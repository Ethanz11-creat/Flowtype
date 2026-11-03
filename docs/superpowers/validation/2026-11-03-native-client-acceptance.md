# Native client acceptance — 2026-11-03

Scope: Tasks 1–11 of the approved native client experience design. This is implementation and a workspace candidate, without installation or release. Native offscreen PNGs demonstrate appearance only. Physical window, focus, keyboard, system appearance transitions, reduced motion, audio devices, permissions, provider network and cross-application delivery require actual candidate observations and remain Pending.

## Automatic contracts from design §12

| Contract | Tasks | Focused evidence / test groups |
| --- | --- | --- |
| 1. Open-window navigation, repeated requests, draft navigation guards, no incidental effects | 1, 3, 5, 8, 11 | NativeNavigationSelfTests; ProviderDraftSelfTests; ProviderDraftCheckSelfTests; NativeRecoveryNavigationSelfTests; isolated Settings dependencies |
| 2. Three modes, disclosure editing, disabled context preserves values, local ASR plus cloud polish disclosure | 2, 5, 6 | ReadinessPresentationSelfTests; SettingsChangeSelfTests; NativeModelPresentationSelfTests |
| 3. Draft cancel/UUID/revision, late test results, local validation versus remote recognition | 3, 4, 11 | ProviderDraftSelfTests; ProviderDraftCheckSelfTests; NativeRecoveryNavigationSelfTests LLM normalization |
| 4. Field-specific hotkey side effects, save versus network action | 6 | SettingsChangeSelfTests; SettingsChangeCoordinator injected effects |
| 5. Multiple permission blockers, denial/recovery and degraded capability | 2, 5, 11 | ReadinessPresentationSelfTests; existing M4RecoveryControllerSelfTests; RecoveryEffects preserves explicit OS permission actions |
| 6. Trial isolation, mutual resource exclusion, cancellation and late callbacks | 7, 8 | TrialSessionSelfTests; OnboardingFlowSelfTests; existing onboarding delivery/cancellation/teardown regressions |
| 7. History delivery, textless actions, clear/reset semantics, dictionary and effective style | 9, 10 | NativeHistorySelfTests; NativeContentSelfTests.dictionaryAndStyleReflectEffectiveState |
| 8. Existing overview formulas, annual heatmap, range/zero handling, reactive refresh | 10, 11 | NativeContentSelfTests.overviewRangeAndSparseData; NativeRecoveryNavigationSelfTests odd chart midpoint |

Integration retains existing recovery policy, card/session/generation ownership, resource/audio retry gate, 20-second stop budget, delivery latch, clipboard protection and history semantics. Captured failure destination contains only a settings section/model target or known profile UUID. A cloud failure without a known captured profile goes to speech; history without a persisted available record ID opens the normal list.

## Native rendering observations

Development-only CLI: `FlowType --self-test --native-client-previews-only --validation-root <canonical-empty-temporary-root>`. Release builds do not expose this filter. The runner uses `NSHostingView` and offscreen `cacheDisplay`, no `NSWindow`, activation, application launch, screen capture or guard bypass. All synthetic stores and generated PNGs first live inside the validation root. Shell orchestration copies only generated PNGs and manifest into ignored `build/native-client-previews`.

The actual MainWindow sidebar and injected production OverviewPage, SettingsPage, HistoryPage, VocabPage and StylePage are rendered. Settings consume real navigation requests with bounded layout settling. Synthetic data includes long mixed-language provider/model names, history text, dictionary phrases/notes and custom style prompts; empty overview/history/dictionary and history-read-error views are included. Manifest records viewport, destination, appearance and scroll position. Default/minimum/wide are 1120×760, 1040×700 and 1440×900 pt. Pixel output uses AppKit backing scale.

Controller inspected actual overview/default light and wide/dark (including full hourly chart/footer), speech/minimum light, style/default light, general/minimum dark, dictionary/minimum dark, privacy/minimum light and text/default light. Those observations found coherent, unclipped layouts. The recommendation badge discrepancy was traced to eligibility-versus-recommendation presentation and corrected against the existing domain recommendation. Empty/error pages were wrapped in the actual opaque MainWindow host after initial standalone captures exposed transparency; corrected error/empty renders retain the production sidebar/background.

Windowless renderer limits remain explicit: the real history NSTableView reports12 rows and a374×619pt frame, but its `visibleRect` is zero without a live window; rows therefore do not paint. Bounded native run-loop/layout settling did not change this. History list appearance remains Pending (detail/count, error and empty states do render). Offscreen clip document geometry similarly prevents minimum/default lower scrolling. A trial native defaultScrollAnchor seam had no effect and was removed; no duplicate top capture is represented as a lower scroll. The wide900pt overview shows the full hourly chart and footer; physical lower scrolling at minimum/default remains Pending. Offscreen appearance is separate from the M5 physical-window cases below. Trial/draft behavior is covered automatically; no actual microphone or provider trial was executed.

## Candidate and gate evidence

Source commit, source tree, code report, artifact manifest, binary SHA256 and exact workspace app path: Pending until source integration and native visual review complete. The source implementation and this initial acceptance document must be committed before verification. Evidence-only documentation commits after verification must distinguish current HEAD from the candidate source identity.

Planned authorized commands: `scripts/verify.sh --lane code`, then `scripts/verify.sh --lane artifact`, then `scripts/verify.sh --write-manual-template build/native-client-manual.json`. Code runs the full suite once at integration; artifact builds/signs/checks and smoke-tests only `build/FlowType.app`. Neither lane installs the app. Reports are read phase by phase; manual and remote CI remain Pending without matching actual evidence. No release lane is claimed.

## M5 manual matrix — unchanged 41-case schema

The generated JSON template preserves `schemaVersion: 1`, the exact existing IDs and per-case candidate/evidence fields. No screenshot or automatic test marks a manual row Pass. Every case below is unexecuted for this candidate and Pending.

| IDs | Required actual candidate observations | Status |
| --- | --- | --- |
| R1.launch10 | Ten cold launches | Pending |
| R2.sessions20 | Twenty real sessions | Pending |
| R3.axRecovery; R3.micRecovery; R3.noEngine; R3.multipleBlockers | Real permission, readiness and recovery | Pending |
| R4.metadata; R4.switchSource; R4.retry; R4.autoFallback; R4.manualSelection; R4.builtin06; R4.builtin17; R4.importQwen; R4.importWhisper | Actual resource/model source ownership and recoveries | Pending |
| R5.silence; R5.quiet; R5.short; R5.noise | Real audio behavior | Pending |
| R6.layout; R6.focus; R6.displays | Physical minimum/default/wide windows, light/dark/system, long content, keyboard focus, reduced motion and displays | Pending |
| V1.weak; V1.offline; V1.badKey | **Mainline V1:** weak/disconnected network and invalid cloud credentials | Pending |
| V2.textEdit; V2.vscode; V2.chrome; V2.terminal; V2.cursor; V2.safeTargets | **Mainline V2:** cross-application Chinese/English/multiline/emoji delivery and safe targets | Pending |
| V3.formats; V3.concurrentCopy | **Mainline V3:** multiple clipboard formats and concurrent user copying | Pending |
| V4.preparing; V4.recording; V4.asr; V4.polish; V4.injection; V4.postEvent | **Mainline V4:** cancel each stage and late results, including after irreversible delivery | Pending |
| V5.unplug; V5.bluetooth | **Mainline V5:** microphone unplug/Bluetooth loss and next-recording recovery | Pending |

Remote CI: Pending. No matching remote run has been performed or imported. These Pending statuses are deliberate; implementation/code/artifact success is not release acceptance.
