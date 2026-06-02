# Brand Visual Rollout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the capsule's purple→blue brand into all windows as "restrained adaptive glass": system-material glass cards, a single brand accent used only on anchor/active elements, and big-number/small-unit stat typography.

**Architecture:** Build a tiny shared theme layer (`Brand` colors/gradient, a `.glassCard()` modifier, `StatFormatting` + `StatValueView`), then apply it page by page. Foundation is fully coded + unit-tested where pure; page application is mechanical restyle (build-green; visual look verified manually).

**Tech Stack:** SwiftUI, system materials (`.ultraThinMaterial`). No XCTest (CLT only) — the pure stat formatter is verified in the `--self-test` runner; visuals are manual.

**Spec:** `docs/superpowers/specs/2026-06-03-brand-visual-rollout-design.md`

**Verification commands:**
- Build: `swift build` (expect `Build complete!`)
- Self-test: `set -o pipefail; swift run FlowType --self-test` (expect `... passed, 0 failed`, exit 0)

**Note on font:** the typeface is NOT changed in this work (per spec §3.7 + §6). No `BrandFont` helper is introduced — a future font swap will be its own focused task.

---

## File structure

- Create `Sources/flowtype/UI/Theme/Brand.swift` — brand colors + gradients.
- Create `Sources/flowtype/UI/Theme/GlassCard.swift` — `.glassCard(active:)` ViewModifier.
- Create `Sources/flowtype/UI/Theme/StatValue.swift` — `StatSegment`, `StatFormatting`, `StatValueView`.
- Modify `Sources/flowtype/Core/DailyStats.swift` — add `estimatedTimeSavedSeconds`.
- Modify `Sources/flowtype/Settings/OverviewPage.swift` — apply theme.
- Modify the Settings cards/sections, History/Vocab/Style, Onboarding, MainWindowView — apply theme (Tasks 4–6).
- Modify `Sources/flowtype/Testing/SelfTest.swift` — `testStatFormatting`.

---

## Task 1: Theme foundation — Brand colors + glass card

**Files:**
- Create: `Sources/flowtype/UI/Theme/Brand.swift`
- Create: `Sources/flowtype/UI/Theme/GlassCard.swift`

- [ ] **Step 1: Create `Brand.swift`**

```swift
import SwiftUI

/// The single source of the FlowType brand color (purple → blue), matching the capsule.
enum Brand {
    static let purple = Color(red: 0.52, green: 0.36, blue: 1.0)   // ~#855CFF
    static let blue   = Color(red: 0.30, green: 0.63, blue: 1.0)   // ~#4DA1FF

    /// Single-color accent for small/flat uses (selected state, links, small icons).
    static let accent = purple

    /// Hero gradient (diagonal) for anchor elements: progress ring, active strokes.
    static let gradient = LinearGradient(
        colors: [purple, blue],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// Horizontal gradient for rows / wide elements.
    static let gradientH = LinearGradient(
        colors: [purple, blue],
        startPoint: .leading, endPoint: .trailing
    )
}
```

- [ ] **Step 2: Create `GlassCard.swift`**

```swift
import SwiftUI

/// The unified "restrained adaptive glass" surface. Translucent system material (adapts to
/// light/dark), hairline border, soft shadow. `active: true` swaps to a brand-gradient border
/// + subtle brand glow for the selected/current item — the ONLY place a card glows.
struct GlassCard: ViewModifier {
    var active: Bool = false
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        active ? AnyShapeStyle(Brand.gradient)
                               : AnyShapeStyle(Color.primary.opacity(0.08)),
                        lineWidth: active ? 1.5 : 1
                    )
            )
            .shadow(color: active ? Brand.purple.opacity(0.18) : .black.opacity(0.06),
                    radius: active ? 10 : 6, x: 0, y: 2)
    }
}

extension View {
    /// Apply the unified glass-card surface. Use `active: true` for the selected/current item.
    func glassCard(active: Bool = false, cornerRadius: CGFloat = 12) -> some View {
        modifier(GlassCard(active: active, cornerRadius: cornerRadius))
    }
}
```

- [ ] **Step 3: Build**

Run: `set -o pipefail; swift build && swift run FlowType --self-test`
Expected: `Build complete!` then `... passed, 0 failed` (no behavior change yet; these are unused primitives).

- [ ] **Step 4: Commit**

```bash
git add Sources/flowtype/UI/Theme/Brand.swift Sources/flowtype/UI/Theme/GlassCard.swift
git commit -m "feat: add brand theme foundation (colors + glass card modifier)"
```

---

## Task 2: Stat typography (TDD) + saved-time seconds

**Files:**
- Create: `Sources/flowtype/UI/Theme/StatValue.swift`
- Modify: `Sources/flowtype/Core/DailyStats.swift`
- Test: `Sources/flowtype/Testing/SelfTest.swift`

- [ ] **Step 1: Write the failing self-test**

In `Sources/flowtype/Testing/SelfTest.swift`, add this method and call `testStatFormatting(r)` in `runAndExit()`:

```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build` → expect FAIL `cannot find 'StatFormatting' in scope`.

- [ ] **Step 3: Create `StatValue.swift`**

```swift
import SwiftUI

/// One part of a stat value: a number, optionally followed by a small unit.
struct StatSegment: Equatable {
    let number: String
    let unit: String?   // nil = plain number (no unit, e.g. word count)
}

/// Pure formatters that turn raw stats into big-number/small-unit segments.
enum StatFormatting {
    /// Whole seconds → 小时/分钟 segments (hours omitted when zero).
    static func duration(seconds: Int) -> [StatSegment] {
        let s = max(0, seconds)
        let hours = s / 3600
        let minutes = (s % 3600) / 60
        if hours > 0 {
            return [StatSegment(number: "\(hours)", unit: "小时"),
                    StatSegment(number: "\(minutes)", unit: "分钟")]
        }
        return [StatSegment(number: "\(minutes)", unit: "分钟")]
    }

    static func speed(_ wpm: Int) -> [StatSegment] {
        [StatSegment(number: "\(max(0, wpm))", unit: "字/分")]
    }

    /// Plain value with no unit (e.g. word count) — a single unchanged big number.
    static func plain(_ text: String) -> [StatSegment] {
        [StatSegment(number: text, unit: nil)]
    }
}

/// Renders segments as big number + small muted unit, baseline-aligned, with spacing.
struct StatValueView: View {
    let segments: [StatSegment]
    var numberSize: CGFloat = 22
    var unitSize: CGFloat = 11

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                Text(seg.number)
                    .font(.system(size: numberSize, weight: .bold))
                    .foregroundColor(.primary)
                if let unit = seg.unit {
                    Text(" \(unit) ")
                        .font(.system(size: unitSize, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}
```

- [ ] **Step 4: Add `estimatedTimeSavedSeconds` to `DailyStats.swift`**

In `Sources/flowtype/Core/DailyStats.swift`, inside `DailyStatsStore`, add next to `estimatedTimeSaved`:

```swift
    /// Estimated time saved vs typing at 40 WPM, in whole seconds (for StatFormatting).
    var estimatedTimeSavedSeconds: Int {
        let typingMinutes = Double(totalWordCount) / 40.0
        let speakingMinutes = Double(totalDurationMs) / 1000.0 / 60.0
        return max(0, Int((typingMinutes - speakingMinutes) * 60))
    }
```

- [ ] **Step 5: Run to verify it passes**

Run: `set -o pipefail; swift build && swift run FlowType --self-test`
Expected: `Build complete!` then `... passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add Sources/flowtype/UI/Theme/StatValue.swift Sources/flowtype/Core/DailyStats.swift Sources/flowtype/Testing/SelfTest.swift
git commit -m "feat: add stat number/unit typography (StatFormatting + StatValueView)"
```

---

## Task 3: Apply theme to OverviewPage

**Files:**
- Modify: `Sources/flowtype/Settings/OverviewPage.swift`

- [ ] **Step 1: Replace the `OverviewPage` struct body, `accuracyCard`, `mainStatsGrid`, `statCard`, and `cardBackground`**

Replace everything from `struct OverviewPage: View {` through its closing brace (the `formatWordCount` method, keep it) with the version below. KEEP the `PageHeader` struct that follows. DELETE the `extension UInt64 { var formattedDuration ... }` block (it becomes unused — confirm with `grep -rn "formattedDuration" Sources/`; if another file uses it, leave it).

```swift
struct OverviewPage: View {
    @ObservedObject private var statsStore = DailyStatsStore.shared
    @ObservedObject private var dictionaryStore = DictionaryStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                HStack(spacing: 20) {
                    accuracyCard
                    mainStatsGrid
                }
                .frame(height: 200)

                Spacer(minLength: 20)
            }
            .padding(24)
        }
        .background(brandBackdrop)
    }

    /// Window background with a barely-there brand tint in the corners.
    private var brandBackdrop: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Brand.purple.opacity(0.06), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 340)
            RadialGradient(colors: [Brand.blue.opacity(0.05), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 340)
        }
        .ignoresSafeArea()
    }

    private var accuracyCard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 8)
                    .frame(width: 80, height: 80)
                Circle()
                    .trim(from: 0, to: accuracyProgress)
                    .stroke(Brand.gradient, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(-90))
                    .shadow(color: Brand.purple.opacity(0.22), radius: 6)
                Text("\(Int(accuracyProgress * 100))%")
                    .font(.system(size: 18, weight: .bold))
            }
            Text("个性化")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .glassCard()
    }

    private var mainStatsGrid: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                statCard(icon: "clock",
                         segments: StatFormatting.duration(seconds: Int(statsStore.totalDurationMs / 1000)),
                         label: "总口述时间")
                statCard(icon: "text.word.count",
                         segments: StatFormatting.plain(formatWordCount(statsStore.totalWordCount)),
                         label: "口述字数")
            }
            HStack(spacing: 12) {
                statCard(icon: "hourglass",
                         segments: StatFormatting.duration(seconds: statsStore.estimatedTimeSavedSeconds),
                         label: "节省时间")
                statCard(icon: "bolt",
                         segments: StatFormatting.speed(statsStore.overallAverageSpeed),
                         label: "平均口述速度（字/分钟）")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statCard(icon: String, segments: [StatSegment], label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                Spacer()
            }
            StatValueView(segments: segments)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .glassCard()
    }

    private var accuracyProgress: Double {
        let total = dictionaryStore.entries.count
        guard total > 0 else { return 0 }
        let enabled = dictionaryStore.entries.filter(\.enabled).count
        return Double(enabled) / Double(total)
    }

    private func formatWordCount(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000.0)
        }
        return "\(count)"
    }
}
```

- [ ] **Step 2: Build + self-test**

Run: `set -o pipefail; swift build && swift run FlowType --self-test`
Expected: `Build complete!` then `... passed, 0 failed`.

- [ ] **Step 3: Commit**

```bash
git add Sources/flowtype/Settings/OverviewPage.swift
git commit -m "feat: restyle Overview with brand glass cards + ring + stat typography"
```

---

## Task 4: Apply theme to Settings (sections + cards)

Mechanical restyle — build-green; the look is verified manually later. Read each file and apply the rules below. Do NOT change any logic/behavior.

**Files:** `Sources/flowtype/Settings/SettingsView.swift`, `SettingsPage+ASR.swift`, `+LLM.swift`, `+Recording.swift`, `+Trigger.swift`, `+Permission.swift`, `+Diagnostics.swift`, `QwenModelStatusCard.swift`, `ServiceConfigCard.swift`, `ProviderRow.swift`, `ProviderEditSheet.swift`, `SettingsFieldComponents.swift`.

- [ ] **Step 1: Unify section-header accent colors to the brand accent**

In the `SettingsPage+*.swift` section files, the section-header icons currently use per-section colors (ASR blue / LLM purple / Recording red / Trigger orange / Permission green). Change EACH section-header icon's color to `Brand.accent` (or `.foregroundStyle(Brand.gradient)` for the icon). Leave the **Permission status colors** (granted green / denied-or-warning orange/red) as-is — those are semantic. Example: a header like
```swift
Image(systemName: "waveform").foregroundColor(.blue)
```
becomes
```swift
Image(systemName: "waveform").foregroundStyle(Brand.gradient)
```

- [ ] **Step 2: Convert card backgrounds to `.glassCard()`**

In `QwenModelStatusCard.swift`, `ServiceConfigCard.swift`, `ProviderRow.swift`, and any card in the section files, replace the ad-hoc card background (a `RoundedRectangle(cornerRadius:...).fill(Color(nsColor: .controlBackgroundColor))` + manual `.overlay` stroke + `.shadow`) with `.glassCard()`. Keep the card's padding and content. For the **active provider** in `ProviderRow.swift` (the one with `isActive`/green border), use `.glassCard(active: true)` instead of its current green/accent border.

- [ ] **Step 3: Status colors stay semantic**

Confirm these remain their semantic colors (do NOT brand them):
- `QwenModelStatusCard`: ready = green check, downloading/loading = orange, failed = red.
- Connection-test indicators in `ProviderRow`/`ProviderEditSheet`: success green / failure red.
- Permission status: granted green / not-granted orange/red.
The brand accent replaces only DECORATIVE color (section icons, active-item highlight, the provider status dot when active → brand).

- [ ] **Step 4: Build + self-test**

Run: `set -o pipefail; swift build && swift run FlowType --self-test`
Expected: `Build complete!` then `... passed, 0 failed`. (Behavior unchanged; only styling.)
Then `grep -rn "controlBackgroundColor\|Color(nsColor: .control" Sources/flowtype/Settings/` to confirm the ad-hoc card fills were replaced (a remaining one is OK only if it is intentionally a non-card surface — note it).

- [ ] **Step 5: Commit**

```bash
git add Sources/flowtype/Settings/
git commit -m "feat: restyle Settings with brand glass cards + unified accent"
```

---

## Task 5: Apply theme to History / Vocab / Style pages

Same mechanical restyle (build-green; visual manual). Read each file and apply.

**Files:** `Sources/flowtype/Settings/HistoryPage.swift`, `VocabPage.swift`, `StylePage.swift`.

- [ ] **Step 1: Card surfaces → `.glassCard()`**

Replace each page's ad-hoc card/row background (RoundedRectangle fill of `controlBackgroundColor`/`textBackgroundColor` + manual stroke/shadow) with `.glassCard()`. For the **selected/current item** use `.glassCard(active: true)`:
- `StylePage.swift`: the **active** style pack card (currently a blue 2pt border) → `.glassCard(active: true)`; inactive packs → `.glassCard()`.
- `VocabPage.swift`: the add-entry card and the info card → `.glassCard()`. (The `VocabTag` chips keep their enabled/disabled tint logic, but recolor the **enabled** tint from blue to `Brand.accent` — e.g. background `Brand.accent.opacity(0.10)`, border `Brand.accent.opacity(0.30)`; disabled stays gray.)
- `HistoryPage.swift`: the detail `DetailSection` text boxes and the left list rows → `.glassCard()` where they currently draw a card; the selected history row → `.glassCard(active: true)`.

- [ ] **Step 2: Mode/category hues — keep informational, brand the decorative**

- `HistoryPage.swift` mode chips (原文 blue / 轻度 teal / 结构 purple / 正式 orange) **encode the mode** → KEEP distinct hues (informational). Do not fold these into the brand.
- `VocabPage.swift` auto-detected `wand.and.stars` icon and the bottom info card accent → `Brand.accent`.
- `StylePage.swift`: the "当前" badge and the active border → brand; the category badge (内置/导入/自定义) stays a neutral gray (decorative, fold to gray, not brand).

- [ ] **Step 3: Page headers**

`PageHeader` (in OverviewPage.swift) is shared. Leave its title as `.primary` (no change needed) — the brand shows through the cards/accents, not every title. (If a page title currently uses a colored accent, set it to `.primary`.)

- [ ] **Step 4: Build + self-test**

Run: `set -o pipefail; swift build && swift run FlowType --self-test`
Expected: `Build complete!` then `... passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/flowtype/Settings/HistoryPage.swift Sources/flowtype/Settings/VocabPage.swift Sources/flowtype/Settings/StylePage.swift
git commit -m "feat: restyle History/Vocab/Style with brand glass cards"
```

---

## Task 6: Apply theme to Onboarding + main window sidebar

**Files:** `Sources/flowtype/Settings/OnboardingView.swift`, `Sources/flowtype/Settings/MainWindowView.swift`.

- [ ] **Step 1: Onboarding**

In `OnboardingView.swift`:
- The **progress dots**: the active/completed dot → fill with `Brand.gradient` (or `Brand.accent`); inactive dots → `Color.secondary.opacity(0.3)`.
- Step **cards** (the permission cards, the welcome/demo panels): apply `.glassCard()` where they currently draw a panel; keep the permission status colors semantic (granted green, not-granted orange/red).
- Primary buttons ("开始设置", "继续", "开始使用 FlowType"): if they use `.borderedProminent`, set `.tint(Brand.accent)` so the call-to-action is on-brand.
- The welcome icon (currently a large `mic.badge.plus` in accent color): set `.foregroundStyle(Brand.gradient)`.

- [ ] **Step 2: Main window sidebar**

In `MainWindowView.swift`:
- The selected sidebar item should read as brand-accented. The simplest reliable way: set `.tint(Brand.accent)` on the `NavigationSplitView` (or the sidebar `List`), so SwiftUI uses the brand color for the selection highlight and the selected `Label` icon.

- [ ] **Step 3: Build + self-test**

Run: `set -o pipefail; swift build && swift run FlowType --self-test`
Expected: `Build complete!` then `... passed, 0 failed`.

- [ ] **Step 4: Commit**

```bash
git add Sources/flowtype/Settings/OnboardingView.swift Sources/flowtype/Settings/MainWindowView.swift
git commit -m "feat: brand-accent onboarding + main window sidebar selection"
```

---

## Task 7: Manual verification (real GUI, light + dark) — DEFERRED to the owner's batch

Self-tests cover the stat formatter; the look needs a real window. Build the app and open the Settings window (no recording needed).

- [ ] **Step 1:** `./scripts/build-app.sh && open build/FlowType.app`, then open the main window (status bar → 显示 Flowtype, or ⌘,).
- [ ] **Step 2:** Walk all five tabs (概览/历史/词典/风格/设置) + onboarding. Confirm: glass cards adapt (toggle System Settings → Appearance Light/Dark), the brand purple→blue shows only on anchors/active items (ring, active provider, sidebar selection, active style pack), and status colors (green/orange/red) still read as status. Overview stat values show big-number/small-unit (`2 小时 14 分钟`), word count plain.
- [ ] **Step 3:** Confirm it does NOT feel "too much / tiring" (the restraint goal). If it does, dial back: lower `Brand` opacity in `GlassCard` glow/border, reduce the `brandBackdrop` radial opacities, or remove brand from any element that over-uses it. Re-verify and commit any tuning:
```bash
git add -A && git commit -m "fix: tune brand-visual restraint from manual verification"
```

---

## Self-review (completed by author)

- **Spec coverage:** §3.1 materials/adaptivity → `GlassCard` `.ultraThinMaterial` (Task 1). §3.2 brand color → `Brand` (Task 1). §3.3 accent unification + keep-semantic → Tasks 4–6 rules. §3.4 glass card → Task 1. §3.5 glow restraint → `GlassCard` active-only glow + Task 7 tuning. §3.6 number typography → Task 2 (`StatFormatting`/`StatValueView`) applied in Task 3. §3.7 font → intentionally no-op (documented). §4 shared layer → Tasks 1–2 (BrandFont omitted per note). §5 rollout → Tasks 3–6 in spec order. §7 testing → Task 2 self-test + Task 7 manual. Covered.
- **Placeholder scan:** none — foundation tasks (1–3) have complete code; the application tasks (4–6) are mechanical restyles with concrete per-file rules + example before/after snippets (full rewrites of those large existing files are impractical and the visual outcome is tuned manually). Every run step has command + expected output.
- **Type consistency:** `Brand` (purple/blue/accent/gradient/gradientH), `glassCard(active:cornerRadius:)`, `StatSegment(number:unit:)`, `StatFormatting.duration(seconds:)/speed(_:)/plain(_:)`, `StatValueView(segments:)`, `DailyStatsStore.estimatedTimeSavedSeconds` — consistent across tasks.
