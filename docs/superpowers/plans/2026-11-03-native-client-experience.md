# Native Client Experience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将已确认的 macOS 客户端设计落地为紧凑、清晰的原生页面，并连接真实配置、模型、权限、会话和持久化状态。

**Architecture:** 延用 SwiftUI 与 M1–M5 服务，页面只负责展示和显式动作。增加导航目的地、服务编辑草稿、配置副作用适配和试说隔离边界；不重写 ASR、交付、恢复或统计引擎。先落实状态合同，再接页面，最后统一原生布局与候选版本验收。

**Tech Stack:** Swift 6.2、macOS 15+、SwiftUI／AppKit、Combine、现有 GRDB 和 SelfTest；不增加依赖。

**Spec:** [已确认设计](../specs/2026-11-03-native-client-experience-design.md)；[归档交互原型](../prototypes/2026-11-03-native-client.html)。原型数据均为示例，不能进入产品统计。

执行状态：Tasks 1–11 及集中修复已实现并完成独立审查。候选 code／artifact 结果和源码身份见[验收记录](../validation/2026-11-03-native-client-acceptance.md)。未勾选项为尚未执行的真机／远端验收；41 项人工矩阵及 remoteCI 保持 Pending。

## Global Constraints

- 主导航保持「概览／历史／词典／风格／设置」；设置分为「语音识别／文本整理／通用／权限与隐私」。
- 最小窗口 1040×700pt，初始窗口 1120×760pt，侧栏 176pt；有效内容最大宽度 844pt，左右内边距各 28pt，总占位最大 900pt。
- 标题约 18pt，正文／控件 12–13pt，说明 11–12pt，图轴 10–11pt，统计数字 28–31pt；主内容纵向滚动，不整体缩放。
- 不透明中性色、克制紫色、少量暖色成就；浅／深／随系统、键盘焦点、减少动态效果。去掉英文口号、背景纹样、重复状态条和装饰卡片堆叠。
- 模式控件靠左、按内容定宽，约 276×40pt；非当前模式配置可折叠展开，不删除配置。
- “仅本地”只约束 ASR；云端整理独立。保留上下文偏好，禁用控件不清值。区分已选服务、已加载模型与会话实际引擎。
- 保持路由快照、模型 lease、20 秒停止后预算、单次交付、剪贴板保护、恢复资源和 M5 门禁；不扩展模型架构或修改数据库统计口径。
- 页面出现、切页、完成 onboarding 不隐式录音、联网测试、下载或请求权限；真实试说及测试均为明确动作。
- 密钥沿用现有本地配置存储，不宣称 Keychain 迁移；不进入日志、状态文案或截图证据。
- 自动测试使用独立 UserDefaults、临时数据库／目录、假传输／音频／注入／剪贴板，禁止读取或写入生产配置、词典、历史和模型缓存。
- 按既有偏好使用子智能体驱动执行，最多 1 个子智能体同时工作；实现与评审依次进行。本计划已获用户确认，源代码实施与独立审查已按此方式执行。
- 本轮不自动安装、替换运行中应用或推送；真机与远端 CI 未执行的项目保留 Pending。

## Review Focus

1. 编辑期间另一页面修改配置或删除档案：按 UUID 合并，保留无关变化，不复活档案。Task 3：`deletedDraftCannotResurrect`／`mergePreservesConcurrentSettings`。
2. 测试已发出后编辑、取消或重开草稿：旧结果失效，不能保存／激活草稿，也不能释放新请求的归属。Task 4：`lateDraftCheckCannotPublish`。
3. 试说取消后旧阶段迟到、普通热键同时开始：不能污染新结果、双占录音或产生正式副作用。Task 7：`trialCancellationAndCompetingStart`。
4. 麦克风被拒绝且辅助功能缺失：显示真正 blocker 和降级能力，查看页面不弹授权。Task 5：`multipleReadinessIssuesWithoutPrompt`。
5. 历史读取失败或隐私清空后文本缺失：错误可重试；禁用文本动作，保留元数据和统计。Task 9：`historyReadFailureAndTextlessActions`。

---

## 文件职责与执行约定

以下路径均相对仓库根目录；`Sources/flowtype/` 为产品源目录。任务列出的新增文件是职责边界，不能把协调器和草稿逻辑塞回大段 SwiftUI body。

| 单元 | 文件与职责 |
| --- | --- |
| 视觉基础 | `UI/Theme/Theme.swift`、`Brand.swift`；新增 `Settings/SettingsSectionComponents.swift`，只管理原生排版、行和分组 |
| 导航 | 新增 `Settings/SettingsDestination.swift`；`MainWindowView.swift`、`SettingsWindowController.swift` 和 `StatusBarController.swift` 接受并消费目的地 |
| 保存与副作用 | 新增 `Settings/SettingsChangeCoordinator.swift`，统一保存及热键差异判断 |
| 服务草稿 | 新增 `Settings/ProviderDraft.swift`、`ProviderDraftCommit.swift`、`ASRProviderEditSheet.swift`；现有 LLM 编辑器复用提交合同 |
| 设置四组 | `SettingsView.swift` 仅组装分组；现有 `SettingsPage+*.swift` 按职责保留；新增 `Settings/ReadinessPresentation.swift` |
| 试说 | 新增 `Core/SessionResourceCoordinator.swift`、`Settings/TrialSessionPresenter.swift`、`TrialSessionView.swift`；`PipelineOrchestrator.swift` 增加 purpose 和资源归属；`OnboardingPipeline.swift` 输出有归属的临时结果 |
| 数据页面 | 概览沿用 `Settings/Overview/`；历史错误状态在 `Core/DictationHistory.swift`；新增 `Settings/HistoryPresentation.swift`、`StylePresentation.swift` 管理真实文案／可用动作 |
| 验证 | 新增 `Testing/NativeClientSelfTests.swift` 汇总各组；同目录新增各任务注明的 SelfTest 文件，在现有 `Testing/SelfTest.swift` 注册 |

所有行为测试遵循 `SelfTest.Reporter`，不另建测试框架。Task 1 增加 `--native-client-only` 分支，并将相同测试注册进完整 suite；后续任务追加至 `NativeClientSelfTests.run(_:)`。纯排版不写镜像测试，以原生人工检查验收。

**聚焦验证命令（以下任务引用“聚焦验证”均指这三行）：**

```sh
swift build
native_validation_dir="$(realpath "$(mktemp -d /tmp/flowtype-native-client.XXXXXX)")"
.build/debug/FlowType --self-test --native-client-only --validation-root "$native_validation_dir"
```

期望退出 0，汇总 `failed == 0`；每组输出可辨认的测试名。行为任务先添加断言并运行，确认失败原因是所需行为未实现，再实现并复跑。新接口尚不存在导致的编译失败只证明缺接口，补齐最小接口后仍需观察行为断言失败。每项提交前执行 `git diff --check`，仅暂存该任务文件。

### Task 1: 导航目的地与原生布局基础

**Files:** 修改 `Sources/flowtype/Settings/MainWindowView.swift`、`SettingsWindowController.swift`、`Sources/flowtype/App/StatusBarController.swift`、`Sources/flowtype/Core/StatsConfig.swift`、`Sources/flowtype/UI/Theme/Theme.swift`、`Brand.swift`；新增 `Sources/flowtype/Settings/SettingsDestination.swift`、`SettingsSectionComponents.swift`、`Sources/flowtype/Testing/NativeClientSelfTests.swift`、`NativeNavigationSelfTests.swift`；修改 `Sources/flowtype/Testing/SelfTest.swift`。

**Interfaces:** Consumes 现有 `AppTab`、`SettingsNavigation(initialTab:)`、`SettingsWindowController.selectTab(_:)`。Produces `SettingsSection: String, CaseIterable`（`speech/text/general/privacy`）、`SettingsTarget: Hashable`（`localModels/provider(UUID)/microphone/accessibility/appleSpeech`）、`ClientDestination: Equatable`（`tab(AppTab)/settings(SettingsSection, SettingsTarget?)/history(String?)/style(String?)`）、`NavigationRequest { id: UUID, destination: ClientDestination }`；`SettingsNavigation.navigate(to: ClientDestination)` 和 `@Published private(set) var request: NavigationRequest?`。保留 `requestedTab` 兼容入口；新增 `SettingsWindowController.open(destination: ClientDestination)` 和 `StatusBarController.openSettings(destination: ClientDestination)`。`SettingsGroup<Content: View>` 与 `SettingsRow<Content: View>` 为纯视图，接收标题、说明和内容，不访问服务。

- [x] 添加 `repeatedDestinationHasNewIdentity`、`legacyTabStillNavigates`：相同目的地两次请求 `id` 不同；旧 AppTab 调用仍发布一次有效请求；不产生录音、保存或热键动作。注册聚焦及全量 suite，运行聚焦验证观察失败。
- [x] 实现目的地及窗口消费：主窗口始终接收请求，设置组和滚动项使用同一 request.id；历史／风格 ID 暂由页面接收，Task 9／10 消费。窗口已打开也能跳转，不重新创建业务控制器。
- [x] 按全局尺寸调整 Theme／StatsConfig 与共享行，保留五入口和固定侧栏；删除本次页面上的装饰纹样，复用现有外观偏好，焦点及减少动态效果走系统环境。
- [x] 聚焦验证通过。
- [ ] 人工核对空壳窗口最小／初始／宽窗口、两主题和键盘焦点，不以浏览器原型代替原生验证。 **Pending：尚未执行当前候选的真机窗口／键盘检查。**
- [x] 提交：`feat: establish native client navigation and layout`。

### Task 2: 配置保存和热键副作用分离

**Files:** 新增 `Sources/flowtype/Settings/SettingsChangeCoordinator.swift`、`Sources/flowtype/Testing/SettingsChangeSelfTests.swift`；修改 `Sources/flowtype/App/StatusBarController.swift`、 `Sources/flowtype/Settings/SettingsView.swift`、`Sources/flowtype/Testing/NativeClientSelfTests.swift`，必要时调整 `Sources/flowtype/WindowManager.swift` 的调用点。

**Interfaces:** Consumes `ConfigurationStore.save(_:)`、`flushPendingSave()`。Produces `@MainActor SettingsChangeCoordinator.init(store: ConfigurationStore, reloadHotkey: @escaping @MainActor () -> Void)`、`startObserving()`（幂等）、`handleChange(from old: Configuration, to new: Configuration)`；保存回馈只能表示已提交到当前保存机制，不虚构磁盘成功。

- [x] 添加 `unrelatedSettingsDoNotReloadHotkey`／`hotkeySettingsReloadOnce`／`saveSurvivesPageClose`：外观、隐私、ASR／LLM 更改不重载；triggerKey／interactionMode 变化各触发一次；重复值不触发；保存防抖后 flush 能从隔离 defaults 还原。运行聚焦验证观察失败。
- [x] 由 StatusBarController.setup 持有唯一 coordinator 并调用 startObserving，测试显式注入。Combine 的 willSet 发布不能同步再写 current；将合并处理排到主执行器下一轮、读取最新值，差异去重后保存，防止回写旧配置和递归事件。设置页移除“任意变更→reloadHotkey”。保留现有保存防抖、退出 flush，避免递归 save 导致重复副作用。草稿不进入 live configuration。
- [x] 用安静的行内回馈替代逐字符绿色浮层；页面打开、分组切换不触发保存或热键重建。
- [x] 聚焦验证通过，切页后仍保存；提交 `fix: scope settings persistence and hotkey effects`。

### Task 3: ASR／LLM 草稿与事务提交

**Files:** 新增 `Sources/flowtype/Settings/ProviderDraft.swift`、`ProviderDraftCommit.swift`、`Sources/flowtype/Testing/ProviderDraftSelfTests.swift`；修改 `Sources/flowtype/Settings/SettingsPage+ProviderActions.swift`、`ProviderEditSheet.swift`、`SettingsView.swift`、`Sources/flowtype/Testing/NativeClientSelfTests.swift`。

**Interfaces:** Consumes `CloudASRProviderConfig`、`LLMProvider`、`Configuration`、现有校验与厂商预设。Produces `ProviderDraftTarget`（`new(UUID)/existing(UUID)`）、`APIKeyEdit`（`preserve/replace(String)/remove`）、`ASRProviderDraft { target, profile: CloudASRProviderConfig, keyEdit: APIKeyEdit }`、`LLMProviderDraft { target, profile: LLMProvider, keyEdit: APIKeyEdit }`；`ProviderDraftCommit.apply(_ draft: ASRProviderDraft, to config: inout Configuration) throws` 及同名 LLM 重载；`ProviderDraftCommitError`（`deleted/conflict/invalid(String)`）。`conflict` 用于新增 UUID 已存在；existing 缺失必须 deleted。

- [x] 添加 `deletedDraftCannotResurrect`、`mergePreservesConcurrentSettings`、`blankKeyPreservesAndRemovalIsExplicit`、`vendorChangePreservesFields`：删除后提交失败；仅合并目标 UUID，保留最新无关配置和活动选择；空白保留旧密钥，remove 才删除；取消整份配置不变。运行聚焦验证观察失败。
- [x] 实现纯提交函数：先在最新配置副本验证再原子赋回；新增允许厂商预设，编辑切厂商只改厂商字段；显式“使用厂商默认值”才替换 URL／模型，密钥不随厂商重置。新建首个档案与唯一活动选择遵循现有规则。
- [x] LLM 弹窗改用同一草稿合同，取消不写配置；关闭有修改的编辑器提供继续编辑／放弃，禁止靠 onDisappear 自动保存。保存错误保留草稿；仅提交成功后调用保存机制。ASR 与 LLM 密钥、档案绝不交叉。
- [x] 聚焦验证通过；提交 `feat: make provider editing transactional`。

### Task 4: 云端服务列表、草稿测试与异步归属

**Files:** 新增 `Sources/flowtype/Settings/ASRProviderEditSheet.swift`、`Sources/flowtype/Testing/ProviderDraftCheckSelfTests.swift`；修改 `Sources/flowtype/Settings/CloudASRProviderList.swift`、`CloudASRConnectionCheck.swift`、`ProviderRow.swift`、`Sources/flowtype/Testing/NativeClientSelfTests.swift`。

**Interfaces:** Consumes Task 3 草稿与提交函数、现有 `CloudASRConnectionCheck` token/state API。Produces `ASRProviderEditSheet`，依赖明确传入的草稿、提交／取消闭包和草稿专用 `CloudASRConnectionCheck`；保留 `checkConfiguration(provider:apiKey:)`、`testRecognition(provider:apiKey:)`、`invalidate(profileID:)` 现有签名。列表的 live checks 与编辑器 checks 分开；每次草稿变化均使其 revision 失效。

执行补充：集中审查后，独立的 live／draft 检查器由应用生命周期的 `SettingsConnectionChecks` 持有，经窗口根视图和页面工厂显式传入；切页／关窗重开不释放尚未结束的传输占用。配置观察也由该 owner 持有，页面不在场时仍使旧结论失效；注入构造必须显式提供隔离 owner。

- [x] 用假传输添加 `lateDraftCheckCannotPublish`、`checkDoesNotCommitOrActivate`、`wssHasConfigurationCheckOnly`：请求 A 暂停后改字段／取消／重开，请求 A 迟到不能覆盖 B；无任何保存；本地检查网络调用数为 0；WSS 不走 HTTP；旧请求完成不能释放另一 token 的 slot。运行聚焦验证观察失败。
- [x] 列表改为紧凑名称／模型／已选／验证状态行，编辑放弹窗；自定义模型 ID 为必填主字段，协议等高级项折叠。保存按最新配置 UUID 提交，删除同步使 live 和草稿结论失效。
- [x] 草稿测试使用草稿密钥或 preserve 对应的当前密钥快照，只在点击测试时发出；保存后也不把草稿成功冒充 live 新修订成功。HTTP 动作旁明确说明发送密钥与 0.5 秒合成静音、可能计费；WSS 只说明真实录音验证。配置有效与连接成功分开显示。
- [x] 聚焦验证通过，使用延迟假服务验证关闭编辑器后的结果不会串行到新编辑器；提交 `feat: add scoped cloud provider editing and checks`。

### Task 5: 四组设置与可用性／隐私展示

**Files:** 新增 `Sources/flowtype/Settings/ReadinessPresentation.swift`、`Sources/flowtype/Testing/ReadinessPresentationSelfTests.swift`；修改 `Sources/flowtype/Settings/SettingsView.swift`、`SettingsPage+ASR.swift`、`+LLM.swift`、`+Appearance.swift`、`+Trigger.swift`、`+Recording.swift`、`+Permission.swift`、`+Privacy.swift`、`+Diagnostics.swift`、`Sources/flowtype/Testing/NativeClientSelfTests.swift`。

**Interfaces:** Consumes Tasks 1–4、`ReadinessMonitor.snapshot/rawLevel/refresh()`、现有配置字段。Produces `ReadinessPresentation.make(snapshot: ReadinessSnapshot, level: ReadinessLevel) -> ReadinessPresentation`，含 `title: String`、`details: [String]`、`destinations: [ClientDestination]`；展示不新增权限判定。`ASRSettingsContent` 与 `PermissionSettingsContent` 通过显式传入的 store／monitor／navigation 复用，onboarding 在 Task 8 使用。

- [x] 添加 `multipleReadinessIssuesWithoutPrompt`、`localASRWithCloudPolishDisclosure`、`contextDisablePreservesPreferences`：mic denied 为 blocked，AX 缺失说明菜单／剪贴板降级；组合问题都可见；构建与查看展示请求权限次数 0；localOnly 不改 polishOnStop；禁用父子控件不改存储值；WSS 不发送上下文。运行聚焦验证观察失败。
- [x] SettingsPage 只保留四组切换、顶部试说入口占位及滚动定位。分派旧扩展至对应分组，复用独立 LLM 列表；通用保留现有枚举完整选项与动态触发键说明。模式控件固定自然宽度，折叠另一配置区仍能编辑，展开不切换模式。
- [x] 仅本地＋云端整理时显示设计中的文字发送提示及文本整理入口；上下文子项依赖总开关，localOnly 禁用但保留值。说明文本保存仅影响后续文本，旧文本清理定位历史。
- [x] 删除设置页每两秒永久权限轮询，复用 ReadinessMonitor、前台刷新与现有有界 watch；打开页面不请求授权。Apple Speech 只作为该引擎依赖说明。设备拔出展示不可用并保留所选设备，不伪装切换成功。
- [x] 聚焦验证通过；提交 `feat: connect grouped settings to readiness and privacy`。
- [ ] 原生逐组检查长 URL、键盘、重复深链定位及不改配置的折叠动作。 **Pending：离屏截图未覆盖全部原生交互。**

### Task 6: 本地模型列表与既有恢复状态

**Files:** 修改 `Sources/flowtype/Settings/LocalModelPicker.swift`、`ASRModelStatusCard.swift`、`QwenModelStatusCard.swift`、`ImportedASRModelList.swift`、`ImportedASRModelPresentation.swift`、`SettingsPage+ASR.swift`；新增 `Sources/flowtype/Testing/NativeModelPresentationSelfTests.swift`，修改 `Sources/flowtype/Testing/NativeClientSelfTests.swift`。

**Interfaces:** Consumes `QwenModelState`、`ModelRecoveryPresentation`、`ImportedASRModelActions.stage(directory:replacing:)`／`loadPreview()` 及 Tasks 1／5。Produces 模型组件统一通过这些服务展示选择／activeLease／操作目标，不新增模型生命周期 API 或第二个加载任务。

- [x] 添加 `selectedLoadedAndPreparingRemainDistinct`／`failedImportKeepsUsableLease`：已选 B、加载 A、准备 B 时分别显示；预检不提交；失败保留旧 lease；移除记录不删除外部目录；自动 1.7B 回退 0.6B 有标识，手动选择不被改写。使用现有假 coordinator 和临时模型目录，聚焦验证观察失败。
- [x] 紧凑整理内置 0.6B／1.7B 与导入列表；下载进度、大小、取消、硬件／磁盘提示及既有恢复动作完整保留。导入为选择目录→检查→预览→明确加载；准确说明 Qwen MLX／Whisper Core ML 支持范围。
- [x] 将现有 `ImportedModelUISelfTests.run(_:)` 与 `ModelProvisionSelfTests.runPresentationAndRouting(_:)` 纳入本任务聚焦验证并通过（最终全量仍由 Task 11 执行）；提交 `feat: clarify local model selection and recovery`。

### Task 7: 试说隔离与录音资源互斥

**Files:** 新增 `Sources/flowtype/Core/SessionResourceCoordinator.swift`、`Sources/flowtype/Settings/TrialSessionPresenter.swift`、`TrialSessionView.swift`、`Sources/flowtype/Testing/TrialSessionSelfTests.swift`；修改 `Sources/flowtype/Core/PipelineOrchestrator.swift`、`Sources/flowtype/Features/Onboarding/OnboardingPipeline.swift`、`Sources/flowtype/Testing/NativeClientSelfTests.swift`，迁移现有 demo 测试调用。同步修改 `Sources/flowtype/Testing/SelfTest.swift`、`M3DeliverySelfTests.swift`、`M3FinalFixSelfTests.swift`、`M3SpeechPreflightSelfTests.swift`、`M4RecoveryControllerSelfTests.swift`、`M5SmokeSelfTests.swift` 的控制器构造，显式注入独立 resources，避免测试间共享占用。

**Interfaces:** Consumes 现有 SessionController 注入参数和 Task 5 可用性。Produces `SessionPurpose`（`dictation/trial`）；SessionController init 追加 `purpose: SessionPurpose = .dictation`、`resources: SessionResourceCoordinator = .shared`。`@MainActor SessionResourceCoordinator` 提供 `acquire(owner: UUID) -> UUID?`、`release(token: UUID)`、`@Published private(set) var owner: UUID?`，token 精确释放。`OnboardingPipeline.makeStages(onResult: @escaping @MainActor @Sendable (UInt64, String) -> Void) -> [PipelineStage]` 替换无身份广播。`@MainActor TrialSessionPresenter` 提供 `start()`、`stop()`、`cancel()`、`copyResult()` 和只读发布 `result: String?`、`controller: SessionController`；init 签名为 `init(configuration: ConfigurationStore, resources: SessionResourceCoordinator, refreshReadiness: @escaping @MainActor () -> ReadinessLevel, readinessLevel: @escaping @MainActor @Sendable () -> ReadinessLevel, copy: @escaping @MainActor (String) -> Void)`，测试无共享单例默认值。

- [x] 添加 `trialHasNoLiveEffects`／`trialCancellationAndCompetingStart`：正常试说、取消及 uncertain 路径的正式历史／统计／词典学习／最近交付／自动剪贴板／胶囊调用均为 0；显式复制一次才调用 copy。普通开始与试说竞争仅一方获得 lease，旧 token 不能释放新 lease；取消后迟到回调不刷新新结果。使用可控挂起阶段，聚焦验证观察失败。
- [x] 在控制器入口获取资源 lease，覆盖热键、菜单、恢复 rerecord 和试说所有来源。忙时给出可理解状态，不启动阶段或清理另一会话。取消先失效回调身份，实际阶段取消清理完成后才释放 lease；正常完成／错误关闭／notice 收尾和重入也精确释放，不因清空 currentTask 提前放开仍在停止的麦克风。等待清理期间阻止第二次 start；实际清理完成后需要用户再次明确开始，不自动排队。
- [x] purpose 为 trial 时强制绕过正式 saveHistory（含内部学习）与 recordLastDelivery；不把空 saveHistory 闭包视为“已入历史”。Presenter 显式注入无 prepare／窗口副作用 effects、空或试说专用 observers 与安全 recovery effects，避免构造控制器自动预热／下载。普通 dictation 路径维持现有语义。
- [x] DemoInjectionStage 保留取消与单次交付 gate，只回传 sessionID 与文本；Presenter 再核对自身 generation，关闭／切页／重开均取消并失效旧结果。保留真实 ASR／整理阶段，不调用真实 InjectionStage；试说复制是明确按钮动作，恢复卡不凭空出现正式历史入口。
- [x] 聚焦验证通过；运行 `.build/debug/FlowType --self-test --m4-recovery-only --validation-root "$native_validation_dir"` 并确认 dictation 的 uncertain 保存、retry 归属及 20 秒预算没有退化；提交 `fix: isolate trial sessions and arbitrate recording ownership`。

### Task 8: 设置试说和 onboarding 复用

**Files:** 修改 `Sources/flowtype/Settings/OnboardingView.swift`、`OnboardingWindowController.swift`、`SettingsView.swift`、`TrialSessionView.swift`；新增 `Sources/flowtype/Testing/OnboardingFlowSelfTests.swift`，修改 `Sources/flowtype/Testing/NativeClientSelfTests.swift`。

**Interfaces:** Consumes Task 5 的 `ASRSettingsContent`／`PermissionSettingsContent` 与 Task 7 Presenter。Produces `OnboardingStep`（`introduction/engine/permissions/trial`）及 `OnboardingFlow`（`step`、`advance()`、`back()`、`finish()`），通过注入完成回调记录完成；finish 仅完成流程，不加载模型。视图拥有并稳定保存一个 Presenter。

- [x] 添加 `finishDoesNotPrepareEngine`／`trialNeedsExplicitStart`：浏览、回退、稍后完成和 finish 的下载／权限请求／录音计数均 0；无引擎试说定位 speech；拒绝 mic 后仍可返回配置；离开 trial 必调 cancel。聚焦验证观察失败。
- [x] 实现简短可返回流程，先准备引擎再授权／试说，复用设置配置和 readiness；删除现有 finish 隐式 loadModel 和默认 live demo controller。资源需求与云端发送说明按当前配置展示。
- [x] 设置页顶部接真实试说区，用按钮开始／停止／取消及动态触发键提示，显示占用和准备状态；结果仅进入该区域，有结果才可显式复制。
- [x] 聚焦验证通过；提交 `feat: reuse native setup and trial flows`。
- [ ] 人工检查无引擎、本地准备、云端配置、mic denied、AX degraded 路径。 **Pending：当前候选的真机检查尚未执行。**

### Task 9: 历史错误、交付语义与隐私动作

**Files:** 修改 `Sources/flowtype/Core/DictationHistory.swift`、`Sources/flowtype/Settings/HistoryPage.swift`；新增 `Sources/flowtype/Settings/HistoryPresentation.swift`、`Sources/flowtype/Testing/NativeHistorySelfTests.swift`，修改 `Sources/flowtype/Testing/NativeClientSelfTests.swift`。

**Interfaces:** Consumes Task 1 history 目的地、`DictationSession`、`DeliveryOutcome` 和现有持久化动作。Produces `HistoryReadState`（`loading/loaded/failed(String)`）、`HistoryStore.@Published private(set) var readState: HistoryReadState`；增加测试用 `init(database: AppDatabase, readSessions: (@MainActor () throws -> [DictationSession])? = nil, refreshStats: @escaping @MainActor () -> Void)`（数据库及统计刷新均注入；readSessions 为可控失败 seam，nil 时读取该 database），shared 保持生产入口。`HistoryPresentation.deliveryLabel(_ outcome: DeliveryOutcome?) -> String`、`canCopy(_ session: DictationSession) -> Bool`、`canExportText(_ session: DictationSession) -> Bool`。

- [x] 添加 `historyReadFailureAndTextlessActions`／`historyDestructiveActionsKeepTheirSemantics`：临时 DB 注入可控读取失败，状态 failed，重试恢复 loaded；缺失文本两动作 false，CSV 元数据保留且文本空；清空文本前后统计相同，单删移除相应统计，reset 仍两次确认。覆盖全部 outcome 与 nil 的设计文案，禁止“确认输入成功”。聚焦验证观察失败。
- [x] HistoryStore 不再将失败伪装空库；错误状态不丢当前选择／未导出的展示数据，重试显式 reload。所需读取失败 seam 仅在注入实例中使用，不关闭生产数据库制造失败。
- [x] 保留 split view、搜索、原文／整理筛选及导出；详情先最终文本，原文不同时展开；显示真实引擎／时间／耗时。消费记录 ID 深链，找不到则保持列表；历史不提供原音频重试。清理危险动作放菜单，保持原有确认及持久化语义。
- [x] 聚焦验证通过；提交 `feat: clarify history delivery and privacy states`。
- [ ] 人工检查无记录／读取错误／长文本／清空后记录及 CSV。 **Pending：当前候选的真机检查尚未执行。**

### Task 10: 概览、词典和风格页面

**Files:** 修改 `Sources/flowtype/Settings/OverviewPage.swift`、`Overview/HeroSection.swift`、`AchievementsSection.swift`、`StatsPanel.swift`、`RangeSegmented.swift`、`FunFact.swift`、`VocabPage.swift`、`StylePage.swift`、`SettingsPage+LLM.swift`；新增 `Sources/flowtype/Settings/StylePresentation.swift`、`Sources/flowtype/Testing/NativeContentSelfTests.swift`，修改 `Sources/flowtype/Testing/NativeClientSelfTests.swift`。为 `Sources/flowtype/Core/Dictionary.swift`／`StylePack.swift` 增加 `DictionaryStore.init(store: PersistentStore<[DictionaryEntry]>)`／`StylePackStore.init(store: PersistentStore<[StylePack]>)` 注入入口，测试使用显式临时 directory；shared 保留现有生产初始化，不改存储语义。

**Interfaces:** Consumes `StatsEngine.summarize`／`denseHeatmap`、DictionaryStore、`StylePackStore.activePack`、Task 1 style 目的地。Produces `StylePresentation.effectiveSource(pack: StylePack?, configuration: Configuration) -> String`；与 LLMService 现有 prompt 优先级相同。概览直接观察词典与 DailyStatsStore，使用现有计算，无第二套统计引擎。

- [x] 添加 `overviewRangeAndSparseData`／`dictionaryAndStyleReflectEffectiveState`：45 字／分钟及 raw 字数、recordingMs 优先和 legacy fallback 保持；三个范围更新汇总和 24 桶，年度热图仍 365 天，零值无假柱；进度环 0／0 为 0，切词条 enabled 即更新比例；风格删活动自定义回退 builtin.structured，导入失败保留当前选择／草稿。覆盖午夜／跨年与稀疏数据，聚焦验证观察失败。
- [x] 原生概览保留环＋四统计、三成就、七里程碑（3／7／14／30／60／100／365）、独占整行的年度热图和小时图、趣味页脚。约 779pt 热图／12pt 格子、112pt 小时绘图区，保留月份／星期／五级图例／日期字数详情与小时次数／高峰。零记录显示引导和真实零数据；范围不改变全量本月／最佳月份口径，保留现有页脚阈值和前台刷新。
- [x] 词典改紧凑可扫描行，直接显示启用开关、备注、来源及 hits；搜索只过滤展示。保留添加／禁用／删除与 Store 规范化，不宣传模型学习进度或保证正确率。
- [x] 风格列表优先名称／用途／来源／状态，提示词在详情编辑；保留内置保护、JSON 导入导出与活动选择；消费风格 ID 深链。文本整理页准确显示 activePack→builtin structured→无 pack 时配置默认提示词的来源与编辑入口；不改变 LLMService 优先级。例子标明说明性示例，切风格不联网。
- [x] 聚焦验证通过；提交 `feat: refine overview dictionary and style pages`。
- [ ] 逐页检查长词条／模型名／中英混合、空／稀疏／加载／错误和两主题。 **Pending：离屏布局观察完成一部分，真机完整矩阵未执行。**

### Task 11: 恢复入口联调与候选版本验收

**Files:** 修改 `Sources/flowtype/Core/Recovery/RecoveryEffects.swift`、`Sources/flowtype/App/StatusBarController.swift`、`Sources/flowtype/Settings/MainWindowView.swift`、`Sources/flowtype/Settings/SettingsWindowController.swift`；仅在有真实资源数据可用处调整 `Sources/flowtype/Core/PipelineOrchestrator.swift` 恢复定位参数；新增 `Sources/flowtype/Testing/NativeRecoveryNavigationSelfTests.swift`、`docs/superpowers/validation/2026-11-03-native-client-acceptance.md`，修改 `Sources/flowtype/Testing/NativeClientSelfTests.swift`。

**Interfaces:** Consumes Task 1 `ClientDestination`、现有 RecoveryPolicy／cardID／sessionID／generation 和 Tasks 2–10 页面。Produces 所有现有恢复入口到真实目的地的绑定；保留 `RecoveryEffects` 现有闭包签名。若错误已有 profile UUID，通过会话持有的恢复数据定位；无法确定时仅定位 speech，不猜当前选中档案就是失败来源。

- [x] 添加 `recoveryOpensCurrentDestinationWithoutRepeatingDelivery`：无引擎→speech，模型问题→localModels，配置错误→已知 provider，权限→对应设置；重复定位仍生效；旧卡点击不触发新会话动作。输入 uncertain 不出现重复发送；ASR retry 仅在仍持有音频且未交付时可见。聚焦验证观察失败。
- [x] 绑定菜单、胶囊、模型错误及历史入口；只展示控制器授权的动作。区分已选／实际引擎，不从配置反推上一会话。跨页不取消普通会话、不重建热键；只取消离开页面的试说。
- [x] 聚焦验证通过；完成并检查隔离的原生离屏截图，证据和限制见验收文档。
- [ ] 完成整体真机布局核对，覆盖 1040×700、1120×760、宽窗口、浅／深／随系统、键盘、减少动态效果和长内容；历史列表及小窗口下半区滚动仍 Pending。不能用 HTML 或离屏截图替代这些真机观察。
- [x] 创建验收文档，列出设计 §12 的八类自动合同与本计划任务／证据对应。保留 M5 的 41 项人工矩阵，特别将 V1 弱网／断网／无效密钥、V2 跨应用中文／英文／多行／emoji、V3 多格式剪贴板／并发复制、V4 各阶段取消／迟到结果、V5 拔麦／蓝牙恢复列为主线，未执行均 Pending。另记录本轮草稿、试说隔离、窗口矩阵的原生观察，不擅自更改 M5 schema 或伪造 Pass。
- [x] 提交 `feat: integrate native recovery navigation and acceptance coverage`，确保源码提交完整后运行 `scripts/verify.sh --lane code`；期望 code 阶段全过，manual／remoteCI 未执行允许如实 Pending，逐项读报告，不把整体 Pending 当 code 失败或发布成功。
- [x] 对最终源码候选执行 `scripts/verify.sh --lane artifact`，构建仓库内候选并记录源码／二进制身份、完整签名、资源与启动检查报告；使用显式的现有 `MLX_METALLIB_PATH`，没有安装应用。创建 `build/native-client-manual.json`，沿用 M5 schema，41 项全部 Pending。
- [ ] 按当前候选逐项执行实际人工验证；需要用户亲自触发的权限／热键动作再说明。远端 CI 证据须匹配源码身份，缺失保留 Pending。
- [x] 串行完成独立整支 review、一次集中修复和修复范围复审；按 receiving-code-review 验证实际问题，重新形成候选并复验 code／artifact。验收文档与审查归档记录最终身份、结论和执行裁定；已执行的真机项为 0，不转记旧观察。分别报告实现、code、artifact、manual、remoteCI 状态。

## 计划自检与交付边界

- 设计 §3–4 → Task 1；§5 → Task 10；§6 → Tasks 3–6；§7 → Tasks 2／5／10；§8 → Tasks 7–8；§9 → Tasks 9–10；§10 → Tasks 6／7／11；§11–12 → 文件职责、各任务测试和 Task 11。
- 五个 Review Focus 均已绑定具名行为测试。跨任务只使用本文件 Interfaces 中的同名接口；已有服务 API 延用源码，不复制新的状态机。
- 单独评审 Task 3（提交事务）、Task 4（异步测试）、Task 7（资源／副作用）后再进入依赖任务；它们不是可以顺手略过的 UI 细节。
- 本计划已获确认并按“最多 1 个子智能体同时工作”执行。实现和代码／产物门禁的完成状态与真机／远端验收分开记录；禁止把设计原型、离屏布局截图、旧真机结果或旧候选转记为当前候选的人工通过。
