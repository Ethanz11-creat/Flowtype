# Keystroke-Only Injection + Clipboard Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Inject all dictated text by simulated keystrokes (Shift+Return for newlines), and when there is no focused field to inject into, copy the text to the clipboard with a distinct sound instead of losing it.

**Architecture:** Rewrite `KeyboardInjector` to type everything (chunked Unicode events, no clipboard paste). Rewrite `InjectionStage`'s decision logic to choose inject-vs-clipboard from a reliable app-changed check plus an AX focus check. Delete the paste path and the B7 clipboard snapshot/restore code (the bug class disappears structurally).

**Tech Stack:** Swift 6.2, AppKit/CoreGraphics (`CGEvent`), ApplicationServices (AX), AudioToolbox. No XCTest — pure-logic regression via `swift run FlowType --self-test`.

**Spec:** `docs/superpowers/specs/2026-06-02-keystroke-injection-clipboard-fallback-design.md`

**Verification commands used throughout:**
- Build: `swift build` (expect `Build complete!`)
- Self-test: `set -o pipefail; swift run FlowType --self-test` (expect `... passed, 0 failed` and exit 0)

---

## File structure

- `Sources/flowtype/Services/KeyboardInjector.swift` — **major rewrite**: add pure segmentation helpers + `FocusState`/`currentFocusState()`; replace `insertText` internals with chunked keystroke typing; delete `pasteText`, `typeText`, `PasteboardSnapshot`, `snapshotPasteboard`, `restore`, `isFocusedElementSecure`.
- `Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift` — **rewrite decision logic**; trim `InjectionStageError`.
- `Sources/flowtype/Utilities/SoundFeedback.swift` — add `playCopiedToClipboard()`.
- `Sources/flowtype/Testing/SelfTest.swift` — add segmentation tests; remove the B7 clipboard test.

---

## Task 1: Pure segmentation helpers (TDD)

Add the testable newline/segment/chunk helpers to `KeyboardInjector` (additive — the paste path still exists, build stays green).

**Files:**
- Modify: `Sources/flowtype/Services/KeyboardInjector.swift`
- Test: `Sources/flowtype/Testing/SelfTest.swift`

- [ ] **Step 1: Write the failing self-test**

In `Sources/flowtype/Testing/SelfTest.swift`, add this method at the end of the `SelfTest` enum (before its closing `}`):

```swift
    // MARK: - Injection segmentation (B-inject)

    static func testInjectionSegmentation(_ r: Reporter) {
        r.eq(KeyboardInjector.normalizeNewlines("a\r\nb\rc"), "a\nb\nc", "inject: CRLF/CR normalized to LF")
        r.eq(KeyboardInjector.splitIntoLineSegments("a\n\nc"), ["a", "", "c"], "inject: split keeps empty segments")
        r.eq(KeyboardInjector.splitIntoLineSegments("single"), ["single"], "inject: single line → one segment")
        r.eq(KeyboardInjector.chunk("abcdef", size: 2), ["ab", "cd", "ef"], "inject: chunk splits evenly")
        r.eq(KeyboardInjector.chunk("abcde", size: 2), ["ab", "cd", "e"], "inject: chunk handles remainder")
        r.eq(KeyboardInjector.chunk("", size: 64), [], "inject: chunk empty → no pieces")
        r.eq(KeyboardInjector.chunk("abc", size: 0), ["abc"], "inject: chunk size 0 → whole string")

        let text = "hello world\nlonger line that exceeds the chunk size by a fair bit\n\nend"
        let segs = KeyboardInjector.splitIntoLineSegments(KeyboardInjector.normalizeNewlines(text))
        let rebuilt = segs.map { KeyboardInjector.chunk($0, size: 8).joined() }.joined(separator: "\n")
        r.eq(rebuilt, KeyboardInjector.normalizeNewlines(text), "inject: segment+chunk round-trips")
    }
```

And add the call inside `runAndExit()`, right after `testClipboardSnapshot(r)`:

```swift
        testClipboardSnapshot(r) // B7
        testInjectionSegmentation(r) // injection helpers
```

- [ ] **Step 2: Run to verify it fails (compile error — helpers don't exist)**

Run: `swift build`
Expected: FAIL — `value of type 'KeyboardInjector'... has no member 'normalizeNewlines'` (and `splitIntoLineSegments`, `chunk`).

- [ ] **Step 3: Add the helpers**

In `Sources/flowtype/Services/KeyboardInjector.swift`, add these methods inside the `KeyboardInjector` struct (e.g. right after the `insertText` method):

```swift
    // MARK: - Newline / segmentation helpers (pure, testable)

    static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func splitIntoLineSegments(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    static func chunk(_ s: String, size: Int) -> [String] {
        guard size > 0, !s.isEmpty else { return s.isEmpty ? [] : [s] }
        var result: [String] = []
        var idx = s.startIndex
        while idx < s.endIndex {
            let end = s.index(idx, offsetBy: size, limitedBy: s.endIndex) ?? s.endIndex
            result.append(String(s[idx..<end]))
            idx = end
        }
        return result
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `set -o pipefail; swift build && swift run FlowType --self-test`
Expected: `Build complete!` then `... passed, 0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/flowtype/Services/KeyboardInjector.swift Sources/flowtype/Testing/SelfTest.swift
git commit -m "feat: add pure newline/segment/chunk helpers for keystroke injection"
```

---

## Task 2: Distinct clipboard-fallback sound

**Files:**
- Modify: `Sources/flowtype/Utilities/SoundFeedback.swift`

- [ ] **Step 1: Add the sound method**

In `Sources/flowtype/Utilities/SoundFeedback.swift`, add inside the `SoundFeedback` enum, after `playError()`:

```swift
    static func playCopiedToClipboard() {
        guard isEnabled else { return }
        AudioServicesPlaySystemSound(1054) // "Tink" — distinct from start(1104)/stop(1103)/error(1102)
    }
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/flowtype/Utilities/SoundFeedback.swift
git commit -m "feat: add distinct clipboard-fallback sound"
```

---

## Task 3: Rewrite KeyboardInjector to keystroke-only + add FocusState

Replace the injection internals with chunked keystroke typing, add `currentFocusState()`, and delete the paste path and B7 snapshot/restore (and its now-broken self-test). `isFocusedElementSecure()` stays for now (still called by `InjectionStage`) so the build stays green; it is removed in Task 4.

**Files:**
- Modify: `Sources/flowtype/Services/KeyboardInjector.swift`
- Modify: `Sources/flowtype/Testing/SelfTest.swift`

- [ ] **Step 1: Replace the whole `KeyboardInjector` struct body**

Replace the entire `struct KeyboardInjector { ... }` (everything from `struct KeyboardInjector {` to its matching closing brace) with the following. Keep the file's `import` lines and the `enum InjectionError` above it unchanged.

```swift
enum FocusState: Equatable {
    case secureField   // focused element is a password / secure text field
    case present       // some focused element exists — assume injectable
    case noFocus       // no focused UI element at all
}

struct KeyboardInjector {

    private static let injectionLock = OSAllocatedUnfairLock<Bool>(uncheckedState: false)
    static let isInjecting = OSAllocatedUnfairLock<Bool>(uncheckedState: false)

    private static let chunkSize = 64
    private static let interEventDelayNs: UInt64 = 2_000_000 // 2 ms between key events
    private static let maxChars = 20_000                     // sanity ceiling

    // MARK: - Entry point: type the text (Shift+Return for newlines)

    static func insertText(_ text: String) async throws {
        let canProceed = injectionLock.withLock { state in
            if state { return false }
            state = true
            return true
        }
        guard canProceed else {
            AppLogger.log("[KeyboardInjector] Injection already in progress, ignoring duplicate")
            return
        }
        defer { injectionLock.withLock { $0 = false } }

        guard text.count <= maxChars else {
            AppLogger.log("[KeyboardInjector] insertText rejected: \(text.count) chars exceeds \(maxChars) cap")
            throw InjectionError.eventSourceCreationFailed
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw InjectionError.eventSourceCreationFailed
        }

        let start = Date()
        defer {
            AppLogger.log("[KeyboardInjector] Injected \(text.count) chars in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        }

        isInjecting.withLock { $0 = true }
        defer { isInjecting.withLock { $0 = false } }

        let segments = splitIntoLineSegments(normalizeNewlines(text))
        for (i, segment) in segments.enumerated() {
            if i > 0 {
                try await postShiftReturn(source: source)
            }
            for piece in chunk(segment, size: chunkSize) {
                try await postUnicode(piece, source: source)
            }
        }
    }

    // MARK: - Newline / segmentation helpers (pure, testable)

    static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func splitIntoLineSegments(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    static func chunk(_ s: String, size: Int) -> [String] {
        guard size > 0, !s.isEmpty else { return s.isEmpty ? [] : [s] }
        var result: [String] = []
        var idx = s.startIndex
        while idx < s.endIndex {
            let end = s.index(idx, offsetBy: size, limitedBy: s.endIndex) ?? s.endIndex
            result.append(String(s[idx..<end]))
            idx = end
        }
        return result
    }

    // MARK: - Low-level CGEvent posting

    private static func postUnicode(_ s: String, source: CGEventSource) async throws {
        guard !s.isEmpty else { return }
        let utf16 = Array(s.utf16)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        keyDown?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyUp?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyDown?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: interEventDelayNs)
        keyUp?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: interEventDelayNs)
    }

    private static func postShiftReturn(source: CGEventSource) async throws {
        let returnKey: CGKeyCode = 0x24 // kVK_Return
        let down = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true)
        let up   = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false)
        down?.flags = .maskShift
        up?.flags   = .maskShift
        down?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: interEventDelayNs)
        up?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: interEventDelayNs)
    }

    // MARK: - Focus detection

    /// Classifies the system-wide focused element. Fails toward `.present`/`.noFocus`
    /// (never blocks normal injection on a transient AX hiccup).
    static func currentFocusState() -> FocusState {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focusedValue = focused,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return .noFocus
        }
        let element = focusedValue as! AXUIElement
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           let s = subrole as? String, s == "AXSecureTextField" {
            return .secureField
        }
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           let r = role as? String, r == "AXSecureTextField" {
            return .secureField
        }
        return .present
    }

    // MARK: - Temporary shim (removed in Task 4)

    /// Kept only until InjectionStage migrates to `currentFocusState()`.
    static func isFocusedElementSecure() -> Bool {
        currentFocusState() == .secureField
    }
}
```

- [ ] **Step 2: Remove the now-broken B7 self-test**

In `Sources/flowtype/Testing/SelfTest.swift`:

1. Remove the call `testClipboardSnapshot(r) // B7` from `runAndExit()` (keep `testInjectionSegmentation(r)`).
2. Delete the entire `testClipboardSnapshot(_:)` method.
3. Delete the `LazyPasteboardProvider` class at the top of the file.
4. If `import AppKit` is now unused, leave it — it is harmless. (Do not remove `import Foundation`.)

- [ ] **Step 3: Build and self-test**

Run: `set -o pipefail; swift build && swift run FlowType --self-test`
Expected: `Build complete!` then `... passed, 0 failed`, exit 0.
(If build fails with `snapshotPasteboard`/`restore`/`PasteboardSnapshot` not found, a reference to the deleted code remains — grep and remove it: `grep -rn "snapshotPasteboard\|PasteboardSnapshot\|\.restore(" Sources/`.)

- [ ] **Step 4: Commit**

```bash
git add Sources/flowtype/Services/KeyboardInjector.swift Sources/flowtype/Testing/SelfTest.swift
git commit -m "feat: keystroke-only injection (Shift+Return newlines); drop paste path + B7 snapshot/restore"
```

---

## Task 4: Rewrite InjectionStage decision logic

Route to inject vs clipboard from the app-changed check + `currentFocusState()`; copy to clipboard with the new sound when there is nowhere to inject; abort on a secure field. Then delete the temporary `isFocusedElementSecure()` shim.

**Files:**
- Modify: `Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift`
- Modify: `Sources/flowtype/Services/KeyboardInjector.swift` (remove the shim)

- [ ] **Step 1: Replace the `execute` method and the error enum**

In `Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift`, replace the entire `func execute(...) async -> StageResult { ... }` with:

```swift
    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        let sessionID = context.sessionID
        AppLogger.log("[InjectionStage#\(sessionID)] Started")
        let startTime = Date()

        let text: String
        switch payload {
        case .polished(let polishedText, _):
            text = polishedText
        default:
            AppLogger.log("[InjectionStage#\(sessionID)] Unexpected payload: \(payload), expected .polished")
            return .suspend(ErrorRecoveryContext(
                failedStage: name,
                error: InjectionStageError.invalidPayload,
                rawText: nil,
                retryable: false
            ))
        }

        guard !text.isEmpty else {
            AppLogger.log("[InjectionStage#\(sessionID)] Empty text, nothing to inject")
            return .complete
        }

        // Guard against double injection
        let hasInjected = await MainActor.run { context.hasInjected }
        guard !hasInjected else {
            AppLogger.log("[InjectionStage#\(sessionID)] Duplicate injection blocked")
            return .complete
        }
        await MainActor.run { context.hasInjected = true }

        // Capture the app we were dictating into.
        let targetBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        AppLogger.log("[InjectionStage#\(sessionID)] Target app: \(targetBundleID)")

        await MainActor.run { context.statePublisher.send(.injecting) }
        try? await Task.sleep(nanoseconds: 100_000_000) // let UI settle

        let currentBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        let appChanged = currentBundleID != targetBundleID
        let focusState = await MainActor.run { KeyboardInjector.currentFocusState() }

        // Never inject into — or leave a transcript on the clipboard near — a password field.
        if focusState == .secureField {
            AppLogger.log("[InjectionStage#\(sessionID)] Secure field focused — aborting (no inject, no clipboard)")
            return .suspend(ErrorRecoveryContext(
                failedStage: name,
                error: InjectionStageError.secureFieldTarget,
                rawText: nil,
                retryable: false
            ))
        }

        // Inject only when staying in the same app with a focused element.
        if !appChanged && focusState == .present {
            do {
                try await KeyboardInjector.insertText(text)
                AppLogger.log("[InjectionStage#\(sessionID)] Injected in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")
                return .complete
            } catch {
                AppLogger.log("[InjectionStage#\(sessionID)] Injection failed (\(error)); falling back to clipboard")
                await copyToClipboard(text)
                return .complete
            }
        }

        // No place to inject (moved to another app, or no focused field) → clipboard + sound.
        let reason = appChanged ? "app changed \(targetBundleID)→\(currentBundleID)" : "no focused field"
        AppLogger.log("[InjectionStage#\(sessionID)] Not injecting (\(reason)); copied to clipboard")
        await copyToClipboard(text)
        return .complete
    }

    private func copyToClipboard(_ text: String) async {
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            SoundFeedback.playCopiedToClipboard()
        }
    }
```

And replace the `InjectionStageError` enum at the bottom of the file with (drops the now-unused `.targetAppChanged`):

```swift
enum InjectionStageError: LocalizedError {
    case invalidPayload
    case secureFieldTarget

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "注入失败：无效的文本"
        case .secureFieldTarget:
            return "检测到密码框，已跳过注入以保护隐私"
        }
    }
}
```

- [ ] **Step 2: Verify nothing else references the removed `.targetAppChanged`**

Run: `grep -rn "targetAppChanged" Sources/`
Expected: no matches. (If any remain, they are stale references — remove them.)

- [ ] **Step 3: Remove the temporary shim from KeyboardInjector**

In `Sources/flowtype/Services/KeyboardInjector.swift`, delete the `// MARK: - Temporary shim (removed in Task 4)` comment and the `isFocusedElementSecure()` method.

Run: `grep -rn "isFocusedElementSecure" Sources/`
Expected: no matches.

- [ ] **Step 4: Build and self-test**

Run: `set -o pipefail; swift build && swift run FlowType --self-test`
Expected: `Build complete!` then `... passed, 0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift Sources/flowtype/Services/KeyboardInjector.swift
git commit -m "feat: route dictation to clipboard+sound when no focused field; keep secure-field abort"
```

---

## Task 5: Manual verification (real GUI required)

Self-tests cover only the pure segmentation logic. The keystroke posting, AX focus detection, and clipboard fallback need a real session. The dev machine has no Xcode, so build the app bundle (or `swift run` with `mlx.metallib` copied next to the debug binary) and grant Accessibility.

- [ ] **Step 1: Build a runnable app**

Run: `./scripts/build-app.sh && open build/FlowType.app`
(Grant Microphone, Speech Recognition, and Accessibility on first run.)

- [ ] **Step 2: Injection works in all four targets (single- and multi-line)**

For each of: terminal Claude Code/Codex, Cursor/VS Code, a browser textarea, a native mac app (e.g. Notes):
- Focus the input, dictate a sentence, end → text is typed in.
- Dictate something with an explicit line break (say a newline) → it lands as a soft newline (Shift+Enter), NOT a premature submit.

Expected: text appears correctly; multi-line does not submit early. If a specific terminal submits on Shift+Enter, note it (per spec §9 — may need a per-target tweak).

- [ ] **Step 3: Walk-away → clipboard + sound**

Start dictating with the cursor in a text field, then click another app (or the desktop) before ending. End the dictation.
Expected: nothing is typed; you hear the distinct "Tink"; `Cmd+V` pastes the dictated text. Log (`~/Library/Logs/flowtype/diagnostic.log`) shows `copied to clipboard`.

- [ ] **Step 4: Password field is never written**

Focus a GUI password field (e.g. https://github.com/login), dictate, end.
Expected: nothing typed into the field AND nothing placed on the clipboard. Log shows `Secure field focused — aborting`.

- [ ] **Step 5: Commit any tuning**

If Step 2/3 required adjusting `chunkSize`, `interEventDelayNs`, or the Shift+Return handling, commit those tweaks:

```bash
git add -A
git commit -m "fix: tune keystroke injection timing/chunking from manual verification"
```

---

## Self-review (completed by author)

- **Spec coverage:** §3 mechanism → Task 1 (helpers) + Task 3 (typing/Shift+Return/chunking, cap removed). §4 decision logic → Task 4. §5 clipboard+sound → Task 2 + Task 4 `copyToClipboard`. §6 code removal → Task 3 (paste/snapshot/restore + B7 test) + Task 4 (`targetAppChanged`, `isFocusedElementSecure`). §7 testing → Task 1 self-test + Task 5 manual. All covered.
- **Placeholders:** none — every code step shows complete code; every run step shows the command and expected output.
- **Type consistency:** `FocusState` (`.secureField`/`.present`/`.noFocus`, `Equatable`) defined in Task 3, consumed in Task 4. `currentFocusState()`, `insertText`, `normalizeNewlines`/`splitIntoLineSegments`/`chunk`, `SoundFeedback.playCopiedToClipboard()`, `InjectionStageError` (`.invalidPayload`/`.secureFieldTarget`) all consistent across tasks.
