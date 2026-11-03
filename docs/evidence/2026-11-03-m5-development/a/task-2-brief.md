### Task 2: A2 — 接通所有自动验证可达的持久化与副作用边界

**Files:** Modify `Core/{ConfigurationStore,Persistence,EnvMigration,PipelineOrchestrator}.swift`、`Core/Database/AppDatabase.swift`、`Services/{AudioRecorder,KeyboardInjector}.swift`、`Utilities/{KeychainHelper,PermissionHelper}.swift`、`Services/Speech/{QwenModelState,ModelLocator,ASRRouter}.swift`、`Services/Speech/LocalModelManager/{ModelPreset,LocalModelLibrary}.swift`、`App/StatusBarController.swift`、`Testing/SelfTest.swift`及确实仍访问真实状态的既有 `Testing/*.swift`；Create `Testing/M5IsolationSelfTests.swift`。以 `rg` 的调用链确认清单，不借机整理其他代码。

**Interfaces:** 消费 A1 的 current/paths/defaults；`KeychainHelper.save(key:value:) -> Bool`、`load(key:) -> String?`、`delete(key:)` 保持签名，非 app 路由至锁保护的内存实现。`ConfigurationStore.shared` 显式传当前 defaults/backupDirectory，普通注入 init 保留。`SessionEffects.live.prepare` 在非 app 禁自动模型工作；smoke 的真实 probe 启动留给 B1。新增 `--m5-isolation-only` 对应 `M5IsolationSelfTests.run(_:)`。

- [ ] **RED：** 先在显式fixture依赖的实例上写 `testLegacyMigrationBoundaries`：旧版含合成 key 的配置及损坏字节迁移、备份、JSON→SQLite rename，fake Keychain内容正确、SecItem边界调用数0、所有改动位于fixture/run根，真实存储spy为0。RED阶段所有OS/网络边界先换deny/spy，未接通隔离前禁止构造会读取真实数据的shared；缺路径注入可先以编译失败证明缺口。`testSingletonSideEffectBudget`的实际shared集成断言在GREEN接完边界后才启用：排空任务队列，网络请求、模型扫描/下载/加载、音频设备改动、授权请求、剪贴板与输入事件均0。不以“没有观察到日志”代替spy。
- [ ] **RED 验证：** `swift build` → `.build/debug/FlowType --self-test --m5-isolation-only`；应因未接通的生产路径/副作用断言失败。spy 与 fixture 从测试创建，不读取真实环境作为 baseline。
- [ ] **GREEN：** shared 使用 RuntimePaths/defaults，EnvMigration 非 app 在读 .env/环境前返回，Keychain 先分流后构造 SecItem query。ModelLocator 非 app 不枚举用户 cache/HF refs；测试需显式合成参数。禁止自动模型 prepare、设备 sentinel 恢复和权限引导；路由 self-test 不启真实监控。将任何旧测试对系统剪贴板/热键/模型缓存的依赖换注入，不能删掉对应语义断言。普通 app 的路径与准备动作保持。
- [ ] **验证：** focused退出0后，顺序 `swift build` → `.build/debug/FlowType --self-test`，完整报告0 failed；检查本 run 的数据库/备份证据。最终硬件副作用由注入计数证明，不运行普通 app 去试权限。新增后完整自测数应实际记录，不写死23872。
- [ ] **提交：** scoped stage/`git diff --cached --check`，提交 `fix: isolate self-test persistence and startup effects`。

