#!/usr/bin/env python3
"""
ASR Evaluation Script for langstream
Tests TeleSpeech and SenseVoice against a manifest of audio samples.

Usage:
    cd tools && python evaluate_asr.py

Requirements:
    pip install requests python-Levenshtein
"""

import os
import sys
import json
import re
from pathlib import Path
from datetime import datetime
from dataclasses import dataclass, asdict
from typing import Optional

# Try to import python-Levenshtein for fast edit distance
try:
    import Levenshtein
    def edit_distance(a: str, b: str) -> int:
        return Levenshtein.distance(a, b)
except ImportError:
    # Fallback DP implementation
    def edit_distance(a: str, b: str) -> int:
        m, n = len(a), len(b)
        if m == 0:
            return n
        if n == 0:
            return m
        prev = list(range(n + 1))
        curr = [0] * (n + 1)
        for i in range(1, m + 1):
            curr[0] = i
            for j in range(1, n + 1):
                cost = 0 if a[i - 1] == b[j - 1] else 1
                curr[j] = min(curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost)
            prev, curr = curr, prev
        return prev[n]


def cer(hypothesis: str, ground_truth: str) -> float:
    """Character Error Rate"""
    if not ground_truth:
        return 0.0 if not hypothesis else 1.0
    dist = edit_distance(hypothesis, ground_truth)
    return dist / len(ground_truth)


def classify_errors(hypothesis: str, ground_truth: str) -> list[str]:
    """Simple error classification based on heuristics"""
    errors = []
    if len(hypothesis) < len(ground_truth) * 0.8:
        errors.append("截断/漏字")
    if len(hypothesis) > len(ground_truth) * 1.2:
        errors.append("多字")
    # Check for English term errors
    english_terms = ["SwiftUI", "LangGraph", "Docker", "Kubernetes", "RAG", "Agent", "DeepSeek"]
    for term in english_terms:
        if term.lower() in ground_truth.lower() and term.lower() not in hypothesis.lower():
            errors.append("英文术语错误")
            break
    # Check filler retention
    fillers = ["嗯", "啊", "哦", "呃", "那个", "然后"]
    for f in fillers:
        if f in hypothesis and f not in ground_truth:
            errors.append("filler残留")
            break
    if not errors:
        if hypothesis != ground_truth:
            errors.append("错字/同音字")
    return errors


@dataclass
class SampleResult:
    id: str
    ground_truth: str
    tele_text: str
    tele_cer: float
    tele_errors: list
    sense_text: str
    sense_cer: float
    sense_errors: list
    chosen_text: str
    chosen_cer: float


def load_env_key() -> str:
    """Load SILICONFLOW_API_KEY from .env file"""
    env_path = Path(__file__).parent.parent / ".env"
    if not env_path.exists():
        return ""
    with open(env_path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("SILICONFLOW_API_KEY="):
                return line.strip().split("=", 1)[1].strip().strip('"').strip("'")
    return ""


def transcribe(audio_path: str, model: str, api_key: str) -> Optional[str]:
    """Call SiliconFlow ASR API"""
    import requests
    url = "https://api.siliconflow.cn/v1/audio/transcriptions"
    headers = {"Authorization": f"Bearer {api_key}"}

    data = {"model": model, "language": "zh"}
    if "TeleSpeech" in model or "tele" in model.lower():
        data["prompt"] = "请识别标准中文普通话，去除重复字词和语气词，保持语句通顺自然。"

    try:
        with open(audio_path, "rb") as f:
            files = {"file": ("recording.wav", f, "audio/wav")}
            resp = requests.post(url, headers=headers, data=data, files=files, timeout=30)
        resp.raise_for_status()
        return resp.json().get("text", "")
    except Exception as e:
        print(f"  Error transcribing with {model}: {e}")
        return None


def evaluate_sample(sample: dict, api_key: str) -> SampleResult:
    sid = sample["id"]
    audio_path = Path(__file__).parent / "eval_data" / sample["audio"]
    gt = sample["ground_truth"]

    print(f"Evaluating {sid}...")

    tele = transcribe(str(audio_path), "TeleAI/TeleSpeechASR", api_key)
    sense = transcribe(str(audio_path), "FunAudioLLM/SenseVoiceSmall", api_key)

    tele_text = tele or ""
    sense_text = sense or ""

    # Simple selection: lower CER wins
    tele_c = cer(tele_text, gt)
    sense_c = cer(sense_text, gt)

    if tele_c <= sense_c:
        chosen = tele_text
        chosen_c = tele_c
    else:
        chosen = sense_text
        chosen_c = sense_c

    return SampleResult(
        id=sid,
        ground_truth=gt,
        tele_text=tele_text,
        tele_cer=tele_c,
        tele_errors=classify_errors(tele_text, gt),
        sense_text=sense_text,
        sense_cer=sense_c,
        sense_errors=classify_errors(sense_text, gt),
        chosen_text=chosen,
        chosen_cer=chosen_c
    )


def main():
    api_key = load_env_key()
    if not api_key:
        print("ERROR: SILICONFLOW_API_KEY not found in .env")
        sys.exit(1)

    manifest_path = Path(__file__).parent / "eval_data" / "manifest.json"
    if not manifest_path.exists():
        print(f"ERROR: Manifest not found at {manifest_path}")
        print("Run: python eval_data/generate_samples.py  (or create your own manifest)")
        sys.exit(1)

    with open(manifest_path, encoding="utf-8") as f:
        manifest = json.load(f)

    results = []
    for sample in manifest:
        result = evaluate_sample(sample, api_key)
        results.append(result)

    # Save results
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_dir = Path(__file__).parent / "eval_output"
    output_dir.mkdir(exist_ok=True)

    # JSON
    json_path = output_dir / f"results_{timestamp}.json"
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump([asdict(r) for r in results], f, ensure_ascii=False, indent=2)

    # Markdown report
    md_path = output_dir / f"report_{timestamp}.md"
    tele_avg = sum(r.tele_cer for r in results) / len(results)
    sense_avg = sum(r.sense_cer for r in results) / len(results)
    chosen_avg = sum(r.chosen_cer for r in results) / len(results)

    with open(md_path, "w", encoding="utf-8") as f:
        f.write("# ASR Evaluation Report\n\n")
        f.write(f"Date: {datetime.now().isoformat()}\n")
        f.write(f"Samples: {len(results)}\n\n")
        f.write("## Overall CER\n\n")
        f.write(f"- TeleSpeech avg CER: {tele_avg:.3f}\n")
        f.write(f"- SenseVoice avg CER: {sense_avg:.3f}\n")
        f.write(f"- Chosen (best per sample) avg CER: {chosen_avg:.3f}\n\n")

        f.write("## Per-Sample Results\n\n")
        f.write("| ID | Ground Truth | TeleSpeech | Tele CER | Tele Errors | SenseVoice | Sense CER | Sense Errors | Chosen | Chosen CER |\n")
        f.write("|---|---|---|---|---|---|---|---|---|---|\n")
        for r in results:
            f.write(
                f"| {r.id} | {r.ground_truth} | {r.tele_text} | {r.tele_cer:.3f} | {', '.join(r.tele_errors)} | "
                f"{r.sense_text} | {r.sense_cer:.3f} | {', '.join(r.sense_errors)} | {r.chosen_text} | {r.chosen_cer:.3f} |\n"
            )

        f.write("\n## Error Pattern Analysis\n\n")
        error_counts = {}
        for r in results:
            for e in r.tele_errors:
                key = f"TeleSpeech:{e}"
                error_counts[key] = error_counts.get(key, 0) + 1
            for e in r.sense_errors:
                key = f"SenseVoice:{e}"
                error_counts[key] = error_counts.get(key, 0) + 1
        for error, count in sorted(error_counts.items(), key=lambda x: -x[1]):
            f.write(f"- {error}: {count}\n")

    print(f"\n{'='*50}")
    print(f"Results saved to {json_path}")
    print(f"Report saved to {md_path}")
    print(f"\nTeleSpeech avg CER: {tele_avg:.3f}")
    print(f"SenseVoice avg CER: {sense_avg:.3f}")
    print(f"Chosen avg CER:     {chosen_avg:.3f}")
    print(f"{'='*50}")


if __name__ == "__main__":
    main()
