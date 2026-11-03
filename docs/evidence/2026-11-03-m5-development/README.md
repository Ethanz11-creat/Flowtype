# M5 开发与验证证据索引

A/B/C实现、逐任务审查和全M5独立源码审查已通过；最终候选的本地技术门禁通过。唯一最终release运行整体为 **exit2 / Pending**：全部24技术阶段Pass，full24334/0，十次独立smoke通过；**41个人工叶子和远端CI仍Pending**。当前分支/worktree保留，未push/merge/安装/发布。

## 最终候选与直接证据

被测源码为 `4cdfaf42cbea1bd04a63a4803a8d103a23e0178f`，Sources tree `953608b60a0349dfcd2acfc4ddeef6f6d6b39288`，source-start/end均clean且一致。候选1.0.0/build353，arm64，builtAt `2026-11-03T05:45:02Z`，固定appPath `/Users/yiheng/pycode/flowtype-local/build/FlowType.app`。

| 证据 | 内容 |
| --- | --- |
| [最终typed报告](runs/3683D6F7-2BD5-4F54-A3EF-5F80A38020D0/verify-report.json) | run3683D6F7-2BD5-4F54-A3EF-5F80A38020D0；24阶段Pass，无Fail/Skip/timeout；manual41Pending、issues空、CI Pending |
| [最终manifest](runs/3683D6F7-2BD5-4F54-A3EF-5F80A38020D0/FlowType.manifest.json) | 14项资源，签名后binary/metadata/shader hash |
| [实际运行报告](c/task-3-actual-release-report.md) | 唯一命令、完整阶段→child映射、时长、候选身份与限制 |
| [独立技术复核](c/final-technical-review.md) | controller读取原始流/结果与十次smoke、独立核实hash后批准技术门禁 |
| [全M5源码审查](c/final-source-review.md) | baseline15ba5e2..4cdfaf4；无开放Critical/Important，无需最终修复波次 |
| [验收台账](../2026-11-03-m5-validation.md) | 完整候选身份、41项真实操作合同、全部Pending |

最终binary SHA256 `d4ab9e5958e8853b0837c85bb1d44869c31646fb3ddeca9da2acee33fd6a32dd`；BuildInfo `b872198de60a3f1ccbed0f48802f3c0c56c0a40d91b122da82bac17151637839`；shader `f36b01c44dd5f2d9020deb1ac6ad53dc085de81af19396694c5963ef3a12137f`。shader146852000B，路径 `Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib`；Package.resolved blob保持 `702ce34b917f9fdf9927b1b428f431125c28970c`。

本次 `docs: record M5 gates and remaining device acceptance` 仅为文档/证据归档提交，其SHA可由git log查询。被测SHA始终为4cdfaf4，不能用后续归档HEAD替代。

## 源码与历史检查点

| 包 | 实现提交 | 证据与边界 |
| --- | --- | --- |
| A1/A2/A3 | aea7dc9 / ffd4ba4 / d6aaace | 最早role、安全根、defaults/Keychain/DB与副作用隔离、BuildInfo/日志，任务审查通过；菜单GUI Pending |
| B1 | 7488553 | bounded进程归属/超时与真实probe/health timer，受控smoke，不运行普通AppDelegate |
| B2 | df63cd2 | AppResources与artifact合同；focused108/0、full24334/0；fixture不冒充真实GPU |
| B3 | c21cb25 | packaging128/0、runner17/0；历史build350真实strict/deep、移位资源及实际Metal/MLX通过；原始记录不改写 |
| C1 | 653ecb8 | RED2/38→工具71/0；共享打包128/0；历史code run全7阶段Pass/full24334/0，dirty=true |
| C2 | 66f1e78 | RED86/7及集成97/6→工具105/0；shell/YAML语法Pass；远端CI未执行 |
| C3 | 4cdfaf4 | RED151/36→工具193/0；严格41叶子、身份与引用校验、全Pending模板、旧schema1兼容，任务审查通过 |

[C1历史code报告](runs/16D28FC9-F86F-4188-93B2-392D61E071AF/verify-report.json) run16D28FC9-F86F-4188-93B2-392D61E071AF在HEAD c21cb25、dirty=true，build22461ms/full186629ms，exit0。manual/CI Pending、artifact null；它不是最终clean候选，也不宣称覆盖未跟踪文件的精确身份。最终release另运行一次code/full并有自己的原始汇总。

## 归档范围与核对

[选择清单](archive-selection.json)列出493个选定文件及其SHA256/字节数/来源；[SHA256SUMS](SHA256SUMS)覆盖最终归档中除自身外的全部文件。A/B只读取controller提供的安全staging；C只取当前C scratch的明确文本与日志；两次run只取typed报告、显式引用命令流、精确独立诊断日志、最终manifest与明确归属的打包命令流。详见[归档策略](archive-policy.md)和[三项去重裁决及代价](rulings.md)。未复制整个运行根、app、shader、配置、数据库、音频或模型。

| 目录 | 选定文件数 | 来源 |
| --- | --- | --- |
| a | 79 | controller安全staging；三项任务brief/report/review、原始安全检查与进度 |
| b | 164 | controller安全staging；B3历史产物记录原样保留 |
| c | 72 | 当前C scratch；任务/独立审查、fixture原始流、实际release parent capture |
| runs | 178 | C1历史code与最终release的报告引用及精确诊断/命令流 |

部分历史报告含当时的绝对build/scratch路径，作为原始记录保留；归档相对路径与最终运行的child映射供独立复核。`progress.md`保留按时间追加的检查点；末尾完成行是最新状态。原规划调研见[历史规划证据](../2026-11-03-m5-planning/README.md)，M1–M4历史日志保持原样。归档后只做文件/JSON/链接/hash/diff检查，没有重复产品验证。

Watchdog仅控制handshake确认的自有进程组及仍留在组内的后代，不承诺终止Foundation Process另建独立组的所有后代。Packaging恢复另查journal、live owner/inner PID/group、token及指纹，活跃或冲突时Fail并保留资源。Effect guards不是OS sandbox；strict ad-hoc签名不等于Developer ID/公证。实际Metal/MLX GPU微计算不证明ASR推理。真实GUI、普通app冷启动、20会话、权限≤5s、模型/声学校准、云端、交付/剪贴板/设备V1–V5均继续Pending。
