import Foundation

/// Unified interface for local and cloud ASR providers.
///
/// Audio format contract (same as `SpeechProvider.transcribe(audioData:)`):
/// `audioData` is **raw little-endian Float32 PCM samples** at 16 kHz mono — never a
/// WAV container. Providers that need WAV encode it themselves (see `CloudASRProvider`),
/// and providers that only expose a sample-based API decode raw Float32 directly
/// (see `QwenASRProvider`).
protocol ASRProvider: SpeechProvider, Sendable {
    var id: String { get }
    var displayName: String { get }
    var isAvailable: Bool { get async }
    var supportsStreaming: Bool { get }
}
