# M2-B Cloud Providers Implementation Plan

**执行状态（2026-11-02）：** 已批准并按 A → B → C 执行。B1/B2/B3 源码、回归、提交及阶段修复审查完成；最终阶段检查点 6fc1973，2034 passed / 0 failed。B3 Step 4 的源码验证已完成，GUI/真实服务部分 Pending；最终全 M2 门禁仍 Pending。

证据：[M2 checkpoints](../../evidence/2026-11-01-m2-validation.md)、[V1–V5](../../evidence/2026-11-01-live-validation.md)、[A/B/C rulings](../../evidence/2026-11-01-m2-rulings.md)。空框若包含真实验收/最终审查，表示该部分待完成；历史计划正文保留，不把先前基线当作当前状态。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用户选择云端厂商后获得可用的URL/模型/协议默认值，填Key即可配置识别，并能准确验证和恢复。

**Architecture:** 厂商目录定义默认值和能力，endpoint解析及multipart构造独立于网络执行。复用现有batch HTTP和DashScope WSS管线，沿用capture-start配置快照、取消和完整音频回退。

**Tech Stack:** macOS15+、Swift6.2、SwiftUI、URLSession、既有HTTP/WSS适配器与self-test。

**Spec:** [云端设计](../specs/2026-11-01-m2-cloud-provider-design.md)、[总设计](../specs/2026-11-01-m2-model-recovery-design.md)。依赖M2-A完成。

## Global Constraints

- 不迁移或导出密钥；保留profile UUID、用户URL/模型及原Key关联。
- 不更改录音字节合同、交付策略、ASR路由与Apple授权策略，不扩展LLM。
- 编辑/保存不发网络；真实测试识别说明合成音频发送和可能计费。
- 模型/字段的在线支持不能由fixture通过推导；真实厂商验收在主线V1记录。
- 只在既有工作树开发；不push、不merge、不改历史；GUI仅CUA。
- 顺序`swift build`、`swift run FlowType --self-test`；不跑`swift test`，测试不读真实配置/Key。

## Review Focus

1. 编辑URL/模型/Key后旧测试返回，不得为新配置显示成功（Task3）。
2. 完整transcription URL、末尾斜杠及WSS地址不能重复拼接或混用（Task1/2）。
3. 同为兼容HTTP的厂商不一定支持prompt/language/temperature；仅发能力允许的字段（Task2）。
4. 跨源重定向不得带Key/音频，HTTP错误与HTML响应不得泄露或冒充转写（Task2）。
5. 升级及切厂商不得覆盖用户已有profile/密钥，进行中录音继续使用旧快照（Task1/3）。

## File Structure

- New `Services/Speech/CloudProviders/CloudASRVendor.swift`：稳定厂商ID、模型预设、字段能力。
- New `.../CloudASREndpoint.swift`：URL解析/验证；New `.../CloudTranscriptionRequestBuilder.swift`：纯请求构造。
- Existing Configuration、CloudASRProvider、CloudASRProviderList、ASRRouter/health identity：保存/消费厂商与能力快照。
- New `Settings/CloudASRConnectionCheck.swift`：纯校验和真实测试版本所有权。
- New `Testing/CloudProviderSelfTests.swift`、SelfTest注册。

## Task 1: 厂商默认值、迁移与端点合同

**Files:** Create vendor/endpoint；Modify `Core/Configuration.swift`；Create/注册CloudProviderSelfTests。

**Interfaces:**
- Produce `CloudASRVendorID: String, Codable, Sendable`（siliconFlow、openAI、dashScope、custom）。
- Produce `CloudASRFieldCapabilities: Codable, Sendable, Equatable`（sendLanguage、sendPrompt、sendTemperature、sendResponseFormat）。
- Produce `CloudASRVendor.makeProfile(_ vendor: CloudASRVendorID, isActive: Bool) -> CloudASRProviderConfig`、`capabilities(for: CloudASRProviderConfig) -> CloudASRFieldCapabilities`。
- Extend profile with`vendorID: CloudASRVendorID`、custom字段开关；decode旧配置按确切provider值迁移，未知保留原名并用custom，不靠域名contains。
- Produce `CloudASREndpoint.transcriptionURL(_ input: String) throws -> URL`、`validateRealtimeURL(_ input: String) throws -> URL`。

- [x] **Step 1: 写失败回归。** `CloudProviderSelfTests.runConfiguration(_:)`使用内存JSON与合成Key：

```swift
r.eq(sf.model, "FunAudioLLM/SenseVoiceSmall", "vendor has default ASR")
r.eq(openai.model, "whisper-1", "OpenAI default visible")
r.eq(try endpoint("https://example.test/v1/audio/transcriptions/"),
     try endpoint("https://example.test/v1/"), "endpoint normalized once")
r.eq(migrated.id, legacy.id, "profile identity retained")
r.eq(migrated.model, legacy.model, "existing model not overwritten")
```

覆盖空host、userinfo/query/fragment、HTTP、非法端口、WSS/HTTPS混用、custom默认无模型、所有旧Key关联不变。URL无效时报错，不截去敏感部分再发送。
- [x] **Step 2: 验证RED。** build失败于未定义接口或self-test默认模型/URL断言失败。
- [x] **Step 3: 实现目录/迁移/URL。** defaults按spec，未知服务需要模型ID。OpenAI先采用最小file/model/response_format=json合同，在线文档访问限制记录到证据，不新增未经核实的其他模型能力。SiliconFlow只发file/model；DashScope保持现有WSS默认值。
- [x] **Step 4: 验证GREEN。** 依次build/self-test，exit0且失败0；无真实配置读写。
- [x] **Step 5: 提交。** 精确git add；`git commit -m "feat: add cloud ASR vendor presets and endpoint contracts"`。

## Task 2: 厂商请求、返回、取消与脱敏

**Files:** Create request builder；Modify `Services/Speech/CloudASRProvider.swift`、`ASRContract.swift`、`ASRRouter.swift`；Extend CloudProviderSelfTests。

**Interfaces:**
- Consume Task1厂商能力/端点。
- Produce `CloudTranscriptionRequestBuilder.make(configuration: CloudASRRequestConfiguration, samples: [Float], language: String?, context: ASRContext?, timeout: TimeInterval) throws -> URLRequest`。
- Extend配置快照/health identity包含厂商及有效能力，避免改能力后沿用旧测试/健康结果；保持其Equatable/Sendable。
- Keep `CloudASRProvider.transcribe(_:)`、`testConnection(provider:apiKey:)`对调用方兼容；增加`validateConfiguration(provider:apiKey:) -> Result<String, CloudASRError>`纯本地检查。

- [x] **Step 1: 写失败回归。** `runTransport(_:) async`用URLProtocol核对WAV头/样本、Bearer、multipart boundary/file/model。断言SF不含prompt/language/temperature，OpenAI最小合同JSON与明确语言/prompt能力，自定义默认只发最小字段，global sendContext=false始终不发prompt。覆盖Base/完整URL同址、WSS从不走multipart、网络取消不标普通失败、capture后切配置仍发原URL/Key/模型。

```swift
r.eq(crossOriginFollowedRequests, 0, "no credential/audio redirect")
r.eq(htmlAcceptedAsTranscript, false, "HTML is not transcription")
r.check(!safeError.contains(testKey), "key redacted")
r.eq(requestModelAfterSettingsChanged, capturedModel, "snapshot is immutable")
```

覆盖400/401/403/404/429/5xx、非HTTP、text缺失/类型错误、异常JSON、超时、过期响应；错误正文/URL中的合成Key不进日志。响应支持JSON text；旧plain-text兼容仅在明确自定义适配策略允许时保留。
- [x] **Step 2: 验证RED。** self-test观察旧实现字段/redirect/响应断言失败。
- [x] **Step 3: 实现传输与错误。** 工厂能力控制字段，拒绝跨源跳转；统一鉴权/模型/限流/网络/响应原因的安全摘要，继续使用现有CompletionBudget和取消语义。真实连接测试复用同一builder，避免“测试能过、听写不同协议”。
- [x] **Step 4: 验证GREEN。** 顺序build/self-test exit0；既有实时、路由generation/半开恢复、取消与唯一交付回归保持通过。
- [x] **Step 5: 提交。** `git commit -m "feat: adapt ASR requests to vendor capabilities"`。

## Task 3: 即用配置UI与诚实测试状态

**Files:** Create CloudASRConnectionCheck；Modify `Settings/CloudASRProviderList.swift`、`SettingsPage+ASR.swift`、必要的readiness配置验证接入；Extend CloudProviderSelfTests；update M2 evidence。

**Interfaces:**
- Consume Task1/2纯校验、profile及真实测试。
- Produce `CloudASRCheckToken: Equatable, Sendable`（profileID、revision UUID）；`CloudASRConnectionCheck.begin(profileID: UUID) -> CloudASRCheckToken`、`invalidate(profileID:)`、`accepts(_:) -> Bool`。编辑任一配置字段/Key、删除profile都invalidate；不把Key写入token或诊断。

- [x] **Step 1: 写失败回归。** `runConnectionOwnership(_:) async`断言编辑URL/模型/Key或删除后旧token均拒绝、另一profile测试不串、纯校验零transport调用、没有模型的custom不可ready、重复点击不发并行测试；旧录音快照不受新UI值影响。
- [x] **Step 2: 验证RED。** self-test看到过期测试被接受或缺少token接口。
- [x] **Step 3: 实现UI。** 添加菜单按厂商显示；普通路径预选URL/模型，Key SecureField；高级入口更换模型/自定义字段；profile绑定按UUID而非容易失效的数组index。分别显示“检查配置”和说明发送合成音频/可能计费的“测试识别”，WSS显示原配置验证边界。旧测试不能显示新配置已连接；诊断不展示整段响应。
- [ ] **Step 4: 验证与证据。** 顺序build/self-test exit0；CUA检查厂商选择、默认值、URL输入和不联网配置校验。不读取/输出用户Key；真实SF/OpenAI正常/弱网/断网/取消验证仅在有已授权可用配置时执行，未跑项写入M2 evidence和V1 Pending，不伪造Pass。
- [x] **Step 5: 提交并审查。** `git commit -m "feat: simplify cloud ASR setup and reject stale checks"`；按选定执行技能做fresh review后进入M2-C。
