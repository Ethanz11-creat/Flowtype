"""Freeze existing public audio inputs separately from scoring references."""
import hashlib
from pathlib import Path
import re
import shutil

from .schema import read_rows, write_json, write_rows, sha, load_audio_inputs


def inference_rows(rows):
    return [{'id': r['id'], 'path': r['path']} for r in rows]


def canonical_vocabulary(mapping):
    if not isinstance(mapping, dict) or any(not isinstance(v, str) or not v for v in mapping.values()):
        raise ValueError('Expected canonical string values')
    return sorted(set(mapping.values()))[:100]


def select_vad(references):
    result = []
    clean = [r for r in references if not re.search(r'\[unk\]', r['transcription'], re.I)]
    for language in ('zh', 'en', 'mixed'):
        rows = sorted((r for r in clean if r['language'] == language),
                      key=lambda r: hashlib.sha256(('iflytek-vad-v1:' + r['id']).encode()).hexdigest())[:12]
        if len(rows) != 12:
            raise ValueError('Insufficient sources for balanced VAD selection')
        result.extend({'id': r['id'], 'language': language, 'split': 'dev' if i < 4 else 'eval'} for i, r in enumerate(rows))
    return result


def prepare(root: Path, source_root: Path) -> Path:
    import json
    target = root / 'prepared'
    if target.exists():
        raise FileExistsError('Prepared inputs already frozen')
    target.mkdir(parents=True)
    # Freeze app vocabulary independently before loading reference text.
    dictionary = Path(__file__).resolve().parents[2] / 'Sources/FlowType/Resources/tech_terms.json'
    vocabulary = canonical_vocabulary(json.loads(dictionary.read_text()))
    write_json(target / 'technical-vocabulary.json', {'words': vocabulary, 'source_sha256': sha(dictionary)})
    datasets = {}
    for name, origin in [('ascend', source_root / 'ascend'), ('librispeech', source_root / 'librispeech/pilot200')]:
        dest = target / name; dest.mkdir()
        inputs = load_audio_inputs(origin / 'inputs.jsonl')
        references = read_rows(origin / 'references.jsonl')
        if set(r['id'] for r in inputs) != set(r['id'] for r in references) or len(references) != len(inputs):
            raise ValueError('Reference IDs do not match audio inputs')
        audio = []
        import soundfile as sf
        for row in inputs:
            path = Path(row['path']); info = sf.info(path)
            if info.samplerate != 16000 or info.channels != 1:
                raise ValueError('Expected original 16kHz mono audio')
            audio.append({'id': row['id'], 'sha256': sha(path), 'audio_seconds': info.frames / info.samplerate,
                          'frames': info.frames})
        write_rows(dest / 'inputs.jsonl', inference_rows(inputs))
        shutil.copyfile(origin / 'references.jsonl', dest / 'references.jsonl')
        shutil.copyfile(origin / 'predictions.jsonl', dest / 'baseline-predictions.jsonl')
        write_rows(dest / 'audio-manifest.jsonl', audio)
        if name == 'librispeech':
            for f in ('official-refs.tsv', 'scoring-protocol.json'):
                shutil.copyfile(origin / f, dest / f)
        clean = [r for r in references if not re.search(r'\[unk\]', r['transcription'], re.I)]
        datasets[name] = {'rows': len(inputs), 'clean_rows': len(clean),
                          'mixed_clean_rows': sum(r['language'] == 'mixed' for r in clean),
                          'input_sha256': sha(dest / 'inputs.jsonl'), 'reference_sha256': sha(dest / 'references.jsonl'),
                          'baseline_sha256': sha(dest / 'baseline-predictions.jsonl'),
                          'audio_manifest_sha256': sha(dest / 'audio-manifest.jsonl')}
        if name == 'ascend':
            if (len(inputs), len(clean), datasets[name]['mixed_clean_rows']) != (1130, 1067, 191):
                raise ValueError('Unexpected ASCEND revision/scope')
            mixed = {r['id'] for r in clean if r['language'] == 'mixed'}
            write_rows(dest / 'mixed-inputs.jsonl', [r for r in inputs if r['id'] in mixed])
            write_rows(dest / 'mixed-references.jsonl', [r for r in references if r['id'] in mixed])
            write_rows(dest / 'mixed-baseline.jsonl', [r for r in read_rows(origin / 'predictions.jsonl') if r['id'] in mixed])
            write_json(target / 'vad-selection.json', select_vad(references))
        elif len(inputs) != 200:
            raise ValueError('Unexpected LibriSpeech pilot scope')
    manifest = {'datasets': datasets, 'technical_vocabulary_sha256': sha(target / 'technical-vocabulary.json'),
                'vad_selection_sha256': sha(target / 'vad-selection.json'), 'source_root': str(source_root.resolve())}
    write_json(target / 'manifest.json', manifest)
    return target / 'manifest.json'
