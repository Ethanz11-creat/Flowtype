import Foundation
import Security

/// Task-owned policy: rejects every redirect and validates localhost TLS against
/// the configured DNS name while the socket is pinned to a numeric loopback URL.
final class ASRHTTPTaskPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    let originalHost: String?
    private let trustEvaluator: @Sendable (SecTrust) -> Bool
    init(originalHost: String?, trustEvaluator: @escaping @Sendable (SecTrust) -> Bool = ASRHTTPTaskPolicy.evaluateLocalhostTrust) {
        self.originalHost = originalHost; self.trustEvaluator = trustEvaluator
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard originalHost == "localhost" else { completionHandler(.performDefaultHandling, nil); return }
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let url = task.originalRequest?.url, url.scheme == "https",
              ["127.0.0.1", "[::1]"].contains(url.host ?? ""),
              challenge.protectionSpace.host.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "") == url.host?.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: ""),
              challenge.protectionSpace.port == (url.port ?? 443),
              let trust = challenge.protectionSpace.serverTrust,
              trustEvaluator(trust)
        else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    static func evaluateLocalhostTrust(_ trust: SecTrust) -> Bool {
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, "localhost" as CFString)) == errSecSuccess else { return false }
        // Standard anchors remain in force; self-signed certificates are not implicitly trusted.
        return SecTrustEvaluateWithError(trust, nil)
    }
}

final class ASRHTTPTransport: Sendable {
    static let responseLimit = 2 * 1024 * 1024
    private let session: URLSession
    private let injected: Bool

    init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: Self.loopbackConfiguration())
        injected = session != nil
    }

    deinit { if !injected { session.invalidateAndCancel() } }

    static func loopbackConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return configuration
    }

    func transcribe(_ request: URLRequest, originalHost: String?) async throws -> String {
        guard injected || ValidationEffects.live.allow(.network) else { throw CloudASRError.networkError(URLError(.notConnectedToInternet)) }
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request, delegate: ASRHTTPTaskPolicy(originalHost: originalHost))
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw CloudASRError.invalidResponse }
            guard (200...299).contains(response.statusCode) else {
                throw CloudASRError.apiError(statusCode: response.statusCode, message: "")
            }
            guard response.expectedContentLength <= Int64(Self.responseLimit) else { throw CloudASRError.invalidResponse }
            var data = Data(); data.reserveCapacity(min(Self.responseLimit, max(0, Int(response.expectedContentLength))))
            for try await byte in bytes {
                guard data.count < Self.responseLimit else { throw CloudASRError.invalidResponse }
                data.append(byte)
            }
            try Task.checkCancellation()
            struct Response: Decodable { let text: String }
            guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
                  !decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudASRError.invalidResponse }
            return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            let underlying = error as NSError
            if error is CancellationError || Task.isCancelled || underlying.domain == NSURLErrorDomain && underlying.code == NSURLErrorCancelled { throw CancellationError() }
            if let error = error as? CloudASRError { throw error }
            if underlying.domain == NSURLErrorDomain && underlying.code == NSURLErrorTimedOut { throw CloudASRError.timeout }
            throw CloudASRError.networkError(NSError(domain: NSURLErrorDomain, code: underlying.domain == NSURLErrorDomain ? underlying.code : NSURLErrorUnknown))
        }
    }
}
