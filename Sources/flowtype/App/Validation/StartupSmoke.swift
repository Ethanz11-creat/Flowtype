import Foundation
import AppKit
import CoreGraphics

@MainActor
enum StartupSmoke {
    static func run(context: RuntimeContext) async -> SmokeReport {
        let started = DispatchTime.now().uptimeNanoseconds
        func duration() -> Int { Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000) }
        let identity = AppLogger.identity
        var snapshot = ReadinessSnapshot(accessibility: .unknown, microphone: .unknown, speechRecognition: .unknown,
            localModel: .unavailable(reason: "validation"), cloudASR: .unavailable(reason: "validation"),
            appleSpeech: .unavailable(reason: "validation"), computedAt: Date())
        func failure(_ code: ValidationFailureCode) -> SmokeReport {
            SmokeReport.evaluate(context: context, buildInfo: identity, durationMs: duration(), snapshot: snapshot,
                                 probeTimerTicks: 0, windowHealthTicks: 0, failure: code)
        }
        guard context.role == .smokeTest, context.mode == .smoke else { return failure(.startupFailed) }
        guard identity.origin != .invalid else { return failure(.invalidBuildInfo) }
        // This API returns nil when no graphical login/WindowServer session is available.
        // Other initialization failures must not be relabeled as this explicit unsupported case.
        guard CGSessionCopyCurrentDictionary() != nil else { return failure(.windowServerUnavailable) }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        _ = ConfigurationStore.shared
        _ = SessionController.shared
        let router = ASRRouter.shared
        let windows = WindowManager.shared
        guard let panel = windows.panel, !panel.isVisible else { return failure(.startupFailed) }
        let status = StatusBarController.shared
        status.setup()
        let readiness = ReadinessMonitor.shared
        defer {
            router.stopProbing()
            windows.finishValidation()
            status.finishValidation()
            readiness.stopPermissionWatch()
        }
        guard status.isConfigured else { return failure(.startupFailed) }
        readiness.refresh()
        snapshot = readiness.snapshot
        let baselineProbe = router.probeTimerTicks
        let baselineWindow = windows.windowHealthTicks
        router.startProbing()
        windows.startValidationHealthCheck()
        let observing = DispatchTime.now().uptimeNanoseconds
        func observedSeconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds - observing) / 1_000_000_000 }
        while observedSeconds() < 10 {
            if observedSeconds() >= 6, router.probeTimerTicks > baselineProbe, windows.windowHealthTicks > baselineWindow { break }
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return failure(.unexpectedFailure) }
        }
        readiness.refresh()
        return SmokeReport.evaluate(context: context, buildInfo: identity, durationMs: duration(), snapshot: readiness.snapshot,
            probeTimerTicks: router.probeTimerTicks - baselineProbe, windowHealthTicks: windows.windowHealthTicks - baselineWindow)
    }
}
