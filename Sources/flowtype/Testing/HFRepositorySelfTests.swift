import Foundation
import CryptoKit
import os

/// Only synthetic metadata reaches an injected URLProtocol; no Hub SDK/global tokens or weights.
enum HFRepositorySelfTests {
    static let commit = String(repeating: "a", count: 40)
    static let gitOID = String(repeating: "b", count: 40)
    static let lfsOID = String(repeating: "c", count: 64)
    static let selection = HFRepositorySelection(repoID: "org/repo", requestedRevision: "main", subdirectory: nil)
    static func run(_ r: SelfTest.Reporter) async {
        testRepositoryInput(r)
        await testPinnedCommitPagination(r)
        await testBlobInputResolution(r)
        await testMetadataLimitsAndAuth(r)
        await testByteBudgets(r)
        testRedirectPolicy(r)
    }
    static func testRepositoryInput(_ r: SelfTest.Reporter) {
        for input in ["org/repo", "https://huggingface.co/org/repo", "https://huggingface.co/org/repo/"] {
            r.eq(try? HFRepositoryInput.parse(input), selection, "input: model repository accepted")
        }
        for kind in ["tree", "blob"] {
            let input = "https://huggingface.co/org/repo/\(kind)/refs/pr/12/variant/config.json"
            do { _ = try HFRepositoryInput.parse(input); r.check(false, "input: suffix needs confirmation") }
            catch { r.eq(error as? HFRepositoryInputError,
                .requiresSelection(repoID: "org/repo", suffix: "refs/pr/12/variant/config.json", kind: kind), "input: structured suffix preserved") }
            if kind == "tree" {
                r.eq(try? HFRepositoryInput.parse(input, revision: "refs/pr/12", subdirectory: "variant/config.json"),
                    .init(repoID: "org/repo", requestedRevision: "refs/pr/12", subdirectory: "variant/config.json"), "input: explicit slash revision boundary")
            }
            r.check((try? HFRepositoryInput.parse(input, revision: "other")) == nil, "input: conflicting revision rejected")
        }
        r.eq(try? HFRepositoryInput.parse("org/repo", revision: "refs/pr/12", subdirectory: "a/b"),
            .init(repoID: "org/repo", requestedRevision: "refs/pr/12", subdirectory: "a/b"), "input: explicit revision and subtree")
        for input in ["hf://org/repo", "http://huggingface.co/org/repo", "https://mirror.invalid/org/repo", "datasets/org/repo", "spaces/org/repo", "org/repo/extra", "org/..", "../repo", "org/re%70o", "org/repo\0", "https://huggingface.co/datasets/org/repo", "https://huggingface.co/spaces/org/repo", "https://user:pass@huggingface.co/org/repo", "https://huggingface.co/org/repo?token=fixture", "https://huggingface.co/org/repo#token", "https://huggingface.co/org/repo/tree/../main", "https://huggingface.co/org/repo/tree/%2e%2e/main", "https://huggingface.co/org/repo/tree/%252e%252e/main", "https://huggingface.co/org/repo/tree/main/%2Fsecret", "https://huggingface.co/org/repo/tree/main/a\\b"] {
            r.check((try? HFRepositoryInput.parse(input)) == nil, "input: unsafe/unsupported input rejected")
        }
        for bad in ["../main", "a/../b", "a//b", "/main", "a%2fb", "a\0", "a\\b"] {
            r.check((try? HFRepositoryInput.parse("org/repo", revision: bad)) == nil, "input: unsafe revision rejected")
            r.check((try? HFRepositoryInput.parse("org/repo", subdirectory: bad)) == nil, "input: unsafe subtree rejected")
        }
    }

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [HFMetadataFixture.self]
        cfg.urlCache = nil; cfg.httpCookieStorage = nil; cfg.urlCredentialStorage = nil
        return URLSession(configuration: cfg)
    }
    static func entry(_ path: String, size: Int64 = 1, lfs: Bool = false) -> [String: Any] {
        var e: [String: Any] = ["type": "file", "path": path, "size": size, "oid": gitOID]
        if lfs { e["lfs"] = ["oid": lfsOID, "size": size, "pointerSize": 130] }
        return e
    }
    static func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    static func info() -> HFMetadataFixture.Reply { .init(body: json(["id": "org/repo", "sha": commit])) }

    // Catches moving-main traversal, partial page discovery, absent tags and escaped revision errors.
    static func testPinnedCommitPagination(_ r: SelfTest.Reporter) async {
        let session = session(); defer { session.invalidateAndCancel() }
        let store = KeychainASRCredentialStore(access: .memory())
        HFMetadataFixture.reset { request, index in
            if index == 0 { return info() }
            if index == 1 { return .init(body: json((0..<4).map { entry("f\($0)", lfs: $0 == 0) }),
                headers: ["Link": "<https://huggingface.co/api/models/org/repo/tree/\(commit)?recursive=true&limit=1000&cursor=two>; rel=\"next\""]) }
            return .init(body: json((4..<7).map { entry("f\($0)") }))
        }
        do {
            let client = HFRepositoryClient(session: session, credentialStore: store)
            let resolved = try await client.resolve(selection)
            r.eq(resolved.commit, commit, "freeze branch revision")
            r.eq(resolved.files.count, 7, "all paginated files retained")
            r.eq(resolved.files.first?.digest, .sha256(lfsOID), "LFS uses SHA256 not pointer blob ID")
            r.eq(resolved.files.last?.digest, .gitBlobSHA1(gitOID), "ordinary files retain Git blob digest")
            r.eq(resolved.downloadEndpoint.absoluteString, "https://huggingface.co", "captured endpoint")
            let urls = HFMetadataFixture.requests.compactMap(\.url)
            r.eq(urls.count, 3, "resolve queries branch exactly once")
            r.eq(urls.dropFirst().map { $0.path }, Array(repeating: "/api/models/org/repo/tree/\(commit)", count: 2), "all followup requests use pinned commit")
            r.check(urls[0].path.hasSuffix("/revision/main"), "model revision API route")
            r.check(urls[1].query?.contains("recursive=true") == true, "recursive file traversal requested")
            let planned = HFPlannedFile(source: selection, downloadEndpoint: resolved.downloadEndpoint, resolvedCommit: commit,
                remotePath: "f0", relativeDestination: "model/f0", sizeBytes: 1, digest: .sha256(lfsOID))
            r.eq(try JSONDecoder().decode(HFPlannedFile.self, from: JSONEncoder().encode(planned)), planned, "planned-file cross-task schema roundtrips")
        } catch { r.check(false, "pinned pagination unexpectedly failed: \(error)") }
        HFMetadataFixture.reset { _, index in index == 0 ? info() : .init(body: json([])) }
        do {
            _ = try await HFRepositoryClient(session: session, credentialStore: store).resolve(.init(repoID: "org/repo", requestedRevision: "refs/pr/12", subdirectory: "folder name/sub"))
            r.check(HFMetadataFixture.requests.first?.url?.absoluteString.contains("/revision/refs%2Fpr%2F12") == true, "slash revision encoded as one API segment")
            r.check(HFMetadataFixture.requests.last?.url?.absoluteString.contains("/tree/\(commit)/folder%20name/sub") == true, "subdirectory encoded by path segments")
        } catch { r.check(false, "slash revision fixture unexpectedly failed") }
    }

    // A blob names a file; resolve its containing subtree and confirm that exact file exists.
    static func testBlobInputResolution(_ r: SelfTest.Reporter) async {
        let session = session(); defer { session.invalidateAndCancel() }
        let store = KeychainASRCredentialStore(access: .memory())
        for (revision, filePath, parent) in [("main", "config.json", nil as String?),
            ("main", "variant/config.json", "variant"), ("refs/pr/12", "variant/nested/config.json", "variant/nested")] {
            let input = "https://huggingface.co/org/repo/blob/\(revision)/\(filePath)"
            let expectedTreePath = "/api/models/org/repo/tree/\(commit)" + (parent.map { "/" + $0 } ?? "")
            HFMetadataFixture.reset { request, _ in
                if request.url!.path.contains("/revision/") { return info() }
                guard request.url!.path == expectedTreePath else { return .init(status: 404, body: Data()) }
                let sibling = parent.map { $0 + "/weights.safetensors" } ?? "weights.safetensors"
                return .init(body: json([entry(filePath), entry(sibling)]))
            }
            do {
                let selected = try HFRepositoryInput.parse(input, revision: revision, subdirectory: parent)
                r.eq(selected.subdirectory, parent, "blob: containing directory selected")
                let encodedSelection = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selected)) as? [String: Any]
                r.eq(encodedSelection?["referencedFilePath"] as? String, filePath, "blob: referenced file identity survives Codable selection")
                let repo = try await HFRepositoryClient(session: session, credentialStore: store).resolve(selected)
                r.eq(repo.commit, commit, "blob: immutable commit retained")
                r.eq(repo.files.count, 2, "blob: complete containing model subtree retained")
                r.check(repo.files.contains { $0.remotePath == filePath }, "blob: referenced file appears in manifest")
                r.eq(HFMetadataFixture.requests.last?.url?.path, expectedTreePath, "blob: file path never used as tree directory")
                if revision.contains("/") {
                    r.check(HFMetadataFixture.requests.first?.url?.absoluteString.contains("/revision/refs%2Fpr%2F12") == true,
                        "blob: explicit slash revision encoded in one segment")
                }
            } catch { r.check(false, "blob parse-to-resolve unexpectedly failed: \(error)") }
            for badSubdirectory in [filePath, "other"] {
                do { _ = try HFRepositoryInput.parse(input, revision: revision, subdirectory: badSubdirectory); r.check(false, "blob: conflicting subtree rejected") }
                catch { r.eq(error as? HFRepositoryInputError, .conflictingSelection, "blob: explicit subtree must equal parent directory") }
            }
            HFMetadataFixture.reset { request, _ in request.url!.path.contains("/revision/") ? info() : .init(body: json([])) }
            do {
                let selected = try HFRepositoryInput.parse(input, revision: revision)
                _ = try await HFRepositoryClient(session: session, credentialStore: store).resolve(selected)
                r.check(false, "blob: nonexistent referenced file rejected")
            } catch { r.eq(error as? HFRepositoryError, .fileNotInRepository, "blob: file existence verified before returning preview") }
        }
        do {
            let legacy = try JSONDecoder().decode(HFRepositorySelection.self, from: json(["repoID": "org/repo", "requestedRevision": "main"]))
            r.eq(legacy, selection, "blob: legacy selection decodes without source file field")
            let forged = try JSONDecoder().decode(HFRepositorySelection.self, from: json(["repoID": "org/repo", "requestedRevision": "main",
                "subdirectory": "variant", "referencedFilePath": "other/config.json"]))
            _ = try await HFRepositoryClient(session: session, credentialStore: store).resolve(forged)
            r.check(false, "blob: forged file outside selected parent rejected")
        } catch { r.eq(error as? HFRepositoryError, .invalidPath, "blob: referenced file must agree with selected subtree") }
        do { _ = try HFRepositoryInput.parse("https://huggingface.co/org/repo/blob/refs/pr/12", revision: "refs/pr/12"); r.check(false, "blob: file suffix required") }
        catch { r.eq(error as? HFRepositoryInputError, .invalidInput, "blob: revision without file rejected") }
    }

    static func expectFailure(_ r: SelfTest.Reporter, _ expected: HFRepositoryError,
        handler: @escaping @Sendable (URLRequest, Int) -> HFMetadataFixture.Reply) async {
        HFMetadataFixture.reset(handler)
        let session = session(); defer { session.invalidateAndCancel() }
        do {
            _ = try await HFRepositoryClient(session: session, credentialStore: KeychainASRCredentialStore(access: .memory())).resolve(selection)
            r.check(false, "metadata: expected \(expected)")
        } catch { r.eq(error as? HFRepositoryError, expected, "metadata failure classification") }
    }
    static func testMetadataLimitsAndAuth(_ r: SelfTest.Reporter) async {
        for (status, expected) in [(401, HFRepositoryError.unauthorized), (403, .forbidden), (404, .notFound), (503, .httpStatus(503))] {
            await expectFailure(r, expected) { _, _ in .init(status: status, body: Data("private server text".utf8)) }
        }
        await expectFailure(r, .invalidCommit) { _, _ in .init(body: json(["sha": "main"])) }
        await expectFailure(r, .byteLimit) { _, _ in .init(body: Data(), headers: ["Content-Length": "16777217"]) }
        await expectFailure(r, .invalidPagination) { _, index in index == 0 ? info() : .init(body: json([]), headers: ["Link": "<https://other.invalid/page?cursor=x>; rel=\"next\""]) }
        await expectFailure(r, .invalidPagination) { _, index in index == 0 ? info() : .init(body: json([]), headers: ["Link": "<https://huggingface.co/api/models/org/repo/tree/main?cursor=x>; rel=\"next\""]) }
        await expectFailure(r, .paginationLoop) { request, index in
            index == 0 ? info() : .init(body: json([]), headers: ["Link": "<https://huggingface.co/api/models/org/repo/tree/\(commit)?recursive=true&limit=1000&cursor=repeat>; rel=\"next\""])
        }
        await expectFailure(r, .pageLimit) { _, index in index == 0 ? info() : .init(body: json((0...1000).map { entry("f\($0)") })) }
        await expectFailure(r, .fileLimit) { _, index in
            if index == 0 { return info() }
            let count = index == 11 ? 1 : 1000
            let body = json((0..<count).map { entry("f\((index - 1) * 1000 + $0)") })
            return .init(body: body, headers: index == 11 ? [:] : ["Link": "<https://huggingface.co/api/models/org/repo/tree/\(commit)?cursor=\(index)>; rel=\"next\""])
        }
        await expectFailure(r, .totalSizeOverflow) { _, index in index == 0 ? info() : .init(body: json([entry("a", size: Int64.max), entry("b")])) }
        await expectFailure(r, .conflictingFile) { _, index in index == 0 ? info() : .init(body: json([entry("a"), entry("a", size: 2)])) }
        await expectFailure(r, .missingFileMetadata) { _, index in index == 0 ? info() : .init(body: json([["type": "file", "path": "a", "oid": gitOID]])) }
        await expectFailure(r, .missingFileMetadata) { _, index in index == 0 ? info() : .init(body: json([["type": "file", "path": "a", "size": 1, "oid": "untrusted-etag"]])) }
        await expectFailure(r, .invalidPath) { _, index in index == 0 ? info() : .init(body: json([entry("../secret")])) }
        await testMetadataReadingAndAuth(r)
    }
    static func testMetadataReadingAndAuth(_ r: SelfTest.Reporter) async {
        let body = Data(#"{"model_type":"fixture"}"#.utf8)
        var gitData = Data("blob \(body.count)\0".utf8); gitData.append(body)
        let oid = Insecure.SHA1.hash(data: gitData).map { String(format: "%02x", $0) }.joined()
        let session = session(); defer { session.invalidateAndCancel() }
        let store = KeychainASRCredentialStore(access: .memory())
        do { try store.write("synthetic-hf-key", id: "asr.hf.official") } catch { r.check(false, "memory credential setup") }
        HFMetadataFixture.reset { _, index in
            if index % 3 == 0 { return info() }
            if index % 3 == 1 { return .init(body: json([["type": "file", "path": "config.json", "size": body.count, "oid": oid]])) }
            return .init(body: body)
        }
        do {
            let client = HFRepositoryClient(session: session, credentialStore: store)
            let repo = try await client.resolve(selection, credentialID: "asr.hf.official")
            r.eq(try await client.readMetadata(file: repo.files[0], repository: repo), body, "metadata read verifies Git blob header digest")
            r.check(HFMetadataFixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-hf-key" }, "official source uses only explicit credential")
            r.check(HFMetadataFixture.requests.last?.url?.path.contains("/resolve/\(commit)/config.json") == true, "metadata read pins resolve URL")
            let forged = HFRepositoryFile(remotePath: "../secret", sizeBytes: 1, digest: .gitBlobSHA1(gitOID))
            do { _ = try await client.readMetadata(file: forged, repository: repo); r.check(false, "metadata membership required") }
            catch { r.eq(error as? HFRepositoryError, .fileNotInRepository, "metadata cannot request injected file") }
        } catch { r.check(false, "metadata read fixture failed: \(error)") }
        // A second resolve must not replace the first result's captured credential.
        HFMetadataFixture.reset { request, _ in
            if request.url!.path.contains("/revision/") { return info() }
            if request.url!.path.contains("/tree/") { return .init(body: json([["type": "file", "path": "config.json", "size": body.count, "oid": oid]])) }
            return .init(body: body)
        }
        do {
            let client = HFRepositoryClient(session: session, credentialStore: store)
            let auth = try await client.resolve(selection, credentialID: "asr.hf.official")
            let anon = try await client.resolve(selection)
            _ = try await client.readMetadata(file: auth.files[0], repository: auth)
            _ = try await client.readMetadata(file: anon.files[0], repository: anon)
            r.eq(HFMetadataFixture.requests.suffix(2).map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer synthetic-hf-key", nil], "same repo results keep distinct captured auth contexts")
        } catch { r.check(false, "captured context fixture failed") }
        HFMetadataFixture.reset { request, _ in request.url!.path.contains("/revision/") ? info() : .init(body: json([])) }
        do {
            let client = HFRepositoryClient(downloadEndpoint: URL(string: "https://mirror.invalid")!, session: session, credentialStore: store)
            _ = try await client.resolve(selection, credentialID: "asr.hf.official")
            r.check(HFMetadataFixture.requests.allSatisfy { $0.url?.host == "mirror.invalid" && $0.value(forHTTPHeaderField: "Authorization") == nil }, "HF token stays official-origin only; mirror anonymous")
        } catch { r.check(false, "anonymous mirror fixture failed") }
        for bad in ["asr.cloud.fixture", "asr.service.fixture", "asr.hf.other"] {
            do { _ = try await HFRepositoryClient(session: session, credentialStore: store).resolve(selection, credentialID: bad); r.check(false, "foreign credential rejected") }
            catch { r.eq(error as? HFRepositoryError, .invalidCredential, "HF credential namespace enforced") }
        }
        HFMetadataFixture.reset { request, _ in
            if request.url!.path.contains("/revision/") { return info() }
            if request.url!.path.contains("/tree/") { return .init(body: json([["type": "file", "path": "config.json", "size": body.count, "oid": oid]])) }
            return .init(body: Data(repeating: 120, count: body.count))
        }
        do {
            let client = HFRepositoryClient(session: session, credentialStore: store)
            let repo = try await client.resolve(selection)
            _ = try await client.readMetadata(file: repo.files[0], repository: repo)
            r.check(false, "metadata digest mismatch rejected")
        } catch { r.eq(error as? HFRepositoryError, .digestMismatch, "metadata digest checked before parser") }
    }
    // Reduced caps exercise streamed bodies/cumulative accounting without large fixtures.
    static func testByteBudgets(_ r: SelfTest.Reporter) async {
        let session = session(); defer { session.invalidateAndCancel() }
        HFMetadataFixture.reset { _, _ in .init(body: Data(repeating: 32, count: 65)) }
        do {
            _ = try await HFRepositoryClient(session: session, credentialStore: KeychainASRCredentialStore(access: .memory()),
                metadataLimits: .init(responseBytes: 64)).resolve(selection)
            r.check(false, "unadvertised streamed body bounded")
        } catch { r.eq(error as? HFRepositoryError, .byteLimit, "streaming body cap enforced before JSON decoding") }
        let body = Data(repeating: 32, count: 900)
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        HFMetadataFixture.reset { request, _ in
            if request.url!.path.contains("/revision/") { return info() }
            if request.url!.path.contains("/tree/") {
                return .init(body: json([["type": "file", "path": "config.json", "size": body.count, "oid": gitOID,
                    "lfs": ["oid": hash, "size": body.count, "pointerSize": 130]]]))
            }
            return .init(body: body)
        }
        do {
            let client = HFRepositoryClient(session: session, credentialStore: KeychainASRCredentialStore(access: .memory()),
                metadataLimits: .init(responseBytes: 1024, preflightBytes: 2500))
            let first = try await client.resolve(selection)
            let second = try await client.resolve(selection)
            r.eq(try await client.readMetadata(file: first.files[0], repository: first), body, "LFS metadata SHA256 verified")
            _ = try await client.readMetadata(file: first.files[0], repository: first)
            do { _ = try await client.readMetadata(file: first.files[0], repository: first); r.check(false, "cumulative preview cap enforced") }
            catch { r.eq(error as? HFRepositoryError, .byteLimit, "all metadata reads share preview byte budget") }
            r.eq(try await client.readMetadata(file: second.files[0], repository: second), body, "separate previews have independent budgets")
        } catch { r.check(false, "cumulative budget fixture failed: \(error)") }
    }
    static func testRedirectPolicy(_ r: SelfTest.Reporter) {
        let policy = HFMetadataRedirectPolicy()
        var original = URLRequest(url: URL(string: "https://huggingface.co/config")!)
        original.setValue("Bearer synthetic", forHTTPHeaderField: "Authorization")
        r.eq(policy.redirectedRequest(original)?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic", "same official origin retains bearer")
        for url in ["https://cdn.invalid/signed?signature=fixture", "https://huggingface.co:444/x", "https://mirror.invalid/x"] {
            var req = original; req.url = URL(string: url)!
            r.eq(HFMetadataRedirectPolicy().redirectedRequest(req)?.value(forHTTPHeaderField: "Authorization"), nil, "redirect strips bearer outside official origin")
            r.check(HFMetadataRedirectPolicy().redirectedRequest(req) != nil, "HTTPS CDN redirect allowed")
        }
        for url in ["http://cdn.invalid/x", "https://user@cdn.invalid/x", "file:///tmp/config"] {
            var req = original; req.url = URL(string: url)!
            r.check(HFMetadataRedirectPolicy().redirectedRequest(req) == nil, "unsafe redirect rejected")
        }
        let bounded = HFMetadataRedirectPolicy()
        for _ in 0..<5 { r.check(bounded.redirectedRequest(original) != nil, "five HTTPS redirect hops allowed") }
        r.check(bounded.redirectedRequest(original) == nil, "sixth redirect hop refused")
    }
}

final class HFMetadataFixture: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var body: Data
        var headers: [String: String] = [:]
    }
    private struct State {
        var requests: [URLRequest] = []
        var handler: @Sendable (URLRequest, Int) -> Reply = { _, _ in .init(status: 500, body: Data()) }
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())
    static var requests: [URLRequest] { state.withLock { $0.requests } }
    static func reset(_ handler: @escaping @Sendable (URLRequest, Int) -> Reply) { state.withLock { $0 = State(handler: handler) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (handler, index) = Self.state.withLock { s in let i = s.requests.count; s.requests.append(request); return (s.handler, i) }
        let reply = handler(request, index)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
