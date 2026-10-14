import Foundation
import Network
import os

/// 健康画像快照（可测的纯数据部分）。
struct RouterHealthSnapshot: Sendable, Equatable {
    var cloudLatencyEWMA: Double = 0
    var cloudConsecutiveFailures: Int = 0
    var networkReachable: Bool = true
    var probeLatencyMs: Double? = nil
    var probeSampledAt: Date? = nil
    /// 采样过但握手失败（与"从未采样"区分）。
    var probeFailed: Bool = false
    /// 最近一次 NWPath 观测特征；用于判断链路是否变化（变化 ⇒ 作废探测样本）。
    var pathSignature: PathSignature? = nil
}

/// 指数移动平均：`previous == 0` 表示未知，直接采用首个样本。
func updateLatencyEWMA(previous: Double, sample: Double, alpha: Double = 0.3) -> Double {
    previous == 0 ? sample : previous * (1 - alpha) + sample * alpha
}

/// 探测样本是否仍在有效期内。
func probeIsFresh(sampledAt: Date?, now: Date, ttl: TimeInterval) -> Bool {
    guard let sampledAt else { return false }
    return now.timeIntervalSince(sampledAt) < ttl
}

/// 一次 NWPath 观测的可比对特征。链路特征变化 ⇒ 旧延迟/探测样本来自另一条链路，必须作废。
struct PathSignature: Equatable, Sendable {
    let satisfied: Bool
    let isExpensive: Bool
    let isConstrained: Bool
    let interface: String?
}

/// 判定链路是否发生变化（首次观测不算变化）。纯函数，便于测试。
func pathChanged(previous: PathSignature?, current: PathSignature) -> Bool {
    guard let previous else { return false }
    return previous != current
}

/// 云端主机探测的周期/超时/首启延迟（秒）。
enum ASRRouterProbeConfig {
    static let interval: TimeInterval = 30
    static let timeout: TimeInterval = 2.0
    static let firstDelay: TimeInterval = 1
}

/// 无感择优：维护 provider 健康画像 + 网络可达性，输出有序候选 provider 链。
final class ASRRouter: @unchecked Sendable {
    static let shared = ASRRouter()

    private let health = OSAllocatedUnfairLock(initialState: RouterHealthSnapshot())
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "flowtype.asr-router.path")

    private var probeTimer: DispatchSourceTimer?
    private let probeQueue = DispatchQueue(label: "flowtype.asr-router.probe")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let current = Self.signature(for: path)
            let changed = self.health.withLock { state -> Bool in
                let previous = state.pathSignature
                state.networkReachable = current.satisfied
                state.pathSignature = current
                return pathChanged(previous: previous, current: current)
            }
            guard changed else { return }
            // 链路换了一条（Wi-Fi ↔ 热点 ↔ VPN）：旧延迟与探测样本属于另一条链路，立即作废并重探，
            // 否则切换后的首次听写会复用旧"快"样本，白等一整轮慢请求。
            self.health.withLock {
                $0.probeLatencyMs = nil
                $0.probeSampledAt = nil
                $0.probeFailed = false
            }
            AppLogger.log("[ASRRouter] network path changed (\(current.interface ?? "?")) → probe cache invalidated")
            Task { await self.refreshProbeIfNeeded(force: true) }
        }
        monitor.start(queue: monitorQueue)
    }

    /// 把 `NWPath` 映射为可比对特征。`NWPath` 不可构造，故仅做映射，判定逻辑留给纯函数 `pathChanged`。
    private static func signature(for path: NWPath) -> PathSignature {
        let interface: String?
        if path.usesInterfaceType(.wifi) { interface = "wifi" }
        else if path.usesInterfaceType(.cellular) { interface = "cellular" }
        else if path.usesInterfaceType(.wiredEthernet) { interface = "wired" }
        else if path.usesInterfaceType(.loopback) { interface = "loopback" }
        else { interface = "other" }
        return PathSignature(satisfied: path.status == .satisfied,
                             isExpensive: path.isExpensive,
                             isConstrained: path.isConstrained,
                             interface: interface)
    }

    func snapshot() -> RouterHealthSnapshot { health.withLock { $0 } }

    func recordSuccess(providerID: String, latencyMs: Int) {
        guard ASRProviderRegistry.shared.provider(forID: providerID)?.capabilities.requiresNetwork == true else { return }
        health.withLock {
            $0.cloudLatencyEWMA = updateLatencyEWMA(previous: $0.cloudLatencyEWMA, sample: Double(latencyMs))
            $0.cloudConsecutiveFailures = 0
        }
        AppLogger.log("[ASRRouter] cloud EWMA=\(Int(health.withLock { $0.cloudLatencyEWMA }))ms")
    }

    func recordFailure(providerID: String) {
        guard ASRProviderRegistry.shared.provider(forID: providerID)?.capabilities.requiresNetwork == true else { return }
        let n = health.withLock { s -> Int in s.cloudConsecutiveFailures += 1; return s.cloudConsecutiveFailures }
        AppLogger.log("[ASRRouter] cloud failure streak=\(n)")
    }

    /// 启动周期性探测（幂等）。app 启动时调用一次即可。
    func startProbing() {
        guard probeTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: probeQueue)
        timer.schedule(deadline: .now() + ASRRouterProbeConfig.firstDelay,
                       repeating: ASRRouterProbeConfig.interval)
        timer.setEventHandler {
            Task { await ASRRouter.shared.refreshProbeIfNeeded() }
        }
        timer.resume()
        probeTimer = timer
        AppLogger.log("[ASRRouter] cloud probe started (interval \(Int(ASRRouterProbeConfig.interval))s)")
    }

    /// 按需刷新探测样本。仅 `auto` 策略 + 已配置云端 + 网络可达时执行。
    func refreshProbeIfNeeded(force: Bool = false) async {
        let cfg = await MainActor.run { ConfigurationStore.shared.current }
        guard cfg.asrRoutingPolicy == .auto else { return }
        guard let effective = cfg.effectiveCloudASRConfig else { return }
        guard let endpoint = CloudProbe.probeEndpoint(fromBaseURL: effective.provider.baseURL) else { return }
        let snap = snapshot()
        guard snap.networkReachable else { return }
        if !force, probeIsFresh(sampledAt: snap.probeSampledAt, now: Date(), ttl: ASRRouterProbeConfig.interval) { return }

        let ms = await CloudProbe.measureLatency(host: endpoint.host,
                                                port: endpoint.port,
                                                timeout: ASRRouterProbeConfig.timeout)
        health.withLock {
            $0.probeLatencyMs = ms
            $0.probeSampledAt = Date()
            $0.probeFailed = (ms == nil)   // "采了但失败" 与 "从未采样" 必须区分
        }
        let shown = ms.map { String(format: "%.0f", $0) } ?? "nil"
        AppLogger.log("[ASRRouter] cloud probe \(endpoint.host) → \(shown)ms")
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
            cloudConsecutiveFailures: snap.cloudConsecutiveFailures,
            cloudProbeMs: snap.probeLatencyMs,
            cloudProbeFailed: snap.probeFailed
        )
        return selectASRChain(inputs).compactMap { ASRProviderRegistry.shared.provider(forID: $0) }
    }
}
