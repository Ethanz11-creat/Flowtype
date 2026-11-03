# IR-01 / IR-02 限定独立复审

日期：2026-11-03。结论：**IR-01 ADDRESSED；IR-02 ADDRESSED。限定范围未发现新的 Critical / Important，可进行一次最终 release 技术门禁。** 这不是完整产品验收通过；41 个人工叶子与远端 CI 继续 Pending。

## 范围与方法

- 先读取 scoped-review-brief.md、原独立审查 IR-01/IR-02，再读取 implementation-report.md；按 requesting-code-review/code-reviewer.md rubric 复审。
- Base：`547188002f0fbb1009316c53c7dac0e8da5c8c9b`；Head：`bb8b5bf671b94ca8f4c5ac5256583b4550ff88e2`。
- 检查两个修复提交、全部六个变更文件、受影响默认生产接线与取消所有权，以及本目录原始 RED/GREEN、子进程输出、缓存 trace、编译输出和诊断日志。没有重做全 M1–M5 扫描。
- HEAD 与 brief 一致；审查开始和报告写入前 tracked worktree/index 均干净；`git diff --check 5471880..bb8b5bf` 无输出。Package.swift / Package.resolved 无差异。Sources tree 为 `5d4772afcd862c9048ccf5d0ad65971cb6fae21f`。
- 本轮没有执行测试、构建、GUI、录音、权限、真实配置/DB/Keychain/模型/用户缓存/服务访问，没有派生代理或改变 checkout/index/HEAD。唯一写入是本报告。

## Strengths

- IR-01 直接删除不合约的输入发现分支；回归编译真实生产 `@main`，没有复制解析器或改写生产源文本。旧实现确实命中合成缓存，证明回归能够观察原缺陷。
- IR-02 将自然完成和 CancellationError 统一到实际生产 `finishRecording`，避免两个退出分支再次分歧。全会话取消先处理，冻结不产出 audio，健康 Stop 保留有效会话和实时识别能力。
- 新测试执行真实 `RecordingStage.execute` 与 `SessionContext`，用非空 PCM、异步 gate 和实际 frozen callback 安排可复现顺序；没有以直接调用终态 helper 代替管线阶段执行。该测试已接入现有 M4 focused/full 入口。

## 原发现处理结果

### IR-01：ADDRESSED

生产位置：`scripts/verification/ArtifactPackagingCLI.swift:71`。

build 分支现在要求存在且非空的 `MLX_METALLIB_PATH`，否则直接抛 `shaderInvalid`；仅将显式 URL 交给原 packager。原 uv/pip 用户缓存枚举分支已完全移除。显式路径的文件大小、格式和最终运行校验仍由原 packager/artifact 门禁负责，没有加入替代来源或自动补齐行为。

回归位置：`ArtifactPackagingCLIInputTests.rb:14` 编译三份实际生产文件和独立 test-only FileManager fixture；`:43` 覆盖缺失、空串、显式输入及额外参数。`ArtifactPackagingCLIInputFixture.swift:14` 将 home 指向合成目录，`:16` 跟踪并约束缓存枚举。正常 build-app/check-app 的明确编译文件列表不含这个 fixture，生产接线不会被该同模块名称遮蔽影响。

核对原始证据：

- `ir01-red.stdout/.stderr/.exit`：exit 1，9 passed / 3 failed；失败正是 missing 错误分类、missing 缓存枚举、empty 错误分类。
- RED 子目录 `cli-input-2cc3f544-b2e8-4a5c-a5b6-c47f1a946f4a/`：missing.cache-trace 确实记录合成 uv 缓存路径；missing/empty stderr 都是 sourceInvalid。
- `ir01-green.stdout/.stderr/.exit`：exit 0，12 passed / 0 failed；GREEN 子目录 `cli-input-14f9adcd-6528-48f4-a49c-b5d21eecae28/` 中 missing/empty 均 exit 1 + shaderInvalid，全部缓存 trace 为空，额外参数仍为 usage / exit 64。编译 stderr 为空。

显式输入案例到达故意损坏仓库的 sourceInvalid 哨兵，证明通过输入选择进入下游；它没有证明真实打包成功。显式 shader 的完整生产打包应由下一次 release 门禁证明。该 CLI 回归是独立入口，当前未接入 full/CI；本次已运行的定向证据可关闭这个具体输入分支发现。

### IR-02：ADDRESSED

生产位置：`Sources/flowtype/Core/Pipeline/Stages/RecordingStage.swift:172`、`:178` 均调用 `finishRecording`；终态判断位于 `:210`。

共享路径先停止并清理所属 recorder、收集 PCM/preview，再检查完整会话取消（`:220`）；已取消则 cancel realtime 并 complete。有效会话随后 seal ingress，检查同一个 frozen latch（`:225`），冻结则 cancel realtime 并返回不可重试的 Recording / interrupted，rawText 为 nil。只有健康结果在 MainActor 再次确认 context 有效后记录时长并继续 audio（`:234`）。正常 Stop 仍只取消录音 Task，不被误判为完整会话取消。

检查了新注入边界的默认值（`:47`）：每次执行仍创建 AudioRecorder/AppleSpeechProvider，路由与设备选择仍调用原单例，context/realtime 默认分别对应原 AXContextProvider 和 liveRealtimeSessionFactory。AXContextProvider 无构造副作用或可变实例状态；默认实例存储时机变化没有引入额外系统探测。SessionContext 原有取消逻辑仍取消 ingress/startTask/session；stage 原 onCancel 与通用错误分支保留。没有改变 controller 的所有权合同。

回归位置：`RecordingStageTerminationSelfTests.swift:102`。四种实际 stage 情况覆盖 healthyStop、fullCancel + freeze、frozenEnd、frozenStop；160 个非零样本验证健康音频不被清空，健康 preview/10 ms 时长保留，实时 session 不被取消。两个冻结结果断言 typed interruption、无可复制/可重试部分结果、实时取消且无成功时长；fullCancel 确认 complete 优先。冻结按 callback → spectrum finish → Task cancel 安排，context 在普通 Stop 中仍有效。

核对原始证据：

- 首次 `ir02-red-build.*` 为 fixture Sendable 编译错误，**不计为行为 RED**。修正后的 `ir02-red-build-fixed.*` exit 0；GREEN build exit 0。两次成功编译保留了 skip-update 弃用提示；未观察到新源代码警告。
- `ir02-red.stdout/.stderr/.exit`：exit 1，19772 passed / 3 failed，恰为 frozenStop 的阻断 audio、实时取消、无成功时长三项。
- `ir02-green.stdout/.stderr/.exit`：exit 0，19777 passed / 0 failed，stderr 为空。多出的两个断言来自正确进入 typed suspension 分支后的检查，不是删减失败断言。
- RED/GREEN 诊断日志中的 session 983 分别为 Recording cancelled → samples 160 与 Recording cancelled → Recording interrupted；982 走自然 stream 完成后的 interruption；980 保持健康 audio；981 保持 full cancellation。
- 当前测试与 `RecordingStageTerminationSelfTests-red.swift` byte-identical；`RecordingStage-red.swift` 与当前源码的差别限定于共享终态修复，保留旧取消分支作为真实行为 RED 的来源。

测试在 preview gate 后的 cancellation check 确定进入同一个真实 catch，未重演原报告中每一种 spectrum 调度交错；共享终态处理与原始 RED 已足以证明这里修复的是实际 frozen/cancellation 漏判。测试停在 stage 返回边界，没有运行下游 ASR/交付；阻断结论来自真实 `.suspend` 结果与既有 controller 分支语义，不能冒充硬件落字实验。IR-02 原缺陷早于 M1，此来源界限不变。

## Issues

- **Critical：无。**
- **Important：未发现新的重要回归；两个原 Important 均已解决。**
- **Minor：无需要单列的修复要求。**

## Recommendations

可以在确切修复身份上执行一次最终集成 release lane，使用显式现有 shader，重新生成并核对源码/产物身份。旧 `4cdfaf4` 技术候选仍只证明旧身份，不能代替本次变更后的 code/full/artifact/smoke 集成结果。无需在本次只读复审中重复定向测试或重开全范围审查。

## Declined to judge

- 真实 shader 的完整新候选打包、签名、移位资源与 Metal/MLX 执行：本次 CLI fixture 有意在 sourceInvalid 处停止；交给一次最终 release 技术门禁。
- 新源码完整 suite、release 构建及十次 smoke：本次仅核对定向原始证据，没有运行集成 lane；不能据旧身份宣称通过。
- 真实设备冻结/拔麦、麦克风权限和 Speech framework 时序：合成外部边界不证明真实硬件行为，对应人工叶子仍 Pending。
- GUI、真实模型推理、云端 ASR、跨应用输入与剪贴板、声学阈值：本次修复复审未执行，原人工 41 叶子状态不变。
- 远端 CI 的真实执行和来源认证：没有远端证据，CI 继续 Pending。
- Developer ID、公证和发布就绪：不属于这两个修复或当前 ad-hoc 技术验证的结论。
- 未受这两个修复影响的 M1–M5 其他路径：沿用先前独立审查的范围和边界，本次未重新全扫。

## Assessment

**Ready for scoped repair acceptance：Yes。Ready for one final release technical gate：Yes。** 两项修复与原要求一致，回归有真实行为 RED/GREEN，并未发现阻止下一次集成验证的新 Critical/Important。**Ready for complete product closeout：尚未证明**；最终技术门禁尚待执行，人工 41 叶子与远端 CI 仍 Pending。
