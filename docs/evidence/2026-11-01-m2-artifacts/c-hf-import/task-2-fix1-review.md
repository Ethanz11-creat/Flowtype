Reviewer /root/m2c_rereview2, gpt-6.1-sol high. BASE d12f6d0 HEAD9f0c92e.

Important unknown-token fallback: ADDRESSED. LocalWhisperTokenizer.swift:34,70–75 exact token→ID→token for inventory/lookup; OfflineWhisperKit.swift:187,196–203 exact requested hints; standard unknown-token fixtures + missing Cantonese/valid languages/Englishonly/v3 covered.
No-speech aliases: ADDRESSED. LocalWhisperTokenizer.swift:24–29 one unique exact nospeech/nocaptions ID, graph validation:44 retained; tests:77–93 acceptance and conflicting alias rejection.
No new breakage; no new out-of-scope findings. Deferred forced-cast warning unchanged and accurately reported.
Read concrete RED/GREEN logs: finalbuild22.71s and2179/0, no suites rerun. Public tokenizer-only probe99 languages/rawyue50257/exactnil/zh50260 verified, graph dimensions supplied, no fullmodel/inference claim.
Spec PASS, quality PASS, all findings addressed; no Critical/Important open.
