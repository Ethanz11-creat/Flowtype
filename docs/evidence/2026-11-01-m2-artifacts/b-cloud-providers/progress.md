# SDD ledger — plan: docs/superpowers/plans/2026-11-01-m2-b-cloud-providers.md

Approved M2 execution, A→B→C; existing linked worktree flowtype-local. Task execution awaits A final gate; planning artifacts only here meanwhile. No push/merge/history rewrite or real credential reads.

## Pre-flight
| Tasks | Shared file/interface | Check / resolution |
| --- | --- | --- |
| B1→B2 | vendor capabilities, endpoint, profile config | B1 pure default/decoding/validation consumed by B2 builder and immutable request configuration. Existing profile identity and values retained. |
| B1→B3 | profile UUID, vendor defaults | UI binding by UUID; creation defaults not applied during editing/decoding. |
| B2→B3 | validateConfiguration / testConnection, health identity | Pure validation separate from paid synthetic test; test token checks revision, health snapshots include effective capabilities. |
| B1 internal | OpenAI capabilities vs official source restriction | Minimum file/model/response_format=json only until verified official optional fields; no implied online support. |
| B2 internal | test language/prompt wording vs minimal OpenAI | Test supported-capability gating, but OpenAI optional language/prompt remain disabled absent verified contract; custom explicit opt-in tests cover field generation. |
| B3 internal | check token vs duplicated tests | Per-profile revision invalidation and single in-flight operation; token has no credential. Pure check zero transport, WSS boundary explicit. |

Ruling: OpenAI first-version capabilities disable optional language/prompt/temperature until official contract is successfully verified; tests should assert that restriction and use custom opt-in fixtures to cover enabled fields — spec's explicit official-document limitation binds over ambiguous B2 'explicit language/prompt' test phrase; cost if wrong: optional functionality deferred, mandatory minimum unaffected.
Ruling: custom JSON response expectation does not require sending response_format unless its explicit capability permits it — servers may return JSON by default; capability is authoritative for wire fields; cost if wrong: user enables the field in advanced configuration.

## Status
Task1 pending; Task2 pending; Task3 pending.
M2-A implementation gate passed at eb840f8, final source1619/0; actualGUI/weights/V Pending remain mainline. Task1 started BASEeb840f8, fresh standard implementer to follow. No repeat baseline needed.
Task1 implementer /root/m2b_task1 gpt-6.1-sol high, no inheritedhistory. Brief authoritative; constraints/rulings/API minimum contract carried.
Task1 implementation418c496, finalbuild23.30s +self-test1760/0. Briefabbreviated files omitted plan CloudProviders/ directory; controller requested unchangedsource relocation of2newfiles to planned directory beforefreshreview, no unchangedfullsuite repeat warranted. Report task-1-report.md.
Task1 relocationfb2ac03, 100%renames0linechanges, diffcheckclean; freshreviewer /root/m2b_review1 gpt-6.1-sol high, review-eb840f8..fb2ac03.diff pending. FullsourceGREEN1760/0 unchanged; no redundanttestrerun.
Task1 reviewNeedsfixes: Important explicitoverflowingport becomesnilaccepted; task-1-review.md. Fixround1/5 BASEfb2ac03 originalimplementer /root/m2b_task1 toaddHTTPS/WSSoverflowfixtures andrejectexplicitnonparseableports. Existingwarningsminor; noCannotVerifygaps.
Task1 fix1 de79912, overflowRED4failures, finalGREEN1782/0 +buildexit0; IPv6/encodedpathpreserved. Freshscopedreview /root/m2b_rereview1 gpt-6.1-sol high, diff review-fb2ac03..de79912.diff pending.
Task1 fix1 re-review ADDRESSED; no newbreakage/outofscope; portauthority distinction preservesIPv6/encodedpath, recorded1782/0 verified. Task1: complete (commitseb840f8..de79912, fix1clean).
Task2 started BASEde79912; fresharchitecture/securityimplementer tofollow. No repeatedbaseline.
Task2 implementer /root/m2b_task2 gpt-6-astra high (security/asyncsnapshot integration), no inheritedhistory; B1interfaces, exactCloudProviderspath, minimalOpenAIruling androutingcontracts carried.
Task2 implementationdf1f439: RED1845/22, finalbuild23.10s +self-test1876/0, clean trackedtree. Freshreviewer /root/m2b_review2 gpt-6-astra high with review-de79912..df1f439.diff pending. Reporttask-2-report.md.
Task2 handoff toB3: nonisolatedvalidateConfiguration pure; HTTPtestConnection uses8000syntheticzeros samebuilder; WSS onlylocalvalidation; .failure(.cancelled) fornonthrowingtest, transcribeCancellationError. Rejectallsourceredirects, usersneedfinalendpoint. fieldcaps/vendor capturedinhealthidentity. Noactualvendor successclaimed.
Task2 reviewNeedsfixes oneImportant WSSsurroundingwhitespacepasseslocalcheckbutactualrecordingrejects; task-2-review.md. Fix1/5 BASEdf1f439 originalimplementer /root/m2b_task2; actualV1Pending andB3UIownershipcross-taskCannotVerifyresolvedasassignedlater. Existingwarningminor.
Task2 fix1 042706e, RED1884/10 whitespacecheck/runtime mismatches; finalbuild23.86s +self-test1894/0, clean. Scopedreview /root/m2b_rereview2 gpt-6.1-sol high, review-df1f439..042706e.diff pending.
Task2 fix1 re-review ADDRESSED; no newbreakage/outofscope, pureactualRealtimeASRConfiguration check nowshared bybothvalidation/testing, recorded1894/0 verified. Task2: complete (commitsde79912..042706e, fix1clean).
Task3 started BASE042706e, freshUIintegrationimplementer tofollow; actualGUIcontrolleraftercommit, runtimeV stillPending.
Task3 implementer /root/m2b_task3 gpt-6.1-sol high no inheritedhistory; B1/B2API/rulings, WSSboundary andUUID/revision/busyownership carried. WorkerGUI-Pending, controllerlater.
Task3 implementation2d3b99e: missingAPIRED, queued-clickbehaviorRED1954/1, finalbuild29.61s+self-test1957/0; clean trackedtree. Freshreviewer /root/m2b_review3 gpt-6-astra high, review-042706e..2d3b99e.diff pending. ActualGUI/VPending noted; sharedUIaction reservesrevision/busysynchronously andskipsobsoletequeuedupload.
Task3 reviewSpeccompliant/QualityApproved; noCritical/Important. UUIDbinding, synchronousrevisionbusyownership, WSSboundary/capabilitycopy checked; GREEN1957/0 logsverifiedwithout rerun. Minorinheritedwarningalreadytracked. CannotVerifyGUI/livevendorvariantsresolvedasexplicitPending, controllerattemptlater.
Task3: complete (commits042706e..2d3b99e, reviewclean).
B stagedwhole-planreview pendingbeforeC.
B stagedreview /root/m2b_stage_review Needsfixes:2Important (actualWSSboundarybypassesstrictURLcontract; SFpresetpickerremoved/TeleSpeechmissing). stage-review.md. Freshstagefixagent willaddressbothinONEdispatchthenfocusedrereview.
Ruling: reviewer-declined credential-only routerhealth reset retained as inherited nonblockingroutingfollow-up forwholeM2triage, notsilentlydiscarded — B2explicitextensionvendor/capabilities, B3Keyedit testownershipfixed; costifwrong: revisedKey maywaitexistingboundedhealthrecovery. RuntimeGUI/VPending areactualacceptanceboundaries, OpenAIoptionalperminimumcontractruling.
Bstagefix implementer /root/m2b_stage_fix gpt-6-astra high no inheritedhistory, BASE2d3b99e. Controllerreleasebundle2d3b99e buildexit0 stage-app-build.log, notlaunched; oldPID10836stillmappedM1source. Waitstagefix/currentbuildbeforeGUI; noappPassclaimed.
Bstagefix6fc1973 DONE; WSSRED1992/26, combinedpreset/actionRED2001/33, finalGREEN2034/0 sequentialbuildexit0, cleantrackedtree. Freshscopedreview /root/m2b_stage_rereview gpt-6-astra high, review-2d3b99e..6fc1973.diff pending. stage-fix-report.md stableworkspace logs.
BstagefixrereviewbothImportantADDRESSED; no newbreakage/outofscope; progressionApprovedat6fc1973. ActualRealtimevalidatorcontractbeforefactory/start, noinvalidsessionandfullfallbackaudio tests; vendorpresetcataloginclTeleSpeech, UUIDmodelactionpreservescustomURL/Key. Recorded2034/0checked,norerun. RuntimeGUI/VPendingretained, credentialhealthfollowupretained.
M2-B implementation-stage complete at6fc1973; controllercurrentreleasebuildbeforeGUI, thenCmayproceed. Keepworkspace untilwholeM2archive/closeout.
Controller fixedreleasebuild6fc1973 completeexit0 gui-app-build.log, sourceTree668858cc69e0a399a997bcd469e76ea645ef2399; bundle executableSHA25654a6c1de13f481cedca7fde32061d7364ecac4a1add8285d21f8863b0ce01657, adhoc/com.flowtype.app/CDHash91cc3a45f3379bc071b336e5a6f4e4d6d4ea0daa. RawreleaseSHA differsafterbundlecodesign expected. Notyetlaunched. C1sourceworkbeginsafterbuild, fixedbundleunchanged.
ControllerGUIattemptblocked: CUAgetApp(ActivityMonitor/displayname+bundleID) andSystemSettings allcgWindowNotFound; listAppsworks, optionalcomputer.launch_app notavailable. No blindUI orshellUIworkaround, nooldprocessquit/relaunch; pgrepstillPID10836(oldM1mappedsource), newfixedreleaseNOTlaunched. AsyncOwnerquestionaboutunlock sent whileC1continues; no responseyet, GUIremainsPending. This is environment/toolwindowfailure, notapprovalrejection.
