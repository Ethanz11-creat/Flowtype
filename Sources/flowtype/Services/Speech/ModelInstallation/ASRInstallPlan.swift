import Foundation

struct ASRInstallPlan: Codable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let engine: LocalASREngine
    let files: [HFPlannedFile]
    let totalBytes: Int64
    let recipeID: String?
    let recipeVersion: Int
    let credentialID: String?
}

struct HFRepositoryPreflightContext: Sendable {
    let credentialID: String?
    let receivedBytes: Int
}

enum ASRInstallPlanningError: Error, LocalizedError, Equatable {
    case unsupportedArchitecture, variantRequired, invalidVariant, tokenizerRequired, tokenizerMismatch
    case incompleteModel, invalidMetadata, invalidPath, destinationCollision, metadataBudget, totalSizeOverflow
    case invalidCredential, ambiguousEngine, duplicateEngine

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture: return "此模型不兼容内置原生引擎。请使用兼容的 Qwen MLX / WhisperKit Core ML 模型，或连接自行运行的本地模型服务。"
        case .variantRequired, .ambiguousEngine: return "请选择具体模型变体或子目录。"
        case .tokenizerRequired: return "请提供此 Whisper 模型对应的分词器仓库和固定版本。"
        case .tokenizerMismatch: return "分词器与所选 Whisper 变体不匹配。"
        case .metadataBudget: return "模型预检元数据超过大小限制，可使用离线导入。"
        default: return "无法生成完整安全的模型安装计划，请检查来源、文件和选择。"
        }
    }
}
