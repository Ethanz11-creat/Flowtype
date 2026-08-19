import Foundation

enum LLMError: Error {
    case invalidResponse
    case apiError(String)
    case streamDecodingError
    case networkError(Error)
    case timeout

    var userFriendlyMessage: String {
        switch self {
        case .invalidResponse:
            return "无效响应格式"
        case .apiError(let msg):
            if msg.contains("401") || msg.contains("403") {
                return "API Key 无效或已过期"
            } else if msg.contains("404") {
                return "模型 ID 不存在"
            } else if msg.contains("500") || msg.contains("502") || msg.contains("503") {
                return "服务商接口异常"
            } else if msg.contains("超时") || msg.contains("timeout") {
                return "连接超时"
            }
            return msg
        case .streamDecodingError:
            return "流数据解码失败"
        case .networkError(let error):
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                switch nsError.code {
                case NSURLErrorTimedOut, NSURLErrorDNSLookupFailed:
                    return "连接超时，请检查网络或 Base URL"
                case NSURLErrorCannotFindHost:
                    return "无法解析 Base URL"
                case NSURLErrorNotConnectedToInternet:
                    return "网络未连接"
                default:
                    break
                }
            }
            return "网络错误: \(error.localizedDescription)"
        case .timeout:
            return "请求超时"
        }
    }
}

actor LLMService {

    init() {}

    static func shouldPolish(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return nil }

        let fillerPattern = "^[嗯啊哦呃哼哈呀哪那个这个那么就是对吧然后然后]+$"
        if let regex = try? NSRegularExpression(pattern: fillerPattern),
           regex.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count)) != nil {
            return nil
        }

        return trimmed
    }

    // MARK: - Public API

    /// `config` MUST be a snapshot the caller read on the main actor — do NOT read
    /// ConfigurationStore.shared.current from this actor (it's a @Published value mutated on main → data race).
    func polishText(_ text: String, systemPrompt: String? = nil, config: Configuration) -> AsyncThrowingStream<String, Error> {
        let prompt = systemPrompt ?? config.systemPrompt
        let maxTokens = config.maxTokens
        return makeStream(text: text, systemPrompt: prompt, maxTokens: maxTokens, timeoutSeconds: 30, config: config)
    }

    @MainActor
    static func composeSystemPrompt(fallback: String) -> String {
        let activePack = StylePackStore.shared.activePack
        var prompt = activePack?.prompt ?? fallback

        let phrases = DictionaryStore.shared.enabledPhrases
        if !phrases.isEmpty {
            // Security: sanitize phrases before injecting into prompt
            let sanitized = phrases.compactMap { phrase -> String? in
                let trimmed = phrase.trimmingCharacters(in: .whitespaces)
                guard trimmed.count <= 100 else { return nil }
                let lower = trimmed.lowercased()
                let forbidden = ["ignore", "</system>", "```", "<script", "http://", "https://"]
                for pattern in forbidden {
                    if lower.contains(pattern) { return nil }
                }
                return trimmed
            }
            if !sanitized.isEmpty {
                let hotwordBlock = "\n\n以下是用户的专有名词词典，请在输出中优先使用这些正确写法：\n" + sanitized.joined(separator: "、")
                if prompt.contains("{{HOTWORDS}}") {
                    prompt = prompt.replacingOccurrences(of: "{{HOTWORDS}}", with: hotwordBlock)
                } else {
                    prompt += hotwordBlock
                }
            } else {
                prompt = prompt.replacingOccurrences(of: "{{HOTWORDS}}", with: "")
            }
        } else {
            prompt = prompt.replacingOccurrences(of: "{{HOTWORDS}}", with: "")
        }

        return prompt
    }

    // MARK: - Provider Resolution

    /// Resolve providers + keys from a config SNAPSHOT (no shared-state read off the actor — see polishText).
    private func resolveProviderChain(config: Configuration) -> [(provider: LLMProvider, apiKey: String)] {
        func key(_ id: UUID) -> String? {
            let k = config.providerAPIKeys[id.uuidString]
            return (k?.isEmpty == false) ? k : nil
        }
        func isValid(_ provider: LLMProvider) -> Bool {
            let model = provider.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseURL = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            return !model.isEmpty && !baseURL.isEmpty
        }
        let providers = config.llmProviders
        var result: [(provider: LLMProvider, apiKey: String)] = []
        if let active = providers.first(where: { $0.isActive && isValid($0) }), let apiKey = key(active.id) {
            result.append((active, apiKey))
        }
        for provider in providers where !provider.isActive && isValid(provider) {
            if let apiKey = key(provider.id) { result.append((provider, apiKey)) }
        }
        return result
    }

    // MARK: - Connection Test

    /// `overrideKey` lets the editor test the key currently typed in the form (before it's saved) —
    /// otherwise a brand-new provider would always test against an empty stored key.
    func testConnection(provider: LLMProvider, apiKey overrideKey: String? = nil) async -> Result<String, LLMError> {
        let apiKey = (overrideKey?.isEmpty == false)
            ? overrideKey!
            : (ConfigurationStore.shared.loadProviderAPIKey(provider.id) ?? "")
        guard !apiKey.isEmpty else {
            return .failure(LLMError.apiError("请在设置中配置 LLM API Key"))
        }

        guard let url = validatedAPIURL(baseURL: provider.baseURL) else {
            return .failure(LLMError.apiError("Invalid Base URL"))
        }

        let body: [String: Any] = [
            "model": provider.model,
            "messages": [
                ["role": "user", "content": "hello"]
            ],
            "stream": false,
            "temperature": 0.3,
            "max_tokens": 5
        ]

        do {
            let requestBody = try JSONSerialization.data(withJSONObject: body)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = requestBody

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(LLMError.apiError("Non-HTTP response"))
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let statusCode = httpResponse.statusCode
                let errorBody = String(data: data, encoding: .utf8) ?? "(unable to decode error body)"
                let sanitizedBody = sanitizeErrorBody(errorBody)
                AppLogger.log("[LLMService] testConnection HTTP \(statusCode): \(sanitizedBody)")
                return .failure(LLMError.apiError("HTTP \(statusCode): \(sanitizedBody)"))
            }

            return .success("连接成功")
        } catch {
            AppLogger.log("[LLMService] testConnection error: \(error)")
            return .failure(LLMError.networkError(error))
        }
    }

    // MARK: - Shared streaming infrastructure

    private func makeStream(
        text: String,
        systemPrompt: String,
        maxTokens: Int,
        timeoutSeconds: UInt64,
        config: Configuration
    ) -> AsyncThrowingStream<String, Error> {
        let temperature = config.temperature

        return AsyncThrowingStream { continuation in
            Task {
                guard let validatedText = Self.shouldPolish(text) else {
                    continuation.finish()
                    return
                }
                if systemPrompt.isEmpty {
                    AppLogger.log("[LLMService] WARNING: systemPrompt is empty, skipping")
                    continuation.finish()
                    return
                }

                let chain = self.resolveProviderChain(config: config)
                guard !chain.isEmpty else {
                    continuation.finish(throwing: LLMError.apiError("请在设置中配置 LLM API Key"))
                    return
                }

                var lastError: Error?
                // Latency cap: each attempt may wait up to timeoutSeconds, so trying more
                // than 2 providers would leave the user staring at the capsule for minutes.
                let maxAttempts = min(chain.count, 2)
                if chain.count > maxAttempts {
                    AppLogger.log("[LLMService] \(chain.count - maxAttempts) provider(s) beyond the 2-attempt latency cap will not be tried")
                }
                let delivery = DeliveryState()
                for i in 0..<maxAttempts {
                    let resolved = chain[i]
                    do {
                        AppLogger.log("[LLMService] Trying provider \(resolved.provider.name) (attempt \(i+1)/\(maxAttempts))")
                        try await Self.streamRequest(
                            apiKey: resolved.apiKey,
                            baseURL: resolved.provider.baseURL,
                            model: resolved.provider.model,
                            temperature: temperature,
                            systemPrompt: systemPrompt,
                            userMessage: validatedText,
                            maxTokens: maxTokens,
                            timeoutSeconds: timeoutSeconds,
                            continuation: continuation,
                            delivery: delivery
                        )
                        return // Success — streamRequest finished normally
                    } catch {
                        lastError = error
                        AppLogger.log("[LLMService] Provider \(resolved.provider.name) failed: \(error)")
                        guard Self.shouldFailover(hasYielded: delivery.hasYielded, attemptIndex: i, maxAttempts: maxAttempts) else {
                            if delivery.hasYielded {
                                AppLogger.log("[LLMService] Content already delivered — not failing over (a retry would duplicate text)")
                            }
                            break
                        }
                        AppLogger.log("[LLMService] Falling back to next provider...")
                    }
                }

                // All attempts exhausted
                if let lastError = lastError {
                    continuation.finish(throwing: lastError)
                } else {
                    continuation.finish(throwing: LLMError.apiError("所有 Provider 均不可用"))
                }
            }
        }
    }

    /// Tracks delivery progress across the streaming task, the failover loop and the
    /// inactivity watchdog. Once content has reached the consumer, failing over would
    /// replay the full response and duplicate text — `hasYielded` gates that decision.
    final class DeliveryState: @unchecked Sendable {
        private let lock = NSLock()
        private var yielded = false
        private var lastActivity = Date()

        var hasYielded: Bool {
            lock.lock(); defer { lock.unlock() }
            return yielded
        }
        func markYielded() {
            lock.lock(); defer { lock.unlock() }
            yielded = true
            lastActivity = Date()
        }
        func touch() {
            lock.lock(); defer { lock.unlock() }
            lastActivity = Date()
        }
        func idleSeconds(now: Date = Date()) -> TimeInterval {
            lock.lock(); defer { lock.unlock() }
            return now.timeIntervalSince(lastActivity)
        }
    }

    /// A failed attempt may fall back to the next provider only while nothing has been
    /// delivered downstream yet.
    nonisolated static func shouldFailover(hasYielded: Bool, attemptIndex: Int, maxAttempts: Int) -> Bool {
        !hasYielded && attemptIndex < maxAttempts - 1
    }

    /// Watchdog verdict. Idle limit catches stalled streams. Before the first content
    /// token there is ALSO a hard cap (3× limit): a gateway that keeps the connection
    /// alive with heartbeats but never produces a token must not stall polish forever —
    /// it has to fail while failover (gated on hasYielded == false) is still reachable.
    /// After the first token, healthy slow streams run uncapped; idle detection suffices.
    nonisolated static func watchdogShouldTimeout(idleSeconds: TimeInterval, attemptElapsed: TimeInterval, hasYielded: Bool, limit: TimeInterval) -> Bool {
        if idleSeconds > limit { return true }
        if !hasYielded && attemptElapsed > limit * 3 { return true }
        return false
    }

    private static func streamRequest(
        apiKey: String,
        baseURL: String,
        model: String,
        temperature: Double,
        systemPrompt: String,
        userMessage: String,
        maxTokens: Int,
        timeoutSeconds: UInt64,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
        delivery: DeliveryState
    ) async throws {
        guard let url = validatedAPIURL(baseURL: baseURL) else {
            throw LLMError.apiError("Invalid Base URL")
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ],
            "stream": true,
            "temperature": temperature,
            "max_tokens": maxTokens
        ]

        let requestBody = try JSONSerialization.data(withJSONObject: body)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = TimeInterval(timeoutSeconds)
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = requestBody

                let (bytes, response) = try await URLSession.shared.bytes(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw LLMError.apiError("Non-HTTP response")
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    let statusCode = httpResponse.statusCode
                    var errorBody = ""
                    do {
                        for try await line in bytes.lines.prefix(20) {
                            errorBody += line + "\n"
                        }
                    } catch {
                        errorBody = "(unable to read error body)"
                    }
                    let sanitizedBody = sanitizeErrorBody(errorBody)
                    AppLogger.log("[LLMService] HTTP \(statusCode): \(sanitizedBody)")
                    throw LLMError.apiError("HTTP \(statusCode): \(sanitizedBody)")
                }

                var yieldedAny = false
                var decodeFailures = 0
                for try await line in bytes.lines {
                    delivery.touch() // any inbound frame counts as liveness for the watchdog
                    switch parseSSELine(line, decodeFailures: &decodeFailures) {
                    case .content(let content):
                        if !content.isEmpty {
                            yieldedAny = true
                            delivery.markYielded()
                            continuation.yield(content)
                        }
                    case .done:
                        continuation.finish()
                        return
                    case .error(let message):
                        // In-band error frame (HTTP 200 + {"error":...}); surface it
                        // so PolishStage can fall back / report instead of going silent.
                        throw LLMError.apiError(sanitizeErrorBody(message))
                    case .ignore:
                        break
                    }
                }

                if decodeFailures > 0 {
                    AppLogger.log("[LLMService] SSE decode failures: \(decodeFailures), yieldedAny=\(yieldedAny)")
                }
                // A stream that produced no content but had undecodable frames is a real
                // failure, not an empty success — surface it instead of finishing silently.
                if !yieldedAny && decodeFailures > 0 {
                    throw LLMError.streamDecodingError
                }
                continuation.finish()
            }

            // Inactivity watchdog: a healthy slow stream keeps touching the clock, so long
            // outputs are not cut off mid-flight; a stalled stream times out within
            // timeoutSeconds of its last frame. Transport-level hangs are additionally
            // covered by request.timeoutInterval. See watchdogShouldTimeout for the
            // pre-first-token hard cap that keeps heartbeat-only streams from hanging polish.
            group.addTask {
                delivery.touch()
                let attemptStart = Date()
                while true {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    if Self.watchdogShouldTimeout(idleSeconds: delivery.idleSeconds(),
                                                  attemptElapsed: Date().timeIntervalSince(attemptStart),
                                                  hasYielded: delivery.hasYielded,
                                                  limit: TimeInterval(timeoutSeconds)) {
                        throw LLMError.timeout
                    }
                }
            }

            try await group.next()!
            group.cancelAll()
        }
    }
}

// MARK: - Security Helpers

private func sanitizeErrorBody(_ body: String) -> String {
    var sanitized = body
    // Redact common API key patterns
    let patterns = [
        "sk-[a-zA-Z0-9]{20,}",
        "sf-[a-zA-Z0-9]{20,}",
        "Bearer\\s+[a-zA-Z0-9_-]+",
        "api[-_]?key\\s*[:=]\\s*['\"]?[a-zA-Z0-9]{16,}['\"]?",
    ]
    for pattern in patterns {
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                options: [],
                range: NSRange(location: 0, length: sanitized.utf16.count),
                withTemplate: "[REDACTED]"
            )
        }
    }
    return String(sanitized.prefix(200))
}

func validatedAPIURL(baseURL: String) -> URL? {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed),
          url.scheme?.lowercased() == "https",
          let host = url.host, !host.isEmpty,
          !host.contains("@"),
          url.user == nil, url.password == nil else {
        return nil
    }
    // Preserve the base path (e.g. /v1, /openai/deployments/...) — OpenAI-compatible
    // endpoints live under it — while still rejecting path traversal.
    var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
    var basePath = components?.path ?? ""
    if basePath.contains("..") { return nil }
    if basePath.hasSuffix("/") { basePath = String(basePath.dropLast()) }
    components?.path = basePath + "/chat/completions"
    components?.query = nil
    components?.fragment = nil
    return components?.url
}

private struct StreamChunk: Codable {
    struct Choice: Codable {
        struct Delta: Codable {
            let content: String?
        }
        let delta: Delta
    }
    let choices: [Choice]
}

private struct StreamErrorEnvelope: Codable {
    struct ErrorBody: Codable {
        let message: String?
        let code: String?
    }
    let error: ErrorBody?
}

/// One classified Server-Sent-Event line from an OpenAI-compatible stream.
enum SSEEvent: Equatable {
    case content(String)
    case done
    case error(String)
    case ignore
}

/// Pure parser for a single SSE line. Recognizes in-band error frames (which many
/// providers, incl. SiliconFlow, return with HTTP 200) and counts malformed frames
/// so the caller can surface a real error instead of silently yielding nothing.
func parseSSELine(_ line: String, decodeFailures: inout Int) -> SSEEvent {
    guard line.hasPrefix("data: ") else { return .ignore }
    let payload = String(line.dropFirst(6))
    if payload == "[DONE]" { return .done }
    guard let data = payload.data(using: .utf8) else { return .ignore }
    // Error frame first: a normal content frame has no "error" key, so this only
    // matches genuine error envelopes.
    if let env = try? JSONDecoder().decode(StreamErrorEnvelope.self, from: data),
       let message = env.error?.message {
        return .error(message)
    }
    if let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) {
        return .content(chunk.choices.first?.delta.content ?? "")
    }
    decodeFailures += 1
    return .ignore
}
