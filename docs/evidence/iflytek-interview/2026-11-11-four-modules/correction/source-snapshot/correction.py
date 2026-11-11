"""Fixed-budget contextual correction. References are scoring-only."""
from concurrent.futures import ThreadPoolExecutor, wait, FIRST_COMPLETED
from collections import Counter
from datetime import datetime,timezone
import json
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit
import jiwer
from tools.run_contextual_asr_correction import SYSTEM, CONTEXT, SETTINGS, parse_completion, load_provider
from tools.score_asr_baseline import evaluate, mixed_tokens
from tools.score_librispeech_biasing import normalize_hypothesis
from .schema import read_rows, write_rows, write_json, freeze_run, sha


def build_conditions(rows, vocab, dataset):
    if dataset not in ['librispeech','ascend']:raise ValueError('Unknown dataset')
    rows=sorted(rows,key=lambda r:r['id'])
    if len({r['id'] for r in rows})!=len(rows):raise ValueError('Duplicate IDs')
    conditions=['plain','contextual','mismatched'] if dataset=='librispeech' else ['plain','static_tech']
    return [dict(id=r['id'],dataset=dataset,condition=c,asr_text=r['asr_text'],
                 candidates=[] if c=='plain' else list(rows[(i+1)%len(rows)]['candidates']) if c=='mismatched' else list(r['candidates']) if c=='contextual' else list(vocab))
            for i,r in enumerate(rows) for c in conditions]


def payload(task):
    body={'transcript':task['asr_text']}
    if task['condition']!='plain':body['candidate_words']=task['candidates']
    return [dict(role='system',content=SYSTEM+(CONTEXT if task['condition']!='plain' else '')),
            dict(role='user',content=json.dumps(body,ensure_ascii=False))]


def completion(response, original):return parse_completion(response,original)


def execute_tasks(tasks,request,max_requests=1000,max_reported_tokens=1000000,on_result=None):
    if not 0<=max_requests<=1000 or max_reported_tokens<1:raise ValueError('Invalid budget')
    results=[];requested=0;tokens=0;cursor=0;pending={}
    def emit(t,r):
        result={k:t[k] for k in ['id','dataset','condition']};result.update(r)
        results.append(result)
        if on_result:on_result(result)
    with ThreadPoolExecutor(max_workers=4) as pool:
        while cursor<len(tasks) or pending:
            while len(pending)<4 and cursor<len(tasks) and requested<max_requests and tokens<max_reported_tokens:
                t=tasks[cursor];cursor+=1
                if not t['asr_text'].strip():
                    emit(t,dict(text=t['asr_text'],status='baseline_empty',failure=None,latency_seconds=0));continue
                requested+=1;pending[pool.submit(request,t)]=t
            if not pending:break
            done,_=wait(pending,return_when=FIRST_COMPLETED)
            for future in done:
                t=pending.pop(future)
                try:r=future.result()
                except Exception:r=dict(text=t['asr_text'],status='fallback',failure='request_exception',latency_seconds=0)
                if r['status']!='ok':r['text']=t['asr_text']
                usage=r.get('usage',{}).get('total_tokens')
                if isinstance(usage,int) and not isinstance(usage,bool) and usage>=0:tokens+=usage
                emit(t,r)
        for t in tasks[cursor:]:
            emit(t,dict(text=t['asr_text'],status='not_requested' if t['asr_text'].strip() else 'baseline_empty',failure='budget_stop' if t['asr_text'].strip() else None,latency_seconds=0))
    return results,dict(requests=requested,reported_tokens=tokens,complete=all(r['status']!='not_requested' for r in results),
                        max_inflight=4,usage_missing=sum('total_tokens' not in r.get('usage',{}) for r in results if r['status'] not in ['baseline_empty','not_requested']))


def request_cloud(task,provider,key,url):
    body=dict(model=provider['model'],messages=payload(task),**SETTINGS)
    start=time.monotonic()
    with tempfile.TemporaryFile() as handle:
        handle.write(json.dumps(body,ensure_ascii=False).encode());handle.seek(0)
        config='header = '+json.dumps('Authorization: Bearer '+key)+'\n'
        proc=subprocess.run(['curl','--silent','--show-error','--fail','--max-time','90','--proto','=https',
              '--config','-','--header','Content-Type: application/json','--data-binary',f'@/dev/fd/{handle.fileno()}',url],
              input=config.encode(),capture_output=True,pass_fds=(handle.fileno(),))
    if proc.returncode:
        result=dict(text=task['asr_text'],status='fallback',failure='curl_exit_'+str(proc.returncode))
    else:
        try:result=completion(json.loads(proc.stdout),task['asr_text'])
        except (ValueError,UnicodeError):result=dict(text=task['asr_text'],status='fallback',failure='invalid_json')
    result['latency_seconds']=time.monotonic()-start
    return result


def run_correction(root,max_requests=1000,max_reported_tokens=1000000):
    provider,key,url=load_provider()
    if provider.get('provider')!='SiliconFlow' or provider.get('model')!='deepseek-ai/DeepSeek-V3' or urlsplit(url).hostname!='api.siliconflow.cn':
        raise ValueError('Configured provider/model differs from frozen protocol; no requests sent')
    tasks=[]
    for dataset in ['librispeech','ascend']:
        directory=root/'prepared'/dataset
        preds=read_rows(directory/('baseline-predictions.jsonl' if dataset=='librispeech' else 'mixed-baseline.jsonl'))
        # Candidate field is the complete fourth-column list. Ref text/rare_words are excluded.
        candidate_rows=read_rows(directory/'references.jsonl') if dataset=='librispeech' else []
        candidates={r['id']:r['biasing_words'] for r in candidate_rows}
        rows=[dict(id=p['id'],asr_text=p['text'] if p['status']=='ok' else '',candidates=candidates.get(p['id'],[])) for p in preds]
        vocab=json.loads((root/'prepared/technical-vocabulary.json').read_text())['words']
        tasks+=build_conditions(rows,vocab,dataset)
    if len(tasks)!=982:raise ValueError('Unexpected correction matrix')
    directory=root/'correction-runs'/datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    directory.parent.mkdir(parents=True,exist_ok=True)
    inputfile=directory.parent/(directory.name+'-inputs.jsonl');write_rows(inputfile,tasks)
    freeze_run(dict(provider='SiliconFlow',host=urlsplit(url).hostname,requested_model=provider['model'],
                    settings=SETTINGS,system_prompt=SYSTEM,context_suffix=CONTEXT,max_requests=max_requests,max_reported_tokens=max_reported_tokens,
                    baseline_hashes={d:sha(root/'prepared'/d/'baseline-predictions.jsonl') for d in ['librispeech','ascend']},
                    mixed_baseline_sha256=sha(root/'prepared/ascend/mixed-baseline.jsonl'),vocab_sha256=sha(root/'prepared/technical-vocabulary.json'),
                    scope='Exploratory fixed custom pilots; alias service weights may change; not blind or SOTA',retries=0),inputfile,directory)
    shutil.move(inputfile,directory/'inference-inputs.jsonl')
    with (directory/'completions.jsonl').open('x') as output:
        count=0
        def record(r):
            nonlocal count
            output.write(json.dumps(r,ensure_ascii=False)+'\n');output.flush();count+=1
            if count%20==0:print(f'correction {count}/982',flush=True)
        _,stats=execute_tasks(tasks,lambda t:request_cloud(t,provider,key,url),max_requests,max_reported_tokens,record)
    write_json(directory/'execution.json',stats)
    score_correction(directory,root)
    return directory


def score_correction(run_dir,root=None):
    root=root or run_dir.parents[1]
    tasks=read_rows(run_dir/'inference-inputs.jsonl');rows=read_rows(run_dir/'completions.jsonl')
    identity=lambda r:(r['dataset'],r['id'],r['condition'])
    expected={identity(t):t for t in tasks};actual=[identity(r) for r in rows]
    if len(expected)!=len(tasks) or len(actual)!=len(set(actual)) or set(actual)!=set(expected):raise ValueError('Incomplete/extra/duplicate completions')
    for r in rows:
        if r['status'] not in ['ok','fallback','baseline_empty','not_requested'] or not isinstance(r['text'],str):raise ValueError('Invalid completion')
        if r['status']!='ok' and r['text']!=expected[identity(r)]['asr_text']:raise ValueError('Fallback changed original')
    if any(r['status']=='not_requested' for r in rows):
        result={'complete':False,'reason':'budget_stop','scored':False};write_json(run_dir/'summary.json',result);return result
    result=dict(complete=True,conditions={});diagnostics=[]
    for dataset in ['librispeech','ascend']:
        prepared=root/'prepared'/dataset
        refs=read_rows(prepared/('references.jsonl' if dataset=='librispeech' else 'mixed-references.jsonl'))
        refs_by={r['id']:r for r in refs}
        base=read_rows(prepared/('baseline-predictions.jsonl' if dataset=='librispeech' else 'mixed-baseline.jsonl'))
        base_by={r['id']:r for r in base}
        conditions=['raw','plain','contextual','mismatched'] if dataset=='librispeech' else ['raw','plain','static_tech']
        for condition in conditions:
            group=[dict(id=r['id'],text=r['text'],status='raw',latency_seconds=0) for r in base] if condition=='raw' else [r for r in rows if r['dataset']==dataset and r['condition']==condition]
            if len(group)!=len(base) or {r['id'] for r in group}!=set(base_by):raise ValueError('Wrong condition scope')
            target=run_dir/f'{dataset}-{condition}';target.mkdir(exist_ok=True)
            predictions=[dict(id=r['id'],text=r['text'],status='ok',latency_seconds=r['latency_seconds'],audio_seconds=base_by[r['id']]['audio_seconds']) for r in group]
            write_rows(target/'predictions.jsonl',predictions)
            if dataset=='librispeech':
                for file in ['official-refs.tsv','scoring-protocol.json']:shutil.copyfile(prepared/file,target/file)
                subprocess.run([sys.executable,'tools/score_librispeech_biasing.py','--run',str(target),'--official-scorer',str(root.parent/'asr-baseline-20261111/official_biasing_score.py')],check=True,capture_output=True)
                metric=json.loads((target/'scored/summary.json').read_text())['metrics']
                tokenize=lambda t:normalize_hypothesis(t).split()
            else:
                summary,scored=evaluate(refs,predictions);metric=dict(clean=summary['clean'],by_language=summary['by_language']);write_rows(target/'scored_rows.jsonl',scored)
                tokenize=mixed_tokens
            counts=Counter();covered=0;candidate_total=0
            for r in group:
                ref=refs_by[r['id']]['transcription'];original=base_by[r['id']]['text']
                def edits(text):
                    a=jiwer.process_words(' '.join(tokenize(ref)),' '.join(tokenize(text)))
                    return a.substitutions+a.deletions+a.insertions
                before,after=edits(original),edits(r['text'])
                counts['improved' if after<before else 'harmed' if after>before else 'same_error_count']+=1
                counts['previously_correct_rows']+=before==0;counts['previously_correct_harmed']+=before==0 and after>0
                counts['changed']+=tokenize(original)!=tokenize(r['text'])
                t=expected.get((dataset,r['id'],condition));candidates=t['candidates'] if t else []
                ref_tokens=set(tokenize(ref));matches=[w for w in candidates if set(tokenize(w))<=ref_tokens and tokenize(w)]
                covered+=bool(matches);candidate_total+=len(candidates)
                diagnostics.append(dict(dataset=dataset,condition=condition,id=r['id'],reference=ref,original=original,corrected=r['text'],before_errors=before,after_errors=after,candidate_matches=matches))
            latencies=[r['latency_seconds'] for r in group]
            result['conditions'][f'{dataset}-{condition}']=dict(metrics=metric,paired_diagnostics=dict(counts),
                fallback_count=sum(r['status']=='fallback' for r in group),baseline_empty=sum(r['status']=='baseline_empty' for r in group),
                latency_median_seconds=statistics.median(latencies),llm_network_seconds=sum(latencies),
                usage_missing=sum('total_tokens' not in r.get('usage',{}) for r in group) if condition!='raw' else 0,
                reported_tokens=sum(max(0,r.get('usage',{}).get('total_tokens',0)) for r in group),
                served_models=dict(Counter(r.get('served_model','not_reported') for r in group)),
                posthoc_candidate_sentence_coverage=covered/len(group),candidate_count=candidate_total,
                alignment_note='paired diagnostics use unit-cost edit distance; official B/U aggregate uses weighted alignment')
    write_rows(run_dir/'paired-diagnostics.jsonl',diagnostics);write_json(run_dir/'summary.json',result)
    lines=['# Fixed correction matrix','', 'English 200-row custom pilot, mixed ASCEND 191; neither is a technical-term specialist benchmark. Full candidate lists include distractors; mismatched lists are cyclically reassigned and can accidentally contain useful words. Posthoc coverage is scored only after inference. No prompt tuning on these outputs.','', '| Condition | metrics | harmed / originally correct harmed | fallback | median LLM network s | reported tokens / missing |','|---|---|---|---:|---:|---|']
    for name,s in result['conditions'].items():
        d=s['paired_diagnostics'];lines.append(f"| {name} | {json.dumps(s['metrics'])} | {d.get('harmed',0)} / {d.get('previously_correct_harmed',0)} | {s['fallback_count']} | {s['latency_median_seconds']:.3f} | {s['reported_tokens']} / {s['usage_missing']} |")
    lines+=['','API fallback keeps original text and counts in scores. LLM network latency is not ASR RTF or confirmed product end-to-end latency. Alias model versions may vary. Historical pilot is separate; spelling normalization (ardor→ardour) is not acoustic understanding. Candidate-supported wrong replacements and numeral rewrites remain risks.','']
    (run_dir/'report.md').write_text('\n'.join(lines));return result
