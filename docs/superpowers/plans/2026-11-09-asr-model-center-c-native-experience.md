# C — Native Model Center Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 macOS 客户端提供可理解、紧凑且完整的模型获取、配置、试用、切换和恢复体验。

**Architecture:** 应用拥有ModelCenterViewModel，页面投影A/B领域状态；五个入口统一进入已有识别设置，详情承载复杂参数。readiness/试用/历史/恢复使用同一后端身份。

**Tech Stack:** SwiftUI、AppKit目录选择、Combine、现有NativeClientPreviewSelfTests、A/B领域服务。

**Spec:** [总设计](../specs/2026-11-09-asr-model-center-design.md)、[体验设计](../specs/2026-11-09-model-center-experience-design.md)；引用A/B契约。依赖A/B通过。

## Global Constraints

- 平台为 macOS 15+、Apple Silicon、Swift 6.2；保留 macOS 原生 SwiftUI 客户端。
- 保持 speech-swift 0.0.15、WhisperKit 0.18.0、swift-transformers 1.1.9 锁定基线；新增依赖或升级必须单独说明依据。
- 核心音频契约为 16kHz、单声道 Float32；协议适配器负责 wire 编码；一次录音只交付一次终稿。
- 原生推理严格离线；下载是显式独立操作；外部模型服务由用户自行安装、启动和更新。
- 下载、检查、加载、试识别、选中分别建模；失败或取消不替换已有可用选择，不删除用户自有模型。
- 录音开始捕获不可变后端、模型、能力与凭据快照；迟到回调不能改变新会话或新配置。
- 自动化使用隔离临时根、合成文件与注入 transport；不读写用户真实配置、密钥、模型、权限或剪贴板。
- 各任务顺序运行 swift build 与 self-test；最终运行现有 code/artifact/release 门禁；Pending 不等于 Pass。

## Review Focus

1. 长名称、真实错误与低内存提示不能靠截断掩盖兼容范围或占用情况（C1/C3）。
2. 试识别必须经用户动作；读取models/静态检查不能变成“已就绪”，本机服务不能宣传整个链路完全离线（C1/C2）。
3. tab关闭/重开、重复点击、草稿修改时下载与测试的应用所有权保持，旧回调不能换主选（C1/C4）。
4. 主备与policy冲突、删主选、云端备选授权必须有明确处理，不能自动挑第一项（C1/C4）。
5. 最小窗口真实滚动、键盘、VoiceOver与减少动态不能用离屏截图冒充通过（C3/D2）。

## File Structure

新 `Sources/flowtype/Settings/ModelCenter/`：`ASRModelCenterViewModel.swift`、`ASRModelCenterPresentation.swift`、`ASRModelCenterView.swift`、`ASRModelRow.swift`、`ASRModelDetail.swift`、`HFModelInstallSheet.swift`、`LocalASRServiceEditSheet.swift`、`ModelInstallationList.swift`、`ASRValidationSampleStore.swift`。UI组件只处理本职责。

修改 `Settings/{SettingsPage+ASR,SettingsWindowController,SettingsDestination,SettingsView,ImportedASRModelActions,CloudASRProviderList,ASRProviderEditSheet,LocalModelPicker,OnboardingView,TrialSessionPresenter}.swift`、`Features/Onboarding/OnboardingPipeline.swift`、`App/FlowTypeApp.swift`。新增 `Testing/ASRModelCenterSelfTests.swift`，修改 NativeClientPreviewSelfTests 与 Package.swift资源声明。

## Task C1: 统一投影、状态与领域动作

**Files:** Create ViewModel/Presentation、`Testing/ASRModelCenterSelfTests.swift`；Modify RuntimeEnvironment/SelfTest注册 `--asr-model-center-only`。

**Interfaces:**
- Consume A descriptors/selection/validation，B installed records/jobs/activation。
- Produce `ASRModelCenterRow: Identifiable, Equatable`（id:ASRBackendID、title:String、subtitle:String、location:ASRBackendLocation、status:ASRModelCenterStatus、isPrimary:Bool、isFallback:Bool）；status覆盖体验spec §3。
- Produce `ASRModelCenterStatus: Equatable`：notInstalled/queued/downloading(progress:Double)/paused/verifying/installedUntested/testing/previouslyValidated/ready/unavailable(reason:String)/failed(reason:String)。
- Produce `ASRModelCenterViewModel` 的 `rows:[ASRModelCenterRow]`、`selectedID:ASRBackendID?`、`installations:[ModelInstallSnapshot]`、`notice:String?`；`selectPrimary(_ id: ASRBackendID) async`、`selectFallback(_ id: ASRBackendID?)`、`test(_ id: ASRBackendID) async`、`remove(_ id: ASRBackendID, deleteManagedFiles: Bool) async`。
- ViewModel应用级拥有，初始化注入所有领域依赖与now；发布数据是领域投影，不另存active lease/网络任务。

- [ ] **Step 1: 写 `testHonestStatusProjection` / `testPrimarySelectionTransaction` / `testPolicyConsentAndRemoval`。** installed未loaded显示未试用；重启验证记录为上次通过；60s服务验证过期；cloud/localservice配置合法不显示识别成功。列表排序不改ID，失败不换主选，主备重复拒绝，localOnly/cloudOnly冲突提示；删除主选要求替代或明确未就绪，不能first自动选中。

```swift
r.eq(selectedPrimaryAfterFailedTest, originalPrimary, "test failure leaves selection")
r.eq(statusAfterRestart, .previouslyValidated, "history is not current readiness")
r.eq(cloudUploadsOnOpeningPage, 0, "rendering has no recognition effects")
r.eq(implicitReplacementAfterDelete, nil, "no arbitrary first-row selection")
```

- [ ] **Step 2: 验证 RED。** build后focused；缺state/transaction断言失败，不能以新filter未注册为业务RED。
- [ ] **Step 3: 实现投影与动作。** 选择native走B5，service/cloud走主动测试再提交；保存未验证profile可用但不自动主选。native/loopback+云备选需显式allowsCloudFallback。将Qwen兼容facade状态投影进相同行，避免两处矛盾；未知峰值与服务端模型显示准确文案。
- [ ] **Step 4: 验证 GREEN。** focused、A/Bfocused顺序通过；没有真实配置/模型动作。
- [ ] **Step 5: 提交并审查。** `git commit -m "feat: project ASR model center state and actions"`。

## Task C2: 五种获取入口、测试音频与配置草稿

**Files:** Create HFModelInstallSheet/LocalASRServiceEditSheet/ValidationSampleStore；Modify existing cloud编辑/导入动作、Package.swift；Create `Sources/flowtype/Resources/ASRValidation/` 中中英WAV与README；Extend modelcenter tests。

**Interfaces:**
- Consume B1 resolve/B2 plan/B4 enqueue、A discovery/validation。
- Produce `ASRValidationSampleStore.load(language: WhisperLanguage) throws -> ASRValidationSample`；每个WAV≤8s、16kHz mono，README记录来源/生成命令/再分发依据/SHA256。
- HF sheet只收集仓库、revision、variant、tokenizer、下载源，预览显示固定commit/大小/许可证后enqueue；service sheet按协议决定model是否必填。保存仅按UUID/revision提交。

- [ ] **Step 1: 写 `testHFPreviewDoesNotDownloadWeights` / `testDraftAndServicePresetCapabilities` / `testValidationResourceContract`。** resolver预览无权重请求，用户未确认不enqueue；缺tokenizer明确提示；token被单独存储，错误不回显token；MLX请求json、cpp不要求model。中英资源格式/长度/摘要正确且加载不触发mic/网络，测试请求不含前台context。
- [ ] **Step 2: 验证 RED。** focused，预期缺入口或资源校验失败。
- [ ] **Step 3: 实现入口与资源。** 推荐/HF/目录/本机/云五入口接领域动作；HF多变体由用户选，gated提供浏览器授权链接；本机提供固定参考版本官方指引，安装由用户管理。试识别前说明目的地、样本与可能费用；用户可看输出判断质量，无虚构准确率。凭据保存失败保留草稿，不提交半个profile。
- [ ] **Step 4: 验证 GREEN。** focused及现有draft/试用回归通过；资源说明真实完整，Package.resolved不变。
- [ ] **Step 5: 提交并审查。** `git commit -m "feat: add ASR acquisition and explicit validation flows"`。

## Task C3: 原生列表、详情与安装任务界面

**Files:** Create View/Row/Detail/InstallationList；Modify `Settings/SettingsPage+ASR.swift`、NativeClientPreviewSelfTests、modelcenter tests。

**Interfaces:**
- Consume ViewModel；`ASRModelCenterView(model: ASRModelCenterViewModel)`替换现有识别模型区域，麦克风/语言设置继续在原识别页。
- 列表来源筛选/详情选择只存UI状态；下载操作按jobID调用pause/resume/cancel，清除部分文件是独立动作。
- Extend preview manifest记录model-center页面与loading/empty/error/long-content/download states，仍从隔离runtime根输出。

- [ ] **Step 1: 添加行为回归。** `testRowIdentityAfterReorder` / `testDownloadActionsTargetJobID`，排序/删除后操作仍落到正确backend/job；被占用文件的删除动作禁用且原因可读。仅此类行为写测试，不给padding/颜色写镜像断言。
- [ ] **Step 2: 验证 RED。** focused预期动作目标或缺页面投影断言失败。
- [ ] **Step 3: 实现紧凑原生界面。** 顶部主备/策略，列表与详情，五入口与可折叠任务；长路径复制、错误换行、下载字节进度、资源估计未知说明。原生键盘与VoiceOver标签、减少动态效果；沿用现有视觉，不改胶囊比例/其他主页面。
- [ ] **Step 4: 验证 GREEN 与渲染。** focused exit0；运行 `swift run --skip-build FlowType --self-test --native-client-previews-only`，按现有输出manifest检查1040×700/1120×760/1440×900、浅/深、长内容/空/失败/下载。真实滚动/焦点/辅助功能留D矩阵，不能只凭图片标Pass。
- [ ] **Step 5: 提交并审查。** `git commit -m "feat: present native ASR model library and installation tasks"`。

## Task C4: 应用所有权、旧入口和恢复闭环

**Files:** Modify `Settings/{SettingsWindowController,SettingsView,SettingsDestination,OnboardingView,TrialSessionPresenter,LocalModelPicker,CloudASRProviderList}.swift`、`Features/Onboarding/OnboardingPipeline.swift`、`App/FlowTypeApp.swift`、`Core/Readiness/ReadinessMonitor.swift`；Extend modelcenter/native tests；Create新版验收表。

**Interfaces:**
- 应用装配唯一installer/activation/modelcenter；窗口和tab不拥有领域task。
- 消费A6 `.asrBackend` target，增加 `.modelInstallation(UUID)` target；旧provider/localModels导航映射到对应新行/获取入口。
- 产出 `docs/superpowers/validation/2026-11-09-asr-model-center-acceptance.md`，H1–H8初始Pending；D2实现机器可读ledger和gate。

- [ ] **Step 1: 写 `testWindowRecreationKeepsOwnership` / `testRecoveryTargetsSpecificModel` / `testLegacyEntryUsesSameSelection`。** 下载/验证中关tab、重开窗口仍同一in-flight；旧callback不能换新选择；录音中编辑profile，当前输出仍原backend，下一次用新backend。缺模型/服务断连/下载失败分别定位实际ID；不存在ID回到识别页，不导航其他用户记录。
- [ ] **Step 2: 验证 RED。** focused/native-client，旧页面所有权/导航缺项断言失败。
- [ ] **Step 3: 接线与清理旧入口。** 首次引导、恢复卡片、试用、菜单使用同一个modelcenter；旧UI作为委托或移除重复路径，不能保留两套下载/选择行为。页内无隐藏自动下载/识别；不改变已有权限拒绝恢复与安全交付策略。
- [ ] **Step 4: 验证 GREEN。** focused、`--native-client-only`、`--m4-recovery-only`、`--m5-isolation-only`顺序通过；稳定提交后 `scripts/verify.sh --lane code` 全Pass。渲染确认后真实UI交互进入D，不在此任务虚报完成。
- [ ] **Step 5: 提交并整段审查。** `git commit -m "feat: integrate ASR model center across native client recovery"`；fresh review A–C整体接口与用户路径，修复Important/Critical再进入发行验证。
