import Foundation

/// Value transformations only. The coordinator persists successful owned loads in a later transaction.
enum LocalModelLibrary {
    /// Idempotent publication registration, without changing any selection or validation.
    static func registering(_ record: ASRInstalledModelRecord, model: ImportedASRModel,
                            in configuration: Configuration) throws -> Configuration {
        guard record.importedModelID == model.id, record.id != model.id,
              canonical(record.directory) == canonical(model.directory) else { throw HFDownloadError(code: .integrity) }
        var result = configuration
        if let existing = result.installedASRModels.first(where: { $0.id == record.id }) {
            guard existing.importedModelID == record.importedModelID, existing.directory == record.directory,
                  existing.installPlan == record.installPlan else { throw HFDownloadError(code: .integrity) }
        } else { result.installedASRModels.append(record) }
        if let existing = result.importedASRModels.first(where: { $0.id == model.id }) {
            guard canonical(existing.directory) == canonical(model.directory), existing.engine == model.engine else { throw HFDownloadError(code: .integrity) }
        } else {
            guard !result.importedASRModels.contains(where: { canonical($0.directory) == canonical(model.directory) }) else { throw HFDownloadError(code: .integrity) }
            result.importedASRModels.append(model)
        }
        return result
    }

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
        result.installedASRModels.removeAll { $0.importedModelID == id }
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
        let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if RuntimeEnvironment.current.role != .app {
            let root = RuntimeEnvironment.current.paths.validationRoot!.resolvingSymlinksInPath().path
            guard directory.resolvingSymlinksInPath().path.hasPrefix(root + "/") else {
                throw ModelProvisionError.incompleteLocal()
            }
        }
        return try ASRModelInspector.inspect(directory: directory)
    }

    private static func canonical(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
}
