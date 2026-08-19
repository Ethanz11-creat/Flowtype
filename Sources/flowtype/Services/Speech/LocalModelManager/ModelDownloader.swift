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

    private init() {}

    func startDownload(preset: ModelPreset) {
        if currentDownload != nil { return }
        currentDownload = (preset, .pending)
        downloadTask = Task {
            await downloadPreset(preset)
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        currentDownload = nil
    }

    func isModelDownloaded(_ preset: ModelPreset) -> Bool {
        ModelLocator.isPresetDownloaded(preset)
    }

    func deleteModel(_ preset: ModelPreset) throws {
        let dir = preset.localDirectory()
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
        }
    }

    private func downloadPreset(_ preset: ModelPreset) async {
        currentDownload = (preset, .pending)

        let requiredSpace = preset.expectedSizeBytes * 2
        if let freeSpace = freeDiskSpaceInBytes(), freeSpace < requiredSpace {
            let requiredGB = Double(requiredSpace) / 1_000_000_000.0
            currentDownload = (preset, .failed("磁盘空间不足，需要至少 \(String(format: "%.1f", requiredGB)) GB 可用空间"))
            return
        }

        let source = ConfigurationStore.shared.current.downloadSource
        if let endpoint = source.endpoint(isChina: DownloadSource.systemIsLikelyChina()) {
            setenv("HF_ENDPOINT", endpoint, 1)
        } else {
            unsetenv("HF_ENDPOINT")
        }

        let destDir = preset.localDirectory()
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        currentDownload = (preset, .downloading(progress: 0))

        let provider = ASRProviderRegistry.shared.qwenLocalProvider
        do {
            let presetID = preset.id
            try await provider.loadModel(
                modelId: preset.repoId,
                cacheDir: destDir,
                offlineMode: false,
                progressHandler: { @Sendable progress, _ in
                    Task { @MainActor in
                        let dl = ModelDownloader.shared
                        guard let current = dl.currentDownload,
                              current.preset.id == presetID else { return }
                        if case .downloading = current.status {
                            dl.currentDownload = (current.preset, .downloading(progress: progress))
                        }
                    }
                }
            )

            provider.unloadModel()

            currentDownload = (preset, .verifying)

            let minBytes = minValidBytes(for: preset)
            if ModelLocator.validateComplete(destDir, minBytes: minBytes) {
                currentDownload = (preset, .completed)
                AppLogger.log("[ModelDownloader] Download complete for \(preset.id)")
                await QwenModelState.shared.handleDownloadCompleted(preset: preset)
            } else {
                currentDownload = (preset, .failed("模型文件验证不完整"))
                AppLogger.log("[ModelDownloader] Validation failed for \(preset.id)")
            }
        } catch is CancellationError {
            provider.unloadModel()
            currentDownload = nil
            AppLogger.log("[ModelDownloader] Download cancelled for \(preset.id)")
        } catch {
            provider.unloadModel()
            currentDownload = (preset, .failed(error.localizedDescription))
            AppLogger.log("[ModelDownloader] Download failed for \(preset.id): \(error)")
        }
    }

    private func minValidBytes(for preset: ModelPreset) -> Int64 {
        let floor = preset.expectedSizeBytes * 8 / 10
        return max(floor, 600 * 1024 * 1024)
    }

    nonisolated private func freeDiskSpaceInBytes() -> Int64? {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            if let freeSize = attrs[.systemFreeSize] as? NSNumber {
                return freeSize.int64Value
            }
        } catch {
            AppLogger.log("[ModelDownloader] Failed to get free disk space: \(error)")
        }
        return nil
    }
}
