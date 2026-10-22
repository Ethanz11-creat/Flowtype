# FlowType 稳定性 M0 + M1 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 先拿到真实环境证据（M0），再把「当前能不能用、缺什么、怎么修」变成单一就绪状态并让权限自愈（M1）。

**Architecture:** 新增纯数据类型 `ReadinessSnapshot` + 纯判定 `classifyReadiness`，由 `@MainActor` 的 `ReadinessMonitor` 采集权限与引擎状态、去抖发布。`WindowManager` 的 tap 生命周期改为 `installEventTap` / `repairEventTap`，健康检查无条件运行。`SessionController.startRecording()` 在创建会话前读取 readiness，blocked 时直接给出带修复动作的错误，不打开麦克风。

**Tech Stack:** Swift 6.2、SPM、macOS 15+、AppKit/SwiftUI、AVFoundation、Speech、Combine、CoreGraphics。

**Spec:** `docs/superpowers/specs/2026-10-22-stability-and-delivery-design.md`（基线 `8bb40f9`）

## Global Constraints

- 只改 `flowtype-local` 分支；不合并 `main`，不推送，不改历史。
- 每个任务结束必须依次通过：`swift build`（exit 0）、`swift run FlowType --self-test`（末行 `0 failed`，exit 0）。任何一步失败不得进入下一任务。
- `SessionController`、`ReadinessMonitor`、`WindowManager`、状态栏与面板代码都必须在主线程 / `@MainActor` 上修改状态。
- 非主线程队列上的 timer handler 必须显式标注 `{ @Sendable in ... }`；主 RunLoop 上的 `CancellableTimer` 继续使用现有 `Task { @MainActor ... }` 模式。
- 统一使用 `AppLogger.log()`，禁止 `print()`。
- 日志、证据文档、提交内容不得包含 API Key、完整配置 JSON、真实听写内容；引用听写只写「字面量是否保留」，不贴原文。
- API Key 继续保存在 `Configuration.providerAPIKeys`（UserDefaults）；不得改回 Keychain。
- M1 不改变交付模式、ASR 路由默认值、模型下载策略、ASR/LLM 提示词。
- 启动路径不得出现 `NSAlert.runModal()`；onboarding 内部向导保持现状。
- 新增代码不得引入第三方依赖。
- 每个任务单独提交，提交信息使用 Conventional Commits。

## Review Focus

1. **运行中授权辅助功能**：用户在系统设置勾选 FlowType 后，≤5s 内热键恢复；不能重复安装 tap、重复触发开始或崩溃。→ Task 7 的 `eventTapHealthAction` 纯逻辑测试 + Task 15 真机用例。
2. **热键可用时 blocked**：AX 已授予但引擎 / 麦克风不可用时按热键，立即出现 `.error` 和修复动作，不打开麦克风、不进入 processing；修复后再次按热键能正常开始。→ Task 9 的 preflight 集成测试 + Task 15 用例。
3. **引擎状态连续变化**：模型 downloading → ready/error、云端配置变化、权限变化时，readiness 不把「准备中」误判为 ready/blocked，也不闪成不可用。→ Task 4 的六档判定矩阵 + Task 15 的观察记录。
4. **用户拒绝或忽略权限**：权限轮询最多 2s × 30 次后停止，不重复弹阻塞窗口，失败日志不刷屏。→ Task 6 的 `PermissionWatchPolicy` 测试 + Task 15 用例。
5. **无辅助功能时从菜单开始/停止**：不依赖 event tap，录音正常结束，结果以剪贴板交付且 UI 明确说明。→ Task 11 的菜单文案测试 + Task 14 的 `applyAccessibilityGate` 测试 + Task 15 用例。

---

## M0：环境与根因（先拿到证据，再改代码）

M0 是硬门禁：Task 3 无法完成（没有一次真实的录音 → 识别 → 交付）时，停止本计划，不进入 M1。

### Task 1: 确认辅助功能权限与 event tap 存活

**Files:**
- Create: `docs/evidence/2026-10-22-m0-environment.md`

**Interfaces:**
- Consumes: `/Applications/FlowType.app`（含 `6b95d53` 崩溃修复的构建）
- Produces: 带日期、SHA、app 路径、签名信息、日志摘录的证据文档；M1 Task 15 沿用同一 app 身份

- [ ] **Step 1: 记录构建与签名身份**

```bash
git rev-parse HEAD
codesign -dv --verbose=4 /Applications/FlowType.app 2>&1 | rg 'Identifier|Authority|TeamIdentifier|Signature'
stat -f '%Sm %N' /Applications/FlowType.app/Contents/MacOS/FlowType
```

- [ ] **Step 2: 启动应用并打开辅助功能设置面板**

```bash
open -a /Applications/FlowType.app
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
```

- [ ] **Step 3: 请 Owner 在系统设置中勾选 FlowType（若列表中没有，拖入 `/Applications/FlowType.app`），等待 5 秒**

- [ ] **Step 4: 验证 tap 已创建**

```bash
rg -n "EventTap|FAILED to create CGEvent tap|Accessibility" ~/Library/Logs/flowtype/diagnostic.log | tail -n 40
```

Expected: 最新一次启动出现 `[EventTap] CGEvent tap created and enabled successfully`；启动时间之后没有 `[WindowManager] FAILED to create CGEvent tap`。若仍然失败，记录完整日志行并在此停止 M0。

- [ ] **Step 5: 写证据文档**

```bash
mkdir -p docs/evidence
```

文档包含：日期、tester、`git rev-parse HEAD`、macOS 版本、app 路径与签名输出、权限状态（麦克风 / Speech / Accessibility）、上述日志摘录、是否仍失败。不要写入 API Key 或听写内容。

- [ ] **Step 6: 提交**

```bash
git add docs/evidence/2026-10-22-m0-environment.md
git commit -m "docs: record m0 accessibility and event-tap evidence"
```

### Task 2: 定位模型 `Invalid metadata` 根因

**Files:**
- Create: `docs/evidence/2026-10-22-model-metadata.md`

**Interfaces:**
- Consumes: `~/Library/Application Support/Flowtype/models/aufklarer/` 下的模型目录；`~/Library/Logs/flowtype/diagnostic.log`
- Produces: 端点 / HTTP 状态 / 必需响应头 / 结论；M2 直接据此实现预检，M0 不改下载核心

背景：`swift-transformers` 在 `HubApi.swift:793-799` 要求 HEAD 响应同时提供 `X-Repo-Commit`、`ETag`（或 `X-Linked-Etag`）、`Content-Length`（或 `X-Linked-Size`）和非空 `Location`，缺一即抛 `File metadata must have been retrieved from server`。

- [ ] **Step 1: 记录模型目录现状**

```bash
MODEL_ROOT="$HOME/Library/Application Support/Flowtype/models/aufklarer"
find "$MODEL_ROOT" -maxdepth 3 -type f -print -exec ls -lh {} \;
du -sh "$MODEL_ROOT"/* 2>/dev/null
```

记录每个目录的字节数、是否存在 `.metadata` 文件、其内容（commit hash / etag / timestamp）。

- [ ] **Step 2: 对官方与镜像分别做 HEAD 预检**

```bash
for host in https://huggingface.co https://hf-mirror.com; do
  echo "===== $host"
  for repo in Qwen3-ASR-0.6B-MLX-4bit Qwen3-ASR-1.7B-MLX-4bit; do
    echo "--- $repo/config.json"
    curl -sSIL --max-time 20 "$host/aufklarer/$repo/resolve/main/config.json" \
      | rg -i '^(HTTP/|location:|x-repo-commit:|x-linked-etag:|etag:|content-length:|x-linked-size:)'
  done
done
```

Expected: 记录每个组合的最终状态码与上述必须头。缺任一头即为该端点的失败原因候选。

- [ ] **Step 3: 检查 swift-transformers 使用的 revision 列表端点**

```bash
for host in https://huggingface.co https://hf-mirror.com; do
  echo "===== $host"
  curl -sS --max-time 20 -o /dev/null -w '%{http_code}\n' \
    "$host/api/models/aufklarer/Qwen3-ASR-1.7B-MLX-4bit/revision/main"
done
```

- [ ] **Step 4: 抓取应用侧日志**

```bash
rg -n "ModelProvision|HF_ENDPOINT|metadata" ~/Library/Logs/flowtype/diagnostic.log | tail -n 80
```

- [ ] **Step 5: 写结论**

在证据文档中逐条判定以下假设，并给出支持证据（HTTP 状态 / 缺失头 / 本地文件状态）：

- H1：镜像的 HEAD 响应缺少 `X-Repo-Commit` / `ETag` / `Content-Length`。
- H2：Apple 平台只允许相对重定向，`resolve` 的绝对 CDN 跳转导致元数据丢失。
- H3：目标目录有 0B / 半成品文件或过期 `.metadata`，本地与远端提交不一致。
- H4：1.7B 的 repoId 或目标目录与真实仓库不符。

本任务不改产品代码；若 H3 成立，只记录「需要清理的具体目录」，不执行删除。

- [ ] **Step 6: 提交**

```bash
git add docs/evidence/2026-10-22-model-metadata.md
git commit -m "docs: diagnose model metadata failure"
```

### Task 3: 完成一次真实听写基线

**Files:**
- Modify: `docs/evidence/2026-10-22-m0-environment.md`（追加「基线听写」一节）

**Interfaces:**
- Consumes: Task 1 的辅助功能权限；至少一个可用引擎（云端已配置 → 本地模型已加载 → Apple Speech 已授权，按此顺序选择）
- Produces: 一次完整的录音 → 识别 → 交付记录；M1 的对照基线

- [ ] **Step 1: 选择引擎并记录**（不记录 Key）

在菜单「ASR 状态」查看当前引擎与路由策略；记录实际使用的引擎。若三者都不可用，记录阻塞原因并停止 M0。

- [ ] **Step 2: 准备目标**

打开 TextEdit 新建空白文稿，光标置于正文。记录 TextEdit 版本。

- [ ] **Step 3: 执行一次听写**

用触发热键开始，朗读短参考句「请把保存按钮改成蓝色，其他部分保持不变。」，单次触发停止。观察最终文字是否完整、落点是否在 TextEdit、是否只交付一次。

- [ ] **Step 4: 记录证据**

```bash
rg -n "SessionController#|RecordingStage|ASRStage|InjectionStage|EventTap" ~/Library/Logs/flowtype/diagnostic.log | tail -n 80
```

记录：开始/停止时间、停止→最终文字、停止→交付、结果（字面量是否保留、是否重复）、目标 app、使用的是 `swift run` 还是 `.app`。

- [ ] **Step 5: 判定 M0 门禁**

- 成功完成一次：继续 M1。
- 无法完成：把阻塞点写进证据文档，**停止本计划**，先解决权限或引擎问题；不要用代码改动掩盖环境问题。

- [ ] **Step 6: 提交**

```bash
git add docs/evidence/2026-10-22-m0-environment.md
git commit -m "docs: record m0 dictation baseline"
```

---

## M1：Readiness 与权限自愈

### Task 4: Readiness 类型与纯判定

**Files:**
- Create: `Sources/flowtype/Core/Readiness/ReadinessSnapshot.swift`
- Modify: `Sources/flowtype/Testing/SelfTest.swift`（新增 `testReadinessClassification`，并在 `runAndExit()` 注册）

**Interfaces:**
- Consumes: 无
- Produces:
  - `enum PermissionState: Equatable, Sendable { case granted, denied, notDetermined, unknown }`
  - `enum EngineReadiness: Equatable, Sendable { case ready, provisioning(progress: Double), unavailable(reason: String) }`
  - `struct ReadinessSnapshot: Equatable, Sendable`（字段：`accessibility`、`microphone`、`speechRecognition`、`localModel`、`cloudASR`、`appleSpeech`、`computedAt`）
  - `enum ReadinessIssue: Equatable, Sendable { case microphoneDenied, microphoneNotDetermined, noEngine, enginePreparing, basicOnly, accessibilityMissing }`，带 `var reason: String`
  - `enum ReadinessLevel: Equatable, Sendable { case ready, degraded(ReadinessIssue), blocked(ReadinessIssue) }`，带 `var isBlocked: Bool`、`var reason: String?`
  - `func classifyReadiness(_ s: ReadinessSnapshot) -> ReadinessLevel`

- [ ] **Step 1: 写失败测试**

在 `SelfTest.swift` 增加：

```swift
static func testReadinessClassification(_ r: Reporter) {
    func snap(microphone: PermissionState = .granted,
              accessibility: PermissionState = .granted,
              local: EngineReadiness = .unavailable(reason: "off"),
              cloud: EngineReadiness = .unavailable(reason: "off"),
              apple: EngineReadiness = .unavailable(reason: "off")) -> ReadinessSnapshot {
        ReadinessSnapshot(accessibility: accessibility, microphone: microphone,
                          speechRecognition: .granted, localModel: local,
                          cloudASR: cloud, appleSpeech: apple,
                          computedAt: Date(timeIntervalSince1970: 0))
    }
    r.eq(classifyReadiness(snap(microphone: .denied, local: .ready)),
         .blocked(.microphoneDenied), "readiness: mic denied blocks even with an engine")
    r.eq(classifyReadiness(snap()), .blocked(.noEngine), "readiness: no engine at all blocks")
    r.eq(classifyReadiness(snap(apple: .ready)), .degraded(.basicOnly),
         "readiness: Apple-only is degraded basic mode")
    r.eq(classifyReadiness(snap(local: .provisioning(progress: 0.4))),
         .degraded(.enginePreparing), "readiness: provisioning only is degraded")
    r.eq(classifyReadiness(snap(accessibility: .denied, local: .ready)),
         .degraded(.accessibilityMissing), "readiness: ready engine without AX is degraded")
    r.eq(classifyReadiness(snap(microphone: .notDetermined, local: .ready)),
         .degraded(.microphoneNotDetermined), "readiness: undecided mic may trigger the system prompt")
    r.eq(classifyReadiness(snap(local: .ready)), .ready, "readiness: local ready is ready")
    r.eq(classifyReadiness(snap(cloud: .ready)), .ready, "readiness: cloud ready is ready")
    r.eq(classifyReadiness(snap(microphone: .notDetermined)), .blocked(.noEngine),
         "readiness: engine blockers outrank an undecided mic")
    r.eq(ReadinessIssue.microphoneDenied.reason, "麦克风权限未开启",
         "readiness: mic-denied copy")
}
```

在 `runAndExit()` 的 `testSessionExperience(r)` 之前加入 `testReadinessClassification(r)`。

- [ ] **Step 2: 运行并确认失败**

Run: `swift run FlowType --self-test`
Expected: 编译失败，错误包含 `cannot find 'ReadinessSnapshot' in scope`（exit 非 0）。

- [ ] **Step 3: 实现类型与判定**

在 `ReadinessSnapshot.swift` 实现上述类型。`classifyReadiness` 按以下顺序返回：

1. `microphone == .denied` → `.blocked(.microphoneDenied)`
2. 本地、云端、Apple 都不是 `.ready`，且本地、云端都不是 `.provisioning` → `.blocked(.noEngine)`
3. 本地、云端都不是 `.ready`，但 `appleSpeech == .ready` → `.degraded(.basicOnly)`
4. 本地、云端都不是 `.ready`，但至少一个 `.provisioning` → `.degraded(.enginePreparing)`
5. 本地或云端至少一个 `.ready`，但 `accessibility != .granted` → `.degraded(.accessibilityMissing)`
6. `microphone != .granted` → `.degraded(.microphoneNotDetermined)`
7. 其余 → `.ready`

`reason` 文案固定为：`麦克风权限未开启` / `首次听写时会请求麦克风权限` / `没有可用的语音识别引擎` / `识别引擎正在准备` / `基础识别模式，准确率较低` / `全局热键不可用；可从菜单开始，结果写入剪贴板`。

- [ ] **Step 4: 运行并确认通过**

Run: `swift build`
Expected: exit 0。

Run: `swift run FlowType --self-test`
Expected: 末行 `=== self-test: N passed, 0 failed ===`，exit 0。

- [ ] **Step 5: 提交**

```bash
git add Sources/flowtype/Core/Readiness/ReadinessSnapshot.swift Sources/flowtype/Testing/SelfTest.swift
git commit -m "feat(readiness): add pure readiness classifier"
```

### Task 5: 权限状态查询与设置入口

**Files:**
- Modify: `Sources/flowtype/Utilities/PermissionHelper.swift`

**Interfaces:**
- Consumes: Task 4 的 `PermissionState`
- Produces:
  - `static func accessibilityState() -> PermissionState`
  - `static func microphoneState() -> PermissionState`
  - `static func speechRecognitionState() -> PermissionState`
  - `static func openMicrophoneSettings()`
  - `static func openSpeechRecognitionSettings()`
  - 保留现有 `checkAccessibility()`、`openAccessibilitySettings()`、`showPermissionGuide()`

- [ ] **Step 1: 实现查询与入口**

在 `PermissionHelper.swift` 顶部 `import AVFoundation`、`import Speech`。

- `accessibilityState()`：`checkAccessibility() ? .granted : .denied`。
- `microphoneState()`：把 `AVAudioApplication.shared.recordPermission` 的 `.granted / .denied / .undetermined` 映射为 `.granted / .denied / .notDetermined`，`@unknown default` → `.unknown`。
- `speechRecognitionState()`：把 `SFSpeechRecognizer.authorizationStatus()` 的 `.authorized / .denied / .restricted / .notDetermined` 映射为 `.granted / .denied / .denied / .notDetermined`，`@unknown default` → `.unknown`。
- 两个打开设置的方法分别使用：
  - `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`
  - `x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition`

不要修改 `showPermissionGuide()` 的现有行为；它只在 onboarding 中继续使用。

- [ ] **Step 2: 验证**

Run: `swift build`
Expected: exit 0。

Run: `swift run FlowType --self-test`
Expected: `0 failed`，exit 0。本任务只是系统 API 薄封装，不新增纯逻辑测试；结果由 Task 15 真机验证。

- [ ] **Step 3: 提交**

```bash
git add Sources/flowtype/Utilities/PermissionHelper.swift
git commit -m "feat(permissions): add microphone and speech state probes"
```

### Task 6: ReadinessMonitor 采集、去抖与权限轮询

**Files:**
- Create: `Sources/flowtype/Core/Readiness/ReadinessMonitor.swift`
- Modify: `Sources/flowtype/Testing/SelfTest.swift`（新增 `testPermissionWatchPolicy` 并注册）

**Interfaces:**
- Consumes: Task 4 类型与判定；Task 5 权限查询；`ConfigurationStore.shared.current`；`QwenModelState.shared.status`；`ASRRouter.shared.snapshot()`；`SFSpeechRecognizer`
- Produces:
  - `@MainActor final class ReadinessMonitor: ObservableObject`，`static let shared`
  - `@Published private(set) var snapshot: ReadinessSnapshot`
  - `@Published private(set) var level: ReadinessLevel`（3s 去抖）
  - `var rawLevel: ReadinessLevel { classifyReadiness(snapshot) }`
  - `var onAccessibilityGranted: (@MainActor @Sendable () -> Void)?`
  - `func refresh()`
  - `func startPermissionWatchIfNeeded()`
  - `func stopPermissionWatch()`
  - 顶层 `struct PermissionWatchPolicy`（放在 `ReadinessMonitor.swift` 中，不嵌套）：`static let interval: Duration = .seconds(2)`、`static let maxPolls = 30`、`nonisolated static func shouldStop(accessibility: PermissionState, pollsCompleted: Int) -> Bool`

- [ ] **Step 1: 写失败测试**

```swift
static func testPermissionWatchPolicy(_ r: Reporter) {
    r.check(PermissionWatchPolicy.shouldStop(accessibility: .granted, pollsCompleted: 0),
            "watch: granted stops immediately")
    r.check(!PermissionWatchPolicy.shouldStop(accessibility: .denied, pollsCompleted: 29),
            "watch: denied keeps polling before the cap")
    r.check(PermissionWatchPolicy.shouldStop(accessibility: .denied, pollsCompleted: 30),
            "watch: denied stops at the 60s cap")
    r.check(PermissionWatchPolicy.shouldStop(accessibility: .notDetermined, pollsCompleted: 30),
            "watch: undetermined also stops at the cap")
}
```

在 `runAndExit()` 中 `testReadinessClassification(r)` 之后注册。

- [ ] **Step 2: 运行并确认失败**

Run: `swift run FlowType --self-test`
Expected: 编译失败，`cannot find 'PermissionWatchPolicy' in scope`。

- [ ] **Step 3: 实现快照采集**

`init()` 中先计算并发布初始快照（`level = classifyReadiness(snapshot)`，不等待去抖），再订阅：

- `QwenModelState.shared.$status`
- `ConfigurationStore.shared.$current`
- `NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)`

每个订阅都调用 `Task { @MainActor in self?.refresh() }`，避免跨 actor 直接改状态。

`makeSnapshot()` 的聚合规则：

- 本地：`routingPolicy == .cloudOnly` → `.unavailable("仅云端模式")`；否则按 `QwenModelState.status`：`.ready` → `.ready`；`.downloading(p,_,_)` → `.provisioning(progress: p)`；`.loading` / `.stalled` → `.provisioning(progress: 0)`；`.notLoaded` 且 `hasCompletedOnboarding` → `.provisioning(progress: 0)`；`.notLoaded` 且未完成 onboarding → `.unavailable("本地模型未加载")`；`.error(reason,_)` → `.unavailable(reason)`。
- 云端：`routingPolicy == .localOnly` → `.unavailable("仅本地模式")`；否则要求 `effectiveCloudASRConfig` 的 key、`provider.baseURL`、`provider.model` 均非空，再按 `ASRRouter.shared.snapshot().networkReachable` 返回 `.ready` 或 `.unavailable("网络不可达")`；未配置 → `.unavailable("云端未配置")`。
- Apple：仅 `routingPolicy == .auto` 时计入；`speechRecognitionState() != .granted` → `.unavailable("语音识别权限未开启")`；`SFSpeechRecognizer(locale: Locale(identifier: config.asrLanguage.appleLocaleIdentifier))?.isAvailable != true` → `.unavailable("Apple 识别不可用")`；否则 `.ready`。

`computedAt` 使用 `Date()`。日志只在 level 变化时写一行，包含 ax / mic / local / cloud / apple 的枚举名，不写 Key 或文本。

- [ ] **Step 4: 实现去抖与轮询**

- 去抖：level 变化时启动 3s `Task`；到点后发布最新 pending 值。若候选值回到当前 `level`，取消 pending。初始值立即发布。
- `refresh()`：保存旧 AX 状态，更新 `snapshot`，`publishIfChanged(classifyReadiness(snapshot))`。旧 AX 不是 `.granted`、新 AX 是 `.granted` 时，调用 `stopPermissionWatch()` 和 `onAccessibilityGranted?()` 各一次。
- `startPermissionWatchIfNeeded()`：AX 已 granted 或已有 task 时直接返回。任务每 2s `refresh()` 一次，`pollsCompleted` 从 1 开始；`PermissionWatchPolicy.shouldStop` 为 true 时退出并将 task 置 nil。任务被取消时同样退出，不调用 callback。
- `stopPermissionWatch()`：cancel 并置 nil。
- `didBecomeActive` 只触发一次 `refresh()`，不自动重启轮询；轮询由启动、打开设置、点击「重新检测」主动启动。

交付失败后的 readiness 刷新依赖 M4 的 `FailureKind` 接线，M1 不实现；M1 已通过模型状态、配置变化、权限轮询与 `didBecomeActive` 覆盖现有刷新来源。

- [ ] **Step 5: 运行并确认通过**

Run: `swift build`
Expected: exit 0。

Run: `swift run FlowType --self-test`
Expected: `0 failed`，exit 0。

- [ ] **Step 6: 提交**

```bash
git add Sources/flowtype/Core/Readiness/ReadinessMonitor.swift Sources/flowtype/Testing/SelfTest.swift
git commit -m "feat(readiness): publish debounced readiness snapshots"
```

### Task 7: event tap 安装、修复与无条件健康检查

**Files:**
- Modify: `Sources/flowtype/WindowManager.swift`
- Modify: `Sources/flowtype/Testing/SelfTest.swift`（新增 `testEventTapHealthAction` 并注册）

**Interfaces:**
- Consumes: `PermissionHelper.checkAccessibility()`
- Produces:
  - `enum EventTapHealthAction: Equatable, Sendable { case none, enableExisting, recreate, waitForPermission }`
  - `nonisolated static func eventTapHealthAction(tapExists: Bool, tapEnabled: Bool, accessibilityTrusted: Bool) -> EventTapHealthAction`
  - `@discardableResult func installEventTap() -> Bool`
  - `func repairEventTap()`

- [ ] **Step 1: 写失败测试**

```swift
static func testEventTapHealthAction(_ r: Reporter) {
    r.eq(WindowManager.eventTapHealthAction(tapExists: true, tapEnabled: true, accessibilityTrusted: true),
         .none, "tap health: enabled tap is left alone")
    r.eq(WindowManager.eventTapHealthAction(tapExists: true, tapEnabled: false, accessibilityTrusted: true),
         .enableExisting, "tap health: disabled tap is re-enabled")
    r.eq(WindowManager.eventTapHealthAction(tapExists: false, tapEnabled: false, accessibilityTrusted: true),
         .recreate, "tap health: missing tap is recreated when trusted")
    r.eq(WindowManager.eventTapHealthAction(tapExists: false, tapEnabled: false, accessibilityTrusted: false),
         .waitForPermission, "tap health: missing tap waits without permission")
    r.eq(WindowManager.eventTapHealthAction(tapExists: true, tapEnabled: true, accessibilityTrusted: false),
         .none, "tap health: a working tap is not torn down by a false trust probe")
    r.eq(WindowManager.eventTapHealthAction(tapExists: true, tapEnabled: false, accessibilityTrusted: false),
         .enableExisting, "tap health: an existing disabled tap is still re-enabled")
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `swift run FlowType --self-test`
Expected: 编译失败，`eventTapHealthAction` 不存在。

- [ ] **Step 3: 重构 tap 生命周期**

- 新增 `private var eventTapRunLoopSource: CFRunLoopSource?`、`private var eventTapFailureCount = 0`、`private var healthTimerStarted = false`、`private var lastHealthAction: EventTapHealthAction = .none`。
- `installEventTap()`：`eventTapPort != nil` 直接返回 true（幂等）。创建失败时递增 `eventTapFailureCount`，只在第 1 次与每第 12 次写日志，返回 false。创建成功后保存 run loop source、清零失败计数、启用 tap、写成功日志，返回 true。
- `tearDownEventTap()`：从主 RunLoop 移除保存的 source，禁用并 invalidate tap，两个属性置 nil。不要再用「新建一个 source 去 remove」的旧写法。
- `repairEventTap()`：按 `eventTapHealthAction(...)` 执行。`.recreate` 先 `tearDownEventTap()` 再 `installEventTap()`；`.waitForPermission` 不反复写日志。
- `setupGlobalHotkey()`：调用 `_ = installEventTap()`，然后**无条件**调用 `startEventTapHealthCheck()`。
- `startEventTapHealthCheck()`：用 `healthTimerStarted` 防重复；5s 周期内仅当 `eventTapPort == nil` 时才调用 `PermissionHelper.checkAccessibility()`，tap 已存在时直接按「已授权」评估（避免每 5s 创建探测 tap）。按 `eventTapHealthAction` 处理，动作变化时才写日志。
- `reloadHotkey()`：保留健康定时器（不要 cancel）；work item 中 `tearDownEventTap()` 后 `installEventTap()`，仍重置缓存的按键边沿状态。

- [ ] **Step 4: 运行并确认通过**

Run: `swift build`
Expected: exit 0。

Run: `swift run FlowType --self-test`
Expected: `0 failed`，exit 0。

- [ ] **Step 5: 手动冒烟**

在有 AX 权限的环境启动应用，然后：

```bash
rg -n "\[WindowManager\]|\[EventTap\]" ~/Library/Logs/flowtype/diagnostic.log | tail -n 30
```

Expected: 5s 健康检查周期内没有反复 `re-creating`；tap 正常时只有一次创建日志。

- [ ] **Step 6: 提交**

```bash
git add Sources/flowtype/WindowManager.swift Sources/flowtype/Testing/SelfTest.swift
git commit -m "fix(hotkey): install and repair event tap after permission grant"
```

### Task 8: 就绪修复动作与错误卡片接线

**Files:**
- Modify: `Sources/flowtype/Core/PipelineOrchestrator.swift`
- Modify: `Sources/flowtype/CapsuleView.swift`
- Modify: `Sources/flowtype/App/StatusBarController.swift`（把 `openSettings` 变为可带 tab 的内部方法）
- Modify: `Sources/flowtype/Settings/SettingsWindowController.swift`
- Modify: `Sources/flowtype/Settings/MainWindowView.swift`
- Modify: `Sources/flowtype/Testing/SelfTest.swift`（新增 `testReadinessRecoveryActions` 并注册）

**Interfaces:**
- Consumes: Task 4 的 `ReadinessIssue`；Task 6 的 `ReadinessMonitor.shared`；Task 5 的设置入口
- Produces:
  - `ErrorAction` 新增 `openAccessibilitySettings`、`openMicrophoneSettings`、`openASRSettings`、`recheckReadiness`、`useAutomaticRouting`
  - `nonisolated static func SessionController.readinessActions(for issue: ReadinessIssue, policy: ASRRoutingPolicy) -> [ErrorAction]`
  - `SessionController.recheckReadiness()`
  - `SessionController.useAutomaticRouting()`
  - `StatusBarController.openSettings(tab: AppTab = .settings)`
  - `SettingsWindowController.init(initialTab: AppTab = .overview)`；`MainWindowView.init(initialTab: AppTab = .overview)`

- [ ] **Step 1: 写失败测试**

```swift
static func testReadinessRecoveryActions(_ r: Reporter) {
    r.eq(SessionController.readinessActions(for: .microphoneDenied, policy: .auto),
         [.openMicrophoneSettings, .recheckReadiness, .dismiss],
         "readiness actions: mic denied opens the mic pane")
    r.eq(SessionController.readinessActions(for: .noEngine, policy: .auto),
         [.openASRSettings, .recheckReadiness, .dismiss],
         "readiness actions: no engine opens ASR settings")
    r.eq(SessionController.readinessActions(for: .noEngine, policy: .localOnly),
         [.openASRSettings, .useAutomaticRouting, .dismiss],
         "readiness actions: constrained routing offers automatic routing")
    r.eq(ErrorAction.openAccessibilitySettings.displayName, "打开辅助功能设置",
         "readiness actions: AX action copy")
    r.eq(ErrorAction.openMicrophoneSettings.displayName, "打开麦克风设置",
         "readiness actions: mic action copy")
    r.eq(ErrorAction.openASRSettings.displayName, "打开 ASR 设置",
         "readiness actions: ASR action copy")
    r.eq(ErrorAction.recheckReadiness.displayName, "重新检测",
         "readiness actions: recheck copy")
    r.eq(ErrorAction.useAutomaticRouting.displayName, "改为自动路由",
         "readiness actions: reroute copy")
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `swift run FlowType --self-test`
Expected: 编译失败，缺少新 `ErrorAction` case / `readinessActions`。

- [ ] **Step 3: 扩展 `ErrorAction` 与映射**

在 `ErrorAction` 增加上述 5 个 case 和 `displayName`。映射：

- `.microphoneDenied` → `[.openMicrophoneSettings, .recheckReadiness, .dismiss]`
- `.noEngine` + `policy == .auto` → `[.openASRSettings, .recheckReadiness, .dismiss]`
- `.noEngine` + 其他 policy → `[.openASRSettings, .useAutomaticRouting, .dismiss]`
- `.accessibilityMissing` → `[.openAccessibilitySettings, .recheckReadiness, .dismiss]`
- 其余 issue → `[.recheckReadiness, .dismiss]`

`recheckReadiness()`：调用 `ReadinessMonitor.shared.refresh()`；若 `rawLevel` 不再是 `.blocked`，`dismissError()` 回到 idle；仍然 blocked 时保持卡片不动，只写日志。

`useAutomaticRouting()`：用 `var config = ConfigurationStore.shared.current` 修改 `asrRoutingPolicy = .auto`，通过 `ConfigurationStore.shared.save(config)` 持久化（直接赋值不会落盘），再 `ReadinessMonitor.shared.refresh()`，并在 `.error` 状态下 `dismissError()`。

本里程碑不实现模型失败态的「重试加载模型」动作（spec §4.3.2）：它依赖 M2 的 `ModelProvisionError` 与卡片重试路径；M1 先提供「打开 ASR 设置 / 重新检测」。

- [ ] **Step 4: 接 UI**

- `CapsuleView` 的按钮 switch 补全：打开辅助功能设置 → `PermissionHelper.openAccessibilitySettings()` 后调用 `ReadinessMonitor.shared.startPermissionWatchIfNeeded()`；打开麦克风设置；打开 ASR 设置 → `StatusBarController.shared.openSettings(tab: .settings)`；重新检测 → `session.recheckReadiness()`；改为自动路由 → `session.useAutomaticRouting()`。
- `MainWindowView` 用 `@State private var selectedTab` + `init(initialTab: AppTab = .overview)` 支持初始页；`SettingsWindowController` 把该参数传给 `MainWindowView`。
- `StatusBarController` 增加 `func openSettings(tab: AppTab = .settings)`，并把现有 `@objc private func openSettings()` 重命名为 `@objc private func showSettings()`，由它调用 `openSettings(tab: .settings)`；否则同名无参方法会与默认参数重载冲突。菜单里的「显示 Flowtype」改指向 `showSettings`。本任务不改变菜单其它行为。

- [ ] **Step 5: 运行并确认通过**

Run: `swift build`
Expected: exit 0。

Run: `swift run FlowType --self-test`
Expected: `0 failed`，exit 0。

- [ ] **Step 6: 提交**

```bash
git add Sources/flowtype/Core/PipelineOrchestrator.swift Sources/flowtype/CapsuleView.swift \
  Sources/flowtype/App/StatusBarController.swift Sources/flowtype/Settings/SettingsWindowController.swift \
  Sources/flowtype/Settings/MainWindowView.swift Sources/flowtype/Testing/SelfTest.swift
git commit -m "feat(recovery): add readiness repair actions"
```

### Task 9: 录音前置检查与降级提示

**Files:**
- Modify: `Sources/flowtype/Core/PipelineOrchestrator.swift`
- Modify: `Sources/flowtype/CapsuleView.swift`
- Modify: `Sources/flowtype/Testing/SelfTest.swift`（新增 `testReadinessPreflight` 并注册）

**Interfaces:**
- Consumes: Task 4 的 `classifyReadiness` / `ReadinessLevel`；Task 6 的 `ReadinessMonitor.shared.rawLevel`；Task 8 的 `readinessActions`
- Produces:
  - `SessionController.init(... readinessLevel: @escaping @MainActor @Sendable () -> ReadinessLevel = { ReadinessMonitor.shared.refresh(); return ReadinessMonitor.shared.rawLevel })`（默认实现在读取前刷新，满足「录音前刷新」触发条件）
  - `@Published private(set) var preparationNotice: String?`
  - `nonisolated static func readinessPreflight(_ level: ReadinessLevel) -> ReadinessIssue?`
  - `nonisolated static func preparationSubtitle(for level: ReadinessLevel) -> String?`

- [ ] **Step 1: 写失败测试**

```swift
@MainActor
static func testReadinessPreflight(_ r: Reporter) async {
    let quiet = SessionEffects(prepare: {}, showWindow: {}, hideWindow: {}, saveHistory: { _ in })
    let blocked = SessionController(pipeline: [], observers: [], effects: quiet,
                                    readinessLevel: { .blocked(.noEngine) })
    blocked.startRecording()
    r.eq(blocked.sessionState, .error(ReadinessIssue.noEngine.reason),
         "preflight: blocked readiness enters error immediately")
    r.eq(blocked.errorActions.first, .openASRSettings,
         "preflight: blocked actions lead with the ASR settings repair")
    r.check(blocked.errorActions.contains(.dismiss),
            "preflight: blocked actions remain dismissible")
    blocked.dismissError()
    r.eq(blocked.sessionState, .idle, "preflight: dismiss returns to idle")

    r.eq(SessionController.readinessPreflight(.degraded(.basicOnly)), nil,
         "preflight: degraded readiness is allowed")
    r.eq(SessionController.readinessPreflight(.blocked(.microphoneDenied)), .microphoneDenied,
         "preflight: blocked mic is reported")
    r.eq(SessionController.preparationSubtitle(for: .degraded(.basicOnly)),
         "基础模式 · 准确率较低", "preflight: basic mode is labelled")
    r.eq(SessionController.preparationSubtitle(for: .degraded(.accessibilityMissing)),
         "无辅助功能 · 结果将复制", "preflight: no-AX is labelled")
    r.eq(SessionController.preparationSubtitle(for: .degraded(.enginePreparing)),
         "识别引擎准备中", "preflight: provisioning is labelled")
    r.eq(SessionController.preparationSubtitle(for: .ready), nil,
         "preflight: ready has no subtitle")
}
```

在 `runAndExit()` 中 `await testReadinessPreflight(r)`，放在 `testSessionExperience(r)` 之前。

- [ ] **Step 2: 运行并确认失败**

Run: `swift run FlowType --self-test`
Expected: 编译失败，`readinessLevel` 参数 / `readinessPreflight` 不存在。

- [ ] **Step 3: 实现前置检查**

在 `SessionController` 存储 `private let readinessLevel: @MainActor @Sendable () -> ReadinessLevel`，init 末尾赋值。

`startRecording()` 复用现有清理流程，在 `currentContext = context` 之后、创建 `stateCancellable` 之前插入：

```swift
let readiness = readinessLevel()
if let issue = Self.readinessPreflight(readiness) {
    presentReadinessBlocked(issue, context: context)
    return
}
preparationNotice = Self.preparationSubtitle(for: readiness)
```

此时 `activeSessionID` 已指向 `newID`、旧 context 已取消、`clearSuspension()` 已执行，因此不需要重复清理，也不会执行任何 stage。

`presentReadinessBlocked(_ issue: ReadinessIssue, context: SessionContext)`：

- 取消 `errorDismissTask` 与 `currentTask` 并置 nil；
- `lastErrorRawText = nil`；
- `errorActions = Self.readinessActions(for: issue, policy: ConfigurationStore.shared.current.asrRoutingPolicy)`；
- `transition(to: .error(issue.reason), context: context)`。

不要调用 `effects.prepare()`，不要 `executeStage`，不要开始录音；`transition` 会按现有逻辑显示面板。

`preparationSubtitle(for:)` 返回：`.degraded(.basicOnly)` → `基础模式 · 准确率较低`；`.degraded(.accessibilityMissing)` → `无辅助功能 · 结果将复制`；`.degraded(.enginePreparing)` → `识别引擎准备中`；`.degraded(.microphoneNotDetermined)` → `首次使用 · 将请求麦克风权限`；其余（含 `.ready`、`.blocked`）→ nil。

`resetToIdle()` 清空 `preparationNotice`；`readinessPublisher` 的 sink 在转入 `.recording` 前也清空它。`CapsuleView` 的 `.preparing` 副标题改为 `session.preparationNotice ?? "正在准备麦克风..."`。

- [ ] **Step 4: 运行并确认通过**

Run: `swift build`
Expected: exit 0。

Run: `swift run FlowType --self-test`
Expected: `0 failed`，exit 0。

- [ ] **Step 5: 提交**

```bash
git add Sources/flowtype/Core/PipelineOrchestrator.swift Sources/flowtype/CapsuleView.swift \
  Sources/flowtype/Testing/SelfTest.swift
git commit -m "feat(session): block recording when readiness is blocked"
```

### Task 10: 非模态权限提醒浮层

**Files:**
- Create: `Sources/flowtype/UI/PermissionReminderPanel.swift`
- Modify: `Sources/flowtype/Utilities/SoundFeedback.swift`
- Modify: `Sources/flowtype/Testing/SelfTest.swift`（新增 `testPermissionReminderPolicy` 并注册）

**Interfaces:**
- Consumes: Task 4 的 `PermissionState`；Task 5 的 `openAccessibilitySettings()`；Task 6 的 `startPermissionWatchIfNeeded()`
- Produces:
  - `@MainActor final class PermissionReminderController`，`static let shared`
  - `nonisolated static func shouldShow(accessibility: PermissionState, hasShownThisLaunch: Bool) -> Bool`
  - `func showIfNeeded(accessibility: PermissionState)`
  - `func showRestored()`
  - `func dismiss()`
  - `SoundFeedback.playPermissionGranted()`

- [ ] **Step 1: 写失败测试**

```swift
static func testPermissionReminderPolicy(_ r: Reporter) {
    r.check(!PermissionReminderController.shouldShow(accessibility: .granted, hasShownThisLaunch: false),
            "reminder: granted never shows")
    r.check(PermissionReminderController.shouldShow(accessibility: .denied, hasShownThisLaunch: false),
            "reminder: denied shows once")
    r.check(PermissionReminderController.shouldShow(accessibility: .notDetermined, hasShownThisLaunch: false),
            "reminder: undetermined shows once")
    r.check(!PermissionReminderController.shouldShow(accessibility: .denied, hasShownThisLaunch: true),
            "reminder: manual dismissal suppresses later reminders this launch")
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `swift run FlowType --self-test`
Expected: 编译失败，`PermissionReminderController` 不存在。

- [ ] **Step 3: 实现浮层**

- `NSPanel`：`[.borderless, .nonactivatingPanel]`、`level = .floating`、`isOpaque = false`、`backgroundColor = .clear`、`hasShadow = true`、`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`，尺寸 360×96，底部居中，位于胶囊上方约 130pt。
- SwiftUI 内容：`VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)` + 圆角 16、白色标题与一行说明。权限提醒文案：「需要辅助功能权限」「开启后才能用全局热键；也可以从菜单开始听写。」；按钮「打开设置」「稍后」。恢复文案：「辅助功能权限已生效」，无按钮。
- 「打开设置」：`PermissionHelper.openAccessibilitySettings()` 后 `ReadinessMonitor.shared.startPermissionWatchIfNeeded()`，再 `dismiss()`。
- 「稍后」：`dismiss()`。
- 权限提醒 20s 自动 `dismiss()`；恢复提示 2.5s 自动 `dismiss()`。
- 首次展示时把 `shownThisLaunch` 置 true；`dismiss()` 不重置它。`shouldShow` = `!hasShownThisLaunch && accessibility != .granted`。
- `showRestored()` 不受 `shownThisLaunch` 限制，但不重复叠加，复用同一个 panel 并替换内容。
- `SoundFeedback.playPermissionGranted()` 使用 `AudioServicesPlaySystemSound(1054)`，并遵循 `isEnabled`。

- [ ] **Step 4: 运行并确认通过**

Run: `swift build`
Expected: exit 0。

Run: `swift run FlowType --self-test`
Expected: `0 failed`，exit 0。

- [ ] **Step 5: 提交**

```bash
git add Sources/flowtype/UI/PermissionReminderPanel.swift Sources/flowtype/Utilities/SoundFeedback.swift \
  Sources/flowtype/Testing/SelfTest.swift
git commit -m "feat(ui): add non-modal permission reminder"
```

### Task 11: 状态栏就绪展示、菜单修复与开始/停止听写

**Files:**
- Modify: `Sources/flowtype/App/StatusBarController.swift`
- Modify: `Sources/flowtype/Core/Readiness/ReadinessSnapshot.swift`（新增纯展示函数）
- Modify: `Sources/flowtype/Testing/SelfTest.swift`（新增 `testReadinessPresentation` 并注册）

**Interfaces:**
- Consumes: Task 4 类型；Task 6 `ReadinessMonitor`；Task 7 `WindowManager.repairEventTap()`；Task 8 `openSettings(tab:)`
- Produces:
  - `func readinessMenuTitle(_ s: ReadinessSnapshot) -> String`
  - `nonisolated static func StatusBarController.dictationMenuTitle(for state: SessionState) -> String`
  - `nonisolated static func StatusBarController.dictationMenuEnabled(for state: SessionState) -> Bool`

- [ ] **Step 1: 写失败测试**

```swift
static func testReadinessPresentation(_ r: Reporter) {
    func snap(microphone: PermissionState = .granted, accessibility: PermissionState = .granted,
              local: EngineReadiness = .unavailable(reason: "off"),
              cloud: EngineReadiness = .unavailable(reason: "off"),
              apple: EngineReadiness = .unavailable(reason: "off")) -> ReadinessSnapshot {
        ReadinessSnapshot(accessibility: accessibility, microphone: microphone,
                          speechRecognition: .granted, localModel: local,
                          cloudASR: cloud, appleSpeech: apple,
                          computedAt: Date(timeIntervalSince1970: 0))
    }
    r.eq(readinessMenuTitle(snap(microphone: .denied)),
         "修复：麦克风权限未开启…", "menu: mic blocked title")
    r.eq(readinessMenuTitle(snap()), "修复：没有可用的语音识别引擎…",
         "menu: no-engine title")
    r.eq(readinessMenuTitle(snap(apple: .ready)), "识别：Apple 基础模式（准确率较低）",
         "menu: Apple basic title")
    r.eq(readinessMenuTitle(snap(local: .provisioning(progress: 0.2))), "识别：引擎准备中",
         "menu: preparing title")
    r.eq(readinessMenuTitle(snap(accessibility: .denied, local: .ready)),
         "识别：已就绪（无辅助功能，结果写入剪贴板）", "menu: no-AX title")
    r.eq(readinessMenuTitle(snap(microphone: .notDetermined, local: .ready)),
         "识别：首次听写将请求麦克风权限", "menu: undecided mic title")
    r.eq(readinessMenuTitle(snap(local: .ready, cloud: .ready)), "识别：云端 → 本地模型",
         "menu: cloud-first chain title")
    r.eq(readinessMenuTitle(snap(local: .ready)), "识别：本地模型", "menu: local title")
    r.eq(StatusBarController.dictationMenuTitle(for: .idle), "开始听写", "menu: idle starts")
    r.eq(StatusBarController.dictationMenuTitle(for: .recording(elapsedSeconds: 1)), "停止听写",
         "menu: recording stops")
    r.eq(StatusBarController.dictationMenuTitle(for: .processing(provider: "x")), "处理中…",
         "menu: processing is not clickable text")
    r.check(!StatusBarController.dictationMenuEnabled(for: .processing(provider: "x")),
            "menu: processing disables the dictation item")
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `swift run FlowType --self-test`
Expected: 编译失败，`readinessMenuTitle` / `dictationMenuTitle` 不存在。

- [ ] **Step 3: 实现纯展示函数**

`readinessMenuTitle` 基于 `classifyReadiness`：

- `.blocked(.microphoneDenied)` → `修复：麦克风权限未开启…`
- `.blocked(.noEngine)` → `修复：没有可用的语音识别引擎…`
- `.blocked` 其它 → `修复：<reason>…`
- `.degraded(.basicOnly)` → `识别：Apple 基础模式（准确率较低）`
- `.degraded(.enginePreparing)` → `识别：引擎准备中`
- `.degraded(.accessibilityMissing)` → `识别：已就绪（无辅助功能，结果写入剪贴板）`
- `.degraded(.microphoneNotDetermined)` → `识别：首次听写将请求麦克风权限`
- `.ready`：cloud+local ready → `识别：云端 → 本地模型`；cloud only → `识别：云端`；local only → `识别：本地模型`；否则 `识别：就绪`

`dictationMenuTitle`：preparing/recording → `停止听写`；processing/polishing/injecting → `处理中…`；其余 → `开始听写`。`dictationMenuEnabled` 仅对 processing/polishing/injecting 返回 false。

- [ ] **Step 4: 接线状态栏**

- `setup()` 保存原始状态图标，订阅 `ReadinessMonitor.shared.$level`：ready 用原图标；degraded 用 `exclamationmark.triangle.fill` + `.systemOrange`；blocked 用 `xmark.circle.fill` + `.systemRed`。tooltip 用 readiness 标题。
- 删除按模型状态覆盖 tooltip 的 `updateIdleTooltip()` / `modelCancellable`；idle tooltip 统一由 readiness 决定，录音/处理/错误状态仍显示会话文案。
- 菜单第一项改为可点击的 readiness 项，标题来自 `readinessMenuTitle`；blocked 或 `.degraded(.accessibilityMissing)` 时启用，其余禁用。点击时：麦克风 blocked → 打开麦克风设置；引擎 blocked → `openSettings(tab: .settings)`；AX 缺失 → 打开辅助功能设置并 `startPermissionWatchIfNeeded()`。
- 第一项之后加「开始听写 / 停止听写」项，动作按 `SessionController.sessionState` 调用 `startRecording()` 或 `endRecording()`；processing 等状态禁用。
- 「检查权限」改名为「重新检测权限」：`ReadinessMonitor.shared.refresh()` + `WindowManager.shared.repairEventTap()` + `ReadinessMonitor.shared.startPermissionWatchIfNeeded()`，不再弹 `NSAlert`。
- `menuWillOpen` 先 `ReadinessMonitor.shared.refresh()`，再刷新 readiness 标题与听写项标题/可用性。

- [ ] **Step 5: 运行并确认通过**

Run: `swift build`
Expected: exit 0。

Run: `swift run FlowType --self-test`
Expected: `0 failed`，exit 0。

- [ ] **Step 6: 提交**

```bash
git add Sources/flowtype/App/StatusBarController.swift \
  Sources/flowtype/Core/Readiness/ReadinessSnapshot.swift \
  Sources/flowtype/Testing/SelfTest.swift
git commit -m "feat(statusbar): surface readiness and dictation controls"
```

### Task 12: 启动流程改为非模态就绪流程

**Files:**
- Modify: `Sources/flowtype/App/FlowTypeApp.swift`

**Interfaces:**
- Consumes: Task 6 `ReadinessMonitor`；Task 7 `WindowManager.repairEventTap()`；Task 10 `PermissionReminderController` / `SoundFeedback.playPermissionGranted()`
- Produces: 启动时无阻塞弹窗；AX 缺失时启动轮询与非模态提醒；授权后自动修复 tap

- [ ] **Step 1: 替换启动权限逻辑**

`applicationDidFinishLaunching` 中：

1. `StatusBarController.shared.setup()` 之后先设置一次 callback（早于任何 refresh，避免漏掉首次授权）：

```swift
ReadinessMonitor.shared.onAccessibilityGranted = {
    WindowManager.shared.repairEventTap()
    PermissionReminderController.shared.showRestored()
    SoundFeedback.playPermissionGranted()
}
```

2. 调用 `ReadinessMonitor.shared.refresh()`。
3. 再调用 `WindowManager.shared.setupGlobalHotkey()`（其内部已无条件启动健康检查）。
4. 删除 `PermissionHelper.showPermissionGuide()` 的启动调用；不要改动 onboarding 分支和末尾的 `loadQwenASRModel()` Task。
5. 若 `hasCompletedOnboarding` 为 true 且 `snapshot.accessibility != .granted`：
   - `PermissionReminderController.shared.showIfNeeded(accessibility:)`
   - `ReadinessMonitor.shared.startPermissionWatchIfNeeded()`

onboarding 未完成时保持现有 onboarding 流程，不显示提醒浮层。

- [ ] **Step 2: 验证**

Run: `swift build`
Expected: exit 0。

Run: `swift run FlowType --self-test`
Expected: `0 failed`，exit 0。

手动：在有 AX 权限时启动，确认没有权限弹窗；在无 AX 权限时启动，确认出现底部浮层且应用可交互、菜单可打开。

- [ ] **Step 3: 提交**

```bash
git add Sources/flowtype/App/FlowTypeApp.swift
git commit -m "refactor(app): replace launch permission alert with readiness flow"
```

### Task 13: 麦克风权限错误结构化

**Files:**
- Modify: `Sources/flowtype/Utilities/PermissionHelper.swift`（新增 `PermissionError`）
- Modify: `Sources/flowtype/Core/Pipeline/Stages/RecordingStage.swift`
- Modify: `Sources/flowtype/Core/PipelineOrchestrator.swift`（`buildErrorActions` 特判）
- Modify: `Sources/flowtype/Testing/SelfTest.swift`（新增 `testPermissionErrorActions` 并注册）

**Interfaces:**
- Consumes: Task 8 的 `ErrorAction.openMicrophoneSettings` / `.recheckReadiness`
- Produces:
  - `enum PermissionError: LocalizedError, Equatable { case microphoneDenied }`
  - `RecordingStage` 在授权失败时返回 `PermissionError.microphoneDenied`
  - `buildErrorActions` 对 `PermissionError` 返回 `[.openMicrophoneSettings, .recheckReadiness, .dismiss]`

- [ ] **Step 1: 写失败测试**

```swift
static func testPermissionErrorActions(_ r: Reporter) {
    let recovery = ErrorRecoveryContext(failedStage: "Recording",
                                        error: PermissionError.microphoneDenied,
                                        rawText: nil, retryable: false)
    r.eq(SessionController.buildErrorActions(from: recovery),
         [.openMicrophoneSettings, .recheckReadiness, .dismiss],
         "mic error: permission failure is actionable, not a notice")
    r.check(PermissionError.microphoneDenied.errorDescription?.contains("麦克风") == true,
            "mic error: copy names the microphone permission")
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `swift run FlowType --self-test`
Expected: 编译失败，`PermissionError` 不存在。

- [ ] **Step 3: 实现**

- `PermissionError` 放在 `PermissionHelper.swift`：`errorDescription` 为「麦克风权限未开启。请前往「系统设置 → 隐私与安全性 → 麦克风」，找到 Flowtype 并开启。」
- `RecordingStage` 的权限失败分支改用 `PermissionError.microphoneDenied`，删除未使用的 `micPermissionMessage(status:)`；日志仍记录原始 `authorizationStatus()`。
- `buildErrorActions` 在 `CancellationError` 判断之后、`retryable || hasText` 守卫之前：

```swift
if recovery.error is PermissionError {
    return [.openMicrophoneSettings, .recheckReadiness, .dismiss]
}
```

M4 引入 `FailureKind` 后，这个特判收敛为 `.permission(.microphone)`；M1 不新增 `FailureKind`。

- [ ] **Step 4: 运行并确认通过**

Run: `swift build`
Expected: exit 0。

Run: `swift run FlowType --self-test`
Expected: `0 failed`，exit 0。

- [ ] **Step 5: 提交**

```bash
git add Sources/flowtype/Utilities/PermissionHelper.swift \
  Sources/flowtype/Core/Pipeline/Stages/RecordingStage.swift \
  Sources/flowtype/Core/PipelineOrchestrator.swift Sources/flowtype/Testing/SelfTest.swift
git commit -m "fix(recording): surface structured microphone permission errors"
```

### Task 14: 无辅助功能时交付降级为剪贴板

**Files:**
- Modify: `Sources/flowtype/Services/Delivery/DeliveryContract.swift`
- Modify: `Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift`
- Modify: `Sources/flowtype/Testing/SelfTest.swift`（扩展 `testInjectionDecision`）

**Interfaces:**
- Consumes: `InjectionDecision`、`PermissionHelper.checkAccessibility()`
- Produces:
  - `func applyAccessibilityGate(_ decision: InjectionDecision, accessibilityTrusted: Bool) -> InjectionDecision`
  - `InjectionStage.init(..., accessibilityTrusted: @escaping @MainActor @Sendable () -> Bool = { PermissionHelper.checkAccessibility() })`

- [ ] **Step 1: 写失败测试**

在 `testInjectionDecision` 末尾追加：

```swift
r.eq(applyAccessibilityGate(.inject, accessibilityTrusted: false), .clipboard,
     "inject: no AX downgrades typing to clipboard")
r.eq(applyAccessibilityGate(.clipboard, accessibilityTrusted: false), .clipboard,
     "inject: no AX keeps an existing clipboard decision")
r.eq(applyAccessibilityGate(.inject, accessibilityTrusted: true), .inject,
     "inject: AX trust preserves typing")
r.eq(applyAccessibilityGate(.clipboard, accessibilityTrusted: true), .clipboard,
     "inject: AX trust does not turn clipboard into typing")
```

- [ ] **Step 2: 运行并确认失败**

Run: `swift run FlowType --self-test`
Expected: 编译失败，`applyAccessibilityGate` 不存在。

- [ ] **Step 3: 实现闸门**

在 `DeliveryContract.swift` 增加：

```swift
func applyAccessibilityGate(_ decision: InjectionDecision, accessibilityTrusted: Bool) -> InjectionDecision {
    decision == .inject && !accessibilityTrusted ? .clipboard : decision
}
```

在 `InjectionStage` 增加存储属性与 init 参数 `accessibilityTrusted`（默认 `{ PermissionHelper.checkAccessibility() }`），在 `execute` 中 `let outcome: DeliveryOutcome` 之前：

```swift
let trusted = await MainActor.run { accessibilityTrusted() }
let decision = applyAccessibilityGate(decideDelivery(target: target, current: current),
                                      accessibilityTrusted: trusted)
switch decision { ... }
```

其余分支保持不变。这样无 AX 时不会发出任何按键，文本走已有的剪贴板事务与「已复制」提示。

同时给 `SelfTest.swift` 中**每一处** `InjectionStage(` 构造传入 `accessibilityTrusted: { true }`（包括 `testSessionRecoveryDelivery`、`testDeliveryModeStage`、`testDeliveryContract` 里的全部用例），否则无 AX 的测试机上的既有交付断言会被真实权限闸门改成 clipboard。生产路径 `PipelineRegistry` 不传该参数，使用 live 实现。

- [ ] **Step 4: 运行并确认通过**

Run: `swift build`
Expected: exit 0。

Run: `swift run FlowType --self-test`
Expected: `0 failed`，exit 0。

- [ ] **Step 5: 提交**

```bash
git add Sources/flowtype/Services/Delivery/DeliveryContract.swift \
  Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift Sources/flowtype/Testing/SelfTest.swift
git commit -m "fix(delivery): copy instead of typing without accessibility"
```

### Task 15: M1 真机验收与证据

**Files:**
- Create: `docs/evidence/2026-10-22-m1-readiness.md`
- Modify: `docs/2026-10-14-flowtype-product-validation.md`（仅更新实际执行过的 P1 / P3 行文案与状态；未执行的行保持 Pending）

**Interfaces:**
- Consumes: M0 的权限与引擎环境；M1 全部代码
- Produces: §7.2（权限自愈）与 §7.3（无引擎前置错误）的真机证据；失败项带日志与复现步骤

- [ ] **Step 1: 构建并固定 app 身份**

```bash
./scripts/build-app.sh
codesign -dv --verbose=4 build/Flowtype.app 2>&1 | rg 'Identifier|Authority|Signature'
```

记录本次 SHA、构建时间、bundle 路径。验证期间不要重新构建，否则 ad-hoc 签名变化可能导致 TCC 权限失效。

- [ ] **Step 2: 执行 M1 用例**

每条用例记录日期、SHA、macOS 版本、app 路径、权限初始状态、操作、观察结果、日志 session id：

- **M1-1 无 AX 启动**：状态栏为红色 `xmark.circle.fill`，菜单首项为「修复：…」，没有阻塞弹窗，底部出现提醒浮层。关闭浮层后菜单仍可打开。
- **M1-2 热键可用但无引擎**：AX 已授予，设置 `auto` 策略，清空云端 ASR，确保本地模型不可用，并拒绝 Speech Recognition。按热键 → 立即出现 `.error`，包含「打开 ASR 设置」「重新检测」；麦克风没有被打开（日志无 `RecordingStage` 启动），状态不进入 processing。
- **M1-3 运行中授权**：保持应用运行，在系统设置勾选 FlowType，回到应用。≤5s 内状态栏恢复正常、日志出现 tap 修复、底部显示「辅助功能权限已生效」并有提示音；按热键可正常开始。
- **M1-4 麦克风被拒绝**：AX 保持授予，在系统设置关闭 FlowType 的麦克风权限，按热键 → 出现「打开麦克风设置」「重新检测」「忽略」；点「打开麦克风设置」到达正确面板；重新开启后点「重新检测」，卡片消失，再次按热键可录音。
- **M1-5 受限策略下无引擎**：设置 `localOnly`，确保本地模型不可用；在系统设置拒绝 Speech Recognition。按热键 → 立即出现 `.error`，包含「打开 ASR 设置」「改为自动路由」「忽略」；点「改为自动路由」后配置持久化为 `auto`，重新检测不再 blocked（云端已配置时）。无录音、无 processing。
- **M1-6 无 AX 菜单听写**：撤销 AX 后重启应用，用菜单「开始听写」录音、菜单「停止听写」结束；文字以剪贴板交付，UI 显示已复制；粘贴到 TextEdit 后内容完整。
- **M1-7 状态变化不闪断**：模型处于 downloading / loading 时观察菜单首项与状态栏；进入 ready 或 error 后 3s 内状态稳定，不出现 blocked 闪烁或卡死。

- [ ] **Step 3: 写证据文档**

每条用例写：`Pass / Fail / Pending`、实际事件顺序、期望与实际差异、日志摘录（只保留 `[Readiness]`、`[WindowManager]`、`[SessionController#...]` 等与结论相关的行）、失败时的复现步骤。不要写 API Key、配置 JSON 或听写原文。

- [ ] **Step 4: 更新验证矩阵**

仅当 P1（麦克风拒绝）和 P3（辅助功能）实际执行且符合新的可操作错误行为时：

- 更新 P1 的 acceptance 文案为「出现带『打开麦克风设置 / 重新检测』的错误；授权后新会话可录音」。
- 更新 P3 的 acceptance 文案为「缺 AX 不阻塞启动；运行中授权后热键自动恢复；无 AX 时交付明确走剪贴板」。
- 把对应行状态改为 `Pass`，并在行内注明证据文档路径。

未执行或不满足的行保持 `Pending`，不得用自动化结果代替真机观察。

- [ ] **Step 5: 最终验证**

Run: `swift build`
Expected: exit 0。

Run: `swift run FlowType --self-test`
Expected: `=== self-test: N passed, 0 failed ===`，exit 0。

- [ ] **Step 6: 提交**

```bash
git add docs/evidence/2026-10-22-m1-readiness.md docs/2026-10-14-flowtype-product-validation.md
git commit -m "docs: record m1 readiness validation"
```

---

## M1 完成定义

- Task 1–15 全部完成并提交；M0 门禁未通过时整个计划停止。
- `swift build` 与 `swift run FlowType --self-test` 全绿。
- §7.2 权限自愈与 §7.3 无引擎前置错误在真机上通过，证据文档包含 SHA、环境、日志与结果。
- 状态栏、菜单、录音前置检查读取同一份 `ReadinessMonitor` 快照；启动路径没有阻塞式权限弹窗。
- 未实现 M2 的模型修复、M3 的自动交付、M4 的 `FailureKind`、M5 的 smoke/BuildInfo/CI；这些仍按 spec 的里程碑单独规划。
