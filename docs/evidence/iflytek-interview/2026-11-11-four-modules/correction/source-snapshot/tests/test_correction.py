import json
import threading
import unittest
from tools.interview_bench.correction import build_conditions, payload, execute_tasks, completion


class CorrectionTests(unittest.TestCase):
    def test_secret_fields_excluded_and_mismatch_full_next_list(self):
        rows=[dict(id='b',asr_text='hello',candidates=['hello','b'],transcription='SECRET',rare_words=['SECRET']),dict(id='a',asr_text='a',candidates=['hello','a'],transcription='SECRET')]
        tasks=build_conditions(rows,[],'librispeech')
        self.assertNotIn('SECRET',json.dumps([payload(t) for t in tasks]))
        mismatch=next(t for t in tasks if t['id']=='a' and t['condition']=='mismatched')
        self.assertEqual(mismatch['candidates'],['hello','b'])
        self.assertEqual(set(mismatch),{'id','asr_text','condition','candidates','dataset'})

    def test_request_cap_token_stop_and_four_inflight(self):
        tasks=build_conditions([dict(id=str(i),asr_text='x',candidates=['y']) for i in range(20)],[],'librispeech')
        lock=threading.Lock();active=0;maximum=0
        def request(t):
            nonlocal active,maximum
            with lock:active+=1;maximum=max(active,maximum)
            result=dict(text='x',status='ok',usage={'total_tokens':100},latency_seconds=0)
            with lock:active-=1
            return result
        result,stats=execute_tasks(tasks,request,max_requests=3,max_reported_tokens=1000)
        self.assertEqual(stats['requests'],3);self.assertFalse(stats['complete']);self.assertLessEqual(maximum,4)
        result,stats=execute_tasks(tasks,request,max_requests=1000,max_reported_tokens=1)
        self.assertLessEqual(stats['requests'],4);self.assertFalse(stats['complete'])
        self.assertEqual(len(result),len(tasks))

    def test_empty_skips_and_failures_preserve_original(self):
        tasks=build_conditions([dict(id='a',asr_text='',candidates=[])],[],'ascend')
        def fail(t):raise AssertionError('must not call')
        result,stats=execute_tasks(tasks,fail)
        self.assertEqual(stats['requests'],0)
        self.assertTrue(all(r['status']=='baseline_empty' and r['text']=='' for r in result))
        for response in [None,{}, {'choices':[{'finish_reason':'length','message':{'content':'wrong'}}]}, {'choices':[{'finish_reason':'stop','message':{'content':''}}]}]:
            self.assertEqual(completion(response,' ORIGINAL ')['text'],' ORIGINAL ')
