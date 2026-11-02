# M4 验证清单 — 2026-11-02

状态：源码实现完成；Task1/2 已独立审查通过，Task3 审查及全 M4 复审待完成。

依据：[设计](../superpowers/specs/2026-11-02-m4-failure-recovery-design.md)、[实施计划](../superpowers/plans/2026-11-02-m4-failure-recovery.md)、[调研](2026-11-02-m4-development/research/typeless.md)。用户已要求调研→计划→开发，本轮沿用子智能体开发；设计中的常驻交付不确定卡是已说明的推荐假设，不虚记单独批准。

| 门禁 | 状态 |
| --- | --- |
| 纯分类/策略与矩阵 | b92a8dd；focused19328/0，顺序build/full23452/0；任务审查通过 |
| 阶段原因保留/录音启动错误 | 61c691f 顺序build/full23584/0；审查F1在43cc155修复，focused19481/0，限定复审通过；后续full将包含该局部修复 |
| 当前卡动作所有权与交付终态 | 1a07557；M4focused19686/0，M3focused990/0，顺序build/full23811/0；任务审查中 |
| 全 M4 审查与最终构建自测 | Pending |
| 固定 app 与源码/二进制身份 | Pending |
| 权限/真实云端弱网断网/配置恢复 | Pending |
| 无引擎与自动路由、拔麦恢复 | Pending |
| 跨应用不确定交付/剪贴板/取消 | Pending |
| 卡片布局 GUI、旧卡竞态真机 | Pending |

基线68c72d4，M3产品源码f7554ee，既有顺序自测4124/0；未重复未变基线。真实 V1–V5、M2 完整模型运行、M3 声学校准不因本轮源码工作关闭。已知 mlx.metallib 签名限制仍属 M5。
