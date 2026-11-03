import SwiftUI
import AppKit

struct LocalModelPicker: View {
    @ObservedObject var store: ConfigurationStore
    @ObservedObject var modelState: QwenModelState
    @ObservedObject var downloader: ModelDownloader
    @ObservedObject var importedActions: ImportedASRModelActions
    @State private var deletionError: String?

    func selectPreset(_ preset: ModelPreset?, automatic: Bool = false) async {
        await modelState.selectPreset(preset, automatic: automatic)
    }

    func cancelPreparation() {
        if let current = downloader.currentDownload, downloader.isDownloading(preset: current.preset) {
            downloader.cancelDownload()
        } else { modelState.cancel() }
    }

    var importedModels: ImportedASRModelList {
        ImportedASRModelList(store: store, coordinator: modelState, actions: importedActions)
    }

    var selectionPresentation: LocalModelSelectionPresentation {
        .make(config: store.current, coordinator: modelState)
    }

    private var currentTier: HardwareTier { HardwareProfiler.currentTier() }
    var recommendedPreset: ModelPreset { ModelPreset.recommendedModel(for: currentTier) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            QwenModelStatusCard(modelState: modelState, store: store, importedActions: importedActions,
                                showsLibraryButton: false, onCancel: cancelPreparation)
            Divider()
            HStack {
                Text("内置模型").font(.system(size: 12, weight: .medium))
                Spacer()
                Button("按硬件推荐并加载") { Task { await selectPreset(nil, automatic: true) } }
                    .controlSize(.small).disabled(modelState.operationID != nil)
            }
            Text(ModelPreset.hardwareTierDescription(currentTier))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(ImportedASRModelPresentation.downloadablePresets) { preset in
                presetRow(preset)
                if preset.id != ImportedASRModelPresentation.downloadablePresets.last?.id { Divider() }
            }
            if let deletionError {
                Text(deletionError).font(.system(size: 11)).foregroundStyle(.orange)
            }
            Divider()
            importedModels
        }
        .padding(.top, 8)
    }

    private func presetRow(_ preset: ModelPreset) -> some View {
        let isPreparing = selectionPresentation.isBusy && selectionPresentation.targetID == preset.id
        let isDownloaded = downloader.isModelDownloaded(preset)
        let isRecommended = recommendedPreset.id == preset.id

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(preset.name).font(.system(size: 12, weight: .medium))
                        if isRecommended {
                            Text("推荐").font(.system(size: 11)).foregroundStyle(Brand.accent)
                        }
                    }
                    Text("\(preset.modelDescription) · 下载 \(formatBytes(preset.expectedSizeBytes))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(selectionPresentation.presetStatus(preset, filesDownloaded: isDownloaded))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if isPreparing {
                    Text("准备中").font(.system(size: 11)).foregroundStyle(Brand.accent)
                } else {
                    Button(isDownloaded ? "加载并使用" : "下载并加载") {
                        Task {
                            if isDownloaded { await selectPreset(preset) }
                            else { downloader.startDownload(preset: preset) }
                        }
                    }.controlSize(.small).disabled(modelState.operationID != nil)
                    if isDownloaded {
                        Button("删除下载") {
                            do { try downloader.deleteModel(preset); deletionError = nil }
                            catch { deletionError = "无法删除下载文件，请检查目录权限后重试。" }
                        }
                        .buttonStyle(.borderless).controlSize(.small)
                        .disabled(modelState.operationID != nil)
                    }
                }
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
