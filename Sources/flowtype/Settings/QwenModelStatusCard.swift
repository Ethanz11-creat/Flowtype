import SwiftUI
import AppKit

struct QwenModelStatusCard: View {
    @ObservedObject private var modelState = QwenModelState.shared
    @ObservedObject private var store = ConfigurationStore.shared
    @State private var folderMessage: String?

    private var configuredPath: String? {
        [store.current.customLocalModelPath, store.current.localModelPath].compactMap { $0 }.first { !$0.isEmpty }
    }

    private var targetPreset: ModelPreset? {
        if case .preset(let preset) = modelState.target { return preset }
        if case .imported = modelState.target { return nil }
        if case .offline(let resolved) = modelState.target {
            return ModelPreset.allPresets.first { $0.repoId == resolved.modelId }
        }
        guard configuredPath == nil, store.current.activeImportedASRModelID == nil,
              modelState.pendingImportDirectory == nil else { return nil }
        return ModelPreset.preset(forID: store.current.selectedLocalModelID)
            ?? (store.current.selectedLocalModelID == nil ? ModelPreset.recommendedModel(for: HardwareProfiler.currentTier()) : nil)
    }

    private var targetPath: String? {
        switch modelState.target {
        case .preset: return nil
        case .offline(let resolved): return resolved.directory.path
        case .imported(let model): return model.directory.path
        case nil: return modelState.pendingImportDirectory?.path ?? configuredPath
        }
    }

    private var presentation: ModelRecoveryPresentation {
        ModelRecoveryPresentation.make(active: modelState.activeLease?.identity, target: targetPreset,
            failure: modelState.failure, didAutoFallback: modelState.didAutoFallback,
            source: store.current.downloadSource, isBusy: modelState.operationID != nil,
            customPath: targetPath, failureSource: modelState.operationSource)
    }

    var body: some View {
        let p = presentation
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: modelState.activeLease == nil ? "circle.dashed" : "checkmark.circle.fill")
                    .foregroundColor(modelState.activeLease == nil ? .orange : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.activeName.map { "可用模型：\($0)" } ?? "本地模型未就绪")
                        .font(.system(size: 13, weight: .medium))
                    if let fallback = p.fallbackLabel { Text(fallback).font(.system(size: 11)).foregroundColor(.orange) }
                    if let target = p.targetName {
                        Text("目标：\(target)").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    if let repo = p.repoID { Text(repo).font(.system(size: 10)).foregroundColor(.secondary) }
                }
                Spacer()
            }
            progressArea
            if let source = p.failureSourceName {
                Text("失败操作来源：\(source)").font(.system(size: 10)).foregroundColor(.secondary)
            }
            if let message = p.failureMessage {
                Text(modelState.importFailureDetail ?? message).font(.system(size: 11)).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if p.actions.contains(.cancel) {
                    Button("取消") { modelState.cancel() }.controlSize(.small)
                }
                if p.actions.contains(.retry) {
                    Button(modelState.failure == nil ? "加载目标模型" : "重试") {
                        Task {
                            try? await ModelRecoveryActions(coordinator: modelState, store: store).retry()
                        }
                    }.controlSize(.small)
                }
                if p.actions.contains(.useSmallerModel) {
                    Button("改用 0.6B") {
                        Task { await modelState.selectPreset(.qwen306B) }
                    }.controlSize(.small)
                }
            }
            Divider().opacity(0.5)
            sourcePicker
            if let command = p.downloadCommand {
                HStack {
                    Text("离线下载命令").font(.system(size: 10)).foregroundColor(.secondary)
                    Button("复制命令") { copy(command) }.buttonStyle(.borderless).controlSize(.small)
                }
                Text(command).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                    .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            }
            HStack {
                Button("指定模型文件夹") { pickModelFolder() }.controlSize(.small)
                    .disabled(modelState.operationID != nil)
                if let path = configuredPath {
                    Button("移除") {
                        ModelRecoveryActions(coordinator: modelState, store: store).removeFolderOverride()
                        folderMessage = nil
                    }.controlSize(.small).disabled(modelState.operationID != nil)
                    Text(path).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }
            Text(folderMessage ?? "指定已下载的模型文件夹，仅在离线加载成功后保存路径。")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
        .padding(14)
        .glassCard(cornerRadius: 10)
    }

    @ViewBuilder private var progressArea: some View {
        if modelState.operationID != nil {
            if let source = modelState.operationSource {
                Text("本次来源：\(source.displayName)").font(.system(size: 10)).foregroundColor(.secondary)
            }
            switch modelState.status {
            case .downloading(let progress, let speed, let eta):
                ProgressView(value: progress).progressViewStyle(.linear).frame(height: 4)
                Text("下载中 \(Int(progress * 100))% · \(String(format: "%.1f", speed)) MB/s\(eta > 0 ? " · 剩余约 \(eta)s" : "")")
                    .font(.system(size: 10)).foregroundColor(.secondary).monospacedDigit()
            case .stalled:
                Text("下载已停滞，等待当前加载退出…").font(.system(size: 11)).foregroundColor(.orange)
            default:
                ProgressView().progressViewStyle(.linear).frame(height: 4)
                Text("模型准备中…").font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("下载源").font(.system(size: 12)).foregroundColor(.secondary)
                Picker("下载源", selection: $store.current.downloadSource) {
                    Text("自动").tag(DownloadSource.auto)
                    Text("官方").tag(DownloadSource.official)
                    Text("镜像").tag(DownloadSource.mirror)
                    if case .custom = store.current.downloadSource {
                        Text(store.current.downloadSource.displayName).tag(store.current.downloadSource)
                    }
                }.labelsHidden().frame(maxWidth: 260)
                Spacer()
            }
            Text("\(presentation.sourceName) · 所选下载源用于下一次重试。")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private func pickModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "选择"; panel.message = "选择已下载的本地模型文件夹"
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

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}
