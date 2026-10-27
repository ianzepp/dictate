# Native Swift inference spikes

These isolated experiments preceded the production `DictateInference` module.
Their measured outputs and fixed input data remain here. The old Python code
and helper scripts are available only in Git history at `ad7e6c8`.

The two Swift executables use local model folders directly. They do not change
the app, configuration, login jobs or model weights. Dependencies are pinned in
`Package.resolved`. Build with Xcode and Swift 6.2 or newer so MLX's Metal
resources are compiled:

```sh
cd spikes/swift-speech
xcodebuild -scheme DictateSpeechSpike -configuration Release \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  -clonedSourcePackagesDirPath .build build CODE_SIGNING_ALLOWED=NO \
  ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO
```

With `MODEL_DIR` pointing to the existing Whisper large-v3-turbo 4-bit folder:

```sh
timeout 90 DerivedData/Build/Products/Release/DictateSpeechSpike \
  "$MODEL_DIR" fixtures/short.wav fixtures/long.wav
```

The checked-in WAVs fix the exact synthetic audio. The executable loads once,
then prints a warmup and three measured inferences per file as JSON lines,
including transcript, audio duration, load time, inference time and device.
The long recording crosses Whisper's 30-second window. Synthetic speech does
not establish real microphone quality. See [RESULTS.md](RESULTS.md).

For Qwen, build with the same options and scheme `DictateCleanupSpike`. With
`CLEANUP_MODEL_DIR` pointing to Qwen2.5 1.5B Instruct 4-bit:

```sh
timeout 60 DerivedData/Build/Products/Release/DictateCleanupSpike \
  "$CLEANUP_MODEL_DIR" fixtures/cleanup-prompts.json
```

The frozen JSON contains the original messages and token IDs. Swift renders
the chat template itself and checks those IDs before generation. Each call
has fresh generation state, zero temperature and a 1024-token limit. See
[CLEANUP_RESULTS.md](CLEANUP_RESULTS.md) for the historical comparison data.

The production `DictateVerify` tool and Swift XCTest suite are the current
integration and cleanup-rule checks. These spikes test standalone model calls.
`timeout` is supplied by GNU coreutils.
