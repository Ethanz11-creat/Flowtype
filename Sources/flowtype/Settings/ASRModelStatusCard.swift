import SwiftUI

struct ASRModelStatusCard: View {
    @ObservedObject private var store = ConfigurationStore.shared
    @ObservedObject private var modelState = QwenModelState.shared
    @State private var cloudAvailable: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch store.current.asrEngine {
            case .local:
                localStatusView
            case .cloud:
                cloudStatusView
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 10)
        .task(id: store.current.asrEngine) {
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
        let hasAPIKey: Bool
        if let provider = store.current.cloudASRConfig.activeProvider {
            hasAPIKey = !(store.current.cloudASRConfig.providerAPIKeys[provider.id.uuidString] ?? "").isEmpty
        } else {
            hasAPIKey = false
        }

        let available = cloudAvailable ?? false
        let configured = hasAPIKey && available

        return HStack(spacing: 8) {
            Image(systemName: configured ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundColor(configured ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(configured ? "已配置" : "未配置 API Key")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(configured ? .green : .orange)
                if let provider = store.current.cloudASRConfig.activeProvider {
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
        guard store.current.asrEngine == .cloud else { return }
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
