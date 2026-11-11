# 四模块实验记录（2026-11-11）

执行分支 `feat/iflytek-interview`；计划 [四模块开发计划](../../../superpowers/plans/2026-11-11-iflytek-interview-four-modules.md)，工具 [README](../../../../tools/interview_bench/README.md)。

## 当前归档

- [上下文纠错报告](correction/report.md)：英语三条件各200 + mixed两条件各191，共982请求；374876 reported tokens；无usage缺失、无HTTP/解析fallback。原始输出、候选表、冻结提示、逐句诊断均保留。
- [三模型同集对比](models/model-comparison.md)：每模型1130条、clean1067/mixed191；均零失败。原始预测、分组评分、加载/预热/推理、RSS与冻结源码齐全。
- 因果回放与总核验仍在运行，完成后补同一批归档。此状态不代表full矩阵完成。

## 来源与许可

ASCEND：Lovenia et al., LREC 2022，[CAiRE/ASCEND](https://huggingface.co/datasets/CAiRE/ASCEND)，CC-BY-SA-4.0。参考摘录与派生转写按该许可保留来源；revision `737e9800ae31be9932ba8464c80366559bd28424`。本地1130条、clean1067/mixed191不是官方完整validation。

LibriSpeech：Panayotov et al., ICASSP 2015，[OpenSLR SLR12](https://www.openslr.org/12/)，CC-BY-4.0。本目录为200条自定义pilot的参考摘录/派生输出；40人每人5句。contextual biasing资源：Le et al., INTERSPEECH 2021，[fbai-speech/is21_deep_bias](https://github.com/facebookresearch/fbai-speech/tree/main/is21_deep_bias)，评分软件MIT；官方脚本SHA256 `669de80a61cf84ac34aacc18cf4813ca0cf1cae32d6435b3763dfa586ea89649`。

Qwen转换模型卡Apache-2.0，Whisper代码/权重MIT，Silero MIT；资产身份与许可文本保留在本地models中，权重和原始音频不进入客户端发行包。本目录整体包含不同许可材料，不能统一套用为仓库代码许可。LLM输出来自SiliconFlow/DeepSeek-V3服务别名；权重版本不可固定，旧pilot单独保留，不跨批次冒充同批对照。
