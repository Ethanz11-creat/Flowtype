import Foundation

enum PermissionState: Equatable, Sendable {
    case granted, denied, notDetermined, unknown
}

enum EngineReadiness: Equatable, Sendable {
    case ready
    case provisioning(progress: Double)
    case unavailable(reason: String)
}

struct ReadinessSnapshot: Equatable, Sendable {
    let accessibility: PermissionState
    let microphone: PermissionState
    let speechRecognition: PermissionState
    let localModel: EngineReadiness
    let cloudASR: EngineReadiness
    let appleSpeech: EngineReadiness
    let computedAt: Date
}

enum ReadinessIssue: Equatable, Sendable {
    case microphoneDenied, microphoneNotDetermined, noEngine
    case enginePreparing, basicOnly, accessibilityMissing

    var reason: String {
        switch self {
        case .microphoneDenied: return "麦克风权限未开启"
        case .microphoneNotDetermined: return "首次听写时会请求麦克风权限"
        case .noEngine: return "没有可用的语音识别引擎"
        case .enginePreparing: return "识别引擎正在准备"
        case .basicOnly: return "基础识别模式，准确率较低"
        case .accessibilityMissing: return "全局热键不可用；可从菜单开始，结果写入剪贴板"
        }
    }
}

enum ReadinessLevel: Equatable, Sendable {
    case ready
    case degraded(ReadinessIssue)
    case blocked(ReadinessIssue)

    var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }

    var reason: String? {
        switch self {
        case .ready: return nil
        case .degraded(let issue), .blocked(let issue): return issue.reason
        }
    }
}

func classifyReadiness(_ s: ReadinessSnapshot) -> ReadinessLevel {
    if s.microphone == .denied { return .blocked(.microphoneDenied) }

    let primaryReady = s.localModel == .ready || s.cloudASR == .ready
    let primaryPreparing: Bool = {
        if case .provisioning = s.localModel { return true }
        if case .provisioning = s.cloudASR { return true }
        return false
    }()

    if !primaryReady && s.appleSpeech != .ready && !primaryPreparing {
        return .blocked(.noEngine)
    }
    if !primaryReady && s.appleSpeech == .ready { return .degraded(.basicOnly) }
    if !primaryReady && primaryPreparing { return .degraded(.enginePreparing) }
    if s.accessibility != .granted { return .degraded(.accessibilityMissing) }
    if s.microphone != .granted { return .degraded(.microphoneNotDetermined) }
    return .ready
}
