### Task 1: C1 — 本地双门禁编排与可复核报告

**Files:** Create `scripts/verify.sh`及上述VerificationCLI/Report/SelfTests；消费B1 runner、B3 build-app/check-app/manifest。不改现有业务流水线。

**Interfaces:**

- CLI `scripts/verify.sh [--lane code|artifact|release] [--manual-report FILE] [--ci-report FILE]`，默认code；重复/未知参数64。输出 `build/verification/<parent UUID>/verify-report.json`，每child分配新的根；CLI不接收伪造runID/skip检查参数。stdout仅安全摘要/报告相对路径，原始child stdout/stderr各归档。
- shell从自己的绝对位置定位repo，`swiftc -parse-as-library scripts/verification/BoundedProcess.swift scripts/verification/VerificationReport.swift scripts/verification/ManualValidation.swift scripts/verification/VerificationSelfTests.swift scripts/verification/VerificationCLI.swift -o build/tools/flowtype-verify` 后执行。C1先提供ManualValidation的Pending stub，C3完成；主入口首先调用B的 `dispatchChildIfNeeded(arguments:)`。
- `VerificationRunner.run(lane: VerificationLane, repository: URL, output: URL, manualReport: URL?, ciReport: URL?) throws -> VerificationReport`；所有外部命令通过BoundedProcess，用argv不用shell拼接。构建工具失败仍由shell写最小安全bootstrap-failure报告/stderr并非0，不伪造完整Swift报告。
- code：macOS≥15/arm64/Swift≥6.2检查→`swift build`→`.build/debug/FlowType --self-test --validation-root NEW_ROOT`。build/full各900s；要求full exit0且原完整汇总唯一、passed>0、failed=0，不接收focused汇总。默认code不要求clean/shader/GPU，但记录dirty与源码身份，CI code要求checkout clean且无HEAD变化。
- artifact：clean/非浅历史→`scripts/build-app.sh`(900s)→strict/deep(30s)→`scripts/check-app.sh`(120s，内部artifact30s)→同一固定候选10次smoke，每次15s、观察≥6s、实际两tick≥1、tap禁用、packaged身份/hash一致。不会启动正常app。check-app有恢复marker时先恢复再继续；外层超时后也按本次marker核实恢复，冲突即Fail，不能遗留隐藏bundle却总绿。
- release：执行code与artifact各一次，调用C3人工/CI检查。独立可执行阶段继续收集证据；有依赖的后续阶段明确Pending/未执行，不因坏候选继续运行。Fail优先于Pending/Skip；全部required Pass才exit0，Fail1，仅Pending/Skip2，usage64。artifact lane的WindowServer Skip不可总Pass（返回2）。

- [ ] **RED：** `VerificationSelfTests.run()`用独立fixture可执行文件/临时repo和注入命令映射，不执行真实业务/网络。`testExitZeroCannotForgeArtifactPass`覆盖多行JSON、缺字段、mode/role错、重复runID、旧SHA/hash、5.9s、任一tick0、tap不禁用、artifact Metal真而MLX假；均Fail。`testFullRunnerRequired`禁止focused冒充full，0 passed/failed非0/缺汇总均失败。
- [ ] **RED：** `testPartialReportAndSkipAggregation`覆盖首build失败、full超时、签名失败、smoke69、10次第7次崩溃、parent输出写失败；必须记录已完成阶段、依赖未执行、准确exit/timeout、无总绿。参数含空格/Unicode按argv原样传递；不经shell执行内容。
- [ ] **RED 验证：** 实现测试入口 `build/tools/flowtype-verify --self-test`；先编译工具并运行，预期上述负例失败。`--self-test`是工具自身fixture模式，不是产品新增flag；不可通过该模式生成正式release报告。
- [ ] **GREEN：** 实现编排/报告、单写者锁和source identity稳定检查。C1人工/CI报告都暂返回Pending，不接受文件存在就Pass。code lane不调用build-app，artifact lane不重复full；release不能通过两个子lane递归再次构建同阶段。
- [ ] **验证：** 工具fixture与`bash -n scripts/verify.sh`通过。执行一次真实 `scripts/verify.sh --lane code`（其内部就是build→full，不再外围重复）；核对当前run独立日志与报告。最终十次artifact执行留C3 clean候选，fixture不能填成10次真实Pass。
- [ ] **提交：** scoped stage/diff check，提交 `build: add bounded code and artifact verification lanes`。

