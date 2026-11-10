import SwiftUI

/// Compatibility status entry. Uses the same projections and navigation as every other host.
struct ASRModelStatusCard: View {
    @ObservedObject private var model = ASRModelCenterEnvironment.shared.model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.rows.filter { $0.isPrimary || $0.isFallback }) { row in
                Text(row.title + " · " + row.status.label)
                Button("在模型中心查看") {
                    StatusBarController.shared.openSettings(destination: .settings(.speech, .asrBackend(row.id)))
                }
            }
            if !model.rows.contains(where: { $0.isPrimary || $0.isFallback }) {
                Button("配置识别模型") { StatusBarController.shared.openSettings(destination: .settings(.speech)) }
            }
        }
    }
}
