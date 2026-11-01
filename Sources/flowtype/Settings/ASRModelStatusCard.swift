import SwiftUI

struct ASRModelStatusCard: View {
    @ObservedObject private var store = ConfigurationStore.shared
    @State private var cloudAvailable: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch store.current.asrRoutingPolicy {
            case .localOnly:
                localStatusView
            case .cloudOnly:
                cloudStatusView
            case .auto:
                localStatusView
                Divider().opacity(0.3)
                cloudStatusView
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 10)
        .task(id: store.current.asrRoutingPolicy) {
            await refreshCloudStatus()
        }
        .onChange(of: store.current.cloudASRConfig) { _, _ in
            Task { await refreshCloudStatus() }
        }
    }

    private var localStatusView: some View {
        QwenModelStatusCard()
    }

    private var cloudStatusView: some View {
        let provider = store.current.cloudASRConfig.activeProvider
        let hasAPIKey: Bool
        if let provider {
            hasAPIKey = !(store.current.cloudASRConfig.providerAPIKeys[provider.id.uuidString] ?? "").isEmpty
        } else {
            hasAPIKey = false
        }

        let available = cloudAvailable ?? false
        let statusText: String
        if available {
            statusText = "已配置"
        } else if !hasAPIKey {
            statusText = "未配置 API Key"
        } else if let provider, provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statusText = "未选择模型"
        } else if let provider, provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statusText = "未配置 Base URL"
        } else {
            statusText = "未配置"
        }

        return HStack(spacing: 8) {
            Image(systemName: available ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundColor(available ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(available ? .green : .orange)
                if let provider {
                    Text("\(provider.name) · \(provider.model)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    Text("未添加服务商")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
    }

    private func refreshCloudStatus() async {
        guard store.current.asrRoutingPolicy != .localOnly else { cloudAvailable = nil; return }
        let provider = ASRProviderRegistry.shared.cloudProvider
        cloudAvailable = await provider.isAvailable
    }

}
