# Flowtype 统一 ASR 能力层与「又快又准」设计

日期：2026-10-13
范围：方向 A（统一 ASR 能力层 + 无感路由）+ 方向 B（又快又准）
后续：方向 C（前端交互框架）另行设计，本设计仅预留接口，不实现。

## 1. 目标与背景

### 1.1 产品目标（护城河）

用户配置好云端 ASR 与本地 ASR 后，**系统自动择优、无感切换**，用户无需知道当前用的是哪一个：

- 默认优先云端 ASR；当网络变差、明显增加识别延迟时，**无感切换到本地**兜底。
- 本地路径保证：断网可用、音频不出设备。
- 云端与本地互为「能力上限补充」：本地缺失或不佳时云端补足，云端不可达或缓慢时本地兜底。

对标 typeless 的结论：它的「快」来自链路工程（原生热键、低码率分片、长连接半流式、final 即注入），「准」来自前台上下文 + 服务端精修 + 用户词典；且它**不做流式 ASR、不做中间文本上屏**。本设计沿用这一判断。

### 1.2 现状问题

1. **Provider 能力没有进协议**：[ASRProvider.swift](../../../Sources/flowtype/Services/Speech/ASRProvider.swift) 只有 `transcribe(audioData:timeout:)`，无法表达「是否支持语言/热词上下文/是否联网/隐私位置」。
2. **靠 `as?` 特判分支能力**：
   - [ASRStage.swift:58](../../../Sources/flowtype/Core/Pipeline/Stages/ASRStage.swift#L58) `if let qwenProvider = provider as? QwenASRProvider`
   - [PipelineOrchestrator.swift:177-185](../../../Sources/flowtype/Core/Pipeline/PipelineOrchestrator.swift#L177-L185) `if let qwen = activeProvider as? QwenASRProvider`
3. **路由是二选一死开关**：[ASRProviderRegistry.swift:16-22](../../../Sources/flowtype/Services/Speech/ASRProviderRegistry.swift#L16-L22) 直接 `switch asrEngine { .local / .cloud }`，无降级、无择优。
4. **无端到端性能指标**：仅日志级计时，无 P50/P95 可观测。
5. **无前台上下文采集**：「准」的第一来源缺失。
6. **录音中实时预览文字上屏**（[PipelineOrchestrator.swift:143-147](../../../Sources/flowtype/Core/Pipeline/PipelineOrchestrator.swift#L143-L147)），与「不做中间文本上屏」的产品判断冲突。

## 2. 非目标（YAGNI）

- 不做流式 ASR，不做增量/中间文本上屏。
- 不做本地+云端竞速（race）作为默认路径。
- 不做独立的 Web/HTTP 后端（那是既有产品设计文档的事），本次只动客户端 ASR 链路。
- 不改注入方式（剪贴板/键入两条路径保持现状）。
- 不实现方向 C 的 UI 框架，仅预留状态字段。

## 3. 架构设计

### 3.1 统一能力描述 `ASRCapabilities`

每个 provider 显式声明自己的能力，取代运行时的 `as?` 判断。

```swift
// Sources/flowtype/Services/Speech/ASRCapabilities.swift
enum ProviderLocation: String, Sendable, Codable {
    case onDevice   // 音频不出设备
    case cloud      // 音频会离开设备
}

struct ASRCapabilities: Sendable {
    let supportsLanguageHint: Bool   // 能否指定识别语言
    let supportsContextHint: Bool    // 能否吃热词 / 前台上下文（Qwen: true；SenseVoice: false）
    let requiresNetwork: Bool        // 云端 true
    let location: ProviderLocation   // 隐私标识，用于 UI 提示与策略过滤
    let maxAudioDuration: TimeInterval?  // nil = 无硬上限
    let estimatedWarmLatencyMs: Int  // 暖机后的经验延迟，供路由与 UI 参考
}
```

说明：
- 不设 `supportsStreaming`：本设计恒为「不做流式」，不需要该维度。
- `estimatedWarmLatencyMs` 是经验初值，运行时由健康画像修正。

### 3.2 统一请求 / 结果

取代 `SpeechProvider.transcribe(audioData:timeout:)`，把「语言」与「上下文」提升为一等参数。

```swift
// Sources/flowtype/Services/Speech/ASRContract.swift
struct ASRContext: Sendable {
    let phrases: [String]      // 用户词典热词（沿用 composeASRContext 的上限约束）
    let foreground: String?    // 前台上下文文本（见 3.4），nil 表示未采集或不可用
}

struct ASRRequest: Sendable {
    let samples: [Float]       // 16k 单声道 Float32（沿用现有字节契约，不变）
    let sampleRate: Int        // 固定 16000
    let language: String?      // BCP-47 / provider 语言码；nil 表示自动
    let context: ASRContext?
    let timeout: TimeInterval  // 由路由层按音频时长计算（沿用 min(120,max(30,dur*3+15)) 规则）
}

struct ASRResult: Sendable {
    let text: String
    let providerID: String
    let latencyMs: Int
}
```

Provider 协议改为：

```swift
protocol ASRProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var capabilities: ASRCapabilities { get }
    var isAvailable: Bool { get async }
    func transcribe(_ request: ASRRequest) async throws -> ASRResult
}
```

实现约定：
- **QwenASRProvider**：`context.phrases` + `context.foreground` 拼进 prompt（沿用 `composeASRContext`，扩展为包含 foreground）。
- **CloudASRProvider**：能力 `supportsContextHint = false` 时忽略 `context`（不报错）；若所选云端模型支持热词字段，则在实现内部按需拼装。`language` 保持现状写法。
- **AppleSpeechProvider 变为「仅预览/兜底」**：它不再是 `ASRProvider` 路由候选，仅保留流式预览能力；其最终文本作为「全部 ASR 候选都失败」时的最后兜底。因此它不实现新的 `ASRProvider` 协议，`ASRProviderRegistry.allProviders` 相应收敛为 `[qwen, cloud]`。
- **`SpeechProvider` 协议移除**，`ASRProvider` 成为唯一 ASR 协议（其唯一调用方是 `ASRStage`）；`SpeechProviderError` 若仍被引用则并入 ASR 错误类型。

**配置迁移（`ASREngineType` → `ASRRoutingPolicy`）**：`asrEngine` 字段被 `asrRoutingPolicy` 取代，向后兼容解码按 `local → localOnly`、`cloud → cloudOnly` 映射（保持老用户既有行为不变），新安装默认 `auto`。

### 3.3 `ASRRouter`：无感择优

取代 `ASRProviderRegistry.activeTranscriptionProvider` 的二选一开关。

```swift
// Sources/flowtype/Services/Speech/ASRRouter.swift
enum ASRRoutingPolicy: String, Codable, CaseIterable {
    case auto        // 默认：健康择优（云端优先，网络差切本地）
    case cloudOnly   // 强制云端
    case localOnly   // 强制本地（隐私最强 / 断网可用）
}

struct ProviderHealth: Sendable {
    var latencyEWMA: Double       // 最近若干次请求的延迟指数移动平均（ms）
    var consecutiveFailures: Int
    var lastSuccessAt: Date?
    var isWarm: Bool              // 本地模型是否已加载常驻
    var networkReachable: Bool    // 到该 provider 主机的可达性
}
```

**路由决策（`policy == .auto`）**，输入 = 配置就绪状态 + 健康画像 + 网络状态，输出 = 有序候选链：

1. 仅一端可用 → 直接返回该端（另一端不可用时不出错，静默降级）。
2. 两端都可用：
   - 网络不可达（`NWPathMonitor` 非 satisfied）→ **本地主选**。
   - 云端健康画像不达标（`latencyEWMA > 云端延迟阈值` 或 `consecutiveFailures >= N`）→ **本地主选**。
   - 其余情况 → **云端主选**（默认优先云端）。
3. 候选链 = `[主选, 备选]`。链首失败/超时 → 自动切下一个，**全程不弹错**（仅在两端都失败时走既有错误路径）。

关键点：**必须"预测"网络差，而不是等云端超时才发现**。因此健康画像由两部分驱动：
- **被动**：每次真实请求后更新 `latencyEWMA` / `consecutiveFailures`。
- **主动**：轻量探测（对云端主机做 TLS 握手计时，无需 API Key），周期性刷新 `networkReachable` 与网络 RTT。探测频率与阈值可调（初值：探测间隔 30s、仅在会话开始前按需刷新；云端延迟阈值初值 3000ms、`consecutiveFailures` 阈值 2）。

`ASRRouter` 同时负责：
- 按音频时长计算 `timeout`。
- 记录本轮「最终 provider / 是否降级 / 降级原因」，供 3.6 指标与 UI 状态使用。

### 3.4 前台上下文采集（新模块）

```swift
// Sources/flowtype/Services/Context/ContextProvider.swift
struct ForegroundContext: Sendable {
    let appName: String?
    let elementText: String?   // 焦点输入元素的上下文文本（有长度上限）
    let url: String?           // 浏览器前台 URL
    let selectedText: String?  // 当前选中文本
}

protocol ContextProvider: Sendable {
    func collect() async -> ForegroundContext?
}
```

- macOS 实现 `AXContextProvider`：用 Accessibility API（`AXUIElement`）读取前台 app / 焦点元素 / 可见文本 / 浏览器 URL / 选中文本。分层，逐项可失败、可关闭。
- 组装规则：把 `ForegroundContext` 压成一段有界文本（沿用 typeless 的截断思路，上限可配，初值 30000 字符上限的本地子集），与词典热词一起构成 `ASRContext`。
- 权限：需要辅助功能（TCC Accessibility），与现有麦克风权限是两套；缺失时静默跳过采集，不阻断录音。

**去向策略（已确认）**：
- 本地 provider：直接喂进 prompt，**音频与上下文都不出设备**。
- 云端 provider：**默认带上上下文**（用户已知情接受），需在设置中提供「云端不发送上下文」开关作为隐私退路。

### 3.5 Pipeline 接线变更

- `PipelineRegistry` 阶段顺序不变：`RecordingStage → ASRStage → PostProcessStage → PolishStage → InjectionStage`。
- **`ASRStage` 重写**为纯编排：组装 `ASRRequest`（含 `ASRContext`）→ `ASRRouter.transcribe` → 收 `ASRResult`。**零 `as?` 特判**。
- **`PipelineOrchestrator.endRecording`**：删除 `as? QwenASRProvider` 分支，改为向 `ASRRouter` 查询当前将使用的 provider 名称（保留 `.processing(provider:)` 状态语义）。
- **`RecordingStage`**：
  - 保留 Apple Speech 作为**内部预览/兜底**（全部 ASR 候选失败时用其文本兜底，沿用现有逻辑）。
  - **移除预览文字上屏**：不再向 UI 主展示发送 `previewTextPublisher`（或降级为非主展示）。录音中主展示仅：波形 + 计时 + 当前 provider 状态。

### 3.6 性能指标（端到端可观测）

每轮会话记录**不含内容**的指标（落库，扩展 `DictationSession`）：

| 字段 | 含义 |
|---|---|
| `asrProviderID` | 最终使用的 provider |
| `usedFallback` | 是否发生降级 |
| `fallbackReason` | `network` / `timeout` / `unavailable` / `error` |
| `networkReachableAtStart` | 会话开始时的网络可达性 |
| `localWarmAtStart` | 本地模型是否已暖机 |
| `asrMs` / `postProcessMs` / `polishMs` / `injectMs` | 各段耗时 |
| `stopToInjectMs` | **停止 → 注入完成**（核心指标） |

指标用于：内测报告（技术词命中率、P50/P95 延迟）、路由阈值调参。

### 3.7 「快」的工程手段（链路优化，不做流式）

1. **本地模型常驻暖机**：避免每轮冷加载（当前 batch 加载是延迟大头）。
2. **关键路径并行化**：录音结束后，ASR 与后处理/提示词准备重叠；润色保持流式（现状已是 stream）。
3. **注入路径复核**：现有结束录音固定 `100ms` 等待（[InjectionStage.swift:48](../../../Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift#L48)）与注入策略。
4. **路由避免空等**：靠 3.3 的主动探测，网络差时**不发起**云端请求。

### 3.8 设置 UI 变更（最小）

- [SettingsPage+ASR.swift](../../../Sources/flowtype/Settings/SettingsPage+ASR.swift) 的「引擎二选一」改为**路由策略选择**：`自动（推荐）/ 仅云端 / 仅本地`。
- 展示当前健康状态（云端可达、本地暖机）与「本轮实际使用」指示。
- 新增「云端不发送上下文」隐私开关（默认关闭 = 发送上下文）。

## 4. 数据流

```
SessionController.startRecording
  -> RecordingStage: 采集 PCM（+ Apple 预览，不上屏）
  -> ASRStage:
       ContextProvider.collect() -> ASRContext（热词 + 前台上下文）
       ASRRouter.select() -> 候选链 [primary, fallback]
       for provider in chain:
           build ASRRequest -> provider.transcribe -> ASRResult
           (失败/超时 -> 记录 fallbackReason，继续下一个)
  -> PostProcessStage -> PolishStage -> InjectionStage
  -> 记录指标
```

## 5. 错误处理

- **单端不可用**：静默使用另一端，不弹错。
- **云端网络差**：在 `ASRRouter` 层面**预测**并走本地，不产生用户可感知的等待。
- **两端都失败/都不可用**：沿用现有路径——`.notice`（未配置/未加载，紫色自消失）或 `.error`（可重试）。
- **上下文采集失败/无权限**：静默跳过，`ASRContext.foreground = nil`，不影响识别。
- **降级不改变隐私边界原则**：`localOnly` 下绝不发起云端请求；`auto` 下降级到本地是更隐私的方向，安全。

## 6. 测试策略

- **Self-test（`swift run FlowType --self-test`）**：
  - `ASRRouter` 决策表：各种（配置就绪 × 网络状态 × 健康画像 × 策略）组合 → 期望候选链。
  - `ASRContext` 组装与截断边界。
  - 指标聚合（P50/P95 计算）。
- **手动矩阵**：
  - 云端就绪 + 网络正常 → 默认走云端。
  - 云端就绪 + 强制断网 → 无感切本地，无错误弹窗。
  - 仅本地 / 仅云端配置 → 各自可用。
  - 云端 Key 失效 → 切本地（auto 模式）。
  - 辅助功能权限缺失 → 采集跳过，识别仍工作。
  - 断网 + 本地 → 完整可用（音频不出设备）。

## 7. 验收标准

- `swift build` 与 `swift run FlowType --self-test` 全部通过。
- 删除 `ASRStage` 与 `PipelineOrchestrator` 中所有 `as? QwenASRProvider` 特判。
- `auto` 策略下：云端就绪且网络正常时走云端；网络差时**无感**走本地且无错误提示。
- 断网时使用本地完整可用。
- 录音中不再上屏实时识别文字（保留内部兜底）。
- 每轮会话写入 `stopToInjectMs` 等指标，可导出 P50/P95。

## 8. 分阶段实施（供 writing-plans 细化）

1. **A-1 契约层**：新增 `ASRCapabilities` / `ASRContract`，改造 `ASRProvider` 协议与三个 provider 实现。
2. **A-2 路由层**：`ASRRouter` + 健康画像 + 网络探测 + 决策表 self-test。
3. **A-3 Pipeline 接线**：重写 `ASRStage`、清理 `PipelineOrchestrator` 的 `as?`、`ASRProviderRegistry` 收敛为 provider 容器。
4. **B-1 上下文采集**：`ContextProvider` 协议 + `AXContextProvider` + `ASRContext` 组装 + 权限处理。
5. **B-2 指标**：扩展 `DictationSession` + 各段计时埋点 + P50/P95 聚合。
6. **B-3 快**：本地常驻暖机、关键路径并行、注入路径复核。
7. **B-4 UI（最小）**：路由策略选择 + 健康状态 + 隐私开关 + 录音中去预览上屏。

## 9. 风险与权衡

- **主动探测有成本**：TLS 握手计时需要到云端主机的网络开销；用低频 + 缓存 + 会话前按需刷新控制。
- **冷启动首轮**：健康画像为空时按「默认优先云端」处理；若首轮云端明显慢，用户会感知一次，之后自动学习。
- **隐私默认**：云端默认带上下文（用户已确认），以「云端不发送上下文」开关作为退路；文案需明示「本轮音频与上下文将上传」。
- **`estimatedWarmLatencyMs` 是估计值**：仅用于路由参考，真实延迟以健康画像为准。

## 10. 参考

- 对标逆向报告：`/Users/yiheng/pycode/typeless-re/TYPELESS-2.8.1-REVERSE-ENGINEERING.md`（快/准机制拆解 §4/§5、前端状态机 §6）。
- 既有产品设计：`docs/plans/2026-10-08-flowtype-local-first-product-design.md`。
