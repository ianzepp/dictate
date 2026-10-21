import tempfile
import unittest
from pathlib import Path

from stt_service.models import PROCESSOR_FILES, describe_failure, ensure_processor, local_dir_for, speech_model_dir


class DownloadTests(unittest.TestCase):
    def test_processor_fetch_skips_files_already_present(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "preprocessor_config.json").write_text("{}", encoding="utf-8")
            fetched = []
            ensure_processor(root, fetch=fetched.append)
        self.assertNotIn("preprocessor_config.json", fetched)
        self.assertEqual(sorted(fetched), sorted(name for name in PROCESSOR_FILES if name != "preprocessor_config.json"))

    def test_speech_name_downloads_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            calls = []

            def fetch(repo, into):
                calls.append(repo)
                local = local_dir_for(repo, into)
                local.mkdir(parents=True)
                (local / "config.json").write_text("{}", encoding="utf-8")
                return local

            first = speech_model_dir("owner/whisper", root, fetch)
            second = speech_model_dir("owner/whisper", root, fetch)
        self.assertEqual(first, root / "owner--whisper")
        self.assertEqual(second, first)
        self.assertEqual(calls, ["owner/whisper"])

    def test_speech_path_must_exist(self):
        with self.assertRaises(FileNotFoundError):
            speech_model_dir("/tmp/dictate-no-such-model")

    def test_failures_read_as_one_sentence(self):
        self.assertIn("No internet", describe_failure("a/b", ConnectionError("Failed to establish a new connection")))
        self.assertEqual(describe_failure("a/b", ValueError("first line\nsecond line")), "first line")


if __name__ == "__main__":
    unittest.main()
