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

