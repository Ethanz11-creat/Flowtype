# Task A2 implementer report

Base: `095692a`. Status: DONE. Final focused verification completed below.

## Implemented

- Added `ASRCredentialStore: Sendable` and atomic value/generation snapshot, traditional Keychain implementation and injected memory/SecItem-boundary fixtures. One shared production store owns stable per-process UUID generations. Successful changed-value writes and actual removals rotate generation; failed/same-value operations do not. Writes use update-existing/add-if-missing and never delete first. Reads distinguish missing from access/data errors.
- Non-app roles route all credential operations to isolated memory before any system adapter call. Both self-test and smoke roles have downstream-spy coverage. No test reads real credentials, configuration, model paths, permissions, clipboard, microphone or HF token.
- Added deterministic, per-key, retryable migration with verified readback. Failed reads/writes/readback preserve their legacy copies. UUID-shaped orphan IDs migrate to deterministic `asr.cloud.<UUID>` records; malformed/orphan string IDs remain pending and recoverable. Existing different credential values are never overwritten by a retry; original backup and pending ID survive.
- `ConfigurationStore` persists migrated selection/generated revisions together with the original legacy copies before migrating any credentials, then verifies the scrubbed persisted config before replacing its live source. Production writes synchronize UserDefaults and compare persisted data. Injectable writer plus independent defaults readback exercise source-save/final-save failure. Pending IDs and a safe recoverable error are exposed. ASR migrations do not alter LLM key storage/migration behavior.
- Cloud draft saves stage only references/revision and already-existing recovery copies, write/verify the credential, then scrub. Newly typed cloud/service/HF credential text is never encoded into new configuration. Explicit key removal writes an empty Keychain tombstone before scrub so a failed scrub/crash/restart cannot resurrect an old legacy key. Profile-deletion cleanup is deliberately deferred; in-flight snapshots retain their captured value.
- Persisted call revisions rotate on changed URL/model/protocol/vendor/capabilities/provider or credential edits. Rename/activation do not change call revision. Immutable existing request snapshots remain valid and retain their original values.
- Settings draft checks/readiness and runtime cloud configuration resolve migrated keys through the store rather than an emptied dictionary. Locked credentials produce a safe error; compatibility availability treats them as unavailable, never an empty key. Corrupt-config diagnostics omit all original string contents, including arbitrary-prefix tokens, rather than relying on token-prefix regexes.

## Exact downstream APIs / A4 handoff

- `KeychainASRCredentialStore.shared`: use this production owner so generations are stable between consumers. `init(access: ASRCredentialAccess)` injects the storage boundary; `.memory()` provides role-safe memory.
- `ASRCredentialStore.snapshot(id: String) throws -> ASRCredentialSnapshot`, fields `value: String?` and `generation: UUID`, reads both in the store's single critical section. Do not separately read value and generation for capture.
- `Configuration.cloudASRCredential(profileID: UUID, store: any ASRCredentialStore) throws -> ASRCredentialSnapshot`: atomic store snapshot, then legacy fallback **only when snapshot.value == nil**. A stored empty string is an explicit-removal tombstone and must never fall back to legacy JSON.
- `Configuration.effectiveCloudASRConfig(store: any ASRCredentialStore) throws -> (provider: CloudASRProviderConfig, apiKey: String)?`: injected throwing resolver. Property `effectiveCloudASRConfig` preserves old caller API, uses shared guarded store, and returns nil on access failure. A4/A6 should use throwing snapshot/resolver to retain errors/generation rather than interpret nil as an absent saved selection.
- `ConfigurationStore.asrCredentials`, `cloudASRCredential(profileID:) throws`, `retryASRCredentialMigration()`, `pendingASRCredentialIDs`, `asrPersistenceError`, `saveASRDraft(_:) throws` provide persistence and settings boundaries.
- IDs: `CloudASRProviderConfig.credentialID` is `asr.cloud.<UUID>`; service callers use `asr.service.<UUID>`, HF official token callers use `asr.hf.official`. Store IDs do not embed key values.
- `ASRCredentialMigration.migrate(configuration:store:)` returns a proposal; callers must verify persistence before replacing their recoverable source. ConfigurationStore performs that ownership sequence serially on existing app settings/startup paths. It never overwrites an existing mismatched credential during a retry.
- Tombstones deliberately remain stored until all legacy copies are safely absent; UI does not invoke physical remove first. The protocol's `remove(id:)` still physically removes and rotates generation for eventual safe cleanup.
- A1's unresolved native path/automatic intent fields remain untouched; A4 still owns lease-based resolution. Adapters/new routing/model-center UI were not implemented here.

## TDD and verification evidence

All commands ran sequentially, with output redirected under this ignored task workspace. Full suite was intentionally not run, per controller's focused verification instruction overriding the generic skill default.

### First RED / GREEN: credential store and per-key migration

Commands:

```
swift build > .superpowers/sdd/2026-11-09-asr-model-center/A2-red-build.log 2>&1
swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A2-red-backends.log 2>&1
```

RED build exit 0, `Build complete! (38.91s)`. Against compiling no-op contract scaffolds, focused runner exit 1:

```
FAIL: credential update error propagates
FAIL: failed update preserves previous credential — got nil, want Optional("fixture-old")
FAIL: failed update preserves generation
FAIL: credential add error propagates
FAIL: failed add never deletes another credential
FAIL: same value preserves generation
FAIL: snapshot captures changed value
FAIL: only confirmed migration removed
FAIL: retry only unfinished key
FAIL: retry migrates remaining key
FAIL: retry does not rewrite migrated key
FAIL: credential lock exposes retry status
=== ASR backend self-test: 74 passed, 12 failed ===
```

Expected missing store mutation/generation/migration behavior. Required named tests exist: `testWriteFailurePreservesPreviousCredential`, `testPartialMigrationRetriesWithoutLoss`, `testCredentialLockDoesNotClearSelection`, `testSerializedNewConfigHasReferencesOnly`.

After implementation:

```
swift build > .superpowers/sdd/2026-11-09-asr-model-center/A2-green1-build.log 2>&1
swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A2-green1-backends.log 2>&1
```

Both exit 0: `Build complete! (44.72s)`; `=== ASR backend self-test: 86 passed, 0 failed ===`.

Initial test-authoring compiler typo (`ASRBackendID.cloud` does not exist) was corrected to `.init(rawValue:)` before the above valid RED; it was not counted as behavioral RED. Swift 6 required local `query` to be `@Sendable`; corrected before GREEN.

### Second RED / GREEN: persistence, runtime lookup, revisions

```
swift build > .superpowers/sdd/2026-11-09-asr-model-center/A2-red2-build.log 2>&1
swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A2-red2-backends.log 2>&1
```

Build exit 0 (`45.21s`), runner exit 1:

```
FAIL: failed save exposes recoverable state
FAIL: retry commits reference-only cloud config
FAIL: selection persisted with stable legacy identity
FAIL: runtime resolves migrated credential after dict emptied
FAIL: model edit rotates call revision
FAIL: credential edit rotates call revision
=== ASR backend self-test: 98 passed, 6 failed ===
```

After persistence/resolver/revision implementation:

```
swift build > .superpowers/sdd/2026-11-09-asr-model-center/A2-green2-build.log 2>&1
swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A2-green2-backends.log 2>&1
```

Both exit 0 (`Build complete! (50.33s)`; `=== ASR backend self-test: 104 passed, 0 failed ===`). Fixtures additionally cover idempotence, newer credential conflict, failed readback, preserved LLM values and stable revisions after restart.

### Third RED / GREEN: explicit removal crash/restart recovery

```
swift build > .superpowers/sdd/2026-11-09-asr-model-center/A2-red3-build.log 2>&1
swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A2-red3-backends.log 2>&1
```

Build exit 0 (`32.77s`); runner exit 1:

```
FAIL: failed removal scrub reports failure
FAIL: explicit removal writes durable tombstone
FAIL: restart never resurrects removed legacy credential
FAIL: failed scrub retains recoverable legacy copy
FAIL: tombstone conflict remains visible for recovery
=== ASR backend self-test: 112 passed, 5 failed ===
```

After staged persistence/tombstone implementation:

```
swift build > .superpowers/sdd/2026-11-09-asr-model-center/A2-green3-build.log 2>&1
swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A2-green3-backends.log 2>&1
swift run --skip-build FlowType --self-test --m5-isolation-only > .superpowers/sdd/2026-11-09-asr-model-center/A2-green3-isolation.log 2>&1
```

All exit 0: build `40.26s`, backends `117 passed, 0 failed`, isolation `64 passed, 0 failed`. Atomic snapshot concurrency and both-role guarded downstream spies also pass.

### Existing focused settings/ownership regressions

Added existing ProviderDraft, ProviderDraftCheck, SettingsChange and cloud connection-ownership tests to the backend runner because these are changed call/save boundaries, not a broad full-suite run.

```
swift build > .superpowers/sdd/2026-11-09-asr-model-center/A2-red4-build.log 2>&1
swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A2-red4-backends.log 2>&1
```

Build exit 0 (`31.66s`), runner exit 1 (`332 passed, 5 failed`):

- `checkDoesNotCommit: tested normalized snapshot matches saved profile`: exact call values matched, saved revision intentionally differs.
- `hotkeySettingsReloadOnce: latest binding settings restore`: new persisted selection vs previously nil fresh fixture.
- `sameTurnChangesKeepLatestSettings: all same-turn fields restore`: same derived selection mismatch.
- `duplicatePublicationsDoNotResave: persisted configuration is complete`: same derived selection mismatch.
- `model selection: preset changes only target model...`: target revision intentionally changed.

Controller approved synchronizing only the expected derived metadata. Fresh settings fixtures now explicitly initialize migrated selection; draft/model assertions first verify revision changed, then compare the entire profile/config with only the revision synchronized. Exact user values/activation/other profiles remain asserted.

```
swift build > .superpowers/sdd/2026-11-09-asr-model-center/A2-green4-build.log 2>&1
swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A2-green4-backends.log 2>&1
swift run --skip-build FlowType --self-test --m5-isolation-only > .superpowers/sdd/2026-11-09-asr-model-center/A2-green4-isolation.log 2>&1
```

All exit 0: build `28.48s`, backend `339 passed, 0 failed`, isolation `64 passed, 0 failed`.

### Final self-review verification

Self-review prioritized a locked credential over cached availability in ASRModelStatusCard, avoided duplicate Keychain reads there, and asserted every staged new-cloud save excludes newly typed arbitrary-prefix token text. A test-only unused-lock-result warning was removed.

An initial final run (`A2-final-backends.log`) returned `339 passed, 1 failed` because its new-profile serialization fixture reused the default SiliconFlow display name and correctly hit duplicate-name validation. The fixture now uses `New fixture cloud profile`; no production validation was weakened. This was a fixture-authoring failure, not counted as feature RED.

Final commands, run sequentially after all source/test edits:

```
swift build > .superpowers/sdd/2026-11-09-asr-model-center/A2-final2-build.log 2>&1
swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A2-final2-backends.log 2>&1
swift run --skip-build FlowType --self-test --m5-isolation-only > .superpowers/sdd/2026-11-09-asr-model-center/A2-final2-isolation.log 2>&1
git diff --check
```

All exit 0. Exact relevant output:

```
Build complete! (33.33s)
=== ASR backend self-test: 342 passed, 0 failed ===
=== M5 isolation self-test: 64 passed, 0 failed ===
```

Final incremental build and test logs contain no warning/error/FAIL lines (`rg` found none, normal no-match exit 1). `git diff --check` emitted nothing. Earlier wider recompiles included pre-existing untouched audio/deprecation warnings; no remaining warning originates in A2 files. Package.resolved has no diff.

## Files changed

Created:
- Sources/flowtype/Services/Speech/Backends/ASRCredentialStore.swift
- Sources/flowtype/Testing/ASRCredentialSelfTests.swift

Modified:
- Sources/flowtype/Core/Configuration.swift
- Sources/flowtype/Core/ConfigurationStore.swift
- Sources/flowtype/Services/Speech/CloudASRProvider.swift
- Sources/flowtype/Settings/ASRModelStatusCard.swift
- Sources/flowtype/Settings/ASRProviderEditSheet.swift
- Sources/flowtype/Settings/CloudASRConnectionCheck.swift
- Sources/flowtype/Settings/CloudASRProviderList.swift
- Sources/flowtype/Settings/ProviderDraftCommit.swift
- Sources/flowtype/Testing/ASRBackendSelfTests.swift
- Sources/flowtype/Testing/CloudProviderSelfTests.swift
- Sources/flowtype/Testing/ProviderDraftCheckSelfTests.swift
- Sources/flowtype/Testing/SettingsChangeSelfTests.swift

## Self-review / constraints / concerns

Read complete diff including new files and checked normal/locked/partial/readback/save-failure/crash ordering. Source save precedes credential migration, final scrub precedes live-copy removal, conflicting newer keys are retained, and nil vs empty has distinct behavior. No adapter/routing/model-center work, dependency changes, Package.resolved changes, push, merge or user-state operations.

Controller-approved scope adjustments: adjacent runtime/settings resolver files were necessary to prevent migrated credentials becoming unavailable; metadata expectations in existing focused fixtures were updated without weakening exact value assertions. Controller-approved empty-value tombstones handle removal crash recovery.

No known open implementation concern. Real login Keychain locked/unlocked/unsigned-app behavior and manual UI interaction are **Pending**, deliberately not represented as passed by the memory fixtures. Generic code/artifact/release gates and actual device/network/signing tests remain later master-plan work. Original native path/automatic-intent resolution remains A4 work; old fields are preserved.

## Commit

`211d4ec` — `feat: store ASR credentials with recoverable migration`. Explicit 14 task files committed. Worktree status after commit is clean; ignored report/logs retained for controller review. No push.

# A2 fix round 1 — Important I1

The review found a real crash-ordering defect: the original staged save published draft URL/model/protocol before the corresponding key was verified. Failed credential write plus failed rollback could persist the same mismatch. The previous DONE report's crash-ordering assessment was incomplete; this section supersedes its draft-save ordering and removal-failure semantics.

## Controller ruling / schema contract

Controller approved immutable profile-scoped credential versions and one configuration commit instead of a cross-store rollback:

- `CloudASRProviderConfig.credentialReferenceID: String?` is backward-compatible; nil retains the existing `asr.cloud.<profile UUID>` namespace.
- New values use `asr.cloud.<profile UUID>.<fresh UUID>`. `credentialID` remains the computed selected ID; `validatedCredentialID() throws -> String` checks exact owning profile prefix and valid UUID suffix before store access. HF/service/other-profile/malformed references are rejected.
- For a changed credential (including an empty removal tombstone), save the OLD committed config/recovery copies first, write and verify the new immutable credential, then commit the NEW call configuration and reference in one JSON blob. Never mutate/delete the old committed credential. No rollback is needed. Failed final save preserves the old live pair and, when the write itself fails, the old disk pair; an interruption after a successful write can select only the new complete matching pair.
- Newly typed keys remain excluded from all config/journal text. Old and staged items remain recoverable; orphan staged-item cleanup is deferred. Stable profile UUID, selection and old snapshot/generation survive.
- A failed removal config commit now leaves the old pair active and reports failure. A committed removal selects a new reference containing `""`; stale legacy JSON cannot resurrect it. This supersedes the earlier in-place tombstone-on-failed-save behavior.
- Explicit references never fall back to legacy values, including when their selected Keychain item is missing. Migration retains the old backup/pending state rather than filling a missing immutable version from stale data. Explicit replacement/removal can repair a missing item; preserving a missing item fails recoverably. Older editors retain the latest committed reference.
- Backend spec §5 and A2 plan interfaces were updated with the ruling and its cost (deferred orphan cleanup). A4 must resolve `profile.validatedCredentialID()` or use `Configuration.cloudASRCredential(profileID:store:)`, rather than construct a fixed cloud ID itself. Store `snapshot` still gives the selected version's atomic value/generation.

## Tests and exact RED/GREEN evidence

Added scoped fixtures to `ASRCredentialSelfTests.swift` only:

- `testDraftCredentialTransactionRestartBoundaries`: interruption immediately after first staged persistence, credential failure while any rollback persistence would also fail, and verified credential followed by final config-save failure. Each decodes the actual disk blob, resolves actual endpoint/model/protocol/key through the production resolver, checks live/restarted pairing, then retries and restarts a successful commit. It also asserts stable UUID/selection, old credential snapshot/generation retention, distinct credential reference, and no serialized secret.
- `testCredentialReferenceNamespace`: rejects HF/service/other-profile/invalid suffix/explicit canonical references; selected valid-but-missing version cannot read stale legacy backup.
- Updated removal fixture: failed commit retains old key; successful tombstone commit survives restart with injected stale legacy JSON and preserves the old snapshot item.
- `testMissingVersionRepairAndStaleEditor`: migration does not resurrect missing version, explicit replacement repairs it, stale editor retains the repaired reference and key while its display edit commits.

First RED commands:

```
swift build > .superpowers/sdd/2026-11-09-asr-model-center/A2-fix1-red-build.log 2>&1
swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A2-fix1-red-backends.log 2>&1
```

Build exit 0, `Build complete! (33.69s)`. Runner exit 1, `=== ASR backend self-test: 373 passed, 35 failed ===`. Relevant output:

```
FAIL: interrupted save keeps original disk endpoint — got Optional("wss://changed.invalid/asr"), want Optional("https://original.invalid/v1")
FAIL: interrupted save keeps original disk model — got Optional("changed-model"), want Optional("original-model")
FAIL: interrupted save keeps original disk protocol — got Optional(...dashScopeRealtime), want Optional(...openAICompatible)
FAIL: restart resolves original endpoint after interruption
FAIL: interrupted save keeps matching original disk key
FAIL: old credential and generation survive for captured sessions
FAIL: foreign or malformed credential reference rejected
FAIL: failed removal preserves committed key on restart — got Optional(""), want Optional("fixture-remove")
```

These failures reproduce the review defect and missing namespace/version protection against the prior implementation. After immutable-reference implementation:

```
swift build > .superpowers/sdd/2026-11-09-asr-model-center/A2-fix1-green-build.log 2>&1
swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A2-fix1-green-backends.log 2>&1
```

Both exit 0: `Build complete! (52.79s)`, `=== ASR backend self-test: 410 passed, 0 failed ===`.

Narrow missing-version repair RED:

```
swift build > .superpowers/sdd/2026-11-09-asr-model-center/A2-fix1-repair-red-build.log 2>&1
swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A2-fix1-repair-red-backends.log 2>&1
```

Build exit 0 (`32.96s`); runner exit 1: `FAIL: missing-version repair fixture unexpectedly threw`; `=== ASR backend self-test: 413 passed, 1 failed ===`. Expected: preserve-only resolver rejection also rejected explicit replacement. The fix reads the selected version directly for explicit repair and refuses missing-value preserve without consulting legacy.

Final commands, sequential after all code edits:

```
swift build > .superpowers/sdd/2026-11-09-asr-model-center/A2-fix1-final-build.log 2>&1
swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A2-fix1-final-backends.log 2>&1
swift run --skip-build FlowType --self-test --m5-isolation-only > .superpowers/sdd/2026-11-09-asr-model-center/A2-fix1-final-isolation.log 2>&1
```

Results: build exit 0, `Build complete! (28.23s)`; backend exit 0, `=== ASR backend self-test: 417 passed, 0 failed ===`. Isolation result appended below.

## Changed files / self-review

Seven files: Configuration.swift, ConfigurationStore.swift, ASRCredentialStore.swift, ProviderDraftCommit.swift, ASRCredentialSelfTests.swift, backend spec, A2 backend plan.

Self-reviewed the exact write order, persistence verification, nil/empty handling, older editor reference preservation, namespace validation, missing-version migration and repair. Existing compatibility callers use the updated profile-aware resolver. No later adapter/routing implementation, dependency changes, full suite, real Keychain/user state, push, merge or child delegation. No open I1 correctness concern; deferred old/staged credential cleanup is the approved cost of retaining session/recovery references. Actual Keychain/manual UI verification remains Pending.

Final isolation exit 0: `=== M5 isolation self-test: 64 passed, 0 failed ===`. Final three logs contain no warning/error/FAIL lines; `git diff --check` is clean. Fix commit recorded in final response; post-commit worktree clean.

Fix round 1 commit: `43f7d68` — `fix: commit ASR profile and credential reference atomically`. Important I1 addressed; no push.
