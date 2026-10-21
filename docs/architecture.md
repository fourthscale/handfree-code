# How handfree-code works

What happens between Claude Code, the Mac's voice, the Handfree Code app and the spoken-commands listener, and why it is built this way. The [README](../README.md) says how to install and use it; this page is for whoever changes it.

## The pieces

```
Claude Code ──hooks──▶ bin/hook.sh ──▶ handfree.js (osascript, on the Mac)
                                   └─▶ cloud-hook.py ──tunnel──▶ bridge-server.py ──▶ handfree.js
microphone ──▶ listener.py (Vosk) ──▶ ~/Library/Application Support/handfree-code/handfree.js (stable copy)
Claude ──MCP──▶ bin/mcp-relay.sh ──▶ Handfree Code app (localhost:51290): questions, dictation
```

- **`bin/handfree.js`** does nearly everything. It runs with `osascript -l JavaScript`, which every Mac has, so the plugin needs no Node or Python on the Mac. The command-line argument picks the job; the comment at the top of the file lists them.
- **`hooks/hooks.json`** wires Claude Code's hooks to it: `Stop` (a reply to read), `PreToolUse` / `PostToolUse` / `PostToolUseFailure` on the dictation tool (a question), `PreToolUse` on the app's own questions (`AskUserQuestion`, its session offer, its end-of-turn question: sent to the dictation tool instead), `SessionStart` (voice rules), `UserPromptSubmit` (a message sent ends a free dictation), `PermissionRequest`, `Notification`.
- **The stable copy.** Each plugin version lives in its own folder, so a login service cannot point at it. The scripts are copied to `~/Library/Application Support/handfree-code/` by one function and one list (`refreshStableCopy`, `STABLE_FILES` in `handfree.js`): at `SessionStart`, voice mode on or off, and by every installer (`handfree.js --refresh-stable-copy`). The listener, the bridge and the app run that copy; a new `listener.py` or `voice-commands.json` restarts the listener, a new `bridge-server.py` the bridge (Python does not reload its code). A change reaches them only after a new session starts, or an install. The copy records the plugin version it came from (`version`): a session still on an older version does not put its scripts back, or the listener and the bridge would restart each time sessions of two versions alternate. An install copies whatever the version: the user asked for it. The app brings its own `mcp-relay.sh` (copied at build) and puts it there only when the copy has none.
- **The listener** (`bin/listener.py`, installed by `bin/install-listener.sh` as the login service `com.handfree-code.listener`) hears the spoken commands and runs `handfree.js` with the matching argument. See *Spoken commands*.
- **The Handfree Code app** (`app/`, Swift) takes every dictation: Claude's `handfree` MCP server is `bin/mcp-relay.sh`, which posts each JSON-RPC line to the app on `localhost:51290` (each request on its own, the answers written one at a time; the app not answering, a request gets an error at once). Its `ask_user_dictation` tool records an answer in the app's pill and returns `Q: …` / `A: …` (`(skipped by user)` on Escape). The plugin asks it directly too, over HTTP: a free dictation, a permission answer, and `dictation/insert` (record, then paste into the field in front and press Return) when Claude's field cannot be reached. It transcribes on the Mac (WhisperKit, or Apple's recognizer), and also shows a status panel and the settings. See *The app*.
- **The bridge** (optional) lets a cloud session speak through the Mac: `cloud-hook.py` forwards the hooks, `bridge-server.py` runs them locally and relays MCP calls to the app. See the README, *Cloud sessions*.

## Shared state

Every hook, voice command and the reader are separate short processes. They share one file, `~/Library/Caches/handfree-code/state.json`, behind a lock (`withState`): a folder holding its owner's token, taken over when older than 10 s, and removed only by the process that still owns it. Nothing slow runs under the lock (the player is asked, and paused or resumed, outside it), and a look that changes nothing writes nothing; a mere look without the lock is `readState`.

Old sessions keep running the plugin version they started with and write the same file, so a new field must be optional (missing means "off") and a field is never renamed. A state written with another `STATE_VERSION` is reset: **never bump it**, since each version would then wipe the other's state at every write.

### Words

- **A reading**: a reply queued to be read aloud, line by line (`current` while it is read, `queue` while it waits).
- **The pause**: where a reading stops ("Details available"), after its first paragraph; **the rest** is what follows it, read on "Continue", or on the answer "the rest" to a question.
- **A cut**: a reading "Claude Quiet" stopped mid-way (`cut`), taken back by "Continue".
- **A summary**: a long reply's gist, read before its question; **the details**: the full text it stands for (`detail`).
- **The hold**: while it is on, the reader starts nothing new, so that no voice talks over a dictation. Its owner is a free dictation ("Listen"), a session's question, or a permission request. In the code: `hold`, `releaseHold`, `releaseHoldOf`, `heldByAnother`, `isHeld`; in the state, the four `dictating_*`, `held_by`, `finishing_current` fields, whose names are older than the word.
- **A send-back**: a reply ending on a written question, turned back by the `Stop` hook so that Claude asks it through the dictation tool. Its hold waits for that question.
- **Session notes**: what is kept per session while it has a question going: `replies_before_question` (a reply sent back, still **to be read** before its question), `read_before_questions` (text **already read** before a question, not to be read again at its turn's end), `sent_backs` (the loop guard of send-backs).

### Fields

"Read by" names the other programs that read the file, besides `handfree.js`: a change to the field's meaning must reach them too.

| Field | Meaning | Read by |
|---|---|---|
| `current`, `queue` | the reply being read (its lines, `position`, `pause_at`) and the ones waiting | listener (`current.lines`, not to obey a command it reads aloud), app (`current`, `queue[].title`) |
| `cut`, `quiet_since` | the reply "Claude Quiet" cut, for "Continue"; when Quiet was last said | |
| `reader_pid`, `speaker_pid` | the reader process and the `say` (or `speak_command`) it runs | listener (`speaker_pid`), app (both) |
| `last_speech_end` | when the plugin's voice last stopped | listener (just stopped still counts as speaking) |
| `dictating_since`, `dictating_session` | the hold: its start, its owner (a session, `permission:<session>`, or none for "Listen"). Older than `max_dictation_seconds`, it holds nothing | listener, app (both judge it with `max_dictation_seconds`, as `isHeld` does) |
| `held_by` | `send_back`: the hold is a question sent back and not asked yet, which a message sent to that session frees | |
| `finishing_current` | a question waits for the reading under way to reach its pause | |
| `reading_requested` | "Claude Continue" or "Claude Restart" asked to read during a dictation | |
| `replies_before_question`, `sent_backs`, `read_before_questions` | the session notes (see *Words*). Dropped after a day | app (`sent_backs[session].question`, the question shown while it waits) |
| `detail` | the full text a summary stands for, read on "the details" | |
| `return_app` | the app to go back to after "Stop" | |
| `prompt_path`, `learning_since` | where the app's message field is in the accessibility tree; a search for it under way | |
| `voice_off` | voice mode is off: nothing is read, the listener stops | listener, app |
| `media_paused` | the plugin paused what was playing, to resume it after | |
| `last_speaker`, `announced_id`, `next_id` | the session read last (its name is said again only when the speaker changes), the reading last announced, the next reading's id | |

### Time limits

Claude Code stops a hook at its timeout (`hooks/hooks.json`), and each wait inside must leave room for what follows it. Through the bridge, each limit sits a little under the one around it.

| What | Limit | Where | Must stay under |
|---|---|---|---|
| The question hook (`--question`) | 120 s | `hooks.json` | |
| Waiting for another dictation, then the reading under way | 90 s together | `QUESTION_WAIT_SECONDS` | the hook |
| Reading before the question | until 85 s after the hook started | `QUESTION_READING_SECONDS` | the hook, with the question and the microphone after it (105 s through the bridge) |
| The answer hook (`--answered`, which reads "the rest") | 300 s | `hooks.json` | |
| The permission hook | 150 s | `hooks.json` | |
| Waiting for another dictation, then the answer | 40 s, then 90 s | `PERMISSION_WAIT_SECONDS`, `permission_answer_seconds` | the permission hook |
| A cloud hook's request to the bridge | 295 s for `--answered`, 25 s for `--guard-question`, 8 s for `--prompt-sent`, else 110 s | `cloud-hook.py` | the hook |
| The bridge running a hook | 290 s, 20 s, 6 s, else 105 s | `bridge-server.py` | the cloud hook's request |
| Claude waiting for the dictation tool | 120 s | the `handfree` server's `timeout`, given by every place that declares it | |
| A dictation's own recording | 900 s | `mcp-relay.sh`, `bridge-server.py` | the tool's timeout ends it first |
| A hold left behind | 180 s | `max_dictation_seconds` | |
| A lock left behind | 10 s (state), 20 s (speech) | `LOCK_STALE_SECONDS`, `SPEECH_LOCK_STALE_SECONDS` | the speaker touches its lock every 5 s |
| `media-control` answering | 3 s | `MEDIA_CONTROL_SECONDS` | |

Settings come from `~/.config/handfree-code.json` (`~/.config/claude-speak.json` before 0.3.2: `handfree.js` moves it, and the old state folder, once and leaves links), with defaults in `DEFAULTS` at the top of `handfree.js`; `CONFIG` is the defaults, the file and a cloud session's overrides. The README lists them.

## Reading a reply

1. `Stop` hook: the reply is split into speakable lines (Markdown removed, a code block becomes "Code block skipped", a link "link", a table row a sentence) and queued. `pause_at` is the end of its first paragraph.
2. If no reader runs, one starts (`--read`). It takes one line at a time from the state, says it, and moves on. Between lines it re-reads the state, so a voice command changes what happens next.
3. At `pause_at` it says "Details available" once and stops. The voice rules ask Claude to open a long reply with a summary of all of it, so the first paragraph is the gist. "Claude Continue" moves `pause_at` to the end; "Claude Restart" starts over; "Claude Quiet" kills the reader and our own `say` (`speaker_pid` and its children, never another `say` on the Mac), and moves the reply it cut to `cut`: the next reply is read from its start, and "Continue" (or "Restart") brings the cut one back first, from its cut line, the one being read then going back to the head of the queue. A second Quiet keeps the first cut reply in `cut` and puts the second at the head of the queue, read after it.
4. A session's name is said when the speaker changes (`announce_session`). Music is paused while speaking and resumed after.
5. Readings from several sessions wait their turn in the queue, first in, first out. A turn started by another session is not read: its parent relays the result.

## One voice at a time

Music or a video playing is paused while the plugin speaks and while you dictate, then resumed; paused by us but playing again (resumed by hand), it is paused again. Every line is said under a speech lock (`speech.lock` in the state folder), whichever process says it: the reader, a question, "the rest". A line cut short (Quiet, a question) frees it.

## Questions

Claude must ask through the dictation tool: the app's buttons and box are not read aloud and cannot be answered by voice. The voice rules injected at `SessionStart` say so, and the `Stop` hook enforces it.

1. **The reply stays written.** Claude writes its full reply, question last, and ends its turn. The `Stop` hook sees a reply ending on a question, or a question in the app's end-of-turn box, and sends the turn back (`decision: block`): "ask it with the dictation tool, the question alone". The reply, minus its question paragraph, goes to `replies_before_question`, and the queue is held from then on (`held_by: send_back`): other sessions finish what they are reading and wait for the question. Never asked (Escape, a message typed instead), the hold goes with the next message sent to that session (`UserPromptSubmit`) or its next turn end. The reply and the loop guard below are kept per session: several sessions may be sent back at once. Every new question is sent back, also later in a turn already sent back (Claude Code then sets `stop_hook_active`): a turn that goes through several questions, one answer after another, asks each aloud. What prevents a loop is `sent_backs`, per session: the same question is not sent back twice in a row, nor more than three with none asked in between, whatever other sessions do meanwhile. Text written just before a tool call cannot be used instead: the desktop app can store it as a hidden thinking block.
2. **A long reply comes summed up.** When more than a few lines follow the first paragraph, the send-back also asks Claude for a two- or three-sentence summary in the question, unless the first paragraph already sums the reply up (as the voice rules ask). With no summary in the question, the first paragraph stands for it: either way, one summary is read, never two.
3. **Before speaking** (`PreToolUse`, `--question`): another session's question, or a free dictation, under way is waited for first: the app records one at a time. Then the reading under way in any session goes on to its pause (`finishing_current`), then nothing else starts. Two voices at once are not understood, and the dictation would record the other one. Both waits share one deadline, 90 s, inside the hook's 120: another dictation still under way then, the call is refused and Claude asks in writing. A reply of the same session still in the queue (another session was reading) is read first, to its pause; what is left of it (after its pause, or cut short) goes back to the head of the queue.
4. **Reading**: only the text written since the last user entry (a message, or an earlier question's answer) counts as written before the question; then the reply's first paragraph (whatever Claude put in the question itself is read in full: it chose to say it), then the summary and "answer 'the details' to hear it all" (the first paragraph alone when it is the summary), then "A question" and the question. Lines said in a row stop at "Quiet" (`quiet_since`), and 85 s after the hook started, however long it waited, so that the question and the microphone still fit in its time (120 s, 105 through the bridge; see *Time limits*); the question itself is always said, and the lines not said are kept for "the rest". Half a second later (`say` returns with the end of its line still in the speakers, and the microphone opening would make it crackle), the hook marks the dictation as started.
5. **The answer** (`PostToolUse`, `--answered`):
   - "the rest" / "the details": what was left out is read, and the turn is sent back to ask again (`ASK_AGAIN`). A long rest without a summary yet makes Claude ask again with one (`ASK_SUMMARY`). Other sessions keep waiting meanwhile.
   - Anything else is a real answer: the queue goes on. The answer frees the queue, not "Stop": the key comes first, and a reading started then would talk over the question asked again.
6. **Questions shown only on screen.** The app's multiple-choice window (`AskUserQuestion`) its "start this in a new session?" card (`start_session` with `initiation: "offer"`) and the question of its end-of-turn box (`wrap_up` with an `ask`) wait for a click and are never read. A `PreToolUse` hook (`--guard-question`) refuses them in voice mode. The refusal does not stop Claude: it reads the reason as the tool's result and asks through the dictation tool instead, which then goes through the steps above.
7. **Away from the Mac** (no keyboard or mouse for `away_after_idle_seconds`): the dictation call is refused and Claude asks in writing; the `Stop` hook no longer sends written questions back.

Answers may come with accents decomposed (NFD): they are normalized before they are compared.

## Spoken commands

`bin/listener.py` reads its commands and their default phrases from `bin/voice-commands.json`, next to it in the stable copy (a change to either restarts it), then reads the microphone continuously: the app's (`AudioFeed.swift` records the default microphone while a listener is connected to `localhost:51291`, and sends it as 16 kHz 16-bit mono; a new default microphone restarts its recording, the app gone restarts the listener). It waits 15 s for the app at start; without it, it records itself (sounddevice), watches the default microphone, and starts over once the app's sound is back. Either way it passes the sound to Vosk, offline, with a closed grammar: the commands' phrases and an "unknown" word. Anything else is heard as unknown. No sound is kept.

- **Said alone.** A phrase counts only when a short silence (0.3 s) sets it apart from anything else heard: a breath before it is fine, a command inside a sentence is not. Vosk gives each word's timing (`SetWords`).
- **Checked by free recognition.** A second recognizer, without the grammar, transcribes the same audio. The grammar maps any speech to its nearest phrase; when the free transcription of the moment the command was said (its words' times, 0.3 s either side) is clearly other words (similarity under 0.8; "stop" needs the word itself), the command is refused. Nothing or next to nothing transcribed keeps it: short commands are often lost there. Each command taken is logged with what the free transcription heard.
- **"Stop" waits for silence**: heard during a dictation, it runs once a second of silence follows; speech going on drops it.
- **What the state allows** (read from the shared state at each phrase): voice mode off, nothing (the plugin stops the listener altogether); a dictation under way, only "Stop" and "Cancel"; the plugin speaking, only Quiet, Continue and Restart, and not a phrase found in the text being read; otherwise every command but "Stop". A voice noted as speaking whose process is gone does not count.
- **Running a command**: a short system sound, then `handfree.js` with the argument (`--listen`, `--reply`, `--search-session`, `--quiet`, `--continue`, `--restart`, `--on`, `--off`). "Stop" first presses Return, then runs `--done`; "Cancel" presses Escape, which cancels the dictation in the app's pill, then runs `--cancel` (a free dictation ends, the app it was said in comes back). The keys are pressed by the app (`keys/press` on `localhost:51290`, with its Accessibility); without it, by System Events, which needs Python's.
- **The microphone** is the app's (`Microphone.swift`): the system's default input, followed when it changes (AirPods put on), or the one chosen in Settings > Dictation (`microphone`, part of a device's name; `listener_device` before 0.3.2), for the dictation and the listener alike. It is recorded alone, through an audio queue (`MicrophoneQueue`), and opened once: a dictation under way takes the listener's sound when it runs. AVAudioEngine is not used: it records through an aggregate device that holds the speakers too, and with it running, opening a dictation made macOS play the end of the last sound again ("…cro, cro, cro" after a question read aloud). Without the app, the listener records the default input itself, checked every 4 s: when it changes, it exits and its service starts it again on the new one.
- **Its log** keeps the commands run (every phrase heard with `listener_log`), trimmed past 200 KB like the other logs.

What each command then does:

- **"Claude Listen"** (`--listen`): stops the reading. Said in another app with Claude reachable, see *Claude left behind*. Otherwise it brings Claude forward and, its field reachable, dictates the same way: through the app's pill (`--dictate-behind -`), the plugin sending the text. The app then answers even an Escape, which frees the readings, the music and the app to go back to. Only when the field cannot be reached does it click the field (found by its accessibility path, learnt in the background when the layout changes) and ask the app for `dictation/insert`: the app records, brings the app in front back, pastes the text through the clipboard (given back its contents afterwards) and presses Return; on Escape it runs `--cancel`.
- **"Stop"** presses Return, which ends the dictation in the app's pill (the app came forward for it, so the key reaches it), then runs `--done`: a free dictation ends there; a question's is freed by its answer instead. A message sent any other way (Return typed, a click) ends a free dictation too: `UserPromptSubmit` runs `--prompt-sent`.
- **Going back.** If "Listen" was said in another app, that app is noted (`return_app`). After "Stop", a background process (`--go-back`) waits until the message has left, then brings that app back. The app pastes and sends only while Claude is in front, so going back earlier would lose the message. "Left" means Claude Code wrote a `queue-operation` `enqueue` entry to a local transcript after the "Stop"; it does this whether the session is at rest or working. No such entry within 30 s, for a cloud session say: Claude stays in front.
- **Claude left behind** (`dictate_behind`). Said in another app, with Claude's message field reachable through accessibility (its stored path still valid, and a window to see: Claude in full screen shows none to another Space), "Listen" and "Reply" start `--dictate-behind` in the background. "Reply" first opens its session through its link; the app comes forward on its links even with `open -g`, so the app it was said in is brought back at once (Claude shows for a moment), and only if that fails does the usual way take over. The app records in its pill (its HTTP API, as for permissions) and returns the text; the plugin gives the field the focus, sets its value, waits for the "Send" button (it shows once the app has taken the text in, about a second later) and presses it. Sent means a `queue-operation` entry, or, for a cloud session, an empty field; otherwise Claude comes forward with the text waiting and "Message not sent" is said. Accessibility reads lag behind the app by about a second.
- **"Claude Reply"** first checks which session the app shows (the session file with the latest `lastFocusedAt`); when it is already the one that spoke last, nothing is opened. Otherwise it opens the session that spoke last through the app's link (`claude://code/continue?session=local_…`, found in the app's session files), then does what "Listen" does. **"Claude Session"** opens the app's search.

## The app

`app/` is a Swift package (SwiftPM, macOS 14), built on each Mac by `app/install.sh`: nothing prebuilt is downloaded but its packages (WhisperKit, pinned to 0.9.4, the last one Xcode 15's Swift 5.10 builds). The install signs it with a certificate made once in the login keychain ("Handfree Code Local Signing"): macOS ties the app's permissions (microphone, Accessibility, speech recognition) to that identity, so they survive rebuilds; an ad hoc signature would change at each build. A rebuild keeps the identity that signs the installed app, when the keychain still has it (`HANDFREE_SIGNING_IDENTITY` picks another): a new one would make it a new app to macOS, its permissions to give again. It runs as an agent (no Dock icon), started at login by `~/Library/LaunchAgents/com.handfree-code.app.plist`.

- **`Server.swift`**: the local address (`localhost:51290`, local connections only). A request with an `Origin` header or another `Host` (a web page) is refused, and a body over 1 MB. `keys/press` and `dictation/insert` need `X-Handfree-Secret`, the secret the app writes at launch to `~/Library/Application Support/handfree-code/app-secret` (0600); the plugin sends it from the file through curl's standard input, never on a command line. The listener's sound (`AudioFeed.swift`, `localhost:51291`) is sent only after the same secret as the connection's first line. MCP's `initialize`, `tools/list`, `tools/call` (`ask_user_dictation`, refused with an error while another dictation is under way rather than cutting it short), notifications answered `202`; `dictation/insert`, answered at once, and `keys/press` (Return or Escape for the listener, with the app's Accessibility). It also declares the `handfree` MCP server (the app's Services tab), with the relay bundled at build time from `bin/mcp-relay.sh`.
- **`DictationSession.swift`**: one dictation. The recording (the listener's sound, or the microphone opened for it; the raw input kept and resampled to 16 kHz in one pass, then brought to a steady level: converting buffer by buffer leaves clicks Whisper mishears), the engines, the end (Return, "stop" at the end of the text, a silence after speech, or Escape), Whisper's phantom phrases dropped (on silence it writes subtitle credits, "Sous-titrage Société Radio-Canada", "Thanks for watching": a silent dictation comes out empty, so skipped).
- **`Dictation.swift`**: who asks for a dictation (a question, `dictation/insert`), one at a time: a question while another dictation is under way is refused, never cut short. What happens with the text, and the *Dictation* tab. The last dictation's sound and text go to `~/Library/Caches/handfree-code/`. **`DictationPill.swift`**: the pill it records in. **`WhisperModels.swift`**: the engines and the Whisper models (downloaded from WhisperKit's repository, loaded once at launch and kept: the first load has macOS prepare the model for the chip, minutes for the large ones). **`Sounds.swift`**: the sounds.
- **The icon** is the halo: `install.sh` runs the built binary with `--render-icon`, which draws `AppIcon` (the same drawing as the panel's halo, still) to a PNG, then `sips` and `iconutil` make `AppIcon.icns`.
- **`VoiceCommands.swift`**: the *Voice commands* and *Sounds* tabs, and the global keyboard shortcuts (Carbon hot keys, no permission needed), one per command but Stop and Cancel, each running the command's argument of `handfree.js`. The commands, their arguments and their default phrases come from `bin/voice-commands.json`, copied into the app at build and read by the listener too. The phrases chosen go to `voice_commands` by command id (an old Voice Control name for the same command is removed), and Stop's first one to `validation_word`, the word that ends a dictation in the app and is stripped from answers. The shortcuts live in the app's defaults (`shortcut.<id>`): absent is the default (⌃⌥L, ⌃⌥R, ⌃⌥Q, ⌃⌥V for Listen, Reply, Quiet, Voice mode on), empty is none. Voice mode on has no phrase: voice mode off stops the listener. A modifier tapped twice alone is not a Carbon hot key: `ModifierTaps` watches the modifier keys (a global monitor, which needs Accessibility, and a local one) and `TapDetector` tells a double tap (each press under 0.3 s, the two within 0.4 s, nothing else pressed). While one is typed, the hot keys and the taps are paused, or the window would never see it. The settings window turns the app into a regular one (Dock icon, a main menu for ⌘W and the editing keys) until it closes: an agent app's window does not reliably get the keyboard.
- **`main.swift`**: the start, the windows and the menu bar light. **`StateMonitor.swift`**: what the panel shows, `state.json` read four times a second and the sessions from the app's session files, never written. **`Panel.swift`** and **`Halo.swift`**: the panel, full screen and the halo; while the plugin reads, their *Stop reading* button (and the menu's) runs `handfree.js --quiet`. **`Plugin.swift`**: the plugin's paths and settings (its file edited in place: a default value removes its key). **`SettingsWindow.swift`**: the settings window. **`Services.swift`**: the services (the listener, the bridge and the tunnel's command through `launchctl`).
- **`Cloud.swift`**: the *Cloud sessions* tab. It runs `install-bridge.sh` from the stable copy (as `/handfree-code:bridge` does): set up the bridge, new keys, the tunnel's command applied, the address checked (`--check`, whose exit codes the tab words in the interface's language). The values for claude.ai are shown or copied only after `LAContext`'s owner authentication (Touch ID or the password), and hidden again after a minute.
- **Text**: English in the code, French in `app/Resources/fr.lproj` and German in `app/Resources/de.lproj` (the code's English text is the key, or a `command.…` key when one English word means two things); macOS picks the user's language, or the one chosen in Settings (the app's `AppleLanguages`, read at start).

## Permissions by voice

With `voice_permissions` on, `PermissionRequest` reads the request, asks the app directly over HTTP and returns allow or deny on a clear yes or no. Anything unclear leaves the usual dialog. Like a question, it first waits for another dictation (40 s, inside the hook's 150 with the answer's 90; still busy, the dialog shows) and holds the readings under its own name, `permission:<session>`, so that its answer frees that hold only.

## Cloud sessions

A cloud session runs the same hooks on Linux: `hook.sh` hands them to `cloud-hook.py`, which posts them, with the end of the transcript the Mac cannot read, to the bridge through the tunnel. The bridge runs `handfree.js` with that input. Questions go through the bridge's `/mcp`, relayed to the app: only `initialize`, notifications, `tools/list` and the `ask_user_dictation` call; anything else (`keys/press`, `dictation/insert`, another tool) is refused with a 403, since a cloud session holds the token. The bridge only accepts reading settings from a cloud session (`CLOUD_OVERRIDABLE`), never a program to run.

The Mac's part knows no tunnel provider. `install-bridge.sh` makes the keys, writes the bridge's login agent, and, when `tunnel_command` is set, one for the tunnel (`com.handfree-code.tunnel`, the command run by `/bin/sh` with Homebrew's paths; removed when the setting is empty). Its `--check` posts to `bridge_url` + `/ping` with the token and the edge key: only this bridge answers `handfree-bridge`, so a provider's own service running, or another server behind the address, never passes for a working tunnel. A 403 is the provider's rule, a 401 a bridge with other keys, a 502 to 504 or 530 the provider without its tunnel.

## Things that break easily

- **Undocumented behaviour** of the Claude app and Claude Code: the "Prompt" field's accessibility name, the `claude://` links, the app's session files, the transcript format (`turnOrigin`, `queue-operation`, custom titles). Each has a fallback; the README's *Known limitations* lists them.
- **`doShellScript`** returns lines separated by `\r`, not `\n`.
- **Hooks** are loaded when a session starts: test a change in a new session.
- **The sandbox** blocks `~/Library/Caches/handfree-code/`: the plugin's commands and the tests run outside it.
- **MediaRemote** (pausing music) is a private framework, restricted since macOS 15.4. There, `media-control` (Homebrew) is used when installed: `media-control get` gives `"playing"` in JSON (`null` when nothing has a Now Playing state), `pause` and `play` drive it. Up to 15.3, MediaRemote is called directly.
