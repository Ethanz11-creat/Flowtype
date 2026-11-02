# M4 开发证据

用户要求先仔细调研，再写计划并开发。基线 `68c72d4`，M3 源码 `f7554ee`，既有完整自测4124/0。研究与计划提交 `bb6d954`；此文件建立时开发尚在进行。

- [设计](../../superpowers/specs/2026-11-02-m4-failure-recovery-design.md)
- [计划](../../superpowers/plans/2026-11-02-m4-failure-recovery.md)
- [Typeless 直接证据](research/typeless.md)
- [现有失败清单](research/failure-inventory.md)
- [验收清单](../2026-11-02-m4-validation.md)

本轮采用常驻交付不确定卡的推荐假设，未虚记为用户单独批准。源码自动验证使用合成数据与隔离系统效果，不能推导真实云端、GUI、权限、模型推理或拔麦通过。V1–V5 继续主线。最终台账、审查、日志和产物身份在完成后追加。

隔离修正：Task2 发现旧 ASRStage 会读取 DictionaryStore.shared，原完整 runner 的 AppLogger 也使用普通用户目录。Task1 与历史全量运行不能据此声称完全隔离用户目录读取/日志写入；未检查用户数据内容，也未尝试回滚真实数据。后续自测使用独立 `CFFIXED_USER_HOME` 进程环境，已用 Foundation 路径探针确认临时 HOME / Application Support；新 ASR 测试还注入空词典。`HOME` 本身未修改。该环境差异需保留正常启动/真实配置验收。
