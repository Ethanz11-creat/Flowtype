### Task 2: ASR 接线、实时收尾与无副作用退出

**Files:** Modify `Core/Pipeline/Stages/ASRStage.swift`, `Testing/M3SpeechPreflightSelfTests.swift`, `Testing/SelfTest.swift`；仅在需要时修订现有有声fixture所在测试文件；Update `docs/evidence/2026-11-02-m3-validation.md`, `docs/evidence/2026-11-01-live-validation.md`, `docs/2026-10-14-flowtype-product-validation.md`。

**Interfaces:**

- 消费 Task 1 Decision / evaluate；ASRStage.init 增加 `speechPreflight: @escaping @Sendable ([Float], Int) async throws -> SpeechPreflightDecision = { try await SpeechPreflight.evaluate(samples: $0, sampleRate: $1) }`，其他参数保持源兼容。
- 在初始 owned 检查后，先从 MainActor `context.takeRealtimeAttempt()`，立即装上现有 ingress/startTask/session defer 取消，再等待 speechPreflight；不能把 defer 放在静音早退之后。已有 budget 保留，无 budget 时在 preflight 前创建；route/candidate、DictionaryStore 及正式识别留在获准继续之后。
- clearlySilent 返回 `.notice("未检测到声音，请重试")`；emptyCapture 返回 `.notice("未录到音频，请重试")`；tooShort/detectorUnavailable/possiblySpeech 沿用完整音频和 saved route。已知 invalidSamples/unsupportedSampleRate 挂起 `ASRStageError.invalidAudio`，exact 文案「录音数据异常，请重新录音」、retryable=false，不送给模型/preview。技术检测错误降为 indeterminate(.detectorUnavailable)，CancellationError/取消所有权优先终止，不能被 fail-open catch 吞掉。
- 不在静音路径调用 routeFactory、batch provider、realtimeFactory、session.finish、healthRecorder、PostProcess/Polish/Injection；不接受 preview/realtime 已有文本。已启动实时流只能取消，不能保证此前零上传/计费。
- 原 CompletionBudget 不换对象、不重置秒数；若直接调用 ASRStage 尚无 budget，预检开始时创建同一 20s budget，后续沿用。正常 controller 在 endRecording 已创建预算，预检耗时计入其中。
- 测试入口 `@MainActor static func integration(_ r: SelfTest.Reporter) async`；真实 stage 和 controller，仅换掉采集/网络/compute 等系统边界。

- [ ] **Step 1: 写真实 ASRStage 静音/空音频 RED，先不修改生产接线。** 提供有字的 Apple preview 与会返回幻觉的 fake batch/provider，断言均不进入；空音频也不能推广 preview。至少包含：

```swift
// ctx 保存 localOnly/cloudOnly/auto 路由的不同 fixture；samples 为 80000 个 0。
// 直接执行真实 ASRStage，然后通过真实 SessionController 组合再验证。
r.eq(batchCalls, 0, "silence sends no batch recognition")
r.eq(previewDeliveries, 0, "preview cannot bypass silence")
r.eq(healthWrites, 0, "silence is not provider failure")
r.eq(historyWrites, 0, "no transcription history for silence")
r.eq(deliveryWrites, 0, "no keyboard or clipboard mutation")
```

真实 registry 仍为 Recording→ASR→PostProcess→Polish→Injection；测试使用 synthetic recording stage 产生 `.audio`，不是把 ASRStage 本身替换成返回 notice 的 fake。

- [ ] **Step 2: 接线预检、提前 live 资源收尾和预算。** routeFactory 必须在静音时为 0 次；live realtime 的 ingress/start/session 被取消一次、finish=0。检测器不可用、抛普通技术错误、短词、有声全录音仍到原 provider；非法样本/采样率则数据错误、provider=0；CancellationError/预检返回后取消不启动 provider。无需改现有 Notice 自动消失状态机或引入 M4 FailureKind。
- [ ] **Step 3: 增加取消、重试与迟到组合回归。**

| 场景 | 精确断言 |
| --- | --- |
| live realtime 已开始且可能已有临时文本 | no finish、新 factory=0、取消收尾；无 transcript/后处理/交付/历史，不能断言此前 start/append=0 |
| 等待中的 preflight 被取消后新会话成功，旧结果随后返回 silent 或 speech | 旧 UI/summary/history/provider 调用不增加，新会话结果不被覆盖 |
| ASR 错误的显式 Retry、直接 stage 调用 | 每次均经过 preflight；不会复用已终止 live handle；既有显式 retry 更新预算规则保留 |
| 预检用掉部分停止预算 | 同一 budget 身份、remaining 减少，不变回 20s；到期不开始 provider |
| tooShort/detectorUnavailable、检测异常、极短词、首尾/延迟有声 | 原始 samples 数量/顺序完整，原候选链仍工作；不裁头尾/不额外上屏 partial |
| invalidSamples / unsupportedSampleRate | 录音数据错误、retryable=false，provider/preview/health/落字/历史均无新增 |
| 5s 静音 + 非空 Apple preview + 有可用引擎 | notice，history=0、postprocess/polish/inject=0；保留上次 delivery summary |
| 真实 controller 取消/notice | 无资源残留的状态收尾；notice 自动回 idle 的原机制仍可运行，不要求新增长期等待测试 |

- [ ] **Step 4: 审查并修订旧路由 fixture。** `rg -n 'samples:|repeating: 0|\.audio' Sources/flowtype/Testing` 找到本次受影响项；专测路由/lease/网络成功的 fixture 改为包含明确非静音的确定合成波形；保留原音频长度/首尾/完整性断言。不能全局注入 `.possiblySpeech` 绕开生产默认，专测 preflight 的零输入保持为零。
- [ ] **Step 5: 运行 focused GREEN、已有相关实时/lease 回归，再顺序完整 `swift build` 与 `swift run FlowType --self-test`，exit 0 后提交 `feat(asr): stop silent sessions before recognition and preview fallback`。** 保存确切 RED/GREEN、源 tree、警告和限度；不重复未变的完整 suite。
- [ ] **Step 6: 做任务审查与全 M3 源码审查。** A/B 共享生命周期及默认配置的影响一起检查；有 Important 修复后限定复审。稳定后重建精确 app，不能用 M2 旧运行进程验收新 M3。
- [ ] **Step 7: 固定源码/bundle执行校准与主线 V。** 正常设备录 5s 静音、轻声、单字/短词、开头/尾部词、超过 6s 再开口；键盘/风扇/风噪记检测结果与局限。自动交付跨五应用、连续20轮、各阶段取消、真实云端弱网/断网、拔麦/蓝牙恢复与既有 V1–V5 对齐。候选参数不达标时记录 Fail，依据测试修订参数/回归并重新固定 bundle；无法执行保留 Pending，不将合成波形通过当真实声音或准确率通过。

## Self-Review / Handoff

已对照 spec：保守/无权重方向与 Typeless 边界、完整原始 PCM、默认候选参数及不确定放行→Task1；ASR 重试、live 清理、preview、预算/health/历史/取消→Task2；真机校准与 V1–V5→Task2 Step7。Review Focus 五项都有归属。参数是待校准值，计划不声称任意噪声都能识别为无语音。

本计划已由 Owner 确认，执行进度以验证记录为准。A/B 全部源码通过后，真实验收尚有 Pending 时仍应明确保留，不把 M3 产品退出条件标成已完成。

## Binding Context

Spec: docs/superpowers/specs/2026-11-02-m3-delivery-and-silence-design.md. Read only relevant sections and this task; do not read the whole implementation plan.


- Swift 6.2、macOS 15+；不新增/升级依赖，不下载 VAD 模型，不运行 Python 或转换脚本。
- 单一 SessionController / SessionContext 生命周期；旧 session 的迟到结果不能发布 UI、历史或交付。
- 音频扫描与 AX IPC 不阻塞 MainActor；取消检查贯穿所有等待与副作用边界。
- 不重置 deliveryAttempted，不自动重发 uncertain，不把 dispatched 写成已确认插入。
- 保留 changeCount + 完整表示快照的剪贴板所有权；不覆盖用户在事务中新增的复制内容。
- 不改变 M2 模型选择、active/captured lease、云端厂商配置和离线合同。
- 只用合成音频/文本、假提供者/剪贴板、隔离配置作自动测试；真机状态单列。
- 使用 `swift build` 后顺序执行 `swift run FlowType --self-test`，不运行 `swift test`；源码稳定后再构建 app。
- 保留分支/worktree，不 push、不 merge，不修改真实配置、权限、用户模型或缓存。

Controller owns independent review, app packaging and actual acceptance; do not dispatch subagents or operate GUI/real user resources. Scope commits to your source/tests and specifically authorized evidence changes; controller plan/audit/status edits may be dirty and must not be staged.
