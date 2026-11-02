# M4 开发证据

M4 源码完成，三项任务审查、全 M4 修复及限定复审通过，无未关闭阻塞。最终源码 **5dc1693**，Sources tree `872e9038b8def8ed720d9cc6370c57ed12d76794`；顺序构建与完整自测 **23872 passed / 0 failed**。固定 app 已构建，完整签名限制与真实验收分列。

用户要求先仔细调研，再写计划并开发，沿用子智能体工作流。基线68c72d4，M3源码f7554ee、既有4124项；研究/计划提交bb6d954。本轮使用常驻交付不确定卡的已说明推荐假设，不虚记为单独批准。

- [设计](../../superpowers/specs/2026-11-02-m4-failure-recovery-design.md)
- [计划](../../superpowers/plans/2026-11-02-m4-failure-recovery.md)
- [Typeless 直接证据](research/typeless.md)：含恢复源码hash、别名/调用链和静态证据边界
- [现有失败清单](research/failure-inventory.md)
- [验收清单](../2026-11-02-m4-validation.md)
- [固定产物身份与签名](bundle-verification.md)
- [本轮决策及代价](rulings.md)
- [完整台账](sdd/progress.md)

| 门禁 | 结果 / 记录 |
| --- | --- |
| Task1 分类/策略 | b92a8dd，focused19328/0、full23452/0；[审查](sdd/task-1-review.md) |
| Task2 阶段原因/录音启动 | 61c691f +43cc155，typed取消复制修复；[审查](sdd/task-2-review.md)、[限定复审](sdd/task-2-rereview-1.md) |
| Task3 卡片/控制器 | 1a07557 +c292110，摘要/卡片/状态发布竞态修复，full23855/0；[审查](sdd/task-3-review.md)、[限定复审](sdd/task-3-rereview-1.md) |
| 全M4复审 | [完整报告](sdd/final-review.md)：I1调用者在通知后覆盖新任务、M1两条新增测试警告 |
| 一次最终修复波次 | 5dc1693，RED6→GREEN19747/0，顺序build/full23872/0；[报告](sdd/final-fix-report.md) |
| 最终限定复审 | I1/M1 ADDRESSED，无新增Critical/Important；[报告](sdd/final-rereview.md) |
| 产物 | arm64/ad-hoc，主代码校验exit0；strict/deep因已有unsigned mlx.metallib exit1；[完整身份](bundle-verification.md) |

保留失败过程：首次Task3 full的7项M3重试夹具断言失败，是未知ProbeError被正确拒绝重试；改为明确Cloud.timeout后原PCM/预检/handle/预算断言全部保留并通过。最终M4引入19747项断言，原套件4125项（原4124 +typed-timeout一项）。原始RED、编译失败、GREEN、full与构建日志均保存在sdd，未抹掉失败或改写日志。

警告更正：两条M4新增Sendable可变捕获警告在task3报告中曾被漏记，最终报告明确更正归因并用MainActor fixture修复；实际重新编译及限定复审确认消除。原AppLogger/AudioDevice/录音回调等未改动行的既有编译警告仍见release日志，不声明warning-clean。

隔离限制：Task2发现旧ASRStage会读取DictionaryStore.shared，原完整runner的AppLogger也使用普通用户目录。Task1与历史full不能声称完全隔离用户目录读取/日志写入；未检查用户数据内容或尝试回滚真实数据。Task2起自测用独立CFFIXED_USER_HOME进程环境（不改HOME），Foundation路径探针已确认临时HOME/Application Support；新ASR测试注入空词典。正常目录/真实配置启动仍需实际覆盖。

自动验证使用合成音频、假provider/事件/目标/剪贴板及隔离效果，不推导真实云端、GUI、权限、模型推理、声学或拔麦通过。V1–V5继续主线；对应Pending项见验证清单。未运行真实app/smoke、未push/merge；分支与worktree保留。

`sdd/`归档本计划的brief/report/review/diff/rawlog/打包helper，独立运行时临时目录不归档为产品配置。文件hash见sdd/SHA256SUMS，复制与checksum验证通过后才删除本计划scratch；其他计划与用户数据不清理。
