import Foundation
import os

/// Catches discovery uploading audio/claiming compatibility and stale validation publishing.
/// All HTTP uses URLProtocol and all recognition uses a cancellation-resistant fixture.
enum ASRBackendValidationSelfTests {
    @MainActor static func run(_ r: SelfTest.Reporter) async {
        await testDiscoveryIsNotRecognition(r)
        await testStaleValidationOwnership(r)
        await testValidationEvidence(r)
    }

    static func testDiscoveryIsNotRecognition(_ r: SelfTest.Reporter) async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DiscoveryHTTPFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = ASRModelDiscoveryClient(session: session, resolver: { _ in ["127.0.0.1"] })
        var profile = ASRBackendTransportSelfTests.profile()
        profile.modelID = nil // Model discovery must work before a model is selected.
        DiscoveryHTTPFixture.reset(body: #"{"data":[{"id":"tts-model"},{"id":"text-model"},{"id":"tts-model"}]}"#)
        do {
            let models = try await client.models(profile: profile, credential: nil)
            r.eq(models, ["tts-model", "text-model"], "discovery: candidates retain order without claiming ASR compatibility")
            let requests = DiscoveryHTTPFixture.requests
            r.eq(requests.count, 1, "discovery: one explicit list request")
            r.eq(requests.first?.httpMethod, "GET", "discovery: never uploads recognition audio")
            r.eq(requests.first?.url?.path, "/v1/models", "discovery: normalized models endpoint")
            r.eq(requests.first?.url?.host, "127.0.0.1", "discovery: pinned loopback destination")
            r.eq(requests.first?.value(forHTTPHeaderField: "Host"), "localhost:8123", "discovery: configured authority preserved")
            r.eq(requests.first?.timeoutInterval, 10, "discovery: ten second request budget")
            r.check(requests.allSatisfy { $0.httpBody == nil && $0.httpBodyStream == nil }, "discovery: no test audio body")
        } catch { r.check(false, "discovery: candidate list unexpected failure") }
        for status in [404, 405] {
            DiscoveryHTTPFixture.reset(status: status)
            do { r.eq(try await client.models(profile: profile, credential: nil), [], "discovery: missing list supports manual model entry") }
            catch { r.check(false, "discovery: missing list must not block manual entry") }
        }
        for status in [401, 403, 307, 429, 503] {
            DiscoveryHTTPFixture.reset(status: status, body: "private response")
            do { _ = try await client.models(profile: profile, credential: nil); r.check(false, "discovery: auth/HTTP error is not an empty successful list") }
            catch { r.eq((error as? CloudASRError)?.statusCode, status, "discovery: HTTP category retained without private body") }
        }
        let thousand = "{\"data\":[" + Array(repeating: "{\"id\":\"candidate\"}", count: 1000).joined(separator: ",") + "]}"
        DiscoveryHTTPFixture.reset(body: thousand)
        do { r.eq(try await client.models(profile: profile, credential: nil), ["candidate"], "discovery: exact item cap accepts then deduplicates") }
        catch { r.check(false, "discovery: exact item limit accepted") }
        for body in ["{}", "<html>private</html>", #"{"data":[{"id":3}]}"#,
                     "{\"data\":[" + Array(repeating: "{\"id\":\"x\"}", count: 1001).joined(separator: ",") + "]}",
                     "{\"data\":[{\"id\":\"" + String(repeating: "x", count: 1024 * 1024) + "\"}]}"] {
            DiscoveryHTTPFixture.reset(body: body)
            do { _ = try await client.models(profile: profile, credential: nil); r.check(false, "discovery: malformed/oversize list rejected without truncation") }
            catch { r.check(error is ASRModelDiscoveryError || error is CloudASRError, "discovery: stable response/limit error") }
        }
        // Exact byte boundary must be accepted, not an accidental strict-less-than limit.
        let prefix = "{\"data\":[{\"id\":\"x\"}],\"padding\":\""
        let exact = prefix + String(repeating: "p", count: 1024 * 1024 - prefix.utf8.count - 2) + "\"}"
        DiscoveryHTTPFixture.reset(body: exact)
        do { r.eq(try await client.models(profile: profile, credential: nil), ["x"], "discovery: exact 1MiB accepted") }
        catch { r.check(false, "discovery: exact byte cap accepted") }
        DiscoveryHTTPFixture.reset(error: URLError(.timedOut))
        do { _ = try await client.models(profile: profile, credential: nil); r.check(false, "discovery: timeout cannot succeed") }
        catch { if case .timeout = error as? CloudASRError { r.check(true, "discovery: timeout classified") } else { r.check(false, "discovery: timeout classified") } }
        DiscoveryHTTPFixture.reset()
        let external = ASRModelDiscoveryClient(session: session, resolver: { _ in ["203.0.113.1"] })
        do { _ = try await external.models(profile: profile, credential: nil); r.check(false, "discovery: external DNS refused") }
        catch { r.eq(DiscoveryHTTPFixture.requests.count, 0, "discovery: external DNS never sends credential") }
        var cloud = CloudASRVendor.makeProfile(.custom, isActive: true)
        cloud.baseURL = "https://fixture.invalid/proxy/v1/audio/transcriptions"; cloud.model = ""
        DiscoveryHTTPFixture.reset(body: #"{"data":[{"id":"cloud-model"}]}"#)
        do {
            r.eq(try await client.models(cloudProfile: cloud, apiKey: "fixture-only"), ["cloud-model"], "discovery: cloud list before model selection")
            r.eq(DiscoveryHTTPFixture.requests.first?.url?.path, "/proxy/v1/models", "discovery: full transcription path normalized")
            r.eq(DiscoveryHTTPFixture.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-only", "discovery: captured cloud credential")
        } catch { r.check(false, "discovery: cloud candidates") }
        cloud.baseURL = "http://fixture.invalid/v1"
        DiscoveryHTTPFixture.reset()
        do { _ = try await client.models(cloudProfile: cloud, apiKey: "fixture-only"); r.check(false, "discovery: cloud HTTP rejected") }
        catch { r.eq(DiscoveryHTTPFixture.requests.count, 0, "discovery: cloud HTTPS boundary retained") }
        var cpp = profile; cpp.protocolKind = .whisperCpp
        DiscoveryHTTPFixture.reset()
        do { r.eq(try await client.models(profile: cpp, credential: nil), [], "discovery: server-managed model supports manual display") }
        catch { r.check(false, "discovery: server-managed model needs no list") }
        r.eq(DiscoveryHTTPFixture.requests.count, 0, "discovery: whisper.cpp does not probe/load models")
    }

    @MainActor static func testStaleValidationOwnership(_ r: SelfTest.Reporter) async {
        let fixture = ValidationRecognitionFixture()
        var records: [ASRServiceValidationRecord] = []
        let coordinator = ASRServiceValidationCoordinator(onVerified: { records.append($0) }, serviceRecognition: { profile, credential, sample in
            try await fixture.send(profile, credential, sample)
        })
        var profile = ASRBackendTransportSelfTests.profile()
        let sample = try! ASRValidationSample(samples: [0, 0.25], sampleRate: 16000, label: "fixture")
        r.eq(coordinator.state(profileID: profile.id), .idle, "validation: no automatic probe on creation")
        let initial = profile
        let first = Task { await coordinator.test(profile: initial, credential: "fixture-A", sample: sample) }
        await fixture.waitForCall()
        r.eq(coordinator.state(profileID: profile.id), .testing, "validation: user action owns testing state")
        await coordinator.test(profile: profile, credential: "fixture-A", sample: sample)
        r.eq(fixture.calls.count, 1, "validation: double-click sends once")
        coordinator.invalidate(profileID: profile.id)
        r.eq(coordinator.state(profileID: profile.id), .idle, "validation: edit/delete/close invalidates immediately")
        r.check(coordinator.isTesting(profileID: profile.id), "validation: cancelled transport retains drain slot")
        profile.modelID = "edited-model"; profile.revision = UUID()
        await coordinator.test(profile: profile, credential: "fixture-B", sample: sample)
        r.eq(fixture.calls.count, 1, "validation: edited owner cannot overlap draining request")
        fixture.finish("late-private-transcript")
        await first.value
        r.eq(coordinator.state(profileID: profile.id), .idle, "validation: stale completion cannot publish")
        r.eq(records.count, 0, "validation: stale recognition emits no persistent record")
        r.check(!coordinator.isTesting(profileID: profile.id), "validation: owner alone releases its slot")
        let edited = profile
        let generation = UUID()
        let second = Task { await coordinator.test(profile: edited, credential: "fixture-B", sample: sample, credentialGeneration: generation) }
        await fixture.waitForCall(count: 2)
        r.eq(fixture.calls.last?.0.modelID, "edited-model", "validation: fresh call captures edited model")
        r.eq(fixture.calls.last?.1, "fixture-B", "validation: fresh call captures edited credential")
        r.eq(fixture.calls.last?.2.sha256, sample.sha256, "validation: supplied sample captured")
        fixture.finish("fresh transcript")
        await second.value
        if case .verified(_, let text) = coordinator.state(profileID: profile.id) { r.eq(text, "fresh transcript", "validation: current owner publishes transcript") }
        else { r.check(false, "validation: fresh recognition verified") }
        r.eq(records.count, 1, "validation: current recognition emits one record")
        r.eq(records.first?.backendID.rawValue, "service:" + profile.id.uuidString, "validation: record uses stable backend identity")
        r.eq(records.first?.revision, edited.revision, "validation: record binds captured revision")
        r.eq(records.first?.credentialGeneration, generation, "validation: record binds atomic credential generation")
        if let record = records.first {
            let encoded = String(decoding: try! JSONEncoder().encode(record), as: UTF8.self)
            r.check(!encoded.contains("fresh transcript") && !encoded.contains("fixture-B") && !encoded.contains("localhost"), "validation: persistence record excludes transcript, key, URL")
            r.eq(try! JSONDecoder().decode(ASRServiceValidationRecord.self, from: Data(encoded.utf8)), record, "validation: date/identity record round-trip")
        }
        // Changes in wire fields and generation invalidate even if a caller forgot revision.
        let third = Task { await coordinator.test(profile: edited, credential: "fixture-B", sample: sample, credentialGeneration: UUID()) }
        await fixture.waitForCall(count: 3)
        var changed = edited; changed.fieldCapabilities.sendPrompt = true
        await coordinator.test(profile: changed, credential: "fixture-B", sample: sample, credentialGeneration: UUID())
        r.eq(coordinator.state(profileID: profile.id), .idle, "validation: wire/generation change cancels stale owner")
        fixture.finish("late generation")
        await third.value
        r.eq(coordinator.state(profileID: profile.id), .idle, "validation: changed configuration cannot inherit evidence")
        let fourth = Task { await coordinator.test(profile: changed, credential: "fixture-B", sample: sample) }
        await fixture.waitForCall(count: 4)
        fourth.cancel()
        fixture.finish("late cancelled")
        await fourth.value
        r.eq(coordinator.state(profileID: profile.id), .idle, "validation: caller cancellation suppresses late success")
        r.eq(records.count, 1, "validation: edited/generation/cancelled completions emit no record")
    }

    @MainActor static func testValidationEvidence(_ r: SelfTest.Reporter) async {
        let sample = try! ASRValidationSample(samples: [0], sampleRate: 16000, label: "fixture")
        var records: [ASRServiceValidationRecord] = []
        let coordinator = ASRServiceValidationCoordinator(onVerified: { records.append($0) }, cloudRecognition: { _, _, _ in "cloud transcript" })
        var cloud = CloudASRVendor.makeProfile(.custom, isActive: true)
        cloud.baseURL = "https://fixture.invalid/v1"; cloud.model = "model"
        coordinator.checkConfiguration(cloudProfile: cloud, apiKey: "fixture")
        r.eq(coordinator.state(profileID: cloud.id), .configurationValid, "validation: configuration check is not recognition")
        r.eq(records.count, 0, "validation: configuration check emits no record")
        await coordinator.test(cloudProfile: cloud, apiKey: "fixture", sample: sample)
        if case .verified(_, let text) = coordinator.state(profileID: cloud.id) { r.eq(text, "cloud transcript", "validation: cloud explicit recognition overload") }
        else { r.check(false, "validation: cloud explicit recognition verified") }
        r.eq(records.count, 1, "validation: cloud recognition emits record")
        r.eq(records.first?.backendID.rawValue, "cloud:" + cloud.id.uuidString, "validation: cloud record stable identity")
        let dash = CloudASRProviderConfig.defaultParaformer()
        await coordinator.test(cloudProfile: dash, apiKey: "fixture", sample: sample)
        r.eq(coordinator.state(profileID: dash.id), .configurationValid, "validation: DashScope configuration cannot become recognition evidence")
        r.eq(records.count, 1, "validation: DashScope configuration check emits no record")
        let failed = ASRServiceValidationCoordinator(serviceRecognition: { _, _, _ in throw CloudASRError.apiError(statusCode: 401, message: "private") })
        let profile = ASRBackendTransportSelfTests.profile()
        await failed.test(profile: profile, credential: nil, sample: sample)
        r.eq(failed.state(profileID: profile.id), .failed(code: "auth"), "validation: safe stable failure code")
        let empty = ASRServiceValidationCoordinator(serviceRecognition: { _, _, _ in "  " })
        await empty.test(profile: profile, credential: nil, sample: sample)
        r.eq(empty.state(profileID: profile.id), .failed(code: "invalidResponse"), "validation: empty recognition never verifies")
    }
}

@MainActor private final class ValidationRecognitionFixture {
    var calls: [(LocalASRServiceProfile, String?, ASRValidationSample)] = []
    var pending: CheckedContinuation<String, Error>?
    func send(_ profile: LocalASRServiceProfile, _ credential: String?, _ sample: ASRValidationSample) async throws -> String {
        calls.append((profile, credential, sample))
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func waitForCall(count: Int = 1) async { for _ in 0..<10_000 { if calls.count >= count { return }; await Task.yield() } }
    func finish(_ text: String) { let value = pending; pending = nil; value?.resume(returning: text) }
}

private final class DiscoveryHTTPFixture: URLProtocol, @unchecked Sendable {
    private struct State { var requests: [URLRequest] = []; var status = 200; var body = #"{"data":[]}"#; var error: URLError? }
    private static let state = OSAllocatedUnfairLock(initialState: State())
    static var requests: [URLRequest] { state.withLock { $0.requests } }
    static func reset(status: Int = 200, body: String = #"{"data":[]}"#, error: URLError? = nil) { state.withLock { $0 = State(status: status, body: body, error: error) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let snapshot = Self.state.withLock { $0.requests.append(request); return ($0.status, $0.body, $0.error) }
        if let error = snapshot.2 { client?.urlProtocol(self, didFailWithError: error); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: snapshot.0, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(snapshot.1.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
