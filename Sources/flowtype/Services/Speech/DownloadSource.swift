import Foundation

/// Which Hugging Face endpoint to download the model from. `auto` uses the mirror in China.
enum DownloadSource: Codable, Equatable, Hashable {
    case auto
    case official
    case mirror
    case custom(String)

    var displayName: String {
        switch self {
        case .auto: return "自动"
        case .official: return "官方"
        case .mirror: return "镜像"
        case .custom(let raw):
            guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  Self.isValidEndpoint(url), let host = url.host else { return "自定义" }
            let identity = host + (url.port.map { ":\($0)" } ?? "")
            return "自定义 (\(identity))"
        }
    }

    static let mirrorEndpoint = "https://hf-mirror.com"

    /// The HF endpoint to set as HF_ENDPOINT, or nil to use the default (official huggingface.co).
    func endpoint(isChina: Bool) -> String? {
        switch self {
        case .auto:            return isChina ? Self.mirrorEndpoint : nil
        case .official:        return nil
        case .mirror:          return Self.mirrorEndpoint
        case .custom(let url):
            let t = url.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
    }

    /// The validated endpoint used by provisioning. Invalid custom values must never silently
    /// become the official endpoint; callers surface a deterministic metadata error instead.
    func validatedEndpoint(isChina: Bool) throws -> URL {
        let raw: String
        if case .custom(let value) = self {
            raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            raw = endpoint(isChina: isChina) ?? "https://huggingface.co"
        }
        guard let url = URL(string: raw), Self.isValidEndpoint(url) else {
            throw ModelProvisionError.metadataInvalid()
        }
        return url
    }

    static func isValidEndpoint(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return false }
        return parts.scheme?.lowercased() == "https"
            || (parts.scheme?.lowercased() == "http" && isLoopback(host))
    }

    static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
    }

    /// Rough "is this machine in China" heuristic (region only; user can always override).
    static func systemIsLikelyChina() -> Bool {
        if #available(macOS 13, *) { return Locale.current.region?.identifier == "CN" }
        return (Locale.current.regionCode ?? "") == "CN"
    }
}
