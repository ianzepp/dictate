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

_SECTIONS = {
    "stt": ("base_url", "model", "language"),
    "llm": ("base_url", "model", "reasoning_effort"),
    "hotkey": ("key", "mode"),
    "replacements": None,
}
_OPTIONAL = {
    "debug": ("enabled",),
}


class ConfigError(Exception):
    """The config file is missing or does not match the schema."""


@dataclass(frozen=True)
class Config:
    path: Path
    stt_base_url: str
    stt_model: str
    stt_language: str
    llm_base_url: str
    llm_model: str
    llm_reasoning_effort: str
    hotkey: str
    hotkey_mode: str
    replacements: tuple[tuple[str, str], ...]
    debug_enabled: bool = False


def default_config_path() -> Path:
    override = os.environ.get("STT_CONFIG")
    if override:
        return Path(override).expanduser()
    return Path.home() / ".config" / "stt-service" / "config.toml"


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
    if not isinstance(data, dict):
        raise ConfigError(f"{cfg_path}: expected a table")
    _require_sections(cfg_path, data)
    stt = _section(cfg_path, data, "stt")
    llm = _section(cfg_path, data, "llm")
    hotkey = _section(cfg_path, data, "hotkey")
    replacements = _replacements(cfg_path, data.get("replacements", {}))
    debug_enabled = _debug_enabled(cfg_path, data.get("debug"))
    return Config(
        path=cfg_path,
        stt_base_url=_local_url(cfg_path, "stt.base_url", _string(cfg_path, "stt.base_url", stt["base_url"])),
        stt_model=_model_path(cfg_path, _string(cfg_path, "stt.model", stt["model"])),
        stt_language=_language(cfg_path, _string(cfg_path, "stt.language", stt["language"])),
        llm_base_url=_local_url(cfg_path, "llm.base_url", _string(cfg_path, "llm.base_url", llm["base_url"])),
        llm_model=_nonempty(cfg_path, "llm.model", _string(cfg_path, "llm.model", llm["model"])),
        llm_reasoning_effort=_reasoning(cfg_path, _string(cfg_path, "llm.reasoning_effort", llm["reasoning_effort"])),
        hotkey=_hotkey(cfg_path, _string(cfg_path, "hotkey.key", hotkey["key"])),
        hotkey_mode=_mode(cfg_path, _string(cfg_path, "hotkey.mode", hotkey["mode"])),
        replacements=replacements,
        debug_enabled=debug_enabled,
    )


def _require_sections(path: Path, data: dict) -> None:
    unknown = set(data) - set(_SECTIONS) - set(_OPTIONAL)
    if unknown:
        names = ", ".join(sorted(unknown))
        raise ConfigError(f"{path}: unknown section: {names}")
    missing = [name for name in _SECTIONS if name not in data]
    if missing:
        names = ", ".join(missing)
        raise ConfigError(f"{path}: missing section: {names}")


def _section(path: Path, data: dict, name: str) -> dict:
    table = data[name]
    if not isinstance(table, dict):
        raise ConfigError(f"{path}: [{name}] must be a table")
    expected = _SECTIONS[name]
    assert expected is not None
    unknown = set(table) - set(expected)
    if unknown:
        names = ", ".join(sorted(unknown))
        raise ConfigError(f"{path}: unknown key in [{name}]: {names}")
    missing = [key for key in expected if key not in table]
    if missing:
        names = ", ".join(missing)
        raise ConfigError(f"{path}: [{name}] missing: {names}")
    return table


def _debug_enabled(path: Path, table: object) -> bool:
    if table is None:
        return False
    if not isinstance(table, dict):
        raise ConfigError(f"{path}: [debug] must be a table")
    unknown = set(table) - set(_OPTIONAL["debug"])
    if unknown:
        names = ", ".join(sorted(unknown))
        raise ConfigError(f"{path}: unknown key in [debug]: {names}")
    if "enabled" not in table:
        raise ConfigError(f"{path}: [debug] missing: enabled")
    value = table["enabled"]
    if isinstance(value, bool):
        return value
    if isinstance(value, str) and value in ("true", "false"):
        return value == "true"
    raise ConfigError(f"{path}: debug.enabled must be true or false")


def _replacements(path: Path, table: object) -> tuple[tuple[str, str], ...]:
    if not isinstance(table, dict):
        raise ConfigError(f"{path}: [replacements] must be a table")
    pairs: list[tuple[str, str]] = []
    for src, dst in table.items():
        if not isinstance(src, str) or src == "":
            raise ConfigError(f"{path}: replacement key must be a non-empty string")
        if not isinstance(dst, str):
            raise ConfigError(f"{path}: replacement for {src!r} must be a string")
        pairs.append((src, dst))
    return tuple(pairs)


def _string(path: Path, label: str, value: object) -> str:
    if not isinstance(value, str):
        raise ConfigError(f"{path}: {label} must be a string")
    return value


def _nonempty(path: Path, label: str, value: str) -> str:
    if value.strip() == "":
        raise ConfigError(f"{path}: {label} is empty")
    return value


def _local_url(path: Path, label: str, value: str) -> str:
    value = _nonempty(path, label, value).rstrip("/")
    parts = urlsplit(value)
    if parts.scheme != "http" or parts.hostname not in ("127.0.0.1", "localhost") or parts.port is None:
        raise ConfigError(f"{path}: {label} must be http://127.0.0.1:<port> or http://localhost:<port>")
    if parts.username or parts.password:
        raise ConfigError(f"{path}: {label} must not carry credentials")
    return value


def _model_path(path: Path, value: str) -> str:
    value = _nonempty(path, "stt.model", value)
    model = Path(value)
    if not model.is_absolute():
        raise ConfigError(f"{path}: stt.model must be an absolute path")
    return str(model)


def _language(path: Path, value: str) -> str:
    value = _nonempty(path, "stt.language", value)
    if len(value) > 8 or any(ch.isspace() for ch in value):
        raise ConfigError(f"{path}: stt.language must be a short code such as en")
    return value


def _reasoning(path: Path, value: str) -> str:
    if value not in REASONING_EFFORTS:
        allowed = ", ".join(repr(item) if item else '""' for item in REASONING_EFFORTS)
        raise ConfigError(f"{path}: llm.reasoning_effort must be one of {allowed}")
    return value


def _hotkey(path: Path, value: str) -> str:
    if value not in HOTKEY_NAMES:
        names = ", ".join(HOTKEY_NAMES)
        raise ConfigError(f"{path}: hotkey.key must be one of {names}")
    return value


def _mode(path: Path, value: str) -> str:
    if value != "hold":
        raise ConfigError(f"{path}: hotkey.mode must be hold")
    return value
