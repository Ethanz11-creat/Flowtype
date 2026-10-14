import Foundation

// MARK: - AudioFeedbackObserver

/// Observes session state transitions and plays audio feedback sounds when enabled.
final class AudioFeedbackObserver: @preconcurrency SessionObserver {
    enum Feedback: Equatable { case start, stop, error }
    private let enabled: () -> Bool
    private let play: (Feedback) -> Void
    @MainActor private var startedSessionID: UInt64?
    @MainActor private var stoppedSessionID: UInt64?

    init(enabled: @escaping () -> Bool = { ConfigurationStore.shared.current.enableAudioFeedback },
         play: @escaping (Feedback) -> Void = { feedback in
             switch feedback {
             case .start: SoundFeedback.playRecordingStart()
             case .stop: SoundFeedback.playRecordingStop()
             case .error: SoundFeedback.playError()
             }
         }) {
        self.enabled = enabled
        self.play = play
    }

    // The synchronous observer contract is always delivered by the main-actor controller.
    @MainActor
    func sessionDidTransition(from oldState: SessionState, to newState: SessionState, context: SessionContext) {
        guard enabled(), !context.isCancelled else { return }
        switch (oldState, newState) {
        case (.preparing, .recording):
            guard context.isReady, startedSessionID != context.sessionID else { return }
            startedSessionID = context.sessionID
            play(.start)
        case (.recording, .processing):
            guard context.isReady, stoppedSessionID != context.sessionID else { return }
            stoppedSessionID = context.sessionID
            play(.stop)
        case (_, .error):
            play(.error)
        default:
            break
        }
    }
}
