# FlowType interview bench

面试分支的离线评测与原型工具，不修改产品设置、默认模型或客户端。主计划见 [四模块计划](../../docs/superpowers/plans/2026-11-11-iflytek-interview-four-modules.md)。

## 复现顺序

从仓库根目录执行。需要现有 `swift build` 依赖产物、macOS arm64/Metal、`uv`、`curl`、`ffmpeg`；没有模型时推理会立即失败，不会暗中联网下载或换模型。

```sh
uv venv build/interview-bench/.venv --python 3.11
uv pip sync tools/interview_bench/requirements.lock.txt --python build/interview-bench/.venv/bin/python
```

后文 `python` 指 `build/interview-bench/.venv/bin/python`，建议加 `PYTHONDONTWRITEBYTECODE=1`。不得覆盖旧的 `build/ascend-validation-audit/.venv`。

```sh
python -m tools.interview_bench prepare --root build/interview-bench --source-root build/asr-baseline-20261111
python -m tools.interview_bench assets --root build/interview-bench --download
python -c 'from pathlib import Path; from tools.interview_bench.build_native import build_native; print(build_native(Path("build/interview-bench/bin")))'
python -m tools.interview_bench models --root build/interview-bench --admission-only
python -m tools.interview_bench models --root build/interview-bench --models qwen-1.7b,qwen-0.6b,whisper-base
python -m tools.interview_bench replay --root build/interview-bench --prepare-annotations
python -m tools.interview_bench replay --root build/interview-bench --split dev
python -m tools.interview_bench replay --root build/interview-bench --split eval
python -m tools.interview_bench correction --root build/interview-bench --allow-cloud
python -m tools.interview_bench report --root build/interview-bench --profile full
python -m tools.interview_bench verify --root build/interview-bench --profile full
python -m unittest discover -s tools/interview_bench/tests -p 'test_*.py'
```

`prepare` 只做一次，已有冻结目录会拒绝覆盖。其他运行建立带UTC时间的新目录；不把不同批次拼成一个完整结果。比较模型按顺序运行，VAD回放不得同时占用另一个ASR模型。构建二进制旁需保留 `mlx.metallib`；链接命令、二进制和资源身份见 `bin/`。

## 数据与模型身份

ASCEND固定revision：`737e9800ae31be9932ba8464c80366559bd28424`。本地导出的1130条音频，clean1067、UNK63单列、mixed191；不等于官方整个validation。LibriSpeech为200条自定义pilot、40人每人5句，不是完整test-clean。输入只有id/path，参考、候选表和逐音频SHA单列。

Qwen0.6固定revision：`bc441bd1e4295c1f42d9879f056049a925b6e013`；已有1.7只读并逐文件hash，不猜上游revision。Whisper使用多语言base、CPU FP32四线程；Qwen使用Swift/MLX的4bit模型。比较对象是部署组合，不据此证明架构优劣。所有Qwen均448最大token、temperature0、repeat1.1/no-repeat-ngram3，无language/context；Whisper不启用多温度fallback、无初始提示、不继承前段文本。每模型3条预热，再重跑全部1130条。RSS单位bytes，不是完整GPU显存。

Silero v5.1固定commit `84768cefdf5a3852400e9d8237f7315d14b64a08`，JIT Git blob `63cb73be394528ef8d4936fdaa4884890754d065`。512 samples、16kHz、CPU一线程；各会话重置状态。onset0.5/offset0.35，min speech96ms，pre160/post100ms，max10s，等待队列4。第5个等待段使会话失败；不静默丢段。未确认短语音仍送ASR。

## 人工标注与演示

打开 `build/interview-bench/replay-prepared/annotate.html`，实际试听36条，填写全部语音区间（秒）、标注者并勾选确认，导出JSON。用以下命令导入，再建立新的回放批次；旧批次不改写。

```sh
python -m tools.interview_bench replay --root build/interview-bench --import-annotations /absolute/path/annotations.json
```

自动分段、静音拼接来源边界不是人工真值。未完成试听时仍可算MER与结果返回时间，endpoint/final-from-speech为null/manual_pending。每四条真人片段拼接，头尾1s，内间隔400/600/1200ms；这是构造回放。HTML按真实返回事件显示逐段文字，非token streaming或客户端落字。

开发集3会话×whole/fixed5/VAD300/600/900；评测集6会话×whole/fixed5/VAD600，参数预先固定。展示每会话延迟，不用六条估计稳定p95 SLA。另需真人完成60–90秒录制和客户端三次短句/混说/术语麦克风→TextEdit演示。未观察到实际落字不得把dispatch写成成功。

## 云端纠错与预算

只读取当前启用的SiliconFlow/DeepSeek-V3配置，凭据只在内存/curl stdin，不能传进CLI参数或落盘。英语plain/contextual/mismatched各200；mismatch为按ID排序的完整候选表循环置换，允许偶然重合，不看答案删词。mixed plain/static_tech各191，技术词表取产品既有规范值、去重后29词，不从逐句参考构造。

提示/参数复用旧pilot，不逐句特判。最多1000请求；已报告token达到100万停止新请求，最多四个在途请求完成。缺失usage意味着这不是账单硬上限。失败、截断、空返回逐字保留原文计分，无重试；原ASR空文本跳过调用。982主条件之外本次未额外增加smoke请求；最先的固定矩阵请求同时验证接入，不调提示。

英语官方B/U评分器保留原hash，3/4列分别只用于评分/提示。普通词损失、正确句误改和fallback必须和收益一起展示。ASCEND mixed没有足够技术词覆盖，不能称为技术词专项成绩。LLM网络耗时不能称作产品端到端时延或ASR RTF。

## 许可

ASCEND（Lovenia et al., LREC 2022，https://huggingface.co/datasets/CAiRE/ASCEND）CC-BY-SA-4.0；LibriSpeech（Panayotov et al., ICASSP 2015，https://www.openslr.org/12/）CC-BY-4.0；contextual biasing资源（Le et al., INTERSPEECH 2021，facebookresearch/fbai-speech/is21_deep_bias）评分软件MIT。公开转写及派生预测随证据记录来源；音频/权重留在ignored build，不嵌入客户端发布包。Qwen转换模型卡Apache-2.0、Whisper代码/权重MIT、Silero MIT；`models/`保留许可文本与来源/hash。
