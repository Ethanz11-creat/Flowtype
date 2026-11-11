# 固定矩阵：LLM 纠错实测

英语为200条自定义pilot；中英混说为ASCEND的191条。两者均不是技术术语专项或盲测。候选表包含干扰项；错配表可能偶然包含正确词。

| 英语条件 | WER | B-WER | U-WER | 变更句 | 改坏句 | 原本正确的128句中改坏 | fallback | 网络中位秒 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| raw | 2.99% | 11.46% | 1.90% | 0 | 0 | 0 | 0 | 0.00 |
| plain | 3.24% | 11.46% | 2.18% | 41 | 19 | 10 | 0 | 1.98 |
| contextual | 2.36% | 5.73% | 1.93% | 37 | 5 | 4 | 0 | 2.11 |
| mismatched | 3.21% | 12.06% | 2.08% | 30 | 14 | 6 | 0 | 2.10 |

| 中英混说条件 | 编辑数/2997（MER） | 变更句 | 改坏句 | 原本正确的42句中改坏 | fallback | 网络中位秒 |
|---|---:|---:|---:|---:|---:|---:|
| raw | 419/2997 (13.98%) | 0 | 0 | 0 | 0 | 0.00 |
| plain | 537/2997 (17.92%) | 80 | 53 | 14 | 0 | 1.59 |
| static_tech | 440/2997 (14.68%) | 29 | 14 | 3 | 0 | 1.71 |

参考分母：英语总4449，B506，U3943；mixed2997。官方B/U使用冻结加权对齐；逐句改好/改坏使用单位编辑代价，口径分别保留。

正确词表带来专名收益，同时普通词仍可能受损；错配词表和无上下文LLM不是可靠默认增强。mixed上的退化表明该提示与服务组合不能直接作为通用语音纠错器，技术词表的效果需要有术语覆盖的专项数据。

## 推理后词表覆盖

| 数据/条件 | 参考中至少命中一个候选的句数 | 稀有目标条目被候选表覆盖 |
|---|---:|---:|
| librispeech/plain | 0/200 | 0/501 |
| librispeech/contextual | 152/200 | 501/501 |
| librispeech/mismatched | 3/200 | 3/501 |
| ascend/plain | 0/191 | 0/0 |
| ascend/static_tech | 0/191 | 0/0 |

稀有目标条目是逐句rare_words列表的计数，区别于官方B分母的词出现次数；ASCEND没有该稀有词标注。覆盖只在完成推理后计算，没有进入请求或修改候选表。

## 固定选例

以下每组按ID取前两个改坏句；展示风险，不能代表随机分布。

- librispeech/contextual `260-123286-0006`：0→1 edits。原始：We are losing time, and the fact is, I have not come all this way to take a little sail upon a pond on a raft.；纠错：We are losing time, and the fact is, I have not come all this way to take a little cruise upon a pond on a raft.；参考：we are losing time and the fact is i have not come all this way to take a little sail upon a pond on a raft
- librispeech/contextual `672-122797-0046`：0→1 edits。原始：Tis now winter out of doors. Thought the tree.；纠错：'Tis now winter out of doors. Thought the tree.；参考：tis now winter out of doors thought the tree
- librispeech/mismatched `2094-142345-0005`：1→2 edits。原始：Several clothes horses, a pillion, a spinning wheel, and an old box wide open and stuffed full of colored rags.；纠错：Several clothes horses, a pillow, a spinning wheel, and an old box wide open and stuffed full of colored rags.；参考：several clothes horses a pillion a spinning wheel and an old box wide open and stuffed full of coloured rags
- librispeech/mismatched `2300-131720-0001`：0→1 edits。原始：The London plant was less temporary, but not permanent. Supplying before it was torn out, no fewer than three thousand lamps in hotels, churches, stores and dwellings in the vicinity of Holborn Viaduct.；纠错：The London plant was less temporary, but not permanent. Supplying before it was torn down, no fewer than three thousand lamps in hotels, churches, stores and dwellings in the vicinity of Holborn Viaduct.；参考：the london plant was less temporary but not permanent supplying before it was torn out no fewer than three thousand lamps in hotels churches stores and dwellings in the vicinity of holborn viaduct
- ascend/plain `00004`：0→2 edits。原始：就是，其实主要的功能就是打电话，然后跟parents联系。；纠错：就是，其实主要的功能就是打电话，然后跟父母联系。；参考：就是其实主要的功能就是打电话然后跟parents联系
- ascend/plain `00007`：2→4 edits。原始：smartphone越来越普及了。；纠错：智能手机越来越普及了。；参考：smart phone越来越普及了
- ascend/static_tech `00067`：2→3 edits。原始：像现在有一款app，它好像是可以。；纠错：像现在有一款app，它好像可以。；参考：像不像有一款app它好像是可以
- ascend/static_tech `00119`：2→3 edits。原始：然后在the the difference呃for environment field is the difference between Hong Kong and mainland.；纠错：然后在the difference呃for environment field is the difference between Hong Kong and mainland.；参考：然后在 the the difference uh for environment field it the difference between Hong Kong and mainland

本批请求982次，服务报告374876 tokens，usage缺失0次。模型为服务别名，不是固定权重快照。失败保留原文计分，不重试。网络耗时不等于ASR RTF或已确认落字的端到端时延。

历史pilot单独保留；ardor→ardour一类收益含书写差异，不解释为声学理解。不能按本批错误继续逐句特判或刷提示。
