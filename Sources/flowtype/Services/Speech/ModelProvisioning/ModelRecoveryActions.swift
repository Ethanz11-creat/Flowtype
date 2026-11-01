import Foundation

/// Shared settings actions keep folder selection and its successful lease together.
@MainActor
struct ModelRecoveryActions {
    let coordinator: QwenModelState
    let store: ConfigurationStore

    func importOfflineModel(at directory: URL) async throws {
        try await coordinator.importOfflineModel(at: directory)
        var config = store.current
        config.customLocalModelPath = directory.path
        config.localModelPath = nil
        config.selectedLocalModelID = nil
        store.save(config)
    }

    func retry() async throws {
        if case .offline(let resolved) = coordinator.target {
            try await importOfflineModel(at: resolved.directory)
        } else if let target = coordinator.target {
            await coordinator.perform(.init(target: target, source: store.current.downloadSource, origin: .manual))
        } else { await coordinator.retryConfiguredModel() }
    }
}
