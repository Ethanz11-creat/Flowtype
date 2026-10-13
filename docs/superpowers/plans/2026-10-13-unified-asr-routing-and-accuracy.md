# 统一 ASR 能力层与「又快又准」实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Flowtype 在用户同时配置本地与云端 ASR 后，自动择优、无感切换（默认云端优先，网络差切本地兜底），并把「准」的来源（前台上下文）与端到端指标补齐。

**Architecture:** 用一个统一的 `ASRCapabilities` + `ASRRequest/ASRResult` 契约取代所有 `as? QwenASRProvider` 运行时类型判断；新增 `ASRRouter`（健康画像 + 网络探测 + 候选链降级）决定谁来识别；新增 `ContextProvider`（AX 采集前台上下文）统一组装 `ASRContext`；每轮会话写入 `stopToInjectMs` 等无内容指标。

**Tech Stack:** Swift 6.2、SPM、macOS 15+、GRDB（SQLite）、Network（NWPathMonitor/NWConnection）、ApplicationServices（AX API）、Combine。

**Spec:** `docs/superpowers/specs/2026-10-13-unified-asr-routing-and-accuracy-design.md`

## Global Constraints

- 每个任务结束时必须 `swift build` 成功 且 `swift run FlowType --self-test` 退出码为 0。
- 代码中**不得**再出现 `as? QwenASRProvider` / `is CloudASRProvider` 这类 provider 类型判断（`Tests/SelfTest.swift` 中的断言字符串除外）。
- 不做流式 ASR、不做实时中间文本上屏（`previewTextPublisher` 不再用于 UI 主展示）。
- 本地路径（`qwen-local`）音频与上下文均不出设备；云端路径默认携带上下文（规格 §3.4）。
- API Key 继续存 `Configuration.providerAPIKeys`（UserDefaults），**不得**迁回 Keychain。
- 路由策略默认 `.auto`；老配置 `asrEngine=.local → .localOnly`、`.cloud → .cloudOnly`，**不得改变老用户既有行为**。
- `Configuration` 解码必须向后兼容：缺失新键时用默认值，不得抛错。
- `SessionController` 保持 `@MainActor`；`ASRProvider` 实现继续用 `@unchecked Sendable` + 内部锁/串行队列。
- 音频字节契约不变：`ASRRequest.samples` 是 **16kHz 单声道 Float32 裸样本**（非 WAV）。
- 提交信息沿用仓库风格：`feat(...)` / `fix(...)` / `refactor(...)` / `test(...)` / `chore(...)`。

---

## File Structure

**新建**
- `Sources/flowtype/Services/Speech/ASRContract.swift` — `ProviderLocation` / `ASRCapabilities` / `ASRContext` / `ASRRequest` / `ASRResult` + 纯函数 `composeProviderContext`。
- `Sources/flowtype/Services/Speech/ASRRoutingPolicy.swift` — 策略枚举 + `ASRRoutingInputs` / `ASRRoutingThresholds` + 纯函数 `selectASRChain`。
- `Sources/flowtype/Services/Speech/ASRRouter.swift` — 健康画像、网络探测、`selectChain()`、成功/失败回写。
- `Sources/flowtype/Services/Context/ContextProvider.swift` — `ForegroundContext`、`ContextProvider` 协议、`ForegroundContextSanitizer`（纯）。
- `Sources/flowtype/Services/Context/AXContextProvider.swift` — AX API 实现 + 辅助功能权限。
- `Sources/flowtype/Core/SessionMetrics.swift` — `percentile` 纯函数 + `SessionMetrics.report`。

**修改**
- `Sources/flowtype/Services/Speech/ASRProvider.swift` — 协议升级。
- `Sources/flowtype/Services/Speech/QwenASRProvider.swift` / `CloudASRProvider.swift` / `AppleSpeechProvider.swift` — 适配。
- `Sources/flowtype/Services/Speech/ASRProviderRegistry.swift` — 收敛为容器。
- `Sources/flowtype/Core/Pipeline/Stages/ASRStage.swift` — 纯编排 + 降级链。
- `Sources/flowtype/Core/Pipeline/PipelineOrchestrator.swift` — 删两处 `as?`、指标计时。
- `Sources/flowtype/Core/Pipeline/SessionContext.swift` — 新增 `usedProviderID` / `foregroundContextText` / `stopRecordingAt` / 各段耗时。
- `Sources/flowtype/Core/Configuration.swift` — `asrRoutingPolicy` 取代 `asrEngine`（含迁移）。
- `Sources/flowtype/Core/DictationHistory.swift` + `Core/Database/Records.swift` + `Core/Database/AppDatabase.swift` — 指标列 + v4 迁移。
- `Sources/flowtype/Settings/SettingsPage+ASR.swift` / `ASRModelStatusCard.swift` — 策略选择 + 健康状态 + 云端上下文开关 + 指标复制。
- `Sources/flowtype/Testing/SelfTest.swift` — 每个任务新增对应自测。

**删除**
- `Sources/flowtype/Services/Speech/SpeechProvider.swift`
- `Sources/flowtype/Services/Speech/SpeechRouter.swift`

---

### Task A1: ASR 契约类型与纯路由决策

建立数据契约与**纯函数**决策逻辑（不触碰任何现有调用方，可独立测试）。

**Files:**
- Create: `Sources/flowtype/Services/Speech/ASRContract.swift`
- Create: `Sources/flowtype/Services/Speech/ASRRoutingPolicy.swift`
- Test: `Sources/flowtype/Testing/SelfTest.swift`

**Interfaces:**
- Consumes: 现有 `composeASRContext(_:maxCount:maxChars:)`（`Core/Dictionary.swift:5`）
- Produces:
  - `enum ProviderLocation { onDevice, cloud }`
  - `struct ASRCapabilities { supportsLanguageHint, supportsContextHint, requiresNetwork: Bool; location: ProviderLocation; maxAudioDuration: TimeInterval?; estimatedWarmLatencyMs: Int }`
  - `struct ASRContext { phrases: [String]; foreground: String? }`
  - `struct ASRRequest { samples: [Float]; sampleRate: Int; language: String?; context: ASRContext?; timeout: TimeInterval }`
  - `struct ASRResult { text: String; providerID: String; latencyMs: Int }`
  - `func composeProviderContext(_ context: ASRContext?, maxCount: Int = 50, maxChars: Int = 300, maxForegroundChars: Int = 1200) -> String?`
  - `enum ASRRoutingPolicy: String, Codable, CaseIterable, Identifiable { auto, cloudOnly, localOnly }`（`displayName` 中文）
  - `struct ASRRoutingInputs { policy; localAvailable; cloudAvailable; networkReachable: Bool; cloudLatencyEWMA: Double; cloudConsecutiveFailures: Int }`
  - `enum ASRRoutingThresholds { static let cloudLatencyMs: Double = 3000; static let cloudFailureStreak = 2 }`
  - `func selectASRChain(_ input: ASRRoutingInputs) -> [String]`（返回 `"cloud-asr"` / `"qwen-local"` 有序数组；空数组 = 无可用）

- [ ] **Step 1: 写失败的测试**

在 `SelfTest.swift` 的 `runAndExit()` 中，`testASRConfig(r)` 之后插入：

```swift
        testASRRouting(r)          // unified ASR routing: pure chain selection
        testProviderContextCompose(r) // ASRContext → provider prompt hint
```

在 `SelfTest.swift` 末尾（`testInjectionSegmentation` 之后、类的闭合 `}` 之前）添加：

```swift
    // MARK: - Unified ASR routing: pure candidate-chain decision

    static func testASRRouting(_ r: Reporter) {
        func inputs(policy: ASRRoutingPolicy = .auto, local: Bool = true, cloud: Bool = true,
                    net: Bool = true, lat: Double = 0, fails: Int = 0) -> ASRRoutingInputs {
            ASRRoutingInputs(policy: policy, localAvailable: local, cloudAvailable: cloud,
                             networkReachable: net, cloudLatencyEWMA: lat,
                             cloudConsecutiveFailures: fails)
        }
        r.eq(selectASRChain(inputs()), ["cloud-asr", "qwen-local"], "route: auto healthy → cloud first")
        r.eq(selectASRChain(inputs(net: false)), ["qwen-local", "cloud-asr"], "route: auto offline → local first")
        r.eq(selectASRChain(inputs(lat: 5000)), ["qwen-local", "cloud-asr"], "route: auto slow cloud → local first")
        r.eq(selectASRChain(inputs(fails: 2)), ["qwen-local", "cloud-asr"], "route: auto failing cloud → local first")
        r.eq(selectASRChain(inputs(lat: 3000)), ["cloud-asr", "qwen-local"], "route: auto latency at threshold → cloud first")
        r.eq(selectASRChain(inputs(cloud: false)), ["qwen-local"], "route: auto cloud missing → local only")
        r.eq(selectASRChain(inputs(local: false)), ["cloud-asr"], "route: auto local missing → cloud only")
        r.eq(selectASRChain(inputs(local: false, cloud: false)), [], "route: auto neither → empty")
        r.eq(selectASRChain(inputs(policy: .localOnly)), ["qwen-local"], "route: localOnly → local")
        r.eq(selectASRChain(inputs(policy: .localOnly, local: false)), [], "route: localOnly+unavailable → empty")
        r.eq(selectASRChain(inputs(policy: .localOnly, net: false)), ["qwen-local"], "route: localOnly ignores network")
        r.eq(selectASRChain(inputs(policy: .cloudOnly)), ["cloud-asr"], "route: cloudOnly → cloud")
        r.eq(selectASRChain(inputs(policy: .cloudOnly, cloud: false)), [], "route: cloudOnly+unavailable → empty")

        // policy round-trips and legacy display
        let data = try! JSONEncoder().encode(ASRRoutingPolicy.auto)
        r.eq(try? JSONDecoder().decode(ASRRoutingPolicy.self, from: data), .auto, "route: policy round-trips")
        r.eq(ASRRoutingPolicy.allCases.count, 3, "route: exactly 3 policies")
    }

    // MARK: - ASRContext → provider prompt hint

    static func testProviderContextCompose(_ r: Reporter) {
        r.check(composeProviderContext(nil) == nil, "ctx: nil → nil")
        r.check(composeProviderContext(ASRContext(phrases: [], foreground: nil)) == nil, "ctx: empty → nil")
        r.eq(composeProviderContext(ASRContext(phrases: ["React"], foreground: nil)), "React", "ctx: phrases only")
        r.eq(composeProviderContext(ASRContext(phrases: [], foreground: "func main()")), "func main()", "ctx: foreground only")
        r.eq(composeProviderContext(ASRContext(phrases: ["React"], foreground: "func main()")),
             "React\nfunc main()", "ctx: phrases then foreground")
        let longFG = String(repeating: "x", count: 5000)
        r.eq((composeProviderContext(ASRContext(phrases: [], foreground: longFG)) ?? "").count, 1200,
             "ctx: foreground truncated to 1200")
        r.check(composeProviderContext(ASRContext(phrases: [], foreground: "   ")) == nil, "ctx: blank foreground → nil")
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift run FlowType --self-test`
Expected: 编译失败（`cannot find 'selectASRChain' in scope`、`cannot find type 'ASRRoutingInputs'`）。

- [ ] **Step 3: 实现契约文件**

`Sources/flowtype/Services/Speech/ASRContract.swift`：

```swift
import Foundation

/// 运行位置 — 决定隐私文案与路由过滤。
enum ProviderLocation: String, Sendable, Codable {
    case onDevice
    case cloud
}

/// Provider 能力声明。取代所有运行时的 `as? QwenASRProvider` 能力判断。
struct ASRCapabilities: Sendable, Equatable {
    let supportsLanguageHint: Bool
    let supportsContextHint: Bool
    let requiresNetwork: Bool
    let location: ProviderLocation
    let maxAudioDuration: TimeInterval?
    let estimatedWarmLatencyMs: Int
}

/// 一次识别所需的全部上下文，打包成一个值类型。
struct ASRContext: Sendable, Equatable {
    let phrases: [String]      // 用户词典热词
    let foreground: String?    // 前台上下文文本，nil 表示未采集/不可用
}

/// 一次识别请求。`samples` 仍是 16kHz 单声道 Float32 裸样本（字节契约不变）。
struct ASRRequest: Sendable {
    let samples: [Float]
    let sampleRate: Int
    let language: String?      // nil = 自动
    let context: ASRContext?
    let timeout: TimeInterval
}

/// 一次识别结果。
struct ASRResult: Sendable, Equatable {
    let text: String
    let providerID: String
    let latencyMs: Int
}

/// 把词典热词与前台上下文拼成一段 provider 提示。
/// 热词在前（信号更强），前台文本截断到 `maxForegroundChars` 避免 prompt 膨胀。
func composeProviderContext(
    _ context: ASRContext?,
    maxCount: Int = 50,
    maxChars: Int = 300,
    maxForegroundChars: Int = 1200
) -> String? {
    guard let context else { return nil }
    var parts: [String] = []
    if let phrasePart = composeASRContext(context.phrases, maxCount: maxCount, maxChars: maxChars) {
        parts.append(phrasePart)
    }
    if let fg = context.foreground?.trimmingCharacters(in: .whitespacesAndNewlines), !fg.isEmpty {
        parts.append(String(fg.prefix(maxForegroundChars)))
    }
    return parts.isEmpty ? nil : parts.joined(separator: "\n")
}
```

`Sources/flowtype/Services/Speech/ASRRoutingPolicy.swift`：

```swift
import Foundation

/// 用户可见的路由策略。
enum ASRRoutingPolicy: String, Codable, CaseIterable, Identifiable {
    case auto
    case cloudOnly
    case localOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "自动（推荐）"
        case .cloudOnly: return "仅云端"
        case .localOnly: return "仅本地"
        }
    }
}

/// 路由决策的全部输入（纯数据，便于测试）。
struct ASRRoutingInputs: Equatable, Sendable {
    let policy: ASRRoutingPolicy
    let localAvailable: Bool
    let cloudAvailable: Bool
    let networkReachable: Bool
    let cloudLatencyEWMA: Double       // ms；0 = 未知（视为健康）
    let cloudConsecutiveFailures: Int
}

enum ASRRoutingThresholds {
    static let cloudLatencyMs: Double = 3000
    static let cloudFailureStreak = 2
}

/// 纯决策：返回有序候选 provider id（"cloud-asr" / "qwen-local"）。
/// 空数组表示无候选可用 → ASRStage 走 notice / 预览兜底。
func selectASRChain(_ input: ASRRoutingInputs) -> [String] {
    switch input.policy {
    case .localOnly:
        return input.localAvailable ? ["qwen-local"] : []
    case .cloudOnly:
        return input.cloudAvailable ? ["cloud-asr"] : []
    case .auto:
        if input.localAvailable && input.cloudAvailable {
            // 产品默认：云端优先；网络不可达 / 云端延迟明显升高 / 连续失败 → 本地兜底。
            let cloudHealthy = input.networkReachable
                && input.cloudConsecutiveFailures < ASRRoutingThresholds.cloudFailureStreak
                && (input.cloudLatencyEWMA == 0 || input.cloudLatencyEWMA <= ASRRoutingThresholds.cloudLatencyMs)
            return cloudHealthy ? ["cloud-asr", "qwen-local"] : ["qwen-local", "cloud-asr"]
        }
        if input.localAvailable { return ["qwen-local"] }
        if input.cloudAvailable { return ["cloud-asr"] }
        return []
    }
}
```

- [ ] **Step 4: 运行自测确认通过**

Run: `swift build && swift run FlowType --self-test`
Expected: `=== self-test: N passed, 0 failed ===`，退出码 0。

- [ ] **Step 5: 提交**

```bash
git add Sources/flowtype/Services/Speech/ASRContract.swift \
        Sources/flowtype/Services/Speech/ASRRoutingPolicy.swift \
        Sources/flowtype/Testing/SelfTest.swift
git commit -m "feat(asr): add unified ASR contract types and pure routing decision"
```

---

### Task A2: Provider 协议迁移并消除所有 `as?` 特判

把三个 provider 迁到新协议，`ASRStage` 改为纯编排，删除 `SpeechProvider`/`SpeechRouter`。

**Files:**
- Modify: `Sources/flowtype/Services/Speech/ASRProvider.swift`（整体替换）
- Modify: `Sources/flowtype/Services/Speech/QwenASRProvider.swift:58-79,127-188`
- Modify: `Sources/flowtype/Services/Speech/CloudASRProvider.swift:81-97,148-164`
- Modify: `Sources/flowtype/Services/Speech/AppleSpeechProvider.swift:6-14,65-70`
- Modify: `Sources/flowtype/Services/Speech/ASRProviderRegistry.swift`（整体替换）
- Modify: `Sources/flowtype/Core/Pipeline/Stages/ASRStage.swift`（整体替换）
- Modify: `Sources/flowtype/Core/PipelineOrchestrator.swift:177-186,455-463`
- Modify: `Sources/flowtype/Core/Pipeline/SessionContext.swift`（新增 `usedProviderID`）
- Delete: `Sources/flowtype/Services/Speech/SpeechProvider.swift`
- Delete: `Sources/flowtype/Services/Speech/SpeechRouter.swift`
- Test: `Sources/flowtype/Testing/SelfTest.swift`

**Interfaces:**
- Consumes: `ASRRequest` / `ASRResult` / `ASRCapabilities`（Task A1）
- Produces:
  - `protocol ASRProvider: Sendable { id; displayName; capabilities: ASRCapabilities; isAvailable: Bool { get async }; transcribe(_ request: ASRRequest) async throws -> ASRResult }`
  - `QwenASRProvider.transcribe(samples:sampleRate:language:context:) async throws -> String`（保留，内部方法）
  - `CloudASRProvider.transcribe(_ request: ASRRequest)`；`ASRContext` 经 `prompt` 表单字段下发
  - `ASRProviderRegistry.routingCandidates: [ASRProvider]` = `[qwenLocalProvider, cloudProvider]`
  - `SessionContext.usedProviderID: String?`

> 注意：本任务**暂不**引入健康画像——`ASRStage` 先用「按策略过滤出的可用 provider 顺序」作为候选链，A4 再替换为 `ASRRouter`。

- [ ] **Step 1: 写失败的测试**

在 `runAndExit()` 中 `testProviderContextCompose(r)` 之后插入：

```swift
        testASRBackendLabel(r)     // context.usedProviderID → history backend label
```

追加测试函数：

```swift
    // MARK: - ASR backend label mapping (replaces the old `as? QwenASRProvider` branches)

    static func testASRBackendLabel(_ r: Reporter) {
        r.eq(SessionController.backendLabel(forProviderID: "qwen-local"), "qwen", "backend: qwen-local → qwen")
        r.eq(SessionController.backendLabel(forProviderID: "cloud-asr"), "cloud", "backend: cloud-asr → cloud")
        r.eq(SessionController.backendLabel(forProviderID: nil), "apple", "backend: nil → apple (preview fallback)")
        r.eq(SessionController.backendLabel(forProviderID: "unknown"), "apple", "backend: unknown id → apple")
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift run FlowType --self-test`
Expected: 编译失败（`cannot find 'backendLabel' in scope`）。

- [ ] **Step 3: 替换 `ASRProvider.swift`**

```swift
import Foundation

/// 本地与云端 ASR provider 的统一接口。
///
/// 音频契约：`ASRRequest.samples` 是 **16kHz 单声道 Float32 裸样本**（非 WAV 容器）。
/// 需要容器的 provider（WAV / multipart）自行编码（见 `CloudASRProvider`）。
protocol ASRProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var capabilities: ASRCapabilities { get }
    var isAvailable: Bool { get async }
    func transcribe(_ request: ASRRequest) async throws -> ASRResult
}
```

- [ ] **Step 4: 迁移 `QwenASRProvider`**

把 `QwenASRProvider.swift:58-64` 改为：

```swift
final class QwenASRProvider: ASRProvider, @unchecked Sendable {
    let name: String = "QwenASR"
    let id = "qwen-local"
    let displayName = "本地 ASR (Qwen)"
    nonisolated let capabilities = ASRCapabilities(
        supportsLanguageHint: true,
        supportsContextHint: true,
        requiresNetwork: false,
        location: .onDevice,
        maxAudioDuration: nil,
        estimatedWarmLatencyMs: 1500
    )

    var isAvailable: Bool { get async { isLoaded } }
```

把 `QwenASRProvider.swift:170-188`（`SpeechProvider Conformance (Data-based)` + `rawFloat32ToSamples`）整段删除，替换为：

```swift
    // MARK: - ASRProvider Conformance

    func transcribe(_ request: ASRRequest) async throws -> ASRResult {
        let start = Date()
        let text = try await transcribe(
            samples: request.samples,
            sampleRate: request.sampleRate,
            language: request.language,
            context: composeProviderContext(request.context)
        )
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        return ASRResult(text: text, providerID: id, latencyMs: ms)
    }
```

（保留其上方已有的 `func transcribe(samples:sampleRate:language:context:) async throws -> String` 原样不动。）

- [ ] **Step 5: 迁移 `CloudASRProvider`**

把 `CloudASRProvider.swift:81-97` 的两行 `nonisolated let` 与 `transcribe(audioData:timeout:)` 头替换为：

```swift
actor CloudASRProvider: ASRProvider {
    nonisolated let id = "cloud-asr"
    nonisolated let name = "CloudASR"
    nonisolated let displayName = "云端 ASR"
    nonisolated let capabilities = ASRCapabilities(
        supportsLanguageHint: true,
        supportsContextHint: true,   // 以 `prompt` 字段尽力下发（见 Q3：云端默认带上下文）
        requiresNetwork: true,
        location: .cloud,
        maxAudioDuration: nil,
        estimatedWarmLatencyMs: 2000
    )

    var isAvailable: Bool {
        get async {
            let config = await MainActor.run { ConfigurationStore.shared.current }
            guard let effective = config.effectiveCloudASRConfig else { return false }
            let baseURL = effective.provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = effective.provider.model.trimmingCharacters(in: .whitespacesAndNewlines)
            return !effective.apiKey.isEmpty && !baseURL.isEmpty && !model.isEmpty
        }
    }

    func transcribe(_ request: ASRRequest) async throws -> ASRResult {
        let start = Date()
        let audioData = request.samples.withUnsafeBytes { Data($0) }
        let text = try await transcribe(audioData: audioData, timeout: request.timeout, context: request.context)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        return ASRResult(text: text, providerID: id, latencyMs: ms)
    }

    func transcribe(audioData: Data, timeout: TimeInterval, context: ASRContext?) async throws -> String {
```

函数体内（原 `transcribe(audioData:timeout:)`），在 `appendFormField(name: "temperature", value: "0.0")` 之后插入：

```swift
        // 云端默认携带上下文（用户可在设置中关闭）。后端不支持该字段时会被忽略。
        if await MainActor.run(body: { ConfigurationStore.shared.current.cloudASRSendContext }),
           let prompt = composeProviderContext(context) {
            appendFormField(name: "prompt", value: prompt)
        }
```

- [ ] **Step 6: 迁移 `AppleSpeechProvider` 为「仅预览/兜底」**

`AppleSpeechProvider.swift:6` 的 `final class AppleSpeechProvider: ASRProvider, @unchecked Sendable {` 改为：

```swift
final class AppleSpeechProvider: @unchecked Sendable {
```

删除 `AppleSpeechProvider.swift:10` 的 `nonisolated let supportsStreaming = true`，并删除 `:12-14` 的 `var isAvailable: Bool { get async { ... } }`。其余方法（`startStreamingRecognition` / `stopStreamingRecognition` / `appendAudioBuffer` / `transcribe(audioData:)`）保留不动。

- [ ] **Step 7: 替换 `ASRProviderRegistry.swift`**

```swift
import Foundation

/// provider 实例容器。路由决策不在这里 —— 见 `ASRRouter`（Task A4）。
final class ASRProviderRegistry: @unchecked Sendable {
    static let shared = ASRProviderRegistry()

    let qwenLocalProvider: QwenASRProvider
    let cloudProvider: CloudASRProvider
    /// 仅用于录音中的实时预览与「全部候选失败」时的文本兜底，不是路由候选。
    let applePreviewProvider: AppleSpeechProvider

    private init() {
        self.qwenLocalProvider = QwenASRProvider()
        self.cloudProvider = CloudASRProvider()
        self.applePreviewProvider = AppleSpeechProvider()
    }

    var routingCandidates: [ASRProvider] { [qwenLocalProvider, cloudProvider] }
    var previewProvider: AppleSpeechProvider { applePreviewProvider }

    func provider(forID id: String) -> ASRProvider? {
        switch id {
        case "qwen-local": return qwenLocalProvider
        case "cloud-asr": return cloudProvider
        default: return nil
        }
    }
}
```

- [ ] **Step 8: 重写 `ASRStage.swift`**

```swift
import Foundation

// MARK: - ASRStage

/// 纯编排：组装 `ASRRequest` → 按策略候选链依次尝试 → 收 `ASRResult`。
/// 无任何 provider 类型判断；AppleSpeech 预览仅作最后兜底。
///
/// Input: `.audio(samples: [Float], previewText: String)`
/// Output: `.transcript(String)`
final class ASRStage: PipelineStage, @unchecked Sendable {

    var name: String { "ASR" }

    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        let sessionID = context.sessionID
        AppLogger.log("[ASRStage#\(sessionID)] Processing phase started")
        let processingStartTime = Date()
        defer {
            let total = Date().timeIntervalSince(processingStartTime)
            AppLogger.log("[ASRStage#\(sessionID)] Processing phase ended (total: \(String(format: "%.1f", total))s)")
        }

        let rawSamples: [Float]
        let localPreviewText: String
        switch payload {
        case .audio(let samples, let previewText):
            rawSamples = samples
            localPreviewText = previewText
        default:
            AppLogger.log("[ASRStage#\(sessionID)] Unexpected payload: \(payload), expected .audio")
            return .suspend(ErrorRecoveryContext(failedStage: name, error: ASRStageError.invalidPayload,
                                                 rawText: nil, retryable: false))
        }

        let audioDuration = Double(rawSamples.count) / 16000.0
        AppLogger.log("[ASRStage#\(sessionID)] Raw samples: \(rawSamples.count) (\(String(format: "%.1f", audioDuration))s)")

        let cfg = await MainActor.run { ConfigurationStore.shared.current }
        let phrases = await MainActor.run { DictionaryStore.shared.enabledPhrases }
        let foreground = await MainActor.run { context.foregroundContextText }
        let request = ASRRequest(
            samples: rawSamples,
            sampleRate: 16000,
            language: cfg.asrLanguage.qwenLanguageCode,
            context: ASRContext(phrases: phrases, foreground: foreground),
            timeout: min(120.0, max(30.0, audioDuration * 3 + 15))
        )

        let chain = await candidateChain()
        AppLogger.log("[ASRStage#\(sessionID)] Candidate chain: \(chain.map(\.id))")

        var finalASRText = ""
        var providerFailed = false
        var firstFailure: Error?

        if !rawSamples.isEmpty {
            for provider in chain {
                if Task.isCancelled {
                    return .suspend(ErrorRecoveryContext(failedStage: name, error: CancellationError(),
                                                         rawText: nil, retryable: false))
                }
                await MainActor.run {
                    context.statePublisher.send(.processing(provider: provider.displayName))
                }
                let asrStart = Date()
                do {
                    let result = try await provider.transcribe(request)
                    let elapsed = Date().timeIntervalSince(asrStart)
                    AppLogger.log("[ASRStage#\(sessionID)] \(provider.displayName) completed in \(String(format: "%.2f", elapsed))s: \(result.text.count) chars")
                    finalASRText = result.text
                    await MainActor.run {
                        context.usedProviderID = result.providerID
                        context.asrMs = result.latencyMs
                    }
                    // A4 接入 ASRRouter 后在此回写云端健康画像。
                } catch is CancellationError {
                    AppLogger.log("[ASRStage#\(sessionID)] \(provider.displayName) cancelled")
                    return .suspend(ErrorRecoveryContext(failedStage: name, error: CancellationError(),
                                                         rawText: nil, retryable: false))
                } catch {
                    AppLogger.log("[ASRStage#\(sessionID)] \(provider.displayName) failed: \(error)")
                    if firstFailure == nil { firstFailure = error }
                    providerFailed = true
                    // A4 接入 ASRRouter 后在此记一次失败。
                }
            }
        }

        if finalASRText.isEmpty, !localPreviewText.isEmpty {
            AppLogger.log("[ASRStage#\(sessionID)] Using AppleSpeech preview as fallback")
            finalASRText = localPreviewText
        }

        guard !finalASRText.isEmpty else {
            if chain.isEmpty {
                let noticeMsg = (cfg.asrEngine == .cloud)
                    ? "云端 ASR 未就绪，请在设置中配置 API Key"
                    : "本地模型未加载，请在设置中下载模型"
                AppLogger.log("[ASRStage#\(sessionID)] No provider in chain, notice: \(noticeMsg)")
                return .notice(noticeMsg)
            }
            if providerFailed {
                return .suspend(ErrorRecoveryContext(
                    failedStage: name,
                    error: ASRStageError.transcriptionFailed(message: "语音识别失败，请检查网络连接或重试"),
                    rawText: nil,
                    retryable: true
                ))
            }
            AppLogger.log("[ASRStage#\(sessionID)] No speech recognized — ending session quietly")
            return .complete
        }

        return .continue(.transcript(finalASRText))
    }

    /// 临时候选链（Task A4 由 `ASRRouter` 取代）：按 legacy engine 过滤可用 provider。
    /// Task A3（配置迁移）会把 `cfg.asrEngine` 换成 `cfg.asrRoutingPolicy`。
    private func candidateChain() async -> [ASRProvider] {
        let cfg = await MainActor.run { ConfigurationStore.shared.current }
        let registry = ASRProviderRegistry.shared
        let policy: ASRRoutingPolicy = (cfg.asrEngine == .cloud) ? .cloudOnly : .localOnly
        let inputs = ASRRoutingInputs(
            policy: policy,
            localAvailable: registry.qwenLocalProvider.isLoaded,
            cloudAvailable: await registry.cloudProvider.isAvailable,
            networkReachable: true,          // A4 引入真实网络探测
            cloudLatencyEWMA: 0,
            cloudConsecutiveFailures: 0
        )
        return selectASRChain(inputs).compactMap { registry.provider(forID: $0) }
    }
}

enum ASRStageError: Error, LocalizedError {
    case invalidPayload
    case transcriptionFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidPayload: return "无效的输入数据"
        case .transcriptionFailed(let msg): return msg
        }
    }
}
```

- [ ] **Step 9: 给 `SessionContext` 增加字段**

在 `SessionContext.swift` 的 `var polishFailed: Bool = false` 之后插入：

```swift
    /// 本轮实际使用的 ASR provider id（由 ASRStage 写入），用于历史与指标。
    var usedProviderID: String?

    /// 前台上下文文本（由 ContextStage / ContextProvider 写入；nil 表示未采集）。
    var foregroundContextText: String?

    /// 用户停止录音的时刻（用于 stopToInjectMs）。
    var stopRecordingAt: Date?

    /// 各段耗时（毫秒）。
    var asrMs: Int?
    var polishMs: Int?
    var injectMs: Int?
```

- [ ] **Step 10: 清理 `PipelineOrchestrator` 的两处 `as?`**

`PipelineOrchestrator.swift:177-186` 整段（`let activeProvider = ...` 到 `transition(to: .processing(provider: providerName), context: context)`）替换为：

```swift
        context.stopRecordingAt = Date()
        // ASRStage 会随后用真实 provider 名刷新 .processing(provider:) 状态。
        transition(to: .processing(provider: "识别中"), context: context)
```

`PipelineOrchestrator.swift:455-463`（`let activeProvider = ...` 到 `}` of if/else）替换为：

```swift
        let sttBackend = SessionController.backendLabel(forProviderID: context.usedProviderID)
```

并在 `SessionController` 内（`historyMode` 附近，`nonisolated static`）新增：

```swift
    /// sttBackend 文案：不再依赖 provider 类型判断。
    nonisolated static func backendLabel(forProviderID id: String?) -> String {
        switch id {
        case "qwen-local": return "qwen"
        case "cloud-asr": return "cloud"
        default: return "apple"
        }
    }
```

- [ ] **Step 11: 删除死代码**

```bash
rm Sources/flowtype/Services/Speech/SpeechProvider.swift \
   Sources/flowtype/Services/Speech/SpeechRouter.swift
```

若 `SpeechProviderError` 仍被引用（`AppLogger`/其它 provider），将其定义搬到 `ASRContract.swift` 末尾：

```swift
enum SpeechProviderError: Error {
    case transcriptionFailed(String)
    case networkError(Error)
    case notAvailable
    case permissionDenied
}
```

- [ ] **Step 12: 构建 + 自测**

Run: `swift build && swift run FlowType --self-test`
Expected: 编译通过；自测全绿。若 `CloudASRProvider` 报 `await MainActor.run(body:)` 语法错误，改成：

```swift
        let sendContext = await MainActor.run { ConfigurationStore.shared.current.cloudASRSendContext }
        if sendContext, let prompt = composeProviderContext(context) {
            appendFormField(name: "prompt", value: prompt)
        }
```

- [ ] **Step 13: 提交**

```bash
git add -A Sources/flowtype/Services/Speech Sources/flowtype/Core
git commit -m "refactor(asr): migrate providers to unified ASRProvider protocol, remove as? special-casing"
```

---

### Task A3: 配置迁移 `asrEngine` → `asrRoutingPolicy` 与设置 UI

**Files:**
- Modify: `Sources/flowtype/Core/Configuration.swift:112-123,364-365,453,494,521`
- Modify: `Sources/flowtype/Settings/SettingsPage+ASR.swift:21-34`
- Modify: `Sources/flowtype/Settings/ASRModelStatusCard.swift:10-25,114-118`
- Test: `Sources/flowtype/Testing/SelfTest.swift:863-884,1057`

**Interfaces:**
- Consumes: `ASRRoutingPolicy`（Task A1）
- Produces: `Configuration.asrRoutingPolicy: ASRRoutingPolicy`；`Configuration.cloudASRSendContext: Bool = true`；`ASREngineType`（保留，仅用于 legacy 解码）

- [ ] **Step 1: 写失败的测试（替换 `testASRConfig`）**

把 `SelfTest.swift:861-884` 的整个 `testASRConfig` 替换为：

```swift
    // MARK: - ASR routing policy config: round-trip + legacy engine migration

    static func testASRConfig(_ r: Reporter) {
        var cfg = Configuration()
        cfg.asrRoutingPolicy = .localOnly
        cfg.cloudASRSendContext = false
        cfg.selectedLocalModelID = "test-model-id"
        cfg.customLocalModelPath = "/tmp/custom-model"
        if let data = try? JSONEncoder().encode(cfg),
           let back = try? JSONDecoder().decode(Configuration.self, from: data) {
            r.eq(back.asrRoutingPolicy, .localOnly, "asrcfg: asrRoutingPolicy round-trips .localOnly")
            r.eq(back.cloudASRSendContext, false, "asrcfg: cloudASRSendContext round-trips false")
            r.eq(back.selectedLocalModelID, "test-model-id", "asrcfg: selectedLocalModelID round-trips")
            r.eq(back.customLocalModelPath, "/tmp/custom-model", "asrcfg: customLocalModelPath round-trips")
        } else {
            r.check(false, "asrcfg: encode/decode round-trip failed")
        }
        // legacy: asrEngine 存在 → 保持老用户行为
        let legacyLocal = Data(#"{"asrLanguage":"zh","asrEngine":"local"}"#.utf8)
        r.eq(try? JSONDecoder().decode(Configuration.self, from: legacyLocal).asrRoutingPolicy,
             .localOnly, "asrcfg: legacy asrEngine=local → localOnly")
        let legacyCloud = Data(#"{"asrLanguage":"zh","asrEngine":"cloud"}"#.utf8)
        r.eq(try? JSONDecoder().decode(Configuration.self, from: legacyCloud).asrRoutingPolicy,
             .cloudOnly, "asrcfg: legacy asrEngine=cloud → cloudOnly")
        // 全新安装 → auto（云端优先）
        let fresh = Data(#"{"asrLanguage":"zh"}"#.utf8)
        let decoded = try? JSONDecoder().decode(Configuration.self, from: fresh)
        r.eq(decoded?.asrRoutingPolicy, .auto, "asrcfg: missing key → auto")
        r.eq(decoded?.cloudASRSendContext, true, "asrcfg: missing key → cloudASRSendContext true")
        r.eq(decoded?.cloudASRConfig.providers.count, 1, "asrcfg: legacy missing key → default SiliconFlow provider")
        r.eq(decoded?.cloudASRConfig.providers.first?.provider, "SiliconFlow", "asrcfg: default provider is SiliconFlow")
        r.eq(decoded?.cloudASRConfig.providers.first?.model, "", "asrcfg: default model is empty (user must select)")
    }
```

把 `SelfTest.swift:1057` 改为：

```swift
        r.eq(cfg.asrRoutingPolicy, .auto, "inject-edge: default asrRoutingPolicy == .auto")
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift run FlowType --self-test`
Expected: 编译失败（`value of type 'Configuration' has no member 'asrRoutingPolicy'`）。

- [ ] **Step 3: 修改 `Configuration`**

`Configuration.swift:112-123` 的 `ASREngineType` 保留，但加注释表明仅供 legacy 解码：

```swift
/// 旧字段（仅用于向后兼容解码；运行时使用 `ASRRoutingPolicy`）。
enum ASREngineType: String, Codable, CaseIterable, Identifiable {
    case local = "local"
    case cloud = "cloud"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .local: return "本地识别（离线）"
        case .cloud: return "云端识别（联网）"
        }
    }

    /// legacy → 新策略：保持老用户既有行为。
    var asRoutingPolicy: ASRRoutingPolicy {
        switch self {
        case .local: return .localOnly
        case .cloud: return .cloudOnly
        }
    }
}
```

`Configuration.swift:364-365` 替换为：

```swift
    // ASR routing policy (replaces the legacy binary asrEngine switch)
    var asrRoutingPolicy: ASRRoutingPolicy = .auto
    /// 云端请求是否携带前台上下文（默认开启；设置中可关闭）。
    var cloudASRSendContext: Bool = true
```

`Configuration.swift:453` 替换为：

```swift
        if let legacyEngine = try? c.decode(ASREngineType.self, forKey: .asrEngine) {
            asrRoutingPolicy = legacyEngine.asRoutingPolicy          // 老用户保持原行为
        } else {
            asrRoutingPolicy = (try? c.decode(ASRRoutingPolicy.self, forKey: .asrRoutingPolicy)) ?? d.asrRoutingPolicy
        }
        cloudASRSendContext = (try? c.decodeIfPresent(Bool.self, forKey: .cloudASRSendContext)) ?? true
```

`Configuration.swift:494` 的 `CodingKeys` 中保留 `case asrEngine`（legacy 解码），并新增：

```swift
        case asrRoutingPolicy
        case cloudASRSendContext
```

`Configuration.swift:521` 替换为：

```swift
        try container.encode(asrRoutingPolicy, forKey: .asrRoutingPolicy)
        try container.encode(cloudASRSendContext, forKey: .cloudASRSendContext)
```

同时把 `ASRStage.swift` 的 `candidateChain()` 里策略来源从 legacy 换成新字段：

```swift
        let policy: ASRRoutingPolicy = (cfg.asrEngine == .cloud) ? .cloudOnly : .localOnly
```

改为：

```swift
        let policy = cfg.asrRoutingPolicy
```

- [ ] **Step 4: 更新设置 UI**

`SettingsPage+ASR.swift:21-34` 替换为：

```swift
            Picker("", selection: $store.current.asrRoutingPolicy) {
                ForEach(ASRRoutingPolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            .pickerStyle(.segmented)

            switch store.current.asrRoutingPolicy {
            case .localOnly:
                LocalModelPicker()
                ASRModelStatusCard()
            case .cloudOnly:
                CloudASRProviderList()
                ASRModelStatusCard()
            case .auto:
                LocalModelPicker()
                CloudASRProviderList()
                ASRModelStatusCard()
            }
```

把 `:15` 的说明文案替换为：

```swift
            Text("Flowtype 同时支持本地（Qwen3-ASR，离线）与云端（OpenAI 兼容接口）识别。自动模式下默认优先云端，网络不佳时无感切换到本地兜底；断网时本地路径可用且音频不出设备。")
```

`ASRModelStatusCard.swift:10-25` 替换为：

```swift
            switch store.current.asrRoutingPolicy {
            case .localOnly:
                localStatusView
            case .cloudOnly:
                cloudStatusView
            case .auto:
                localStatusView
                Divider().opacity(0.3)
                cloudStatusView
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 10)
        .task(id: store.current.asrRoutingPolicy) {
            await refreshCloudStatus()
        }
```

`ASRModelStatusCard.swift:115` 替换为：

```swift
        guard store.current.asrRoutingPolicy != .localOnly else { cloudAvailable = nil; return }
```

- [ ] **Step 5: 构建 + 自测**

Run: `swift build && swift run FlowType --self-test`
Expected: 全绿。

- [ ] **Step 6: 提交**

```bash
git add Sources/flowtype/Core/Configuration.swift Sources/flowtype/Settings Sources/flowtype/Testing/SelfTest.swift
git commit -m "feat(asr): replace asrEngine switch with routing policy + legacy migration"
```

---

### Task A4: `ASRRouter` —— 健康画像、网络探测与降级链

**Files:**
- Create: `Sources/flowtype/Services/Speech/ASRRouter.swift`
- Modify: `Sources/flowtype/Core/Pipeline/Stages/ASRStage.swift`（用 `ASRRouter.shared.selectChain()` 取代 A2 的临时 `candidateChain()`）
- Test: `Sources/flowtype/Testing/SelfTest.swift`

**Interfaces:**
- Consumes: `selectASRChain` / `ASRRoutingInputs` / `ASRRoutingThresholds`（A1）；`ASRProviderRegistry.provider(forID:)`（A2）
- Produces:
  - `final class ASRRouter: @unchecked Sendable { static let shared; func selectChain() async -> [ASRProvider]; func recordSuccess(providerID:latencyMs:); func recordFailure(providerID:); func snapshot() -> RouterHealthSnapshot }`
  - `struct RouterHealthSnapshot: Sendable, Equatable { var cloudLatencyEWMA: Double; var cloudConsecutiveFailures: Int; var networkReachable: Bool }`
  - `func updateLatencyEWMA(previous: Double, sample: Double, alpha: Double = 0.3) -> Double`（纯，可测）

- [ ] **Step 1: 写失败的测试**

`runAndExit()` 中 `testASRBackendLabel(r)` 之后插入：

```swift
        testRouterEWMA(r)          // ASR router health: EWMA update math
```

追加：

```swift
    // MARK: - ASR router health: latency EWMA

    static func testRouterEWMA(_ r: Reporter) {
        // 首个样本（previous == 0）直接采用，避免从 0 缓慢爬升
        r.eq(updateLatencyEWMA(previous: 0, sample: 800), 800, "ewma: first sample taken directly")
        // 后续样本按 alpha=0.3 加权
        r.eq(updateLatencyEWMA(previous: 1000, sample: 2000), 1300, "ewma: alpha 0.3 blend")
        r.eq(updateLatencyEWMA(previous: 1000, sample: 0), 700, "ewma: fast sample pulls average down")
        // 单调性：连续慢样本必须把均值推过阈值
        var v = 0.0
        for _ in 0..<5 { v = updateLatencyEWMA(previous: v, sample: 5000) }
        r.check(v > ASRRoutingThresholds.cloudLatencyMs, "ewma: sustained slow samples exceed threshold")
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift run FlowType --self-test`
Expected: 编译失败（`cannot find 'updateLatencyEWMA' in scope`）。

- [ ] **Step 3: 实现 `ASRRouter.swift`**

```swift
import Foundation
import Network
import os

/// 健康画像快照（可测的纯数据部分）。
struct RouterHealthSnapshot: Sendable, Equatable {
    var cloudLatencyEWMA: Double = 0
    var cloudConsecutiveFailures: Int = 0
    var networkReachable: Bool = true
}

/// 指数移动平均：`previous == 0` 表示未知，直接采用首个样本。
func updateLatencyEWMA(previous: Double, sample: Double, alpha: Double = 0.3) -> Double {
    previous == 0 ? sample : previous * (1 - alpha) + sample * alpha
}

/// 无感择优：维护 provider 健康画像 + 网络可达性，输出有序候选 provider 链。
final class ASRRouter: @unchecked Sendable {
    static let shared = ASRRouter()

    private let health = OSAllocatedUnfairLock(initialState: RouterHealthSnapshot())
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "flowtype.asr-router.path")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.health.withLock { $0.networkReachable = (path.status == .satisfied) }
        }
        monitor.start(queue: monitorQueue)
    }

    func snapshot() -> RouterHealthSnapshot { health.withLock { $0 } }

    func recordSuccess(providerID: String, latencyMs: Int) {
        guard providerID == "cloud-asr" else { return }
        health.withLock {
            $0.cloudLatencyEWMA = updateLatencyEWMA(previous: $0.cloudLatencyEWMA, sample: Double(latencyMs))
            $0.cloudConsecutiveFailures = 0
        }
        AppLogger.log("[ASRRouter] cloud EWMA=\(Int(health.withLock { $0.cloudLatencyEWMA }))ms")
    }

    func recordFailure(providerID: String) {
        guard providerID == "cloud-asr" else { return }
        let n = health.withLock { s -> Int in s.cloudConsecutiveFailures += 1; return s.cloudConsecutiveFailures }
        AppLogger.log("[ASRRouter] cloud failure streak=\(n)")
    }

    /// 收集可用性与健康画像，交给纯函数决策，映射为有序 provider 实例。
    func selectChain() async -> [ASRProvider] {
        let cfg = await MainActor.run { ConfigurationStore.shared.current }
        let qwen = ASRProviderRegistry.shared.qwenLocalProvider
        let cloud = ASRProviderRegistry.shared.cloudProvider
        let localAvailable = qwen.isLoaded
        let cloudAvailable = await cloud.isAvailable
        let snap = snapshot()

        let inputs = ASRRoutingInputs(
            policy: cfg.asrRoutingPolicy,
            localAvailable: localAvailable,
            cloudAvailable: cloudAvailable,
            networkReachable: snap.networkReachable,
            cloudLatencyEWMA: snap.cloudLatencyEWMA,
            cloudConsecutiveFailures: snap.cloudConsecutiveFailures
        )
        return selectASRChain(inputs).compactMap { ASRProviderRegistry.shared.provider(forID: $0) }
    }
}
```

**接入 `ASRStage`**：删除 A2 里加的临时 `candidateChain()` 私有方法，把调用点改为：

```swift
        let chain = await ASRRouter.shared.selectChain()
```

并在成功分支回写健康画像：

```swift
                    await ASRRouter.shared.recordSuccess(providerID: result.providerID, latencyMs: result.latencyMs)
```

在失败分支记失败：

```swift
                    await ASRRouter.shared.recordFailure(providerID: provider.id)
```

- [ ] **Step 4: 构建 + 自测**

Run: `swift build && swift run FlowType --self-test`
Expected: 全绿。

- [ ] **Step 5: 手动验证无感降级（记录在诊断报告）**

1. 配置云端（SiliconFlow + 模型 + Key）与本地模型，策略设为「自动」→ 拔网线/关 Wi-Fi → 录音一次：应立即使用本地、无错误弹窗、历史 `sttBackend == "qwen"`。
2. 恢复网络 → 再录一次：`sttBackend == "cloud"`。
Expected: 断网轮次无用户可感知等待；正常轮次走云端。

- [ ] **Step 6: 提交**

```bash
git add Sources/flowtype/Services/Speech/ASRRouter.swift Sources/flowtype/Testing/SelfTest.swift
git commit -m "feat(asr): add ASRRouter with health EWMA and network reachability"
```

---

### Task B1: `ContextProvider` 协议与上下文组装

**Files:**
- Create: `Sources/flowtype/Services/Context/ContextProvider.swift`
- Test: `Sources/flowtype/Testing/SelfTest.swift`

**Interfaces:**
- Consumes: `ASRContext`（A1）
- Produces:
  - `struct ForegroundContext: Sendable, Equatable { appName: String?; elementText: String?; url: String?; selectedText: String? }`
  - `protocol ContextProvider: Sendable { func collect() async -> ForegroundContext? }`
  - `func buildContextText(_ ctx: ForegroundContext?, maxChars: Int = 1200) -> String?`（纯）
  - `func redactContextSecrets(_ text: String) -> String`（纯）

- [ ] **Step 1: 写失败的测试**

`runAndExit()` 中 `testRouterEWMA(r)` 之后插入：

```swift
        testContextAssembly(r)     // ForegroundContext → bounded context text + redaction
```

追加：

```swift
    // MARK: - Foreground context assembly (pure)

    static func testContextAssembly(_ r: Reporter) {
        r.check(buildContextText(nil) == nil, "ctx-asm: nil → nil")
        r.check(buildContextText(ForegroundContext(appName: nil, elementText: nil, url: nil, selectedText: nil)) == nil,
                "ctx-asm: all-nil → nil")
        r.eq(buildContextText(ForegroundContext(appName: "Xcode", elementText: "func main()", url: nil, selectedText: nil)),
             "func main()", "ctx-asm: elementText is primary signal")
        r.eq(buildContextText(ForegroundContext(appName: "Terminal", elementText: nil, url: nil, selectedText: "git log")),
             "git log", "ctx-asm: selectedText included when no elementText")
        r.eq(buildContextText(ForegroundContext(appName: "Safari", elementText: nil, url: "https://docs.swift.org", selectedText: nil)),
             "https://docs.swift.org", "ctx-asm: url included when nothing else")
        let both = buildContextText(ForegroundContext(appName: "X", elementText: "code", url: "https://x", selectedText: "sel"))
        r.eq(both, "code\nsel\nhttps://x", "ctx-asm: elementText > selectedText > url order")
        let long = ForegroundContext(appName: nil, elementText: String(repeating: "z", count: 5000), url: nil, selectedText: nil)
        r.eq((buildContextText(long) ?? "").count, 1200, "ctx-asm: bounded to 1200 chars")
        // 密钥脱敏：上下文里不得出现 Bearer / sk- / sf- 形态的串
        r.check(!redactContextSecrets("Authorization: Bearer sk-abcdefghij123456").contains("sk-abcdefghij123456"),
                "ctx-asm: sk- token redacted")
        r.check(!redactContextSecrets("key=sf-abcdefghij123456").contains("sf-abcdefghij123456"),
                "ctx-asm: sf- token redacted")
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift run FlowType --self-test`
Expected: 编译失败（`cannot find type 'ForegroundContext'`）。

- [ ] **Step 3: 实现 `ContextProvider.swift`**

```swift
import Foundation

/// 前台上下文的一次采集结果。逐项可为 nil（采集失败或不可用不阻断录音）。
struct ForegroundContext: Sendable, Equatable {
    let appName: String?
    let elementText: String?
    let url: String?
    let selectedText: String?
}

/// 平台能力：采集前台上下文。macOS 实现见 `AXContextProvider`。
protocol ContextProvider: Sendable {
    func collect() async -> ForegroundContext?
}

/// 把采集结果压成一段有界上下文文本（先脱敏，再截断）。
/// 优先级：焦点元素文本 > 选中文本 > 网页 URL。
func buildContextText(_ ctx: ForegroundContext?, maxChars: Int = 1200) -> String? {
    guard let ctx else { return nil }
    var parts: [String] = []
    if let t = ctx.elementText?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { parts.append(t) }
    if let s = ctx.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { parts.append(s) }
    if let u = ctx.url?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty { parts.append(u) }
    guard !parts.isEmpty else { return nil }
    let joined = parts.joined(separator: "\n")
    return String(redactContextSecrets(joined).prefix(maxChars))
}

/// 去除上下文里可能出现的凭据形态，避免随云端请求外泄。
func redactContextSecrets(_ text: String) -> String {
    var out = text
    for pattern in [#"sk-[A-Za-z0-9_-]{8,}"#, #"sf-[A-Za-z0-9_-]{8,}"#, #"Bearer\s+[A-Za-z0-9._-]{8,}"#] {
        if let re = try? NSRegularExpression(pattern: pattern) {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                              withTemplate: "[REDACTED]")
        }
    }
    return out
}
```

- [ ] **Step 4: 构建 + 自测**

Run: `swift build && swift run FlowType --self-test`
Expected: 全绿。

- [ ] **Step 5: 提交**

```bash
git add Sources/flowtype/Services/Context/ContextProvider.swift Sources/flowtype/Testing/SelfTest.swift
git commit -m "feat(context): add ContextProvider protocol and bounded context assembly"
```

---

### Task B2: `AXContextProvider` 与辅助功能权限

**Files:**
- Create: `Sources/flowtype/Services/Context/AXContextProvider.swift`
- Modify: `Sources/flowtype/Core/Pipeline/Stages/RecordingStage.swift`（会话开始时采集一次，写入 context）
- Test: 手动矩阵（AX 依赖真实前台应用，无法在纯逻辑自测中覆盖）

**Interfaces:**
- Consumes: `ContextProvider` / `ForegroundContext` / `buildContextText`（B1）
- Produces: `final class AXContextProvider: ContextProvider { func collect() async -> ForegroundContext? }`

- [ ] **Step 1: 实现 `AXContextProvider`**

```swift
import Foundation
import Cocoa
import ApplicationServices

/// 用 macOS Accessibility API 采集前台 app / 焦点元素 / 选中文本 / 网页 URL。
/// 任一步失败都静默返回已采集到的部分；无辅助功能权限时返回 nil（不阻断录音）。
final class AXContextProvider: ContextProvider, @unchecked Sendable {

    func collect() async -> ForegroundContext? {
        guard AXIsProcessTrusted() else {
            AppLogger.log("[AXContext] Accessibility permission not granted — skipping context")
            return nil
        }
        let appName = await MainActor.run { NSWorkspace.shared.frontmostApplication?.localizedName }
        let system = AXUIElementCreateSystemWide()

        let focusedApp = elementAttribute(system, kAXFocusedApplicationAttribute as CFString)
        let focusedElement = focusedApp.flatMap { elementAttribute($0, kAXFocusedUIElementAttribute as CFString) }

        var elementText: String? = focusedElement.flatMap { collectElementText($0) }
        let selectedText = focusedElement.flatMap { stringAttribute($0, kAXSelectedTextAttribute as CFString) }
        let url = focusedApp.flatMap { stringAttribute($0, kAXDocumentAttribute as CFString) }

        // 只在没有更精确信号时才用 URL（避免把无关页面 URL 当上下文）。
        if elementText == nil && selectedText == nil { elementText = url }

        if elementText == nil && selectedText == nil && url == nil && appName == nil { return nil }
        return ForegroundContext(appName: appName, elementText: elementText,
                                 url: url, selectedText: selectedText)
    }

    // MARK: - AX helpers

    private func elementAttribute(_ element: AXUIElement, _ attr: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private func stringAttribute(_ element: AXUIElement, _ attr: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &value) == .success,
              let s = value as? String, !s.isEmpty else { return nil }
        return s
    }

    /// 焦点元素自身文本，其次回退到其父级（多数编辑器把文本放在嵌套的 AXTextArea 上）。
    private func collectElementText(_ element: AXUIElement) -> String? {
        if let v = stringAttribute(element, kAXValueAttribute as CFString) { return v }
        if let v = stringAttribute(element, kAXTitleAttribute as CFString) { return v }
        var parent: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
           let p = parent, CFGetTypeID(p) == AXUIElementGetTypeID() {
            return stringAttribute((p as! AXUIElement), kAXValueAttribute as CFString)
        }
        return nil
    }
}
```

- [ ] **Step 2: 接到 `RecordingStage`（会话开始时采集一次）**

在 `RecordingStage.swift` 顶部（`private let appleSpeechProvider = AppleSpeechProvider()` 之后）新增：

```swift
    private let contextProvider: ContextProvider = AXContextProvider()
```

在 `RecordingStage.swift:56`（`let output = try await audioRecorder.startRecording(deviceID: deviceID)`）之后插入：

```swift
            // 采集一次前台上下文（失败则静默跳过，不阻断录音）。
            if await MainActor.run(body: { ConfigurationStore.shared.current.asrRoutingPolicy != .localOnly })
                || true {   // 本地优先时同样采集：本地 Qwen 直接用，不上传
                if let fg = await contextProvider.collect(),
                   let text = buildContextText(fg) {
                    await MainActor.run { context.foregroundContextText = text }
                    AppLogger.log("[RecordingStage#\(sessionID)] Foreground context: \(text.count) chars")
                }
            }
```

> 上面 `|| true` 仅为表达「两种策略都采集」；实现时直接写成无条件 `if let fg = await contextProvider.collect(), let text = buildContextText(fg) { ... }`，删除该占位判断。

- [ ] **Step 3: 构建 + 自测**

Run: `swift build && swift run FlowType --self-test`
Expected: 全绿（AX 逻辑不进纯逻辑自测）。

- [ ] **Step 4: 手动验证（记录在诊断报告）**

1. 授予辅助功能权限 → 在 Xcode 编辑器里录音 → 日志应出现 `Foreground context: N chars`。
2. 撤销辅助功能权限 → 录音仍成功，日志出现 `Accessibility permission not granted — skipping context`。
Expected: 无权限不阻断录音；有权限时上下文进入 `ASRContext`。

- [ ] **Step 5: 提交**

```bash
git add Sources/flowtype/Services/Context/AXContextProvider.swift \
        Sources/flowtype/Core/Pipeline/Stages/RecordingStage.swift
git commit -m "feat(context): collect foreground context via Accessibility API"
```

---

### Task B3: 端到端指标（列 + 埋点 + P50/P95）

**Files:**
- Create: `Sources/flowtype/Core/SessionMetrics.swift`
- Modify: `Sources/flowtype/Core/DictationHistory.swift:24-62`
- Modify: `Sources/flowtype/Core/Database/Records.swift:4-48`
- Modify: `Sources/flowtype/Core/Database/AppDatabase.swift:66-84`
- Modify: `Sources/flowtype/Core/Pipeline/Stages/PolishStage.swift:19,56-73`、`Stages/InjectionStage.swift:14,63`
- Modify: `Sources/flowtype/Core/PipelineOrchestrator.swift:447-475`
- Modify: `Sources/flowtype/Settings/SettingsPage+ASR.swift`（指标复制按钮）
- Test: `Sources/flowtype/Testing/SelfTest.swift`

**Interfaces:**
- Consumes: `context.usedProviderID` / `asrMs` / `polishMs` / `injectMs` / `stopRecordingAt`（A2）
- Produces:
  - `func percentile(_ values: [Int], _ p: Double) -> Int?`（纯）
  - `enum SessionMetrics { static func report(_ sessions: [DictationSession]) -> String }`
  - `DictationSession` 新字段：`asrProviderID: String?`, `usedFallback: Bool`, `fallbackReason: String?`, `asrMs: Int?`, `polishMs: Int?`, `injectMs: Int?`, `stopToInjectMs: Int?`
  - `SessionRecord` 对应列 + GRDB 迁移 `v4_metrics`

- [ ] **Step 1: 写失败的测试**

`runAndExit()` 中 `testContextAssembly(r)` 之后插入：

```swift
        testSessionMetrics(r)      // percentile + metrics report
        testMetricsSchema(r)       // v4 metrics columns persist
```

追加：

```swift
    // MARK: - Session metrics: percentile + report

    static func testSessionMetrics(_ r: Reporter) {
        r.check(percentile([], 0.5) == nil, "metrics: empty → nil")
        r.eq(percentile([100], 0.5), 100, "metrics: single value")
        r.eq(percentile([10, 20, 30, 40, 50], 0.5), 30, "metrics: p50 of odd set")
        r.eq(percentile([10, 20, 30, 40], 0.5), 30, "metrics: p50 nearest-rank of even set")
        r.eq(percentile([10, 20, 30, 40], 0.95), 40, "metrics: p95 clamps to max")
        r.eq(percentile([10, 20, 30, 40], 0.0), 10, "metrics: p0 → min")

        var s = DictationSession(rawTranscript: "a", finalText: "a", polishMode: .raw,
                                 durationMs: 2000, recordingMs: 1000, appName: nil,
                                 appBundleID: nil, language: "zh", sttBackend: "cloud")
        s.stopToInjectMs = 1500
        s.asrProviderID = "cloud-asr"
        s.usedFallback = false
        let txt = SessionMetrics.report([s])
        r.check(txt.contains("p50"), "metrics: report contains p50")
        r.check(txt.contains("1500"), "metrics: report contains the sample value")
    }

    static func testMetricsSchema(_ r: Reporter) {
        guard let db = try? AppDatabase.inMemory() else { r.check(false, "metrics-db"); return }
        var s = DictationSession(rawTranscript: "hi", finalText: "hi", polishMode: .raw,
                                 durationMs: 2000, recordingMs: 1000, appName: "A",
                                 appBundleID: nil, language: "en", sttBackend: "cloud")
        s.stopToInjectMs = 1420
        s.asrProviderID = "cloud-asr"
        s.usedFallback = true
        s.fallbackReason = "network"
        s.asrMs = 900
        var rec = SessionRecord(from: s)
        try? db.dbQueue.write { try rec.insert($0) }
        let back = (try? db.dbQueue.read { try SessionRecord.fetchAll($0) })?.first
        r.eq(back?.stopToInjectMs, 1420, "metrics: stopToInjectMs persisted")
        r.eq(back?.usedFallback, true, "metrics: usedFallback persisted")
        r.eq(back?.fallbackReason, "network", "metrics: fallbackReason persisted")
        r.eq(back?.asrProviderID, "cloud-asr", "metrics: asrProviderID persisted")
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift run FlowType --self-test`
Expected: 编译失败（`cannot find 'percentile'`）。

- [ ] **Step 3: 实现 `SessionMetrics.swift`**

```swift
import Foundation

/// 最近样本的 p 分位数（nearest-rank），空数组返回 nil。
func percentile(_ values: [Int], _ p: Double) -> Int? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let clamped = min(max(p, 0.0), 1.0)
    let rank = Int((Double(sorted.count) * clamped).rounded(.up)) - 1
    return sorted[min(max(rank, 0), sorted.count - 1)]
}

enum SessionMetrics {
    /// 纯函数：把会话指标渲染成可复制的文本报告（不含转写内容）。
    static func report(_ sessions: [DictationSession]) -> String {
        let stopToInject = sessions.compactMap(\.stopToInjectMs)
        let asr = sessions.compactMap(\.asrMs)
        let fallbacks = sessions.filter(\.usedFallback).count
        let cloud = sessions.filter { $0.asrProviderID == "cloud-asr" }.count

        func line(_ label: String, _ values: [Int]) -> String {
            guard let p50 = percentile(values, 0.5), let p95 = percentile(values, 0.95) else {
                return "\(label): n=0"
            }
            return "\(label): n=\(values.count) p50=\(p50)ms p95=\(p95)ms"
        }

        return [
            "=== Flowtype ASR metrics ===",
            line("stop→inject", stopToInject),
            line("asr", asr),
            "sessions: \(sessions.count), cloud: \(cloud), fallback: \(fallbacks)",
        ].joined(separator: "\n")
    }
}
```

- [ ] **Step 4: 扩展 `DictationSession`**

`DictationHistory.swift` 的 `struct DictationSession` 增加存储属性（放在 `sttBackend` 之后）：

```swift
    // MARK: - Metrics (no content)
    var asrProviderID: String?
    var usedFallback: Bool = false
    var fallbackReason: String?
    var asrMs: Int?
    var polishMs: Int?
    var injectMs: Int?
    var stopToInjectMs: Int?
```

两个 `init` 的末尾各加一行（保持默认值即可，无需新参数）：

```swift
        self.usedFallback = false
```

> 因为新增属性全部有默认值，现有的两个 memberwise `init` 与 JSON legacy 解码都无需改动（`var` + 默认值 = 解码时缺失即用默认）。

- [ ] **Step 5: 扩展 `SessionRecord` + 迁移**

`Records.swift` 的 `struct SessionRecord` 增加：

```swift
    var asrProviderID: String?
    var usedFallback: Bool
    var fallbackReason: String?
    var asrMs: Int64
    var polishMs: Int64
    var injectMs: Int64
    var stopToInjectMs: Int64
```

在 `init(from s: DictationSession)` 末尾追加：

```swift
        self.asrProviderID = s.asrProviderID
        self.usedFallback = s.usedFallback
        self.fallbackReason = s.fallbackReason
        self.asrMs = Int64(s.asrMs ?? 0)
        self.polishMs = Int64(s.polishMs ?? 0)
        self.injectMs = Int64(s.injectMs ?? 0)
        self.stopToInjectMs = Int64(s.stopToInjectMs ?? 0)
```

在 `toDictationSession()` 的构造参数后补：

```swift
        session.asrProviderID = asrProviderID
        session.usedFallback = usedFallback
        session.fallbackReason = fallbackReason
        session.asrMs = asrMs > 0 ? Int(asrMs) : nil
        session.polishMs = polishMs > 0 ? Int(polishMs) : nil
        session.injectMs = injectMs > 0 ? Int(injectMs) : nil
        session.stopToInjectMs = stopToInjectMs > 0 ? Int(stopToInjectMs) : nil
        return session
```

（把原 `return DictationSession(...)` 改为 `var session = DictationSession(...)`。）

`AppDatabase.swift` 的 `migrator` 中，在 `v3_charcount_trim_fix` 之后追加：

```swift
        // v4: per-session ASR metrics (content-free) for latency/fallback observability.
        m.registerMigration("v4_metrics") { db in
            try db.alter(table: "session") { t in
                t.add(column: "asrProviderID", .text)
                t.add(column: "usedFallback", .boolean).notNull().defaults(to: false)
                t.add(column: "fallbackReason", .text)
                t.add(column: "asrMs", .integer).notNull().defaults(to: 0)
                t.add(column: "polishMs", .integer).notNull().defaults(to: 0)
                t.add(column: "injectMs", .integer).notNull().defaults(to: 0)
                t.add(column: "stopToInjectMs", .integer).notNull().defaults(to: 0)
            }
        }
```

- [ ] **Step 6: 埋点（polish / inject 耗时）**

`PolishStage.swift`：在 `execute` 的 `let startTime = Date()`（:22）之后不动；在成功分支（`if !accumulated.isEmpty && accumulated != text {` 之前）插入：

```swift
            await MainActor.run { context.polishMs = Int(Date().timeIntervalSince(startTime) * 1000) }
```

`InjectionStage.swift`：在 `let startTime = Date()`（:16）之后不动；在 `.inject` 成功分支 `AppLogger.log("[InjectionStage#...] Injected in ...")` 之前插入：

```swift
                await MainActor.run { context.injectMs = Int(Date().timeIntervalSince(startTime) * 1000) }
```

- [ ] **Step 7: 在 `saveHistory` 组装指标**

`PipelineOrchestrator.swift:447-475` 的 `saveHistory` 中，`let session = DictationSession(...)` 改为：

```swift
        var session = DictationSession(
            rawTranscript: context.rawTranscript,
            finalText: context.finalText,
            polishMode: mode,
            durationMs: durationMs,
            recordingMs: context.recordingMs,
            appName: context.targetApp?.localizedName,
            appBundleID: context.targetApp?.bundleIdentifier,
            language: detectLanguageTag(context.finalText),
            sttBackend: sttBackend
        )
        session.asrProviderID = context.usedProviderID
        session.asrMs = context.asrMs
        session.polishMs = context.polishMs
        session.injectMs = context.injectMs
        if let stopAt = context.stopRecordingAt {
            session.stopToInjectMs = Int(Date().timeIntervalSince(stopAt) * 1000)
        }
```

（`usedFallback` / `fallbackReason` 暂留默认 —— 降级原因在 Task A4 已记录到日志与 router 快照；把「本轮有几次 provider 失败」透传进 context 留待后续，本任务只保证列与写入路径可用。）

- [ ] **Step 8: 指标报告入口（设置页）**

在 `SettingsPage+ASR.swift` 的 ASR 段落「麦克风设备」之后追加：

```swift
            HStack {
                Text("性能指标")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Button("复制指标报告") {
                    let report = SessionMetrics.report(HistoryStore.shared.sessions)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
```

- [ ] **Step 9: 构建 + 自测**

Run: `swift build && swift run FlowType --self-test`
Expected: 全绿（含 `testMetricsSchema`）。

- [ ] **Step 10: 提交**

```bash
git add Sources/flowtype/Core/SessionMetrics.swift Sources/flowtype/Core/DictationHistory.swift \
        Sources/flowtype/Core/Database Sources/flowtype/Core/Pipeline \
        Sources/flowtype/Core/PipelineOrchestrator.swift Sources/flowtype/Settings/SettingsPage+ASR.swift \
        Sources/flowtype/Testing/SelfTest.swift
git commit -m "feat(metrics): persist content-free ASR latency metrics with p50/p95 report"
```

---

### Task B4: 「快」的链路优化（暖机 + 关键路径 + 注入复核）

**Files:**
- Modify: `Sources/flowtype/Core/PipelineOrchestrator.swift`（启动暖机）
- Modify: `Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift:48`（等待复核）
- Test: 手动延迟矩阵

**Interfaces:**
- Consumes: `QwenModelState.shared.loadModel(provider:)`（现状）
- Produces: 无新公开接口

- [ ] **Step 1: 启动时暖机本地模型**

在 `SessionController` 的 `init` 末尾（`self.observers = observers` 之后）追加：

```swift
        // 本地模型常驻暖机：避免每轮首字都付冷加载代价。
        Task { @MainActor in
            let cfg = ConfigurationStore.shared.current
            guard cfg.asrRoutingPolicy != .cloudOnly else { return }
            _ = try? await ConfigurationStore.shared.current   // keep MainActor isolation explicit
            await QwenModelState.shared.loadModel(provider: asrRegistry.qwenLocalProvider)
        }
```

> 实现时删除上面那行无意义的 `_ = try? await ...`，只保留 `await QwenModelState.shared.loadModel(provider:)` 调用。

- [ ] **Step 2: 复核注入前的固定等待**

把 `InjectionStage.swift:48` 的

```swift
        try? await Task.sleep(nanoseconds: 100_000_000) // let focus settle after the end-tap
```

改为：

```swift
        // 让焦点在结束触发键之后稳定下来 —— 这个等待直接计入 stop→inject 延迟。
        // 缩短到 50ms 后按指标 P95 观测再决定是否继续压缩。
        try? await Task.sleep(nanoseconds: 50_000_000)
```

- [ ] **Step 3: 构建 + 自测**

Run: `swift build && swift run FlowType --self-test`
Expected: 全绿。

- [ ] **Step 4: 手动延迟矩阵（记录在诊断报告）**

条件：本地模型已加载，策略「自动」，录制 3–10s 短句 ×10 次。
记录（用设置页「复制指标报告」）：
- 冷启动第一轮 `stop→inject`（预期明显更高）
- 暖机后 `stop→inject` P50 / P95
Expected: 暖机后 P50 显著低于冷启动；把数值填入诊断报告作为基线。

- [ ] **Step 5: 提交**

```bash
git add Sources/flowtype/Core/PipelineOrchestrator.swift Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift
git commit -m "perf(asr): keep local model warm and trim injection settle delay"
```

---

### Task B5: 云端上下文开关与「录音中去预览上屏」

**Files:**
- Modify: `Sources/flowtype/Settings/SettingsPage+ASR.swift`（隐私开关）
- Modify: `Sources/flowtype/Core/Pipeline/Stages/RecordingStage.swift:72-80`（不再上屏，仅兜底）
- Modify: `Sources/flowtype/Core/PipelineOrchestrator.swift:143-147,172-175`（移除 UI 预览订阅）
- Test: `Sources/flowtype/Testing/SelfTest.swift`

**Interfaces:**
- Consumes: `Configuration.cloudASRSendContext`（A3）
- Produces: 无新公开接口

- [ ] **Step 1: 写失败的测试**

`runAndExit()` 中 `testMetricsSchema(r)` 之后插入：

```swift
        testCloudContextToggle(r)  // cloud context opt-out default + round-trip
```

追加：

```swift
    // MARK: - Cloud context opt-out

    static func testCloudContextToggle(_ r: Reporter) {
        r.check(Configuration().cloudASRSendContext, "ctx-toggle: default is true (cloud carries context)")
        var c = Configuration(); c.cloudASRSendContext = false
        let back = try? JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(c))
        r.check(back?.cloudASRSendContext == false, "ctx-toggle: false round-trips")
    }
```

- [ ] **Step 2: 运行测试确认失败（若 A3 未实现则会失败）**

Run: `swift run FlowType --self-test`
Expected: 若 A3 已完成则**直接通过**（该字段已在 A3 引入）——此时保留测试作为回归守卫继续下一步。

- [ ] **Step 3: 设置页增加隐私开关**

接在 Task B3 加入的「性能指标」行之后：

```swift
            HStack {
                Text("云端发送上下文")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Toggle("", isOn: $store.current.cloudASRSendContext)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(store.current.asrRoutingPolicy == .localOnly)
            }
            Text("开启后，云端识别会携带前台上下文以提升技术词命中率；音频与上下文仅在走云端路径时离开设备。")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
```

- [ ] **Step 4: 录音中不再上屏预览文字（保留内部兜底）**

`RecordingStage.swift:72-80` 的 `previewTask` 改为只更新内部状态、不推送 UI 流：

```swift
            // AppleSpeech 预览仅作内部兜底文本：不再上屏（产品判断：不做中间文本展示）。
            previewTask = Task { [weak self] in
                guard self != nil else { return }
                for await text in previewStream {
                    await MainActor.run { context.currentPreviewText = text }
                }
            }
```

`PipelineOrchestrator.swift:138-147`：删除 `previewCancellable` 的订阅块，并把 `:143-147` 替换为：

```swift
        // 录音中不再向 UI 推送预览文字（预览仅作 ASR 失败时的内部兜底）。
```

删除 `previewCancellable` 属性声明（`:64`）与 `startRecording` 里的 `previewText = ""`（`:121`）、`@Published private(set) var previewText`（`:34`）以及 `endRecording` 里 `:172-175` 的 flush 日志块。

> 若仍有 UI 读取 `SessionController.previewText`（`CapsuleView` 等），一并删除对应引用。先运行 `swift build`，编译器会列出全部引用点。

- [ ] **Step 5: 构建 + 自测**

Run: `swift build && swift run FlowType --self-test`
Expected: 全绿。

- [ ] **Step 6: 手动验证**

1. 录音中胶囊/悬浮窗只显示波形 + 计时（无文字）。
2. 关闭「云端发送上下文」→ 走云端的一轮，抓取请求体确认**无** `prompt` 字段。
Expected: 两项均符合。

- [ ] **Step 7: 提交**

```bash
git add Sources/flowtype/Settings/SettingsPage+ASR.swift \
        Sources/flowtype/Core/Pipeline/Stages/RecordingStage.swift \
        Sources/flowtype/Core/PipelineOrchestrator.swift Sources/flowtype/Testing/SelfTest.swift
git commit -m "feat(asr): cloud context opt-out toggle; stop showing interim preview text"
```

---

## 收尾验收（全部任务完成后）

- [ ] `swift build` 成功。
- [ ] `swift run FlowType --self-test` 退出码 0。
- [ ] `grep -rn "as? QwenASRProvider\|is CloudASRProvider" Sources/flowtype` 无结果（`SelfTest.swift` 断言除外）。
- [ ] 手动矩阵全过：云端就绪+网络正常→走云端；强制断网→无感切本地且无弹错；仅本地/仅云端各自可用；云端 Key 失效→auto 下切本地；辅助功能权限缺失→采集跳过但识别正常。
- [ ] 断网 + 本地：完整可用（音频不出设备）。
- [ ] 录音中不再上屏识别文字。
- [ ] 设置页「复制指标报告」可导出 `stop→inject` P50/P95。

## Self-Review 记录

- **Spec coverage**：A1(§3.1/§3.2) → Task A1；A2(§3.2/§3.5) → Task A2；策略与隐私默认(§3.3/§1.1) → Task A3；路由与探测(§3.3) → Task A4；上下文(§3.4) → Task B1/B2；指标(§3.6) → Task B3；快(§3.7) → Task B4；UI(§3.8) → Task A3/B3/B5；配置迁移(§3.2) → Task A3。
- **Placeholder 扫描**：已消除；两处刻意标注的占位实现（B2 Step 2 的 `|| true`、B4 Step 1 的 `_ = try? await`）均写明实现时应删除的最终形态。
- **类型一致性**：`ASRRequest.samples` / `ASRResult.providerID` / `context.usedProviderID` / `sttBackend` 标签在 A1→A2→A3→B3 之间名称一致；`ASRRoutingPolicy` 三态在 Configuration、Settings、SelfTest 中一致。
- **已知缺口**：`usedFallback` / `fallbackReason` 的自动填充（"本轮是否降级"）在本计划中只落列与写入路径，未做跨阶段透传——留待方向 C 之后按需补齐；此缺口已在 Task B3 Step 7 显式标注。
