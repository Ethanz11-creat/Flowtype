---
license: apache-2.0
language:
- en
- zh
- ja
- ko
- fr
- de
- es
tags:
- speech
- asr
- mlx
- qwen3
library_name: mlx
base_model: Qwen/Qwen3-ASR-0.6B
---

# Qwen3 ASR 0.6B — MLX 4-bit

MLX 4-bit quantized conversion of [Qwen/Qwen3-ASR-0.6B](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) for Apple Silicon inference.

## Usage

Used by [speech-swift](https://github.com/soniqo/speech-swift) `Qwen3ASR` module:

```swift
let model = try await Qwen3ASRModel.fromPretrained()
let text = model.transcribe(audio: samples, sampleRate: 16000)
```

```bash
audio transcribe audio.wav
```

## Model Details

- **Architecture**: Qwen3-ASR encoder-decoder (Whisper-style audio encoder + Qwen3 text decoder)
- **Parameters**: 0.6B
- **Quantization**: 4-bit (MLX)
- **Size**: ~680 MB
- **Languages**: Multilingual (EN, ZH, JA, KO, FR, DE, ES, and more)

---

---

- **Guide**: [soniqo.audio/guides/transcribe](https://soniqo.audio/guides/transcribe)
- **Docs**: [soniqo.audio](https://soniqo.audio)
- **GitHub**: [soniqo/speech-swift](https://github.com/soniqo/speech-swift)
