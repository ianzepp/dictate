"""Local speech service.

Opens its port at once and readies the Whisper model, then the cleanup model,
in the background, downloading each first if needed. Each utterance is
recognized, literal keyword replacements are applied, then the cleanup model
fixes grammar. Both models run here on MLX, unless [cleanup] points at a
server that is already running. Replacements are reread on every request.
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

from stt_service.cleanup import apply_replacements, cleanup_transcript, server_completer
from stt_service.config import Config, ConfigError, load_config
from stt_service.local_model import LocalModel
from stt_service.models import describe_failure, model_dir, needs_download

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("stt")

# Each "downloading", "loading", "ready", or "failed", with a sentence for the menu.
_speech_state = {"state": "loading", "detail": ""}
_cleanup_state = {"state": "loading", "detail": ""}
_cleanup_model: LocalModel | None = None
RETRY_SECONDS = 30


@asynccontextmanager
async def _lifespan(_app):
    task = asyncio.create_task(_prepare_models())
    yield
    task.cancel()


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
        if _last_good and cfg.cleanup_model != _last_good.cleanup_model:
            log.warning("cleanup.model changed to %s; restart the service to load it", cfg.cleanup_model)
        _last_good = cfg
        return cfg


async def _prepare_models() -> None:
    """Speech first, since dictation needs it; then the local cleanup model."""
    cfg = _last_good
    assert cfg is not None
    await _prepare(cfg.speech_model, "speech", _speech_state, lambda path: _load_speech(cfg, path))
    if cfg.cleanup_local:
        await _prepare(cfg.cleanup_model, "cleanup", _cleanup_state, _load_cleanup)


async def _prepare(model: str, label: str, state: dict, load) -> None:
    """Download if needed, then load, retrying until it works.

    The download runs in a worker thread. The load runs on the event loop's
    thread on purpose: MLX's GPU stream belongs to the thread that loaded the
    model, and requests use both models on this thread too.
    """
    while True:
        try:
            if needs_download(model):
                state.update(state="downloading", detail=f"Downloading {model}")
            path = await asyncio.to_thread(model_dir, model)
            state.update(state="loading", detail=f"Loading the {label} model")
            await asyncio.sleep(0)
            load(path)
            state.update(state="ready", detail="")
            return
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            log.warning("%s model unavailable (%s); retrying in %ds", label, exc, RETRY_SECONDS)
            state.update(state="failed", detail=describe_failure(model, exc))
            await asyncio.sleep(RETRY_SECONDS)


def _load_speech(cfg: Config, model_path: Path) -> None:
    """The first utterance after this still compiles Metal kernels."""
    global _model, _model_name, _model_path, _language
    log.info("loading speech model %s", model_path)
    from mlx_audio.stt import load

    _model = load(str(model_path))
    _model_name = cfg.speech_model
    _model_path = str(model_path)
    _language = cfg.speech_language
    log.info("speech model loaded")


def _load_cleanup(model_path: Path) -> None:
    global _cleanup_model
    log.info("loading cleanup model %s", model_path)
    _cleanup_model = LocalModel(model_path)
    log.info("cleanup model loaded")


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


async def _clean(text: str, cfg: Config) -> tuple[str, bool]:
    """A local model runs on this thread, like the speech model; a server call runs in a worker."""
    if cfg.cleanup_local:
        return cleanup_transcript(text, cfg, _cleanup_model)
    return await asyncio.to_thread(cleanup_transcript, text, cfg, server_completer(cfg))


def _cleanup_status(cfg: Config | None) -> dict:
    if cfg is None or not cfg.cleanup_enabled:
        return {"state": "off", "detail": "Turned off in the config"}
    if cfg.cleanup_local:
        return dict(_cleanup_state)
    import requests

    try:
        requests.get(cfg.cleanup_url + "/models", timeout=0.5).raise_for_status()
        return {"state": "ready", "detail": ""}
    except (OSError, ValueError):
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
    cfg = _config_or_500()
    started = time.perf_counter()
    cleaned, llm_used = await _clean(body.text, cfg)
    llm_seconds = time.perf_counter() - started if body.text.strip() else 0.0
    log.info("llm %.2fs used=%s", llm_seconds, llm_used)
    return {
        "cleaned_transcript": cleaned,
        "llm_seconds": round(llm_seconds, 2),
        "llm_used": llm_used,
        "llm_model": cfg.cleanup_model or cfg.cleanup_name,
    }


@app.post("/transcribe")
async def transcribe(audio_file: UploadFile = File(...)):
    _require_speech()
    audio, suffix = await _read_audio(audio_file)
    cfg = _config_or_500()
    raw, replaced, stt_seconds = _phase_one(audio, suffix, cfg)
    llm_started = time.perf_counter()
    cleaned, llm_used = await _clean(replaced, cfg)
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
        "llm_model": cfg.cleanup_model or cfg.cleanup_name,
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
    global _last_good
    _last_good = cfg
    log.info("listening on %s", cfg.speech_url)
    uvicorn.run(app, host="127.0.0.1", port=cfg.speech_port, log_level="info")


if __name__ == "__main__":
    main()
