import dataclasses
import unittest

from stt_service.cleanup import (
    apply_replacements,
    cleanup_request,
    cleanup_transcript,
    drifted,
    strip_wrapping,
)
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

    def test_system_prompt_lists_pairs_and_transcript_is_tagged(self):
        cfg = dataclasses.replace(self.cfg, replacements=(("em el ex", "MLX"),))
        messages = cleanup_request("use MLX", cfg)["messages"]
        self.assertEqual(messages[0]["role"], "system")
        self.assertIn("em el ex -> MLX", messages[0]["content"])
        self.assertIn("Do not revert them", messages[0]["content"])
        self.assertEqual(messages[-1], {"role": "user", "content": "<transcript>\nuse MLX\n</transcript>"})

    def test_request_omits_reasoning_for_the_dedicated_model(self):
        body = cleanup_request("hello", self.cfg)
        self.assertNotIn("reasoning_effort", body)
        self.assertEqual(body["model"], "cleanup")
        self.assertIn("hello", body["messages"][-1]["content"])

    def test_llm_text_is_used(self):
        def post(url, json, timeout):
            self.assertTrue(url.endswith("/chat/completions"))
            self.assertEqual(timeout, 60)
            return FakeResponse({"choices": [{"message": {"content": "Hello."}}]})

        text, used = cleanup_transcript("hello", self.cfg, post=post)
        self.assertEqual(text, "Hello.")
        self.assertTrue(used)

    def reply(self, content):
        def post(url, json, timeout):
            return FakeResponse({"choices": [{"message": {"content": content}}]})

        return post

    # The leak cases below are model replies taken from the stt-debug log.
    def test_preamble_and_quotes_are_stripped(self):
        source = "Can you explain to me the purpose of ViviChat?"
        content = 'Sure, I can help with that. Here\'s the cleaned transcript:\n\n"Can you explain to me the purpose of ViviChat?"'
        text, used = cleanup_transcript(source, self.cfg, post=self.reply(content))
        self.assertEqual(text, source)
        self.assertTrue(used)

    def test_preamble_variants_are_stripped(self):
        for preamble in ("Sure, here is the cleaned transcript:", "Sure! Here is the cleaned transcript:"):
            self.assertEqual(strip_wrapping(f"{preamble}\n\nStop here."), "Stop here.")

    def test_spoken_sure_is_kept(self):
        self.assertEqual(strip_wrapping("Sure, that works for me."), "Sure, that works for me.")

    def test_reply_instead_of_transcript_falls_back(self):
        source = "Can you run the polish analyzer on Radix, please?"
        content = "Sure, I can help with that. Please provide the speech-to-text transcript you want me to clean."
        text, used = cleanup_transcript(source, self.cfg, post=self.reply(content))
        self.assertEqual(text, source)
        self.assertFalse(used)

    def test_drift_allows_normal_cleanup(self):
        self.assertFalse(drifted("um so uh can you you know fix the the build", "So can you fix the build?"))
        self.assertTrue(drifted("fix the build", "Here is a poem about the sea and the sky."))

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

    def test_disabled_cleanup_skips_the_model(self):
        def post(url, json, timeout):
            raise AssertionError("model should not be called")

        cfg = dataclasses.replace(self.cfg, cleanup_enabled=False)
        text, used = cleanup_transcript("hello there", cfg, post=post)
        self.assertEqual(text, "hello there")
        self.assertFalse(used)

    def test_blank_transcript_skips_the_model(self):
        def post(url, json, timeout):
            raise AssertionError("model should not be called")

        text, used = cleanup_transcript("   ", self.cfg, post=post)
        self.assertEqual(text, "")
        self.assertFalse(used)


if __name__ == "__main__":
    unittest.main()
