# Overview 1:1 Replica + Solid Content Theme — Design Spec

**Date:** 2026-06-03
**Status:** Approved (owner sign-off 2026-06-03)
**Source:** owner PRD「概览页 1:1 复刻演示图」+ two clarifying decisions.
**Supersedes:** the adaptive-`GridItem(.adaptive)` column approach (→ fixed-width centered) **and** the frosted **content** surfaces (→ solid). The Frost window **shell + sidebar** stay.

---

## 1. The reconciliation (decisions)

The demo is a clean solid-dark dashboard; the shipped Frost made content read muddy/gray. Resolution:

- **Content panes become SOLID/opaque** (Overview/Settings/History/Vocab/Style): solid page background + solid cards (no `.thinMaterial`, no window vibrancy bleeding through).
- **The Frost window shell + sidebar STAY** frosted/translucent (premium glass at the chrome). `FrostBackground` remains behind the window; the sidebar stays transparent over it; **only the detail/content region gets a solid background on top of the frost.**
- **Adaptive**: provide BOTH a solid **dark** and solid **light** theme, following the existing 浅色/深色/随系统 switch.
- The floating **capsule** is unchanged (its own HUD material).

## 2. Theme tokens (new `UI/Theme/Theme.swift`, adaptive via `Color(light:dark:)`)

| Role | Dark | Light |
|---|---|---|
| Page background (solid, opaque) | `#0C0C0F` | `#F5F5F7` |
| Card background (solid) | `#17171C` | `#FFFFFF` |
| Card border (1px) | white 0.06 | black 0.06 |
| Primary text (numbers) | `#F5F5F7` | `#1A1A1C` |
| Secondary text | `#8A8A92` | `#6B6B72` |
| Accent | `#A99BFF` | `#8E7DF5` |
| Heatmap empty cell | `#1C1C22` | `#E6E6EA` |
| Card radius | 14 | 14 |
| Card padding | 16 | 16 |
| Section spacing | 20 | 20 |

All thresholds/conversions/sizes already live in `StatsConfig`; visual tokens live in `Theme`. Nothing hard-coded in views.

## 3. Surface refactor (what changes app-wide)

- **`GlassCard` → solid:** fill `Theme.cardBackground` (opaque), `RoundedRectangle(14, .continuous)`, 1px `Theme.cardBorder`; no `.thinMaterial`, no shadow. `active` = accent border + faint accent wash. This propagates to **all** `.glassCard` call sites → every content card becomes solid. (Keep the `glassCard(active:cornerRadius:)` API.)
- **Content background solid:** the detail/content region paints `Theme.pageBackground` (opaque) on top of the window frost. Implement at the `MainWindowView` detail container (so all pages inherit), while the sidebar stays transparent (frost shows behind it). Onboarding likewise gets the solid page background.
- **Keep:** `FrostBackground` window shell, the frosted sidebar, the capsule.

## 4. Overview layout — fixed-width, centered, scroll-not-compress (§1 of PRD)

- Root: `ScrollView { VStack(alignment:.leading, spacing:20){ … }.frame(maxWidth: StatsConfig.contentMaxWidth).frame(maxWidth:.infinity).padding(.horizontal,32).padding(.vertical,24) }`. `contentMaxWidth = 1200`.
- **Widen window → content width fixed, gutters grow** (the inner `.frame(maxWidth:1200)` capped, outer `.frame(maxWidth:.infinity)` centers it).
- **Vertical = scroll, never compress:** every component is fixed/natural height; window shorter → bottom scrolls out of view; taller → content pinned top, blank below.
- **Min window 1040×700** via `NSWindow.contentMinSize` (the window is AppKit `SettingsWindowController`, not a SwiftUI `WindowGroup` — `windowResizability(.contentMinSize)` maps to this) + `MainWindowView.frame(minWidth:1040, minHeight:700)`.
- **Forbidden:** `.scaleEffect` for layout; `GeometryReader` ratio-sizing of fonts/padding/cards; uncapped `maxWidth:.infinity` cards. Fonts/heights are fixed points (Dynamic-Type friendly).

## 5. Components (align to demo)

- **Top row (§3):** compact personalization ring (container just wraps ring+label, ~150pt) + 4 cards (口述字数 · 节省时间 · 总口述时间 · 平均速度), one equal-height row, within the 1200 column. (Already mostly done; verify within fixed width.)
- **Tabs + range (§4):** 概览 / 应用·语言(v2 greyed) + All/30d/7d (accent selected). Range switch recomputes cards + 24h + footer. (Done.)
- **8-card grid (§5):** **fixed 4 columns** = `Array(repeating: GridItem(.flexible(), spacing:14), count:4)` (four-equal within the capped width — no balloon). Big bold `.monospacedDigit()` numbers (~30–34pt); 节省时间 + 当前连续 in accent; "平均速度 ✓修正". (Switch grid from `.adaptive` to fixed 4-col.)
- **Activity heatmap (§6):** dense last-365-days, 7-row `LazyHGrid(GridItem(.fixed(13)))`, weekday-aligned leading blanks; empty cell `Theme.heatEmpty`, active 5-level accent ramp (`0.25/0.45/0.65/0.85/1.0`); **always 最近一年, independent of range**; legend 少▢▢▢▢▢多; horizontal `ScrollView` defaulting to the right (most-recent). **NEW: hover tooltip** — `.onHover` per cell → a rounded dark popover "5月7日 — 16,572" (date + day chars) following the hovered cell, hides on exit.
- **24h (§7):** Swift Charts `BarMark`, fixed 0–23 buckets, peak/current-hour brighter accent, X-axis [0,6,12,18,23], "· 高峰 HH:00–HH:00". (Done; retint to Theme.)
- **Footer (§8):** "你已累计口述约 N 字 · 少敲了约 M 次键盘 ⌨️ · 节省的时间够看 K 部电影 🎬"; 万-format; low-value fallback (coffee); hidden at 0. (Done.)

## 6. Empty / low-data (§9) — keep

All-empty → guide card, no empty heatmap/chart. Low-data → dense heatmap (mostly empty cells) + chart render + footer fallback. All aggregates div-zero-guarded.

## 7. Files

- **New:** `UI/Theme/Theme.swift` (solid adaptive tokens); add `contentMaxWidth=1200` to `StatsConfig`.
- **Modify:** `UI/Theme/GlassCard.swift` (solid), `Settings/MainWindowView.swift` (solid detail bg + min 1040×700), `Settings/SettingsWindowController.swift` (contentMinSize 1040×700), `Settings/OnboardingView.swift` (solid page bg), `Settings/OverviewPage.swift` (fixed-width centered wrapper + top row within it), `Settings/Overview/StatsPanel.swift` (fixed 4-col grid + heatmap hover tooltip + Theme colors).
- **Keep:** `FrostBackground` (shell), frosted sidebar, `CapsuleView`/`FloatingPanel`.

## 8. Acceptance (PRD §10)

Layout: widen → content fixed + gutters grow, no stretch; short → scrolls; tall → pinned top; can't go below 1040×700; **zero** `.scaleEffect`/ratio-`GeometryReader`. Visual: content solid opaque (no frosted gray bleed), accent on 节省/当前连续, big bold mono numbers; both dark+light solid. Components: heatmap fills at 1-day/half-year/full-year + legend + date—value tooltip; 24h always 24 bars + peak; footer complete + fallback.

## 9. Non-goals

No 3rd-party charts. No App/Language tabs / 一次成稿率 (still v2/later). No change to capsule, injection, audio, model loading.
