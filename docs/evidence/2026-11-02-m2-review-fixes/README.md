# M2 追加独立审查与修复 — 2026-11-02

修复基线：`9fa57bf`（此前产品源码 `3a34a51`、2430/0）。Owner 已明确要求修复两项确认的 P2。

- [追加独立审查](independent-review.md)：Whisper `.mlpackage` 缺少原生编译衔接；Qwen 完整复检阻塞 MainActor。
- 修复提交：`e69d6889e5211ffb1a35572eda8030609a313e30`；Sources/flowtype tree `5b583ab9f2d72318e167a5ef81f35619e06e3b66`。[实现报告](report.md)说明编译资源所有权、后台检查与原有协调器生命周期。
- **限定修复范围 PASS**：[独立复审](scoped-rereview.md)确认两项 P2 均 ADDRESSED，未发现修复新增的 Critical／Important。旧源码 PASS 已由本轮证据更新。
- 本轮授权保留接受的源包格式，使用原生 Core ML 编译到应用临时目录；源目录不修改，依赖版本不变。
- 全模型推理、GUI、真实云端及 V1–V5 仍 Pending。微型原生编译检查与合成生命周期测试不能替代这些验收。

最终顺序执行 `swift build`（exit 0，20.68s）后 `swift run FlowType --self-test`（exit 0，**2507 passed / 0 failed**）。源包 RED 为 6/6、扩展 GREEN 34/0；后台检查 RED 为 29/6、扩展 GREEN 43/0。日志保留在本目录，命令、退出码及中间检查见实现报告。既有 AppLogger 警告另列，未引入新的产品源码警告。

`native-smoke.swift` 使用本机 CreateML 生成微型回归模型，执行原样产品准备器、原生编译、Core ML 加载与 CPU 预测；四个组件名及非默认 Manifest 路径通过。初始合成 Manifest 缺少 description 的失败亦保留在 `native-smoke-invalid-fixture.log`。此检查不包含 Whisper 图或完整外部权重语义，不证明语音推理。

本目录保留原审查、实现报告、独立复审、RED/GREEN、原生 smoke 源码与日志。[任务台账](progress.md)记录执行顺序；旧实际检查计时记录为 `inspection-timing.swift` / `inspection-timing-result.txt`。scratch 二进制、完整模型及生成的原生微型模型未纳入 Git。

稳定源码通过复审后执行 `bash scripts/build-app.sh`，exit **0**，release 编译 **87.83s**。[应用身份](bundle-identity.txt)：`build/FlowType.app`，arm64，ad-hoc `com.flowtype.app`；可执行文件 SHA256 `66d06e20ae0b646831b1f2815f2459e11e29e3627852b2b67f76873723b4d083`，CDHash `f02988e9689c24c6af1a92bd50d6dc1b9689526f`。[构建日志](bundle-build.log)及[警告对照](release-warning-comparison.txt)保留全部既有 release 警告，主警告位置／消息与上一版归档一致。

未启动或重启 GUI：当前无可用 CUA 工具，不以旧运行进程冒充新包。本轮没有使用用户模型、真实配置／Key 或私人音频作测试，也未修改模型源文件、缓存或系统权限。此包是开发产物，真实验收与分发状态仍按上文 Pending。

分支 `flowtype-local` 与 worktree 保留，不 push、不 merge。本轮 scratch 在纯文本证据归档后清理；Git 提交与本目录是持久记录。
