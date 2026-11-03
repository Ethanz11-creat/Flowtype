import Foundation
import Combine
import GRDB

enum NativeHistorySelfTests {
    @MainActor private final class ReadControl { var shouldFail = false }
    @MainActor
    static func run(_ r: SelfTest.Reporter) {
        print("--- NativeHistorySelfTests.historyReadFailureAndTextlessActions ---")
        historyReadFailureAndTextlessActions(r)
        print("--- NativeHistorySelfTests.historyDestructiveActionsKeepTheirSemantics ---")
        historyDestructiveActionsKeepTheirSemantics(r)
    }

    private static func database() throws -> (AppDatabase, URL) {
        let dir = RuntimeEnvironment.current.paths.applicationSupportDirectory
            .appendingPathComponent("native-history-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try AppDatabase(try DatabaseQueue(path: dir.appendingPathComponent("fixture.sqlite").path),
                                isOnDisk: true), dir)
    }

    private static func fixture(raw: String = "原始识别内容", final: String = "最终文本", mode: PolishMode = .polish) -> DictationSession {
        DictationSession(rawTranscript: raw, finalText: final, polishMode: mode,
                         durationMs: 9000, recordingMs: 4000, appName: "Fixture App",
                         appBundleID: "test.fixture", language: "zh", sttBackend: "fixture-engine")
    }

    @MainActor
    private static func historyReadFailureAndTextlessActions(_ r: SelfTest.Reporter) {
        do {
            let (db, dir) = try database()
            defer { try? FileManager.default.removeItem(at: dir) }
            let effects = ValidationEffects.live.snapshot
            var original = fixture()
            original.deliveryOutcome = .pasteDispatched
            var row = SessionRecord(from: original)
            try db.dbQueue.write { try row.insert($0) }
            let control = ReadControl()
            var refreshes = 0
            enum ReadError: LocalizedError {
                case unavailable
                var errorDescription: String? { "fixture history read unavailable" }
            }
            let store = HistoryStore(database: db, readSessions: {
                if control.shouldFail { throw ReadError.unavailable }
                return try db.dbQueue.read { try SessionRecord.fetchAll($0).map {
                    var session = $0.toDictationSession()
                    session.storedCharacterCount = $0.charCount
                    return session
                } }
            }, refreshStats: { refreshes += 1 })
            var states: [HistoryReadState] = []
            let observer = store.$readState.sink { states.append($0) }
            var copies: [String] = []
            var exports: [HistoryExport] = []
            let model = HistoryPageModel(store: store, copy: { copies.append($0) }, export: { exports.append($0) })
            let isolatedPage = HistoryPage(historyStore: store, copy: { copies.append($0) },
                                           export: { exports.append($0) })
            model.consume(NavigationRequest(id: UUID(), destination: .history(original.id)))
            model.searchText = "原始"
            r.eq(model.filteredSessions.map(\.id), [original.id], "history search: raw transcript matches")
            model.searchText = "最终"
            r.eq(model.filteredSessions.map(\.id), [original.id], "history search: final text matches")
            model.filterMode = .raw
            r.eq(model.filteredSessions.count, 0, "history filter: excludes other mode")
            model.filterMode = nil
            model.searchText = ""
            control.shouldFail = true
            store.reload()
            if case .failed(let message) = store.readState {
                r.check(message.contains("fixture history read unavailable"), "history read: observable failure explains retry")
            } else { r.check(false, "history read: must publish failed rather than empty loaded state") }
            r.eq(store.sessions.map(\.id), [original.id], "history read: preserves unexported display on error")
            r.eq(model.selectedSession?.finalText, original.finalText, "history read: selection and result survive error")
            if let selected = model.selectedSession { model.copy(selected); model.exportText(selected) }
            r.eq(copies, [original.finalText], "history read: retained result still copies through fake boundary")
            r.eq(exports.count, 1, "history read: retained result still exports through fake boundary")
            control.shouldFail = false
            store.reload()
            r.eq(store.readState, .loaded, "history read: explicit retry recovers")
            r.check(states.contains(.loading), "history read: reload publishes loading")
            r.check(states.contains { if case .failed = $0 { true } else { false } }, "history read: observers receive failure")
            r.eq(model.selectedSession?.id, original.id, "history read: retry keeps selection")
            r.eq(refreshes, 0, "history read: reads never refresh statistics")

            let expected: [(DeliveryOutcome?, String)] = [
                (.typedDispatched, "已发送键入事件"), (.pasteDispatched, "已发送粘贴事件"),
                (.clipboard, "结果已写入剪贴板"), (.uncertain, "无法确认是否输入；可复制结果"),
                (.cancelled, "已取消"), (nil, "无交付状态记录")
            ]
            for (outcome, label) in expected {
                original.deliveryOutcome = outcome
                let record = SessionRecord(from: original)
                try db.dbQueue.write { try record.update($0) }
                store.reload()
                r.eq(HistoryPresentation.deliveryLabel(model.selectedSession?.deliveryOutcome), label,
                     "history delivery: stored outcome maps honestly")
            }
            store.clearTranscripts()
            guard let textless = model.selectedSession else { r.check(false, "history textless: metadata retained"); return }
            r.check(!HistoryPresentation.canCopy(textless), "history textless: copy unavailable")
            r.check(!HistoryPresentation.canExportText(textless), "history textless: single text export unavailable")
            let previousCopies = copies.count, previousExports = exports.count
            model.copy(textless)
            model.exportText(textless)
            r.eq(copies.count, previousCopies, "history textless: copy performs no clipboard effect")
            r.eq(exports.count, previousExports, "history textless: text export performs no save effect")
            model.exportCSV()
            guard case .csv(let csvSessions) = exports.last else { r.check(false, "history CSV: fake receives CSV"); return }
            let csv = HistoryPresentation.csv(csvSessions)
            r.check(csv.contains("\"Fixture App\",\"zh\",\"\(row.charCount)\",\"4000\",\"fixture-engine\",\"\""),
                    "history CSV: retains persisted metadata/count with empty text")
            r.check(!csv.contains("最终文本") && !csv.contains("原始识别内容"), "history CSV: never recovers removed content")
            let noSave = fixture(raw: "未保存内容", final: "不应保存", mode: .raw)
            store.append(noSave, storeText: false)
            let defaultReader = HistoryStore(database: db, refreshStats: {})
            let noSaveRead = defaultReader.sessions.first { $0.id == noSave.id }!
            r.check(!HistoryPresentation.canCopy(noSaveRead) && !HistoryPresentation.canExportText(noSaveRead),
                    "history privacy-off: persisted metadata record disables text actions")
            r.eq(noSaveRead.storedCharacterCount, noSave.rawTranscript.count, "history privacy-off: original count preserved")
            let repeatRequest = NavigationRequest(id: UUID(), destination: .history(original.id))
            model.searchText = "unmatched"
            model.filterMode = .raw
            model.consume(repeatRequest)
            r.eq(model.selectedID, original.id, "history navigation: selects existing ID")
            r.eq(model.filteredSessions.count, 2, "history navigation: clears conflicting search/filter")
            model.selectedID = noSave.id
            let again = NavigationRequest(id: UUID(), destination: .history(original.id))
            model.consume(again)
            r.eq(model.selectedID, original.id, "history navigation: repeated target reselects record")
            r.eq(model.navigationRequestID, again.id, "history navigation: consumes new request identity")
            model.consume(NavigationRequest(id: UUID(), destination: .history("missing")))
            r.eq(model.selectedID, original.id, "history navigation: missing ID leaves usable ordinary list")
            model.searchText = "fixture"
            r.eq(model.filteredSessions.count, 0, "history search: searches transcript rather than invented metadata")
            model.searchText = ""
            model.filterMode = .raw
            r.eq(model.filteredSessions.map(\.id), [noSave.id], "history filter: raw mode remains available")
            r.eq(ValidationEffects.live.snapshot.blocked, effects.blocked, "history isolation: no attempted live effects")
            r.eq(ValidationEffects.live.snapshot.permitted, effects.permitted, "history isolation: no live effects")
            withExtendedLifetime((observer, isolatedPage)) {}
        } catch { r.check(false, "history fixtures: \(error)") }
    }

    @MainActor
    private static func historyDestructiveActionsKeepTheirSemantics(_ r: SelfTest.Reporter) {
        do {
            let (db, dir) = try database()
            defer { try? FileManager.default.removeItem(at: dir) }
            var refreshes = 0
            let store = HistoryStore(database: db, refreshStats: { refreshes += 1 })
            let first = fixture(raw: "12345", final: "1")
            let second = fixture(raw: "123", final: "长一些的最终文本")
            store.append(first, storeText: true)
            store.append(second, storeText: true)
            let repository = StatsRepository(db: db)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let statsBefore = try encoder.encode(repository.buildDailyStats())
            r.eq(repository.buildDailyStats().reduce(0) { $0 + $1.totalWordCount }, 8, "history stats: uses original recognized count")
            let callbacksBeforeClear = refreshes
            store.clearTranscripts()
            r.eq(try encoder.encode(repository.buildDailyStats()), statsBefore, "history clear: all statistics unchanged")
            r.eq(refreshes, callbacksBeforeClear, "history clear: no changed-statistics refresh")
            r.eq(store.sessions.count, 2, "history clear: metadata rows retained")
            r.check(store.sessions.allSatisfy { $0.finalText.isEmpty && $0.rawTranscript.isEmpty }, "history clear: both transcripts removed")
            let model = HistoryPageModel(store: store, copy: { _ in r.check(false, "unexpected copy") },
                                         export: { _ in r.check(false, "unexpected export") })
            model.selectedID = first.id
            model.delete(store.sessions.first { $0.id == first.id }!)
            r.eq(repository.buildDailyStats().reduce(0) { $0 + $1.totalWordCount }, 3, "history delete: corresponding count removed")
            r.eq(repository.buildDailyStats().reduce(0) { $0 + $1.sessionCount }, 1, "history delete: corresponding session removed")
            r.eq(refreshes, callbacksBeforeClear + 1, "history delete: refreshes injected statistics")
            r.check(model.selectedID == nil, "history delete: deleted detail deselected")
            try db.dbQueue.write { try $0.execute(sql: "INSERT INTO daily_legacy(date) VALUES('2001-01-01')") }
            model.confirmReset()
            r.eq(store.sessions.count, 1, "history reset: cannot bypass both confirmations")
            model.requestReset()
            model.confirmReset()
            r.eq(store.sessions.count, 1, "history reset: first confirmation alone cannot destroy")
            model.continueReset()
            model.cancelReset()
            model.confirmReset()
            r.eq(store.sessions.count, 1, "history reset: cancellation revokes final confirmation")
            model.requestReset()
            model.continueReset()
            model.confirmReset()
            r.eq(store.sessions.count, 0, "history reset: final confirmation deletes records")
            r.eq(repository.buildDailyStats().count, 0, "history reset: session and frozen legacy statistics deleted")
            r.eq(refreshes, callbacksBeforeClear + 2, "history reset: refreshes statistics once")
            r.eq(store.readState, .loaded, "history reset: genuine empty database is loaded")
        } catch { r.check(false, "history destructive fixtures: \(error)") }
    }
}
