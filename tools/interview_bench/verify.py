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


def validate_correction_matrix(tasks, rows, profile='full'):
    if profile not in ['full','compact']:raise ValueError('Unknown profile')
    from collections import Counter
    expected={('librispeech',c):200 for c in ['plain','contextual','mismatched']}
    expected.update({('ascend',c):191 for c in ['plain','static_tech']})
    if profile=='compact' and len(tasks)==200:expected={('librispeech','mismatched'):200}
    size=sum(expected.values())
    identity=lambda r:(r['dataset'],r['id'],r['condition'])
    if Counter((t['dataset'],t['condition']) for t in tasks)!=expected:
        raise ValueError('Wrong fixed correction matrix')
    keys=[identity(t) for t in tasks];actual=[identity(r) for r in rows]
    if len(set(keys))!=size or len(set(actual))!=size or len(actual)!=size or set(keys)!=set(actual):
        raise ValueError('Incomplete/extra/duplicate corrections')
    for dataset in ['librispeech','ascend']:
        groups=[{t['id'] for t in tasks if t['dataset']==d and t['condition']==c} for d,c in expected if d==dataset]
        if groups and any(g!=groups[0] for g in groups):raise ValueError('Condition IDs differ')


def historical_corrections(root, directory=None):
    """Validate the frozen 400-output pilot before a compact cross-batch analysis."""
    from tools.run_contextual_asr_correction import SYSTEM, CONTEXT, SETTINGS
    directory=directory or Path('docs/evidence/2026-11-11-contextual-asr-correction')
    protocol=json.loads((directory/'protocol.json').read_text())
    summary=json.loads((directory/'comparison-summary.json').read_text())
    prepared=root/'prepared/librispeech'
    for name,key in [('baseline-predictions.jsonl','baseline_predictions_sha256'),('references.jsonl','candidate_source_sha256')]:
        if sha(prepared/name)!=protocol[key]:raise ValueError('Historical baseline/candidates changed')
    if sha(directory/'inference-inputs.jsonl')!=protocol['inputs_sha256'] or sha(directory/'completions.jsonl')!=summary['completions_sha256'] or sha(directory/'protocol.json')!=summary['protocol_sha256']:raise ValueError('Historical artifact changed')
    if protocol['system_prompt']!=SYSTEM or protocol['contextual_suffix']!=CONTEXT or protocol['settings']!=SETTINGS or protocol['requested_model']!='deepseek-ai/DeepSeek-V3' or protocol['provider']!='SiliconFlow':raise ValueError('Historical method changed')
    inputs=read_rows(directory/'inference-inputs.jsonl');rows=read_rows(directory/'completions.jsonl')
    refs={r['id']:r for r in read_rows(prepared/'references.jsonl')}
    base={r['id']:r for r in read_rows(prepared/'baseline-predictions.jsonl')}
    if len(inputs)!=200 or len({r['id'] for r in inputs})!=200 or {r['id'] for r in inputs}!=set(base) or set(refs)!=set(base):raise ValueError('Historical input scope')
    for r in inputs:
        if r['asr_text']!=base[r['id']]['text'] or r['candidates']!=refs[r['id']]['biasing_words']:raise ValueError('Historical input contents')
    expected={(r['id'],c) for r in inputs for c in ['plain','contextual']}
    if len(rows)!=400 or {(r['id'],r['condition']) for r in rows}!=expected:raise ValueError('Historical completion scope')
    for r in rows:
        if not isinstance(r['text'],str) or r['status'] not in ['ok','fallback','baseline_empty'] or (r['status']!='ok' and r['text']!=base[r['id']]['text']):raise ValueError('Historical fallback changed')
    tasks=[dict(id=r['id'],dataset='librispeech',condition=c,asr_text=r['asr_text'],candidates=r['candidates'] if c=='contextual' else []) for r in inputs for c in ['plain','contextual']]
    return tasks,[dict(dataset='librispeech',**r) for r in rows]


def boundaries_confirmed(annotations, required_ids):
    """Only human-confirmed boundaries for the selected source IDs count."""
    by={r['id']:r for r in annotations}
    if len(by)!=len(annotations) or not required_ids:return False
    for id in required_ids:
        r=by.get(id,{})
        if r.get('status')!='confirmed' or not r.get('annotator','').strip() or not r.get('spans'):return False
        last=0
        for span in r['spans']:
            a,b=span['start_sample'],span['end_sample']
            if type(a)!=int or type(b)!=int or not last<=a<b<=r.get('frames',b):return False
            last=b
    return True


def verify_manual(root):
    from datetime import datetime
    import subprocess
    result={k:check('manual_pending',reason=reason) for k,reason in [
        ('microphone_demo','3 real microphone/TextEdit insertions require a human observation record'),
        ('recorded_replay_demo','60–90s replay recording requires a real media file and human observation')]}
    path=root/'manual-demonstrations.json'
    if not path.exists():return result
    try:manual=json.loads(path.read_text())
    except (ValueError,TypeError):return {k:check('failed',reason='invalid manual record') for k in result}
    if not isinstance(manual,dict):return {k:check('failed',reason='manual record must be an object') for k in result}
    microphone=manual.get('microphone',{})
    if not isinstance(microphone,dict):return {k:check('failed',reason='invalid manual record sections') for k in result}
    if microphone.get('status')=='confirmed':
        try:
            observations=microphone['observations']
            if len(observations)!=3 or {o['kind'] for o in observations}!={'short','mixed','technical'}:raise ValueError('cases')
            for o in observations:
                if not o['observer'].strip() or not o['spoken_text'].strip() or not o['observed_text'].strip() or o['target_app']!='TextEdit' or o['confirmed_inserted'] is not True:raise ValueError('actual observed text required')
                timestamp=datetime.fromisoformat(o['observed_at_utc'])
                if timestamp.utcoffset() is None:raise ValueError('timestamp timezone')
            result['microphone_demo']=check('passed',evidence='human observation, not independently proven by dispatch')
        except (ValueError,KeyError,TypeError,AttributeError):result['microphone_demo']=check('failed',reason='incomplete human insertion observations')
    recording=manual.get('replay_recording',{})
    if not isinstance(recording,dict):
        result['recorded_replay_demo']=check('failed',reason='invalid recording section');return result
    if recording.get('status')=='confirmed':
        try:
            video=Path(recording['path'])
            if not video.is_absolute():video=root/video
            if not recording['observer'].strip() or sha(video)!=recording['sha256']:raise ValueError('recording identity')
            probe=subprocess.run(['ffprobe','-v','error','-show_entries','format=duration','-of','json',str(video)],capture_output=True,text=True,check=True)
            seconds=float(json.loads(probe.stdout)['format']['duration'])
            if not 60<=seconds<=90:raise ValueError('recording duration')
            result['recorded_replay_demo']=check('passed',seconds=seconds,evidence='media hash/duration plus human observation')
        except (ValueError,KeyError,TypeError,AttributeError,FileNotFoundError,subprocess.SubprocessError):result['recorded_replay_demo']=check('failed',reason='missing/invalid recording or observation')
    return result


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
            canonical_path=root/'replay-prepared/sessions.json'
            if sha(canonical_path)!=protocol['input_sha256'] or protocol['config']['sessions_sha256']!=protocol['input_sha256']:raise ValueError('session input changed')
            canonical=[r for r in json.loads(canonical_path.read_text()) if r['split']==split]
            expected_ids={r['id'] for r in canonical}
            snapshot=json.loads((p/'sessions.json').read_text())
            if len(canonical)!=count or len(expected_ids)!=count or snapshot!=canonical:raise ValueError('session snapshot identity')
            for session in snapshot:
                if sha(Path(session['path']))!=session['sha256']:raise ValueError('session audio changed')
            if set(s)!=set(strategies):raise ValueError('strategy matrix')
            for strategy in strategies:
                group=s[strategy]
                if len(group['sessions'])!=count or group['rows']!=count:raise ValueError('session counts')
                if any(r['status']!='ok' for r in group['sessions']):raise ValueError('failed session')
                ids={r['id'] for r in group['sessions']}
                if len(ids)!=count or ids!=expected_ids:raise ValueError('missing/extra/duplicate session')
                predictions=read_rows(p/strategy/'predictions.jsonl')
                if len(predictions)!=count or {r['id'] for r in predictions}!=expected_ids or any(r['status']!='ok' for r in predictions):raise ValueError('prediction identities/status')
                predicted={r['id']:r for r in predictions}
                trace_names={f.name for f in (p/strategy).glob('*.json') if f.name!='summary.json'}
                if trace_names!={f'{id}.json' for id in expected_ids}:raise ValueError('trace identities')
                for id in expected_ids:
                    r=json.loads((p/strategy/f'{id}.json').read_text())
                    if r['status']!='ok' or predicted[id]['text']!=r['text']:raise ValueError('failed/mismatched event trace')
                    ownership=[(x['start_sample'],x['end_sample']) for x in r['segments']]
                    if any(a[1]>b[0] for a,b in zip(ownership,ownership[1:])):raise ValueError('duplicated audio')
                    if r['annotation_status']!='confirmed' and (r['endpoint_latency_seconds'] is not None or r['final_from_speech_seconds'] is not None):raise ValueError('invented human timing')
            checks['replay-'+split]=check('passed',run=str(p))
        except (KeyError,ValueError,FileNotFoundError,TypeError):checks['replay-'+split]=check('failed',run=str(p))
    required_ids=set();confirmed=True
    for split in (['eval'] if profile=='compact' else ['dev','eval']):
        p=replay_by_split.get(split)
        if not p:confirmed=False;continue
        try:
            sessions=json.loads((p/'sessions.json').read_text())
            ids={r['id'] for session in sessions if session['split']==split for r in session['sources']}
            if len(ids)!=(24 if split=='eval' else 12):raise ValueError('boundary source count')
            required_ids.update(ids)
            confirmed=boundaries_confirmed(json.loads((p/'annotations.json').read_text()),ids) and confirmed
        except (ValueError,KeyError,TypeError,FileNotFoundError):confirmed=False
    checks['human_boundaries']=check('passed' if confirmed else 'manual_pending',reason=f'{24 if profile=="compact" else 36} real listening confirmations required')
    correction=latest(root,'correction-runs')
    if correction:
        try:
            validate_frozen_sources(correction)
            s=json.loads((correction/'summary.json').read_text());execution=json.loads((correction/'execution.json').read_text())
            tasks=read_rows(correction/'inference-inputs.jsonl');rows=read_rows(correction/'completions.jsonl')
            if s['completion_sha256']!=sha(correction/'completions.jsonl') or s['inference_input_sha256']!=sha(correction/'inference-inputs.jsonl'):raise ValueError('correction scoring hashes changed')
            validate_correction_matrix(tasks,rows,profile)
            compact_only=profile=='compact' and len(tasks)==200
            if compact_only:historical_corrections(root)
            expected_conditions={f'{d}-{c}' for d,cs in [('librispeech',['raw','plain','contextual','mismatched']),('ascend',['raw','plain','static_tech'])] for c in cs}
            if compact_only:expected_conditions={f'librispeech-{c}' for c in ['raw','plain','contextual','mismatched']}
            if compact_only:
                history=Path('docs/evidence/2026-11-11-contextual-asr-correction')
                if s['cross_batch_history']!={str(p):sha(p) for p in [history/'protocol.json',history/'completions.jsonl']} or s['mixed_status']!='not_run':raise ValueError('Historical analysis provenance')
            if set(s['conditions'])!=expected_conditions:raise ValueError('Missing condition summary')
            key=lambda r:(r['dataset'],r['id'],r['condition'])
            if not s['complete'] or not execution['complete'] or len(tasks)!=(200 if compact_only else 982) or len(rows)!=len(tasks) or len({key(r) for r in rows})!=len(tasks) or {key(r) for r in rows}!={key(r) for r in tasks}:raise ValueError('incomplete correction')
            protocol=json.loads((correction/'protocol.json').read_text())
            if protocol['input_sha256']!=sha(correction/'inference-inputs.jsonl') or execution['requests']>1000:raise ValueError('correction identity/budget')
            for d in ['librispeech','ascend']:
                if protocol['config']['baseline_hashes'][d]!=sha(root/'prepared'/d/'baseline-predictions.jsonl'):raise ValueError('baseline changed')
            if protocol['config']['mixed_baseline_sha256']!=sha(root/'prepared/ascend/mixed-baseline.jsonl') or protocol['config']['vocab_sha256']!=sha(root/'prepared/technical-vocabulary.json'):raise ValueError('mixed/vocabulary identity')
            if protocol['config']['requested_model']!='deepseek-ai/DeepSeek-V3' or protocol['config']['provider']!='SiliconFlow':raise ValueError('provider identity')
            originals={key(t):t['asr_text'] for t in tasks}
            if any(r['status']!='ok' and r['text']!=originals[key(r)] for r in rows):raise ValueError('fallback changed original')
            checks['correction']=check('passed',run=str(correction),requests=execution['requests'],reported_tokens=execution['reported_tokens'],
                scope='cross-batch: historical plain/contextual400 plus mismatched200; mixed not_run' if compact_only else 'full982 (superset of compact)')
        except (ValueError,KeyError,FileNotFoundError,TypeError):checks['correction']=check('failed',run=str(correction))
    else:checks['correction']=check('not_run')
    checks.update(verify_manual(root))
    required=list(checks)
    if profile=='compact':required=[k for k in required if k not in ['model-qwen-0.6b','replay-dev']]
    statuses=[checks[k]['status'] for k in required]
    return dict(profile=profile,status='passed' if all(s=='passed' for s in statuses) else 'partial',checks=checks,
                limitations=['Not a blind benchmark; public custom subsets','ASR RTF, LLM network time, and confirmed product insertion are different quantities','dispatch is an attempt, never proof of inserted text'])
