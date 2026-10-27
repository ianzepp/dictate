#!/usr/bin/env python3
"""Summarize Python and Swift results for the synthetic speech fixtures."""

from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
import unicodedata
from pathlib import Path
from typing import Optional


FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"
REPEATS = 3


def key_for(path: object) -> str:
    if not isinstance(path, str) or not path:
        raise ValueError(f"invalid audio path: {path!r}")
    return Path(path).stem.casefold()


def positive(value: object, name: str, errors: list[str]) -> Optional[float]:
    try:
        number = math.nan if isinstance(value, bool) else float(value)
    except (OverflowError, TypeError, ValueError):
        number = math.nan
    if not math.isfinite(number) or number <= 0:
        errors.append(f"{name}: expected a positive time, got {value!r}")
        return None
    return number


def transcript(value: object, name: str, errors: list[str]) -> Optional[str]:
    if not isinstance(value, str) or not value.strip():
        errors.append(f"{name}: empty or missing transcript")
        return None
    return value


def tokens(text: str) -> list[str]:
    folded = text.casefold()
    return "".join(" " if unicodedata.category(ch).startswith("P") else ch for ch in folded).split()


def edit_distance(reference: str, hypothesis: str) -> int:
    expected, actual = tokens(reference), tokens(hypothesis)
    row = list(range(len(actual) + 1))
    for i, word in enumerate(expected, start=1):
        next_row = [i]
        for j, candidate in enumerate(actual, start=1):
            next_row.append(min(
                row[j - 1] + (word != candidate),
                next_row[j - 1] + 1,
                row[j] + 1,
            ))
        row = next_row
    return row[-1]


def median(values: list[float]) -> Optional[float]:
    return round(statistics.median(values), 6) if values else None


def load_swift(path: Path, errors: list[str]) -> dict[str, list[dict]]:
    grouped: dict[str, list[dict]] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        errors.append(f"cannot read Swift JSONL {path}: {error}")
        return grouped
    for line_no, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
            if not isinstance(row, dict) or row.get("runtime") != "swift":
                raise ValueError("expected a Swift JSON object")
            audio = row.get("audio", row.get("audio_filename", row.get("audio_file")))
            grouped.setdefault(key_for(audio), []).append(row)
        except (json.JSONDecodeError, ValueError) as error:
            errors.append(f"Swift JSONL line {line_no}: {error}")
    return grouped


def read_python_row(row: object, name: str, errors: list[str]) -> tuple:
    if not isinstance(row, dict):
        errors.append(f"{name}: missing or invalid row")
        row = {}
    response = row.get("response")
    response = response if isinstance(response, dict) else {}
    text = transcript(response.get("raw_transcript"), name, errors)
    wall = positive(row.get("wall_time_seconds"), f"{name} wall_time_seconds", errors)
    stt = positive(response.get("stt_seconds"), f"{name} stt_seconds", errors)
    return text, wall, stt


def read_swift_row(row: dict, name: str, errors: list[str]) -> tuple:
    text = transcript(row.get("text"), name, errors)
    wall = positive(row.get("wall_seconds"), f"{name} wall_seconds", errors)
    positive(row.get("audio_seconds"), f"{name} audio_seconds", errors)
    positive(row.get("model_load_seconds"), f"{name} model_load_seconds", errors)
    return text, wall


def summarize(key: str, fixture: dict, swift_rows: list[dict], errors: list[str]) -> dict:
    try:
        reference = (FIXTURES / f"{key}.txt").read_text(encoding="utf-8")
        ref_tokens = tokens(reference)
        if not ref_tokens:
            raise ValueError("fixture text has no words")
    except (OSError, ValueError) as error:
        errors.append(f"fixture {key}: cannot use text reference: {error}")
        reference, ref_tokens = "", []

    warmup = fixture.get("warmup")
    measured = fixture.get("measured_repetitions")
    if not isinstance(measured, list):
        errors.append(f"Python {key}: missing measured rows")
        measured = []
    elif len(measured) != REPEATS:
        errors.append(f"Python {key}: expected {REPEATS} measured rows")
    warm_text, warm_wall, _ = read_python_row(warmup, f"Python {key} warmup", errors)
    python_rows = [read_python_row(row, f"Python {key} measured {i}", errors) for i, row in enumerate(measured, 1)]
    python_texts = [row[0] for row in python_rows if row[0] is not None]
    python_walls = [row[1] for row in python_rows if row[1] is not None]
    python_stt = [row[2] for row in python_rows if row[2] is not None]
    positive(fixture.get("audio_duration_seconds"), f"Python {key} audio_duration_seconds", errors)

    if len(swift_rows) != REPEATS + 1:
        errors.append(f"Swift {key}: expected one warmup plus {REPEATS} measured rows, got {len(swift_rows)}")
    warmups = [row for row in swift_rows if row.get("warmup") is True]
    swift_measured = [row for row in swift_rows if row.get("warmup") is False]
    if len(warmups) != 1 or len(swift_measured) != REPEATS:
        errors.append(f"Swift {key}: expected one warmup and {REPEATS} measured rows")
    iterations = [row.get("iteration") for row in swift_rows]
    if any(type(i) is not int for i in iterations) or sorted(iterations) != [0, 1, 2, 3]:
        errors.append(f"Swift {key}: expected iteration values 0, 1, 2, 3")
    elif len(warmups) == 1 and (warmups[0]["iteration"] != 0 or {row["iteration"] for row in swift_measured} != {1, 2, 3}):
        errors.append(f"Swift {key}: warmup must be iteration 0 and measured rows iterations 1 through 3")
    swift_values = [read_swift_row(row, f"Swift {key} row {i}", errors) for i, row in enumerate(swift_rows, 1)]
    swift_warm_texts = [value[0] for row, value in zip(swift_rows, swift_values) if row.get("warmup") is True]
    swift_texts = [value[0] for row, value in zip(swift_rows, swift_values) if row.get("warmup") is False and value[0] is not None]
    swift_walls = [value[1] for row, value in zip(swift_rows, swift_values) if row.get("warmup") is False and value[1] is not None]
    swift_warm_text = swift_warm_texts[0] if len(swift_warm_texts) == 1 else None

    def scores(texts: list[str]) -> dict:
        distances = [edit_distance(reference, text) for text in texts] if ref_tokens else []
        normalized = [distance / len(ref_tokens) for distance in distances] if ref_tokens else []
        return {"word_edits": distances, "normalized_distances": [round(x, 6) for x in normalized], "median": median(normalized)}

    return {
        "fixture": key,
        "python": {
            "audio_seconds": fixture.get("audio_duration_seconds"),
            "measured_rows": len(measured),
            "median_client_wall_seconds": median(python_walls),
            "median_stt_seconds": median(python_stt),
            "normalized_word_edit_distance": scores(python_texts),
        },
        "swift": {
            "measured_rows": len(swift_measured),
            "median_wall_seconds": median(swift_walls),
            "normalized_word_edit_distance": scores(swift_texts),
        },
        "exact_raw_text_equality": {
            "python_measured_repetitions_equal": len(python_texts) == REPEATS and len(set(python_texts)) == 1,
            "swift_measured_repetitions_equal": len(swift_texts) == REPEATS and len(set(swift_texts)) == 1,
            "between_runtimes_measured_equal": (
                len(python_texts) == REPEATS and len(swift_texts) == REPEATS
                and len(set(python_texts + swift_texts)) == 1
            ),
            "between_runtimes_case_and_punctuation_ignored": (
                len(python_texts) == REPEATS and len(swift_texts) == REPEATS
                and len({tuple(tokens(text)) for text in python_texts + swift_texts}) == 1
            ),
            "python_warmup_matches_measured": warm_text is not None and all(text == warm_text for text in python_texts),
            "swift_warmup_matches_measured": swift_warm_text is not None and all(text == swift_warm_text for text in swift_texts),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("python_json", type=Path)
    parser.add_argument("swift_jsonl", type=Path)
    args = parser.parse_args()
    errors = []
    try:
        baseline = json.loads(args.python_json.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"cannot read Python baseline JSON: {error}", file=sys.stderr)
        return 1
    if not isinstance(baseline, dict) or not isinstance(baseline.get("fixtures"), list):
        print("Python baseline JSON must contain a fixtures array", file=sys.stderr)
        return 1

    python_fixtures = {}
    for index, fixture in enumerate(baseline["fixtures"], start=1):
        try:
            if not isinstance(fixture, dict):
                raise ValueError("expected a JSON object")
            key = key_for(fixture.get("fixture"))
            if key in python_fixtures:
                raise ValueError(f"duplicate fixture {key!r}")
            python_fixtures[key] = fixture
        except ValueError as error:
            errors.append(f"Python fixture row {index}: {error}")

    swift_fixtures = load_swift(args.swift_jsonl, errors)
    for key in set(swift_fixtures) - set(python_fixtures):
        errors.append(f"Swift fixture {key!r} is absent from Python baseline")
    if not python_fixtures:
        errors.append("Python baseline contains no usable fixtures")
    results = [summarize(key, fixture, swift_fixtures.get(key, []), errors) for key, fixture in sorted(python_fixtures.items())]
    output = {
        "valid": not errors,
        "measurement_scope": "medians use three measured runs and exclude warmup",
        "distance_method": "casefold; replace punctuation with spaces; word Levenshtein edits / reference word count",
        "limitations": [
            "Synthetic speech does not establish real microphone parity.",
            "Numbers and abbreviations are not normalized and may inflate edit distance.",
            "Edit distance is directional evidence for these fixtures, not a general accuracy claim.",
            "Python client wall time includes HTTP overhead; stt_seconds excludes it.",
        ],
        "fixtures": results,
        "errors": errors,
    }
    print(json.dumps(output, indent=2, ensure_ascii=False))
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
