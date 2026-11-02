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

- [ ] **Step 1: 添加行为 RED，先运行 focused runner。** 现有 enum 已存在，默认 automatic、notDispatched→键入、unsafeSnapshot→键入等必须是行为失败。至少锁定：

```swift
r.eq(Configuration().deliveryMode, .automatic, "new default")
r.eq(try JSONDecoder().decode(Configuration.self, from: Data("{}".utf8)).deliveryMode,
     .automatic, "missing mode migrates")
// 用真实 InjectionStage+ClipboardTransaction，原板含 public.rtf、图像及文件类型 Data。
r.eq(events, ["paste-preparation", "type"], "no paste event permits one typed fallback")
r.eq(board.contents(), original, "fallback never replaces protected clipboard")
```

写板后、发键前的取消用受控 continuation/屏障定位，避免依赖固定 sleep。用 fake board 实际先清空/部分写入、返回 succeeded=false，再成功恢复原板，覆盖真实事务的 notDispatched，eventStarted 必须为 false；另用真实 SessionContext gate 单独验证 effect=true 不代表 event=true。成功写板后发生取消的真实事务应为 cancelled，不伪造为 notDispatched；不能只让 paste seam 直接返回枚举来证明这些路径。

- [ ] **Step 2: 实现双标记与受控回退。** `.unsafeSnapshot` / `.notDispatched` 才重新取目标/权限；禁止释放/重置 session attempt 来另开一次交付。回退类型首键前失败时 preserveClipboardOnFailure=true → 含全文、retryable=false 的恢复卡；首键后失败/取消 → uncertain，无 copy。普通 unicode 首效应前失败继续原有复制恢复。
- [ ] **Step 3: 补齐竞态与故障行为测试。** 逐项断言下表：

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

- [ ] **Step 4: 接入模式默认/设置，修订旧测试的隐含默认依赖。** 专门验证 Unicode 的旧测试明确注入 `.unicode`；测试生产默认的路径改断言 automatic。不允许统一注入旧模式把生产路径排除出测试。保留已完成 M2 与所有原事务断言；新测试不伪造“已发送”来跳过 event gate。
- [ ] **Step 5: 运行 focused GREEN，顺序完整 build/self-test，检查 diff，再提交 `feat(delivery): enable automatic paste with owned typing fallback`。** 如失败，先定位新默认影响的真实场景再修，不删除旧回归。限定任务审查重点核对真实事务、部分输出与取消。


## Binding Context

Spec: docs/superpowers/specs/2026-11-02-m3-delivery-and-silence-design.md. Read only relevant sections and this task; do not read the whole implementation plan.


- Swift 6.2、macOS 15+；不新增/升级依赖，不下载 VAD 模型，不运行 Python 或转换脚本。
- 单一 SessionController / SessionContext 生命周期；旧 session 的迟到结果不能发布 UI、历史或交付。
- 音频扫描与 AX IPC 不阻塞 MainActor；取消检查贯穿所有等待与副作用边界。
- 不重置 deliveryAttempted，不自动重发 uncertain，不把 dispatched 写成已确认插入。
- 保留 changeCount + 完整表示快照的剪贴板所有权；不覆盖用户在事务中新增的复制内容。
- 不改变 M2 模型选择、active/captured lease、云端厂商配置和离线合同。
- 只用合成音频/文本、假提供者/剪贴板、隔离配置作自动测试；真机状态单列。
- 使用 `swift build` 后顺序执行 `swift run FlowType --self-test`，不运行 `swift test`；源码稳定后再构建 app。
- 保留分支/worktree，不 push、不 merge，不修改真实配置、权限、用户模型或缓存。

Controller owns independent review, app packaging and actual acceptance; do not dispatch subagents or operate GUI/real user resources. Scope commits to your source/tests and specifically authorized evidence changes; controller plan/audit/status edits may be dirty and must not be staged.
