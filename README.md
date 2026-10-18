# handfree-code

Drive Claude Code by voice on macOS, hands free.

- **Claude talks**: replies and questions are read aloud, with the name of the session speaking. Only the first paragraph is read; say "Claude Continue" for the rest.
- **You talk**: you dictate with [Spokenly](https://spokenly.app) and send by saying "stop". Claude asks its questions through Spokenly and you answer aloud.
- **You steer it** with a few spoken commands: "Claude Listen", "Claude Reply", "Claude Session", "Stop", "Claude Quiet", "Claude Continue", "Claude Restart", "Claude Voice mode on/off".

The plugin sets up Claude Code. The macOS side (Shortcuts, Voice Control, permissions) is done by hand, once: macOS does not let a program grant itself these rights.

Tested on macOS 14.4.1 with the Claude desktop app. It only relies on what macOS ships (`osascript`, `say`); the optional cloud bridge also needs `/usr/bin/python3`.

## Requirements

- macOS, the Claude desktop app and the `claude` command line (Claude Code in a terminal works too: see `target_app` in *Settings*).
- [Spokenly](https://spokenly.app); the free tier is enough.
- Two microphones: your headphones' for Spokenly, the Mac's for Voice Control. With a single microphone they fight over it.
- Headphones, preferably: otherwise the Mac's microphone hears the reading voice, and a command word read by Claude can trigger on its own.

**Privacy.** Depending on the model chosen in Spokenly, your voice may go to an online service. The plugin itself sends nothing anywhere, except to an online voice you choose (`speak_command`) and through the cloud bridge, if you set them up.

## Installation

### 1. The plugin

```bash
claude plugin marketplace add https://github.com/fourthscale/handfree-code.git
claude plugin install handfree-code@handfree-code
```

(Or, inside Claude: `/plugin marketplace add …` then `/plugin install handfree-code@handfree-code`.)

Then open a new session: it copies the plugin's scripts to `~/Library/Application Support/handfree-code/`, a path that stays the same across versions. The Shortcuts call the scripts there.

### 2. Spokenly

- Microphone: your headphones'.
- Dictation shortcut: **double tap on right Command**, in toggle mode. With another shortcut, set `spokenly_trigger` to `none`.
- Turn off Spokenly's own "read the question aloud": the plugin already reads it.
- Declare its MCP server in Claude Code:
  ```bash
  claude mcp add --scope user spokenly "$HOME/Library/Application Support/Spokenly/mcp-bridge.sh"
  ```
- Then, in `~/.claude.json`, add `"timeout": 120000` to the `spokenly` entry under `mcpServers`. Without it, an unanswered question blocks the session for 30 minutes.

### 3. The voice

System Settings > Accessibility > Spoken Content > **System voice**: pick a voice in your language and its rate.

**An online voice** (optional): `speak_command` points to a script that speaks the text it is given. One for OpenAI ships with the plugin. Add this to `~/.config/claude-speak.json`:

```json
{
  "speak_command": "~/Library/Application Support/handfree-code/speak-openai.sh",
  "openai_api_key": "<YOUR-OPENAI-KEY>"
}
```

Optional: `openai_voice` (default `alloy`), `openai_tts_model` (default `gpt-4o-mini-tts`). Each line costs a round trip, about half a second to a second. If the script fails, `say` reads the line. For another service, copy the script and change the request.

### 4. Shortcuts

In the Shortcuts app, create one shortcut per file of [`shortcuts/`](shortcuts) and paste the file's content into the action named on its first line:

| Shortcut | Action | File |
|---|---|---|
| Claude Listen | Run Shell Script | `listen.sh` |
| Claude Reply | Run Shell Script | `reply.sh` |
| Claude Session | Run Shell Script | `session.sh` |
| Stop | Run AppleScript | `stop.applescript` |
| Claude Quiet | Run Shell Script | `quiet.sh` |
| Claude Continue | Run Shell Script | `continue.sh` |
| Claude Restart | Run Shell Script | `restart.sh` |
| Claude Voice mode on | Run Shell Script | `voice-on.sh` |
| Claude Voice mode off | Run Shell Script | `voice-off.sh` |

Run each one once from the Shortcuts app and accept the permissions macOS asks for.

### 5. Voice commands

System Settings > Accessibility > Voice Control: turn it on, with the **Mac's** microphone. Then Commands… > "+", for each command: "While using: Any Application", "Perform: Run Shortcut".

| You say | Shortcut | What it does |
|---|---|---|
| Claude Listen | Claude Listen | brings Claude forward, clicks its field, starts Spokenly |
| Claude Reply | Claude Reply | the same, in the session that spoke last |
| Claude Session | Claude Session | opens the session search and starts Spokenly: say a session's name, then "Stop" |
| Stop | Stop | sends the dictation (presses Return) |
| Claude Quiet | Claude Quiet | cuts the reading |
| Claude Continue | Claude Continue | reads the rest of the reply |
| Claude Restart | Claude Restart | reads the reply again from the start |
| Claude Voice mode on | Claude Voice mode on | turns voice mode on |
| Claude Voice mode off | Claude Voice mode off | turns it off: nothing is read, questions stay written |

"Claude" in front keeps a word said in conversation from triggering a command. "Stop" stays short: you say it at the end of every dictation. Pick your own words, in any language; keep "Stop" the same as the `validation_word` setting.

Switch Voice Control to **command mode** (search "mode" in the command list): otherwise it types everything it hears into Claude's field, the reading voice included.

To switch sessions by voice, add commands limited to Claude, with "Press Keyboard Shortcut": new session ⌘N, next ⌘⇧], previous ⌘⇧[, search ⌘⇧K.

### 6. Permissions

System Settings > Privacy & Security > **Accessibility**: enable these, adding them with "+" when missing (⌘⇧G to paste a path):

- Shortcuts;
- `/System/Library/CoreServices/Shortcuts Events.app`;
- `/System/Library/Input Methods/DictationIM.app`: macOS holds it responsible for the keys a voice command sends. Without it, commands fail at random.

Accept, when asked, control of **System Events** and **microphone** access for Spokenly and Voice Control.

### 7. Check

```bash
say hello
```

Then, in a new Claude session: "ask me a question". The question is read, you answer in Spokenly, and the reply that follows is read.

## Usage

- **Claude Listen** → dictate → **Stop**: the message goes to the session on screen, wherever you were.
- **Claude Reply** → dictate → **Stop**: the message goes to the session that spoke last, even if another one is on screen. A cloud session cannot be opened this way: the session on screen gets it.
- **Claude Session** → say a session's name → **Stop**: that session opens. Then **Claude Listen**.
- **A question**: it is read ("Session X. A question. …"), you answer, **Stop** or Enter sends. The answer goes back to the session that asked.
- **A reply**: the first paragraph is read, then "There is more" if text remains. **Claude Continue** reads the rest, **Claude Restart** reads it all again, **Claude Quiet** cuts it (say it between two lines).
- **Several sessions**: readings wait their turn. A session's name is said when the speaker changes. Nothing is read while you dictate.
- **Music or a video**: paused while Claude speaks, resumed afterwards. Only the app the keyboard's play/pause key drives; if nothing plays, nothing is touched.
- **A session started by another one** stays quiet: the one that started it relays its result. Talk to it yourself and it answers aloud.
- **Away from the Mac** (keyboard and mouse idle for `away_after_idle_seconds`): questions are asked in writing instead.
- **Permission prompts by voice** (opt-in, `voice_permissions`): the request is read, a clear "yes" allows, a clear "no" denies, anything else leaves the dialog on screen. Your deny rules still win. Keep it off if a misheard "yes" is a risk.
- **Claude Voice mode off / on**, or `/vocal off|on` in Claude: turns everything off or back on.

## Updating

```bash
claude plugin marketplace update handfree-code
claude plugin update handfree-code@handfree-code
```

Then open a new session: hooks are only reloaded by a new session. With the bridge, restart its service so it runs the new version:

```bash
launchctl kickstart -k "gui/$(id -u)/com.handfree-code.bridge"
```

## Cloud sessions: the bridge (optional)

A cloud session runs on a Linux machine, far from your Mac's speakers and microphone. The bridge sends its hooks and its questions to your Mac through a tunnel, so it talks and listens like a local one.

```
cloud session ──hooks──▶ https://<HOSTNAME>/hook ──▶ bridge on the Mac ──▶ reading
              ──MCP────▶ https://<HOSTNAME>/mcp  ──▶ bridge on the Mac ──▶ Spokenly
```

Replace, in the commands below:

| Pattern | Example |
|---|---|
| `<HOSTNAME>` | `voice.example.com`, on a domain managed by Cloudflare |
| `<TUNNEL>` | `handfree` |
| `<TUNNEL-ID>` | printed by `cloudflared tunnel create` |

### 1. The bridge on the Mac

```bash
git clone https://github.com/fourthscale/handfree-code.git
sh handfree-code/bin/install-bridge.sh
```

It generates two random keys in `~/.config/claude-speak.json`: `bridge_token` (checked by the Mac) and `bridge_edge_key` (checked by Cloudflare). Then it starts the service at login, on `127.0.0.1:8765` only. `--uninstall` removes the service.

To copy a key to the clipboard without showing it:

```bash
plutil -extract bridge_token raw -o - ~/.config/claude-speak.json | pbcopy
plutil -extract bridge_edge_key raw -o - ~/.config/claude-speak.json | pbcopy
```

To change the keys: delete them from the file, run `install-bridge.sh` again, then update the WAF rule and the cloud environment.

### 2. The Cloudflare tunnel

```bash
brew install cloudflared
cloudflared tunnel login
cloudflared tunnel create <TUNNEL>
cloudflared tunnel route dns <TUNNEL> <HOSTNAME>
```

`~/.cloudflared/config.yml`:

```yaml
tunnel: <TUNNEL>
credentials-file: /Users/<YOU>/.cloudflared/<TUNNEL-ID>.json
ingress:
  - hostname: <HOSTNAME>
    service: http://localhost:8765
  - service: http_status:404
```

Start it at login:

```bash
cloudflared service install
```

Another tunnel (ngrok, Tailscale Funnel…) works too, as long as its address is fixed.

### 3. The Cloudflare rules

Cloudflare dashboard > your domain > Security > WAF > **Custom rules**, in this order ("Edit expression" to paste):

1. **Block requests without the key**: action *Block*.
   ```
   (http.host eq "<HOSTNAME>" and not any(http.request.headers["x-handfree-key"][*] eq "<BRIDGE-EDGE-KEY>"))
   ```
   Nothing without the key reaches your Mac.
2. **Let requests with the key through**: action *Skip*.
   ```
   (http.host eq "<HOSTNAME>" and any(http.request.headers["x-handfree-key"][*] eq "<BRIDGE-EDGE-KEY>"))
   ```
   Tick: all remaining custom rules, **all managed rules**, Super Bot Fight Mode, and under "More components to skip": Browser Integrity Check and Security Level.

The managed rules matter most: they read the commands and paths of a conversation as an attack, and answer 403 to every hook but the first. The free plan's Bot Fight Mode cannot be skipped by a rule: if it blocks the bridge, turn it off for the domain.

### 4. Check from outside

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://<HOSTNAME>/hook
```

`403`: Cloudflare blocks it, as it should without the key. With the key:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://<HOSTNAME>/hook -H "X-Handfree-Key: $(plutil -extract bridge_edge_key raw -o - ~/.config/claude-speak.json)"
```

`401`: the request reached your Mac, which refuses it without the token. Everything is in place.

### 5. The cloud environment

On claude.ai, in the cloud environment's settings:

- **Environment variables**:
  ```
  HANDFREE_BRIDGE_URL=https://<HOSTNAME>
  HANDFREE_BRIDGE_TOKEN=<BRIDGE-TOKEN>
  HANDFREE_BRIDGE_EDGE_KEY=<BRIDGE-EDGE-KEY>
  ```
- **Network**: if outbound traffic is filtered, allow `github.com`, `raw.githubusercontent.com` and `<HOSTNAME>`.
- **Setup script**:
  ```bash
  curl -fsSL https://raw.githubusercontent.com/fourthscale/handfree-code/main/bin/cloud-setup.sh | bash
  ```
  It installs the plugin and declares Spokenly at the tunnel's address, with the token and the key. It never fails the environment: with a piece missing, sessions just stay silent.

Optional: `HANDFREE_OVERRIDES` changes a few reading settings for that environment's sessions, in JSON, for instance `{"first_paragraph_only": false, "language": "en"}`. Accepted keys: `language`, `voice`, `validation_word`, `first_paragraph_only`, `pause_between_lines_seconds`, `silence_around_title_ms`. Nothing that would make the Mac run a program.

Your sessions' text and your microphone go through the tunnel: use a provider you trust, and never publish the keys.

### How sessions reach Spokenly

`question_transport`, set separately for local and cloud sessions:

| Value | Effect |
|---|---|
| `mcp` | through the `spokenly` MCP server declared in Claude Code (local default) |
| `bridge` | through the tunnel (cloud default) |
| `none` | no spoken questions: they stay written |

A session only gets the voice rules when its transport works. To change the local one (it also redeclares `spokenly`):

```bash
sh handfree-code/bin/set-question-transport.sh mcp|bridge|none
```

`bridge` locally needs `bridge_url` in the settings.

## Settings

All optional, in `~/.config/claude-speak.json`:

| Key | Default | Purpose |
|---|---|---|
| `language` | the Mac's | spoken phrases and rules: `fr`, `en` or `de` (otherwise English) |
| `voice` | system voice | a `say` voice to force |
| `speak_command` | — | script that speaks instead of `say`; `say` takes over if it fails |
| `validation_word` | `stop` | word that sends a dictation; sessions ignore it at the end of a message |
| `first_paragraph_only` | `true` | `false` reads the whole reply right away |
| `pause_between_lines_seconds` | `1.2` | silence between lines, where a voice command gets through |
| `silence_around_title_ms` | `800` | silence around the session's name |
| `announce_session` | `on_change` | say the session's name when the speaker changes, or `always` |
| `pause_media` | `true` | pause what plays while speaking |
| `max_dictation_seconds` | `180` | after a dictation never sent, reading resumes |
| `question_tool` | `mcp__spokenly__ask_user_dictation` | questions tool named in the voice rules |
| `target_app` | `Claude` | app "Claude Listen" brings forward; `iTerm2` or `Terminal` for a terminal |
| `click_prompt` | auto | click into the message field (only for the Claude app by default) |
| `prompt_name` | `Prompt` | accessibility name of the Claude app's message field |
| `prompt_fallback` | `{"x_ratio": 0.6, "from_bottom": 55}` | point clicked when the field is not found |
| `spokenly_trigger` | `double_right_command` | or `none` |
| `activate_delay_seconds` | `0.5` | wait after bringing the app forward |
| `after_click_delay_seconds` | `0.3` | wait after the click |
| `double_tap_gap_seconds` | `0.12` | gap between the two taps |
| `open_session_delay_seconds` | `0.8` | wait for the session "Claude Reply" opened to show |
| `away_after_idle_seconds` | `300` | Mac idle time after which questions go in writing |
| `voice_permissions` | `false` | answer permission prompts by voice |
| `permission_answer_seconds` | `90` | how long to wait for the spoken answer |
| `question_transport` | `{"local": "mcp", "cloud": "bridge"}` | `mcp`, `bridge` or `none`, per kind of session |
| `bridge_url` | — | the tunnel's address, for the local `bridge` transport |
| `bridge_token` | — | created by `install-bridge.sh` |
| `bridge_edge_key` | — | sent as `X-Handfree-Key`; created by `install-bridge.sh` |
| `bridge_port` | `8765` | local port of the bridge |

The question hooks match any `mcp__…spokenly…__ask_user_dictation` tool. For another dictation tool, change the `matcher` in `hooks/hooks.json` too.

## Troubleshooting

- **Nothing is read**: check voice mode (`/vocal on`), then `say hello`. A hook added mid-session only applies to new sessions.
- **A voice command does nothing**: a permission dropped. Untick and tick the app again in Accessibility. To find which one, right after the failure:
  ```bash
  /usr/bin/log show --last 5m --style compact --predicate 'process == "tccd"' | grep -E "PostEvent|AUTHREQ_SUBJECT|AUTHREQ_RESULT"
  ```
  `authValue=0` followed by `AUTHREQ_SUBJECT` names the refused program.
- **"Shortcuts is not allowed to send keystrokes"**: remove Shortcuts from Accessibility ("−") and add it back, or run `tccutil reset Accessibility com.apple.shortcuts`.
- **"Claude Listen" clicks the wrong place**: the field is found by its accessibility name. If the app's layout changed, a fallback point is clicked and the field is searched again in the background (about 30 s), for next time.
- **A cloud session stays silent**: run the checks of *Check from outside*, then read the bridge's log on the Mac (`tail ~/Library/Logs/handfree-bridge.log`) and ask the cloud session for its hooks' log (`cat /tmp/handfree-hook.log`): one line per hook, with its outcome.

## What an update can break

- The Claude app may rename its "Prompt" field: the fallback click takes over, and `prompt_name` can be set.
- "Claude Reply" and "Claude Session" use the app's own links (`claude://code/continue`, `claude://code/search`) and its session files. If they change, "Claude Reply" falls back to the session on screen.
- Session titles and delegated turns are read from Claude Code's internal transcript format. If it changes, the plugin falls back to the folder name and reads the reply.
- Pausing music uses a private macOS framework (MediaRemote), restricted since macOS 15.4: there, pausing may stop working. Speaking does not depend on it.

## Development

```bash
tests/run.sh
tests/bridge.sh
```

Silent tests: a fake `say` writes to a file, and state and settings live in a scratch folder. Run them outside Claude Code's sandbox, before every release. "Claude Listen" (click, accessibility) is tested by hand.

## License

[MIT](LICENSE): free to use, change and redistribute, keeping the copyright notice.
