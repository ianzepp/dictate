#!/usr/bin/env python3
"""Run each cleanup prompt through one local model instance and emit JSONL."""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "spikes/python-reference"))

from stt_service.local_model import LocalModel


def load_prompts(path: Path) -> list[dict]:
    value = json.loads(path.read_text(encoding="utf-8"))
    cases = value.get("cases") if isinstance(value, dict) else None
    if not isinstance(cases, list) or not cases:
        raise ValueError("prompts file must contain a non-empty cases array")
    for case in cases:
        if not isinstance(case, dict) or not isinstance(case.get("chunks"), list) or not case["chunks"]:
            raise ValueError("each case must contain a non-empty chunks array")
        for chunk in case["chunks"]:
            if not isinstance(chunk, dict) or not isinstance(chunk.get("messages"), list):
                raise ValueError("each chunk must contain messages")
            if not isinstance(chunk.get("prompt_tokens"), list):
                raise ValueError("each chunk must contain prompt_tokens")
    return cases


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prompts", type=Path)
    parser.add_argument("--model-path", required=True, type=Path)
    args = parser.parse_args()

    model_path = args.model_path.expanduser().resolve(strict=True)
    if not model_path.is_dir():
        parser.error(f"model path is not a directory: {model_path}")

    try:
        cases = load_prompts(args.prompts)
        started = time.perf_counter()
        model = LocalModel(model_path)
        model_load_seconds = time.perf_counter() - started

        chunks = [(case["id"], chunk) for case in cases for chunk in case["chunks"]]
        for case_id, chunk in chunks:
            prompt = model.tokenizer.apply_chat_template(
                chunk["messages"],
                add_generation_prompt=True,
                tokenize=False,
            )
            prompt_tokens = [
                int(token) for token in model.tokenizer.encode(prompt, add_special_tokens=False)
            ]
            if prompt_tokens != chunk["prompt_tokens"]:
                raise ValueError(
                    f"{case_id} chunk {chunk['index']}: runtime tokenizer IDs differ from fixture"
                )

        first_case_id, first_chunk = chunks[0]
        started = time.perf_counter()
        warm_text = model(first_chunk["messages"])
        warm_row = {
            "runtime": "python",
            "case_id": first_case_id,
            "chunk_index": first_chunk["index"],
            "iteration": 0,
            "warmup": True,
            "source": first_chunk["source"],
            "text": warm_text,
            "wall_seconds": time.perf_counter() - started,
            "model_load_seconds": model_load_seconds,
            "prompt_tokens": first_chunk["prompt_tokens"],
        }
        print(json.dumps(warm_row, ensure_ascii=False), flush=True)

        for case_id, chunk in chunks:
            for iteration in (1, 2, 3):
                started = time.perf_counter()
                text = model(chunk["messages"])
                row = {
                    "runtime": "python",
                    "case_id": case_id,
                    "chunk_index": chunk["index"],
                    "iteration": iteration,
                    "warmup": False,
                    "source": chunk["source"],
                    "text": text,
                    "wall_seconds": time.perf_counter() - started,
                    "model_load_seconds": model_load_seconds,
                    "prompt_tokens": chunk["prompt_tokens"],
                }
                print(json.dumps(row, ensure_ascii=False), flush=True)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"run Python cleanup: {error}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
