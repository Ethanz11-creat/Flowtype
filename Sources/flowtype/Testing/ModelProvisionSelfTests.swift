import Foundation

/// Fixtures intercept every URL; these tests never contact a model host or use live configuration.
enum ModelProvisionSelfTests {
    private final class ProtocolFixture: URLProtocol, @unchecked Sendable {
        struct Reply {
            var status = 200
            var headers: [String: String] = [:]
            var failure: URLError.Code?
            var nonHTTP = false
        }
        nonisolated(unsafe) static var reply: (URLRequest) -> Reply = { _ in Reply() }
        nonisolated(unsafe) static var requests: [URLRequest] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requests.append(request)
            let value = Self.reply(request)
            if let failure = value.failure {
                client?.urlProtocol(self, didFailWithError: URLError(failure))
                return
            }
            let response: URLResponse = value.nonHTTP
                ? URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
                : HTTPURLResponse(url: request.url!, statusCode: value.status, httpVersion: "HTTP/1.1", headerFields: value.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("secret response body".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private static let metadata = ["X-Repo-Commit": "abc123", "ETag": "\"etag\"", "Content-Length": "512"]

    static func runPreflight(_ r: SelfTest.Reporter) async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProtocolFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let preflight = ModelMetadataPreflight(session: session)
        let endpoint = URL(string: "https://fixtures.invalid")!
        let repo = "aufklarer/Qwen3-ASR-1.7B-MLX-4bit"
        func response(_ value: ProtocolFixture.Reply) {
            ProtocolFixture.requests = []
            ProtocolFixture.reply = { _ in value }
        }
        func failure(_ name: String, _ expected: ModelProvisionError, endpoint custom: URL? = nil) async {
            do {
                _ = try await preflight.check(repoID: repo, endpoint: custom ?? endpoint)
                r.check(false, "preflight: \(name) must reject metadata")
            } catch let error as ModelProvisionError {
                r.eq(error, expected, "preflight: \(name) classification")
                r.eq(error.isRetryable, expected.isRetryable, "preflight: \(name) retry policy")
                r.check(!String(describing: error).contains("secret"), "query/userinfo/body redacted")
            } catch { r.check(false, "preflight: \(name) unexpected error \(error)") }
        }
        let path = "/aufklarer/Qwen3-ASR-1.7B-MLX-4bit/resolve/main/config.json"
        func summary(_ status: Int) -> ModelEndpointSummary {
            ModelEndpointSummary(host: "fixtures.invalid", safePath: path, httpStatus: status)
        }

        response(.init(headers: metadata))
        do {
            r.eq(try await preflight.check(repoID: repo, endpoint: endpoint), summary(200), "preflight: complete 200 metadata")
        } catch { r.check(false, "preflight: valid 200 rejected") }
        let capturedRequest = ProtocolFixture.requests.first!
        r.eq(capturedRequest.httpMethod, "HEAD", "preflight only requests metadata")
        r.eq(capturedRequest.timeoutInterval, 10, "preflight timeout")
        r.eq(capturedRequest.cachePolicy, .reloadIgnoringLocalCacheData, "preflight bypasses cached metadata")
        r.eq(capturedRequest.value(forHTTPHeaderField: "Accept-Encoding"), "identity", "preflight Hub size has identity encoding")

        var cdnMetadata = metadata
        cdnMetadata["Location"] = "https://cdn.invalid/weights?token=secret"
        response(.init(status: 302, headers: cdnMetadata))
        do {
            r.eq(try await preflight.check(repoID: repo, endpoint: endpoint), summary(302), "preflight: complete 302 metadata accepted without fetching CDN")
        } catch { r.check(false, "preflight: complete 302 rejected") }
        r.eq(ProtocolFixture.requests.filter { $0.url?.host == "cdn.invalid" }.count, 0, "cross-origin location is not followed")

        ProtocolFixture.requests = []
        ProtocolFixture.reply = { request in
            request.url?.path == path
                ? .init(status: 302, headers: ["Location": "/relative/config.json"])
                : .init(headers: metadata)
        }
        do { _ = try await preflight.check(repoID: repo, endpoint: endpoint) }
        catch { r.check(false, "preflight: same-origin relative redirect rejected") }
        r.eq(ProtocolFixture.requests.compactMap(\.httpMethod), ["HEAD", "HEAD"], "redirect preserves HEAD")

        ProtocolFixture.requests = []
        ProtocolFixture.reply = { request in
            let hop = Int(request.url?.lastPathComponent ?? "") ?? 0
            return .init(status: 302, headers: ["Location": "/hop/\(hop + 1)"])
        }
        await failure("over five redirects", .metadataInvalid(summary: .init(host: "fixtures.invalid", safePath: "/hop/5", httpStatus: 302)))
        r.eq(ProtocolFixture.requests.count, 6, "preflight stops after five redirect hops")

        for status in [308, 401, 403, 404, 429, 500, 503] {
            response(.init(status: status, headers: metadata))
            let expected: ModelProvisionError = status == 429 || status >= 500
                ? .network(summary: summary(status)) : .metadataInvalid(summary: summary(status))
            await failure("HTTP \(status)", expected)
            r.eq(expected.isRetryable, status == 429 || status >= 500, "preflight: HTTP \(status) has explicit retry policy")
        }
        for key in ["X-Repo-Commit", "ETag", "Content-Length"] {
            var incomplete = metadata
            incomplete.removeValue(forKey: key)
            response(.init(headers: incomplete))
            await failure("missing \(key)", .metadataInvalid(summary: summary(200)))
        }
        for size in ["0", "-1", "not-a-size"] {
            var invalid = metadata
            invalid["Content-Length"] = size
            response(.init(headers: invalid))
            await failure("invalid size \(size)", .metadataInvalid(summary: summary(200)))
        }
        for location in ["file:///secret", "https://secret@cdn.invalid/file", "http://cdn.invalid/file", "https://cdn.invalid/file#secret"] {
            var invalid = metadata
            invalid["Location"] = location
            response(.init(status: 302, headers: invalid))
            await failure("invalid location", .metadataInvalid(summary: summary(302)))
        }
        response(.init(status: 302, headers: ["Location": "https://cdn.invalid/file?secret"]))
        await failure("incomplete cross-origin 302", .metadataInvalid(summary: summary(302)))
        r.eq(ProtocolFixture.requests.count, 1, "preflight rejects incomplete CDN metadata before further requests")
        response(.init(nonHTTP: true))
        await failure("non HTTP response", .metadataInvalid(summary: .init(host: "fixtures.invalid", safePath: path, httpStatus: nil)))
        response(.init(failure: .timedOut))
        await failure("timeout", .network(summary: .init(host: "fixtures.invalid", safePath: path, httpStatus: nil)))
        r.check(ModelProvisionError.network().isRetryable, "preflight: network errors are retryable")
        r.check(!ModelProvisionError.metadataInvalid().isRetryable, "preflight: invalid metadata is deterministic")
        response(.init(failure: .cancelled))
        do {
            _ = try await preflight.check(repoID: repo, endpoint: endpoint)
            r.check(false, "preflight cancellation throws")
        } catch is CancellationError { r.check(true, "preflight cancellation remains cancellation") }
        catch { r.check(false, "preflight cancellation was reclassified") }

        for raw in ["http://example.com", "https://secret@example.com?secret", "https://example.com#secret", "file:///tmp/secret", " "] {
            r.check((try? DownloadSource.custom(raw).validatedEndpoint(isChina: false)) == nil, "invalid custom endpoint rejected")
        }
        for raw in ["http://localhost:8123", "http://127.0.0.1:8123", "http://[::1]:8123", "https://example.com/hub"] {
            r.eq(try? DownloadSource.custom(raw).validatedEndpoint(isChina: false).absoluteString, raw, "safe custom endpoint accepted")
        }
        r.eq(DownloadSource.custom("https://models.example:8443/hub").displayName, "自定义 (models.example:8443)", "custom display identifies configured endpoint")
        response(.init(headers: metadata))
        let unsafe = URL(string: "https://secret@fixtures.invalid?secret")!
        await failure("unsafe endpoint", .metadataInvalid(summary: .init(host: "fixtures.invalid", safePath: "/", httpStatus: nil)), endpoint: unsafe)
        r.eq(ProtocolFixture.requests.count, 0, "invalid endpoint sends no request")

        testIdentity(r)
    }

    private static func testIdentity(_ r: SelfTest.Reporter) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("flowtype-preflight-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let legacy = root.appendingPathComponent("qwen3-speech/aufklarer_Qwen3-ASR-0.6B-MLX-4bit")
        do {
            try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: legacy.appendingPathComponent("config.json"))
            try Data("{}".utf8).write(to: legacy.appendingPathComponent("tokenizer.json"))
            let weights = legacy.appendingPathComponent("model.safetensors")
            fm.createFile(atPath: weights.path, contents: nil)
            let handle = try FileHandle(forWritingTo: weights)
            try handle.truncate(atOffset: 2_000_000_000) // sparse file, deliberately large enough for either preset
            try handle.close()
            var config = Configuration()
            config.selectedLocalModelID = "qwen3-1.7b-4bit"
            let resolve: (Configuration) -> ResolvedModel? = { config in
                ModelLocator.resolveActiveModel(config: config, knownCacheDirectories: [legacy], presetDirectory: { root.appendingPathComponent($0.id) })
            }
            r.eq(resolve(config), nil, "legacy identity stays explicit")
            config.selectedLocalModelID = "qwen3-0.6b-4bit"
            r.eq(resolve(config)?.modelId, "aufklarer/Qwen3-ASR-0.6B-MLX-4bit", "legacy 0.6B retains actual identity despite size")
            config.selectedLocalModelID = "qwen3-1.7b-4bit"
            config.localModelPath = legacy.path
            r.eq(resolve(config), nil, "configured legacy path cannot masquerade as selected preset")
            let unknown = root.appendingPathComponent("unknown")
            try fm.moveItem(at: legacy, to: unknown)
            config.localModelPath = unknown.path
            r.eq(resolve(config), nil, "unknown model is not identified by file size")
            try Data("{\"_name_or_path\":\"aufklarer/Qwen3-ASR-1.7B-MLX-4bit\"}".utf8).write(to: unknown.appendingPathComponent("config.json"))
            r.eq(resolve(config)?.modelId, "aufklarer/Qwen3-ASR-1.7B-MLX-4bit", "verifiable model metadata identifies configured preset")
            let preset17 = root.appendingPathComponent("aufklarer/Qwen3-ASR-1.7B-MLX-4bit")
            try fm.createDirectory(at: preset17.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: unknown, to: preset17)
            config.localModelPath = nil
            let resolvePreset: () -> ResolvedModel? = {
                ModelLocator.resolveActiveModel(config: config, knownCacheDirectories: [], presetDirectory: { _ in preset17 })
            }
            r.eq(resolvePreset()?.modelId, "aufklarer/Qwen3-ASR-1.7B-MLX-4bit", "matching preset path and metadata accepted")
            try Data("{\"_name_or_path\":\"aufklarer/Qwen3-ASR-0.6B-MLX-4bit\"}".utf8).write(to: preset17.appendingPathComponent("config.json"))
            r.eq(resolvePreset(), nil, "conflicting preset directory metadata is rejected")
            try fm.removeItem(at: preset17)
            try Data("{\"_name_or_path\":\"aufklarer/Qwen3-ASR-0.6B-MLX-4bit\"}".utf8).write(to: unknown.appendingPathComponent("config.json"))
            try fm.moveItem(at: unknown, to: legacy)
            try fm.createSymbolicLink(at: preset17, withDestinationURL: legacy)
            r.eq(resolvePreset(), nil, "preset symlink cannot disguise another model identity")
        } catch { r.check(false, "preflight identity fixture failed: \(error)") }
    }
}


extension ModelProvisionSelfTests {
    // These fixtures exercise retry policy and lease ownership, replacing only model/network I/O.
    private actor ProvisionProbe {
        var attempts: [String] = []
        var loadedTargets: [ModelProvisionTarget] = []
        var preflightPresets: [String] = []
        var delays: [Int] = []
        var preflights = 0
        func record(_ target: ModelProvisionTarget) {
            loadedTargets.append(target)
            if case .preset(let preset) = target { attempts.append(preset.id) }
        }
        func preflight(_ preset: ModelPreset? = nil) {
            preflights += 1
            if let preset { preflightPresets.append(preset.id) }
        }
        func delay(_ duration: Duration) async throws {
            let seconds = Int(duration.components.seconds)
            if seconds == 5 { try await Task.sleep(for: .seconds(3600)) }
            else { delays.append(seconds) }
        }
    }

    private final class FixtureValues: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 100)
        private var endpoint: String? = "original-endpoint"
        private var writes: [String?] = []
        func now() -> Date { lock.withLock { date } }
        func advance() { lock.withLock { date = date.addingTimeInterval(31) } }
        func read() -> String? { lock.withLock { endpoint } }
        func write(_ value: String?) { lock.withLock { endpoint = value; writes.append(value) } }
        func history() -> [String?] { lock.withLock { writes } }
    }

    private actor SuspendedLoader {
        var calls = 0
        var offlineValues: [Bool] = []
        var callback: (@Sendable (Double) -> Void)?
        var continuation: CheckedContinuation<LocalASRLease, Error>?
        func load(_ offline: Bool, _ progress: @escaping @Sendable (Double) -> Void) async throws -> LocalASRLease {
            calls += 1
            offlineValues.append(offline)
            callback = progress
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func complete(_ lease: LocalASRLease) { continuation?.resume(returning: lease); continuation = nil }
        func fail(_ error: ModelProvisionError) { continuation?.resume(throwing: error); continuation = nil }
        func progress(_ value: Double) { callback?(value) }
    }

    private static func lease(_ id: String) -> LocalASRLease {
        .init(id: UUID(), identity: .init(id: id, displayName: id, engine: "qwen", repoID: id,
                                        directory: URL(fileURLWithPath: "/fixture/" + id)), provider: QwenASRProvider())
    }

    @MainActor
    private static func fixture(
        preflight: @escaping @Sendable (ModelPreset, DownloadSource) async throws -> Void = { _, _ in },
        load: @escaping @Sendable (ModelProvisionTarget, Bool, @escaping @Sendable (Double) -> Void) async throws -> LocalASRLease,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            if duration == .seconds(5) { try await Task.sleep(for: .seconds(3600)) }
        },
        values: FixtureValues = FixtureValues(),
        configuration: @escaping @MainActor () -> Configuration = { Configuration() },
        localModel: @escaping @Sendable (Configuration) -> ResolvedModel? = { _ in nil },
        disk: Int64 = .max
    ) -> QwenModelState {
        QwenModelState(preflight: preflight, load: load, sleep: sleep, now: { values.now() },
                       configuration: configuration, localModel: localModel,
                       destination: { URL(fileURLWithPath: "/fixture/" + $0.id) },
                       availableDisk: { _ in disk }, environment: .init(read: { values.read() }, write: { values.write($0) }))
    }

    @MainActor
    private static func until(_ predicate: () async -> Bool) async {
        for _ in 0..<10000 { if await predicate() { return }; await Task.yield() }
    }

    @MainActor
    static func runCoordinator(_ r: SelfTest.Reporter) async {
        let probe = ProvisionProbe()
        let state = QwenModelState(
            preflight: { _, _ in await probe.preflight() },
            load: { target, _, _ in await probe.record(target); throw ModelProvisionError.network() },
            sleep: { try await probe.delay($0) },
            configuration: { Configuration() },
            localModel: { _ in nil },
            destination: { URL(fileURLWithPath: "/fixture/" + $0.id) },
            availableDisk: { _ in Int64.max },
            environment: .init(read: { nil }, write: { _ in })
        )
        await state.perform(.init(target: .preset(.qwen317B), source: .official, origin: .automatic))
        r.eq(await probe.attempts, ["qwen3-1.7b-4bit", "qwen3-1.7b-4bit", "qwen3-1.7b-4bit", "qwen3-0.6b-4bit"], "bounded fallback")
        r.eq(await probe.delays, [10, 20], "primary network backoff")
        r.eq(state.failure, .network(), "fallback failure is terminal")
        r.eq(state.operationID, nil, "terminal operation releases ownership")
        await state.perform(.init(target: .preset(.qwen317B), source: .official, origin: .manual))
        r.eq((await probe.attempts).filter { $0 == "qwen3-0.6b-4bit" }.count, 1, "manual choice preserved; terminal record permits retry")
        r.check(!state.didAutoFallback, "manual retry resets fallback flag")

        let rejected = ProvisionProbe()
        let deterministic = fixture(preflight: { _, _ in await rejected.preflight(); throw ModelProvisionError.metadataInvalid() },
                                    load: { target, _, _ in await rejected.record(target); return lease("unexpected") })
        await deterministic.perform(.init(target: .preset(.qwen317B), source: .official, origin: .automatic))
        r.eq(await rejected.preflights, 2, "deterministic primary once, fallback once")
        r.eq(await rejected.attempts, [], "failed preflight never invokes bottom loader")
        r.check(deterministic.didAutoFallback, "automatic deterministic primary may try smaller model")

        let localProbe = ProvisionProbe()
        let old = lease("old")
        let local = ResolvedModel(directory: URL(fileURLWithPath: "/fixture/local"), modelId: "known-local")
        let offline = fixture(preflight: { _, _ in await localProbe.preflight() }, load: { _, offline, _ in
            if !offline { throw ModelProvisionError.network() }; return old
        }, localModel: { _ in local })
        await offline.perform(.init(target: .preset(.qwen317B), source: .official, origin: .automatic))
        r.eq(await localProbe.preflights, 0, "complete local model skips preflight")
        r.eq(offline.activeLease?.id, old.id, "offline model becomes active")

        let suspended = SuspendedLoader()
        let values = FixtureValues()
        let ownership = fixture(load: { target, offline, progress in
            if case .offline = target { return old }
            return try await suspended.load(offline, progress)
        }, values: values)
        await ownership.perform(.init(target: .offline(local), source: .official, origin: .offlineImport))
        let pending = Task { await ownership.perform(.init(target: .preset(.qwen317B), source: .mirror, origin: .automatic)) }
        await until { await suspended.calls == 1 }
        let operation = ownership.operationID
        await ownership.perform(.init(target: .preset(.qwen306B), source: .official, origin: .manual))
        r.eq(await suspended.calls, 1, "duplicate click cannot start concurrent bottom load")
        ownership.cancel()
        await ownership.perform(.init(target: .preset(.qwen306B), source: .official, origin: .manual))
        r.eq(ownership.operationID, operation, "cancel retains ownership until bottom load exits")
        r.eq(await suspended.calls, 1, "cancel draining blocks next operation")
        r.eq(values.read(), "https://hf-mirror.com", "endpoint remains owned while cancelling")
        await suspended.progress(0.9)
        let stale = lease("stale")
        await suspended.complete(stale)
        await pending.value
        r.eq(ownership.activeLease?.id, old.id, "cancelled stale completion cannot publish")
        r.eq(ownership.failure, nil, "user cancellation is not a stall or failure")
        r.check(!ownership.didAutoFallback, "cancel never degrades")
        r.eq(values.read(), "original-endpoint", "endpoint restored after cancellation drain")
        r.eq(ownership.operationID, nil, "drained cancellation releases ownership")
        let retry = Task { await ownership.perform(.init(target: .preset(.qwen317B), source: .official, origin: .manual)) }
        await until { await suspended.calls == 2 }
        await suspended.fail(.loadFailed())
        await retry.value
        r.eq(ownership.activeLease?.id, old.id, "failed candidate retains usable model")
        r.eq(ownership.failure, .loadFailed(), "failed replacement exposes typed error")
        let terminal = ownership.status
        await suspended.progress(0.6)
        for _ in 0..<10 { await Task.yield() }
        r.eq(ownership.status, terminal, "late progress cannot revive terminal operation")

        let stallLoader = SuspendedLoader()
        let stallValues = FixtureValues()
        let stalled = fixture(load: { _, offline, callback in try await stallLoader.load(offline, callback) },
                              sleep: { duration in
                                  if duration == .seconds(5) { try await Task.sleep(for: .milliseconds(1)) }
                              }, values: stallValues)
        let stallTask = Task { await stalled.perform(.init(target: .preset(.qwen306B), source: .official, origin: .manual)) }
        await until { await stallLoader.calls == 1 }
        stallValues.advance()
        await until { stalled.status == .stalled }
        r.eq(stalled.status, .stalled, "thirty seconds without progress triggers watchdog")
        r.check(stalled.operationID != nil, "watchdog also waits for bottom loader")
        await stallLoader.complete(stale)
        for count in 2...3 {
            await until { await stallLoader.calls == count }
            stallValues.advance()
            await until { stalled.status == .stalled }
            await stallLoader.complete(stale)
        }
        await stallTask.value
        r.eq(stalled.activeLease, nil, "stalled candidate cannot commit even if bottom returns success")
        r.eq(stalled.failure, .stalled(), "watchdog cancellation remains retryable stall, distinct from user cancellation")
        r.eq(await stallLoader.calls, 3, "watchdog retries are bounded")

        let diskProbe = ProvisionProbe()
        let disk = fixture(preflight: { _, _ in await diskProbe.preflight() }, load: { target, _, _ in
            await diskProbe.record(target); return stale
        }, disk: 1)
        await disk.perform(.init(target: .preset(.qwen317B), source: .official, origin: .manual))
        r.eq(disk.failure, .insufficientDisk(), "insufficient disk typed failure")
        r.eq(await diskProbe.preflights, 0, "insufficient disk starts no network")
        r.eq(await diskProbe.attempts, [], "insufficient disk starts no loader")

        var unresolvedConfig = Configuration()
        unresolvedConfig.customLocalModelPath = "/fixture/unknown-custom"
        unresolvedConfig.hasCompletedOnboarding = true
        let fixedConfig = unresolvedConfig
        let unresolved = fixture(load: { target, _, _ in await diskProbe.record(target); return stale }, configuration: { fixedConfig })
        await unresolved.loadModel(provider: QwenASRProvider())
        r.eq(unresolved.failure, .incompleteLocal(), "unresolved custom identity fails offline")
        r.eq(await diskProbe.attempts, [], "unresolved custom path never silently downloads")
        var unknownConfig = Configuration()
        unknownConfig.selectedLocalModelID = "unknown-manual-model"
        unknownConfig.hasCompletedOnboarding = true
        let unknownFixture = unknownConfig
        let unknown = fixture(load: { target, _, _ in await diskProbe.record(target); return stale }, configuration: { unknownFixture })
        await unknown.loadModel(provider: QwenASRProvider())
        r.eq(unknown.failure, .incompleteLocal(), "unknown manual selection never becomes recommended preset")
        r.eq(await diskProbe.attempts, [], "unknown manual selection starts no download")

        // An unknown ID must not be made valid by the locator finding some installed preset.
        let installedPrimary = ResolvedModel(directory: URL(fileURLWithPath: "/fixture/installed-1.7b"),
                                             modelId: ModelPreset.qwen317B.repoId)
        let installedProbe = ProvisionProbe()
        let unknownWithInstalled = fixture(load: { target, _, _ in
            await installedProbe.record(target); return old
        }, configuration: { unknownFixture }, localModel: { _ in installedPrimary })
        await unknownWithInstalled.loadModel(provider: QwenASRProvider())
        r.eq(unknownWithInstalled.failure, .incompleteLocal(), "unknown manual ID rejects unrelated installed preset")
        r.eq(await installedProbe.loadedTargets, [], "unknown manual ID never loads unrelated installed model")
        r.eq(unknownWithInstalled.activeLease, nil, "unknown manual ID cannot commit unrelated installed identity")

        // A verified explicit path remains authoritative even when its legacy selection ID is unknown.
        var explicitConfig = unknownFixture
        explicitConfig.customLocalModelPath = installedPrimary.directory.path
        let explicitFixture = explicitConfig
        let validExplicit = fixture(load: { target, _, _ in
            await installedProbe.record(target); return old
        }, configuration: { explicitFixture }, localModel: { _ in installedPrimary })
        await validExplicit.loadModel(provider: QwenASRProvider())
        r.eq(validExplicit.activeLease?.id, old.id, "verified explicit path survives unknown legacy selection ID")
        r.eq(validExplicit.failure, nil, "verified explicit path is not rejected as unknown preset")

        var automaticConfig = Configuration()
        automaticConfig.hasCompletedOnboarding = true
        let automaticFixture = automaticConfig
        let bootstrapProbe = ProvisionProbe()
        let fallbackLease = lease("bootstrap-0.6b")
        let bootstrap = fixture(preflight: { preset, _ in await bootstrapProbe.preflight(preset) }, load: { target, offline, _ in
            await bootstrapProbe.record(target)
            if case .offline = target { throw ModelProvisionError.loadFailed() }
            guard !offline else { throw ModelProvisionError.incompleteLocal() }
            return fallbackLease
        }, configuration: { automaticFixture }, localModel: { config in
            config.selectedLocalModelID == ModelPreset.qwen306B.id ? nil : installedPrimary
        })
        await bootstrap.loadModel(provider: QwenASRProvider())
        r.eq(await bootstrapProbe.loadedTargets, [.offline(installedPrimary), .preset(.qwen306B)],
             "automatic local primary load failure falls back once to 0.6B")
        r.eq(await bootstrapProbe.preflightPresets, ["qwen3-0.6b-4bit"],
             "automatic local primary bypasses preflight; only remote fallback preflights")
        r.eq(bootstrap.activeLease?.id, fallbackLease.id, "bootstrap commits successful fallback lease")
        r.check(bootstrap.didAutoFallback, "bootstrap retains automatic fallback eligibility")

        let preOnboardingProbe = ProvisionProbe()
        let preOnboarding = fixture(preflight: { preset, _ in await preOnboardingProbe.preflight(preset) }, load: { target, _, _ in
            await preOnboardingProbe.record(target); throw ModelProvisionError.loadFailed()
        }, configuration: { Configuration() }, localModel: { _ in installedPrimary })
        await preOnboarding.loadModel(provider: QwenASRProvider())
        r.eq(await preOnboardingProbe.loadedTargets, [.offline(installedPrimary)], "pre-onboarding local bootstrap stays offline-only")
        r.eq(await preOnboardingProbe.preflights, 0, "pre-onboarding local failure cannot download fallback")
        r.check(!preOnboarding.didAutoFallback, "pre-onboarding bootstrap preserves automatic-download gate")


        let explicitFailureProbe = ProvisionProbe()
        let explicitFailure = fixture(preflight: { preset, _ in await explicitFailureProbe.preflight(preset) }, load: { target, _, _ in
            await explicitFailureProbe.record(target); throw ModelProvisionError.loadFailed()
        }, configuration: { explicitFixture }, localModel: { _ in installedPrimary })
        await explicitFailure.loadModel(provider: QwenASRProvider())
        r.eq(await explicitFailureProbe.loadedTargets, [.offline(installedPrimary)], "explicit path bootstrap failure remains terminal")
        r.eq(await explicitFailureProbe.preflights, 0, "explicit path failure never starts preflight")
        r.check(!explicitFailure.didAutoFallback, "explicit path bootstrap never auto-falls back")


        let offlineFailureProbe = ProvisionProbe()
        let offlineFailure = fixture(preflight: { _, _ in await offlineFailureProbe.preflight() }, load: { target, _, _ in
            await offlineFailureProbe.record(target); throw ModelProvisionError.loadFailed()
        })
        await offlineFailure.perform(.init(target: .offline(local), source: .official, origin: .offlineImport))
        r.eq(offlineFailure.failure, .loadFailed(), "explicit offline failure ends directly")
        r.check(!offlineFailure.didAutoFallback, "explicit offline failure never falls back")
        r.eq(await offlineFailureProbe.preflights, 0, "explicit offline failure makes no network request")

        let downloaderLoader = SuspendedLoader()
        let downloaderState = fixture(load: { target, offline, progress in
            if case .offline = target { return old }
            return try await downloaderLoader.load(offline, progress)
        })
        await downloaderState.perform(.init(target: .offline(local), source: .official, origin: .offlineImport))
        let downloader = ModelDownloader(coordinator: downloaderState, configuration: { Configuration() })
        var completedDownloads = 0
        let subscription = downloader.$currentDownload.sink { value in
            if value?.status == .completed { completedDownloads += 1 }
        }
        downloader.startDownload(preset: .qwen317B)
        await until { await downloaderLoader.calls == 1 }
        downloader.cancelDownload()
        await downloaderLoader.complete(stale)
        await until { downloaderState.operationID == nil }
        for _ in 0..<10 { await Task.yield() }
        r.eq(completedDownloads, 0, "cancelled replacement cannot announce completed download for old lease")
        r.eq(downloader.currentDownload?.status, nil, "cancelled downloader clears terminal display after draining")
        downloader.startDownload(preset: .qwen317B)
        await until { await downloaderLoader.calls == 2 }
        await downloaderLoader.fail(.loadFailed())
        await until { downloaderState.operationID == nil }
        for _ in 0..<10 { await Task.yield() }
        downloader.startDownload(preset: .qwen306B)
        await until { await downloaderLoader.calls == 3 }
        r.eq(await downloaderLoader.calls, 3, "failed downloader terminal record does not block retry")
        await downloaderLoader.complete(stale)
        await until { downloaderState.operationID == nil }
        r.eq(downloader.currentDownload?.status, .completed, "successful downloader maps coordinator commit")
        for _ in 0..<10 { await Task.yield() }
        let unrelated = Task { await downloaderState.perform(.init(target: .preset(.qwen317B), source: .official, origin: .manual)) }
        await until { await downloaderLoader.calls == 4 }
        r.eq(downloader.currentDownload?.status, .completed, "terminal downloader record does not follow unrelated provisioning")
        downloaderState.cancel()
        await downloaderLoader.complete(stale)
        await unrelated.value
        subscription.cancel()


        let serialA = SuspendedLoader()
        let serialB = SuspendedLoader()
        let sharedEnvironment = FixtureValues()
        let a = fixture(load: { _, offline, callback in try await serialA.load(offline, callback) }, values: sharedEnvironment)
        let b = fixture(load: { _, offline, callback in try await serialB.load(offline, callback) }, values: sharedEnvironment)
        let first = Task { await a.perform(.init(target: .preset(.qwen306B), source: .mirror, origin: .manual)) }
        await until { await serialA.calls == 1 }
        let second = Task { await b.perform(.init(target: .preset(.qwen306B), source: .official, origin: .manual)) }
        var compatibilityCalls = 0
        let compatibility = QwenModelState(loadDownloadedPreset: { _ in
            compatibilityCalls += 1
            throw ModelProvisionError.loadFailed()
        })
        let compatibilityTask = Task { await compatibility.handleDownloadCompleted(preset: .qwen306B) }
        for _ in 0..<100 { await Task.yield() }
        r.eq(await serialB.calls, 0, "all coordinator instances serialize bottom work")
        r.eq(compatibilityCalls, 0, "compatibility loader also respects global coordinator ownership")
        r.eq(sharedEnvironment.read(), "https://hf-mirror.com", "queued operation cannot overwrite active endpoint")
        second.cancel()
        await serialA.complete(old)
        await first.value
        await second.value
        await compatibilityTask.value
        r.eq(compatibilityCalls, 1, "compatibility loader starts after preceding operation drains")
        r.eq(compatibility.operationID, nil, "compatibility failure releases coordinator ownership")
        r.eq(await serialB.calls, 0, "cancelled queued operation never enters bottom loader")
        r.eq(b.failure, nil, "caller task cancellation remains cancellation")
        let third = Task { await b.perform(.init(target: .preset(.qwen306B), source: .official, origin: .manual)) }
        await until { await serialB.calls == 1 }
        await serialB.complete(stale)
        await third.value
        r.eq(sharedEnvironment.read(), "original-endpoint", "serialized operations restore environment")
        r.eq(sharedEnvironment.history(), ["https://hf-mirror.com", "original-endpoint", nil, "original-endpoint"], "endpoint scope never overlaps")

    }
}
