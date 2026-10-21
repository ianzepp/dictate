# Dictate

Hold a key, talk, let go. Dictate records your voice, turns it into text with a local Whisper model, tidies the text with a small local language model, and pastes it into whatever window you are typing in. Nothing leaves your Mac.

It has three parts, all local:

| Part | Port | What it runs | LaunchAgent |
| --- | --- | --- | --- |
| Speech | 8090 | Whisper large-v3 turbo on MLX (`stt_server.py`) | `com.ianzepp.stt` |
| Cleanup | 8091 | Qwen2.5 1.5B Instruct on llama.cpp | `com.ianzepp.stt.2pass` |
| Menu-bar app | | `Dictate.app`, which holds the key, shows the overlay, and pastes | `com.ianzepp.stt.dictate` |

The speech service applies your keyword replacements, then asks the cleanup model to fix punctuation and filler words. If cleanup fails or wanders off from what you said, the paste is the uncleaned transcript.

## Requirements

- An Apple Silicon Mac on macOS 14 or newer.
- Python 3.11 or newer.
- Xcode Command Line Tools, for `swift`: `xcode-select --install`.
- llama.cpp: `brew install llama.cpp`.

## Setup

Run these from the repository root.

1. Install the Python packages.

   ```bash
   python3 -m venv .venv
   .venv/bin/pip install -r requirements.txt
   ```

2. Download the two models into `~/.local/share/dictate/models/`.

   ```bash
   .venv/bin/python download_model.py
   .venv/bin/hf download bartowski/Qwen2.5-1.5B-Instruct-GGUF Qwen2.5-1.5B-Instruct-Q4_K_M.gguf --local-dir ~/.local/share/dictate/models
   ```

3. Copy the config.

   ```bash
   mkdir -p ~/.config/stt-service
   cp config.example.toml ~/.config/stt-service/config.toml
   ```

4. Make a signing certificate (once). macOS ties the Microphone, Input Monitoring, and Accessibility permissions to the app's signature. Without a stable certificate, every rebuild looks like a new app and you have to grant them again.

   Open Keychain Access, then Keychain Access > Certificate Assistant > Create a Certificate. Name it `Dictate Local Code Sign`, set Identity Type to Self-Signed Root and Certificate Type to Code Signing, and create it in the login keychain.

5. Build the app and start everything at login.

   ```bash
   dictate/scripts/build-app.sh
   launchd/install.sh
   ```

   `install.sh` fills in this Mac's paths and starts all three parts. Set `PYTHON`, `LLAMA_SERVER`, or `LLM_MODEL` before it if yours live somewhere else.

6. Grant permissions. On first run, macOS asks for Microphone access. Add Dictate under System Settings > Privacy & Security > Input Monitoring and > Accessibility, then restart it with `launchctl kickstart -k gui/$(id -u)/com.ianzepp.stt.dictate`.

7. Free up the Fn key. In System Settings > Keyboard, set "Press 🌐 key to" to Do Nothing. Otherwise Fn also opens the emoji picker or Apple's dictation.

Hold Fn and talk. A small overlay at the bottom of the screen shows Listening, then Transcribing, then Pasted.

## Config

`~/.config/stt-service/config.toml`. The speech service and the menu-bar app both read it.

- `[hotkey] key` picks the hold key: `fn`, `right_option`, `left_option`, `right_command`, `left_command`, `right_control`, or `right_shift`.
- `[replacements]` maps a phrase Whisper hears to the spelling you want, such as `"em el ex" = "MLX"`. These are reread on every utterance.
- Endpoints, models, and the hotkey apply after a restart.
- `[debug] enabled = true` makes the app save each dictation under `~/Library/Logs/Dictate/debug/<timestamp>/`: `01-audio.wav`, `02-phase1.txt` (speech), and `03-phase2.txt` (cleanup). A failed step leaves `error.txt` beside them.

Service logs are in `~/Library/Logs/Dictate/`.

## Run in the foreground

For testing without the LaunchAgents:

```bash
./start.sh
.venv/bin/python transcribe.py audio.wav
```

`./start.sh` loads the speech model before it listens on `127.0.0.1:8090`. The first utterance after a start is slower while Metal kernels compile.

## Tests

```bash
.venv/bin/python -m unittest discover -s tests
cd dictate && swift test
```

## License

MIT. See `LICENSE`.
