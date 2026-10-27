#!/usr/bin/env python3
"""Compare cleanup runtimes and apply the existing Python guard to both."""

from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT))

from stt_service.cleanup import drifted, strip_wrapping


ITERATIONS = (1, 2, 3)
RUNTIMES = ("python", "swift")
ANALYSIS_LABEL = (
    "Python post-analysis using existing strip_wrapping/drifted; this is not a native Swift guard port."
)


def read_jsonl(path: Path, expected_runtime: str) -> list[dict]:
    rows = []
    for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip():
            continue
        row = json.loads(line)
        if not isinstance(row, dict) or row.get("runtime") != expected_runtime:
            raise ValueError(f"{path}:{line_no}: expected a {expected_runtime} JSON object")
        rows.append(row)
    return rows


def seconds(value: object, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{label}: expected a number")
    result = float(value)
    if not math.isfinite(result) or result <= 0:
        raise ValueError(f"{label}: expected a finite positive number")
    return result


def load_prompts(path: Path) -> tuple[list[dict], dict[tuple[str, int], dict]]:
    value = json.loads(path.read_text(encoding="utf-8"))
    cases = value.get("cases") if isinstance(value, dict) else None
    if not isinstance(cases, list) or not cases:
        raise ValueError("prompts file must contain a non-empty cases array")
    chunks = {}
    seen_ids = set()
    for case in cases:
        if not isinstance(case, dict) or not isinstance(case.get("id"), str):
            raise ValueError("each case must have a string id")
        case_id = case["id"]
        if case_id in seen_ids:
            raise ValueError(f"duplicate case id: {case_id}")
        seen_ids.add(case_id)
        if not isinstance(case.get("chunks"), list) or not case["chunks"]:
            raise ValueError(f"case {case_id}: chunks must be a non-empty array")
        for expected_index, chunk in enumerate(case["chunks"]):
            if not isinstance(chunk, dict) or chunk.get("index") != expected_index:
                raise ValueError(f"case {case_id}: chunk indexes must be contiguous from zero")
            source = chunk.get("source")
            tokens = chunk.get("prompt_tokens")
            if not isinstance(source, str) or not isinstance(tokens, list) or not tokens:
                raise ValueError(f"case {case_id} chunk {expected_index}: missing source or token IDs")
            if any(type(token) is not int for token in tokens):
                raise ValueError(f"case {case_id} chunk {expected_index}: token IDs must be integers")
            key = (case_id, expected_index)
            chunks[key] = {"source": source, "prompt_tokens": tokens}
    return cases, chunks


def group_rows(rows: list[dict], runtime: str, expected: dict[tuple[str, int], dict]) -> dict:
    grouped = {}
    first_key = next(iter(expected))
    for row_number, row in enumerate(rows, start=1):
        case_id, chunk_index = row.get("case_id"), row.get("chunk_index")
        key = (case_id, chunk_index)
        if key not in expected:
            raise ValueError(f"{runtime} row {row_number}: unknown case/chunk {key!r}")
        if type(chunk_index) is not int:
            raise ValueError(f"{runtime} row {row_number}: chunk_index must be an integer")
        if row.get("source") != expected[key]["source"]:
            raise ValueError(f"{runtime} row {row_number}: source does not match prompts fixture")
        if row.get("prompt_tokens") != expected[key]["prompt_tokens"]:
            raise ValueError(f"{runtime} row {row_number}: prompt token IDs differ from fixture")
        text = row.get("text")
        if not isinstance(text, str):
            raise ValueError(f"{runtime} row {row_number}: text must be a string")
        iteration, warmup = row.get("iteration"), row.get("warmup")
        if type(iteration) is not int or type(warmup) is not bool:
            raise ValueError(f"{runtime} row {row_number}: invalid iteration or warmup flag")
        if warmup:
            if key != first_key or iteration != 0:
                raise ValueError(f"{runtime} row {row_number}: only the first chunk has iteration 0 warmup")
        elif iteration not in ITERATIONS:
            raise ValueError(f"{runtime} row {row_number}: measured iteration must be 1, 2, or 3")
        seconds(row.get("wall_seconds"), f"{runtime} row {row_number} wall_seconds")
        seconds(row.get("model_load_seconds"), f"{runtime} row {row_number} model_load_seconds")
        grouped.setdefault(key, {})
        if iteration in grouped[key]:
            raise ValueError(f"{runtime} has duplicate row for {key!r}, iteration {iteration}")
        grouped[key][iteration] = row

    for key in expected:
        actual = grouped.get(key, {})
        wanted = set(ITERATIONS) | ({0} if key == first_key else set())
        if set(actual) != wanted:
            raise ValueError(f"{runtime} {key!r}: expected iterations {sorted(wanted)}, got {sorted(actual)}")
        if (0 in actual) != (key == first_key):
            raise ValueError(f"{runtime} {key!r}: warmup row must belong to the first chunk only")
    return grouped


def analyze_chunk(source: str, row: dict) -> dict:
    cleaned = strip_wrapping(row["text"])
    accepted = bool(cleaned.strip()) and not drifted(source, cleaned)
    return {
        "accepted": accepted,
        "fallback": not accepted,
        "final_text": cleaned if accepted else source,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prompts", type=Path)
    parser.add_argument("python_jsonl", type=Path)
    parser.add_argument("swift_jsonl", type=Path)
    args = parser.parse_args()

    try:
        cases, expected = load_prompts(args.prompts)
        rows = {
            "python": group_rows(read_jsonl(args.python_jsonl, "python"), "python", expected),
            "swift": group_rows(read_jsonl(args.swift_jsonl, "swift"), "swift", expected),
        }
        chunk_summaries = []
        case_summaries = []

        for case in cases:
            case_id = case["id"]
            case_chunks = case["chunks"]
            case_runtime_results = {runtime: {iteration: [] for iteration in ITERATIONS} for runtime in RUNTIMES}
            case_runtime_walls = {runtime: [] for runtime in RUNTIMES}
            case_iteration_walls = {runtime: {iteration: 0.0 for iteration in ITERATIONS} for runtime in RUNTIMES}

            for chunk in case_chunks:
                key = (case_id, chunk["index"])
                runtime_rows = {runtime: rows[runtime][key] for runtime in RUNTIMES}
                measured = {runtime: [runtime_rows[runtime][i] for i in ITERATIONS] for runtime in RUNTIMES}
                post_analysis = {}
                for runtime in RUNTIMES:
                    for iteration, row in zip(ITERATIONS, measured[runtime]):
                        outcome = analyze_chunk(chunk["source"], row)
                        case_runtime_results[runtime][iteration].append(outcome)
                        case_runtime_walls[runtime].append(float(row["wall_seconds"]))
                        case_iteration_walls[runtime][iteration] += float(row["wall_seconds"])
                    post_analysis[runtime] = {
                        str(iteration): analyze_chunk(chunk["source"], runtime_rows[runtime][iteration])
                        for iteration in ITERATIONS
                    }

                if 0 in runtime_rows["python"]:
                    post_analysis["python"]["warmup"] = analyze_chunk(
                        chunk["source"], runtime_rows["python"][0]
                    )
                    post_analysis["swift"]["warmup"] = analyze_chunk(
                        chunk["source"], runtime_rows["swift"][0]
                    )

                equality = {
                    str(iteration): measured["python"][iteration - 1]["text"]
                    == measured["swift"][iteration - 1]["text"]
                    for iteration in ITERATIONS
                }
                summary = {
                    "case_id": case_id,
                    "chunk_index": chunk["index"],
                    "source": chunk["source"],
                    "prompt_token_count": len(expected[key]["prompt_tokens"]),
                    "median_wall_seconds": {
                        runtime: round(
                            statistics.median(float(row["wall_seconds"]) for row in measured[runtime]), 6
                        )
                        for runtime in RUNTIMES
                    },
                    "raw_text_exact_equal_by_iteration": equality,
                    "raw_text_exact_equal_all_measured": all(equality.values()),
                    "python_post_analysis": post_analysis,
                }
                if key == next(iter(expected)):
                    summary["raw_warmup_text_exact_equal"] = (
                        runtime_rows["python"][0]["text"] == runtime_rows["swift"][0]["text"]
                    )
                chunk_summaries.append(summary)

            joined = {}
            for runtime in RUNTIMES:
                joined[runtime] = {
                    str(iteration): {
                        "text": " ".join(
                            outcome["final_text"] for outcome in case_runtime_results[runtime][iteration]
                        ),
                        "llm_used": any(
                            outcome["accepted"] for outcome in case_runtime_results[runtime][iteration]
                        ),
                    }
                    for iteration in ITERATIONS
                }
            case_summaries.append(
                {
                    "case_id": case_id,
                    "median_chunk_wall_seconds": {
                        runtime: round(statistics.median(case_runtime_walls[runtime]), 6)
                        for runtime in RUNTIMES
                    },
                    "median_total_generation_wall_seconds": {
                        runtime: round(statistics.median(case_iteration_walls[runtime].values()), 6)
                        for runtime in RUNTIMES
                    },
                    "joined_final_text_by_iteration": joined,
                }
            )

        output = {
            "valid": True,
            "prompt_token_sequences_match_fixture": True,
            "guard_analysis": ANALYSIS_LABEL,
            "warmup_policy": "One iteration-0 warmup for the first chunk per runtime; iterations 1-3 measured for every chunk.",
            "chunk_summaries": chunk_summaries,
            "case_summaries": case_summaries,
        }
        print(json.dumps(output, ensure_ascii=False, indent=2))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(json.dumps({"valid": False, "error": str(error)}, ensure_ascii=False, indent=2))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
