import unittest
import numpy as np
from tools.interview_bench.vad import Segmenter


class Prob:
    def __init__(self, value): self.value=value; self.resets=0
    def __call__(self, frame): return self.value
    def reset(self): self.resets+=1


class VADTests(unittest.TestCase):
    def test_short_eos_clamps_and_resets(self):
        model=Prob(.9);s=Segmenter(model)
        self.assertEqual(s.process(np.zeros(100,dtype='float32')),[])
        segments=s.flush()
        self.assertEqual((segments[0].end_sample,segments[0].reason),(100,'short_candidate'))
        s.reset();self.assertEqual(s.samples_seen,0);self.assertEqual(model.resets,2)

    def test_long_speech_no_gap_or_duplicate_padding(self):
        s=Segmenter(Prob(.9));events=[]
        for _ in range(700): events+=s.process(np.zeros(512,dtype='float32'))
        events+=s.flush()
        self.assertEqual(events[0].reason,'max_duration')
        self.assertEqual(events[0].start_sample,0)
        self.assertEqual(events[-1].end_sample,700*512)
        for a,b in zip(events,events[1:]): self.assertEqual(a.end_sample,b.start_sample)
        self.assertTrue(all(e.end_sample-e.start_sample<=160000 for e in events))

    def test_prefix_causality(self):
        class Energy(Prob):
            def __call__(self,frame): return .9 if np.max(frame)>.1 else .1
        prefix=np.r_[np.ones(16000),np.zeros(16000)].astype('float32')
        def run(tail):
            s=Segmenter(Energy(0));events=[]
            for frame in np.array_split(np.r_[prefix,tail],len(np.r_[prefix,tail])//512):
                events+=s.process(frame)
            return [e for e in events if e.decision_sample<=len(prefix)]
        self.assertEqual(run(np.zeros(32768)),run(np.ones(32768)))

    def test_padding_ownership(self):
        p=Prob(.9);s=Segmenter(p,silence_ms=300);events=[]
        for _ in range(10): events+=s.process(np.zeros(512,dtype='float32'))
        p.value=.1
        for _ in range(10): events+=s.process(np.zeros(512,dtype='float32'))
        p.value=.9
        for _ in range(10): events+=s.process(np.zeros(512,dtype='float32'))
        events+=s.flush()
        self.assertEqual(len(events),2)
        self.assertLessEqual(events[0].end_sample,events[1].start_sample)
