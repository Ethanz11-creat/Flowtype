# M2-A staged whole-plan review
Reviewer /root/m2a_stage_review, BASE7964d02 HEAD26e10c7. Approval With fixes; do not advance B. Critical none.

## Important1 terminal recovery loses diagnostic information
ModelRecoveryPresentation.swift:27; QwenModelStatusCard.swift:104. Presentation reduces failure to generic category without failure.summary: HTTP status and safe endpoint/path neverdisplayed. Operation source only shown while operationID nonnil; terminalUI source comes from mutable settings. Mirror308 cannot distinguish; selectingOfficial removes failedMirrorassociation. Show safe failure endpoint/status and retain failedoperation source independent from nextretry source. Regression mirrorfailure→change selectedsource→retry.

## Important2 removing folder override undone by recovery
ModelRecoveryActions.swift:18; LocalModelPicker.swift:154. ImportA then remove clears config but leavescoordinator.target=.offline(A), cardload/retry reimportsA and savespathagain. Legacy-only localModelPath shown but no removecontrol; preset handler.swift:53 returns whileoverrideexists. Shared explicit removal clears relevant fields and resets/rebases recoverytarget; preserve failednewimportretry whenintentstillcurrent. Cover importA→remove→load/retry and legacy-onlyoverride removal.

## Important3 opaque failures misclassified transient
QwenASRProvider.swift:105 maps every DownloadError.failedToDownload tonetwork retryable. dependency AudioCommon/HuggingFaceDownloader.swift:125 wraps any snapshoterror, includingdeterministic; configHEADvalid then otherfile metadata/HTTPfailure causesup to3 coordinator×3snapshot attempts. Retry only positivelyknown transienterrors; preserve structuredcauses whereavailable, unclassifiedopaque wrappers conservative. Add provider-boundary classification/budget regressions. Do not emitrawerrors/response/credentials.

## Minor
Native redirectcallback interception fixture deferred (realrelative probe partialevidence); inheritedAppLoggerwarning.

## Declined to judge / controller resolution
Actualweights/GPU/GUI/realrecordingreplacement andV1–V5 remainPending; no fixtureclaim. B/C assignedlater, notA. Explicit outstandingruntimeacceptance distinctfromimplementationstageapproval.

Strengths: candidateleases, captureidentity, operationserialization/HFscope, cancellationdrain, substantial RED/GREEN, honest1559/0 fixtureandHEAD-onlyevidence. Readonly, no testsrerun.
