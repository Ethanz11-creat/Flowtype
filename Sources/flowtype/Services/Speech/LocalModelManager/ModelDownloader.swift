import Foundation
import Combine

enum DownloadStatus: Equatable {
    case pending
    case downloading(progress: Double)
    case verifying
    case completed
    case failed(String)
}

@MainActor
final class ModelDownloader: ObservableObject {
    static let shared = ModelDownloader()

    @Published var currentDownload: (preset: ModelPreset, status: DownloadStatus)?

    private var ownedOperationID: UUID?
    private let coordinator: QwenModelState
    private let configuration: @MainActor () -> Configuration
    private var subscription: AnyCancellable?
    private var ownershipSubscription: AnyCancellable?
    private var cancelRequested = false

    init(coordinator: QwenModelState = .shared,
         configuration: @escaping @MainActor () -> Configuration = { ConfigurationStore.shared.current }) {
        self.coordinator = coordinator
        self.configuration = configuration
        subscription = coordinator.$status.sink { [weak self] status in
            guard let self, self.ownedOperationID != nil, let current = self.currentDownload else { return }
            if self.cancelRequested { return }
            switch status {
            case .downloading(let progress, _, _): self.currentDownload = (current.preset, .downloading(progress: progress))
            case .loading: self.currentDownload = (current.preset, .verifying)
            case .ready: self.currentDownload = (current.preset, .completed)
            case .error(let reason, _): self.currentDownload = (current.preset, .failed(reason))
            case .notLoaded: self.currentDownload = nil
            case .stalled: break
            }
        }
        ownershipSubscription = coordinator.$operationID.sink { [weak self] id in
            guard let self, id == nil, self.ownedOperationID != nil else { return }
            self.ownedOperationID = nil
            if self.cancelRequested { self.currentDownload = nil }
        }
    }

    func startDownload(preset: ModelPreset) {
        guard ownedOperationID == nil, coordinator.operationID == nil else { return }
        cancelRequested = false
        currentDownload = (preset, .pending)
        ownedOperationID = coordinator.start(.init(target: .preset(preset), source: configuration().downloadSource, origin: .manual))
    }

    /// A terminal download record is history, never an in-flight operation.
    func isDownloading(preset: ModelPreset) -> Bool {
        guard ownedOperationID != nil, let current = currentDownload, current.preset.id == preset.id else { return false }
        switch current.status {
        case .pending: return true
        case .downloading, .verifying: return coordinator.operationID != nil
        case .completed, .failed: return false
        }
    }

    func cancelDownload() {
        guard let ownedOperationID, coordinator.operationID == ownedOperationID else { return }
        cancelRequested = true
        coordinator.cancel()
    }

    func isModelDownloaded(_ preset: ModelPreset) -> Bool {
        configuration().installedASRModels.contains {
            $0.ownership == .managed && $0.installPlan?.recipeID == preset.id && FileManager.default.fileExists(atPath: $0.directory.path)
        } || ModelLocator.isPresetDownloaded(preset)
    }

    func deleteModel(_ preset: ModelPreset) async throws {
        let records = configuration().installedASRModels.filter { $0.ownership == .managed && $0.installPlan?.recipeID == preset.id }
        guard !records.isEmpty else { throw NativeModelUsageError.external }
        guard records.count == 1, let record = records.first else { throw NativeModelUsageError.invalidOwnership }
        try await coordinator.removeModelRecord(id: record.importedModelID, deleteManagedFiles: true)
    }
}
