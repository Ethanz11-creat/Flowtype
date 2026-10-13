import SwiftUI

struct ASRModelStatusCard: View {
    @ObservedObject private var store = ConfigurationStore.shared
    @ObservedObject private var modelState = QwenModelState.shared
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
        let preset = ModelPreset.preset(forID: store.current.selectedLocalModelID)
            ?? ModelPreset.recommendedModel(for: HardwareProfiler.currentTier())
        let isDownloaded = ModelLocator.isPresetDownloaded(preset)
        let isLoaded: Bool
        if case .ready = modelState.status {
            isLoaded = true
        } else {
            isLoaded = ASRProviderRegistry.shared.qwenLocalProvider.isLoaded
        }

        return Group {
            HStack(spacing: 8) {
                Image(systemName: statusIcon(isDownloaded: isDownloaded, isLoaded: isLoaded))
                    .font(.system(size: 16))
                    .foregroundColor(statusColor(isDownloaded: isDownloaded, isLoaded: isLoaded))
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle(isDownloaded: isDownloaded, isLoaded: isLoaded))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(statusColor(isDownloaded: isDownloaded, isLoaded: isLoaded))
                    Text(preset.name)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            if let customPath = store.current.customLocalModelPath, !customPath.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(customPath)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
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

    private func statusIcon(isDownloaded: Bool, isLoaded: Bool) -> String {
        if isLoaded { return "checkmark.circle.fill" }
        if isDownloaded { return "exclamationmark.circle.fill" }
        return "circle.dashed"
    }

    private func statusColor(isDownloaded: Bool, isLoaded: Bool) -> Color {
        if isLoaded { return .green }
        if isDownloaded { return .orange }
        return .gray
    }

    private func statusTitle(isDownloaded: Bool, isLoaded: Bool) -> String {
        if isLoaded { return "已就绪" }
        if isDownloaded { return "已下载未加载" }
        return "未下载"
    }
}
