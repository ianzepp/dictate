# Native app migration — 2026-10-26

Dictate 0.2.0 is installed locally and running native Whisper and Qwen inside
the signed menu-bar app. The final snapshot showed one app process and both
models ready. The Python speech job was removed and port 8090 was closed.
The app keeps the existing bundle identifier and local signing certificate.

## Implemented

- Pure Swift replacements, prompts/examples, sentence chunks, wrapper stripping,
  contractions/fillers/stutters, protected-word checks, edit budgets, Python
  SequenceMatcher behavior and per-chunk fallback.
- Full native config validation, live replacement reload and last-good retention
  when an edit is invalid. The obsolete `speech.port` is migrated by the installer.
- Actor-owned models off MainActor, serialized GPU access, and cancellation that
  waits for the Qwen producer before reusing its model. App session checks guard
  each awaited result and the paste boundary.
- Native preparation/download/retry states, existing local model reuse, atomic
  staging of new downloads, and preserved optional loopback cleanup-server mode.
- One app login job, staged build/install, stable signing, bundled Metal resources,
  preserved app/config backups and Release builds without coverage instrumentation.

Normal build/install and app use require no Python. The previous implementation
and its benchmark/verification scripts were subsequently removed from the tree
at the operator's request. They remain in Git history at `ad7e6c8`; the frozen
corpus and this dated evidence remain as data.

## Evidence

The integrated Release XCTest run passed **35 tests**: 29 core and 6 inference.
The cleanup corpus includes **617 drift/acceptance cases** and **610 matcher
opcode/ratio cases**, plus Unicode replacements, exact prompts, wrappers and
chunks. A replay of the archived Python generator produced byte-identical data.
The archived reference's own 44 tests also passed; those are not native tests.

The final uninstrumented production-engine run completed in **9.14 seconds**:

- Both existing synthetic audio fixtures transcribed and cleaned.
- All six cleanup cases exactly matched the prior Python final texts.
- Cancelled cleanup and recognition returned cancellation, and subsequent model
  requests succeeded.
- Live replacements took effect; an invalid edit retained the last good values;
  restoring the config restored the original replacement behavior.

The full unit run preceded the vocabulary-based downloader correction. That
changed path was then checked with a fresh download of the default Whisper
checkpoint, and the complete production-engine run was repeated on the final
Release code. The fresh download, load and transcription took **43.72 seconds**.
The downloaded weight hash matched the original spike checkpoint exactly.

Release packaging with profiling disabled passed in **134.87 seconds**, and
the final metadata-only package took **19.83 seconds**. The installed binary's signature verified;
its compiler commands and binary contain no profiling runtime, and the config
check emitted no raw profiling file.

The optional loopback cleanup-server contract also passed four real HTTP
requests: the model/name/sampling fields were correct, a rewritten negation
fell back per chunk while the next chunk was cleaned, an HTTP 503 preserved
the original text, and a subsequent request recovered. The app explicitly
allows local networking in its transport policy while config restricts cleanup
URLs to loopback. [Protocol-check evidence](external-cleanup.json).

- [Verification manifest, source hashes, dependency pins and command timings](verification.json)
- [Final production-engine outputs](integration-release.jsonl)
- [Final installed process/model status](installed-status.json)
- [Cutover checks and downloaded checkpoint hash](cutover-checks.json)
- [Fresh default-model download outputs](fresh-download.jsonl)
- [Original frozen Python comparison](../../spikes/swift-speech/evidence/cleanup/summary.json)

Detailed command logs and generated build/test results remain locally under the
ignored build/artifact paths; the compact receipts above are committed.

## Operational boundary

The installer preserved the original Python-era app/config and speech plist
under `dictate/dist/.native-backup.L5vsAX/`. Later native replacements also have
their own backups, whose paths are retained in the local install logs. These are local,
ignored recovery artifacts. No models, permissions or personal recordings were
deleted. The release is local only; nothing was pushed, tagged or published.

Real microphone/hotkey/paste interaction was not exercised automatically. The
recording and paste components remain in place, but the operator should verify
one real dictation after the update. Synthetic fixtures do not prove that UI path.

The supported defaults use MLX safetensors. A legacy NPZ-only Whisper checkpoint
was correctly rejected; an older tiny 4-bit checkpoint exposed an upstream SDK
embedding-layout incompatibility. Those negative checks are retained as
[format](unsupported-format.jsonl) and [layout](incompatible-checkpoint.jsonl)
evidence. The production checkpoint passed both existing-file and fresh-download
paths. Other checkpoints are not claimed universally compatible.
