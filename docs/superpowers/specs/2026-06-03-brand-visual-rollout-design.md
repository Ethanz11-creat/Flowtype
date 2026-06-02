# Design: Brand Visual Rollout — "Restrained Adaptive Glass"

**Date:** 2026-06-03
**Status:** Approved (design), pending implementation plan
**Scope:** All app windows/pages. The recording capsule is the *source* of the brand look and is **not** changed.

## 1. Goal

FlowType today is "two skins": the recording capsule is a polished dark-glass, purple-blue
branded HUD, while every window/page is neutral macOS gray/white with a hodgepodge of accent
colors (ASR blue, LLM purple, recording red, trigger orange, permission green). Bring the
capsule's brand language **down into the windows** — but **restrained**, so it reads premium,
not tiring.

**Chosen direction: C, restrained** — adaptive glass (system materials, auto light/dark) with
the brand purple→blue used as a *point* accent, not a flood.

## 2. Current state

- Windows use semantic system colors + flat `controlBackgroundColor` cards with faint shadows.
- Section accents are inconsistent (per-section colors). No single brand color.
- Capsule (`CapsuleView`, `AudioVisualizer`) already uses the purple→blue brand; the audio
  bars were just rebuilt with a purple→blue gradient as a deliberate first step.
- Pages: `MainWindowView` (sidebar container), `OverviewPage`, `HistoryPage`, `VocabPage`,
  `StylePage`, `SettingsView` + `SettingsPage+*.swift` sections + cards (`QwenModelStatusCard`,
  `ServiceConfigCard`, `ProviderRow`, `ProviderEditSheet`, `SettingsFieldComponents`),
  `OnboardingView`.

## 3. Design language: "Restrained Adaptive Glass"

**Principle: the brand color is a point accent, not a background.** Glass unifies, but stays
quiet; semantic colors (error/success/warning) are preserved.

### 3.1 Materials & light/dark
- Card/surface backgrounds use **translucent system material** (`.regularMaterial` /
  `.ultraThinMaterial`) so they adapt to light/dark automatically and read as "glass."
- Glass is **airy/transparent** (the restrained version: noticeably see-through, strong blur),
  not milky.
- Text uses semantic colors (`.primary`/`.secondary`) — auto-adapts.
- A very faint brand-tint backdrop is allowed (subtle purple/blue radial glow in a page's
  corners) but must stay barely-there.

### 3.2 Brand color
- **Brand gradient** (purple→blue), the hero accent: `LinearGradient` from
  `brandPurple = Color(red: 0.52, green: 0.36, blue: 1.0)` (~#855CFF) to
  `brandBlue = Color(red: 0.30, green: 0.63, blue: 1.0)` (~#4DA1FF), top-leading → bottom-trailing.
- **Solid accent** for single-color uses (selected state, links, small icons):
  `brandAccent = brandPurple` (or a slightly desaturated purple-blue; tuned in implementation).
- Used **only on anchor/active elements**: progress ring, audio bars (done), active/selected
  rows, the current-item highlight border, a subtly gradient page title, primary-action accents.
  NOT on every label or every card.

### 3.3 Accent unification
- Replace the per-section color hodgepodge with the **single brand accent** for decorative
  section headers/icons.
- **Keep semantic colors** where they carry meaning: error = red, success = green, warning =
  orange (e.g. permission-granted green check, mic-unavailable orange, error cards). The brand
  color does not override status meaning.

### 3.4 Glass card (one reusable style)
A single card treatment used everywhere:
- background: translucent material (airy), corner radius ~12–13.
- border: hairline light stroke (`Color.white.opacity(~0.5)` in light; adapts via material).
- shadow: soft, low (`~0.06–0.08` black, small radius). No heavy drop shadows.
- The **active/selected** card swaps its border to a brand-gradient/brand-accent stroke +
  a *very* subtle glow — this is the only place glow appears on cards.

### 3.5 Glow restraint
- Soft glow appears on **one hero anchor per page** at most (e.g. the Overview progress ring),
  and on active/selected items. Never glow every card. Low intensity.

### 3.6 Number typography (stat values)
- Values **with units** (总时长 / 省下 / 语速): render as **big number + small unit, with a
  space** — e.g. `2 小时 14 分钟` where `2`/`14` are ~22pt bold and `小时`/`分钟` are ~11pt,
  muted (`.secondary`), space before/after the unit.
- **字数 stays plain** (a single large number, e.g. `18,402`).
- Implemented as one reusable view, e.g. `StatValueView(number:unit:)` / a number+unit builder,
  with a pure formatter so it is unit-testable.

### 3.7 Font
- **Keep the system font for now** — do NOT change the typeface in this work.
- Centralize the font choice so a future swap is a one-place change: a single
  `Font` extension / `brandFont(...)` helper that today returns the system font. (The owner
  will pick a custom font later and ask to switch; this makes that trivial.)

## 4. Shared design layer (build once, use everywhere)

Create a small theme module (e.g. `Sources/flowtype/UI/Theme/`):
- `Brand.swift` — `brandPurple`, `brandBlue`, `brandGradient`, `brandAccent` (+ soft variants).
- `GlassCard.swift` — a `ViewModifier` (`.glassCard()` / `.glassCard(active:)`) implementing
  §3.4 (material + border + radius + shadow; active variant adds the brand stroke/glow).
- `StatValueView.swift` — the §3.6 number+unit typography, plus a pure helper to split a
  formatted value into (number, unit) parts (testable).
- `BrandFont.swift` — the §3.7 centralized font (returns system font today).
- `SectionHeader.swift` (or extend existing) — brand-accented section header used across
  Settings sections and pages.

Then refactor each page/card to use these, removing the per-section ad-hoc colors and one-off
card styling.

## 5. Rollout (apply the language, page by page)

1. **Foundation** — the shared theme module above (§4). No visual change yet beyond making the
   primitives exist.
2. **OverviewPage** — the "face": glass stat cards, brand progress ring, number typography,
   fill the empty lower half is OUT OF SCOPE (layout content is a separate concern) — only
   restyle existing elements.
3. **Settings** (`SettingsView` + `SettingsPage+*` + the cards) — unify section headers to the
   brand accent; `QwenModelStatusCard` / `ServiceConfigCard` / `ProviderRow` / `ProviderEditSheet`
   adopt `.glassCard()`; active provider uses the brand-active card; keep status colors
   (green/orange/red) semantic.
4. **HistoryPage / VocabPage / StylePage** — `.glassCard()` for their cards/rows; the
   mode/category chips and "current/active" highlights use the brand accent; keep the mode
   colors that are *informational* if they must distinguish categories (decision per page —
   default to brand accent + neutral, only keep distinct hues where they encode data).
5. **OnboardingView** — apply the brand accent + glass to the step cards and the progress dots
   (the brand gradient on the active dot), so onboarding stops looking unbranded.
6. **MainWindowView** — sidebar selection uses the brand accent; optional faint brand backdrop.

## 6. Out of scope

- Changing the typeface (font swap is deferred to the owner's future pick — only centralization
  now).
- The recording capsule / `AudioVisualizer` (already branded; unchanged).
- The capsule's `SessionState` colors in `PipelineOrchestrator` (those encode recording states).
- New layout/content (e.g. filling the Overview's empty lower half) — restyle only.
- Dark-mode-only or light-mode-only designs — everything adapts via system materials.

## 7. Testing

- The only pure-logic piece is the number/unit split for `StatValueView` — unit-test it in the
  self-test runner (e.g. "2小时14分钟" / "142字/分" / "18,402" split into the right number/unit
  parts). The rest (materials, colors, glow, layout) is visual and verified manually.

## 8. Risks / open points

- **Material legibility:** very transparent glass over a busy desktop can hurt contrast; tune
  material opacity/blur on device, and ensure text stays `.primary`/`.secondary` for contrast.
- **Which mode/category hues to keep:** History mode chips and Style category badges currently
  use distinct colors that *encode information*; decide per-element whether to keep a distinct
  hue (informational) or fold into brand accent (decorative). Default: fold decorative ones,
  keep genuinely-informational ones.
- **Brand color exact values** (§3.2) are starting points; fine-tune for light AND dark on
  device.
- **Glow/shadow intensity** tuned on device to avoid the "tiring" feel the owner flagged.
