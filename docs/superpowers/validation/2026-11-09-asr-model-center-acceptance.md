# ASR 模型中心验收（2026-11-09）

本文为新增 H1–H8 真机验收清单，不替代原 V1–V5 / 41 项主线验收。C4 的隔离领域测试与离屏预览不构成下表的通过证据。D2 后续提供机器可读 ledger 和 gate，D3/D4 绑定最终候选身份；所有项目初始 **Pending**。

候选 git SHA / Sources tree / binary SHA256 / 分发包 SHA256：Pending。

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
