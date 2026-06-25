# Flowtype

**English** | [简体中文](README.zh.md)

> Voice-to-prompt input for AI coding

Flowtype is a macOS voice input app built for AI coding workflows.

It helps developers turn spoken, messy, and highly verbal thoughts into clearer prompts for coding agents like Codex, Claude Code, and similar tools.

## About this branch (`flowtype-local`)

This branch contains the **Qwen3-ASR + Modular Pipeline** architecture. Key differences from `main`:

- **ASR Engine**: Uses [`speech-swift`](https://github.com/soniqo/speech-swift) (Qwen3-ASR via MLX, ~300MB 4-bit) directly in Swift — no Python server
- **Pipeline Architecture**: Modular stage-based pipeline (Recording → ASR → PostProcess → Polish → Injection) with `SessionContext` state propagation
- **No Python dependency**: No `uv`, no Whisper Python server, no `setup_whisper.sh`
- **macOS 15+ required** (Swift 6.2)

> **What's missing from GitHub**: `mlx.metallib` (119MB Metal shader library) exceeds GitHub's file size limit. See [Continuing development on another machine](#continuing-development-on-another-machine) below.

## Why Flowtype

- **Voice is faster than typing** — describe ideas at natural speaking speed
- **Spoken thoughts flow better** — they're more continuous and expressive than typed text
- **Raw transcription isn't enough** — speech is too conversational for AI coding tools
- **Flowtype bridges the gap** — structured, coding-oriented text refinement with one keypress

## Core interaction

| Action | Result |
|--------|--------|
| Double press trigger key | Start voice recording (capsule window appears) |
| Single press trigger key (while recording) | Stop and output raw spoken text |
| Double press trigger key (while recording) | Stop and output LLM-polished structured prompt |

> Default trigger key is `Command`. Supports `fn`, `control`, `option`, `command`, `f13`, `f14`, `f15`, `capsLock`, and `rightCommand`.

## Use cases

- Describe a feature idea hands-free while reviewing code
- Turn rough implementation thoughts into a usable coding prompt
- Quickly draft UI, workflow, and product instructions for AI coding tools
- Brainstorm architecture decisions out loud, then paste the cleaned result

## How it works

1. **Record** — Double press the trigger key to start voice capture (a capsule window appears at the bottom)
2. **Preview** — Apple on-device speech recognition shows real-time transcription as you speak
3. **Transcribe** — When recording stops, audio is sent to the local Qwen3-ASR model for high-quality transcription; if the model is unavailable, it falls back to AppleSpeech
4. **Refine** — LLM cleans up filler words, fixes recognition errors, and structures the prompt (double-press end only)
5. **Inject** — Result is typed directly into your active text field

## Features

- **Voice → polished prompt** — local Qwen3-ASR transcription + optional one-key LLM refinement, injected into the focused field
- **Stats dashboard** — an Overview page with total characters / speed / dictation time, estimated time saved, a personalization ring, achievements (active days, current & longest streak, Duolingo-style milestones), a GitHub-style year heatmap, a 24-hour distribution chart, and a fun-fact footer
- **History** — every session is stored in a local SQLite database (via GRDB); browse, search, and export to JSON/CSV
- **Privacy first** — audio is never written to disk; a `storeTranscriptText` toggle keeps metadata only when off; "clear history" wipes transcripts but keeps stats, "reset stats" wipes everything
- **Multiple LLM providers** — OpenAI-compatible; add, edit, delete providers with a built-in "Test connection"; per-provider API key storage
- **Dictionary & style packs** — personal vocabulary (with auto-detected corrections) and switchable polishing prompt templates
- **Theme support** — light, dark, or system appearance; consistent across settings, capsule, and onboarding windows
- **First-launch onboarding** — 4-step wizard (Welcome → Permissions → Quick Config → Demo) guides new users through setup
- **Model download source** — auto-detects region (China mirror vs. official HuggingFace) with fallback; supports custom URLs
- **Security-aware injection** — automatically uses clipboard for secure input fields and non-text controls; pure decision logic with comprehensive self-tests
- **Real-time audio visualizer** — 28-band FFT spectrum with attack/decay envelope during recording
- **Built-in self-test suite** — run `swift run FlowType --self-test` for 25+ diagnostic checks covering config migration, injection logic, database schema, stats computation, SSE parsing, and more

## Architecture

```
Sources/flowtype/
├── App/
│   ├── FlowTypeApp.swift              # Entry point, accessory-only app
│   └── StatusBarController.swift      # Status bar icon & menu
├── Core/
│   ├── Configuration.swift            # Configuration model
│   ├── ConfigurationStore.swift       # UserDefaults persistence with debounce
│   ├── PipelineOrchestrator.swift     # SessionController + SessionState state machine
│   ├── Pipeline/                      # Modular pipeline stage architecture
│   │   ├── SessionContext.swift       # Immutable context passed through stages
│   │   ├── PipelineStage.swift        # Stage protocol
│   │   ├── PipelineRegistry.swift     # Stage registration
│   │   ├── Observers/                 # Real-time state observation
│   │   │   ├── AudioFeedbackObserver.swift
│   │   │   └── SessionObserver.swift
│   │   └── Stages/                    # Individual pipeline stages
│   │       ├── RecordingStage.swift   # Audio capture
│   │       ├── ASRStage.swift         # Qwen3-ASR / AppleSpeech transcription
│   │       ├── PostProcessStage.swift # Filler stripping, term correction
│   │       ├── PolishStage.swift      # LLM refinement
│   │       └── InjectionStage.swift   # Keyboard text injection
│   ├── Database/                      # Local SQLite (GRDB) data layer
│   │   ├── AppDatabase.swift          # Connection + schema migrations
│   │   ├── Records.swift              # SessionRecord / DailyLegacyRecord
│   │   ├── StatsRepository.swift      # DB → daily aggregates for the engine
│   │   └── JSONMigration.swift        # One-time JSON → SQLite migration
│   ├── StatsEngine.swift              # Pure metrics / streaks / heatmap computation
│   ├── StatsConfig.swift              # Thresholds, milestones, conversion constants
│   ├── DailyStats.swift               # SQLite-backed daily-stats store
│   ├── DictationHistory.swift         # SQLite-backed session history store
│   ├── StylePack.swift                # Polishing prompt-template packs
│   ├── Dictionary.swift               # User vocabulary & auto-detected corrections
│   ├── EnvMigration.swift             # One-time .env → UserDefaults migration
│   └── Persistence.swift              # Generic JSON persistence helpers
├── Services/
│   ├── AudioRecorder.swift            # macOS audio capture (16kHz mono Float32)
│   ├── AudioDevice.swift              # Input device enumeration & selection
│   ├── InjectionDecision.swift        # Pure logic: inject keystrokes vs. clipboard paste
│   ├── KeyboardInjector.swift         # Text insertion via clipboard / CGEvent keystrokes
│   ├── LLMService.swift               # OpenAI-compatible SSE streaming client
│   ├── SpectrumAnalyzer.swift         # Real-time FFT audio visualizer (vDSP)
│   ├── SpectrumMath.swift             # DSP helpers: log-spaced bins, smoothing
│   ├── WindowManager.swift            # CGEventTap hotkey setup
│   └── Speech/
│       ├── SpeechRouter.swift         # Provider routing (QwenASR → AppleSpeech fallback)
│       ├── SpeechProvider.swift       # Protocol
│       ├── QwenASRProvider.swift      # Local Qwen3-ASR MLX model (~300MB 4-bit)
│       ├── QwenModelState.swift       # Model load state management
│       ├── ModelLocator.swift         # Finds cached Qwen3-ASR model on disk
│       ├── DownloadSource.swift       # Model download source config (auto/official/mirror/custom)
│       ├── AppleSpeechProvider.swift  # On-device speech recognition (preview + fallback)
│       └── ASRPostProcessor.swift     # Filler stripping, repetition detection, term correction
├── Settings/
│   ├── SettingsView.swift             # SwiftUI settings panel root
│   ├── SettingsWindowController.swift # Settings window host
│   ├── MainWindowView.swift           # Settings tab container
│   ├── OverviewPage.swift             # Stats dashboard (composes Overview/*)
│   ├── Overview/                      # Hero, achievements/milestones, heatmap, 24h, fun-fact
│   ├── HistoryPage.swift              # Session history: search, export, clear/reset
│   ├── VocabPage.swift                # Personal dictionary management
│   ├── StylePage.swift                # Polishing style packs (prompt templates)
│   ├── OnboardingView.swift           # First-launch 4-step wizard
│   ├── OnboardingWindowController.swift
│   ├── QwenModelStatusCard.swift      # Model load status card
│   ├── ServiceConfigCard.swift        # Reusable provider config form
│   ├── ProviderEditSheet.swift        # Add/edit LLM provider with validation
│   ├── ProviderRow.swift              # Provider list row UI
│   ├── SettingsFieldComponents.swift  # Reusable settings UI components
│   ├── SettingsPage+ASR.swift         # Local ASR settings section
│   ├── SettingsPage+Appearance.swift  # Light/dark/system theme
│   ├── SettingsPage+Diagnostics.swift # View diagnostic logs
│   ├── SettingsPage+LLM.swift         # LLM provider configuration
│   ├── SettingsPage+Permission.swift  # Accessibility & microphone status
│   ├── SettingsPage+Privacy.swift     # storeTranscriptText toggle
│   ├── SettingsPage+ProviderActions.swift # Provider management (add/edit/delete/test)
│   ├── SettingsPage+Recording.swift   # Max duration, audio feedback, mic device
│   └── SettingsPage+Trigger.swift     # Trigger key & interaction mode
├── Features/
│   └── Onboarding/
│       └── OnboardingPipeline.swift   # First-launch guide pipeline
├── UI/
│   ├── CapsuleView.swift              # Recording capsule window
│   ├── FloatingPanel.swift            # Panel window host
│   ├── AudioVisualizer.swift          # Recording waveform (28-band spectrum)
│   ├── AppearanceController.swift     # Applies light/dark/system appearance
│   └── Theme/                         # Brand colors, Theme tokens, GlassCard, StatValue
│       ├── Brand.swift
│       ├── FrostBackground.swift
│       ├── GlassCard.swift
│       ├── GrainOverlay.swift
│       ├── StatValue.swift
│       └── Theme.swift
├── Utilities/
│   ├── AppLogger.swift                # File-based diagnostic logging
│   ├── AudioFormatConverter.swift     # PCM format conversion
│   ├── CancellableTimer.swift         # Auto-invalidating timer wrapper
│   ├── DotEnv.swift                   # .env file parser (legacy)
│   ├── KeychainHelper.swift           # Traditional keychain helper (legacy migration)
│   ├── PermissionHelper.swift         # Accessibility permission check & guide
│   ├── SoundFeedback.swift            # Audio feedback for recording events
│   └── UnsafeCell.swift               # Thread-safe value wrapper
├── Testing/
│   └── SelfTest.swift                 # Comprehensive self-test suite (~650 lines)
└── Resources/
    ├── tech_terms.json                # Tech term corrections
    ├── filler_words.json              # Filler word dictionary
    ├── AppIcon.icns                   # App icon
    └── status_bar_icon*.png           # Status bar icons
```

## Model Choice

Flowtype uses [Qwen3-ASR](https://huggingface.co/aufklarer/Qwen3-ASR-0.6B-MLX-4bit) via the [`speech-swift`](https://github.com/soniqo/speech-swift) package — a Qwen3-based ASR model optimized for Apple Silicon via MLX.

### Why Qwen3-ASR

- **Small footprint** — ~300MB 4-bit quantized model, much lighter than Whisper Large v3 (~1.6GB)
- **Fast loading** — loads directly in Swift via MLX, no Python server overhead
- **Native MLX** — runs on Apple Silicon GPU/Neural Engine through Metal
- **Quality** — strong performance on Chinese-English code-switching and technical vocabulary

### Why MLX

[MLX](https://github.com/ml-explore/mlx) is Apple's machine learning framework built specifically for Apple Silicon:

- **Unified memory** — model weights live in system RAM, no VRAM copying overhead
- **Native Metal backend** — compute shaders run directly on the GPU / Neural Engine
- **Low latency** — no network round-trip; transcription happens on-device
- **Privacy** — audio never leaves your machine

## Requirements

- macOS 15+
- Apple Silicon (M1 or later) — for local MLX inference
- Swift 6.2+ — only if building from source
- [SiliconFlow API key](https://cloud.siliconflow.cn/account/ak) — for LLM text refinement only (ASR is fully local)

## Install (downloaded build)

Flowtype is distributed unsigned (no paid Apple Developer certificate), so macOS
Gatekeeper will block it on first launch. The `mlx.metallib` GPU library is already
bundled inside the `.app`, so no extra setup is needed — you only need to authorize it:

1. Move `FlowType.app` to `/Applications`.
2. Remove the quarantine flag macOS adds to downloads (this is the "self-authorization" step):
   ```bash
   xattr -dr com.apple.quarantine /Applications/FlowType.app
   ```
   (Alternatively: right-click the app → **Open** → **Open** in the dialog.)
3. Launch it. On first run, grant **Microphone**, **Speech Recognition**, and
   **Accessibility** permissions when prompted (Accessibility must be enabled manually
   in **System Settings → Privacy & Security → Accessibility**).

> Without step 2 macOS reports the app as "damaged" — that is the Gatekeeper block on an
> unsigned download, not actual corruption.

## Setup

### 1. Build

```bash
swift build
```

### 2. Provide `mlx.metallib` (required for Qwen3-ASR GPU inference)

SPM cannot compile Metal shaders. The `mlx.metallib` file must be copied next to the binary from a Python `mlx` installation:

```bash
# Install Python mlx (if not already installed)
pip install mlx

# Find and copy the metallib
python3 -c "import mlx, pathlib; print(pathlib.Path(mlx.__file__).parent / 'lib' / 'mlx.metallib')"
# Then copy the printed path to:
cp <path-to-mlx.metallib> .build/debug/
```

Common locations:
- `~/.cache/uv/archive-v0/*/mlx/lib/mlx.metallib` (if using `uv`)
- `~/.cache/pip/*/mlx/lib/mlx.metallib` (if using `pip`)

> ⚠️ **Without `mlx.metallib`, Qwen3-ASR will crash at runtime.** This file is intentionally excluded from Git (119MB > GitHub's 100MB limit).

### 3. Run

```bash
swift run FlowType
```

Or build the `.app` bundle (which automatically copies `mlx.metallib` if found):

```bash
./scripts/build-app.sh
open build/Flowtype.app
```

### Self-test

Run the built-in diagnostic suite before first use or after changes:

```bash
swift run FlowType --self-test
```

This runs 25+ tests covering configuration migration, injection decisions, appearance, model config, download sources, model locator, stats engine, database schema, SSE parsing, spectrum math, and FFT correctness.

## Configuration

All settings are managed through the **Settings GUI** (click the status bar icon → Settings, or press `Cmd + ,`):

| Section | Settings |
|----------|---------|
| **Local ASR** | Model load status, language (Auto / 中文 / English), download source |
| **LLM** | Provider(s), Base URL, API Key, Model ID, Test connection |
| **Recording** | Max duration, audio feedback, microphone device |
| **Privacy** | `storeTranscriptText` — store transcript text, or metadata only |
| **Trigger Key** | Fn / Control / Option / Command / F13 / F14 / F15 / Caps Lock / Right Command |
| **Interaction Mode** | Tap-to-start (double-press to start, single-press to end) or Toggle (press to start/stop) |
| **Appearance** | Light / Dark / System theme |
| **Overview** | Usage stats, streaks & milestones, heatmap, 24h distribution |
| **History** | Session history with JSON/CSV export; clear transcripts / reset stats |
| **Dictionary** | Personal vocabulary & auto-detected corrections |
| **Style** | Polishing prompt-template packs |
| **Diagnostics** | View diagnostic logs in Finder |
| **Permissions** | Accessibility & microphone permission status |

Settings are persisted to `UserDefaults` automatically. An existing `.env` file will be **migrated once** on first launch, after which the GUI settings take precedence.

### Data storage & privacy

- **Dictation data** lives in a local SQLite database (`~/Library/Application Support/FlowType/flowtype.sqlite`, via [GRDB](https://github.com/groue/GRDB.swift)). Older JSON files are migrated once and kept as `*.json.bak`.
- **Audio is never written to disk** — the only temporary `.wav` (AppleSpeech) is deleted on every path (success / failure / cancel).
- **API keys** are stored locally in the config (unsigned apps can't use the data-protection keychain), so they persist across launches.
- **Word count** is computed from the *original recognized* text, not the polished result. If polishing fails, the raw text is kept in history and never lost.

### ASR fallback behavior

| Scenario | Behavior |
|----------|----------|
| Qwen3-ASR model loaded | Qwen3-ASR serves final transcription |
| Qwen3-ASR not loaded / crashed | AppleSpeech provides final transcription |
| Real-time preview | AppleSpeech streams live transcription during recording |

### Security-aware injection

Flowtype classifies the focused UI element before deciding how to insert text:

| Focused element type | Strategy |
|---------------------|----------|
| Editable text field (non-secure) | Simulated keystrokes for short text; clipboard paste for multi-line/long text |
| Secure input field (password, etc.) | Clipboard paste only (user must manually paste) |
| Non-text control or unknown | Clipboard paste only |

This logic is fully covered by the built-in self-test suite.

## Build scripts

| Script | Purpose |
|--------|---------|
| `scripts/build-app.sh` | Builds release binary, creates `.app` bundle, copies `mlx.metallib`, generates `Info.plist`, ad-hoc signs |
| `scripts/build-dmg.sh` | Creates distributable DMG from built `.app` with `/Applications` symlink |

## Continuing development on another machine

When cloning this repo on a new Mac, here's what's **not included** and what you need to do:

1. **Clone & build**
   ```bash
   git clone -b flowtype-local https://github.com/Ethanz11-creat/Flowtype.git
   cd Flowtype
   swift build
   ```

2. **Install Python `mlx`** to get `mlx.metallib`:
   ```bash
   pip install mlx
   ```

3. **Copy `mlx.metallib`** next to the debug binary:
   ```bash
   python3 -c "import mlx, pathlib; print(pathlib.Path(mlx.__file__).parent / 'lib' / 'mlx.metallib')"
   cp <path-from-above> .build/debug/
   ```

4. **Run**
   ```bash
   swift run FlowType
   ```

The `.gitignore` excludes: `build/`, `FlowType.app/`, `FlowType` binary, `*.dmg`, and `.build/` (SPM build directory). Only source code and resources are tracked in git.

## License

MIT
