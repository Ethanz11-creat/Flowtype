import Foundation

// MARK: - ASRStage

/// 纯编排：组装 `ASRRequest` → 按策略候选链依次尝试 → 收 `ASRResult`。
/// 无任何 provider 类型判断；AppleSpeech 预览仅作最后兜底。
///
/// Input: `.audio(samples: [Float], previewText: String)`
/// Output: `.transcript(String)`
final class ASRStage: PipelineStage, @unchecked Sendable {

    var name: String { "ASR" }

    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        let sessionID = context.sessionID
        AppLogger.log("[ASRStage#\(sessionID)] Processing phase started")
        let processingStartTime = Date()
        defer {
            let total = Date().timeIntervalSince(processingStartTime)
            AppLogger.log("[ASRStage#\(sessionID)] Processing phase ended (total: \(String(format: "%.1f", total))s)")
        }

        let rawSamples: [Float]
        let localPreviewText: String
        switch payload {
        case .audio(let samples, let previewText):
            rawSamples = samples
            localPreviewText = previewText
        default:
            AppLogger.log("[ASRStage#\(sessionID)] Unexpected payload: \(payload), expected .audio")
            return .suspend(ErrorRecoveryContext(failedStage: name, error: ASRStageError.invalidPayload,
                                                 rawText: nil, retryable: false))
        }

        let audioDuration = Double(rawSamples.count) / 16000.0
        AppLogger.log("[ASRStage#\(sessionID)] Raw samples: \(rawSamples.count) (\(String(format: "%.1f", audioDuration))s)")

        let cfg = await MainActor.run { ConfigurationStore.shared.current }
        let phrases = await MainActor.run { DictionaryStore.shared.enabledPhrases }
        let foreground = await MainActor.run { context.foregroundContextText }
        let request = ASRRequest(
            samples: rawSamples,
            sampleRate: 16000,
            language: cfg.asrLanguage.qwenLanguageCode,
            context: ASRContext(phrases: phrases, foreground: foreground),
            timeout: min(120.0, max(30.0, audioDuration * 3 + 15))
        )

        let chain = await ASRRouter.shared.selectChain()
        AppLogger.log("[ASRStage#\(sessionID)] Candidate chain: \(chain.map(\.id))")

        var finalASRText = ""
        var providerFailed = false
        var firstFailure: Error?

        if !rawSamples.isEmpty {
            for provider in chain {
                if Task.isCancelled {
                    return .suspend(ErrorRecoveryContext(failedStage: name, error: CancellationError(),
                                                         rawText: nil, retryable: false))
                }
                await MainActor.run {
                    context.statePublisher.send(.processing(provider: provider.displayName))
                }
                let asrStart = Date()
                do {
                    let result = try await provider.transcribe(request)
                    let elapsed = Date().timeIntervalSince(asrStart)
                    AppLogger.log("[ASRStage#\(sessionID)] \(provider.displayName) completed in \(String(format: "%.2f", elapsed))s: \(result.text.count) chars")
                    finalASRText = result.text
                    await MainActor.run {
                        context.usedProviderID = result.providerID
                        context.asrMs = result.latencyMs
                    }
                    ASRRouter.shared.recordSuccess(providerID: result.providerID, latencyMs: result.latencyMs)
                    break
                } catch is CancellationError {
                    AppLogger.log("[ASRStage#\(sessionID)] \(provider.displayName) cancelled")
                    return .suspend(ErrorRecoveryContext(failedStage: name, error: CancellationError(),
                                                         rawText: nil, retryable: false))
                } catch {
                    AppLogger.log("[ASRStage#\(sessionID)] \(provider.displayName) failed: \(error)")
                    providerFailed = true
                    if firstFailure == nil { firstFailure = error }
                    ASRRouter.shared.recordFailure(providerID: provider.id)
                }
            }
        }

        if providerFailed, let failure = firstFailure {
            let reason = fallbackReason(for: failure)
            await MainActor.run {
                context.usedFallback = true
                context.fallbackReason = reason
            }
        }

        if finalASRText.isEmpty, !localPreviewText.isEmpty {
            AppLogger.log("[ASRStage#\(sessionID)] Using AppleSpeech preview as fallback")
            finalASRText = localPreviewText
            await MainActor.run {
                context.usedFallback = true
                context.fallbackReason = "preview"
            }
        }

        guard !finalASRText.isEmpty else {
            if chain.isEmpty {
                let noticeMsg: String
                switch cfg.asrRoutingPolicy {
                case .cloudOnly:
                    noticeMsg = "云端 ASR 未就绪，请在设置中配置 API Key"
                case .localOnly:
                    noticeMsg = "本地模型未加载，请在设置中下载模型"
                case .auto:
                    noticeMsg = "语音识别暂不可用，请在设置中配置云端服务或下载本地模型"
                }
                AppLogger.log("[ASRStage#\(sessionID)] No provider in chain, notice: \(noticeMsg)")
                return .notice(noticeMsg)
            }
            if providerFailed {
                return .suspend(ErrorRecoveryContext(
                    failedStage: name,
                    error: ASRStageError.transcriptionFailed(message: "语音识别失败，请检查网络连接或重试"),
                    rawText: nil,
                    retryable: true
                ))
            }
            AppLogger.log("[ASRStage#\(sessionID)] No speech recognized — ending session quietly")
            return .complete
        }

        return .continue(.transcript(finalASRText))
    }
}

enum ASRStageError: Error, LocalizedError {
    case invalidPayload
    case transcriptionFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidPayload: return "无效的输入数据"
        case .transcriptionFailed(let msg): return msg
        }
    }
}
