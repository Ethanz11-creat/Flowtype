import SwiftUI
import Combine
import ApplicationServices
import CoreGraphics

@MainActor
class WindowManager: ObservableObject {
    static let shared = WindowManager()
    var panel: FloatingPanel?
    private let orchestrator = PipelineOrchestrator.shared

    // MARK: - Hotkey State
    private var lastOptionPressTime: Date = .distantPast
    private var lastTriggerTime: Date = .distantPast
    private var recordingStartTime: Date?
    private var recordingStopTime: Date?
    private var isOptionDown: Bool = false
    private let doubleTapInterval: TimeInterval = 0.6
    private let debounceInterval: TimeInterval = 0.2
    private let postActionCooldown: TimeInterval = 0.5

    private var eventTapPort: CFMachPort?

    init() {
        let view = AnyView(
            CapsuleView()
                .environmentObject(orchestrator.state)
        )
        panel = FloatingPanel(view: view)
        setupGlobalHotkey()
    }

    // MARK: - CGEventTap Setup

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
        // Listen to flagsChanged (Option key state) and keyDown/keyUp as backup
        let eventMask = (1 << CGEventType.flagsChanged.rawValue)
                      | (1 << CGEventType.keyDown.rawValue)
                      | (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[WindowManager] Failed to create CGEvent tap, falling back to NSEvent monitor")
            setupNSEventFallback()
            return
        }

        self.eventTapPort = tap

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        DispatchQueue.global(qos: .userInteractive).async {
            let runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
    }

    /// CGEventTap callback — runs on background thread, must be @convention(c)
    private static let eventTapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon = refcon else {
            return Unmanaged.passRetained(event)
        }

        let manager = Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()

        // Primary path: flagsChanged detects Option key state transitions
        if type == .flagsChanged {
            let flags = event.flags
            let isOptionNow = flags.contains(.maskAlternate)

            DispatchQueue.main.async {
                manager.handleOptionFlagsChanged(isOptionNow: isOptionNow)
            }

            // Consume flagsChanged to prevent system sound
            return nil
        }

        // Backup path: keyDown for Option key (keyCode 58 = left, 61 = right)
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 58 || keyCode == 61 {
                DispatchQueue.main.async {
                    manager.handleOptionKeyDown()
                }
                return nil
            }
        }

        // Pass through all other events
        return Unmanaged.passRetained(event)
    }

    /// Fallback if CGEventTap fails
    private func setupNSEventFallback() {
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleOptionFlagsChanged(isOptionNow: event.modifierFlags.contains(.option))
            }
        }
    }

    // MARK: - Hotkey Handling

    /// Called when Option key state changes (via flagsChanged)
    private func handleOptionFlagsChanged(isOptionNow: Bool) {
        let now = Date()

        // Detect Option press (transition from not pressed to pressed)
        if isOptionNow && !isOptionDown {
            isOptionDown = true
            handleOptionPressed(at: now)
        }
        // Detect Option release (transition from pressed to not pressed)
        else if !isOptionNow && isOptionDown {
            isOptionDown = false
        }
    }

    /// Called when Option keyDown fires (backup detection)
    private func handleOptionKeyDown() {
        let now = Date()
        handleOptionPressed(at: now)
    }

    private func handleOptionPressed(at now: Date) {
        // Debounce: ignore if last trigger was too recent
        if now.timeIntervalSince(lastTriggerTime) < debounceInterval {
            return
        }

        // Cooldown after starting recording: prevents the second tap of a double-tap from stopping
        if let startTime = recordingStartTime,
           now.timeIntervalSince(startTime) < postActionCooldown {
            return
        }

        // Cooldown after stopping recording: prevents immediate re-start
        if let stopTime = recordingStopTime,
           now.timeIntervalSince(stopTime) < postActionCooldown {
            return
        }

        let isRecording = orchestrator.isRecording

        if isRecording {
            // Single tap to stop recording
            lastTriggerTime = now
            recordingStopTime = now
            recordingStartTime = nil
            print("[WindowManager] Single-tap Option → stop recording")
            orchestrator.toggleRecording()
        } else {
            // Double tap to start recording
            let interval = now.timeIntervalSince(lastOptionPressTime)
            if interval <= doubleTapInterval {
                // Double tap confirmed
                lastTriggerTime = now
                recordingStartTime = now
                recordingStopTime = nil
                lastOptionPressTime = .distantPast
                print("[WindowManager] Double-tap Option → start recording (interval \(String(format: "%.3f", interval))s)")
                orchestrator.toggleRecording()
            } else {
                // First tap of potential double-tap
                lastOptionPressTime = now
            }
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
            let x = (screen.frame.width - 320) / 2
            let y = screen.frame.height * 0.82
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
