import SwiftUI

extension SettingsPage {
    var recordingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "mic.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.red)
                Text("录音设置")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }

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
