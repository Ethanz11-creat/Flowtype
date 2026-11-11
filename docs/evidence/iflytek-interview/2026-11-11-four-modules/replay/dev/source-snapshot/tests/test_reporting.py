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


class VerificationTests(unittest.TestCase):
    def test_empty_root_never_passes_full_or_compact(self):
        from tools.interview_bench.verify import verify
        with tempfile.TemporaryDirectory() as d:
            for profile in ['full','compact']:
                result=verify(Path(d),profile)
                self.assertNotEqual(result['status'],'passed')
                self.assertEqual(result['checks']['human_boundaries']['status'],'manual_pending')
                self.assertEqual(result['checks']['microphone_demo']['status'],'manual_pending')
                self.assertEqual(result['checks']['model-qwen-1.7b']['status'],'not_run')

    def test_missing_manifest_or_tamper_is_failed(self):
        from tools.interview_bench.verify import verify_prepared
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); (root/'prepared').mkdir()
            write_json(root/'prepared/manifest.json',{'datasets':{'ascend':{'rows':1,'input_sha256':'WRONG'}}})
            result=verify_prepared(root)
            self.assertEqual(result['status'],'failed')

    def test_correction_requires_every_fixed_condition(self):
        from tools.interview_bench.verify import validate_correction_matrix
        tasks=[dict(dataset='librispeech',id=str(i),condition='plain') for i in range(982)]
        with self.assertRaises(ValueError): validate_correction_matrix(tasks,tasks)

    def test_tampered_frozen_source_is_rejected(self):
        from tools.interview_bench.schema import freeze_run
        from tools.interview_bench.verify import validate_frozen_sources
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);inputs=root/'input';inputs.write_text('input')
            run=root/'run';freeze_run({},inputs,run)
            validate_frozen_sources(run)
            (run/'source-snapshot/backends.py').write_text('changed')
            with self.assertRaises(ValueError):validate_frozen_sources(run)

    def test_dispatch_only_never_passes_manual_insertion_check(self):
        from tools.interview_bench.verify import verify_manual
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            observations=[dict(kind=k,observer='test-fixture-human',observed_at_utc='2026-11-11T00:00:00+00:00',
                               target_app='TextEdit',spoken_text='test',observed_text='test',confirmed_inserted=True)
                          for k in ['short','mixed','technical']]
            write_json(root/'manual-demonstrations.json',dict(microphone=dict(status='confirmed',observations=observations)))
            self.assertEqual(verify_manual(root)['microphone_demo']['status'],'passed')
            for r in observations:r.pop('observed_text');r['dispatch_sent']=True
            write_json(root/'manual-demonstrations.json',dict(microphone=dict(status='confirmed',observations=observations)))
            self.assertEqual(verify_manual(root)['microphone_demo']['status'],'failed')
            self.assertEqual(verify_manual(root)['recorded_replay_demo']['status'],'manual_pending')

    def test_manual_record_wrong_json_type_is_failed(self):
        from tools.interview_bench.verify import verify_manual
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);write_json(root/'manual-demonstrations.json',[])
            self.assertEqual(verify_manual(root)['microphone_demo']['status'],'failed')
