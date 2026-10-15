import Foundation
import Combine
import AppKit
import os

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

    /// Emits once, after the first non-empty PCM buffer reaches the recording stage.
    let readinessPublisher = PassthroughSubject<Void, Never>()

    /// True after capture has produced a valid audio buffer.
    private(set) var isReady = false

    /// Cancellation is owned by the controller. Stages and callbacks must check it
    /// before publishing state or advancing the pipeline.
    private(set) var isCancelled = false
    private struct DeliveryGateState { var cancelled = false; var effectStarted = false }
    private let cancellationLock = OSAllocatedUnfairLock(initialState: DeliveryGateState())

    /// Synchronous cancellation snapshot for audio callbacks, which cannot await
    /// the main actor before forwarding a PCM buffer.
    nonisolated var isCancellationRequested: Bool {
        cancellationLock.withLock { $0.cancelled }
    }

    /// Performs a short synchronous effect only while the session is active.
    /// Cancellation and an audio append serialize on this gate; work queued
    /// after cancellation cannot forward a buffer to the preview provider.
    @discardableResult
    nonisolated func performIfActive(_ action: () -> Void) -> Bool {
        cancellationLock.withLockUnchecked { cancelled in
            guard !cancelled.cancelled else { return false }
            action()
            return true
        }
    }

    /// The first irreversible action claims the latch inside the cancellation gate.
    /// Later balanced key pairs belong to this same attempt, never a fallback.
    nonisolated func performDeliveryEffect(_ action: () -> Void) -> Bool {
        cancellationLock.withLockUnchecked { state in
            guard !state.cancelled, !Task.isCancelled else { return false }
            state.effectStarted = true
            action()
            return true
        }
    }

    nonisolated var deliveryEffectStarted: Bool {
        cancellationLock.withLock { $0.effectStarted }
    }

    /// Raw transcript from ASR before any post-processing.
    var rawTranscript: String = ""

    /// Final text after all processing / polish, ready for injection.
    var finalText: String = ""

    /// Set when optional polish is unavailable or degraded (history then marks it .raw).
    var polishFailed: Bool = false

    /// Displayed only after the terminal delivery succeeds.
    var completionNotice: String?

    private var historySaved = false

    /// Completion can transition through a notice and then idle; persist only once.
    func claimHistorySave() -> Bool {
        guard !isCancelled, !historySaved, hasInjected, !finalText.isEmpty else { return false }
        historySaved = true
        return true
    }

    /// 本轮实际使用的 ASR provider id（由 ASRStage 写入），用于历史与指标。
    var usedProviderID: String?

    /// 前台上下文文本（由 ContextStage / ContextProvider 写入；nil 表示未采集）。
    var foregroundContext: ForegroundContext?
    var foregroundContextText: String? { buildContextText(foregroundContext) }
    private var foregroundCollectionTask: Task<Void, Never>?
    private var foregroundCollectionID = UUID()

    /// Starts alongside audio, never blocking capture or realtime preview setup.
    func startForegroundCollection(provider: ContextProvider = AXContextProvider()) {
        guard !isCancelled else { return }
        foregroundCollectionTask?.cancel()
        let ownership = UUID()
        foregroundCollectionID = ownership
        foregroundContext = nil
        foregroundCollectionTask = Task { [weak self] in
            let snapshot = try? await withAsyncDeadline(seconds: 0.5) { await provider.collect() }
            guard !Task.isCancelled, let self, !self.isCancelled,
                  self.foregroundCollectionID == ownership else { return }
            self.foregroundContext = boundedForegroundContext(snapshot)
            self.foregroundCollectionTask = nil
        }
    }

    private func cancelForegroundCollection() {
        foregroundCollectionID = UUID()
        foregroundCollectionTask?.cancel()
        foregroundCollectionTask = nil
        foregroundContext = nil
    }

    /// 用户停止录音的时刻（用于 stopToInjectMs）。
    var stopRecordingAt: Date?

    /// 各段耗时（毫秒）。
    var asrMs: Int?
    var polishMs: Int?
    var injectMs: Int?
    var stopToDeliveryMs: Int?
    var deliveryEventDispatchedAt: Date?

    /// 本轮是否发生降级（候选失败后改用后备，或最终用了 AppleSpeech 预览兜底）。
    var usedFallback: Bool = false
    /// 降级原因：`network` / `timeout` / `unavailable` / `error` / `preview`。
    var fallbackReason: String?

    // MARK: - Capture-start ASR routing and realtime fan-out

    /// Immutable route/config identity selected before the audio engine starts.
    var captureRoute: ASRRouteSnapshot?
    /// Live realtime handle owned by this session, if the capture-start route
    /// selected a realtime profile. The ingress itself is synchronous and is
    /// called from the audio callback without creating a Task per buffer.
    var realtimeHandle: RealtimeASRSessionHandle?
    var realtimeResult: ASRResult?
    var realtimeFailureReason: String?
    var completionBudget: CompletionBudget?

    var realtimeStartTask: Task<Void, Error>?
    private let realtimeFailureLock = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Installs and starts the live session before capture. This never awaits
    /// network readiness; the bounded ingress accepts early buffers.
    func prepareRealtime(route: ASRRouteSnapshot,
                         factory: RealtimeSessionFactory = liveRealtimeSessionFactory) {
        guard !isCancelled else { return }
        captureRoute = route
        guard route.shouldStartRealtime, let cloud = route.cloudConfiguration else { return }
        do {
            let config = try RealtimeASRConfiguration(provider: cloud.provider, apiKey: cloud.apiKey, language: route.language)
            let handle = factory(config)
            realtimeHandle = handle
            realtimeStartTask = Task { try await handle.session.start() }
        } catch { realtimeFailureReason = error.localizedDescription }
    }

    /// A retry cannot reuse a terminated live handle.
    func takeRealtimeAttempt() -> (RealtimeASRSessionHandle, Task<Void, Error>?)? {
        guard let handle = realtimeHandle else { return nil }
        realtimeHandle = nil
        let start = realtimeStartTask
        realtimeStartTask = nil
        return (handle, start)
    }

    nonisolated func markRealtimeFailure(_ reason: String) {
        realtimeFailureLock.withLock { current in
            if current == nil { current = reason }
        }
    }

    nonisolated func realtimeFailureSnapshot() -> String? {
        realtimeFailureLock.withLock { $0 }
    }

    func syncRealtimeFailure() {
        if let reason = realtimeFailureSnapshot() {
            realtimeFailureReason = reason
        }
    }

    func setRealtimeResult(_ result: ASRResult) {
        guard !isCancelled else { return }
        // Exactly one terminal winner per session.
        guard realtimeResult == nil else { return }
        realtimeResult = result
    }

    /// Reserves one terminal attempt; preparation is not an irreversible effect.
    private(set) var deliveryAttempted = false
    private(set) var deliveryOutcome: DeliveryOutcome?
    /// Legacy read-only terminal flag; event dispatch is never insertion confirmation.
    var hasInjected: Bool { deliveryOutcome?.isTerminalDelivery == true }

    func beginDeliveryAttempt() -> Bool {
        guard !isCancelled, !deliveryAttempted else { return false }
        deliveryAttempted = true
        return true
    }

    func finishDelivery(_ outcome: DeliveryOutcome) {
        guard deliveryOutcome == nil else { return }
        deliveryOutcome = outcome
    }

    var deliveryTarget: DeliveryTargetSnapshot?
    private var deliveryTargetTask: Task<DeliveryTargetSnapshot, Never>?

    /// PID is captured synchronously by the stop handler. AX work cannot select
    /// a different app after this point, and a cancelled session drops its result.
    func captureDeliveryTarget(pid: Int32?,
        collect: @escaping @Sendable (Int32?) async -> DeliveryTargetSnapshot = { await KeyboardInjector.deliveryTarget(pid: $0) }) {
        guard !isCancelled, deliveryTarget == nil else { return }
        deliveryTarget = DeliveryTargetSnapshot(pid: pid)
        deliveryTargetTask = Task { await collect(pid) }
    }

    func resolvedDeliveryTarget() async -> DeliveryTargetSnapshot? {
        guard !isCancelled else { return nil }
        if let task = deliveryTargetTask {
            let result = await task.value
            guard !isCancelled else { return nil }
            // Ignore an invalid provider result rather than changing the stop PID.
            if result.pid == deliveryTarget?.pid { deliveryTarget = result }
            deliveryTargetTask = nil
        }
        return deliveryTarget
    }

    /// The target application that was frontmost when recording stopped.
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

    init(sessionID: UInt64,
         statePublisher: PassthroughSubject<SessionState, Never> = PassthroughSubject()) {
        self.sessionID = sessionID
        self.statePublisher = statePublisher
    }

    /// Marks microphone capture ready exactly once. Late callbacks after cancellation
    /// are ignored, so an old session cannot make a new UI session look recording.
    func markReady() {
        guard !isCancelled, !isReady else { return }
        isReady = true
        readinessPublisher.send(())
    }

    /// Invalidates all future stage results and readiness/state callbacks.
    func cancel() {
        isCancelled = true
        cancelForegroundCollection()
        cancellationLock.withLock { $0.cancelled = true }
        deliveryTargetTask?.cancel()
        deliveryTargetTask = nil
        realtimeHandle?.ingress.cancel()
        realtimeStartTask?.cancel()
        if let handle = realtimeHandle { Task { await handle.session.cancel() } }
        realtimeHandle = nil
        realtimeStartTask = nil
    }
}
