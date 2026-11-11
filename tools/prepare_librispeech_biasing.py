#!/usr/bin/env python3
"""Select a deterministic speaker-balanced pilot without reading ASR outputs.

Input is an extracted official test-clean tree and the verified 100-word biasing
reference. The pilot is a custom subset, not a full official benchmark result.
"""
import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path

import soundfile as sf


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--biasing-refs", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    data = args.biasing_refs.read_bytes()
    assert hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest() == "3b65fb715bd42f3bf6c927aabe5a3ad1861031b5"
    rows = [line.split("\t") for line in data.decode().splitlines()]
    assert len(rows) == 2620 and all(len(r) == 4 for r in rows)
    original = {}
    for path in args.corpus.rglob("*.trans.txt"):
        for line in path.read_text().splitlines():
            sid, text = line.split(" ", 1)
            assert sid not in original
            original[sid] = text.lower()
    assert set(original) == {r[0] for r in rows}
    assert all(original[r[0]] == r[1] for r in rows)
    speakers = defaultdict(list)
    for row in rows:
        speakers[row[0].split("-")[0]].append(row)
    assert len(speakers) == 40
    rank = lambda r: hashlib.sha256(("20261111:" + r[0]).encode()).hexdigest()
    selected = sorted((r for speaker in sorted(speakers) for r in sorted(speakers[speaker], key=rank)[:5]), key=lambda r: r[0])
    assert len(selected) == 200
    output = args.output.resolve()
    audio = output / "audio"
    audio.mkdir(parents=True, exist_ok=True)
    seconds = 0
    with (output / "inputs.jsonl").open("w") as inputs, (output / "references.jsonl").open("w") as references:
        for row in selected:
            sid, text, rare_words, bias_list = row
            speaker, chapter, _ = sid.split("-")
            source = args.corpus / speaker / chapter / (sid + ".flac")
            waveform, rate = sf.read(source, dtype="int16")
            assert rate == 16000 and waveform.ndim == 1 and len(waveform)
            path = audio / (sid + ".wav")
            sf.write(path, waveform, rate, subtype="PCM_16")
            seconds += len(waveform) / rate
            inputs.write(json.dumps({"id": sid, "path": str(path)}) + "\n")
            references.write(json.dumps({"id": sid, "transcription": text, "language": "en", "topic": "audiobook",
                                         "original_speaker_id": int(speaker), "rare_words": json.loads(rare_words),
                                         "biasing_words": json.loads(bias_list)}) + "\n")
    (output / "official-refs.tsv").write_text("\n".join("\t".join(r) for r in selected) + "\n")
    metadata = {"dataset": "LibriSpeech test-clean + fbai-speech/is21_deep_bias", "scope": "custom 200-row pilot, not official full test-clean",
                "selection": "smallest SHA256('20261111:' + utterance_id), 5 per speaker; independent of predictions and rare-word annotations",
                "rows": len(selected), "speakers": len(speakers), "audio_seconds": seconds,
                "full_reference_rows": len(rows), "source_biasing_blob_sha1": "3b65fb715bd42f3bf6c927aabe5a3ad1861031b5",
                "source_biasing_sha256": hashlib.sha256(data).hexdigest(),
                "selected_reference_sha256": hashlib.sha256((output / "official-refs.tsv").read_bytes()).hexdigest(),
                "license": {"LibriSpeech_audio": "CC-BY-4.0", "fbai_speech_software": "MIT"},
                "asr_context": None, "notes": "Biasing lists kept in reference metadata only. No hints fed to baseline ASR."}
    (output / "selection.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps(metadata, indent=2))


if __name__ == "__main__":
    main()
