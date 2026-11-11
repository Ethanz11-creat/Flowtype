"""Strict experiment boundaries and immutable run identities."""
from datetime import datetime, timezone
import hashlib
import json
import math
import shutil
from pathlib import Path


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def read_rows(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def write_json(path, data):
    Path(path).write_text(json.dumps(data, ensure_ascii=False, indent=2, allow_nan=False) + '\n')


def write_rows(path, rows):
    Path(path).write_text(''.join(json.dumps(r, ensure_ascii=False, allow_nan=False) + '\n' for r in rows))


def load_audio_inputs(path: Path) -> list[dict]:
    rows = read_rows(path)
    if not rows or any(set(r) != {'id', 'path'} or not all(isinstance(v, str) and v for v in r.values()) for r in rows):
        raise ValueError('Inference inputs must contain only nonempty id/path')
    ids = [r['id'] for r in rows]
    if len(ids) != len(set(ids)):
        raise ValueError('Duplicate input IDs')
    return rows


def validate_predictions(expected_ids: list[str], rows: list[dict]) -> None:
    ids = [r['id'] for r in rows]
    if len(set(expected_ids)) != len(expected_ids) or len(set(ids)) != len(ids) or set(ids) != set(expected_ids):
        raise ValueError('Incomplete, duplicate or extra prediction IDs')
    required = {'id', 'model_id', 'text', 'status', 'error_code', 'latency_seconds', 'audio_seconds'}
    for r in rows:
        if not required <= set(r) or r['status'] not in ('ok', 'error') or not isinstance(r['text'], str):
            raise ValueError('Invalid prediction schema')
        if not all(isinstance(r[k], (int, float)) and math.isfinite(r[k]) and r[k] >= 0 for k in ('latency_seconds', 'audio_seconds')):
            raise ValueError('Invalid timing')
        if r['status'] == 'error' and (r['text'] or not r['error_code']):
            raise ValueError('Errors must have empty text and explicit error code')


def freeze_run(config: dict, inputs: Path, output: Path) -> dict:
    output.mkdir(parents=True, exist_ok=False)
    protocol = {'schema_version': 1, 'created_at_utc': datetime.now(timezone.utc).isoformat(),
                'config': config, 'input_sha256': sha(inputs), 'input_path': str(inputs.resolve()),
                'tool_sha256': {str(p): sha(p) for p in sorted(Path(__file__).parent.rglob('*'))
                                if p.is_file() and p.suffix in ('.py', '.swift', '.json', '.txt', '.in') and '__pycache__' not in p.parts}}
    for source in protocol['tool_sha256']:
        dest = output / 'source-snapshot' / Path(source).relative_to(Path(__file__).parent)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, dest)
    write_json(output / 'protocol.json', protocol)
    return protocol
