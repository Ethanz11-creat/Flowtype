# M0 环境证据：辅助功能权限与 event tap 存活

- 日期：2026-10-22
- Tester：Owner（授予辅助功能权限并执行退出/重启），Controller 采集本文件中的命令输出
- 结论：**PASS** — 当前 `/Applications/FlowType.app` 已获得 Accessibility 授权，启动时成功创建 CGEvent tap，且 tap 正在实时接收按键事件。最新一次启动之后没有任何 `FAILED to create CGEvent tap`。

> 时间约定：应用日志（`diagnostic.log`）使用 UTC；`log show` / `ps` 使用本机时间（UTC+8）。例如 `12:55:08`（日志）与 `20:55:08`（系统）是同一次启动。

## 构建与签名身份

```console
$ git rev-parse HEAD
efab912bd9e368750dd22d1d7fc02047a96baf74

$ codesign -dv --verbose=4 /Applications/FlowType.app 2>&1 | rg 'Identifier|Authority|TeamIdentifier|Signature'
Identifier=com.flowtype.app
Signature=adhoc
TeamIdentifier=not set

$ stat -f '%Sm %N' /Applications/FlowType.app/Contents/MacOS/FlowType
Oct 22 18:37:09 2026 /Applications/FlowType.app/Contents/MacOS/FlowType
```

- App 路径：`/Applications/FlowType.app`（可执行文件为 arm64）
- Bundle 版本：`CFBundleShortVersionString = 1.0.0`，`CFBundleVersion = 1`
- 签名：adhoc（`Signature=adhoc`，`TeamIdentifier=not set`）——因此每次重新构建都会改变 cdhash，TCC 记录中的 code requirement 可能失配（见下文麦克风一节）。
- 系统版本：

```console
$ sw_vers
ProductName:		macOS
ProductVersion:		15.7.9
BuildVersion:		24G830
```

## 权限状态

### Accessibility（M0 关键项）：已授权

系统 TCC 日志显示 2026-10-22 20:54 的授权操作，以及 20:55:08 启动时 `com.flowtype.app` 的查询结果为 allowed：

```text
2026-10-22 20:54:41.558 tccd [com.apple.TCC:events] Publishing <TCCDEvent: type=Modify, service=kTCCServiceAccessibility, identifier_type=Bundle ID, identifier=com.flowtype.app>
2026-10-22 20:54:48.601 tccd [com.apple.TCC:events] Publishing <TCCDEvent: type=Delete, service=kTCCServiceAccessibility, identifier_type=Bundle ID, identifier=com.flowtype.app>
2026-10-22 20:54:55.214 tccd [com.apple.TCC:events] Publishing <TCCDEvent: type=Modify, service=kTCCServiceAccessibility, identifier_type=Bundle ID, identifier=com.flowtype.app>
2026-10-22 20:55:08.861 Df tccd [com.apple.TCC:access] AUTHREQ_RESULT: msgID=84353.2, authValue=2, authReason=4, authVersion=1, desired_auth=0, error=(null),
```

（`authValue=2` = allowed，`authReason=4` = 用户在系统设置中授权。20:54:48 的 Delete 是勾选过程中的一次移除，随后 20:54:55 重新授权。）

同一次启动还确认了 event tap 所需的另外两项：

```text
2026-10-22 20:55:08.697 kTCCServiceListenEvent AUTHREQ_RESULT: authValue=2, authReason=4
2026-10-22 20:55:08.863 kTCCServicePostEvent  AUTHREQ_RESULT: authValue=2, authReason=4
```

注意：TCC 日志中有一条 `attempted to call TCCAccessRequest for kTCCServiceAccessibility without the recommended com.apple.private.tcc.manager.check-by-audit-token entitlement` — 这是 adhoc 签名的非沙盒应用查询权限时的正常提示，查询结果仍为 allowed，不影响 tap 创建。

### 麦克风：当前构建下为「未确定」，需要重新授权

最近一次麦克风 TCC 预查询（2026-10-22 18:38:41 本机时间，即应用构建后首次启动）显示 code requirement 失配：

```text
2026-10-22 18:38:41.284 tccd [com.apple.TCC:access] Failed to match existing code requirement for subject com.flowtype.app and service kTCCServiceMicrophone
2026-10-22 18:38:41.284 tccd [com.apple.TCC:access] AUTHREQ_RESULT: msgID=73565.6, authValue=1, authReason=0, authVersion=1, ...
2026-10-22 18:38:41.291 tccd [com.apple.TCC:access] AUTHREQ_RESULT: msgID=179.1018, authValue=1, authReason=0, authVersion=1, ...
```

`authValue=1` = unknown / not determined。没有观察到之后的授权或拒绝记录。结合 adhoc 签名，这对 M0 无影响（tap 与权限基线不依赖麦克风），但 M0 Task 3 的「真实录音」步骤预计会在首次录音时弹出麦克风授权提示；如需提前确认，请 Owner 在系统设置 → 隐私与安全性 → 麦克风中确认 FlowType 已勾选。

### Speech（语音识别）：未在当前构建上重新验证

- 应用日志最后一次记录：`[2026-06-22T13:48:01] [AppleSpeechProvider] startStreaming: authStatus=3`（3 = authorized）。
- 最近 30 天的 TCC 日志中没有 `kTCCServiceSpeechRecognition` 与 `com.flowtype.app` 的记录（30 天内没有触发过该权限查询）。
- 结论：历史上已授权，但当前 adhoc 构建的 code requirement 是否仍然匹配未验证；AppleSpeech 只在录音预览/兜底路径使用，不影响 M0 的 tap 基线。

## Event tap 存活

最新一次启动（2026-10-22T12:55:08Z；本机 20:55:08，PID 84353，仍在运行）创建成功：

```text
[2026-10-22T12:55:08] [AppDelegate] Setting up global hotkey...
[2026-10-22T12:55:08] [WindowManager] setupGlobalHotkey called
[2026-10-22T12:55:08] [WindowManager] Cached triggerKey: Command, interactionMode: Tap to Start
[2026-10-22T12:55:08] [WindowManager] setupCGEventTap called
[2026-10-22T12:55:08] [EventTap] CGEvent tap created and enabled successfully
[2026-10-22T12:55:08] [WindowManager] Global hotkey registered (double-tap Command to start, single-tap to stop)
[2026-10-22T12:55:08] [AppDelegate] Flowtype launched successfully
```

对比同一文件中的上一次启动（2026-10-22T12:53:22Z，授权前）：

```text
[2026-10-22T12:53:22] [WindowManager] WARNING: Accessibility permission not granted
[2026-10-22T12:53:22] [WindowManager] setupCGEventTap called
[2026-10-22T12:53:22] [WindowManager] FAILED to create CGEvent tap
```

`12:55:08` 之后没有任何 `FAILED to create CGEvent tap` 或 `Accessibility permission not granted`。使用 brief Step 5 的完整筛选命令确认：

```console
$ rg -n "EventTap|FAILED to create CGEvent tap|Accessibility" ~/Library/Logs/flowtype/diagnostic.log | tail -n 40
...
11173:[2026-10-22T12:53:22] [WindowManager] WARNING: Accessibility permission not granted
11175:[2026-10-22T12:53:22] [WindowManager] setupCGEventTap called
11176:[2026-10-22T12:53:22] [WindowManager] FAILED to create CGEvent tap
11197:[2026-10-22T12:55:08] [WindowManager] setupCGEventTap called
11198:[2026-10-22T12:55:08] [EventTap] CGEvent tap created and enabled successfully
```

并且 tap 正在实时接收事件（说明不是只创建后失效）：

```text
[2026-10-22T13:02:56] [EventTap] Trigger key release suppressed (shortcut chord during hold)
[2026-10-22T13:03:30] [EventTap] Trigger key release suppressed (shortcut chord during hold)
[2026-10-22T13:03:31] [EventTap] Trigger key release suppressed (shortcut chord during hold)
[2026-10-22T13:03:31] [EventTap] Trigger key release suppressed (shortcut chord during hold)
[2026-10-22T13:03:44] [EventTap] Trigger key release suppressed (shortcut chord during hold)
[2026-10-22T13:03:54] [EventTap] Trigger key release suppressed (shortcut chord during hold)
[2026-10-22T13:03:55] [EventTap] Trigger key release suppressed (shortcut chord during hold)
[2026-10-22T13:03:55] [EventTap] Trigger key release suppressed (shortcut chord during hold)
```

进程确认：

```console
$ pgrep -fl FlowType
84353 /Applications/FlowType.app/Contents/MacOS/FlowType

$ ps -o pid,lstart,comm -p 84353
  PID STARTED                      COMM
84353 Thu Oct 22 20:55:08 2026     /Applications/FlowType.app/Contents/MacOS/FlowType
```

## 是否仍失败

否。授权后重启（brief Step 4）已在 2026-10-22T12:55:08Z 完成，日志已显示最新启动创建 tap 成功，因此本次核验没有再次重启应用。

## 备注 / 后续

- 当前构建只在启动时创建 tap；运行中授权不会自愈——这正是 M1 要实现的 `installEventTap` / `repairEventTap`。M0 基线以「授权后重启」为准。
- adhoc 签名意味着每次重新构建 app 都会改变 cdhash；M1 Task 15 必须沿用当前 `/Applications/FlowType.app` 身份，重新构建后需要重新确认 TCC 记录（尤其麦克风）。
- 本文件不含 API Key、配置 JSON 或听写内容。
