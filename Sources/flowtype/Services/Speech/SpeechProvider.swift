import Foundation

// MARK: - Speech Provider Protocol

protocol SpeechProvider: Sendable {
    var name: String { get }

    /// One-shot transcription.
    ///
    /// Contract: `audioData` is **raw little-endian Float32 PCM samples** (16 kHz mono),
    /// NOT a WAV container. Providers that need a container (e.g. WAV, multipart file)
    /// must encode it themselves. This matches the single call site, `ASRStage`, which
    /// passes `[Float]` bytes directly.
    func transcribe(audioData: Data, timeout: TimeInterval) async throws -> String
}

// MARK: - Provider Types

enum SpeechProviderError: Error {
    case transcriptionFailed(String)
    case networkError(Error)
    case notAvailable
    case permissionDenied
}
