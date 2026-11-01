# M1 readiness 真机证据（部分记录）

记录日期：2026-11-01，时区 Asia/Shanghai；续测记录截至 12:00:25Z。本文依据控制器的 `task-15-observations.md` 与 `task-15-runtime-continuation.md` 整理；文档交付不代表 Task 15 或 M1 真机验收完成。七项用例均为 **Pending**，P1 / P3 验证矩阵保持 Pending；自动化结果不能替代权限转换的真机观察。

## 固定候选与环境

- 代码：`2d0eca91e21177738d019a9bf6e9f35442b88e4c`（`fix(readiness): align menu commands and terminal model failures`），分支 `flowtype-local`。本文后续文档提交不改变该候选代码身份。
- 设备：MacBook Pro，Apple M1，16 GB；macOS 15.7.9（24G830）。
- 构建：`./scripts/build-app.sh`，exit 0，93.19s；日志 `/private/tmp/flowtype-m1-release-fixed.log`。二进制 mtime：`2026-11-01T19:13:26+0800`，大小 51,110,704 bytes。
- 候选 bundle：`/Users/yiheng/pycode/flowtype-local/build/FlowType.app`（注意大小写）；验证窗口未重新构建或重启。
- `codesign -dv --verbose=4`：Identifier=`com.flowtype.app`，Signature=`adhoc`，TeamIdentifier=`not set`，无 Authority 行；CDHash=`295afde657b44498ff199325bac4fd3b733c36a6`。
- 二进制 SHA256：`26436213a835f1c5d74cb17ff2b57ce93198ebf413be21d23cc67f6cfef3b0f1`。
- `Contents/MacOS/mlx.metallib` 已打包，大小 146,852,000 bytes。

**签名限制：**`codesign --verify --deep --strict --verbose=2 build/FlowType.app` 返回 exit 1：`code object is not signed at all`，子组件为 `Contents/MacOS/mlx.metallib`。对 `/Applications/FlowType.app` 执行同一验证也同样失败。身份信息可读取、候选可启动，但深度签名验证失败，不能称签名完全有效；这是已有打包限制，本次未实施 M5 修复。

已安装应用在候选启动前通过 CUA 退出，二进制未替换，其原 CDHash 仍为 `de4d96988b5dcf15a896a38592ef3074cb53ee58`。续测中共享 `com.flowtype.app` 授权条目已为候选移除重建；原安装版本未来的权限状态未复查，可能需重新授权。M0 中用户接受的是原安装应用 sessions #2 / #3（最新 stop→delivery 4233ms，本地 Qwen，无 fallback），不能转移为本候选的 M1 验收。

## 初始启动观察（11:17Z）

候选于 `2026-11-01T11:17:19Z`（本地 19:17:19）通过 CUA 按完整路径启动，PID 75257；3m26s 后观察进程仍存活。保持 `localOnly`，本地已有 `Qwen3-ASR-1.7B-MLX-4bit`；初始观察期间未改云端 ASR 设置或凭据，未授予或撤销 AX、麦克风、Speech Recognition 权限。后续 AX 变更见续测记录。

初始应用探测快照为 AX `denied`、mic `notDetermined`、local `ready`、cloud / Apple `unavailable`，readiness 为 `degraded`。这些是候选在初始观察时的应用探测结果，不能推定续测后的快照或所有安装身份的历史权限状态。没有实际录音或候选会话，所有下列用例的真实日志 session id 均为 **N/A**，不引用 SelfTest 合成会话。

CUA `getApp/getAXState` 仅暴露隐藏、零尺寸的 SwiftUI EmptyView 窗口及普通应用菜单；截图是无有效验证信息的微小空白窗口，未保留。有限树中未暴露阻塞权限弹窗，不能据此证明所有弹窗均不存在。状态栏图标、提醒浮层、焦点、首次点击及关闭浮层后菜单行为均未核验，也不能把日志中的 degraded 写成可见图标颜色。

以下为实际 `diagnostic.log` 的筛选摘录（UTC，省略其他行，不含听写内容）：

```text
[2026-11-01T11:17:19] [WindowManager] WARNING: Accessibility permission not granted
[2026-11-01T11:17:19] [WindowManager] FAILED to create CGEvent tap (attempt 1)
[2026-11-01T11:17:19] [AppDelegate] Flowtype launched successfully
[2026-11-01T11:17:19] [AppDelegate] Qwen3-ASR model loading failed
[2026-11-01T11:17:20] [QwenASR] Model loaded successfully
[2026-11-01T11:17:20] [ModelProvision] Loaded offline from /Users/yiheng/Library/Application Support/Flowtype/models/aufklarer/Qwen3-ASR-1.7B-MLX-4bit (modelId=aufklarer/Qwen3-ASR-1.7B-MLX-4bit)
[2026-11-01T11:17:23] [ReadinessMonitor] level=degraded ax=denied mic=notDetermined local=ready cloud=unavailable apple=unavailable
[2026-11-01T11:17:24] [WindowManager] Event tap health action: waitForPermission
```

筛选命令：`rg '2026-11-01T11:(17|18|19|20):.*(ReadinessMonitor|WindowManager|AppDelegate|QwenASR|ModelProvision)' ~/Library/Logs/flowtype/diagnostic.log`。

初始 AppDelegate 失败消息先于异步加载成功，不构成 11:17:20 后仍加载失败的证据。观察窗口内只有一次 tap 创建失败，随后进入 `waitForPermission`；这仅支持该有限窗口无重复失败日志，不能证明长期稳定。

## 授权与运行中恢复续测（截至 12:00:25Z）

Owner 对候选 AX / 麦克风授予及临时关闭 / 恢复的具体批次请求回复「继续」，该同意已记录，无需重复请求；Speech 授权不在此批次。系统设置添加辅助功能条目要求本机 Touch ID / 管理员认证，Owner 自行完成并回复「加了」；代理未读取或输入密码。本次无重启，PID 75257 从初始启动持续运行；源代码、bundle、配置、密钥和模型均未改变。

系统辅助功能列表最初仅有一个 FlowType 条目且开关为开。CUA 经 Add→GoTo 完整候选路径→Open 后仍显示开；约 11:50Z 观察到关闭→开启，仍未见 tap 恢复。这些是在系统设置中的外部操作，未使用候选内「打开设置」或 recheck/watch 入口。19:53:18+0800 的只读进程采样显示主 RunLoop 空闲，实际重复 health timer 正在调用 `WindowManager.repairEventTap`→`PermissionHelper.checkAccessibility`→`event_tap_create`；因此，缺少新日志不能证明 timer 停止。采样 `/private/tmp/flowtype-m1-permission-sample.txt` 未提交。用户 TCC 数据库的有限查询被系统拒绝，未提权或修改数据库。

随后 CUA 选中该 FlowType 条目并 Remove，确认条目消失，再 Add→GoTo 精确候选路径→Open，条目重新出现且开启。移除的是授权条目，未删除应用或数据。同一进程出现以下实际 `diagnostic.log` 摘录（UTC，其他行省略）：

```text
[2026-11-01T11:55:49] [WindowManager] Event tap health action: recreate
[2026-11-01T11:55:49] [EventTap] CGEvent tap created and enabled successfully
[2026-11-01T11:55:54] [WindowManager] Event tap health action: none
```

这是运行中 tap 恢复的直接证据。授权发生时刻没有足够精度的记录，不能声称 grant→恢复实测 ≤5s；两条 health 日志相隔五秒不等于授权延迟。顺序支持「旧授权条目 / 身份不匹配」的解释，但这只是推断，未验证底层 TCC csreq。至 12:00:25Z 未观察到新的 ReadinessMonitor ready / snapshot 转换日志；启动的 60s 权限 watch 早已结束，应用内 Settings / recheck 入口未执行。正常图标、权限确认卡片、提示音及整体 UI ≤5s 恢复均未证实，也不能据此确立源代码缺陷或修复结论。

已通过 Finder / TextEdit 打开独立空白 `/private/tmp/flowtype-m1-scratch-XXXXXX.txt`，CUA 确认其文件名与空文本框，未读取旧 M0 或私人文档。CUA 的纯修饰键 `pressKey('super')` 被拒绝（`keyPressIncludedNoNonModifierKeys`），没有发出热键；已请 Owner 在空白 scratch 中物理双击 Command，若出现麦克风提示则选「不允许」并回报。截至本记录尚无 Owner 结果、实际候选录音 / 会话或权限提示观察；代理未改变麦克风设置。后续完整热键 / UI / 麦克风测试仍待该物理操作。

候选仍仅暴露隐藏零尺寸根窗口，关闭按钮操作失败（`screen capture size is invalid (0.0,0.0)`）；SystemUIServer getApp 超时。可见状态菜单 / 卡片 / 焦点仍未建立证据，没有留存能验证产品行为的截图。这些是自动化限制，不是产品失败。

## 用例结果与证据缺口

共同环境、日期、SHA、路径及初始权限见上文；当前已知辅助功能条目为精确候选重建后开启，麦克风尚无新的探测 / 操作结果。除列明的启动与授权恢复部分观察外，其余用例操作未执行，没有完整真机通过或失败结论。

| 用例 | 状态 | 实际事件顺序 / 与期望的差异 | 尚需执行 |
| --- | --- | --- | --- |
| M1-1 无 AX 启动 | Pending（部分） | 启动→tap 创建失败→本地模型加载成功→degraded→waitForPermission。依 spec §4.1 / classifier，有可用本地引擎而缺 AX 时应 degraded，覆盖 brief 中无条件红色 blocked 的表述。 | 核验可见图标、修复菜单项、无阻塞弹窗、提醒浮层、关闭后菜单、焦点和首次点击。 |
| M1-2 热键可用但无引擎 | Pending | 当前为 localOnly 且本地模型 ready，未建立 AX 已授予 / auto / 无引擎场景。 | 可逆地建立无引擎场景；核验立即 error、「打开 ASR 设置 / 重新检测」，无 RecordingStage 启动、无 processing。 |
| M1-3 运行中授权 | Pending（部分） | 同一 PID，授权条目移除并以精确候选重建→11:55:49Z tap recreate / 创建成功→11:55:54Z none；未测授权延迟，未观察 ready 快照 / UI，未触发真实热键。 | 实测授权后 ≤5s 恢复要求，核验正常图标、可见确认、提示音及 Owner 物理 Command 热键开始。 |
| M1-4 麦克风被拒绝 | Pending | mic 仅探测为 notDetermined；未拒绝、授权、跳设置或录音。 | 核验拒绝卡片的「打开麦克风设置 / 重新检测 / 忽略」、正确设置面板、重授后卡片消失及新会话录音。 |
| M1-5 受限策略下无引擎 | Pending | localOnly 已选，但本地引擎可用；当前无云端配置，不满足云端恢复前提。 | 可逆地建立无引擎并拒绝 Speech 场景；核验立即 error、「打开 ASR 设置 / 改为自动路由 / 忽略」、auto 持久化；仅在已有可用云端配置时核验恢复。全程无录音、无 processing。 |
| M1-6 无 AX 菜单听写 | Pending | AX denied 启动仅部分观察；续测 AX 条目已重建并开启，仍未通过无 AX 菜单录音 / 停止、交付或粘贴。 | 在已同意的权限批次中建立无 AX 场景，使用合成 scratch 输入核验菜单操作、已复制提示及 TextEdit 内容完整性；不记录原文。 |
| M1-7 状态变化不闪断 | Pending（部分） | 离线模型加载成功后日志为 degraded；未观察 UI 的 downloading / loading 转换或终态失败。 | 核验菜单首项 / 图标转换，ready 或 error 后 3s 内稳定，无 blocked 闪烁或卡死。 |

## 已有自动化及源代码审查证据

控制器已在同一逻辑任务中依次执行，之后源代码未变；本次仅写观察文档，未重跑构建、自测或新增 TDD：

1. `swift build`：exit 0，`Build complete! (25.17s)`，日志 `/private/tmp/flowtype-m1-final-build.log`。
2. `swift run FlowType --self-test`：exit 0，`=== self-test: 1318 passed, 0 failed ===`，日志 `/private/tmp/flowtype-m1-final-selftest.log`。

存在已跟踪的 `AppLogger.swift:27` 无关警告，不声称编译输出无警告。以上为已有自动化记录，不能把它写成七项真机用例通过。

Tasks 4–14 已逐项审查。最终广泛源码审查的两个 Important 问题（过期 Stop 显示可能启动新录音、终态本地加载失败表现为无限 provisioning）已在 `2d0eca9` 修复；限定范围复审接受，无新增 Critical / Important 破坏。详见工作区 `final-review.md`、`final-fix-report.md`、`final-rereview.md`。非阻塞遗留项：没有空闲网络路径订阅（菜单 / preflight 刷新正确）；另一 blocker 仍在时 recheck 可能保留先前原因；旧 Settings 权限文案。M2–M5 不在本次范围。

## 下一步权限测试

固定候选已经构建并审查。Owner 已明确同意 AX / 麦克风授权及临时关闭 / 恢复批次，并完成所需本机认证；不重复请求这项同意。Speech Recognition 不在已同意范围，若测试需授予它，须按计算机使用工具策略另行取得动作时确认或由用户操作。本文仅记录控制器提供的结果，不执行权限变更。

当前先等待 Owner 在已准备的空白 scratch 中物理双击 Command 的结果；CUA 未能发送纯修饰键，不伪造热键、麦克风提示或录音结果。继续使用同一 bundle，补核 M1-1 可见 UI，再完成 M1-3、M1-4、M1-6 权限恢复及合成 scratch 会话；随后在约定的可逆环境下验证 M1-2 / M1-5 / M1-7。无引擎测试不得删除模型目录，不得改凭据或假设空云端可恢复。每项记录操作时间、权限前后状态、真实 session id（无会话则 N/A）、脱敏日志与期望差异，测试后恢复约定权限状态，并复查原安装版本是否需重新授权。仅实际执行且满足验收时才更新 P1 / P3；全部所需真机结果具备前，Task 15 与 M1 验收继续开放。
