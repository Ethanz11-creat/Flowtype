# 科大讯飞面试实验总览

当前矩阵：**partial**；profile=full。

| 项目 | 状态 | 证据 |
|---|---|---|
| prepared | passed |  |
| assets | passed |  |
| model-qwen-1.7b | passed | [qwen-1.7b](file:///Users/yiheng/pycode/flowtype-local/build/interview-bench/model-runs/20261111T080223324612Z/qwen-1.7b) |
| model-qwen-0.6b | passed | [qwen-0.6b](file:///Users/yiheng/pycode/flowtype-local/build/interview-bench/model-runs/20261111T080223324612Z/qwen-0.6b) |
| model-whisper-base | passed | [whisper-base](file:///Users/yiheng/pycode/flowtype-local/build/interview-bench/model-runs/20261111T080223324612Z/whisper-base) |
| replay-dev | passed | [20261111T084344485283Z](file:///Users/yiheng/pycode/flowtype-local/build/interview-bench/replay-runs/20261111T084344485283Z) |
| replay-eval | passed | [20261111T084753091986Z](file:///Users/yiheng/pycode/flowtype-local/build/interview-bench/replay-runs/20261111T084753091986Z) |
| human_boundaries | manual_pending | 36 real listening confirmations required |
| correction | passed | [20261111T080603494245Z](file:///Users/yiheng/pycode/flowtype-local/build/interview-bench/correction-runs/20261111T080603494245Z) |
| microphone_demo | manual_pending | 3 real microphone/TextEdit insertions require a human observation record |
| recorded_replay_demo | manual_pending | 60–90s replay recording requires a real media file and human observation |

## 阅读路径

- 模型：[部署对比](model-comparison.md)，同时查看每模型 protocol、predictions、timing、resource、summary。
- 回放：每批 report.md、策略目录 JSON/HTML。先看每会话的时间和排队，再看分段 MER。
- 纠错：每批 report.md、summary.json、paired-diagnostics.jsonl。比较 B/U、正确句误改、fallback；网络时间不是 ASR RTF。
- 人工试听：[标注页面](../replay-prepared/annotate.html)。未确认的端点和语音结束延迟为 null。

## 事实边界

本轮为面试准备的真实推理与对照实验，不是盲测、科研创新或 SOTA 证明。ASCEND 是自定义 clean-reference 子集，LibriSpeech 是 200 条自定义 pilot；mixed 191 不构成技术术语专项。后端不同只比较部署组合。构造回放不等于自然连续语音；分段结果逐步出现不等于 token streaming。

dispatch 仅证明尝试发送，不能证明目标应用已落字。真实麦克风与 TextEdit 的三次确认、36条试听边界、60–90秒录制演示，均需真实操作与人工记录；缺失时保持 manual_pending。

## 复现

依次运行 prepare → assets --download → models --admission-only → models → replay --prepare-annotations → replay --split dev/eval → correction --allow-cloud → report/verify。已存在的冻结输入/批次不可覆盖。模型比较必须串行运行，安装及参数见 tools/interview_bench/README.md。
