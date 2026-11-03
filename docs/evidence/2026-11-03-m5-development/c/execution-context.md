# Binding C execution context

- Swift6.2+、macOS15+、Apple Silicon；不新增或升级外部依赖/Package.resolved，不运行Python、不下载ASR模型或自动安装shader/toolchain。
- 用户本轮仅要求计划；产品源码、现有构建产物与系统配置保持原状。不把规划写成已实施或验收通过。
- 后续开发使用合成数据、假服务/剪贴板/输入事件和独立运行目录；不读取真实配置/词典/DB/Keychain/模型缓存，不触发授权弹窗、录音、热键输入或外部ASR/LLM请求。
- 普通app仍使用原用户配置/目录/启动行为；验证模式必须在任何shared/logger/AppKit初始化前确定，初始化失败退出，禁止回退到生产路径。
- 保留M1–M4 readiness降级、captured route/lease、原音频重试、新20s预算、新实时句柄、单次交付、剪贴板与取消/回调所有权保护；不借M5改写这些合同。
- 构建/运行报告只含身份、阶段、闭合枚举/计数/状态；不输出密钥、请求正文、转写、用户文档、原始配置、URL/query或任意NSError.userInfo。自动上传仅显式白名单的合成验证产物。
- 验证按focused→顺序swift build/full self-test；不运行swift test或重复未变全套/声学benchmark。M4的23872/0仅作历史基线，不重复一次未变baseline。
- 保留分支和worktree，不push、不merge、不安装到/Applications、不替换正在运行的app。V1–V5/真实模型/声学校准/GUI未执行均Pending。



新增 `scripts/verify.sh`（入口）、`scripts/verification/{VerificationCLI,VerificationReport,VerificationSelfTests,ManualValidation}.swift`（编排/结构/fixture/人工格式）；复用B1 `BoundedProcess.swift`。新增 `.github/workflows/ci.yml`。人工说明与模板在 `docs/evidence/2026-11-03-m5-{validation.md,manual-template.json}`，更新现有产品矩阵/审计及M5证据，不改写历史测试日志。

`VerificationStatus: String, Codable` = Pass/Fail/Pending/Skip；报告 `schemaVersion=1, runID, lane, status, sourceIdentity, artifactIdentity, phases, manualStatus, ciStatus`。sourceIdentity记录gitSHA/sourceTree/dirty；artifactIdentity含B的manifest身份/hash或null；各phase有name/status/exitCode(Int?)/timedOut(Bool)/failureCode(闭合枚举/null)、安全相对证据文件名。报告不能用异常description/userInfo填failureCode。

工具独立编译，不import FlowType的@main：在VerificationReport.swift定义 `BuildMetadataRecord: Codable`（字段逐一对应A的磁盘BuildMetadata）、`ArtifactManifest: Codable`（字段逐一对应B3 manifest）与 `VerificationLane: String, Codable`。产品JSON里的BuildIdentity按origin/metadata/failureCode映射为工具自己的record，不能直接引用未编译进工具的产品类型。


Prior planning-only sentence is historical; latest user authorization requests implementation. Reuse this same implementer; no nested agents. Controller owns reviews/ledgers. Read only this plan scratch plus committed product/tool sources; no other plan scratch. M5-A approved at d6aaace. M5-B dependency contracts must come from committed source, not guesses. No ordinary app, real config/key/models, permissions, clipboard/input, external ASR or remote CI. No Python, downloads/install or dependency lock changes. CI source notes and pinned action snapshots are in this same directory. Actual CI/manual evidence stays Pending. Stop after each assigned task report/commit for controller review, then continue when dispatched.

B3 actual artifact is now proven atc21cb25e4d37249d3d932939a6157b946b64a243 (Sources tree953608b60a0349dfcd2acfc4ddeef6f6d6b39288): strict/deep and moved app resource/Metal/actual MLX all passed. This is prior artifact evidence, not C final10. Build350/version1.0.0 binaryc59eb53b8aaec14421ef19e2c884e67cbb94f46a31ec069092051e66a38ac85f. Existing shader now lives in build/FlowType.app/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib,146852000B, SHA256f36b01c44dd5f2d9020deb1ac6ad53dc085de81af19396694c5963ef3a12137f. For C3 actual release command use that explicit MLX_METALLIB_PATH input; do not use the historical MacOS shader path or scan user caches. B3 copies input into owned staging before replacing final candidate, so self-source input is supported. No candidate ordinary app was launched.

Committed tool contracts: scripts/build-app.sh no args, scripts/check-app.sh --app ABSOLUTE_APP --output EXISTING_EMPTY_DIRECTORY. Shared ArtifactPackaging.swift/CLI use fixed production adapters and token/fingerprint/active-inner checks. Optional BoundedProcess shouldCancel/onLaunch hooks preserve B1 defaults. Independent CLI must dispatchChildIfNeeded first. Need recovery after an outer check timeout: use owned packaging recovery with the same lock; restore safely or Fail conflict, never infer outer process group killed all nested groups. Do not rerun B3 actual build/check unchanged just to inspect it; C3 final release has its own exact final-source gate.
