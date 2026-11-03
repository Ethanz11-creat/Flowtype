### Task 3: C3 — 人工schema、主线矩阵与最终交接

**Files:** Complete `scripts/verification/ManualValidation.swift`；Modify工具测试/CLI/报告、`docs/2026-10-14-flowtype-product-validation.md`、`docs/2026-11-01-remaining-work-audit.md`；Create/Update `docs/evidence/2026-11-03-m5-validation.md`、`2026-11-03-m5-manual-template.json`、`2026-11-03-m5-development/README.md`及任务/审查原始证据归档。不改写M1–M4历史日志。

**Interfaces:**

- `ManualValidation.evaluate(data: Data?, manifest: ArtifactManifest, evidenceRoot: URL) -> ManualValidationResult`；结果含status及缺失/不匹配的闭合case ID。无文件/合法Pending为Pending；malformed/伪Pass/身份错/引用逃逸为Fail。未知/重复ID、不全的required集合均不能聚合Pass；缺必填子项Pending，声称父项Pass但缺子项Fail。
- schemaVersion=1；top-level candidate含gitSHA/sourceTree/binarySHA256/appPath；cases数组每项id/status(Pending/Pass/Fail)。Pass每项还需testedAt(UTC)、tester、environment(macOS/hardware/目标app版本或设备/服务标识)、相同四身份字段、observation(具体动作/结果/次数/时间)、evidence([相对文件])。路径必须存在且在本地evidenceRoot内；不自动上传人工文件/截图。只验证结构/身份，不宣称程序能辨别人工观察真假。
- required叶子ID：R1.launch10；R2.sessions20；R3.axRecovery/R3.micRecovery/R3.noEngine/R3.multipleBlockers；R4.metadata/R4.switchSource/R4.retry/R4.autoFallback/R4.manualSelection/R4.builtin06/R4.builtin17/R4.importQwen/R4.importWhisper；R5.silence/R5.quiet/R5.short/R5.noise；R6.layout/R6.focus/R6.displays；V1.weak/V1.offline/V1.badKey；V2.textEdit/V2.vscode/V2.chrome/V2.terminal/V2.cursor/V2.safeTargets；V3.formats/V3.concurrentCopy；V4.preparing/V4.recording/V4.asr/V4.polish/V4.injection/V4.postEvent；V5.unplug/V5.bluetooth。每个case都required，大小写固定；父ID只显示聚合，不能覆盖叶子。
- `CIValidation.evaluate(data: Data?, expectedGitSHA: String, expectedSourceTree: String) -> VerificationStatus`：schemaVersion=1，status、gitSHA/sourceTree、lane="code"、runURL、evidence；Pass需要确切身份与可复核运行证据。缺报告Pending；旧身份/格式错Fail。只读用户提供或已存在的CI结果，不发起push/远程写入。
- 工具模板命令 `--write-manual-template FILE`只写所有required叶子Pending及空候选，不生成任何Pass；拒绝覆盖已有文件。release报告同时记录manualStatus/ciStatus，未通过的required子项不能隐藏。

- [ ] **RED：** `testManualIdentityAndRequiredCases`生成临时合成Pass fixture验证结构通过（只用于测试，不写真实证据）；逐项删required叶子、改binary/SHA、父项空勾Pass、缺日期/观察/环境/证据、证据路径穿越/链接、重复ID、过期版本、任一Fail/Pending，断言对应聚合；旧CI/仅本地结果不能让ciStatus=Pass。模板必须全部Pending。
- [ ] **RED验证：** 编译工具并 `build/tools/flowtype-verify --self-test`，在接真实校验前观察负例失败；不得拿真实环境凑测试输入。
- [ ] **GREEN：** 完成两个验证器/模板和release聚合。文档矩阵写具体方法/预期/身份/evidence：R1普通app十次与smoke分开；R2二十次混合会话含idle/麦克风释放/无重复；R3权限≤5s精确计时、无引擎和多blocker；R4修复动作及自动降级/手选保留、两预置及两类HF导入均实际推理；R5零历史/无幻觉与轻声短词误拒校准；V1–V5按下方台账，不用正常使用代替异常变体。
- [ ] **文档更新：** 当前产品矩阵更新为M4常驻权限/恢复卡、380×156和实际事件证据区分deliveryBlocked/Uncertain；保留旧版本备注和原记录。M5审计分列源码、产物、CI与人工；模板实际全部Pending。GUI/网络/设备/真实模型操作需要相应环境和会话授权，本任务不擅改系统或调用收费服务。
- [ ] **验证：** 工具fixture通过；先提交工具/文档使clean，再用最终源码 `scripts/verify.sh --lane release` 执行一次完整技术门禁（code一次、build/artifact一次、十次smoke）。本轮未来执行若无真实人工/CI报告，预期exit2且明确Pending；技术失败则exit1。不要为“拿到0”填写Pass。若已在同一最终身份跑过这条完整命令，后续仅审阅其原始报告，不为文档收口重复执行；CLI本身不提供绕过阶段的resume开关。
- [ ] **审查/收口：** 所有任务审查后做一次全M5独立审查；同一修复波次修复阻塞项，再限定范围复审。变更源码后重跑相关focused及一次顺序full，影响产物则固定新binary并使旧manual身份失效。归档原始报告、指纹、限制和Pending，scoped提交 `docs: record M5 gates and remaining device acceptance`。不push/merge/安装/发布，保留当前分支和worktree。

## 人工执行方法摘要

- V1：在已提供的真实云端配置/受控网络条件下覆盖弱网、录音中断网、坏key；观察完整原音频显式重试、新会话/新实时句柄、无隐藏重发和正确卡片。日志不留key/URL正文。
- V2：五app分别中文/英文/多行/emoji；Terminal使用无执行副作用的安全文本。密码框/secure input/非文本/无AX不发键，焦点变化不误投其他app。
- V3：纯文本/多item/图片/文件UTI恢复与用户并发copy；同时记录未发事件与真正发键后的行为，不只看最终剪贴板字符串。
- V4：五阶段取消及发键后取消；无迟到交付/剪贴板污染，真实事件后uncertain只能显式复制/查历史且不重发。
- V5：USB拔麦/蓝牙断开后旧会话终止/可恢复，新录音采用有效设备，不残留占用。真实设备不可用就保留对应叶子Pending。
- R6：长文案/各按钮边缘点击/旧卡失效/多屏与缩放，保持目标焦点；此GUI检查不能由隐藏panel几何fixture替代。

## 包级完成条件

C工具/配置完成与远端CI/真实验收通过分开写；只有全部required Pass且最终身份匹配，才可把原治理与release ready标记完成。当前只写计划，以上没有执行。自检：§7归C1/C2、§8归C3，五项Review Focus都有负例；B/C共享进程/报告接口，源门禁不依赖GPU，产物门禁不绕过签名，所有V1–V5均主线required。
