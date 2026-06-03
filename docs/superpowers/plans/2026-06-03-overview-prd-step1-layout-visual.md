# Overview PRD — Step 1: §1 Layout Model + §2 Visual Style ONLY

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`).
> **SCOPE GUARD:** Implement ONLY PRD §1 (layout model) + §2 (visual style). Do NOT touch components (§3 IA restructure, §4 2×2, §5 achievements, §6 milestones, §7 sidebar settings, §8 heatmap, §9 24h, §10 footer, §11 metrics, §12 SQLite). After Task 3, **STOP for owner acceptance.**

**Goal:** Match the prototype's solid-dark look + fixed-width-centered layout. The prototype `docs/files/overview-prototype.html` is the visual source of truth (exact colors/spacing/fonts); `docs/files/overview-final-prd.md` is the spec.

**Source values (from the HTML inline styles):** page `#0C0C0F`, sidebar `#101013`, card `#17171C`, card border `rgba(255,255,255,0.07)` 0.5px, radius **12**, text `#F2F2F5` / secondary `#8A8A92`, purple `#8E7DF5` (fill) / `#A99BFF` (bright) / `#B9AEFF` (text), amber `#FFB454`, heat-empty `#1C1C22`. The window is **fully solid** (no vibrancy/frost anywhere).

**Verify:** `swift build` green; `swift run FlowType --self-test` stays **118/0**; real gate = owner acceptance of the look (Task 3).

---

## Task 1: Theme tokens (exact prototype) + radius 12 + content width 960

**Files:** Modify `UI/Theme/Theme.swift`, `UI/Theme/Brand.swift`, `Core/StatsConfig.swift`, `UI/Theme/GlassCard.swift`.

- [ ] **Step 1: Add a hex Color init** (append to `UI/Theme/Theme.swift`, top-of-file or extension):
```swift
extension Color {
    init(hex: UInt) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8)  & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
```

- [ ] **Step 2: Replace the `Theme` enum** with the exact prototype tokens (adaptive — dark = prototype-exact; light = a sensible solid light per the owner's "也要浅色版"):
```swift
enum Theme {
    static let pageBackground    = Color(light: Color(hex: 0xF5F5F7), dark: Color(hex: 0x0C0C0F))
    static let sidebarBackground = Color(light: Color(hex: 0xECECEE), dark: Color(hex: 0x101013))
    static let cardBackground    = Color(light: .white,               dark: Color(hex: 0x17171C))
    static let cardBorder        = Color(light: Color.black.opacity(0.07), dark: Color.white.opacity(0.07))
    static let textPrimary       = Color(light: Color(hex: 0x1A1A1C), dark: Color(hex: 0xF2F2F5))
    static let textSecondary     = Color(light: Color(hex: 0x6B6B72), dark: Color(hex: 0x8A8A92))
    static let accent            = Color(light: Color(hex: 0x6B4DE6), dark: Color(hex: 0x8E7DF5))  // fill
    static let accentBright      = Color(light: Color(hex: 0x6B4DE6), dark: Color(hex: 0xA99BFF))  // icons/peak
    static let accentText        = Color(light: Color(hex: 0x6B4DE6), dark: Color(hex: 0xB9AEFF))  // data numbers/active text
    static let warm              = Color(light: Color(hex: 0xE0901E), dark: Color(hex: 0xFFB454))  // achievements
    static let heatEmpty         = Color(light: Color(hex: 0xE6E6EA), dark: Color(hex: 0x1C1C22))
    static let cardRadius: CGFloat = 12
    static let cardPadding: CGFloat = 14
    static let sectionSpacing: CGFloat = 18
}
```
(Removes the `static let accent = Brand.accent` line — `Theme.accent` is now its own token.)

- [ ] **Step 3: Refresh the global accent** to the prototype purple. In `UI/Theme/Brand.swift`, change `Brand.accent` to:
```swift
    static let accent = Color(light: Color(red: 0.557, green: 0.490, blue: 0.961),   // #8E7DF5
                              dark:  Color(red: 0.663, green: 0.608, blue: 1.0))      // #A99BFF
```
(So existing accent usages — sidebar active, buttons — read as the brighter prototype purple now.)

- [ ] **Step 4: Content width → 960 (PRD §1.1).** In `Core/StatsConfig.swift`, change `contentMaxWidth` from 1200 to:
```swift
    static let contentMaxWidth: CGFloat = 960
```

- [ ] **Step 5: GlassCard radius → 12 + exact border.** `UI/Theme/GlassCard.swift` already defaults `cornerRadius` to `Theme.cardRadius` (now 12) — confirm. No code change unless it hardcodes a radius. (The border already uses `Theme.cardBorder` = white .07.)

- [ ] **Step 6:** `swift build` green; `swift run FlowType --self-test` 118/0; **Commit** `feat(ui): exact prototype theme tokens (solid dark) + radius 12 + 960 content width + accent refresh`.

---

## Task 2: Fully solid window (no frost anywhere) + confirm §1 layout

**Files:** Modify `Settings/MainWindowView.swift`. (Verify only: `OverviewPage.swift`, `SettingsWindowController.swift`.)

- [ ] **Step 1: De-frost the window — solid sidebar + solid shell.** In `MainWindowView.body`: the sidebar currently shows the window frost; the HStack uses `.background(FrostBackground())`. Replace with solid: give the `sidebar` a `Theme.sidebarBackground` and the HStack a `Theme.pageBackground` (drop `FrostBackground()`). The `detail` already has `Theme.pageBackground`. Result:
```swift
    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .background(Theme.sidebarBackground)
            Divider().overlay(Color.white.opacity(0.06))
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.pageBackground)
        }
        .background(Theme.pageBackground)         // solid shell, no frost
        .tint(Brand.accent)
        .frame(minWidth: StatsConfig.minWindowWidth, minHeight: StatsConfig.minWindowHeight)
    }
```
(`FrostBackground` is now unused in the window — leave the file; it's still referenced by nothing else. Do NOT delete it this round.)

- [ ] **Step 2: Verify §1 acceptance items (no code unless broken):**
  - `OverviewPage.body` already wraps content in `.frame(maxWidth: StatsConfig.contentMaxWidth)` then `.frame(maxWidth: .infinity)` then padding — the **cap-then-center** order (PRD §1.1). It's now 960. Confirm present and in that order.
  - `MainWindowView` + `SettingsWindowController` enforce min 1040×700 via `StatsConfig.minWindow*`. Confirm.
  - `grep -rn "scaleEffect\|GeometryReader" Sources/flowtype/Settings Sources/flowtype/UI` → none for layout (capsule breathing is elsewhere). Confirm clean.

- [ ] **Step 3:** `swift build` green; self-test 118/0; **Commit** `feat(ui): fully solid window (de-frost sidebar/shell) per prototype`.

---

## Task 3: Build `.app` → STOP for owner acceptance

- [ ] Build `.app`, relaunch. Owner verifies vs the prototype: content area is **solid dark** `#0C0C0F`, sidebar `#101013`, cards `#17171C` radius 12, text/purple/amber match; **widen window → content fixed-width centered, gutters grow** (not stretched); shorter → scrolls; can't go below 1040×700; light mode reads as a clean solid light theme.
- [ ] **Do NOT proceed to §3+ components.** Report the build is ready and wait for the owner's acceptance before planning the component rebuild.

---

## Self-Review
- Scope: ONLY §1 (960 width + cap-then-center confirmed + min 1040×700 + no scaleEffect) and §2 (exact solid tokens, radius 12, de-frost, accent refresh). No component/IA/milestone/SQLite work. ✓
- Visual source of truth = the HTML inline styles (page/sidebar/card/border/text/purple/amber/heat-empty/radius transcribed exactly into `Theme`). ✓
- Type consistency: `Theme.{pageBackground,sidebarBackground,cardBackground,cardBorder,textPrimary,textSecondary,accent,accentBright,accentText,warm,heatEmpty,cardRadius=12,cardPadding,sectionSpacing}`, `Color(hex:)`, `StatsConfig.contentMaxWidth=960`, `Brand.accent` (refreshed). `FrostBackground` retained but unused.
