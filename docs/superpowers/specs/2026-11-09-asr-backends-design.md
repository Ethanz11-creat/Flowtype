# A：可替换 ASR 后端与服务协议设计

父设计及全局约束：[ASR 模型中心](2026-11-09-asr-model-center-design.md)。状态：待评审。目标是在公共听写链路中接入原生、云端与本机服务，移除两个固定 slot 对扩展能力的限制。

## 1. 身份与持久化

新增 `Services/Speech/Backends/`。以下类型的字段是跨计划契约，具体初始化器使用成员初始化或同语义显式初始化：

```swift
struct ASRBackendID: RawRepresentable, Codable, Hashable, Sendable { let rawValue: String }
enum ASRBackendLocation: String, Codable, Sendable { case native, loopbackService, cloud }
enum ASRServiceProtocol: String, Codable, Sendable { case openAICompatible, whisperCpp, dashScopeRealtime }
struct ASRBackendSelection: Codable, Equatable, Sendable {
    var primary: ASRBackendID?
    var fallback: ASRBackendID?
    var allowsCloudFallback: Bool
}
enum ASRServiceAuthentication: Codable, Equatable, Sendable {
    case none
    case bearer(credentialID: String)
}
struct LocalASRServiceProfile: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var revision: UUID
    var name: String
    var baseURL: String
    var protocolKind: ASRServiceProtocol
    var modelID: String?
    var authentication: ASRServiceAuthentication
    var fieldCapabilities: CloudASRFieldCapabilities
}
```

`Configuration` 增加 `asrBackendSelection: ASRBackendSelection?`（缺失表示未迁移）、`localASRServices: [LocalASRServiceProfile]`（默认空）。CloudASRProviderConfig 增加 revision:UUID，旧配置 decodeIfPresent 缺省生成并随迁移保存；影响调用的编辑保存时更换 revision。旧 asrRoutingPolicy 的 auto/localOnly/cloudOnly 值保留。

稳定 ID：`cloud:<profile UUID>`、`service:<profile UUID>`、`native:preset:<preset.id>`、`native:import:<model UUID>`。路由/健康键另包含配置 revision、model ID、credential generation；不得仅以厂商名、目录名或两个旧 slot 聚合健康。

迁移函数 `ASRBackendMigration.selection(from: Configuration) -> ASRBackendSelection` 是纯函数：localOnly 保留原 native 选择，cloudOnly 保留原 active cloud；auto 保留 cloud 主选 + native 备选及原回退语义。旧 auto 的 allowsCloudFallback=true，旧 localOnly=false；全新原生/本机服务主选默认 false，用户明确选择云端备选时才可打开。没有可用实例的 reference 保留并显示不可用，不擅自改选其他项。旧字段留作兼容读取，迁移后运行路由只读新 selection，UI 编辑同步必要旧字段以支持现有页面迁移期。

## 2. 能力、快照与公共调用

现有 ProviderLocation 增加 localService；本机服务的 ASRCapabilities.requiresNetwork=true（使用socket），descriptor.requiresInternet=false；原生为onDevice/false，云端为cloud/true。所有互联网过滤改用descriptor，不用旧requiresNetwork阻挡loopback。

```swift
struct ASRBackendDescriptor: Sendable, Equatable {
    let id: ASRBackendID
    let revision: UUID
    let displayName: String
    let modelID: String?
    let location: ASRBackendLocation
    let requiresInternet: Bool
    let capabilities: ASRCapabilities
    let maxUploadBytes: Int64?
}
struct ASRBackendBinding: Sendable, Equatable {
    let descriptor: ASRBackendDescriptor
    let provider: any ASRProvider
    let nativeLease: LocalASRLease?
    let credentialGeneration: UUID?
    // Equatable 比较 descriptor、lease.id 与 credentialGeneration，不比较 provider 对象。
}
protocol ASRServiceAdapter: Sendable {
    var protocolKind: ASRServiceProtocol { get }
    func makeProvider(profile: LocalASRServiceProfile, credential: String?) throws -> any ASRProvider
}
```

`ASRProviderRegistry` 增加 `init(adapters: [any ASRServiceAdapter]) throws` 和 `makeLocalServiceBinding(profile:credential:credentialGeneration:) throws -> ASRBackendBinding`，拒绝重复 protocol；生产静态装配 OpenAI-compatible 与 whisperCpp adapter。云端保留原 profile 与 DashScope 工厂，由 `CapturedCloudASRProvider` 包装不可变 `CloudASRRequestConfiguration`；native 包装捕获的 lease，其 descriptor.revision 使用 lease.id。服务适配器不负责 profile 持久化。

`ASRRouteSnapshot` 新增 `bindings: [ASRBackendBinding]`；此数组是候选顺序唯一事实来源。旧 selectedProviderID / cloudConfiguration / localLease 等用于兼容实时捕获和测试的字段从 binding 推导，生产不再用两个旧 ID switch 选择 batch provider。realtime 仅从捕获的 DashScope binding 创建；native/service 不误入 DashScope。

`ASRBackendRouting.order(selection:policy:descriptors:availableIDs:internetAvailable:degradedIDs:) -> [ASRBackendID]` 是纯函数：

- 仅考虑明确主选、明确备选，按策略/可用性/联网需求过滤、去重；无候选给现有 readiness 恢复。
- auto 可按健康将主选暂置后，但候选集合不扩大；localOnly 排除 cloud，cloudOnly 排除 native/service。
- requiresInternet=false 的 native/loopback 不受 NWPath.internet 状态阻挡；不能把“需要 socket”解释为“需要互联网”。
- 原生/本机服务主选到云端备选需要 allowsCloudFallback；用户显式 cloud 主选不受该开关阻挡。迁移 auto 的既有语义保留。
- 取消不重试、不降级；所有尝试复用现有剩余预算。auto 且有非云端备选时云端单次上限沿用现有 5 秒，整体停止后处理预算沿用 20 秒。

`ASRBackendHealthStore` 按 descriptor.id/revision 和 credential generation 隔离失败、延迟、探测；凭据值与完整 URL 不进入日志。`ASRResult.providerID` 与历史标签记录实际 binding 身份；保留读取旧 qwen-local/cloud-asr 历史。

## 3. HTTP 协议

| 预设 | 路径与必填字段 | 可选字段与结果 |
| --- | --- | --- |
| 自定义 OpenAI-compatible | base/v1 由用户填写；标准化追加 `/audio/transcriptions`，已是完整路径不重复；file/model | 未知模型仅最小字段；显式 opt-in language/prompt/temperature/response_format；结果 JSON text |
| MLX Audio 本机 | 同上；file/model，强制 response_format=json | language/prompt 支持；不解析默认 NDJSON；model list 仅提示候选 |
| WhisperKit 本机 | 同上；file/model，response_format=json | language/prompt 支持；`/models` 缺失允许手填 |
| whisper.cpp 本机 | base 追加 `/inference`，已完整不重复；file，response_format=json | language/prompt 支持；不发送 model，不调用 `/load`，显示“模型由服务端决定” |
| SiliconFlow 云端 | 复用现有 region/baseURL，file/model | 首版最小可证实字段，不按名称猜测能力 |
| OpenAI 云端 | 新建默认 gpt-transcribe；file/model | 新型号可发 prompt；不把旧单 language 字段直接映射成新 languages。旧 whisper-1 保留并提示弃用，按其已核对字段构建 |

复用 WAV 编码和 multipart 小组件；不让 local service 绕过原 cloud HTTPS 校验，也不把 cloud 校验放宽成任意 HTTP。`LocalASRServiceEndpoint.transcriptionURL(profile:) throws -> URL` 只接受 http/https + exact `localhost`、`127.0.0.1`、`[::1]`，规范端口 1...65535；拒绝 userinfo/query/fragment、混淆编码/其他 IP 表示法，localhost 实际连接必须是 loopback。loopback session 禁代理/缓存/cookie，拒绝所有 redirect；不能重定向上传到外网。cloud HTTP 上传同样禁自动重发 redirect。

传输统一将 timeout/cancel/auth/rateLimit/invalidModel/invalidResponse 归类；响应上限 2MiB，JSON text 须非空，错误正文不写日志。上传实际 body 超过已知 maxUploadBytes 时发送前失败；不截断音频。服务端内部取消能否停止计算不作保证，本进程必须取消等待并抑制迟到结果。

## 4. 发现与验证

`ASRModelDiscoveryClient.models(profile:credential:) async throws -> [String]`：OpenAI 风格 GET `/models`，10 秒、最多 1MiB/1000 项。超过上限给明确错误并允许手填，不静默截断。404/405 返回空列表支持手填；401/403 正确提示权限，不伪装已连接。发现不标记识别兼容；不自动发测试音频。

`ASRServiceValidationCoordinator.test(profile:credential:sample:) async` 使用配置 revision token、每 profile 单 in-flight 槽；编辑/删除/关闭只取消本次操作，旧回调不能覆盖新状态。调用现有或扩展的合成测试音频路径，用户点“试识别”才请求，显示可能产生厂商费用。对 DashScope 保留“配置检查”与真实识别不同结果。

## 5. 凭据与迁移

**A2 原子提交修订（评审 I1）**：`CloudASRProviderConfig` 新增可选 `credentialReferenceID: String?`，旧配置 decode 缺失时为 nil。nil 继续读取 `asr.cloud.<profile UUID>`；新凭据版本使用 `asr.cloud.<profile UUID>.<fresh UUID>`。计算属性 `credentialID: String` 给出引用；调用存储前必须以 `validatedCredentialID()` 校验显式引用的本 profile 命名空间与 UUID 后缀，不得跨 profile、service 或 HF 读取。显式引用缺失/不可读时禁止回退旧 JSON 密钥。

编辑保存先持久化旧配置作为恢复源，把变更密钥（删除用空字符串 tombstone）写入新的不可变引用并读回验证，最后通过**单个配置 blob**同时提交新 URL/model/protocol/revision 和新 credential reference。旧已提交 Keychain 项始终不覆盖/删除；崩溃、凭据失败、最终配置保存失败都保留旧调用配置与旧凭据配对，无需跨存储回滚。若写入已完成但保存确认失败，磁盘可能是旧或新完整 blob，二者均引用各自匹配的凭据。未提交的 staged Keychain 项可能成为孤立项，其清理延后处理，不把密钥正文或待提交事务密钥写入配置/journal。未修改密钥时保留最新已提交引用，旧编辑器不能回写过时引用。

显式引用的空字符串表示已提交删除，不能用遗留 key 复活；提交前失败的删除保留旧可用配对。迁移尊重显式引用：不得向丢失的不可变引用填入旧备份；冲突/丢失保留备份与 pending 状态。此修订替代早期仅固定 `asr.cloud.<profile UUID>` 允许原地覆盖的约束；稳定 profile UUID 与在途快照保持不变。

新增 `ASRCredentialStore: Sendable`，`read(id:) throws -> String?`、`generation(id:) -> UUID`、`write(_:id:) throws`、`remove(id:) throws`；生产使用传统 Keychain，测试只用注入内存 store。generation 在当前进程中按 ID 稳定，成功写入不同值/删除时更换，失败不变；它是不可逆推出密钥的随机身份，不是密钥摘要。捕获 read 与 generation 需同一 store 临界区提供一致视图，生产另实现 `snapshot(id:) throws -> ASRCredentialSnapshot`（value:String?、generation:UUID）供路由使用。写入采用 update-existing / add-if-missing，不复用先删后写造成失败丢值的路径。

新 service/HF 使用 credential ID；旧 `cloudASRConfig.providerAPIKeys` 按 profile ID 可重试迁移：写入并读回相同才从旧持久化字段移除该 key，失败保留旧值与原选择。当前 code 的 LLM provider key 存储不在本子项目迁移范围。Keychain 锁定/拒绝显示可恢复状态，不降级为空密钥或删除原记录。配置 revision 在凭据变更后失效；凭据移除需等待使用它的快照排空后清理，或已捕获值继续仅存会话内存。

验收与文件任务见 [A 实施计划](../plans/2026-11-09-asr-model-center-a-backends.md)。
