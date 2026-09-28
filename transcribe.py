#!/usr/bin/env python3
"""Send one audio file to the local speech service and print the cleaned text."""

import argparse
import sys

import requests

from stt_service.config import ConfigError, default_config_path, load_config


def default_url() -> str:
    try:
        return load_config().stt_base_url
    except ConfigError:
        return "http://127.0.0.1:8090"


def transcribe_file(filepath: str, url: str) -> None:
    with open(filepath, "rb") as handle:
        response = requests.post(
            url.rstrip("/") + "/transcribe",
            files={"audio_file": (filepath.split("/")[-1], handle, "application/octet-stream")},
            timeout=300,
        )
    if response.status_code != 200:
        print(f"Error: {response.status_code}", file=sys.stderr)
        print(response.text, file=sys.stderr)
        sys.exit(1)
    result = response.json()
    print(result.get("cleaned_transcript") or result.get("replaced_transcript") or "")


def main() -> None:
    parser = argparse.ArgumentParser(description="STT service client")
    parser.add_argument("audio_file")
    parser.add_argument("--url", default=default_url(), help="Speech service base URL")
    args = parser.parse_args()
    try:
        transcribe_file(args.audio_file, args.url)
    except OSError as exc:
        print(f"{exc}", file=sys.stderr)
        print(f"Is the service up? Config: {default_config_path()}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
