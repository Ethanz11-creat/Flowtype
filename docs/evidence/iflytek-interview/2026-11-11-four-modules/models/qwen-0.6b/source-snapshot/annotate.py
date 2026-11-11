"""Build public-audio annotation/replay assets; never invent human confirmation."""
import html
import json
from pathlib import Path
import numpy as np
import soundfile as sf
from .schema import load_audio_inputs, read_rows, sha, write_json, write_rows


def prepare_annotations(root):
    directory=root/'replay-prepared'
    if directory.exists(): return directory
    directory.mkdir(parents=True)
    selection=json.loads((root/'prepared/vad-selection.json').read_text())
    inputs={r['id']:r for r in load_audio_inputs(root/'prepared/ascend/inputs.jsonl')}
    refs={r['id']:r for r in read_rows(root/'prepared/ascend/references.jsonl')}
    annotations=[];cards=[]
    (directory/'audio').mkdir()
    for r in selection:
        id=r['id'];path=Path(inputs[id]['path']);info=sf.info(path)
        (directory/'audio'/f'{id}.wav').symlink_to(path.resolve())
        annotations.append(dict(id=id,status='pending',annotator='',spans=[],frames=info.frames))
        cards.append(f'<article><b>{html.escape(id)} · {r["language"]} · {r["split"]}</b><audio controls src="audio/{id}.wav"></audio><p>Listen, then enter speech spans in seconds, e.g. 0.2-1.4, 1.8-2.1. Include quiet/short speech; replay before confirming.</p><input data-id="{id}" placeholder="start-end, start-end"><label><input type="checkbox" data-confirm="{id}"> I listened and confirmed</label></article>')
    write_json(directory/'annotations.json',annotations)
    sessions=[];session_refs=[]
    for split in ['dev','eval']:
        for language in ['zh','en','mixed']:
            selected=[r for r in selection if r['split']==split and r['language']==language]
            for i in range(0,len(selected),4):
                group=selected[i:i+4];audio=[np.zeros(16000,dtype='float32')];offset=16000;sources=[]
                for j,r in enumerate(group):
                    data,rate=sf.read(inputs[r['id']]['path'],dtype='float32')
                    sources.append(dict(id=r['id'],offset_sample=offset,frames=len(data),sha256=sha(Path(inputs[r['id']]['path']))))
                    audio.append(data);offset+=len(data)
                    silence=[6400,9600,19200,16000][j];audio.append(np.zeros(silence,dtype='float32'));offset+=silence
                id=f'{split}-{language}-{i//4+1}';path=(directory/f'{id}.wav').resolve()
                sf.write(path,np.concatenate(audio),16000,subtype='PCM_16')
                sessions.append(dict(id=id,path=str(path),split=split,language=language,sources=sources,sha256=sha(path)))
                session_refs.append(dict(id=id,transcription=' '.join(refs[r['id']]['transcription'] for r in group),language=language,topic='constructed_replay',original_speaker_id='multiple'))
    write_json(directory/'sessions.json',sessions);write_rows(directory/'references.jsonl',session_refs)
    page='''<!doctype html><meta charset="utf-8"><title>Human speech boundaries</title><style>body{font:16px system-ui;max-width:850px;margin:30px auto;background:#f5f5f7}article{background:white;padding:20px;margin:16px 0}audio{display:block;width:100%;margin:12px 0}input{padding:8px}label{display:block}</style><h1>36-source listening annotation</h1><p>No automatic estimate counts as confirmed. Sample rate: 16000. Pending entries remain pending.</p><input id="annotator" placeholder="Your name"><button onclick="save()">Export annotations.json</button>'''+''.join(cards)+'''<script>
function save(){let name=document.querySelector('#annotator').value.trim();if(!name){alert('Enter annotator');return}let rows=[];for(let e of document.querySelectorAll('[data-id]')){let id=e.dataset.id;let yes=document.querySelector('[data-confirm="'+id+'"]').checked;let spans=[];if(yes){try{spans=e.value.split(',').map(s=>{let [a,b]=s.trim().split('-').map(Number);if(!(a>=0&&b>a))throw Error();return {start_sample:Math.round(a*16000),end_sample:Math.round(b*16000)}})}catch{alert('Invalid spans: '+id);return}}rows.push({id,status:yes?'confirmed':'pending',annotator:yes?name:'',spans})}let a=document.createElement('a');a.href=URL.createObjectURL(new Blob([JSON.stringify(rows,null,2)],{type:'application/json'}));a.download='annotations.json';a.click()}
</script>'''
    (directory/'annotate.html').write_text(page)
    return directory


def import_annotations(root,path):
    directory=prepare_annotations(root)
    original=json.loads((directory/'annotations.json').read_text());rows=json.loads(path.read_text())
    if len(rows)!=len(original) or {r['id'] for r in rows}!={r['id'] for r in original}:raise ValueError('Annotation ID mismatch')
    frames={r['id']:r['frames'] for r in original}
    for r in rows:
        if r['status'] not in ['pending','confirmed']:raise ValueError('Invalid annotation status')
        if r['status']=='confirmed':
            if not r['annotator'].strip() or not r['spans']:raise ValueError('Missing human identity or spans')
            last=0
            for s in r['spans']:
                a,b=s['start_sample'],s['end_sample']
                if not isinstance(a,int) or not isinstance(b,int) or not last<=a<b<=frames[r['id']]:raise ValueError('Invalid speech spans')
                last=b
        r['frames']=frames[r['id']]
    write_json(directory/'annotations.json',rows)
    return directory/'annotations.json'
