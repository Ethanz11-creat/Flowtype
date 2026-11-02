# M2 independent-review fixes — worker report

Date: 2026-11-02. Base: `9fa57bf`. Source commit: `e69d6889e5211ffb1a35572eda8030609a313e30`. Git tree: `b924c0a1e7ffc173e247b35d2f140a62076190d7`.
Scope: both approved P2 findings; no format reduction, dependency change, user configuration/key/audio/model/cache manipulation, network/model downloads, GUI/relaunch/release build, push/merge/reset, or delegated review. Controller owns independent review and durable evidence/audit updates.

## Root-cause evidence and hypotheses

Read authoritative `brief.md`, approved local-import spec, and `/tmp/flowtype-m2-independent-review-20261102/independent-review.md`; copied the latter to `root-cause-review.md` here. Followed systematic-debugging (trace → pattern → behavioral hypothesis → fix), test-driven-development plus writing-good-tests, and verification-before-completion.

1. Pinned WhisperKit `ModelUtilities.detectModelURL` chooses either `Name.mlmodelc` or fixed `Name.mlpackage/Data/com.apple.CoreML/model.mlmodel`; the pinned model loader directly loads the returned URL. Hypothesis: passing an accepted package directory unchanged yields an uncompiled source URL for conventional roots and nonexistent compiled URLs for alternate Manifest roots. The RED exercised that actual pinned resolver against complete package/resource fixtures through an initially pass-through preparation scaffold; the scaffold added the desired seam but did not change runtime behavior. No compilation fix existed before this behavioral RED.
2. `QwenModelState` is MainActor-isolated; its synchronous default inspector was called directly both during provisioning and before legacy provisioning ownership. Hypothesis: a blocking synchronous inspector prevents MainActor heartbeat/cancel and may reach loading before cancellation runs. The RED exercised the real coordinator with a blocking synchronous worker (not an already-async injected loader), with a bounded watchdog to avoid deadlocking the test. No inspection production fix existed before this behavioral RED.

## Production integration

### Whole-package preparation

- New `WhisperModelPreparation.prepare(directory:compile:)` explicitly detaches synchronous filesystem/compiler work and awaits its actual completion. Cancellation forwards to the worker, checks between components and after completion, and never releases the surrounding coordinator/gate early.
- Native default passes the entire `.mlpackage` to `MLModel.compileModel(at:)`, preserving Manifest and external resource resolution. The returned compiled directory is moved to a uniquely created app-owned runtime root under the system temporary directory; only those generated outputs are cleaned.
- Required components and optional prefill receive the conventional compiled names the pinned resolver consumes. Mixed compiled/source imports link existing compiled components into the generated directory without copying weights. Fully compiled imports preserve the original directory and bypass compiler/staging work. Ambiguous/missing components fail safely.
- `PreparedWhisperModels` is an immutable Sendable resource owner. Failure/cancel drops partial preparation and removes only its owned root. `WhisperKitBackend` stores the owner for its lifetime; active/captured leases retain provider/backend, and the existing inference queue captures the backend for uncancellable in-flight work. The owner therefore survives both retained leases and active inference. Existing user source/compiled paths are never owned/deleted.
- `WhisperKitBackend.load` validates the original local tokenizer, prepares models, gives the actual prepared directory to `OfflineWhisperKit`, and retains the preparation with the returned backend. Original explicit tokenizer URL, offline options, graph admission, graph-derived identity and provider's original import identity/path are preserved.

### Off-main inspection with one lifecycle

- New `LocalModelInspection.inspect(directory:using:)` explicitly detaches the synchronous inspector and drains it before returning cancellation. Both coordinator inspection and runtime-factory fresh-fingerprint reinspection use it; expensive production inspection cannot inherit MainActor.
- New `ModelProvisionTarget.uninspectedDirectory(URL)` represents legacy/folder intent without guessing model identity. `importOfflineModel` enters the existing `perform` reservation before the first long await, then the same global gate, inspection, assessment, runtime and success-only latest-configuration commit. There is no separate initial lifecycle or second initial inspection.
- Ownership/cancellation is checked immediately after inspection, before publishing assessment or starting a runtime. Canonical UUID/name handling for existing imports remains. Invalid unresolved directories retain offline recovery intent and incomplete-local reporting. Settings path presentation handles the unresolved target; exhaustive test loader switches reject unresolved targets that should never reach them.

## Behavioral verification and exact commands

All paths below are relative to `.superpowers/sdd/2026-11-02-m2-review-fixes/`. Commands ran from the repository root. No `swift test` was run.

| Phase | Command | Log | Exit and result |
| --- | --- | --- | --- |
| Package behavioral RED | `swift run FlowType --self-test --m2-review-packages-only` | `package-red.log` | **1**; 6 passed / 6 failed. Conventional source resolved to `.mlmodel`; alternate source/prefill compiled paths absent; no separate owned runtime. |
| Package initial GREEN | same | `package-green.log` | **0**; 12 passed / 0 failed. |
| Package expanded GREEN | same | `package-extended-green.log` | **0**; 24 passed / 0 failed. |
| Package + real coordinator compile-lifecycle GREEN | same | `package-lifecycle-green.log` | **0**; 34 passed / 0 failed. |
| Inspection behavioral RED | `swift run FlowType --self-test --m2-review-inspection-only` | `inspection-red.log` | **1**; 29 passed / 6 failed. All four entry paths blocked heartbeat; selection/startup reached runtime before cancellation. |
| Inspection initial GREEN | same | `inspection-green.log` | **0**; 35 passed / 0 failed. |
| Inspection expanded global-gate GREEN | same | `inspection-extended-green.log` | **0**; 43 passed / 0 failed. |
| Final build, followed sequentially by full self-test | `swift build` | `final-build.log`, `final-build.exit` | **0**, 20.68 s. |
| Final full suite | `swift run FlowType --self-test` | `final-self-test.log`, `final-self-test.exit` | **0**; **2507 passed / 0 failed**. |

Expanded package tests use real preparation/path resolution and replace only expensive native compilation with a synchronous compiler seam. The seam requires a whole package, reads its Manifest-selected root and external resource, and rejects MainThread execution; loaded paths are verified with the pinned resolver as existing compiled component directories. Coverage includes conventional/alternate roots, mixed compiled input, optional prefill, fully compiled bypass, retained owner lifetime, partial failure, cancellation with uncancellable work and source preservation. A real coordinator + blocked compiler additionally verifies responsive cancellation, reservation/global-gate retention until drain, no late candidate/configuration commit, and old lease preservation.

Expanded inspection tests cover selection, imported startup, direct legacy import and legacy configured retry with the real coordinator and a blocked synchronous inspector. Assertions cover MainActor heartbeat, operation reservation, same-coordinator rejection, another coordinator waiting behind the global gate, cancellation/drain, no late load/save, previous config/lease preservation and retained previous-provider usability. Existing broad lifecycle, graph, tokenizer, routing and offline-failure cases remain in the full suite.

Test setup corrections: the first inspection test compile omitted a required hardware-assessment argument; corrected before obtaining the behavioral RED. Adding a MainActor lifecycle check ahead of existing nonisolated tests triggered Swift's non-Sendable Reporter transfer diagnostics; moved that check beside existing MainActor tests without changing Reporter or production isolation. Those compiler failures are not counted as behavioral RED evidence.

## Actual native compiler/load smoke

Scratch source `native-smoke.swift` uses only installed CreateML/CoreML SDK APIs to train an eight-row synthetic linear regressor and export a tiny valid `.mlmodel`. It packages that model under conventional and alternate Manifest roots for the three required component names plus prefill. It compiles **the exact product preparation source**, calls its default native compiler, then calls `MLModel.load` on each generated `.mlmodelc`, performs CPU-only prediction (x=3 → y≈7), and verifies generated cleanup/original-source preservation.

Commands:

```sh
swiftc -swift-version 6 -parse-as-library Sources/flowtype/Services/Speech/WhisperModelPreparation.swift .superpowers/sdd/2026-11-02-m2-review-fixes/native-smoke.swift -o .superpowers/sdd/2026-11-02-m2-review-fixes/native-smoke
.superpowers/sdd/2026-11-02-m2-review-fixes/native-smoke /Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-02-m2-review-fixes/native-fixture-v2
```

Compiler log `native-smoke-build.log`: exit **0**; scratch-only deprecated CreateML MLDataTable/initializer warnings. Runtime `native-smoke.log`: exit **0**, all four native compile/load/prediction checks plus cleanup passed. Only the app error type is stubbed to compile the product preparer standalone; no preparation/compiler behavior is mocked. First scratch Manifest omitted Core ML's required entry `description`, causing a native invalid-itemInfo rejection and top-level thrown-error exit **133** (`native-smoke-invalid-fixture.log`). The fixture was corrected, not the product's compiler/admission behavior. The first scratch compilation also required `await` on the SDK prediction overload; corrected before native execution.

Limits: the tiny model has no Whisper graph, speech, KV cache or external trained-weight payload. Native smoke establishes whole-package compilation including alternate roots and compiled-load execution, not Whisper inference or external-weight semantics. Synthetic package tests establish the intact external-resource seam. Actual full Whisper/Qwen variant inference, GUI and V1–V5 acceptance remain **Pending**. No dependencies installed and no model downloaded. Scratch inputs/binaries retained for controller archive.

## Self-review and remaining work

- Checked `git diff --check`, all changed production branches, compiler cancellation/failure ownership, original tokenizer/path identity, prefill/mixed/compiled behavior, and the actor/lease/inference retention chain.
- Confirmed both live production coordinator call sites and runtime-factory reinspection use explicit detached synchronous work; unchanged legacy inspection utilities have no production callers in these entry paths.
- Checked all new target switches and recovery retry handling; unresolved intent stays offline and cannot reach the runtime loader uninspected.
- No architecture conversion, unsupported source format rejection, fallback to the original source directory at runtime, network fallback, or user/cache deletion added.
- Existing `AppLogger.swift:27` unnecessary `nonisolated(unsafe)` warning appeared during incremental source compilations; it is outside this scope. Final cached build output has no new source warnings.
- Controller must perform independent scoped review and stable bundle build; worker did not self-approve independent review or real-environment acceptance.

## Final result / commit

**DONE — both approved P2 fixes implemented and verified; independent review still belongs to the controller.**

- Final sequential `swift build` exit **0**; full `swift run FlowType --self-test` exit **0**, **2507 passed / 0 failed**. No final full-suite rerun of unchanged source.
- Source/tests commit: `e69d6889e5211ffb1a35572eda8030609a313e30` — `fix: prepare Whisper packages and inspect imports off main actor` (11 files; no controller documentation staged).
- Commit tree SHA: `b924c0a1e7ffc173e247b35d2f140a62076190d7`. Production/test files were unchanged between the final test run and commit.
- Post-commit working-tree changes are exclusively the controller's evidence/audit documentation; `.superpowers` report/logs/scratch remain ignored for its archive.
- No remaining known source blocker found in this worker's scoped self-review. Actual Whisper/model variants, GUI and V1–V5 remain Pending; native tiny-model success does not change those statuses.
