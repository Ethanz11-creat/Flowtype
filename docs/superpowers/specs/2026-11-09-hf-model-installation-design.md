# B：Hugging Face 模型安装与原生激活设计

父设计及全局约束：[ASR 模型中心](2026-11-09-asr-model-center-design.md)。状态：待评审。目标是用户输入 HF 链接/ID 或选择推荐项，即可取得完整、固定版本、可验证的原生模型目录。

## 1. 输入、格式与推荐配方

支持 `org/repo`、`https://huggingface.co/org/repo`、tree/blob 链接。链接中的 revision 与 subdirectory 可能有歧义，不按第一个 slash 猜测：解析出仓库与待确认 suffix，通过元数据解析后在预览中显示，用户确认版本/变体才下载。revision 可另填 branch/tag/完整 commit，默认 main，解析后冻结 40 位 commit。只接受 HF model repo，拒绝 dataset/space、带凭据/查询/片段的链接、路径越界和 NUL。`hf://` 语法本版不支持，给明确输入提示。

首批配方候选：现有 Qwen 0.6B/1.7B 4-bit；WhisperKit `openai_whisper-tiny` / `openai_whisper-base` 多语言，配对应 OpenAI tokenizer repo。推荐配方由应用随版本携带，固定每一来源 commit、variant、必要文件集合、许可证链接与验证状态。动态 HF 搜索不是依赖，首版通过推荐列表与链接输入覆盖获取。

自定义 Qwen 仅识别现有加载器兼容的两规模、4/8-bit group64；自定义 Whisper Core ML 可选择具体子目录。原始 transformers、其他 MLX 布局、GGUF 或其他架构解释为需要其他引擎/本地服务，不下载后假装可用。小元数据预检只表示候选兼容；完整 tensor / graph 检查及真实加载在下载后完成。

## 2. 跨计划类型与文件布局

新目录 `Services/Speech/ModelInstallation/`；复用 A 的 ASRCredentialStore。

```swift
struct HFRepositorySelection: Codable, Equatable, Sendable {
    let repoID: String
    let requestedRevision: String
    let subdirectory: String?
}
enum HFFileDigest: Codable, Equatable, Sendable {
    case sha256(String)
    case gitBlobSHA1(String) // SHA1("blob <size>\0" + payload)，不是裸文件 SHA1
}
struct HFPlannedFile: Codable, Equatable, Sendable {
    let source: HFRepositorySelection
    let downloadEndpoint: URL
    let resolvedCommit: String
    let remotePath: String
    let relativeDestination: String
    let sizeBytes: Int64
    let digest: HFFileDigest
}
struct ASRInstallPlan: Codable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let engine: LocalASREngine
    let files: [HFPlannedFile]
    let totalBytes: Int64
    let recipeID: String?
    let recipeVersion: Int
    let credentialID: String?
}
enum ModelStorageOwnership: String, Codable, Sendable { case managed, external }
struct ASRInstalledModelRecord: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let importedModelID: UUID
    let ownership: ModelStorageOwnership
    let installPlan: ASRInstallPlan?
    let directory: URL
    var validation: ASRNativeValidationRecord?
}
struct ASRNativeValidationRecord: Codable, Equatable, Sendable {
    let fileFingerprint: String
    let engineVersion: String
    let sampleSHA256: String
    let validatedAt: Date
    let latencyMs: Int
}
```

记录写入 `Configuration.installedASRModels: [ASRInstalledModelRecord]`，缺省为空。现有 ImportedASRModel 保存兼容性与真实目录；新记录通过 importedModelID 引用它，不创建第二套 active 模型。安装记录 id 为安装 UUID，激活/删除/usage API 的 modelID 一律指 importedModelID；两者不能混用。导入旧目录视为 external，未知归属绝不据路径猜 managed。

托管目录在 `RuntimePaths.modelsDirectory/installed/<install UUID>/model`；journal/staging 在同一文件系统的 `.../installation-jobs/<job UUID>/`。下载中目录不进入可用库。来源文件可映射到 model 根或 `tokenizer/`，必须由 plan 精确列出且目标不可冲突；不展开 zip/tar、不修改用户 HF 全局缓存。旧 preset 路径继续可识别，升级不强制搬动/重下载权重。

## 3. Resolver

`HFRepositoryClient.resolve(_ selection: HFRepositorySelection, credentialID: String?) async throws -> HFResolvedRepository` 返回 repo/commit/license 与完整文件元数据；`HFResolvedRepository` 字段为 selection、commit、downloadEndpoint、files（remotePath/sizeBytes/digest）、licenseURL。客户端初始化时注入下载 endpoint，plan 将其按文件捕获，恢复时不能重读设置换源。tree 分页跟随同 origin Link，cursor 循环拒绝；路径逐段编码，不把 revision 中的 slash 当文件路径。

`ASRInstallPlanner.plan(repository: HFResolvedRepository, variant: String?, tokenizer: HFResolvedRepository?) async throws -> ASRInstallPlan` 使用小元数据识别器与当前 ASRModelInspector 的相同兼容常数，禁止维护第二份宽松“支持列表”。检查 config、权重索引、必需 tokenizer/merges 和选中 Core ML 的全部组件文件。Whisper 已内含 tokenizer 时使用它；缺失时选择明确配方或用户指定的 tokenizer repo/commit，全部写入 plan。多个变体必须选，缺分词器不能自动选 tiny 或借本机其他缓存。

资源上限：单次 JSON/索引/小配置 16MiB、预检累计 32MiB、文件数 10,000、单页最多 1,000、所有 size 求和检查 Int64 溢出。超过上限在预览前失败，不能静默截断列表。不把无 pipeline_tag 或模型文件夹改名判为不兼容。元数据无明确大小/可解释摘要时本版不启动托管下载，提示可用离线导入。

## 4. 下载与恢复

`ModelInstallationCoordinator` 为 actor，拥有所有 job/journal 与一个活动网络任务；可排队多个安装，逐文件下载。API：

```swift
func enqueue(_ plan: ASRInstallPlan) async throws -> UUID
func pause(jobID: UUID) async
func resume(jobID: UUID) async throws
func cancel(jobID: UUID) async
func recover() async throws -> [ModelInstallSnapshot]
func snapshots() async -> [ModelInstallSnapshot]
```

`ModelInstallSnapshot` 为 Codable/Equatable/Sendable，字段 jobID:UUID、plan:ASRInstallPlan、state:ModelInstallState、receivedBytes:Int64、errorCode:String?；`ModelInstallState: String, Codable, Equatable, Sendable` 为 queued/downloading/paused/verifying/installed/failed/cancelled。用户取消保留部分文件，可显式继续或“清除未完成文件”；清除只处理该 job 归属目录。重启将活动任务恢复为 paused，不自动联网。进度按完成字节累计，不按文件数量平均。

`HFDownloadTransport.transfer(file:partialURL:credentialID:progress:) async throws` 用 URLSession delegate 流式写盘，不把 GB 权重装入 Data。默认每文件最多 3 次尝试，重试等待 1s/2s；只重试断网/timeout/429/5xx。Retry-After 不超过 30s 时遵从，否则暂停并提示稍后继续。请求 idle 超时 60s；下载预算独立于 ASR 的 20s。暂停/取消后排空任务才释放槽，generation 防止旧回调更新新 job。

续传 journal 只存 repo/commit/path、捕获的无敏感下载源、已写长度、digest、非敏感 validator 与 credential ID 引用；不存临时签名 URL、token 正文、响应正文。每次恢复重新取得 URL，固定 commit、下载源和 manifest 不变。token 按捕获的 ID 在请求前读取，用户更新 token 可用于恢复，但不改变模型版本。

- 206：必须验证 Content-Range 起点等于 partial 长度、总长匹配；不匹配废弃该 partial 并从零重试一次。
- 200 忽略 Range：截断 partial 后写完整响应，不能 append。
- 416：仅在 partial 长度等于目标且摘要正确时视为文件完成，否则从零重试一次。
- validator 改变、摘要不符或截断：不安装，移除该文件的坏 partial 后显式重试；不在新旧 revision 间拼接。
- HEAD 不支持时按受控 GET/Range 获取必要元数据；不能把 HTML 错误页、LFS pointer 或 JSON 错误当权重。

开始/恢复检查剩余磁盘至少 `remainingBytes + max(256MiB, plan.totalBytes / 10)`；运行中磁盘满准确失败。校验逐文件大小+摘要；LFS SHA256 只与对应 metadata 比较，普通 Git blob 按 Git 头格式计算 SHA1，不能将任意 ETag 当 SHA256。

## 5. 凭据、源与安装提交

HF token 显式输入，存 A 的 credential store。受限模型提示浏览器授权，已授权 token 才可读取；本版不自动提交许可同意。保留官方/镜像/自定义下载源设置，但选择源、repo commit 和 credential origin 都在 job 创建时捕获。

HF token 仅发送 `https://huggingface.co`；镜像/自定义源仅匿名下载，不继承 HF token。跨源 CDN redirect 移除 Authorization，HTTPS 且无 userinfo，最多 5 跳；过期签名 URL 从固定 resolve URL 重新获取。下载不是语音上传，单独实现这套 redirect 策略。日志不包含签名 query；官方源不可用也不悄悄带凭据换镜像。

全部校验通过后运行现有静态检查，写完整 installation manifest，原子 rename 到托管目录，再注册 imported/installed 记录。发布后崩溃重启以 manifest 和未完成publication journal幂等完成注册；manifest 前失败只留下可恢复 job。job journal持久化libraryDetached:Bool，用户“移除记录但保留文件”先写detached，再删库记录；recover不能把显式移除的模型重新加回。静态注册可为“已安装，未试用”，不修改 active selection。

## 6. 原生激活与删除

原生运行库同样使用编译期注册：`LocalASREngineAdapter: Sendable` 提供 engine:LocalASREngine、`assessMetadata(config: Data?, paths: [String]) throws -> Bool`、`inspect(directory: URL) throws -> ImportedASRModel`、`load(model: ImportedASRModel) async throws -> LocalASRLease`。QwenMLXEngineAdapter / WhisperCoreMLEngineAdapter 复用现有检查器和运行库；`LocalASRRuntimeRegistry.init(adapters:) throws` 拒绝重复engine，metadata零匹配报告不支持，多匹配要求明确选择，不按注册顺序猜。`LocalASRRuntimeFactory.load` 统一重检后委托registry，不再硬编码两分支。新增family仍需App集成引擎和枚举schema，但不改ASRStage、模型中心动作或历史。

新增 `NativeASRActivationCoordinator`，复用/组合 QwenModelState 的单操作 gate 与 lease 提交，提供 `activate(modelID: UUID, sample: ASRValidationSample) async throws -> LocalASRLease`。加载前重检指纹、资源准入，加载后用固定离线语音样本试识别；20 秒验证 deadline，非空终稿且无运行错误才记本次验证通过，不能声称准确率达标。engineVersion 包含依赖版本和 FlowType adapter 兼容版本；任一改变使旧验证失效。取消抵抗底层仍需排空，不并发启第二个候选。

若旧+新内存准入不通过，给出“结束当前会话并卸载旧模型后再试”显式动作；不自动卸载或冒险分配。用户选择该动作后当前无录音/资源排空才卸载；新加载失败会明确处于未就绪并提供重载旧模型，不能宣称旧 lease 仍在。

移除 external 只删记录；managed 的“移除记录”和“删除下载文件”分开，后者需核对 ownership/manifest/目录归属，并等待 active lease 与所有捕获 session 释放。`NativeModelUsageRegistry.acquire(modelID:)` 与 `reserveDeletion(modelID:)` 原子互斥；lease 持有引用 token，不能只在异步删除前检查一次计数。尚在用时显示占用并禁止文件删除。不为释放空间删除未选中的用户模型或 HF 缓存。旧 preset 的 native:preset backend ID 在未显式换选前保留；新托管安装使用 native:import:<importedModelID>，不在后台改写当前选项。

验收与任务见 [B 实施计划](../plans/2026-11-09-asr-model-center-b-hf-installation.md)。
