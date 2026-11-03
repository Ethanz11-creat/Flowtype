import AppKit

@MainActor
struct RecoveryEffects {
    var openAccessibilitySettings: @MainActor @Sendable () -> Void
    var openMicrophoneSettings: @MainActor @Sendable () -> Void
    var openSpeechRecognitionSettings: @MainActor @Sendable () -> Void
    var openASRSettings: @MainActor @Sendable () -> Void
    var openHistory: @MainActor @Sendable () -> Void
    var copyText: @MainActor @Sendable (String) -> Void
    var openDestination: (@MainActor @Sendable (ClientDestination) -> Void)? = nil

    func navigate(to destination: ClientDestination) {
        if let openDestination { openDestination(destination) }
        else if case .history = destination { openHistory() }
        else { openASRSettings() }
    }

    static let live = RecoveryEffects(
        openAccessibilitySettings: {
            PermissionHelper.openAccessibilitySettings()
            ReadinessMonitor.shared.startPermissionWatchIfNeeded()
        },
        openMicrophoneSettings: { PermissionHelper.openMicrophoneSettings() },
        openSpeechRecognitionSettings: { PermissionHelper.openSpeechRecognitionSettings() },
        openASRSettings: { StatusBarController.shared.openSettings(destination: .settings(.speech)) },
        openHistory: { StatusBarController.shared.openSettings(destination: .history()) },
        copyText: { KeyboardInjector.copyText($0) },
        openDestination: { StatusBarController.shared.openSettings(destination: $0) })
}
