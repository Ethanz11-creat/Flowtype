# 上下文纠错评测集补充：优先采用公开基准

日期：2026-11-11。延续[中英混说数据集调研](2026-11-11-code-switching-asr-datasets.md)与 [ASCEND 验证集检查](../evidence/2026-11-11-ascend-validation-audit/README.md)。

用户希望继续查找现成术语评测集，并接受用主流语音评测集验证。补查结论：**公开的上下文/长尾词评测资源确实存在，不必将自采作为开始实验的前置条件。**此前“需要专项数据”的判断应理解为需要匹配研究问题的数据，不意味着必须自己录制。

后续已完成 ASCEND validation 原始推理与 LibriSpeech 固定 200 条 pilot，见[实测基线记录](../evidence/2026-11-11-asr-baselines/README.md)；普通纠错与候选词表纠错的后续对照见[首轮纠错实测](../evidence/2026-11-11-contextual-asr-correction/README.md)。本文的“未推理/尚未形成方案”描述资料补查阶段，不是后续运行状态。

## 推荐实验组织

先复用已下载的 ASCEND validation 跑原始 ASR 基线，再优先引入 **LibriSpeech contextual biasing 基准**来验证长尾词纠错与普通词误改；**ContextASR-Bench**可作多领域实体的补充实验。先把这条链路跑通，无需同时下载所有候选全集。

建议研究问题改为可测量的形式：**外部上下文能否降低长尾词/实体识别错误，同时控制普通词误改？**它可以使用既有公开标注检验；中英混合技术口述作为应用目标，不能由纯英语或合成数据的收益直接推定。

以上是本轮建议，尚未形成实现计划或新的推理结果。

## 1. LibriSpeech contextual biasing：推荐的公开专项基准

来源：[Facebook Research 官方目录与说明](https://github.com/facebookresearch/fbai-speech/tree/main/is21_deep_bias)，对应 [INTERSPEECH 2021 论文](https://arxiv.org/abs/2104.02194)。

- 基于真实英语有声书语音，复用 [LibriSpeech](https://www.openslr.org/12/) 的 test-clean / test-other。
- 官方提供逐句参考、参考中的稀有词、包含目标稀有词的 biasing 词表，以及评分脚本。
- 已核到 100、500、1,000、2,000 词表规模的参考文件，可测试词表变大、干扰增加时的效果。
- 官方指标包括 **WER、B-WER、U-WER**：整体错误、目标稀有词错误、其他词错误。后续实际核对 `score.py` 发现，它按 TSV 第三列的参考稀有词划分 B/U，而非第四列的完整提示/干扰词表；实现口径应随实验一并记录。
- 稀有词的定义基于训练语音中的词频，文档说明前 5,000 个词作为 common words，并提供 supporting word lists。

**证据边界：**该词表按构造保证含有参考中的目标稀有词，属于明确的受控/理想先验条件，不能声称它代表线上检索命中率；不能拿它模拟“完全不知道目标词”的场景。方法提示词、阈值和超参数使用独立开发数据确定，冻结后再测官方 test。不得按 test 的错误案例挑选最有利词表或修改提示词。

它检验英语长尾词处理，不直接覆盖现代软件术语或中英切换。音频源的 LibriSpeech 许可为 CC-BY-4.0；fbai-speech 仓库的软件许可为 MIT，两者分别记录。

本轮读取了官方说明及参考目录，尚未下载对应音频或运行评分脚本。

## 2. ContextASR-Bench：与上下文实体问题直接相关

来源：[论文](https://arxiv.org/abs/2507.05727)、[官方代码](https://github.com/MrSupW/ContextASR-Bench)、[官方数据卡](https://huggingface.co/datasets/MrSupW/ContextASR-Bench)。

- 论文描述 4 万余条、10 多个领域、30 多万个实体；包括 ContextASR-Speech 与 ContextASR-Dialogue，各有 Mandarin 和 English 配置。
- 每条提供音频、文本、粗粒度上下文与细粒度实体信息；具备无上下文、领域/主题提示、精确实体提示三种条件。
- 官方代码提供 WER、NE-WER、NE-FNR 的评测流程，可参考实体局部错误与整实体漏识别的区分。
- 数据卡当前标 MIT；元数据 revision 为 `7906fd98d1d093bf244df80e726e07fc8afed6a6`，`gated=false`、`private=false`。不要把论文页面的 CC0 声明误当作数据卡许可。

**两个必须单列的限制：**

1. 它使用 LLM 生成实体密集文本，再经零样本 TTS 合成，且经过 ASR/PER 质量筛选；不是自然人真实口述分布，可能存在合成语音和筛选模型偏差。
2. 细粒度条件直接提供音频文本包含的实体，属于知道目标实体列表的理想条件。结果只能说明已提供正确词表时的利用能力，不能替代真实上下文获取、检索或抗干扰效果。

Mandarin / English 两种配置不等于整套是中英混说语料。软件/LLM 技术子域与具体目标词覆盖仍需检查原始条目，不根据摘要中的 engineering 示例推定 PyTorch、LoRA 等词必然存在。

建议作为**补充可控实验**，同时保留真实语音的主结果；不以该合成基准单独声称产品准确率提升。若适配为 ASR 后置文本纠错，要明确改变了论文中端到端/音频模型的实验设置。

## 3. Earnings-21 / ConEC：真实实体与真实外部文档

来源：[Earnings-21 官方说明](https://github.com/revdotcom/speech-datasets/tree/main/earnings21)、[ConEC 论文](https://aclanthology.org/2024.lrec-main.328/)、[ConEC 仓库](https://github.com/huangruizhe/ConEC)。

- Earnings-21 有 44 份英语财报电话录音、约 39 小时，包含实体标注；还提供约 10 小时的 Eval-10 子集。它是实体密集的真实语音，可评估 PERSON、ORG、PRODUCT、ABBREVIATION 等类别。
- ConEC 基于 Earnings-21/22，补充演示幻灯片、财报发布材料、参会人姓名与机构信息。它检验从真实外部文档获取的上下文，其覆盖不完全且含干扰，较逐句正确实体表更贴近产品条件。
- 财经英语与中英技术口述不同，但适合验证“外部材料辅助专有词纠错”能否泛化。

Earnings-21 的目录许可文件明确将 transcripts 及相关文本标为 CC-BY-SA-4.0，不把它自行扩展为所有原始音频/外部材料的统一授权。ConEC 本轮读到了论文，仓库 README 获取超时，实际数据入口、材料许可及版本尚未逐项核验；暂不作为立即运行的唯一依赖。

## 4. SlideSpeech：有技术讲座与幻灯片，需注意划分

来源：[论文](https://arxiv.org/abs/2309.05396)、[项目页](https://slidespeech.github.io/)。

- 真实讲座视频，提供音频片段、OCR 与关键词信息，直接涉及用幻灯片改善专有词识别。
- 全集 1,705 个视频；论文训练集 L 中 Computer Science 为 435 个视频 / 161.0 小时。这是**训练数据分布**，不是官方 test 的技术词规模。
- dev 为 21 个视频 / 5.07 小时，test 为 25 个视频 / 8.75 小时，均人工标注；训练大部分为自动标注。论文刻意区分训练/评测类别，不能把训练中的计算机主题当作官方技术领域测试结果。
- 若从训练计算机主题额外构造技术专项集，必须公开自定义划分、人工核验标签，并按完整源视频留出；不得宣称为原官方 benchmark。
- 项目页称 metadata 为 CC-BY-SA-4.0，论文同时注明学术研究用途。原视频、音频及平台获取条件须分别核实，不将 metadata 许可视为所有媒体的授权。

它值得后续调研真实技术上下文，但当前不需要为它额外启动大规模媒体采集。

## 5. 新近 KeyASRBench：方法参考，尚非可直接运行的公开音频集

[2026-11-07 预印本](https://arxiv.org/abs/2611.10852)关注名称、产品、技术术语与版本等完整短语保留，提出按出现次数统计的 KER，场景与需求贴近。

但全文明确：完整音频、参考、关键词与详细 provenance 留在受控环境，计划公开的是协议、评分器、聚合统计及另行获许可的例子。它的 10 小时 challenge 还按若干模型错误作筛选，并另设约 30 分钟 model-blind control。因此本轮只将其视作指标与研究问题的线索，**不推荐作为可直接下载并独立复现的评测数据依赖**。

## 主流 ASR 数据集能回答什么

| 资源 | 可以支持的结论 | 单独不能支持的结论 |
| --- | --- | --- |
| ASCEND | 真实混说准确性、纠错前后是否整体退化 | 对软件/LLM 技术术语的专项收益 |
| [AISHELL-1](https://www.openslr.org/33/) | 普通话基线与普通词误改控制 | 现代技术词或中英混说收益 |
| LibriSpeech | 英语识别基线；带官方 biasing 扩展可测长尾词/干扰词表 | 中英技术口述的真实产品效果 |
| ContextASR-Bench | 多领域实体与已知上下文条件下的利用能力 | 自然人录音分布下的全部收益、真实词表召回率 |
| ConEC | 财经英语中真实外部材料辅助效果 | 直接等价于编程领域或中英混说 |

通用 CER/MER/WER 下降是有价值的结果，仍需搭配词表内/外错误和误改统计，才能检验上下文纠错机制，而非只得到一个总体均值。若后续公开数据已覆盖研究问题，自采只用于仍存在的产品场景缺口。

## 本轮执行状态

只核对论文、官方说明、部分目录/元数据，未为这些新增候选下载整套音频、推理或填写性能结果。Hugging Face 卡片与元数据经镜像读取，其余资料来自 arXiv、ACL、OpenSLR 或官方 GitHub/项目页。AutoGLM 搜索 token 服务返回 HTTP 502，后续采用公开文献检索及原站内容核验。

资料缓存：`build/research/2026-11-11-contextual-asr-benchmarks/`。当前推荐取代“先自行录一套技术集才能继续”的理解，不改变已有 ASCEND 检查事实。
