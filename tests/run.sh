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

configure() { printf '{"say_path": "%s", "language": "fr", "pause_between_lines_seconds": 0.1, "silence_around_title_ms": 1%s}\n' "$ROOT/tests/fake-say.sh" "${1:-}" > "$HANDFREE_CONFIG"; }
hf() { HANDFREE_IDLE_SECONDS=${HANDFREE_IDLE_SECONDS:-0} osascript -l JavaScript "$SCRIPT" "$@"; }
transcript() { printf '{"type":"custom-title","customTitle":"%s"}\n' "$2" > "$WORK/$1.jsonl"; }
reply() { printf '{"session_id":"%s","transcript_path":"%s/%s.jsonl","last_assistant_message":"%s"}' "$1" "$WORK" "$1" "$2" | hf >/dev/null; }
said() { cat "$HANDFREE_SAY_LOG" 2>/dev/null; }
reset() { : > "$HANDFREE_SAY_LOG"; }
wait_quiet() { sleep "${1:-2}"; }
# macOS may hand accented letters back decomposed (NFD): patterns avoid them.
check() {
  if printf '%s' "$2" | grep -q -- "$3"; then echo "ok   $1"; else echo "FAIL $1"; echo "     expected: $3"; echo "     got: $(printf '%s' "$2" | tr '\n' '|')"; FAILS=$((FAILS + 1)); fi
}
check_not() {
  if printf '%s' "$2" | grep -q -- "$3"; then echo "FAIL $1"; echo "     unexpected: $3"; FAILS=$((FAILS + 1)); else echo "ok   $1"; fi
}

configure
transcript a 'Projet Alpha'
transcript b 'Projet Beta'

reset; reply a 'A un.\nA deux.\n\nA suite.'; reply b 'B un.'; wait_quiet 3
check "replies are queued, each announced" "$(said)" "Session Projet Alpha.*A un"
check "the second session is announced" "$(said)" "Session Projet Beta.*B un"
check_not "only the first paragraph is read" "$(said)" "A suite"
check "the pause after the first paragraph is announced" "$(said)" "Il y a une suite."

reset; reply a 'Seul.\n\nSuite cachée.'; wait_quiet 1.5
check_not "the rest waits" "$(said)" "Suite cach"
hf --resume >/dev/null; wait_quiet 1.5
check "« Continue » reads the rest of the last reply" "$(said)" "Suite cach"

reset; reply a 'Voir https://x.y/z.\n```js\nx()\n```\nFin.'; wait_quiet 1.5; hf --resume >/dev/null; wait_quiet 2
check "a web address is read as « lien »" "$(said)" "Voir lien."
check "a code block is announced as skipped" "$(said)" "Bloc de code omis."

reset; reply a 'L1.\nL2.\nL3.\nL4.'; sleep 0.5; hf --stop >/dev/null; n=$(said | wc -l); sleep 1
check "« Tais-toi » stops the reading" "$(said | wc -l)" "$n"
reset; hf --resume >/dev/null; wait_quiet 2.5
check "« Continue » announces again and goes on" "$(said)" "Session Projet Alpha.*L"
reset; hf --restart >/dev/null; wait_quiet 2.5
check "« Recommence » starts over" "$(said)" "L1."

reset; hf --dictating >/dev/null; reply a 'Pendant la dictée.'; sleep 1
check_not "nothing is read while dictating" "$(said)" "Pendant"
hf --done >/dev/null; wait_quiet 1.5
check "« Stop » lets the queue go on" "$(said)" "Pendant la dict"

reset; printf '{"session_id":"b","transcript_path":"%s/b.jsonl","tool_input":{"questions":["On y va ?"]}}' "$WORK" | hf --question >/dev/null
check "a question is announced with its session" "$(said)" "Session Projet Beta.*Une question.*On y va"
reply a 'Après la question.'; sleep 1
check_not "the queue waits for the answer" "$(said)" "s la question"
hf --done >/dev/null; wait_quiet 1.5

reset; printf '{"type":"user","turnOrigin":"sdk","message":{"content":"Background (from the session that started this one): x"}}\n' >> "$WORK/b.jsonl"
reply b 'Tâche déléguée.'; sleep 1
check_not "a turn delegated by another session is not read" "$(said)" "che d.*l.*gu"
printf '{"type":"user","turnOrigin":"human","message":{"content":"Pose-moi une question"}}\n' >> "$WORK/b.jsonl"
reply b 'Réponse directe.'; wait_quiet 1.5
check "a turn asked by the user is read" "$(said)" "ponse directe."

reset; printf '{"session_id":"a","transcript_path":"%s/a.jsonl"}' "$WORK" | hf --notify; wait_quiet 1.5
check "the waiting notice names its session" "$(said)" "Session Projet Alpha.*Claude attend ta r"

reset; hf --off >/dev/null; reply a 'Muet.'; rules=$(hf --session-rules); sleep 1
check "switching off is said" "$(said)" "Mode vocal d.*sactiv"
check_not "nothing is read while off" "$(said)" "Muet"
check "no rules are injected while off" "[$rules]" "\[\]"
hf --toggle >/dev/null
check "switching back on is said" "$(said)" "Mode vocal activ"

printf '{"say_path": "%s", "language": "en", "validation_word": "banana"}\n' "$ROOT/tests/fake-say.sh" > "$HANDFREE_CONFIG"
rules=$(hf --session-rules)
if grep -q '"spokenly"' "$HOME/.claude.json" 2>/dev/null; then
  check "rules follow the language and validation word" "$rules" 'saying "banana"'
fi
set_transport() { printf '{"say_path": "%s", "language": "fr", "question_transport": {"local": "%s", "cloud": "%s"}}\n' "$ROOT/tests/fake-say.sh" "$1" "$2" > "$HANDFREE_CONFIG"; }
set_transport none bridge
check "transport none: no voice rules" "[$(hf --session-rules)]" "\[\]"
if grep -q '"spokenly"' "$HOME/.claude.json" 2>/dev/null; then
  set_transport bridge bridge
  check "local bridge with Spokenly up: rules" "$(HANDFREE_SPOKENLY_UP=1 hf --session-rules)" "Mode vocal actif"
  check "local bridge with Spokenly down: no rules" "[$(HANDFREE_SPOKENLY_UP=0 hf --session-rules)]" "\[\]"
fi
set_transport mcp none
check "cloud transport none: no rules for a cloud session" "[$(HANDFREE_CONTEXT=cloud hf --session-rules)]" "\[\]"
set_transport mcp bridge
check "cloud bridge with Spokenly up: rules for a cloud session" "$(HANDFREE_CONTEXT=cloud HANDFREE_SPOKENLY_UP=1 hf --session-rules)" "Mode vocal actif"
configure

if grep -q '"spokenly"' "$HOME/.claude.json" 2>/dev/null; then
  reset; out=$(printf '{"session_id":"a","transcript_path":"%s/a.jsonl","last_assistant_message":"Fait.\\n\\nJe le pousse ?"}' "$WORK" | hf); sleep 1
  check "a reply ending on a written question is sent back" "$out" '"decision":"block"'
  check_not "and is not read meanwhile" "$(said)" "pousse"
  out=$(printf '{"session_id":"a","stop_hook_active":true,"transcript_path":"%s/a.jsonl","last_assistant_message":"Je le pousse ?"}' "$WORK" | hf)
  check_not "a reply already sent back once is not sent back again" "$out" "block"
  wait_quiet 1.5
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__ccd_turn__wrap_up","input":{"recap":"x","ask":"On publie ?"}}]}}\n' >> "$WORK/a.jsonl"
  out=$(printf '{"session_id":"a","transcript_path":"%s/a.jsonl","last_assistant_message":"Fait."}' "$WORK" | hf)
  check "a question in the app box is sent back" "$out" '"decision":"block"'
  printf '{"type":"user","turnOrigin":"human","message":{"content":"suite"}}\n' >> "$WORK/a.jsonl"
  out=$(printf '{"session_id":"a","transcript_path":"%s/a.jsonl","last_assistant_message":"Pourquoi ? Parce que.\\n\\nFait."}' "$WORK" | hf)
  check_not "a question earlier in the reply is not sent back" "$out" "block"
  wait_quiet 1.5
fi

reset; out=$(HANDFREE_IDLE_SECONDS=3600 sh -c "printf '{\"session_id\":\"b\",\"transcript_path\":\"%s/b.jsonl\",\"tool_input\":{\"questions\":[\"Absent ?\"]}}' '$WORK' | osascript -l JavaScript '$SCRIPT' --question")
check "away from the Mac, the Spokenly question is refused" "$out" '"permissionDecision":"deny"'
check_not "and nothing is said" "$(said)" "Absent"
if grep -q '"spokenly"' "$HOME/.claude.json" 2>/dev/null; then
  out=$(HANDFREE_IDLE_SECONDS=3600 sh -c "printf '{\"session_id\":\"a\",\"transcript_path\":\"%s/a.jsonl\",\"last_assistant_message\":\"On publie ?\"}' '$WORK' | osascript -l JavaScript '$SCRIPT'")
  check_not "away from the Mac, a written question is allowed" "$out" "block"
  wait_quiet 1.5
fi

printf '{"version": 0, "queue": [{"bogus": true}]}' > "$HANDFREE_STATE_DIR/state.json"
reset; reply a 'Après migration.'; wait_quiet 1.5
check "a state from another version is reset" "$(said)" "s migration."

hf --off >/dev/null 2>&1
rm -rf "$WORK"
[ "$FAILS" -eq 0 ] && echo "ALL PASSED" || { echo "$FAILS FAILED"; exit 1; }
