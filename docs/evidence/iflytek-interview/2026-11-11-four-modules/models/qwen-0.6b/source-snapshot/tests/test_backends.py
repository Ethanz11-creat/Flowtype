from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from tools.interview_bench.backends import NativeWorker, WhisperBackend, BackendError, effective_prediction


class BackendTests(unittest.TestCase):
    def test_missing_weights_never_download(self):
        with patch('urllib.request.urlopen') as network:
            with self.assertRaises(FileNotFoundError):
                WhisperBackend(Path('/nonexistent/whisper.pt'))
            with self.assertRaises(FileNotFoundError):
                NativeWorker(Path('/nonexistent/model'), 'm', Path('/missing')).start()
            network.assert_not_called()

    def test_serial_requests_id_validation_and_close(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root / 'config.json').write_text('{}')
            script = root / 'worker.py'
            script.write_text('''import json,sys,time
print(json.dumps({'event':'ready','model_id':'m','load_seconds':0}),flush=True)
for line in sys.stdin:
 r=json.loads(line);time.sleep(.01)
 print(json.dumps(dict(r,text='hello',status='ok',latency_seconds=.01,audio_seconds=1)),flush=True)
''')
            worker = NativeWorker(root, 'm', script, command=[sys.executable, str(script)])
            worker.start()
            with ThreadPoolExecutor(2) as pool:
                results = list(pool.map(lambda n: worker.transcribe(str(n), root / 'x.wav'), range(6)))
            self.assertEqual([r['id'] for r in results], [str(i) for i in range(6)])
            worker.close(); self.assertIsNotNone(worker.process.poll())

    def test_bad_json_id_and_dead_worker_are_errors(self):
        for reply in ['not-json', '{"id":"WRONG","request_id":"WRONG"}', '']:
            with self.subTest(reply=reply), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); (root / 'config.json').write_text('{}')
                script = root / 'worker.py'
                script.write_text("import sys,json\nprint(json.dumps({'event':'ready','model_id':'m','load_seconds':0}),flush=True)\nsys.stdin.readline()\nprint(" + repr(reply) + ",flush=True)\n")
                worker = NativeWorker(root, 'm', script, command=[sys.executable, str(script)])
                worker.start()
                try:
                    with self.assertRaises(BackendError):
                        worker.transcribe('a', root / 'x')
                finally:
                    worker.close()

    def test_error_is_explicit_empty_and_retains_audio_denominator(self):
        result = effective_prediction('a', 'm', 2.0, 1.0, error=BackendError('worker_exit'))
        self.assertEqual((result['id'], result['text'], result['status'], result['audio_seconds']), ('a', '', 'error', 2.0))
