"""Local speech service.

Loads the Whisper model before it listens. Each utterance is recognized,
literal keyword replacements are applied, then the cleanup model fixes grammar.
When the config names a cleanup model, this service runs llama-server for it.
Replacements are reread from the config on every request.
"""

from __future__ import annotations

import argparse
import asyncio
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
from stt_service.models import speech_model_dir

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("stt")

_cleanup_server: ManagedServer | None = None


@asynccontextmanager
async def _lifespan(_app):
    yield
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


def preload(cfg: Config) -> None:
    """Load weights before the port opens. The first utterance still compiles Metal kernels."""
    global _model, _model_name, _model_path, _language, _last_good
    try:
        model_path = speech_model_dir(cfg.speech_model)
    except Exception as exc:
        raise SystemExit(f"speech model unavailable: {exc}") from exc
    log.info("loading speech model %s", model_path)
    from mlx_audio.stt import load

    _model = load(str(model_path))
    _model_name = cfg.speech_model
    _model_path = str(model_path)
    _language = cfg.speech_language
    _last_good = cfg
    log.info("STT model loaded")


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
    cfg = _config_or_500()
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
    audio, suffix = await _read_audio(audio_file)
    cfg = _config_or_500()
    raw, replaced, stt_seconds = _phase_one(audio, suffix, cfg)
    llm_started = time.perf_counter()
    cleaned, llm_used = await asyncio.to_thread(cleanup_transcript, replaced, cfg)
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
    global _cleanup_server
    cleanup = None
    if cfg.cleanup_managed:
        try:
            cleanup = ManagedServer(server_args(find_server(), cfg))
        except FileNotFoundError as exc:
            raise SystemExit(str(exc)) from exc
        # Start it first: a first-run download or load overlaps the speech model load.
        cleanup.start()
        _cleanup_server = cleanup
    try:
        preload(cfg)
        log.info("listening on %s", cfg.speech_url)
        uvicorn.run(app, host="127.0.0.1", port=cfg.speech_port, log_level="info")
    finally:
        if cleanup:
            cleanup.stop()


if __name__ == "__main__":
    main()
