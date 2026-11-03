# 核心链路对照：FlowType 与 Typeless

审查日期：2026-11-03。审查基线为 `2fff1c7`；产品源码与候选 `00bdd2f581a4f83a5f0cd290c542c5991380489c` 一致，Sources tree 为 `50fe779eb598377251bda42ee463e15d0930fb53`。这是当前整条核心链路的只读对照与独立代码审查，覆盖 M1–M5、原生客户端接线和胶囊，并非仅复查最近的 UI diff。

基本链路已经实现：快捷键 → 准备与权限 → 录音/背景识别 → 停止与无声预检 → ASR 路由/降级 → 文本后处理 → 可选润色 → 安全交付 → 历史与恢复。但“所有阶段存在”不代表内容与交付始终正确：本轮独立审查发现的阻塞问题见 [independent-code-review.md](independent-code-review.md)。正确性问题应先于追求竞争产品的传输与功能扩展。

## 证据口径

Typeless 根目录：`/Users/yiheng/pycode/typeless-re/`。以下短名均指该目录：

- **R**：`TYPELESS-2.8.1-REVERSE-ENGINEERING.md`。
- **Q**：`sources-recovered/renderer/static/js/qA149QP2.mjs`。
- **U**：`sources-recovered/renderer/static/js/UfR9-a2Z.js`。
- **M**：`sources-recovered/main/index.js`。

先采用 [逆向证据纠偏](../../superpowers/typeless-evidence-2026-10-14.md) 和 [M4 原始链路复核](../2026-11-02-m4-development/research/typeless.md) 的边界：600ms 不证明正常长按交互；500ms 不证明粘贴成功；已审查的调用先插入再读取 editability；WS/HTTP 是延迟结果竞争，不是已证实的断线续传。服务端模型、提示词和实际润色实现仍未知。2.8.1 静态证据不借用 2.5.0 运行观察补齐；恢复文件只覆盖 11/83 JS，负面判断只适用于已审查路径。

FlowType 代码路径相对 `Sources/flowtype/`，文档链接相对本报告；行号对应上述审查基线。下表“实现”表示当前代码存在相应调用和策略，并不替代真机或厂商互操作验收。

## 逐段对照

| 阶段 | Typeless 已知机制 | FlowType 当前链路与依据 | 判断与后续 |
| --- | --- | --- | --- |
| 触发与状态机 | Q:5175–5950 有初始化、录音、处理、失败等显式状态；Q:5491–5555 的 long-hold 分支不能直接解释为正常按住说话 | `WindowManager.swift:13–62,485–510`，双击启动，活动态单击停止；toggle 另行选择；`Core/PipelineOrchestrator.swift` 管理会话与阶段归属 | 已实现，手势是本产品选择；不照搬 600ms。真实修饰键、权限与按键时序仍需验收 |
| 采集与就绪 | renderer 音频采集、后台编码与消息发送；Q:3204 的 100ms 上传节奏 | `Core/Pipeline/Stages/RecordingStage.swift`，每次执行独立录音器，首个有效 PCM 后就绪，完整 PCM 与实时入口并行保留；`Services/AudioRecorder.swift`，16kHz 单声道采集、设备心跳 | 采集主链已实现；本地完整音频也是云端失败后的回退基础。**冻结心跳 Timer 的注册执行器存在问题**，不能只列作缺真机证据；见独立审查。拔麦/蓝牙恢复仍待验收 |
| 音柱与状态反馈 | Q:7358–7460 主要呈现状态/波形；不能从 partial 消息推断实时落字 | `UI/DiffusionWaveform.swift` 及实际录音可视化流；胶囊普通 216×54、十根细柱、真实音量和频谱细节驱动、停顿归静 | 已实现产品自己的视觉；仅原生离屏渲染与合成输入有自动证据，桌面材质、噪声底、手感仍待真机 |
| 录音上限 | 最大 9 分钟，末分钟提示（R:181–183 及录音状态链） | `Core/Configuration.swift:400,436` 默认/上限 10 分钟；`Core/PipelineOrchestrator.swift:771–794` 按归属计时自动停止；胶囊显示接近上限状态 | 主动差异，不是缺陷；应按本产品时长策略验收 |
| 无声处理 | Q:3014–3150,5587–5600：录音开始约 1 秒后启动、观察约 5 秒的一次早期音量检测；不等于端点 VAD | `Services/Speech/SpeechPreflight.swift:19–21,35–64` 停止后扫描完整 PCM，20ms 帧；仅极低 RMS/peak 且至少 100ms 才判明确静音，极短/不确定放行 | 主动选择更保守的停止后预检。**实时模式在停止前可能已上传音频**，不能宣称静音零请求/零费用；未来可研究独立的早期无声提示 |
| 云端管线与厂商 | Typeless 私有长连接协议，U:8136–8148 先 metadata 后 binary；私有服务端能力不能当作标准厂商 API | `Services/Speech/CloudProviders/CloudASRVendor.swift` 支持硅基流动/OpenAI/DashScope/custom；`CloudTranscriptionRequestBuilder.swift:39` 按能力与上下文开关构造字段；兼容 HTTP 与 DashScope WS 分离 | 已实现 BYOK 厂商边界。URL+密钥仍需对应厂商协议/模型；不能把 HTTP 兼容误称任意厂商支持实时 WS。真实服务互操作待验收 |
| 传输效率 | Ogg Opus 单声道约 32kbps、后台 worker；100ms 分块 | `Services/Speech/RealtimeASR.swift:51–110` 为 DashScope 协议编码 16kHz PCM16LE；`DashScopeRealtimeASR.swift:220–224` 发送有界入口数据 | 性能差异：音频净载荷约 256kbps，即名义 8 倍；是协议约束，不应直接改为 Opus。可按厂商能力扩展 codec、分块和连接复用，先实测延迟/耗电/流量 |
| 最终结果与 partial | U:8734–8748 缓存 partial；U:8750–8784 用最终 refined_text 和 audio ID 完成；审查路径不渲染 partial | `Services/Speech/RealtimeASR.swift:157–185` 只提交 sentence_end；task-finished 不把未完 partial 升格；`Core/Pipeline/Stages/ASRStage.swift:95–193` 只接受非空完整候选；预算内可能使用设备端 Apple 预览兜底 | 终稿一次交付已实现，不需要先补实时字幕；Apple 预览是内部候选，不是向用户流式插字 |
| 弱网与降级 | U:8301–8379：每音频 WS 与延迟 HTTP 结果竞争、完成 ID、胜者交付、清理/取消败者；弱网可立即 fallback | `Services/Speech/ASRRoutingPolicy.swift:64–98` 自动/仅云/仅本地；健康条件决定顺序。`ASRRouter.swift:519–521` 自动且本地可用时云端尝试最多 5 秒；ASRStage 顺序尝试捕获的候选及模型 lease | 已实现云/本地回退，**不是同服务 WS+HTTP 延迟竞争**。后者与跨会话连接复用是可选优化，不是当前主线漏接；实际弱网/断网与最坏延迟待测 |
| 超时预算 | Typeless 普通 refine 20 秒、command 30 秒、HTTP fallback 40 秒；不是同一个整体预算 | `Core/PipelineOrchestrator.swift:374,430` 停止/显式重试各有一次 20 秒预算；`PolishStage.swift:87–92,120` 可选润色默认 3 秒并受剩余预算限制 | 已实现本产品预算；不应将外部系统落字耗时一概声称由 20 秒硬截断，也不照抄竞争产品各阶段常数 |
| 本地与导入 | 当前已知 Typeless 云端协议不能证明存在同等本地 HF 执行能力 | `Services/Speech/LocalModelManager/LocalASRRuntimeFactory.swift:8–28` 载入前重检指纹与配置；支持兼容 Qwen MLX、Whisper CoreML；内置 Qwen 0.6B/1.7B 下载与 lease | 产品差异/已有能力。**不是任意 Hugging Face ASR 架构通用加载器**；应保持导入检查与 UI 支持范围一致，真机模型矩阵待测 |
| 上下文、词典与风格 | M:19400–19529 有独立上下文/模式参数，M:12034 截断上限 30000；不能从字段反推服务端提示词 | `Services/Context/ContextProvider.swift:18,65–127` 限长 1200、secure field 排除和敏感串遮罩；`AXContextProvider.swift:5–22` 有界采集；`LLMService.swift:85–109` 分离低信任上下文与指令，按开关/能力发送 | 有实现且刻意收窄采集范围；不是浏览器全文采集。ASR 厂商不支持 prompt 时不能声称词典/上下文必然生效；需用实际模型验证收益 |
| 后处理与可选润色 | 协议区分 transcript/refined text，但服务端是否 LLM、纠错算法及质量未知 | `PostProcessStage.swift:35–50` 总先执行本地规则；`PolishStage.swift:100–147` 再按模式选择润色、完整流与 literal guard | **存在正确性阻塞**：前置规则会改坏数字/代码/URL，而后置 guard 以已处理文本为基线，关闭润色也不能绕过。见独立审查；不能宣称文字保真已闭环 |
| 目标与跨应用输入 | Q:3838–3878 先调用插入再读取 editability；M:11714–11726 的 500ms wrapper 不证明目标收到文字 | `Core/Pipeline/SessionContext.swift:276–292` 以停止时前台目标为准；`InjectionStage.swift:65–153` 初始 PID/元素/AX 门控、paste/Unicode/clipboard 分路；`DeliveryPolicy.swift:22–38` 自动降级须明确未发事件 | 采用停止时目标，是当前规格选择。**Unicode 主路径缺逐对目标复查**，和自动降级路径不一致，见独立审查；不能把“有入口门控”当作整个输入期间安全 |
| 剪贴板与交付语义 | Native helper/纯文本与富文本 IPC 有证据；native 恢复时序/确认语义仍不明 | `Services/KeyboardInjector.swift:320–391` 串行事务、完整 representation 快照、changeCount 所有权、独立清理；`InjectionStage.swift:96–152,201–216` 区分 dispatched/uncertain，已发事件不自动重送 | 保护机制已实现，不能承诺目标确认收到；150ms 也是可读窗口而非 acknowledgment。多格式、并发复制和各应用粘贴仍是主线真机 Pending |
| 取消、失败与恢复 | Q 录音状态机、U completed IDs/cancel、历史重试区分阶段 | `Core/PipelineOrchestrator.swift` 维护 session/card/generation 归属、资源排空与显式重试；`ASRStage` 保留完整 PCM；恢复操作依据错误阶段和是否已发交付事件 | 上层机制已接通，不自动重复可能已落字的结果；**AppleSpeechProvider 在锁内 finish，onTermination 重入同锁**，可能破坏真实录音结束/清理，见独立审查。各阶段取消、迟到结果及设备恢复仍需实际验收 |
| 历史与失败音频 | U:8198–8300 的历史 retry 压缩已存音频再走 HTTP；事件名不证明 WS 重传 | `Core/DictationHistory.swift:24–48`、`Core/Database/Records.swift:4–26` 存文本/指标/交付结果，无持久 PCM；`PipelineOrchestrator.swift:419–430,583–589` 失败音频仅在当前挂起会话内存中重试 | **能力缺口**：重启后不能从历史音频重识别；不是当前 M4 会话内重试的缺陷。若做，应独立设计保存开关、保留时长/磁盘配额、删除与隐私迁移 |

## 建议的剩余顺序

1. **先修独立审查确认的内容、交付与生命周期问题。** 文本规则需保护数字、URL、代码及重复字符；Unicode 主路径需复查输入期间目标；Apple 预览结束需把 finish/外部回调移到锁外；设备冻结监测需使用确实会执行的调度器。补真实管线回归，尤其避免继续以直接调用 frozen 回调的假录音器替代实际 watchdog 调度验证。
2. **继续现有真机主线 V1–V5。** 真实云端弱网/断网/坏密钥；TextEdit、VS Code、Chrome、Terminal、Cursor 的中英/多行/emoji 与安全目标；剪贴板多格式和并发复制；各阶段取消/迟到结果；拔麦/蓝牙恢复。这是已实现行为缺证据，不应另开功能替代。
3. **按测量决定传输优化。** 记录 stop→首个交付事件、云端5秒回退比例、模型冷/热启动、录音流量、连接耗时。只有数据说明需要时，才为具体厂商规划连接复用、延迟 HTTP 竞争或其他编码；不向所有 BYOK 厂商复制私有 WS 协议。
4. **独立讨论历史音频重试与更丰富的编辑能力。** 跨重启重识别、command/翻译、富文本、账号/云同步等属于产品扩展；本次未据此宣布核心错误或擅自加入实现承诺。

## 验证与结论边界

本轮只读核对当前生产调用链、规格和逆向源码，并委派一个独立 reviewer。没有访问真实麦克风/云端、注入键盘、改动剪贴板或切换系统权限；没有重新运行未改变源码的全套门禁。reviewer 的聚焦离线合成实验记录在独立报告中，不等同于真机测试。

此前相同产品源码的 code **25555/0、7 阶段通过**，artifact **22 阶段通过**，详见 [候选证据](../2026-11-03-capsule-waveform/README.md)。这些结果保留，但不能覆盖本轮新发现的测试盲点。当前候选的真机与远端 CI 仍为 Pending；41 项实际验收范围见 [主线验收表](../../superpowers/validation/2026-11-03-native-client-acceptance.md)，不得把旧候选状态或离屏截图改写成当前真机通过。

最终状态：**核心骨架已覆盖，文字保真、Unicode 输入目标和录音生命周期存在待修问题；尚不能以“全部对齐 Typeless / 发布验收完成”收尾。** 本轮未修改产品源码，报告中的修复与扩展是后续优先级，不是已完成实现。
