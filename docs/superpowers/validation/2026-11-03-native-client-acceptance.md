# Native client acceptance — 2026-11-03

Scope: Tasks 1–11 of the approved native client experience design and the independently reviewed consolidated fix wave (trial notices, retained check ownership, history mutation feedback, combined readiness and empty-range guidance). This is implementation and a workspace candidate, without installation or release. Native offscreen PNGs demonstrate appearance only. Physical window, focus, keyboard, system appearance transitions, reduced motion, audio devices, permissions, provider network and cross-application delivery require actual candidate observations and remain Pending.

## Automatic contracts from design §12

| Contract | Tasks | Focused evidence / test groups |
| --- | --- | --- |
| 1. Open-window navigation, repeated requests, draft navigation guards, no incidental effects | 1, 3, 5, 8, 11 | NativeNavigationSelfTests; ProviderDraftSelfTests; ProviderDraftCheckSelfTests; NativeRecoveryNavigationSelfTests; isolated Settings dependencies |
| 2. Three modes, disclosure editing, disabled context preserves values, local ASR plus cloud polish disclosure | 2, 5, 6 | ReadinessPresentationSelfTests; SettingsChangeSelfTests; NativeModelPresentationSelfTests |
| 3. Draft cancel/UUID/revision, late test results, local validation versus remote recognition | 3, 4, 11 | ProviderDraftSelfTests; ProviderDraftCheckSelfTests; NativeRecoveryNavigationSelfTests LLM normalization |
| 4. Field-specific hotkey side effects, save versus network action | 2 | SettingsChangeSelfTests; SettingsChangeCoordinator injected effects |
| 5. Multiple permission blockers, denial/recovery and degraded capability | 2, 5, 11 | ReadinessPresentationSelfTests; existing M4RecoveryControllerSelfTests; RecoveryEffects preserves explicit OS permission actions |
| 6. Trial isolation, mutual resource exclusion, cancellation and late callbacks | 7, 8 | TrialSessionSelfTests; OnboardingFlowSelfTests; existing onboarding delivery/cancellation/teardown regressions |
| 7. History delivery, textless actions, clear/reset semantics, dictionary and effective style | 9, 10 | NativeHistorySelfTests; NativeContentSelfTests.dictionaryAndStyleReflectEffectiveState |
| 8. Existing overview formulas, annual heatmap, range/zero handling, reactive refresh | 10, 11 | NativeContentSelfTests.overviewRangeAndSparseData; NativeRecoveryNavigationSelfTests odd chart midpoint |

Integration retains existing recovery policy, card/session/generation ownership, resource/audio retry gate, 20-second stop budget, delivery latch, clipboard protection and history semantics. Captured failure destination contains only a settings section/model target or known profile UUID. A cloud failure without a known captured profile goes to speech; history without a persisted available record ID opens the normal list.

## Native rendering observations

Development-only CLI: `FlowType --self-test --native-client-previews-only --validation-root <canonical-empty-temporary-root>`. Release builds do not expose this filter. The runner uses `NSHostingView` and offscreen `cacheDisplay`, no `NSWindow`, activation, application launch, screen capture or guard bypass. All synthetic stores and generated PNGs first live inside the validation root. Shell orchestration copies only generated PNGs and manifest into ignored `build/native-client-previews`.

The actual MainWindow sidebar and injected production OverviewPage, SettingsPage, HistoryPage, VocabPage and StylePage are rendered. Settings consume real navigation requests with bounded layout settling. Synthetic data includes long mixed-language provider/model names, history text, dictionary phrases/notes and custom style prompts; empty overview/history/dictionary and history-read-error views are included. Manifest records viewport, destination, appearance and scroll position. Default/minimum/wide are 1120×760, 1040×700 and 1440×900 pt. Pixel output uses AppKit backing scale.

Initial controller inspection at c058190 covered actual overview/default light and wide/dark (including full hourly chart/footer), speech/minimum light, style/default light, general/minimum dark, dictionary/minimum dark, privacy/minimum light and text/default light. Those observations found coherent, unclipped layouts. The recommendation badge discrepancy was traced to eligibility-versus-recommendation presentation and corrected against the existing domain recommendation. Empty/error pages were wrapped in the actual opaque MainWindow host after initial standalone captures exposed transparency; corrected error/empty renders retain the production sidebar/background.

Final source f3ac69f regenerated all **56 PNGs**, renderer **3 passed / 0 failed**, with source/debug-binary identity in `build/native-client-previews/source-identity.json`. Controller re-inspected final overview/default-light, speech/minimum-light and history-error/default-dark; their visible content remained coherent and unclipped. New trial-notice and mutation-failure presentation contracts were verified through real injected presenter/page-model behavior; physical interaction is still Pending.

Windowless renderer limits remain explicit: the real history NSTableView reports12 rows and a374×619pt frame, but its `visibleRect` is zero without a live window; rows therefore do not paint. Bounded native run-loop/layout settling did not change this. History list appearance remains Pending (detail/count, error and empty states do render). Offscreen clip document geometry similarly prevents minimum/default lower scrolling. A trial native defaultScrollAnchor seam had no effect and was removed; no duplicate top capture is represented as a lower scroll. The wide900pt overview shows the full hourly chart and footer; physical lower scrolling at minimum/default remains Pending. Offscreen appearance is separate from the M5 physical-window cases below. Trial/draft behavior is covered automatically; no actual microphone or provider trial was executed.

## Candidate and gate evidence

The final source candidate is **f3ac69f1a586f5d4c61b0acd10e9ef22c650c43f**, Sources tree **a2a5c5d3c823c13ad29779fe5ad0c08c2a576dda**. The verifier recorded clean, identical source identities at the start and end of both lanes. Later evidence-only documentation commits do not change this candidate's source or relabel the binary as built from a later HEAD.

| Layer | Result | Evidence |
| --- | --- | --- |
| Implementation / review | Complete for source; no open scoped findings | [Review and fix archive](2026-11-03-native-client-review.md) |
| Code | **Pass — 25,393 passed / 0 failed**, all 7 phases Pass | `build/verification/E556FF78-F118-4883-A524-1603896EF5F2/verify-report.json`; [archived report](2026-11-03-native-client-code.json) |
| Artifact | **Pass — all 22 phases, including complete signature/Metal/resource checks and 10 smoke runs** | `build/verification/BB7067C9-5E2B-4339-B0BB-E677B62A1884/verify-report.json`; [archived report](2026-11-03-native-client-artifact.json) |
| Manual | **Pending — all 41 cases** | `build/native-client-manual-final.json`; [candidate-bound Pending snapshot](2026-11-03-native-client-manual-pending.json) |
| Remote CI | **Pending** | No matching remote run was performed or imported |

Workspace app: `/Users/yiheng/pycode/flowtype-local/build/FlowType.app`. Binary SHA256: **45ef06165ab3f2ff3ff86193a9fa2eda4c9d972fd9f46613295d724b1aa8bee4**. Manifest: `build/FlowType.manifest.json`; build metadata is in `Contents/Resources/FlowTypeBuild.json`. Neither lane installed or replaced the running application. These results establish a local candidate, not completed release acceptance.

Commands executed on committed, stable source:

```sh
scripts/verify.sh --lane code
MLX_METALLIB_PATH="$PWD/build/FlowType.app/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib" scripts/verify.sh --lane artifact
scripts/verify.sh --write-manual-template build/native-client-manual-final.json
```

The existing explicit shader is 146,852,000 bytes, MTLB, SHA256 `f36b01c44dd5f2d9020deb1ac6ad53dc085de81af19396694c5963ef3a12137f`; no shader/model download or cache discovery was used. Generated manual template keeps schemaVersion 1 and exact 41 IDs, then receives only the actual final artifact's candidate fields; no manual row is marked Pass. Archived JSON reports preserve original relative child-evidence paths; those streams remain under each corresponding `build/verification/<runID>` directory.

Earlier attempts remain historical evidence: c058190's first code run (ABC9F37A-A64B-468D-9B7C-756AFB774156) failed 27 assertions because old tests restarted while cancellation-resistant stages deliberately held the resource. Deterministic drain/explicit-restart tests corrected that ordering without changing production policy; f974781 code then passed 25,299/0. An f974781 artifact invocation (3FD4343E-5AF9-40B6-AE23-D03D0C93FAEE) failed shaderInvalid because the controller omitted required MLX_METALLIB_PATH; the explicit-input rerun (0CC8C386-34D5-4001-BD58-F2C4D7FE1B13) passed. The whole-feature review then required the consolidated source fix, so none of those older reports is reassigned to f3ac69f.

Final focused evidence is supplementary: native **938/0**, delivery **714/0**, silence **1,014/0**, build without warnings. Full review found I1/I2/I3 and M1/M2; one consolidated fix and fresh scoped re-review closed all five with no new breakage. Physical parent-window draft dismissal, keyboard/focus/motion/display behavior and windowless-renderer gaps were explicitly declined as unverified and remain in the physical acceptance matrix. No ignored review finding is presented as a pass.

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
