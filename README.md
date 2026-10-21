# handfree-code

Drive Claude Code by voice on macOS, hands free.

- **Claude talks**: replies and questions are read aloud, with the name of the session speaking. Only the first paragraph is read; say "Claude Continue" for the rest.
- **You talk**: you dictate in the Handfree Code app's window and send by saying "stop". Claude asks its questions there too and you answer aloud. The transcription runs on your Mac (Whisper, or Apple's recognizer).
- **You steer it** with a few spoken commands, or keyboard shortcuts: "Claude Listen", "Claude Reply", "Claude Session", "Stop", "Claude Cancel", "Claude Quiet", "Claude Continue", "Claude Restart", "Claude Voice mode off" (voice mode on: its shortcut, as nothing listens while it is off).

Everything is open source and built on your Mac: the plugin (hooks and scripts), the **Handfree Code app** (a native macOS app: dictation, questions, a status panel with a halo, settings), and a **listener** for the spoken commands (Vosk, offline). One command installs it all.

## Requirements

- macOS 14 or later (tested on 14.4.1), on a Mac with Apple silicon for a fast transcription.
- Apple's developer tools: `xcode-select --install` (Swift builds the app, Python runs the listener). Xcode itself is not needed.
- The Claude desktop app and the `claude` command line (`curl -fsSL https://claude.ai/install.sh | bash`, see [Claude Code's setup](https://docs.anthropic.com/en/docs/claude-code/setup)); tested with Claude Code 2.1.287 (`claude --version`). Claude Code in a terminal works too: see `target_app` in *Settings*.
- About 2 GB of disk for the Whisper model and the listener's model.
- [Homebrew](https://brew.sh), for two optional pieces: on macOS 15.4 or later, [media-control](https://github.com/ungive/media-control), for music and videos to pause while Claude speaks (the installer installs it when Homebrew is there); and a tunnel's program, for cloud sessions.
- Headphones, preferably: the microphone then hears you, not the reading voice. Without them it still works: while Claude speaks, only "Quiet", "Continue" and "Restart" are listened for, and not when the text being read says them.

**Privacy.** Your voice is transcribed on the Mac, offline, and the spoken commands are recognized there too. No sound is kept, except the last dictation's and its transcript (`last-dictation.wav` and `.txt` in `~/Library/Caches/handfree-code/`, to compare engines; each dictation replaces them). The plugin sends nothing anywhere, except to an online voice you choose (`speak_command`) and through the cloud bridge, if you set them up.

## Install

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

### 2. Everything else, in one command

In a new Claude session, type:

```
/handfree-code:install
```

or, in a terminal, from a clone of this repository: `sh bin/install.sh`.

It does the following; run it again any time: it brings everything up to date and keeps your settings.

1. copies the plugin's scripts to `~/Library/Application Support/handfree-code/`, a path that stays the same across versions;
2. builds the **Handfree Code** app with Swift, signs it with a certificate of your Mac's own (made once: macOS asks your password to trust it, and then keeps the app's permissions from one build to the next; if it asks to use the key or for the keychain's password, answer **Always Allow**, or it asks at every build), installs it in `~/Applications` and starts it with your session;
3. installs the **listener** for the spoken commands: Vosk in a Python environment of its own, the speech model of your language (about 65 MB), a login service; and media-control on macOS 15.4 and later;
4. declares Claude's **`handfree` MCP server** (user scope), through which Claude asks its questions by voice.

The first build takes a few minutes. At its first start, the app downloads the Whisper model (Large v3 Turbo, about 1.6 GB), then macOS prepares it once for your Mac's chip (a few minutes, in the background).

### 3. The permissions

- System Settings > Privacy & Security > **Accessibility**: allow **Handfree Code** (the app asks). It pastes your dictation into Claude when Claude's field cannot be reached otherwise, presses Return for "Stop" and Escape for "Cancel", and sees the double taps of a modifier key chosen as a shortcut.
- **Speech Recognition**, only if you choose Apple's engine (Settings > Dictation): macOS asks Handfree Code the first time.
- The **microphone**: macOS asks Handfree Code once. The app records for the listener too, so Python needs no permission; the microphone is the system's, or the one chosen in Settings > Dictation. Only without the app does Python record and press the keys itself: then allow Python in Microphone and Accessibility, and restart the listener: `launchctl kickstart -k "gui/$(id -u)/com.handfree-code.listener"`.

Tip: with people talking nearby, a headset microphone close to your mouth keeps their voices out far better than the Mac's own.

### 4. The voice

System Settings > Accessibility > Spoken Content > **System voice**: pick a voice in your language and its rate. Or choose it in the app's settings (Settings > Reading > Voice).

The default voices sound robotic. For a natural one, click the ⓘ next to *System voice*, search your language and download a voice marked *Premium*, or a Siri voice, then select it. Try it:

```bash
say "Hello, this is the voice Claude will use."
```

**An online voice** (optional): `speak_command` points to a script that speaks the text it is given. One for OpenAI ships with the plugin. Add this to `~/.config/handfree-code.json`:

```json
{
  "speak_command": "~/Library/Application Support/handfree-code/speak-openai.sh",
  "openai_api_key": "<YOUR-OPENAI-KEY>"
}
```

Optional: `openai_voice` (default `alloy`), `openai_tts_model` (default `gpt-4o-mini-tts`). Each line costs a round trip, about half a second to a second. If the script fails, `say` reads the line. For another service, copy the script and change the request.

### 5. Check

First let the Whisper model finish downloading and loading: Handfree Code's menu > **Settings and services…** > *Dictation* shows when it is ready. Then open a new Claude session (hooks and MCP servers are read when a session starts) and type "ask me a question". The question is read, the dictation pill opens at the bottom of the screen, you answer and say "stop", and Claude's reply is read. Then say "Claude Listen", dictate a message, say "Stop": a short sound tells each command was taken, another that the microphone is open, and the message goes to the session on screen.

That is all for sessions on this Mac. For cloud sessions to speak and ask through it too, see *Cloud sessions* below: `/handfree-code:bridge` sets them up.

## The Handfree Code app

Its icon in the menu bar is a status light: a microphone with a green dot when the listener waits for a command, crossed out when voice mode is off, a wave while Claude speaks, a red dot while you dictate, an orange one while a question waits.

- **The panel**: a small floating window with a halo that moves while Claude speaks, the text being read, the readings waiting their turn and the recent sessions. While Claude speaks, a **Stop reading** button above the text cuts the reading as "Claude Quiet" does (also in full screen and the menu bar menu): handy when the spoken command is drowned by the reading itself; **Claude Continue** or its shortcut resumes it. At rest it folds to the halo and its buttons, and opens while something happens. A click on the halo, or its circle button, reduces it to a circle that opens only while Claude speaks or listens; the arrow opens a full-screen view (the whole reply, the queue, the sessions in detail). The panel stays where you drag it.
- **The dictation pill**: the app the text is for on the left, a glow red while it listens and blue while it transcribes, the question when there is one. **↩** or "stop" sends, **Esc** or "Claude Cancel" cancels, and a silence after you spoke can end it too (Settings > Dictation > Automatic end).
- **Settings and services** (the gear, or **Settings and services…** in the menu bar icon's menu):
  - *Services*: voice mode on or off; the listener, the bridge and the tunnel's command (start, stop, restart, their logs); the dictation and Claude's questions (with a button, *Declare*, to declare the app's MCP server again; it leaves `question_transport` as it is).
  - *Settings*: the app's interface language (the Mac's, French, English or German; the app restarts to take it), and the plugin's settings (language, voice, what is read, dictation), written to `~/.config/handfree-code.json`. After changing the plugin's `language`, run `/handfree-code:install` again: the listener needs that language's speech model.
  - *Dictation*: the engine (Whisper or Apple), the Whisper model, the microphone (the system's, or one you choose; the listener hears through it too), the automatic end. Whisper's phantom phrases on silence ("Sous-titrage Société Radio-Canada", "Thanks for watching") are dropped.
  - *Voice commands*: for each command, its spoken phrases (empty: the language's defaults; several separated by commas) and a **keyboard shortcut** that works anywhere on the Mac: a key with ⌘, ⌥ or ⌃, a function key, or a modifier tapped twice alone (right ⌘ twice, say; this one needs the Accessibility permission the app asks for). By default ⌃⌥L listens, ⌃⌥R replies, ⌃⌥Q cuts the reading, ⌃⌥V turns voice mode on. The shortcut that started a dictation, pressed again, ends it and sends it, as "Stop" does. A double tap must be quick (two short presses, close together, nothing else pressed), so that a key brushed by accident starts nothing. Voice mode on has no spoken phrase: voice mode off stops the listener, so nothing would hear it; its shortcut, the panel's button or the menu turn it on. A shortcut that cannot work (taken by macOS or another app, or a double tap without Accessibility) shows a warning. "Restore the defaults" puts back the phrases and the shortcuts; the listener restarts by itself to take a new phrase.
  - *Sounds*: command taken, microphone open, dictation done, among Apple's own.
  - *Cloud sessions*: the bridge, the tunnel (its command and public address, checked end to end) and the values to paste on claude.ai, shown after Touch ID or your password. See *Cloud sessions*.

While the settings are open, the app has a Dock icon, the halo (⌘Tab, ⌘W); it goes away with the window.

The app answers on `localhost:51290`, for the plugin, the cloud bridge and the `handfree` MCP server (`bin/mcp-relay.sh`). Its code is in `app/`; `sh app/install.sh` rebuilds it alone.

## The commands

| Said in English | En français | Auf Deutsch | What it does |
|---|---|---|---|
| claude listen | claude écoute | claude zuhören | starts a dictation for the session on screen |
| claude reply | claude réponse | claude antworten | the same, for the session that spoke last |
| claude session | claude session | claude sitzung | opens the session search: say a session's name, then "Stop" |
| stop | stop | stopp | sends the dictation (presses Return); does nothing when you are not dictating |
| claude cancel | claude annule | claude abbrechen | cancels the dictation (presses Escape): nothing is sent |
| claude quiet | claude silence, claude chut, claude tais-toi | claude ruhe | cuts the reading |
| claude continue | claude continue | claude weiter | reads the rest of the reply |
| claude restart | claude recommence | claude neu | reads the reply again from the start |
| claude voice mode off | claude mode vocal désactivé | claude sprachmodus aus | turns everything off, listening included |

Say a command on its own, a short pause before and after; a command inside a sentence does nothing. A second, free transcription of the same audio checks each command: one it heard as other words (a video, a sentence of yours) is refused. "Stop" sends once a second of silence follows it, so a "stop" inside your sentence does not cut you short. What is listened for follows what happens: while you dictate, only "Stop" and "Cancel"; while Claude speaks, only "Quiet", "Continue" and "Restart". **The phrases are yours to choose**, several per command if you like: in the app (Settings > Voice commands; the listener restarts by itself to take them), or in `~/.config/handfree-code.json` (then restart the listener with the `launchctl kickstart` above: it does not restart with each session, only when its own files change):

```json
{
  "voice_commands": {
    "listen": "claude écoute",
    "quiet": ["claude chut", "claude stop lecture"]
  }
}
```

"Claude" in front keeps a word said in conversation from triggering a command. The phrase for "Stop" is also the word that ends a dictation and is left out of what is sent (`validation_word` follows it unless set). Each phrase must be made of words the speech model knows.

## Usage

- **Claude Listen** → dictate → **Stop**: the message goes to the session on screen, wherever you were. You dictate in the app's pill, and the plugin puts the text in Claude's field and sends it; **Escape** cancels cleanly (nothing sent, the readings and the music resume, you are back in your app). **Said in another app**, with Claude in a normal window (not full screen): Claude stays behind, the text is put in Claude's field and sent; you never leave your app. `"dictate_behind": false` turns this off. With Claude in full screen, or when its field cannot be reached, Claude comes forward and the app pastes the text into its field and sends it; then you are back in the app you said it in. Said in Claude, you stay in Claude. **Claude Reply** does the same, and so does **Claude Session** followed by **Claude Listen**. `"return_to_previous_app": false` leaves Claude on screen.
- **Claude Reply** → dictate → **Stop**: the message goes to the session that spoke last, even if another one is on screen (it is opened only then). A cloud session cannot be opened this way: the session on screen gets it.
- **Claude Session** → say a session's name → **Stop**: that session opens. Then **Claude Listen**.
- **A question**: Claude writes its reply in full, the question last, and ends its turn; it is then asked to put the question alone to the dictation tool. The reply stays on screen and its first paragraph is read first, then "Details available" if text remains, then the question ("A question. …"). For a long reply, its first paragraph is its summary (see *A reply*); if it is not, Claude adds a two- or three-sentence summary to the question, read right after it. The voice rules ask for that order because text written just before a tool call may be hidden in the app. You answer, **Stop** or Enter sends; the answer goes back to the session that asked. To hear the rest of that text first, answer "the rest" ("la suite", "der Rest"): a long rest comes as a summary Claude writes, read before the question asked again; answer "the details" ("le détail", "die Details") to hear the full text, then Claude asks once more. A short rest is read as it is. `"summarize_rest": false` reads the full rest straight away. A question sent back but never asked (you pressed Escape, or typed another message to that session) holds nothing: the other readings go on.
- **The app's own questions** (its multiple-choice window, its "start in a new session?" card, the question in its end-of-turn box) are never read aloud: in voice mode Claude is turned back to ask them through the dictation tool.
- **A reply**: the first paragraph is read, then "Details available" if text remains. The voice rules ask Claude to open a long reply with a two- or three-sentence summary of all of it, so that what you hear is the gist. **Claude Continue** reads the rest, **Claude Restart** reads it all again, **Claude Quiet** cuts it (say it between two lines, or use ⌃⌥Q or the panel's **Stop reading** button, which the reading cannot drown). After Quiet, the next reply is read from its start, and the one you cut does not come back by itself: **Claude Continue** resumes it from the line you cut (two replies cut in a row: the first, then the second). Quiet (or its shortcut) during the text read before a question stops that text; the question itself is still asked.
- **Several sessions**: readings wait their turn, first come first read. A session's name is said when the speaker changes. A question waits for another session's question or a dictation under way to be answered, then for the reading under way to reach its pause (its first paragraph), a minute and a half in all; then nothing else is read until you answer: the dictation never takes down another voice. Still busy after that, the question is asked in writing instead. A reply of the same session still waiting its turn is read before its question.
- **Music or a video**: paused while Claude speaks, resumed afterwards. Only the app the keyboard's play/pause key drives; if nothing plays, nothing is touched.
- **A session started by another one** stays quiet: the one that started it relays its result. Talk to it yourself and it answers aloud.
- **Claude waiting**: when a session shows a permission prompt or waits for you without asking aloud, "Claude needs your answer" is read, with the session's name (not while you are already answering by voice). A turn that ends with nothing to read says "Claude is waiting".
- **Away from the Mac** (keyboard and mouse idle for `away_after_idle_seconds`): questions are asked in writing instead.
- **Permission prompts by voice** (opt-in, `voice_permissions`): the request is read, a clear "yes" allows, a clear "no" denies, anything else leaves the dialog on screen. Like a question, it waits for a dictation under way (up to 40 s, then the dialog shows). Your deny rules still win. Keep it off if a misheard "yes" is a risk.
- **Claude Voice mode off**, `/handfree-code:vocal off` in Claude, or the app's Voice button: turns everything off, listening included (the microphone is let go). `/handfree-code:vocal on` or the button turns it back on; by voice it cannot, since nothing listens any more.

## Updating

```bash
claude plugin marketplace update handfree-code
claude plugin update handfree-code@handfree-code
```

Then run `/handfree-code:install` again (it rebuilds the app and keeps your settings) and open a new session: hooks are only reloaded by a new session. The listener and the bridge restart on their new version by themselves.

**From a version before 0.3.2**: the settings file `~/.config/claude-speak.json` becomes `~/.config/handfree-code.json`, and `~/Library/Caches/claude-speak` becomes `~/Library/Caches/handfree-code`; each old name stays as a link to the new one. Nothing to do.

**From a version before 0.3**, which used Spokenly: `/handfree-code:install` replaces Spokenly's MCP server with the app's (`handfree`) and drops the settings that no longer apply. Spokenly itself can then be uninstalled. Cloud environments: run their setup script again (see *Cloud sessions*), it now declares `handfree`.

## Turning off and uninstalling

To pause it: say "Claude Voice mode off", or type `/handfree-code:vocal off` in Claude. To disable the plugin without removing it: `"handfree-code@handfree-code": false` in `enabledPlugins`, then a new session.

To remove everything, in this order:

1. In a Claude session, with the bridge set up: `/handfree-code:bridge remove` (the bridge and the tunnel's service). Then delete the tunnel at your provider (Cloudflare: `cloudflared tunnel delete handfree`, and its rules).
2. In a Claude session: `/handfree-code:install remove`. It stops and removes the app, the listener and the `handfree` MCP server.
3. In a terminal:
   ```bash
   claude plugin uninstall handfree-code@handfree-code
   claude plugin marketplace remove handfree-code
   rm -rf ~/Library/Application\ Support/handfree-code ~/Library/Caches/handfree-code ~/Library/Caches/claude-speak ~/.config/handfree-code.json ~/.config/claude-speak.json ~/Library/Logs/handfree-listener.log ~/Library/Logs/handfree-bridge.log ~/Library/Logs/handfree-tunnel.log
   defaults delete com.handfree-code.app
   ```

The `rm` removes the models, the settings (with the bridge's keys and an OpenAI key, if any) and the logs; `defaults delete` removes the app's own choices (engine, model, shortcuts, sounds). Remove Handfree Code (and Python, if you allowed it) from Accessibility, and the "Handfree Code Local Signing" certificate from Keychain Access if you like. A version before 0.2 set up Shortcuts and Voice Control commands: delete them by hand if you still have them.

## Cloud sessions: the bridge (optional)

A cloud session runs on a Linux machine, far from your Mac's speakers and microphone. The bridge sends its hooks and its questions to your Mac through a tunnel, so it talks and listens like a local one.

```
cloud session ──hooks──▶ https://<ADDRESS>/hook ──▶ tunnel ──▶ bridge on the Mac (127.0.0.1:8765) ──▶ reading
              ──MCP────▶ https://<ADDRESS>/mcp  ──▶ tunnel ──▶ bridge on the Mac ──▶ Handfree Code app
```

**What you need**: a tunnel provider that gives a fixed public address: Cloudflare (a domain managed by Cloudflare), ngrok (a reserved domain), Tailscale Funnel, or another. Each person has their own bridge and tunnel: a bridge speaks on the Mac it runs on.

### Set up, in three steps

In a Claude session, `/handfree-code:bridge` does it with you, provider included. Or by hand, in Handfree Code's menu bar icon > **Settings and services…** > *Cloud sessions*:

1. **The bridge**: *Set up the bridge*. It makes two random keys in `~/.config/handfree-code.json` (`bridge_token`, checked by the Mac; `bridge_edge_key`, for the provider's rule) and starts the bridge with your session, listening on `127.0.0.1:8765` only (or `bridge_port`: then use that port wherever 8765 shows below).
2. **The tunnel**: create it at your provider (below), pointed at `http://localhost:8765`. If it is a command to keep running, enter its **command** and *Apply* (the app then runs it with your session, as a service shown under *Services*; leave it empty when the provider's own service runs the tunnel). Type its **public address** (saved as you type it), then *Check*: it sends a request to the public address and tells whether it reaches this Mac's bridge, or why not.
3. **claude.ai**, in the settings of the cloud environment your sessions use (on claude.ai/code, where you pick the environment for a new session, edit that environment):
   - **Environment variables**: *Copy the variables* (after Touch ID or your password), paste. They are `HANDFREE_BRIDGE_URL`, `HANDFREE_BRIDGE_TOKEN` and `HANDFREE_BRIDGE_EDGE_KEY`.
   - **Setup script**: *Copy the setup script*, paste:
     ```bash
     curl -fsSL https://raw.githubusercontent.com/fourthscale/handfree-code/main/bin/cloud-setup.sh | bash
     ```
     It installs the plugin and declares the `handfree` MCP server at the tunnel's address, with the token and the key. It never fails the environment: with a piece missing, sessions just stay silent.
   - **Network**: if outbound traffic is filtered, allow `github.com`, `raw.githubusercontent.com` and the tunnel's host.

**Try it**: open a new cloud session in that environment and ask it to ask you a question. The question is read on the Mac and the dictation pill opens; your answer goes back to the cloud session, and its reply is read.

The same from a terminal: `sh "$HOME/Library/Application Support/handfree-code/install-bridge.sh"` (sets up the bridge, and the tunnel's service from `tunnel_command`), `--check`, `--new-keys`, `--uninstall`.

Optional: `HANDFREE_OVERRIDES` changes a few reading settings for that environment's sessions, in JSON, for instance `{"first_paragraph_only": false, "language": "en"}`. Accepted keys: `language`, `voice`, `validation_word`, `first_paragraph_only`, `summarize_rest`, `pause_between_lines_seconds`, `silence_around_title_ms`. Nothing that would make the Mac run a program.

### Tunnels

**Cloudflare** (a domain managed by Cloudflare):

```bash
brew install cloudflared
cloudflared tunnel login
cloudflared tunnel create handfree
cloudflared tunnel route dns handfree <HOSTNAME>
```

`~/.cloudflared/config.yml`:

```yaml
tunnel: handfree
credentials-file: /Users/<YOU>/.cloudflared/<TUNNEL-ID>.json   # the ID `cloudflared tunnel create` printed
ingress:
  - hostname: <HOSTNAME>
    service: http://localhost:8765
  - service: http_status:404
```

Command: `cloudflared tunnel run handfree`; address: `https://<HOSTNAME>`. Then the **rules** that keep everything without the edge key away from your Mac: Cloudflare dashboard > your domain > Security > WAF > **Custom rules**, in this order ("Edit expression" to paste; the edge key from *Copy the edge key*):

1. **Block requests without the key**: action *Block*.
   ```
   (http.host eq "<HOSTNAME>" and not any(http.request.headers["x-handfree-key"][*] eq "<BRIDGE-EDGE-KEY>"))
   ```
2. **Let requests with the key through**: action *Skip*. Tick: all remaining custom rules, **all managed rules**, Super Bot Fight Mode, and under "More components to skip": Browser Integrity Check and Security Level.
   ```
   (http.host eq "<HOSTNAME>" and any(http.request.headers["x-handfree-key"][*] eq "<BRIDGE-EDGE-KEY>"))
   ```

The managed rules matter most: they read the commands and paths of a conversation as an attack, and answer 403 to every hook but the first. The free plan's Bot Fight Mode cannot be skipped by a rule: if it blocks the bridge, turn it off for the domain. `cloudflared service install` runs cloudflared as a system service, but without a configuration of its own it carries no tunnel: prefer the command in the app.

**ngrok**: `ngrok config add-authtoken <TOKEN>`, reserve a domain in ngrok's dashboard. Command: `ngrok http --url=<DOMAIN> 8765`; address: `https://<DOMAIN>`.

**Tailscale Funnel**: `tailscale funnel --bg 8765`, once: Tailscale's own service carries it, so no command. Address: the one it prints, `https://<MACHINE>.<TAILNET>.ts.net`.

### Keys

| Key | Made by | Goes to |
|---|---|---|
| `bridge_token` | *Set up the bridge* | claude.ai (`HANDFREE_BRIDGE_TOKEN`) |
| `bridge_edge_key` | *Set up the bridge* | claude.ai (`HANDFREE_BRIDGE_EDGE_KEY`), and the provider's rule |
| the public address | your provider | the app (*Public address*), claude.ai (`HANDFREE_BRIDGE_URL`) |

If one leaks: *New keys* (or `--new-keys`), then give them again to claude.ai and to the provider's rule.

### Security

What the bridge exposes, and what guards it:

- **What gets through**: `/hook` makes the Mac read text aloud; `/mcp` opens a dictation in the Handfree Code app and returns what you say; `/ping` answers the address check. Nothing else: the Mac never runs a program sent by a cloud session (`HANDFREE_OVERRIDES` only accepts reading settings), and `/mcp` relays only the dictation tool (`ask_user_dictation`) and MCP's own handshake: the app's other calls, which press keys or type into the app in front, are refused.
- **The app's own address** (`localhost:51290`) takes no request from a web page (one with an `Origin`, or another `Host`), and the calls that press keys or type text need a secret only the plugin and the listener read (`~/Library/Application Support/handfree-code/app-secret`, made by the app). The microphone's sound goes to the listener (`localhost:51291`) only after that secret.
- **Two locks**: the Mac refuses any request without `bridge_token`, and a provider that can filter (Cloudflare's rules) refuses any request without `bridge_edge_key` before it reaches the Mac. The service only listens on `127.0.0.1`: nothing reaches it except through the tunnel.
- **What travels**: the end of the conversation (to read it and title it) and your dictated answers. Use a tunnel provider you trust, and never publish the keys; if one leaks, change both (see *Keys*).

### How sessions reach the dictation

`question_transport`, set separately for local and cloud sessions:

| Value | Effect |
|---|---|
| `mcp` | through the `handfree` MCP server declared in Claude Code (local default) |
| `bridge` | through the tunnel (cloud default) |
| `none` | no spoken questions: they stay written |

A session only gets the voice rules when its transport works. The install keeps the local one you chose. To change it (it also redeclares `handfree`):

```bash
sh ~/Library/Application\ Support/handfree-code/set-question-transport.sh mcp|bridge|none
```

`bridge` locally needs `bridge_url` and `bridge_token` in the settings. The app's *Declare* button declares the app's server again without changing this choice.

## Settings

All optional, in `~/.config/handfree-code.json`:

| Key | Default | Purpose |
|---|---|---|
| `language` | the Mac's | spoken phrases, rules and the listener's speech model: `fr`, `en` or `de` (otherwise English); after a change, run `/handfree-code:install` again |
| `voice` | system voice | a `say` voice to force |
| `speak_command` | — | script that speaks instead of `say`; `say` takes over if it fails |
| `say_path` | `/usr/bin/say` | the `say` program the Mac's voice is spoken with |
| `voice_commands` | per language | your phrases for the spoken commands, one or several per command (see *The commands*) |
| `microphone` | the system's | part of a microphone's name, for the dictation and the listener (Settings > Dictation); by default the system's input, followed when it changes (headphones, AirPods). `listener_device`, its name before 0.3.2, is still read |
| `listener_sound` | `Tink` | sound played when a command is taken, a name from `/System/Library/Sounds`, or `false` |
| `listener_log` | `false` | `true` also logs every phrase heard and why it was ignored |
| `validation_word` | the "Stop" phrase (`stopp` in German) | word that sends a dictation; sessions ignore it at the end of a message |
| `first_paragraph_only` | `true` | `false` reads the whole reply right away |
| `summarize_rest` | `true` | answering "the rest" to a question: a long rest is summed up first, "the details" reads it in full; `false` reads it in full at once |
| `pause_between_lines_seconds` | `1.2` | silence between lines, where a spoken command gets through |
| `silence_around_title_ms` | `800` | silence around the session's name |
| `announce_session` | `on_change` | say the session's name when the speaker changes, or `always` |
| `pause_media` | `true` | pause what plays while speaking |
| `media_control` | `null` | media-control is used when installed (needed from macOS 15.4); a path to it, or `false` to never use it |
| `max_dictation_seconds` | `180` | after a dictation never sent, reading and the other commands resume |
| `question_tool` | `mcp__handfree__ask_user_dictation` | questions tool named in the voice rules |
| `dictation_url` | `http://localhost:51290` | where the Handfree Code app answers |
| `target_app` | `Claude` | app "Claude Listen" brings forward; `iTerm2` or `Terminal` for a terminal |
| `dictate_behind` | `true` | said in another app, Claude stays behind: the app records in its pill and the text is sent through accessibility (not with Claude in full screen) |
| `dictation_log` | `false` | `true` notes how each dictation with Claude behind went in `~/Library/Caches/handfree-code/dictate-behind.log` (last 200 lines) |
| `return_to_previous_app` | `true` | after **Stop**, back to the app "Claude Listen" was said in; `false` stays in Claude |
| `click_prompt` | auto | click into the message field (only for the Claude app by default) |
| `prompt_name` | `Prompt` | accessibility name of the Claude app's message field |
| `prompt_fallback` | `{"x_ratio": 0.6, "from_bottom": 55}` | point clicked when the field is not found |
| `activate_delay_seconds` | `0.5` | wait after bringing the app forward |
| `after_click_delay_seconds` | `0.3` | wait after the click |
| `open_session_delay_seconds` | `0.8` | wait for the session "Claude Reply" opened to show |
| `away_after_idle_seconds` | `300` | Mac idle time after which questions go in writing |
| `voice_permissions` | `false` | answer permission prompts by voice |
| `permission_answer_seconds` | `90` | how long to wait for the spoken answer |
| `question_transport` | `{"local": "mcp", "cloud": "bridge"}` | `mcp`, `bridge` or `none`, per kind of session |
| `bridge_url` | — | the tunnel's public address: the address check, and the local `bridge` transport |
| `tunnel_command` | — | the tunnel's command, run by the app with your session; none: the tunnel runs on its own |
| `bridge_token` | — | created by *Set up the bridge* (`install-bridge.sh`) |
| `bridge_edge_key` | — | sent as `X-Handfree-Key`; created by *Set up the bridge* |
| `bridge_port` | `8765` | local port of the bridge; the tunnel must point at it (the recipes above say 8765) |

The question hooks match any `mcp__…__ask_user_dictation` tool. For another dictation tool, set `question_tool`, and change the `matcher` in `hooks/hooks.json` if its tool has another name.

The app keeps its own choices out of this file: the engine, the model and the automatic end (Settings > Dictation), the shortcuts (Settings > Voice commands), the sounds of the dictation (Settings > Sounds). The microphone and the "command taken" sound, which the listener uses too, are written here (`microphone`, `listener_sound`).

## Troubleshooting

- **Nothing is read**: check voice mode (`/handfree-code:vocal on`), then `say hello`. A hook added mid-session only applies to new sessions.
- **A spoken command does nothing**: set `"listener_log": true`, restart the listener, say it again and read `~/Library/Logs/handfree-listener.log`. Each phrase heard is there with what was done with it: not heard at all (microphone), heard among other words (say it alone), heard as other words by the free transcription (each command taken also shows what it heard), or ignored in the current state (only "Stop" while you dictate).
- **"osascript is not allowed to send keystrokes"** in that log: the app did not press the key (not running, or missing from Accessibility), so Python tried and is not allowed either. Allow Handfree Code in Accessibility (see *The permissions*); if it is there and was rebuilt, remove it ("−") and add it back.
- **The dictation does not open, or Claude's questions stay written**: the app's Settings and services > Services shows whether the dictation is ready and the MCP server declared (a button declares it again; then open a new session). `curl -s -X POST localhost:51290 -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'` answers when the app runs.
- **The transcription is poor**: Settings > Dictation: the full Large v3 Turbo model is the most accurate. The last dictation's sound is in `~/Library/Caches/handfree-code/last-dictation.wav`, to compare.
- **The app asks for its permissions again after an update**: it was signed ad hoc, the local certificate missing (the install says so). Run `sh app/install.sh` again: it creates the certificate.
- **The listener does not run**: `launchctl print "gui/$(id -u)/com.handfree-code.listener"`, then run `/handfree-code:install` again.
- **"Claude Listen" clicks the wrong place**: the field is found by its accessibility name. If the app's layout changed, a fallback point is clicked and the field is searched again in the background (about 30 s), for next time.
- **A cloud session stays silent**: *Check* in Settings and services > *Cloud sessions* (or `sh ~/Library/Application\ Support/handfree-code/install-bridge.sh --check`) tells whether the tunnel reaches the bridge, or why not; then read the bridge's log on the Mac (`tail ~/Library/Logs/handfree-bridge.log`) and ask the cloud session for its hooks' log (`cat /tmp/handfree-hook.log`): one line per hook, with its outcome.

## Known limitations

Checked with Claude Code 2.1.287 and macOS 14.4.1, October 2026.

- **Cloud sessions**: their permission prompts are not asked by voice, the bridge does not carry them. "Claude Reply" cannot open a cloud session. They are announced as "cloud" and the project's name: a cloud session's title lives on claude.ai only, neither in its transcript nor in the app's files on the Mac.
- **A session started by another one** is not read: the session that started it relays its result.
- **One Mac**: the bridge speaks and listens on a single Mac.
- **The app is built on each Mac** (no download of a prebuilt app): it needs Apple's developer tools, and Swift 5.10 or later. WhisperKit is pinned to 0.9.4, the last version Xcode 15's Swift builds.
- **The first load of a Whisper model** takes a few minutes, once (macOS prepares it for the chip), and the model stays in memory (about 1 GB for Large v3 Turbo).
- **The listener** runs in the Python of Apple's developer tools, on the sound the app sends it. Its small speech models know common words only: a phrase you choose must use them.
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

Silent tests: a fake `say` writes to a file, and state and settings live in a scratch folder. Run them outside Claude Code's sandbox, before every release. The listener's decisions are tested; the microphone, the click and the app are tried by hand (`sh app/install.sh` rebuilds and restarts the app).

## License

[MIT](LICENSE): free to use, change and redistribute, keeping the copyright notice.
