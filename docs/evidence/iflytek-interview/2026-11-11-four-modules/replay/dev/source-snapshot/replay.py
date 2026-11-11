"""Wall-clock audio ingress independent of serial ASR inference."""
from dataclasses import asdict
import json
from pathlib import Path
import queue
import tempfile
import threading
import time
import numpy as np
import soundfile as sf
from .schema import write_json, write_rows


class ReplayClock:
    def now(self): return time.monotonic()
    def wait_until(self, deadline):
        remaining=deadline-self.now()
        if remaining>0: time.sleep(remaining)


def endpoint_latency(decision_sample, speech_end_sample, sample_rate=16000):
    return (decision_sample-speech_end_sample)/sample_rate


def run_replay(audio_path, segmenter, worker, clock=None, cancel=None):
    clock=clock or ReplayClock();cancel=cancel or threading.Event()
    audio,rate=sf.read(str(audio_path),dtype='float32')
    if rate!=16000 or audio.ndim!=1:raise ValueError('Expected 16kHz mono')
    pending=queue.Queue(maxsize=4);events=[];results=[];lock=threading.Lock()
    origin=clock.now();error=None
    def event(kind,**kwargs):
        with lock:events.append(dict(event=kind,at_seconds=clock.now()-origin,**kwargs))
    with tempfile.TemporaryDirectory(prefix='flowtype-replay-') as tmp:
        def consume():
            while True:
                task=pending.get()
                if task is None: pending.task_done();break
                index,segment,enqueued,decision_seconds=task
                if cancel.is_set():
                    event('cancelled_pending',index=index);pending.task_done();continue
                start=clock.now();event('dequeue',index=index,wait_seconds=start-enqueued)
                path=Path(tmp)/f'{index}.wav'
                sf.write(path,audio[segment.start_sample:segment.end_sample],rate,subtype='PCM_16')
                try:
                    result=worker.transcribe(str(index),path)
                    if result.get('status')!='ok': raise RuntimeError('asr_error')
                    text=result['text'];status='ok';failure=None
                except Exception:
                    text='';status='error';failure='asr_error'
                result=dict(index=index,text=text,status=status,error_code=failure,
                            wait_seconds=start-enqueued,returned_seconds=clock.now()-origin,
                            inference_seconds=clock.now()-start,decision_seconds=decision_seconds,
                            speech_end_sample=None,**asdict(segment))
                results.append(result);event('result',**result);pending.task_done()
        consumer=threading.Thread(target=consume,name='asr-replay-worker');consumer.start()
        count=0
        def submit(segments):
            nonlocal count,error
            for segment in segments:
                if not 0<=segment.start_sample<segment.end_sample<=segmenter.samples_seen<=len(audio):
                    raise ValueError('Future or invalid segment')
                count+=1;decision_seconds=clock.now()-origin
                event('segment',index=count,**asdict(segment))
                try:
                    pending.put_nowait((count,segment,clock.now(),decision_seconds))
                    event('enqueue',index=count,queue_depth=pending.qsize())
                except queue.Full:
                    error='queue_overflow';event('failed',error_code=error,index=count);return False
            return True
        try:
            for begin in range(0,len(audio),512):
                if cancel.is_set():error='cancelled';break
                end=min(begin+512,len(audio));clock.wait_until(origin+end/rate)
                if cancel.is_set():error='cancelled';break
                event('audio',end_sample=end)
                if not submit(segmenter.process(audio[begin:end])):break
            if error is None:submit(segmenter.flush())
        except BaseException:
            cancel.set();raise
        finally:
            pending.put(None);consumer.join() # current compute exits before caller closes model
    results.sort(key=lambda r:r['index'])
    failed=error or ('asr_error' if any(r['status']!='ok' for r in results) else None)
    return dict(status='failed' if failed else 'ok',error_code=failed,events=events,segments=results,
                text=' '.join(r['text'] for r in results),audio_seconds=len(audio)/rate,
                first_result_seconds=next((r['returned_seconds'] for r in results if r['text'].strip()),None),
                final_result_seconds=results[-1]['returned_seconds'] if results else None,
                endpoint_latency_seconds=None,final_from_speech_seconds=None,annotation_status='manual_pending')


def score_endpoints(result, session, annotations):
    annotations={r['id']:r for r in annotations}
    if not all(annotations[s['id']]['status']=='confirmed' for s in session['sources']):return result
    spans=[dict(start_sample=p['start_sample']+s['offset_sample'],end_sample=p['end_sample']+s['offset_sample'])
           for s in session['sources'] for p in annotations[s['id']]['spans']]
    delays=[]
    for segment in result['segments']:
        matched=[s['end_sample'] for s in spans if s['start_sample']<segment['end_sample'] and s['end_sample']>segment['start_sample']]
        if matched:
            segment['speech_end_sample']=max(matched)
            segment['signal_endpoint_latency_seconds']=endpoint_latency(segment['decision_sample'],max(matched))
            segment['endpoint_latency_seconds']=segment['decision_seconds']-max(matched)/16000
            delays.append(segment['endpoint_latency_seconds'])
    result.update(annotation_status='confirmed',endpoint_latency_seconds=delays,
                  final_from_speech_seconds=(result['final_result_seconds']-max(s['end_sample'] for s in spans)/16000) if result['final_result_seconds'] is not None else None)
    return result


def replay_html(run, session, result):
    import html
    payload=json.dumps(result,ensure_ascii=False).replace('<','\\u003c')
    page='''<!doctype html><meta charset="utf-8"><title>Constructed VAD replay</title><style>body{font:17px system-ui;max-width:1000px;margin:30px auto;background:#eff1f8}pre{white-space:pre-wrap}#text{font-size:26px;min-height:100px;background:white;padding:24px}audio{width:100%}</style><h1>Constructed public-audio replay</h1><p>Incremental segment results, not token streaming or confirmed client insertion. Endpoint timing requires human boundaries.</p>'''
    page+=f'<audio id="audio" controls src="{html.escape(Path(session["path"]).as_uri())}"></audio><div id="text"></div><pre id="events"></pre><script>let r={payload};'
    page+='''let a=document.querySelector('audio'),origin=null;a.onplay=()=>{origin=performance.now()-a.currentTime*1000};setInterval(()=>{if(origin===null)return;let t=(performance.now()-origin)/1000;document.querySelector('#text').textContent=r.segments.filter(s=>s.returned_seconds<=t).map(s=>s.text).join(' ');document.querySelector('#events').textContent=JSON.stringify(r.events.filter(e=>e.at_seconds<=t).slice(-8),null,2)},50)</script>'''
    (run/f'{session["id"]}.html').write_text(page)


def run_sessions(root,split):
    from datetime import datetime,timezone
    from .annotate import prepare_annotations
    from .models import backend
    from .schema import freeze_run,sha
    from .vad import FixedSegmenter,Segmenter,Silero
    from tools.score_asr_baseline import evaluate
    prepared=prepare_annotations(root)
    sessions=[s for s in json.loads((prepared/'sessions.json').read_text()) if s['split']==split]
    annotations=json.loads((prepared/'annotations.json').read_text())
    output=root/'replay-runs'/datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    freeze_run(dict(split=split,model_id='qwen-1.7b',annotations_sha256=sha(prepared/'annotations.json'),
                    sessions_sha256=sha(prepared/'sessions.json'),vad=json.loads((Path(__file__).parent/'configs/vad.json').read_text()),
                    constructed=True,token_streaming=False),prepared/'sessions.json',output)
    write_json(output/'annotations.json',annotations);write_json(output/'sessions.json',sessions)
    strategies=['whole','fixed5','vad300','vad600','vad900'] if split=='dev' else ['whole','fixed5','vad600']
    silero=Silero(root/'models/silero-v5.1/silero_vad.jit')
    summaries={}
    with (output/'native.stderr').open('w') as log:
        worker,ready=backend(root,'qwen-1.7b',log);write_json(output/'ready.json',ready)
        try:
            for strategy in strategies:
                target=output/strategy;target.mkdir();predictions=[];results=[]
                for session in sessions:
                    segmenter=FixedSegmenter(None if strategy=='whole' else 80000) if strategy in ['whole','fixed5'] else Segmenter(silero,int(strategy[3:]))
                    result=run_replay(Path(session['path']),segmenter,worker)
                    score_endpoints(result,session,annotations)
                    write_json(target/f'{session["id"]}.json',result);replay_html(target,session,result)
                    for s in result['segments']:print(f'{strategy} {session["id"]} {s["returned_seconds"]:.2f}s {s["text"]}',flush=True)
                    predictions.append(dict(id=session['id'],text=result['text'] if result['status']=='ok' else '',status='ok' if result['status']=='ok' else 'error',latency_seconds=result['final_result_seconds'] or 0,audio_seconds=result['audio_seconds']))
                    results.append(dict(id=session['id'],status=result['status'],first_result_seconds=result['first_result_seconds'],final_result_seconds=result['final_result_seconds'],endpoint_latency_seconds=result['endpoint_latency_seconds'],final_from_speech_seconds=result['final_from_speech_seconds'],annotation_status=result['annotation_status'],wait_seconds=[s['wait_seconds'] for s in result['segments']]))
                refs=[r for r in __import__('tools.interview_bench.schema',fromlist=['read_rows']).read_rows(prepared/'references.jsonl') if r['id'] in {s['id'] for s in sessions}]
                summary,scored=evaluate(refs,predictions);write_rows(target/'predictions.jsonl',predictions)
                summary.update(sessions=results,annotation_status='confirmed' if all(r['annotation_status']=='confirmed' for r in results) else 'manual_pending')
                write_json(target/'summary.json',summary);write_rows(target/'scored_rows.jsonl',scored);summaries[strategy]=summary
        finally:worker.close()
    write_json(output/'summary.json',summaries)
    lines=['# Constructed replay comparison','',f'Split: {split}. 32ms real-clock PCM ingress; serial Qwen1.7 ASR. Constructed public clips ≠ natural continuous sessions. Incremental segment results ≠ token streaming.','', '| Strategy | MER edits/units | first result / final result (seconds, each session) | endpoint |','|---|---|---|---|']
    for strategy,s in summaries.items():
        g=s['clean'];timings='; '.join(f"{r['id']}: {r['first_result_seconds']} / {r['final_result_seconds']}" for r in s['sessions'])
        lines.append(f"| {strategy} | {g['edit_errors']}/{g['reference_units']} ({g['mer']:.2%}) | {timings} | {s['annotation_status']} |")
    lines+=['','No p95/SLA claim from six eval sessions. See JSON for queue waiting, each endpoint (including negative early cuts), and final-from-speech delay. Manual-pending delays are null. Microphone/client insertion demonstrations are separate.','']
    (output/'report.md').write_text('\n'.join(lines));return output
