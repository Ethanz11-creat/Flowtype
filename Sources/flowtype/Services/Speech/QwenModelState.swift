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

/// Thread-safe download progress → speed (MB/s) + ETA + stall detection.
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

    /// Load ladder: specified folder / known caches (offline, zero network) → download (mirror +
    /// stall watchdog + retry). Forcing offlineMode when a complete local copy exists is what
    /// stops the occasional per-launch network-revalidation hang.
    func loadModel(provider: QwenASRProvider) async {
        guard !status.isLoading else { return }
        if provider.isLoaded { status = .ready; return }

        let cfg = ConfigurationStore.shared.current
        let configured = cfg.localModelPath
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }

        // 0 + 1: offline-first — specified folder, then known caches. Zero network.
        if let local = ModelLocator.firstCompleteLocalCopy(configured: configured) {
            status = .loading
            do {
                try await provider.loadModel(cacheDir: local, offlineMode: true)
                status = .ready
                AppLogger.log("[ModelProvision] Loaded offline from \(local.path)")
                return
            } catch {
                AppLogger.log("[ModelProvision] Offline load from \(local.path) failed (\(error)); falling through to download")
            }
        }

        // 2: download via the chosen endpoint, with stall watchdog + retry.
        applyDownloadEndpoint(cfg.downloadSource)
        await downloadWithRetry(provider: provider, maxAttempts: 3)
    }

    private func applyDownloadEndpoint(_ source: DownloadSource) {
        if let endpoint = source.endpoint(isChina: DownloadSource.systemIsLikelyChina()) {
            setenv("HF_ENDPOINT", endpoint, 1)
            AppLogger.log("[ModelProvision] HF_ENDPOINT=\(endpoint)")
        } else {
            unsetenv("HF_ENDPOINT")
        }
    }

    private func downloadWithRetry(provider: QwenASRProvider, maxAttempts: Int) async {
        let totalBytes = 680.0 * 1024 * 1024
        for attempt in 1...maxAttempts {
            status = .downloading(progress: 0, speedMBps: 0, etaSeconds: 0)
            let progress = ProgressTracker()
            let loadTask = Task { [provider] in
                try await provider.loadModel(offlineMode: false) { @Sendable p, _ in
                    let snap = progress.update(fraction: p, totalBytes: totalBytes)
                    Task { @MainActor in
                        guard QwenModelState.shared.status.isLoading else { return }
                        if p >= 1.0 {
                            QwenModelState.shared.status = .loading
                        } else {
                            QwenModelState.shared.status = .downloading(progress: p, speedMBps: snap.mbps, etaSeconds: snap.eta)
                        }
                    }
                }
            }
            // Watchdog: no byte progress for 30 s → cancel this attempt (the real "下载不动" fix).
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
                AppLogger.log("[ModelProvision] Download attempt \(attempt) failed: \(error)")
                if attempt < maxAttempts {
                    try? await Task.sleep(for: .seconds(Double(attempt * 10)))   // 10s / 20s backoff
                } else {
                    status = .error(reason: "下载失败或停滞。可重试，或在设置里「指定已下载的模型文件夹」。", retryable: true)
                }
            }
        }
    }
}
