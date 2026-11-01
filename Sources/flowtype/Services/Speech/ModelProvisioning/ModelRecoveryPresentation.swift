import Foundation

/// One description for the available lease and the separate recovery target.
struct ModelRecoveryPresentation {
    enum Action: Equatable { case retry, chooseFolder, useSmallerModel, cancel }
    let activeName: String?
    let targetName: String?
    let repoID: String?
    let sourceName: String
    let downloadCommand: String?
    let failureMessage: String?
    let failureSourceName: String?
    let fallbackLabel: String?
    let actions: [Action]

    static func make(active: LocalModelIdentity?, target: ModelPreset?, failure: ModelProvisionError?,
                     didAutoFallback: Bool, source: DownloadSource = .auto, destination: URL? = nil,
                     isBusy: Bool = false, customPath: String? = nil, failureSource: DownloadSource? = nil) -> Self {
        let isCustom = customPath?.isEmpty == false
        let targetName = isCustom ? "自定义模型" : target?.name
        let repo = isCustom ? nil : target?.repoId
        let command: String?
        if let target, !isCustom,
           let endpoint = try? source.validatedEndpoint(isChina: DownloadSource.systemIsLikelyChina()) {
            command = "HF_ENDPOINT=\(quote(endpoint.absoluteString)) hf download \(quote(target.repoId)) --local-dir \(quote((destination ?? target.localDirectory()).path))"
        } else { command = nil }
        var message: String?
        switch failure {
        case .metadataInvalid: message = "下载源元数据无效。请选择其他下载源后重试，或指定已下载的模型文件夹。"
        case .network: message = "模型下载网络错误。可重试或切换下载源。"
        case .stalled: message = "模型下载已停滞。可重试或切换下载源。"
        case .incompleteLocal: message = "本地模型目录不完整或身份不匹配。请重新指定模型文件夹。"
        case .loadFailed: message = "模型加载失败。可检查文件后重试，或指定其他模型文件夹。"
        case .insufficientDisk: message = "磁盘空间不足。请准备足够空间后重试，或指定已下载的模型文件夹。"
        case nil: message = nil
        }
        if let summary = failure?.summary {
            let endpoint = summary.host + summary.safePath
            let status = summary.httpStatus.map { "HTTP \($0) · " } ?? ""
            message = [message, status + endpoint].compactMap { $0 }.joined(separator: "\n")
        }
        let actions: [Action] = isBusy ? [.cancel] : [.retry, .chooseFolder, .useSmallerModel]
        return Self(activeName: active?.displayName, targetName: targetName, repoID: repo,
                    sourceName: source.displayName, downloadCommand: command, failureMessage: message,
                    failureSourceName: failure == nil ? nil : failureSource?.displayName,
                    fallbackLabel: didAutoFallback && !isBusy && failure == nil && active?.id == ModelPreset.qwen306B.id ? "已退回 0.6B" : nil,
                    actions: actions)
    }

    /// Choosing a preset explicitly discards conflicting folder overrides.
    static func selectSmallerModel(in config: inout Configuration) {
        config.selectedLocalModelID = ModelPreset.qwen306B.id
        config.customLocalModelPath = nil
        config.localModelPath = nil
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
