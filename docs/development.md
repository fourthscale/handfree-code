# Developing handfree-code

How to change the plugin, test it and try it for real. [architecture.md](architecture.md) explains how it works.

## Layout

| Path | What it is |
|---|---|
| `bin/handfree.js` | the plugin: hooks, reader, voice commands (JavaScript for Automation, run by `osascript`) |
| `bin/hook.sh` | entry point of every hook: `handfree.js` on a Mac, `cloud-hook.py` elsewhere |
| `bin/bridge-server.py`, `bin/cloud-hook.py`, `bin/cloud-setup.sh`, `bin/install-bridge.sh` | the bridge for cloud sessions |
| `bin/listener.py` | the spoken-commands listener (Vosk, offline) |
| `bin/voice-commands.json` | the spoken commands: what each runs, and their default phrases per language (read by the listener and the app) |
| `bin/install-listener.sh` | installs or updates it: Python environment, model, login service |
| `bin/set-question-transport.sh` | switches how local sessions reach the dictation, and declares the `handfree` MCP server |
| `bin/mcp-relay.sh` | the `handfree` MCP server: stdio lines to the app's local address |
| `bin/install.sh` | installs everything (scripts, app, listener, MCP server); `/handfree-code:install` |
| `app/` | the Handfree Code app (Swift): `Package.swift`, `Sources/` (one file per part, listed in architecture.md, *The app*), `Resources/fr.lproj` and `de.lproj`, `install.sh` builds and installs it |
| `bin/speak-openai.sh` | example `speak_command` (another voice) |
| `hooks/hooks.json` | which hook runs what |
| `commands/install.md`, `commands/vocal.md`, `commands/listener.md`, `commands/bridge.md` | the `/handfree-code:install`, `/handfree-code:vocal`, `/handfree-code:listener` and `/handfree-code:bridge` commands |
| `tests/unit.js`, `tests/run.sh`, `tests/bridge.sh` | the tests: the pure logic of `handfree.js`, then everything end to end, then the bridge |
| `.claude-plugin/` | plugin manifest and local marketplace |

## Conventions

Their short form for Claude Code is in `.claude/rules/`: `project.md` and `testing.md` always apply, the others when their files are touched (`paths`). A convention changed here is changed there too.

- **English everywhere** in the repository: code, comments, docs, tests, commit messages. Only the phrases spoken to the user are translated, in `bin/voice-commands.json` and `TEXTS` at the top of `handfree.js` (French, English, German). The texts sent to Claude in the user's language (`TEXTS.<language>.claude`) have French and English; other languages get the English.
- **No personal data**: no names of companies, hostnames, keys or paths of a particular user. The author's name only appears as the author.
- **Short comments that say why**, one or two lines, as in the existing code.
- **Simple over clever**: when something gets complicated for a small gain, say so and leave it out.
- **The README follows the behaviour**: a change the user can notice updates its *Usage*, *Settings* or *Known limitations*.
- **A new setting** goes in `DEFAULTS` with a comment, in the README's settings table, and in `CLOUD_OVERRIDABLE` only if it is harmless coming from a cloud session. A setting read by another program keeps its default there too, where it is read: `listener.py` in its `config.get(…, default)` calls, `bridge-server.py` in its constants after reading the config, `speak-openai.sh` as `setting`'s second argument, and the app in each control of its settings (`settings.number("…", default)` in `SettingsWindow.swift`). Change both when a default changes.
- **A new state field** must be optional (missing means off): sessions still on an older version share the same state file. A field is never renamed, and `STATE_VERSION` never bumped. A field another program reads goes in the *Read by* column of architecture.md's state table.
- **The hold** changes only through `hold`, `releaseHold` and `releaseHoldOf` in `handfree.js`, never by setting its fields.
- **A new script** for the stable copy goes in `STABLE_FILES` in `handfree.js`, the one list SessionStart and the installers copy.

### Adding a language

1. `TEXTS` in `bin/handfree.js`: its `spoken` phrases and its `words` (yes, no, "the rest", "the details", the app's Send button); `claude` only if Claude should be told things in it (otherwise English).
2. `bin/voice-commands.json`: the commands' default phrases.
3. `bin/listener.py`: its Vosk model in `MODELS`.
4. The app: `app/Resources/<language>.lproj` (`Localizable.strings`, `InfoPlist.strings`), `CFBundleLocalizations` in `app/install.sh`, the language pickers in `SettingsWindow.swift`, and Whisper's phantom phrases in that language (`phantomPattern`, `DictationSession.swift`).
5. The README's languages, and a check in `tests/run.sh` that the language's phrases are read.

### Adding a voice command

1. `bin/voice-commands.json`: its id, the `handfree.js` argument it runs, its phrases per language.
2. `bin/handfree.js`: the function, in `COMMANDS`; in `RUNS_WHEN_OFF` only if it must also run with voice mode off.
3. `bin/listener.py`: in `WHILE_SPEAKING` or `WHILE_DICTATING` if it is heard then too (otherwise only when nothing goes on).
4. The app: its title and description in `VoiceCommands.all` (`VoiceCommands.swift`), with their French and German lines.
5. The README's commands, and checks in `tests/run.sh`.

## Tests

```bash
tests/run.sh
tests/bridge.sh
```

Run them **outside Claude Code's sandbox**: the sandbox blocks the folders they use. They take free ports, so both can run at once. Both are silent: a fake `say` (`tests/fake-say.sh`) writes what would be spoken to a file, and state and settings live in a scratch folder.

`tests/run.sh` starts with `tests/unit.js`: `handfree.js` loaded in another script, its pure functions checked in a second, with no voice, process or wait (the text read aloud, the answers, the reading plan before a question, the hold, the reader's next line). A new pure function, or a rule decided from text alone, gets its check there; what involves hooks, processes or timing stays in `run.sh`. The names it uses are listed in its `NAMES`.

Environment variables let the tests stand in for the Mac:

| Variable | Replaces |
|---|---|
| `HANDFREE_STATE_DIR`, `HANDFREE_CONFIG` | the state folder and the settings file |
| `HANDFREE_SAY_LOG`, `HANDFREE_FAKE_SAY_SECONDS` | where the fake `say` writes, and how long it takes to speak |
| `HANDFREE_IDLE_SECONDS` | keyboard and mouse idle time |
| `HANDFREE_AUDIO_PLAYING`, `HANDFREE_NOW_PLAYING`, `HANDFREE_MEDIA_KEY_LOG` | music detection and the play/pause key |
| `HANDFREE_MEDIA_CONTROL` | the media-control program (empty: none) |
| `HANDFREE_OPEN_LOG` | links opened and apps brought back are written there instead; no click or key either |
| `HANDFREE_APP_SESSIONS_DIR` | the Claude app's session files |
| `HANDFREE_FRONT_APP` | the app in front (empty: none) |
| `HANDFREE_PROMPT_REACHABLE` | whether Claude's message field can be reached from another app (`1`/`0`) |
| `HANDFREE_PROJECTS_DIR`, `HANDFREE_RETURN_WAIT_SECONDS` | Claude Code's transcripts, and how long to wait for a sent message |
| `HANDFREE_DICTATION_URL`, `HANDFREE_DICTATION_UP` | the app's address, and whether it answers |
| `HANDFREE_APP_SECRET_FILE` | the app's local secret (`~/Library/Application Support/handfree-code/app-secret`) |
| `HANDFREE_CLAUDE_JSON` | Claude Code's `~/.claude.json`, where the `handfree` MCP server is declared |
| `HANDFREE_NO_KEYS` | `1`: the listener never presses keys through System Events |
| `HANDFREE_QUESTION_WAIT_SECONDS` | how long a question or a permission waits for another dictation (90 s and 40 s) |
| `HANDFREE_QUESTION_READING_SECONDS` | how long after it starts the question hook stops reading the text before the question (85 s) |
| `HANDFREE_SUPPORT_DIR`, `HANDFREE_LAUNCH_AGENTS_DIR`, `HANDFREE_RESTART_LOG` | the stable copy, the login services, and the services restarted (written there instead) |
| `HANDFREE_CONTEXT` | `local` or `cloud` |
| `HANDFREE_BRIDGE_PORT`, `HANDFREE_BRIDGE_LOG` | the bridge's port and log (`tests/bridge.sh`) |
| `HANDFREE_HOOK_LOG` | the cloud hook's log (`/tmp/handfree-hook.log` in a cloud session) |
| `HANDFREE_SCRIPT`, `HANDFREE_APP_PORT`, `HANDFREE_AUDIO_PORT` | for the listener: the `handfree.js` it runs, the app's address and the port the app sends the sound to |

Each behaviour gets a check in `tests/run.sh`, with a name that says what should happen. What needs a real screen ("Claude Listen" clicking the field, the app pasting) is tried by hand.

## Trying a change for real

1. Bump `version` in `.claude-plugin/plugin.json`: without it, the update is not picked up.
2. Install it:
   ```bash
   claude plugin marketplace update handfree-code
   claude plugin update handfree-code@handfree-code
   ```
3. Open a **new session**: hooks are loaded when a session starts, and it also refreshes the stable copy the voice commands run. Sessions already open keep the old version.
4. A change to the app (`app/`): `sh app/install.sh` rebuilds, signs and restarts it (a few seconds once its packages are built). It has no automated tests: the build must pass, then try the pill, a question and the settings by hand. New interface text is written in English and gets its French and German lines in `app/Resources/fr.lproj/Localizable.strings` and `de.lproj`.

After changing `bin/listener.py` or `bin/voice-commands.json` (or `bin/bridge-server.py`), a new session copies them and restarts the listener (or the bridge). The tests use a stable copy and services of their own (`HANDFREE_SUPPORT_DIR`, `HANDFREE_LAUNCH_AGENTS_DIR`, `HANDFREE_RESTART_LOG`), never the real ones. To try the listener at once: `cp bin/listener.py bin/voice-commands.json ~/Library/Application\ Support/handfree-code/ && launchctl kickstart -k "gui/$(id -u)/com.handfree-code.listener"`. `python3 bin/listener.py --check "<phrase>"` prints what it would do with a phrase, given the current state.

## Debugging

- **What was said**: nothing is logged on the Mac; the state file (`~/Library/Caches/handfree-code/state.json`) shows the queue, the reader and any dictation under way.
- **The listener**: set `"listener_log": true`, restart it, read `~/Library/Logs/handfree-listener.log` (each phrase heard and why it was ignored).
- **Dictating with Claude behind**: set `"dictation_log": true`, then read `~/Library/Caches/handfree-code/dictate-behind.log` (each step, and why the usual way was taken).
- **Cloud sessions**: `/tmp/handfree-hook.log` in the cloud session (one line per hook) and `~/Library/Logs/handfree-bridge.log` on the Mac.
- **A voice command that does nothing**: usually an Accessibility permission; see the README's *Troubleshooting*.
