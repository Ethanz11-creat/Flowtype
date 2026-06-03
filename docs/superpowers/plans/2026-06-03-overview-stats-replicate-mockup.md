# Overview Stats — Replicate the Mockup + Heatmap-Always-Year

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (or executing-plans). Steps use checkbox (`- [ ]`).

**Goal:** Make the live Overview panel faithfully match the approved mockup, and fix the heatmap so it **always shows the last year (range = all)** regardless of the All/30d/7d switch (which only drives the cards + 24h chart).

**Architecture:** Decouple the heatmap from the range switcher — compute a year-long dense heatmap independently; align colors/labels/order to the mockup. Pure-logic untouched (`StatsEngine` already supports it). No new Swift Charts; no data changes.

**Reference:** the owner-confirmed mockup (deep-dark dashboard: compact ring + 4 cards row · tabs + All/30d/7d · 8-card grid with 节省时间/当前连续 in purple · GitHub heatmap "最近一年" with neutral empty cells + 少▢▢▢▢▢多 legend · 24h bars with bright peak · footer "…少敲了约 2.4 万 次键盘 ⌨️ · …够看 1 部电影 🎬").

**Verify:** `swift build` green; `swift run FlowType --self-test` stays **118/0**; real gate = compare against the mockup on-device (Task 3).

---

## Task 1: Heatmap always last-year + neutral empty cells + header

**Files:** Modify `Sources/flowtype/Settings/Overview/StatsPanel.swift`.

- [ ] **Step 1: Feed the heatmap a year of data, independent of `range`.** In `StatsPanel.body`, the heatmap currently gets the range-dependent `s`. Compute a separate year heatmap and pass cells directly:
```swift
    var body: some View {
        let s = StatsEngine.summarize(store.stats, range: range, now: Date())
        let yearCells = StatsEngine.denseHeatmap(store.stats, range: .all, now: Date(), cal: .current)

        VStack(alignment: .leading, spacing: 16) {
            headerRow
            statGrid(s: s)
            if s.isEmpty {
                emptyGuideCard
            } else {
                ActivityHeatmap(cells: yearCells)
                HourDistributionChart(summary: s)
            }
            footerLine(s: s)
        }
        .padding(16)
        .glassCard(cornerRadius: Brand.Radius.panel)
    }
```
(The cards + 24h still use `s` = the selected range; only the heatmap is pinned to `.all`.)

- [ ] **Step 2: `ActivityHeatmap` takes `cells` + neutral level-0 + "最近一年" header.** Replace the `ActivityHeatmap` struct with:
```swift
struct ActivityHeatmap: View {
    let cells: [HeatCell]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("活动热力图 · 最近一年")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            heatGrid
            legendRow
        }
    }

    /// Level 0 = neutral (empty) cell; 1...4 = brand-accent ramp (matches the mockup).
    private func heatColor(_ level: Int) -> Color {
        level == 0 ? Color.primary.opacity(0.08) : Brand.accent.opacity(StatsConfig.heatOpacity[level])
    }

    private var heatGrid: some View {
        let leadingBlanks = cells.first?.weekday ?? 0
        let rows = Array(repeating: GridItem(.fixed(12), spacing: 3), count: 7)
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: rows, spacing: 3) {
                ForEach(0..<leadingBlanks, id: \.self) { _ in
                    Color.clear.frame(width: 12, height: 12)
                }
                ForEach(cells, id: \.dayOrdinal) { cell in
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(heatColor(cell.level))
                        .frame(width: 12, height: 12)
                        .help("\(cell.date) · \(cell.chars) 字 · \(cell.sessions) 次")
                        .accessibilityLabel("\(cell.date), \(cell.chars) 字")
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var legendRow: some View {
        HStack(spacing: 4) {
            Spacer()
            Text("少").font(.system(size: 9)).foregroundColor(.secondary)
            ForEach(0..<5, id: \.self) { lvl in
                RoundedRectangle(cornerRadius: 2).fill(heatColor(lvl)).frame(width: 10, height: 10)
            }
            Text("多").font(.system(size: 9)).foregroundColor(.secondary)
        }
    }
}
```

- [ ] **Step 3:** `swift build` green; `swift run FlowType --self-test` 118/0; **Commit** `fix(stats): heatmap always shows last year (decoupled from range) + neutral empty cells`.

---

## Task 2: Footer 万-format · "✓修正" tag · top-card order

**Files:** Modify `Sources/flowtype/Settings/Overview/StatsPanel.swift`, `Sources/flowtype/Settings/OverviewPage.swift`.

- [ ] **Step 1: Footer keystrokes use 万 for big numbers** (mockup: "2.4 万"). In `StatsPanel`, add a helper and use it for the keystroke clause:
```swift
    /// Large counts as 万 (e.g. 24,180 → "2.4 万"); small counts keep thousands separators.
    private func formatWan(_ n: Int) -> String {
        if n >= 10_000 {
            let wan = Double(n) / 10_000.0
            return String(format: "%.1f 万", wan)
        }
        return formatThousands(n)
    }
```
In `buildFooterText`, change the keystroke line from `formatThousands(keystrokes)` to `formatWan(keystrokes)`:
```swift
            parts.append("少敲了约 \(formatWan(keystrokes)) 次键盘 ⌨️")
```

- [ ] **Step 2: "✓修正" tag on the avg-speed card** (mockup label "平均速度 ✓修正"). In `statGrid`, change the 平均速度 card's label:
```swift
            MiniStatCard(icon: "bolt.fill",      value: "\(s.avgSpeedCPM)",       unit: "字/分",  label: "平均速度 ✓修正", accent: false)
```

- [ ] **Step 3: Reorder the top 4 cards to match the mockup** (字数 · 节省时间 · 总口述时间 · 平均速度). In `OverviewPage.swift` `mainStatsGrid`, reorder the four `statCard(...)` calls to:
```swift
    private var mainStatsGrid: some View {
        HStack(spacing: 12) {
            statCard(icon: "text.word.count",
                     segments: StatFormatting.plain(formatWordCount(statsStore.totalWordCount)),
                     label: "口述字数")
            statCard(icon: "hourglass",
                     segments: StatFormatting.duration(seconds: statsStore.estimatedTimeSavedSeconds),
                     label: "节省时间")
            statCard(icon: "clock",
                     segments: StatFormatting.duration(seconds: Int(statsStore.totalDurationMs / 1000)),
                     label: "总口述时间")
            statCard(icon: "bolt",
                     segments: StatFormatting.speed(statsStore.overallAverageSpeed),
                     label: "平均速度")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
```

- [ ] **Step 4:** `swift build` green; self-test 118/0; **Commit** `fix(stats): footer 万-format + ✓修正 tag + top-card order to match mockup`.

---

## Task 3: On-device compare to the mockup (manual)

- [ ] Build `.app`, launch, open Overview. Side-by-side with the mockup, confirm:
  - Heatmap stays "最近一年" and **does NOT change** when switching All/30d/7d (only cards + 24h change); empty cells are neutral gray, active cells purple ramp; legend 少▢▢▢▢▢多.
  - 8-card grid: 节省时间 + 当前连续 numbers purple; 平均速度 shows "✓修正"; numbers bold/large.
  - Footer reads "…少敲了约 2.4 万 次键盘 ⌨️ · …够看 N 部电影 🎬" (万 unit for big keystrokes).
  - Top row: compact ring + 字数/节省/总时间/速度 in one equal-height row.
  - Widen the window → card columns increase (no balloon); heatmap scrolls.
- [ ] Build + push; note any remaining mockup gap.

---

## Self-Review
- Heatmap decoupled from range (Task 1 Step 1) + always `.all` ✓; neutral level-0 + "最近一年" ✓; footer 万 (Task 2 S1) ✓; ✓修正 (S2) ✓; top order (S3) ✓.
- No placeholders; full code per step.
- Type consistency: `ActivityHeatmap(cells:)` (was `summary:`) updated at the call site (Task 1 S1) and definition (S2); `StatsEngine.denseHeatmap(_:range:now:cal:)` signature matches; `formatWan`/`formatThousands` both defined.
