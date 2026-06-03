# Frost — Adaptive Premium UI Design Spec

**Date:** 2026-06-03
**Status:** Approved (owner sign-off 2026-06-03)
**Topic:** Elevate FlowType's window UI to a premium **frosted-glass ("Frost")** aesthetic, adaptive to system appearance, applied across all windows.

---

## 1. Decision summary (all locked with owner)

| Decision | Choice |
|---|---|
| Direction | **Frost** — translucent frosted glass (Raycast / macOS HUD lineage), the window family-resembling the recording capsule |
| Appearance | **Adaptive** — dark frosted at night, light frosted by day, follows system (`NSVisualEffectView` adapts automatically) |
| Transparency | **通透 (see-through)** — the more translucent level; desktop tint reads through. Content cards sit a touch more opaque for legibility |
| Scope of v1 | **All windows in one sweep** — Overview, History, Vocab, Style, Settings sections, Onboarding, main-window shell + sidebar |
| Grain | **Yes**, ~0.04 monochrome noise, `.softLight`, on the window shell |
| Accent | **One** desaturated brand purple, only on: active sidebar row, primary button, live recording dot. Purple→blue **gradient retires to the capsule only** |
| Typography | **System font (SF Pro)** — no display typeface (owner: keep system for now); add tracking + monospaced digits + weight discipline |
| Radii | Tight token scale: **window 18 · panel 14 · card 10 · chip 6**, all `.continuous` |
| Density | **Compact** (tighten sidebar + grids toward Raycast density) |
| macOS 26 | **Opt out of Liquid Glass** (it's specular/glossy — opposite of matte frost); keep our material |

**The capsule (`CapsuleView`/`FloatingPanel`) is the existing reference and changes only to share the new tokens.** This is an elevation of the current `GlassCard`/`Brand` system, not a rebuild.

## 2. Why (problem being solved)

Today every page is a flat opaque `Color(nsColor: .windowBackgroundColor)` with `.ultraThinMaterial` cards that can only blur *within-window* content — so there's **no real depth**; controls are 100% stock SwiftUI; borders/shadows are too timid to separate anything; radii are a freehand grab-bag (6/8/10/12/35); color is sprinkled inconsistently. The one premium surface (the `hudWindow` capsule) is an orphan. Frost brings the windows up to the capsule and gives the app one coherent, high-end material language.

## 3. Design tokens (the system)

All tokens are **appearance-adaptive** (a dark value + a light value), exposed through the theme layer so pages never hard-code raw values.

### 3.1 Material / translucency (通透)
- **Window shell:** `NSVisualEffectView`, material **`.hudWindow`** (frosted/translucent), blending **`.behindWindow`**, `state = .active`, wrapped in an `NSViewRepresentable`. The host window must set `isOpaque = false`, `backgroundColor = .clear`, `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`, and full-size content so the material samples the desktop behind.
- **Content cards / panels:** SwiftUI `.thinMaterial` (one step more opaque than the shell) so text stays legible over the 通透 shell. This is the visible "frost layering."
- **Sidebar:** `.hudWindow` or `.sidebar` material, continuous with the shell.
- 通透 tuning happens on-device; the structure is material-first, not a fixed opacity.

### 3.2 Grain
- A single cached monochrome noise texture (generate once via `CIRandomGenerator` → desaturate → static `Image`, or bundle a small tiling PNG), tiled, `.blendMode(.softLight)`, opacity **~0.04**, `allowsHitTesting(false)`, applied at the **window shell** layer (not on every card). Kills the plastic flatness that makes thin material look like cheap CSS glass.

### 3.3 Hairline border / bevel (adaptive)
- `strokeBorder`, `lineWidth = 1 / displayScale`, **inner**.
- Dark: asymmetric bevel — top edge `white opacity 0.08–0.10`, bottom `black 0.25–0.30` (lit-from-above).
- Light: top `black 0.05–0.07`, soft; cards also get a soft layered shadow (`0 1px 2px black 0.04` + `0 8px 22px black 0.06`).
- Applied to **interactive surfaces only**; non-interactive regions get no border ("no card unless it holds an interaction").

### 3.4 Radius scale
- `Radius.window = 18 · panel = 14 · card = 10 · chip = 6`, every shape `RoundedRectangle(cornerRadius:style:.continuous)`. Concentric nesting (inner = outer − padding). Replaces all freehand 6/8/10/12/35 values.

### 3.5 Color
- **One neutral ramp per appearance** built as translucent tints over the material (so frost shows through): e.g. surface `white 0.06 / 0.07` (dark), `white 0.60 / 0.66` (light).
- **One accent:** desaturated brand purple — dark `#9B7FE0`, light `#6B4DE6` — used **only** on active sidebar row, primary button, and the live recording dot.
- **Retire the purple→blue gradient from all window UI**; it lives only on the capsule.
- **Functional status colors** (model ready / error) kept but **muted**, used sparingly; decorative semantic colors collapse to neutral + accent.

### 3.6 Typography (system font)
- SF Pro. Weights: title `.semibold`, body `.regular`, micro-label `.medium` + `.secondary`.
- Tracking: `-0.4` on titles ≥ 20pt; `+0.6` + uppercase on ~11pt eyebrow labels.
- All numeric stats `.monospacedDigit()`. No display typeface in v1.

### 3.7 Density & elevation
- Compact: dim/shrink the sidebar a notch; intra-grid spacing 16 → 12; keep page padding ~24. Dark relies on bevel + window shadow for depth; light adds the soft layered card shadow.

## 4. Architecture / files

**New / extended theme layer (`Sources/flowtype/UI/Theme/`):**
- `Brand.swift` — add `Surface`, `Radius`, `Elevation`, adaptive accent tokens; retire window gradient.
- `GlassCard.swift` — upgrade to the Frost recipe: `.thinMaterial` + hairline bevel + radius token + (light) layered shadow.
- New `VisualEffectBackground` (`NSViewRepresentable`) — the window-shell material.
- New `GrainOverlay` / `NoiseTexture` modifier.

**Window chrome:** the window controller(s) (`SettingsWindowController` / main window) set `isOpaque/backgroundColor/titlebar/ fullSizeContentView`.

**Apply across (swap opaque `windowBackgroundColor` for the material shell + tokens):** `MainWindowView`, `SettingsView` (+ sections/cards), `OverviewPage`, `HistoryPage`, `VocabPage`, `StylePage`, `Onboarding`, sidebar. `StatValueView` gets `.monospacedDigit()`.

**Controls (v1 includes the high-visibility ones):** a consistent primary/secondary `ButtonStyle`, a text-field style, and the segmented picker treatment — so surfaces aren't undercut by stock controls. Exotic/rare controls inherit the treatment as encountered; a full custom control library is explicitly a later polish phase.

**Unchanged:** `CapsuleView` / `FloatingPanel` (already the target recipe; only adopt shared tokens).

## 5. Testing

- **Self-test (`--self-test`)**: cover any pure token helpers (radius scale lookup, hex→Color parsing, appearance token selection) if introduced. The visual material/grain/blur is **not** unit-testable.
- **Manual on-device matrix** (the real gate): every window in **both light and dark**; verify (a) frosted shell reads 通透 but text stays legible, (b) grain is present but subtle, (c) accent appears only on active/primary/live, (d) radii/typography consistent, (e) no stock-control eyesores, (f) performance is smooth (grain cached, no per-frame noise), (g) the capsule still matches the family.

## 6. Open risks (verify on device)

- **Legibility over 通透**: small text on the translucent shell — mitigate with the more-opaque `.thinMaterial` cards and, if needed, a touch more tint. Tune on device.
- **Performance**: grain must be a cached static image (never regenerated per frame); blurred materials over a busy desktop are GPU-cheap but confirm.
- **macOS 26 Liquid Glass**: gate/opt out so Tahoe doesn't reinterpret controls into specular glass.
- **Light-mode frost**: confirm the light frosted look holds against bright/busy wallpapers (raise tint opacity if it washes out).

## 7. Non-goals (v1)

- No display/custom typeface (owner deferred).
- No full custom-control library (only the high-visibility controls).
- No change to the capsule's behavior or the injection/audio logic.
- Not introducing a second accent or bringing the gradient back into windows.
