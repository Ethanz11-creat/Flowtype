# D — Release Acceptance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 解释并修复当前CI失败，为模型中心新增候选绑定验收，并补齐新旧真机矩阵与正式发行证据。

**Architecture:** 保留现有M5技术门禁和41项manual schema；新增模型中心30项独立ledger、发行报告与汇总gate。CI/source/artifact/manual/distribution各层身份显式匹配，不能互相替代。

**Tech Stack:** 现有Swift verification CLI/self-tests、GitHub Actions、codesign/notarytool/stapler/spctl、原生macOS真机。

**Spec:** [总设计](../specs/2026-11-09-asr-model-center-design.md) §3/6；[体验设计](../specs/2026-11-09-model-center-experience-design.md) §5/6。D1先执行，D2依赖A–C，D3/D4协同收口。

## Global Constraints

- 平台为 macOS 15+、Apple Silicon、Swift 6.2；保留 macOS 原生 SwiftUI 客户端。
- 保持 speech-swift 0.0.15、WhisperKit 0.18.0、swift-transformers 1.1.9 锁定基线；新增依赖或升级必须单独说明依据。
- 核心音频契约为 16kHz、单声道 Float32；协议适配器负责 wire 编码；一次录音只交付一次终稿。
- 原生推理严格离线；下载是显式独立操作；外部模型服务由用户自行安装、启动和更新。
- 下载、检查、加载、试识别、选中分别建模；失败或取消不替换已有可用选择，不删除用户自有模型。
- 录音开始捕获不可变后端、模型、能力与凭据快照；迟到回调不能改变新会话或新配置。
- 自动化使用隔离临时根、合成文件与注入 transport；不读写用户真实配置、密钥、模型、权限或剪贴板。
- 各任务顺序运行 swift build 与 self-test；最终运行现有 code/artifact/release 门禁；Pending 不等于 Pass。

## Review Focus

1. timer断言失败不能通过跳过测试或放宽为“等待过就通过”掩盖（D1）。
2. 旧41项schema不能混入新ID，重复/缺失/错候选/伪造Pass必须被拒绝（D2）。
3. fixture推理、离屏预览或无凭据Skip不能算真实模型/厂商/跨应用成功（D2/D3）。
4. ad-hoc签名验证不等于Developer ID/公证；重签后的binary hash不能复用旧manual（D4）。
5. 签名/公证/DMG复制后资源、Metal与Keychain访问仍须可用，未签名构建可用不足以证明发行可用（D3/D4）。

## File Structure

D1修改WindowManager与M5SmokeSelfTests，必要timer调度抽象单独成文件。D2新增 `scripts/verification/ModelCenterAcceptance.swift` / `ModelCenterAcceptanceSelfTests.swift` / `ModelCenterAcceptanceCLI.swift` 与 `scripts/verify-model-center.sh`；不修改旧ManualCaseID列表。D4新增 `scripts/verification/DistributionVerification.swift` / `DistributionVerificationSelfTests.swift` / `DistributionVerificationCLI.swift` 与 `scripts/verify-distribution.sh`，修改ArtifactPackagingCLI、VerificationCLI/Report/SelfTests和build-dmg的发行/候选复用支持。验收文档/JSON放`docs/superpowers/validation/`，实际证据放`docs/evidence/<执行日期>-asr-model-center/`；大日志与安装包留ignored build，归档摘要和hash。

## Task D1: 恢复远端 CI 基线

**Files:** Modify `Sources/flowtype/WindowManager.swift`、`Testing/M5SmokeSelfTests.swift`；Create `Sources/flowtype/Utilities/EventTapHealthScheduler.swift`（若用下述调度注入）；更新独立基线证据。

**Interfaces:**
- 在WindowManager的MainActor边界注入 `EventTapHealthScheduler.schedule(interval: TimeInterval, tick: @escaping @MainActor @Sendable () -> Void) -> EventTapHealthTimer`；timer提供 `cancel()`。
- 生产仍是.main DispatchSourceTimer；fake只在测试注入，暴露scheduledCount与可手动fire的callback。保留现有healthGeneration和实际windowHealthTicks。

- [ ] **Step 1: 保存失败证据并补失败回归。** 下载/核对run41672136709日志，记录已有25,919/1结果；给真实timer断言增加elapsed、ticks、start/cancel计数。新增 `testOneHealthTimerOwner`：重复start只schedule一次，逐次fire每次加1，stop后捕获的旧callback不能加1；新增实际timer liveness测试，最多2秒等待2个真实callback，不限定110ms时点的计数区间。

```swift
r.eq(fake.scheduledCount, 1, "duplicate start has one scheduled timer")
r.eq(ticksAfterTwoExplicitCallbacks, 2, "one tick per callback")
r.eq(ticksAfterStaleCallback, stoppedTicks, "cancelled generation cannot tick")
r.check(actualCallbacksWithinTwoSeconds >= 2, "actual timer must make progress")
```

- [ ] **Step 2: 验证 RED。** 顺序build、`swift run --skip-build FlowType --self-test --m5-smoke-contract-only`；用原CI作为原始失败证据，不要求不稳定断言每次必现。fake明确暴露duplicate/stale错误时不能继续只归因负载。打印观测值后区分调度时序与真实timer生命周期缺陷，结论记证据。
- [ ] **Step 3: 实现调度注入与准确测试。** 若发现真实重复start/取消缺陷，修复owner/generation；如果仅旧时点断言不可靠，用fake证明所有权、用真实callback证明liveness，保留artifact smoke中的实际timer门槛。不可删除timer evidence、改为sleep即Pass或把失败转Skip。
- [ ] **Step 4: 验证 GREEN。** build→focused→一次全量`./scripts/verify.sh --lane code`；退出0、所有phase Pass。后续得到已授权push的新SHA后在D3核对远端CI；本任务本地通过允许继续A，但此时不能宣称远端已经通过。
- [ ] **Step 5: 提交并审查。** `git commit -m "fix: verify health timer ownership without fragile timing counts"`；fresh review核对没有削弱实际timer证据。未经后续push指令不推送。

## Task D2: 新旧验收并存与候选绑定 gate

**Files:** Create ModelCenterAcceptance/CLI/SelfTests、`scripts/verify-model-center.sh`；Create新版acceptance JSON schema/template；Modify C创建的验收md与现有verification自测注册；旧41项schema不变。

**Interfaces:**
- Produce `ModelCenterAcceptance.evaluate(report: URL, candidate: ModelCenterCandidate) throws -> VerificationStatus`；candidate字段gitSHA/sourceTree/binarySHA256/appPath/packageSHA256（尚未分发可为nil，但最终public gate必填）。
- Produce CLI `scripts/verify-model-center.sh --write-template <path>` 与 `--report <path> --manifest <path> --distribution-report <path>`；status Pass/Fail/Pending分别exit0/1/2，usage64。报告自身schemaVersion=1，与旧schemaVersion=1是不同schema，不能按数字混用。
- 固定30个case：`H1.repo,H1.variant,H1.tokenizer,H1.gated,H2.resume,H2.restart,H2.integrity,H2.disk,H3.qwen06,H3.qwen17,H3.whisperTiny,H3.whisperBase,H3.offlineLong,H4.mlxAudio,H4.whisperKit,H4.whisperCpp,H4.disconnect,H5.siliconCN,H5.openAI,H5.custom,H5.errors,H6.switch,H6.cancel,H6.delete,H6.credentials,H7.layout,H7.keyboard,H7.accessibility,H8.fresh,H8.upgrade`。

- [ ] **Step 1: 写 `testModelCenterLedgerValidation`。** 全30项真实字段完整才可Pass；缺项/重复/未知ID/错误binary或package/无观察/空证据/把configurationValid当realrecognition都失败。初始template全Pending；混入R/V ID不能通过。已有41项manual报告仍由原validator独立核对。

```swift
r.eq(validPendingTemplate.status, .pending, "template is never acceptance")
r.eq(duplicatedCaseReport.status, .fail, "duplicate case rejected")
r.eq(reSignedBinaryWithOldManual.status, .fail, "binary identity is binding")
```

- [ ] **Step 2: 验证 RED。** 本task给新CLI提供 `--self-test`，先运行 `bash -n scripts/verify-model-center.sh`，再运行 `scripts/verify-model-center.sh --self-test`，预期新validator断言失败。
- [ ] **Step 3: 实现validator和template。** 每行要求测试者/日期/硬件/macOS/服务版本或模型commit/动作/观察/证据路径；不在template自动填Pass。D3运行报告提供candidate字段；签名/资源改变后旧行失效。原41项逐项仍必须通过，不用新30项代替。
- [ ] **Step 4: 验证 GREEN。** 新CLI自测exit0、template校验exit2；错候选fixture exit1。原verification自测仍通过，新CLI不触发真实权限/网络/Keychain。
- [ ] **Step 5: 提交并审查。** `git commit -m "feat: gate model center acceptance on candidate-bound evidence"`。

## Task D3: 技术候选、真实矩阵与整体 review

**Files:** Update验收表与候选证据；如发现缺陷只改对应owner task的源码/测试。Add `docs/evidence/<执行日期>-asr-model-center/README.md`、研究到实现的覆盖映射、final-review。

**Interfaces:**
- Consume A–C实现、D2ledger、M5 code/artifact/release、D4distribution报告。
- Produce同一候选的41项旧manual +30项新manual、远端CI、代码/资源/发行报告。模型variant、原生engine version、service commit与安装source commit均写明。

- [ ] **Step 1: 完成独立代码审查。** 使用requesting-code-review，覆盖A–C全差异、核心链路和所有新安装/凭据接口；receiving-code-review核对后修复Important/Critical，补实际回归，fresh复审。不得用原M1–M5旧审查代替本版本。
- [ ] **Step 2: 建立技术候选。** 稳定提交后运行 `scripts/verify.sh --lane code`；显式提供已知Metal资源路径再运行artifact lane（沿用既有MLX_METALLIB_PATH要求），取得manifest与10次smoke。不能从缓存自动发现不明shader。远端CI只在已授权push后核对同source SHA，不从旧run复制Pass。
- [ ] **Step 3: 在D4产出最终签名候选后执行真机矩阵。** H1：HF链接/变体/双来源tokenizer/受限授权；H2：实际断网、重启、续传/损坏与磁盘失败；H3：Qwen两规模4/8-bit导入、tiny/base多语言、真正断网加载及>30s首尾；H4：三种参考服务实际识别/断连/取消；H5：硅基CN/OpenAI/自定义真实model与坏key/限流；H6：在途切换/取消/占用删除/Keychain恢复；H7：三档窗口、滚动、键盘、VoiceOver/减少动态；H8：干净用户目录首次安装与旧配置升级。真实可用的模型/凭据/设备逐项执行，缺条件保持Pending。
- [ ] **Step 4: 完成原41项。** V1弱网/断网、V2 TextEdit/VSCode/Chrome/Terminal/Cursor落字与焦点、V3多格式与并发剪贴板、V4各阶段取消、V5拔麦/蓝牙恢复继续是主线；R1–R6也逐项绑定最终签名候选。涉及用户真实环境的手动动作按测试目标说明，不批量改权限或覆盖剪贴板来伪造结果。
- [ ] **Step 5: 汇总门禁与归档。** 将原41项/新30项/远端CI报告分别保存为 `build/asr-model-center/manual-mainline.json`、`manual-model-center.json`、`remote-code.json`。对最终候选运行 `scripts/verify.sh --lane release --candidate-manifest "$PWD/build/FlowType.manifest.json" --manual-report "$PWD/build/asr-model-center/manual-mainline.json" --ci-report "$PWD/build/asr-model-center/remote-code.json"`，再运行D2/D4新gate。D4负责新增candidate-manifest模式，此处不能调用旧会重建的release命令。命令与退出码原样存证。重新签名/改资源/改源码后，相关验收必须重新绑定并复测，不能只改JSON hash。全部Pass才报告正式可发布；任何Pending明确列出。归档摘要hash后提交文档，推送/合并/发行等待明确指令。

## Task D4: Developer ID、公证和 DMG 分发

**Files:** Modify `scripts/verification/ArtifactPackagingCLI.swift`、`ArtifactPackaging.swift`、`VerificationCLI.swift`、`VerificationReport.swift`、`VerificationSelfTests.swift`、`scripts/build-dmg.sh`；Create DistributionVerification/CLI/SelfTests、`scripts/verify-distribution.sh`。不把发行身份写进产品源码或仓库配置。

**Interfaces:**
- 新增可选 `FLOWTYPE_SIGNING_IDENTITY`，缺失继续现有ad-hoc开发候选；有值时验证为Developer ID Application身份，内嵌Mach-O从内到外用timestamp/hardened runtime签名。签名完成后写manifest。需要的entitlements按依赖实际需求列最小集合，不默认允许unsigned executable memory。
- 公证凭据通过用户预先配置的 `FLOWTYPE_NOTARY_PROFILE` 引用，使用notarytool profile，不读取/打印Apple口令。公证凭据、签名身份缺失时发行报告Pending，不能默认Pass或申请账号。
- Produce `DistributionVerificationReport`（schemaVersion:Int=1、status、candidate、teamID、hardenedRuntime:Bool、appNotarizationID:String?、dmgNotarizationID:String?、stapled:Bool、gatekeeperAccepted:Bool、dmgSHA256:String?、issues:[String]）。`scripts/verify-distribution.sh --app <absolute> --manifest <absolute> --dmg <absolute> --notary-evidence <absolute> --output <absolute>`输出0/1/2；另有无外部动作的 `--self-test`。notary-evidence由发行操作保存原始notarytool Accepted输出、提交包SHA与最终staple后包SHA，不能通过手填ID冒充接受。
- Extend `VerificationOptions.candidateManifest: URL?` 和CLI成对参数 `--candidate-manifest <absolute>`，只允许artifact/release lane；限定为当前repo的 `build/FlowType.manifest.json`，重新读取验证manifest/签名/clean source。runner记录 `artifact-reuse` 内部phase代替 `artifact-build`，保留其余source/签名/资源/10smoke与manual校验；报告validator明确接受这两种互斥phase，不接受二者都缺失。

- [ ] **Step 1: 写 `testDistributionIdentityAndEvidence` / `testCandidateReuseDoesNotRebuild`。** fixture命令注入：ad-hoc/deep verify成功但无team/notary→Pending；公证rejected→Fail；signed app与manifest不符→Fail；全部接受且binary/package匹配→Pass。reuse模式build/sign调用为0，10smoke和资源检查仍发生；错source/hash、外部manifest、dirty source拒绝。脚本test不实际签名、公证、上传或更改Keychain。测试nested-code顺序、sign失败事务不替换旧app。
- [ ] **Step 2: 验证 RED。** 新distribution CLI自测，预期现有ad-hoc流程不能满足正式发行条件。
- [ ] **Step 3: 实现发行模式与验证。** 所有Mach-O以Developer ID签名后生成manifest；先将signed App归档提交公证，Accepted后staple App，核对binary/metadata/shader hash未变并运行现有 `scripts/check-app.sh`。再生成DMG、Developer ID签名DMG、提交DMG公证，Accepted后staple DMG；完成后计算最终package SHA。两次submission ID与原始接受输出分别记录。签名后不写新产品资源。实现显式candidate复用模式，不能在公证后再次重建App；只靠ad-hoc副本的报告不算通过。
- [ ] **Step 4: 验证 GREEN 与真实发行。** CLI自测exit0；具备用户提供身份后生成最终signed/stapled App和DMG，运行 `scripts/verify.sh --lane artifact --candidate-manifest "$PWD/build/FlowType.manifest.json"` 取得同一二进制技术证据。`codesign --verify --deep --strict`、stapler validate、`spctl --assess --type execute`均通过，并在干净机器验证下载隔离属性下首开、安装/升级、模型加载与Keychain读取。实际签名条件缺失只完成代码/fixture，真实发行保持Pending。将最终app交D3执行manual，禁止拿ad-hoc版manual改hash。
- [ ] **Step 5: 提交并审查。** `git commit -m "feat: verify signed and notarized FlowType distribution"`；review发行命令、身份与报告可信度。发行上传/发布须有用户明确指令，本计划阶段不执行。
