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
