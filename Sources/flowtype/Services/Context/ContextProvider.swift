import Foundation

/// 前台上下文的一次采集结果。逐项可为 nil（采集失败或不可用不阻断录音）。
struct ForegroundContext: Sendable, Equatable {
    let appName: String?
    let elementText: String?
    let url: String?
    let selectedText: String?
}

/// 平台能力：采集前台上下文。macOS 实现见 `AXContextProvider`。
protocol ContextProvider: Sendable {
    func collect() async -> ForegroundContext?
}

/// 把采集结果压成一段有界上下文文本（先脱敏，再截断）。
/// 优先级：焦点元素文本 > 选中文本 > 网页 URL。
func buildContextText(_ ctx: ForegroundContext?, maxChars: Int = 1200) -> String? {
    guard let ctx else { return nil }
    var parts: [String] = []
    if let t = ctx.elementText?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { parts.append(t) }
    if let s = ctx.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { parts.append(s) }
    if let u = ctx.url?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty { parts.append(u) }
    guard !parts.isEmpty else { return nil }
    let joined = parts.joined(separator: "\n")
    return String(redactContextSecrets(joined).prefix(maxChars))
}

/// 去除上下文里可能出现的凭据形态，避免随云端请求外泄。
func redactContextSecrets(_ text: String) -> String {
    var out = text
    for pattern in [#"sk-[A-Za-z0-9_-]{8,}"#, #"sf-[A-Za-z0-9_-]{8,}"#, #"Bearer\s+[A-Za-z0-9._-]{8,}"#] {
        if let re = try? NSRegularExpression(pattern: pattern) {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                              withTemplate: "[REDACTED]")
        }
    }
    return out
}
