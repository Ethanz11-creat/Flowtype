### Task 2: B2 — 独立资源入口和无模型artifact-check

**Files:** Create `App/AppResources.swift`、`App/Validation/RuntimeArtifactCheck.swift`、`Testing/M5ArtifactSelfTests.swift`；Modify `App/{FlowTypeApp,StatusBarController}.swift`、`Services/Speech/ASRPostProcessor.swift`、`Testing/SelfTest.swift`、`Package.swift`（仅显式引用已有MLX）。

**Interfaces:**

- `AppResources.bundle(in application: Bundle) throws -> Bundle`：.app只找 `Contents/Resources/FlowType_FlowType.bundle`，校验规范化URL仍在app内；开发可Bundle.module。`AppResources.url(forResource name: String, withExtension ext: String) -> URL?` 为现有图标/词库共同入口。
- `@MainActor RuntimeArtifactCheck.run(context: RuntimeContext) async -> ArtifactReport`；`ArtifactReport: Codable, Sendable` 含共同字段及appResources/metalLibrary/mlxOperation/resolvedInsideApp(Bool)。身份必须packaged且dirty=false，不建UI/路由timer，不加载模型。
- 内部 `ArtifactCheckDependencies` 注入资源解析、Metal库加载、MLX微运算三个闭包供合成负例；live闭包读取app内两JSON/图标，Metal用实际 `makeLibrary(URL:)`，MLX显式GPU计算 `[1,2]+1`、eval并取回 `[2,3]`，不可CPU回退或只加载Metal却跳过MLX。
- 新focused `--m5-artifact-contract-only` → `M5ArtifactSelfTests.run(_:)`。新增package声明仅允许既有 mlx-swift exact0.31.3/revision61b9e011e09a62b489f6bd647958f1555bdf2896及MLX product；Package.resolved必须无diff。

- [ ] **RED：** `testNoDeveloperResourceFallback` 在合成.app中移除词库，即使开发Bundle.module可用也必须resourceMissing；symlink逃出app必resourceOutsideBundle；坏JSON/空词库/缺图标分别失败。`testArtifactStageTruth` 注入Metal通过/MLX失败、无GPU、错误结果和invalid身份，断言对应failureCode且ok=false；未运行步骤不报true，依赖闭包不触发模型工作。
- [ ] **RED 验证：** `swift build` → `.build/debug/FlowType --self-test --m5-artifact-contract-only`，先确认上述失败，不调用真实GPU作为单元fixture。
- [ ] **GREEN：** 接共同AppResources及artifact入口，报告无绝对用户路径；实际Metal/MLX调用只存在于artifact live路径，不被code lane full自测执行。显式GPU微计算不能因默认设备选择而悄悄用CPU通过。
- [ ] **验证：** focused通过后顺序build/full一次，确认Package.resolved无改动。真实打包/MLX默认搜索验证留B3，不把fixture成功当真实GPU通过。
- [ ] **提交：** scoped stage/diff check，提交 `feat: validate bundled resources and MLX artifact runtime`。

