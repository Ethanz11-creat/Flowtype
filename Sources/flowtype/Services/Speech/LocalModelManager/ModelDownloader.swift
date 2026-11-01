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

    private var downloadTask: Task<Void, Never>?
    private let coordinator: QwenModelState
    private let configuration: @MainActor () -> Configuration
    private var subscription: AnyCancellable?
    private var cancelRequested = false

    init(coordinator: QwenModelState = .shared,
         configuration: @escaping @MainActor () -> Configuration = { ConfigurationStore.shared.current }) {
        self.coordinator = coordinator
        self.configuration = configuration
        subscription = coordinator.$status.sink { [weak self] status in
            guard let self, self.downloadTask != nil, let current = self.currentDownload else { return }
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
    }

    func startDownload(preset: ModelPreset) {
        guard downloadTask == nil, coordinator.operationID == nil else { return }
        cancelRequested = false
        currentDownload = (preset, .pending)
        let source = configuration().downloadSource
        downloadTask = Task {
            guard !Task.isCancelled, coordinator.operationID == nil else {
                currentDownload = nil; downloadTask = nil; return
            }
            await coordinator.perform(.init(target: .preset(preset), source: source, origin: .manual))
            if Task.isCancelled { currentDownload = nil }
            downloadTask = nil
        }
    }

    /// A terminal download record is history, never an in-flight operation.
    func isDownloading(preset: ModelPreset) -> Bool {
        guard downloadTask != nil, let current = currentDownload, current.preset.id == preset.id else { return false }
        switch current.status {
        case .pending: return true
        case .downloading, .verifying: return coordinator.operationID != nil
        case .completed, .failed: return false
        }
    }

    func cancelDownload() {
        guard downloadTask != nil else { return }
        cancelRequested = true
        // perform's cancellation handler cancels only the operation this task owns.
        downloadTask?.cancel()
        // Keep ownership until the coordinator has drained the underlying loader.
    }

    func isModelDownloaded(_ preset: ModelPreset) -> Bool { ModelLocator.isPresetDownloaded(preset) }

    func deleteModel(_ preset: ModelPreset) throws {
        let dir = preset.localDirectory()
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
    }
}
