# Flowtype

[English](README.md) | **简体中文**

> 语音转 AI 编程提示词

Flowtype 是一款为 AI 编程工作流打造的 macOS 语音输入应用。

它帮助开发者将口头表达的、混乱的、高度口语化的想法，转化为更清晰、结构化的提示词，直接发送给 Codex、Claude Code 等 AI 编程助手。

## 为什么用 Flowtype

- **语音比打字快** —— 以自然语速描述想法
- **口语表达更流畅** —— 比打字更连贯、更有表现力
- **原始转写不够用** —— 语音识别结果对 AI 编程工具来说太口语化
- **Flowtype 弥合鸿沟** —— 一键将语音转化为结构化、面向编程的指令文本

## 核心交互

| 操作 | 结果 |
|------|------|
| 单击 `Option` | 输出原始语音文本 |
| 双击 `Option` | 输出优化后的结构化提示词 |

## 使用场景

- 一边 review 代码，一边口述功能想法
- 将粗略的实现思路转化为可直接使用的编程提示词
- 快速为 AI 编程工具起草 UI、工作流和产品需求
- 大声讨论架构决策，然后直接粘贴整理后的结果

## 工作流程

1. **录音** —— 按住 `Option` 开始语音捕获
2. **转写** —— 音频发送至 ASR 服务提供商（并行路由 + 质量评分）
3. **精炼** —— LLM 清理填充词、修正识别错误、结构化提示词
4. **注入** —— 结果直接输入到当前活动文本框

## 架构

```
Sources/flowtype/
├── App/
│   └── FlowTypeApp.swift          # 入口，菜单栏应用
├── Core/
│   ├── AppState.swift             # 全局状态管理
│   ├── Configuration.swift        # .env 配置与系统提示词
│   ├── PipelineOrchestrator.swift # 端到端音频 → 文本流水线
│   └── AsyncRefiner.swift         # 异步 LLM 精炼
├── Services/
│   ├── AudioRecorder.swift        # macOS 音频采集
│   ├── KeyboardInjector.swift     # 通过 HID 注入文本
│   ├── LLMService.swift           # SiliconFlow API 客户端
│   └── Speech/
│       ├── SpeechRouter.swift     # 多提供商路由与评分
│       ├── SpeechProvider.swift   # 协议定义
│       ├── ASRPostProcessor.swift # 填充词过滤、术语纠正
│       ├── ASRResultScorer.swift  # 质量评分
│       ├── TeleSpeechProvider.swift
│       ├── SenseVoiceProvider.swift
│       └── SiliconFlowSpeechProvider.swift
├── UI/
│   └── AudioVisualizer.swift      # 录音可视化反馈
├── Utilities/
│   ├── AudioFormatConverter.swift
│   ├── SegmentMerger.swift
│   └── DotEnv.swift               # .env 文件解析器
├── Resources/
│   ├── tech_terms.json            # 技术术语纠正表
│   └── filler_words.json          # 填充词词典
```

## 环境要求

- macOS 14+
- Swift 6.2+
- [SiliconFlow API Key](https://cloud.siliconflow.cn/account/ak)（用于 LLM 精炼和语音识别）

## 快速开始

```bash
# 1. 克隆仓库
git clone <仓库地址>
cd Flowtype

# 2. 配置环境
cp .env.example .env
# 编辑 .env，填入你的 SILICONFLOW_API_KEY

# 3. 构建
swift build

# 4. 运行
swift run FlowType
```

## 配置说明

所有设置通过 `.env` 文件管理：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `SILICONFLOW_API_KEY` | — | 必填。SiliconFlow 平台的 API Key |
| `ASR_PRIMARY_MODEL` | `TeleAI/TeleSpeechASR` | 主 ASR 模型 |
| `ASR_FALLBACK_MODEL` | `FunAudioLLM/SenseVoiceSmall` | 备用 ASR 模型 |
| `ASR_STRATEGY` | `parallel` | `parallel`（并行运行，评分选优）或 `fallback`（顺序回退） |
| `LLM_MODEL` | `deepseek-ai/DeepSeek-V3` | 用于提示词精炼的模型 |
| `ENABLE_FILLER_STRIP` | `1` | 去除填充词（嗯、那个 等） |
| `ENABLE_TERM_CORRECTION` | `1` | 纠正技术术语识别错误 |
| `FLOWTYPE_DUMP_AUDIO` | `0` | 将录音保存至 `~/Library/Logs/flowtype/` 用于调试 |

## ASR 评估

`tools/` 目录包含 ASR 提供商的评估框架：

```bash
cd tools
cp .env ../.env  # 确保 API Key 可用
python evaluate_asr.py --output-dir eval_output/
```

数据集详情见 [`tools/eval_data/README.md`](tools/eval_data/README.md)。

## 许可证

MIT
