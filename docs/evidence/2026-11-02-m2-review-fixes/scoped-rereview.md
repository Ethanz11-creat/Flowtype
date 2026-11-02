# Independent scoped re-review — 2026-11-02

Reviewer: `m2_fix_rereview`, fresh isolated `gpt-6-astra`, high. Fix range `9fa57bf..e69d6889e5211ffb1a35572eda8030609a313e30`. Read-only; no suite rerun or checkout mutation.

**P2：Whisper `.mlpackage` 缺少运行时准备 — ADDRESSED。**

- `Sources/flowtype/Services/Speech/WhisperModelPreparation.swift:37` 保留必需组件、可选 prefill、纯编译及混合输入；`:57`、`:68` 将整个 package 交给原生 Core ML 编译，保留 Manifest 根路径与资源解析；`:54` 生成 pinned WhisperKit 实际查找的组件名称。
- `Sources/flowtype/Services/Speech/OfflineWhisperKit.swift:184` 将准备后的目录传给运行时，保留原 tokenizer 与离线参数；`:172`、`:192` 将生成资源所有权保留至 backend 生命周期结束。`WhisperASRProvider.swift:48`、`:79` 的 provider／计算闭包持有链覆盖 active/captured lease 和未结束推理。
- `WhisperModelPreparation.swift:23` 等待同步编译真正结束后才返回取消；`:12` 仅清理应用生成目录，混合输入使用符号链接。原始来源目录与身份保持不变。

**P2：完整模型检查阻塞 MainActor — ADDRESSED。**

- `Sources/flowtype/Services/Speech/LocalModelManager/LocalModelInspection.swift:11` 显式 detached 执行同步检查，`:13` 等待排空，`:15` 拒绝取消后的结果。coordinator 的 `QwenModelState.swift:366` 与运行时复检的 `LocalASRRuntimeFactory.swift:8` 均使用该边界。
- `QwenModelState.swift:278` 使 legacy 初检进入同一操作生命周期；`:176` 先预留操作，`:315` 持有全局 gate，`:367` 检查返回后核验所有权。`:372` 保留 canonical UUID／资源检查，`:420` 继续仅在成功时读取最新配置并提交。
- `Sources/flowtype/Testing/M2ReviewFixSelfTests.swift:127` 注入阻塞的同步检查器；`:149`、`:159`、`:165` 验证四个入口的 MainActor 心跳、取消、竞争操作、排空与晚到结果抑制；`:173` 验证原 captured provider 仍可使用。

**New Breakage in Fix Diff：** 未发现新增 Critical／Important。无待修复 Important。

**Out-of-Scope Observations：** 无新增问题。真实 Whisper/Qwen 完整模型推理、GUI、云服务及 V1–V5 仍为 Pending。

**Checks：**

- 只读核对 supplied diff、原始 findings、brief、worker report、相关源码及 pinned WhisperKit 路径解析／加载契约；未修改 checkout/index/HEAD，未重跑 suite。
- 对照测试源码核验日志：package RED **6/6** → GREEN **34/0**；inspection RED **29/6** → GREEN **43/0**。
- 核验最终 build exit **0**；完整 self-test exit **0，2507 passed／0 failed**。
- 核对 native smoke 源码与日志：四个微型组件完成原生整包编译、加载及 CPU prediction，并验证清理。这不证明完整 Whisper 推理或真实外部权重语义。

**Verdict：限定修复范围通过 — 两项均 ADDRESSED，未发现新增 Critical／Important；真实环境验收尚未完成。**
