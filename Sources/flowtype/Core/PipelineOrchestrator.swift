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
        case .uncertainDispatch: return "已发送，但无法确认是否插入；可从历史复制"
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
        guard RuntimeEnvironment.current.role == .app else { return }
        Task { @MainActor in
            ASRRouter.shared.startProbing()
            let cfg = ConfigurationStore.shared.current
            guard cfg.asrRoutingPolicy != .cloudOnly else { return }
            await QwenModelState.shared.loadModel()
        }
    }, showWindow: {
        guard ValidationEffects.live.allow(.window) else { return }
        WindowManager.shared.showWindow()
    }, hideWindow: {
        guard ValidationEffects.live.allow(.window) else { return }
        WindowManager.shared.hide()
    })
}

// MARK: - Session Controller

@MainActor
final class SessionController: ObservableObject {
    static let shared = SessionController()

    private let presentationTiming: CapsulePresentationTiming
    private var noticeValue: CapsuleNotice?
    private var slowValue = false
    var capsulePresentation: CapsulePresentation {
        CapsulePresentation(state: sessionState, preparationNotice: preparationNotice, notice: noticeValue,
            slow: slowValue, recoveryCard: recoveryCard, resourceBusyNotice: resourceBusyNotice,
            maxRecordingDuration: configurationStore.current.maxRecordingDuration)
    }

    private let purpose: SessionPurpose
    private let resources: SessionResourceCoordinator
    private let resourceOwner = UUID()
    private var resourceLease: SessionResourceLease?
    private var startAttempt: UUID?

    private let pipeline: [PipelineStage]
    private let observers: [SessionObserver]
    private let recoveryEffects: RecoveryEffects
    private var recoveryState = SessionRecoveryState()
    private let effects: SessionEffects
    private let configurationStore: ConfigurationStore
    private let refreshReadiness: @MainActor () -> ReadinessLevel
    private let readinessLevel: @MainActor @Sendable () -> ReadinessLevel

    // MARK: - Published State

    // Canonical presentation is committed before Combine invokes any subscriber.
    // The subject carries a notification generation, never lifecycle authority.
    private var stateValue: SessionState = .idle
    private var presentationGeneration: UInt64 = 0
    private let presentationChanges = CurrentValueSubject<UInt64, Never>(0)
    var sessionState: SessionState { stateValue }
    var sessionStatePublisher: AnyPublisher<SessionState, Never> {
        presentationChanges.compactMap { [weak self] generation in
            guard let self, self.presentationGeneration == generation else { return nil }
            return self.stateValue
        }.eraseToAnyPublisher()
    }
    var recoveryCardPublisher: AnyPublisher<RecoveryCard?, Never> {
        presentationChanges.compactMap { [weak self] generation -> SessionRecoveryState? in
            guard let self, self.presentationGeneration == generation else { return nil }
            return self.recoveryState
        }.map(\.card).removeDuplicates().eraseToAnyPublisher()
    }
    @Published private(set) var spectrum: [Float] = []
    // Guard explicit publication before assigning: @Published willSet can restore
    // stale energy after a synchronous subscriber cancels or starts another session.
    private var visualizationValue = AudioVisualizationFrame.silence
    var visualizationFrame: AudioVisualizationFrame { visualizationValue }
    var lastErrorRawText: String? { recoveryState.copyText }
    var recoveryCard: RecoveryCard? { recoveryState.card }
    var errorActions: [ErrorAction] { recoveryState.card?.presentation.actions ?? [] }
    @Published private(set) var preparationNotice: String?
    @Published private(set) var lastDeliverySummary: LastDeliverySummary?
    private var claimedDeliverySummary: LastDeliverySummary?

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
    private var noticeDismissToken: UUID?
    private var slowProgressTask: Task<Void, Never>?
    private var slowOperation: (token: UUID, sessionID: UInt64, started: TimeInterval)?

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
        recoveryEffects: RecoveryEffects = .live,
        configurationStore: ConfigurationStore = .shared,
        refreshReadiness: @escaping @MainActor () -> ReadinessLevel = {
            ReadinessMonitor.shared.refresh()
            return ReadinessMonitor.shared.rawLevel
        },
        readinessLevel: @escaping @MainActor @Sendable () -> ReadinessLevel = {
            ReadinessMonitor.shared.refresh()
            return ReadinessMonitor.shared.rawLevel
        },
        presentationTiming: CapsulePresentationTiming = .init(),
        purpose: SessionPurpose = .dictation,
        resources: SessionResourceCoordinator = .shared
    ) {
        self.presentationTiming = presentationTiming
        self.purpose = purpose
        self.resources = resources
        self.pipeline = pipeline
        self.observers = observers

        self.recoveryEffects = recoveryEffects
        self.effects = effects
        self.configurationStore = configurationStore
        self.refreshReadiness = refreshReadiness
        self.readinessLevel = readinessLevel
        if purpose == .dictation { effects.prepare() }
    }

    deinit {
        currentTask?.cancel()
        errorDismissTask?.cancel()
        slowProgressTask?.cancel()
        let lease = resourceLease
        let context = currentContext
        Task { @MainActor in context?.cancel(); lease?.end() }
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

        guard startAttempt == nil else { return }
        let attempt = UUID()
        startAttempt = attempt
        guard let token = resources.acquire(owner: resourceOwner) else {
            startAttempt = nil
            presentResourceBusy()
            return
        }
        guard startAttempt == attempt else { resources.release(token: token); return }
        startAttempt = nil
        resourceLease = SessionResourceLease(token: token, resources: resources)

        invalidateNoticeDismissal()
        invalidateSlowProgress()
        noticeValue = nil
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

        let generation = presentationGeneration
        let readiness = readinessLevel()
        guard ownsActiveContext(context), presentationGeneration == generation else { return }
        if let issue = Self.readinessPreflight(readiness) {
            presentReadinessBlocked(issue, context: context)
            return
        }
        preparationNotice = Self.preparationSubtitle(for: readiness)
        guard ownsActiveContext(context), presentationGeneration == generation else { return }

        // Reset state
        visualizationValue = .silence
        spectrum = []
        guard ownsActiveContext(context), presentationGeneration == generation else { return }

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
                      ctx.isReady, self.isPreparing else { return }
                ctx.recordingStartTime = Date()
                let generation = self.presentationGeneration
                self.preparationNotice = nil
                guard self.ownsActiveContext(ctx), self.presentationGeneration == generation else { return }
                guard self.transition(to: Self.stateForAudioReadiness(isReady: true), context: ctx),
                      self.ownsActiveContext(ctx) else { return }
                self.startRecordingTimer(sessionID: newID, context: ctx)
            }

        // The same ordered frame updates absolute energy and legacy spectrum together.
        spectrumCancellable = context.visualizationPublisher
            .sink { [weak self] frame in
                guard let self,
                      Self.shouldAcceptEvent(activeSessionID: self.activeSessionID,
                                             eventSessionID: newID,
                                             isCancelled: context.isCancelled) else { return }
                guard self.sessionState.isRecordingIndicator else { return }
                let generation = self.presentationGeneration
                self.objectWillChange.send()
                guard self.ownsActiveContext(context), self.presentationGeneration == generation,
                      self.sessionState.isRecordingIndicator else { return }
                self.visualizationValue = frame
                self.spectrum = frame.spectrum
            }
        // 录音中不再向 UI 推送预览文字（预览仅作 ASR 失败时的内部兜底）。

        guard transition(to: Self.stateForAudioReadiness(isReady: false), context: context),
              ownsActiveContext(context) else { return }
        let preparingGeneration = presentationGeneration
        effects.showWindow()
        guard ownsActiveContext(context), presentationGeneration == preparingGeneration else { return }

        executeStage(at: 0, payload: .empty, context: context)
    }

    func endRecording() {
        if purpose == .dictation { OptionTapDetector.shared.cancelPendingTaps() }
        let withPolish = configurationStore.current.polishOnStop
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
        guard beginSlowProgress(context: context) else { return }
        if purpose == .dictation {
            context.targetApp = NSWorkspace.shared.frontmostApplication
            context.captureDeliveryTarget(pid: context.targetApp?.processIdentifier)
        }

        currentTask?.cancel()
        currentTask = nil

        // ASRStage 会随后用真实 provider 名刷新 .processing(provider:) 状态。
        transition(to: .processing(provider: "识别中"), context: context)
    }

    func cancel() {
        AppLogger.log("[SessionController#\(activeSessionID)] cancel called, state=\(sessionState)")
        startAttempt = nil
        let cancelledSessionID = activeSessionID
        let cancelledContext = currentContext
        cancelledContext?.cancel(recordPendingDelivery: cancelledContext?.sessionID == activeSessionID)
        // A paste/key event can already have escaped when cancellation arrives.
        // Persist that uncertain terminal outcome once for recovery/metrics while
        // suppressing all stale UI/state publication below.
        if let cancelledContext, cancelledContext.deliveryOutcome == .uncertain {
            saveHistory(context: cancelledContext)
            guard activeSessionID == cancelledSessionID, currentContext === cancelledContext else { return }
            recordLastDelivery(context: cancelledContext)
            guard activeSessionID == cancelledSessionID, currentContext === cancelledContext else { return }
        }
        // Invalidate ownership before cancellation can resume a stage on another executor.
        activeSessionID = 0
        currentTask?.cancel()
        currentTask = nil

        resetToIdle()
        AppLogger.log("[SessionController] Cancelled — session reset to idle")
    }

    /// Every action, including compatibility wrappers, enters this ownership gate.
    func performRecoveryAction(_ action: RecoveryAction, cardID: UUID) {
        guard case .error = sessionState, let card = recoveryState.card,
              card.id == cardID, card.sessionID == activeSessionID,
              card.presentation.actions.contains(action) else { return }
        switch action {
        case .retry:
            guard let recovery = suspendedContext, let payload = suspendedPayload,
                  let index = suspendedStageIndex, let context = currentContext,
                  context.sessionID == card.sessionID, !context.isCancelled,
                  pipeline.indices.contains(index), pipeline[index] is ASRStage,
                  case .audio(let samples, _) = payload, !samples.isEmpty,
                  !context.deliveryEventStarted,
                  recoveryPresentation(recovery, payload: payload, index: index, context: context).actions.contains(action)
            else { return }
            guard acquireRetryResource(context: context) else { return }
            clearSuspension()
            context.completionBudget = CompletionBudget(seconds: 20)
            guard beginSlowProgress(context: context) else { return }
            context.realtimeResult = nil
            guard transition(to: .processing(provider: "识别中"), context: context),
                  ownsActiveContext(context) else { return }
            executeStage(at: index, payload: payload, context: context)
        case .copyRaw, .copyResult:
            if let text = recoveryState.copyText { recoveryEffects.copyText(text) }
        case .openAccessibilitySettings: recoveryEffects.openAccessibilitySettings()
        case .openMicrophoneSettings: recoveryEffects.openMicrophoneSettings()
        case .openSpeechRecognitionSettings: recoveryEffects.openSpeechRecognitionSettings()
        case .openASRSettings: recoveryEffects.navigate(to: recoveryState.destination)
        case .viewHistory: recoveryEffects.navigate(to: .history())
        case .rerecord: startRecording()
        case .dismiss: resetToIdle()
        case .recheckReadiness: refreshRecoveryReadiness(cardID: cardID)
        case .useAutomaticRouting:
            do {
                try configurationStore.applyASRSettingsAction(.changePolicy(.auto),
                    activeNativeID: currentContext?.captureRoute?.localLease.map(ASRBackendID.init(nativeLease:)))
                refreshRecoveryReadiness(cardID: cardID)
            } catch {
                // The card remains visible and settings explain the unresolved selection.
                recoveryEffects.navigate(to: recoveryState.destination)
            }
        }
    }

    private func performCurrentAction(_ action: RecoveryAction) {
        guard let card = recoveryState.card else { return }
        performRecoveryAction(action, cardID: card.id)
    }

    func retryFailedStage() {
        guard let action = recoveryState.card?.presentation.actions.first(where: {
            if case .retry = $0 { return true }; return false
        }) else { return }
        performCurrentAction(action)
    }
    func dismissError() { performCurrentAction(.dismiss) }
    func recheckReadiness() { performCurrentAction(.recheckReadiness) }
    func useAutomaticRouting() { performCurrentAction(.useAutomaticRouting) }
    func copyRawText() {
        performCurrentAction(recoveryState.card?.presentation.actions.contains(.copyResult) == true ? .copyResult : .copyRaw)
    }

    private func refreshRecoveryReadiness(cardID: UUID) {
        guard let card = recoveryState.card, card.id == cardID,
              let context = currentContext, context.sessionID == activeSessionID else { return }
        let level = refreshReadiness()
        // Injected effects and readiness publishers may synchronously start another
        // session. A completed recheck still belongs to its original card.
        guard recoveryState.card?.id == cardID, activeSessionID == card.sessionID,
              currentContext === context, !context.isCancelled else { return }
        guard let issue = Self.readinessPreflight(level) else {
            resetToIdle()
            return
        }
        clearSuspension()
        presentReadinessBlocked(issue, context: context)
    }

    /// Clear every recovery value without notifying midway through a lifecycle mutation.
    /// The enclosing transition/reset publishes once the new state is committed.
    private func clearSuspension() {
        recoveryState = SessionRecoveryState()
        suspendedContext = nil
        suspendedPayload = nil
        suspendedStageIndex = nil
        presentationGeneration &+= 1
    }

    private func presentRecovery(_ presentation: FailurePresentation, copyText: String?, context: SessionContext,
                                 destination: ClientDestination? = nil) {
        guard activeSessionID == context.sessionID else { return }
        let card = RecoveryCard(id: UUID(), sessionID: context.sessionID, presentation: presentation)
        recoveryState = SessionRecoveryState(card: card, copyText: copyText,
            destination: destination ?? suspendedContext?.destination ?? .settings(.speech))
        transition(to: .error(presentation.message), context: context)
    }

    private func publishPresentation() {
        let generation = presentationGeneration
        // Each projection filters this generation when it reaches that subscriber.
        // If an earlier subscriber starts a newer session, later subscribers never
        // receive the superseded outer value after the nested notification.
        presentationChanges.send(generation)
        guard presentationGeneration == generation else { return }
        objectWillChange.send()
    }

    private func recoveryPresentation(_ recovery: ErrorRecoveryContext, payload: StagePayload,
                                      index: Int, context: SessionContext) -> FailurePresentation {
        let hasAudio: Bool
        if case .audio(let samples, _) = payload { hasAudio = !samples.isEmpty && pipeline[index] is ASRStage }
        else { hasAudio = false }
        return RecoveryPolicy.presentation(kind: recovery.failureKind, resources: RecoveryResources(
            stage: recovery.failedStage, hasAudio: hasAudio,
            textKind: recovery.rawText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? recovery.textKind : .none,
            deliveryEventStarted: context.deliveryEventStarted,
            routingPolicy: configurationStore.current.asrRoutingPolicy, hasHistory: false))
    }

    // MARK: - Orchestration

    private func executeStage(at index: Int, payload: StagePayload, context: SessionContext) {
        guard ownsActiveContext(context), let lease = resourceLease, lease.isActive else {
            AppLogger.log("[SessionController] Session \(context.sessionID) no longer active, aborting pipeline")
            return
        }
        guard index < pipeline.count else {
            return finish(context: context)
        }

        let stage = pipeline[index]

        // Pre-stage state transitions
        if stage is InjectionStage {
            // A synchronous subscriber may install a different recording task or
            // commit a newer presentation even within this same session.
            guard transition(to: .injecting, context: context),
                  ownsActiveContext(context) else { return }
        }

        guard ownsActiveContext(context), resourceLease === lease, lease.enterStage() else { return }
        let task = Task { [weak self, lease] in
            let result = await stage.executeIfOwned(payload: payload, context: context)
            lease.leaveStage()

            guard let self, self.resourceLease === lease, lease.isActive,
                  self.ownsActiveContext(context) else {
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
                if recovery.failureKind == .cancelled {
                    self.resetToIdle()
                } else {
                    self.suspendedContext = recovery
                    self.suspendedPayload = payload
                    self.suspendedStageIndex = index
                    self.presentRecovery(self.recoveryPresentation(recovery, payload: payload, index: index, context: context),
                                         copyText: recovery.rawText, context: context)
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
        guard ownsActiveContext(context) else { return }
        let generation = presentationGeneration
        var enteredHistory = false
        if context.hasInjected {
            enteredHistory = saveHistory(context: context)
            // Storage is an injected synchronous effect and may reenter cancel/start.
            // Never close the newer context or install this session's terminal card.
            guard ownsActiveContext(context), presentationGeneration == generation else { return }
            recordLastDelivery(context: context)
            guard ownsActiveContext(context), presentationGeneration == generation else { return }
        }
        if context.deliveryOutcome == .uncertain {
            let presentation = RecoveryPolicy.presentation(
                kind: context.deliveryEventStarted ? .deliveryUncertain : .deliveryBlocked,
                resources: .init(stage: "Injection", hasAudio: false,
                    textKind: context.finalText.isEmpty ? .none : .result,
                    deliveryEventStarted: context.deliveryEventStarted,
                    routingPolicy: configurationStore.current.asrRoutingPolicy, hasHistory: enteredHistory))
            context.cancel()
            currentContext = nil
            currentTask = nil
            stateCancellable?.cancel(); stateCancellable = nil
            spectrumCancellable?.cancel(); spectrumCancellable = nil
            readinessCancellable?.cancel(); readinessCancellable = nil
            stopRecordingTimer()
            visualizationValue = .silence
            spectrum = []
            guard activeSessionID == context.sessionID, presentationGeneration == generation else { return }
            clearSuspension()
            presentRecovery(presentation, copyText: context.finalText, context: context)
            return
        }
        let notice = CapsuleNotice.completion(outcome: context.deliveryOutcome, fallback: context.capsuleNotice)
        let state: SessionState = context.hasInjected && (context.completionNotice != nil || notice != nil)
            ? .notice(context.completionNotice ?? "") : .idle
        transition(to: state, context: context)
    }

    // MARK: - State Transition

    /// Whether this exact presentation survived all synchronous effects and
    /// subscribers. Callers with remaining lifecycle work must also own context.
    @discardableResult
    private func transition(to newState: SessionState, context: SessionContext) -> Bool {
        let oldState = sessionState
        stateValue = newState
        invalidateNoticeDismissal()
        switch newState {
        case .idle, .notice, .error, .preparing, .recording: invalidateSlowProgress()
        default: break
        }
        if case .notice = newState {
            noticeValue = CapsuleNotice.completion(outcome: context.deliveryOutcome, fallback: context.capsuleNotice)
        } else { noticeValue = nil }
        presentationGeneration &+= 1
        let generation = presentationGeneration
        if !newState.isRecordingIndicator {
            visualizationValue = .silence
            spectrum = []
            guard presentationGeneration == generation else { return false }
        }
        switch newState {
        case .idle, .notice, .error: endResourceOwnership()
        default: break
        }
        guard presentationGeneration == generation else { return false }
        if newState.showPanel { effects.showWindow() }
        guard presentationGeneration == generation else { return false }
        for observer in observers {
            observer.sessionDidTransition(from: oldState, to: newState, context: context)
            guard presentationGeneration == generation else { return false }
        }

        // Hide the capsule when the session finishes normally (slides down). resetToIdle()
        // covers the cancel/error paths; the normal .complete → .idle path needs this.
        if case .idle = newState {
            // A completed session is no longer allowed to publish readiness/state
            // events. Invalidate ownership before any late callback can resurrect it.
            context.cancel()
            activeSessionID = 0
            effects.hideWindow()
        }

        // Notices lose session ownership, so dismissal belongs to an independent token.
        if case .notice = newState {
            context.cancel()
            activeSessionID = 0
            let token = UUID()
            noticeDismissToken = token
            let duration = noticeValue?.duration ?? 2.2
            errorDismissTask = Task { @MainActor [weak self, timing = presentationTiming] in
                do { try await timing.delay(duration) } catch { return }
                guard let self, self.noticeDismissToken == token,
                      case .notice = self.sessionState else { return }
                self.resetToIdle()
            }
        }

        // Actionable recovery stays visible until retry, copy/dismiss, or a new session.
        if case .error = newState {
            errorDismissTask?.cancel()
            errorDismissTask = nil
        }
        guard presentationGeneration == generation else { return false }
        publishPresentation()
        return presentationGeneration == generation
    }

    // MARK: - Error Actions

    private func presentReadinessBlocked(_ issue: ReadinessIssue, context: SessionContext) {
        AppLogger.log("[SessionController#\(context.sessionID)] Readiness preflight blocked reason=\(issue)")
        errorDismissTask?.cancel()
        errorDismissTask = nil
        currentTask?.cancel()
        currentTask = nil
        clearSuspension()
        presentRecovery(RecoveryPolicy.presentation(kind: Self.readinessFailure(issue), resources: .init(
            stage: "Recording", hasAudio: false, textKind: .none, deliveryEventStarted: false,
            routingPolicy: configurationStore.current.asrRoutingPolicy, hasHistory: false)), copyText: nil, context: context,
            destination: issue == .noEngine ? Self.backendReadinessDestination(configurationStore.current) : nil)
    }

    nonisolated static func backendReadinessDestination(_ config: Configuration) -> ClientDestination {
        let selection = ASRBackendMigration.selection(from: config)
        return (selection.primary ?? selection.fallback).map { .settings(.speech, .asrBackend($0)) } ?? .settings(.speech)
    }

    nonisolated static func readinessPreflight(_ level: ReadinessLevel) -> ReadinessIssue? {
        if case .blocked(let issue) = level { return issue }
        return nil
    }

    nonisolated static func preparationSubtitle(for level: ReadinessLevel) -> String? {
        switch level {
        case .degraded(.basicOnly): return "基础模式 · 准确率较低"
        case .degraded(.accessibilityMissing): return "无辅助功能 · 结果将复制"
        case .degraded(.enginePreparing): return "识别引擎准备中"
        case .degraded(.microphoneNotDetermined): return "首次使用 · 将请求麦克风权限"
        default: return nil
        }
    }

    nonisolated static func readinessActions(for issue: ReadinessIssue,
                                             policy: ASRRoutingPolicy) -> [ErrorAction] {
        RecoveryPolicy.presentation(kind: readinessFailure(issue), resources: .init(stage: "Recording",
            hasAudio: false, textKind: .none, deliveryEventStarted: false, routingPolicy: policy, hasHistory: false)).actions
    }

    private nonisolated static func readinessFailure(_ issue: ReadinessIssue) -> FailureKind {
        switch issue {
        case .microphoneDenied: return .permission(.microphone)
        case .accessibilityMissing: return .permission(.accessibility)
        default: return .readiness(issue)
        }
    }

    /// Compatibility projection has no retained audio or actual stage authority.
    nonisolated static func buildErrorActions(from recovery: ErrorRecoveryContext) -> [ErrorAction] {
        RecoveryPolicy.presentation(kind: recovery.failureKind, resources: .init(stage: recovery.failedStage,
            hasAudio: false,
            textKind: recovery.rawText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? recovery.textKind : .none,
            deliveryEventStarted: false, routingPolicy: .auto, hasHistory: false)).actions
    }

    // MARK: - Timer

    private func startRecordingTimer(sessionID: UInt64, context: SessionContext) {
        elapsedSeconds = 0
        let maxDuration = configurationStore.current.maxRecordingDuration
        recordingTimer.schedule(withTimeInterval: 1.0, repeats: true) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      Self.shouldAcceptTimerTick(activeSessionID: self.activeSessionID,
                                                 tickSessionID: sessionID,
                                                 isCancelled: context.isCancelled,
                                                 isRecording: self.isRecording),
                      self.currentContext === context else { return }
                self.elapsedSeconds += 1
                self.stateValue = .recording(elapsedSeconds: self.elapsedSeconds)
                self.presentationGeneration &+= 1
                let generation = self.presentationGeneration
                self.publishPresentation()
                guard self.ownsActiveContext(context), self.presentationGeneration == generation,
                      self.isRecording else { return }

                // Auto-stop at max duration
                if self.elapsedSeconds >= maxDuration {
                    AppLogger.log("[SessionController] Recording reached max duration (\(maxDuration)s), auto-stopping")
                    self.endRecording()
                }
            }
        }
    }

    private func invalidateNoticeDismissal() {
        noticeDismissToken = nil
        errorDismissTask?.cancel()
        errorDismissTask = nil
    }

    private func invalidateSlowProgress() {
        slowOperation = nil
        slowProgressTask?.cancel()
        slowProgressTask = nil
        slowValue = false
    }

    /// One monotonic origin per stop/retry, independent of provider transitions and budget.
    private func beginSlowProgress(context: SessionContext) -> Bool {
        invalidateSlowProgress()
        let token = UUID()
        let generation = presentationGeneration
        let started = presentationTiming.now()
        guard ownsActiveContext(context), presentationGeneration == generation else { return false }
        slowOperation = (token, context.sessionID, started)
        slowProgressTask = Task { @MainActor [weak self, timing = presentationTiming] in
            do { try await timing.delay(max(0, 6 - (timing.now() - started))) } catch { return }
            let now = timing.now()
            guard let self, let operation = self.slowOperation,
                  operation.token == token, operation.sessionID == context.sessionID,
                  self.ownsActiveContext(context), now - operation.started >= 6 else { return }
            switch self.sessionState {
            case .processing, .polishing: break
            default: return
            }
            // Commit before publishing. A subscriber may synchronously cancel/start;
            // there is deliberately no assignment after this notification.
            self.slowValue = true
            self.presentationGeneration &+= 1
            self.publishPresentation()
        }
        return true
    }

    private func stopRecordingTimer() {
        recordingTimer.cancel()
        elapsedSeconds = 0
    }

    // MARK: - History

    /// Publish only while this context owns the lifecycle. Cancellation may keep
    /// its existing uncertain recovery result, but a late stage cannot publish.
    private func recordLastDelivery(context: SessionContext) {
        guard purpose == .dictation else { return }
        guard activeSessionID == context.sessionID, currentContext === context,
              let outcome = context.deliveryOutcome, outcome.isTerminalDelivery,
              !context.isCancelled || (context.deliveryEffectStarted && outcome == .uncertain) else { return }
        let summary = LastDeliverySummary(sessionID: context.sessionID, outcome: outcome,
            targetAppName: context.targetApp?.localizedName, targetBundleID: context.targetApp?.bundleIdentifier)
        guard claimedDeliverySummary != summary else { return }
        // @Published emits in willSet: claim before subscribers can call cancel.
        claimedDeliverySummary = summary
        lastDeliverySummary = summary
    }

    /// History label for a finished session: `.polish` only when polish was requested AND succeeded.
    /// A degraded (failed-polish) session is stored as `.raw` — its text is the un-polished original.
    nonisolated static func historyMode(usePolish: Bool, polishFailed: Bool) -> PolishMode {
        (usePolish && !polishFailed) ? .polish : .raw
    }

    /// sttBackend 文案：不再依赖 provider 类型判断。
    nonisolated static func backendLabel(forProviderID id: String?, localIdentity: LocalModelIdentity? = nil) -> String {
        switch id {
        case ASRProviderID.local: return localIdentity?.engine ?? "local"
        case ASRProviderID.cloud: return "cloud"
        default:
            if let id, id.hasPrefix("native:") { return localIdentity?.engine ?? "local" }
            if let id, id.hasPrefix("cloud:") || id.hasPrefix("service:") { return id }
            return id == nil ? "apple" : "unknown"
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

    /// Shared history projection uses the winning captured descriptor, including fallback.
    static func historySession(context: SessionContext, durationMs: UInt64?) -> DictationSession {
        let mode: PolishMode = SessionController.historyMode(usePolish: context.usePolish, polishFailed: context.polishFailed)
        let sttBackend = context.usedBackendDescriptor?.displayName ?? SessionController.backendLabel(forProviderID: context.usedProviderID, localIdentity: context.captureRoute?.localLease?.identity)
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
        session.asrBackendID = context.usedBackendDescriptor?.id.rawValue
        session.asrModelID = context.usedBackendDescriptor?.modelID
        session.asrLocation = context.usedBackendDescriptor?.location.rawValue
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
        return session
    }

    @discardableResult
    private func saveHistory(context: SessionContext) -> Bool {
        guard purpose == .dictation, context.claimHistorySave() else { return false }
        if let saveHistory = effects.saveHistory { saveHistory(context); return true }
        let durationMs: UInt64?
        if let recStart = context.recordingStartTime {
            durationMs = UInt64(Date().timeIntervalSince(recStart) * 1000)
        } else {
            durationMs = nil
        }
        let session = Self.historySession(context: context, durationMs: durationMs)
        HistoryStore.shared.append(session, storeText: configurationStore.current.storeTranscriptText)

        // Auto-detect corrections for dictionary
        if context.rawTranscript != context.finalText {
            let raw = context.rawTranscript
            let polished = context.finalText
            detectAndAddCorrections(raw: raw, final: polished)
        }

        let hitIds = DictionaryStore.shared.detectHits(in: context.finalText)
        DictionaryStore.shared.incrementHits(ids: hitIds)

        AppLogger.log("[SessionController] History saved, dict hits: \(hitIds.count)")
        return true
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
        invalidateNoticeDismissal()
        invalidateSlowProgress()
        noticeValue = nil
        startAttempt = nil
        if purpose == .dictation { OptionTapDetector.shared.cancelPendingTaps() }
        currentContext?.cancel()
        stateValue = .idle
        activeSessionID = 0
        currentContext = nil
        stateCancellable?.cancel()
        stateCancellable = nil
        spectrumCancellable?.cancel()
        spectrumCancellable = nil
        readinessCancellable?.cancel()
        readinessCancellable = nil
        clearSuspension()
        currentTask?.cancel()
        currentTask = nil
        errorDismissTask?.cancel()
        errorDismissTask = nil
        stopRecordingTimer()
        let generation = presentationGeneration
        endResourceOwnership()
        guard presentationGeneration == generation else { return }
        preparationNotice = nil
        guard presentationGeneration == generation else { return }
        visualizationValue = .silence
        spectrum = []
        guard presentationGeneration == generation else { return }
        effects.hideWindow()
        guard presentationGeneration == generation else { return }
        publishPresentation()
    }

    // MARK: - Helpers

    private func endResourceOwnership() {
        let lease = resourceLease
        resourceLease = nil
        lease?.end()
    }

    private static let resourceBusyMessage = "未开始录音：资源正在使用或收尾，请稍后再试"
    var resourceBusyNotice: String? { preparationNotice == Self.resourceBusyMessage ? preparationNotice : nil }

    private func presentResourceBusy() {
        let message = Self.resourceBusyMessage
        let generation = presentationGeneration
        preparationNotice = message
        guard presentationGeneration == generation else { return }
        switch sessionState {
        case .idle, .notice:
            let context = SessionContext(sessionID: 0)
            context.capsuleNotice = .resourceBusy
            transition(to: .notice(message), context: context)
        case .error:
            // Preserve retained audio, card identity and retry authority.
            effects.showWindow()
        default: break
        }
    }

    private func acquireRetryResource(context: SessionContext) -> Bool {
        let generation = presentationGeneration
        guard let token = resources.acquire(owner: resourceOwner) else {
            presentResourceBusy()
            return false
        }
        guard ownsActiveContext(context), presentationGeneration == generation else {
            resources.release(token: token); return false
        }
        let lease = SessionResourceLease(token: token, resources: resources)
        resourceLease = lease
        preparationNotice = nil
        return ownsActiveContext(context) && presentationGeneration == generation && resourceLease === lease
    }

    var ownsRecordingResource: Bool { resourceLease?.isActive == true }

    /// Scoped result identity for the trial presenter, never a process-wide event.
    var currentSessionIdentifier: UInt64? {
        guard let context = currentContext, ownsActiveContext(context) else { return nil }
        return context.sessionID
    }

    private func ownsActiveContext(_ context: SessionContext) -> Bool {
        activeSessionID == context.sessionID && currentContext === context && !context.isCancelled
    }

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

    typealias ErrorAction = RecoveryAction
}

// MARK: - SessionState UI Properties

extension SessionState {

    var capsuleSize: NSSize {
        if case .error = self { return NSSize(width: 380, height: 156) }
        return NSSize(width: 216, height: 54)
    }

    var statusColor: Color {
        switch self {
        case .idle:       return Color.white.opacity(0.5)
        case .preparing:  return Color(red: 0.5, green: 0.3, blue: 1.0)
        case .recording:  return Color(red: 0.5, green: 0.3, blue: 1.0)
        case .processing, .polishing: return .blue
        case .injecting:  return Color(red: 0.30, green: 0.63, blue: 1.0)
        case .notice:     return Color(red: 0.66, green: 0.61, blue: 1.0)  // 温和紫 #A99BFF,非红
        case .error:      return .red
        }
    }

    var statusTitle: String {
        switch self {
        case .idle:                      return "准备就绪"
        case .preparing:                 return "正在准备"
        case .recording:                 return "Listening..."
        case .processing, .polishing:    return "正在处理"
        case .injecting:                 return "正在输入"
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
