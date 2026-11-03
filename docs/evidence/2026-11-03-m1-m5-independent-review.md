# M1–M5 收尾前独立代码审查

日期：2026-11-03。用户要求按 Superpowers `requesting-code-review` 审查，随后明确范围为M1一直到M5。本轮仅使用一位独立审查子智能体，无嵌套代理；controller复核两项发现的当前源码、调用链和规范依据。

**结论：With fixes。2项Important / P2未关闭，未确认Critical；修复后才能完成M1–M5源码收尾。** 本轮仅审查与记录，没有修改产品源码、执行修复或补做真实验收。

## 范围与证据

- Base：`6aa27fba88fc2dbeb4b41db1ec1088a5220fe5ad`，M0实测记录完成后、首个M1 classifier提交之前。
- Head：`684b18cc9983e1ae799ad78a13709cbe8a54527b`。
- 源码、脚本、工作流及Package差异涉及139个文件，17102行新增/1888行删除。按功能分批检查当前实现、合同和相关测试，不将文件数量或断言数量视为覆盖证明。
- 实际技术运行仍属于被测源码 `4cdfaf42cbea1bd04a63a4803a8d103a23e0178f`，其后至审查Head的源码、脚本、Package和工作流没有变化。既有[运行报告](2026-11-03-m5-development/runs/3683D6F7-2BD5-4F54-A3EF-5F80A38020D0/verify-report.json)记录24个技术阶段Pass、完整自测24334/0、十次smoke通过；整体仍Pending。
- 未重跑构建、完整自测、artifact、smoke或benchmark；未运行Python、下载、安装、读取真实配置/DB/Keychain/模型缓存、启动普通app、录音、申请权限、使用剪贴板/输入或云端服务；未push/merge/发布。

| 阶段 | 本轮实质检查的路径与合同 |
| --- | --- |
| M1 | ReadinessSnapshot/Monitor、权限探测与watch、event tap健康、自愈、状态栏/菜单、SessionController录音前就绪与所有权 |
| M2 | Qwen模型事务、失败/回退意图、旧lease保留与导入提交；Qwen/safetensors检查、Whisper图/tokenizer/离线编译准备；BYOK endpoint/request builder、连接检查revision及配置 |
| M3 | 完整PCM静音预检、捕获route/lease与ASR预算；自动交付事务、逐键对目标复检、剪贴板恢复、真实事件与取消/uncertain |
| M4 | typed失败分类、恢复策略、卡片与会话所有权、同步发布后的调用者检查、录音失败与跨阶段接线 |
| M5 | 早期role和路径/effect隔离、身份与日志；实际timer、bounded进程、打包/签名/资源/恢复；code/artifact/release、证据导出、人工/CI状态聚合 |

## Strengths

会话所有权、取消latch、恢复卡身份、捕获路由和本地模型lease共同约束异步结果；交付区分实际事件前失败与事件后不确定，并检查剪贴板所有权和自动键入目标。M5实际覆盖timer回调、移位资源、严格签名、Metal/MLX运算和确切源码/产物身份；人工与远端CI缺证据时仍保留Pending，没有被本地技术通过覆盖。

## Issues

### IR-01 / Important / P2：未指定shader仍搜索用户缓存

位置：[ArtifactPackagingCLI.swift:75](../../scripts/verification/ArtifactPackagingCLI.swift#L75)，相关分支71–82。

普通打包调用没有提供 `MLX_METALLIB_PATH` 时，CLI遍历 `~/.cache/uv/archive-v0` 和 `~/.cache/pip`，选择首个存在的 `mlx/lib/mlx.metallib`。这与[M5设计§6](../superpowers/specs/2026-11-03-m5-release-guardrails-design.md)第74行明确要求的“显式输入；缺失失败；不查用户cache”不一致。

影响：发生未声明的用户缓存读取，shader来源取决于缓存内容与目录枚举顺序，打包可重复性和输入边界不符合合同。后续artifact运行仍可拒绝不兼容shader；本发现不声称任意shader能伪造runtime通过。最终既有运行使用了显式shader，因此其通过不能覆盖该缺省分支。

建议：移除缓存回退，缺少显式输入时以shaderInvalid失败；通过真实CLI解析/选择路径补合成回归，证明缺参时不调用缓存枚举。现有[ArtifactPackagingSelfTests.swift:76](../../scripts/verification/ArtifactPackagingSelfTests.swift#L76)直接向packager传nil，没有经过CLI的缓存解析分支。

### IR-02 / Important / P2：冻结与普通停止并发时，部分音频可继续进入识别

主要位置：[RecordingStage.swift:171](../../Sources/flowtype/Core/Pipeline/Stages/RecordingStage.swift#L171)，取消分支157–175。

静态可达顺序：

1. 设备心跳失败先调用onRecordingFrozen设置frozen，再finish spectrum：[AudioRecorder.swift:236](../../Sources/flowtype/Services/AudioRecorder.swift#L236)。
2. 用户正常Stop取消录音Task，但保留有效会话context：[PipelineOrchestrator.swift:322](../../Sources/flowtype/Core/PipelineOrchestrator.swift#L322)。
3. 已排队的spectrum迭代在取消后恢复，于[RecordingStage.swift:116](../../Sources/flowtype/Core/Pipeline/Stages/RecordingStage.swift#L116)抛出CancellationError。
4. catch清理后仅检查会话取消，没有检查frozen，直接返回continue(audio)。context仍有效，因此controller接受结果并新建下一阶段Task；这不是全会话取消，下一Task不会因前一录音Task取消而自动停止。

影响：已检测到的设备中断可被当成正常结束，部分语音进入ASR，并可能继续自动落字；本应呈现“录音中断，请检查麦克风后重新录音”。正常stream完成分支137已检查frozen，取消分支缺少同样判断。

**来源边界：该分支在M1之前已存在，本轮没有把它归因为M1–M5引入的新回归。** 但它违反当前[M3静音设计§5](../superpowers/specs/2026-11-02-m3-delivery-and-silence-design.md)第105行的设备错误路径要求，以及M4录音失败不能送ASR/preview的合同，并影响必做V5。没有实际拔麦或硬件复现声明，依据是当前调用链与可达交错。

建议：清理后先处理全会话取消，再统一检查frozen，冻结则取消实时句柄并返回录音中断恢复；最好让两条完成路径共享终态判定。增加非空合成PCM、冻结已发生、正常Stop取消获先执行、context仍活跃的确定性交错回归，断言不进入ASR/交付。当前[M4StageFailureSelfTests.swift:131](../../Sources/flowtype/Testing/M4StageFailureSelfTests.swift#L131)只验证启动失败通知先于finish，未覆盖Stop取消交错。

### Critical / Minor

没有另行成立的Critical或需要单列的Minor发现。另一个候选“verify忽略SIGINT取消”经[VerificationReport.swift:328](../../scripts/verification/VerificationReport.swift#L328)确认已将shouldCancel接入，予以排除，没有列作缺陷。

## Declined to judge 与controller裁定

| 未作通过判断的行为 | 理由与后续处理 |
| --- | --- |
| 普通GUI冷启动、权限恢复时序、跨应用/真实剪贴板、物理设备断开 | 本轮未执行相关真实验收；继续保留对应required叶子Pending，不能据源码判为通过 |
| 真实Whisper/Qwen推理质量及云端厂商互通 | 合成回归/静态源码不足以证明；模型和云端验收继续Pending |
| 轻声、短词、噪声与静音阈值校准 | 没有真实录音；继续Pending，不提升算法能力承诺 |
| 远端CI实际执行及服务端来源认证 | 本地报告结构/身份校验不等于远端认证；CI Pending |
| Developer ID、公证和发布就绪 | 不属于当前ad-hoc技术门禁证明；分发决策与验收保持未完成 |
| 逃逸出已握手进程组的任意后代，以及超出已声明路径合同的敌对文件系统操纵 | 不宣称OS sandbox或全局杀进程能力；不把该边界当成对实际合同内缺陷的豁免 |
| 旧显式Unicode注入模式的兼容行为 | 严格逐键对目标复检合同针对automatic fallback；旧模式兼容保持原范围，真实交付验收仍Pending |

这些不是新增功能缺陷或已通过的行为。controller接受上述证据边界，两个具体源码问题必须单独修复，不能被Pending覆盖或被旧审查通过结论自动关闭。

## Recommendations / Assessment

下一步修复IR-01和IR-02，分别运行有意义的定向回归并限定复审；源码变化后按影响更新技术验证与候选身份。当前审查只完成发现与记录，不提前记录修复成功。41个人工叶子和远端CI独立于这两项源码修复继续Pending。

**Ready for complete closeout：No，With fixes。** 历史技术门禁仍是其精确身份上的有效记录，不能代替上述缺少分支/交错的回归，也不能据此关闭真实验收。
