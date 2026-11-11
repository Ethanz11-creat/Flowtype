# 2026-11-11 原始 ASR 基线协议

本轮先固定原始识别输出，为后续上下文纠错提供相同输入。尚不能以原始基线说明任何纠错收益。

## 运行边界

- 模型：本机现有 `aufklarer/Qwen3-ASR-1.7B-MLX-4bit`，离线加载。
- 复用项目锁定的 speech-swift / MLX 依赖，不改应用的录音、设置或路由。
- 逐句调用 `Qwen3ASRModel.transcribe`，解码参数与当前 `QwenASRProvider` 一致：`maxTokens=448`、`repetitionPenalty=1.1`、`noRepeatNgramSize=3`、`temperature=0`、语言自动、无上下文。这是当前产品参数的模型输出，不能称为上游模型默认解码。
- 无 ASR 后处理、无 LLM 整理、无备用模型或参考答案选模。输入清单仅含音频路径与 ID，不向推理器提供参考转写、语言标签、主题或词表。
- 模型上游 revision 未保存在本地安装记录中，不猜测。以[运行身份记录](run-metadata.json)中的文件 SHA-256、配置、依赖 pins 和二进制 SHA-256 界定本次执行。
- 检查了 3 条真实音频的推理接入输出后启动全量 ASCEND；没有根据这些输出调整模型或参数。它们不是独立盲测样本。

## ASCEND

- 固定 revision：`737e9800ae31be9932ba8464c80366559bd28424`，validation 全部 1,130 条。
- 为全部样本保存原始输出。63 条含 `[UNK]` 的参考转写只作单列诊断，不把标记当英文词计分。
- 预先约定无 `[UNK]` 的 1,067 条为自定义 clean-reference 子集，其中 mixed 191 条；不得称为官方全 validation 口径或直接与论文数字对比。
- 评分规则：Unicode NFKC + casefold，弯引号统一为 ASCII 撇号；汉字逐字，字母词逐词，数字连续串作一个单位；保留字母词内部撇号，其他标点形成边界。不转换数字拼写，不删除口头词，不改繁简。
- 主指标为混合 token 的总编辑数/总参考单位数（MER），使用 jiwer 4.0.0 的标准单位编辑代价；另按语言标签、主题、说话人报告相同口径。
- 失败请求按空假设计漏字，空成功输出也参与计分；任何缺失、额外或重复 ID 都阻止生成完整运行报告。
- 这是已查看标注的开发/验证集基线，不宣称最终 held-out test 或独立外部泛化。

## LibriSpeech contextual biasing 接入验证

- 官方 test-clean 音频全包 MD5：`32fa31d27d2e1cad72775fee3f4849a9`，已与 OpenSLR 校验表匹配。
- fbai-speech 100 词表参考文件 Git blob SHA-1：`3b65fb715bd42f3bf6c927aabe5a3ad1861031b5`；2,620 条参考与原 LibriSpeech 转写小写化后逐条一致。
- 首轮使用**自定义 200 条 pilot**，按 `SHA256('20261111:' + utterance_id)` 排序，每位说话人选前 5 条，覆盖 40 人、约 28.21 分钟；不读模型输出或稀有词标注决定样本。
- 选择清单及哈希见 [librispeech-selection.json](librispeech-selection.json)。本轮没有运行完整 2,620 条 test-clean，不报告官方全量 test-clean 成绩。
- 音频从 FLAC 解码并写为 WAV，全部 200 条均校验 PCM 样本完全相同；不重采样、降噪或改变音量。
- 无上下文模型基线，词表只保存在独立参考清单中，不提供给模型。
- 使用官方 `score.py` 计算 WER、U-WER、B-WER。它实际按 TSV 第三列的参考稀有词划分类别，不能把 B-WER 误称为完整第四列提示/干扰词表的错误率。
- 官方脚本使用插入/删除代价 3、替换代价 4 确定对齐路径，与 ASCEND 的单位代价对齐分开记录。实现身份及假设规范化规则见 [librispeech-scoring-protocol.json](librispeech-scoring-protocol.json)。
- 原始音频为 CC-BY-4.0，官方 fbai-speech 评分软件为 MIT。本地原始数据与第三方脚本保留在 ignored `build/` 中。

## 延迟解释

逐条延迟包含 WAV 读取与同步模型推理，以及调用中可能触发的图编译，不含模型加载。接入检查已使用同一模型与 GPU，可能复用系统/驱动缓存，不能称为机器冷启动。当前依赖产物为 debug，且用户客户端仍在运行，不能把本次时间直接当作 release 端到端交互性能。报告中保留首条、全部中位数、p95、总推理秒数与总音频秒数。

## 复现工具

- [构建独立原生推理器](../../../tools/build_native_asr_baseline.py)：在已有 `swift build` 产物基础上链接，排除应用自身对象，不修改 Package.swift。
- [推理器源码](../../../tools/NativeASRBaseline.swift)：只接受音频清单、输出路径、模型目录与样本上限；输出文件必须是新文件。
- [ASCEND 导出](../../../tools/prepare_ascend_baseline.py)、[LibriSpeech pilot 准备](../../../tools/prepare_librispeech_biasing.py)。
- [ASCEND 评分](../../../tools/score_asr_baseline.py)、[评分行为测试](../../../tools/test_score_asr_baseline.py)。
- [Python 依赖锁](requirements.lock.txt)。原始音频与逐条参考受源数据许可约束，不嵌入产品发行包。
