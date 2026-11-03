import SwiftUI

extension SettingsPage {
    var triggerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("触发键与交互").font(.system(size: 13, weight: .semibold))
            SettingsRow("触发键") {
                Picker("触发键", selection: $store.current.triggerKey) {
                    ForEach(TriggerKey.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.labelsHidden().pickerStyle(.menu).frame(width: 180)
            }
            Divider()
            SettingsRow("交互模式") {
                Picker("交互模式", selection: $store.current.interactionMode) {
                    ForEach(InteractionMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.labelsHidden().pickerStyle(.menu).frame(width: 180)
            }
            Text(store.current.interactionMode == .tapToStart
                 ? "当前触发键：\(store.current.triggerKey.displayName)。双击开始录音，单击立即停止。"
                 : "当前触发键：\(store.current.triggerKey.displayName)。单击开始或停止录音。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            SettingsRow("录音开始／结束播放提示音") {
                Toggle("录音开始／结束播放提示音", isOn: $store.current.enableAudioFeedback)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }
}
