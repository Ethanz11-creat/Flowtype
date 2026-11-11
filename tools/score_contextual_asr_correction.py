#!/usr/bin/env python3
"""Score complete paired correction runs, including original-text fallbacks.

Aggregate B/U metrics use the pinned official scorer through the existing
wrapper. Per-sentence benefit/harm diagnostics use unit-cost word edit distance
and are explicitly separate from the official weighted alignment.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import shutil
import statistics
import subprocess
import sys

import jiwer

from run_contextual_asr_correction import read_rows, sha
from score_librispeech_biasing import normalize_hypothesis


def validate_completions(inputs, completions):
    ids = [r["id"] for r in inputs]
    expected = {(sid, c) for sid in ids for c in ("plain", "contextual")}
    actual = [(r["id"], r["condition"]) for r in completions]
    if len(set(ids)) != len(ids) or len(set(actual)) != len(actual) or set(actual) != expected:
        raise ValueError("Incomplete, extra or duplicate paired completions")
    originals = {r["id"]: r["asr_text"] for r in inputs}
    for row in completions:
        if row["status"] not in ("ok", "fallback") or not isinstance(row["text"], str):
            raise ValueError("Invalid completion status or text")
        if row["status"] == "fallback" and row["text"] != originals[row["id"]]:
            raise ValueError("Fallback must preserve original ASR")


def edit_count(ref, text):
    result = jiwer.process_words(ref, normalize_hypothesis(text))
    return result.substitutions + result.insertions + result.deletions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--official-scorer", type=Path, required=True)
    args = parser.parse_args()
    protocol = json.loads((args.run / "protocol.json").read_text())
    if sha(args.baseline / "predictions.jsonl") != protocol["baseline_predictions_sha256"]:
        raise ValueError("Baseline identity changed")
    if sha(args.baseline / "references.jsonl") != protocol["candidate_source_sha256"]:
        raise ValueError("Reference/candidate source changed")
    if sha(args.run / "inference-inputs.jsonl") != protocol["inputs_sha256"]:
        raise ValueError("Inference inputs changed")
    inputs = read_rows(args.run / "inference-inputs.jsonl")
    completions = read_rows(args.run / "completions.jsonl")
    validate_completions(inputs, completions)
    baseline = read_rows(args.baseline / "predictions.jsonl")
    baseline_by_id = {r["id"]: r for r in baseline}
    if [r["id"] for r in inputs] != [r["id"] for r in baseline]:
        raise ValueError("Scoring requires the complete baseline pilot")
    if any(r["asr_text"] != p["text"] for r, p in zip(inputs, baseline)):
        raise ValueError("ASR input text changed")
    refs = {r[0]: r[1] for line in (args.baseline / "official-refs.tsv").read_text().splitlines()
            if (r := line.split("\t"))}
    original_errors = {r["id"]: edit_count(refs[r["id"]], r["asr_text"]) for r in inputs}
    baseline_metrics = json.loads((args.baseline / "scored/summary.json").read_text())["metrics"]
    summary = {"rows": len(inputs), "scope": protocol["scope"], "conditions": {},
               "baseline_official_metrics": baseline_metrics,
               "protocol_sha256": sha(args.run / "protocol.json"),
               "completions_sha256": sha(args.run / "completions.jsonl"),
               "analysis_sha256": sha(Path(__file__)),
               "paired_diagnostic_alignment": "unit-cost edit distance, separate from official aggregate B/U alignment"}
    diagnostic_rows = []
    for condition in ("plain", "contextual"):
        rows = [r for r in completions if r["condition"] == condition]
        output = args.run / condition
        output.mkdir(exist_ok=False)
        for name in ("official-refs.tsv", "scoring-protocol.json"):
            shutil.copyfile(args.baseline / name, output / name)
        # Both successful completions and explicit original-text fallbacks count
        # as effective pipeline outputs; API failures remain separately reported.
        (output / "predictions.jsonl").write_text("".join(json.dumps({
            "id": r["id"], "text": r["text"], "status": "ok",
            "latency_seconds": r["latency_seconds"],
            "audio_seconds": baseline_by_id[r["id"]]["audio_seconds"]}) + "\n" for r in rows))
        subprocess.run([sys.executable, str(Path(__file__).with_name("score_librispeech_biasing.py")),
                        "--run", str(output), "--official-scorer", str(args.official_scorer)],
                       check=True, capture_output=True)
        official = json.loads((output / "scored/summary.json").read_text())
        if any(official["metrics"][k]["reference_words"] != baseline_metrics[k]["reference_words"]
               for k in ("WER", "B-WER", "U-WER")):
            raise ValueError("Reference denominators changed between conditions")
        counts = Counter()
        for row in rows:
            sid = row["id"]
            before, after = original_errors[sid], edit_count(refs[sid], row["text"])
            counts["improved" if after < before else "harmed" if after > before else "same_error_count"] += 1
            counts["previously_correct_rows"] += before == 0
            counts["previously_correct_harmed"] += before == 0 and after > 0
            counts["normalized_text_changed"] += normalize_hypothesis(row["text"]) != normalize_hypothesis(next(r["asr_text"] for r in inputs if r["id"] == sid))
            diagnostic_rows.append({"id": sid, "condition": condition, "reference": refs[sid],
                                    "original": next(r["asr_text"] for r in inputs if r["id"] == sid),
                                    "corrected": row["text"], "original_errors": before, "corrected_errors": after})
        latencies = sorted(r["latency_seconds"] for r in rows)
        summary["conditions"][condition] = {
            "official_metrics": official["metrics"], "paired_diagnostics": dict(counts),
            "delta_percentage_points_vs_raw": {
                k: official["metrics"][k]["rate_percent"] - baseline_metrics[k]["rate_percent"]
                for k in ("WER", "B-WER", "U-WER")},
            "fallback_count": sum(r["status"] == "fallback" for r in rows),
            "failure_types": dict(Counter(r.get("failure") for r in rows if r["status"] == "fallback")),
            "latency_median_seconds": statistics.median(latencies),
            "latency_p95_seconds": latencies[max(0, int(len(rows) * .95 + .999999) - 1)],
            "usage": {k: sum(r.get("usage", {}).get(k, 0) for r in rows)
                      for k in ("prompt_tokens", "completion_tokens", "total_tokens")},
            "usage_missing_rows": sum("usage" not in r for r in rows),
            "served_models": dict(Counter(r.get("served_model", "not_reported") for r in rows)),
        }
    (args.run / "paired-diagnostics.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in diagnostic_rows))
    (args.run / "comparison-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
