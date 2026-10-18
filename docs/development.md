# Developing handfree-code

How to change the plugin, test it and try it for real. [architecture.md](architecture.md) explains how it works.

## Layout

| Path | What it is |
|---|---|
| `bin/handfree.js` | the plugin: hooks, reader, voice commands (JavaScript for Automation, run by `osascript`) |
| `bin/hook.sh` | entry point of every hook: `handfree.js` on a Mac, `cloud-hook.py` elsewhere |
| `bin/bridge-server.py`, `bin/cloud-hook.py`, `bin/cloud-setup.sh`, `bin/install-bridge.sh` | the bridge for cloud sessions |
| `bin/listener.py` | the spoken-commands listener (Vosk, offline) |
| `bin/install-listener.sh` | installs or updates it: Python environment, model, login service |
| `bin/set-question-transport.sh` | switches how local sessions reach Spokenly |
| `bin/speak-openai.sh` | example `speak_command` (another voice) |
| `hooks/hooks.json` | which hook runs what |
| `commands/vocal.md`, `commands/listener.md` | the `/handfree-code:vocal` and `/handfree-code:listener` commands |
| `tests/run.sh`, `tests/bridge.sh` | the tests |
| `.claude-plugin/` | plugin manifest and local marketplace |

## Conventions

- **English everywhere** in the repository: code, comments, docs, tests, commit messages. Only the phrases spoken to the user are translated, in `PHRASES`, `SESSION_RULES`, `UNSPOKEN_QUESTION` and `AWAY` (French, English, German).
- **No personal data**: no names of companies, hostnames, keys or paths of a particular user. The author's name only appears as the author.
- **Short comments that say why**, one or two lines, as in the existing code.
- **Simple over clever**: when something gets complicated for a small gain, say so and leave it out.
- **The README follows the behaviour**: a change the user can notice updates its *Usage*, *Settings* or *Known limitations*.
- **A new setting** goes in `CONFIG` with a comment, in the README's settings table, and in `CLOUD_OVERRIDABLE` only if it is harmless coming from a cloud session.
- **A new state field** must be optional (missing means off): sessions still on an older version share the same state file.

## Tests

```bash
tests/run.sh
tests/bridge.sh
```

Run them **outside Claude Code's sandbox**: the sandbox blocks the folders they use. Both are silent: a fake `say` (`tests/fake-say.sh`) writes what would be spoken to a file, and state and settings live in a scratch folder.

Environment variables let the tests stand in for the Mac:

| Variable | Replaces |
|---|---|
| `HANDFREE_STATE_DIR`, `HANDFREE_CONFIG` | the state folder and the settings file |
| `HANDFREE_SAY_LOG` | where the fake `say` writes |
| `HANDFREE_IDLE_SECONDS` | keyboard and mouse idle time |
| `HANDFREE_AUDIO_PLAYING`, `HANDFREE_NOW_PLAYING`, `HANDFREE_MEDIA_KEY_LOG` | music detection and the play/pause key |
| `HANDFREE_OPEN_LOG` | links opened and apps brought back are written there instead; no click or key either |
| `HANDFREE_APP_SESSIONS_DIR` | the Claude app's session files |
| `HANDFREE_FRONT_APP` | the app in front (empty: none) |
| `HANDFREE_PROMPT_REACHABLE` | whether Claude's message field can be reached from another app (`1`/`0`) |
| `HANDFREE_PROJECTS_DIR`, `HANDFREE_RETURN_WAIT_SECONDS` | Claude Code's transcripts, and how long to wait for a sent message |
| `HANDFREE_SPOKENLY_URL`, `HANDFREE_SPOKENLY_UP` | Spokenly's address, and whether it answers |
| `HANDFREE_CONTEXT` | `local` or `cloud` |

Each behaviour gets a check in `tests/run.sh`, with a name that says what should happen. What needs a real screen ("Claude Listen" clicking the field, Spokenly typing) is tried by hand.

## Trying a change for real

1. Bump `version` in `.claude-plugin/plugin.json`: without it, the update is not picked up.
2. Install it:
   ```bash
   claude plugin marketplace update handfree-code
   claude plugin update handfree-code@handfree-code
   ```
3. Open a **new session**: hooks are loaded when a session starts, and it also refreshes the stable copy the voice commands run. Sessions already open keep the old version.

After changing `bin/listener.py`, a new session copies it and restarts the listener; to try it at once: `cp bin/listener.py ~/Library/Application\ Support/handfree-code/ && launchctl kickstart -k "gui/$(id -u)/com.handfree-code.listener"`. `python3 bin/listener.py --check "<phrase>"` prints what it would do with a phrase, given the current state.

## Debugging

- **What was said**: nothing is logged on the Mac; the state file (`~/Library/Caches/claude-speak/state.json`) shows the queue, the reader and any dictation under way.
- **The listener**: set `"listener_log": true`, restart it, read `~/Library/Logs/handfree-listener.log` (each phrase heard and why it was ignored).
- **Dictating with Claude behind**: set `"dictation_log": true`, then read `~/Library/Caches/claude-speak/dictate-behind.log` (each step, and why the usual way was taken).
- **Cloud sessions**: `/tmp/handfree-hook.log` in the cloud session (one line per hook) and `~/Library/Logs/handfree-bridge.log` on the Mac.
- **A voice command that does nothing**: usually an Accessibility permission; see the README's *Troubleshooting*.
