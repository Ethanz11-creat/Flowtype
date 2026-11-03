import Foundation

/// All inputs are synthetic; this suite never opens settings or touches providers.
enum M4RecoveryPolicySelfTests {
    @MainActor
    static func run(_ r: SelfTest.Reporter) {
        classification(r)
        policy(r)
        context(r)
    }

    private static func classification(_ r: SelfTest.Reporter) {
        let hostile = "secret-provider-body https://invalid.example/?key=secret"
        let cases: [(Error, FailureKind)] = [
            (CancellationError(), .cancelled), (CloudASRError.cancelled, .cancelled),
            (URLError(.cancelled), .cancelled), (RealtimeAudioIngressError.cancelled, .cancelled),
            (CloudASRError.noAPIKey, .configuration(.credentials)),
            (CloudASRError.noModel, .configuration(.endpointOrModel)),
            (CloudASRError.noActiveProvider, .configuration(.endpointOrModel)),
            (CloudASRError.invalidURL(hostile), .configuration(.endpointOrModel)),
            (CloudASRError.unsupportedRealtimeTransport, .configuration(.endpointOrModel)),
            (CloudASRError.audioEncodingFailed, .recording(.invalidAudio)),
            (CloudASRError.invalidResponse, .transientASR), (CloudASRError.timeout, .transientASR),
            (RealtimeASRConfigurationError.missingAPIKey, .configuration(.credentials)),
            (RealtimeASRConfigurationError.missingModel, .configuration(.endpointOrModel)),
            (RealtimeASRConfigurationError.invalidEndpoint, .configuration(.endpointOrModel)),
            (RealtimeASRConfigurationError.unsupportedProtocol, .configuration(.endpointOrModel)),
            (SpeechProviderError.notAvailable, .readiness(.noEngine)),
            (SpeechProviderError.permissionDenied, .permission(.speechRecognition)),
            (SpeechProviderError.transcriptionFailed(hostile), .transientASR),
            (OfflineWhisperError.unsupportedLanguage, .configuration(.unsupportedLanguage)),
            (OfflineWhisperError.invalidSampleRate, .recording(.invalidAudio)),
            (OfflineWhisperError.invalidLocalDirectory, .configuration(.endpointOrModel)),
            (OfflineWhisperError.incompatibleGraph, .configuration(.endpointOrModel)),
            (OfflineWhisperError.incompatibleTokenizer, .configuration(.endpointOrModel)),
            (OfflineWhisperError.tokenizerUnavailable, .configuration(.endpointOrModel)),
            (OfflineWhisperError.incompatibleRuntime, .configuration(.endpointOrModel)),
            (AudioRecorderError.permissionDenied, .permission(.microphone)),
            (PermissionError.microphoneDenied, .permission(.microphone)),
            (AudioRecorderError.engineStartFailed, .recording(.interrupted)),
            (AudioRecorderError.formatCreationFailed, .recording(.interrupted)),
            (ASRStageError.invalidPayload, .internalFailure),
            (ASRStageError.invalidAudio, .recording(.invalidAudio)),
            (ASRStageError.transcriptionFailed(message: hostile), .transientASR),
            (PostProcessStageError.invalidPayload, .internalFailure),
            (PostProcessStageError.emptyResult, .processing),
            (PolishStageError.invalidPayload, .internalFailure),
            (PolishStageError.damagedLiterals, .processing),
            (InjectionStageError.invalidPayload, .internalFailure),
            (InjectionStageError.clipboardSnapshotIncomplete, .deliveryBlocked),
            (InjectionStageError.pasteNotDispatched, .deliveryBlocked),
            (InjectionError.eventCreationFailed, .deliveryBlocked),
            (InjectionError.eventSourceCreationFailed, .deliveryBlocked),
            (InjectionError.textTooLong, .deliveryBlocked),
            (InjectionError.injectionAlreadyInProgress, .deliveryBlocked),
            (InjectionError.noEventsDispatched, .deliveryBlocked),
            (InjectionError.targetNoLongerSafe, .deliveryBlocked),
            (AsyncDeadlineError.timedOut, .internalFailure),
            (DashScopeRealtimeError.startTimeout, .transientASR),
            (DashScopeRealtimeError.finalTimeout, .transientASR),
            (DashScopeRealtimeError.invalidEvent, .transientASR),
            (DashScopeRealtimeError.transportClosed, .transientASR),
            (DashScopeRealtimeError.notStarted, .transientASR),
            (DashScopeRealtimeError.taskFailed(code: "401", message: hostile), .transientASR),
            (RealtimeAudioIngressError.closed, .transientASR),
            (RealtimeAudioIngressError.overflow, .transientASR),
            (WebSocketTransportError.closed, .transientASR),
            (WebSocketTransportError.invalidFrame, .transientASR),
            (ModelProvisionError.metadataInvalid(), .configuration(.endpointOrModel)),
            (ModelProvisionError.network(), .configuration(.endpointOrModel)),
            (ModelProvisionError.stalled(), .configuration(.endpointOrModel)),
            (ModelProvisionError.incompleteLocal(), .configuration(.endpointOrModel)),
            (ModelProvisionError.loadFailed(), .configuration(.endpointOrModel)),
            (ModelProvisionError.insufficientDisk(), .configuration(.endpointOrModel)),
            (NSError(domain: "synthetic", code: 401, userInfo: [NSLocalizedDescriptionKey: hostile]), .internalFailure)
        ]
        for (index, pair) in cases.enumerated() {
            let kind = FailureClassifier.classify(pair.0)
            r.eq(kind, pair.1, "M4 classifier typed row \(index)")
            let shown = RecoveryPolicy.presentation(kind: kind, resources: resources())
            r.check(!shown.message.contains("secret") && !shown.message.contains("https://"), "M4 classifier safe message \(index)")
            r.check(shown.actions.allSatisfy { !$0.displayName.contains("secret") }, "M4 classifier safe actions \(index)")
        }
        let statuses: [(Int, FailureKind)] = [
            (301, .configuration(.requestRejected)), (400, .configuration(.endpointOrModel)),
            (401, .configuration(.credentials)), (403, .configuration(.credentials)),
            (404, .configuration(.endpointOrModel)), (408, .transientASR),
            (413, .recording(.tooLarge)), (429, .transientASR),
            (500, .transientASR), (599, .transientASR), (200, .configuration(.requestRejected)),
            (600, .configuration(.requestRejected))
        ]
        for (status, expected) in statuses {
            let kind = FailureClassifier.classify(CloudASRError.apiError(statusCode: status, message: hostile))
            r.eq(kind, expected, "M4 HTTP \(status)")
            r.check(!RecoveryPolicy.presentation(kind: kind, resources: resources()).message.contains("secret"), "M4 HTTP body never shown")
        }
        let configurationCodes: [URLError.Code] = [.badURL, .unsupportedURL, .secureConnectionFailed,
            .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired,
            .appTransportSecurityRequiresSecureConnection]
        for code in configurationCodes {
            r.eq(FailureClassifier.classify(URLError(code)), .configuration(.endpointOrModel), "M4 URL configuration \(code.rawValue)")
        }
        for code: URLError.Code in [.notConnectedToInternet, .timedOut, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost] {
            r.eq(FailureClassifier.classify(URLError(code)), .transientASR, "M4 URL transport \(code.rawValue)")
        }
        let wrapperLeaves: [(Error, FailureKind)] = [
            (CancellationError(), .cancelled), (CloudASRError.cancelled, .cancelled),
            (URLError(.cancelled), .cancelled), (RealtimeAudioIngressError.cancelled, .cancelled),
            (URLError(.badURL), .configuration(.endpointOrModel)),
            (CloudASRError.apiError(statusCode: 401, message: hostile), .configuration(.credentials)),
            (NSError(domain: "synthetic", code: -999), .internalFailure)
        ]
        for (leafIndex, pair) in wrapperLeaves.enumerated() {
            var nested = pair.0
            for depth in 1...5 {
                nested = depth.isMultiple(of: 2) ? SpeechProviderError.networkError(nested) : CloudASRError.networkError(nested)
                r.eq(FailureClassifier.classify(nested), depth <= 4 ? pair.1 : .internalFailure, "M4 bounded wrapper leaf \(leafIndex) depth \(depth)")
            }
        }
        r.eq(FailureClassifier.classify(CloudASRError.networkError(SpeechProviderError.networkError(URLError(.badURL)))),
             .configuration(.endpointOrModel), "M4 nested wrapper keeps URL configuration")
        r.eq(FailureClassifier.classify(SpeechProviderError.networkError(CloudASRError.apiError(statusCode: 401, message: hostile))),
             .configuration(.credentials), "M4 nested wrapper keeps HTTP credentials")
        r.eq(FailureClassifier.classify(CloudASRError.networkError(NSError(domain: "synthetic", code: -999))),
             .internalFailure, "M4 unknown wrapped error stays internal")
    }

    private static func resources(stage: String = "ASR", audio: Bool = true, text: RecoveryTextKind = .raw,
                                  event: Bool = false, routing: ASRRoutingPolicy = .auto, history: Bool = true) -> RecoveryResources {
        RecoveryResources(stage: stage, hasAudio: audio, textKind: text, deliveryEventStarted: event,
                          routingPolicy: routing, hasHistory: history)
    }

    private static func policy(_ r: SelfTest.Reporter) {
        let rows: [(FailureKind, String, [RecoveryAction])] = [
            (.permission(.accessibility), "辅助功能权限未开启", [.openAccessibilitySettings, .recheckReadiness, .dismiss]),
            (.permission(.microphone), "麦克风权限未开启", [.openMicrophoneSettings, .recheckReadiness, .dismiss]),
            (.permission(.speechRecognition), "语音识别权限未开启", [.openSpeechRecognitionSettings, .recheckReadiness, .dismiss]),
            (.readiness(.noEngine), "没有可用的语音识别引擎", [.openASRSettings, .recheckReadiness, .dismiss]),
            (.readiness(.microphoneDenied), "麦克风权限未开启", [.recheckReadiness, .dismiss]),
            (.readiness(.microphoneNotDetermined), "首次听写时会请求麦克风权限", [.recheckReadiness, .dismiss]),
            (.readiness(.enginePreparing), "识别引擎正在准备", [.recheckReadiness, .dismiss]),
            (.readiness(.basicOnly), "基础识别模式，准确率较低", [.recheckReadiness, .dismiss]),
            (.readiness(.accessibilityMissing), "全局热键不可用；可从菜单开始，结果写入剪贴板", [.recheckReadiness, .dismiss]),
            (.configuration(.credentials), "ASR 密钥无效或未配置，请检查设置后重新录音", [.openASRSettings, .rerecord, .dismiss]),
            (.configuration(.endpointOrModel), "ASR 地址或模型配置不可用，请检查设置后重新录音", [.openASRSettings, .rerecord, .dismiss]),
            (.configuration(.unsupportedLanguage), "当前模型不支持所选语言，请调整设置后重新录音", [.openASRSettings, .rerecord, .dismiss]),
            (.configuration(.requestRejected), "识别请求被拒绝，请检查 ASR 设置后重新录音", [.openASRSettings, .rerecord, .dismiss]),
            (.transientASR, "语音识别未完成，可重试原录音", [.retry(stage: "ASR"), .rerecord, .copyRaw, .dismiss]),
            (.recording(.interrupted), "录音中断，请检查麦克风后重新录音", [.rerecord, .dismiss]),
            (.recording(.invalidAudio), "录音数据异常，请重新录音", [.rerecord, .dismiss]),
            (.recording(.tooLarge), "音频过长，请缩短后重新录音", [.rerecord, .dismiss]),
            (.processing, "文本处理未完成，请重新录音", [.copyRaw, .rerecord, .dismiss]),
            (.internalFailure, "处理未完成，请重新录音", [.copyRaw, .rerecord, .dismiss]),
            (.deliveryBlocked, "未发送文本", [.dismiss]),
            (.deliveryUncertain, "已发送，但无法确认是否插入；可查看历史", [.viewHistory, .dismiss]),
            (.cancelled, "", [])
        ]
        for (kind, message, defaultActions) in rows {
            let base = RecoveryPolicy.presentation(kind: kind, resources: resources())
            r.eq(base, FailurePresentation(kind: kind, message: message, actions: defaultActions), "M4 exact presentation \(kind)")
            for stage in ["ASR", "Injection"] {
                for audio in [false, true] {
                    for event in [false, true] {
                        for text: RecoveryTextKind in [.none, .raw, .result] {
                            for routing in ASRRoutingPolicy.allCases {
                                for history in [false, true] {
                                    let value = RecoveryPolicy.presentation(kind: kind, resources: resources(stage: stage, audio: audio, text: text, event: event, routing: routing, history: history))
                                    r.eq(value.kind, kind, "M4 kind preserved")
                                    r.check(value.actions.count <= 4, "M4 at most four actions")
                                    r.eq(value.actions.contains(.retry(stage: "ASR")), kind == .transientASR && stage == "ASR" && audio && !event, "M4 retry eligibility")
                                    r.check(!value.actions.contains(.retry(stage: "Injection")), "M4 never retry delivery")
                                    var expected = defaultActions
                                    var expectedMessage = message
                                    switch kind {
                                    case .readiness(.noEngine) where routing != .auto:
                                        expected = [.openASRSettings, .useAutomaticRouting, .dismiss]
                                    case .transientASR:
                                        expected = stage == "ASR" && audio && !event ? [.retry(stage: "ASR"), .rerecord] : [.rerecord]
                                        if text == .raw { expected.append(.copyRaw) }
                                        expected.append(.dismiss)
                                        expectedMessage = expected.contains(.retry(stage: "ASR"))
                                            ? "语音识别未完成，可重试原录音" : "语音识别未完成，请重新录音"
                                    case .processing, .internalFailure:
                                        expected = text == .raw ? [.copyRaw] : text == .result ? [.copyResult] : []
                                        expected += [.rerecord, .dismiss]
                                    case .deliveryBlocked:
                                        expected = text == .result ? [.copyResult, .dismiss] : [.dismiss]
                                        expectedMessage = text == .result ? "未发送文本，可复制结果" : "未发送文本"
                                    case .deliveryUncertain:
                                        expected = text == .result ? [.copyResult] : []
                                        if history { expected.append(.viewHistory) }
                                        expected.append(.dismiss)
                                        expectedMessage = "已发送，但无法确认是否插入"
                                        if text == .result { expectedMessage += "；可复制结果" }
                                        else if history { expectedMessage += "；可查看历史" }
                                    default: break
                                    }
                                    r.eq(value.message, expectedMessage, "M4 resource-aware copy \(kind)")
                                    r.eq(value.actions, expected, "M4 exact matrix action order \(kind)")
                                }
                            }
                        }
                    }
                }
            }
        }
        let labels: [(RecoveryAction, String)] = [(.retry(stage: "ASR"), "重试识别"),
            (.retry(stage: "Polish"), "重试润色"), (.retry(stage: "Injection"), "重试输入"),
            (.retry(stage: "Other"), "重试处理"), (.copyRaw, "复制原文"), (.copyResult, "复制结果"),
            (.dismiss, "忽略"), (.openAccessibilitySettings, "打开辅助功能设置"),
            (.openMicrophoneSettings, "打开麦克风设置"), (.openASRSettings, "打开 ASR 设置"),
            (.recheckReadiness, "重新检测"), (.useAutomaticRouting, "改为自动路由"),
            (.openSpeechRecognitionSettings, "打开语音识别设置"), (.rerecord, "重新录音"), (.viewHistory, "查看历史")]
        for (action, expected) in labels { r.eq(action.displayName, expected, "M4 action label") }
        r.eq(Set(labels.map(\.0)).count, labels.count, "M4 actions Hashable")
        let presentation = RecoveryPolicy.presentation(kind: .deliveryUncertain, resources: resources())
        let id = UUID()
        let card = RecoveryCard(id: id, sessionID: 42, presentation: presentation)
        r.eq(card, RecoveryCard(id: id, sessionID: 42, presentation: presentation), "M4 card equality")
        r.check(card != RecoveryCard(id: UUID(), sessionID: 42, presentation: presentation), "M4 card identity")
        r.check(card != RecoveryCard(id: id, sessionID: 43, presentation: presentation), "M4 card session ownership")
    }

    private static func context(_ r: SelfTest.Reporter) {
        let configuration = ErrorRecoveryContext(failedStage: "ASR", error: CloudASRError.noAPIKey, rawText: nil, retryable: true)
        r.eq(configuration.failureKind, .configuration(.credentials), "M4 legacy retryable cannot override configuration")
        r.eq(configuration.textKind, .none, "M4 nil text inference")
        r.eq(configuration.failedStage, "ASR", "M4 legacy stage retained")
        r.check(configuration.error is CloudASRError && configuration.retryable, "M4 original error/retryable retained")
        let transient = ErrorRecoveryContext(failedStage: "ASR", error: CloudASRError.noAPIKey, rawText: "synthetic", retryable: false, failureKind: .transientASR)
        r.eq(transient.failureKind, .transientASR, "M4 explicit kind wins over legacy retryable and error")
        r.eq(transient.textKind, .raw, "M4 nonnil text inference")
        r.eq(transient.rawText, "synthetic", "M4 raw text retained only in context")
        let result = ErrorRecoveryContext(failedStage: "Injection", error: InjectionStageError.invalidPayload, rawText: "synthetic", retryable: true, failureKind: .deliveryBlocked, textKind: .result)
        r.eq(result.textKind, .result, "M4 explicit complete result kind")
        let unknown = ErrorRecoveryContext(failedStage: "ASR", error: NSError(domain: "synthetic", code: 1), rawText: "", retryable: true)
        r.eq(unknown.failureKind, .internalFailure, "M4 unknown retryable cannot infer transient")
        r.eq(unknown.textKind, .raw, "M4 text inference uses existence")
    }
}
