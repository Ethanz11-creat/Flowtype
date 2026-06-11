# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

FlowType is a macOS voice-input app for AI coding workflows. It captures speech, transcribes via a local Qwen3-ASR MLX model, optionally refines with an LLM, and injects the result into the active text field. Swift 6.2, SPM, macOS 15+.

## Build & Run

```bash
swift build                    # Debug build
swift run FlowType             # Run from CLI (requires mlx.metallib next to binary)
swift run FlowType --self-test # Pure-logic self-tests (exit 0 = all pass)
./scripts/build-app.sh         # Build .app bundle → build/Flowtype.app
./scripts/build-dmg.sh         # Build distributable DMG
```

**Testing**: the real test suite is `swift run FlowType --self-test` (`Sources/flowtype/Testing/SelfTest.swift`) — pure-logic assertions compiled into the main target; exits 0 on all-pass, 1 on any failure, so CI can gate on the exit code. Package.swift also declares a `FlowTypeTests` XCTest target, but Command-Line-Tools-only machines have no XCTest module so `swift test` cannot run there (it works once full Xcode is installed). The project has no linter configured. Verify changes with `swift build` and the self-test.

**Metal shaders**: SPM cannot compile Metal shaders. The `mlx.metallib` file from the Python `mlx-metal` package is copied next to the binary at build time. For `swift run`, manually copy it: `cp ~/.cache/uv/archive-v0/*/mlx/lib/mlx.metallib .build/debug/`

## Logs

Diagnostic logs write to `~/Library/Logs/flowtype/diagnostic.log` via `AppLogger.log()`. Use this instead of `print()` — stdout is lost inside .app bundles. All log lines are prefixed with ISO8601 timestamps and component tags like `[SessionController#1]`, `[QwenASR]`.

## Architecture

### Session lifecycle (state machine)

`PipelineOrchestrator.swift` contains both `SessionState` and `SessionController` — the central orchestrator. This is the most critical file.

```
SessionState: .idle → .recording → .processing → [.polishing] → .injecting → .idle
                                                                    ↘ .notice → .idle (auto-dismiss ~2.2s)
                                                                    ↘ .error  → .idle (auto-dismiss 5s)
```

`.notice` is the gentle degradation path (e.g. LLM polish failed → raw text delivered instead): purple, no buttons, slides away on its own. `.error` is red and carries recovery semantics (retry / copy raw / dismiss actions).

`SessionController` is a `@MainActor ObservableObject` singleton. It owns the full pipeline: audio recording → batch Qwen3-ASR transcription → optional LLM polish → keyboard injection.

### Audio pipeline

1. **AudioRecorder** captures mic input at 16kHz mono Float32, accumulates raw samples
2. During recording, **AppleSpeechProvider** provides real-time preview text
3. On recording end, accumulated samples are sent to **QwenASRProvider.transcribe()** for batch ASR
4. If Qwen3-ASR fails or isn't loaded, AppleSpeech preview text is used as fallback
5. Result is post-processed by **ASRPostProcessor** (filler stripping, repetition detection, tech term correction, Chinese punctuation)

### Provider routing

- **SpeechRouter** holds two providers: `qwenProvider` (QwenASRProvider) and `fallbackProvider` (AppleSpeechProvider)
- Real-time preview during recording uses AppleSpeech streaming
- Final transcription uses Qwen3-ASR batch mode with AppleSpeech as fallback
- **QwenASRProvider** wraps `speech-swift` (Qwen3ASR MLX, ~300MB 4-bit model)

### Hotkey & UI

- **WindowManager** sets up a CGEventTap for the trigger key (default: Command)
- **OptionTapDetector** detects single/double taps with a 0.35s window
- Double-tap starts recording; single-tap ends with raw ASR; double-tap while recording ends with LLM polish
- **FloatingPanel** / **CapsuleView** show the recording UI at screen bottom

### Configuration

- `Configuration` struct (Codable) with backward-compatible decoding — new fields get defaults
- `ConfigurationStore` persists to UserDefaults with 0.5s debounce (`flushPendingSave()` on quit); API keys are stored locally in `Configuration.providerAPIKeys` — Keychain (`KeychainHelper`) is only used by legacy migrations, since unsigned apps fail `SecItemAdd` (-34018)
- LLM config: multi-provider list (`llmProviders`, one active) for OpenAI-compatible APIs (default: SiliconFlow + DeepSeek-V3)

### Text injection

**InjectionStage** samples the focused element at delivery time (`KeyboardInjector.currentFocusSignals()`); the pure function `decideInjection` (`InjectionDecision.swift`) picks one of two outcomes:
- Editable text, or AX-blind focus (terminals/Electron — fail open) → `KeyboardInjector.insertText()`: CGEvent Unicode typing in 64-char chunks, newlines sent as Shift+Return, 20k-char cap
- Secure input or a non-text control → text is written to the clipboard + sound cue; the clipboard IS the delivery destination (no Cmd+V is sent, the previous clipboard is not restored)
- If typing fails mid-way it also falls back to clipboard — text is never lost

## Key Constraints

- `SessionController` is `@MainActor` — all state mutations happen on the main thread
- The app runs as `.accessory` (no dock icon) — UI is status bar menu + floating panel only
- Audio format: 16kHz mono Float32 for Qwen3-ASR
- MLX requires Metal GPU — `mlx.metallib` must be colocated with the binary
- `speech-swift` types (Qwen3ASRModel, StreamingASR) are not Sendable — use `nonisolated(unsafe)` + DispatchQueue for thread safety
