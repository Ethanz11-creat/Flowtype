import Foundation
import Combine

enum QwenModelStatus: Equatable {
    case notLoaded
    case downloading(progress: Double, speedMBps: Double, etaSeconds: Int)
    case stalled
    case loading
    case ready
    case error(reason: String, retryable: Bool)

    var isLoading: Bool {
        switch self {
        case .downloading, .loading, .stalled: return true
        default: return false
        }
    }
}

final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTick = Date()
    private var lastFraction = 0.0
    private var lastBytes = 0.0

    func update(fraction: Double, totalBytes: Double) -> (mbps: Double, eta: Int) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        let bytes = fraction * totalBytes
        var mbps = 0.0
        if dt > 0.25, fraction > lastFraction {
            mbps = (bytes - lastBytes) / dt / (1024 * 1024)
            lastTick = now; lastFraction = fraction; lastBytes = bytes
        } else if fraction > lastFraction {
            lastFraction = fraction; lastBytes = bytes; lastTick = now
        }
        let remaining = max(0, totalBytes - bytes)
        let eta = mbps > 0.01 ? Int(remaining / (mbps * 1024 * 1024)) : 0
        return (mbps, eta)
    }

    func secondsSinceLastTick() -> Double {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastTick)
    }
}

@MainActor
final class QwenModelState: ObservableObject {
    static let shared = QwenModelState()

    @Published private(set) var status: QwenModelStatus = .notLoaded

    func loadModel(provider: QwenASRProvider) async {
        guard !status.isLoading else { return }
        if provider.isLoaded { status = .ready; return }

        let cfg = ConfigurationStore.shared.current
        let tier = HardwareProfiler.currentTier()
        let activePreset = ModelPreset.preset(forID: cfg.selectedLocalModelID)
            ?? ModelPreset.recommendedModel(for: tier)

        if let resolved = ModelLocator.resolveActiveModel(config: cfg) {
            status = .loading
            do {
                try await provider.loadModel(
                    modelId: resolved.modelId,
                    cacheDir: resolved.directory,
                    offlineMode: true
                )
                status = .ready
                AppLogger.log("[ModelProvision] Loaded offline from \(resolved.directory.path) (modelId=\(resolved.modelId))")
                return
            } catch {
                AppLogger.log("[ModelProvision] Offline load from \(resolved.directory.path) failed (\(error)); falling through to download")
            }
        }

        // Auto mode (selectedLocalModelID == nil) must still download a model —
        // `activePreset` above already falls back to the hardware-recommended model.
        // Only gate on onboarding: a fresh user may not have chosen a model yet but
        // still needs the local engine to work out of the box.
        guard cfg.hasCompletedOnboarding else {
            status = .notLoaded
            AppLogger.log("[ModelProvision] Skipping auto-download: onboarding not complete")
            return
        }

        applyDownloadEndpoint(cfg.downloadSource)
        await downloadWithRetry(provider: provider, preset: activePreset, maxAttempts: 3)
    }

    func handleDownloadCompleted(preset: ModelPreset) async {
        let provider = ASRProviderRegistry.shared.qwenLocalProvider
        if provider.isLoaded {
            provider.unloadModel()
        }
        status = .loading
        do {
            try await provider.loadPreset(preset)
            status = .ready
            AppLogger.log("[ModelProvision] Auto-loaded downloaded preset \(preset.id)")
        } catch {
            status = .notLoaded
            AppLogger.log("[ModelProvision] Auto-load failed for \(preset.id): \(error)")
        }
    }

    private func applyDownloadEndpoint(_ source: DownloadSource) {
        if let endpoint = source.endpoint(isChina: DownloadSource.systemIsLikelyChina()) {
            setenv("HF_ENDPOINT", endpoint, 1)
            AppLogger.log("[ModelProvision] HF_ENDPOINT=\(endpoint)")
        } else {
            unsetenv("HF_ENDPOINT")
        }
    }

    private func downloadWithRetry(provider: QwenASRProvider, preset: ModelPreset, maxAttempts: Int) async {
        let totalBytes = Double(preset.expectedSizeBytes)
        let destDir = preset.localDirectory()
        let fm = FileManager.default
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        for attempt in 1...maxAttempts {
            status = .downloading(progress: 0, speedMBps: 0, etaSeconds: 0)
            let progress = ProgressTracker()
            let loadTask = Task { [provider] in
                try await provider.loadModel(
                    modelId: preset.repoId,
                    cacheDir: destDir,
                    offlineMode: false
                ) { @Sendable p, _ in
                    let snap = progress.update(fraction: p, totalBytes: totalBytes)
                    Task { @MainActor in
                        guard case .downloading = QwenModelState.shared.status else { return }
                        if p >= 1.0 {
                            QwenModelState.shared.status = .loading
                        } else {
                            QwenModelState.shared.status = .downloading(progress: p, speedMBps: snap.mbps, etaSeconds: snap.eta)
                        }
                    }
                }
            }
            let watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    if progress.secondsSinceLastTick() > 30 {
                        await MainActor.run { self?.status = .stalled }
                        loadTask.cancel()
                        return
                    }
                }
            }
            do {
                try await loadTask.value
                watchdog.cancel()
                status = .ready
                AppLogger.log("[ModelProvision] Downloaded + loaded (attempt \(attempt))")
                return
            } catch {
                watchdog.cancel()
                provider.unloadModel()
                AppLogger.log("[ModelProvision] Download attempt \(attempt) failed: \(error)")
                if attempt < maxAttempts {
                    try? await Task.sleep(for: .seconds(Double(attempt * 10)))
                } else {
                    status = .error(reason: "下载失败或停滞。可重试，或在设置里「指定已下载的模型文件夹」。", retryable: true)
                }
            }
        }
    }
}
