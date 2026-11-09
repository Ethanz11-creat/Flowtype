import Foundation
import CryptoKit
import os

/// Synthetic streaming HTTP responses only; each test owns an isolated temporary directory.
enum HFDownloadSelfTests {
    static let bytes = Data("abcdefgh".utf8)
    static func file(_ data: Data = bytes, git: Bool = false, endpoint: String = "https://huggingface.co") -> HFPlannedFile {
        var blob = Data("blob \(data.count)\0".utf8); blob.append(data)
        let digest: HFFileDigest = git ? .gitBlobSHA1(Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined()) : .sha256(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        return .init(source: HFRepositorySelfTests.selection, downloadEndpoint: URL(string: endpoint)!, resolvedCommit: HFRepositorySelfTests.commit,
                     remotePath: "weights.bin", relativeDestination: "weights.bin", sizeBytes: Int64(data.count), digest: digest)
    }
    static func run(_ r: SelfTest.Reporter) async {
        await testRangeResponses(r)
        await testRenewedResolveURL(r)
        testDigestFormats(r)
        await testRetryAndFailures(r)
        await testDiskCreationFailures(r)
        await testVerified416Cancellation(r)
        await testTransportCancellation(r)
    }
    static func root() -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("flowtype-B3-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
    static func transport(clock: HFDownloadTestClock = .init(), writer: HFDownloadTransport.ChunkWriter? = nil) -> HFDownloadTransport {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HFDownloadFixture.self]
        return HFDownloadTransport(configuration: config, credentialStore: KeychainASRCredentialStore(access: .memory()), sleep: { try await clock.sleep($0) }, chunkWriter: writer)
    }
    static func rejects(_ r: SelfTest.Reporter, _ expected: HFDownloadError.Code, file: HFPlannedFile = file(), at url: URL, transport: HFDownloadTransport = transport(), _ label: String) async {
        do { try await transport.transfer(file: file, partialURL: url, credentialID: nil, progress: { _ in }); r.check(false, label) }
        catch { r.eq((error as? HFDownloadError)?.code, expected, label) }
    }
    static func testRangeResponses(_ r: SelfTest.Reporter) async {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("partial")
        for status in [206, 200] {
            try! bytes.prefix(4).write(to: url)
            HFDownloadFixture.reset { _, _ in .init(status: status, headers: status == 206 ? ["Content-Range": "bytes 4-7/8"] : [:], chunks: [status == 206 ? Data(bytes.suffix(4)) : bytes]) }
            do {
                try await transport().transfer(file: file(), partialURL: url, credentialID: nil, progress: { _ in })
                r.eq(try Data(contentsOf: url), bytes, "B3 \(status) resumes to exact bytes; 200 truncates")
                r.eq(HFDownloadFixture.requests.first?.value(forHTTPHeaderField: "Range"), "bytes=4-", "B3 resume starts at disk length")
            } catch { r.check(false, "B3 range \(status): \(error)") }
        }
        try! bytes.prefix(4).write(to: url)
        HFDownloadFixture.reset { _, n in n == 0 ? .init(status: 206, headers: ["Content-Range": "bytes 3-7/8"], chunks: [Data(bytes.suffix(5))]) : .init(chunks: [bytes]) }
        do { try await transport().transfer(file: file(), partialURL: url, credentialID: nil, progress: { _ in }); r.eq(try Data(contentsOf: url), bytes, "B3 wrong 206 start discarded and restarted once") }
        catch { r.check(false, "B3 range restart: \(error)") }
        try! bytes.write(to: url)
        HFDownloadFixture.reset { _, _ in .init(status: 416) }
        do { try await transport().transfer(file: file(), partialURL: url, credentialID: nil, progress: { _ in }); r.check(true, "B3 416 exact length and digest accepted") }
        catch { r.check(false, "B3 valid 416: \(error)") }
        try! Data("abcdxxxx".utf8).write(to: url)
        HFDownloadFixture.reset { _, n in n == 0 ? .init(status: 416) : .init(chunks: [bytes]) }
        do { try await transport().transfer(file: file(), partialURL: url, credentialID: nil, progress: { _ in }); r.eq(try Data(contentsOf: url), bytes, "B3 corrupt 416 restarts from zero") }
        catch { r.check(false, "B3 corrupt 416 restart: \(error)") }
        try! bytes.prefix(4).write(to: url)
        HFDownloadFixture.reset { _, _ in .init(status: 206, headers: ["Content-Range": "bytes 4-7/9"], chunks: [Data(bytes.suffix(4))]) }
        await rejects(r, .integrity, at: url, "B3 wrong range total cannot install")
    }
    static func testRenewedResolveURL(_ r: SelfTest.Reporter) async {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }; let url = dir.appendingPathComponent("partial")
        let store = KeychainASRCredentialStore(access: .memory()); try! store.write("synthetic-B3-token", id: "asr.hf.official")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HFDownloadFixture.self]
        let clock = HFDownloadTestClock()
        let t = HFDownloadTransport(configuration: config, credentialStore: store, sleep: { try await clock.sleep($0) })
        HFDownloadFixture.reset { request, n in
            if request.url!.host == "huggingface.co" { return .init(status: 302, headers: ["Location": "https://cdn.invalid/weights?signature=secret-\(n)"]) }
            return n == 1 ? .init(status: 403) : .init(chunks: [bytes])
        }
        do {
            try await t.transfer(file: file(), partialURL: url, credentialID: "asr.hf.official", progress: { _ in })
            let requests = HFDownloadFixture.requests
            r.eq(requests.count, 4, "B3 expired CDN signature refreshes fixed resolve")
            r.check(requests.filter { $0.url?.host == "huggingface.co" }.allSatisfy { $0.url!.path.contains("/resolve/" + HFRepositorySelfTests.commit + "/") }, "B3 resolve refresh retains commit")
            r.check(requests.filter { $0.url?.host == "cdn.invalid" }.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil }, "B3 CDN redirect strips bearer")
            r.eq(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-B3-token", "B3 official origin receives explicit credential")
        } catch { r.check(false, "B3 refreshed resolve: \(error)") }
        HFDownloadFixture.reset { _, _ in .init(chunks: [bytes]) }
        do { try await t.transfer(file: file(endpoint: "https://mirror.invalid"), partialURL: url, credentialID: "asr.hf.official", progress: { _ in }); r.eq(HFDownloadFixture.requests.first?.value(forHTTPHeaderField: "Authorization"), nil, "B3 mirror remains anonymous") }
        catch { r.check(false, "B3 mirror download: \(error)") }
        let journal = HFDownloadJournal(file: file(), writtenBytes: 4, validator: "\"safe-etag\"", credentialID: "asr.hf.official")
        let encoded = String(data: try! JSONEncoder().encode(journal), encoding: .utf8)!
        r.check(!encoded.contains("secret-") && !encoded.contains("synthetic-B3-token") && !encoded.contains("cdn.invalid"), "B3 journal contains no token or signed URL")
        for target in ["http://cdn.invalid/w", "https://user:pass@cdn.invalid/w"] {
            HFDownloadFixture.reset { _, _ in .init(status: 302, headers: ["Location": target]) }
            await rejects(r, .network, at: url, "B3 unsafe redirects rejected")
        }
        HFDownloadFixture.reset { _, _ in .init(status: 302, headers: ["Location": "https://cdn.invalid/again"]) }
        await rejects(r, .network, at: url, "B3 redirect loop bounded")
        r.eq(HFDownloadFixture.requests.count, 6, "B3 at most five redirect hops")
    }
    static func testDigestFormats(_ r: SelfTest.Reporter) {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }; let url = dir.appendingPathComponent("partial")
        for git in [false, true] {
            try! bytes.write(to: url)
            do { try HFFileVerifier.verify(file: file(git: git), at: url); r.check(true, "B3 \(git ? "Git blob SHA1 with header" : "LFS SHA256") verified") }
            catch { r.check(false, "B3 digest format: \(error)") }
            try! Data("abcdxxxx".utf8).write(to: url)
            r.check((try? HFFileVerifier.verify(file: file(git: git), at: url)) == nil, "B3 same-length digest corruption rejected")
        }
        try! Data("abc".utf8).write(to: url)
        r.check((try? HFFileVerifier.verify(file: file(), at: url)) == nil, "B3 truncated file rejected")
        for data in [Data(), Data("<!DOCTYPE html><html>error</html>".utf8), Data("version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 8\n".utf8)] {
            try! data.write(to: url)
            r.check((try? HFFileVerifier.verify(file: file(data), at: url)) == nil, "B3 empty/HTML/LFS pointer cannot pass even matching manifest")
        }
    }
    static func testRetryAndFailures(_ r: SelfTest.Reporter) async {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }; let url = dir.appendingPathComponent("partial")
        let clock = HFDownloadTestClock()
        HFDownloadFixture.reset { _, n in n < 2 ? .init(status: 503) : .init(chunks: [bytes]) }
        do { try await transport(clock: clock).transfer(file: file(), partialURL: url, credentialID: nil, progress: { _ in }); r.eq(clock.delays, [1, 2], "B3 injected retry clock observes 1s/2s") }
        catch { r.check(false, "B3 transient retries: \(error)") }
        for (status, code) in [(403, HFDownloadError.Code.auth), (401, .auth), (404, .network), (503, .network)] {
            HFDownloadFixture.reset { _, _ in .init(status: status, chunks: [Data("<html>error</html>".utf8)]) }
            await rejects(r, code, at: url, "B3 HTTP \(status) classified")
            r.eq(HFDownloadFixture.requests.count, status == 503 ? 3 : 1, "B3 retry only transient status \(status)")
        }
        HFDownloadFixture.reset { _, _ in .init(status: 429, headers: ["Retry-After": "31"]) }
        await rejects(r, .rateLimit, at: url, "B3 long Retry-After pauses immediately")
        r.eq(HFDownloadFixture.requests.count, 1, "B3 long Retry-After does not retry")
        let retryClock = HFDownloadTestClock()
        HFDownloadFixture.reset { _, n in n == 0 ? .init(status: 429, headers: ["Retry-After": "7"]) : .init(chunks: [bytes]) }
        do { try await transport(clock: retryClock).transfer(file: file(), partialURL: url, credentialID: nil, progress: { _ in }); r.eq(retryClock.delays, [7], "B3 bounded Retry-After respected") }
        catch { r.check(false, "B3 rate retry: \(error)") }
        HFDownloadFixture.reset { _, _ in .init(chunks: [Data("abcd".utf8)]) }
        await rejects(r, .integrity, at: url, "B3 truncated body rejected")
        r.check(!FileManager.default.fileExists(atPath: url.path), "B3 bad partial removed")
        try! bytes.prefix(4).write(to: url)
        try! HFDownloadJournal(file: file(), writtenBytes: 4, validator: "\"old\"", credentialID: nil).write(for: url)
        HFDownloadFixture.reset { _, _ in .init(status: 206, headers: ["Content-Range": "bytes 4-7/8", "ETag": "\"new\""], chunks: [Data(bytes.suffix(4))]) }
        await rejects(r, .integrity, at: url, "B3 changed validator rejects mixed bytes")
        HFDownloadFixture.reset { _, _ in .init(chunks: [bytes]) }
        let disk = transport(writer: { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) })
        await rejects(r, .diskFull, at: url, transport: disk, "B3 disk full is distinct failure")
    }
    static func testDiskCreationFailures(_ r: SelfTest.Reporter) async {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("partial")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HFDownloadFixture.self]
        let clock = HFDownloadTestClock(), progress = HFDownloadProgressProbe()
        let creates = OSAllocatedUnfairLock(initialState: 0)
        let disk = HFDownloadTransport(configuration: config, credentialStore: KeychainASRCredentialStore(access: .memory()),
            sleep: { try await clock.sleep($0) }, fileCreator: { _ in
                creates.withLock { $0 += 1 }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
            })
        HFDownloadFixture.reset { _, _ in .init(chunks: [bytes]) }
        do { try await disk.transfer(file: file(), partialURL: url, credentialID: nil, progress: { progress.add($0) }); r.check(false, "B3 create ENOSPC must fail") }
        catch { r.eq((error as? HFDownloadError)?.code, .diskFull, "B3 create ENOSPC is diskFull") }
        r.eq(creates.withLock { $0 }, 1, "B3 create ENOSPC makes one creation attempt")
        r.eq(HFDownloadFixture.requests.count, 1, "B3 create ENOSPC never retries network")
        r.eq(clock.delays, [], "B3 create ENOSPC never backs off")
        r.eq(progress.values, [], "B3 creation failure emits no byte progress")
        r.check(!FileManager.default.fileExists(atPath: url.path), "B3 failed creation leaves no partial")
        r.check(!FileManager.default.fileExists(atPath: HFDownloadJournal.sidecarURL(for: url).path), "B3 failed creation leaves no sidecar")
        let prefix = Data(bytes.prefix(4)); try! prefix.write(to: url)
        let writerClock = HFDownloadTestClock()
        let writing = HFDownloadTransport(configuration: config, credentialStore: KeychainASRCredentialStore(access: .memory()),
            sleep: { try await writerClock.sleep($0) }, chunkWriter: { _, _ in
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
            }, fileCreator: { _ in creates.withLock { $0 += 1 } })
        HFDownloadFixture.reset { _, _ in .init(status: 206, headers: ["Content-Range": "bytes 4-7/8"], chunks: [Data(bytes.suffix(4))]) }
        await rejects(r, .diskFull, at: url, transport: writing, "B3 resumed write ENOSPC is diskFull")
        r.eq(try? Data(contentsOf: url), prefix, "B3 failed resumed write preserves old partial")
        r.eq(creates.withLock { $0 }, 1, "B3 resume never recreates existing partial")
        r.eq(HFDownloadFixture.requests.count, 1, "B3 write ENOSPC never retries network")
        r.eq(writerClock.delays, [], "B3 write ENOSPC never backs off")
    }
    static func testVerified416Cancellation(_ r: SelfTest.Reporter) async {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("partial"); try! bytes.write(to: url)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HFDownloadFixture.self]
        let progress = HFDownloadProgressProbe(), verifications = OSAllocatedUnfairLock(initialState: 0)
        let t = HFDownloadTransport(configuration: config, credentialStore: KeychainASRCredentialStore(access: .memory()),
            fileVerifier: { file, url in
                try HFFileVerifier.verify(file: file, at: url)
                verifications.withLock { $0 += 1 }
                withUnsafeCurrentTask { $0?.cancel() }
            })
        HFDownloadFixture.reset { _, _ in .init(status: 416) }
        let task = Task { try await t.transfer(file: file(), partialURL: url, credentialID: nil, progress: { progress.add($0) }) }
        do { try await task.value; r.check(false, "B3 verified 416 cancellation must throw") }
        catch { r.eq((error as? HFDownloadError)?.code, .cancelled, "B3 verified 416 observes cancellation before success") }
        r.eq(verifications.withLock { $0 }, 1, "B3 416 cancellation follows actual digest verification")
        r.eq(try? Data(contentsOf: url), bytes, "B3 416 cancellation preserves verified partial")
        r.eq(HFDownloadFixture.requests.count, 1, "B3 416 cancellation does not retry")
        r.eq(progress.values, [], "B3 drained 416 emits no progress")
    }
    static func testTransportCancellation(_ r: SelfTest.Reporter) async {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }; let url = dir.appendingPathComponent("partial")
        let data = Data(repeating: 7, count: 1024 * 1024)
        let progress = HFDownloadProgressProbe()
        HFDownloadFixture.reset { _, _ in .init(chunks: (0..<128).map { _ in Data(repeating: 7, count: 8192) }, delay: 0.005) }
        let task = Task { try await transport().transfer(file: file(data), partialURL: url, credentialID: nil, progress: { progress.add($0) }) }
        while progress.values.isEmpty { await Task.yield() }
        task.cancel()
        do { try await task.value; r.check(false, "B3 cancellation must throw") }
        catch { r.eq((error as? HFDownloadError)?.code, .cancelled, "B3 cancellation reports cancelled after drain") }
        let count = progress.values.count; let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
        try? await Task.sleep(for: .milliseconds(40))
        r.eq(progress.values.count, count, "B3 no progress after cancellation returns")
        r.eq(((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0, size, "B3 no disk writes after cancellation returns")
        r.check(size < data.count, "B3 cancelled stream preserves partial")
        // Generate chunks on demand in URLProtocol; production sink writes each callback in <=64KiB pieces.
        let maxWrite = OSAllocatedUnfairLock(initialState: 0)
        HFDownloadFixture.reset { _, _ in .init(chunks: [data]) }
        do {
            try await transport(writer: { handle, chunk in maxWrite.withLock { $0 = max($0, chunk.count) }; try handle.write(contentsOf: chunk) }).transfer(file: file(data), partialURL: url, credentialID: nil, progress: { _ in })
            r.check(maxWrite.withLock { $0 } <= 64 * 1024, "B3 bounded disk chunk writes")
            r.eq(try Data(contentsOf: url), data, "B3 streaming fixture verified payload")
        } catch { r.check(false, "B3 bounded streaming: \(error)") }
    }
}

final class HFDownloadTestClock: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [TimeInterval]())
    var delays: [TimeInterval] { state.withLock { $0 } }
    func sleep(_ delay: TimeInterval) async throws { try Task.checkCancellation(); state.withLock { $0.append(delay) } }
}
final class HFDownloadProgressProbe: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [Int64]())
    var values: [Int64] { state.withLock { $0 } }
    func add(_ value: Int64) { state.withLock { $0.append(value) } }
}
final class HFDownloadFixture: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { var status = 200; var headers: [String: String] = [:]; var chunks: [Data] = []; var delay: TimeInterval = 0 }
    struct State { var requests: [URLRequest] = []; var handler: @Sendable (URLRequest, Int) -> Reply = { _, _ in .init() } }
    static let state = OSAllocatedUnfairLock(initialState: State())
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    static var requests: [URLRequest] { state.withLock { $0.requests } }
    static func reset(_ handler: @escaping @Sendable (URLRequest, Int) -> Reply) { state.withLock { $0 = State(handler: handler) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.withLock { s in let n = s.requests.count; s.requests.append(request); return s.handler(request, n) }
        DispatchQueue.global().async { [self] in
            guard !stopped.withLock({ $0 }) else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!, cacheStoragePolicy: .notAllowed)
            for chunk in reply.chunks {
                if reply.delay > 0 { Thread.sleep(forTimeInterval: reply.delay) }
                guard !stopped.withLock({ $0 }) else { return }
                client?.urlProtocol(self, didLoad: chunk)
            }
            if !stopped.withLock({ $0 }) { client?.urlProtocolDidFinishLoading(self) }
        }
    }
    override func stopLoading() { stopped.withLock { $0 = true } }
}
