# M2-C 本地 Hugging Face 模型导入设计

日期：2026-11-01；收口更新：2026-11-02。状态：Owner 已批准首批 Qwen3-ASR MLX 和 WhisperKit 兼容 Core ML 方案及 A → B → C 执行顺序。检测、严格离线运行库、统一生命周期和模型库 UI 已实现；真实加载/听写、GUI 与最终全 M2 审查仍 Pending。合成回归、静态模型检查和 tokenizer-only 实测不能替代真实推理验收。
总范围：[M2 设计](2026-11-01-m2-model-recovery-design.md)。

## 支持合同

保留现有 0.6B / 1.7B 4-bit 下载预设，同时建设独立的“导入本地ASR模型”入口：
用户从 Hugging Face 自行下载，选择本机模型文件/目录，由产品识别架构和格式、
匹配本地推理引擎、校验文件和硬件条件，再离线加载并用于听写。
本地模型库应保存多个导入项、显示各自兼容性、允许选择当前使用项；
移除库中记录不删除用户原始模型文件。不能只复用一个Qwen路径字段冒充通用导入。

支持范围以“架构 + 权重格式 + 运行库”列明；Hugging Face 是来源，不是统一的
可执行模型格式。不是所有ASR仓库都能在现有Swift/MLX/Core ML运行，不承诺任意
文件即插即用。未知格式须说明缺少什么支持，不能只让用户选中目录后标为已就绪。
不执行模型仓库脚本或trust_remote_code。新增运行库属于本工作包的显式实现范围，
不能只预留适配器而将尚不能使用的模型标为支持。

## 运行方案与首批范围

推荐原生多引擎适配：统一导入/模型库/生命周期，按各架构加载。相较于直接沿用
Qwen目录选择，它需要扩展本地provider、路由和readiness的身份表示；这些改动
属于实现用户要求所需的范围。首批建议Qwen3-ASR MLX + Whisper Core ML，
再按具体目标仓库核对变体。Owner 的后续“开发吧”承接这个方案；Parakeet和
Omnilingual保留候选，不纳入本轮已实现承诺。

| 候选 | 可研究的HF模型格式/来源 | 已有依据与接入代价 |
| --- | --- | --- |
| Qwen3-ASR | 当前兼容MLX目录；0.6B/1.7B、4/8-bit、group size64 | 已链接 speech-swift Qwen3ASR，严格结构检测和自定义身份已实现；真实变体验收 Pending |
| Whisper | `argmaxinc/whisperkit-coreml` 的兼容Core ML子目录及同布局自定义导出 | 已获取WhisperKit官方README；已集成 exact WhisperKit 0.18.0 及完整离线 tokenizer 检查；真实图加载/推理 Pending |
| Parakeet TDT | `aufklarer/Parakeet-TDT-v3-CoreML-INT8` 同布局模型 | 已有依赖提供独立product，产品未链接；注意其语言范围和单窗口截断，不能直接当作完整长录音识别 |
| Omnilingual CTC | speech-swift文档所列Core ML/MLX转换布局 | 已有依赖提供独立product，产品未链接；需要独立分词器、窗口/时长及取消适配 |

另一方案是自带Python/Transformers后端，能覆盖更多原始HF架构，但增加Python、
PyTorch、包版本和分发维护，并非所有仓库都能用同一个pipeline。第三种是让用户
自行运行本地模型服务再填API，它可作未来扩展，不能替代本轮本机文件导入。
不会未经决定就引入Python环境或下载模型运行库。

Owner 未指定具体仓库，不再以此为阻塞；按Qwen兼容MLX和WhisperKit兼容Core ML
形成首批清单，后续具体仓库逐项记录兼容性。
特别注意 `openai/whisper-*` 原始权重与WhisperKit兼容Core ML导出不是同一格式；
选择Whisper Core ML不能宣称已经支持前者，原始权重/自动转换需单独评估。

“导入”指选择本机目录并记录路径，不复制数GB权重、不上传至FlowType或第三方。
支持模型根目录及有效的HF snapshot目录，允许其指向本地blobs的正常符号链接；
不把缓存仓库根目录或 refs/main 当作权重目录。移动/删除文件后给重新选择入口。

## 检测与描述

按格式读取配置、模型图或权重头/索引得到独立的模型描述：family、运行格式、规模、
量化、目录、可选来源repo与磁盘体积。用户看到的来源名称与用于调用现有加载器
的兼容身份分开；不得把自定义模型显示成官方preset或根据目录名默认为0.6B。

模型结构元数据优先于文件夹名。按已支持的音频/文本配置以及张量形状确认规模；
quantization bits/group size与权重布局冲突时拒绝，不自动改成另一模型配置。
缺失关键信息且无法从权重确定时显示“无法确定兼容性”，而非猜测后加载。
Qwen底层依赖从modelId推断规模/位数，其导入适配层只在检测成功后提供相应兼容身份。
离线加载仍指向用户目录，绝不把这个内部兼容身份当作联网补齐的repo。

校验按各运行库分别实现，不对Core ML等格式强制要求safetensors/vocab.json。
以下为Qwen适配器的静态校验细则；Whisper的对应文件合同见后文：

1. 目录可读、config可解析；限制元数据读取大小，避免整文件读入权重。
2. 分词器按当前加载器实际需求检查 vocab.json 及需要的配套文件，不能仅有
   tokenizer.json就宣称满足当前加载器；词表需可解析且含所需特殊token。
3. 单文件或分片safetensors可读；有索引时核对所有映射分片、张量和边界，
   无索引时核对已支持结构需要的张量集合/形状。拒绝Git LFS指针、截断文件、
   断链、重复冲突张量或缺分片。索引路径不得逃出所选目录；合法HF符号链接
   仍允许解析到blobs，不通过文件名猜文件完整性。
4. 对照受支持布局检测架构、规模、量化；原始PyTorch权重即使是safetensors
   也不能只凭后缀接受。未知布局显式拒绝，提供支持格式说明。

这些检查只证明文件布局通过静态校验。运行库会容忍部分缺失权重，因此
不能仅以fromPretrained未抛错替代必要张量检查；最终还需要离线加载结果。

Whisper采用WhisperKit exact0.18.0，要求MelSpectrogram、AudioEncoder、TextDecoder
的兼容mlmodelc/mlpackage，以及本包或明确tokenizer子目录中的tokenizer.json、
tokenizer_config.json；可选TextDecoderContextPrefill。需校验Core ML图输入/输出、
模型维度、多语言/英语词表和special token匹配，不能将原始PyTorch权重直接接受。
仓库根有多个变体时要求选择具体子目录；单个模型子目录可独立导入。
完整图检查在 WhisperKit 的维度快捷访问器之前读取原始 Core ML 描述：必要名称、
MultiArray 类型、rank、30秒音频/3000 mel帧/1500编码帧、编码器与解码器接口、
KV缓存/更新/mask和可选prefill一致性均须通过。输出不允许声明不兼容的可变形状；
输入可以包含更宽的可接受形状，但运行时只传递已检查的固定默认尺寸。
缓存允许224…448上下文、1…32个解码层的整倍数宽度，保留distil/turbo减层变体；
身份仍只报告图可证实的家族，不把相同维度冒充某个具体checkpoint。

Qwen基础byte-BPE词表必须覆盖0…151642、完整256字节字母表及151387条有序、
无重复、引用有效且覆盖全基础词表的合并规则；附加token覆盖151643…151704，
加载器关键token保持确切ID。附加词条可位于vocab或tokenizer_config；
151705…151935是合法的模型填充槽，缺少对应词条不视为词表截断。


严格离线通过OfflineWhisperKit覆写本地tokenizer加载实现，使用AutoTokenizer的
modelFolder入口和产品内的WhisperTokenizer协议适配器，避免上游内部wrapper不可访问
和ModelUtilities解析失败后联网的兜底。modelFolder/tokenizerFolder显式设置，
download=false、load=false后显式加载。上游私有setter的modelVariant不用于本产品
身份或推理配置；本产品从实际模型图确定variant及textDecoder多语言标志。

## 硬件与导入事务

读取本机处理器架构、物理内存和可用内存估计，展示模型体积与硬件建议。
硬件条件按运行库判断；当前MLX运行路径仅对支持的Apple Silicon环境开放加载，
Core ML等运行路径另列条件，不能把Qwen的限制套给所有ASR。当前固定的WhisperKit
0.18在Intel上将FloatType定义为Float，却分配Float16缓存并按FloatType字节宽度复制，
因此此运行库路径在Intel上提前拒绝，并在原始图验证入口再次检查ABI；Apple Silicon
路径保持开放。这不是Core ML格式或所有Whisper实现不支持Intel的结论，后续运行库
适配可重新评估。硬件不兼容直接解释原因。
4-bit已知预设沿用现有0.6B最低4GiB、1.7B最低8GiB及现有推荐档位，但将其
标为产品建议，不能当作实际峰值。8-bit只显示有依据的估算/建议；没有验证数据
就显示“运行内存需求未实测”，不从文件大小生成保证可运行的标签。
资源提示还要考虑保留旧模型时新旧模型同时驻留的峰值；明显不足时阻止本次加载
并建议较小模型，不为完成切换而自动卸载仍可用的模型。

用户选目录→显示检测结果与资源提示→点击“加载并使用”。目录选择和静态校验
不覆盖当前选择。加载由M2-A同一协调入口执行，offlineMode固定true；不得自动
发预检/下载请求。期间保留旧模型，失败/取消/过期回调不能替换或卸载它。
校验与加载之间重新确认文件身份；文件变化则重新校验，不沿用旧的通过状态。

成功后才保存模型库导入项及active引用；兼容旧配置的Qwen项同步当前自定义路径，
并将selectedLocalModelID置nil。明确选择的导入项优先于自动推荐，UI展示真实架构
与来源。自定义导入是
显式离线操作，不参与自动preset的1.7B→0.6B降级。失败保留此前配置。旧localModelPath
继续兼容读取，首次使用前检测；旧配置的体积/推荐preset不能成为导入身份依据。
重复导入可重试；切回内置preset是显式操作，不删除自定义目录。

## 扩展与模型来源

静态受支持格式目录与运行库适配分开。HF搜索、任意repo远程执行和自动转换模型
不属于当前已确认的交互要求；优先让用户已有文件可检测、可选择、可实际离线识别。
来源链接和帮助覆盖最终支持的每种格式，不能只链接两个Qwen预设。
研究候选按family、格式、语言、许可、运行库、硬件实测记录。首批架构须完成
加载器与真实离线验收；后续候选保持“未接入”，预留接口不等于实现支持。

## 验收

临时目录与小型合成元数据覆盖两种规模/两种量化的识别、被改名目录、未知family、
config与张量冲突、group size不符、tokenizer不完整、缺分片、LFS指针、截断头、
索引路径越界、合法HF链接与断链、检查后文件变化、硬件建议和内存未知提示。
注入loader验证offline=true且零网络；失败/取消保留旧模型、成功才持久化、
重试与晚回调隔离。合成头只验证静态检测，不宣称真实推理通过。

真实验收用每个首批架构的完整兼容模型：断网导入、加载、短句识别、超过引擎
单窗口的录音首尾完整性、取消、切回preset、失败目录恢复。Qwen的0.6B/1.7B、
4/8-bit以及其他引擎各变体/硬件分别记录覆盖；没有模型的变体保留
Pending。禁止删除当前工作模型或改写用户权重来制造失败。

来源：当前speech-swift的ASRModelSize、TextDecoderConfig、Qwen3ASRModel.fromPretrained、
WeightLoader，以及本产品CustomModelScanner / ModelLocator。公开HF config直连本轮
超时，尚未在线复核模型卡/许可或实际自定义仓库兼容性；依赖能力不等于仓库实测。
新增调研还读取了当前依赖ParakeetASR / OmnilingualASR的模型文档和加载源码，
以及[WhisperKit官方README](https://github.com/argmaxinc/WhisperKit)（本轮已获取）。
后续已读取WhisperKit v0.18.0完整源码（临时只读参考clone），核实本地模型加载、
tokenizer联网兜底、override hook与公开协议；具体接口固化在实施计划。产品已固定依赖并实现适配，未运行完整真实模型推理；不将源码能力或 tokenizer-only 证据当作已完成离线推理验收。
