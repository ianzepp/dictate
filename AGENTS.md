# Dictate

This repository now builds a native macOS app. Read the shared instructions
first; this file adds repository-specific facts.

- `dictate/Sources/DictateCore`: strict config and pure cleanup/hotkey/audio rules.
- `dictate/Sources/DictateInference`: actor-owned MLX models, serialized access,
  model preparation, chunk fallback and cancellation. Keep all model work off
  MainActor. Await Qwen producer termination before releasing model ownership.
- `dictate/Sources/Dictate`: recording, overlay, menu and paste. Session checks
  and Task cancellation must prevent a cancelled request from pasting.
- `DictateVerify`: the production engine without microphone/pasteboard, for
  fixture, download, reload and cancellation checks.
- Python source and helper scripts are retained only in Git history (`ad7e6c8`).
  The checked-in golden data is read directly by Swift tests.

Use Xcode builds: SwiftPM alone does not compile MLX's Metal resources. The
build script stages `dist/Dictate.next.app`; the installer validates it, backs
up the current app/config and replaces the single `com.ianzepp.dictate` job.
Preserve the signing certificate and bundle identifier for macOS permissions.

Serialize all commands using `dictate/.build/xcode`. Parallel builds/tests
against that directory contend on Xcode's database. Dependencies are locked in
`dictate/Package.resolved`. Release builds explicitly disable coverage; do not
ship profiling instrumentation or omit the bundled Metal library.

Measured on the M5 Max / 128 GiB / macOS 27.0.1 during the 2026-10-26 migration:

| Command / check | Wall time |
| --- | ---: |
| First production dependency resolution | 111.83 s |
| First release app build | 142.57 s |
| Release packaging with coverage disabled, dependencies rebuilt | 134.87 s |
| Incremental packaging before the coverage-setting change | 20.12 s |
| Final metadata-only packaging with coverage disabled | 19.83 s |
| Integrated Release XCTest (35 tests, rebuilding for testability) | 110.02 s |
| Production-engine speech/cleanup/cancel/reload fixture run | 12.98 s |
| Final production-engine run without coverage instrumentation | 9.14 s |

Expect a cold native build to take roughly 2–3 minutes, capped at five minutes.
Changing coverage or testability can rebuild dependencies. Narrow core parity
tests ran in about 3.3 seconds after compilation. Use measured receipts under
`artifacts/native-inference/`; rerun only checks justified by the change.

The native config has no `speech.port`. The installer removes that obsolete
setting during upgrade; the app rejects it. Optional loopback cleanup-server
configuration remains supported. Cleanup fallback is a correctness property;
never weaken protected-word/negation checks for model output to pass.
