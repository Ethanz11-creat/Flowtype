# Design: Keystroke-Only Injection + Clipboard Fallback

**Date:** 2026-06-02
**Status:** Approved (design), pending implementation plan
**Supersedes:** the paste-based injection path and the B7 clipboard snapshot/restore fix
(both removed — see §6).

## 1. Goal

Two changes to how dictated text reaches the user's cursor:

1. **Inject by typing, always.** Replace the clipboard-paste strategy with keystroke
   injection for all text (short or long, single- or multi-line), matching how tools like
   Typeless behave. This removes the whole clipboard save/restore dance (and the class of
   bugs it caused).
2. **Never lose a dictation.** When there is no place to inject (the user clicked away to
   another app, or no field is focused), put the final text on the clipboard and play a
   distinct sound, so the user can paste it manually instead of losing it.

## 2. Current behavior (what exists today)

- `KeyboardInjector.insertText` routes to `pasteText` (text > 50 chars or contains a
  newline) or `typeText` (short single-line, capped at 100 chars).
- `pasteText` snapshots the clipboard, writes the text, posts ⌘V, waits, and restores the
  clipboard (the B7 fix made the snapshot/restore lossy-aware).
- `typeText` posts one CGEvent per character with a 5 ms gap (Unicode via
  `keyboardSetUnicodeString`, which bypasses the IME — works for CJK).
- `InjectionStage` already: guards against double injection; captures the frontmost app at
  start and **aborts if the frontmost app changed** after a 100 ms settle; checks for a
  secure (password) field and aborts with no clipboard residue (B6).
- When injection is aborted (app changed / failure), the text is left on the clipboard via
  `setString`, but there is **no user feedback** and **no handling of the "same app, no
  field focused" case** — so a dictation can still be silently lost.

## 3. Injection mechanism (rewrite of `KeyboardInjector`)

- **Type everything via keystrokes.** Remove `pasteText` and the clipboard snapshot/restore
  machinery entirely (§6).
- **Segment by line.** Normalize `\r\n` and `\r` to `\n`, split the text into line segments.
- **Type each segment as chunked Unicode.** Inject each segment via
  `keyboardSetUnicodeString` in chunks (≈64 chars per CGEvent keyDown/keyUp) rather than one
  char at a time — much faster, still broadly compatible. Keep a small inter-event delay
  (a few ms) for reliability.
- **Newline = Shift+Return.** Between segments, post a `Return` key event with `.maskShift`.
  Shift+Enter is a soft newline in Claude Code, editors, chat boxes, and text areas — it
  inserts a line break without submitting. (Plain Return would submit in terminal/chat
  targets.)
- **Remove the 100-char cap** (it existed only because per-char typing was slow). Keep a
  generous sanity ceiling against pathological input.
- **Keep** the injection lock / `isInjecting` flag (lets the hotkey event tap ignore
  FlowType's own synthesized events).

### Testable seam
Expose pure helpers so the segmentation logic can be unit-tested without posting real events:
- `normalizeNewlines(_:) -> String`
- `splitIntoLineSegments(_:) -> [String]`
- `chunk(_:size:) -> [String]`

## 4. Where the text goes (`InjectionStage` decision logic)

Evaluated in order; reuses the existing app-capture + 100 ms settle:

1. **Empty final text** → do nothing.
2. **Frontmost app changed** (bundle ID at injection time ≠ at recording start) →
   **clipboard + sound**. *Reliable, no AX needed — covers the primary "I clicked another
   app" pain.*
3. **Focused element is a secure/password field** (B6) → **abort: no injection, no
   clipboard** (never leave a transcript near a password context).
4. **No focused UI element at all** (`kAXFocusedUIElement` returns nil/error) →
   **clipboard + sound** (the user clicked onto something non-focusable).
5. **Otherwise** (same app, a focused element exists, not secure) → **inject** (type it).

**Bias:** when AX cannot positively say "no focused element," we inject. This deliberately
favors injection so terminals/Electron (where AX is unreliable) are never wrongly diverted
to the clipboard. The reliable app-changed guard (step 2) is the main safety net for the
walk-away case; the nil-focus check (step 4) is a secondary catch for same-app-no-focus.

### Focus helper
Replace B6's `isFocusedElementSecure()` with a single `currentFocusState() -> FocusState`:
```
enum FocusState { case secureField, present, noFocus }
```
queried once from the system-wide focused element (`secureField` if role/subrole is
`AXSecureTextField`; `noFocus` if the attribute is absent/errors; `present` otherwise).

## 5. Clipboard fallback behavior

- `NSPasteboard.general.clearContents()` + `setString(finalText, forType: .string)` —
  **overwrite, no save, no restore** (the user keeps a clipboard-manager history, so the
  previous contents are recoverable).
- Play a **distinct system sound** via a new `SoundFeedback.playCopiedToClipboard()`
  (different ID from start `1104` / stop `1103` / error `1102`, e.g. a light "Tink"), so the
  sound alone tells the user "this went to the clipboard — paste it."
- **No** capsule message and **no** system notification (per user preference).
- History is still saved (the dictation is recorded regardless of injection vs clipboard).

## 6. Code removed (simplification)

- `KeyboardInjector.pasteText`, and the B7 additions it depended on:
  `PasteboardSnapshot`, `snapshotPasteboard`, `restore`.
- The corresponding self-test `testClipboardSnapshot` (B7) — the bug class it guarded
  (lossy clipboard restore / 500 ms race) **disappears structurally** because FlowType no
  longer saves+restores the user's clipboard; it only overwrites in the fallback.
- The `> 50 chars || newline → paste` routing in `insertText`.

## 7. Testing

- **Self-test (`swift run FlowType --self-test`):** add assertions for
  `normalizeNewlines`, `splitIntoLineSegments`, and `chunk` (e.g. `"a\r\nb\n\nc"` →
  `["a","b","","c"]`; chunking a long line respects the size and preserves order/content).
- **Manual (real GUI + permissions required):**
  - Inject correctly in all four targets: terminal Claude Code/Codex, Cursor/VS Code,
    browser textarea, native mac app — including a multi-line (Shift+Enter) case.
  - Dictate, then click another app before ending → text on clipboard + distinct sound; ⌘V
    pastes it.
  - Dictate into a password field → nothing injected, nothing on clipboard.

## 8. Out of scope

- Auto-update, model-download UX, settings UI changes.
- A user-facing setting to toggle inject-vs-clipboard (always automatic for now).
- B3 (recording-stop/cancel channel refactor) — tracked separately.

## 9. Risks / open points

- **AX false negatives** (same app, focus genuinely off the field, but a non-text element is
  focused → step 5 injects into nothing and the text is lost). Accepted as rare; the
  app-changed guard covers the common walk-away case. Revisit if it bites in practice.
- **Shift+Return** is a soft newline in most targets but not guaranteed universally (some
  terminals may map newline differently). Verify against the four targets during
  implementation; fall back to a per-target tweak only if a target misbehaves.
- **Chunked Unicode injection** size (≈64) is a compatibility/speed trade-off to confirm on
  the real targets during implementation.
