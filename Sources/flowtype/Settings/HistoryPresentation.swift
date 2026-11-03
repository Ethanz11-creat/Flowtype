import Foundation
import Combine

/// User-facing descriptions refer to recorded delivery events, never confirmed insertion.
enum HistoryPresentation {
    static func deliveryLabel(_ outcome: DeliveryOutcome?) -> String {
        switch outcome {
        case .typedDispatched: "已发送键入事件"
        case .pasteDispatched: "已发送粘贴事件"
        case .clipboard: "结果已写入剪贴板"
        case .uncertain: "无法确认是否输入；可复制结果"
        case .cancelled: "已取消"
        case nil: "无交付状态记录"
        }
    }

    static func canCopy(_ session: DictationSession) -> Bool {
        !session.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    static func canExportText(_ session: DictationSession) -> Bool { canCopy(session) }

    static let missingTextExplanation = "文本已清除或未保存，统计仍保留。"

    static func csv(_ sessions: [DictationSession]) -> String {
        let formatter = ISO8601DateFormatter()
        let rows: [String] = sessions.map { session in
            let count = session.storedCharacterCount.map { String($0) } ?? ""
            let recording = session.recordingMs.map { String($0) } ?? ""
            let fields: [String] = [formatter.string(from: session.createdAt), session.appName ?? "",
                                    session.language ?? "", count, recording, session.sttBackend ?? "", session.finalText]
            return fields.map(csvCell).joined(separator: ",")
        }
        return "startedAt,appName,language,charCount,recordingMs,sttBackend,finalText\n"
            + rows.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
    }

    private static func csvCell(_ value: String) -> String {
        var value = value.replacingOccurrences(of: "\"", with: "\"\"")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        if let first = value.first, ["=", "+", "-", "@", "\t"].contains(first) { value = "'" + value }
        return "\"\(value)\""
    }
}

enum HistoryExport {
    case csv([DictationSession]), json([DictationSession]), text(DictationSession)

    var fileExtension: String {
        switch self { case .csv: "csv"; case .json: "json"; case .text: "txt" }
    }

    func data() throws -> Data {
        switch self {
        case .csv(let sessions): Data(HistoryPresentation.csv(sessions).utf8)
        case .json(let sessions): try JSONEncoder().encode(sessions)
        case .text(let session): Data(session.finalText.utf8)
        }
    }
}

/// The page's actions are injected so isolated previews/tests never reach clipboard or save panels.
@MainActor
final class HistoryPageModel: ObservableObject {
    enum ResetConfirmation { case none, first, final }
    @Published var selectedID: String?
    @Published var searchText = ""
    @Published var filterMode: PolishMode?
    @Published private(set) var resetConfirmation: ResetConfirmation = .none
    @Published private(set) var navigationRequestID: UUID?
    private let store: HistoryStore
    private let copyText: @MainActor (String) -> Void
    private let export: @MainActor (HistoryExport) -> Void

    init(store: HistoryStore, copy: @escaping @MainActor (String) -> Void,
         export: @escaping @MainActor (HistoryExport) -> Void) {
        self.store = store
        copyText = copy
        self.export = export
    }

    var filteredSessions: [DictationSession] {
        store.currentSessions.filter { session in
            (filterMode == nil || session.polishMode == filterMode)
                && (searchText.isEmpty || session.finalText.localizedCaseInsensitiveContains(searchText)
                    || session.rawTranscript.localizedCaseInsensitiveContains(searchText))
        }
    }

    var selectedSession: DictationSession? { store.currentSessions.first { $0.id == selectedID } }

    func consume(_ request: NavigationRequest?) {
        guard let request, request.id != navigationRequestID,
              case .history(let id) = request.destination else { return }
        navigationRequestID = request.id
        guard let id, store.currentSessions.contains(where: { $0.id == id }) else { return }
        searchText = ""
        filterMode = nil
        selectedID = id
    }

    func copy(_ session: DictationSession) {
        guard let current = store.currentSessions.first(where: { $0.id == session.id }),
              HistoryPresentation.canCopy(current) else { return }
        copyText(current.finalText)
    }

    func exportText(_ session: DictationSession) {
        guard let current = store.currentSessions.first(where: { $0.id == session.id }),
              HistoryPresentation.canExportText(current) else { return }
        export(.text(current))
    }

    func exportCSV() { if !filteredSessions.isEmpty { export(.csv(filteredSessions)) } }
    func exportJSON() { if !filteredSessions.isEmpty { export(.json(filteredSessions)) } }
    func delete(_ session: DictationSession) {
        if store.delete(id: session.id), selectedID == session.id { selectedID = nil }
    }
    func requestReset() { resetConfirmation = .first }
    func continueReset() { if resetConfirmation == .first { resetConfirmation = .final } }
    func cancelReset() { resetConfirmation = .none }
    func confirmReset() {
        guard resetConfirmation == .final else { return }
        resetConfirmation = .none
        if store.resetAllStats() { selectedID = nil }
    }
}
