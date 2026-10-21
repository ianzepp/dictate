"""Find or download the models named in the config."""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Callable

from stt_service.config import is_local_path

log = logging.getLogger("stt")

MODELS_DIR = Path.home() / ".local" / "share" / "dictate" / "models"

# The mlx-community Whisper repos ship weights without the Hugging Face
# processor. Recognition needs those files, so a Whisper download also
# fetches any missing processor files from the matching OpenAI repo.
PROCESSOR_FILES = (
    "preprocessor_config.json",
    "tokenizer_config.json",
    "tokenizer.json",
    "vocab.json",
    "merges.txt",
    "special_tokens_map.json",
    "normalizer.json",
    "added_tokens.json",
    "generation_config.json",
)
PROCESSOR_REPO = "openai/whisper-large-v3-turbo"


def ensure_processor(local_dir: Path, fetch: Callable[[str], None] | None = None) -> list[str]:
    """Download processor files that the weight repo left out. Returns the names fetched."""
    missing = [name for name in PROCESSOR_FILES if not (local_dir / name).is_file()]
    if not missing:
        return []
    if fetch is None:
        from huggingface_hub import hf_hub_download

        def fetch(name: str, _dest: Path = local_dir) -> None:
            hf_hub_download(PROCESSOR_REPO, name, local_dir=_dest)

    for name in missing:
        fetch(name)
    return missing


def local_dir_for(repo: str, root: Path = MODELS_DIR) -> Path:
    return root / repo.replace("/", "--")


def download(repo: str, root: Path = MODELS_DIR) -> Path:
    from huggingface_hub import snapshot_download

    local_dir = local_dir_for(repo, root)
    log.info("downloading %s to %s", repo, local_dir)
    snapshot_download(repo_id=repo, local_dir=local_dir)
    if "whisper" in repo:
        fetched = ensure_processor(local_dir)
        if fetched:
            log.info("added processor files: %s", ", ".join(fetched))
    return local_dir


def describe_failure(model: str, exc: Exception) -> str:
    """One plain sentence for the menu, instead of a Hugging Face error page."""
    from huggingface_hub.errors import LocalEntryNotFoundError, RepositoryNotFoundError

    if isinstance(exc, RepositoryNotFoundError):
        return f"{model} was not found on Hugging Face"
    if isinstance(exc, (LocalEntryNotFoundError, ConnectionError)) or "connect" in str(exc).lower():
        return "No internet connection for the download; retrying"
    first = str(exc).strip().splitlines()[0] if str(exc).strip() else type(exc).__name__
    return first[:120]


def needs_download(model: str, root: Path = MODELS_DIR) -> bool:
    return not is_local_path(model) and not (local_dir_for(model, root) / "config.json").is_file()


def speech_model_dir(model: str, root: Path = MODELS_DIR, fetch: Callable[[str, Path], Path] = download) -> Path:
    """The folder to load: a configured path as is, or a Hugging Face name downloaded on first use."""
    if is_local_path(model):
        path = Path(model)
        if not path.is_dir():
            raise FileNotFoundError(f"speech model folder not found: {path}")
        return path
    local_dir = local_dir_for(model, root)
    # config.json lands last in a snapshot; without it the download did not finish.
    if (local_dir / "config.json").is_file():
        return local_dir
    return fetch(model, root)
