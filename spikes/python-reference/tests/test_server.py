import dataclasses
import unittest
from pathlib import Path

from fastapi import HTTPException

import stt_server
from stt_service.config import load_config

EXAMPLE = Path(__file__).resolve().parents[1] / "config.example.toml"


class ServerStateTests(unittest.TestCase):
    def setUp(self):
        self.cfg = load_config(EXAMPLE)
        self.addCleanup(self._restore, stt_server._model, dict(stt_server._speech_state), dict(stt_server._cleanup_state))
        stt_server._model = None

    def _restore(self, model, speech, cleanup):
        stt_server._model = model
        stt_server._speech_state.update(speech)
        stt_server._cleanup_state.update(cleanup)

    def test_dictation_waits_for_the_speech_model(self):
        for state, words in (("downloading", "downloading"), ("loading", "loading"), ("failed", "no network")):
            stt_server._speech_state.update(state=state, detail="no network")
            with self.assertRaises(HTTPException) as caught:
                stt_server._require_speech()
            self.assertEqual(caught.exception.status_code, 503)
            self.assertIn(words, caught.exception.detail)

    def test_local_cleanup_reports_its_own_state(self):
        stt_server._cleanup_state.update(state="downloading", detail="Downloading c/d")
        self.assertEqual(stt_server._cleanup_status(self.cfg), {"state": "downloading", "detail": "Downloading c/d"})

    def test_cleanup_off_in_config(self):
        cfg = dataclasses.replace(self.cfg, cleanup_enabled=False, cleanup_model="")
        self.assertEqual(stt_server._cleanup_status(cfg)["state"], "off")

    def test_unanswered_external_server_is_unreachable(self):
        cfg = dataclasses.replace(self.cfg, cleanup_model="", cleanup_url="http://127.0.0.1:1/v1", cleanup_name="x")
        self.assertEqual(stt_server._cleanup_status(cfg)["state"], "unreachable")


if __name__ == "__main__":
    unittest.main()
