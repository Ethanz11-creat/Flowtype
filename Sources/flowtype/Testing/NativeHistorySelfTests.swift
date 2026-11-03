import Foundation
import Combine
import GRDB

enum NativeHistorySelfTests {
    @MainActor private final class ReadControl {
        var shouldFail = false
        var failureMessage: String?
    }
    @MainActor
    static func run(_ r: SelfTest.Reporter) {
        print("--- NativeHistorySelfTests.historyReadFailureAndTextlessActions ---")
        historyReadFailureAndTextlessActions(r)
        print("--- NativeHistorySelfTests.historyDestructiveActionsKeepTheirSemantics ---")
        historyDestructiveActionsKeepTheirSemantics(r)
        print("--- NativeHistorySelfTests.historyCommittedMutationsSurviveReadFailure ---")
        historyCommittedMutationsSurviveReadFailure(r)
        print("--- NativeHistorySelfTests.historyFailedWritesPreserveCache ---")
        historyFailedWritesPreserveCache(r)
        print("--- NativeHistorySelfTests.historyReentrantMutationKeepsLatestState ---")
        historyReentrantMutationKeepsLatestState(r)
        print("--- NativeHistorySelfTests.historyReadStatePublicationKeepsLatestFailure ---")
        historyReadStatePublicationKeepsLatestFailure(r)
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

    private enum Mutation: String, CaseIterable { case clear, delete, reset }

    private static func readRows(_ db: AppDatabase) throws -> [DictationSession] {
        try db.dbQueue.read { try SessionRecord.fetchAll($0).map { record in
            var session = record.toDictationSession()
            session.storedCharacterCount = record.charCount
            return session
        } }
    }

    @MainActor
    private static func mutate(_ mutation: Mutation, store: HistoryStore, model: HistoryPageModel,
                               selected: DictationSession) {
        switch mutation {
        case .clear: store.clearTranscripts()
        case .delete: model.delete(selected)
        case .reset:
            model.requestReset()
            model.continueReset()
            model.confirmReset()
        }
    }

    @MainActor
    private static func historyCommittedMutationsSurviveReadFailure(_ r: SelfTest.Reporter) {
        for mutation in Mutation.allCases {
            do {
                let (db, dir) = try database()
                defer { try? FileManager.default.removeItem(at: dir) }
                let effects = ValidationEffects.live.snapshot
                let first = fixture(raw: "12345", final: "first erased secret")
                let second = fixture(raw: "123", final: "second retained secret")
                try db.dbQueue.write { d in
                    var a = SessionRecord(from: first), b = SessionRecord(from: second)
                    try a.insert(d)
                    try b.insert(d)
                }
                let control = ReadControl()
                var refreshes = 0
                let store = HistoryStore(database: db, readSessions: {
                    if control.shouldFail { throw NSError(domain: "history-next-read", code: 1) }
                    return try readRows(db)
                }, refreshStats: { refreshes += 1 })
                var copies: [String] = [], exports: [HistoryExport] = []
                let model = HistoryPageModel(store: store, copy: { copies.append($0) }, export: { exports.append($0) })
                model.selectedID = first.id
                let staleSelection = model.selectedSession!
                let repository = StatsRepository(db: db)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let before = try encoder.encode(repository.buildDailyStats())
                var publishedSelectedText: [String] = []
                // Synchronous subscribers run inside @Published willSet. Actions must resolve
                // committed rows even if the rendered detail still holds the old value.
                let sessionsObserver = store.$sessions.dropFirst().sink { _ in
                    publishedSelectedText.append(model.selectedSession?.finalText ?? "")
                    model.copy(staleSelection)
                    model.exportText(staleSelection)
                    model.exportCSV()
                }
                let readObserver = store.$readState.dropFirst().sink { state in
                    guard state == .loading else { return }
                    publishedSelectedText.append(model.selectedSession?.finalText ?? "")
                    model.copy(staleSelection)
                    model.exportText(staleSelection)
                    model.exportJSON()
                }
                control.shouldFail = true
                mutate(mutation, store: store, model: model, selected: staleSelection)
                let prefix = "history committed \(mutation.rawValue)"
                if case .failed = store.readState {} else { r.check(false, "\(prefix): failed follow-up read is visible") }
                model.copy(staleSelection)
                model.exportText(staleSelection)
                model.exportCSV()
                model.exportJSON()
                r.check(copies.isEmpty, "\(prefix): stale detail cannot copy erased text, including reentrant actions")
                r.check(!exports.contains { if case .text = $0 { true } else { false } },
                        "\(prefix): stale detail cannot export erased text")
                r.check(publishedSelectedText.allSatisfy { $0.isEmpty },
                        "\(prefix): publication observers see no copyable stale selected detail")
                let payloads = try exports.map { String(decoding: try $0.data(), as: UTF8.self) }
                r.check(payloads.allSatisfy { !$0.contains(first.finalText) }, "\(prefix): bulk exports omit erased row text")
                let persisted = try db.dbQueue.read { try SessionRecord.fetchAll($0) }
                switch mutation {
                case .clear:
                    r.eq(persisted.count, 2, "\(prefix): database retains metadata rows")
                    r.check(persisted.allSatisfy { $0.rawTranscript == nil && $0.finalText == nil }, "\(prefix): database text is NULL")
                    r.eq(store.sessions.count, 2, "\(prefix): cache retains metadata rows after read failure")
                    r.check(store.sessions.allSatisfy { $0.rawTranscript.isEmpty && $0.finalText.isEmpty }, "\(prefix): both cached transcript fields cleared")
                    r.eq(model.selectedSession?.finalText, "", "\(prefix): selected detail is sanitized")
                    r.check(payloads.allSatisfy { !$0.contains(second.finalText) }, "\(prefix): all bulk text is empty")
                    let csv = payloads.first { $0.hasPrefix("startedAt,") } ?? ""
                    r.check(csv.contains("\"Fixture App\",\"zh\",\"5\",\"4000\",\"fixture-engine\",\"\""),
                            "\(prefix): CSV keeps original metadata and empty text")
                    r.eq(try encoder.encode(repository.buildDailyStats()), before, "\(prefix): statistics unchanged")
                case .delete:
                    r.eq(persisted.map(\.id), [second.id], "\(prefix): deleted database row absent")
                    r.eq(store.sessions.map(\.id), [second.id], "\(prefix): deleted cache row absent after read failure")
                    r.check(model.selectedSession == nil, "\(prefix): deleted selected detail absent")
                    r.eq(repository.buildDailyStats().reduce(0) { $0 + $1.totalWordCount }, 3, "\(prefix): only surviving row contributes statistics")
                case .reset:
                    r.eq(persisted.count, 0, "\(prefix): database reset committed")
                    r.eq(store.sessions.count, 0, "\(prefix): cache remains empty after read failure")
                    r.check(model.selectedSession == nil, "\(prefix): reset selected detail absent")
                    r.check(exports.isEmpty, "\(prefix): empty cache produces no bulk export effect")
                    r.eq(repository.buildDailyStats().count, 0, "\(prefix): reset statistics remain empty")
                }
                r.eq(refreshes, mutation == .clear ? 0 : 1, "\(prefix): correct statistics refresh count")
                control.shouldFail = false
                store.reload()
                r.eq(store.readState, .loaded, "\(prefix): explicit retry recovers post-mutation cache")
                r.eq(ValidationEffects.live.snapshot.blocked, effects.blocked, "\(prefix): no attempted live effects")
                r.eq(ValidationEffects.live.snapshot.permitted, effects.permitted, "\(prefix): no live effects")
                withExtendedLifetime((sessionsObserver, readObserver)) {}
            } catch { r.check(false, "history committed \(mutation): fixture failed: \(error)") }
        }
    }

    @MainActor
    private static func historyFailedWritesPreserveCache(_ r: SelfTest.Reporter) {
        for mutation in Mutation.allCases {
            do {
                let (db, dir) = try database()
                defer { try? FileManager.default.removeItem(at: dir) }
                let original = fixture(final: "write must preserve this text")
                var row = SessionRecord(from: original)
                try db.dbQueue.write { try row.insert($0) }
                let control = ReadControl()
                var refreshes = 0
                let store = HistoryStore(database: db, readSessions: {
                    if control.shouldFail { throw NSError(domain: "history-next-read", code: 1) }
                    return try readRows(db)
                }, refreshStats: { refreshes += 1 })
                var copies: [String] = [], exports: [HistoryExport] = []
                let model = HistoryPageModel(store: store, copy: { copies.append($0) }, export: { exports.append($0) })
                model.selectedID = original.id
                // Reset fails on its second DELETE, exercising transaction rollback of the first.
                let statement: String
                switch mutation {
                case .clear: statement = "BEFORE UPDATE ON session"
                case .delete: statement = "BEFORE DELETE ON session"
                case .reset: statement = "BEFORE DELETE ON daily_legacy"
                }
                try db.dbQueue.write { d in
                    if mutation == .reset { try d.execute(sql: "INSERT INTO daily_legacy(date) VALUES('2001-01-01')") }
                    try d.execute(sql: "CREATE TRIGGER reject_write \(statement) BEGIN SELECT RAISE(ABORT, 'fixture write rejected'); END")
                }
                control.shouldFail = true
                mutate(mutation, store: store, model: model, selected: original)
                let prefix = "history failed write \(mutation.rawValue)"
                r.eq(try readRows(db).map(\.finalText), [original.finalText], "\(prefix): database retains text/rolls back reset")
                r.eq(store.sessions.map(\.finalText), [original.finalText], "\(prefix): cache is not erased on write failure")
                r.eq(model.selectedSession?.id, original.id, "\(prefix): selection is not erased on write failure")
                model.copy(original)
                model.exportText(original)
                model.exportCSV()
                r.eq(copies, [original.finalText], "\(prefix): unchanged record remains copyable")
                r.eq(exports.count, 2, "\(prefix): unchanged record remains exportable")
                r.eq(refreshes, 0, "\(prefix): failed write does not refresh unchanged statistics")
            } catch { r.check(false, "history failed write \(mutation): fixture failed: \(error)") }
        }
    }


    @MainActor
    private static func historyReentrantMutationKeepsLatestState(_ r: SelfTest.Reporter) {
        do {
            let (db, dir) = try database()
            defer { try? FileManager.default.removeItem(at: dir) }
            let original = fixture(final: "reentrant erased secret")
            var row = SessionRecord(from: original)
            try db.dbQueue.write { try row.insert($0) }
            let control = ReadControl()
            let store = HistoryStore(database: db, readSessions: {
                if control.shouldFail { throw NSError(domain: "history-reentrant-read", code: 1) }
                return try readRows(db)
            }, refreshStats: {})
            var copies: [String] = [], exports: [HistoryExport] = []
            let model = HistoryPageModel(store: store, copy: { copies.append($0) }, export: { exports.append($0) })
            model.selectedID = original.id
            var cleared = false
            let observer = store.$sessions.dropFirst().sink { _ in
                guard !cleared else { return }
                cleared = true
                control.shouldFail = true
                store.clearTranscripts()
                model.copy(original)
                model.exportText(original)
            }
            store.reload()
            r.check(cleared, "history reentrant: subscriber completed the privacy mutation")
            r.eq(store.sessions.first?.finalText, "", "history reentrant: outer publication cannot restore erased text")
            r.eq(model.selectedSession?.rawTranscript, "", "history reentrant: selected authoritative raw text stays erased")
            r.check(copies.isEmpty && exports.isEmpty, "history reentrant: stale actions produce no effects")
            r.check({ if case .failed = store.readState { true } else { false } }(),
                    "history reentrant: older read completion cannot overwrite the mutation's failed read state")
            r.eq(try readRows(db).first?.finalText, "", "history reentrant: database privacy write committed")
            withExtendedLifetime(observer) {}
        } catch { r.check(false, "history reentrant fixture: \(error)") }
    }


    @MainActor
    private static func historyReadStatePublicationKeepsLatestFailure(_ r: SelfTest.Reporter) {
        let outerFailure = "outer history read failure"
        let nestedFailure = "latest mutation read failure"
        for target in [HistoryReadState.loading, .loaded, .failed(outerFailure)] {
            do {
                let (db, dir) = try database()
                defer { try? FileManager.default.removeItem(at: dir) }
                let effects = ValidationEffects.live.snapshot
                let original = fixture(raw: "original secret", final: "read-state erased secret")
                var record = SessionRecord(from: original)
                try db.dbQueue.write { try record.insert($0) }
                let control = ReadControl()
                let store = HistoryStore(database: db, readSessions: {
                    if let message = control.failureMessage {
                        throw NSError(domain: "history-publication", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: message])
                    }
                    return try readRows(db)
                }, refreshStats: {})
                var copies: [String] = [], exports: [HistoryExport] = []
                let model = HistoryPageModel(store: store, copy: { copies.append($0) }, export: { exports.append($0) })
                model.selectedID = original.id
                var mutated = false
                var events: [HistoryReadState] = []
                if case .failed = target { control.failureMessage = outerFailure }
                // Each actual store publication case gets its own deterministic one-shot
                // subscriber. Mutation and nested failed read run inside the outer willSet.
                let observer = store.$readState.dropFirst().sink { state in
                    events.append(state)
                    guard !mutated, state == target else { return }
                    mutated = true
                    control.failureMessage = nestedFailure
                    store.clearTranscripts()
                    model.copy(original)
                    model.exportText(original)
                    model.exportCSV()
                }
                store.reload()
                let prefix = "history read-state publication \(target)"
                r.check(mutated, "\(prefix): subscriber committed its one-shot mutation")
                r.eq(store.readState, .failed(nestedFailure), "\(prefix): latest failure survives outer assignment")
                r.eq(events.last, .failed(nestedFailure), "\(prefix): observers receive the latest failure")
                r.eq(store.sessions.first?.finalText, "", "\(prefix): displayed final text stays sanitized")
                r.eq(store.sessions.first?.rawTranscript, "", "\(prefix): displayed raw text stays sanitized")
                r.eq(model.selectedSession?.finalText, "", "\(prefix): selected committed text stays sanitized")
                model.copy(original)
                model.exportText(original)
                model.exportJSON()
                r.check(copies.isEmpty, "\(prefix): stale detail cannot copy erased text")
                r.check(!exports.contains { if case .text = $0 { true } else { false } }, "\(prefix): stale detail cannot export text")
                let payloads = try exports.map { String(decoding: try $0.data(), as: UTF8.self) }
                r.check(!payloads.isEmpty && payloads.allSatisfy { !$0.contains(original.finalText) && !$0.contains(original.rawTranscript) },
                        "\(prefix): bulk exports contain metadata without erased text")
                let persisted = try db.dbQueue.read { try SessionRecord.fetchAll($0) }
                r.check(persisted.count == 1 && persisted[0].finalText == nil && persisted[0].rawTranscript == nil,
                        "\(prefix): actual database clear committed")
                r.eq(ValidationEffects.live.snapshot.blocked, effects.blocked, "\(prefix): no attempted live effects")
                r.eq(ValidationEffects.live.snapshot.permitted, effects.permitted, "\(prefix): no live effects")
                withExtendedLifetime(observer) {}
            } catch { r.check(false, "history read-state publication \(target): fixture failed: \(error)") }
        }
    }

}
