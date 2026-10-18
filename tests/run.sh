#!/bin/sh
# Silent tests: a fake `say` writes to a log, state and config live in a scratch folder.
# Usage: tests/run.sh   (needs no sound, does not touch your real state)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/bin/handfree.js"
WORK=$(mktemp -d)
export HANDFREE_STATE_DIR="$WORK/state" HANDFREE_CONFIG="$WORK/config.json" HANDFREE_SAY_LOG="$WORK/said.log"
chmod +x "$ROOT/tests/fake-say.sh"
FAILS=0

configure() { printf '{"say_path": "%s", "language": "en", "announce_session": "always", "pause_between_lines_seconds": 0.1, "silence_around_title_ms": 1%s}\n' "$ROOT/tests/fake-say.sh" "${1:-}" > "$HANDFREE_CONFIG"; }
# The Now Playing answer is unknown by default: the tests then go through the audio-signal fallback.
hf() { HANDFREE_IDLE_SECONDS=${HANDFREE_IDLE_SECONDS:-0} HANDFREE_AUDIO_PLAYING=${HANDFREE_AUDIO_PLAYING:-0} HANDFREE_NOW_PLAYING=${HANDFREE_NOW_PLAYING:-unknown} osascript -l JavaScript "$SCRIPT" "$@"; }
transcript() { printf '{"type":"custom-title","customTitle":"%s"}\n' "$2" > "$WORK/$1.jsonl"; }
reply() { printf '{"session_id":"%s","transcript_path":"%s/%s.jsonl","last_assistant_message":"%s"}' "$1" "$WORK" "$1" "$2" | hf >/dev/null; }
said() { cat "$HANDFREE_SAY_LOG" 2>/dev/null; }
reset() { : > "$HANDFREE_SAY_LOG"; }
wait_quiet() { sleep "${1:-2}"; }
check() {
  if printf '%s' "$2" | grep -q -- "$3"; then echo "ok   $1"; else echo "FAIL $1"; echo "     expected: $3"; echo "     got: $(printf '%s' "$2" | tr '\n' '|')"; FAILS=$((FAILS + 1)); fi
}
check_not() {
  if printf '%s' "$2" | grep -q -- "$3"; then echo "FAIL $1"; echo "     unexpected: $3"; FAILS=$((FAILS + 1)); else echo "ok   $1"; fi
}
spokenly_declared() { grep -q '"spokenly"' "$HOME/.claude.json" 2>/dev/null; }

configure
transcript a 'Project Alpha'
transcript b 'Project Beta'

reset; reply a 'A one.\nA two.\n\nA more.'; reply b 'B one.'; wait_quiet 3
check "replies are queued, each announced" "$(said)" "Session Project Alpha.*A one"
check "the second session is announced" "$(said)" "Session Project Beta.*B one"
check_not "only the first paragraph is read" "$(said)" "A more"
check "the pause after the first paragraph is announced" "$(said)" "There is more."

reset; reply a 'Alone.\n\nHidden rest.'; wait_quiet 1.5
check_not "the rest waits" "$(said)" "Hidden rest"
hf --resume >/dev/null; wait_quiet 1.5
check "Continue reads the rest of the last reply" "$(said)" "Hidden rest"

reset; reply a 'See https://x.y/z.\n```js\nx()\n```\nEnd.'; wait_quiet 1.5; hf --resume >/dev/null; wait_quiet 2
check "a web address is read as link" "$(said)" "See link."
check "a code block is announced as skipped" "$(said)" "Code block skipped."

reset; reply a 'L1.\nL2.\nL3.\nL4.'; sleep 0.5; hf --stop >/dev/null; n=$(said | wc -l); sleep 1
check "Quiet stops the reading" "$(said | wc -l)" "$n"
reset; hf --resume >/dev/null; wait_quiet 2.5
check "Continue announces again and goes on" "$(said)" "Session Project Alpha.*L"
reset; hf --restart >/dev/null; wait_quiet 2.5
check "Restart starts over" "$(said)" "L1."

reset; hf --dictating >/dev/null; reply a 'During the dictation.'; sleep 1
check_not "nothing is read while dictating" "$(said)" "During"
hf --done >/dev/null; wait_quiet 1.5
check "Stop lets the queue go on" "$(said)" "During the dictation"

reset; reply a 'A long line being read.\nNext line.'; sleep 0.3
printf '{"session_id":"b","transcript_path":"%s/b.jsonl","tool_input":{"questions":["Shall we?"]}}' "$WORK" | hf --question >/dev/null
check "a question lets the current line end first" "$(said | tr '\n' ' ')" "A long line being read.*A question.*Shall we"
printf '{"session_id":"b","transcript_path":"%s/b.jsonl"}' "$WORK" | hf --notify; sleep 1
check_not "the waiting notice is dropped while the answer is dictated" "$(said)" "Claude needs your answer"
check_not "and holds the rest until the answer" "$(said)" "Next line"
hf --done >/dev/null; wait_quiet 1.5
check "the rest follows the answer" "$(said)" "Next line"
reset; printf '{"session_id":"b","transcript_path":"%s/b.jsonl","tool_input":{"questions":["Shall we?"]}}' "$WORK" | hf --question >/dev/null
check "a question is announced with its session" "$(said)" "Session Project Beta.*A question.*Shall we"
reply a 'After the question.'; sleep 1
check_not "the queue waits for the answer" "$(said)" "After the question"
hf --done >/dev/null; wait_quiet 1.5

reset; printf '{"session_id":"a","transcript_path":"%s/a.jsonl","tool_input":{"questions":["First?"]}}' "$WORK" | hf --question >/dev/null
printf '{"session_id":"a","tool_name":"mcp__spokenly__ask_user_dictation"}' | hf --answered >/dev/null
reply a 'Answer to the first.'; wait_quiet 1.5
check "an answer sent from Spokenly, without Stop, frees the queue" "$(said)" "Answer to the first"
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
check "the text before a question is read first" "$(said | tr '\n' ' ')" "Intro para.*There is more.*A question.*Which one"
check_not "only its first paragraph" "$(said)" "More para"
hf --resume >/dev/null; wait_quiet 1.5
check "Continue reads the rest while the answer is awaited" "$(said)" "More para"
printf '{"session_id":"q"}' | hf --answered >/dev/null
reset; reply q 'Intro para.\n\nMore para.'; wait_quiet 1.5
check_not "the same text is not read again at the turn's end" "$(said)" "Intro para"
reply q 'Final words.'; wait_quiet 1.5
check "a new reply is read" "$(said)" "Final words"

reset; printf '{"type":"user","turnOrigin":"sdk","message":{"content":"Background (from the session that started this one): x"}}\n' >> "$WORK/b.jsonl"
reply b 'Delegated task.'; sleep 1
check_not "a turn delegated by another session is not read" "$(said)" "Delegated task"
printf '{"type":"user","turnOrigin":"human","message":{"content":"Ask me a question"}}\n' >> "$WORK/b.jsonl"
reply b 'Direct answer.'; wait_quiet 1.5
check "a turn asked by the user is read" "$(said)" "Direct answer."

reset; printf '{"session_id":"a","transcript_path":"%s/a.jsonl"}' "$WORK" | hf --notify; wait_quiet 1.5
check "the waiting notice names its session" "$(said)" "Session Project Alpha.*Claude needs your answer"

reset; hf --off >/dev/null; reply a 'Muted.'; rules=$(hf --session-rules); sleep 1
check "switching off is said" "$(said)" "Voice mode off."
check_not "nothing is read while off" "$(said)" "Muted"
check "no rules are injected while off" "[$rules]" "\[\]"
hf --toggle >/dev/null
check "switching back on is said" "$(said)" "Voice mode on."

printf '{"say_path": "%s", "language": "en", "validation_word": "banana"}\n' "$ROOT/tests/fake-say.sh" > "$HANDFREE_CONFIG"
rules=$(hf --session-rules)
if spokenly_declared; then
  check "rules follow the language and validation word" "$rules" 'saying "banana"'
fi
set_transport() { printf '{"say_path": "%s", "language": "en", "question_transport": {"local": "%s", "cloud": "%s"}}\n' "$ROOT/tests/fake-say.sh" "$1" "$2" > "$HANDFREE_CONFIG"; }
set_transport none bridge
check "transport none: no voice rules" "[$(hf --session-rules)]" "\[\]"
if spokenly_declared; then
  set_transport bridge bridge
  check "local bridge with Spokenly up: rules" "$(HANDFREE_SPOKENLY_UP=1 hf --session-rules)" "Voice mode is on"
  check "local bridge with Spokenly down: no rules" "[$(HANDFREE_SPOKENLY_UP=0 hf --session-rules)]" "\[\]"
fi
set_transport mcp none
check "cloud transport none: no rules for a cloud session" "[$(HANDFREE_CONTEXT=cloud hf --session-rules)]" "\[\]"
set_transport mcp bridge
check "cloud bridge with Spokenly up: rules for a cloud session" "$(HANDFREE_CONTEXT=cloud HANDFREE_SPOKENLY_UP=1 hf --session-rules)" "Voice mode is on"
configure

if spokenly_declared; then
  reset; out=$(printf '{"session_id":"a","transcript_path":"%s/a.jsonl","last_assistant_message":"Done.\\n\\nShall I push it?"}' "$WORK" | hf); sleep 1
  check "a reply ending on a written question is sent back" "$out" '"decision":"block"'
  check_not "and is not read meanwhile" "$(said)" "push"
  out=$(printf '{"session_id":"a","stop_hook_active":true,"transcript_path":"%s/a.jsonl","last_assistant_message":"Shall I push it?"}' "$WORK" | hf)
  check_not "a reply already sent back once is not sent back again" "$out" "block"
  wait_quiet 1.5
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__ccd_turn__wrap_up","input":{"recap":"x","ask":"Publish?"}}]}}\n' >> "$WORK/a.jsonl"
  out=$(printf '{"session_id":"a","transcript_path":"%s/a.jsonl","last_assistant_message":"Done."}' "$WORK" | hf)
  check "a question in the app box is sent back" "$out" '"decision":"block"'
  printf '{"type":"user","turnOrigin":"human","message":{"content":"go on"}}\n' >> "$WORK/a.jsonl"
  out=$(printf '{"session_id":"a","transcript_path":"%s/a.jsonl","last_assistant_message":"Why? Because.\\n\\nDone."}' "$WORK" | hf)
  check_not "a question earlier in the reply is not sent back" "$out" "block"
  wait_quiet 1.5
fi

reset; out=$(HANDFREE_IDLE_SECONDS=3600 sh -c "printf '{\"session_id\":\"b\",\"transcript_path\":\"%s/b.jsonl\",\"tool_input\":{\"questions\":[\"Away?\"]}}' '$WORK' | osascript -l JavaScript '$SCRIPT' --question")
check "away from the Mac, the Spokenly question is refused" "$out" '"permissionDecision":"deny"'
check_not "and nothing is said" "$(said)" "Away"
if spokenly_declared; then
  out=$(HANDFREE_IDLE_SECONDS=3600 sh -c "printf '{\"session_id\":\"a\",\"transcript_path\":\"%s/a.jsonl\",\"last_assistant_message\":\"Publish?\"}' '$WORK' | osascript -l JavaScript '$SCRIPT'")
  check_not "away from the Mac, a written question is allowed" "$out" "block"
  wait_quiet 1.5
fi

# Voice permissions: a fake Spokenly answers with the text in $WORK/answer.txt.
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
' 8796 "$WORK/answer.txt" &
SPOKENLY_PID=$!
sleep 0.5
permission() {  # $1: the spoken answer
  printf '%s' "$1" > "$WORK/answer.txt"; export HANDFREE_FAKE_SAY_SECONDS=2
  printf '{"session_id":"a","transcript_path":"%s/a.jsonl","tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' "$WORK" | HANDFREE_SPOKENLY_URL=http://127.0.0.1:8796 hf --permission
}
configure ', "voice_permissions": true'
reset; out=$(permission 'oui stop')
check "a spoken yes allows" "$out" '"behavior":"allow"'
check "the request is read with its session" "$(said)" "Session Project Alpha.*Permission requested: git commit"
check "the request is read in full before listening" "$(cat "$WORK/order.log" 2>/dev/null)" "said-then-asked"
check "deny on a spoken no" "$(permission 'non')" '"behavior":"deny"'
check "an unclear answer leaves the dialog" "[$(permission 'well I do not know')]" "\[\]"
check "a mixed answer leaves the dialog" "[$(permission 'yes no')]" "\[\]"
check "away from the Mac, the dialog shows as usual" "[$(HANDFREE_IDLE_SECONDS=3600 permission 'yes')]" "\[\]"
configure
check "off by default" "[$(permission 'yes')]" "\[\]"
kill "$SPOKENLY_PID" 2>/dev/null; wait "$SPOKENLY_PID" 2>/dev/null
unset HANDFREE_FAKE_SAY_SECONDS

# Default: the name is said only when the speaking session changes.
printf '{"say_path": "%s", "language": "en", "pause_between_lines_seconds": 0.1, "silence_around_title_ms": 1}\n' "$ROOT/tests/fake-say.sh" > "$HANDFREE_CONFIG"
rm -f "$HANDFREE_STATE_DIR/state.json"  # no one has spoken yet
reset; reply a 'First.'; reply a 'Second.'; reply b 'Third.'; reply b 'Fourth.'; wait_quiet 4
check "a session's name is said once while it keeps talking" "$(said | grep -c 'Session Project Alpha')" "^1$"
check "and again when another session speaks" "$(said | grep -c 'Session Project Beta')" "^1$"
reset; printf '{"session_id":"b","transcript_path":"%s/b.jsonl","tool_input":{"questions":["Same speaker?"]}}' "$WORK" | hf --question >/dev/null
check_not "a question from the same session skips the name" "$(said)" "Session"
hf --done >/dev/null
reset; printf '{"session_id":"a","transcript_path":"%s/a.jsonl","tool_input":{"questions":["Other speaker?"]}}' "$WORK" | hf --question >/dev/null
check "a question from another session says its name" "$(said)" "Session Project Alpha.*Other speaker"
hf --done >/dev/null; wait_quiet 1
configure

# Pausing what plays: the media commands are recorded instead of sent.
export HANDFREE_MEDIA_KEY_LOG="$WORK/keys.log"
rm -f "$HANDFREE_STATE_DIR/state.json" "$HANDFREE_MEDIA_KEY_LOG"
HANDFREE_AUDIO_PLAYING=1 reply a 'Over the music.'; wait_quiet 2
check "music playing: paused before speaking, resumed after" "$(cat "$HANDFREE_MEDIA_KEY_LOG" 2>/dev/null | tr '\n' ' ')" "^pause play $"
rm -f "$HANDFREE_STATE_DIR/state.json" "$HANDFREE_MEDIA_KEY_LOG"
HANDFREE_AUDIO_PLAYING=0 reply a 'In silence.'; wait_quiet 2
check "nothing playing: nothing is sent" "[$(cat "$HANDFREE_MEDIA_KEY_LOG" 2>/dev/null)]" "\[\]"
reply a 'Right after.'; wait_quiet 2
HANDFREE_AUDIO_PLAYING=1 reply a 'Own voice still reported.'; wait_quiet 2
check "our own voice is not taken for music" "[$(cat "$HANDFREE_MEDIA_KEY_LOG" 2>/dev/null)]" "\[\]"
rm -f "$HANDFREE_STATE_DIR/state.json" "$HANDFREE_MEDIA_KEY_LOG"
printf '{"session_id":"b","transcript_path":"%s/b.jsonl","tool_input":{"questions":["Over the music?"]}}' "$WORK" | HANDFREE_AUDIO_PLAYING=1 hf --question >/dev/null
check "a question pauses the music too" "$(cat "$HANDFREE_MEDIA_KEY_LOG" 2>/dev/null | tr '\n' ' ')" "^pause $"
hf --done >/dev/null; wait_quiet 1.5
check "and the answer given, the music resumes" "$(cat "$HANDFREE_MEDIA_KEY_LOG" 2>/dev/null | tr '\n' ' ')" "^pause play $"
rm -f "$HANDFREE_STATE_DIR/state.json" "$HANDFREE_MEDIA_KEY_LOG"
HANDFREE_NOW_PLAYING=0 HANDFREE_AUDIO_PLAYING=1 reply a 'Music just stopped.'; wait_quiet 2
check "music the user just stopped is left alone, though audio still shows" "[$(cat "$HANDFREE_MEDIA_KEY_LOG" 2>/dev/null)]" "\[\]"
reply a 'Right after our voice.'; wait_quiet 2
HANDFREE_NOW_PLAYING=1 reply a 'Music started meanwhile.'; wait_quiet 2
check "the Now Playing app's answer needs no wait after our own voice" "$(cat "$HANDFREE_MEDIA_KEY_LOG" 2>/dev/null | tr '\n' ' ')" "^pause play $"
unset HANDFREE_MEDIA_KEY_LOG

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
reset; SPEAKER_SECONDS=3 reply a 'Cut short.'; sleep 0.8; hf --stop >/dev/null; sleep 3
check_not "Quiet stops the other voice too" "$(said)" "Cut short"
configure

# Pointing at a session: links are recorded instead of opened, and no window, click or key happens.
export HANDFREE_OPEN_LOG="$WORK/links.log" HANDFREE_APP_SESSIONS_DIR="$WORK/app-sessions"
SID=11111111-2222-3333-4444-555555555555
mkdir -p "$HANDFREE_APP_SESSIONS_DIR/x/y"
printf '{"sessionId":"local_abc-1","cliSessionId":"%s","title":"Speaker"}' "$SID" > "$HANDFREE_APP_SESSIONS_DIR/x/y/local_abc-1.json"
transcript "$SID" 'Speaker'
reset; reply "$SID" 'Who spoke last.'; wait_quiet 1.5
hf --reply >/dev/null
check "Claude Reply opens the session that spoke last" "$(cat "$HANDFREE_OPEN_LOG")" "^claude://code/continue?session=local_abc-1$"
reply a 'Then another one spoke.'; sleep 0.3; hf --done >/dev/null; wait_quiet 1.5; rm -f "$HANDFREE_OPEN_LOG"
hf --reply >/dev/null
check "a speaker the app does not know opens no link" "[$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)]" "\[\]"
reset; hf --search-session >/dev/null; reply a 'Not while naming the session.'; sleep 1
check "Claude Session opens the session search" "$(cat "$HANDFREE_OPEN_LOG")" "^claude://code/search$"
check_not "and holds the reading while the name is dictated" "$(said)" "Not while naming"
hf --done >/dev/null; wait_quiet 1.5
unset HANDFREE_OPEN_LOG HANDFREE_APP_SESSIONS_DIR

hf --off >/dev/null 2>&1
rm -rf "$WORK"
[ "$FAILS" -eq 0 ] && echo "ALL PASSED" || { echo "$FAILS FAILED"; exit 1; }
