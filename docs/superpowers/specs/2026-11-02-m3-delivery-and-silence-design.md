# M3 自动交付与静音预检设计

日期：2026-11-02。状态：M3-A → M3-B 子智能体源码开发、全 M3 修复及限定复审通过（`f7554ee`，完整 4124/0）；最终 app 已构建，资源签名既有限制及真机 Pending 分别见验证记录。
核对基线：`b64d538`（产品源码 `e69d688`，已有自测 2507/0；本轮没有重跑）。

## 1. 意图、来源与范围

Owner 要求先核对 M3 是否有计划，弄清开发方式后补齐实施计划；并要求核对 Typeless 实际的无语音策略。当前有 [稳定性总设计 §4.4、§7、§10](2026-10-22-stability-and-delivery-design.md)，没有 M3 专门计划。[10 月交付计划](../plans/2026-10-14-delivery-accuracy.md)已经实现目标身份、结果、剪贴板事务和历史字段，默认 Unicode、实验候选粘贴的决定是旧检查点，不是这次 M3 的目标。

本设计把原有 M3 细化成两个可独立验证的工作包：

- **M3-A 自动交付**：新默认 `.automatic`；目标身份与安全检查通过后优先粘贴；确定未发键时才允许一次受控键入回退；保留显式旧模式；显示最近交付结果。
- **M3-B 静音预检**：停止后、正式识别和预览兜底前检查完整原始音频；明确静音不识别、不落字、不写历史；未知或可能有声音时继续原识别链。

成功标准是正确目标、最多一次文本派发、剪贴板所有权不丢、静音不产生转写、取消无迟到副作用。源码回归和真实验收分别记账。V1 云端弱网/断网、V2 跨应用、V3 剪贴板、V4 取消、V5 拔麦恢复继续是必做主线。

## 2. Typeless 原始代码复核

只读来源：`/Users/yiheng/pycode/typeless-re/sources-recovered/renderer/static/js/qA149QP2.mjs`，下文行号均指该文件；另见 [证据复核](../typeless-evidence-2026-10-14.md)。这是恢复的静态代码证据，不能代替当前 Typeless 真机行为，也不能排除未恢复入口或服务端另有检测。

本次核对文件 SHA256：`6764745c0deb4d95cea3df8cf30f0c7c870146ea333ad72c8d0d2bc40a7eac14`。检测与状态机相关行段均直接读取，未修改 Typeless 文件或运行其应用。

| 位置 | 直接观察 | 含义与边界 |
| --- | --- | --- |
| 3014–3018、3034–3040 | `silenceThreshold:1`、`checkInterval:100`；共享 AudioContext、Analyser `fftSize=2048`，分配 `frequencyBinCount` 长度的 Uint8Array | 使用时域字节数据；配置写了 sampleRate=44100，但这段检测没有用它创建或重采样 AudioContext，不能认定实际检测一定是 44.1kHz |
| 3059–3069 | `getByteTimeDomainData`，计算归一化 RMS、0...100 volume、maxVolume | RMS/volume 是返回的观测指标；实际 detected 不以 RMS 阈值判断 |
| 3071–3089 | 任一字节 `abs(value-128)>=1` 就 detected=true 并结束；否则检查到 duration 到期 | 很宽松的声音存在检查；不能证明会区分人声、键盘、风声、音乐，也不能把一个字节单位直接当作 Float32 PCM 阈值 |
| 4844–4848、5587–5589 | 进入 recording_active 后 1000ms 开始，最长 5s，每 100ms 再检查 | 录音早期一次性检查；不是停止后的完整音频扫描，也不是持续静音自动断句 |
| 5169、5593–5603 | 未 detected → stopping → recoverable `RECOVERABLE_NO_SPEECH_DETECTED`；检测 error 的处理为空 | 明确未发现声音才停止；检测技术异常不因此中断录音 |
| 3137–3156、5753–5756 | 退出/停止时取消检测；取消返回值可带 `detected:false,canceled:true`，guard 本身只看 detected | FlowType 应保留自己的 session/取消核验，不能直接复制该 guard 作为迟到结果处理 |

采用其**宽松、保守的声音存在判定方向**，第一版不增加专用 VAD 权重。仍按 FlowType 既有 M3 范围放在停止后，检查完整录音、保护开头短词及延迟开口；不增加“录音 6 秒就自动停止”的交互。这里的“无语音预检”是产品阶段名，技术能力是明确静音检查，不能宣称人声分类。

## 3. 全局约束

- Swift 6.2、macOS 15+；不新增/升级依赖，不下载 VAD 模型，不运行 Python 或转换脚本。
- 单一 SessionController / SessionContext 生命周期；旧 session 的迟到结果不能发布 UI、历史或交付。
- 音频扫描与 AX IPC 不阻塞 MainActor；取消检查贯穿所有等待与副作用边界。
- 不重置 deliveryAttempted，不自动重发 uncertain，不把 dispatched 写成已确认插入。
- 保留 changeCount + 完整表示快照的剪贴板所有权；不覆盖用户在事务中新增的复制内容。
- 不改变 M2 模型选择、active/captured lease、云端厂商配置和离线合同。
- 只用合成音频/文本、假提供者/剪贴板、隔离配置作自动测试；真机状态单列。
- 使用 `swift build` 后顺序执行 `swift run FlowType --self-test`，不运行 `swift test`；源码稳定后再构建 app。
- 保留分支/worktree，不 push、不 merge，不修改真实配置、权限、用户模型或缓存。

## 4. M3-A：交付设计

### 4.1 策略与迁移

新增纯 `DeliveryPolicy.swift`，收拢 DeliveryMode 和策略；原 InjectionDecision、decideDelivery、applyAccessibilityGate 保留，避免两套目标身份判断。

| 条件（按序） | 方式 |
| --- | --- |
| 停止时目标缺失、PID 或已知 AX 身份变化 | 复制恢复，不向新目标发键 |
| secure input、明确非文本、无 AX 权限 | 复制恢复，不发键 |
| `.unicode` | 原键入路径 |
| `.pasteInSupportedApps` | 原六项候选目录内粘贴，其余键入；失败恢复保持旧合同 |
| `.automatic` 且同目标 editable / blindOrUnknown | 粘贴；未知 bundle ID 不影响同 PID 的安全检查 |

新配置和缺失/无法识别 deliveryMode 的旧配置解码缺省为 `.automatic`。明确存储的 unicode / pasteInSupportedApps 保留，不能用版本标记推断它们是否曾由用户点击。设置提供「自动（推荐）」「仅键入（兼容）」「旧版候选应用模式」三个可表示的值，防止旧模式仍保存却在 Picker 中无选中项；说明候选目录不是兼容性认证。

### 4.2 同一次尝试中的回退

保持 beginDeliveryAttempt 只调用一次。当前 deliveryEffectStarted 同时覆盖临时剪贴板写入和按键，不能独自证明“文本已发出”；保留这个锁与语义，另在同一锁内记录 `deliveryEventStarted`。`performDeliveryEvent` 同时声明 effect/event，KeyboardInjector.postIfActive 的真实平衡按键对走此入口；剪贴板写入仍只声明 effect。不能重置任何 latch 来允许回退。

| 粘贴结果 | 自动模式动作 |
| --- | --- |
| dispatched / uncertain / clipboardChanged / cancelled | 终止该尝试；不键入、不自动复制、不重发。保持原有结果/所有权变化提示 |
| unsafeSnapshot | 原板未改；允许进入下面的严格回退检查 |
| notDispatched | 原板未改或已恢复，且无按键；允许进入下面的严格回退检查 |

只有 `.automatic`、结果属于上述两类、**实际无按键**，并在事务退出后重新核验同 PID/已知 AX 身份、AX 仍授权、安全输入关闭且**明确 editableText**，才键入一次。盲区可进行首次自动粘贴，但不把“无法确认可编辑”当作二次键入依据；用户可显式改为仅键入。

回退键入在首键前失败 → 保留原剪贴板，挂起为含完整文本的复制/关闭恢复卡片；不能落入通用 copy 分支破坏刚保护的图片/文件/不可读取表示。回退首键后失败或取消 → uncertain，停止后续派发，不再复制或重试。取消前无文本事件、临时板已恢复 → cancelled，不能因临时写板标记就误报已发送。原 `.unicode` 首效应前失败的显式复制恢复继续保留。

模式在尝试开始时取一次快照；回退不因设置页并发变化而切换策略。目标和权限在回退前取新快照。最终审查 F1 补齐：自动键入回退在每个真实 chunk/newline 平衡键对前复检目标、权限、安全和明确可编辑性，等待后再检查取消；首键前拒绝保留全文恢复，首键后拒绝 uncertain。剪贴板默认 settle 保持 150ms；没有真实慢消费证据不改为 250ms，更不复制 Typeless 的 500ms 包装等待作为插入确认。

### 4.3 结果与界面

沿用 DeliveryOutcome 与现有数据库/JSON 可选字段，不新建数据库迁移。uncertain 文案改为「已发送，但无法确认是否插入；可从历史复制」。保留原有 polish 降级提示组合，正常派发不新增弹窗。

增加内存 `LastDeliverySummary`：sessionID、outcome、停止时目标的展示名/bundle ID，无文本、音频或上下文。SessionController 仅从仍拥有生命周期的终态更新；未派发的取消/静音不清除上次结果，旧 session 晚到不能覆盖新结果。最终审查 F2 补齐：取消仍持有当前会话时，在同一事件 gate 关闭发键后，按实际 event 证据同步将 nil/尚未保存的派发终态转为 uncertain，再保存一次历史/摘要并失效所有权；只写临时板不能产生 uncertain，晚到 stage 不获发布权。菜单显示「最近一次交付」，区分“已发送粘贴/键入”“已复制（原目标…）”“发送不确定”；不能写“已输入成功”。可注入 session 的 LastDeliveryMenuController 负责菜单项与同步订阅，菜单打开时再读最新值；测试不需要启动 StatusBarController.shared 或真实应用。

## 5. M3-B：静音预检设计

### 5.1 输入、算法与结果

输入是 RecordingStage 已保留的完整原始 **16kHz、单声道、Float32** samples，发生在归一化、转 WAV、正式识别和 Apple 预览兜底前。不给模型裁头尾，不只抽检前 5 秒。

第一版采用可审计、无权重的保守能量/峰值门槛：20ms（320 samples）帧；至少 100ms（1600 samples）才允许判定静音；每帧 RMS ≤ **0.0003** 且全程 peak ≤ **0.001** 才返回 clearlySilent。这是针对 Float32 的**待真机校准候选参数**，不是逆向得到的 Typeless 参数，不代表已证明适配全部麦克风。边界 `<=` 固定；全程扫描包含最后不足一帧的尾部。

结果：`emptyCapture`（0 样本）、`clearlySilent`、`possiblySpeech`、`indeterminate(reason)`。短于 100ms、非法采样率、非有限/超出归一化范围的样本返回 indeterminate；不把损坏音频当成静音。possiblySpeech 仅表示有足够信号，不能声称识别人声。短音频/检测技术异常保留原音频进入原识别链；已知非法样本/采样率则报告录音数据异常，不能继续送给模型或伪装 noSpeech。

扫描 O(n)、O(1) 额外统计空间，不分配全量分帧副本；显式后台运行，每帧检查取消。技术异常走 unknown/原识别，CancellationError 继续取消，不能吞掉变成继续识别。初版无敏感度 UI、无自动降噪/自适应阈值/音频裁剪。

### 5.2 管线接线

在 **ASRStage 开头**调用可注入的 preflight，保证直接 ASR 重试入口也会经过检查，不另增容易被 retry 跳过的管线阶段。先取走 live realtime handle 并安装原有 defer 收尾，再等待 preflight；静音路径不构造新的 route、不调用 batch provider 或 saved-realtime factory、不 finish 现有实时识别、不走预览兜底、不修改 provider health。

- clearlySilent → `.notice("未检测到声音，请重试")`；emptyCapture → `.notice("未录到音频，请重试")`。
- invalidSamples / unsupportedSampleRate → 不可重试的录音数据错误「录音数据异常，请重新录音」；无 provider 请求、预览兜底、落字或历史。tooShort / detectorUnavailable 则继续原识别。
- 两条路径都不进入 PostProcess/Polish/Injection，不写转写历史、不产生 recent-delivery 摘要；沿用约 2.2s 的 notice 自动回 idle。
- live ingress/startTask/session 都按旧取消边界收尾；不等待不合作的网络取消阻塞界面，旧结果由 session 所有权挡住。
- **实时配置可能已在录音中上传音频。** 这一步阻止的是停止后的 finalize、兜底、转写交付，不能承诺零云请求/零费用。batch 路径才可验证静音不发正式识别请求。
- 不重置停止时的单一 20s CompletionBudget；预检耗时属于同一预算。设备冻结/拔麦仍由 RecordingStage 的现有设备错误路径处理，不伪装为静音。

### 5.3 校准与退出边界

候选参数先在合成输入锁定边界，再以固定源码/bundle 做真实 5s 静音、轻声、极短词、开头/尾部单词、1s 内开口与超过 6s 才开口、键盘/风扇/风噪检查。低于两个门槛的极轻声仍可能被误拦，不能承诺零吞词。优先避免吞字；噪声若放行记为该保守算法的能力边界，不伪称专用 VAD。实际静音无法拦截或轻声被误拦时，M3-B 真机验收不通过，先修订有证据的参数与回归，不提高到“人声过滤”承诺。需要专用 VAD 时另行评估资产来源、离线加载、失败放行、硬件及新授权范围。

## 6. 验证、依赖与非目标

执行顺序：M3-A 三个任务 → 限定阶段复审 → M3-B 两个任务 → 全 M3 源码复审 → 固定 bundle 的真机矩阵。A/B 共享 SessionContext 和 SessionController，顺序修改，避免并发写同一生命周期文件。

| 关口 | 必需证据 |
| --- | --- |
| A 策略与迁移 | 目标/安全/权限 × 三模式；缺省与显式旧值；unknown bundle；不改其他配置 |
| A 回退与事务 | 原样 ClipboardTransaction + fake board；未发键但临时写板已恢复；unsafe 多类型表示；首键前/后失败、并发复制、切焦点、取消、重复调用 |
| A 结果 | 同一终态一次历史；过期会话不能覆盖摘要；菜单开着/重开正确；结果不声称确认插入 |
| B 预检 | 数字静音、阈值边界、首尾极短信号、完整长录音、NaN/Inf/短音频、取消与 MainActor 心跳 |
| B 接线 | 真实 ASRStage/controller + synthetic capture；静音无 batch/finalize/preview/polish/delivery/history/health；live 取消；原实时/路由测试不误用零 samples 作为有声fixture |
| 真机 | 五应用中文/英文/多行；安全/无 AX；多表示与并发剪贴板；轻声与静音校准；V1–V5、连续 20 轮与设备恢复 |

本文件源自规划轮；实施与验证进度以 [M3 验证记录](../../evidence/2026-11-02-m3-validation.md)为准，不把旧自测数当新验证。M4 统一 FailureKind、M5 smoke/BuildInfo/CI，以及 AX 插入确认、原生 helper 逆向、新热键/自动断句和专用 VAD 均不在 M3 产品实现范围。执行计划：

1. [M3-A 自动交付](../plans/2026-11-02-m3-a-automatic-delivery.md)
2. [M3-B 静音预检](../plans/2026-11-02-m3-b-silence-preflight.md)

## 7. 方案比较与自审

推荐上述增量方案：复用已审查的事务/所有权，先实现与 Typeless 静态证据一致的宽松声音检查，新增能力可分别回归。照搬录音早期 1s+5s 检测会改变录音交互并可能漏掉窗口前/后的短词，不符合停止后 M3 范围；直接引入 Silero/其他 VAD 增加权重与加载生命周期，当前需求和证据不要求这项成本。

自审已覆盖：旧模式 Picker、停止时目标、临时板效应与实际按键分离、受保护板的键入失败、异步取消/预算、实时已上传边界、空音频带预览、provider health、历史与菜单摘要，以及候选参数未经真机校准的限制。设计和计划可评审，不等于实现或真机通过。
