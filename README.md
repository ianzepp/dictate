# Local dictation

A speech service on this Mac, and a menu-bar app that holds a key, records, and pastes the cleaned text into the focused window.

Two servers, both local:

| Job | Port | Process |
| --- | --- | --- |
| Speech | 8090 | Whisper Turbo, `com.ianzepp.stt` |
| Cleanup | 8091 | Qwen2.5 1.5B Instruct, `com.ianzepp.stt.2pass` |

The speech service applies keyword replacements, then asks the cleanup server to fix grammar. One paste happens after both passes. If cleanup fails, the paste is the literal-replaced transcript. Splash on port 8000 is a different service and is not on this path.

## Config

`~/.config/stt-service/config.toml`, copied from `config.example.toml`.

The service and the menu-bar app both read it. Replacements are reread on every utterance. The endpoints, the model path, and the hotkey apply on restart.

The talk key for testing is `right_option`. `fn` is the same hold path. It is exclusive only after the other Fn binding is removed, and only if the Globe key is not set to start Dictation.

`[debug] enabled = true` makes the menu-bar app write each hold to `~/ai/logs/stt-debug/<timestamp>/`: `01-audio.wav`, then `02-phase1.txt`, then `03-phase2.txt`, and then it pastes. A failed step leaves `error.txt` beside whatever was saved. Set `enabled` to `false` and relaunch to stop writing.

## Run in the foreground

```bash
./start.sh
python transcribe.py audio.wav
```

`./start.sh` loads the model before it listens on `127.0.0.1:8090`. The first utterance still compiles Metal kernels.

## Menu bar

```bash
dictate/scripts/build-app.sh
open dictate/dist/Dictate.app
```

The app needs Microphone, Input Monitoring, and Accessibility. `build-app.sh` signs with the local certificate `Dictate Local Code Sign` when that identity is in the login keychain, so the Accessibility grant survives a rebuild.

## Login

The plists in `launchd/` start the cleanup server, the speech server, and the menu-bar app at login.

```bash
dictate/scripts/build-app.sh
launchd/install.sh
```

`com.ianzepp.stt.2pass` keeps the cleanup model up. `com.ianzepp.stt` keeps the speech service up. `com.ianzepp.stt.dictate` opens the menu-bar app at login.
