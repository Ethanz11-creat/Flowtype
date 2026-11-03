# 原生胶囊与音柱验证记录

实现、逐项独立审查、整体审查及本地 code/artifact 门禁均已通过。普通胶囊为 **216×54** 蓝紫雾面，音柱为十根2pt细柱、真实音量驱动、中心向外扩散、停顿归静；状态提示已接入实际会话管线。

[规格](../../superpowers/specs/2026-11-03-capsule-waveform.md) · [实施计划](../../superpowers/plans/2026-11-03-capsule-waveform.md) · [整体审查](reviews/final-review.md) · [18 状态原生预览](native-previews/states-at-1x.png)

## 最终候选与门禁

被测源码 **00bdd2f581a4f83a5f0cd290c542c5991380489c**，Sources tree **50fe779eb598377251bda42ee463e15d0930fb53**；两条门禁的 source-start/end 均 clean 且一致。随后只归档文档与证据，不把候选重新标记成文档提交的 SHA。

| 验证 | 结果 | 原始报告 |
| --- | --- | --- |
| Code | **Pass：25,555 passed / 0 failed，全部7阶段通过** | [code报告](runs/FF2E0D81-59A2-41BE-BAEA-DD2AD1B66522/verify-report.json) |
| Artifact | **Pass：全部22阶段通过，含签名、资源/Metal检查及10次smoke** | [artifact报告](runs/94CE669B-4664-4468-9F46-D2AE228249B5/verify-report.json) |
| 聚焦检查 | 呈现114/0、音柱45/0、原生客户端938/0、M4恢复19788/0 | [最终小修报告](reviews/final-golden-fix-report.md)、[胶囊报告](reviews/task-2-report.md)与 focused/ |
| 原生渲染 | 40/0，18个实际1×状态PNG | [尺寸清单](native-previews/manifest.json) |
| 真机与远端CI | **Pending** | 未将自动测试或截图视为真实操作验收 |

候选 **1.0.0 / build384 / arm64**，builtAt `2026-11-03T15:17:38Z`。应用位置 `/Users/yiheng/pycode/flowtype-local/build/FlowType.app`；[产物清单](FlowType.manifest.json)。binary SHA256：`1de063674da591853825fde8b7db0f009c6a55b2e86c1146acc760ff798e085c`；BuildInfo SHA256：`aec9ad28c69580ccfd6bd4c1b5318565bd07d4b9e533d4d8d2a5cddb82147dcc`。控制器独立核对实际文件hash与manifest一致。

实际最终命令：

```sh
scripts/verify.sh --lane code
MLX_METALLIB_PATH="$PWD/build/FlowType.app/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib" scripts/verify.sh --lane artifact
```

使用原有着色器（SHA256 `f36b01c44dd5f2d9020deb1ac6ad53dc085de81af19396694c5963ef3a12137f`），未下载模型或着色器，未安装、推送、合并或发布。

## 实现与审查

`139e123` 实现真实 PCM RMS、单一有界可视化流、按时间计算的扩散、静音/过期回落、取消隔离与减少动态效果；`db58ea6` 实现紧凑胶囊、类型化状态提示、慢处理/提示计时与资源一致的恢复文案；`00bdd2f` 修正旧测试文案预期并将现有三条稳定呈现断言加入聚焦入口。

两项任务分别经过独立规格/质量审查，最后由独立整体审查复核组合行为，均无待修问题。最终测试预期小修又经过[独立复核](reviews/final-golden-rereview.md)。慢处理约6秒只更新呈现，不释放会话资源或延长20秒预算；剪贴板提示5秒，静音等温和提示2.2秒；实际交付结果优先于润色降级。原有M4恢复操作矩阵和会话归属检查保留。

首轮完整 code [历史报告](runs/6B551B82-A340-4ACC-9EBB-43DD5488503C/verify-report.json)在 `4d8da71` 为25554/1：唯一失败是旧断言要求“处理中…”而规格已改为“正在处理”。完整修复证据保留，未将历史失败报告改写为通过。后续两行测试修改后重新运行完整门禁，得到上述最终结果。此前M4旧文案金标准按真实资源更新，具体RED/GREEN和历史构建/渲染尝试在任务报告中保留。

## 原生预览与边界

预览使用真实 CapsuleView/AudioVisualizer 和合成音量，在隔离 NSHostingView 中输出1× PNG。manifest列明普通216×54、恢复380×156；控制器检查了录音、静音、倒计时、慢处理、复制、长准备提示与恢复操作，未见明显裁字。预览来自最终界面实现，后续只修改两行测试入口/预期；没有用网页原型替代原生渲染。

离屏渲染不证明真实桌面材质、跨应用焦点/拖动或麦克风手感，透明角落中的光晕也不代表实际FloatingPanel遮罩表现。真机音量/噪声底校准、系统减少动态效果、桌面材质/焦点/拖动，以及真实云端弱网/断网、跨应用落字、剪贴板保护、取消与拔麦恢复继续在剩余主线中；沿用 [M5真实操作验收](../../superpowers/validation/2026-11-03-native-client-acceptance.md) 的未完成状态，不给新候选冒用旧候选的真机记录。

归档只包含明确选定的任务/审查报告、聚焦文本日志、原生PNG与清单、产物manifest和M5白名单导出的三次run证据；没有复制验证根中的配置/数据库、音频、模型、app或shader。导出报告保留原始证据引用，未选入归档的内部git命令流和进程结果仍在各 `build/verification/<runID>` 原目录。`SHA256SUMS`覆盖本目录除自身外的所有文件。
