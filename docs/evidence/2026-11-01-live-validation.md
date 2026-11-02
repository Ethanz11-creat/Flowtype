# 主线 V：真实环境验收

日期：2026-11-01。执行负责人：开发控制器；物理热键、拔麦和本机认证由
Owner 操作。该工作包与 M2–M5 交叉执行，全部必需项通过是 M5 退出条件。
这是一份执行清单，当前未执行的变体保持 Pending，不以自动化回归替代。

现有认可：Owner 接受了 M0 原安装应用的真实 TextEdit 听写，也确认本轮
修复候选恢复后正常使用。M1 麦克风拒绝卡片截图、正确设置目的地及
重启后 ready 已有观察。这些证据不能推广到下表的其他应用、服务和设备。

| ID | 必需环境 / 操作 | Pass 条件 | 当前状态 |
| --- | --- | --- | --- |
| V1.1 | 已有合法云端配置；正常网络，以短合成参考句录音并停止 | 记录实际服务/协议、final信号、唯一结果和交付，密钥不进证据 | Pending |
| V1.2 | 同一参考句；受控弱网/服务慢响应，auto 且本地模型ready | 云端等待有界，完整录音本地回退，单次final，分别记录stop→final与stop→delivery | Pending |
| V1.3 | 分别在开始前与录音中断网，再恢复 | 开始前离线不发云请求；中途断网完整回退，无重复/迟到交付；下一轮恢复可用 | Pending |
| V2.1 | TextEdit、VS Code/Cursor、Chrome文本框、Terminal/Ghostty；中文、英文、多行合成输入 | 逐应用核对完整首尾、字面量、只写入一次、正确目标；终端不误提交命令 | Pending（TextEdit已有Owner认可，尚未覆盖全部变体） |
| V2.2 | 合成输入；录音/处理中切到另一个测试输入框、非文本控件、安全输入框 | 按当前交付合同处理目标变动；安全/非文本不发键，有完整可恢复文本；不得自动重试不确定交付 | Pending |
| V3.1 | 测试者创建的文字、图片、文件、RTF剪贴板，逐一听写交付 | 支持的表示完整保留；无法无损快照时拒绝覆盖或明确恢复；不损坏原数据 | Pending |
| V3.2 | 粘贴事务开始后测试者再次复制另一合成值；分别取消和正常结束 | 不覆盖新复制内容；所有权丢失有诚实结果，无重复发送 | Pending |
| V4.1 | preparing/recording/ASR/polish/injection 各阶段分别Escape；随后等候超过提供者deadline | 资源收尾、idle、未发出的结果不交付、不写历史；已发出的事件边界单独记录 | Pending |
| V4.2 | 取消慢会话后开始新会话，再让旧回调返回；快速重复停止 | 旧结果不能改变新会话；无重复文本/历史、无计时器残留 | Pending |
| V5.1 | USB/蓝牙麦克风已连接并选定；录音中拔出/断开 | 在既定心跳检测窗口内显式报错并释放资源；无永久recording/processing；重新连接后新会话可用 | Pending（需外接设备与物理操作） |
| V5.2 | 默认麦克风和用户指定麦克风分别做短句；设备失效后重试 | 实际输入设备与设置一致；失败原因可理解，不把静音伪装成功 | Pending |

## 执行规则

- 固定产品源码 SHA、bundle路径/二进制身份后执行一组测试；中途不重建。
- 每项记录日期、macOS/硬件、应用版本、权限前后、路由/交付模式、真实sessionID、
  事件次序、脱敏计时、最终文本完整性/次数、结果和未覆盖变体。
- 原始参考句仅用合成文本；不提交真实音频、私人转写、前台上下文或密钥。
- 按需采集截图；不能从“事件已发出”推定目标实际写入。
- 不删除模型、不清应用URL缓存、不读取/改写凭据以制造失败。
- 网络/权限/设备测试结束后恢复原状态；避免OS按bundleID重开旧安装版本，
  重启后核对精确进程路径。没有设备或云配置时写明前提，不伪造Pass。
- 各项测试按所需授权执行；本会话已有AX/麦克风批次授权持续有效，新权限、
  云端费用或其他新增范围仍需按实际动作边界处理。

## 每次结果模板

```text
Case / variant:
Pass | Fail | Pending:
Tester / UTC / source SHA / bundle identity:
macOS / device / target app version:
Route / delivery mode / permission before→after:
Session ID / observed event order / timings:
Completeness / delivery count / history count:
Content-free evidence:
Deviation / remaining prerequisite / restored state:
```

协议细节继续沿用 [实时ASR矩阵](../2026-10-14-realtime-asr-validation.md)；
会话与交付变体沿用 [产品矩阵](../2026-10-14-flowtype-product-validation.md)。
本文件将它们收束为必做工作包，不取代更细的既有测试步骤。

## M2 收口时的执行前提（2026-11-02）

V1–V5 仍是必做主线，所有表中 Pending 保持不变。此前 Owner 的 TextEdit/麦克风认可仅适用于当时 M0/M1 源码，不能推广为当前 M2 验收。
旧进程 PID 10836 对应 M1 源码 2588d56；B-only 的 6fc1973 release bundle 曾成功构建但未启动，不是当前 M2-C 证据。
控制器此前 CUA 返回 `cgWindowNotFound`；本次重新读取 inventory 仍无匹配的 FlowType / TextEdit / Finder / System Settings / Activity Monitor 原生窗口，浏览器 host 亦不可用。
未以 AppleScript、shell 或盲操作替代 GUI，也未重启、退出或改用户配置。待源码稳定后由控制器串行构建最终 bundle，重试 CUA 并核对源码/二进制身份。

| 主线 | 环境前提 | Owner 物理动作 / 控制器职责 | 当前状态 |
| --- | --- | --- | --- |
| V1 云端 | 已授权有效配置、实际服务、可控正常/弱网/断网条件，本地兜底已加载 | Owner 提供本机认证/网络条件；控制器记录真实服务、协议与单次交付 | Pending；不以无凭据变体作 Pass |
| V2 跨应用 | 可用桌面与各测试应用文本框、AX 权限 | Owner 执行物理热键/合成短句；控制器 CUA 核对目标和完整文本 | Pending；旧 TextEdit 认可不覆盖新 M2 或其他应用 |
| V3 剪贴板 | 测试者创建的多类型合成剪贴板与并发复制 | Owner 触发另一次复制；控制器核对所有权及完整恢复 | Pending |
| V4 取消 | 可进入各阶段的可用模型/服务与桌面 | Owner 在阶段执行 Escape；控制器核对超时后旧回调及新会话 | Pending |
| V5 设备 | 实际 USB / 蓝牙麦克风和可用权限 | Owner 拔出/断开/重连设备；控制器记录选定设备、错误与恢复 | Pending；无设备不是 Pass |

M2-C 的 Qwen 0.6B/1.7B × 4/8-bit 与 Whisper 各图规模、量化和硬件分别验收：断网导入→静态预览→成功加载→合成短句实际落字、超过引擎窗口首尾完整性、取消与恢复、切回内置预设。
当前仅有 Qwen 1.7B 4-bit 的实际静态检测和公开 Whisper tiny tokenizer-only 检查，均不构成完整图加载或推理 Pass。完整 Whisper 模型/设备未验证，全部真实推理变体 Pending。

补充窄证据：2026-11-01T19:49:34Z 控制器以 C3 63db2e9 的精确检测源码再次对现有 Qwen 1.7B MLX 4-bit 静态检查 PASS（packed-U32 保守预留 860225536 bytes，大小/指纹未变）。这仍不是运行加载、实测内存或落字验收，不改变上述 Pending。


## M2 source closeout — 2026-11-02

M2 product source **3a34a51** passed independent whole-M2 source review and scoped fixes; sequential build/full self-test is **2430/0**. Final development bundle was rebuilt with the identity in [M2 evidence](2026-11-01-m2-validation.md). Exact-path CUA activation still returns `cgWindowNotFound`; current-binary GUI and real delivery cannot be observed. This source gate does not change any V1–V5 Pending cell above. Full model and service/device variants retain their prerequisites and Owner physical-action requirements. Selected evidence is retained in the [durable archive](2026-11-01-m2-artifacts/README.md).

## M3-A Task3 source stage — 2026-11-02

Task3 adds honest delivery wording and an injected recent-delivery menu, with
synthetic controller/session-effect tests for once-only history/summary, open-menu
updates, quiet cancellation and stale results. Current stage evidence is in the
[M3 record](2026-11-02-m3-validation.md). Automatic mode is the new default;
explicit Unicode/legacy selections remain preserved. This stage operated no GUI,
real pasteboard, permissions, microphone, model, service or user configuration.
The controller defers app packaging and real-app execution until stable final
M3 source after B. All V1–V5 Pending cells remain unchanged; source tests cannot
confirm insertion or consumption within the unchanged 150ms restore window.

## M3-B Task2 source stage — 2026-11-02

The production ASR stage now performs full-recording silence preflight before
recognition and Apple-preview fallback. Synthetic real-controller tests cover
no history/delivery/health effects, live cancellation without finalize, consumed
stop budget, retry and old-result ownership. See the [M3 source record](2026-11-02-m3-validation.md).
These are source tests with isolated settings and fake external boundaries;
no current-bundle GUI, microphone calibration, cloud billing, network disruption,
permission change or device action was performed in this task. Existing realtime
capture may already have uploaded audio; zero upload/zero cost is not claimed.
All V1–V5, five-application delivery, continuous 20-round stability and actual
quiet/short/delayed-speech versus silence/noise cases remain **Pending** until the
controller fixes final reviewed source/bundle identity and executes those cases.

M3 最终源码更新：`f7554ee`，顺序 build/full 4124/0；全 M3 的分块回退和发键后取消两项 Important 已修复、限定复审关闭。最终 app 已构建；资源深度签名仍有既有 unsigned mlx.metallib 限制。[归档与产物身份](2026-11-02-m3-development/README.md)。本轮没有桌面工具/实际服务/物理设备验收，所有对应主线 V 项保持 Pending，不以合成回归关闭。
