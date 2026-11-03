import Foundation

/// Reuse capture/ASR/processing/polish, with delivery scoped to one presenter.
enum OnboardingPipeline {
    @MainActor
    static func cancelDemo(_ session: SessionController) { session.cancel() }

    static func makeStages(onResult: @escaping @MainActor @Sendable (UInt64, String) -> Void) -> [PipelineStage] {
        [RecordingStage(), ASRStage(), PostProcessStage(), PolishStage(), DemoInjectionStage(onResult: onResult)]
    }
}

struct DemoInjectionStage: PipelineStage {
    var name: String { "DemoInjectionStage" }
    let onResult: @MainActor @Sendable (UInt64, String) -> Void

    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        guard case .polished(let text, _) = payload else { return .continue(payload) }
        await MainActor.run {
            guard !Task.isCancelled, context.beginDeliveryAttempt() else { return }
            guard context.performDeliveryEffect({}) else { context.finishDelivery(.cancelled); return }
            onResult(context.sessionID, text)
            context.finishDelivery(.typedDispatched)
        }
        return .complete
    }
}
