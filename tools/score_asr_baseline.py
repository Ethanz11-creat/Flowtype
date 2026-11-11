"""Fixed mixed-token scoring for ASCEND; raw outputs and unknown refs stay visible."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import statistics
import unicodedata

import jiwer


TOKENIZATION_VERSION = "nfkc-casefold-han-char-latin-word-number-run-v1"


def mixed_tokens(text):
    text = unicodedata.normalize("NFKC", text).casefold().replace("’", "'").replace("‘", "'")
    separated = []
    for char in text:
        name = unicodedata.name(char, "")
        if name.startswith(("CJK UNIFIED IDEOGRAPH-", "CJK COMPATIBILITY IDEOGRAPH-")):
            separated.extend((" ", char, " "))
        else:
            separated.append(char)
    return re.findall(r"[^\W\d_]+(?:'[^\W\d_]+)*|\d+", "".join(separated))


def aggregate(rows):
    result = {"rows": len(rows)}
    for key in ["reference_units", "hits", "substitutions", "deletions", "insertions"]:
        result[key] = sum(r[key] for r in rows)
    result["edit_errors"] = sum(result[k] for k in ["substitutions", "deletions", "insertions"])
    result["mer"] = result["edit_errors"] / result["reference_units"] if result["reference_units"] else None
    return result


def evaluate(references, predictions):
    reference_ids = [r["id"] for r in references]
    prediction_ids = [p["id"] for p in predictions]
    if len(set(reference_ids)) != len(reference_ids) or len(set(prediction_ids)) != len(prediction_ids):
        raise ValueError("Duplicate reference/prediction IDs")
    if set(reference_ids) != set(prediction_ids):
        raise ValueError("Incomplete or extra prediction IDs; score only complete runs")
    by_id = {p["id"]: p for p in predictions}
    results = []
    for ref in references:
        pred = by_id[ref["id"]]
        if pred["status"] not in ("ok", "error"):
            raise ValueError("Unrecognized prediction status")
        hypothesis = pred["text"] if pred["status"] == "ok" else ""
        row = {**ref, "hypothesis": hypothesis, "prediction_status": pred["status"],
               "latency_seconds": pred["latency_seconds"], "mer": None,
               "unknown_reference": bool(re.search(r"\[unk\]", ref["transcription"], re.I))}
        if not row["unknown_reference"]:
            reference_tokens, hypothesis_tokens = mixed_tokens(ref["transcription"]), mixed_tokens(hypothesis)
            if not reference_tokens:
                raise ValueError("Empty normalized reference; declare a scoring policy before proceeding")
            alignment = jiwer.process_words(" ".join(reference_tokens), " ".join(hypothesis_tokens))
            row.update({key: getattr(alignment, key) for key in ["hits", "substitutions", "deletions", "insertions"]})
            row.update(reference_units=len(reference_tokens), reference_tokens=reference_tokens,
                       hypothesis_tokens=hypothesis_tokens, mer=alignment.wer)
        results.append(row)
    clean = [r for r in results if not r["unknown_reference"]]
    summary = {
        "tokenization_version": TOKENIZATION_VERSION, "rows": len(references),
        "unknown_reference_rows": len(results) - len(clean),
        "failure_count": sum(p["status"] == "error" for p in predictions),
        "empty_output_count": sum(not mixed_tokens(p["text"]) for p in predictions if p["status"] == "ok"),
        "clean": aggregate(clean),
    }
    for field in ["language", "topic", "original_speaker_id"]:
        summary["by_" + field] = {str(value): aggregate([r for r in clean if r[field] == value])
                                    for value in sorted({r[field] for r in clean})}
    timings = sorted(p["latency_seconds"] for p in predictions)
    seconds = sum(p.get("audio_seconds") or 0 for p in predictions)
    summary["latency"] = {"total_seconds": sum(timings), "median_seconds": statistics.median(timings) if timings else None,
                          "p95_seconds": timings[max(0, int(len(timings) * .95 + .999999) - 1)] if timings else None,
                          "decoded_audio_seconds": seconds, "aggregate_rtf": sum(timings) / seconds if seconds else None,
                          "first_sample_seconds": predictions[0]["latency_seconds"] if predictions else None}
    return summary, results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--references", type=Path, required=True)
    parser.add_argument("--predictions", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    read = lambda p: [json.loads(line) for line in p.read_text().splitlines() if line.strip()]
    summary, rows = evaluate(read(args.references), read(args.predictions))
    summary["references_sha256"] = hashlib.sha256(args.references.read_bytes()).hexdigest()
    summary["predictions_sha256"] = hashlib.sha256(args.predictions.read_bytes()).hexdigest()
    summary["scorer_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    with (args.output / "scored_rows.jsonl").open("w") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    lines = ["# ASCEND raw ASR baseline", "", f"Attempted: {summary['rows']}; unknown-reference diagnostics: {summary['unknown_reference_rows']}; failed requests: {summary['failure_count']}; empty successful outputs: {summary['empty_output_count']}.", "",
             "Custom clean-reference subset; not the official full validation scoring protocol.", "",
             "| Group | Rows | Reference units | Edits | MER |", "| --- | ---: | ---: | ---: | ---: |"]
    for name, stats in [("all clean", summary["clean"]), *summary["by_language"].items()]:
        rate = f"{100 * stats['mer']:.2f}%" if stats["mer"] is not None else "n/a"
        lines.append(f"| {name} | {stats['rows']} | {stats['reference_units']} | {stats['edit_errors']} | {rate} |")
    lines += ["", "Mixed units: one Han character, one alphabetic word (internal apostrophe retained), or one digit run. NFKC + casefold; punctuation separates units; no number spelling conversion or filler removal.", "",
              "All unknown-reference rows retain predictions but have no MER. Failed requests remain as empty hypotheses, contributing deletions. Latency includes WAV I/O and first-use compilation, excludes model loading; dependency build is debug.", ""]
    (args.output / "report.md").write_text("\n".join(lines))
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
