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
                   scorer_sha256=sha(Path('tools/score_asr_baseline.py')),analysis_sha256=sha(Path(__file__)),
                   timing=json.loads((run_dir/'timing.json').read_text()),
                   resource=json.loads((run_dir/'resource.json').read_text()))
    if summary.get('cross_batch_history'):
        lines+=['','compact：plain/contextual来自历史400请求，mismatched来自本批200请求；跨批次服务别名可能漂移。mixed扩展not_run，本报告中相关分母/局限为full设计说明，不能视作compact实测。','']
    (run_dir/'analysis-source').mkdir(exist_ok=True)
    __import__('shutil').copyfile(Path(__file__),run_dir/'analysis-source/report.py')
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
    lines += ['', '| Language | Rows / reference units | Model | Edits | MER |', '|---|---|---|---:|---:|']
    for s in summaries:
        for language,g in s['by_language'].items():
            lines.append(f"| {language} | {g['rows']} / {g['reference_units']} | {s['model_id']} | {g['edit_errors']} | {g['mer']:.2%} |")
    lines += ['', 'Load timers cover model loading inside the worker, excluding process launch and dependency imports; this is not product cold-start latency.', '', '**Different performance protocols/backends/build modes** are shown above; RSS is macOS process memory, not complete GPU allocation. Warmup is separate; all scoring rows are rerun. Desktop/client load is uncontrolled. Historical baseline is separate.', '']
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


def report(root, profile='full'):
    from .verify import verify,model_runs,latest
    directory=root/'reports';directory.mkdir(parents=True,exist_ok=True)
    runs=model_runs(root);complete=[]
    refs=root/'prepared/ascend/references.jsonl'
    for model,p in runs.items():
        if (p/'timing.json').is_file() and (p/'resource.json').is_file():
            score_model_run(p,refs);complete.append(p)
    if complete:
        render_model_comparison(complete,directory/'model-comparison.md')
        old={r['id']:r['text'] for r in read_rows(root/'prepared/ascend/baseline-predictions.jsonl')}
        if 'qwen-1.7b' in runs and (runs['qwen-1.7b']/'summary.json').exists():
            new=read_rows(runs['qwen-1.7b']/'predictions.jsonl')
            write_json(directory/'historical-difference.json',dict(changed_text_rows=sum(old[r['id']]!=r['text'] for r in new),
                rows=len(new),old_prediction_sha256=sha(root/'prepared/ascend/baseline-predictions.jsonl'),
                new_prediction_sha256=sha(runs['qwen-1.7b']/'predictions.jsonl'),
                note='Historical baseline had no separate warmup; new worker has explicit identity and copied Metal resources; deployment build remains SPM debug. Historical run is not pooled into new performance table.'))
    correction=latest(root,'correction-runs')
    if correction:render_correction(correction)
    validation=verify(root,profile);write_json(directory/'verification.json',validation)
    lines=['# 科大讯飞面试实验总览','',f"当前矩阵：**{validation['status']}**；profile={profile}。",'',
           '| 项目 | 状态 | 证据 |','|---|---|---|']
    for name,s in validation['checks'].items():
        p=Path(s['run']).resolve() if s.get('run') else None
        lines.append(f"| {name} | {s['status']} | {f'[{p.name}]({p.as_uri()})' if p else s.get('reason','')} |")
    lines+=['','## 阅读路径','',
            '- 模型：[部署对比](model-comparison.md)，同时查看每模型 protocol、predictions、timing、resource、summary。',
            '- 回放：每批 report.md、策略目录 JSON/HTML。先看每会话的时间和排队，再看分段 MER。',
            '- 纠错：每批 report.md、summary.json、paired-diagnostics.jsonl。比较 B/U、正确句误改、fallback；网络时间不是 ASR RTF。',
            '- 人工试听：[标注页面](../replay-prepared/annotate.html)。未确认的端点和语音结束延迟为 null。',
            '', '## 事实边界','',
            '本轮为面试准备的真实推理与对照实验，不是盲测、科研创新或 SOTA 证明。ASCEND 是自定义 clean-reference 子集，LibriSpeech 是 200 条自定义 pilot；mixed 191 不构成技术术语专项。后端不同只比较部署组合。构造回放不等于自然连续语音；分段结果逐步出现不等于 token streaming。',
            '', 'dispatch 仅证明尝试发送，不能证明目标应用已落字。真实麦克风与 TextEdit 的三次确认、36条试听边界、60–90秒录制演示，均需真实操作与人工记录；缺失时保持 manual_pending。',
            '', '## 复现','',
            '依次运行 prepare → assets --download → models --admission-only → models → replay --prepare-annotations → replay --split dev/eval → correction --allow-cloud → report/verify。已存在的冻结输入/批次不可覆盖。模型比较必须串行运行，安装及参数见 tools/interview_bench/README.md。', '']
    (directory/'report.md').write_text('\n'.join(lines));return directory/'report.md'


def render_correction(run_dir):
    summary=json.loads((run_dir/'summary.json').read_text())
    if not summary.get('complete'):return
    lines=['# 固定矩阵：LLM 纠错实测','',
        '英语为200条自定义pilot；中英混说为ASCEND的191条。两者均不是技术术语专项或盲测。候选表包含干扰项；错配表可能偶然包含正确词。', '',
        '| 英语条件 | WER | B-WER | U-WER | 变更句 | 改坏句 | 原本正确的128句中改坏 | fallback | 网络中位秒 |',
        '|---|---:|---:|---:|---:|---:|---:|---:|---:|']
    for condition in ['raw','plain','contextual','mismatched']:
        s=summary['conditions']['librispeech-'+condition];m=s['metrics'];d=s['paired_diagnostics']
        lines.append(f"| {condition} | {m['WER']['rate_percent']:.2f}% | {m['B-WER']['rate_percent']:.2f}% | {m['U-WER']['rate_percent']:.2f}% | {d.get('changed',0)} | {d.get('harmed',0)} | {d.get('previously_correct_harmed',0)} | {s['fallback_count']} | {s['latency_median_seconds']:.2f} |")
    lines+=['','| 中英混说条件 | 编辑数/2997（MER） | 变更句 | 改坏句 | 原本正确的42句中改坏 | fallback | 网络中位秒 |','|---|---:|---:|---:|---:|---:|---:|']
    for condition in ['raw','plain','static_tech']:
        if 'ascend-'+condition not in summary['conditions']:continue
        s=summary['conditions']['ascend-'+condition];m=s['metrics']['clean'];d=s['paired_diagnostics']
        lines.append(f"| {condition} | {m['edit_errors']}/{m['reference_units']} ({m['mer']:.2%}) | {d.get('changed',0)} | {d.get('harmed',0)} | {d.get('previously_correct_harmed',0)} | {s['fallback_count']} | {s['latency_median_seconds']:.2f} |")
    lines+=['','参考分母：英语总4449，B506，U3943；mixed2997。官方B/U使用冻结加权对齐；逐句改好/改坏使用单位编辑代价，口径分别保留。','',
            '正确词表带来专名收益，同时普通词仍可能受损；错配词表和无上下文LLM不是可靠默认增强。mixed上的退化表明该提示与服务组合不能直接作为通用语音纠错器，技术词表的效果需要有术语覆盖的专项数据。', '',
            '## 推理后词表覆盖','', '| 数据/条件 | 参考中至少命中一个候选的句数 | 稀有目标条目被候选表覆盖 |','|---|---:|---:|']
    for dataset,groups in summary.get('posthoc_coverage',{}).items():
        for c,s in groups.items():lines.append(f"| {dataset}/{c} | {s['sentences_with_candidate']}/{s['rows']} | {s['rare_targets_covered']}/{s['rare_target_entries']} |")
    lines+=['','稀有目标条目是逐句rare_words列表的计数，区别于官方B分母的词出现次数；ASCEND没有该稀有词标注。覆盖只在完成推理后计算，没有进入请求或修改候选表。','',
        '## 固定选例','', '以下每组按ID取前两个改坏句；展示风险，不能代表随机分布。','']
    diagnostics=read_rows(run_dir/'paired-diagnostics.jsonl')
    for dataset,condition in [('librispeech','contextual'),('librispeech','mismatched'),('ascend','plain'),('ascend','static_tech')]:
        for r in sorted((r for r in diagnostics if r['dataset']==dataset and r['condition']==condition and r['after_errors']>r['before_errors']),key=lambda r:r['id'])[:2]:
            lines += [f"- {dataset}/{condition} `{r['id']}`：{r['before_errors']}→{r['after_errors']} edits。原始：{r['original']}；纠错：{r['corrected']}；参考：{r['reference']}"]
    execution=json.loads((run_dir/'execution.json').read_text())
    lines+=['',f"本批请求{execution['requests']}次，服务报告{execution['reported_tokens']} tokens，usage缺失{execution['usage_missing']}次。模型为服务别名，不是固定权重快照。失败保留原文计分，不重试。网络耗时不等于ASR RTF或已确认落字的端到端时延。", '',
            '历史pilot单独保留；ardor→ardour一类收益含书写差异，不解释为声学理解。不能按本批错误继续逐句特判或刷提示。','']
    lines += ['推断限制：plain与有词表组的系统提示还相差固定CONTEXT后缀。英语正确/错配两组共享该后缀，能更直接比较候选表匹配性；mixed词表零命中时两组差异也可能来自提示后缀或服务波动，不能解释为技术词纠错收益。', '']
    if summary.get('cross_batch_history'):
        lines+=['','compact：plain/contextual来自历史400请求，mismatched来自本批200请求；跨批次服务别名可能漂移。mixed扩展not_run，本报告中相关分母/局限为full设计说明，不能视作compact实测。','']
    (run_dir/'analysis-source').mkdir(exist_ok=True)
    __import__('shutil').copyfile(Path(__file__),run_dir/'analysis-source/report.py')
    (run_dir/'report.md').write_text('\n'.join(lines))
