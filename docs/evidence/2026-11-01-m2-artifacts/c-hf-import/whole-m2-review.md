# Whole M2 review — /root/whole_m2_review, gpt-6-astra high

Range878725c..73d5e74. Read-only production diff in passes plus relevantfixtures/docs/plans/ledgers/dependencies/evidence. No mutations or suites rerun. Recorded finalbuild23.57s/selftest2306/0.

## Strengths
Sharedcoordinator retainedleases/captures/successonlylatestconfig; sharedcloudbuilder/vendorcapabilities/redirectblock/safediagnostics; UUIDpreview/relocation/removal/checkownership; scopeddependencies; honestfixture/static/tokenizer/Pendingevidence.

## Important — required before source completion

1. Ordinary retry silently changes automatic selection into an explicit preset.
ModelRecoveryActions.swift:31, QwenModelState.swift:418. Trigger: automatic1.7B recovery and0.6Bfallbackfail; user fixes source and clicks重试. Retry submits current0.6Btargetwithmanual; successfulC3persistence changesselectedLocalModelID nil→0.6B. Loses selectionpolicy and mayloseautomaticfallbacksemantics. Preserve original selection intent/request separately from current attempttarget. Retry retains automatic/explicitintent usinglatestsource. Regression throughModelRecoveryActions.retry checks persistedconfig/restartbehavior, automaticfallback, explicitselection.

2. Whisper graph validation is incomplete and invokes unsafe dimension accessors before validating rank.
OfflineWhisperKit.swift:55. Onlylogitssize and encoder/decoderembeddings checked. Pinneddependencydimensionhelpers directlysubscriptarrays; validCoreMLgraph rank1logits cantrapduringload. Otherincompatiblegraphssame3dimensions butmissing/wrongMelSpectrogramoutputs/mismatchedencoderinputs/incompatibledecodercaches cancommitready thenfail/forcedunwraprecognition. Validate requiredfeaturenames/types/ranks/supporteddimensions/crosscomponentrelationships includingoptionalprefill fromrawmodeldescriptions BEFOREdependencyaccessors/readinesscommit. Addmalformedrank/mismatchedinterfacesregressions. Existing scalarmetadata/stubtests insufficient.

3. Qwen accepts severely incomplete tokenizers that silently discard transcription text.
ASRModelInspector.swift:177. Any nonemptyvocabwith11sentinels +mergesone2partlineaccepted; acceptedfixtureonly14vocabentries. Truncatedordinaryvocab passesinspector+dependencyloader, decoder silentlyskipsunknownIDs, missing/emptytextafterreadycommit. Validate supportedQwencompletebasevocabcoverage/bytealphabet/mergereferencesandstructure, explicitlyspecialtokens/paddedmodelslots. Regress ordinarytokenremoval/corruptmerge, retain actualconvertedtokenizercompatibility. Noinference/payload-equivalence required.

## Minor deferred triage
- ModelMetadataPreflight111 nativecallbackfixtureabsent; purepolicy+actualrelativeHEADprobe substantiallyreducesrisk. Followup,no demonstratedredirectdefect.
- SafetensorsManifest43 optional__metadata__string→stringvalidationmissing; actionableearlyfailure, oldleaseisolation limitsimpact.
- WhisperRuntimeSelfTests67 newforcedbridgewarning/potentialfixturetrap; explicittypedconversion. AppLogger27inheritedseparate.
- ASRRouter40 credentialonlyhealthidentityretainfailureuntilboundedrecovery60s; inheritednonblockingfollowup, usecredentialindependentrevision notkeydiagnostics.

## Declined to judge
- ActualGUI/currentbinary/offlinefullmodels inclmlpackage/V1–V5: unavailable environment/models/services/devices, mandatoryPending notwaived.
- Accuracy/actualmemorypeaks/untestedvariants: fixture/static/tokenizer evidence cannotestablish.
- Extra families/automaticconversion/M3delivery/M4taxonomy/M5infrastructure: explicitlyoutsideM2.

## Verdict
SpecNeedsfixes, QualityNeedsfixes, ReadyWithfixes/notreadyyet. ThreeImportantmustfixsinglefinalwave+scopedrereview. NoCritical.
