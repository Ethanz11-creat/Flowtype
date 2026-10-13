import Foundation
import Network
import os

/// 健康画像快照（可测的纯数据部分）。
struct RouterHealthSnapshot: Sendable, Equatable {
    var cloudLatencyEWMA: Double = 0
    var cloudConsecutiveFailures: Int = 0
    var networkReachable: Bool = true
}

/// 指数移动平均：`previous == 0` 表示未知，直接采用首个样本。
func updateLatencyEWMA(previous: Double, sample: Double, alpha: Double = 0.3) -> Double {
    previous == 0 ? sample : previous * (1 - alpha) + sample * alpha
}

/// 无感择优：维护 provider 健康画像 + 网络可达性，输出有序候选 provider 链。
final class ASRRouter: @unchecked Sendable {
    static let shared = ASRRouter()

    private let health = OSAllocatedUnfairLock(initialState: RouterHealthSnapshot())
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "flowtype.asr-router.path")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.health.withLock { $0.networkReachable = (path.status == .satisfied) }
        }
        monitor.start(queue: monitorQueue)
    }

    func snapshot() -> RouterHealthSnapshot { health.withLock { $0 } }

    func recordSuccess(providerID: String, latencyMs: Int) {
        guard providerID == "cloud-asr" else { return }
        health.withLock {
            $0.cloudLatencyEWMA = updateLatencyEWMA(previous: $0.cloudLatencyEWMA, sample: Double(latencyMs))
            $0.cloudConsecutiveFailures = 0
        }
        AppLogger.log("[ASRRouter] cloud EWMA=\(Int(health.withLock { $0.cloudLatencyEWMA }))ms")
    }

    func recordFailure(providerID: String) {
        guard providerID == "cloud-asr" else { return }
        let n = health.withLock { s -> Int in s.cloudConsecutiveFailures += 1; return s.cloudConsecutiveFailures }
        AppLogger.log("[ASRRouter] cloud failure streak=\(n)")
    }

    /// 收集可用性与健康画像，交给纯函数决策，映射为有序 provider 实例。
    func selectChain() async -> [ASRProvider] {
        let cfg = await MainActor.run { ConfigurationStore.shared.current }
        let qwen = ASRProviderRegistry.shared.qwenLocalProvider
        let cloud = ASRProviderRegistry.shared.cloudProvider
        let localAvailable = qwen.isLoaded
        let cloudAvailable = await cloud.isAvailable
        let snap = snapshot()

        let inputs = ASRRoutingInputs(
            policy: cfg.asrRoutingPolicy,
            localAvailable: localAvailable,
            cloudAvailable: cloudAvailable,
            networkReachable: snap.networkReachable,
            cloudLatencyEWMA: snap.cloudLatencyEWMA,
            cloudConsecutiveFailures: snap.cloudConsecutiveFailures
        )
        return selectASRChain(inputs).compactMap { ASRProviderRegistry.shared.provider(forID: $0) }
    }
}
