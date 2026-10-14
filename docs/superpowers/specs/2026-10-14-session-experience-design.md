# 会话体验与恢复设计

日期：2026-10-14。授权：用户已认可三个子项目，要求写三份开发计划并子智能体驱动执行。本文件及对应计划是该授权的具体化。

## 目标与证据

用户按键立即知道系统响应，只有采音就绪才提示“可以说话”；停止立即生效；可用转写不会因可选润色失败而消失。参考 docs/superpowers/typeless-evidence-2026-10-14.md。Typeless 的 initializing/recording/finishing 与 final-only UI 有静态证据，但长按语义、500ms 粘贴确认不可照搬。

## 设计

保留顺序 Pipeline，新增 preparing 状态和录音停止命令；停止与取消必须是不同操作。RecordingStage 请求 AudioRecorder 首个有效 PCM 的就绪事件后发布 recording，并处理初始化过程中 stop/cancel。timer 从真实就绪开始；stopRecordingAt 从实际停止手势开始。SessionController 接受同一 activeSessionID 的事件，cancel 先失效身份再终止任务。所有阶段在状态更新/交付前检查取消；旧任务结果不可推进新会话。

录音首个有效 buffer 前只显示“正在准备”；常规 processing/polishing/injecting 统一呈现“正在完成”。状态机保留内部阶段供指标与调试，不改成多个窗口各自维护状态。胶囊不显示 provider 或 LLM token。窗口继续不激活、不抢焦点；开始/停止提示音只播放一次，不因 timer 更新重播。

新增 polishOnStop 配置默认 true（明确的产品行为变化，旧配置缺键同样 true），设置提供“停止后自动整理”。录音/准备时的第一个干净触发键释放立即停止，取消 pending tap timer；结束手势不再区分原文与润色。空闲时现有 double-tap/toggle 开始习惯保留；组合快捷键不得触发听写；处理时开始请求忽略；Esc 取消。非修饰键保持现有 200ms 启动防误触，但准备/录音中的 stop 不等待 hold threshold，不受 key repeat 延长影响。文案/引导同步。

润色以完整转写为退路：最多 3 秒（或剩余完成预算更短），正常完整 LLM 结果使用；空结果、失败或到期使用已后处理转写，不交付半截 LLM 文本。降级提示在交付完成后呈现，历史标记 raw。取消不是降级，不落字。LLM AsyncThrowingStream.onTermination 取消生产者/URLSession；看门狗/重试均响应取消。

恢复状态与视图：保留失败阶段、可重试原始 payload；错误胶囊显示一个与阶段匹配的主要动作（识别重试/复制结果/去权限设置），并允许关闭；真实错误不再 5 秒自动清掉恢复材料。普通成功和 notice 仍自动收起。ASR 重试不强制开启润色，不标成“重试润色”。只在内存保留当前失败会话，重录/取消/关闭时清理，不新增音频落盘。

## 边界与测试

不提前接入实时服务（子项目二负责）；不更改注入策略（子项目三负责）。测试生产就绪/停止/取消路径、初始化时停止、旧事件、快捷键事件时间线、完整润色退路、重试阶段映射。必要时给 controller 注入 presentation/prepare/history 回调和 stage fakes，避免测试启动麦克风、加载模型、修改真实历史。扩展 self-test 的 async runner 可用于 actor/stream 测试，确保 CLI 入口仍运行全部旧断言。

## 成功标准

收到首个 PCM 才进入 recording；停止无需 350ms 双击等待；Esc 后迟到结果不落字；润色失败交付完整处理后原文；错误有可用恢复动作；正常胶囊不显示中间内容。实际按键/麦克风反馈耗时需人工测量，不在开发期承诺具体 P95。

## 共同约束

- 工作在现有 `flowtype-local` linked worktree，不合并、不推送、不修改 main。
- Swift 6.2 / macOS 15+；SessionController 保持 @MainActor；非 Sendable 模型推理串行化。
- 核心音频仍为 16kHz 单声道 Float32；协议适配器负责服务要求的编码。
- 后台边录边处理允许；ASR/LLM 中间文本不上屏、不增量注入；完整最终文本最多交付一次。
- 默认云端优先、本地兜底；localOnly 不发送音频或上下文，云端上下文开关继续生效。
- API Key 保留 Configuration.providerAPIKeys；新配置使用 decodeIfPresent，新历史字段 Optional。
- 不新增自有云服务、账户或计费；采用 BYOK；不调用 Typeless 私有端点。
- 每个任务提交前 swift build 和 swift run FlowType --self-test 双绿。纯逻辑与可注入服务自动测；麦克风、真实服务、AX、CGEvent 用人工矩阵，不把模拟测试称作真机通过。
