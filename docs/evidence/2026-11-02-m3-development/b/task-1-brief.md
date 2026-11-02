### Task 1: 保守静音判定与可取消后台扫描

**Files:** Create `Services/Speech/SpeechPreflight.swift`, `Testing/M3SpeechPreflightSelfTests.swift`; Modify `Testing/SelfTest.swift`。（路径前缀 `Sources/flowtype/`。）

**Interfaces:**

- 产生 `enum SpeechPreflightUnknownReason: Equatable, Sendable { case tooShort, unsupportedSampleRate, invalidSamples, detectorUnavailable }`。
- 产生 `enum SpeechPreflightDecision: Equatable, Sendable { case emptyCapture, clearlySilent, possiblySpeech, indeterminate(SpeechPreflightUnknownReason) }`。
- 产生不可变 `struct SpeechPreflightPolicy: Sendable`；`static let conservative` 固定 sampleRate=16000、frameSamples=320、minimumSamples=1600、maximumFrameRMS:Float=0.0003、maximumPeak:Float=0.001。用于第一轮校准的候选参数，不能声称已实测适配。
- 产生 `nonisolated static func SpeechPreflight.analyze(samples: [Float], sampleRate: Int = 16000, policy: SpeechPreflightPolicy = .conservative) throws -> SpeechPreflightDecision`；仅 CPU 统计，完整 raw samples、每帧/尾帧 RMS 和总 peak，用 Double 累加平方；最终数值比较维持 Float32 候选边界。每帧检查 Task cancellation；发现任何非法样本返回 invalidSamples，不能因前部已有声音跳过末尾合法性检查，possiblySpeech 不作人声证明。
- 产生 `typealias SpeechPreflightAnalyzer = @Sendable ([Float], Int) throws -> SpeechPreflightDecision` 与 `nonisolated static func SpeechPreflight.evaluate(samples: [Float], sampleRate: Int = 16000, using analyzer: @escaping SpeechPreflightAnalyzer = { try SpeechPreflight.analyze(samples: $0, sampleRate: $1) }) async throws -> SpeechPreflightDecision`；显式 Task.detached 执行同步 analyzer，取消向 worker 传播，worker 协作退出后返回，不继承调用者 MainActor。using 是响应性测试的窄同步 seam；生产默认必须是 analyze。
- 测试入口 `static func pure(_ r: SelfTest.Reporter)` / `@MainActor static func background(_ r: SelfTest.Reporter) async`。`--m3-silence-only` 与 full suite 均调用，以后的 Task 2 追加 integration。

- [ ] **Step 1: 先写纯判定 RED，包含以下明确值。**

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

- [ ] **Step 2: 运行 `swift run FlowType --self-test --m3-silence-only` 记录 RED，再实现纯扫描。** 不归一化、不裁剪、不创建 `[ArraySlice]` 分帧副本，不依赖 SpeechVAD 或网络。空输入独立结果；有效短输入 indeterminate，完整扫描覆盖最后一个样本。
- [ ] **Step 3: 为生产后台包装写响应/取消回归再接线。** 从 MainActor 调用真实 evaluate，using 同步 seam 内设受控屏障并断言不在主线程；此时 MainActor 心跳/取消可运行，取消后释放屏障，旧结果不得返回为成功。另用默认 analyzer 跑真实合成长音频的取消检查；不能仅传一个已异步 fake 让测试自行避开阻塞。生产默认与纯判定测试继续覆盖原样 analyze。
- [ ] **Step 4: 运行 focused GREEN；记录 30 分钟样本上 production analyze/evaluate 的耗时/取消响应（合成 PCM，不复制用户录音）。** 这项测量只执行一次，记编译模式/硬件，不称为全机型性能门槛；不得为吞吐改丢首尾样本。顺序完整 build/self-test exit 0 后提交 `feat(asr): add cancellable conservative silence preflight`，做任务审查。


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
