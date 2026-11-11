"""Checks against reference leakage, broken responses and incomplete inputs."""
import unittest

from run_contextual_asr_correction import make_inputs, messages, parse_completion
from score_contextual_asr_correction import validate_completions


class CorrectionTests(unittest.TestCase):
    def test_only_full_candidate_list_enters_inference(self):
        refs = [{"id": "a", "transcription": "SECRET ANSWER", "rare_words": ["SECRET"],
                 "biasing_words": ["target", "distractor"]}]
        rows = make_inputs([{"id": "a", "text": "raw speech", "status": "ok"}], refs)
        self.assertEqual(rows, [{"id": "a", "asr_text": "raw speech", "candidates": ["target", "distractor"]}])
        self.assertNotIn("SECRET", str(messages(rows[0], "contextual")))
        self.assertIn("distractor", str(messages(rows[0], "contextual")))
        self.assertNotIn("distractor", str(messages(rows[0], "plain")))

    def test_missing_extra_duplicate_or_failed_inputs_rejected(self):
        refs = [{"id": "a", "biasing_words": ["word"]}]
        p = {"id": "a", "text": "raw", "status": "ok"}
        for preds in [[], [p, p], [dict(p, id="b")], [dict(p, status="error")]]:
            with self.subTest(preds=preds), self.assertRaises(ValueError):
                make_inputs(preds, refs)
        with self.assertRaises(ValueError):
            make_inputs([p], refs + refs)

    def test_valid_completion_preserves_text_and_usage(self):
        result = parse_completion({"model": "served", "usage": {"total_tokens": 20}, "choices": [
            {"finish_reason": "stop", "message": {"content": "  corrected text  "}}]}, "raw")
        self.assertEqual(result["text"], "corrected text")
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["usage"]["total_tokens"], 20)

    def test_truncated_empty_and_invalid_response_keep_original(self):
        cases = [{}, {"error": {"message": "private server diagnostic"}},
                 {"choices": [{"finish_reason": "length", "message": {"content": "partial"}}]},
                 {"choices": [{"finish_reason": "stop", "message": {"content": "  "}}]}]
        for response in cases:
            with self.subTest(response=response):
                out = parse_completion(response, "original")
                self.assertEqual(out["text"], "original")
                self.assertEqual(out["status"], "fallback")
                self.assertNotIn("private", str(out))

    def test_partial_pairs_and_modified_fallback_cannot_be_scored(self):
        inputs = [{"id": "a", "asr_text": "original"}]
        plain = {"id": "a", "condition": "plain", "text": "original", "status": "fallback"}
        contextual = dict(plain, condition="contextual", status="ok", text="corrected")
        validate_completions(inputs, [plain, contextual])
        for rows in [[plain], [plain, contextual, plain], [dict(plain, text="modified"), contextual]]:
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                validate_completions(inputs, rows)


if __name__ == "__main__":
    unittest.main()
