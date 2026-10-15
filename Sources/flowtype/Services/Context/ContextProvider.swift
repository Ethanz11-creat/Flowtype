import Foundation

/// 前台上下文的一次采集结果。逐项可为 nil（采集失败或不可用不阻断录音）。
struct ForegroundContext: Sendable, Equatable, Codable {
    let appName: String?
    let elementText: String?
    let url: String?
    let selectedText: String?
}

/// 平台能力：采集前台上下文。macOS 实现见 `AXContextProvider`。
protocol ContextProvider: Sendable {
    func collect() async -> ForegroundContext?
}

/// Redact each field before allocating the shared character budget. Selection and
/// app identity must survive even when an editor exposes a very large value.
func boundedForegroundContext(_ context: ForegroundContext?, maxChars: Int = 1200) -> ForegroundContext? {
    guard let context else { return nil }
    var remaining = max(0, maxChars)
    func take(_ value: String?) -> String? {
        guard remaining > 0, let value else { return nil }
        let clean = redactContextSecrets(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let result = String(clean.prefix(remaining))
        // Reserve the separator used by the compatible text projection.
        remaining = max(0, remaining - result.count - 1)
        return result
    }
    let selected = take(context.selectedText)
    let app = take(context.appName)
    let element = take(context.elementText)
    let url = take(context.url)
    guard selected != nil || app != nil || element != nil || url != nil else { return nil }
    return ForegroundContext(appName: app, elementText: element, url: url, selectedText: selected)
}

func buildContextText(_ ctx: ForegroundContext?, maxChars: Int = 1200) -> String? {
    guard let context = boundedForegroundContext(ctx, maxChars: maxChars) else { return nil }
    return [context.selectedText, context.appName, context.elementText, context.url]
        .compactMap { $0 }.joined(separator: "\n")
}

/// Synchronous producers (including AX) run outside the main actor. The deadline
/// never joins one that is blocked in a platform call; late results have no sink.
func collectBoundedForegroundContext(timeout: TimeInterval = 0.5,
    producer: @escaping @Sendable () -> ForegroundContext?) async -> ForegroundContext? {
    try? await withAsyncDeadline(seconds: timeout) {
        let worker = Task.detached(priority: .utility) { () -> ForegroundContext? in
            guard !Task.isCancelled else { return nil }
            let result = producer()
            guard !Task.isCancelled else { return nil }
            return boundedForegroundContext(result)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

/// Shared production guard, injectable without touching real AX/user applications.
/// Metadata for the element AND parent is evaluated before any text closure runs.
func collectSafeElementContext<Node>(element: Node,
    parent: (Node) -> Node?, secure: (Node) -> Bool,
    selected: (Node) -> String?, text: (Node) -> String?) -> (selected: String?, text: String?)? {
    let parentElement = parent(element)
    guard !secure(element), parentElement.map({ !secure($0) }) ?? true else { return nil }
    let selection = selected(element)
    if let value = text(element) { return (selection, value) }
    guard let parentElement else { return (selection, nil) }
    // A parent fallback is also guarded against its own secure parent.
    guard parent(parentElement).map({ !secure($0) }) ?? true else { return (selection, nil) }
    return (selection, text(parentElement))
}

/// Selection ranges from AX use UTF-16 offsets, as does NSString.
func cursorNearContextText(_ value: String, selection: NSRange?, maxChars: Int = 1200) -> String {
    let safeValue = redactContextSecrets(value, preservingUTF16Offsets: true)
    let source = safeValue as NSString
    guard let selection, selection.location != NSNotFound,
          selection.location >= 0, selection.location <= source.length else {
        return String(safeValue.prefix(max(0, maxChars)))
    }
    let start = max(0, selection.location - max(0, maxChars) / 2)
    let range = NSRange(location: start, length: min(max(0, maxChars), source.length - start))
    // Avoid slicing a surrogate pair or a composed character.
    return String(source.substring(with: source.rangeOfComposedCharacterSequences(for: range)).prefix(max(0, maxChars)))
}

/// 焦点处于安全输入（密码）字段时，绝不可采集其值。
/// macOS 的安全输入字段以 subrole（AXSecureTextField）标识；防御性地也接受 role 命中。
func isSecureFocus(role: String?, subrole: String?) -> Bool {
    if subrole == "AXSecureTextField" { return true }
    if role == "AXSecureTextField" { return true }
    return false
}

/// 去除上下文里可能出现的凭据形态，避免随云端请求外泄。
///
/// 模式必须带左侧词边界：上下文文本会被喂进 ASR 提示词来偏向技术词，若 `sk-` 不带边界，
/// 普通标识符会被误伤（`disk-partitioning` → `di[REDACTED]`），反而损害识别准确率。
/// `Bearer` 则要求 token 至少 20 个字符，避免吞掉 `Bearer authentication` 这类正常文字。
func redactContextSecrets(_ text: String, preservingUTF16Offsets: Bool = false) -> String {
    var out = text
    let patterns = [
        #"(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{8,}"#,
        #"(?<![A-Za-z0-9])sf-[A-Za-z0-9_-]{8,}"#,
        #"Bearer\s+[A-Za-z0-9._~+/-]{20,}"#,
    ]
    for pattern in patterns {
        if let re = try? NSRegularExpression(pattern: pattern) {
            if preservingUTF16Offsets {
                // AX selections refer to the original UTF-16 source. Mask every
                // complete credential span before a window can lose its prefix.
                let masked = NSMutableString(string: out)
                for match in re.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
                    masked.replaceCharacters(in: match.range, with: String(repeating: "•", count: match.range.length))
                }
                out = masked as String
            } else {
                out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                  withTemplate: "[REDACTED]")
            }
        }
    }
    return out
}
