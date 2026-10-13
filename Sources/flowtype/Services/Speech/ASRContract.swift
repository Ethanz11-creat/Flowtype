import Foundation

/// 运行位置 — 决定隐私文案与路由过滤。
enum ProviderLocation: String, Sendable, Codable {
    case onDevice
    case cloud
}

/// Provider 能力声明。取代所有运行时的 `as? QwenASRProvider` 能力判断。
struct ASRCapabilities: Sendable, Equatable {
    let supportsLanguageHint: Bool
    let supportsContextHint: Bool
    let requiresNetwork: Bool
    let location: ProviderLocation
    let maxAudioDuration: TimeInterval?
    let estimatedWarmLatencyMs: Int
}

/// 一次识别所需的全部上下文，打包成一个值类型。
struct ASRContext: Sendable, Equatable {
    let phrases: [String]      // 用户词典热词
    let foreground: String?    // 前台上下文文本，nil 表示未采集/不可用
}

/// 一次识别请求。`samples` 仍是 16kHz 单声道 Float32 裸样本（字节契约不变）。
struct ASRRequest: Sendable {
    let samples: [Float]
    let sampleRate: Int
    let language: String?      // nil = 自动
    let context: ASRContext?
    let timeout: TimeInterval
}

/// 一次识别结果。
struct ASRResult: Sendable, Equatable {
    let text: String
    let providerID: String
    let latencyMs: Int
}

/// 把词典热词与前台上下文拼成一段 provider 提示。
/// 热词在前（信号更强），前台文本截断到 `maxForegroundChars` 避免 prompt 膨胀。
func composeProviderContext(
    _ context: ASRContext?,
    maxCount: Int = 50,
    maxChars: Int = 300,
    maxForegroundChars: Int = 1200
) -> String? {
    guard let context else { return nil }
    var parts: [String] = []
    if let phrasePart = composeASRContext(context.phrases, maxCount: maxCount, maxChars: maxChars) {
        parts.append(phrasePart)
    }
    if let fg = context.foreground?.trimmingCharacters(in: .whitespacesAndNewlines), !fg.isEmpty {
        parts.append(String(fg.prefix(maxForegroundChars)))
    }
    return parts.isEmpty ? nil : parts.joined(separator: "\n")
}
