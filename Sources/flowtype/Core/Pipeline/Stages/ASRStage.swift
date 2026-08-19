import Foundation

// MARK: - ASRStage

/// Pipeline stage that performs batch ASR transcription using the active provider
/// (local Qwen3-ASR or cloud ASR) with AppleSpeech preview fallback.
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
            let totalProcessingTime = Date().timeIntervalSince(processingStartTime)
            AppLogger.log("[ASRStage#\(sessionID)] Processing phase ended (total: \(String(format: "%.1f", totalProcessingTime))s)")
        }

        // Extract input payload
        let rawSamples: [Float]
        let localPreviewText: String
        switch payload {
        case .audio(let samples, let previewText):
            rawSamples = samples
            localPreviewText = previewText
        default:
            AppLogger.log("[ASRStage#\(sessionID)] Unexpected payload: \(payload), expected .audio")
            return .suspend(ErrorRecoveryContext(
                failedStage: name,
                error: ASRStageError.invalidPayload,
                rawText: nil,
                retryable: false
            ))
        }

        let audioDuration = Double(rawSamples.count) / 16000.0
        AppLogger.log("[ASRStage#\(sessionID)] Raw samples: \(rawSamples.count) (\(String(format: "%.1f", audioDuration))s)")

        var finalASRText = ""
        var providerFailed = false

        let provider = await ASRProviderRegistry.shared.activeTranscriptionProviderAsync()
        let providerAvailable = await provider.isAvailable

        if providerAvailable && !rawSamples.isEmpty {
            AppLogger.log("[ASRStage#\(sessionID)] Using \(provider.displayName) for batch transcription")
            await MainActor.run {
                context.statePublisher.send(.processing(provider: provider.displayName))
            }

            let asrStart = Date()
            do {
                if let qwenProvider = provider as? QwenASRProvider {
                    let asrLanguage = await MainActor.run { ConfigurationStore.shared.current.asrLanguage }
                    let asrPhrases = await MainActor.run { DictionaryStore.shared.enabledPhrases }
                    let asrContext = composeASRContext(asrPhrases)
                    finalASRText = try await qwenProvider.transcribe(
                        samples: rawSamples,
                        language: asrLanguage.qwenLanguageCode,
                        context: asrContext
                    )
                } else {
                    let audioData = rawSamples.withUnsafeBytes { Data($0) }
                    // Cloud STT is upload + remote inference; a fixed 30s is too tight for
                    // long recordings on slow links. Scale with duration, bounded 30–120s.
                    let cloudTimeout = min(120.0, max(30.0, audioDuration * 3 + 15))
                    finalASRText = try await provider.transcribe(audioData: audioData, timeout: cloudTimeout)
                }
                AppLogger.log("[ASRStage#\(sessionID)] \(provider.displayName) completed in \(String(format: "%.2f", Date().timeIntervalSince(asrStart)))s: \(finalASRText.count) chars")
            } catch is CancellationError {
                AppLogger.log("[ASRStage#\(sessionID)] \(provider.displayName) cancelled")
                return .suspend(ErrorRecoveryContext(
                    failedStage: name,
                    error: CancellationError(),
                    rawText: nil,
                    retryable: false
                ))
            } catch {
                AppLogger.log("[ASRStage#\(sessionID)] \(provider.displayName) failed: \(error)")
                finalASRText = ""
                providerFailed = true
            }
        }

        if finalASRText.isEmpty, !localPreviewText.isEmpty {
            AppLogger.log("[ASRStage#\(sessionID)] Using AppleSpeech preview as fallback")
            finalASRText = localPreviewText
        }

        guard !finalASRText.isEmpty else {
            if !providerAvailable {
                let noticeMsg: String
                if provider.id == "cloud-asr" {
                    noticeMsg = "云端 ASR 未就绪，请在设置中配置 API Key"
                } else {
                    noticeMsg = "本地模型未加载，请在设置中下载模型"
                }
                AppLogger.log("[ASRStage#\(sessionID)] Provider not available, showing gentle notice: \(noticeMsg)")
                // A missing provider alongside silence is not a hard error — guide the
                // user with a purple auto-dismissing notice instead of a red error card.
                return .notice(noticeMsg)
            }
            if providerFailed {
                AppLogger.log("[ASRStage#\(sessionID)] Provider failed and no preview available — surfacing error")
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
        case .invalidPayload:
            return "无效的输入数据"
        case .transcriptionFailed(let msg):
            return msg
        }
    }
}
