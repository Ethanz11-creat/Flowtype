import SwiftUI

extension SettingsPage {
    var diagnosticsSection: some View {
        HStack {
            Button(action: { AppLogger.openLogInFinder() }) {
                Label("查看诊断日志", systemImage: "doc.text.magnifyingglass")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundColor(Brand.accent)
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}
