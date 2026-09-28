import unittest

from stt_service.cleanup import apply_replacements, cleanup_prompt, cleanup_request, cleanup_transcript
from stt_service.config import load_config

ROOT_EXAMPLE = __import__("pathlib").Path(__file__).resolve().parents[1] / "config.example.toml"


class FakeResponse:
    def __init__(self, payload=None, fail=False):
        self.payload = payload
        self.fail = fail

    def raise_for_status(self):
        if self.fail:
            raise OSError("splash down")

    def json(self):
        return self.payload


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.cfg = load_config(ROOT_EXAMPLE)

    def test_word_boundary_and_longer_phrase_first(self):
        pairs = (("cat", "dog"), ("Faber", "FABER"), ("Faber Lang", "FaberLang"))
        text = apply_replacements("Faber Lang wrote a cat catalog", pairs)
        self.assertEqual(text, "FaberLang wrote a dog catalog")

    def test_phrase_replace_is_literal(self):
        text = apply_replacements("use em el ex today", (("em el ex", "MLX"),))
        self.assertEqual(text, "use MLX today")

    def test_prompt_lists_pairs_and_transcript(self):
        prompt = cleanup_prompt("use MLX", (("em el ex", "MLX"),))
        self.assertIn("em el ex -> MLX", prompt)
        self.assertIn("use MLX", prompt)
        self.assertIn("Do not revert them", prompt)

    def test_request_omits_reasoning_for_the_dedicated_model(self):
        body = cleanup_request("hello", self.cfg)
        self.assertNotIn("reasoning_effort", body)
        self.assertEqual(body["model"], "qwen2.5-1.5b-instruct")
        self.assertIn("hello", body["messages"][0]["content"])

    def test_llm_text_is_used(self):
        def post(url, json, timeout):
            self.assertTrue(url.endswith("/chat/completions"))
            self.assertEqual(timeout, 60)
            return FakeResponse({"choices": [{"message": {"content": "Hello."}}]})

        text, used = cleanup_transcript("hello", self.cfg, post=post)
        self.assertEqual(text, "Hello.")
        self.assertTrue(used)

    def test_empty_content_falls_back(self):
        def post(url, json, timeout):
            return FakeResponse({"choices": [{"message": {"content": None}}]})

        text, used = cleanup_transcript("hello", self.cfg, post=post)
        self.assertEqual(text, "hello")
        self.assertFalse(used)

    def test_network_error_falls_back(self):
        def post(url, json, timeout):
            raise OSError("connection refused")

        text, used = cleanup_transcript("hello", self.cfg, post=post)
        self.assertEqual(text, "hello")
        self.assertFalse(used)

    def test_blank_transcript_skips_the_model(self):
        def post(url, json, timeout):
            raise AssertionError("model should not be called")

        text, used = cleanup_transcript("   ", self.cfg, post=post)
        self.assertEqual(text, "")
        self.assertFalse(used)


if __name__ == "__main__":
    unittest.main()
