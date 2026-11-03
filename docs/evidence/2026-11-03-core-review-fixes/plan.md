# 核心审查修复计划

输入：[独立审查 CORE-01–04](../2026-11-03-core-typeless-review/independent-code-review.md)。基线 `2fff1c7`。按 receiving-code-review 先复核实际调用链，不把 Typeless 能力差异转成未授权功能。

1. CORE-01：在整个本地后处理之前保护显式数字/代码/URL/路径等字面量，限制普通重复清理范围；用真实 PostProcess → Polish → Injection 组合验证原文、完成润色和失败回退。
2. CORE-02：主 Unicode 路径每个键对前重新验证目标与权限；保留主路径未知 AX 的兼容策略和自动降级严格可编辑策略；已发事件失败保持 uncertain，禁止重送。
3. CORE-03：Apple 预览的 stream finish 与框架 endAudio/cancel 在锁外执行；结束幂等、会话归属隔离，合成框架边界覆盖 final/error/timeout 与停止竞态。
4. CORE-04：录音心跳和 Apple 预览超时采用确实会运行的调度器，取消与回调保留 owner/generation 检查；测试真实调度器而非直接触发下游 frozen。

先记录 RED，再实现和 GREEN；完成后独立审查，修复有效反馈，执行候选对应 code/artifact 门禁并提交。物理麦克风、云端、目标应用和剪贴板操作仍属于现有真机 Pending 主线，不因合成回归转为通过。不安装应用、不新增持久音频或竞争产品协议。
