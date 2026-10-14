import Foundation
import Combine

/// Lightweight, dependency-free self-tests that run WITHOUT Xcode / XCTest.
///
/// This machine (and any Command-Line-Tools-only setup) has no `XCTest` or
/// `Testing` module, so `swift test` cannot run. These checks live inside the
/// FlowType target (so they have `internal` access to the code under test) and
/// are invoked via `swift run FlowType --self-test`, exiting 0 on all-pass and 1
/// on any failure. They are pure-logic regression guards for the fixed bugs;
/// system/hardware/UI behaviours (audio device, AX, CGEvent) are verified
/// manually and noted in the diagnostic report, not here.
enum SelfTest {

    final class Reporter {
        private(set) var passed = 0
        private(set) var failed = 0

        func check(_ cond: Bool, _ msg: String) {
            if cond {
                passed += 1
            } else {
                failed += 1
                FileHandle.standardError.write(Data("  ✗ FAIL: \(msg)\n".utf8))
            }
        }

        func eq<T: Equatable>(_ got: T, _ want: T, _ msg: String) {
            check(got == want, "\(msg) — got \(String(describing: got)), want \(String(describing: want))")
        }
    }

    // MARK: - PolishMode: 2 modes (raw/polish) + legacy-record migration

    static func testPolishModeMigration(_ r: Reporter) {
        func decode(_ raw: String) -> PolishMode? {
            try? JSONDecoder().decode(PolishMode.self, from: Data("\"\(raw)\"".utf8))
        }
        r.check(decode("raw") == .raw, "polishMode: raw → raw")
        r.check(decode("polish") == .polish, "polishMode: polish → polish")
        r.check(decode("light") == .polish, "polishMode: legacy light → polish")
        r.check(decode("structured") == .polish, "polishMode: legacy structured → polish")
        r.check(decode("formal") == .polish, "polishMode: legacy formal → polish")
        r.eq(PolishMode.allCases.count, 2, "polishMode: exactly 2 modes")
    }

    // MARK: - Injection delivery decision (classifyFocus + decideInjection)

    static func testInjectionDecision(_ r: Reporter) {
        // classifyFocus: role + settable → kind
        r.eq(classifyFocus(role: "AXTextField", isValueSettable: false), .editableText,
             "inject: AXTextField → editableText")
        r.eq(classifyFocus(role: "AXTextArea", isValueSettable: false), .editableText,
             "inject: AXTextArea → editableText")
        r.eq(classifyFocus(role: "AXComboBox", isValueSettable: false), .editableText,
             "inject: AXComboBox → editableText")
        r.eq(classifyFocus(role: "AXSearchField", isValueSettable: false), .editableText,
             "inject: AXSearchField → editableText")
        r.eq(classifyFocus(role: "AXButton", isValueSettable: false), .nonTextControl,
             "inject: AXButton → nonTextControl")
        r.eq(classifyFocus(role: "AXMenuItem", isValueSettable: false), .nonTextControl,
             "inject: AXMenuItem (status bar) → nonTextControl")
        r.eq(classifyFocus(role: "AXSlider", isValueSettable: true), .nonTextControl,
             "inject: settable slider stays nonTextControl (not text)")
        r.eq(classifyFocus(role: "AXGroup", isValueSettable: true), .editableText,
             "inject: settable generic role → editableText (web/custom editor)")
        r.eq(classifyFocus(role: "AXGroup", isValueSettable: false), .blindOrUnknown,
             "inject: generic non-settable → blindOrUnknown")
        r.eq(classifyFocus(role: nil, isValueSettable: false), .blindOrUnknown,
             "inject: no role → blindOrUnknown")

        // decideInjection: signals → outcome (spec §4 rows 0–3)
        r.eq(decideInjection(FocusSignals(secureInputActive: true, focus: .editableText)), .clipboard,
             "inject: secure input → clipboard (row 0)")
        r.eq(decideInjection(FocusSignals(secureInputActive: true, focus: .nonTextControl)), .clipboard,
             "inject: secure input dominates nonTextControl → clipboard (row 0)")
        r.eq(decideInjection(FocusSignals(secureInputActive: true, focus: .blindOrUnknown)), .clipboard,
             "inject: secure input dominates blind → clipboard (row 0)")
        r.eq(decideInjection(FocusSignals(secureInputActive: false, focus: .editableText)), .inject,
             "inject: editable text → inject (row 1)")
        r.eq(decideInjection(FocusSignals(secureInputActive: false, focus: .nonTextControl)), .clipboard,
             "inject: non-text control → clipboard (row 2)")
        r.eq(decideInjection(FocusSignals(secureInputActive: false, focus: .blindOrUnknown)), .inject,
             "inject: blind/unknown → inject, fail open (row 3)")
    }

    // MARK: - Appearance preference: round-trip + legacy default

    static func testAppearanceConfig(_ r: Reporter) {
        var cfg = Configuration()
        cfg.appearancePreference = .dark
        if let data = try? JSONEncoder().encode(cfg),
           let back = try? JSONDecoder().decode(Configuration.self, from: data) {
            r.eq(back.appearancePreference, .dark, "appearance: round-trips .dark")
        } else {
            r.check(false, "appearance: encode/decode round-trip failed")
        }
        // A config saved before this field existed must default to .system (not crash).
        let legacy = Data("{\"asrLanguage\":\"zh\"}".utf8)
        let decoded = try? JSONDecoder().decode(Configuration.self, from: legacy)
        r.eq(decoded?.appearancePreference, .system, "appearance: legacy missing key → .system")
    }

    // MARK: - Model provisioning config: round-trip + legacy default

    static func testModelConfig(_ r: Reporter) {
        // Round-trip: localModelPath + downloadSource survive encode→decode
        var cfg = Configuration()
        cfg.localModelPath = "/tmp/m"
        cfg.downloadSource = .mirror
        if let data = try? JSONEncoder().encode(cfg),
           let back = try? JSONDecoder().decode(Configuration.self, from: data) {
            r.eq(back.localModelPath, "/tmp/m", "modelcfg: localModelPath round-trips")
            r.eq(back.downloadSource, .mirror, "modelcfg: downloadSource round-trips .mirror")
        } else {
            r.check(false, "modelcfg: encode/decode round-trip failed")
            r.check(false, "modelcfg: encode/decode round-trip failed (downloadSource)")
        }
        // Legacy JSON without the new keys → defaults
        let legacy = Data("{\"asrLanguage\":\"zh\"}".utf8)
        let decoded = try? JSONDecoder().decode(Configuration.self, from: legacy)
        r.eq(decoded?.localModelPath, nil, "modelcfg: legacy missing key → localModelPath nil")
        r.eq(decoded?.downloadSource, .auto, "modelcfg: legacy missing key → downloadSource .auto")
    }

    // MARK: - DownloadSource endpoint mapping

    static func testDownloadSource(_ r: Reporter) {
        r.eq(DownloadSource.auto.endpoint(isChina: true), "https://hf-mirror.com", "src: auto+CN → mirror")
        r.eq(DownloadSource.auto.endpoint(isChina: false), nil, "src: auto+非CN → 官方(nil)")
        r.eq(DownloadSource.official.endpoint(isChina: true), nil, "src: official → nil")
        r.eq(DownloadSource.mirror.endpoint(isChina: false), "https://hf-mirror.com", "src: mirror → mirror")
        r.eq(DownloadSource.custom("https://x.example").endpoint(isChina: false), "https://x.example", "src: custom → custom")
        r.eq(DownloadSource.custom("   ").endpoint(isChina: false), nil, "src: blank custom → nil")
    }

    // MARK: - ModelLocator: completeness validation

    static func testModelLocator(_ r: Reporter) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("flowtype-modeltest-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        func write(_ name: String, _ bytes: Int) {
            fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data(count: bytes))
        }
        r.check(!ModelLocator.validateComplete(dir, minBytes: 100), "locator: empty dir → incomplete")
        write("config.json", 10); write("tokenizer.json", 10); write("model.safetensors", 200)
        r.check(ModelLocator.validateComplete(dir, minBytes: 100), "locator: config+tok+big weights → complete")
        r.check(!ModelLocator.validateComplete(dir, minBytes: 1000), "locator: weights below floor → incomplete")
        try? fm.removeItem(at: dir.appendingPathComponent("config.json"))
        r.check(!ModelLocator.validateComplete(dir, minBytes: 100), "locator: missing config → incomplete")
    }

    // MARK: - Stats data model: language tag + legacy decode

    static func testStatsDataModel(_ r: Reporter) {
        // language heuristic
        r.eq(detectLanguageTag("你好世界"), "zh", "lang: CJK → zh")
        r.eq(detectLanguageTag("hello world"), "en", "lang: latin → en")
        r.eq(detectLanguageTag("hello 你好世界吗"), "mixed", "lang: mixed → mixed")
        r.eq(detectLanguageTag("   "), nil, "lang: blank → nil")
        r.eq(detectLanguageTag("こんにちは、ありがとうございます"), "ja", "lang: kana → ja")
        r.eq(detectLanguageTag("日本語を勉強しています"), "ja", "lang: kanji+kana mix → ja")
        r.eq(detectLanguageTag("안녕하세요 반갑습니다"), "ko", "lang: hangul → ko")
        // old DictationSession JSON (no new keys) still decodes
        let oldSession = Data(#"{"id":"x","createdAt":"2026-01-01T00:00:00Z","rawTranscript":"a","finalText":"a","polishMode":"raw","durationMs":1000}"#.utf8)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let s = try? dec.decode(DictationSession.self, from: oldSession)
        r.check(s != nil, "session: legacy JSON still decodes after new metric fields")
        r.eq(s?.recordingMs, nil, "session: legacy decodes, recordingMs nil")
        r.eq(s?.appName, nil, "session: legacy decodes, appName nil")
        r.eq(s?.usedFallback, nil, "session: legacy decodes, usedFallback nil")
        // old DailyStats JSON (no new keys) → defaults
        let oldDaily = Data(#"{"date":"2026-01-01","totalDurationMs":1000,"totalWordCount":5,"sessionCount":1}"#.utf8)
        let d = try? JSONDecoder().decode(DailyStats.self, from: oldDaily)
        r.eq(d?.totalRecordingMs, 0, "daily: legacy decodes, totalRecordingMs 0")
        r.eq(d?.hourHistogram.count, 24, "daily: legacy decodes, hourHistogram default 24")
    }

    // MARK: - StatsEngine: metrics, streaks, heatmap

    static func testStatsEngine(_ r: Reporter) {
        func day(_ d: String, chars: Int, recMs: UInt64, sessions: Int = 1, hist: [Int]? = nil) -> DailyStats {
            DailyStats(date: d, totalDurationMs: recMs, totalWordCount: chars, sessionCount: sessions,
                       totalRecordingMs: recMs, byApp: [:], byLang: [:],
                       hourHistogram: hist ?? Array(repeating: 0, count: 24))
        }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = StatsEngine.parseDate("2026-06-03", cal)!

        // speed regression: 100 chars over 50s pure recording = 100 / (50/60) = 120 CPM
        let one = StatsEngine.summarize([day("2026-06-03", chars: 100, recMs: 50_000)], range: .all, now: now, cal: cal)
        r.eq(one.avgSpeedCPM, 120, "engine: speed = chars/(recSec/60) = 120")
        r.check(one.timeSavedSeconds >= 0, "engine: timeSaved never negative")
        // timeSaved precise: Int(100/45*60)=133, recSec=50, 133-50=83
        r.eq(one.timeSavedSeconds, 83, "engine: timeSaved = chars/45*60 − recSec")
        // max(0,…) clamp: few chars over a long recording → timeSaved must be 0, not negative
        let longRec = StatsEngine.summarize([day("2026-06-03", chars: 5, recMs: 600_000)], range: .all, now: now, cal: cal)
        r.eq(longRec.timeSavedSeconds, 0, "engine: timeSaved clamped to 0 when recording exceeds typing estimate")

        // empty → zeros, no crash
        let empty = StatsEngine.summarize([], range: .all, now: now, cal: cal)
        r.check(empty.isEmpty && empty.avgSpeedCPM == 0 && empty.currentStreak == 0, "engine: empty → zeros")

        // levels
        r.eq(StatsEngine.level(0, max: 100), 0, "engine: level 0")
        r.eq(StatsEngine.level(100, max: 100), 4, "engine: level max → 4")

        // streaks
        r.eq(StatsEngine.longestRun([1,2,3,5,6]), 3, "engine: longest run 3")
        r.eq(StatsEngine.currentRun([10,9,8], todayOrdinal: 10), 3, "engine: current streak today-anchored 3")
        r.eq(StatsEngine.currentRun([9,8], todayOrdinal: 10), 2, "engine: current streak yesterday-anchored 2")
        r.eq(StatsEngine.currentRun([5], todayOrdinal: 10), 0, "engine: stale → 0")

        // peakHour / hour-histogram aggregation
        var h = Array(repeating: 0, count: 24); h[21] = 5; h[9] = 2
        let peakDay = DailyStats(date: "2026-06-03", totalDurationMs: 10_000, totalWordCount: 50, sessionCount: 1,
                                 totalRecordingMs: 10_000, byApp: [:], byLang: [:], hourHistogram: h)
        let peakSummary = StatsEngine.summarize([peakDay], range: .all, now: now, cal: cal)
        r.eq(peakSummary.peakHour, 21, "engine: peakHour is bucket with most sessions (hour 21)")
        // all-zero histogram → peakHour nil
        let zeroPeak = StatsEngine.summarize([day("2026-06-03", chars: 5, recMs: 5000)], range: .all, now: now, cal: cal)
        r.check(zeroPeak.peakHour == nil, "engine: all-zero histogram → peakHour nil")

        // range filter keeps only recent
        let many = [day("2026-01-01", chars: 5, recMs: 5000), day("2026-06-01", chars: 5, recMs: 5000), day("2026-06-03", chars: 5, recMs: 5000)]
        r.eq(StatsEngine.summarize(many, range: .d7, now: now, cal: cal).activeDays, 2, "engine: 7d keeps 06-01 & 06-03")
        r.eq(StatsEngine.summarize(many, range: .all, now: now, cal: cal).activeDays, 3, "engine: all keeps 3")

        // speed denominator: totalRecordingMs vs totalDurationMs must differ
        // 100 chars / (60_000ms = 1 min) = 100 CPM using recordingMs; durationMs(600_000) would give 10 CPM
        let diffMs = DailyStats(date: "2026-06-03", totalDurationMs: 600_000, totalWordCount: 100, sessionCount: 1,
                                totalRecordingMs: 60_000, byApp: [:], byLang: [:],
                                hourHistogram: Array(repeating: 0, count: 24))
        let s = StatsEngine.summarize([diffMs], range: .all, now: now, cal: cal)
        r.eq(s.avgSpeedCPM, 100, "engine: speed uses recordingMs not durationMs")

        // legacy fallback: totalRecordingMs == 0 → fall back to durationMs (100 chars / 1 min = 100 CPM)
        let legacyMs = DailyStats(date: "2026-06-03", totalDurationMs: 60_000, totalWordCount: 100, sessionCount: 1,
                                  totalRecordingMs: 0, byApp: [:], byLang: [:],
                                  hourHistogram: Array(repeating: 0, count: 24))
        let sl = StatsEngine.summarize([legacyMs], range: .all, now: now, cal: cal)
        r.eq(sl.avgSpeedCPM, 100, "engine: speed falls back to durationMs when recordingMs is 0")
    }

    // MARK: - StatsEngine: dense heatmap (full range, missing days = 0)

    static func testHeatmapDensity(_ r: Reporter) {
        func day(_ d: String, chars: Int, recMs: UInt64, sessions: Int = 1, hist: [Int]? = nil) -> DailyStats {
            DailyStats(date: d, totalDurationMs: recMs, totalWordCount: chars, sessionCount: sessions,
                       totalRecordingMs: recMs, byApp: [:], byLang: [:],
                       hourHistogram: hist ?? Array(repeating: 0, count: 24))
        }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = StatsEngine.parseDate("2026-06-03", cal)!

        // dense heatmap: 7d range → exactly 7 cells even with one data day
        let h7 = StatsEngine.denseHeatmap([day("2026-06-03", chars: 100, recMs: 1000)], range: .d7, now: now, cal: cal)
        r.eq(h7.count, 7, "heatmap: 7d → 7 cells (dense)")
        r.eq(h7.last?.date, "2026-06-03", "heatmap: last cell is today")
        r.eq(h7.filter { $0.chars > 0 }.count, 1, "heatmap: only the one data day is non-zero")
        r.eq(StatsEngine.denseHeatmap([], range: .d30, now: now, cal: cal).count, 30, "heatmap: 30d empty → 30 zero cells")
        r.check((0...6).contains(h7[0].weekday), "heatmap: weekday in 0...6")
    }

    @MainActor
    static func runAndExit() async -> Never {
        let r = Reporter()
        print("=== FlowType --self-test ===")
        testLLMURL(r)            // B1
        testSSEParse(r)          // B8
        testLLMFailoverGuards(r) // failover-after-yield guard + inactivity watchdog clock
        testModifierTapMachine(r) // modifier-trigger edge machine + detector window
        testContinuationBox(r)   // exactly-once continuation resume (ASR providers)
        testConfigCorrupt(r)     // B9
        testInjectionEdgeCases(r) // injection edge cases: emoji/newlines/config/continuation
        testInjectionSegmentation(r) // injection helpers
        testASRWiring(r)         // ASR language + context
        testSpectrumMath(r)      // SpectrumMath pure DSP helpers
        testFFTPeak(r)           // SpectrumAnalyzer FFT correctness
        testSpectrumProcess(r)   // SpectrumAnalyzer.process smoothed bands
        testStatFormatting(r)    // StatFormatting pure formatters
        testPolishModeMigration(r) // history mode raw/polish + legacy decode
        testHistoryMode(r)         // polish-degrade → history label .raw
        testPolishDegradeTexts(r)  // polish-degrade → keep PostProcess text + stage-name sync
        testCorrectionCandidates(r) // dictionary auto-detect: CJK sentence pollution guards
        testLLMWatchdogVerdict(r)  // LLM watchdog: idle + pre-first-token hard cap
        testCharCountSemantics(r)  // charCount grapheme-cluster semantics (CJK parity)
        testProviderAPIKeyLocal(r) // local API-key storage round-trip
        testConfigFlushAndSetterFallback(r) // flush-on-quit + setter fallback + stale-snapshot trap
        testFunFact(r)             // fun-fact footer clauses
        testInjectionDecision(r)   // delivery decision: classifyFocus + decideInjection
        testAppearanceConfig(r)    // appearance pref round-trip + legacy default
        testModelConfig(r)         // model provisioning fields: round-trip + legacy default
        testDownloadSource(r)      // DownloadSource endpoint mapping
        testModelLocator(r)        // ModelLocator completeness validation
        testStatsDataModel(r)      // stats data model: language tag + legacy decode
        testStatsEngine(r)         // StatsEngine: metrics, streaks, heatmap
        testHeatmapDensity(r)      // StatsEngine: dense heatmap (full range, missing days = 0)
        testDatabaseSchema(r)      // GRDB schema: session/daily_legacy/meta tables
        testSessionRecord(r)       // SessionRecord round-trip + charCount/sttBackend/recordingMs
        testStatsRepository(r)     // StatsRepository boundary fold: legacy/session/boundary
        testJSONMigration(r)       // JSONMigration: idempotent import + sttBackend tagging
        testPrivacyConfig(r)       // storeTranscriptText: round-trip + legacy default true
        testASRConfig(r)           // ASR engine config: round-trip + legacy default
        testASRRouting(r)          // unified ASR routing: pure chain selection
        testRoutingKeyPrecedence(r) // legacy asrEngine wins when both routing keys present
        testProviderContextCompose(r) // ASRContext → provider prompt hint
        testASRBackendLabel(r)     // context.usedProviderID → history backend label
        testFallbackReasonClassification(r) // provider failure → aggregatable fallback reason
        testASRCapabilityContract(r) // provider capability contract (router requiresNetwork gate)
        testRouterEWMA(r)          // ASR router health: EWMA update math
        testCloudProbe(r)          // cloud host probe: endpoint parse + threshold isolation + cold-start chain
        testPathChangeDetection(r) // network switch must invalidate the cached probe sample
        testLinkSampleInvalidation(r) // which samples die on a link change (probe + stale EWMA)
        testAgedLatencySample(r)   // EWMA TTL: stale fast sample re-decided by the probe
        testRoutingInputsWiring(r) // production wiring: snapshot → aging → decision
        testProbeGating(r)         // when the probe is allowed to spend a handshake at all
        testContextAssembly(r)     // ForegroundContext → bounded context text + redaction
        testSecureFocus(r)         // secure (password) focus → never collect value
        testSessionMetrics(r)      // percentile + metrics report
        testMetricsSchema(r)       // v4 metrics columns persist
        testCloudContextToggle(r)  // cloud context opt-out default + round-trip
        testHardwareProfiler(r)    // HardwareProfiler: memory tier classification
        testModelPreset(r)         // ModelPreset: preset catalog + tier recommendation
        testCustomModelScanner(r)  // CustomModelScanner: validateModelDirectory error cases + success
        testStopGestureTimeline(r) // first-release stop, pending taps, idle compatibility
        testNonModifierRepeat(r)
        testAudioFeedbackTimeline(r)
        testPolishOnStopConfig(r)  // default/migration and persisted opt-out
        testStableSessionPresentation(r) // no provider or streaming text in capsule
        testSessionExperience(r)   // readiness, cancellation, and stale session ownership
        await testSessionRecoveryDelivery(r)
        await testRecoveryActions(r)
        await testPolishStreamCompleteness(r)
        await testPolishStreamTermination(r)
        await testAsyncDeadline(r)
        await testPolishDelivery(r)
        await testStageOwnership(r) // actual async wrapper, before/during cancellation
        print("=== self-test: \(r.passed) passed, \(r.failed) failed ===")
        exit(r.failed == 0 ? 0 : 1)
    }

    private final class DeliveryLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func append(_ text: String) { lock.lock(); entries.append(text); lock.unlock() }
        var value: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    }

    @MainActor
    private final class TransitionLog: @preconcurrency SessionObserver {
        var events: [String] = []
        func sessionDidTransition(from oldState: SessionState, to newState: SessionState, context: SessionContext) {
            if case .notice = newState { events.append("notice") }
        }
    }

    private actor RetryLedger {
        var polishRequests: [Bool] = []
        func visit(_ polish: Bool) -> Bool { polishRequests.append(polish); return polishRequests.count == 1 }
    }

    private struct RetryASRStage: PipelineStage {
        let name = "ASR"
        let ledger: RetryLedger
        func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
            let polish = await MainActor.run { context.usePolish }
            if await ledger.visit(polish) {
                return .suspend(ErrorRecoveryContext(failedStage: name, error: LLMError.invalidResponse, rawText: nil, retryable: true))
            }
            return .complete
        }
    }

    private struct ProcessedStarter: PipelineStage {
        let name = "Processed starter"
        func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
            await MainActor.run { context.usePolish = true }
            return .continue(.processed("你好，世界。", raw: "你好世界"))
        }
    }

    @MainActor
    private static func waitForSession(_ controller: SessionController, until predicate: (SessionState) -> Bool) async {
        for _ in 0..<100 {
            if predicate(controller.sessionState) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    static func testSessionRecoveryDelivery(_ r: Reporter) async {
        let ledger = RetryLedger()
        let quietEffects = SessionEffects(prepare: {}, showWindow: {}, hideWindow: {}, saveHistory: { _ in })
        let recovery = SessionController(pipeline: [RetryASRStage(ledger: ledger)], observers: [], effects: quietEffects)
        recovery.startRecording()
        await waitForSession(recovery) { if case .error = $0 { return true }; return false }
        let immediateLedger = RetryLedger()
        let immediate = SessionController(pipeline: [RetryASRStage(ledger: immediateLedger)], observers: [], effects: quietEffects)
        immediate.startRecording()
        await waitForSession(immediate) { if case .error = $0 { return true }; return false }
        immediate.retryFailedStage()
        await waitForSession(immediate) { $0 == .idle }
        r.eq(await immediateLedger.polishRequests, [false, false], "recovery: immediate ASR retry preserves configured polish flag")
        immediate.cancel()
        try? await Task.sleep(for: .seconds(5.2))
        if case .error = recovery.sessionState { r.check(true, "recovery: actionable error persists beyond former five-second dismissal") }
        else { r.check(false, "recovery: actionable error persists beyond former five-second dismissal") }
        recovery.retryFailedStage()
        await waitForSession(recovery) { $0 == .idle }
        r.eq(await ledger.polishRequests, [false, false], "recovery: retry reruns ASR without forcing polish preference")
        recovery.cancel()

        var configured = Configuration()
        configured.llmProviders = [.defaultSiliconFlow()]
        configured.providerAPIKeys[configured.llmProviders[0].id.uuidString] = "test-key"
        let config = configured
        let log = TransitionLog()
        let failure = PolishStage(configuration: { config }, streamFactory: { _, _ in
            AsyncThrowingStream { $0.yield("partial"); $0.finish(throwing: LLMError.invalidResponse) }
        })
        let delivery = InjectionStage(settle: {}, focus: { FocusSignals(secureInputActive: true, focus: .blindOrUnknown) },
                                     copy: { text in log.events.append("delivered:\(text)") })
        let effects = SessionEffects(prepare: {}, showWindow: {}, hideWindow: {}, saveHistory: { _ in log.events.append("history") })
        let session = SessionController(pipeline: [ProcessedStarter(), failure, delivery], observers: [log], effects: effects)
        session.startRecording()
        await waitForSession(session) { if case .notice = $0 { return true }; return $0 == .idle }
        r.eq(log.events, ["delivered:你好，世界。", "history", "notice"], "session: complete processed delivery precedes single history save and gentle notice")
        session.cancel()
    }

    @MainActor
    static func testRecoveryActions(_ r: Reporter) async {
        let asr = ErrorRecoveryContext(failedStage: "ASR", error: LLMError.invalidResponse, rawText: nil, retryable: true)
        r.eq(SessionController.buildErrorActions(from: asr).map(\.displayName), ["重试识别", "忽略"], "recovery: ASR retry label describes failed stage")
        let processed = ErrorRecoveryContext(failedStage: "PostProcess", error: LLMError.invalidResponse, rawText: "完整文本", retryable: true)
        r.eq(SessionController.buildErrorActions(from: processed).map(\.displayName), ["重试处理", "复制原文", "忽略"], "recovery: non-polish retry label and copy available text")
        let empty = ErrorRecoveryContext(failedStage: "ASR", error: LLMError.invalidResponse, rawText: "", retryable: false)
        r.eq(SessionController.buildErrorActions(from: empty).map(\.displayName), [], "recovery: nonactionable error exposes no action buttons")
        let cancellation = ErrorRecoveryContext(failedStage: "ASR", error: CancellationError(), rawText: "stale", retryable: true)
        r.eq(SessionController.buildErrorActions(from: cancellation).map(\.displayName), [], "recovery: cancellation exposes no stale retry or copy")
    }

    private final class CompletingLLMProtocol: URLProtocol, @unchecked Sendable {
        private static let content = "data: {\"choices\":[{\"delta\":{\"content\":\"整理完整结果。\"}}]}\n\n"
        private static let malformed = "data: {broken json}\n\n"
        private static let done = "data: [DONE]\n\n"
        private static let stop = "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        private static let length = "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\n"
        private static let fixtures: [String: String] = [
            "partialEOF": content,
            "malformedEOF": content + malformed,
            "malformedDone": content + malformed + done,
            "lengthDone": content + length + done,
            "validDone": content + done,
            "validStopEOF": content + stop
        ]
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "llm-completion.invalid" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let fixture = request.url!.pathComponents[1]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(Self.fixtures[fixture]!.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    @MainActor
    static func testPolishStreamCompleteness(_ r: Reporter) async {
        let service = LLMService(makeSession: {
            let networkConfig = URLSessionConfiguration.ephemeral
            networkConfig.protocolClasses = [CompletingLLMProtocol.self]
            return URLSession(configuration: networkConfig)
        })
        for (fixture, degraded) in [("partialEOF", true), ("malformedEOF", true), ("malformedDone", true),
                                     ("lengthDone", true), ("validDone", false), ("validStopEOF", false)] {
            var configured = Configuration()
            configured.llmProviders = [LLMProvider(name: "Completion test", provider: "custom",
                baseURL: "https://llm-completion.invalid/\(fixture)/v1", model: "test", isActive: true)]
            configured.providerAPIKeys[configured.llmProviders[0].id.uuidString] = "test-key"
            let config = configured
            let stage = PolishStage(configuration: { config }, streamFactory: { text, config in
                await service.polishText(text, config: config)
            })
            let context = SessionContext(sessionID: 330)
            context.usePolish = true
            let result = await stage.execute(payload: .processed("完整处理结果。", raw: "完整处理结果"), context: context)
            if case .continue(.polished(let text, _)) = result {
                r.eq(text, degraded ? "完整处理结果。" : "整理完整结果。", "SSE completeness: \(fixture) delivers only complete final text")
            } else { r.check(false, "SSE completeness: \(fixture) continues with final text") }
            r.eq(context.polishFailed, degraded, "SSE completeness: \(fixture) records degradation accurately")
            r.eq(context.completionNotice, degraded ? "整理失败 · 已保留识别结果" : nil,
                 "SSE completeness: \(fixture) records destination-neutral completion notice")
        }
    }

    private final class HangingLLMProtocol: URLProtocol, @unchecked Sendable {
        static let events = DeliveryLog()
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "llm-test.invalid" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.events.append("started")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"partial draft\"}}]}\n\n".utf8))
            // No EOF: only cancellation may stop this transport.
        }
        override func stopLoading() { Self.events.append("stopped") }
    }

    @MainActor
    static func testPolishStreamTermination(_ r: Reporter) async {
        var configured = Configuration()
        configured.llmProviders = [LLMProvider(name: "Test", provider: "custom", baseURL: "https://llm-test.invalid/v1", model: "test", isActive: true)]
        configured.providerAPIKeys[configured.llmProviders[0].id.uuidString] = "test-key"
        let config = configured
        let service = LLMService(makeSession: {
            let networkConfig = URLSessionConfiguration.ephemeral
            networkConfig.protocolClasses = [HangingLLMProtocol.self]
            return URLSession(configuration: networkConfig)
        })
        let timeout = PolishStage(configuration: { config }, deadlineSeconds: 0.1, streamFactory: { text, config in
            await service.polishText(text, config: config)
        })
        let context = SessionContext(sessionID: 320)
        context.usePolish = true
        let start = Date()
        let result = await timeout.execute(payload: .processed("完整处理结果。", raw: "完整处理结果"), context: context)
        if case .continue(.polished(let final, _)) = result {
            r.eq(final, "完整处理结果。", "polish: stalled real transport never delivers partial tokens")
        } else { r.check(false, "polish: stalled real transport falls back") }
        r.check(Date().timeIntervalSince(start) < 0.5, "polish: never-completing stream obeys whole deadline")
        for _ in 0..<50 {
            if HangingLLMProtocol.events.value.contains("stopped") { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        r.check(HangingLLMProtocol.events.value.contains("started"), "polish: transport producer actually started")
        r.check(HangingLLMProtocol.events.value.contains("stopped"), "polish: deadline terminates stream producer and cancels network transport")
        r.check(context.completionNotice != nil && context.polishFailed, "polish: deadline records notice for final-delivery completion")

        let cancelledTransport = DeliveryLog()
        let producer = StageRendezvous()
        let cancellationStage = PolishStage(configuration: { config }, streamFactory: { _, _ in
            LLMService.producerOwnedStream(cancelTransport: { cancelledTransport.append("cancelled") }) { continuation in
                await producer.invoke(suspend: true)
                continuation.finish()
            }
        })
        let cancelContext = SessionContext(sessionID: 321)
        cancelContext.usePolish = true
        let task = Task { await cancellationStage.execute(payload: .processed("完整处理结果。", raw: "完整处理结果"), context: cancelContext) }
        await producer.waitForInvocation()
        cancelContext.cancel()
        task.cancel()
        let cancelled = await task.value
        if case .suspend(let recovery) = cancelled { r.check(recovery.error is CancellationError, "polish: cancellation suspends without delivery") }
        else { r.check(false, "polish: cancellation suspends without delivery") }
        for _ in 0..<50 {
            if !cancelledTransport.value.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        r.check(!cancelledTransport.value.isEmpty, "polish: consumer cancellation cleans producer-owned resources")
        await producer.release()
    }

    @MainActor
    static func testAsyncDeadline(_ r: Reporter) async {
        let started = Date()
        do {
            _ = try await withAsyncDeadline(seconds: 0.02) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { continuation.resume(returning: "late") }
                }
            }
            r.check(false, "deadline: timeout wins against uncooperative operation")
        } catch {
            r.check(error is AsyncDeadlineError, "deadline: timeout wins against uncooperative operation")
        }
        r.check(Date().timeIntervalSince(started) < 0.15, "deadline: does not join an uncooperative loser")
        let task = Task {
            try await withAsyncDeadline(seconds: 5) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { continuation.resume(returning: "late") }
                }
            }
        }
        await Task.yield()
        let cancelledAt = Date()
        task.cancel()
        do { _ = try await task.value; r.check(false, "deadline: caller cancellation resumes promptly") }
        catch { r.check(error is CancellationError, "deadline: caller cancellation resumes promptly") }
        r.check(Date().timeIntervalSince(cancelledAt) < 0.15, "deadline: cancellation does not join operation")
        do { r.eq(try await withAsyncDeadline(seconds: 1) { "complete" }, "complete", "deadline: successful operation completes once") }
        catch { r.check(false, "deadline: successful operation completes once") }
    }

    // MARK: - Optional polish must deliver only complete text

    @MainActor
    static func testPolishDelivery(_ r: Reporter) async {
        var configured = Configuration()
        configured.llmProviders = [LLMProvider(name: "Test", provider: "custom", baseURL: "https://example.com/v1", model: "test", isActive: true)]
        configured.providerAPIKeys[configured.llmProviders[0].id.uuidString] = "test-key"
        let config = configured
        func finalText(_ result: StageResult) -> String? {
            if case .continue(.polished(let text, _)) = result { return text }
            return nil
        }
        for chunks in [[], ["你好，世界。"], ["整理", "完成。"]] as [[String]] {
            let stage = PolishStage(configuration: { config }, streamFactory: { _, _ in
                AsyncThrowingStream { continuation in
                    for chunk in chunks { continuation.yield(chunk) }
                    continuation.finish()
                }
            })
            let context = SessionContext(sessionID: 301)
            context.usePolish = true
            let result = await stage.execute(payload: .processed("你好，世界。", raw: "你好世界"), context: context)
            r.eq(finalText(result), chunks == ["整理", "完成。"] ? "整理完成。" : "你好，世界。", "polish: empty/same/success keeps complete text")
        }
        let failing = PolishStage(configuration: { config }, streamFactory: { _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield("不完整草稿")
                continuation.finish(throwing: LLMError.apiError("offline"))
            }
        })
        let failureContext = SessionContext(sessionID: 302)
        failureContext.usePolish = true
        let failed = await failing.execute(payload: .processed("你好，世界。", raw: "你好世界"), context: failureContext)
        r.eq(finalText(failed), "你好，世界。", "polish: stream error discards partial draft and delivers processed text")
        let noConfig = PolishStage(configuration: { Configuration() }, streamFactory: { _, _ in
            AsyncThrowingStream { $0.finish(throwing: LLMError.apiError("must not request")) }
        })
        let noConfigContext = SessionContext(sessionID: 303)
        noConfigContext.usePolish = true
        r.eq(finalText(await noConfig.execute(payload: .processed("本地结果。", raw: "本地结果"), context: noConfigContext)), "本地结果。", "polish: missing LLM config passes through")
        let cancelled = SessionContext(sessionID: 304)
        cancelled.usePolish = true
        cancelled.cancel()
        let cancelledResult = await failing.execute(payload: .processed("你好，世界。", raw: "你好世界"), context: cancelled)
        if case .suspend(let recovery) = cancelledResult {
            r.check(recovery.error is CancellationError, "polish: cancelled context suspends without draft or fallback")
        } else { r.check(false, "polish: cancelled context suspends without draft or fallback") }

        let delivery = DeliveryLog()
        for clipboard in [false, true] {
            let context = SessionContext(sessionID: 305)
            let stage = InjectionStage(settle: {
                await context.cancel()
            }, focus: { FocusSignals(secureInputActive: clipboard, focus: .blindOrUnknown) },
            inject: { text, _ in delivery.append(text) }, copy: { text in delivery.append(text) })
            _ = await stage.execute(payload: .polished("完整文本。", raw: "完整文本"), context: context)
        }
        r.eq(delivery.value, [], "injection: cancellation during focus settle prevents keyboard and clipboard effects")
        let deliveredOnce = DeliveryLog()
        let once = SessionContext(sessionID: 306)
        let stage = InjectionStage(settle: {}, focus: { FocusSignals(secureInputActive: true, focus: .blindOrUnknown) },
                                   inject: { text, _ in deliveredOnce.append(text) }, copy: { text in deliveredOnce.append(text) })
        _ = await stage.execute(payload: .polished("只送一次。", raw: "只送一次"), context: once)
        _ = await stage.execute(payload: .polished("只送一次。", raw: "只送一次"), context: once)
        r.eq(deliveredOnce.value, ["只送一次。"], "injection: one terminal delivery across duplicate stage executions")
        let concurrentContext = SessionContext(sessionID: 311)
        let concurrentDeliveries = DeliveryLog()
        let concurrentStage = InjectionStage(settle: { await Task.yield() },
            focus: { FocusSignals(secureInputActive: true, focus: .blindOrUnknown) },
            copy: { text in concurrentDeliveries.append(text) })
        async let first = concurrentStage.execute(payload: .polished("并发只送一次。", raw: "并发只送一次"), context: concurrentContext)
        async let second = concurrentStage.execute(payload: .polished("并发只送一次。", raw: "并发只送一次"), context: concurrentContext)
        _ = await (first, second)
        r.eq(concurrentDeliveries.value, ["并发只送一次。"], "injection: concurrent executions share one terminal delivery reservation")
        once.finalText = "只送一次。"
        r.check(once.claimHistorySave(), "history: delivered session claims terminal history save")
        r.check(!once.claimHistorySave(), "history: notice then idle cannot save delivered history twice")
        let unsent = SessionContext(sessionID: 307)
        unsent.finalText = "取消文本。"
        r.check(!unsent.claimHistorySave(), "history: undelivered text never creates terminal history")
        unsent.hasInjected = true
        unsent.cancel()
        r.check(!unsent.claimHistorySave(), "history: cancelled context cannot claim history")

        let events = DeliveryLog()
        let cancelledBeforePost = SessionContext(sessionID: 308)
        cancelledBeforePost.cancel()
        do {
            try KeyboardInjector.postIfActive(context: cancelledBeforePost) { events.append("posted") }
            r.check(false, "keyboard: actual CGEvent posting gate rejects cancelled context")
        } catch { r.check(error is CancellationError, "keyboard: actual CGEvent posting gate rejects cancelled context") }
        r.eq(events.value, [], "keyboard: rejected post never executes its event side effect")
        let postContext = SessionContext(sessionID: 309)
        let posting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { try KeyboardInjector.postIfActive(context: postContext) { events.append("posted") }; return false }
            catch { return error is CancellationError }
        }
        r.check(await posting.value, "keyboard: actual posting gate rejects cancelled task even with active context")
        r.eq(events.value, [], "keyboard: task cancellation posts no event")

        let afterInject = SessionContext(sessionID: 310)
        let cancelledDuringInject = InjectionStage(settle: {}, focus: { FocusSignals(secureInputActive: false, focus: .blindOrUnknown) },
            inject: { _, context in await context.cancel(); throw LLMError.invalidResponse },
            copy: { text in events.append(text) })
        _ = await cancelledDuringInject.execute(payload: .polished("禁止回退。", raw: "禁止回退"), context: afterInject)
        r.eq(events.value, [], "injection: cancellation during keyboard await prevents clipboard fallback")
        r.eq(polishFallbackText(processed: "", raw: "最后兜底"), "最后兜底", "polish: empty processed text falls back to complete raw text")
    }

    // MARK: - Stop gestures and final-only presentation

    private final class TapTimeline: @unchecked Sendable {
        var events: [String] = []
    }

    @MainActor
    static func testStopGestureTimeline(_ r: Reporter) {
        let detector = OptionTapDetector.shared
        let timeline = TapTimeline()
        detector.onSingleTap = { timeline.events.append("single") }
        detector.onDoubleTap = { timeline.events.append("double") }
        // Drain a timer left by a previous sequence, then start each sequence clean.
        func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }
        func reset() { drain(); timeline.events = [] }
        reset()
        let now = Date()

        detector.recordTap(at: now, state: .recording(elapsedSeconds: 3), mode: .tapToStart)
        r.eq(timeline.events, ["single"], "gesture: first recording release stops before double-tap window")
        reset()
        detector.recordTap(at: now, state: .preparing, mode: .tapToStart)
        r.eq(timeline.events, ["single"], "gesture: first preparing release cancels immediately")
        reset()

        detector.recordTap(at: now, state: .idle, mode: .tapToStart)
        r.eq(timeline.events, [], "gesture: idle first tap does not start")
        detector.recordTap(at: now.addingTimeInterval(0.1), state: .idle, mode: .tapToStart)
        r.eq(timeline.events, ["double"], "gesture: idle double-tap start remains compatible")
        reset()
        detector.recordTap(at: now, state: .idle, mode: .toggle)
        r.eq(timeline.events, ["single"], "gesture: idle toggle starts on first release")
        reset()

        detector.recordTap(at: now, state: .idle, mode: .tapToStart)
        detector.recordTap(at: now.addingTimeInterval(0.1), state: .recording(elapsedSeconds: 0), mode: .tapToStart)
        r.eq(timeline.events, ["single"], "gesture: active release clears idle tap instead of becoming double-tap")
        drain()
        r.eq(timeline.events, ["single"], "gesture: active stop leaves no delayed tap callback")
        detector.recordTap(at: now.addingTimeInterval(0.2), state: .processing(provider: "cloud"), mode: .tapToStart)
        drain()
        r.eq(timeline.events, ["single"], "gesture: repeated release while processing does not stop or restart")
        reset()

        detector.recordTap(at: now, state: .idle, mode: .tapToStart)
        detector.cancelPendingTaps() // Escape path must discard a pending idle tap.
        drain()
        r.eq(timeline.events, [], "gesture: Escape cancellation clears pending tap timer")
        detector.onSingleTap = nil
        detector.onDoubleTap = nil
    }

    static func testNonModifierRepeat(_ r: Reporter) {
        let pressed = Date(timeIntervalSince1970: 100)
        let repeated = Date(timeIntervalSince1970: 100.5)
        r.eq(WindowManager.nonModifierPressTime(current: pressed, now: repeated, isRepeat: true), pressed,
             "gesture: key repeat cannot restart original hold timestamp")
        r.eq(WindowManager.nonModifierPressTime(current: nil, now: repeated, isRepeat: true), nil,
             "gesture: repeat without initial press cannot manufacture hold")
        r.eq(WindowManager.nonModifierPressTime(current: nil, now: pressed, isRepeat: false), pressed,
             "gesture: first genuine key-down begins hold")
    }

    @MainActor
    static func testAudioFeedbackTimeline(_ r: Reporter) {
        var sounds: [AudioFeedbackObserver.Feedback] = []
        var enabled = true
        let observer = AudioFeedbackObserver(enabled: { enabled }, play: { sounds.append($0) })
        let context = SessionContext(sessionID: 200)
        observer.sessionDidTransition(from: .idle, to: .preparing, context: context)
        observer.sessionDidTransition(from: .preparing, to: .recording(elapsedSeconds: 0), context: context)
        r.eq(sounds, [], "sound: no start cue before valid PCM readiness")
        context.markReady()
        observer.sessionDidTransition(from: .preparing, to: .recording(elapsedSeconds: 0), context: context)
        observer.sessionDidTransition(from: .recording(elapsedSeconds: 0), to: .recording(elapsedSeconds: 1), context: context)
        r.eq(sounds, [.start], "sound: ready session plays one start cue across repeated updates")
        observer.sessionDidTransition(from: .recording(elapsedSeconds: 1), to: .processing(provider: "cloud"), context: context)
        observer.sessionDidTransition(from: .recording(elapsedSeconds: 1), to: .processing(provider: "local"), context: context)
        r.eq(sounds, [.start, .stop], "sound: repeated stop plays exactly one stop cue")
        context.cancel()
        observer.sessionDidTransition(from: .preparing, to: .recording(elapsedSeconds: 0), context: context)
        observer.sessionDidTransition(from: .preparing, to: .error("cancelled"), context: context)
        r.eq(sounds, [.start, .stop], "sound: cancelled context cannot play late cues")
        enabled = false
        let disabled = SessionContext(sessionID: 201)
        disabled.markReady()
        observer.sessionDidTransition(from: .preparing, to: .recording(elapsedSeconds: 0), context: disabled)
        r.eq(sounds, [.start, .stop], "sound: audio-feedback preference disables cues")
        enabled = true
        let preparingError = SessionContext(sessionID: 202)
        observer.sessionDidTransition(from: .preparing, to: .error("no microphone"), context: preparingError)
        r.eq(sounds, [.start, .stop, .error], "sound: preparation failure gives error cue without start cue")
    }

    static func testPolishOnStopConfig(_ r: Reporter) {
        func encodedFlag(_ config: Configuration) -> Bool? {
            let data = try! JSONEncoder().encode(config)
            let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            return json["polishOnStop"] as? Bool
        }
        r.eq(encodedFlag(Configuration()), true, "config: new sessions enable automatic polish by default")
        let legacy = try! JSONDecoder().decode(Configuration.self, from: Data(#"{}"#.utf8))
        r.eq(encodedFlag(legacy), true, "config: legacy config enables automatic polish")
        let optedOut = try! JSONDecoder().decode(Configuration.self, from: Data(#"{"polishOnStop":false}"#.utf8))
        r.eq(encodedFlag(optedOut), false, "config: automatic-polish opt-out survives decode/encode")
    }

    static func testStableSessionPresentation(_ r: Reporter) {
        r.eq(SessionState.processing(provider: "private-provider").statusTitle, "处理中...",
             "presentation: ASR provider identity does not leak into processing title")
        r.eq(SessionState.polishing(preview: "unfinished draft").statusTitle,
             SessionState.processing(provider: "cloud").statusTitle,
             "presentation: ASR and polish share one stable processing title")
        r.check(SessionState.preparing.showSpinner, "presentation: preparing visibly indicates work before audio readiness")
    }

    // MARK: - Session experience: readiness and ownership contract

    /// Deterministic rendezvous for a stage that completes only when the test
    /// releases it. No timing sleeps, microphone, provider, or controller setup.
    private actor StageRendezvous {
        private(set) var invocationCount = 0
        private var entered: CheckedContinuation<Void, Never>?
        private var finish: CheckedContinuation<Void, Never>?

        func invoke(suspend: Bool) async {
            invocationCount += 1
            entered?.resume()
            entered = nil
            if suspend {
                await withCheckedContinuation { finish = $0 }
            }
        }

        func waitForInvocation() async {
            if invocationCount > 0 { return }
            await withCheckedContinuation { entered = $0 }
        }

        func release() {
            finish?.resume()
            finish = nil
        }
    }

    private struct SuspensibleStage: PipelineStage {
        let name = "Self-test stage"
        let rendezvous: StageRendezvous
        var suspend = false

        func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
            await rendezvous.invoke(suspend: suspend)
            return .continue(.transcript("complete transcript"))
        }
    }

    @MainActor
    static func testStageOwnership(_ r: Reporter) async {
        let cancelledContext = SessionContext(sessionID: 101)
        cancelledContext.cancel()
        let skipped = StageRendezvous()
        let skippedResult = await SuspensibleStage(rendezvous: skipped)
            .executeIfOwned(payload: .empty, context: cancelledContext)
        r.eq(await skipped.invocationCount, 0,
             "stage ownership: cancelled before execution never invokes underlying stage")
        if case .complete = skippedResult {
            r.check(true, "stage ownership: cancelled before execution completes quietly")
        } else {
            r.check(false, "stage ownership: cancelled before execution propagated a result")
        }

        let suspendedContext = SessionContext(sessionID: 102)
        let suspended = StageRendezvous()
        let suspendedStage = SuspensibleStage(rendezvous: suspended, suspend: true)
        let task = Task {
            let result = await suspendedStage.executeIfOwned(payload: .empty, context: suspendedContext)
            if case .complete = result { return true }
            return false
        }
        await suspended.waitForInvocation()
        suspendedContext.cancel()
        await suspended.release()
        r.check(await task.value,
                "stage ownership: cancellation during suspended execution suppresses continue")
        r.eq(await suspended.invocationCount, 1,
             "stage ownership: suspended underlying stage ran exactly once")

        let activeContext = SessionContext(sessionID: 103)
        let active = StageRendezvous()
        let activeResult = await SuspensibleStage(rendezvous: active)
            .executeIfOwned(payload: .empty, context: activeContext)
        if case .continue(.transcript(let text)) = activeResult {
            r.eq(text, "complete transcript", "stage ownership: active execution preserves payload")
        } else {
            r.check(false, "stage ownership: active execution did not propagate continue")
        }
        r.eq(await active.invocationCount, 1,
             "stage ownership: active execution invokes underlying stage once")
    }

    static func testSessionExperience(_ r: Reporter) {
        r.eq(SessionController.stateForAudioReadiness(isReady: false), .preparing,
              "session: before first valid PCM buffer → preparing")
        r.eq(SessionController.stateForAudioReadiness(isReady: true), .recording(elapsedSeconds: 0),
              "session: first valid PCM buffer → recording")
        r.check(SessionController.shouldAcceptEvent(activeSessionID: 7, eventSessionID: 7, isCancelled: false),
                "session: active session accepts its own event")
        r.check(!SessionController.shouldAcceptEvent(activeSessionID: 7, eventSessionID: 6, isCancelled: false),
                "session: stale session event is rejected")
        r.check(!SessionController.shouldAcceptEvent(activeSessionID: 7, eventSessionID: 7, isCancelled: true),
                "session: cancelled session event is rejected")
        r.check(!SessionController.shouldAcceptEvent(activeSessionID: 0, eventSessionID: 7, isCancelled: false),
                "session: stop invalidates ownership before late result")
        r.check(!SessionController.shouldAcceptTimerTick(activeSessionID: 7, tickSessionID: 6,
                                                         isCancelled: false, isRecording: true),
                "session: queued timer tick from old session is rejected")
        r.check(!SessionController.shouldAcceptTimerTick(activeSessionID: 7, tickSessionID: 7,
                                                         isCancelled: true, isRecording: true),
                "session: queued timer tick after cancellation is rejected")
        r.check(AudioRecorder.shouldAcceptOwner(activeOwnerID: 7, eventOwnerID: 7),
                "audio: current recorder owner is accepted")
        r.check(!AudioRecorder.shouldAcceptOwner(activeOwnerID: 8, eventOwnerID: 7),
                "audio: stale recorder owner is rejected")
        r.check(AudioRecorder.isValidPCM(frameCount: 1, hasFloatChannel: true),
                "audio: even first one-frame PCM buffer establishes readiness")
        r.check(!AudioRecorder.isValidPCM(frameCount: 0, hasFloatChannel: true),
                "audio: empty callback cannot establish readiness")
        r.check(!AudioRecorder.isValidPCM(frameCount: 1, hasFloatChannel: false),
                "audio: unusable PCM callback cannot establish readiness")

        let contextChecks: (initial: Bool, emittedOnce: Bool, cancelled: Bool, sideEffects: Int) = MainActor.assumeIsolated {
            let context = SessionContext(sessionID: 8)
            var readinessEvents = 0
            let subscription = context.readinessPublisher.sink { _ in readinessEvents += 1 }
            let initial = !context.isReady && !context.isCancelled
            context.markReady()
            context.markReady()
            let emittedOnce = context.isReady && readinessEvents == 1
            var sideEffects = 0
            context.performIfActive { sideEffects += 1 }
            context.cancel()
            context.performIfActive { sideEffects += 1 }
            context.markReady()
            let cancelled = context.isCancelled && readinessEvents == 1
            subscription.cancel()
            return (initial, emittedOnce, cancelled, sideEffects)
        }
        r.check(contextChecks.initial,
                "session: fresh context is neither ready nor cancelled")
        r.check(contextChecks.emittedOnce,
                "session: readiness emits once after first valid buffer")
        r.check(contextChecks.cancelled,
                "session: cancellation blocks late readiness events")
        r.eq(contextChecks.sideEffects, 1,
             "session: cancelled audio callback cannot forward another buffer")
    }

    // MARK: - B1: validatedAPIURL must preserve the base path (e.g. /v1)

    static func testLLMURL(_ r: Reporter) {
        func s(_ baseURL: String) -> String? { validatedAPIURL(baseURL: baseURL)?.absoluteString }

        r.eq(s("https://api.siliconflow.cn/v1"), "https://api.siliconflow.cn/v1/chat/completions",
             "B1 SiliconFlow /v1 preserved")
        r.eq(s("https://api.siliconflow.cn/v1/"), "https://api.siliconflow.cn/v1/chat/completions",
             "B1 trailing slash does not double up")
        r.eq(s("https://api.openai.com/v1"), "https://api.openai.com/v1/chat/completions",
             "B1 OpenAI /v1 preserved")
        r.eq(s("https://api.siliconflow.cn"), "https://api.siliconflow.cn/chat/completions",
             "B1 no base path still works")
        r.eq(s("  https://api.siliconflow.cn/v1  "), "https://api.siliconflow.cn/v1/chat/completions",
             "B1 surrounding whitespace trimmed")

        // Security guards that MUST keep rejecting:
        r.check(validatedAPIURL(baseURL: "https://api.siliconflow.cn/v1/../../etc") == nil,
                "B1 path traversal rejected")
        r.check(validatedAPIURL(baseURL: "https://user:pass@api.siliconflow.cn/v1") == nil,
                "B1 embedded credentials rejected")
        r.check(validatedAPIURL(baseURL: "http://api.siliconflow.cn/v1") == nil,
                "B1 non-https rejected")
    }

    // MARK: - B8: SSE parser surfaces error frames & counts decode failures

    static func testSSEParse(_ r: Reporter) {
        var df = 0
        if case .content(let c) = parseSSELine(#"data: {"choices":[{"delta":{"content":"hi"}}]}"#, decodeFailures: &df) {
            r.eq(c, "hi", "B8 content extracted")
        } else {
            r.check(false, "B8 content frame should parse as .content")
        }

        r.check(parseSSELine("data: [DONE]", decodeFailures: &df) == .done, "B8 [DONE] recognized")

        if case .error(let m) = parseSSELine(#"data: {"error":{"message":"rate limit exceeded","code":"429"}}"#, decodeFailures: &df) {
            r.check(m.contains("rate limit"), "B8 in-band error frame surfaced")
        } else {
            r.check(false, "B8 error frame should parse as .error")
        }

        r.check(parseSSELine(": ping", decodeFailures: &df) == .ignore, "B8 non-data line ignored")
        r.eq(df, 0, "B8 well-formed frames cause no decode failures")

        var df2 = 0
        _ = parseSSELine("data: {not valid json}", decodeFailures: &df2)
        r.eq(df2, 1, "B8 malformed JSON counted as decode failure")
    }

    // MARK: - CancellableContinuationBox: exactly-once resume across racing callbacks

    static func testContinuationBox(_ r: Reporter) {
        final class Slot: @unchecked Sendable { var value: String? }

        // Exactly-once: late second resume and late cancel are no-ops, not crashes.
        let box1 = CancellableContinuationBox<String>()
        let slot1 = Slot()
        let installed1 = DispatchSemaphore(value: 0)
        let done1 = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                slot1.value = try await withCheckedThrowingContinuation { c in
                    box1.setContinuation(c)
                    installed1.signal()
                }
            } catch {
                slot1.value = "error"
            }
            done1.signal()
        }
        guard installed1.wait(timeout: .now() + 5) == .success else {
            r.check(false, "box: continuation install timed out"); return
        }
        box1.resume(returning: "first")
        box1.resume(returning: "second")
        box1.resume(throwing: CancellationError())
        box1.cancel()
        guard done1.wait(timeout: .now() + 5) == .success else {
            r.check(false, "box: resume wait timed out"); return
        }
        r.eq(slot1.value, "first", "box: resumes exactly once with the first value")

        // Cancel before the continuation is installed → immediate CancellationError.
        let box2 = CancellableContinuationBox<String>()
        box2.cancel()
        r.check(box2.isCancelled, "box: isCancelled reflects cancel (inference-skip gate)")
        let slot2 = Slot()
        let done2 = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                _ = try await withCheckedThrowingContinuation { box2.setContinuation($0) }
                slot2.value = "returned"
            } catch is CancellationError {
                slot2.value = "cancelled"
            } catch {
                slot2.value = "other"
            }
            done2.signal()
        }
        guard done2.wait(timeout: .now() + 5) == .success else {
            r.check(false, "box: cancel-before-set wait timed out"); return
        }
        r.eq(slot2.value, "cancelled", "box: cancel-before-set resumes with CancellationError")
        r.check(!CancellableContinuationBox<String>().isCancelled, "box: fresh box is not cancelled")
    }

    // MARK: - Modifier-trigger tap machine: shortcut chords must not count as taps

    static func testModifierTapMachine(_ r: Reporter) {
        var a = WindowManager.modifierTapAction(isDownNow: true, wasDown: false, sawOtherKey: true)
        r.check(!a.recordTap && a.resetSawOtherKey, "tap-machine: press edge records nothing and starts a clean hold")
        a = WindowManager.modifierTapAction(isDownNow: false, wasDown: true, sawOtherKey: false)
        r.check(a.recordTap && !a.resetSawOtherKey, "tap-machine: clean release records a tap")
        a = WindowManager.modifierTapAction(isDownNow: false, wasDown: true, sawOtherKey: true)
        r.check(!a.recordTap, "tap-machine: chord-poisoned release (Cmd+C) records nothing")
        a = WindowManager.modifierTapAction(isDownNow: true, wasDown: true, sawOtherKey: false)
        r.check(!a.recordTap && !a.resetSawOtherKey, "tap-machine: held-state repeat (Cmd+Shift press) is a no-op")
        a = WindowManager.modifierTapAction(isDownNow: false, wasDown: false, sawOtherKey: false)
        r.check(!a.recordTap, "tap-machine: idle flagsChanged is a no-op")

        // Detector window behaviour (synchronous double-tap callback, injected timestamps).
        final class Box: @unchecked Sendable { var doubles = 0 }
        let box = Box()
        let det = OptionTapDetector.shared
        det.onDoubleTap = { box.doubles += 1 }
        det.onSingleTap = { }
        let t0 = Date()
        det.recordTap(at: t0)
        det.recordTap(at: t0.addingTimeInterval(0.1))
        r.eq(box.doubles, 1, "tap-machine: two taps within window → double-tap")
        det.recordTap(at: t0.addingTimeInterval(1.0))
        det.recordTap(at: t0.addingTimeInterval(2.0))
        r.eq(box.doubles, 1, "tap-machine: taps outside window do not double")
        det.onDoubleTap = nil
        det.onSingleTap = nil
    }

    // MARK: - LLM failover guards: no provider retry after content delivery + inactivity watchdog

    static func testLLMFailoverGuards(_ r: Reporter) {
        r.check(LLMService.shouldFailover(hasYielded: false, attemptIndex: 0, maxAttempts: 2),
                "failover: clean failure → try next provider")
        r.check(!LLMService.shouldFailover(hasYielded: true, attemptIndex: 0, maxAttempts: 2),
                "failover: content delivered → never fail over (would duplicate text)")
        r.check(!LLMService.shouldFailover(hasYielded: false, attemptIndex: 1, maxAttempts: 2),
                "failover: last attempt → no fallback")

        let d = LLMService.DeliveryState()
        r.check(!d.hasYielded, "watchdog: starts un-yielded")
        d.touch()
        r.check(d.idleSeconds(now: Date()) < 1, "watchdog: just-touched clock reads ~0 idle")
        r.check(d.idleSeconds(now: Date().addingTimeInterval(31)) > 30, "watchdog: 31s without frames exceeds a 30s limit")
        d.markYielded()
        r.check(d.hasYielded, "watchdog: markYielded sets delivered flag")
        r.check(d.idleSeconds(now: Date()) < 1, "watchdog: markYielded also counts as activity")
    }

    // MARK: - B9: corrupt persisted config is backed up, not silently discarded

    static func testConfigCorrupt(_ r: Reporter) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowtype-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Corrupt blob -> reset to default AND a backup file is written.
        let suite = "FlowTypeSelfTest.\(UUID().uuidString)"
        guard let ud = UserDefaults(suiteName: suite) else {
            r.check(false, "B9 could not create test UserDefaults suite"); return
        }
        defer { ud.removePersistentDomain(forName: suite) }
        ud.set(Data("this is not valid config json".utf8), forKey: "flowtype.config")

        let store = ConfigurationStore(defaults: ud, backupDirectory: tmp)
        r.eq(store.current.maxRecordingDuration, Configuration.default.maxRecordingDuration,
             "B9 corrupt config resets to default")
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        r.check(backups.contains { $0.hasPrefix("flowtype.config.corrupt-") },
                "B9 corrupt blob backed up to disk")

        // First launch (no data) -> default, and NO spurious backup.
        let suite2 = "FlowTypeSelfTest.\(UUID().uuidString)"
        let tmp2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowtype-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp2, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp2) }
        guard let ud2 = UserDefaults(suiteName: suite2) else {
            r.check(false, "B9 could not create second test suite"); return
        }
        defer { ud2.removePersistentDomain(forName: suite2) }
        _ = ConfigurationStore(defaults: ud2, backupDirectory: tmp2)
        let backups2 = (try? FileManager.default.contentsOfDirectory(atPath: tmp2.path)) ?? []
        r.check(backups2.isEmpty, "B9 first launch writes no spurious backup")
    }

    // MARK: - ASR language + context wiring

    static func testASRWiring(_ r: Reporter) {
        r.check(WhisperLanguage.auto.qwenLanguageCode == nil, "ASR: auto → nil language hint")
        r.check(WhisperLanguage.zh.qwenLanguageCode == "zh", "ASR: zh → zh")
        r.check(WhisperLanguage.en.qwenLanguageCode == "en", "ASR: en → en")
        r.eq(WhisperLanguage.en.appleLocaleIdentifier, "en-US", "ASR: en → en-US locale")
        r.eq(WhisperLanguage.zh.appleLocaleIdentifier, "zh-CN", "ASR: zh → zh-CN locale")
        r.eq(WhisperLanguage.auto.appleLocaleIdentifier, "zh-CN", "ASR: auto → zh-CN locale")
        r.check(composeASRContext([]) == nil, "ASR: empty phrases → nil context")
        r.check(composeASRContext(["  ", ""]) == nil, "ASR: blank phrases → nil context")
        r.check(composeASRContext(["React", "SwiftUI"]) == "React、SwiftUI", "ASR: phrases joined")
        let many = (0..<100).map { "w\($0)" }
        r.check((composeASRContext(many) ?? "").count <= 300, "ASR: context capped to maxChars")
    }

    // MARK: - SpectrumMath pure DSP helpers

    static func testSpectrumMath(_ r: Reporter) {
        let env = SpectrumMath.centerEnvelope(count: 9)
        r.eq(env.count, 9, "spectrum: envelope length")
        r.check(env.first! < 0.01, "spectrum: envelope edge ~0")
        r.check(env[4] > 0.99, "spectrum: envelope center ~1")
        r.check(abs(env[1] - env[7]) < 1e-5, "spectrum: envelope symmetric")

        var mags = [Float](repeating: 0, count: 512)   // fftSize 1024 -> 512 magnitudes
        mags[64] = 10                                  // bin 64 = 64*(16000/1024) = 1000 Hz
        let bands = SpectrumMath.logBin(mags, sampleRate: 16000, fftSize: 1024,
                                        bandCount: 28, minHz: 80, maxHz: 6000)
        r.eq(bands.count, 28, "spectrum: band count")
        let maxIdx = bands.indices.max(by: { bands[$0] < bands[$1] })!
        r.check(bands[maxIdx] > 0, "spectrum: energy lands in a band")
        r.check(maxIdx > 0 && maxIdx < 27, "spectrum: 1kHz lands mid-range")

        r.eq(SpectrumMath.normalize([5, 10, 0], reference: 10), [0.5, 1.0, 0.0], "spectrum: normalize clamps 0...1")
        let up = SpectrumMath.smooth(previous: [0], target: [1], attack: 0.5, decay: 0.1)
        r.check(abs(up[0] - 0.5) < 1e-6, "spectrum: attack rate (fast rise)")
        let down = SpectrumMath.smooth(previous: [1], target: [0], attack: 0.5, decay: 0.1)
        r.check(abs(down[0] - 0.9) < 1e-6, "spectrum: decay rate (slow fall)")
    }

    // MARK: - SpectrumAnalyzer FFT correctness

    static func testFFTPeak(_ r: Reporter) {
        let analyzer = SpectrumAnalyzer()
        let fs: Float = 16000
        let freq: Float = 1000
        let n = 1024
        let samples = (0..<n).map { sin(2 * Float.pi * freq * Float($0) / fs) }
        let mags = analyzer.magnitudes(samples)
        r.eq(mags.count, 512, "spectrum: FFT half-spectrum length")
        let peak = mags.indices.max(by: { mags[$0] < mags[$1] })!
        let expected = Int(freq / (fs / Float(n)))     // 1000 / 15.625 = 64
        r.check(abs(peak - expected) <= 2, "spectrum: FFT peak at ~1kHz bin (got \(peak), want ~\(expected))")
    }

    // MARK: - SpectrumAnalyzer.process smoothed bands

    static func testSpectrumProcess(_ r: Reporter) {
        let analyzer = SpectrumAnalyzer()
        let fs: Float = 16000
        let freq: Float = 1000
        let samples = (0..<1024).map { sin(2 * Float.pi * freq * Float($0) / fs) }
        var bands = [Float]()
        for _ in 0..<10 { bands = analyzer.process(samples) }   // let smoothing settle
        r.eq(bands.count, 28, "spectrum: process band count")
        r.check(bands.allSatisfy { $0 >= 0 && $0 <= 1.0001 }, "spectrum: process bands in 0...1")
        let maxIdx = bands.indices.max(by: { bands[$0] < bands[$1] })!
        r.check(bands[maxIdx] > 0.5, "spectrum: dominant band strong after settling")

        let silence = [Float](repeating: 0, count: 1024)
        var quiet = [Float]()
        for _ in 0..<30 { quiet = analyzer.process(silence) }
        r.check((quiet.max() ?? 1) < 0.2, "spectrum: silence decays toward 0")
    }

    // MARK: - StatFormatting pure formatters

    static func testStatFormatting(_ r: Reporter) {
        r.eq(StatFormatting.duration(seconds: 8054),
             [StatSegment(number: "2", unit: "h"), StatSegment(number: "14", unit: "m")],
             "stat: 8054s → 2h14m")
        r.eq(StatFormatting.duration(seconds: 840),
             [StatSegment(number: "14", unit: "m")],
             "stat: 840s → 14m (no hours segment)")
        r.eq(StatFormatting.duration(seconds: 0),
             [StatSegment(number: "0", unit: "m")],
             "stat: 0s → 0m")
        r.eq(StatFormatting.speed(142),
             [StatSegment(number: "142", unit: " 字/分")],
             "stat: speed 142 → 142 字/分")
        r.eq(StatFormatting.plain("18,402"),
             [StatSegment(number: "18,402", unit: nil)],
             "stat: plain passthrough")

        // Milestone system (PRD §6) — pure
        r.eq(StatsEngine.flameTier(6), 3, "ms: tier(6)=3")
        r.eq(StatsEngine.flameTier(2), 0, "ms: tier(2)=0 (<3)")
        r.eq(StatsEngine.flameTier(365), 365, "ms: tier(365)=365")
        r.eq(StatsEngine.nextMilestone(6), 7, "ms: next(6)=7")
        r.check(StatsEngine.nextMilestone(365) == nil, "ms: next(365)=nil")
        r.eq(StatsEngine.milestoneProgress(6), 0.75, "ms: progress(6)=.75")
        r.eq(StatsEngine.milestoneProgress(3), 0.0, "ms: progress(3)=0 at anchor")
        r.eq(StatsEngine.milestoneProgress(400), 1.0, "ms: progress(>max)=1")
    }

    // MARK: - GRDB schema self-test

    static func testDatabaseSchema(_ r: Reporter) {
        guard let db = try? AppDatabase.inMemory() else { r.check(false, "db: inMemory open"); return }
        let tables = (try? db.dbQueue.read { d in
            try String.fetchAll(d, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }) ?? []
        r.check(tables.contains("session"), "db: session table exists")
        r.check(tables.contains("daily_legacy"), "db: daily_legacy table exists")
        r.check(tables.contains("meta"), "db: meta table exists")
    }

    // MARK: - SessionRecord round-trip

    static func testSessionRecord(_ r: Reporter) {
        guard let db = try? AppDatabase.inMemory() else { r.check(false, "rec: db"); return }
        let s = DictationSession(rawTranscript: "你好世界", finalText: "你好", polishMode: .polish,
                                 durationMs: 9000, recordingMs: 4000, appName: "Xcode",
                                 appBundleID: "com.apple.dt.Xcode", language: "zh", sttBackend: "qwen")
        var rec = SessionRecord(from: s)
        try? db.dbQueue.write { try rec.insert($0) }
        let back = (try? db.dbQueue.read { try SessionRecord.fetchAll($0) }) ?? []
        r.eq(back.count, 1, "rec: one row")
        r.eq(back.first?.charCount, 4, "rec: charCount=4 from rawTranscript 你好世界 (not polished finalText)")
        r.eq(back.first?.sttBackend, "qwen", "rec: sttBackend persisted")
        r.eq(back.first?.recordingMs, 4000, "rec: recordingMs persisted")
    }

    // MARK: - StatsRepository boundary fold

    static func testStatsRepository(_ r: Reporter) {
        guard let db = try? AppDatabase.inMemory() else { r.check(false, "repo: db"); return }
        let cal = Calendar.current
        func noon(_ iso: String) -> Double {
            let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"
            return f.date(from: "\(iso) 12:00")!.timeIntervalSince1970
        }
        func session(_ day: String, chars: Int, recMs: UInt64, durMs: UInt64 = 0) -> SessionRecord {
            var s = SessionRecord(from: DictationSession(rawTranscript: String(repeating: "字", count: chars), finalText: "",
                                  polishMode: .raw, durationMs: durMs, recordingMs: recMs,
                                  appName: "A", appBundleID: nil, language: "zh", sttBackend: "qwen"))
            s.startedAt = noon(day); return s
        }
        // migrationDate 2026-06-01; legacy snapshot has only 2026-05-20 (100 chars). Sessions:
        //   05-20 (999) → same day as the snapshot → must be IGNORED (no double-count)
        //   05-19 (50)  → a pre-migration day the snapshot is MISSING → must be COUNTED from sessions (no loss) ← real-device bug
        //   06-02 (50, recMs 20000, durMs 99999) → post-migration → counted; speed must use recordingMs
        try? db.dbQueue.write { d in
            try d.execute(sql: "INSERT OR REPLACE INTO meta VALUES('migrationDate','2026-06-01')")
            try DailyLegacyRecord(from: DailyStats(date: "2026-05-20", totalDurationMs: 0, totalWordCount: 100, sessionCount: 1, totalRecordingMs: 60000)).insert(d)
            var a = session("2026-05-20", chars: 999, recMs: 0); try a.insert(d)
            var b = session("2026-05-19", chars: 50, recMs: 0); try b.insert(d)
            var c = session("2026-06-02", chars: 50, recMs: 20000, durMs: 99999); try c.insert(d)
        }
        let stats = StatsRepository(db: db).buildDailyStats(cal: cal)
        r.eq(stats.first { $0.date == "2026-05-20" }?.totalWordCount, 100, "repo: legacy-covered day uses snapshot, session ignored (no double-count)")
        r.eq(stats.first { $0.date == "2026-05-19" }?.totalWordCount, 50, "repo: pre-migration day MISSING from snapshot counted from sessions (no loss)")
        r.eq(stats.first { $0.date == "2026-06-02" }?.totalWordCount, 50, "repo: post-migration day from sessions")
        // recordingMs denominator: 50 chars / (20000ms=0.333min) → high speed, durationMs(99999) ignored
        let summary = StatsEngine.summarize(stats, range: .all, now: noonDate("2026-06-02", cal), cal: cal)
        r.check(summary.avgSpeedCPM >= 100, "repo: speed uses recordingMs not durationMs")
    }

    static func noonDate(_ iso: String, _ cal: Calendar) -> Date {
        let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: "\(iso) 12:00")!
    }

    // MARK: - Polish-degrade → history label

    static func testHistoryMode(_ r: Reporter) {
        r.check(SessionController.historyMode(usePolish: true, polishFailed: false) == .polish, "history: polish ok → .polish")
        r.check(SessionController.historyMode(usePolish: true, polishFailed: true) == .raw, "history: polish failed → degraded .raw")
        r.check(SessionController.historyMode(usePolish: false, polishFailed: false) == .raw, "history: raw request → .raw")
    }

    // MARK: - Polish degrade: history must keep the POST-process text, not the pre-process raw

    static func testPolishDegradeTexts(_ r: Reporter) {
        let t1 = SessionController.degradedPolishTexts(payload: .processed("你好，世界。", raw: "你好世界"), recoveryRaw: "你好世界")
        r.eq(t1.final, "你好，世界。", "degrade: finalText keeps PostProcess punctuation")
        r.eq(t1.raw, "你好世界", "degrade: rawTranscript stays the true raw")

        let t2 = SessionController.degradedPolishTexts(payload: .transcript("x"), recoveryRaw: "fallback")
        r.eq(t2.final, "fallback", "degrade: non-.processed payload falls back to recovery raw")

        let t3 = SessionController.degradedPolishTexts(payload: .processed("", raw: "r"), recoveryRaw: "r")
        r.eq(t3.final, "r", "degrade: empty processed text falls back to recovery raw")

        // The degrade special case matches on the stage name — keep them in sync.
        r.check(PolishStage().name == PolishStage.stageName, "degrade: PolishStage.name matches stageName constant")
    }

    // MARK: - Dictionary auto-detect: unsegmented Chinese sentences must not enroll as "terms"

    static func testCorrectionCandidates(_ r: Reporter) {
        r.check(SessionController.correctionCandidates(raw: "你好世界", final: "你好，世界。").isEmpty,
                "corrections: punctuated Chinese sentence is not a candidate")
        r.check(SessionController.correctionCandidates(raw: "我想把这个改成深色模式", final: "我现在想把这个界面改成深色模式").isEmpty,
                "corrections: long CJK run (sentence fragment) is not a candidate")
        r.eq(SessionController.correctionCandidates(raw: "use postgres now", final: "use PostgreSQL now"), ["PostgreSQL"],
             "corrections: English term diff still detected")
        r.eq(SessionController.correctionCandidates(raw: "用 快配 部署", final: "用 Kafka 部署"), ["Kafka"],
             "corrections: short term in spaced context still detected")
        r.check(SessionController.correctionCandidates(raw: "same text", final: "same text").isEmpty,
                "corrections: identical text yields nothing")
        // Review regression: tech terms with interior ASCII punctuation must stay enrollable
        // (tech_terms.json itself maps "node js" → "Node.js").
        r.eq(SessionController.correctionCandidates(raw: "用 node js 写", final: "用 Node.js 写"), ["Node.js"],
             "corrections: dotted tech term (Node.js) is a candidate")
        r.eq(SessionController.correctionCandidates(raw: "用 tree sitter 解析", final: "用 tree-sitter 解析"), ["tree-sitter"],
             "corrections: hyphenated tech term is a candidate")
        r.eq(SessionController.correctionCandidates(raw: "学 csharp 吧", final: "学 C# 吧"), ["C#"],
             "corrections: trailing # survives edge trimming")
        r.eq(SessionController.correctionCandidates(raw: "连 wifi 不上", final: "连 Wi-Fi, 不上"), ["Wi-Fi"],
             "corrections: trailing comma trimmed off a tech term")
        r.check(SessionController.correctionCandidates(raw: "hello world", final: "hello world.").isEmpty,
                "corrections: sentence-final period does not create a candidate")
        r.check(SessionController.correctionCandidates(raw: "你好世界", final: "你好世界。").isEmpty,
                "corrections: trailing 。 alone does not enroll the sentence")
    }

    // MARK: - LLM watchdog verdict: idle limit + pre-first-token hard cap

    static func testLLMWatchdogVerdict(_ r: Reporter) {
        let f = LLMService.watchdogShouldTimeout
        r.check(f(31, 31, false, 30), "watchdog: 31s idle → timeout")
        r.check(!f(5, 80, false, 30), "watchdog: heartbeats keep it alive under the 90s pre-token cap")
        r.check(f(5, 91, false, 30), "watchdog: heartbeat-only stream hits the 3× hard cap (failover stays reachable)")
        r.check(!f(5, 600, true, 30), "watchdog: healthy long stream after first token is never cut")
        r.check(f(31, 600, true, 30), "watchdog: stall after first token still times out")
    }

    // MARK: - charCount grapheme-cluster semantics

    /// Documents that SessionRecord.charCount uses Swift grapheme-cluster count (.count), so CJK
    /// characters each count as 1 visual character, matching what readers perceive as 字数.
    /// (Contrast: the SQLite v2/v3 migration uses length() which counts code points — for plain
    /// CJK these are equal; emoji can differ, but that delta is acceptable for statistics.)
    static func testCharCountSemantics(_ r: Reporter) {
        let session = DictationSession(rawTranscript: "你好世界", finalText: "",
                                       polishMode: .raw, durationMs: 1000,
                                       recordingMs: 1000, appName: nil, appBundleID: nil,
                                       language: "zh", sttBackend: "qwen")
        let rec = SessionRecord(from: session)
        r.eq(rec.charCount, 4, "charCount: CJK grapheme == code-point parity (你好世界 = 4)")
    }

    // MARK: - Local API-key storage (no Keychain)

    static func testProviderAPIKeyLocal(_ r: Reporter) {
        var c = Configuration()
        let pid = UUID()
        c.llmProviders = [LLMProvider(id: pid, name: "P", provider: "X", baseURL: "https://x", model: "m", isActive: true)]
        c.llmApiKey = "sk-test-123"   // setter stores under the active provider
        r.check(c.providerAPIKeys[pid.uuidString] == "sk-test-123", "key: llmApiKey setter → providerAPIKeys[active]")
        r.check(c.llmApiKey == "sk-test-123", "key: llmApiKey getter reads active provider key")
        let data = try! JSONEncoder().encode(c)
        let back = try! JSONDecoder().decode(Configuration.self, from: data)
        r.check(back.providerAPIKeys[pid.uuidString] == "sk-test-123", "key: persists across encode/decode (local)")
        r.check(back.llmApiKey == "sk-test-123", "key: still readable after reload")
    }

    // MARK: - Debounced save: flush-on-quit + provider setter fallback

    static func testConfigFlushAndSetterFallback(_ r: Reporter) {
        let suite = "FlowTypeSelfTest.\(UUID().uuidString)"
        guard let ud = UserDefaults(suiteName: suite) else {
            r.check(false, "flush: could not create test suite"); return
        }
        defer { ud.removePersistentDomain(forName: suite) }

        // A save inside the 0.5s debounce window must survive quit. Self-test never pumps
        // the main run loop, so the debounced write below stays pending — same as quitting.
        let store = ConfigurationStore(defaults: ud)
        var c = store.current
        c.maxRecordingDuration = 120
        store.save(c)
        let onDisk0 = ud.data(forKey: "flowtype.config").flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) }
        r.check(onDisk0?.maxRecordingDuration != 120, "flush: debounced write still pending (precondition)")
        store.flushPendingSave()
        let onDisk1 = ud.data(forKey: "flowtype.config").flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) }
        r.eq(onDisk1?.maxRecordingDuration, 120, "flush: flushPendingSave persists the pending change")

        // EnvMigration regression: a store-routed key write is undone by a later save of a
        // stale snapshot — which is why migration writes keys into its snapshot directly.
        let pid = UUID()
        var c2 = store.current
        c2.llmProviders = [LLMProvider(id: pid, name: "P", provider: "X", baseURL: "https://x", model: "m", isActive: true)]
        let staleSnapshot = c2
        store.save(c2)
        store.saveProviderAPIKey("sk-k", for: pid)
        store.save(staleSnapshot)
        r.check(store.loadProviderAPIKey(pid) == nil,
                "flush: stale-snapshot save overwrites store-written key (EnvMigration must write into snapshot)")

        // Setter fallback: with no active provider the write lands on the first provider
        // (matching LLMService's read-side fallback) instead of being silently dropped.
        var c3 = Configuration()
        let pid3 = UUID()
        c3.llmProviders = [LLMProvider(id: pid3, name: "P", provider: "X", baseURL: "https://x", model: "m", isActive: false)]
        c3.llmApiKey = "sk-fallback"
        r.check(c3.providerAPIKeys[pid3.uuidString] == "sk-fallback", "key: setter falls back to first provider when none active")
        c3.llmModel = "m2"
        r.eq(c3.llmProviders[0].model, "m2", "key: llmModel setter falls back to first provider")
        var empty = Configuration()
        empty.llmProviders = []
        empty.llmApiKey = "sk-x"
        r.check(empty.providerAPIKeys.isEmpty, "key: setter with zero providers is a no-op")
    }

    // MARK: - Fun-fact footer

    static func testFunFact(_ r: Reporter) {
        var s = StatsSummary()
        s.chars = 24180
        s.timeSavedSeconds = StatsConfig.secondsPerMovie
        let f = FunFact.make(for: s)
        r.check(f.clauses.count == 3, "funfact: chars + keystrokes + movie → 3 clauses")
        r.check(f.clauses.first?.value.contains("24") == true, "funfact: highlighted char value present")
        r.check(FunFact.make(for: StatsSummary()).isEmpty, "funfact: empty when no chars")
    }

    // MARK: - JSONMigration idempotent import

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

    // MARK: - Privacy config: storeTranscriptText round-trip + legacy default

    static func testPrivacyConfig(_ r: Reporter) {
        var c = Configuration(); c.storeTranscriptText = false
        let data = try! JSONEncoder().encode(c)
        let back = try! JSONDecoder().decode(Configuration.self, from: data)
        r.check(back.storeTranscriptText == false, "config: storeTranscriptText round-trips")
        let legacy = Data(#"{"asrLanguage":"zh"}"#.utf8)
        let dflt = try? JSONDecoder().decode(Configuration.self, from: legacy)
        r.check(dflt?.storeTranscriptText == true, "config: storeTranscriptText defaults true on legacy JSON")
    }

    // MARK: - ASR routing policy config: round-trip + legacy engine migration

    static func testASRConfig(_ r: Reporter) {
        var cfg = Configuration()
        cfg.asrRoutingPolicy = .localOnly
        cfg.cloudASRSendContext = false
        cfg.selectedLocalModelID = "test-model-id"
        cfg.customLocalModelPath = "/tmp/custom-model"
        if let data = try? JSONEncoder().encode(cfg),
           let back = try? JSONDecoder().decode(Configuration.self, from: data) {
            r.eq(back.asrRoutingPolicy, .localOnly, "asrcfg: asrRoutingPolicy round-trips .localOnly")
            r.eq(back.cloudASRSendContext, false, "asrcfg: cloudASRSendContext round-trips false")
            r.eq(back.selectedLocalModelID, "test-model-id", "asrcfg: selectedLocalModelID round-trips")
            r.eq(back.customLocalModelPath, "/tmp/custom-model", "asrcfg: customLocalModelPath round-trips")
        } else {
            r.check(false, "asrcfg: encode/decode round-trip failed")
        }
        // legacy: asrEngine 存在 → 保持老用户行为
        let legacyLocal = Data(#"{"asrLanguage":"zh","asrEngine":"local"}"#.utf8)
        r.eq(try? JSONDecoder().decode(Configuration.self, from: legacyLocal).asrRoutingPolicy,
             .localOnly, "asrcfg: legacy asrEngine=local → localOnly")
        let legacyCloud = Data(#"{"asrLanguage":"zh","asrEngine":"cloud"}"#.utf8)
        r.eq(try? JSONDecoder().decode(Configuration.self, from: legacyCloud).asrRoutingPolicy,
             .cloudOnly, "asrcfg: legacy asrEngine=cloud → cloudOnly")
        // 全新安装 → auto（云端优先）
        let fresh = Data(#"{"asrLanguage":"zh"}"#.utf8)
        let decoded = try? JSONDecoder().decode(Configuration.self, from: fresh)
        r.eq(decoded?.asrRoutingPolicy, .auto, "asrcfg: missing key → auto")
        r.eq(decoded?.cloudASRSendContext, true, "asrcfg: missing key → cloudASRSendContext true")
        r.eq(decoded?.cloudASRConfig.providers.count, 1, "asrcfg: legacy missing key → default SiliconFlow provider")
        r.eq(decoded?.cloudASRConfig.providers.first?.provider, "SiliconFlow", "asrcfg: default provider is SiliconFlow")
        r.eq(decoded?.cloudASRConfig.providers.first?.model, "", "asrcfg: default model is empty (user must select)")
    }

    // MARK: - Cloud context opt-out

    static func testCloudContextToggle(_ r: Reporter) {
        r.check(Configuration().cloudASRSendContext, "ctx-toggle: default is true (cloud carries context)")
        var c = Configuration(); c.cloudASRSendContext = false
        let back = try? JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(c))
        r.check(back?.cloudASRSendContext == false, "ctx-toggle: false round-trips")
    }

    // MARK: - HardwareProfiler: memory tier classification

    static func testHardwareProfiler(_ r: Reporter) {
        r.eq(HardwareProfiler.tier(forMemoryGB: 7), .low, "profiler: 7GB → low")
        r.eq(HardwareProfiler.tier(forMemoryGB: 8), .low, "profiler: 8GB → low")
        r.eq(HardwareProfiler.tier(forMemoryGB: 15), .mid, "profiler: 15GB → mid")
        r.eq(HardwareProfiler.tier(forMemoryGB: 23), .mid, "profiler: 23GB → mid")
        r.eq(HardwareProfiler.tier(forMemoryGB: 24), .high, "profiler: 24GB → high")
        r.eq(HardwareProfiler.tier(forMemoryGB: 64), .high, "profiler: 64GB → high")
        r.check(HardwareProfiler.currentMemoryBytes() > 0, "profiler: current memory bytes > 0")
    }

    // MARK: - ModelPreset: preset catalog + tier recommendation

    static func testModelPreset(_ r: Reporter) {
        r.check(ModelPreset.allPresets.count >= 2, "preset: at least 2 presets")
        r.eq(ModelPreset.recommendedModel(for: .low).id, "qwen3-0.6b-4bit", "preset: low → 0.6b")
        r.eq(ModelPreset.recommendedModel(for: .mid).id, "qwen3-1.7b-4bit", "preset: mid → 1.7b (recommended for ≥12GB)")
        r.eq(ModelPreset.recommendedModel(for: .high).id, "qwen3-1.7b-4bit", "preset: high → 1.7b")
        r.check(ModelPreset.preset(forID: "qwen3-0.6b-4bit") != nil, "preset: lookup by id works")
        r.check(ModelPreset.preset(forID: "nonexistent") == nil, "preset: unknown id → nil")
        let high = ModelPreset.allPresets.first { $0.id == "qwen3-1.7b-4bit" }!
        r.check(high.recommendedTiers.contains(.high), "preset: 1.7b recommended for high")
        r.check(high.recommendedTiers.contains(.mid), "preset: 1.7b recommended for mid")
        r.check(!high.recommendedTiers.contains(.low), "preset: 1.7b not recommended for low")
    }

    // MARK: - CustomModelScanner: validateModelDirectory error cases + success

    static func testCustomModelScanner(_ r: Reporter) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("flowtype-scannertest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        func write(_ name: String, _ bytes: Int, in dir: URL) {
            fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data(count: bytes))
        }

        let minBytes: Int64 = 100 * 1024

        // 1. Non-existent directory → .directoryNotFound
        let ghost = base.appendingPathComponent("does-not-exist")
        do {
            _ = try CustomModelScanner.validateModelDirectory(ghost, minBytes: minBytes)
            r.check(false, "scanner: non-existent dir should throw")
        } catch let error as ModelScanError {
            if case .directoryNotFound = error {
                r.check(true, "scanner: non-existent dir → .directoryNotFound")
            } else {
                r.check(false, "scanner: non-existent dir → wrong error: \(error.localizedDescription)")
            }
        } catch {
            r.check(false, "scanner: non-existent dir → unexpected error type")
        }

        // 2. Directory with only config.json → .missingTokenizer
        let dir2 = base.appendingPathComponent("tok-missing")
        try? fm.createDirectory(at: dir2, withIntermediateDirectories: true)
        write("config.json", 10, in: dir2)
        do {
            _ = try CustomModelScanner.validateModelDirectory(dir2, minBytes: minBytes)
            r.check(false, "scanner: missing tokenizer should throw")
        } catch let error as ModelScanError {
            if case .missingTokenizer = error {
                r.check(true, "scanner: only config → .missingTokenizer")
            } else {
                r.check(false, "scanner: only config → wrong error: \(error.localizedDescription)")
            }
        } catch {
            r.check(false, "scanner: only config → unexpected error type")
        }

        // 3. config + tokenizer + small weights (< minBytes) → .weightsTooSmall
        let dir3 = base.appendingPathComponent("weights-small")
        try? fm.createDirectory(at: dir3, withIntermediateDirectories: true)
        write("config.json", 10, in: dir3)
        write("tokenizer.json", 10, in: dir3)
        write("model.safetensors", 1024, in: dir3)
        do {
            _ = try CustomModelScanner.validateModelDirectory(dir3, minBytes: minBytes)
            r.check(false, "scanner: small weights should throw")
        } catch let error as ModelScanError {
            if case .weightsTooSmall = error {
                r.check(true, "scanner: config+tok+small weights → .weightsTooSmall")
            } else {
                r.check(false, "scanner: small weights → wrong error: \(error.localizedDescription)")
            }
        } catch {
            r.check(false, "scanner: small weights → unexpected error type")
        }

        // 4. config + tokenizer + large weights (≥ minBytes) → success
        let dir4 = base.appendingPathComponent("weights-large")
        try? fm.createDirectory(at: dir4, withIntermediateDirectories: true)
        write("config.json", 10, in: dir4)
        write("tokenizer.json", 10, in: dir4)
        write("model.safetensors", 200 * 1024, in: dir4)
        do {
            let info = try CustomModelScanner.validateModelDirectory(dir4, minBytes: minBytes)
            r.check(info.sizeBytes >= minBytes, "scanner: large weights → success, sizeBytes ≥ minBytes")
            r.eq(info.url.path, dir4.path, "scanner: success returns correct url")
        } catch {
            r.check(false, "scanner: large weights should succeed, got: \(error.localizedDescription)")
        }

        // 5. Alternate tokenizer form: tokenizer_config.json + vocab.json
        let dir5 = base.appendingPathComponent("alt-tokenizer")
        try? fm.createDirectory(at: dir5, withIntermediateDirectories: true)
        write("config.json", 10, in: dir5)
        write("tokenizer_config.json", 10, in: dir5)
        write("vocab.json", 10, in: dir5)
        write("model.safetensors", 200 * 1024, in: dir5)
        do {
            _ = try CustomModelScanner.validateModelDirectory(dir5, minBytes: minBytes)
            r.check(true, "scanner: tokenizer_config.json+vocab.json accepted as tokenizer")
        } catch {
            r.check(false, "scanner: alt tokenizer should succeed, got: \(error.localizedDescription)")
        }

        // 6. Missing config → .missingConfig
        let dir6 = base.appendingPathComponent("config-missing")
        try? fm.createDirectory(at: dir6, withIntermediateDirectories: true)
        write("tokenizer.json", 10, in: dir6)
        write("model.safetensors", 200 * 1024, in: dir6)
        do {
            _ = try CustomModelScanner.validateModelDirectory(dir6, minBytes: minBytes)
            r.check(false, "scanner: missing config should throw")
        } catch let error as ModelScanError {
            if case .missingConfig = error {
                r.check(true, "scanner: no config → .missingConfig")
            } else {
                r.check(false, "scanner: no config → wrong error: \(error.localizedDescription)")
            }
        } catch {
            r.check(false, "scanner: no config → unexpected error type")
        }
    }

    // MARK: - Injection edge cases: emoji/surrogate safety, newline boundaries, config defaults, continuation double-error

    static func testInjectionEdgeCases(_ r: Reporter) {
        let emojiChunks = KeyboardInjector.chunk("a🌍b", size: 2)
        r.eq(emojiChunks.joined(), "a🌍b", "inject-edge: emoji chunk round-trips intact")
        for piece in emojiChunks {
            let units = Array(piece.utf16)
            for (i, unit) in units.enumerated() {
                if (0xD800...0xDBFF).contains(unit) {
                    r.check(i + 1 < units.count && (0xDC00...0xDFFF).contains(units[i + 1]),
                           "inject-edge: high surrogate paired in chunk '\(piece)'")
                }
            }
        }
        let helloChunks = KeyboardInjector.chunk("hello 🌍 world", size: 5)
        r.eq(helloChunks.joined(), "hello 🌍 world", "inject-edge: emoji sentence round-trips at size=5")

        r.eq(KeyboardInjector.normalizeNewlines(""), "", "inject-edge: normalizeNewlines empty → empty")
        r.eq(KeyboardInjector.normalizeNewlines("abc"), "abc", "inject-edge: normalizeNewlines no newlines → unchanged")
        r.eq(KeyboardInjector.normalizeNewlines("a\nb"), "a\nb", "inject-edge: normalizeNewlines all LF → unchanged")
        r.eq(KeyboardInjector.normalizeNewlines("a\r\nb\rc\nd"), "a\nb\nc\nd", "inject-edge: normalizeNewlines mixed CRLF/CR/LF → all LF")
        r.eq(KeyboardInjector.normalizeNewlines("line\r\n"), "line\n", "inject-edge: normalizeNewlines CRLF at end → LF")
        r.eq(KeyboardInjector.normalizeNewlines("\r\n\r\n"), "\n\n", "inject-edge: normalizeNewlines consecutive CRLFs → LFs")

        r.eq(KeyboardInjector.splitIntoLineSegments(""), [""], "inject-edge: split empty → [\"\"]")
        r.eq(KeyboardInjector.splitIntoLineSegments("\n"), ["", ""], "inject-edge: split single newline → [\"\", \"\"]")
        r.eq(KeyboardInjector.splitIntoLineSegments("\nabc"), ["", "abc"], "inject-edge: split leading newline")
        r.eq(KeyboardInjector.splitIntoLineSegments("abc\n"), ["abc", ""], "inject-edge: split trailing newline")
        r.eq(KeyboardInjector.splitIntoLineSegments("\n\n"), ["", "", ""], "inject-edge: split consecutive newlines")
        r.eq(KeyboardInjector.splitIntoLineSegments("\n\nabc"), ["", "", "abc"], "inject-edge: split two leading newlines")

        let cfg = Configuration()
        r.eq(cfg.asrRoutingPolicy, .auto, "inject-edge: default asrRoutingPolicy == .auto")
        r.eq(cfg.hasCompletedOnboarding, false, "inject-edge: default hasCompletedOnboarding == false")
        r.eq(cfg.selectedLocalModelID, nil, "inject-edge: default selectedLocalModelID == nil")
        r.check(!cfg.cloudASRConfig.providers.isEmpty, "inject-edge: default cloudASRConfig has providers")
        r.check(cfg.cloudASRConfig.providerAPIKeys.isEmpty, "inject-edge: default cloudASRConfig has no API keys")
        if let activeProvider = cfg.cloudASRConfig.activeProvider {
            r.eq(activeProvider.model, "", "inject-edge: default cloud ASR provider model is empty")
        } else {
            r.check(false, "inject-edge: default cloudASRConfig has active provider")
        }

        final class Slot: @unchecked Sendable { var value: String? }
        let box = CancellableContinuationBox<String>()
        let slot = Slot()
        let installed = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                slot.value = try await withCheckedThrowingContinuation { c in
                    box.setContinuation(c)
                    installed.signal()
                }
            } catch is CancellationError {
                slot.value = "cancelled"
            } catch {
                slot.value = "error"
            }
            done.signal()
        }
        guard installed.wait(timeout: .now() + 5) == .success else {
            r.check(false, "inject-edge: continuation install timed out"); return
        }
        struct TestError: Error {}
        box.resume(throwing: TestError())
        box.resume(throwing: TestError())
        box.cancel()
        guard done.wait(timeout: .now() + 5) == .success else {
            r.check(false, "inject-edge: resume wait timed out"); return
        }
        r.eq(slot.value, "error", "inject-edge: first error resume wins, double error+cancel are no-ops")
    }

    // MARK: - Injection segmentation (B-inject)

    static func testInjectionSegmentation(_ r: Reporter) {
        r.eq(KeyboardInjector.normalizeNewlines("a\r\nb\rc"), "a\nb\nc", "inject: CRLF/CR normalized to LF")
        r.eq(KeyboardInjector.splitIntoLineSegments("a\n\nc"), ["a", "", "c"], "inject: split keeps empty segments")
        r.eq(KeyboardInjector.splitIntoLineSegments("single"), ["single"], "inject: single line → one segment")
        r.eq(KeyboardInjector.chunk("abcdef", size: 2), ["ab", "cd", "ef"], "inject: chunk splits evenly")
        r.eq(KeyboardInjector.chunk("abcde", size: 2), ["ab", "cd", "e"], "inject: chunk handles remainder")
        r.eq(KeyboardInjector.chunk("", size: 64), [], "inject: chunk empty → no pieces")
        r.eq(KeyboardInjector.chunk("abc", size: 0), ["abc"], "inject: chunk size 0 → whole string")

        let text = "hello world\nlonger line that exceeds the chunk size by a fair bit\n\nend"
        let segs = KeyboardInjector.splitIntoLineSegments(KeyboardInjector.normalizeNewlines(text))
        let rebuilt = segs.map { KeyboardInjector.chunk($0, size: 8).joined() }.joined(separator: "\n")
        r.eq(rebuilt, KeyboardInjector.normalizeNewlines(text), "inject: segment+chunk round-trips")
    }

    // MARK: - Unified ASR routing: pure candidate-chain decision

    static func testASRRouting(_ r: Reporter) {
        func inputs(policy: ASRRoutingPolicy = .auto, local: Bool = true, cloud: Bool = true,
                    net: Bool = true, lat: Double = 0, fails: Int = 0) -> ASRRoutingInputs {
            ASRRoutingInputs(policy: policy, localAvailable: local, cloudAvailable: cloud,
                             networkReachable: net, cloudLatencyEWMA: lat,
                             cloudConsecutiveFailures: fails)
        }
        r.eq(selectASRChain(inputs()), ["cloud-asr", "qwen-local"], "route: auto healthy → cloud first")
        r.eq(selectASRChain(inputs(net: false)), ["qwen-local", "cloud-asr"], "route: auto offline → local first")
        r.eq(selectASRChain(inputs(lat: 5000)), ["qwen-local", "cloud-asr"], "route: auto slow cloud → local first")
        r.eq(selectASRChain(inputs(fails: 2)), ["qwen-local", "cloud-asr"], "route: auto failing cloud → local first")
        r.eq(selectASRChain(inputs(lat: 3000)), ["cloud-asr", "qwen-local"], "route: auto latency at threshold → cloud first")
        r.eq(selectASRChain(inputs(cloud: false)), ["qwen-local"], "route: auto cloud missing → local only")
        r.eq(selectASRChain(inputs(local: false)), ["cloud-asr"], "route: auto local missing → cloud only")
        r.eq(selectASRChain(inputs(local: false, cloud: false)), [], "route: auto neither → empty")
        r.eq(selectASRChain(inputs(policy: .localOnly)), ["qwen-local"], "route: localOnly → local")
        r.eq(selectASRChain(inputs(policy: .localOnly, local: false)), [], "route: localOnly+unavailable → empty")
        r.eq(selectASRChain(inputs(policy: .localOnly, net: false)), ["qwen-local"], "route: localOnly ignores network")
        r.eq(selectASRChain(inputs(policy: .cloudOnly)), ["cloud-asr"], "route: cloudOnly → cloud")
        r.eq(selectASRChain(inputs(policy: .cloudOnly, cloud: false)), [], "route: cloudOnly+unavailable → empty")

        // policy round-trips and legacy display
        let data = try! JSONEncoder().encode(ASRRoutingPolicy.auto)
        r.eq(try? JSONDecoder().decode(ASRRoutingPolicy.self, from: data), .auto, "route: policy round-trips")
        r.eq(ASRRoutingPolicy.allCases.count, 3, "route: exactly 3 policies")
    }

    // MARK: - ASRContext → provider prompt hint

    static func testProviderContextCompose(_ r: Reporter) {
        r.check(composeProviderContext(nil) == nil, "ctx: nil → nil")
        r.check(composeProviderContext(ASRContext(phrases: [], foreground: nil)) == nil, "ctx: empty → nil")
        r.eq(composeProviderContext(ASRContext(phrases: ["React"], foreground: nil)), "React", "ctx: phrases only")
        r.eq(composeProviderContext(ASRContext(phrases: [], foreground: "func main()")), "func main()", "ctx: foreground only")
        r.eq(composeProviderContext(ASRContext(phrases: ["React"], foreground: "func main()")),
             "React\nfunc main()", "ctx: phrases then foreground")
        let longFG = String(repeating: "x", count: 5000)
        r.eq((composeProviderContext(ASRContext(phrases: [], foreground: longFG)) ?? "").count, 1200,
             "ctx: foreground truncated to 1200")
        r.check(composeProviderContext(ASRContext(phrases: [], foreground: "   ")) == nil, "ctx: blank foreground → nil")
    }

    // MARK: - ASR backend label mapping (replaces the old `as? QwenASRProvider` branches)

    static func testASRBackendLabel(_ r: Reporter) {
        r.eq(SessionController.backendLabel(forProviderID: "qwen-local"), "qwen", "backend: qwen-local → qwen")
        r.eq(SessionController.backendLabel(forProviderID: "cloud-asr"), "cloud", "backend: cloud-asr → cloud")
        r.eq(SessionController.backendLabel(forProviderID: nil), "apple", "backend: nil → apple (preview fallback)")
        r.eq(SessionController.backendLabel(forProviderID: "unknown"), "apple", "backend: unknown id → apple")
    }

    // MARK: - Provider failure → aggregatable fallback reason (pure)

    static func testFallbackReasonClassification(_ r: Reporter) {
        r.eq(fallbackReason(for: CloudASRError.timeout), "timeout", "fallback: CloudASRError.timeout")
        r.eq(fallbackReason(for: CloudASRError.networkError(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost))),
             "network", "fallback: CloudASRError.networkError")
        r.eq(fallbackReason(for: CloudASRError.noAPIKey), "unavailable", "fallback: noAPIKey")
        r.eq(fallbackReason(for: CloudASRError.noModel), "unavailable", "fallback: noModel")
        r.eq(fallbackReason(for: CloudASRError.noActiveProvider), "unavailable", "fallback: noActiveProvider")
        r.eq(fallbackReason(for: CloudASRError.invalidResponse), "error", "fallback: invalidResponse")
        r.eq(fallbackReason(for: CloudASRError.apiError(statusCode: 500, message: "boom")), "error", "fallback: apiError")
        r.eq(fallbackReason(for: CloudASRError.invalidURL("bad")), "error", "fallback: invalidURL")
        r.eq(fallbackReason(for: CloudASRError.audioEncodingFailed), "error", "fallback: audioEncodingFailed")
        r.eq(fallbackReason(for: SpeechProviderError.notAvailable), "unavailable", "fallback: SpeechProviderError.notAvailable")
        r.eq(fallbackReason(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)),
             "network", "fallback: NSURLErrorDomain NSError")
        r.eq(fallbackReason(for: SpeechProviderError.permissionDenied), "error", "fallback: SpeechProviderError.permissionDenied")
        struct UnknownError: Error {}
        r.eq(fallbackReason(for: UnknownError()), "error", "fallback: unknown error → error")
    }

    // MARK: - Provider capability contract (router's requiresNetwork gate depends on it)

    static func testASRCapabilityContract(_ r: Reporter) {
        let qwen = ASRProviderRegistry.shared.qwenLocalProvider
        let cloud = ASRProviderRegistry.shared.cloudProvider
        r.eq(qwen.id, ASRProviderID.qwenLocal, "caps: qwen id matches constant")
        r.eq(qwen.capabilities.requiresNetwork, false, "caps: qwen-local is not network-backed")
        r.eq(qwen.capabilities.location, .onDevice, "caps: qwen-local location onDevice")
        r.eq(cloud.id, ASRProviderID.cloud, "caps: cloud id matches constant")
        r.eq(cloud.capabilities.requiresNetwork, true, "caps: cloud requires network")
        r.eq(cloud.capabilities.location, .cloud, "caps: cloud location cloud")
    }

    // MARK: - ASR router health: latency EWMA

    static func testRouterEWMA(_ r: Reporter) {
        // 首个样本（previous == 0）直接采用，避免从 0 缓慢爬升
        r.eq(updateLatencyEWMA(previous: 0, sample: 800), 800, "ewma: first sample taken directly")
        // 后续样本按 alpha=0.3 加权
        r.eq(updateLatencyEWMA(previous: 1000, sample: 2000), 1300, "ewma: alpha 0.3 blend")
        r.eq(updateLatencyEWMA(previous: 1000, sample: 0), 700, "ewma: fast sample pulls average down")
        // 单调性：连续慢样本必须把均值推过阈值
        var v = 0.0
        for _ in 0..<5 { v = updateLatencyEWMA(previous: v, sample: 5000) }
        r.check(v > ASRRoutingThresholds.cloudLatencyMs, "ewma: sustained slow samples exceed threshold")
    }

    // MARK: - Cloud probe: endpoint parsing + cold-start effective latency

    static func testCloudProbe(_ r: Reporter) {
        // 1. probeEndpoint: https + host + port 解析（纯函数）。
        let sf = CloudProbe.probeEndpoint(fromBaseURL: "https://api.siliconflow.cn/v1")
        r.eq(sf?.host, "api.siliconflow.cn", "probe: SiliconFlow host parsed")
        r.eq(sf?.port, 443, "probe: default port 443 when absent")

        let custom = CloudProbe.probeEndpoint(fromBaseURL: "https://api.openai.com:8443/v1")
        r.eq(custom?.host, "api.openai.com", "probe: custom-port host parsed")
        r.eq(custom?.port, 8443, "probe: explicit port honoured")

        let padded = CloudProbe.probeEndpoint(fromBaseURL: "  https://x.example/v1  ")
        r.eq(padded?.host, "x.example", "probe: surrounding whitespace trimmed")
        r.eq(padded?.port, 443, "probe: trimmed url still gets default port")

        r.check(CloudProbe.probeEndpoint(fromBaseURL: "http://x.example/v1") == nil, "probe: non-https → nil")
        r.check(CloudProbe.probeEndpoint(fromBaseURL: "api.siliconflow.cn") == nil, "probe: scheme-less → nil")
        r.check(CloudProbe.probeEndpoint(fromBaseURL: "") == nil, "probe: empty → nil")

        // 2. 量纲隔离：探测值有自己的阈值，绝不与整轮请求延迟共用同一个槽位/阈值。
        //    核心不变式 —— 探测值域是 [0, timeout*1000)，必须能越过"慢握手"阈值，
        //    否则探测在数学上永远无法触发（这正是本次修复的 bug）。
        r.check(ASRRouterProbeConfig.timeout * 1000 > ASRRoutingThresholds.cloudProbeHandshakeMs,
                "probe: producible value range must exceed the slow-handshake threshold")
        r.check(ASRRoutingThresholds.cloudProbeHandshakeMs < ASRRoutingThresholds.cloudLatencyMs,
                "probe: handshake threshold calibrated below the request-latency threshold")

        // 3. sampleIsFresh: TTL 过期判定（探测与 EWMA 共用）。
        let now = Date()
        r.check(!sampleIsFresh(sampledAt: nil, now: now, ttl: 30), "probe: nil sample → stale")
        r.check(sampleIsFresh(sampledAt: now.addingTimeInterval(-10), now: now, ttl: 30), "probe: 10s old < 30s ttl → fresh")
        r.check(!sampleIsFresh(sampledAt: now.addingTimeInterval(-40), now: now, ttl: 30), "probe: 40s old > 30s ttl → stale")

        // 4. 路由组合：冷启动时探测真正参与决策（用生产可达的握手值，非 5000 之类不可达值）。
        func cold(probe: Double?, failed: Bool = false, ewma: Double = 0) -> ASRRoutingInputs {
            ASRRoutingInputs(policy: .auto, localAvailable: true, cloudAvailable: true,
                             networkReachable: true, cloudLatencyEWMA: ewma,
                             cloudConsecutiveFailures: 0,
                             cloudProbeMs: probe, cloudProbeFailed: failed)
        }
        r.eq(selectASRChain(cold(probe: 900)), [ASRProviderID.qwenLocal, ASRProviderID.cloud],
             "probe: cold + producible 900ms handshake → local-first")
        r.eq(selectASRChain(cold(probe: 200)), [ASRProviderID.cloud, ASRProviderID.qwenLocal],
             "probe: cold + fast 200ms handshake → cloud-first")
        r.eq(selectASRChain(cold(probe: ASRRoutingThresholds.cloudProbeHandshakeMs)),
             [ASRProviderID.cloud, ASRProviderID.qwenLocal],
             "probe: cold + handshake exactly at threshold → cloud-first (边界含等号)")
        r.eq(selectASRChain(cold(probe: nil)), [ASRProviderID.cloud, ASRProviderID.qwenLocal],
             "probe: never sampled → existing healthy default (unchanged)")
        r.eq(selectASRChain(cold(probe: nil, failed: true)), [ASRProviderID.qwenLocal, ASRProviderID.cloud],
             "probe: sampled but failed → negative signal → local-first")
        r.eq(selectASRChain(cold(probe: 900, ewma: 1200)), [ASRProviderID.cloud, ASRProviderID.qwenLocal],
             "probe: real EWMA is ground truth → slow probe ignored once a real sample exists")
    }

    // MARK: - Network path change detection (probe cache must be invalidated on switch)

    static func testPathChangeDetection(_ r: Reporter) {
        func sig(satisfied: Bool = true, expensive: Bool = false, constrained: Bool = false,
                 interface: String? = "wifi") -> PathSignature {
            PathSignature(satisfied: satisfied, isExpensive: expensive,
                          isConstrained: constrained, interface: interface)
        }
        r.check(!pathChanged(previous: nil, current: sig()), "path: first observation is not a change")
        r.check(!pathChanged(previous: sig(), current: sig()), "path: identical observation → no change")
        r.check(pathChanged(previous: sig(), current: sig(interface: "cellular")),
                "path: interface switch → change (invalidate probe cache)")
        r.check(pathChanged(previous: sig(), current: sig(satisfied: false)),
                "path: reachability flip → change")
        r.check(pathChanged(previous: sig(), current: sig(expensive: true)),
                "path: became expensive → change")
        r.check(pathChanged(previous: sig(), current: sig(constrained: true)),
                "path: became constrained → change")
    }

    // MARK: - Probe gating (when to spend a handshake at all)

    static func testProbeGating(_ r: Reporter) {
        func sig(satisfied: Bool = true, expensive: Bool = false, constrained: Bool = false) -> PathSignature {
            PathSignature(satisfied: satisfied, isExpensive: expensive,
                          isConstrained: constrained, interface: "wifi")
        }
        // 采样 TTL 必须严格短于探测周期，否则每隔一拍才真正探测（有效周期翻倍）。
        r.check(ASRRouterProbeConfig.ttl < ASRRouterProbeConfig.interval,
                "probe-gate: ttl strictly shorter than interval")
        r.check(!shouldProbeCloud(path: sig(), policy: .localOnly), "probe-gate: localOnly → never probe")
        r.check(!shouldProbeCloud(path: sig(), policy: .cloudOnly), "probe-gate: cloudOnly → never probe")
        r.check(shouldProbeCloud(path: sig(), policy: .auto), "probe-gate: auto + normal link → probe")
        r.check(!shouldProbeCloud(path: sig(satisfied: false), policy: .auto), "probe-gate: offline → no probe")
        r.check(!shouldProbeCloud(path: sig(expensive: true), policy: .auto),
                "probe-gate: metered link → no probe (don't burn cellular data)")
        r.check(!shouldProbeCloud(path: sig(constrained: true), policy: .auto),
                "probe-gate: low-data mode → no probe")
        r.check(shouldProbeCloud(path: nil, policy: .auto), "probe-gate: no observation yet → probe")
    }

    // MARK: - Link-change invalidation contract (which samples die on a network switch)

    static func testLinkSampleInvalidation(_ r: Reporter) {
        var stale = RouterHealthSnapshot()
        stale.cloudLatencyEWMA = 4200          // 旧链路测到的整轮延迟
        stale.cloudLatencySampledAt = Date()
        stale.probeLatencyMs = 150             // 旧链路测到的握手
        stale.probeSampledAt = Date()
        stale.probeFailed = true
        stale.cloudConsecutiveFailures = 1
        stale.networkReachable = true

        let next = invalidateLinkSamples(stale)
        r.eq(next.cloudLatencyEWMA, 0, "invalidate: stale request latency dropped on link change")
        r.eq(next.cloudLatencySampledAt, nil, "invalidate: request-latency timestamp dropped")
        r.eq(next.probeLatencyMs, nil, "invalidate: probe latency dropped")
        r.eq(next.probeSampledAt, nil, "invalidate: probe timestamp dropped")
        r.check(!next.probeFailed, "invalidate: probe failure flag dropped")
        r.eq(next.cloudConsecutiveFailures, 1, "invalidate: failure streak preserved (link-agnostic evidence)")
        r.check(next.networkReachable, "invalidate: reachability preserved (owned by the path monitor)")
    }

    // MARK: - Aged latency sample (EWMA TTL, asymmetric)

    static func testAgedLatencySample(_ r: Reporter) {
        let now = Date()
        let ttl: TimeInterval = 300
        let fresh = now.addingTimeInterval(-10)
        let stale = now.addingTimeInterval(-9999)

        r.eq(agedLatencySample(0, sampledAt: nil, now: now, ttl: ttl), 0, "ewma-ttl: no sample → unknown")
        r.eq(agedLatencySample(1200, sampledAt: fresh, now: now, ttl: ttl), 1200, "ewma-ttl: fresh fast sample kept")
        r.eq(agedLatencySample(4200, sampledAt: fresh, now: now, ttl: ttl), 4200, "ewma-ttl: fresh slow sample kept")

        // 非对称的关键：保守不需要新鲜证据 —— 陈旧的"慢"样本依旧否决云端。
        // 若有过期即清零，则"握手快但服务端慢"的链路上会在 cloud/local 之间振荡。
        r.eq(agedLatencySample(4200, sampledAt: stale, now: now, ttl: ttl), 4200,
             "ewma-ttl: stale SLOW sample still blocks cloud (caution needs no fresh evidence)")

        // 陈旧的"快"样本不再可信 → 降级为未知，由握手探测重新判定（这正是被报告的缺口）。
        r.eq(agedLatencySample(1200, sampledAt: stale, now: now, ttl: ttl), 0,
             "ewma-ttl: stale FAST sample → unknown so the probe can re-decide")

        // 端到端组合：陈旧快样本 + 探测判慢 → 本地优先。
        let inputs = ASRRoutingInputs(
            policy: .auto, localAvailable: true, cloudAvailable: true, networkReachable: true,
            cloudLatencyEWMA: agedLatencySample(1200, sampledAt: stale, now: now, ttl: ttl),
            cloudConsecutiveFailures: 0,
            cloudProbeMs: 900
        )
        r.eq(selectASRChain(inputs), [ASRProviderID.qwenLocal, ASRProviderID.cloud],
             "ewma-ttl: stale fast EWMA + slow probe → local-first (the reported gap)")

        // 边界：恰好到期视为过期（与 sampleIsFresh 的 < 语义一致），两侧都要覆盖。
        r.eq(agedLatencySample(1200, sampledAt: now.addingTimeInterval(-ttl), now: now, ttl: ttl), 0,
             "ewma-ttl: exactly at ttl + fast → unknown")
        r.eq(agedLatencySample(4200, sampledAt: now.addingTimeInterval(-ttl), now: now, ttl: ttl), 4200,
             "ewma-ttl: exactly at ttl + slow → still kept")
        // 阈值处的一致性：新鲜侧以 `<= 3000` 为健康，故过期侧只有 `> 3000` 才值得保留。
        r.eq(agedLatencySample(ASRRoutingThresholds.cloudLatencyMs, sampledAt: stale, now: now, ttl: ttl), 0,
             "ewma-ttl: stale sample exactly at latency threshold → unknown (matches fresh <= threshold = healthy)")
    }

    // MARK: - Production wiring: snapshot → aging → decision (pins selectChain's real path)

    static func testRoutingInputsWiring(_ r: Reporter) {
        let now = Date()

        // 陈旧"快"EWMA + 新鲜慢探测 → 走本地。
        // 这钉住的是 ASRRouter.selectChain 实际走的组装函数，而不是测试里自制的合成。
        var snap = RouterHealthSnapshot()
        snap.cloudLatencyEWMA = 1200
        snap.cloudLatencySampledAt = now.addingTimeInterval(-(ASRRouterProbeConfig.latencyTtl + 60))
        snap.probeLatencyMs = 900
        snap.probeSampledAt = now
        let wired = routingInputs(from: snap, policy: .auto,
                                  localAvailable: true, cloudAvailable: true, now: now)
        r.eq(wired.cloudLatencyEWMA, 0, "wiring: stale fast EWMA aged to unknown")
        r.eq(selectASRChain(wired), [ASRProviderID.qwenLocal, ASRProviderID.cloud],
             "wiring: stale fast EWMA + slow probe → local-first")

        // 陈旧的探测值不得当"当前链路"用（休眠/唤醒后定时器不触发、无唤醒重探）。
        var staleProbe = RouterHealthSnapshot()
        staleProbe.probeLatencyMs = 200
        staleProbe.probeSampledAt = now.addingTimeInterval(-(ASRRouterProbeConfig.ttl + 60))
        let staleProbeInputs = routingInputs(from: staleProbe, policy: .auto,
                                            localAvailable: true, cloudAvailable: true, now: now)
        r.eq(staleProbeInputs.cloudProbeMs, nil, "wiring: stale probe value → unknown")
        r.eq(selectASRChain(staleProbeInputs), [ASRProviderID.cloud, ASRProviderID.qwenLocal],
             "wiring: stale probe must not decide the chain")

        // 干净启动：无任何样本 → 维持既有"未知视为健康"。
        let empty = routingInputs(from: RouterHealthSnapshot(), policy: .auto,
                                  localAvailable: true, cloudAvailable: true, now: now)
        r.eq(selectASRChain(empty), [ASRProviderID.cloud, ASRProviderID.qwenLocal],
             "wiring: no samples at all → unchanged healthy default")

        // 负证据在过期后仍保留（保守不需要新鲜证据）。
        var staleFailure = RouterHealthSnapshot()
        staleFailure.probeFailed = true
        staleFailure.probeSampledAt = now.addingTimeInterval(-(ASRRouterProbeConfig.ttl + 60))
        let staleFailureInputs = routingInputs(from: staleFailure, policy: .auto,
                                              localAvailable: true, cloudAvailable: true, now: now)
        r.eq(selectASRChain(staleFailureInputs), [ASRProviderID.qwenLocal, ASRProviderID.cloud],
             "wiring: stale failure evidence still blocks cloud")

        // 新鲜探测值照常透传。
        var fresh = RouterHealthSnapshot()
        fresh.probeLatencyMs = 200
        fresh.probeSampledAt = now
        let freshInputs = routingInputs(from: fresh, policy: .auto,
                                        localAvailable: true, cloudAvailable: true, now: now)
        r.eq(freshInputs.cloudProbeMs, 200, "wiring: fresh probe value passes through")
    }

    // MARK: - Foreground context assembly (pure)

    static func testContextAssembly(_ r: Reporter) {
        r.check(buildContextText(nil) == nil, "ctx-asm: nil → nil")
        r.check(buildContextText(ForegroundContext(appName: nil, elementText: nil, url: nil, selectedText: nil)) == nil,
                "ctx-asm: all-nil → nil")
        r.eq(buildContextText(ForegroundContext(appName: "Xcode", elementText: "func main()", url: nil, selectedText: nil)),
             "func main()", "ctx-asm: elementText is primary signal")
        r.eq(buildContextText(ForegroundContext(appName: "Terminal", elementText: nil, url: nil, selectedText: "git log")),
             "git log", "ctx-asm: selectedText included when no elementText")
        r.eq(buildContextText(ForegroundContext(appName: "Safari", elementText: nil, url: "https://docs.swift.org", selectedText: nil)),
             "https://docs.swift.org", "ctx-asm: url included when nothing else")
        let both = buildContextText(ForegroundContext(appName: "X", elementText: "code", url: "https://x", selectedText: "sel"))
        r.eq(both, "code\nsel\nhttps://x", "ctx-asm: elementText > selectedText > url order")
        let long = ForegroundContext(appName: nil, elementText: String(repeating: "z", count: 5000), url: nil, selectedText: nil)
        r.eq((buildContextText(long) ?? "").count, 1200, "ctx-asm: bounded to 1200 chars")
        // 密钥脱敏：上下文里不得出现 Bearer / sk- / sf- 形态的串
        r.check(!redactContextSecrets("Authorization: Bearer sk-abcdefghij123456").contains("sk-abcdefghij123456"),
                "ctx-asm: sk- token redacted")
        r.check(!redactContextSecrets("key=sf-abcdefghij123456").contains("sf-abcdefghij123456"),
                "ctx-asm: sf- token redacted")
        // 反向保护：词内 `sk-`/`sf-` 不得被误伤。上下文会喂进 ASR 提示词偏向技术词，
        // 过度脱敏会把标识符打残（disk-partitioning → di[REDACTED]），反而降低技术词命中率。
        r.eq(redactContextSecrets("disk-partitioning task-something desk-organizer"),
             "disk-partitioning task-something desk-organizer",
             "ctx-asm: identifiers containing sk- are preserved")
        r.eq(redactContextSecrets("please use Bearer authentication"), "please use Bearer authentication",
             "ctx-asm: prose after Bearer is not redacted")
        r.check(!redactContextSecrets("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abcdefgh").contains("eyJhbGciOiJIUzI1NiJ9"),
                "ctx-asm: long Bearer token still redacted")
    }

    // MARK: - Secure focus: password fields must never be collected

    static func testSecureFocus(_ r: Reporter) {
        r.check(isSecureFocus(role: "AXTextField", subrole: "AXSecureTextField"),
                "secure: secure subrole → true")
        r.check(isSecureFocus(role: "AXSecureTextField", subrole: nil),
                "secure: secure role (defensive) → true")
        r.check(isSecureFocus(role: "AXSecureTextField", subrole: "AXSecureTextField"),
                "secure: both secure → true")
        r.check(!isSecureFocus(role: "AXTextField", subrole: nil),
                "secure: normal AXTextField → false")
        r.check(!isSecureFocus(role: nil, subrole: nil),
                "secure: nil/nil → false")
    }

    // MARK: - Routing key precedence: legacy asrEngine wins when both keys present

    static func testRoutingKeyPrecedence(_ r: Reporter) {
        // 兼容旧配置：当 asrEngine 与新 asrRoutingPolicy 同时存在时，旧键优先（保持老用户行为）。
        let both1 = Data(#"{"asrLanguage":"zh","asrEngine":"cloud","asrRoutingPolicy":"localOnly"}"#.utf8)
        r.eq(try? JSONDecoder().decode(Configuration.self, from: both1).asrRoutingPolicy,
             .cloudOnly, "route-key: legacy asrEngine=cloud wins over policy=localOnly")
        let both2 = Data(#"{"asrLanguage":"zh","asrEngine":"local","asrRoutingPolicy":"cloudOnly"}"#.utf8)
        r.eq(try? JSONDecoder().decode(Configuration.self, from: both2).asrRoutingPolicy,
             .localOnly, "route-key: legacy asrEngine=local wins over policy=cloudOnly")
        // 仅有新键时按其取值。
        let onlyNew = Data(#"{"asrLanguage":"zh","asrRoutingPolicy":"localOnly"}"#.utf8)
        r.eq(try? JSONDecoder().decode(Configuration.self, from: onlyNew).asrRoutingPolicy,
             .localOnly, "route-key: new-key-only → honoured")
    }

    // MARK: - Session metrics: percentile + report

    static func testSessionMetrics(_ r: Reporter) {
        r.check(percentile([], 0.5) == nil, "metrics: empty → nil")
        r.eq(percentile([100], 0.5), 100, "metrics: single value")
        r.eq(percentile([10, 20, 30, 40, 50], 0.5), 30, "metrics: p50 of odd set")
        r.eq(percentile([10, 20, 30, 40], 0.5), 30, "metrics: p50 nearest-rank of even set")
        r.eq(percentile([10, 20, 30, 40], 0.95), 40, "metrics: p95 clamps to max")
        r.eq(percentile([10, 20, 30, 40], 0.0), 10, "metrics: p0 → min")

        var s = DictationSession(rawTranscript: "a", finalText: "a", polishMode: .raw,
                                 durationMs: 2000, recordingMs: 1000, appName: nil,
                                 appBundleID: nil, language: "zh", sttBackend: "cloud")
        s.stopToInjectMs = 1500
        s.asrProviderID = "cloud-asr"
        s.usedFallback = false
        let txt = SessionMetrics.report([s])
        r.check(txt.contains("p50"), "metrics: report contains p50")
        r.check(txt.contains("1500"), "metrics: report contains the sample value")
        r.check(txt.contains("fallback: 0"), "metrics: report counts non-fallback as 0")

        var fb = DictationSession(rawTranscript: "b", finalText: "b", polishMode: .raw,
                                  durationMs: 2000, recordingMs: 1000, appName: nil,
                                  appBundleID: nil, language: "zh", sttBackend: "qwen")
        fb.usedFallback = true
        r.check(SessionMetrics.report([fb]).contains("fallback: 1"), "metrics: report counts usedFallback == true")

        // legacy JSON without ANY of the seven new metric keys must still decode (non-nil, usedFallback nil)
        let legacy = Data(#"{"id":"x","createdAt":"2026-01-01T00:00:00Z","rawTranscript":"a","finalText":"a","polishMode":"raw","durationMs":1000}"#.utf8)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let legacySession = try? dec.decode(DictationSession.self, from: legacy)
        r.check(legacySession != nil, "metrics: legacy JSON decodes (no new keys)")
        r.eq(legacySession?.usedFallback, nil, "metrics: legacy JSON → usedFallback nil (no throw)")
    }

    static func testMetricsSchema(_ r: Reporter) {
        guard let db = try? AppDatabase.inMemory() else { r.check(false, "metrics-db"); return }
        var s = DictationSession(rawTranscript: "hi", finalText: "hi", polishMode: .raw,
                                 durationMs: 2000, recordingMs: 1000, appName: "A",
                                 appBundleID: nil, language: "en", sttBackend: "cloud")
        s.stopToInjectMs = 1420
        s.asrProviderID = "cloud-asr"
        s.usedFallback = true
        s.fallbackReason = "network"
        s.asrMs = 900
        var rec = SessionRecord(from: s)
        try? db.dbQueue.write { try rec.insert($0) }
        let back = (try? db.dbQueue.read { try SessionRecord.fetchAll($0) })?.first
        r.eq(back?.stopToInjectMs, 1420, "metrics: stopToInjectMs persisted")
        r.eq(back?.usedFallback, true, "metrics: usedFallback persisted")
        r.eq(back?.fallbackReason, "network", "metrics: fallbackReason persisted")
        r.eq(back?.asrProviderID, "cloud-asr", "metrics: asrProviderID persisted")

        // nil/false case: a session that did NOT fall back round-trips as false / nil.
        var plain = DictationSession(rawTranscript: "ok", finalText: "ok", polishMode: .raw,
                                     durationMs: 1000, recordingMs: 800, appName: nil,
                                     appBundleID: nil, language: "en", sttBackend: "qwen")
        plain.usedFallback = nil
        plain.fallbackReason = nil
        let plainBack = SessionRecord(from: plain).toDictationSession()
        r.eq(plainBack.usedFallback, false, "metrics: nil usedFallback → false round-trip")
        r.eq(plainBack.fallbackReason, nil, "metrics: nil fallbackReason → nil round-trip")
    }
}
