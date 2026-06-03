import Foundation

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

    static func runAndExit() -> Never {
        let r = Reporter()
        print("=== FlowType --self-test ===")
        testLLMURL(r)            // B1
        testSSEParse(r)          // B8
        testConfigCorrupt(r)     // B9
        testInjectionSegmentation(r) // injection helpers
        testASRWiring(r)         // ASR language + context
        testSpectrumMath(r)      // SpectrumMath pure DSP helpers
        testFFTPeak(r)           // SpectrumAnalyzer FFT correctness
        testSpectrumProcess(r)   // SpectrumAnalyzer.process smoothed bands
        testStatFormatting(r)    // StatFormatting pure formatters
        testPolishModeMigration(r) // history mode raw/polish + legacy decode
        testInjectionDecision(r)   // delivery decision: classifyFocus + decideInjection
        testAppearanceConfig(r)    // appearance pref round-trip + legacy default
        testModelConfig(r)         // model provisioning fields: round-trip + legacy default
        testDownloadSource(r)      // DownloadSource endpoint mapping
        print("=== self-test: \(r.passed) passed, \(r.failed) failed ===")
        exit(r.failed == 0 ? 0 : 1)
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
             [StatSegment(number: "2", unit: "小时"), StatSegment(number: "14", unit: "分钟")],
             "stat: 8054s → 2小时14分钟")
        r.eq(StatFormatting.duration(seconds: 840),
             [StatSegment(number: "14", unit: "分钟")],
             "stat: 840s → 14分钟 (no hours segment)")
        r.eq(StatFormatting.duration(seconds: 0),
             [StatSegment(number: "0", unit: "分钟")],
             "stat: 0s → 0分钟")
        r.eq(StatFormatting.speed(142),
             [StatSegment(number: "142", unit: "字/分")],
             "stat: speed")
        r.eq(StatFormatting.plain("18,402"),
             [StatSegment(number: "18,402", unit: nil)],
             "stat: plain word count unchanged")
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

}
