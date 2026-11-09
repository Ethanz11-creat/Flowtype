import Foundation

protocol LocalASREngineAdapter: Sendable {
    var engine: LocalASREngine { get }
    func assessMetadata(config: Data?, paths: [String]) throws -> Bool
    func inspect(directory: URL) throws -> ImportedASRModel
    func load(model: ImportedASRModel) async throws -> LocalASRLease
}
