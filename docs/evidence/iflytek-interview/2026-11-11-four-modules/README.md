# 四模块实验记录（2026-11-11）

分支 `feat/iflytek-interview`；[开发计划](../../../superpowers/plans/2026-11-11-iflytek-interview-four-modules.md)、[复现命令](../../../../tools/interview_bench/README.md)、[中文讲述与18条追问](../../../interviews/2026-11-11-iflytek-project-walkthrough.md)。

**自动矩阵完成，整体验收 partial。** [核验结果](reports/verification.json)：8项自动检查passed、3项manual_pending，无failed/not_run；缺少36条实际试听边界、60–90秒录制演示、三次麦克风→TextEdit实际落字确认。自动分段/dispatch不能代替这些人工事实。

## 结果与证据

| 模块 | 实际完成 | 主要结果 |
|---|---|---|
| [三模型同集](models/model-comparison.md) | 各1130条、clean1067/mixed191，0失败 | Qwen1.7/0.6/Whisper base clean MER 11.87%/12.14%/43.60%；mixed13.98%/14.78%/51.22% |
| [开发回放](replay/dev/report.md) | 3会话×whole/fixed5/VAD300/600/900，0失败 | 编辑数5/8/6/6/4，共112参考单元；所有条件并列展示，未根据成绩改eval参数 |
| [评测回放](replay/eval/report.md) | 6会话×whole/fixed5/VAD600，0失败 | MER22/235=9.36%、37/235=15.74%、30/235=12.77%；分段提前返回，准确率低于整段 |
| [上下文纠错](correction/report.md) | 英语3×200 + mixed2×191，982请求 | 英语raw/plain/context/mismatch WER2.99/3.24/2.36/3.21%；mixed13.98/17.92/14.68%，没有自动启用纠错的依据 |

新1.7文本与旧基线[0/1130条差异](models/historical-difference.json)。[十个ASR选例](models/model-comparison.examples.json)按各模型ID取前三个非零错误、再取首个跨模型差异，不代表随机分布。纠错报告同时列原本正确句的误改和普通词损失，原始输出与逐句诊断全部保留。

## 计量与事实边界

- ASCEND是自定义可评分参考子集，clean指不含UNK参考，不代表“无噪声音频”；LibriSpeech为200条pilot，不是完整test-clean。均已查看过既有基线，不是独立盲测。
- Qwen是Swift/MLX/Metal混合4bit；Whisper base是PyTorch CPU FP32四线程。[环境版本](environment.json)在批次后采集，隔离环境期间未变。比较部署组合，不把差异归因于纯架构或参数量。
- 后台桌面负载未控制，Qwen1.7阶段与云端纠错请求重叠，0.6阶段有短暂VAD预检；没有并行运行多个待比较ASR。速度为本次记录，不是受控性能或产品SLA。
- 每模型加载后3条预热，再重跑全部1130。模型加载计时不含进程启动/依赖导入；ASR RTF、LLM网络耗时和确认落字时延分别计量。RSS为macOS进程bytes，不代表完整GPU显存。
- 回放由36条真人片段构成3dev/6eval会话；头尾1s，内部400/600/1200ms静音。是真实时钟构造回放，不是自然连续语音或麦克风录屏；逐段返回不等于token streaming。评测只6会话，逐个展示，不声称稳定p95。
- 端点采用真实单调时钟事件时间减人工语音结束时间，另保留采样差。当前无人工确认，因此endpoint/final-from-speech全部null/manual_pending。录制与客户端演示尚未完成。
- 英语正确表覆盖501/501个稀有目标条目，错配表偶然覆盖3/501；技术表29词在mixed191参考中零命中。因此mixed不能当技术词专项；plain/词表提示还相差固定CONTEXT后缀，零命中差异不能解释成热词收益。
- 本轮未做模型训练、声学结构消融、提示词刷分或产品默认链路集成。结果/原型与产品能力分别陈述。

## 目录与复现

`prepared/`保留冻结id/path、参考、基线、音频manifest、候选表/词表与划分。`models/`、`replay/`、`correction/`各保留协议、逐条输出、汇总与冻结源码；推理源码在source-snapshot，推理后的评分/排版源码在analysis-source（如有）。原始输出不覆写。`assets/`与`native-build/`保留权重身份/许可、链接命令及二进制/Metal资源hash，不含模型或可执行文件。

`replay/annotation-package/annotate.html`需本地音频；`replay/*/*/*.html`按实际事件回放文字，音频URI指向本次ignored build。其他机器请按工具README重新准备/下载，或调整本地音频位置；GitHub直接查看HTML源码不等于运行演示。原始音频、权重、二进制不进入本目录。`reports/report.md`来自本机CLI，含运行目录URI；此README提供仓库内相对链接。

验证命令：`python -m tools.interview_bench report/verify --root build/interview-bench --profile full`（report和verify分别调用）；Python指新隔离环境。已有冻结prepare目录禁止覆盖，新的推理/标注批次新建身份。人工确认按README导入边界或填写人工演示记录，不补写自动通过。

## 来源与许可

ASCEND：Lovenia et al., LREC 2022，[CAiRE/ASCEND](https://huggingface.co/datasets/CAiRE/ASCEND)，CC-BY-SA-4.0。参考摘录与派生转写按该许可保留来源；revision `737e9800ae31be9932ba8464c80366559bd28424`。本地1130条、clean1067/mixed191不是官方完整validation。

LibriSpeech：Panayotov et al., ICASSP 2015，[OpenSLR SLR12](https://www.openslr.org/12/)，CC-BY-4.0。本目录为200条自定义pilot的参考摘录/派生输出；40人每人5句。contextual biasing资源：Le et al., INTERSPEECH 2021，[fbai-speech/is21_deep_bias](https://github.com/facebookresearch/fbai-speech/tree/main/is21_deep_bias)，评分软件MIT；官方脚本SHA256 `669de80a61cf84ac34aacc18cf4813ca0cf1cae32d6435b3763dfa586ea89649`。

Qwen转换模型卡Apache-2.0，Whisper代码/权重MIT，Silero MIT；资产身份与许可文本保留在本地models中，权重和原始音频不进入客户端发行包。本目录整体包含不同许可材料，不能统一套用为仓库代码许可。LLM输出来自SiliconFlow/DeepSeek-V3服务别名；权重版本不可固定，旧pilot单独保留，不跨批次冒充同批对照。

## 最终审查

[独立审查与处理](audit/final-review.md)、[执行台账与取舍](audit/progress.md)。修复了回放磁盘写入失败误报/退出阻塞、会话ID核验及派生源码哈希；新测试41/41、原有研究测试12/12通过。HTML暂停/拖动/变速与文字事件不同步暂缓，不影响归档事件和评分。文件全集见 `SHA256SUMS.json`（不包含自身）。分支保留供后续人工验收，本轮不自动推送或合并。
