#!/usr/bin/env python3
"""Build cleanup prompts and reference token IDs from the local MLX tokenizer."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"
sys.path.insert(0, str(REPO_ROOT / "spikes/python-reference"))

from stt_service.cleanup import apply_replacements, chunks, cleanup_messages


def load_cases(path: Path) -> list[dict]:
    value = json.loads(path.read_text(encoding="utf-8"))
    cases = value.get("cases") if isinstance(value, dict) else None
    if not isinstance(cases, list) or not cases:
        raise ValueError("cases file must contain a non-empty cases array")
    seen: set[str] = set()
    for case in cases:
        if not isinstance(case, dict):
            raise ValueError("each case must be an object")
        case_id = case.get("id")
        source = case.get("source")
        pairs = case.get("replacements")
        if not isinstance(case_id, str) or not case_id or case_id in seen:
            raise ValueError(f"invalid or duplicate case id: {case_id!r}")
        if not isinstance(source, str) or not source.strip():
            raise ValueError(f"case {case_id}: source must be non-empty text")
        if not isinstance(pairs, list) or any(
            not isinstance(pair, list) or len(pair) != 2
            or not all(isinstance(part, str) for part in pair) or not pair[0]
            for pair in pairs
        ):
            raise ValueError(f"case {case_id}: replacements must be [from, to] string pairs")
        seen.add(case_id)
    return cases


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-path", required=True, type=Path)
    parser.add_argument("--cases", type=Path, default=FIXTURES / "cleanup-cases.json")
    parser.add_argument("--output", type=Path, default=FIXTURES / "cleanup-prompts.json")
    args = parser.parse_args()

    model_path = args.model_path.expanduser().resolve(strict=True)
    if not model_path.is_dir():
        parser.error(f"model path is not a directory: {model_path}")

    try:
        from mlx_lm.utils import load_tokenizer

        tokenizer = load_tokenizer(str(model_path))
        output_cases = []
        for case in load_cases(args.cases):
            pairs = [tuple(pair) for pair in case["replacements"]]
            replaced = apply_replacements(case["source"], pairs)
            output_chunks = []
            for index, source in enumerate(chunks(replaced)):
                messages = cleanup_messages(source, pairs)
                prompt = tokenizer.apply_chat_template(
                    messages,
                    tokenize=False,
                    add_generation_prompt=True,
                )
                prompt_tokens = tokenizer.encode(prompt, add_special_tokens=False)
                output_chunks.append(
                    {
                        "index": index,
                        "source": source,
                        "messages": messages,
                        "prompt_tokens": [int(token) for token in prompt_tokens],
                    }
                )
            if not output_chunks:
                raise ValueError(f"case {case['id']}: replacement pass produced no chunks")
            output_cases.append(
                {
                    "id": case["id"],
                    "source": case["source"],
                    "replacements": case["replacements"],
                    "chunks": output_chunks,
                }
            )

        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(
            json.dumps({"cases": output_cases}, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"prepare cleanup prompts: {error}", file=sys.stderr)
        return 1

    print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
