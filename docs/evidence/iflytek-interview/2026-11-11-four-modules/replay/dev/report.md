# Constructed replay comparison

Split: dev. 32ms real-clock PCM ingress; serial Qwen1.7 ASR. Constructed public clips ≠ natural continuous sessions. Incremental segment results ≠ token streaming.

| Strategy | MER edits/units | first result / final result (seconds, each session) | endpoint |
|---|---|---|---|
| whole | 5/112 (4.46%) | dev-zh-1: 15.444129499956034 / 15.444129499956034; dev-en-1: 11.8655250830343 / 11.8655250830343; dev-mixed-1: 27.25051929196343 / 27.25051929196343 | manual_pending |
| fixed5 | 8/112 (7.14%) | dev-zh-1: 6.142935625044629 / 13.057974625029601; dev-en-1: 6.101527792052366 / 11.185971416998655; dev-mixed-1: 6.2441020829137415 / 24.706520707928576 | manual_pending |
| vad300 | 6/112 (5.36%) | dev-zh-1: 4.686144958017394 / 12.168529583024792; dev-en-1: 2.2002029590075836 / 10.310637167072855; dev-mixed-1: 7.175613458035514 / 23.672077542054467 | manual_pending |
| vad600 | 6/112 (5.36%) | dev-zh-1: 8.59278258390259 / 12.458472333964892; dev-en-1: 2.340233749942854 / 10.513589957961813; dev-mixed-1: 8.440371749922633 / 23.487599957967177 | manual_pending |
| vad900 | 4/112 (3.57%) | dev-zh-1: 12.51136099989526 / 12.934436166891828; dev-en-1: 7.6968665830791 / 11.03338916611392; dev-mixed-1: 13.38112675002776 / 23.94848208304029 | manual_pending |

No p95/SLA claim from six eval sessions. See JSON for queue waiting, each endpoint (including negative early cuts), and final-from-speech delay. Manual-pending delays are null. Microphone/client insertion demonstrations are separate.
