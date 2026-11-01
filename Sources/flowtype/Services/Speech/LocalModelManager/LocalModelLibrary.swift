import Foundation

/// Value transformations only. The coordinator persists successful owned loads in a later transaction.
enum LocalModelLibrary {
    /// Resolve the durable ID before constructing a provider/lease, including symlink aliases.
    static func canonicalizing(_ model: ImportedASRModel, in configuration: Configuration) -> ImportedASRModel {
        var result = model
        if let existing = configuration.importedASRModels.first(where: {
            $0.id == model.id || canonical($0.directory) == canonical(model.directory)
        }) { result.id = existing.id }
        return result
    }
    static func upserting(_ model: ImportedASRModel, in configuration: Configuration) -> Configuration {
        var result = configuration
        var model = model
        if let index = result.importedASRModels.firstIndex(where: {
            $0.id == model.id || canonical($0.directory) == canonical(model.directory)
        }) {
            model.id = result.importedASRModels[index].id
            result.importedASRModels[index] = model
        } else { result.importedASRModels.append(model) }
        return result
    }

    static func removing(id: UUID, from configuration: Configuration) -> Configuration {
        var result = configuration
        guard let removed = result.importedASRModels.first(where: { $0.id == id }) else { return result }
        result.importedASRModels.removeAll { $0.id == id }
        if result.activeImportedASRModelID == id {
            result.activeImportedASRModelID = nil
            result.localModelPath = nil
            result.customLocalModelPath = nil
            result.selectedLocalModelID = nil
        }
        for path in [result.localModelPath, result.customLocalModelPath].compactMap({ $0 }) {
            if canonical(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) == canonical(removed.directory) {
                if result.localModelPath == path { result.localModelPath = nil }
                if result.customLocalModelPath == path { result.customLocalModelPath = nil }
            }
        }
        return result
    }

    /// Legacy paths are staged and inspected, without writing configuration or selecting a model.
    static func inspectLegacyCandidate(in configuration: Configuration) throws -> ImportedASRModel? {
        guard let path = [configuration.customLocalModelPath, configuration.localModelPath]
            .compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return nil }
        return try ASRModelInspector.inspect(directory: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    private static func canonical(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
}
