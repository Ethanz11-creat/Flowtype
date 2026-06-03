import Foundation
import GRDB

struct SessionRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    static let databaseTableName = "session"
    var id: String
    var startedAt: Double          // Unix seconds
    var recordingMs: Int64
    var durationMs: Int64
    var charCount: Int
    var language: String?
    var appName: String?
    var appBundleID: String?
    var polishMode: String
    var sttBackend: String
    var rawTranscript: String?
    var finalText: String?

    init(from s: DictationSession) {
        self.id = s.id
        self.startedAt = s.createdAt.timeIntervalSince1970
        self.recordingMs = Int64(s.recordingMs ?? 0)
        self.durationMs = Int64(s.durationMs ?? 0)
        self.charCount = s.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).count  // 原始识别字数（不是润色后）
        self.language = s.language
        self.appName = s.appName
        self.appBundleID = s.appBundleID
        self.polishMode = s.polishMode.rawValue
        self.sttBackend = s.sttBackend ?? "legacy"   // migrated old rows have no backend
        self.rawTranscript = s.rawTranscript
        self.finalText = s.finalText
    }

    func toDictationSession() -> DictationSession {
        DictationSession(id: id,
                         createdAt: Date(timeIntervalSince1970: startedAt),
                         rawTranscript: rawTranscript ?? "",
                         finalText: finalText ?? "",
                         polishMode: PolishMode(rawValue: polishMode) ?? .polish,
                         durationMs: durationMs > 0 ? UInt64(durationMs) : nil,
                         recordingMs: recordingMs > 0 ? UInt64(recordingMs) : nil,
                         appName: appName, appBundleID: appBundleID,
                         language: language, sttBackend: sttBackend)
    }
}

struct DailyLegacyRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "daily_legacy"
    var date: String
    var totalDurationMs: Int64
    var totalRecordingMs: Int64
    var totalWordCount: Int
    var sessionCount: Int
    var byApp: String          // JSON {String:Int}
    var byLang: String         // JSON {String:Int}
    var hourHistogram: String  // JSON [Int]

    init(from d: DailyStats) {
        self.date = d.date
        self.totalDurationMs = Int64(d.totalDurationMs)
        self.totalRecordingMs = Int64(d.totalRecordingMs)
        self.totalWordCount = d.totalWordCount
        self.sessionCount = d.sessionCount
        self.byApp = Self.encode(d.byApp)
        self.byLang = Self.encode(d.byLang)
        self.hourHistogram = Self.encodeArr(d.hourHistogram)
    }

    func toDailyStats() -> DailyStats {
        DailyStats(date: date,
                   totalDurationMs: UInt64(max(0, totalDurationMs)),
                   totalWordCount: totalWordCount,
                   sessionCount: sessionCount,
                   totalRecordingMs: UInt64(max(0, totalRecordingMs)),
                   byApp: Self.decode(byApp),
                   byLang: Self.decode(byLang),
                   hourHistogram: Self.decodeArr(hourHistogram))
    }

    static func encode(_ d: [String: Int]) -> String { (try? String(data: JSONEncoder().encode(d), encoding: .utf8) ?? "{}") ?? "{}" }
    static func encodeArr(_ a: [Int]) -> String { (try? String(data: JSONEncoder().encode(a), encoding: .utf8) ?? "[]") ?? "[]" }
    static func decode(_ s: String) -> [String: Int] { (try? JSONDecoder().decode([String: Int].self, from: Data(s.utf8))) ?? [:] }
    static func decodeArr(_ s: String) -> [Int] {
        let a = (try? JSONDecoder().decode([Int].self, from: Data(s.utf8))) ?? []
        return a.count == 24 ? a : Array(repeating: 0, count: 24)
    }
}
