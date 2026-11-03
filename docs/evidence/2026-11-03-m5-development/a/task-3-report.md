# M5-A Task 3 implementation report

Status: DONE — M5-A Task 3 only; ready for controller review.

Base: `ffd4ba473cf871617caaebdd65061b06642ee8e9`.

Commit: `d6aaace2bcbc74d21499543e83684598391bda41` — `feat: add build identity and role-scoped diagnostics`.

## Implementation

- `App/BuildInfo.swift` separates disk `BuildMetadata` from runtime `BuildIdentity`. Validation rejects malformed/missing fields, unsupported schema, invalid version/build/SHA, non-UTC or invalid calendar timestamps, dirty source and plist version/build mismatch. An `.app` with absent/bad metadata is invalid; a non-app development run has explicit unknown identity and never queries Git. Runtime optional fields encode explicit JSON nulls.
- `Utilities/DiagnosticLogWriter.swift` owns explicit fileURL/role/runID/identity, queue-confined formatting and I/O, synchronous startup header plus synchronization, UTC prefixes on every physical line, queue-aware synchronous flush, and current plus three rotated files at the existing 10MiB threshold. Each rotated file starts with the current identity header. Failures after startup stay confined to the selected path.
- `Utilities/AppLogger.swift` becomes a lock-protected configure-once facade. No production log path is initialized before configure; a header failure throws before publishing the writer. Conflicting reconfiguration throws and preserves the existing identity/path. Compatibility log, logFileURL and openLogInFinder entrypoints remain.
- Main loads identity and configures the logger immediately after successful runtime bootstrap and before shared services/AppKit launch. Logger configuration failure exits without starting shared services. Main's exits, ordinary termination and every self-test exit flush. Every self-test summary is logged and flushed before the unchanged stdout summary.
- The About menu displays the same configured identity, including development/invalid unknown states, without Git or metadata reload. Its real GUI appearance remains Pending.
- `scripts/generate-build-info.swift` is independent Swift/Foundation/Process code. It uses argument-array Git invocations, ignores inherited Git overrides/global config, requires a clean nonshallow checkout and valid committed Sources tree, derives HEAD/count/HEAD:Sources/UTC itself, and verifies the source snapshot before and after writing matching JSON/plist. Version defaults to1.0.0 and accepts only three ASCII decimal components. Output must be an empty real directory; writes use no-overwrite semantics and rollback removes only newly owned files. Existing bundle and permission usage declarations are preserved. CLI usage errors return64; generation failures return1. Its self-test owns and removes only independent temporary Git repositories and output directories.
- The new focused suite and RuntimeOptions filter are integrated into the runner. README documents focused checks, isolated logs, generator use, synthetic-input requirements and pending packaging integration. It explicitly describes effect budgets as code-boundary evidence rather than an OS sandbox.

## TDD evidence

All commands ran from `/Users/yiheng/pycode/flowtype-local`; logs are local ignored evidence beside this report. Shell wrappers preserve the command status.

1. `task-3-red-build.log`: build exit1 due to the test fixture's stored `[String:Any]` static dictionary being non-Sendable. Fixed the fixture to `[String:String]`; `task-3-red-build-fixed.log` builds successfully.
2. `task-3-red-focused.log`: real focused behavioral RED against minimal safe APIs:47 passed/536 failed, exit1. Failures include malformed metadata accepted, broken app treated as development, missing synchronous identity header, missing rotation/UTC/role/run markers, and configure conflict accepted. No ordinary app/shared baseline was launched for RED.
3. `task-3-generator-red.log`: initial fixture compile error because throwing expressions occurred on the right side of `&&`. Corrected the fixture expression. `task-3-generator-red-behavior.log`: real Git fixture RED,6 passed/18 failed, exit1. Invalid versions, dirty/untracked/shallow trees, occupied output, incorrect commit/tree/count/UTC and missing usage declarations were caught.
4. A script replacement accidentally removed the fixture entrypoint, producing an empty exit0 in `task-3-generator-green-initial.log`. This was rejected as verification evidence. Restored the actual self-test entrypoint and fixtures; `task-3-generator-green.log` records29 passed/0 failed, exit0.
5. `task-3-green-build.log`: intermediate compile failure from an inserted newline between NSMenuItem and its initializer. Corrected that insertion. `task-3-green-build-fixed.log` builds successfully; `task-3-green-focused.log` records114 passed/0 failed, exit0.
6. A saved, independent mutated script disables only the final snapshot verification: `task-3-generator-head-red.log` records27 passed/2 failed, exit1, specifically detecting HEAD change and intervening dirty tree. The real source retained its guard.
7. Added explicit-null serialization regression assertions. `task-3-null-red-build.log` builds; `task-3-null-red-focused.log` records114 passed/2 failed, exit1, because synthesized optional encoding omitted metadata/failure. Added explicit encoding to emit nulls.

The focused tests cover malformed JSON, all missing metadata fields, strict field types/formats, plist mismatch, dirty source, invalid calendar/UTC, development/broken/valid app origins, explicit-null serialization, About identity text, synchronous startup header, every retained physical line's ownership/timestamp, real low-threshold rotation/four-file limit,120 concurrent messages delivered exactly once, immediate flush/final sentinels, in-queue flush without deadlock, separate run files, configure conflict and startup header I/O failure.

Generator fixtures check actual clean two-commit Git identity, matching plist/JSON, default and explicit version, injection/newline version rejection, usage64, occupied-output preservation, symlink output rejection, dirty/untracked/shallow rejection, HEAD/worktree stability, and final fixture cleanliness. Git commits/configuration changes are confined to the owned synthetic fixture repositories; no global Git config is modified.

## Final verification

Final focused command:

```sh
.build/debug/FlowType --self-test --m5-buildinfo-only --validation-root /Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-03-m5-a-build-identity-and-isolation/task-3-final-focused-run
```

Exit0,116 passed/0 failed, in `task-3-final-focused.log`. Its preceding successful build is `task-3-final-focused-build.log` (34.85s).

```sh
swift scripts/generate-build-info.swift --self-test
```

Exit0,29 passed/0 failed, in `task-3-generator-final.log`.

`task-3-focused-log-inspection.log` independently checks the actual retained file against its runtime ownership marker: two lines, first identity header, explicit-null development metadata/failure, every line's selfTest role/runID/[SelfTest], last line the116/0 summary. All assertions passed.

The required subsequent `swift build` exited0 (`task-3-full-lane-build.log`,17.17s). The full runner was then launched exactly once with a fresh explicit `task-3-full-run` root, retaining its owned PID in `task-3-full.pid` and exit status in `task-3-full.exit`.

Full command (executed exactly once):

```sh
.build/debug/FlowType --self-test --validation-root /Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-03-m5-a-build-identity-and-isolation/task-3-full-run
```

Actual complete stdout in `task-3-full.log`:

```text
=== FlowType --self-test ===
=== self-test: 24164 passed, 0 failed ===
```

The owned process34256 exited normally with status0, independently retained in `task-3-full.exit`. The full run includes all legacy semantic assertions, hidden AppKit panel/screen geometry checks and the final fourteen external-effect budget assertions; none was removed or skipped.

`task-3-full-log-inspection.log` records independent Ruby/JSON read-only inspection of only the explicit full root:552 lines, first BuildIdentity header, every physical line has UTC/selfTest/runID/[SelfTest], explicit-null development metadata/failure, and last line is the exact24164/0 summary. Every inspection assertion passed. The marker supplied the expected runID, rather than trusting the log prefix itself. No source changed after final verification, and the unchanged full suite was not repeated.

## Scoped files and commit

The scoped source/documentation files are:

```text
README.md
Sources/flowtype/App/BuildInfo.swift
Sources/flowtype/App/FlowTypeApp.swift
Sources/flowtype/App/RuntimeEnvironment.swift
Sources/flowtype/App/StatusBarController.swift
Sources/flowtype/Testing/M5BuildInfoSelfTests.swift
Sources/flowtype/Testing/SelfTest.swift
Sources/flowtype/Utilities/AppLogger.swift
Sources/flowtype/Utilities/DiagnosticLogWriter.swift
scripts/generate-build-info.swift
```

`task-3-scoped-files.log` retains the exact staged list. Scoped stage:10 files,652 additions/105 deletions. `git diff --cached --check` passed with empty output in `task-3-staged-check.log`; `task-3-commit.log` records the successful commit above. Final `git status --short` and `git diff HEAD --check` produced no output. Reports, logs and retained synthetic run roots are ignored local evidence and were not committed. No further task was started.

## Self-review and limits

Source audit verified all main/self-test exits flush and the startup header precedes shared initialization; evidence is retained in `task-3-exit-audit.log`. App logging retains RuntimePaths' original `~/Library/Logs/flowtype/diagnostic.log`, with10MiB/three archives. Validation filenames remain diagnostic-selftest.log and diagnostic-smoke.log under the unique run Logs directory. No log fallback chooses a production path after initialization failure.

Earlier rebuild logs include existing AudioRecorder/AudioDevice/AppleSpeechProvider/ProviderEditSheet warnings. The old AppLogger nonisolated(unsafe) warning disappears with the rewritten logger; no unrelated warnings were changed. The final sequential build reported no warning.

No model, session, transport, injection-ownership or persistence semantics were rewritten. No build-app/bundle-layout/signing integration was performed; B3 owns it. No ordinary app/visible GUI, real model load/download, recording, permission request, clipboard mutation, input event or provider request was executed. No real user config/dictionary/DB/Keychain/model cache was read as a baseline. No Python, install, dependency update, swift test, acoustic benchmark, push, merge, nested agent or reviewer was used. No plans/ledger were modified.

Existing free-text logging is not comprehensively redacted; all executed automatic lanes use synthetic inputs. Budget counters establish guarded code-boundary evidence, not OS-level monitoring or sandbox enforcement. Real About/menu appearance and ordinary app/hardware lanes remain Pending. This task cannot establish M5 or release completion.
