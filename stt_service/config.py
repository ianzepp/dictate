"""One TOML file for the speech service and the menu-bar app."""

from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

HOTKEY_NAMES = (
    "fn",
    "right_option",
    "left_option",
    "right_command",
    "left_command",
    "right_control",
    "right_shift",
)

REASONING_EFFORTS = ("", "none", "minimal", "low", "medium", "high")

DEFAULT_SPEECH_PORT = 8090
DEFAULT_CLEANUP_PORT = 8091
# The name the managed llama-server answers to. Nothing outside this service sees it.
MANAGED_CLEANUP_NAME = "cleanup"

_KEYS = {
    "speech": ("model", "language", "port"),
    "cleanup": ("enabled", "model", "port", "url", "name", "reasoning_effort"),
    "hotkey": ("key", "mode"),
    "debug": ("enabled",),
}
_KIND_NAMES = {str: "a string", int: "a number", bool: "true or false"}


class ConfigError(Exception):
    """The config file is missing or does not match the schema."""


@dataclass(frozen=True)
class Config:
    path: Path
    speech_model: str
    speech_language: str
    speech_port: int
    cleanup_enabled: bool
    # Set when this service runs llama-server itself: a .gguf path or a Hugging Face repo[:quant].
    cleanup_model: str
    cleanup_port: int
    # The OpenAI-compatible base URL and model name the cleanup request goes to.
    cleanup_url: str
    cleanup_name: str
    cleanup_reasoning_effort: str
    hotkey: str
    hotkey_mode: str
    replacements: tuple[tuple[str, str], ...]
    debug_enabled: bool = False

    @property
    def speech_url(self) -> str:
        return f"http://127.0.0.1:{self.speech_port}"

    @property
    def cleanup_managed(self) -> bool:
        return self.cleanup_model != ""


def default_config_path() -> Path:
    override = os.environ.get("STT_CONFIG")
    if override:
        return Path(override).expanduser()
    return Path.home() / ".config" / "stt-service" / "config.toml"


def is_local_path(value: str) -> bool:
    """A model given as a path rather than a Hugging Face name."""
    return value.startswith(("/", "~", "."))


def load_config(path: Path | None = None) -> Config:
    """Load and validate the dictation config.

    Replacement order in the file is preserved. Callers that rewrite text
    sort longer phrases first themselves.
    """
    cfg_path = path if path is not None else default_config_path()
    if not cfg_path.is_file():
        raise ConfigError(
            f"config not found: {cfg_path}\n"
            "Copy config.example.toml to ~/.config/stt-service/config.toml"
        )
    try:
        data = tomllib.loads(cfg_path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"{cfg_path}: {exc}") from exc
    return _Reader(cfg_path, data).config()


class _Reader:
    """Every key is optional except speech.model. Unknown keys are errors, so typos surface."""

    def __init__(self, path: Path, data: dict) -> None:
        self.path = path
        unknown = set(data) - set(_KEYS) - {"replacements"}
        if unknown:
            raise self.error(f"unknown section: {', '.join(sorted(unknown))}")
        self.tables = {name: self.table(data, name) for name in _KEYS}
        self.replacements = self.pairs(data.get("replacements", {}))

    def error(self, message: str) -> ConfigError:
        return ConfigError(f"{self.path}: {message}")

    def table(self, data: dict, name: str) -> dict:
        table = data.get(name, {})
        if not isinstance(table, dict):
            raise self.error(f"[{name}] must be a table")
        unknown = set(table) - set(_KEYS[name])
        if unknown:
            raise self.error(f"unknown key in [{name}]: {', '.join(sorted(unknown))}")
        return table

    def get(self, section: str, key: str, kind: type, default):
        value = self.tables[section].get(key, default)
        # bool is an int in Python, so `port = true` would otherwise pass.
        if not isinstance(value, kind) or (kind is int and isinstance(value, bool)):
            raise self.error(f"{section}.{key} must be {_KIND_NAMES[kind]}")
        return value

    def config(self) -> Config:
        if "model" not in self.tables["speech"]:
            raise self.error("[speech] missing: model")
        speech_model = self.model("speech.model", self.get("speech", "model", str, ""))
        language = self.get("speech", "language", str, "en")
        if language == "" or len(language) > 8 or any(ch.isspace() for ch in language):
            raise self.error("speech.language must be a short code such as en")
        speech_port = self.port("speech.port", self.get("speech", "port", int, DEFAULT_SPEECH_PORT))

        enabled = self.get("cleanup", "enabled", bool, True)
        model = self.get("cleanup", "model", str, "").strip()
        cleanup_port = self.port("cleanup.port", self.get("cleanup", "port", int, DEFAULT_CLEANUP_PORT))
        url = self.get("cleanup", "url", str, "").strip()
        name = self.get("cleanup", "name", str, "").strip()
        effort = self.get("cleanup", "reasoning_effort", str, "")
        if effort not in REASONING_EFFORTS:
            allowed = ", ".join(repr(item) if item else '""' for item in REASONING_EFFORTS)
            raise self.error(f"cleanup.reasoning_effort must be one of {allowed}")
        if not enabled:
            model = url = name = ""
        elif model and (url or name):
            raise self.error("[cleanup] takes either model, or url and name, not both")
        elif model:
            model = self.model("cleanup.model", model)
            if cleanup_port == speech_port:
                raise self.error("speech.port and cleanup.port must differ")
            url = f"http://127.0.0.1:{cleanup_port}/v1"
            name = MANAGED_CLEANUP_NAME
        elif url and name:
            url = self.local_url("cleanup.url", url)
        else:
            raise self.error("[cleanup] needs model, or url and name, or enabled = false")

        hotkey = self.get("hotkey", "key", str, "fn")
        if hotkey not in HOTKEY_NAMES:
            raise self.error(f"hotkey.key must be one of {', '.join(HOTKEY_NAMES)}")
        mode = self.get("hotkey", "mode", str, "hold")
        if mode != "hold":
            raise self.error("hotkey.mode must be hold")

        return Config(
            path=self.path,
            speech_model=speech_model,
            speech_language=language,
            speech_port=speech_port,
            cleanup_enabled=enabled,
            cleanup_model=model,
            cleanup_port=cleanup_port,
            cleanup_url=url,
            cleanup_name=name,
            cleanup_reasoning_effort=effort,
            hotkey=hotkey,
            hotkey_mode=mode,
            replacements=self.replacements,
            debug_enabled=self.get("debug", "enabled", bool, False),
        )

    def model(self, label: str, value: str) -> str:
        value = value.strip()
        if value == "":
            raise self.error(f"{label} is empty")
        if is_local_path(value):
            path = Path(value).expanduser()
            if not path.is_absolute():
                raise self.error(f"{label} path must be absolute or start with ~/")
            return str(path)
        repo = value.split(":", 1)[0]
        if repo.count("/") != 1 or repo.startswith("/") or repo.endswith("/"):
            raise self.error(f"{label} must be a path or a Hugging Face name such as owner/repo")
        return value

    def port(self, label: str, value: int) -> int:
        if not 1024 <= value <= 65535:
            raise self.error(f"{label} must be between 1024 and 65535")
        return value

    def local_url(self, label: str, value: str) -> str:
        value = value.rstrip("/")
        parts = urlsplit(value)
        if parts.scheme != "http" or parts.hostname not in ("127.0.0.1", "localhost") or parts.port is None:
            raise self.error(f"{label} must be http://127.0.0.1:<port>/... or http://localhost:<port>/...")
        if parts.username or parts.password:
            raise self.error(f"{label} must not carry credentials")
        return value

    def pairs(self, table: object) -> tuple[tuple[str, str], ...]:
        if not isinstance(table, dict):
            raise self.error("[replacements] must be a table")
        pairs: list[tuple[str, str]] = []
        for src, dst in table.items():
            if not isinstance(src, str) or src == "":
                raise self.error("replacement key must be a non-empty string")
            if not isinstance(dst, str):
                raise self.error(f"replacement for {src!r} must be a string")
            pairs.append((src, dst))
        return tuple(pairs)
