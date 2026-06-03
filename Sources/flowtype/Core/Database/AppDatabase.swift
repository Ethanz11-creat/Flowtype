import Foundation
import GRDB

/// Owns the GRDB connection and the schema migrator. One DB file; in-memory variant for tests.
final class AppDatabase: @unchecked Sendable {
    let dbQueue: DatabaseQueue
    /// True only for the durable on-disk DB. The one-time JSON migration (and its destructive
    /// *.json.bak rename) must NEVER run against the in-memory fallback — otherwise a transient open
    /// failure imports into a throwaway DB and orphans the source JSON, permanently losing all history.
    let isOnDisk: Bool

    init(_ dbQueue: DatabaseQueue, isOnDisk: Bool) throws {
        self.dbQueue = dbQueue
        self.isOnDisk = isOnDisk
        try Self.migrator.migrate(dbQueue)
    }

    /// On-disk DB at <appSupport>/FlowType/flowtype.sqlite. Falls back to an empty in-memory DB on failure.
    static func make(at dir: URL) -> AppDatabase {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var config = GRDB.Configuration()
            config.prepareDatabase { db in try db.execute(sql: "PRAGMA journal_mode = WAL") }
            let queue = try DatabaseQueue(path: dir.appendingPathComponent("flowtype.sqlite").path, configuration: config)
            return try AppDatabase(queue, isOnDisk: true)
        } catch {
            AppLogger.log("[DB] open failed: \(error) — using empty in-memory DB (migration suppressed)")
            return try! AppDatabase(try! DatabaseQueue(), isOnDisk: false)
        }
    }

    /// Empty in-memory DB (self-tests).
    static func inMemory() throws -> AppDatabase { try AppDatabase(try DatabaseQueue(), isOnDisk: false) }

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
        // v2: word-count should reflect the ORIGINAL recognized text (rawTranscript), not the polished
        // finalText. Recompute charCount for existing rows that still have the raw text.
        m.registerMigration("v2_charcount_from_raw") { db in
            try db.execute(sql: """
                UPDATE session SET charCount = length(trim(rawTranscript))
                WHERE rawTranscript IS NOT NULL AND trim(rawTranscript) <> ''
                """)
        }
        // v3: v2 used bare trim() (strips only ASCII space 0x20), diverging from the Swift insert path
        // which trims the full whitespace+newline set. Redo it trimming space/tab/CR/LF to match.
        m.registerMigration("v3_charcount_trim_fix") { db in
            let ws = "char(32)||char(9)||char(10)||char(13)"
            try db.execute(sql: """
                UPDATE session SET charCount = length(trim(rawTranscript, \(ws)))
                WHERE rawTranscript IS NOT NULL AND trim(rawTranscript, \(ws)) <> ''
                """)
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
        // Only migrate (and back up the source JSON) into the DURABLE on-disk DB — never the ephemeral
        // in-memory fallback, which would discard the import and orphan the JSON as *.bak (data loss).
        if db.isOnDisk { JSONMigration.runIfNeeded(db, dir: dir) }
        return db
    }()
}
