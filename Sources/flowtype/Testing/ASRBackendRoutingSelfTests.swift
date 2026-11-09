import Foundation
import os

enum ASRBackendRoutingSelfTests {
    @MainActor static func run(_ r: SelfTest.Reporter) async {
        await testPolicyAndNetworkMatrix(r)
        testRoutingMatrix(r)
        await testCaptureIdentitySurvivesEdits(r)
        await testCancelledPrimaryNeverFallsBack(r)
        await testLegacyResolutionAndCredentialFailures(r)
        await testServiceConsentAndRealtimeBinding(r)
        await testExcludedCredentialsNeverRead(r)
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
