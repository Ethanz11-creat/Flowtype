from pathlib import Path
import tempfile
import threading
import time
import unittest
import numpy as np
import soundfile as sf
from tools.interview_bench.replay import run_replay, endpoint_latency
from tools.interview_bench.vad import SpeechSegment


class FakeClock:
    def __init__(self): self.t=0;self.delivered=[]
    def now(self): return self.t
    def wait_until(self,t): self.t=max(t,self.t);self.delivered.append(t)


class Cuts:
    def __init__(self): self.samples_seen=0
    def process(self, samples):
        begin=self.samples_seen;self.samples_seen+=len(samples)
        return [SpeechSegment(begin,self.samples_seen,self.samples_seen,'endpoint')]
    def flush(self): return []


class ReplayTests(unittest.TestCase):
    def test_slow_asr_does_not_pause_clock_and_fifth_pending_fails(self):
        class Worker:
            def transcribe(self,id,path): time.sleep(.05);return dict(text='a',status='ok')
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'a.wav';sf.write(p,np.zeros(512*20),16000,subtype='PCM_16')
            clock=FakeClock();result=run_replay(p,Cuts(),Worker(),clock)
            self.assertEqual(result['status'],'failed')
            self.assertEqual(result['error_code'],'queue_overflow')
            self.assertGreater(len(clock.delivered),4)
            self.assertTrue(any(r['wait_seconds']>0 for r in result['segments']))
            self.assertLess(clock.now(),.64)
            self.assertTrue(all(not t.name.startswith('asr-replay') for t in threading.enumerate()))

    def test_early_endpoint_is_negative(self):
        self.assertLess(endpoint_latency(100,120,16000),0)

    def test_no_human_annotation_has_null_endpoint(self):
        class Worker:
            def transcribe(self,id,path): return dict(text='a',status='ok')
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'a.wav';sf.write(p,np.zeros(100),16000,subtype='PCM_16')
            result=run_replay(p,Cuts(),Worker(),FakeClock())
            self.assertIsNone(result['endpoint_latency_seconds'])
            self.assertEqual(result['annotation_status'],'manual_pending')

    def test_cancellation_waits_for_current_compute(self):
        started=threading.Event();finished=threading.Event();cancel=threading.Event()
        class Worker:
            def transcribe(self,id,path):
                started.set();time.sleep(.06);finished.set();return dict(text='a',status='ok')
        class CancelClock(FakeClock):
            def wait_until(self,t):
                super().wait_until(t)
                if len(self.delivered)==2:
                    started.wait(1);cancel.set()
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'a.wav';sf.write(p,np.zeros(512*20),16000,subtype='PCM_16')
            clock=CancelClock();result=run_replay(p,Cuts(),Worker(),clock,cancel)
            self.assertEqual(result['error_code'],'cancelled')
            self.assertTrue(finished.is_set())
            self.assertEqual(len(clock.delivered),2)

    def test_first_text_skips_successful_empty_segment(self):
        clock=FakeClock()
        class Worker:
            calls=0
            def transcribe(self,id,path):
                self.calls+=1;clock.t+=1
                return dict(text='' if self.calls==1 else 'hello',status='ok')
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'a.wav';sf.write(p,np.zeros(1024),16000,subtype='PCM_16')
            result=run_replay(p,Cuts(),Worker(),clock)
            self.assertEqual(result['first_result_seconds'],result['segments'][1]['returned_seconds'])

    def test_endpoint_uses_actual_decision_event_time(self):
        from tools.interview_bench.replay import score_endpoints
        result=dict(segments=[dict(start_sample=0,end_sample=200,decision_sample=512,decision_seconds=1.1)],final_result_seconds=2)
        session=dict(sources=[dict(id='a',offset_sample=0)])
        annotations=[dict(id='a',status='confirmed',annotator='human',spans=[dict(start_sample=0,end_sample=16000)])]
        score_endpoints(result,session,annotations)
        self.assertAlmostEqual(result['endpoint_latency_seconds'][0],.1)
        self.assertEqual(result['segments'][0]['speech_end_sample'],16000)

    def test_audio_write_failure_is_a_failed_segment(self):
        from unittest.mock import patch
        class Worker:
            def transcribe(self,id,path):raise AssertionError('ASR must not run after write failure')
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'input.wav';sf.write(path,np.zeros(100),16000)
            with patch('tools.interview_bench.replay.sf.write',side_effect=OSError('disk full')):
                result=run_replay(path,Cuts(),Worker(),FakeClock())
            self.assertEqual(result['status'],'failed')
            self.assertEqual(result['error_code'],'audio_write_error')
            self.assertEqual(result['segments'][0]['status'],'error')
            self.assertEqual(result['segments'][0]['error_code'],'audio_write_error')

    def test_audio_write_failure_with_full_queue_shuts_down(self):
        import subprocess,sys,textwrap
        script=textwrap.dedent("""
            import tempfile,threading,json
            from pathlib import Path
            from unittest.mock import patch
            import numpy as np
            import soundfile as sf
            from tools.interview_bench.replay import run_replay
            from tools.interview_bench.tests.test_replay import Cuts,FakeClock
            entered=threading.Event();release=threading.Event()
            class Clock(FakeClock):
                def wait_until(self,t):
                    super().wait_until(t)
                    if len(self.delivered)==2:assert entered.wait(1)
                    if len(self.delivered)==6:release.set()
            class Worker:
                def transcribe(self,*args):raise AssertionError('unexpected ASR')
            def fail(*args,**kwargs):
                entered.set();assert release.wait(1);raise OSError('disk full')
            with tempfile.TemporaryDirectory() as d:
                path=Path(d)/'input.wav';sf.write(path,np.zeros(512*20),16000)
                with patch('tools.interview_bench.replay.sf.write',side_effect=fail):
                    result=run_replay(path,Cuts(),Worker(),Clock())
                assert result['status']=='failed'
                assert any(r['error_code']=='audio_write_error' for r in result['segments'])
                assert not any(t.name=='asr-replay-worker' for t in threading.enumerate())
                print('clean shutdown')
        """)
        result=subprocess.run([sys.executable,'-B','-c',script],capture_output=True,text=True,timeout=4)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('clean shutdown',result.stdout)
