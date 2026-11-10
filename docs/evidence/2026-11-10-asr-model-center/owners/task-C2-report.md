# C2 — acquisition drafts and explicit validation samples

Status: DONE (commit appended at closeout). Base: `d156b82167a502493f03c1353e64c05beff44d13`. Implemented the approved plan inline using the executing-plans skill; no nested agents or independent reviewer were spawned. Controller owns independent review. No app assembly / full model-center host redesign (C3/C4), dependency changes, real user configuration/Keychain/model paths, microphone, clipboard, permissions, real network/weights, model/service installation, signing, push or merge. Build/tests ran sequentially with no tracked edits while a build/test was running.

## Delivered

- `ASRAcquisitionEntry` exposes the five stable destinations and Chinese titles: recommended, huggingFace, directory, localService, cloudService. Existing pinned `ASRModelRecipes.all` feed recommendation drafts, with resource tradeoff copy and honest unverified-candidate labels. Recommendation and arbitrary HF acquisition share `HFModelInstallSession` / `HFModelInstallSheet`.
- HF session composes actual B1 client resolution, B2 planner and B4 enqueue. It owns metadata previews only, not a downloader/runtime. Free-form repo/official URL, explicit revision (including tree/blob ambiguity), variant/subdirectory, tokenizer repo/revision, source and explicit stored-token use are collected. Conventional top-level Core ML variant parents are offered as buttons; free-form paths remain supported by B2. A current successful preview displays each source's frozen commit, captured endpoint, license link or honest unknown-license notice, exact byte/file total, native-engine scope and remaining checks. Preview never enqueues. Only explicit confirmation enqueues, with one-at-a-time admission and duplicate-confirmation suppression. Changed fields invalidate preview, and stale metadata errors/results do not overwrite edited input. B4 owns the durable job after sheet closure. Failures retain inputs/preview/job.
- HF tokens are supplied through a separate injected credential-save closure, not in input/plan/journal values. The production session uses the injected ASR credential store and only the `asr.hf.official` reference. Official repository authorization opens through an explicit browser link. Mirror/custom sources remain anonymous under B1. Errors show fixed safe guidance rather than arbitrary thrown/token/server text.
- Added `LocalASRServiceDraft`, its UUID/revision-checked merge, dirty-draft/navigation session and protocol-aware sheet. OpenAI-style requires a manual/discovered model; whisper.cpp has no model field and never invents a model switch. MLX/WhisperKit presets request JSON. Preset application is explicit and preserves address/key. Explicit candidate discovery uses A5's existing client and clears stale displayed lists on edit/close; it sends no audio and grants no recognition readiness. Configuration checks remain local only. Fixed official reference commits for MLX Audio `5dbe43b`, WhisperKit 0.18.0 `e2adabb`, and whisper.cpp `f92e1e4` match the existing research. The app does not install/start/update servers.
- Added `ConfigurationStore.saveLocalASRServiceDraft`: stage a fresh immutable credential reference, read it back, then durably publish the profile/reference/revision together. Credentials never enter serialized profiles. Key failure or config persistence failure leaves the old committed endpoint/key/selection usable and the caller's draft intact. Removal changes authentication to none without deleting keys potentially captured by in-flight recordings. Existing profile revisions are checked before writes; no selection or validation is created by save.
- Directory acquisition adds `ImportedASRModelActions.savePreview(persist:) -> ASRBackendID`. It consumes the existing strict inspector/hardware preview, persists only a new external candidate, returns stable identity, never copies weights, and never loads/tests/selects. Every already-existing record remains immutable through this add-only path: same-directory/engine canonical identity returns its existing UUID without saving, while relocation conflicts are rejected. Newer edits/fingerprints, active/selected/captured/managed records cannot be overwritten by stale previews. Save failure retains the preview. Relocation continues to require the existing guarded B5 path.
- Added bundled `en.wav` and `zh.wav`, resource declaration, bounded/checksummed RIFF PCM decoder, canonical Float32 conversion, and `ASRValidationSampleStore.load(language:)`. Both WAVs are signed 16-bit 16000 Hz mono and below eight seconds: en 48,727 frames / 3.0454375 s; zh 55,377 frames / 3.4610625 s. `auto` uses Chinese. File SHA256 is checked before parsing, then `ASRValidationSample` computes its separate canonical Float32 hash. No capture/network/permissions/user-state API is used.
- `ASRValidationDisclosure` / `ASRValidationNotice` provide the destination, selected bundled sample, explicit upload action, credentials, potential cloud/service costs and exclusion of microphone/context/dictionary/clipboard BEFORE service/cloud Test or select-with-test. Nonempty output only establishes runtime/connectivity availability; ephemeral output remains C1's `lastTrialResult` for human quality judgment.

## Controller rulings and precise C3 / C4 handoff

### Save-first service/cloud drafts

The controller approved save-first to avoid a second draft recognition owner. Actual cloud editor UI no longer invokes its legacy silence-based draft Test; its old session/check domain implementation and meaningful regressions remain compatible. The local sheet also has no draft recognition action. This adds one explicit Save interaction: save unverified profile, locate its stable backend, read destination/sample/cost notice, then explicitly Test / select through the one C1 VM. The experience spec's service/cloud acquisition paragraphs now say this explicitly. Successful save alone does not select, validate, or mark ready.

C3 must route both new and edited cloud sheet commits to `try store.saveModelCenterASRDraft(draft)` (the existing CloudASRProviderList save callback now does). This narrow wrapper shares the existing private credential transaction; the legacy `saveASRDraft` and pure ProviderDraftCommit semantics remain compatible for existing domain callers. The new wrapper freezes `ASRBackendMigration.selection(from: current)` into the candidate, marks a new cloud profile inactive, and preserves `pendingLegacyNativeResolution` by direct value assignment. It does not call the explicit-selection setter, which would retire unresolved native intent. Tests cover no-cloud first save, nil versus existing/explicitly cleared selections, pending native migration, later native resolution, and failure atomicity. C4 must remove/delegate all legacy UI auto-selection paths when assembling the new host; the existing legacy list's activation actions are not a new validation path supplied by C2.

Exact views/actions available:

```swift
HFModelInstallSession(credentialStore: store.asrCredentials, installer: applicationInstaller)
HFModelInstallSession(resolve: ..., plan: ..., enqueue: ...) // injectable fixture/composition seam
session.input: HFModelInstallInput // repository, revision, variant, tokenizerRepository,
                                  // tokenizerRevision, source, usesStoredToken
session.useRecipe(recipe)
await session.preparePreview()
await session.confirmInstall()
session.preview / variants / message / isWorking / jobID
HFModelInstallSheet(session: session, saveToken: { try store.asrCredentials.write($0, id: "asr.hf.official") }, onClose: ...)

LocalASRServiceDraft(target: .new(id) /* or .existing(id) */, profile: profile, keyEdit: ...)
LocalASRServiceEditSheet(draft: draft, discovery: applicationDiscovery,
    navigation: navigation, storedCredential: { /* value for current profile auth ref */ },
    onSave: { try store.saveLocalASRServiceDraft($0); /* refresh VM, locate backend, close */ }, onCancel: ...)
try store.saveLocalASRServiceDraft(draft)
try store.saveModelCenterASRDraft(cloudDraft)

await importedActions.stage(directory: selectedDirectory)?.value
let id = try importedActions.savePreview(persist: { try store.commitNativeASRActivation($0) })
// no copy; refresh VM, set selectedID=id, then user explicitly tests/selects.

try ASRValidationSampleStore.load(language: store.current.asrLanguage)
ASRValidationDisclosure(destination: actualValidatedEndpoint, language: language, isCloud: location == .cloud)
ASRValidationNotice(disclosure: disclosure)
```

C3 owns the five acquisition buttons, recommendation picker, directory NSOpenPanel/format/hardware preview and add-only button, saved-profile selection, full errors, output display and complete window/keyboard/accessibility verification. On successful save use `service:<draft.target.id.uuidString>` or `cloud:<draft.target.id.uuidString>`, `vm.refresh()`, and `vm.selectedID = backendID`; this is browsing only. Preserve C1 `lastTrialResult` display for explicit quality judgment. Do not automatically Test after save.

Every actual Test / primary / fallback action must use the shared C1 VM; native Test uses its existing trialOnly/B5 path. C2 introduces no runtime, recognition task, trial owner or activation+undo. C3 visibly disables conflicting VM actions while `isBusy` and renders `busyNotice`; acquisition browsing and independent installer pause/cancel remain available. C4 owns one application VM/coordinator/installer and supplies the SAME canonical sample-store closure to the VM and Qwen's production `sampleProvider`, including legacy native import/select activation paths. Missing sample remains fail-closed. Native startup must not automatically trial. C4 also owns atomic credential snapshots, readiness/history callbacks/clock and actual live-recording drain permission from C1/B5.

## Resource provenance and limitations

The optional local research route was used: `mespeak@2.0.2`, embedded meSpeak 1.9.6, eSpeak formant synthesis, short original English text and Mandarin Pinyin input. Research package integrity and official documentation snapshots remain ignored research; the shipped README links official sources and gives exact text, Pinyin, generation/resampling commands, version, format, duration and SHA256. FFmpeg 8.1.2 produced PCM16/16k/mono WAVs with metadata removed. Only generated WAV output and README ship; no generator/engine/voice-definition code or data was bundled and no dependency was added.

Redistribution basis is documented honestly as GPLv3 §2's output clause applied to formant audio from our original short text, rather than a separately granted upstream CC0 license. No upstream CC0 or macOS `say` license assumption is claimed. No listening, intelligibility, real-model sample recognition, accuracy, vendor/service or real hardware quality validation was performed. Those matrix entries remain Pending.

WAV SHA256:

```text
0341fa437d4e93a039780bc1f9dc7783e37a09598e5e4a774a9ca73913a86813  en.wav
10deb420ab53319fb8a0f14ae17a17e61b2e206136963a874d2b71455da912af  zh.wav
```

## TDD evidence

The C2 suite is called from the existing registered nonempty `ASRModelCenterSelfTests.run` / `--asr-model-center-only`; full runner registration follows C1. Every RED build below succeeded; none is an API/compiler/filter failure. All commands redirect both output streams to ignored `C2-*` logs.

Initial interface-only scaffolds:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/C2-red-build.log 2>&1
.build/debug/FlowType --self-test --asr-model-center-only > .superpowers/sdd/2026-11-09-asr-model-center/C2-red-focused.log 2>&1
```

Build exit 0 / 32.05 s; focused exit 1 / **145 passed, 12 failed**. Expected failures: metadata resolve not called, no fixed-commit/size preview, explicit confirmation never enqueued, service UUID not committed, missing required OpenAI model/stale revision accepted, all zh/en/auto resources missing. Initial GREEN `C2-green1-build.log` exit 0; focused **166/0**.

Directory add-only stale/relocation regression:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/C2-edge-red-build.log 2>&1
.build/debug/FlowType --self-test --asr-model-center-only > .superpowers/sdd/2026-11-09-asr-model-center/C2-edge-red-focused.log 2>&1
```

Build exit 0 / 29.10 s; focused exit 1 / **185 passed, 3 failed**: a stale add-only preview overwrote newer record metadata/fingerprint; existing record relocation was admitted and changed the stored directory. Fixed by immutable existing-record lookup described above. `C2-green2-build.log` exit 0 / 29.92 s; focused **188/0**. That suite also verifies failed save preserves preview, no runtime/selection/copy, multivariant/tokenizer refusals, safe errors, explicit disclosure, and atomic service key/persistence failure behavior.

Save-only cloud/legacy migration regression:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/C2-cloud-red-build.log 2>&1
.build/debug/FlowType --self-test --asr-model-center-only > .superpowers/sdd/2026-11-09-asr-model-center/C2-cloud-red-focused.log 2>&1
```

Build exit 0 / 61.24 s; focused exit 1 / **202 passed, 5 failed**: delegated legacy save did not freeze prior effective selection, first profile became active (both marker values), and subsequent native legacy resolution had no explicit selection to update. Shared save-only wrapper fixes these while retaining the marker. Dirty local-draft external navigation/keep/discard ownership also passes.

## Final GREEN and self-review

Final sequential commands/results appended after the affected regressions finish. No full code gate, artifact/release gate, real-network/manual validation or broad unrelated suite is claimed. Self-review read the entire production diff, new sheet/session/action files, decoder/resources/provenance, tests, central C1 registration and exact downstream boundaries. No independent agent was spawned. Existing-record mutation and cloud autoactivation findings were reproduced RED before their fixes. No unresolved automated correctness concern remains; C3/C4 assembly and all real/manual acceptance remain downstream.

Files changed: Package.swift; Core/ConfigurationStore.swift; Settings/ASRProviderEditSheet.swift; Settings/CloudASRProviderList.swift; Settings/ImportedASRModelActions.swift; new Settings/ModelCenter/{HFModelInstallSheet,LocalASRServiceEditSheet,ASRValidationSampleStore}.swift; new Testing/ASRAcquisitionSelfTests.swift; Testing/ASRModelCenterSelfTests.swift; Resources/ASRValidation/{README.md,en.wav,zh.wav}; the service/cloud acquisition paragraphs in docs/superpowers/specs/2026-11-09-model-center-experience-design.md. Package.resolved/dependency versions unchanged.

### Final GREEN exact commands and results

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/C2-final-build.log 2>&1
.build/debug/FlowType --self-test --asr-model-center-only > .superpowers/sdd/2026-11-09-asr-model-center/C2-final-focused.log 2>&1
.build/debug/FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/C2-final-backends.log 2>&1
.build/debug/FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/C2-final-hf.log 2>&1
.build/debug/FlowType --self-test --native-client-only > .superpowers/sdd/2026-11-09-asr-model-center/C2-final-native.log 2>&1
git diff --check
git diff --exit-code -- Package.resolved
shasum -a 256 Sources/flowtype/Resources/ASRValidation/*.wav
```

All exit 0. Build complete 50.51 s. Exact test summaries:

```text
=== ASR model center self-test: 207 passed, 0 failed ===
=== ASR backend self-test: 1084 passed, 0 failed ===
=== HF install self-test: 866 passed, 0 failed ===
=== Native client self-test: 960 passed, 0 failed ===
```

Whitespace/dependency-lock diff emitted no output. WAV checksums equal the README/store constants above. The four final focused test logs contain no FAIL/error/warning output. The broad final rebuild re-emitted the existing captured-variable warning at unchanged HFInstallTransactionSelfTests.swift:169 (`reject` mutated after capture by sendable closure); no new C2 warning was introduced. No tracked edits followed the final build/tests. Only this ignored report is being completed for closeout.

### Commit closeout

Explicit 14-file commit `98f527d` — `feat: add ASR acquisition and explicit validation flows`; 867 insertions / 11 deletions, plus two generated WAV resources. Staged whitespace check and post-commit base-to-HEAD whitespace/dependency-lock checks exited 0. Final `git status --short` emitted no output. No tracked edits after the final GREEN or commit. C2 is DONE; no unresolved automated concern. Remaining C3/C4 composition, actual sample quality, real models/services/vendors/window/accessibility and release/manual acceptance are Pending as described above.

## C2 review fix round 1 — I1 revision ownership and M1 preview context lifetime

Review source: `task-C2-review.md` (Needs fixes, Important I1, Minor M1/M2). Fix base: `98f527dc54116e5464730baf2484e856ee50cfc0`. Controller authorized narrow I1/M1 fixes only, no broad boundary expansion, no subagents, no real user/config/credential/model/network effects, no full gate. M2 is unchanged baseline warning cleanup, not part of this fix.

### Changes and downstream contracts

- `saveModelCenterASRDraft` now checks `.existing` UUID existence and the captured `draft.profile.revision` against the latest committed profile **before** entering the shared transaction. A missing UUID throws `.deleted`; an older revision throws `.conflict`. This occurs before pending save cancellation, any credential access, profile/config mutation or durable write. C3 retains its draft on failure and should explain conflict/reopen against the latest profile; it must never silently retry with a refreshed revision. Both endpoint/model and credential-only edits rotate revision as before. Existing legacy `saveASRDraft` and `ProviderDraftCommit.apply` compatibility semantics are unchanged. Save-only effective-selection/migration-marker behavior and all previous C3/C4 requirements remain unchanged.
- HF production composition now resets its small endpoint→client dictionary when a fresh preview is admitted. All clients and their B1 contexts from the obsolete preview are released. The current preview's model resolution, tokenizer resolution and planner still use the same client for each endpoint, retaining credential/provenance/budget identity through planning. Reset runs only after the existing `isWorking` guard admits a new preview; it cannot affect an in-flight accepted preview. No B1 resolver, transport, budget or install domain behavior changed.
- Existing `HFModelInstallSession(credentialStore:installer:)` callers are source-compatible. Added `init(makeClient:enqueue:)` as a small injected-metadata lifecycle seam, used by the production convenience initializer and the focused actual resolver/planner fixture. The existing lower-level `init(resolve:plan:enqueue:)` adds a defaulted `beginPreview: () -> Void = {}` hook, so current injected callers remain compatible. C3/C4 need no new lifecycle owner or wiring.

### Meaningful RED evidence

Added a cloud fixture using isolated defaults, in-memory credential boundary with operation counts and a persistence counter. It creates R0, captures the second editor's draft, commits a newer R1 endpoint/model/key, and schedules an unrelated settings save. It then tries R0 and asserts `.conflict`, no config writes/credential reads or writes/staged keys, unchanged committed bytes/profile/effective selection/migration marker, retained draft and completion of the already scheduled settings save. The bounded 650 ms await covers the existing 500 ms debounce; it is not a new product timer.

The HF fixture uses the real B1 `HFRepositoryClient` and B2 `ASRInstallPlanner` through injected URLProtocol metadata for tiny synthetic Whisper model+tokenizer repositories. Both model and tokenizer plan successfully with one client in a preview; after another real preview, a weak reference to the old client must be nil, a new client/context must exist, and no weights may be fetched or enqueued. This exercises actual retained resolver contexts, not a mirror count of a fake cache.

The first build/focused attempt (`C2-fix1-red-build.log`, `C2-fix1-red-focused.log`) compiled successfully (34.19 s) and reproduced M1, but the I1 fixture hit duplicate naming against `Configuration.default` before reaching its intended stale edit. This setup failure is not counted as I1 business RED. `C2-fix1-red2-build.log` (30.00 s) compiled the name correction; no focused run followed it because review identified its still-present default first row/index mismatch. The fixture was corrected to an explicitly empty cloud list before initial R0 save.

Exact valid RED commands:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/C2-fix1-red3-build.log 2>&1
.build/debug/FlowType --self-test --asr-model-center-only > .superpowers/sdd/2026-11-09-asr-model-center/C2-fix1-red3-focused.log 2>&1
```

Build exit 0 / **29.88 s**. Focused exit 1 / **217 passed, 9 failed**. Relevant observed failures:

```text
C2 I1 stale cloud revision throws conflict
C2 I1 stale revision rejected before config writes — got 6, want 4
C2 I1 stale revision rejected before credential reads or writes — got 5, want 0
C2 I1 stale revision cannot stage any key
C2 I1 stale revision preserves latest profile selection and migration marker
C2 I1 stale revision leaves durable config untouched — got Optional(1348 bytes), want Optional(2831 bytes)
C2 I1 conflict does not cancel an already scheduled settings save
C2 M1 fresh preview replaces the prior metadata client — got 1, want 2
C2 M1 obsolete resolver and all of its contexts are released
=== ASR model center self-test: 217 passed, 9 failed ===
```

Full fixture UUID/value/config dumps remain in the ignored log. These failures occurred before either production fix, against buildable code and the registered nonempty C1 filter.

### GREEN / self-review

Sequential final commands/results appended below. No tracked edits occurred during any build/test. Self-review read the three-file complete diff, confirmed the guard is before entry to `commitASRDraft`, legacy call sites remain untouched, selection/migration is not changed by conflict, pending work survives, and the preview reset affects only metadata clients after the existing action admission. Current model/tokenizer/planner context identity remains bound through B1/B2. No downloader/activation/recognition owner, credential cleanup or transport behavior was added. No further broad edges/features were added.

### Fix round 1 final GREEN

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/C2-fix1-green-build.log 2>&1
.build/debug/FlowType --self-test --asr-model-center-only > .superpowers/sdd/2026-11-09-asr-model-center/C2-fix1-green-focused.log 2>&1
.build/debug/FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/C2-fix1-green-backends.log 2>&1
.build/debug/FlowType --self-test --native-client-only > .superpowers/sdd/2026-11-09-asr-model-center/C2-fix1-green-native.log 2>&1
git diff --check
git diff --exit-code -- Package.resolved
```

All exit 0. Build complete **32.35 s**. Final exact summaries:

```text
=== ASR model center self-test: 226 passed, 0 failed ===
=== ASR backend self-test: 1084 passed, 0 failed ===
=== Native client self-test: 960 passed, 0 failed ===
```

Whitespace/dependency-lock checks emitted no output. The four GREEN logs contain no warning/error/FAIL lines. M2's known unchanged HFInstallTransactionSelfTests.swift:169 captured-variable warning remains tracked as baseline, although this incremental rebuild did not re-emit it. No HF-only suite was rerun: this fix changes UI metadata-client lifetime only, with the actual resolver/planner regression included in the C1 filter; no HF transport/domain source changed. No full code/artifact/release gate or manual matrix was run. Previous pending sample/model/service/window/accessibility/release checks remain Pending.

Files changed only: `Sources/flowtype/Core/ConfigurationStore.swift`, `Sources/flowtype/Settings/ModelCenter/HFModelInstallSheet.swift`, `Sources/flowtype/Testing/ASRAcquisitionSelfTests.swift`. All automated concerns in I1/M1 are addressed, with fresh scoped review reserved for the controller.

Fix round 1 closeout: **DONE**. Explicit three-file commit `385639e` — `fix: guard ASR draft revisions and release preview contexts`; 129 insertions / 7 deletions. Staged and post-commit whitespace checks and base-to-HEAD Package.resolved check exited 0. Final `git status --short` emitted no output. No tracked changes after the final GREEN or commit; only this ignored report was appended. No unresolved automated I1/M1 concern; M2 baseline cleanup and all prior manual/downstream boundaries remain as stated.
