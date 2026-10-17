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

configure() { printf '{"say_path": "%s", "language": "en", "pause_between_lines_seconds": 0.1, "silence_around_title_ms": 1%s}\n' "$ROOT/tests/fake-say.sh" "${1:-}" > "$HANDFREE_CONFIG"; }
hf() { HANDFREE_IDLE_SECONDS=${HANDFREE_IDLE_SECONDS:-0} osascript -l JavaScript "$SCRIPT" "$@"; }
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

reset; printf '{"session_id":"b","transcript_path":"%s/b.jsonl","tool_input":{"questions":["Shall we?"]}}' "$WORK" | hf --question >/dev/null
check "a question is announced with its session" "$(said)" "Session Project Beta.*A question.*Shall we"
reply a 'After the question.'; sleep 1
check_not "the queue waits for the answer" "$(said)" "After the question"
hf --done >/dev/null; wait_quiet 1.5

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

printf '{"version": 0, "queue": [{"bogus": true}]}' > "$HANDFREE_STATE_DIR/state.json"
reset; reply a 'After migration.'; wait_quiet 1.5
check "a state from another version is reset" "$(said)" "After migration."

hf --off >/dev/null 2>&1
rm -rf "$WORK"
[ "$FAILS" -eq 0 ] && echo "ALL PASSED" || { echo "$FAILS FAILED"; exit 1; }
