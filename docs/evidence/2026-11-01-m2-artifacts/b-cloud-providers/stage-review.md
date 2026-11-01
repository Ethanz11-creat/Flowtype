# M2-B staged whole-plan review
Reviewer /root/m2b_stage_review BASEeb840f8 HEAD2d3b99e. Needsfixes beforeC; Criticalnone, 2Important.

## Important1 actual WSS recording bypasses strict endpoint restrictions
CloudTranscriptionRequestBuilder.swift:13 strictsettings/readiness validator notused by directRealtimeASRConfiguration at SessionContext.swift:195/ASRStage.swift:73. RealtimeASR.swift:34 validator stillacceptsquerycomponents/overflowexplicitports, e.g WSS?token... failslocalCheck butcanreachrealsessionKey/audio. Captureroutingonlynonemptychecks, activeLocal cankeepreadinessunblocked. Enforce strictendpointcontract atactualRealtimeASRConfiguration boundary, preserveexistingwhitespacerejection; regression constructor/capturepath and no sessionstart forrejectedsettings.

## Important2 SiliconFlow preset choices disappeared
CloudASRProviderList.swift:124 onlymodelIDtextfield; oldpresetpickerremoved, CloudASRModelPreset.siliconFlowModels nouiconsumer. ExplicitdesignrequiresTeleSpeechASR entry/presetswitching. Restore vendorappropriatepresetselection inadvancedsettings alongsidecustommodelentry, preservingcustomvalues onrender/migration.

## Strengths / evidence
Preservedmigration/captureidentity; sharedbuilder/capabilities/JSON/redirectrefusal/redaction/cancel; synchronousUItestownership; logged1957/0matchesHEAD, no rerun/read-only.

## Declined to judge
GUI andliveV1/WSS handshakePending; remainingV2–V5 mainlinePending; OpenAIoptionalfield intentionallydeferredperruling. Credential-onlychangesresettinginheritedrouterhealth outside specifiedvendor/capabilityextension/preservedrouting scope, Key-relatedUItestinvalidationreviewed.
