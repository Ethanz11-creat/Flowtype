### Task 3: 结果呈现、菜单摘要与阶段验收

**Files:** Create `Services/Delivery/LastDeliverySummary.swift`, `App/LastDeliveryMenuController.swift`; Modify `Core/PipelineOrchestrator.swift`, `App/StatusBarController.swift`, `Testing/M3DeliverySelfTests.swift`, `Testing/SelfTest.swift`; Update `docs/evidence/2026-11-02-m3-validation.md`, `docs/evidence/2026-11-01-live-validation.md`, `docs/2026-10-14-flowtype-product-validation.md`。

**Interfaces:**

- 产生 `struct LastDeliverySummary: Equatable, Sendable`，字段 `sessionID: UInt64`, `outcome: DeliveryOutcome`, `targetAppName: String?`, `targetBundleID: String?`；产生纯 `lastDeliveryMenuTitle(_ summary: LastDeliverySummary?) -> String`。
- SessionController 增加 `@Published private(set) var lastDeliverySummary: LastDeliverySummary?`；私有 `recordLastDelivery(context: SessionContext)` 仅在有真实 terminal delivery、且拥有当前 session 时同步发布。finish 与现有取消 uncertain 保存路径共用；过期 stage 不得反写。
- 沿用 DeliveryCopy，uncertain exact 文案为「已发送，但无法确认是否插入；可从历史复制」。无摘要显示「最近一次交付：暂无」；typed/paste 显示“已发送键入/粘贴”，clipboard 显示“已复制（原目标：…）”，uncertain 显示“发送不确定”。fallback app 名为「未知应用」，不能显示原始转写/上下文。
- 产生 `@MainActor final class LastDeliveryMenuController`，`init(session: SessionController)`、`let item: NSMenuItem`、`func refresh(for summary: LastDeliverySummary?)`。禁用 item 只展示信息；同步订阅 `$lastDeliverySummary` 使用 emitted value 更新（@Published 发送时属性可能仍是旧值）。StatusBarController 在 menuWillOpen/updateMenuItems 用当前摘要再刷新；fixture 注入隔离 controller，不访问真实 singleton/窗口。
- 测试入口 `@MainActor static func presentation(_ r: SelfTest.Reporter) async`。

- [ ] **Step 1: 写文案/摘要 RED。** 三种终态各有正确动词；nil/未知应用；clipboard 不声称输入到原 app；正常 finish 一次历史/一次摘要，静音 notice/无事件 cancel 不清旧摘要，旧 session 屏障释放不覆盖新摘要。用真实 controller + SessionEffects 的隔离保存 seam。
- [ ] **Step 2: 实现摘要发布与菜单接线。** 保留已有历史/隐私模式行为，不用写数据库再读取作为菜单状态；不让菜单刷新产生新的权限/交付副作用。审查 uncertain 的取消历史边界，不为新摘要绕过旧所有权。
- [ ] **Step 3: 运行 focused GREEN 和顺序完整 build/self-test。** 构建、自测 exit 0，核对无 transcript 的摘要/日志。提交 `feat(delivery): present honest last delivery outcomes`。
- [ ] **Step 4: 阶段独立源码审查。** 核验 spec 与三任务 diff，修复 Important 后限定复审；源码稳定再 `bash scripts/build-app.sh`，记录 source tree 与二进制身份。不重跑未变化的完整 suite。
- [ ] **Step 5: 固定产物执行 M3-A 真机矩阵。** TextEdit / VS Code / Chrome / Terminal / Cursor 中文+英文+多行，终端不自动执行命令；安全输入、无 AX、切焦点；文字/RTF/图片/文件与并发复制；150ms 恢复窗口、事件前/后取消。逐行记录 Pass/Fail/Pending，工具/应用不可用保持 Pending，V1/V4/V5 未覆盖项继续主线，不以源码通过结案。

## Self-Review / Handoff

已对照 spec：策略/迁移→Task1+2；实际事件与剪贴板效应分离/回退→Task2；结果/菜单→Task3；全局五类 Review Focus 均有对应测试。类型名、case、eventStarted 只在一个 gate 定义；没有引入第二套目标检查、剪贴板实现或历史迁移。150ms 保持，真机证据才允许调整。

本文件任务均未执行。开始实施前审阅本计划与共同 spec；沿用子智能体方式时三个任务顺序执行、每项独立审查，接着做 M3-B，最终全 M3 复审。源码完成不替代真实验收。

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

Controller ruling: defer the intermediate A release/GUI batch to the stable final M3 bundle after B; you implement source/tests and truthful stage evidence only. A stage source review remains controller-owned.
