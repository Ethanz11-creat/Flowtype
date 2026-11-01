# M2-C Hugging Face Local Import Implementation Plan

**执行状态（2026-11-02）：** 已批准并按 A → B → C 执行。C1 a36df21（2113/0）、C2 9f0c92e（2179/0）、C3 63db2e9（2263/0）已完成源码、回归和对应审查/交接。C4 模型库 UI 与文档源码完成；最终顺序 build 23.57s / self-test 2306 passed、0 failed，见 M2 证据。C4 Step 5 的最终全 M2 源码审查及修复复审已通过（3a34a51，顺序 build 30.35s / self-test 2430/0）。Step 4 的 GUI/真实推理部分仍 Pending，不能视为整套真机验收通过。

证据：[M2 checkpoints](../../evidence/2026-11-01-m2-validation.md)、[V1–V5](../../evidence/2026-11-01-live-validation.md)、[A/B/C rulings](../../evidence/2026-11-01-m2-rulings.md)。空框若包含真实验收/最终审查，表示该部分待完成；历史计划正文保留，不把先前基线当作当前状态。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用户将自行从HF下载的兼容ASR模型导入模型库，按本机配置选择并实际离线听写；首批支持Qwen3-ASR MLX和Whisper Core ML。

**Architecture:** 导入检测器按family/格式产出描述，模型库只保存路径/元数据，运行库工厂创建独立候选provider，再交M2-A协调器提交。WhisperKit显式加载本地模型和分词器，禁止其隐式Hub回退；每次录音使用捕获的本地lease。

**Tech Stack:** macOS15+、Swift6.2、Core ML、speech-swift、WhisperKit **exact 0.18.0**（tag v0.18.0 / e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef）、SPM、SwiftUI、self-test。

**Spec:** [本地导入设计](../specs/2026-11-01-m2-local-import-design.md)、[总设计](../specs/2026-11-01-m2-model-recovery-design.md)。依赖M2-A共享lease/生命周期、M2-B完成。

## Global Constraints

- 首批为Qwen3-ASR 0.6B/1.7B MLX 4/8-bit group64，以及WhisperKit兼容Core ML目录；不是任意HF仓库或原始PyTorch权重。
- 模型导入是本机读取，不上传、不复制GB权重；移除库记录不删除用户模型。
- 不安装Python、执行repo脚本、trust_remote_code或做自动格式转换；不接入额外候选family。
- 严格离线，模型和分词器缺失直接失败；零自动网络补齐，不借用户其他缓存冒充目录完整。
- 新模型成功/所有权检查通过后才改变active配置，失败/取消保留旧模型和选择；录音快照不变。
- 不删除现有模型、缓存、Key；只在既有工作树开发，不push/merge；GUI仅CUA。
- 顺序`swift build`、`swift run FlowType --self-test`，不运行`swift test`；fixtures只用临时目录/小型合成文件。

## Review Focus

1. Whisper模型下载关闭后tokenizer损坏仍可能走Hub；必须证明缺失/损坏都零联网（Task2）。
2. 改名目录、错误量化、缺分片、LFS指针和合法HF链接不能被文件体积规则误判（Task1）。
3. Core ML短窗口不能截断长录音首尾，Whisper结果必须完整且按顺序合并（Task2/3）。
4. 切模型/删除库记录与录音并发时旧lease有效，取消晚回调不能改新会话（Task3/4）。
5. 旧路径迁移、失败导入和模型移动后不能覆盖可用配置或虚报ready（Task1/4）。

## File Structure

- New `Services/Speech/LocalModelManager/{ImportedASRModel,LocalModelLibrary,ASRModelInspector,SafetensorsManifest,WhisperModelInspector}.swift`：持久化描述/库、架构分派、分片/布局验证。
- New `Services/Speech/WhisperASRProvider.swift`、`LocalModelManager/LocalASRRuntimeFactory.swift`：严格离线Whisper与统一运行库选择。
- Modify Configuration、CustomModelScanner、ModelLocator、QwenModelState、Registry、Router/Stage、Readiness与本地模型设置。
- Modify Package.swift / Package.resolved仅为精确WhisperKit依赖及其所需产品，不顺手升级既有依赖。
- New `Testing/{LocalModelImportSelfTests,WhisperRuntimeSelfTests}.swift`与runner注册。

## Task 1: 多格式检测与模型库配置

**Files:** Create descriptor/library/inspector/manifest/WhisperInspector；Modify `Core/Configuration.swift`、现有CustomModelScanner/ModelLocator；Create LocalModelImportSelfTests并注册。

**Interfaces:**
- Produce `LocalASREngine: String, Codable, Sendable`（qwenMLX、whisperCoreML）；`ImportedASRModel: Codable, Sendable, Equatable, Identifiable`（id:UUID、name、directory:URL、engine、variant:String、bits:Int?、sizeBytes:Int64、tokenizerDirectory:URL?、fileFingerprint:String）。
- Extend Configuration：`importedASRModels: [ImportedASRModel] = []`、`activeImportedASRModelID: UUID? = nil`，旧配置decodeIfPresent兼容。
- Produce `ASRModelInspector.inspect(directory: URL) throws -> ImportedASRModel`，不写用户配置；`LocalModelLibrary.upserting(_:in:) -> Configuration`、`removing(id:from:) -> Configuration`是纯配置变换。
- Produce `SafetensorsManifest.read(directory: URL) throws -> SafetensorsManifest`，限制config/每个header最大16MiB、index最大16MiB，检查整数溢出/offset/文件大小，不读取权重payload。

- [x] **Step 1: 写失败回归。** `LocalModelImportSelfTests.runInspection(_:)`用合成header/JSON/符号链接检查Qwen的2规模×2量化；文件夹改名不改识别结果；未知family、config与张量冲突、错误group、缺special token、缺分片/索引越界/重复tensor、LFS指针/截断header、合法HF blob链接和断链均有准确结果。Whisper只按专属模型图布局检查，不强制safetensors。

```swift
r.eq(renamedModel.engine, .qwenMLX, "identity from metadata")
r.eq(coreMLModel.engine, .whisperCoreML, "format-specific inspection")
r.eq(networkCalls, 0, "inspection is local")
r.eq(try decodeLegacy().importedASRModels, [], "legacy decode")
r.check(originalDirectoryStillExists, "library removal never deletes weights")
```

Whisper必需MelSpectrogram、AudioEncoder、TextDecoder（mlmodelc或受支持mlpackage），可选TextDecoderContextPrefill；tokenizer.json + tokenizer_config.json必须在所选包/明确子目录可读，不能依赖全局HF缓存。HF仓库根有多个变体时返回明确“选择具体模型子目录”，不能偷偷选最大的。
- [x] **Step 2: 验证RED。** build/self-test预期缺少类型或旧scanner误接受输入。
- [x] **Step 3: 实现检测/库/迁移。** Qwen按当前加载器实际张量key/形状/完整集合和config确认支持布局；不能只检查少量哨兵tensor。Whisper静态包完整性与Core ML图形状兼容性分层，只有运行库加载成功才ready。legacy路径延迟校验后纳入库，不联网、不持久化未通过项。Qwen preset定位继续保持A计划的显式身份规则。
- [x] **Step 4: 验证GREEN。** 顺序build/self-test exit0；检查临时目录均清理且没有真实配置/模型改动。
- [x] **Step 5: 提交。** `git commit -m "feat: inspect local ASR formats and persist imported model library"`。

## Task 2: Whisper Core ML 严格离线运行库

**Files:** Modify Package.swift/Package.resolved；Create WhisperASRProvider、LocalASRRuntimeFactory、WhisperRuntimeSelfTests、`Services/Speech/OfflineWhisperKit.swift`、`Services/Speech/LocalWhisperTokenizer.swift`。

**Interfaces:**
- Consume Task1描述、A计划LocalASRLease。
- Produce `WhisperASRProvider: ASRProvider, @unchecked Sendable`，`static func load(model: ImportedASRModel) async throws -> WhisperASRProvider`；id使用A计划的`ASRProviderID.local`路由slot，displayName/lease身份明确Whisper；capabilities为onDevice/requiresNetwork=false，提供准确的语言/prompt能力。
- Produce `LocalASRRuntimeFactory.load(_ model: ImportedASRModel) async throws -> LocalASRLease`；Qwen构造兼容modelId但展示真实来源；Whisper只使用所选目录。
- Produce `OfflineWhisperBackend: Sendable`协议：`transcribe(samples: [Float], language: String?, prompt: String?) async throws -> [String]`；`WhisperASRProvider.init(identity: LocalModelIdentity, backend: any OfflineWhisperBackend)`供stub测试。
- Produce `WhisperOfflineLoadOptions: Sendable, Equatable`（modelDirectory:URL、tokenizerDirectory:URL、download:Bool=false、load:Bool=false）；backend工厂注入`@Sendable (WhisperOfflineLoadOptions) async throws -> any OfflineWhisperBackend`，测试不加载真实Core ML模型。adapter内部MLX/Core ML对象由串行executor隔离，不能仅靠unchecked Sendable宣称线程安全。
- Produce `OfflineWhisperKit: WhisperKit`，override `loadTokenizerIfNeeded() async throws`只解析本地；`LocalWhisperTokenizer: WhisperTokenizer`的`init(tokenizer: any Tokenizer) throws`检查必要special token并适配公开协议，不依赖上游internal wrapper初始化器。

- [x] **Step 1: 写失败回归。** `WhisperRuntimeSelfTests.run(_:) async`用stub backend/分词器：

```swift
r.eq(downloadFlag, false, "no model downloads")
r.eq(tokenizerSource, selectedTokenizerDirectory, "no global-cache substitution")
r.eq(networkRequestsWhenTokenizerCorrupt, 0, "no tokenizer fallback")
r.eq(output.text, "首段 中段 尾段", "all segments retained in order")
r.eq(concurrentInferenceCount.max(), 1, "serialized runtime access")
```

覆盖tokenizer缺失/解析失败、model形状/词表不匹配、语言非英语、取消在排队中/推理中、旧推理晚到、新会话排队、多个segment、超过30秒输入和空结果；真实音频不进fixture。
- [x] **Step 2: 验证RED。** build/self-test缺少runtime或离线保护断言失败。
- [x] **Step 3: 添加依赖并实现运行库。** exact0.18.0，仅WhisperKit及所需Tokenizers/Hub产品；固定锁文件，先检查与现有swift-transformers1.1.x兼容。初始化传modelFolder、tokenizerFolder、download=false、load=false、verbose=false，再显式loadModels。override从实际logitsSize/embedSize识别variant，设置textDecoder.isModelMultilingual，只调用AutoTokenizer.from(modelFolder:)并创建LocalWhisperTokenizer，绝不调用会联网兜底的super.loadTokenizerIfNeeded/ModelUtilities.loadTokenizer。自定义tokenizer需保留encode/decode、special/language token及Unicode安全的splitToWordTokens行为。上游modelVariant属性private(set)，其0.18.0使用处仅是默认tokenizer选择/日志；本适配器绕过默认tokenizer路径，保存自己的detectedVariant供真实身份与测试使用，不读取该属性作推理配置。非tiny/英语版的词表与模型维度不匹配必须报错。保持依赖原码不改，所有底层日志关闭。
- [x] **Step 4: 验证GREEN。** `swift build`后`swift run FlowType --self-test` exit0；read dependency diff确认未无关升级；fixture证明错误路径零网络。完整模型实际离线推理仍单独Pending，不能从stub推导成功。
- [x] **Step 5: 提交。** `git commit -m "feat: run imported Whisper Core ML models strictly offline"`。

## Task 3: 多引擎生命周期、录音快照和真实身份

**Files:** Modify QwenModelState、ModelProvisionRequest、LocalASRLease、ASRProviderRegistry、ASRRouter、ASRContract、ASRStage、ReadinessMonitor、PipelineOrchestrator、App/FlowTypeApp；Extend import/runtime self-tests。

**Interfaces:**
- Extend `ModelProvisionTarget`：`.imported(ImportedASRModel)`；复用A计划perform/cancel和activeLease。
- Consume runtime factory，按engine创建候选；`ASRRouteSnapshot.localLease`继续为每次录音锁定provider；无配置重读。
- Produce `LocalModelHardwareAssessment.assess(model: ImportedASRModel, physicalMemory: UInt64, availableMemory: UInt64?, activeModelBytes: UInt64?) -> LocalModelHardwareAssessment`（新增同名文件；支持compatible/warning/incompatible和解释），不承诺文件体积等于峰值。

- [x] **Step 1: 写失败回归。** 注入Qwen/Whisper两种stub lease；断言Qwen→Whisper切换失败/取消仍使用旧lease和旧配置，成功才持久化activeID；进行中录音用旧lease，新会话用新lease；库记录删除不杀死已有lease；可用旧+候选失败readiness ready；custom失败不触发preset降级；重启只按active导入项离线恢复。硬件测试覆盖Apple Silicon/其他架构、4/8GiB旧建议、未知峰值、旧新并存内存不足。
- [x] **Step 2: 验证RED。** self-test旧Qwen单引擎假设/提交时机断言失败。
- [x] **Step 3: 接入多引擎。** 失败/取消不更改库/active字段；成功一次性提交描述/路径/activeID。模型加载前确认文件fingerprint仍一致，变化则重检；明确不可行硬件或资源不足不盲加载。路由slot兼容旧值，但所有用户文案/历史引擎标签读取lease.identity.engine，Whisper不得显示Qwen。不在切换过程中修改全局上下文/路由配置。
- [x] **Step 4: 验证GREEN。** 顺序build/self-test exit0；A/B计划回归与原有路由、M1readiness、会话取消回归保持通过。
- [x] **Step 5: 提交。** `git commit -m "feat: route sessions through selected imported local engine"`。

## Task 4: 模型库UI与真实验收收口

**Files:** Create `Settings/ImportedASRModelList.swift`；Modify LocalModelPicker、ASRModelStatusCard、QwenModelStatusCard、OnboardingView、SettingsPage+ASR；Extend import tests；update M2 evidence、live-validation、remaining-work-audit。

**Interfaces:**
- Consume inspect/library/perform/assessment；不新增第二套加载任务。
- Produce `ImportedASRModelPresentation.make(model: ImportedASRModel, assessment: LocalModelHardwareAssessment, isActive: Bool) -> ImportedASRModelPresentation`（新增同名文件）集中模型名、family/格式/体积、硬件建议和动作。

- [x] **Step 1: 写失败回归。** 纯presentation/action tests断言内置两preset仍可下载、多个导入项显示真实来源/active状态、unsupported包给具体原因、硬件估算未知不显示保证可运行、移除仅移除记录、加载失败不自动选中、缺路径可重新定位、引导稍后配置仍诚实显示不可用。UI事件以UUID引用模型，不因列表排序/删除误操作另一项。
- [x] **Step 2: 验证RED。** self-test看到旧Qwen卡片/单路径行为不满足；不为纯样式改动写镜像测试。
- [x] **Step 3: 实现UI。** 独立“导入本地ASR模型”→选目录→检测结果/硬件提示→“加载并使用”；列表支持切换、重新定位、移除记录。帮助说明HF来源与支持的QwenMLX/WhisperCoreML格式，给相应来源链接，原始PyTorch目录显示需要兼容转换格式。保留两个preset的下载/恢复动作。
- [ ] **Step 4: 顺序验证与真实证据。** build/self-test exit0；CUA检查导入/多项管理/失败恢复/真实身份。可用完整模型时在不删除现有模型前提下执行断网导入→加载→合成短句实际落字、超过窗口首尾、切回preset、取消恢复；每个family/量化/硬件单独记录。缺少Whisper完整模型时将该真实推理项标Pending，不能宣称M2真机验收全部完成。V1–V5继续作为主线并列环境前提、Owner物理动作和状态，不把无凭据/无设备变体写成Pass。
- [x] **Step 5: 提交和最终审查。** `git commit -m "feat: manage imported ASR models and document M2 validation"`。按选定执行技能fresh review整个M2范围（从878725c起至最终HEAD，连同A/B/C计划、spec和ledger），修复Important/Critical并跑顺序检查；保留明确的真实服务/模型/设备Pending。禁止push/merge，汇报最终源码与证据路径。
