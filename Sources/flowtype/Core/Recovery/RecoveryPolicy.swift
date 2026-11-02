import Foundation

enum RecoveryTextKind: Equatable, Sendable {
    case none, raw, result
}

enum RecoveryAction: Equatable, Hashable, Sendable {
    case retry(stage: String)
    case copyRaw, copyResult, dismiss
    case openAccessibilitySettings, openMicrophoneSettings, openSpeechRecognitionSettings
    case openASRSettings, recheckReadiness, useAutomaticRouting
    case rerecord, viewHistory

    var displayName: String {
        switch self {
        case .retry(let stage):
            switch stage {
            case "ASR": return "重试识别"
            case "Polish": return "重试润色"
            case "Injection": return "重试输入"
            default: return "重试处理"
            }
        case .copyRaw: return "复制原文"
        case .copyResult: return "复制结果"
        case .dismiss: return "忽略"
        case .openAccessibilitySettings: return "打开辅助功能设置"
        case .openMicrophoneSettings: return "打开麦克风设置"
        case .openSpeechRecognitionSettings: return "打开语音识别设置"
        case .openASRSettings: return "打开 ASR 设置"
        case .recheckReadiness: return "重新检测"
        case .useAutomaticRouting: return "改为自动路由"
        case .rerecord: return "重新录音"
        case .viewHistory: return "查看历史"
        }
    }
}

/// Availability only: audio and text stay with the owning session.
struct RecoveryResources: Equatable, Sendable {
    let stage: String
    let hasAudio: Bool
    let textKind: RecoveryTextKind
    let deliveryEventStarted: Bool
    let routingPolicy: ASRRoutingPolicy
    let hasHistory: Bool
}

struct FailurePresentation: Equatable, Sendable {
    let kind: FailureKind
    let message: String
    let actions: [RecoveryAction]
}

struct RecoveryCard: Equatable, Sendable {
    let id: UUID
    let sessionID: UInt64
    let presentation: FailurePresentation
}

enum RecoveryPolicy {
    static func presentation(kind: FailureKind, resources: RecoveryResources) -> FailurePresentation {
        let message: String
        var actions: [RecoveryAction]
        switch kind {
        case .permission(let permission):
            switch permission {
            case .accessibility:
                message = "辅助功能权限未开启"
                actions = [.openAccessibilitySettings]
            case .microphone:
                message = "麦克风权限未开启"
                actions = [.openMicrophoneSettings]
            case .speechRecognition:
                message = "语音识别权限未开启"
                actions = [.openSpeechRecognitionSettings]
            }
            actions += [.recheckReadiness, .dismiss]
        case .readiness(let issue):
            message = issue.reason
            if issue == .noEngine {
                actions = [.openASRSettings, resources.routingPolicy == .auto ? .recheckReadiness : .useAutomaticRouting, .dismiss]
            } else {
                actions = [.recheckReadiness, .dismiss]
            }
        case .configuration(let issue):
            switch issue {
            case .credentials: message = "ASR 密钥无效或未配置，请检查设置后重新录音"
            case .endpointOrModel: message = "ASR 地址或模型配置不可用，请检查设置后重新录音"
            case .unsupportedLanguage: message = "当前模型不支持所选语言，请调整设置后重新录音"
            case .requestRejected: message = "识别请求被拒绝，请检查 ASR 设置后重新录音"
            }
            actions = [.openASRSettings, .rerecord, .dismiss]
        case .transientASR:
            message = "语音识别未完成，可重试原录音"
            actions = []
            if resources.stage == "ASR", resources.hasAudio, !resources.deliveryEventStarted {
                actions.append(.retry(stage: "ASR"))
            }
            actions.append(.rerecord)
            if resources.textKind == .raw { actions.append(.copyRaw) }
            actions.append(.dismiss)
        case .recording(let reason):
            switch reason {
            case .interrupted: message = "录音中断，请检查麦克风后重新录音"
            case .invalidAudio: message = "录音数据异常，请重新录音"
            case .tooLarge: message = "音频过长，请缩短后重新录音"
            }
            actions = [.rerecord, .dismiss]
        case .processing, .internalFailure:
            message = kind == .processing ? "文本处理未完成，请重新录音" : "处理未完成，请重新录音"
            switch resources.textKind {
            case .none: actions = []
            case .raw: actions = [.copyRaw]
            case .result: actions = [.copyResult]
            }
            actions += [.rerecord, .dismiss]
        case .deliveryBlocked:
            message = "未发送文本，可复制结果"
            actions = resources.textKind == .result ? [.copyResult, .dismiss] : [.dismiss]
        case .deliveryUncertain:
            message = "已发送，但无法确认是否插入；可复制结果"
            actions = resources.textKind == .result ? [.copyResult] : []
            if resources.hasHistory { actions.append(.viewHistory) }
            actions.append(.dismiss)
        case .cancelled:
            message = ""
            actions = []
        }
        return FailurePresentation(kind: kind, message: message, actions: actions)
    }
}
