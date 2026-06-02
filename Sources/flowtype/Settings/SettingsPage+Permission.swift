import SwiftUI

extension SettingsPage {
    var permissionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.gradient)
                Text("权限与系统状态")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: hasAccessibility ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.system(size: 16))
                        .foregroundColor(hasAccessibility ? .green : .orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(hasAccessibility ? "辅助功能权限已开启" : "辅助功能权限未开启")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(hasAccessibility ? .green : .orange)
                        Text(hasAccessibility
                             ? "Flowtype 可以监听全局按键触发"
                             : "需要开启权限才能使用语音输入功能")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button("打开系统设置") {
                    PermissionHelper.openAccessibilitySettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(14)
            .glassCard(cornerRadius: 10)
        }
        .padding(.horizontal, 4)
    }
}
