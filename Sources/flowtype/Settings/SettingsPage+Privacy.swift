import SwiftUI

extension SettingsPage {
    var privacySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                Text("隐私")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("保存转写文本")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                    Toggle("", isOn: $store.current.storeTranscriptText)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                Text("关闭后只保存时长/字数等统计元数据，不再保存\u{201C}你说了什么\u{201D}。统计不受影响。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
    }
}
