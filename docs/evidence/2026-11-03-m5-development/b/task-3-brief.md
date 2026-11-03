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
