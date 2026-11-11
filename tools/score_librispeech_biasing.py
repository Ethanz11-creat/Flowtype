#!/usr/bin/env python3
"""Validate complete pilot predictions and invoke the pinned upstream scorer.

The upstream scorer must be downloaded separately; its original MIT notice stays
with that file. Corpus and software licensing are documented in the evidence.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import statistics
import subprocess
import sys
import unicodedata


def normalize_hypothesis(text):
    text = unicodedata.normalize("NFKC", text).casefold().replace("’", "'").replace("‘", "'")
    # Preserve all alphabets (including wrong-language outputs), not just English.
    return " ".join("".join(c if c.isalnum() or c.isspace() or c == "'" else " " for c in text).split())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--official-scorer", type=Path, required=True)
    args = parser.parse_args()
    protocol = json.loads((args.run / "scoring-protocol.json").read_text())
    source_hash = hashlib.sha256(args.official_scorer.read_bytes()).hexdigest()
    if source_hash != protocol["scorer_sha256"]:
        raise ValueError("Official scorer changed since protocol was frozen")
    refs = [line.split("\t") for line in (args.run / "official-refs.tsv").read_text().splitlines()]
    predictions = [json.loads(line) for line in (args.run / "predictions.jsonl").read_text().splitlines()]
    ids = [p["id"] for p in predictions]
    if len(set(ids)) != len(ids) or set(ids) != {r[0] for r in refs} or len(refs) != len(predictions):
        raise ValueError("Incomplete/duplicate/extra prediction IDs")
    if any(p["status"] not in ("ok", "error") for p in predictions):
        raise ValueError("Unexpected prediction status")
    output = args.run / "scored"
    output.mkdir(exist_ok=True)
    hyps = output / "official-hypotheses.tsv"
    hyps.write_text("".join(p["id"] + "\t" + normalize_hypothesis(p["text"] if p["status"] == "ok" else "") + "\n" for p in predictions))
    command = [sys.executable, str(args.official_scorer), "--refs", str(args.run / "official-refs.tsv"), "--hyps", str(hyps)]
    completed = subprocess.run(command, capture_output=True, text=True, check=True)
    (output / "official-score.txt").write_text(completed.stdout + completed.stderr)
    metrics = {}
    for line in completed.stdout.splitlines():
        match = re.fullmatch(r"(WER|U-WER|B-WER): error_rate=([0-9.eE+-]+), ref_words=(\d+), subs=(\d+), ins=(\d+), dels=(\d+)", line)
        if match:
            name, rate, units, subs, ins, dels = match.groups()
            metrics[name] = {"rate_percent": float(rate), "reference_words": int(units),
                             "substitutions": int(subs), "insertions": int(ins), "deletions": int(dels)}
    if set(metrics) != {"WER", "B-WER", "U-WER"}:
        raise ValueError("Unexpected official scorer output")
    if metrics["WER"]["reference_words"] != sum(metrics[k]["reference_words"] for k in ["B-WER", "U-WER"]):
        raise ValueError("Reference partitions do not sum")
    latencies = sorted(p["latency_seconds"] for p in predictions)
    audio_seconds = sum(p.get("audio_seconds") or 0 for p in predictions)
    summary = {"scope": "200-row speaker-balanced custom pilot, not official full test-clean", "rows": len(predictions),
               "speakers": len(Counter(p["id"].split("-")[0] for p in predictions)),
               "failure_count": sum(p["status"] == "error" for p in predictions),
               "empty_output_count": sum(not normalize_hypothesis(p["text"]) for p in predictions if p["status"] == "ok"),
               "metrics": metrics, "audio_seconds": audio_seconds, "inference_seconds": sum(latencies),
               "latency_median_seconds": statistics.median(latencies),
               "latency_p95_seconds": latencies[max(0, int(len(latencies) * .95 + .999999) - 1)],
               "aggregate_rtf": sum(latencies) / audio_seconds,
               "official_scorer_sha256": source_hash,
               "wrapper_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
               "predictions_sha256": hashlib.sha256((args.run / "predictions.jsonl").read_bytes()).hexdigest(),
               "reference_sha256": hashlib.sha256((args.run / "official-refs.tsv").read_bytes()).hexdigest()}
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
