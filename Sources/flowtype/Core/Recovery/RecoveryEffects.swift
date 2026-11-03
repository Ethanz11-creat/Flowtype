import AppKit

@MainActor
struct RecoveryEffects {
    var openAccessibilitySettings: @MainActor @Sendable () -> Void
    var openMicrophoneSettings: @MainActor @Sendable () -> Void
    var openSpeechRecognitionSettings: @MainActor @Sendable () -> Void
    var openASRSettings: @MainActor @Sendable () -> Void
    var openHistory: @MainActor @Sendable () -> Void
    var copyText: @MainActor @Sendable (String) -> Void

    static let live = RecoveryEffects(
        openAccessibilitySettings: {
            PermissionHelper.openAccessibilitySettings()
            ReadinessMonitor.shared.startPermissionWatchIfNeeded()
        },
        openMicrophoneSettings: { PermissionHelper.openMicrophoneSettings() },
        openSpeechRecognitionSettings: { PermissionHelper.openSpeechRecognitionSettings() },
        openASRSettings: { StatusBarController.shared.openSettings(tab: .settings) },
        openHistory: { StatusBarController.shared.openSettings(tab: .history) },
        copyText: { KeyboardInjector.copyText($0) })
}
