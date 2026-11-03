import SwiftUI
import AppKit

struct LocalModelPicker: View {
    @ObservedObject var store: ConfigurationStore
    @ObservedObject var modelState: QwenModelState
    @ObservedObject var downloader: ModelDownloader
    @ObservedObject var importedActions: ImportedASRModelActions

    func selectPreset(_ preset: ModelPreset?, automatic: Bool = false) async {
        await modelState.selectPreset(preset, automatic: automatic)
    }

    var importedModels: ImportedASRModelList {
        ImportedASRModelList(store: store, coordinator: modelState, actions: importedActions)
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
                Menu("选择内置下载预设") {
                    Button("自动选择（推荐）") {
                        Task { await selectPreset(nil, automatic: true) }
                    }
                    ForEach(ImportedASRModelPresentation.downloadablePresets) { preset in
                        Button(preset.name) { Task { await selectPreset(preset) } }
                    }
                }.disabled(modelState.operationID != nil)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ImportedASRModelPresentation.downloadablePresets) { preset in
                        presetRow(preset)
                    }
                }

                Divider().opacity(0.5)

                importedModels
            }
            .padding(14)
            .glassCard(cornerRadius: 10)
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
                    Button("使用") {
                        Task { await selectPreset(preset) }
                    }.controlSize(.small).disabled(modelState.operationID != nil)
                    Button("删除") {
                        Task {
                            try? downloader.deleteModel(preset)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.red.opacity(0.8))
                    .disabled(modelState.operationID != nil)
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

    private func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 {
            let gb = mb / 1024
            return String(format: "%.1f GB", gb)
        }
        return String(format: "%.0f MB", mb)
    }
}
