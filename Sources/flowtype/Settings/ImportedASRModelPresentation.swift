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
                     isActive: Bool, isSelected: Bool = false, isPreparing: Bool = false) -> Self {
        let variant = model.variant == "unverified" ? "规模待加载验证" : model.variant
        let quantization = model.bits.map { " · \($0)-bit" } ?? ""
        let roles = [isSelected ? "已选" : nil, isActive ? "当前已加载" : nil,
                     isPreparing ? "正在准备" : nil].compactMap { $0 }
        return .init(id: model.id, name: model.name,
            format: "\(engineName(model.engine.rawValue)) · \(variant)\(quantization)",
            source: "本机目录：\(model.directory.path)",
            size: ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file),
            status: roles.isEmpty ? "未在使用；加载时重新校验" : roles.joined(separator: " · "),
            hardwareAdvice: assessment.explanation,
            actions: assessment.compatibility == .incompatible ? [.relocate, .removeRecord] : [.load, .relocate, .removeRecord])
    }
}

/// Saved intent, usable runtime and the current attempt are independent sources of truth.
/// Reading this presentation never starts model discovery, downloading or loading.
struct LocalModelSelectionPresentation {
    let selectedName: String
    let selectedPresetID: String?
    let selectedImportedID: UUID?
    let loaded: LocalModelIdentity?
    let targetName: String?
    let targetID: String?
    let targetPath: String?
    let isBusy: Bool
    let selectionNeedsLoading: Bool
    let recovery: ModelRecoveryPresentation

    @MainActor
    static func make(config: Configuration, coordinator: QwenModelState) -> Self {
        let imported = config.importedASRModels.first { $0.id == config.activeImportedASRModelID }
        let configuredPath = [config.customLocalModelPath, config.localModelPath]
            .compactMap { $0 }.first { !$0.isEmpty }
        let selectedName: String
        if let imported {
            selectedName = "\(imported.name) · \(ImportedASRModelPresentation.engineName(imported.engine.rawValue))"
        } else if config.activeImportedASRModelID != nil {
            selectedName = "导入记录不可用；请重新定位或选择模型"
        } else if let configuredPath {
            selectedName = "本机目录 · \(URL(fileURLWithPath: configuredPath).lastPathComponent)"
        } else if let id = config.selectedLocalModelID {
            selectedName = ModelPreset.preset(forID: id)?.name ?? "未知模型（\(id)）"
        } else {
            selectedName = "自动选择（按硬件推荐）"
        }

        let targetName: String?
        let targetID: String?
        let targetPath: String?
        let preset: ModelPreset?
        switch coordinator.target {
        case .preset(let value):
            preset = value; targetName = value.name; targetID = value.id; targetPath = nil
        case .imported(let model):
            preset = nil; targetName = "\(model.name) · \(ImportedASRModelPresentation.engineName(model.engine.rawValue))"
            targetID = model.id.uuidString; targetPath = model.directory.path
        case .offline(let model):
            preset = ModelPreset.allPresets.first { $0.repoId == model.modelId }
            targetName = preset?.name ?? model.directory.lastPathComponent
            targetID = preset?.id; targetPath = model.directory.path
        case .uninspectedDirectory(let directory):
            preset = nil; targetName = "待检查目录 · \(directory.lastPathComponent)"
            targetID = nil; targetPath = directory.path
        case nil:
            targetPath = coordinator.pendingImportDirectory?.path ?? imported?.directory.path ?? configuredPath
            preset = targetPath == nil && config.activeImportedASRModelID == nil
                ? ModelPreset.preset(forID: config.selectedLocalModelID)
                    ?? (config.selectedLocalModelID == nil ? ModelPreset.recommendedModel(for: HardwareProfiler.currentTier()) : nil)
                : nil
            targetName = imported?.name ?? preset?.name ?? (targetPath == nil ? nil : "本机目录")
            targetID = imported?.id.uuidString ?? preset?.id
        }
        let busy = coordinator.operationID != nil
        let loaded = coordinator.activeLease?.identity
        let selectionNeedsLoading: Bool
        if let id = config.activeImportedASRModelID {
            selectionNeedsLoading = loaded?.id != id.uuidString
        } else if let configuredPath {
            selectionNeedsLoading = loaded?.directory.standardizedFileURL != URL(fileURLWithPath: configuredPath).standardizedFileURL
        } else if let id = config.selectedLocalModelID {
            selectionNeedsLoading = loaded?.id != id
        } else { selectionNeedsLoading = loaded == nil }
        return .init(selectedName: selectedName,
            selectedPresetID: config.activeImportedASRModelID == nil && configuredPath == nil ? config.selectedLocalModelID : nil,
            selectedImportedID: config.activeImportedASRModelID, loaded: coordinator.activeLease?.identity,
            targetName: targetName, targetID: targetID, targetPath: targetPath, isBusy: busy,
            selectionNeedsLoading: selectionNeedsLoading,
            recovery: .make(active: coordinator.activeLease?.identity, target: preset,
                failure: coordinator.failure, didAutoFallback: coordinator.didAutoFallback,
                source: config.downloadSource, isBusy: busy, customPath: preset == nil ? targetPath : nil,
                failureSource: coordinator.operationSource))
    }

    func presetStatus(_ preset: ModelPreset, filesDownloaded: Bool) -> String {
        let roles = [selectedPresetID == preset.id ? "已选" : nil,
                     loaded?.id == preset.id || loaded?.repoID == preset.repoId ? "已加载可用" : nil,
                     isBusy && targetID == preset.id ? "正在准备" : nil].compactMap { $0 }
        return roles.isEmpty ? (filesDownloaded ? "文件已下载；尚未加载" : "尚未下载") : roles.joined(separator: " · ")
    }
}
