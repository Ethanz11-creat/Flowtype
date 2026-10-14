# 交付可靠性与上下文准确率设计

日期：2026-10-14。依赖前两项目的 session/budget 合同。

## 目标与证据

用户知道文字去了哪里，跨应用切换不误写，整理保留路径、命令、数字和代码术语。Typeless native paste 符号只支持派生结论，500ms 不是确认信号，故不得据此宣称插入已确认。

## 上下文与精修

AXContextProvider 在工作队列进行有界采集；显式 0.15 秒 AX 单次消息限制，整个采集等待最多 0.5 秒，超时静默使用已采集部分/无上下文，不拖住采音。安全字段和父级始终先判断再读文本。优先选中文本、应用名与近光标文本，最终 payload上限 1200 字符，脱敏后截断；AX 支持 selection range 时选取周边窗口，否则使用 bounded prefix，不扩大到无界可见页面遍历。

SessionContext 保存 ForegroundContext（结构化，兼容已有 text 属性）；LLM 系统指令与词典独立，前台上下文作为单独的低信任数据块，禁止将页面文本当指令，明确仅作术语/主题线索。新增 cloudPolishSendContext，默认跟随已有 cloudASRSendContext（decode缺键时跟随值）；实际发送还必须通过 cloudASRSendContext 主开关，关闭旧开关不能绕行到LLM，localOnly 不发送前台上下文到云润色。改现有 ASR 上下文开关关闭时不顺手绕过到 LLM；词典仍按原策略，设置解释去向。

精修提示要求保留原意，不执行口述指令，保留路径、命令、数字、代码标识符。保真校验只对明确 literal（反引号代码、/或~/路径、URL、命令开关、版本/独立数字）做丢失检测，匹配按 token 边界，不猜中文语义；发现损坏使用完整处理后 ASR 文本并记录 polishFailed。测试保护真实技术例子，避免把普通自然语言合理整理全判为失败。沿用预算，取消不交付。

## 交付合同

停止时快照目标 PID/可得的AX focused-element identity（录音期间换应用，以停止时应用为目标；停止后再换才走剪贴板）；交付前重查，若目标应用或可比焦点变化，转剪贴板并提示“焦点已变化 · 已复制，按 ⌘V 粘贴”，不强行激活旧应用。安全/不可编辑焦点同样剪贴板；AX未知时仅同一目标 PID可沿用键入。原有 unicode 方式是默认。

新增 opt-in delivery mode：unicode 默认 / pasteInSupportedApps。粘贴支持目录首版为 TextEdit、VS Code、Cursor、Chrome/Safari/Edge（目录只表示候选适配，非已真机验证；设置标为实验）。仍须安全/焦点检查；未知app使用unicode。一次事务：保存所有可枚举 pasteboard item representations → 写 plain text → 发一次 Cmd+V → 等150ms非阻塞读取窗口 → 若 changeCount和文本仍属于本次才恢复。用户期间复制别的内容绝不恢复覆盖。清理任务独立于会话取消，提交后仍等待完整150ms才按ownership恢复；枚举或写入前changeCount变化/无法完整快照时拒绝事务。提交事件后失败/取消不自动再次粘贴；保护原剪贴板，结果不宣称confirmed。提交前失败可复制兜底，提交后不明确的结果提示“已发送 · 可从历史复制”，避免重复。

DeliveryOutcome 区分 typedDispatched / pasteDispatched / clipboard / cancelled / uncertain，只有可验证readback才能confirmed（首版不实现readback）。hasInjected更名或语义明确为deliveryAttempted，不把发事件当真实确认；每个session最多一次副作用。onboarding DemoInjectionStage遵循同一完成合同；历史按显式 terminal 完成写一次（不要只靠 .injecting→.idle，因为notice也可能终结）。

## 指标与验收

DictationSession/DB添加Optional deliveryOutcome、stopToDeliveryMs，迁移 v5_delivery；clipboard 路径也有交付耗时，报告分开 dispatch 与 clipboard，而非声称实际插入成功率。兼容旧JSON/表记录，隐私关文本时指标仍保存。统一 P50/P95 的实际 round((n-1)*p) 定义，修正“nearest-rank”文案和相关旧计划描述，不变动现有数值。

新增 docs/2026-10-14-flowtype-product-validation.md 真机清单与可复现实验：5–15秒中英 coding、30–60秒段落、静音、慢网、断网、本地冷/热、快速取消、切换输入框、各候选app、多行/emoji、用户并发复制。统计开头漏录、stop→final、stop→dispatch/clipboard P50/P95、误落字/重复、技术literal保真和失败可恢复率；不编造未采集的数据。

自动测使用真实生产decision/context/paste ownership函数、假pasteboard/dispatcher接线、DB roundtrip和旧JSON。手工验证不自动输入用户前台应用，不需要用户提供Key才运行纯测试。

## 共同约束

- 工作在现有 `flowtype-local` linked worktree，不合并、不推送、不修改 main。
- Swift 6.2 / macOS 15+；SessionController 保持 @MainActor；非 Sendable 模型推理串行化。
- 核心音频仍为 16kHz 单声道 Float32；协议适配器负责服务要求的编码。
- 后台边录边处理允许；ASR/LLM 中间文本不上屏、不增量注入；完整最终文本最多交付一次。
- 默认云端优先、本地兜底；localOnly 不发送音频或上下文，云端上下文开关继续生效。
- API Key 保留 Configuration.providerAPIKeys；新配置使用 decodeIfPresent，新历史字段 Optional。
- 不新增自有云服务、账户或计费；采用 BYOK；不调用 Typeless 私有端点。
- 每个任务提交前 swift build 和 swift run FlowType --self-test 双绿。纯逻辑与可注入服务自动测；麦克风、真实服务、AX、CGEvent 用人工矩阵，不把模拟测试称作真机通过。
