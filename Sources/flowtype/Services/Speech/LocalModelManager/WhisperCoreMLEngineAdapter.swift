import Foundation

struct WhisperCoreMLEngineAdapter: LocalASREngineAdapter {
    let engine = LocalASREngine.whisperCoreML
    func assessMetadata(config: Data?, paths: [String]) throws -> Bool {
        let packages = Set(paths.compactMap { $0.split(separator: "/").first.map(String.init) })
        return WhisperModelInspector.components.allSatisfy { name in
            WhisperModelInspector.packageExtensions.contains { packages.contains(name + "." + $0) }
        }
    }
    func inspect(directory: URL) throws -> ImportedASRModel {
        try WhisperModelInspector.inspect(directory: directory)
    }
    func load(model: ImportedASRModel) async throws -> LocalASRLease {
        let provider = try await WhisperASRProvider.load(model: model)
        try Task.checkCancellation()
        return LocalASRLease(id: UUID(), identity: provider.identity, provider: provider,
                             whisperMetadata: provider.verifiedMetadata)
    }
}
