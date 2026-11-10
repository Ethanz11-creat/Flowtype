# C3 — Native model library, details and installation tasks

Status: DONE. Commit `c2a6cdd` — `feat: present native ASR model library and installation tasks`. Base `385639e`; linked worktree `/Users/yiheng/pycode/flowtype-local`, branch `flowtype-local`. Seven explicit files, 754 insertions / 14 deletions. No subagents. Frontend-design skill read and applied under binding native Theme/system typography/compact utility visual ruling. No new dependencies or Package.resolved changes.

## Delivered

- `ASRModelCenterView(model:)` consumes the application-owned C1 VM. Compact role/policy/explicit cloud-fallback consent summary; stable-ID source-filtered model rows; separately scrollable details with pinned Test / primary / fallback controls; five actual acquisition entry flows; collapsible installation tasks. UI browsing never changes roles. Conflicting VM actions disable while `isBusy`, with readable in-progress and `busyNotice` messages; installer actions remain independent.
- Native details show complete title, engine/variant/quantization, formatted and exact bytes, full selectable/copyable injected paths, installed source repositories/fixed commits and source-license links, explicit unknown peak memory, installation ownership and last validation. Source/license unknown is honest for imported records. Native versus loopback/cloud privacy copy is separate. whisper.cpp explicitly has service-managed model identity. Errors wrap and remain selectable.
- Recommendations show all four existing recipes and resource tradeoffs, then use C2 `HFModelInstallSession.useRecipe` and the actual HF preview/explicit-install sheet. Directory flow invokes only injected directory selection then existing C2 inspection owner, previews format/path/size/hardware assessment, and calls `savePreview` add-only. Cloud/local sheets use exact saved UUID/revision drafts and injected save-only C2 transactions. Save only refreshes/locates the saved backend; no implicit Test, upload, activation or first-row selection. A legacy folded imported identity is mapped through the existing C1 presentation API. Successful primary/fallback locates the projected actual role identity after native preset acquisition.
- Service/cloud recognition first opens `ASRValidationNotice` with the actual validated endpoint, canonical language-specific sample label, credentials/upload and possible cost disclosure. Confirmation captures full saved profile (cloud validation identity)/revision, backend ID, destination and sample language; it rechecks both at confirmation and the queued MainActor action before invoking C1. Deleted/edited profiles require a fresh confirmation. Native Test stays C1 trial-only. LastTrialResult is ephemeral/selectable quality output, never an accuracy score or persisted transcript.
- Selected removal requires explicit deselection confirmation explaining unready/no arbitrary replacement and ongoing recording snapshot/drain. Record-only and managed-file deletion have separate confirmations and separate injected usage/ownership reasons. External user-owned files never offer file deletion. C1 remains the final domain guard. Job pause/resume/cancel always capture `jobID`, not row offsets; cancel states its retained partial files. Partial clearing is independent, explicitly confirmed and disabled unless a safe injected callback exists; no UI filesystem deletion.
- Source list uses native SwiftUI ScrollView/buttons with focusability, arrow selection, stable IDs, selected accessibility traits and complete combined labels; no custom motion. This replaced a SwiftUI List that drew no rows in real offscreen PNG inspection. Details use a pinned action footer so long content cannot hide the main actions.
- `ASRSettingsContent` adds optional `modelCenter` and defaulted `modelCenterActions` arguments; when supplied it replaces the old model/config portion and preserves microphone/language settings. Full application/window/onboarding assembly intentionally belongs to C4; legacy production path remains until C4 routes it.

## Exact C4 integration interfaces (mandatory composition)

Host:

```swift
ASRModelCenterView(model: ASRModelCenterViewModel,
                   actions: ASRModelCenterUIActions = .init(),
                   initialSource: String = "all")
ASRSettingsContent(..., modelCenter: ASRModelCenterViewModel? = nil,
                   modelCenterActions: ASRModelCenterUIActions = .init(),
                   target: ..., requestID: ..., devices: ...)
```

`@MainActor ASRModelCenterUIActions` is a value dependency bundle. All optional fields default nil and fail closed with disabled operations and readable unavailable copy. Its synthesized memberwise initializer follows this field order; each callback/property below is optional unless stated:

```swift
configuration: (() -> Configuration)?
importedActions: ImportedASRModelActions?
hfSession: HFModelInstallSession?
discovery: ASRModelDiscoveryClient?
draftChecks: CloudASRConnectionCheck?
navigation: SettingsNavigation?
chooseDirectory: (() -> URL?)?
persistImported: ((Configuration) throws -> Void)?
saveLocal: ((LocalASRServiceDraft) throws -> Void)?
saveCloud: ((ASRProviderDraft) throws -> Void)?
hasCredential: ((ASRBackendID) -> Bool)?
credential: ((ASRBackendID) throws -> String?)?
saveHFToken: ((String) throws -> Void)?
copy: ((String) -> Void)?
removalReason: ((ASRBackendID, Bool) -> String?)?
pause: ((UUID) async throws -> Void)?
resume: ((UUID) async throws -> Void)?
cancel: ((UUID) async throws -> Void)?
clearPartial: ((UUID) async throws -> Void)?
loading: Bool = false
loadError: String? = nil
```

C4 MUST supply all production effects using the existing app-owned objects. In particular:

- `configuration = { store.current }`, existing `ImportedASRModelActions`, one retained HF session with existing installer/credential boundary, existing discovery/checks/navigation.
- `chooseDirectory = ASRModelCenterUIActions.openDirectory` is available; the static helper creates NSOpenPanel only after the user invokes import. Previews inject `{ nil }` and never call a panel.
- `persistImported = store.commitNativeASRActivation`, `saveLocal = store.saveLocalASRServiceDraft`, `saveCloud = store.saveModelCenterASRDraft`, `saveHFToken` writes only the existing official HF credential slot. Preserve revisions/conflict errors; never retry stale drafts silently. C2 editors retain failed drafts.
- `credential` reads the exact requested saved profile's credential reference; `hasCredential` supplies the correct cloud editor presence indicator. The VM itself must still receive C1's atomic value+generation credential snapshot rather than this editor-only value closure.
- `copy` invokes the existing guarded production clipboard boundary only on a user click. Previews use no-op injected copy and never click it.
- `removalReason(id, deleteManagedFiles)` MUST project captured usage, pending real native drain/live-recording state and ownership for this exact backend. `false` is record-only; `true` requires application-owned managed files. Return a readable reason when occupied/unsafe. Never delete external user files; selected roles are separately guarded in UI and C1. This is a projection, not a second deletion/runtime owner. C4 also retains B5's real unload gate and C1 domain final checks.
- Installer `pause` / `resume` / `cancel` call existing actor APIs by exact job ID; UI refreshes C1 snapshots after each awaited operation. C4 continuously refreshes snapshots/configuration/readiness as already required by C1.
- Existing B4 has no safe `clearPartial(jobID:)` API. Controller ruling: C3 provides only this independent seam/explicit unavailable state; C4 MUST add the safe B4 domain API and wire it. Do not leave production permanently unavailable, and do not implement file removal in UI. Cancellation retains staging.
- Feed the SAME C2 canonical sample-store closure to the VM and Qwen sample provider. No startup/automatic trial. C4 must route every old editor/action path to the save-only/new model-center host and retain one application VM/coordinator/installer.

## TDD evidence

All builds/tests ran sequentially with no tracked edits during a running build/test. Logs are ignored task-workspace files. No full code gate was run per controller instruction.

Initial buildable identity/removal scaffold RED:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/C3-red-build.log 2>&1
.build/debug/FlowType --self-test --asr-model-center-only > .superpowers/sdd/2026-11-09-asr-model-center/C3-red-focused.log 2>&1
```

Build exit0, 41.55s. Focused exit1, **227 passed / 5 failed**, exactly: `testRowIdentityAfterReorder` missing captured backend forwarding and deleted-row protection; `testDownloadActionsTargetJobID` missing exact ID forwarding after reorder/deletion; occupied-removal reason and selected-removal reason missing. No registration/compiler failure counted as RED. GREEN `C3-green2-build.log` 44.17s exit0; `C3-green2-focused.log` **232/0**. The intermediate green1 build found a long SwiftUI type-check expression plus an always-true optional comparison; both corrected before GREEN, no business RED claimed for compiler diagnostics.

Explicit disclosure race regression RED:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/C3-consent-red-build.log 2>&1
.build/debug/FlowType --self-test --asr-model-center-only > .superpowers/sdd/2026-11-09-asr-model-center/C3-consent-red-focused.log 2>&1
```

Build exit0,44.13s. Focused exit1, **233/3**: edited endpoint, changed canonical sample language and deleted disclosed profile incorrectly passed confirmation. GREEN `C3-green3-build.log`29.82s exit0, focused **236/0**. This tests actual captured profile identity against current domain configuration, not a style mirror.

Final freeze exact commands:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/C3-final-build.log 2>&1
.build/debug/FlowType --self-test --asr-model-center-only > .superpowers/sdd/2026-11-09-asr-model-center/C3-final-focused.log 2>&1
.build/debug/FlowType --self-test --native-client-only > .superpowers/sdd/2026-11-09-asr-model-center/C3-final-native.log 2>&1
swift run --skip-build FlowType --self-test --native-client-previews-only > .superpowers/sdd/2026-11-09-asr-model-center/C3-final-previews.log 2>&1
git diff --check
git diff --exit-code -- Package.resolved
git diff --cached --check
```

All exit0. Build **35.35s**; model-center **236 passed/0 failed**; native-client **960/0**; preview **3/0**. Final logs have no warning/error/FAIL lines. No source edits followed the final build/tests. No unrelated A/B-only suites repeated: no A/B domain implementation changed. Final exact staged whitespace and dependency-lock checks emitted no output.

## PNG manifest and actual visual inspection

Final manifest:

`/private/var/folders/40/tymbl3bj6hv92j3rzcpqyqf00000gn/T/flowtype-validation/817639D3-C9A8-4694-AA9A-9951A7028F76/Tmp/native-client-previews/manifest.json`

**98 actual SwiftUI PNGs**: existing56 plus six model-center states × three sizes × two appearances (36), plus installation-component six. States: `model-center`, `model-center-loading`, `model-center-empty`, `model-center-error`, `model-center-long-content`, `model-center-download`;1040×700,1120×760,1440×900; light/dark. Manifest marks the dedicated installation view `position=installation-component`; it is not a fake scrolled window.

Read actual final PNGs with `view_image` before commit: `model-center-minimum-light`, `model-center-default-dark`, `model-center-wide-light`, `model-center-wide-dark`, `model-center-long-content-minimum-dark`, `model-center-error-minimum-light`, `model-center-empty-default-light`, `model-center-loading-default-dark`, `model-center-download-tasks-minimum-light`. Controller separately inspected minimum/light, long/minimum/dark and download/default/light. Normal smallest/default/wide details retain useful width, stable list rows and primary controls; full long path wraps without horizontal overflow, errors wrap, density matches native client. Empty/loading are intentional centered states; wide normal page content remains bounded by existing preview wrapper. Download component shows exact bytes, percentage, failure text and independent retained-partial/cancel/clear actions.

First render `C3-previews1.log` generated92 PNGs at isolated root `A91B00DB-912A-456C-8D43-803497FF258E`; actual images exposed blank List rows and hidden detail actions. Fixed from that evidence with SwiftUI ScrollView stable row buttons and pinned footer, then regenerated final98. No pixels or synthetic screenshots were substituted.

Limitations: smallest long/error page's lower acquisition/task content lies below the outer scroll viewport; detail's advanced fields, results and removal controls require its separate scrolling. Dedicated tasks image shows the real component but does not prove whole-window scrolling. Real window keyboard focus, arrow navigation/scroll-following, VoiceOver labels/selection, reduced-motion preference, material composition and microphone/input integration remain Pending for D2/C4 real-window acceptance. No such checks are marked Pass from offscreen PNGs.

## Effects, self-review and downstream limits

Preview retained both before/after ValidationEffects counts unchanged (3 checks pass), used isolated runtime configuration/fixture root, injected service recognition and canonical bundled sample closure, no real user config/Keychain/global Hub token, model path reads/downloads, external services, microphone, permissions, actual clipboard, signing/install/push/release. Instantiating a discovery client starts no request; no acquisition/copy/link action was triggered. Fixture save callbacks either throw or write only isolated store, installer controls are injected; no real model/service quality claim.

Self-review read all seven files and diff: action targets captured stable IDs; selected/occupied removal has independent record/delete predicate; cloud/service Test requires disclosure and rejects profile edits before VM admission; busy effects remain C1-owned; acquisition does not select or test; final native actual identity is projected; no new runtime/install/recognition task owner. Short UI Tasks only await existing coordinator methods. Full C4 application assembly, safe domain clearPartial implementation, real cloud/vendor/service/model tests, sample intelligibility/quality, real-window accessibility/focus/scroll and artifact/release acceptance remain explicitly downstream. No unresolved C3 automated correctness finding; fresh independent review is controller-owned.

Files: new `Settings/ModelCenter/{ASRModelCenterView,ASRModelRow,ASRModelDetail,ModelInstallationList}.swift`; modified `Settings/SettingsPage+ASR.swift`, `Testing/ASRModelCenterSelfTests.swift`, `Testing/NativeClientPreviewSelfTests.swift`.

## C3 review fix I1 — model identity

Added the existing `row.subtitle` as one compact visible line and its complete value to the combined accessibility summary; complete detail presentation is retained. No new tests for this reversible presentation change.

Sequential verification (no edits while commands ran): `swift build` passed in **30.86s** (`C3-fix1-build.log`); `.build/debug/FlowType --self-test --asr-model-center-only` **236 passed/0 failed** (`C3-fix1-focused.log`); `swift run --skip-build FlowType --self-test --native-client-previews-only` **3/0**, **98 PNGs** (`C3-fix1-previews.log`). Logs are ignored. `git diff --check` passed.

Actual `view_image` inspection: `/private/var/folders/40/tymbl3bj6hv92j3rzcpqyqf00000gn/T/flowtype-validation/E06203DC-3A0E-4DC9-9A37-21330E371556/Tmp/native-client-previews/model-center-minimum-light.png` and sibling `model-center-long-content-minimum-dark.png`. Model/subtitle is visible, list fits, and pinned action footer remains visible in both; long values truncate compactly with full details retained. Existing outer scrolling limitation remains. Manual real-window focus, keyboard scrolling, VoiceOver, reduced motion/material and production integration remain **Pending**.

Exact changed files: `Sources/flowtype/Settings/ModelCenter/ASRModelRow.swift`, `.superpowers/sdd/2026-11-09-asr-model-center/task-C3-report.md`. No A/B/native-full gate rerun and no real user/system effects.
