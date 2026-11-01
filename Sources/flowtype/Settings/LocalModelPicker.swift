import SwiftUI
import AppKit

struct LocalModelPicker: View {
    @ObservedObject private var store = ConfigurationStore.shared
    @ObservedObject private var downloader = ModelDownloader.shared
    @ObservedObject private var modelState = QwenModelState.shared
    @State private var folderMessage: String?

    private var configuredPath: String? {
        [store.current.customLocalModelPath, store.current.localModelPath].compactMap { $0 }.first { !$0.isEmpty }
    }

    private var currentTier: HardwareTier {
        HardwareProfiler.currentTier()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("本地模型")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text(ModelPreset.hardwareTierDescription(currentTier))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $store.current.selectedLocalModelID) {
                    Text("自动选择（推荐）").tag(String?.none)
                    ForEach(ModelPreset.allPresets) { preset in
                        let isRecommended = preset.recommendedTiers.contains(currentTier)
                        let sizeStr = formatBytes(preset.expectedSizeBytes)
                        Text("\(preset.name)\(isRecommended ? " ⭐️推荐" : "") (\(sizeStr))")
                            .tag(Optional(preset.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(modelState.operationID != nil)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ModelPreset.allPresets) { preset in
                        presetRow(preset)
                    }
                }

                Divider().opacity(0.5)

                customFolderSection
            }
            .padding(14)
            .glassCard(cornerRadius: 10)
        }
        .onChange(of: store.current.selectedLocalModelID) { _, _ in
            guard store.current.customLocalModelPath == nil, store.current.localModelPath == nil else { return }
            Task { await modelState.retryConfiguredModel() }
        }
    }

    private func presetRow(_ preset: ModelPreset) -> some View {
        let isDownloading = downloader.isDownloading(preset: preset)
        let isDownloaded = downloader.isModelDownloaded(preset)
        let isRecommended = preset.recommendedTiers.contains(currentTier)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(preset.name)
                            .font(.system(size: 12, weight: .medium))
                        if isRecommended {
                            Text("⭐️推荐")
                                .font(.system(size: 9))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                    Text(preset.modelDescription)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("下载大小：\(formatBytes(preset.expectedSizeBytes))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isDownloading {
                    Button("取消") {
                        downloader.cancelDownload()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.red.opacity(0.8))
                } else if isDownloaded {
                    Button("删除") {
                        Task {
                            try? downloader.deleteModel(preset)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.red.opacity(0.8))
                } else {
                    Button("下载") {
                        Task {
                            downloader.startDownload(preset: preset)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(Brand.accent)
                    .disabled(modelState.operationID != nil)
                }
            }

            if isDownloading, case let .downloading(progress) = downloader.currentDownload?.status {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(height: 4)
                Text("下载中 \(Int(progress * 100))%")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var customFolderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("指定本地模型文件夹") {
                    pickModelFolder()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(modelState.operationID != nil)

                Button {
                    NSWorkspace.shared.open(ModelPreset.modelsDirectory)
                } label: {
                    Text("打开模型文件夹")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundColor(.secondary)

                Spacer()
            }

            if let path = configuredPath {
                HStack(spacing: 6) {
                    Button {
                        ModelRecoveryActions(coordinator: modelState, store: store).removeFolderOverride()
                        folderMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(modelState.operationID != nil)
                    .help("移除模型文件夹选择")
                    Text(path)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
            }

            if let msg = folderMessage {
                Text(msg)
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if configuredPath == nil {
                Text("已下载好模型的话，指到那个文件夹即可离线加载。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func pickModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择本地模型文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                try await ModelRecoveryActions(coordinator: modelState, store: store).importOfflineModel(at: url)
                folderMessage = nil
            } catch {
                folderMessage = (error as? ModelProvisionError).flatMap {
                    ModelRecoveryPresentation.make(active: nil, target: nil, failure: $0, didAutoFallback: false).failureMessage
                } ?? "模型加载已取消。"
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 {
            let gb = mb / 1024
            return String(format: "%.1f GB", gb)
        }
        return String(format: "%.0f MB", mb)
    }
}
