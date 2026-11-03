# FlowType session product validation

Scope: the 2026-10-14 session experience plan, Tasks 1–4. This matrix records the
readiness, stop/cancel, final-text and recovery contracts. It can be extended with
the later realtime and delivery plans' cases without treating those as validated here.

**Manual status: every case below is Pending.** No physical microphone capture,
hotkey input, user-app interaction, Accessibility/CGEvent posting, or clipboard
read/write was performed for this task. Automated checks exercise production logic
through injected effects and transport fixtures; they are not evidence of live UI,
hardware latency, model accuracy or real provider interoperability.

Current acceptance overlay (2026-11-03): M4 recovery and M5 validation contracts
below supersede outdated expectations while preserving the historical row IDs and
past notes. The [M5 ledger](evidence/2026-11-03-m5-validation.md) and its41 dotted
leaf IDs are the required release matrix; old R1–R6 rows are session scenarios,
not substitutes for `R1.launch10` through `R6.displays`. No manual result is promoted.

## Reproduction record

For each run, record date/tester, commit (`git rev-parse HEAD`), macOS version,
Mac/chip/RAM, app launch method, microphone/device, permission states (microphone,
Speech Recognition, Accessibility), display/scale/Spaces, target app/version and
focused control. Record trigger key, interaction mode, audio feedback setting,
`polishOnStop`, max recording duration, ASR routing policy/model and LLM provider/model.
Do not include API keys or private dictated content in shared evidence.

Build with `swift build`. For a CLI launch, ensure `mlx.metallib` is alongside the
binary as described in [CLAUDE.md](../CLAUDE.md), then use `swift run FlowType`.
Alternatively build the app with `./scripts/build-app.sh` and launch that bundle;
record which build was used because permissions depend on app identity.
Use a tester-owned scratch text field and synthetic speech. A short reference is
“请把保存按钮改成蓝色，其他部分保持不变。” For long speech, read a prepared
60–90 second passage with a recognizable final sentence and preserve the reference.

Baseline: Command trigger, Tap to Start, feedback on, auto polish on, 600-second
limit, usable configured ASR/LLM. Repeat gesture cases with Toggle and with an
available nonmodifier trigger (F13/F14/F15/Caps Lock). Record unavailable hardware
combinations as Pending with a reason; do not mark them passed by analogy.

For timing, capture the trigger release, first valid PCM/readiness event, actual
stop release, first final-delivery event and panel dismissal in a tester recording
or timestamped diagnostic excerpt (`~/Library/Logs/flowtype/diagnostic.log`). Record
individual durations and repeats, including failures. No measured latency or P95
claim is made here. “Immediate stop” means it does not wait for the 0.35-second
idle double-tap window; polish's 3 seconds is its whole-operation budget, not a
promise that ASR plus delivery completes in 3 seconds.

## Expected behavior shared by the cases

- Before the first valid PCM buffer: spinner/title `正在准备...`; recording timer
  and start cue begin only at actual readiness. Recording title is `Listening...`.
- Processing and polishing share `处理中...`; provider names, ASR preview and LLM
  token drafts remain hidden. Delivery may show `输入中...`.
- The first clean active trigger release stops immediately. Stop during preparation
  cancels capture and delivers nothing. Escape cancels; late work cannot revive
  the old session or deliver into a newer one. Idle double-tap/Toggle habits remain.
- Stop, including max-duration stop, uses `停止后自动整理` (`polishOnStop`, default
  true for both new and legacy configurations). Opt-out delivers processed ASR text.
- Optional polish can replace the transcript only with a complete result. Empty
  output, errors and the whole 3-second deadline preserve complete postprocessed
  text (raw only if processed is empty); cancellation is not fallback delivery.
- A failed/timeout polish notice appears after delivery, with `整理失败 · 已保留识别结果`
  or `整理超时 · 已保留识别结果`. Notices have no action buttons and dismiss after
  about 2.2 seconds. Actionable errors persist beyond 5 seconds until explicit
  recovery/dismissal/new recording; retry labels describe the failed stage.
- Normal panel size is 240×70 points; current actionable error size is380×156. The panel
  remains nonactivating, preserves its horizontal center when resized, and its
  visible capsule mask matches its click area. The historical actionable size
  320×94 is superseded by M4's current **380×156** recovery card; normal is240×70.
  Missing permissions/no engine use persistent current-blocker recovery. Granting
  one permission refreshes remaining blockers without dismissing a different fault.

## Manual matrix

Each row needs actual observations, evidence and a tester before its status changes.
For failures, record the first unexpected event and retain the diagnostic session ID.

| ID | Setup and reproducible steps | Acceptance observation | Status |
| --- | --- | --- | --- |
| R1 | Start from idle with a cold microphone; remain silent until readiness. Repeat 3 times. | Preparing before valid PCM; timer starts at 00:00 only after readiness; one start cue, no timer-tick cue replay or focus change. | Pending |
| R2 | Start, then immediately cleanly release the trigger again while still preparing (use a slow/first permission initialization if needed). Wait for any late readiness. | Panel returns idle; no start cue, timer, transcript, delivery or resurrected recording from the late callback. Record if preparation was too short to exercise. | Pending |
| R3 | Record the short reference after readiness, then release trigger once. Repeat auto polish on/off. | Capture stops on first release without idle double-tap delay; full result once; opt-out uses processed ASR text and does not call LLM. No intermediate text on panel. | Pending |
| R4 | Record the 60–90 second reference, stop, and compare beginning and final sentence. | Full final result once, no partial output or missing tail; timer reflects actual recording, not preparation. Record recognition differences separately from session faults. | Pending |
| R5 | Record 3–5 seconds of silence after readiness and stop; repeat with synthetic filler-only speech. | No invented text or partial draft; no-speech/empty result returns to idle or a brief notice without stale recovery buttons. | Pending |
| R6 | Set maximum duration to 10 seconds (supported minimum); speak through expiry. Repeat auto polish on/off; restore original setting. | One automatic stop at limit; same polish policy as manual stop, single final delivery/history entry, no lingering recording timer. | Pending |
| G1 | In Tap to Start idle, release once, then twice within 0.35 seconds in a separate attempt. In Toggle idle, release once. | Single idle tap does not start Tap to Start; double tap does. Toggle starts with one tap. Both stop with first active clean release. | Pending |
| G2 | Repeat a stop rapidly; press trigger while processing/polishing. | No second stop/delivery, no idle tap timer accidentally starts a new session; start requests while processing are ignored. | Pending |
| G3 | In idle and recording, use Command+C or the selected trigger with another modifier/key; then release it. | Chords preserve normal shortcut behavior and do not start/stop dictation. A later clean release still works. | Pending |
| G4 | Select a nonmodifier trigger. Hold at least 200 ms to start; hold with repeat events; stop with a short active release. | Idle hold guard works; repeats do not extend hold/start another recording; active stop does not wait for the hold threshold. | Pending |
| C1 | Escape separately during preparing, recording, ASR processing and polish streaming. Wait longer than provider response/deadline. | Each cancelled session returns idle and produces no final text, clipboard fallback or history entry; resources stop, late events stay ignored. | Pending |
| C2 | Cancel a slow session, start another, then allow the old ASR/LLM response to arrive. | Only the new session can update timer/state or deliver; old readiness/spectrum/results cannot overwrite it. | Pending |
| C3 | With a long synthetic final result, Escape while delivery is posting keyboard events; record the cancellation boundary. | No new event pair begins after cancellation is observed; an already posted pair stays balanced, no held Shift/key; no clipboard fallback or continued suffix. Already typed text may remain. | Pending |
| F1 | Start in scratch field A; switch to scratch field B while recording and again while processing. | Panel never steals focus; capture the stop target and recheck PID/focus before events. An initially changed/unsafe target safely completes via clipboard fallback; no-event cancellation remains cancelled. A failed unsafe/notDispatched attempt with fallback disallowed may suspend as deliveryBlocked. Only genuine prior events plus unverifiable/cancelled insertion retain uncertain evidence, with no automatic repeat. Record stop/dispatch targets and actual event boundary. | Pending |
| F2 | During processing focus a tester-owned nontext button, then a synthetic secure field in a separate run. | Existing policy copies complete result instead of typing into those controls; no automatic paste. Inspect only the tester's scratch clipboard; later delivery-plan cases will extend this coverage. | Pending |
| P1 | Deny microphone permission in a dedicated test app identity/profile; attempt start, then grant in System Settings and recheck/start a new session. | No recording/start cue or delivery on denial; persistent permission recovery exposes settings/recheck actions with current ownership. Repair updates remaining blockers; a new session works. Record actual recovery timing and restore the test profile. | Pending |
| P2 | Deny Speech Recognition permission while microphone is allowed; repeat with permission granted. | Record Apple preview availability; configured final ASR remains usable where supported; no preview appears on panel or stale callback after cancel. | Pending |
| P3 | Deny/revoke Accessibility in a dedicated test identity, attempt trigger/delivery; grant and relaunch as needed. | Record actual permission guidance and event-tap availability; no silent loss presented as successful typing. Restore permission and confirm a new scratch session works. | Pending |
| L1 | Select localOnly with provisioned Qwen model, quit/relaunch and run short reference without a prior dictation (cold app/model load). | Readiness truthfully reflects capture; local model remains usable; no cloud audio/context request. Record model-load time separately from capture readiness. | Pending |
| L2 | Immediately repeat L1 without relaunch (warm model), then run the long reference. | Complete result once in cold and warm runs, no stale timer/resource ownership; compare measured timings without asserting a hardware target. | Pending |
| L3 | Select localOnly with missing/unavailable model; start/stop; make model available and start again. | No accidental cloud request; understandable failure/notice, usable recovery only when offered; restored local model permits a fresh session. | Pending |
| E1 | Use a tester-controlled failing ASR service (with all configured fallback ASR paths made unavailable) to get a retryable ASR error. Wait at least 6 seconds, repair service and click retry with auto polish off. | Error persists; `重试识别` reruns preserved input with original polish opt-out, succeeds once; does not say retry polish. New recording/dismiss clears prior actions and payload. | Pending |
| E2 | Produce an actionable error with available raw text; click `复制原文`, inspect synthetic clipboard, then `忽略`. | Full available text copied; recovery remains actionable until explicitly dismissed; dismissal clears it and hides panel. | Pending |
| E3 | Enter E1/E2 error from recording; click every available button near its edge, drag panel, retry/dismiss; repeat on another display/scale/Space. | Current M4 panel grows240×70 → 380×156 and shrinks afterward; long copy and buttons remain visible/clickable, old cards cannot act on a new session, horizontal center and target focus remain intact. The old320×94 expectation is historical. | Pending |
| S1 | Tester-controlled SSE sends multiple content deltas then `data: [DONE]`; repeat with `finish_reason: "stop"` plus EOF and no `[DONE]`. | Both supported completion forms deliver full assembled polished text once, with no degradation notice or intermediate UI. | Pending |
| S2 | Send valid content then EOF without completion; repeat with malformed frame then `[DONE]`, and with `finish_reason: "length"` then `[DONE]`. | Each rejects incomplete polished draft; complete processed ASR text delivered once, failure notice only after delivery, history marked raw. | Pending |
| S3 | Send partial tokens then stall longer than 3 seconds; repeat with a stream that has only heartbeats. | Whole polish budget ends around 3 seconds from polish start; transport/producer cancels, full processed fallback delivered once, timeout notice afterward. Observe actual timing; no partial draft. | Pending |
| S4 | Complete with whitespace/empty output; repeat with no usable LLM key/provider and with identical-to-input output. | Complete processed text retained; missing configuration bypasses network; no unnecessary actionable error or incomplete output. | Pending |
| S5 | Escape during S2/S3 before fallback delivery; then allow late completion. | Nothing delivered or copied; no fallback notice/history from cancellation; underlying request ends and cannot enter provider failover. | Pending |
| O1 | With an incomplete onboarding profile, reach demo; dictate short reference and stop; move focus outside demo before completion. Repeat auto polish off. | Complete final text appears only in onboarding demo editor via notification, once; no injection into active external app, no intermediate editor text. | Pending |
| O2 | Cancel/leave onboarding demo during preparation, recording, ASR and polishing, then begin a normal session. Complete onboarding and relaunch. | Old demo results do not affect the new session; completed onboarding stays completed; saved trigger/mode/feedback/provider choices persist. | Pending |

## Automated evidence and manual result sheet

Required commands are `swift build` and `swift run FlowType --self-test`; record
their exit codes and final counts in the task report. Relevant existing checks cover
readiness/ownership, stop timeline, repeated/nonmodifier keys, feedback once,
legacy defaults/opt-out, fallback/cancellation, real URLSession SSE fixtures,
producer termination, terminal one-delivery/history gates and persistent retry.
Task 4 adds legacy saved language/gesture/provider settings, the nonmodifier
release policy used by the live event callback, and onboarding's real stage
replacement/notification delivery with complete-text, cancellation and concurrent
duplicate guards. It also exercises page-leave cleanup through a suspended demo
pipeline during preparation, recording, processing and polish, and verifies that
a notification observer can reenter cancellation without deadlock.
It does not execute capture, models, live services or actual app delivery.

Copy one entry per manual row/repetition:

```text
Case ID / repetition:
Status: Pending | Pass | Fail
Tester / date / commit:
Environment and config deviations:
Input / service fixture and completion signal:
Observed event order and timings:
Focused app/control before and at delivery:
Final text completeness / delivery count / history count:
Evidence (synthetic screenshot/video/diagnostic session ID):
Failure or remaining limitation:
```

Pass requires the row's actual setup and observations. Keep unexercised variants
Pending; automated fixture success cannot promote a manual row to Pass.

## Delivery accuracy appendix (2026-10-14 delivery plan)

The rows below extend this session matrix with the delivery-plan evidence. They
remain Pending until a tester runs the stated setup on a real app. A dispatched
keyboard or paste event is an **attempt**, not proof that the target inserted the
text; an uncertain result must never be retried automatically.

### Coding-speech evaluation cases

Use prepared 5–15 second utterances so the expected literals are known before
each run. Repeat each case in Chinese, English, and mixed speech where shown.

| ID | Utterance and setup | Accuracy/recovery evidence | Status |
| --- | --- | --- | --- |
| A1 | Chinese coding request containing ``/tmp/项目.swift``, ``--force``, ``v1.2.3-beta+build1`` and the number ``42``; polish on. | Final text retains every path, flag, version and number; ordinary sentence punctuation may be improved. | Pending |
| A2 | English request containing a URL with a query, a backtick identifier and a shell command; polish on. | URL/query, code identifier and command survive unchanged; no spoken instruction is executed. | Pending |
| A3 | Mixed Chinese/English paragraph with a multiline code block and emoji; polish on and off. | Complete beginning and tail are present once; polish off uses processed ASR text and does not call the LLM. | Pending |
| A4 | Repeat A1 with a tester-controlled refinement response that drops or changes one literal. | Damaged polish is rejected; the complete processed ASR result is delivered, history is marked raw, and the literal-preservation copy is shown. | Pending |
| A5 | 30–60 second prepared paragraph with coding terms, then silence and a rapid cancel in separate runs. | Record start/end completeness, no invented text for silence, and no delivery/history for cancellation. | Pending |
| A6 | Slow network, disconnected network, and local cold/warm model runs using the same short utterance. | Record stop→final and stop→delivery/clipboard timings; fallback remains complete and no uncollected accuracy number is claimed. | Pending |

For each A-row record WER-like observations only with the reference text and
literal pass/fail counts. Do not turn a small manual sample into a model accuracy
percentage. Record `polishFailed`, `deliveryOutcome`, and whether the recovery
copy was actionable.

### Manual app and delivery matrix

M3-A source now defaults new/missing/unknown settings to Automatic. Explicit
Unicode and the legacy candidate-app mode remain available and retain saved
values. Exercise Automatic first, then those explicit modes. The legacy list
identifies candidate adaptations, not evidence that a release accepts paste or
supports AX readback. Real app acceptance remains Pending.

| App/control | Bundle ID | Mode to exercise | Cases | Acceptance observation | Status |
| --- | --- | --- | --- | --- | --- |
| TextEdit plain text | `com.apple.TextEdit` | Automatic, explicit Unicode / legacy | A1–A4, multiline, emoji, user copies during cleanup | One delivery attempt; user clipboard is restored only while still owned; concurrent copy is never overwritten. | Pending |
| VS Code editor | `com.microsoft.VSCode` | Automatic, explicit Unicode / legacy | A1–A4, command/flag/path literals | Focus/PID recheck protects the editor; uncertain paste says it can be copied from history and does not repeat. | Pending |
| Cursor editor | `com.todesktop.230313mzl4w4u92` | Automatic, explicit Unicode / legacy | A1–A4, multiline code | Same as VS Code; record the actual focused editor and whether insertion can be read back. | Pending |
| Chrome text control | `com.google.Chrome` | Automatic, explicit Unicode / legacy | URL, CJK/English, focus switch | Switching tabs/controls before delivery routes to explicit clipboard recovery; no old target activation. | Pending |
| Terminal text input | `com.apple.Terminal` | Automatic, explicit Unicode / legacy | CJK/English, multiline synthetic text | Complete text appears once at the stop target; never submit or execute a command during validation. | Pending |
| Safari text control | `com.apple.Safari` | Automatic, explicit Unicode / legacy | URL, emoji, user concurrent copy | Record whether paste is accepted and keep an uncertain outcome when it cannot be verified. | Pending |
| Edge text control | `com.microsoft.edgemac` | Automatic, explicit Unicode / legacy | URL, path, focus switch | Same target/focus checks and no automatic repeat after an ambiguous event. | Pending |
| Unknown app / non-text or secure control | tester bundle ID | Automatic, explicit Unicode / legacy | Focus change, secure field, button, AX unavailable | Complete result is copied with the matching recovery message; it is never blindly typed into a non-editable target. | Pending |

For every app row record app version, bundle ID, focused element before stop and
at delivery, selected mode, delivery outcome, and whether a tester copied the
result manually. Do not call the candidate list a compatibility certification.

### Delivery evidence fields

Capture `stop→final`, `stop→dispatch`, and `stop→clipboard` separately and report
P50/P95 with the repository definition `round((n - 1) × p)` on sorted samples.
Also count duplicate attempts, focus-change recoveries, clipboard ownership
losses, uncertain dispatches, preserved literals, and successful manual recovery.
The current repository has no live measurements; leave every unrun row Pending.

M3-A presentation source (2026-11-02) adds a metadata-only recent-delivery menu.
Manual acceptance must distinguish sent typing/paste, clipboard recovery naming
the original target, and uncertain dispatch. The uncertain copy is
「已发送，但无法确认是否插入；可从历史复制」. Check an open menu and reopen it,
then cancel a session and release an older callback after a newer delivery;
neither may erase or replace the newer summary. Synthetic controller/menu tests
do not establish real insertion, clipboard consumption within 150ms, or any
Pending app/device/service result. Final bundle and real-app execution follow
stable M3-A/M3-B source review; no intermediate Task3 GUI batch was run.

M3-B Task2 source integration (2026-11-02) adds stop-time preflight inside the real
ASR stage, so direct entry and explicit ASR Retry cannot skip it. Digital silence
and empty capture produce notices before provider/preview/downstream effects;
known malformed PCM produces a non-retryable recording-data error. Full original
short/head/tail/delayed audio and uncertain detector results retain the existing
recognition chain. Existing live resources are cancelled without finish on silence,
and scan time consumes the same stop budget. Synthetic real-controller coverage
also protects previous delivery summaries against silence and obsolete results.
See the [M3 evidence](evidence/2026-11-02-m3-validation.md) for source evidence and
limits. Actual microphone silence/quiet-word/noise calibration, the app matrix,
continuous 20 rounds and V1–V5 remain **Pending**. No synthetic waveform proves
human-speech accuracy, real target insertion, or zero prior realtime upload/cost.

M3 最终源码更新：`f7554ee`，完整自测4124/0、全 M3 修复限定复审通过；automatic 分块回退逐键对复检，真实发键后取消同步保存 uncertain。最终 app 已构建，但严格整体签名仍受既有 unsigned mlx.metallib 限制；[证据与产物身份](evidence/2026-11-02-m3-development/README.md)。全部实际应用/剪贴板/声音校准与 V1–V5 未覆盖项仍 Pending。

2026-11-03 update: the preceding M3 signature note describes that historical
candidate. M5-B3 at `c21cb25` proved a new Resources shader layout, strict/deep
signature, moved resources, actual Metal and MLX micro-operation. It does not
prove ASR inference or the final C candidate. C1 code validation passed24334/0;
C2 added a code-only CI workflow, with remote execution still Pending. C3 source
and its all-Pending manual template are awaiting review; final technical ten smoke
and every real R/V leaf remain Pending.

For every current delivery test, record whether an event actually left the process.
Temporary clipboard staging alone is not dispatch. An initially changed/unsafe
target completes via safe clipboard fallback; cancellation before any event is
cancelled. `deliveryBlocked` describes a suspended delivery failure, such as an
unsafe/notDispatched paste when fallback is disallowed or a failure that must
preserve the existing clipboard. Only after a genuine event can unverifiable or
cancelled insertion be `deliveryUncertain`, with explicit copy/history recovery
and no automatic retransmission. V3/V4 must record these distinct outcomes.
