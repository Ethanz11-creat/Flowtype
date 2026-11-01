# SDD ledger — plan: docs/superpowers/plans/2026-11-01-m2-a-model-recovery.md

Owner approved all three M2 plans and chose subagent-driven development. Worktree verified linked, branch flowtype-local. M2 start HEAD7964d02; product source2588d56. Execute A→B→C continuously; no push/merge/model/cache deletion.

## Pre-flight
| Tasks | Shared file/interface | Check / resolution |
| --- | --- | --- |
| A1→A2 | ModelProvisionError, metadata preflight, ModelLocator | Error names/summary match; A1 preflight check is independently testable, coordinator loader-zero assertion integration belongs A2. |
| A1→A3 | ModelLocator/source labels | Explicit preset identity consumed unchanged; presentation source needs actual DownloadSource parameter beyond abbreviated plan signature. |
| A2→A3 | activeLease, status, request, failure | A2 produces leases; A3 switches router/readiness to them. Keep legacy startup compatibility through A2. |
| A1/A2→C | model detection/lease | A1 existing preset locator stays narrow; C inspector is separate and only C uses full imported descriptors. |
| A1 internal | Tests vs production | Preflight object cannot itself invoke weights; test direct rejection in A1, loader-zero integration in A2. |
| A2 internal | Lifetime/old model | Each candidate owns its provider; active immutable lease preserves old provider, no early unload. |
| A3 internal | Presentation inputs | Source not included in abbreviated make signature although display/command require it; add source:DownloadSource and needed destination, retaining pure API. |

Ruling: A1 loader-zero integration assertion is owned by A2, while A1 asserts failed preflight never succeeds — coordinator does not exist in A1; cost if wrong: integration gap until A2, explicitly tested there.
Ruling: A3 presentation API may include source/destination beyond abbreviated signature — truthful source and executable command require them; cost if wrong: small interface revision.
Ruling: inherited recorded1327/0 source baseline is supplemented by one sequential baseline run required by worktree setup; no repeated unchanged-source checks after it.

## Status
Task1 pending; Task2 pending; Task3 pending. Subsequent B(3) and C(4) use their own plan workspaces/ledgers.

Baseline: sequential swift build exit0(25.74s), swift run FlowType --self-test exit0(1327passed/0failed); logs baseline-build.log/baseline-self-test.log. Source before all edits.
Task1 started BASE7964d02, implementer /root/m2a_task1, gpt-6.1-sol high; no inherited history.
Ruling: ModelProvisionError cases carry optional safe summary with default nil; computed summary/isRetryable, network retryable incl429/5xx, deterministic4xx metadataInvalid; cancellation stays CancellationError — binds A2 integration; cost if wrong: error API adjustment.
Ruling: configured custom paths cannot claim selected/recommended preset from size alone; A1 accepts known preset path or exact metadata identity, A2 must fail explicit unresolved custom offline selection without silent download — avoids false identity; cost if wrong: older ambiguous imports require re-selection/detection in C.
Task1 implementation abc5eea, RED foundation missing APIs, self-review RED metadata conflict1431/1, final GREEN build33.82s +self-test1432/0. Report task-1-report.md. Production error/preflight files moved unchanged to planned ModelProvisioning directory after verification (no semantic change). Review package review-7964d02..abc5eea.diff; reviewer /root/m2a_review1 gpt-6.1-sol high; review pending.
Task1 review: Spec compliant, Quality Approved; noCritical/Important. CannotVerify loader-zero/unresolved custom paths resolved as assigned A2 requirements (not product claims).
Task1: minor (deferred): URLProtocol fixtures don't exercise actual redirect callback interception; manual redirect policy tested, add callback fixture if final review finds material risk.
Task1: minor (deferred): preexisting AppLogger compiler warning remains (unchanged source).
Task1: complete (commits7964d02..abc5eea, review clean)
Task2 started BASEabc5eea; implementer /root/m2a_task2 (gpt-6-astra high); task-2-brief.md authoritative, A1 API and unresolved-custom ruling carried.
Task2: Ruling: allow minimal thread-safe registry provider adoption bridge until A3 switches router/readiness to leases — isolated candidate load otherwise leaves current legacy router looking at unloaded original provider; production shared commit only, no mutation from test coordinators; cost if wrong: interim API removed/adjusted in A3. Registry storage/access must be synchronized because @uncheckedSendable reads occur off-main. Carry bridge interface into A3 dispatch.
Task2 first GREEN1467/0; self-review additional RED/GREEN underway for unknown explicit preset IDs and downloader cancellation with retained ready model.
Carry to A3: LocalModelPicker.isDownloading currently checks only currentDownload preset id, so completed/failed records incorrectly showCancel; bind onlypending/downloading/verifying. Explicit replacement UI must call perform(request), not loadModel(provider:) bootstrap (loaded fast path intentionally preserves activeLease). Registry thread-safe adoption bridge is interim dependency.
Task2: Ruling: remove redundant boot-time HF_ENDPOINT assignment in App/FlowTypeApp — coordinator must own scoped endpoint mutation/restoration; cost if wrong: old startup behavior requires revisiting, no network policy change intended.
Task2: Ruling: keep legacy loadDownloadedPreset initializer signature but adapt callback through shared coordinator loader (isolated stub lease/provider for callback-only test success), removing separate test-only handleDownloadCompleted transitions — M1 producer regression must exercise real lifecycle; UI terminal retry affordance can be true while typed isRetryable=false for automatic loops; cost if wrong: fixture adapter/API adjustment. Production default never uses stub. Implementation agent notified before DONE.
Task2 implementation b6397fa; final sequential build exit0(23.80s), self-test1489/0, clean tracked tree. Review package review-abc5eea..b6397fa.diff; fresh reviewer /root/m2a_review2 (gpt-6-astra high), review pending.
Task2 review: Spec issues / Quality Needs fixes, twoImportant bootstrap defects (unknown explicit selection accepts unrelated local result; auto local primary is relabeled offlineImport and loses fallback). task-2-review.md. CannotVerify router/readiness/UI consumption confirmed planned A3 dependency. Minor inherited warning tracked underA1.
Task2 fix round1/5 started BASEb6397fa, original implementer /root/m2a_task2; both findings forwarded without downgrading.
Task2 fix1 Ruling: preserve existing pre-onboarding no-automatic-download policy; existing local bootstrap may run offline-only before onboarding, without network fallback. After onboarding automatic local preset failure retains normal fallback eligibility — avoids newly downloading before setup consent; cost if wrong: pre-onboarding recovery requires setup completion or explicit action.
Task2 fix1 implementation964b616; RED1497/7 reproduces both findings; final GREEN1504/0, sequential build/self-test exit0, clean tree. Scoped re-review /root/m2a_rereview2 gpt-6.1-sol high, diff review-b6397fa..964b616.diff pending.
Task2 fix1 re-review: bothImportant ADDRESSED; no new breakage/out-of-scope findings. UnknownID rejected before ordinary resolution, valid explicit paths retained; local preset preserves automatic/manual origin and fallback after onboarding. Evidence1504/0 confirmed, tests not repeated.
Task2: complete (commitsabc5eea..964b616, fix round1 clean)
Task3 started BASE964b616; fresh implementer to follow; task-3-brief.md authoritative.
Task3 implementer /root/m2a_task3 gpt-6.1-sol high, no inherited history; prior interfaces, terminal downloader UI concern, pre-onboarding ruling and pendingV carried in dispatch.
Controller metadata probe (exact product preflight classes, source964b616, HEAD-only CFNetwork, UTC2026-11-01T16:17:00Z): mirror both presets metadataInvalid308; official both presets200 metadataPass after relative redirects. Raw safe log metadata-probe.log. No weights/download/GPU/appGUI claims. A3 implementer instructed to include actual result in M2 evidence. Standalone compile default-target regionCode deprecation only (package macOS15 unaffected).
Task3 implementationc74daaf; final build28.19s exit0 +self-test1543/0. Report task-3-report.md; actual GUI/models Pending, probe included in evidence. Fresh task reviewer /root/m2a_review3 gpt-6-astra high, diff review-964b616..c74daaf.diff pending.
Task3 review: twoImportant findings, Spec issues / Quality Needs fixes; failed folder import Retry activates without persisting selection; cancel fallback with retained06 falsely labels success. Full findings task-3-review.md. GUI/model/V CannotVerify resolved as explicit Pending, not runtime claims. Minor inherited warning alreadytracked.
Task3 fix round1/5 BASEc74daaf, original implementer /root/m2a_task3 to fix both. BroaderA review waits correctedHEAD.
Task3 fix1 implementation26e10c7; RED1553/6 repro both, final sequential build26.95s exit0 +self-test1559/0. Fresh scoped reviewer /root/m2a_rereview3 gpt-6.1-sol high with review-c74daaf..26e10c7.diff, pending.
Task3 fix1 re-review bothImportant ADDRESSED, no newbreakage/out-ofscope. ModelRecoveryActions offlineRetry verifies+persists onlysuccess; cancel clearsfallbackflag bothbranches; recorded1559/0 confirmed without rerun.
Task3: complete (commits964b616..26e10c7, fixround1 clean)
A staged whole-plan review pending beforeB; retainworkspace until wholeM2 cross-plan closeout and committedrulings.
A stagedreview /root/m2a_stage_review: threeImportant, approvalWithfixes; findings stage-review.md. Terminaldiagnostics/failedsource lost; overrideclear leavesofflineintent incllegacy noaction; provideropaque wrappers falselynetworkretry. Fresh stronger fixagent to address all in ONE staged-final fixdispatch, then scopedreview. Declineditems: actualruntime/V remainPending, B/C later; acceptedasboundaries notdiscardedrequirements.
Controller releasebundle build source26e10c7 exit0, stage-app-build.log; NOT launched (PID10836 still oldmappedsource2588d56). Must rebuildafterstagefix beforeactualGUI.
A stagedfix implementer /root/m2a_stage_fix gpt-6-astra high DONEeb840f8; initialRED1582/33, fresh-lease-removal mutationRED1612/7, finalGREEN1619/0 with build23.48s exit0. Scopedreview /root/m2a_stage_rereview gpt-6-astra high, diff review-26e10c7..eb840f8.diff pending. Fixreport stage-fix-report.md.
A stagedfix scopedreview: allthreeImportant ADDRESSED; no newCritical/Important orout-ofscope; implementation-stage progression Approved. Evidence1619/0 confirmedwithout testrepeat. Deferrednative redirectcallbackfixture and inheritedwarning retainedforwholeM2review. GUI/fullmodels/V stillPending.
M2-A implementation-stage complete at eb840f8; B mayproceed. Keepignoredworkspace untilM2final/archive rulings.
