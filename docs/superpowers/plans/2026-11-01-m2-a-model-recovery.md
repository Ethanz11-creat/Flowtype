# M2-A Model Recovery Implementation Plan

**执行状态（2026-11-02）：** 已批准并按 A → B → C 执行。A1/A2/A3 源码、回归、提交及阶段修复审查完成；最终阶段检查点 eb840f8，1619 passed / 0 failed。GUI/真实模型及 V1–V5 未运行变体 Pending。最终全 M2 门禁由控制器在 C4 提交后执行。

证据：[M2 checkpoints](../../evidence/2026-11-01-m2-validation.md)、[V1–V5](../../evidence/2026-11-01-live-validation.md)、[A/B/C rulings](../../evidence/2026-11-01-m2-rulings.md)。空框若包含真实验收/最终审查，表示该部分待完成；历史计划正文保留，不把先前基线当作当前状态。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让两个本地预设的下载、加载、取消和失败恢复可诊断，并为自定义ASR引擎建立共享生命周期。

**Architecture:** QwenModelState是唯一模型操作协调器，创建独立候选provider，成功后发布不可变的本地模型lease。独立URLSession预检先解释元数据问题；ModelDownloader只保留兼容展示入口。录音开始时捕获lease，切模型不改变进行中的识别。

**Tech Stack:** macOS15+、Swift6.2、Combine、URLSession、speech-swift/SPM、既有self-test。

**Spec:** [M2总设计](../specs/2026-11-01-m2-model-recovery-design.md)，本计划对应M2-A。

## Global Constraints

- 仅在既有flowtype-local工作树开发；不push、不merge、不改历史。
- 不删除现有模型或应用URL缓存，不访问真实Key/音频/配置作为测试fixture。
- 保留现有路由及Apple-basic授权规则，不改变交付策略。
- 预检HEAD超时10秒、相对同源跳转最多5跳、缓存禁用；日志只含安全摘要。
- primary最多3次、网络退避10/20秒、无进度30秒；自动推荐1.7B失败仅额外一次0.6B。
- 显式选择不自动降级；取消不降级；可用旧模型保留至候选成功且操作仍拥有提交权。
- 每次验证依次`swift build`、`swift run FlowType --self-test`，不运行`swift test`。
- 在M2-A→M2-B→M2-C顺序执行；各计划独立提交、独立检查，主线V验收不以fixtures替代。

## Review Focus

1. 被取消的加载晚到成功时，不替换新状态、不卸载新模型（Task2）。
2. 正在用的模型切换失败后，readiness和进行中的录音仍使用旧模型（Task2/3）。
3. 显式1.7B搜索legacy缓存不能认领0.6B；custom来源不能冒称官方（Task1/3）。
4. 无元数据的308、跨源Location和含密钥参数的错误不得泄漏或开启昂贵重试（Task1）。
5. 终止失败、取消和重复点击后，真实任务与UI一致且可以重新发起（Task2/3）。

## File Structure and Shared Interfaces

- New `Services/Speech/ModelProvisioning/ModelProvisionError.swift`: 错误类别、HTTP/端点安全摘要与retry策略。
- New `.../ModelMetadataPreflight.swift`: 独立同栈HEAD预检；不管理权重。
- New `.../LocalASRLease.swift`: `LocalModelIdentity`与`LocalASRLease`，供路由/后续导入共享。
- New `.../ModelProvisionRequest.swift`: 操作快照、来源与目标。
- Existing QwenModelState、ModelDownloader、QwenASRProvider、ModelLocator：协调、候选加载与缓存身份。
- Existing ASRRouter/ASRContract/ASRStage/Registry、ReadinessMonitor、模型卡片与Onboarding：消费真实active lease。
- New `Testing/ModelProvisionSelfTests.swift`，在SelfTest.runAndExit注册；测试辅助留在同文件。

## Task 1: 元数据预检与真实模型定位

**Files:** Create上述error/preflight文件；Modify `Services/Speech/ModelLocator.swift`、`DownloadSource.swift`；Test `Testing/ModelProvisionSelfTests.swift`、注册`Testing/SelfTest.swift`。

**Interfaces:**
- Produce `ModelEndpointSummary: Sendable, Equatable`（host、safePath、httpStatus）；禁止query/userinfo。
- Produce `ModelProvisionError: Error, Sendable, Equatable`（metadataInvalid、network、stalled、incompleteLocal、loadFailed、insufficientDisk），带可选安全摘要；取消使用CancellationError。
- Produce `ModelMetadataPreflight.init(session: URLSession)`、`check(repoID: String, endpoint: URL) async throws -> ModelEndpointSummary`。
- Keep `ModelLocator.resolveActiveModel(config:) -> ResolvedModel?`；显式身份匹配含legacy路径，不再以体积认领其他preset。

- [x] **Step 1: 写失败回归。** 用URLProtocol、内存配置和临时目录构造固定响应/文件；测试入口`ModelProvisionSelfTests.runPreflight(_ r: SelfTest.Reporter) async`。断言：

```swift
r.eq(loaderCallsAfterInvalid308, 0, "invalid metadata never starts weights")
r.eq(relativeRedirectMethods, ["HEAD", "HEAD"], "redirect preserves HEAD")
r.eq(crossOriginRequests, 0, "cross-origin location is not followed")
r.eq(capturedRequest.timeoutInterval, 10, "preflight timeout")
r.check(!diagnostic.contains("secret"), "query/userinfo/body redacted")
r.eq(explicit17WithOnly06LegacyCache, nil, "legacy identity stays explicit")
```

同时覆盖200/302完整commit、etag、正size、有效location；缺字段/308/401/404/429/5xx、非HTTP、超时、超过5跳、无效custom端点、custom展示身份。每个失败需断言具体分类及是否可重试。
- [x] **Step 2: 验证RED。** `swift build`预期新增生产类型未定义而失败；若先写成现有API回归，则执行self-test并看到相关断言失败，记录原因。
- [x] **Step 3: 实现预检和定位。** ephemeral+nil cache+reloadIgnoringLocalCacheData，delegate保留HEAD并限制跳转；200/完整302与底层Hub消费一致。network/429/5xx可按瞬时策略恢复，确定性metadata/4xx不盲重试。按已知路径或可验证模型元数据确定legacy身份。custom URL只接受HTTPS或明确loopback HTTP，拒绝userinfo/query/fragment。
- [x] **Step 4: 验证GREEN。** 依次`swift build`、`swift run FlowType --self-test`，exit0且失败数0；检查fixtures未发真实网络请求。
- [x] **Step 5: 提交。** `git add`仅本任务文件，`git commit -m "feat: preflight model metadata and preserve preset identity"`。

## Task 2: 单一操作协调、候选提交与一次降级

**Files:** Create上述lease/request文件；Modify `QwenModelState.swift`、`QwenASRProvider.swift`、`LocalModelManager/ModelDownloader.swift`；Extend ModelProvisionSelfTests。

**Interfaces:**
- Consume Task1预检/错误。
- Produce `LocalModelIdentity: Codable, Sendable, Equatable`（id:String、displayName:String、engine:String、repoID:String?、directory:URL）；`LocalASRLease: Sendable, Equatable`（id:UUID、identity:LocalModelIdentity、provider:any ASRProvider），等值只比较lease id。
- Produce `ModelProvisionOrigin`（automatic、manual、offlineImport）和`ModelProvisionTarget`（preset(ModelPreset)、offline(ResolvedModel)）；`ModelProvisionRequest`保存target/source/origin。
- Produce `QwenModelState.perform(_ request: ModelProvisionRequest) async`、`cancel()`；published `activeLease: LocalASRLease?`、`failure: ModelProvisionError?`、`operationID: UUID?`、`didAutoFallback: Bool`。保留status和既有loadModel/handleDownloadCompleted兼容签名。
- Init注入`preflight: @Sendable (ModelPreset, DownloadSource) async throws -> Void`、`load: @Sendable (ModelProvisionTarget, Bool, @escaping @Sendable (Double) -> Void) async throws -> LocalASRLease`、`sleep: @Sendable (Duration) async throws -> Void`、`now: @Sendable () -> Date`、`configuration: @MainActor () -> Configuration`。保留既有`loadDownloadedPreset`测试便利初始化。

- [x] **Step 1: 写失败回归。** 增加`runCoordinator(_:) async`，使用可控continuation loader与注入时钟，断言：

```swift
r.eq(autoAttempts, ["1.7B", "1.7B", "1.7B", "0.6B"], "bounded fallback")
r.eq(backoffSeconds, [10, 20], "primary network backoff")
r.eq(explicit17FallbackCalls, 0, "manual choice preserved")
r.eq(cancelledFallbackCalls, 0, "cancel never degrades")
r.eq(state.activeLease?.id, oldLease.id, "failed candidate retains usable model")
r.eq(staleCompletionCommitted, false, "old operation cannot publish")
```

另覆盖本地成功零preflight、primary预检确定性失败仅一次且auto仍可试0.6、fallback失败不递归、30秒无进度、watchdog取消与用户取消区别、重复点击、取消未收尾禁止新底层并发、失败后重试可启动、磁盘不足、HF_ENDPOINT恢复和串行隔离。fixture失败只注入错误，不改用户模型。
- [x] **Step 2: 验证RED。** 执行build或self-test，预期缺少协调接口或旧实现的生命周期断言失败。
- [x] **Step 3: 实现协调与候选提交。** 每次候选用独立QwenASRProvider，load成功后检查取消和operationID才发布lease；旧provider由旧lease持有，不提前unload。串行化底层工作和HF_ENDPOINT，并在结束后恢复原环境；取消继续等待底层退出才释放操作所有权。明确计算底层speech-swift内部重试，不误称3次就是3个HTTP请求。进度回调绑定当前实例/operationID，不再写`.shared`。ModelDownloader仅映射协调状态，terminal记录不阻止下一次请求。离线显式导入失败直接结束。
- [x] **Step 4: 验证GREEN。** 顺序build/self-test exit0，全部新生命周期回归通过；M1终端加载失败回归仍通过。
- [x] **Step 5: 提交。** `git commit -m "feat: coordinate model recovery and retain active model"`（先精确git add本任务文件）。

## Task 3: 真实身份、录音快照与恢复UI

**Files:** Modify `ASRContract.swift`、`ASRRouter.swift`、`ASRProviderRegistry.swift`、`Core/Pipeline/Stages/ASRStage.swift`、`Core/PipelineOrchestrator.swift`、`Core/Readiness/ReadinessMonitor.swift`、`App/FlowTypeApp.swift`、`Settings/{QwenModelStatusCard,ASRModelStatusCard,LocalModelPicker,OnboardingView}.swift`；Extend ModelProvisionSelfTests。

**Interfaces:**
- Consume `activeLease`和Task2所有生命周期接口。
- Extend `ASRRouteSnapshot`：`localLease: LocalASRLease? = nil`；录音开始时获取，ASRStage本地尝试使用捕获的provider。现有legacy `qwen-local`仅作为兼容的本地路由slot，不作为实际模型标签。
- Add `ASRProviderID.local = ASRProviderID.qwenLocal`作为统一命名别名；保留旧字符串和旧常量兼容回归/历史，不新增第二条并行本地路由。
- Produce `ModelRecoveryPresentation.make(active: LocalModelIdentity?, target: ModelPreset?, failure: ModelProvisionError?, didAutoFallback: Bool) -> ModelRecoveryPresentation`（新增`ModelProvisioning/ModelRecoveryPresentation.swift`），集中显示名、repo、source、复制命令与动作。
- Extend ReadinessSnapshotBuilder.make：`localUsable: Bool = false`；只要active lease可用，候选操作失败不使本地不可用。订阅status与activeLease。

- [x] **Step 1: 写失败回归。** `runPresentationAndRouting(_:) async`断言旧lease在录音开始后切换仍接收完整样本，新会话才用新lease；active旧+target失败readiness为ready；1.7B卡片/命令均为1.7B；fallback标签为“已退回 0.6B”且selectedLocalModelID为nil；custom显示custom；stall结束无假重试文案。手动“改用0.6B”才清冲突custom路径。引导“稍后配置”保留未就绪状态，Apple-basic只在auto生效。
- [x] **Step 2: 验证RED。** build/self-test看到上述旧身份、快照或readiness断言失败。
- [x] **Step 3: 接入UI与路由。** 卡片分别显示可用模型和目标操作，恢复动作走同一协调器；源选择说明下一次重试使用。folder picker先统一走现有离线入口，M2-C再替换为模型库导入。pipeline/history诊断使用lease的engine标签，不能将将来的Whisper写成qwen。旧`SessionController.qwenProvider`启动路径迁移至共享状态入口。
- [x] **Step 4: 验证GREEN与证据。** 顺序build/self-test exit0；在`docs/evidence/2026-11-01-m2-validation.md`记录源码SHA、fixture通过项及未跑的下载/切源/目录/降级GUI项。公开metadata probe可执行，但不下载GB权重、不删除现有模型；GUI仅用CUA。
- [x] **Step 5: 提交并审查。** `git commit -m "feat: expose truthful model recovery and capture local leases"`；按选定执行技能做本计划fresh review，修复Important/Critical后再进入M2-B。V1–V5未跑项继续Pending。
