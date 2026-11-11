import unittest
from tools.interview_bench.prepare import select_vad, inference_rows, canonical_vocabulary


class PrepareTests(unittest.TestCase):
    def test_vad_balanced_repeatable_disjoint_and_independent_of_answers(self):
        refs = [{'id': f'{lang}-{i:03}', 'language': lang, 'transcription': 'SECRET'}
                for lang in ['zh', 'en', 'mixed'] for i in range(20)]
        result = select_vad(refs)
        self.assertEqual(len(result), 36)
        self.assertEqual(sum(r['split'] == 'dev' for r in result), 12)
        self.assertEqual(len({r['id'] for r in result}), 36)
        self.assertEqual(result, select_vad(list(reversed(refs))))
        self.assertNotIn('SECRET', str(result))
        self.assertEqual({l: sum(r['language'] == l for r in result) for l in ['zh', 'en', 'mixed']},
                         {'zh': 12, 'en': 12, 'mixed': 12})

    def test_inference_projection_and_dictionary_values_only(self):
        self.assertEqual(inference_rows([{'id': 'a', 'path': 'x', 'transcription': 'SECRET'}]),
                         [{'id': 'a', 'path': 'x'}])
        self.assertEqual(canonical_vocabulary({'wrong': 'PyTorch', 'other': 'PyTorch', 'x': 'API'}), ['API', 'PyTorch'])
