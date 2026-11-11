"""Research metric checks: known edit counts, weighting and missing-data handling."""
import unittest

from score_asr_baseline import mixed_tokens, evaluate


def ref(sid, text, language="mixed"):
    return {"id": sid, "transcription": text, "language": language, "topic": "fixture", "original_speaker_id": 1}


def pred(sid, text, status="ok"):
    return {"id": sid, "text": text, "status": status, "latency_seconds": 1, "audio_seconds": 2}


class MetricsTests(unittest.TestCase):
    def test_mixed_units_and_punctuation(self):
        self.assertEqual(mixed_tokens("我用PyTorch，batch-size是１.７B。I’m ready!"),
                         ["我", "用", "pytorch", "batch", "size", "是", "1", "7", "b", "i'm", "ready"])

    def test_micro_average_not_sentence_average(self):
        s, _ = evaluate([ref("a", "甲"), ref("b", "甲乙丙")], [pred("a", "乙"), pred("b", "甲乙丙")])
        self.assertEqual(s["clean"]["reference_units"], 4)
        self.assertEqual(s["clean"]["mer"], 0.25)

    def test_known_substitution_and_insertion(self):
        s, _ = evaluate([ref("a", "甲乙go")], [pred("a", "甲丙go fast")])
        self.assertEqual([s["clean"][k] for k in ["substitutions", "deletions", "insertions"]], [1, 0, 1])
        self.assertAlmostEqual(s["clean"]["mer"], 2 / 3)

    def test_failure_is_scored_as_deletions(self):
        s, _ = evaluate([ref("a", "甲乙")], [pred("a", "", "error")])
        self.assertEqual(s["clean"]["deletions"], 2)
        self.assertEqual(s["clean"]["mer"], 1)
        self.assertEqual(s["failure_count"], 1)

    def test_unknown_refs_are_explicitly_diagnostic(self):
        s, rows = evaluate([ref("a", "甲[UNK]乙"), ref("b", "丙")], [pred("a", "胡乱输出"), pred("b", "丙")])
        self.assertEqual((s["rows"], s["unknown_reference_rows"], s["clean"]["rows"]), (2, 1, 1))
        self.assertIsNone(rows[0]["mer"])

    def test_incomplete_extra_and_duplicate_outputs_are_rejected(self):
        for outputs in [[], [pred("a", "甲"), pred("b", "乙")], [pred("a", "甲"), pred("a", "甲")]]:
            with self.subTest(outputs=outputs), self.assertRaises(ValueError):
                evaluate([ref("a", "甲")], outputs)

    def test_empty_output_still_has_full_reference_denominator(self):
        s, _ = evaluate([ref("a", "hello world", "en")], [pred("a", "")])
        self.assertEqual((s["empty_output_count"], s["clean"]["reference_units"], s["clean"]["mer"]), (1, 2, 1))


if __name__ == "__main__":
    unittest.main()
