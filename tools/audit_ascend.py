#!/usr/bin/env python3
"""Audit the pinned ASCEND validation parquet; no inference or cloud requests.

Dependencies: numpy, pyarrow, soundfile. See the generated report for provenance.
Audio and reference exports inherit the dataset's CC-BY-SA-4.0 terms.
"""

import argparse
from collections import Counter, defaultdict
import hashlib
import html
import io
import json
from pathlib import Path
import random
import re
import sys
from datetime import datetime, timezone

import numpy as np
import pyarrow.parquet as pq
import soundfile as sf


REVISION = "737e9800ae31be9932ba8464c80366559bd28424"
PARQUET_SHA256 = "3bdec53d2abfd3dd4f0d86a6df4e27e60f20660edc9b66055ae0ef8ec05cf7e2"
SOURCE = "https://huggingface.co/datasets/CAiRE/ASCEND"
SEED = 20261111

# Exploratory coverage probes chosen for our target domain, not ASR prompts.
# Aliases are explicit; matches require Latin token boundaries even next to Hanzi.
TARGET_TERMS = {
    "PyTorch": ["pytorch", "py torch"], "TensorFlow": ["tensorflow", "tensor flow"],
    "LoRA": ["lora"], "QLoRA": ["qlora"], "Transformer": ["transformer", "transformers"],
    "attention": ["attention"], "RAG": ["rag"], "LLM": ["llm", "llms"],
    "CUDA": ["cuda"], "GPU": ["gpu", "gpus"], "API": ["api", "apis"],
    "Docker": ["docker"], "Kubernetes": ["kubernetes", "k8s"],
    "Python": ["python"], "tokenizer": ["tokenizer", "tokenizers"],
    "embedding": ["embedding", "embeddings"], "batch size": ["batch size", "batch-size"],
    "learning rate": ["learning rate", "learning-rate"], "checkpoint": ["checkpoint", "checkpoints"],
    "fine-tuning": ["fine tuning", "fine-tuning", "finetuning"], "inference": ["inference"],
    "Hugging Face": ["hugging face", "huggingface"], "DeepSeek": ["deepseek"],
    "Qwen": ["qwen"], "OpenAI": ["openai", "open ai"], "GitHub": ["github", "git hub"],
    "JSON": ["json"], "SQL": ["sql"], "ASR": ["asr"], "Whisper": ["whisper"],
}
CONSUMER_TERMS = {
    "smartphone": ["smart phone", "smart phones", "smartphone", "smartphones"],
    "app": ["app", "apps"], "computer": ["computer", "computers"],
    "Cortana": ["cortana"], "TV": ["tv"], "online game": ["online game", "online games"],
}
TIME_PATTERN = re.compile(
    r"(?P<recording>ses(?P<session>\d+)_spk(?P<speaker>\d+)(?:_\d+)?)_L\d+_(?P<start>\d+(?:\.\d+)?)_(?P<duration>\d+(?:\.\d+)?)\.wav$"
)


def term_hits(text, terms):
    result = {}
    for name, aliases in terms.items():
        alternatives = sorted((re.escape(a) for a in aliases), key=len, reverse=True)
        pattern = r"(?<![A-Za-z0-9_])(?:" + "|".join(alternatives) + r")(?![A-Za-z0-9_])"
        count = len(re.findall(pattern, text, flags=re.IGNORECASE))
        if count:
            result[name] = count
    return result


def distribution(values):
    values = np.asarray(list(values), dtype=np.float64)
    if not len(values):
        return None
    return dict(zip(["min", "p05", "median", "p95", "max"],
                    [float(x) for x in np.percentile(values, [0, 5, 50, 95, 100])]))


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--parquet", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    digest = hashlib.sha256(args.parquet.read_bytes()).hexdigest()
    if digest != PARQUET_SHA256:
        parser.error("Parquet hash differs from the audited validation revision; investigate before running")
    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    samples_dir = output / "samples"
    samples_dir.mkdir(exist_ok=True)
    table = pq.read_table(args.parquet)
    source_rows = table.to_pylist()
    if len(source_rows) != 1130:
        parser.error("Expected 1,130 validation rows")
    rows, hashes = [], defaultdict(list)
    for index, source in enumerate(source_rows):
        row = {k: v for k, v in source.items() if k not in ("audio", "path")}
        row["source_audio_filename"] = Path(source["path"]).name
        row["row_index"] = index
        row["unknown_markers"] = source["transcription"].count("[UNK]")
        row["target_terms"] = term_hits(source["transcription"], TARGET_TERMS)
        row["consumer_terms"] = term_hits(source["transcription"], CONSUMER_TERMS)
        match = TIME_PATTERN.search(row["source_audio_filename"])
        row["filename_timing"] = ({"start_seconds": float(match["start"]),
                                   "duration_seconds": float(match["duration"]),
                                   "recording_key": match["recording"],
                                   "session": int(match["session"]), "speaker": int(match["speaker"])}
                                  if match else None)
        row["flags"] = []
        try:
            audio_bytes = source["audio"]["bytes"]
            row["audio_sha256"] = hashlib.sha256(audio_bytes).hexdigest()
            hashes[row["audio_sha256"]].append(row["id"])
            info = sf.info(io.BytesIO(audio_bytes))
            audio, rate = sf.read(io.BytesIO(audio_bytes), dtype="float32", always_2d=True)
            if not len(audio) or not np.isfinite(audio).all():
                raise ValueError("Empty or nonfinite waveform")
            magnitude = np.abs(audio)
            rms = float(np.sqrt(np.mean(audio.astype(np.float64) ** 2)))
            duration = len(audio) / rate
            row["audio_metrics"] = {
                "sample_rate": rate, "channels": audio.shape[1], "frames": len(audio),
                "format": info.format, "subtype": info.subtype, "seconds": duration,
                "peak": float(magnitude.max()), "rms_dbfs": 20 * float(np.log10(max(rms, 1e-12))),
                "near_full_scale_fraction": float(np.mean(magnitude >= 0.999)),
                "zero_fraction": float(np.mean(audio == 0)),
                "duration_delta_seconds": abs(duration - source["duration"]),
            }
            if rate != 16000 or audio.shape[1] != 1:
                row["flags"].append("unexpected_audio_format")
            if row["audio_metrics"]["duration_delta_seconds"] > 0.01:
                row["flags"].append("duration_delta_over_10ms")
            if row["audio_metrics"]["rms_dbfs"] < -50:
                row["flags"].append("low_rms_below_minus50dbfs")
            if row["audio_metrics"]["near_full_scale_fraction"] > 0.001:
                row["flags"].append("over_0.1pct_samples_near_full_scale")
        except Exception as exc:
            row["audio_error"] = type(exc).__name__ + ": " + str(exc)
            row["flags"].append("decode_error")
        rows.append(row)

    selected = {}

    def choose(pool, n, reason):
        pool = list(pool)
        for row in random.Random(SEED + len(selected)).sample(pool, min(n, len(pool))):
            selected.setdefault(row["id"], {"row": row, "reasons": []})["reasons"].append(reason)

    choose((r for r in rows if r["topic"] == "technology" and r["language"] == "mixed"), 5, "technology/mixed")
    choose((r for r in rows if r["topic"] != "technology" and r["language"] == "mixed"), 4, "other/mixed")
    choose((r for r in rows if r["language"] == "zh"), 3, "zh control")
    choose((r for r in rows if r["language"] == "en"), 3, "en control")
    for speaker in sorted({r["original_speaker_id"] for r in rows}):
        choose((r for r in rows if r["original_speaker_id"] == speaker), 1, "speaker coverage")
    choose((r for r in rows if r["unknown_markers"]), 2, "UNK reference")
    valid = [r for r in rows if "audio_metrics" in r]
    for key, reverse, reason in [("seconds", False, "shortest"), ("seconds", True, "longest"),
                                 ("rms_dbfs", False, "lowest RMS"),
                                 ("near_full_scale_fraction", True, "highest near-full-scale fraction")]:
        choose(sorted(valid, key=lambda r: r["audio_metrics"][key], reverse=reverse)[:2], 2, reason)
    for speaker in sorted({r["original_speaker_id"] for r in rows}):
        choose((r for r in rows if r["flags"] and r["original_speaker_id"] == speaker), 2,
               "automatic flag / speaker coverage")
    for sample in selected.values():
        row = sample["row"]
        if "audio_error" not in row:
            suffix = ".wav" if row["audio_metrics"]["format"] == "WAV" else ".flac"
            relative = Path("samples") / (row["id"] + suffix)
            (output / relative).write_bytes(source_rows[row["row_index"]]["audio"]["bytes"])
            sample["audio_path"] = str(relative)
        sample["human_listening_status"] = "pending"
    write_json(output / "listening_manifest.json", list(selected.values()))
    with (output / "rows.jsonl").open("w") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, allow_nan=False) + "\n")

    coverage = {}
    for label, terms, field in [("target", TARGET_TERMS, "target_terms"), ("consumer", CONSUMER_TERMS, "consumer_terms")]:
        coverage[label] = {term: {"occurrences": sum(r[field].get(term, 0) for r in rows),
                                  "utterances": sum(term in r[field] for r in rows)} for term in terms}
    topic_language = Counter((r["topic"], r["language"]) for r in rows)
    summary = {
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "dataset": "CAiRE/ASCEND", "split": "validation", "revision": REVISION,
        "source": SOURCE, "download_via": "https://hf-mirror.com", "license": "CC-BY-SA-4.0",
        "parquet_sha256": digest, "parquet_bytes": args.parquet.stat().st_size,
        "script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), "sample_seed": SEED,
        "rows": len(rows), "unique_ids": len({r["id"] for r in rows}),
        "language_counts": dict(Counter(r["language"] for r in rows)),
        "topic_counts": dict(Counter(r["topic"] for r in rows)),
        "topic_language_counts": {topic: {lang: topic_language[topic, lang] for lang in ["zh", "en", "mixed"]}
                                  for topic in sorted({r["topic"] for r in rows})},
        "speaker_counts": dict(Counter(r["original_speaker_id"] for r in rows)),
        "session_speaker_groups": len({(r["session_id"], r["original_speaker_id"]) for r in rows}),
        "filename_recording_groups": len({r["filename_timing"]["recording_key"] for r in rows if r["filename_timing"]}),
        "blank_references": sum(not r["transcription"].strip() for r in rows),
        "unknown_reference_rows": sum(bool(r["unknown_markers"]) for r in rows),
        "unknown_reference_markers": sum(r["unknown_markers"] for r in rows),
        "clean_reference_rows": sum(not r["unknown_markers"] for r in rows),
        "unknown_reference_by_language": dict(Counter(r["language"] for r in rows if r["unknown_markers"])),
        "audio_decode_successes": len(valid), "audio_decode_errors": len(rows) - len(valid),
        "audio_formats": dict(Counter(f'{r["audio_metrics"]["sample_rate"]}Hz/{r["audio_metrics"]["channels"]}ch/{r["audio_metrics"]["subtype"]}' for r in valid)),
        "decoded_duration_seconds": sum(r["audio_metrics"]["seconds"] for r in valid),
        "duration_distribution_seconds": distribution(r["audio_metrics"]["seconds"] for r in valid),
        "rms_distribution_dbfs": distribution(r["audio_metrics"]["rms_dbfs"] for r in valid),
        "maximum_duration_delta_seconds": max((r["audio_metrics"]["duration_delta_seconds"] for r in valid), default=None),
        "all_zero_rows": sum(r["audio_metrics"]["peak"] == 0 for r in valid),
        "flag_counts": dict(Counter(flag for r in rows for flag in r["flags"])),
        "near_full_scale_flagged_by_speaker": dict(Counter(r["original_speaker_id"] for r in rows
            if "over_0.1pct_samples_near_full_scale" in r["flags"])),
        "duplicate_audio_groups": [ids for ids in hashes.values() if len(ids) > 1],
        "filename_timing_parsed_rows": sum(r["filename_timing"] is not None for r in rows),
        "term_aliases": {"target": TARGET_TERMS, "consumer": CONSUMER_TERMS}, "term_coverage": coverage,
        "target_hit_rows": sum(bool(r["target_terms"]) for r in rows),
        "english_tokens_top50": Counter(token.casefold() for r in rows for token in re.findall(
            r"[A-Za-z]+(?:['’-][A-Za-z]+)*", r["transcription"].replace("[UNK]", " "))).most_common(50),
        "listening_pack_rows": len(selected), "human_listening_completed": 0,
        "asr_inference_performed": False,
    }
    write_json(output / "summary.json", summary)
    cards = []
    for sample in selected.values():
        row = sample["row"]
        audio_path = sample.get("audio_path")
        audio_tag = '<audio controls preload="none" src="' + html.escape(audio_path, quote=True) + '"></audio>' if audio_path else "Decode failed"
        cards.append("<article><h2>" + html.escape(row["id"] + " · " + row["language"] + " · " + row["topic"]) +
                     "</h2><p>" + html.escape(" / ".join(sample["reasons"])) + "</p><p>" +
                     html.escape(row["transcription"]) + "</p>" + audio_tag + "</article>")
    (output / "listen.html").write_text(
        '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>ASCEND validation 抽查</title>'
        '<style>body{max-width:900px;margin:32px auto;padding:0 20px;font:16px/1.6 system-ui}article{border-top:1px solid #ddd;padding:12px 0}h2{font-size:17px}audio{width:100%}</style>'
        '<h1>ASCEND validation 抽查</h1><p>自动筛选样本，尚未完成主观试听；可检查口音、截词、噪声、串音与转写一致性。</p>'
        '<p>Source: <a href="' + SOURCE + '">CAiRE/ASCEND</a> · Lovenia et al., 2022 · '
        '<a href="https://creativecommons.org/licenses/by-sa/4.0/">CC-BY-SA-4.0</a> · revision ' + REVISION +
        '。音频与转写保持原样；本页添加筛选理由。</p>' + "\n".join(cards) + '</html>')
    (output / "README.md").write_text(
        "# ASCEND validation 本地抽查包\n\n"
        f"Source: {SOURCE}\n\nRevision: `{REVISION}`\n\n"
        "Attribution: Holy Lovenia et al., ASCEND: A Spontaneous Chinese-English Dataset for Code-switching in Multi-turn Conversation, LREC 2022. https://arxiv.org/abs/2112.06223\n\n"
        "Audio and transcriptions: CC-BY-SA-4.0, https://creativecommons.org/licenses/by-sa/4.0/ . "
        "Selected source audio bytes and references are unchanged; audit statistics, selection reasons and the HTML index were added.\n\n"
        "Open `listen.html` for playback; all subjective listening annotations are pending. "
        "Signal thresholds are screening heuristics, not VAD, SNR, perceived quality or verified clipping diagnoses. "
        "This pack contains validation data only. No ASR inference was performed.\n")
    print(json.dumps({k: v for k, v in summary.items() if k not in ("term_aliases", "english_tokens_top50")}, ensure_ascii=False, indent=2))
    return 1 if summary["audio_decode_errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
