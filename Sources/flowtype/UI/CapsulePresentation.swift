import Foundation

/// Emission-site metadata. Arbitrary legacy notice strings never determine outcome or timing.
enum CapsuleNotice: Equatable, Sendable {
    enum PolishFallback: Equatable, Sendable { case failed, timedOut, literalPreserved }
    case noSpeech, emptyAudio, clipboard, resourceBusy, polishFallback(PolishFallback)

    var duration: TimeInterval { self == .clipboard ? 5 : 2.2 }

    static func completion(outcome: DeliveryOutcome?, fallback: CapsuleNotice?) -> CapsuleNotice? {
        switch outcome {
        case .clipboard: return .clipboard
        case .uncertain, .cancelled: return nil
        default: return fallback
        }
    }
}

/// Only the controller owns these waits; tests can resume cancelled waits to prove token guards.
@MainActor struct CapsulePresentationTiming {
    var now: @MainActor @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var delay: @MainActor @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(for: .seconds(seconds))
    }
}

struct CapsulePresentation: Equatable {
    enum Indicator: Equatable { case waveform, spinner, symbol(String) }
    let title: String
    let subtitle: String
    let timer: String?
    let indicator: Indicator
    let size: NSSize
    let hidden: Bool
    let actions: [RecoveryAction]

    init(state: SessionState, preparationNotice: String? = nil, notice: CapsuleNotice? = nil,
         slow: Bool = false, recoveryCard: RecoveryCard? = nil, resourceBusyNotice: String? = nil,
         maxRecordingDuration: Int = 300) {
        size = state.capsuleSize
        hidden = !state.showPanel
        actions = recoveryCard?.presentation.actions ?? []
        var timerValue: String?
        switch state {
        case .idle:
            title = ""; subtitle = ""; indicator = .symbol("circle")
        case .preparing:
            title = "正在准备"; subtitle = preparationNotice ?? "启动麦克风"; indicator = .spinner
        case .recording(let seconds):
            title = "Listening..."; subtitle = "正在听写"; indicator = .waveform
            let remaining = maxRecordingDuration - seconds
            timerValue = remaining > 0 && remaining <= 30 ? "剩余 \(remaining)s" : String(format: "%02d:%02d", seconds / 60, seconds % 60)
        case .processing, .polishing:
            title = slow ? "处理时间较长" : "正在处理"
            if slow { subtitle = "仍在处理，请稍候" }
            else if case .polishing = state { subtitle = "整理文字中" }
            else { subtitle = "识别语音中" }
            indicator = .spinner
        case .injecting:
            title = "正在输入"; subtitle = "请保持当前光标"; indicator = .symbol("text.cursor")
        case .notice(let message):
            switch notice {
            case .resourceBusy: title = "暂时无法开始"; subtitle = "资源使用中，请稍后再试"; indicator = .symbol("hourglass")
            case .noSpeech: title = "未检测到声音"; subtitle = "请重新录音"; indicator = .symbol("mic.slash")
            case .emptyAudio: title = "未录到音频"; subtitle = "请重新录音"; indicator = .symbol("mic.slash")
            case .clipboard: title = "结果已复制"; subtitle = "按 ⌘V 粘贴"; indicator = .symbol("doc.on.clipboard")
            case .polishFallback(let reason):
                title = reason == .literalPreserved ? "技术内容已保留" : "已保留识别结果"
                subtitle = reason == .literalPreserved ? "已使用识别结果" : (reason == .timedOut ? "整理超时" : "整理未完成")
                indicator = .symbol("text.alignleft")
            case nil: title = message; subtitle = ""; indicator = .symbol("info.circle")
            }
        case .error(let message):
            title = Self.failureTitle(recoveryCard?.presentation.kind)
            subtitle = resourceBusyNotice ?? message
            indicator = .symbol(recoveryCard?.presentation.kind == .deliveryUncertain ? "questionmark.circle" : "exclamationmark.circle")
        }
        timer = timerValue
    }

    static func failureTitle(_ kind: FailureKind?) -> String {
        switch kind {
        case .permission: return "需要开启权限"
        case .readiness: return "暂时无法开始"
        case .configuration: return "请检查识别设置"
        case .transientASR: return "语音识别未完成"
        case .recording: return "录音未完成"
        case .processing: return "文本处理未完成"
        case .deliveryBlocked: return "文本尚未输入"
        case .deliveryUncertain: return "请检查输入结果"
        default: return "处理未完成"
        }
    }
}
