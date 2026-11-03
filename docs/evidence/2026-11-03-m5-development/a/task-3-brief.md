### Task 3: A3 — 构建身份、每 run 日志与关于菜单

**Files:** Create `App/BuildInfo.swift`、`Utilities/DiagnosticLogWriter.swift`、`Testing/M5BuildInfoSelfTests.swift`、`scripts/generate-build-info.swift`；Modify `Utilities/AppLogger.swift`、`App/{FlowTypeApp,StatusBarController}.swift`、`Testing/SelfTest.swift`。本任务不改写 build-app 的 bundle 布局。

**Interfaces:**

- `BuildMetadata: Codable, Equatable, Sendable`：schemaVersion(Int)=1、version/buildNumber/gitSHA/sourceTree/builtAt(String)、dirty(Bool)。version三段数字，buildNumber十进制，两个SHA40hex，builtAt UTC ISO8601。
- `BuildIdentity: Codable, Sendable`：origin(packaged/development/invalid)、metadata(BuildMetadata?)、failureCode(BuildInfoFailure?)；`BuildInfo.load(bundle: Bundle) -> BuildIdentity`，`BuildInfo.validate(json: Data, infoPlist: [String: Any]) -> BuildIdentity`。packaged必须与plist版本/build一致；无.app的开发运行明确development；坏app明确invalid，不能回退development。
- 元数据工具 CLI：`swift scripts/generate-build-info.swift --repo PATH --output EMPTY_DIRECTORY [--version X.Y.Z]`；生成 `FlowTypeBuild.json` 和含现有 bundle/用途声明的 `Info.plist`。默认VERSION=1.0.0；HEAD/count/HEAD:Sources/UTC，dirty或HEAD变化失败1，参数错64。不接受任意env覆盖SHA/time。`--self-test` 仅创建独立小git仓库测试，不改当前仓库或全局git配置。
- `AppLogger.configure(context: RuntimeContext, identity: BuildIdentity) throws`；`log(_:)`、`logFileURL`、`openLogInFinder()`兼容；新增同步 `flush()`。`DiagnosticLogWriter` 接收显式fileURL、role、runID、identity和可注入轮转阈值，提供 `log(_:)`/`flush()`；实际10MiB/3个轮转。启动header同步成功后才初始化shared；正常app终止与所有self-test退出均flush。
- 新 `--m5-buildinfo-only` → `M5BuildInfoSelfTests.run(_:)`。日志路径按spec；每行role/runID/UTC，自测[SelfTest]；关于菜单只展示同一identity，不查询git。

- [ ] **RED：** `testMetadataValidation` 覆盖坏JSON、缺字段、非40hex、非UTC、version/plist不一致、dirty以及开发运行；bad app不能伪装development。工具 fixture `testCleanGitIdentity` 覆盖版本注入字符/浅历史/脏树/含空格repo路径；浅历史拒绝生成release身份。`testIdentityAndConcurrentFlush` 用低阈值writer并发写与立即flush，检查每run首条header、末条sentinel、四文件上限、各行角色、不同run不串文件，队列内flush不死锁。
- [ ] **RED 验证：** 接 focused 后 `swift build` → `.build/debug/FlowType --self-test --m5-buildinfo-only`，先确认预期失败；`swift scripts/generate-build-info.swift --self-test` 先确认生成器负例失败。
- [ ] **GREEN：** 实现上述校验/工具/logger与菜单；日志无初始化前的生产路径默认值，启动失败不写旧production日志。保持现有自测汇总stdout，汇总前flush；本任务不把所有历史自由文本日志宣称为已全面脱敏，自动模式必须只运行合成输入。
- [ ] **验证：** 两个focused命令退出0；顺序构建/full self-test一次，stdout零失败、退出0、独立日志有header和末尾汇总。无普通app/GUI启动；菜单外观仍Pending。
- [ ] **提交：** scoped stage/diff check，提交 `feat: add build identity and role-scoped diagnostics`。

## 包级完成条件与交接

A1–A3审查通过、隔离全套有新证据、身份工具fixture通过即可标记A源码完成；不能标记M5或发布完成。B1消费 current/BuildIdentity/logger，B2消费RuntimePaths，B3消费生成器。执行时逐任务按保留的子智能体方式实现和审查；源码验收后才进入B，未开始的任务保持空checkbox。

自检：spec §3归A1/A2、§4归A3；五项Review Focus各有测试；无 Package.resolved 变更、无本轮构建。路径/role/身份类型与B/C共享，后续变更须同时修改本计划与消费者。
