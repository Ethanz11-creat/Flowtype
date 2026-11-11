# Constructed replay comparison

Split: eval. 32ms real-clock PCM ingress; serial Qwen1.7 ASR. Constructed public clips ≠ natural continuous sessions. Incremental segment results ≠ token streaming.

| Strategy | MER edits/units | first result / final result (seconds, each session) | endpoint |
|---|---|---|---|
| whole | 22/235 (9.36%) | eval-zh-1: 12.876616458059289 / 12.876616458059289; eval-zh-2: 13.405329458997585 / 13.405329458997585; eval-en-1: 21.403689709026366 / 21.403689709026366; eval-en-2: 15.88831954204943 / 15.88831954204943; eval-mixed-1: 22.000004208064638 / 22.000004208064638; eval-mixed-2: 24.023352290969342 / 24.023352290969342 | manual_pending |
| fixed5 | 37/235 (15.74%) | eval-zh-1: 6.454391832929105 / 10.760888417018577; eval-zh-2: 5.978516291012056 / 11.787584083038382; eval-en-1: 6.129796792054549 / 18.493116625002585; eval-en-2: 6.36838016693946 / 14.207502166973427; eval-mixed-1: 6.222960417042486 / 18.02945762500167; eval-mixed-2: 6.238385916920379 / 20.843059333972633 | manual_pending |
| vad600 | 30/235 (12.77%) | eval-zh-1: 6.8422227499540895 / 9.633671832969412; eval-zh-2: 7.3451914170291275 / 11.301481375005096; eval-en-1: 12.006424291059375 / 18.274832458002493; eval-en-2: 8.763482125010341 / 13.470170625019819; eval-mixed-1: 9.536949625005946 / 17.42224616603926; eval-mixed-2: 13.313852790975943 / 20.45036695804447 | manual_pending |

No p95/SLA claim from six eval sessions. See JSON for queue waiting, each endpoint (including negative early cuts), and final-from-speech delay. Manual-pending delays are null. Microphone/client insertion demonstrations are separate.
