"""Serial model admission/batches, each in a fresh Python process."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import sys
import time
import wave
from .backends import NativeWorker, WhisperBackend, effective_prediction
from .schema import freeze_run, load_audio_inputs, read_rows, sha, validate_predictions, write_json, write_rows


def backend(root, model_id, log=None):
    manifest = json.loads((root / 'models/assets.json').read_text())
    path = Path(manifest['paths'][model_id])
    if model_id == 'whisper-base':
        worker = WhisperBackend(path)
        return worker, {'event':'ready', 'model_id':model_id, 'load_seconds':worker.load_seconds}
    binary = (root / 'bin/native-asr-bench').resolve()
    command = ['/usr/bin/time', '-l', str(binary), str(path), model_id]
    worker = NativeWorker(path, model_id, binary, command=command, stderr=log)
    return worker, worker.start()


def run_single(root, model_id, output):
    rows = load_audio_inputs(output / 'inputs.jsonl')
    options = json.loads((Path(__file__).parent / 'configs/models.json').read_text())
    with (output / 'native.stderr').open('w') as log:
        worker, ready = backend(root, model_id, log)
        write_json(output / 'ready.json', ready)
        try:
            warmup_start = time.monotonic()
            for r in rows[:options['warmup_rows']]:
                result = worker.transcribe(r['id'], Path(r['path']))
                if result.get('status') != 'ok': raise RuntimeError('Warmup inference failed')
            warmup_seconds = time.monotonic() - warmup_start
            start = time.monotonic()
            predictions = []
            with (output / 'predictions.jsonl').open('w') as handle:
                for r in rows:
                    with wave.open(r['path']) as wav: duration = wav.getnframes() / wav.getframerate()
                    begin = time.monotonic()
                    try:
                        raw = worker.transcribe(r['id'], Path(r['path']))
                        result = effective_prediction(r['id'], model_id, duration, time.monotonic() - begin,
                                     text=raw.get('text', ''), error=None if raw.get('status') == 'ok' else RuntimeError(raw.get('error_code', 'inference_error')))
                    except Exception as exc:
                        result = effective_prediction(r['id'], model_id, duration, time.monotonic()-begin, error=exc)
                    predictions.append(result)
                    handle.write(json.dumps(result, ensure_ascii=False) + '\n'); handle.flush()
                    print(f'{model_id} {len(predictions)}/{len(rows)} {result["status"]}', flush=True)
            validate_predictions([r['id'] for r in rows], predictions)
            write_json(output / 'timing.json', dict(load_seconds=ready['load_seconds'], warmup_seconds=warmup_seconds,
                        batch_wall_seconds=time.monotonic()-start, warmup_rows=min(3,len(rows)), scoring_rows=len(rows),
                        audio_seconds=sum(r['audio_seconds'] for r in predictions)))
        finally:
            worker.close()


def run_models(root: Path, model_ids=None, admission_only=False):
    from .assets import assets
    assets(root)  # verify all local weights before any model starts
    model_ids = model_ids or ['qwen-1.7b', 'qwen-0.6b', 'whisper-base']
    if len(set(model_ids)) != len(model_ids) or set(model_ids) - {'qwen-1.7b','qwen-0.6b','whisper-base'}:
        raise ValueError('Invalid/duplicate model IDs')
    run_id = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    output = root / 'model-runs' / run_id; output.mkdir(parents=True)
    rows = load_audio_inputs(root / 'prepared/ascend/inputs.jsonl')
    if admission_only: rows = sorted(rows, key=lambda r:r['id'])[:10]
    write_rows(output / 'inputs.jsonl', rows)
    config = json.loads((Path(__file__).parent / 'configs/models.json').read_text())
    manifest = json.loads((root / 'models/assets.json').read_text())
    write_json(output / 'run.json', dict(admission_only=admission_only, model_ids=model_ids,
                background_load='Existing desktop/client processes left running; no process terminated. Uncontrolled desktop load.'))
    for model_id in model_ids:
        target = output / model_id
        engine = dict(engine='PyTorch/openai-whisper' if model_id == 'whisper-base' else 'Swift/MLX/speech-swift 0.0.15',
                      dtype='FP32' if model_id == 'whisper-base' else 'mixed BF16/4bit affine group64',
                      quantization='none' if model_id == 'whisper-base' else '4bit',
                      device='CPU 4 threads' if model_id == 'whisper-base' else 'Apple Metal',
                      build_mode='Python package' if model_id == 'whisper-base' else 'SPM debug dependency objects')
        freeze_run(dict(model_id=model_id, admission_only=admission_only, parameters=config, deployment=engine,
                        assets_manifest_sha256=sha(root/'models/assets.json'), assets=manifest,
                        binary_sha256=sha(root/'bin/native-asr-bench')), output/'inputs.jsonl', target)
        write_rows(target/'inputs.jsonl', rows)
        with (target/'progress.log').open('w') as progress, (target/'process.time').open('w') as timing:
            command = ['/usr/bin/time','-l',sys.executable,'-m','tools.interview_bench.models',
                       '--root',str(root.resolve()),'--single',model_id,'--output',str(target.resolve())]
            result = subprocess.run(command, stdout=progress, stderr=timing, timeout=10800)
        if result.returncode:
            write_json(target/'failure.json', {'error':'model_process_failed','returncode':result.returncode})
            raise RuntimeError(f'Model process failed: {model_id}; inspect {target}')
        text = (target/'native.stderr').read_text() if model_id != 'whisper-base' else (target/'process.time').read_text()
        matches = re.findall(r'(\d+)\s+maximum resident set size', text)
        write_json(target/'resource.json', dict(maximum_resident_set_size_bytes=int(matches[-1]) if matches else None,
            scope='Native worker process' if model_id != 'whisper-base' else 'Python model process',
            limitation='macOS process RSS, not complete Metal GPU allocation; desktop load uncontrolled'))
    return output


if __name__ == '__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--single',required=True); parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args(); run_single(args.root,args.single,args.output)
