# M5 开发与验证证据索引

当前阶段：A/B与C1/C2实现及任务审查Pass；C3源码/文档/合成fixture待审，全M5源码审查、最终release技术门禁、远端CI、人工验收及大证据归档仍Pending。当前分支/worktree保留，不push/merge/安装/发布。

## 源码与检查点

| 包 | 实现提交 | 已知证据与边界 |
| --- | --- | --- |
| A1/A2/A3 | aea7dc9 / ffd4ba4 / d6aaace | 最早role、安全根、defaults/Keychain/DB与副作用隔离、BuildInfo/日志，任务审查通过；关于菜单GUI仍Pending |
| B1 | 7488553 | bounded进程归属/超时与真实probe/health timer，受控smoke，不运行普通AppDelegate |
| B2 | df63cd2 | AppResources与artifact合同；focused108/0、full24334/0；fixture不冒充真实GPU |
| B3 | c21cb25 | packaging128/0、runner17/0；一次真实build/check，strict/deep、移位资源、实际Metal及显式MLX GPU微计算均Pass；四个release资源bundle恢复，无marker遗留 |
| C1 | 653ecb8 | RED2/38→工具71/0；共享打包128/0；一次真实code run full24334/0，全7阶段Pass，原始dirty=true |
| C2 | 66f1e78 | RED86/7及集成97/6→工具105/0；shell/YAML语法Pass；不执行远端CI |
| C3 | 本次源码/文档提交，待审 | RED151/36→工具193/0；严格41叶子人工/CI校验、全Pending模板、release逐叶子状态和旧schema1导出兼容；仅合成fixture，最终release尚未调度 |

C1实际run `16D28FC9-F86F-4188-93B2-392D61E071AF` 在HEAD c21cb25、Sources tree `953608b60a0349dfcd2acfc4ddeef6f6d6b39288`，build22461ms/full186629ms，normal exit0/未超时；manual/CI Pending、artifact null。该precommit dirty运行不宣称涵盖任意未跟踪文件内容的精确身份；CI要求clean。其full是当时唯一code lane中的原始完整汇总。

B3候选身份见[验收台账](../2026-11-03-m5-validation.md#最终候选身份)，不是最终C候选；不能把后续归档HEAD改写成被测SHA。Package.resolved blob保持 `702ce34b917f9fdf9927b1b428f431125c28970c`。

Watchdog归属边界：仅向handshake确认的自有进程组发送TERM/KILL；仍留在该组的后代受控，不承诺终止Foundation Process另建独立组的所有后代。Packaging恢复必须继续检查本次journal、live owner/inner PID/group、token和指纹；活跃或冲突时Fail并保留资源，不推断“外层超时即全部结束”，不清理既有普通app。

## 待后续调度的步骤

1. C3任务与全M5源码独立审查；阻塞项同一波修复、限定复审。
2. clean源码上运行一次 `scripts/verify.sh --lane release`，显式shader取当前B3标准Resources路径；code一次、packaging/check一次、固定新候选十次独立smoke。缺人工/CI时预期exit2，技术失败则exit1，不为获得0制造Pass。
3. 保留最终manifest、verify-report、child streams、逐次UUID/tick/duration/hash和限制。后续文档归档提交与被测源码身份分列。
4. 经controller明确归档调度后，才消费安全staging和允许的合成原始证据；本次没有归档大型日志或原始用户文件。

完整41项操作/身份/证据合同与全Pending模板见[台账](../2026-11-03-m5-validation.md)；[原规划调研](../2026-11-03-m5-planning/README.md)及M1–M4历史日志原样保留。真实GUI/设备/模型/云端、权限≤5s、交付/剪贴板/V1–V5未实测项不因fixture通过而关闭。任何远端CI URL也只有被提供后作结构/身份校验，本工具不发起或证明远端执行。
