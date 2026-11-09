import Foundation
import CryptoKit
import os

/// Resolves small metadata only. No Hub SDK, global token lookup or global model cache.
actor HFRepositoryClient {
    private final class Budget {
        var received = 0
    }
    private struct Context {
        let repository: HFResolvedRepository
        let credentialID: String?
        let budget: Budget
    }
    private let endpoint: URL
    private let session: URLSession
    private let injected: Bool
    private let credentials: any ASRCredentialStore
    private let limits: HFMetadataLimits
    private var contexts: [UUID: Context] = [:]

    init(downloadEndpoint: URL = URL(string: "https://huggingface.co")!, session: URLSession? = nil,
         credentialStore: any ASRCredentialStore = KeychainASRCredentialStore.shared, metadataLimits: HFMetadataLimits = .init()) {
        endpoint = downloadEndpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = session ?? URLSession(configuration: configuration)
        injected = session != nil; credentials = credentialStore; limits = metadataLimits
    }
    deinit { if !injected { session.invalidateAndCancel() } }

    func resolve(_ selection: HFRepositorySelection, credentialID: String? = nil) async throws -> HFResolvedRepository {
        guard Self.validEndpoint(endpoint) else { throw HFRepositoryError.invalidEndpoint }
        guard credentialID == nil || credentialID == "asr.hf.official" else { throw HFRepositoryError.invalidCredential }
        guard let normalized = try? HFRepositoryInput.parse(selection.repoID, revision: selection.requestedRevision,
            subdirectory: selection.subdirectory), normalized.repoID == selection.repoID,
            normalized.requestedRevision == selection.requestedRevision, normalized.subdirectory == selection.subdirectory else {
            throw HFRepositoryError.invalidPath
        }
        if let filePath = selection.referencedFilePath {
            guard HFRepositoryInput.validPath(filePath), HFRepositoryInput.parentDirectory(of: filePath) == selection.subdirectory else {
                throw HFRepositoryError.invalidPath
            }
        }
        let budget = Budget()
        let base = ["api", "models"] + selection.repoID.components(separatedBy: "/")
        let infoURL = try url(segments: base + ["revision", selection.requestedRevision])
        let (infoData, _) = try await fetch(infoURL, credentialID: credentialID, budget: budget)
        struct Info: Decodable { let sha: String; let id: String? }
        guard let info = try? JSONDecoder().decode(Info.self, from: infoData) else { throw HFRepositoryError.invalidMetadata }
        guard Self.hex(info.sha, length: 40) else { throw HFRepositoryError.invalidCommit }
        guard info.id == nil || info.id == selection.repoID else { throw HFRepositoryError.invalidMetadata }
        let commit = info.sha.lowercased()
        var treeURL = try url(segments: base + ["tree", commit] + (selection.subdirectory?.components(separatedBy: "/") ?? []))
        var components = URLComponents(url: treeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "recursive", value: "true"), .init(name: "limit", value: "1000")]
        treeURL = components.url!
        let treePath = components.percentEncodedPath
        var next: URL? = treeURL
        var visited: Set<String> = []
        var cursors: Set<String> = []
        var files: [HFRepositoryFile] = []
        var byPath: [String: HFRepositoryFile] = [:]
        var totalBytes: Int64 = 0
        var pages = 0
        while let pageURL = next {
            guard visited.insert(pageURL.absoluteString).inserted else { throw HFRepositoryError.paginationLoop }
            pages += 1
            guard pages <= 10_000 else { throw HFRepositoryError.pageLimit }
            let (data, response) = try await fetch(pageURL, credentialID: credentialID, budget: budget)
            guard let entries = try? JSONDecoder().decode([TreeEntry].self, from: data) else { throw HFRepositoryError.invalidMetadata }
            guard entries.count <= 1000 else { throw HFRepositoryError.pageLimit }
            for entry in entries {
                guard HFRepositoryInput.validPath(entry.path), selection.subdirectory.map({ entry.path.hasPrefix($0 + "/") }) ?? true else {
                    throw HFRepositoryError.invalidPath
                }
                if entry.type == "directory" { continue }
                guard entry.type == "file", let size = entry.size, size >= 0 else { throw HFRepositoryError.missingFileMetadata }
                let digest: HFFileDigest
                if let lfs = entry.lfs {
                    guard lfs.size == size, Self.hex(lfs.oid, length: 64) else { throw HFRepositoryError.missingFileMetadata }
                    digest = .sha256(lfs.oid.lowercased())
                } else {
                    guard let oid = entry.oid, Self.hex(oid, length: 40) else { throw HFRepositoryError.missingFileMetadata }
                    digest = .gitBlobSHA1(oid.lowercased())
                }
                let file = HFRepositoryFile(remotePath: entry.path, sizeBytes: size, digest: digest)
                if let previous = byPath[entry.path] {
                    guard previous == file else { throw HFRepositoryError.conflictingFile }
                    continue
                }
                guard files.count < 10_000 else { throw HFRepositoryError.fileLimit }
                let sum = totalBytes.addingReportingOverflow(size)
                guard !sum.overflow else { throw HFRepositoryError.totalSizeOverflow }
                totalBytes = sum.partialValue
                byPath[entry.path] = file; files.append(file)
            }
            next = try pagination(response.value(forHTTPHeaderField: "Link"), pageURL: pageURL, treePath: treePath, cursors: &cursors)
        }
        if let filePath = selection.referencedFilePath, byPath[filePath] == nil {
            throw HFRepositoryError.fileNotInRepository
        }
        let licensePath = files.first { ["license", "license.txt", "license.md", "copying"].contains($0.remotePath.components(separatedBy: "/").last!.lowercased()) }?.remotePath
        let licenseURL = try licensePath.map { try url(segments: selection.repoID.components(separatedBy: "/") + ["blob", commit] + $0.components(separatedBy: "/")) }
        let contextID = UUID()
        let repository = HFResolvedRepository(selection: selection, commit: commit, downloadEndpoint: endpoint, files: files,
            licenseURL: licenseURL, resolutionContextID: contextID)
        contexts[contextID] = .init(repository: repository, credentialID: credentialID, budget: budget)
        return repository
    }

    /// Read-only, nonsensitive captured metadata. Reject missing original resolver identities or altered result fields.
    func preflightContext(for repository: HFResolvedRepository) throws -> HFRepositoryPreflightContext {
        guard let id = repository.resolutionContextID, let context = contexts[id],
              context.repository.selection == repository.selection, context.repository.commit == repository.commit,
              context.repository.downloadEndpoint == repository.downloadEndpoint,
              context.repository.files == repository.files, context.repository.licenseURL == repository.licenseURL else {
            throw HFRepositoryError.fileNotInRepository
        }
        return .init(credentialID: context.credentialID, receivedBytes: context.budget.received)
    }

    func readMetadata(file: HFRepositoryFile, repository: HFResolvedRepository) async throws -> Data {
        guard let id = repository.resolutionContextID, let context = contexts[id],
              context.repository.selection == repository.selection, context.repository.commit == repository.commit,
              context.repository.downloadEndpoint == repository.downloadEndpoint,
              context.repository.files == repository.files, repository.files.contains(file) else { throw HFRepositoryError.fileNotInRepository }
        guard file.sizeBytes <= Int64(limits.responseBytes) else { throw HFRepositoryError.byteLimit }
        let metadataURL = try url(segments: repository.selection.repoID.components(separatedBy: "/")
            + ["resolve", repository.commit] + file.remotePath.components(separatedBy: "/"))
        let (data, _) = try await fetch(metadataURL, credentialID: context.credentialID, budget: context.budget)
        guard Int64(data.count) == file.sizeBytes else { throw HFRepositoryError.digestMismatch }
        let actual: String
        let expected: String
        switch file.digest {
        case .sha256(let hash):
            actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(); expected = hash
        case .gitBlobSHA1(let hash):
            var payload = Data("blob \(data.count)\0".utf8); payload.append(data)
            actual = Insecure.SHA1.hash(data: payload).map { String(format: "%02x", $0) }.joined(); expected = hash
        }
        guard actual == expected else { throw HFRepositoryError.digestMismatch }
        return data
    }

    private struct TreeEntry: Decodable {
        struct LFS: Decodable { let oid: String; let size: Int64 }
        let type: String
        let path: String
        let size: Int64?
        let oid: String?
        let lfs: LFS?
    }
    private static func hex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    private static func validEndpoint(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return c.scheme == "https" && c.host?.isEmpty == false && c.user == nil && c.password == nil
            && c.query == nil && c.fragment == nil && ["", "/"].contains(c.percentEncodedPath)
    }
    private func url(segments: [String]) throws -> URL {
        var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        c.percentEncodedPath = "/" + segments.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        guard let result = c.url else { throw HFRepositoryError.invalidPath }
        return result
    }

    private func pagination(_ header: String?, pageURL: URL, treePath: String, cursors: inout Set<String>) throws -> URL? {
        guard let header, !header.isEmpty else { return nil }
        var candidates: [URL] = []
        for part in header.split(separator: ",") {
            let fields = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let target = fields.first, target.hasPrefix("<"), target.hasSuffix(">"), fields.count >= 2 else { throw HFRepositoryError.invalidPagination }
            let relations = fields.dropFirst().filter { $0.hasPrefix("rel=") }.flatMap {
                $0.dropFirst(4).replacingOccurrences(of: "\"", with: "").split(separator: " ").map(String.init)
            }
            if relations.contains("next") {
                guard let next = URL(string: String(target.dropFirst().dropLast()), relativeTo: pageURL)?.absoluteURL else { throw HFRepositoryError.invalidPagination }
                candidates.append(next)
            }
        }
        guard candidates.count <= 1 else { throw HFRepositoryError.invalidPagination }
        guard let next = candidates.first else { return nil }
        guard var c = URLComponents(url: next, resolvingAgainstBaseURL: false), c.scheme == endpoint.scheme,
              c.host == endpoint.host, (c.port ?? 443) == (endpoint.port ?? 443), c.user == nil, c.password == nil,
              c.fragment == nil, c.percentEncodedPath == treePath else { throw HFRepositoryError.invalidPagination }
        let items = c.queryItems ?? []
        guard items.allSatisfy({ ["cursor", "recursive", "limit", "expand"].contains($0.name) }),
              Set(items.map(\.name)).count == items.count,
              let cursor = items.first(where: { $0.name == "cursor" })?.value, !cursor.isEmpty,
              items.first(where: { $0.name == "recursive" }).map({ $0.value == "true" }) ?? true,
              items.first(where: { $0.name == "expand" }).map({ $0.value == "false" }) ?? true,
              items.first(where: { $0.name == "limit" }).map({ (1...1000).contains(Int($0.value ?? "") ?? 0) }) ?? true else { throw HFRepositoryError.invalidPagination }
        guard cursors.insert(cursor).inserted else { throw HFRepositoryError.paginationLoop }
        c.queryItems = items.filter { !["recursive", "limit"].contains($0.name) }
            + [.init(name: "recursive", value: "true"), .init(name: "limit", value: "1000")]
        guard let result = c.url else { throw HFRepositoryError.invalidPagination }
        return result
    }

    private func fetch(_ url: URL, credentialID: String?, budget: Budget) async throws -> (Data, HTTPURLResponse) {
        guard injected || ValidationEffects.live.allow(.network) else { throw HFRepositoryError.network }
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if HFMetadataRedirectPolicy.isOfficial(url), let credentialID {
            guard let token = try credentials.read(id: credentialID), !token.isEmpty,
                  !token.unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 }) else { throw HFRepositoryError.invalidCredential }
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        do {
            let (bytes, raw) = try await session.bytes(for: request, delegate: HFMetadataRedirectPolicy(originalURL: url))
            defer { bytes.task.cancel() }
            guard let response = raw as? HTTPURLResponse else { throw HFRepositoryError.invalidMetadata }
            switch response.statusCode {
            case 200: break
            case 401: throw HFRepositoryError.unauthorized
            case 403: throw HFRepositoryError.forbidden
            case 404: throw HFRepositoryError.notFound
            default: throw HFRepositoryError.httpStatus(response.statusCode)
            }
            guard response.expectedContentLength <= Int64(limits.responseBytes),
                  response.expectedContentLength <= Int64(limits.preflightBytes - budget.received) else { throw HFRepositoryError.byteLimit }
            var data = Data()
            data.reserveCapacity(min(limits.responseBytes, max(0, Int(response.expectedContentLength))))
            for try await byte in bytes {
                guard data.count < limits.responseBytes, budget.received < limits.preflightBytes else { throw HFRepositoryError.byteLimit }
                budget.received += 1; data.append(byte)
            }
            try Task.checkCancellation()
            return (data, response)
        } catch {
            let nsError = error as NSError
            if error is CancellationError || Task.isCancelled || nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { throw CancellationError() }
            if let safe = error as? HFRepositoryError { throw safe }
            throw HFRepositoryError.network
        }
    }
}

/// Separate from audio upload's deny-all policy: HTTPS CDN hops are allowed, bearer scope only narrows.
final class HFMetadataRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    private struct State { var hops = 0; var bearerAllowed: Bool }
    private let state: OSAllocatedUnfairLock<State>
    init(originalURL: URL = URL(string: "https://huggingface.co")!) {
        state = .init(initialState: State(bearerAllowed: Self.isOfficial(originalURL)))
    }
    static func isOfficial(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "huggingface.co" && (url.port ?? 443) == 443 && url.user == nil && url.password == nil
    }
    func redirectedRequest(_ request: URLRequest) -> URLRequest? {
        state.withLock { state in
            guard state.hops < 5, let url = request.url, url.scheme == "https", url.host?.isEmpty == false,
                  url.user == nil, url.password == nil, url.fragment == nil else { return nil }
            state.hops += 1
            state.bearerAllowed = state.bearerAllowed && Self.isOfficial(url)
            var forwarded = request
            if !state.bearerAllowed { forwarded.setValue(nil, forHTTPHeaderField: "Authorization") }
            forwarded.setValue(nil, forHTTPHeaderField: "Cookie")
            return forwarded
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(redirectedRequest(request))
    }
}
