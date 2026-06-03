import Foundation

enum PolishMode: String, Codable, CaseIterable, Identifiable {
    case raw
    case polish

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .raw: return "原文"
        case .polish: return "润色"
        }
    }

    /// Backward-compatible decode: old records stored light/structured/formal — fold to .polish.
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = (value == PolishMode.raw.rawValue) ? .raw : .polish
    }
}

struct DictationSession: Codable, Identifiable {
    let id: String
    let createdAt: Date
    let rawTranscript: String
    let finalText: String
    let polishMode: PolishMode
    let durationMs: UInt64?          // legacy end-to-end wall clock (kept for fallback)
    let recordingMs: UInt64?         // pure recording time (the speed fix)
    let appName: String?
    let appBundleID: String?
    let language: String?            // "zh" / "en" / "mixed" (CJK heuristic)

    init(rawTranscript: String, finalText: String, polishMode: PolishMode,
         durationMs: UInt64?, recordingMs: UInt64? = nil,
         appName: String? = nil, appBundleID: String? = nil, language: String? = nil) {
        self.id = UUID().uuidString
        self.createdAt = Date()
        self.rawTranscript = rawTranscript
        self.finalText = finalText
        self.polishMode = polishMode
        self.durationMs = durationMs
        self.recordingMs = recordingMs
        self.appName = appName
        self.appBundleID = appBundleID
        self.language = language
    }
}

/// Cheap per-session language tag from the final text: CJK-char ratio → "zh" / "en" / "mixed".
/// Works even when ASR language is "auto". Empty/whitespace → nil.
func detectLanguageTag(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    var cjk = 0, letters = 0
    for scalar in trimmed.unicodeScalars {
        if (0x4E00...0x9FFF).contains(scalar.value) || (0x3040...0x30FF).contains(scalar.value)
            || (0xAC00...0xD7AF).contains(scalar.value) { cjk += 1 }
        else if scalar.properties.isAlphabetic { letters += 1 }
    }
    let total = cjk + letters
    guard total > 0 else { return nil }
    let cjkRatio = Double(cjk) / Double(total)
    if cjkRatio > 0.8 { return "zh" }
    if cjkRatio < 0.2 { return "en" }
    return "mixed"
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var sessions: [DictationSession] = []

    private let store = PersistentStore<[DictationSession]>(filename: "history.json")
    private let maxEntries = 500
    private var saveDebounce: Task<Void, Never>?

    private init() {
        sessions = store.load() ?? []
    }

    func append(_ session: DictationSession) {
        sessions.insert(session, at: 0)
        if sessions.count > maxEntries {
            sessions = Array(sessions.prefix(maxEntries))
        }
        scheduleSave()

        // Always aggregate (sessions with no duration must still count toward chars/active-days/heatmap).
        let charCount = session.finalText.trimmingCharacters(in: .whitespacesAndNewlines).count
        let hour = Calendar.current.component(.hour, from: session.createdAt)
        DailyStatsStore.shared.recordSession(
            durationMs: session.durationMs ?? 0,
            recordingMs: session.recordingMs ?? 0,
            charCount: charCount,
            app: session.appName ?? "未知",
            language: session.language ?? "未知",
            hour: hour
        )
    }

    func delete(id: String) {
        sessions.removeAll { $0.id == id }
        scheduleSave()
    }

    func clear() {
        sessions.removeAll()
        scheduleSave()
    }

    private func scheduleSave() {
        saveDebounce?.cancel()
        saveDebounce = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self.store.save(self.sessions)
        }
    }
}
