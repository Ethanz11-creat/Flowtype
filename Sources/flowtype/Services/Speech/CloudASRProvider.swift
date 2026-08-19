import Foundation

private struct TranscriptionResponse: Decodable {
    let text: String
}

private struct ErrorResponse: Decodable {
    struct ErrorDetail: Decodable {
        let message: String?
    }
    let error: ErrorDetail?
    let message: String?
}

enum CloudASRError: Error, LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case networkError(Error)
    case timeout
    case noAPIKey
    case noModel
    case noActiveProvider
    case invalidURL(String)
    case audioEncodingFailed

    var statusCode: Int? {
        if case .apiError(let code, _) = self { return code }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "无效响应格式"
        case .apiError(let code, let msg):
            switch code {
            case 401, 403:
                return "API Key 无效或已过期"
            case 404:
                return "模型 ID 不存在或接口地址错误"
            case 413:
                return "音频文件过大"
            case 429:
                return "请求过于频繁，请稍后重试"
            case 500...599:
                return "服务商接口异常"
            default:
                return msg.isEmpty ? "HTTP \(code) 错误" : msg
            }
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
            return "网络错误: \(sanitizeCloudError(error.localizedDescription))"
        case .timeout:
            return "请求超时"
        case .noAPIKey:
            return "请在设置中配置云端 ASR API Key"
        case .noModel:
            return "请在设置中选择云端 ASR 模型"
        case .noActiveProvider:
            return "未配置云端 ASR 服务"
        case .invalidURL(let detail):
            return detail
        case .audioEncodingFailed:
            return "音频编码失败"
        }
    }
}

actor CloudASRProvider: ASRProvider {
    nonisolated let id = "cloud-asr"
    nonisolated let name = "CloudASR"
    nonisolated let displayName = "云端 ASR"
    nonisolated let supportsStreaming = false

    var isAvailable: Bool {
        get async {
            let config = await MainActor.run { ConfigurationStore.shared.current }
            guard let effective = config.effectiveCloudASRConfig else { return false }
            let baseURL = effective.provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = effective.provider.model.trimmingCharacters(in: .whitespacesAndNewlines)
            return !effective.apiKey.isEmpty && !baseURL.isEmpty && !model.isEmpty
        }
    }

    func transcribe(audioData: Data, timeout: TimeInterval) async throws -> String {
        let config = await MainActor.run { ConfigurationStore.shared.current }

        guard let effective = config.effectiveCloudASRConfig else {
            throw CloudASRError.noActiveProvider
        }

        let provider = effective.provider
        let apiKey = effective.apiKey

        guard !apiKey.isEmpty else {
            throw CloudASRError.noAPIKey
        }

        guard !provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudASRError.noModel
        }

        let url = try buildEndpointURL(baseURL: provider.baseURL)
        let wavData = try encodeWAVOrThrow(samples: audioData, sampleRate: 16000)
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        func appendFormField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendFormField(name: "model", value: provider.model)
        appendFormField(name: "response_format", value: "json")
        appendFormField(name: "temperature", value: "0.0")

        if let langCode = config.asrLanguage.qwenLanguageCode {
            appendFormField(name: "language", value: langCode)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let maxAttempts = 3
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                return try await executeTranscriptionRequest(request: request, logPrefix: "[CloudASR]")
            } catch {
                lastError = error
                if attempt < maxAttempts - 1 && isRetryableError(error) {
                    AppLogger.log("[CloudASR] Attempt \(attempt + 1) failed (\(error)), retrying in 500ms...")
                    try? await Task.sleep(nanoseconds: 500_000_000)
                } else {
                    throw error
                }
            }
        }
        throw lastError ?? CloudASRError.networkError(NSError(domain: "CloudASR", code: -1))
    }

    private nonisolated func isRetryableError(_ error: Error) -> Bool {
        if let asrError = error as? CloudASRError {
            switch asrError {
            case .networkError(let err):
                return (err as NSError).domain == NSURLErrorDomain
            case .timeout:
                return true
            case .apiError(let statusCode, _):
                return statusCode == 500 || statusCode == 502 || statusCode == 503 || statusCode == 504
            case .noAPIKey, .noModel, .noActiveProvider, .invalidURL, .invalidResponse, .audioEncodingFailed:
                return false
            }
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
    }

    func testConnection(provider: CloudASRProviderConfig, apiKey: String) async -> Result<String, CloudASRError> {
        guard !apiKey.isEmpty else {
            return .failure(.noAPIKey)
        }

        guard !provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.noModel)
        }

        let url: URL
        do {
            url = try buildEndpointURL(baseURL: provider.baseURL)
        } catch let error as CloudASRError {
            return .failure(error)
        } catch {
            return .failure(.invalidURL("无效的 Base URL"))
        }

        let silenceSamples = [Float](repeating: 0, count: 8000)
        let silenceData = silenceSamples.withUnsafeBytes { Data($0) }
        let wavData: Data
        do {
            wavData = try encodeWAVOrThrow(samples: silenceData, sampleRate: 16000)
        } catch let error as CloudASRError {
            return .failure(error)
        } catch {
            return .failure(.audioEncodingFailed)
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        func appendFormField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendFormField(name: "model", value: provider.model)
        appendFormField(name: "response_format", value: "json")

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"silence.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
            _ = try await executeTranscriptionRequest(request: request, logPrefix: "[CloudASR/test]")
            return .success("连接成功")
        } catch let error as CloudASRError {
            return .failure(error)
        } catch {
            return .failure(.networkError(error))
        }
    }

    private func buildEndpointURL(baseURL: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var urlComponents = URLComponents(string: trimmed) else {
            throw CloudASRError.invalidURL("无效的 Base URL")
        }

        var path = urlComponents.path
        if path.hasSuffix("/") { path = String(path.dropLast()) }
        path += "/audio/transcriptions"
        urlComponents.path = path
        urlComponents.query = nil
        urlComponents.fragment = nil

        guard let url = urlComponents.url, url.scheme?.lowercased() == "https" else {
            throw CloudASRError.invalidURL("无效的 Base URL，必须使用 HTTPS")
        }

        return url
    }

    private func encodeWAVOrThrow(samples: Data, sampleRate: Int) throws -> Data {
        guard let wav = WAVEncoder.encode(samples: samples, sampleRate: sampleRate) else {
            throw CloudASRError.audioEncodingFailed
        }
        return wav
    }

    private func executeTranscriptionRequest(request: URLRequest, logPrefix: String) async throws -> String {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw CloudASRError.invalidResponse
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let statusCode = httpResponse.statusCode
                let errorBody = String(data: data, encoding: .utf8) ?? "(无法解析错误响应)"
                let sanitizedBody = sanitizeCloudError(errorBody)
                AppLogger.log("\(logPrefix) HTTP \(statusCode): \(sanitizedBody)")

                let detailMessage: String
                if let errorResp = try? JSONDecoder().decode(ErrorResponse.self, from: data),
                   let msg = errorResp.error?.message ?? errorResp.message {
                    detailMessage = sanitizeCloudError(msg)
                } else {
                    detailMessage = sanitizedBody
                }
                throw CloudASRError.apiError(statusCode: statusCode, message: detailMessage)
            }

            do {
                if let result = try? JSONDecoder().decode(TranscriptionResponse.self, from: data) {
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    AppLogger.log("\(logPrefix) Transcription complete: \(text.count) chars")
                    return text
                }

                if let errorResp = try? JSONDecoder().decode(ErrorResponse.self, from: data),
                   let msg = errorResp.error?.message ?? errorResp.message {
                    throw CloudASRError.apiError(statusCode: httpResponse.statusCode, message: sanitizeCloudError(msg))
                }

                if let rawText = String(data: data, encoding: .utf8) {
                    let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                        throw CloudASRError.invalidResponse
                    }
                    AppLogger.log("\(logPrefix) Transcription complete (plain text): \(trimmed.count) chars")
                    return trimmed
                }

                throw CloudASRError.invalidResponse
            } catch let error as CloudASRError {
                throw error
            } catch {
                throw CloudASRError.invalidResponse
            }
        } catch let error as CloudASRError {
            throw error
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
                throw CloudASRError.timeout
            }
            AppLogger.log("\(logPrefix) Network error: \(sanitizeCloudError(error.localizedDescription))")
            throw CloudASRError.networkError(error)
        }
    }

}

private func sanitizeCloudError(_ message: String) -> String {
    var sanitized = message
    let patterns = [
        "sk-[a-zA-Z0-9_-]{8,}",
        "sf-[a-zA-Z0-9_-]{8,}",
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
    return String(sanitized.prefix(500))
}
