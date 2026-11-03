import Foundation

// MARK: - StagePayload

/// Strongly-typed data passed between pipeline stages.
enum StagePayload {
    case empty
    case audio(samples: [Float], previewText: String)
    case transcript(String)
    case processed(String, raw: String)
    case polished(String, raw: String)
}

// MARK: - StageResult

/// What a stage returns after execution.
enum StageResult {
    /// Continue to the next stage with the given payload.
    case `continue`(StagePayload)

    /// Skip to a named stage with the given payload.
    case skip(to: String, StagePayload)

    /// Suspend the pipeline for error recovery.
    case suspend(ErrorRecoveryContext)

    /// Degrade gently: no buttons, auto-dismissing notice. Used when a stage can't
    /// proceed but the situation isn't an error (e.g. no provider available / no speech).
    case notice(String)

    /// Pipeline completed successfully.
    case complete
}

// MARK: - ErrorRecoveryContext

/// Session-owned error and copyable text; presentation uses only safe categories.
struct ErrorRecoveryContext {
    let failedStage: String
    let error: Error
    let rawText: String?
    let retryable: Bool
    let failureKind: FailureKind
    let textKind: RecoveryTextKind
    var destination: ClientDestination? = nil

    init(failedStage: String, error: Error, rawText: String?, retryable: Bool,
         failureKind: FailureKind? = nil, textKind: RecoveryTextKind? = nil) {
        self.failedStage = failedStage
        self.error = error
        self.rawText = rawText
        self.retryable = retryable
        self.failureKind = failureKind ?? FailureClassifier.classify(error)
        self.textKind = textKind ?? (rawText == nil ? .none : .raw)
    }
}

// MARK: - PipelineStage

/// Protocol defining a single stage in the pipeline.
///
/// Stages are executed sequentially. Errors are communicated via `.suspend()`
/// rather than thrown, keeping the protocol simple and allowing the orchestrator
/// to present retryable error cards.
///
/// Stages must be Sendable: the MainActor orchestrator sends them into
/// nonisolated Tasks for execution.
protocol PipelineStage: Sendable {
    /// Human-readable name for diagnostics and logging.
    var name: String { get }

    /// Execute this stage.
    ///
    /// - Parameters:
    ///   - payload: Input data from the previous stage.
    ///   - context: Shared session context (MainActor-isolated).
    /// - Returns: A `StageResult` directing the orchestrator how to proceed.
    func execute(payload: StagePayload, context: SessionContext) async -> StageResult
}

extension PipelineStage {
    /// Runs a stage only while its session still owns the pipeline. A cancellation
    /// that races with a stage's async work is converted into `.complete`, which
    /// lets the controller finish quietly without advancing a stale result. A
    /// stage still owns its external side effects and must check cancellation
    /// immediately before each such effect (for example, a provider append or
    /// delivery attempt).
    func executeIfOwned(payload: StagePayload, context: SessionContext) async -> StageResult {
        let cancelledBefore = await MainActor.run { context.isCancelled }
        guard !cancelledBefore else { return .complete }

        let result = await execute(payload: payload, context: context)
        let cancelledAfter = await MainActor.run { context.isCancelled }
        return cancelledAfter ? .complete : result
    }
}
