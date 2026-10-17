#!/bin/sh
# Bridge tests: a pretend cloud session sends hooks to the bridge service running here, with a test token.
# A fake Spokenly answers slowly, to check the stream stays open through a long dictation.
# Usage: tests/bridge.sh   (silent, does not touch your real state, config or Spokenly)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
PORT=8799
FAKE_SPOKENLY_PORT=8798
TOKEN=test-token
export HANDFREE_STATE_DIR="$WORK/state" HANDFREE_CONFIG="$WORK/config.json" HANDFREE_SAY_LOG="$WORK/said.log"
export HANDFREE_BRIDGE_PORT=$PORT HANDFREE_IDLE_SECONDS=0 HANDFREE_AUDIO_PLAYING=0 HANDFREE_SPOKENLY_URL="http://127.0.0.1:$FAKE_SPOKENLY_PORT"
chmod +x "$ROOT/tests/fake-say.sh"
printf '{"say_path": "%s", "language": "en", "announce_session": "always", "pause_between_lines_seconds": 0.1, "silence_around_title_ms": 1, "bridge_token": "%s"}\n' "$ROOT/tests/fake-say.sh" "$TOKEN" > "$HANDFREE_CONFIG"
FAILS=0

check() {
  if printf '%s' "$2" | grep -q -- "$3"; then echo "ok   $1"; else echo "FAIL $1"; echo "     expected: $3"; echo "     got: $(printf '%s' "$2" | tr '\n' '|')"; FAILS=$((FAILS + 1)); fi
}
check_not() {
  if printf '%s' "$2" | grep -q -- "$3"; then echo "FAIL $1"; echo "     unexpected: $3"; FAILS=$((FAILS + 1)); else echo "ok   $1"; fi
}
said() { cat "$HANDFREE_SAY_LOG" 2>/dev/null; }

# Fake Spokenly: answers tools/call after 20 s, the rest at once.
/usr/bin/python3 - "$FAKE_SPOKENLY_PORT" <<'EOF' &
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        msg = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if msg.get("method") == "tools/call":
            time.sleep(20)
            out = {"jsonrpc": "2.0", "id": msg["id"], "result": {"content": [{"type": "text", "text": "Q: x\nA: yes"}]}}
        else:
            out = {"jsonrpc": "2.0", "id": msg.get("id"), "result": {"tools": [{"name": "ask_user_dictation"}]}}
        body = json.dumps(out).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
FAKE_PID=$!
/usr/bin/python3 "$ROOT/bin/bridge-server.py" 2>"$WORK/bridge.log" &
BRIDGE_PID=$!
sleep 1

cloud() {  # a hook as a cloud session would run it: on Linux, hook.sh hands it to cloud-hook.py
  HANDFREE_BRIDGE_URL="http://127.0.0.1:$PORT" HANDFREE_BRIDGE_TOKEN="$TOKEN" python3 "$ROOT/bin/cloud-hook.py" "$@"
}
printf '{"type":"custom-title","customTitle":"Cloud work"}\n' > "$WORK/cloud.jsonl"
printf '{"type":"user","turnOrigin":"human","message":{"content":"go ahead"}}\n' >> "$WORK/cloud.jsonl"

printf '{"session_id":"c","transcript_path":"%s/cloud.jsonl","last_assistant_message":"Done from the cloud.\\n\\nMore."}' "$WORK" | cloud >/dev/null
sleep 1.5
check "a cloud reply is read on the Mac, with its session's title" "$(said)" "Session Cloud work.*Done from the cloud"
check_not "only its first paragraph" "$(said)" "More."

: > "$HANDFREE_SAY_LOG"
printf '{"session_id":"c","transcript_path":"%s/cloud.jsonl","tool_input":{"questions":["Publish?"]}}' "$WORK" | cloud --question >/dev/null
check "a cloud question is read on the Mac" "$(said)" "A question.*Publish"
osascript -l JavaScript "$ROOT/bin/handfree.js" --done >/dev/null

out=$(printf '{"session_id":"c","transcript_path":"%s/cloud.jsonl","last_assistant_message":"Shall I push?"}' "$WORK" | cloud)
if grep -q '"spokenly"' "$HOME/.claude.json" 2>/dev/null; then
  check "a cloud turn ending on a written question is sent back" "$out" '"decision":"block"'
fi

rules=$(printf '{"session_id":"c"}' | cloud --session-rules)
if grep -q '"spokenly"' "$HOME/.claude.json" 2>/dev/null; then
  check "a cloud session receives the voice rules" "$rules" "Voice mode is on"
fi

rules=$(printf '{"session_id":"c"}' | HANDFREE_OVERRIDES='{"validation_word":"banana","say_path":"/bin/evil"}' cloud --session-rules)
check "a cloud environment can override safe settings" "$rules" 'saying "banana"'
: > "$HANDFREE_SAY_LOG"
printf '{"session_id":"c","transcript_path":"%s/cloud.jsonl","last_assistant_message":"Override."}' "$WORK" | HANDFREE_OVERRIDES='{"say_path":"/usr/bin/true"}' cloud >/dev/null; sleep 1.5
check "but not the program run on the Mac" "$(said)" "Override."

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/hook" -d '{}')
check "a request without the token is refused" "$code" "401"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/hook" -H "Authorization: Bearer $TOKEN" -d '{"command":"--listen"}')
check "only hook commands are accepted" "$code" "400"

out=$(curl -s -X POST "http://127.0.0.1:$PORT/mcp" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
check "MCP calls are relayed to Spokenly" "$out" "ask_user_dictation"

out=$(curl -s -N -X POST "http://127.0.0.1:$PORT/mcp" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"ask_user_dictation","arguments":{"questions":["x"]}}}')
check "a long dictation keeps the stream alive" "$out" ": keep-alive"
check "and ends with Spokenly's answer" "$out" '"id": 7'

# Edge key: a recorder stands in for the tunnel's edge.
/usr/bin/python3 -c '
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        open(sys.argv[2], "w").write(str(self.headers))
        self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers()
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).handle_request()
' 8797 "$WORK/headers.txt" &
RECORDER_PID=$!
sleep 0.5
printf '{"session_id":"c"}' | HANDFREE_BRIDGE_URL=http://127.0.0.1:8797 HANDFREE_BRIDGE_TOKEN=x HANDFREE_BRIDGE_EDGE_KEY=edge-secret python3 "$ROOT/bin/cloud-hook.py" --notify
wait "$RECORDER_PID" 2>/dev/null
check "the edge key reaches the tunnel's edge" "$(cat "$WORK/headers.txt" 2>/dev/null)" "X-Handfree-Key: edge-secret"

kill "$BRIDGE_PID" "$FAKE_PID" 2>/dev/null; wait 2>/dev/null
osascript -l JavaScript "$ROOT/bin/handfree.js" --off >/dev/null 2>&1
rm -rf "$WORK"
[ "$FAILS" -eq 0 ] && echo "ALL PASSED" || { echo "$FAILS FAILED"; exit 1; }
