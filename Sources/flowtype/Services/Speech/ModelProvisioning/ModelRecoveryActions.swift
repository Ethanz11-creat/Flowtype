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
            config = LocalModelLibrary.removing(id: id, from: config)
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
        } else if let target = coordinator.target {
            await coordinator.perform(.init(target: target, source: store.current.downloadSource, origin: .manual))
        } else { await coordinator.retryConfiguredModel() }
    }
}
