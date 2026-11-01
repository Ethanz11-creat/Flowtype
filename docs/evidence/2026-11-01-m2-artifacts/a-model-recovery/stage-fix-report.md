# M2-A staged final fix report

Base: `26e10c7`. Commit: `eb840f8` — `fix: preserve recovery diagnostics and removed folder intent`. Status: **DONE**. Scope: all three Important findings in `stage-review.md`, one sequential fix dispatch, no subagents.

## Changes

1. Terminal recovery presentation now renders the typed safe endpoint summary (HTTP status, host, path). The card explicitly labels the failed operation's captured source separately from the mutable source selection used for the next retry and its download command. A mirror HTTP 308 remains associated with the mirror after selecting Official, until another operation starts. No raw response, underlying error string, URL query/userinfo/fragment, or credential is displayed or logged.
2. Both settings folder controls use `ModelRecoveryActions.removeFolderOverride()`. It clears custom and legacy configuration paths together and resets the coordinator's recovery target and old terminal state without unloading the active lease. Both controls support legacy-only paths and disable removal while an operation drains. A subsequent load/retry uses current configured preset resolution instead of re-importing the removed folder. Existing failed-new-import retry behavior remains intact and its existing cancellation/success/persistence regressions continue to run.
3. `QwenASRProvider.loadModel` uses a shared production error boundary. Opaque AudioCommon `DownloadError` wrappers are terminal `loadFailed`, regardless of whether their arbitrary text resembles a network error. Explicit transient URL errors and preserved typed network errors remain retryable; deterministic URL errors do not. URL cancellation remains cancellation. Structured `ModelProvisionError` summaries survive intact; structured underlying NSError causes are inspected with a depth bound. No string parsing or raw error logging was added. The dependency's own snapshot loop remains unchanged.

## TDD evidence

Before behavior changes, the existing provider catch was mechanically extracted into `withProvisionErrors`, and the existing picker removal body was moved unchanged into the shared action. This exposed real production boundaries for regressions without replacing classification, configuration writes, coordinator retries, or presentation with mocks. Model/network I/O alone uses fixtures. Test inputs use isolated UserDefaults suites and fixture paths, never actual models or credentials.

### Initial behavioral RED

Commands, run sequentially:

```
swift build > .superpowers/sdd/2026-11-01-m2-a-model-recovery/stage-fix-red-build.log 2>&1
swift run FlowType --self-test > .superpowers/sdd/2026-11-01-m2-a-model-recovery/stage-fix-red-self-test.log 2>&1
```

Build exit 0, 38.58s. Self-test exit 1: `1582 passed, 33 failed`.

Representative observed failures:

- `terminal failure exposes HTTP 308`
- `terminal failure exposes safe endpoint and path`
- `shared removal clears legacy override` — retained `/fixture/legacy-conflict`.
- `load after removal replaces old folder from configured preset` — old folder lease remained.
- `removed folder is loaded only by the initial import` — 2 instead of 1.
- `legacy-only folder removal clears legacy selection` — old path remained.
- `provider boundary: opaque deterministic download has bounded outer attempts` — 3 instead of 1.
- Opaque transient-looking strings, deterministic URLs, and URL cancellation incorrectly received 3 outer attempts and 10/20-second backoff.
- Structured metadata/network and wrapped timeout lost their typed classification.
- `automatic recovery keeps primary plus one fallback budget at provider boundary` — 4 instead of 2 for opaque failure.

### Initial GREEN

Commands, run sequentially:

```
swift build > .superpowers/sdd/2026-11-01-m2-a-model-recovery/stage-fix-green-build.log 2>&1
swift run FlowType --self-test > .superpowers/sdd/2026-11-01-m2-a-model-recovery/stage-fix-green-self-test.log 2>&1
```

Build exit 0, 29.30s. Self-test exit 0: `1617 passed, 0 failed`.

### Self-review improvement and final validation

Self-review found the new removal fixture reused the same candidate lease UUID. The real import action correctly rejects a repeated lease UUID as unsuccessful, which masked the old action's persistence side effect even though its target/load assertions were red. The fixture now creates a fresh lease for every successful load, matching production, and asserts configuration remains removed after restart. A targeted mutation restores the original removal body for a second behavioral RED before restoring the fix. The second RED used these sequential commands:

```
swift build > .superpowers/sdd/2026-11-01-m2-a-model-recovery/stage-fix-removal-red-build.log 2>&1
swift run FlowType --self-test > .superpowers/sdd/2026-11-01-m2-a-model-recovery/stage-fix-removal-red-self-test.log 2>&1
```

Build exit 0, 24.08s. Self-test exit 1: `1612 passed, 7 failed`. In addition to wrong target/load behavior, the fresh-lease fixture now directly reproduces:

- `retry after removal cannot resurrect removed folder` — got `/fixture/stage-folder-A`, wanted nil.
- `legacy-only removal cannot migrate removed folder back to custom selection` — got `/fixture/stage-folder-A`, wanted nil.
- `removed custom folder stays removed after restart` — got `/fixture/stage-folder-A`, wanted nil.

The real fix was then restored (no mutation remains). Final commands, run sequentially:

```
swift build > .superpowers/sdd/2026-11-01-m2-a-model-recovery/stage-fix-final-build.log 2>&1
swift run FlowType --self-test > .superpowers/sdd/2026-11-01-m2-a-model-recovery/stage-fix-final-self-test.log 2>&1
```

Final build exit 0, 23.48s. Final self-test exit 0: `1619 passed, 0 failed`. `git diff --check` passed.

## Changed files

- `Sources/flowtype/Services/Speech/ModelProvisioning/ModelRecoveryActions.swift`
- `Sources/flowtype/Services/Speech/ModelProvisioning/ModelRecoveryPresentation.swift`
- `Sources/flowtype/Services/Speech/QwenASRProvider.swift`
- `Sources/flowtype/Services/Speech/QwenModelState.swift`
- `Sources/flowtype/Settings/LocalModelPicker.swift`
- `Sources/flowtype/Settings/QwenModelStatusCard.swift`
- `Sources/flowtype/Testing/ModelProvisionSelfTests.swift`

The report and validation logs live in the existing ignored SDD workspace, consistent with previous task reports.

## Self-review and remaining boundaries

- Candidate lease ownership, captured recording identity, global operation/HF endpoint serialization, cancellation drain, onboarding gating, and successful-import persistence contracts remain unchanged. Existing regressions run in the full self-test suite.
- Explicit opaque failure now invokes the provider once; automatic 1.7B opaque failure invokes primary once plus fallback once. Known transient causes retain primary at most 3 plus automatic fallback at most 1, with 10/20-second outer backoff. Tests exercise the same provider boundary used around `fromPretrained` and real coordinator loops. They do not claim to execute the dependency's internal HTTP/snapshot loop; it can still perform up to 3 snapshots per invocation.
- Inherited AppLogger `nonisolated(unsafe)` compiler warning remains. No new warnings observed.
- Actual GUI, real weights/GPU, real recording replacement, and V1–V5 remain **Pending**. The release bundle at 26e10c7 was not rebuilt or launched by this worker. HEAD metadata probe evidence remains distinct from weight-download acceptance.
- No push, merge, real-key/config/model fixture access, model deletion, or application cache deletion.
