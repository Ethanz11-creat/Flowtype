# 核心链路审查修复与验证

2026-11-03 开始，2026-11-04 Asia/Shanghai 完成。按用户要求使用 receiving-code-review 核实并修复 [CORE-01～04](../2026-11-03-core-typeless-review/independent-code-review.md)，随后完成独立复查与一个干净候选的完整技术门禁。

**四项源码问题均已关闭，独立复查没有剩余 Critical／Important；全量 25,920/0，24 个技术阶段全部 Pass，含十次启动 smoke。实际验收仍 Pending，未宣称产品发布验收完成。**

## 修复与审查

源码提交：`7e5fd9ba3481df8fea47c08c98b3d9031523d001`。

| 发现 | 修复后的行为 | 回归依据 |
| --- | --- | --- |
| CORE-01 | 数字、代码、引号/JSON 字符串、URL/路径等字面量不再被前置清理改坏；逐条全文规则检查内容保真，标点保留全文上下文 | 实际 PostProcess → Polish → Injection，原文、完成润色和失败回退；含独立复查补出的上下文与 URL 单引号边界 |
| CORE-02 | 主 Unicode 和自动降级均逐键对复查目标/权限；保留不同路径的未知 AX 策略，部分发送后失败仅 uncertain | 实际键对循环，首段、分块、换行期间 PID/焦点/安全输入/权限变化及取消；不重复发送全文 |
| CORE-03 | Apple 预览锁外结束流和清理框架对象，幂等停止并隔离迟到回调 | 实际 StreamingPreviewSession，重入、final/error/stop、取消、超时与迟到任务 |
| CORE-04 | 真实录音心跳由服务中的 Dispatch 队列驱动，使用单调进度时钟，按会话归属取消；先通知冻结再结束流 | 实际 RecordingHeartbeat 与 scheduler，无首帧、中途停流、进度刷新、旧 owner、停止及替换 |

[实施与 RED/GREEN 记录](implementation.md) · [生命周期说明](lifecycle-fix-notes.md) · [独立复查](scoped-rereview.md) · [最终聚焦 1079/0](focused-final.log)。源码问题均早于胶囊开发；不归因于最近的 UI 改动。复查中发现的第一版修复盲点也已记录并关闭，未将早期聚焦通过冒充最终完成。

## 候选对应验证

在上述 clean 提交上仅执行一次完整组合门禁：

```sh
MLX_METALLIB_PATH="$PWD/build/FlowType.app/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib" scripts/verify.sh --lane release
```

Run：`64277922-A392-4F34-8F8D-1E62155C21C9`。[原始报告](release/verify-report.json)、[外层输出](release.stdout)、[退出码](release.exit)、[身份与主哈希复核](final-identity.json)。

| 层级 | 结果 |
| --- | --- |
| 代码构建与完整自测 | Pass，**25,920 passed / 0 failed** |
| 产物、签名、资源/Metal 与恢复 | 全部 Pass |
| 十次独立启动 smoke | 10/10 Pass |
| 所有技术阶段及 source-start/end | **24/24 Pass**；起止均 clean，源码身份一致 |
| 真机 / 远端 CI | **41 项 Pending / Pending** |
| release 总状态 | **Pending，exit 2**，由缺实际验收证据决定，没有技术阶段 Fail |

本地候选 `build/FlowType.app`：**1.0.0 / build386 / arm64**，builtAt `2026-11-03T16:11:26Z`（北京时间 2026-11-04）。[产物清单](FlowType.manifest.json)。

- Sources tree：`eeab631f159fc5ad0820e45fe03edaacbbb237b9`。
- Binary SHA256：`dd8dc5a8d888b732ee4ac01817d16bd538c921818fd0b6b0da4dc455a165e18f`。
- BuildInfo SHA256：`4596164b5b0dc258d07287a296324cc10af8dfba14411e5e910a496563a27973`。
- 显式既有 shader SHA256：`f36b01c44dd5f2d9020deb1ac6ad53dc085de81af19396694c5963ef3a12137f`。

控制器独立核对 HEAD、Sources tree、干净状态、报告与 manifest 身份，以及实际 binary / BuildInfo / shader 主哈希一致。后续文档提交不改写被测源码或二进制身份。

## 证据边界与剩余主线

真实云端弱网/断网、跨应用落字、剪贴板多格式及并发复制、各阶段取消、拔麦/蓝牙恢复继续按 [现有 41 项验收](../../superpowers/validation/2026-11-03-native-client-acceptance.md) 执行；未对新候选冒用旧候选或合成回归的真实操作记录。Typeless 的传输优化、持久历史音频重识别等能力差异仍见 [核心对照表](../2026-11-03-core-typeless-review/core-chain-comparison.md)，本轮没有扩展这些功能。

保真规则被拒绝时，部分普通填充词/空白会保留；URL 歧义标点也优先保留为可能的数据。详见独立复查的明确取舍。AudioRecorder 重编译暴露的原有 warning 及验证准备中的失败已在实施记录中说明，不宣称所有历史编译输出无 warning。

归档使用既有白名单导出器选取 45 个 run 文件，再加入计划、审查、合成 RED/GREEN、manifest 和主身份核对。导出报告保留原始证据引用；未导出的进程结果和内部 git 流仍在 `build/verification/64277922-A392-4F34-8F8D-1E62155C21C9`。未归档 app、模型、shader、音频或验证根内的配置/数据库；`SHA256SUMS` 覆盖本目录除自身外的全部文件。本轮构建未替换 `/Applications/FlowType.app`，真实设备和云端验收尚未执行。
