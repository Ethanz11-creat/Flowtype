"""Post-inference scoring: references never enter backend requests."""
import json
from pathlib import Path
from tools.score_asr_baseline import evaluate
from .schema import read_rows, sha, validate_predictions, write_json, write_rows


def score_model_run(run_dir: Path, references: Path):
    refs=read_rows(references); predictions=read_rows(run_dir/'predictions.jsonl')
    validate_predictions([r['id'] for r in refs], predictions)
    protocol=json.loads((run_dir/'protocol.json').read_text())
    deployment=protocol['config']['deployment']
    if not {'engine','dtype','quantization','device','build_mode'} <= deployment.keys():
        raise ValueError('Missing deployment identity')
    summary,rows=evaluate(refs,predictions)
    summary.update(deployment=deployment, model_id=protocol['config']['model_id'],
                   reference_sha256=sha(references), prediction_sha256=sha(run_dir/'predictions.jsonl'),
                   scorer_sha256=sha(Path('tools/score_asr_baseline.py')),
                   timing=json.loads((run_dir/'timing.json').read_text()),
                   resource=json.loads((run_dir/'resource.json').read_text()))
    write_json(run_dir/'summary.json',summary);write_rows(run_dir/'scored_rows.jsonl',rows)
    return summary


def render_model_comparison(runs, output):
    summaries=[json.loads((p/'summary.json').read_text()) for p in runs]
    lines=['# ASCEND deployment comparison','',
           'Custom clean-reference subset, not official full validation. Failures retain empty hypotheses. MLX and PyTorch deployment combinations differ; this is not an architecture-only speed comparison.', '',
           '| Model | engine / dtype / quantization / device / build | Clean edits/units (MER) | mixed edits/units (MER) | failures | ASR RTF | load / warmup / batch (s) | RSS bytes |',
           '|---|---|---|---|---:|---:|---|---:|']
    builds=set()
    for s in summaries:
        d=s['deployment'];builds.add(tuple(d.values()))
        group=lambda g:f"{g['edit_errors']}/{g['reference_units']} ({g['mer']:.2%})"
        t=s['timing'];rss=s['resource']['maximum_resident_set_size_bytes']
        lines.append(f"| {s['model_id']} | {' / '.join(d.values())} | {group(s['clean'])} | {group(s['by_language'].get('mixed',s['clean']))} | {s['failure_count']} | {s['latency']['aggregate_rtf']:.3f} | {t['load_seconds']:.2f} / {t['warmup_seconds']:.2f} / {t['batch_wall_seconds']:.2f} | {rss} |")
    lines += ['', '**Different performance protocols/backends/build modes** are shown above; RSS is macOS process memory, not complete GPU allocation. Warmup is separate; all scoring rows are rerun. Desktop/client load is uncontrolled. Historical baseline is separate.', '']
    examples=[]
    for p in runs:
        errors=sorted((r for r in read_rows(p/'scored_rows.jsonl') if r.get('mer')),key=lambda r:r['id'])[:3]
        examples.extend(dict(model=p.name,id=r['id'],reference=r['transcription'],hypothesis=r['hypothesis'],mer=r['mer']) for r in errors)
    if runs:
        maps=[{r['id']:r for r in read_rows(p/'predictions.jsonl')} for p in runs]
        different=sorted(i for i in maps[0] if len({m[i]['text'] for m in maps})>1)
        if different: examples.append(dict(id=different[0],model_outputs={p.name:m[different[0]]['text'] for p,m in zip(runs,maps)}))
    write_json(output.with_suffix('.examples.json'),examples)
    lines += ['Examples: first three nonzero-error rows by ID per model, plus first cross-model disagreement; illustrative, not a random distribution.', '']
    output.write_text('\n'.join(lines))
