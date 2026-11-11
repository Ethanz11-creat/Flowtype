"""Causal 512-sample segmentation; intervals own samples at most once."""
from dataclasses import dataclass
import numpy as np


@dataclass(frozen=True)
class SpeechSegment:
    start_sample: int
    end_sample: int
    decision_sample: int
    reason: str


class Silero:
    def __init__(self, path):
        import torch
        torch.set_num_threads(1)
        self.torch=torch
        self.model=torch.jit.load(str(path),map_location='cpu').eval()
        self.reset()
    def reset(self): self.model.reset_states()
    def __call__(self, frame):
        with self.torch.inference_mode():
            return float(self.model(self.torch.from_numpy(frame.copy()),16000).item())


class Segmenter:
    def __init__(self, model, silence_ms=600):
        self.model=model;self.silence=int(silence_ms*16)
        self.pre=2560;self.post=1600;self.maximum=160000
        self.reset()
    def reset(self):
        self.model.reset();self.samples_seen=0;self.processed=0
        self.pending=np.empty(0,dtype='float32');self.start=None;self.last_speech=0
        self.speech_samples=0;self.owned_end=0
    def _frame(self, frame, valid):
        begin=self.processed;end=begin+valid;self.processed=end
        probability=self.model(frame)
        events=[]
        if self.start is None and probability>=.5:
            self.start=max(self.owned_end,begin-self.pre);self.speech_samples=0
        if self.start is not None:
            if probability>=.35:
                self.last_speech=end;self.speech_samples+=valid
            while end-self.start>=self.maximum:
                cut=self.start+self.maximum
                events.append(SpeechSegment(self.start,cut,end,'max_duration'))
                self.owned_end=cut;self.start=cut
            if end-self.last_speech>=self.silence:
                cut=min(end,self.last_speech+self.post)
                if cut>self.start:
                    events.append(SpeechSegment(self.start,cut,end,'endpoint' if self.speech_samples>=1536 else 'short_candidate'))
                    self.owned_end=cut
                self.start=None;self.speech_samples=0
        return events
    def process(self, samples):
        samples=np.asarray(samples,dtype='float32')
        if samples.ndim!=1 or not np.isfinite(samples).all(): raise ValueError('Invalid mono PCM')
        self.samples_seen+=len(samples);self.pending=np.r_[self.pending,samples]
        events=[]
        while len(self.pending)>=512:
            events+=self._frame(self.pending[:512],512);self.pending=self.pending[512:]
        return events
    def flush(self):
        events=[]
        if len(self.pending):
            n=len(self.pending);events+=self._frame(np.pad(self.pending,(0,512-n)),n)
            self.pending=np.empty(0,dtype='float32')
        if self.start is not None:
            end=min(self.samples_seen,self.last_speech+self.post)
            if end>self.start:
                events.append(SpeechSegment(self.start,end,self.samples_seen,'eos' if self.speech_samples>=1536 else 'short_candidate'))
                self.owned_end=end
            self.start=None
        return events


class FixedSegmenter:
    def __init__(self, samples=None): self.limit=samples;self.samples_seen=0;self.start=0
    def process(self,samples):
        self.samples_seen+=len(samples);events=[]
        if self.limit:
            while self.samples_seen-self.start>=self.limit:
                end=self.start+self.limit;events.append(SpeechSegment(self.start,end,self.samples_seen,'max_duration'));self.start=end
        return events
    def flush(self):
        if self.samples_seen<=self.start:return []
        result=[SpeechSegment(self.start,self.samples_seen,self.samples_seen,'eos')];self.start=self.samples_seen
        return result
