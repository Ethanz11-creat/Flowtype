# 上下文纠错首轮实测：稀有词改善，普通词仍有误改

日期：2026-11-11。已完成同一批 **200 条 LibriSpeech test-clean pilot** 的三组比较。后置纠错使用硅基流动 `deepseek-ai/DeepSeek-V3`；原始识别使用本机 Qwen3-ASR-1.7B MLX 4bit。完整条件见[实验协议](PROTOCOL.md)与[运行前冻结记录](protocol.json)。

## 结果

| 条件 | WER（整体） | B-WER（目标稀有词） | U-WER（其他词） |
| --- | ---: | ---: | ---: |
| 原始 ASR | 2.99%（133/4,449） | 11.46%（58/506） | 1.90%（75/3,943） |
| 普通 LLM 纠错 | 3.37%（150/4,449） | 11.07%（56/506） | 2.38%（94/3,943） |
| 完整候选词表＋保守 LLM 纠错 | **2.45%（109/4,449）** | **5.93%（30/506）** | 2.00%（79/3,943） |

相对原始 ASR，词表约束组减少 28 个稀有词编辑错误（相对减少 **48.3%**），但增加 4 个其他词错误，净减少 24 个整体错误。整体 WER 降低 0.54 个百分点，相对减少 18.0%。这是本次 pilot 的描述性结果，未进行显著性检验，不是“产品准确率提升 48%”。

普通纠错只减少 2 个稀有词错误，却增加 19 个其他词错误，整体退化。结果说明，在本次条件下，给 LLM 一句“请纠错”不足以获得稳定收益，正确候选上下文有帮助；同时，保守提示也未消除误改。

官方 B/U 按参考中实际稀有词划分，不是按完整候选表划分。评分使用与[原始基线](../2026-11-11-asr-baselines/README.md)相同的规范化和固定官方脚本。

## 逐句收益与误改

下表是**单位代价词编辑距离**的逐句诊断，与官方加权对齐的聚合 B/U 指标分开。

| 条件 | 错误减少的句子 | 错误增加的句子 | 错误数量不变 | 原本正确的 128 句中被改错 |
| --- | ---: | ---: | ---: | ---: |
| 普通 LLM 纠错 | 14 | 23 | 163 | 11（8.59%） |
| 词表约束纠错 | 27 | 6 | 167 | 4（3.13%） |

“错误数量不变”不代表文本未变。规范化后的文本发生变化的句子，普通组为 45 条、词表组为 37 条。逐句结果完整保存在[诊断输出](paired-diagnostics.jsonl)，没有只挑成功案例。

几个有代表性的文本差异：

- `1188-133604-0005`：词表组将 `Carpaccius` 改为参考中的 `Carpaccio's`，体现专有词词形恢复。
- `1089-134686-0008`：`ardor → ardour` 使计分改善，但它属于英美拼写差异，不能称为声学听辨提升。
- `260-123286-0006`：原始 `sail` 与参考一致，词表组却改为 `cruise`；后者确实在完整候选表中，表现与词表干扰一致，但单例不能独立证明因果。
- `7176-92135-0019`：`I want double nine` 被改为 `I want to dine`，数字表达被语义化改写；两个关键词都不在候选表中，不能将所有错误都归因于词表命中。

这些例子为解释机制而主动选取，**未独立试听裁决，不代表随机错误比例**。原文见[示例](selected-examples.json)。本轮没有在看到这些案例后修改提示词或重新刷分。

## 失败、用量与延迟

共发起 400 次完整实验请求，普通组 2 次 curl TLS 连接失败（exit 35）、词表组 1 次接收失败（exit 56）。全部按预设协议保留原始文本并计入上表，未重试、未换模型或删除样本。之前的 4 次接入检查请求均成功，单独归档，不混入主结果。

| 条件 | 原文回退 | 请求耗时中位数 | 请求耗时 p95 | 已报告 token 总量 |
| --- | ---: | ---: | ---: | ---: |
| 普通 LLM 纠错 | 2/200 | 2.46 s | 9.64 s | 27,810 |
| 词表约束纠错 | 1/200 | 2.66 s | 13.99 s | 134,535 |

token 为服务端有返回的请求总计，分别缺少 2 次、1 次失败请求的用量，不等于最终账单。耗时包含网络、排队和推理；4 路并发批处理也不同于真实逐句交互。词表组明显增加输入成本，这次服务 p95 还提示需要进一步研究交互延迟。

请求模型为服务别名，成功响应报告相同 `deepseek-ai/DeepSeek-V3`；不能据此固定底层权重版本。temperature=0 也不保证外部服务逐字复现。

## 证据与复现

- [机器汇总](comparison-summary.json)、[原始服务输出](completions.jsonl)、[实际推理输入](inference-inputs.jsonl)。不含参考答案字段、实际命中稀有词字段或凭据。
- [普通组官方分数](plain-official-score.txt)、[词表组官方分数](contextual-official-score.txt)。
- [接入检查协议](smoke-protocol.json)、[接入检查输出](smoke-completions.jsonl)。仅前两句，未用于调参。
- [依赖锁](requirements.lock.txt)、[验证结果](verification.json)。工具代码与测试见[协议](PROTOCOL.md)。

本地原始运行目录：`build/contextual-asr-correction-20261111/pilot200/`。主实验输入、提示词与运行脚本哈希在首次请求前冻结。推理器从 FlowType 现有配置中只读获取活动厂商，不修改用户设置。

在已准备原始基线的机器上，使用新的输出目录复现；命令会调用当前活动的 HTTPS LLM 服务，消耗服务用量：

```sh
PYTHONDONTWRITEBYTECODE=1 build/ascend-validation-audit/.venv/bin/python tools/run_contextual_asr_correction.py --baseline build/asr-baseline-20261111/librispeech/pilot200 --output build/contextual-asr-correction-reproduction --workers 4
PYTHONDONTWRITEBYTECODE=1 build/ascend-validation-audit/.venv/bin/python tools/score_contextual_asr_correction.py --baseline build/asr-baseline-20261111/librispeech/pilot200 --run build/contextual-asr-correction-reproduction --official-scorer build/asr-baseline-20261111/official_biasing_score.py
PYTHONDONTWRITEBYTECODE=1 build/ascend-validation-audit/.venv/bin/python -m unittest discover -s tools -p 'test*asr*.py'
```

厂商、模型、协议字段和哈希应与本次记录核对；换服务或模型属于新实验。全部 API 失败也可生成有效管线结果，但只能解释为回退到原始 ASR，不能冒充 LLM 成功。

## 面试中可以怎样讲

“我研究外部上下文能否改善 ASR 长尾词，同时控制误改。先固定识别结果，再用相同 LLM 比较无词表与含干扰候选词表，分别计算整体、稀有词和普通词错误。在 200 条真实英语语音 pilot 上，词表条件使稀有词错误从 58 降到 30，但普通词错误从 75 增到 79。无词表纠错整体反而退化，因此下一步重点是约束修改范围和拒绝不可靠修改，而不是让 LLM 自由润色。”

这属于**系统实验与上下文利用研究**，不是已完成 PyTorch 训练、声学模型微调或新算法 SOTA。用户需要能解释输入隔离、编辑距离、实验消融、误改案例与先验条件，而不只是复述一个改善百分比。

## 局限与下一步

1. 词表保证含正确目标，是理想先验；必须补无关/缺失目标词表，才更接近真实检索环境。现有干扰项不等于完全无关词表条件。
2. pilot 输出和部分标注已查看，不是独立盲测。方法调整应在独立开发数据上完成，再冻结方案使用未见留出验证；后续完整 test-clean 若包含这 200 条，必须分开报告已见与未见部分。
3. 当前是英语有声书，含古语、专名、英美拼写差异。ASCEND 中英混说目前只有[原始基线](../2026-11-11-asr-baselines/README.md)，尚未执行纠错对照。软件技术术语收益仍需匹配数据。
4. 已观察到候选词误替换、数字和语序改写。下一轮可在开发集研究候选编辑＋保守拒绝：限制修改范围，保护数字/否定/标识符，遇到不可靠候选保留原文；不能利用当前参考答案逐句特判。
5. 没有声学候选或音频证据的文本纠错无法可靠区分同音词及合理原句；更深入的方法可比较 ASR n-best/声学信息，需另立实验。

本轮未改产品链路、未完成发行验收，也没有把探索性结果自动接入用户的实时落字。

## 来源与许可

LibriSpeech：Panayotov et al., ICASSP 2015，[OpenSLR SLR12](https://www.openslr.org/12/)，CC-BY-4.0。本目录参考摘录来自该语料；识别文本、纠错输出与分析为新增派生结果。官方 contextual biasing 资源来自 Le et al., INTERSPEECH 2021 的 [fbai-speech](https://github.com/facebookresearch/fbai-speech/tree/main/is21_deep_bias)，评分软件 MIT。原始音频和第三方脚本保留在 ignored `build/`，不随客户端分发。
