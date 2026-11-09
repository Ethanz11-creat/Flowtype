import Foundation

enum FailureClassifier {
    static func classify(_ error: Error) -> FailureKind {
        classify(error, wrapperDepth: 0)
    }

    private static func classify(_ error: Error, wrapperDepth: Int) -> FailureKind {
        // Four known wrappers may be opened. Do not inspect arbitrary userInfo or
        // follow unbounded chains; unknown and over-deep errors remain internal.
        guard wrapperDepth <= 4 else { return .internalFailure }
        if error is CancellationError { return .cancelled }
        if error is ASRCredentialError { return .configuration(.credentials) }

        if let cloud = error as? CloudASRError {
            switch cloud {
            case .cancelled: return .cancelled
            case .networkError(let underlying): return classify(underlying, wrapperDepth: wrapperDepth + 1)
            case .noAPIKey: return .configuration(.credentials)
            case .noModel, .noActiveProvider, .invalidURL, .unsupportedRealtimeTransport:
                return .configuration(.endpointOrModel)
            case .audioEncodingFailed: return .recording(.invalidAudio)
            case .invalidResponse, .timeout: return .transientASR
            case .apiError(let status, _):
                switch status {
                case 401, 403: return .configuration(.credentials)
                case 400, 404: return .configuration(.endpointOrModel)
                case 413: return .recording(.tooLarge)
                case 408, 429, 500...599: return .transientASR
                default: return .configuration(.requestRejected)
                }
            }
        }
        if let speech = error as? SpeechProviderError {
            switch speech {
            case .networkError(let underlying): return classify(underlying, wrapperDepth: wrapperDepth + 1)
            case .notAvailable: return .readiness(.noEngine)
            case .permissionDenied: return .permission(.speechRecognition)
            case .transcriptionFailed: return .transientASR
            }
        }
        let network = error as NSError
        if network.domain == NSURLErrorDomain {
            switch network.code {
            case NSURLErrorCancelled: return .cancelled
            case NSURLErrorBadURL, NSURLErrorUnsupportedURL, NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired,
                 NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return .configuration(.endpointOrModel)
            default: return .transientASR
            }
        }
        if let configuration = error as? RealtimeASRConfigurationError {
            return .configuration(configuration == .missingAPIKey ? .credentials : .endpointOrModel)
        }
        if let ingress = error as? RealtimeAudioIngressError {
            return ingress == .cancelled ? .cancelled : .transientASR
        }
        if error is DashScopeRealtimeError || error is WebSocketTransportError {
            return .transientASR
        }
        if let whisper = error as? OfflineWhisperError {
            switch whisper {
            case .unsupportedLanguage: return .configuration(.unsupportedLanguage)
            case .invalidSampleRate: return .recording(.invalidAudio)
            case .invalidLocalDirectory, .incompatibleGraph, .incompatibleTokenizer,
                 .tokenizerUnavailable, .incompatibleRuntime:
                return .configuration(.endpointOrModel)
            }
        }
        // Model provisioning is repaired in settings, never by replaying audio.
        if error is ModelProvisionError { return .configuration(.endpointOrModel) }
        if error is PermissionError { return .permission(.microphone) }
        if let recorder = error as? AudioRecorderError {
            switch recorder {
            case .permissionDenied: return .permission(.microphone)
            case .engineStartFailed, .formatCreationFailed: return .recording(.interrupted)
            }
        }
        if let stage = error as? ASRStageError {
            switch stage {
            case .invalidPayload: return .internalFailure
            case .invalidAudio: return .recording(.invalidAudio)
            case .transcriptionFailed: return .transientASR
            }
        }
        if let stage = error as? PostProcessStageError {
            switch stage {
            case .invalidPayload: return .internalFailure
            case .emptyResult: return .processing
            }
        }
        if let stage = error as? PolishStageError {
            switch stage {
            case .invalidPayload: return .internalFailure
            case .damagedLiterals: return .processing
            }
        }
        if let stage = error as? InjectionStageError {
            switch stage {
            case .invalidPayload: return .internalFailure
            case .clipboardSnapshotIncomplete, .pasteNotDispatched: return .deliveryBlocked
            }
        }
        // Errors alone cannot prove whether an event was posted. The delivery
        // owner must explicitly use deliveryUncertain after its event latch.
        if error is InjectionError { return .deliveryBlocked }
        return .internalFailure
    }
}
