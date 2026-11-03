# CORE-01–04 修复实施记录

基线 `2fff1c7`；按 receiving-code-review 逐项核实，最终源码于 2026-11-04 Asia/Shanghai 冻结。独立复查见 [scoped-rereview.md](scoped-rereview.md)，四项均 Addressed，无剩余 Critical/Important。

## 修复及回归

- CORE-01：完整文本逐条清理，任何损坏显式字面量的规则整体弃用；标点转换保留全文上下文并跳过字面量 UTF-16 范围。数字/ASCII 标识符不再按中文重复规则缩短。保护数字、引号/转义字符串、JSON 字符串、代码、路径、选项、版本和含单引号/Unicode 数据的 URL。
- CORE-02：两条键入路径都给真实键对循环传递 fresh target/permission validator，覆盖首对、分块和换行。保留主路径未知 AX 兼容、自动降级的明确可编辑要求；已发事件后失败仅 uncertain，不复制全文重送。
- CORE-03：Apple 预览每次独立 owner，锁外完成流及 endAudio/cancel；终止幂等，迟到结果/任务清理不污染其他会话。
- CORE-04：实际录音心跳使用受服务的 dispatch scheduler 与单调进度时钟，按 owner/generation 取消，先通知冻结再结束流；Apple 预览超时也使用该 scheduler。

原始全文回归先在旧实现得到 **836/126，exit1**，重现数字/代码/URL 损坏及主键入继续向变化目标发送；见 [core01-02-red.log](core01-02-red.log)。CORE-03 安全锁重入特征及 CORE-04 原始工作线程 timer 行为失败记录见 lifecycle notes。

第一版修复的初始聚焦用例通过 1013/0，但独立复查发现引用字符串、分段上下文与 URL 单引号盲点；已补充 RED 用例并修正，未把第一次通过当作最终完成。相关 RED/GREEN 日志保留在本目录。最终实际构建成功，`--m3-delivery-only` 同时运行原有交付组及新内容/生命周期回归，结果 **1079 passed / 0 failed，exit0**，见 [focused-final.log](focused-final.log)。两处 focused/full 注册均已核对。

## 验证准备与范围

初次 focused 命令传入 `/tmp` 别名，被隔离根校验拒绝 invalidRoot，没有执行用例；改为 `/private/tmp` 的独立空根后才取得行为 RED。集成编译曾发现一个重复局部变量名，已修正；另一次因控制器在构建时修改源码而被 Swift 拒绝，源码冻结后的构建成功。以上不计为预期行为 RED。

AudioRecorder 重编译暴露三条原有 warning：deviceIDSize 未修改，以及 AVAudioConverter 的 inputConsumed 捕获读写；这些代码在基线已存在，本轮未改动，不宣称 warning-free。最终增量构建没有新增 warning。完整候选门禁由本次源码提交后另行执行，最终结果见后续 README。

测试替换了外部 LLM stream、OS 输入/剪贴板效果及硬件进度来源，执行实际阶段、键对循环、预览清理 owner 和心跳 scheduler；没有实际麦克风/权限、模型/云端、键盘/剪贴板或应用安装操作。真机 V1–V5 与远端 CI 保持 Pending。清理规则整体弃用会保留部分普通填充词/空白，URL 歧义标点也保守保留，这是优先保护内容的明确取舍。
