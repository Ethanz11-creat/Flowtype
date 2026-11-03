import Foundation
import Combine
import GRDB

/// Real stores and repository fixtures under the self-test validation root; no application services.
enum NativeContentSelfTests {
    @MainActor static func run(_ r: SelfTest.Reporter) async {
        print("--- NativeContentSelfTests.overviewRangeAndSparseData ---")
        await overviewRangeAndSparseData(r)
        print("--- NativeContentSelfTests.dictionaryAndStyleReflectEffectiveState ---")
        dictionaryAndStyleReflectEffectiveState(r)
    }

    private static func directory() throws -> URL {
        let dir = RuntimeEnvironment.current.paths.applicationSupportDirectory
            .appendingPathComponent("native-content-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor private static func overviewRangeAndSparseData(_ r: SelfTest.Reporter) async {
        do {
            let dir = try directory()
            defer { try? FileManager.default.removeItem(at: dir) }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
            let now = cal.date(from: DateComponents(year: 2027, month: 1, day: 2, hour: 0, minute: 1))!
            func day(_ date: String, chars: Int, hour: Int) -> DailyStats {
                var hist = Array(repeating: 0, count: 24); hist[hour] = 1
                return DailyStats(date: date, totalDurationMs: 90_000, totalWordCount: chars,
                    sessionCount: 1, totalRecordingMs: 60_000, hourHistogram: hist)
            }
            let stats = [day("2027-01-02", chars: 90, hour: 0), day("2027-01-01", chars: 45, hour: 23),
                         day("2026-12-25", chars: 180, hour: 6), day("2026-11-01", chars: 360, hour: 12)]
            let all = StatsEngine.summarize(stats, range: .all, now: now, cal: cal)
            let month = StatsEngine.summarize(stats, range: .d30, now: now, cal: cal)
            let week = StatsEngine.summarize(stats, range: .d7, now: now, cal: cal)
            r.eq([all.chars, month.chars, week.chars], [675, 315, 135], "overview ranges: sparse totals cross year")
            r.eq([all.sessions, month.sessions, week.sessions], [4, 3, 2], "overview ranges: real session counts")
            r.eq(week.hourHistogram.count, 24, "overview hours: 24 real buckets")
            r.eq(week.hourHistogram[23], 1, "overview hours: before midnight retained")
            r.eq(week.hourHistogram[0], 1, "overview hours: after midnight retained")
            r.eq(week.hourHistogram[6], 0, "overview range excludes older hourly bucket")
            r.eq(month.hourHistogram[6], 1, "overview month adds older hourly bucket")
            r.eq(all.hourHistogram[12], 1, "overview all adds oldest hourly bucket")
            r.eq(week.recordingSeconds, 120, "overview recordingMs preferred over durationMs")
            r.eq(week.timeSavedSeconds, 60, "overview uses 45 CPM typing baseline")
            r.eq(week.avgSpeedCPM, 67, "overview speed uses actual recording duration")
            r.eq(week.currentStreak, 2, "overview streak crosses calendar year")
            r.eq(StatsEngine.activeDaysInMonth(stats, now: now, cal: cal), 2, "overview month caption keeps full dataset")
            r.eq(StatsEngine.longestStreakEndMonth(stats, now: now, cal: cal), 1, "overview best month crosses year")
            for range in StatsRange.allCases {
                let heat = StatsEngine.denseHeatmap(stats, range: .all, now: now, cal: cal)
                r.eq(heat.count, 365, "overview \(range): annual heatmap remains 365 days")
                r.eq(heat.last?.date, "2027-01-02", "overview \(range): annual endpoint local today")
                r.eq(heat.filter { $0.chars > 0 }.count, 4, "overview \(range): heatmap sparse without synthetic activity")
            }
            let oldOnly = [day("2026-11-01", chars: 360, hour: 12)]
            for range in [StatsRange.d7, .d30] {
                r.check(StatsEngine.summarize(oldOnly, range: range, now: now, cal: cal).isEmpty,
                        "overview empty range: selected range is empty")
                r.eq(OverviewPage.emptyMessage(allStats: oldOnly), "所选时间范围内暂无口述记录",
                     "overview empty range: older activity does not imply first use")
                r.eq(StatsEngine.denseHeatmap(oldOnly, range: .all, now: now, cal: cal).filter { $0.chars > 0 }.count, 1,
                     "overview empty range: older annual activity retained")
            }
            r.eq(OverviewPage.emptyMessage(allStats: []), "开始你的第一次口述，数据会出现在这里",
                 "overview true first use: first dictation guidance")
            let legacy = DailyStats(date: "2027-01-02", totalDurationMs: 120_000, totalWordCount: 90, sessionCount: 1)
            r.eq(StatsEngine.summarize([legacy], range: .all, now: now, cal: cal).avgSpeedCPM, 45,
                 "overview legacy falls back to durationMs")
            let empty = StatsEngine.summarize([], range: .d7, now: now, cal: cal)
            r.eq(empty.hourHistogram, Array(repeating: 0, count: 24), "overview empty retains real zero buckets")
            r.check(empty.peakHour == nil && empty.isEmpty, "overview empty has no fictitious peak")
            r.check(StatsEngine.denseHeatmap([], range: .all, now: now, cal: cal).allSatisfy { $0.level == 0 },
                    "overview empty heatmap has no fake cells")
            r.eq(StatsConfig.milestones, [3, 7, 14, 30, 60, 100, 365], "overview preserves all seven milestones")
            r.check(FunFact.make(for: empty).isEmpty, "overview zero has no invented footer saving")
            var coffee = empty; coffee.chars = 500; coffee.timeSavedSeconds = 300
            r.eq(FunFact.make(for: coffee).clauses.last?.icon, "cup.and.saucer", "overview coffee threshold retained")
            coffee.timeSavedSeconds = 7200
            r.eq(FunFact.make(for: coffee).clauses.last?.icon, "film", "overview movie threshold retained")

            let db = try AppDatabase(try DatabaseQueue(path: dir.appendingPathComponent("raw.sqlite").path), isOnDisk: true)
            let session = DictationSession(rawTranscript: "原文 Raw", finalText: "整理后的文本长度明显不同", polishMode: .polish,
                durationMs: 9000, recordingMs: 4000, appName: "Fixture", appBundleID: "fixture", language: "zh", sttBackend: "fixture")
            let record = SessionRecord(from: session)
            try await db.dbQueue.write { db in var inserted = record; try inserted.insert(db) }
            let rawStats = StatsRepository(db: db).buildDailyStats(now: now, cal: cal)
            r.eq(rawStats.reduce(0) { $0 + $1.totalWordCount }, session.rawTranscript.count,
                 "overview repository preserves raw recognized characters rather than polished length")
            let effects = ValidationEffects.live.snapshot
            let store = DailyStatsStore(stats: [], readStats: { stats })
            var publications = 0
            let observation = store.$stats.sink { _ in publications += 1 }
            store.refresh()
            for _ in 0..<20 where store.stats.isEmpty { await Task.yield() }
            r.eq(store.stats.count, 4, "overview injected source refresh publishes fixture dataset")
            r.check(publications >= 2, "overview refresh reaches subscribers")
            r.eq(ValidationEffects.live.snapshot.blocked, effects.blocked, "overview injected refresh attempts no system effects")
            withExtendedLifetime(observation) {}
        } catch { r.check(false, "overview fixtures: \(error)") }
    }

    @MainActor private static func dictionaryAndStyleReflectEffectiveState(_ r: SelfTest.Reporter) {
        do {
            let dir = try directory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let dictionary = DictionaryStore(store: PersistentStore(filename: "dictionary.json", directory: dir))
            r.eq(DictionaryPresentation.enabledRatio(dictionary.entries), 0, "dictionary ratio 0/0 is zero")
            r.check(!DictionaryPresentation.add(phrase: " \n\r\t", note: nil, to: dictionary),
                    "dictionary UI rejects whitespace/newline-only phrase")
            r.eq(dictionary.entries.count, 0, "dictionary rejected input has no store side effects")
            r.check(DictionaryPresentation.add(phrase: "  FlowType  ", note: "中英混合 note", to: dictionary), "dictionary UI adds valid phrase")
            r.eq(dictionary.entries.first?.phrase, "FlowType", "dictionary retains store whitespace normalization")
            dictionary.add(phrase: "\nLegacy\n")
            r.eq(dictionary.entries.last?.phrase, "\nLegacy\n", "dictionary backend newline normalization is unchanged")
            var observedRatios: [Double] = []
            let observation = dictionary.$entries.sink { observedRatios.append(DictionaryPresentation.enabledRatio($0)) }
            dictionary.setEnabled(id: dictionary.entries[0].id, false)
            r.eq(DictionaryPresentation.enabledRatio(dictionary.entries), 0.5, "dictionary visible toggle changes overview ratio")
            r.eq(observedRatios.last, 0.5, "dictionary enabled ratio change is observable")
            dictionary.incrementHits(ids: [dictionary.entries[1].id])
            r.eq(dictionary.entries[1].hits, 1, "dictionary hits remain visible data")
            let filtered = DictionaryPresentation.filtered(dictionary.entries, search: "note")
            r.eq(filtered.count, 1, "dictionary search includes notes")
            r.eq(dictionary.entries.count, 2, "dictionary search only filters display")
            dictionary.remove(id: dictionary.entries[0].id)
            r.eq(DictionaryPresentation.enabledRatio(dictionary.entries), 1, "dictionary deletion updates denominator")
            withExtendedLifetime(observation) {}

            let styles = StylePackStore(store: PersistentStore(filename: "styles.json", directory: dir))
            let model = StylePageModel(store: styles)
            let constructionEffects = ValidationEffects.live.snapshot
            let _ = VocabPage(store: dictionary)
            let _ = OverviewPage(statsStore: DailyStatsStore(stats: [], readStats: { [] }),
                dictionaryStore: dictionary, openDictionary: {})
            let _ = StylePage(store: styles, model: model, export: { _, _ in })
            r.eq(ValidationEffects.live.snapshot.blocked, constructionEffects.blocked,
                 "content injected page construction attempts no production effects")
            var config = Configuration.default; config.systemPrompt = "isolated configuration fallback"
            r.check(StylePresentation.effectiveSource(pack: styles.activePack, configuration: config).contains("活动风格"),
                    "style source identifies enabled active builtin")
            let custom = styles.createCustom(name: "混合 Long Style", prompt: "custom prompt")
            styles.setActive(id: custom.id)
            r.eq(styles.activePack?.prompt, "custom prompt", "style active custom supplies effective prompt")
            r.check(StylePresentation.effectiveSource(pack: styles.activePack, configuration: config).contains(custom.name),
                    "style effective source names actual active pack")
            let request = NavigationRequest(id: UUID(), destination: .style(custom.id))
            model.consume(request)
            r.eq(model.selectedID, custom.id, "style deep link selects requested pack")
            model.consume(NavigationRequest(id: UUID(), destination: .style(custom.id)))
            r.check(model.navigationRequestID != request.id && model.navigationRequestID != nil,
                    "style repeated same-pack deep links consume new request identity")
            model.newName = "unsaved name"; model.newPrompt = "unsaved prompt"
            var draft = custom; draft.prompt = "unsaved edited prompt"; model.editingPack = draft
            let before = styles.packs.count
            model.importData(Data("invalid JSON".utf8))
            r.check(model.importExportError != nil, "style failed import exposes error")
            r.eq(styles.packs.count, before, "style failed import preserves store")
            r.eq(styles.activePack?.id, custom.id, "style failed import preserves active selection")
            r.eq(model.editingPack?.id, custom.id, "style failed import preserves editing draft")
            r.eq(model.editingPack?.prompt, "unsaved edited prompt", "style failed import preserves edited draft contents")
            r.eq([model.newName, model.newPrompt], ["unsaved name", "unsaved prompt"], "style failed import preserves new draft fields")
            let exported = styles.exportToJSON(id: custom.id)!
            model.importData(exported)
            r.eq(styles.packs.last?.kind, .imported, "style JSON round trip becomes imported pack")
            r.eq(styles.activePack?.id, custom.id, "style importing does not switch active pack")
            styles.delete(id: "builtin.structured")
            r.check(styles.packs.contains { $0.id == "builtin.structured" }, "style builtin cannot be deleted")
            styles.delete(id: custom.id)
            r.eq(styles.activePack?.id, "builtin.structured", "style deleting active custom falls back to structured")
            styles.setActive(id: "missing")
            r.check(StylePresentation.effectiveSource(pack: styles.activePack, configuration: config).contains("内置回退"),
                    "style source distinguishes fallback from explicit activity")
            r.eq(StylePresentation.effectiveSource(pack: nil, configuration: config), "高级默认提示词（配置）",
                 "style no-pack source is configuration fallback")
        } catch { r.check(false, "dictionary/style fixtures: \(error)") }
    }
}
