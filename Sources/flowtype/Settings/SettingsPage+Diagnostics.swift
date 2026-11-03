import SwiftUI

extension SettingsPage {
    var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("诊断").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 16) {
                Button(action: { AppLogger.openLogInFinder() }) {
                    Label("查看诊断日志", systemImage: "doc.text.magnifyingglass")
                }
                Button("复制指标报告") {
                    let report = SessionMetrics.report(HistoryStore.shared.sessions)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
                Spacer()
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }
}
