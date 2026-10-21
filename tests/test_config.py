import tempfile
import unittest
from pathlib import Path

from stt_service.config import ConfigError, load_config

ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / "config.example.toml"


class ConfigTests(unittest.TestCase):
    def test_example_file(self):
        cfg = load_config(EXAMPLE)
        self.assertEqual(cfg.speech_model, "mlx-community/whisper-large-v3-turbo-4bit")
        self.assertEqual(cfg.speech_url, "http://127.0.0.1:8090")
        self.assertEqual(cfg.speech_language, "en")
        self.assertTrue(cfg.cleanup_managed)
        self.assertEqual(cfg.cleanup_model, "bartowski/Qwen2.5-1.5B-Instruct-GGUF:Q4_K_M")
        self.assertEqual(cfg.cleanup_url, "http://127.0.0.1:8091/v1")
        self.assertEqual(cfg.cleanup_name, "cleanup")
        self.assertEqual(cfg.cleanup_reasoning_effort, "")
        self.assertEqual(cfg.hotkey, "fn")
        self.assertEqual(cfg.hotkey_mode, "hold")
        self.assertEqual(cfg.hotkey_lock, "right_option")
        self.assertEqual(cfg.replacements, ())
        self.assertFalse(cfg.debug_enabled)

    def test_only_speech_model_is_required(self):
        cfg = load_config(self._write('[speech]\nmodel = "~/models/whisper"\n[cleanup]\nenabled = false\n'))
        self.assertEqual(cfg.speech_model, str(Path.home() / "models/whisper"))
        self.assertEqual(cfg.speech_port, 8090)
        self.assertEqual(cfg.hotkey, "fn")
        self.assertFalse(cfg.cleanup_enabled)
        self.assertFalse(cfg.cleanup_managed)

    def test_missing_speech_model(self):
        with self.assertRaises(ConfigError) as caught:
            load_config(self._write('[speech]\nlanguage = "en"\n'))
        self.assertIn("speech", str(caught.exception))

    def test_cleanup_gguf_path(self):
        cfg = load_config(self._write('[speech]\nmodel = "a/b"\n[cleanup]\nmodel = "~/m/q.gguf"\nport = 9001\n'))
        self.assertEqual(cfg.cleanup_model, str(Path.home() / "m/q.gguf"))
        self.assertEqual(cfg.cleanup_url, "http://127.0.0.1:9001/v1")

    def test_external_cleanup_server(self):
        cfg = load_config(self._write(
            '[speech]\nmodel = "a/b"\n[cleanup]\nurl = "http://localhost:1234/v1/"\nname = "qwen"\n'
            'reasoning_effort = "none"\n'
        ))
        self.assertFalse(cfg.cleanup_managed)
        self.assertEqual(cfg.cleanup_url, "http://localhost:1234/v1")
        self.assertEqual(cfg.cleanup_name, "qwen")
        self.assertEqual(cfg.cleanup_reasoning_effort, "none")

    def test_cleanup_needs_a_source(self):
        with self.assertRaises(ConfigError) as caught:
            load_config(self._write('[speech]\nmodel = "a/b"\n'))
        self.assertIn("enabled = false", str(caught.exception))

    def test_cleanup_model_and_url_conflict(self):
        text = '[speech]\nmodel = "a/b"\n[cleanup]\nmodel = "c/d"\nurl = "http://127.0.0.1:1/v1"\nname = "x"\n'
        with self.assertRaises(ConfigError):
            load_config(self._write(text))

    def test_rejects_remote_cleanup_url(self):
        text = '[speech]\nmodel = "a/b"\n[cleanup]\nurl = "http://example.com:80/v1"\nname = "x"\n'
        with self.assertRaises(ConfigError):
            load_config(self._write(text))

    def test_rejects_bad_model_name(self):
        with self.assertRaises(ConfigError):
            load_config(self._write('[speech]\nmodel = "whisper"\n[cleanup]\nenabled = false\n'))

    def test_rejects_same_ports(self):
        text = '[speech]\nmodel = "a/b"\nport = 9000\n[cleanup]\nmodel = "c/d"\nport = 9000\n'
        with self.assertRaises(ConfigError):
            load_config(self._write(text))

    def test_rejects_wrong_types(self):
        for text in ('[speech]\nmodel = "a/b"\nport = "8090"\n', '[speech]\nmodel = "a/b"\nport = true\n'):
            with self.assertRaises(ConfigError):
                load_config(self._write(text + '[cleanup]\nenabled = false\n'))

    def test_replacements_keep_file_order(self):
        cfg = load_config(self._write(self._body() + '"em el ex" = "MLX"\nfaber = "Faber"\n'))
        self.assertEqual(cfg.replacements, (("em el ex", "MLX"), ("faber", "Faber")))

    def test_missing_file(self):
        with self.assertRaises(ConfigError):
            load_config(Path("/tmp/dictate-does-not-exist.toml"))

    def test_unknown_key(self):
        text = self._body().replace('language = "en"', 'language = "en"\nextra = "no"')
        with self.assertRaises(ConfigError) as caught:
            load_config(self._write(text))
        self.assertIn("extra", str(caught.exception))

    def test_rejects_unknown_hotkey(self):
        text = self._body().replace('key = "fn"', 'key = "f13"')
        with self.assertRaises(ConfigError):
            load_config(self._write(text))

    def test_lock_key(self):
        base = '[speech]\nmodel = "a/b"\n[cleanup]\nenabled = false\n[hotkey]\n'
        self.assertEqual(load_config(self._write(base + 'lock = "none"\n')).hotkey_lock, "")
        self.assertEqual(load_config(self._write(base + 'key = "right_option"\n')).hotkey_lock, "")
        for bad in ('lock = "f13"\n', 'key = "right_option"\nlock = "right_option"\n'):
            with self.assertRaises(ConfigError):
                load_config(self._write(base + bad))

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
