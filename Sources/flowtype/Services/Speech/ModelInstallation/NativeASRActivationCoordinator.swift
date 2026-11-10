import Foundation

/// Validation never owns a second runtime. QwenModelState owns reservation, drain and commit.
@MainActor
final class NativeASRActivationCoordinator {
    private let state: QwenModelState
    init(state: QwenModelState) { self.state = state }

    func activate(modelID: UUID, sample: ASRValidationSample, selectionIntent: NativeASRSelectionIntent = .existingRole) async throws -> LocalASRLease {
        try await state.activate(modelID: modelID, sample: sample, selectionIntent: selectionIntent)
    }

    func activate(preset: ModelPreset, sample: ASRValidationSample, selectionIntent: NativeASRSelectionIntent = .existingRole) async throws -> LocalASRLease {
        try await state.activate(preset: preset, sample: sample, selectionIntent: selectionIntent)
    }

    func test(modelID: UUID, sample: ASRValidationSample) async throws -> ASRModelTrialResult {
        try await state.test(modelID: modelID, sample: sample)
    }

    func test(preset: ModelPreset, sample: ASRValidationSample) async throws -> ASRModelTrialResult {
        try await state.test(preset: preset, sample: sample)
    }

    func unloadCurrentAfterDrain() async throws {
        try await state.unloadCurrentAfterDrain()
    }
}

enum NativeASRActivationError: Error, Equatable, LocalizedError {
    case busy, validationRequired, missingModel, emptyResult, deadlineExceeded, changedCandidate, resourcesInUse, onlineProvider

    var errorDescription: String? {
        switch self {
        case .busy: return "候选模型仍在加载或排空，请稍后重试。"
        case .validationRequired: return "此模型需要使用离线语音样本验证后才能使用。"
        case .missingModel: return "候选模型已从模型库移除，请重新检查。"
        case .emptyResult: return "试识别未返回非空终稿，未替换当前模型。"
        case .deadlineExceeded: return "离线试识别超过 20 秒，等待运行任务排空后可重试。"
        case .changedCandidate: return "模型文件、运行库版本或当前选择已改变，请重新验证。"
        case .resourcesInUse: return "请结束当前录音并等待捕获资源排空后卸载模型。"
        case .onlineProvider: return "原生模型验证只允许完全离线的本机运行库。"
        }
    }
}
