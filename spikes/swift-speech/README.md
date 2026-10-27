# Native Swift inference spikes

Question: can a native Swift executable use Dictate's existing 4-bit Whisper
large-v3-turbo weights, with useful output and latency, without Python?
The follow-up also tests the existing Qwen2.5 1.5B 4-bit cleanup weights.

This is a separate package. It does not change the app, installed LaunchAgents,
configuration, or model weights. `Package.resolved` records the dependency
revisions used. The audio SDK is pinned to a commit rather than a moving branch.

The executable accepts a local model directory and one or more WAV files. It
loads once, then reports the first inference and three warm inferences for each
file as JSON lines. Each row includes the text, audio duration, inference wall
time, and model load time. It forces English, matching Dictate's default.

Requires Swift 6.2 or later and Xcode's Metal compiler. If shader compilation
reports a missing Metal Toolchain, install it with
`xcodebuild -downloadComponent MetalToolchain` (838.9 MB on the spike machine).
Build with Xcode so MLX's Metal library is compiled:

```sh
cd spikes/swift-speech
xcodebuild -scheme DictateSpeechSpike -configuration Release \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  -clonedSourcePackagesDirPath .build build CODE_SIGNING_ALLOWED=NO
```

Run the comparison from this directory, with `MODEL_DIR` pointing to your
existing Whisper large-v3-turbo 4-bit directory:

```sh
mkdir -p results
python3 scripts/generate_fixtures.py
timeout 60 python3 scripts/run_python_baseline.py > results/python.json
timeout 90 DerivedData/Build/Products/Release/DictateSpeechSpike \
  "$MODEL_DIR" fixtures/short.wav fixtures/long.wav > results/swift.jsonl
python3 scripts/summarize.py results/python.json results/swift.jsonl
```

`timeout` is supplied by GNU coreutils. The Python baseline requires Dictate's
existing service at port 8090; the Swift command uses local weights directly
and requires no Python service. Do not run both inference commands concurrently.
The Swift command requests the GPU and reports the selected device in each row.

The fixture and reference scripts live under `scripts/`. The Python reference
calls the existing service's raw transcription endpoint; Swift runs directly.
HTTP overhead is therefore included only in the Python wall time, while the
service also returns its own inference timing. Compare raw transcripts before
replacements and optional cleanup.

Synthetic audio makes this repeatable, but does not establish real microphone
quality. A short fixture and a fixture longer than Whisper's 30-second window
exercise different paths. Results on battery are provisional. This spike does
not establish that the complete app has migrated.

Measured results and limitations are recorded in [RESULTS.md](RESULTS.md), with
the actual transcripts and timings under `evidence/`.

## Qwen cleanup

`DictateCleanupSpike` loads the local Qwen directory directly, renders each
chunk's chat template in Swift, and checks every input token ID against the
Python fixture before generation. Each call has fresh generation state,
temperature zero, and a 1024-token limit. The model stays loaded for the run.

Build with the same Xcode options, changing the scheme to `DictateCleanupSpike`.
Set `CLEANUP_MODEL_DIR` to the existing Qwen2.5 1.5B Instruct 4-bit directory and
`MODEL_PYTHON` to a Python environment with the project's requirements installed:

```sh
timeout 15 "$MODEL_PYTHON" scripts/prepare_cleanup.py --model-path "$CLEANUP_MODEL_DIR"
timeout 60 "$MODEL_PYTHON" scripts/run_cleanup_python.py \
  fixtures/cleanup-prompts.json --model-path "$CLEANUP_MODEL_DIR" > results/cleanup-python.jsonl
timeout 60 DerivedData/Build/Products/Release/DictateCleanupSpike \
  "$CLEANUP_MODEL_DIR" fixtures/cleanup-prompts.json > results/cleanup-swift.jsonl
"$MODEL_PYTHON" scripts/summarize_cleanup.py fixtures/cleanup-prompts.json \
  results/cleanup-python.jsonl results/cleanup-swift.jsonl
```

Keep these runs sequential. Python uses the production `LocalModel` directly;
neither inference runner uses the HTTP speech service. The summary applies the
existing Python cleanup guard to both outputs afterward. This tests native
model inference, not a Swift port of the guard or the whole cleanup pipeline.

See [CLEANUP_RESULTS.md](CLEANUP_RESULTS.md) and `evidence/cleanup/` for results.
