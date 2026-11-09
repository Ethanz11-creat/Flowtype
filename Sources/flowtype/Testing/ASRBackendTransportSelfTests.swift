import Foundation
import os
import Security

/// Synthetic PCM and an injected URLProtocol only: no local service or real cloud calls.
enum ASRBackendTransportSelfTests {
    static func profile(_ kind: ASRServiceProtocol = .openAICompatible, fields: CloudASRFieldCapabilities = .init()) -> LocalASRServiceProfile {
        .init(id: UUID(), revision: UUID(), name: "Fixture", baseURL: "http://localhost:8123/v1", protocolKind: kind,
              modelID: "fixture-model", authentication: .none, fieldCapabilities: fields)
    }
    static func run(_ r: SelfTest.Reporter) async {
        testLoopbackBoundary(r)
        testTLSChallenge(r)
        testServicePresets(r)
        await testWireProfiles(r)
        await testResponsesAndLimits(r)
        CloudProviderSelfTests.runConfiguration(r)
        await CloudProviderSelfTests.runTransport(r)
    }
    static func testServicePresets(_ r: SelfTest.Reporter) {
        for preset in [LocalASRServicePreset.mlxAudio, .whisperKit] {
            let profile = preset.makeProfile(baseURL: "http://localhost:8123/v1", modelID: "fixture")
            r.check(profile.fieldCapabilities.sendResponseFormat, "presets: MLX/WhisperKit force JSON wire format")
            r.eq(profile.protocolKind, .openAICompatible, "presets: MLX/WhisperKit batch protocol")
        }
        let cpp = LocalASRServicePreset.whisperCpp.makeProfile(baseURL: "http://localhost:8123", modelID: "ignored")
        r.eq(cpp.modelID, nil, "presets: whisper.cpp model belongs to server")
        r.eq(try? LocalASRServiceEndpoint.transcriptionURL(profile: cpp).path, "/inference", "presets: whisper.cpp endpoint")
        let custom = LocalASRServicePreset.customOpenAICompatible.makeProfile(baseURL: "http://localhost:8123", modelID: "unknown")
        r.eq(custom.fieldCapabilities, .init(), "presets: unknown custom minimal fields")
    }

    static func testTLSChallenge(_ r: SelfTest.Reporter) {
        let certificateData = Data(base64Encoded: "MIICpDCCAYwCCQCQwCooXrt5ITANBgkqhkiG9w0BAQsFADAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwHhcNMjYxMTA5MDk1NjMyWhcNMjYxMTEwMDk1NjMyWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDWFf75A8MO15fV172nNqmF5ffyltmvu7Aaq0ZNlaq442DConkWxAwy0+dNGHu90yl8oOqAm2okU8NVx8YF8iLV74vdqvDoS0/zs2c8EdZ3OOv1pb9AUjomQS9ZZl9AbuGakn84/xCEtmLtq+2jLiwI/hf5N6qYlUSN2EwfFCop1qe2cGS2IryBDPrz1+FQ4yrieb+wmtJPeykpRJGdHTHf8FyAz5sVctOVl94u+7k9LtGcK4RaSIAtYFU1kyaGD33Hq2wHWyG/v5P8LprdpyGRiYEyuF5VxvOpc/rLazMBPXh17/iqeCgthrBoNN0Xgv70vQgiYpe1r94sZFzgfyipAgMBAAEwDQYJKoZIhvcNAQELBQADggEBAJnnidQsUCWfEXytXhbQApHKKvrquuJPdWy7gpbjytFxBP4wj5qRLnuS3uZoQHozvg9QTFJ51LlwrjteJc8FC1q/VpK/Up0IXECk4xy0xqZbT/sQw8VV/sCUb7/nkXSNFvCiKyXZ7aiVrjueT2txd7/UlpfTRxoRF5XPeY6PlEMz63InbSdH59+4bqTNFodnuyPORKBMkah3teVXZkCvVuqV83d6ZlGqXxA9St1Zpm8is7LnYCoAqEfPNce8l7TtaSVHhsnqMfg2m/51yNXeZTxRJtbTurxQHuLYNbRL2UA5NU++VkwmdZ4vP9vhvGS6iX3gmbHB0np8zJP/Pvmn+Ns=")!
        let certificate = SecCertificateCreateWithData(nil, certificateData as CFData)!
        var output: SecTrust?
        SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "localhost" as CFString), &output)
        guard let trust = output else { r.check(false, "TLS: synthetic trust fixture"); return }
        r.check(!ASRHTTPTaskPolicy.evaluateLocalhostTrust(trust), "TLS: self-signed localhost rejected with standard anchors")
        let url = URL(string: "https://127.0.0.1:8123/v1/audio/transcriptions")!
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        for (challengeHost, challengePort, method, trusted, expected) in [
            ("127.0.0.1", 8123, NSURLAuthenticationMethodServerTrust, true, URLSession.AuthChallengeDisposition.useCredential),
            ("127.0.0.1", 8123, NSURLAuthenticationMethodServerTrust, false, .cancelAuthenticationChallenge),
            ("external.invalid", 8123, NSURLAuthenticationMethodServerTrust, true, .cancelAuthenticationChallenge),
            ("127.0.0.1", 443, NSURLAuthenticationMethodServerTrust, true, .cancelAuthenticationChallenge),
            ("127.0.0.1", 8123, NSURLAuthenticationMethodHTTPBasic, true, .cancelAuthenticationChallenge)
        ] {
            let policy = ASRHTTPTaskPolicy(originalHost: "localhost", trustEvaluator: { _ in trusted })
            let protection = BackendTrustProtectionSpace(host: challengeHost, port: challengePort, protocol: "https", realm: nil, authenticationMethod: method)
            protection.fixtureTrust = trust
            let challenge = URLAuthenticationChallenge(protectionSpace: protection, proposedCredential: nil, previousFailureCount: 0,
                failureResponse: nil, error: nil, sender: BackendChallengeSender())
            let disposition = OSAllocatedUnfairLock(initialState: URLSession.AuthChallengeDisposition.performDefaultHandling)
            policy.urlSession(session, task: task, didReceive: challenge) { value, _ in disposition.withLock { $0 = value } }
            r.eq(disposition.withLock { $0 }, expected, "TLS: challenge bound to numeric HTTPS origin and verified trust")
        }
    }

    // Catches permissive URL normalization and DNS validation disconnected from the destination.
    static func testLoopbackBoundary(_ r: SelfTest.Reporter) {
        for base in ["http://localhost:8123/v1", "https://127.0.0.1/v1", "http://[::1]:8123/v1/audio/transcriptions/"] {
            var p = profile(); p.baseURL = base
            r.check((try? LocalASRServiceEndpoint.transcriptionURL(profile: p)) != nil, "loopback: accepted canonical endpoint")
        }
        for base in ["http://localhost:0", "http://localhost:65536", "http://localhost:", "http://user@localhost", "http://localhost?x=1", "http://localhost#x", "http://127.1", "http://2130706433", "http://127.0.0.2", "http://[::ffff:127.0.0.1]", "http://%6cocalhost", "http://LOCALHOST", "http://localhost.", "file://localhost/v1", "http://localhost/v1/%2e%2e/", "http://localhost\\@external.invalid"] {
            var p = profile(); p.baseURL = base
            r.check((try? LocalASRServiceEndpoint.transcriptionURL(profile: p)) == nil, "loopback: rejects ambiguous URL \(base)")
        }
        let url = URL(string: "http://localhost:8123/v1/audio/transcriptions")!
        do {
            let destination = try LocalASRServiceEndpoint.destination(for: url, resolver: { _ in ["127.0.0.1", "::1"] })
            r.eq(destination.url.host, "127.0.0.1", "loopback: connection URL pins numeric resolution")
            r.eq(destination.hostHeader, "localhost:8123", "loopback: original authority retained")
        } catch { r.check(false, "loopback: valid resolution") }
        for addresses in [["203.0.113.1"], ["127.0.0.1", "203.0.113.1"], []] {
            r.check((try? LocalASRServiceEndpoint.destination(for: url, resolver: { _ in addresses })) == nil,
                    "loopback: rejects external/mixed/empty resolution before connection")
        }
        let configuration = ASRHTTPTransport.loopbackConfiguration()
        r.eq(configuration.connectionProxyDictionary?.count, 0, "loopback: proxies disabled")
        r.check(configuration.urlCache == nil && configuration.httpCookieStorage == nil && !configuration.httpShouldSetCookies,
                "loopback: no cache or cookie store")
        let policy = ASRHTTPTaskPolicy(originalHost: "localhost")
        let redirected = OSAllocatedUnfairLock(initialState: true)
        policy.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: url),
                          willPerformHTTPRedirection: HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil)!,
                          newRequest: URLRequest(url: URL(string: "https://external.invalid/upload")!)) { request in redirected.withLock { $0 = request != nil } }
        r.check(!redirected.withLock { $0 }, "loopback: redirect policy refuses audio resend")
        do { _ = try ASRProviderRegistry(adapters: [OpenAICompatibleASRAdapter(), OpenAICompatibleASRAdapter()]); r.check(false, "registry rejects duplicate protocol") }
        catch { r.check(true, "registry rejects duplicate protocol") }
        do {
            let registry = try ASRProviderRegistry(adapters: [OpenAICompatibleASRAdapter()])
            _ = try registry.makeLocalServiceBinding(profile: profile(.dashScopeRealtime), credential: nil, credentialGeneration: nil)
            r.check(false, "registry rejects unsupported realtime service")
        } catch { r.check(true, "registry rejects unsupported realtime service") }
    }
    // Catches leaking opt-in fields, wrong paths/model ownership and broken 16kHz WAV framing.
    static func testWireProfiles(_ r: SelfTest.Reporter) async {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [BackendHTTPFixture.self]
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        for (kind, fields, expectedPath, expectsJSON) in [
            (ASRServiceProtocol.openAICompatible, CloudASRFieldCapabilities(), "/v1/audio/transcriptions", false),
            (.openAICompatible, .init(sendLanguage: true, sendPrompt: true, sendResponseFormat: true), "/v1/audio/transcriptions", true),
            (.whisperCpp, .init(sendLanguage: true, sendPrompt: true), "/v1/inference", true)
        ] {
            BackendHTTPFixture.reset()
            do {
                let adapters: [any ASRServiceAdapter] = [OpenAICompatibleASRAdapter(session: session, resolver: { _ in ["127.0.0.1"] }),
                    WhisperCppASRAdapter(session: session, resolver: { _ in ["127.0.0.1"] })]
                let p = profile(kind, fields: fields)
                let binding = try ASRProviderRegistry(adapters: adapters).makeLocalServiceBinding(profile: p, credential: nil, credentialGeneration: nil)
                let result = try await binding.provider.transcribe(.init(samples: [0, 1, -1, 0.5], sampleRate: 16000, language: "zh",
                    context: .init(phrases: ["fixture-hint"], foreground: nil), timeout: 1))
                r.eq(result.text, "fixture transcript", "wire: JSON text returned")
                r.eq(result.providerID, "service:" + p.id.uuidString, "wire: stable service result identity")
                r.check(!binding.descriptor.requiresInternet && binding.descriptor.capabilities.requiresNetwork, "wire: socket does not imply internet")
                guard let request = BackendHTTPFixture.requests.first else { r.check(false, "wire: captured upload"); continue }
                r.eq(request.url?.path, expectedPath, "wire: protocol-owned path")
                r.eq(request.url?.host, "127.0.0.1", "wire: actual upload uses pinned destination")
                r.eq(request.value(forHTTPHeaderField: "Host"), "localhost:8123", "wire: preserves configured Host")
                let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                r.eq(body.contains("name=\"model\""), kind != .whisperCpp, "wire: server-managed model omitted")
                r.eq(body.contains("name=\"response_format\"\r\n\r\njson"), expectsJSON, "wire: explicit JSON avoids NDJSON")
                r.eq(body.contains("name=\"language\""), fields.sendLanguage, "wire: optional language opt-in")
                r.eq(body.contains("name=\"prompt\""), fields.sendPrompt, "wire: optional prompt opt-in")
                r.check(!body.contains("name=\"temperature\""), "wire: unknown temperature omitted")
                r.check(body.contains("RIFF") && body.contains("WAVE"), "wire: WAV container")
            } catch { r.check(false, "wire: unexpected \(error)") }
        }
        BackendHTTPFixture.reset()
        do {
            let provider = try OpenAICompatibleASRAdapter(session: session, resolver: { _ in ["203.0.113.1"] }).makeProvider(profile: profile(), credential: nil)
            _ = try await provider.transcribe(.init(samples: [0], sampleRate: 16000, language: nil, context: nil, timeout: 1))
            r.check(false, "wire: resolved external destination rejected")
        } catch { r.eq(BackendHTTPFixture.requests.count, 0, "wire: rejected DNS sends zero audio") }
        BackendHTTPFixture.reset(redirect: URL(string: "https://external.invalid/upload")!)
        do {
            let provider = try OpenAICompatibleASRAdapter(session: session, resolver: { _ in ["127.0.0.1"] }).makeProvider(profile: profile(), credential: nil)
            _ = try await provider.transcribe(.init(samples: [0], sampleRate: 16000, language: nil, context: nil, timeout: 1))
            r.check(false, "wire: redirect fails the request")
        } catch { r.check(error is CloudASRError || error is CancellationError, "wire: refused redirect cannot produce transcript") }
        r.eq(BackendHTTPFixture.requests.count, 1, "wire: redirect never resends audio")
        r.check(BackendHTTPFixture.requests.allSatisfy { $0.url?.host == "127.0.0.1" }, "wire: no audio request to redirect target")
        for key in [nil, "", "\ninvalid"] as [String?] {
            var p = profile(); p.authentication = .bearer(credentialID: "fixture-reference")
            do { _ = try OpenAICompatibleASRAdapter(session: session).makeProvider(profile: p, credential: key); r.check(false, "wire: missing/invalid bearer rejected") }
            catch { r.check(error is CloudASRError, "wire: bearer failure classified") }
        }
        BackendHTTPFixture.reset()
        do {
            var p = profile(); p.authentication = .bearer(credentialID: "fixture-reference")
            let provider = try OpenAICompatibleASRAdapter(session: session, resolver: { _ in ["127.0.0.1"] }).makeProvider(profile: p, credential: "fixture-key")
            _ = try await provider.transcribe(.init(samples: [0], sampleRate: 16000, language: nil, context: nil, timeout: 1))
            r.eq(BackendHTTPFixture.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key", "wire: captured bearer only")
        } catch { r.check(false, "wire: valid bearer fixture") }
    }
    static func testResponsesAndLimits(_ r: SelfTest.Reporter) async {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [BackendHTTPFixture.self]
        let session = URLSession(configuration: cfg); defer { session.invalidateAndCancel() }
        let transport = ASRHTTPTransport(session: session)
        let request = URLRequest(url: URL(string: "https://fixture.invalid/transcribe")!)
        for body in ["<html>login</html>", "{}", #"{"text":" "}"#, "{\"text\":\"one\"}\n{\"text\":\"two\"}", "{\"text\":\"" + String(repeating: "x", count: 2 * 1024 * 1024) + "\"}"] {
            BackendHTTPFixture.reset(body: body)
            do { _ = try await transport.transcribe(request, originalHost: nil); r.check(false, "response: malformed/oversize rejected") }
            catch { r.check(error is CloudASRError, "response: safe classification") }
        }
        BackendHTTPFixture.reset(body: "{\"text\":\"" + String(repeating: "x", count: 2 * 1024 * 1024 - 11) + "\"}")
        do {
            let text = try await transport.transcribe(request, originalHost: nil)
            r.eq(text.count, 2 * 1024 * 1024 - 11, "response: exact 2MiB JSON accepted without truncation")
        } catch { r.check(false, "response: exact cap rejected") }
        for status in [301, 307, 400, 401, 403, 404, 429, 503] {
            BackendHTTPFixture.reset(status: status, body: "private body")
            do { _ = try await transport.transcribe(request, originalHost: nil); r.check(false, "response: error status rejected") }
            catch { r.eq((error as? CloudASRError)?.statusCode, status, "response: preserves status category") }
        }
        BackendHTTPFixture.reset()
        let openAI = CloudASRRequestConfiguration(provider: CloudASRVendor.makeProfile(.openAI, isActive: true), apiKey: "fixture", sendContext: false)
        do {
            _ = try CloudTranscriptionRequestBuilder.make(configuration: openAI, samples: [Float](repeating: 0, count: 12_500_000), language: nil, context: nil, timeout: 1)
            r.check(false, "upload: actual OpenAI multipart over 25000000 bytes rejected")
        } catch { r.eq((error as? CloudASRError)?.statusCode, 413, "upload: known profile limit rejects before send") }
        r.eq(BackendHTTPFixture.requests.count, 0, "upload: known oversized profile sends no audio")
        var legacy = CloudASRVendor.makeProfile(.openAI, isActive: true); legacy.model = "whisper-1"
        r.eq(legacy.model, "whisper-1", "presets: old selected model retained")
        r.check(CloudASRVendor.modelPresets(for: legacy).contains { $0.modelId == "whisper-1" && $0.isDeprecated }, "presets: old model remains visibly deprecated")
        var custom = CloudASRVendor.makeProfile(.custom, isActive: true); custom.baseURL = "https://fixture.invalid/v1"; custom.model = "unknown"
        let cloud = CloudASRRequestConfiguration(provider: custom, apiKey: "fixture", sendContext: false)
        do {
            let exact = try ASRMultipartRequest.make(url: request.url!, model: "unknown", fields: .init(), samples: [0], language: nil, context: nil, credential: nil, timeout: 1, maxUploadBytes: nil)
            _ = try ASRMultipartRequest.make(url: request.url!, model: "unknown", fields: .init(), samples: [0], language: nil, context: nil, credential: nil, timeout: 1, maxUploadBytes: Int64(exact.httpBody!.count))
            r.check(true, "upload: exact body threshold accepted")
            do { _ = try ASRMultipartRequest.make(url: request.url!, model: "unknown", fields: .init(), samples: [0], language: nil, context: nil, credential: nil, timeout: 1, maxUploadBytes: 1); r.check(false, "upload: multipart limit enforced") }
            catch { r.eq(BackendHTTPFixture.requests.count, 0, "upload: oversized body never sent") }
            let request = try CloudTranscriptionRequestBuilder.make(configuration: cloud, samples: [0], language: nil, context: nil, timeout: 1)
            r.check(request.httpBody != nil, "upload: unknown cloud model has no invented global limit")
        } catch { r.check(false, "upload: unexpected \(error)") }
    }
}

private final class BackendHTTPFixture: URLProtocol, @unchecked Sendable {
    private struct State { var requests: [URLRequest] = []; var status = 200; var body = #"{"text":"fixture transcript"}"#; var redirect: URL? }
    private static let state = OSAllocatedUnfairLock(initialState: State())
    static var requests: [URLRequest] { state.withLock { $0.requests } }
    static func reset(status: Int = 200, body: String = #"{"text":"fixture transcript"}"#, redirect: URL? = nil) { state.withLock { $0 = State(status: status, body: body, redirect: redirect) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        let frozen = captured
        let (status, body, redirect) = Self.state.withLock { $0.requests.append(frozen); return ($0.status, $0.body, $0.redirect) }
        if let redirect, request.url?.host != redirect.host {
            var forwarded = frozen; forwarded.url = redirect
            client?.urlProtocol(self, wasRedirectedTo: forwarded, redirectResponse: HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil, headerFields: ["Location": redirect.absoluteString])!)
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class BackendTrustProtectionSpace: URLProtectionSpace, @unchecked Sendable {
    var fixtureTrust: SecTrust?
    override var serverTrust: SecTrust? { fixtureTrust }
}
private final class BackendChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}
