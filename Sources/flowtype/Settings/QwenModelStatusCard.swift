import SwiftUI
import AppKit

/// Compact shared status and existing recovery actions; lifecycle belongs to QwenModelState.
struct QwenModelStatusCard: View {
    @ObservedObject var modelState: QwenModelState
    @ObservedObject var store: ConfigurationStore
    @ObservedObject var importedActions: ImportedASRModelActions
    var showsLibraryButton = true
    var onCancel: (() -> Void)? = nil
    @State private var showsLibrary = false

    var downloadSourceSelection: Binding<DownloadSource> {
        Binding(get: { store.current.downloadSource }, set: { store.current.downloadSource = $0 })
    }

    var modelLibrary: ImportedASRModelLibrarySheet {
        ImportedASRModelLibrarySheet(store: store, coordinator: modelState, actions: importedActions)
    }

    var selectionPresentation: LocalModelSelectionPresentation {
        .make(config: store.current, coordinator: modelState)
    }

    var body: some View {
        let selection = selectionPresentation
        let p = selection.recovery
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("已选", value: selection.selectedName)
                .foregroundStyle(.secondary)
            LabeledContent("已加载") {
                Text(selection.loaded.map {
                    "\($0.displayName) · \(ImportedASRModelPresentation.engineName($0.engine))"
                } ?? "尚未加载可用模型")
                    .foregroundStyle(selection.loaded == nil ? Color.secondary : Brand.accent)
            }
            if let fallback = p.fallbackLabel {
                Text("自动推荐\(fallback)").foregroundStyle(.orange)
            }
            if (selection.isBusy || modelState.failure != nil), let target = selection.targetName {
                LabeledContent(selection.isBusy ? "正在准备" : "失败目标", value: target)
                if let path = selection.targetPath {
                    Text(path).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                } else if let repo = p.repoID {
                    Text(repo).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            progressArea
            if let source = p.failureSourceName {
                Text("失败操作来源：\(source)").foregroundStyle(.secondary)
            }
            if let message = p.failureMessage {
                Text(modelState.importFailureDetail ?? message).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let assessment = modelState.hardwareAssessment, selection.isBusy || modelState.failure != nil {
                Text(assessment.explanation).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if p.actions.contains(.cancel) {
                    Button("取消准备") {
                        if let onCancel { onCancel() } else { modelState.cancel() }
                    }
                }
                if p.actions.contains(.retry), selection.selectionNeedsLoading || modelState.failure != nil {
                    Button(modelState.failure == nil ? "加载所选模型" : "重试目标模型") {
                        Task {
                            if modelState.failure == nil { await modelState.retryConfiguredModel() }
                            else { try? await ModelRecoveryActions(coordinator: modelState, store: store).retry() }
                        }
                    }
                }
                if p.actions.contains(.useSmallerModel), modelState.failure != nil {
                    Button("改用 0.6B") { Task { await modelState.selectPreset(.qwen306B) } }
                }
                if showsLibraryButton {
                    Button("导入与管理模型") { showsLibrary = true }.disabled(selection.isBusy)
                }
            }.controlSize(.small)
            DisclosureGroup("下载与离线恢复选项") {
                VStack(alignment: .leading, spacing: 8) {
                    sourcePicker
                    if let command = p.downloadCommand {
                        HStack {
                            Text("离线下载命令").foregroundStyle(.secondary)
                            Button("复制命令") { copy(command) }.buttonStyle(.borderless).controlSize(.small)
                        }
                        Text(command).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled).lineLimit(3).truncationMode(.middle)
                    }
                }.padding(.top, 6)
            }
        }
        .font(.system(size: 12))
        .sheet(isPresented: $showsLibrary) { modelLibrary }
    }

    @ViewBuilder private var progressArea: some View {
        if modelState.operationID != nil {
            if let source = modelState.operationSource {
                Text("本次来源：\(source.displayName)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            switch modelState.status {
            case .downloading(let progress, let speed, let eta):
                ProgressView(value: progress).progressViewStyle(.linear)
                Text("下载中 \(Int(progress * 100))% · \(String(format: "%.1f", speed)) MB/s\(eta > 0 ? " · 剩余约 \(eta)s" : "")")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            case .stalled:
                Text("下载已停滞，等待当前加载退出…").foregroundStyle(.orange)
            default:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在加载并验证模型；下载完成不等于加载成功。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("下载源").foregroundStyle(.secondary)
                Picker("下载源", selection: downloadSourceSelection) {
                    Text("自动").tag(DownloadSource.auto)
                    Text("官方").tag(DownloadSource.official)
                    Text("镜像").tag(DownloadSource.mirror)
                    if case .custom = store.current.downloadSource {
                        Text(store.current.downloadSource.displayName).tag(store.current.downloadSource)
                    }
                }.labelsHidden().frame(maxWidth: 220)
                Spacer()
            }
            Text("\(selectionPresentation.recovery.sourceName) · 所选下载源用于下一次操作。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}
