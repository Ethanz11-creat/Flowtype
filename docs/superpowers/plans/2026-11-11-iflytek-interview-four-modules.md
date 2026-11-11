# 科大讯飞面试四模块 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Preserve the user's limit of at most one active subagent; do not delegate unless execution is authorized.

**Goal:** 面试前完成多模型对比、VAD 分段回放、上下文纠错和统一评测工具，交付真实结果、可演示原型及用户能理解的项目讲述。

**Architecture:** 在 `tools/interview_bench/` 建立 Python CLI，复用既有固定数据与评分器。Qwen 通过独立 Swift/MLX 常驻 worker 推理，Whisper 和 Silero 使用隔离 Python 3.11/PyTorch CPU 环境；评分后置读取参考，完整保留旧实验。客户端继续使用现有真实能力，实验原型与产品集成分别标识。

**Tech Stack:** macOS Apple M1/16GB；现有 speech-swift 0.0.15/MLX pins；Python 3.11；torch 2.8.0；openai-whisper 20250625；Silero v5.1 TorchScript；NumPy/SoundFile/jiwer；JSONL/Markdown。

**Spec:** [四模块调研与交付设计](../../interviews/2026-11-11-iflytek-four-module-research.md)；[面试需求](../../interviews/2026-11-11-iflytek-speech-llm-requirements.md)。本计划是本次交付，不在写完后自动开始下载、实现或调用服务。

## Global Constraints

- 目标为科大讯飞面试准备，不以科研创新、发表论文或 SOTA 为当前目标。
- 最多同时使用 1 个子智能体；默认逐任务执行，性能批次不得并行运行多个待比较模型。
- 新增实现集中在 `tools/interview_bench/`；不改用户设置、录音路由、默认模型或运行中的客户端，不放宽应用自测隔离。
- 旧基线/纠错源码、协议、预测和归档保持原样；新运行使用新的目录和身份记录，禁止覆盖。
- 原始推理输入不含参考答案；VAD 不读未来音频；LLM 不接收参考转写或第三列实际命中稀有词。
- ASCEND 固定 revision `737e9800ae31be9932ba8464c80366559bd28424`；1,130 条推理、1,067 条 clean-reference 主评分、mixed 191 条。
- Qwen 0.6B 固定 revision `bc441bd1e4295c1f42d9879f056049a925b6e013`；已有 1.7B 用文件 SHA-256 标识，不猜上游 revision。
- Qwen 参数 maxTokens=448、temperature=0、repetitionPenalty=1.1、noRepeatNgramSize=3、language/context=nil。
- Whisper base 多语言、PyTorch CPU FP32、4 线程；temperature=0.0、condition_on_previous_text=False、task=transcribe、language=None、无初始提示。
- Silero v5.1 commit `84768cefdf5a3852400e9d8237f7315d14b64a08`；16kHz/512 samples；CPU 1 线程，独立会话 reset。
- VAD onset=0.5、offset=0.35、min_speech=96ms；静音300/600/900ms；前缓冲160ms、后缓冲100ms；最长段10,000ms；待处理片段上限4。
- 完整纠错主请求最多982次，含接入检查请求硬上限1,000次；服务已报告token达到1,000,000停止新请求，最多4个在途请求完成，此值不是用量或账单硬上限；原文回退全部计分，不重试、不换厂商。
- 无论指标改善或退化，满足预定矩阵和证据要求即完成；不根据结果反复刷提示词或选样本。

## Review Focus

1. 原始数据/候选词表字段混用导致答案泄漏；Task 1 和 Task 5 用字段白名单与故意含秘密答案的输入验证。
2. 缺失、重复或额外 ID，API 失败被静默剔除；Task 1/2/5 拒绝不完整正式报告，保留失败与回退原文。
3. 实时回放偷看完整音频、ASR 阻塞时暂停音频时钟、计时基准混用；Task 4 用虚拟时钟和延迟 worker 验证因果顺序及积压。
4. 短词、末帧、连续长语音或缓冲重叠造成音频丢失/重复；Task 4 验证 EOS、候选短段、强制切分和样本所有权。
5. 模型/进程串用、隐式下载、参考驱动 fallback 或后端差异被隐去；Task 2/3/6 校验模型身份、离线读取、并发与报告标签。

---

## 交付顺序与模块对应

```text
Task 1 冻结数据与公共协议
    → Task 2 推理 worker 与独立运行入口
    → Task 3 多模型真实评测
    → Task 4 VAD 分段与实时回放
    → Task 5 上下文纠错补测
    → Task 6 汇总、验证、演示与面试材料
```

统一评测工具贯穿所有任务。Task 3/4/5 各自产出可单独检查的报告；某一扩展失败不能把已经完成的其他模块回滚成“没有结果”。

## 文件职责

| 路径 | 职责 |
| --- | --- |
| `tools/interview_bench/__main__.py` | argparse 入口，prepare/models/replay/correction/report/verify 子命令 |
| `tools/interview_bench/schema.py` | 清单、模型身份、预测和运行协议的校验 |
| `tools/interview_bench/prepare.py` | 复用 ASCEND/LibriSpeech；冻结技术词表、36 条 VAD 来源及划分 |
| `tools/interview_bench/assets.py` | 按固定来源下载、校验模型与许可，不访问应用设置 |
| `tools/interview_bench/build_native.py` | 读取现有 SPM 产物构建新 worker，不覆盖旧 runner |
| `tools/interview_bench/swift/NativeASRBench.swift` | Qwen 离线加载、ready 事件及串行 JSONL 推理协议 |
| `tools/interview_bench/backends.py` | 常驻 Qwen worker、Whisper CPU 适配与生命周期 |
| `tools/interview_bench/models.py` | 串行模型批次、测时与进程峰值 RSS 归档 |
| `tools/interview_bench/vad.py` | 固定 Silero 模型、逐块状态机、片段所有权 |
| `tools/interview_bench/replay.py` | 因果音频回放、ASR 队列、事件/延迟记录 |
| `tools/interview_bench/annotate.py` | 输出试听/波形标注页，导入带状态的语音区间 JSON |
| `tools/interview_bench/correction.py` | 冻结三种 LLM 条件与预算，复用旧提示/解析函数 |
| `tools/interview_bench/report.py`、`verify.py` | 复用现有评分器，出报告、检查完整性和哈希 |
| `tools/interview_bench/configs/*.json` | 三模块固定参数；模型路径在运行时传入，不保存凭据 |
| `tools/interview_bench/tests/test_*.py` | 字段隔离、失败、进程生命周期、分段与计时行为 |
| `docs/evidence/iflytek-interview/<run-id>/` | 审核后的协议、汇总、预测、验证、许可和复现说明 |
| `docs/interviews/2026-11-11-iflytek-project-walkthrough.md` | 项目讲述、追问及事实边界 |

不改 `Package.swift`；构建 helper 沿用现有依赖对象链接方法，新二进制放 `build/interview-bench/bin/native-asr-bench`。若当前 SPM 产物失效，先运行现有 `swift build` 重建，不转而修改应用启动模式。

命令约定：Task1 中的 `python` 使用现有 `build/ascend-validation-audit/.venv/bin/python`；Task2 建好新环境后，后续所有 `python` 使用 `build/interview-bench/.venv/bin/python`。从仓库根目录执行；不改变全局 Python 或覆盖旧环境。Swift helper 需要完整 Xcode/CLT 可用的现有构建工具链，具体路径记录进运行元数据。

## Task 1：冻结输入、配置与结果协议

**Files:** Create `schema.py`、`prepare.py`、`__main__.py`、`configs/{models,vad,correction}.json`、`tests/test_schema.py`、`tests/test_prepare.py`。

**Interfaces:**
- `load_audio_inputs(path: Path) -> list[dict]`：每行仅 `id/path`，音频身份/时长放独立 manifest。
- `validate_predictions(expected_ids: list[str], rows: list[dict]) -> None`：预测需含 `id/model_id/text/status/error_code/latency_seconds/audio_seconds`，status 为 `ok/error`；失败以空有效假设计分。
- `prepare(root: Path, source_root: Path) -> Path`：生成 `root/prepared/manifest.json`、各集 inputs/references、词表与 VAD 划分；不做模型推理。
- `freeze_run(config: dict, inputs: Path, output: Path) -> dict`：创建新目录，保存配置、输入、来源/工具哈希和 UTC 时间；已有目录拒绝覆盖。

- [x] **1.1 写失败测试。** 重复/缺失/额外 ID 均抛 `ValueError`；故意含 `transcription='SECRET'` 的参考不进入 id/path 推理清单；已有输出目录拒绝覆盖。VAD 36 来源无重复、zh/en/mixed 各12、开发12/评测24无交集；同一输入重复准备得到相同划分。
- [x] **1.2 跑红灯。** `python -m unittest discover -s tools/interview_bench/tests -p 'test_schema.py'`，确认因尚无接口失败；prepare 测试同理。
- [x] **1.3 实现接口。** 优先读取既有导出 JSONL；按 `SHA256('iflytek-vad-v1:'+id)` 每语言选12条，前4开发/后8评测。技术词表为 `tech_terms.json` 所有规范值的去重排序结果、最多100项，先独立冻结再分析参考覆盖；该文件当前只有29条映射，不能假称已有100词。LibriSpeech 保留原200条，不重选。
- [x] **1.4 跑绿灯及真实准备。** `python -m tools.interview_bench prepare --root build/interview-bench --source-root build/asr-baseline-20261111`；检查 ASCEND 1130/1067/191、LibriSpeech200、VAD36及来源哈希。
- [x] **1.5 独立检查本任务差异并记录提交。** 只纳入本任务工具和配置；提交不得夹带旧实验未提交文件或用户其他修改。

## Task 2：隔离环境、模型资产与推理 worker

**Files:** Create `requirements.in`、`requirements.lock.txt`、`assets.py`、`build_native.py`、`swift/NativeASRBench.swift`、`backends.py`、`models.py`、`tests/test_backends.py`；Extend CLI 的 assets/models。

**Interfaces:**
- `NativeWorker(model_dir: Path, model_id: str, binary: Path)`；`start() -> dict` 返回含 `event='ready'/model_id/load_seconds` 的身份；`transcribe(id: str, wav_path: Path) -> dict`；`close() -> None`。
- worker stdin 请求仅 `request_id/id/path`；stdout 每请求恰好一个对应 JSON 对象，诊断只走 stderr。模型加载一次，推理串行，收到 EOF 清理退出。
- `WhisperBackend(model_path: Path, threads: int = 4)`，同名 `transcribe/close`；本地权重加载，音频由 SoundFile 转16kHz float32数组。
- `run_models(root: Path, model_ids: list[str]) -> Path`：每模型独立进程串行执行，写 `model-runs/<run-id>/<model-id>/`。

- [x] **2.1 写失败测试。** 未找到权重时加载立即失败且网络 spy 调用为0；响应 ID 不匹配、worker退出或非JSON时产生明确错误；两个并发请求进入原生 worker 时最大活跃推理数仍为1；close 后无子进程。失败样本仍占据完整预测ID，不换模型。
- [x] **2.2 跑红灯。** `python -m unittest discover -s tools/interview_bench/tests -p 'test_backends.py'`。
- [x] **2.3 建隔离环境并冻结依赖。** `uv venv build/interview-bench/.venv --python 3.11`；requirements.in 固定 torch==2.8.0、openai-whisper==20250625、numpy==2.2.6、soundfile==0.13.1、jiwer==4.0.0；使用 `uv pip compile` 解析传递依赖并冻结，安装到新环境。torch2.8 的 cp311 macOS arm64 wheel 已核存在，但安装与运行仍须验证。
- [x] **2.4 下载并验证资产。** Qwen0.6按固定HF revision；Whisper base使用包内官方模型URL，核对SHA-256 `ed3a0b6b1c0edf879ad9b11b1af5a0e6ab5db9205f891f668f8b0e6c6326e34e`；Silero用固定commit，核对JIT 2,269,612 bytes和Git blob `63cb73be394528ef8d4936fdaa4884890754d065`，另存SHA-256。模型存 `build/interview-bench/models/`；已有1.7目录只读。保留来源、许可、文件hash，不下载整个 WhisperKit 仓库，不把 LFS 指针当权重，不修改全局 HF_ENDPOINT。
- [x] **2.5 实现两种 backend 与新 Swift worker。** 从旧原生推理器复用已确认的调用方式，新增明确model_id参数，禁止仍把0.6B写成1.7B。`build_native.py` 输出新路径，保存命令与二进制hash。Whisper参数按全局约束，明确禁用默认多温度重试。
- [x] **2.6 跑绿灯、构建与10条接入检查。** Python测试通过；`python -m tools.interview_bench assets --root build/interview-bench --download`；`python -m tools.interview_bench models --root build/interview-bench --admission-only`。admission 选择同一固定10条、不得据识别好坏改选。加载失败、权重未校验或非预期身份均不启动正式批次。
- [x] **2.7 独立检查任务差异并记录提交。** 10条输出只作为接入/资源证据；无模型准确率达标门槛，不以预期收益决定是否允许跑全量。

## Task 3：完成三模型同集真实评测

**Files:** Extend `models.py`、`report.py`、`verify.py`；Create `tests/test_reporting.py` 与该批 evidence 目录。

**Interfaces:**
- `score_model_run(run_dir: Path, references: Path) -> dict`：复用 `tools/score_asr_baseline.py`，不改冻结 tokenization。
- `render_model_comparison(runs: list[Path], output: Path) -> None`：输出分组MER、编辑分母、耗时、RSS、加载时间、后端和失败数。

- [x] **3.1 写并跑报告行为红灯。** 1130预测缺1条不得给完整报告；63条UNK不进入clean分母；混合MLX/PyTorch时报告必须列engine、dtype、quantization、device。不同性能协议/构建模式出现显著标记，不把旧数据无标识拼入同一表。
- [x] **3.2 实现批次计时与评分。** 每模型新进程，加载计时后固定3条预热（仅计预热耗时），再重新执行全部1130条计正式耗时；预热不减少评分样本。保留首条、每条耗时与整批墙钟。`/usr/bin/time -l` 记录进程峰值RSS，单位bytes并注明其覆盖范围。
- [x] **3.3 正式运行。** `python -m tools.interview_bench models --root build/interview-bench --models qwen-1.7b,qwen-0.6b,whisper-base`。不同时跑其他模型批次；记录客户端/后台负载状态，不能自动杀用户进程。缺失或错误结果不得悄悄重试为成功。
- [x] **3.4 验证与出表。** 三模型各1130条、clean1067、mixed191，ID完整，模型身份/输入hash匹配；输出完整计分和10个固定规则选取案例（每模型先按ID选前3个非零错误，另选1个跨模型差异），说明是示例而非随机分布。
- [x] **3.5 归档、复核并记录提交。** 保留旧1.7基线；新结果与旧结果有差异时记录差异条数和构建身份。报告如实描述效果，不以“某模型必须赢”作为成功条件。

**完成标准：** 同数据的三模型真实结果及可复现命令齐全；若进入时间收缩，至少两个不同架构配置完成相同全部1130条，缺少的配置明确标为not_run。

## Task 4：VAD 分段原型、人工边界与实时回放

**Files:** Create `vad.py`、`replay.py`、`annotate.py`、`tests/test_vad.py`、`tests/test_replay.py`；Extend configs/CLI/report。

**Interfaces:**
- `SpeechSegment(start_sample: int, end_sample: int, decision_sample: int, reason: str)`；区间为左闭右开，reason为endpoint/max_duration/eos/short_candidate。
- `Segmenter.process(samples: np.ndarray) -> list[SpeechSegment]`、`flush() -> list[SpeechSegment]`、`reset() -> None`；只处理已接收PCM。
- `ReplayClock.now() -> float`、`ReplayClock.wait_until(deadline: float) -> None`：真实单调时钟与测试虚拟时钟使用相同接口。
- `run_replay(audio_path: Path, segmenter: Segmenter, worker: NativeWorker, clock: ReplayClock) -> dict`：保存分段、入队/出队/结果事件、样本所有权和失败状态。
- annotations为 `{id,status,annotator,spans:[{start_sample,end_sample}]}`；仅 `status=confirmed` 可用于语音结束延迟评分，推理接口不接收annotations。

- [x] **4.1 写并跑红灯。** 末帧不足512补零处理后输出边界不得超过原样本数；不同会话reset；不足96ms但有语音概率的候选在EOS仍以short_candidate提交；恒定高概率超过10s强制切且无采样缺口；相邻padding不重复样本；队列第5个等待片段使会话明确failed，不能丢弃后继续报成功。
- [x] **4.2 写计时/因果红灯。** 同一音频前缀配两个不同未来尾部时，该前缀内事件完全相同；模拟慢ASR时音频投递时钟继续前进、等待时间增加；过早结束得到负endpoint延迟；ASR ready/load完成前不开始回放计时。取消后停止投递并等待未取消的底层计算退出，再关闭worker。
- [x] **4.3 实现固定Silero加载和分段器。** TorchScript CPU1线程；512样本输入；模型与状态机独立重置。min_speech用于确认事件；未确认候选遇结束/EOF时输出short_candidate交给ASR，不暗中丢短词。三种结束静音参数按研究设计固定，最长10s和缓冲所有权均写入事件。
- [ ] **4.4 生成人工标注包。** `python -m tools.interview_bench replay --root build/interview-bench --prepare-annotations`；试听36条并确认起止/停顿，保留标注者。未试听不得将自动估计标为confirmed。没有confirmed边界时仍可跑MER与首段结果计时，但endpoint/final-from-speech延迟字段为null并给出manual_pending原因。
- [x] **4.5 构造固定回放并运行。** 3个dev/6个eval会话、每个4条、不跨划分复用来源；静音布局固定，运行前冻结当前人工标注及音频hash，之后修改标注需另起批次。dev跑整段/固定5s/VAD300/600/900；eval固定整段/固定5s/VAD600，不根据dev或eval成绩自动换参数。`python -m tools.interview_bench replay --root build/interview-bench --split dev`，再执行 `--split eval`。
- [ ] **4.6 验证、报告与演示。** eval三策略各6会话，在同一Qwen1.7worker配置上完整计MER、等待、首段文字和每会话延迟；6条延迟逐条展示，不包装为稳定p95。生成终端逐段文字演示及一个可播放/查看事件的HTML报告，录制60～90秒演示，注明构造回放。
- [x] **4.7 独立检查任务差异并记录提交。** 清楚区分分段增量输出、模型token streaming、现有客户端落字。若未人工标注或未录演示，标pending，不由自动测试代签。

## Task 5：英语错配词表与中英混说纠错实测

**Files:** Create `correction.py`、`tests/test_correction.py`；Extend CLI/report/configs；Import旧推理器的固定提示和响应解析函数，不修改旧源码。

**Interfaces:**
- `build_conditions(rows: list[dict], vocab: list[str], dataset: str) -> list[dict]`：英语生成plain/contextual/mismatched；ASCEND生成plain/static_tech；只包含id、原ASR文本、该条件候选词。
- `run_correction(root: Path, max_requests: int = 1000, max_reported_tokens: int = 1000000) -> Path`：固定一次加载的provider/model，写完协议后4路交错请求。
- `score_correction(run_dir: Path) -> dict`：计有效原文回退、官方B/U或冻结mixed MER、误改、用量缺失与请求延迟。

- [x] **5.1 写并跑红灯。** 故意含SECRET参考/目标稀有词的输入不得出现在请求；错配为完整词表循环置换且不偷偷去重合目标词；达到请求硬上限或已报告token软阈值后不启动新请求并标incomplete，在途至多4个请求仍须归档；HTTP失败/截断/空返回逐字保留原始ASR。原始ASR为空时不调用LLM，保留空文本和baseline_empty状态。
- [x] **5.2 实现准备与冻结。** 从旧protocol读取准确提示与参数；错配词表按既有200条ID排序循环分配下一行列表。ASCEND使用Task1冻结的规范技术词值，不读逐句答案构造词表。reference、rare_words、语言标签等字段禁止进入请求payload。
- [x] **5.3 小规模接入后运行固定矩阵。** 最多6次接入不调提示；`python -m tools.interview_bench correction --root build/interview-bench --allow-cloud`。英语3×200，上限600；ASCEND2×191，上限382。当前厂商/模型与预期SiliconFlow/DeepSeek-V3不一致时停止并报告，禁止静默替换；密钥仅内存读配置，不存CLI参数、协议、日志或服务器错误体。
- [x] **5.4 评分与控制核验。** 英语用同一官方脚本及hash；mixed用同一MER；额外读取参考计算正确/错配/技术词表覆盖率，但仅在推理后评分阶段。缺失、重复、额外condition/ID不得出完整结论；旧历史两组结果只作单独参照。
- [x] **5.5 出报告并记录提交。** 所有组同时列收益、普通词损失、原本正确句子误改、fallback、延迟和用量缺失。保留`ardor/ardour`等书写差异说明；ASCEND结果不命名为技术术语专项成绩。不开启根据本批错误逐句特判或反复调prompt的新迭代。

## Task 6：整体核验、面试材料与冻结

**Files:** Extend `report.py`、`verify.py`、`tests/test_reporting.py`；Create evidence根README、`2026-11-11-iflytek-project-walkthrough.md`。

**Interfaces:**
- `verify(root: Path, profile: str) -> dict`：profile为full/compact，按下方明确矩阵验证，输出passed/failed/not_run/manual_pending；不得把not_run计成通过。
- `report(root: Path, profile: str) -> Path`：输出总报告，链接每批协议、原始输出、单独指标和限制。

- [x] **6.1 写并跑报告红灯。** 缺少VAD人工边界时显示manual_pending；只完成两模型不得显示full完成；MLX与PyTorch对比始终列后端；ASR的RTF与LLM网络耗时不能混为产品端到端速度；dispatch只能标发送事件，不能标已确认落字。
- [x] **6.2 生成和复核完整报告。** `python -m tools.interview_bench report --root build/interview-bench --profile full`；`python -m tools.interview_bench verify --root build/interview-bench --profile full`。核对数据/模型/源码/二进制/评分器hash、全部IDs、单位分母、API原文回退与凭据不落盘。
- [x] **6.3 完成必要测试。** `PYTHONDONTWRITEBYTECODE=1 build/interview-bench/.venv/bin/python -m unittest discover -s tools/interview_bench/tests -p 'test_*.py'`；原有12项研究行为测试在旧隔离环境重跑。不改客户端代码时不将全应用自测当成本轮算法效果证据；实际触及产品代码则补对应原有回归。
- [x] **6.4 整理面试讲述。** 写30秒/3分钟两版介绍；每模块列“问题→实现→实际数字→失败案例→取舍”。准备Qwen/Whisper差异、量化、VAD与ASR边界、MER/WER与微平均、流式/分段、上下文误改、PyTorch张量与推理模式、原型与产品边界等至少12条追问。
- [ ] **6.5 演示并冻结。** 保留CLI运行/报告/分段演示；现有客户端做至少3次短句/混说/术语真实麦克风演示，并人工确认TextEdit实际文字。未完成时标产品演示pending，不虚构真机通过。客户端演示不自动注入私密文档，不改变用户长期模型设置。面试前一天停止新增方法，最后一天用于用户阅读代码与演练。
- [x] **6.6 独立检查所有改动、归档并按用户指令提交。** 本任务不包含自动push或发布；以测试/核验结果和实际完成矩阵说明状态，不以预期改进数字宣布成功。

## 实测矩阵与完成标准

| 模块 | full | compact（截止时间不足时明确切换） |
| --- | --- | --- |
| 模型 | 三模型×ASCEND1130；同口径clean/mixed | Qwen1.7＋Whisper base，各1130；0.6 not_run |
| VAD | dev3×5策略；eval6×3策略；confirmed边界与演示 | eval同一6会话×整段/固定5s/VAD600；人工边界仍需实际确认 |
| 纠错 | 新英语三LLM条件×200＋mixed两条件×191，原始输出固定 | 既有普通/正确表结果＋新增错配200；注明跨批次/服务版本限制，mixed扩展not_run |
| 工具与材料 | 六任务证据齐全，总CLI/报告/核验/讲述 | 相同公共协议与报告，缩减项逐个列出，不包装为full |

人工起止未确认不应阻止其他实验，但不能出该部分端点结论；产品麦克风演示未完成不能声称已测客户端端到端效果。报告可用明确的partial状态交付，不能为赶时间补写“通过”。

## 执行预算、收缩与停止条件

| 工作日 | 主要任务 | 当日能审查的产出 |
| --- | --- | --- |
| Day 1 | Task1/2/3 | 固定清单、加载证据、首版多模型真结果 |
| Day 2 | Task4 | 分段链路、边界标注、回放事件与延迟表 |
| Day 3 | Task5＋补漏 | 纠错两场景对照、误改案例、汇总草稿 |
| Day 4 | Task6 | 最终报告、演示、本人讲解与追问练习 |

- 日期未定，以上为4个可用工作日预算，不能宣称保证4日完成。Day1统一环境/构建最多2小时；单个新模型下载/加载排障最多90分钟。仍失败则保留错误证据并进入明确的compact/partial，不通过更换语料掩盖失败。
- 10条admission测实际吞吐并估算完整时长；单模型全量预算3小时。超出时先保留已有两个模型的相同全量结果；若Whisper本身超出，仍可跑固定191 mixed形成局部跨架构比较，但须标明full/compact均未完全满足，不把不同样本数混比。
- Day2结束仍未有因果回放时，先完成600ms VAD与两种基线，不追加阈值扫描。人工标注集中一次完成，未完成部分始终pending。
- Day3不再追加数据集、模型、提示词或训练任务。超过API预算就停止发新请求，保留partial，不静默删条件。
- Whisper small、原生WhisperKit实机性能、噪声鲁棒性、ASR n-best、模型训练均为明确可选项；基础交付完成前不启动。

## 本计划的交接状态

- [x] 读取岗位要求、既有实测和关键实现。
- [x] 核验官方模型/解码/VAD资料、固定来源与可用后端。
- [x] 写出四模块整体范围、接口、测试、实测矩阵、时间收缩与事实边界。
- [ ] 按本计划实施新增工具、下载模型、执行新批次和人工演示。

实施状态（2026-11-11）：自动矩阵已完成，整体为 partial。三模型各1130、dev3×5/eval6×3回放、982次纠错均有真实归档；36条人工试听、60–90秒录制、三次麦克风实际落字尚待完成。4.4/4.6/6.5保留未勾选表示其中人工部分待验证；6.6已完成独立审查及一次回归修复；HTML暂停/拖动同步延后项已在后续修复，新增只渲染入口及33个独立展示页，49/49测试通过。详见 [证据总览](../../evidence/iflytek-interview/2026-11-11-four-modules/README.md)。
