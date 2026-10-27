#!/usr/bin/env python3
"""Download a speech model ahead of time.

The service downloads speech.model on first start when it is a Hugging Face
name, so this is only needed to fetch a model before going offline.
"""

import argparse
import sys
from pathlib import Path

from stt_service.models import MODELS_DIR, download

DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo-4bit"


def main() -> None:
    parser = argparse.ArgumentParser(description="Download a speech model")
    parser.add_argument("model", nargs="?", default=DEFAULT_MODEL, help="Hugging Face repo id")
    parser.add_argument("--output-dir", help=f"Directory to save the model (default: {MODELS_DIR})")
    args = parser.parse_args()
    root = Path(args.output_dir) if args.output_dir else MODELS_DIR
    try:
        path = download(args.model, root)
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)
    print(f"Saved to: {path}")


if __name__ == "__main__":
    main()
