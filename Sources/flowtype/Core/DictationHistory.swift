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

struct DictationSession: Codable, Identifiable, Equatable {
    let id: String
    let createdAt: Date
    var rawTranscript: String
    var finalText: String
    let polishMode: PolishMode
    let durationMs: UInt64?          // legacy end-to-end wall clock (kept for fallback)
    let recordingMs: UInt64?         // pure recording time (the speed fix)
    let appName: String?
    let appBundleID: String?
    let language: String?            // "zh" / "en" / "mixed" (CJK heuristic)
    let sttBackend: String?

    // MARK: - Metrics (no content)
    var asrProviderID: String?
    var usedFallback: Bool?
    var fallbackReason: String?
    var asrMs: Int?
    var polishMs: Int?
    var injectMs: Int?
    var stopToInjectMs: Int?
    var deliveryOutcome: DeliveryOutcome?
    var stopToDeliveryMs: Int?
    /// Persisted count survives transcript removal; populated by HistoryStore reads.
    var storedCharacterCount: Int?

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

/// Cheap per-session language tag from the final text: CJK-char ratio → "zh" / "ja" / "ko" /
/// "en" / "mixed". Works even when ASR language is "auto". Empty/whitespace → nil.
/// Kana/Hangul stay inside the CJK bucket for the ratio (they are also Alphabetic — moving
/// them to `letters` would mislabel Japanese as "en"), then split the CJK-dominant case.
func detectLanguageTag(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    var han = 0, kana = 0, hangul = 0, letters = 0
    for scalar in trimmed.unicodeScalars {
        if (0x4E00...0x9FFF).contains(scalar.value) { han += 1 }
        else if (0x3040...0x30FF).contains(scalar.value) { kana += 1 }
        else if (0xAC00...0xD7AF).contains(scalar.value) { hangul += 1 }
        else if scalar.properties.isAlphabetic { letters += 1 }
    }
    let cjk = han + kana + hangul
    let total = cjk + letters
    guard total > 0 else { return nil }
    let cjkRatio = Double(cjk) / Double(total)
    if cjkRatio > 0.8 {
        // Japanese intermixes kanji with kana; Chinese never contains kana.
        if kana > 0, kana * 4 >= han { return "ja" }
        if hangul > han { return "ko" }
        return "zh"
    }
    if cjkRatio < 0.2 { return "en" }
    return "mixed"
}

enum HistoryReadState: Equatable {
    case loading, loaded, failed(String)
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore(database: AppDatabaseProvider.shared,
                                     refreshStats: { DailyStatsStore.shared.refresh() })
    @Published private(set) var sessions: [DictationSession] = []
    // Actions consult committed state, including during @Published's willSet notifications.
    private(set) var currentSessions: [DictationSession] = []
    private var publishingSessions = false
    private var readGeneration = 0
    @Published private(set) var readState: HistoryReadState = .loading
    private var committedReadState: HistoryReadState = .loading
    private var publishingReadState = false
    private let db: AppDatabase
    private let readSessions: @MainActor () throws -> [DictationSession]
    private let refreshStats: @MainActor () -> Void

    init(database: AppDatabase,
         readSessions: (@MainActor () throws -> [DictationSession])? = nil,
         refreshStats: @escaping @MainActor () -> Void) {
        db = database
        self.refreshStats = refreshStats
        self.readSessions = readSessions ?? {
            try database.dbQueue.read {
                try SessionRecord.order(Column("startedAt").desc).fetchAll($0).map { record in
                    var session = record.toDictationSession()
                    session.storedCharacterCount = record.charCount
                    return session
                }
            }
        }
        reload()
    }

    func reload() {
        readGeneration += 1
        let generation = readGeneration
        replaceReadState(.loading)
        guard generation == readGeneration else { return }
        do {
            let updated = try readSessions()
            guard generation == readGeneration else { return }
            replaceSessions(updated)
            // A publication subscriber may have committed a mutation and reloaded.
            guard generation == readGeneration else { return }
            replaceReadState(.loaded)
        } catch {
            guard generation == readGeneration else { return }
            AppLogger.log("[History] reload failed: \(error)")
            // Keep the latest committed snapshot, including successful privacy mutations.
            replaceReadState(.failed(error.localizedDescription))
        }
    }

    /// Insert one session. `charCount` is computed before nulling text, so stats survive privacy-off.
    func append(_ session: DictationSession, storeText: Bool) {
        var rec = SessionRecord(from: session, storeText: storeText)
        do { try db.dbQueue.write { try rec.insert($0) } } catch { AppLogger.log("[History] insert failed: \(error)") }
        reload()
        refreshStats()
    }

    @discardableResult
    func delete(id: String) -> Bool {
        do {
            try db.dbQueue.write { _ = try SessionRecord.deleteOne($0, key: id) }
        } catch {
            AppLogger.log("[History] delete failed: \(error)")
            return false
        }
        replaceSessions(currentSessions.filter { $0.id != id })
        reload()
        refreshStats()
        return true
    }

    /// 清空历史 (privacy): erase transcripts, keep metadata rows → stats/streaks survive.
    @discardableResult
    func clearTranscripts() -> Bool {
        do {
            try db.dbQueue.write { try $0.execute(sql: "UPDATE session SET rawTranscript=NULL, finalText=NULL") }
        } catch {
            AppLogger.log("[History] clear transcripts failed: \(error)")
            return false
        }
        replaceSessions(currentSessions.map { session in
            var session = session
            session.rawTranscript = ""
            session.finalText = ""
            return session
        })
        reload()
        return true
    }

    /// 重置统计 (destruction): delete all rows incl. frozen legacy aggregates.
    @discardableResult
    func resetAllStats() -> Bool {
        do {
            try db.dbQueue.write { d in
                try d.execute(sql: "DELETE FROM session")
                try d.execute(sql: "DELETE FROM daily_legacy")
            }
        } catch {
            AppLogger.log("[History] reset failed: \(error)")
            return false
        }
        replaceSessions([])
        reload()
        refreshStats()
        return true
    }

    private func replaceReadState(_ updated: HistoryReadState) {
        committedReadState = updated
        guard !publishingReadState else { return }
        publishingReadState = true
        // A subscriber may start a newer reload during willSet. Reconcile the
        // presentation after the older assignment resumes, including failure details.
        repeat { readState = committedReadState } while readState != committedReadState
        publishingReadState = false
    }

    private func replaceSessions(_ updated: [DictationSession]) {
        currentSessions = updated
        guard !publishingSessions else { return }
        publishingSessions = true
        // A subscriber may perform another mutation. Its committed snapshot wins over
        // the outer @Published assignment, without exposing pre-mutation action data.
        repeat { sessions = currentSessions } while sessions != currentSessions
        publishingSessions = false
    }
}
