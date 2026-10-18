# handfree-code

Drive Claude Code by voice on macOS, hands free.

- **Claude talks**: replies and questions are read aloud, with the name of the session speaking. Only the first paragraph is read; say "Claude Continue" for the rest.
- **You talk**: you dictate with [Spokenly](https://spokenly.app) and send by saying "stop". Claude asks its questions through Spokenly and you answer aloud.
- **You steer it** with a few spoken commands: "Claude Listen", "Claude Reply", "Claude Session", "Stop", "Claude Quiet", "Claude Continue", "Claude Restart", "Claude Voice mode on/off".

Setup comes in two parts: a **quick start** (5 minutes) that reads Claude aloud and lets you answer its questions by voice, then the **hands-free setup** (5 minutes: one command, one permission) for the spoken commands.

## Requirements

- macOS 14 or later (tested on 14.4.1). The plugin relies on what macOS ships (`osascript`, `say`). The spoken commands and the optional cloud bridge also need `/usr/bin/python3` (`xcode-select --install` if it is missing).
- The Claude desktop app and the `claude` command line; tested with Claude Code 2.1.287 (`claude --version`). Claude Code in a terminal works too: see `target_app` in *Settings*.
- [Spokenly](https://spokenly.app); the free tier is enough.
- On macOS 15.4 or later, [media-control](https://github.com/ungive/media-control) (`brew install media-control`) for music and videos to pause while Claude speaks. The listener's installer installs it when Homebrew is there. Earlier versions need nothing.
- Headphones, preferably: the microphone then hears you, not the reading voice. Without them it still works: while Claude speaks, only "Quiet", "Continue" and "Restart" are listened for, and not when the text being read says them.

**Privacy.** Depending on the model chosen in Spokenly, your voice may go to an online service. The spoken commands are recognized on the Mac, offline, and no sound is kept. The plugin itself sends nothing anywhere, except to an online voice you choose (`speak_command`) and through the cloud bridge, if you set them up.

## Quick start

### 1. The plugin

```bash
claude plugin marketplace add https://github.com/fourthscale/handfree-code.git
claude plugin install handfree-code@handfree-code
```

Or add it to a Claude Code settings file (`~/.claude/settings.json`, or a project's `.claude/settings.json`):

```json
{
  "extraKnownMarketplaces": {
    "handfree-code": {
      "source": { "source": "git", "url": "https://github.com/fourthscale/handfree-code.git" }
    }
  },
  "enabledPlugins": {
    "handfree-code@handfree-code": true
  }
}
```

Then open a new session: it copies the plugin's scripts to `~/Library/Application Support/handfree-code/`, a path that stays the same across versions. The listener and the bridge run the scripts there.

### 2. Spokenly

- Microphone: your headphones'.
- Dictation shortcut: **double tap on right Command**, in toggle mode. With another shortcut, set `spokenly_trigger` to `none`.
- Turn on **Quick send (Return key or swipe)**: when Claude's message field cannot be reached, Spokenly types the dictation into it, and "Stop" presses Return to end it and send it.
- Turn off Spokenly's own "read the question aloud": the plugin already reads it.
- Declare its MCP server in Claude Code, in `~/.claude.json` (MCP servers are not read from `settings.json`), replacing `<YOU>` with your user name:
  ```json
  {
    "mcpServers": {
      "spokenly": {
        "type": "stdio",
        "command": "/Users/<YOU>/Library/Application Support/Spokenly/mcp-bridge.sh",
        "timeout": 120000
      }
    }
  }
  ```
  Add the `spokenly` entry to the `mcpServers` already in the file. `timeout` (2 minutes) leaves you time to think and answer, and keeps an unanswered question from blocking the session for 30 minutes (the scripts below set it for you). Or with the command line, then add the `timeout` by hand:
  ```bash
  claude mcp add --scope user spokenly "$HOME/Library/Application Support/Spokenly/mcp-bridge.sh"
  ```

### 3. The voice

System Settings > Accessibility > Spoken Content > **System voice**: pick a voice in your language and its rate.

The default voices sound robotic. For a natural one, click the ⓘ next to *System voice*, search your language and download a voice marked *Premium*, or a Siri voice, then select it. Try it:

```bash
say "Hello, this is the voice Claude will use."
```

**An online voice** (optional): `speak_command` points to a script that speaks the text it is given. One for OpenAI ships with the plugin. Add this to `~/.config/claude-speak.json`:

```json
{
  "speak_command": "~/Library/Application Support/handfree-code/speak-openai.sh",
  "openai_api_key": "<YOUR-OPENAI-KEY>"
}
```

Optional: `openai_voice` (default `alloy`), `openai_tts_model` (default `gpt-4o-mini-tts`). Each line costs a round trip, about half a second to a second. If the script fails, `say` reads the line. For another service, copy the script and change the request.

### 4. Check

In a new Claude session, type "ask me a question". The question is read, Spokenly opens, you answer, and Claude's reply is read.

Replies and questions now speak. You dictate your own messages with Spokenly's shortcut. To also drive Claude by voice alone, go on with the hands-free setup.

## Hands-free setup

### 5. The listener

A small program listens for the spoken commands, offline: [Vosk](https://alphacephei.com/vosk/) (free, open source), restricted to the commands' phrases, in French, English or German. In Claude, type:

```
/handfree-code:listener
```

or run `sh ~/Library/Application\ Support/handfree-code/install-listener.sh` in a terminal. The first time, it creates a Python environment, downloads Vosk and the speech model of your language (about 65 MB) and starts a login service; afterwards it only does what is missing. Its log, which keeps only the commands run and its last lines: `~/Library/Logs/handfree-listener.log`.

### 6. The permission

System Settings > Privacy & Security > **Accessibility**: allow **Python**, the app the listener runs in. The install opens that page and shows the app in the Finder: drag it into the list. Without it, "Claude Listen" cannot start Spokenly and "Stop" cannot press Return. Allow the **microphone** too when macOS asks. Then restart the listener:

```bash
launchctl kickstart -k "gui/$(id -u)/com.handfree-code.listener"
```

Tip: while the listener runs, Control Center > Mic Mode > **Voice Isolation** for Python keeps background noise, and much of the reading voice, out.

Check: say "Claude Listen", dictate a message, say "Stop". A short sound tells each command was taken; the message goes to the session on screen.

### The commands

| Said in English | En français | Auf Deutsch | What it does |
|---|---|---|---|
| claude listen | claude écoute | claude zuhören | starts a dictation for the session on screen |
| claude reply | claude réponds | claude antworten | the same, for the session that spoke last |
| claude session | claude session | claude sitzung | opens the session search: say a session's name, then "Stop" |
| stop | stop | stopp | sends the dictation (presses Return); does nothing when you are not dictating |
| claude cancel | claude annule | claude abbrechen | cancels the dictation (presses Escape): nothing is sent |
| claude quiet | claude silence, claude chut | claude ruhe | cuts the reading |
| claude continue | claude continue | claude weiter | reads the rest of the reply |
| claude restart | claude recommence | claude neu | reads the reply again from the start |
| claude voice mode on | claude mode vocal activé | claude sprachmodus an | turns voice mode on |
| claude voice mode off | claude mode vocal désactivé | claude sprachmodus aus | turns everything off, listening included |

Say a command on its own, a short pause before and after; a command inside a sentence does nothing. A second, free transcription of the same audio checks each command: one it heard as other words (a video, a sentence of yours) is refused. "Stop" sends once a second of silence follows it, so a "stop" inside your sentence does not cut you short. What is listened for follows what happens: while you dictate, only "Stop" and "Cancel"; while Claude speaks, only "Quiet", "Continue" and "Restart". **The phrases are yours to choose**, several per command if you like, in `~/.config/claude-speak.json`; the listener restarts with each new session, or run the `launchctl kickstart` above:

```json
{
  "voice_commands": {
    "Claude Listen": "claude écoute",
    "Claude Voice mode on": ["claude réveille-toi", "claude mode vocal activé"]
  }
}
```

"Claude" in front keeps a word said in conversation from triggering a command. Keep "Stop" the same as the `validation_word` setting. Each phrase must be made of words the speech model knows.

## Usage

- **Claude Listen** → dictate → **Stop**: the message goes to the session on screen, wherever you were. You dictate in Spokenly's own window, and the plugin puts the text in Claude's field and sends it; **Escape** in Spokenly cancels cleanly (nothing sent, the readings and the music resume, you are back in your app). **Said in another app**, with Claude in a normal window (not full screen): Claude stays behind. Spokenly records in its own window, then the text is put in Claude's field and sent; you never leave your app. `"dictate_behind": false` turns this off. With Claude in full screen, or when its field cannot be reached, Claude comes forward for the dictation instead; once the message has left (Spokenly inserts and sends it only while Claude is in front), you are back in the app you said it in (your browser, say). No message within 30 s, a cloud session for instance: Claude stays on screen. Said in Claude, you stay in Claude. **Claude Reply** does the same, and so does **Claude Session** followed by **Claude Listen**. `"return_to_previous_app": false` leaves Claude on screen.
- **Claude Reply** → dictate → **Stop**: the message goes to the session that spoke last, even if another one is on screen (it is opened only then). A cloud session cannot be opened this way: the session on screen gets it.
- **Claude Session** → say a session's name → **Stop**: that session opens. Then **Claude Listen**.
- **A question**: Claude writes its reply in full, the question last, and ends its turn; it is then asked to put the question alone to Spokenly. The reply stays on screen and its first paragraph is read first, then "Details available" if text remains, then the question ("A question. …"). For a long reply, its first paragraph is its summary (see *A reply*); if it is not, Claude adds a two- or three-sentence summary to the question, read right after it. "The rest" or "the details" read the reply in full. The voice rules ask for that order because text written just before a tool call may be hidden in the app. You answer, **Stop** or Enter sends; the answer goes back to the session that asked. To hear the rest of that text first, answer "the rest" ("la suite", "der Rest"): a long rest comes as a summary Claude writes, read before the question asked again; answer "the details" ("le détail", "die Details") to hear the full text, then Claude asks once more. A short rest is read as it is. `"summarize_rest": false` reads the full rest straight away.
- **The app's own questions** (its multiple-choice window, its "start in a new session?" card) are never read aloud: in voice mode Claude is turned back to ask them through Spokenly.
- **A reply**: the first paragraph is read, then "Details available" if text remains. The voice rules ask Claude to open a long reply with a two- or three-sentence summary of all of it, so that what you hear is the gist. **Claude Continue** reads the rest, **Claude Restart** reads it all again, **Claude Quiet** cuts it (say it between two lines).
- **Several sessions**: readings wait their turn. A session's name is said when the speaker changes. A question waits for the reading under way to reach its pause (its first paragraph, up to a minute), then nothing else is read until you answer: Spokenly never takes down another voice.
- **Music or a video**: paused while Claude speaks, resumed afterwards. Only the app the keyboard's play/pause key drives; if nothing plays, nothing is touched.
- **A session started by another one** stays quiet: the one that started it relays its result. Talk to it yourself and it answers aloud.
- **Away from the Mac** (keyboard and mouse idle for `away_after_idle_seconds`): questions are asked in writing instead.
- **Permission prompts by voice** (opt-in, `voice_permissions`): the request is read, a clear "yes" allows, a clear "no" denies, anything else leaves the dialog on screen. Your deny rules still win. Keep it off if a misheard "yes" is a risk.
- **Claude Voice mode off**, or `/handfree-code:vocal off` in Claude: turns everything off, listening included (the microphone is let go). `/handfree-code:vocal on` turns it back on; by voice it cannot, since nothing listens any more.

## Updating

```bash
claude plugin marketplace update handfree-code
claude plugin update handfree-code@handfree-code
```

Then open a new session: hooks are only reloaded by a new session, and it brings the listener to the new version (it restarts by itself). With the bridge, restart its service so it runs the new version:

```bash
launchctl kickstart -k "gui/$(id -u)/com.handfree-code.bridge"
```

## Turning off and uninstalling

To pause it: say "Claude Voice mode off", or type `/handfree-code:vocal off` in Claude. To disable the plugin without removing it: `"handfree-code@handfree-code": false` in `enabledPlugins`, then a new session.

To remove everything:

```bash
claude plugin uninstall handfree-code@handfree-code
claude plugin marketplace remove handfree-code
claude mcp remove --scope user spokenly
sh ~/Library/Application\ Support/handfree-code/install-listener.sh --remove
rm -rf ~/Library/Application\ Support/handfree-code ~/Library/Caches/claude-speak ~/.config/claude-speak.json
```

With the bridge, first `sh handfree-code/bin/install-bridge.sh --uninstall`, then delete the Cloudflare tunnel (`cloudflared tunnel delete <TUNNEL>`) and its rules. Remove Python from Accessibility. An earlier version set up Shortcuts and Voice Control commands: delete them by hand if you have them.

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

Optional: `HANDFREE_OVERRIDES` changes a few reading settings for that environment's sessions, in JSON, for instance `{"first_paragraph_only": false, "language": "en"}`. Accepted keys: `language`, `voice`, `validation_word`, `first_paragraph_only`, `summarize_rest`, `pause_between_lines_seconds`, `silence_around_title_ms`. Nothing that would make the Mac run a program.

### Security

What the bridge exposes, and what guards it:

- **What gets through**: `/hook` makes the Mac read text aloud; `/mcp` opens a Spokenly dictation and returns what you say. Nothing else: the Mac never runs a program sent by a cloud session (`HANDFREE_OVERRIDES` only accepts reading settings).
- **Two locks**: Cloudflare refuses any request without `bridge_edge_key`, and the Mac refuses any request without `bridge_token`. The service only listens on `127.0.0.1`: nothing reaches it except through the tunnel.
- **What travels**: the end of the conversation (to read it and title it) and your dictated answers. Use a tunnel provider you trust, and never publish the keys; if one leaks, change both (see *The bridge on the Mac*).

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
| `voice_commands` | per language | your phrases for the spoken commands, one or several per command (see *The commands*) |
| `listener_device` | the system's | part of a microphone's name for the listener; by default it follows the system's input (headphones, AirPods) |
| `listener_sound` | `Tink` | sound played when a command is taken, a name from `/System/Library/Sounds`, or `false` |
| `listener_log` | `false` | `true` also logs every phrase heard and why it was ignored |
| `validation_word` | `stop` | word that sends a dictation; sessions ignore it at the end of a message |
| `first_paragraph_only` | `true` | `false` reads the whole reply right away |
| `summarize_rest` | `true` | answering "the rest" to a question: a long rest is summed up first, "the details" reads it in full; `false` reads it in full at once |
| `pause_between_lines_seconds` | `1.2` | silence between lines, where a spoken command gets through |
| `silence_around_title_ms` | `800` | silence around the session's name |
| `announce_session` | `on_change` | say the session's name when the speaker changes, or `always` |
| `pause_media` | `true` | pause what plays while speaking |
| `media_control` | `null` | media-control is used when installed (needed from macOS 15.4); a path to it, or `false` to never use it |
| `max_dictation_seconds` | `180` | after a dictation never sent, reading and the other commands resume |
| `question_tool` | `mcp__spokenly__ask_user_dictation` | questions tool named in the voice rules |
| `target_app` | `Claude` | app "Claude Listen" brings forward; `iTerm2` or `Terminal` for a terminal |
| `dictate_behind` | `true` | said in another app, Claude stays behind: Spokenly records in its own window and the text is sent through accessibility (not with Claude in full screen) |
| `dictation_log` | `false` | `true` notes how each dictation with Claude behind went in `~/Library/Caches/claude-speak/dictate-behind.log` (last 200 lines) |
| `return_to_previous_app` | `true` | after **Stop**, back to the app "Claude Listen" was said in; `false` stays in Claude |
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

- **Nothing is read**: check voice mode (`/handfree-code:vocal on`), then `say hello`. A hook added mid-session only applies to new sessions.
- **A spoken command does nothing**: set `"listener_log": true`, restart the listener, say it again and read `~/Library/Logs/handfree-listener.log`. Each phrase heard is there with what was done with it: not heard at all (microphone, or Voice Isolation off), heard among other words (say it alone), or ignored in the current state (only "Stop" while you dictate).
- **"osascript is not allowed to send keystrokes"** in that log: Python is missing from Accessibility (see *The permission*), or it was updated: remove it ("−"), add it back, restart the listener.
- **The listener does not run**: `launchctl print "gui/$(id -u)/com.handfree-code.listener"`, then run `/handfree-code:listener` again.
- **"Claude Listen" clicks the wrong place**: the field is found by its accessibility name. If the app's layout changed, a fallback point is clicked and the field is searched again in the background (about 30 s), for next time.
- **A cloud session stays silent**: run the checks of *Check from outside*, then read the bridge's log on the Mac (`tail ~/Library/Logs/handfree-bridge.log`) and ask the cloud session for its hooks' log (`cat /tmp/handfree-hook.log`): one line per hook, with its outcome.

## Known limitations

Checked with Claude Code 2.1.287 and macOS 14.4.1, October 2026.

- **Cloud sessions**: their permission prompts are not asked by voice, the bridge does not carry them. "Claude Reply" cannot open a cloud session. They are announced as "cloud" and the project's name: a cloud session's title lives on claude.ai only, neither in its transcript nor in the app's files on the Mac.
- **A session started by another one** is not read: the session that started it relays its result.
- **One Mac**: the bridge speaks and listens on a single Mac.
- **The listener** runs in the Python of Apple's developer tools: an update of them may replace that app, and its Accessibility permission must then be given again. Its small speech models know common words only: a phrase you choose must use them.
- **Pausing music** relies on a private macOS framework (MediaRemote), restricted since macOS 15.4: there, it goes through [media-control](https://github.com/ungive/media-control) when installed (`brew install media-control`), and without it music may not pause. Speaking does not depend on it.
- **Undocumented parts of the Claude app and of Claude Code**, which an update may change:
  - The Claude app may rename its "Prompt" field: the fallback click takes over, and `prompt_name` can be set.
  - "Claude Reply" and "Claude Session" use the app's own links (`claude://code/continue`, `claude://code/search`) and its session files. If they change, "Claude Reply" falls back to the session on screen.
  - Session titles and delegated turns are read from Claude Code's internal transcript format. If it changes, the plugin falls back to the folder name and reads the reply.

## Development

How it works: [docs/architecture.md](docs/architecture.md). Layout, conventions and how to try a change: [docs/development.md](docs/development.md).

```bash
tests/run.sh
tests/bridge.sh
```

Silent tests: a fake `say` writes to a file, and state and settings live in a scratch folder. Run them outside Claude Code's sandbox, before every release. The listener's decisions are tested; the microphone, the click and Spokenly are tried by hand.

## License

[MIT](LICENSE): free to use, change and redistribute, keeping the copyright notice.
