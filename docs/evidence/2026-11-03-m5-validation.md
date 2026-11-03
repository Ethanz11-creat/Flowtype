# M5 验证与剩余验收台账

日期2026-11-03。按[设计](../superpowers/specs/2026-11-03-m5-release-guardrails-design.md)及[M5-A](../superpowers/plans/2026-11-03-m5-a-build-identity-and-isolation.md) → [M5-B](../superpowers/plans/2026-11-03-m5-b-smoke-and-artifact.md) → [M5-C](../superpowers/plans/2026-11-03-m5-c-verification-and-acceptance.md)实施。A/B及C1/C2源码与任务审查已通过；C3源码/文档/fixture提交后等待C3及全M5源码审查。最终release技术门禁、远端CI、全部41个人工叶子仍Pending。Pending表示未执行或缺证据，不是已确认产品故障。[开发证据索引](2026-11-03-m5-development/README.md)区分历史检查点与最终候选。

历史规划基线HEAD `b00b0a50d9c6913a91ef01c6a8c8944688add31e`，当时产品源码 `5dc1693`、Sources tree `872e9038b8def8ed720d9cc6370c57ed12d76794`。M4历史自测23872/0、旧app二进制 `ceded28e359918d8d66f8ed1090107fb4a8bffb46aa1b8b9e0278c94a5ccc250` 仍为[旧证据](2026-11-02-m4-development/README.md)。B3已在新检查点修复该旧strict/deep限制；不改写M4日志，也不把B3检查点当最终C验收。

## 技术门禁

| 项目 | 所属任务/证明要求 | 状态 |
| --- | --- | --- |
| 进程role/路径/配置域隔离 | A1/A2；legacy Keychain/DB迁移与副作用预算，aea7dc9/ffd4ba4 | 源码/审查Pass |
| 构建身份/日志/关于菜单 | A3 d6aaace；metadata/plist、role/runID、flush/轮转 | 源码Pass；菜单GUI Pending |
| 新源码顺序build/full | B2 full24334/0；C1唯一实际code run全7阶段Pass/full24334/0 | 历史检查点Pass；最终C release Pending |
| watchdog异常进程 | B1 7488553；主线程卡死、signal、子孙归属与真实timer | 源码/任务审查Pass |
| 最终候选smoke 10/10 | C3最终clean源码；每次≥6s、实际probe/健康tick≥1 | Pending；尚未执行 |
| standard Resources/完整签名 | B3 c21cb25；strict/deep exit0 | B3检查点Pass；最终C候选Pending |
| 仓库外资源/Metal/真实MLX | B3移位check exit0，四项资源/Metal/MLX/inside均true | B3检查点Pass；无ASR模型推理 |
| 本地verify聚合/失败保留 | C1 653ecb8；fixture71/0，实际code24334/0，恢复fixture128/0 | 源码/任务审查Pass |
| CI配置/安全上传 | C2 66f1e78；fixture105/0，arm64/Swift6.2预检/白名单/partial/安全bootstrap | 源码/任务审查Pass；远端Pending |
| 远端CI实际运行 | C2/C3；最终gitSHA/sourceTree匹配的code报告；本会话不push | Pending |
| 人工schema/主线矩阵 | C3；41叶子、固定预期路径/source、CI独立、Pending模板 | 已实现；源码审查Pending；人工全Pending |
| 全M5源码审查与修复复审 | 任务审查后一次全量、同一修复波次与限定复审 | Pending |

Watchdog仅控制handshake确认的自有进程组及仍在组内的后代。Foundation Process另建的独立后代组不受全局清理保证；packaging恢复另查marker/live owner/inner group及资源指纹，仍活跃或冲突就Fail并保留证据，不能把外层timeout当作安全恢复证明。

## 最终候选身份

最终C候选尚未构建；在C3/全M5源码审查后另行运行一次release并填写其gitSHA、sourceTree、version/buildNumber、builtAt、binary/buildInfo/shader hash、architecture、固定appPath及manifest/verify-report。先签名再取hash；二进制变化使旧人工Pass失效。归档提交与被测源码身份分列，不能把后续HEAD冒充被测SHA。

B3历史检查点为 `c21cb25e4d37249d3d932939a6157b946b64a243`，Sources tree `953608b60a0349dfcd2acfc4ddeef6f6d6b39288`，version1.0.0/build350，arm64；binary `c59eb53b8aaec14421ef19e2c884e67cbb94f46a31ec069092051e66a38ac85f`，metadata `9ff060d015a4a3fefffb63b1378bd9e55545f7da17203cd985d5e73b42b6afc8`，shader `f36b01c44dd5f2d9020deb1ac6ad53dc085de81af19396694c5963ef3a12137f`。固定路径为本checkout `build/FlowType.app`；shader在 `Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib`。这份候选证明B3打包，不是C最终十次smoke或人工通过。

## required 真机验收

Pass需日期、测试人、环境、确切四身份字段、具体观察与证据；子项均通过才能聚合父项。[实际模板](2026-11-03-m5-manual-template.json)含41个Pending和空候选，未创建任何真实Pass。

schemaVersion=1，candidate为gitSHA/sourceTree/binarySHA256/appPath四个字符串。空候选加Pending叶子合法；非空身份必须完全匹配最终manifest、独立sourceIdentity及调用方明确指定的 `repo/build/FlowType.app`。不能从人工报告自己的路径或evidenceRoot推导预期app路径。每个Pass叶子重复这四字段，并包含：`testedAt` UTC `YYYY-MM-DDTHH:MM:SS[.SSS]Z`、非空`tester`、`environment`对象（macOS/hardware/target，target记录目标app版本、设备或服务标识）、`observation`对象（非空actions/result、整数count/durationMs）。R1 count≥10，R2 count≥20，其他count≥1且durationMs>0。观察必须描述实际动作/结果；结构校验不能辨别观察真假，需人工审阅。

`evidence`是非空相对文件数组，根严格为所提供manual JSON的父目录；文件必须存在且无链接/逃逸。父ID仅允许R1–R6/V1–V5的可选聚合行，其状态必须等于叶子聚合；不能代替缺失叶子。未知/重复ID、坏schema、错身份、伪Pass或坏引用Fail；缺required叶子Pending，release报告始终列出41叶子的状态和闭合issue。人工JSON/截图不会进入自动上传白名单。

CI JSON独立于artifact成功与否按预期gitSHA/sourceTree校验：schemaVersion1、lane code、status、精确身份、`runURL=https://github.com/OWNER/REPO/actions/runs/NUMBER`、非空evidence数组（同一run的 `.../artifacts/NUMBER` URL）。只校验已提供记录的结构/身份，不访问网络或证明服务端结果；缺报告Pending，本地日志或旧身份不能当远端Pass。全空Pending CI模板可保留Pending。没有push/远端执行授权时不能填Pass。

R3.axRecovery须记录设置授权完成与首次真实热键恢复/角标消失时间差，≤5s而非目测；R2每次记录结果、idle、麦克风释放和重复次数；R4两预置及两类导入必须真实推理；V2各应用覆盖中英/多行/emoji，V3/V4分别记录零事件和已发事件的证据。需要GUI/网络/配置/设备授权的动作尚未执行。

| 叶子case ID | 操作与通过要求 | 状态 |
| --- | --- | --- |
| R1.launch10 | 普通app连续10次冷启动；无崩溃且每run身份header，不能用smoke代替 | Pending |
| R2.sessions20 | 20次成功/取消/重新录音混合；idle、无重复落字/卡processing/麦克风残留 | Pending |
| R3.axRecovery | 缺AX→设置授权，不重启≤5s热键恢复/角标消失，记录精确时间 | Pending |
| R3.micRecovery | 拒绝麦克风→设置→重检/新录音；拒绝时无录音或落字 | Pending |
| R3.noEngine | 三引擎不可用立即可操作常驻卡，无空录音/processing；路由约束也测 | Pending |
| R3.multipleBlockers | 多权限/无引擎组合，修好一个后卡片准确显示剩余blocker | Pending |
| R4.metadata | 元数据失败分类与安全提示正确，恢复操作有效 | Pending |
| R4.switchSource | 下载源切换至少实际恢复一次，无旧操作迟到覆盖 | Pending |
| R4.retry | 失败后显式重试成功，旧事务已结束且无隐式无限重试 | Pending |
| R4.autoFallback | 自动1.7B失败只再试一次0.6B并明确降级 | Pending |
| R4.manualSelection | 手选1.7B不被失败降级覆盖 | Pending |
| R4.builtin06 | 内置0.6B真实下载/离线加载/完整听写 | Pending |
| R4.builtin17 | 内置1.7B真实下载/离线加载/完整听写，硬件适配 | Pending |
| R4.importQwen | HF兼容Qwen3-ASR MLX目录，离线导入/真实推理/重定位 | Pending |
| R4.importWhisper | HF兼容WhisperKit Core ML目录（含源包编译衔接），离线真实推理 | Pending |
| R5.silence | 5s静音/空音频，无幻觉/历史/下游交付；不虚称实时阶段零上传 | Pending |
| R5.quiet | 轻声不能被错误拦截；保守预检不确定时继续ASR | Pending |
| R5.short | 极短词可识别，记录设备/时长/判断，无少样本准确率宣传 | Pending |
| R5.noise | 背景噪声及混合语音校准，记录阈值与误判边界 | Pending |
| R6.layout | 380×156恢复卡、长文案、按钮边缘/旧卡失效、缩回尺寸 | Pending |
| R6.focus | 操作卡片不抢落字目标焦点，动作只属当前卡/会话 | Pending |
| R6.displays | 多显示器/缩放/Space/拖动，无裁切或不可点击按钮 | Pending |
| V1.weak | 真实云端弱网/长录音；正确失败分类、完整原音频显式重试 | Pending |
| V1.offline | 录音/识别中真实断网→恢复；原route/lease、全音频、新预算/实时句柄 | Pending |
| V1.badKey | 真实服务坏key/配置错误，不把设置打开/重检当重新上传 | Pending |
| V2.textEdit | 中文/英文/多行/emoji落点和剪贴板恢复正确 | Pending |
| V2.vscode | 同上，记录版本/焦点元素 | Pending |
| V2.chrome | 同上，网页输入/焦点变化不误投 | Pending |
| V2.terminal | 同上，使用无执行副作用文本，不触发命令 | Pending |
| V2.cursor | 同上，记录编辑器/输入区域差异 | Pending |
| V2.safeTargets | 密码/secure input/非文本/无AX仅复制，焦点/目标改变不误发键 | Pending |
| V3.formats | 文本/多item/图片/文件UTI恢复，不能只比一个字符串 | Pending |
| V3.concurrentCopy | 用户并发copy保留，未发事件与已发事件分别验证 | Pending |
| V4.preparing | 准备阶段取消，无迟到录音/模型结果接管会话 | Pending |
| V4.recording | 录音取消，无后续上传/交付/麦克风占用 | Pending |
| V4.asr | ASR取消，迟到结果不交付/写剪贴板 | Pending |
| V4.polish | 整理取消，无迟到fallback/交付/历史污染 | Pending |
| V4.injection | 发事件前取消，无键/剪贴板污染 | Pending |
| V4.postEvent | 真正发键后取消保留uncertain证据，不自动重发，显式copy/history语义正确 | Pending |
| V5.unplug | USB拔麦后旧会话终止/可恢复，新录音采用有效设备 | Pending |
| V5.bluetooth | 蓝牙断开/重连后无残留占用，新会话恢复 | Pending |

## 完成口径

A/B/C源码完成、产物技术门禁通过、真实验收通过、远端CI通过分别记录。缺任一required真实项/CI时release仍Pending，不因full自测或正常使用反馈改成Pass。旧UI/统计/SQLite迁移人工项仍在原审计中追踪，不随M5规划自动关闭。

历史规划轮只写Markdown，无当时测试结果。后续A/B/C1/C2实施结果如上；C3本次只做源码/文档/合成fixture，最终release及大证据归档等待后续明确调度，不在此提前声称完成。
