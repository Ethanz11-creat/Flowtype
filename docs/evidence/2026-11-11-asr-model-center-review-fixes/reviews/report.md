# ASR Model Center 独立代码审查

审查日期：2026-11-10。审查方式：独立、只读；没有修复产品代码，没有创建子代理，没有运行真实模型、网络服务、钥匙串、麦克风、剪贴板、签名、公证或分发操作。

- Base：`aacf49a84d66609c57f9d3809624a08ca95fa79c`
- Reviewed HEAD：`6e0f09f5a3480a7dfd0ca9791f40838d4e940cb9`
- 实际代码候选：`d43a603c13b61b21de7cac4b44c51ceb54404a23`
- 当前 Sources tree：`40f3b4b1c763057f70810596b0eae02b7035c728`
- 当前 scripts tree：`95057298acb707b433912b0652c406a7865f3e6c`

HEAD 与代码候选间仅文档及归档变化；没有将候选报告重新标成文档 HEAD 的验证。按照 requesting-code-review/code-reviewer.md、总计划及 A/B/C/D 相关设计和计划审查，分模块读取当前实现与 base→HEAD 变更、相关测试和候选证据。旧 owner 报告、ruling 与 review verdict 不作为本次免检依据。

## Strengths

1. 后端身份已经贯穿真实调用链：捕获的 descriptor、不可变 provider/config、credential generation 和 native lease 进入 ASRStage，再把实际获胜后端写入历史；仅已选择候选参与路由，loopback 的 socket 需求没有被误当成互联网需求。
2. 云端凭据更改采用新的不可变引用，再将引用与调用配置写进同一配置 blob。读取失败、显式空值、旧 JSON 备份以及跨 profile 引用分别处理，避免旧端点与新密钥组合或删除后旧密钥复活。
3. HF resolver/planner 把来源 commit、文件摘要、目标映射和下载源固定下来；Whisper tokenizer 明确来自已选来源，路径大小写及 Unicode 冲突在下载前拒绝。发布前重新校验文件并严格检查，rename 与提交许可共享同步边界。
4. native activation 保留旧 lease 到候选检查、准入、加载、试识别和持久提交成功。usage token 与真实计算 drain 的组合比单纯取消 Task 更可靠，托管删除还校验 manifest、原始 job 与文件清单。
5. 发行工具明确区分 ad-hoc 技术证据、真实 Developer ID/公证和人工验收；D4 核验提交包的 notary log/hash 与包内 App，candidate reuse 不重建或重签已经验收的 App。

## Issues

### Critical

未发现已支持的 Critical 缺陷。

### Important

#### I1 — 本机服务主选降级后无法恢复，显式测试成功也不能恢复主选路由

- **位置：** `Sources/flowtype/Services/Speech/ASRRouter.swift:590`（特别是 592 的 `.cloud` 限制）；关联 `Sources/flowtype/Services/Speech/Backends/ASRBackendHealthStore.swift:26`、`Sources/flowtype/Services/Speech/Backends/ASRBackendRouting.swift:20`。
- **触发：** `.auto` 策略，主选为 loopback 服务，备选为可用 native、另一服务或已明确允许的云端。主选在连续两次识别中失败，备选均成功。随后用户重启/修复本机服务，但不修改 profile revision 或凭据版本。
- **实际路径：** health store 将所有 location 的失败计数用于降级；routing.order 把降级主选置后。captureStartRoute 的周期性 recovery reservation 却只允许 cloud 主选。loopback 的失败计数没有时间到期，也不会随互联网变化清除；健康备选先成功后 ASRStage 直接结束，因此修复后的主选不再获得成功清除计数的机会。
- **后果：** 主选标签仍是用户选定服务，实际后续识别长期使用备选；若备选是云端，会持续产生本可避免的上传和费用，虽然此前已获得云端备选同意。此问题不是一次临时回退。
- **显式恢复核对：** 模型中心 `validate`（`ASRModelCenterViewModel.swift:330`）只更新自己的验证记录/evidence，不调用 router health。再次“测试识别”或对同一 profile “试用并设为主选”即使成功，也不改变健康键，仍然路由到备选。重启 App、改变 profile/credential 身份，或暂时移除备选后成功听写可以绕过；这些不是正常的服务恢复路径。native 主选也受到通用降级规则影响，但重新激活会产生新 lease revision，故最明确的复现目标是 loopback。
- **建议：** 为每一种可被降级的主选提供有界、按捕获身份隔离的恢复试探；或将同身份的显式成功验证纳入健康恢复。维持现有候选集合、云端同意和共享预算，不扩大路由。
- **测试缺口：** `ASRBackendRoutingSelfTests.swift:353` 附近测试 health 原语的 failure/probe/recovery，但没有“服务主选失败→健康备选持续成功→服务恢复→新 capture 恢复优先级”的实际 router 场景。应同时验证显式测试/重选后的预期恢复行为。

#### I2 — 新模型中心没有取消已开始的原生加载/试识别动作

- **位置：** `Sources/flowtype/Settings/ModelCenter/ASRModelCenterView.swift:68`；关联 `Sources/flowtype/Settings/ModelCenter/ASRModelDetail.swift:202`。
- **触发：** 在已安装原生模型上点击“测试识别”“试用并设为主选”或“设为备选”，随后决定取消，或加载耗时很长。
- **实际路径：** 新界面只显示“请等待验证与计算结束”，试用、编辑、策略、卸载和解除选择等动作在 `model.isBusy` 时禁用。VM 没有 cancel 用户动作；UI action 的 unstructured Task 没有可供取消的句柄。生产页面走新的 ModelCenterHost，旧 `QwenModelStatusCard` 中的“取消准备”不再呈现。安装任务的“取消”仅取消 B4 job，不会取消这里的已安装模型激活；确认 sheet 的“取消”只在发送/加载前有效。
- **后果：** 用户无法撤销仍在执行的选择意图，关闭/重开窗口也只是继续观察同一应用所有者。候选最终成功仍会提交选择；原生加载本身没有 20 秒总 deadline（20 秒从加载后的试识别开始），长时间加载会一直占用模型中心操作槽。
- **界限：** 这里要求的是**可取消当前拥有的操作意图**，并在真实计算排空前继续显示 draining/占用；不是要求关窗口自动取消，也不是要求取消后立即释放 native 内存。现有 `QwenModelState.cancel()`（`QwenModelState.swift:286`）已经能撤销提交资格，缺少的是新 UI/VM 接线。
- **建议：** 在应用所有的 VM 暴露针对当前 operation ID 的显式取消，并在 busy 状态提供可用按钮/键盘取消；保留真实 drain 期间的独占，防止旧取消命中新操作。服务验证同样应能取消当前验证，而不是只有发送前取消。
- **测试缺口：** `NativeActivationSelfTests.swift:387` 通过测试自身持有的 Task 调用 `cancel()`，证明领域取消有效；`ASRModelCenterIntegrationSelfTests.swift:15` 证明关窗重建仍持有操作。这两者都没有证明真实模型中心用户能触发取消。补一个新 VM/UI 操作路由测试即可覆盖缺口。

#### I3 — 外部模型目录移动后的同 UUID 重新定位入口在新界面中丢失

- **位置：** `Sources/flowtype/Settings/ModelCenter/ASRModelCenterView.swift:180`、`:238`；关联 `Sources/flowtype/Settings/ModelCenter/ASRModelDetail.swift:136`。
- **触发：** 用户把已经导入、可能仍为主选/备选的外部模型目录移到其他磁盘或文件夹，再从失败恢复进入该模型详情。
- **实际路径：** 新详情提供测试、选择、解除、移除，但没有“重新定位”。新的目录入口始终调用 `stage(directory:)`，不传 `replacing:`；预览只调用刻意设计成 add-only 的 `savePreview`。原有 `ImportedASRModelList.swift:90` 的重新定位按钮以及 `loadPreview` 的验证事务仍在源码中，但生产模型中心替换旧页面后没有可达入口。`ASRSettingsContent` 的生产分支为 `ASRModelCenterHost`，旧 localModelPicker 也已改成导航提示。
- **后果：** 现有 backend UUID/选择仍指向不存在的旧路径。重新导入新路径会添加新 UUID，不能修复原引用；用户必须解除旧选择、移除旧记录、重新添加及选择，丢失原记录连续性。设计明确承诺目录移位可重新定位并重新验证，旧版本也曾提供该恢复动作。
- **界限：** add-only 导入不允许偷偷覆盖现有行是正确的；问题是独立的**同 UUID 路径修复**没有迁移到新界面，不应通过放宽 add-only 的防护解决。
- **建议：** 为 external 模型详情添加显式“重新定位”，捕获已有 UUID，走现有 `stage(directory:replacing:)`/候选验证事务或等效的新 VM 方法；成功验证后原子更新目录并使旧验证失效，失败保留旧记录/选择。managed 模型继续遵守托管归属限制。
- **测试缺口：** `ImportedModelUISelfTests.swift:78` 的同 UUID relocation 测试仍直接调用旧 actions；`ASRAcquisitionSelfTests.swift:83` 正确断言 add-only 不能 relocation。缺的是新生产页面可到达独立 relocation 动作的测试。

### Minor

#### M1 — 本地识别页面丢失“转写文本仍会发送给云端整理服务”的独立提示

- **位置：** `Sources/flowtype/Settings/SettingsPage+ASR.swift:35`；提示目前仅位于旧分支 `:85`。
- **触发：** `asrRoutingPolicy == .localOnly` 且 `polishOnStop == true`，在生产模型中心查看/配置离线识别。
- **问题与影响：** 生产分支不再渲染 `modeSection`，而新 ModelCenterView/Detail 没有等效的 `SettingsPrivacyPresentation.localPolishDisclosure`。因此用户只看到本地策略、原生离线推理及 ASR 云端备选开关，看不到仍启用的云端文本整理提醒。这没有改变传输逻辑，但回退了既有隐私说明，也与 C 设计“文本润色是否联网仍单独显示”的要求不符。
- **建议：** 把现有 disclosure 和“管理文本整理”入口移到新模型中心策略摘要处，明确其独立于 ASR 路由。
- **测试缺口：** `ReadinessPresentationSelfTests.swift:42` 只测提示字符串生成，不证明生产页面显示它。

## Tests and evidence assessment

本次未重复运行已经通过的重型 code/artifact/release 套件，也未新增 fixture；上述发现可由当前控制流和生产页面可达性直接支持。没有把静态阅读说成运行复现或真实设备验证。

已核对归档报告的 candidate identity：code、artifact、release 都绑定 `d43a603…`，artifact/release 的 binary SHA256 都为 `1c4efb28993f4dad954aff750ea9a1c8f7271615796218e68af41712b4d48854`；当前 Sources/scripts tree 与该候选相符。归档记录 code 28,335/0；code 报告 code-build/code-full 等 7 个 phase 为 Pass，artifact 22 个 phase/10 次 smoke 为 Pass，release 24 个技术 phase/10 次 smoke 为 Pass 而总体 Pending。测试总数不是覆盖率证据。

选读测试显示以下风险确有实质行为覆盖：

- 路由：捕获后修改端点/model/key，再通过实际 batch builder/fixture transport 断言仍使用旧快照；取消主选不回退、禁用候选不读凭据、实际后端历史与恢复定位。
- 凭据：部分迁移、Keychain/持久化失败、tombstone、崩溃重启配对及 namespace 限制，而非仅 Codable 往返。
- 下载与发布：206/200/416、签名 URL 刷新、摘要、取消；真实临时文件/hash/rename，并在 manifest/rename/registration 边界注入失败后检查幂等注册及损坏文件不得入库。
- 原生：空结果/失败不换 lease、指纹/配置变更、取消抵抗计算与真实队列排空、capture token 阻止删除。
- 页面：应用环境重建仍同 owner，稳定 backend/job ID 导航、保存后凭据运行时读取；但领域 helper 通过并未覆盖 I2/I3/M1 的实际页面入口遗漏。
- 发行：签名、公证/包内 App 身份和 ledger 的代码/fixture 不等于真实公证或人工验收。

## Declined to judge

**仅因为“在计划/规格之外”而放弃判断的已考虑行为：无。** I1 的服务恢复和 I2 的用户取消即使不逐项写在 task 清单里，也按合理用户期望评估；I3/M1 还有直接的设计或既有 UI 契约。没有以先前 review/ruling 已通过为理由放弃问题。

以下是本次**未实测的外部检查**，原因是本轮只读/隔离授权及缺失真实验收证据，不是按规格范围排除，也不将其伪装成产品缺陷：

- 全部原 41 项主线 + 新 30 项真机/交互矩阵（71 项仍 Pending）：真实权限、热键/落字、设备切换、窗口焦点/滚动、VoiceOver、长音频等。
- 两个 Qwen、Whisper tiny/base 的真实文件获取、首次加载、离线长音频与实测峰值内存/转写质量；未下载模型。
- 官方 HF/gated/token 授权、真实断网重启/续传及真实磁盘满；未执行网络或改变磁盘状态。
- MLX Audio、WhisperKit、whisper.cpp 参考版本及真实云厂商/地区/型号的端到端协议与错误；未启动外部服务或使用真实凭据。`localhost` 双栈监听行为也未作真实连接试验，不据静态地址顺序单独列为缺陷。
- 真实 Keychain 锁定、权限和正式签名 App 的凭据读取；只审查实现及 fixture。
- 当前候选远端 CI 未运行；历史 run 41672136709 的 failure 不能用本地 Pass 覆盖。
- Developer ID、hardened runtime 真实发行、公证、staple、Gatekeeper、最终 DMG 与干净机器新装/升级；目前只有 ad-hoc 技术候选，distribution/model-center 总验收均 Pending。

## Recommendations and assessment

优先修复 I1 的非云端健康恢复，再补齐新页面对已有取消/重新定位领域能力的接线；回归重点放在新生产 VM/host 的可达动作，避免只继续强化已脱离生产 UI 的旧 helper。M1 可直接复用原有 disclosure。

**Ready to merge? With fixes（当前不建议直接合并）。** 底层身份、安装事务和资源所有权设计扎实，已有故障注入覆盖也有价值；但三个 Important 问题会影响日常服务恢复和用户主动恢复/取消，不能由全量测试 Pass 消除。

**正式发行：尚未就绪 / Pending。** 即使修复上述代码问题，仍需对最终同一候选完成 71 项真机矩阵、当前远端 CI 和 Developer ID/公证/DMG/干净机器证据；本次 review 不替代这些验收。
