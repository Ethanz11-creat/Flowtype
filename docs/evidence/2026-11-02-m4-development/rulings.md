Ruling: 后续自测使用进程级 CFFIXED_USER_HOME 指向本计划独立 scratch，并注入空词典 — 发现旧 ASRStage/full runner 会初始化真实用户词典及日志，已用只打印路径的 Foundation probe 验证 HOME 与 Application Support 被重定向，不修改 HOME、不扩大到 M5 重构 — 若隔离环境与正常启动有差异，需真机覆盖配置/目录行为。

Ruling: 首事件前 clipboardChanged 的保守 uncertain outcome 保留，但恢复展示用 deliveryBlocked“未发送文本，可复制结果” — M3真实事务在快照/写板并发变化时可无事件返回uncertain，统一“已发送”会失实；仅实际发事件后的uncertain用deliveryUncertain和历史动作 — 若用户需要该子类历史快捷入口，当前copy/dismiss需后续补充；不会导致重发或自动覆盖剪贴板。已同步spec/plan/task3 brief及实现者，并要求真实事务controller回归。

Ruling: 恢复卡改为单一私有快照的计算属性，并提供显式 recoveryCardPublisher，替代原计划 @Published 卡片 — willSet 在同步订阅中启动新会话后仍可把旧值写回，事后ID检查不能修复；没有产品消费者依赖原卡片投影，优先窄接口而非自定义wrapper — 内部订阅代码须改用新publisher，未来新增订阅也须遵守提交后通知；仍需真机UI验收。摘要保留原订阅接口，发布前领取一次通知资格、返回后复检owner。

Publication ruling extension (same finding/decision): consumer audit found only two $sessionState uses, both StatusBarController23/90. Approved same canonical commit-before-notify sessionStatePublisher and these two mechanical consumer migrations; source property remains read-only, state enum/lifecycle unchanged. Newer committed generation suppresses older remaining notifications/cleanup, including objectWillChange. No spectrum/preparation rewrite absent concrete need. Cost extends prior ruling: internal state subscribers must use explicit publisher too; normal GUI still Pending. Spec/plan updated.

