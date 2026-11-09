import Foundation

/// One sequential winner; all attempts share the stop-to-delivery budget.
final class ASRStage: PipelineStage, @unchecked Sendable {
    var name: String { "ASR" }
    private let healthRecorder: @MainActor @Sendable (String, Int?, ASRRouteSnapshot) -> Void
    private let realtimeFactory: RealtimeSessionFactory
    private let routeFactory: @Sendable () async -> ASRRouteSnapshot
    private let speechPreflight: @Sendable ([Float], Int) async throws -> SpeechPreflightDecision
    private let phrases: @MainActor @Sendable () -> [String]

    init(healthRecorder: @escaping @MainActor @Sendable (String, Int?, ASRRouteSnapshot) -> Void = { id, latency, route in
        if let latency { ASRRouter.shared.recordSuccess(providerID: id, latencyMs: latency, route: route) }
        else { ASRRouter.shared.recordFailure(providerID: id, route: route) }
    }, realtimeFactory: @escaping RealtimeSessionFactory = liveRealtimeSessionFactory,
         routeFactory: @escaping @Sendable () async -> ASRRouteSnapshot = {
        await ASRRouter.shared.captureStartRoute()
    }, speechPreflight: @escaping @Sendable ([Float], Int) async throws -> SpeechPreflightDecision = {
        try await SpeechPreflight.evaluate(samples: $0, sampleRate: $1)
    }, phrases: @escaping @MainActor @Sendable () -> [String] = { DictionaryStore.shared.enabledPhrases }) {
        self.healthRecorder = healthRecorder
        self.realtimeFactory = realtimeFactory
        self.routeFactory = routeFactory
        self.speechPreflight = speechPreflight
        self.phrases = phrases
    }

    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        guard case .audio(let samples, let preview) = payload else {
            return .suspend(ErrorRecoveryContext(failedStage: name, error: ASRStageError.invalidPayload,
                                                 rawText: nil, retryable: false))
        }
        guard !Task.isCancelled, !context.isCancellationRequested else { return cancelled() }
        let (budget, live) = await MainActor.run {
            if context.completionBudget == nil { context.completionBudget = CompletionBudget() }
            return (context.completionBudget!, context.takeRealtimeAttempt())
        }
        defer {
            if let live {
                live.0.ingress.cancel()
                live.1?.cancel()
                Task { await live.0.session.cancel() }
            }
        }
        guard !Task.isCancelled, !context.isCancellationRequested else { return cancelled() }
        let decision: SpeechPreflightDecision
        do {
            decision = try await speechPreflight(samples, 16000)
        } catch {
            guard FailureClassifier.classify(error) != .cancelled, !Task.isCancelled, !context.isCancellationRequested else {
                return cancelled()
            }
            decision = .indeterminate(.detectorUnavailable)
        }
        guard !Task.isCancelled, !context.isCancellationRequested else { return cancelled() }
        switch decision {
        case .clearlySilent:
            await MainActor.run { if !context.isCancelled { context.capsuleNotice = .noSpeech } }
            return .notice("未检测到声音，请重试")
        case .emptyCapture:
            await MainActor.run { if !context.isCancelled { context.capsuleNotice = .emptyAudio } }
            return .notice("未录到音频，请重试")
        case .indeterminate(.invalidSamples), .indeterminate(.unsupportedSampleRate):
            return .suspend(ErrorRecoveryContext(failedStage: name, error: ASRStageError.invalidAudio,
                                                 rawText: nil, retryable: false))
        case .possiblySpeech, .indeterminate(.tooShort), .indeterminate(.detectorUnavailable): break
        }
        guard !budget.isExpired else {
            return .suspend(ErrorRecoveryContext(failedStage: name,
                error: ASRStageError.transcriptionFailed(message: "识别超时，请重试"), rawText: nil, retryable: true,
                failureKind: .transientASR))
        }
        let savedRoute = await MainActor.run { context.captureRoute }
        guard !Task.isCancelled, !context.isCancellationRequested else { return cancelled() }
        let route: ASRRouteSnapshot
        if let savedRoute { route = savedRoute } else { route = await routeFactory() }
        guard !Task.isCancelled, !context.isCancellationRequested else { return cancelled() }
        let (phrases, foreground) = await MainActor.run {
            context.captureRoute = route
            context.syncRealtimeFailure()
            return (self.phrases(), context.foregroundContextText)
        }
        let ids = route.candidateIDs
        var firstFailure: Error? = route.captureError
        var firstFailureKind: FailureKind? = route.captureError.map { FailureClassifier.classify($0) }
        var firstFailureDestination: ClientDestination?
        var finalResult: ASRResult?
        var finalProviderID: String?
        var usedFallback = false

        for binding in route.bindings where !samples.isEmpty {
            let id = binding.descriptor.id.rawValue
            guard !Task.isCancelled, !context.isCancellationRequested else { return cancelled() }
            let timeout = completionStageTimeout(remaining: budget.remainingSeconds,
                                                  cloud: binding.descriptor.location == .cloud,
                                                  policy: route.policy, localAvailable: route.localAvailable)
            guard timeout > 0 else {
                if firstFailure == nil {
                    firstFailure = AsyncDeadlineError.timedOut
                    firstFailureKind = .transientASR
                }
                break
            }
            await MainActor.run {
                if !context.isCancelled { context.statePublisher.send(.processing(provider: "识别中")) }
            }
            guard !Task.isCancelled, !context.isCancellationRequested else { return cancelled() }
            do {
                let request = ASRRequest(samples: samples, sampleRate: 16000, language: route.language,
                                         context: ASRContext(phrases: phrases, foreground: foreground),
                                         timeout: timeout, cloudConfiguration: binding.cloudConfiguration)
                let result: ASRResult
                if binding.isRealtime, let config = binding.cloudConfiguration {
                    let capturedLive = route.bindings.first?.descriptor.id == binding.descriptor.id ? live : nil
                    let handle: RealtimeASRSessionHandle
                    if let live = capturedLive { handle = live.0 }
                    else {
                        handle = realtimeFactory(try RealtimeASRConfiguration(provider: config.provider,
                                                                              apiKey: config.apiKey,
                                                                              language: route.language))
                    }
                    do {
                        result = try await withAsyncDeadline(seconds: timeout) {
                            if let live = capturedLive {
                                if let start = live.1 { try await start.value }
                                return try await handle.session.finish()
                            }
                            return try await transcribeSavedRealtime(samples: samples, handle: handle)
                        }
                    } catch {
                        handle.ingress.cancel()
                        // Cleanup must not join an uncooperative provider.
                        Task { await handle.session.cancel() }
                        live?.1?.cancel()
                        throw error
                    }
                } else {
                    let provider = binding.provider
                    result = try await withAsyncDeadline(seconds: timeout) { try await provider.transcribe(request) }
                }
                guard !Task.isCancelled, !context.isCancellationRequested else { return cancelled() }
                guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ASRStageError.transcriptionFailed(message: "未识别到完整文字，请重试")
                }
                finalResult = ASRResult(text: result.text, providerID: id, latencyMs: result.latencyMs)
                finalProviderID = id
                let latencyMs = Int(budget.elapsedSeconds * 1000)
                await healthRecorder(id, binding.isRealtime ? latencyMs : result.latencyMs, route)
                break
            } catch {
                // Classify before the safe generic terminal error hides provider causes.
                let kind: FailureKind = error is AsyncDeadlineError ? .transientASR : FailureClassifier.classify(error)
                guard kind != .cancelled, !Task.isCancelled, !context.isCancellationRequested else {
                    return cancelled()
                }
                if firstFailure == nil {
                    firstFailure = error
                    firstFailureKind = kind
                    if case .configuration = kind {
                        firstFailureDestination = binding.descriptor.location == .native
                            ? .settings(.speech, .localModels)
                            : binding.cloudConfiguration.map { .settings(.speech, .provider($0.provider.id)) }
                    }
                }
                usedFallback = true
                await healthRecorder(id, nil, route)
                AppLogger.log("[ASRStage#\(context.sessionID)] engine=\(binding.nativeLease?.identity.engine ?? binding.descriptor.location.rawValue) transport=\(binding.isRealtime ? "realtime" : "batch") fallback=\(fallbackReason(for: error))")
            }
        }
        guard !Task.isCancelled, !context.isCancellationRequested else { return cancelled() }
        if let result = finalResult {
            let ms = Int(budget.elapsedSeconds * 1000)
            await MainActor.run {
                guard !context.isCancelled else { return }
                context.usedProviderID = finalProviderID
                context.asrMs = ms
                context.rawTranscript = result.text
                context.usedFallback = usedFallback
                context.fallbackReason = firstFailure.map { fallbackReason(for: $0) }
                if route.bindings.first(where: { $0.descriptor.id.rawValue == result.providerID })?.isRealtime == true { context.setRealtimeResult(result) }
            }
            return .continue(.transcript(result.text))
        }
        // An expired stop budget cannot promote provisional/partial preview.
        if !budget.isExpired, !preview.isEmpty {
            await MainActor.run {
                context.usedFallback = true
                context.fallbackReason = "preview"
            }
            return .continue(.transcript(preview))
        }
        if samples.isEmpty, firstFailure == nil { return .complete }
        var recovery = ErrorRecoveryContext(failedStage: name,
            error: (firstFailure as? RealtimeASRConfigurationError).map { $0 as Error } ?? ASRStageError.transcriptionFailed(message: budget.isExpired ? "识别超时，请重试" :
                ids.isEmpty ? "语音识别未就绪，请配置云端 API Key 或加载本地模型" : "语音识别失败，请重试"),
            rawText: nil, retryable: true,
            failureKind: firstFailureKind ?? (ids.isEmpty ? .readiness(.noEngine) : budget.isExpired ? .transientASR : .internalFailure))
        recovery.destination = firstFailureDestination
        return .suspend(recovery)
    }

    private func cancelled() -> StageResult {
        .suspend(ErrorRecoveryContext(failedStage: name, error: CancellationError(), rawText: nil, retryable: false))
    }
}

/// A new handle for each saved recording attempt. Awaiting append waits for its
/// binary send to finish, bounding memory independently of recording duration.
func transcribeSavedRealtime(samples: [Float], handle: RealtimeASRSessionHandle) async throws -> ASRResult {
    try Task.checkCancellation()
    try await handle.session.start()
    for offset in stride(from: 0, to: samples.count, by: 1600) {
        try Task.checkCancellation()
        try await handle.session.append(samples: Array(samples[offset..<min(samples.count, offset + 1600)]))
    }
    try Task.checkCancellation()
    return try await handle.session.finish()
}

enum ASRStageError: Error, LocalizedError {
    case invalidPayload
    case invalidAudio
    case transcriptionFailed(message: String)
    var errorDescription: String? {
        switch self {
        case .invalidPayload: return "无效的输入数据"
        case .invalidAudio: return "录音数据异常，请重新录音"
        case .transcriptionFailed(let msg): return msg
        }
    }
}
