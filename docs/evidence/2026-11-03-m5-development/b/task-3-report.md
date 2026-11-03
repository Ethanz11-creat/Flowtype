# B3 implementer report

Status: B3 source complete and actual artifact PASS; submitted for controller's final gate record. Base `df63cd2f903cd6de33e5a79db4d1956adef6ced5`.

## Changes and ownership

- Replaced build-app's direct candidate mutation with a shared Swift packaging flow and fixed production adapters. Shell CLI remains no-argument, VERSION optional. Explicit MLX_METALLIB_PATH is checked as a preexisting local MTLB file of at least 1048576 bytes; no Python, install, download, xattr clearing or signing bypass exists. Legacy shader-cache lookup is a read-only fallback; the actual run used the documented explicit old-artifact input and did not scan user caches.
- Production release adapter executes `swift build -c release`, separately queries `swift build -c release --show-bin-path`, requires arm64, copies the executable and actual release resource bundles into private staging, installs the standard Cmlx/default.metallib bundle with plist, consumes the A generator, signs actual Mach-O files then the app, and strictly verifies deep/strict signing.
- Independent `write-artifact-manifest.swift` writes schemaVersion/buildInfo/architecture/binarySHA256/buildInfoSHA256/shaderSHA256/resources after signing; file SHA256 is streamed. Resource paths are canonical-root-relative and hashes cover copied bytes. Metadata uses its own fixed Codable disk schema. No shader source path is included.
- Publication uses one POSIX advisory writer lock, fingerprint-checked old backups, and a journal. The app and manifest are two renames, explicitly not one atomic operation. Prepared transactions roll back; committed transactions finish validated cleanup. Failed owned stages and rollback candidate bytes remain for diagnosis. An in-use candidate is refused, never terminated.
- check-app copies to an independent temporary root outside the checkout, verifies hashes/signature before and after copy, clears shader/SwiftPM/DYLD locator environment for the artifact child, uses an unrelated cwd and separate validation/log root, hides only actual release bundles of this worktree, runs the artifact process with a 30s BoundedProcess, restores outside that inner watchdog, and strictly decodes an independent Codable artifact report. Bad boolean/numeric schemas fail; actual original/copied hash triples are recorded.
- Hiding has the same writer lock, token/fingerprint marker, recorded owner/inner PID, and conflict checks. Recovery refuses active inner processes/groups or unknown original content and never overwrites unknown directories. A `.build` resolving outside the current canonical repo is refused.
- TERM/INT cancellation uses a preinitialized nonblocking self-pipe; the raw signal handler only writes a byte and restores errno. Ordinary synchronized code observes cancellation. BoundedProcess gained optional cancellation/on-launch hooks, retaining default B1 behavior and closed result codes. FD_CLOEXEC prevents lock/cancellation fds leaking through exec. Shell traps clean only their own tool scratch directory.
- build-dmg reads plist version/build number, verifies matching external manifest and strict signing, then creates a local DMG; automatic release instructions removed. DMG creation is not run in B3.
- Extra helpers beyond the brief: `scripts/verification/ArtifactPackaging.swift` is the shared implementation; `ArtifactPackagingCLI.swift` supplies fixed production adapters. Test adapters exist only in `ArtifactPackagingSelfTests.swift`, not production env switches.

## Synthetic verification evidence

All commands ran from `/Users/yiheng/pycode/flowtype-local`; raw logs named below are in this report's directory. No product source changed, so the already successful B2 full product suite was not repeated.

Compile pattern:

```sh
swiftc scripts/verification/BoundedProcess.swift scripts/verification/ArtifactPackaging.swift scripts/verification/ArtifactPackagingSelfTests.swift -o build/m5-packaging-tests
build/m5-packaging-tests
```

- Initial compile typo was corrected before behavioral RED; `task-3-red-compile.log` final exit 0.
- `task-3-red.stdout/.stderr`: exit 1, `=== packaging self-test: 10 passed, 12 failed ===`.
- Final independent recovery RED (`task-3-red-final.stdout/.stderr`): exit 1, `=== packaging self-test: 10 passed, 18 failed ===`. Failures explicitly include missing/short/invalid shader protection, sign failure preservation, HEAD changes, in-use preservation, artifact fail/timeout restoration, and parseable manifest behavior.
- First GREEN (`task-3-green.stdout`): exit 1, 21/2. Debug logs `task-3-green-debug*.stdout` identify journalInvalid. Retained synthetic fixture evidence showed Foundation enumeration canonicalizing `/var` to `/private/var`, causing bad relative digest prefixes and backup mismatch. Corrected with POSIX canonical roots and literal resource-prefix checks.
- `task-3-green-fixed.stdout/.stderr`: exit 0, 84/0.
- Expanded controller edge coverage `task-3-final-fixtures.stdout/.stderr`: exit 0, 126/0.
- Strict metadata writer and stage failure-code check `task-3-final2-fixtures.stdout/.stderr`: exit 0, 126/0; stderr empty.
- Final packaging and amended runner results follow below, including immediate handshake cancellation.

Other exact commands:

```sh
swiftc scripts/verification/BoundedProcess.swift scripts/verification/ArtifactPackaging.swift scripts/verification/ArtifactPackagingCLI.swift -o build/m5-artifact-tool
swiftc scripts/verification/BoundedProcess.swift scripts/verification/ProcessRunnerSelfTests.swift scripts/verification/ProcessCLI.swift -o build/m5-process
build/m5-process --self-test
bash -n scripts/build-app.sh scripts/build-dmg.sh scripts/check-app.sh
```

CLI compile `task-3-final-cli-compile.log` exit 0. Runner compile `task-3-runner-compile.log` exit 0, runner test `task-3-runner.stdout/.stderr` exit 0, `=== process runner self-test: 17 passed, 0 failed ===`, stderr empty. Shell syntax exit 0.

Fixtures exercise actual shared control flow with generated Git repositories, spaces in paths and locally generated MTLB bytes; actual identity/manifest scripts run in those fixtures. Signing/build/artifact dependencies are explicit test-driver closures. The fake signer changes executable bytes, then manifest SHA is checked against independently executed shasum, and each resource digest is checked against real copied files. Real killed marker owner, TERM owner restoration, unknown conflicts, live inner PID refusal, and writer-lock exclusion are covered. No synthetic fixture invokes real GPU or model work.

## Limits

No product source, dependency graph/lockfile, dependency checkout, user config/DB/dictionary/Keychain/model/cache baseline, permissions, clipboard/input, recordings, normal app launch, provider/network action, installs/downloads, push/merge, DMG or final ten-smoke run was touched. Actual shader input was the preexisting old candidate's `Contents/MacOS/mlx.metallib`, copied before candidate replacement.

The watchdog owns only its handshaken process group, not arbitrary independent descendant groups or an OS sandbox. TERM cleanup can race an outer TERM→KILL budget; durable token/fingerprint/inner-group conflict checks must restore safely or explicitly Fail on next invocation, never call leftover hiding Pass. No attempt was made to kill a non-owned normal app. Concrete actual termination/restoration results are recorded below; B3 GPU success comes from the actual explicit-GPU operation, separately from direct Metal loading.

Source commit, actual build-app/check-app and signed binary identity are complete below. Controller explicitly deferred evidence archival to C3; no additional evidence/docs commit was created in B3.

## Final source verification / source commit

- `task-3-verified-compile.log` exit 0. `build/m5-packaging-tests > task-3-verified-fixtures.stdout 2> task-3-verified-fixtures.stderr`: exit 0, **128 passed / 0 failed**, stderr empty. The final two checks cover immediate handshake cancellation and group cleanup.
- `task-3-verified-runner-compile.log` exit 0. `build/m5-process --self-test > task-3-verified-runner.stdout 2> task-3-verified-runner.stderr`: exit 0, **17 passed / 0 failed**, stderr empty.
- `bash -n scripts/build-app.sh scripts/build-dmg.sh scripts/check-app.sh`: exit 0. `git diff --cached --check`: exit 0; scoped stage exactly eight script/helper files, 857 insertions / 149 deletions. No product/Package/lockfile changes.
- Source commit: **c21cb25e4d37249d3d932939a6157b946b64a243** — `build: package portable resources with strict signing`.
- `git status --short` empty immediately after source commit. Sources tree: **953608b60a0349dfcd2acfc4ddeef6f6d6b39288**. `git diff --exit-code -- Package.swift Package.resolved` exit 0; Package.resolved blob remains `702ce34b917f9fdf9927b1b428f431125c28970c`.
- Existing explicit shader input stat before run: **146852000 bytes**. No user cache scan, Python, installs, or downloads were needed.

## Single actual build command

```sh
MLX_METALLIB_PATH='/Users/yiheng/pycode/flowtype-local/build/FlowType.app/Contents/MacOS/mlx.metallib' \
build/m5-process --timeout 900 \
  --stdout .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-3-actual-build.stdout \
  --stderr .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-3-actual-build.stderr \
  --result .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-3-actual-build-result.json \
  -- /Users/yiheng/pycode/flowtype-local/scripts/build-app.sh
```

Raw bounded child-tool logs for this actual build: `build/packaging-5DC4EB68-C637-433E-8731-E315686BF9E9/`. Actual build completed successfully as recorded below.

## Actual build result

Command exit **0**. `task-3-actual-build.stdout` exactly:

```text
FlowType candidate and manifest staged, signed, and published
```

`task-3-actual-build.stderr` is empty. Raw outer result:

```json
{"termination":"normal","exitCode":0,"timedOut":false,"durationMs":176963,"failureCode":null,"schemaVersion":1}
```

Actual `swift build -c release` completed in **163.32s**. Its raw log is `build/packaging-5DC4EB68-C637-433E-8731-E315686BF9E9/B8AA7168-202B-4CB3-B03B-9207081FE4A4.stdout`. It reports ten warnings in unchanged product code (unused/mutable values, AudioRecorder Sendable captures, deprecated regionCode and AudioDevice Optional<CFString> pointer formation); no compile errors. Those files were not changed by B3.

Actual final signing and strict/deep verification succeeded. `478B5EC1-94ED-485F-BA8F-60F32279F8B2.stderr` in that build log directory contains the stage app's `valid on disk` and `satisfies its Designated Requirement`. Final signing happened before manifest calculation and no app resources were modified afterward.

Signed candidate identity:

| Field | Value |
| --- | --- |
| source commit | c21cb25e4d37249d3d932939a6157b946b64a243 |
| Sources tree | 953608b60a0349dfcd2acfc4ddeef6f6d6b39288 |
| version / build | 1.0.0 / 350 |
| builtAt / dirty | 2026-11-03T04:57:15Z / false |
| binarySHA256 | c59eb53b8aaec14421ef19e2c884e67cbb94f46a31ec069092051e66a38ac85f |
| buildInfoSHA256 | 9ff060d015a4a3fefffb63b1378bd9e55545f7da17203cd985d5e73b42b6afc8 |
| shaderSHA256 | f36b01c44dd5f2d9020deb1ac6ad53dc085de81af19396694c5963ef3a12137f |

The complete external manifest is `build/FlowType.manifest.json`, schemaVersion 1, architecture arm64, with 14 relative resource path/hash entries. Shader destination is `Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib`; source absolute path is not in the manifest.

## Single actual relocated check

The empty output directory was created with `mkdir .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-3-check-output`, exit 0. Exact command:

```sh
env -u MLX_METALLIB_PATH build/m5-process --timeout 30 \
  --stdout .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-3-actual-check.stdout \
  --stderr .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-3-actual-check.stderr \
  --result .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-3-actual-check-result.json \
  -- /Users/yiheng/pycode/flowtype-local/scripts/check-app.sh \
  --app /Users/yiheng/pycode/flowtype-local/build/FlowType.app \
  --output /Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-3-check-output
```

Exit **0**, stdout exactly `FlowType moved artifact check passed`, outer stderr empty. Raw outer result:

```json
{"failureCode":null,"exitCode":0,"schemaVersion":1,"termination":"normal","durationMs":8880,"timedOut":false}
```

The actual artifact stdout is exactly one JSON line, and artifact stderr is empty:

```json
{"metalLibrary":true,"buildInfo":{"failureCode":null,"metadata":{"buildNumber":"350","sourceTree":"953608b60a0349dfcd2acfc4ddeef6f6d6b39288","dirty":false,"gitSHA":"c21cb25e4d37249d3d932939a6157b946b64a243","schemaVersion":1,"builtAt":"2026-11-03T04:57:15Z","version":"1.0.0"},"origin":"packaged"},"ok":true,"schemaVersion":1,"role":"smokeTest","durationMs":843,"failureCode":null,"mode":"artifact","appResources":true,"mlxOperation":true,"runID":"908DDA1F-0B66-42D2-BCF6-0B15E2BD5D9C","resolvedInsideApp":true}
```

This is a real packaged executable running from a temporary root outside this checkout, with unrelated cwd, MLX_/SWIFTPM_/DYLD_ locator environment cleared and the actual worktree release bundles hidden. `metalLibrary=true` is actual `makeLibrary(URL:)`; `mlxOperation=true` separately means explicit GPU `[1,2]+1`, eval and retrieved `[2,3]` succeeded. No model was loaded.

`task-3-check-output/check-result.json` records signature=true, resourcesHidden=true, resourcesRestored=true, exact packaged source identity and identical actual hash triples before/after copy. The three hashes are the same binary/metadata/shader values in the table above. Raw strict/deep signature logs under that output directory show `valid on disk` / `satisfies its Designated Requirement` for the original candidate and for the moved copy both before and after execution. No second actual build or artifact-check was run.

## Final recovery / source checks and handoff

Final read-only checks, all exit 0:

```sh
test ! -e build/.m5-resources.json && test ! -e build/.m5-publication.json
/bin/bash -c 'shopt -s nullglob; remaining=(.build/arm64-apple-macosx/release/.m5-hidden-*); test ${#remaining[@]} -eq 0'
git status --short
git diff --exit-code -- Package.swift Package.resolved
git hash-object Package.resolved
```

Worktree is clean at source commit c21cb25. Lockfile blob still `702ce34b917f9fdf9927b1b428f431125c28970c`. The actual four release bundles are restored at their original paths: FlowType_FlowType.bundle, GRDB_GRDB.bundle, swift-crypto_Crypto.bundle, swift-transformers_Hub.bundle. No hiding marker, publication journal, or hidden resource leftovers remain. The output's resourcesRestored=true and the successful path checks agree.

B3 source and actual artifact gates pass. Compiler warnings in unchanged product code remain noted above. No B3 blocker observed. Final ten-smoke run, complete C aggregation/archival, real model/GUI/V1–V5 claims remain pending their separate owners; B3 does not transfer old product identity results. Per controller instruction, no extra docs/evidence commit; stopped after this B3 report for controller review.
