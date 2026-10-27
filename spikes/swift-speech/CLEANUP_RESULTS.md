# Native Swift Qwen cleanup spike — 2026-10-26

The existing Qwen2.5 1.5B Instruct 4-bit checkpoint works in the standalone
Swift release executable on `Device(gpu, 0)`. All 25 Swift replies matched the
Python replies exactly, including the first warmup and three measured replies
for each of eight chunks across six synthetic dictations. Every Swift-rendered
chat-template token sequence also matched Python's input token IDs exactly.
The Swift process performs local inference directly, without a Python bridge
or calls to the speech service. Model weights and production code are unchanged.

| Case | Chunks | Python warm median | Swift warm median |
| --- | ---: | ---: | ---: |
| Fillers and punctuation | 1 | 0.155 s | 0.203 s |
| Dictated question | 1 | 0.158 s | 0.197 s |
| Negation and pronouns | 1 | 0.265 s | 0.226 s |
| Instruction treated as dictated text | 1 | 0.245 s | 0.266 s |
| Required `em el ex` → `MLX` replacement | 1 | 0.196 s | 0.166 s |
| Long dictation | 3 | 0.906 s | 0.827 s |

Each row is the median of three repetitions. The long row sums all three
chunk-generation times for each repetition before taking the median. These
times include prompt rendering, tokenization and generation, but exclude model
loading, literal replacement/chunk preparation, and the guard applied after
generation. Both runtimes use fresh generation state for every call, zero
temperature, and a 1024-token limit. All Swift generations reported normal
`stop` completion; none exhausted that limit. Python ran first, then Swift.

Swift loaded the model in 0.374 s; its first generation took 1.764 s. Python's
load, including its lazy imports, took 1.147 s; its first generation took
0.975 s. The entire Python runner took 8.07 s and Swift took 7.94 s. These are
first calls in these processes, not measurements with all system caches empty.

This was the same M5 Max, 128 GiB Mac on battery as the speech experiment.
Relative speed is mixed, and the corpus is small. The result establishes
feasibility and exact output agreement on these inputs, not general numerical
parity, a broad quality evaluation, or an overall speed improvement.

## Cleanup behavior and boundary

The fixtures use the live production functions for literal replacements,
sentence chunks, system instructions, and examples. The long dictation is 79
words and splits into three whole-sentence chunks using the current 40-word
chunk policy. Swift renders the messages with its own tokenizer and refuses
to generate if those token IDs differ from Python's fixture. It does not simply
feed the exported Python token IDs into the model.

The existing Python `strip_wrapping` and `drifted` functions accepted every
measured reply from both runtimes; no chunk required fallback. Joined final
texts were identical. The question remained a question, the dictated
instruction remained transcript text, and the negations, pronouns and `MLX`
replacement survived.

Those guard checks are Python post-analysis, not native Swift functionality.
This spike does not port replacements, sentence chunking, wrapper stripping,
the drift checker, or fallback behavior. It also does not integrate the models
with recording, cancellation, UI updates, model downloads or login startup.
Together with the speech spike, it supports proceeding with native inference
integration while preserving those remaining application responsibilities.

## Reproduction and evidence

See the cleanup section in [README.md](README.md) for commands.

- [Synthetic cases](fixtures/cleanup-cases.json)
- [Exact production messages and Python token IDs](fixtures/cleanup-prompts.json)
- [Python outputs](evidence/cleanup/python.jsonl) and [Swift outputs](evidence/cleanup/swift.jsonl)
- [Comparison and guard decisions](evidence/cleanup/summary.json)
- [Hashes, dependency pins and power state](evidence/cleanup/provenance.json)
- [Build and run timings](evidence/cleanup/commands.json)
- [Failure-path checks](evidence/cleanup/validation.json)

The checkpoint came from the existing local directory
`~/.local/share/dictate/models/mlx-community--Qwen2.5-1.5B-Instruct-4bit`.
Its weight SHA-256 is
`0979f33d1bc58afcf696d13f57977644e7b11a6f0eec3e631d8e9463d18c0717`.
Swift uses MLX Swift 0.32.3, mlx-swift-lm revision
`efcedcd4cd245eb03b65050a6bd2c103d7252d42`, and Swift Transformers 1.3.5.
The tokenizer adapter implements mlx-swift-lm 3's tokenizer protocols using the
same Swift Transformers package already used by the speech spike. Python uses
the installed production environment's Python 3.13.14, MLX 0.32.0 and mlx-lm
0.31.3, invoking `stt_service.local_model.LocalModel` directly.

Dependency resolution took 55.93 s; the final pinned cached resolution took
2.90 s. The release build passed in 77.46 s, reusing the prior MLX/Metal build.
The checked-in prompt fixture was regenerated from production code and matched
byte for byte. Usage and missing-model checks returned exit codes 2 and 1.
Deliberately corrupting the expected input tokens caused the Swift executable
to stop before generation with exit code 1. The summary also rejected a missing
result row and a mismatched token sequence. No broad production test suite was
run; production sources are unchanged.
The original speech spike also still builds with the extended package (7.71 s),
and the installed service reported both speech and cleanup ready afterward.
