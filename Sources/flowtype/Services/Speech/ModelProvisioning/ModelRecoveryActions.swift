import Foundation

/// Shared settings actions keep folder selection and its successful lease together.
@MainActor
struct ModelRecoveryActions {
    let coordinator: QwenModelState
    let store: ConfigurationStore

    func importOfflineModel(at directory: URL) async throws {
        try await coordinator.importOfflineModel(at: directory)
    }

    func removeFolderOverride() {
        guard coordinator.operationID == nil else { return }
        var config = store.current
        if let id = config.activeImportedASRModelID {
            // This is explicit deselection, not removal of a possibly managed/in-use row.
            let backend = ASRBackendID(rawValue: "native:import:" + id.uuidString)
            var selection = ASRBackendMigration.selection(from: config)
            if selection.primary == backend { selection.primary = nil }
            if selection.fallback == backend { selection.fallback = nil }
            config.setASRBackendSelection(selection)
            config.activeImportedASRModelID = nil
        }
        config.customLocalModelPath = nil
        config.localModelPath = nil
        store.save(config)
        coordinator.resetConfiguredRecovery()
    }

    func retry() async throws {
        if coordinator.target == nil, let directory = coordinator.pendingImportDirectory {
            try await coordinator.importOfflineModel(at: directory)
        } else if case .imported(let model) = coordinator.target {
            try await coordinator.useImportedModel(model)
        } else if coordinator.target != nil {
            await coordinator.retrySelection(source: store.current.downloadSource)
        } else { await coordinator.retryConfiguredModel() }
    }
}
