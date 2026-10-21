#!/bin/sh
# Silent tests: a fake `say` writes to a log, state and config live in a scratch folder.
# Usage: tests/run.sh   (needs no sound, does not touch your real state)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/bin/handfree.js"
WORK=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM
free_port() { /usr/bin/python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
DICTATION_PORT=$(free_port); APP_PORT=$(free_port); DEAD_PORT=$(free_port)
export HANDFREE_STATE_DIR="$WORK/state" HANDFREE_CONFIG="$WORK/config.json" HANDFREE_SAY_LOG="$WORK/said.log"
# The stable copy and the services stay the test's own: the real ones are never touched.
export HANDFREE_SUPPORT_DIR="$WORK/support" HANDFREE_LAUNCH_AGENTS_DIR="$WORK/agents" HANDFREE_RESTART_LOG="$WORK/restarted.log"
# Nothing reaches this Mac's media, keys or app: media commands go to a log, the app's address answers nobody, and
# Claude's settings are a fixture declaring the dictation tool. Every osascript run here (sh -c too) inherits them.
export HANDFREE_NOW_PLAYING=unknown HANDFREE_AUDIO_PLAYING=0 HANDFREE_IDLE_SECONDS=0 HANDFREE_MEDIA_CONTROL= HANDFREE_MEDIA_KEY_LOG="$WORK/keys.log"
export HANDFREE_NO_KEYS=1 HANDFREE_APP_SECRET_FILE="$WORK/app-secret" HANDFREE_CLAUDE_JSON="$WORK/claude.json" HANDFREE_DICTATION_URL="http://127.0.0.1:$DEAD_PORT"
printf '{"mcpServers": {"handfree": {"type": "stdio", "command": "mcp-relay.sh"}}}\n' > "$HANDFREE_CLAUDE_JSON"
printf 'test-secret\n' > "$HANDFREE_APP_SECRET_FILE"
mkdir -p "$WORK/support" "$WORK/agents"
chmod +x "$ROOT/tests/fake-say.sh"
FAILS=0

configure() { printf '{"say_path": "%s", "language": "en", "announce_session": "always", "pause_between_lines_seconds": 0.1, "silence_around_title_ms": 1%s}\n' "$ROOT/tests/fake-say.sh" "${1:-}" > "$HANDFREE_CONFIG"; }
# The Now Playing answer is unknown by default: the tests then go through the audio-signal fallback.
hf() { HANDFREE_IDLE_SECONDS=${HANDFREE_IDLE_SECONDS:-0} HANDFREE_AUDIO_PLAYING=${HANDFREE_AUDIO_PLAYING:-0} HANDFREE_NOW_PLAYING=${HANDFREE_NOW_PLAYING:-unknown} osascript -l JavaScript "$SCRIPT" "$@"; }
transcript() { printf '{"type":"custom-title","customTitle":"%s"}\n' "$2" > "$WORK/$1.jsonl"; }
reply() { printf '{"session_id":"%s","transcript_path":"%s/%s.jsonl","last_assistant_message":"%s"}' "$1" "$WORK" "$1" "$2" | hf >/dev/null; }
# The Stop hook's output (a send-back), a question (session, question), its answer (session, answer).
turn_end() { printf '{"session_id":"%s","transcript_path":"%s/%s.jsonl","last_assistant_message":"%s"%s}' "$1" "$WORK" "$1" "$2" "${3:+,\"stop_hook_active\":true}" | hf; }
ask() { printf '{"session_id":"%s","transcript_path":"%s/%s.jsonl","tool_input":{"questions":["%s"]}}' "$1" "$WORK" "$1" "$2" | hf --question; }
answer() { printf '{"session_id":"%s","tool_response":[{"type":"text","text":"Q: x\\nA: %s. Stop"}]}' "$1" "$2" | hf --answered >/dev/null; }
said() { cat "$HANDFREE_SAY_LOG" 2>/dev/null; }
reset() { : > "$HANDFREE_SAY_LOG"; }
# At least $1 seconds, then until no reader is left (at most 15 s more): a reading still going on would bleed into the next check.
wait_quiet() {
  sleep "${1:-2}"
  n=0
  while [ "$n" -lt 75 ] && reading; do sleep 0.2; n=$((n + 1)); done
}
reading() {
  pid=$(grep -o '"reader_pid":[0-9]*' "$HANDFREE_STATE_DIR/state.json" 2>/dev/null | cut -d: -f2)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}
# A job waited for at most $2 seconds: a hook that hangs fails its check instead of the whole run.
wait_job() {
  n=0
  while [ "$n" -lt "$(($2 * 5))" ] && kill -0 "$1" 2>/dev/null; do sleep 0.2; n=$((n + 1)); done
  kill "$1" 2>/dev/null; wait "$1" 2>/dev/null
}
check() {
  if printf '%s' "$2" | grep -q -- "$3"; then echo "ok   $1"; else echo "FAIL $1"; echo "     expected: $3"; echo "     got: $(printf '%s' "$2" | tr '\n' '|')"; FAILS=$((FAILS + 1)); fi
}
check_not() {
  if printf '%s' "$2" | grep -q -- "$3"; then echo "FAIL $1"; echo "     unexpected: $3"; FAILS=$((FAILS + 1)); else echo "ok   $1"; fi
}

configure
# The pure logic first, fast (tests/unit.js), then the hooks and commands end to end.
unit=$(osascript -l JavaScript "$ROOT/tests/unit.js" 2>&1)
printf '%s\n' "$unit"
printf '%s' "$unit" | grep -q '^ok' || { echo "FAIL unit: tests/unit.js did not run"; FAILS=$((FAILS + 1)); }
FAILS=$((FAILS + $(printf '%s\n' "$unit" | grep -c '^FAIL')))
transcript a 'Project Alpha'
transcript b 'Project Beta'

reset; reply a 'A one.\nA two.\n\nA more.'; reply b 'B one.'; wait_quiet 3
check "replies are queued, each announced" "$(said)" "Session Project Alpha.*A one"
check "the second session is announced" "$(said)" "Session Project Beta.*B one"
check "the queue is first in, first out across sessions" "$(said | tr '\n' ' ')" "A one.*B one"
check "say is given -- before the text" "$(head -1 "$WORK/say-args.log")" "^-- "
check_not "only the first paragraph is read" "$(said)" "A more"
check "the pause after the first paragraph is announced" "$(said)" "Details available."
reset; reply a '-o spoken.aiff'; wait_quiet 1.5
check "a line starting with - is read as text, never as an option" "$(tail -1 "$WORK/say-args.log")" "^-- .*-o spoken.aiff.$"

reset; reply a 'Alone.\n\nHidden rest.'; wait_quiet 1.5
check_not "the rest waits" "$(said)" "Hidden rest"
hf --continue >/dev/null; wait_quiet 1.5
check "Continue reads the rest of the last reply" "$(said)" "Hidden rest"

reset; reply a 'See https://x.y/z.\n```js\nx()\n```\nEnd.'; wait_quiet 1.5; hf --continue >/dev/null; wait_quiet 2
check "a web address is read as link" "$(said)" "See link."
check "a code block is announced as skipped" "$(said)" "Code block skipped."

reset; reply a 'L1.\nL2.\nL3.\nL4.'; sleep 0.5; hf --quiet >/dev/null; n=$(said | wc -l); sleep 1
check "Quiet stops the reading" "$(said | wc -l)" "$n"
reset; hf --continue >/dev/null; wait_quiet 2.5
check "Continue announces again and goes on" "$(said)" "Session Project Alpha.*L"
reset; hf --restart >/dev/null; wait_quiet 2.5
check "Restart starts over" "$(said)" "L1."

reset; hf --dictating >/dev/null; reply a 'During the dictation.'; sleep 1
check_not "nothing is read while dictating" "$(said)" "During"
hf --done >/dev/null; wait_quiet 1.5
check "Stop lets the queue go on" "$(said)" "During the dictation"

reset; reply a 'A long line being read.\nSame paragraph.\n\nNext line.'; sleep 0.3
printf '{"session_id":"b","transcript_path":"%s/b.jsonl","tool_input":{"questions":["Shall we?"]}}' "$WORK" | hf --question >/dev/null
check "a question lets the reading under way reach its pause first" "$(said | tr '\n' ' ')" "A long line being read.*Same paragraph.*Details available.*A question.*Shall we"
printf '{"session_id":"b","transcript_path":"%s/b.jsonl"}' "$WORK" | hf --notify; sleep 1
check_not "the waiting notice is dropped while the answer is dictated" "$(said)" "Claude needs your answer"
check_not "and holds the rest until the answer" "$(said)" "Next line"
hf --done >/dev/null; hf --continue >/dev/null; wait_quiet 1.5
check "after the answer, Continue reads the rest" "$(said)" "Next line"
reset; printf '{"session_id":"b","transcript_path":"%s/b.jsonl","tool_input":{"questions":["Shall we?"]}}' "$WORK" | hf --question >/dev/null
check "a question is announced with its session" "$(said)" "Session Project Beta.*A question.*Shall we"
reply a 'After the question.'; sleep 1
check_not "the queue waits for the answer" "$(said)" "After the question"
answer b Yes; wait_quiet 1.5

reset; printf '{"session_id":"a","transcript_path":"%s/a.jsonl","tool_input":{"questions":["First?"]}}' "$WORK" | hf --question >/dev/null
printf '{"session_id":"a","tool_name":"mcp__handfree__ask_user_dictation"}' | hf --answered >/dev/null
reply a 'Answer to the first.'; wait_quiet 1.5
check "an answer sent from the dictation window, without Stop, frees the queue" "$(said)" "Answer to the first"
reset; printf '{"session_id":"b","transcript_path":"%s/b.jsonl","tool_input":{"questions":["Second?"]}}' "$WORK" | hf --question >/dev/null
printf '{"session_id":"b"}' | hf --answered >/dev/null
reply b 'Answer to the second.'; wait_quiet 1.5
check_not "the next session's reply is read alone" "$(said)" "Answer to the first"
check "and read at once" "$(said)" "Answer to the second"

reset; printf '{"session_id":"b","transcript_path":"%s/b.jsonl","tool_input":{"questions":["Refused?"]}}' "$WORK" | hf --question >/dev/null
reply a 'Another session meanwhile.'; sleep 1
check_not "another session's turn end does not cut a question short" "$(said)" "Another session meanwhile"
reply b 'Question refused, turn over.'; wait_quiet 2.5
check "the asking session's turn end frees the reading, though no answer came" "$(said)" "Question refused, turn over"

# Text written just before a question: read before it, its rest on "Continue", not read again at the turn's end.
transcript q 'Quiz'
printf '{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Intro para.\\n\\nMore para."}]}}\n' >> "$WORK/q.jsonl"
reset; printf '{"session_id":"q","transcript_path":"%s/q.jsonl","tool_input":{"questions":["Which one?"]}}' "$WORK" | hf --question >/dev/null
check "the text before a question is read first" "$(said | tr '\n' ' ')" "Intro para.*Details available.*A question.*Which one"
check_not "only its first paragraph" "$(said)" "More para"
out=$(printf '{"session_id":"q","tool_response":[{"type":"text","text":"Q: Which one?\\nA: La suite. Stop"}]}' | hf --answered)
check "answering \"the rest\" reads the rest of the text" "$(said)" "More para"
check "and has Claude ask again" "$out" '"decision":"block"'
reply b 'Meanwhile from Beta.'; sleep 1.5
check_not "another session waits while the question is asked again" "$(said)" "Meanwhile from Beta"
printf '{"session_id":"q","transcript_path":"%s/q.jsonl","tool_input":{"questions":["Which one?"]}}' "$WORK" | hf --question >/dev/null
out=$(printf '{"session_id":"q","tool_response":{"content":[{"type":"text","text":"Q: Which one?\\nA: The second one. Stop"}]}}' | hf --answered)
check_not "a real answer goes through" "$out" "block"
wait_quiet 2.5
check "and the other session is read once it is answered" "$(said)" "Meanwhile from Beta"
reset; reply q 'Intro para.\n\nMore para.'; wait_quiet 1.5
check_not "the same text is not read again at the turn's end" "$(said)" "Intro para"
reply q 'Final words.'; wait_quiet 1.5
check "a new reply is read" "$(said)" "Final words"

# The context put in the question itself (text written before the call kept only as a thinking summary).
transcript k 'Options'
printf '{"type":"assistant","message":{"id":"m2","content":[{"type":"thinking","thinking":"A summary."}]}}\n' >> "$WORK/k.jsonl"
reset; printf '{"session_id":"k","transcript_path":"%s/k.jsonl","tool_input":{"questions":["Option A first.\\n\\nOption B second.\\n\\nWhich one?"]}}' "$WORK" | hf --question >/dev/null
check "a question's own context is read in full, then the question" "$(said | tr '\n' ' ')" "Option A first.*Option B second.*A question.*Which one"
check_not "with no rest announced: it was all read" "$(said)" "Details available"
check_not "nor the thinking summary" "$(said)" "A summary"
printf '{"session_id":"k","tool_response":[{"type":"text","text":"Q: Which one?\\nA: Option A. Stop"}]}' | hf --answered >/dev/null
reset; printf '{"session_id":"k","transcript_path":"%s/k.jsonl","tool_input":{"questions":["Short one?"]}}' "$WORK" | hf --question >/dev/null
check "a one-paragraph question is read as it is" "$(said | tr '\n' ' ')" "A question.*Short one"
# The microphone opens once the end of the question has left the speakers, not as `say` returns.
tail=$(python3 -c 'import os,sys,time; print(int((time.time() - os.path.getmtime(sys.argv[1])) * 1000))' "$HANDFREE_SAY_LOG")
check "the hook returns a moment after the question is said" "$([ "$tail" -ge 450 ] && echo late || echo "early: $tail ms")" "late"
check_not "with no rest announced" "$(said)" "Details available"
printf '{"session_id":"k"}' | hf --answered >/dev/null

# "Claude Cancel" (Escape in the dictation window): the dictation ends, nothing is sent, readings go on.
reset; hf --dictating >/dev/null; reply b 'After the cancel.'; sleep 1
hf --cancel >/dev/null; wait_quiet 1.5
check "a cancelled dictation lets the readings go on" "$(said)" "After the cancel"

# A dictation sent with Return (no "Stop"): the message reaching a session ends it, and readings go on.
reset; hf --dictating >/dev/null; reply b 'Waiting for the message.'; sleep 1
check_not "nothing is read while the dictation lasts" "$(said)" "Waiting for the message"
printf '{"session_id":"b","prompt":"Sent with Return."}' | hf --prompt-sent >/dev/null; wait_quiet 1.5
check "a message sent ends the dictation, the reply is read" "$(said)" "Waiting for the message"

# A dictation under way ("Listen") is not freed by another session's question failing or being answered.
reset; hf --dictating >/dev/null
printf '{"session_id":"x","tool_response":[{"type":"text","text":"Already recording"}]}' | hf --answered >/dev/null
reply b 'Working session done.'; sleep 1.5
check_not "another session's answer does not free a dictation under way" "$(said)" "Working session done"
hf --done >/dev/null; wait_quiet 1.5
check "Stop does, and the reply is read" "$(said)" "Working session done"

# Two sessions asking at once: the second question waits for the first one's answer, never read over it.
transcript x 'Xray'; transcript y 'Yankee'
reset; printf '{"session_id":"x","transcript_path":"%s/x.jsonl","tool_input":{"questions":["Question from X?"]}}' "$WORK" | hf --question >/dev/null
(printf '{"session_id":"y","transcript_path":"%s/y.jsonl","tool_input":{"questions":["Question from Y?"]}}' "$WORK" | hf --question >/dev/null) & ASKING=$!
sleep 2
check_not "a second session's question waits while the first is answered" "$(said)" "Question from Y"
printf '{"session_id":"x","tool_response":[{"type":"text","text":"Q: Question from X?\\nA: Fine. Stop"}]}' | hf --answered >/dev/null
wait_job "$ASKING" 60
check "then it is asked" "$(said | tr '\n' ' ')" "Question from X.*Question from Y"
printf '{"session_id":"y"}' | hf --answered >/dev/null

# A cloud session has no title in its transcript: "cloud" and its folder's name.
printf '{"type":"user","message":{"content":"Corrige le bug."}}\n' > "$WORK/c.jsonl"
reset; printf '{"session_id":"c","cwd":"/work/project","transcript_path":"%s/c.jsonl","last_assistant_message":"Done in the cloud."}' "$WORK" | HANDFREE_CONTEXT=cloud hf >/dev/null; wait_quiet 1.5
check "a cloud session is named cloud and its project" "$(said)" "Session cloud project"
reset; printf '{"session_id":"c2","cwd":"/work/project","transcript_path":"%s/c.jsonl","last_assistant_message":"Done locally."}' "$WORK" | hf >/dev/null; wait_quiet 1.5
check_not "a local one without a title is its folder's name only" "$(said)" "cloud"

# The same text written in the message and copied into the question is read once.
transcript d 'Dup'
printf '{"type":"assistant","message":{"id":"m3","content":[{"type":"text","text":"Same intro."}]}}\n' >> "$WORK/d.jsonl"
reset; printf '{"session_id":"d","transcript_path":"%s/d.jsonl","tool_input":{"questions":["Same intro.\\n\\nWhich?"]}}' "$WORK" | hf --question >/dev/null
check "a copied paragraph is read" "$(said)" "Same intro"
check "only once" "$(said | grep -c 'Same intro')" "^1$"
printf '{"session_id":"d"}' | hf --answered >/dev/null

# A long rest: "the rest" asks Claude for a summary, "the details" then reads the full text.
transcript s 'Long'
printf '{"type":"assistant","message":{"id":"m4","content":[{"type":"text","text":"First part.\\n\\nPart two.\\n\\nPart three.\\n\\nPart four."}]}}\n' >> "$WORK/s.jsonl"
reset; printf '{"session_id":"s","transcript_path":"%s/s.jsonl","tool_input":{"questions":["Which?"]}}' "$WORK" | hf --question >/dev/null
out=$(printf '{"session_id":"s","tool_response":[{"type":"text","text":"Q: Which?\\nA: Lis la suite. Stop"}]}' | hf --answered)
check_not "a long rest is not read on \"the rest\"" "$(said)" "Part two"
check "Claude is asked for a summary" "$out" "summing up"
reset; printf '{"session_id":"s","transcript_path":"%s/s.jsonl","tool_input":{"questions":["In short, parts two to four.\\n\\nWhich?"]}}' "$WORK" | hf --question >/dev/null
check "the summary is read, then how to hear it all, then the question" "$(said | tr '\n' ' ')" "In short.*the details.*A question.*Which"
out=$(printf '{"session_id":"s","tool_response":[{"type":"text","text":"Q: Which?\\nA: Montre le de\\u0301tail. Stop"}]}' | hf --answered)
check "\"the details\" (accents decomposed) reads the full text" "$(said | tr '\n' ' ')" "Part two.*Part three.*Part four"
check "and has Claude ask again" "$out" "Ask the same question again"
reset; printf '{"session_id":"s","transcript_path":"%s/s.jsonl","tool_input":{"questions":["Which?"]}}' "$WORK" | hf --question >/dev/null
check_not "the details are offered no more" "$(said)" "the details"
out=$(printf '{"session_id":"s","tool_response":[{"type":"text","text":"Q: Which?\\nA: The second. Stop"}]}' | hf --answered)
check_not "the real answer goes through" "$out" "block"

reset; printf '{"type":"user","turnOrigin":"sdk","message":{"content":"Background (from the session that started this one): x"}}\n' >> "$WORK/b.jsonl"
reply b 'Delegated task.'; sleep 1
check_not "a turn delegated by another session is not read" "$(said)" "Delegated task"
printf '{"type":"user","turnOrigin":"human","message":{"content":"Ask me a question"}}\n' >> "$WORK/b.jsonl"
reply b 'Direct answer.'; wait_quiet 1.5
check "a turn asked by the user is read" "$(said)" "Direct answer."
printf '{"type":"assistant","message":{"id":"m-direct","content":[{"type":"text","text":"Direct answer."}]}}\n' >> "$WORK/b.jsonl"
reset; printf '{"type":"user","message":{"content":"Ask me again"}}\n' >> "$WORK/b.jsonl"
printf '{"session_id":"b","transcript_path":"%s/b.jsonl","tool_input":{"questions":["Which?"]}}' "$WORK" | hf --question >/dev/null
check "a question asked at once is read" "$(said)" "Which"
check_not "without the reply of the turn before, read already" "$(said)" "Direct answer"
printf '{"session_id":"b","tool_response":[{"type":"text","text":"Q: Which?\\nA: None. Stop"}]}' | hf --answered >/dev/null

reset; printf '{"session_id":"a","transcript_path":"%s/a.jsonl"}' "$WORK" | hf --notify; wait_quiet 1.5
check "the waiting notice names its session" "$(said)" "Session Project Alpha.*Claude needs your answer"

reset; hf --off >/dev/null; reply a 'Muted.'; rules=$(hf --session-rules </dev/null); sleep 1
check "switching off is said" "$(said)" "Voice mode off."
check_not "nothing is read while off" "$(said)" "Muted"
check "no rules are injected while off" "[$rules]" "\[\]"
hf --toggle >/dev/null
check "switching back on is said" "$(said)" "Voice mode on."

# Voice mode switched during a session: the session hears of it with its next message, once.
sent() { printf '{"session_id":"%s","prompt":"Go."}' "$1" | hf --prompt-sent; }
hf --off >/dev/null; printf '{"session_id":"v"}' | hf --session-rules >/dev/null; hf --on >/dev/null
check "a session started with voice mode off gets the rules with its next message" "$(sent v)" "UserPromptSubmit.*Voice mode is on"
check "and not again with the one after" "[$(sent v)]" "^\[\]$"
hf --off >/dev/null
check "switched off, the session is told the rules no longer apply" "$(sent v)" "Voice mode is off"
check "and only once" "[$(sent v)]" "^\[\]$"
hf --on >/dev/null
check "a session given the rules at its start is not given them again" "[$(printf '{"session_id":"w"}' | hf --session-rules >/dev/null; sent w)]" "^\[\]$"
reset

echo "<plist/>" > "$WORK/agents/com.handfree-code.bridge.plist"; rm -f "$WORK/support/bridge-server.py" "$WORK/restarted.log"
hf --session-rules </dev/null >/dev/null
check "a new bridge-server.py in the stable copy restarts the bridge" "$(cat "$WORK/restarted.log" 2>/dev/null)" "com.handfree-code.bridge"
check_not "and not the listener, not installed" "$(cat "$WORK/restarted.log" 2>/dev/null)" "listener"
rm -f "$WORK/restarted.log"; hf --session-rules </dev/null >/dev/null
check "an unchanged one does not" "[$(cat "$WORK/restarted.log" 2>/dev/null)]" "^\[\]$"
hf --off >/dev/null; rm -f "$WORK/support/bridge-server.py"; hf --session-rules </dev/null >/dev/null; hf --on >/dev/null; reset
check "voice mode off, a new session still refreshes the stable copy" "$(ls "$WORK/support")" "bridge-server.py"
# A session still on an older plugin version must not put its scripts back over a newer copy.
VERSION=$(/usr/bin/python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/.claude-plugin/plugin.json")
check "the stable copy records the version it came from" "$(cat "$WORK/support/version" 2>/dev/null)" "^$VERSION$"
printf '99.0.0\n' > "$WORK/support/version"; rm -f "$WORK/support/bridge-server.py" "$WORK/restarted.log"; hf --session-rules </dev/null >/dev/null
check_not "an older plugin version leaves a newer stable copy alone" "$(ls "$WORK/support")" "bridge-server.py"
check "and restarts nothing" "[$(cat "$WORK/restarted.log" 2>/dev/null)]" "^\[\]$"
printf '0.0.1\n' > "$WORK/support/version"; hf --session-rules </dev/null >/dev/null
check "a newer plugin version refreshes it" "$(ls "$WORK/support")" "bridge-server.py"
check "the stable copy carries set-question-transport.sh, as the install does" "$(ls "$WORK/support"; grep -c set-question-transport.sh "$ROOT/bin/install.sh")" "set-question-transport.sh"

printf '{"say_path": "%s", "language": "en", "validation_word": "banana"}\n' "$ROOT/tests/fake-say.sh" > "$HANDFREE_CONFIG"
check "rules follow the language and validation word" "$(hf --session-rules </dev/null)" 'saying "banana"'
check "no rules when Claude's settings do not declare the dictation tool" "[$(HANDFREE_CLAUDE_JSON="$WORK/none.json" hf --session-rules </dev/null)]" "\[\]"
printf '{"say_path": "%s", "language": "de"}\n' "$ROOT/tests/fake-say.sh" > "$HANDFREE_CONFIG"
check "the validation word is the language's Stop phrase (stopp in German)" "$(hf --session-rules </dev/null)" '"stopp"'
set_transport() { printf '{"say_path": "%s", "language": "en", "question_transport": {"local": "%s", "cloud": "%s"}}\n' "$ROOT/tests/fake-say.sh" "$1" "$2" > "$HANDFREE_CONFIG"; }
set_transport none bridge
check "transport none: no voice rules" "[$(hf --session-rules </dev/null)]" "\[\]"
set_transport bridge bridge
check "local bridge with the dictation up: rules" "$(HANDFREE_DICTATION_UP=1 hf --session-rules </dev/null)" "Voice mode is on"
check "local bridge with the dictation down: no rules" "[$(HANDFREE_DICTATION_UP=0 hf --session-rules </dev/null)]" "\[\]"
set_transport mcp none
check "cloud transport none: no rules for a cloud session" "[$(HANDFREE_CONTEXT=cloud hf --session-rules </dev/null)]" "\[\]"
set_transport mcp bridge
check "cloud bridge with the dictation up: rules for a cloud session" "$(HANDFREE_CONTEXT=cloud HANDFREE_DICTATION_UP=1 hf --session-rules </dev/null)" "Voice mode is on"
configure

reset; out=$(printf '{"session_id":"a","transcript_path":"%s/a.jsonl","last_assistant_message":"Done.\\n\\nShall I push it?"}' "$WORK" | hf); sleep 1
check "a reply ending on a written question is sent back" "$out" '"decision":"block"'
check_not "and is not read meanwhile" "$(said)" "push"
printf '{"session_id":"a","transcript_path":"%s/a.jsonl","tool_input":{"questions":["Shall I push it?"]}}' "$WORK" | hf --question >/dev/null
check "the reply sent back is read before its question, which is not read twice" "$(said | tr '\n' ' ')" "Done. *A question.*Shall I push it"
check "its written question is not read as text" "$(said | grep -c 'push')" "^1$"
printf '{"session_id":"a"}' | hf --answered >/dev/null
reset; out=$(printf '{"session_id":"a","transcript_path":"%s/a.jsonl","last_assistant_message":"Intro.\\n\\nTwo.\\n\\nThree.\\n\\nFour.\\n\\nWhich one?"}' "$WORK" | hf)
check "a long reply sent back asks for its summary with the question" "$out" "summing up the rest"
printf '{"session_id":"a","transcript_path":"%s/a.jsonl","tool_input":{"questions":["In short, two to four.\\n\\nWhich one?"]}}' "$WORK" | hf --question >/dev/null
check "its first paragraph, its summary, how to hear it all, the question" "$(said | tr '\n' ' ')" "Intro.*In short.*the details.*A question.*Which one"
check_not "with no rest announced" "$(said)" "Details available"
check_not "nor the rest read" "$(said)" "Two"
out=$(printf '{"session_id":"a","tool_response":[{"type":"text","text":"Q: Which one?\\nA: La suite. Stop"}]}' | hf --answered)
check "\"the rest\" then reads the reply in full" "$(said | tr '\n' ' ')" "Two.*Three.*Four"
check "and has Claude ask again" "$out" "Ask the same question again"
printf '{"session_id":"a","tool_response":[{"type":"text","text":"Q: Which one?\\nA: The first. Stop"}]}' | hf --answered >/dev/null
reset; printf '{"session_id":"a","transcript_path":"%s/a.jsonl","last_assistant_message":"Intro.\\n\\nTwo.\\n\\nThree.\\n\\nFour.\\n\\nWhich one?"}' "$WORK" | hf >/dev/null
printf '{"session_id":"a","transcript_path":"%s/a.jsonl","tool_input":{"questions":["Which one?"]}}' "$WORK" | hf --question >/dev/null
check "no summary given: its first paragraph stands for it, the details offered" "$(said | tr '\n' ' ')" "Intro.*the details.*A question.*Which one"
out=$(printf '{"session_id":"a","tool_response":[{"type":"text","text":"Q: Which one?\\nA: La suite. Stop"}]}' | hf --answered)
check "and \"the rest\" reads the reply in full" "$(said | tr '\n' ' ')" "Two.*Three.*Four"
check_not "with no summary asked for" "$out" "summing up"
printf '{"session_id":"a","tool_response":[{"type":"text","text":"Q: Which one?\\nA: The first. Stop"}]}' | hf --answered >/dev/null
stop_hook=$(printf '{"session_id":"a","stop_hook_active":true,"transcript_path":"%s/a.jsonl","last_assistant_message":"Noted."}' "$WORK" | hf); wait_quiet 1.5
out=$(printf '{"session_id":"a","stop_hook_active":true,"transcript_path":"%s/a.jsonl","last_assistant_message":"Still: which one?"}' "$WORK" | hf)
check "a new question later in a turn sent back is sent back too" "$out" '"decision":"block"'
out=$(printf '{"session_id":"a","stop_hook_active":true,"transcript_path":"%s/a.jsonl","last_assistant_message":"Still: which one?"}' "$WORK" | hf)
check_not "the same question is not sent back twice in a row" "$out" "block"
wait_quiet 1.5
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__ccd_turn__wrap_up","input":{"recap":"x","ask":"Publish?"}}]}}\n' >> "$WORK/a.jsonl"
out=$(printf '{"session_id":"a","transcript_path":"%s/a.jsonl","last_assistant_message":"Done."}' "$WORK" | hf)
check "a question in the app box is sent back" "$out" '"decision":"block"'
printf '{"type":"user","turnOrigin":"human","message":{"content":"go on"}}\n' >> "$WORK/a.jsonl"
out=$(printf '{"session_id":"a","transcript_path":"%s/a.jsonl","last_assistant_message":"Why? Because.\\n\\nDone."}' "$WORK" | hf)
check_not "a question earlier in the reply is not sent back" "$out" "block"
wait_quiet 1.5

# A turn that goes on through several questions (a grill, a checklist): each is asked aloud, nobody talks over it.
transcript g 'Grill'
reset; out=$(printf '{"session_id":"g","transcript_path":"%s/g.jsonl","last_assistant_message":"Round one.\\n\\nFirst?"}' "$WORK" | hf)
check "round one's question is sent back" "$out" '"decision":"block"'
reply b 'Beta talks meanwhile.'; sleep 1.5
check_not "another session waits for the question sent back" "$(said)" "Beta talks meanwhile"
printf '{"session_id":"g","transcript_path":"%s/g.jsonl","tool_input":{"questions":["First?"]}}' "$WORK" | hf --question >/dev/null
hf --done >/dev/null; sleep 1.5
check_not "Stop said for the answer does not let it talk yet" "$(said)" "Beta talks meanwhile"
printf '{"session_id":"g","tool_response":[{"type":"text","text":"Q: First?\\nA: Yes. Stop"}]}' | hf --answered >/dev/null
out=$(printf '{"session_id":"g","stop_hook_active":true,"transcript_path":"%s/g.jsonl","last_assistant_message":"Round two.\\n\\nSecond?"}' "$WORK" | hf)
check "round two's question is sent back too, in the same turn" "$out" '"decision":"block"'
printf '{"session_id":"g","transcript_path":"%s/g.jsonl","tool_input":{"questions":["Second?"]}}' "$WORK" | hf --question >/dev/null
check "round two's text is read before its question" "$(said | tr '\n' ' ')" "Round two.*A question.*Second"
printf '{"session_id":"g","tool_response":[{"type":"text","text":"Q: Second?\\nA: No. Stop"}]}' | hf --answered >/dev/null; wait_quiet 2
check "the other session talks once the questions are answered" "$(said)" "Beta talks meanwhile"
for n in 1 2 3; do printf '{"session_id":"g","stop_hook_active":true,"transcript_path":"%s/g.jsonl","last_assistant_message":"Again %s?"}' "$WORK" "$n" | hf >/dev/null; done
out=$(printf '{"session_id":"g","stop_hook_active":true,"transcript_path":"%s/g.jsonl","last_assistant_message":"Again 4?"}' "$WORK" | hf)
check_not "after three sent back with none asked, Claude is let go" "$out" "block"
wait_quiet 1.5

out=$(printf '{"session_id":"b","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which?"}]}}' | hf --guard-question)
check "the app's multiple-choice question is turned back to the dictation tool" "$out" '"permissionDecision":"deny".*mcp__handfree__ask_user_dictation'
out=$(printf '{"session_id":"b","tool_name":"mcp__ccd_session__start_session","tool_input":{"initiation":"offer","title":"x"}}' | hf --guard-question)
check "the app's session offer is asked through the dictation tool" "$out" '"permissionDecision":"deny".*new session or here'
out=$(printf '{"session_id":"b","tool_name":"mcp__ccd_session__start_session","tool_input":{"initiation":"own_initiative","title":"x"}}' | hf --guard-question)
check_not "a proposal card waiting for nobody is let through" "$out" "deny"
out=$(printf '{"session_id":"b","tool_name":"mcp__ccd_turn__wrap_up","tool_input":{"recap":"Done.","ask":"Commit it?"}}' | hf --guard-question)
check "the app's end-of-turn question is asked through the dictation tool" "$out" '"permissionDecision":"deny".*recap alone.*mcp__handfree__ask_user_dictation'
out=$(printf '{"session_id":"b","tool_name":"mcp__ccd_turn__wrap_up","tool_input":{"recap":"Done."}}' | hf --guard-question)
check_not "an end-of-turn recap alone is let through" "$out" "deny"
out=$(printf '{"session_id":"b","tool_name":"AskUserQuestion","tool_input":{}}' | HANDFREE_IDLE_SECONDS=3600 sh -c "osascript -l JavaScript '$SCRIPT' --guard-question")
check_not "away from the Mac, the app's question is let through" "$out" "deny"
hf --off >/dev/null; out=$(printf '{"session_id":"b","tool_name":"AskUserQuestion","tool_input":{}}' | hf --guard-question); hf --on >/dev/null; reset
check_not "voice mode off, the app's question is let through" "$out" "deny"

reset; out=$(HANDFREE_IDLE_SECONDS=3600 sh -c "printf '{\"session_id\":\"b\",\"transcript_path\":\"%s/b.jsonl\",\"tool_input\":{\"questions\":[\"Away?\"]}}' '$WORK' | osascript -l JavaScript '$SCRIPT' --question")
check "away from the Mac, the dictation question is refused" "$out" '"permissionDecision":"deny"'
check_not "and nothing is said" "$(said)" "Away"
out=$(HANDFREE_IDLE_SECONDS=3600 sh -c "printf '{\"session_id\":\"a\",\"transcript_path\":\"%s/a.jsonl\",\"last_assistant_message\":\"Publish?\"}' '$WORK' | osascript -l JavaScript '$SCRIPT'")
check_not "away from the Mac, a written question is allowed" "$out" "block"
wait_quiet 1.5

# A question sent back and never asked (Escape, a message typed instead): a message sent to that session frees the queue.
transcript f 'Forgotten'
reset; out=$(turn_end f 'Done.\n\nShall I go on?')
check "a question sent back" "$out" '"decision":"block"'
reply b 'Waiting behind the question.'; sleep 1
printf '{"session_id":"b","prompt":"Elsewhere."}' | hf --prompt-sent >/dev/null; sleep 1
check_not "a message sent to another session does not free it" "$(said)" "Waiting behind the question"
printf '{"session_id":"f","prompt":"Something else."}' | hf --prompt-sent >/dev/null; wait_quiet 1.5
check "a message typed instead of answering frees the queue" "$(said)" "Waiting behind the question"
# A question asked since by a session on an older version (held_by left as it was) is not freed by a message.
reset; turn_end f 'Done.\n\nShall I go on again?' >/dev/null
/usr/bin/python3 -c 'import json, sys; p = sys.argv[1]; s = json.load(open(p)); s["dictating_since"] += 5; json.dump(s, open(p, "w"))' "$HANDFREE_STATE_DIR/state.json"
reply b 'Behind an older question.'; sleep 1
printf '{"session_id":"f","prompt":"Typed meanwhile."}' | hf --prompt-sent >/dev/null; sleep 1
check_not "a message does not free a question asked since the send-back" "$(said)" "Behind an older question"
answer f 'x'; wait_quiet 1.5

# Two sessions sent back at once: each reply is read before its own question.
transcript p 'Papa'; transcript r 'Romeo'
reset; turn_end p 'Text from Papa.\n\nPapa asks?' >/dev/null; turn_end r 'Text from Romeo.\n\nRomeo asks?' >/dev/null
ask p 'Papa asks?' >/dev/null
check "the first session's reply sent back is read before its question" "$(said | tr '\n' ' ')" "Text from Papa.*Papa asks"
answer p 'Yes'; reset; ask r 'Romeo asks?' >/dev/null
check "and the second one's before its own" "$(said | tr '\n' ' ')" "Text from Romeo.*Romeo asks"
answer r 'No'; wait_quiet 1.5

# The loop guard is each session's own: another session's turn end between two send-backs does not reset it.
reset; turn_end p 'Same question?' >/dev/null; turn_end r 'Another question?' >/dev/null
out=$(turn_end p 'Same question?' active)
check_not "the same question is not sent back twice, another session's in between" "$out" "block"
answer p 'x'; answer r 'x'; reply p 'Over.'; reply r 'Over.'; wait_quiet 2

# A second question in the same turn: the text read before the first one is not read again.
transcript t 'Tango'
printf '%s\n' '{"type":"assistant","message":{"id":"t1","content":[{"type":"text","text":"Context of the first."}]}}' \
  '{"type":"assistant","message":{"id":"t1","content":[{"type":"tool_use","name":"mcp__handfree__ask_user_dictation","input":{}}]}}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","content":"Q: First?\nA: Yes."}]}}' >> "$WORK/t.jsonl"
reset; ask t 'Second?' >/dev/null
check "a second question in the same turn is read" "$(said)" "Second?"
check_not "without the first one's text again" "$(said)" "Context of the first"
answer t 'Fine'; wait_quiet 1

# A session's own older reply, still waiting behind another session's reading, comes before its question.
reset; reply b 'Beta one.\nBeta two.\nBeta three.'; sleep 0.4; reply a 'Older from Alpha.'
ask a 'Fresh question?' >/dev/null
check "a session's older reply still queued is read before its question" "$(said | tr '\n' ' ')" "Older from Alpha.*A question.*Fresh question"
answer a 'Yes'; wait_quiet 1.5
check "and not read again after the answer" "$(said | grep -c 'Older from Alpha')" "^1$"
# What follows that older reply's pause is not lost with it: it waits its turn again, for "Continue".
reset; reply b 'Beta one.\nBeta two.\nBeta three.'; sleep 0.4; reply a 'Older first.\n\nOlder rest.'
ask a 'Another question?' >/dev/null; answer a 'Yes'; wait_quiet 1.5
check_not "the older reply's rest waits for Continue" "$(said)" "Older rest"
hf --continue >/dev/null; wait_quiet 1.5
check "and Continue reads it" "$(said)" "Older rest"

# Another dictation still under way at the deadline: the question goes in writing instead of being read over it.
reset; hf --dictating >/dev/null
out=$(HANDFREE_QUESTION_WAIT_SECONDS=1 ask a 'Over a dictation?')
check "a question that cannot wait any longer is refused, to be written" "$out" '"permissionDecision":"deny".*in writing'
check_not "and is not read" "$(said)" "Over a dictation"
hf --done >/dev/null; wait_quiet 1

# "Quiet" cuts the reply being read: a new one is read next from its start, "Continue" resumes the cut one.
reset; reply a 'Cut one.\nCut two.\nCut three.\nCut four.'; sleep 1.2; hf --quiet >/dev/null
reply b 'Fresh reply.'; wait_quiet 2
check "after Quiet, a new reply is read" "$(said)" "Fresh reply"
check_not "and the cut one does not come back by itself" "$(said)" "Cut four"
reset; hf --continue >/dev/null; wait_quiet 2.5
check "Continue resumes the cut reply" "$(said)" "Cut four"
check_not "from where it was cut" "$(said)" "Cut one"

# "Quiet" (or its shortcut) said while a question's text is read stops all of it, not one line.
transcript l 'Lima'
reset; (ask l 'L1.\n\nL2.\n\nL3.\n\nL4.\n\nL5.\n\nL6.\n\nWhich?' >/dev/null) & sleep 1.5; hf --quiet >/dev/null; wait_job $! 60
check_not "Quiet stops a question's lines" "$(said)" "L6"
check "the question itself is still asked" "$(said)" "Which?"
answer l 'x'; wait_quiet 1

# The question hook stops reading in time for its question and the microphone, however long it waited.
reset; out=$(HANDFREE_QUESTION_READING_SECONDS=1 ask l 'M1.\n\nM2.\n\nM3.\n\nM4.\n\nM5.\n\nM6.\n\nWhich one?')
check_not "past its reading time, the question's text stops" "$(said)" "M6"
check "and the question is asked" "$(said)" "Which one?"
answer l 'x'; wait_quiet 1

# A second "Quiet" keeps the first reply it cut: "Continue" reads the first, then the second.
reset; reply a 'First cut 1.\nFirst cut 2.\nFirst cut 3.\nFirst cut 4.'; sleep 1.2; hf --quiet >/dev/null
reply b 'Second cut 1.\nSecond cut 2.\nSecond cut 3.\nSecond cut 4.'; sleep 1.2; hf --quiet >/dev/null
reset; hf --continue >/dev/null; wait_quiet 4
check "after two Quiet, Continue reads the first cut reply, then the second" "$(said | tr '\n' ' ')" "First cut 4.*Second cut 4"

# Voice permissions: a fake dictation app answers with the text in $WORK/answer.txt.
/usr/bin/python3 -c '
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        msg = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if msg.get("method") == "tools/call":
            import os
            log = os.path.join(os.path.dirname(sys.argv[2]), "said.log")
            spoken = open(log).read() if os.path.exists(log) else ""
            open(os.path.join(os.path.dirname(sys.argv[2]), "order.log"), "w").write("said-then-asked" if "Permission requested" in spoken else "asked-too-early")
            out = {"jsonrpc": "2.0", "id": msg["id"], "result": {"content": [{"type": "text", "text": "Q: x\nA: " + open(sys.argv[2]).read()}]}}
        else:
            out = {"jsonrpc": "2.0", "id": msg.get("id"), "result": {"tools": []}}
        body = json.dumps(out).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
' "$DICTATION_PORT" "$WORK/answer.txt" &
DICTATION_PID=$!
sleep 0.5
permission() {  # $1: the spoken answer
  printf '%s' "$1" > "$WORK/answer.txt"; export HANDFREE_FAKE_SAY_SECONDS=2
  printf '{"session_id":"a","transcript_path":"%s/a.jsonl","tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' "$WORK" | HANDFREE_DICTATION_URL=http://127.0.0.1:$DICTATION_PORT hf --permission
}
configure ', "voice_permissions": true'
reset; out=$(permission 'oui stop')
check "a spoken yes allows" "$out" '"behavior":"allow"'
check "the request is read with its session" "$(said)" "Session Project Alpha.*Permission requested: git commit"
check "the request is read in full before listening" "$(cat "$WORK/order.log" 2>/dev/null)" "said-then-asked"
check "deny on a spoken no" "$(permission 'non')" '"behavior":"deny"'
check "an unclear answer leaves the dialog" "[$(permission 'well I do not know')]" "\[\]"
check "a mixed answer leaves the dialog" "[$(permission 'yes no')]" "\[\]"
# A validation phrase that is also a yes ("go ahead") must not turn a spoken no into a mixed answer.
configure ', "voice_permissions": true, "validation_word": "go ahead"'
check "a validation phrase of several words is taken out of the answer" "$(permission 'no go ahead')" '"behavior":"deny"'
check "but never from inside a word" "[$(permission 'no go aheads')]" "\[\]"
configure ', "voice_permissions": true'
check "away from the Mac, the dialog shows as usual" "[$(HANDFREE_IDLE_SECONDS=3600 permission 'yes')]" "\[\]"
# Like a question, a request waits for another dictation: still under way at the deadline, the dialog shows.
reset; hf --dictating >/dev/null
check "another dictation under way: the dialog shows" "[$(HANDFREE_QUESTION_WAIT_SECONDS=1 permission 'yes')]" "\[\]"
check_not "and the request is not read over it" "$(said)" "Permission requested"
hf --done >/dev/null
# Its answer frees only its own hold.
reset; permission 'yes' >/dev/null; reply b 'After the permission.'; wait_quiet 3.5
check "the answered request lets the readings go on" "$(said)" "After the permission"
configure
check "off by default" "[$(permission 'yes')]" "\[\]"
kill "$DICTATION_PID" 2>/dev/null; wait "$DICTATION_PID" 2>/dev/null
unset HANDFREE_FAKE_SAY_SECONDS

# Default: the name is said only when the speaking session changes.
printf '{"say_path": "%s", "language": "en", "pause_between_lines_seconds": 0.1, "silence_around_title_ms": 1}\n' "$ROOT/tests/fake-say.sh" > "$HANDFREE_CONFIG"
rm -f "$HANDFREE_STATE_DIR/state.json"  # no one has spoken yet
reset; reply a 'First.'; reply a 'Second.'; reply b 'Third.'; reply b 'Fourth.'; wait_quiet 4
check "a session's name is said once while it keeps talking" "$(said | grep -c 'Session Project Alpha')" "^1$"
check "and again when another session speaks" "$(said | grep -c 'Session Project Beta')" "^1$"
reset; printf '{"session_id":"b","transcript_path":"%s/b.jsonl","tool_input":{"questions":["Same speaker?"]}}' "$WORK" | hf --question >/dev/null
check_not "a question from the same session skips the name" "$(said)" "Session"
answer b Yes
reset; printf '{"session_id":"a","transcript_path":"%s/a.jsonl","tool_input":{"questions":["Other speaker?"]}}' "$WORK" | hf --question >/dev/null
check "a question from another session says its name" "$(said)" "Session Project Alpha.*Other speaker"
answer a Yes; wait_quiet 1
configure

# Pausing what plays: the media commands are recorded instead of sent.
rm -f "$HANDFREE_STATE_DIR/state.json" "$HANDFREE_MEDIA_KEY_LOG"
(HANDFREE_AUDIO_PLAYING=1 reply a 'Over the music.'); wait_quiet 2
check "music playing: paused before speaking, resumed after" "$(cat "$HANDFREE_MEDIA_KEY_LOG" 2>/dev/null | tr '\n' ' ')" "^pause play $"
rm -f "$HANDFREE_STATE_DIR/state.json" "$HANDFREE_MEDIA_KEY_LOG"
(HANDFREE_AUDIO_PLAYING=1 hf --dictating >/dev/null); (HANDFREE_AUDIO_PLAYING=0 hf --done >/dev/null); wait_quiet 1.5
check "a dictation pauses the music, Stop resumes it" "$(cat "$HANDFREE_MEDIA_KEY_LOG" 2>/dev/null | tr '\n' ' ')" "^pause play $"
# A dictation sent with Return, not "Stop": it runs out, and the music the user resumed meanwhile is paused again.
configure ', "max_dictation_seconds": 1'; rm -f "$HANDFREE_MEDIA_KEY_LOG"
(HANDFREE_NOW_PLAYING=1 hf --dictating >/dev/null); sleep 1.5
(HANDFREE_NOW_PLAYING=1 reply b 'Music resumed by hand meanwhile.'); sleep 1
check "music resumed by hand after a dictation is paused again for a reading" "$(cat "$HANDFREE_MEDIA_KEY_LOG" 2>/dev/null | tr '\n' ' ')" "^pause pause"
wait_quiet 2; configure
rm -f "$HANDFREE_STATE_DIR/state.json" "$HANDFREE_MEDIA_KEY_LOG"
(HANDFREE_AUDIO_PLAYING=0 reply a 'In silence.'); wait_quiet 2
check "nothing playing: nothing is sent" "[$(cat "$HANDFREE_MEDIA_KEY_LOG" 2>/dev/null)]" "\[\]"
# macOS 15.4 and later: media-control, when installed, reads and drives what plays (here a fake one).
printf '#!/bin/sh\necho "$1" >> "%s/media-control.log"\n[ "$1" = get ] && cat "%s/now-playing.json"\nexit 0\n' "$WORK" "$WORK" > "$WORK/media-control"
chmod +x "$WORK/media-control"
with_media_control() { printf '{"session_id":"a","transcript_path":"%s/a.jsonl","last_assistant_message":"%s"}' "$WORK" "$1" \
  | env -u HANDFREE_NOW_PLAYING HANDFREE_MEDIA_KEY_LOG= HANDFREE_MEDIA_CONTROL="$WORK/media-control" HANDFREE_IDLE_SECONDS=0 HANDFREE_AUDIO_PLAYING=0 \
    osascript -l JavaScript "$SCRIPT" >/dev/null; }
rm -f "$HANDFREE_STATE_DIR/state.json" "$WORK/media-control.log"
echo '{"playing": true, "title": "A video"}' > "$WORK/now-playing.json"
with_media_control 'Over the video.'; wait_quiet 2
check "media-control: what plays is paused, then resumed" "$(grep -v get "$WORK/media-control.log" 2>/dev/null | tr '\n' ' ')" "^pause play $"
rm -f "$HANDFREE_STATE_DIR/state.json" "$WORK/media-control.log"
echo null > "$WORK/now-playing.json"
with_media_control 'Nothing playing.'; wait_quiet 2
check "media-control: nothing playing, nothing sent" "[$(grep -v get "$WORK/media-control.log" 2>/dev/null)]" "\[\]"
reply a 'Right after.'; wait_quiet 2
(HANDFREE_AUDIO_PLAYING=1 reply a 'Own voice still reported.'); wait_quiet 2
check "our own voice is not taken for music" "[$(cat "$HANDFREE_MEDIA_KEY_LOG" 2>/dev/null)]" "\[\]"
rm -f "$HANDFREE_STATE_DIR/state.json" "$HANDFREE_MEDIA_KEY_LOG"
printf '{"session_id":"b","transcript_path":"%s/b.jsonl","tool_input":{"questions":["Over the music?"]}}' "$WORK" | HANDFREE_AUDIO_PLAYING=1 hf --question >/dev/null
check "a question pauses the music too" "$(cat "$HANDFREE_MEDIA_KEY_LOG" 2>/dev/null | tr '\n' ' ')" "^pause $"
hf --done >/dev/null; printf '{"session_id":"b"}' | hf --answered >/dev/null; wait_quiet 1.5
check "and the answer given, the music resumes" "$(cat "$HANDFREE_MEDIA_KEY_LOG" 2>/dev/null | tr '\n' ' ')" "^pause play $"
rm -f "$HANDFREE_STATE_DIR/state.json" "$HANDFREE_MEDIA_KEY_LOG"
(HANDFREE_NOW_PLAYING=0 HANDFREE_AUDIO_PLAYING=1 reply a 'Music just stopped.'); wait_quiet 2
check "music the user just stopped is left alone, though audio still shows" "[$(cat "$HANDFREE_MEDIA_KEY_LOG" 2>/dev/null)]" "\[\]"
reply a 'Right after our voice.'; wait_quiet 2
(HANDFREE_NOW_PLAYING=1 reply a 'Music started meanwhile.'); wait_quiet 2
check "the Now Playing app's answer needs no wait after our own voice" "$(cat "$HANDFREE_MEDIA_KEY_LOG" 2>/dev/null | tr '\n' ' ')" "^pause play $"

printf '{"version": 0, "queue": [{"bogus": true}]}' > "$HANDFREE_STATE_DIR/state.json"
reset; reply a 'After migration.'; wait_quiet 1.5
check "a state from another version is reset" "$(said)" "After migration."

# Another voice: a script given the text speaks instead of say.
printf 'sleep "${SPEAKER_SECONDS:-0.1}"; printf "other voice: %%s\\n" "$1" >> "%s"; exit "${SPEAKER_EXIT:-0}"\n' "$HANDFREE_SAY_LOG" > "$WORK/speaker.sh"
printf '{"say_path": "%s", "speak_command": "%s", "language": "en", "pause_between_lines_seconds": 0.1, "silence_around_title_ms": 1}\n' "$ROOT/tests/fake-say.sh" "$WORK/speaker.sh" > "$HANDFREE_CONFIG"
rm -f "$HANDFREE_STATE_DIR/state.json"; reset; reply a 'Other voice.'; wait_quiet 1.5
check "speak_command speaks instead of say" "$(said)" "^other voice: Session Project Alpha. Other voice."
check_not "without say's silence marks" "$(said)" "slnc"
reset; SPEAKER_EXIT=1 reply a 'Failing voice.'; wait_quiet 2
check "a failing speak_command hands the line to say" "$(said)" "^Failing voice."
reset; SPEAKER_SECONDS=3 reply a 'Cut short.'; sleep 0.8; hf --quiet >/dev/null; sleep 3
check_not "Quiet stops the other voice too" "$(said)" "Cut short"
configure
ln -s /bin/sleep "$WORK/say"; "$WORK/say" 30 & OTHER_SAY=$!
hf --quiet >/dev/null
check "Quiet leaves the Mac's other say processes alone" "$(kill -0 "$OTHER_SAY" 2>/dev/null && echo alive)" "alive"
kill "$OTHER_SAY" 2>/dev/null

# Pointing at a session: links are recorded instead of opened, and no window, click or key happens.
export HANDFREE_OPEN_LOG="$WORK/links.log" HANDFREE_APP_SESSIONS_DIR="$WORK/app-sessions" HANDFREE_FRONT_APP="" HANDFREE_PROMPT_REACHABLE=0
SID=11111111-2222-3333-4444-555555555555
mkdir -p "$HANDFREE_APP_SESSIONS_DIR/x/y"
printf '{"sessionId":"local_abc-1","cliSessionId":"%s","title":"Speaker"}' "$SID" > "$HANDFREE_APP_SESSIONS_DIR/x/y/local_abc-1.json"
transcript "$SID" 'Speaker'
reset; reply "$SID" 'Who spoke last.'; wait_quiet 1.5
hf --reply >/dev/null
check "Claude Reply opens the session that spoke last" "$(cat "$HANDFREE_OPEN_LOG")" "^claude://code/continue?session=local_abc-1$"
printf '{"sessionId":"local_abc-1","cliSessionId":"%s","title":"Speaker","lastFocusedAt":"9999999999999"}' "$SID" > "$HANDFREE_APP_SESSIONS_DIR/x/y/local_abc-1.json"; rm -f "$HANDFREE_OPEN_LOG"
hf --reply >/dev/null; hf --done >/dev/null
check_not "the session that spoke last already on screen: nothing is opened" "$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)" "claude://"
printf '{"sessionId":"local_abc-1","cliSessionId":"%s","title":"Speaker"}' "$SID" > "$HANDFREE_APP_SESSIONS_DIR/x/y/local_abc-1.json"
reply a 'Then another one spoke.'; sleep 0.3; hf --done >/dev/null; wait_quiet 1.5; rm -f "$HANDFREE_OPEN_LOG"
hf --reply >/dev/null
check "a speaker the app does not know opens no link" "[$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)]" "\[\]"
reset; hf --search-session >/dev/null; reply a 'Not while naming the session.'; sleep 1
check "Claude Session opens the session search" "$(cat "$HANDFREE_OPEN_LOG")" "^claude://code/search$"
check_not "and holds the reading while the name is dictated" "$(said)" "Not while naming"
hf --done >/dev/null; wait_quiet 1.5

# "Stop" goes back to the app "Listen" was said in, once the message has left; already in Claude, it stays there.
export HANDFREE_PROJECTS_DIR="$WORK/projects" HANDFREE_RETURN_WAIT_SECONDS=1
mkdir -p "$HANDFREE_PROJECTS_DIR/p"
sent() { printf '{"type":"queue-operation","operation":"enqueue","timestamp":"%s","content":"%s"}\n' "$(date -u -v+5S +%Y-%m-%dT%H:%M:%S.000Z)" "$1" >> "$HANDFREE_PROJECTS_DIR/p/s.jsonl"; }
: > "$HANDFREE_PROJECTS_DIR/p/s.jsonl"
rm -f "$HANDFREE_OPEN_LOG"; (HANDFREE_FRONT_APP=Safari hf --listen >/dev/null); sent 'Dictated.'; hf --done >/dev/null
check "after Stop and the message sent, back to the app Listen was said in" "$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)" "^back to id.Safari$"
: > "$HANDFREE_PROJECTS_DIR/p/s.jsonl"
rm -f "$HANDFREE_OPEN_LOG"; (HANDFREE_FRONT_APP=Safari hf --listen >/dev/null); hf --done >/dev/null
check "no message sent: Claude stays on screen" "[$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)]" "\\[\\]"
sent '<task-notification>x</task-notification>'
rm -f "$HANDFREE_OPEN_LOG"; (HANDFREE_FRONT_APP=Safari hf --listen >/dev/null); hf --done >/dev/null
check "a notification queued meanwhile is not taken for the message" "[$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)]" "\\[\\]"
: > "$HANDFREE_PROJECTS_DIR/p/s.jsonl"
rm -f "$HANDFREE_OPEN_LOG"; (HANDFREE_FRONT_APP=Claude hf --listen >/dev/null); sent 'Dictated.'; hf --done >/dev/null
check "said in Claude, Stop stays in Claude" "[$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)]" "\\[\\]"
rm -f "$HANDFREE_OPEN_LOG"; (HANDFREE_FRONT_APP=Safari hf --reply >/dev/null); sent 'Dictated.'; hf --done >/dev/null
check "Claude Reply goes back too" "$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)" "^back to id.Safari$"
rm -f "$HANDFREE_OPEN_LOG"; (HANDFREE_FRONT_APP=Safari hf --search-session >/dev/null); sent 'Session name.'; hf --done >/dev/null
check_not "the Stop that picks a session does not go back yet" "$(cat "$HANDFREE_OPEN_LOG")" "back to"
(HANDFREE_FRONT_APP=Claude hf --listen >/dev/null); sent 'Dictated.'; hf --done >/dev/null
check "the Listen that follows goes back to where Session was said" "$(cat "$HANDFREE_OPEN_LOG")" "^back to id.Safari$"
rm -f "$HANDFREE_OPEN_LOG"; printf '{"session_id":"b","transcript_path":"%s/b.jsonl","tool_input":{"questions":["Here?"]}}' "$WORK" | HANDFREE_FRONT_APP=Safari hf --question >/dev/null; sent 'Answer.'; hf --done >/dev/null
check "answering a question switches no app" "[$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)]" "\\[\\]"
configure ', "return_to_previous_app": false'
rm -f "$HANDFREE_OPEN_LOG"; (HANDFREE_FRONT_APP=Safari hf --listen >/dev/null); sent 'Dictated.'; hf --done >/dev/null
check "return_to_previous_app false: Stop stays in Claude" "[$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)]" "\\[\\]"
configure

# Said in another app with Claude's field within reach, the dictation happens with Claude left behind.
rm -f "$HANDFREE_OPEN_LOG"; (HANDFREE_FRONT_APP=Safari HANDFREE_PROMPT_REACHABLE=1 hf --listen >/dev/null); hf --done >/dev/null
check "Listen in another app, Claude reachable: dictated with Claude behind" "$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)" "^dictate behind -$"
rm -f "$HANDFREE_OPEN_LOG"; (HANDFREE_FRONT_APP=Safari HANDFREE_PROMPT_REACHABLE=1 hf --reply >/dev/null); hf --done >/dev/null
check "Reply too, for the session that spoke last" "$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)" "^dictate behind "
rm -f "$HANDFREE_OPEN_LOG"; (HANDFREE_FRONT_APP=Safari HANDFREE_PROMPT_REACHABLE=0 hf --listen >/dev/null); hf --done >/dev/null
check_not "Claude out of reach (full screen elsewhere): as before" "$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)" "dictate behind"
rm -f "$HANDFREE_OPEN_LOG"; (HANDFREE_FRONT_APP=Claude HANDFREE_PROMPT_REACHABLE=1 hf --listen >/dev/null); hf --done >/dev/null
check "said in Claude: through the app's window too (an Escape is seen)" "$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)" "^dictate behind -$"
rm -f "$HANDFREE_OPEN_LOG"; (HANDFREE_FRONT_APP=Claude HANDFREE_PROMPT_REACHABLE=0 hf --listen >/dev/null); hf --done >/dev/null
check_not "the field out of reach: the app pastes into it, as before" "$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)" "dictate behind"
configure ', "dictate_behind": false'
rm -f "$HANDFREE_OPEN_LOG"; (HANDFREE_FRONT_APP=Safari HANDFREE_PROMPT_REACHABLE=1 hf --listen >/dev/null); hf --done >/dev/null
check_not "dictate_behind false: as before" "$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)" "dictate behind"
configure
unset HANDFREE_PROJECTS_DIR HANDFREE_RETURN_WAIT_SECONDS
unset HANDFREE_OPEN_LOG HANDFREE_APP_SESSIONS_DIR HANDFREE_FRONT_APP HANDFREE_PROMPT_REACHABLE

# The spoken-commands listener: what it does with what it hears, in each state of the plugin.
LISTENER="$ROOT/bin/listener.py"
lstate() { printf '%s' "$1" > "$HANDFREE_STATE_DIR/state.json"; }
lcheck() { HANDFREE_CONFIG="$HANDFREE_CONFIG" HANDFREE_STATE_DIR="$HANDFREE_STATE_DIR" /usr/bin/python3 "$LISTENER" --check "$1"; }
printf '{"language": "fr"}' > "$HANDFREE_CONFIG"
lstate '{}'
check "listener: a command said alone runs" "$(lcheck 'Claude écoute')" "^listen$"
check "listener: inside a sentence it does not" "$(lcheck 'je pense que claude écoute')" "^none"
lwords() { HANDFREE_CONFIG="$HANDFREE_CONFIG" /usr/bin/python3 "$LISTENER" --check-words "$1"; }
check "listener: a noise then a pause then the command: it counts" "$(lwords '[["[unk]",0.0,0.3],["claude",0.9,1.2],["écoute",1.2,1.6]]')" "^claude écoute$"
check "listener: the command run into a sentence does not" "$(lwords '[["[unk]",0.0,0.3],["claude",0.35,0.6],["écoute",0.6,0.9],["[unk]",0.95,1.2]]')" "^none$"
lfree() { /usr/bin/python3 "$LISTENER" --check-free "$@"; }
check "listener: a command the free transcription agrees with counts" "$(lfree 'claude réponds' 'claude répond')" "^yes$"
check "listener: refused when it was clearly other words" "$(lfree 'claude écoute' 'je vais écouter la radio')" "^no$"
check "listener: stop needs the word itself" "$(lfree 'stop' "c'est top")" "^no$"
check "listener: nothing transcribed keeps the command" "$(lfree 'claude chut' '')" "^yes$"
check "listener: stop with no dictation does nothing" "$(lcheck 'stop')" "^none"
check "listener: nor cancel" "$(lcheck 'claude annule')" "^none"
lstate "{\"dictating_since\": $(date +%s)}"
check "listener: during a dictation, stop sends it" "$(lcheck 'stop')" "^stop$"
check "listener: and nothing else runs" "$(lcheck 'claude écoute')" "^none"
check "listener: during a dictation, cancel cancels it" "$(lcheck 'claude annule')" "^cancel$"
# A dictation 200 s old: past the default 180 s it holds nothing, under a max_dictation_seconds of 300 it still does,
# for the listener as for the plugin.
lstate "{\"dictating_since\": $(($(date +%s) - 200))}"
check "listener: an abandoned dictation holds nothing" "$(lcheck 'stop')" "^none"
printf '{"language": "fr", "max_dictation_seconds": 300}' > "$HANDFREE_CONFIG"
check "listener: max_dictation_seconds is the plugin's" "$(lcheck 'stop')" "^stop$"
printf '{"language": "fr"}' > "$HANDFREE_CONFIG"
lstate "{\"speaker_pid\": $$, \"current\": {\"lines\": [\"Il dit claude continue ici.\"]}}"
check "listener: while speaking, quiet works" "$(lcheck 'claude tais-toi')" "^quiet$"
check "listener: but not listen" "$(lcheck 'claude écoute')" "^none"
check "listener: nor a command that is in the text being read" "$(lcheck 'claude continue')" "^none"
lstate '{"speaker_pid": 999999, "current": {"lines": ["claude continue"]}}'
check "listener: a voice noted but gone does not count as speaking" "$(lcheck 'claude écoute')" "^listen$"
lstate '{"voice_off": true}'
check "listener: voice mode on has no phrase (nothing listens while it is off)" "$(lcheck 'claude mode vocal activé')" "^none"
check_not "listener: nothing else" "$(lcheck 'claude écoute')" "^listen"
printf '{"language": "fr", "voice_commands": {"Claude Listen": "claude écoute moi"}}' > "$HANDFREE_CONFIG"; lstate '{}'
check "listener: a phrase chosen in voice_commands is used" "$(lcheck 'claude écoute moi')" "^listen$"
printf '{"language": "fr", "voice_commands": {"listen": ["claude écoute bien", "claude à toi"], "Claude Listen": "claude vieux nom"}}' > "$HANDFREE_CONFIG"; lstate '{}'
check "listener: the app's phrases, by command, several per command, over an old name" "$(lcheck 'claude à toi')" "^listen$"
check_not "listener: they replace the defaults" "$(lcheck 'claude écoute')" "^listen$"
mkdir -p "$WORK/support"; cp "$ROOT/bin/listener.py" "$ROOT/bin/voice-commands.json" "$WORK/support/"
check "listener: its installed copy reads the shared defaults next to it" "$(printf '{"language": "en"}' > "$WORK/en.json"; HANDFREE_CONFIG="$WORK/en.json" HANDFREE_STATE_DIR="$HANDFREE_STATE_DIR" /usr/bin/python3 "$WORK/support/listener.py" --check 'claude listen')" "^listen$"
check "the stable copy and the app carry the shared defaults" "$(grep -c voice-commands.json "$ROOT/bin/handfree.js" "$ROOT/app/install.sh" | grep -c ':[1-9]')" "^2$"
rm -f "$HANDFREE_STATE_DIR/state.json"; configure

# "Stop" and "Cancel": the app presses the key (its Accessibility), not Python through System Events.
cat > "$WORK/fake-app.py" <<'PY'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        open(sys.argv[2], "wb").write(str(self.headers).encode() + self.rfile.read(int(self.headers["Content-Length"])))
        body = b'{"jsonrpc":"2.0","id":1,"result":{"pressed":true}}'
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).handle_request()
PY
/usr/bin/python3 "$WORK/fake-app.py" "$APP_PORT" "$WORK/pressed.json" & sleep 0.5
HANDFREE_APP_PORT=$APP_PORT /usr/bin/python3 "$LISTENER" --press escape; wait
check "listener: the app is asked to press the key" "$(cat "$WORK/pressed.json" 2>/dev/null)" '"method": "keys/press", "params": {"key": "escape"}'

# Claude's field out of reach, the app records and types the text in: it asks for its local secret, sent from its file.
/usr/bin/python3 "$WORK/fake-app.py" "$APP_PORT" "$WORK/inserted.txt" & FAKE_APP=$!; sleep 0.5
(HANDFREE_OPEN_LOG="$WORK/links.log" HANDFREE_FRONT_APP=Claude HANDFREE_PROMPT_REACHABLE=0 HANDFREE_DICTATION_URL="http://127.0.0.1:$APP_PORT" hf --listen >/dev/null)
kill "$FAKE_APP" 2>/dev/null; wait "$FAKE_APP" 2>/dev/null
check "dictation/insert is asked of the app" "$(cat "$WORK/inserted.txt" 2>/dev/null)" '"method":"dictation/insert"'
check "with the app's secret" "$(cat "$WORK/inserted.txt" 2>/dev/null)" "X-Handfree-Secret: test-secret"
hf --done >/dev/null

# The app's filter of Whisper's phantom phrases, run alone (needs Swift, as the app does).
if command -v swift >/dev/null 2>&1; then
  { echo 'import Foundation'; sed -n '/^private let phantomPattern/,/^}/p' "$ROOT/app/Sources/DictationSession.swift" | sed 's/^private //'
    echo 'while let line = readLine() { print("[" + withoutPhantoms(line) + "]") }'; } > "$WORK/phantom.swift"
  phantoms=$(printf '%s\n' 'Sous-titrage Société Radio-Canada' "Sous-titres réalisés para la communauté d'Amara.org" \
    'La suite. Stop. Sous-titrage Société Radio-Canada' 'Thank you for watching.' 'Untertitel im Auftrag des ZDF, 2017' \
    'Les sous-titres du film sont bons.' | swift "$WORK/phantom.swift" 2>&1)
  check "app: a phantom alone leaves nothing" "$(printf '%s' "$phantoms" | sed -n 1p)" '^\[\]$'
  check "app: and the Amara one too" "$(printf '%s' "$phantoms" | sed -n 2p)" '^\[\]$'
  check "app: a phantom after Stop leaves the Stop last" "$(printf '%s' "$phantoms" | sed -n 3p)" '^\[La suite. Stop.\]$'
  check "app: English and German phantoms go too" "$(printf '%s' "$phantoms" | sed -n 4,5p | tr -d '\n')" '^\[\]\[\]$'
  check "app: real words about subtitles stay" "$(printf '%s' "$phantoms" | sed -n 6p)" '^\[Les sous-titres du film sont bons.\]$'
  # The double tap of a modifier, run alone with times given: tight, so that a brushed key starts nothing.
  { echo 'import AppKit'; echo 'enum ModifierTaps { static let flags: [UInt16: NSEvent.ModifierFlags] = [54: .command, 55: .command] }'
    sed -n '/^struct TapDetector {/,/^}/p' "$ROOT/app/Sources/VoiceCommands.swift"
    cat <<'SWIFT'
// Each line: taps as "press-length gap press-length…" in seconds, then what the detector says.
func taps(_ times: [Double], key: UInt16 = 54, other: Bool = false) -> String {
  var detector = TapDetector()
  var now = Date(timeIntervalSince1970: 0)
  var result: UInt16?
  for (index, length) in times.enumerated() where index % 2 == 0 {
    if index > 0 { now += times[index - 1] }
    _ = detector.feed(code: key, flags: .command, at: now)
    if other && index > 0 { _ = detector.feed(code: nil, flags: [], at: now) }
    now += length
    result = detector.feed(code: key, flags: [], at: now) ?? result
  }
  return result.map { "tap \($0)" } ?? "none"
}
print(taps([0.1, 0.15, 0.1]))
print(taps([0.1, 0.5, 0.1]))
print(taps([0.35, 0.1, 0.1]))
print(taps([0.1, 0.1, 0.1], other: true))
SWIFT
  } > "$WORK/taps.swift"
  taps=$(swift "$WORK/taps.swift" 2>&1)
  check "app: two quick taps of a modifier alone make a double tap" "$(printf '%s' "$taps" | sed -n 1p)" '^tap 54$'
  check "app: not with a pause between them" "$(printf '%s' "$taps" | sed -n 2p)" '^none$'
  check "app: nor with a key held" "$(printf '%s' "$taps" | sed -n 3p)" '^none$'
  check "app: nor with another key between them" "$(printf '%s' "$taps" | sed -n 4p)" '^none$'
fi

# The install keeps the way Claude's questions travel: run with a scratch home and a fake `claude` that notes its calls.
mkdir -p "$WORK/home/.config" "$WORK/bin"
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$WORK/claude-calls.log" > "$WORK/bin/claude"; chmod +x "$WORK/bin/claude"
transport() { HOME="$WORK/home" HANDFREE_CONFIG= PATH="$WORK/bin:$PATH" sh "$ROOT/bin/set-question-transport.sh" "$@" >/dev/null 2>&1; }
local_transport() { /usr/bin/python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['question_transport']['local'])" "$WORK/home/.config/handfree-code.json"; }
transport keep
check "install: with nothing chosen, questions go through the app" "$(local_transport)" "^mcp$"
transport none; : > "$WORK/claude-calls.log"; transport keep
check "install: a choice of none is kept" "$(local_transport)" "^none$"
check_not "install: and the MCP server is not declared again" "$(cat "$WORK/claude-calls.log")" "mcp add"
HANDFREE_CONFIG="$WORK/transport.json" HOME="$WORK/home" PATH="$WORK/bin:$PATH" sh "$ROOT/bin/set-question-transport.sh" none >/dev/null 2>&1
check "install: the transport script follows HANDFREE_CONFIG" "$(cat "$WORK/transport.json" 2>/dev/null)" '"local": "none"'
# Every installer copies the scripts through the plugin's one list, which records their version: an older session then
# leaves them alone, and the listener and the bridge restart on their new version.
for installer in install.sh install-bridge.sh install-listener.sh set-question-transport.sh; do
  check "install: $installer copies through the plugin's one list" "$(grep -c 'handfree.js" --refresh-stable-copy' "$ROOT/bin/$installer")" "^[1-9]"
done
check "install: the app's install brings the scripts to its own version" "$(grep -c 'handfree.js" --refresh-stable-copy' "$ROOT/app/install.sh")" "^[1-9]"
rm -rf "$WORK/support"/*; printf '99.0.0\n' > "$WORK/support/version"; hf --refresh-stable-copy >/dev/null
check "install: an install copies even over a newer version" "$(ls "$WORK/support")" "listener.py"
check "install: and records the version it copied" "$(cat "$WORK/support/version")" "^$VERSION$"

# The MCP relay, the app not answering: a request gets an error at once, a notification nothing.
out=$(printf '%s\n' '{"jsonrpc":"2.0","id":7,"method":"tools/list"}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' | sh "$ROOT/bin/mcp-relay.sh")
check "relay: the app not answering, a request gets an error" "$out" '"id": 7, "error"'
check "relay: and a notification nothing" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "^1$"

hf --off >/dev/null 2>&1
rm -rf "$WORK"
[ "$FAILS" -eq 0 ] && echo "ALL PASSED" || { echo "$FAILS FAILED"; exit 1; }
