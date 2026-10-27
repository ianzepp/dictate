# Dictate

Hold a key, talk, let go. Dictate records your voice, turns it into text with a local Whisper model, optionally tidies the text with a small local language model, and pastes it into whatever window you are typing in. Both models run natively inside the Mac app. Nothing leaves your Mac.

## Using it

- **Hold Fn and talk. Let go to paste.** A small overlay at the bottom of the screen shows Listening with a live microphone level, then Transcribing, then Pasted. It floats over full-screen apps and never takes focus.
- **Lock for long dictation.** Add Right Option while holding Fn, and you can let go of both keys. See [Hotkeys](#hotkeys).
- **Cancel.** Click the ✕ on the overlay. Nothing is pasted.
- **Change your mind.** Letting go without saying anything pastes nothing. The overlay shows Nothing heard.
- **Music fades out while you talk.** While you record, Dictate fades your Mac's output to silent, so the microphone hears you and not the song, then fades it back when you let go. If you change the volume yourself mid-dictation, yours is kept.
- **The menu-bar icon** shows the current state and the last five transcripts. Click one to copy it.
- **Single or two passes.** By default Dictate pastes Whisper's text as heard, after your `[replacements]`. Check **Two-pass cleanup** in the menu to also run the text through the cleanup model. The choice is kept across launches.

## Hotkeys

Two keys do everything: the **hold key**, Fn by default, and the **lock key**, Right Option by default. Both can be changed; see [Using other keys](#using-other-keys). The table uses the defaults.

| You are | You do | What happens |
| --- | --- | --- |
| Idle | Hold Fn | Listening starts. |
| Listening | Let go of Fn | Recording stops, then it transcribes and pastes. |
| Listening | Press Right Option, still holding Fn | **Locked.** You can let go of both keys; recording continues. The overlay shows a lock. |
| Locked | Press or let go of Fn | Nothing. Fn is ignored while locked. |
| Locked | Press Right Option, with Fn up | **Unlocks and finishes.** It transcribes and pastes. |
| Locked | Press Right Option, with Fn held down | **Unlocks back to a normal hold.** Let go of Fn when you are done. |
| Listening or locked | Click ✕ on the overlay | Cancels. Nothing is pasted. |
| Idle | Press Right Option | Nothing. The lock key only matters during a recording. |

In practice:

- **A long dictation:** hold Fn, tap Right Option, let go of everything, and talk. Tap Right Option again to paste.
- **Changed your mind about locking:** while locked, hold Fn and tap Right Option. You are back to an ordinary hold; let go of Fn to paste.

A tap of Fn too quick to record anything, such as half of a double tap, is ignored. Dictate only watches these keys; the app you are typing in still receives them.

### Using other keys

Both keys are set in the config. For example, if Fn already does something else for you, hold Right Option to talk and use Right Command to lock:

```toml
[hotkey]
key = "right_option"
lock = "right_command"
```

Then restart the app with `launchctl kickstart -k gui/$(id -u)/com.ianzepp.dictate`. The menu card's hints, such as "Hold Right Option to dictate", use the new names.

Either key can be `fn`, `right_option`, `left_option`, `right_command`, `left_command`, `right_control`, or `right_shift`, and the two must differ. `lock = "none"` turns locking off. If you leave `lock` out, it defaults to Right Option, except when the hold key is itself Right Option; then locking is off until you name a lock key.

A hold key you also type with, such as Option for accented letters, starts a recording each time you hold it. Nothing is pasted, because there is no speech, but the overlay briefly shows Nothing heard.

If you keep Fn as the hold key, it needs one macOS setting; see setup step 5.

Up to two cleanups happen between your voice and the paste. Your own `[replacements]` fix words Whisper keeps getting wrong. If you turn on two-pass cleanup in the menu, a small language model then fixes punctuation and drops filler words such as um. It works a few sentences at a time, and a check keeps it honest: it may drop fillers, stutters, and a few small words, but not a content word, a pronoun, or a negation. If the model fails, or a piece comes back changed, Dictate pastes that piece uncleaned and cleans the rest.

## How it fits together

`Dictate.app` owns the hotkeys, recording, Whisper large-v3 turbo, optional Qwen2.5
1.5B cleanup, the overlay, and pasting. MLX runs the models on the Metal GPU away
from the UI thread. Model access is serialized, and a cancelled request cannot
paste its result.

One LaunchAgent, `com.ianzepp.dictate`, starts the app at login and restarts it
if it stops. There is no Python installation or local speech server to manage.

## Requirements

- An Apple Silicon Mac on macOS 14 or newer.
- Xcode with Swift 6.2 or newer and its Metal toolchain, to build from source.
- About 1.3 GB of disk for the two models.

## Setup

Clone this repository, then run these from its root.

1. Copy the config. The defaults work as they are.

   ```bash
   mkdir -p ~/.config/dictate
   cp config.example.toml ~/.config/dictate/config.toml
   ```

2. Make a signing certificate, once. macOS ties the Microphone, Input Monitoring, and Accessibility permissions to the app's signature. Without a stable certificate, every rebuild looks like a new app and you have to grant them again.

   Open Keychain Access, then Keychain Access > Certificate Assistant > Create a Certificate. Name it `Dictate Local Code Sign`, set Identity Type to Self-Signed Root and Certificate Type to Code Signing, and create it in the login keychain.

3. Build and install the app.

   ```bash
   dictate/scripts/build-app.sh
   launchd/install.sh
   ```

   The build creates an inactive, signed candidate. `install.sh` validates it,
   backs up the previous app and config, and switches the login job to it.
   When upgrading from Python it removes the obsolete `speech.port` setting
   and stops/removes the old speech LaunchAgent. Other config settings stay.

   If Xcode reports a missing Metal compiler, run
   `xcodebuild -downloadComponent MetalToolchain` once, then build again.

   The first start downloads both models, about 1.3 GB, if they are not already
   present. The menu card shows Downloading speech model until dictation is
   ready. Speech keeps working while cleanup downloads or is unavailable.

4. Grant permissions. macOS asks for Microphone access on first use. Add Dictate under System Settings > Privacy & Security > Input Monitoring, and again under Accessibility. Then restart the app:

   ```bash
   launchctl kickstart -k gui/$(id -u)/com.ianzepp.dictate
   ```

5. Free up the Fn key, if it is your hold key. In System Settings > Keyboard, set "Press 🌐 key to" to Do Nothing. Otherwise Fn also opens the emoji picker or Apple's dictation.

## Config

`~/.config/dictate/config.toml`. The app validates all settings.
`config.example.toml` explains them. The reader supports single-level tables,
single-line quoted strings, booleans, and comments. Unknown keys and duplicate
settings are errors.

- `[speech] model` and `[cleanup] model` take a Hugging Face name, downloaded on first start, or a path to files you already have.
- Native models need MLX safetensors weights. Older Whisper repositories that contain only `weights.npz` are unsupported; the default 4-bit models use safetensors.
- The default checkpoints are validated. Some older quantized Whisper variants also use a different embedding layout and cannot load in the current Swift SDK.
- `[cleanup]` can instead point at a model server you already run, such as LM Studio or Ollama, with `url` and `name`. `enabled = false` skips cleanup.
- `[hotkey] key` and `[hotkey] lock` choose the hold and lock keys. See [Hotkeys](#hotkeys).
- `[replacements]` maps a phrase Whisper hears to the spelling you want, such as `"em el ex" = "MLX"`. These apply on the next dictation.
- `[debug] enabled = true` saves each dictation under `~/Library/Logs/Dictate/debug/<timestamp>/`: the audio, the speech text, and the cleaned text.

Everything except replacements applies after a restart:

```bash
launchctl kickstart -k gui/$(id -u)/com.ianzepp.dictate
```

## Troubleshooting

The menu card shows each model's download, load, or failure state. Failed model
preparation retries every 30 seconds. Logs are in `~/Library/Logs/Dictate/`:
`dictate.err.log` for errors and `dictate.out.log` for model readiness changes.

- **Nothing happens when you hold Fn.** Dictate needs Input Monitoring. Grant it, then restart the app.
- **Fn opens the emoji picker or Apple's dictation.** See setup step 5.
- **The text is copied but not pasted.** Dictate needs Accessibility. Grant it, then restart the app.
- **The permissions vanish after a rebuild.** The signing certificate is missing, and `build-app.sh` printed a warning. See setup step 2.
- **Background music shows up in the text.** Dictate turns the output volume down while recording, but some outputs, such as HDMI displays and some USB audio devices, have no volume macOS can change. Lower the music yourself, or use headphones.
- **The volume stayed low.** If Dictate stopped in the middle of a dictation, it puts the volume back when it restarts, within about ten seconds. If you changed the volume since, it leaves yours alone.
- **The first dictation after a restart is slow.** Metal compiles its kernels on first use. Later ones are fast.
- **The card says Config problem.** Fix the named setting and restart. `launchd/install.sh` validates the file before replacing the app.
- **The card says Speech model unavailable.** Check the configured path or internet connection and `dictate.err.log`. It retries every 30 seconds.
- **The card says Cleanup is off.** Dictation still works with Whisper's text. Cleanup may be disabled, still downloading, unable to load, or unable to reach the server configured in `[cleanup] url`.

## Updating

```bash
git pull
dictate/scripts/build-app.sh
launchd/install.sh
```

## Uninstalling

```bash
launchctl bootout gui/$(id -u)/com.ianzepp.dictate
rm ~/Library/LaunchAgents/com.ianzepp.dictate.plist
```

Then delete the models in `~/.local/share/dictate`, the logs in `~/Library/Logs/Dictate`, and the config in `~/.config/dictate`.

## Development

`DictateCore` owns config and cleanup rules. `DictateInference` owns model
preparation, native inference and cancellation. The app owns recording and UI.
`DictateVerify` exercises the same engine without a microphone or pasteboard.

```bash
cd dictate
xcodebuild -scheme DictateVerify -configuration Release -destination 'platform=macOS' \
  -derivedDataPath .build/xcode -clonedSourcePackagesDirPath .build build CODE_SIGNING_ALLOWED=NO \
  ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO
.build/xcode/Build/Products/Release/DictateVerify ~/.config/dictate/config.toml audio.wav
```

Running `DictateVerify CONFIG` without an audio file prepares the configured
models ahead of offline use. It prints model status and fails if preparation
does not succeed.

Tests:

```bash
cd dictate
xcodebuild test -scheme Dictate-Package -configuration Release -destination 'platform=macOS' \
  -derivedDataPath .build/xcode -clonedSourcePackagesDirPath .build \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES
```

The cleanup tests contain a frozen Python-derived corpus. The old implementation
lives under `spikes/python-reference/` only as an experimental oracle, never as
an app runtime. The original spike evidence remains under `spikes/swift-speech/`.

## License

MIT. See `LICENSE`.
