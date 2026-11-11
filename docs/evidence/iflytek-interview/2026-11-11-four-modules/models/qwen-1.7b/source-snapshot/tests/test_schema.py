import json
from pathlib import Path
import tempfile
import unittest

from tools.interview_bench.schema import load_audio_inputs, validate_predictions, freeze_run


class SchemaTests(unittest.TestCase):
    def test_answers_and_duplicate_ids_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'inputs.jsonl'
            for rows in [[{'id': 'a', 'path': 'x', 'transcription': 'SECRET'}],
                         [{'id': 'a', 'path': 'x'}] * 2]:
                p.write_text(''.join(json.dumps(r) + '\n' for r in rows))
                with self.assertRaises(ValueError):
                    load_audio_inputs(p)

    def test_complete_failed_rows_count_but_missing_extra_duplicate_do_not(self):
        row = dict(id='a', model_id='m', text='', status='error', error_code='failed',
                   latency_seconds=1, audio_seconds=2)
        validate_predictions(['a'], [row])
        for rows in [[], [row, row], [dict(row, id='b')], [dict(row, latency_seconds=float('nan'))]]:
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                validate_predictions(['a'], rows)

    def test_freeze_is_immutable(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'input'; p.write_text('source')
            output = Path(tmp) / 'run'
            result = freeze_run({'model': 'm'}, p, output)
            self.assertEqual(result['config'], {'model': 'm'})
            self.assertTrue((output / 'protocol.json').exists())
            with self.assertRaises(FileExistsError):
                freeze_run({}, p, output)
