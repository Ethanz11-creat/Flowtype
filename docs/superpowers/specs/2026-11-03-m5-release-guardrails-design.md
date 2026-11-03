# M5 构建身份、隔离验证与发布护栏设计

历史规划记录：日期2026-11-03；规划基线b00b0a5，产品源码5dc1693/M4完整自测23872/0。用户该轮要求“先对M5做计划”，只产出设计/实施计划/验收台账；未授权该轮实施、安装、修改权限或发布。沿用后续子智能体逐项开发与独立审查偏好，当时开发尚未开始。

执行更新（后续授权，2026-11-03）：以上为保留的历史规划轮，不是当前源码状态。A/B及C1/C2实现与任务独立审查通过；C3源码/文档/fixture待审，全M5源码审查和最终release技术门禁待后续调度。B3历史候选strict/deep、移位资源与实际Metal/MLX已Pass；远端CI、最终候选十次smoke及41个人工required叶子仍Pending。[执行索引](../../evidence/2026-11-03-m5-development/README.md)分列源码、产物、CI和人工，不更改M1–M4历史记录。

## 1. 意图、方案与边界

目标：任何人可判断正在运行哪份代码；自动验证不读取/改写真实配置、词典、数据库、Keychain或模型；真实启动异步回调能被进程级检查捕获；发布候选有可复核身份和门禁，未实测的行为不会被“全绿”掩盖。

选择三个相依工作包：M5-A构建身份与验证隔离，M5-B启动/资源检查与可迁移app，M5-C验证脚本/CI和人工验收收口。每包可独立审查，A→B→C。只加CI无法修复本地数据/产物问题；重做完整分发系统超出需要。新设计细化/修正原总设计§4.6，冲突时以本设计为准。

本轮不设计公证/Developer ID、自动更新、商店发布、远端备份或push/merge；不重写M1–M4会话/ASR路由/模型生命周期/数据库schema，不清理无关警告。现有metallib签名失败纳入本地产物门禁，不再允许以ignore-resources替代完整通过；若未修复，artifact门禁保持Fail，不阻止如实报告代码门禁通过。

调研依据见[规划证据](../../evidence/2026-11-03-m5-planning/README.md)。M4合成验证与真实V1–V5的边界继续保留。

## 2. 全局约束

- Swift6.2+、macOS15+、Apple Silicon；不新增或升级外部依赖/Package.resolved，不运行Python、不下载ASR模型或自动安装shader/toolchain。
- 历史规划轮仅要求计划；后续逐任务实施已获授权。源码工作完成和真实验收通过分列，当前状态见执行更新；安装、权限修改与发布未获本轮授权。
- 后续开发使用合成数据、假服务/剪贴板/输入事件和独立运行目录；不读取真实配置/词典/DB/Keychain/模型缓存，不触发授权弹窗、录音、热键输入或外部ASR/LLM请求。
- 普通app仍使用原用户配置/目录/启动行为；验证模式必须在任何shared/logger/AppKit初始化前确定，初始化失败退出，禁止回退到生产路径。
- 保留M1–M4 readiness降级、captured route/lease、原音频重试、新20s预算、新实时句柄、单次交付、剪贴板与取消/回调所有权保护；不借M5改写这些合同。
- 构建/运行报告只含身份、阶段、闭合枚举/计数/状态；不输出密钥、请求正文、转写、用户文档、原始配置、URL/query或任意NSError.userInfo。自动上传仅显式白名单的合成验证产物。
- 验证按focused→顺序swift build/full self-test；不运行swift test或重复未变全套/声学benchmark。M4的23872/0仅作历史基线，不重复一次未变baseline。
- 保留分支和worktree，不push、不merge、不安装到/Applications、不替换正在运行的app。V1–V5/真实模型/声学校准/GUI未执行均Pending。

## 3. 进程角色与数据隔离（A）

新增 `App/RuntimeEnvironment.swift` / `RuntimePaths.swift`，最早解析 `--self-test`、`--smoke-test`、`--artifact-check`；后二者role均smokeTest，含不同mode。互斥主模式，未知M5选项/重复冲突参数退出64（usage），绝不启动GUI。普通app为app。runID由进程生成UUID；测试可注入固定值，生产命令不可伪造其他run身份。

非app默认根目录 `<temporaryDirectory>/flowtype-validation/<runID>`；工具可传 `--validation-root <absolute empty path>` 以保存证据。默认系统temp基址先规范化，兼容macOS的/var→/private/var；显式用户路径则拒绝symlink本体/祖先、根目录、用户home/Library及其祖先、Library内部生产目录、已有非空目录。home下的普通仓库build目录可用，不把所有home后代误拒绝。只接受新建目录或已有空的真实目录；用不跟随链接的组件检查和独占run marker防止两个run共享根，失败退出1；未成功准备前不构造shared。测试根不自动删除，供排查；verify脚本只管理它自己创建的目录，不递归清其他路径。app拒绝仅供验证的root选项。

目录固定为config/、ApplicationSupport/、Caches/、Logs/、Tmp/；不修改HOME/CODEX_HOME，不依赖CFFIXED_USER_HOME作为唯一保障。RuntimePaths供PersistentStore、AppDatabaseProvider、ModelPreset、ModelLocator/本地import目录等所有自动模式可达全局路径使用；app路径完全兼容旧值（注意现有FlowType/Flowtype大小写）。自测迁移只在合成run目录进行；真实目录内容不作为测试输入。

ConfigurationStore.shared在非app使用唯一suite `com.flowtype.validation.<role>.<runID>`，无创建成功就退出，不回落standard；初始空配置/无key/无模型选择、关闭自动模型工作。suite是系统管理的唯一命名偏好域，不假装其文件也在run目录；正常退出仅清理本run的suite，崩溃不清扫其他域。直接使用standard的恢复sentinel/设置重载/迁移路径统一走RuntimeEnvironment.defaults或在非app明确跳过。EnvMigration在非app立即返回，禁止读cwd的.env或继承provider key环境。KeychainHelper在非app仅访问进程内锁保护字典；fixture迁移可测试语义但绝不调用SecItem*。app保持现有Keychain路径。

SessionEffects.live.prepare在非app不自动loadModel；selfTest不启动真实路由监控，smoke显式启动受控的同一个真实probe timer。模型加载/扫描只允许显式注入的合成测试依赖；QwenModelState.shared不能因构造触发真实cache搜索。AppDelegate的环境迁移/设备恢复/引导/授权/模型任务不被smoke调用。验证不声称等价完整正常启动。

## 4. BuildInfo和日志（A）

`FlowTypeBuild.json` schemaVersion=1，字段version/buildNumber/gitSHA/sourceTree/builtAt/dirty；gitSHA与sourceTree为40位hex，builtAt为UTC ISO8601。release构建要求非浅克隆、clean checkout，生成前后HEAD/工作树不变；VERSION仅接受三段非负数字，默认1.0.0，buildNumber为git rev-list --count HEAD；sourceTree=HEAD:Sources。build-app生成一次，同一值写plist/JSON，先生成后签名，失败不发布候选。

磁盘元数据类型为 `BuildMetadata: Codable, Sendable`，上述字段中buildNumber为十进制字符串，dirty为Bool；`BuildInfo.load(bundle:) -> BuildIdentity`，后者包含origin(packaged/development/invalid)、metadata(BuildMetadata?)、failureCode(闭合枚举或null)。app bundle必须有合法JSON，artifact-check遇缺失/坏字段/与plist不一致失败；swift run开发路径返回origin=development/metadata=null，展示development/build0/SHA与时间unknown，不能运行时调用git猜身份。普通app malformed metadata使用origin=invalid的unknown日志/关于展示而不凭身份故障毁掉听写；产物门禁只接受packaged、dirty=false的身份。smoke允许开发身份，artifact lane另行要求packaged。

日志/菜单“关于 FlowType”/smoke与artifact JSON统一用BuildInfo。关于菜单显示版本、build、短SHA、UTC构建时间，不需要新增设置页。app进程从main最早先同步落启动身份头再初始化shared，退出flush；只承诺每个run首条是header（不声称旧文件第一行），轮转后header仍需可定位。

AppLogger角色路由：app→原diagnostic.log；selfTest→独立run Logs/diagnostic-selftest.log；smokeTest→独立run Logs/diagnostic-smoke.log。每行有role+runID，UTC时间；自测带[SelfTest]。保留10MiB/最多3个轮转的既有上限，轮转不能串角色/run。新增 `flush()` 在退出前排空私有串行队列；logger configure只一次，第二次冲突失败，线程不执行queue.sync自锁。自测仍保留原stdout计数/exit，脚本按本run退出码+报告解析，不扫描production日志计算失败。

## 5. 两个进程级检查（B）

### 5.1 --smoke-test：启动异步基础设施

先配置role/路径/logger→NSApplication.shared/.accessory（不启动普通AppDelegate）→独立ConfigurationStore.shared→SessionController.shared（禁自动model prepare）→ASRRouter.shared→WindowManager.shared隐藏panel/StatusBarController.setup→ReadinessMonitor.refresh，显式启动probe及event-tap健康timer。只读取权限状态，不申请权限/请求AX提示、不显示引导/恢复卡、不启动录音。

所有非app的事件安装/处理在生产入口处阻断：不安装CGEvent tap、不处理真实hotkey、不修改音频默认设备；健康timer仍走真实回调及安全检查分支，记录tick。smoke报告说明tap=disabledForValidation，不能称已验证真实tap创建/授权或panel可见行为。构建hidden panel失败为失败；缺AX/mic/engine只影响readiness，不是smoke失败。状态栏由测试进程退出清理，不接收自动录音动作。

原3s改 **6s** 最小观察窗口，异步Task.sleep释放MainActor/RunLoop。必须观察到probeTimerTicks≥1（实际首tick1s）和windowHealthTicks≥1（周期5s），不以“等过6s”代替。ASRRouter计时器回调必须捕获weak self/Sendable，不从测试实例跳转shared；计数从真正callback进入累加。probe cloud配置为空，measureProbe边界禁止外网；NWPathMonitor可被动观测、不建立provider连接。延迟超过10s仍缺tick失败；外部runner15s watchdog覆盖主线程卡死/崩溃，不能只用同actor Task超时。

输出恰一行JSON到stdout（日志走文件，构建输出由脚本另存）：schemaVersion、mode="smoke"、ok、role、runID、buildInfo、readiness/AX/mic/speech闭合枚举、probeTimerTicks/windowHealthTicks、tap="disabledForValidation"、durationMs、failureCode。exit0=检查通过（readiness可blocked/degraded）；失败exit1，unsupported WindowServer环境用failureCode=windowServerUnavailable（显式Skip报告/exit69）；root/mode错误exit64。不能将任意启动失败转Skip。

### 5.2 --artifact-check：脱离开发目录的资源/Metal检查

同样先隔离，但不创建panel/tap/timer/模型。使用新的 `AppResources` 定位 `Contents/Resources/FlowType_FlowType.bundle`；app环境只允许bundle内资源，禁止绝对.build或cwd回退；开发运行才允许Bundle.module。将StatusBar图标和ASRPostProcessor两处资源加载统一入口。检查两词库可解析/非空、图标存在，必须记录resolvedInsideApp=true。

SwiftPM产生的依赖.bundle按构建产物原样复制到Contents/Resources，不能仅复制app的平铺json。逐项列manifest与路径；不把列出文件视为依赖加载已验证。当前MLX静态搜索支持 `Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib`（带合法bundle plist）；优先采用该标准资源封装，删除旧MacOS/mlx.metallib。不把shader当Mach-O签名，不依赖绕过资源校验。实现时必须验证实际当前版本搜索与真实加载；不修改依赖源码。

artifact-check显式加载bundle内Metal library，并执行无模型的实际MLX微计算验证默认搜索链，结果 `[2,3]`（输入[1,2]+1）；若需要，Package.swift可将已锁定的mlx-swift 0.31.3（revision 61b9e011e09a62b489f6bd647958f1555bdf2896）提升为显式直接依赖并引用MLX product，这是已有依赖的声明调整，不新增包或改变Package.resolved。新操作不加载ASR权重或下载资源。shader不兼容/无Metal/GPU/搜索失败均为artifact失败（code门禁不要求GPU）；不要将Metal直接加载成功冒充MLX运行通过。

输出独立一行mode="artifact"的JSON，共同字段schemaVersion=1、mode、ok、role、runID、buildInfo(BuildIdentity)、durationMs、failureCode；另含appResources/metalLibrary/mlxOperation/resolvedInsideApp布尔结果，不输出路径内用户信息。smoke沿用同一共同字段。failureCode均为闭合枚举，成功为null。外部30s watchdog；exit0/1/64。此入口不验证完整ASR推理。

## 6. 可迁移app与签名（B）

build-app不调用Python，不安装任何内容。当前实现要求MLX_METALLIB_PATH显式指向本地已存在shader；缺失即失败，不查用户模型/cache、不下载补齐。缺失/小于1MiB/无法Metal加载即不能通过artifact门禁；来源SHA256与目标SHA256写manifest。CI默认code lane不需要该文件，不能发布无shader的“成功app”。

在build下私有staging构造完整候选，复制实际release .bundle并写身份/manifest；只签真正code，资源在标准Resources。先验证strict/deep签名，再将候选移至最终build/FlowType.app；失败保留既有最终app，staging用于诊断。不得在运行中安装、启动正常app或清quarantine来伪装签名通过。若标准资源封装不能解决，记录artifact Fail和最小原因，不能退回ignore-resources当Pass。

资源脱离验证：在checkout外临时目录复制候选，临时隐藏**本worktree**的release资源bundle并由trap恢复，从无关cwd运行拷贝的artifact-check；确保本地绝对fallback无法救场。不得改依赖checkout/缓存/用户模型；同一时刻只一个构建写者。复制后codesign --verify --deep --strict仍须exit0。manifest同时记录二进制/BuildInfo/shader hash、sourceTree、architecture；验证前后hash一致。原版本/build1脚本与build-dmg中的版本冲突由build-dmg读取候选plist解决，但M5不创建/发布DMG。

签名门禁仅ad-hoc本地完整性，不等于Developer ID、公证、Gatekeeper分发通过。App运行路径迁移改变TCC身份可能影响权限；V验收必须固定候选路径/真实权限并如实记录，自动smoke不改TCC。

## 7. 双门禁、本地脚本与CI（C）

`scripts/verify.sh`显式 `--lane code|artifact|release`，默认code，输出build/verification/<runID>/。外部进程runner使用Swift Foundation Process及Darwin进程组（不用Python/依赖timeout命令）控制超时/退出；受控子包装进程先建立独立进程组再exec目标，父级接收启动握手，只终止该handshake确认归属的进程组（及仍在此组的后代），不killall、不触及既有app。先TERM，2s后仍存活再KILL；启动握手失败亦失败。Foundation Process可能创建独立后代进程组，runner不承诺全局终止它们；packaging的marker/live owner/inner group检查会拒绝不安全恢复并Fail，不能因外层已超时就假定全部内层结束。每个验证子进程新run根，suite不复用。stdin关闭，stdout/stderr分存，异常/超时均失败。code lane: platform/toolchain检查→swift build→完整self-test，单次full watchdog900s。artifact lane: clean identity→build-app→strict/deep→移位artifact-check→10次独立smoke（每次观察6s，watchdog15s）；首次发布候选执行10次，任务迭代仅改动相关focused，避免每项重复10次。packaging watchdog900s、artifact30s。

release lane运行上述两个lane一次，并消费人工验收JSON及可选 `--ci-report FILE`；任何required项Pending/Fail/未匹配最终身份返回非0（Pending为exit2），不是“代码绿所以可发布”。原总设计要求的远端CI绿继续是最终治理完成条件：ci-report须提供最终gitSHA/sourceTree对应的code lane成功与运行链接/证据；没有push或远端执行时保持Pending。每阶段phase/status/exitCode/timeout/failureCode写verify-report.json，部分成功/Skip保留，不覆盖成总绿；代码错误exit1、参数错误64。如果人工或CI报告缺失，release仍先完成有授权且可执行的code/artifact工作，再汇总Pending，不能伪造人工/CI Pass。

CI `.github/workflows/ci.yml`采用macOS15+ AppleSilicon/Swift6.2可用runner，先显示sw_vers/uname/swift版本并检查，unsupported失败而非静默换平台。默认只跑code（不依赖预装shader/WindowServer/私有模型/key）。Checkout完整git历史以保证buildNumber；不触发push/merge/deploy，也不注入provider secrets。CI artifact lane只在明确提供本地shader和可用图形会话的运行器启用；默认报告未执行为Pending。GitHub Action版本/commit固定并在实施时核对来源，不在规划中猜SHA或runner预装软件。

只上传白名单verify-report、build stdout/stderr、自测stdout/stderr和该run独立验证日志；不上传整个根目录、defaults、SQLite、.env、production日志、音频/模型。even on failure保留安全证据；若CI无WindowServer，对其artifact smoke记Skip而不把本地artifact必过规则降格。编写CI配置≠远端CI已运行，执行中若不push，远端结果保持Pending。

## 8. 人工主线与退出（C）

M5代码完成与“稳定性治理/发布完成”分开：A/B/C实现及源码审查、自测、候选身份可单独通过；发布需最终身份全部required人工项Pass。固定schemaVersion=1 manual-validation.json，每项id/status(Pending/Pass/Fail)、testedAt/tester/environment、gitSHA/sourceTree/binarySHA256/appPath、evidence；Pass必须有具体测试观察和证据，缺字段不能被验证器接受，不接收只勾选无身份的旧结论。旧SHA证据仍有历史价值，但不自动迁移到新二进制。验证器能检查格式/身份和路径引用，不能证明观察真实，需人工审阅。

C3 API澄清：manual validator额外接收独立expectedSourceIdentity和明确expectedAppPath（调用方固定repo/build/FlowType.app），manifest可空以保留空Pending模板；manifest没有路径，不能用报告路径/evidenceRoot自证预期候选。CI无论artifact是否成功都对独立source身份校验。release可选扩展manualCases/manualIssues，不破坏历史schema1报告解码/导出。41叶子逐项显示；可选父ID仅R1–R6/V1–V5且必须等于叶子聚合，不能代替缺失叶子。

Pass细节：environment为macOS/hardware/target对象；observation为actions/result/count/durationMs对象，R1≥10、R2≥20次，其余≥1次且耗时>0。UTC时间为秒或三位毫秒Z格式；evidence相对人工JSON父目录，存在且无链接/逃逸。CI只消费已有schema1 code结果，runURL为GitHub Actions运行URL、evidence为同run artifact URL；本地结果、错身份或不全Pass不得接受。人工文件不自动上传。完整字段和执行方法见[台账](../../evidence/2026-11-03-m5-validation.md)。

required：R1普通app冷启动10次（smoke10次另算），R2连续20次成功/取消/重新录音，R3真实权限拒绝与≤5s恢复/readiness多个blocker，R4模型修复/0.6B/1.7B及两类导入真实推理，R5静音/轻声/短词/噪声校准，V1真实云端弱网/断网/坏key→正确恢复，V2五应用中文/英文/多行/emoji与安全目标交付，V3多格式剪贴板和并发复制，V4各阶段取消/迟到结果/发键后uncertain无重发，V5拔麦/蓝牙断开→新录音恢复，R6恢复卡长文案/按钮/焦点/多显示器GUI。每项可细分subcases，required子项全部Pass才聚合Pass，不用一次正常使用覆盖所有变体。

自动流程不会为完成这些项修改全局网络、权限、真实配置、外设或收费服务。后续执行在具备环境/授权的范围做可执行部分，需要真实key/物理操作时说明前提，Pending不妨碍先交付完整源码/产物报告。最终矩阵引用M1–M4现有证据并更新失效文案（M4卡380×156、权限常驻、按事件证据区分uncertain），不改历史日志为新结果。

## 9. 自检与状态

设计自检：所有旧M5目标有A/B/C owner；3s/5s矛盾已解决，suite并发、legacy Keychain、shared.prepare模型加载、真实tap触发、资源fallback、CI缺shader、完整签名和人工Pending均有明确合同。签名布局为依赖静态支持的选定实现，成功须运行证明，不虚记可行性已证实。

历史规划状态为Planning only；原始基线和调研保持原样。当前[M5-A](../plans/2026-11-03-m5-a-build-identity-and-isolation.md) → [M5-B](../plans/2026-11-03-m5-b-smoke-and-artifact.md) → [M5-C](../plans/2026-11-03-m5-c-verification-and-acceptance.md)执行状态与checkbox已分别更新。C3/全M5源码审查、最终技术release和归档尚未完成，不把B3历史检查点或工具fixture当作最终通过。
