import dataclasses
import unittest

from stt_service.cleanup import (
    apply_replacements,
    chunks,
    cleanup_messages,
    cleanup_transcript,
    drifted,
    server_completer,
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
        self.server = dataclasses.replace(
            self.cfg, cleanup_model="", cleanup_url="http://127.0.0.1:1234/v1", cleanup_name="qwen"
        )

    def test_word_boundary_and_longer_phrase_first(self):
        pairs = (("cat", "dog"), ("Faber", "FABER"), ("Faber Lang", "FaberLang"))
        text = apply_replacements("Faber Lang wrote a cat catalog", pairs)
        self.assertEqual(text, "FaberLang wrote a dog catalog")

    def test_phrase_replace_is_literal(self):
        text = apply_replacements("use em el ex today", (("em el ex", "MLX"),))
        self.assertEqual(text, "use MLX today")

    def test_system_prompt_lists_pairs_and_transcript_is_tagged(self):
        cfg = dataclasses.replace(self.cfg, replacements=(("em el ex", "MLX"),))
        messages = cleanup_messages("use MLX", cfg.replacements)
        self.assertEqual(messages[0]["role"], "system")
        self.assertIn("em el ex -> MLX", messages[0]["content"])
        self.assertIn("Do not revert them", messages[0]["content"])
        self.assertEqual(messages[-1], {"role": "user", "content": "<transcript>\nuse MLX\n</transcript>"})

    def test_server_request_names_the_model_and_omits_empty_reasoning(self):
        sent = {}

        def post(url, json, timeout):
            sent.update(json)
            return FakeResponse({"choices": [{"message": {"content": "Hello."}}]})

        server_completer(self.server, post)(cleanup_messages("hello", ()))
        self.assertEqual(sent["model"], "qwen")
        self.assertNotIn("reasoning_effort", sent)
        self.assertIn("hello", sent["messages"][-1]["content"])

    def test_local_model_is_called_with_the_messages(self):
        seen = []

        def local(messages):
            seen.append(messages)
            return "Hello there."

        self.assertEqual(cleanup_transcript("hello there", self.cfg, local), ("Hello there.", True))
        self.assertEqual(seen[0][-1]["content"], "<transcript>\nhello there\n</transcript>")

    def test_local_model_not_loaded_yet_falls_back(self):
        self.assertEqual(cleanup_transcript("hello there", self.cfg, None), ("hello there", False))

    def test_llm_text_is_used(self):
        def post(url, json, timeout):
            self.assertTrue(url.endswith("/chat/completions"))
            self.assertEqual(timeout, 60)
            return FakeResponse({"choices": [{"message": {"content": "Hello."}}]})

        text, used = cleanup_transcript("hello", self.server, server_completer(self.server, post))
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
        text, used = cleanup_transcript(source, self.server, server_completer(self.server, self.reply(content)))
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
        text, used = cleanup_transcript(source, self.server, server_completer(self.server, self.reply(content)))
        self.assertEqual(text, source)
        self.assertFalse(used)

    def test_drift_allows_normal_cleanup(self):
        self.assertFalse(drifted("um so uh can you you know fix the the build", "So can you fix the build?"))
        self.assertTrue(drifted("fix the build", "Here is a poem about the sea and the sky."))

    def test_drift_rejects_lost_meaning_from_real_dictations(self):
        cases = (
            # a dropped decision
            (
                "I would approve it. I would not include step five because I don't know what that is.",
                "I would approve it.",
            ),
            # a reversed clause
            ("It belongs in the Vivi repo and not in Faberlang.", "It belongs in the Vivi repo, even though it's not in Faberlang."),
            # a dropped negation
            ("We should not merge this.", "We should merge this."),
            # a swapped pronoun
            ("Am I going to see my results?", "Are you going to see your results?"),
            # a dropped noun
            ("Let's get the Vivi service pump up and running.", "Let's get the Vivi service up and running."),
        )
        for source, cleaned in cases:
            self.assertTrue(drifted(source, cleaned), cleaned)

    def test_drift_allows_punctuation_contractions_and_fillers(self):
        cases = (
            ("all right i am back from the drive", "All right, I'm back from the drive."),
            ("we don't um want that you know because it breaks", "We do not want that because it breaks."),
            ("it is basically fine", "It is fine."),
            ("you can do it anyways", "You can do it anyway."),
        )
        for source, cleaned in cases:
            self.assertFalse(drifted(source, cleaned), cleaned)

    def test_chunks_keep_whole_sentences(self):
        sentence = "one two three four five six seven eight nine ten."
        text = " ".join([sentence] * 9)
        parts = chunks(text)
        self.assertEqual(" ".join(parts), text)
        self.assertTrue(all(part.endswith(".") for part in parts))
        self.assertTrue(all(len(part.split()) <= 40 for part in parts))
        self.assertGreater(len(parts), 1)

    def test_a_bad_chunk_keeps_its_speech_and_the_rest_is_cleaned(self):
        first = "we should not merge this branch today " * 4
        second = "um please run the tests"
        text = first.strip() + ". " + second + "."
        replies = iter(["We should merge this branch today.", "Please run the tests."])
        cfg = dataclasses.replace(self.server)

        def post(url, json, timeout):
            return FakeResponse({"choices": [{"message": {"content": next(replies)}}]})

        import stt_service.cleanup as cleanup

        original = cleanup.CHUNK_WORDS
        cleanup.CHUNK_WORDS = 10
        try:
            result, used = cleanup_transcript(text, cfg, server_completer(cfg, post))
        finally:
            cleanup.CHUNK_WORDS = original
        self.assertEqual(result, first.strip() + ". Please run the tests.")
        self.assertTrue(used)

    def test_empty_content_falls_back(self):
        def post(url, json, timeout):
            return FakeResponse({"choices": [{"message": {"content": None}}]})

        text, used = cleanup_transcript("hello", self.server, server_completer(self.server, post))
        self.assertEqual(text, "hello")
        self.assertFalse(used)

    def test_network_error_falls_back(self):
        def post(url, json, timeout):
            raise OSError("connection refused")

        text, used = cleanup_transcript("hello", self.server, server_completer(self.server, post))
        self.assertEqual(text, "hello")
        self.assertFalse(used)

    def test_disabled_cleanup_skips_the_model(self):
        def post(url, json, timeout):
            raise AssertionError("model should not be called")

        cfg = dataclasses.replace(self.cfg, cleanup_enabled=False)
        text, used = cleanup_transcript("hello there", cfg, server_completer(cfg, post))
        self.assertEqual(text, "hello there")
        self.assertFalse(used)

    def test_blank_transcript_skips_the_model(self):
        def post(url, json, timeout):
            raise AssertionError("model should not be called")

        text, used = cleanup_transcript("   ", self.server, server_completer(self.server, post))
        self.assertEqual(text, "")
        self.assertFalse(used)


if __name__ == "__main__":
    unittest.main()
