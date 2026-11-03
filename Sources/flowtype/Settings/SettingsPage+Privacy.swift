import SwiftUI

extension SettingsPage {
    var privacySection: some View {
        let presentation = SettingsPrivacyPresentation.make(config: store.current)
        return VStack(alignment: .leading, spacing: 12) {
            Text("隐私").font(.system(size: 13, weight: .semibold))
            SettingsRow("保存转写文本", description: "关闭只影响后续文本：仍保存时长、字数等统计；已有文本请在历史中清除。") {
                Toggle("保存转写文本", isOn: $store.current.storeTranscriptText)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Button("管理已有历史文本") { navigation?.navigate(to: .history()) }
                .buttonStyle(.link).font(.system(size: 11))
            Divider()
            SettingsRow("云端发送上下文", description: "总开关：支持上下文的 HTTP 识别可携带前台文本。") {
                Toggle("云端发送上下文", isOn: $store.current.cloudASRSendContext)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!presentation.contextEnabled)
            }
            Divider()
            SettingsRow("云端整理使用上下文", description: "需同时开启上下文总开关；关闭不会改变整理服务或转写文本发送。") {
                Toggle("云端整理使用上下文", isOn: $store.current.cloudPolishSendContext)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!presentation.polishContextEnabled)
            }
            Text("仅本地下禁用上下文发送，保留原选择。Paraformer 实时识别（WSS）不发送上下文。识别音频仅在云端 ASR 时离开设备；云端文本整理仍会发送转写文字。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("服务密钥沿用本地配置存储。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
