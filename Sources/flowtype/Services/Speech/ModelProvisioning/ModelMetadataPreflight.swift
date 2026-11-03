import Foundation

/// Checks the config metadata that Hub consumes before a provider may start downloading weights.
/// Redirects are inspected here so no GET, CDN request, or credential forwarding can occur.
final class ModelMetadataPreflight: Sendable {
    private let session: URLSession
    private let injectedSession: Bool

    init(session: URLSession? = nil) {
        injectedSession = session != nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = session?.configuration.protocolClasses
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    func check(repoID: String, endpoint: URL) async throws -> ModelEndpointSummary {
        guard DownloadSource.isValidEndpoint(endpoint),
              repoID.split(separator: "/", omittingEmptySubsequences: false).count == 2,
              repoID.split(separator: "/").allSatisfy({ part in
                  !part.isEmpty && part != "." && part != ".."
                      && part.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).contains($0) }
              }) else {
            throw ModelProvisionError.metadataInvalid(summary: ModelEndpointSummary(url: endpoint))
        }
        var url = endpoint.appendingPathComponent(repoID).appendingPathComponent("resolve/main/config.json")
        var hops = 0
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.httpMethod = "HEAD"
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let response: URLResponse
            do {
                guard injectedSession || ValidationEffects.live.allow(.network) else { throw URLError(.notConnectedToInternet) }
                (_, response) = try await session.data(for: request, delegate: StopRedirects())
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                    throw CancellationError()
                }
                throw ModelProvisionError.network(summary: ModelEndpointSummary(url: url))
            }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw ModelProvisionError.metadataInvalid(summary: ModelEndpointSummary(url: url))
            }
            let summary = ModelEndpointSummary(url: url, httpStatus: http.statusCode)
            if http.statusCode == 429 || (500...599).contains(http.statusCode) {
                throw ModelProvisionError.network(summary: summary)
            }
            // 308 is not compatible with the Hub consumer's 302 location semantics.
            guard [200, 301, 302, 303, 307].contains(http.statusCode) else {
                throw ModelProvisionError.metadataInvalid(summary: summary)
            }
            if http.statusCode != 200,
               let raw = http.value(forHTTPHeaderField: "Location"),
               let relative = URL(string: raw), relative.scheme == nil, relative.host == nil {
                guard hops < 5,
                      let target = URL(string: raw, relativeTo: url)?.absoluteURL,
                      Self.validLocation(target), Self.sameOrigin(url, target) else {
                    throw ModelProvisionError.metadataInvalid(summary: summary)
                }
                hops += 1
                url = target
                continue
            }
            guard http.statusCode == 200 || http.statusCode == 302,
                  Self.nonempty(http.value(forHTTPHeaderField: "X-Repo-Commit")),
                  Self.validEtag(http.value(forHTTPHeaderField: "X-Linked-Etag") ?? http.value(forHTTPHeaderField: "ETag")),
                  let size = Int64(http.value(forHTTPHeaderField: "X-Linked-Size") ?? http.value(forHTTPHeaderField: "Content-Length") ?? ""), size > 0 else {
                throw ModelProvisionError.metadataInvalid(summary: summary)
            }
            if http.statusCode == 302 {
                guard let raw = http.value(forHTTPHeaderField: "Location"),
                      let target = URL(string: raw), Self.validLocation(target) else {
                    throw ModelProvisionError.metadataInvalid(summary: summary)
                }
            }
            return summary
        }
    }

    private static func nonempty(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func validEtag(_ value: String?) -> Bool {
        guard var value else { return false }
        if value.hasPrefix("W/") { value.removeFirst(2) }
        return nonempty(value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
    }

    private static func validLocation(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let host = parts.host, !host.isEmpty else { return false }
        return parts.scheme?.lowercased() == "https"
            || (parts.scheme?.lowercased() == "http" && DownloadSource.isLoopback(host))
    }

    private static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return first.scheme?.lowercased() == second.scheme?.lowercased()
            && first.host?.lowercased() == second.host?.lowercased() && port(first) == port(second)
    }

    private final class StopRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
