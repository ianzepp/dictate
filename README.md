# Dictate

Hold a key, talk, let go. Dictate records your voice, turns it into text with a local Whisper model, tidies the text with a small local language model, and pastes it into whatever window you are typing in. Nothing leaves your Mac.

## Using it

- **Hold Fn and talk. Let go to paste.** A small overlay at the bottom of the screen shows Listening with a live microphone level, then Transcribing, then Pasted. It floats over full-screen apps and never takes focus.
- **Lock for long dictation.** Add Right Option while holding Fn, and you can let go of both keys. See [Hotkeys](#hotkeys).
- **Cancel.** Click the ✕ on the overlay. Nothing is pasted.
- **Change your mind.** Letting go without saying anything pastes nothing. The overlay shows Nothing heard.
- **Music fades out while you talk.** While you record, Dictate fades your Mac's output to silent, so the microphone hears you and not the song, then fades it back when you let go. If you change the volume yourself mid-dictation, yours is kept.
- **The menu-bar icon** shows the current state and the last five transcripts. Click one to copy it.

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

If you keep Fn as the hold key, it needs one macOS setting; see setup step 6.

Two cleanups happen between your voice and the paste. Your own `[replacements]` fix words Whisper keeps getting wrong. Then a small language model fixes punctuation and drops filler words such as um. If that model fails, or its answer drifts away from what you said, Dictate pastes the uncleaned text instead.

## How it fits together

| Part | Port | What it runs | LaunchAgent |
| --- | --- | --- | --- |
| Speech service | 8090 | Whisper large-v3 turbo on MLX (`stt_server.py`) | `com.ianzepp.dictate.speech` |
| Cleanup model | | Qwen2.5 1.5B Instruct on MLX, run inside the speech service | |
| Menu-bar app | | `Dictate.app`: the hotkeys, the overlay, and the paste | `com.ianzepp.dictate` |

Both LaunchAgents start at login and restart if they stop.

## Requirements

- An Apple Silicon Mac on macOS 14 or newer.
- Python 3.11 or newer.
- Xcode Command Line Tools, for `swift`: `xcode-select --install`.
- About 1.3 GB of disk for the two models.

## Setup

Clone this repository, then run these from its root.

1. Install the Python packages.

   ```bash
   python3 -m venv .venv
   .venv/bin/pip install -r requirements.txt
   ```

2. Copy the config. The defaults work as they are.

   ```bash
   mkdir -p ~/.config/dictate
   cp config.example.toml ~/.config/dictate/config.toml
   ```

3. Make a signing certificate, once. macOS ties the Microphone, Input Monitoring, and Accessibility permissions to the app's signature. Without a stable certificate, every rebuild looks like a new app and you have to grant them again.

   Open Keychain Access, then Keychain Access > Certificate Assistant > Create a Certificate. Name it `Dictate Local Code Sign`, set Identity Type to Self-Signed Root and Certificate Type to Code Signing, and create it in the login keychain.

4. Build the app and start everything.

   ```bash
   dictate/scripts/build-app.sh
   launchd/install.sh
   ```

   `install.sh` checks the config, fills in this Mac's paths, and starts the speech service and the app. Set `PYTHON` before it if your Python lives somewhere else.

   The first start downloads both models, about 1.3 GB, in about a minute on a fast connection. The menu-bar card shows Downloading speech model until dictation is ready; until the cleanup model follows, dictation pastes Whisper's text uncleaned.

5. Grant permissions. macOS asks for Microphone access on first use. Add Dictate under System Settings > Privacy & Security > Input Monitoring, and again under Accessibility. Then restart the app:

   ```bash
   launchctl kickstart -k gui/$(id -u)/com.ianzepp.dictate
   ```

6. Free up the Fn key, if it is your hold key. In System Settings > Keyboard, set "Press 🌐 key to" to Do Nothing. Otherwise Fn also opens the emoji picker or Apple's dictation.

## Config

`~/.config/dictate/config.toml`. The speech service and the menu-bar app both read it. `config.example.toml` explains every setting.

- `[speech] model` and `[cleanup] model` take a Hugging Face name, downloaded on first start, or a path to files you already have.
- `[cleanup]` can instead point at a model server you already run, such as LM Studio or Ollama, with `url` and `name`. `enabled = false` skips cleanup.
- `[hotkey] key` and `[hotkey] lock` choose the hold and lock keys. See [Hotkeys](#hotkeys).
- `[replacements]` maps a phrase Whisper hears to the spelling you want, such as `"em el ex" = "MLX"`. These apply on the next dictation.
- `[debug] enabled = true` saves each dictation under `~/Library/Logs/Dictate/debug/<timestamp>/`: the audio, the speech text, and the cleaned text.

Everything except replacements applies after a restart:

```bash
launchctl kickstart -k gui/$(id -u)/com.ianzepp.dictate.speech   # speech and cleanup models
launchctl kickstart -k gui/$(id -u)/com.ianzepp.dictate          # hotkey, lock key, debug
```

## Troubleshooting

The menu-bar card says what is wrong and where to fix it. It checks the speech service every ten seconds and whenever you open the menu. Logs are in `~/Library/Logs/Dictate/`: `stt.err.log` for the speech service and both models, and `dictate.err.log` for the app.

- **Nothing happens when you hold Fn.** Dictate needs Input Monitoring. Grant it, then restart the app.
- **Fn opens the emoji picker or Apple's dictation.** See setup step 6.
- **The text is copied but not pasted.** Dictate needs Accessibility. Grant it, then restart the app.
- **The permissions vanish after a rebuild.** The signing certificate is missing, and `build-app.sh` printed a warning. See setup step 3.
- **Background music shows up in the text.** Dictate turns the output volume down while recording, but some outputs, such as HDMI displays and some USB audio devices, have no volume macOS can change. Lower the music yourself, or use headphones.
- **The volume stayed low.** If Dictate stopped in the middle of a dictation, it puts the volume back when it restarts, within about ten seconds. If you changed the volume since, it leaves yours alone.
- **The first dictation after a restart is slow.** Metal compiles its kernels on first use. Later ones are fast.
- **The card says Speech service not running.** Check `stt.err.log`. A broken config is the usual cause; `launchd/install.sh` checks it and says what is wrong.
- **The card says Speech model unavailable.** The download failed, for example with no internet connection. It retries every 30 seconds.
- **The card says Cleanup is off.** Dictation still works, but pastes Whisper's text uncleaned. The card says why: the cleanup model failed to download or load, which retries every 30 seconds, or the model server in `[cleanup] url` is not answering. Details are in `stt.err.log`.

## Updating

```bash
git pull
.venv/bin/pip install -r requirements.txt
dictate/scripts/build-app.sh
launchd/install.sh
```

## Uninstalling

```bash
launchctl bootout gui/$(id -u)/com.ianzepp.dictate.speech
launchctl bootout gui/$(id -u)/com.ianzepp.dictate
rm ~/Library/LaunchAgents/com.ianzepp.dictate.speech.plist ~/Library/LaunchAgents/com.ianzepp.dictate.plist
```

Then delete the models in `~/.local/share/dictate`, the logs in `~/Library/Logs/Dictate`, and the config in `~/.config/dictate`.

## Development

Run the speech service in the foreground, and send it an audio file. It listens at once and readies both models in the background; `GET /health` reports progress.

```bash
./start.sh
.venv/bin/python transcribe.py audio.wav
```

`download_model.py` fetches a model ahead of time, for example before going offline: `.venv/bin/python download_model.py mlx-community/Qwen2.5-1.5B-Instruct-4bit`. With no name it fetches the default speech model.

Tests:

```bash
.venv/bin/python -m unittest discover -s tests
cd dictate && swift test
```

## License

MIT. See `LICENSE`.
