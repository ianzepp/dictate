import tempfile
import unittest
from pathlib import Path

from stt_service.config import ConfigError, load_config

ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / "config.example.toml"


class ConfigTests(unittest.TestCase):
    def test_example_file(self):
        cfg = load_config(EXAMPLE)
        self.assertEqual(cfg.stt_base_url, "http://127.0.0.1:8090")
        self.assertEqual(cfg.llm_base_url, "http://127.0.0.1:8091/v1")
        self.assertEqual(cfg.llm_model, "qwen2.5-1.5b-instruct")
        self.assertEqual(cfg.llm_reasoning_effort, "")
        self.assertEqual(cfg.hotkey, "fn")
        self.assertTrue(cfg.stt_model.startswith(str(Path.home())))
        self.assertEqual(cfg.hotkey_mode, "hold")
        self.assertEqual(cfg.stt_language, "en")
        self.assertEqual(cfg.replacements, ())
        self.assertFalse(cfg.debug_enabled)

    def test_replacements_keep_file_order(self):
        cfg = load_config(self._write(
            self._body() + '"em el ex" = "MLX"\nfaber = "Faber"\n'
        ))
        self.assertEqual(cfg.replacements, (("em el ex", "MLX"), ("faber", "Faber")))

    def test_missing_file(self):
        with self.assertRaises(ConfigError):
            load_config(Path("/tmp/stt-service-does-not-exist.toml"))

    def test_unknown_key(self):
        text = self._body().replace('language = "en"', 'language = "en"\nextra = "no"')
        with self.assertRaises(ConfigError) as caught:
            load_config(self._write(text))
        self.assertIn("extra", str(caught.exception))

    def test_rejects_remote_url(self):
        text = self._body().replace("http://127.0.0.1:8090", "http://example.com:8090")
        with self.assertRaises(ConfigError):
            load_config(self._write(text))

    def test_rejects_unknown_hotkey(self):
        text = self._body().replace('key = "fn"', 'key = "f13"')
        with self.assertRaises(ConfigError):
            load_config(self._write(text))

    def _body(self) -> str:
        return EXAMPLE.read_text(encoding="utf-8")

    def _write(self, text: str) -> Path:
        handle = tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False, encoding="utf-8")
        handle.write(text)
        handle.close()
        self.addCleanup(Path(handle.name).unlink, missing_ok=True)
        return Path(handle.name)


if __name__ == "__main__":
    unittest.main()
