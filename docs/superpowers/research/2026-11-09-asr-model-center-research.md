# ASR 模型中心：实现与生态调研

日期：2026-11-09。源码基线：`288aa9a6d02ce966a05dbd3fe71a6e26f6a9ad21`。这是设计研究，不是功能或互操作验收报告。仅查询公开文档、仓库元数据与代码；没有下载模型权重、使用用户密钥、上传音频或操作真实权限。

## 结论

推荐在现有 macOS 原生应用内建立完整模型中心：内置兼容模型一键安装，HF 仓库可解析、选择变体、固定版本并下载；已有目录可直接导入；其他架构经用户自行启动的本地服务连接。FlowType 统一管理识别会话、选择、降级、验证结果与安全交付。模型来源、模型格式、运行引擎、API 协议分别建模。

不采用“把 HF 下载当成通用运行时”的方案，也不在首版捆绑 Python/PyTorch 环境安装器。用户已经选择外部服务由用户安装、启动；扩大首版完善安装和使用闭环，不改变这一选择。

## 当前实现：可复用部分与缺口

| 领域 | 已有实现 | 本次需要补齐 |
| --- | --- | --- |
| ASR 公共接口 | `ASRProvider`、16kHz mono Float32 请求、结果、独立 realtime 会话 | 配置/模型/后端实例身份分开，编译期注册的协议与引擎工厂 |
| 路由与会话 | `ASRRouter`、录音开始快照、不可变云端配置、本地 lease、20 秒处理预算 | 两个硬编码 slot 扩展成带真实身份的有序候选；本机服务不依赖互联网可达性 |
| 云端 | SiliconFlow/OpenAI/DashScope/custom；自定义 model ID；multipart 与 WSS 分离 | 模型能力与版本预设、可选模型发现、可验证的协议差异 |
| 导入 | Qwen MLX / Whisper Core ML 静态检测、分词器检查、库、重新定位 | 统一来源与验证记录；安装和选中分离；可执行的真实模型矩阵 |
| 生命周期 | `QwenModelState` 候选加载、取消排空、旧 lease 保留、成功后提交 | 提取与 Qwen 无关的原生激活入口；增加候选试识别，避免另一套 active 状态 |
| 下载 | 两个 Qwen preset，经 speech-swift/Hub 下载；存在 source/env gate | 任意 HF 仓库解析、固定 commit、多来源安装配方、持久任务、可信续传与事务发布 |
| 原生界面 | 识别设置、草稿、连接测试、离线导入、试用与恢复导航 | 集中模型列表、安装任务、来源详情、主选与备选、明确状态 |

重点源文件：`Sources/flowtype/Services/Speech/{ASRContract,ASRProviderRegistry,ASRRouter,QwenModelState}.swift`、`LocalModelManager/*`、`CloudProviders/*`、`Core/Configuration.swift`、`Settings/SettingsPage+ASR.swift`。

## 外部来源与可证实事实

公开来源抓取摘要与 SHA256 见 [sources.json](2026-11-09-asr-model-center-sources.json)。动态文档中的型号与日期只代表本次读取结果；上线前必须再次核对，不自动修改用户已有 model ID。

### R1. HF 是版本化文件仓库，不是统一模型安装包

- [Hub 下载指南](https://github.com/huggingface/huggingface_hub/blob/main/docs/source/en/guides/download.md)：支持 revision、snapshot、allow/ignore patterns、local directory；完整下载并不意味着运行格式兼容。
- [Hub OpenAPI](https://huggingface.co/.well-known/openapi.json)：tree API 带 recursive、expand、limit、cursor。实际查询 Whisper tiny 子目录 `limit=5` 返回分页 Link；实现必须处理分页，不能只取第一页。
- [受限模型指南](https://huggingface.co/docs/hub/models-gated)：访问申请在浏览器完成，下载需要已获授权的身份。401/403/404 不能一律解释成“模型不存在”。
- API 的 `pipeline_tag` / `library_name` 可缺失。Qwen 0.6B 的实际公开响应中 `pipeline_tag=null`，但有 `library_name=mlx`。标签只辅助展示，不能当兼容性的唯一判据。

### R2. 现有两个原生引擎覆盖的是明确格式

锁文件：speech-swift **0.0.15** / `10bcb4648932a8a8d8caa7ee6ef9d866abd95ff8`；WhisperKit **0.18.0** / `e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef`；swift-transformers **1.1.9** / `150169bfba0889c229a2ce7494cf8949f18e6906`。

- 当前 Qwen 检测器严格匹配 0.6B / 1.7B、MLX affine 4/8-bit、group64，以及实际加载器的张量布局。其他 MLX 导出不能靠文件后缀自动放行。
- [Qwen 0.6B 仓库](https://huggingface.co/aufklarer/Qwen3-ASR-0.6B-MLX-4bit) 本次 commit：`bc441bd1e4295c1f42d9879f056049a925b6e013`，8 个文件；权重 708,236,945 bytes。配置、merges、vocab、tokenizer config、索引需要随权重保留。
- [Qwen 1.7B 仓库](https://huggingface.co/aufklarer/Qwen3-ASR-1.7B-MLX-4bit) 本次 commit：`d4f9fa3bb45489219f0fcbec671c92d9c1a68fb6`。
- [WhisperKit 模型仓库](https://huggingface.co/argmaxinc/whisperkit-coreml) 本次 commit：`0f63a7800b00dd0226abd051b906c246e1907482`，550 个文件、多个模型子目录，**没有 tokenizer 文件**。直接下载整个仓库既浪费空间，也不满足现有严格离线加载契约。
- 因此推荐 Whisper tiny/base 多语言安装配方要固定 Core ML 子目录，并从对应 `openai/whisper-tiny` / `openai/whisper-base` 仓库取得配套分词器；两个来源分别固定 commit。自定义 Whisper 没有配套分词器时由用户明确补选来源，不猜测 tiny。
- [WhisperKit 0.18.0](https://github.com/argmaxinc/WhisperKit/tree/e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef) 提供本机 OpenAI 风格服务器；本地源码 `ServeCLI.swift` 与 OpenAPI 显示 `/v1/audio/transcriptions`、`/health`。这不等于 FlowType 已接入，也不代表服务器一定开放 `/v1/models`。

### R3. 首版外部服务以三个已研究的实现为参考

| 服务 | 来源版本 | 适配结论 |
| --- | --- | --- |
| MLX Audio | [5dbe43b](https://github.com/Blaizzy/mlx-audio/blob/5dbe43bdacccdf17a930a2787a39acae7a44d1a0/mlx_audio/server.py) | `/v1/models` + `/v1/audio/transcriptions`；multipart model/file；默认 `response_format=ndjson`，需明确请求 `json` 才匹配一次性 `{"text":...}` 契约 |
| WhisperKit CLI | 上述锁定 0.18.0 | OpenAI 风格 batch；支持手动 model ID，模型发现不可作为必需条件 |
| whisper.cpp server | [f92e1e4](https://github.com/ggml-org/whisper.cpp/blob/f92e1e4d1056700c39d4e86c1140f0a088fe1ab6/examples/server/server.cpp) | `/inference`，multipart file/response_format/language/prompt；模型由服务端加载，不能强塞必填 model，也不自动调用 `/load` |

各服务仅完成文档/源码协议核对，没有本次真机运行证据。外部服务自身可能下载模型或调用其他服务；FlowType 只能保证请求发往已验证的 loopback 地址，不能把这一连接标签解释成第三方进程绝不出网。

### R4. 云端能力必须以型号为单位

- [SiliconFlow 官方转写文档](https://docs.siliconflow.com/en/api-reference/audio/create-audio-transcriptions)：multipart file/model、Bearer、JSON text；示例 `FunAudioLLM/SenseVoiceSmall`。国际站示例不能用于覆写已存中国站地址。本次旧 `.cn/cn/...` 路径多次 404，使用可读国际站文档说明最小协议，地区实测分别记录。
- [OpenAI 转写指南](https://developers.openai.com/api/docs/guides/speech-to-text.md) 本次推荐 `gpt-transcribe`；[弃用页](https://developers.openai.com/api/docs/deprecations) 标记 whisper-1 等旧型号将于 **2027-02-26** 移除。首版新建预设跟随本次文档，旧配置保留并展示弃用提示，账户是否可调用仍需用户测试。
- OpenAI 当前文档上传限制为 25MB；16kHz mono PCM16 WAV 的 10 分钟约 19.2MB，仍须计算实际 multipart 大小，并按型号/服务限制判断，不能靠录音时长猜测。
- OpenAI 的新型号上下文字段与旧 whisper 不完全相同；最小 file/model 先可用，只有明确支持的字段才发送。`/models` 含其他任务模型，发现列表不等于已确认 ASR 兼容。
- 保留现有 DashScope 专属 realtime 状态机；不把兼容 HTTP 接口描述为任意厂商实时 WebSocket。

### R5. 现有 Hub 工具可参考，不能直接当完整安装事务

审阅本地锁定 `HubApi.swift`、`Downloader.swift`：snapshot 支持 revision 和 glob，但目标目录按 repo 组织；取消可能直接返回目录；下载器发 Range 后只检查通用 2xx，不能据此证明 200/206/416 恢复都正确。默认 token 查找还涉及环境与全局缓存。

决策：新安装器由 FlowType 维护固定版本 manifest、下载 journal、字节/摘要校验与发布事务；使用 Foundation URLSession + CryptoKit，不升级现有依赖、不执行 Python。现有引擎只加载安装完成目录，不能在推理时暗中补文件。旧下载源与 preset 路径保留识别/迁移能力；原有 process-wide `HF_ENDPOINT` gate 不能被并行下载绕过。

## 发布现状：不能被新计划覆盖的缺口

- 最新远端 [run 41672136709](https://github.com/Ethanz11-creat/Flowtype/actions/runs/41672136709)，对应上述 HEAD，结论 **failure**：25,919 passed / 1 failed，唯一报告 `M5 actual health timer advances once per interval`。原测试为等待 110ms 后断言 30ms timer 计数 2...4；没有打印实际计数，尚不足以定性为测试波动或产品故障。
- 历史本地全量 25,920/0、24 项技术阶段 Pass 是原候选证据，不替代该 CI 失败，也不转移给本次未来产品。
- [原主线 41 项真机验收](../validation/2026-11-03-native-client-acceptance.md) 仍需对新候选执行；尤其弱网、跨应用落字、剪贴板、阶段取消、拔麦与蓝牙恢复。
- 当前 ad-hoc 签名只证明本地完整性。Developer ID、公证、Gatekeeper、DMG 安装/升级需独立发行验收。
- 本次继续审阅 `VerificationReport.swift` 证实 artifact/release lane 都调用build-app；完成manual后再次调用会重建候选。计划加入显式candidate-manifest模式验证已有候选，不能在签名/公证/manual后再走默认重建。
- Typeless [核心链路对照](../../evidence/2026-11-03-core-typeless-review/core-chain-comparison.md) 没有证明同等 HF/本地模型能力；该模块化方向来自 FlowType 的产品目标，不用逆向文档填补未知服务端能力。

## 研究限制与执行时前置检查

没有执行服务部署、模型转换或实际推理。模型目录/格式核对与哈希不能证明识别质量、加载峰值或 Apple Silicon 各配置的表现。推荐列表需要最终版本真机矩阵才能获得“已验证”标识；官方型号、模型 revision、服务版本、硬件与测试音频摘要都须记录。

设计与计划入口：[ASR 模型中心设计](../specs/2026-11-09-asr-model-center-design.md)、[实施计划索引](../plans/2026-11-09-asr-model-center.md)。
