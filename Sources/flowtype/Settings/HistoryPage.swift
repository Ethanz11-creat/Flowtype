import SwiftUI

struct HistoryPage: View {
    @ObservedObject private var historyStore = HistoryStore.shared
    @State private var selectedID: String?
    @State private var searchText: String = ""
    @State private var filterMode: PolishMode?
    @State private var showClearTranscriptsConfirm = false
    @State private var showResetStatsConfirm1 = false
    @State private var showResetStatsConfirm2 = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            HSplitView {
                sessionList
                    .frame(minWidth: 240, idealWidth: 280)
                detailPanel
                    .frame(minWidth: 300)
            }
        }
        // 清空历史：one-step confirm — erases text, keeps stats
        .alert("清空历史文本", isPresented: $showClearTranscriptsConfirm) {
            Button("清空历史文本", role: .destructive) { historyStore.clearTranscripts() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清空所有历史文本？时长、字数、连续打卡等统计会保留。")
        }
        // 重置统计：first confirmation
        .alert("重置全部统计", isPresented: $showResetStatsConfirm1) {
            Button("继续", role: .destructive) {
                showResetStatsConfirm1 = false
                showResetStatsConfirm2 = true
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("即将删除全部历史记录与统计数据。")
        }
        // 重置统计：second (final) confirmation
        .alert("无法撤销", isPresented: $showResetStatsConfirm2) {
            Button("确认删除全部", role: .destructive) {
                selectedID = nil
                historyStore.resetAllStats()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会删除全部记录与统计，且不可恢复。")
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            PageHeader(title: "历史记录", subtitle: "共 \(filteredSessions.count) 条")

            Spacer()

            Picker("", selection: $filterMode) {
                Text("全部").tag(Optional<PolishMode>.none)
                ForEach(PolishMode.allCases) { mode in
                    Text(mode.displayName).tag(Optional(mode))
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)

            TextField("搜索...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)

            Button {
                exportSessions()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(filteredSessions.isEmpty)

            // 清空历史（保留统计）
            Button(role: .destructive) {
                showClearTranscriptsConfirm = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("清空历史文本（保留统计）")
            .disabled(historyStore.sessions.isEmpty)

            // 重置统计（危险，需两次确认）
            Button(role: .destructive) {
                showResetStatsConfirm1 = true
            } label: {
                Image(systemName: "xmark.bin")
            }
            .buttonStyle(.borderless)
            .help("重置全部统计（不可撤销）")
            .disabled(historyStore.sessions.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - List

    private var filteredSessions: [DictationSession] {
        historyStore.sessions.filter { session in
            if let mode = filterMode, session.polishMode != mode { return false }
            if !searchText.isEmpty {
                let query = searchText.lowercased()
                return session.finalText.lowercased().contains(query) ||
                       session.rawTranscript.lowercased().contains(query)
            }
            return true
        }
    }

    private var sessionList: some View {
        List(filteredSessions, selection: $selectedID) { session in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(session.polishMode.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(pillColor(session.polishMode))
                        .clipShape(Capsule())

                    Spacer()

                    Text(formatDate(session.createdAt))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Text(session.finalText.isEmpty ? "(文本已清除)" : session.finalText)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .foregroundColor(session.finalText.isEmpty ? .secondary : .primary)

                if let ms = session.durationMs {
                    Text("\(String(format: "%.1f", Double(ms) / 1000))s")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
            .tag(session.id)
            .contextMenu {
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.finalText, forType: .string)
                }
                Divider()
                Button("删除", role: .destructive) {
                    if selectedID == session.id { selectedID = nil }
                    historyStore.delete(id: session.id)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Detail

    private var selectedSession: DictationSession? {
        guard let id = selectedID else { return nil }
        return historyStore.sessions.first(where: { $0.id == id })
    }

    private var detailPanel: some View {
        Group {
            if let session = selectedSession {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(session.polishMode.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(pillColor(session.polishMode))
                                .clipShape(Capsule())

                            Spacer()

                            Text(formatDateFull(session.createdAt))
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }

                        if session.rawTranscript != session.finalText {
                            DetailSection(title: "原始识别",
                                         text: session.rawTranscript.isEmpty ? "(文本已清除)" : session.rawTranscript,
                                         isCleared: session.rawTranscript.isEmpty)
                        }

                        DetailSection(title: "最终文本",
                                      text: session.finalText.isEmpty ? "(文本已清除)" : session.finalText,
                                      isCleared: session.finalText.isEmpty)

                        HStack(spacing: 12) {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(session.finalText, forType: .string)
                            } label: {
                                Label("复制", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button(role: .destructive) {
                                selectedID = nil
                                historyStore.delete(id: session.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(20)
                }
            } else {
                VStack {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("选择一条记录查看详情")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Helpers

    private func pillColor(_ mode: PolishMode) -> Color {
        switch mode {
        case .raw: return .secondary
        case .polish: return Brand.accent
        }
    }

    private static let listDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter
    }()

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private func formatDate(_ date: Date) -> String {
        Self.listDateFormatter.string(from: date)
    }

    private func formatDateFull(_ date: Date) -> String {
        Self.fullDateFormatter.string(from: date)
    }

    private func exportSessions() {
        let sessions = filteredSessions
        guard !sessions.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json, .plainText]
        panel.nameFieldStringValue = "flowtype_history_\(formatDateFile(Date()))"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let ext = url.pathExtension.lowercased()
        do {
            if ext == "json" {
                let data = try JSONEncoder().encode(sessions)
                try data.write(to: url)
            } else {
                // CSV with formula injection protection
                var csv = "startedAt,appName,language,charCount,recordingMs,sttBackend,finalText\n"
                for session in sessions {
                    let startedAt = sanitizeCSVCell(formatDateFull(session.createdAt))
                    let appName = sanitizeCSVCell(session.appName ?? "")
                    let language = sanitizeCSVCell(session.language ?? "")
                    let charCount = sanitizeCSVCell(String(session.finalText.trimmingCharacters(in: .whitespacesAndNewlines).count))
                    let recordingMs = sanitizeCSVCell(session.recordingMs.map { String($0) } ?? "")
                    let sttBackend = sanitizeCSVCell(session.sttBackend ?? "")
                    let text = sanitizeCSVCell(session.finalText)
                    csv += "\(startedAt),\(appName),\(language),\(charCount),\(recordingMs),\(sttBackend),\(text)\n"
                }
                try csv.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            AppLogger.log("[HistoryPage] Export failed: \(error)")
        }
    }

    private func sanitizeCSVCell(_ value: String) -> String {
        var sanitized = value.replacingOccurrences(of: "\"", with: "\"\"")
        // Replace newlines to preserve CSV row structure
        sanitized = sanitized.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        // Protect against formula injection by prefixing dangerous leading chars
        if let first = sanitized.first,
           ["=", "+", "-", "@"].contains(first) || first == "\t" {
            sanitized = "'" + sanitized
        }
        return "\"\(sanitized)\""
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()

    private func formatDateFile(_ date: Date) -> String {
        Self.fileDateFormatter.string(from: date)
    }
}

private struct DetailSection: View {
    let title: String
    let text: String
    var isCleared: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            textContent
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: 8)
        }
    }

    @ViewBuilder private var textContent: some View {
        if isCleared {
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .italic()
                .textSelection(.disabled)
        } else {
            Text(text)
                .font(.system(size: 13))
                .textSelection(.enabled)
        }
    }
}
