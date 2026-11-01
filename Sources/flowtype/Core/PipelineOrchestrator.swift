import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - Session State

enum SessionState: Equatable {
    case idle
    case preparing
    case recording(elapsedSeconds: Int)
    case processing(provider: String)
    case polishing(preview: String)
    case injecting
    case notice(String)   // 温和提示(如润色降级):无按钮、短暂自动消失
    case error(String)
}

/// User-facing copy for terminal delivery and accuracy fallbacks. These strings
/// describe the recovery action available to the user; they never imply that a
/// dispatched keyboard or paste event was confirmed by the target application.
enum DeliveryCopy: Equatable, Sendable {
    case focusChanged
    case clipboardRecovery
    case clipboardOwnershipChanged
    case uncertainDispatch
    case literalPreservationFallback

    var message: String {
        switch self {
        case .focusChanged: return "焦点已变化 · 已复制，按 ⌘V 粘贴"
        case .clipboardRecovery: return "已复制，按 ⌘V 粘贴"
        case .clipboardOwnershipChanged: return "剪贴板已变化 · 可从历史复制"
        case .uncertainDispatch: return "已发送 · 可从历史复制"
        case .literalPreservationFallback: return "技术内容已保留 · 已使用识别结果"
        }
    }

    /// Map an explicit terminal outcome to copy. Typed/paste-dispatched outcomes
    /// intentionally have no copy because the event was attempted only once.
    nonisolated static func forOutcome(_ outcome: DeliveryOutcome, focusChanged: Bool = false) -> DeliveryCopy? {
        switch outcome {
        case .clipboard: return focusChanged ? .focusChanged : .clipboardRecovery
        case .uncertain: return .uncertainDispatch
        case .typedDispatched, .pasteDispatched, .cancelled: return nil
        }
    }
}

/// External session effects are replaceable without changing pipeline ownership or transitions.
@MainActor
struct SessionEffects {
    var prepare: @MainActor @Sendable () -> Void
    var showWindow: @MainActor @Sendable () -> Void
    var hideWindow: @MainActor @Sendable () -> Void
    var saveHistory: (@MainActor @Sendable (SessionContext) -> Void)? = nil

    static let live = SessionEffects(prepare: {
        Task { @MainActor in
            ASRRouter.shared.startProbing()
            let cfg = ConfigurationStore.shared.current
            guard cfg.asrRoutingPolicy != .cloudOnly else { return }
            await QwenModelState.shared.loadModel(provider: ASRProviderRegistry.shared.qwenLocalProvider)
        }
    }, showWindow: { WindowManager.shared.showWindow() }, hideWindow: { WindowManager.shared.hide() })
}

// MARK: - Session Controller

@MainActor
final class SessionController: ObservableObject {
    static let shared = SessionController()

    private let pipeline: [PipelineStage]
    private let observers: [SessionObserver]
    private let effects: SessionEffects
    private let configurationStore: ConfigurationStore
    private let refreshReadiness: @MainActor () -> ReadinessLevel
    private let asrRegistry = ASRProviderRegistry.shared

    var qwenProvider: QwenASRProvider { asrRegistry.qwenLocalProvider }

    // MARK: - Published State

    @Published private(set) var sessionState: SessionState = .idle
    @Published private(set) var spectrum: [Float] = []
    @Published private(set) var lastErrorRawText: String?
    @Published private(set) var errorActions: [ErrorAction] = []

    // MARK: - Session Identity

    private var sessionID: UInt64 = 0
    private var activeSessionID: UInt64 = 0
    private var currentContext: SessionContext?

    // MARK: - Error Recovery

    private var suspendedContext: ErrorRecoveryContext?
    private var suspendedPayload: StagePayload?
    private var suspendedStageIndex: Int?

    // MARK: - Timer

    private var recordingTimer = CancellableTimer()
    private var elapsedSeconds: Int = 0

    // MARK: - Tasks

    private var currentTask: Task<Void, Never>?
    private var errorDismissTask: Task<Void, Never>?

    // MARK: - Combine

    private var stateCancellable: AnyCancellable?
    private var spectrumCancellable: AnyCancellable?
    private var readinessCancellable: AnyCancellable?

    // MARK: - Computed

    var isRecording: Bool {
        if case .recording = sessionState { return true }
        return false
    }

    var isPreparing: Bool {
        if case .preparing = sessionState { return true }
        return false
    }

    var isProcessing: Bool {
        if case .processing = sessionState { return true }
        return false
    }

    // MARK: - Initialization

    init(
        pipeline: [PipelineStage] = PipelineRegistry.defaultPipeline(),
        observers: [SessionObserver] = PipelineRegistry.defaultObservers(),
        effects: SessionEffects = .live,
        configurationStore: ConfigurationStore = .shared,
        refreshReadiness: @escaping @MainActor () -> ReadinessLevel = {
            ReadinessMonitor.shared.refresh()
            return ReadinessMonitor.shared.rawLevel
        }
    ) {
        self.pipeline = pipeline
        self.observers = observers

        self.effects = effects
        self.configurationStore = configurationStore
        self.refreshReadiness = refreshReadiness
        effects.prepare()
    }

    // MARK: - Public API

    func startRecording() {
        let newID = nextSessionID()
        AppLogger.log("[SessionController#\(newID)] startRecording requested")

        switch sessionState {
        case .idle, .error, .notice:
            break
        default:
            AppLogger.log("[SessionController#\(newID)] REJECTED: state=\(sessionState)")
            return
        }

        errorDismissTask?.cancel()
        errorDismissTask = nil
        // Starting fresh from .error/.notice must not carry over the previous
        // session's recovery state (suspended payload, error actions).
        clearSuspension()

        currentTask?.cancel()
        currentTask = nil
        currentContext?.cancel()

        activeSessionID = newID

        // Create session context
        let statePublisher = PassthroughSubject<SessionState, Never>()
        let context = SessionContext(sessionID: newID, statePublisher: statePublisher)
        currentContext = context

        // Reset state
        spectrum = []

        // Subscribe to state publisher for intermediate updates from stages
        stateCancellable = statePublisher
            .filter { state in
                // Timer handles recording state; orchestrator handles injecting
                if case .recording = state { return false }
                if case .injecting = state { return false }
                return true
            }
            .sink { [weak self] state in
                guard let self else { return }
                guard let ctx = self.currentContext,
                      Self.shouldAcceptEvent(activeSessionID: self.activeSessionID,
                                             eventSessionID: newID,
                                             isCancelled: ctx.isCancelled) else { return }
                self.transition(to: state, context: ctx)
            }

        readinessCancellable = context.readinessPublisher
            .sink { [weak self] in
                guard let self,
                      let ctx = self.currentContext,
                      Self.shouldAcceptEvent(activeSessionID: self.activeSessionID,
                                             eventSessionID: newID,
                                             isCancelled: ctx.isCancelled),
                      ctx.isReady else { return }
                ctx.recordingStartTime = Date()
                self.transition(to: Self.stateForAudioReadiness(isReady: true), context: ctx)
                self.startRecordingTimer(sessionID: newID, context: ctx)
            }

        // Subscribe to real-time spectrum publisher (avoids 1Hz timer polling)
        spectrumCancellable = context.spectrumPublisher
            .sink { [weak self] spec in
                guard let self,
                      Self.shouldAcceptEvent(activeSessionID: self.activeSessionID,
                                             eventSessionID: newID,
                                             isCancelled: context.isCancelled) else { return }
                self.spectrum = spec
            }
        // 录音中不再向 UI 推送预览文字（预览仅作 ASR 失败时的内部兜底）。

        transition(to: Self.stateForAudioReadiness(isReady: false), context: context)
        effects.showWindow()

        executeStage(at: 0, payload: .empty, context: context)
    }

    func endRecording() {
        OptionTapDetector.shared.cancelPendingTaps()
        let withPolish = ConfigurationStore.shared.current.polishOnStop
        AppLogger.log("[SessionController#\(activeSessionID)] endRecording called, withPolish=\(withPolish)")

        if isPreparing {
            guard let context = currentContext else { return }
            context.cancel()
            currentTask?.cancel()
            currentTask = nil
            resetToIdle()
            AppLogger.log("[SessionController#\(activeSessionID)] stop during preparation — capture cancelled")
            return
        }

        guard isRecording else {
            AppLogger.log("[SessionController#\(activeSessionID)] endRecording: not recording, ignoring")
            return
        }

        guard let context = currentContext else { return }

        context.usePolish = withPolish
        stopRecordingTimer()

        // All stop-to-delivery work shares one monotonic 20 second budget.
        // Stages derive their own bounded timeout from this snapshot.
        context.completionBudget = CompletionBudget(seconds: 20)
        context.stopRecordingAt = Date()
        context.targetApp = NSWorkspace.shared.frontmostApplication
        context.captureDeliveryTarget(pid: context.targetApp?.processIdentifier)

        currentTask?.cancel()
        currentTask = nil

        // ASRStage 会随后用真实 provider 名刷新 .processing(provider:) 状态。
        transition(to: .processing(provider: "识别中"), context: context)
    }

    func cancel() {
        AppLogger.log("[SessionController#\(activeSessionID)] cancel called, state=\(sessionState)")
        let cancelledContext = currentContext
        cancelledContext?.cancel()
        // A paste/key event can already have escaped when cancellation arrives.
        // Persist that uncertain terminal outcome once for recovery/metrics while
        // suppressing all stale UI/state publication below.
        if let cancelledContext, cancelledContext.deliveryOutcome == .uncertain {
            saveHistory(context: cancelledContext)
        }
        // Invalidate ownership before cancellation can resume a stage on another executor.
        activeSessionID = 0
        currentTask?.cancel()
        currentTask = nil

        resetToIdle()
        AppLogger.log("[SessionController] Cancelled — session reset to idle")
    }

    func retryFailedStage() {
        guard case .error = sessionState else {
            AppLogger.log("[SessionController] retryFailedStage: not in error state")
            return
        }
        guard suspendedContext != nil else {
            AppLogger.log("[SessionController] retryFailedStage: no recovery context")
            return
        }
        guard suspendedContext?.retryable == true else {
            AppLogger.log("[SessionController] retryFailedStage: recovery is copy/dismiss only")
            return
        }
        guard let payload = suspendedPayload else {
            AppLogger.log("[SessionController] retryFailedStage: no suspended payload")
            return
        }
        guard let stageIndex = suspendedStageIndex else {
            AppLogger.log("[SessionController] retryFailedStage: no suspended stage index")
            return
        }
        guard let context = currentContext else {
            AppLogger.log("[SessionController] retryFailedStage: no current context")
            return
        }

        AppLogger.log("[SessionController#\(activeSessionID)] Retrying failed stage...")

        errorDismissTask?.cancel()
        errorDismissTask = nil

        clearSuspension()

        context.completionBudget = CompletionBudget(seconds: 20)
        context.realtimeResult = nil
        // Retry the suspended stage with the original session policy.
        // A failed ASR attempt must not opt the user into polish.
        let retryState: SessionState = pipeline[stageIndex].name == PolishStage.stageName
            ? .polishing(preview: "") : .processing(provider: "识别中")
        transition(to: retryState, context: context)
        executeStage(at: stageIndex, payload: payload, context: context)
    }

    private func clearSuspension() {
        lastErrorRawText = nil
        errorActions = []
        suspendedContext = nil
        suspendedPayload = nil
        suspendedStageIndex = nil
    }

    func dismissError() {
        guard case .error = sessionState else { return }
        errorDismissTask?.cancel()
        errorDismissTask = nil
        clearSuspension()
        resetToIdle()
    }

    func recheckReadiness() {
        guard !refreshReadiness().isBlocked else {
            AppLogger.log("[SessionController] Readiness recheck remains blocked")
            return
        }
        dismissError()
    }

    func useAutomaticRouting() {
        var config = configurationStore.current
        config.asrRoutingPolicy = .auto
        configurationStore.save(config)
        _ = refreshReadiness()
        dismissError()
    }

    func copyRawText() {
        guard let rawText = suspendedContext?.rawText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rawText, forType: .string)
    }

    // MARK: - Orchestration

    private func executeStage(at index: Int, payload: StagePayload, context: SessionContext) {
        guard activeSessionID == context.sessionID, !context.isCancelled else {
            AppLogger.log("[SessionController] Session \(context.sessionID) no longer active, aborting pipeline")
            return
        }
        guard index < pipeline.count else {
            return finish(context: context)
        }

        let stage = pipeline[index]

        // Pre-stage state transitions
        if stage is InjectionStage {
            transition(to: .injecting, context: context)
        }

        let task = Task { [weak self] in
            guard let self else { return }
            let result = await stage.executeIfOwned(payload: payload, context: context)

            guard self.activeSessionID == context.sessionID, !context.isCancelled else {
                AppLogger.log("[SessionController] Session \(context.sessionID) no longer active, ignoring stage result")
                return
            }

            switch result {
            case .continue(let nextPayload):
                // Extract text for history tracking
                switch nextPayload {
                case .processed(_, let raw):
                    context.rawTranscript = raw
                case .polished(let final, let raw):
                    context.rawTranscript = raw
                    context.finalText = final
                default:
                    break
                }
                self.executeStage(at: index + 1, payload: nextPayload, context: context)

            case .skip(let targetName, let nextPayload):
                if let targetIndex = self.pipeline.firstIndex(where: { $0.name == targetName }) {
                    self.executeStage(at: targetIndex, payload: nextPayload, context: context)
                } else {
                    // Invalid internal routing has no retry/copy recovery payload.
                    AppLogger.log("[SessionController] internal: unknown skip target '\(targetName)' — failing session \(context.sessionID)")
                    self.transition(to: .notice("internal: unknown stage '\(targetName)'"), context: context)
                }

            case .suspend(let recovery):
                if recovery.error is CancellationError {
                    self.resetToIdle()
                } else {
                    let actions = Self.buildErrorActions(from: recovery)
                    if actions.isEmpty {
                        self.transition(to: .notice(recovery.error.localizedDescription), context: context)
                    } else {
                        self.suspendedContext = recovery
                        self.suspendedPayload = payload
                        self.suspendedStageIndex = index
                        self.lastErrorRawText = recovery.rawText
                        self.errorActions = actions
                        self.transition(to: .error(recovery.error.localizedDescription), context: context)
                    }
                }

            case .notice(let message):
                // Gentle degradation (no error UI): e.g. ASR had no provider available or
                // recognized no speech. transition(to: .notice) auto-dismisses after ~2.2s.
                AppLogger.log("[SessionController#\(context.sessionID)] Stage returned notice: \(message)")
                self.transition(to: .notice(message), context: context)

            case .complete:
                self.finish(context: context)
            }
        }

        currentTask = task
    }

    /// All terminal delivery paths converge here; no optional-stage failure saves early.
    private func finish(context: SessionContext) {
        guard activeSessionID == context.sessionID, !context.isCancelled else { return }
        if context.hasInjected { saveHistory(context: context) }
        let state = context.hasInjected ? context.completionNotice.map(SessionState.notice) ?? .idle : .idle
        transition(to: state, context: context)
    }

    // MARK: - State Transition

    private func transition(to newState: SessionState, context: SessionContext) {
        let oldState = sessionState
        sessionState = newState
        if newState.showPanel { effects.showWindow() }
        observers.forEach { $0.sessionDidTransition(from: oldState, to: newState, context: context) }

        // Hide the capsule when the session finishes normally (slides down). resetToIdle()
        // covers the cancel/error paths; the normal .complete → .idle path needs this.
        if case .idle = newState {
            // A completed session is no longer allowed to publish readiness/state
            // events. Invalidate ownership before any late callback can resurrect it.
            context.cancel()
            activeSessionID = 0
            effects.hideWindow()
        }

        // Auto-dismiss the gentle notice after ~2.2s (no buttons; slides away like a normal finish).
        if case .notice = newState {
            context.cancel()
            activeSessionID = 0
            errorDismissTask?.cancel()
            let noticeSessionID = activeSessionID
            errorDismissTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 2_200_000_000) } catch { return }
                guard let self else { return }
                if case .notice = self.sessionState, self.activeSessionID == noticeSessionID {
                    self.resetToIdle()
                }
            }
        }

        // Actionable recovery stays visible until retry, copy/dismiss, or a new session.
        if case .error = newState {
            errorDismissTask?.cancel()
            errorDismissTask = nil
        }
    }

    // MARK: - Error Actions

    nonisolated static func readinessActions(for issue: ReadinessIssue,
                                             policy: ASRRoutingPolicy) -> [ErrorAction] {
        switch issue {
        case .microphoneDenied:
            return [.openMicrophoneSettings, .recheckReadiness, .dismiss]
        case .noEngine:
            return [.openASRSettings, policy == .auto ? .recheckReadiness : .useAutomaticRouting, .dismiss]
        case .accessibilityMissing:
            return [.openAccessibilitySettings, .recheckReadiness, .dismiss]
        default:
            return [.recheckReadiness, .dismiss]
        }
    }

    nonisolated static func buildErrorActions(from recovery: ErrorRecoveryContext) -> [ErrorAction] {
        guard !(recovery.error is CancellationError) else { return [] }
        let hasText = recovery.rawText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard recovery.retryable || hasText else { return [] }
        var actions: [ErrorAction] = []
        if recovery.retryable { actions.append(.retry(stage: recovery.failedStage)) }
        if hasText {
            // Delivery failures carry the final polished result. Keep their
            // recovery action explicit so the capsule never offers a hidden
            // retry after a paste transaction refused to dispatch.
            if recovery.error is InjectionStageError {
                actions.append(.copyResult)
            } else {
                actions.append(.copyRaw)
            }
        }
        actions.append(.dismiss)
        return actions
    }

    // MARK: - Timer

    private func startRecordingTimer(sessionID: UInt64, context: SessionContext) {
        elapsedSeconds = 0
        let maxDuration = ConfigurationStore.shared.current.maxRecordingDuration
        recordingTimer.schedule(withTimeInterval: 1.0, repeats: true) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      Self.shouldAcceptTimerTick(activeSessionID: self.activeSessionID,
                                                 tickSessionID: sessionID,
                                                 isCancelled: context.isCancelled,
                                                 isRecording: self.isRecording),
                      self.currentContext === context else { return }
                self.elapsedSeconds += 1
                self.sessionState = .recording(elapsedSeconds: self.elapsedSeconds)

                // Auto-stop at max duration
                if self.elapsedSeconds >= maxDuration {
                    AppLogger.log("[SessionController] Recording reached max duration (\(maxDuration)s), auto-stopping")
                    self.endRecording()
                }
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer.cancel()
        elapsedSeconds = 0
    }

    // MARK: - History

    /// History label for a finished session: `.polish` only when polish was requested AND succeeded.
    /// A degraded (failed-polish) session is stored as `.raw` — its text is the un-polished original.
    nonisolated static func historyMode(usePolish: Bool, polishFailed: Bool) -> PolishMode {
        (usePolish && !polishFailed) ? .polish : .raw
    }

    /// sttBackend 文案：不再依赖 provider 类型判断。
    nonisolated static func backendLabel(forProviderID id: String?) -> String {
        switch id {
        case ASRProviderID.qwenLocal: return "qwen"
        case ASRProviderID.cloud: return "cloud"
        default: return "apple"
        }
    }

    /// Compatibility text mapping for optional-polish failure. The recovery context's
    /// rawText is the PRE-PostProcess transcript; the suspended payload's `.processed` text carries
    /// the punctuation/term fixes the user already benefits from on the success path — prefer it
    /// for finalText so degraded history matches polish-disabled history in quality.
    nonisolated static func degradedPolishTexts(payload: StagePayload, recoveryRaw: String) -> (raw: String, final: String) {
        if case .processed(let processed, _) = payload, !processed.isEmpty {
            return (recoveryRaw, polishFallbackText(processed: processed, raw: recoveryRaw))
        }
        return (recoveryRaw, recoveryRaw)
    }

    private func saveHistory(context: SessionContext) {
        guard context.claimHistorySave() else { return }
        if let saveHistory = effects.saveHistory { saveHistory(context); return }
        let durationMs: UInt64?
        if let recStart = context.recordingStartTime {
            durationMs = UInt64(Date().timeIntervalSince(recStart) * 1000)
        } else {
            durationMs = nil
        }
        let mode: PolishMode = SessionController.historyMode(usePolish: context.usePolish, polishFailed: context.polishFailed)
        let sttBackend = SessionController.backendLabel(forProviderID: context.usedProviderID)
        var session = DictationSession(
            rawTranscript: context.rawTranscript,
            finalText: context.finalText,
            polishMode: mode,
            durationMs: durationMs,
            recordingMs: context.recordingMs,
            appName: context.targetApp?.localizedName,
            appBundleID: context.targetApp?.bundleIdentifier,
            language: detectLanguageTag(context.finalText),
            sttBackend: sttBackend
        )
        session.asrProviderID = context.usedProviderID
        session.usedFallback = context.usedFallback
        session.fallbackReason = context.fallbackReason
        session.asrMs = context.asrMs
        session.polishMs = context.polishMs
        session.injectMs = context.injectMs
        session.deliveryOutcome = context.deliveryOutcome
        session.stopToDeliveryMs = context.stopToDeliveryMs
        if let stopAt = context.stopRecordingAt, context.injectMs != nil {
            session.stopToInjectMs = Int(Date().timeIntervalSince(stopAt) * 1000)
        }
        HistoryStore.shared.append(session, storeText: ConfigurationStore.shared.current.storeTranscriptText)

        // Auto-detect corrections for dictionary
        if context.rawTranscript != context.finalText {
            let raw = context.rawTranscript
            let polished = context.finalText
            detectAndAddCorrections(raw: raw, final: polished)
        }

        let hitIds = DictionaryStore.shared.detectHits(in: context.finalText)
        DictionaryStore.shared.incrementHits(ids: hitIds)

        AppLogger.log("[SessionController] History saved, dict hits: \(hitIds.count)")
    }

    private func detectAndAddCorrections(raw: String, final: String) {
        for word in SessionController.correctionCandidates(raw: raw, final: final) {
            DictionaryStore.shared.addAutoDetected(phrase: word)
        }
    }

    /// Sentence punctuation for the auto-dictionary guard. Word-interior ASCII tech
    /// characters (Node.js, tree-sitter, C#, snake_case, C++) are NOT sentence punctuation —
    /// they must stay enrollable. CJK 标点（，。？！、…）remain in the set, which is what
    /// rejects unsegmented Chinese sentences.
    private nonisolated static let sentencePunctuation: CharacterSet = {
        var set = CharacterSet.punctuationCharacters
        set.remove(charactersIn: ".-_#+")
        return set
    }()

    /// Sentence-edge punctuation stripped from token boundaries before diffing.
    /// Deliberately excludes # _ - + so "C#" keeps its #; a trailing . or 。 is
    /// sentence-final and safe to strip (interior dots as in Node.js are untouched).
    private nonisolated static let edgePunctuation = CharacterSet(charactersIn: "，。？！、；：…,.!?;:()[]{}（）【】「」『』\"'\u{201C}\u{201D}\u{2018}\u{2019}")

    /// Word-level diff for auto-detected dictionary corrections: words in `final` absent from `raw`.
    /// Whitespace tokenization means an unsegmented Chinese sentence arrives as ONE token — without
    /// the guards below, PostProcess adding a single 。 would enroll the whole sentence as a "term",
    /// permanently polluting the ASR bias context (composeASRContext caps at 50 phrases / 300 chars).
    nonisolated static func correctionCandidates(raw: String, final: String) -> [String] {
        let rawWords = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let finalWords = final.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

        // Edge punctuation is trimmed on BOTH sides of the diff so "world." matches "world"
        // and a sentence that merely gained a trailing 。 still matches its raw form.
        let rawSet = Set(rawWords.map { $0.trimmingCharacters(in: Self.edgePunctuation).lowercased() })
        var candidates: [String] = []
        for token in finalWords {
            let word = token.trimmingCharacters(in: Self.edgePunctuation)
            guard word.count >= 2 else { continue }
            // Interior sentence punctuation means this token is a sentence, not a term.
            if word.rangeOfCharacter(from: Self.sentencePunctuation) != nil { continue }
            // Genuine Chinese tech terms are short; longer CJK runs are sentence fragments.
            let containsCJK = word.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            if containsCJK && word.count > 7 { continue }
            let lower = word.lowercased()
            if !rawSet.contains(lower) {
                candidates.append(word)
            }
        }
        return candidates
    }

    // MARK: - Reset

    private func resetToIdle() {
        OptionTapDetector.shared.cancelPendingTaps()
        currentContext?.cancel()
        sessionState = .idle
        activeSessionID = 0
        currentContext = nil
        stateCancellable?.cancel()
        stateCancellable = nil
        spectrumCancellable?.cancel()
        spectrumCancellable = nil
        readinessCancellable?.cancel()
        readinessCancellable = nil
        lastErrorRawText = nil
        errorActions = []
        suspendedContext = nil
        suspendedPayload = nil
        suspendedStageIndex = nil
        currentTask?.cancel()
        currentTask = nil
        errorDismissTask?.cancel()
        errorDismissTask = nil
        stopRecordingTimer()
        spectrum = []
        effects.hideWindow()
    }

    // MARK: - Helpers

    private func nextSessionID() -> UInt64 {
        sessionID += 1
        return sessionID
    }
}

// MARK: - ErrorAction

extension SessionController {
    nonisolated static let stateBeforeAudioReady: SessionState = .preparing
    nonisolated static let stateAfterAudioReady: SessionState = .recording(elapsedSeconds: 0)

    nonisolated static func stateForAudioReadiness(isReady: Bool,
                                                   elapsedSeconds: Int = 0) -> SessionState {
        isReady ? .recording(elapsedSeconds: elapsedSeconds) : .preparing
    }

    nonisolated static func shouldAcceptEvent(activeSessionID: UInt64,
                                               eventSessionID: UInt64,
                                               isCancelled: Bool) -> Bool {
        activeSessionID != 0 && activeSessionID == eventSessionID && !isCancelled
    }

    nonisolated static func shouldAcceptTimerTick(activeSessionID: UInt64,
                                                   tickSessionID: UInt64,
                                                   isCancelled: Bool,
                                                   isRecording: Bool) -> Bool {
        shouldAcceptEvent(activeSessionID: activeSessionID,
                          eventSessionID: tickSessionID,
                          isCancelled: isCancelled) && isRecording
    }

    enum ErrorAction: Equatable, Hashable {
        case retry(stage: String)
        case copyRaw
        case copyResult
        case dismiss
        case openAccessibilitySettings
        case openMicrophoneSettings
        case openASRSettings
        case recheckReadiness
        case useAutomaticRouting

        var displayName: String {
            switch self {
            case .retry(let stage):
                switch stage {
                case "ASR": return "重试识别"
                case PolishStage.stageName: return "重试润色"
                case "Injection": return "重试输入"
                default: return "重试处理"
                }
            case .copyRaw: return "复制原文"
            case .copyResult: return "复制结果"
            case .dismiss: return "忽略"
            case .openAccessibilitySettings: return "打开辅助功能设置"
            case .openMicrophoneSettings: return "打开麦克风设置"
            case .openASRSettings: return "打开 ASR 设置"
            case .recheckReadiness: return "重新检测"
            case .useAutomaticRouting: return "改为自动路由"
            }
        }
    }
}

// MARK: - SessionState UI Properties

extension SessionState {

    var capsuleSize: NSSize {
        if case .error = self { return NSSize(width: 320, height: 94) }
        return NSSize(width: 240, height: 70)
    }

    var statusColor: Color {
        switch self {
        case .idle:       return Color.white.opacity(0.5)
        case .preparing:  return Color(red: 0.5, green: 0.3, blue: 1.0)
        case .recording:  return Color(red: 0.5, green: 0.3, blue: 1.0)
        case .processing, .polishing: return .blue
        case .injecting:  return .green
        case .notice:     return Color(red: 0.66, green: 0.61, blue: 1.0)  // 温和紫 #A99BFF,非红
        case .error:      return .red
        }
    }

    var statusTitle: String {
        switch self {
        case .idle:                      return "准备就绪"
        case .preparing:                 return "正在准备..."
        case .recording:                 return "Listening..."
        case .processing, .polishing:    return "处理中..."
        case .injecting:                 return "输入中..."
        case .notice(let msg):           return msg
        case .error:                     return "出错了"
        }
    }

    var isRecordingIndicator: Bool {
        if case .recording = self { return true }
        return false
    }

    var showSpinner: Bool {
        switch self {
        case .preparing, .processing, .polishing: return true
        default: return false
        }
    }

    var showPanel: Bool {
        switch self {
        case .idle: return false
        default: return true
        }
    }
}
