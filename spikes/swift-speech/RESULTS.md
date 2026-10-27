# Native Swift speech spike — 2026-10-26

The speech-recognition part can run in Swift without Python. The standalone
release executable loaded Dictate's existing Whisper large-v3-turbo 4-bit
checkpoint unchanged and transcribed both synthetic fixtures on `Device(gpu, 0)`.
No production app or service code was changed.

The two runtimes produced the same words after case and punctuation were
ignored. Their raw strings differ: Swift lowercases `add` in the short clip,
and uses a comma where Python starts a new sentence before `review the demo`
in the long clip. Each runtime repeated its own result exactly in all three
measured runs. This is limited fixture evidence, not general model parity.

| Fixture | Audio duration | Python service wall time | Swift inference wall time |
| --- | ---: | ---: | ---: |
| Short | 7.763 s | 0.285 s | 0.185 s |
| Long | 51.733 s | 0.730 s | 0.898 s |

Times are medians of three warm runs, excluding one warmup per fixture. Python
includes the localhost request; its reported inference medians were 0.28 s and
0.73 s. Swift loads audio before its inference timer. Both timers include
recognition and text decoding, but neither includes optional cleanup. Runs
were sequential, on battery, on an M5 Max with 128 GiB RAM and macOS 27.0.1.
This establishes useful latency for these clips, with mixed relative speed.
It is not an AC-powered benchmark or evidence of a general speed improvement.
The Python endpoint also decodes the uploaded audio and applies configured
replacements; comparisons use its raw transcript field. These timings compare
the two current call paths rather than identical operation boundaries.

Swift's model load took 0.240 s. Its first inference took 5.334 s, and the
complete process, including all eight inferences, took 10.00 s. The Python
service was already resident, so this spike does not compare cold startup.

The long clip crosses the Swift implementation's 30-second chunk boundary.
No word difference from Python appeared in that fixture, but more recordings
are needed to test words and sentences cut at chunk boundaries. Both runtimes
made the same recognition errors: for example, `before lunch` became `before
launch`. This migration does not itself fix those errors. Normalized edit
distance against fixture text was identical between runtimes (5/25 words in
the short clip; 7/151 in the long clip). That simple measure does not normalize
numbers or abbreviations and should not be read as a general accuracy score.

## Reproduction and evidence

See [README.md](README.md) for commands. The executable uses local weights
directly; the existing Python service remains available for the reference
runner. Do not run the inference commands concurrently. Checked-in WAVs fix
the exact audio used; regeneration can vary with the installed voice version.

- [Python reference output](evidence/python.json)
- [Swift output](evidence/swift.jsonl)
- [Comparison](evidence/summary.json)
- [Model and fixture hashes, package revisions, host state](evidence/provenance.json)
- [Build and command timings](evidence/commands.json)
- [CLI error-path checks](evidence/smoke.json)

The baseline used the installed service's Python 3.13.14 environment at
`~/ai/venvs/bonsai-mlx`, with MLX 0.32.0, mlx-audio 0.4.6, and mlx-lm 0.31.3.
The small HTTP reference driver uses only the Python standard library. Swift
uses MLX Swift 0.32.3 and mlx-audio-swift revision
`fe2c182f4da8115fe2b6b99c9a4d2048fbf9b1e6`; all transitive revisions are locked
in `Package.resolved`. The exact weight file SHA-256 is
`e2d6146b49644c13ed7467060d3c43c402bbdfca1f01f1c21f6fbeda23b6567e`.

## Build findings

The release build passed with Swift 6.4 and Xcode's Metal toolchain. The Metal
compiler was initially absent; Apple's 838.9 MB component downloaded in
75.22 s. The component is now installed on this machine. Xcode printed
unrelated CoreDevice/simulator-version warnings, but the macOS build passed.

Initial dependency resolution took 178.18 s. Renaming the spike directory from
`mlx-swift` to `swift-speech` fixed a SwiftPM root/dependency identity collision;
resolution then fetched the missing MLX sources and submodules in 110.71 s.
With the final pins and caches, resolution took 2.40 s.

The first substantial compile took 121.71 s and built the dependencies before
rejecting the wrapper's async GPU-scope closure under Swift concurrency rules.
The wrapper now keeps model ownership in one async function and scopes its
synchronous inference to the GPU. The successful incremental release build
took 15.23 s. A successful clean build has not been timed end to end.

Validation ran the release executable on both fixtures, checked eight Swift
results against eight final Python responses, and verified usage and missing
model failures exit with codes 2 and 1. The comparison script also rejects
missing input instead of reporting a successful comparison. No production app
build or broad test suite was run; production sources are unchanged. The
installed speech service still reported both models ready afterward.

## Migration boundary

This is enough evidence to proceed with native speech integration. It is not
a completed replacement for the Python service. Remaining work includes
real microphone recordings, longer and boundary-sensitive utterances, optional
Qwen cleanup inference, replacements and cleanup integrity checks, model
download/recovery, and moving inference off the app's UI thread. Packaging and
removing the speech LaunchAgent belong to that integration, not this spike.
