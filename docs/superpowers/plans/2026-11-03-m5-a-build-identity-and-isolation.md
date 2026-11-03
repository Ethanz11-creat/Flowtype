# M5-A Build Identity and Validation Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在任何共享对象构造前确定进程角色，使自动验证隔离于用户数据，并让日志、关于菜单与后续报告携带同一构建身份。

**Architecture:** 不重构业务流水线；新增不可变启动上下文和集中路径，接入现有全局边界。磁盘 BuildMetadata 与运行时 BuildIdentity 分离；构建时写入，运行时只读取。此包不实现 smoke/artifact 入口主体，B 消费它的接口。

**Tech Stack:** Swift 6.2、Foundation、AppKit、Security、现有内置 SelfTest；无 XCTest。

**Spec:** [M5 设计 §2–4](../specs/2026-11-03-m5-release-guardrails-design.md)。基线 `b00b0a5`，Sources `5dc1693`；M4 的23872/0仅为历史证据。

## 执行状态（2026-11-03更新）

A1–A3实现与任务审查通过，提交aea7dc9 / ffd4ba4 / d6aaace；以下步骤按已完成源码任务勾选。原规划基线与历史命令保持记录，当前执行索引见[开发证据](../../evidence/2026-11-03-m5-development/README.md)。A完成不等于M5发布或GUI通过。

最终更新：全M5源码审查已通过4cdfaf4；唯一最终release运行的24个技术阶段、full24334/0及十次smoke均Pass。A原始安全证据已由controller staging归档，原日志保持不变。最终候选为1.0.0/build353；整体仍因41项人工及远端CI Pending而exit2，关于菜单GUI仍Pending。

## Global Constraints

- Swift6.2+、macOS15+、Apple Silicon；不新增或升级外部依赖/Package.resolved，不运行Python、不下载ASR模型或自动安装shader/toolchain。
- 历史规划轮仅要求计划；其基线与原约束保留。后续已授权逐任务实施，当前状态见本页执行记录；未执行的真实验收仍Pending。
- 后续开发使用合成数据、假服务/剪贴板/输入事件和独立运行目录；不读取真实配置/词典/DB/Keychain/模型缓存，不触发授权弹窗、录音、热键输入或外部ASR/LLM请求。
- 普通app仍使用原用户配置/目录/启动行为；验证模式必须在任何shared/logger/AppKit初始化前确定，初始化失败退出，禁止回退到生产路径。
- 保留M1–M4 readiness降级、captured route/lease、原音频重试、新20s预算、新实时句柄、单次交付、剪贴板与取消/回调所有权保护；不借M5改写这些合同。
- 构建/运行报告只含身份、阶段、闭合枚举/计数/状态；不输出密钥、请求正文、转写、用户文档、原始配置、URL/query或任意NSError.userInfo。自动上传仅显式白名单的合成验证产物。
- 验证按focused→顺序swift build/full self-test；不运行swift test或重复未变全套/声学benchmark。M4的23872/0仅作历史基线，不重复一次未变baseline。
- 保留分支和worktree，不push、不merge、不安装到/Applications、不替换正在运行的app。V1–V5/真实模型/声学校准/GUI未执行均Pending。

## Review Focus

1. macOS temp 的 /var 别名与用户显式 symlink 不同：默认根可用，显式链接拒绝；A1 `testCanonicalTempAndExplicitSymlink`。
2. 两进程争用同一空根、只读目录或非法参数：一个获独占，其余退出且没有 GUI/生产回退；A1 `testRootOwnershipAndUsage`。
3. legacy 配置迁移/损坏备份会触及 Keychain、默认日志与原 JSON：全部只触及合成存储；A2 `testLegacyMigrationBoundaries`。
4. 隐式 shared.prepare、模型 cache 和音频恢复 sentinel 绕过路径隔离：零实际模型/设备/授权操作；A2 `testSingletonSideEffectBudget`。
5. 坏元数据、并发日志、轮转/立即退出：身份不伪装，首条 header 与最后一条均可找到，flush 不自锁；A3 `testIdentityAndConcurrentFlush`。

## 文件职责

新增 `Sources/flowtype/App/{RuntimeEnvironment,RuntimePaths,BuildInfo}.swift`；路径/身份各自只负责一件事。新增 `Utilities/DiagnosticLogWriter.swift` 承载可注入文件与轮转测试，保留 AppLogger facade。新增 `Testing/M5{Runtime,Isolation,BuildInfo}SelfTests.swift`；接入现有 `Testing/SelfTest.swift`。构建元数据工具独立为 `scripts/generate-build-info.swift`，B3 才接入打包脚本。

### Task 1: A1 — 最早启动上下文与安全运行根

**Files:** Create上述 RuntimeEnvironment/RuntimePaths、M5RuntimeSelfTests；Modify `Sources/flowtype/App/FlowTypeApp.swift`、`Testing/SelfTest.swift`、`Utilities/AppLogger.swift`（先接隔离路径，身份header/flush留A3）。

**Interfaces:**

- `ProcessRole: String, Codable, Sendable` = app/selfTest/smokeTest；`RuntimeMode` = app/selfTest/smoke/artifact。
- `RuntimeContext: Sendable` 含 role、mode、runID(UUID)、paths(RuntimePaths)、defaultsSuiteName(String?)、selfTestFilter(String?)；普通 app 的 paths 无验证根。
- `RuntimeEnvironment.bootstrap(arguments: [String], temporaryDirectory: URL) throws -> RuntimeContext` 只成功一次；`current: RuntimeContext` 启动前访问显式失败，绝不懒建 app 上下文。启动上下文可跨 actor 安全读取。
- `RuntimePaths` 提供 validationRoot(URL?)、configDirectory、applicationSupportDirectory、cachesDirectory、logsDirectory、temporaryDirectory、modelsDirectory(URL)；`RuntimePaths.app(home: URL, applicationSupport: URL, caches: URL, temporaryDirectory: URL) -> RuntimePaths` 允许纯 fixture 比对旧路径，无需访问真实目录。
- `RuntimeEnvironment.defaults: UserDefaults` 用受保护的一次构造保持同一 suite；`finishValidation()` 只清本 run 的 suite。实例测试工厂不重置真正 current。
- 主选项互斥：`--self-test|--smoke-test|--artifact-check`；验证根选项 `--validation-root ABSOLUTE_PATH`。保留已存在的 self-test filters，新增 `--m5-runtime-only`，filter 仅与 self-test 配对；未知/重复/冲突 M5 参数 usage64。app 的 LaunchServices 参数须维持现有可启动行为，不能把系统 `-psn_…` 当用户验证选项。

- [x] **RED：** 在 `M5RuntimeSelfTests.run(_ r: SelfTest.Reporter)` 添加 `testCanonicalTempAndExplicitSymlink`、`testRootOwnershipAndUsage`、`testAppPathCompatibility`：合成 temp 的可信别名可规范化；显式根/祖先 symlink、相对路径、home/Library及生产子目录、非空根均拒绝；普通 workspace/build 子目录可用；同根独占创建只一成功；失败不删除原文件。比较大小写和旧路径公式。用 fixture 目录与注入 home，不读取真实内容。
- [x] **RED 验证：** 先接 focused 分支，`swift build` 因缺接口失败并保存编译错误；接口具备后先让上述行为断言失败。此前不运行旧完整 self-test（尚未接好全部隔离）。
- [x] **GREEN：** 实现路径/参数/独占 marker；启动第一步解析，错误只写安全 stderr 并退出64/1。非 app 的 config/ApplicationSupport/Caches/Logs/Tmp 在根下；现有AppLogger的logDir/logPath先按当前role路由至隔离根，避免A2迁移测试日志仍写production。未实现的 smoke/artifact 暂以明确 unsupported 退出1，不落入普通 app。app 仍交给原 FlowTypeApp。
- [x] **验证：** `swift build` 后运行 `.build/debug/FlowType --self-test --m5-runtime-only`，退出0；冲突/未知参数先用纯解析器及launch spy验证usage64，无 AppDelegate 调用。真实负例进程留B1有watchdog与全部副作用守卫后验证；不能为跑RED意外启动普通app。本任务 focused 只调用新测试，完整 runner 留给 A2。
- [x] **提交：** 仅 stage 本任务文件，`git diff --cached --check`，提交 `feat: bootstrap isolated validation runtime`。

### Task 2: A2 — 接通所有自动验证可达的持久化与副作用边界

**Files:** Modify `Core/{ConfigurationStore,Persistence,EnvMigration,PipelineOrchestrator}.swift`、`Core/Database/AppDatabase.swift`、`Services/{AudioRecorder,KeyboardInjector}.swift`、`Utilities/{KeychainHelper,PermissionHelper}.swift`、`Services/Speech/{QwenModelState,ModelLocator,ASRRouter}.swift`、`Services/Speech/LocalModelManager/{ModelPreset,LocalModelLibrary}.swift`、`App/StatusBarController.swift`、`Testing/SelfTest.swift`及确实仍访问真实状态的既有 `Testing/*.swift`；Create `Testing/M5IsolationSelfTests.swift`。以 `rg` 的调用链确认清单，不借机整理其他代码。

**Interfaces:** 消费 A1 的 current/paths/defaults；`KeychainHelper.save(key:value:) -> Bool`、`load(key:) -> String?`、`delete(key:)` 保持签名，非 app 路由至锁保护的内存实现。`ConfigurationStore.shared` 显式传当前 defaults/backupDirectory，普通注入 init 保留。`SessionEffects.live.prepare` 在非 app 禁自动模型工作；smoke 的真实 probe 启动留给 B1。新增 `--m5-isolation-only` 对应 `M5IsolationSelfTests.run(_:)`。

- [x] **RED：** 先在显式fixture依赖的实例上写 `testLegacyMigrationBoundaries`：旧版含合成 key 的配置及损坏字节迁移、备份、JSON→SQLite rename，fake Keychain内容正确、SecItem边界调用数0、所有改动位于fixture/run根，真实存储spy为0。RED阶段所有OS/网络边界先换deny/spy，未接通隔离前禁止构造会读取真实数据的shared；缺路径注入可先以编译失败证明缺口。`testSingletonSideEffectBudget`的实际shared集成断言在GREEN接完边界后才启用：排空任务队列，网络请求、模型扫描/下载/加载、音频设备改动、授权请求、剪贴板与输入事件均0。不以“没有观察到日志”代替spy。
- [x] **RED 验证：** `swift build` → `.build/debug/FlowType --self-test --m5-isolation-only`；应因未接通的生产路径/副作用断言失败。spy 与 fixture 从测试创建，不读取真实环境作为 baseline。
- [x] **GREEN：** shared 使用 RuntimePaths/defaults，EnvMigration 非 app 在读 .env/环境前返回，Keychain 先分流后构造 SecItem query。ModelLocator 非 app 不枚举用户 cache/HF refs；测试需显式合成参数。禁止自动模型 prepare、设备 sentinel 恢复和权限引导；路由 self-test 不启真实监控。将任何旧测试对系统剪贴板/热键/模型缓存的依赖换注入，不能删掉对应语义断言。普通 app 的路径与准备动作保持。
- [x] **验证：** focused退出0后，顺序 `swift build` → `.build/debug/FlowType --self-test`，完整报告0 failed；检查本 run 的数据库/备份证据。最终硬件副作用由注入计数证明，不运行普通 app 去试权限。新增后完整自测数应实际记录，不写死23872。
- [x] **提交：** scoped stage/`git diff --cached --check`，提交 `fix: isolate self-test persistence and startup effects`。

### Task 3: A3 — 构建身份、每 run 日志与关于菜单

**Files:** Create `App/BuildInfo.swift`、`Utilities/DiagnosticLogWriter.swift`、`Testing/M5BuildInfoSelfTests.swift`、`scripts/generate-build-info.swift`；Modify `Utilities/AppLogger.swift`、`App/{FlowTypeApp,StatusBarController}.swift`、`Testing/SelfTest.swift`。本任务不改写 build-app 的 bundle 布局。

**Interfaces:**

- `BuildMetadata: Codable, Equatable, Sendable`：schemaVersion(Int)=1、version/buildNumber/gitSHA/sourceTree/builtAt(String)、dirty(Bool)。version三段数字，buildNumber十进制，两个SHA40hex，builtAt UTC ISO8601。
- `BuildIdentity: Codable, Sendable`：origin(packaged/development/invalid)、metadata(BuildMetadata?)、failureCode(BuildInfoFailure?)；`BuildInfo.load(bundle: Bundle) -> BuildIdentity`，`BuildInfo.validate(json: Data, infoPlist: [String: Any]) -> BuildIdentity`。packaged必须与plist版本/build一致；无.app的开发运行明确development；坏app明确invalid，不能回退development。
- 元数据工具 CLI：`swift scripts/generate-build-info.swift --repo PATH --output EMPTY_DIRECTORY [--version X.Y.Z]`；生成 `FlowTypeBuild.json` 和含现有 bundle/用途声明的 `Info.plist`。默认VERSION=1.0.0；HEAD/count/HEAD:Sources/UTC，dirty或HEAD变化失败1，参数错64。不接受任意env覆盖SHA/time。`--self-test` 仅创建独立小git仓库测试，不改当前仓库或全局git配置。
- `AppLogger.configure(context: RuntimeContext, identity: BuildIdentity) throws`；`log(_:)`、`logFileURL`、`openLogInFinder()`兼容；新增同步 `flush()`。`DiagnosticLogWriter` 接收显式fileURL、role、runID、identity和可注入轮转阈值，提供 `log(_:)`/`flush()`；实际10MiB/3个轮转。启动header同步成功后才初始化shared；正常app终止与所有self-test退出均flush。
- 新 `--m5-buildinfo-only` → `M5BuildInfoSelfTests.run(_:)`。日志路径按spec；每行role/runID/UTC，自测[SelfTest]；关于菜单只展示同一identity，不查询git。

- [x] **RED：** `testMetadataValidation` 覆盖坏JSON、缺字段、非40hex、非UTC、version/plist不一致、dirty以及开发运行；bad app不能伪装development。工具 fixture `testCleanGitIdentity` 覆盖版本注入字符/浅历史/脏树/含空格repo路径；浅历史拒绝生成release身份。`testIdentityAndConcurrentFlush` 用低阈值writer并发写与立即flush，检查每run首条header、末条sentinel、四文件上限、各行角色、不同run不串文件，队列内flush不死锁。
- [x] **RED 验证：** 接 focused 后 `swift build` → `.build/debug/FlowType --self-test --m5-buildinfo-only`，先确认预期失败；`swift scripts/generate-build-info.swift --self-test` 先确认生成器负例失败。
- [x] **GREEN：** 实现上述校验/工具/logger与菜单；日志无初始化前的生产路径默认值，启动失败不写旧production日志。保持现有自测汇总stdout，汇总前flush；本任务不把所有历史自由文本日志宣称为已全面脱敏，自动模式必须只运行合成输入。
- [x] **验证：** 两个focused命令退出0；顺序构建/full self-test一次，stdout零失败、退出0、独立日志有header和末尾汇总。无普通app/GUI启动；菜单外观仍Pending。
- [x] **提交：** scoped stage/diff check，提交 `feat: add build identity and role-scoped diagnostics`。

## 包级完成条件与交接

A1–A3审查通过、隔离全套有新证据、身份工具fixture通过即可标记A源码完成；不能标记M5或发布完成。B1消费 current/BuildIdentity/logger，B2消费RuntimePaths，B3消费生成器。执行时逐任务按保留的子智能体方式实现和审查；源码验收后才进入B，未开始的任务保持空checkbox。

自检：spec §3归A1/A2、§4归A3；五项Review Focus各有测试；无 Package.resolved 变更、无本轮构建。路径/role/身份类型与B/C共享，后续变更须同时修改本计划与消费者。
