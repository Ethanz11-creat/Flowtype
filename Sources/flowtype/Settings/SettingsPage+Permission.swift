import SwiftUI

/// Reused by settings and onboarding; viewing this surface only reads the monitor.
struct PermissionSettingsContent: View {
    @ObservedObject var store: ConfigurationStore
    @ObservedObject var monitor: ReadinessMonitor
    let navigation: SettingsNavigation?
    var openMicrophoneSettings: () -> Void = PermissionHelper.openMicrophoneSettings
    var openAccessibilitySettings: () -> Void = PermissionHelper.openAccessibilitySettings
    var openSpeechSettings: () -> Void = PermissionHelper.openSpeechRecognitionSettings

    var body: some View {
        let presentation = ReadinessPresentation.make(snapshot: monitor.snapshot, level: monitor.rawLevel)
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(presentation.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("重新检测") { monitor.refresh() }.controlSize(.small)
            }
            ForEach(presentation.details, id: \.self) { detail in
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                SettingsRow("麦克风", description: microphoneDescription) {
                    Button("打开系统设置", action: openMicrophoneSettings).controlSize(.small)
                }.id(SettingsTarget.microphone)
                Divider()
                SettingsRow("辅助功能", description: monitor.snapshot.accessibility == .granted
                    ? "已开启；全局热键与自动落字可用。"
                    : "未开启；可从菜单开始听写，结果写入剪贴板。全局热键与自动落字不可用。") {
                    Button("打开系统设置") {
                        openAccessibilitySettings()
                        monitor.startPermissionWatchIfNeeded()
                    }.controlSize(.small)
                }.id(SettingsTarget.accessibility)
                Divider()
                SettingsRow("Apple Speech（可选）", description: "仅 Apple 基础识别依赖此权限；本地模型与云端 ASR 无需授权。") {
                    Button("打开系统设置", action: openSpeechSettings).controlSize(.small)
                }.id(SettingsTarget.appleSpeech)
            }
            Text("配置通过或引擎就绪表示可以开始尝试，不代表本次识别已经成功。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var microphoneDescription: String {
        switch monitor.snapshot.microphone {
        case .granted: "已开启；可以录音。"
        case .denied: "未开启；录音已阻止，请在系统设置中开启。"
        case .notDetermined, .unknown: "首次明确开始录音时请求；查看此页面不会弹出授权。"
        }
    }
}
