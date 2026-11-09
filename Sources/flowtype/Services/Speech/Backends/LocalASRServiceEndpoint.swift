import Foundation
import Darwin

struct LocalASRConnectionDestination: Sendable {
    let url: URL
    let originalHost: String
    let hostHeader: String
}

enum LocalASRServiceEndpoint {
    typealias Resolver = @Sendable (String) throws -> [String]

    static func transcriptionURL(profile: LocalASRServiceProfile) throws -> URL {
        guard profile.protocolKind != .dashScopeRealtime else { throw CloudASRError.unsupportedRealtimeTransport }
        let raw = profile.baseURL
        guard raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.contains("%"), !raw.contains("\\"),
              let components = URLComponents(string: raw),
              ["http", "https"].contains(components.scheme ?? ""),
              let host = components.host, ["localhost", "127.0.0.1", "[::1]"].contains(host),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              let authority = raw.components(separatedBy: "://").last?.components(separatedBy: "/").first,
              authority == host || authority == host + ":" + String(components.port ?? 0)
        else { throw CloudASRError.invalidURL("本机服务仅支持 localhost、127.0.0.1 或 [::1] 的规范 HTTP(S) 地址") }
        var output = components
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        let suffix = profile.protocolKind == .whisperCpp ? "/inference" : "/audio/transcriptions"
        if !path.hasSuffix(suffix) { path += suffix }
        output.path = path
        guard let url = output.url else { throw CloudASRError.invalidURL("无效本机服务地址") }
        return url
    }

    /// DNS is checked once and the checked numeric address becomes the connection URL.
    /// The transport never asks URLSession to resolve localhost again (no rebinding race).
    static func destination(for url: URL, resolver: Resolver = resolve) throws -> LocalASRConnectionDestination {
        guard let host = url.host, ["localhost", "127.0.0.1", "[::1]"].contains(host),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw CloudASRError.invalidURL("无效本机服务地址")
        }
        let addresses = try host == "localhost" ? resolver(host) : [host == "[::1]" ? "::1" : host]
        guard !addresses.isEmpty, addresses.allSatisfy({ $0 == "127.0.0.1" || $0 == "::1" }) else {
            throw CloudASRError.invalidURL("本机服务解析到了非 loopback 地址")
        }
        components.host = addresses[0] == "::1" ? "[::1]" : addresses[0]
        guard let pinned = components.url else { throw CloudASRError.invalidURL("无效本机服务地址") }
        return .init(url: pinned, originalHost: host == "[::1]" ? "::1" : host,
                     hostHeader: host + (url.port.map { ":\($0)" } ?? ""))
    }

    static func resolve(_ host: String) throws -> [String] {
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &head) == 0, let first = head else {
            throw CloudASRError.invalidURL("无法解析本机服务地址")
        }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []; var entry: UnsafeMutablePointer<addrinfo>? = first
        while let current = entry {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            } else { throw CloudASRError.invalidURL("无法解析本机服务地址") }
            entry = current.pointee.ai_next
        }
        return addresses
    }
}
