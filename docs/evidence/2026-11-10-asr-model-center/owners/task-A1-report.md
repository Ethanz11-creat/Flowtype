# Task A1 implementation report

**Current contract after review fix round 1:** all runtime sample hashes are canonical little-endian Float32 PCM SHA256. The historical original resource-hash exception below is superseded; see the appended fix report.

Base: `1d8583b` (`D1` stable baseline). Commit: `72f57e5` — `feat: define stable ASR backend identities and migration`. Scope: A1 only. No credential store, protocol transport, routing integration, UI migration, or user-state access added.

## Implementation

- Added the exact cross-task identity/location/protocol/selection/authentication/local-service-profile fields from backend spec §1.
- Added descriptor and binding fields from §2. Binding equality compares descriptor, retained native lease ID, and credential generation; provider objects are deliberately excluded. Native descriptor construction uses `LocalASRLease.id` as revision and retains native capabilities with `requiresInternet=false`.
- Added `.localService` to legacy `ProviderLocation`. The loopback fixture demonstrates `requiresNetwork=true` (socket) independently of `requiresInternet=false`. Existing native and cloud capabilities remain untouched. The complete build verifies compatibility of existing enum consumers.
- Added optional `Configuration.asrBackendSelection` (missing/null => nil), `localASRServices` (missing => empty), and cloud profile revision (missing => generated UUID, retained on re-encode). Existing profile URL/model/UUID/active flags and orphan key dictionaries survive.
- Added pure `ASRBackendMigration.selection(from:)`. Explicit new selections take precedence. Legacy localOnly retains native reference; cloudOnly retains old active/first cloud profile without adding native fallback; auto retains cloud primary/native fallback and old cloud-fallback consent. No filesystem/hardware inspection or configuration mutation occurs.
- Added validated immutable `ASRValidationSample`, rejecting empty PCM and rates other than 16,000 Hz. Computed initializer fingerprints canonical little-endian Float32 PCM using system CryptoKit. The exact field-contract initializer accepts an explicit trusted resource hash, allowing a packaged WAV hash; callers own that supplied fingerprint.
- Added focused `--asr-backends-only` parser registration and both focused/full self-test entry points through `ASRBackendSelfTests.run(_:) async`. This runner is the extension point for later transport/routing tests.

## Clarifications and downstream contracts (controller rulings)

1. Preserve legacy `CloudASRConfig.activeProvider` behavior: active row, otherwise first row, even if disabled. Do not rewrite active flags. Reference identity is profile UUID rather than row/name.
2. Native migration uses explicit imported UUID first, then explicit selected preset ID (including unavailable/unknown IDs). Path-only or automatic legacy native intent with no explicit ID produces **nil native reference**, while original path/automatic configuration stays untouched. Do not invent a preset, derive a path UUID, or inspect disk. A4 must resolve that legacy unresolved intent to the **actual successfully captured lease identity**, then persist the resolved selection. This resolution applies only to legacy intent; an explicit user-cleared new selection must remain empty. A2 persistence must preserve enough unmigrated intent for this A4 resolution.
3. A1 produces serializable revision fields and pure selection projection only. A2 owns persisted migration and revision regeneration on call-impacting cloud URL/model/protocol/capability/key edits. A4 captures the resulting immutable descriptors. Existing UI/save paths are intentionally unchanged in A1.
4. Sample hashes: computed runtime initializer hashes canonical little-endian PCM; explicit `sha256` initializer can retain a trusted packaged WAV fingerprint. C2 resource documentation must distinguish the two.

These ambiguities were raised to the controller before committing; none were silently skipped.

## TDD evidence

Tests were written before new production types. The failing test fixture covers three decoded legacy policies; custom UUID/URL/empty model/disabled profile/orphan key preservation; revision round-trip; rename/reorder stability; missing imported/preset references; automatic/path-only no substitution; explicit native/service consent; service profile round-trip; sample validation/fingerprint; native lease ownership and binding equality.

### RED

Command: `swift build`

Captured as:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/task-A1-logs/red-build.log 2>&1
```

Actual result: **exit 1**, expected missing A1 types/fields. Relevant output:

```text
error: value of type 'Configuration' has no member 'asrBackendSelection'
error: cannot find 'ASRBackendMigration' in scope
error: cannot find 'ASRValidationSample' in scope
error: cannot find 'ASRBackendBinding' in scope
error: cannot find 'ASRBackendDescriptor' in scope
```

This was the brief's expected compile RED; no parameter-parser exit 64 was counted as business RED. Full log: `task-A1-logs/red-build.log`.

### GREEN (sequential; no competing build/self-test processes)

1. `swift build` => **exit 0**, `Build complete! (57.88s)`. Full log: `task-A1-logs/green-build.log`. Build emitted existing warnings in untouched audio/deprecation code (e.g. AudioDevice/AudioRecorder and locale regionCode). No warnings originate in A1 changed files; output is therefore not claimed pristine.
2. `swift run --skip-build FlowType --self-test --asr-backends-only` => **exit 0**, `=== ASR backend self-test: 57 passed, 0 failed ===`. Full log: `task-A1-logs/green-backends.log`.
3. `swift run --skip-build FlowType --self-test --m2-fix-only` => **exit 0**, `=== M2 fix self-test: 276 passed, 0 failed ===`. Full log: `task-A1-logs/green-m2-fix.log`. Both self-test outputs contain only their start/summary lines; no failures or warnings.

`git diff --check` passed. No full-suite repetition was run: controller explicitly bound A1 to focused/M2 verification and left the full suite to the phase lane.

## Files

Created:

- `Sources/flowtype/Services/Speech/Backends/ASRBackendIdentity.swift`
- `Sources/flowtype/Services/Speech/Backends/ASRBackendSelection.swift`
- `Sources/flowtype/Services/Speech/Backends/ASRBackendDescriptor.swift`
- `Sources/flowtype/Services/Speech/Backends/ASRBackendMigration.swift`
- `Sources/flowtype/Services/Speech/Backends/ASRValidationSample.swift`
- `Sources/flowtype/Testing/ASRBackendSelfTests.swift`

Modified:

- `Sources/flowtype/Core/Configuration.swift`
- `Sources/flowtype/Services/Speech/ASRContract.swift`
- `Sources/flowtype/App/RuntimeEnvironment.swift`
- `Sources/flowtype/Testing/SelfTest.swift`

## Self-review

Read all changed production files, test fixture, and tracked diff. Checked cross-task field signatures against spec; exhaustive routing-policy branches; new selection precedence; no file existence filtering; no defaults overwriting custom profiles; binding lease retention; both test registrations; encode/decode compatibility; and explicit file staging. No implementation defect found. Existing large Configuration/SelfTest files were changed narrowly, without structural refactoring. No Package.resolved change, new dependency, secret handling, network call, model load, microphone/clipboard/permission access, push, or real user configuration write was introduced.

Remaining dependencies are the controller-approved A2 persistence/revision changes and A4 unresolved legacy lease resolution above; they are not claimed complete by A1. No real service/model/manual validation was claimed.

## Review fix round 1 — canonical sample fingerprint

Fix commit: `095692a` — `fix: enforce canonical ASR validation sample fingerprints`.

The fresh review's Important finding was verified: the explicit initializer could assign arbitrary or WAV-resource hashes to identical PCM. The controller clarified that its earlier instructions conflicted and the final contract requires **canonical little-endian Float32 PCM SHA256 for every ASRValidationSample**, with WAV checksums retained separately in C2 resource metadata. This final instruction supersedes the original implementation/report exception above.

Changes: the throwing explicit-hash initializer now delegates to the computed initializer and throws `ValidationError.invalidSHA256` unless the supplied value exactly matches the canonical lowercase PCM digest. There is one hashing/PCM-validation path. Tests use nonzero PCM `[1, -0.5]`, independently verified little-endian bytes `0000803f000000bf`, and literal digest `e5e0ce39fac89cd93af5ba8bcad2fe35d88c75417c7e44941fe5ee4e48f1cf75`. Matching digest acceptance and identical-PCM identity across both constructors are covered, together with incorrect 64-digit, malformed, nonhex 64-character, empty PCM, and wrong-rate rejection.

### Fix RED

Before changing production code:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/task-A1-logs/fix1-red-build.log 2>&1
```

Exit 0; full build output:

```text
[0/1] Planning build
[1/1] Compiling plugin GenerateManual
[2/2] Compiling plugin GenerateDoccReference
Building for debugging...
[2/6] Write sources
[3/6] Write swift-version--1AB21518FC5DEDBE.txt
[5/8] Compiling FlowType ASRBackendSelfTests.swift
[6/8] Emitting module FlowType
[6/9] Write Objects.LinkFileList
[7/9] Linking FlowType
[8/9] Applying FlowType
Build complete! (39.65s)
```

```sh
swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/task-A1-logs/fix1-red-backends.log 2>&1
```

Exit **1**; full output:

```text
  ✗ FAIL: incorrect 64-digit PCM fingerprint rejected
  ✗ FAIL: malformed resource fingerprint rejected
  ✗ FAIL: nonhex 64-character fingerprint rejected
=== FlowType --self-test ===
=== ASR backend self-test: 60 passed, 3 failed ===
```

These are the exact intended behavior failures: production accepted the three invalid supplied digests. Matching/nonzero hash and explicit sample validation checks already passed.

### Fix GREEN

After the minimal production initializer correction, sequential commands:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/task-A1-logs/fix1-green-build.log 2>&1
```

Exit **0**; full output:

```text
[0/1] Planning build
[1/1] Compiling plugin GenerateManual
[2/2] Compiling plugin GenerateDoccReference
Building for debugging...
[2/6] Write sources
[3/6] Write swift-version--1AB21518FC5DEDBE.txt
[5/8] Compiling FlowType ASRValidationSample.swift
[6/8] Emitting module FlowType
[6/9] Write Objects.LinkFileList
[7/9] Linking FlowType
[8/9] Applying FlowType
Build complete! (34.74s)
```

```sh
swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/task-A1-logs/fix1-green-backends.log 2>&1
```

Exit **0**; full output:

```text
=== FlowType --self-test ===
=== ASR backend self-test: 63 passed, 0 failed ===
```

Both fix build logs and focused GREEN output have no warnings. M2/full suite were intentionally not repeated per controller instructions: this correction touches only sample identity and its focused tests. The original full-build baseline warnings remain recorded and were not fixed by this incremental build.

Self-review: read both changed files and diff; `git diff --check` passed. The supplied initializer cannot bypass canonical hashing or PCM validation; malformed values fail the same exact comparison as incorrect values. No broader task work or user-state access. Files changed: `Sources/flowtype/Services/Speech/Backends/ASRValidationSample.swift`, `Sources/flowtype/Testing/ASRBackendSelfTests.swift`. No remaining concern from this finding.
