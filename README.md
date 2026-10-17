# handfree-code

Drive Claude Code by voice on macOS, hands free.

- **Claude talks to you**: replies and questions are read aloud, with the name of the session speaking. Only the first paragraph is read by default; the rest waits until you say "Continue".
- **You talk to Claude**: you dictate with [Spokenly](https://spokenly.app) and send by saying "stop". Claude's questions go through Spokenly, and you answer them aloud.
- **You steer the reading** with a few words: Listen, Stop, Quiet, Continue, Restart, Voice mode.

The plugin sets up the whole Claude Code side. The macOS side (Shortcuts, Voice Control commands, permissions) is done by hand, once: macOS does not let a program grant itself these rights.

Tested on macOS 14.4.1 with the Claude desktop app. The plugin itself only relies on what macOS ships (`osascript`, `say`); the optional cloud bridge also needs `/usr/bin/python3`.

## Requirements

- macOS and the Claude desktop app (Claude Code in a terminal works too, see *Settings*).
- [Spokenly](https://spokenly.app) (the free tier is enough), with its MCP server declared in Claude Code as `spokenly` (Spokenly offers this in its settings).
- Two microphones: your headphones' for Spokenly, the Mac's for Voice Control. With a single microphone they fight over it.
- Headphones, preferably: without them the Mac's microphone hears the reading voice, and a command word read aloud by Claude can trigger on its own.

**Privacy.** Depending on the transcription model chosen in Spokenly, your voice may be sent to an online service. Check the model in its settings. The plugin itself contacts no service: everything happens on the Mac (see *Cloud sessions* for the optional bridge).

## Installation

### 1. The plugin

```
/plugin marketplace add https://github.com/fourthscale/handfree-code.git
/plugin install handfree-code@handfree-code
```

Then open a new session: on start, the plugin drops a copy of its scripts in `~/Library/Application Support/handfree-code/`. That path, stable across versions, is what the Shortcuts call.

### 2. The voice

System Settings > Accessibility > Spoken Content > **System voice**: pick a voice in your language and its rate. The plugin uses that voice unless you set one in *Settings*.

### 3. Spokenly

- Microphone: your headphones'.
- Dictation shortcut: **double tap on right Command**, in toggle mode (one tap starts, one tap stops). If you choose another one, set `spokenly_trigger` to `none` and start Spokenly yourself.
- Leave Spokenly's own "read the question aloud" option off: the plugin does it, and both would overlap.
- Shorten Claude Code's wait on Spokenly: an unanswered question otherwise blocks the session for 30 minutes. Add `"timeout": 120000` (2 minutes) to the `spokenly` entry of `mcpServers` in `~/.claude.json`.

### 4. Shortcuts (Shortcuts app)

Create one shortcut per file of the [`shortcuts/`](shortcuts) folder, pasting its content into the action named at the top of the file:

| Shortcut | Action | File |
|---|---|---|
| Listen | Run Shell Script | `listen.sh` |
| Press Return | Run AppleScript | `press-return.applescript` |
| Quiet | Run Shell Script | `quiet.sh` |
| Continue | Run Shell Script | `continue.sh` |
| Restart | Run Shell Script | `restart.sh` |
| Voice mode | Run Shell Script | `voice-mode.sh` |

Run each one once from the Shortcuts app: macOS then asks for permissions; accept them.

### 5. Voice commands (Voice Control)

System Settings > Accessibility > Voice Control: turn it on, with the **Mac's** microphone. Then Commands… > "+", for each command: "While using: Any Application", "Perform: Run Shortcut".

| You say | Shortcut |
|---|---|
| Listen | Listen |
| Stop | Press Return |
| Quiet | Quiet |
| Continue | Continue |
| Restart | Restart |
| Voice mode | Voice mode |

The words are yours to choose, in any language; keep the "Stop" word identical to the `validation_word` setting.

Then switch Voice Control to **command mode** (search "mode" in the command list for the phrase in your language): otherwise it types everything it hears into Claude's field, the reading voice included.

To switch sessions by voice, add commands limited to Claude with "Press Keyboard Shortcut": new session ⌘N, next session ⌘⇧], previous ⌘⇧[, search ⌘⇧K (from Claude's menus; keys differ on non-US keyboards).

### 6. Permissions (Privacy & Security)

In **Accessibility**, enable, adding them with "+" when needed (⌘⇧G to paste a path):

- Shortcuts (in Applications);
- `/System/Library/CoreServices/Shortcuts Events.app`;
- `/System/Library/Input Methods/DictationIM.app`: the dictation module macOS holds responsible for keys sent by a voice command. Without it, a command works once and then fails at random.

Also accept, when they show up, permission to **control System Events** and **microphone** access for Spokenly and Voice Control.

The `DictationIM.app` path may differ on other macOS versions. If a voice command fails, *Troubleshooting* shows how to find the refused program.

## Usage

- **Listen** → dictate → **Stop**: the message goes to the session on screen. "Listen" brings Claude forward and puts the cursor in its field, wherever you are.
- A question from Claude: it is read ("Session X. A question. …"), you answer, **Stop** sends. The answer always goes back to the session that asked.
- At the end of a reply: the first paragraph is read, followed by "There is more" when text remains. **Continue** reads the rest, **Restart** reads it all again, **Quiet** cuts it (say it in a pause between two lines).
- Several sessions: readings wait their turn. A session's name is said when the speaker changes, not each time the same session talks again. Nothing is read while you dictate.
- A session started by another one does not read its reply: the one that started it relays it. If you talk to it yourself, it answers aloud.
- **Away from the Mac** (on your phone, say): when keyboard and mouse have been idle for `away_after_idle_seconds`, the plugin refuses the Spokenly call, which would wait on a Mac you are not at, and the session asks in writing.
- **Cloud sessions**: without the bridge, nothing is read and their questions stay written (dictating to them works: the field is on your Mac). With the bridge, everything works as locally: see *Cloud sessions: the bridge*.
- **Permission prompts by voice** (opt-in, `voice_permissions`): the request is read ("Permission requested: git commit. Allow?"), Spokenly listens, a clear "yes" allows and a clear "no" denies. Anything else, or when you are away, leaves the usual dialog on screen. Deny rules you configured still win. Keep it off if a misheard "yes" is a risk you do not want.
- **Voice mode**, or `/vocal [on|off]` in Claude: turns everything off or back on. Off, the queue is emptied and new sessions get no voice rules.

## Cloud sessions: the bridge (optional)

A cloud session runs on a Linux machine: without the bridge it stays silent and its questions stay written. With the bridge, its hooks and its Spokenly questions travel through a tunnel to your Mac, and everything works as locally, as long as you are in the room.

```
cloud session ──hooks──▶ https://your-tunnel/hook ──▶ Mac service ──▶ reading, queue
              ──MCP────▶ https://your-tunnel/mcp  ──▶ Mac service ──▶ Spokenly (localhost:51089)
```

1. **The Mac service**: `sh bin/install-bridge.sh` writes a secret token and an edge key to `~/.config/claude-speak.json` and starts the service at login (port 8765, listening locally only). It refuses any request without the token. `--uninstall` removes it. It uses `/usr/bin/python3` (Apple's command line tools).
2. **A tunnel** to `http://localhost:8765`, with a fixed address: Cloudflare Tunnel, ngrok, Tailscale Funnel… With Cloudflare on a protected domain, add a WAF "Skip" rule and a configuration rule (security level at its lowest, browser integrity check off) for that hostname only: the bot challenge page would block the cloud session.
3. **A key checked by the tunnel** (recommended): every call to the bridge carries the `X-Handfree-Key` header, with the value of `bridge_edge_key`. Have the tunnel block any request without the right value: then nothing reaches the Mac. With Cloudflare, a custom WAF rule placed **before** the "Skip" rule:
   ```
   (http.host eq "<your-tunnel>" and not any(http.request.headers["x-handfree-key"][*] eq "<value>"))  →  Block
   ```
4. **The cloud environment** (claude.ai, environment settings):
   - variables: `HANDFREE_BRIDGE_URL` (the tunnel's address), `HANDFREE_BRIDGE_TOKEN` (the value of `bridge_token`) and, with step 3, `HANDFREE_BRIDGE_EDGE_KEY` (the value of `bridge_edge_key`);
   - network: allow `github.com` and the tunnel's hostname if the environment filters outbound traffic;
   - setup script:
     ```
     curl -fsSL https://raw.githubusercontent.com/fourthscale/handfree-code/main/bin/cloud-setup.sh | bash
     ```
     It installs the plugin and declares Spokenly at the tunnel's address, with the token and the key. It never fails: with a piece missing, the session just stays silent.

Reading settings are the Mac's (`~/.config/claude-speak.json`): the Mac reads and asks. A cloud environment can change a few of them for its sessions with the optional `HANDFREE_OVERRIDES` variable, in JSON, for instance `{"first_paragraph_only": false, "language": "en"}`. Only `language`, `voice`, `validation_word`, `first_paragraph_only`, `pause_between_lines_seconds` and `silence_around_title_ms` are accepted: nothing that would make the Mac run a program.

Without `HANDFREE_BRIDGE_URL`, the plugin stays silent in the cloud. Its hooks on the Mac never go through the bridge.

### How sessions reach Spokenly

The `question_transport` setting, separate for local and cloud sessions:

| Value | Effect |
|---|---|
| `mcp` | the session calls the `spokenly` MCP server it has declared (local default) |
| `bridge` | the session goes through the tunnel (cloud default); locally, it does without Spokenly's MCP relay |
| `none` | no spoken questions: they stay written |

A session only gets the voice rules when its transport can succeed: a declared server for `mcp`, a responding Spokenly app for `bridge`.

To change the local sessions' transport, and redeclare `spokenly` accordingly:

```
sh bin/set-question-transport.sh mcp|bridge|none
```

`bridge` locally needs `bridge_url` and `bridge_token` in the settings. For the cloud, the transport is set in `question_transport.cloud` on the Mac, and `spokenly` is declared by the environment's setup script.

Your sessions' text and access to your microphone go through the tunnel: pick a provider you already trust with that traffic, and never publish the token.

## Settings

All optional, in `~/.config/claude-speak.json`:

| Key | Default | Purpose |
|---|---|---|
| `language` | the Mac's | spoken phrases and rules: `fr`, `en` or `de` (otherwise English) |
| `voice` | system voice | name of a `say` voice to force |
| `validation_word` | `stop` | word that sends a dictation; sessions learn to ignore it at the end of a message |
| `first_paragraph_only` | `true` | `false` reads the whole reply right away |
| `pause_between_lines_seconds` | `1.2` | silence between two lines, where a voice command can get through |
| `silence_around_title_ms` | `800` | silence around the session's name |
| `announce_session` | `on_change` | say the session's name only when the speaker changes, or `always` |
| `max_dictation_seconds` | `180` | after a dictation abandoned without "Stop", reading resumes |
| `question_tool` | `mcp__spokenly__ask_user_dictation` | the questions tool named in the voice rules |
| `target_app` | `Claude` | app "Listen" brings forward; `iTerm2` or `Terminal` for Claude Code in a terminal |
| `click_prompt` | auto | click into the message field: by default only for the Claude app |
| `prompt_name` | `Prompt` | accessibility name of the Claude app's message field |
| `prompt_fallback` | `{"x_ratio": 0.6, "from_bottom": 55}` | point clicked when the field is not found |
| `spokenly_trigger` | `double_right_command` | or `none` |
| `activate_delay_seconds` | `0.5` | wait after bringing the app forward |
| `after_click_delay_seconds` | `0.3` | wait after the click |
| `double_tap_gap_seconds` | `0.12` | gap between the two taps |
| `away_after_idle_seconds` | `300` | past this much Mac idle time, questions go in writing |
| `voice_permissions` | `false` | answer permission prompts by voice |
| `permission_answer_seconds` | `90` | how long to wait for the spoken answer |
| `question_transport` | `{"local": "mcp", "cloud": "bridge"}` | how each kind of session reaches Spokenly: `mcp`, `bridge` or `none` |
| `bridge_url` | — | the tunnel's public address, for the local `bridge` transport |
| `bridge_token` | — | the bridge's token, created by `install-bridge.sh` |
| `bridge_edge_key` | — | value of the `X-Handfree-Key` header, checked by the tunnel; created by `install-bridge.sh` |
| `bridge_port` | `8765` | local port of the bridge service |

The questions hook reacts to any `mcp__…spokenly…__ask_user_dictation` tool. For another dictation tool, also change the `matcher` in `hooks/hooks.json`.

## How "Listen" finds the field

The Claude app's message field is found by its accessibility name, at the end of a remembered path (25 ms): it is clicked where it actually is, whatever the window size or screen. If that path no longer leads to the field (layout changed), the fallback point is clicked and the path is relearnt in the background (about 30 s), for next time.

## Troubleshooting

- **A voice command does nothing**: a permission dropped. Untick and tick the app again in Accessibility. To find which one, read the permissions log right after the failure:
  ```
  /usr/bin/log show --last 5m --style compact --predicate 'process == "tccd"' | grep -E "PostEvent|AUTHREQ_SUBJECT|AUTHREQ_RESULT"
  ```
  `authValue=0` followed by an `AUTHREQ_SUBJECT` names the refused program.
- **"Shortcuts is not allowed to send keystrokes"**: remove Shortcuts from the list ("−") and add it back. If needed, `tccutil reset Accessibility com.apple.shortcuts` makes macOS ask again.
- **Nothing is read**: check voice mode (`/vocal on`), then the system voice with `say hello`.
- **A hook added mid-session is ignored**: open a new session.

## What an update can break

- The Claude app may rename or translate its "Prompt" field: the fallback click takes over, and `prompt_name` can be set.
- Session titles and the detection of delegated turns read Claude Code's internal transcript format. If it changes, the plugin falls back to the simple behaviour: folder name instead of title, reply read rather than muted.
- The saved state carries a version number: a plugin version that does not recognise it starts over.

## Development

```
tests/run.sh
tests/bridge.sh
```

Silent tests: a fake `say` writes to a file; state and settings live in a scratch folder. Run them before every release. The "Listen" part (click, accessibility) is tested by hand.
