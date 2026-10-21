"""Run llama-server for the cleanup model when the config names one."""

from __future__ import annotations

import logging
import os
import shutil
import subprocess
import threading
from pathlib import Path

from stt_service.config import MANAGED_CLEANUP_NAME, Config, is_local_path

log = logging.getLogger("stt")

LOG_PATH = Path.home() / "Library" / "Logs" / "Dictate" / "cleanup.log"
RESTART_DELAY = 10.0

# LaunchAgents get a bare PATH, so look where Homebrew installs too.
_SEARCH_PATH = os.pathsep.join([os.environ.get("PATH", ""), "/opt/homebrew/bin", "/usr/local/bin"])


def find_server() -> str:
    override = os.environ.get("LLAMA_SERVER", "")
    found = override or shutil.which("llama-server", path=_SEARCH_PATH)
    if not found or not os.access(found, os.X_OK):
        raise FileNotFoundError("llama-server not found; brew install llama.cpp or set LLAMA_SERVER")
    return found


def server_args(binary: str, cfg: Config) -> list[str]:
    if is_local_path(cfg.cleanup_model):
        source = ["-m", cfg.cleanup_model]
    else:
        # llama-server downloads a repo[:quant] into its own cache on first start.
        source = ["-hf", cfg.cleanup_model]
    return [
        binary,
        *source,
        "--alias", MANAGED_CLEANUP_NAME,
        "--host", "127.0.0.1",
        "--port", str(cfg.cleanup_port),
        "-c", "4096",
        "-ngl", "99",
        "--reasoning", "off",
    ]


class ManagedServer:
    """Keeps llama-server up while the speech service runs.

    It shares the service's process group, so launchd stops it with the service.
    """

    def __init__(self, args: list[str]) -> None:
        self.args = args
        self.process: subprocess.Popen | None = None
        self.stopping = threading.Event()
        self.thread = threading.Thread(target=self._run, name="llama-server", daemon=True)

    def start(self) -> None:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        log.info("starting cleanup model: %s", " ".join(self.args[1:3]))
        self.thread.start()

    def stop(self) -> None:
        if self.stopping.is_set():
            return
        log.info("stopping cleanup model")
        self.stopping.set()
        process = self.process
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()

    def _run(self) -> None:
        while not self.stopping.is_set():
            with LOG_PATH.open("ab") as out:
                self.process = subprocess.Popen(self.args, stdout=out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
            code = self.process.wait()
            if self.stopping.is_set():
                return
            log.warning("llama-server exited with %s; restarting in %.0fs (log: %s)", code, RESTART_DELAY, LOG_PATH)
            self.stopping.wait(RESTART_DELAY)
