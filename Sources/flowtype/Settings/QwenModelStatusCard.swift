import SwiftUI
import AppKit

struct QwenModelStatusCard: View {
    @ObservedObject private var modelState = QwenModelState.shared
    @ObservedObject private var store = ConfigurationStore.shared
    @State private var showsLibrary = false

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
        case .uninspectedDirectory(let directory): return directory.path
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
                    Text(ImportedASRModelPresentation.availability(modelState.activeLease?.identity))
                        .font(.system(size: 13, weight: .medium))
                    if let fallback = p.fallbackLabel { Text(fallback).font(.system(size: 11)).foregroundColor(.orange) }
                    if let target = p.targetName {
                        Text("目标：\(targetDescription ?? target)").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    if let repo = p.repoID { Text(repo).font(.system(size: 10)).foregroundColor(.secondary) }
                }
                Spacer()
            }
            if let path = targetPath {
                Text(path).font(.system(size: 10)).foregroundColor(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
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
            Button("导入与管理本地 ASR 模型") { showsLibrary = true }
                .controlSize(.small).disabled(modelState.operationID != nil)
        }
        .padding(14)
        .glassCard(cornerRadius: 10)
        .sheet(isPresented: $showsLibrary) { ImportedASRModelLibrarySheet() }
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

    private var targetDescription: String? {
        guard case .imported(let model) = modelState.target else { return nil }
        return "\(model.name) · \(ImportedASRModelPresentation.engineName(model.engine.rawValue))"
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}
