# M5-C Verification, CI and Manual Acceptance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 提供一条本地可复现的验证入口和CI代码门禁，让尚未完成的真实环境验收始终显式阻止“发布完成”。

**Architecture:** shell只负责编译/启动Swift验证工具，Swift按code/artifact/release顺序编排B的受控进程并校验报告。源代码、候选二进制、人工观察、远端CI分别保留身份与状态；最终聚合不把Pending或Skip转为Pass。

**Tech Stack:** Swift6.2、Foundation/Darwin、bash、GitHub Actions、JSON、现有SelfTest与B的BoundedProcess。

**Spec:** [M5设计 §7–8](../specs/2026-11-03-m5-release-guardrails-design.md)；前置：[M5-A](2026-11-03-m5-a-build-identity-and-isolation.md) → [M5-B](2026-11-03-m5-b-smoke-and-artifact.md)。

## 执行状态（2026-11-03更新）

C1 653ecb8 / C2 66f1e78实现与独立任务审查通过；C3源码/文档/合成fixture本次提交后待审。以下C3源码步骤已执行，最终release、全M5独立审查及大型证据归档仍留空；远端CI和41个人工叶子全Pending。API的预期路径/source分离为controller已记录的内部合同澄清，避免由报告自证身份。

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

1. 子程序exit0却给坏/多行JSON、缺tick或旧身份：门禁失败；C1 `testExitZeroCannotForgeArtifactPass`。
2. 某阶段超时/Skip导致脚本提前退出且丢失证据或被总绿覆盖：部分报告必须保留；C1 `testPartialReportAndSkipAggregation`。
3. CI无arm64/正确Swift/shader/WindowServer：显式检查，默认code不偷偷执行artifact；C2 `testCICapabilityAndUploadContract`。
4. CI上传通配符把defaults/DB/生产日志带出：只列允许文件，路径/链接逃逸拒绝；C2 `testEvidenceAllowlist`。
5. 手工只勾父项、旧binary证据、缺子项/观察、伪CI记录：不能release Pass；C3 `testManualIdentityAndRequiredCases`。

## 文件职责与输出合同

新增 `scripts/verify.sh`（入口）、`scripts/verification/{VerificationCLI,VerificationReport,VerificationSelfTests,ManualValidation}.swift`（编排/结构/fixture/人工格式）；复用B1 `BoundedProcess.swift`。新增 `.github/workflows/ci.yml`。人工说明与模板在 `docs/evidence/2026-11-03-m5-{validation.md,manual-template.json}`，更新现有产品矩阵/审计及M5证据，不改写历史测试日志。

`VerificationStatus: String, Codable` = Pass/Fail/Pending/Skip；报告 `schemaVersion=1, runID, lane, status, sourceIdentity, artifactIdentity, phases, manualStatus, ciStatus`。sourceIdentity记录gitSHA/sourceTree/dirty；artifactIdentity含B的manifest身份/hash或null；各phase有name/status/exitCode(Int?)/timedOut(Bool)/failureCode(闭合枚举/null)、安全相对证据文件名。报告不能用异常description/userInfo填failureCode。

工具独立编译，不import FlowType的@main：在VerificationReport.swift定义 `BuildMetadataRecord: Codable`（字段逐一对应A的磁盘BuildMetadata）、`ArtifactManifest: Codable`（字段逐一对应B3 manifest）与 `VerificationLane: String, Codable`。产品JSON里的BuildIdentity按origin/metadata/failureCode映射为工具自己的record，不能直接引用未编译进工具的产品类型。

### Task 1: C1 — 本地双门禁编排与可复核报告

**Files:** Create `scripts/verify.sh`及上述VerificationCLI/Report/SelfTests；消费B1 runner、B3 build-app/check-app/manifest。不改现有业务流水线。

**Interfaces:**

- CLI `scripts/verify.sh [--lane code|artifact|release] [--manual-report FILE] [--ci-report FILE]`，默认code；重复/未知参数64。输出 `build/verification/<parent UUID>/verify-report.json`，每child分配新的根；CLI不接收伪造runID/skip检查参数。stdout仅安全摘要/报告相对路径，原始child stdout/stderr各归档。
- shell从自己的绝对位置定位repo，`swiftc -parse-as-library scripts/verification/BoundedProcess.swift scripts/verification/VerificationReport.swift scripts/verification/ManualValidation.swift scripts/verification/VerificationSelfTests.swift scripts/verification/VerificationCLI.swift -o build/tools/flowtype-verify` 后执行。C1先提供ManualValidation的Pending stub，C3完成；主入口首先调用B的 `dispatchChildIfNeeded(arguments:)`。
- `VerificationRunner.run(lane: VerificationLane, repository: URL, output: URL, manualReport: URL?, ciReport: URL?) throws -> VerificationReport`；所有外部命令通过BoundedProcess，用argv不用shell拼接。构建工具失败仍由shell写最小安全bootstrap-failure报告/stderr并非0，不伪造完整Swift报告。
- code：macOS≥15/arm64/Swift≥6.2检查→`swift build`→`.build/debug/FlowType --self-test --validation-root NEW_ROOT`。build/full各900s；要求full exit0且原完整汇总唯一、passed>0、failed=0，不接收focused汇总。默认code不要求clean/shader/GPU，但记录dirty与源码身份，CI code要求checkout clean且无HEAD变化。
- artifact：clean/非浅历史→`scripts/build-app.sh`(900s)→strict/deep(30s)→`scripts/check-app.sh`(120s，内部artifact30s)→同一固定候选10次smoke，每次15s、观察≥6s、实际两tick≥1、tap禁用、packaged身份/hash一致。不会启动正常app。check-app有恢复marker时先恢复再继续；外层超时后也按本次marker核实恢复，冲突即Fail，不能遗留隐藏bundle却总绿。
- release：执行code与artifact各一次，调用C3人工/CI检查。独立可执行阶段继续收集证据；有依赖的后续阶段明确Pending/未执行，不因坏候选继续运行。Fail优先于Pending/Skip；全部required Pass才exit0，Fail1，仅Pending/Skip2，usage64。artifact lane的WindowServer Skip不可总Pass（返回2）。

- [x] **RED：** `VerificationSelfTests.run()`用独立fixture可执行文件/临时repo和注入命令映射，不执行真实业务/网络。`testExitZeroCannotForgeArtifactPass`覆盖多行JSON、缺字段、mode/role错、重复runID、旧SHA/hash、5.9s、任一tick0、tap不禁用、artifact Metal真而MLX假；均Fail。`testFullRunnerRequired`禁止focused冒充full，0 passed/failed非0/缺汇总均失败。
- [x] **RED：** `testPartialReportAndSkipAggregation`覆盖首build失败、full超时、签名失败、smoke69、10次第7次崩溃、parent输出写失败；必须记录已完成阶段、依赖未执行、准确exit/timeout、无总绿。参数含空格/Unicode按argv原样传递；不经shell执行内容。
- [x] **RED 验证：** 实现测试入口 `build/tools/flowtype-verify --self-test`；先编译工具并运行，预期上述负例失败。`--self-test`是工具自身fixture模式，不是产品新增flag；不可通过该模式生成正式release报告。
- [x] **GREEN：** 实现编排/报告、单写者锁和source identity稳定检查。C1人工/CI报告都暂返回Pending，不接受文件存在就Pass。code lane不调用build-app，artifact lane不重复full；release不能通过两个子lane递归再次构建同阶段。
- [x] **验证：** 工具fixture与`bash -n scripts/verify.sh`通过。执行一次真实 `scripts/verify.sh --lane code`（其内部就是build→full，不再外围重复）；核对当前run独立日志与报告。最终十次artifact执行留C3 clean候选，fixture不能填成10次真实Pass。
- [x] **提交：** scoped stage/diff check，提交 `build: add bounded code and artifact verification lanes`。

### Task 2: C2 — CI默认代码门禁与安全证据上传

**Files:** Create `.github/workflows/ci.yml`；Modify `scripts/verification/{VerificationReport,VerificationSelfTests,VerificationCLI}.swift`，扩展白名单证据导出；在规划证据目录记录runner选择依据（实施时核对，不猜SHA）。

**Interfaces:**

- workflow仅push/pull_request默认code，permissions contents:read，checkout fetch-depth:0；不主动push或触发workflow_dispatch。选择实施时GitHub文档明确支持的macOS15+ arm64标签，运行前sw_vers/uname/swift版本确认。Action使用核实过的完整commit固定；无provider secrets，无下载shader/安装toolchain步骤。实际runner不满足即Fail，不能改成Intel“通过”。
- `VerificationEvidence.exportAllowlisted(report: VerificationReport, runRoot: URL, destination: URL) throws -> [String]`只复制该run的verify-report、build/full/smoke/artifact stdout/stderr及隔离diagnostic日志，拒绝symlink/越界与未知文件；返回相对导出文件清单。工具 `--export-evidence RUN_ROOT --output EMPTY_DIRECTORY` 只处理完整/部分验证报告归属路径，不触发任何验证。
- CI always上传 `build/ci-evidence/` 中上述导出文件，明确排除defaults/config/DB/audio/models/production日志，不上传整个verification根。导出失败不能回退为glob全部目录。若验证工具无法编译，只上传预先约定的安全bootstrap stderr/状态。
- artifact CI暂不默认开启；仅后续明确预置shader和图形会话的runner执行同一artifact lane。远端CI未运行则记录Pending，不把本地fixture或yaml语法检查当CI绿。

- [x] **RED：** `testEvidenceAllowlist` 在fixture根并列放diagnostic合成日志及 `.env`/SQLite/模型/外部symlink canary；导出必须只含白名单，无canary、无链接跟随，未知phase路径拒绝。失败/部分报告仍能安全导出已有文件。
- [x] **RED：** `testCICapabilityAndUploadContract`对共用版本/平台解析器测试Swift6.1、Intel、macOS14拒绝；审查workflow实际命令仅code、完整checkout、read权限、always白名单上传。fixture验证导出与预检行为；不写仅比较yaml固定字符串的镜像测试。
- [x] **RED/GREEN验证：** 先运行工具self-test观察导出/预检失败，再实现导出和CI配置并运行同一self-test至通过。人工逐行核对workflow/Action引用及runner文档；无新依赖时不为yaml安装linter。不重复未改产品源码的full，不调用远端CI。
- [x] **提交：** scoped stage/diff check，提交 `ci: gate code validation and whitelist evidence`；远端结果明确Pending。

### Task 3: C3 — 人工schema、主线矩阵与最终交接

**Files:** Complete `scripts/verification/ManualValidation.swift`；Modify工具测试/CLI/报告、`docs/2026-10-14-flowtype-product-validation.md`、`docs/2026-11-01-remaining-work-audit.md`；Create/Update `docs/evidence/2026-11-03-m5-validation.md`、`2026-11-03-m5-manual-template.json`、`2026-11-03-m5-development/README.md`及任务/审查原始证据归档。不改写M1–M4历史日志。

**Interfaces:**

- `ManualValidation.evaluate(data: Data?, manifest: ArtifactManifest?, expectedSourceIdentity: SourceIdentity?, expectedAppPath: URL, evidenceRoot: URL) -> ManualValidationResult`；结果含status、41闭合叶子状态及issue；release报告可选新增manualCases/manualIssues，历史schema1报告无新增字段仍可解码/导出。manifest没有路径，因此预期appPath必须由调用方明确提供repo/build/FlowType.app；sourceIdentity独立提供，CI不依赖artifact成功。证据根只取人工文件父目录。无文件/合法Pending为Pending；malformed/伪Pass/身份错/引用逃逸为Fail。未知/重复ID、不全的required集合均不能聚合Pass；缺必填子项Pending，声称父项Pass但缺子项Fail。
- schemaVersion=1；top-level candidate含gitSHA/sourceTree/binarySHA256/appPath；cases数组每项id/status(Pending/Pass/Fail)。Pass每项还需testedAt(UTC)、tester、environment(macOS/hardware/目标app版本或设备/服务标识)、相同四身份字段、observation对象(actions/result/count/durationMs，R1 count≥10、R2≥20、其他≥1，durationMs>0)、evidence([相对文件])。路径必须存在且在本地evidenceRoot内；不自动上传人工文件/截图。只验证结构/身份，不宣称程序能辨别人工观察真假。
- required叶子ID：R1.launch10；R2.sessions20；R3.axRecovery/R3.micRecovery/R3.noEngine/R3.multipleBlockers；R4.metadata/R4.switchSource/R4.retry/R4.autoFallback/R4.manualSelection/R4.builtin06/R4.builtin17/R4.importQwen/R4.importWhisper；R5.silence/R5.quiet/R5.short/R5.noise；R6.layout/R6.focus/R6.displays；V1.weak/V1.offline/V1.badKey；V2.textEdit/V2.vscode/V2.chrome/V2.terminal/V2.cursor/V2.safeTargets；V3.formats/V3.concurrentCopy；V4.preparing/V4.recording/V4.asr/V4.polish/V4.injection/V4.postEvent；V5.unplug/V5.bluetooth。每个case都required，大小写固定；可选父ID只允许R1–R6/V1–V5，显示叶子聚合且声明必须一致，不能覆盖或替代缺失叶子。空四字段candidate加Pending合法；非空错身份/伪Pass仍Fail。
- `CIValidation.evaluate(data: Data?, expectedGitSHA: String, expectedSourceTree: String) -> VerificationStatus`：schemaVersion=1，status、gitSHA/sourceTree、lane="code"、runURL、evidence；Pass需要确切身份、https://github.com/OWNER/REPO/actions/runs/NUMBER及同run的artifacts/NUMBER证据URL；本地日志不能替代。只验证已提供结构，不访问网络证明结果。缺报告Pending；旧身份/格式错Fail。只读用户提供或已存在的CI结果，不发起push/远程写入。
- 工具模板命令 `--write-manual-template FILE`只写所有required叶子Pending及空候选，不生成任何Pass；拒绝覆盖已有文件。release报告同时记录manualStatus/ciStatus，未通过的required子项不能隐藏。

- [x] **RED：** `testManualIdentityAndRequiredCases`生成临时合成Pass fixture验证结构通过（只用于测试，不写真实证据）；逐项删required叶子、改binary/SHA、父项空勾Pass、缺日期/观察/环境/证据、证据路径穿越/链接、重复ID、过期版本、任一Fail/Pending，断言对应聚合；旧CI/仅本地结果不能让ciStatus=Pass。模板必须全部Pending。
- [x] **RED验证：** 编译工具并 `build/tools/flowtype-verify --self-test`，在接真实校验前观察负例失败；不得拿真实环境凑测试输入。
- [x] **GREEN：** 完成两个验证器/模板和release聚合。文档矩阵写具体方法/预期/身份/evidence：R1普通app十次与smoke分开；R2二十次混合会话含idle/麦克风释放/无重复；R3权限≤5s精确计时、无引擎和多blocker；R4修复动作及自动降级/手选保留、两预置及两类HF导入均实际推理；R5零历史/无幻觉与轻声短词误拒校准；V1–V5按下方台账，不用正常使用代替异常变体。
- [x] **文档更新：** 当前产品矩阵更新为M4常驻权限/恢复卡、380×156和实际事件证据区分deliveryBlocked/Uncertain；保留旧版本备注和原记录。M5审计分列源码、产物、CI与人工；模板实际全部Pending。GUI/网络/设备/真实模型操作需要相应环境和会话授权，本任务不擅改系统或调用收费服务。
- [x] **focused验证：** 工具fixture通过；模板全部Pending，旧schema1解码/导出与CI独立于artifact均有合成覆盖。
- [ ] **最终技术验证（后续调度）：** 先提交工具/文档使clean，再用最终源码 `scripts/verify.sh --lane release` 执行一次完整技术门禁（code一次、build/artifact一次、十次smoke）。本轮未来执行若无真实人工/CI报告，预期exit2且明确Pending；技术失败则exit1。不要为“拿到0”填写Pass。若已在同一最终身份跑过这条完整命令，后续仅审阅其原始报告，不为文档收口重复执行；CLI本身不提供绕过阶段的resume开关。
- [ ] **审查/收口：** 所有任务审查后做一次全M5独立审查；同一修复波次修复阻塞项，再限定范围复审。变更源码后重跑相关focused及一次顺序full，影响产物则固定新binary并使旧manual身份失效。归档原始报告、指纹、限制和Pending，scoped提交 `docs: record M5 gates and remaining device acceptance`。不push/merge/安装/发布，保留当前分支和worktree。

## 人工执行方法摘要

- V1：在已提供的真实云端配置/受控网络条件下覆盖弱网、录音中断网、坏key；观察完整原音频显式重试、新会话/新实时句柄、无隐藏重发和正确卡片。日志不留key/URL正文。
- V2：五app分别中文/英文/多行/emoji；Terminal使用无执行副作用的安全文本。密码框/secure input/非文本/无AX不发键，焦点变化不误投其他app。
- V3：纯文本/多item/图片/文件UTI恢复与用户并发copy；同时记录未发事件与真正发键后的行为，不只看最终剪贴板字符串。
- V4：五阶段取消及发键后取消；无迟到交付/剪贴板污染，真实事件后uncertain只能显式复制/查历史且不重发。
- V5：USB拔麦/蓝牙断开后旧会话终止/可恢复，新录音采用有效设备，不残留占用。真实设备不可用就保留对应叶子Pending。
- R6：长文案/各按钮边缘点击/旧卡失效/多屏与缩放，保持目标焦点；此GUI检查不能由隐藏panel几何fixture替代。

## 包级完成条件

C工具/配置完成与远端CI/真实验收通过分开写；只有全部required Pass且最终身份匹配，才可把原治理与release ready标记完成。以上最初为规划合同；当前源码进展见执行状态，不能把源码/fixture完成写成真实验收通过。自检：§7归C1/C2、§8归C3，五项Review Focus都有负例；B/C共享进程/报告接口，源门禁不依赖GPU，产物门禁不绕过签名，所有V1–V5均主线required。
