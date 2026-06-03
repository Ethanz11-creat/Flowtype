# Overview PRD — Step 2: Component Rebuild (§3–§10 + Milestone System) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`).
> **SCOPE:** PRD §3 (IA) · §4 (Hero 2×2) · §5 (achievements) · §6 (milestone system) · §7 (sidebar settings bottom-left) · §8 (heatmap tooltip/colors) · §9 (24h peak) · §10 (footer), applying §11 metric口径 (already correct in `StatsEngine` — uses `totalRecordingMs`). **DEFERRED to their own later stages:** §11 *settings-editable* `baselineTypingCPM` (numbers are already correct), and §12 JSON→SQLite migration. Do NOT touch those.

**Goal:** Rebuild the Overview page in SwiftUI to 1:1 match `docs/files/overview-prototype.html` — control bar → Hero (personalization ring + 2×2 data) → achievements (3 warm cards) → streak milestone system → activity heatmap → 24h distribution → footer — on top of the already-accepted §1 layout (fixed-width-centered 780) + §2 solid-dark theme.

**Architecture:** Pure data/format helpers go in `Core` (`StatsConfig` constants, `StatsEngine` milestone/month helpers — Foundation only, self-tested). Colors as hex `UInt` in `StatsConfig`, mapped to `Color` via the existing `Color(hex:)` in views. Each visual section is its own focused SwiftUI file under `Settings/Overview/`. `OverviewPage` owns the `@State range` and composes the sections inside the existing cap-then-center frames. Range (`All/30d/7d`) governs every number except the heatmap (always last 365 days per §8).

**Tech Stack:** SwiftUI, Swift Charts (system), AppKit colors via `Color(hex:)`. No third-party libs.

**Visual source of truth:** `docs/files/overview-prototype.html` inline styles. Key tokens already in `Theme`: page `#0C0C0F`, card `#17171C` radius 12, border white .07, text `#F2F2F5`/sec `#8A8A92`, accent `#8E7DF5`(`Theme.accent`)/bright `#A99BFF`(`Theme.accentBright`)/text `#B9AEFF`(`Theme.accentText`), warm `#FFB454`(`Theme.warm`), heatEmpty `#1C1C22`.

**Verify each task:** `swift build` → "Build complete!"; `set -o pipefail && swift run FlowType --self-test` → "NNN passed, 0 failed" (≥118, never a regression). SourceKit "Cannot find X in scope" diagnostics are STALE — trust `swift build`.

---

## File Structure

- **Modify** `Core/StatsConfig.swift` — milestones array, tier hex map, start hex; re-align `heatOpacity` to PRD §8.
- **Modify** `Core/StatsEngine.swift` — pure milestone helpers (`flameTier/nextMilestone/milestoneProgress`) + month helpers (`activeDaysInMonth/longestStreakEndMonth`).
- **Modify** `UI/Theme/StatValue.swift` — `duration` → `h/m` (minutes `%02d` when hours present); speed unit gets a leading space; `StatValueView` gains `numberColor`/`numberWeight` and uses `Theme` tokens.
- **Modify** `Testing/SelfTest.swift` — update 4 `StatFormatting` asserts (h/m + speed space); add milestone-helper asserts.
- **Create** `Settings/Overview/RangeSegmented.swift` — prototype-pill `All/30d/7d` control + `OverviewControlBar` (tabs + range).
- **Create** `Settings/Overview/HeroSection.swift` — `PersonalizationCard` (ring) + `StatGrid2x2` + `StatCell`.
- **Create** `Settings/Overview/AchievementsSection.swift` — `AchievementsSection` (3 warm cards incl. `StreakMilestoneCard`) + `MilestoneTrack`.
- **Modify** `Settings/Overview/StatsPanel.swift` — strip everything except `ActivityHeatmap` + `HourDistributionChart`; refine both to prototype (heatmap base → `Theme.accent`, opacities per §8; 24h peak uses `summary.peakHour`).
- **Modify** `Settings/OverviewPage.swift` — own `@State range`; compose the new sections in cap-then-center; move footer here; drop old `accuracyCard/mainStatsGrid/statCard`.
- **Modify** `Settings/MainWindowView.swift` — sidebar: nav = 概览/历史/词典/风格; 设置 pinned bottom-left with a top divider (§7).

---

## Task 1: `StatsConfig` — milestone + heatmap constants

**Files:** Modify `Core/StatsConfig.swift`.

- [ ] **Step 1:** Inside `enum StatsConfig`, replace the `heatOpacity` line and add milestone constants. Current `heatOpacity` is `[0.25, 0.45, 0.65, 0.85, 1.0]`; PRD §8 wants level 1–4 opacities `0.35/0.6/0.85/1.0` (level 0 is the empty color, index unused). Add after the existing `heatOpacity`:
```swift
    // Heatmap: index by level (0 = empty → uses Theme.heatEmpty, so [0] is a placeholder).
    // PRD §8: levels 1…4 = #8E7DF5 at 0.35 / 0.6 / 0.85 / 1.0.
    static let heatOpacity: [Double] = [0, 0.35, 0.6, 0.85, 1.0]

    // Streak milestones (days) + per-tier flame colors (PRD §6). Colors are 0xRRGGBB; views map via Color(hex:).
    static let milestones: [Int] = [3, 7, 14, 30, 60, 100, 365]
    static let milestoneStartHex: UInt = 0xFFB454            // flame color while streak < first milestone
    static let milestoneTierHex: [Int: UInt] = [
        3: 0xFFB454, 7: 0xFF8A3D, 14: 0xFF6B35, 30: 0xFF4D4D,
        60: 0xE0479E, 100: 0xA99BFF, 365: 0xFFD24D,
    ]
```
(Delete the old single-line `static let heatOpacity: [Double] = [0.25, 0.45, 0.65, 0.85, 1.0]`.)

- [ ] **Step 2:** `swift build` → Build complete!; `swift run FlowType --self-test` → still ≥118/0.

- [ ] **Step 3: Commit**
```bash
git add Sources/flowtype/Core/StatsConfig.swift
git commit -m "feat(stats): milestone tiers + heatmap opacities per prototype (§6,§8)"
```

---

## Task 2: `StatsEngine` — pure milestone + month helpers (TDD)

**Files:** Modify `Core/StatsEngine.swift`, `Testing/SelfTest.swift`.

- [ ] **Step 1: Write failing self-tests.** In `Testing/SelfTest.swift`, at the end of `testStatFormatting` (it already lives in the suite at line ~423; OK to append milestone asserts there, or add a new `testMilestones(_:)` and call it from the same place `testStatFormatting` is called, line ~242). Append these asserts (they will fail to compile → that's the failing state):
```swift
        // Milestone system (PRD §6) — pure
        r.eq(StatsEngine.flameTier(6), 3, "ms: tier(6)=3")
        r.eq(StatsEngine.flameTier(2), 0, "ms: tier(2)=0 (<3)")
        r.eq(StatsEngine.flameTier(365), 365, "ms: tier(365)=365")
        r.eq(StatsEngine.nextMilestone(6), 7, "ms: next(6)=7")
        r.check(StatsEngine.nextMilestone(365) == nil, "ms: next(365)=nil")
        r.eq(StatsEngine.milestoneProgress(6), 0.75, "ms: progress(6)=.75")
        r.eq(StatsEngine.milestoneProgress(3), 0.0, "ms: progress(3)=0 at anchor")
        r.eq(StatsEngine.milestoneProgress(400), 1.0, "ms: progress(>max)=1")
```

- [ ] **Step 2: Run, verify it fails to build** (`flameTier`/`nextMilestone`/`milestoneProgress` undefined):
```bash
swift build 2>&1 | tail -3
```
Expected: error "cannot find 'StatsEngine.flameTier'" (or similar). Good.

- [ ] **Step 3: Implement helpers.** In `Core/StatsEngine.swift`, inside `enum StatsEngine` (after `currentRun`), add:
```swift
    // MARK: Milestones (PRD §6) — pure

    /// Highest reached milestone day; 0 when streak < first milestone.
    static func flameTier(_ streak: Int) -> Int {
        StatsConfig.milestones.last(where: { streak >= $0 }) ?? 0
    }

    /// Next milestone strictly above streak; nil once the top milestone is reached.
    static func nextMilestone(_ streak: Int) -> Int? {
        StatsConfig.milestones.first(where: { $0 > streak })
    }

    /// Fraction [0,1] from the last reached anchor toward the next milestone.
    static func milestoneProgress(_ streak: Int) -> Double {
        guard let next = nextMilestone(streak) else { return 1 }
        let prev = flameTier(streak)
        let span = Double(next - prev)
        guard span > 0 else { return 1 }
        return min(1, max(0, Double(streak - prev) / span))
    }

    /// Active days (sessionCount>0) within the calendar month containing `now`.
    static func activeDaysInMonth(_ all: [DailyStats], now: Date, cal: Calendar) -> Int {
        let m = cal.dateComponents([.year, .month], from: now)
        return all.filter { $0.sessionCount > 0 }.filter { d in
            guard let date = parseDate(d.date, cal) else { return false }
            let dc = cal.dateComponents([.year, .month], from: date)
            return dc.year == m.year && dc.month == m.month
        }.count
    }

    /// Calendar month (1…12) in which the longest streak ends; nil when there is no streak.
    static func longestStreakEndMonth(_ all: [DailyStats], now: Date, cal: Calendar) -> Int? {
        let ordinals = Set(all.filter { $0.sessionCount > 0 }
            .compactMap { parseDate($0.date, cal).map { dayOrdinal($0, cal) } })
        guard !ordinals.isEmpty else { return nil }
        var best = 0, bestEnd = ordinals.max()!
        for o in ordinals where !ordinals.contains(o - 1) {
            var len = 1; while ordinals.contains(o + len) { len += 1 }
            if len >= best { best = len; bestEnd = o + len - 1 }
        }
        let todayOrd = dayOrdinal(now, cal)
        guard let endDate = cal.date(byAdding: .day, value: bestEnd - todayOrd, to: cal.startOfDay(for: now)) else { return nil }
        return cal.component(.month, from: endDate)
    }
```

- [ ] **Step 4: Run self-test, verify pass:** `set -o pipefail && swift run FlowType --self-test 2>&1 | tail -1` → "NNN passed, 0 failed" (now 8 more than before).

- [ ] **Step 5: Commit**
```bash
git add Sources/flowtype/Core/StatsEngine.swift Sources/flowtype/Testing/SelfTest.swift
git commit -m "feat(stats): pure milestone + month helpers with self-tests (§5,§6)"
```

---

## Task 3: `StatValue` — h/m units + accent number color

**Files:** Modify `UI/Theme/StatValue.swift`, `Testing/SelfTest.swift`.

- [ ] **Step 1: Update the 4 existing `StatFormatting` self-tests** in `Testing/SelfTest.swift` (lines ~424–438) to the new h/m + spaced-speed expectations:
```swift
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
```

- [ ] **Step 2: Run, verify it fails** (old impl returns 小时/分钟): `swift run FlowType --self-test 2>&1 | grep -E "FAIL|failed" | head`.

- [ ] **Step 3: Update `StatFormatting`** in `UI/Theme/StatValue.swift` — replace `duration` and `speed`:
```swift
    /// Whole seconds → big-number/small-unit h/m segments (prototype: "3h08m"; minutes zero-padded when hours present).
    static func duration(seconds: Int) -> [StatSegment] {
        let s = max(0, seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        if h > 0 {
            return [StatSegment(number: "\(h)", unit: "h"),
                    StatSegment(number: String(format: "%02d", m), unit: "m")]
        }
        return [StatSegment(number: "\(m)", unit: "m")]
    }

    static func speed(_ wpm: Int) -> [StatSegment] {
        [StatSegment(number: "\(max(0, wpm))", unit: " 字/分")]   // leading space → "142 字/分"
    }
```

- [ ] **Step 4: Upgrade `StatValueView`** to support an accent number color, configurable weight, and Theme tokens; render with zero inter-segment spacing (so "3"+"h" is tight). Replace the struct body:
```swift
struct StatValueView: View {
    let segments: [StatSegment]
    var numberSize: CGFloat = 22
    var unitSize: CGFloat = 11
    var numberWeight: Font.Weight = .semibold     // prototype .d = 600
    var numberColor: Color = Theme.textPrimary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                Text(seg.number)
                    .font(.system(size: numberSize, weight: numberWeight))
                    .monospacedDigit()
                    .foregroundColor(numberColor)
                if let unit = seg.unit {
                    Text(unit)
                        .font(.system(size: unitSize, weight: .regular))
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}
```

- [ ] **Step 5: Run self-test, verify pass** (≥126/0). `swift build` will still show OverviewPage using the old `statCard`/`StatValueView(segments:)` — that's fine, the call site `StatValueView(segments:)` still compiles (new params have defaults). Build must stay green.

- [ ] **Step 6: Commit**
```bash
git add Sources/flowtype/UI/Theme/StatValue.swift Sources/flowtype/Testing/SelfTest.swift
git commit -m "feat(ui): StatFormatting h/m units + accent number color (§4)"
```

---

## Task 4: `RangeSegmented` + `OverviewControlBar` (§3.1)

**Files:** Create `Settings/Overview/RangeSegmented.swift`.

- [ ] **Step 1: Create the file.** A prototype-pill segmented control (container `#17171C` border white .08 radius 9 padding 2; active span `Theme.accent` bg, `#0C0C0F` text, semibold; inactive `Theme.textSecondary`), plus the control bar (tabs 概览/应用/语言 + the segmented control). The two v2 tabs are muted and non-interactive.
```swift
import SwiftUI

/// Prototype `.seg` pill — All / 30d / 7d. Active span = solid accent with near-black text.
struct RangeSegmented: View {
    @Binding var range: StatsRange

    var body: some View {
        HStack(spacing: 2) {
            ForEach(StatsRange.allCases) { r in
                let active = r == range
                Text(r.displayName)
                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                    .foregroundColor(active ? Color(hex: 0x0C0C0F) : Theme.textSecondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(active ? Theme.accent : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { range = r }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        )
    }
}

/// §3.1 control bar: 概览 (active) / 应用 / 语言 (v2, muted) on the left, range on the right.
struct OverviewControlBar: View {
    @Binding var range: StatsRange

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 18) {
                Text("概览").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.accentText)
                Text("应用").font(.system(size: 14)).foregroundColor(Theme.textSecondary.opacity(0.7))
                Text("语言").font(.system(size: 14)).foregroundColor(Theme.textSecondary.opacity(0.7))
            }
            Spacer()
            RangeSegmented(range: $range)
        }
    }
}
```

- [ ] **Step 2:** `swift build` → Build complete! (file compiles standalone; not yet wired). Self-test ≥126/0.

- [ ] **Step 3: Commit**
```bash
git add Sources/flowtype/Settings/Overview/RangeSegmented.swift
git commit -m "feat(ui): prototype range-segmented control + overview control bar (§3.1)"
```

---

## Task 5: `HeroSection` — personalization ring + 2×2 data (§3.2, §4)

**Files:** Create `Settings/Overview/HeroSection.swift`.

- [ ] **Step 1: Create the file.** Hero row = fixed-width personalization card (188pt) + flexible 2×2 grid, equal height. The 2×2 cells use `StatValueView` (27pt number / 15pt unit). 节省时间 number is `Theme.accentText` with `Theme.accentBright` hourglass; the rest use secondary-gray icons. Personalization progress = enabled dictionary entries / total (carried over from the old `OverviewPage.accuracyProgress`).
```swift
import SwiftUI

struct HeroSection: View {
    let summary: StatsSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PersonalizationCard()
                .frame(width: 188)
                .frame(maxHeight: .infinity)
            StatGrid2x2(s: summary)
        }
        .fixedSize(horizontal: false, vertical: true)   // row height = taller child (the 2×2 grid)
    }
}

private struct PersonalizationCard: View {
    @ObservedObject private var dictionaryStore = DictionaryStore.shared

    private var progress: Double {
        let total = dictionaryStore.entries.count
        guard total > 0 else { return 0 }
        return Double(dictionaryStore.entries.filter(\.enabled).count) / Double(total)
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.10), lineWidth: 6)
                    .frame(width: 72, height: 72)
                Circle().trim(from: 0, to: progress)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 72, height: 72)
                    .rotationEffect(.degrees(-90))
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                    .foregroundColor(Theme.textPrimary)
            }
            VStack(spacing: 4) {
                Text("个性化进度").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.textPrimary)
                Text("继续口述，让转写更贴合你")
                    .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center).lineSpacing(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(14)
        .glassCard()
    }
}

private struct StatGrid2x2: View {
    let s: StatsSummary

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                StatCell(icon: "hourglass", iconColor: Theme.accentBright,
                         segments: StatFormatting.duration(seconds: s.timeSavedSeconds),
                         numberColor: Theme.accentText, label: "节省时间")
                StatCell(icon: "text.alignleft", iconColor: Theme.textSecondary,
                         segments: StatFormatting.plain(StatCell.thousands(s.chars)),
                         numberColor: Theme.textPrimary, label: "口述字数")
            }
            GridRow {
                StatCell(icon: "clock", iconColor: Theme.textSecondary,
                         segments: StatFormatting.duration(seconds: s.recordingSeconds),
                         numberColor: Theme.textPrimary, label: "总口述时间")
                StatCell(icon: "bolt", iconColor: Theme.textSecondary,
                         segments: StatFormatting.speed(s.avgSpeedCPM),
                         numberColor: Theme.textPrimary, label: "平均速度")
            }
        }
    }
}

private struct StatCell: View {
    let icon: String
    let iconColor: Color
    let segments: [StatSegment]
    let numberColor: Color
    let label: String

    static func thousands(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon).font(.system(size: 16)).foregroundColor(iconColor)
            StatValueView(segments: segments, numberSize: 27, unitSize: 15, numberColor: numberColor)
            Text(label).font(.system(size: 12)).foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 15).padding(.vertical, 14)
        .glassCard()
    }
}
```
Note: SF Symbol `text.alignleft` is the closest to the prototype's `align-left`. Keep `hourglass`, `clock`, `bolt` as-is.

- [ ] **Step 2:** `swift build` → Build complete!. Self-test ≥126/0.

- [ ] **Step 3: Commit**
```bash
git add Sources/flowtype/Settings/Overview/HeroSection.swift
git commit -m "feat(ui): Hero — personalization ring + 2×2 data, big-number/small-unit (§3.2,§4)"
```

---

## Task 6: `AchievementsSection` + milestone card + track (§5, §6)

**Files:** Create `Settings/Overview/AchievementsSection.swift`.

- [ ] **Step 1: Create the file.** Section title "成就" + 3 equal-height warm cards: 活跃天数 (calendar `Theme.warm`), 当前连续 (flame colored by tier + progress bar + caption), 最长连续 (trophy `Theme.warm`). Below them, a slim `MilestoneTrack` (§6 overview row). Flame breathes unless Reduce Motion. Tier color via `Color(hex:)` from `StatsConfig`.
```swift
import SwiftUI

struct AchievementsSection: View {
    let summary: StatsSummary
    @ObservedObject private var store = DailyStatsStore.shared

    private func tierColor(_ day: Int) -> Color {
        Color(hex: StatsConfig.milestoneTierHex[day] ?? StatsConfig.milestoneStartHex)
    }

    var body: some View {
        let streak = summary.currentStreak
        let flameDay = StatsEngine.flameTier(streak)
        let flameColor = flameDay == 0 ? Color(hex: StatsConfig.milestoneStartHex) : tierColor(flameDay)
        let next = StatsEngine.nextMilestone(streak)
        let monthActive = StatsEngine.activeDaysInMonth(store.stats, now: Date(), cal: .current)
        let bestMonth = StatsEngine.longestStreakEndMonth(store.stats, now: Date(), cal: .current)

        VStack(alignment: .leading, spacing: 9) {
            Text("成就").font(.system(size: 13, weight: .medium)).foregroundColor(Theme.textSecondary)
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    AchievementCard {
                        Image(systemName: "calendar").font(.system(size: 16)).foregroundColor(Theme.warm)
                        bigNumber("\(summary.activeDays)")
                        label("活跃天数")
                        sub("本月共 \(monthActive) 天")
                    }
                    StreakMilestoneCard(streak: streak, flameColor: flameColor,
                                        nextDay: next, progress: StatsEngine.milestoneProgress(streak),
                                        nextColor: next.map(tierColor) ?? Theme.warm)
                    AchievementCard {
                        Image(systemName: "trophy").font(.system(size: 16)).foregroundColor(Theme.warm)
                        bigNumber("\(summary.longestStreak)")
                        label("最长连续")
                        sub(bestMonth.map { "个人最佳 · \($0) 月" } ?? "个人最佳")
                    }
                }
            }
            MilestoneTrack(streak: streak)
        }
    }

    private func bigNumber(_ s: String) -> some View {
        Text(s).font(.system(size: 27, weight: .semibold)).monospacedDigit()
            .foregroundColor(Theme.textPrimary).padding(.top, 8)
    }
    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundColor(Theme.textSecondary).padding(.top, 7)
    }
    private func sub(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundColor(Color(hex: 0x7C7C84)).padding(.top, 7)
    }
}

/// Generic warm achievement card; children are leading-aligned, card stretches to row height.
private struct AchievementCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content; Spacer(minLength: 0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 15).padding(.vertical, 14)
            .glassCard()
    }
}

/// 当前连续 card — flame (tier color, breathing) + streak, progress to next milestone, caption.
private struct StreakMilestoneCard: View {
    let streak: Int
    let flameColor: Color
    let nextDay: Int?
    let progress: Double
    let nextColor: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 18)).foregroundColor(flameColor)
                    .scaleEffect(pulse ? 1.10 : 1.0).opacity(pulse ? 0.82 : 1.0)
                    .shadow(color: flameColor.opacity(pulse ? 0.8 : 0.4), radius: pulse ? 7 : 3)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(streak)").font(.system(size: 27, weight: .semibold)).monospacedDigit()
                        .foregroundColor(Theme.textPrimary)
                    Text(" 天").font(.system(size: 15)).foregroundColor(Theme.textSecondary)
                }
            }
            Text("当前连续").font(.system(size: 12)).foregroundColor(Theme.textSecondary).padding(.top, 8)
            // progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(nextColor).frame(width: max(0, geo.size.width * progress))
                }
            }
            .frame(height: 5).padding(.top, 11)
            // caption
            HStack(spacing: 4) {
                Image(systemName: "flame.fill").font(.system(size: 11)).foregroundColor(flameColor)
                if let next = nextDay {
                    Text("还差 \(next - streak) 天解锁 \(next) 天里程碑")
                } else {
                    Text("已达成最高里程碑 🎉")
                }
            }
            .font(.system(size: 11)).foregroundColor(Color(hex: 0x7C7C84)).padding(.top, 7)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 15).padding(.vertical, 14)
        .glassCard()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// §6 milestone overview: all 7 nodes — reached = lit + check, locked = dim + lock.
private struct MilestoneTrack: View {
    let streak: Int
    private func color(_ day: Int) -> Color { Color(hex: StatsConfig.milestoneTierHex[day] ?? StatsConfig.milestoneStartHex) }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StatsConfig.milestones, id: \.self) { day in
                let done = streak >= day
                VStack(spacing: 5) {
                    Image(systemName: "flame.fill").font(.system(size: 16)).foregroundColor(color(day))
                    Text("\(day) 天").font(.system(size: 11))
                        .foregroundColor(done ? Color(hex: 0xD6D6DC) : Color(hex: 0x7C7C84))
                    Image(systemName: done ? "checkmark" : "lock.fill")
                        .font(.system(size: 10))
                        .foregroundColor(done ? Color(hex: 0x61C554) : Color(hex: 0x4A4A50))
                }
                .frame(maxWidth: .infinity)
                .opacity(done ? 1 : 0.45)
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 8)
        .glassCard()
    }
}
```
Note: `GeometryReader` here measures the progress-bar width only — it is NOT layout-by-ratio of fonts/sizes, so it complies with PRD §1.4 (which forbids ratio-driven *sizing*). Heights/fonts are fixed points.

- [ ] **Step 2:** `swift build` → Build complete!. Self-test ≥126/0.

- [ ] **Step 3: Commit**
```bash
git add Sources/flowtype/Settings/Overview/AchievementsSection.swift
git commit -m "feat(ui): achievements 3-card warm + streak milestone + track (§5,§6)"
```

---

## Task 7: Refine heatmap + 24h to prototype; strip old `StatsPanel`

**Files:** Modify `Settings/Overview/StatsPanel.swift`.

- [ ] **Step 1: Reduce the file to just the two chart components.** Delete `struct StatsPanel`, `TabChip`, `MiniStatCard`, and the panel's grid/footer/empty helpers. KEEP `ActivityHeatmap` and `HourDistributionChart`. The footer + empty-state move to `OverviewPage` (Task 8). After this step the file contains only `import SwiftUI` / `import Charts`, `ActivityHeatmap`, `HourDistributionChart`.

- [ ] **Step 2: `ActivityHeatmap` — base color → `Theme.accent` (#8E7DF5) per §8.** In `heatColor`, change `Brand.accent` → `Theme.accent`:
```swift
    private func heatColor(_ level: Int) -> Color {
        level == 0 ? Theme.heatEmpty : Theme.accent.opacity(StatsConfig.heatOpacity[level])
    }
```
(Legend uses `heatColor` already — it inherits the change. Keep the existing 12pt cells / 3pt gap / popover tooltip "M月D日 — chars" — that already matches §8.)

- [ ] **Step 3: `HourDistributionChart` — peak by mode, prototype colors (§9).** The peak bar must be `summary.peakHour` (the mode), not the current clock hour. Replace the `chartBody`'s bar styling: drop `currentHour`/`let hour = currentHour`, and color bars:
```swift
                .foregroundStyle(index == summary.peakHour ? Theme.accentBright : Theme.accent.opacity(0.55))
```
Remove the now-unused `currentHour` computed property. (Title already renders "· 高峰 HH:00–HH:00" from `summary.peakHour`; keep it. Keep the all-zero empty state.)

- [ ] **Step 4:** `swift build` will now FAIL in `OverviewPage.swift` (it still references `StatsPanel()`), which Task 8 fixes. To verify THIS task in isolation, just confirm the two components compile by checking the error is only the `StatsPanel` reference in OverviewPage:
```bash
swift build 2>&1 | grep -E "error:" | head
```
Expected: only "cannot find 'StatsPanel' in scope" at OverviewPage. (Do not commit a broken build — proceed straight to Task 8, then build+commit them together. ALTERNATIVELY temporarily keep a thin `StatsPanel` stub — but simplest is to do Task 7+8 back-to-back and commit once. **Commit Task 7 together with Task 8.**)

---

## Task 8: `OverviewPage` — compose the new structure (§3, §10, §14)

**Files:** Modify `Settings/OverviewPage.swift`.

- [ ] **Step 1: Replace the whole `OverviewPage` struct** (keep `PageHeader` at the bottom of the file untouched — it is shared by other pages). New page owns the range, computes the range summary + always-year heatmap, composes the sections, and renders the footer/empty-state:
```swift
import SwiftUI

struct OverviewPage: View {
    @ObservedObject private var statsStore = DailyStatsStore.shared
    @State private var range: StatsRange = .d30

    var body: some View {
        let s = StatsEngine.summarize(statsStore.stats, range: range, now: Date())
        let yearCells = StatsEngine.denseHeatmap(statsStore.stats, range: .all, now: Date(), cal: .current)

        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                OverviewControlBar(range: $range)
                HeroSection(summary: s)
                AchievementsSection(summary: s)
                if s.isEmpty {
                    emptyGuideCard
                } else {
                    ActivityHeatmap(cells: yearCells)
                    HourDistributionChart(summary: s)
                }
                footerLine(s: s)
            }
            .frame(maxWidth: StatsConfig.contentMaxWidth)   // ① cap (780)
            .frame(maxWidth: .infinity)                     // ② center; gutters absorb extra width
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
        }
    }

    private var emptyGuideCard: some View {
        HStack {
            Spacer()
            Text("开始你的第一次口述，数据会出现在这里")
                .font(.system(size: 13)).foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center).padding(.vertical, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .glassCard()
    }

    @ViewBuilder private func footerLine(s: StatsSummary) -> some View {
        if let text = buildFooterText(s: s) {
            HStack(alignment: .top, spacing: 0) {
                Text(text)
                    .font(.system(size: 13)).foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 14)
            .overlay(Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5), alignment: .top)
        }
    }

    private func buildFooterText(s: StatsSummary) -> String? {
        guard s.chars > 0 else { return nil }
        var parts: [String] = ["你已累计口述约 \(thousands(s.chars)) 字"]
        if s.chars >= 50 {
            let keystrokes = Int(Double(s.chars) * StatsConfig.keystrokesPerChar)
            parts.append("少敲约 \(wan(keystrokes)) 次键盘")
        }
        if s.timeSavedSeconds >= StatsConfig.secondsPerMovie {
            parts.append("节省时间够看 \(s.timeSavedSeconds / StatsConfig.secondsPerMovie) 部电影")
        } else if s.timeSavedSeconds >= StatsConfig.secondsPerCoffee {
            parts.append("够泡 \(s.timeSavedSeconds / StatsConfig.secondsPerCoffee) 杯咖啡")
        }
        return parts.joined(separator: " · ")
    }

    private func thousands(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    private func wan(_ n: Int) -> String {
        n >= 10_000 ? String(format: "%.1f 万", Double(n) / 10_000.0) : thousands(n)
    }
}

// MARK: - Shared Components  (PageHeader — used by History/Vocab/Style; keep unchanged)

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 22, weight: .bold))
            Text(subtitle).font(.system(size: 12)).foregroundColor(.secondary)
        }
    }
}
```

- [ ] **Step 2:** `swift build` → Build complete!. `set -o pipefail && swift run FlowType --self-test 2>&1 | tail -1` → ≥126/0.

- [ ] **Step 3: Commit (Tasks 7 + 8 together)**
```bash
git add Sources/flowtype/Settings/Overview/StatsPanel.swift Sources/flowtype/Settings/OverviewPage.swift
git commit -m "feat(ui): rebuild Overview page to prototype IA — control bar/Hero/achievements/heatmap/24h/footer (§3,§8,§9,§10,§14)"
```

---

## Task 9: Sidebar — settings pinned bottom-left (§7)

**Files:** Modify `Settings/MainWindowView.swift`.

- [ ] **Step 1: Split the nav.** In `MainWindowView.sidebar`, iterate only the primary tabs and pin 设置 to the bottom with a top divider. Replace the `sidebar` computed property:
```swift
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(AppTab.allCases.filter { $0 != .settings }) { tab in
                SidebarRow(tab: tab, selected: selectedTab == tab) { selectedTab = tab }
            }
            Spacer()
            Divider().overlay(Color.white.opacity(0.06))
            SidebarRow(tab: .settings, selected: selectedTab == .settings) { selectedTab = .settings }
                .padding(.top, 6)
        }
        .padding(.horizontal, 10)
        .padding(.top, 36)
        .padding(.bottom, 12)
        .frame(width: 176)
    }
```
(`AppTab.settings` keeps its `gearshape.fill` icon + "设置" title — already defined.)

- [ ] **Step 2:** `swift build` → Build complete!. Self-test ≥126/0.

- [ ] **Step 3: Commit**
```bash
git add Sources/flowtype/Settings/MainWindowView.swift
git commit -m "feat(ui): sidebar — settings pinned bottom-left with divider (§7)"
```

---

## Task 10: Build `.app` → STOP for owner acceptance

- [ ] **Step 1:** Build + relaunch + push:
```bash
cd /Users/yiheng/pycode/flowtype-local
./scripts/build-app.sh 2>&1 | tail -1
pkill -x FlowType 2>/dev/null; sleep 1; xattr -cr build/FlowType.app && open build/FlowType.app
for i in 1 2 3; do git push origin flowtype-local 2>&1 | tail -1 && break; sleep 5; done
```
- [ ] **Step 2: STOP.** Report ready; owner verifies vs prototype + acceptance §15.5–§15.8 (Hero 2×2 equal-height + no dup; achievements warm; flame tier color + progress + animation; settings bottom-left; heatmap tooltip; 24h peak highlight). **Do NOT** start §11 editable-CPM or §12 SQLite — those are separate later stages.

---

## Self-Review

**Spec coverage:** §3 IA → Tasks 4(control bar)+5(Hero)+6(achievements)+7-8(heatmap/24h/footer compose), dedup done by removing the old grid (Task 7). §4 2×2 → Task 5 (节省 purple #B9AEFF, big/small h/m, icons). §5 achievements warm → Task 6. §6 milestone (array+tiers+flame color+progress+caption+animation+track) → Tasks 1,2,6. §7 sidebar bottom → Task 9. §8 heatmap (dense year, §8 opacities, #8E7DF5 base, tooltip, legend) → Tasks 1,7. §9 24h (24 bars, peak by mode + bright bar, empty state) → Task 7. §10 footer (兜底 coffee/hide) → Task 8. §11 口径 already correct (recMs denominator) — no change; **editable baseline DEFERRED** (no Configuration field today). §12 SQLite **DEFERRED**. §14 empty/low → Task 8 empty card + footer 兜底. §1/§2 unchanged (already accepted).

**Placeholder scan:** none — every step has full code or exact commands.

**Type consistency:** `StatsSummary` fields used (`chars, timeSavedSeconds, recordingSeconds, avgSpeedCPM, activeDays, currentStreak, longestStreak, peakHour, hourHistogram, isEmpty`) all exist. New `StatsEngine.{flameTier,nextMilestone,milestoneProgress,activeDaysInMonth,longestStreakEndMonth}` defined Task 2, used Task 6. New `StatsConfig.{milestones,milestoneStartHex,milestoneTierHex,heatOpacity}` defined Task 1, used Tasks 6,7. `StatValueView(segments:numberSize:unitSize:numberColor:)` — `numberWeight` defaulted, callers in Task 5 pass `numberSize/unitSize/numberColor`. `OverviewControlBar(range:)`, `HeroSection(summary:)`, `AchievementsSection(summary:)`, `ActivityHeatmap(cells:)`, `HourDistributionChart(summary:)` — all signatures match call sites in Task 8. `Color(hex:)` exists (Theme.swift). `DictionaryStore.shared.entries[].enabled` — same accessor the old `accuracyProgress` used. Footer constants (`keystrokesPerChar/secondsPerMovie/secondsPerCoffee`) exist.
