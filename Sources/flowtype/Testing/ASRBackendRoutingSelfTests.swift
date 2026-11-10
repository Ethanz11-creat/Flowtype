import Foundation
import GRDB
import os

enum ASRBackendRoutingSelfTests {
    @MainActor static func run(_ r: SelfTest.Reporter) async {
        await testNativeHealthRecoveryAndBudget(r)
        await testServiceHealthRecovery(r)
        await testOfflineServiceReadiness(r)
        await testActualBackendHistoryAndRecovery(r)
        await testPolicyAndNetworkMatrix(r)
        testRoutingMatrix(r)
        await testCaptureIdentitySurvivesEdits(r)
        await testCancelledPrimaryNeverFallsBack(r)
        await testLegacyResolutionAndCredentialFailures(r)
        await testServiceConsentAndRealtimeBinding(r)
        await testExcludedCredentialsNeverRead(r)
        await testEligibleCaptureFailuresKeepAttemptedCause(r)
    }

    // Catches the fixed cloud/native slots silently discarding selected loopback services.
    @MainActor static func testPolicyAndNetworkMatrix(_ r: SelfTest.Reporter) async {
        var config = Configuration()
        let profile = LocalASRServiceProfile(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            revision: UUID(), name: "Fixture", baseURL: "http://127.0.0.1:8123/v1", protocolKind: .openAICompatible,
            modelID: "captured-model", authentication: .none, fieldCapabilities: .init())
        config.localASRServices = [profile]
        config.asrBackendSelection = .init(primary: .init(rawValue: "service:11111111-1111-1111-1111-111111111111"))
        config.asrRoutingPolicy = .localOnly
        let router = ASRRouter(startMonitoring: false, internetAvailable: { false }, configuration: { config }, localAvailable: { false }, localLease: { nil })
        let route = await router.captureStartRoute()
        r.eq(route.candidateIDs, ["service:11111111-1111-1111-1111-111111111111"], "localOnly retains selected loopback service")
    }
}

private struct RoutingProvider: ASRProvider {
    let id: String
    var displayName: String { id }
    let capabilities = ASRCapabilities(supportsLanguageHint: true, supportsContextHint: true, requiresNetwork: false, location: .onDevice)
    var isAvailable: Bool { get async { true } }
    var operation: @Sendable (ASRRequest) async throws -> ASRResult = { _ in .init(text: "native", providerID: "fixture", latencyMs: 10) }
    func transcribe(_ request: ASRRequest) async throws -> ASRResult { try await operation(request) }
}

private final class RoutingHTTPFixture: URLProtocol, @unchecked Sendable {
    static let requests = OSAllocatedUnfairLock(initialState: [URLRequest]())
    static let failLoopback = OSAllocatedUnfairLock(initialState: false)
    static let failure = OSAllocatedUnfairLock<URLError.Code?>(initialState: nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = data
        }
        let frozen = captured
        if let code = Self.failure.withLock({ $0 }) { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
        Self.requests.withLock { $0.append(frozen) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.failLoopback.withLock({ $0 }) && request.url?.host == "127.0.0.1" ? 503 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"text\":\"captured text\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor RoutingGate {
    var started = false
    var startWaiter: CheckedContinuation<Void, Never>?
    var producer: CheckedContinuation<Void, Never>?
    func begin() async {
        started = true; startWaiter?.resume(); startWaiter = nil
        await withCheckedContinuation { producer = $0 }
    }
    func waitStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release() { producer?.resume(); producer = nil }
}

extension ASRBackendRoutingSelfTests {
    static func descriptor(_ id: String, _ location: ASRBackendLocation) -> ASRBackendDescriptor {
        .init(id: .init(rawValue: id), revision: UUID(), displayName: id, modelID: "model", location: location,
              requiresInternet: location == .cloud, capabilities: .init(supportsLanguageHint: true,
              supportsContextHint: true, requiresNetwork: location != .native,
              location: location == .cloud ? .cloud : location == .native ? .onDevice : .localService), maxUploadBytes: nil)
    }
    static func testRoutingMatrix(_ r: SelfTest.Reporter) {
        let native = descriptor("native:preset:fixture", .native)
        let service = descriptor("service:fixture", .loopbackService)
        let cloud = descriptor("cloud:fixture", .cloud)
        let descriptors = [native, service, cloud]
        let available = Set(descriptors.map(\.id))
        let cases: [(ASRBackendSelection, ASRRoutingPolicy, Bool, Set<ASRBackendID>, [String])] = [
            (.init(primary: service.id, fallback: cloud.id), .auto, true, [], ["service:fixture"]),
            (.init(primary: service.id, fallback: cloud.id, allowsCloudFallback: true), .auto, true, [], ["service:fixture", "cloud:fixture"]),
            (.init(primary: cloud.id, fallback: service.id), .auto, false, [], ["service:fixture"]),
            (.init(primary: service.id, fallback: native.id), .localOnly, false, [], ["service:fixture", "native:preset:fixture"]),
            (.init(primary: cloud.id, fallback: service.id), .localOnly, true, [], ["service:fixture"]),
            (.init(primary: cloud.id, fallback: service.id), .cloudOnly, true, [], ["cloud:fixture"]),
            (.init(primary: service.id, fallback: native.id), .cloudOnly, true, [], []),
            (.init(primary: cloud.id, fallback: service.id), .auto, true, [cloud.id], ["service:fixture", "cloud:fixture"]),
            (.init(primary: cloud.id, fallback: cloud.id), .auto, true, [], ["cloud:fixture"]),
            (.init(primary: .init(rawValue: "unknown")), .auto, true, [], [])
        ]
        for (selection, policy, internet, degraded, expected) in cases {
            r.eq(ASRBackendRouting.order(selection: selection, policy: policy, descriptors: descriptors,
                availableIDs: available, internetAvailable: internet, degradedIDs: degraded).map(\.rawValue), expected,
                "A4 policy/network/consent matrix")
        }
        let budget = CompletionBudget(seconds: 20, nowNanoseconds: 100)
        r.eq(budget.remainingSeconds(at: 10_000_000_100), 10, "A4 shared stop budget elapsed")
        r.eq(completionStageTimeout(remaining: 19, cloud: true, policy: .auto, localAvailable: true), 5, "A4 cloud attempt capped with noncloud fallback")
        r.eq(completionStageTimeout(remaining: 2, cloud: true, policy: .auto, localAvailable: true), 2, "A4 attempt cannot extend remaining budget")
    }

    @MainActor static func testCaptureIdentitySurvivesEdits(_ r: SelfTest.Reporter) async {
        let settings = RoutingSettings()
        let credentials = KeychainASRCredentialStore(access: .memory())
        var profile = CloudASRProviderConfig.defaultSiliconFlow(isActive: true)
        profile.model = "captured-model"; profile.baseURL = "https://captured.invalid/v1"
        profile.credentialReferenceID = "asr.cloud." + profile.id.uuidString + "." + UUID().uuidString
        do { try credentials.write("captured-key", id: profile.credentialID) } catch { r.check(false, "fixture credential write") }
        settings.config.cloudASRConfig.providers = [profile]
        settings.config.asrRoutingPolicy = .cloudOnly
        settings.config.setASRBackendSelection(.init(primary: .init(rawValue: "cloud:" + profile.id.uuidString)))
        let sessionConfig = URLSessionConfiguration.ephemeral; sessionConfig.protocolClasses = [RoutingHTTPFixture.self]
        let session = URLSession(configuration: sessionConfig); defer { session.invalidateAndCancel() }
        let router = ASRRouter(startMonitoring: false, credentials: credentials,
            cloudProvider: CloudASRProvider(session: session, logger: { _ in }), persistNativeResolution: { _ in },
            configuration: { settings.config }, localAvailable: { settings.lease != nil }, localLease: { settings.lease })
        let captured = await router.captureStartRoute()
        settings.config.cloudASRConfig.providers[0].baseURL = "https://edited.invalid/v1"
        settings.config.cloudASRConfig.providers[0].model = "edited-model"
        do { try credentials.write("edited-key", id: profile.credentialID) } catch { r.check(false, "fixture credential edit") }
        RoutingHTTPFixture.requests.withLock { $0 = [] }
        let context = SessionContext(sessionID: 94001); context.captureRoute = captured
        let stage = ASRStage(healthRecorder: { _, _, _ in }, speechPreflight: { _, _ in .possiblySpeech }, phrases: { [] })
        _ = await stage.execute(payload: .audio(samples: [0.1, 0.2], previewText: ""), context: context)
        let requests = RoutingHTTPFixture.requests.withLock { $0 }
        r.eq(requests.map { $0.url?.host }, ["captured.invalid"], "capture retains original endpoint")
        r.eq(requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer captured-key"], "capture retains original key version")
        let body = requests.first?.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        r.check(body.contains("captured-model") && !body.contains("edited-model"), "capture retains original wire model")
        r.eq(context.rawTranscript, "captured text", "captured cloud binding executes real batch builder")
        r.eq(context.usedProviderID, "cloud:" + profile.id.uuidString, "actual profile identity reaches session")
        r.check(captured.bindings.first?.credentialGeneration != (await router.captureStartRoute()).bindings.first?.credentialGeneration,
                "new capture observes changed credential generation")

        let health = ASRBackendHealthStore()
        if let binding = captured.bindings.first {
            health.recordFailure(binding: binding); health.recordFailure(binding: binding)
            r.check(health.isDegraded(binding: binding), "captured instance degrades after failures")
            var other = binding.descriptor
            other = .init(id: .init(rawValue: "cloud:other"), revision: other.revision, displayName: other.displayName,
                modelID: other.modelID, location: other.location, requiresInternet: other.requiresInternet,
                capabilities: other.capabilities, maxUploadBytes: other.maxUploadBytes)
            r.check(!health.isDegraded(binding: .init(descriptor: other, provider: binding.provider, nativeLease: nil,
                credentialGeneration: binding.credentialGeneration)), "same vendor different profile health stays independent")
            let next = await router.captureStartRoute()
            if let fresh = next.bindings.first { r.check(!health.isDegraded(binding: fresh), "credential generation isolates old failure") }
        }

        settings.config.asrRoutingPolicy = .localOnly
        let oldLease = lease("fixture-old")
        settings.lease = oldLease
        settings.config.setASRBackendSelection(.init(primary: ASRBackendID(nativeLease: oldLease)))
        let nativeCapture = await router.captureStartRoute()
        settings.lease = lease("fixture-new")
        settings.config.setASRBackendSelection(.init(primary: ASRBackendID(nativeLease: settings.lease!)))
        let localContext = SessionContext(sessionID: 94002); localContext.captureRoute = nativeCapture
        _ = await stage.execute(payload: .audio(samples: [0.1], previewText: ""), context: localContext)
        r.eq(localContext.rawTranscript, "fixture-old", "recording retains actual native runtime after selection changes")
        r.eq(nativeCapture.bindings.first?.nativeLease?.id, oldLease.id, "captured native lease is retained")
        r.eq((await router.captureStartRoute()).bindings.first?.nativeLease?.id, settings.lease?.id, "next recording uses newly selected runtime")
    }

    static func lease(_ name: String) -> LocalASRLease {
        .init(id: UUID(), identity: .init(id: name, displayName: name, engine: "fixture", repoID: nil,
            directory: URL(fileURLWithPath: "/fixture/" + name)), provider: RoutingProvider(id: name, operation: { _ in
                .init(text: name, providerID: name, latencyMs: 10)
            }))
    }

    @MainActor static func testCancelledPrimaryNeverFallsBack(_ r: SelfTest.Reporter) async {
        let gate = RoutingGate()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let primary = RoutingProvider(id: "primary", operation: { _ in
            await gate.begin() // Deliberately ignores task cancellation until manually released.
            return .init(text: "late text", providerID: "primary", latencyMs: 1)
        })
        let fallback = RoutingProvider(id: "fallback", operation: { _ in
            calls.withLock { $0 += 1 }; return .init(text: "fallback", providerID: "fallback", latencyMs: 1)
        })
        let bindings = [ASRBackendBinding(descriptor: descriptor("service:primary", .loopbackService), provider: primary,
            nativeLease: nil, credentialGeneration: nil), ASRBackendBinding(descriptor: descriptor("cloud:fallback", .cloud),
            provider: fallback, nativeLease: nil, credentialGeneration: nil)]
        let context = SessionContext(sessionID: 94003); context.captureRoute = .init(policy: .auto, bindings: bindings)
        let stage = ASRStage(healthRecorder: { _, _, _ in }, speechPreflight: { _, _ in .possiblySpeech }, phrases: { [] })
        let task = Task { await stage.execute(payload: .audio(samples: [0.1], previewText: "preview"), context: context) }
        await gate.waitStarted(); context.cancel(); task.cancel()
        _ = await task.value
        await gate.release()
        await Task.yield()
        r.eq(calls.withLock { $0 }, 0, "cancelled primary never uploads to fallback")
        r.eq(context.rawTranscript, "", "ignored cancellation late result never delivers")
        r.check(!context.beginDeliveryAttempt(), "cancelled session cannot deliver late result")
    }
}

@MainActor private final class RoutingSettings {
    var config = Configuration()
    var lease: LocalASRLease?
}


extension ASRBackendRoutingSelfTests {
    @MainActor static func testLegacyResolutionAndCredentialFailures(_ r: SelfTest.Reporter) async {
        let suite = "flowtype-A4-migration-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = KeychainASRCredentialStore(access: .memory())
        var old = Configuration(); old.asrRoutingPolicy = .localOnly
        old.customLocalModelPath = "/fixture/legacy-path"
        do {
            defaults.set(5, forKey: "flowtype.migrationVersion")
            defaults.set(try JSONEncoder().encode(old), forKey: "flowtype.config")
            let store = ConfigurationStore(defaults: defaults, asrCredentials: credentials)
            r.check(store.current.pendingLegacyNativeResolution, "legacy unresolved native gets persisted marker")
            let restart = ConfigurationStore(defaults: defaults, asrCredentials: credentials)
            r.check(restart.current.pendingLegacyNativeResolution, "legacy marker survives restart")
            let actual = lease("actual-loaded-identity")
            restart.resolveLegacyNativeSelection(lease: actual)
            let resolved = ConfigurationStore(defaults: defaults, asrCredentials: credentials)
            r.eq(resolved.current.asrBackendSelection?.primary?.rawValue, "native:preset:actual-loaded-identity", "successful actual lease resolves and persists real identity")
            r.check(!resolved.current.pendingLegacyNativeResolution, "resolved marker clears atomically with identity")
            try resolved.setASRBackendSelection(.init())
            let cleared = ConfigurationStore(defaults: defaults, asrCredentials: credentials)
            cleared.resolveLegacyNativeSelection(lease: actual)
            r.eq(cleared.current.asrBackendSelection, .init(), "explicit clear never reactivates old path intent")
            var noRole = cleared.current
            noRole.selectNativeASRBackend(lease: actual)
            r.eq(noRole.asrBackendSelection, .init(), "load without selected native role cannot resurrect explicit clear")
            var missing = old
            missing.setASRBackendSelection(.init(primary: .init(rawValue: "native:import:unknown")))
            missing.resolveLegacyNativeSelection(lease: actual)
            r.eq(missing.asrBackendSelection?.primary?.rawValue, "native:import:unknown", "explicit unavailable native identity remains unavailable")
        } catch { r.check(false, "migration fixture: \(error)") }

        let settings = RoutingSettings()
        let profile = CloudASRProviderConfig.defaultSiliconFlow(isActive: true)
        settings.config.cloudASRConfig.providers = [profile]
        settings.config.cloudASRConfig.providerAPIKeys[profile.id.uuidString] = "legacy-backup"
        settings.config.asrRoutingPolicy = .cloudOnly
        settings.config.setASRBackendSelection(.init(primary: .init(rawValue: "cloud:" + profile.id.uuidString)))
        do { try credentials.write("", id: profile.credentialID) } catch { r.check(false, "tombstone fixture") }
        let removedRouter = ASRRouter(startMonitoring: false, credentials: credentials, persistNativeResolution: { _ in },
            configuration: { settings.config }, localAvailable: { false }, localLease: { nil })
        r.eq((await removedRouter.captureStartRoute()).bindings.count, 0, "empty credential tombstone never uses old JSON backup")
        let denied = KeychainASRCredentialStore(access: .init(read: { _ in throw ASRCredentialError.unavailable },
            update: { _, _ in false }, add: { _, _ in }, remove: { _ in }))
        let deniedRouter = ASRRouter(startMonitoring: false, credentials: denied, persistNativeResolution: { _ in },
            configuration: { settings.config }, localAvailable: { false }, localLease: { nil })
        let context = SessionContext(sessionID: 94004); context.captureRoute = await deniedRouter.captureStartRoute()
        let stage = ASRStage(healthRecorder: { _, _, _ in }, speechPreflight: { _, _ in .possiblySpeech }, phrases: { [] })
        let result = await stage.execute(payload: .audio(samples: [0.1], previewText: ""), context: context)
        if case .suspend(let recovery) = result { r.eq(recovery.failureKind, .configuration(.credentials), "locked credential remains repairable access failure") }
        else { r.check(false, "locked credential cannot become a missing selection") }
    }
}

private actor RoutingRealtimeFixture: RealtimeASRSession {
    var starts = 0
    var finishes = 0
    var cancels = 0
    func start() async throws { starts += 1 }
    func append(samples: [Float]) async throws {}
    func finish() async throws -> ASRResult {
        finishes += 1
        return .init(text: "realtime captured", providerID: ASRProviderID.cloud, latencyMs: 1)
    }
    func cancel() async { cancels += 1 }
}

extension ASRBackendRoutingSelfTests {
    @MainActor static func testServiceConsentAndRealtimeBinding(_ r: SelfTest.Reporter) async {
        let settings = RoutingSettings()
        let credentials = KeychainASRCredentialStore(access: .memory())
        let cloud = CloudASRProviderConfig.defaultSiliconFlow(isActive: true)
        let service = ASRBackendTransportSelfTests.profile()
        let serviceID = ASRBackendID(rawValue: "service:" + service.id.uuidString)
        let cloudID = ASRBackendID(rawValue: "cloud:" + cloud.id.uuidString)
        settings.config.localASRServices = [service]
        settings.config.cloudASRConfig.providers = [cloud]
        settings.config.cloudASRConfig.providerAPIKeys[cloud.id.uuidString] = "cloud-fixture"
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RoutingHTTPFixture.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let registry = try! ASRProviderRegistry(adapters: [OpenAICompatibleASRAdapter(session: session, resolver: { _ in ["127.0.0.1"] })])
        let router = ASRRouter(startMonitoring: false, credentials: credentials, registry: registry,
            cloudProvider: CloudASRProvider(session: session, logger: { _ in }), persistNativeResolution: { _ in },
            configuration: { settings.config }, localAvailable: { false }, localLease: { nil })
        RoutingHTTPFixture.failLoopback.withLock { $0 = true }
        defer { RoutingHTTPFixture.failLoopback.withLock { $0 = false } }
        for consent in [false, true] {
            settings.config.setASRBackendSelection(.init(primary: serviceID, fallback: cloudID, allowsCloudFallback: consent))
            let context = SessionContext(sessionID: consent ? 94006 : 94005)
            context.captureRoute = await router.captureStartRoute()
            RoutingHTTPFixture.requests.withLock { $0 = [] }
            let stage = ASRStage(healthRecorder: { _, _, _ in }, speechPreflight: { _, _ in .possiblySpeech }, phrases: { [] })
            _ = await stage.execute(payload: .audio(samples: [0.2, -0.2], previewText: ""), context: context)
            let requests = RoutingHTTPFixture.requests.withLock { $0 }
            let cloudRequests = requests.filter { $0.url?.host != "127.0.0.1" }
            r.eq(cloudRequests.count, consent ? 1 : 0, "local service failure uploads only with explicit cloud fallback consent")
            r.eq(requests.count, consent ? 2 : 1, "service attempt precedes permitted cloud fallback")
            if consent {
                r.eq(context.rawTranscript, "captured text", "permitted cloud fallback delivers one final result")
                r.eq(context.usedProviderID, cloudID.rawValue, "fallback reports actual cloud profile")
                r.check((cloudRequests.first?.timeoutInterval ?? 99) <= 5, "cloud fallback inherits five second cap with noncloud candidate")
            }
        }

        let ds = CloudASRProviderConfig.defaultParaformer(isActive: true)
        settings.config.cloudASRConfig.providers = [ds]
        settings.config.cloudASRConfig.providerAPIKeys[ds.id.uuidString] = "dashscope-fixture"
        settings.config.setASRBackendSelection(.init(primary: .init(rawValue: "cloud:" + ds.id.uuidString)))
        let route = await router.captureStartRoute()
        let realtime = RoutingRealtimeFixture()
        let factories = OSAllocatedUnfairLock(initialState: 0)
        let factory: RealtimeSessionFactory = { _ in
            factories.withLock { $0 += 1 }
            return .init(session: realtime, ingress: RealtimeAudioIngress(), capabilities: DashScopeRealtimeASR.capabilities)
        }
        let context = SessionContext(sessionID: 94007)
        context.prepareRealtime(route: route, factory: factory)
        try? await context.realtimeStartTask?.value
        RoutingHTTPFixture.requests.withLock { $0 = [] }
        let stage = ASRStage(healthRecorder: { _, _, _ in }, realtimeFactory: factory,
            speechPreflight: { _, _ in .possiblySpeech }, phrases: { [] })
        _ = await stage.execute(payload: .audio(samples: [0.2], previewText: "partial preview"), context: context)
        r.eq(factories.withLock { $0 }, 1, "captured DashScope binding starts once and reuses live handle at stop")
        r.eq(await realtime.starts, 1, "captured realtime session starts during recording")
        r.eq(await realtime.finishes, 1, "captured realtime session finalizes exactly once")
        r.eq(RoutingHTTPFixture.requests.withLock { $0.count }, 0, "DashScope binding never uses multipart transport")
        r.eq(context.realtimeResult?.providerID, "cloud:" + ds.id.uuidString, "realtime winner reports actual profile identity")
        r.eq(context.rawTranscript, "realtime captured", "realtime final wins over Apple preview")

        if let binding = route.bindings.first {
            let health = ASRBackendHealthStore()
            health.recordProbe(binding: binding, generation: health.networkGeneration, latencyMs: nil)
            r.check(health.isDegraded(binding: binding), "failed probe degrades only captured instance")
            var changed = ds; changed.revision = UUID()
            let provider = CapturedCloudASRProvider(configuration: .init(provider: changed, apiKey: "dashscope-fixture", sendContext: false), underlying: binding.provider)
            let revised = ASRBackendBinding(descriptor: .init(id: binding.descriptor.id, revision: changed.revision,
                displayName: changed.name, modelID: changed.model, location: .cloud, requiresInternet: true,
                capabilities: provider.capabilities, maxUploadBytes: nil), provider: provider, nativeLease: nil,
                credentialGeneration: binding.credentialGeneration)
            r.check(!health.isDegraded(binding: revised), "profile revision isolates prior probe failure")
            let oldGeneration = health.networkGeneration
            health.invalidateInternetSamples()
            health.recordProbe(binding: binding, generation: oldGeneration, latencyMs: nil)
            r.check(!health.isDegraded(binding: binding), "old path late probe cannot poison current network")
            health.recordFailure(binding: binding); health.recordFailure(binding: binding)
            r.check(health.reserveRecovery(binding: binding, uptime: 1), "degraded capture reserves one recovery attempt")
            r.check(!health.reserveRecovery(binding: binding, uptime: 60_000_000_000), "recovery reservation uses monotonic cooldown")
            r.check(health.reserveRecovery(binding: binding, uptime: 60_000_000_001), "recovery resumes at sixty elapsed seconds")
            health.recordSuccess(binding: binding, latencyMs: 10)
            r.check(!health.isDegraded(binding: binding), "actual successful recognition retires negative evidence")
        }
    }
}

extension ASRBackendRoutingSelfTests {
    @MainActor static func testExcludedCredentialsNeverRead(_ r: SelfTest.Reporter) async {
        for policy in [ASRRoutingPolicy.localOnly, .auto, .cloudOnly] {
            let settings = RoutingSettings()
            let cloud = CloudASRProviderConfig.defaultSiliconFlow(isActive: true)
            var service = ASRBackendTransportSelfTests.profile()
            if policy == .cloudOnly { service.authentication = .bearer(credentialID: "asr.service." + service.id.uuidString) }
            let cloudID = ASRBackendID(rawValue: "cloud:" + cloud.id.uuidString)
            let serviceID = ASRBackendID(rawValue: "service:" + service.id.uuidString)
            settings.config.asrRoutingPolicy = policy
            settings.config.cloudASRConfig.providers = [cloud]
            settings.config.localASRServices = [service]
            settings.config.setASRBackendSelection(.init(primary: policy == .cloudOnly ? cloudID : serviceID,
                fallback: policy == .cloudOnly ? serviceID : cloudID, allowsCloudFallback: policy == .localOnly))
            let reads = OSAllocatedUnfairLock(initialState: [String]())
            let cloudCredentialID = cloud.credentialID
            let cloudOnly = policy == .cloudOnly
            let credentials = KeychainASRCredentialStore(access: .init(read: { id in
                reads.withLock { $0.append(id) }
                if cloudOnly, id == cloudCredentialID { return "permitted-cloud-key" }
                throw ASRCredentialError.unavailable
            }, update: { _, _ in false }, add: { _, _ in }, remove: { _ in }))
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RoutingHTTPFixture.self]
            let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
            let registry = try! ASRProviderRegistry(adapters: [OpenAICompatibleASRAdapter(session: session, resolver: { _ in ["127.0.0.1"] })])
            let router = ASRRouter(startMonitoring: false, credentials: credentials, registry: registry,
                cloudProvider: CloudASRProvider(session: session, logger: { _ in }), persistNativeResolution: { _ in },
                configuration: { settings.config }, localAvailable: { false }, localLease: { nil })
            let context = SessionContext(sessionID: 94008); context.captureRoute = await router.captureStartRoute()
            r.eq(reads.withLock { $0 }, cloudOnly ? [cloudCredentialID] : [], "excluded backend never accesses credential store")
            r.check(context.captureRoute?.captureError == nil, "excluded credential access cannot contaminate permitted route")
            RoutingHTTPFixture.failLoopback.withLock { $0 = true }
            let stage = ASRStage(healthRecorder: { _, _, _ in }, speechPreflight: { _, _ in .possiblySpeech }, phrases: { [] })
            let result = await stage.execute(payload: .audio(samples: [0.2], previewText: ""), context: context)
            RoutingHTTPFixture.failLoopback.withLock { $0 = false }
            if !cloudOnly {
                if case .suspend(let recovery) = result { r.eq(recovery.failureKind, .transientASR, "permitted service failure retains its own cause") }
                else { r.check(false, "permitted failed service remains recoverable") }
            }
        }
    }
}

extension ASRBackendRoutingSelfTests {
    @MainActor static func testEligibleCaptureFailuresKeepAttemptedCause(_ r: SelfTest.Reporter) async {
        for timeout in [false, true] {
            let settings = RoutingSettings()
            let cloud = CloudASRProviderConfig.defaultSiliconFlow(isActive: true)
            let service = ASRBackendTransportSelfTests.profile()
            settings.config.localASRServices = [service]
            settings.config.cloudASRConfig.providers = [cloud]
            settings.config.setASRBackendSelection(.init(primary: .init(rawValue: "service:" + service.id.uuidString),
                fallback: .init(rawValue: "cloud:" + cloud.id.uuidString), allowsCloudFallback: true))
            let credentials = KeychainASRCredentialStore(access: .init(read: { _ in throw ASRCredentialError.unavailable },
                update: { _, _ in false }, add: { _, _ in }, remove: { _ in }))
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RoutingHTTPFixture.self]
            let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
            let registry = try! ASRProviderRegistry(adapters: [OpenAICompatibleASRAdapter(session: session, resolver: { _ in ["127.0.0.1"] })])
            let router = ASRRouter(startMonitoring: false, credentials: credentials, registry: registry, persistNativeResolution: { _ in },
                configuration: { settings.config }, localAvailable: { false }, localLease: { nil })
            let context = SessionContext(sessionID: 94100); context.captureRoute = await router.captureStartRoute()
            RoutingHTTPFixture.failLoopback.withLock { $0 = true }
            RoutingHTTPFixture.failure.withLock { $0 = timeout ? .timedOut : nil }
            let stage = ASRStage(healthRecorder: { _, _, _ in }, speechPreflight: { _, _ in .possiblySpeech }, phrases: { [] })
            let result = await stage.execute(payload: .audio(samples: [0.2], previewText: ""), context: context)
            RoutingHTTPFixture.failLoopback.withLock { $0 = false }; RoutingHTTPFixture.failure.withLock { $0 = nil }
            if case .suspend(let recovery) = result {
                r.eq(recovery.failureKind, .transientASR, "attempted service 503/timeout outranks locked eligible fallback")
                let presentation = RecoveryPolicy.presentation(kind: recovery.failureKind, resources: .init(stage: "ASR", hasAudio: true,
                    textKind: .none, deliveryEventStarted: false, routingPolicy: .auto, hasHistory: false))
                r.check(presentation.actions.contains(.retry(stage: "ASR")), "locked fallback cannot remove retained-audio retry")
            } else { r.check(false, "failed permitted service suspends") }
        }

        let primary = CloudASRProviderConfig.defaultSiliconFlow(isActive: true)
        let fallback = CloudASRProviderConfig.defaultSiliconFlow(isActive: false)
        for profiles in [[primary, fallback], [fallback, primary]] {
            let settings = RoutingSettings()
            settings.config.cloudASRConfig.providers = profiles
            settings.config.setASRBackendSelection(.init(primary: .init(rawValue: "cloud:" + primary.id.uuidString),
                fallback: .init(rawValue: "cloud:" + fallback.id.uuidString)))
            let primaryCredentialID = primary.credentialID
            let credentials = KeychainASRCredentialStore(access: .init(read: { id in
                throw id == primaryCredentialID ? ASRCredentialError.unavailable : ASRCredentialError.invalidData
            }, update: { _, _ in false }, add: { _, _ in }, remove: { _ in }))
            let router = ASRRouter(startMonitoring: false, credentials: credentials, persistNativeResolution: { _ in },
                configuration: { settings.config }, localAvailable: { false }, localLease: { nil })
            let route = await router.captureStartRoute()
            r.eq(route.captureFailures.map(\.backendID.rawValue), ["cloud:" + primary.id.uuidString, "cloud:" + fallback.id.uuidString],
                 "capture diagnostics retain each backend identity in selection order")
            r.eq(route.captureError?.localizedDescription, ASRCredentialError.unavailable.localizedDescription,
                 "multiple capture errors follow selection order instead of profile array order")
            let context = SessionContext(sessionID: 94101); context.captureRoute = route
            let stage = ASRStage(healthRecorder: { _, _, _ in }, speechPreflight: { _, _ in .possiblySpeech }, phrases: { [] })
            if case .suspend(let recovery) = await stage.execute(payload: .audio(samples: [0.2], previewText: ""), context: context) {
                r.eq(recovery.destination, .settings(.speech, .asrBackend(.init(rawValue: "cloud:" + primary.id.uuidString))), "capture-only failure retains primary backend destination")
            } else { r.check(false, "capture-only credential error suspends") }
        }
    }
}


extension ASRBackendRoutingSelfTests {
    // Regression: the old cloud/native readiness slots discard an offline loopback selection.
    @MainActor static func testOfflineServiceReadiness(_ r: SelfTest.Reporter) async {
        var config = Configuration()
        config.asrRoutingPolicy = .localOnly
        let service = descriptor("service:fixture", .loopbackService)
        let native = descriptor("native:preset:fixture", .native)
        let cloud = descriptor("cloud:fixture", .cloud)
        config.asrBackendSelection = .init(primary: service.id)
        func snapshot(_ backends: [ASRBackendDescriptor], _ available: Set<ASRBackendID>,
                      status: QwenModelStatus = .notLoaded, internet: Bool = false) -> ReadinessSnapshot {
            ReadinessSnapshotBuilder.make(config: config, modelStatus: status,
                accessibility: .granted, microphone: .granted, speechRecognition: .denied,
                networkReachable: internet, appleAvailable: false, computedAt: Date(timeIntervalSince1970: 1),
                backends: backends, availableIDs: available)
        }
        let ready = snapshot([service], [service.id])
        r.eq(classifyReadiness(ready), .ready, "A6 offline selected loopback is ready")
        r.check(readinessMenuTitle(ready).contains("本机服务"), "A6 offline readiness menu identifies service")
        r.eq(classifyReadiness(snapshot([service], [])), .blocked(.noEngine), "A6 configured service alone is not ready")
        config.asrBackendSelection = nil
        config.selectedLocalModelID = nil
        config.activeImportedASRModelID = nil
        r.eq(classifyReadiness(snapshot([native], [native.id])), .ready, "A6 pending legacy intent uses actual loaded availability without persistence")
        let otherNative = descriptor("native:import:other", .native)
        for descriptors in [[native, otherNative], [otherNative, native]] {
            r.eq(classifyReadiness(snapshot(descriptors, [native.id, otherNative.id])), .blocked(.noEngine),
                "A6 ambiguous injected native availability cannot choose array order")
        }

        config.setASRBackendSelection(.init())
        r.eq(classifyReadiness(snapshot([native], [native.id])), .blocked(.noEngine), "A6 explicit clear cannot resurrect loaded native")
        config.asrBackendSelection = .init(primary: native.id)
        r.eq(classifyReadiness(snapshot([], [])), .blocked(.noEngine), "A6 missing native is not ready")
        r.eq(classifyReadiness(snapshot([native], [], status: .ready)), .blocked(.noEngine), "A6 installed status without loaded lease is not ready")
        r.eq(classifyReadiness(snapshot([native], [], status: .loading)), .degraded(.enginePreparing), "A6 selected native load reports preparing")
        config.asrBackendSelection = .init(primary: cloud.id, fallback: service.id)
        config.asrRoutingPolicy = .auto
        r.eq(classifyReadiness(snapshot([cloud, service], [service.id])), .ready, "A6 offline cloud falls back to validated service")
        config.asrBackendSelection = .init(primary: cloud.id)
        r.eq(classifyReadiness(snapshot([cloud], [], internet: true)), .blocked(.noEngine), "A6 locked cloud is not ready")
        config.asrBackendSelection = .init(primary: .init(rawValue: "future:unknown"))
        let unknown = snapshot([service], [service.id])
        r.eq(classifyReadiness(unknown), .blocked(.noEngine), "A6 unknown selection cannot adopt another backend")
        let presentation = ReadinessPresentation.make(snapshot: unknown, level: classifyReadiness(unknown))
        r.check(presentation.destinations.contains(.settings(.speech, .asrBackend(.init(rawValue: "future:unknown")))),
                "A6 unknown readiness recovery preserves stable target")

        let credentials = KeychainASRCredentialStore(access: .memory())
        let profile = LocalASRServiceProfile(id: UUID(), revision: UUID(), name: "Evidence", baseURL: "http://127.0.0.1:8123/v1",
            protocolKind: .openAICompatible, modelID: "actual", authentication: .none, fieldCapabilities: .init())
        config.localASRServices = [profile]
        config.asrBackendSelection = .init(primary: .init(rawValue: "service:" + profile.id.uuidString))
        let settings = RoutingSettings(); settings.config = config
        let router = ASRRouter(startMonitoring: false, internetAvailable: { false }, credentials: credentials,
            configuration: { settings.config }, localAvailable: { false }, localLease: { nil })
        r.eq(router.readinessBackends().availableIDs, [], "A6 runtime construction is not service validation")
        let evidence = ASRServiceValidationRecord(backendID: config.asrBackendSelection!.primary!, revision: profile.revision,
            credentialGeneration: credentials.generation(id: "asr.service." + profile.id.uuidString), validatedAt: Date(timeIntervalSince1970: 1))
        r.eq(router.readinessBackends(currentValidatedServices: [evidence]).availableIDs, [evidence.backendID], "A6 runtime current validation admits offline service")
        settings.config.localASRServices[0].revision = UUID()
        r.eq(router.readinessBackends(currentValidatedServices: [evidence]).availableIDs, [], "A6 revision edit invalidates service readiness")
        settings.config.localASRServices[0] = profile
        let keyID = "asr.service." + profile.id.uuidString
        settings.config.localASRServices[0].authentication = .bearer(credentialID: keyID)
        try? credentials.write("fixture-key", id: keyID)
        let generation = credentials.generation(id: keyID)
        let keyed = ASRServiceValidationRecord(backendID: evidence.backendID, revision: profile.revision,
            credentialGeneration: generation, validatedAt: evidence.validatedAt)
        r.eq(router.readinessBackends(currentValidatedServices: [keyed]).availableIDs, [evidence.backendID], "A6 matching credential evidence admits service")
        try? credentials.write("fixture-replacement", id: keyID)
        r.eq(router.readinessBackends(currentValidatedServices: [keyed]).availableIDs, [], "A6 credential generation edit invalidates service readiness")
        var lockedAccess = ASRCredentialAccess.memory()
        lockedAccess.read = { _ in throw ASRCredentialError.unavailable }
        let locked = ASRRouter(startMonitoring: false, internetAvailable: { false },
            credentials: KeychainASRCredentialStore(access: lockedAccess), configuration: { settings.config },
            localAvailable: { false }, localLease: { nil })
        r.eq(locked.readinessBackends(currentValidatedServices: [keyed]).availableIDs, [], "A6 locked credential cannot appear ready")

    }

    // Regressions: new identity survives JSON/SQL and configuration failures retain the actual backend.
    @MainActor static func testActualBackendHistoryAndRecovery(_ r: SelfTest.Reporter) async {
        do {
            let session = DictationSession(rawTranscript: "fixture", finalText: "fixture", polishMode: .raw, durationMs: 1)
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as! [String: Any]
            json["asrBackendID"] = "cloud:actual-fallback"
            json["asrModelID"] = "actual-model"
            json["asrLocation"] = "cloud"
            let decoded = try JSONDecoder().decode(DictationSession.self, from: JSONSerialization.data(withJSONObject: json))
            let legacy = try JSONDecoder().decode(DictationSession.self, from: JSONEncoder().encode(session))
            r.eq(legacy.asrBackendID, nil, "A6 old JSON defaults backend to nil")
            r.eq(legacy.asrModelID, nil, "A6 old JSON defaults model to nil")
            r.eq(legacy.asrLocation, nil, "A6 old JSON defaults location to nil")
            let queue = try DatabaseQueue()
            try AppDatabase.migrator.migrate(queue, upTo: "v5_delivery")
            try await queue.write { db in
                try db.execute(sql: "INSERT INTO session (id,startedAt,charCount,rawTranscript,finalText,sttBackend) VALUES ('legacy-row',123,7,'old raw','old final','custom-old-brand')")
            }
            _ = try AppDatabase(queue, isOnDisk: false)
            let migrated = try await queue.read { try SessionRecord.fetchOne($0, key: "legacy-row")! }.toDictationSession()
            r.eq(migrated.rawTranscript, "old raw", "A6 additive migration retains old transcript")
            r.eq(migrated.sttBackend, "custom-old-brand", "A6 additive migration retains old unknown brand")
            r.eq(migrated.asrBackendID, nil, "A6 migrated row defaults backend to nil")
            let oldRecord = SessionRecord(from: session)
            let oldRecordJSON = try JSONEncoder().encode(oldRecord)
            r.eq(try JSONDecoder().decode(SessionRecord.self, from: oldRecordJSON).asrBackendID, nil,
                "A6 old record decode defaults backend to nil")
            let db = try AppDatabase.inMemory()
            try await db.dbQueue.write { db in
                var record = SessionRecord(from: decoded)
                try record.insert(db)
            }
            let stored = try await db.dbQueue.read { try SessionRecord.fetchOne($0, key: session.id)! }.toDictationSession()
            let roundTrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as! [String: Any]
            r.eq(roundTrip["asrBackendID"] as? String, "cloud:actual-fallback", "A6 actual backend survives JSON and SQL")
            r.eq(roundTrip["asrModelID"] as? String, "actual-model", "A6 actual model survives JSON and SQL")
            r.eq(roundTrip["asrLocation"] as? String, "cloud", "A6 actual location survives JSON and SQL")
            r.check(SessionMetrics.report([stored]).contains("cloud: 1"), "A6 metrics count actual cloud location")
        } catch { r.check(false, "A6 identity persistence fixture: \(error)") }
        let failed = descriptor("service:actual", .loopbackService)
        let context = SessionContext(sessionID: 601)
        context.captureRoute = .init(policy: .localOnly, bindings: [.init(descriptor: failed,
            provider: RoutingProvider(id: "wire", operation: { _ in throw CloudASRError.noModel }),
            nativeLease: nil, credentialGeneration: nil)])
        let stage = ASRStage(healthRecorder: { _, _, _ in }, speechPreflight: { _, _ in .possiblySpeech }, phrases: { [] })
        let result = await stage.execute(payload: .audio(samples: [0.1], previewText: ""), context: context)
        if case .suspend(let recovery) = result {
            r.eq(recovery.destination, .settings(.speech, .asrBackend(failed.id)), "A6 service failure targets actual backend")
        } else { r.check(false, "A6 service configuration failure suspends") }
        let fallback = ASRBackendDescriptor(id: .init(rawValue: "cloud:actual-fallback"), revision: UUID(), displayName: "Actual fallback",
            modelID: "actual-model", location: .cloud, requiresInternet: true, capabilities: failed.capabilities, maxUploadBytes: nil)
        context.captureRoute = .init(policy: .auto, bindings: [context.captureRoute!.bindings[0], .init(descriptor: fallback,
            provider: RoutingProvider(id: "untrusted-wire-id"), nativeLease: nil, credentialGeneration: nil)])
        let success = await stage.execute(payload: .audio(samples: [0.1], previewText: ""), context: context)
        if case .continue(.transcript(let text)) = success { context.finalText = text }
        else { r.check(false, "A6 actual fallback succeeds") }
        // Later edits to route metadata cannot change the already completed winner.
        context.captureRoute = .init(policy: .auto, bindings: [])
        let history = SessionController.historySession(context: context, durationMs: 1)
        r.eq(history.asrBackendID, "cloud:actual-fallback", "A6 fallback history uses winning backend")
        r.eq(history.asrModelID, "actual-model", "A6 fallback history uses captured model")
        r.eq(history.asrLocation, "cloud", "A6 fallback history uses actual location")
        r.eq(history.sttBackend, "Actual fallback", "A6 fallback history uses actual display name")
        r.eq(history.usedFallback, true, "A6 actual fallback is recorded")
        r.check(SessionMetrics.report([history]).contains("cloud: 1"), "A6 fallback metrics use actual cloud")
        let report = SessionMetrics.report([history])
        r.check(report.contains("cloud:actual-fallback") && report.contains("actual-model") && report.contains("location=cloud"),
                "A6 metrics expose actual captured backend model and location")
        let suite = "flowtype.a6.preflight." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConfigurationStore(defaults: defaults, keychain: .init(save: { _, _ in true }, load: { _ in nil }, delete: { _ in }),
            asrCredentials: KeychainASRCredentialStore(access: .memory()))
        var config = store.current
        let selected = ASRBackendID(rawValue: "future:selected-before-edit")
        config.setASRBackendSelection(.init(primary: selected))
        store.save(config)
        var destinations: [ClientDestination] = []
        let controller = SessionController(pipeline: [], observers: [],
            effects: .init(prepare: {}, showWindow: {}, hideWindow: {}, saveHistory: { _ in }),
            recoveryEffects: .init(openAccessibilitySettings: {}, openMicrophoneSettings: {}, openSpeechRecognitionSettings: {},
                openASRSettings: {}, openHistory: {}, copyText: { _ in }, openDestination: { destinations.append($0) }),
            configurationStore: store, refreshReadiness: { .blocked(.noEngine) }, readinessLevel: { .blocked(.noEngine) },
            resources: SessionResourceCoordinator())
        controller.startRecording()
        if let card = controller.recoveryCard {
            config.setASRBackendSelection(.init(primary: .init(rawValue: "future:later-edit")))
            store.save(config)
            controller.performRecoveryAction(.openASRSettings, cardID: card.id)
            r.eq(destinations, [.settings(.speech, .asrBackend(selected))], "A6 preflight recovery retains blocked selection despite edits")
        } else { r.check(false, "A6 preflight recovery card exists") }
        controller.cancel()

        let previewContext = SessionContext(sessionID: 602)
        previewContext.captureRoute = .init(policy: .auto, bindings: [])
        _ = await stage.execute(payload: .audio(samples: [0.1], previewText: "Apple preview"), context: previewContext)
        let previewHistory = SessionController.historySession(context: previewContext, durationMs: 1)
        r.eq(previewHistory.asrBackendID, nil, "A6 preview does not invent selectable backend")
        r.eq(previewHistory.sttBackend, "apple", "A6 preview retains explicit Apple label")
        r.eq(SessionController.backendLabel(forProviderID: ASRProviderID.local), "local", "A6 legacy local without brand does not force Qwen")
    }
}


extension ASRBackendRoutingSelfTests {
    @MainActor static func testServiceHealthRecovery(_ r: SelfTest.Reporter) async {
        let settings = RoutingSettings()
        let service = ASRBackendTransportSelfTests.profile()
        let cloud = CloudASRProviderConfig.defaultSiliconFlow(isActive: true)
        let serviceID = ASRBackendID(rawValue: "service:" + service.id.uuidString)
        let cloudID = ASRBackendID(rawValue: "cloud:" + cloud.id.uuidString)
        settings.config.localASRServices = [service]
        settings.config.cloudASRConfig.providers = [cloud]
        settings.config.cloudASRConfig.providerAPIKeys[cloud.id.uuidString] = "fixture"
        settings.config.setASRBackendSelection(.init(primary: serviceID, fallback: cloudID, allowsCloudFallback: true))
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1))
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [RoutingHTTPFixture.self]
        let session = URLSession(configuration: c); defer { session.invalidateAndCancel() }
        let registry = try! ASRProviderRegistry(adapters: [OpenAICompatibleASRAdapter(session: session, resolver: { _ in ["127.0.0.1"] })])
        let router = ASRRouter(startMonitoring: false, credentials: KeychainASRCredentialStore(access: .memory()), registry: registry,
            cloudProvider: CloudASRProvider(session: session, logger: { _ in }), persistNativeResolution: { _ in },
            configuration: { settings.config }, localAvailable: { false }, localLease: { nil }, uptimeNanoseconds: { clock.withLock { $0 } })
        let stage = ASRStage(healthRecorder: { id, latency, route in
            if let latency { router.recordSuccess(providerID: id, latencyMs: latency, route: route) }
            else { router.recordFailure(providerID: id, route: route) }
        }, speechPreflight: { _, _ in .possiblySpeech }, phrases: { [] })
        RoutingHTTPFixture.failLoopback.withLock { $0 = true }
        defer { RoutingHTTPFixture.failLoopback.withLock { $0 = false } }
        for index in 0..<3 {
            let context = SessionContext(sessionID: UInt64(97000 + index))
            context.captureRoute = await router.captureStartRoute()
            if index == 2 { r.eq(context.captureRoute?.candidateIDs.first, serviceID.rawValue, "I1 degraded service gets bounded capture recovery") }
            _ = await stage.execute(payload: .audio(samples: [0.2], previewText: ""), context: context)
            r.eq(context.usedProviderID, cloudID.rawValue, "I1 failed service still falls back")
        }
        r.eq(await router.captureStartRoute().candidateIDs.first, cloudID.rawValue, "I1 cooldown keeps healthy fallback first")
        RoutingHTTPFixture.failLoopback.withLock { $0 = false }
        clock.withLock { $0 = 60_000_000_001 }
        let context = SessionContext(sessionID: 97004)
        context.captureRoute = await router.captureStartRoute()
        RoutingHTTPFixture.requests.withLock { $0 = [] }
        r.eq(context.captureRoute?.candidateIDs, [serviceID.rawValue, cloudID.rawValue], "I1 repaired service reenters existing candidate order")
        _ = await stage.execute(payload: .audio(samples: [0.2], previewText: ""), context: context)
        r.eq(context.usedProviderID, serviceID.rawValue, "I1 real capture success restores service")
        r.check((RoutingHTTPFixture.requests.withLock { $0.first?.timeoutInterval } ?? 99) <= 5, "I1 recovery preserves time for healthy fallback")
        r.eq(await router.captureStartRoute().candidateIDs.first, serviceID.rawValue, "I1 successful recovery restores normal priority")
    }
}


extension ASRBackendRoutingSelfTests {
    @MainActor static func testNativeHealthRecoveryAndBudget(_ r: SelfTest.Reporter) async {
        let settings = RoutingSettings(), failing = OSAllocatedUnfairLock(initialState: true)
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1))
        let cloud = CloudASRProviderConfig.defaultSiliconFlow(isActive: true)
        let model = NativeActivationFixtures.model(RuntimeEnvironment.current.paths.temporaryDirectory.appendingPathComponent("native-recovery"))
        let usage = NativeModelUsageRegistry()
        settings.lease = LocalASRLease(id: UUID(), identity: .init(id: model.id.uuidString, displayName: model.name, engine: model.engine.rawValue,
            repoID: nil, directory: model.directory), provider: RoutingProvider(id: "native", operation: { _ in
                if failing.withLock({ $0 }) { throw NativeASRActivationError.emptyResult }
                return .init(text: "repaired native", providerID: "native", latencyMs: 1)
            })).retainingUsage(try! usage.acquire(modelID: model.id))
        settings.config.importedASRModels = [model]
        settings.config.cloudASRConfig.providers = [cloud]
        settings.config.cloudASRConfig.providerAPIKeys[cloud.id.uuidString] = "fixture"
        let nativeID = ASRBackendID(nativeLease: settings.lease!), cloudID = ASRBackendID(rawValue: "cloud:" + cloud.id.uuidString)
        settings.config.setASRBackendSelection(.init(primary: nativeID, fallback: cloudID, allowsCloudFallback: true))
        let router = ASRRouter(startMonitoring: false, credentials: KeychainASRCredentialStore(access: .memory()),
            cloudProvider: RoutingProvider(id: "cloud"), persistNativeResolution: { _ in }, configuration: { settings.config },
            localAvailable: { true }, localLease: { settings.lease }, uptimeNanoseconds: { clock.withLock { $0 } })
        let stage = ASRStage(healthRecorder: { id, latency, route in
            if let latency { router.recordSuccess(providerID: id, latencyMs: latency, route: route) }
            else { router.recordFailure(providerID: id, route: route) }
        }, speechPreflight: { _, _ in .possiblySpeech }, phrases: { [] })
        for i in 0..<3 {
            let context = SessionContext(sessionID: UInt64(97100 + i)); context.captureRoute = await router.captureStartRoute()
            _ = await stage.execute(payload: .audio(samples: [0.2], previewText: ""), context: context)
            r.eq(context.usedProviderID, cloudID.rawValue, "I1 degraded native still uses permitted selected fallback")
        }
        r.eq(await router.captureStartRoute().candidateIDs.first, cloudID.rawValue, "I1 native recovery respects same cooldown")
        clock.withLock { $0 = 60_000_000_001 }; failing.withLock { $0 = false }
        let context = SessionContext(sessionID: 97104); context.captureRoute = await router.captureStartRoute()
        r.check(context.captureRoute?.isHealthRecovery == true, "I1 native recovery captures explicit bounded attempt")
        _ = await stage.execute(payload: .audio(samples: [0.2], previewText: ""), context: context)
        r.eq(context.usedProviderID, nativeID.rawValue, "I1 native real capture restores original primary")
        r.eq(await router.captureStartRoute().candidateIDs.first, nativeID.rawValue, "I1 recovered native remains first without new lease")

        let gate = RoutingGate(), timeouts = OSAllocatedUnfairLock(initialState: [Double]())
        let slow = RoutingProvider(id: "slow", operation: { request in
            timeouts.withLock { $0.append(request.timeout) }; await gate.begin()
            return .init(text: "too late", providerID: "slow", latencyMs: 1)
        })
        var route = ASRRouteSnapshot(policy: .auto, bindings: [
            .init(descriptor: descriptor("service:recovery", .loopbackService), provider: slow, nativeLease: nil, credentialGeneration: nil),
            .init(descriptor: descriptor("native:healthy", .native), provider: RoutingProvider(id: "healthy"), nativeLease: nil, credentialGeneration: nil)])
        route.isHealthRecovery = true
        let bounded = SessionContext(sessionID: 97105); bounded.captureRoute = route; bounded.completionBudget = .init(seconds: 0.5)
        let boundedStage = ASRStage(healthRecorder: { _, _, _ in }, speechPreflight: { _, _ in .possiblySpeech }, phrases: { [] })
        _ = await boundedStage.execute(payload: .audio(samples: [0.2], previewText: ""), context: bounded)
        r.eq(bounded.usedProviderID, "native:healthy", "I1 timeout of uncooperative recovery leaves shared budget for healthy fallback")
        r.check((timeouts.withLock { $0.first } ?? 99) <= 0.25, "I1 recovery receives at most half remaining shared budget")
        await gate.release()
    }
}
