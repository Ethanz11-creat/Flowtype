# Native client review and execution archive — 2026-11-03

This file preserves the pre-fix whole-feature review at f974781, followed by the scoped verification of its single fix wave at f3ac69f. The original review's artifact status reflects its handoff time; the corrected earlier artifact and final candidate gate results are recorded in the [acceptance record](2026-11-03-native-client-acceptance.md). All five source findings were closed in the scoped review. Manual/remote CI acceptance remains Pending.

## Original whole-feature review

# Whole-feature review — native macOS client

Reviewed base `46dca0f` through `f974781e7415d46ab7b757c0af77d3021642e24d`, Sources tree `c539eae74bb17646158309eefa2bcd648d8dccd0`. This is the single broad review of the complete feature, independently of the earlier task reviews. Product source, index and branch were not changed; no tests, native/live actions or child agents were run. Only this requested report was written.

## Strengths

- Navigation has explicit destination and request identities, including repeated requests and guarded legacy tab assignments. Draft dismissal resumes the exact deferred request, and stale editor detach cannot remove a newer guard (`Settings/MainWindowView.swift:34`, `Settings/ProviderDraft.swift:72`, `Settings/ASRProviderEditSheet.swift:64`; all source paths below are relative to `Sources/flowtype/`). Five-page navigation and four settings groups are retained.
- Provider commits resolve UUIDs against the latest configuration, preserve current activation and untouched keys, and reject deleted profiles before any mutation. ASR and LLM key namespaces remain independent. Save no longer implicitly tests a service, and LLM Test/Save now share normalization (`Settings/ProviderDraftCommit.swift:18`, `:25`, `:57`; `Settings/ProviderEditSheet.swift:301`).
- Trial delivery is a scoped callback with session/generation validation. The controller's purpose check skips actual formal history/learning and recent-delivery branches, including uncertain cancellation; it does not merely replace an effect with an empty closure. Resource leases survive cancelled tasks until entered stages return, and real RecordingStage cleanup is covered using a controlled recorder (`Core/PipelineOrchestrator.swift:201`, `:515`, `:756`, `:802`; `Core/SessionResourceCoordinator.swift:40`; `Settings/TrialSessionPresenter.swift:35`). The tests correctly require an explicit restart after drain and retain existing clipboard, uncertainty and once-only persistence assertions.
- History distinguishes failed reads from an empty database. Successful privacy mutations update authoritative action data before publication/reload, including willSet reentry. Stale detail actions resolve current rows, so cleared/deleted text cannot be copied or exported from cached view values (`Core/DictationHistory.swift:117`, `:137`, `:170`, `:221`; `Settings/HistoryPresentation.swift:102`). The real SQLite rollback/reentrant tests are substantive.
- Model display separates saved intent, active lease and preparation target. Recovery destinations follow the captured first failed candidate rather than the currently selected provider. Existing route snapshots, recovery authorization, 20-second budget, retained-audio retry and delivery latch remain in their established owners (`Settings/ImportedASRModelPresentation.swift:58`; `Core/Pipeline/Stages/ASRStage.swift:155`; `Core/PipelineOrchestrator.swift:387`).
- Native layout uses the specified dimensions, opaque surfaces, restrained accent, fixed-size mode control and independent full-row charts. Dictionary/style pages use real stores, and overview keeps StatsEngine formulas. The DEBUG-only renderer uses production pages with isolated fixture stores and reports its limitations honestly. I visually inspected the existing minimum/light overview and privacy PNGs: their visible content is coherent and unclipped; this does not establish lower scrolling or live-window acceptance.

## Issues

### Critical

None found.

### Important

**I1 — Trial hides terminal notices, including silent/empty capture and polish fallback.**

- References: `Settings/TrialSessionView.swift:63` and `:82`; `Settings/TrialSessionPresenter.swift:41`; `Core/PipelineOrchestrator.swift:564` and `:611`.
- The trial view handles preparing, processing and `.error`, but never displays `.notice(message)`. Real ASR returns notices for clearly silent and empty recordings (`Core/Pipeline/Stages/ASRStage.swift:61`). The ordinary capsule would show them, but the trial deliberately has no window/capsule effects. The user consequently sees Start again and an empty result with no explanation. A polish timeout/failure also produces a completion notice (`Core/Pipeline/Stages/PolishStage.swift:158`), which is lost even when the trial displays the fallback text.
- Render the controller's notice in the trial surface, with a lifecycle that clears it on the next attempt/cancel and does not introduce ordinary delivery effects. Add an isolated regression that drives the actual presenter/controller through silent capture and degraded polish and verifies the user-facing presentation value, not just the controller enum.

**I2 — Main-page recreation bypasses retained cloud-check transport ownership.**

- References: `Settings/SettingsView.swift:12` and `:48`; `Settings/MainWindowView.swift:137`; `Settings/ASRProviderEditSheet.swift:58` and `:80`; `Settings/CloudASRConnectionCheck.swift:37`, `:62`, `:71`.
- Both check owners live in `SettingsPage`. Switching to another main page removes that conditional branch; returning constructs new check owners. Cancelling/discarding a draft invalidates its conclusion and cancels its task, but correctly leaves its transport slot occupied until the old operation actually returns. A slow cancellation-resistant test can therefore still be running in the old checker while the replacement settings page accepts another test for the same profile through a fresh empty checker. Closing/reopening the settings window has the same owner replacement. This defeats the intended in-flight protection and can duplicate a billable test; it does not resurrect configuration or let the old checker publish into the new one.
- Retain transport ownership above disposable page/window composition, or use a shared reservation owner with separate live/draft result revisions. Preserve the explicit isolated owner injection for tests/previews. Extend the existing delayed-transport regression to recreate the actual settings-page composition while the previous request remains suspended. The current regression reopens sessions with the same explicitly supplied checker, so it cannot catch this wiring gap (`Testing/ProviderDraftCheckSelfTests.swift:40`).

**I3 — Failed history privacy/destructive writes have no user-visible failure state.**

- References: `Settings/HistoryPage.swift:39`; `Settings/HistoryPresentation.swift:116` and `:122`; `Core/DictationHistory.swift:174`, `:189`, `:211`.
- The store now correctly returns `false` and preserves cached data when delete, clear-transcripts or reset fails. The UI discards that failure: clear ignores the result, delete exposes no error, and reset dismisses confirmation before checking the Boolean. `readState` remains its previous value because failed writes do not reload. If SQLite rejects a write or disk access fails, the user gets no explanation or retry feedback after explicitly requesting a privacy action. Preserving the cache is correct, but quietly retaining sensitive text after a clear request is not adequate failure handling.
- Surface a distinct mutation failure in the page/model, retain the current safe cache behavior, and allow a fresh explicit retry. Extend the existing real-database failed-write fixture to verify this visible failure contract (`Testing/NativeHistorySelfTests.swift:317`). Do not report failure by erasing the cache or pretending the write succeeded.

### Minor

**M1 — A denied microphone masks a concurrent missing-engine blocker.**

- References: `Settings/ReadinessPresentation.swift:16` and `:24`; `Settings/SettingsPage+Permission.swift:20`; dependency `Core/Readiness/ReadinessSnapshot.swift:53`.
- With microphone denied and all engines unavailable, the classifier returns microphoneDenied first. The presenter adds microphone/AX details and then only the classifier's one reason, which is already present. No-engine is omitted, so a user repairs the microphone only to discover another blocker. The existing multiple-issue test uses a ready local engine and misses this combination (`Testing/ReadinessPresentationSelfTests.swift:10`).
- Expose the simultaneous engine issue using the existing readiness domain rules while keeping the primary classification and permission behavior unchanged; cover denied mic + unavailable engines, with and without AX.

**M2 — Empty selected range is described as first-ever use.**

- References: `Settings/OverviewPage.swift:34` and `:58`.
- Selecting 7/30 days with no recent sessions shows “开始你的第一次口述” even if the annual heatmap contains older activity. Use first-use guidance only for an empty full dataset; otherwise describe no activity in the chosen range. Statistics themselves remain correct.

**M3 — Documentation closeout still describes pre-implementation state and misattributes contract 4.**

- `docs/superpowers/validation/2026-11-03-native-client-acceptance.md:12` maps hotkey effects to Task 6; the coordinator/regressions are Task 2. Candidate identities at `:32` are still placeholders.
- `docs/superpowers/specs/2026-11-03-native-client-experience-design.md:5` and `:258`, and `docs/superpowers/plans/2026-11-03-native-client-experience.md:197`, still say implementation has not begun / only planning was delivered; implementation checkboxes remain unchecked.
- These corrections were already queued by the controller. Close them using the final candidate identities and truthful remaining Pending items; they are not additional source defects.

## Deferred ledger and rulings

All deferred entries in `progress.md` were triaged:

| Entry | Final disposition |
| --- | --- |
| Task 1 injected navigator initial-tab mismatch | Resolved: MainWindow initializes from supplied navigation; actual constructor regression in NativeRecoveryNavigationSelfTests. |
| Task 1 ProviderEditSheet `var` warning | Resolved: validation's unmodified baseURL is `let`. |
| Task 3 Test used unnormalized LLM URL/model | Resolved: Test and Save call normalizedLLMProfile; whitespace regression present. |
| Task 7 AX notice incorrectly promised trial auto-copy | Resolved in TrialSessionView.preparationText and OnboardingFlowSelfTests. Distinct terminal-notice omission is I1. |
| Task 10 odd histogram midpoint truncation | Resolved: midpointLabel yields 0.5/1.5 for odd maxima, covered in NativeRecoveryNavigationSelfTests. |
| Task 11 acceptance contract 4 attribution | Still pending; M3 above. |

The narrow navigation-guard expansion, reusable injected model subtree and DEBUG native-renderer seam implement approved contracts. Retaining a cancelled lease until actual stage return and requiring explicit restart is consistent with the Task 7 ruling. The four-file Testing-only correction in f974781 preserves delivery/history/clipboard assertions rather than changing production cancellation policy. The removed lower-anchor experiment is not claimed as working evidence.

## Evidence and review coverage

- Read the complete 81-file packaged diff in bounded passes: core/storage and lifecycle; cloud drafts/checks; history; models/navigation/onboarding; overview/settings; style/trial/dictionary; all changed and added tests; theme and acceptance documentation. Reviewed the full spec, plan/global constraints and deferred ledger. The Task 11 report was inspected for evidence provenance, not used as a substitute for reviewing its source changes.
- Concrete outside-diff checks: existing readiness classification was checked to confirm M1; RecordingStage cleanup was checked to validate stage-drain assumptions; ConfigurationStore.flushPendingSave and the application termination hook were checked to rule out losing a latest unobserved edit; ModelDownloader was checked to verify “下载并加载” delegates to the existing coordinator; reused PostProcess/Polish stages were checked for trial persistence/learning leakage and the origin of terminal fallback notices. No new formal-store mutation was found in those reused stages.
- Current-head **code lane Pass**: `build/verification/7A40A5E3-CE3F-43B8-96EC-172F64E4500A/verify-report.json`. All source/platform/build/full-suite phases Pass, clean source-start/end, f974781 and Sources c539eae identity. Full-suite stdout reports **25,299 passed, 0 failed**. Focused native 844/0, delivery 714/0 and silence 1014/0 are supplementary existing evidence. The earlier c058190 27-failure run is superseded only as code evidence, not rewritten as a pass.
- Current-head **artifact lane Fail**: `build/verification/3FD4343E-5AF9-40B6-AE23-D03D0C93FAEE/verify-report.json`. Same clean source identity; artifact-build exits 1 (`buildFailed`), with child stderr `FlowType packaging: shaderInvalid`. Artifact identity is null; manifest/signature/check and all smoke phases are Pending/notExecuted. Source-end and recovery phases pass. Controller subsequently reports that the invocation omitted the CLI/README-required explicit `MLX_METALLIB_PATH`; this is not a demonstrated source/shader defect. The corrected invocation is compiling release, logged at `build/native-client-artifact-explicit-shader.log`, with its result pending at review handoff. The original failure remains recorded; no artifact success is inferred from code Pass.
- Existing preview PNGs originate from c058190. Production files match f974781, but Testing changes altered Sources identity; they remain supplementary layout observations with that provenance, not exact-candidate manual evidence. Actual history rows and lower scrolling at minimum/default have documented windowless-renderer limitations.
- All **41 manual cases remain Pending**; **remote CI remains Pending**. Manual-template generation and final candidate/evidence documentation remain controller work. Any fixes resulting from this review create a new candidate identity and require appropriate renewed gates; current f974781 reports cannot be reassigned to that candidate.

## Recommendations

Fix I1–I3 and cover the missing composition/presentation boundaries with isolated tests. The existing fine-grained domain tests are strong; the newly found gaps sit where real page composition consumes those domains. Resolve the artifact packaging failure, update final evidence/status documents, and preserve manual/CI Pending until there is actual matching evidence.

## Declined to judge

- Physical parent-window close while an edited provider sheet is presented: source has interactiveDismissDisabled and explicit Cancel/Escape/navigation guards, but I did not infer AppKit parent-close behavior from offscreen rendering. This needs the pending native interaction check; no unverified data-loss defect is asserted.
- Live keyboard focus/shortcuts, reduced-motion behavior, system appearance transitions, display changes, actual scroll reachability and history List row painting: windowless images cannot establish these behaviors; physical R6 cases remain Pending.
- Actual microphones/Bluetooth/unplug recovery, OS permission prompts/recovery, real provider credentials/network billing/weak-network behavior, real model loading on supported hardware and cross-application/clipboard delivery: no authorized current-candidate manual evidence was supplied and this review prohibited side-effectful native/live tests. Existing fake/isolated coverage supports source contracts only.
- Independent diagnosis of artifact `shaderInvalid`: the controller reports an omitted required `MLX_METALLIB_PATH` and has started a corrected invocation. I did not duplicate its packaging investigation or infer success before a completed report.
- Remote CI success, installability/release acceptance and the final post-fix candidate: no matching completed evidence exists. No installation, running-app replacement or release is approved here.
- New model architectures, cloud SDKs/accounts/subscriptions and Keychain migration: explicitly excluded by the approved design; no claim that these were implemented is accepted.

## Assessment

**Plan/spec verdict:** Substantially implemented, but not yet complete. The page/service ownership integration and visible terminal/error feedback need I1–I3; M1 is a smaller multi-blocker presentation gap. Task 11 candidate acceptance is unfinished with a failed artifact gate and deliberate manual/CI Pending statuses.

**Quality verdict:** With fixes. Architecture, isolation, transactional state and regression depth are strong; no critical delivery/data-corruption regression was found. Passing the current full suite does not cover the missing view/composition contracts above.

**Ready to merge? With fixes.** Resolve the Important findings and required artifact/code evidence for the resulting candidate, then complete the planned documentation closeout. This review is not release acceptance.


## Post-fix scoped re-review

**I1 — Trial hides terminal notices, including silent/empty capture and polish fallback. — ADDRESSED.** `Sources/flowtype/Settings/TrialSessionPresenter.swift:7` registers a weak presenter receiver as a real controller observer; `:75` accepts only the current generation/session and retains the notice separately from the result. `:55`/`:63` clear both on start/cancel. `Sources/flowtype/Settings/TrialSessionView.swift:78` renders the notice alongside fallback text. `Sources/flowtype/Testing/TrialSessionSelfTests.swift:343` drives actual ASRStage clearlySilent/emptyCapture and failing PolishStage through the injected presenter/controller, verifies exact messages, fallback coexistence, persistence beyond capsule dismissal, next-attempt/cancel invalidation, unchanged isolated history/dictionary, no delivery summary/autocopy, and zero live effects. The unchanged controller transition was checked specifically for observer timing: `Sources/flowtype/Core/PipelineOrchestrator.swift:633` notifies before notice cancellation clears active ownership at `:649`, so the new acceptance guard can accept the legitimate terminal notice.

**I2 — Main-page recreation bypasses retained cloud-check transport ownership. — ADDRESSED.** `Sources/flowtype/Settings/CloudASRConnectionCheck.swift:142` provides an application-lived shared owner containing separate live/draft checkers and revision namespaces; its configuration subscription at `:155` invalidates stale conclusions even with no page present. Existing reservation retention/drain remains intact. Production `Sources/flowtype/Settings/SettingsWindowController.swift:28` uses the same root handoff tested at `:34`; `Sources/flowtype/Settings/MainWindowView.swift:141` resolves the retained owner and passes it to the actual settings branch at `:156`. `Sources/flowtype/Settings/SettingsView.swift:34` requires an explicit owner in its injected constructor and observes its checker instances instead of replacing them. `Sources/flowtype/Testing/ProviderDraftCheckSelfTests.swift:184` reconstructs both root/page composition with an isolated injected owner and leaf factory, checks identity before actions, blocks duplicate transports across tab/window recreation, suppresses late publication/configuration mutation, requires a fresh explicit test after drain, keeps live/draft conclusions independent, and exercises absent-page configuration invalidation. The explicit owner injection and production shared fallback together close the original wiring defect.

**I3 — Failed history privacy/destructive writes have no user-visible failure state. — ADDRESSED.** `Sources/flowtype/Settings/HistoryPresentation.swift:66` defines operation-specific mutation messages; delete/clear/reset publish failures at `:128`, `:135`, and `:143`, preserving existing data and selection on failure. `Sources/flowtype/Settings/HistoryPage.swift:29` displays the distinct failure banner; the clear alert at `:42` invokes model confirmation. Clear/reset consume confirmation before attempting writes, and reset still requires first and final confirmation. `Sources/flowtype/Testing/NativeHistorySelfTests.swift:344` uses real rejecting SQLite triggers, including reset transaction rollback, and verifies authoritative/cache text, statistics and selection, unchanged read state, the visible model failure, no implicit retry after repair, renewed confirmations, and successful explicit retry.

**M1 — A denied microphone masks a concurrent missing-engine blocker. — ADDRESSED.** `Sources/flowtype/Settings/ReadinessPresentation.swift:26` makes a permission-neutral snapshot solely for presentation and reuses the existing domain classifier to add the secondary engine issue, while the original level still controls the primary title. `Sources/flowtype/Testing/ReadinessPresentationSelfTests.swift:23` covers denied microphone plus unavailable engines with AX granted and denied, unchanged microphone-first classification, engine recovery destination, and no permission attempts. The unchanged classifier was inspected only to verify this projection preserves engine rules (`Sources/flowtype/Core/Readiness/ReadinessSnapshot.swift:53`).

**M2 — Empty selected range is described as first-ever use. — ADDRESSED.** `Sources/flowtype/Settings/OverviewPage.swift:55` chooses first-use text only when the full dataset is empty, and the existing selected-summary condition at `:34` still controls whether the guide appears. Statistics formulas and full annual heatmap inputs remain untouched. `Sources/flowtype/Testing/NativeContentSelfTests.swift:61` covers empty 7/30-day ranges with older annual activity and the truly empty dataset.

**New Breakage in the Fix Diff — None identified.** No new Critical, Important, or Minor source defect found in the packaged 16-file fix from f974781 to f3ac69f. The complete packaged diff was inspected in bounded passes; unchanged code was consulted only for the named observer-timing, configuration-publication, and readiness-classification risks.

**Out-of-Scope Observations — None newly identified.** M3 documentation attribution/status/evidence remains controller-owned. This scoped verdict does not establish renewed full code/artifact gates or physical/manual/remote CI acceptance; the reported manual, CI and renderer gaps remain Pending.

**Check — Implementer claims verified against named logs without rerunning suites.** `build/native-final-fix-red.log:59` records 896 passed/19 failed: 16 product failures across I1/I3/M1/M2 and three explicitly disclosed test-authoring claim failures. `build/native-final-fix-ownership-red-build.log:8` records the missing new composition boundary; this is compile-time contract evidence, not runtime evidence. `build/native-final-fix-ownership-red.log:1` records the three absent-page configuration/stale-result failures, with 929 passed/3 failed at `:43`. `build/native-final-fix-presentation.log:40` records 918 passed/0 failed. Final covering results are `build/native-final-fix-native-green.log:40` (938/0), `build/native-final-fix-delivery-green.log:2` (714/0), and `build/native-final-fix-silence-green.log:2` (1014/0). `build/native-final-fix-green-build.log:13` records build completion in 26.14 seconds; no warning/error/failure markers were found in these final focused logs. Covering regression bodies match the stated contracts; no test, provider, microphone, permission, model, clipboard, installation, or other live action was run during this review. Only this requested scratch report was written; source, index, HEAD and branch state were not mutated.

**Fix round — All findings addressed, no new Critical/Important breakage.** I1, I2, I3, M1 and M2 are closed for stable source candidate f3ac69f1a586f5d4c61b0acd10e9ef22c650c43f; no scoped finding remains open.


## Execution rulings (exhaustive)

1. Task 1: Ruling: Add native-client-only to RuntimeEnvironment self-test filter allowlist — planned focused CLI cannot run without it — if wrong, harmless extra accepted self-test filter requires removal. NavigationRequest is supplied to detail pages through environment; Tasks 5/9/10 own their receivers.

2. Task 1: Ruling: Apply layout-token-only changes to OverviewPage.swift and SettingsView.swift now — hardcoded gutters/caps otherwise leave the foundation unimplemented — if wrong, minor sequencing rework; grouping/content remain Tasks 5/10.

3. Task 1: Ruling: Canonicalize mktemp validation root with realpath — /tmp is a macOS symlink and M5 correctly rejects noncanonical explicit roots — if wrong, command-only correction; production isolation remains unchanged.

4. Task 3: Ruling: Extend SettingsNavigation/MainWindowView narrowly to defer external navigation while a modified provider editor is active — native sheet Cancel alone cannot protect a draft when parent switches pages — if wrong, extra navigation guard maintenance; tests must pin keep/discard and request identity. This implements approved spec section4/6.3 rather than deferring lost edits.

5. Task 7: Ruling: Reject explicit start while canceled stage drains; do not queue automatic restart — approved spec requires one resource owner until cleanup — if wrong, users must press start again after brief busy state. Two M4 cancel-inside-Injection regressions must assert drain blocks then explicit restart, preserving once-only uncertain/history/card contracts; non-cancel reentrancy unchanged.

