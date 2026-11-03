import SwiftUI

extension SettingsPage {
    var recordingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "mic.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                Text("录音设置")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }

            Picker("文字交付方式", selection: $store.current.deliveryMode) {
                Text("自动（推荐）").tag(DeliveryMode.automatic)
                Text("仅键入（兼容）").tag(DeliveryMode.unicode)
                Text("旧版候选应用模式").tag(DeliveryMode.pasteInSupportedApps)
            }
            Text("自动模式优先粘贴，确认未发送且目标可编辑时尝试键入。旧版候选：TextEdit、VS Code、Cursor、Chrome、Safari、Edge；其他应用使用键入。候选目录不代表已完成真机验证。")
                .font(.system(size: 11)).foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("最大录音时长")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(store.current.maxRecordingDuration / 60) 分钟")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                }

                Slider(
                    value: Binding(
                        get: { Double(store.current.maxRecordingDuration) },
                        set: { store.current.maxRecordingDuration = Int($0) }
                    ),
                    in: 60...1800,
                    step: 60
                )

                Text("录音达到最大时长后将自动停止。最后 30 秒会显示倒计时提醒。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
    }
}
