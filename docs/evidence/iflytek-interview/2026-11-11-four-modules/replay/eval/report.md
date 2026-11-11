# Constructed replay comparison

Split: eval. 32ms real-clock PCM ingress; serial Qwen1.7 ASR. Constructed public clips ≠ natural continuous sessions. Incremental segment results ≠ token streaming.

| Strategy | MER edits/units | first result / final result (seconds, each session) | endpoint |
|---|---|---|---|
| whole | 22/235 (9.36%) | eval-zh-1: 12.920730666955933 / 12.920730666955933; eval-zh-2: 13.244595917058177 / 13.244595917058177; eval-en-1: 21.59849241701886 / 21.59849241701886; eval-en-2: 15.800341458059847 / 15.800341458059847; eval-mixed-1: 20.616492290981114 / 20.616492290981114; eval-mixed-2: 24.855712832999416 / 24.855712832999416 | manual_pending |
| fixed5 | 37/235 (15.74%) | eval-zh-1: 6.506062499945983 / 10.998442499898374; eval-zh-2: 6.043896374991164 / 11.787936082924716; eval-en-1: 6.109427458024584 / 18.47143941698596; eval-en-2: 6.150140000041574 / 13.936249666032381; eval-mixed-1: 6.130660833092406 / 17.95008783310186; eval-mixed-2: 6.173877291963436 / 20.60329991695471 | manual_pending |
| vad600 | 30/235 (12.77%) | eval-zh-1: 6.848780500004068 / 9.644072458031587; eval-zh-2: 7.211384875001386 / 11.271629499970004; eval-en-1: 12.21080504101701 / 18.225159875000827; eval-en-2: 8.756362334010191 / 13.420081000076607; eval-mixed-1: 9.635943791945465 / 17.391489458968863; eval-mixed-2: 14.733002791996114 / 20.71496291703079 | manual_pending |

No p95/SLA claim from six eval sessions. See JSON for queue waiting, each endpoint (including negative early cuts), and final-from-speech delay. Manual-pending delays are null. Microphone/client insertion demonstrations are separate.
