# Injection Target Detection — Design Spec

**Date:** 2026-06-03
**Status:** Approved (owner sign-off 2026-06-03)
**Topic:** Production-grade "is the cursor in an editable text field? → inject, else → clipboard" decision for FlowType's text delivery.

---

## 1. Problem

After transcription, FlowType must deliver the text to one of two destinations:

- **Inject** — type the text into the field where the user's cursor is.
- **Clipboard + sound** — copy the text and play a sound, when there is no usable text destination.

The current implementation decides this from the **wrong signal** and has three real defects (confirmed by a 5-agent research pass, 2026-06-03):

1. **It forks on "did the frontmost app change", not on "is there a text field".** `InjectionStage` injects whenever the bundle ID is unchanged and copies to clipboard whenever it changed. This contradicts the desired behaviour: switching to *another app's text field* should still inject there; and staying in the same app but ending on a non-text element (e.g. a clicked menu-bar item) should go to clipboard.
2. **It never verifies "editable text".** `KeyboardInjector.currentFocusState()` returns `.present` for *any* focused AX element (button, label, menu, table cell), then types into it blindly.
3. **Silent text loss + UI freeze risk.** Keystroke injection uses force-unwrapped `CGEvent`s and `post()` (which returns void); when macOS **secure input** is active (password fields, Terminal "Secure Keyboard Entry") the OS silently drops the keys while the stage logs "Injected N chars" — the transcript vanishes with no clipboard fallback. AX queries have **no messaging timeout**, so an unresponsive target app can block the main thread for ~6 s.

This is the most-reported pain: dictating into WeChat / VS Code / Cursor / a terminal wrongly diverted to the clipboard, and one incident where text went *neither* to the field nor the clipboard (secure-input silent drop).

## 2. Goals / Non-Goals

**Goals**
- Decide delivery from the **focus at the moment of delivery**, not from app-change.
- Inject into an editable text field **even across an app switch**.
- Clipboard **+ sound** only when there is genuinely no text destination (menu/status-bar/button/desktop) — and as the universal fallback so **text is never lost**.
- Work reliably in **AX-blind apps** (terminals, Cursor/VS Code, Electron) where Accessibility reports "no focus" even though the user is typing.
- Production stability: bounded AX latency, no silent keystroke loss, password safety.

**Non-Goals**
- No separate password-field UX flow. A secure-input context simply means "can't inject" → clipboard + sound (per owner: "密码框不单独讨论，按那两个场景走").
- No floating "scratchpad" recovery window. Clipboard + sound is the recovery (per owner).
- No auto-enabling of Chromium/Electron accessibility (`AXManualAccessibility`) — unreliable, intrusive, and unnecessary because keystroke injection follows key focus, not the AX tree.
- The "app changed" signal is **removed**, not kept as a guard.

## 3. Key Insight

**Synthesised CGEvent keystrokes follow the Window Server *key focus*, not the Accessibility tree.** So in AX-blind apps, *injecting anyway* works. Therefore AX is used to **gain confidence / detect a non-text destination**, never as *permission* to type. The decision **fails open toward injection**; the only thing that suppresses a direct inject is (a) a confirmed non-text control, or (b) secure input.

## 4. The Decision Ladder

At delivery time, gather observable signals, then decide. Two outcomes only: **inject** or **clipboard + sound**.

| # | Condition | Outcome |
|---|-----------|---------|
| 0 | **Secure input active** — `IsSecureEventInputEnabled()` OR focused role/subrole `AXSecureTextField` | **clipboard + sound** (don't attempt inject; OS would drop it) |
| 1 | **Editable text** — focused role ∈ {`AXTextField`,`AXTextArea`,`AXComboBox`,`AXSearchField`}, or (not a known non-text control and) `kAXValue` is settable | **inject** |
| 2 | **Non-text control** — focused role ∈ {`AXButton`,`AXMenuButton`,`AXMenuItem`,`AXMenu`,`AXMenuBar`,`AXMenuBarItem`,`AXCheckBox`,`AXRadioButton`,`AXPopUpButton`,`AXSlider`,`AXLink`,`AXDisclosureTriangle`,`AXIncrementor`,`AXColorWell`,`AXImage`} | **clipboard + sound** |
| 3 | **Blind / unknown** — no focused element, generic container, `AXUnknown`, or AX timed out | **inject** (fail open; covers terminals / Cursor / Electron) |
| 4 | Inject was chosen but **threw / could not create events** | **clipboard + sound** (runtime fallback; never lose text) |

Maps to requirements: cross-app text field → inject (row 1); clicked status bar → clipboard+sound (row 2, menu roles); terminal/Cursor → inject (row 3); password field → clipboard+sound (row 0); text never lost (rows 0/2/4 always reach clipboard+sound).

**Accepted trade-off (row 3):** in an AX-blind app, if the cursor happens to be on a *non-text* surface we cannot detect, the keystrokes go nowhere and that transcript is lost. This is rare and is the price of making every coding app "just type". The owner chose **inject** for this case (the conservative "only inject if same app" variant is intentionally omitted; it can be added later if row-3 misfires prove annoying).

## 5. Architecture

Split the logic into a **pure, unit-testable core** and a thin **side-effecting probe**, because this machine has no XCTest — tests run via the in-target `--self-test` harness (`SelfTest.Reporter`), which can only exercise pure functions.

**New file `Sources/flowtype/Services/InjectionDecision.swift`** (pure, no system calls):
- `enum InjectionDecision { case inject, clipboard }`
- `enum FocusKind { case editableText, nonTextControl, blindOrUnknown }`
- `struct FocusSignals { var secureInputActive: Bool; var focus: FocusKind }`
- `let editableTextRoles: Set<String>` and `let nonTextControlRoles: Set<String>`
- `func classifyFocus(role: String?, isValueSettable: Bool) -> FocusKind` — pure role/settable → kind.
- `func decideInjection(_ s: FocusSignals) -> InjectionDecision` — pure ladder (rows 0–3).

**`KeyboardInjector.swift`** (side-effecting glue):
- Replace `enum FocusState` + `currentFocusState()` with `currentFocusSignals() -> FocusSignals`, which: sets `AXUIElementSetMessagingTimeout(systemWide, 0.25)`, reads `IsSecureEventInputEnabled()`, reads focused element role/subrole and `AXUIElementIsAttributeSettable(kAXValue)`, and calls `classifyFocus`. Fails open to `.blindOrUnknown` on any AX miss.
- Make `postUnicode` / `postShiftReturn` **throw** `InjectionError.eventCreationFailed` instead of force-unwrapping `CGEvent`, so dropped events surface to the stage's `catch` → clipboard.

**`InjectionStage.swift`**:
- After the settle delay, `let signals = currentFocusSignals(); switch decideInjection(signals)`. Remove `targetBundleID` / `appChanged`. Remove the `.secureFieldTarget` abort (secure now → clipboard+sound). On `.inject`, `try insertText`; on throw → `copyToClipboard`. On `.clipboard`, `copyToClipboard`. `copyToClipboard` already plays the sound.

## 6. Production-Stability Requirements

- **AX messaging timeout** `0.25 s` set on the system-wide element (bounds the worst-case main-thread block).
- **All AX reads on the main thread** (AX is not thread-safe); rely on the timeout, not backgrounding.
- **Secure-input check on every delivery** (`IsSecureEventInputEnabled()` is in-process, sub-µs).
- **No silent keystroke loss**: nil `CGEvent` → throw → clipboard fallback.
- **Perf budget**: a few AX reads (≤ ~4 round-trips) bounded by the 0.25 s cap; healthy case ≪ 5 ms.

## 7. Testing

- **Self-test (`--self-test`)**: pure `classifyFocus` (role/settable matrix) and `decideInjection` (signals → outcome matrix). Asserts every ladder row.
- **Manual on-device matrix** (must-work apps from owner): Terminal CLIs (Claude Code/Codex in Terminal/iTerm2/Ghostty), Cursor / VS Code, browser web inputs (Chrome/Safari), native apps (Notes/Mail), WeChat. Plus the two divert cases: end on a clicked **status-bar/menu** item → clipboard+sound; switch to **another app's text field** → inject there. Confirm password field → clipboard+sound and no UI freeze on an unresponsive target.

## 8. Open Risk to Verify on Device

Whether a clicked status-bar/menu reliably reports a non-text AX role (`AXMenuItem`/`AXMenuBar`) at delivery time, vs. leaving the previous text field as the system-wide focused element. If the latter, row-2 won't catch it; tune the role set / add a "menu tracking" check during manual verification. The decision *structure* is unaffected.
