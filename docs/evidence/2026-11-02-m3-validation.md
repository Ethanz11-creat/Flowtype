# M3 验证清单 — 2026-11-02

状态：**计划阶段，未执行**。当前产品仍为 M2 源码 `e69d688`，文档检查点 `b64d538`。既有 2507/0 是 M2 结果，本文件没有新增构建/测试/GUI/云端/音频结果。

依据：[共同设计](../superpowers/specs/2026-11-02-m3-delivery-and-silence-design.md)、[M3-A 计划](../superpowers/plans/2026-11-02-m3-a-automatic-delivery.md)、[M3-B 计划](../superpowers/plans/2026-11-02-m3-b-silence-preflight.md)。执行负责人为开发控制器；Owner 执行需物理热键、复制、拔麦与本机认证的操作。

## 源码验证

| ID | 覆盖 | 状态 |
| --- | --- | --- |
| S-A1 | 三模式策略、安全/权限/目标身份、回退纯判定 | Pending |
| S-A2 | 默认/旧值迁移、真实 ClipboardTransaction+InjectionStage、部分写板恢复、受保护板键入失败 | Pending |
| S-A3 | 事件前后取消、并发复制、目标复检、duplicate attempt、一次历史/摘要和菜单 | Pending |
| S-B1 | 原始 PCM 全帧/尾帧、候选阈值、短音频/无效样本、后台响应/取消 | Pending |
| S-B2 | 真实 ASR/controller 的静音早退；preview、health、预算、live 收尾与重试/旧回调 | Pending |
| S-F | 稳定源码顺序 build/full self-test、独立全 M3 审查及修复复审 | Pending |

## 真实验收（全部必做）

| ID | 操作 | 通过条件 | 主线关联 | 状态 |
| --- | --- | --- | --- | --- |
| M3-A1 | TextEdit、VS Code、Chrome、Terminal、Cursor，分别中文/英文/多行 | 原目标完整一次落字；Terminal 不误提交命令；记录应用版本和实际 outcome | V2.1 | Pending |
| M3-A2 | 录音前/停止前/处理中切 app 或已知文本框；非文本/secure/noAX | 停止时目标合同明确；变目标与不安全输入不发键，可恢复文本 | V2.2 | Pending |
| M3-A3 | 合成文字/RTF/图片/文件、多 item、多 representation | 支持的表示完整保留；快照不完整不破坏；键入回退失败仍保留原板 | V3.1 | Pending |
| M3-A4 | 事务期间另复制，分别正常完成和取消 | 不覆盖新复制；所有权变化不重发；观察 150ms 目标消费 | V3.2、V4 | Pending |
| M3-A5 | 新配置/缺键配置/两种旧显式模式及 UI 切换 | automatic 新默认、旧值不改；模式可见/可选；摘要动词诚实，无转写泄漏 | UI | Pending |
| M3-B1 | 实际选定设备录 5s 静音并停止 | 短暂 notice、无幻觉/落字/历史；batch 不发识别，实时只记录停止后未 finalize | V1、V5.2 | Pending |
| M3-B2 | 轻声、极短词、立即开口、开头/尾部词、超过 6s 再开口 | 不误拦，不裁头尾；没有录音早期 6s 自动停止 | 音频校准 | Pending |
| M3-B3 | 风扇、敲键盘、风噪和安静背景 | 如实记录候选参数/误拦/放行；不以有能量声称有人声；不宣称噪声全能过滤 | 能力边界 | Pending |
| M3-C1 | preparing/recording/预检/ASR/polish/injection 分别取消；旧回调随后返回 | 无迟到交付/历史/摘要污染；已发出的边界另记 uncertain | V4.1、V4.2 | Pending |
| M3-C2 | 已授权真实云端正常/弱网/录音中断网，本地已加载 | 受控预算、完整本地兜底、单次终态与交付；静音不重复 finalize | V1.1–V1.3 | Pending |
| M3-C3 | 真实 USB/蓝牙失联、默认/指定设备；连接后重试 | 设备错误不伪装静音，释放后可恢复；保留真实物理设备证据 | V5.1、V5.2 | Pending |
| M3-C4 | 连续 20 轮成功/静音/取消/重新录音 | 全部回 idle，无重复/卡住/麦克风残留，历史数量对应实际终态 | 连续稳定性 | Pending |

## 记录规则

每轮固定 source SHA、source tree、bundle 路径/二进制 SHA、macOS/硬件、目标 app 版本、配置/权限、sessionID、事件顺序及脱敏计时。测试内容只用合成参考句；不得保存私人音频/转写/上下文/密钥。网络、权限、设备条件按实际动作授权执行并恢复。

若桌面/工具/应用/有效云配置/外设不可用，记录具体前提并保持 Pending，不能用假传输、旧运行进程或静态元数据作为 Pass。M2 的实际模型推理剩余覆盖继续保留；M3 源码通过不能自动关闭 V1–V5。

静音候选值：20ms/320 samples、minimum 100ms/1600 samples、RMS 0.0003、peak 0.001，全部是待校准的 Float32 参数，并非 Typeless 量化阈值。一次真实 Fail 必须保留；调整参数时记录理由、旧/新结果及新回归，重新固定源码/bundle 后再验收。
