import SwiftUI
import UniformTypeIdentifiers

struct HistoryPage: View {
    @ObservedObject private var historyStore: HistoryStore
    @StateObject private var model: HistoryPageModel
    @Environment(\.clientNavigationRequest) private var navigationRequest
    @State private var showRawTranscript = false

    init() {
        self.init(historyStore: .shared, copy: { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }, export: Self.saveExport)
    }

    /// Fully injected boundary for native previews and validation; does not resolve shared data.
    init(historyStore: HistoryStore, copy: @escaping @MainActor (String) -> Void,
         export: @escaping @MainActor (HistoryExport) -> Void) {
        self.historyStore = historyStore
        _model = StateObject(wrappedValue: HistoryPageModel(store: historyStore, copy: copy, export: export))
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            readStatus
            if let failure = model.mutationFailure {
                Label(failure.message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                Divider()
            }
            HSplitView {
                sessionList.frame(minWidth: 230, idealWidth: 270)
                detailPanel.frame(minWidth: 300)
            }
        }
        .onAppear { model.consume(navigationRequest) }
        .onChange(of: navigationRequest?.id) { _, _ in model.consume(navigationRequest) }
        .onChange(of: model.selectedID) { _, _ in showRawTranscript = false }
        .alert("清空历史文本", isPresented: Binding(get: { model.clearConfirmation }, set: { _ in })) {
            Button("清空历史文本", role: .destructive) { model.confirmClear() }
            Button("取消", role: .cancel) { model.cancelClear() }
        } message: {
            Text("清空所有历史文本？时长、字数、连续打卡等统计会保留。")
        }
        .alert("重置全部统计", isPresented: resetBinding(.first)) {
            Button("继续", role: .destructive) { model.continueReset() }
            Button("取消", role: .cancel) { model.cancelReset() }
        } message: {
            Text("即将删除全部历史记录与统计数据。")
        }
        .alert("无法撤销", isPresented: resetBinding(.final)) {
            Button("确认删除全部", role: .destructive) { model.confirmReset() }
            Button("取消", role: .cancel) { model.cancelReset() }
        } message: {
            Text("这会删除全部记录与统计，且不可恢复。")
        }
    }

    private func resetBinding(_ step: HistoryPageModel.ResetConfirmation) -> Binding<Bool> {
        // Alert actions own this state. SwiftUI may dismiss before running an action;
        // its binding write must not revoke the first confirmation before “继续”.
        Binding(get: { model.resetConfirmation == step }, set: { _ in })
    }

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("历史记录").font(.system(size: 18, weight: .semibold))
                Text("\(model.filteredSessions.count) 条").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("导出 CSV", action: model.exportCSV)
                    Button("导出 JSON", action: model.exportJSON)
                } label: { Label("导出", systemImage: "square.and.arrow.up") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.filteredSessions.isEmpty)
                Menu {
                    Button("清空历史文本…", role: .destructive) { model.requestClear() }
                    Divider()
                    Button("重置全部统计…", role: .destructive) { model.requestReset() }
                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("历史与统计操作") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            HStack(spacing: 12) {
                Picker("模式", selection: $model.filterMode) {
                    Text("全部").tag(Optional<PolishMode>.none)
                    ForEach(PolishMode.allCases) { Text($0.displayName).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
                TextField("搜索历史文本", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer(minLength: 0)
            }
        }
        .controlSize(.small)
        .font(.system(size: 12))
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder private var readStatus: some View {
        switch historyStore.readState {
        case .loading:
            HStack { ProgressView().controlSize(.small); Text("正在读取历史…"); Spacer() }
                .font(.system(size: 12)).padding(12)
        case .failed:
            HStack {
                Label("历史读取失败，已保留上次读取的内容。", systemImage: "exclamationmark.triangle")
                Spacer()
                Button("重试") { historyStore.reload() }
            }
            .font(.system(size: 12)).padding(12)
            Divider()
        case .loaded: EmptyView()
        }
    }

    private var sessionList: some View {
        List(model.filteredSessions, selection: $model.selectedID) { session in
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(session.polishMode.displayName).font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(session.createdAt, format: .dateTime.month().day().hour().minute())
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text(HistoryPresentation.canCopy(session) ? session.finalText : "文本已清除或未保存")
                    .font(.system(size: 12)).lineLimit(2)
                    .foregroundStyle(HistoryPresentation.canCopy(session) ? .primary : .secondary)
            }
            .padding(.vertical, 5)
            .tag(session.id)
            .contextMenu {
                Button("复制最终文本") { model.copy(session) }.disabled(!HistoryPresentation.canCopy(session))
                Button("导出文本…") { model.exportText(session) }.disabled(!HistoryPresentation.canExportText(session))
                Divider()
                Button("删除记录", role: .destructive) { model.delete(session) }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if model.filteredSessions.isEmpty, historyStore.readState == .loaded {
                Text(historyStore.sessions.isEmpty ? "还没有历史记录" : "没有符合条件的记录")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var detailPanel: some View {
        Group {
            if let session = model.selectedSession {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("最终文本").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Button { model.copy(session) } label: { Label("复制", systemImage: "doc.on.doc") }
                                .disabled(!HistoryPresentation.canCopy(session))
                        }
                        .controlSize(.small)
                        if HistoryPresentation.canCopy(session) {
                            Text(session.finalText).font(.system(size: 13)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(HistoryPresentation.missingTextExplanation)
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        if session.rawTranscript != session.finalText {
                            DisclosureGroup("原始识别", isExpanded: $showRawTranscript) {
                                Text(session.rawTranscript.isEmpty ? "原始文本已清除或未保存" : session.rawTranscript)
                                    .font(.system(size: 13)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                            }
                            .font(.system(size: 12))
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text(HistoryPresentation.deliveryLabel(session.deliveryOutcome))
                            Text(session.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                            Text("模式：\(session.polishMode.displayName)")
                            if let backend = session.sttBackend, !backend.isEmpty { Text("识别引擎：\(backend)") }
                            if let app = session.appName, !app.isEmpty { Text("目标应用：\(app)") }
                            if let ms = session.recordingMs { Text("录音：\(seconds(ms)) 秒") }
                            if let ms = session.durationMs { Text("总耗时：\(seconds(ms)) 秒") }
                            if let ms = session.asrMs { Text("识别：\(seconds(UInt64(max(0, ms)))) 秒") }
                            if let ms = session.polishMs { Text("整理：\(seconds(UInt64(max(0, ms)))) 秒") }
                            if let ms = session.stopToDeliveryMs { Text("停止至交付：\(seconds(UInt64(max(0, ms)))) 秒") }
                        }
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        HStack {
                            Button("导出文本…") { model.exportText(session) }
                                .disabled(!HistoryPresentation.canExportText(session))
                            Spacer()
                            Menu {
                                Button("删除记录", role: .destructive) { model.delete(session) }
                            } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("记录操作") }
                            .menuStyle(.borderlessButton).fixedSize()
                        }
                        .controlSize(.small)
                    }
                    .padding(20)
                }
            } else {
                Text("选择一条记录查看详情").font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func seconds(_ milliseconds: UInt64) -> String { String(format: "%.1f", Double(milliseconds) / 1000) }

    @MainActor private static func saveExport(_ export: HistoryExport) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: export.fileExtension) ?? .plainText]
        panel.nameFieldStringValue = "flowtype_history.\(export.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try export.data().write(to: url, options: .atomic) }
        catch { AppLogger.log("[HistoryPage] export failed: \(error)") }
    }
}
