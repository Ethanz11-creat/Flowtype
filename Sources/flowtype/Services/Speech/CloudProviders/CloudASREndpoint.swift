import Foundation

/// Pure validation. Invalid input is rejected in full, never stripped of sensitive components.
enum CloudASREndpoint {
    static func transcriptionURL(_ input: String) throws -> URL {
        var parts = try validatedComponents(input, scheme: "https")
        // Keep escaped proxy path components intact (e.g. a tenant containing %2F).
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/audio/transcriptions") { path += "/audio/transcriptions" }
        parts.percentEncodedPath = path
        guard let url = parts.url else { throw CloudASRError.invalidURL("无效的 HTTPS 转写地址") }
        return url
    }

    static func validateRealtimeURL(_ input: String) throws -> URL {
        let parts = try validatedComponents(input, scheme: "wss")
        guard let url = parts.url else { throw CloudASRError.invalidURL("无效的 WSS 实时识别地址") }
        return url
    }

    private static func validatedComponents(_ input: String, scheme: String) throws -> URLComponents {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\\" }),
              let decoded = value.removingPercentEncoding,
              !decoded.contains(where: { $0 == "{" || $0 == "}" || $0.isWhitespace || $0.isNewline }),
              let parts = URLComponents(string: value), parts.scheme?.lowercased() == scheme,
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.url != nil else {
            throw CloudASRError.invalidURL("地址必须使用 \(scheme.uppercased())，包含有效主机且不能包含账号、密码、查询参数、片段或占位符")
        }
        // Foundation accepts an empty port (host:); require an actual valid port when specified.
        let authority = value.components(separatedBy: "://").dropFirst().joined(separator: "://")
            .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard !authority.hasSuffix(":"), parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw CloudASRError.invalidURL("地址端口必须在 1–65535 范围内")
        }
        return parts
    }
}
