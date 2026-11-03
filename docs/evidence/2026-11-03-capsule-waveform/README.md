# 原生胶囊与音柱验证记录

实现与逐项/整体独立审查完成。完整 code/artifact 门禁待运行；本文件会补录实际报告和被测源码身份。

实现提交：`139e123`（真实 PCM 音量、十根细音柱、按时间扩散、静音回落、取消隔离、减少动态效果）；`db58ea6`（216×54 蓝紫雾面胶囊、状态呈现、慢处理与提示计时、资源一致的恢复文案）。

[规格](../../superpowers/specs/2026-11-03-capsule-waveform.md) · [实施计划](../../superpowers/plans/2026-11-03-capsule-waveform.md) · [整体审查](reviews/final-review.md) · [18 状态原生预览](native-previews/states-at-1x.png)

聚焦验证：呈现111/0、音柱45/0、原生客户端938/0、M4恢复19788/0、原生渲染40/0。实际命令、RED/GREEN与历史失败说明在 [音柱报告](reviews/task-1-report.md) 和 [胶囊报告](reviews/task-2-report.md)，选定原始日志在 focused/。M4原有恢复操作矩阵保留，旧的无条件重试/复制文案断言按可用资源更新。

原生预览使用真实 CapsuleView/AudioVisualizer 和合成音量，在隔离 NSHostingView 中输出1× PNG。manifest列明18个状态：普通216×54、恢复380×156；控制器检查了录音、静音、倒计时、慢处理、复制、长准备提示与恢复操作。它证明布局和文案，不证明真实桌面的材质、跨应用焦点/拖动或实际麦克风手感。未触发模型下载、云端请求、麦克风授权更改或真实剪贴板写入。

真机音量/噪声底校准、系统减少动态效果、桌面材质/焦点/拖动，以及真实云端弱网/断网、跨应用落字、剪贴板保护、取消与拔麦恢复继续在剩余主线中；沿用 [M5真实操作验收](../../superpowers/validation/2026-11-03-native-client-acceptance.md) 的未完成状态，不以截图或自动测试代替。
