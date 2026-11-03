# B2 implementer report

Status: implemented and verified; controller review pending.
Base: `748855375a4f887732aa282d50d0c3ef2d260c43`.

## Changes

- Added `AppResources`: `.app` resolves only `Contents/Resources/FlowType_FlowType.bundle`; development uses `Bundle.module`. Canonical path comparison resolves each symbolic-link segment (including absent leaves/dangling targets), with a bounded link count and directory-component containment. Individual JSON/icon paths and the standard MLX library location are checked.
- Centralized existing status icon and ASR term/filler resource URLs without changing ordinary postprocessor fallback behavior.
- Added strict artifact resource parsing: nonempty term dictionary, nonempty filler array, nonblank entries, decodable status icon. Missing/malformed/outside failures use closed codes.
- Added `ArtifactReport` with explicit-null success failureCode, staged truth flags, monotonic duration and isolated report emission. Identity must be packaged with non-dirty metadata and no identity error; no app/shared UI/routing/timer/model startup occurs.
- Live dependencies load the standard packaged Metal library with `makeLibrary(URL:)` and separately perform explicit `MLX.add(..., stream: .gpu)` on `[1,2]`, evaluate and retrieve Int32 results. MLX errors are captured via `withError` and converted to closed codes; output must equal `[2,3]`.
- Added `--m5-artifact-contract-only` registration and full-run integration. Every artifact self-test injects synthetic dependencies; no live GPU callback is invoked in focused/full tests.
- Transitive `import MLX` compiles; no Package.swift promotion, dependency changes, or Package.resolved changes.

## RED and repair evidence

All commands were run from `/Users/yiheng/pycode/flowtype-local`. Raw logs named below are adjacent to this report and ignored.

1. `swift build > .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-2-red-build.log 2>&1`: exit 0, 64.80s.
2. `.build/debug/FlowType --self-test --m5-artifact-contract-only --validation-root /Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-2-red-run > .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-2-red.stdout 2> .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-2-red.stderr`: exit 1, **58 passed / 48 failed**, real behavioral failures against safe stubs, no live GPU. Failures include missing/malformed/empty/icon/escaped resources, invalid identities, incorrect stage flags, skipped callbacks, and success null encoding.
3. `swift build > .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-2-green-build.log 2>&1`: exit 0, 38.34s; transitive MLX import succeeds.
4. `.build/debug/FlowType --self-test --m5-artifact-contract-only --validation-root /Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-2-green-run > .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-2-green.stdout 2> .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-2-green.stderr`: exit 1, **105 passed / 1 failed**. Foundation `resolvingSymlinksInPath` left the Metal resource-bundle ancestor unresolved when `default.metallib` did not exist. Preserved that negative fixture; replaced resolution with bounded segment traversal.
5. `swift build > .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-2-green-fixed-build.log 2>&1`: exit 0, 46.86s. Controller requested two additional precise dangling-target cases during this build; a further build compiles their final source before focused verification.

## Self-review and limits

- Resource containment compares canonical path components rather than string prefixes and never falls back to developer resources for `.app`.
- Reports contain identity, enums, booleans, runID and duration; dependency URLs/errors are not encoded or printed.
- Unexecuted stages stay false; successful Metal loading cannot imply MLX success. Invalid identity stops before any resource or hardware callback.
- Full/focused coverage uses generated bundles under the isolated validation root and synthetic Metal/MLX callbacks only. No real configuration, dictionary/DB, Keychain, cache/model baseline, clipboard/input, authorization, providers/network, recording, normal app, model load/download, installs, Python, or dependency upgrade was invoked.
- B2 does **not** establish real packaged Metal loading, MLX GPU success, or MLX default-search provenance. B3 owns those actual runtime checks; chosen standard location is `Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib`.
- No source changes to A/M1–M4 behavior except resource URL consumers and new filter registration. No plans/ledger modifications; no push/merge.

Final GREEN/build/full/lockfile evidence follows; commit recorded below after scoped review.

## Final verification

6. `swift build > .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-2-green-final-build.log 2>&1`: exit 0, 48.15s, includes the final two dangling-target fixtures.
7. `.build/debug/FlowType --self-test --m5-artifact-contract-only --validation-root /Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-2-green-final-run > .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-2-green-final.stdout 2> .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-2-green-final.stderr`: exit 0, **108 passed / 0 failed**, stderr empty.
8. `swift build > .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-2-final-build.log 2>&1`: exit 0, 24.38s. Completed before the single full run.
9. Single full command: exit 0, **24334 passed / 0 failed**, stderr 0 bytes. External watchdog result: `{"exitCode":0,"schemaVersion":1,"termination":"normal","durationMs":257412,"timedOut":false,"failureCode":null}`. No second full run was performed.

```sh
build/m5-process --timeout 900 \
  --stdout .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-2-full.stdout \
  --stderr .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-2-full.stderr \
  --result .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-2-full-result.json \
  -- /Users/yiheng/pycode/flowtype-local/.build/debug/FlowType --self-test \
  --validation-root /Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-2-full-run
```

10. `git hash-object Package.resolved` and `git rev-parse HEAD:Package.resolved` both return `702ce34b917f9fdf9927b1b428f431125c28970c`; `git diff --exit-code -- Package.swift Package.resolved` exit 0, zero diff including originHash. `git diff --check` exit 0.

11. Scoped stage: only the eight source files listed by `git diff --cached --stat`, 339 insertions / 9 deletions. `git diff --cached --check` exit 0. Reviewed the final resource resolver, live closure isolation, staged report guards/encoding, common consumer diff, filter registration and synthetic fixtures; no unrelated source, dependency, generated artifact, plan or ledger staged.

Concerns: no remaining B2 code/test failure observed. Real packaged Metal/MLX/default-search validation remains explicitly B3 pending; synthetic success is not GPU evidence. The external watchdog cleans only its handshaken process group and is not an OS sandbox, as documented in B1.

## Commit

`df63cd2f903cd6de33e5a79db4d1956adef6ced5` — `feat: validate bundled resources and MLX artifact runtime`.

Post-commit `git status --short` is empty. `git diff 748855375a4f887732aa282d50d0c3ef2d260c43 HEAD -- Package.swift Package.resolved` is empty. Stopped after B2 for controller review; B3 not started.
