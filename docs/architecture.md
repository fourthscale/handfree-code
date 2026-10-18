# How handfree-code works

What happens between Claude Code, the Mac's voice, Spokenly and Voice Control, and why it is built this way. The [README](../README.md) says how to install and use it; this page is for whoever changes it.

## The pieces

```
Claude Code ──hooks──▶ bin/hook.sh ──▶ handfree.js (osascript, on the Mac)
                                   └─▶ cloud-hook.py ──tunnel──▶ bridge-server.py ──▶ handfree.js
Voice Control ──▶ Shortcuts ──▶ ~/Library/Application Support/handfree-code/handfree.js (stable copy)
Claude ──MCP──▶ Spokenly (ask_user_dictation): the spoken questions
```

- **`bin/handfree.js`** does nearly everything. It runs with `osascript -l JavaScript`, which every Mac has, so the plugin needs no Node or Python on the Mac. The command-line argument picks the job; the comment at the top of the file lists them.
- **`hooks/hooks.json`** wires Claude Code's hooks to it: `Stop` (a reply to read), `PreToolUse` / `PostToolUse` on the Spokenly tool (a question), `SessionStart` (voice rules), `PermissionRequest`, `Notification`.
- **The stable copy.** Each plugin version lives in its own folder, so the Shortcuts cannot point at it. `SessionStart` copies the scripts to `~/Library/Application Support/handfree-code/`, and the Shortcuts call that copy. A change reaches the voice commands only after a new session starts.
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

## Questions

Claude must ask through Spokenly: the app's buttons and box are not read aloud and cannot be answered by voice. The voice rules injected at `SessionStart` say so, and the `Stop` hook enforces it.

1. **The reply stays written.** Claude writes its full reply, question last, and ends its turn. The `Stop` hook sees a reply ending on a question, or a question in the app's end-of-turn box, and sends the turn back (`decision: block`): "ask it with the Spokenly tool, the question alone". The reply, minus its question paragraph, goes to `reply_before_question`. Text written just before a tool call cannot be used instead: the desktop app can store it as a hidden thinking block.
2. **A long reply comes summed up.** When more than a few lines follow the first paragraph, the send-back also asks Claude for a two- or three-sentence summary in the question, unless the first paragraph already sums the reply up (as the voice rules ask). With no summary in the question, the first paragraph stands for it: either way, one summary is read, never two.
3. **Before speaking** (`PreToolUse`, `--question`): the reading under way in any session goes on to its pause (`finishing_current`, at most 60 s), then nothing else starts. Two voices at once are not understood, and Spokenly would record the other one.
4. **Reading**: the reply's first paragraph, then the summary and "answer 'the details' to hear it all" (the first paragraph alone when it is the summary), then "A question" and the question. The hook then marks the dictation as started.
5. **The answer** (`PostToolUse`, `--answered`):
   - "the rest" / "the details": what was left out is read, and the turn is sent back to ask again (`ASK_AGAIN`). A long rest without a summary yet makes Claude ask again with one (`ASK_SUMMARY`). Other sessions keep waiting meanwhile.
   - Anything else is a real answer: the queue goes on.
6. **Questions shown only on screen.** The app's multiple-choice window (`AskUserQuestion`) and its "start this in a new session?" card (`start_session` with `initiation: "offer"`) wait for a click and are never read. A `PreToolUse` hook (`--guard-question`) refuses them in voice mode. The refusal does not stop Claude: it reads the reason as the tool's result and asks through Spokenly instead, which then goes through the steps above.
7. **Away from the Mac** (no keyboard or mouse for `away_after_idle_seconds`): the Spokenly call is refused and Claude asks in writing; the `Stop` hook no longer sends written questions back.

Spokenly may hand accents decomposed (NFD): answers are normalized before they are compared.

## Voice commands

Voice Control recognizes a phrase and runs a Shortcut, which runs `handfree.js` with a command. A command is only recognized when spoken alone, hence the pause between read lines.

- **"Claude Listen"** (`--listen`): stops the reading, brings Claude forward, clicks its message field (found by its accessibility path, learnt in the background when the layout changes) and starts Spokenly with a double tap on right Command.
- **"Stop"** presses Return, which in Spokenly's Quick Send mode inserts the transcript and sends it, then runs `--done`: the queue goes on.
- **Going back.** If "Listen" was said in another app, that app is noted (`return_app`). After "Stop", a background process (`--go-back`) waits until the message has left, then brings that app back. Spokenly inserts and sends only while Claude is in front, so going back earlier would lose the message. "Left" means Claude Code wrote a `queue-operation` `enqueue` entry to a local transcript after the "Stop"; it does this whether the session is at rest or working. No such entry within 30 s, for a cloud session say: Claude stays in front.
- **"Claude Reply"** opens the session that spoke last through the app's link (`claude://code/continue?session=local_…`, found in the app's session files), then does what "Listen" does. **"Claude Session"** opens the app's search.

## Permissions by voice

With `voice_permissions` on, `PermissionRequest` reads the request, asks Spokenly directly over HTTP and returns allow or deny on a clear yes or no. Anything unclear leaves the usual dialog.

## Cloud sessions

A cloud session runs the same hooks on Linux: `hook.sh` hands them to `cloud-hook.py`, which posts them, with the end of the transcript the Mac cannot read, to the bridge through the tunnel. The bridge runs `handfree.js` with that input. Questions go through the bridge's `/mcp`, relayed to Spokenly. The bridge only accepts reading settings from a cloud session (`CLOUD_OVERRIDABLE`), never a program to run.

## Things that break easily

- **Undocumented behaviour** of the Claude app and Claude Code: the "Prompt" field's accessibility name, the `claude://` links, the app's session files, the transcript format (`turnOrigin`, `queue-operation`, custom titles). Each has a fallback; the README's *Known limitations* lists them.
- **`doShellScript`** returns lines separated by `\r`, not `\n`.
- **Hooks** are loaded when a session starts: test a change in a new session.
- **The sandbox** blocks `~/Library/Caches/claude-speak/`: the plugin's commands and the tests run outside it.
- **MediaRemote** (pausing music) is a private framework, restricted since macOS 15.4.
