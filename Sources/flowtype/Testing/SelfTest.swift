import Foundation
import AppKit

/// A pasteboard data provider that intentionally provides nothing, simulating
/// promise/lazy clipboard content (copied file, on-demand image) whose data cannot
/// be materialized on demand.
private final class LazyPasteboardProvider: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {}
}

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

    static func runAndExit() -> Never {
        let r = Reporter()
        print("=== FlowType --self-test ===")
        testLLMURL(r)            // B1
        testSSEParse(r)          // B8
        testConfigCorrupt(r)     // B9
        testClipboardSnapshot(r) // B7
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

    // MARK: - B7: clipboard snapshot round-trips; lossy content is detected

    static func testClipboardSnapshot(_ r: Reporter) {
        let pb = NSPasteboard(name: NSPasteboard.Name("FlowTypeSelfTest.\(UUID().uuidString)"))
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("hello", forType: .string)
        item.setData(Data("<b>hi</b>".utf8), forType: .html)
        pb.writeObjects([item])

        let snap = KeyboardInjector.snapshotPasteboard(pb)
        r.check(!snap.isLossy, "B7 faithful multi-type snapshot is not lossy")

        // Simulate our paste overwriting the clipboard, then restore.
        pb.clearContents()
        pb.setString("INJECTED", forType: .string)
        KeyboardInjector.restore(snap, to: pb)
        r.check(pb.string(forType: .string) == "hello", "B7 string content restored")
        r.check(pb.data(forType: .html) == Data("<b>hi</b>".utf8), "B7 rich (html) content restored")

        // Un-snapshottable (promise/lazy) content must be flagged lossy so we never
        // overwrite the user's clipboard with a degraded copy.
        let pb2 = NSPasteboard(name: NSPasteboard.Name("FlowTypeSelfTest.\(UUID().uuidString)"))
        pb2.clearContents()
        let lazyItem = NSPasteboardItem()
        lazyItem.setDataProvider(LazyPasteboardProvider(), forTypes: [.fileURL])
        pb2.writeObjects([lazyItem])
        let snap2 = KeyboardInjector.snapshotPasteboard(pb2)
        r.check(snap2.isLossy, "B7 promise/lazy clipboard flagged lossy")
    }
}
