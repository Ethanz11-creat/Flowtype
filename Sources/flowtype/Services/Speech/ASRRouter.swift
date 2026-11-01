import Foundation
import Network
import os

/// A capture-start routing decision. The provider identity and credentials are
/// immutable for the lifetime of a session; stop/fallback never re-reserves a
/// different half-open route from mutable settings.
struct ASRRouteSnapshot: Sendable, Equatable {
    let policy: ASRRoutingPolicy
    let selectedProviderID: String?
    let localAvailable: Bool
    let cloudAvailable: Bool
    let cloudConfiguration: CloudASRRequestConfiguration?
    var language: String? = nil
    var healthGeneration: UInt64 = 0
    var isHealthRecovery: Bool = false
    var localLease: LocalASRLease? = nil
    var cloudIdentity: CloudASRHealthIdentity? { cloudConfiguration.map { CloudASRHealthIdentity(provider: $0.provider) } }

    var shouldStartRealtime: Bool {
        policy != .localOnly && selectedProviderID == ASRProviderID.cloud && cloudAvailable && isRealtime
    }

    var candidateIDs: [String] {
        if policy == .localOnly { return localAvailable ? [ASRProviderID.qwenLocal] : [] }
        if policy == .cloudOnly { return cloudAvailable ? [ASRProviderID.cloud] : [] }
        var ids = selectedProviderID.map { [$0] } ?? []
        if localAvailable, !ids.contains(ASRProviderID.qwenLocal) { ids.append(ASRProviderID.qwenLocal) }
        if cloudAvailable, !ids.contains(ASRProviderID.cloud) { ids.append(ASRProviderID.cloud) }
        return ids
    }

    var isRealtime: Bool {
        cloudConfiguration?.provider.protocolKind == .dashScopeRealtime
    }
}

/// Content-free endpoint/model/transport identity. Credentials are never logged
/// or placed in router health diagnostics.
struct CloudASRHealthIdentity: Sendable, Equatable {
    let providerID: UUID
    let endpoint: String
    let model: String
    let protocolKind: CloudASRProtocolKind
    init(provider: CloudASRProviderConfig) {
        providerID = provider.id
        endpoint = provider.baseURL
        model = provider.model
        protocolKind = provider.protocolKind
    }
}

/// Both the configured service and the observed network belong to a sample.
struct CloudASRHealthToken: Sendable, Equatable {
    let identity: CloudASRHealthIdentity?
    let generation: UInt64
}

/// 健康画像快照（可测的纯数据部分）。
struct RouterHealthSnapshot: Sendable, Equatable {
    var cloudIdentity: CloudASRHealthIdentity? = nil
    var generation: UInt64 = 0
    var realtimeLatencyEWMA: Double = 0
    var realtimeLatencySampledAt: Date? = nil
    var cloudLatencyEWMA: Double = 0
    var cloudLatencySampledAt: Date? = nil
    var cloudConsecutiveFailures: Int = 0
    var networkReachable: Bool = true
    var probeLatencyMs: Double? = nil
    var probeSampledAt: Date? = nil
    /// 采样过但握手失败（与"从未采样"区分）。
    var probeFailed: Bool = false
    /// 最近一次 NWPath 观测特征；用于判断链路是否变化（变化 ⇒ 作废探测样本）。
    var pathSignature: PathSignature? = nil
    var lastHalfOpenUptimeNanoseconds: UInt64? = nil

    var token: CloudASRHealthToken { CloudASRHealthToken(identity: cloudIdentity, generation: generation) }

    mutating func synchronizeIdentity(_ identity: CloudASRHealthIdentity?) {
        guard cloudIdentity != identity else { return }
        self = invalidateLinkSamples(self)
        cloudIdentity = identity
        cloudConsecutiveFailures = 0
    }

    /// Path observation + invalidation are one transaction with capture/results.
    @discardableResult
    mutating func applyNetworkPath(_ current: PathSignature) -> Bool {
        // The first monitor callback is a boundary too: captures made while
        // NWPath was still unknown carry the pre-observation generation and
        // must be rejected once the initial reachable/expensive/interface
        // state is known. Keep `pathChanged(nil, ...) == false` as a pure
        // comparison contract; production state treats nil as invalidating.
        let firstObservation = pathSignature == nil
        let changed = pathChanged(previous: pathSignature, current: current)
        if firstObservation || changed { self = invalidateLinkSamples(self) }
        networkReachable = current.satisfied
        pathSignature = current
        return firstObservation || changed
    }

    mutating func recordSuccess(route: ASRRouteSnapshot, latencyMs: Int, now: Date) {
        guard routeHealthIsCurrent(route, health: self) else { return }
        if route.isHealthRecovery {
            // A real successful request can retire old negative handshake and
            // inference evidence. A fast handshake alone never does this.
            probeLatencyMs = nil
            probeSampledAt = nil
            probeFailed = false
        }
        if route.isRealtime {
            realtimeLatencyEWMA = updateLatencyEWMA(previous: route.isHealthRecovery ? 0 : realtimeLatencyEWMA,
                                                    sample: Double(latencyMs))
            realtimeLatencySampledAt = now
        } else {
            cloudLatencyEWMA = updateLatencyEWMA(previous: route.isHealthRecovery ? 0 : cloudLatencyEWMA,
                                                 sample: Double(latencyMs))
            cloudLatencySampledAt = now
        }
        cloudConsecutiveFailures = 0
    }

    mutating func recordFailure(route: ASRRouteSnapshot) {
        guard routeHealthIsCurrent(route, health: self) else { return }
        cloudConsecutiveFailures += 1
    }

    mutating func recordProbe(token expected: CloudASRHealthToken, latencyMs: Double?, now: Date) {
        guard token == expected else { return }
        probeLatencyMs = latencyMs
        probeSampledAt = now
        probeFailed = latencyMs == nil
    }
}

/// 指数移动平均：`previous == 0` 表示未知，直接采用首个样本。
func updateLatencyEWMA(previous: Double, sample: Double, alpha: Double = 0.3) -> Double {
    previous == 0 ? sample : previous * (1 - alpha) + sample * alpha
}

/// 一次延迟采样是否仍在有效期内（探测样本与真实请求 EWMA 共用同一时间语义）。
func sampleIsFresh(sampledAt: Date?, now: Date, ttl: TimeInterval) -> Bool {
    guard let sampledAt else { return false }
    return now.timeIntervalSince(sampledAt) < ttl
}

/// 对**真实请求**延迟样本做过期处置，策略是**非对称**的：
/// - 新鲜：原样使用。
/// - 过期且"慢"：仍然有效 —— 保守（走本地）不需要新鲜证据。若过期即清零，
///   "握手快但服务端慢"的链路会在 cloud/local 之间来回振荡（握手探测看不见服务端处理耗时，
///   而云端 ASR 的延迟大头正来自推理）。
/// - 过期且"快"：不再可信，降级为未知（0），交给握手探测按当前链路重新判定。
func agedLatencySample(_ ewma: Double, sampledAt: Date?, now: Date, ttl: TimeInterval) -> Double {
    guard ewma != 0 else { return 0 }
    if sampleIsFresh(sampledAt: sampledAt, now: now, ttl: ttl) { return ewma }
    return ewma > ASRRoutingThresholds.cloudLatencyMs ? ewma : 0
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

/// 是否应当做握手探测。仅 `auto` 策略、链路可达、且**非计费/受限**链路时探测：
/// 计费热点上照烧流量最不划算，而热点恰是本该直接走本地的场景。
/// 尚未收到任何观测（nil）时不阻塞探测，保持既有行为。
func shouldProbeCloud(path: PathSignature?, policy: ASRRoutingPolicy) -> Bool {
    guard policy == .auto else { return false }
    guard let path else { return true }
    guard path.satisfied else { return false }
    return !(path.isExpensive || path.isConstrained)
}

/// 链路变化后作废旧链路的延迟证据：探测样本与真实请求 EWMA 都属于**上一条链路**，
/// 保留它们会让"新链路很慢"被旧快样本掩盖。失败连击与可达性由调用方维护，不在此作废。
func invalidateLinkSamples(_ state: RouterHealthSnapshot) -> RouterHealthSnapshot {
    var next = state
    next.generation &+= 1
    next.realtimeLatencyEWMA = 0
    next.realtimeLatencySampledAt = nil
    next.probeLatencyMs = nil
    next.probeSampledAt = nil
    next.probeFailed = false
    next.cloudLatencyEWMA = 0
    next.cloudLatencySampledAt = nil
    next.lastHalfOpenUptimeNanoseconds = nil
    return next
}

/// 云端主机探测的周期/超时/首启延迟（秒）。
enum ASRRouterProbeConfig {
    static let interval: TimeInterval = 30
    static let timeout: TimeInterval = 2.0
    static let firstDelay: TimeInterval = 1
    /// 必须**严格小于** `interval`：采样时刻晚于 tick，若两者相等，下一个 tick 会因
    /// "未过期"被跳过，实际退化成每两拍才探测一次（有效周期翻倍到 ~60s）。
    static let ttl: TimeInterval = interval * 0.6
    /// 真实请求延迟样本的有效期。超过它，陈旧的"快"样本不再可信；陈旧的"慢"样本依然有效。
    static let latencyTtl: TimeInterval = 300
    static let recoveryIntervalNanoseconds: UInt64 = 60_000_000_000
}

/// 生产接线的**唯一**入口：健康快照 + 可用性 + 策略 → 决策输入。
///
/// 抽成纯函数的目的很具体：`ASRRouter.selectChain()` 依赖单例与 MainActor 配置、无法单测，
/// 若把"快照 → 老化 → 决策"的组装留在它里面，接线就能被静默回退而自测仍然全绿
/// （曾经的探测失效 bug 正是这样藏住的）。这里让所有样本时效判定集中在一处并被测试钉住。
func routingInputs(from snapshot: RouterHealthSnapshot,
                   policy: ASRRoutingPolicy,
                   localAvailable: Bool,
                   cloudAvailable: Bool,
                   now: Date) -> ASRRoutingInputs {
    // 探测值同样要论新鲜度：休眠/唤醒后定时器不触发、也没有唤醒重探，
    // 决策若采用数小时前的握手值，就复现了"陈旧样本当当前样本"的同一类 bug。
    // 与 EWMA 采用同一非对称策略：陈旧的"快"值降级为未知，陈旧的"失败"证据保留（保守）。
    let probeIsCurrent = sampleIsFresh(sampledAt: snapshot.probeSampledAt,
                                       now: now,
                                       ttl: ASRRouterProbeConfig.ttl)
    return ASRRoutingInputs(
        policy: policy,
        localAvailable: localAvailable,
        cloudAvailable: cloudAvailable,
        networkReachable: snapshot.networkReachable,
        cloudLatencyEWMA: agedLatencySample(snapshot.cloudLatencyEWMA,
                                            sampledAt: snapshot.cloudLatencySampledAt,
                                            now: now,
                                            ttl: ASRRouterProbeConfig.latencyTtl),
        cloudConsecutiveFailures: snapshot.cloudConsecutiveFailures,
        cloudProbeMs: probeIsCurrent ? snapshot.probeLatencyMs : nil,
        cloudProbeFailed: snapshot.probeFailed
    )
}

/// 无感择优：维护 provider 健康画像 + 网络可达性，输出有序候选 provider 链。
final class ASRRouter: @unchecked Sendable {
    static let shared = ASRRouter()

    private let health = OSAllocatedUnfairLock(initialState: RouterHealthSnapshot())
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "flowtype.asr-router.path")

    private var probeTimer: DispatchSourceTimer?
    private let probeQueue = DispatchQueue(label: "flowtype.asr-router.probe")
    /// 探测是否正在进行，防止链路抖动时重叠刷新。
    private let probeInFlight = OSAllocatedUnfairLock(initialState: false)

    private let configuration: @MainActor @Sendable () -> Configuration
    private let localAvailable: @MainActor @Sendable () -> Bool
    private let localLease: @MainActor @Sendable () -> LocalASRLease?
    private let uptimeNanoseconds: @Sendable () -> UInt64
    private let measureProbe: @Sendable (String, UInt16, TimeInterval) async -> Double?

    /// Dependencies keep the real capture/probe boundary runnable offline.
    init(startMonitoring: Bool = true,
         configuration: @escaping @MainActor @Sendable () -> Configuration = { ConfigurationStore.shared.current },
         localAvailable: @escaping @MainActor @Sendable () -> Bool = { QwenModelState.shared.activeLease != nil },
         localLease: @escaping @MainActor @Sendable () -> LocalASRLease? = { QwenModelState.shared.activeLease },
         uptimeNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         measureProbe: @escaping @Sendable (String, UInt16, TimeInterval) async -> Double? = {
             await CloudProbe.measureLatency(host: $0, port: $1, timeout: $2)
         }) {
        self.configuration = configuration
        self.localAvailable = localAvailable
        self.localLease = localLease
        self.uptimeNanoseconds = uptimeNanoseconds
        self.measureProbe = measureProbe
        guard startMonitoring else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let current = Self.signature(for: path)
            let changed = self.health.withLock { $0.applyNetworkPath(current) }
            guard changed else { return }
            AppLogger.log("[ASRRouter] network path changed (\(current.interface ?? "?")) → latency samples invalidated")
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

    @MainActor
    func recordSuccess(providerID: String, latencyMs: Int, route: ASRRouteSnapshot) {
        guard providerID == ASRProviderID.cloud else { return }
        synchronizeConfigurationIdentity()
        health.withLock { $0.recordSuccess(route: route, latencyMs: latencyMs, now: Date()) }
    }

    @MainActor
    func recordFailure(providerID: String, route: ASRRouteSnapshot) {
        guard providerID == ASRProviderID.cloud else { return }
        synchronizeConfigurationIdentity()
        health.withLock { $0.recordFailure(route: route) }
    }

    /// 启动周期性探测（幂等）。app 启动时调用一次即可。
    /// `@MainActor`：`probeTimer` 的 check-and-set 因此串行化（唯一调用点本就在 MainActor 上）。
    @MainActor
    func startProbing() {
        guard probeTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: probeQueue)
        timer.schedule(deadline: .now() + ASRRouterProbeConfig.firstDelay,
                       repeating: ASRRouterProbeConfig.interval)
        // Must be explicitly `@Sendable`: an unannotated closure formed in this `@MainActor`
        // method would inherit MainActor isolation, then the first tick on `probeQueue`
        // trips Swift 6's executor assertion (dispatch_assert_queue_fail → SIGTRAP).
        timer.setEventHandler { @Sendable in
            Task { await ASRRouter.shared.refreshProbeIfNeeded() }
        }
        timer.resume()
        probeTimer = timer
        AppLogger.log("[ASRRouter] cloud probe started (interval \(Int(ASRRouterProbeConfig.interval))s)")
    }

    /// 按需刷新探测样本。仅 `auto` 策略 + 已配置云端 + 非计费链路时执行。
    func refreshProbeIfNeeded(force: Bool = false) async {
        // 链路抖动会让多个 `force` 刷新重叠，每个都持有一个最长 2s 的连接；串行化即可。
        let alreadyRunning = probeInFlight.withLock { running -> Bool in
            if running { return true }
            running = true
            return false
        }
        guard !alreadyRunning else { return }
        defer { probeInFlight.withLock { $0 = false } }

        // Capture configuration and its token without suspension between them.
        let (cfg, snap) = await MainActor.run {
            self.synchronizeConfigurationIdentity()
            return (self.configuration(), self.snapshot())
        }
        guard let effective = cfg.effectiveCloudASRConfig else { return }
        guard shouldProbeCloud(path: snap.pathSignature, policy: cfg.asrRoutingPolicy) else { return }
        guard let endpoint = CloudProbe.probeEndpoint(fromBaseURL: effective.provider.baseURL) else { return }
        if !force, sampleIsFresh(sampledAt: snap.probeSampledAt, now: Date(), ttl: ASRRouterProbeConfig.ttl) { return }

        let ms = await measureProbe(endpoint.host, endpoint.port, ASRRouterProbeConfig.timeout)
        await MainActor.run {
            // Configuration may have changed while the handshake was suspended,
            // even when no subsequent capture or periodic probe has run yet.
            self.synchronizeConfigurationIdentity()
            guard shouldProbeCloud(path: self.snapshot().pathSignature, policy: self.configuration().asrRoutingPolicy) else { return }
            self.health.withLock { $0.recordProbe(token: snap.token, latencyMs: ms, now: Date()) }
        }
    }

    /// 收集可用性与健康画像，交给纯函数决策，映射为有序 provider 实例。
    func selectChain() async -> [ASRProvider] {
        // Diagnostic selection never spends the user-session recovery slot.
        let route = await MainActor.run {
            self.synchronizeConfigurationIdentity()
            return makeASRRouteSnapshot(configuration: self.configuration(), localAvailable: self.localAvailable(), health: self.snapshot(), localLease: self.localLease())
        }
        return route.candidateIDs.compactMap { id in
            id == ASRProviderID.local ? route.localLease?.provider : ASRProviderRegistry.shared.provider(forID: id)
        }
    }

    /// Snapshot routing exactly once at capture start. The returned identity is
    /// carried through stop and fallback so a settings edit cannot change the
    /// protocol or credentials of an active recording.
    @MainActor
    func captureStartRoute() async -> ASRRouteSnapshot {
        let cfg = configuration()
        let lease = localLease()
        let local = localAvailable()
        let uptime = uptimeNanoseconds()
        return health.withLock {
            reserveASRCaptureRoute(configuration: cfg, localAvailable: local, health: &$0,
                                   now: Date(), uptimeNanoseconds: uptime, localLease: lease)
        }
    }

    @MainActor
    private func synchronizeConfigurationIdentity() {
        let identity = configuration().effectiveCloudASRConfig.map { CloudASRHealthIdentity(provider: $0.provider) }
        health.withLock { $0.synchronizeIdentity(identity) }
    }

    /// Descriptive alias used by pipeline code and tests.
    func snapshotCaptureRoute() async -> ASRRouteSnapshot {
        await captureStartRoute()
    }
}

/// Monotonic stop-to-delivery budget. Wall-clock changes and sleep/wake do not
/// extend it; every stage asks for a fresh bounded timeout from this value.
struct CompletionBudget: Sendable, Equatable {
    private let deadlineNanoseconds: UInt64
    private let startedNanoseconds: UInt64

    init(seconds: TimeInterval = 20, nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        let delta = UInt64(max(0, seconds) * 1_000_000_000)
        self.startedNanoseconds = nowNanoseconds
        self.deadlineNanoseconds = nowNanoseconds &+ delta
    }

    var elapsedSeconds: TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        return now > startedNanoseconds ? TimeInterval(now - startedNanoseconds) / 1_000_000_000 : 0
    }

    var remainingSeconds: TimeInterval {
        remainingSeconds(at: DispatchTime.now().uptimeNanoseconds)
    }

    func remainingSeconds(at nowNanoseconds: UInt64) -> TimeInterval {
        guard nowNanoseconds < deadlineNanoseconds else { return 0 }
        return TimeInterval(deadlineNanoseconds - nowNanoseconds) / 1_000_000_000
    }

    func timeout(maximum: TimeInterval) -> TimeInterval {
        min(max(0, maximum), remainingSeconds)
    }

    var isExpired: Bool { remainingSeconds <= 0 }
}

/// Pure capture route construction also makes privacy gating testable offline.
func makeASRRouteSnapshot(configuration cfg: Configuration, localAvailable: Bool,
                          health: RouterHealthSnapshot, now: Date = Date(), localLease: LocalASRLease? = nil) -> ASRRouteSnapshot {
    let effective = cfg.effectiveCloudASRConfig
    let cloud = effective.map {
        CloudASRRequestConfiguration(provider: $0.provider, apiKey: $0.apiKey, sendContext: cfg.cloudASRSendContext)
    }
    let available = cloud.map {
        !$0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !$0.provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !$0.provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    } ?? false
    var transportHealth = health
    if cloud?.provider.protocolKind == .dashScopeRealtime {
        transportHealth.cloudLatencyEWMA = health.realtimeLatencyEWMA
        transportHealth.cloudLatencySampledAt = health.realtimeLatencySampledAt
    }
    let inputs = routingInputs(from: transportHealth, policy: cfg.asrRoutingPolicy,
                               localAvailable: localAvailable, cloudAvailable: available, now: now)
    return ASRRouteSnapshot(policy: cfg.asrRoutingPolicy, selectedProviderID: selectASRChain(inputs).first,
                            localAvailable: localAvailable, cloudAvailable: available,
                            cloudConfiguration: cloud, language: cfg.asrLanguage.qwenLanguageCode, healthGeneration: health.generation, localLease: localLease)
}

/// Caller owns the health lock: decision and reservation are indivisible.
func reserveASRCaptureRoute(configuration cfg: Configuration, localAvailable: Bool,
                            health: inout RouterHealthSnapshot, now: Date,
                            uptimeNanoseconds uptime: UInt64, localLease: LocalASRLease? = nil) -> ASRRouteSnapshot {
    let identity = cfg.effectiveCloudASRConfig.map { CloudASRHealthIdentity(provider: $0.provider) }
    health.synchronizeIdentity(identity)
    let route = makeASRRouteSnapshot(configuration: cfg, localAvailable: localAvailable, health: health, now: now, localLease: localLease)
    guard route.policy == .auto, route.localAvailable, route.cloudAvailable,
          route.selectedProviderID == ASRProviderID.qwenLocal, health.networkReachable else { return route }
    if let last = health.lastHalfOpenUptimeNanoseconds {
        guard uptime >= last, uptime - last >= ASRRouterProbeConfig.recoveryIntervalNanoseconds else { return route }
    }
    health.lastHalfOpenUptimeNanoseconds = uptime
    return ASRRouteSnapshot(policy: route.policy, selectedProviderID: ASRProviderID.cloud,
                            localAvailable: route.localAvailable, cloudAvailable: route.cloudAvailable,
                            cloudConfiguration: route.cloudConfiguration, language: route.language,
                            healthGeneration: route.healthGeneration, isHealthRecovery: true, localLease: route.localLease)
}

func completionStageTimeout(remaining: TimeInterval, cloud: Bool, policy: ASRRoutingPolicy,
                            localAvailable: Bool) -> TimeInterval {
    max(0, min(remaining, cloud && policy == .auto && localAvailable ? 5 : remaining))
}

func routeHealthIsCurrent(_ route: ASRRouteSnapshot, health: RouterHealthSnapshot) -> Bool {
    route.healthGeneration == health.generation && route.cloudIdentity == health.cloudIdentity
}
