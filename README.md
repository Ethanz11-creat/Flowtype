# Flowtype

**English** | [简体中文](README.zh.md)

> Voice-to-prompt input for AI coding

Flowtype is a macOS voice input app built for AI coding workflows.

It helps developers turn spoken, messy, and highly verbal thoughts into clearer prompts for coding agents like Codex, Claude Code, and similar tools.

## Why Flowtype

- **Voice is faster than typing** — describe ideas at natural speaking speed
- **Spoken thoughts flow better** — they're more continuous and expressive than typed text
- **Raw transcription isn't enough** — speech is too conversational for AI coding tools
- **Flowtype bridges the gap** — structured, coding-oriented text refinement with one keypress

## Core interaction

| Action | Result |
|--------|--------|
| Single press `Option` | Output raw spoken text |
| Double press `Option` | Output refined, structured prompt text |

## Use cases

- Describe a feature idea hands-free while reviewing code
- Turn rough implementation thoughts into a usable coding prompt
- Quickly draft UI, workflow, and product instructions for AI coding tools
- Brainstorm architecture decisions out loud, then paste the cleaned result

## How it works

1. **Record** — Hold `Option` to start voice capture
2. **Transcribe** — Audio is sent to ASR providers (parallel routing with scoring)
3. **Refine** — LLM cleans up filler words, fixes recognition errors, and structures the prompt
4. **Inject** — Result is typed directly into your active text field

## Architecture

```
Sources/flowtype/
├── App/
│   └── FlowTypeApp.swift          # Entry point, accessory-only app
├── Core/
│   ├── AppState.swift             # Global state management
│   ├── Configuration.swift        # .env-based config & system prompt
│   ├── PipelineOrchestrator.swift # End-to-end audio → text pipeline
│   └── AsyncRefiner.swift         # Async LLM refinement
├── Services/
│   ├── AudioRecorder.swift        # macOS audio capture
│   ├── KeyboardInjector.swift     # Text insertion via HID
│   ├── LLMService.swift           # SiliconFlow API client
│   └── Speech/
│       ├── SpeechRouter.swift     # Multi-provider routing & scoring
│       ├── SpeechProvider.swift   # Protocol
│       ├── ASRPostProcessor.swift # Filler stripping, term correction
│       ├── ASRResultScorer.swift  # Quality scoring
│       ├── TeleSpeechProvider.swift
│       ├── SenseVoiceProvider.swift
│       └── SiliconFlowSpeechProvider.swift
├── UI/
│   └── AudioVisualizer.swift      # Recording visual feedback
├── Utilities/
│   ├── AudioFormatConverter.swift
│   ├── SegmentMerger.swift
│   └── DotEnv.swift               # .env file parser
├── Resources/
│   ├── tech_terms.json            # Tech term corrections
│   └── filler_words.json          # Filler word dictionary
```

## Requirements

- macOS 14+
- Swift 6.2+
- [SiliconFlow API key](https://cloud.siliconflow.cn/account/ak) (for LLM refinement and ASR)

## Setup

```bash
# 1. Clone
git clone <repo-url>
cd Flowtype

# 2. Configure environment
cp .env.example .env
# Edit .env and add your SILICONFLOW_API_KEY

# 3. Build
swift build

# 4. Run
swift run FlowType
```

## Configuration

All settings are managed via the `.env` file:

| Variable | Default | Description |
|----------|---------|-------------|
| `SILICONFLOW_API_KEY` | — | Required. API key from SiliconFlow |
| `ASR_PRIMARY_MODEL` | `TeleAI/TeleSpeechASR` | Primary ASR model |
| `ASR_FALLBACK_MODEL` | `FunAudioLLM/SenseVoiceSmall` | Fallback ASR model |
| `ASR_STRATEGY` | `parallel` | `parallel` (run both, score) or `fallback` (sequential) |
| `LLM_MODEL` | `deepseek-ai/DeepSeek-V3` | Model for prompt refinement |
| `ENABLE_FILLER_STRIP` | `1` | Remove filler words (嗯, 那个, etc.) |
| `ENABLE_TERM_CORRECTION` | `1` | Correct tech term misrecognitions |
| `FLOWTYPE_DUMP_AUDIO` | `0` | Save recordings to `~/Library/Logs/flowtype/` for debugging |

## ASR Evaluation

The `tools/` directory includes an evaluation framework for benchmarking ASR providers:

```bash
cd tools
cp .env ../.env  # ensure API key is available
python evaluate_asr.py --output-dir eval_output/
```

See [`tools/eval_data/README.md`](tools/eval_data/README.md) for dataset details.

## License

MIT
