#!/usr/bin/env python3
"""Download a local speech model.

The mlx-community Whisper repos ship weights without the Hugging Face
processor. Recognition needs those files, so a Whisper download also
fetches any missing processor files from the matching OpenAI repo.
"""

import argparse
import sys
from pathlib import Path

PROCESSOR_FILES = (
    "preprocessor_config.json",
    "tokenizer_config.json",
    "tokenizer.json",
    "vocab.json",
    "merges.txt",
    "special_tokens_map.json",
    "normalizer.json",
    "added_tokens.json",
    "generation_config.json",
)

DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo-4bit"
PROCESSOR_REPO = "openai/whisper-large-v3-turbo"


def ensure_processor(local_dir: Path, fetch=None) -> list[str]:
    """Download processor files that the weight repo left out. Returns the names fetched."""
    missing = [name for name in PROCESSOR_FILES if not (local_dir / name).is_file()]
    if not missing:
        return []
    if fetch is None:
        from huggingface_hub import hf_hub_download

        def fetch(name: str, _dest: Path = local_dir) -> None:
            hf_hub_download(PROCESSOR_REPO, name, local_dir=_dest)

    fetched = []
    for name in missing:
        fetch(name)
        fetched.append(name)
    return fetched


def download_model(model_name: str, output_dir: str | None = None) -> Path:
    from huggingface_hub import snapshot_download

    root = Path(output_dir) if output_dir else Path.home() / "ai" / "models" / "stt"
    root.mkdir(parents=True, exist_ok=True)
    local_dir = root / model_name.replace("/", "--")
    print(f"Downloading: {model_name}")
    print(f"Saving to: {local_dir}")
    try:
        snapshot_download(repo_id=model_name, local_dir=local_dir)
        if "whisper" in model_name:
            fetched = ensure_processor(local_dir)
            if fetched:
                print(f"Added processor files: {', '.join(fetched)}")
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)
    return local_dir


def main() -> None:
    parser = argparse.ArgumentParser(description="Download an STT model locally")
    parser.add_argument("model", nargs="?", default=DEFAULT_MODEL, help="Hugging Face repo id")
    parser.add_argument("--output-dir", help="Directory to save the model (default: ~/ai/models/stt)")
    args = parser.parse_args()
    path = download_model(args.model, args.output_dir)
    print(f"Saved to: {path}")


if __name__ == "__main__":
    main()
