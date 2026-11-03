import SwiftUI
import AppKit

struct ImportedASRModelList: View {
    @ObservedObject var store: ConfigurationStore
    @ObservedObject var coordinator: QwenModelState
    @ObservedObject var actions: ImportedASRModelActions

    private var busy: Bool { coordinator.operationID != nil || actions.isInspecting }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("导入的 ASR 模型").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("导入本地 ASR 模型") { pickDirectory() }
                    .controlSize(.small).disabled(busy)
            }
            if store.current.importedASRModels.isEmpty {
                Text("尚未添加模型。选择目录后先检查，确认后再加载。")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            ForEach(store.current.importedASRModels) { model in
                modelRow(model)
            }
            if actions.isInspecting {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在检查本地文件…").font(.system(size: 11))
                    Button("取消检查") { actions.cancelInspection() }.controlSize(.small)
                }
            }
            if let preview = actions.preview {
                previewCard(preview)
            }
            if let message = actions.message {
                Text(message).font(.system(size: 11)).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Text(ImportedASRModelPresentation.importHelp)
                .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("来源示例（需自行下载完整兼容目录和分词器）：")
                .font(.system(size: 10)).foregroundColor(.secondary)
            ForEach(ImportedASRModelPresentation.sources, id: \.url) { source in
                Link(source.name, destination: source.url).font(.system(size: 10))
            }
            Text(ImportedASRModelPresentation.removalHelp)
                .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear { actions.cancelInspection() }
    }

    private func modelRow(_ model: ImportedASRModel) -> some View {
        let assessment = LocalModelHardwareAssessment.current(model: model, activeModelBytes: coordinator.activeLease?.minimumResidentBytes)
        let p = ImportedASRModelPresentation.make(model: model, assessment: assessment,
            isActive: coordinator.activeLease?.identity.id == model.id.uuidString)
        let exists = FileManager.default.fileExists(atPath: model.directory.path)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(p.name).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(p.status).font(.system(size: 10)).foregroundColor(.secondary)
            }
            Text("\(p.format) · 磁盘 \(p.size)").font(.system(size: 11))
            Text(p.source).font(.system(size: 10)).foregroundColor(.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            if !exists {
                Text("目录不存在，请重新定位；原选择不会被自动替换。")
                    .font(.system(size: 11)).foregroundColor(.orange)
            }
            DisclosureGroup("硬件建议与兼容性") {
                Text(p.hardwareAdvice).font(.system(size: 10)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 10))
            HStack {
                Button("检查并切换") { actions.stageExisting(id: model.id) }
                    .disabled(busy || !exists || !p.actions.contains(.load))
                Button("重新定位") { pickDirectory(replacing: model.id) }.disabled(busy)
                Button("移除记录") { actions.remove(id: model.id) }.disabled(busy)
            }.controlSize(.small)
        }
        .padding(10).background(Color.secondary.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func previewCard(_ preview: ImportedASRModelActions.Preview) -> some View {
        let p = ImportedASRModelPresentation.make(model: preview.model, assessment: preview.assessment, isActive: false)
        return VStack(alignment: .leading, spacing: 7) {
            Text("检测结果 · \(p.name)").font(.system(size: 12, weight: .semibold))
            Text("\(p.format) · 磁盘 \(p.size)").font(.system(size: 11))
            Text(p.source).font(.system(size: 10)).textSelection(.enabled)
            Text("静态文件检查通过；尚未保存或启用。实际模型图、运行内存与识别能力需加载验证。")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Text(p.hardwareAdvice).font(.system(size: 11)).foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("加载并使用") { Task { await actions.loadPreview() } }
                    .disabled(coordinator.operationID != nil || !p.actions.contains(.load))
                if coordinator.operationID != nil {
                    Button("取消加载") { coordinator.cancel() }
                } else {
                    Button("放弃预览") { actions.cancelInspection() }
                }
            }.controlSize(.small)
        }
        .padding(12).background(Brand.accent.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func pickDirectory(replacing id: UUID? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "检查目录"
        panel.message = "选择完整的 Qwen MLX 或 WhisperKit Core ML 模型目录；选择后不会立即加载。"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        actions.stage(directory: directory, replacing: id)
    }
}

struct ImportedASRModelLibrarySheet: View {
    @ObservedObject var store: ConfigurationStore
    @ObservedObject var coordinator: QwenModelState
    @ObservedObject var actions: ImportedASRModelActions
    var modelList: ImportedASRModelList {
        ImportedASRModelList(store: store, coordinator: coordinator, actions: actions)
    }

    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            ScrollView { modelList.padding(4) }
            Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(20).frame(width: 600, height: 560)
    }
}
