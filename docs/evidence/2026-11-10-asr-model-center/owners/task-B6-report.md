# Task B6 implementation and evidence report

Status: DONE. Implementation complete; downstream assembly and real-model validation remain explicitly pending. Independent B6 and whole-B review belong to the controller.

## Source identity and scope

- Base: `df6adf3` (B5 fix1).
- Commit: `44f8172a46a766d2771522414b39187de401df92` — `feat: protect model ownership and integrate managed installations`.
- Git tree: `92a4c9f8856c9db457f26c3634d732e6357e8285`.
- 25 files changed; 1015 insertions, 149 deletions.
- Stable source was committed before the single full code gate; source-start and source-end both report clean. No tracked edits after that gate.
- Whole-B review range prepared by controller: `69691c0..44f8172`.
- No subagents, push, merge, dependency changes, Package.resolved changes, real model downloads, credentials, microphone, clipboard, or user configuration writes. Verification used synthetic files, injected runtimes/transports, and isolated temporary roots. Builds and tests ran sequentially.

## Implementation and public interfaces

### Usage and capture lifetime

`NativeModelUsageRegistry` provides `acquire(modelID: UUID) throws -> ModelUsageToken` and `reserveDeletion(modelID: UUID) throws -> ModelDeletionPermit`. Lock-protected atomic reservation makes acquisition and deletion mutually exclusive; reference tokens/permits release occupancy on deinitialization. IDs are imported model UUIDs, never job or installation UUIDs.

Capture occupancy is separately counted. `hasNoCapturedUsage(modelID:)` and `pendingDrains(modelID:)` supply lifecycle evidence. `registerExternalCapture(modelID:)` registers raw/no-token legacy sources explicitly as external-source usage; token `isExternalSource` describes the source without rewriting filesystem ownership.

Registry-owned drain keeper tasks retain the exact token, provider, and existing native drain closure until uncancellable native work completes. They start no native work. `NativeUsageProvider` returns cancellation promptly and transfers protection to this owned keeper. This replaces an unowned asynchronous tail. B5 trial validation still explicitly awaits the real drain before proceeding to the next candidate.

`LocalASRLease` gains optional `usageToken`, `retainingUsage(_:identity:)`, and `captured(externalModelID:)`. Re-retaining avoids nesting provider wrappers. A raw unresolved legacy source uses its immutable lease UUID as a stable external usage identity.

`ASRRouter` resolves the existing imported UUID for a raw lease from immutable identity/configured-directory association. Ambiguous aliases or mismatched identity fail binding safely. A raw capture that resolves to a managed imported UUID protects that exact model through capture and native drain; it does not grant or rewrite managed file ownership. Per-backend capture failure is retained. Controller-approved error generalization changes `ASRBackendCaptureFailure.error`, snapshot `captureError`, and local capture error maps to `any Error`; credential normalization remains unchanged. `NativeModelUsageError` classifies as `.configuration(.endpointOrModel)` and regressions verify native failure classification/destination.

### Guarded removal and durable detach

`ModelInstallationCoordinator.remove(modelID:deleteManagedFiles:)` reserves deletion before suspension, requires explicit deselection and absence of active/captured/native-tail usage, and parses native import role UUIDs including lowercase spellings. External file deletion is refused.

Managed removal durably marks the B4 journal `libraryDetached` before removing library records. Fresh disk journal validation prevents stale in-memory authority from overwriting corruption. Recovery is excluded during removal; detached recovery does not resurrect records. Configuration, ownership, and selection are rechecked before final synchronous persistence/deletion. Configuration and removal persistence are injectable; production uses the shared usage registry.

`ModelInstallationPublisher.validateRemoval` validates the exact managed layout and authentic immutable plan/manifest/import UUID association. The installed record path must equal the publisher destination. The imported descriptor may use the exact path or the exact canonical path produced by the B4 inspector, accommodating macOS `/var` versus `/private/var` without accepting arbitrary symlink equivalence as ownership.

Removal rejects symlink components/descendants, duplicate case aliases, forged manifest/journal associations, physical case-only owned child spelling mismatch, unplanned user-added files/directories, and special files. Expected plan payload corruption does not itself erase established ownership. Managed records must have nil `legacyPresetID`.

If filesystem deletion fails after durable detach and library persistence, the error propagates and remaining bytes stay detached; there is no rollback/resurrection. This is the transaction ordering, not an observed test failure.

### Removal callsite closure

- Qwen synchronous external-record removal returns Bool and refuses active, selected, in-use, or managed rows.
- `removeModelRecord(id:deleteManagedFiles: Bool = false)` dispatches managed removal through an injected `(UUID, Bool) async throws` closure.
- Only production shared-state construction wires the real shared installer. Injected states default to refusal, preventing fixture mutation of global stores.
- `ImportedASRModelActions` dispatches to the correct owner.
- `ModelRecoveryActions.removeFolderOverride` explicitly clears folder/native selection while retaining library/installed rows, files, and runtime; it no longer bypasses guarded removal.
- `ModelDownloader.deleteModel` is async, resolves a unique managed recipe record, and supplies its imported UUID to the guarded coordinator. External and ambiguous matches fail.
- `LocalModelPicker` awaits deletion and shows the actual localized error.

### Preset acquisition and activation

Production default preset acquisition delegates B4 through `acquire(preset:source:progress:)`: resolve pinned recipe metadata/plan, enqueue the installer, await its queue, and drain on cancellation. Acquisition alone does not select a model.

Strict static inspection and both memory-admission checks precede allocation. The factory's final reinspection and final authorization callback remain intact. Existing legacy directories are reused without downloading. Actual new managed installations activate with `native:import` identity; legacy `native:preset` identity is preserved without background role rewriting. Recipe `verified` flags remain false.

`ModelDownloader` owns no task. It observes Qwen operation/status and calls synchronous `Qwen.start(request)`. Qwen retains the sole operation and active lease; its owned Task returns an operation-local Result, preserving B5 completion ownership.

The controller approved a narrow explicit injected `load` seam for historical retry assertions. Production has no callsite passing this seam and no legacy combined downloader implementation; the default loader throws, while production uses B4/factory. The former production convenience `loadDownloadedPreset` was removed; its isolated stub equivalent lives only in `NativeActivationFixtures.legacyState`.

### Legacy association schema

Controller-approved additive `ASRInstalledModelRecord.legacyPresetID: String? = nil` decodes missing old JSON as nil. It stores only an actually validated legacy preset lease ID for external adoption (including the actual 0.6B fallback, never a guessed recommendation). Selection guards use this exact association, avoiding same-family false positives.

External relocation updates directory and clears stale association in the same activation transaction. Managed relocation outside the owned directory is rejected. Record/import IDs remain stable. The HF design specification documents this field and meaning.

## TDD and diagnostic evidence

All named logs below are under `.superpowers/sdd/2026-11-09-asr-model-center/`. Behavioral focused commands used `.build/debug/FlowType --self-test --hf-install-only`, except explicitly named native/provision/inspection suites. Build commands were `swift build` with output redirected to the named build log. RED/GREEN pairs below describe actual observed failures and corrections; intermediate compiler mistakes are distinguished from intentional RED.

| Evidence | Observed result and significance |
| --- | --- |
| `B6-red-build.log` | Exit 1: registry/token/removal-injection APIs absent, expected API RED before implementation. |
| `B6-api-build.log`, `B6-api2-build.log`, `B6-assembly-build.log` | Implementation compile corrections: nonexistent `.secondary` changed to `.fallback`; candidate redeclaration; actor-isolated default argument replaced with production handler static method. These are not behavioral RED claims. |
| `B6-behavior-focused.log` | 675 passed, 3 failed: valid managed deletion rejected. |
| `B6-path-focused.log` | 676 passed, 5 failed: diagnostic comparisons isolated `/private/var` versus `/var` descriptor representations. |
| `B6-deletefix-focused.log` | 683 passed, 0 failed after constrained inspector-canonical descriptor handling and disk-journal protection. |
| `B6-managed-red-focused.log` | 700 passed, 10 failed: real injected B4 acquisition through default preset split rejected model/record URL representation, yielding zero allocation/trial. |
| `B6-managed-green-focused.log` | 710 passed, 0 failed after association comparison correction; deletion retains exact ownership rules. |
| `B6-cancel-red-focused.log` | 710 passed, 1 failed: “B6 cancelled native caller returns before compute drains”. |
| `B6-cancel-green-focused.log` | 713 passed, 0 failed after registry-owned keeper preserves occupancy while returning cancellation promptly. |
| `B6-native-focused.log` | 955 passed, 2 failed in `--native-client-only`: same-family preset selection guard wrongly blocked unrelated Qwen rows. |
| `B6-native2-focused.log` | 960 passed, 0 failed after exact optional legacy association. |
| `B6-provision-focused.log` | 184 passed, 8 failed in `--model-provision-only`: old load-only startup fixtures lacked B5 validation history. |
| `B6-provision2-focused.log` | 192 passed, 0 failed after fixture migration. Five explicit startup no-history/no-download assertions subsequently bring final suite to 197/0. |
| `B6-inspection-focused.log` | 40 passed, 3 failed in `--m2-review-inspection-only`: old blocking inspector also blocked initial preset validation. |
| `B6-inspection2-focused.log` | 43 passed, 0 failed after distinct synthetic old descriptor/inspection; cancellation and heartbeat assertions retained. |
| `B6-alias-red-focused.log` | 722 passed, 3 failed: unplanned user-added file was deleted. |
| `B6-final-focused.log` | 725 passed, 0 failed after owned-directory inventory guard. |
| `B6-facade-red-build.log` | Expected missing two-argument removal closure API. |
| `B6-freeze-focused.log` | 731 passed, 0 failed after facade integration. |
| `B6-raw-red-focused.log` | 732 passed, 2 failed: raw capture token had nil model ID and managed deletion succeeded while raw capture remained alive after deselection. |
| `B6-stable-hf.log` | 745 passed, 0 failed after capture-boundary identity resolution, native cancellation/drain, ambiguity classification, and stable external identity regressions. |
| `B6-identity-red-focused.log` | 745 passed, 3 failed: lowercase selected import UUID bypassed deselection guard and removed record/files. |
| `B6-precommit-hf-install-only.log` | 748 passed, 0 failed after UUID parsing guard. |

### Fixture migrations and assertion preservation

Controller-approved fixture migration supplies required sample/provider/inspection/persistence seams or matching synthetic startup validation history; no production validation bypass was introduced.

- Active-row immediate removal now asserts refusal and preserved selection/runtime/files. Existing survival assertions remain; success is exercised only after explicit deselection/unload/capture drain.
- Historical bootstrap network-fallback expectations run through explicit retry. New preceding startup assertions prove zero allocations/downloads without validated history. Startup-only fixtures receive matching synthetic history.
- Folder-override recovery asserts both library and installed records remain.
- Old blocking inspection fixtures distinguish the synthetic initial preset from the later model under test, preserving concurrency/cancellation assertions.
- Native preset selection uses exact validated association rather than family-wide refusal.
- Added `--model-provision-only` selector exposes existing preflight/coordinator/terminal tests and is in RuntimeEnvironment's self-test allowlist. All those tests remain on the full runner; controller authorized the selector.

## Final verification on stable implementation

Final precommit `swift build` exited 0 (`B6-precommit-build.log`, `Build complete! (32.14s)`), with no warnings/errors. Focused suites then ran sequentially with `.build/debug/FlowType --self-test --<filter>`:

| Filter | Passed | Failed | Log |
| --- | ---: | ---: | --- |
| hf-install-only | 748 | 0 | B6-precommit-hf-install-only.log |
| model-provision-only | 197 | 0 | B6-precommit-model-provision-only.log |
| native-client-only | 960 | 0 | B6-precommit-native-client-only.log |
| m3-asr-regression-only | 294 | 0 | B6-precommit-m3-asr-regression-only.log |
| asr-backends-only | 1084 | 0 | B6-precommit-asr-backends-only.log |
| m4-recovery-only | 19793 | 0 | B6-precommit-m4-recovery-only.log |
| m5-runtime-only | 118 | 0 | B6-precommit-m5-runtime-only.log |
| m5-isolation-only | 64 | 0 | B6-precommit-m5-isolation-only.log |
| m2-review-packages-only | 34 | 0 | B6-precommit-m2-review-packages-only.log |

Earlier required focused evidence: `B6-m2-focused.log` is M2 fix 276/0; `B6-inspection2-focused.log` is M2 inspection 43/0. The stable-source full gate below covers all tests.

Exactly one full code gate ran after committing stable source:

```sh
scripts/verify.sh --lane code > .superpowers/sdd/2026-11-09-asr-model-center/B6-code-gate.log 2>&1
```

Exit 0; `Verification code: Pass`. Report: `build/verification/DEE3EC33-550E-4DED-9DC7-63EE0C66A7E6/verify-report.json`.

All seven phases Pass: source-start, platform-os, platform-arch, platform-swift, code-build, code-full, source-end. Report source identity is SHA `44f8172a46a766d2771522414b39187de401df92`, tree `92a4c9f8856c9db457f26c3634d732e6357e8285`, dirty false.

Full self-test child: `7580A5E4-6C1F-4858-9940-4E56C7AFB2B5` under the run's `children/` directory. Output: `=== self-test: 27755 passed, 0 failed ===`. Full stderr is empty. Controller independently verified the report and source identity.

| Artifact (relative to run directory) | Bytes | SHA256 |
| --- | ---: | --- |
| verify-report.json | 5493 | `597e7c6bd643c6e3928361f9a3ffe1e324bf8b4b64e604672cd1a5f7dd31ee76` |
| children/7580A5E4-6C1F-4858-9940-4E56C7AFB2B5/stdout | 3970 | `67a4ee8856294fb0aea2f638cb8b5d85c6929df74fca34b1aae2a88456433db2` |
| children/7580A5E4-6C1F-4858-9940-4E56C7AFB2B5/stderr | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

`manualStatus` and `ciStatus` remain Pending; `artifactIdentity` is null. Artifact/release, manual, real native model, service, microphone, signing, and remote CI checks are not claimed Pass.

## Self-review findings and dispositions

The completed self-review examined ownership boundaries, raw capture lifetime, cancellation tails, removal callsites, startup migration, preset acquisition/allocation ordering, and fixture isolation. Findings were fixed before the stable commit: canonical descriptor mismatch, family-wide selection false positives, user-added-file deletion, raw lease protection omission, and lowercase selected UUID bypass. RED/GREEN evidence above records each material correction.

Preserved B5's final factory authority/hardware callback and second inspection. Verified the default preset route reaches B4 acquisition and B5 validation with synthetic integration fixtures. No legacy production combined download/allocation path remains. No global installer is invoked from default injected test states. No unowned native drain task remains. Usage retention and deletion use imported UUID identity consistently.

QwenModelState and existing self-test files are already large; edits stayed in existing orchestration boundaries. This task did not perform an unrelated restructuring. No remaining known B6 correctness failure is asserted; independent review is pending.

## Required downstream handoffs

1. **C2/C4 validation sample:** supply the actual validation sample to production Qwen composition. `sampleProvider` still defaults to validationRequired, so fixtures do not imply production sample wiring is complete.
2. **C4 recording/unload:** wire actual live-recording permission. `canUnload` defaults false. Qwen combines the injected permission with registry capture/drain evidence within its existing unique lifecycle gate. There is no automatic unload.
3. **C UI removal:** use `removeModelRecord(id:deleteManagedFiles:)`/guarded installer removal and await localized errors. Explicit deselection plus complete capture/native drain is required; never use direct filesystem deletion for installed models.
4. **Legacy schema:** preserve optional `legacyPresetID` and only record validated external legacy association. Never infer ownership or rewrite backend identity from family/preset guesswork.
5. **D real-model matrix:** actual Qwen/Whisper payloads and native execution remain unverified; recipes stay `verified = false`. Artifact/release/manual/remote CI remain pending until their own evidence exists.
6. **Controller review:** dispatch fresh B6 review, then whole-B review over `69691c0..44f8172`, emphasizing durable deletion, recovery, capture/drain ownership, preset acquisition/validation, and tokenizer completeness. No child reviewer was spawned.

## Changed files

```text
Sources/flowtype/App/RuntimeEnvironment.swift
Sources/flowtype/Core/Recovery/FailureClassifier.swift
Sources/flowtype/Services/Speech/ASRRouter.swift
Sources/flowtype/Services/Speech/LocalModelManager/LocalASRRuntimeFactory.swift
Sources/flowtype/Services/Speech/LocalModelManager/LocalModelLibrary.swift
Sources/flowtype/Services/Speech/LocalModelManager/ModelDownloader.swift
Sources/flowtype/Services/Speech/ModelInstallation/ASRInstalledModelRecord.swift
Sources/flowtype/Services/Speech/ModelInstallation/ModelInstallationCoordinator.swift
Sources/flowtype/Services/Speech/ModelInstallation/ModelInstallationPublisher.swift
Sources/flowtype/Services/Speech/ModelInstallation/NativeModelUsageRegistry.swift
Sources/flowtype/Services/Speech/ModelProvisioning/LocalASRLease.swift
Sources/flowtype/Services/Speech/ModelProvisioning/ModelRecoveryActions.swift
Sources/flowtype/Services/Speech/QwenModelState.swift
Sources/flowtype/Settings/ImportedASRModelActions.swift
Sources/flowtype/Settings/LocalModelPicker.swift
Sources/flowtype/Testing/HFInstallTransactionSelfTests.swift
Sources/flowtype/Testing/ImportedLifecycleSelfTests.swift
Sources/flowtype/Testing/ImportedModelUISelfTests.swift
Sources/flowtype/Testing/LocalSettingsOwnershipSelfTests.swift
Sources/flowtype/Testing/M2ReviewFixSelfTests.swift
Sources/flowtype/Testing/ModelProvisionSelfTests.swift
Sources/flowtype/Testing/NativeActivationSelfTests.swift
Sources/flowtype/Testing/NativeModelPresentationSelfTests.swift
Sources/flowtype/Testing/SelfTest.swift
docs/superpowers/specs/2026-11-09-hf-model-installation-design.md
```


## Whole-B review fix I1 — round 1 of 5

Reviewed base: `44f8172`. B6 itself was approved; whole-B review found inherited B2 → B4 directory-spelling inconsistency. The previous planner accepted `AudioEncoder.mlmodelc/weights/one.bin` plus `AudioEncoder.mlmodelc/Weights/two.bin`; default case-insensitive macOS coalesced the directory and strict publication rejected the completed payload. The full review was read before this fix.

### Change and contract

`ASRInstallPlanner.validateFilePaths` now records the original spelling of every normalized directory prefix. Different spellings under the existing case-folded, canonically normalized key throw `ASRInstallPlanningError.destinationCollision` before any payload transfer. Existing callers apply the rule both to each source manifest and to the final combined destination paths. File/file and file/ancestor collision checks, metadata budgets, closure selection, and graph resource paths remain intact.

Original spellings compare using Swift String equality, matching the publisher/removal `Set<String>` inventory contract. Therefore case and folding variants (`weights`/`Weights`, `straße`/`STRASSE`, `Café`/`CAFE\u{301}`) reject; canonically equivalent NFC/NFD forms (`Café`/`Cafe\u{301}`) remain allowed. Controller explicitly approved this Unicode rule. No resource remapping, installer refactor, or relaxation of publisher/deletion ownership checks occurred. The API comment and HF design layout paragraph document the contract.

### Regression coverage

- Planner tests replace the old case-alias success with rejection and preserve exact-spelling distinct-sibling success.
- Both enumeration orders cover case-alias siblings, differing outer/nested parent spellings, Unicode case folding and normalization combined with case differences. Existing file/ancestor and normalized filename collisions remain covered.
- Destination validation covers aliases across individually safe source mappings, including nested destination parents.
- New `testPlannerDirectorySpellingPublication` runs eight layouts in both repository enumeration orders. It composes the real planner, real installation coordinator, real static inspector/publisher/journals/hash verification/registration, and synthetic byte transport under temporary roots.
- Ambiguous layouts assert the planning error, zero transport calls, zero jobs, no installed rows, and no published root.
- Exact directory siblings, exact nested siblings, and NFC/NFD equivalents each complete real publication; assertions check installed state, exact transfer count, installed/imported registration, unchanged plan, sibling bytes, and strict removal inventory validation. Synthetic MIL references retain original resource paths.

### Exact sequential RED/GREEN evidence

All logs remain in this ignored task workspace. No source edits occurred during build/test processes.

1. `swift build > .../B6-I1-red-build.log 2>&1` exited 1 due to test-harness compile mistakes (nonexistent `waitUntilIdle` and extra `record:` label). These were corrected before the behavioral RED; not counted as intentional regression evidence.
2. `swift build > .../B6-I1-red2-build.log 2>&1` exited 0, compiling the new tests against the unchanged planner.
3. `.build/debug/FlowType --self-test --hf-install-only > .../B6-I1-red-focused.log 2>&1` exited 1: **822 passed, 54 failed**. Failures include alias layouts being accepted and `rejected before any transfer — got 13, want 0`, plus installed-job/published-root assertions. Valid exact and canonically equivalent publication cases passed. This reproduced the missing pre-download boundary through the real installer, rather than only asserting a helper's output.
4. Added the directory-prefix spelling guard and documentation.
5. `swift build > .../B6-I1-green-build.log 2>&1` exited 0: `Build complete! (28.87s)`. No warnings/errors.
6. `.build/debug/FlowType --self-test --hf-install-only > .../B6-I1-green-focused.log 2>&1` exited 0: **866 passed, 0 failed**. Output contains only the standard heading and summary. The RED/GREEN assertion counts differ because rejected plans no longer enter the installer-completion branch.
7. `git diff --check` passed. Consolidated self-review checked the entire four-file diff, source and destination callsites, order independence, Unicode equality compatibility with exact publication/removal inventory, graph resource preservation, and synthetic test isolation; no additional unresolved issue found.

Only four tracked files changed: `ASRInstallPlanner.swift`, `HFInstallPlannerSelfTests.swift`, `HFInstallTransactionSelfTests.swift`, and the HF installation design specification. Static inspection and packages implementations are unchanged, and HF already exercises their real integration here; no extra inspection/package suite was needed. No full gate was repeated, per controller instruction. The prior 27,755/0 full gate remains evidence for exact `44f8172` only, not this fix; later C/D gates cover the new head. Downstream sample/unload wiring, real-model matrix, artifact/release/manual/remote CI remain pending as previously stated. Fresh scoped review of `44f8172..fixHEAD` belongs to the controller.

Fix commit: `dfd799143f010ce9efd41d9905984baaf0580f21` — `fix: reject conflicting model directory spellings before download`. Tree: `b641605f07c88cb9d54f42948fa587c0b9648630`. Working tree clean after explicit four-file commit.
