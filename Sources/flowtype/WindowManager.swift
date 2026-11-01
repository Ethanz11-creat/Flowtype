import SwiftUI
import ApplicationServices
import CoreGraphics
import QuartzCore

@preconcurrency import CoreFoundation

// MARK: - Option Tap Detector

/// Standalone tap detector kept synchronous on the main run loop.
/// Hotkey callbacks route live session actions with MainActor.assumeIsolated;
/// its timer fires on the same main run loop, without a queued dispatch hop.
final class OptionTapDetector: @unchecked Sendable {
    static let shared = OptionTapDetector()

    private let tapWindow: TimeInterval = 0.35
    private var tapTimes: [Date] = []
    private var tapTimer = CancellableTimer()

    var onDoubleTap: (@Sendable () -> Void)?
    var onSingleTap: (@Sendable () -> Void)?

    private init() {}

    func cancelPendingTaps() {
        tapTimer.cancel()
        tapTimes.removeAll()
    }

    /// Active releases bypass the idle start detector and discard its pending timer.
    func recordTap(at now: Date = Date(), state: SessionState = .idle,
                   mode: InteractionMode = .tapToStart) {
        switch state {
        case .preparing, .recording:
            cancelPendingTaps()
            onSingleTap?()
            return
        case .processing, .polishing, .injecting:
            cancelPendingTaps()
            return
        case .idle, .error, .notice:
            if mode == .toggle {
                cancelPendingTaps()
                onSingleTap?()
                return
            }
        }
        tapTimes.append(now)
        tapTimes.removeAll { now.timeIntervalSince($0) > tapWindow }

        if tapTimes.count >= 2 {
            tapTimer.cancel()
            tapTimes.removeAll()
            AppLogger.log("[TapDetector] DOUBLE-TAP detected")
            onDoubleTap?()
        } else {
            tapTimer.schedule(
                timeInterval: tapWindow,
                target: self,
                selector: #selector(timerFired)
            )
            AppLogger.log("[TapDetector] Single tap, timer started (window: \(tapWindow)s)")
        }
    }

    @objc private func timerFired() {
        AppLogger.log("[TapDetector] Timer fired, tapTimes.count=\(tapTimes.count)")
        if tapTimes.count == 1 {
            tapTimes.removeAll()
            onSingleTap?()
        } else {
            tapTimes.removeAll()
        }
    }
}

// MARK: - Window Manager

enum EventTapHealthAction: Equatable, Sendable {
    case none, enableExisting, recreate, waitForPermission
}

@MainActor
class WindowManager: ObservableObject {
    static let shared = WindowManager()
    var panel: FloatingPanel?

    private var eventTapPort: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var eventTapFailureCount = 0
    private var healthTimerStarted = false
    private var lastHealthAction: EventTapHealthAction = .none
    private var reloadWorkItem: DispatchWorkItem?

    /// Periodic timer to ensure the CGEvent tap stays enabled after system events.
    private var eventTapHealthTimer = CancellableTimer()
    private let eventTapHealthInterval: TimeInterval = 5.0

    /// Current trigger key from configuration
    private var triggerKey: TriggerKey { ConfigurationStore.shared.current.triggerKey }

    /// Cached trigger key for safe access from C callback (avoids actor isolation issues)
    private static var cachedTriggerKey = MainThreadCachedValue<TriggerKey>(.command)

    /// Cached interaction mode for safe access from C callback.
    private static var cachedInteractionMode = MainThreadCachedValue<InteractionMode>(.tapToStart)

    /// Cached key-down timestamp for non-modifier trigger keys to enforce press-and-hold.
    private static var cachedKeyDownTime = MainThreadCachedValue<Date?>(nil)
    private nonisolated static let nonModifierHoldThreshold: TimeInterval = 0.2

    /// Edge tracking for modifier trigger keys: a tap is a clean press+release. Any
    /// non-modifier keyDown while the trigger is held (Cmd+C, Cmd+V, …) marks the hold
    /// as a shortcut chord, not a tap — otherwise two quick shortcuts would start
    /// recording and a single shortcut would kill an active recording.
    private static var cachedTriggerWasDown = MainThreadCachedValue<Bool>(false)
    private static var cachedSawOtherKeyDuringHold = MainThreadCachedValue<Bool>(false)

    /// Edge machine for modifier-trigger flagsChanged events.
    /// Press edge starts a clean hold; release edge records a tap only if the hold stayed
    /// clean; a repeated same-state event (another modifier moved while held) is a no-op.
    nonisolated static func modifierTapAction(isDownNow: Bool, wasDown: Bool, sawOtherKey: Bool) -> (recordTap: Bool, resetSawOtherKey: Bool) {
        if isDownNow && !wasDown { return (recordTap: false, resetSawOtherKey: true) }
        if !isDownNow && wasDown { return (recordTap: !sawOtherKey, resetSawOtherKey: false) }
        return (recordTap: false, resetSawOtherKey: false)
    }

    nonisolated static func nonModifierPressTime(current: Date?, now: Date, isRepeat: Bool) -> Date? {
        isRepeat ? current : (current ?? now)
    }

    nonisolated static func nonModifierReleaseAllowed(heldDuration: TimeInterval?, sawOtherKey: Bool,
                                                     state: SessionState) -> Bool {
        guard let heldDuration, !sawOtherKey else { return false }
        switch state {
        case .preparing, .recording: return true
        case .idle, .error, .notice: return heldDuration >= nonModifierHoldThreshold
        case .processing, .polishing, .injecting: return false
        }
    }

    init() {
        let view = AnyView(
            CapsuleView()
                .environmentObject(SessionController.shared)
        )
        panel = FloatingPanel(view: view)

        // Wire up tap detector callbacks
        let detector = OptionTapDetector.shared
        detector.onDoubleTap = { [weak self] in
            guard let self = self else { return }
            MainActor.assumeIsolated { self.handleDoubleTap() }
        }
        detector.onSingleTap = { [weak self] in
            guard let self = self else { return }
            MainActor.assumeIsolated { self.handleSingleTap() }
        }
    }

    // MARK: - Hotkey Setup

    nonisolated static func eventTapHealthAction(tapExists: Bool, tapEnabled: Bool,
                                                 accessibilityTrusted: Bool) -> EventTapHealthAction {
        if tapExists { return tapEnabled ? .none : .enableExisting }
        return accessibilityTrusted ? .recreate : .waitForPermission
    }

    func setupGlobalHotkey() {
        AppLogger.log("[WindowManager] setupGlobalHotkey called")
        let accessibilityEnabled = PermissionHelper.checkAccessibility()
        if !accessibilityEnabled {
            AppLogger.log("[WindowManager] WARNING: Accessibility permission not granted")
        }

        Self.cachedTriggerKey.value = triggerKey
        Self.cachedInteractionMode.value = ConfigurationStore.shared.current.interactionMode
        AppLogger.log("[WindowManager] Cached triggerKey: \(triggerKey.displayName), interactionMode: \(Self.cachedInteractionMode.value.displayName)")

        _ = installEventTap()
        startEventTapHealthCheck()
        AppLogger.log("[WindowManager] Global hotkey registered (double-tap \(triggerKey.displayName) to start, single-tap to stop)")
    }

    func reloadHotkey() {
        AppLogger.log("[WindowManager] Queuing debounced hotkey reload...")
        reloadWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            AppLogger.log("[WindowManager] Executing debounced reload...")
            Self.cachedTriggerKey.value = self.triggerKey
            Self.cachedInteractionMode.value = ConfigurationStore.shared.current.interactionMode
            // Stale edge state across a tap rebuild could turn the next unrelated
            // flagsChanged into a phantom release-tap — start the new tap clean.
            Self.cachedTriggerWasDown.value = false
            Self.cachedSawOtherKeyDuringHold.value = false
            Self.cachedKeyDownTime.value = nil
            OptionTapDetector.shared.cancelPendingTaps()
            self.tearDownEventTap()
            _ = self.installEventTap()
            AppLogger.log("[WindowManager] Hotkey reloaded with trigger key: \(self.triggerKey.displayName)")
        }
        reloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func startEventTapHealthCheck() {
        guard !healthTimerStarted else { return }
        healthTimerStarted = true
        eventTapHealthTimer.schedule(
            withTimeInterval: eventTapHealthInterval,
            repeats: true
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.repairEventTap()
            }
        }
    }

    func repairEventTap() {
        // An installed tap is stronger evidence than a trust query for unsigned
        // apps. Only probe permission when there is no tap to repair.
        let trusted = eventTapPort != nil || PermissionHelper.checkAccessibility()
        let action = Self.eventTapHealthAction(
            tapExists: eventTapPort != nil,
            tapEnabled: eventTapPort.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
            accessibilityTrusted: trusted
        )
        if action != lastHealthAction {
            AppLogger.log("[WindowManager] Event tap health action: \(action)")
            lastHealthAction = action
        }
        switch action {
        case .none, .waitForPermission:
            break
        case .enableExisting:
            if let tap = eventTapPort { CGEvent.tapEnable(tap: tap, enable: true) }
        case .recreate:
            tearDownEventTap()
            _ = installEventTap()
        }
    }

    private func tearDownEventTap() {
        if let source = eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTapPort {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        eventTapRunLoopSource = nil
        eventTapPort = nil
    }

    @discardableResult
    func installEventTap() -> Bool {
        guard eventTapPort == nil else { return true }
        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
                      | CGEventMask(1 << CGEventType.keyDown.rawValue)
                      | CGEventMask(1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return recordEventTapFailure()
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            return recordEventTapFailure()
        }
        eventTapPort = tap
        eventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        eventTapFailureCount = 0
        CGEvent.tapEnable(tap: tap, enable: true)
        AppLogger.log("[EventTap] CGEvent tap created and enabled successfully")
        return true
    }

    private func recordEventTapFailure() -> Bool {
        eventTapFailureCount += 1
        if eventTapFailureCount == 1 || eventTapFailureCount.isMultiple(of: 12) {
            AppLogger.log("[WindowManager] FAILED to create CGEvent tap (attempt \(eventTapFailureCount))")
        }
        return false
    }

    /// CGEventTap callback — runs on the main thread since source is added to main RunLoop.
    /// MainActor.assumeIsolated routes session actions synchronously on this main-runloop callback.
    private static let eventTapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
        // Security: enforce that callback runs on main thread (all cached values are main-thread-only)
        dispatchPrecondition(condition: .onQueue(.main))

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let refcon = refcon {
                let manager = Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
                assert(WindowManager.shared === manager, "eventTapCallback refcon must point to the WindowManager singleton")
                if let tap = manager.eventTapPort {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            return Unmanaged.passRetained(event)
        }

        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if keyCode == 53 {
                if cachedKeyDownTime.value != nil { cachedSawOtherKeyDuringHold.value = true }
                let cancelled = MainActor.assumeIsolated {
                    OptionTapDetector.shared.cancelPendingTaps()
                    let controller = SessionController.shared
                    guard controller.sessionState != .idle else { return false }
                    controller.cancel()
                    return true
                }
                if cancelled { return nil }
            }

            // Handle non-modifier trigger keys (F13, F14, F15, Caps Lock)
            if !cachedTriggerKey.value.isModifier,
               let triggerKeyCode = cachedTriggerKey.value.keyCode,
               keyCode == Int64(triggerKeyCode) {
                if cachedKeyDownTime.value == nil && !isRepeat {
                    let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
                    cachedSawOtherKeyDuringHold.value = !event.flags.intersection(modifiers).isEmpty
                }
                cachedKeyDownTime.value = nonModifierPressTime(
                    current: cachedKeyDownTime.value,
                    now: Date(),
                    isRepeat: isRepeat
                )
                AppLogger.log("[EventTap] Non-modifier trigger key down, waiting for hold threshold...")
                return nil
            }

            if !cachedTriggerKey.value.isModifier, cachedKeyDownTime.value != nil {
                cachedSawOtherKeyDuringHold.value = true
            }

            // Any other key pressed while the trigger modifier is held → this hold is a
            // shortcut chord (Cmd+C …), not a tap. Poison it so the release records nothing.
            if cachedTriggerKey.value.isModifier,
               let triggerFlag = cachedTriggerKey.value.cgEventFlag,
               (event.flags.rawValue & triggerFlag.rawValue) != 0 {
                cachedSawOtherKeyDuringHold.value = true
            }

            return Unmanaged.passRetained(event)
        }

        if type == .keyUp {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if !cachedTriggerKey.value.isModifier,
               let triggerKeyCode = cachedTriggerKey.value.keyCode,
               keyCode == Int64(triggerKeyCode) {
                // Only idle start needs a hold; active clean release stops immediately.
                let holdDuration: TimeInterval?
                if let downTime = cachedKeyDownTime.value {
                    holdDuration = Date().timeIntervalSince(downTime)
                } else {
                    holdDuration = nil
                }
                cachedKeyDownTime.value = nil
                let sawOtherKey = cachedSawOtherKeyDuringHold.value
                cachedSawOtherKeyDuringHold.value = false

                MainActor.assumeIsolated {
                    let controller = SessionController.shared
                    guard nonModifierReleaseAllowed(heldDuration: holdDuration,
                                                    sawOtherKey: sawOtherKey,
                                                    state: controller.sessionState) else { return }
                    OptionTapDetector.shared.recordTap(state: controller.sessionState,
                                                       mode: cachedInteractionMode.value)
                }
                return nil
            }
            return Unmanaged.passRetained(event)
        }

        guard type == .flagsChanged else {
            return Unmanaged.passRetained(event)
        }

        guard !KeyboardInjector.isInjecting.withLock({ $0 }) else {
            return Unmanaged.passRetained(event)
        }

        let flags = event.flags
        let triggerFlag = cachedTriggerKey.value.cgEventFlag
        let isTriggerKeyNow: Bool
        if let triggerFlag {
            isTriggerKeyNow = (flags.rawValue & triggerFlag.rawValue) != 0
        } else {
            isTriggerKeyNow = false
        }

        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
        if !cachedTriggerKey.value.isModifier, cachedKeyDownTime.value != nil,
           !flags.intersection(modifiers).isEmpty {
            cachedSawOtherKeyDuringHold.value = true
        }
        let hasOtherModifier = triggerFlag.map {
            flags.rawValue & modifiers.rawValue & ~$0.rawValue != 0
        } ?? false
        if isTriggerKeyNow && hasOtherModifier {
            cachedSawOtherKeyDuringHold.value = true
        }

        let wasDown = cachedTriggerWasDown.value
        cachedTriggerWasDown.value = isTriggerKeyNow
        let action = modifierTapAction(isDownNow: isTriggerKeyNow,
                                       wasDown: wasDown,
                                       sawOtherKey: cachedSawOtherKeyDuringHold.value)
        if action.resetSawOtherKey {
            cachedSawOtherKeyDuringHold.value = hasOtherModifier
        }
        if action.recordTap {
            AppLogger.log("[EventTap] Trigger key tap (clean press+release, trigger=\(cachedTriggerKey.value.displayName))")
            MainActor.assumeIsolated {
                let controller = SessionController.shared
                OptionTapDetector.shared.recordTap(state: controller.sessionState,
                                                   mode: cachedInteractionMode.value)
            }
        } else if !isTriggerKeyNow && wasDown {
            AppLogger.log("[EventTap] Trigger key release suppressed (shortcut chord during hold)")
        }

        return Unmanaged.passRetained(event)
    }

    // MARK: - Tap Handlers

    private func handleDoubleTap() {
        let controller = SessionController.shared
        // Double-tap belongs exclusively to idle start detection. An active release
        // already stopped synchronously and cannot change the polish policy.
        switch controller.sessionState {
        case .idle, .error, .notice: controller.startRecording()
        default: break
        }
    }

    private func handleSingleTap() {
        let controller = SessionController.shared
        switch controller.sessionState {
        case .preparing, .recording:
            controller.endRecording()
        case .idle, .error, .notice:
            if ConfigurationStore.shared.current.interactionMode == .toggle {
                controller.startRecording()
            }
        default:
            break
        }
    }

    // MARK: - Window Management

    /// Distance the capsule travels while sliding in/out, in points.
    private static let slideOffset: CGFloat = 60

    func showWindow() {
        guard let panel = panel else { return }
        panel.setCapsuleSize(SessionController.shared.sessionState.capsuleSize)
        guard let screen = NSScreen.main else {
            panel.alphaValue = 1
            panel.orderFront(nil)
            return
        }
        // Already visible — don't replay the slide-in animation (e.g. .polishing → .notice).
        if panel.isVisible { return }

        let targetX = screen.visibleFrame.midX - panel.frame.width / 2
        let targetY = screen.visibleFrame.minY + 40

        // Start just below the resting position, fully transparent, then slide up + fade in.
        panel.setFrameOrigin(NSPoint(x: targetX, y: targetY - Self.slideOffset))
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(NSPoint(x: targetX, y: targetY))
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        // Don't hide the panel during text injection — user needs to see progress
        guard SessionController.shared.sessionState != .injecting else { return }
        guard let panel = panel, panel.isVisible else {
            panel?.orderOut(nil)
            return
        }

        // Slide down + fade out, then actually order out once the animation finishes.
        let origin = panel.frame.origin
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrameOrigin(NSPoint(x: origin.x, y: origin.y - Self.slideOffset))
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let panel = self?.panel else { return }
                if panel.alphaValue < 0.05 {
                    panel.orderOut(nil)
                    panel.alphaValue = 1
                }
            }
        })
    }

    func toggleWindow() {
        guard let panel = panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            showWindow()
        }
    }

    func hideMainWindow() {
        for window in NSApp.windows {
            if window.title.isEmpty && !(window is FloatingPanel) {
                window.close()
            }
        }
    }
}
