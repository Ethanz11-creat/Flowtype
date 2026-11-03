# SDD ledger — plan: docs/superpowers/plans/2026-11-03-capsule-waveform.md

Base: b86b428. Existing linked worktree verified; branch flowtype-local. Serial, max 1 active child.

Ruling: Latest user explicitly authorized development of the already-discussed capsule and waveform — proceed with execution after writing plan without another approval gate — design refinements beyond spec would require rework.
Ruling: Two meaningful deliverables; focused regression per task, full suite once after combined review — avoids repeating unchanged expensive suites.

## Preflight

| Tasks | Shared file/interface | Producer/consumer and finding |
|---|---|---|
| 1 / 2 | PipelineOrchestrator, SelfTest | T1 adds ownership-scoped visualization frame; T2 must preserve resets/subscriptions when adding progress/notice state. Sequential commits, no conflict. |
| 1 / 2 | AudioVisualizer / previews | T1 owns frame + motion; T2 consumes unchanged visualizer. Preview uses real frame contract. |
| 1 | Internal consistency | Ordered stream with backwards-compatible fixture initializer; bounded buffering applies live path. Pure tests cover amplitude, invalid samples, timing and reset; no ASR change. |
| 2 | Internal consistency | String enum compatibility kept, typed outcome metadata controls timing/copy; existing notice writers audited. Slow signal is nonterminal; recovery size unchanged. Render evidence plus behavior tests cover focus areas. |

Spec coverage: Appearance and waveform → T1/T2; presentation and recovery → T2; acceptance → both and final verification. No missing scope found.

Task 1: pending
Task 2: pending
Final verification: pending

Ruling: Task 2 explicitly includes ASRStage.swift — silent/empty notice metadata must be emitted at source, not inferred by matching Chinese strings. Also register new focused CLI flags in RuntimeEnvironment.swift allowlist.

Task 1: in progress — /root/waveform_impl (gpt-6.1-sol/high), baseline55e5ac8, report task-1-report.md. Parent prepared task-2-context.md, including typed notice source points and generation/reentrancy risks.
Ruling: Honor Reduce Motion as already called out in approved waveform research — direct real-amplitude feedback without travelling diffusion; added to spec/plan and sent implementer.
Final artifact lane must use explicit existing shader: MLX_METALLIB_PATH="$PWD/build/FlowType.app/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib" scripts/verify.sh --lane artifact. Existing shader hash f36b01c44dd5f2d9020deb1ac6ad53dc085de81af19396694c5963ef3a12137f. No downloads.

Task 1 checkpoint: RED12passed/7expected failures captured by implementer; frame transport and pure analytic diffusion implemented, green build underway. API: AudioVisualizationFrame(samples:spectrum:timestamp:), RecordingOutput.visualizationFrames lazy AsyncSequence; controller.visualizationFrame; legacy spectrum adapters preserved. Final report/review pending.

Task 1 implementation:139e123. Final waveform45/0, M4 recovery19788/0, native938/0, build40.78s. Parent read raw final summaries and report. Independent scoped review /root/waveform_review in progress against55e5ac8..139e123. Guarded computed observable frame replaces @Published after real synchronous-cancel test failure; valid interface refinement, no projected publisher is consumed.

Task 1: complete —139e123, independent review specPASS/qualityPASS, no new findings. Retained historical @Published spectrum behavior is outside new frame consumer, not a gate defect.
Task 2: dispatch next, basea7b5d7e (docs amendments after139e123).

Task 2: in progress — /root/capsule_impl gpt-6.1-sol/high. Design choice: separate typed CapsuleNotice, injectable monotonic presentation timing, independent slow-operation/dismiss UUID tokens. First behavioral RED build underway. No SessionState enum expansion and no waveform rewrite.

Task 2 checkpoint: presentation111/0, waveform45/0, native938/0, preview18states40/0 at1×. Parent inspected final recording216×54, permission380×156, uncertain, longsafeconfiguration and preparingdiagnostic PNGs: visible text/actions fit; offscreen material and mask/glow do not establish live-desktop appearance. M4 old goldencopy assertions failed19468/320 after intended resource-aware copy changes; updating expectedcopy while retaining actionmatrix authorized, rerun affectedM4 required.

Task 2: complete —db58ea6, independent specPASS/qualityPASS, no Critical/Important/Minor findings. Final focused111/0+45/0+938/0+19788/0; previews40/0. Reports and18nativePNGs archived explicitly; combined final review next.

Final broad review: complete PASS, gpt-6-astra/high /root/capsule_final_review, no Critical/Important/Minor findings. Parent adjudication: listed livehardware/glass/focus/realcloud manual boundaries accurately remain pending; unrelated preexisting pipeline behavior not silently claimed. Final gates next on clean committed source.

Final code lane started clean at4d8da71354a0400c4108a5784253b8d7e438ba0f, Sources treea084c0ce3c33209ce954da34a6103621703f33ad. Run6B551B82-A340-4ACC-9EBB-43DD5488503C. Do not modify tracked files until lane completes.
Final declined judgments adjudication: hardware voice/cadence, live compositing/focus/multiscreen, actual OS ReducedMotion/energy remain manual; fullcode/artifact resolved by upcoming gates; legacy spectrum/converter behavior unchanged and not a new user regression. No deferred introduced defect.

Final code lane6B551B82-A340-4ACC-9EBB-43DD5488503C: FAIL, buildPass, full25554/1, duration207879ms, source-start/endPass clean4d8da71. Solefailure old SelfTest.swift testStableSessionPresentation expected处理中... vsapprovednew正在处理. Rootcause testcopygolden omitted fromTask2focusedpath; no productfailure. Finalfixround1 resumed /root/capsule_impl for oneexpectedstring+registerexistingtestinfocusedroute, focusedbuild/testonly. Parent will do scopedfreshreview then repeatcompletecode lane once; artifactnotyetstarted. Historicalfailedrunmuststayarchivednotrelabeled.

Final test-onlyfix00bdd2f: independent scopedreviewPASS, no weakening; focusedpresentation114/0. Completecode rerun FF2E0D81-59A2-41BE-BAEA-DD2AD1B66522 PASS:25555/0,stderr0bytes,all7phasesPass,sourcecleanidentical00bdd2f581a4f83a5f0cd290c542c5991380489c /Sources50fe779eb598377251bda42ee463e15d0930fb53. Artifactlane started with explicitknownMLXshader, commandexecsession96460; no trackedmutations until complete.

Final artifact94CE669B-4664-4468-9F46-D2AE228249B5 PASS:22/22 including10smoke, samecleansource00bdd2f. Candidate1.0.0/build384arm64, binary1de063674da591853825fde8b7db0f009c6a55b2e86c1146acc760ff798e085c. Reports exported using allowlistedtool after creatingrequiredemptydestinationdirs (initialmissingdestinationcalls failedwithoutproductchange);52runfilesselectedtotal. NoDB/config/audio/models copied.
Final verification: complete — allauthorizedimplementation/review/localcode/artifactworkcomplete; actualhardware/manualandremoteCIremainPending. Keep preexistinglinkedworktree/branchperplan; no merge/push/install/publish. Finaldocs/hashcheckandcommitnext.
