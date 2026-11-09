# B — HF Model Installation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 从推荐配方、HF 仓库或已有目录取得完整原生模型，支持中断恢复、离线试识别、可靠激活和受控删除。

**Architecture:** HF 元数据 resolver 产出固定 commit 的 install plan；actor 安装器将文件写入 staging，校验后原子发布，再复用原生生命周期激活。安装库、active lease 与下载 job 分开。

**Tech Stack:** Swift 6.2、Foundation URLSession delegate、CryptoKit、现有 Qwen/Whisper 检测器与生命周期协调器、self-test。

**Spec:** [总设计](../specs/2026-11-09-asr-model-center-design.md)；[HF 安装设计](../specs/2026-11-09-hf-model-installation-design.md)。依赖 A1/A2 的身份、sample 和 credential store，以及 A4 的 native binding。

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

1. HF 标签为空、多变体、带 slash 的 revision、分页重复或循环不能选错来源（B1/B2）。
2. tokenizer 位于另一仓库或 Core ML 图不匹配时，不能静默联网或标 ready（B2/B5）。
3. 200/206/416、截断、HTML/LFS pointer、过期 CDN URL 不能破坏续传完整性（B3）。
4. rename 后注册前进程终止、磁盘满、暂停取消晚回调不能产生半安装或覆盖旧模型（B4）。
5. 旧 preset/用户目录/活动录音交错时，删除和迁移不能损坏已有文件或在用 lease（B5/B6）。

## File Structure

新 `Services/Speech/ModelInstallation/`：`HFRepositorySelection.swift`、`HFRepositoryClient.swift`、`HFRepositoryMetadata.swift`、`ASRInstallPlan.swift`、`ASRInstallPlanner.swift`、`ASRModelRecipes.swift`、`HFDownloadTransport.swift`、`HFDownloadJournal.swift`、`ModelInstallationCoordinator.swift`、`ModelInstallSnapshot.swift`、`ModelInstallationPublisher.swift`、`ASRInstalledModelRecord.swift`、`NativeASRActivationCoordinator.swift`、`NativeModelUsageRegistry.swift`。新 `LocalModelManager/{LocalASREngineAdapter,LocalASRRuntimeRegistry,QwenMLXEngineAdapter,WhisperCoreMLEngineAdapter}.swift` 为原生引擎注册与适配。

修改 LocalModelManager 中 Inspector/Library/Downloader/Preset、ModelProvisioning 的 request/lease、QwenModelState、RuntimePaths、Configuration。测试为 `HFRepositorySelfTests.swift`、`HFInstallPlannerSelfTests.swift`、`HFDownloadSelfTests.swift`、`HFInstallTransactionSelfTests.swift`、`NativeActivationSelfTests.swift`，由 `HFInstallSelfTests.run(_:) async` 汇总，新增 `--hf-install-only`，也接 full runner。

## Task B1: HF 仓库输入、固定版本与完整元数据

**Files:** Create Selection/Client/Metadata 与 `Testing/{HFRepositorySelfTests,HFInstallSelfTests}.swift`；Modify RuntimeEnvironment/SelfTest 注册。

**Interfaces:**
- Produce `HFRepositorySelection`、`HFFileDigest`、`HFPlannedFile`（字段按 spec）；`HFRepositoryFile: Codable, Equatable, Sendable`（remotePath:String、sizeBytes:Int64、digest:HFFileDigest）。
- Produce `HFResolvedRepository: Sendable`（selection:HFRepositorySelection、commit:String、downloadEndpoint:URL、files:[HFRepositoryFile]、licenseURL:URL?）。
- Produce `HFRepositoryInput.parse(_ input: String, revision: String?, subdirectory: String?) throws -> HFRepositorySelection`；tree/blob 有歧义时返回结构化选择错误，不猜 revision 边界。
- Produce `HFRepositoryClient.resolve(_:credentialID:) async throws -> HFResolvedRepository`；`.readMetadata(file: HFRepositoryFile, repository: HFResolvedRepository) async throws -> Data`，URLSession 与 credential store 注入。

- [ ] **Step 1: 写 `testRepositoryInput` / `testPinnedCommitPagination` / `testMetadataLimitsAndAuth`。** 测 repo ID/HTTPS/tree/blob；slash revision 显式字段可用；../、编码穿越、dataset、query token、NUL 拒绝。fixture 两页+Link，branch 首次 commit=A、后续 branch变B，所有后续请求仍用A；缺 pipeline_tag 不失败。401/403/404、游标循环、外源 Link、10001文件、16MiB JSON和求和溢出准确失败。

```swift
r.eq(resolved.commit, String(repeating: "a", count: 40), "freeze branch revision")
r.eq(resolved.files.count, 7, "all paginated files retained")
r.eq(followupRevisions, [resolved.commit, resolved.commit], "no moving-main requests")
r.eq(headersToMirror["Authorization"], nil, "HF token stays official-origin only")
```

- [ ] **Step 2: 验证 RED。** `swift build`，编译通过后 `swift run --skip-build FlowType --self-test --hf-install-only`；预期新 client/固定版本断言失败。
- [ ] **Step 3: 实现受限元数据查询。** model API revision 与 tree 编码按官方 schema；文件路径逐段验证，完整遍历并检测重复冲突。token 只从显式 credential ID 读取，测试不构造默认 HubApi 去读全局 token。source/credential origin 被显式捕获，重定向策略与语音上传分开。
- [ ] **Step 4: 验证 GREEN。** build/focused exit0，fixtures ≤小型合成元数据，零权重下载/零真实令牌。
- [ ] **Step 5: 提交并审查。** `git commit -m "feat: resolve pinned Hugging Face model repositories"`。

## Task B2: 原生兼容预检与多来源安装配方

**Files:** Create Plan/Planner/Recipes、`Testing/HFInstallPlannerSelfTests.swift`；Create `LocalModelManager/{NativeASRFormatSupport,LocalASREngineAdapter,LocalASRRuntimeRegistry,QwenMLXEngineAdapter,WhisperCoreMLEngineAdapter}.swift`；Modify ASRModelInspector、WhisperModelInspector、ModelPreset、LocalASRRuntimeFactory。

**Interfaces:**
- Consume B1 metadata/readMetadata；produce spec 的 `ASRInstallPlan`。
- Produce `NativeASRFormatSupport.assessMetadata(config: Data?, paths: [String]) throws -> LocalASREngine`，从现有 detector 抽取共享 metadata 规则；仅预检候选，不代替完整 tensor 检查。
- Produce spec §6 的LocalASREngineAdapter/LocalASRRuntimeRegistry，registry的 `.engine(config: Data?, paths: [String]) throws -> LocalASREngine` / `.load(_ model: ImportedASRModel) async throws -> LocalASRLease`；NativeASRFormatSupport委托registry。LocalASRRuntimeFactory保留统一重检后委托具体adapter加载；Qwen具体检查入口改为内部可调用，避免adapter回调总dispatcher造成递归。
- Produce `ASRInstallPlanner.plan(repository: HFResolvedRepository, variant: String?, tokenizer: HFResolvedRepository?) async throws -> ASRInstallPlan`。
- Produce `ASRModelRecipe`（id:String、version:Int、displayName:String、sources:[HFRepositorySelection]、variant:String?、engine:LocalASREngine、verified:Bool）与 `ASRModelRecipes.all`。候选 revision 来源见研究快照，执行时读取当前指定 commit 元数据，不能使用浮动 main 作为最终 plan。

- [ ] **Step 1: 写 `testMinimalModelFileClosure` / `testWhisperTokenizerRecipe` / `testVariantAndBudgetRejections` / `testNativeEngineRegistration`。** 合成 Qwen 单文件/分片索引，闭包包含所有权重+必要配置；Whisper 根多个变体必须选择，tiny只包含tiny的图与对应tokenizer来源。未知 Whisper 缺 tokenizer 需补选，不能自动配tiny；误传PyTorch/GGUF/不兼容MLX拒绝。总预检超32MiB、目标路径碰撞/绝对路径失败。两个同engine adapter注册失败，未知/多匹配metadata不靠顺序选，注入stub adapter的load能被工厂调用，核心stage不感知具体engine。

```swift
r.eq(Set(plan.files.map(\.resolvedCommit)), Set([coreMLCommit, tokenizerCommit]), "both sources pinned")
r.check(plan.files.allSatisfy { !$0.remotePath.contains("openai_whisper-large") }, "only selected variant")
r.eq(Set(plan.files.map(\.relativeDestination)).count, plan.files.count, "no destination collisions")
```

- [ ] **Step 2: 验证 RED。** build/focused，缺二来源安装或整仓选择的断言失败。
- [ ] **Step 3: 实现精确文件闭包。** 索引文件引用的相对权重必须存在；Whisper各选中CoreML package资源递归保留。两Qwen配方保留，增加tiny/base多语言候选；base tokenizer revision执行时解析一次冻结。许可证缺失显示未知，不自动许可同意。静态元数据限制与现有 inspector 同源，不创建更宽松支持清单。
- [ ] **Step 4: 验证 GREEN。** focused + 旧 `--m2-review-inspection-only` / `--m2-review-packages-only` 顺序通过，证明抽取规则没放宽实际加载。
- [ ] **Step 5: 提交并审查。** `git commit -m "feat: plan complete compatible ASR model installations"`。

## Task B3: 流式下载、摘要与可信续传

**Files:** Create DownloadTransport/Journal、`Testing/HFDownloadSelfTests.swift`；复用 RuntimePaths 的隔离根。

**Interfaces:**
- Produce `HFDownloadTransport.transfer(file: HFPlannedFile, partialURL: URL, credentialID: String?, progress: @escaping @Sendable (Int64) -> Void) async throws`；生产 URLSession delegate、fixture transport 注入。
- Produce `HFDownloadJournal: Codable, Sendable`（file:HFPlannedFile、writtenBytes:Int64、validator:String?）；仅保存 credential ID 引用，不存正文、签名 URL 或响应正文；downloadEndpoint 由 planned file 捕获。
- Produce `HFFileVerifier.verify(file: HFPlannedFile, at: URL) throws`，流式 SHA256/Git blob SHA1、大小与 LFS-pointer 检查；错误 code 固定区分 auth/rateLimit/network/integrity/diskFull/cancelled。

- [ ] **Step 1: 写 `testRangeResponses` / `testRenewedResolveURL` / `testDigestFormats` / `testTransportCancellation`。** partial 4bytes，206 start4正确；206start3失败；200返回8bytes必须截断后8；416 full+hash正确才成功，否则重启一次；同长损坏失败。签名URL过期从同commit resolve刷新，旧URL/token不在journal或日志；重试最多3次、退避1s/2s、Retry-After>30s暂停。pause/cancel迟到progress不被接受。

```swift
r.eq(finalBytes, Data("abcdefgh".utf8), "200-on-range restarts instead of appending")
r.eq(try Data(contentsOf: resumedFile).count, 8, "resume exact length")
r.eq(untrustedRedirectAuthorization, nil, "no bearer on CDN redirect")
r.eq(attemptsForPermanent403, 1, "permission failure does not retry")
```

另用会流式输出的 fixture 验证上层只持有有界chunk，不能对权重调用data(for:)；测试HTTP错误HTML/LFSpointer/零长度/truncated/摘要错误。
- [ ] **Step 2: 验证 RED。** build/focused；旧Hub snapshot的通用2xx逻辑不能用作本测试的实现。
- [ ] **Step 3: 实现字节和响应状态机。** 用URLSession delegate串行写盘；Range规则、最多5跳HTTPS CDN、每文件60sidle超时。每次重试重新读取已写长度，固定manifest；Git SHA1加入`blob <size>\0`前缀。取消返回后transport drain才释放所有权。
- [ ] **Step 4: 验证 GREEN。** focused通过；注入磁盘写失败/取消/过期签名证明不安装坏文件。fixture HTTP server如需监听，仅绑定系统分配loopback端口，随测试清理。
- [ ] **Step 5: 提交并审查。** `git commit -m "feat: download ASR files with verified resumable transfers"`。

## Task B4: 持久任务、原子发布与库注册

**Files:** Create InstallationCoordinator/Snapshot/Publisher/InstalledModelRecord、`Testing/HFInstallTransactionSelfTests.swift`；Modify `Core/Configuration.swift`、`App/RuntimePaths.swift`、`LocalModelManager/LocalModelLibrary.swift`。

**Interfaces:**
- Produce spec 的 `ModelInstallState` / `ModelInstallSnapshot` / `ASRInstalledModelRecord` / ownership，`Configuration.installedASRModels`默认空。
- Produce actor `ModelInstallationCoordinator` 的 enqueue/pause/resume/cancel/recover/snapshots（签名按spec）；通过初始化参数注入 transport、publisher、clock、disk sample、journal root。
- Produce `ModelInstallationPublisher.publish(plan: ASRInstallPlan, staging: URL) async throws -> ASRInstalledModelRecord`；先完整检查、manifest、原子rename，再幂等注册。生产配置更新封装到MainActor闭包。

- [ ] **Step 1: 写 `testPersistentQueueRecovery` / `testPublishCrashBoundaries` / `testCancelGenerationAndDiskAdmission`。** 多job只1活动transport，进度按字节；下载时terminate→recover为paused且零请求；设置改源后恢复仍用plan捕获的downloadEndpoint/credential ID。rename前/后、注册前/后注入崩溃，两次recover无重复记录。取消后旧completion不能publish。空磁盘与不足`remaining+max(256MiB,total/10)`时零下载，运行中diskFull不改active。

```swift
r.eq(maximumConcurrentTransfers, 1, "one active download owner")
r.eq(requestsAfterRecover, 0, "restart requires explicit resume")
r.eq(recoveredRecords.filter { $0.id == installedID }.count, 1, "publication idempotent")
r.eq(activeLeaseAfterInstall, activeLeaseBeforeInstall, "installing is not activation")
```

- [ ] **Step 2: 验证 RED。** build/focused，现有单preset状态不足以通过。
- [ ] **Step 3: 实现actor/journal事务。** managed staging与final同文件系统；写manifest后原子move。发现未完成发布按manifest恢复；缺/坏manifest不能标installed或删除外部目录。每次resume重新采样磁盘、验证固定plan。journal仅写非敏感字段，损坏job隔离显示失败，其他job不受影响。
- [ ] **Step 4: 验证 GREEN。** focused + `--m5-isolation-only`，临时根外无读写；检查旧配置缺installed数组可decode。
- [ ] **Step 5: 提交并审查。** `git commit -m "feat: persist and atomically publish ASR installations"`。

## Task B5: 候选试识别与唯一原生激活所有权

**Files:** Create NativeASRActivationCoordinator、`Testing/NativeActivationSelfTests.swift`；Modify `Services/Speech/QwenModelState.swift`、`ModelProvisioning/{ModelProvisionRequest,LocalASRLease}.swift`、`LocalModelManager/LocalASRRuntimeFactory.swift`。

**Interfaces:**
- Consume A1 ASRValidationSample、B4 installed records与现有严格inspector/硬件准入。
- Produce `@MainActor NativeASRActivationCoordinator.activate(modelID: UUID, sample: ASRValidationSample) async throws -> LocalASRLease`；通过组合/抽取QwenModelState的唯一operation gate实现，不新增第二个activeLease。
- Produce spec 的 `ASRNativeValidationRecord`；通过候选load、transcribe、指纹与generation复核后和选择一起提交；modelID一律为importedModelID，不是安装记录id。
- Produce `unloadCurrentAfterDrain() async throws` 显式动作：仅无录音、无捕获资源时卸载，失败不能假称旧runtime保留。

- [ ] **Step 1: 写 `testCandidateValidationIsTransactional` / `testOfflineValidationAndFingerprint` / `testActivationCancelDrain`。** stubload成功但text为空/抛错不换旧lease；旧+新预算不足不加载；file或engine/adapter兼容版本变动拒绝旧验证。候选不联网补tokenizer；验证不读mic；cancel抵抗推理排空前第二次activate不启动。20s验证deadline通过注入clock验证，无需实际等待20s。

```swift
r.eq(selectionAfterEmptyResult, originalSelection, "load success alone cannot select")
r.eq(activeLeaseAfterCancelledCandidate, originalLease, "cancel preserves usable runtime")
r.eq(internetCallsFromNativeValidation, 0, "strictly offline validation")
r.eq(maximumCandidateLoads, 1, "one activation lifecycle")
```

- [ ] **Step 2: 验证 RED。** focused，现有load即commit的行为应失败。
- [ ] **Step 3: 提取/组合公共激活流程。** 保留现有取消、源gate、成功提交与自动1.7→0.6恢复语义；明确手选自定义不自动改模型。新模型入口走验证事务；旧preset启动恢复检查既有验证记录/文件指纹，再离线加载，不在启动自动上传或播放。验证音频由C2资源注入，领域测试用小PCM与stub。
- [ ] **Step 4: 验证 GREEN。** focused、`--m2-fix-only`、`--m3-asr-regression-only`顺序通过；跨Qwen/Whisper切换保持capture lease。
- [ ] **Step 5: 提交并审查。** `git commit -m "feat: validate native ASR candidates before activation"`。

## Task B6: 托管归属、在用文件保护与旧模型衔接

**Files:** Create NativeModelUsageRegistry；Modify LocalASRLease、LocalModelLibrary、ModelDownloader、ModelPreset、ModelInstallationCoordinator、ImportedASRModelActions、ASRRouter的native binding构造；Extend transaction/activation tests。

**Interfaces:**
- Produce `NativeModelUsageRegistry.acquire(modelID: UUID) throws -> ModelUsageToken`、`.reserveDeletion(modelID: UUID) throws -> ModelDeletionPermit`；二者互斥，token/permit为可跨任务保留的引用，析构释放对应占用。registry锁保护原子检查+保留，不能先canDelete再异步删除。
- `LocalASRLease` 增加可选usageToken，active/captured/candidate lease都持有；旧无token来源先登记为external，不允许managed删除。
- Produce `ModelInstallationCoordinator.remove(modelID: UUID, deleteManagedFiles: Bool) async throws`；external即使true也拒绝删文件；managed删文件要求manifest/归属与删除permit。移除active记录需用户显式解除选择且已有会话排空。

- [ ] **Step 1: 写 `testDeleteWhileOldSessionOwnsLease` / `testExternalAndAliasProtection` / `testLegacyPresetAdoption`。** 切新模型后旧录音仍占用旧token，删除失败；token释放后可删；删除permit保留时新acquire失败。external/symlink越界/伪造manifest/大小写别名不能删用户文件。移除managed记录但保留文件后recover不重新注册；detached journal写失败则保留记录。旧preset路径可用时不重下，import UUID稳定，旧任务恢复不改source。

```swift
r.eq(externalFileBytesAfterRemoval, originalBytes, "external files are never owned")
r.eq(deletionsWhileCapturedLeaseAlive, 0, "old session retains model files")
r.eq(downloadsWhenAdoptingExistingPreset, 0, "existing model reused")
```

- [ ] **Step 2: 验证 RED。** focused，现有deleteModel直接removeItem应无法满足保护。
- [ ] **Step 3: 统一入口与保护。** 新preset下载委托B4安装器，激活委托B5；ModelDownloader仅作旧UI兼容facade，不再拥有独立下载task。保留旧版本路径识别，不能一律通过新路径存在性判未安装；旧native:preset ID不在后台改写，新安装以native:import ID加入。移除保留文件先持久化libraryDetached，再移除记录，recover尊重detached。源变化不改进行中manifest，清除partial只处理该job所有权路径。
- [ ] **Step 4: 验证 GREEN。** focused、旧M2 lifecycle、A聚焦通过；提交稳定源码后一次 `scripts/verify.sh --lane code` 全Pass。实际模型仍待D矩阵，不能标verified=true。
- [ ] **Step 5: 提交并整段审查。** `git commit -m "feat: protect model ownership and integrate managed installations"`；fresh review B全范围，重点审查删除、崩溃恢复与tokenizer完整性。
