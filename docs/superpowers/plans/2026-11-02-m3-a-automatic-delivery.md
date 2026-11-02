# M3-A Automatic Delivery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不损坏剪贴板、不重复派发的前提下，提供默认粘贴的自动交付与一次受控键入回退。

**Architecture:** 复用停止时 DeliveryTargetSnapshot、decideDelivery 和 ClipboardTransaction；纯策略只选方式，InjectionStage 持有唯一尝试并执行回退。SessionContext 在现有取消锁中分开记录 effect 与实际键盘 event；最近交付摘要只从有效终态发布。

**Tech Stack:** Swift 6.2、macOS 15+、AppKit/AX/NSPasteboard/CGEvent、SwiftUI、现有 self-test 与 GRDB 历史字段。

**Spec:** [M3 设计 §3–4、§6](../specs/2026-11-02-m3-delivery-and-silence-design.md)。基线 `b64d538`；旧的 `2026-10-14-delivery-accuracy.md` 是已经实现的资产，不能重新执行其任务。

**Status:** 三项源码及全 A 阶段审查完成；全 M3 审查追加修复 `f7554ee`（分块回退逐键对复检、当前会话取消时按事件证据建立 uncertain），限定复审通过，完整自测 4124/0。最终 app 已构建；严格资源签名的既有 metallib 限制及真实验收仍保留。源码步骤已勾选，真机 Step5 未勾选，详见[验证记录](../../evidence/2026-11-02-m3-validation.md)。

## Global Constraints

- Swift 6.2、macOS 15+；不新增/升级依赖，不下载 VAD 模型，不运行 Python 或转换脚本。
- 单一 SessionController / SessionContext 生命周期；旧 session 的迟到结果不能发布 UI、历史或交付。
- 音频扫描与 AX IPC 不阻塞 MainActor；取消检查贯穿所有等待与副作用边界。
- 不重置 deliveryAttempted，不自动重发 uncertain，不把 dispatched 写成已确认插入。
- 保留 changeCount + 完整表示快照的剪贴板所有权；不覆盖用户在事务中新增的复制内容。
- 不改变 M2 模型选择、active/captured lease、云端厂商配置和离线合同。
- 只用合成音频/文本、假提供者/剪贴板、隔离配置作自动测试；真机状态单列。
- 使用 `swift build` 后顺序执行 `swift run FlowType --self-test`，不运行 `swift test`；源码稳定后再构建 app。
- 保留分支/worktree，不 push、不 merge，不修改真实配置、权限、用户模型或缓存。

## Review Focus

- 临时写板后恢复且结果为 notDispatched，仍须允许安全回退，不能靠重置 latch；Task 2 覆盖真实事务路径。
- 图片/文件/RTF 无法完整快照，回退键入也失败：原板必须保留，不能转入破坏性 copy；Task 2 覆盖。
- 回退期间切焦点、变 secure、撤销 AX 或取消：不能在新目标继续输入；Task 2 覆盖等待边界。
- 明确保存的 legacy 模式、缺键/损坏值及 Picker 选中项不能静默改变；Task 1/2 覆盖迁移与呈现。
- 旧会话迟到、静音/未派发取消、菜单已打开：最近交付摘要保持真实且不含转写；Task 3 覆盖。

## File Structure

| 文件 | 职责 |
| --- | --- |
| 新增 `Sources/flowtype/Services/Delivery/DeliveryPolicy.swift` | DeliveryMode（从 KeyboardInjector 搬移）、DeliveryMethod、纯方式/回退判定 |
| 修改 `Services/KeyboardInjector.swift` | 保留原剪贴板事务；真实按键通过 event gate；不复制第二套事务 |
| 修改 `Core/Pipeline/SessionContext.swift` | 现有同一取消锁内新增实际按键标记，保留旧 effect/attempt 语义 |
| 修改 `Core/Pipeline/Stages/InjectionStage.swift` | 单次策略快照、回退复检、受保护板失败恢复 |
| 修改 `Core/Configuration.swift`、`Settings/SettingsPage+Recording.swift` | automatic 默认/解码、旧值兼容、三值 Picker 与说明 |
| 新增 `Services/Delivery/LastDeliverySummary.swift` | 无内容的摘要与纯菜单文案 |
| 新增 `App/LastDeliveryMenuController.swift` | 可注入 SessionController 的菜单项与同步订阅，供无真实窗口测试 |
| 修改 `Core/PipelineOrchestrator.swift`、`App/StatusBarController.swift` | 有效终态发布、菜单读取、诚实 uncertain 文案 |
| 新增 `Testing/M3DeliverySelfTests.swift`；修改 `Testing/SelfTest.swift` | 真实 stage/transaction/controller 组合回归及旧默认断言更新 |
| 更新 `docs/evidence/2026-11-02-m3-validation.md`、主线 V / 产品矩阵 | 源码与真机证据分列 |

生产路径前缀均为 `Sources/flowtype/`。不要拆解整个 orchestrator、改数据库或顺手实现 M4/M5。

### Task 1: 纯交付策略与兼容模式

**Files:** Create `Services/Delivery/DeliveryPolicy.swift`, `Testing/M3DeliverySelfTests.swift`; Modify `Services/KeyboardInjector.swift`, `Testing/SelfTest.swift`。

**Interfaces:**

- 产生 `enum DeliveryMode: String, Codable, Sendable { case automatic, unicode, pasteInSupportedApps }`，保留 `usesPaste(bundleID: String?) -> Bool`；automatic 不按目录限制，legacy 六项目录不变。最终安全性由策略/目标检查决定，不能仅调用 usesPaste 发键。
- 产生 `enum DeliveryMethod: Equatable, Sendable { case paste, type, clipboard }`。
- 产生 `resolveDeliveryMethod(mode: DeliveryMode, signals: FocusSignals, accessibilityTrusted: Bool, bundleID: String?) -> DeliveryMethod`，实现 spec §4.1 阶梯；目标身份由 Task 2 在调用前用 decideDelivery 核验。
- 产生 `canFallbackToTyping(mode: DeliveryMode, pasteResult: PasteTransactionResult, eventDispatched: Bool, target: DeliveryTargetSnapshot?, current: DeliveryTargetSnapshot, accessibilityTrusted: Bool) -> Bool`。仅 automatic + unsafeSnapshot/notDispatched + 无按键 + decideDelivery==inject + trusted + 明确 editableText 为 true。
- 测试入口 `M3DeliverySelfTests.policy(_ r: SelfTest.Reporter)`；新 `--m3-delivery-only` 调用它，后续任务追加同一入口的 runtime/presentation 检查；完整 suite 也必须调用。

- [x] **Step 1: 写纯策略 RED 测试并接入 focused runner。** 对三模式覆盖 secure/nonText/noAX → clipboard；automatic editable/blind + unknown/nil bundle → paste；unicode → type；legacy 六项 → paste、Terminal/nil → type。回退表覆盖所有六种 PasteTransactionResult × event true/false；focus/PID 改变、blind、无权限、legacy 一律 false。代表断言：

```swift
r.eq(resolveDeliveryMethod(mode: .automatic,
    signals: .init(secureInputActive: false, focus: .blindOrUnknown),
    accessibilityTrusted: true, bundleID: "test.unknown"), .paste,
    "automatic permits initial paste for same-target AX blind apps")
// 使用相同目标构造 fallback，editable+notDispatched 为 true；blind 为 false。
```

- [x] **Step 2: 运行 `swift run FlowType --self-test --m3-delivery-only`。** 记录缺失 API/策略断言的 RED；不得以替换一个已异步的 fake 代替真实判定。
- [x] **Step 3: 搬移 enum，按上述接口实现纯策略。** 此任务暂不切换 Configuration 默认，避免 stage 尚未接线就切用户行为；不重复角色集或目标核验逻辑。
- [x] **Step 4: 运行 focused GREEN，再顺序 `swift build`、`swift run FlowType --self-test`。** exit 均为 0、无失败；旧默认断言此时仍是 unicode。记录日志与源身份。
- [x] **Step 5: 提交 `feat(delivery): define automatic delivery and safe fallback policy`，做该任务源码审查。**

### Task 2: 自动默认、真实事务回退与取消

**Files:** Modify `Services/KeyboardInjector.swift`, `Core/Pipeline/SessionContext.swift`, `Core/Pipeline/Stages/InjectionStage.swift`, `Core/Configuration.swift`, `Settings/SettingsPage+Recording.swift`, `Testing/M3DeliverySelfTests.swift`, `Testing/SelfTest.swift`。

**Interfaces:**

- 消费 Task 1 的 DeliveryMethod / canFallbackToTyping 与现有 ClipboardTransaction.paste。
- 同一个 `DeliveryGateState` 新增 `eventStarted: Bool`；产生 `nonisolated var deliveryEventStarted: Bool` 与 `nonisolated func performDeliveryEvent(_ action: () -> Void) -> Bool`。后者在现有取消锁内、确认 active 后同时设置 effectStarted/eventStarted 再执行平衡按键对。
- `KeyboardInjector.postIfActive(context:action:)` 保留签名，改走 event gate；ClipboardTransaction 的临时板写入继续走 performDeliveryEffectIf。不要将任何普通写板伪装成实际按键。
- InjectionStage 内产生 `private func typeText(_ text: String, context: SessionContext, preserveClipboardOnFailure: Bool, start: Date) async -> StageResult`，集中现有键入结果/失败处理；完整取消与外层 complete 语义须对照 spec，不能仅替换 catch 条件。
- 继续保留现有注入 seam；`execute` 仅一次 beginDeliveryAttempt，模式快照一次；回退前新取 currentTarget/trusted，调用 canFallbackToTyping。
- Configuration 默认和缺省/未知 deliveryMode 解码变为 `.automatic`；显式旧值原样 round-trip。Picker 对应三项 exact 文案见 spec §4.1。
- 测试入口增加 `@MainActor static func runtime(_ r: SelfTest.Reporter) async`，使用独立 fake board/事件日志，禁止真实剪贴板或 CGEvent。

- [x] **Step 1: 添加行为 RED，先运行 focused runner。** 现有 enum 已存在，默认 automatic、notDispatched→键入、unsafeSnapshot→键入等必须是行为失败。至少锁定：

```swift
r.eq(Configuration().deliveryMode, .automatic, "new default")
r.eq(try JSONDecoder().decode(Configuration.self, from: Data("{}".utf8)).deliveryMode,
     .automatic, "missing mode migrates")
// 用真实 InjectionStage+ClipboardTransaction，原板含 public.rtf、图像及文件类型 Data。
r.eq(events, ["paste-preparation", "type"], "no paste event permits one typed fallback")
r.eq(board.contents(), original, "fallback never replaces protected clipboard")
```

写板后、发键前的取消用受控 continuation/屏障定位，避免依赖固定 sleep。用 fake board 实际先清空/部分写入、返回 succeeded=false，再成功恢复原板，覆盖真实事务的 notDispatched，eventStarted 必须为 false；另用真实 SessionContext gate 单独验证 effect=true 不代表 event=true。成功写板后发生取消的真实事务应为 cancelled，不伪造为 notDispatched；不能只让 paste seam 直接返回枚举来证明这些路径。

- [x] **Step 2: 实现双标记与受控回退。** `.unsafeSnapshot` / `.notDispatched` 才重新取目标/权限；禁止释放/重置 session attempt 来另开一次交付。回退类型首键前失败时 preserveClipboardOnFailure=true → 含全文、retryable=false 的恢复卡；首键后失败/取消 → uncertain，无 copy。普通 unicode 首效应前失败继续原有复制恢复。
- [x] **Step 3: 补齐竞态与故障行为测试。** 逐项断言下表：

| 输入 | 精确断言 |
| --- | --- |
| unsafeSnapshot，键入也在首键前抛错 | 原板及 writes 不变，events=0；suspend.rawText 为完整文本，retryable=false，非 uncertain |
| 实际写板失败、恢复后 notDispatched，或事件准备失败且未改板 | event=false 不阻止一次安全键入；不重置 effect/attempt；保存最终结果仅一次 |
| paste uncertain / clipboardChanged / dispatched | typeCount=0、copyCount=0，不重复 execute 副作用 |
| 回退复检中切 PID/已知 focus、变 secure、失去 AX、变 blind | typeCount=0；原板不被恢复 copy 覆盖；完整文本可恢复 |
| 复检/排队/首键前取消 | 无迟到 type/copy；无事件的临时板恢复后是 cancelled；原板保留 |
| 首个键对已发后失败/取消 | 事件不重复、outcome=uncertain；不得再 paste/copy |
| 用户在事务期间复制另一值 | 当前 changeCount/内容保持用户新值，事务不恢复旧板，不启动回退 |
| 显式 unicode / legacy | 既有方式与旧失败恢复保持；成功/失败均无新增自动策略越界 |
| default/缺键/未知字符串/显式两旧值 | automatic/automatic/automatic/原值；三个值编码往返、其他字段不变 |

- [x] **Step 4: 接入模式默认/设置，修订旧测试的隐含默认依赖。** 专门验证 Unicode 的旧测试明确注入 `.unicode`；测试生产默认的路径改断言 automatic。不允许统一注入旧模式把生产路径排除出测试。保留已完成 M2 与所有原事务断言；新测试不伪造“已发送”来跳过 event gate。
- [x] **Step 5: 运行 focused GREEN，顺序完整 build/self-test，检查 diff，再提交 `feat(delivery): enable automatic paste with owned typing fallback`。** 如失败，先定位新默认影响的真实场景再修，不删除旧回归。限定任务审查重点核对真实事务、部分输出与取消。

### Task 3: 结果呈现、菜单摘要与阶段验收

**Files:** Create `Services/Delivery/LastDeliverySummary.swift`, `App/LastDeliveryMenuController.swift`; Modify `Core/PipelineOrchestrator.swift`, `App/StatusBarController.swift`, `Testing/M3DeliverySelfTests.swift`, `Testing/SelfTest.swift`; Update `docs/evidence/2026-11-02-m3-validation.md`, `docs/evidence/2026-11-01-live-validation.md`, `docs/2026-10-14-flowtype-product-validation.md`。

**Interfaces:**

- 产生 `struct LastDeliverySummary: Equatable, Sendable`，字段 `sessionID: UInt64`, `outcome: DeliveryOutcome`, `targetAppName: String?`, `targetBundleID: String?`；产生纯 `lastDeliveryMenuTitle(_ summary: LastDeliverySummary?) -> String`。
- SessionController 增加 `@Published private(set) var lastDeliverySummary: LastDeliverySummary?`；私有 `recordLastDelivery(context: SessionContext)` 仅在有真实 terminal delivery、且拥有当前 session 时同步发布。finish 与现有取消 uncertain 保存路径共用；过期 stage 不得反写。
- 沿用 DeliveryCopy，uncertain exact 文案为「已发送，但无法确认是否插入；可从历史复制」。无摘要显示「最近一次交付：暂无」；typed/paste 显示“已发送键入/粘贴”，clipboard 显示“已复制（原目标：…）”，uncertain 显示“发送不确定”。fallback app 名为「未知应用」，不能显示原始转写/上下文。
- 产生 `@MainActor final class LastDeliveryMenuController`，`init(session: SessionController)`、`let item: NSMenuItem`、`func refresh(for summary: LastDeliverySummary?)`。禁用 item 只展示信息；同步订阅 `$lastDeliverySummary` 使用 emitted value 更新（@Published 发送时属性可能仍是旧值）。StatusBarController 在 menuWillOpen/updateMenuItems 用当前摘要再刷新；fixture 注入隔离 controller，不访问真实 singleton/窗口。
- 测试入口 `@MainActor static func presentation(_ r: SelfTest.Reporter) async`。

- [x] **Step 1: 写文案/摘要 RED。** 三种终态各有正确动词；nil/未知应用；clipboard 不声称输入到原 app；正常 finish 一次历史/一次摘要，静音 notice/无事件 cancel 不清旧摘要，旧 session 屏障释放不覆盖新摘要。用真实 controller + SessionEffects 的隔离保存 seam。
- [x] **Step 2: 实现摘要发布与菜单接线。** 保留已有历史/隐私模式行为，不用写数据库再读取作为菜单状态；不让菜单刷新产生新的权限/交付副作用。审查 uncertain 的取消历史边界，不为新摘要绕过旧所有权。
- [x] **Step 3: 运行 focused GREEN 和顺序完整 build/self-test。** 构建、自测 exit 0，核对无 transcript 的摘要/日志。提交 `feat(delivery): present honest last delivery outcomes`。
- [x] **Step 4: 阶段独立源码审查。** 核验 spec 与三任务 diff，修复 Important 后限定复审；源码稳定再 `bash scripts/build-app.sh`，记录 source tree 与二进制身份。不重跑未变化的完整 suite。
- [ ] **Step 5: 固定产物执行 M3-A 真机矩阵。** TextEdit / VS Code / Chrome / Terminal / Cursor 中文+英文+多行，终端不自动执行命令；安全输入、无 AX、切焦点；文字/RTF/图片/文件与并发复制；150ms 恢复窗口、事件前/后取消。逐行记录 Pass/Fail/Pending，工具/应用不可用保持 Pending，V1/V4/V5 未覆盖项继续主线，不以源码通过结案。

## Self-Review / Handoff

已对照 spec：策略/迁移→Task1+2；实际事件与剪贴板效应分离/回退→Task2；结果/菜单→Task3；全局五类 Review Focus 均有对应测试。类型名、case、eventStarted 只在一个 gate 定义；没有引入第二套目标检查、剪贴板实现或历史迁移。150ms 保持，真机证据才允许调整。

本计划已由 Owner 确认。三个任务顺序执行、每项独立审查，接着做 M3-B，最终全 M3 复审。A3 的中间 release/真机批次合并至稳定最终 M3 产物；A 源码阶段审查保持。源码完成不替代真实验收。
