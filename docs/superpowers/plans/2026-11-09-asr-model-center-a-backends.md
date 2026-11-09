# A — ASR Backends Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将云端、原生引擎和用户启动的本机服务接入同一可捕获、可验证的 ASR 后端体系。

**Architecture:** 稳定 ID + descriptor + binding 替代两个固定路由 slot；服务协议工厂注册，现有 native lease 与 DashScope 会话继续复用。能力、凭据和健康按配置版本隔离。

**Tech Stack:** Swift 6.2、Foundation URLSession、Security、现有 ASRProvider/ASRRouter/self-test。

**Spec:** [总设计](../specs/2026-11-09-asr-model-center-design.md) §3–6；[后端设计](../specs/2026-11-09-asr-backends-design.md)。依赖 D1 的已解释/通过基线。

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

1. 旧配置的自定义 URL/空型号/禁用项/孤立密钥必须可恢复，不能被新默认值覆盖（A1/A2）。
2. loopback HTTP 在断网时仍可用；redirect/localhost 实际非 loopback 不能上传音频（A3/A4）。
3. MLX 默认 NDJSON、whisper.cpp 服务端模型与未知 ASR 字段不能误判兼容（A3）。
4. 同厂商不同型号/凭据的健康与在途快照不串用，取消不会启动备选或重复落字（A4）。
5. 读取模型列表、配置合法、试识别成功必须是三种不同证据；迟到结果不能覆盖新草稿（A5/A6）。

## File Structure

新建 `Sources/flowtype/Services/Speech/Backends/` 下 `ASRBackendIdentity.swift`、`ASRBackendSelection.swift`、`ASRBackendDescriptor.swift`、`ASRBackendMigration.swift`、`ASRCredentialStore.swift`、`LocalASRServiceEndpoint.swift`、`ASRServiceAdapter.swift`、`OpenAICompatibleASRAdapter.swift`、`WhisperCppASRAdapter.swift`、`ASRBackendRouting.swift`、`ASRBackendHealthStore.swift`、`CapturedCloudASRProvider.swift`、`ASRModelDiscoveryClient.swift`、`ASRServiceValidationCoordinator.swift`、`ASRValidationSample.swift`。每个文件只承担其命名职责；共享 WAV/multipart 编码单独复用。

修改现有 Configuration/Store、ASRProviderRegistry、ASRRouter、ASRContract、CloudProviders、ASRStage、RecordingStage、PipelineOrchestrator、Readiness 与历史/恢复身份映射。测试分 `ASRBackendSelfTests.swift`、`ASRBackendTransportSelfTests.swift`、`ASRBackendRoutingSelfTests.swift`，统一由新 `--asr-backends-only` 调用，注册于 RuntimeEnvironment + SelfTest，完整 runner 也调用。

## Task A1: 后端身份、配置与兼容迁移

**Files:** Create Identity/Selection/Descriptor/Migration/ValidationSample；Modify `Core/Configuration.swift`、`Services/Speech/ASRContract.swift`、`App/RuntimeEnvironment.swift`、`Testing/SelfTest.swift`；Create `Testing/ASRBackendSelfTests.swift`。

**Interfaces:**
- Produce spec §1/2 的 ASRBackendID、Selection、Location、Descriptor、Binding、LocalASRServiceProfile 与 ASRServiceAuthentication；ASRServiceProtocol 也在本任务定义。
- Extend旧ProviderLocation.localService，区分requiresNetwork（socket）与descriptor.requiresInternet；local service分别true/false，保持原生/云端原值。
- Produce `ASRBackendMigration.selection(from: Configuration) -> ASRBackendSelection`；`Configuration.asrBackendSelection` / `.localASRServices`、`CloudASRProviderConfig.revision: UUID` 的兼容 decode；native descriptor revision=lease.id。
- Produce `ASRValidationSample: Sendable`，字段 samples:[Float]、sampleRate:Int、sha256:String、label:String；构造时拒绝非 16kHz/空样本。
- Produce `ASRBackendSelfTests.run(_ r: SelfTest.Reporter) async` 与聚焦 runner；后续测试文件通过本 runner 调用。

- [ ] **Step 1: 写 `testLegacySelectionAndStableIdentity` 与 `testValidationSampleContract`。** 从旧 Configuration 解码三种 policy；自定义 profile UUID、URL、空 model 与 active 状态原样保留；无本地文件也保留 reference；新启动与迁移的 cloudFallback 标志区分。

```swift
let profile = CloudASRProviderConfig.defaultSiliconFlow(isActive: true)
var config = Configuration()
config.cloudASRConfig.providers = [profile]
config.asrRoutingPolicy = .cloudOnly
let selection = ASRBackendMigration.selection(from: config)
r.eq(selection.primary?.rawValue, "cloud:" + profile.id.uuidString, "stable profile identity")
r.eq(selection.fallback, nil, "cloud-only never gains local fallback")
```

- [ ] **Step 2: 验证 RED。** `swift build` 预期新类型/迁移缺失；若编译通过，再运行 `swift run --skip-build FlowType --self-test --asr-backends-only`，预期迁移或 CLI 注册断言失败。保存实际错误，不把参数解析 exit64 当业务 RED。
- [ ] **Step 3: 实现上述类型和纯迁移。** binding 的 Equatable 比较 descriptor/lease.id/credentialGeneration；ID 不受行排序/改名影响。添加 filter 到 parser、focused 与 full runner；无真实配置写入。
- [ ] **Step 4: 运行 GREEN。** 顺序 `swift build`、`swift run --skip-build FlowType --self-test --asr-backends-only`；预期 exit0、0 failed；运行旧 `--m2-fix-only` 验证旧字段 decode 与配置默认无回退。
- [ ] **Step 5: 提交并审查。** `git add` 本 task 的明确文件；`git commit -m "feat: define stable ASR backend identities and migration"`。fresh review 聚焦迁移默认与 reference 稳定性。

## Task A2: 凭据读写与可重试 ASR key 迁移

**Files:** Create `Backends/ASRCredentialStore.swift`、`Testing/ASRCredentialSelfTests.swift`；Modify `Core/ConfigurationStore.swift`、`Settings/CloudASRConnectionCheck.swift`、`Settings/ASRProviderEditSheet.swift`、`Testing/ASRBackendSelfTests.swift`。

**Interfaces:**
- Consume A1 profile identity。
- Produce `ASRCredentialStore: Sendable`，`read(id: String) throws -> String?`、`generation(id: String) -> UUID`、`snapshot(id: String) throws -> ASRCredentialSnapshot`、`write(_ value: String, id: String) throws`、`remove(id: String) throws`；snapshot字段value:String?、generation:UUID，二者原子读取；`KeychainASRCredentialStore` 与注入内存 fixture。
- Produce `ASRCredentialMigration.migrate(configuration: Configuration, store: any ASRCredentialStore) -> ASRCredentialMigrationResult`，result 包含 configuration 与 pendingIDs:[String]。credential ID 旧引用为 `asr.cloud.<profile UUID>`；A2 评审 I1 原子提交修订新增 `CloudASRProviderConfig.credentialReferenceID: String?`（缺失为 nil），新不可变版本为 `asr.cloud.<profile UUID>.<fresh UUID>`；service/HF 仍为 `asr.service.<UUID>` / `asr.hf.official`。`credentialID: String` 为计算引用，读前通过 `validatedCredentialID()` 验证显式引用属于本 profile 且后缀为 UUID。显式引用缺失不得回退旧 key。先保存旧配置恢复源、写新引用并读回，最后单个配置 blob 同时提交 URL/model/protocol/revision + credential reference；失败不覆盖旧配对，不依赖回滚。删除使用新引用的空值 tombstone，提交前失败保留旧配对。旧引用与未提交 staged 项保留，安全清理后续处理；不持久化密钥正文到配置/journal。详见后端设计 §5 修订。

- [ ] **Step 1: 写失败回归。** `testWriteFailurePreservesPreviousCredential` 注入 update/add 错误；`testPartialMigrationRetriesWithoutLoss` 使用两个 key，第二个写失败；`testCredentialLockDoesNotClearSelection` 注入读拒绝；`testSerializedNewConfigHasReferencesOnly` 检查新 service/token 字段无正文。

```swift
// fixture 的第一个 write+read 成功，第二个 write 抛错。
r.eq(result.configuration.cloudASRConfig.providerAPIKeys[secondID], "fixture-second", "failed migration retained")
r.eq(result.configuration.cloudASRConfig.providerAPIKeys[firstID], nil, "only confirmed migration removed")
r.eq(result.pendingIDs.count, 1, "retry only unfinished key")
```

- [ ] **Step 2: 验证 RED。** 顺序 build 与上述 focused runner；预期未实现的 migration/错误状态断言失败。
- [ ] **Step 3: 实现 update/add 和逐 key 迁移。** 只在成功写入、读回、配置保存后移除旧副本；当前 KeychainHelper 的先 delete 再 add 不复用。现有 ASR 编辑/连接测试通过注入 store 取值，旧未迁移 key 继续读取；统一更新Configuration.effectiveCloudASRConfig及调用边界，不能迁移后仍只查空dict而误报不可用。成功改变值才更换随机generation，读取snapshot保证一致。序列化/redaction 与错误日志不带任意前缀 token；不迁移 LLM keys。
- [ ] **Step 4: 验证 GREEN。** focused 0 failed；运行 `--m5-isolation-only`，证明测试角色不会触碰系统 Keychain。fixture 验证二次迁移幂等及配置保存失败不会丢失最后可恢复 key。
- [ ] **Step 5: 提交并审查。** `git commit -m "feat: store ASR credentials with recoverable migration"`，审查在正常/锁定/部分成功/崩溃顺序上的行为。

## Task A3: 注册式 batch 适配器与端点边界

**Files:** Create endpoint/adapter/HTTP transport 文件和 `Testing/ASRBackendTransportSelfTests.swift`；Modify `Services/Speech/ASRProviderRegistry.swift`、`CloudProviders/CloudTranscriptionRequestBuilder.swift`、`CloudProviders/CloudASRVendor.swift`、`Core/Configuration.swift` 的 model presets、聚焦 runner。

**Interfaces:**
- Produce `ASRServiceAdapter`、`ASRProviderRegistry.init(adapters:) throws` / `.makeLocalServiceBinding(profile: LocalASRServiceProfile, credential: String?, credentialGeneration: UUID?) throws -> ASRBackendBinding`。
- Produce `LocalASRServiceEndpoint.transcriptionURL(profile: LocalASRServiceProfile) throws -> URL`。
- Produce `OpenAICompatibleASRAdapter` 与 `WhisperCppASRAdapter`，注入 URLSession/endpoint validator；不允许 service 使用 dashScopeRealtime。
- Transport 返回 `ASRResult`，错误准确转成取消、超时、认证、限流、响应错误；2MiB 读取上限，16kHz PCM16 WAV。

- [ ] **Step 1: 写 `testWireProfiles` / `testLoopbackBoundary` / `testUploadLimit`。** URLProtocol 捕获每个 multipart 字段和 URL；MLX/WhisperKit 必须 json，whisper.cpp 不含 model；unknown custom 不发送未知字段；OpenAI 新预设不覆盖旧 whisper-1。测试 localhost/127.0.0.1/[::1]、异常端口、userinfo、非 loopback IP、编码混淆与 redirect；注入真实连接目的验证分支，不能只测字符串。

```swift
r.eq(capturedPaths, ["/v1/audio/transcriptions", "/inference"], "protocol-owned paths")
r.eq(cppFields["model"], nil, "server-managed model")
r.eq(mlxFields["response_format"], "json", "avoid default NDJSON")
r.eq(redirectedAudioRequests, 0, "no redirected audio upload")
```

增加 JSON/NDJSON/HTML/空 text/错误状态/超大响应，以及计算 multipart 后超过 25,000,000 bytes 时零发送；精确阈值按该 profile 元数据，不全局套用。
- [ ] **Step 2: 验证 RED。** build/focused，现有 HTTPS-only / 必填 key/model 路径不能被当已满足。
- [ ] **Step 3: 实现工厂和协议。** endpoint 规则按 spec；loopback 禁代理/redirect，cloud 不被放宽。现有云端 builder 提取公共 multipart/WAV 逻辑但保留厂商能力。更新新建 OpenAI 默认及弃用 presentation 元数据，旧 profile 不自动改。registry 拒绝重复注册和不支持协议。
- [ ] **Step 4: 验证 GREEN。** focused 0 failed；原 `CloudProviderSelfTests` / M2 相关断言保持或依据新建预设有意更新。用注入 socket/transport 验证 localhost 解析为外部地址时失败；真实网络不属于 self-test。
- [ ] **Step 5: 提交并审查。** `git commit -m "feat: add registered local ASR protocol adapters"`；重点检查上传目的地、取消和响应格式。

## Task A4: 捕获 binding、通用候选与健康隔离

**Files:** Create Routing/HealthStore/CapturedCloudASRProvider、`Testing/ASRBackendRoutingSelfTests.swift`；Modify `Services/Speech/ASRRouter.swift`、`ASRContract.swift`、`Core/Pipeline/Stages/{ASRStage,RecordingStage}.swift`、`Core/PipelineOrchestrator.swift`、`Core/Pipeline/SessionContext.swift`。

**Interfaces:**
- Consume A1 descriptors/selection、A2 credentials、A3 registry。
- Produce `ASRBackendRouting.order(selection: ASRBackendSelection, policy: ASRRoutingPolicy, descriptors: [ASRBackendDescriptor], availableIDs: Set<ASRBackendID>, internetAvailable: Bool, degradedIDs: Set<ASRBackendID>) -> [ASRBackendID]`。
- Produce `ASRBackendHealthStore`，`recordSuccess(binding:latencyMs:)` / `recordFailure(binding:)`；revision 变动隔离旧健康。
- Extend `ASRRouteSnapshot.bindings: [ASRBackendBinding]`；生产 batch 仅遍历此数组，捕获 nativeLease/云端配置/凭据。旧 realtime 只从 DashScope binding 建 session。

- [ ] **Step 1: 写 `testCaptureIdentitySurvivesEdits` / `testPolicyAndNetworkMatrix` / `testCancelledPrimaryNeverFallsBack`。** capture 后换 URL/key/model/active native，再执行 provider，仍用 capture 原值；profile A 失败不能污染同厂商 B。断网时 service 可用；localOnly 排云，cloudOnly 排本机；本地主选无许可不向云备选发送。录音中换模型只有下一会话变化。

```swift
r.eq(actualRequests.map(\.model), ["captured-model"], "immutable model snapshot")
r.eq(nativeResultLeaseID, capturedLeaseID, "retained native runtime")
r.eq(cloudUploadsWithLocalConsentOff, 0, "local failure does not imply upload consent")
r.eq(deliveriesAfterCancel, 0, "late results never deliver")
```

另外覆盖 auto primary unhealthy 的两候选顺序、相同主备去重、整体 20s/云单次5s预算，以及 DashScope 不走 multipart。
- [ ] **Step 2: 验证 RED。** focused runner；旧固定 slot 或联网 gate 的行为断言应失败。
- [ ] **Step 3: 接入通用路由。** 在录音开始一次捕获 descriptors、credential generation、provider 与 native lease；清除停止/重试时重读 mutable settings 的残留。旧 ID 仅兼容读/迁移，健康按实际实例。复用既有 session generation、资源排空与 stop budget；不新增并行竞速。
- [ ] **Step 4: 验证 GREEN。** focused + `--m3-asr-regression-only` + `--m4-recovery-only`，顺序运行，全部 exit0。取消后 producer 迟到/忽略 cancellation 的 fixture 必须继续覆盖。
- [ ] **Step 5: 提交并审查。** `git commit -m "feat: capture versioned ASR backend bindings per session"`；fresh review 检查原实时启动、自动回退和真实身份没有回归。

## Task A5: 模型发现与主动试识别

**Files:** Create ModelDiscoveryClient/ServiceValidationCoordinator；Modify `Settings/CloudASRConnectionCheck.swift` 与 backend focused tests。

**Interfaces:**
- Produce `ASRModelDiscoveryClient.models(profile: LocalASRServiceProfile, credential: String?) async throws -> [String]` 与 `.models(cloudProfile: CloudASRProviderConfig, apiKey: String) async throws -> [String]`。
- Produce `@MainActor ASRServiceValidationCoordinator`，`test(profile: LocalASRServiceProfile, credential: String?, sample: ASRValidationSample) async`、`invalidate(profileID: UUID)`、`state(profileID: UUID) -> ASRServiceValidationState`。
- `ASRServiceValidationState` 为 idle/configurationValid/testing/verified(at:Date,text:String)/failed(code:String)；每次测试有 revision token 与独立 transport ownership 槽，配置 hash 包含全部 wire 字段和 credential generation。

- [ ] **Step 1: 写 `testDiscoveryIsNotRecognition` / `testStaleValidationOwnership`。** 404/405 列表为空且可手填，401/403 是错误，列表包含文本/TTS 型号也不宣称 ASR 兼容；10s timeout、1MiB/1000项上限；双击/删 profile/编辑后旧 completion 不写新状态。

```swift
r.eq(recognitionCallsAfterDiscovery, 0, "discovery never uploads test audio")
r.eq(stateAfterEdit, .idle, "edited revision needs a new test")
r.eq(testCallsAfterDoubleClick, 1, "one in-flight owner per profile")
```

- [ ] **Step 2: 验证 RED。** focused runner，预期缺少区分状态或 token 断言失败。
- [ ] **Step 3: 实现发现与验证。** 请求仅因用户动作启动；不读前台文本/词典/麦克风。错误内容使用稳定 code 和安全描述，保存验证日期但不持久化测试转写正文；超过60s的“上次验证”由 presentation 判断。DashScope 原配置检查不能升级成识别成功。
- [ ] **Step 4: 验证 GREEN。** focused 0 failed；原草稿、连接测试所有权回归保持通过。
- [ ] **Step 5: 提交并审查。** `git commit -m "feat: discover and validate ASR service models explicitly"`。

## Task A6: 就绪、历史和恢复使用实际后端

**Files:** Modify `Core/Readiness/{ReadinessMonitor,ReadinessSnapshot}.swift`、`Core/Pipeline/Stages/ASRStage.swift`、`Core/SessionMetrics.swift`、`Core/DictationHistory.swift`、`Core/Database/{AppDatabase,Records}.swift`、`Core/PipelineOrchestrator.swift`、`Settings/SettingsDestination.swift`；Extend backend tests。

**Interfaces:**
- Consume captured descriptor；readiness builder 增加 `backends: [ASRBackendDescriptor]` / `availableIDs: Set<ASRBackendID>` 注入，不创建真实服务进行探测。
- Extend `SettingsTarget` 为 `.asrBackend(ASRBackendID)`，旧 `.provider(UUID)` / `.localModels` 继续可解析。
- 新历史保存可选 `asrBackendID: String?`、`asrModelID: String?`、`asrLocation: String?`；旧行 decode 默认 nil，未知品牌不强制显示 Qwen。

- [ ] **Step 1: 写 `testOfflineServiceReadiness` / `testActualBackendHistoryAndRecovery`。** 互联网断开而本机 service 通过时可准备；未安装/已安装未加载/Keychain锁定不能伪装 ready；真实 fallback 结果写实际 ID/model/location；旧历史显示兼容标签。
- [ ] **Step 2: 验证 RED。** focused runner 旧 cloud/local 聚合假设失败。
- [ ] **Step 3: 接线状态与导航。** 从统一后端投影构造 readiness、metrics、recovery target；Apple preview 继续作为现有明确后备机制，不注册成新增可选模型。DB 增字段需要沿用现有 GRDB migration 与旧配置兼容，不重建用户数据库。
- [ ] **Step 4: 验证 GREEN。** focused、`--native-client-only`、`--m3-asr-regression-only` 全部通过；提交稳定源码后运行一次 `scripts/verify.sh --lane code`，预期所有阶段 Pass。真实服务仍 Pending。
- [ ] **Step 5: 提交并整段审查。** `git commit -m "feat: expose actual ASR backend readiness and history"`；fresh review A 全范围，修复 Important/Critical 后交 B，不把 fixture 成功当厂商验收。
