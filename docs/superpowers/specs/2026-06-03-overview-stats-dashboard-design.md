# Overview Stats Dashboard (v1) — Design Spec

**Date:** 2026-06-03
**Status:** Approved (owner sign-off 2026-06-03; v1 layout approved via visual companion)
**Source PRD:** owner-provided「概览页统计增强 PRD」(mapped onto FlowType's SwiftUI + JSON stack).

---

## 1. Goal & scope

Fill the empty lower half of the Overview page with a credible, production-grade stats panel, and **fix the avg-speed bug**. Decisions locked with owner:

- **v1 = everything buildable now from existing + cheap-new data**: the speed fix, an 8-card grid, a GitHub-style activity heatmap, streaks, peak hour + 24h distribution, All/30d/7d range switch, a fun-comparison footer. **Capture `appName` + `language` per session starting in v1** (so v2's tabs have real data), but the App/Language **tabs ship in v2**.
- **v2 (later):** App tab + Language tab (stacked bar + donut). **Deferred:** 一次成稿率/`edited` (needs a product definition + a post-injection monitor the architecture lacks).
- All numbers are **read-only**; metric definitions live in one backend module; no user-customization entry points.

## 2. The speed bug (highest-leverage fix)

`DictationSession.durationMs` today is **end-to-end wall clock** (`saveHistory()` = `now − recordingStartTime`, *after injection*), so it includes recording **+ transcription + polish + injection + await gaps**. Avg speed = `chars / (durationMs/60000)` divides by that inflated number → structurally low ("58 字/分"). 

**Fix:** capture **pure recording seconds** (already computed in `RecordingStage` as `samples.count / 16000`, currently logged and dropped), thread it through `SessionContext` → save as a new `recordingMs`, and compute speed/total-time/time-saved from `recordingMs`. **One change corrects three metrics.** Historical rows (no `recordingMs`) fall back to the legacy `durationMs` denominator — reads slightly low but never blank; no destructive rebuild of `daily_stats.json`.

## 3. Metric definitions (§2 of PRD — fixed, in `StatsEngine`)

- **char_count** = `finalText.trimmingCharacters(in: .whitespacesAndNewlines).count` (CJK/letters/digits/punct all = 1 char).
- **recordingSeconds** = `recordingMs ?? durationMs` (legacy fallback) / 1000.
- **avgSpeed (字/分)** = `totalChars / (totalRecordingSeconds/60)`, **0 when denominator 0** (no NaN/Inf).
- **BASELINE_CPM = 40** (constant; not exposed).
- **timeSaved (s)** = `max(0, totalChars/40*60 − totalRecordingSeconds)`.
- **activeDays** = count of local days with ≥1 session in range.
- **currentStreak / longestStreak** = consecutive local-midnight active days (current = ending today; longest = max run). Within the selected range for 7d/30d; full history for All.
- **peakHour** = mode of session start-hour (local tz) from the per-day `hourHistogram`.
- **Day boundary = local midnight** via `Calendar.current` + `ordinality(of:.day, in:.era)` on `startOfDay` — NOT `timestamp/86400` (avoids UTC/DST ±1 drift).

## 4. Data model changes (backward-compatible; old files decode to defaults)

**`DictationSession`** (`Core/DictationHistory.swift`) — add optional fields (`decodeIfPresent` → nil):
- `recordingMs: UInt64?` — pure recording (the speed fix).
- `appName: String?`, `appBundleID: String?` — frontmost app captured **at recording start** (before the panel can steal focus).
- `language: String?` — CJK-ratio heuristic on `finalText` (`"zh"`/`"en"`/`"mixed"`); works even in auto mode.

**`DailyStats`** (`Core/DailyStats.swift`) — add defaulted aggregates (`decodeIfPresent ?? default`):
- `totalRecordingMs: UInt64 = 0`
- `byApp: [String: Int] = [:]`, `byLang: [String: Int] = [:]` (char counts per app/lang — for v2)
- `hourHistogram: [Int] = Array(repeating: 0, count: 24)` (session-start counts; powers peak-hour + 24h, from the 365-day file, not the 500-session cap)

**Two bugs to fix while here:**
1. `HistoryStore.append` currently **skips all aggregation when `durationMs == nil`** → such sessions vanish from stats. Change to **always** aggregate chars/app/lang/hour/sessionCount; only the time fields stay 0 when duration is unknown.
2. Replace any `timestamp/86400` day math with the `Calendar` local-midnight approach above.

**Backfill:** historical app/language = bucket **「未知」**; not recoverable. Everything else (heatmap, cards, streaks, peak hour) derives fine from `createdAt` + `finalText` + existing totals.

## 5. Capture (write path)

- **recordingMs:** `RecordingStage` already has `audioDuration = samples.count/16000`; put it on `SessionContext` (e.g. `recordingMs`) and include it in the saved `DictationSession`.
- **appName/appBundleID:** capture `NSWorkspace.shared.frontmostApplication` (localizedName + bundleIdentifier) **at recording start** (`SessionController.startRecording`), store on `SessionContext` (wire the dead `targetApp` stub), save onto the session.
- **language:** compute the CJK-ratio heuristic on the final text at save time.

## 6. Logic home: `StatsEngine` (pure, testable)

New `Core/StatsEngine.swift` — an `enum` of static pure functions over value types with injected `now: Date` + `calendar: Calendar`, returning a `StatsSummary` struct. Consumes `[DailyStats]` (+ `[DictationSession]` only if needed). Mirrors `StatFormatting`/`SpectrumMath`. Functions: `filter(range:)`, `totals`, `avgSpeed`, `timeSaved`, `activeDays`, `streaks`, `peakHour`, `heatmapCells(range:)`, `hourBuckets`. All div-zero→0, all empty→sensible zero. **Self-tested** via the in-target `--self-test` harness (no XCTest): known fixtures for speed (incl. the bug-regression: chars+recording→expected字/分), streaks across midnight/DST, time-saved never-negative, empty→all-zero-no-NaN.

## 7. UI (Overview lower half) — approved layout

Below the existing top cards, a new stats panel (Frost dark, flat cards, accent `Brand.accent`, `.monospacedDigit()`):

1. **Header bar:** tabs `概览` (active) · `应用`/`语言` (disabled "v2" until built) on the left; **range segmented control** `All / 30d / 7d` (default **30d**) on the right. Changing range refreshes everything.
2. **8-card grid (4×2):** 口述次数 · 口述字数 · 总口述时间 · 节省时间 · 活跃天数 · 当前连续 · 最长连续 · 平均速度. Each = small icon + big tabular number (千分位; compact units `1h23m`, `12,345`, `1.2M`) + caption. Reuse the existing card/`StatValueView` styling.
3. **Activity heatmap:** custom SwiftUI `RoundedRectangle` grid (52w×7d for All; 30/7 cells for 30d/7d, 7d may be one row), 5-level purple intensity by daily chars, weekday/month labels, horizontal scroll on narrow widths. Hover/click → date · chars · time · sessions. Each cell `accessibilityLabel`.
4. **24-hour distribution:** a 24-bar mini chart (custom or `BarMark` over fixed `0...23`), peak hour highlighted in accent.
5. **Footer:** one light line, randomly chosen from fun-comparison templates computed from cumulative data (键盘次数、电影、书）; **hidden entirely when the number rounds to 0** (no "0 本书"). Constants (红楼梦≈730k字, etc.) live in one place.

Narrow window: 4-col grid → 2-col; heatmap scrolls.

## 8. Empty / edge cases (PRD §11/§14 — production-grade)

- All-zero/new install: cards show `0`/`—` (never blank/NaN); heatmap all-empty cells + centered "开始你的第一次听写，这里会亮起来"; no broken charts.
- 1 day / 1 session: nothing crashes; streak = 1; single bar centered.
- Div-zero: speed/percent/timeSaved → 0, never `Infinity`/`NaN`.
- Extremes: compact units so cards don't overflow.
- Dark + light: colors/heat gradient defined per appearance (asset-catalog dynamic or `Color(light:dark:)`).
- Accessibility: `aria`-equiv `accessibilityLabel` on heat cells; `accessibilityReduceMotion` gates any entrance animation.

## 9. Files

- **New:** `Core/StatsEngine.swift` (pure + summary types), `Settings/Overview/StatsPanel.swift` (the panel), `Settings/Overview/ActivityHeatmap.swift`, `Settings/Overview/StatCardGrid.swift` (+ hour bars + footer, split as sensible).
- **Modify:** `Core/DictationHistory.swift` (+fields, append aggregation fix), `Core/DailyStats.swift` (+aggregates), `Core/Pipeline/SessionContext.swift` (recordingMs/app fields), `Core/Pipeline/Stages/RecordingStage.swift` (set recordingMs), `Core/PipelineOrchestrator.swift` (`startRecording` app capture; `saveHistory` plumb new fields), `Settings/OverviewPage.swift` (mount the panel below the top cards), `Testing/SelfTest.swift` (StatsEngine tests).
- Charts: v1 needs **no Swift Charts** (heatmap + hour bars are custom SwiftUI). Swift Charts enters in v2 (stacked bar + donut).

## 10. Non-goals (v1)

- No export / multi-user / server leaderboard.
- No App/Language **tabs** (capture only); no `edited`/一次成稿率.
- No destructive rebuild of historical `daily_stats.json`.

---

## 11. v2 (deferred — design, not built in this plan)

v2 surfaces the dimensions whose **capture already starts in v1** (`appName`, `language`, `DailyStats.byApp/byLang`), so by the time v2 ships there is real (non-未知) data. v2 is purely additive UI + Swift Charts over data the write-path already records.

**11.1 App tab (the high-value downroll — "你都在哪些应用里口述")**
- Aggregate `byApp` over the selected range → a **ranking list**: app name (localized) + chars + time + share %, sorted desc, **top-N (e.g. 6) + 「其他」** rolled up.
- A **stacked bar chart** of chars-per-day segmented by app: Swift Charts `BarMark(x: date, y: chars) .foregroundStyle(by: .value("App", app))` with an explicit color `domain` for stable ordering; pre-aggregate top-N+其他 in the view-model.
- **Custom legend** (Swift Charts' built-in can't show value/%): rows of `■ name — 12,345 字 · 32%`, colors from one shared `[String: Color]` brand map.
- Historical sessions (pre-capture) appear as **「未知」**; the bucket shrinks as new data accrues.

**11.2 Language tab**
- `byLang` (`zh`/`en`/`mixed`/未知) over range → list + a **donut** (`SectorMark(innerRadius: .ratio(0.6), angularInset: 1.5)`, macOS 14+, center label via `.chartBackground`), tiny slices collapsed to 其他.
- Same custom legend (name + chars + %).

**11.3 Charts infrastructure (v2 introduces Swift Charts)**
- Shared `[String: Color]` category→brand-color map; dynamic (light/dark) colors; `.chartLegend(.hidden)` + custom legends throughout.
- Empty/single-point branching in the view-model; `domain`-stable axes; `accessibilityLabel` on marks; gate animation on `accessibilityReduceMotion`.

**11.4 Optional enhancements (PRD §10 — pick by value, future)**
- **Speed trend line** (`LineMark` + `PointMark` fallback at N=1) — "我越用越快了吗".
- **Week rhythm** (Mon–Sun 7-cell strip, reuse heatmap cells) + the v1 24h bars already cover the daily rhythm.
- **Milestones/成就** (10万字, 连续7天, 单日新高) with a reduced-motion-respecting micro-animation.
- **个性化进度环联动**: tie the top progress ring to learned-vocab/correction counts so it actually rises.
- **一次成稿率 (`edited`)** — still deferred; needs a "what counts as edited" product definition + a post-injection monitor (AX value-watch or clipboard diff) the architecture doesn't have. Out of v2 unless that's specced first.

**11.5 v2 data note:** no new schema beyond v1 (it already records `byApp`/`byLang`). v2 = view-models + Swift Charts views + the two tabs wired into the existing header tab control (un-greying 应用/语言).
