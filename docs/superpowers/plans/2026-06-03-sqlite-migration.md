# JSON → SQLite (GRDB) Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`).

**Goal:** Move FlowType's dictation data to one local SQLite DB (GRDB) with the `session` table as the single source of truth; all stats derive through the unchanged `StatsEngine`; remove the 500/365 caps + dual-write; add `storeTranscriptText`, split clear-history vs reset-stats, align export, and harden temp-wav deletion.

**Architecture:** New `Core/Database/` layer (GRDB) built additively alongside the existing JSON stores (Tasks 1–5, build stays green), then the stores are switched to DB-backed in one integration task (Task 6) keeping their `.stats`/`.sessions` read APIs so the views don't change. The day-bucketing reuses the existing `Calendar` local-midnight `dayOrdinal` logic; speed uses `recordingMs`.

**Tech Stack:** Swift 6.2, SPM, GRDB.swift, the custom in-target `--self-test` runner (GRDB in-memory DBs).

**Spec:** `docs/superpowers/specs/2026-06-03-sqlite-migration-design.md`. **Verify each task:** `swift build` → "Build complete!"; `set -o pipefail && swift run FlowType --self-test 2>&1 | tail -1` → "N passed, 0 failed" (never a regression; new tests raise N). SourceKit "Cannot find X" is STALE — trust `swift build`.

---

## File Structure
- **Modify** `Package.swift` — add GRDB dependency + product.
- **Create** `Core/Database/AppDatabase.swift` — `DatabaseQueue` + `DatabaseMigrator` (session/daily_legacy/meta); file + in-memory factories; `AppDatabaseProvider.shared` (runs migration once).
- **Create** `Core/Database/Records.swift` — `SessionRecord`, `DailyLegacyRecord` (GRDB records + domain mapping).
- **Create** `Core/Database/StatsRepository.swift` — DB → `[DailyStats]` (boundary fold, local-day, recordingMs).
- **Create** `Core/Database/JSONMigration.swift` — one-time import + backup + boundary meta.
- **Modify** `Core/DictationHistory.swift` — add `sttBackend` to `DictationSession`; `HistoryStore` → DB-backed (`append(_:storeText:)`, `delete`, `clearTranscripts`, `resetAllStats`, `reload`).
- **Modify** `Core/DailyStats.swift` — `DailyStatsStore` → DB-backed (`stats` derived, `refresh()`; drop `recordSession`).
- **Modify** `Core/PipelineOrchestrator.swift` — set `sttBackend`; `append(_:storeText:)`.
- **Modify** `Core/Configuration.swift` — `storeTranscriptText: Bool = true`.
- **Modify** `Settings/SettingsView.swift` — privacy toggle.
- **Modify** `Settings/HistoryPage.swift` — 清空历史 (null text) + 重置统计 (delete, double-confirm); export `sttBackend`.
- **Modify** `Services/Speech/AppleSpeechProvider.swift` — verify/harden temp-wav delete.
- **Modify** `Testing/SelfTest.swift` — DB self-tests + registration.

---

## Task 1: Add GRDB dependency

**Files:** Modify `Package.swift`.

- [ ] **Step 1:** Add the dependency (line 10–12) and product (line 16–20):
```swift
    dependencies: [
        .package(url: "https://github.com/soniqo/speech-swift.git", from: "0.0.15"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
    ],
```
and in the executable target's `dependencies` array add:
```swift
                .product(name: "GRDB", package: "GRDB.swift"),
```
(If Swift-6 strict-concurrency errors appear from GRDB 6, bump the requirement to the latest `from: "7.0.0"` — GRDB 7 is the Swift-6-ready line. Resolve and rebuild.)

- [ ] **Step 2:** `swift build 2>&1 | tail -3` → "Build complete!" (downloads GRDB). Self-test unchanged count.

- [ ] **Step 3: Commit**
```bash
git add Package.swift Package.resolved
git commit -m "build: add GRDB.swift dependency for the SQLite migration (§12)"
```

---

## Task 2: `AppDatabase` — schema + migrator + provider

**Files:** Create `Sources/flowtype/Core/Database/AppDatabase.swift`.

- [ ] **Step 1: Create the file:**
```swift
import Foundation
import GRDB

/// Owns the GRDB connection and the schema migrator. One DB file; in-memory variant for tests.
final class AppDatabase {
    let dbQueue: DatabaseQueue

    init(_ dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    /// On-disk DB at <appSupport>/FlowType/flowtype.sqlite. Falls back to an empty in-memory DB on failure.
    static func make(at dir: URL) -> AppDatabase {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var config = Configuration()
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
```

- [ ] **Step 2: Add a schema self-test.** In `Testing/SelfTest.swift`, add a new method and register it (call `testDatabaseSchema(r)` inside `runAndExit()` right after `testHeatmapDensity(r)`):
```swift
    static func testDatabaseSchema(_ r: Reporter) {
        guard let db = try? AppDatabase.inMemory() else { r.check(false, "db: inMemory open"); return }
        let tables = (try? db.dbQueue.read { d in
            try String.fetchAll(d, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }) ?? []
        r.check(tables.contains("session"), "db: session table exists")
        r.check(tables.contains("daily_legacy"), "db: daily_legacy table exists")
        r.check(tables.contains("meta"), "db: meta table exists")
    }
```
(`JSONMigration.runIfNeeded` is referenced by `AppDatabaseProvider` but defined in Task 5 — Task 2 will not build until Task 5 lands. To keep Task 2 self-contained, temporarily stub `AppDatabaseProvider.shared` to `AppDatabase.make(at: dir)` WITHOUT the migration call, then restore the migration call in Task 5. Note this in the commit.)

- [ ] **Step 3:** `swift build` green; self-test +3. **Commit** `feat(db): GRDB AppDatabase + schema migrator (session/daily_legacy/meta)`.

---

## Task 3: `SessionRecord` + `DailyLegacyRecord` (records + domain mapping)

**Files:** Create `Sources/flowtype/Core/Database/Records.swift`. (Depends on `DictationSession.sttBackend` from Task 6 Step 1 — to avoid ordering pain, **add the `sttBackend` field to `DictationSession` here** as the first step.)

- [ ] **Step 1: Add `sttBackend` to `DictationSession`** in `Core/DictationHistory.swift` (Optional ⇒ synthesized decode tolerates old JSON):
  - Add stored property after `language`: `let sttBackend: String?`
  - Add to the memberwise `init(...)` a trailing parameter `sttBackend: String? = nil` and `self.sttBackend = sttBackend`.

- [ ] **Step 2: Create `Records.swift`:**
```swift
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
        self.charCount = s.finalText.trimmingCharacters(in: .whitespacesAndNewlines).count
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
```
Note: `DictationSession` needs an `init` that accepts `id`/`createdAt` (the current one auto-generates them). **Add a second initializer** to `DictationSession` (in `Core/DictationHistory.swift`) that takes all fields explicitly, used by `toDictationSession()`:
```swift
    init(id: String, createdAt: Date, rawTranscript: String, finalText: String, polishMode: PolishMode,
         durationMs: UInt64?, recordingMs: UInt64?, appName: String?, appBundleID: String?,
         language: String?, sttBackend: String?) {
        self.id = id; self.createdAt = createdAt
        self.rawTranscript = rawTranscript; self.finalText = finalText; self.polishMode = polishMode
        self.durationMs = durationMs; self.recordingMs = recordingMs
        self.appName = appName; self.appBundleID = appBundleID; self.language = language; self.sttBackend = sttBackend
    }
```

- [ ] **Step 3: Round-trip self-test** — register `testSessionRecord(r)` after `testDatabaseSchema(r)`:
```swift
    static func testSessionRecord(_ r: Reporter) {
        guard let db = try? AppDatabase.inMemory() else { r.check(false, "rec: db"); return }
        let s = DictationSession(rawTranscript: "原文", finalText: "你好世界", polishMode: .polish,
                                 durationMs: 9000, recordingMs: 4000, appName: "Xcode",
                                 appBundleID: "com.apple.dt.Xcode", language: "zh", sttBackend: "qwen")
        var rec = SessionRecord(from: s)
        try? db.dbQueue.write { try rec.insert($0) }
        let back = (try? db.dbQueue.read { try SessionRecord.fetchAll($0) }) ?? []
        r.eq(back.count, 1, "rec: one row")
        r.eq(back.first?.charCount, 4, "rec: charCount=4 (你好世界)")
        r.eq(back.first?.sttBackend, "qwen", "rec: sttBackend persisted")
        r.eq(back.first?.recordingMs, 4000, "rec: recordingMs persisted")
    }
```

- [ ] **Step 4:** build green; self-test +4. **Commit** `feat(db): SessionRecord + DailyLegacyRecord with domain mapping + round-trip test`.

---

## Task 4: `StatsRepository` — DB → `[DailyStats]` (boundary fold)

**Files:** Create `Sources/flowtype/Core/Database/StatsRepository.swift`.

- [ ] **Step 1: Create the file.** The boundary rule (spec §5.1): `daily_legacy` rows with `date < migrationDate` plus **session rows whose local day `>= migrationDate`** — so migrated old sessions (day < migrationDate) never double-count against the frozen legacy snapshot. Day strings "yyyy-MM-dd" compare chronologically.
```swift
import Foundation
import GRDB

struct StatsRepository {
    let db: AppDatabase

    static func dayString(_ date: Date, _ cal: Calendar) -> String {
        let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// daily_legacy(date < migrationDate) ∪ fold(session where localDay >= migrationDate) → [DailyStats], oldest→newest.
    func buildDailyStats(now: Date = Date(), cal: Calendar = .current) -> [DailyStats] {
        do {
            return try db.dbQueue.read { d -> [DailyStats] in
                let migrationDay = (try String.fetchOne(d, sql: "SELECT value FROM meta WHERE key='migrationDate'"))
                    ?? Self.dayString(now, cal)
                var byDate: [String: DailyStats] = [:]
                for row in try DailyLegacyRecord.fetchAll(d) where row.date < migrationDay {
                    byDate[row.date] = row.toDailyStats()
                }
                for s in try SessionRecord.fetchAll(d) {
                    let date = Date(timeIntervalSince1970: s.startedAt)
                    let day = Self.dayString(date, cal)
                    guard day >= migrationDay else { continue }     // pre-migration days belong to daily_legacy
                    let hour = cal.component(.hour, from: date)
                    var ds = byDate[day] ?? DailyStats(date: day, totalDurationMs: 0, totalWordCount: 0, sessionCount: 0)
                    ds.totalDurationMs  += UInt64(max(0, s.durationMs))
                    ds.totalRecordingMs += UInt64(max(0, s.recordingMs))
                    ds.totalWordCount   += s.charCount
                    ds.sessionCount     += 1
                    ds.byApp[s.appName ?? "未知", default: 0]  += s.charCount
                    ds.byLang[s.language ?? "未知", default: 0] += s.charCount
                    if (0..<24).contains(hour) { ds.hourHistogram[hour] += 1 }
                    byDate[day] = ds
                }
                return byDate.values.sorted { $0.date < $1.date }
            }
        } catch {
            AppLogger.log("[StatsRepository] read failed: \(error)")
            return []
        }
    }
}
```

- [ ] **Step 2: Self-tests** — register `testStatsRepository(r)` after `testSessionRecord(r)`. Covers equivalence, boundary no-double-count, and recordingMs denominator. Use **noon timestamps** to stay clear of timezone day-boundaries.
```swift
    static func testStatsRepository(_ r: Reporter) {
        guard let db = try? AppDatabase.inMemory() else { r.check(false, "repo: db"); return }
        let cal = Calendar.current
        func noon(_ iso: String) -> Double {
            let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"
            return f.date(from: "\(iso) 12:00")!.timeIntervalSince1970
        }
        // migrationDate = 2026-06-01; legacy day 2026-05-20 (chars 100); sessions on 06-02 (chars 50, recMs 20000) + a session on 05-19 (chars 999, should be ignored for stats)
        try? db.dbQueue.write { d in
            try d.execute(sql: "INSERT OR REPLACE INTO meta VALUES('migrationDate','2026-06-01')")
            try DailyLegacyRecord(from: DailyStats(date: "2026-05-20", totalDurationMs: 0, totalWordCount: 100, sessionCount: 1, totalRecordingMs: 60000)).insert(d)
            var s1 = SessionRecord(from: DictationSession(rawTranscript: "", finalText: String(repeating: "字", count: 50), polishMode: .raw, durationMs: 99999, recordingMs: 20000, appName: "A", appBundleID: nil, language: "zh", sttBackend: "qwen"))
            s1.startedAt = noon("2026-06-02"); try s1.insert(d)
            var sOld = SessionRecord(from: DictationSession(rawTranscript: "", finalText: String(repeating: "x", count: 999), polishMode: .raw, durationMs: 0, recordingMs: 0, appName: "A", appBundleID: nil, language: "en", sttBackend: "qwen"))
            sOld.startedAt = noon("2026-05-19"); try sOld.insert(d)
        }
        let stats = StatsRepository(db: db).buildDailyStats(cal: cal)
        let d0520 = stats.first { $0.date == "2026-05-20" }
        let d0602 = stats.first { $0.date == "2026-06-02" }
        r.eq(d0520?.totalWordCount, 100, "repo: legacy day from snapshot (no session double-count)")
        r.check(stats.first { $0.date == "2026-05-19" } == nil, "repo: pre-migration session excluded from stats")
        r.eq(d0602?.totalWordCount, 50, "repo: post-migration day from sessions")
        // recordingMs denominator: 50 chars / (20000ms=0.333min) → high speed, durationMs(99999) ignored
        let summary = StatsEngine.summarize(stats, range: .all, now: noonDate("2026-06-02", cal), cal: cal)
        r.check(summary.avgSpeedCPM >= 100, "repo: speed uses recordingMs not durationMs")
    }
    static func noonDate(_ iso: String, _ cal: Calendar) -> Date {
        let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: "\(iso) 12:00")!
    }
```
(If `DailyStats(date:totalDurationMs:totalWordCount:sessionCount:totalRecordingMs:)` arg order differs, match the existing memberwise init in `Core/DailyStats.swift`.)

- [ ] **Step 3:** build green; self-test +4. **Commit** `feat(db): StatsRepository boundary-fold DB→[DailyStats] + equivalence/boundary tests`.

---

## Task 5: `JSONMigration` — one-time import + backup

**Files:** Create `Sources/flowtype/Core/Database/JSONMigration.swift`; restore the migration call in `AppDatabase.swift` (Task 2 stub).

- [ ] **Step 1: Create the file:**
```swift
import Foundation
import GRDB

enum JSONMigration {
    static func hasMigrated(_ db: AppDatabase) -> Bool {
        ((try? db.dbQueue.read { try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key='migrationDate'") }) ?? nil) != nil
    }

    /// Pure import (testable): insert sessions + legacy days, set migrationDate. Caller wraps with file IO.
    static func importInto(_ db: AppDatabase, sessions: [DictationSession], daily: [DailyStats], migrationDay: String) throws {
        try db.dbQueue.write { d in
            for s in sessions { var rec = SessionRecord(from: s); try rec.insert(d) }
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
```

- [ ] **Step 2: Restore** the migration call in `AppDatabase.swift` `AppDatabaseProvider.shared` (replace the Task-2 stub) to:
```swift
    static let shared: AppDatabase = {
        let db = AppDatabase.make(at: dir)
        JSONMigration.runIfNeeded(db, dir: dir)
        return db
    }()
```

- [ ] **Step 3: Self-tests** — register `testJSONMigration(r)` after `testStatsRepository(r)`:
```swift
    static func testJSONMigration(_ r: Reporter) {
        guard let db = try? AppDatabase.inMemory() else { r.check(false, "mig: db"); return }
        r.check(!JSONMigration.hasMigrated(db), "mig: not migrated initially")
        let s = DictationSession(rawTranscript: "", finalText: "你好", polishMode: .raw, durationMs: 1000,
                                 recordingMs: 1000, appName: "A", appBundleID: nil, language: "zh", sttBackend: nil)
        try? JSONMigration.importInto(db, sessions: [s], daily: [], migrationDay: "2026-01-01")
        r.check(JSONMigration.hasMigrated(db), "mig: migrated after import")
        let recs = (try? db.dbQueue.read { try SessionRecord.fetchAll($0) }) ?? []
        r.eq(recs.first?.sttBackend, "legacy", "mig: imported session tagged legacy (no backend)")
    }
```

- [ ] **Step 4:** build green; self-test +2. **Commit** `feat(db): one-time JSON→SQLite migration (idempotent, backs up *.json.bak)`.

---

## Task 6: Switch stores to DB-backed + orchestrator

**Files:** Modify `Core/DailyStats.swift`, `Core/DictationHistory.swift`, `Core/PipelineOrchestrator.swift`.

- [ ] **Step 1: `DailyStatsStore` → DB-derived.** Replace its body (keep `static let shared`, keep `@Published private(set) var stats`). Remove `recordSession` and all JSON/`PersistentStore` code:
```swift
@MainActor
final class DailyStatsStore: ObservableObject {
    static let shared = DailyStatsStore()
    @Published private(set) var stats: [DailyStats] = []
    private let repo = StatsRepository(db: AppDatabaseProvider.shared)
    private init() { refresh() }
    func refresh() { stats = repo.buildDailyStats() }
}
```
(The computed conveniences `totalDurationMs`/`overallAverageSpeed`/`estimatedTimeSavedSeconds` are now dead — delete them; the Overview uses `StatsEngine.summarize(stats,…)`.)

- [ ] **Step 2: `HistoryStore` → DB-backed** (keep `static let shared`, `@Published private(set) var sessions`). Replace `PersistentStore` + `append`/`delete`/`clear`:
```swift
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
```
(The `append` no longer calls `DailyStatsStore.recordSession`; aggregates are derived.)

- [ ] **Step 3: Orchestrator** `Core/PipelineOrchestrator.swift`. At the `DictationSession(` build (≈line 390) add `sttBackend:` from the same logic used for the status label (≈line 170): a local `let sttBackend = speechRouter.qwenProvider.isLoaded ? "qwen" : "apple"`. Then change the append call (≈line 400) to:
```swift
        HistoryStore.shared.append(session, storeText: ConfigurationStore.shared.config.storeTranscriptText)
```
Add `sttBackend: sttBackend` to the `DictationSession(...)` initializer call. (`storeTranscriptText` is added in Task 7 — to keep this task building, add the `Configuration` field in Task 7 *before* this line compiles; if executing Task 6 first, temporarily pass `storeText: true` and switch to the config in Task 7.)

- [ ] **Step 4:** `swift build` green; `swift run FlowType --self-test` — existing stats/engine tests still pass (they call `StatsEngine` directly, unaffected); DB tests pass. **Commit** `feat(db): switch DailyStatsStore + HistoryStore to GRDB (single source of truth, no dual-write)`.

---

## Task 7: `storeTranscriptText` config + Settings toggle

**Files:** Modify `Core/Configuration.swift`, `Settings/SettingsView.swift`.

- [ ] **Step 1:** In `Configuration` add (near `appearancePreference`): `var storeTranscriptText: Bool = true`. The struct's custom `init(from:)` uses `decodeIfPresent ?? default` elsewhere — add the same: `storeTranscriptText = (try? c.decodeIfPresent(Bool.self, forKey: .storeTranscriptText)) ?? true` (and ensure the `CodingKeys`/key exists; if the struct relies on synthesized keys, the Optional-with-default pattern already used for other new fields applies — match it exactly).

- [ ] **Step 2:** In `SettingsView.swift` add a privacy toggle. Add a `privacySection` and place it after `recordingSection` in `body`:
```swift
    private var privacySection: some View {
        Section("隐私") {
            Toggle("保存转写文本", isOn: Binding(
                get: { store.config.storeTranscriptText },
                set: { store.update { $0.storeTranscriptText = $0.storeTranscriptText; $0.storeTranscriptText = $1 } }
            ))
            Text("关闭后只保存时长/字数等统计元数据，不再保存“你说了什么”。统计不受影响。")
                .font(.system(size: 11)).foregroundColor(.secondary)
        }
    }
```
Match the existing `store.update { … }` mutation pattern actually used in `SettingsView` (inspect a neighboring Toggle, e.g. `enableAudioFeedback`, and copy its exact binding style — replace the placeholder setter above with that real pattern).

- [ ] **Step 3:** build green; add a config round-trip self-test in `testAppearanceConfig` or a new `testPrivacyConfig(r)`:
```swift
    static func testPrivacyConfig(_ r: Reporter) {
        var c = Configuration(); c.storeTranscriptText = false
        let data = try! JSONEncoder().encode(c)
        let back = try! JSONDecoder().decode(Configuration.self, from: data)
        r.check(back.storeTranscriptText == false, "config: storeTranscriptText round-trips")
        let legacy = Data(#"{"asrLanguage":"zh"}"#.utf8)
        let dflt = try? JSONDecoder().decode(Configuration.self, from: legacy)
        r.check(dflt?.storeTranscriptText == true, "config: storeTranscriptText defaults true on legacy JSON")
    }
```
register after `testJSONMigration(r)`. build + self-test green. **Commit** `feat(privacy): storeTranscriptText setting (default on) + Settings toggle (§8)`.

---

## Task 8: HistoryPage — 清空历史 vs 重置统计 + export `sttBackend`

**Files:** Modify `Settings/HistoryPage.swift`.

- [ ] **Step 1:** The current destructive button calls `historyStore.clear()` (now removed). Replace it with **two** actions:
  - **清空历史** (default-safe): confirmation "清空所有历史文本？时长、字数、连续打卡等统计会保留。" → `historyStore.clearTranscripts()`.
  - **重置统计** (destructive, separate, e.g. in an overflow/secondary position): a **two-step** confirm ("这会删除全部记录与统计，且不可恢复。" → second confirm) → `historyStore.resetAllStats()`.
  Use the existing `.confirmationDialog`/`.alert` pattern already in the file (the `清空全部` dialog at line ≈22) as the template; make 重置统计 require an extra confirmation step.

- [ ] **Step 2:** In the CSV export (≈line 243–247), add `sttBackend` to the header and each row, and ensure cleared/withheld text exports as empty. Header → `startedAt,appName,language,charCount,recordingMs,sttBackend,finalText`; row appends `sanitizeCSVCell(session.sttBackend ?? "")` and `sanitizeCSVCell(session.finalText)`. (JSON export already serializes the full `DictationSession`, which now includes `sttBackend` — no change needed beyond it compiling.)

- [ ] **Step 3:** Handle cleared rows in the row/detail views: where `session.finalText` is shown, if it is empty show "(文本已清除)" so a nulled transcript reads intentionally rather than blank.

- [ ] **Step 4:** build green; self-test unchanged. **Commit** `feat(history): split 清空历史 (keep stats) vs 重置统计 + export sttBackend (§8,§9)`.

---

## Task 9: AppleSpeech temp-wav — verify all paths

**Files:** Modify `Services/Speech/AppleSpeechProvider.swift`.

- [ ] **Step 1:** Read `transcribe(...)` (the function around line 58 that writes `flowtype_apple_speech_*.wav`). Confirm the `defer { try? FileManager.default.removeItem(at: tmpFile) }` (line 61) is registered **immediately after** the successful `write` and therefore fires on every exit — normal return, thrown error, and task cancellation. If any early-return/throw path exists **before** the `defer` is registered (between the `write` at line 60 and the `defer`), move the `defer` to the line directly after the `write`, or wrap in `do { … }` so cleanup is guaranteed.

- [ ] **Step 2:** If the recognition uses a continuation/closure that can outlive the function scope (so `defer` would delete the wav before recognition reads it), restructure so the temp file is removed only after the recognition completes/fails/cancels — e.g. delete inside the completion handler's terminal branches AND on the cancel path. Ensure **success, failure, and cancel** all delete. (If the current `defer` already correctly scopes around an `await`ed result, no change — just confirm and note it.)

- [ ] **Step 3:** build green; self-test unchanged. **Commit** `fix(privacy): guarantee AppleSpeech temp .wav deletion on success/fail/cancel (§10)`.

---

## Task 10: Build `.app` → on-device migration verify → STOP

- [ ] **Step 1:** `./scripts/build-app.sh`; `pkill -x FlowType; xattr -cr build/FlowType.app; open build/FlowType.app`; push (retry loop).
- [ ] **Step 2: Owner verifies on real data (spec §13):** existing JSON migrates (numbers identical pre/post; `*.json.bak` present); new dictations persist to DB; History uncapped; 清空历史 keeps streaks; 重置统计 (double-confirm) clears; `storeTranscriptText=off` stores no text yet stats accrue; export JSON+CSV valid; AppleSpeech temp wav gone; heatmap/streaks on local days; speed realistic. **STOP for acceptance.**

---

## Self-Review
- **Spec coverage:** §3 architecture → Tasks 2/4/6; §4 schema → Task 2 (+`sttBackend`, `charCount` independent of text); §5 migration (idempotent/atomic/backup/boundary) → Tasks 5 + 4 (boundary fold filter `>= migrationDate`); §6 StatsRepository (local-day via Calendar, recordingMs) → Task 4; §7 writes/History API → Task 6; §8 privacy (清空历史 null-text, 重置统计 delete, storeTranscriptText) → Tasks 6/7/8; §9 export JSON/CSV (+sttBackend, escaping) → Task 8; §10 temp-wav → Task 9; §11 error handling → Tasks 2/5/6 (fallbacks + non-fatal writes); §12 tests → Tasks 2–7; §13 acceptance → Task 10. `editedCharCount`/cloud excluded. ✓
- **Placeholder scan:** the two "match the existing pattern" notes (Settings `store.update` binding in Task 7 Step 2; confirmation-dialog template in Task 8 Step 1) point at a concrete in-file exemplar to copy — not vague TODOs. All record/repo/migration code is complete.
- **Type consistency:** `AppDatabase.dbQueue/.inMemory()/.make(at:)`, `AppDatabaseProvider.shared/.dir`, `SessionRecord(from:)/.toDictationSession()`, `DailyLegacyRecord(from:)/.toDailyStats()`, `StatsRepository(db:).buildDailyStats(now:cal:)`/`.dayString(_:_:)`, `JSONMigration.importInto(_:sessions:daily:migrationDay:)/.runIfNeeded(_:dir:now:cal:)/.hasMigrated(_:)`, `DictationSession.sttBackend` + explicit `init`, `HistoryStore.append(_:storeText:)/.clearTranscripts()/.resetAllStats()/.reload()`, `DailyStatsStore.refresh()`, `Configuration.storeTranscriptText` — all defined before use. `DailyStats` memberwise init arg order must be verified against `Core/DailyStats.swift` when writing Task 3/4 test data.
