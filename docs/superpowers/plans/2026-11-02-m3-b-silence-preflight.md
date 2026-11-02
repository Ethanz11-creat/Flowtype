# M3-B Silence Preflight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 停止后拦截明确静音，避免识别/Apple 预览幻觉落字及历史；不确定的轻声、短词继续原识别链。

**Architecture:** 新增无模型的纯 PCM 扫描与显式后台包装，在 ASRStage 最前方接线，覆盖直接重试入口。先取得 live realtime handle 并安装既有收尾，再检查音频；clearlySilent/empty 返回现有 notice，未知情况放行，取消仍走原会话隔离。

**Tech Stack:** Swift 6.2、macOS 15+、Foundation、16kHz mono Float32、现有 ASRStage/SessionController/self-test；不引入 VAD 权重。

**Spec:** [M3 设计 §2–3、§5–6](../specs/2026-11-02-m3-delivery-and-silence-design.md)。Typeless 原始算法与证据行号在 §2；这是 Float32 的保守静音检查，不是人声分类器。

**Status:** 两项任务 `d9111f1`、`7ce5d21` 及独立任务审查完成；全 M3 修复 `f7554ee` 限定复审通过，顺序 build/full 4124/0（包含最终加强屏障测试）。最终 app 已构建，资源签名既有限制另记。源码步骤已勾选，真实校准及 V1–V5 Step7 保持 Pending，详见[验证记录](../../evidence/2026-11-02-m3-validation.md)。

## Global Constraints

- Swift 6.2、macOS 15+；不新增/升级依赖，不下载 VAD 模型，不运行 Python 或转换脚本。
- 单一 SessionController / SessionContext 生命周期；旧 session 的迟到结果不能发布 UI、历史或交付。
- 音频扫描与 AX IPC 不阻塞 MainActor；取消检查贯穿所有等待与副作用边界。
- 不重置 deliveryAttempted，不自动重发 uncertain，不把 dispatched 写成已确认插入。
- 保留 changeCount + 完整表示快照的剪贴板所有权；不覆盖用户在事务中新增的复制内容。
- 不改变 M2 模型选择、active/captured lease、云端厂商配置和离线合同。
- 只用合成音频/文本、假提供者/剪贴板、隔离配置作自动测试；真机状态单列。
- 使用 `swift build` 后顺序执行 `swift run FlowType --self-test`，不运行 `swift test`；源码稳定后再构建 app。
- 保留分支/worktree，不 push、不 merge，不修改真实配置、权限、用户模型或缓存。

## Review Focus

- 只有最后不足一帧的尾部或录音最开头有短词：不能被抽样/整帧计数漏掉；Task 1 覆盖。
- Float32 低音量、短音频、NaN/Inf/错误采样率：不把未知或损坏信号当作确定静音；Task 1 覆盖。
- 明确静音但 Apple 预览/实时端已有幻觉文本：不可从任何兜底路径继续落字；Task 2 覆盖。
- 实时已开始、预检期间取消/旧结果迟到：资源收尾而不等待不合作网络，旧结果不得污染新会话；Task 2 覆盖。
- 30 分钟最大配置录音扫描与停止预算：后台可取消、不复制整段、不重置 20s 预算；Task 1/2 覆盖并记录性能，真机单列。

## File Structure

| 文件 | 职责 |
| --- | --- |
| 新增 `Sources/flowtype/Services/Speech/SpeechPreflight.swift` | 策略、纯统计结果、显式后台执行；不持有模型或会话 |
| 新增 `Sources/flowtype/Testing/M3SpeechPreflightSelfTests.swift` | 合成 PCM 边界、生产后台包装、真实 ASR/controller 效果计数 |
| 修改 `Sources/flowtype/Core/Pipeline/Stages/ASRStage.swift` | stop 后正式识别前唯一预检入口、live handle 早取/defer 收尾 |
| 修改 `Sources/flowtype/Testing/SelfTest.swift` | focused/full runner、旧路由 fixture 使用明确有声的合成 PCM |
| 修改 `Sources/flowtype/Testing/ImportedLifecycleSelfTests.swift` 等实际命中旧有声fixture的测试 | 仅修订用零样本冒充可识别音频的 fixture，保留原断言 |
| 更新 `docs/evidence/2026-11-02-m3-validation.md` 及现有主线 V/产品矩阵 | 静音与轻声校准、真实推理/服务/设备覆盖 |

不新增独立 pipeline stage，不重写 RecordingStage，不用 trimSilence 或波形 UI 阈值代替预检。

### Task 1: 保守静音判定与可取消后台扫描

**Files:** Create `Services/Speech/SpeechPreflight.swift`, `Testing/M3SpeechPreflightSelfTests.swift`; Modify `Testing/SelfTest.swift`。（路径前缀 `Sources/flowtype/`。）

**Interfaces:**

- 产生 `enum SpeechPreflightUnknownReason: Equatable, Sendable { case tooShort, unsupportedSampleRate, invalidSamples, detectorUnavailable }`。
- 产生 `enum SpeechPreflightDecision: Equatable, Sendable { case emptyCapture, clearlySilent, possiblySpeech, indeterminate(SpeechPreflightUnknownReason) }`。
- 产生不可变 `struct SpeechPreflightPolicy: Sendable`；`static let conservative` 固定 sampleRate=16000、frameSamples=320、minimumSamples=1600、maximumFrameRMS:Float=0.0003、maximumPeak:Float=0.001。用于第一轮校准的候选参数，不能声称已实测适配。
- 产生 `nonisolated static func SpeechPreflight.analyze(samples: [Float], sampleRate: Int = 16000, policy: SpeechPreflightPolicy = .conservative) throws -> SpeechPreflightDecision`；仅 CPU 统计，完整 raw samples、每帧/尾帧 RMS 和总 peak，用 Double 累加平方；最终数值比较维持 Float32 候选边界。每帧检查 Task cancellation；发现任何非法样本返回 invalidSamples，不能因前部已有声音跳过末尾合法性检查，possiblySpeech 不作人声证明。
- 产生 `typealias SpeechPreflightAnalyzer = @Sendable ([Float], Int) throws -> SpeechPreflightDecision` 与 `nonisolated static func SpeechPreflight.evaluate(samples: [Float], sampleRate: Int = 16000, using analyzer: @escaping SpeechPreflightAnalyzer = { try SpeechPreflight.analyze(samples: $0, sampleRate: $1) }) async throws -> SpeechPreflightDecision`；显式 Task.detached 执行同步 analyzer，取消向 worker 传播，worker 协作退出后返回，不继承调用者 MainActor。using 是响应性测试的窄同步 seam；生产默认必须是 analyze。
- 测试入口 `static func pure(_ r: SelfTest.Reporter)` / `@MainActor static func background(_ r: SelfTest.Reporter) async`。`--m3-silence-only` 与 full suite 均调用，以后的 Task 2 追加 integration。

- [x] **Step 1: 先写纯判定 RED，包含以下明确值。**

```swift
r.eq(try SpeechPreflight.analyze(samples: Array(repeating: 0, count: 80000)),
     .clearlySilent, "five-second digital silence")
r.eq(try SpeechPreflight.analyze(samples: []), .emptyCapture, "no captured audio")
r.eq(try SpeechPreflight.analyze(samples: Array(repeating: 0, count: 800)),
     .indeterminate(.tooShort), "50ms never proves silence")
r.eq(try SpeechPreflight.analyze(samples: Array(repeating: 0, count: 1600), sampleRate: 48000),
     .indeterminate(.unsupportedSampleRate), "wrong rate is not silence")
```

加 RMS 边界 0.0003、刚高于边界、peak 0.001/刚高于边界；只有一个首/尾 sample 高于 peak、末尾 1...319 samples 的信号必须 possiblySpeech。NaN/±Inf/abs>1 → invalidSamples；任何位置非法均不能 clearlySilent。100ms 边界、低幅合成正弦、超过 6s 才出现的信号、静音与信号混合帧都钉住。

- [x] **Step 2: 运行 `swift run FlowType --self-test --m3-silence-only` 记录 RED，再实现纯扫描。** 不归一化、不裁剪、不创建 `[ArraySlice]` 分帧副本，不依赖 SpeechVAD 或网络。空输入独立结果；有效短输入 indeterminate，完整扫描覆盖最后一个样本。
- [x] **Step 3: 为生产后台包装写响应/取消回归再接线。** 从 MainActor 调用真实 evaluate，using 同步 seam 内设受控屏障并断言不在主线程；此时 MainActor 心跳/取消可运行，取消后释放屏障，旧结果不得返回为成功。另用默认 analyzer 跑真实合成长音频的取消检查；不能仅传一个已异步 fake 让测试自行避开阻塞。生产默认与纯判定测试继续覆盖原样 analyze。
- [x] **Step 4: 运行 focused GREEN；记录 30 分钟样本上 production analyze/evaluate 的耗时/取消响应（合成 PCM，不复制用户录音）。** 这项测量只执行一次，记编译模式/硬件，不称为全机型性能门槛；不得为吞吐改丢首尾样本。顺序完整 build/self-test exit 0 后提交 `feat(asr): add cancellable conservative silence preflight`，做任务审查。

### Task 2: ASR 接线、实时收尾与无副作用退出

**Files:** Modify `Core/Pipeline/Stages/ASRStage.swift`, `Testing/M3SpeechPreflightSelfTests.swift`, `Testing/SelfTest.swift`；仅在需要时修订现有有声fixture所在测试文件；Update `docs/evidence/2026-11-02-m3-validation.md`, `docs/evidence/2026-11-01-live-validation.md`, `docs/2026-10-14-flowtype-product-validation.md`。

**Interfaces:**

- 消费 Task 1 Decision / evaluate；ASRStage.init 增加 `speechPreflight: @escaping @Sendable ([Float], Int) async throws -> SpeechPreflightDecision = { try await SpeechPreflight.evaluate(samples: $0, sampleRate: $1) }`，其他参数保持源兼容。
- 在初始 owned 检查后，先从 MainActor `context.takeRealtimeAttempt()`，立即装上现有 ingress/startTask/session defer 取消，再等待 speechPreflight；不能把 defer 放在静音早退之后。已有 budget 保留，无 budget 时在 preflight 前创建；route/candidate、DictionaryStore 及正式识别留在获准继续之后。
- clearlySilent 返回 `.notice("未检测到声音，请重试")`；emptyCapture 返回 `.notice("未录到音频，请重试")`；tooShort/detectorUnavailable/possiblySpeech 沿用完整音频和 saved route。已知 invalidSamples/unsupportedSampleRate 挂起 `ASRStageError.invalidAudio`，exact 文案「录音数据异常，请重新录音」、retryable=false，不送给模型/preview。技术检测错误降为 indeterminate(.detectorUnavailable)，CancellationError/取消所有权优先终止，不能被 fail-open catch 吞掉。
- 不在静音路径调用 routeFactory、batch provider、realtimeFactory、session.finish、healthRecorder、PostProcess/Polish/Injection；不接受 preview/realtime 已有文本。已启动实时流只能取消，不能保证此前零上传/计费。
- 原 CompletionBudget 不换对象、不重置秒数；若直接调用 ASRStage 尚无 budget，预检开始时创建同一 20s budget，后续沿用。正常 controller 在 endRecording 已创建预算，预检耗时计入其中。
- 测试入口 `@MainActor static func integration(_ r: SelfTest.Reporter) async`；真实 stage 和 controller，仅换掉采集/网络/compute 等系统边界。

- [x] **Step 1: 写真实 ASRStage 静音/空音频 RED，先不修改生产接线。** 提供有字的 Apple preview 与会返回幻觉的 fake batch/provider，断言均不进入；空音频也不能推广 preview。至少包含：

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

- [x] **Step 2: 接线预检、提前 live 资源收尾和预算。** routeFactory 必须在静音时为 0 次；live realtime 的 ingress/start/session 被取消一次、finish=0。检测器不可用、抛普通技术错误、短词、有声全录音仍到原 provider；非法样本/采样率则数据错误、provider=0；CancellationError/预检返回后取消不启动 provider。无需改现有 Notice 自动消失状态机或引入 M4 FailureKind。
- [x] **Step 3: 增加取消、重试与迟到组合回归。**

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

- [x] **Step 4: 审查并修订旧路由 fixture。** `rg -n 'samples:|repeating: 0|\.audio' Sources/flowtype/Testing` 找到本次受影响项；专测路由/lease/网络成功的 fixture 改为包含明确非静音的确定合成波形；保留原音频长度/首尾/完整性断言。不能全局注入 `.possiblySpeech` 绕开生产默认，专测 preflight 的零输入保持为零。
- [x] **Step 5: 运行 focused GREEN、已有相关实时/lease 回归，再顺序完整 `swift build` 与 `swift run FlowType --self-test`，exit 0 后提交 `feat(asr): stop silent sessions before recognition and preview fallback`。** 保存确切 RED/GREEN、源 tree、警告和限度；不重复未变的完整 suite。
- [x] **Step 6: 做任务审查与全 M3 源码审查。** A/B 共享生命周期及默认配置的影响一起检查；有 Important 修复后限定复审。稳定后重建精确 app，不能用 M2 旧运行进程验收新 M3。
- [ ] **Step 7: 固定源码/bundle执行校准与主线 V。** 正常设备录 5s 静音、轻声、单字/短词、开头/尾部词、超过 6s 再开口；键盘/风扇/风噪记检测结果与局限。自动交付跨五应用、连续20轮、各阶段取消、真实云端弱网/断网、拔麦/蓝牙恢复与既有 V1–V5 对齐。候选参数不达标时记录 Fail，依据测试修订参数/回归并重新固定 bundle；无法执行保留 Pending，不将合成波形通过当真实声音或准确率通过。

## Self-Review / Handoff

已对照 spec：保守/无权重方向与 Typeless 边界、完整原始 PCM、默认候选参数及不确定放行→Task1；ASR 重试、live 清理、preview、预算/health/历史/取消→Task2；真机校准与 V1–V5→Task2 Step7。Review Focus 五项都有归属。参数是待校准值，计划不声称任意噪声都能识别为无语音。

本计划已由 Owner 确认，执行进度以验证记录为准。A/B 全部源码通过后，真实验收尚有 Pending 时仍应明确保留，不把 M3 产品退出条件标成已完成。
