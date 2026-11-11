"""Offline-only inference adapters. No implicit model downloads or fallback."""
import json
import os
import signal
from pathlib import Path
import select
import subprocess
import threading
import time
import uuid


def stop_process_tree(process):
    """Stop an owned session plus descendant sessions (e.g. time→Python→MLX)."""
    listing=subprocess.run(['ps','-Ao','pid=,ppid='],capture_output=True,text=True,check=True)
    parents=[tuple(map(int,line.split())) for line in listing.stdout.splitlines() if line.strip()]
    descendants={process.pid}
    while True:
        expanded=descendants|{pid for pid,parent in parents if parent in descendants}
        if expanded==descendants:break
        descendants=expanded
    groups={process.pid}
    for pid in descendants:
        try:groups.add(os.getpgid(pid))
        except ProcessLookupError:pass
    groups.discard(os.getpgrp())
    for sig in [signal.SIGTERM,signal.SIGKILL]:
        for group in groups:
            try:os.killpg(group,sig)
            except ProcessLookupError:pass
        if sig==signal.SIGTERM:
            try:process.wait(timeout=2)
            except subprocess.TimeoutExpired:pass
    process.wait()


class BackendError(RuntimeError):
    pass


def effective_prediction(id, model_id, audio_seconds, latency_seconds, text='', error=None):
    return dict(id=id, model_id=model_id, audio_seconds=audio_seconds,
                latency_seconds=latency_seconds, text=text if error is None else '',
                status='ok' if error is None else 'error',
                error_code=None if error is None else str(error).split(':')[0][:80])


class NativeWorker:
    def __init__(self, model_dir: Path, model_id: str, binary: Path, command=None, stderr=None, shutdown_timeout=30):
        self.model_dir, self.model_id, self.binary = model_dir, model_id, binary
        self.command = command
        self.stderr = stderr
        self.shutdown_timeout = shutdown_timeout
        self.lock = threading.Lock()
        self.process = None

    def _read(self):
        if not select.select([self.process.stdout], [], [], 300)[0]:
            raise BackendError('worker_timeout')
        line = self.process.stdout.readline()
        if not line:
            raise BackendError('worker_exit')
        try:
            return json.loads(line)
        except (ValueError, TypeError) as exc:
            raise BackendError('worker_invalid_json') from exc

    def start(self):
        if not (self.model_dir / 'config.json').is_file() or not self.binary.is_file():
            raise FileNotFoundError('Missing local model or worker')
        self.process = subprocess.Popen(self.command or [str(self.binary), str(self.model_dir), self.model_id],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.stderr, text=True, bufsize=1, start_new_session=True)
        try:
            ready = self._read()
            if ready.get('event') != 'ready' or ready.get('model_id') != self.model_id:
                raise BackendError('worker_identity_mismatch')
            return ready
        except BaseException:
            self.close()
            raise

    def transcribe(self, id: str, wav_path: Path):
        with self.lock:
            request_id = uuid.uuid4().hex
            request = dict(request_id=request_id, id=id, path=str(wav_path))
            try:
                self.process.stdin.write(json.dumps(request) + '\n')
                self.process.stdin.flush()
            except (OSError, ValueError, AttributeError) as exc:
                raise BackendError('worker_exit') from exc
            result = self._read()
            if result.get('id') != id or result.get('request_id') != request_id:
                raise BackendError('worker_response_mismatch')
            if result.get('model_id', self.model_id) != self.model_id:
                raise BackendError('worker_identity_mismatch')
            return result

    def close(self):
        if self.process is not None:
            if self.process.stdin:
                self.process.stdin.close()
            try:
                self.process.wait(timeout=self.shutdown_timeout)
            except subprocess.TimeoutExpired:
                stop_process_tree(self.process)
            self.process.stdout.close()


class WhisperBackend:
    def __init__(self, model_path: Path, threads=4):
        if not model_path.is_file():
            raise FileNotFoundError(model_path)
        import torch
        import whisper
        torch.set_num_threads(threads)
        start = time.monotonic()
        self.model = whisper.load_model(str(model_path), device='cpu')
        self.load_seconds = time.monotonic() - start

    def transcribe(self, id, wav_path):
        import soundfile as sf
        audio, rate = sf.read(str(wav_path), dtype='float32')
        if rate != 16000 or audio.ndim != 1 or not len(audio):
            raise BackendError('invalid_audio')
        start = time.monotonic()
        result = self.model.transcribe(audio, language=None, task='transcribe', temperature=0.0,
                                       condition_on_previous_text=False, fp16=False,
                                       initial_prompt=None, verbose=None)
        return effective_prediction(id, 'whisper-base', len(audio) / rate,
                                    time.monotonic() - start, text=result['text'].strip())

    def close(self):
        self.model = None
