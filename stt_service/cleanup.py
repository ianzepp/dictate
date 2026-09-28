"""Literal keyword fixes, then the local LLM cleanup pass."""

from __future__ import annotations

import logging
import re
from typing import Callable

from stt_service.config import Config

log = logging.getLogger("stt")

Post = Callable[..., object]


def apply_replacements(text: str, pairs: tuple[tuple[str, str], ...] | list[tuple[str, str]]) -> str:
    """Replace configured phrases. Longer phrases win over shorter ones.

    A single word is matched on boundaries so "cat" does not hit "catalog".
    A phrase that contains a space or punctuation is matched as written.
    """
    ordered = sorted((pair for pair in pairs if pair[0]), key=lambda pair: len(pair[0]), reverse=True)
    for src, dst in ordered:
        if re.fullmatch(r"\w+", src, flags=re.UNICODE):
            text = re.sub(rf"\b{re.escape(src)}\b", lambda _match, dst=dst: dst, text)
        else:
            text = text.replace(src, dst)
    return text


def cleanup_prompt(transcript: str, pairs: tuple[tuple[str, str], ...] | list[tuple[str, str]]) -> str:
    lines = [
        "Clean this speech-to-text transcript.",
        "Fix punctuation, capitalization, and obvious recognition errors.",
        "Remove filler words such as um, uh, and you know when they are only filler.",
        "Preserve the speaker's meaning and tone.",
        "Output only the cleaned transcript.",
    ]
    useful = [pair for pair in pairs if pair[0]]
    if useful:
        lines.append(
            "These substitutions are required. Exact matches are already applied. "
            "Do not revert them. Apply any the literal pass missed:"
        )
        for src, dst in useful:
            lines.append(f"- {src} -> {dst}")
    lines.extend(["", "Transcript:", transcript, "", "Cleaned transcript:"])
    return "\n".join(lines)


def cleanup_request(transcript: str, cfg: Config) -> dict:
    body = {
        "model": cfg.llm_model,
        "messages": [{"role": "user", "content": cleanup_prompt(transcript, cfg.replacements)}],
        "max_tokens": 1024,
        "temperature": 0.2,
    }
    if cfg.llm_reasoning_effort:
        body["reasoning_effort"] = cfg.llm_reasoning_effort
    return body


def cleanup_transcript(transcript: str, cfg: Config, post: Post | None = None) -> tuple[str, bool]:
    """Return cleaned text and whether the LLM produced it.

    A failed or empty model reply falls back to the transcript it was given,
    which is already the literal-replaced speech text.
    """
    if transcript.strip() == "":
        return "", False
    if post is None:
        import requests

        post = requests.post
    url = cfg.llm_base_url.rstrip("/") + "/chat/completions"
    try:
        response = post(url, json=cleanup_request(transcript, cfg), timeout=60)
        response.raise_for_status()
        content = response.json()["choices"][0]["message"].get("content")
    except (OSError, ValueError, KeyError, IndexError, TypeError) as exc:
        log.warning("LLM cleanup failed (%s); using the literal transcript", exc)
        return transcript, False
    if not isinstance(content, str) or content.strip() == "":
        log.warning("LLM cleanup returned empty content; using the literal transcript")
        return transcript, False
    return content.strip(), True
