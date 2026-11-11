# ASCEND validation：音频完整性与技术词覆盖检查

日期：2026-11-11。对应[数据集调研](../../interviews/2026-11-11-code-switching-asr-datasets.md)。

## 结论与边界

已实际下载 ASCEND validation，检查全部 1,130 条嵌入音频的解码、格式与信号统计，并审阅技术主题的参考转写。该集可用于**通用中英混说基线**，不足以单独检验现代软件/LLM 技术术语纠错。

已导出 33 条代表样本及浏览器播放页，覆盖混说、纯中/纯英、三个说话人、未知标记、极短/较长片段及信号异常提示。**未完成主观试听与人工音文对齐核验，未运行 ASR 推理，本文没有 MER/CER 或模型性能结果。**自动解码成功不等于人耳听感合格。

## 数据身份与获取

- 官方来源：[CAiRE/ASCEND](https://huggingface.co/datasets/CAiRE/ASCEND)，[论文](https://arxiv.org/abs/2112.06223)。
- 作者归属：Holy Lovenia et al., *ASCEND: A Spontaneous Chinese-English Dataset for Code-switching in Multi-turn Conversation*, LREC 2022。
- 许可：[CC-BY-SA-4.0](https://creativecommons.org/licenses/by-sa/4.0/)。本地样本包保留原音频字节与原转写，并附来源、许可、筛选说明。
- revision：`737e9800ae31be9932ba8464c80366559bd28424`。
- 文件：`main/validation-00000-of-00001.parquet`，实际下载 106,532,266 字节。
- SHA-256：`3bdec53d2abfd3dd4f0d86a6df4e27e60f20660edc9b66055ae0ef8ec05cf7e2`，与下载响应公布的 `x-linked-etag` 一致。
- 通过 `hf-mirror.com` 的固定 revision URL 获取，随后跳转到 Hugging Face 的文件存储；未下载 train/test。

## 实测组成

| 项目 | 结果 |
| --- | --- |
| 样本总数 / 唯一 ID | 1,130 / 1,130 |
| 解码音频总时长 | 3,323.61 秒，约 55.39 分钟 |
| 中文 / 英文 / 混说标签 | 655 / 262 / 213 条 |
| 混说占比 | 18.85%，不是全集论文统计的 27.01% |
| technology 主题 | 222 条，其中 mixed 47 条 |
| 说话人 | 3 人：ID 7 为 149 条，12 为 646 条，20 为 335 条 |
| 有 `[UNK]` 的转写 | 63 条，共 68 个标记；中文 15、英文 26、混说 22 条 |
| 无 `[UNK]` 的转写 | 1,067 条，其中 mixed 191 条 |
| 空参考文本 / 重复音频字节哈希组 | 0 / 0 |

各主题的中文/英文/混说条数：

| 主题 | 中文 | 英文 | 混说 |
| --- | ---: | ---: | ---: |
| education | 172 | 57 | 66 |
| persona | 169 | 116 | 38 |
| sports | 179 | 49 | 62 |
| technology | 135 | 40 | 47 |

验证集只有 3 位说话人，而且 ID 12 占 57.17%。短句数量不代表同等数量的独立声学条件；需报告分说话人结果，不能根据该验证集宣称广泛口音泛化。只检查了 validation，尚未实测跨 train/test 的说话人与近重复交叉。

## 音频检查

- **1,130 / 1,130 解码成功**，全部为 16 kHz、单声道、PCM 16-bit；未发现零帧、非有限波形或整段全零音频。
- 时长 min / median / p95 / max：**0.20 / 2.42 / 7.342 / 13.85 秒**。极短片段需要保留为诊断条件，不能事后只挑长句。
- 波形解码时长与 metadata 的最大差异约 **0.25 毫秒**，没有超过筛查阈值 10 毫秒的样本。
- RMS 中位数约 **−20.10 dBFS**，范围约 −39.27 至 −9.25 dBFS；这不是 SNR 或人声概率。
- **268 条**触发“超过 0.1% 的样本绝对幅度 ≥ 0.999”的提示，其中 ID 12 占 262 条、ID 20 占 5 条、ID 7 占 1 条。最高的 `00676` 接近满幅的样本占约 4.80%。该统计提示需要核查电平/削波，尚不能确认可闻失真或判定原因；不据此排除样本。
- 文件名全部可提取起始时间与片段时长，但有 `ses3_spk7_1` 这类额外分段标识。需使用完整录音标识排序；本集共 12 个文件名录音组，不能仅按 `session_id` 拼上下文。能解析时间也不证明录音无缺段或对话完整。

本轮没有进行降噪、归一化、裁剪或重采样；试听包音频字节与 parquet 中的原始音频一致。

## 技术词覆盖

对全量参考转写匹配 **30 组目标词及显式别名**，忽略大小写，使用拉丁字母/数字/下划线边界防止子串误命中，允许词语与汉字紧邻。完整词表与规则保存在[检查脚本](../../../tools/audit_ascend.py)和 [summary.json](summary.json)。这是面向目标领域的探索性检索，不是 ASR 热词或从测试答案构建的纠错提示。

目标组包括 PyTorch、TensorFlow、LoRA、QLoRA、Transformer、attention、RAG、LLM、CUDA、GPU、API、Docker、Kubernetes、Python、tokenizer、embedding、batch size、learning rate、checkpoint、fine-tuning、inference、Hugging Face、DeepSeek、Qwen、OpenAI、GitHub、JSON、SQL、ASR、Whisper。

**30 组均未在参考转写中命中。**这不等于音频中绝无相关概念：别名匹配不覆盖所有中文译名、拼字形式或 `[UNK]` 所代表的内容，也尚未逐条听辨。

消费科技词例的命中条数（不同词可能在同一句，不能直接相加作为独立句数）：

| 词组（含列明的单复数/拼写别名） | 命中条数 |
| --- | ---: |
| smart phone / smartphone | 14 |
| app / apps | 5 |
| computer / computers | 1 |
| Cortana | 1 |
| TV | 1 |
| online game / online games | 2 |

参考转写例子（保留原文，不代表已核实音文一致）：

- `00007`：`smart phone越来越普及了`。
- `00068`：`呃在某个特定时间内block掉你使用某些app的那种`。
- `00701`：`语音系统但我用的那个电脑戴尔它有一个Cortana`。
- `00451`（education）：`每星期都会有一个呃group meeting`。

因此不能把 technology 的 47 条混说直接命名为“编程技术术语测试集”。自然停顿、口头词与重复也出现在参考转写中；后续需分清逐字 ASR 和产品化整理，不能把删口头词后的结果与逐字参考混为一项任务。

## 本地试听包

路径：`build/ascend-validation-audit/inspection/`。

- `listen.html`：33 条音频、原参考转写、抽样理由与来源，可在浏览器播放。
- `listening_manifest.json`：所选 ID、信号统计、筛选理由、逐条 `human_listening_status=pending`。
- `rows.jsonl`：全 1,130 条的元数据、参考转写、音频哈希、检查结果；未把异常条目静默剔除。
- `samples/`：所选原始音频字节。

抽样使用固定 seed `20261111`，包含随机分层及极端信号条件，服务于问题发现；**不能用这 33 条估计整体准确率**。主观核验项包括：切分是否截词、转写与发音是否一致、口音、噪声、串音、疑似削波的听感影响。当前均未标记完成。

## 后续计分建议

后续已补查到公开的长尾词/上下文专项基准，见[调研补充](../../interviews/2026-11-11-contextual-asr-benchmark-followup.md)。下面“另补专项集”不要求先自行采集，可优先采用现成基准。

继续使用 ASCEND 作为公共混说基线，另补真实软件/LLM 技术口述专项集。后续正式推理可覆盖全部 1,130 条，并完整保存原始输出与失败记录；计分前冻结以下规则：

1. 单独记录 63 条 `[UNK]` 样本。不把标记作为英文单词，也不只从参考中删掉它却让对应预测继续参与同一计分，从而引入不明惩罚。
2. 在尚未核实官方未知片段计分规范时，可预先约定以无 `[UNK]` 的 1,067 条为自定义 clean-reference 评分子集、其中 191 条为 mixed 子集；63 条单列诊断。明确这不是官方 validation 全集口径，不直接与论文数字比较。
3. MER 使用中文按字、英文按词的混合序列，汇总总编辑数/总参考单位数；分语言、说话人和主题报告。先固定大小写、数字、口头词、标点与英文连写规则。
4. 固定 ASR 模型与解码配置，禁止根据参考答案逐句选模型；原始 ASR 与规则整理分开记录，不启用上下文纠错来冒充原始识别基线。

这些是检查后的评测建议，本轮尚未实现或运行评分。

## 复现

依赖锁见 [requirements.lock.txt](requirements.lock.txt)，结构化结果见 [summary.json](summary.json)。本次使用 macOS arm64、Python 3.13.9；脚本读取固定文件 SHA，不接受未经核查的其他版本。

```sh
uv venv build/ascend-validation-audit/.venv --python 3.13
uv pip install --python build/ascend-validation-audit/.venv/bin/python -r docs/evidence/2026-11-11-ascend-validation-audit/requirements.lock.txt
mkdir -p build/ascend-validation-audit/data
curl -fL --retry 2 --connect-timeout 15 --max-time 600 --output build/ascend-validation-audit/data/validation.parquet 'https://hf-mirror.com/datasets/CAiRE/ASCEND/resolve/737e9800ae31be9932ba8464c80366559bd28424/main/validation-00000-of-00001.parquet'
build/ascend-validation-audit/.venv/bin/python tools/audit_ascend.py --parquet build/ascend-validation-audit/data/validation.parquet --output build/ascend-validation-audit/inspection
```

原始数据、环境与试听包均留在 ignored 的 `build/`；仓库记录检查脚本、依赖锁和聚合结果。
