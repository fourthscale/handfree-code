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
check "the pause after the first paragraph is announced" "$(said)" "Details available."

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

reset; reply a 'A long line being read.\nSame paragraph.\n\nNext line.'; sleep 0.3
printf '{"session_id":"b","transcript_path":"%s/b.jsonl","tool_input":{"questions":["Shall we?"]}}' "$WORK" | hf --question >/dev/null
check "a question lets the reading under way reach its pause first" "$(said | tr '\n' ' ')" "A long line being read.*Same paragraph.*Details available.*A question.*Shall we"
printf '{"session_id":"b","transcript_path":"%s/b.jsonl"}' "$WORK" | hf --notify; sleep 1
check_not "the waiting notice is dropped while the answer is dictated" "$(said)" "Claude needs your answer"
check_not "and holds the rest until the answer" "$(said)" "Next line"
hf --done >/dev/null; hf --resume >/dev/null; wait_quiet 1.5
check "after the answer, Continue reads the rest" "$(said)" "Next line"
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
check_not "with no rest announced" "$(said)" "Details available"
printf '{"session_id":"k"}' | hf --answered >/dev/null

# "Claude Cancel" (Escape in Spokenly): the dictation ends, nothing is sent, readings go on.
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
(printf '{"session_id":"y","transcript_path":"%s/y.jsonl","tool_input":{"questions":["Question from Y?"]}}' "$WORK" | hf --question >/dev/null) &
sleep 2
check_not "a second session's question waits while the first is answered" "$(said)" "Question from Y"
printf '{"session_id":"x","tool_response":[{"type":"text","text":"Q: Question from X?\\nA: Fine. Stop"}]}' | hf --answered >/dev/null
wait
check "then it is asked" "$(said | tr '\n' ' ')" "Question from X.*Question from Y"
printf '{"session_id":"y"}' | hf --answered >/dev/null

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
fi

if spokenly_declared; then
  out=$(printf '{"session_id":"b","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which?"}]}}' | hf --guard-question)
  check "the app's multiple-choice question is turned back to Spokenly" "$out" '"permissionDecision":"deny".*mcp__spokenly__ask_user_dictation'
  out=$(printf '{"session_id":"b","tool_name":"mcp__ccd_session__start_session","tool_input":{"initiation":"offer","title":"x"}}' | hf --guard-question)
  check "the app's session offer is asked through Spokenly" "$out" '"permissionDecision":"deny".*new session or here'
  out=$(printf '{"session_id":"b","tool_name":"mcp__ccd_session__start_session","tool_input":{"initiation":"own_initiative","title":"x"}}' | hf --guard-question)
  check_not "a proposal card waiting for nobody is let through" "$out" "deny"
  out=$(printf '{"session_id":"b","tool_name":"AskUserQuestion","tool_input":{}}' | HANDFREE_IDLE_SECONDS=3600 sh -c "osascript -l JavaScript '$SCRIPT' --guard-question")
  check_not "away from the Mac, the app's question is let through" "$out" "deny"
  hf --off >/dev/null; out=$(printf '{"session_id":"b","tool_name":"AskUserQuestion","tool_input":{}}' | hf --guard-question); hf --on >/dev/null; reset
  check_not "voice mode off, the app's question is let through" "$out" "deny"
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
HANDFREE_AUDIO_PLAYING=1 hf --dictating >/dev/null; HANDFREE_AUDIO_PLAYING=0 hf --done >/dev/null; wait_quiet 1.5
check "a dictation pauses the music, Stop resumes it" "$(cat "$HANDFREE_MEDIA_KEY_LOG" 2>/dev/null | tr '\n' ' ')" "^pause play $"
# A dictation sent with Return, not "Stop": it runs out, and the music the user resumed meanwhile is paused again.
configure ', "max_dictation_seconds": 1'; rm -f "$HANDFREE_MEDIA_KEY_LOG"
HANDFREE_NOW_PLAYING=1 hf --dictating >/dev/null; sleep 1.5
HANDFREE_NOW_PLAYING=1 reply b 'Music resumed by hand meanwhile.'; sleep 1
check "music resumed by hand after a dictation is paused again for a reading" "$(cat "$HANDFREE_MEDIA_KEY_LOG" 2>/dev/null | tr '\n' ' ')" "^pause pause"
wait_quiet 2; configure
rm -f "$HANDFREE_STATE_DIR/state.json" "$HANDFREE_MEDIA_KEY_LOG"
rm -f "$HANDFREE_STATE_DIR/state.json" "$HANDFREE_MEDIA_KEY_LOG"
HANDFREE_AUDIO_PLAYING=0 reply a 'In silence.'; wait_quiet 2
check "nothing playing: nothing is sent" "[$(cat "$HANDFREE_MEDIA_KEY_LOG" 2>/dev/null)]" "\[\]"
reply a 'Right after.'; wait_quiet 2
HANDFREE_AUDIO_PLAYING=1 reply a 'Own voice still reported.'; wait_quiet 2
check "our own voice is not taken for music" "[$(cat "$HANDFREE_MEDIA_KEY_LOG" 2>/dev/null)]" "\[\]"
rm -f "$HANDFREE_STATE_DIR/state.json" "$HANDFREE_MEDIA_KEY_LOG"
printf '{"session_id":"b","transcript_path":"%s/b.jsonl","tool_input":{"questions":["Over the music?"]}}' "$WORK" | HANDFREE_AUDIO_PLAYING=1 hf --question >/dev/null
check "a question pauses the music too" "$(cat "$HANDFREE_MEDIA_KEY_LOG" 2>/dev/null | tr '\n' ' ')" "^pause $"
hf --done >/dev/null; printf '{"session_id":"b"}' | hf --answered >/dev/null; wait_quiet 1.5
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
rm -f "$HANDFREE_OPEN_LOG"; HANDFREE_FRONT_APP=Safari hf --listen >/dev/null; sent 'Dictated.'; hf --done >/dev/null
check "after Stop and the message sent, back to the app Listen was said in" "$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)" "^back to id.Safari$"
: > "$HANDFREE_PROJECTS_DIR/p/s.jsonl"
rm -f "$HANDFREE_OPEN_LOG"; HANDFREE_FRONT_APP=Safari hf --listen >/dev/null; hf --done >/dev/null
check "no message sent: Claude stays on screen" "[$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)]" "\\[\\]"
sent '<task-notification>x</task-notification>'
rm -f "$HANDFREE_OPEN_LOG"; HANDFREE_FRONT_APP=Safari hf --listen >/dev/null; hf --done >/dev/null
check "a notification queued meanwhile is not taken for the message" "[$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)]" "\\[\\]"
: > "$HANDFREE_PROJECTS_DIR/p/s.jsonl"
rm -f "$HANDFREE_OPEN_LOG"; HANDFREE_FRONT_APP=Claude hf --listen >/dev/null; sent 'Dictated.'; hf --done >/dev/null
check "said in Claude, Stop stays in Claude" "[$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)]" "\\[\\]"
rm -f "$HANDFREE_OPEN_LOG"; HANDFREE_FRONT_APP=Safari hf --reply >/dev/null; sent 'Dictated.'; hf --done >/dev/null
check "Claude Reply goes back too" "$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)" "^back to id.Safari$"
rm -f "$HANDFREE_OPEN_LOG"; HANDFREE_FRONT_APP=Safari hf --search-session >/dev/null; sent 'Session name.'; hf --done >/dev/null
check_not "the Stop that picks a session does not go back yet" "$(cat "$HANDFREE_OPEN_LOG")" "back to"
HANDFREE_FRONT_APP=Claude hf --listen >/dev/null; sent 'Dictated.'; hf --done >/dev/null
check "the Listen that follows goes back to where Session was said" "$(cat "$HANDFREE_OPEN_LOG")" "^back to id.Safari$"
rm -f "$HANDFREE_OPEN_LOG"; printf '{"session_id":"b","transcript_path":"%s/b.jsonl","tool_input":{"questions":["Here?"]}}' "$WORK" | HANDFREE_FRONT_APP=Safari hf --question >/dev/null; sent 'Answer.'; hf --done >/dev/null
check "answering a question switches no app" "[$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)]" "\\[\\]"
configure ', "return_to_previous_app": false'
rm -f "$HANDFREE_OPEN_LOG"; HANDFREE_FRONT_APP=Safari hf --listen >/dev/null; sent 'Dictated.'; hf --done >/dev/null
check "return_to_previous_app false: Stop stays in Claude" "[$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)]" "\\[\\]"
configure

# Said in another app with Claude's field within reach, the dictation happens with Claude left behind.
rm -f "$HANDFREE_OPEN_LOG"; HANDFREE_FRONT_APP=Safari HANDFREE_PROMPT_REACHABLE=1 hf --listen >/dev/null; hf --done >/dev/null
check "Listen in another app, Claude reachable: dictated with Claude behind" "$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)" "^dictate behind -$"
rm -f "$HANDFREE_OPEN_LOG"; HANDFREE_FRONT_APP=Safari HANDFREE_PROMPT_REACHABLE=1 hf --reply >/dev/null; hf --done >/dev/null
check "Reply too, for the session that spoke last" "$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)" "^dictate behind "
rm -f "$HANDFREE_OPEN_LOG"; HANDFREE_FRONT_APP=Safari HANDFREE_PROMPT_REACHABLE=0 hf --listen >/dev/null; hf --done >/dev/null
check_not "Claude out of reach (full screen elsewhere): as before" "$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)" "dictate behind"
rm -f "$HANDFREE_OPEN_LOG"; HANDFREE_FRONT_APP=Claude HANDFREE_PROMPT_REACHABLE=1 hf --listen >/dev/null; hf --done >/dev/null
check "said in Claude: through Spokenly's window too (an Escape is seen)" "$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)" "^dictate behind -$"
rm -f "$HANDFREE_OPEN_LOG"; HANDFREE_FRONT_APP=Claude HANDFREE_PROMPT_REACHABLE=0 hf --listen >/dev/null; hf --done >/dev/null
check_not "the field out of reach: Spokenly types into it, as before" "$(cat "$HANDFREE_OPEN_LOG" 2>/dev/null)" "dictate behind"
configure ', "dictate_behind": false'
rm -f "$HANDFREE_OPEN_LOG"; HANDFREE_FRONT_APP=Safari HANDFREE_PROMPT_REACHABLE=1 hf --listen >/dev/null; hf --done >/dev/null
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
lfree() { /usr/bin/python3 "$LISTENER" --check-free "$1" "$2"; }
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
lstate "{\"speaker_pid\": $$, \"current\": {\"lines\": [\"Il dit claude continue ici.\"]}}"
check "listener: while speaking, quiet works" "$(lcheck 'claude tais-toi')" "^quiet$"
check "listener: but not listen" "$(lcheck 'claude écoute')" "^none"
check "listener: nor a command that is in the text being read" "$(lcheck 'claude continue')" "^none"
lstate '{"speaker_pid": 999999, "current": {"lines": ["claude continue"]}}'
check "listener: a voice noted but gone does not count as speaking" "$(lcheck 'claude écoute')" "^listen$"
lstate '{"voice_off": true}'
check "listener: voice mode off, only voice mode on" "$(lcheck 'claude mode vocal activé')" "^voice_on$"
check_not "listener: nothing else" "$(lcheck 'claude écoute')" "^listen"
printf '{"language": "fr", "voice_commands": {"Claude Listen": "claude écoute moi"}}' > "$HANDFREE_CONFIG"; lstate '{}'
check "listener: a phrase chosen in voice_commands is used" "$(lcheck 'claude écoute moi')" "^listen$"
rm -f "$HANDFREE_STATE_DIR/state.json"; configure

hf --off >/dev/null 2>&1
rm -rf "$WORK"
[ "$FAILS" -eq 0 ] && echo "ALL PASSED" || { echo "$FAILS FAILED"; exit 1; }
