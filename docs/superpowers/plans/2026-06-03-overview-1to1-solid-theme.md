# Overview 1:1 Replica + Solid Content Theme — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`).

**Goal:** Make content panes solid/opaque (clean high-contrast, no frosted gray) while keeping the frosted window shell + sidebar; give the Overview a fixed-width-centered layout (widen → gutters only, scroll-not-compress); add a hover tooltip to the heatmap. Adaptive dark+light.

**Architecture:** New `Theme` (solid adaptive tokens). `GlassCard` → solid fill. The detail/content region paints `Theme.pageBackground` over the window's `FrostBackground` (sidebar stays transparent → frost shows). Overview wrapped in a 1200-max centered column. No Swift Charts change.

**Spec:** `docs/superpowers/specs/2026-06-03-overview-1to1-solid-theme-design.md`

**Verify:** `swift build` green; `swift run FlowType --self-test` stays **118/0** (UI; no new tests); real gate = on-device (Task 6). Ignore stale SourceKit "Cannot find X".

---

## Task 1: `Theme` tokens + StatsConfig sizes

**Files:** Create `Sources/flowtype/UI/Theme/Theme.swift`; modify `Sources/flowtype/Core/StatsConfig.swift`.

- [ ] **Step 1: Create `Theme.swift`** (`Color(light:dark:)` already exists in `Brand.swift`):
```swift
import SwiftUI

/// Solid (opaque) content theme — adaptive light/dark. The window SHELL + sidebar stay frosted;
/// content panes use these solid surfaces for clean high-contrast (no frosted gray bleed).
enum Theme {
    static let pageBackground = Color(light: Color(red: 0.961, green: 0.961, blue: 0.969),  // #F5F5F7
                                      dark:  Color(red: 0.047, green: 0.047, blue: 0.059))   // #0C0C0F
    static let cardBackground = Color(light: .white,
                                      dark:  Color(red: 0.090, green: 0.090, blue: 0.110))   // #17171C
    static let cardBorder     = Color(light: Color.black.opacity(0.06),
                                      dark:  Color.white.opacity(0.06))
    static let textPrimary    = Color(light: Color(red: 0.10, green: 0.10, blue: 0.11),
                                      dark:  Color(red: 0.961, green: 0.961, blue: 0.969))
    static let textSecondary  = Color(light: Color(red: 0.42, green: 0.42, blue: 0.45),
                                      dark:  Color(red: 0.541, green: 0.541, blue: 0.573))   // #8A8A92
    static let heatEmpty      = Color(light: Color(red: 0.902, green: 0.902, blue: 0.918),   // #E6E6EA
                                      dark:  Color(red: 0.110, green: 0.110, blue: 0.133))    // #1C1C22
    static let accent = Brand.accent   // adaptive desaturated purple
    static let cardRadius: CGFloat = 14
    static let cardPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 20
}
```

- [ ] **Step 2: StatsConfig** — bump min window + add content max width. In `StatsConfig.swift` replace the window/grid consts:
```swift
    static let minWindowWidth: CGFloat = 1040
    static let minWindowHeight: CGFloat = 700
    static let contentMaxWidth: CGFloat = 1200
```
Also change `heatOpacity` to the demo ramp:
```swift
    static let heatOpacity: [Double] = [0.25, 0.45, 0.65, 0.85, 1.0]
```
(Drop `cardMinWidth`/`cardMaxWidth` if present — the grid is fixed 4-col now; if other code references them, leave them.)

- [ ] **Step 3:** `swift build` green; **Commit** `feat(ui): solid Theme tokens + 1040×700 min + 1200 content width`.

---

## Task 2: `GlassCard` → solid surface

**Files:** Modify `Sources/flowtype/UI/Theme/GlassCard.swift`.

- [ ] **Step 1: Replace the `GlassCard` body + `fill`/`border`** so cards are opaque solid (not `.thinMaterial`):
```swift
struct GlassCard: ViewModifier {
    var active: Bool = false
    var cornerRadius: CGFloat = Theme.cardRadius

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(shape.fill(active ? AnyShapeStyle(Brand.accent.opacity(0.14)) : AnyShapeStyle(Theme.cardBackground)))
            .overlay(shape.strokeBorder(active ? Brand.accent.opacity(0.55) : Theme.cardBorder, lineWidth: 1))
    }
}

extension View {
    /// Solid content-card surface. `active: true` = accent wash + accent border.
    func glassCard(active: Bool = false, cornerRadius: CGFloat = Theme.cardRadius) -> some View {
        modifier(GlassCard(active: active, cornerRadius: cornerRadius))
    }
}
```
(Removes `@Environment(\.colorScheme)` — `Theme` colors are already adaptive. Default radius now 14.)

- [ ] **Step 2:** `swift build` green; self-test 118/0; **Commit** `feat(ui): GlassCard → solid opaque surface (de-frost content cards)`.

---

## Task 3: Solid content background + window mins + onboarding

**Files:** Modify `Settings/MainWindowView.swift`, `Settings/SettingsWindowController.swift`, `Settings/OnboardingView.swift`.

- [ ] **Step 1: MainWindowView — solid detail region (sidebar stays frosted).** Put `Theme.pageBackground` on the `detail`; keep `FrostBackground()` on the HStack. Change:
```swift
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.pageBackground)
```
(`.background(FrostBackground())` and `.frame(minWidth: StatsConfig.minWindowWidth, minHeight: StatsConfig.minWindowHeight)` already present — leave them; the min now resolves to 1040×700 via Task 1.)

- [ ] **Step 2: SettingsWindowController — open larger than the new min.** Change the default contentRect:
```swift
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
```
(The `contentMinSize` already uses `StatsConfig.minWindow*` → now 1040×700.)

- [ ] **Step 3: OnboardingView — solid page background.** At `OnboardingView.swift:37`, replace `.frostWindowBackground()` with:
```swift
        .background(Theme.pageBackground)
```

- [ ] **Step 4:** `swift build` green; **Commit** `feat(ui): solid content background (frosted sidebar/shell kept) + larger window`.

---

## Task 4: OverviewPage — fixed-width, centered

**Files:** Modify `Settings/OverviewPage.swift`.

- [ ] **Step 1: Wrap content in a 1200-max centered column** (widen → gutters grow). Replace `body`:
```swift
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                HStack(spacing: 14) {
                    accuracyCard
                    mainStatsGrid
                }
                .frame(height: 112)

                StatsPanel()
            }
            .frame(maxWidth: StatsConfig.contentMaxWidth)   // cap content width
            .frame(maxWidth: .infinity)                     // center it; gutters absorb extra width
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
        }
    }
```

- [ ] **Step 2:** `swift build` green; **Commit** `feat(ui): Overview fixed-width centered layout (1200, gutters on widen)`.

---

## Task 5: StatsPanel — fixed 4-col grid + heatmap hover tooltip + Theme colors

**Files:** Modify `Settings/Overview/StatsPanel.swift`.

- [ ] **Step 1: Fixed 4-column grid** (no adaptive). In `statGrid`, replace the columns:
```swift
        let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 4)
```
(Within the 1200-capped parent, four equal columns — no balloon.)

- [ ] **Step 2: Heatmap empty cell → `Theme.heatEmpty`.** In `ActivityHeatmap.heatColor`:
```swift
    private func heatColor(_ level: Int) -> Color {
        level == 0 ? Theme.heatEmpty : Brand.accent.opacity(StatsConfig.heatOpacity[level])
    }
```

- [ ] **Step 3: Heatmap hover tooltip** (styled bubble, anchored to the hovered cell, hides on exit). Add `@State private var hovered: HeatCell?` to `ActivityHeatmap`, format a date "M月D日", and attach a `.popover` to each cell driven by hover:
```swift
    @State private var hovered: HeatCell?

    private func cellDateLabel(_ iso: String) -> String {
        // "yyyy-MM-dd" → "M月D日"
        let parts = iso.split(separator: "-")
        guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) else { return iso }
        return "\(m)月\(d)日"
    }
```
In the cell `ForEach`, replace the `.help(...)` cell with:
```swift
                ForEach(cells, id: \.dayOrdinal) { cell in
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(heatColor(cell.level))
                        .frame(width: 12, height: 12)
                        .onHover { inside in
                            if inside { hovered = cell }
                            else if hovered?.dayOrdinal == cell.dayOrdinal { hovered = nil }
                        }
                        .popover(isPresented: Binding(
                            get: { hovered?.dayOrdinal == cell.dayOrdinal },
                            set: { if !$0 { hovered = nil } }
                        ), arrowEdge: .top) {
                            Text("\(cellDateLabel(cell.date)) — \(cell.chars)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Theme.textPrimary)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Theme.cardBackground)
                        }
                        .accessibilityLabel("\(cell.date), \(cell.chars) 字")
                }
```
(Use the `GridItem(.fixed(13))` row size per the spec if not already; keep the horizontal `ScrollView`.)

- [ ] **Step 4: Theme text colors in the panel.** In `MiniStatCard`, set the big number `.foregroundColor(accent ? Brand.accent : Theme.textPrimary)`, the icon + label + unit `.foregroundColor(Theme.textSecondary)`. In section headers/footer, use `Theme.textSecondary`. (Numbers stay 30pt bold rounded `.monospacedDigit()`.)

- [ ] **Step 5:** `swift build` green; self-test 118/0; **Commit** `feat(ui): fixed 4-col grid + heatmap hover tooltip + solid Theme colors`.

---

## Task 6: On-device verification (manual)

- [ ] Build `.app`, launch, open Overview (dark + light system appearance). Confirm vs the demo + acceptance §10:
  - Content is **solid** (no frosted gray bleed); sidebar + window edges still frosted glass.
  - Widen window → **content width fixed, gutters grow**, cards don't stretch; short window → bottom **scrolls**, not compressed; can't go below 1040×700.
  - 节省时间 + 当前连续 accent; big bold mono numbers; "平均速度 ✓修正".
  - Heatmap fills the year grid + legend + **hover bubble "M月D日 — N"**; 24h 24 bars + peak; footer complete.
  - Light mode: solid light theme reads clean (not a dark island).
- [ ] `grep -rn "scaleEffect\|GeometryReader" Sources/flowtype/Settings` → only the capsule's breathing (none in Settings); confirm no ratio-sizing.
- [ ] Build + push; note any remaining demo gap.

---

## Self-Review
- Spec coverage: solid Theme (T1) + GlassCard solid (T2) + solid content bg keeping frosted shell/sidebar (T3) + onboarding solid (T3) + adaptive (Theme via Color(light:dark:)) ✓; fixed-width centered + min 1040×700 (T1+T3+T4) ✓; fixed 4-col (T5) ✓; heatmap tooltip + demo colors (T5) ✓; no Swift Charts change ✓.
- Type consistency: `Theme.{pageBackground,cardBackground,cardBorder,textPrimary,textSecondary,heatEmpty,accent,cardRadius,sectionSpacing}`, `StatsConfig.{minWindowWidth=1040,minWindowHeight=700,contentMaxWidth=1200,heatOpacity}`, `glassCard(active:cornerRadius:)` API unchanged. `FrostBackground` retained (shell).
