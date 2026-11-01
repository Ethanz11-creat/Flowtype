import Foundation

enum LocalASRRuntimeFactory {
    static func load(_ model: ImportedASRModel) async throws -> LocalASRLease {
        try Task.checkCancellation()
        // Reinspect immediately before constructing any runtime. A stale library row is
        // not permission to load a replaced model or substitute another tokenizer folder.
        let current = try ASRModelInspector.inspect(directory: model.directory)
        guard current.fileFingerprint == model.fileFingerprint, current.engine == model.engine,
              current.tokenizerDirectory == model.tokenizerDirectory,
              current.qwenCompatibilityModelID == model.qwenCompatibilityModelID else {
            throw ASRModelInspectionError(code: .changedDuringInspection, detail: "模型文件已改变，请重新检测。")
        }
        switch model.engine {
        case .qwenMLX:
            guard let compatibilityID = model.qwenCompatibilityModelID else {
                throw ASRModelInspectionError(code: .unsupportedFormat, detail: "不支持此 Qwen 模型配置。")
            }
            let provider = QwenASRProvider()
            try await provider.loadModel(modelId: compatibilityID, cacheDir: model.directory, offlineMode: true)
            try Task.checkCancellation()
            return LocalASRLease(id: UUID(), identity: LocalModelIdentity(id: model.id.uuidString,
                displayName: model.name, engine: model.engine.rawValue, repoID: nil, directory: model.directory), provider: provider,
                minimumResidentBytes: current.minimumResidentBytes)
        case .whisperCoreML:
            let provider = try await WhisperASRProvider.load(model: model)
            return LocalASRLease(id: UUID(), identity: provider.identity, provider: provider,
                                 whisperMetadata: provider.verifiedMetadata)
        }
    }
}
