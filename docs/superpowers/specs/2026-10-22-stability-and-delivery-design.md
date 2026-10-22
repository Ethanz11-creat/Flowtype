# FlowType 稳定性与交付治理 — Design Spec

**日期**：2026-10-22
**状态**：待 Owner 评审（Draft）
**分支 / 基线**：`flowtype-local` / `6b95d53`
**输入**：本次启动崩溃排查、全量薄弱点审计、Typeless 2.8.1 逆向报告、现有验证矩阵

---

## 0. 一句话

把「能不能用」从隐式假设变成显式状态：应用启动后必须知道自己缺什么、能做什么、失败时下一步做什么；交付先保证落到正确位置，再谈识别准确率。

---

## 1. 目标与非目标

### 1.1 用户症状 → 可验收目标

| 用户症状 | 已定位的机制性原因 | 本 spec 的目标 |
|---|---|---|
| 一开就不能用 | 启动崩溃（已修）；辅助功能权限只在启动检查且不恢复；本地模型 / 云端 ASR 都不可用时没有任何前置提示 | 冷启动 10/10 不崩；3 秒内说明当前可用性；运行中授权后热键自动恢复；没有识别引擎时在开始录音前就给出可操作修复，而不是录完才失败 |
| 转写和落点不靠谱 | 默认逐键 Unicode 注入；粘贴只是 6 个 bundle ID 的实验选项；停止后没有无语音预检 | 默认「自动交付」：可编辑目标走剪贴板 + Cmd+V，键入作为兼容回退；静音不产生幻觉文本；每次交付有明确结果 |
| 说不清，整体没底 | 没有单一就绪状态；错误只有 notice/error 两档；没有启动冒烟、构建身份、CI；验证矩阵全部 Pending | 单一 Readiness 事实源；失败分级 + 下一步动作；进程级启动冒烟 + 构建身份 + CI 门禁；核心真机矩阵跑完并留证据 |

### 1.2 非目标（本 spec 明确不做）

- 自动更新、云端遥测 / 崩溃上报（需要签名、托管与隐私设计，另立 spec）
- 修改 ASR 模型、准确率算法、LLM 提示词
- 流式 ASR、录音中上屏中间文本
- 合并回 `main`（`main` 仍是 2026-05-07 旧快照，见 handoff）
- 把 API Key 迁回 Keychain（未签名 app 会 `SecItemAdd -34018`）
- 新增云 ASR / LLM 服务商

---

## 2. 已验证的现状（截至 `6b95d53`）

### 2.1 启动

- 启动闪退根因已确认：`ASRRouter.startProbing()` 是 `@MainActor`，其 `DispatchSourceTimer.setEventHandler` 的闭包未标注 `@Sendable`，Swift 6 推断为 MainActor 隔离；首次 tick 在 `flowtype.asr-router.probe` 队列上触发 executor 断言，`dispatch_assert_queue_fail` → `EXC_BREAKPOINT` / SIGTRAP。
- 修复为 `{ @Sendable in ... }` 后，最小复现、`swift build`、`--self-test`、替换后的 `.app` 均已验证不崩。
- 该 bug 说明：**构建通过、纯逻辑测试全绿，都不能证明进程能活过启动后的第一个定时器。**

### 2.2 权限

- `FlowTypeApp.applicationDidFinishLaunching` 在 onboarding 完成后调用 `PermissionHelper.checkAccessibility()`；失败则 `showPermissionGuide()`，内部是阻塞式 `NSAlert.runModal()`（`PermissionHelper.swift:50`）。每次启动都会弹。
- `WindowManager.setupCGEventTap()` 在 `CGEvent.tapCreate` 失败时直接 `return`（`WindowManager.swift:234`），**不会**调用 `startEventTapHealthCheck()`。因此健康检查只在 tap 创建成功后存在。
- 用户在系统设置里补授权限后，当前进程不会重建 tap；菜单「检查权限」（`StatusBarController.swift:193`）只再查一次并弹窗，不重建；只有「重新加载配置」会走 `reloadHotkey()`。
- 本次审计环境当天 7 次启动全部记录 `FAILED to create CGEvent tap`，辅助功能权限未授予。
- 麦克风权限在录音开始时才请求（`RecordingStage.swift:52`）；拒绝后返回不可重试错误，但错误卡片没有「打开麦克风设置」动作。

### 2.3 ASR 引擎与模型

- 路由默认 `.auto`：云端已配置且健康时**云端优先**，否则本地（`ASRRoutingPolicy.swift:64-99`）。因此「本地模型」不是所有配置下的硬前置；但未配置云端时，本地模型就是唯一引擎。
- 推荐模型按硬件档位选择：中/高端推荐 1.7B，低端 0.6B（`ModelPreset.swift:60-67`）。
- 本次审计机器上 `~/Library/Application Support/Flowtype/models/aufklarer/Qwen3-ASR-1.7B-MLX-4bit` 为 0B；自动下载以 `Invalid metadata: File metadata must have been retrieved from server` 失败。
- `hf-mirror.com` 可达（HTTP 307，约 0.4s）；`huggingface.co` 8s 超时。说明失败更像源 / 元数据问题，不是纯网络不可达；**根因尚未确认**，M0 必须先查清。
- 已有修复 UI：`QwenModelStatusCard` 提供重试、下载源切换、指定模型文件夹、复制 `hf download` 命令。但该卡片把 `modelId` 与命令**写死为 0.6B**（`QwenModelStatusCard.swift:11-12`），而中高端机器实际下载 1.7B；`ASRModelStatusCard` 用的是真实 preset。两个状态卡片会互相矛盾。
- 模型状态只进菜单 tooltip（`StatusBarController.swift:72-87`），不会在开始录音前阻止或解释。

### 2.4 交付

- `Configuration.deliveryMode` 默认 `.unicode`，解码缺省也是 `.unicode`（`Configuration.swift:405`、`514`）。
- `DeliveryMode.usesPaste` 只对 6 个 bundle ID 返回 true（`KeyboardInjector.swift:207-211`）；设置页把粘贴标为「候选应用粘贴（实验）」。
- `decideInjection` 只有在 secure input 或明确的非文本控件时才走剪贴板；`blindOrUnknown` 失败开放，走注入（`InjectionDecision.swift:47-54`）。
- `ClipboardTransaction` 已实现快照 / 写入 / Cmd+V / 恢复，并处理 changeCount 所有权、并发复制、部分快照、取消（`KeyboardInjector.swift:271-344`）。这是可以复用的资产。
- 交付结果已有 `.typedDispatched` / `.pasteDispatched` / `.uncertain` / `.clipboard` / `.cancelled`，但没有 AX 回读，事件发出不等于目标真的插入。

### 2.5 失败与验证

- `ASRStage` 在识别结果为空时抛「未识别到完整文字，请重试」（`ASRStage.swift:96-98`）；**没有在停止录音后、识别前做静音 / 无语音判定**。候选全失败时会把 AppleSpeech 预览当最终文本（`ASRStage.swift:128-133`），静音时预览可能产生幻觉。
- `ErrorRecoveryContext` 只有 `retryable` 与 `rawText`；orchestrator 根据动作数量决定 `.notice` 还是 `.error`（`PipelineOrchestrator.swift:401-415`）。
- 手动验证矩阵 `docs/2026-10-14-flowtype-product-validation.md` 全部 Pending；没有任何一次真实麦克风 / 热键 / AX / 注入 / 剪贴板验收。
- 无 `.github/workflows`；无启动冒烟；`scripts/build-app.sh` 把 `CFBundleShortVersionString` 写死 `1.0.0`、`CFBundleVersion` 写死 `1`。
- 分支领先 `origin/flowtype-local` 58 个 commit，未推送；`main` 未动。

---

## 3. 设计原则

1. **单一事实源**：就绪状态只由 `ReadinessMonitor` 计算和发布；菜单、面板、录音前置检查、日志读同一份快照。
2. **显式降级，不假装成功**：没有强引擎就用「基础模式」并标注；交付不确定就说不确定；绝不把「事件已发出」说成「已输入」。
3. **失败必须带下一步**：每个 fatal / recoverable 错误至少有一个可执行动作（打开设置、重试、改用其他引擎、复制原文）。
4. **交付以目标可写为准**：先判定焦点是否可编辑 / 是否安全输入，再选择粘贴或键入；不以「我们有权限」代替「目标能接收」。
5. **每个改动都有证据**：纯逻辑进 `--self-test`；进程级问题进 `--smoke-test`；真实落点进验证矩阵。

---

## 4. 架构设计

### 4.1 Readiness：单一事实源

新增纯数据类型与纯判定函数，便于 self-test：

```swift
enum PermissionState: Equatable, Sendable {
    case granted, denied, notDetermined, unknown
}

enum EngineReadiness: Equatable, Sendable {
    case ready                      // 本地模型已加载 / 云端已配置且网络可达 / Apple 已授权
    case provisioning(progress: Double)
    case configuredUnverified       // 已配置但尚未验证（云端）
    case unavailable(reason: String)
}

struct ReadinessSnapshot: Equatable, Sendable {
    let accessibility: PermissionState
    let microphone: PermissionState
    let speechRecognition: PermissionState
    let localModel: EngineReadiness
    let cloudASR: EngineReadiness
    let appleSpeech: EngineReadiness
    let computedAt: Date
}

enum ReadinessLevel: Equatable, Sendable {
    case ready
    case degraded(reason: String)   // 可用，但能力受限
    case blocked(reason: String)    // 开始录音没有意义
}

func classifyReadiness(_ s: ReadinessSnapshot) -> ReadinessLevel  // pure
```

判定阶梯（纯函数，测试钉住）：

1. `microphone != .granted` → `.blocked("麦克风权限未开启")`。
2. 三个引擎全部不可用，且没有 `provisioning` → `.blocked("没有可用的语音识别引擎")`。
3. 只有 AppleSpeech 可用 → `.degraded("基础识别模式，准确率较低")`。
4. 本地 / 云端至少一个 `ready`，但 `accessibility != .granted` → `.degraded("全局热键不可用；可从菜单开始，结果写入剪贴板")`。
5. 其余 → `.ready`。

`ReadinessMonitor`（`@MainActor ObservableObject` 单例）：

- 触发刷新：启动、`NSApplication.didBecomeActiveNotification`、菜单即将打开、录音前、`QwenModelState.$status` 变化、云端配置变化、权限轮询命中、交付失败后。
- 权限轮询只在 `accessibility != .granted` 时启动：每 2s 一次，最多 60s；命中后立即取消并调用 `WindowManager.repairEventTap()`。
- 非模态提醒与红色角标带 3s 去抖：模型正在自动加载、权限轮询尚未返回时，不因瞬时 `.blocked` 闪一下。
- 发布 `@Published private(set) var snapshot` / `level`。
- 消费方：状态栏图标与 tooltip、菜单首项、录音前置检查、`--smoke-test` 输出。

状态栏表现：

- `.ready`：现有图标。
- `.degraded`：图标叠加 `exclamationmark.triangle.fill`，tooltip 写原因。
- `.blocked`：图标叠加红色 `xmark.circle.fill`，菜单首项为「修复：<原因>…」。

### 4.2 权限自愈

**目标：授权后不需要重启，也不需要手动「重新加载配置」。**

1. `WindowManager` 重构为：
   - `installEventTap() -> Bool`：创建成功返回 true；失败返回 false，不再静默返回。
   - `repairEventTap()`：tap 存在但被禁用 → `tapEnable`；tap 为 nil → `installEventTap()`。幂等。
   - 健康定时器在启动时**无条件**创建一次，每 5s 检查：tap 被系统禁用则重新启用；tap 为 nil 且 `PermissionHelper.checkAccessibility()` 为 true 则重建；为 nil 且权限未授予则跳过（避免每 5s 产生一条失败日志，只在首次与每第 12 次记录）。
2. `PermissionRecovery`（由 `ReadinessMonitor` 驱动）：
   - 启动时缺权限 → 启动 2s × 30 次轮询。
   - `didBecomeActive` → 立即检查一次。
   - 从 FlowType 打开系统设置后 → 启动同样的轮询。
   - 命中后：`repairEventTap()` → 刷新 readiness → 播放一次轻提示音 → 底部浮层短暂显示「辅助功能权限已生效」（不复用会话 `.notice`，避免与听写状态机耦合）。
3. 菜单：
   - 「重新检测权限」→ 立即检查 + `repairEventTap()`，不再只是弹窗。
   - 「打开辅助功能设置」→ 打开对应 pane 并启动轮询。
4. 启动提示改为非模态：
   - 删除 `showPermissionGuide()` 的启动调用；onboarding 内部仍可保留向导。
   - 新增 `PermissionReminderPanel`：复用 `FloatingPanel` 样式，底部浮层 360×96，两个按钮「打开设置」「稍后」，20s 自动消失；同一启动周期内用户手动关闭后不再出现。
   - 缺权限但用户坚持使用时，菜单提供「开始听写 / 停止听写」；没有 AX 时交付只能写剪贴板，UI 必须明确标注。
5. 麦克风：
   - `RecordingStage` 的权限错误改为带 `PermissionKind.microphone` 的结构化错误；orchestrator 生成动作「打开麦克风设置」「重新检测」。
   - 录音前 readiness 已判定为 blocked 时不打开麦克风，直接进 `.error`，避免无意义录音。

### 4.3 ASR 引擎就绪与模型修复

#### 4.3.1 引擎聚合

候选引擎必须遵守 `asrRoutingPolicy`，否则 readiness 会宣称一条路由永远不会走的路：

- 本地：`QwenModelState.status == .ready` → `ready`；`downloading/loading/stalled` → `provisioning`；`.notLoaded` 且 onboarding 完成、自动下载将会启动 → `provisioning(0)`；其余 → `unavailable(reason)`。
- 云端：`cloudASRConfig` 有 active provider 且 key / baseURL / model 非空 → 配置存在；再结合 `ASRRouter` 的 `networkReachable`。已配置且网络可达 → `ready`（标注「未验证」可选）；已配置但网络不可达 → `unavailable("网络不可达")`；`policy == .localOnly` 时直接视为 unavailable。
- AppleSpeech：`SFSpeechRecognizer.authorizationStatus() == .authorized` 且 recognizer 可用 → `ready`；仅在 `policy == .auto` 时计入可用候选（`.localOnly` / `.cloudOnly` 下它是内部兜底，不算满足用户选择）；拒绝 → `unavailable`。

菜单首项显示实际候选链，例如：

```
识别：云端 DeepSeek-ASR → 本地 1.7B
识别：本地 1.7B（下载中 42%）
识别：Apple 基础模式（仅此引擎可用）
识别：未就绪 — 配置云端或加载模型…
```

#### 4.3.2 录音前置检查

`SessionController.startRecording()` 在进入 `.preparing` 前读取 readiness：

- `.blocked` → 直接 `.error(reason)`，不打开麦克风、不创建会话。动作由 blocker 决定：
  - 麦克风未授权 → `打开麦克风设置` / `重新检测`；
  - 没有可用引擎 → `打开 ASR 设置` / `重新检测`；若本地模型处于失败态，再加 `重试加载模型`；
  - `localOnly` / `cloudOnly` 下所选引擎不可用 → 上述动作 + `改为自动路由`（显式改变策略，不偷偷降级）。
- `.degraded` → 正常录音；面板在 `preparing` 阶段显示降级原因（例如「基础模式」），不阻塞。
- `.ready` → 现有路径。

这样「按了热键什么都没发生 / 录完才报错」变成「按了热键立刻告诉你缺什么、点哪里修」。

#### 4.3.3 模型 provisioning 加固

在现有 `QwenModelState` 上增量修改，不重写：

1. **错误分类**：新增

   ```swift
   enum ModelProvisionError: Equatable, Sendable {
       case metadataInvalid(detail: String)   // "Invalid metadata…"
       case network(detail: String)
       case stalled
       case incompleteLocal(path: String)
       case loadFailed(detail: String)
   }
   ```

   分类只依赖错误文本 / 阶段，纯函数，进 self-test。

2. **下载前预检**：对选中端点请求 `config.json`（URLSession，10s 超时），拿到 HTTP 状态与最终 URL。
   - 失败 → 立即报 `metadataInvalid` / `network`，附端点与状态，不再盲等 3 次 × 30s。
   - 成功 → 再进入 `fromPretrained`。
   - 预检只取元数据，不下载权重。

3. **尝试阶梯**：
   - 本地完整副本 → `offlineMode: true` 加载（现有逻辑）。
   - 否则下载当前推荐 preset，最多 3 次（现有退避保留）。
   - 自动模式（`selectedLocalModelID == nil`）且推荐的是 1.7B 且全部失败 → **再试一次 0.6B**；成功则记录「已退回 0.6B」。
   - 用户显式选择了 1.7B → 不偷偷换模型，只提供按钮「改用 0.6B（约 675MB）」。

4. **错误卡片**（修 `QwenModelStatusCard`）：
   - 使用真实 active preset，不再写死 0.6B；`hf download` 命令同步用真实 repoId。
   - 显示：错误分类、端点、最近一次 HTTP 状态 / 错误摘要。
   - 动作：`重试` / `切换下载源（自动 / 官方 / 镜像）` / `指定模型文件夹` / `复制命令` / （自动模式）`改用 0.6B`。
   - 不再显示「下载停滞，正在自动重试…」却没有进度（当前 `.stalled` 状态文案与实际重试不同步的问题一并修）。

5. **与 readiness 接线**：`QwenModelState` 状态变化驱动 `ReadinessMonitor.refresh()`；模型 ready 后清掉 blocked 状态与提示。

6. **Onboarding**：完成前检查至少一个引擎可用；若用户选择「稍后配置」，允许完成，但 readiness 持续为 `.blocked`，状态栏红点与菜单修复项常驻。

### 4.4 交付：自动模式（粘贴优先）

#### 4.4.1 模式与迁移

```swift
enum DeliveryMode: String, Codable, Sendable {
    case automatic            // 新默认
    case unicode              // 兼容：仅逐键键入
    case pasteInSupportedApps // 兼容：旧实验选项
}
```

- `Configuration` 的默认值与解码缺省从 `.unicode` 改为 `.automatic`。
- 已显式保存为 `unicode` / `pasteInSupportedApps` 的配置保持原值（尊重用户选择）；从未写过该键的用户升级后自动进入 `.automatic`。
- 设置页文案：`自动（推荐）` / `仅键入（兼容）`；删除「候选应用粘贴（实验）」。

#### 4.4.2 纯决策函数

新增 `DeliveryPolicy.swift`：

```swift
enum DeliveryMethod: Equatable {
    case paste        // 写剪贴板 + Cmd+V
    case type         // 逐键 Unicode
    case clipboard    // 只复制 + 提示音
}

func resolveDeliveryMethod(mode: DeliveryMode,
                           signals: FocusSignals,
                           accessibilityTrusted: Bool,
                           bundleID: String?) -> DeliveryMethod
```

阶梯：

1. `signals.secureInputActive` 或 `focus == .nonTextControl` → `.clipboard`（沿用现有 `decideInjection`）。
2. `accessibilityTrusted == false` → `.clipboard`（无法向其他 app 发按键）。
3. `.unicode` → `.type`。
4. `.pasteInSupportedApps` → 白名单内 `.paste`，否则 `.type`（保持旧行为）。
5. `.automatic`：`.editableText` / `.blindOrUnknown` → `.paste`。

#### 4.4.3 运行时回退链

在 `InjectionStage` 中替换当前「`usePaste` 布尔」分支：

- `paste` 返回 `.dispatched` → 完成，结果 `.pasteDispatched`。
- `.uncertain` → 完成，结果 `.uncertain`，**绝不重试**。
- `.cancelled` → 完成，结果 `.cancelled`。
- `.unsafeSnapshot` → 未写剪贴板、未发键；若 `accessibilityTrusted` 且焦点仍可编辑 → 回退 `.type`；否则挂起错误并保留原文。
- `.clipboardChanged` → 结果 `.uncertain` + 「剪贴板被其他应用改过」提示，不重试。
- `.notDispatched` → 未发键；若焦点仍可编辑 → 回退 `.type`；否则挂起错误。
- `type` 中途失败且已发出部分事件 → `.uncertain`，不复制、不回退（避免重复文本）。
- `type` 在发出任何事件前失败 → 复制到剪贴板（现有行为）。

剪贴板恢复窗口保持 150ms；M3 在真实 app 上验证是否足够，若 Terminal / Electron 消费慢，再把 `settle` 提到 250ms（只改一个常量，加真机证据）。

#### 4.4.4 结果呈现

- 成功：不加提示（避免噪音），历史记录写 `deliveryOutcome`。
- `.uncertain`：面板 `.notice("已发送，但无法确认是否插入；文本已可从历史复制")`。
- `.clipboard`：现有「已复制」文案与提示音。
- 菜单「最近一次交付」显示结果与目标 app，便于用户自查。

### 4.5 失败分级与恢复

扩展 `ErrorRecoveryContext`（保持向后兼容默认值）：

```swift
enum FailureKind: Equatable, Sendable {
    case permission(PermissionKind)
    case readiness(ReadinessBlocker)
    case transientASR
    case deliveryUncertain
    case cancelled
}

enum RecoveryAction: Equatable, Sendable {
    case openAccessibilitySettings
    case openMicrophoneSettings
    case openASRSettings
    case recheckReadiness
    case retryStage
    case copyRawText
    case dismiss
}
```

映射：

| FailureKind | UI 状态 | 动作 |
|---|---|---|
| permission(.accessibility) | `.error` | 打开辅助功能设置、重新检测 |
| permission(.microphone) | `.error` | 打开麦克风设置、重新检测 |
| readiness(noEngine / modelFailed) | `.error` | 打开 ASR 设置、重新检测、重试加载模型；策略受限时加「改为自动路由」 |
| transientASR | `.error` | 重试识别、复制原文 |
| deliveryUncertain | `.notice` | 复制文本、查看历史 |
| cancelled | `.idle` | 无 |

规则：**只有没有任何可执行动作时才用 `.notice`**；`.notice` 不再承担「不可恢复错误」的展示。`buildErrorActions` 改为由 `FailureKind` 生成，不再根据 `retryable` 猜测。

### 4.6 启动与发布护栏

#### 4.6.1 `--smoke-test`

`FlowTypeMain.main` 增加参数分支：

- 先初始化 `NSApplication.shared` 并设 `.accessory`；否则构造状态栏 / 面板可能在 `main()` 早期崩溃，冒烟本身变成噪音。
- `ConfigurationStore.shared` 在检测到 `--smoke-test` 时使用独立 suite（`flowtype.smoke`），日志走 `diagnostic-smoke.log`；不写真实配置、不触发模型下载。
- 依次构造：`ConfigurationStore` → `SessionController.shared` → `ASRRouter.shared`（并启动探测）→ `WindowManager.shared`（创建 tap 允许失败）→ `ReadinessMonitor.refresh()`。
- 在主 RunLoop 上等待 3s（覆盖 probe timer 的 1s 首次 tick 与健康检查周期）。
- 输出一行 JSON：`{"ok":true,"readiness":"degraded","accessibility":"denied",...}` 并 `exit(0)`；任何未捕获异常 / 崩溃即非 0。
- 不要求辅助功能、麦克风或模型，CI 与本地都能跑。若 CI runner 没有 WindowServer，smoke 作为本地门禁，CI 至少保留 build + self-test（在 CI 配置里显式注明）。

该测试的直接价值：本次 SIGTRAP 发生在启动后 1s 的 `probeQueue` 上；`--smoke-test` 会走到同一条路径。

#### 4.6.2 构建身份

- 新增 `BuildInfo`：`version`、`gitSHA`、`builtAt`。
- `scripts/build-app.sh` 生成 `FlowTypeBuild.json` 放进 `Contents/Resources`，并把 `CFBundleShortVersionString` 来自 `VERSION` 环境变量（默认 `1.0.0`）、`CFBundleVersion` 使用 `git rev-list --count HEAD`。
- 日志首行、菜单「关于 Flowtype」、`--smoke-test` JSON 都带 version + SHA。
- 安装脚本 / 文档记录 SHA，避免再次出现「装了旧 app 却以为在测新代码」。

#### 4.6.3 日志隔离

- `AppLogger` 增加进程角色（`.app` / `.selfTest` / `.smokeTest`）与文件路由：
  - `.app` → `~/Library/Logs/flowtype/diagnostic.log`
  - `.selfTest` → `diagnostic-selftest.log`
  - `.smokeTest` → `diagnostic-smoke.log`
- 每条自测日志带 `[SelfTest]` 前缀与 run id；失败统计只看该文件。
- 保留 UTC 时间戳（与崩溃报告本地时间差 8 小时，文档已说明）；不再混入生产日志。

#### 4.6.4 CI

新增 `.github/workflows/ci.yml`（macOS 15 runner）：

```bash
swift build
swift run FlowType --self-test
./scripts/build-app.sh
./build/Flowtype.app/Contents/MacOS/FlowType --smoke-test
```

- 任一步非 0 即失败。
- 不上传含用户数据的日志；CI 只上传自测/冒烟日志。
- 若仓库无远端或 runner 不可用，至少把同样命令写进 `scripts/verify.sh` 作为本地门禁。

#### 4.6.5 分支备份

把 `flowtype-local` 推送到 origin，作为防丢备份；不合 `main`、不改历史。

---

## 5. 启动时序（目标状态）

```
applicationDidFinishLaunching
  → ConfigurationStore
  → BuildInfo 写日志首行
  → StatusBarController.setup()
  → ReadinessMonitor.refresh()            // 权限 + 引擎快照
  → WindowManager.installEventTap()        // 无论成败都启动健康检查
  → ReadinessMonitor.level:
       .blocked / .degraded → 状态栏角标；首次缺 AX 显示非模态浮层
  → 若 accessibility 缺失 → 启动 2s 权限轮询
  → 若 onboarding 完成 → 后台加载模型（状态变化驱动 readiness）
  → 用户按热键 / 菜单开始听写
       → startRecording 前置检查 readiness
       → .blocked → 立即 .error + 修复动作（不打开麦克风）
       → .degraded → 正常录音，面板显示降级原因
```

---

## 6. 文件改动地图

### 新增

| 文件 | 职责 |
|---|---|
| `Core/Readiness/ReadinessSnapshot.swift` | 状态类型 + 纯 `classifyReadiness` |
| `Core/Readiness/ReadinessMonitor.swift` | `@MainActor` 单例；权限轮询、刷新触发、发布快照 |
| `Services/Delivery/DeliveryPolicy.swift` | 纯 `resolveDeliveryMethod` + 结果映射 |
| `App/SmokeTest.swift` | `--smoke-test` 生命周期与 JSON 输出 |
| `Utilities/BuildInfo.swift` | 读 bundle 内构建身份（dev 环境回退） |
| `UI/PermissionReminderPanel.swift` | 非模态权限提醒浮层 |
| `.github/workflows/ci.yml` | build + self-test + smoke |

### 修改

| 文件 | 改动 |
|---|---|
| `App/FlowTypeApp.swift` | 去阻塞弹窗；smoke 分支；启动日志带 BuildInfo；模型加载接 readiness |
| `WindowManager.swift` | `installEventTap` / `repairEventTap`；健康检查无条件启动 |
| `App/StatusBarController.swift` | 角标 / 菜单首项显示 readiness；「重新检测权限」重建 tap；「开始 / 停止听写」；最近交付结果 |
| `Utilities/PermissionHelper.swift` | 麦克风 / Speech 状态查询；非模态提醒入口；去掉每次启动 `runModal` |
| `Core/Pipeline/Stages/RecordingStage.swift` | 录音前 readiness 检查；麦克风结构化错误 |
| `Core/PipelineOrchestrator.swift` | `FailureKind` / `RecoveryAction` 映射；blocked 直接进 error |
| `Core/Pipeline/Stages/ASRStage.swift` | 无引擎错误改为 `readiness(noEngine)` |
| `Services/Speech/QwenModelState.swift` | 错误分类、预检、0.6B 回退、发布 readiness 变化 |
| `Settings/QwenModelStatusCard.swift` | 动态 preset / repoId；错误详情与修复动作 |
| `Core/Configuration.swift` | `deliveryMode` 默认 `.automatic`，解码缺省同步 |
| `Services/KeyboardInjector.swift` | 保留事务；`DeliveryMode` 增 `.automatic`；移除硬编码白名单依赖（白名单仍供 legacy 模式） |
| `Core/Pipeline/Stages/InjectionStage.swift` | 用 `resolveDeliveryMethod` 与回退链替换布尔分支 |
| `Settings/SettingsPage+Recording.swift` | 交付模式文案与选项 |
| `Utilities/AppLogger.swift` | 进程角色 / 文件路由 |
| `scripts/build-app.sh` | BuildInfo、版本 / build number |
| `Testing/SelfTest.swift` | readiness、delivery policy、错误分类、权限映射的纯逻辑断言 |
| `docs/2026-10-14-flowtype-product-validation.md` | 补 R1–R3、P1–P3、F1–F2 的实测记录与新 cases |

---

## 7. 验收标准（程序级）

只有全部满足，才把本治理标记为完成：

1. **冷启动**：连续 10 次启动无崩溃；每次日志有 BuildInfo 首行；`--smoke-test` 10/10 exit 0。
2. **权限自愈**：缺 AX 启动 → 打开系统设置并授权 → 不重启，≤5s 内热键可用、状态栏角标消失。
3. **无引擎**：本地模型不可用、云端未配置且 Apple Speech 未授权（即三引擎均不可用）→ 按热键立即出现 `.error`，包含「打开 ASR 设置」「重新检测」；不产生空录音、不进入 processing。
4. **模型修复**：制造一次元数据失败 → 卡片显示错误分类与端点；「切换下载源」「指定文件夹」「重试」至少各成功一次；自动模式下 1.7B 全失败能退回 0.6B 并标注。
5. **交付**：`.automatic` 下在 TextEdit、VS Code、Chrome、Terminal、Cursor 各完成一次中文 + 英文 + 多行输入；文本落点正确；用户原剪贴板在粘贴后被恢复；`.uncertain` 不重复发送。
6. **安全目标**：密码框 / secure input → 只复制，不发键；非文本控件 → 只复制；无 AX → 只复制。
7. **静音**：录音 5s 静音后停止 → 无幻觉文本、无历史记录、只出现短暂提示。
8. **连续稳定性**：连续 20 次听写（混合成功 / 取消 / 重新录音）后，状态机回到 `.idle`，无重复交付、无卡在 processing、无残留麦克风占用。
9. **取消**：在 preparing / recording / ASR / polish / injection 各阶段取消 → 无迟到交付、无剪贴板污染。
10. **发布**：CI 绿；验证矩阵中新增核心行全部 Pass 且有证据（日期 / SHA / 环境 / 目标 app）。

---

## 8. 测试策略

### 8.1 纯逻辑（`--self-test`）

- `classifyReadiness`：麦克风拒绝 → blocked；三引擎均不可用 → blocked；仅 Apple → degraded；AX 缺失但引擎就绪 → degraded；全就绪 → ready。
- `resolveDeliveryMethod`：secure / non-text → clipboard；无 AX → clipboard；`.unicode` → type；`.automatic` + editable / blind → paste；legacy 白名单行为不变。
- `ModelProvisionError` 分类：真实错误字符串样本 → `metadataInvalid` / `network` / `stalled`；空目录 → `incompleteLocal`。
- `FailureKind → RecoveryAction` 映射：每类至少一个动作；只有 deliveryUncertain / cancelled 允许空动作。
- `Configuration` 迁移：缺少 `deliveryMode` 的旧 JSON → `.automatic`；显式 `"unicode"` → `.unicode`。

### 8.2 进程级（`--smoke-test`）

- 构造真实单例并等待 3s，覆盖 `ASRRouter` probe timer、WindowManager 健康定时器、模型状态订阅。
- 作为 SIGTRAP 类问题的回归门禁（当前没有这类测试）。

### 8.3 集成 / 真机

- 现有 `ClipboardTransaction` fixture 测试保留；新增 `.automatic` 回退链的注入测试（paste notDispatched → type；uncertain → 不重试）。
- 手动矩阵按 §7 执行；每行记录 SHA、macOS 版本、目标 app 版本、焦点元素、交付结果、剪贴板恢复情况。
- 不做「少量样本推准确率」的结论；只记录字面量 pass/fail。

---

## 9. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 默认粘贴在个别 app 行为异常（自定义 Cmd+V、远程桌面、游戏） | 保留「仅键入」设置；自动模式失败回退键入；先跑 5 个核心 app 的真机矩阵；必要时加 app 排除列表 |
| 剪贴板恢复过早，目标 app 尚未消费粘贴 | 150ms 常量可调到 250ms；矩阵中专门测 Terminal / Electron；事务已有所有权检查，不会覆盖用户并发复制 |
| 权限轮询带来日志噪音 / 耗电 | 只在缺权限时启动，2s × 30 次封顶；命中即停；健康检查失败日志限流 |
| `.blocked` 直接报错让用户觉得「又不能用」 | 错误必须带明确动作：打开对应设置、重新检测、重试加载模型；策略受限时提供「改为自动路由」；状态栏常驻可点 |
| 元数据错误根因未明，改动绕错方向 | M0 先复现并抓完整错误 / 端点 / HTTP 状态；未确认前不改下载核心，只加观测 |
| Apple 基础模式被误认为正式能力 | UI 明确标注「基础模式 / 准确率较低」，不写入正式引擎列表首位 |
| 冒烟测试给出虚假安全感 | 明确它只覆盖进程存活与定时器路径，不覆盖 UI / 真机；真机矩阵仍是最终门禁 |
| 工作流过大，半途而废 | 按 M0–M5 拆分，每个里程碑单独 writing-plans、单独验收；M0 不通过不进入后续 |

---

## 10. 分阶段路线图

| 里程碑 | 内容 | 依赖 | 退出条件 |
|---|---|---|---|
| **M0 环境与根因** | 授予辅助功能；复现并定位模型 `Invalid metadata`；确认镜像 / 官方端点行为；完成一次真实听写 | 无 | 有一次完整的 录音 → 识别 → 交付 证据；错误根因有结论 |
| **M1 Readiness + 权限自愈** | Snapshot / Monitor、状态栏、菜单动作、非模态提醒、tap 重建、麦克风动作 | M0 | §7.2、§7.3 通过 |
| **M2 模型修复 + 引擎降级** | 错误分类、预检、0.6B 回退、卡片修正、Apple 基础模式 | M1 | §7.4 通过 |
| **M3 自动交付 + 无语音预检** | `.automatic`、`DeliveryPolicy`、回退链、结果呈现、设置文案；停止后静音判定 | M1 | §7.5、§7.6、§7.7 通过 |
| **M4 失败分级** | `FailureKind` / `RecoveryAction`、orchestrator 映射、文案 | M1–M3 | 每类失败都有可执行动作 |
| **M5 发布护栏 + 验证** | smoke、BuildInfo、日志隔离、CI、验证矩阵、push 分支 | M1–M4 | §7.1、§7.8–§7.10 通过 |

顺序理由：M0 没有真实权限与模型，后面所有真机验收都无法执行；M1 是 M2/M3 的共同前置；M4 依赖前三者产生的真实失败类型；M5 最后固化门禁。

---

## 11. 待 Owner 确认的决策（含推荐值）

| # | 决策 | 推荐 | 影响 |
|---|---|---|---|
| 1 | 默认交付改为 `.automatic`（可编辑 / AX 盲区走粘贴） | **是**；显式 `.unicode` 用户保持原行为 | 直接改善「落点不靠谱」；需 5 app 真机矩阵 |
| 2 | Apple Speech 升级为显式「基础模式」 | **是**，标注准确率较低，排在本地 / 云端之后 | 无引擎时仍可交付，但可能拉低体感 |
| 3 | 1.7B 全部失败后自动试 0.6B | **仅自动模式**，一次；显式选择不覆盖 | 首次可用性优先，代价是准确率下降 |
| 4 | 启动权限提示改为非模态浮层 | **是** | 不再阻塞启动；用户可能忽略，需状态栏角标兜底 |
| 5 | 菜单增加「开始 / 停止听写」 | **是** | 无 AX 时仍可用剪贴板交付 |
| 6 | 推送 `flowtype-local` 到 origin 作为备份 | **是**（不合并 main） | 降低 58 个未推送 commit 的丢失风险 |

---

## 12. 与 Typeless 对照的取舍

| Typeless 机制 | 本 spec 是否采用 | 说明 |
|---|---|---|
| 每次录音初始化检查 AX + 麦克风，fatal 引导设置 | **采用** | 改为 ReadinessMonitor + 录音前置检查，且授权后自愈 |
| 剪贴板 + Cmd+V 作为主注入 | **采用** | `.automatic` 默认；保留键入兼容 |
| app / URL 黑白名单 + `is_editable` | **部分采用** | 已有 AX 焦点判定；本版不做 URL 规则，保留 bundle 排除扩展点 |
| 1s 后 5s 静音检测 | **采用（M3）** | 在停止后、ASR 前加无语音判定；不引入流式 |
| 服务端两阶段识别 / 精修 | **不采用** | 与本地可离线、隐私可控的路线冲突 |
| 完整 fatal / recoverable 错误分类 | **采用** | `FailureKind` + `RecoveryAction` |
| Squirrel 自动更新 / Mixpanel | **不采用（本版）** | 需签名与托管；先做启动冒烟与构建身份 |
| Electron / Opus / WS 半流式 | **不采用** | 架构不同，收益不匹配当前问题 |

---

## 13. 下一步

1. Owner 评审本 spec，对 §11 的 6 个决策给出确认或修改。
2. 通过后，用 writing-plans 为 **M0 + M1** 写实施计划（先解决环境与权限闭环，拿到真机证据）。
3. M0 不通过（拿不到权限或模型仍不可用）时，暂停后续里程碑，先解决环境，不以代码改动掩盖。
