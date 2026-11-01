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
}

/// provider 身份的唯一事实来源 —— 避免字符串字面量在多处漂移。
enum ASRProviderID {
    static let qwenLocal = "qwen-local"
    static let local = qwenLocal
    static let cloud = "cloud-asr"
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
    /// Immutable capture-start provider snapshot. Batch providers must use this
    /// value instead of reading mutable settings while a request is in flight.
    let cloudConfiguration: CloudASRRequestConfiguration?

    init(samples: [Float], sampleRate: Int, language: String?, context: ASRContext?,
         timeout: TimeInterval, cloudConfiguration: CloudASRRequestConfiguration? = nil) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.language = language
        self.context = context
        self.timeout = timeout
        self.cloudConfiguration = cloudConfiguration
    }
}

/// Batch HTTP request identity captured at capture start. It deliberately
/// contains the protocol discriminator so a realtime WSS profile can never be
/// accidentally serialized as an HTTP multipart request.
struct CloudASRRequestConfiguration: Sendable, Equatable {
    let provider: CloudASRProviderConfig
    let apiKey: String
    let sendContext: Bool
}

/// 一次识别结果。
struct ASRResult: Sendable, Equatable {
    let text: String
    let providerID: String
    let latencyMs: Int
}

/// One recording owns one realtime session. Audio remains 16kHz mono Float32;
/// providers perform their own wire encoding. Finish drains accepted audio and
/// waits for the server's terminal result; cancel must unblock pending waits.
protocol RealtimeASRSession: Sendable {
    func start() async throws
    func append(samples: [Float]) async throws
    func finish() async throws -> ASRResult
    func cancel() async
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

enum SpeechProviderError: Error {
    case transcriptionFailed(String)
    case networkError(Error)
    case notAvailable
    case permissionDenied
}

/// 把一次 provider 失败归类成可聚合的降级原因（不含内容）。
func fallbackReason(for error: Error) -> String {
    if error is AsyncDeadlineError { return "timeout" }
    if let realtime = error as? DashScopeRealtimeError,
       realtime == .startTimeout || realtime == .finalTimeout { return "timeout" }
    if let cloud = error as? CloudASRError {
        switch cloud {
        case .timeout: return "timeout"
        case .networkError: return "network"
        case .noAPIKey, .noModel, .noActiveProvider: return "unavailable"
        case .invalidResponse, .apiError, .invalidURL, .audioEncodingFailed, .unsupportedRealtimeTransport: return "error"
        }
    }
    if let speech = error as? SpeechProviderError {
        switch speech {
        case .notAvailable: return "unavailable"
        case .transcriptionFailed, .networkError, .permissionDenied: return "error"
        }
    }
    if (error as NSError).domain == NSURLErrorDomain { return "network" }
    return "error"
}
