# FlowType ASR 模型中心设计

日期：2026-11-09；基线 `288aa9a6d02ce966a05dbd3fe71a6e26f6a9ad21`。状态：**待用户评审的设计与实施计划，未开始产品开发**。用户已认可完整模型中心范围，并明确要求深入调研后使用 writing-plans；本次一并交付书面设计与分项计划，执行在文档评审后开始。

## 1. 产品目标与成功标准

FlowType 是 macOS 原生听写应用，也提供可替换 ASR 后端的公共链路。用户能更换云厂商与型号，从 HF 安装兼容离线模型、导入已有目录、连接自行启动的本地模型服务；这些选择共享录音、取消、润色、恢复、落字和历史。

完成意味着六条端到端路径全部可验证：新建云端 → 试识别 → 听写；推荐离线模型 → 下载 → 验证 → 使用；HF 链接 → 变体/固定版本 → 安装 → 使用；已有目录 → 检查 → 试识别 → 使用；本地服务 → 协议配置 → 验证 → 使用；任意失败/取消 → 明确恢复动作且不破坏原可用模型。

## 2. 已选方案与替代方案

采用 **原生双引擎 + 用户管理的本地服务 + 统一模型中心**。原生支持沿用 Qwen3-ASR MLX 和 WhisperKit Core ML；服务适配 OpenAI 风格 batch 与 whisper.cpp inference，现有 DashScope realtime 保留。

只增加原生引擎的方案安装简单，但每种新架构都要求 App 集成；捆绑通用 Python 服务的方案覆盖面更广，但会引入运行环境安装、转换、更新和进程管理子系统，仍不能保证任意 HF 仓库可运行。本版通过可适配服务扩展架构覆盖，保持用户已选择的自行启动方式。

## 3. Global Constraints

以下原文同时适用于各分项计划：

- 平台为 macOS 15+、Apple Silicon、Swift 6.2；保留 macOS 原生 SwiftUI 客户端。
- 保持 speech-swift 0.0.15、WhisperKit 0.18.0、swift-transformers 1.1.9 锁定基线；新增依赖或升级必须单独说明依据。
- 核心音频契约为 16kHz、单声道 Float32；协议适配器负责 wire 编码；一次录音只交付一次终稿。
- 原生推理严格离线；下载是显式独立操作；外部模型服务由用户自行安装、启动和更新。
- 下载、检查、加载、试识别、选中分别建模；失败或取消不替换已有可用选择，不删除用户自有模型。
- 录音开始捕获不可变后端、模型、能力与凭据快照；迟到回调不能改变新会话或新配置。
- 自动化使用隔离临时根、合成文件与注入 transport；不读写用户真实配置、密钥、模型、权限或剪贴板。
- 各任务顺序运行 swift build 与 self-test；最终运行现有 code/artifact/release 门禁；Pending 不等于 Pass。

## 4. 模块边界

| 模块 | 职责 | 依赖与输出 |
| --- | --- | --- |
| Backend catalog / registry | 标准身份、能力、编译期工厂注册 | 消费配置/原生 lease，产出捕获的识别后端 |
| Protocol adapters | OpenAI 风格 HTTP、whisper.cpp HTTP、DashScope WS | 请求/响应/错误/取消；不负责 UI 或安装 |
| HF source resolver | 仓库解析、commit、文件与变体发现 | 不下载权重，输出精确 install plan |
| Installer | 下载任务、续传、校验、事务安装、存储归属 | 输出本地目录和 manifest，不直接改 active 模型 |
| Native activation coordinator | 检查、资源准入、加载、试识别、提交 lease | 复用 QwenModelState 的唯一生命周期所有权 |
| Model center | 统一列表、编辑、安装与试用、主选/备选 | 调用领域动作，不在 View 内实现网络与路由 |

开发者增加后端应注册协议工厂/引擎适配器与能力描述，不在 ASRStage、View、History 中增加厂商品牌 switch。注册是应用内的开发扩展点，不宣称用户可安装任意二进制插件。

分项契约：[A 后端](2026-11-09-asr-backends-design.md)、[B HF 安装](2026-11-09-hf-model-installation-design.md)、[C 原生体验](2026-11-09-model-center-experience-design.md)。

## 5. 数据与生命周期

持久化保存 backend/model reference、来源 commit、目录归属、安装 manifest 与验证记录。凭据正文不进入新持久化类型或下载 journal；调用前读取并捕获。旧 ASR 配置迁移按 A 的可重试规则保留密钥与自定义值。

原生激活先构造候选，静态检查与内存准入后加载、试识别，最后在同一 MainActor 事务提交 selection 和 active lease。失败不提交；取消立即失去提交资格，但底层未排空时仍保留资源所有权。正在录音的 lease 保持有效。

安装完成仅表示文件可作为候选。验证记录绑定文件指纹、engine version 与验证音频；服务验证绑定配置 revision 与 credential generation。重启显示“上次验证通过”，本次成功加载前不显示“已就绪”。

## 6. 发行范围与验收

四份计划共同组成同一版完整交付；内部可分阶段提交，不能把安装器或页面完成单独宣称整版完成。首批推荐候选为 Qwen 0.6B/1.7B 4-bit、Whisper tiny/base 多语言；只有最终矩阵实际通过的配方才能获得“推荐/已验证”标识。配置能力可用但真机未验证的模型如实标注。

验收层级：纯领域与故障注入 → 真实网络 transport fixture → 原生页面集成/布局 → 模型/厂商/服务真机 → M1–M5 回归 → 正式分发。B 的下载故障不能用模拟测试代替真实断网恢复；A 的协议 fixture 不能当真实厂商成功。

发布仍受既有 CI 失败、41 项主线真机验收和正式签名/公证约束。新增模型中心验收使用独立版本化 ledger，不改变原 41 项 schema/ID，也不复用旧候选 Pass。发行身份必须绑定 git SHA、Sources tree、binary SHA256 与分发包 SHA256。

现有 release lane 会重新构建 App；D4 必须增加显式 `--candidate-manifest <absolute path>` 验证模式，对已经签名/公证的候选复用其 manifest，保留 clean source、签名、资源与十次 smoke 验证，不重建或重签。只有该候选才能与其真机和发行报告汇总；缺省行为仍是原有构建验证。

## 7. 本版明确边界

支持完整 HF 文件夹与支持格式的仓库下载，不提供任意 zip 解包、模型格式自动转换或 repo 脚本执行。可输入任意合法 HF repo 进行兼容性评估，不承诺任意架构可原生加载。

本机服务入口只接 loopback；远程自建 HTTPS 服务可作为自定义云端 profile 使用。不同协议须有相应适配器。首版不新增通用实时协议、外部服务进程管理、自动镜像密钥转发、插件市场、Intel 支持或 localhost 网页。

## 8. 研究与计划

[研究与来源](../research/2026-11-09-asr-model-center-research.md)。[实施索引](../plans/2026-11-09-asr-model-center.md) 按 D1 → A → B → C → D2–D4 执行；A/B/C 各自提供能独立验证的领域交付。执行方式沿用子智能体驱动，同一时刻最多 1 个子智能体。
