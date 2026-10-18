# How handfree-code works

What happens between Claude Code, the Mac's voice, Spokenly and the spoken-commands listener, and why it is built this way. The [README](../README.md) says how to install and use it; this page is for whoever changes it.

## The pieces

```
Claude Code ──hooks──▶ bin/hook.sh ──▶ handfree.js (osascript, on the Mac)
                                   └─▶ cloud-hook.py ──tunnel──▶ bridge-server.py ──▶ handfree.js
microphone ──▶ listener.py (Vosk) ──▶ ~/Library/Application Support/handfree-code/handfree.js (stable copy)
Claude ──MCP──▶ Spokenly (ask_user_dictation): the spoken questions
```

- **`bin/handfree.js`** does nearly everything. It runs with `osascript -l JavaScript`, which every Mac has, so the plugin needs no Node or Python on the Mac. The command-line argument picks the job; the comment at the top of the file lists them.
- **`hooks/hooks.json`** wires Claude Code's hooks to it: `Stop` (a reply to read), `PreToolUse` / `PostToolUse` on the Spokenly tool (a question), `SessionStart` (voice rules), `PermissionRequest`, `Notification`.
- **The stable copy.** Each plugin version lives in its own folder, so a login service cannot point at it. `SessionStart` copies the scripts to `~/Library/Application Support/handfree-code/`; the listener and the bridge run that copy, and a new `listener.py` restarts the listener. A change reaches them only after a new session starts.
- **The listener** (`bin/listener.py`, installed by `bin/install-listener.sh` as the login service `com.handfree-code.listener`) hears the spoken commands and runs `handfree.js` with the matching argument. See *Spoken commands*.
- **Spokenly** asks the questions: its MCP tool records an answer in its own window and returns the text. For a free dictation ("Claude Listen"), Spokenly types into the app in front.
- **The bridge** (optional) lets a cloud session speak through the Mac: `cloud-hook.py` forwards the hooks, `bridge-server.py` runs them locally and relays MCP calls to Spokenly. See the README, *Cloud sessions*.

## Shared state

Every hook, voice command and the reader are separate short processes. They share one file, `~/Library/Caches/claude-speak/state.json`, behind a lock (`withState`). A state written with another `STATE_VERSION` is reset. Old sessions keep running the plugin version they started with and write the same file, so a new field must be optional: missing means "off".

Main fields:

| Field | Meaning |
|---|---|
| `current`, `queue` | the reply being read (its lines, `position`, `pause_at`) and the ones waiting |
| `reader_pid`, `speaker_pid` | the reader process and the `say` (or `speak_command`) it runs |
| `dictating_since`, `dictating_session` | a question or dictation is under way: nothing new is read |
| `finishing_current` | a question waits for the reading under way to reach its pause |
| `reading_requested` | "Claude Continue" or "Claude Restart" asked to read during a dictation |
| `reply_before_question` | a written reply sent back to have its question asked aloud (see *Questions*) |
| `detail` | the full text a summary stands for, read on "the details" |
| `return_app` | the app to go back to after "Stop" |
| `prompt_path` | where the app's message field is in the accessibility tree |

Settings come from `~/.config/claude-speak.json`, with defaults in `CONFIG` at the top of `handfree.js`. The README lists them.

## Reading a reply

1. `Stop` hook: the reply is split into speakable lines (Markdown removed, a code block becomes "Code block skipped", a link "link", a table row a sentence) and queued. `pause_at` is the end of its first paragraph.
2. If no reader runs, one starts (`--read`). It takes one line at a time from the state, says it, and moves on. Between lines it re-reads the state, so a voice command changes what happens next.
3. At `pause_at` it says "Details available" once and stops. The voice rules ask Claude to open a long reply with a summary of all of it, so the first paragraph is the gist. "Claude Continue" moves `pause_at` to the end; "Claude Restart" starts over; "Claude Quiet" kills the reader and `say`.
4. A session's name is said when the speaker changes (`announce_session`). Music is paused while speaking and resumed after.
5. Readings from several sessions wait their turn in the queue. A turn started by another session is not read: its parent relays the result.

## One voice at a time

Music or a video playing is paused while the plugin speaks and while you dictate, then resumed; paused by us but playing again (resumed by hand), it is paused again. Every line is said under a speech lock (`speech.lock` in the state folder), whichever process says it: the reader, a question, "the rest". A line cut short (Quiet, a question) frees it.

## Questions

Claude must ask through Spokenly: the app's buttons and box are not read aloud and cannot be answered by voice. The voice rules injected at `SessionStart` say so, and the `Stop` hook enforces it.

1. **The reply stays written.** Claude writes its full reply, question last, and ends its turn. The `Stop` hook sees a reply ending on a question, or a question in the app's end-of-turn box, and sends the turn back (`decision: block`): "ask it with the Spokenly tool, the question alone". The reply, minus its question paragraph, goes to `reply_before_question`, and the queue is held from then on: other sessions finish what they are reading and wait for the question. Every new question is sent back, also later in a turn already sent back (Claude Code then sets `stop_hook_active`): a turn that goes through several questions, one answer after another, asks each aloud. What prevents a loop is `sent_back`: the same question is not sent back twice in a row, nor more than three with none asked in between. Text written just before a tool call cannot be used instead: the desktop app can store it as a hidden thinking block.
2. **A long reply comes summed up.** When more than a few lines follow the first paragraph, the send-back also asks Claude for a two- or three-sentence summary in the question, unless the first paragraph already sums the reply up (as the voice rules ask). With no summary in the question, the first paragraph stands for it: either way, one summary is read, never two.
3. **Before speaking** (`PreToolUse`, `--question`): another session's question, or a free dictation, under way is waited for first (up to 60 s): Spokenly records one at a time. Then the reading under way in any session goes on to its pause (`finishing_current`, at most 60 s), then nothing else starts. Two voices at once are not understood, and Spokenly would record the other one.
4. **Reading**: the reply's first paragraph (whatever Claude put in the question itself is read in full: it chose to say it), then the summary and "answer 'the details' to hear it all" (the first paragraph alone when it is the summary), then "A question" and the question. The hook then marks the dictation as started.
5. **The answer** (`PostToolUse`, `--answered`):
   - "the rest" / "the details": what was left out is read, and the turn is sent back to ask again (`ASK_AGAIN`). A long rest without a summary yet makes Claude ask again with one (`ASK_SUMMARY`). Other sessions keep waiting meanwhile.
   - Anything else is a real answer: the queue goes on. The answer frees the queue, not "Stop": the key comes first, and a reading started then would talk over the question asked again.
6. **Questions shown only on screen.** The app's multiple-choice window (`AskUserQuestion`) and its "start this in a new session?" card (`start_session` with `initiation: "offer"`) wait for a click and are never read. A `PreToolUse` hook (`--guard-question`) refuses them in voice mode. The refusal does not stop Claude: it reads the reason as the tool's result and asks through Spokenly instead, which then goes through the steps above.
7. **Away from the Mac** (no keyboard or mouse for `away_after_idle_seconds`): the Spokenly call is refused and Claude asks in writing; the `Stop` hook no longer sends written questions back.

Spokenly may hand accents decomposed (NFD): answers are normalized before they are compared.

## Spoken commands

`bin/listener.py` reads the microphone continuously and passes it to Vosk, offline, with a closed grammar: the commands' phrases and an "unknown" word. Anything else is heard as unknown. No sound is kept.

- **Said alone.** A phrase counts only when a short silence (0.3 s) sets it apart from anything else heard: a breath before it is fine, a command inside a sentence is not. Vosk gives each word's timing (`SetWords`).
- **Checked by free recognition.** A second recognizer, without the grammar, transcribes the same audio. The grammar maps any speech to its nearest phrase; when the free transcription of the moment the command was said (its words' times, 0.3 s either side) is clearly other words (similarity under 0.8; "stop" needs the word itself), the command is refused. Nothing or next to nothing transcribed keeps it: short commands are often lost there.
- **"Stop" waits for silence**: heard during a dictation, it runs once a second of silence follows; speech going on drops it.
- **What the state allows** (read from the shared state at each phrase): voice mode off, nothing (the plugin stops the listener altogether); a dictation under way, only "Stop" and "Cancel"; the plugin speaking, only Quiet, Continue and Restart, and not a phrase found in the text being read; otherwise every command but "Stop". A voice noted as speaking whose process is gone does not count.
- **Running a command**: a short system sound, then `handfree.js` with the argument (`--listen`, `--reply`, `--search-session`, `--stop`, `--resume`, `--restart`, `--on`, `--off`). "Stop" first presses Return (System Events), then runs `--done`; "Cancel" presses Escape, which cancels Spokenly, then runs `--cancel` (a free dictation ends, the app it was said in comes back). Python's app needs Accessibility for the keys, here and for starting Spokenly.
- **The microphone** is the system's default input, checked every 4 s: when it changes (AirPods put on), the listener exits and its service starts it again on the new one. `listener_device` pins one instead.
- **Its log** keeps the commands run (every phrase heard with `listener_log`), trimmed past 200 KB like the other logs.

What each command then does:

- **"Claude Listen"** (`--listen`): stops the reading. Said in another app with Claude reachable, see *Claude left behind*. Otherwise it brings Claude forward and, its field reachable, dictates the same way: through Spokenly's window (`--dictate-behind -`), the plugin sending the text. Spokenly then answers even an Escape, which frees the readings, the music and the app to go back to. Only when the field cannot be reached does it click the field (found by its accessibility path, learnt in the background when the layout changes) and start Spokenly with a double tap on right Command, Spokenly typing the text.
- **"Stop"** presses Return, which in Spokenly's Quick Send mode inserts the transcript and sends it, then runs `--done`: a free dictation ends there; a question's is freed by its answer instead. A message sent any other way (Return typed, a click) ends a free dictation too: `UserPromptSubmit` runs `--prompt-sent`.
- **Going back.** If "Listen" was said in another app, that app is noted (`return_app`). After "Stop", a background process (`--go-back`) waits until the message has left, then brings that app back. Spokenly inserts and sends only while Claude is in front, so going back earlier would lose the message. "Left" means Claude Code wrote a `queue-operation` `enqueue` entry to a local transcript after the "Stop"; it does this whether the session is at rest or working. No such entry within 30 s, for a cloud session say: Claude stays in front.
- **Claude left behind** (`dictate_behind`). Said in another app, with Claude's message field reachable through accessibility (its stored path still valid, and a window to see: Claude in full screen shows none to another Space), "Listen" and "Reply" start `--dictate-behind` in the background. "Reply" first opens its session through its link; the app comes forward on its links even with `open -g`, so the app it was said in is brought back at once (Claude shows for a moment), and only if that fails does the usual way take over. Spokenly records in its own window (its HTTP API, as for permissions) and returns the text; the plugin gives the field the focus, sets its value, waits for the "Send" button (it shows once the app has taken the text in, about a second later) and presses it. Sent means a `queue-operation` entry, or, for a cloud session, an empty field; otherwise Claude comes forward with the text waiting and "Message not sent" is said. Accessibility reads lag behind the app by about a second.
- **"Claude Reply"** first checks which session the app shows (the session file with the latest `lastFocusedAt`); when it is already the one that spoke last, nothing is opened. Otherwise it opens the session that spoke last through the app's link (`claude://code/continue?session=local_…`, found in the app's session files), then does what "Listen" does. **"Claude Session"** opens the app's search.

## Permissions by voice

With `voice_permissions` on, `PermissionRequest` reads the request, asks Spokenly directly over HTTP and returns allow or deny on a clear yes or no. Anything unclear leaves the usual dialog.

## Cloud sessions

A cloud session runs the same hooks on Linux: `hook.sh` hands them to `cloud-hook.py`, which posts them, with the end of the transcript the Mac cannot read, to the bridge through the tunnel. The bridge runs `handfree.js` with that input. Questions go through the bridge's `/mcp`, relayed to Spokenly. The bridge only accepts reading settings from a cloud session (`CLOUD_OVERRIDABLE`), never a program to run.

## Things that break easily

- **Undocumented behaviour** of the Claude app and Claude Code: the "Prompt" field's accessibility name, the `claude://` links, the app's session files, the transcript format (`turnOrigin`, `queue-operation`, custom titles). Each has a fallback; the README's *Known limitations* lists them.
- **`doShellScript`** returns lines separated by `\r`, not `\n`.
- **Hooks** are loaded when a session starts: test a change in a new session.
- **The sandbox** blocks `~/Library/Caches/claude-speak/`: the plugin's commands and the tests run outside it.
- **MediaRemote** (pausing music) is a private framework, restricted since macOS 15.4. There, `media-control` (Homebrew) is used when installed: `media-control get` gives `"playing"` in JSON (`null` when nothing has a Now Playing state), `pause` and `play` drive it. Up to 15.3, MediaRemote is called directly.
