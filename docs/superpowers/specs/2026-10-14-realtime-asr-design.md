# 后台实时云端识别与本地兜底设计

日期：2026-10-14。依赖会话体验接口。用户明确允许后台边录边处理、最终一次落字；云端暂沿用 BYOK。

## 目标与依据

把上传和 ASR 移入录音期间，停止只等待最终转写与短预算精修。Typeless 的 100ms metadata/binary 分片与 final-only 交付有证据；不复制其端点、密钥、握手参数和未经证明的断线续传。生产 adapter 采用官方验证的 DashScope Paraformer 实时协议；参考 docs/superpowers/paraformer-protocol-2026-10-14.md。

## 接口与配置

现有 ASRProvider.transcribe 保留整段协议，新增 RealtimeASRSession：start / append PCM / finish / cancel 生命周期。独立 DashScope adapter 用 URLSessionWebSocketTask；test socket 注入只存在于测试。CloudASRProviderConfig 新增 protocolKind（openAICompatible 默认，dashScopeRealtime 可选）；独立 model/baseURL 预设 paraformer-realtime-v2 与 wss://dashscope.aliyuncs.com/api-ws/v1/inference。已有配置继续是 HTTP，不擅自转 WS；设置可添加实时 provider 和 Key，连接测试仅做协议/握手验证，不假装识别质量验证。

run-task 发送后等 task-started 才发 PCM16 LE mono 16k 二进制；finish-task 后继续收结果直至 task-finished。task_id 精确匹配；task-failed、畸形消息和断线产生结构化错误；未知非错误事件忽略。官方 Paraformer 无 sentence_id；以 begin_time 为键替换 revisions（FlowType 的明确归并策略），sentence_end=true 才提交该句；task-finished 不随意把未定稿 partial 当完整句。end_time 可 null；最终文本按 begin_time 排序。句子/重放有去重，迟到事件在 cancel 后丢弃。

音频回调仅复制/转换并交给串行有界队列，不在音频 callback 或 MainActor 等网络。未收到 task-started 时缓存不超过 5 秒音频，发送队列累计不超过 5 秒；溢出终止云端会话并保留完整录音用于本地。adapter 总开始超时 3 秒；PCM 分片目标约 100ms，但可依实际 buffer 切片。格式遵循官方服务，不引入 Opus 依赖。

## Pipeline 接线与预算

RecordingStage 在采音时根据路由/配置选择是否开启实时会话，与 AX 采集并行，不等云端 ready 才录音。完整 Float32 留在现有录音缓冲。localOnly 和本地主选不启用 WS；实时主选无可用实时配置时沿用 HTTP。SessionContext 持有会话对象与 start configuration snapshot，ASRStage finish 已开启会话并只消费其最终文本。云端失败/断线立即关闭；停止后优先尝试本地，不把失败实时会话再重试三次。未启动实时的 HTTP 主路径在 auto 且本地可用时一次请求即回退。

新增 monotonic CompletionBudget，从停止开始总计 20 秒（到可交付文本，不含长文本系统落字耗时）。auto 且本地就绪时云端最终/HTTP 首尝试最多 5 秒，随后本地使用剩余预算；cloudOnly/无本地时云端最多剩余 20 秒。润色最多 min(3秒, 剩余预算)。超时取消等待者；Qwen 同步推理不可中止 GPU 时结果仍被抛弃，新推理保持串行。到期已有完整 ASR 文本就交付原文；无文本产生可重试错误，音频保留到用户关闭/重录。网络恢复不自动重放用户取消会话。

## 健康恢复

慢/失败的当前探测可否决新鲜快 EWMA；快探测不能推翻慢真实请求证据。云端被降到后备后每 60 秒最多允许一轮真实 half-open 请求（由下一轮用户会话触发，非后台音频上传）；请求失败继续本地，成功重置失败/旧慢样本，重新更新 EWMA。Endpoint/model/protocol 身份变化清空健康数据，in-flight 旧身份探测结果不得写回。网络变化同样 invalidation。强制策略不改变。计费/受限链路跳过 probe，路由不额外猜测费用偏好。

## 指标、限制与验收

真实实时延迟样本记录 stop→ASR final，不能拿含录音时间的 session duration 和旧 batch EWMA混为一谈。content-free 记录 transport、fallback、开始/完成耗时。实际模型支持热词应按官方能力处理；Paraformer 不支持任意 foreground prompt，不发送伪造字段，词典/上下文留给精修或官方 vocabulary_id（首版不实现词表 API）。

自动测试必须覆盖真实 codec/parser/session 状态机与假 socket 接线：ack 前不发送、结束后等待、修订替换、null 时间、wrong ID、失败/超时/溢出/取消、localOnly 无 socket、实时失败完整音频本地兜底、唯一最终结果、endpoint 变更与half-open恢复。手工矩阵包括真实 Key、正常/弱网/断网、长录音、切网、取消；未执行时明确待测。

## 共同约束

- 工作在现有 `flowtype-local` linked worktree，不合并、不推送、不修改 main。
- Swift 6.2 / macOS 15+；SessionController 保持 @MainActor；非 Sendable 模型推理串行化。
- 核心音频仍为 16kHz 单声道 Float32；协议适配器负责服务要求的编码。
- 后台边录边处理允许；ASR/LLM 中间文本不上屏、不增量注入；完整最终文本最多交付一次。
- 默认云端优先、本地兜底；localOnly 不发送音频或上下文，云端上下文开关继续生效。
- API Key 保留 Configuration.providerAPIKeys；新配置使用 decodeIfPresent，新历史字段 Optional。
- 不新增自有云服务、账户或计费；采用 BYOK；不调用 Typeless 私有端点。
- 每个任务提交前 swift build 和 swift run FlowType --self-test 双绿。纯逻辑与可注入服务自动测；麦克风、真实服务、AX、CGEvent 用人工矩阵，不把模拟测试称作真机通过。
