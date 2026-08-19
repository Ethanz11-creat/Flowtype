import SwiftUI
import AppKit

struct LocalModelPicker: View {
    @ObservedObject private var store = ConfigurationStore.shared
    @ObservedObject private var downloader = ModelDownloader.shared
    @State private var folderMessage: String?

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
    }

    private func presetRow(_ preset: ModelPreset) -> some View {
        let isDownloading = downloader.currentDownload?.preset.id == preset.id
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

            if let path = store.current.customLocalModelPath {
                HStack(spacing: 6) {
                    Button {
                        store.current.customLocalModelPath = nil
                        folderMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
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
            } else if store.current.customLocalModelPath == nil {
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

        let minBytes: Int64 = 600 * 1024 * 1024
        do {
            _ = try CustomModelScanner.validateModelDirectory(url, minBytes: minBytes)
            store.current.customLocalModelPath = url.path
            folderMessage = nil
        } catch {
            folderMessage = error.localizedDescription
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
