# ASR 模型中心验收（2026-11-09）

本文为新增 H1–H8 真机验收清单，不替代原 V1–V5 / 41 项主线验收。C4 的隔离领域测试与离屏预览不构成下表的通过证据。D2 提供独立机器可读 ledger 和 gate，D3/D4 绑定最终候选身份；本轮所有 30 项仍为 **Pending**。

2026-11-10 技术候选：git SHA `d43a603c13b61b21de7cac4b44c51ceb54404a23`；Sources tree `40f3b4b1c763057f70810596b0eae02b7035c728`；ad-hoc binary SHA256 `1c4efb28993f4dad954aff750ea9a1c8f7271615796218e68af41712b4d48854`；最终分发包 SHA256：Pending（未生成）。这是技术候选，尚非 Developer ID/公证后的真机验收候选。

[归档与下一步](../../evidence/2026-11-10-asr-model-center/README.md) 保存真实 gate 报告、命令/退出码/hash、全部 Ruling 和最终审查。code 28,335/0；artifact 22/22 phase + 10 smoke Pass；release 复用原 App，24/24 技术 phase Pass，整体 Pending（exit 2）；D4 与本 D2 gate 均真实运行并返回 Pending（exit 2）。原 41 项仍独立 Pending，远端 CI 未运行，真实模型/服务/凭据/辅助功能/发行条件均未执行；无任何 manual Pass。签名改变后二进制身份及最终 package 需重新绑定并实测，不能把本候选 ledger 改 hash 当新观察。

| 组 | 验收范围 | case ID | 状态 |
| --- | --- | --- | --- |
| H1 | HF 链接与仓库解析 | H1.repo | Pending |
| H1 | 多变体选择 | H1.variant | Pending |
| H1 | 双来源 tokenizer | H1.tokenizer | Pending |
| H1 | 受限仓库授权 | H1.gated | Pending |
| H2 | 实际断网与续传 | H2.resume | Pending |
| H2 | 应用重启恢复安装任务 | H2.restart | Pending |
| H2 | 损坏 payload 与完整性错误 | H2.integrity | Pending |
| H2 | 磁盘不足与安全残留清理 | H2.disk | Pending |
| H3 | Qwen 0.6B 4/8-bit 导入与识别 | H3.qwen06 | Pending |
| H3 | Qwen 1.7B 4/8-bit 导入与识别 | H3.qwen17 | Pending |
| H3 | Whisper tiny 多语言 | H3.whisperTiny | Pending |
| H3 | Whisper base 多语言 | H3.whisperBase | Pending |
| H3 | 真正断网加载、超过 30 秒语音首尾 | H3.offlineLong | Pending |
| H4 | 用户安装的 MLX Audio 服务 | H4.mlxAudio | Pending |
| H4 | 用户安装的 WhisperKit 服务 | H4.whisperKit | Pending |
| H4 | 用户安装的 whisper.cpp 服务 | H4.whisperCpp | Pending |
| H4 | 服务实际断连与取消 | H4.disconnect | Pending |
| H5 | SiliconFlow CN 实际型号 | H5.siliconCN | Pending |
| H5 | OpenAI 实际型号 | H5.openAI | Pending |
| H5 | 自定义兼容服务实际识别 | H5.custom | Pending |
| H5 | 坏 key、地区错误与限流 | H5.errors | Pending |
| H6 | 在途切换与旧会话输出 | H6.switch | Pending |
| H6 | 取消后的真实计算排空 | H6.cancel | Pending |
| H6 | 占用删除、用户目录保护 | H6.delete | Pending |
| H6 | Keychain 锁定、凭据更新和恢复 | H6.credentials | Pending |
| H7 | 三档真实窗口、长内容、滚动 | H7.layout | Pending |
| H7 | 键盘焦点、导航与滚动跟随 | H7.keyboard | Pending |
| H7 | VoiceOver、减少动态与材质 | H7.accessibility | Pending |
| H8 | 干净用户目录首次安装 | H8.fresh | Pending |
| H8 | 旧配置升级与既有模型恢复 | H8.upgrade | Pending |

内置中英文合成样本的可懂度、真实模型输出质量、真实网络/服务/麦克风、远程 CI、正式签名与公证均未由 C4 自动化代替。缺少条件的项目保持 Pending；不由历史候选或模拟 fixture 推导 Pass。

## 候选绑定 ledger（D2）

[JSON schema](model-center-acceptance-v1.schema.json) 与 [初始模板](model-center-acceptance-v1.template.json) 属于 `flowtype.model-center-acceptance` schemaVersion 1，与原 41 项 manual schemaVersion 1 不可混用。固定上述 30 个 ID，缺项、重复、未知 ID、错误身份或伪造汇总状态均 Fail。

```bash
scripts/verify-model-center.sh --write-template build/model-center-manual.json
scripts/verify-model-center.sh --report build/model-center-manual.json --manifest build/FlowType.manifest.json --distribution-report build/distribution-report.json
scripts/verify-model-center.sh --self-test
```

Gate 返回 Pass=0、Fail=1、Pending=2、参数错误=64。模板不填入任何真实测试声明，全部 Pending。原 `scripts/verify.sh` 的 41 项 manual 与 CI/技术门禁仍须独立满足；本 gate 不能单独证明整版可发布。

文档及每个 Pass 行的 `candidate` 必须精确一致：`gitSHA`、`sourceTree`（`git rev-parse <gitSHA>:Sources`）、`binarySHA256`、绝对 `appPath`、最终 `packageSHA256`。签名、资源或包身份改变后不能复用旧行。未打包时，候选的 package 可以 null/省略，仅可 Pending；任何声称 Pass 的行或报告缺 package 均 Fail。

Pass 行需 `attestation`：`kind=realManual`，测试者、UTC `testedAt`、Apple Silicon 硬件描述、macOS 15+ 版本、`modelCommitOrServiceVersion`、`actions`、`observation`、相对本 ledger 的非空证据文件路径数组。H3 全组、H4 三项服务、H5 三项厂商识别需 `verification=realRecognition`；H7.accessibility 需 `realAccessibility`；其余需 `realInteraction`。对于无模型的交互项，版本字段记录所测 App/引擎版本及相关环境，不能留空。真人负责描述真实动作和观察；结构验证不鉴定截图内容。配置有效、元数据读取、fixture、离屏预览不能填真实识别或辅助功能通过。

公开 gate 校验 App 实际字节与 manifest，再消费 D4 `DistributionVerificationReport` 声明字段（schemaVersion=1；无新增 discriminator）。D4 candidate 同上，`dmgSHA256 == candidate.packageSHA256`。D4 Pass 还必须有 teamID、hardenedRuntime、两个 notarization ID、stapled、gatekeeperAccepted 和空 issues；D2 不执行签名、公证、联网或服务检查。缺签名/包的 D4 Pending 可保留 null 包身份并使本 gate Pending；字段畸形、身份不符或 D4 Fail 则 Fail。
