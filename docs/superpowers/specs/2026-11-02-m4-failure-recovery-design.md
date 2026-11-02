# M4 失败分级与安全恢复设计

日期：2026-11-02。基线 `68c72d4`，产品源码 `f7554ee`，既有完整回归4124/0；本轮未重复基线测试。Owner 本轮要求“仔细调研，然后写计划去开发”，本设计记录调研后方案；沿用子智能体逐项实现与独立审查。真实验收不由源码测试代替。

## 1. 意图和范围

M4 解决“失败后知道发生什么、有什么安全动作、不会重发或恢复错会话”。沿用 M1 权限/readiness、M2 配置和模型生命周期、M3 单次交付与原始音频预检；统一 FailureKind → 安全文案/RecoveryAction → 当前会话动作执行。

原总设计 §4.5 是方向文档，没有专门实施计划；其 deliveryUncertain 同时列动作与 notice、规则又禁止 actionable notice，互相矛盾。本轮采用：需要用户动作的失败保持常驻恢复卡片；静音/空录音、可选润色降级仍为短 notice；用户取消仍 idle，发键后的取消只保存 uncertain 历史/摘要，不重新弹卡。曾向 Owner 发出可选偏好问题，暂无回复时按推荐的常驻不确定恢复卡执行，可后续调整。

不改 ASR 路由/网络重试算法，不新增自动重发、模型下载、音频持久化或数据库迁移；不重写完整状态机。M5 smoke/BuildInfo/签名、广泛录音重构、系统网络修复不在本轮。现有签名限制保留。

## 2. 调研证据和方案选择

[本项目错误清单](../../evidence/2026-11-02-m4-development/research/failure-inventory.md)指出：ASRStage171 的通用失败包装抹掉鉴权/配置/不可用与临时错误；retryable 不保证保留可识别音频；录音设备失败多数没有动作；设置变更不会修改捕获路由的旧密钥/模型/语言。CapsuleView 直接分发全局效果，旧按钮也没有恢复卡身份。原文路径/行号均以基线为准。

[Typeless 直接静态证据](../../evidence/2026-11-02-m4-development/research/typeless.md)含源码 SHA、别名展开、函数和行号。直接观察：权限错误持久显示设置动作；瞬时慢处理和需要用户介入的失败分开；alert Retry 读取点击时最新历史 ID 后重处理已保存音频，不能因此认为任意失败都有完整音频。弱网 needStop=false 实际继续降级，不是立即 fatal；无声却映射麦克风访问文案，不能照搬。FlowType 使用绑定失败会话和恢复代次的动作，绝不查询“最新一条历史”来决定重试对象。证据只来自恢复的静态代码，不代表真机表现或全部输入。

比较：只改 UI 映射无法恢复已丢失原因；重新实现整条状态机成本大且破坏现有取消边界；推荐增量纯策略，保留管线/事务，明确分类时机并集中动作入口。

## 3. 全局约束

- Swift 6.2、macOS15+；不新增/升级依赖，不运行 Python/转换，不下载模型，不访问真实配置、密钥、录音或模型缓存。
- 单一 SessionController/SessionContext 生命周期；旧 session、旧恢复卡、旧异步完成不能发起请求、复制、改设置或覆盖当前 UI/历史/摘要。
- 保留 M3 event/effect latch、一次 deliveryAttempt、逐键对目标复检、完整剪贴板/changeCount/用户新复制保护和150ms settle；任何 uncertain/cancel 均无重发动作。
- 原始 PCM、saved route、captured local lease、显式 ASR retry 的完整样本/新实时 handle/新20s预算保持；设置修复需要新录音，不偷偷改捕获路由。
- 可选 polish 失败继续完整 processed fallback；静音/空录音保持 notice，不走 provider/preview/health/交付/历史；非法音频不重试原 PCM。
- 用户界面和新增诊断只用稳定安全文案/枚举；不展示或记录 provider message、HTTP body、URL/query、NSError userInfo、原始文本或密钥。
- 自动化仅用合成数据、假系统/网络/剪贴板与隔离配置。验证顺序 swift build → swift run FlowType --self-test；不运行 swift test，不重复未变全套或30分钟 benchmark。
- 分支/worktree保留，不push、不merge；源码审查、固定产物与真机矩阵分别记账，未执行为 Pending。

## 4. 失败模型与纯策略

新目录 `Core/Recovery/`：FailureKind.swift 定义领域枚举；FailureClassifier.swift 只将已有 typed Error 转成安全类别；RecoveryPolicy.swift 定义唯一 RecoveryAction、资源摘要、纯展示与卡身份。现有嵌套 ErrorAction 改为 typealias，保留旧调用点表达；不复制两套动作或文案。

FailureKind 至少覆盖以下精确值：

- permission(PermissionKind)，PermissionKind = accessibility / microphone / speechRecognition。
- readiness(ReadinessIssue)，复用现有类型，不另造 ReadinessBlocker。
- configuration(ASRConfigurationIssue)，issue = credentials / endpointOrModel / unsupportedLanguage / requestRejected。
- transientASR：允许显式重试原录音的识别失败，不声称已确定网络原因；包含未知服务响应/可重试运输失败。
- recording(RecordingFailure)，reason = interrupted / invalidAudio / tooLarge。
- processing、deliveryBlocked、deliveryUncertain、internalFailure、cancelled。

RecoveryAction 保留 retry(stage:String)、copyRaw、copyResult、dismiss、openAccessibilitySettings、openMicrophoneSettings、openASRSettings、recheckReadiness、useAutomaticRouting；增加 openSpeechRecognitionSettings、rerecord、viewHistory。displayName 集中在该类型。retry 仅对实际 ASR 阶段且保留非空 audio、尚无 deliveryEvent 才可出现；绝不“重试输入”。

RecoveryResources 仅含 stage:String、hasAudio:Bool、textKind:RecoveryTextKind（none/raw/result）、deliveryEventStarted:Bool、routingPolicy:ASRRoutingPolicy、hasHistory:Bool，不保存音频/文本。FailurePresentation 只含 kind/message/actions；RecoveryCard 再加 id:UUID、sessionID:UInt64。实际可复制文本继续保留在 ErrorRecoveryContext/控制器，不能嵌入展示模型/日志。

ErrorRecoveryContext 保持旧 initializer 源兼容，新增 failureKind 与 textKind；若未显式提供，使用 typed classifier，不能从本地化错误文字匹配。retryable 保留兼容字段，不再作为动作或执行权限来源。未知 legacy retryable=true 不得凭布尔解锁派发/非法音频/配置重试；需要重试的测试 fixture 明确提供真实 transientASR 和 audio。

分类接口固定为 `FailureClassifier.classify(_ error: Error) -> FailureKind`，未知错误和解包超限均为 internalFailure；不按 stage 名或 retryable 猜 transient。`ErrorRecoveryContext.init(failedStage:error:rawText:retryable:failureKind:textKind:)` 后两项为可选默认参数；textKind 未提供时，有 rawText 则 raw，否则 none。策略入口为 `RecoveryPolicy.presentation(kind:resources:) -> FailurePresentation`。

纯 RecoveryPolicy.presentation(kind:resources:) 精确规则：

| kind | message | 动作（按顺序，省略无资源项） |
| --- | --- | --- |
| permission | 辅助功能权限未开启 / 麦克风权限未开启 / 语音识别权限未开启 | 对应设置、重新检测、忽略 |
| readiness(noEngine) | 没有可用的语音识别引擎 | 打开ASR设置、受限策略时改为自动路由否则重新检测、忽略 |
| 其余 readiness | issue.reason | 重新检测、忽略 |
| configuration(credentials) | ASR 密钥无效或未配置，请检查设置后重新录音 | 打开ASR设置、重新录音、忽略 |
| configuration(endpointOrModel) | ASR 地址或模型配置不可用，请检查设置后重新录音 | 同上 |
| configuration(unsupportedLanguage) | 当前模型不支持所选语言，请调整设置后重新录音 | 同上 |
| configuration(requestRejected) | 识别请求被拒绝，请检查 ASR 设置后重新录音 | 同上 |
| transientASR | 语音识别未完成，可重试原录音 | 有合格audio才重试识别、重新录音、有原文才复制原文、忽略 |
| recording(interrupted) | 录音中断，请检查麦克风后重新录音 | 重新录音、忽略 |
| recording(invalidAudio) | 录音数据异常，请重新录音 | 重新录音、忽略 |
| recording(tooLarge) | 音频过长，请缩短后重新录音 | 重新录音、忽略 |
| processing / internalFailure | 文本处理未完成，请重新录音 / 处理未完成，请重新录音 | 对应可用文本复制、重新录音、忽略 |
| deliveryBlocked | 未发送文本，可复制结果 | 有完整result才复制结果、忽略 |
| deliveryUncertain | 已发送，但无法确认是否插入；可复制结果 | 有完整result才复制结果、有历史才查看历史、忽略；无重试 |
| cancelled | 无 | 无，idle |

保留 M3 DeliveryCopy 的精确文案作为原兼容值；常驻卡使用本表文案，避免隐私模式不存文本或保存失败时仍承诺“从历史复制”。viewHistory 只打开历史页面，不定位/重试最新记录，不保证 DB 成功或包含转写。hasHistory 指本会话已进入终态历史保存路径（不是磁盘持久化证明）；不展示虚构的成功确认。正常 typed/paste 成功无新增卡片。

### 4.1 分类矩阵与多候选失败

分类不解析任意 provider 文本。CancellationError、CloudASRError.cancelled、NSURLErrorCancelled、RealtimeAudioIngressError.cancelled 优先 cancelled，不能继续 fallback 或写失败 health。

Cloud HTTP401/403→credentials；400/404→endpointOrModel；413→tooLarge；408/429/500...599→transientASR；其余（含拒绝重定向）→requestRejected。noAPIKey→credentials；noModel/noActiveProvider/invalidURL/unsupportedRealtimeTransport→endpointOrModel；audioEncodingFailed→invalidAudio；invalidResponse/timeout→transientASR。网络包装只检查 NSError domain/code：cancelled优先；badURL/unsupportedURL和TLS/证书类→endpointOrModel；其他网络错误→transientASR，不展示userInfo。嵌套 Cloud/Speech networkError 最多解包4层，超出保守internalFailure。

RealtimeASRConfigurationError 全部 configuration（missingAPIKey为credentials，其余endpointOrModel）。DashScopeRealtimeError/非取消 ingress/WebSocketTransportError 为 transientASR，不从 taskFailed.code/message 猜鉴权。SpeechProviderError.notAvailable→readiness(noEngine)，permissionDenied→permission(speechRecognition)，transcriptionFailed→transientASR。Whisper unsupportedLanguage→对应配置；invalidSampleRate→invalidAudio；本地目录/图/分词器/runtime错误→endpointOrModel。ModelProvisionError仍由M2设置修复，不在ASR重试中重新下载。录音两种权限错误都映射mic；已知engine/format错误→interrupted。InjectionStageError.invalidPayload及各阶段invalidPayload→internalFailure；pre-event injection失败→deliveryBlocked，post-event继续M3 uncertain终态，不能仅按error猜。

ASR 原一次候选链及健康记录不改：每次 catch 在原因丢失前记安全 firstFailureKind；成功 fallback 仍成功；失败保留第一实际候选原因，后续预算到期不盖掉已知配置/权限问题。无候选→readiness(noEngine)，仅预算到期无先前原因→transientASR。混合候选两种顺序都固定该规则并写回归；这是保守修复第一失败来源，不重排候选。

### 4.2 录音启动错误的小范围补齐

AudioRecorder299 的 catch 只对某个CoreAudio域调用冻结通知，其他启动错误可能伪装成正常空录音。本轮仅补齐“任何 engine.start 失败都进入已有设备失败路径”，不改采集转换/心跳/选设备/音频长度。抽取窄同步 engine-start 边界，生产调用真实 prepare/start，测试用抛错闭包；失败先通知frozen再finish spectrum一次，RecordingStage沿用现有engineStartFailed，不把失败送ASR/preview。不可访问真实硬件作单测；真实拔麦另列Pending。

## 5. 控制器、动作所有权与展示

新增 `Core/Recovery/SessionRecoveryState.swift` 保存当前卡和可复制文本的纯状态值，`RecoveryEffects.swift` 定义 MainActor 的系统效果。动作验证、重试/重新录音/终态转换留在 PipelineOrchestrator.swift 的原 SessionController 内；控制器保留生命周期字段private，不新增 coordinator 或第二套会话生命周期。

每次呈现卡生成新UUID，记录sessionID、kind、message、允许动作；CapsuleView 捕获这张卡的ID调用 `performRecoveryAction(_:cardID:)`，控制器核对error状态、当前卡ID/sessionID和动作存在。配置/权限跳转、复制等全部在验证后才调用可注入 RecoveryEffects；不得由View直接操作单例。旧方法retryFailedStage/copyRawText/recheckReadiness/useAutomaticRouting/dismissError可作为当前卡的兼容包装，核心只有一个入口。

- retry仅ASR+保留audio+活动context+无事件，清旧恢复卡再重跑同阶段。保留saved route/lease、完整audio/preflight、polish偏好，新20s预算和新realtime handle；不隐式重试。
- rerecord 调startRecording创建新session，清旧卡/上下文，不复用损坏PCM。设置修复需要新录音；打开设置本身不发请求、不自动重绑route。
- recheck重新读readiness：仍blocked时更新类别/文案/动作；ready/degraded时回idle，绝不自动录音/发送。useAutomaticRouting只改policy，刷新后仍blocked则保留新卡，否则idle；旧捕获重试被清除。
- copy只复制当前卡完整raw/result，使用效果seam，仅用户点击才可覆盖剪贴板；复制后卡仍可见。viewHistory只导航，不复制/重试。
- stage suspend统一用typed policy；取消先处理，不根据动作数/legacy retryable猜原因。有动作→error常驻，无可执行动作只限cancelled（idle）或真实notice信号；不为非法PCM/设备错误自动2.2s消失。
- 正常 finish 的uncertain先一次保存历史/摘要，再建立只复制/历史/忽略的终态恢复卡并关闭context资源/事件gate；保留卡所有权元数据，不给旧stage继续发布权。显式cancel维持M3的uncertain一次保存后idle，不新弹卡。
- noAX仍按M1降级可菜单录音/复制；不得把readiness degraded变成录音阻断。polish降级/静音无新卡，正常typed/paste无卡。

界面错误区固定380×156，使用两列动作布局（最多四项），安全文案允许两行；保留既有主题与无转写预览。源码测试覆盖模型尺寸/动作顺序及真实controller效果，GUI布局仍为Pending。

## 6. 验证与退出

三个任务：纯模型/策略（独立flags+矩阵）→阶段显式分类（真实ASR+fake provider、窄录音边界）→控制器/效果/卡片（真实controller/ASR/InjectionStage，系统边界fake）。每项focused RED/GREEN、顺序build/full、独立任务审查；最后全M4审查、一波修复+限定复审、固定最终app并记录源码与二进制身份。复用现有linked worktree，无重复基线全套。

必须覆盖：故意矛盾kind/legacyretryable；401与超时真实stage不混类；第一候选失败与成功fallback；旧卡对新session的每类副作用=0；显式retry原PCM/新handle/预算；重新录音新ID；设置修复不重放旧路由；invalidPCM无provider；typed/paste不确定无重试；显式cancel历史/摘要一次且idle；隐私模式和不含密钥/provider正文的文案；无声和polish降级原行为。

真机必做：权限拒绝→设置→重检，离线/弱网→原录音重试；坏密钥→修复→新录音；无引擎/受限路由→自动；拔麦→设备修复→新录音；跨app交付不确定→copy/history；旧卡/新会话竞态；长文案与按钮布局。当前无桌面工具/未调用真实云服务/外设时全部Pending，V1–V5持续主线。M3静音阈值校准与M2完整模型推理不因本轮而关闭。
