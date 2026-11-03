# M1–M5 independent review fixes — implementation report

Implemented IR-01 then IR-02, each with behavioral RED→GREEN, using `receiving-code-review` and `test-driven-development` including `writing-good-tests.md`. Starting HEAD5471880, branch/worktree retained. No nested agents.

Commits:

- `9c20e31bd5a9b13418a4b9131299e07e8ba7972c` — `fix: require explicit shader input in packaging CLI`.
- `bb8b5bf671b94ca8f4c5ac5256583b4550ff88e2` — `fix: reject frozen capture when normal Stop cancels recording`.

Final scope:6 source/test files,344 insertions/64 deletions. Current Sources tree `5d4772afcd862c9048ccf5d0ad65971cb6fae21f`. Package.swift and Package.resolved unchanged from starting HEAD; resolved blob remains `702ce34b917f9fdf9927b1b428f431125c28970c`. Worktree clean after commits. Old historical evidence and review records were not changed.

## IR-01 — explicit shader input

Confirmed root cause: actual `ArtifactPackagingCLI.main` build branch searched the user's uv/pip cache roots when MLX_METALLIB_PATH was missing; an empty value was converted to a URL rather than rejected before the packager's source preflight. Existing nil-shader packager fixtures never exercised this CLI branch.

Change: build requires a present, nonempty MLX_METALLIB_PATH, throws `shaderInvalid` immediately otherwise, and passes only that explicit URL to the existing packager. Removed cache fallback entirely. No Python/install/cache search or replacement source-selection API was added.

Regression executes the real production `@main` compiled from BoundedProcess.swift, ArtifactPackaging.swift and ArtifactPackagingCLI.swift, with the test-only `ArtifactPackagingCLIInputFixture.swift` included. **No production source text is rewritten.** The fixture defines a same-module `FileManager` name whose `.default` returns a Foundation.FileManager subclass. It overrides only homeDirectoryForCurrentUser (required synthetic path) and directory enumeration (guard/trace cache paths, then calls Foundation super); all other filesystem behavior is inherited. CLI and packager `.default` references use this object only in this standalone test compilation. Production builds never include the fixture.

A valid-sized synthetic MTLB file exists in a synthetic uv cache, so the old fallback is observably reachable. The synthetic repository has deliberately invalid `.git` metadata: if input selection wrongly proceeds, real packaging's source preflight returns sourceInvalid before build/sign. Explicit input's sourceInvalid is the expected downstream sentinel, not a successful package claim. Tests also retain extra-argument usage64 behavior and assert no candidate success output.

Long-term standalone entry, independent like existing packaging selftests (not wired into product full/CI):

```sh
ruby scripts/verification/ArtifactPackagingCLIInputTests.rb /absolute/path/to/flowtype-local/build/owned-scratch
```

Exact invocation used for both RED and GREEN:

```sh
ruby scripts/verification/ArtifactPackagingCLIInputTests.rb /Users/yiheng/pycode/flowtype-local/build/m1-m5-review-fixes
```

The runner's exact swiftc argv is the three production files plus the test fixture, `-o <owned-run>/packaging-cli`; generated paths and child stdout/stderr/exit/cache traces remain in each run below.

| Gate | Exit / result | Raw evidence |
| --- | --- | --- |
| RED | exit1,9 passed/3 failed | ir01-red.{stdout,stderr,exit}; cli-input-2cc3f544-b2e8-4a5c-a5b6-c47f1a946f4a/ |
| GREEN | exit0,12 passed/0 failed | ir01-green.{stdout,stderr,exit}; cli-input-14f9adcd-6528-48f4-a49c-b5d21eecae28/ |

RED failures were exactly: missing input returned sourceInvalid instead of shaderInvalid; missing input enumerated the synthetic uv cache; empty input returned sourceInvalid instead of shaderInvalid. GREEN missing/empty both produce exit1 + `FlowType packaging: shaderInvalid`, all cache traces empty, explicit input reaches the sourceInvalid sentinel, extra argument produces usage64. Compile streams and GREEN parent stderr are empty. No actual user cache was read.

## IR-02 — frozen capture plus normal Stop

Confirmed root cause: controller normal Stop cancels the recording task while retaining the SessionContext. RecordingStage's cancellation catch cleaned up and returned partial audio whenever the context remained active, ignoring the frozen latch. Natural completion checked that latch. Thus an already-detected device interruption could be promoted into ASR despite the current failure contract. This branch predates M1; the fix is not described as a newly introduced M1–M5 regression.

Change: both natural completion and CancellationError catch now call the same production `finishRecording` routine. It stops/clears owned capture and collects samples/preview, checks full-context cancellation first, then checks the same frozen latch. Full cancellation cancels realtime and returns complete. Freeze cancels realtime and returns nonretryable Recording interruption with no raw text. After the full-cancellation check ingress is sealed; only healthy completion returns audio with a success duration; ownership is checked again on MainActor before returning audio. Existing cancellation handler and generic error path remain in place. No test-only cleanup method was added to production.

Narrow injection exposes the existing external boundaries: recorder/preview protocols and factories, route capture, ContextProvider, realtime factory and microphone-device lookup. Defaults remain AudioRecorder, AppleSpeechProvider, ASRRouter, AXContextProvider, live realtime and ConfigurationStore. Tests replace these boundaries, while **real RecordingStage.execute, SessionContext.prepareRealtime/cancel, deadlines, ingress and failure classification execute unchanged**.

`RecordingStageTerminationSelfTests` is called from existing M4StageFailureSelfTests.run, therefore runs through existing `--m4-recovery-only` and eventual full suite; no new product CLI flag. All doubles remain in the Testing file.

Deterministic gate: synthetic capture supplies160 nonzero samples and calls the installed PCM/buffer callbacks. Preview initialization signals an entered AsyncStream, then waits on a release stream. Awaiting entered guarantees capture has started and real context realtime preparation has happened. The test invokes capture.freeze in the actual recorder ordering (onRecordingFrozen first, spectrum finish second); normal Stop then cancels only the recording Task and releases preview. The real Task.checkCancellation after preview enters the actual cancellation catch. No sleeps, hardware, manual frozen helper evaluation or copied terminal-decision logic are used.

Four real stage cases:

| Case | Required observed outcome |
| --- | --- |
| healthy Stop | audio160 unchanged nonzero samples, preview retained,10ms duration, realtime uncancelled, context active |
| full cancellation with freeze | complete wins over freeze, realtime cancelled, no success duration, context cancelled |
| freeze + natural stream end | Recording/interrupted suspension, no raw text/retry/audio result, realtime cancelled, context active |
| freeze + normal Stop | same interruption suspension/cancel, no success duration, context still active |

Exact incremental compile command, explicitly allowed by controller (not a clean/full build):

```sh
swift build --skip-update --disable-automatic-resolution
```

Exact RED focused command:

```sh
.build/debug/FlowType --self-test --m4-recovery-only --validation-root /Users/yiheng/pycode/flowtype-local/build/m1-m5-review-fixes/ir02-red-validation
```

Exact GREEN focused command is identical except root ends `ir02-green-validation`.

| Step | Exit / observed result | Raw files |
| --- | --- | --- |
| Initial fixture compile | exit1, fixture non-Sendable callback lock-access errors | ir02-red-build.{stdout,stderr,exit} |
| Corrected fixture compile | exit0, incremental35.13s | ir02-red-build-fixed.{stdout,stderr,exit} |
| Behavioral RED | exit1,19772 passed/3 failed | ir02-red.{stdout,stderr,exit}; ir02-red-validation/Logs/diagnostic-selftest.log |
| GREEN incremental compile | exit0,32.98s | ir02-green-build.{stdout,stderr,exit} |
| Behavioral GREEN | exit0,19777 passed/0 failed; stderr empty | ir02-green.{stdout,stderr,exit}; ir02-green-validation/Logs/diagnostic-selftest.log |

The initial compile failure is **not** counted as behavioral RED. Corrected fixture uses withLockUnchecked for already lock-protected non-Sendable callback properties, matching their existing production signatures. Before changing terminal behavior, actual RED failed exactly frozenStop's audio blocking, realtime cancellation and absence of success-duration assertions. Healthy Stop, full cancellation and frozen natural completion passed, as did all existing focused M4 assertions. GREEN then exercises the typed suspension assertions as well (two more checks than the RED wrong-branch guard). The test file is byte-identical to its RED snapshot (`RecordingStageTerminationSelfTests-red.swift`, cmp exit0). `RecordingStage-red.swift` preserves pre-fix terminal behavior with the injection scaffold.

Diagnostic IDs980–983 independently show real branch execution: RED983 logs Recording cancelled then160 samples; GREEN983 logs Recording cancelled then Recording interrupted, while982 uses natural spectrum completion. GREEN980 remains healthy audio and981 remains full cancellation. No downstream ASR or delivery is invoked by this isolated stage test; suspension is the real pipeline boundary preventing their advancement, not a claim of a hardware delivery experiment.

Build warnings: all incremental invocations report the CLI deprecation of `--skip-update`. The first compile also surfaced existing untouched AppleSpeechProvider unused withLock result and AudioRecorder deviceIDSize/inputConsumed warnings. They are preserved in raw output and were not opportunistically fixed. Corrected RED/GREEN compiles have no new source warnings.

## Self-check, limits and handoff

Scoped staged git diff --check exit0 before each commit. Package.swift/Package.resolved diff against5471880 exit0. Real test helpers were not replaced by implementation mirrors; wrong frozen decision/missing realtime cancellation/empty healthy audio would each break concrete assertions. Final source self-review confirmed both unwind paths share terminal logic, full cancellation precedes freeze, and only healthy audio records duration.

No swift test, baseline/full-suite repetition, benchmark, full/clean build, final release, ordinary app/GUI, real recording/permission/input/clipboard, real configuration/DB/Keychain/model-cache, external ASR/LLM/CI, Python/download/install/dependency changes, push/merge or publication. Scratch/raw evidence stays under this owned build/m1-m5-review-fixes directory. No old SDD scratch was read. The new source invalidates treating the old4cdfaf4 candidate as this fix's technical candidate; controller will arrange independent review followed by one final release integration gate.41 manual leaves and remoteCI remain Pending. Stop for controller review.
