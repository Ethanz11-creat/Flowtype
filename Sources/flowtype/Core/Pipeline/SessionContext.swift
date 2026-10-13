import Foundation
import Combine
import AppKit

// MARK: - SessionContext

/// Shared mutable state for a single dictation session.
///
/// `SessionContext` is `@MainActor` because it is accessed from both the UI
/// (SwiftUI views observing state changes) and the async pipeline stages.
///
/// ## Data Flow Architecture
///
/// There are two separate data paths from the pipeline to the UI:
///
/// 1. **Discrete state transitions** — `statePublisher` emits `SessionState` values
///    (`.idle → .recording → .processing → ...`). These are coarse-grained,
///    stage-driven transitions observed by both `SessionController` and `SessionObserver`s.
///
/// 2. **Continuous real-time data** — `spectrumPublisher`
///    streams high-frequency updates directly from `RecordingStage` to `SessionController`.
///    This bypasses the 1-second timer polling that was used in the initial refactor,
///    providing responsive spectrum visualization at the
///    native frequency of the audio buffer callbacks.
///
/// Stages write real-time data to both the stored property (`currentSpectrum`)
/// and the corresponding publisher, so the values remain inspectable for debugging
/// while the publisher drives immediate UI updates.
@MainActor
final class SessionContext {
    /// Unique identifier for this session (monotonically increasing).
    let sessionID: UInt64

    /// Whether the user requested LLM polish (double-tap to end recording).
    var usePolish: Bool = false

    /// When the recording phase started (for diagnostics).
    var recordingStartTime: Date?

    /// Pure recording duration in ms (samples/16000), set by RecordingStage. The speed denominator.
    var recordingMs: UInt64?

    /// Publisher for state transitions (observed by UI and observers).
    let statePublisher: PassthroughSubject<SessionState, Never>

    /// Raw transcript from ASR before any post-processing.
    var rawTranscript: String = ""

    /// Final text after all processing / polish, ready for injection.
    var finalText: String = ""

    /// Set when LLM polish failed and we degraded to keeping the raw ASR text (history then marks it .raw).
    var polishFailed: Bool = false

    /// 本轮实际使用的 ASR provider id（由 ASRStage 写入），用于历史与指标。
    var usedProviderID: String?

    /// 前台上下文文本（由 ContextStage / ContextProvider 写入；nil 表示未采集）。
    var foregroundContextText: String?

    /// 用户停止录音的时刻（用于 stopToInjectMs）。
    var stopRecordingAt: Date?

    /// 各段耗时（毫秒）。
    var asrMs: Int?
    var polishMs: Int?
    var injectMs: Int?

    /// Guard to prevent double-injection.
    var hasInjected: Bool = false

    /// The target application that was frontmost when recording started.
    var targetApp: NSRunningApplication?

    // MARK: - Real-time Recording State

    /// Current frequency spectrum (updated by RecordingStage during recording).
    var currentSpectrum: [Float] = []

    /// Current AppleSpeech preview text (updated by RecordingStage during recording).
    /// 不再上屏，仅作 ASR 全部候选失败时的内部兜底来源。
    var currentPreviewText: String = ""

    /// Publisher for real-time spectrum updates (bypasses 1s timer polling).
    let spectrumPublisher = PassthroughSubject<[Float], Never>()

    // MARK: - Initialization

    init(sessionID: UInt64, statePublisher: PassthroughSubject<SessionState, Never>) {
        self.sessionID = sessionID
        self.statePublisher = statePublisher
    }
}
