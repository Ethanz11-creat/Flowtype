import Foundation
import AppKit
import os

enum M5SmokeSelfTests {
    @MainActor
    static func run(_ r: SelfTest.Reporter) async {
        testSmokeReport(r)
        testValidationActionGuards(r)
        await testTimerOwnershipAndEvidence(r)
    }

    // Missing timer evidence or generic errors must not become success/WindowServer Skip.
    static func testSmokeReport(_ r: SelfTest.Reporter) {
        let context = RuntimeContext(role: .smokeTest, mode: .smoke, runID: UUID(), paths: RuntimeEnvironment.current.paths,
                                     defaultsSuiteName: nil, selfTestFilter: nil)
        let identity = BuildIdentity(origin: .development, metadata: nil, failureCode: nil)
        let snapshot = ReadinessSnapshot(accessibility: .denied, microphone: .notDetermined, speechRecognition: .denied,
            localModel: .unavailable(reason: "synthetic"), cloudASR: .unavailable(reason: "synthetic"), appleSpeech: .unavailable(reason: "synthetic"), computedAt: Date())
        func report(_ probe: Int = 1, _ window: Int = 1, duration: Int = 6000, failure: ValidationFailureCode? = nil) -> SmokeReport {
            SmokeReport.evaluate(context: context, buildInfo: identity, durationMs: duration, snapshot: snapshot,
                                 probeTimerTicks: probe, windowHealthTicks: window, failure: failure)
        }
        let good = report()
        r.check(good.ok && good.exitCode == 0 && good.readiness == .blocked, "M5 smoke succeeds with absent engines and permissions")
        r.eq(good.mic, .notDetermined, "M5 smoke retains read-only permission state")
        for candidate in [report(0), report(1, 0), report(duration: 5999)] {
            r.check(!candidate.ok && candidate.exitCode == 1 && candidate.failureCode == .timerDeadline, "M5 smoke requires duration plus both actual timer callbacks")
        }
        r.eq(report(failure: .windowServerUnavailable).exitCode, 69, "M5 only explicit WindowServer absence is Skip69")
        for failure in [ValidationFailureCode.startupFailed, .unexpectedFailure] {
            r.check(!report(failure: failure).ok && report(failure: failure).exitCode == 1, "M5 ordinary startup failures never Skip")
        }
        let json = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(good)) as! [String: Any]
        r.check(json["failureCode"] is NSNull, "M5 successful smoke emits explicit null failure")
        r.eq(json["mode"] as? String, "smoke", "M5 smoke JSON mode")
        r.eq(good.tap, "disabledForValidation", "M5 smoke never claims a live tap")
    }

    // Direct dispatch, even after a sender is force-enabled, must honor the process role.
    @MainActor
    static func testValidationActionGuards(_ r: SelfTest.Reporter) {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        for role in [ProcessRole.selfTest, .smokeTest] {
            let gate = ValidationActionGate(role: role, downstream: { _ in calls.withLock { $0 += 1 } })
            for action in ValidationAction.allCases { r.check(!gate.allow(action), "M5 validation action denied: \(action)") }
            let shows = OSAllocatedUnfairLock(initialState: 0)
            let session = SessionController(pipeline: [], observers: [],
                effects: SessionEffects(prepare: {}, showWindow: { shows.withLock { $0 += 1 } }, hideWindow: {}), readinessLevel: { .ready }, resources: SessionResourceCoordinator())
            let menu = DictationMenuController(session: session, actionGate: gate)
            menu.item.isEnabled = true
            _ = (menu.item.target as? NSObject)?.perform(menu.item.action!, with: menu.item)
            r.eq(shows.withLock { $0 }, 0, "M5 forced menu selector cannot start capture in validation")
            session.cancel()
        }
        r.eq(calls.withLock { $0 }, 0, "M5 no downstream action in non-app roles")
        for role in [ProcessRole.selfTest, .smokeTest, .app] {
            let effects = OSAllocatedUnfairLock(initialState: [ValidationAction: Int]())
            let gate = ValidationActionGate(role: role)
            let window = WindowManager(panelFactory: { nil }, actionGate: gate, actionEffects: { action in effects.withLock { $0[action, default: 0] += 1 } })
            r.eq(window.installEventTap(), role == .app, "M5 actual install entry respects role")
            window.setupGlobalHotkey(); window.repairEventTap(); window.reloadHotkey()
            window.handleDoubleTap(); window.handleSingleTap()
            r.eq(effects.withLock { $0.values.reduce(0, +) }, role == .app ? 6 : 0,
                 "M5 actual window install repair reload and hotkey downstream guarded")
            let status = StatusBarController(actionGate: gate, actionEffects: { action in effects.withLock { $0[action, default: 0] += 1 } })
            for name in ["repairReadiness", "checkPermissions", "reloadConfiguration", "showSettings", "showOnboarding", "quit", "openLogs", "showAbout", "showMenu"] {
                _ = status.perform(NSSelectorFromString(name))
            }
            status.openSettings()
            r.eq(effects.withLock { $0.values.reduce(0, +) }, role == .app ? 16 : 0,
                 "M5 direct menu repair permission configuration and window selectors guard downstream")
        }
        let app = ValidationActionGate(role: .app, downstream: { _ in calls.withLock { $0 += 1 } })
        for action in ValidationAction.allCases { r.check(app.allow(action), "M5 app action gate permits synthetic control") }
        r.eq(calls.withLock { $0 }, ValidationAction.allCases.count, "M5 app positive control reaches action observer")
    }

    // A callback that redirects to shared, double-starts or merely waits cannot satisfy these.
    @MainActor
    static func testTimerOwnershipAndEvidence(_ r: SelfTest.Reporter) async {
        let firstReads = OSAllocatedUnfairLock(initialState: 0)
        let secondReads = OSAllocatedUnfairLock(initialState: 0)
        let first = ASRRouter(startMonitoring: false, configuration: { firstReads.withLock { $0 += 1 }; return Configuration() },
                              localAvailable: { false }, localLease: { nil }, probeFirstDelay: 0.03, probeInterval: 5, role: .smokeTest)
        let second = ASRRouter(startMonitoring: false, configuration: { secondReads.withLock { $0 += 1 }; return Configuration() },
                               localAvailable: { false }, localLease: { nil }, probeFirstDelay: 0.03, probeInterval: 5, role: .smokeTest)
        r.eq(first.probeTimerTicks, 0, "M5 waiting without start is not a timer tick")
        first.startProbing(); first.startProbing()
        try? await Task.sleep(for: .milliseconds(150))
        r.eq(first.probeTimerTicks, 1, "M5 duplicate probe start owns one real timer")
        r.check(firstReads.withLock { $0 } > 0, "M5 real probe callback refreshes owning instance")
        r.eq(second.probeTimerTicks, 0, "M5 second router receives no callback")
        r.eq(secondReads.withLock { $0 }, 0, "M5 first router callback never refreshes another instance")
        first.stopProbing(); second.stopProbing()
        let window = WindowManager(eventTapHealthInterval: 0.03, panelFactory: { nil })
        window.startValidationHealthCheck(); window.startValidationHealthCheck()
        try? await Task.sleep(for: .milliseconds(110))
        r.check(window.windowHealthTicks >= 2 && window.windowHealthTicks <= 4, "M5 actual health timer advances once per interval")
        window.stopValidationHealthCheck()
        let stopped = window.windowHealthTicks
        try? await Task.sleep(for: .milliseconds(65))
        r.eq(window.windowHealthTicks, stopped, "M5 stopped health timer cannot keep ticking")
    }
}
