import AudioToolbox

/// Provides audio feedback for recording state changes.
/// Sounds respect macOS "Play user interface sound effects" setting.
enum SoundFeedback {

    static var isEnabled: Bool {
        ConfigurationStore.shared.current.enableAudioFeedback
    }

    static func playRecordingStart() {
        guard isEnabled else { return }
        AudioServicesPlaySystemSound(1104) // ascending tone
    }

    static func playRecordingStop() {
        guard isEnabled else { return }
        AudioServicesPlaySystemSound(1103) // descending tone
    }

    static func playError() {
        guard isEnabled else { return }
        AudioServicesPlaySystemSound(1102) // subtle bump
    }

    static func playCopiedToClipboard() {
        guard isEnabled else { return }
        AudioServicesPlaySystemSound(1054) // "Tink" — distinct from start(1104)/stop(1103)/error(1102)
    }
}
