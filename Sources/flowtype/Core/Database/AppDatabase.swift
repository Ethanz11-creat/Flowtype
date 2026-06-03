import Foundation
import GRDB

/// Owns the GRDB connection and the schema migrator. One DB file; in-memory variant for tests.
final class AppDatabase: @unchecked Sendable {
    let dbQueue: DatabaseQueue

    init(_ dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    /// On-disk DB at <appSupport>/FlowType/flowtype.sqlite. Falls back to an empty in-memory DB on failure.
    static func make(at dir: URL) -> AppDatabase {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var config = GRDB.Configuration()
            config.prepareDatabase { db in try db.execute(sql: "PRAGMA journal_mode = WAL") }
            let queue = try DatabaseQueue(path: dir.appendingPathComponent("flowtype.sqlite").path, configuration: config)
            return try AppDatabase(queue)
        } catch {
            AppLogger.log("[DB] open failed: \(error) — using empty in-memory DB")
            return try! AppDatabase(try! DatabaseQueue())
        }
    }

    /// Empty in-memory DB (self-tests).
    static func inMemory() throws -> AppDatabase { try AppDatabase(try DatabaseQueue()) }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "session") { t in
                t.column("id", .text).primaryKey()
                t.column("startedAt", .double).notNull().indexed()
                t.column("recordingMs", .integer).notNull().defaults(to: 0)
                t.column("durationMs", .integer).notNull().defaults(to: 0)
                t.column("charCount", .integer).notNull().defaults(to: 0)
                t.column("language", .text)
                t.column("appName", .text)
                t.column("appBundleID", .text)
                t.column("polishMode", .text).notNull().defaults(to: "polish")
                t.column("sttBackend", .text).notNull().defaults(to: "unknown")
                t.column("rawTranscript", .text)
                t.column("finalText", .text)
            }
            try db.create(table: "daily_legacy") { t in
                t.column("date", .text).primaryKey()
                t.column("totalDurationMs", .integer).notNull().defaults(to: 0)
                t.column("totalRecordingMs", .integer).notNull().defaults(to: 0)
                t.column("totalWordCount", .integer).notNull().defaults(to: 0)
                t.column("sessionCount", .integer).notNull().defaults(to: 0)
                t.column("byApp", .text).notNull().defaults(to: "{}")
                t.column("byLang", .text).notNull().defaults(to: "{}")
                t.column("hourHistogram", .text).notNull().defaults(to: "[]")
            }
            try db.create(table: "meta") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }
        return m
    }
}

/// App-wide singleton: opens the on-disk DB and runs the one-time JSON migration before any store reads.
enum AppDatabaseProvider {
    static let dir: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("FlowType", isDirectory: true)

    static let shared: AppDatabase = {
        let db = AppDatabase.make(at: dir)
        JSONMigration.runIfNeeded(db, dir: dir)
        return db
    }()
}
