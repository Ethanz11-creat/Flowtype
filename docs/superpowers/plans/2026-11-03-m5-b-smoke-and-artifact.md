# M5-B Startup Smoke and Portable Artifact Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 捕获真实启动异步回调故障，并验证app脱离开发目录后资源、Metal/MLX和完整签名仍有效。

**Architecture:** smoke构造受控的真实单例和计时器，不进入普通AppDelegate。artifact-check只检查身份、资源与无模型GPU微计算。外部独立进程watchdog捕获主线程卡死；打包在staging完成，签名通过才更新build候选。

**Tech Stack:** Swift6.2、AppKit、Foundation.Process/Darwin、Metal、既有MLX0.31.3、bash、codesign。

**Spec:** [M5设计 §5–6](../specs/2026-11-03-m5-release-guardrails-design.md)；前置：[M5-A](2026-11-03-m5-a-build-identity-and-isolation.md)完成并审查。

## Global Constraints

- Swift6.2+、macOS15+、Apple Silicon；不新增或升级外部依赖/Package.resolved，不运行Python、不下载ASR模型或自动安装shader/toolchain。
- 用户本轮仅要求计划；产品源码、现有构建产物与系统配置保持原状。不把规划写成已实施或验收通过。
- 后续开发使用合成数据、假服务/剪贴板/输入事件和独立运行目录；不读取真实配置/词典/DB/Keychain/模型缓存，不触发授权弹窗、录音、热键输入或外部ASR/LLM请求。
- 普通app仍使用原用户配置/目录/启动行为；验证模式必须在任何shared/logger/AppKit初始化前确定，初始化失败退出，禁止回退到生产路径。
- 保留M1–M4 readiness降级、captured route/lease、原音频重试、新20s预算、新实时句柄、单次交付、剪贴板与取消/回调所有权保护；不借M5改写这些合同。
- 构建/运行报告只含身份、阶段、闭合枚举/计数/状态；不输出密钥、请求正文、转写、用户文档、原始配置、URL/query或任意NSError.userInfo。自动上传仅显式白名单的合成验证产物。
- 验证按focused→顺序swift build/full self-test；不运行swift test或重复未变全套/声学benchmark。M4的23872/0仅作历史基线，不重复一次未变baseline。
- 保留分支和worktree，不push、不merge、不安装到/Applications、不替换正在运行的app。V1–V5/真实模型/声学校准/GUI未执行均Pending。

## Review Focus

1. 主线程卡死、SIGTRAP、子进程持有输出句柄：父runner按时失败并终止自己拥有的进程组；B1 `testTimeoutCrashAndDescendants`。
2. router非shared实例的timer偷偷调用shared，或健康tick只是伪计数：必须走实际实例和实际callback；B1 `testTimerOwnershipAndEvidence`。
3. 6s内用户点击菜单/敲热键触发录音或授权：所有非app生产动作入口守卫；B1 `testValidationActionGuards`。
4. 原checkout有资源时误通过：拷贝候选在开发bundle不可见时仍通过，缺文件必须失败；B2/B3 `testNoDeveloperResourceFallback`。
5. shader太小/不可加载、签名失败、构建中HEAD变化：失败不覆盖旧候选，不输出伪Pass；B3 `testStagingFailurePreservesCandidate`。

## 公共合同

消费A的 `RuntimeContext`、`RuntimeEnvironment.current`、`BuildIdentity`、`AppLogger.flush()`。新增 `ValidationFailureCode: String, Codable, Sendable`：startupFailed/timerDeadline/windowServerUnavailable/invalidBuildInfo/resourceMissing/resourceMalformed/resourceOutsideBundle/metalUnavailable/metalLibraryInvalid/mlxOperationFailed/unexpectedFailure；成功failureCode=null。

JSON共同字段：schemaVersion=1、mode(smoke/artifact)、ok(Bool)、role="smokeTest"、runID(UUID string)、buildInfo(BuildIdentity)、durationMs(Int)、failureCode；恰一行stdout，诊断写隔离日志。参数/根初始化错误在上下文形成前可只写安全stderr并exit64/1，不虚构runID。每次子进程根唯一。

### Task 1: B1 — 外部watchdog与真实timer启动smoke

**Files:** Create `Sources/flowtype/App/Validation/{ValidationReport,StartupSmoke}.swift`、`Testing/M5SmokeSelfTests.swift`、`scripts/verification/{BoundedProcess,ProcessCLI,ProcessRunnerSelfTests}.swift`；Modify `App/FlowTypeApp.swift`、`App/StatusBarController.swift`、`WindowManager.swift`、`Services/Speech/ASRRouter.swift`、`Testing/SelfTest.swift`。

**Interfaces:**

- `@MainActor StartupSmoke.run(context: RuntimeContext) async -> SmokeReport`；`SmokeReport: Codable, Sendable` 含共同字段及readiness(ready/degraded/blocked)、ax/mic/speech(granted/denied/notDetermined/unknown)、probeTimerTicks/windowHealthTicks(Int)、tap="disabledForValidation"。`exitCode`由report映射，成功0、失败1、明确无WindowServer69。
- Router新增线程安全只读 `probeTimerTicks: Int`，回调weak self/@Sendable，入真实callback才累加；首1s/周期30s不变。WindowManager新增 `private(set) var windowHealthTicks: Int`，在真正健康callback进入累加，周期5s不变。新增 `startValidationHealthCheck()` 只启动同一健康timer；非app install/repair/handle入口均禁止真实tap。清理重复启动/退出所有权。
- `BoundedCommand: Sendable` = executable(URL)、arguments([String])、workingDirectory(URL)、environment([String:String])、stdoutURL/stderrURL(URL)、timeoutSeconds(Double)。`BoundedResult: Codable, Sendable` = schemaVersion=1、exitCode(Int32?)、termination(normal/signal/launchFailure/timeout)、durationMs(Int)、timedOut(Bool)、failureCode(闭合枚举/null)。`BoundedProcess.run(_ command: BoundedCommand) throws -> BoundedResult` 在独立runner线程控制等待，不依赖被测actor。
- `ProcessCLI` CLI：`--timeout SECONDS --stdout FILE --stderr FILE --result FILE -- EXECUTABLE ARGS...`；不经shell拼接参数。返回child退出码、signal/launchFailure为1、timeout124、工具错误125、usage64。内部受控子模式先setpgid(0,0)，通过管道报告组就绪后exec目标；仅杀自己的组，TERM后2s KILL，不killall。启动握手失败清本次child并报告失败。stdin=/dev/null，文件输出不靠未排空pipe。
- `BoundedProcess.dispatchChildIfNeeded(arguments: [String]) throws` 在每个消费该runner的CLI入口首先调用：普通模式返回，受控子模式握手后exec成功不返回；失败抛错并退出。ProcessCLI、PackagingSelfTests以及C的VerificationCLI均实现同一内部子模式，避免“runner仅在某个主程序下可用”。
- `ProcessCLI --self-test`调用ProcessRunnerSelfTests，仅生成自己的短命fixture；新增FlowType focused `--m5-smoke-contract-only` → `M5SmokeSelfTests.run(_:)`。

- [ ] **RED：** `testTimeoutCrashAndDescendants` 启动fixture的主线程阻塞、signal退出、子孙忽略TERM、超长stdout，断言timeout=true/退出非0、子孙已终止、另一个独立fixture仍存活、输出完整，无无限wait。`testTimerOwnershipAndEvidence` 注入两个router，触发一个真实定时源，只有该实例计数/refresh增加；纯等待而callback未执行不能通过；重复start只一timer。focused可用短注入间隔，正式smoke仍1s/5s。
- [ ] **RED：** `testValidationActionGuards` 用spies覆盖tap安装/repair、热键处理、菜单录音/修复/授权及正常app门控分支。非app均无实际副作用；不能只关闭button而漏掉selector直接调用。`testSmokeReport`覆盖缺引擎/无权限仍可ok、缺任一tick必Fail、已判定无WindowServer才69，普通异常不得Skip。
- [ ] **RED 验证：** 接focused后 `swift build` → `.build/debug/FlowType --self-test --m5-smoke-contract-only`，先观察断言失败。编译 `swiftc -parse-as-library scripts/verification/BoundedProcess.swift scripts/verification/ProcessCLI.swift scripts/verification/ProcessRunnerSelfTests.swift -o build/m5-process`，运行 `build/m5-process --self-test`，先确认超时/归属负例失败。
- [ ] **GREEN：** 实现watchdog、报告和smoke。按spec顺序创建NSApplication accessory、配置/session/router/隐藏panel/statusbar/readiness；不进入AppDelegate。状态栏保持真实setup但禁全部可启动录音/授权/配置修改动作；6s最小观察，缺tick等至10s失败，Task.sleep不阻塞MainActor。禁外网probe、模型、引导及录音，退出flush并清理自身对象。
- [ ] **验证：** 两个focused退出0；顺序build/full self-test一次。通过runner分别验证重复主模式/未知M5选项/非法root参数的usage64；只在全部非app守卫已接好后运行，不给任何负例机会落入普通app。再用 `build/m5-process` 以15s timeout启动 `.build/debug/FlowType --smoke-test` 一次，核查stdout恰一JSON、durationMs≥6000、两tick≥1、tap禁用、development身份可见。未具备WindowServer明确记录Skip，不伪造Pass；最终十次留给C。不运行普通app。
- [ ] **提交：** scoped stage/diff check，提交 `feat: add bounded startup smoke with real timer evidence`。

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

### Task 3: B3 — 可迁移bundle、staging签名与独立路径验证

**Files:** Modify `scripts/{build-app,build-dmg}.sh`；Create `scripts/check-app.sh`、`scripts/write-artifact-manifest.swift`、`scripts/verification/ArtifactPackagingSelfTests.swift`。消费A3生成器、B1 runner、B2 artifact入口；不动依赖checkout。

**Interfaces:**

- `scripts/build-app.sh`无参，VERSION可选三段数字；`MLX_METALLIB_PATH`只接受已存在本地文件（优先显式，其次旧shader-cache只读候选）；没有shader/不合法/脏树/浅历史退出1。HEAD变动再次拒绝。用 `swift build -c release --show-bin-path` 定位实际产物（该查询不代替release build）。
- 私有staging只复制当前release可执行文件及所有实际 `.bundle` 到Contents/Resources；新增MLX标准bundle含 `default.metallib` 和合法Info.plist，替代MacOS/mlx.metallib。生成 `Contents/Resources/FlowTypeBuild.json`、外置 `build/FlowType.manifest.json`。shader阈值为1MiB=1048576字节；Manifest schemaVersion=1含BuildMetadata、architecture="arm64"、binarySHA256/buildInfoSHA256/shaderSHA256和相对资源路径/hash清单，不泄露shader来源用户绝对路径。
- manifest JSON固定键为schemaVersion、buildInfo(磁盘BuildMetadata结构)、architecture、binarySHA256、buildInfoSHA256、shaderSHA256、resources(含path/sha256的数组)。`swift scripts/write-artifact-manifest.swift --app APP --output FILE`在最终签名之后计算真实hash并写外置manifest，不能在codesign修改Mach-O之前取hash；该工具自身fixture并入PackagingSelfTests。C以自己的Codable结构读取相同schema，不import产品主程序。
- 只签真正code，最后签app并 `codesign --verify --deep --strict --verbose=2`；禁ignore-resources/xattr清理绕过。签名失败不替换旧build/FlowType.app。签名成功只代表候选构造成功，MLX运行是否通过另看check-app；最终更新与manifest一致，失败不得遗留看似同身份的新旧混合对。
- app与外置manifest更新采用同一写者锁、旧候选备份和更新journal；正常失败回滚，异常中断后下次构建先恢复或明确失败，校验器发现不匹配立即Fail。两次rename不能声称是一个原子操作。
- `scripts/check-app.sh --app ABSOLUTE_APP --output EMPTY_DIRECTORY`：复制候选到checkout外临时根，无关cwd、无shader定位env，记录拷贝前后binary/metadata/shader hash并验strict/deep；隐藏本worktree实际release `.bundle`，内层runner30s执行拷贝的artifact-check，再恢复。返回0需artifact三项和resolvedInsideApp全true且身份/hash匹配；其他1、参数64。报告保存在output，测试app根与日志根分开。
- 资源隐藏有独占锁/恢复marker，恢复者在内层watchdog之外；trap覆盖正常/TERM/INT退出，SIGKILL/断电后的下一次调用先按marker核实原路径并恢复或明确失败，绝不覆盖未知目录。不得隐藏其他worktree/依赖cache，也不得因并发构建误搬资源。
- build-dmg只改为读取候选plist版本及匹配身份，移除暗示自动发布的提示；本任务不执行DMG创建。

- [ ] **RED：** PackagingSelfTests用合成git仓库/小fixture工具运行真实脚本控制流，以显式注入的测试依赖替代swift/codesign（入口只存在测试driver，不接受release绕过变量）。`testStagingFailurePreservesCandidate` 覆盖缺/截断shader、build/sign失败、HEAD变化、空格路径；旧候选/hash保持。`testRestoreOnArtifactFailure`覆盖artifact失败/超时和恢复marker残留，确保只恢复自有文件。验证manifest对真实复制后的hash，不能仅断言文件存在。
- [ ] **RED 验证：** 编译独立 `ArtifactPackagingSelfTests.swift`（自身@main，仅Foundation/Process，复用BoundedProcess）到 `build/m5-packaging-tests`；先运行看到负例失败。`bash -n scripts/build-app.sh scripts/build-dmg.sh scripts/check-app.sh`验证语法。
- [ ] **GREEN：** 实现staging/标准资源封装/manifest/移位检查和安全恢复；任何shader定位都不调用Python/安装/下载。如果所选MLX布局实际加载失败，保留Fail并定位，不篡改依赖或降级门禁。
- [ ] **验证：** fixture与语法通过，提交全部源码/脚本使checkout clean后，再运行一次真实build-app→check-app（runner watchdog分别900s/30s）。严格签名、移位资源、真实GPU微计算全有证据才artifact Pass；无法取得已有shader则该项Pending/Fail，不安装补齐。签名完成后不改bundle任何资源。此任务源码若仅shell改动不重复未变full；若改了B2源码，先focused再full。
- [ ] **提交与证据：** scoped stage/diff check，提交 `build: package portable resources with strict signing`；真实门禁证据在独立后续docs提交归档，报告准确记录被测源码commit和binary hash。不运行现有正在使用的正常app。

## 包级完成条件与交接

源码完成与artifact通过分列；完整签名/真实MLX未通过时不得称产物已修复。C消费上述report/runner/manifest/check-app CLI，负责一次最终十次smoke及完整验收聚合。M4旧app不被重新解释为通过；新候选即使技术门禁通过，也不能继承真实模型/GUI/V1–V5的旧身份结果。

自检：§5.1归B1、§5.2归B2、§6归B3；五项Review Focus有归属。Metal直接加载与MLX运行分别有结果；无新ASR依赖/模型/发布。所有本计划checkbox当前未执行。
