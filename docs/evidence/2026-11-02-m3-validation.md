# M3 验证清单 — 2026-11-02

状态：**Owner 已确认子智能体执行，M3-A 开发中**。执行基线 `8d5d6bd`，此前产品为 M2 源码 `e69d688`。既有 2507/0 是 M2 结果；本文件只在取得新证据后更新对应状态，真实验收保持 Pending。

依据：[共同设计](../superpowers/specs/2026-11-02-m3-delivery-and-silence-design.md)、[M3-A 计划](../superpowers/plans/2026-11-02-m3-a-automatic-delivery.md)、[M3-B 计划](../superpowers/plans/2026-11-02-m3-b-silence-preflight.md)。执行负责人为开发控制器；Owner 执行需物理热键、复制、拔麦与本机认证的操作。

## 源码验证

| ID | 覆盖 | 状态 |
| --- | --- | --- |
| S-A1 | 三模式策略、安全/权限/目标身份、回退纯判定 | Pass（源码）：`c9f91a1`，focused 133/0，完整 2640/0；独立任务审查通过 |
| S-A2 | 默认/旧值迁移、真实 ClipboardTransaction+InjectionStage、部分写板恢复、受保护板键入失败 | Pending |
| S-A3 | 事件前后取消、并发复制、目标复检、duplicate attempt、一次历史/摘要和菜单 | Pass（自动化，待阶段独立审查）：Task3（父 `7700f36`），focused 381/0，顺序 build/full 2888/0；不代表真机通过 |
| S-B1 | 原始 PCM 全帧/尾帧、候选阈值、短音频/无效样本、后台响应/取消 | Pending |
| S-B2 | 真实 ASR/controller 的静音早退；preview、health、预算、live 收尾与重试/旧回调 | Pending |
| S-F | 稳定源码顺序 build/full self-test、独立全 M3 审查及修复复审 | Pending |

### M3-A Task3 阶段证据

Task3 在已批准运行时 `7700f36` 上添加内存 `LastDeliverySummary`、诚实的四种终态动词和可注入的禁用菜单项。摘要只含 sessionID/outcome/停止目标展示名/bundle ID，不含转写、音频或上下文；uncertain 文案固定为「已发送，但无法确认是否插入；可从历史复制」。正常 finish 与既有已终态 uncertain 取消保存路径共用当前所有权校验；静音 notice、无事件取消、旧会话屏障释放不清空或污染新摘要。同步菜单订阅使用 emitted value，打开菜单时再次刷新。

自动化命令及结果：

- RED：`swift run FlowType --self-test --m3-delivery-only`，exit 1，305 passed / 1 failed（旧 uncertain 文案）；随后先写摘要/菜单契约测试，缺失接口产生预期编译 RED。
- GREEN：同 focused 命令，exit 0，381 passed / 0 failed；包含真实 controller + 隔离 SessionEffects 保存 seam 的 once-only、取消与晚到结果测试，以及独立注入菜单的即时/重开刷新。
- 稳定源码顺序执行 `swift build` 后 `swift run FlowType --self-test`：均 exit 0，完整 2888 passed / 0 failed；未运行 `swift test`。focused 编译只见既有 AppLogger.swift:27 警告；最终增量 build/full 日志无警告，本轮未出现 AppleSpeechProvider 警告。
- 新增摘要/菜单没有转写日志；成功日志未出现测试专用的 synthetic transcript/final 标记。历史持久化/隐私模式、polish 降级组合与剪贴板事务未改动。

本阶段只做源码/合成测试；控制器负责独立 A/全 M3 审查，并按裁定在 B 后稳定最终源码构建 app、固定二进制身份及执行真机矩阵。未运行中间 app 构建或 GUI，不把 150ms 恢复窗口、实际插入或 V1–V5 记为 Pass。所有下表真机 Pending 保持不变。

## 真实验收（全部必做）

| ID | 操作 | 通过条件 | 主线关联 | 状态 |
| --- | --- | --- | --- | --- |
| M3-A1 | TextEdit、VS Code、Chrome、Terminal、Cursor，分别中文/英文/多行 | 原目标完整一次落字；Terminal 不误提交命令；记录应用版本和实际 outcome | V2.1 | Pending |
| M3-A2 | 录音前/停止前/处理中切 app 或已知文本框；非文本/secure/noAX | 停止时目标合同明确；变目标与不安全输入不发键，可恢复文本 | V2.2 | Pending |
| M3-A3 | 合成文字/RTF/图片/文件、多 item、多 representation | 支持的表示完整保留；快照不完整不破坏；键入回退失败仍保留原板 | V3.1 | Pending |
| M3-A4 | 事务期间另复制，分别正常完成和取消 | 不覆盖新复制；所有权变化不重发；观察 150ms 目标消费 | V3.2、V4 | Pending |
| M3-A5 | 新配置/缺键配置/两种旧显式模式及 UI 切换 | automatic 新默认、旧值不改；模式可见/可选；摘要动词诚实，无转写泄漏 | UI | Pending |
| M3-B1 | 实际选定设备录 5s 静音并停止 | 短暂 notice、无幻觉/落字/历史；batch 不发识别，实时只记录停止后未 finalize | V1、V5.2 | Pending |
| M3-B2 | 轻声、极短词、立即开口、开头/尾部词、超过 6s 再开口 | 不误拦，不裁头尾；没有录音早期 6s 自动停止 | 音频校准 | Pending |
| M3-B3 | 风扇、敲键盘、风噪和安静背景 | 如实记录候选参数/误拦/放行；不以有能量声称有人声；不宣称噪声全能过滤 | 能力边界 | Pending |
| M3-C1 | preparing/recording/预检/ASR/polish/injection 分别取消；旧回调随后返回 | 无迟到交付/历史/摘要污染；已发出的边界另记 uncertain | V4.1、V4.2 | Pending |
| M3-C2 | 已授权真实云端正常/弱网/录音中断网，本地已加载 | 受控预算、完整本地兜底、单次终态与交付；静音不重复 finalize | V1.1–V1.3 | Pending |
| M3-C3 | 真实 USB/蓝牙失联、默认/指定设备；连接后重试 | 设备错误不伪装静音，释放后可恢复；保留真实物理设备证据 | V5.1、V5.2 | Pending |
| M3-C4 | 连续 20 轮成功/静音/取消/重新录音 | 全部回 idle，无重复/卡住/麦克风残留，历史数量对应实际终态 | 连续稳定性 | Pending |

## 记录规则

每轮固定 source SHA、source tree、bundle 路径/二进制 SHA、macOS/硬件、目标 app 版本、配置/权限、sessionID、事件顺序及脱敏计时。测试内容只用合成参考句；不得保存私人音频/转写/上下文/密钥。网络、权限、设备条件按实际动作授权执行并恢复。

若桌面/工具/应用/有效云配置/外设不可用，记录具体前提并保持 Pending，不能用假传输、旧运行进程或静态元数据作为 Pass。M2 的实际模型推理剩余覆盖继续保留；M3 源码通过不能自动关闭 V1–V5。

静音候选值：20ms/320 samples、minimum 100ms/1600 samples、RMS 0.0003、peak 0.001，全部是待校准的 Float32 参数，并非 Typeless 量化阈值。一次真实 Fail 必须保留；调整参数时记录理由、旧/新结果及新回归，重新固定源码/bundle 后再验收。

### M3-B Task2 ASR integration evidence — 2026-11-02

ASRStage now calls the production `SpeechPreflight.evaluate` before route creation,
DictionaryStore lookup, provider recognition or preview fallback. It takes the
live handle and installs ingress/start/session cleanup before awaiting preflight.
A capture's existing monotonic completion budget is preserved; a direct stage
entry without one creates its single 20-second budget before scanning. Silence
and empty capture return the specified notices without downstream processing,
health/history/delivery writes or a new delivery summary. Known invalid PCM/rate
returns non-retryable `ASRStageError.invalidAudio`; the existing controller presents
that data error as a notice without retry/copy actions. Technical detector errors
fail open with full original PCM; cancellation wins over detector results/errors.

Synthetic coverage uses the real ASRStage and SessionController, synthetic capture,
real PostProcess/Polish/Injection stages with external-effect seams, isolated
settings, fake batch/realtime providers and completion barriers. It covers the
three routing policies; nonempty Apple preview; previous summary preservation;
live cancel without finish; invalid PCM; original short/head/tail/delayed PCM and
fallback; unchanged/reduced/expired budgets; explicit ASR retry with a fresh live
handle; and obsolete silent/speech results after newer successful delivery.
Only three tiny imported-lease routing fixtures changed from zeros to deterministic
nonzero PCM, preserving their lengths. No global preflight bypass was introduced.

Task2 validation: initial real-ASR/controller RED 756 passed / 51 failed; focused
GREEN 987/0; related realtime/route/imported-lease regression 292/0; sequential
`swift build` then full `swift run FlowType --self-test` both exit 0, full 3875/0.
A final test-only refinement replaced fixed yields with an explicit old-ASR
completion observation; focused rerun passed 989/0, followed by `swift build`.
Production source was unchanged after the full run; per controller ruling the
unchanged full suite was not repeated. The focused compile retains the existing
AppLogger.swift:27 Sendable warning; no new warning was introduced.
Task2 command outcomes and exact source identities are retained in the local
implementation report `.superpowers/sdd/2026-11-02-m3-b-silence-preflight/task-2-report.md`.
Independent Task2/full-M3 review and final app packaging belong to the controller.
This evidence does not close any real-device row: 5s microphone silence, quiet or
short words, head/tail/delayed speech, keyboard/fan/wind noise, five applications,
20 consecutive sessions, V1–V5 and device recovery all remain **Pending**. The
Float32 energy thresholds remain uncalibrated candidate values. An already-started
realtime session may have uploaded audio or incurred charges during recording;
this integration prevents stop-time finalize and delivery, not prior upload.
