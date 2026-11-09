import Foundation

/// Compatibility boundary for pre-binding pipeline fixtures. Production ASRStage
/// always executes only bindings; this fixture captures injected providers first.
final class FixtureASRStage: PipelineStage, @unchecked Sendable {
    let name = "ASR"
    private let stage: ASRStage
    private let providerForID: @Sendable (String) -> (any ASRProvider)?
    init(healthRecorder: @escaping @MainActor @Sendable (String, Int?, ASRRouteSnapshot) -> Void = { _, _, _ in },
         providerForID: @escaping @Sendable (String) -> (any ASRProvider)? = { _ in nil },
         realtimeFactory: @escaping RealtimeSessionFactory = liveRealtimeSessionFactory,
         routeFactory: @escaping @Sendable () async -> ASRRouteSnapshot = { .init(policy: .auto, bindings: []) },
         speechPreflight: @escaping @Sendable ([Float], Int) async throws -> SpeechPreflightDecision = {
             try await SpeechPreflight.evaluate(samples: $0, sampleRate: $1)
         }, phrases: @escaping @MainActor @Sendable () -> [String] = { [] }) {
        self.providerForID = providerForID
        stage = ASRStage(healthRecorder: healthRecorder, realtimeFactory: realtimeFactory,
            routeFactory: { Self.capture(await routeFactory(), providerForID: providerForID) },
            speechPreflight: speechPreflight, phrases: phrases)
    }
    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        await MainActor.run {
            if let route = context.captureRoute { context.captureRoute = Self.capture(route, providerForID: providerForID) }
        }
        return await stage.execute(payload: payload, context: context)
    }
    static func capture(_ route: ASRRouteSnapshot,
                        providerForID: @Sendable (String) -> (any ASRProvider)? = { _ in nil }) -> ASRRouteSnapshot {
        if !route.bindings.isEmpty {
            var captured = route
            captured.bindings = route.bindings.map { binding in
                let underlying = (binding.provider as? CapturedCloudASRProvider)?.underlying ?? binding.provider
                guard underlying is UnavailableASRFixtureProvider,
                      let provider = providerForID(binding.descriptor.id.rawValue) else { return binding }
                let wrapped: any ASRProvider = binding.cloudConfiguration.map { CapturedCloudASRProvider(configuration: $0, underlying: provider) } ?? provider
                return .init(descriptor: binding.descriptor, provider: wrapped, nativeLease: binding.nativeLease,
                             credentialGeneration: binding.credentialGeneration)
            }
            return captured
        }
        var ids: [String] = []
        if route.policy == .localOnly { ids = route.localAvailable ? [ASRProviderID.local] : [] }
        else if route.policy == .cloudOnly { ids = route.cloudAvailable ? [ASRProviderID.cloud] : [] }
        else {
            if let selected = route.selectedProviderID { ids.append(selected) }
            if route.localAvailable, !ids.contains(ASRProviderID.local) { ids.append(ASRProviderID.local) }
            if route.cloudAvailable, !ids.contains(ASRProviderID.cloud) { ids.append(ASRProviderID.cloud) }
        }
        var captured = route
        captured.bindings = ids.compactMap { id in
            let cloud = id == ASRProviderID.cloud
            let lease = id == ASRProviderID.local ? route.localLease : nil
            var provider: any ASRProvider = lease?.provider ?? providerForID(id) ?? UnavailableASRFixtureProvider()
            if cloud, let configuration = route.cloudConfiguration {
                provider = CapturedCloudASRProvider(configuration: configuration, underlying: provider)
            }
            return .init(descriptor: .init(id: .init(rawValue: id), revision: lease?.id ?? route.cloudConfiguration?.provider.revision ?? UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, displayName: id,
                modelID: cloud ? route.cloudConfiguration?.provider.model : lease?.identity.id,
                location: cloud ? .cloud : .native, requiresInternet: cloud, capabilities: provider.capabilities,
                maxUploadBytes: nil), provider: provider, nativeLease: lease, credentialGeneration: nil)
        }
        return captured
    }
}

private struct UnavailableASRFixtureProvider: ASRProvider {
    let id = "fixture-unavailable"
    let displayName = "Unavailable fixture"
    let capabilities = ASRCapabilities(supportsLanguageHint: false, supportsContextHint: false, requiresNetwork: false, location: .onDevice)
    var isAvailable: Bool { get async { false } }
    func transcribe(_ request: ASRRequest) async throws -> ASRResult { throw SpeechProviderError.notAvailable }
}

/// Legacy routing characterization fixtures only; live capture uses ASRRouter bindings.
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
    return FixtureASRStage.capture(ASRRouteSnapshot(policy: cfg.asrRoutingPolicy, selectedProviderID: selectASRChain(inputs).first,
                            localAvailable: localAvailable, cloudAvailable: available,
                            cloudConfiguration: cloud, language: cfg.asrLanguage.qwenLanguageCode, healthGeneration: health.generation, localLease: localLease))
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
    return FixtureASRStage.capture(ASRRouteSnapshot(policy: route.policy, selectedProviderID: ASRProviderID.cloud,
                            localAvailable: route.localAvailable, cloudAvailable: route.cloudAvailable,
                            cloudConfiguration: route.cloudConfiguration, language: route.language,
                            healthGeneration: route.healthGeneration, isHealthRecovery: true, localLease: route.localLease))
}
