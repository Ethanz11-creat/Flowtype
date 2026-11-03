# M5 规划调研 — 2026-11-03

只读源码/文档调研，基线HEAD `b00b0a50d9c6913a91ef01c6a8c8944688add31e`；产品源码 `5dc1693`，Sources tree `872e9038b8def8ed720d9cc6370c57ed12d76794`。本轮用户只要求计划：不实施、不运行构建/自测/smoke，不访问真实配置/密钥/模型，不更改权限、网络或现有app。M4的23872/0是历史证据，不是本轮运行。

## 直接发现

| 文件/位置（当前基线） | 观察 | M5影响 |
| --- | --- | --- |
| App/FlowTypeApp.swift:10/40/79 | 只有self-test分支；普通AppDelegate会环境迁移、恢复音频设备、显示引导并加载/可能下载模型 | smoke不能直接调用完整AppDelegate；先确定进程角色/隔离再构造单例 |
| Core/PipelineOrchestrator.swift:60 | SessionEffects.live.prepare会startProbing+loadModel | smoke构造SessionController.shared必须禁止自动模型动作；否则独立defaults还不够 |
| Services/Speech/ASRRouter.swift:204/332 | probe首tick1s、周期30s；计时器闭包调用ASRRouter.shared而非实例 | 等待真实tick并记counter；修成weak self，保持Sendable；离线测试实例不能偷偷回共享路由 |
| WindowManager.swift:97/208 | event-tap健康周期实际5s | 原总设计3s观察不足，改6s；不能用等过时间代替callback证据 |
| WindowManager.swift:170/259 | 设置hotkey会创建可执行热键tap，用户真实按键可触发会话 | smoke禁止tap安装/事件处理，保留真实健康timer执行；报告该边界未验证真实tap |
| Core/ConfigurationStore.swift:5/17/53/70 | shared默认standard；旧迁移能操作登录Keychain | role配置defaults；测试Keychain改进程内假store，不能仅改文件目录 |
| Core/Persistence.swift:13、Core/Database/AppDatabase.swift:107 | 词典/数据库shared使用用户Application Support；DB迁移可改名旧JSON | 显式RuntimePaths；自动进程只触及唯一run目录，fixture migration可在其中运行 |
| Utilities/AppLogger.swift:8/35 | 固定production日志，异步队列，exit可能丢最后日志 | role/runID文件路由、启动首条身份和退出flush |
| Services/Speech/LocalModelManager/ModelPreset.swift:13；ModelLocator.swift:37 | presets创建用户目录；locator会读系统cache/HF refs | 测试路径覆盖；smoke完全禁加载/扫描，self-test旧路径也不能回真实cache |
| scripts/build-app.sh:6/24/31/65 | version/build写死；Python导入回退；只平铺复制json/png，metallib放MacOS | 生成身份、无Python、显式shader前提、资源bundle和标准签名封装 |
| release/FlowType.build/DerivedSources/resource_bundle_accessor.swift:5 | Bundle.module先查app根的FlowType_FlowType.bundle，后查绝对.build路径；脚本未复制该bundle | 新AppResources以Contents/Resources中的bundle为主，打包检查禁止开发路径回退 |
| Services/Speech/ASRPostProcessor.swift:409/420；App/StatusBarController.swift:73 | 词库与状态图标依赖Bundle.module | 迁移到共同AppResources；脱离checkout运行检查实际字典/图片 |
| M4 bundle-verification | ignore-resources通过，strict/deep因unsigned MacOS/mlx.metallib失败 | 不能把main-code通过当完整签名；需独立产物修复及真实Metal加载证据 |

## MLX本地依赖证据（未修改依赖）

`.build/checkouts/mlx-swift/Package.swift:94`定义 `SWIFTPM_BUNDLE="mlx-swift_Cmlx"`。
`Source/Cmlx/mlx/mlx/backend/metal/device.cpp:139–159`依次尝试colocated mlx、colocated Resources/mlx、SwiftPM bundle里的default；`load_swiftpm_library:113–128`遍历allBundles的resourceURL，`try_load_bundle:56–64`查 `<resourceURL>/mlx-swift_Cmlx.bundle/default.metallib`。
`backend/common/utils.cpp:9`用dladdr确定二进制路径。

因此标准候选封装为 `Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib`（带bundle plist）。这是静态支持的方案，不是已通过的修复；必须实际验证strict/deep签名、独立路径Metal加载与真实MLX微计算，任一失败都不能宣称解决。不修改vendored依赖、不签名shader为伪可执行文件、不使用ignore-resources作通过门禁。

## 原依据与冲突处理

- 总设计 `docs/superpowers/specs/2026-10-22-stability-and-delivery-design.md` §4.6/§7/§10：M5只有方向，没有独立计划。
- M4验证清单记录V1–V5、声学/模型/GUI均Pending，本轮不替代。
- 原3s smoke不覆盖5s timer；原固定flowtype.smoke suite并发共享；原CI无条件packaging隐含机器有shader；原push条目与现有不push约束冲突。新设计分别采用6s+tick证据、每run隔离、CI代码与本地产物双门禁、保留分支不push。
- 没有调用浏览器/远端/CI/桌面工具，不声称了解当前GitHub runner镜像的全部预装内容；CI实现须显式检查arm64/macOS15+/Swift6.2，不静默改平台/下载模型。

## 规划产物与自检

- [设计](../../superpowers/specs/2026-11-03-m5-release-guardrails-design.md)：当前规划依据；不标记为用户已批准实施。
- [M5-A](../../superpowers/plans/2026-11-03-m5-a-build-identity-and-isolation.md)：A1启动上下文/安全根，A2真实数据与副作用隔离，A3身份/日志/关于菜单。
- [M5-B](../../superpowers/plans/2026-11-03-m5-b-smoke-and-artifact.md)：B1外部watchdog/真实timer，B2资源与GPU检查，B3打包/签名/移位验证。
- [M5-C](../../superpowers/plans/2026-11-03-m5-c-verification-and-acceptance.md)：C1双门禁脚本，C2CI/白名单，C3人工schema/矩阵与审查交接。
- [验收台账](../2026-11-03-m5-validation.md)：技术门禁及41个required真机叶子全部Pending；不填伪Pass。

| 自检项 | 检查结果与已修正问题 |
| --- | --- |
| 设计覆盖 | §3→A1/A2，§4→A3，§5→B1/B2，§6→B3，§7→C1/C2，§8→C3；原十次普通启动、十次smoke、二十会话、无引擎/权限/模型/交付/安全目标/静音/CI均有owner |
| 接口一致 | RuntimeContext/BuildIdentity→B；BoundedProcess与child dispatch→各CLI；脚本独立编译的metadata record与产品磁盘schema一致，不误import产品@main |
| 身份与签名 | 签名后取binary hash，外置manifest与app成对更新/恢复；浅历史/脏树/HEAD变化拒绝；旧身份不沿用人工Pass |
| 隔离 | A1先接logger路径，A2再跑迁移；RED先fixture/deny边界，接好守卫后才shared集成；默认temp可规范化，显式symlink拒绝 |
| 失败与Pending | 真实tick缺失/坏JSON/超时/MLX失败均Fail，WindowServer显式Skip不能总绿；远端CI未运行保持Pending，未擅自push |
| Review Focus | 每包五项风险均有命名测试归属；本轮为作者文档自检，没有子智能体代码审查或新测试运行 |
| 比例与交接 | 三包各三任务，明确文件/接口/RED-GREEN/验证/提交与包级退出；后续沿用已指定子智能体开发，当前只规划 |

只执行Markdown链接/路径一致性检查、git diff检查和文档提交；没有构建、自测、smoke、Python、真实配置/权限/模型/网络变更。完整签名布局仍需实现后的运行证据，静态源码推断不是已通过证明。
