# Typeless 2.8.1 error and recovery evidence for FlowType M4

Research date: 2026-11-02. FlowType checkout inspected at `68c72d4b7cb135279d813a43c1050c71921e4e73` (requested baseline `68c72d4`). Scope: passive static inspection of recovered source; no app/GUI execution, network requests, builds, tests, target scripts, or product edits. This report is the sole authored file.

## Evidence standard and provenance

- **Observed** means a literal branch, call, option, or string in the recovered source. It does not assert runtime execution or correctness of Wakaru recovery.
- **Derived** means an interpretation supported by the cited call chain. It is not an observed user interaction.
- **Unknown** means the inspected static evidence cannot establish the property. Absence claims below are limited to the cited functions and bounded searches, not the complete shipped binary.

Source root for all source citations below: `/Users/yiheng/pycode/typeless-re/`. Abbreviations:

| ID | Relative file | SHA-256 |
| --- | --- | --- |
| Q | `sources-recovered/renderer/static/js/qA149QP2.mjs` | `6764745c0deb4d95cea3df8cf30f0c7c870146ea333ad72c8d0d2bc40a7eac14` |
| U | `sources-recovered/renderer/static/js/UfR9-a2Z.js` | `ec04a89c8bb0dd2954ac7769c0a59de745c3390494680e9012a2aa37bce942c2` |
| X | `sources-recovered/renderer/static/js/UfR9-a2Z/chunk_xt.js` | `c20380a072e96859b35f498e0c17c76a9cafac21fd7c41ba6acab8687dafe537` |
| M | `sources-recovered/renderer/static/js/UfR9-a2Z/chunk_mo.js` | `023558825f65c5a3fe7c8119633067a35ec07e122ed69cb0664234a2606e247a` |
| L | `sources-recovered/renderer/static/js/2BchMC1V.js` | `a143a121e2df75ecee1a16c71354d570bae8dba41b86d1ee4df60687c70a1e76` |
| C | `sources-recovered/renderer/static/js/CeQePRHT.js` | `37a55829efd00669bbce0b1f645476f697d2c39e96e6b89091ed925389c551b4` |
| R | `TYPELESS-2.8.1-REVERSE-ENGINEERING.md` | `0db801ff8d15d0ddb472e3de5d6d9ae2e3fd40f920f6084d6952151998e30c2f` |
| E | `evidence/p2-error.json` | `8629171f11b7ee954783219d7a291a26e8d3dfab80ad2ebafe9d1711c0d5b5d5` |

R and E were used as discovery indexes, not as independent proof of behavior. R:24 states recovered coverage is only 11 of 83 JS inputs. The primary findings below come from the named recovered functions and their imports/exports. Full application coverage, production server behavior, active locale, visual layout, and actual persistence success were not verified.

## Findings that change the broad report's interpretation

1. **Observed:** `FATAL_POOR_INTERNET_CONNECTED` from the listed WebSocket close codes carries `needStop:false` (U:8597–8612). Its consumer sets a weak-network downgrade flag and returns, without emitting `ERROR.FATAL` or `ERROR.RECOVERABLE` (Q:4152–4185). The name does not imply that this path immediately enters `failure`. R:223/E's fatal enumeration flatten this distinction.
2. **Observed:** both `error` and `failure` accept fresh recording triggers, and fatal error alerts can offer working saved-audio Retry actions. “Fatal means no retry” is too broad (Q:5904–5948; X:604–640,820–835; M:657–680).
3. **Observed:** the `RETRY_AUDIO` chain reads saved history and then calls compression plus `audio:ai-voice-flow` with `isRetry:true`; the `WEBSOCKET.SEND_RETRY_DATA` event name does not establish WebSocket audio retransmission (Q:4578–4588; U:8198–8300).
4. **Observed:** no-speech detection maps to the UI function named `showMicrophoneAccessDeniedAlert`, with “Couldn't access your microphone” copy. It does not map to a dedicated no-speech notice in this recovered call chain (Q:5109–5110; U:12435; X:758–771,1551; L:3359–3360).
5. **Observed:** alert Retry resolves the **latest history ID at click time**, not an ID captured from the failed session. Failure to resolve it records telemetry and presents no new recovery UI in this helper (M:657–680).

## Error taxonomy and state handling

**Observed:** `assignFatalError` records `errorType:'fatal'`, `onStopTarget:'failure'` and the event payload/error message (Q:5050–5060). `assignRecoverableError` records `errorType:'recoverable'`, `onStopTarget:'error'` (Q:5061–5069). Top-level `ERROR.FATAL` and `ERROR.RECOVERABLE` both first enter `.stopping` (Q:5246–5253). `stopping` requests recorder stop and cancels volume detection; `RECORD.STOP_COMPLETE` then selects `finishing`, `error`, `failure`, or `idle` from `onStopTarget` (Q:5751–5816). Initializer exceptions are classified by whether `error.message` includes `RECOVERABLE` (Q:5170–5173,5363–5372).

| Error | Observed trigger | Observed state/UI mapping | Evidence |
| --- | --- | --- | --- |
| `RECOVERABLE_NOT_LOGGED_IN` | `checkLoginStatus()` false | `error`; `br()` | Q:4690–4694,5105–5113 |
| `RECOVERABLE_NO_SPEECH_DETECTED` | Local volume detector returns `detected:false`; detection starts 1s into recording, requested window 5s | `stopping` → `error`; `bs_1()` | Q:4844–4848,5169,5587–5600,5109–5110 |
| `FATAL_MICROPHONE_PERMISSION_REQUIRED` | Initialization microphone check false; recorder `onNotAllowedOrFound` also emits it | `failure`; `bt_1()` | Q:2852–2861,4714–4727,5088–5089 |
| `FATAL_ACCESSIBILITY_PERMISSION_REQUIRED` | Initialization accessibility check false | `failure`; `bu()` | Q:4701–4724,5090–5091 |
| `FATAL_NOT_INTERNET_CONNECTED` | `navigator.onLine` false during initialization | `failure`; `bv()` | Q:4696–4698,5092–5093 |
| `FATAL_POOR_INTERNET_CONNECTED` | U close-code mapping; see consumer distinction below | **If delivered as fatal**, `bw()`; listed close path itself only enables downgrade | U:8597–8612; Q:4170–4179,5094–5095 |
| `FATAL_TRANSCRIPTION_TIMEOUT` | Refining timer expires; clears WebSocket audio ID and marks history error | `failure`; `bx()` | Q:4756–4825,5096–5097 |
| `FATAL_NOT_SET_TARGET_TRANSLATION_LANGUAGE` | Missing/failed target-language lookup in translation availability check | `failure`; `by()` | Q:4911–4925,5098–5099 |
| `RETRY_AUDIO_FAILED` | A delivered retry-history event fails the nonempty ID / defined `history.audio` guard | `failure`; generic `bz()` | Q:5884–5900,5100–5101 |
| Other fatal detail | Error event data or thrown message | Generic `bz(async()=>{}, error)` | Q:5050–5060,5100–5101 |
| Other recoverable detail | `ERROR.RECOVERABLE` may carry other details | Stored in `error`; no matching presentation branch in this handler | Q:5061–5069,5105–5113 |

**Observed:** `error` and `failure` both allow primary/hands-free/translation keys and the hands-free button to initialize a new session (Q:5904–5948). `failure` clears its error on exit; `error` resets mode on exit but has an explicit `CLICK.RETRY_BUTTON → idle + clearError` transition. That event does not itself capture audio or process old audio (Q:5922–5924). The hook exposing `handleRetryButton` sends exactly that event (Q:6718–6722,7058).

**Derived:** Typeless's fatal/recoverable labels primarily choose stop destination and presentation. They do not form a complete user recovery policy. Restarting capture, fixing configuration, retrying old audio, and dismissing an alert are distinct operations that must be inspected separately.

## Exact UI mappings, copy, actions, and lifetimes

The alias chain is **Observed**: Q imports `br`, `bs as bs_1`, `bt as bt_1`, `bu`…`bz` from U (Q:14); U imports their implementations from X (U:2) and re-exports `Qo→br`, `es→bs`, `ss→bt`, `os→bu`, `ns→bv`, `rs→bw`, `zo→bx`, `hs→by`, `Go→bz` (U:12435). Therefore the following are function-body evidence, upgrading the broad report's unexpanded UI mappings.

English strings below are literal recovered locale entries, normalized only to decode `\x20`/`\x27`. Runtime display language is unknown. Title/body keys and button keys are observed in X.

| Q UI function → X implementation | English title/body | Configured presentation and action | Primary evidence |
| --- | --- | --- | --- |
| `br → Qo` | “You have been signed out”; “Everything is OK, but you will need to sign in again to continue!” | `info`, 5s, `closeFloatingButtonOnDismiss:true`; Sign in → `auth:start-app-login('login')`, failure fallback `page:open-entry-window` | X:724–739; L:3316–3317 |
| `bs_1 → es` | “Couldn't access your microphone”; “Please check if your microphone is muted or try a different microphone.” | `error`, 5s; Open settings → app settings modal | X:758–771,408–410; L:3359–3360 |
| `bt_1 → ss`, default diagnosis | “Microphone permission required”; asks to re-enable microphone in System Settings | `error`, 9999s, `closable:false`; Open settings → `permission:request {microphone,type:'request'}` | X:894–917; L:3362–3363 |
| `bt_1 → ss`, restricted/unavailable diagnosis | “Microphone unavailable”; says another app or system/security setting may block access | `error`, 9999s, `closable:true`; Get help → `${b}/help/troubleshooting/microphone-unavailable` | X:894–917; M:751; L:3364–3365 |
| `bu → os` | “Accessibility permission required”; asks to re-enable access in System Settings | `error`, 9999s, `closable:false`; Open settings → `permission:request {accessibility,type:'request'}` | X:878–893; L:3310–3311 |
| `bv → ns` | “No internet connection”; asks to check connection in System Settings | `error`, 24h, closable, closes floating button on dismiss; Open settings → `page:open-url-scheme('network-settings')` | X:803–819,401; M:740–744; L:3368–3369 |
| `bw → rs` | “Poor internet connection”; “Couldn't finish writing. Click Retry to continue.” | `warning`, 24h, closable, closes floating button on dismiss; Retry → `zt('Transcript error')` | X:820–835,401; L:3370–3371 |
| `bx → zo` | Non-pro: “High demand right now”; `pro` / `pro_trial`: “Unstable internet connection”; both “Couldn't finish writing. Click Retry to continue.” | `error`, 24h, closable; Retry → `zt('Transcript timeout')` | X:622–640,401; L:3398–3401 |
| `by → hs` | “No target language selected”; “Select a target language in Settings to enable translation.” | `info`, 3s, closes floating button on dismiss; Open settings → app settings with `openTranslationTargetLanguageModal:true` | X:1086–1103,408–410; L:3402–3403 |
| `bz → Go` | “Something went wrong”; body is supplied error detail when nonempty, otherwise “Couldn't finish writing. Click Retry to continue.” | `error`, 24h, closable; Retry first calls `zt('Transcript error')`, then optional callback | X:604–621,401; L:3396–3397 |

**Observed:** `ss` calls `permission:diagnose-microphone`; only `systemPermissionGrantedButDeviceUnavailable` and `systemPermissionRestricted` select the unavailable/help variant (X:894–916). Failure to diagnose is swallowed and follows the permission-required variant. The inferred diagnosis is UI treatment, not proof that the physical device is actually busy.

**Observed:** common alert button `xe` calls its onClick, then by default closes the floating alert and calls `f()`; refocus is performed unless `disabledRefocusWindow:true` (X:491–538). `f` re-exports `r9`, which broadcasts `ESCAPE` (C:30379–30385,40691); the recording-machine receiver forwards ESC only when `force` is true or current state is `error`/`failure` (Q:6511–6523). The button's cleanup path is shared with action behavior; its existence is not evidence that it rerecords.

**Derived:** permission blocks are presented as long-lived actionable errors. Login and missing-language problems are actionable but short-lived; a 3–5s lifetime may remove the action before the user can use it. The labels `info`/`warning`/`error` do not by themselves describe recoverability or persistence.

## What Retry actually does

### Alert Retry and cancellation Undo: reprocess the latest saved recording

1. **Observed:** `zt(entryPoint)` queries `db:history-latest-id`, then posts `voice-record-retry` with that ID (M:657–663). It does not accept a failed audio ID parameter. Failure only gathers history-retention/reason metadata and emits `error_monitoring_voice_dictation_retry_initiation_failed`; no alternate UI is shown in this helper (M:664–679).
2. **Observed:** the window listener sends `RETRY_AUDIO(audioId)` (Q:7003–7021). A separate shared retry store can supply an explicit audio ID and reach the same event (M:618–656; Q:7022–7033).
3. **Observed:** top-level `RETRY_AUDIO` enters `.retrying` (Q:5275–5277). `audioRetryActor` reads `db:history-get` and posts `RECORD.RETRY_HISTORY` (Q:2974–3013). The actor uses a cancellation flag to avoid sending that event after its cleanup.
4. **Observed:** nonempty ID plus `history.audio !== undefined` enters `finishing`, forwarding `WEBSOCKET.SEND_RETRY_DATA`; failed guard produces `RETRY_AUDIO_FAILED` with fatal type (Q:5865–5903). **Important limit:** unsuccessful DB lookup, absent history ID, or thrown exception returns/swallows before this event; it is not covered by that guard and does not necessarily reach the failure branch (Q:2993–3007).
5. **Observed:** the WebSocket actor sets current audio ID, clears its completed-ID marker, and calls `sendRetryRequest(audioId)` (Q:4578–4588). It does not use the forwarded `history` payload in this branch.
6. **Observed:** `sendRetryRequest` compresses by saved audio ID, invokes `audio:ai-voice-flow` with the resulting bytes, a unique retry abort ID, and `isRetry:true`, then publishes refined result/completion or fatal error details (U:8198–8295). `finally` asks to clean the compressed audio file (U:8296–8300). The recovered telemetry explicitly labels this as `http:retry_request_*`; the exact main-process transport implementation was not separately audited here.

**Derived:** this is retranscription/reprocessing of existing saved audio, not microphone rerecording. A fresh recording is initiated by the recording shortcut/button paths in `error`/`failure`. The UI label “Retry” spans at least two internal events: alert Retry reprocesses saved audio; `CLICK.RETRY_BUTTON` only returns to idle.

**Observed:** generic fatal mapping passes an empty async callback to `bz` (Q:5101), but its Retry is still functional because `Go` invokes `zt` before invoking the callback (X:613–617). Calling this Retry a no-op would be incorrect.

**Unknown:** retry attempt limit, backoff policy, server idempotency, whether latest-ID selection can target a different recording under real concurrency, retained-audio availability after retention expiry, and user-facing handling for failed history lookup. The inspected retry function has no loop/backoff counter, but this is not a whole-app absence claim.

## Network degradation and transient progress versus actionable failure

**Observed close handling:** `handleClose` deduplicates a close. Embedded reason code `4018` with server time adjusts time offset and reconnects only when over 10s since the last reconnect and not already connecting/connected (U:8495–8528). Embedded codes `4000/4404/4001/4003`, and other embedded code+reason pairs, produce `needStop:true` errors and return (U:8529–8561). Other closes default to code 5000, `needStop:true`; `[1000,1001,1005,1006,1012,3001]` override the detail to `FATAL_POOR_INTERNET_CONNECTED` and `needStop:false` (U:8585–8612). Even code 1000 is in that override; do not relabel the whole list “abnormal” as a literal protocol fact.

**Observed consumer behavior:** an active session plus `needStop:true` emits `ERROR.FATAL`, requests session/context finalization, marks history error, clears current ID and buffers (Q:4152–4169). A `needStop:true` error with no active audio ID is ignored by the outer guard. `needStop:false` plus the poor-network detail enables the downgrade flag, optionally resets socket state/queued buffers, and returns (Q:4170–4179). Other non-stopping details emit `ERROR.RECOVERABLE` (Q:4180–4184).

**Observed:** the downgrade/slow-processing path calls a separate `Ts`/`bl` informational indicator (Q:4238–4242,4478–4483; U:12435; X:1497–1508). Its English title is “Taking longer than usual…” (L:3410). It has no action, hides the type icon, is nonclosable, and configures a 24h `PERSISTENT` lifetime (X:402–406,1497–1508). It is semantically temporary progress information, not a short auto-expiring toast. Session clear explicitly hides it (Q:4613–4625).

**Observed:** normal refinement races WebSocket and fallback completion; fallback starts immediately for downgrade metadata, otherwise after `taking_longer_alert_delay_ms ?? 6000` and compression completion. It calls `audio:ai-voice-flow` with `isRetry:false` (U:7620,8302–8362,8379–8430). It checks cancellation before sending and after response (U:8380–8388,8404–8413,8431–8464). A missing refined result logs fallback failure rather than directly displaying a fatal alert in this function (U:8458–8462). Refining timeout independently supplies the eventual fatal timeout path (Q:4756–4825).

**Observed:** generic service messages `audio_processing_error/transcription_error/refine_error/refine_selected_text_error/error` call `onError` with `needStop:true`; absent detail falls back to “Transcript failed to load. You can always recover it from History.” Code 90002 with exact detail “Unknown message type” is skipped (U:8690–8705). This fallback text is a client claim, not proof every recording is durable.

**Derived:** a better M4 model separates “work continues, no user intervention needed” from “work stopped, action needed.” Typeless supplies an example of that separation, but its cloud-specific offline/auth/paywall/transport behavior is not a requirement for FlowType's local route.

## Preservation of text/audio and cancellation safety

### Audio and history

- **Observed:** stopping computes history status (`dismissed` for escape; `error` for error/failure/interruption; other cancel-like cases dismissed) and upserts status/duration when an audio ID and recorder result exist (Q:2880–2905). When `allAudioBlob` exists it calls `b8(audioId, blob)` before publishing stop completion; missing blob is caught (Q:2906–2916).
- **Observed:** `b8` converts the blob and invokes `db:history-save-audio`, then optionally compresses/saves Ogg audio (U:7658–7695). The caller does not await `b8` (Q:2910), so `RECORD.STOP_COMPLETE` does not prove completion of the asynchronous save.
- **Observed:** history upsert is an IPC request (U:7622–7632); session-context finalization persists `audio_context` when available and returns false on failure (Q:3503–3522). Clear-session functions delete in-memory entries (Q:3524–3530). Their name “finalizeSaveSessionToDB” must not be read as proof that audio or transcript text was saved: this particular method stores context only.
- **Derived:** errors and cancellation are designed to preserve recoverable audio/history where capture produced a blob and a valid ID. **Unknown:** file/DB durability, complete audio on every error path, save race outcomes, retention/deletion behavior, and recovery after process crash. Never promise unconditional preservation from this evidence.

### Text

- **Observed:** partial transcription text accumulates in `transcriptionChunks` in memory (U:8734–8749). Reset restores initial empty text/chunks/current ID (U:8176–8182,8479–8487).
- **Observed:** successful refinement writes `ai_result.refined_text` into mode metadata and `refined_text/status:'completed'` into history (Q:3205–3218). The completion handler only runs output delivery/persistence for its active audio ID (Q:4124–4136).
- **Observed:** delivery uses final nonempty text and then current input-context/editability checks (Q:3791–3803,3853–3869). This report does not audit the full insertion implementation.
- **Unknown:** durable preservation of partial/raw transcript text on every ASR/refinement failure. The inspected error paths save audio/status/context, but do not demonstrate a universal “copy whatever text exists” recovery affordance. Existing editor contents and selection are not proven safe under all retry/cancel races by these snippets.

### Cancel and late results

- **Observed:** global ESC marks escape, hides alert, clears error, and stops toward idle (Q:5235–5244). Hands-free and translation cancel/ESC use `assignCancelRecordingTarget` toward idle without necessarily setting the escape flag (Q:5083–5085,5686–5693,5739–5746).
- **Observed:** finishing ESC moves to idle, clears finishing/error, marks history dismissed, and shows a cancellation alert (Q:5845–5862). That alert lasts 5s and its Undo invokes `zt('Transcript cancelled')`, again selecting latest saved history (X:556–574; M:657–663).
- **Observed:** idle entry asks the socket actor to clear audio ID (Q:5297–5304). That actor finalizes context, clears its active ID, ends the chunk session, hides weak-network notice, resets state, and clears buffers (Q:4613–4625). Its refinement callback checks active ID equality before delivery (Q:4124–4136).
- **Observed:** the retry-history loader has a cleanup cancellation flag (Q:2997–3011). Fallback has an explicit abort API (`audio:abort-ai-voice-flow-request`) and cancellation flag, used by `cancelFallbackRequest`/`interruptSession` (U:8364–8378). Successful WebSocket completion cancels competing fallback and deduplicates completed IDs (U:8750–8784).
- **Limit:** `resetState` itself does not call fallback abort or cancel the separately created retry request (U:8176–8182). `sendRetryRequest` publishes after awaits without an explicit per-request cancellation check in its body (U:8198–8300). Active-ID gating is evidence of a late-output guard, not a demonstrated guarantee of transport cancellation or immunity to reused-ID/new-retry races. No runtime race tests were performed.

## Recommended FlowType M4 lessons — design input only

These are **recommendations/derived**, not Typeless facts or an implementation plan. The controller owns M4 design and acceptance criteria.

1. **Attach recovery actions to the failed stage and retained resources.** Permission/configuration problems should open the relevant settings/help; transient processing should show nonblocking progress; a stopped operation should present a specific available next action. Keep ASR, rewrite, and insertion errors distinguishable so retrying a later stage need not redo earlier successful work.
2. **Make re-record, retranscribe, retry rewrite, copy text, retry insertion, and dismiss distinct actions.** Do not let one ambiguous Retry label hide idle-reset behavior or bind itself to whichever recording is latest. Carry the failed session/attempt ID with the action and check that its audio/text still exists.
3. **Preserve usable output before presenting failure.** For a rewrite/insertion failure, expose the already available text immediately; for ASR failure with retained audio, offer retranscription only if audio save is confirmed. Typeless demonstrates saved-audio retry, but does not demonstrate universal text salvage or durable audio completion.
4. **Treat cancellation as an explicit session/attempt boundary.** Prevent cancelled/older attempts from changing current state or inserting text; cancel owned tasks/requests when supported, and gate late callbacks even when cancellation cannot stop the provider. Do not infer safety from clearing a spinner or resetting error state.
5. **Separate progress notices from recovery surfaces.** “Taking longer…” can accompany ongoing automatic fallback without requiring action. Actionable failures should remain discoverable long enough for settings/retry/copy; avoid losing the only action to a 3–5s timeout.
6. **Use accurate failure language.** Avoid Typeless's observed no-speech → microphone-access mismatch. Silence does not prove microphone denial; a timeout does not prove high demand or unstable internet. Use an observed condition plus an appropriate action, with technical detail available separately.
7. **Keep cloud facts scoped to a cloud attempt.** A missing network/login or a cloud transport error need not block local recognition. Typeless's WebSocket close codes, time-sync reconnect, paywall, retry backend, and timing constants are not transferable evidence about FlowType's local ASR behavior.
8. **Specify terminal outcomes for failed recovery setup.** Missing history/audio and failed resource loading must end with a visible explanation and available actions. The recovered actor can silently return before its `RETRY_AUDIO_FAILED` branch, which is an anti-pattern to avoid.

## Open evidence limits

- Static recovered-code behavior was inspected, not executed. The supplied broad report and p2 JSON are secondary analyses, not additional runtime observations.
- English locale strings were read; the production locale, timing scheduler, rendered appearance, and focus behavior were not observed.
- Main-process DB persistence, raw source equivalence, retention enforcement, server retry limits/idempotency, and all cross-window callers were outside this bounded audit.
- No claim is made that cancellation always aborts transport, that every error has saved audio/text, or that a Retry action always succeeds.
