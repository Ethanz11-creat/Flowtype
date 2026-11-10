# C：原生模型中心与验证体验设计

父设计及全局约束：[ASR 模型中心](2026-11-09-asr-model-center-design.md)。依赖 [A](2026-11-09-asr-backends-design.md) / [B](2026-11-09-hf-model-installation-design.md) 的接口。状态：待评审。

## 1. 信息结构

沿用原生侧栏和当前视觉体系，在识别设置内集中呈现模型中心，不另建网页或重新设计整个客户端。顶部是主选/备选与策略，主体为“已添加”“获取模型”，底部有可折叠安装任务。列表通过来源筛选查看全部/离线模型/本机服务/云端服务，避免同一模型在多处出现互相矛盾的状态。

已添加行显示：模型/服务名称、具体型号或“由服务端决定”、来源标签、当前状态、主选/备选标识。选中行的详情侧区展示来源 repo/revision/许可证、格式/量化、文件大小、内存估算与不确定性、上次验证、错误和恢复操作。高级参数放详情，不挤进每一行。

获取模型提供“推荐模型”“从 Hugging Face 下载”“导入本地目录”“连接本机服务”“添加云端服务”五个清晰入口。推荐项解释速度/资源取舍，不只展示参数量；内置 Qwen 两项保留。

## 2. 获取与配置流程

HF：输入 repo 链接/ID → 查询元数据 → 选择 variant/revision，必要时配 tokenizer → 展示完整大小、来源、下载源、兼容范围与许可证 → 安装 → 静态检查结果 → “试用并设为主选”或“稍后试用”。大文件下载前必须显示解析出的版本和文件总量；repo 多变体不能默认全下载。失败保留输入与 job。

本地目录：选择完整目录 → 现有严格检测 → 格式/配置与硬件预览 → 加入模型库或“试用并使用”。不复制 GB 权重；说明移除记录不删除原文件。移位时可重新定位，必须重新验证。

本机服务：预设 MLX Audio / WhisperKit / whisper.cpp / 自定义兼容 → 地址、认证与型号（按协议决定必填）→ 配置检查 / 用户主动获取模型列表 → 原子保存未验证配置 → 模型中心显示目的地、内置样本与费用说明 → 用户明确试识别或试用并选择。whisper.cpp 显示服务端模型，不提供虚假的 model 切换。FlowType 不安装或启动这些服务，详情提供对应版本的官方部署指引和手动复制地址示例。

云端：现有编辑草稿继续使用 UUID/修订所有权；选择厂商只应用一次创建默认值，后续不重写 URL/型号/密钥。可发现模型仍允许手填；更改任何影响调用的字段会使旧试用状态失效。新 OpenAI 预设与弃用提示按 A，地区地址保留。草稿仅检查配置；先原子保存未验证配置并定位其 backend，再由同一模型中心 VM 在目的地、样本与费用说明后执行明确 Test / 试用并选择。保存不自动验证、选择或标记就绪；多一次保存交互换取真实已提交配置与凭据版本的唯一验证归属。

## 3. 真实状态与选择

状态分别显示：未安装/排队/下载中/已暂停/校验中/已安装未试用/验证中/上次验证通过/已就绪/不可用/失败。连接地址合法仅叫“配置有效”；GET models 成功仅叫“已读取模型列表”；两者不标识别成功。服务检查结果超过 60 秒显示“上次验证”，下次真实请求仍处理不可用，不靠这个标签绕过错误。

加载或选中动作使用 model/backend 稳定 ID；不能用列表 index。设为主选前原生必须完成候选激活；云/服务允许保存未验证配置但主动作先试识别，验证失败不改主选。编辑已选 profile 需保存新 revision，并使其显示待验证；进行中的录音保留旧快照。删除主选项先显式选替代项或确认进入未就绪；不从列表随意选第一项。

主选与备选不能相同；自动策略只使用明确选择的候选。localOnly/cloudOnly 与选择不相容时显示原因并要求调整，不暗中改策略。用户将本地主选配上云端备选时明确确认允许上传 ASR 音频；文本润色是否联网仍单独显示，不能因本地 ASR 标签宣传整个链路完全离线。

## 4. 试识别与验证记录

新增 `ASRValidationSample`：samples:[Float]、sampleRate:Int=16000、sha256:String、label:String。随 App 提供可再分发的短中文/英文语音 WAV，最长 8 秒；来源/生成方式与 SHA256 写入资源说明。录音权限不是测试前提。自动测试使用合成小 PCM，不把真实用户音频放入 fixtures。

用户点击服务试识别才发送样本，提前说明发往目标服务且云端可能收费；不收集前台上下文/词典/剪贴板。成功以非空最终 text 判断连接与运行可用，展示转写供用户听/看质量；不据此给准确率评分。词典/上下文质量与长音频分段另做矩阵。

`@MainActor ASRModelCenterViewModel: ObservableObject` 由应用拥有，注入 ConfigurationStore、A 的 service validation、B 的 installer/activation；页面重建不丢下载或测试所有权。其 `rows` / `selectedID` / `installations` / `notice` 均为投影，不保存第二套 active 模型。动作：`selectPrimary(_:) async`、`selectFallback(_:)`、`test(_:) async`、`remove(_:deleteManagedFiles:) async`。

readiness、onboarding、状态栏、胶囊、历史详情和恢复导航读取同一实际 backend descriptor。服务断连指向对应 profile；缺文件指向具体模型；下载失败指向具体 job。测试结果和恢复 token 防止旧窗口完成覆盖新选择。

## 5. 布局与交互验收

沿用 1040×700、1120×760、1440×900 三档窗口，浅/深/系统外观。列表密度与现有客户端一致；长中英名称省略但详情可完整阅读，错误可换行、路径可复制。下载总量与进度不依赖颜色区分。支持键盘选择/默认动作/取消、VoiceOver 标签、减少动态效果，窄窗口可切详情而不横向溢出。

不把 SwiftUI 颜色或 padding 写镜像测试。领域 action/投影有自动覆盖；离屏渲染接入现有 NativeClientPreviewSelfTests；滚动、真实窗口焦点、材质、辅助功能和真实服务操作需要真机，离屏截图不替代。

## 6. 新版验证 ledger

新增 `docs/superpowers/validation/2026-11-09-asr-model-center-acceptance.md` 和候选绑定 JSON schema。每行记录 case ID、Pass/Fail/Pending、candidate（git/source/binary/package）、环境/服务版本/模型 commit、操作、观察、证据与测试者。初始全部 Pending。

新增验收组：H1 HF 解析/多变体/分词器/受限授权；H2 下载中断/重启/续传/错误摘要/磁盘；H3 两 Qwen + 两 Whisper 实际离线运行；H4 MLX Audio/WhisperKit/whisper.cpp 实际协议与断连；H5 云厂商/型号/地区与错误；H6 模型切换/旧会话/删除占用/Keychain恢复；H7 页面与辅助功能；H8 新装与升级配置。原 V1–V5 继续是主线验收。

不满足已声明支持矩阵的项不得以“其他模型可用”代替；没有凭据或设备保持 Pending，发行门禁相应不能 Pass。Developer ID、公证与干净机器 DMG 首开/升级的发行工作在 D 计划独立验证。

任务见 [C 实施计划](../plans/2026-11-09-asr-model-center-c-native-experience.md)、[D 发布计划](../plans/2026-11-09-asr-model-center-d-release-acceptance.md)。
