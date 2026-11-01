import Foundation

private struct TranscriptionResponse: Decodable {
    let text: String
}

enum CloudASRError: Error, LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case networkError(Error)
    case timeout
    case cancelled
    case noAPIKey
    case noModel
    case noActiveProvider
    case invalidURL(String)
    case audioEncodingFailed
    case unsupportedRealtimeTransport

    var statusCode: Int? {
        if case .apiError(let code, _) = self { return code }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "无效响应格式"
        case .apiError(let code, _):
            switch code {
            case 400:
                return "请求参数或模型配置无效"
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
                return "HTTP \(code) 错误"
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
            return "网络连接失败，请检查网络或服务地址"
        case .cancelled:
            return "请求已取消"
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
        case .unsupportedRealtimeTransport:
            return "该服务商配置为实时 WSS，请在真实录音时验证"
        }
    }
}

/// Never resend credentials or audio to an endpoint the user did not configure.
/// Redirects (including same-origin redirects) are surfaced as HTTP failures.
private final class CloudASRRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor CloudASRProvider: ASRProvider {
    private let session: URLSession
    private let logger: @Sendable (String) -> Void
    init(session: URLSession = .shared, logger: @escaping @Sendable (String) -> Void = { AppLogger.log($0) }) {
        self.session = session
        self.logger = logger
    }
    nonisolated let id = ASRProviderID.cloud
    nonisolated let name = "CloudASR"
    nonisolated let displayName = "云端 ASR"
    // The HTTP adapter can deliver hints; each captured vendor capability gates actual wire fields.
    nonisolated let capabilities = ASRCapabilities(
        supportsLanguageHint: true, supportsContextHint: true, requiresNetwork: true, location: .cloud
    )

    var isAvailable: Bool {
        get async {
            let config = await MainActor.run { ConfigurationStore.shared.current }
            guard let effective = config.effectiveCloudASRConfig else { return false }
            if case .success = validateConfiguration(provider: effective.provider, apiKey: effective.apiKey) { return true }
            return false
        }
    }

    func transcribe(_ request: ASRRequest) async throws -> ASRResult {
        let start = Date()
        let configuration = try await resolveConfiguration(request.cloudConfiguration)
        try Task.checkCancellation()
        let upload = try CloudTranscriptionRequestBuilder.make(configuration: configuration, samples: request.samples,
                                                               language: request.language, context: request.context,
                                                               timeout: request.timeout)
        let text = try await executeTranscriptionRequest(request: upload, logPrefix: "[CloudASR]")
        return ASRResult(text: text, providerID: id, latencyMs: Int(Date().timeIntervalSince(start) * 1000))
    }

    func transcribe(audioData: Data, timeout: TimeInterval, context: ASRContext?,
                    configuration snapshot: CloudASRRequestConfiguration? = nil, language: String? = nil) async throws -> String {
        guard audioData.count.isMultiple(of: MemoryLayout<Float>.stride) else { throw CloudASRError.audioEncodingFailed }
        // Data does not promise Float alignment. Copy bytes into aligned sample storage.
        var samples = [Float](repeating: 0, count: audioData.count / MemoryLayout<Float>.stride)
        _ = samples.withUnsafeMutableBytes { audioData.copyBytes(to: $0) }
        let configuration = try await resolveConfiguration(snapshot)
        try Task.checkCancellation()
        let upload = try CloudTranscriptionRequestBuilder.make(configuration: configuration, samples: samples,
                                                               language: language, context: context, timeout: timeout)
        return try await executeTranscriptionRequest(request: upload, logPrefix: "[CloudASR]")
    }

    private func resolveConfiguration(_ snapshot: CloudASRRequestConfiguration?) async throws -> CloudASRRequestConfiguration {
        if let snapshot { return snapshot }
        let effective = await MainActor.run {
            let config = ConfigurationStore.shared.current
            return config.effectiveCloudASRConfig.map {
                CloudASRRequestConfiguration(provider: $0.provider, apiKey: $0.apiKey, sendContext: config.cloudASRSendContext)
            }
        }
        guard let effective else { throw CloudASRError.noActiveProvider }
        return effective
    }

    /// Pure local validation: no transport, recording, configuration store, or credential-store access.
    nonisolated func validateConfiguration(provider: CloudASRProviderConfig, apiKey: String) -> Result<String, CloudASRError> {
        do {
            try CloudTranscriptionRequestBuilder.validate(provider: provider, apiKey: apiKey)
            return .success(provider.protocolKind == .dashScopeRealtime
                ? "配置有效；实时连接将在真实录音时验证" : "配置有效；尚未连接服务商")
        } catch let error as CloudASRError {
            return .failure(error)
        } catch {
            return .failure(.invalidURL("云端 ASR 配置无效"))
        }
    }

    func testConnection(provider: CloudASRProviderConfig, apiKey: String) async -> Result<String, CloudASRError> {
        do {
            try Task.checkCancellation()
            let validation = validateConfiguration(provider: provider, apiKey: apiKey)
            if case .failure = validation { return validation }
            if provider.protocolKind == .dashScopeRealtime { return validation }
            let configuration = CloudASRRequestConfiguration(provider: provider, apiKey: apiKey, sendContext: false)
            let request = try CloudTranscriptionRequestBuilder.make(configuration: configuration,
                samples: [Float](repeating: 0, count: 8000), language: nil, context: nil, timeout: 15)
            _ = try await executeTranscriptionRequest(request: request, logPrefix: "[CloudASR/test]")
            return .success("连接成功")
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as CloudASRError {
            return .failure(error)
        } catch {
            return .failure(.networkError(Self.safeNetworkError(error)))
        }
    }

    private func executeTranscriptionRequest(request: URLRequest, logPrefix: String) async throws -> String {
        do {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request, delegate: CloudASRRedirectPolicy())
            // A task that expired/cancelled while the transport completed cannot deliver a late result.
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw CloudASRError.invalidResponse }
            guard (200...299).contains(response.statusCode) else {
                logger("\(logPrefix) HTTP \(response.statusCode)")
                throw CloudASRError.apiError(statusCode: response.statusCode, message: "")
            }
            // Only the documented JSON text envelope is accepted; HTML/plain text is never a transcript.
            guard let decoded = try? JSONDecoder().decode(TranscriptionResponse.self, from: data) else {
                throw CloudASRError.invalidResponse
            }
            let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
            logger("\(logPrefix) Transcription complete: \(text.count) chars")
            return text
        } catch {
            if error is CancellationError || Task.isCancelled || (error as NSError).domain == NSURLErrorDomain &&
                (error as NSError).code == NSURLErrorCancelled { throw CancellationError() }
            if let error = error as? CloudASRError { throw error }
            if (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorTimedOut {
                throw CloudASRError.timeout
            }
            logger("\(logPrefix) Network request failed")
            throw CloudASRError.networkError(Self.safeNetworkError(error))
        }
    }

    /// Do not retain arbitrary NSError userInfo (which can include URL queries, headers, or body text).
    private static func safeNetworkError(_ error: Error) -> NSError {
        let underlying = error as NSError
        return NSError(domain: NSURLErrorDomain,
                       code: underlying.domain == NSURLErrorDomain ? underlying.code : NSURLErrorUnknown)
    }
}
