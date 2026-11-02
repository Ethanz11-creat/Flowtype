# M3-A / M3-B 开发与验证归档

M3 源码开发完成。五项任务逐项独立审查；全 M3 审查发现两项 Important，统一修复后限定复审均关闭、无新增阻塞。最终产品源码 `f7554ee4dec4782a6a4fb3c137e61f1e627ce2f9`，`Sources/flowtype` tree `f2d097da0b9b296aca9d37fd8f15382155c19b67`。

- M3-A：automatic 默认和旧值迁移；粘贴优先与事件前安全回退；真实事件/临时写板分离；每个回退键对复检；元数据菜单摘要；发键后取消同步保留 uncertain。
- M3-B：完整原始 PCM 的可取消后台静音检查；短音频/检测技术异常放行，损坏音频明确报错；真实 ASR/direct/retry 接线、实时清理、单一预算及无预览/历史/交付早退。
- [验证矩阵](../2026-11-02-m3-validation.md)保留全部真实验收 Pending；[执行裁定](rulings.md)保留五项决定及代价；[固定产物/签名/警告](bundle-verification.md)记录实际构建结果。

| 关口 | 提交 | Focused | 完整 self-test | 独立审查 |
| --- | --- | --- | --- | --- |
| A1 纯策略 | c9f91a1 | 133/0 | 2640/0 | [通过](a/task-1-review.md) |
| A2 事务/默认/回退 | 7700f36 | 305/0 | 2812/0 | [通过](a/task-2-review.md) |
| A3 摘要/菜单 | 7c6c130 | 381/0 | 2888/0 | [任务及全 A 通过](a/task-3-review.md) |
| B1 扫描/后台 | d9111f1 | 741/0 | 3629/0 | [通过](b/task-1-review.md) |
| B2 管线 | 7ce5d21 | 989/0，相关292/0 | 3875/0（屏障加强前） | [通过](b/task-2-review.md) |
| 全 M3 修复 | f7554ee | RED527/78 → 628/0 | **4124/0** | [F1/F2 关闭](b/final-rereview.md) |

每个生产源码稳定关口均顺序 `swift build` 后 `swift run FlowType --self-test`，未运行 `swift test`。B2 那次完整验证在测试屏障加强前；差异和当时完整测试文件在 b/ 保留；最终修复版重新顺序完整通过 4124/0，包含加强后的屏障测试。最终测试之后只有测试空白格式/文档归档，没有生产行为改动。源码并不因增加文档提交而变化。

[全 M3 初审](b/final-review.md)确认 F1 分块等待后缺目标复检、F2 实际发键后取消尚无 outcome 会漏历史/摘要。修复用真实分块循环与真实 controller/stage/transaction，只替换 OS/存储边界：[完整修复报告](b/final-fix-report.md)。限定复审确认两项均 ADDRESSED，不允许旧 stage 迟到发布。

一次独立 Debug 30 分钟合成 PCM 测量：Apple M1/16 GiB，analyze 4.535s、evaluate 4.531s、取消请求至观察退出约0.080ms；[原记录](b/task-1-benchmark.log)。未重复 benchmark，不代表真实声音或全部机型。

最终 `build/FlowType.app` 已构建，Release99.05s，arm64、com.flowtype.app、ad-hoc；可执行 SHA256 `09a458ad6f9492c297eb5a85145407b71d539b4112a66b09349c2cc8d11d824d`。主代码 `--ignore-resources` 校验通过；严格完整/深度校验仍因既有 unsigned mlx.metallib 失败，不能声称签名/分发就绪。未运行 GUI。Release 还有本轮未修改文件中的警告，完整原文见 bundle-build.log。

当前工具无桌面/截图/输入能力，未调用真实云服务、完整模型推理或操作物理麦克风。五应用、实际剪贴板消费、静音/轻声校准、20轮、弱网/断网、取消、拔麦/蓝牙恢复及 M2 实际推理继续是必做 Pending。低于候选阈值的轻声可能误拦，噪声可能放行；实时录音可能早已上传，不能承诺零请求或计费。

归档布局：a/ 与 b/ 各保存本计划台账、brief、报告、审查和实际命令日志；a/task-3-logs/ 映射报告中的 /tmp/flowtype-m3-a3-*.log；报告内的原 .superpowers 路径是运行时溯源，文件已复制到当前目录。源代码 diff 可由所列提交恢复，不重复保存大 diff。仅这两份 M3 临时工作目录在归档校验后清理，分支与 worktree 保留，无 push/merge。

原始日志包含编译器源码片段的行尾空白，按字节保留以维持证据校验；全量 diff whitespace 检查会报告这些 .log 行。源码/Markdown 单独通过 whitespace 检查，不将 raw log 空白改写为新的运行输出。
