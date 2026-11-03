# M5 验证台账（规划态）

日期2026-11-03。当前只有[设计](../superpowers/specs/2026-11-03-m5-release-guardrails-design.md)及[M5-A](../superpowers/plans/2026-11-03-m5-a-build-identity-and-isolation.md) → [M5-B](../superpowers/plans/2026-11-03-m5-b-smoke-and-artifact.md) → [M5-C](../superpowers/plans/2026-11-03-m5-c-verification-and-acceptance.md)实施计划，尚未实施。所有下表Pending表示未执行，不是已确认产品故障。

规划基线HEAD `b00b0a50d9c6913a91ef01c6a8c8944688add31e`；现有产品源码 `5dc1693`，Sources tree `872e9038b8def8ed720d9cc6370c57ed12d76794`。M4历史自测23872/0、旧app二进制 `ceded28e359918d8d66f8ed1090107fb4a8bffb46aa1b8b9e0278c94a5ccc250` 仅是[旧证据](2026-11-02-m4-development/README.md)，不算M5验证。旧strict/deep签名失败仍未被本轮修复。

## 技术门禁

| 项目 | 所属任务/证明要求 | 状态 |
| --- | --- | --- |
| 进程role/路径/配置域隔离 | A1/A2；含legacy Keychain、DB迁移、无隐式模型/设备动作 | Pending |
| 构建身份/日志/关于菜单 | A3；metadata/plist一致，role/runID，flush/轮转；GUI另验 | Pending |
| 新源码顺序build/full | A/B各有意义变更后；本次实际计数、退出码和源码身份 | Pending |
| watchdog异常进程 | B1；主线程卡死、signal、子孙清理、非本run不受影响 | Pending |
| smoke 10/10 | B1/C1；每次≥6s、实际probe/健康tick≥1、独立根、固定候选 | Pending |
| standard Resources/完整签名 | B2/B3；codesign strict/deep exit0，不用ignore-resources | Pending |
| 仓库外资源/Metal/真实MLX | B2/B3；无开发bundle救场，独立三项，不加载ASR模型 | Pending |
| 本地verify聚合/失败保留 | C1；code/artifact/release、exit1/2/64准确 | Pending |
| CI配置/安全上传 | C2；arm64/Swift6.2预检，仅白名单 | Pending |
| 远端CI实际运行 | C2/C3；最终gitSHA/sourceTree匹配的code报告；本会话不push | Pending |
| 人工schema/主线矩阵 | C3；每叶子required、身份匹配、证据存在 | Pending |
| 全M5源码审查与修复复审 | 任务审查后一次全量、同一修复波次与限定复审 | Pending |

## 最终候选身份

尚无M5候选。实施后填写gitSHA、sourceTree、version/buildNumber、builtAt、binarySHA256、buildInfoSHA256、shaderSHA256、architecture、固定appPath及manifest/verify-report引用。先签名再取二进制hash；任何二进制变更均使旧人工Pass不能自动沿用。后续仅文档提交需同时保留“被测源码身份”和“归档提交”，不能把新HEAD冒充当时构建SHA。

## required 真机验收

Pass需日期、测试人、环境、确切四身份字段、具体观察与证据；子项均通过才能聚合父项。实际JSON模板由C3生成，规划本轮不创建任何伪Pass记录。此表的详细字段合同见C3。

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

本轮仅写Markdown计划并检查文档一致性；没有新构建、自测、smoke、GUI、模型、权限、网络或发布结果。
