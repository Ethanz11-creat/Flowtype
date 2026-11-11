# 科大讯飞面试：四模块调研与交付设计

日期：2026-11-11。状态：调研完成后的待执行方案；本文不代表新增模型、VAD 或客户端联调已完成。

需求依据：[岗位与用户要求](2026-11-11-iflytek-speech-llm-requirements.md)。目标是面试前形成可解释、可演示、可复现的项目证据。用户明确不以科研创新、发表论文或 SOTA 为当前目标。

## 1. 总体结论

四个模块组成同一条工作链：准备真人语音与参考 → 比较模型 → 比较分段方式 → 检查上下文纠错 → 输出报告与面试材料。

交付采用 **Python 评测入口＋离线 Swift/MLX 推理进程＋PyTorch Whisper/Silero**。保留既有客户端和旧实验原始文件；新增工作集中在 `tools/interview_bench/`，不为了评测扩展应用启动模式或放宽自测隔离权限。

首轮目标是三个模型配置、三种分段策略、两套纠错场景，以及一条能实时回放并逐段显示文字的实验链路。产品中的原生 WhisperKit 接入和真实麦克风落字，使用现有客户端另作演示，不能将实验原型说成已集成的新产品功能。

## 2. 已完成与真实缺口

| 模块 | 已有事实 | 本次仍需补齐 |
| --- | --- | --- |
| 多模型 | Qwen 1.7B MLX 4bit 已对 ASCEND 1,130 条、LibriSpeech pilot 200 条真实推理 | 0.6B 与跨架构模型的相同数据对照；统一性能测量 |
| VAD 与延迟 | `SpeechPreflight` 为保守能量/峰值预检；speech-swift 含 Silero v5 实现 | 有因果时间顺序的分段回放、ASR 队列、边界与延迟测量 |
| 上下文纠错 | 英语 pilot 中普通纠错退化；词表组 B-WER 11.46%→5.93%，U-WER 1.90%→2.00% | 中英混说误改检查、错配词表控制；复核服务延迟与失败 |
| 评测工具 | 已有准备、推理、评分、逐句诊断和哈希验证脚本 | 统一运行清单、批次标识、结果表及一条执行命令 |

证据：[原始基线](../evidence/2026-11-11-asr-baselines/README.md)、[纠错 pilot](../evidence/2026-11-11-contextual-asr-correction/README.md)。旧 `tools/evaluate_asr.py` 会按参考答案逐句选择错误率较低的模型，属于 oracle，不作为新评测入口。

## 3. 多模型方向调研与选型

### Qwen3-ASR

[官方模型卡](https://huggingface.co/Qwen/Qwen3-ASR-0.6B)说明 0.6B/1.7B 支持 30 种语言和 22 种中文方言，并提供离线与流式能力。官方工具链的流式推理当前要求 vLLM；不能据模型支持流式，宣称本项目的同步 Swift `transcribe` 已支持原生增量解码。

本机已有 1.7B 4bit 权重，具体身份以旧实验的文件 SHA-256 为准，上游 revision 未知。不能因为安装预设里有 revision 就追认本地权重来自该版本。

0.6B 候选 [aufklarer/Qwen3-ASR-0.6B-MLX-4bit](https://huggingface.co/aufklarer/Qwen3-ASR-0.6B-MLX-4bit)已核元数据：revision `bc441bd1e4295c1f42d9879f056049a925b6e013`；配置 `model_type=qwen3_asr`、4bit、group_size=64，与现有原生格式支持一致。这只是格式证据，下载完整性、加载和真实识别仍需实测。

两个 Qwen 配置均使用现有产品参数：maxTokens=448、temperature=0、repetitionPenalty=1.1、noRepeatNgramSize=3、language/context=nil。比较它们能回答“相同模型家族在本机如何权衡体积、准确率和耗时”。

### Whisper

[OpenAI 官方说明](https://github.com/openai/whisper)列出多语言 base 74M、small 244M；英文专用 `.en` 版本不适合本次中文/混说对比。官方相对速度表在 A100 英语上测量，不能直接用于本机 M1 预估。

**基础对照选择多语言 Whisper base，PyTorch CPU FP32；small 为完成基础矩阵后的扩展。**原因是 Python 3.11 与 ffmpeg 本机已具备，用户熟悉 PyTorch，官方接口直接可用；同时避免把当前 WhisperKit Core ML 图、分词器与临时编译适配变成评测前置阻塞。

初始依赖使用 `openai-whisper==20250625`、`torch==2.8.0`，在隔离 Python 3.11 环境解析并冻结依赖。已核 PyPI 存在 torch 2.8.0 的 cp311 macOS arm64 wheel，仍需安装验证。官方 base 权重预期 SHA-256 为 `ed3a0b6b1c0edf879ad9b11b1af5a0e6ab5db9205f891f668f8b0e6c6326e34e`，执行时与固定包内模型注册表双重核对。Whisper 按 16kHz float32 数组输入，task=transcribe、language=None、temperature=0.0、condition_on_previous_text=False、fp16=False、无初始提示；不使用默认多温度回退序列。CPU 线程数固定为 4，记录实际解析的解码选项。

**比较的对象是模型与运行后端的组合。**Qwen MLX 4bit 与 Whisper PyTorch CPU FP32 的时间、内存不能用来证明架构本身谁快。准确率也受模型规模、量化和解码设置影响，报告中列明全部因素。PyTorch Whisper 是实验对照，不冒充 FlowType 原生 WhisperKit 的性能。

原生 WhisperKit 已锁定 0.18.0，代码包含本地分词器、图校验和编译处理；tiny/base 的安装预设均仍为 `verified=false`。本轮查到仓库存在对应组件，不代表已验证加载。可作为后续客户端联调扩展，本次不调整其隔离策略来跑实验。

### 评测范围

- 三个基础配置：Qwen 0.6B MLX 4bit、Qwen 1.7B MLX 4bit、Whisper base PyTorch CPU FP32。
- 同一 ASCEND validation 全 1,130 条推理；主分数沿用 1,067 条 clean-reference 和 mixed 191 条的冻结 MER 口径；63 条含 `[UNK]` 单列。
- 先对确定性选取的 10 条做接入与资源检查，不按输出优劣更换模型或选样本。
- 模型加载、预热、逐句推理和整批墙钟时间分开。性能批次三个模型分别新进程串行运行，不与其他评测并行争用资源。
- 旧 1.7B 准确率可以作历史参照；可比性能需在相同测量协议下重跑。新旧输出有差异时保留两批并解释，不覆盖旧文件。
- RSS 通过 `/usr/bin/time -l` 记录，单位与 macOS 含义明确；它不是完整 GPU 显存，也不能代替统一内存总占用。

## 4. VAD、分段与低延迟方向调研

[Silero 官方仓库](https://github.com/snakers4/silero-vad)支持 PyTorch/ONNX 和 8/16kHz。本次固定 **v5.1 commit `84768cefdf5a3852400e9d8237f7315d14b64a08`**，不是随时变化的最新版；已通过 Git tree 确认 TorchScript 文件 `src/silero_vad/data/silero_vad.jit`，2,269,612 bytes，Git blob `63cb73be394528ef8d4936fdaa4884890754d065`。下载后补文件 SHA-256。

本项目依赖的 Swift Silero v5 也是 16kHz、512 samples/32ms 的逐块接口，携带循环状态。模型状态必须在会话间清空，不能每帧清空，也不能跨会话复用残留状态。Python 方案使用官方固定 TorchScript 模型、CPU 1 线程，便于与用户熟悉的 PyTorch 对接；本轮不将 Swift/MLX 转换版与官方 TorchScript 版视为逐帧完全相同。

**选择流式逐块调用，不使用先分析完整文件再假装实时的离线 VAD 切片。**Python 按单调时钟、每 32ms 投递 PCM；VAD 与 ASR 分离，ASR 为持久化单进程串行推理，记录排队时间。音频仍按时到达，不能在 ASR 忙时暂停回放计时来获得好看的延迟。

### 比较条件

1. 整段：收齐会话后识别一次。
2. 固定分段：每 5,000ms 切一段，末尾 flush，无重叠；作为简单工程基线。
3. Silero：onset=0.5、offset=0.35、min_speech=96ms；结束静音分别 300/600/900ms；前缓冲 160ms、后缓冲 100ms；最长段 10,000ms。

这里的值是预先选定的对照条件，不声称最优。min_speech 用于确认事件；短于96ms但已有语音概率的待确认候选遇结束或EOF时仍以 short_candidate 提交ASR，不能因flush逻辑悄悄丢弃。使用 1.7B ASR 固定模型，不同时扩大到模型×词表×所有 VAD 参数的全排列。三个静音条件在开发回放上全部展示；评测回放固定 600ms，不按评测结果改默认值。

端点判定晚于候选语音结束是正常现象，必须分别保存 `speech_end_sample` 与 `decision_sample`。保存片段所有权，前后缓冲不得重复提交同一音频；最长段强制切分保留连续采样边界，不悄悄丢弃过长音频。队列上限 4 个待处理片段，溢出标记该会话失败并保留事件记录，不静默跳段。

### 数据与真实程度

ASCEND 已有真实人声但没有本次可直接使用的精确语音起止标签，不能把文件结束当成说话结束，也不能用被测 Silero 自动标注后评估自己。

从 clean-reference 按 ID 哈希确定选取 36 条（zh/en/mixed 各 12 条），不按 ASR 错误选样。每组前 4 条为开发、后 8 条为评测，即开发 12 条、评测 24 条。人工试听并标记语音起止及明显内部停顿，记录标注人和状态。无法人工确认的边界标为 pending，不发布对应端点延迟结论。

将开发 12 条组成 3 个回放会话、评测 24 条组成 6 个回放会话，每会话 4 条；每条来源只属于一个划分。会话开头和末尾各加 1s 数字静音，内部间隔依次为 400/600/1,200ms。原始人声不变、不重采样。拼接会话是**由真人语音构造的回放**，不是自然连续会话；人工边界与插入静音信息不能提供给 VAD/ASR 决策器。

另设数字静音、正弦等少量逻辑控制，只说明处理行为，不冒充真实环境噪声或噪声鲁棒性测评。旧 `tools/eval_data` 的 25 条 macOS `say` 合成样本同样只作接入检查。

### 需要测量的量

- 首段文本延迟：首个非空 ASR 片段返回时刻 − 回放起点；不是模型首 token 延迟。
- 端点判定延迟：VAD 发出结束事件时刻 − 人工标注的实际语音结束时刻；允许负值，不能截断为 0 掩盖过早切段。
- 最终文本延迟：全部结果返回时刻 − 最后一个人工语音结束时刻。
- 队列等待、逐段推理时间、处理积压、强制切分次数、失败会话数。
- 同一完整会话的 MER、插入/删除/替换数；漏字或重复是否发生在切分附近，需结合样本人工核对，不能把全部删除都称作“VAD 截断”。

6 个评测回放会话全部列出延迟；中位数为摘要，不用如此少的会话宣称稳定 p95 SLA。要报告 p95，另扩至至少 30 个预先固定回放会话，并仍注明样本量与构造分布。

## 5. 上下文纠错方向调研与范围

已做出的三组实验足以作为主体，不必先训练纠错模型。下一步用同一 DeepSeek-V3、冻结提示和原始 ASR，检查“正确上下文有用时，错误上下文会不会更危险”。

### 英语长尾词

复用官方 [LibriSpeech contextual biasing](https://github.com/facebookresearch/fbai-speech/tree/main/is21_deep_bias)固定 200 条，比较原始 ASR、普通 LLM、正确候选表、错配候选表。正确表为第四列完整列表，包含干扰词；不能只提供第三列实际命中目标词。

错配条件将按 ID 排序后的完整列表循环移给下一条样本，保留长度和干扰词。它可能偶然覆盖当前目标，故准确称“错配词表”，评分阶段另报实际覆盖率；不按参考答案删掉重合词，也不宣称完全无关。

为降低不同调用时间/服务别名变化的影响，新一轮普通、正确表、错配表三个 LLM 条件同批交错提交（600 次上限）。旧结果保持原样，作为已完成探索证据。服务没有固定权重版本时明确记录这个限制。

指标仍为官方 WER/B-WER/U-WER、逐句改善/退化、原本正确句子的误改率、fallback 和网络延迟。B/U 分类使用第三列参考目标词，只在评分器内部访问。

### 中英混说

复用 ASCEND clean mixed 191 条，比较原始 ASR、普通 LLM、固定技术词表 LLM（382 次请求上限）。技术词表从项目 `tech_terms.json` 的规范词中确定性生成、最多 100 项，在读取这组参考文本前冻结，不逐句注入正确词。

这组主要检验真实混说是否被改坏，以及与场景无关的技术词表是否干扰识别。ASCEND 未覆盖本项目筛查的 30 组技术词，不能将它写成 PyTorch/LoRA 术语纠错专项成绩。词表命中率及覆盖在冻结后的评分阶段报告。

没有足够自然技术口述时，先保留这个结论边界；不把合成音频或临时录制的少量演示句包装成主流基准。用户自己的 10～20 条技术口述可作为可选演示材料，但不是当前必须等待的依赖。

### 成本与成功标准

完整新增矩阵最多 982 个主请求，接入检查最多 6 个，总请求硬上限 1,000；服务已报告总 token 达到 1,000,000 时停止新请求，输出 incomplete 状态。token 是软停止阈值，最多4个在途请求仍会完成，失败请求也可能缺用量，故该数字不是用量或账单硬上限。未查到当前账户价格前不填写预计人民币费用。

失败、截断、空响应按既有协议保留原文，不重试或换厂商；所有样本继续参与有效管线评分。报告成功接口与原文回退数，不能把错误回退说成 LLM 成功。

完成标准是对照齐全、来源可追溯、结果可解释，**不要求所有指标改善**。无关上下文造成退化本身就是面试中可以讲的工程发现。

## 6. 评测工具设计

Python CLI 负责清单、准备、串行模型运行、实时回放、纠错任务和报告；Swift 推理 worker 只接收 id/path，不读取参考。VAD 仅接收截至当前帧的音频；纠错仅接收冻结识别文本和该条件允许的词表。评分器后置读取参考，任何参数选取都不能使用逐句答案挑选模型输出。

公共结果字段：`id/model_id/text/status/error_code/latency_seconds/audio_seconds`。每个运行有独立目录，包含冻结配置、输入与模型文件哈希、执行源码/二进制身份、依赖版本、预测、评分及验证记录。旧 JSONL 通过适配器读取，原件不改。

所有基础模型串行运行；仅 LLM 网络请求允许 4 路并发。VAD 与单个 ASR worker 的必要并行是回放管线本身，记录积压，不与其他 benchmark 同时进行。性能数据写清实际后台应用状态、构建模式和测量条件，不自动关闭用户客户端。

报告必须带样本量、参考单位分母、失败/空输出数、模型与后端、是否真人录音/构造回放/合成控制。缺失、重复、额外 ID 或来源哈希变更时停止正式汇总，保留 partial 文件用于诊断。

不新增 Web 平台、数据库、模型训练或自动选模。评测入口与报告可以在面试时直接演示；产品客户端展示则用现有真实能力，并在材料中区分。

## 7. 方案取舍

| 路线 | 优点 | 主要代价 | 决定 |
| --- | --- | --- | --- |
| 全部走原生客户端 | 与产品部署一致 | 需要改应用运行隔离、验证原生模型和集成实时分段 | 后续产品联调，不作为本轮主路线 |
| Python＋现有 Swift worker | 复用真实基线；PyTorch 易理解；不改用户设置；可独立复现 | 后端不同，性能必须按部署组合解释 | **推荐并写入计划** |
| 云端 ASR 大范围横评 | 接入快、能覆盖厂商 | 网络/计费/服务版本变量；不能替代本地延迟 | 时间充裕时扩展，不纳入完成前置条件 |

## 8. 交付与时间边界

面试具体日期未确认；以 4 个工作日安排，可压缩到 2 日最小范围。时间是执行预算，不是已验证工期。最多同时使用 1 个子智能体，当前调研和计划编写未启动子智能体。

完整交付：三模型同集报告、VAD 回放与边界/延迟报告、纠错两场景报告、统一 CLI 与归档验证、3 分钟项目讲解及追问材料。面试前一天冻结方法，最后一天用于理解与演练；不以改善百分比达标作为结束条件。

2 日收缩：Qwen 1.7B＋Whisper base 同集对照；整段/固定分段/600ms VAD 在相同 6 个回放上的完整比较；已有纠错结果＋新增错配词表 200 请求；统一报告与讲述。0.6B、阈值扫查、ASCEND 纠错扩展和 Whisper small 明确记为未执行，不能混入完整矩阵。

产品发布、71 项真机验收、论文创新与训练任务不作为本次面试计划的完成条件。原生客户端演示和人工边界标注仍需要实际检查，不能由单元测试代替。

## 9. 来源与核验方式

| 来源 | 核验内容 | 证据边界 |
| --- | --- | --- |
| [Qwen 官方模型卡](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) | 模型规模、语言、官方流式后端限制 | 通过 HF 镜像读取；非本机测速 |
| [0.6B 固定转换配置](https://huggingface.co/aufklarer/Qwen3-ASR-0.6B-MLX-4bit/blob/bc441bd1e4295c1f42d9879f056049a925b6e013/config.json) | 架构、4bit、group64、revision | 元数据检查，未下载权重 |
| [Whisper 官方仓库](https://github.com/openai/whisper)及[解码代码](https://github.com/openai/whisper/blob/86098128c0b4f24f0e2aa2994de830614b474227/whisper/transcribe.py) | base/small、PyTorch、默认温度回退、语言选项 | main 资料与计划固定包版本分别记录 |
| [Whisper PyPI](https://pypi.org/project/openai-whisper/20250625/) | 公开版本、Python 要求 | 未安装或运行新模型 |
| [Silero v5.1 固定版本](https://github.com/snakers4/silero-vad/tree/84768cefdf5a3852400e9d8237f7315d14b64a08) | JIT 路径、文件大小、Git blob、许可路径 | 不是当前 PyPI 最新 6.2.3；不混用版本 |
| [WhisperKit 模型仓库](https://huggingface.co/argmaxinc/whisperkit-coreml)及本地锁定源码 | 模型组件、离线加载与产品适配点 | `verified=false` 仍需真机验证 |
| [ASCEND](https://huggingface.co/datasets/CAiRE/ASCEND)、[官方 biasing 扩展](https://github.com/facebookresearch/fbai-speech/tree/main/is21_deep_bias) | 复用固定数据与既有实测 | 本轮不重复声称取得新模型成绩 |

网络原始读取与内容哈希见[来源清单](2026-11-11-iflytek-four-module-sources.json)。原文缓存位于 ignored `build/research/2026-11-11-iflytek-four-modules/`。HF 主站部分请求超时，改用镜像并记录实际 URL；GitHub 部分 raw 失败改读 Git blob API，不关闭 TLS。本文没有引用不可访问页面的未核实具体数值。

许可分别记录：ASCEND CC-BY-SA-4.0，LibriSpeech CC-BY-4.0，Qwen 转换模型卡 Apache-2.0，Whisper 代码/权重 MIT，Silero MIT。下载转换权重时仍核对实际仓库声明，原始音频不嵌入客户端发行包。
