# Frost — Adaptive Premium UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert all FlowType windows to an adaptive frosted-glass ("Frost") aesthetic — translucent window material + grain + hairline bevels + token radii + single desaturated accent + typographic discipline — light by day, dark by night.

**Architecture:** Centralize the look in shared theme primitives (`Brand` tokens, a `FrostBackground` window material, a `GrainOverlay`, an upgraded `GlassCard`), make the windows transparent so the material samples the desktop, then drop each page's opaque background so the frost shows through. Pages that already use `.glassCard(...)` inherit the upgrade automatically.

**Tech Stack:** Swift 6.2, SwiftUI + AppKit (`NSVisualEffectView`, `NSWindow`), Core Image (cached grain).

**Spec:** `docs/superpowers/specs/2026-06-03-frost-adaptive-ui-design.md`

**Verification reality:** This is a visual refactor; there is almost no pure logic to unit-test. Tasks verify with `swift build` (must stay green) + the repo self-test (`swift run FlowType --self-test`, must stay 78/0, i.e. no regression), and the real gate is the on-device light+dark matrix in the final task. SourceKit "Cannot find X" diagnostics lag — trust `swift build`.

---

## File Structure

- **Modify** `Sources/flowtype/UI/Theme/Brand.swift` — add adaptive `Color(light:dark:)` helper, desaturated adaptive `accent`, and a `Radius` token scale. Keep `gradient`/`gradientH` (capsule still uses them).
- **Create** `Sources/flowtype/UI/Theme/GrainOverlay.swift` — cached monochrome noise `Image` + `.grain()` modifier.
- **Create** `Sources/flowtype/UI/Theme/FrostBackground.swift` — `FrostMaterial` (NSVisualEffectView rep) + `FrostBackground` view + `.frostWindowBackground()` modifier.
- **Modify** `Sources/flowtype/UI/Theme/GlassCard.swift` — frost recipe: `.thinMaterial` + adaptive hairline bevel + `Radius.card` + adaptive shadow; `active` → solid accent (no gradient).
- **Modify** `Sources/flowtype/UI/Theme/StatValue.swift` — `.monospacedDigit()` on the big number.
- **Modify** `Sources/flowtype/Settings/SettingsWindowController.swift` + `Sources/flowtype/Settings/OnboardingWindowController.swift` — transparent window chrome.
- **Modify** `Sources/flowtype/Settings/MainWindowView.swift` — frost shell behind the split view, clear sidebar background, accent tint.
- **Modify** the five page roots — drop the opaque `windowBackgroundColor` background: `OverviewPage.swift`, `SettingsView.swift`, `HistoryPage.swift`, `VocabPage.swift`, `StylePage.swift` (+ `OnboardingView.swift`).

---

## Task 1: Brand tokens — adaptive accent + Radius scale

**Files:** Modify `Sources/flowtype/UI/Theme/Brand.swift`

Current file is `import SwiftUI` + `enum Brand` with `purple`, `blue`, `accent = purple`, `gradient`, `gradientH`.

- [ ] **Step 1: Add AppKit import + adaptive color helper + replace `accent` + add `Radius`.**

Change the import line `import SwiftUI` to:
```swift
import SwiftUI
import AppKit
```

Replace the line `static let accent = purple` with a desaturated, appearance-adaptive accent:
```swift
    /// Single desaturated accent — the ONLY accent in window UI (active row, primary button,
    /// live dot). Adapts: a touch deeper in light mode, lighter in dark. Gradient stays on the capsule.
    static let accent = Color(light: Color(red: 0.42, green: 0.30, blue: 0.90),   // ~#6B4DE6
                              dark:  Color(red: 0.61, green: 0.50, blue: 0.88))   // ~#9B7FE0
```

Append, after the closing `}` of `enum Brand`:
```swift
extension Brand {
    /// Token radius scale — every rounded shape uses one of these, `style: .continuous`.
    enum Radius {
        static let window: CGFloat = 18
        static let panel:  CGFloat = 14
        static let card:   CGFloat = 10
        static let chip:   CGFloat = 6
    }
}

extension Color {
    /// Appearance-adaptive color: resolves `light` in Aqua, `dark` in Dark Aqua.
    init(light: Color, dark: Color) {
        self = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        }))
    }
}
```

- [ ] **Step 2: Build.**

Run: `set -o pipefail && swift build 2>&1 | tail -4`
Expected: `Build complete!`

- [ ] **Step 3: Commit.**
```bash
git add Sources/flowtype/UI/Theme/Brand.swift
git commit -m "feat(ui): adaptive desaturated accent + Radius token scale"
```

---

## Task 2: Grain overlay primitive

**Files:** Create `Sources/flowtype/UI/Theme/GrainOverlay.swift`

- [ ] **Step 1: Create the file.**
```swift
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// A single cached monochrome noise tile, generated once. Tiling this at low opacity with
/// `.softLight` is the "matte" tell that stops translucent material from looking like cheap glass.
enum GrainTexture {
    static let image: Image = {
        let side = 180
        let ctx = CIContext(options: nil)
        let noise = CIFilter.randomGenerator().outputImage ?? CIImage.empty()
        let mono = noise
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputBrightnessKey: 0.0,
                kCIInputContrastKey: 1.0,
            ])
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        if let cg = ctx.createCGImage(mono, from: CGRect(x: 0, y: 0, width: side, height: side)) {
            return Image(decorative: cg, scale: 1, orientation: .up)
        }
        return Image(size: CGSize(width: 1, height: 1)) { _ in }   // transparent fallback
    }()
}

struct GrainOverlay: ViewModifier {
    var opacity: Double = 0.04
    func body(content: Content) -> some View {
        content.overlay(
            GrainTexture.image
                .resizable(resizingMode: .tile)
                .opacity(opacity)
                .blendMode(.softLight)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        )
    }
}

extension View {
    /// Overlay the cached grain texture (default 4%). Call once at the window-shell level.
    func grain(_ opacity: Double = 0.04) -> some View { modifier(GrainOverlay(opacity: opacity)) }
}
```

- [ ] **Step 2: Build.**

Run: `set -o pipefail && swift build 2>&1 | tail -4`
Expected: `Build complete!`. If `Image(size:renderer:)` is unavailable, replace the fallback line with `return Image(systemName: "circle").renderingMode(.template)` and re-build (the fallback never runs in practice).

- [ ] **Step 3: Commit.**
```bash
git add Sources/flowtype/UI/Theme/GrainOverlay.swift
git commit -m "feat(ui): cached grain-texture overlay modifier"
```

---

## Task 3: Frost window background

**Files:** Create `Sources/flowtype/UI/Theme/FrostBackground.swift`

(There is already a `VisualEffectView` rep inside `CapsuleView.swift`; do NOT reuse or rename it — create the dedicated `FrostMaterial` below so the window shell is independent.)

- [ ] **Step 1: Create the file.**
```swift
import SwiftUI
import AppKit

/// Window-level frosted material. `.behindWindow` blending samples the desktop behind a
/// transparent window, so the result is real frosted glass that adapts to light/dark.
struct FrostMaterial: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

/// The full window backdrop: translucent frosted material + subtle grain. Use behind a
/// transparent window's root view via `.frostWindowBackground()`.
struct FrostBackground: View {
    var body: some View {
        FrostMaterial(material: .hudWindow, blending: .behindWindow)
            .grain(0.04)
            .ignoresSafeArea()
    }
}

extension View {
    /// Place the adaptive frosted-glass backdrop behind a window root.
    func frostWindowBackground() -> some View { background(FrostBackground()) }
}
```

- [ ] **Step 2: Build + commit.**
```bash
set -o pipefail && swift build 2>&1 | tail -4   # expect Build complete!
git add Sources/flowtype/UI/Theme/FrostBackground.swift
git commit -m "feat(ui): FrostMaterial + frosted window background"
```

---

## Task 4: Upgrade GlassCard to the frost recipe

**Files:** Modify `Sources/flowtype/UI/Theme/GlassCard.swift`

- [ ] **Step 1: Replace the whole file** (keep the `glassCard(...)` call-site API so all existing pages keep compiling):
```swift
import SwiftUI

/// Frosted content surface, one step more opaque than the window shell so text stays legible
/// over the see-through window. Adaptive hairline bevel (lit-from-above), token radius, soft
/// appearance-aware shadow. `active: true` swaps the border to the solid accent (the gradient
/// lives only on the capsule now) for the selected/current item.
struct GlassCard: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var active: Bool = false
    var cornerRadius: CGFloat = Brand.Radius.card

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(shape.fill(.thinMaterial))
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .shadow(color: shadow, radius: active ? 12 : 8, x: 0, y: active ? 4 : 3)
    }

    private var border: AnyShapeStyle {
        if active { return AnyShapeStyle(Brand.accent) }
        let top    = scheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.55)
        let bottom = scheme == .dark ? Color.black.opacity(0.30) : Color.black.opacity(0.08)
        return AnyShapeStyle(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
    }

    private var shadow: Color {
        if active { return Brand.accent.opacity(0.22) }
        return scheme == .dark ? .black.opacity(0.28) : .black.opacity(0.10)
    }
}

extension View {
    /// Apply the unified frosted-card surface. `active: true` for the selected/current item.
    /// Default radius is `Brand.Radius.card` (10); pass `Brand.Radius.panel` (14) for large panels.
    func glassCard(active: Bool = false, cornerRadius: CGFloat = Brand.Radius.card) -> some View {
        modifier(GlassCard(active: active, cornerRadius: cornerRadius))
    }
}
```

- [ ] **Step 2: Build + self-test (no regression) + commit.**
```bash
set -o pipefail && swift build 2>&1 | tail -4         # Build complete!
swift run FlowType --self-test 2>&1 | tail -2          # 78 passed, 0 failed
git add Sources/flowtype/UI/Theme/GlassCard.swift
git commit -m "feat(ui): GlassCard frost recipe — thinMaterial, adaptive bevel, accent"
```

---

## Task 5: Transparent window chrome

**Files:** Modify `Sources/flowtype/Settings/SettingsWindowController.swift` and `Sources/flowtype/Settings/OnboardingWindowController.swift`

- [ ] **Step 1: SettingsWindowController.** After the `window.isReleasedWhenClosed = false` line (before `self.init(window: window)`), insert:
```swift
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isOpaque = false
        window.backgroundColor = .clear
```

- [ ] **Step 2: OnboardingWindowController.** Read the file, find where its `NSWindow` is configured, and add the same five lines after the window's other properties are set (before `self.init(window:)` / before it's shown). If the onboarding window has a different variable name, adapt accordingly. Keep its existing size/centering.

- [ ] **Step 3: Build + commit.**
```bash
set -o pipefail && swift build 2>&1 | tail -4   # Build complete!
git add Sources/flowtype/Settings/SettingsWindowController.swift Sources/flowtype/Settings/OnboardingWindowController.swift
git commit -m "feat(ui): transparent full-size-content window chrome for frost"
```

---

## Task 6: Frost shell in MainWindowView

**Files:** Modify `Sources/flowtype/Settings/MainWindowView.swift`

Current body is a `NavigationSplitView { List(...).listStyle(.sidebar).frame(minWidth:150,maxWidth:170) } detail: { switch ... }`.`.tint(Brand.accent).frame(minWidth:780,minHeight:520)`.

- [ ] **Step 1: Clear the sidebar's opaque list background and put the frost behind the whole split view.** Replace the `body`:
```swift
    var body: some View {
        NavigationSplitView {
            List(AppTab.allCases, selection: $selectedTab) { tab in
                Label(tab.title, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)          // let the frost show through the sidebar
            .frame(minWidth: 150, maxWidth: 170)
        } detail: {
            switch selectedTab {
            case .overview: OverviewPage()
            case .history:  HistoryPage()
            case .vocab:    VocabPage()
            case .style:    StylePage()
            case .settings: SettingsPage()
            }
        }
        .background(FrostBackground())                  // adaptive frosted-glass window backdrop
        .tint(Brand.accent)
        .frame(minWidth: 780, minHeight: 520)
    }
```

- [ ] **Step 2: Build + commit.**
```bash
set -o pipefail && swift build 2>&1 | tail -4   # Build complete!
git add Sources/flowtype/Settings/MainWindowView.swift
git commit -m "feat(ui): frosted window shell + clear sidebar in MainWindowView"
```

---

## Task 7: Drop opaque page backgrounds (let the frost through)

**Files:** Modify `OverviewPage.swift`, `SettingsView.swift`, `HistoryPage.swift`, `VocabPage.swift`, `StylePage.swift` (all under `Sources/flowtype/Settings/`)

Each page currently paints its own opaque `Color(nsColor: .windowBackgroundColor)`, which hides the window frost. Remove it on each.

- [ ] **Step 1: SettingsView, HistoryPage, VocabPage, StylePage.** In each, find the line `.background(Color(nsColor: .windowBackgroundColor))` and delete it (the page then shows the window frost). Exact locations from grep: `SettingsView.swift:49`, `HistoryPage.swift:21`, `VocabPage.swift:14`, `StylePage.swift:17`. (Read each to confirm the line before deleting.)

- [ ] **Step 2: OverviewPage** — it uses a `brandBackdrop` ZStack and a gradient accuracy ring. (a) Replace `.background(brandBackdrop)` (line 20) with nothing — delete that modifier line. (b) Delete the `brandBackdrop` computed property (the `private var brandBackdrop: some View { ZStack { Color(nsColor:.windowBackgroundColor) ... } .ignoresSafeArea() }` block, ~lines 23–33). (c) Per spec the gradient retires from windows: change the accuracy-ring stroke `Brand.gradient` (around line 43) to `Brand.accent`. Leave the rest.

- [ ] **Step 3: Build + self-test + commit.**
```bash
set -o pipefail && swift build 2>&1 | tail -4         # Build complete!
swift run FlowType --self-test 2>&1 | tail -2          # 78 passed, 0 failed
git add Sources/flowtype/Settings/OverviewPage.swift Sources/flowtype/Settings/SettingsView.swift Sources/flowtype/Settings/HistoryPage.swift Sources/flowtype/Settings/VocabPage.swift Sources/flowtype/Settings/StylePage.swift
git commit -m "feat(ui): drop opaque page backgrounds; retire ring gradient to accent"
```

---

## Task 8: Frost the onboarding window

**Files:** Modify `Sources/flowtype/Settings/OnboardingView.swift`

- [ ] **Step 1:** Read `OnboardingView.swift`. Find its root container's background. If it paints an opaque color (e.g. `windowBackgroundColor` or a solid fill), replace that with `.frostWindowBackground()` on the root view so onboarding matches the frost. If it has no explicit background, add `.frostWindowBackground()` to the outermost view. Keep all content/layout unchanged.

- [ ] **Step 2: Build + commit.**
```bash
set -o pipefail && swift build 2>&1 | tail -4   # Build complete!
git add Sources/flowtype/Settings/OnboardingView.swift
git commit -m "feat(ui): frost the onboarding window"
```

---

## Task 9: StatValue monospaced digits

**Files:** Modify `Sources/flowtype/UI/Theme/StatValue.swift`

- [ ] **Step 1:** In `StatValueView.body`, the big number `Text(seg.number).font(.system(size: numberSize, weight: .bold))` — add `.monospacedDigit()` right after the `.font(...)`:
```swift
                Text(seg.number)
                    .font(.system(size: numberSize, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(.primary)
```

- [ ] **Step 2: Build + self-test + commit.**
```bash
set -o pipefail && swift build 2>&1 | tail -4         # Build complete!
swift run FlowType --self-test 2>&1 | tail -2          # 78 passed, 0 failed
git add Sources/flowtype/UI/Theme/StatValue.swift
git commit -m "feat(ui): monospaced digits on stat values"
```

---

## Task 10: On-device verification matrix (manual)

No code. The visual result is system-dependent; this is the real gate.

- [ ] **Step 1: Build + launch.**
```bash
set -o pipefail && ./scripts/build-app.sh 2>&1 | tail -5
pkill -x FlowType 2>/dev/null; sleep 1; xattr -cr build/FlowType.app && open build/FlowType.app
```

- [ ] **Step 2: Verify in BOTH appearances** (System Settings → Appearance → Light, then Dark), each window: Overview, History, Vocab, Style, Settings, Onboarding:
  - Window reads as **frosted glass, 通透** (desktop tint visible) but text on cards stays legible.
  - Grain is present but subtle; no banding; smooth scrolling (no per-frame regen).
  - Accent (desaturated purple) appears ONLY on the active sidebar row, primary buttons, and the live dot — no purple→blue gradient anywhere in the window.
  - Radii/typography consistent; stat numbers monospaced; no stock-control eyesores that clash.
  - The recording capsule still matches the family.

- [ ] **Step 3: Tune (expected).** If the sidebar double-frosts or a column stays opaque, adjust the `.scrollContentBackground(.hidden)` / column backgrounds. If 通透 hurts legibility, bump card material a step or add a faint tint. If grain is invisible or too strong, adjust the 0.04. If light-mode frost washes out on bright wallpaper, raise the light tint. Record what was changed.

- [ ] **Step 4: Record results** in `docs/feature-inventory.md` (add a "Frost UI — verification" batch with the light+dark matrix), commit, and push `flowtype-local`.

---

## Self-Review

**Spec coverage:** material shell (T3, T5, T6); adaptive light/dark (T1 accent, T3 material auto-adapts, T4 bevel/shadow by scheme); 通透 (T3 hudWindow + T4 thinMaterial cards); grain (T2); hairline bevel (T4); radius scale (T1 + T4 default); single accent / gradient retired (T1, T4, T7b); typography monospaced digits (T9); all windows (T6–T8); capsule untouched ✓; macOS-26 opt-out + tuning (T10). All spec §3 tokens have a task.

**Placeholder scan:** primitives (T1–T4, T9) have complete code; per-page tasks (T5 onboarding, T7, T8) specify exact lines/transforms to apply after reading the file (uniform pattern, not vague). No TBD.

**Type consistency:** `Brand.Radius.card/panel/window/chip`, `Brand.accent`, `Color(light:dark:)`, `.grain(_:)`, `FrostMaterial`, `FrostBackground`, `.frostWindowBackground()`, `.glassCard(active:cornerRadius:)` — names consistent across tasks. `GlassCard` default radius is `Brand.Radius.card` (defined in T1, used in T4). `FrostBackground` (T3) used in T6/T8.
