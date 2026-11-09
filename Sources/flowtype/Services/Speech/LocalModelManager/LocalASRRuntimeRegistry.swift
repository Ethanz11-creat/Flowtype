import Foundation

/// Compiled-in adapters; metadata ambiguity is an error, never an ordering decision.
struct LocalASRRuntimeRegistry: Sendable {
    static let standard = try! LocalASRRuntimeRegistry(adapters: [QwenMLXEngineAdapter(), WhisperCoreMLEngineAdapter()])
    private let adapters: [any LocalASREngineAdapter]

    init(adapters: [any LocalASREngineAdapter]) throws {
        guard Set(adapters.map { $0.engine.rawValue }).count == adapters.count else {
            throw ASRInstallPlanningError.duplicateEngine
        }
        self.adapters = adapters
    }
    func engine(config: Data?, paths: [String]) throws -> LocalASREngine {
        let matching = try adapters.filter { try $0.assessMetadata(config: config, paths: paths) }
        guard !matching.isEmpty else { throw ASRInstallPlanningError.unsupportedArchitecture }
        guard matching.count == 1 else { throw ASRInstallPlanningError.ambiguousEngine }
        return matching[0].engine
    }
    private func adapter(for engine: LocalASREngine) throws -> any LocalASREngineAdapter {
        guard let adapter = adapters.first(where: { $0.engine == engine }) else { throw ASRInstallPlanningError.unsupportedArchitecture }
        return adapter
    }
    func inspect(engine: LocalASREngine, directory: URL) throws -> ImportedASRModel {
        try adapter(for: engine).inspect(directory: directory)
    }
    func load(_ model: ImportedASRModel) async throws -> LocalASRLease {
        try await adapter(for: model.engine).load(model: model)
    }
}
