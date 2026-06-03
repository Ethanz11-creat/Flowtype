# Overview Stats Dashboard v1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Build the v1 Overview stats panel and fix the avg-speed bug — capture pure recording time + app + language per session, aggregate per local day, compute metrics in a pure `StatsEngine`, and render cards + activity heatmap + 24h distribution + footer with All/30d/7d switching.

**Architecture:** Per-session records (`DictationSession`) gain `recordingMs`/`appName`/`appBundleID`/`language`; the per-day rollup (`DailyStats`) gains `totalRecordingMs`/`byApp`/`byLang`/`hourHistogram`. A pure `StatsEngine` reads `[DailyStats]` → `StatsSummary`. SwiftUI panel renders it. Backward-compatible Codable; no destructive migration. v1 uses no Swift Charts (heatmap + bars are custom).

**Tech Stack:** Swift 6.2, SwiftUI/AppKit, JSON via `PersistentStore`.

**Spec:** `docs/superpowers/specs/2026-06-03-overview-stats-dashboard-design.md`

**Verify:** `swift build` green; `swift run FlowType --self-test` (currently 94/0) grows with `StatsEngine`/migration tests; real gate = on-device (Task 5). Ignore stale SourceKit "Cannot find X".

---

## Task 1: Data model — new fields + backward-compat + append aggregation fix

**Files:** Modify `Core/DictationHistory.swift`, `Core/DailyStats.swift`; modify `Testing/SelfTest.swift`.

- [ ] **Step 1: `DictationSession` — add optional fields.** In `Core/DictationHistory.swift`, replace the `DictationSession` struct with:
```swift
struct DictationSession: Codable, Identifiable {
    let id: String
    let createdAt: Date
    let rawTranscript: String
    let finalText: String
    let polishMode: PolishMode
    let durationMs: UInt64?          // legacy end-to-end wall clock (kept for fallback)
    let recordingMs: UInt64?         // pure recording time (the speed fix)
    let appName: String?
    let appBundleID: String?
    let language: String?            // "zh" / "en" / "mixed" (CJK heuristic)

    init(rawTranscript: String, finalText: String, polishMode: PolishMode,
         durationMs: UInt64?, recordingMs: UInt64? = nil,
         appName: String? = nil, appBundleID: String? = nil, language: String? = nil) {
        self.id = UUID().uuidString
        self.createdAt = Date()
        self.rawTranscript = rawTranscript
        self.finalText = finalText
        self.polishMode = polishMode
        self.durationMs = durationMs
        self.recordingMs = recordingMs
        self.appName = appName
        self.appBundleID = appBundleID
        self.language = language
    }
}
```
(`Codable` synthesis + `init(from:)` default behavior decodes missing keys to nil automatically for optionals — no custom decoder needed, since all new fields are optional. Verify old `history.json` still loads.)

- [ ] **Step 2: Language heuristic (pure, testable).** Add to `Core/DictationHistory.swift` (file scope):
```swift
/// Cheap per-session language tag from the final text: CJK-char ratio → "zh" / "en" / "mixed".
/// Works even when ASR language is "auto". Empty/whitespace → nil.
func detectLanguageTag(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    var cjk = 0, letters = 0
    for scalar in trimmed.unicodeScalars {
        if (0x4E00...0x9FFF).contains(scalar.value) || (0x3040...0x30FF).contains(scalar.value)
            || (0xAC00...0xD7AF).contains(scalar.value) { cjk += 1 }
        else if scalar.properties.isAlphabetic { letters += 1 }
    }
    let total = cjk + letters
    guard total > 0 else { return nil }
    let cjkRatio = Double(cjk) / Double(total)
    if cjkRatio > 0.8 { return "zh" }
    if cjkRatio < 0.2 { return "en" }
    return "mixed"
}
```

- [ ] **Step 3: `DailyStats` — add aggregates + the append fix.** In `Core/DailyStats.swift`, replace `DailyStats` struct with:
```swift
struct DailyStats: Codable, Identifiable {
    let date: String // "YYYY-MM-DD" (local)
    var totalDurationMs: UInt64
    var totalWordCount: Int
    var sessionCount: Int
    var totalRecordingMs: UInt64 = 0
    var byApp: [String: Int] = [:]
    var byLang: [String: Int] = [:]
    var hourHistogram: [Int] = Array(repeating: 0, count: 24)

    var id: String { date }
}
```
(All new fields have defaults → old `daily_stats.json` decodes them to defaults automatically.)

- [ ] **Step 4: Rewrite `DailyStatsStore.recordSession`** to aggregate the new dimensions (and ALWAYS aggregate chars/app/lang/hour even when duration is unknown):
```swift
    func recordSession(durationMs: UInt64, recordingMs: UInt64, charCount: Int,
                       app: String, language: String, hour: Int) {
        let date = Self.todayString
        let idx = stats.firstIndex(where: { $0.date == date })
        if let idx {
            stats[idx].totalDurationMs += durationMs
            stats[idx].totalRecordingMs += recordingMs
            stats[idx].totalWordCount += charCount
            stats[idx].sessionCount += 1
            stats[idx].byApp[app, default: 0] += charCount
            stats[idx].byLang[language, default: 0] += charCount
            if (0..<24).contains(hour) { stats[idx].hourHistogram[hour] += 1 }
        } else {
            var hist = Array(repeating: 0, count: 24)
            if (0..<24).contains(hour) { hist[hour] = 1 }
            stats.append(DailyStats(date: date, totalDurationMs: durationMs, totalWordCount: charCount,
                                    sessionCount: 1, totalRecordingMs: recordingMs,
                                    byApp: [app: charCount], byLang: [language: charCount], hourHistogram: hist))
        }
        if stats.count > 365 { stats.removeFirst(stats.count - 365) }
        scheduleSave()
    }
```
Keep the existing `totalDurationMs`/`totalWordCount`/`overallAverageSpeed`/`estimatedTimeSavedSeconds` computed props (still used by the existing top cards until Task 4 migrates them).

- [ ] **Step 5: `HistoryStore.append` — always aggregate.** In `Core/DictationHistory.swift`, replace the aggregation block in `append`:
```swift
    func append(_ session: DictationSession) {
        sessions.insert(session, at: 0)
        if sessions.count > maxEntries { sessions = Array(sessions.prefix(maxEntries)) }
        scheduleSave()

        // Always aggregate (sessions with no duration must still count toward chars/active-days/heatmap).
        let charCount = session.finalText.trimmingCharacters(in: .whitespacesAndNewlines).count
        let hour = Calendar.current.component(.hour, from: session.createdAt)
        DailyStatsStore.shared.recordSession(
            durationMs: session.durationMs ?? 0,
            recordingMs: session.recordingMs ?? 0,
            charCount: charCount,
            app: session.appName ?? "未知",
            language: session.language ?? "未知",
            hour: hour
        )
    }
```

- [ ] **Step 6: Self-tests** (`testStatsDataModel`, register after `testModelLocator`): old-JSON decode (a `DictationSession` JSON without the new keys → nil fields; a `DailyStats` JSON without new keys → default aggregates); `detectLanguageTag("你好世界")=="zh"`, `detectLanguageTag("hello world")=="en"`, `detectLanguageTag("hello 你好")=="mixed"`, `detectLanguageTag("  ")==nil`.

- [ ] **Step 7:** `swift build` green; `swift run FlowType --self-test` green; **Commit** `feat(stats): data model — recordingMs/app/language + day aggregates + always-aggregate`.

---

## Task 2: Capture — pure recording time + frontmost app + language

**Files:** Modify `Core/Pipeline/SessionContext.swift`, `Core/Pipeline/Stages/RecordingStage.swift`, `Core/PipelineOrchestrator.swift`.

- [ ] **Step 1: SessionContext — add `recordingMs`.** In `SessionContext.swift`, after `var recordingStartTime: Date?` add:
```swift
    /// Pure recording duration in ms (samples/16000), set by RecordingStage. The speed denominator.
    var recordingMs: UInt64?
```
(`targetApp: NSRunningApplication?` already exists — we'll finally assign it.)

- [ ] **Step 2: RecordingStage — set `recordingMs` on the normal end path.** In `RecordingStage.swift`, in the normal (non-cancelled) completion where `audioDuration` is computed and it `return .continue(.audio(...))`, set the context first:
```swift
            let rawSamples = audioRecorder.takeAccumulatedSamples()
            let audioDuration = Double(rawSamples.count) / 16000.0
            await MainActor.run { context.recordingMs = UInt64(audioDuration * 1000) }
            AppLogger.log("[RecordingStage#\(sessionID)] Raw samples: \(rawSamples.count) (\(String(format: "%.1f", audioDuration))s)")
            return .continue(.audio(samples: rawSamples, previewText: finalPreviewText))
```
(Only the normal path; the cancellation path discards the session.)

- [ ] **Step 3: Capture frontmost app at recording start.** In `PipelineOrchestrator.swift` `startRecording`, near the top (before `WindowManager.shared.showWindow()` and ideally before any UI change), assign the target app to the context:
```swift
        context.targetApp = NSWorkspace.shared.frontmostApplication
```
(The floating panel is a non-activating panel, so frontmost stays the user's app; capturing here is safe. `NSWorkspace` is available via the existing AppKit import.)

- [ ] **Step 4: saveHistory — plumb the new fields.** In `PipelineOrchestrator.swift` `saveHistory`, build the session with the new fields:
```swift
        let mode: PolishMode = context.usePolish ? .polish : .raw
        let session = DictationSession(
            rawTranscript: context.rawTranscript,
            finalText: context.finalText,
            polishMode: mode,
            durationMs: durationMs,
            recordingMs: context.recordingMs,
            appName: context.targetApp?.localizedName,
            appBundleID: context.targetApp?.bundleIdentifier,
            language: detectLanguageTag(context.finalText)
        )
        HistoryStore.shared.append(session)
```

- [ ] **Step 5:** `swift build` green; self-test green; **Commit** `feat(stats): capture pure recordingMs + frontmost app + language per session`.

---

## Task 3: StatsEngine (pure) + StatsSummary + self-tests

**Files:** Create `Core/StatsEngine.swift`; modify `Testing/SelfTest.swift`.

- [ ] **Step 1: Create `Core/StatsEngine.swift`.** A pure module over `[DailyStats]` with injected `now`/`calendar`. Key pieces (full code):
```swift
import Foundation

enum StatsRange: String, CaseIterable, Identifiable { case all, d30, d7; var id: String { rawValue }
    var displayName: String { switch self { case .all: return "All"; case .d30: return "30d"; case .d7: return "7d" } } }

struct StatsSummary: Equatable {
    var sessions = 0
    var chars = 0
    var recordingSeconds = 0
    var timeSavedSeconds = 0
    var avgSpeedCPM = 0
    var activeDays = 0
    var currentStreak = 0
    var longestStreak = 0
    var peakHour: Int?              // 0..23, nil if no data
    var hourHistogram = Array(repeating: 0, count: 24)
    var heatmap: [HeatCell] = []    // one per local day in range
    var isEmpty: Bool { sessions == 0 && chars == 0 }
}

struct HeatCell: Equatable { let dayOrdinal: Int; let date: String; let chars: Int; let level: Int }

enum StatsEngine {
    static let baselineCPM = 40

    /// Local-day ordinal (days since era), DST-safe.
    static func dayOrdinal(_ date: Date, _ cal: Calendar) -> Int {
        cal.ordinality(of: .day, in: .era, for: cal.startOfDay(for: date)) ?? 0
    }

    static func parseDate(_ s: String, _ cal: Calendar) -> Date? {
        let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    /// Filter daily stats into the range ending at `now`.
    static func filtered(_ stats: [DailyStats], range: StatsRange, now: Date, cal: Calendar) -> [DailyStats] {
        switch range {
        case .all: return stats
        case .d30, .d7:
            let days = range == .d30 ? 30 : 7
            let cutoff = dayOrdinal(now, cal) - (days - 1)
            return stats.filter { d in
                guard let date = parseDate(d.date, cal) else { return false }
                return dayOrdinal(date, cal) >= cutoff
            }
        }
    }

    static func summarize(_ all: [DailyStats], range: StatsRange, now: Date, cal: Calendar = .current) -> StatsSummary {
        let stats = filtered(all, range: range, now: now, cal: cal)
        var s = StatsSummary()
        s.sessions = stats.reduce(0) { $0 + $1.sessionCount }
        s.chars = stats.reduce(0) { $0 + $1.totalWordCount }
        let recMs = stats.reduce(UInt64(0)) { $0 + $1.totalRecordingMs }
        let durMs = stats.reduce(UInt64(0)) { $0 + $1.totalDurationMs }
        // Prefer pure recording; fall back to legacy duration only if no recording captured at all.
        let denomMs = recMs > 0 ? recMs : durMs
        s.recordingSeconds = Int(denomMs / 1000)
        let minutes = Double(denomMs) / 1000.0 / 60.0
        s.avgSpeedCPM = minutes > 0 ? Int(Double(s.chars) / minutes) : 0
        s.timeSavedSeconds = max(0, Int(Double(s.chars) / Double(baselineCPM) * 60.0) - s.recordingSeconds)

        // hour histogram + peak
        var hist = Array(repeating: 0, count: 24)
        for d in stats where d.hourHistogram.count == 24 { for h in 0..<24 { hist[h] += d.hourHistogram[h] } }
        s.hourHistogram = hist
        if let mx = hist.max(), mx > 0 { s.peakHour = hist.firstIndex(of: mx) }

        // active days + streaks (over the date set)
        let ordinals = Set(stats.filter { $0.sessionCount > 0 }.compactMap { parseDate($0.date, cal).map { dayOrdinal($0, cal) } })
        s.activeDays = ordinals.count
        s.longestStreak = longestRun(ordinals)
        s.currentStreak = currentRun(ordinals, todayOrdinal: dayOrdinal(now, cal))

        // heatmap cells (chars per day → 0..4 level)
        let maxChars = stats.map { $0.totalWordCount }.max() ?? 0
        s.heatmap = stats.compactMap { d in
            guard let date = parseDate(d.date, cal) else { return nil }
            return HeatCell(dayOrdinal: dayOrdinal(date, cal), date: d.date, chars: d.totalWordCount,
                            level: level(d.totalWordCount, max: maxChars))
        }.sorted { $0.dayOrdinal < $1.dayOrdinal }
        return s
    }

    static func level(_ chars: Int, max: Int) -> Int {
        guard chars > 0, max > 0 else { return 0 }
        let r = Double(chars) / Double(max)
        if r > 0.75 { return 4 }; if r > 0.5 { return 3 }; if r > 0.25 { return 2 }; return 1
    }

    static func longestRun(_ ordinals: Set<Int>) -> Int {
        guard !ordinals.isEmpty else { return 0 }
        var best = 1
        for o in ordinals where !ordinals.contains(o - 1) {   // run starts
            var len = 1; while ordinals.contains(o + len) { len += 1 }
            best = max(best, len)
        }
        return best
    }

    static func currentRun(_ ordinals: Set<Int>, todayOrdinal: Int) -> Int {
        // Streak counts back from today (or yesterday if today not yet active).
        var start = todayOrdinal
        if !ordinals.contains(start) { start -= 1 }
        guard ordinals.contains(start) else { return 0 }
        var len = 0; while ordinals.contains(start - len) { len += 1 }
        return len
    }
}
```

- [ ] **Step 2: Self-tests** (`testStatsEngine`, register after the Task-1 test). Assert with fixtures: speed regression (10 chars over 5s recording → `120` CPM via summarize on a single day with totalRecordingMs=5000, totalWordCount=10); timeSaved never negative; empty `[]` → `.isEmpty`, all zeros, no crash; `level(0, max: 100)==0`, `level(100, max: 100)==4`; `longestRun([1,2,3,5,6])==3`; `currentRun([10,9,8], todayOrdinal: 10)==3` and `currentRun([9,8], todayOrdinal: 10)==2` (yesterday-anchored) and `currentRun([5], todayOrdinal: 10)==0`; range filter keeps only recent days.

- [ ] **Step 3:** self-test green; **Commit** `feat(stats): pure StatsEngine (metrics, streaks, heatmap) + self-tests`.

---

## Task 4: UI — stats panel in OverviewPage

**Files:** Create `Settings/Overview/StatsPanel.swift` (+ `ActivityHeatmap.swift`, split as sensible); modify `Settings/OverviewPage.swift`.

Read `OverviewPage.swift` first. Mount the panel below the existing top cards (inside the `ScrollView`/`VStack`), passing `DailyStatsStore.shared.stats`.

- [ ] **Step 1: `StatsPanel`** — `@State var range: StatsRange = .d30`; compute `let s = StatsEngine.summarize(store.stats, range: range, now: Date())`. Layout (Frost dark, flat `.glassCard`, `.monospacedDigit()`, `Brand.accent`):
  - Header: tabs `概览`(active) · `应用`/`语言`(disabled, "v2") · a trailing `Picker(range, .segmented)` All/30d/7d.
  - 8-card grid via `LazyVGrid(columns: 4→2 adaptive)`: 口述次数 `s.sessions` · 口述字数 `s.chars`(千分位) · 总口述时间 `format(s.recordingSeconds)` · 节省时间 `format(s.timeSavedSeconds)` · 活跃天数 `s.activeDays` · 当前连续 `s.currentStreak` · 最长连续 `s.longestStreak` · 平均速度 `s.avgSpeedCPM 字/分`. Reuse `StatValueView`/the existing card style; compact time format `1h23m`; 千分位 via `NumberFormatter`.
  - `ActivityHeatmap(cells: s.heatmap)` — custom `LazyHGrid`/columns of 7 `RoundedRectangle(cornerRadius: 2.5)`, 5-level purple by `cell.level` (`Brand.accent` opacity scale), `.help()`/`.onHover` tooltip showing date·chars, `.accessibilityLabel`. Empty → all level-0 cells + centered "开始你的第一次听写，这里会亮起来".
  - 24h distribution: 24 bars from `s.hourHistogram`, peak hour (`s.peakHour`) in `Brand.accent`.
  - Footer: one line from a small template list using cumulative numbers (键盘次数≈chars, 电影≈timeSaved/6300s, 书≈chars/730000); **hide the whole line if all derived values round to 0**.
  - Empty state (`s.isEmpty`): cards show `0`/`—`, heatmap empty + guide text, no charts crash.

- [ ] **Step 2:** `swift build` green; self-test green; **Commit** `feat(stats): Overview stats panel — cards, heatmap, 24h, range switch, footer`.

---

## Task 5: On-device verification (manual)

- [ ] Build `.app`, launch, open Overview. Verify: panel renders below existing cards (Frost dark, flat); All/30d/7d switches all metrics; **avg speed now realistic (not ~58)**; heatmap shows your activity with hover tooltips; 24h peak highlighted; streaks correct; footer reads naturally (or hidden when 0).
- [ ] Fresh/zero state (or temporarily rename `daily_stats.json`): no NaN/Infinity/broken charts; empty heatmap + guide text.
- [ ] Dictate once into an app → confirm a new session records `recordingMs`/app/language (check `history.json`) and the cards update; avg speed reflects pure recording time.
- [ ] Dark + light + narrow window OK. Record results in `docs/feature-inventory.md`; push.

---

## Self-Review
- Spec coverage: speed fix (T2 recordingMs + T3 denom) ✓; data model + backward-compat + append fix (T1) ✓; capture app/language (T2) ✓; metrics/streaks/peak/heatmap (T3) ✓; UI cards+heatmap+24h+range+footer+empty (T4) ✓; tests (T1/T3) ✓; no Swift Charts in v1 ✓.
- Placeholders: full code for T1–T3; T4 is a precise UI spec against the read file (judgment UI).
- Type consistency: `recordingMs`, `detectLanguageTag`, `DailyStats.{totalRecordingMs,byApp,byLang,hourHistogram}`, `recordSession(durationMs:recordingMs:charCount:app:language:hour:)`, `StatsEngine.summarize(_:range:now:cal:)`, `StatsSummary`, `HeatCell`, `StatsRange` — consistent across tasks.
