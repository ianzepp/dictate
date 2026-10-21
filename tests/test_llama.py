import dataclasses
import unittest
from pathlib import Path

from stt_service.config import load_config
from stt_service.llama import server_args

EXAMPLE = Path(__file__).resolve().parents[1] / "config.example.toml"


class LlamaTests(unittest.TestCase):
    def test_hugging_face_name_uses_hf(self):
        args = server_args("/bin/llama-server", load_config(EXAMPLE))
        self.assertEqual(args[:3], ["/bin/llama-server", "-hf", "bartowski/Qwen2.5-1.5B-Instruct-GGUF:Q4_K_M"])
        self.assertIn("8091", args)
        self.assertEqual(args[args.index("--alias") + 1], "cleanup")

    def test_gguf_path_uses_m(self):
        cfg = dataclasses.replace(load_config(EXAMPLE), cleanup_model="/models/q.gguf")
        self.assertEqual(server_args("llama-server", cfg)[1:3], ["-m", "/models/q.gguf"])


if __name__ == "__main__":
    unittest.main()
