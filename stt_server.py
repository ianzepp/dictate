"""Local speech service.

Opens its port at once and readies the Whisper model in the background,
downloading it first if needed. Each utterance is recognized,
literal keyword replacements are applied, then the cleanup model fixes grammar.
When the config names a cleanup model, this service runs llama-server for it.
Replacements are reread from the config on every request.
"""

from __future__ import annotations

import argparse
import asyncio
import dataclasses
from contextlib import asynccontextmanager
import logging
import tempfile
import threading
import time
from pathlib import Path

import uvicorn
from fastapi import FastAPI, File, HTTPException, UploadFile
from pydantic import BaseModel

from stt_service.cleanup import apply_replacements, cleanup_transcript
from stt_service.config import Config, ConfigError, load_config
from stt_service.llama import ManagedServer, find_server, server_args
from stt_service.models import describe_failure, needs_download, speech_model_dir

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("stt")

_cleanup_server: ManagedServer | None = None
# Why a configured cleanup model is not running, such as llama-server missing. Empty when fine.
_cleanup_problem = ""
# "downloading", "loading", "ready", or "failed", with a sentence for the menu.
_speech_state = {"state": "loading", "detail": ""}
SPEECH_RETRY_SECONDS = 30


@asynccontextmanager
async def _lifespan(_app):
    task = asyncio.create_task(_prepare_speech())
    yield
    task.cancel()
    # uvicorn re-raises SIGTERM after shutdown, which ends the process before a
    # finally block in main() runs. Stopping llama-server here happens first.
    if _cleanup_server:
        _cleanup_server.stop()


app = FastAPI(title="Local STT Service", version="0.2.0", lifespan=_lifespan)

_model = None
_model_name = ""
_model_path = ""
_language = "en"
_infer_lock = threading.Lock()
_config_lock = threading.Lock()
_last_good: Config | None = None

_AUDIO_SUFFIXES = {".wav", ".mp3", ".m4a", ".flac", ".ogg", ".aiff", ".aif", ".caf"}


def _live_config() -> Config:
    """Reread the file so a keyword fix applies on the next utterance."""
    global _last_good
    with _config_lock:
        try:
            cfg = load_config()
        except ConfigError as exc:
            if _last_good is None:
                raise
            log.warning("config reload failed (%s); using the last good file", exc)
            return _last_good
        if _model_name and cfg.speech_model != _model_name:
            log.warning("speech.model changed to %s; restart the service to load it", cfg.speech_model)
        _last_good = cfg
        return cfg


def _set_speech(state: str, detail: str = "") -> None:
    _speech_state.update(state=state, detail=detail)


async def _prepare_speech() -> None:
    """Download if needed, then load, retrying until it works.

    The download runs in a worker thread. The load runs on the event loop's
    thread on purpose: MLX's GPU stream belongs to the thread that loaded the
    model, and requests are recognized on this thread too.
    """
    cfg = _last_good
    assert cfg is not None
    while True:
        try:
            if needs_download(cfg.speech_model):
                _set_speech("downloading", f"Downloading {cfg.speech_model}")
            model_path = await asyncio.to_thread(speech_model_dir, cfg.speech_model)
            _set_speech("loading", "Loading the speech model")
            await asyncio.sleep(0)
            _load(cfg, model_path)
            _set_speech("ready")
            return
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            log.warning("speech model unavailable (%s); retrying in %ds", exc, SPEECH_RETRY_SECONDS)
            _set_speech("failed", describe_failure(cfg.speech_model, exc))
            await asyncio.sleep(SPEECH_RETRY_SECONDS)


def _load(cfg: Config, model_path: Path) -> None:
    """The first utterance after this still compiles Metal kernels."""
    global _model, _model_name, _model_path, _language
    log.info("loading speech model %s", model_path)
    from mlx_audio.stt import load

    _model = load(str(model_path))
    _model_name = cfg.speech_model
    _model_path = str(model_path)
    _language = cfg.speech_language
    log.info("speech model loaded")


def _require_speech() -> None:
    if _model is not None:
        return
    state, detail = _speech_state["state"], _speech_state["detail"]
    if state == "downloading":
        message = "The speech model is still downloading. Try again in a few minutes."
    elif state == "failed":
        message = f"The speech model is unavailable: {detail}"
    else:
        message = "The speech model is still loading. Try again in a moment."
    raise HTTPException(status_code=503, detail=message)


def _effective(cfg: Config) -> Config:
    """Skip cleanup when its server could not start, instead of failing each request."""
    if _cleanup_problem and cfg.cleanup_managed:
        return dataclasses.replace(cfg, cleanup_enabled=False)
    return cfg


def _cleanup_status(cfg: Config | None) -> dict:
    if cfg is None or not cfg.cleanup_enabled:
        return {"state": "off", "detail": "Turned off in the config"}
    if _cleanup_problem and cfg.cleanup_managed:
        return {"state": "missing", "detail": _cleanup_problem}
    import requests

    try:
        requests.get(cfg.cleanup_url + "/models", timeout=0.5).raise_for_status()
        return {"state": "ready", "detail": ""}
    except (OSError, ValueError):
        pass
    if cfg.cleanup_managed:
        return {"state": "starting", "detail": "The cleanup model is starting or downloading"}
    return {"state": "unreachable", "detail": f"Nothing is answering at {cfg.cleanup_url}"}


def transcribe_audio(audio: bytes, suffix: str) -> str:
    if _model is None:
        raise RuntimeError("STT model is not loaded")
    with tempfile.NamedTemporaryFile(suffix=suffix) as handle:
        handle.write(audio)
        handle.flush()
        with _infer_lock:
            result = _model.generate(
                handle.name,
                verbose=False,
                language=_language,
                temperature=0.0,
            )
    text = getattr(result, "text", None)
    if not isinstance(text, str):
        raise RuntimeError(f"unexpected STT result type: {type(result).__name__}")
    return text.strip()


def _suffix(filename: str | None) -> str:
    suffix = Path(filename or "audio.wav").suffix.lower()
    if suffix not in _AUDIO_SUFFIXES:
        return ".wav"
    return suffix


@app.get("/health")
def health():
    cfg = _last_good
    return {
        "status": "ok",
        "speech": dict(_speech_state),
        "cleanup": _cleanup_status(cfg),
        "stt_model_loaded": _model is not None,
        "stt_model": _model_path,
        "cleanup_url": cfg.cleanup_url if cfg else "",
        "cleanup_model": (cfg.cleanup_model or cfg.cleanup_name) if cfg else "",
    }


class CleanupBody(BaseModel):
    text: str


async def _read_audio(audio_file: UploadFile) -> tuple[bytes, str]:
    audio = await audio_file.read()
    if len(audio) < 100:
        raise HTTPException(status_code=400, detail="audio too small")
    return audio, _suffix(audio_file.filename)


def _config_or_500() -> Config:
    try:
        return _live_config()
    except ConfigError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc


def _phase_one(audio: bytes, suffix: str, cfg: Config) -> tuple[str, str, float]:
    # MLX's GPU stream belongs to the thread that loaded the model.
    started = time.perf_counter()
    try:
        raw = transcribe_audio(audio, suffix)
    except Exception as exc:
        log.exception("speech recognition failed")
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    replaced = apply_replacements(raw, cfg.replacements)
    return raw, replaced, time.perf_counter() - started


@app.post("/transcribe/raw")
async def transcribe_raw(audio_file: UploadFile = File(...)):
    """Phase one only: recognize speech and apply literal replacements."""
    _require_speech()
    audio, suffix = await _read_audio(audio_file)
    cfg = _config_or_500()
    raw, replaced, stt_seconds = _phase_one(audio, suffix, cfg)
    log.info("stt %.2fs (%d chars)", stt_seconds, len(raw))
    return {
        "raw_transcript": raw,
        "replaced_transcript": replaced,
        "stt_seconds": round(stt_seconds, 2),
        "model": _model_path,
    }


@app.post("/cleanup")
async def cleanup(body: CleanupBody):
    """Phase two only: grammar cleanup of text that already went through phase one."""
    cfg = _effective(_config_or_500())
    started = time.perf_counter()
    cleaned, llm_used = await asyncio.to_thread(cleanup_transcript, body.text, cfg)
    llm_seconds = time.perf_counter() - started if body.text.strip() else 0.0
    log.info("llm %.2fs used=%s", llm_seconds, llm_used)
    return {
        "cleaned_transcript": cleaned,
        "llm_seconds": round(llm_seconds, 2),
        "llm_used": llm_used,
        "llm_model": cfg.cleanup_name,
    }


@app.post("/transcribe")
async def transcribe(audio_file: UploadFile = File(...)):
    _require_speech()
    audio, suffix = await _read_audio(audio_file)
    cfg = _config_or_500()
    raw, replaced, stt_seconds = _phase_one(audio, suffix, cfg)
    llm_started = time.perf_counter()
    cleaned, llm_used = await asyncio.to_thread(cleanup_transcript, replaced, _effective(cfg))
    llm_seconds = time.perf_counter() - llm_started if replaced.strip() else 0.0
    log.info(
        "stt %.2fs (%d chars) llm %.2fs used=%s",
        stt_seconds,
        len(raw),
        llm_seconds,
        llm_used,
    )
    return {
        "raw_transcript": raw,
        "replaced_transcript": replaced,
        "cleaned_transcript": cleaned,
        "stt_seconds": round(stt_seconds, 2),
        "llm_seconds": round(llm_seconds, 2),
        "llm_used": llm_used,
        "model": _model_path,
        "llm_model": cfg.cleanup_name,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Local STT service")
    parser.add_argument("--check", action="store_true", help="Validate the config and exit")
    args = parser.parse_args()
    try:
        cfg = load_config()
    except ConfigError as exc:
        raise SystemExit(str(exc)) from exc
    if args.check:
        print(f"config ok: {cfg.path}")
        return
    global _cleanup_server, _cleanup_problem, _last_good
    _last_good = cfg
    cleanup = None
    if cfg.cleanup_managed:
        try:
            cleanup = ManagedServer(server_args(find_server(), cfg))
        except FileNotFoundError:
            # Speech still works; dictation pastes the uncleaned text.
            _cleanup_problem = "llama-server missing, run brew install llama.cpp"
            log.warning("%s; running without cleanup", _cleanup_problem)
        else:
            cleanup.start()
            _cleanup_server = cleanup
    try:
        log.info("listening on %s", cfg.speech_url)
        uvicorn.run(app, host="127.0.0.1", port=cfg.speech_port, log_level="info")
    finally:
        if cleanup:
            cleanup.stop()


if __name__ == "__main__":
    main()
