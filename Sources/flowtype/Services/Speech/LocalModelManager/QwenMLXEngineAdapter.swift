import Foundation

struct QwenMLXEngineAdapter: LocalASREngineAdapter {
    let engine = LocalASREngine.qwenMLX
    func assessMetadata(config: Data?, paths: [String]) throws -> Bool {
        guard let config, let object = try JSONSerialization.jsonObject(with: config) as? [String: Any],
              object["model_type"] as? String == "qwen3_asr" else { return false }
        _ = try NativeASRFormatSupport.qwenMetadata(object)
        return true
    }
    func inspect(directory: URL) throws -> ImportedASRModel {
        try ASRModelInspector.inspectQwen(directory)
    }
    func load(model: ImportedASRModel) async throws -> LocalASRLease {
        guard let compatibilityID = model.qwenCompatibilityModelID else {
            throw ASRModelInspectionError(code: .unsupportedFormat, detail: "不支持此 Qwen 模型配置。")
        }
        let provider = QwenASRProvider()
        try await provider.loadModel(modelId: compatibilityID, cacheDir: model.directory, offlineMode: true)
        try Task.checkCancellation()
        return LocalASRLease(id: UUID(), identity: LocalModelIdentity(id: model.id.uuidString,
            displayName: model.name, engine: model.engine.rawValue, repoID: nil, directory: model.directory),
            provider: provider, minimumResidentBytes: model.minimumResidentBytes)
    }
}
