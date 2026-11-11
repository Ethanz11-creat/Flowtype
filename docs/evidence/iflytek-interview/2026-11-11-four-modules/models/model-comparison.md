# ASCEND deployment comparison

Custom clean-reference subset, not official full validation. Failures retain empty hypotheses. MLX and PyTorch deployment combinations differ; this is not an architecture-only speed comparison.

| Model | engine / dtype / quantization / device / build | Clean edits/units (MER) | mixed edits/units (MER) | failures | ASR RTF | load / warmup / batch (s) | RSS bytes |
|---|---|---|---|---:|---:|---|---:|
| qwen-1.7b | Swift/MLX/speech-swift 0.0.15 / mixed BF16/4bit affine group64 / 4bit / Apple Metal / SPM debug dependency objects | 1362/11479 (11.87%) | 419/2997 (13.98%) | 0 | 0.267 | 0.90 / 2.46 / 887.99 | 1693712384 |
| qwen-0.6b | Swift/MLX/speech-swift 0.0.15 / mixed BF16/4bit affine group64 / 4bit / Apple Metal / SPM debug dependency objects | 1394/11479 (12.14%) | 443/2997 (14.78%) | 0 | 0.216 | 0.94 / 1.51 / 718.64 | 849362944 |
| whisper-base | PyTorch/openai-whisper / FP32 / none / CPU 4 threads / Python package | 5005/11479 (43.60%) | 1535/2997 (51.22%) | 0 | 0.259 | 0.52 / 1.87 / 861.91 | 805076992 |

**Different performance protocols/backends/build modes** are shown above; RSS is macOS process memory, not complete GPU allocation. Warmup is separate; all scoring rows are rerun. Desktop/client load is uncontrolled. Historical baseline is separate.

Examples: first three nonzero-error rows by ID per model, plus first cross-model disagreement; illustrative, not a random distribution.
