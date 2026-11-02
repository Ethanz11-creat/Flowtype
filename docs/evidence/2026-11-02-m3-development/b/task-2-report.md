# M3-B Task2 implementation report

Status: DONE (authorized source/tests/evidence scope). Independent review, final app packaging and actual acceptance are controller-owned and remain Pending where not executed.

Commit: `7ce5d21306cb03ccb1832a9b3ac30b7f983ac863` — `feat(asr): stop silent sessions before recognition and preview fallback`.
Parent: `d9111f1` (approved SpeechPreflight production analyzer/background wrapper).
Final commit tree: `26b814f63f30e1d979c6790df2eba52fe6f5a2a3`.
Final `Sources/flowtype` subtree: `6c036ef4846ce19dbe3d014da0ba51a9373bb4be`.
Final ASRStage blob: `0ee3b34226be476baa685514347fe8d783453780`.
Final M3SpeechPreflightSelfTests blob: `332703bc7db2d5f2d771fb0e8fd132429dcf837c`.

## Implementation

- Added source-compatible trailing injectable asynchronous `speechPreflight`, defaulting to production `SpeechPreflight.evaluate(samples:sampleRate:)`.
- After initial audio/ownership validation, ASR takes the current realtime handle/start task and preserves an existing CompletionBudget, or creates one default 20-second budget. The live ingress/start/session defer is installed before any preflight wait/return. CompletionBudget is a value struct; exact equality verifies its original start/deadline identity is unchanged.
- Silence returns `未检测到声音，请重试`; zero samples return `未录到音频，请重试`. Both return before routeFactory, candidate recognition, dictionary/foreground lookup, preview promotion, or health recording. Downstream real stages never execute.
- Known invalid samples/rate suspend with `ASRStageError.invalidAudio`, `录音数据异常，请重新录音`, retryable=false, rawText=nil. Existing controller behavior renders this as a no-action notice; no new error taxonomy/state machine was introduced.
- Unknown detector technical errors degrade to detectorUnavailable. CancellationError and task/context cancellation always terminate rather than fail open. A cancellation recheck after publishing processing state also prevents recognition after a synchronous subscriber invalidates the context.
- Valid short/possiblySpeech/detectorUnavailable input preserves all samples/order and saved routes/fallback candidates. Expired preflight budget cannot construct a route, start a provider, or promote preview. Explicit controller Retry retains its pre-existing new-budget rule and reruns actual preflight.
- Three imported-lease fixtures now use deterministic nonzero samples of their original lengths (3/2/1); no global `.possiblySpeech` injection or production bypass.
- Added `--m3-asr-regression-only` for existing realtime pipeline, imported lifecycle/lease, and model presentation/routing checks; added integration to both existing `--m3-silence-only` and full entry.

## TDD and validation evidence

All logs below are in `.superpowers/sdd/2026-11-02-m3-b-silence-preflight/`.

1. RED, before any production ASR edits:
   `swift run FlowType --self-test --m3-silence-only`
   `task-2-red.log`, exit 1, **756 passed / 51 failed**.
   Tests use real ASR, real SessionController, synthetic recording, real PostProcess/Polish/Injection with fake external effects. Failures demonstrate missing behavior: silent batch request/health/transcript; empty Apple preview promotion; downstream processing, clipboard seam/history/summary; routeFactory called without saved route. Example output:
   - `M3 ASR auto/0: controller notice — got notice("已复制，按 ⌘V 粘贴"), want notice("未录到音频，请重试")`
   - `M3 ASR auto/0: no PostProcess/Polish/Injection — got ["PostProcess", "Polish", "Injection"], want []`
   - `M3 ASR auto/0: silence without saved route cannot construct route — got 1, want 0`
   Initial harness compilation needed explicit `cloudConfiguration: nil`; corrected before the behavioral RED, with production still unchanged.
2. Initial wiring GREEN: `task-2-green-initial.log`, same command, **807/0**, exit 0.
3. Expanded focused checks: first comprehensive **949/0**, then **964/0**. Final pre-barrier result retained in `task-2-green.log`: **987/0**, exit 0.
   During additional controller assertions, **983/4** reflected an incorrect test assumption (`.error`/dismiss for nonretryable rawText=nil). Reading existing `buildErrorActions` confirmed `.notice`/no actions is the established contract. Only expectations changed; diagnostic log retained as `task-2-controller-expectation-correction.log`. This was not a production regression.
4. Relevant existing regression:
   `swift run FlowType --self-test --m3-asr-regression-only`
   `task-2-regression.log`, **292/0**, exit 0. Existing realtime failure/success, endpoint validation, saved chunk completeness, queue overflow, timeout/local fallback, imported captured/current leases and model routing all passed.
5. Stable production, sequential required commands:
   - `swift build` → `task-2-build.log`, exit 0.
   - `swift run FlowType --self-test` → `task-2-full.log`, **3875/0**, exit 0.
   No `swift test` was run.
6. Self-review after full started found fixed `Task.yield` iterations in the obsolete-result test were weaker than an explicit completion observation. The only subsequent source edit added a test wrapper around real ASR and waited for the obsolete ASR call to return before assertions. No production source changed.
   Controller explicitly ruled: let the full run finish; rerun focused amended tests and build; do not repeat the unchanged-production full suite absent failures/unresolved concerns.
   - `swift run FlowType --self-test --m3-silence-only` → `task-2-green-final.log`, **989/0**, exit 0.
   - `swift build` → `task-2-build-final.log`, exit 0.
   Final commit is covered by that final focused/build and the full production suite above; **do not describe 3875/0 as a full run with the final completion-observer test version**.
7. `git diff --check` and staged diff check clean. Commit contains only seven authorized files; index clean after commit.

Full-suite source reconstruction, for exact audit: `Sources/flowtype` subtree `5456d184fd1d34eb3ffd8f293872f249ef126318`, differing from final source only in M3SpeechPreflightSelfTests blob `31b52cbb4ec078d438b46b12b9ee7c9fb663b5a3`. Reconstructed pre-refinement file is retained as `task-2-full-tested-M3SpeechPreflightSelfTests.swift`; its diff to committed test file contains only completion counter, ObservedASR wrapper, wrapping that real ASR, and replacing fixed yields with completion wait plus two assertions. Production ASR blob is identical for full and final runs.

Warnings: focused recompilations show only pre-existing `AppLogger.swift:27` (`nonisolated(unsafe)` unnecessary for Sendable DispatchQueue). Related regression, required final production build/full, and final build logs show no warnings/errors. No new warning introduced. Full success is not claimed as globally pristine because focused compile retained that known warning.

## Coverage and self-review

- Default preflight is used for digital silence/empty, actual malformed PCM, short/head/tail/delayed signals, controller recording pipeline, live silence cleanup and retry. Decision injection is confined to detector reason/error/cancellation/budget timing boundaries, not a global routing bypass.
- localOnly/cloudOnly/auto silence/empty fixtures carry nonempty Apple preview and usable fake provider returning hallucination. Assert no provider, routeFactory, health, raw transcript, downstream stage, keyboard/clipboard seam, history or summary.
- Production default real analyzer sees 5-second zero input and real invalid Float values; pure/background Task1 tests remain included unchanged.
- Live tests allow prior start/queued audio, assert finish=0/new factory=0, exactly one session cancellation on early exit, cancelled start task, specifically cancelled ingress with queued audio released, consumed context handle and no double cancel via subsequent context cleanup. An injected early detector exit additionally proves handle ownership/budget existed before detector invocation; CancellationError also unwinds installed cleanup.
- Real successful controller pipeline establishes previous summary. Subsequent silence and malformed audio preserve it without any added downstream effects. Notice cancellation returns idle through original mechanism; no new long dismissal-timer test or state-machine change.
- Cancelled suspended preflight returning either silent or speech is released only after a newer actual pipeline delivery; final tests wait for obsolete actual ASR completion before checking unchanged new UI/summary/history/provider/health/delivery. Context raw transcript stays empty.
- Explicit real ASR Retry follows failed live finish, rereads full stored payload through preflight, never reuses terminated live handle, creates one fresh saved realtime handle, sends exact samples, produces one history write and keeps established 20-second retry-budget reset.
- Existing/new/expired budgets checked before preflight, after delay and at provider timeout; existing start/deadline identity preserved and expired path has no route/provider or preview.
- Cross-M3 self-review checked default automatic delivery remains untouched, summary ownership stays controller-guarded, no delivery/event latch reset, no uncertain replay, and clipboard transaction ownership is unchanged. Independent Task2 and whole-M3 review belong to controller.
- Test file grew to 690 lines in its task-specified file; helper types remain private to the test enum, with no test-only API added to production. No unrelated restructure.

## Files committed

- `Sources/flowtype/Core/Pipeline/Stages/ASRStage.swift`
- `Sources/flowtype/Testing/M3SpeechPreflightSelfTests.swift`
- `Sources/flowtype/Testing/SelfTest.swift`
- `Sources/flowtype/Testing/ImportedLifecycleSelfTests.swift`
- `docs/evidence/2026-11-02-m3-validation.md` (Task2 appendix only; controller's pre-existing dirty status rows preserved unstaged)
- `docs/evidence/2026-11-01-live-validation.md`
- `docs/2026-10-14-flowtype-product-validation.md`

`task-2-fixture-audit.log` retains the requested samples/zeros/audio search. Other zero fixtures are direct analyzer/provider/transport boundary tests rather than ASR routing-success audio and were retained.

## Remaining boundaries / concerns

No known source correctness concern after self-review and the listed tests. Actual acceptance remains Pending: microphone 5s silence, quiet/single/short/head/tail/delayed speech, keyboard/fan/wind, five apps, 20 rounds, physical cancellation/device recovery and V1–V5. Candidate RMS/peak thresholds are not calibrated and synthetic signals are not human-speech accuracy evidence. Existing realtime capture may already have uploaded/billed before stop; this implementation stops finalize/preview/delivery, not prior upload. Old process/M2 bundle cannot accept M3.

No GUI, packaging, cloud request/billing, model/dependency download, Python/conversion, real user configuration, permission, model or cache mutation was performed. Tests used synthetic inputs, fake providers and isolated config as required. No subagents were spawned. Branch/worktree retained; no push/merge.

Untouched controller-owned dirty files remain: audit, both plans, spec, M3 evidence status rows; untracked `docs/evidence/2026-11-02-m3-development/` archive not staged. Logs/report under ignored `.superpowers` are for controller review and were not committed.
