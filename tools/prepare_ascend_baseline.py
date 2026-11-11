#!/usr/bin/env python3
"""Export pinned ASCEND validation audio and separate blind inference inputs."""
import argparse
import hashlib
import json
from pathlib import Path

import pyarrow.parquet as pq


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--parquet", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if hashlib.sha256(args.parquet.read_bytes()).hexdigest() != "3bdec53d2abfd3dd4f0d86a6df4e27e60f20660edc9b66055ae0ef8ec05cf7e2":
        raise ValueError("Unexpected ASCEND validation revision")
    rows = pq.read_table(args.parquet).to_pylist()
    assert len(rows) == len({r["id"] for r in rows}) == 1130
    output = args.output.resolve()
    audio = output / "audio"
    audio.mkdir(parents=True, exist_ok=True)
    with (output / "inputs.jsonl").open("w") as inputs, (output / "references.jsonl").open("w") as references:
        for row in rows:
            path = audio / (row["id"] + ".wav")
            path.write_bytes(row["audio"]["bytes"])
            inputs.write(json.dumps({"id": row["id"], "path": str(path)}) + "\n")
            references.write(json.dumps({k: v for k, v in row.items() if k not in ("audio", "path")}, ensure_ascii=False) + "\n")
    print(f"Exported {len(rows)} validation rows; inference inputs contain id/path only")


if __name__ == "__main__":
    main()
