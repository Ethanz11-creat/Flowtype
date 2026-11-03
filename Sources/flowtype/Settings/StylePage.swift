import SwiftUI
import AppKit

struct StylePage: View {
    @ObservedObject private var store: StylePackStore
    @StateObject private var model: StylePageModel
    @Environment(\.clientNavigationRequest) private var request
    @State private var showNewSheet = false
    @State private var showImportSheet = false
    private let export: (StylePack, Data) async throws -> Void

    init() { self.init(store: .shared, export: Self.exportWithPanel) }

    /// Explicit stores and file effects make the actual page safe for isolated native previews.
    init(store: StylePackStore, model: StylePageModel? = nil,
         export: @escaping (StylePack, Data) async throws -> Void) {
        self.store = store
        _model = StateObject(wrappedValue: model ?? StylePageModel(store: store))
        self.export = export
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    Text(StylePresentation.effectiveSource(pack: store.activePack, configuration: .default))
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    VStack(spacing: 0) {
                        ForEach(store.packs) { pack in
                            styleRow(pack).id(pack.id)
                            Divider()
                        }
                    }
                    Text("切换风格只更改后续整理使用的提示词，不会发起网络请求。提示词可在详情中编辑。")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: StatsConfig.contentMaxWidth, alignment: .leading)
                .padding(.horizontal, StatsConfig.contentHorizontalPadding).padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .task(id: model.navigationRequestID) {
                await Task.yield()
                guard !Task.isCancelled, let id = model.selectedID else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
        .onChange(of: request, initial: true) { _, request in model.consume(request) }
        .sheet(isPresented: $showNewSheet) { newPackSheet }
        .sheet(item: $model.editingPack) { pack in
            StylePackEditor(pack: pack) { updated in
                store.save(updated)
                model.editingPack = nil
            } onCancel: { model.editingPack = nil }
        }
        .fileImporter(isPresented: $showImportSheet, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                model.importData(try Data(contentsOf: url))
            } catch { model.importExportError = "导入失败：\(error.localizedDescription)" }
        }
        .alert("操作失败", isPresented: Binding(get: { model.importExportError != nil },
            set: { if !$0 { model.importExportError = nil } })) {
                Button("好") { model.importExportError = nil }
            } message: { Text(model.importExportError ?? "") }
    }

    private var header: some View {
        HStack(spacing: 10) {
            PageHeader(title: "风格", subtitle: "选择文本整理的用途与表达方式")
            Spacer()
            Button { showImportSheet = true } label: { Label("导入", systemImage: "square.and.arrow.down") }
            Button {
                model.newName = ""; model.newPrompt = ""; showNewSheet = true
            } label: { Label("新建", systemImage: "plus") }.buttonStyle(.borderedProminent)
        }.controlSize(.small)
    }

    private func styleRow(_ pack: StylePack) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(pack.name).font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(pack.kind == .builtin ? "内置" : pack.kind == .imported ? "导入" : "自定义")
                        .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                }
                Text(pack.description.isEmpty ? "自定义整理提示词" : pack.description)
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if store.activePack?.id == pack.id {
                Label("当前生效", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(Theme.accentText)
            } else {
                Button(pack.enabled ? "设为当前" : "已禁用") { store.setActive(id: pack.id) }
                    .disabled(!pack.enabled).controlSize(.small)
            }
            Button("详情") { model.editingPack = pack }.controlSize(.small)
            Menu {
                Button("导出 JSON") { exportPack(pack) }
                if pack.kind != .builtin {
                    Divider()
                    Button("删除", role: .destructive) { store.delete(id: pack.id) }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().help("更多风格操作")
        }
        .padding(.vertical, 15).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(model.selectedID == pack.id ? Theme.accent.opacity(0.08) : .clear))
    }

    private var newPackSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建风格").font(.system(size: 16, weight: .semibold))
            TextField("名称", text: $model.newName).textFieldStyle(.roundedBorder)
            Text("提示词").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            TextEditor(text: $model.newPrompt).font(.system(size: 12)).frame(minHeight: 200)
                .padding(4).background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.cardBorder))
            Text("可使用 {{HOTWORDS}} 占位符控制词典注入位置")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { showNewSheet = false }
                Button("创建") {
                    _ = store.createCustom(name: model.newName, prompt: model.newPrompt)
                    showNewSheet = false
                }.buttonStyle(.borderedProminent)
                    .disabled(model.newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 500, height: 420)
    }

    private func exportPack(_ pack: StylePack) {
        guard let data = store.exportToJSON(id: pack.id) else {
            model.importExportError = "导出失败：无法生成 JSON 数据"; return
        }
        Task {
            do { try await export(pack, data) }
            catch { model.importExportError = "导出失败：\(error.localizedDescription)" }
        }
    }

    @MainActor private static func exportWithPanel(_ pack: StylePack, data: Data) async throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(pack.name).json"
        panel.allowedContentTypes = [.json]
        let response = await panel.begin()
        if response == .OK, let url = panel.url { try data.write(to: url) }
    }
}

// MARK: - Editor

private struct StylePackEditor: View {
    @State private var name: String
    @State private var description: String
    @State private var prompt: String
    private let pack: StylePack
    private let onSave: (StylePack) -> Void
    private let onCancel: () -> Void

    init(pack: StylePack, onSave: @escaping (StylePack) -> Void, onCancel: @escaping () -> Void) {
        self.pack = pack
        self._name = State(initialValue: pack.name)
        self._description = State(initialValue: pack.description)
        self._prompt = State(initialValue: pack.prompt)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(pack.kind == .builtin ? "内置风格详情" : "编辑风格")
                .font(.system(size: 16, weight: .bold))

            TextField("名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .disabled(pack.kind == .builtin)

            TextField("用途描述", text: $description)
                .textFieldStyle(.roundedBorder)

            Text("提示词")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            TextEditor(text: $prompt)
                .font(.system(size: 12))
                .frame(minHeight: 200)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .buttonStyle(.bordered)
                Button("保存") {
                    var updated = pack
                    updated.name = name
                    updated.description = description
                    updated.prompt = prompt
                    onSave(updated)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 500, height: 460)
    }
}
