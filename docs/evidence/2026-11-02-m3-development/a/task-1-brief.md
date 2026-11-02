### Task 1: 纯交付策略与兼容模式

**Files:** Create `Services/Delivery/DeliveryPolicy.swift`, `Testing/M3DeliverySelfTests.swift`; Modify `Services/KeyboardInjector.swift`, `Testing/SelfTest.swift`。

**Interfaces:**

- 产生 `enum DeliveryMode: String, Codable, Sendable { case automatic, unicode, pasteInSupportedApps }`，保留 `usesPaste(bundleID: String?) -> Bool`；automatic 不按目录限制，legacy 六项目录不变。最终安全性由策略/目标检查决定，不能仅调用 usesPaste 发键。
- 产生 `enum DeliveryMethod: Equatable, Sendable { case paste, type, clipboard }`。
- 产生 `resolveDeliveryMethod(mode: DeliveryMode, signals: FocusSignals, accessibilityTrusted: Bool, bundleID: String?) -> DeliveryMethod`，实现 spec §4.1 阶梯；目标身份由 Task 2 在调用前用 decideDelivery 核验。
- 产生 `canFallbackToTyping(mode: DeliveryMode, pasteResult: PasteTransactionResult, eventDispatched: Bool, target: DeliveryTargetSnapshot?, current: DeliveryTargetSnapshot, accessibilityTrusted: Bool) -> Bool`。仅 automatic + unsafeSnapshot/notDispatched + 无按键 + decideDelivery==inject + trusted + 明确 editableText 为 true。
- 测试入口 `M3DeliverySelfTests.policy(_ r: SelfTest.Reporter)`；新 `--m3-delivery-only` 调用它，后续任务追加同一入口的 runtime/presentation 检查；完整 suite 也必须调用。

- [ ] **Step 1: 写纯策略 RED 测试并接入 focused runner。** 对三模式覆盖 secure/nonText/noAX → clipboard；automatic editable/blind + unknown/nil bundle → paste；unicode → type；legacy 六项 → paste、Terminal/nil → type。回退表覆盖所有六种 PasteTransactionResult × event true/false；focus/PID 改变、blind、无权限、legacy 一律 false。代表断言：

```swift
r.eq(resolveDeliveryMethod(mode: .automatic,
    signals: .init(secureInputActive: false, focus: .blindOrUnknown),
    accessibilityTrusted: true, bundleID: "test.unknown"), .paste,
    "automatic permits initial paste for same-target AX blind apps")
// 使用相同目标构造 fallback，editable+notDispatched 为 true；blind 为 false。
```

- [ ] **Step 2: 运行 `swift run FlowType --self-test --m3-delivery-only`。** 记录缺失 API/策略断言的 RED；不得以替换一个已异步的 fake 代替真实判定。
- [ ] **Step 3: 搬移 enum，按上述接口实现纯策略。** 此任务暂不切换 Configuration 默认，避免 stage 尚未接线就切用户行为；不重复角色集或目标核验逻辑。
- [ ] **Step 4: 运行 focused GREEN，再顺序 `swift build`、`swift run FlowType --self-test`。** exit 均为 0、无失败；旧默认断言此时仍是 unicode。记录日志与源身份。
- [ ] **Step 5: 提交 `feat(delivery): define automatic delivery and safe fallback policy`，做该任务源码审查。**


## Binding Context

Spec: docs/superpowers/specs/2026-11-02-m3-delivery-and-silence-design.md (§3–4). Read relevant sections, not the whole implementation plan.


- Swift 6.2、macOS 15+；不新增/升级依赖，不下载 VAD 模型，不运行 Python 或转换脚本。
- 单一 SessionController / SessionContext 生命周期；旧 session 的迟到结果不能发布 UI、历史或交付。
- 音频扫描与 AX IPC 不阻塞 MainActor；取消检查贯穿所有等待与副作用边界。
- 不重置 deliveryAttempted，不自动重发 uncertain，不把 dispatched 写成已确认插入。
- 保留 changeCount + 完整表示快照的剪贴板所有权；不覆盖用户在事务中新增的复制内容。
- 不改变 M2 模型选择、active/captured lease、云端厂商配置和离线合同。
- 只用合成音频/文本、假提供者/剪贴板、隔离配置作自动测试；真机状态单列。
- 使用 `swift build` 后顺序执行 `swift run FlowType --self-test`，不运行 `swift test`；源码稳定后再构建 app。
- 保留分支/worktree，不 push、不 merge，不修改真实配置、权限、用户模型或缓存。

Controller performs independent reviews, packaging and actual acceptance. Do not spawn agents or touch real user resources.
