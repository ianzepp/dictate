# Historical Python reference

This is the pre-migration implementation from `83993dd`, retained only to
reproduce the speech/Qwen experiments and regenerate the cleanup parity corpus.
The app, native build and login installer do not use it. No Python job is
installed by the native product.

Use an existing environment with this directory's requirements if reproducing
the old tests or inference. From this directory:

```sh
python -m unittest discover -s tests
```

The old HTTP service is a manual benchmark oracle only. Do not run it alongside
native timing comparisons. Its LaunchAgent template is archived here for
provenance and is not installed. The current installer stops and removes the
old `com.ianzepp.dictate.speech` login job during migration.

The unchanged cleanup source hash and seed are embedded in the Swift test
fixture. From the repository root, `tools/export_cleanup_golden.py` imports this
reference and regenerates that fixture. Running Swift tests requires no Python.
