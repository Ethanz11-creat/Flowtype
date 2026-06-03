import Foundation
import GRDB

enum JSONMigration {
    static func hasMigrated(_ db: AppDatabase) -> Bool {
        ((try? db.dbQueue.read { try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key='migrationDate'") }) ?? nil) != nil
    }

    /// Pure import (testable): insert sessions + legacy days, set migrationDate. Caller wraps with file IO.
    static func importInto(_ db: AppDatabase, sessions: [DictationSession], daily: [DailyStats], migrationDay: String) throws {
        try db.dbQueue.write { d in
            for s in sessions {
                var rec = SessionRecord(from: s)
                // A duplicate/invalid id must not abort (and thus permanently block) the whole one-time
                // migration — skip the bad row and keep going so migrationDate still gets written.
                do { try rec.insert(d) }
                catch { AppLogger.log("[Migration] skipped session \(s.id): \(error)") }
            }
            for day in daily { try DailyLegacyRecord(from: day).insert(d) }
            try d.execute(sql: "INSERT OR REPLACE INTO meta VALUES('migrationDate', ?)", arguments: [migrationDay])
            try d.execute(sql: "INSERT OR REPLACE INTO meta VALUES('schemaVersion', '1')")
        }
    }

    /// One-time on launch: if not migrated, load the two JSON files, import, then back them up. Idempotent + safe.
    static func runIfNeeded(_ db: AppDatabase, dir: URL, now: Date = Date(), cal: Calendar = .current) {
        guard !hasMigrated(db) else { return }
        let historyURL = dir.appendingPathComponent("history.json")
        let dailyURL = dir.appendingPathComponent("daily_stats.json")
        let sessions: [DictationSession] = load(historyURL) ?? []
        let daily: [DailyStats] = load(dailyURL) ?? []
        do {
            try importInto(db, sessions: sessions, daily: daily, migrationDay: StatsRepository.dayString(now, cal))
            backup(historyURL); backup(dailyURL)
            AppLogger.log("[Migration] imported \(sessions.count) sessions, \(daily.count) legacy days")
        } catch {
            AppLogger.log("[Migration] failed: \(error) — JSON kept; retry next launch")
        }
    }

    private static func load<T: Decodable>(_ url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path), let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(T.self, from: data)
    }
    private static func backup(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let bak = url.deletingPathExtension().appendingPathExtension("json.bak")
        try? FileManager.default.removeItem(at: bak)
        try? FileManager.default.moveItem(at: url, to: bak)
    }
}
