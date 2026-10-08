# Flowtype 本地优先产品化设计

日期：2026-10-08  
目标：把 Flowtype 发展成面向中文/中英混合 AI coding 开发者的可靠内测产品，并让 macOS 原生界面与 localhost 网页界面共享同一个本地后端。

## 产品基线

Flowtype 的核心承诺是“给 AI coding 用的 macOS 语音输入”：开发者口述包含技术术语、文件路径、命令和中英混合内容的想法，Flowtype 将其转成可直接交给 Codex、Claude Code、Cursor 等工具的文本。

本地 Qwen3-ASR 是默认路径。音频默认留在设备上，云端 ASR 只有在用户主动选择或主动打开 fallback 策略时才参与。原生 macOS 前端和 localhost 网页前端是等价入口，不能各自复制录音、识别、润色、历史和配置逻辑。网页端适合完整操作、查看统计和复制历史；原生端负责全局快捷键、系统麦克风、跨应用注入和菜单栏常驻。

成功标准是可观察的行为：首次配置能完成，常用短句停止后稳定出字，模型或网络失败时文本仍可恢复，原生与网页对同一配置产生一致结果。对外展示技术词命中率、停止到注入延迟、断网可用和跨应用注入，而不是宣称绝对最高识别率。

## 目标架构

新增 `FlowtypeCore` Swift target，作为领域层和共享后端。Core 不依赖 SwiftUI、AppKit 或具体窗口；平台能力通过协议注入。

核心模块：

- `DictationService` actor：会话状态机、Pipeline 编排、取消、重试、显式 provider fallback 和性能事件。
- `ModelCoordinator` actor：模型 manifest、HF 下载/导入、校验、加载、切换、卸载和推理串行化。
- `ASRProvider`、`PolishProvider`、`AudioCapture`、`TextInjector`、`HistoryStore`、`ConfigurationStore` 协议。
- `SessionCommand`、`SessionEvent`、`SessionSnapshot`、`ModelSpec`、`ProviderDescriptor` 等 Codable 数据合同。
- 纯逻辑的后处理、词典、风格包、统计计算、配置迁移和数据库记录。

macOS target 提供 `MacAudioCapture`、Apple Speech 实时预览、`MacTextInjector`、全局快捷键、权限、菜单栏和 SwiftUI 视图。网页 server target 提供 Hummingbird HTTP/SSE、静态资源、loopback token 和 DTO 映射。两个入口都调用 `DictationService`，而不是直接调用 Qwen、CloudASR 或数据库。

## 会话与 API 数据流

```text
Native SwiftUI / localhost Web SPA
        |
        | SessionCommand
        v
FlowtypeBackend facade
        |
        v
FlowtypeCore DictationService
  -> AudioCapture + Apple preview
  -> ASR provider chain
  -> ASR post-process
  -> optional LLM polish
  -> optional TextInjector
  -> History/Stats observer
        |
        | SessionEvent / metrics
        v
Native UI + Web SSE clients
```

主要 API：

- `GET /api/v1/bootstrap`：返回脱敏配置、能力、模型状态、引导状态。
- `POST /api/v1/sessions`、`/start`、`/stop`、`/cancel`：创建和控制会话。
- `GET /api/v1/events`：SSE 推送 `recording`、`processing`、`polishing`、`completed`、`failed` 和模型下载事件。
- `GET/PATCH /api/v1/settings`：读写非秘密配置；API Key 只接受写入和脱敏回显。
- `GET /api/v1/models`、`POST /models/import`、`/models/download`、`/models/activate`：模型目录和生命周期。
- `GET/POST /api/v1/providers`、`/providers/test`：云端 provider 配置和连接测试。
- `GET /api/v1/history`、`/api/v1/stats`、`/api/v1/onboarding`：历史、统计和引导数据。

服务只绑定 `127.0.0.1`，启动时随机选择端口并生成一次性 token。网页静态资源与 API 同源，API Key 不出现在 bootstrap、日志或 SSE；音频默认不落盘。事件带有递增 `eventID`，网页重连后可从游标继续，避免刷新页面丢失完成结果。

## 本地模型路线

第一优先级是 Qwen3-ASR 兼容模型：

| 模型 | 角色 | 规划 |
|---|---|---|
| Qwen3-ASR 0.6B 4-bit | 默认低内存模型 | 内测默认，约 0.4GB 级别；按 manifest/shard 校验 |
| Qwen3-ASR 1.7B 4-bit | 质量优先 | 内存充足设备的可选项 |
| Qwen3-ASR 0.6B/1.7B 8-bit | 实验质量档 | 高级设置，后续开启 |
| Parakeet TDT / Streaming | 英文/欧洲语言高速路径 | 独立 provider，不能冒充 Qwen |
| WhisperKit/CoreML、SenseVoice、Omnilingual | 后续扩展 | 先评估许可证、中文 coding 质量和内存，再接入 |

HF 换模型采用兼容性目录而不是任意权重猜测。`ModelSpec` 至少保存 `family`、`repoID`、`revision`、`localURL`、`quantization`、`license`、`languages`、`sizeBytes` 和 `estimatedMemory`。用户可粘贴 repo ID 或选择本地目录；导入时检查架构、tokenizer、config、权重 shard、许可证和磁盘空间，加载时使用 manifest 中的 repo ID。修复当前 0.6B 固定 600MB 下限误判完整模型的问题，不能用一个跨模型的硬编码大小阈值。

模型切换由 `ModelCoordinator` 串行执行：停止当前推理、等待队列清空、卸载旧模型、校验新模型、加载和 warm-up，最后发布 ready。切换失败保留旧模型可用，并向两个客户端给出可操作错误。

## 云端 ASR provider 路线

云端 provider 分为协议适配器和服务商目录。内测先覆盖 OpenAI `audio/transcriptions` 兼容协议：

1. SiliconFlow：保留 `FunAudioLLM/SenseVoiceSmall` 和 `TeleAI/TeleSpeechASR` 预设。
2. OpenAI、Groq：补充通用英文/多语言高速选项，具体模型通过连接测试确认可用性。
3. Custom：允许用户填写 Base URL、模型 ID、Key；公网强制 HTTPS，loopback 服务允许 `http://localhost`。

DashScope Paraformer、腾讯云、火山/豆包、Deepgram 等使用签名或 WebSocket 的服务，放入独立 adapter 阶段，不能把它们强行塞进 multipart OpenAI 逻辑。provider descriptor 需要声明协议、语言、是否支持 streaming、最大音频长度、价格提示和隐私说明。

默认 fallback policy 是 `localOnly`。用户可显式选择 `localThenCloud`，并能看到“本轮音频将上传到 X”。云端错误分为 Key、模型、HTTP、限流、网络、超时和响应格式，错误信息要能指导修复。provider chain 不允许无提示地改变隐私边界。

## 流程与性能

录音中继续使用 Apple Speech 做低延迟预览；最终文本只由选定的 batch/streaming provider 负责。Qwen3-ASR 当前是 batch-only，长音频采用本地 VAD 静音边界切片，默认 20–30 秒、0.5–1 秒重叠、按序合并并做边界去重；短口述仍走单片路径。后续 Parakeet Streaming 才承担真正的实时提交。

每轮记录不含内容的指标：模型冷/热加载耗时、录音时长、ASR 耗时、LLM 耗时、停止到注入耗时、provider/model、fallback 次数、错误分类和注入结果。内测评测集加入真实录音、中文口音、中英技术词、数字、路径、命令、静音和长句，同时计算 CER、技术词命中率、填充词残留率、重复率和 P50/P95 延迟。

润色失败必须注入已经处理的原文并给非阻塞提示；当前“存历史但不注入”的行为会让用户认为文本丢失。注入失败继续使用剪贴板兜底。录音、模型切换、云端请求和网页连接都必须响应取消；任何阶段失败都要回到可重试或可复制的状态。

## 网页产品结构

网页 SPA 与原生前端共享同一份 API 合同，页面分为：录音工作区、模型、云端 ASR、LLM/风格、词典、历史、统计、隐私和引导。录音工作区显示当前 provider、模型加载状态、实时预览、最终文本、复制和重试；历史/统计沿用 SQLite 的分页和聚合结果。网页端不直接获取麦克风，录音由本地后端统一完成，保证两个入口共享同一会话和设备权限。

Web server 先采用 facade 接入现有实现，随后把纯逻辑和服务迁入 Core；不要复制 SwiftUI 页面中的业务判断。网页 API 的契约测试和原生 UI 的手动矩阵必须同时覆盖：模型未加载、云端未配置、断网、LLM 超时、注入焦点丢失、两个客户端同时控制和 SSE 重连。

## 分阶段实施

### 阶段 A：Core 与合同

建立 `FlowtypeCore` target，迁移纯数据模型、后处理、统计、provider 协议、会话事件和模型 manifest；加入 actor 隔离、取消语义和 Core 单元测试。macOS 适配层通过协议接回现有录音、Apple Speech、键盘注入和数据库。

### 阶段 B：模型与云端

实现 `ModelCoordinator`、Qwen manifest 校验、HF repo/目录引导、模型切换和 warm-up；修复 0.6B 校验阈值、保留旧模型回滚、显式 fallback policy。扩充 OpenAI-compatible provider 目录并完成连接测试、Key 脱敏和错误分类。

### 阶段 C：本地 Web backend

加入 Hummingbird server、loopback token、REST/SSE、静态资源和 API contract tests。原生 SwiftUI 改为调用 Core service，网页调用同一 server；完成录音、转写、润色、模型/provider 配置和历史统计主路径。

### 阶段 D：验证与推广

在 Terminal、iTerm2、Ghostty、Cursor、VS Code、浏览器输入框、原生文本框和密码框上做注入矩阵；用真实中文/中英 coding 语音跑质量与延迟报告。内测先邀请 5–10 位目标开发者，以技术词命中率、P95 延迟、注入成功率和失败后可恢复率迭代。

## 验收门槛

- `swift build` 和 `swift run FlowType --self-test` 全部通过。
- 新安装用户能完成权限、模型、触发键和首次录音引导。
- 本地模型已缓存时，断网仍可录音、识别和注入。
- 原生和网页对同一配置、历史和模型状态一致。
- LLM、ASR、注入任一环节失败时，用户能复制或得到处理后的原文。
- API Key 不出现在 bootstrap、日志、SSE 或网页明文状态中。
- 公开文案聚焦“本地优先的 AI coding 语音输入”，以可复现 demo 和指标证明差异度。

## 参考

- [speech-swift](https://github.com/soniqo/speech-swift)：Qwen3-ASR、Parakeet、VAD 和 Apple Silicon 推理实现。
- [Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-0.6B)：官方模型与许可证信息。
- [WhisperKit](https://github.com/argmaxinc/WhisperKit)：CoreML/Apple Silicon Whisper 备选路线。
- [SenseVoice](https://github.com/FunAudioLLM/SenseVoice)：中文、多语言和低延迟 ASR 参考。
