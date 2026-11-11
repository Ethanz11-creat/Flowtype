"""Evidence matrix verification. Missing work is never converted into a pass."""
import json
from pathlib import Path
from .schema import load_audio_inputs, read_rows, sha, validate_predictions


def check(status, **kwargs):return dict(status=status,**kwargs)

def verify_prepared(root):
    try:
        p=root/'prepared';manifest=json.loads((p/'manifest.json').read_text())
        for dataset,counts in [('ascend',(1130,1067)),('librispeech',(200,200))]:
            m=manifest['datasets'][dataset];directory=p/dataset
            if (m['rows'],m['clean_rows'])!=counts:raise ValueError('dataset counts')
            for file,key in [('inputs.jsonl','input_sha256'),('references.jsonl','reference_sha256'),('baseline-predictions.jsonl','baseline_sha256'),('audio-manifest.jsonl','audio_manifest_sha256')]:
                if sha(directory/file)!=m[key]:raise ValueError('prepared hash')
            inputs=load_audio_inputs(directory/'inputs.jsonl');audio=read_rows(directory/'audio-manifest.jsonl')
            if len(audio)!=counts[0] or {r['id'] for r in audio}!={r['id'] for r in inputs}:raise ValueError('audio identities')
            audio_by={r['id']:r for r in audio}
            if any(sha(Path(r['path']))!=audio_by[r['id']]['sha256'] for r in inputs):raise ValueError('audio changed')
        for file,key in [('technical-vocabulary.json','technical_vocabulary_sha256'),('vad-selection.json','vad_selection_sha256')]:
            if sha(p/file)!=manifest[key]:raise ValueError('prepared auxiliary hash')
        return check('passed')
    except FileNotFoundError:
        return check('not_run' if not (root/'prepared/manifest.json').exists() else 'failed',reason='missing prepared artifact')
    except (ValueError,KeyError,TypeError):return check('failed',reason='prepared identity/count validation')


def validate_frozen_sources(run):
    protocol=json.loads((run/'protocol.json').read_text())
    for source,digest in protocol['tool_sha256'].items():
        marker='/tools/interview_bench/'
        if marker not in source:raise ValueError('Unknown frozen source layout')
        relative=Path(source.split(marker,1)[1])
        if relative.is_absolute() or '..' in relative.parts:raise ValueError('Invalid source path')
        if sha(run/'source-snapshot'/relative)!=digest:raise ValueError('Frozen source checksum mismatch')


def verify_assets(root):
    manifest=root/'models/assets.json'
    if not manifest.exists():return check('not_run')
    try:
        assets=json.loads(manifest.read_text())
        for r in assets['files']:
            if sha(Path(r['path']))!=r['sha256']:raise ValueError('asset changed')
        for name,digest in assets['existing_17_files'].items():
            if sha(Path(assets['paths']['qwen-1.7b'])/name)!=digest:raise ValueError('existing model changed')
        return check('passed')
    except (ValueError,KeyError,FileNotFoundError):return check('failed',reason='missing/changed local weight or model asset')


def model_runs(root):
    runs={}
    for p in sorted((root/'model-runs').glob('*/run.json')):
        metadata=json.loads(p.read_text())
        if metadata['admission_only']:continue
        for model_id in metadata['model_ids']:
            directory=p.parent/model_id
            if (directory/'protocol.json').exists():runs[model_id]=directory
    return runs


def latest(root,folder):
    paths=sorted((root/folder).glob('*/summary.json'))
    return paths[-1].parent if paths else None


def validate_correction_matrix(tasks, rows):
    from collections import Counter
    expected={('librispeech',c):200 for c in ['plain','contextual','mismatched']}
    expected.update({('ascend',c):191 for c in ['plain','static_tech']})
    identity=lambda r:(r['dataset'],r['id'],r['condition'])
    if Counter((t['dataset'],t['condition']) for t in tasks)!=expected:
        raise ValueError('Wrong fixed correction matrix')
    keys=[identity(t) for t in tasks];actual=[identity(r) for r in rows]
    if len(set(keys))!=982 or len(set(actual))!=982 or len(actual)!=982 or set(keys)!=set(actual):
        raise ValueError('Incomplete/extra/duplicate corrections')
    for dataset in ['librispeech','ascend']:
        groups=[{t['id'] for t in tasks if t['dataset']==d and t['condition']==c} for d,c in expected if d==dataset]
        if any(g!=groups[0] for g in groups):raise ValueError('Condition IDs differ')


def verify(root,profile='full'):
    if profile not in ['full','compact']:raise ValueError('Unknown profile')
    checks={'prepared':verify_prepared(root),'assets':verify_assets(root)};runs=model_runs(root)
    expected_ids=[r['id'] for r in read_rows(root/'prepared/ascend/inputs.jsonl')] if (root/'prepared/ascend/inputs.jsonl').exists() else []
    for model_id in ['qwen-1.7b','qwen-0.6b','whisper-base']:
        p=runs.get(model_id)
        if not p:checks['model-'+model_id]=check('not_run');continue
        try:
            validate_frozen_sources(p)
            predictions=read_rows(p/'predictions.jsonl');validate_predictions(expected_ids,predictions)
            protocol=json.loads((p/'protocol.json').read_text());config=protocol['config']
            if len(predictions)!=1130 or config['model_id']!=model_id or config['admission_only'] or protocol['input_sha256']!=sha(root/'prepared/ascend/inputs.jsonl'):raise ValueError('model identity')
            if config['binary_sha256']!=sha(root/'bin/native-asr-bench'):raise ValueError('worker binary changed')
            identity=json.loads((root/'bin/identity.json').read_text())
            if identity['metal_sha256']!=sha(root/'bin/mlx.metallib'):raise ValueError('Metal resource changed')
            if config['assets_manifest_sha256']!=sha(root/'models/assets.json'):raise ValueError('asset manifest changed')
            if config['parameters']!=json.loads((Path(__file__).parent/'configs/models.json').read_text()):raise ValueError('decoding parameters changed')
            if any(r['model_id']!=model_id for r in predictions):raise ValueError('prediction model identity')
            if not {'engine','dtype','quantization','device','build_mode'}<=config['deployment'].keys():raise ValueError('missing deployment')
            timing=json.loads((p/'timing.json').read_text())
            if timing['warmup_rows']!=3 or timing['scoring_rows']!=1130:raise ValueError('warmup/scoring scope')
            for file in ['resource.json','summary.json']:
                if not (p/file).is_file():raise ValueError('missing model summary')
            summary=json.loads((p/'summary.json').read_text())
            if summary['prediction_sha256']!=sha(p/'predictions.jsonl') or summary['reference_sha256']!=sha(root/'prepared/ascend/references.jsonl'):raise ValueError('Scoring hash changed')
            if summary['clean']['rows']!=1067 or summary['unknown_reference_rows']!=63 or summary['by_language']['mixed']['rows']!=191:raise ValueError('scoring partitions')
            checks['model-'+model_id]=check('passed',run=str(p),failures=sum(r['status']=='error' for r in predictions))
        except (ValueError,KeyError,FileNotFoundError,TypeError):checks['model-'+model_id]=check('failed',reason='identity/integrity/incomplete model run',run=str(p))
    replay_by_split={}
    for p in sorted((root/'replay-runs').glob('*/summary.json')):
        try:
            config=json.loads((p.parent/'protocol.json').read_text())['config'];replay_by_split[config['split']]=p.parent
        except (KeyError,FileNotFoundError,ValueError):continue
    for split,count,strategies in [('dev',3,['whole','fixed5','vad300','vad600','vad900']),('eval',6,['whole','fixed5','vad600'])]:
        p=replay_by_split.get(split)
        if not p:checks['replay-'+split]=check('not_run');continue
        try:
            s=json.loads((p/'summary.json').read_text())
            validate_frozen_sources(p)
            protocol=json.loads((p/'protocol.json').read_text())
            if sha(p/'annotations.json')!=protocol['config']['annotations_sha256']:raise ValueError('annotation snapshot changed')
            if sha(root/'replay-prepared/sessions.json')!=protocol['input_sha256']:raise ValueError('session input changed')
            for session in json.loads((p/'sessions.json').read_text()):
                if sha(Path(session['path']))!=session['sha256']:raise ValueError('session audio changed')
            if set(s)!=set(strategies):raise ValueError('strategy matrix')
            for strategy in strategies:
                group=s[strategy]
                if len(group['sessions'])!=count or group['rows']!=count:raise ValueError('session counts')
                if any(r['status']!='ok' for r in group['sessions']):raise ValueError('failed session')
                ids={r['id'] for r in group['sessions']}
                if len(ids)!=count:raise ValueError('duplicate session')
                for id in ids:
                    r=json.loads((p/strategy/f'{id}.json').read_text())
                    if r['status']!='ok':raise ValueError('failed event trace')
                    ownership=[(x['start_sample'],x['end_sample']) for x in r['segments']]
                    if any(a[1]>b[0] for a,b in zip(ownership,ownership[1:])):raise ValueError('duplicated audio')
                    if r['annotation_status']!='confirmed' and (r['endpoint_latency_seconds'] is not None or r['final_from_speech_seconds'] is not None):raise ValueError('invented human timing')
            checks['replay-'+split]=check('passed',run=str(p))
        except (KeyError,ValueError,FileNotFoundError,TypeError):checks['replay-'+split]=check('failed',run=str(p))
    evaluation=replay_by_split.get('eval')
    confirmed=False
    if evaluation:
        annotations=json.loads((evaluation/'annotations.json').read_text())
        confirmed=len(annotations)==36 and all(r['status']=='confirmed' and r['annotator'] and r['spans'] for r in annotations)
    checks['human_boundaries']=check('passed' if confirmed else 'manual_pending',reason='36 real listening confirmations required')
    correction=latest(root,'correction-runs')
    if correction:
        try:
            validate_frozen_sources(correction)
            s=json.loads((correction/'summary.json').read_text());execution=json.loads((correction/'execution.json').read_text())
            tasks=read_rows(correction/'inference-inputs.jsonl');rows=read_rows(correction/'completions.jsonl')
            if s['completion_sha256']!=sha(correction/'completions.jsonl') or s['inference_input_sha256']!=sha(correction/'inference-inputs.jsonl'):raise ValueError('correction scoring hashes changed')
            validate_correction_matrix(tasks,rows)
            expected_conditions={f'{d}-{c}' for d,cs in [('librispeech',['raw','plain','contextual','mismatched']),('ascend',['raw','plain','static_tech'])] for c in cs}
            if set(s['conditions'])!=expected_conditions:raise ValueError('Missing condition summary')
            key=lambda r:(r['dataset'],r['id'],r['condition'])
            if not s['complete'] or not execution['complete'] or len(tasks)!=982 or len(rows)!=982 or len({key(r) for r in rows})!=982 or {key(r) for r in rows}!={key(r) for r in tasks}:raise ValueError('incomplete correction')
            protocol=json.loads((correction/'protocol.json').read_text())
            if protocol['input_sha256']!=sha(correction/'inference-inputs.jsonl') or execution['requests']>1000:raise ValueError('correction identity/budget')
            for d in ['librispeech','ascend']:
                if protocol['config']['baseline_hashes'][d]!=sha(root/'prepared'/d/'baseline-predictions.jsonl'):raise ValueError('baseline changed')
            if protocol['config']['mixed_baseline_sha256']!=sha(root/'prepared/ascend/mixed-baseline.jsonl') or protocol['config']['vocab_sha256']!=sha(root/'prepared/technical-vocabulary.json'):raise ValueError('mixed/vocabulary identity')
            if protocol['config']['requested_model']!='deepseek-ai/DeepSeek-V3' or protocol['config']['provider']!='SiliconFlow':raise ValueError('provider identity')
            originals={key(t):t['asr_text'] for t in tasks}
            if any(r['status']!='ok' and r['text']!=originals[key(r)] for r in rows):raise ValueError('fallback changed original')
            checks['correction']=check('passed',run=str(correction),requests=execution['requests'],reported_tokens=execution['reported_tokens'])
        except (ValueError,KeyError,FileNotFoundError,TypeError):checks['correction']=check('failed',run=str(correction))
    else:checks['correction']=check('not_run')
    # Manual demonstrations have no automated route to confirmation.
    checks['microphone_demo']=check('manual_pending',reason='3 real microphone/TextEdit insertions must be observed and recorded manually')
    checks['recorded_replay_demo']=check('manual_pending',reason='60–90s recorded demonstration not yet confirmed')
    required=list(checks)
    if profile=='compact':required=[k for k in required if k not in ['model-qwen-0.6b','replay-dev']]
    statuses=[checks[k]['status'] for k in required]
    return dict(profile=profile,status='passed' if all(s=='passed' for s in statuses) else 'partial',checks=checks,
                limitations=['Not a blind benchmark; public custom subsets','ASR RTF, LLM network time, and confirmed product insertion are different quantities','dispatch is an attempt, never proof of inserted text'])
