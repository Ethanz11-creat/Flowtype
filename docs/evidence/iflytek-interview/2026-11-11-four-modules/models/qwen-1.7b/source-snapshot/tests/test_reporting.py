import json
from pathlib import Path
import tempfile
import unittest
from tools.interview_bench.schema import write_json, write_rows
from tools.interview_bench.report import score_model_run, render_model_comparison


class ReportingTests(unittest.TestCase):
    def fixture(self, root):
        refs = [dict(id=str(i), transcription=t, language='mixed',topic='x',original_speaker_id='1')
                for i,t in enumerate(['你 hello','[UNK]','好'])]
        write_rows(root/'refs.jsonl',refs)
        run=root/'run';run.mkdir()
        write_rows(run/'predictions.jsonl',[dict(id=r['id'],model_id='m',text=r['transcription'],status='ok',error_code=None,audio_seconds=1,latency_seconds=.1) for r in refs])
        write_json(run/'protocol.json',{'config':{'model_id':'m','deployment':dict(engine='MLX',dtype='4bit',quantization='4bit',device='Metal',build_mode='debug')}})
        write_json(run/'timing.json',dict(load_seconds=1,warmup_seconds=1,batch_wall_seconds=1))
        write_json(run/'resource.json',dict(maximum_resident_set_size_bytes=123,scope='worker'))
        return run, root/'refs.jsonl'

    def test_missing_prediction_never_produces_complete_report(self):
        with tempfile.TemporaryDirectory() as d:
            run,refs=self.fixture(Path(d))
            rows=[json.loads(x) for x in (run/'predictions.jsonl').read_text().splitlines()]
            write_rows(run/'predictions.jsonl',rows[:-1])
            with self.assertRaises(ValueError): score_model_run(run,refs)

    def test_unknown_excluded_and_deployment_always_visible(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);run,refs=self.fixture(root)
            result=score_model_run(run,refs)
            self.assertEqual(result['clean']['reference_units'],3)
            self.assertEqual(result['unknown_reference_rows'],1)
            render_model_comparison([run],root/'report.md')
            text=(root/'report.md').read_text()
            for word in ['MLX','4bit','Metal','debug','RSS']: self.assertIn(word,text)
