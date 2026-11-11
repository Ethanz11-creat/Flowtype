# Qwen3-ASR 实测基线：ASCEND 与 LibriSpeech 稀有词

日期：2026-11-11。本目录两组均为本机真实离线推理，**原始基线未应用 LLM 或上下文纠错**。目的为冻结可复用的识别输出，建立后续对照实验的起点。后续已完成的三组纠错比较另见[上下文纠错实测](../2026-11-11-contextual-asr-correction/README.md)，不覆盖本目录的原始输出。

## 主要结果

模型为本机 `aufklarer/Qwen3-ASR-1.7B-MLX-4bit`，Apple M1 / 16 GB，复用项目锁定的 Swift/MLX 依赖，语言自动识别、无上下文、无后处理、无备用模型。

### ASCEND validation

全部 1,130 条均已执行，无推理异常；2 条成功调用返回空文本，已保留并按漏字计分。63 条参考含 `[UNK]` 的样本单列诊断，常规评分采用预先约定的 1,067 条 clean-reference 子集。

| 分组 | 计分句数 | 参考混合单位数 | 总编辑数 | MER |
| --- | ---: | ---: | ---: | ---: |
| 全部 clean-reference | 1,067 | 11,479 | 1,362 | **11.87%** |
| 中英混说标签 | 191 | 2,997 | 419 | **13.98%** |
| 中文标签 | 640 | 6,977 | 643 | 9.22% |
| 英文标签 | 236 | 1,505 | 300 | 19.93% |

这里各分组都采用相同的中文逐字、英文逐词、数字串单列的混合单位规则，不能把英文标签组与独立英语语料直接作模型能力排名。MER 为总编辑数/总参考单位数，不是各句错误率的平均值。

该 clean-reference 子集是**自定义口径**，不是官方全 validation 计分协议，也不是最终 test 成绩。[结构化结果](ascend-summary.json)包含按说话人、主题的分组统计。

### LibriSpeech contextual biasing pilot

官方 test-clean 音频与 100 词表参考均已获取并校验。此次只执行固定的 **200 条 pilot / 40 人 / 每人 5 条 / 约 28.21 分钟**，不是完整 2,620 条 test-clean 的成绩。选择依据是预先固定的 ID 哈希，与模型结果、稀有词标签无关。

| 官方评分指标 | 参考词数 | 编辑数 | 错误率 |
| --- | ---: | ---: | ---: |
| WER：整体 | 4,449 | 133 | **2.99%** |
| B-WER：参考中的目标稀有词 | 506 | 58 | **11.46%** |
| U-WER：其余词 | 3,943 | 75 | **1.90%** |

200 条均执行成功，无空输出。模型没有接收 biasing 词表；本表是无上下文基线。[原版评分输出](librispeech-official-score.txt)和[结构化结果](librispeech-summary.json)已归档。官方实现按参考文件第三列稀有词划分类别，使用带权对齐；细节见[计分协议](librispeech-scoring-protocol.json)。

## 能说明什么

在这份 LibriSpeech pilot 上，稀有词的文本错误率高于其他词，支持继续研究长尾词/实体纠错；不能据此宣称上下文已带来提升，或推定对 PyTorch、LoRA 等技术术语同样有效。ASCEND 则提供真实中英混说的基线与误改控制场景。

本轮文本对照也暴露了需要分开的错误来源：

- ASCEND `00581` 的参考含 `bedtimes`，输出为 `bad times`，同时出现简繁写法差异；一个总错误率会混合词识别、分词和书写规范差异。
- ASCEND `00142` 的参考缩写为 `C R P`，输出为 `CLP`；`00338` 的 `koala bear` 输出为中文音译。需要区分缩写、音译与真正词义变化，不能未经听辨就裁定参考或模型哪方符合音频。
- LibriSpeech `1089-134686-0008` 的 `ardour → ardor` 属于可见的英美拼写差异；`1188-133604-0005` 的 `carpaccio's → carpaccius` 则体现专有词词形差异。B-WER 不能直接等同于纯粹的声学听错比例。

原先计分协议保持冻结，没有在看到错误后改变规范化以改善主成绩。例子见 [ASCEND 文本对照](ascend-examples.json)、[LibriSpeech 文本对照](librispeech-examples.json)；它们是输出与参考之间的差异，**未独立试听裁决，也不是随机错误分布估计**。

ASCEND validation 仅 3 位说话人，且部分样本有接近满幅的信号提示；其真实音质影响尚未完成主观核验。LibriSpeech pilot 已查看输出，后续若据此设计或调参，包含这些样本的 test-clean 结果不能再称为全新盲测。

## 运行耗时

| 范围 | 音频总时长 | 逐条读取与推理耗时合计 | 单条中位数 | 单条 p95 | 合计 RTF |
| --- | ---: | ---: | ---: | ---: | ---: |
| ASCEND 1,130 条 | 3,323.61 s | 835.60 s | 0.624 s | 1.552 s | 0.251 |
| LibriSpeech pilot 200 条 | 1,692.66 s | 358.79 s | 1.487 s | 3.843 s | 0.212 |

不含模型加载，依赖是 debug 产物；接入检查可能使系统编译缓存变热，用户客户端仍在运行。这些时间只描述本次离线批量运行，不能当作发布版冷启动或端到端落字延迟。

## 结果与验证

- [完整协议](PROTOCOL.md)、[模型文件哈希与依赖版本](run-metadata.json)、[Python 依赖锁](requirements.lock.txt)。本地安装未保留上游模型 revision，故使用文件 SHA-256 界定模型身份。
- [ASCEND 原始预测](ascend-predictions.jsonl)、[LibriSpeech pilot 原始预测](librispeech-predictions.jsonl)。ID、原始文本、成功/失败状态、逐条时间均保留，未人工修正。
- ASCEND 的 1,067 条评分，额外以独立的单位代价动态规划重算，确认 **1,362 / 11,479**，与 jiwer 一致。
- 评分器 7 项行为测试通过，覆盖混合 token、微平均、已知编辑数、失败/空输出、未知参考、缺失/重复/额外 ID。
- 官方 LibriSpeech 评分器用手算样本验证整体错误 `2/6`、稀有词错误 `1/2`、其他词错误 `1/4`；实际 200 条的 B/U 参考分母及编辑数均能加回整体。
- 所有 200 条 FLAC→WAV 导出均验证 PCM 完全一致；全部 2,620 条词表参考与原始 LibriSpeech 转写小写化后相符。
- 独立推理源码实际编译成功，构建辅助脚本也已重新执行验证。初次辅助脚本未解码 SPM 对含空格对象路径的引号，已修复并重跑通过。原始执行二进制另存于本地 `build/asr-baseline-20261111/executed-asr-baseline`，哈希与运行记录一致。

本目录的基线阶段未改客户端产品代码，未调用云端 ASR/LLM，未测上下文纠错收益，未运行完整 LibriSpeech test-clean 或 ASCEND test。后续云端 LLM 纠错调用单独归档于上述实测目录。

## 复现命令

以下假定已按[数据检查记录](../2026-11-11-ascend-validation-audit/README.md)获取固定 ASCEND parquet，按 OpenSLR 获取并解压 LibriSpeech test-clean，以及下载协议所指的官方 biasing 参考和评分器。LibriSpeech 参考可按 [selection 记录](librispeech-selection.json)中的 Git blob SHA 从 GitHub API 获取，避免把网络中断的部分文件当作完整文件。

```sh
uv venv build/ascend-validation-audit/.venv --python 3.13
uv pip install --python build/ascend-validation-audit/.venv/bin/python -r docs/evidence/2026-11-11-asr-baselines/requirements.lock.txt
swift build
python3 tools/build_native_asr_baseline.py
build/ascend-validation-audit/.venv/bin/python tools/prepare_ascend_baseline.py --parquet build/ascend-validation-audit/data/validation.parquet --output build/asr-baseline-20261111/ascend
.build/debug/asr-baseline '/path/to/Qwen3-ASR-1.7B-MLX-4bit' build/asr-baseline-20261111/ascend/inputs.jsonl build/asr-baseline-20261111/ascend/new-predictions.jsonl 0
build/ascend-validation-audit/.venv/bin/python tools/score_asr_baseline.py --references build/asr-baseline-20261111/ascend/references.jsonl --predictions build/asr-baseline-20261111/ascend/new-predictions.jsonl --output build/asr-baseline-20261111/ascend/new-scored
build/ascend-validation-audit/.venv/bin/python tools/prepare_librispeech_biasing.py --corpus build/asr-baseline-20261111/librispeech/extracted/LibriSpeech/test-clean --biasing-refs build/asr-baseline-20261111/librispeech-100.verified.tsv --output build/asr-baseline-20261111/librispeech/pilot200
```

LibriSpeech 同理运行原生推理器，之后使用[官方评分包装器](../../../tools/score_librispeech_biasing.py)。该包装器要求 run 目录已有预测、冻结的 `scoring-protocol.json` 及 `official-refs.tsv`，实际目录为 `build/asr-baseline-20261111/librispeech/pilot200/`；冻结协议已归档为本文目录中的 `librispeech-scoring-protocol.json`。推理器拒绝覆盖已有输出，重跑应使用新的输出位置。

## 数据来源与许可

- ASCEND：Holy Lovenia et al., LREC 2022，[数据](https://huggingface.co/datasets/CAiRE/ASCEND)、[论文](https://arxiv.org/abs/2112.06223)，CC-BY-SA-4.0。本目录的 ASCEND 参考摘录及基于其音频生成的预测按该来源注明归属及许可；新增模型转写与分析已明确标识。
- LibriSpeech：Vassil Panayotov et al., ICASSP 2015，[OpenSLR SLR12](https://www.openslr.org/12/)，CC-BY-4.0；本目录列明原参考与新增模型预测的区别。
- Contextual biasing：Le et al., INTERSPEECH 2021，[官方代码和参考目录](https://github.com/facebookresearch/fbai-speech/tree/main/is21_deep_bias)，软件 MIT；官方脚本保留原许可声明。

源音频、逐条参考、环境、原版第三方脚本和运行日志仍保存在 ignored `build/`，不随 FlowType 客户端分发。

## 下一轮实验

以冻结的原始预测比较普通 LLM 纠错与受词表/上下文约束的纠错，分别报告目标稀有词收益、其他词损失、原本正确内容被改坏的比例及延迟。正确词表、无关词表、无词表条件应分开；提供逐句正确实体列表属于理想先验条件，不能代表真实检索效果。

普通语音改写、简繁/拼写标准化与术语纠错收益也应分别记录。新提示词、阈值和方法需要在独立开发数据上确定，正式验证保持未见数据留出。后续 pilot 的局部收益与误改见上述独立记录；当前仍没有最终泛化结论。
