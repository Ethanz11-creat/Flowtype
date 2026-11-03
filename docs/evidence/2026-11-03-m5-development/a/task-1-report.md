# M5-A Task 1 implementation report

Status: DONE. Task 1 only; A2 has not started.

Base: `9b149fdad7c6a3c6b0a6a342d6d2fa7b388f797f`.

Commit: `aea7dc9396b2020d2372c85af0d4da20f10394cf` — `feat: bootstrap isolated validation runtime`.

## Implemented

- `RuntimeEnvironment` exposes the required bootstrap/current/defaults/finishValidation API. Its independent `RuntimeBootstrap` owner protects successful one-time initialization, immutable Sendable context reads, and a single defaults instance with an NSLock. Access before bootstrap explicitly fails; no lazy app fallback exists. Instances accept injected paths and a fixed UUID without modifying process current. UUID injection is never a CLI option.
- `RuntimeOptions` parses mutually exclusive app/selfTest/smoke/artifact modes, rejects duplicate/conflicting/unknown long options with usage64, accepts one root argument, and permits filters only with self-test. All eight legacy filters and the new M5 filter remain supported. LaunchServices/AppKit single-dash arguments retain the app path.
- `RuntimePaths` preserves legacy app formulas: config and persistent support under `FlowType`, models under `Flowtype/models`, cache base unchanged, logs under `Library/Logs/flowtype`, and the injected temp base unchanged. The app formula helper performs no filesystem operations.
- Validation bootstrapping canonicalizes only the trusted temp base using POSIX realpath. Explicit roots preserve their components and reject relative paths, dot components, null bytes, root/home/home ancestors/Library descendants, symlinks in any component, files, and nonempty directories. Descriptor-relative O_NOFOLLOW operations create real directories, verify root ownership, and acquire an O_EXCL marker. Two competing owners of one root yield exactly one success. Failures do not remove original data or markers.
- Non-app roots contain config, ApplicationSupport, Caches, Logs, and Tmp directories. Model paths are confined below ApplicationSupport. Validation suites are named `com.flowtype.validation.<role>.<runID>`; failure to create one fails closed, and cleanup removes only that instance's suite. Run directories remain for diagnosis.
- `FlowTypeMain` establishes the runtime before app/shared initialization, prints only closed error codes to stderr, and maps usage errors to 64 and bootstrap errors to 1. Smoke/artifact placeholders explicitly report unsupported and exit1; they cannot fall through into the app.
- The new focused self-test branch invokes only `M5RuntimeSelfTests`, cleans its suite, prints the existing style of counts, and exits. Logger directory/filename selection now uses the current role and isolated runtime path. Identity headers, logger configure/flush, persistent global rewiring, and legacy runner isolation are left for their assigned later tasks.

## Files in the scoped commit

1. `Sources/flowtype/App/RuntimeEnvironment.swift` — new context/parser/state owner.
2. `Sources/flowtype/App/RuntimePaths.swift` — new pure app formulas and validation root preparation.
3. `Sources/flowtype/App/FlowTypeApp.swift` — earliest bootstrap and explicit dispatch.
4. `Sources/flowtype/Testing/M5RuntimeSelfTests.swift` — synthetic focused tests.
5. `Sources/flowtype/Testing/SelfTest.swift` — focused M5 branch only.
6. `Sources/flowtype/Utilities/AppLogger.swift` — role/path routing only.

No ledger, plan, dependency, or Package.resolved changes were made. Report/log files are intentionally in the existing ignored `.superpowers` directory and are not part of the source commit.

## TDD and command evidence

Commands ran from `/Users/yiheng/pycode/flowtype-local`. Complete stdout/stderr is retained in the named sibling log files. Shell wrappers saved `$?`, displayed a log tail or the entire small focused output, then exited with that original status.

### Initial compile RED

Tests and the focused runner branch were written before production APIs.

```sh
swift build > .superpowers/sdd/2026-11-03-m5-a-build-identity-and-isolation/task-1-red-compile.log 2>&1
```

Exit1, as expected. Output includes `cannot find 'RuntimeBootstrap' in scope`, `cannot find 'RuntimePaths' in scope`, `cannot find 'RuntimeOptions' in scope`, and `cannot find 'RuntimeEnvironment' in scope`. Complete compiler output: [task-1-red-compile.log](task-1-red-compile.log).

### Behavioral RED after minimal fail-closed API

The minimal API used an isolated default root, refused all explicit roots, and had an incomplete parser. It did not construct production shared services. The setup build succeeded:

```sh
swift build > .superpowers/sdd/2026-11-03-m5-a-build-identity-and-isolation/task-1-red-behavior-build.log 2>&1
.build/debug/FlowType --self-test --m5-runtime-only > .superpowers/sdd/2026-11-03-m5-a-build-identity-and-isolation/task-1-red-behavior.log 2>&1
```

Build exit0; focused exit1. Exact focused output:

```text
  ✗ FAIL: M5 same-root race has exactly one owner — got 0, want 1
  ✗ FAIL: M5 creates isolated config
  ✗ FAIL: M5 creates isolated ApplicationSupport
  ✗ FAIL: M5 creates isolated Caches
  ✗ FAIL: M5 creates isolated Logs
  ✗ FAIL: M5 creates isolated Tmp
  ✗ FAIL: M5 runtime fixture operation failed
  ✗ FAIL: M5 invalid arguments fail before launch
  ✗ FAIL: M5 invalid arguments never reach app launch
  ✗ FAIL: M5 invalid arguments fail before launch
  ✗ FAIL: M5 invalid arguments never reach app launch
  ✗ FAIL: M5 invalid arguments fail before launch
  ✗ FAIL: M5 invalid arguments never reach app launch
  ✗ FAIL: M5 invalid arguments usage64 — got 1, want 64
  ✗ FAIL: M5 invalid arguments fail before launch
  ✗ FAIL: M5 invalid arguments never reach app launch
  ✗ FAIL: M5 invalid arguments fail before launch
  ✗ FAIL: M5 invalid arguments never reach app launch
  ✗ FAIL: M5 argument fixture operation failed
=== FlowType --self-test ===
=== M5 runtime self-test: 49 passed, 19 failed ===
```

These were real assertion failures in root creation/ownership and argument/launch gating, beyond missing-symbol compiler evidence. The launch spy was the actual launch closure of the same bootstrap-and-run method used by main; no AppDelegate or app launch occurred.

### Intermediate failures and fixes

The first completed implementation build succeeded, but its focused process exited1 before tests:

```text
FlowType: runtime bootstrap invalidRoot
```

Saved as [task-1-green-focused-initial.log](task-1-green-focused-initial.log). A metadata-only diagnosis (getconf, ls metadata of `/`, `/private`, `/private/var`, `/var`, and a standalone Foundation URL check) showed that Foundation's `resolvingSymlinksInPath()` retained `/var` on this host despite `/var -> private/var`. Evidence: [task-1-temp-alias-diagnosis.log](task-1-temp-alias-diagnosis.log). Trusted temp canonicalization was changed to POSIX realpath.

The next focused run exited1 with `85 passed, 6 failed`; exact output is retained in [task-1-green-focused-foundation.log](task-1-green-focused-foundation.log). Five failures were the synthetic Library path guards, plus the synthetic existing-empty-root operation. A standalone synthetic-directory diagnosis showed Foundation's `standardizedFileURL` changes existing `/private/var/.../home` into `/var/.../home`, while nonexistent child paths retain `/private/var`. The fix preserves explicit components and compares raw plus POSIX-canonical home paths. The next build and focused run passed (`92 passed, 0 failed`), retained in [task-1-green-build.log](task-1-green-build.log) and [task-1-green-focused.log](task-1-green-focused.log).

A subsequent fixed-identity test was added before extending the instance initializer:

```sh
swift build > .superpowers/sdd/2026-11-03-m5-a-build-identity-and-isolation/task-1-red-fixed-identity.log 2>&1
```

Exit1, as expected: `error: extra argument 'runID' in call`. Then the initializer accepted an injected UUID, retaining a generated default for the process runtime.

### Final GREEN

```sh
swift build > .superpowers/sdd/2026-11-03-m5-a-build-identity-and-isolation/task-1-final-build.log 2>&1
.build/debug/FlowType --self-test --m5-runtime-only > .superpowers/sdd/2026-11-03-m5-a-build-identity-and-isolation/task-1-final-focused.log 2>&1
```

Build exit0: `Build complete! (31.11s)`.

Focused exit0, complete output:

```text
=== FlowType --self-test ===
=== M5 runtime self-test: 94 passed, 0 failed ===
```

The 94 checks cover trusted temp alias canonicalization; explicit symlink/ancestor rejection; home/Library/root/nonempty/relative rejection; original file preservation; workspace/build acceptance; empty root acceptance; concurrent exclusive ownership; isolated directories/models; exact legacy app path casing/formulas; usage64 before launch callback; filter pairing; LaunchServices compatibility; smoke/artifact roles; fixed/unique identities; defaults object identity; suite cleanup ownership; successful bootstrap immutability; unchanged process current after instance fixtures; and isolated logger destination.

Final raw output: [task-1-final-build.log](task-1-final-build.log), [task-1-final-focused.log](task-1-final-focused.log).

### Scoped stage/commit and final worktree

```sh
git add Sources/flowtype/App/RuntimeEnvironment.swift Sources/flowtype/App/RuntimePaths.swift Sources/flowtype/App/FlowTypeApp.swift Sources/flowtype/Testing/M5RuntimeSelfTests.swift Sources/flowtype/Testing/SelfTest.swift Sources/flowtype/Utilities/AppLogger.swift
git diff --cached --check > .superpowers/sdd/2026-11-03-m5-a-build-identity-and-isolation/task-1-staged-check.log 2>&1
git commit -m 'feat: bootstrap isolated validation runtime' > .superpowers/sdd/2026-11-03-m5-a-build-identity-and-isolation/task-1-commit.log 2>&1
git rev-parse HEAD
git status --short
git diff HEAD --check
```

All exit0. Staged check output was empty. Commit output is retained in [task-1-commit.log](task-1-commit.log). Final HEAD is `aea7dc9396b2020d2372c85af0d4da20f10394cf`; final status and diff-check outputs were empty.

## Self-review, limitations, and remaining scope

Self-review checked all six source files, staged scope/diff, strict error mapping, lock/read boundaries (no call to static current/defaults from inside an instance bootstrap lock), root descriptor cleanup, marker exclusivity, non-destructive failures, literal legacy path expectations, focused runner reachability, and default suite ownership. No unresolved Task 1 blocker was found.

The final build still emits the pre-existing AppLogger warning that `nonisolated(unsafe)` is unnecessary on its Sendable DispatchQueue constant. Its annotation is unchanged; no new warning was introduced by the new APIs.

Per the explicit task safety constraint, no full/legacy self-test, swift test, ordinary app, true negative CLI process, GUI, permission, device, recording, keychain, real model, external provider, clipboard, or input-event operation was run. Real usage64/unsupported child-process coverage waits for B1's watchdog and side-effect guards. The parser and real bootstrap launch gate are tested safely in process. Pre-bootstrap fatal access is explicit in source but was not intentionally crashed as a child before those guards exist.

A2 still owns all persistent global/defaults/keychain/model migration and full-runner isolation; A3 owns build identity and logger headers/configure/flush. Their absence is intentional task scope, so the existing non-focused runner must not be executed yet. No subagents or reviewers were spawned, and no push/merge/install/dependency/Python operation occurred. Awaiting controller review before any next task.
