# Native inference delivery

Authority: operator request, 2026-10-26: port remaining cleanup rules to Swift
and replace the Python service with native inference in the app.

## Interpreted unit and normalized spec

One menu-bar app owns recording, native Whisper/Qwen inference, cleanup rules,
model preparation and status. Preserve hotkeys, lock/cancel, silence filtering,
audio ducking, recent text, the saved single/two-pass choice, debug artifacts,
live replacements, cleanup integrity fallback and documented optional external
cleanup configuration. Delete the internal HTTP speech-service path and its
Python login job. Retain the completed spike evidence as historical experiments.

Completion includes building and installing the signed app locally, stopping
the obsolete service, verifying native fixture transcription/cleanup in the
same production engine, checking cancellation/stale-result suppression, and
recording actual limits. No remote release or push is requested.

## Repo-aware baseline

Base: `83993dd` on `codex/swift-speech-spike`, initially clean. App currently
uploads WAVs to Python at localhost:8090; Python owns config validation, model
preparation, replacement/chunk/prompt/guard logic and cleanup. Both model spikes
passed against the existing quantized weights. The Swift app currently builds
with SwiftPM; native MLX needs Xcode's Metal resources bundled and signed.

## Stage graph and implementation work

- R1: pure cleanup rules in DictateCore, with Python-derived golden fixtures and
  SequenceMatcher parity. Owner: cleanup worker. No changes to config or UI.
- R2: complete native AppConfig and model status types, strict config validation,
  live replacement reload behavior contract. Owner: config worker. No inference/UI.
- R3: DictateInference model resolver, native model ownership, serialized inference,
  cancellation, health/progress and optional external cleanup. Owner: inference
  worker. Depends on R1/R2 interfaces; no UI/package/install edits.
- R4: app orchestration and native dependencies/build/packaging. Owner: parent.
  Depends on R1/R2/R3. Keep all inference off MainActor and suppress stale pastes.
- R5: remove production Python/HTTP remnants, migrate startup/config, update docs,
  native integration evidence, local installation and deliberate commit. Parent.

## Checkpoints, gates and validation

1. Pure cleanup parity: replacements, Python SequenceMatcher opcodes/ratios,
   contractions, protected words, edit budget, wrappers, prompts, sentence chunks,
   per-chunk failure and fallback. Existing Python is the temporary oracle.
2. Config: all existing functional settings validated natively; obsolete speech
   port removed explicitly on local upgrade; local model and external cleanup
   contracts preserved. Invalid reload keeps last-good replacements.
3. Native engine: real local Whisper and Qwen fixtures, same prompts/guard results;
   missing/download/load states; cancellation discards results and serial ownership.
4. App: recording lifecycle, status, debug steps and recent/paste path are wired
   to native work. No localhost speech calls or production Python requirement.
5. Build/install: release build, resources, stable signature, one app login job,
   old speech job stopped, native engine ready. Never claim real microphone/paste
   validation from synthetic fixtures alone.

## Companion skill plan and release

Factory executes; clean-break removes the internal service; existing spikes
provide pinned dependency/API evidence. Parent reviews integrated code and
serialized Git writes. Release: local installation now; remote release deferred
because the operator did not request publication. No scope item may silently
be deferred; unresolved limits stay explicit.

## Ledger

- R1 complete: 617 drift/acceptance + 610 SequenceMatcher comparisons and Unicode
  replacement/wrapper/prompt/chunk fixtures passed in isolated Swift tests.
- R2 complete: 17 strict config tests passed in isolation.
- R3/R4 integrated: native app release build passed (142.57 s); verifier build
  passed (17.09 s). Production-engine integration passed (12.98 s), including
  both audio fixtures, six cleanup cases, both cancellation paths and live
  replacement reload/invalid-edit retention/restoration.
- Integrated package tests passed: 35/35 (110.02 s). Fresh default-model download
  and load passed (43.72 s), weight hash matched the original spike checkpoint.
- Final Release disables profiling, packages/signs the Metal resources, and passed
  packaging (134.87 s). Final production-engine run repeated after all source and
  build-setting changes: 12 events, six exact cleanup comparisons, cancellation
  and reload checks passed (9.14 s).
- Local cutover completed: one native app process, both models ready, old Python
  job removed and port 8090 closed. Original app/config/plist backed up. Parent
  integration review checked ownership, cancellation completion, stale-paste
  guards, config migration and the production/Python boundary.
- Optional external cleanup integration also passed: four loopback HTTP
  requests proved request fields, per-chunk guard fallback, transport-failure
  fallback and recovery. The app declares local networking support explicitly.
- R1–R5 complete. Local version 0.2.0 installed; remote release deferred because
  it was not requested. No required implementation phase remains.
- Python production sources moved to `spikes/python-reference/` for historical
  reproduction; normal build/install has no Python dependency.
- Validation boundary: real microphone/hotkey/paste interaction needs an operator
  check; it was not inferred from fixture tests. Older NPZ/quantized Whisper
  variants unsupported by the SDK are documented, while the default checkpoint
  is validated. See `artifacts/native-inference/RESULTS.md` and `verification.json`.
- Open product decision: none. External cleanup remains because it is a documented
  configuration contract. The internal speech HTTP API has no required external
  consumer in this app migration and is removed.
