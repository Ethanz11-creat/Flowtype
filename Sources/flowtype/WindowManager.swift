import SwiftUI
import Combine
import ApplicationServices
import CoreGraphics

@preconcurrency import CoreFoundation

// MARK: - Option Tap Detector
/// Standalone tap detector that lives outside @MainActor isolation.
/// All access is serialized on the main thread (CGEventTap dispatches via
/// DispatchQueue.main.async, Timer fires on the runloop that created it).
final class OptionTapDetector: @unchecked Sendable {
    static let shared = OptionTapDetector()

    private let tapWindow: TimeInterval = 0.35
    private var tapTimes: [Date] = []
    private var tapTimer: Timer?

    var onDoubleTap: (@Sendable () -> Void)?
    var onSingleTap: (@Sendable () -> Void)?

    private init() {}

    func recordTap(at now: Date = Date()) {
        tapTimes.append(now)
        tapTimes.removeAll { now.timeIntervalSince($0) > tapWindow }

        if tapTimes.count >= 2 {
            tapTimer?.invalidate()
            tapTimer = nil
            tapTimes.removeAll()
            print("[TapDetector] DOUBLE-TAP detected")
            onDoubleTap?()
        } else {
            tapTimer?.invalidate()
            tapTimer = Timer.scheduledTimer(timeInterval: tapWindow,
                                            target: self,
                                            selector: #selector(timerFired),
                                            userInfo: nil,
                                            repeats: false)
            print("[TapDetector] Single tap, timer started (window: \(tapWindow)s)")
        }
    }

    @objc private func timerFired() {
        print("[TapDetector] Timer fired, tapTimes.count=\(tapTimes.count)")
        if tapTimes.count == 1 {
            tapTimes.removeAll()
            onSingleTap?()
        } else {
            tapTimes.removeAll()
        }
    }
}

// MARK: - WindowManager

@MainActor
class WindowManager: ObservableObject {
    static let shared = WindowManager()
    var panel: FloatingPanel?
    private let orchestrator = PipelineOrchestrator.shared

    private var eventTapPort: CFMachPort?

    init() {
        let view = AnyView(
            CapsuleView()
                .environmentObject(orchestrator.state)
        )
        panel = FloatingPanel(view: view)

        // Wire up tap detector callbacks
        let detector = OptionTapDetector.shared
        detector.onDoubleTap = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.handleDoubleTap()
            }
        }
        detector.onSingleTap = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.handleSingleTap()
            }
        }

        setupGlobalHotkey()
    }

    // MARK: - Hotkey Setup

    func setupGlobalHotkey() {
        let accessibilityEnabled = Self.checkAccessibilityPermission()
        if !accessibilityEnabled {
            print("[WindowManager] WARNING: Accessibility permission not granted")
        } else {
            print("[WindowManager] Accessibility permission granted")
        }

        setupCGEventTap()
        print("[WindowManager] Global hotkey registered (double-tap Option to start, single-tap to stop)")
    }

    private func setupCGEventTap() {
        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[WindowManager] Failed to create CGEvent tap")
            return
        }

        self.eventTapPort = tap

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        DispatchQueue.global(qos: .userInteractive).async { [runLoopSource] in
            let runLoop = CFRunLoopGetCurrent()
            if let source = runLoopSource {
                CFRunLoopAddSource(runLoop, source, .commonModes)
            }
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
    }

    /// CGEventTap callback — runs on background thread, must be @convention(c).
    /// We ONLY check flagsChanged for Option-key press and immediately
    /// bounce to the main thread via Task { @MainActor }.
    private static let eventTapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon = refcon else {
            return Unmanaged.passRetained(event)
        }

        // We only care about flagsChanged events
        guard type == .flagsChanged else {
            return Unmanaged.passRetained(event)
        }

        let flags = event.flags
        let isOptionNow = flags.contains(.maskAlternate)

        if isOptionNow {
            // Bounce to MainActor so OptionTapDetector (which is not isolated)
            // receives the tap on the main thread.
            Task { @MainActor in
                OptionTapDetector.shared.recordTap()
            }
        }

        // Always pass the event through — never consume it.
        return Unmanaged.passRetained(event)
    }

    // MARK: - Tap Handlers

    @MainActor
    private func handleDoubleTap() {
        let wasRecording = orchestrator.isRecording
        print("[WindowManager] handleDoubleTap — wasRecording=\(wasRecording)")

        if wasRecording {
            print("[WindowManager] → DOUBLE-TAP END (LLM polish)")
            orchestrator.beginEndModeDetection()
            orchestrator.confirmDoubleTapEnd()
            orchestrator.toggleRecording()
        } else {
            print("[WindowManager] → DOUBLE-TAP START recording")
            orchestrator.toggleRecording()
        }
    }

    @MainActor
    private func handleSingleTap() {
        print("[WindowManager] handleSingleTap — isRecording=\(orchestrator.isRecording)")
        if orchestrator.isRecording {
            print("[WindowManager] → SINGLE-TAP END (raw ASR)")
            orchestrator.toggleRecording()
        } else {
            print("[WindowManager] Single tap while idle, ignoring")
        }
    }

    // MARK: - Window Management

    func toggleWindow() {
        guard let panel = panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            showWindow()
        }
    }

    func showWindow() {
        guard let panel = panel else { return }
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - 160
            let y = screen.visibleFrame.minY + 40
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func hideMainWindow() {
        for window in NSApp.windows {
            if window.title.isEmpty && !(window is FloatingPanel) {
                window.close()
            }
        }
    }

    private static func checkAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }
}
