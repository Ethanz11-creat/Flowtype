# Production Hardening — Systematic Debugging Pass (2026-06-02)

A full health-check found 11 candidate issues; each was root-cause-confirmed by an
independent investigation before any fix (systematic-debugging discipline). 10 were
real and fixed; 1 (B3) was downgraded to a latent fragility and deferred.

Pure-logic fixes are guarded by a no-Xcode self-test runner:

```bash
swift run FlowType --self-test   # exits 0 on pass, 1 on failure (21 assertions)
```

> This machine has Command Line Tools only (no full Xcode), so `XCTest` / `swift-testing`
> are unavailable and `swift test` cannot run. The self-test lives in-target and runs via
> a CLI flag instead. System/hardware/UI bugs are verified manually (checklist below).

## Fixed

| ID | Severity | Issue | Fix | Verified by |
|----|----------|-------|-----|-------------|
| B1 | 🔴 open-box | `validatedAPIURL` replaced the whole path, dropping `/v1` → every LLM polish 404'd | Preserve+sanitize base path, append `/chat/completions`; keep traversal/cred/https guards | self-test (8) |
| B8 | 🟡 | SSE silently swallowed malformed chunks & in-band `{"error":…}` frames → silent empty output | `parseSSELine` surfaces error frames, counts decode failures, throws on all-failed-no-content | self-test (6) |
| B9 | 🟡 | Corrupt persisted config was silently reset, wiping all settings with no backup | Separate no-data vs corrupt; back up the raw blob to `~/Library/Logs/flowtype/` + log | self-test (3) |
| B4 | 🔴 | `.skip` to a missing stage → `else`-less no-op → session hung permanently | `else` → `transition(.error)` (self-heals to idle) | build + reasoning |
| B5 | 🔴 privacy | Transcript text written plaintext to diagnostic log | Log `.count` only (3 sites) | grep guard |
| B11| 🟡 | 9 `print()` calls lost inside the `.app` bundle | → `AppLogger.log` | grep guard |
| B2 | 🔴 | Mic unplug/Bluetooth disconnect mid-recording → amplitude stream never finished → stuck in `.recording` forever | `amplitudeContinuation.finish()` on heartbeat freeze + RecordingStage surfaces `.error` | build + **manual** |
| B10| 🟢 | Dead code incl. blind-backspace `appendText`; also a wasteful unused `StreamingASR` model load at startup | Removed all four dead symbols + the unused streaming model load | build + grep |
| B7 | 🔴 | Clipboard restore corrupted promise/lazy content (files/images); fixed 500 ms race restored wrong text | Detect lossy snapshot → don't overwrite (type instead when short); bounded condition-poll instead of fixed 500 ms | self-test (4) + **manual** |
| B6 | 🔴 security | Transcript could be typed/pasted into a password field | AX `kAXSecureTextField` check before injection; abort with no clipboard residue | build + **manual** |

## Deferred (with reason)

- **B3 — recording-stop / session-cancel share one `currentTask.cancel()` channel.** Investigation
  proved the catastrophic symptom does **not** occur in current code (`guard isRecording` +
  synchronous `.processing` transition + session-ID guard all protect it). It is a latent
  fragility, not an active bug. Fixing it cleanly is a real refactor (add an explicit
  `stopRecording` signal to `SessionContext`) and was deferred to avoid a speculative change.
- **Code signing / notarization.** Intentionally dropped — no paid Apple Developer account.
  Distribution is via GitHub Releases + user self-authorization (`xattr -dr com.apple.quarantine`),
  documented in the README. `build-app.sh` now **hard-fails** if `mlx.metallib` is missing so a
  broken bundle can never ship.
- **EnvMigration save/flag race** (migration flag set before the 0.5 s debounced save flushes):
  low severity, only affects users upgrading from the old `.env` format. Noted, not fixed.

## Manual verification checklist (system/hardware/UI bugs)

These require a real GUI session + permissions and cannot run headlessly.

**B2 — mic freeze recovery**
1. `swift run FlowType` (copy `mlx.metallib` next to the debug binary first), or run the `.app`.
2. Connect a Bluetooth/USB mic, select it as input, double-tap Command to start recording.
3. Power off / disconnect the mic mid-recording; wait > 5 s.
4. Expect: session goes to `.error` then auto-dismisses to `.idle` (recoverable). Before the
   fix it stayed in `.recording` forever with a frozen capsule.

**B6 — password field**
1. Focus a GUI password field (e.g. https://github.com/login, or System Settings).
2. Dictate and end.
3. Expect: nothing typed/pasted into the field; log shows "secure text field — aborting
   injection"; clipboard untouched.

**B7 — clipboard preservation**
1. Copy a **file** in Finder (or an image in Preview).
2. Dictate a long sentence into a text field.
3. Expect: dictation lands; your copied file/image is not corrupted into a stripped/empty
   clipboard (short dictations are typed instead of pasted to fully preserve it).
