"""Describe frozen experiments without model/API calls. Run from any directory.

Usage: python3 analyze-retrospective.py <archived-regression-directory>
Output is adjacent to this script; all input hashes are retained.
"""
import collections
import hashlib
import json
from pathlib import Path
import sys


def main(regression):
    base = Path(__file__).resolve().parents[1]
    regression = Path(regression).resolve()
    inputs = {}

    def read(path, rows=False):
        path = path.resolve()
        raw = path.read_bytes()
        inputs[str(path.relative_to(base))] = hashlib.sha256(raw).hexdigest()
        return [json.loads(line) for line in raw.splitlines()] if rows else json.loads(raw)

    def indexed(rows):
        result = {r['id']: r for r in rows}
        assert len(result) == len(rows), 'duplicate IDs'
        return result

    def edits(row):
        return sum(row[k] for k in ('substitutions', 'deletions', 'insertions'))

    def count_group(rows):
        errors = sum(edits(r) for r in rows)
        units = sum(r['reference_units'] for r in rows)
        return dict(rows=len(rows), edits=errors, units=units, mer=errors/units)

    refs = indexed(read(base/'prepared/ascend/references.jsonl', True))
    models, details = {}, {}
    for model in ('qwen-1.7b', 'qwen-0.6b', 'whisper-base'):
        rows = read(base/'models'/model/'scored_rows.jsonl', True)
        assert indexed(rows).keys() == refs.keys() and len(rows) == 1130
        clean = [r for r in rows if not r['unknown_reference']]
        aggregate = count_group(clean)
        summary = read(base/'models'/model/'summary.json')
        assert aggregate['edits'] == summary['clean']['edit_errors']
        assert aggregate['units'] == summary['clean']['reference_units']
        models[model] = dict(
            clean=aggregate,
            by_speaker={str(s): count_group([r for r in clean if r['original_speaker_id'] == s])
                        for s in sorted({r['original_speaker_id'] for r in clean})},
            by_language={s: count_group([r for r in clean if r['language'] == s])
                         for s in sorted({r['language'] for r in clean})})
        details[model] = indexed(clean)
    pairs = collections.Counter()
    for id, row in details['qwen-1.7b'].items():
        a, b = edits(row), edits(details['qwen-0.6b'][id])
        pairs['1.7b_fewer_edits' if a < b else '0.6b_fewer_edits' if b < a else 'equal_edits'] += 1

    correction = read(base/'correction/paired-diagnostics.jsonl', True)
    correction_summary = read(base/'correction/summary.json')
    corrections = {}
    for dataset, condition in sorted({(r['dataset'], r['condition']) for r in correction}):
        rows = [r for r in correction if (r['dataset'], r['condition']) == (dataset, condition)]
        indexed(rows)
        counts = dict(rows=len(rows),
                      improved=sum(r['after_errors'] < r['before_errors'] for r in rows),
                      harmed=sum(r['after_errors'] > r['before_errors'] for r in rows),
                      equal_edits=sum(r['after_errors'] == r['before_errors'] for r in rows),
                      previously_correct_harmed=sum(r['before_errors'] == 0 and r['after_errors'] > 0 for r in rows))
        frozen = correction_summary['conditions'][dataset+'-'+condition]['paired_diagnostics']
        for k in ('improved', 'harmed', 'previously_correct_harmed'):
            assert counts[k] == frozen.get(k, 0)
        corrections[dataset+'-'+condition] = counts

    old = base/'replay/eval'
    old_summary, new_summary = read(old/'summary.json'), read(regression/'summary.json')
    old_protocol, new_protocol = read(old/'protocol.json'), read(regression/'protocol.json')
    assert old_protocol['config'] == new_protocol['config']
    assert old_protocol['input_sha256'] == new_protocol['input_sha256']
    sessions = read(old/'sessions.json')
    assert sessions == read(regression/'sessions.json')
    expected_ids = {r['id'] for r in sessions}
    assert len(expected_ids) == 6
    replays = {}
    for strategy in ('whole', 'fixed5', 'vad600'):
        old_predictions = indexed(read(old/strategy/'predictions.jsonl', True))
        new_predictions = indexed(read(regression/strategy/'predictions.jsonl', True))
        old_scored = indexed(read(old/strategy/'scored_rows.jsonl', True))
        new_scored = indexed(read(regression/strategy/'scored_rows.jsonl', True))
        assert old_predictions.keys() == new_predictions.keys() == expected_ids
        assert old_scored.keys() == new_scored.keys() == expected_ids
        timing = []
        for id in sorted(expected_ids):
            before, after = read(old/strategy/(id+'.json')), read(regression/strategy/(id+'.json'))
            assert before['status'] == after['status'] == 'ok'
            assert after['text'] == new_predictions[id]['text']
            assert before['text'] == old_predictions[id]['text']
            assert after['endpoint_latency_seconds'] is None and after['final_from_speech_seconds'] is None
            timing.append(dict(id=id, text_changed=before['text'] != after['text'],
                               old_edits=edits(old_scored[id]), new_edits=edits(new_scored[id]),
                               first_result_seconds=after['first_result_seconds'],
                               final_result_seconds=after['final_result_seconds'],
                               first_result_delta_seconds=after['first_result_seconds']-before['first_result_seconds'],
                               final_result_delta_seconds=after['final_result_seconds']-before['final_result_seconds']))
        aggregate = count_group(list(new_scored.values()))
        assert aggregate['edits'] == new_summary[strategy]['clean']['edit_errors']
        assert aggregate['units'] == new_summary[strategy]['clean']['reference_units'] == 235
        replays[strategy] = dict(old_clean=old_summary[strategy]['clean'], new_clean=aggregate,
                                changed_text_rows=sum(r['text_changed'] for r in timing), sessions=timing)

    output = dict(
        scope='Posthoc descriptive audit, not a new algorithm evaluation or a significance test.',
        speaker_rows=dict(collections.Counter(str(r['original_speaker_id']) for r in refs.values())),
        models=models, qwen_paired_clean_rows=dict(pairs), correction=corrections,
        replay_regression=replays, input_sha256=inputs,
        script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    (base/'audit/retrospective-analysis.json').write_text(json.dumps(output, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps(dict(speakers=output['speaker_rows'], qwen_pairs=dict(pairs),
                          replay={k: dict(edits=v['new_clean']['edits'], changed=v['changed_text_rows'])
                                  for k, v in replays.items()}), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main(sys.argv[1])
