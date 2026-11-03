### Task 2: C2 — CI默认代码门禁与安全证据上传

**Files:** Create `.github/workflows/ci.yml`；Modify `scripts/verification/{VerificationReport,VerificationSelfTests,VerificationCLI}.swift`，扩展白名单证据导出；在规划证据目录记录runner选择依据（实施时核对，不猜SHA）。

**Interfaces:**

- workflow仅push/pull_request默认code，permissions contents:read，checkout fetch-depth:0；不主动push或触发workflow_dispatch。选择实施时GitHub文档明确支持的macOS15+ arm64标签，运行前sw_vers/uname/swift版本确认。Action使用核实过的完整commit固定；无provider secrets，无下载shader/安装toolchain步骤。实际runner不满足即Fail，不能改成Intel“通过”。
- `VerificationEvidence.exportAllowlisted(report: VerificationReport, runRoot: URL, destination: URL) throws -> [String]`只复制该run的verify-report、build/full/smoke/artifact stdout/stderr及隔离diagnostic日志，拒绝symlink/越界与未知文件；返回相对导出文件清单。工具 `--export-evidence RUN_ROOT --output EMPTY_DIRECTORY` 只处理完整/部分验证报告归属路径，不触发任何验证。
- CI always上传 `build/ci-evidence/` 中上述导出文件，明确排除defaults/config/DB/audio/models/production日志，不上传整个verification根。导出失败不能回退为glob全部目录。若验证工具无法编译，只上传预先约定的安全bootstrap stderr/状态。
- artifact CI暂不默认开启；仅后续明确预置shader和图形会话的runner执行同一artifact lane。远端CI未运行则记录Pending，不把本地fixture或yaml语法检查当CI绿。

- [ ] **RED：** `testEvidenceAllowlist` 在fixture根并列放diagnostic合成日志及 `.env`/SQLite/模型/外部symlink canary；导出必须只含白名单，无canary、无链接跟随，未知phase路径拒绝。失败/部分报告仍能安全导出已有文件。
- [ ] **RED：** `testCICapabilityAndUploadContract`对共用版本/平台解析器测试Swift6.1、Intel、macOS14拒绝；审查workflow实际命令仅code、完整checkout、read权限、always白名单上传。fixture验证导出与预检行为；不写仅比较yaml固定字符串的镜像测试。
- [ ] **RED/GREEN验证：** 先运行工具self-test观察导出/预检失败，再实现导出和CI配置并运行同一self-test至通过。人工逐行核对workflow/Action引用及runner文档；无新依赖时不为yaml安装linter。不重复未改产品源码的full，不调用远端CI。
- [ ] **提交：** scoped stage/diff check，提交 `ci: gate code validation and whitelist evidence`；远端结果明确Pending。

