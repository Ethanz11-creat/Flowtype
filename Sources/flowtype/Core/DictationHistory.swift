import Foundation
import GRDB

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
    let sttBackend: String?

    init(rawTranscript: String, finalText: String, polishMode: PolishMode,
         durationMs: UInt64?, recordingMs: UInt64? = nil,
         appName: String? = nil, appBundleID: String? = nil, language: String? = nil,
         sttBackend: String? = nil) {
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
        self.sttBackend = sttBackend
    }

    init(id: String, createdAt: Date, rawTranscript: String, finalText: String, polishMode: PolishMode,
         durationMs: UInt64?, recordingMs: UInt64?, appName: String?, appBundleID: String?,
         language: String?, sttBackend: String?) {
        self.id = id; self.createdAt = createdAt
        self.rawTranscript = rawTranscript; self.finalText = finalText; self.polishMode = polishMode
        self.durationMs = durationMs; self.recordingMs = recordingMs
        self.appName = appName; self.appBundleID = appBundleID; self.language = language; self.sttBackend = sttBackend
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
    private let db = AppDatabaseProvider.shared

    private init() { reload() }

    func reload() {
        do {
            let recs = try db.dbQueue.read { try SessionRecord.order(Column("startedAt").desc).fetchAll($0) }
            sessions = recs.map { $0.toDictationSession() }
        } catch { AppLogger.log("[History] reload failed: \(error)"); sessions = [] }
    }

    /// Insert one session. `charCount` is computed before nulling text, so stats survive privacy-off.
    func append(_ session: DictationSession, storeText: Bool) {
        var rec = SessionRecord(from: session)
        if !storeText { rec.rawTranscript = nil; rec.finalText = nil }
        do { try db.dbQueue.write { try rec.insert($0) } } catch { AppLogger.log("[History] insert failed: \(error)") }
        reload()
        DailyStatsStore.shared.refresh()
    }

    func delete(id: String) {
        try? db.dbQueue.write { _ = try SessionRecord.deleteOne($0, key: id) }
        reload(); DailyStatsStore.shared.refresh()
    }

    /// 清空历史 (privacy): erase transcripts, keep metadata rows → stats/streaks survive.
    func clearTranscripts() {
        try? db.dbQueue.write { try $0.execute(sql: "UPDATE session SET rawTranscript=NULL, finalText=NULL") }
        reload()
    }

    /// 重置统计 (destruction): delete all rows incl. frozen legacy aggregates.
    func resetAllStats() {
        try? db.dbQueue.write { d in
            try d.execute(sql: "DELETE FROM session")
            try d.execute(sql: "DELETE FROM daily_legacy")
        }
        reload(); DailyStatsStore.shared.refresh()
    }
}
