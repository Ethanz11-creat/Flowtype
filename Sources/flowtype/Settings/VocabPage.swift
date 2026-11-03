import SwiftUI

struct VocabPage: View {
    @ObservedObject private var store: DictionaryStore
    @State private var newPhrase = ""
    @State private var newNote = ""
    @State private var search = ""

    init() { self.init(store: .shared) }
    init(store: DictionaryStore) { self.store = store }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "词典", subtitle: "管理专有名词、备注与识别提示")
                VStack(alignment: .leading, spacing: 9) {
                    Text("添加词条").font(Theme.Typography.sectionTitle)
                    HStack(spacing: 8) {
                        TextField("专有名词，如 Claude、FlowType", text: $newPhrase)
                        TextField("备注（可选）", text: $newNote).frame(width: 170)
                        Button("添加", action: addEntry).buttonStyle(.borderedProminent)
                            .disabled(newPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("\(store.entries.count) 条 · 已启用 \(store.entries.filter(\.enabled).count) 条")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        TextField("搜索词条或备注", text: $search).textFieldStyle(.roundedBorder).frame(width: 230)
                    }
                    let entries = DictionaryPresentation.filtered(store.entries, search: search)
                    if entries.isEmpty {
                        Text(store.entries.isEmpty ? "还没有词条，添加常用专有名词作为识别与整理的参考。" : "没有匹配的词条")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 28)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                VocabRow(entry: entry, setEnabled: { store.setEnabled(id: entry.id, $0) },
                                         remove: { store.remove(id: entry.id) })
                                Divider()
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("启用的词条会作为识别和文本整理的提示；实际支持取决于所选引擎。")
                    Text("命中次数记录识别文本包含该词条的次数。禁用保留词条，删除会移除词条。")
                    Text("可在风格提示词中使用 {{HOTWORDS}} 指定词典注入位置。")
                }.font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: StatsConfig.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, StatsConfig.contentHorizontalPadding).padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private func addEntry() {
        guard DictionaryPresentation.add(phrase: newPhrase, note: newNote.isEmpty ? nil : newNote, to: store) else { return }
        newPhrase = ""; newNote = ""
    }
}

private struct VocabRow: View {
    let entry: DictionaryEntry
    let setEnabled: (Bool) -> Void
    let remove: () -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("启用 \(entry.phrase)", isOn: Binding(get: { entry.enabled }, set: { setEnabled($0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.phrase).font(.system(size: 13, weight: .medium))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let note = entry.note, !note.isEmpty {
                    Text(note).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                Text(entry.source == .manual ? "手动添加" : "自动发现")
                Text("命中 \(entry.hits) 次 · \(entry.enabled ? "已启用" : "已禁用")").monospacedDigit()
            }.font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("删除词条").accessibilityLabel("删除 \(entry.phrase)")
        }.padding(.vertical, 11)
    }
}

/// Display filtering and the page's add action do not change backend normalization.
enum DictionaryPresentation {
    static func enabledRatio(_ entries: [DictionaryEntry]) -> Double {
        entries.isEmpty ? 0 : Double(entries.filter(\.enabled).count) / Double(entries.count)
    }
    static func filtered(_ entries: [DictionaryEntry], search: String) -> [DictionaryEntry] {
        entries.filter { search.isEmpty || $0.phrase.localizedCaseInsensitiveContains(search)
            || ($0.note?.localizedCaseInsensitiveContains(search) ?? false) }
    }
    @MainActor @discardableResult
    static func add(phrase: String, note: String?, to store: DictionaryStore) -> Bool {
        guard !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        store.add(phrase: phrase, note: note)
        return true
    }
}
