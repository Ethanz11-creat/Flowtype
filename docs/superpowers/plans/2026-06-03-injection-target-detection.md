# Injection Target Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace FlowType's "app-changed → clipboard" delivery fork with a focus-based decision (editable text → inject, including across app switches; no text destination → clipboard + sound), robust in AX-blind apps and hardened against silent text loss and AX hangs.

**Architecture:** A pure, unit-testable core (`InjectionDecision.swift`: `classifyFocus` + `decideInjection`) plus a thin side-effecting probe in `KeyboardInjector` (`currentFocusSignals`) that reads Accessibility + secure-input state with a 0.25 s messaging timeout. `InjectionStage` runs the probe, then the pure decision, then injects (failing open to clipboard) or copies. Tests run via the in-target `--self-test` harness since this machine has no XCTest.

**Tech Stack:** Swift 6.2, SPM, AppKit, ApplicationServices (Accessibility), Carbon (`IsSecureEventInputEnabled`), CoreGraphics (`CGEvent`).

**Spec:** `docs/superpowers/specs/2026-06-03-injection-target-detection-design.md`

---

## File Structure

- **Create** `Sources/flowtype/Services/InjectionDecision.swift` — pure types + role sets + `classifyFocus` + `decideInjection`. No system calls. Sole responsibility: the delivery decision.
- **Modify** `Sources/flowtype/Services/KeyboardInjector.swift` — replace `FocusState`/`currentFocusState()` with `currentFocusSignals()`; add Carbon import + AX timeout + secure check + settable check; make CGEvent posting throw.
- **Modify** `Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift` — run probe + `decideInjection`; drop app-changed and the secure-field abort.
- **Modify** `Sources/flowtype/Testing/SelfTest.swift` — add `testInjectionDecision(_:)` and register it.

---

## Task 1: Pure decision core + self-tests

**Files:**
- Create: `Sources/flowtype/Services/InjectionDecision.swift`
- Test: `Sources/flowtype/Testing/SelfTest.swift`

- [ ] **Step 1: Create the file with types, role sets, and STUB logic (wrong on purpose)**

Create `Sources/flowtype/Services/InjectionDecision.swift`:

```swift
import Foundation

/// Where a finished transcript should be delivered. Two outcomes only.
enum InjectionDecision: Equatable {
    case inject     // type into the focused field
    case clipboard  // copy + play sound (no usable text destination, or inject unsafe)
}

/// Classification of the system-wide focused element at delivery time.
enum FocusKind: Equatable {
    case editableText    // an editable text field/area (or settable value)
    case nonTextControl  // a clearly non-text control: button, menu, slider, link, image…
    case blindOrUnknown  // no element, generic container, AXUnknown, or AX timed out
}

/// Observable signals gathered just before delivery. Plain data so `decideInjection`
/// stays a pure function (unit-testable without a live AX/system query).
struct FocusSignals: Equatable {
    var secureInputActive: Bool   // IsSecureEventInputEnabled() OR an AXSecureTextField focus
    var focus: FocusKind
}

/// AX roles that mean "you can type text here".
let editableTextRoles: Set<String> = [
    "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
]

/// AX roles that mean "this is a focusable control you clearly cannot type into".
/// Reaching one of these is a positive signal to divert to the clipboard.
let nonTextControlRoles: Set<String> = [
    "AXButton", "AXMenuButton", "AXMenuItem", "AXMenu", "AXMenuBar", "AXMenuBarItem",
    "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXSlider", "AXLink",
    "AXDisclosureTriangle", "AXIncrementor", "AXColorWell", "AXImage",
]

/// Pure role/settable → kind. Editable roles win first; then known non-text controls
/// (so a settable slider value is NOT mistaken for text); then a settable generic value
/// (catches web/contentEditable/custom editors that report a non-text role); else blind.
func classifyFocus(role: String?, isValueSettable: Bool) -> FocusKind {
    return .blindOrUnknown   // STUB — replaced in Step 4
}

/// Pure decision ladder (spec §4 rows 0–3). Row 4 (inject-then-fail) is handled at runtime.
func decideInjection(_ s: FocusSignals) -> InjectionDecision {
    return .clipboard        // STUB — replaced in Step 4
}
```

- [ ] **Step 2: Add the self-test (compiles against the real symbols, asserts the real behaviour)**

In `Sources/flowtype/Testing/SelfTest.swift`, add this method (place it just after `testPolishModeMigration`, before `runAndExit`):

```swift
    // MARK: - Injection delivery decision (classifyFocus + decideInjection)

    static func testInjectionDecision(_ r: Reporter) {
        // classifyFocus: role + settable → kind
        r.eq(classifyFocus(role: "AXTextField", isValueSettable: false), .editableText,
             "inject: AXTextField → editableText")
        r.eq(classifyFocus(role: "AXTextArea", isValueSettable: false), .editableText,
             "inject: AXTextArea → editableText")
        r.eq(classifyFocus(role: "AXComboBox", isValueSettable: false), .editableText,
             "inject: AXComboBox → editableText")
        r.eq(classifyFocus(role: "AXButton", isValueSettable: false), .nonTextControl,
             "inject: AXButton → nonTextControl")
        r.eq(classifyFocus(role: "AXMenuItem", isValueSettable: false), .nonTextControl,
             "inject: AXMenuItem (status bar) → nonTextControl")
        r.eq(classifyFocus(role: "AXSlider", isValueSettable: true), .nonTextControl,
             "inject: settable slider stays nonTextControl (not text)")
        r.eq(classifyFocus(role: "AXGroup", isValueSettable: true), .editableText,
             "inject: settable generic role → editableText (web/custom editor)")
        r.eq(classifyFocus(role: "AXGroup", isValueSettable: false), .blindOrUnknown,
             "inject: generic non-settable → blindOrUnknown")
        r.eq(classifyFocus(role: nil, isValueSettable: false), .blindOrUnknown,
             "inject: no role → blindOrUnknown")

        // decideInjection: signals → outcome (spec §4 rows 0–3)
        r.eq(decideInjection(FocusSignals(secureInputActive: true, focus: .editableText)), .clipboard,
             "inject: secure input → clipboard (row 0)")
        r.eq(decideInjection(FocusSignals(secureInputActive: false, focus: .editableText)), .inject,
             "inject: editable text → inject (row 1)")
        r.eq(decideInjection(FocusSignals(secureInputActive: false, focus: .nonTextControl)), .clipboard,
             "inject: non-text control → clipboard (row 2)")
        r.eq(decideInjection(FocusSignals(secureInputActive: false, focus: .blindOrUnknown)), .inject,
             "inject: blind/unknown → inject, fail open (row 3)")
    }
```

Register it in `runAndExit()` — add the call right after `testPolishModeMigration(r)`:

```swift
        testPolishModeMigration(r) // history mode raw/polish + legacy decode
        testInjectionDecision(r)   // delivery decision: classifyFocus + decideInjection
        print("=== self-test: \(r.passed) passed, \(r.failed) failed ===")
```

- [ ] **Step 3: Run self-test to verify the new assertions FAIL against the stubs**

Run: `set -o pipefail && swift run FlowType --self-test 2>&1 | tail -20`
Expected: build succeeds; several `✗ FAIL: inject: …` lines (stubs return `.blindOrUnknown` / `.clipboard`), and the summary shows `N failed` with N ≥ 8.

- [ ] **Step 4: Implement the real pure logic**

In `Sources/flowtype/Services/InjectionDecision.swift`, replace the two stub bodies:

```swift
func classifyFocus(role: String?, isValueSettable: Bool) -> FocusKind {
    if let role, editableTextRoles.contains(role) { return .editableText }
    if let role, nonTextControlRoles.contains(role) { return .nonTextControl }
    if isValueSettable { return .editableText }
    return .blindOrUnknown
}
```

```swift
func decideInjection(_ s: FocusSignals) -> InjectionDecision {
    if s.secureInputActive { return .clipboard }   // row 0: OS would drop the keys
    switch s.focus {
    case .editableText:   return .inject            // row 1
    case .nonTextControl: return .clipboard         // row 2
    case .blindOrUnknown: return .inject            // row 3: fail open (terminals/Electron)
    }
}
```

- [ ] **Step 5: Run self-test to verify all assertions PASS**

Run: `set -o pipefail && swift run FlowType --self-test 2>&1 | tail -3`
Expected: `=== self-test: <N> passed, 0 failed ===` (N = previous count + 13).

- [ ] **Step 6: Commit**

```bash
git add Sources/flowtype/Services/InjectionDecision.swift Sources/flowtype/Testing/SelfTest.swift
git commit -m "feat: pure injection-delivery decision core (classifyFocus + decideInjection)"
```

---

## Task 2: AX probe — currentFocusSignals (replaces currentFocusState)

**Files:**
- Modify: `Sources/flowtype/Services/KeyboardInjector.swift`

No unit test: this reads live system state. Correctness of the pure mapping is covered by Task 1; this task is verified by `swift build` and Task 6's on-device matrix.

- [ ] **Step 1: Add the Carbon import**

In `Sources/flowtype/Services/KeyboardInjector.swift`, the current imports are:

```swift
import Foundation
import CoreGraphics
import AppKit
import ApplicationServices
import os
```

Add `import Carbon` (provides `IsSecureEventInputEnabled()`):

```swift
import Foundation
import CoreGraphics
import AppKit
import ApplicationServices
import Carbon
import os
```

- [ ] **Step 2: Delete the old `FocusState` enum and `currentFocusState()`**

Remove the enum (lines 12–16):

```swift
enum FocusState: Equatable {
    case secureField   // focused element is a password / secure text field
    case present       // some focused element exists — assume injectable
    case noFocus       // no focused UI element at all
}
```

Remove the whole `// MARK: - Focus detection` block — the doc comment and `currentFocusState()` (the method spanning `static func currentFocusState() -> FocusState { … return .present }`).

- [ ] **Step 3: Add the new probe + two private helpers**

In `KeyboardInjector`, where `currentFocusState()` was (under a `// MARK: - Focus detection` comment), add:

```swift
    // MARK: - Focus detection

    /// Gathers the signals the delivery decision needs from the live system. Bounds AX
    /// latency with a 0.25 s messaging timeout and fails open to `.blindOrUnknown` so a
    /// transient AX miss never blocks injection. Must be called on the main thread.
    static func currentFocusSignals() -> FocusSignals {
        let systemWide = AXUIElementCreateSystemWide()
        // Global default timeout for all AX messages — prevents a hung target app from
        // blocking the main thread for the ~6 s system default.
        AXUIElementSetMessagingTimeout(systemWide, 0.25)

        let secureGlobal = IsSecureEventInputEnabled()

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let value = focused,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return FocusSignals(secureInputActive: secureGlobal, focus: .blindOrUnknown)
        }
        let element = value as! AXUIElement
        let role = copyStringAttribute(element, kAXRoleAttribute as CFString)
        let subrole = copyStringAttribute(element, kAXSubroleAttribute as CFString)

        if secureGlobal || role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            return FocusSignals(secureInputActive: true, focus: .nonTextControl)
        }
        let kind = classifyFocus(role: role, isValueSettable: isValueSettable(element))
        return FocusSignals(secureInputActive: false, focus: kind)
    }

    private static func copyStringAttribute(_ element: AXUIElement, _ attr: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &value) == .success else { return nil }
        return value as? String
    }

    private static func isValueSettable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return err == .success && settable.boolValue
    }
```

- [ ] **Step 4: Build (compile-check; old symbol removed, new one referenced by Task 4 next)**

Run: `set -o pipefail && swift build 2>&1 | tail -6`
Expected: `Build complete!`. (If the build flags `currentFocusState` as still-referenced, that reference is in `InjectionStage.swift`, fixed in Task 4 — but Task 4 follows, so a clean build here requires InjectionStage already updated. Run Task 4 before building if the compiler complains; otherwise this builds clean because nothing else references the removed symbol.)

> Note for the implementer: Tasks 2–4 are one cohesive edit. If `swift build` errors on a dangling `currentFocusState`/`FocusState`/`secureFieldTarget` reference, proceed to Tasks 3–4 and build at the end of Task 4. Do not commit a non-building tree.

- [ ] **Step 5: Commit (after Task 4 build is green — see Task 4 Step 4)**

Deferred to Task 4's commit, which bundles the cohesive probe + posting + stage change.

---

## Task 3: Make keystroke posting fail loudly (no silent drop)

**Files:**
- Modify: `Sources/flowtype/Services/KeyboardInjector.swift`

- [ ] **Step 1: Add the error case**

The current `InjectionError` is:

```swift
enum InjectionError: Error {
    case eventSourceCreationFailed
    case textTooLong
}
```

Replace with:

```swift
enum InjectionError: Error {
    case eventSourceCreationFailed
    case eventCreationFailed
    case textTooLong
}
```

- [ ] **Step 2: Throw on nil CGEvent in `postUnicode`**

Replace the current `postUnicode` body:

```swift
    private static func postUnicode(_ s: String, source: CGEventSource) async throws {
        guard !s.isEmpty else { return }
        let utf16 = Array(s.utf16)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw InjectionError.eventCreationFailed
        }
        keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyDown.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: interEventDelayNs)
        keyUp.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: interEventDelayNs)
    }
```

- [ ] **Step 3: Throw on nil CGEvent in `postShiftReturn`**

Replace the current `postShiftReturn` body:

```swift
    private static func postShiftReturn(source: CGEventSource) async throws {
        let returnKey: CGKeyCode = 0x24 // kVK_Return
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false) else {
            throw InjectionError.eventCreationFailed
        }
        down.flags = .maskShift
        up.flags   = .maskShift
        down.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: interEventDelayNs)
        up.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: interEventDelayNs)
    }
```

- [ ] **Step 4: Build (bundled with Task 4)** — see Task 4 Step 4.

---

## Task 4: Rewrite InjectionStage around the decision ladder

**Files:**
- Modify: `Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift`

- [ ] **Step 1: Replace the decision section of `execute`**

In `InjectionStage.execute`, replace everything from the `// Capture the app we were dictating into.` comment through the end of the same-app inject block (the current lines that compute `targetBundleID`, `currentBundleID`, `appChanged`, the `.secureField` abort, the `appChanged` clipboard branch, and the same-app inject `do/catch`) with:

```swift
        // (.injecting is set by the orchestrator's pre-stage transition; the
        // statePublisher subscriber filters .injecting, so we don't re-send it.)
        try? await Task.sleep(nanoseconds: 100_000_000) // let focus settle after the end-tap

        // Decide from the focus at THIS moment (not from whether the app changed):
        // editable text → inject (even across an app switch); a non-text control or secure
        // input → clipboard + sound; AX-blind apps (terminals/Electron) fail open to inject.
        let signals = await MainActor.run { KeyboardInjector.currentFocusSignals() }
        let decision = decideInjection(signals)
        AppLogger.log("[InjectionStage#\(sessionID)] signals=\(signals) → \(decision)")

        switch decision {
        case .clipboard:
            await copyToClipboard(text)
            return .complete
        case .inject:
            do {
                try await KeyboardInjector.insertText(text)
                AppLogger.log("[InjectionStage#\(sessionID)] Injected in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")
                return .complete
            } catch {
                // Never lose text: a failed/blocked injection falls back to clipboard + sound.
                AppLogger.log("[InjectionStage#\(sessionID)] Injection failed (\(error)); falling back to clipboard")
                await copyToClipboard(text)
                return .complete
            }
        }
    }
```

After this edit, `execute` no longer references `NSWorkspace`, `targetBundleID`, `currentBundleID`, `appChanged`, or `KeyboardInjector.currentFocusState()`. The `import AppKit` line stays (NSPasteboard in `copyToClipboard`).

- [ ] **Step 2: Remove the now-unused `.secureFieldTarget` error case**

The secure path no longer suspends. Replace the `InjectionStageError` enum at the bottom of the file:

```swift
enum InjectionStageError: LocalizedError {
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "注入失败：无效的文本"
        }
    }
}
```

- [ ] **Step 3: Verify nothing else references the removed symbols**

Run: `grep -rn "secureFieldTarget\|currentFocusState\|FocusState\b" Sources/flowtype/ | grep -v "currentFocusSignals"`
Expected: no output. If `secureFieldTarget` appears in an error-recovery UI or switch elsewhere, remove that branch (it is dead — secure now routes to clipboard).

- [ ] **Step 4: Build the whole tree (Tasks 2+3+4 together)**

Run: `set -o pipefail && swift build 2>&1 | tail -6`
Expected: `Build complete!`. (Ignore any SourceKit "Cannot find … in scope" diagnostics — they lag; trust the `swift build` result.)

- [ ] **Step 5: Run the full self-test (regression + Task 1 logic)**

Run: `set -o pipefail && cp ~/.cache/uv/archive-v0/*/mlx/lib/mlx.metallib .build/debug/ 2>/dev/null; swift run FlowType --self-test 2>&1 | tail -3`
Expected: `=== self-test: <N> passed, 0 failed ===`.

- [ ] **Step 6: Commit the cohesive change**

```bash
git add Sources/flowtype/Services/KeyboardInjector.swift Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift
git commit -m "feat: focus-based injection decision (probe + ladder), drop app-changed fork

- KeyboardInjector.currentFocusSignals(): IsSecureEventInputEnabled + AX role/
  subrole/settable, 0.25s AX messaging timeout, fails open to blindOrUnknown
- CGEvent posting throws InjectionError.eventCreationFailed (no silent drop)
- InjectionStage runs decideInjection: editable→inject (cross-app too),
  non-text/secure→clipboard+sound, AX-blind→inject, inject-fail→clipboard
- remove FocusState/currentFocusState + secureFieldTarget abort"
```

---

## Task 5: On-device verification matrix (manual; record results)

No code. Build the `.app` and verify the decision live, because the AX/CGEvent behaviour is system-dependent and not unit-testable.

- [ ] **Step 1: Build and launch the app**

```bash
set -o pipefail && ./scripts/build-app.sh 2>&1 | tail -5
pkill -x FlowType 2>/dev/null; sleep 1; xattr -cr build/FlowType.app && open build/FlowType.app
```

- [ ] **Step 2: Verify each must-work case, recording inject/clipboard outcome**

For each, dictate a short phrase and confirm the outcome:

| Case | Expected |
|------|----------|
| Native app text field (Notes / Mail) | inject |
| Browser web input (Chrome + Safari, an `<input>`/`<textarea>`) | inject |
| Terminal (Apple Terminal) | inject |
| Terminal (iTerm2 / Ghostty) | inject |
| Cursor / VS Code editor pane | inject |
| WeChat chat box | inject |
| Switch to **another app's** text field mid-dictation, end there | inject **there** |
| End while focus is on a clicked **status-bar / menu** item | clipboard + sound |
| End on the desktop (Finder, no field) | clipboard + sound |
| Focus a password field (e.g. login) | clipboard + sound, no freeze |

- [ ] **Step 3: Confirm no regressions on the three earlier fixes**

Capsule slides up on start / down on end; 9 audio bars track speech; no UI freeze when a target app is busy.

- [ ] **Step 4: Record outcomes in the feature inventory**

Append a "Injection target detection — verification" batch to `docs/feature-inventory.md` with the table above and pass/fail per row. If row "status-bar/menu → clipboard" fails (AX still reports the prior text field), note it and open a follow-up to tune `nonTextControlRoles` / add menu-tracking detection (spec §8). Do not block the other rows on it.

---

## Self-Review (run after writing, before execution)

**Spec coverage:**
- §4 row 0 (secure) → Task 1 `decideInjection` + Task 2 secure probe. ✓
- §4 row 1 (editable → inject) → Task 1 + Task 4 ladder. ✓
- §4 row 2 (non-text → clipboard) → Task 1 `nonTextControlRoles` + classify. ✓
- §4 row 3 (blind → inject) → Task 1 + probe fail-open. ✓
- §4 row 4 (inject fails → clipboard) → Task 3 throw + Task 4 catch. ✓
- §5 architecture (pure core + probe) → Tasks 1–2. ✓
- §6 stability (AX timeout, main thread, secure each delivery, no silent loss) → Tasks 2–3. ✓
- §7 testing (pure self-tests + manual matrix) → Tasks 1, 5. ✓
- "drop app-changed" → Task 4 Step 1. ✓
- "remove secure abort" → Task 4 Step 2. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; commands have expected output. ✓

**Type consistency:** `FocusSignals`/`FocusKind`/`InjectionDecision`/`classifyFocus(role:isValueSettable:)`/`decideInjection(_:)`/`currentFocusSignals()`/`InjectionError.eventCreationFailed`/`InjectionStageError.invalidPayload` named identically across Tasks 1–4. `currentFocusSignals` (not `currentFocusState`) used in Task 4. ✓
