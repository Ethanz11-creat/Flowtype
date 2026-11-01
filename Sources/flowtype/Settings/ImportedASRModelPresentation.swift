import Foundation

/// Pure display/action policy. Static compatibility never implies runtime readiness.
struct ImportedASRModelPresentation {
    enum Action: Equatable { case load, relocate, removeRecord }
    let id: UUID
    let name: String
    let format: String
    let source: String
    let size: String
    let status: String
    let hardwareAdvice: String
    let actions: [Action]

    static let downloadablePresets = ModelPreset.allPresets
    static let sources: [(name: String, url: URL)] = [
        ("Qwen3-ASR MLX 0.6B", URL(string: "https://huggingface.co/aufklarer/Qwen3-ASR-0.6B-MLX-4bit")!),
        ("Qwen3-ASR MLX 1.7B", URL(string: "https://huggingface.co/aufklarer/Qwen3-ASR-1.7B-MLX-4bit")!),
        ("WhisperKit 兼容 Core ML", URL(string: "https://huggingface.co/argmaxinc/whisperkit-coreml")!)
    ]
    static let importHelp = "仅在本机读取并记录目录，不上传、不复制权重。支持 Qwen3-ASR 0.6B / 1.7B MLX 4/8-bit（group size 64）与满足本产品接口合同的 WhisperKit Core ML 目录。Whisper 导出须使用 Int32 的 KV 更新掩码；Float16 更新掩码导出当前不支持，并非所有 WhisperKit 导出均兼容。当前 WhisperKit 0.18 运行库不支持 Intel Mac，需 Apple Silicon；这是运行库限制，不是 Core ML 格式限制。原始 PyTorch 权重不受支持，请自行准备兼容转换格式；不安装 Python、不执行仓库脚本、不自动转换或联网补齐文件。"
    static let removalHelp = "移除记录不会删除模型文件；已加载模型及进行中的录音仍可继续使用。"

    static func engineName(_ engine: String) -> String {
        switch engine {
        case LocalASREngine.qwenMLX.rawValue, "qwen": return "Qwen3-ASR MLX"
        case LocalASREngine.whisperCoreML.rawValue: return "Whisper Core ML"
        default: return engine
        }
    }

    static func availability(_ identity: LocalModelIdentity?) -> String {
        guard let identity else { return "本地模型尚未就绪；稍后配置不会启用离线识别。" }
        return "可用模型：\(identity.displayName) · \(engineName(identity.engine))"
    }

    static func make(model: ImportedASRModel, assessment: LocalModelHardwareAssessment,
                     isActive: Bool) -> Self {
        let variant = model.variant == "unverified" ? "规模待加载验证" : model.variant
        let quantization = model.bits.map { " · \($0)-bit" } ?? ""
        return .init(id: model.id, name: model.name,
            format: "\(engineName(model.engine.rawValue)) · \(variant)\(quantization)",
            source: "本机目录：\(model.directory.path)",
            size: ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file),
            status: isActive ? "当前已加载" : "未在使用；加载时重新校验",
            hardwareAdvice: assessment.explanation,
            actions: assessment.compatibility == .incompatible ? [.relocate, .removeRecord] : [.load, .relocate, .removeRecord])
    }
}
