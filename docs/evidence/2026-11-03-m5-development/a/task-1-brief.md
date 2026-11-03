### Task 1: A1 — 最早启动上下文与安全运行根

**Files:** Create上述 RuntimeEnvironment/RuntimePaths、M5RuntimeSelfTests；Modify `Sources/flowtype/App/FlowTypeApp.swift`、`Testing/SelfTest.swift`、`Utilities/AppLogger.swift`（先接隔离路径，身份header/flush留A3）。

**Interfaces:**

- `ProcessRole: String, Codable, Sendable` = app/selfTest/smokeTest；`RuntimeMode` = app/selfTest/smoke/artifact。
- `RuntimeContext: Sendable` 含 role、mode、runID(UUID)、paths(RuntimePaths)、defaultsSuiteName(String?)、selfTestFilter(String?)；普通 app 的 paths 无验证根。
- `RuntimeEnvironment.bootstrap(arguments: [String], temporaryDirectory: URL) throws -> RuntimeContext` 只成功一次；`current: RuntimeContext` 启动前访问显式失败，绝不懒建 app 上下文。启动上下文可跨 actor 安全读取。
- `RuntimePaths` 提供 validationRoot(URL?)、configDirectory、applicationSupportDirectory、cachesDirectory、logsDirectory、temporaryDirectory、modelsDirectory(URL)；`RuntimePaths.app(home: URL, applicationSupport: URL, caches: URL, temporaryDirectory: URL) -> RuntimePaths` 允许纯 fixture 比对旧路径，无需访问真实目录。
- `RuntimeEnvironment.defaults: UserDefaults` 用受保护的一次构造保持同一 suite；`finishValidation()` 只清本 run 的 suite。实例测试工厂不重置真正 current。
- 主选项互斥：`--self-test|--smoke-test|--artifact-check`；验证根选项 `--validation-root ABSOLUTE_PATH`。保留已存在的 self-test filters，新增 `--m5-runtime-only`，filter 仅与 self-test 配对；未知/重复/冲突 M5 参数 usage64。app 的 LaunchServices 参数须维持现有可启动行为，不能把系统 `-psn_…` 当用户验证选项。

- [ ] **RED：** 在 `M5RuntimeSelfTests.run(_ r: SelfTest.Reporter)` 添加 `testCanonicalTempAndExplicitSymlink`、`testRootOwnershipAndUsage`、`testAppPathCompatibility`：合成 temp 的可信别名可规范化；显式根/祖先 symlink、相对路径、home/Library及生产子目录、非空根均拒绝；普通 workspace/build 子目录可用；同根独占创建只一成功；失败不删除原文件。比较大小写和旧路径公式。用 fixture 目录与注入 home，不读取真实内容。
- [ ] **RED 验证：** 先接 focused 分支，`swift build` 因缺接口失败并保存编译错误；接口具备后先让上述行为断言失败。此前不运行旧完整 self-test（尚未接好全部隔离）。
- [ ] **GREEN：** 实现路径/参数/独占 marker；启动第一步解析，错误只写安全 stderr 并退出64/1。非 app 的 config/ApplicationSupport/Caches/Logs/Tmp 在根下；现有AppLogger的logDir/logPath先按当前role路由至隔离根，避免A2迁移测试日志仍写production。未实现的 smoke/artifact 暂以明确 unsupported 退出1，不落入普通 app。app 仍交给原 FlowTypeApp。
- [ ] **验证：** `swift build` 后运行 `.build/debug/FlowType --self-test --m5-runtime-only`，退出0；冲突/未知参数先用纯解析器及launch spy验证usage64，无 AppDelegate 调用。真实负例进程留B1有watchdog与全部副作用守卫后验证；不能为跑RED意外启动普通app。本任务 focused 只调用新测试，完整 runner 留给 A2。
- [ ] **提交：** 仅 stage 本任务文件，`git diff --cached --check`，提交 `feat: bootstrap isolated validation runtime`。

