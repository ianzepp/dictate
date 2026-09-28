import tempfile
import unittest
from pathlib import Path

from download_model import PROCESSOR_FILES, ensure_processor


class DownloadTests(unittest.TestCase):
    def test_processor_fetch_skips_files_already_present(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "preprocessor_config.json").write_text("{}", encoding="utf-8")
            fetched = []
            ensure_processor(root, fetch=fetched.append)
        self.assertNotIn("preprocessor_config.json", fetched)
        self.assertEqual(sorted(fetched), sorted(name for name in PROCESSOR_FILES if name != "preprocessor_config.json"))


if __name__ == "__main__":
    unittest.main()
