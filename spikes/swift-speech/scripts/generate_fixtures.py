#!/usr/bin/env python3
"""Generate repeatable speech fixtures with macOS `say` and `afconvert`.

This uses text-to-speech only. It never opens a microphone or records audio.
Run from any directory; WAV files are written beside the fixture text by default.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
import wave
from pathlib import Path


FIXTURES_DIR = Path(__file__).resolve().parent.parent / "fixtures"
FIXTURE_NAMES = ("short", "long")
EXPECTED_RATE = 16_000
EXPECTED_CHANNELS = 1
EXPECTED_SAMPLE_WIDTH = 2


def wav_duration(path: Path) -> float:
    with wave.open(str(path), "rb") as audio:
        if audio.getframerate() != EXPECTED_RATE:
            raise RuntimeError(f"{path} has sample rate {audio.getframerate()}, expected {EXPECTED_RATE}")
        if audio.getnchannels() != EXPECTED_CHANNELS:
            raise RuntimeError(f"{path} has {audio.getnchannels()} channels, expected mono")
        if audio.getsampwidth() != EXPECTED_SAMPLE_WIDTH:
            raise RuntimeError(f"{path} has {audio.getsampwidth()}-byte samples, expected 16-bit PCM")
        if audio.getnframes() == 0:
            raise RuntimeError(f"{path} contains no audio frames")
        return audio.getnframes() / audio.getframerate()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--voice", default="Samantha", help="macOS say voice (default: Samantha)")
    parser.add_argument("--rate", type=int, default=165, help="say rate in words per minute (default: 165)")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=FIXTURES_DIR,
        help="directory for short.wav and long.wav (default: fixture directory)",
    )
    args = parser.parse_args()

    if sys.platform != "darwin":
        parser.error("fixture generation requires macOS `say` and `afconvert`")
    missing = [name for name in ("say", "afconvert") if shutil.which(name) is None]
    if missing:
        parser.error(f"required macOS command not found: {', '.join(missing)}")
    if args.rate <= 0:
        parser.error("--rate must be positive")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    results = []
    with tempfile.TemporaryDirectory(prefix="mlx-swift-speech-") as temp_dir:
        temp_path = Path(temp_dir)
        for name in FIXTURE_NAMES:
            text_path = FIXTURES_DIR / f"{name}.txt"
            wav_path = args.output_dir / f"{name}.wav"
            aiff_path = temp_path / f"{name}.aiff"
            if not text_path.is_file():
                raise FileNotFoundError(f"missing fixture text: {text_path}")

            subprocess.run(
                ["say", "-v", args.voice, "-r", str(args.rate), "-f", str(text_path), "-o", str(aiff_path)],
                check=True,
                timeout=30,
            )
            subprocess.run(
                ["afconvert", "-f", "WAVE", "-d", f"LEI16@{EXPECTED_RATE}", "-c", "1", str(aiff_path), str(wav_path)],
                check=True,
                timeout=30,
            )
            duration = wav_duration(wav_path)
            if name == "long" and duration <= 30.0:
                raise RuntimeError(
                    f"long fixture is only {duration:.2f}s; choose a slower --rate or lengthen long.txt"
                )
            results.append({"text": str(text_path), "wav": str(wav_path), "duration_seconds": round(duration, 3)})

    print(json.dumps({"voice": args.voice, "rate_words_per_minute": args.rate, "fixtures": results}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
