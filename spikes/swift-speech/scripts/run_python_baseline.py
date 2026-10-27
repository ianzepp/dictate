#!/usr/bin/env python3
"""Post WAV fixtures to Dictate's raw transcription endpoint using Python stdlib."""

from __future__ import annotations

import argparse
import json
import statistics
import time
import uuid
import wave
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


FIXTURES_DIR = Path(__file__).resolve().parent.parent / "fixtures"
DEFAULT_FIXTURES = [FIXTURES_DIR / "short.wav", FIXTURES_DIR / "long.wav"]
DEFAULT_URL = "http://127.0.0.1:8090/transcribe/raw"


def audio_duration(path: Path) -> float:
    with wave.open(str(path), "rb") as audio:
        if audio.getnchannels() != 1 or audio.getframerate() != 16_000 or audio.getsampwidth() != 2:
            raise ValueError(f"{path} must be mono, 16 kHz, 16-bit PCM WAV")
        return audio.getnframes() / audio.getframerate()


def parse_response(body: bytes):
    text = body.decode("utf-8", errors="replace")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return {"unparsed_body": text}


def send_wav(url: str, path: Path, timeout: float) -> dict:
    boundary = "----dictate-baseline-" + uuid.uuid4().hex
    body = b"".join(
        [
            f"--{boundary}\r\n".encode("ascii"),
            f'Content-Disposition: form-data; name="audio_file"; filename="{path.name}"\r\n'.encode("utf-8"),
            b"Content-Type: audio/wav\r\n\r\n",
            path.read_bytes(),
            f"\r\n--{boundary}--\r\n".encode("ascii"),
        ]
    )
    request = Request(
        url,
        data=body,
        headers={"Accept": "application/json", "Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    started = time.perf_counter()
    try:
        with urlopen(request, timeout=timeout) as response:
            response_body = response.read()
            status = response.status
        result = {"http_status": status, "response": parse_response(response_body)}
    except HTTPError as error:
        result = {"http_status": error.code, "response": parse_response(error.read())}
    except (URLError, TimeoutError, OSError) as error:
        result = {"transport_error": str(error)}
    result["wall_time_seconds"] = round(time.perf_counter() - started, 6)
    return result


def succeeded(result: dict) -> bool:
    return result.get("http_status", 0) in range(200, 300) and "transport_error" not in result


def run_fixture(url: str, path: Path, repetitions: int, timeout: float) -> dict:
    duration = audio_duration(path)
    fixture_started = time.perf_counter()
    warmup = send_wav(url, path, timeout)
    measured = []
    for index in range(1, repetitions + 1):
        result = send_wav(url, path, timeout)
        result["repetition"] = index
        measured.append(result)
    elapsed = time.perf_counter() - fixture_started
    times = [item["wall_time_seconds"] for item in measured]
    return {
        "fixture": str(path),
        "audio_duration_seconds": round(duration, 6),
        "warmup": warmup,
        "measured_repetitions": measured,
        "measured_wall_time": {
            "count": len(times),
            "mean_seconds": round(statistics.mean(times), 6),
            "median_seconds": round(statistics.median(times), 6),
            "min_seconds": round(min(times), 6),
            "max_seconds": round(max(times), 6),
        },
        "warmup_plus_repetitions_wall_time_seconds": round(elapsed, 6),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default=DEFAULT_URL, help=f"raw transcription endpoint (default: {DEFAULT_URL})")
    parser.add_argument("--repetitions", type=int, default=3, help="measured requests per fixture (default: 3)")
    parser.add_argument("--timeout", type=float, default=15.0, help="request timeout in seconds (default: 15)")
    parser.add_argument("fixtures", nargs="*", type=Path, default=DEFAULT_FIXTURES, help="WAV fixture paths")
    args = parser.parse_args()
    if args.repetitions < 1:
        parser.error("--repetitions must be at least 1")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    if not args.fixtures:
        parser.error("provide at least one WAV fixture")

    started = time.perf_counter()
    fixtures = [run_fixture(args.url, path, args.repetitions, args.timeout) for path in args.fixtures]
    output = {
        "runner": "python-stdlib-baseline",
        "endpoint": args.url,
        "request_order": "sequential; one warmup then measured repetitions per fixture",
        "fixtures": fixtures,
        "total_wall_time_seconds": round(time.perf_counter() - started, 6),
    }
    print(json.dumps(output, indent=2, ensure_ascii=False))
    return 0 if all(
        succeeded(item["warmup"]) and all(succeeded(run) for run in item["measured_repetitions"])
        for item in fixtures
    ) else 1


if __name__ == "__main__":
    raise SystemExit(main())
