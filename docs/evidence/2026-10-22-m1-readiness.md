# M1 readiness 真机证据（部分记录）

记录日期：2026-11-01，时区 Asia/Shanghai；续测覆盖至修复候选 13:19:37Z 的 tap 恢复及随后待执行的 Owner 物理触发。本文依据控制器的 observations、runtime-continuation、panel-runtime-boundary、panel-fix-report、geometry-review 与 fixed-runtime 记录整理。基线 `2d0eca9` 的 M1-4 已出现实际卡片不可见 **Fail**；修复 `2588d56` 尚无真机可见通过结果。七项完整用例均未完成，P1 / P3 验证矩阵保持 Pending；文档、隐藏 AppKit 回归及源码审查不能替代真机验收。

## 历史基线候选与环境（2d0eca9）

- 代码：`2d0eca91e21177738d019a9bf6e9f35442b88e4c`（`fix(readiness): align menu commands and terminal model failures`），分支 `flowtype-local`。下述初始观察与首次拒绝测试均属于此历史基线；当前修复候选身份另列于后文。
- 设备：MacBook Pro，Apple M1，16 GB；macOS 15.7.9（24G830）。
- 构建：`./scripts/build-app.sh`，exit 0，93.19s；日志 `/private/tmp/flowtype-m1-release-fixed.log`。二进制 mtime：`2026-11-01T19:13:26+0800`，大小 51,110,704 bytes。
- 候选 bundle：`/Users/yiheng/pycode/flowtype-local/build/FlowType.app`（注意大小写）；本基线观察期间未重新构建，初始同进程恢复后因麦克风撤销测试退出，再按精确路径启动；之后诊断与修复候选分别构建，详见后文。
- `codesign -dv --verbose=4`：Identifier=`com.flowtype.app`，Signature=`adhoc`，TeamIdentifier=`not set`，无 Authority 行；CDHash=`295afde657b44498ff199325bac4fd3b733c36a6`。
- 二进制 SHA256：`26436213a835f1c5d74cb17ff2b57ce93198ebf413be21d23cc67f6cfef3b0f1`。
- `Contents/MacOS/mlx.metallib` 已打包，大小 146,852,000 bytes。

**签名限制：**`codesign --verify --deep --strict --verbose=2 build/FlowType.app` 返回 exit 1：`code object is not signed at all`，子组件为 `Contents/MacOS/mlx.metallib`。对 `/Applications/FlowType.app` 执行同一验证也同样失败。身份信息可读取、候选可启动，但深度签名验证失败，不能称签名完全有效；这是已有打包限制，本次未实施 M5 修复。

已安装应用在候选启动前通过 CUA 退出，二进制未替换，其原 CDHash 仍为 `de4d96988b5dcf15a896a38592ef3074cb53ee58`。续测中共享 `com.flowtype.app` 授权条目已为候选移除重建；后来 macOS 误重开原安装版本时出现旧 AX 引导，但未完整复查其未来权限状态，可能需重新授权。M0 中用户接受的是原安装应用 sessions #2 / #3（最新 stop→delivery 4233ms，本地 Qwen，无 fallback），不能转移为本候选的 M1 验收。

## 初始启动观察（11:17Z）

候选于 `2026-11-01T11:17:19Z`（本地 19:17:19）通过 CUA 按完整路径启动，PID 75257；3m26s 后观察进程仍存活。保持 `localOnly`，本地已有 `Qwen3-ASR-1.7B-MLX-4bit`；初始观察期间未改云端 ASR 设置或凭据，未授予或撤销 AX、麦克风、Speech Recognition 权限。后续 AX 变更见续测记录。

初始应用探测快照为 AX `denied`、mic `notDetermined`、local `ready`、cloud / Apple `unavailable`，readiness 为 `degraded`。这些是候选在初始观察时的应用探测结果，不能推定续测后的快照或所有安装身份的历史权限状态。初始观察无录音，session id 为 **N/A**；续测有真实候选 session **#1**，见下文，不引用 SelfTest 合成会话。

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

已通过 Finder / TextEdit 打开独立空白 `/private/tmp/flowtype-m1-scratch-XXXXXX.txt`，CUA 确认其文件名与空文本框，未读取旧 M0 或私人文档。CUA 的纯修饰键 `pressKey('super')` 被拒绝（`keyPressIncludedNoNonModifierKeys`），没有发出热键；已请 Owner 在空白 scratch 中物理双击 Command，若出现麦克风提示则选「不允许」并回报。截至 12:00:25Z 尚无 Owner 结果、实际候选录音 / 会话或权限提示观察；此阶段代理未改变麦克风设置。其后实际结果见下节。

候选仍仅暴露隐藏零尺寸根窗口，关闭按钮操作失败（`screen capture size is invalid (0.0,0.0)`）；SystemUIServer getApp 超时。可见状态菜单 / 卡片 / 焦点仍未建立证据，没有留存能验证产品行为的截图。这些是自动化限制，不是产品失败。

## 真实热键、麦克风与退出重启

Owner 回报「出现了麦克风授权请求，已拒绝」，但实际日志与「拒绝麦克风」的解释冲突，应同时保留。以下是实际诊断日志摘录（UTC，其他行省略，无听写正文）：

```text
[2026-11-01T12:01:22] [EventTap] Trigger key tap (clean press+release, trigger=Command)
[2026-11-01T12:01:22] [EventTap] Trigger key tap (clean press+release, trigger=Command)
[2026-11-01T12:01:22] [SessionController#1] startRecording requested
[2026-11-01T12:01:23] [RecordingStage#1] Recording phase started
[2026-11-01T12:01:25] AudioRecorder: mic request result = true
[2026-11-01T12:01:26] [AudioRecorder] Engine prepared and started successfully
[2026-11-01T12:01:26] [ReadinessMonitor] level=degraded ax=granted mic=notDetermined local=ready cloud=unavailable apple=unavailable
[2026-11-01T12:01:29] [RecordingStage#1] Recording in progress
```

真实 session **#1** 证实原 PID 75257 在 tap 恢复后处理了物理 Command 并启动采集，麦克风请求实际获准；不能据 Owner 回报将 M1-4 / P1 记为通过。12:01:26 的 mic `notDetermined` 是请求前的陈旧快照，不能称当前权限状态。可能拒绝的是另一个 Speech 提示，但未独立证实。未保留语音内容或听写正文，未声称成功识别或交付。

控制器在已确认空白 scratch 中尝试 CUA Escape，未出现取消日志；随后请求 Owner 物理 Escape，尚无回复。为停止持续采集并继续已同意的拒绝测试，控制器在真实麦克风设置页确认 FlowType 为 ON 后切至 OFF。macOS 明确提示退出前仍可访问麦克风，控制器选择「Quit and Reopen」。PID 75257 退出使采集结束；这是进程终止，不是已观察到的 Escape 取消，未导出录音结果，也不能声称撤销无需重启即可生效。

macOS 于 12:07:02Z 重开了 `/Applications/FlowType.app`（PID 79833），并非候选。CUA 看到旧阻塞式 AX 引导，选择 Later 后 CmdQ 退出；此观察不能归于 M1 候选。控制器随后按精确 build 路径重开候选：初始 CUA 状态捕获因隐藏 0×0 窗口失败，但进程列表及启动日志确认 PID **79953**、12:08:26Z 启动，tap 于 12:08:26Z 创建、模型于 12:08:28Z 离线加载。未重新构建，bundle / 二进制哈希保持不变，候选 AX 授权仍可用。

当时麦克风设置为 **OFF**，等待 Owner 再次物理双击 Command；后续实际拒绝启动及不可见失败见下节。PID 79953 是历史基线进程，不是当前修复进程。

## 基线实际失败与诊断续测

Owner 随后回报「现在双击没有弹出了」。在 `2d0eca9`、PID 79953 下，12:21:03 / 06 / 07 / 19Z 的四次物理双击 Command 分别到达 `startRecording requested`（#1…#4），未进入 RecordingStage。拒绝前置检查未能呈现可操作错误卡片，因此 M1-4 的可见行为为 **Fail**，不能继续仅写成未执行。卡片按钮、正确设置目的地及重新授权恢复均未验证。其后曾恢复 mic ON，但 OS 要求退出生效；下一轮诊断在应用退出时设为 OFF。

诊断提交 `a1a80de` 仅增加去重、无内容载荷的 preflight / panel 日志。早期隐藏真实面板检查在未修复前已通过，`hidesOnDeactivate` 实际为 false；泛化 NSPanel 默认值不能证明根因。另一个只断言 ordering API 选择的失败探针已被拒绝并移除，不计为有效回归 RED。

控制器构建诊断候选并按精确 build 路径于 12:49:39Z 启动 PID 96438（现已正常退出）。Owner 物理双击产生麦克风提示；日志在 13:00:12Z 实际记录 `mic request result = false`，控制器未自行点击拒绝，不能把拒绝动作归于特定操作者。本轮进入了准备 / RecordingStage 阶段，但无成功采集。关键实际日志（UTC，无听写内容）：

```text
[2026-11-01T12:58:57] [SessionController#1] startRecording requested
[2026-11-01T12:58:57] [WindowManager] show-ordered state=preparing visible=true alpha=0.0 frame={{673, 805}, {240, 70}} screenFrame={{-487, 900}, {2560, 1415}} panelScreen=true hidesOnDeactivate=false appActive=false appHidden=false
[2026-11-01T12:58:57] [RecordingStage#1] Recording phase started
[2026-11-01T12:58:57] [WindowManager] show-complete state=preparing visible=true alpha=1.0 frame={{673, 805}, {240, 70}} screenFrame={{-487, 900}, {2560, 1415}} panelScreen=true hidesOnDeactivate=false appActive=false appHidden=false
[2026-11-01T13:00:12] AudioRecorder: mic request result = false
[2026-11-01T13:00:12] [WindowManager] show-request state=error visible=true alpha=1.0 frame={{673, 805}, {240, 70}} screenFrame={{-487, 900}, {2560, 1415}} panelScreen=true hidesOnDeactivate=false appActive=false appHidden=false
```

目标 `NSScreen.main.visibleFrame` 为 `(-487,900,2560,1415)`；240×70 胶囊应位于 x673，动画起点 y880、终点 y940。实际 ordered 与 complete 均为 `(673,805,240,70)`，顶部 y875 仍低于目标屏幕 minY900。alpha 已达 1、panel 非 nil 且 visible、app 未 hidden；这些日志支持具体跨屏几何偏差，不能将 `visible=true` 当作用户可见。error 请求因面板已被视为 visible 提前返回，没有重新定位。两个在线显示器未镜像；运行时 `NSScreen.main` 指向上方外屏，不能等同于 OS 主显示器或 `NSScreen.screens.first`。

## 几何边界、源码修复与限定审查

真实隐藏 AppKit 探针确认：新面板 `screen` 是内置屏 `(0,52,1440,823)`，而目标是上方外屏。未修改的 superclass `constrainFrameRect(_:to:)` 在传入旧内置屏时，把 y880 / y940 均约束成 **y805**，与 live 偏差一致；传入目标屏或普通隐藏 setFrame 操作保留原坐标。探针未显示或 order 窗口，未观测实际 ordering 的完整回调序列，因此不能称它完成可见验收。

源码修复 `2588d56 fix(panel): preserve capsule geometry across displays` 仅在 FloatingPanel 覆盖该约束以保留调用方指定的全局 frame，并增加隐藏真实 AppKit 回归。已有 WindowManager 屏幕选择、ordering、动画、拖动、resize / mask 和取消策略未改变。胶囊显式全局几何由调用方负责，不再使用旧屏的标题栏 / 顶边约束。

有效 RED：修复前自测实际 exit 1，**1323 passed / 4 failed**；240×70 的起点 / 终点被改为 y805，320×94 被改为 y781，四项均未保留期望 y880 / y940。其余五项新断言已通过。修复后顺序执行 `swift build`（exit 0，40.59s）及 `swift run FlowType --self-test`（exit 0，**1327 passed / 0 failed**）；日志为 `/tmp/flowtype-task15-geometry-build.log` 与 `/tmp/flowtype-task15-geometry-green.log`，RED 为 `/tmp/flowtype-task15-geometry-red.log`。回归同时覆盖 resize 中心 / origin / mask、非激活、不能成为 key / main、始终隐藏。不是只断言 API 选择的模拟测试，也不代表无 WindowServer 的 headless 验证。

限定源码审查 `a1a80de..2588d56` 结论为 spec compliant、quality **Approved**，无 Critical / Important；审查未重复构建或自测。真实应用的 ordering / 可见位置 / 非激活 / 拖动验收仍待执行。所有上述检查均为已有执行结果，本次文档更新未重跑。

## 当前固定修复候选（2588d56，等待 Owner）

以下以控制器 `task-15-fixed-runtime.md` 为当前权威快照：

- `./scripts/build-app.sh` exit 0，93.86s；日志 `/private/tmp/flowtype-m1-panel-geometry-release.log`。
- 精确路径 `/Users/yiheng/pycode/flowtype-local/build/FlowType.app`；adhoc，Identifier `com.flowtype.app`。
- 二进制 mtime `2026-11-01T21:17:57+0800`，大小 51,114,528 bytes；CDHash `2017c833bc9d3fad6fc08327101e907a506cfa31`。
- SHA256 `3ec43fb892ca6aa69bb1dd0a058d6c38f96ca14749dabf7374142b542d908dc2`。
- 13:18:12Z 按精确路径启动，PID **8002**；13:18:17Z 探测 AX denied、mic notDetermined、local ready。
- 在已授权批次内，CUA 为新身份替换 AX 条目；同一 PID 于 13:19:32Z recreate、13:19:33Z tap created、13:19:37Z health none。没有精确 grant 时刻，仍不声称 ≤5s。
- 新启动前系统 mic UI 为 OFF，但新身份探测为 notDetermined；不能仅根据 OFF 推定此进程已 denied。空白 TextEdit scratch 已聚焦，正在等待 Owner 物理双击 Command；如有初始麦克风提示则拒绝，并确认当前屏幕卡片。

当前固定进程尚未开始采集，修复后卡片实际可见性仍 **Pending**。release 保留 AudioDevice、AudioRecorder、AppleSpeechProvider、DownloadSource、ModelLocator、ProviderEditSheet、AppLogger 的已有警告，不声称仅有 AppLogger 警告或无警告。旧 deep / strict 签名限制未修复；本次没有新的 deep 验证结果，不能从身份可读或可启动推导签名完整有效。后续 live run 不应再次构建改变身份。

## 用例结果与证据缺口

共同环境与各轮候选身份见上文；当前为修复候选 PID 8002，tap 已恢复、mic 探测 notDetermined。M1-3 的真实采集对应基线 PID 75257 的 session #1；诊断 PID 96438 的 #1 未成功采集，修复进程尚无会话。无会话则记 N/A。基线 M1-4 的可见失败保留，七项完整验收均未完成。

| 用例 | 状态 | 实际事件顺序 / 与期望的差异 | 尚需执行 |
| --- | --- | --- | --- |
| M1-1 无 AX 启动 | Pending（部分） | 启动→tap 创建失败→本地模型加载成功→degraded→waitForPermission。依 spec §4.1 / classifier，有可用本地引擎而缺 AX 时应 degraded，覆盖 brief 中无条件红色 blocked 的表述。 | 核验可见图标、修复菜单项、无阻塞弹窗、提醒浮层、关闭后菜单、焦点和首次点击。 |
| M1-2 热键可用但无引擎 | Pending | 当前为 localOnly 且本地模型 ready，未建立 AX 已授予 / auto / 无引擎场景。 | 可逆地建立无引擎场景；核验立即 error、「打开 ASR 设置 / 重新检测」，无 RecordingStage 启动、无 processing。 |
| M1-3 运行中授权 | Pending（部分） | 同一 PID 75257，重建授权条目→11:55:49Z tap 创建成功→11:55:54Z none→12:01:22Z 真实 Command / session #1→12:01:26Z 采集启动；未测授权延迟，未核验完整 UI / 提示音。 | 实测授权后 ≤5s 恢复要求，核验正常图标、可见确认及提示音。 |
| M1-4 麦克风被拒绝 | Fail（基线可见行为）；修复复测 Pending | 基线 PID 79953 四次物理触发均无卡片、无 RecordingStage；诊断 a1a80de 记录 mic false 与位于目标屏下方的 error panel。2588d56 源码修复及隐藏回归通过，固定应用尚未验证可见性。 | Owner 触发当前 PID 8002，核验目标屏卡片、「打开麦克风设置 / 重新检测 / 忽略」、正确设置面板、重授后消失及新会话录音；保留基线 Fail 历史。 |
| M1-5 受限策略下无引擎 | Pending | localOnly 已选，但本地引擎可用；当前无云端配置，不满足云端恢复前提。 | 可逆地建立无引擎并拒绝 Speech 场景；核验立即 error、「打开 ASR 设置 / 改为自动路由 / 忽略」、auto 持久化；仅在已有可用云端配置时核验恢复。全程无录音、无 processing。 |
| M1-6 无 AX 菜单听写 | Pending | AX denied 启动仅部分观察；续测 AX 条目已重建并开启，仍未通过无 AX 菜单录音 / 停止、交付或粘贴。 | 在已同意的权限批次中建立无 AX 场景，使用合成 scratch 输入核验菜单操作、已复制提示及 TextEdit 内容完整性；不记录原文。 |
| M1-7 状态变化不闪断 | Pending（部分） | 离线模型加载成功后日志为 degraded；未观察 UI 的 downloading / loading 转换或终态失败。 | 核验菜单首项 / 图标转换，ready 或 error 后 3s 内稳定，无 blocked 闪烁或卡死。 |

## 已有自动化及源代码审查证据

以下是基线 `2d0eca9` 已有顺序验证；之后新增诊断与几何修复的结果见上文。本次仅写观察文档，未重跑构建、自测或新增 TDD：

1. `swift build`：exit 0，`Build complete! (25.17s)`，日志 `/private/tmp/flowtype-m1-final-build.log`。
2. `swift run FlowType --self-test`：exit 0，`=== self-test: 1318 passed, 0 failed ===`，日志 `/private/tmp/flowtype-m1-final-selftest.log`。

上述基线检查有已跟踪的 `AppLogger.swift:27` 无关警告；当前 release 的多处既有警告另见上文。以上均不能写成七项真机用例通过。

Tasks 4–14 已逐项审查。最终广泛源码审查的两个 Important 问题（过期 Stop 显示可能启动新录音、终态本地加载失败表现为无限 provisioning）已在 `2d0eca9` 修复；限定范围复审接受，无新增 Critical / Important 破坏。详见工作区 `final-review.md`、`final-fix-report.md`、`final-rereview.md`。非阻塞遗留项：没有空闲网络路径订阅（菜单 / preflight 刷新正确）；另一 blocker 仍在时 recheck 可能保留先前原因；旧 Settings 权限文案。M2–M5 不在本次范围。

## 下一步权限测试

固定候选已经构建并审查。Owner 已明确同意 AX / 麦克风授权及临时关闭 / 恢复批次，并完成所需本机认证；不重复请求这项同意。Speech Recognition 不在已同意范围，若测试需授予它，须按计算机使用工具策略另行取得动作时确认或由用户操作。本文仅记录控制器提供的结果，不执行权限变更。

当前等待 Owner 在固定修复候选 `2588d56`、PID 8002 下物理双击 Command，若出现初始麦克风提示则拒绝，并回报当前屏幕卡片；mic UI OFF 与进程 notDetermined 的区别见当前快照。CUA 未能发送纯修饰键，不伪造卡片、设置跳转或恢复结果。控制器先验证修复后实际位置、非激活与拖动，再继续 M1-4 按钮和恢复，补核 M1-1 可见 UI、M1-3 与 M1-6 权限恢复及合成 scratch 会话；随后在约定的可逆环境下验证 M1-2 / M1-5 / M1-7。无引擎测试不得删除模型目录，不得改凭据或假设空云端可恢复。每项记录操作时间、权限前后状态、真实 session id（无会话则 N/A）、脱敏日志与期望差异。控制器测试后恢复约定权限状态（含麦克风 ON）、记录 OS 重启要求，并复查原安装版本是否需重新授权。仅实际执行且满足验收时才更新 P1 / P3；全部所需真机结果具备前，Task 15 与 M1 验收继续开放。
