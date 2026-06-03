import Foundation

/// Which Hugging Face endpoint to download the model from. `auto` uses the mirror in China.
enum DownloadSource: Codable, Equatable {
    case auto
    case official
    case mirror
    case custom(String)

    var displayName: String {
        switch self {
        case .auto: return "自动"
        case .official: return "官方"
        case .mirror: return "镜像"
        case .custom: return "自定义"
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

    /// Rough "is this machine in China" heuristic (region only; user can always override).
    static func systemIsLikelyChina() -> Bool {
        if #available(macOS 13, *) { return Locale.current.region?.identifier == "CN" }
        return (Locale.current.regionCode ?? "") == "CN"
    }
}
