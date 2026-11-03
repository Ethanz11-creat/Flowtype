# Task 2 report — compact frosted capsule and honest state presentation

Status: implemented, self-reviewed, all required focused verification green. Parent owns plan/progress, final independent review, evidence publication and full code/artifact lanes.

Base: `a7b5d7e` (Task 1 product `139e123`). Owned commit: `db58ea6` (`feat(capsule): ship compact frosted state presentation`), 15 owned source files only.

## Result and API handoff

- `CapsuleView()` remains the production environment-object view. Ordinary geometry is **216 × 54**, radius 27; recovery remains **380 × 156**, radius 78. `FloatingPanel` initial content rect and initial resizing now use 216 × 54. No changes to drag monitors, nonactivation, all-spaces behavior, mask/resize ownership or WindowManager focus behavior.
- Actual view keeps original dark blue-purple native HUD material/radial frost and brand gradient, 13pt semibold title / 11pt medium subtitle. Removed whole-panel scale breathing. Ordinary horizontal insets 16, signal region 40 × 24, gap 12, copy area 132. Recovery uses 28pt insets / 40pt symbol / 12pt gap / 272pt copy and the same two-column action grid. Subtitle contrast is raised; useful long preparation diagnostics can wrap to two lines, recovery diagnostics to three with no head truncation. Reviewed real 1× long diagnostic and uncertain-delivery PNGs: complete reason, actions and category title are visible.
- `CapsulePresentation(state:preparationNotice:notice:slow:recoveryCard:resourceBusyNotice:maxRecordingDuration:)` is an equatable pure presentation value. It exposes `title`, `subtitle`, `timer`, `indicator` (`waveform`, `spinner`, `symbol`), `size`, `hidden`, `actions`. `SessionController.capsulePresentation` is its read-only observable projection from canonical session/presentation storage.
- Recording is the only waveform state and still uses Task 1 `AudioVisualizer()` unchanged, including complete `visualizationFrame`, session identity, silent rest and Reduce Motion behavior. Preparation/processing/polishing use a spinner; injecting uses text cursor, notices use semantic symbols, errors use category symbols. No checkmark/green success promise, partial transcription, synthetic progress or dwell.
- Exact approved ordinary copy: preparation `正在准备` / `启动麦克风` unless useful preparation diagnostic; recording `Listening...` / timer + `正在听写`; processing `正在处理` / `识别语音中`; polishing `正在处理` / `整理文字中`; slow `处理时间较长` / `仍在处理，请稍候`; injecting `正在输入` / `请保持当前光标`; clipboard `结果已复制` / `按 ⌘V 粘贴`; no-speech `未检测到声音` / `请重新录音`; empty `未录到音频` / `请重新录音`. Uncertain recovery title is exactly `请检查输入结果`.
- `CapsuleNotice` is typed emission metadata: `.noSpeech`, `.emptyAudio`, `.clipboard`, `.polishFallback(.failed/.timedOut/.literalPreserved)`, `.resourceBusy`. `SessionContext.capsuleNotice` carries it. Real ASR, Polish and Injection stages set it at emission. Existing `.notice(String)` and `completionNotice` strings remain compatible for existing consumers/tests. No arbitrary string matching determines a timeout or outcome. Resource-busy legacy state string is retained while the compact view says `暂时无法开始` / `资源使用中，请稍后再试`.
- `CapsuleNotice.completion(outcome:fallback:)` prioritizes actual clipboard outcome over any polish fallback. Uncertain/cancelled delivery cannot produce a polish fallback notice; controller uncertain terminal recovery remains ahead of notice selection. Clipboard duration **5 seconds**; all gentle/fallback/default notices **2.2 seconds**. Successful dispatched completion without fallback hides promptly.
- `RecoveryPolicy.transientASR` uses the same `canRetry` Boolean for its claim and action (actual ASR stage, retained nonempty audio, no prior event). Missing resources say re-record. Delivery blocked/uncertain text offers copying only when result exists; uncertain may offer history if available. No delivery retry was added. Full M4 action matrix remains intact; only its old resource-independent copy goldens were updated.

## Timer ownership / lifecycle invariants

- `CapsulePresentationTiming(now:delay:)` is an injectable MainActor clock/wait seam; defaults use monotonic `systemUptime` and cancellable `Task.sleep`. Deterministic tests advance virtual time and intentionally resume cancelled waits rather than sleeping six seconds.
- One `slowOperation` tuple (UUID token, session ID, monotonic start) begins at `endRecording()` immediately after the existing **20-second CompletionBudget**/stop timestamp, before provider work. Explicit eligible ASR retry creates a fresh operation alongside its existing fresh 20-second budget. Provider and polish state updates do not restart the clock.
- Slow timer only sets `slowValue` for currently-owned processing/polishing context after six seconds. It never calls `transition`, ends a resource lease, cancels the context, changes pipeline stage, saves history, resends text or changes budget. Canonical slow value and generation are committed before presentation publication, with no post-publication assignment, so synchronous cancellation wins.
- Token + context identity + active session + cancellation checks guard slow callbacks. Entering idle/notice/error/preparing/recording invalidates slow work; reset/cancel/new accepted session invalidate it too. Deinit cancels the stored tasks. Readiness failures and uncertain completion converge through terminal transition and therefore clear the slow operation.
- Notice dismissal uses a separate UUID token, not terminal session ID (which is 0). Any new transition, reset or accepted session invalidates the previous dismissal token and cancels its task. Even a non-cooperative old delay returning while a different zero-session notice is showing cannot dismiss it. No new SessionState cases were introduced.
- Existing generation checks around injected effects, observers, readiness, history, resource coordinator and waveform publication remain in place. Timing clock publication paths recheck ownership after injectable clock calls. First-PCM readiness and resource-drain behavior are unchanged.

## RED → GREEN and regression evidence

All logs live in `.superpowers/sdd/2026-11-03-capsule-waveform/`. Builds and source edits were kept sequential; no source was edited while a compiler was running. No full code/artifact lane was run by this task.

1. Added focused `--capsule-presentation-only` entry to `SelfTest` and runtime allowlist plus full-suite registration. Initial tests used existing APIs. `swift build > .../task-2-red-build.log 2>&1`: exit 0. `task-2-red-run` presentation command: exit **1**, **2 passed / 6 failed**, exactly ordinary width/height, preparation/processing/injecting copy, and missing-original-audio retry claim. stdout/stderr retained.
2. Added pure presentation/types and injected timing API with controller scheduling still unimplemented, plus real-controller non-cooperative-wait tests. `swift build > .../task-2-timer-red-build.log 2>&1`: exit 0. `task-2-timer-red-run`: exit **1**, **8 passed / 1 failed** (`stop schedules one slow signal`). Guarded test exits after that missing prerequisite.
3. Implemented controller timers/outcome projection, native view and stage metadata. `swift build > .../task-2-green-build.log 2>&1`: exit 0 (39.74s). `task-2-green-run`: exit **0**, **25 passed / 0 failed**, including real-controller ownership/budget persistence, provider update no-restart, cancelled slow callback/new session, synchronous objectWillChange cancellation, actual clipboard-over-fallback, gentle duration and old zero-session notice timer isolation.
4. Expanded pure/state/emission checks and added missing-result delivery claims before changing policy. `swift build > .../task-2-policy-red-build.log 2>&1`: exit 0. `task-2-policy-red-run`: exit **1**, **105 passed / 2 failed**, exactly blocked/uncertain delivery without result must not claim available copy. Fixed policy based on typed `RecoveryResources`.
5. Initial isolated native preview (`task-2-preview-initial-run`): exit **1**, **4 passed / 34 failed** because automatic backing produced 2× bitmaps. Actual logical geometry was correct. Extended existing native capture helper with optional explicit `pixelScale`; capsule route asks for 1× while main-window preview behavior remains the default. No markup replica was introduced.
6. `swift build > .../task-2-final-build.log 2>&1`: exit 0 (40.73s). Initial combined focused run: presentation **111/0**, waveform **45/0**, native **938/0**, preview **40/0**, M4 **19468/320**. Complete M4 stderr classified: 126 outdated transient copy rows, 96 outdated blocked copy rows, 96 outdated uncertain copy rows, plus 2 base exact-copy goldens. No action/lifecycle failures. Parent authorized updating resource-aware copy goldens; all resource/action matrix combinations and exact action assertions remain.
7. Final build after golden changes and accurate resource-busy subtitle: `swift build > .superpowers/sdd/2026-11-03-capsule-waveform/task-2-regression-build.log 2>&1`: exit **0**, **Build complete! (30.02s)**, no warnings/errors.
8. Final commands below all exited **0** with **empty stderr**. Complete stdout/stderr were inspected; the native log's 40 lines list all native groups. Each command used a distinct new canonical isolated root:

```sh
.build/debug/FlowType --self-test --capsule-presentation-only --validation-root /Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-03-capsule-waveform/task-2-verified-presentation-run > .superpowers/sdd/2026-11-03-capsule-waveform/task-2-verified-presentation.stdout 2> .superpowers/sdd/2026-11-03-capsule-waveform/task-2-verified-presentation.stderr
# 111 passed / 0 failed

.build/debug/FlowType --self-test --capsule-waveform-only --validation-root /Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-03-capsule-waveform/task-2-verified-waveform-run > .superpowers/sdd/2026-11-03-capsule-waveform/task-2-verified-waveform.stdout 2> .superpowers/sdd/2026-11-03-capsule-waveform/task-2-verified-waveform.stderr
# 45 passed / 0 failed

.build/debug/FlowType --self-test --native-client-only --validation-root /Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-03-capsule-waveform/task-2-verified-native-run > .superpowers/sdd/2026-11-03-capsule-waveform/task-2-verified-native.stdout 2> .superpowers/sdd/2026-11-03-capsule-waveform/task-2-verified-native.stderr
# 938 passed / 0 failed; includes trial session/controller/resource ownership

.build/debug/FlowType --self-test --m4-recovery-only --validation-root /Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-03-capsule-waveform/task-2-verified-m4-run > .superpowers/sdd/2026-11-03-capsule-waveform/task-2-verified-m4.stdout 2> .superpowers/sdd/2026-11-03-capsule-waveform/task-2-verified-m4.stderr
# 19788 passed / 0 failed; includes actual ASR retry and recording-stage drain/termination

.build/debug/FlowType --self-test --capsule-previews-only --validation-root /Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-03-capsule-waveform/task-2-verified-preview-run > .superpowers/sdd/2026-11-03-capsule-waveform/task-2-verified-preview.stdout 2> .superpowers/sdd/2026-11-03-capsule-waveform/task-2-verified-preview.stderr
# 40 passed / 0 failed; 18 actual native PNGs, pixel and logical dimensions equal

git diff --check
# exit 0
```

A combined log-inspection shell ended with `rg warning:|error:` returning 1 because it found no matches; this was not a build failure. `git diff --check` was then run independently with exit 0.

## Native render artifacts / fixture API

Final canonical preview root:
`/Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-03-capsule-waveform/task-2-verified-preview-run/Tmp/capsule-previews`

- `manifest.json` contains file, logical width/height, actual pixel width/height, title/subtitle for every state.
- 18 PNGs: `recording`, `silent-recording`, `recording-countdown`, `preparing`, `preparing-diagnostic`, `processing`, `polishing`, `slow`, `injecting`, `clipboard`, `no-speech`, `empty-audio`, `polish-fallback`, `resource-busy`, `recoverable-error`, `error-long-diagnostic`, `uncertain-delivery`, `permission-error`.
- Every ordinary image is exactly **216 × 54 pixels / logical points**; each recovery image **380 × 156**. `contact-sheet-1x.png` is an additional generated Pillow review artifact (not part of the native harness manifest), all capsules at the same 1× size.
- `CapsuleView(presentationOverride:)` is a tiny data-only fixture seam into the actual production layout. Override error cards use the exact production action-grid renderer with inert callbacks; default production cards retain actual `performRecoveryAction(action, cardID:)` callbacks. No fake view replica.
- Preview harness reuses `NativeClientPreviewSelfTests.renderHost/capture` NSHostingView offscreen layout; optional `capture(pixelScale: 1)` controls raster scale. It starts only an isolated synthetic capture stage with `markReady()` and repeated whole `publishVisualization(AudioVisualizationFrame(...))` frames for voice/silence; actual AudioVisualizer/motion renders these. It never constructs a live panel/window or requests any microphone/cloud/clipboard/permission effect. Both permitted/blocked ValidationEffects snapshots stay unchanged.
- Self-reviewed the initial and final 1× sheets plus individual final long-diagnostic, uncertain-delivery and resource-busy images. No copy/action clipping observed. Parent also inspected selected native artifacts independently.

Limitations: offscreen native material has no real desktop/window backdrop and glow is visible in transparent bitmap corners; the live FloatingPanel retains its existing capsule layer mask. This evidence validates actual production view geometry/copy/layout, not live backdrop blur or drag/focus across actual apps/screens. Real hardware voice/noise-floor feel, Reduce Motion system setting behavior, and live native material remain manual checks unless separately performed. No real microphone, model/cloud calls, downloads, clipboard writes, permission mutations or active-window changes were performed.

## Owned source changes / final boundaries

- `Sources/flowtype/CapsuleView.swift`
- `Sources/flowtype/FloatingPanel.swift`
- `Sources/flowtype/UI/CapsulePresentation.swift` (new)
- `Sources/flowtype/Core/PipelineOrchestrator.swift`
- `Sources/flowtype/Core/Pipeline/SessionContext.swift`
- `Sources/flowtype/Core/Pipeline/Stages/{ASRStage,InjectionStage,PolishStage}.swift`
- `Sources/flowtype/Core/Recovery/RecoveryPolicy.swift`
- `Sources/flowtype/App/RuntimeEnvironment.swift`
- `Sources/flowtype/Testing/{CapsulePresentationSelfTests,CapsulePreviewSelfTests}.swift` (new)
- `Sources/flowtype/Testing/NativeClientPreviewSelfTests.swift`
- `Sources/flowtype/Testing/M4RecoveryPolicySelfTests.swift` (required expected-copy update, parent authorized)
- `Sources/flowtype/Testing/SelfTest.swift`

No subagents/dependencies. Parent-owned plan/progress/spec/evidence files left unstaged; all report/log/render scratch artifacts remain under the ignored task workspace. No push/merge/full-lane execution. No unresolved focused test failures or deferred implementation issues.
