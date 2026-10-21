#!/bin/sh
# Bridge tests: a pretend cloud session sends hooks to the bridge service running here, with a test token.
# A fake dictation app answers slowly, to check the stream stays open through a long dictation.
# Usage: tests/bridge.sh   (silent, does not touch your real state, config or dictation app)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM
# Ports free right now: the other suite, or the user's own services, may run at the same time.
free_port() { /usr/bin/python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
PORT=$(free_port)
FAKE_DICTATION_PORT=$(free_port)
TOKEN=test-token
export HANDFREE_STATE_DIR="$WORK/state" HANDFREE_CONFIG="$WORK/config.json" HANDFREE_SAY_LOG="$WORK/said.log"
export HANDFREE_BRIDGE_LOG="$WORK/bridge.log" HANDFREE_NO_KEYS=1 HANDFREE_APP_SECRET_FILE="$WORK/app-secret"
# Claude's settings are a fixture declaring the dictation tool, never this Mac's own.
export HANDFREE_CLAUDE_JSON="$WORK/claude.json" HANDFREE_MEDIA_KEY_LOG="$WORK/keys.log" HANDFREE_NOW_PLAYING=unknown HANDFREE_MEDIA_CONTROL=
# The stable copy and the services stay the test's own: the real listener and bridge are never touched.
export HANDFREE_SUPPORT_DIR="$WORK/support" HANDFREE_LAUNCH_AGENTS_DIR="$WORK/agents" HANDFREE_RESTART_LOG="$WORK/restarted.log"
export HANDFREE_BRIDGE_PORT=$PORT HANDFREE_IDLE_SECONDS=0 HANDFREE_AUDIO_PLAYING=0 HANDFREE_DICTATION_URL="http://127.0.0.1:$FAKE_DICTATION_PORT"
chmod +x "$ROOT/tests/fake-say.sh"
printf '{"say_path": "%s", "language": "en", "announce_session": "always", "pause_between_lines_seconds": 0.1, "silence_around_title_ms": 1, "bridge_token": "%s"}\n' "$ROOT/tests/fake-say.sh" "$TOKEN" > "$HANDFREE_CONFIG"
printf '{"mcpServers": {"handfree": {"type": "stdio", "command": "mcp-relay.sh"}}}\n' > "$HANDFREE_CLAUDE_JSON"
FAILS=0

check() {
  if printf '%s' "$2" | grep -q -- "$3"; then echo "ok   $1"; else echo "FAIL $1"; echo "     expected: $3"; echo "     got: $(printf '%s' "$2" | tr '\n' '|')"; FAILS=$((FAILS + 1)); fi
}
check_not() {
  if printf '%s' "$2" | grep -q -- "$3"; then echo "FAIL $1"; echo "     unexpected: $3"; FAILS=$((FAILS + 1)); else echo "ok   $1"; fi
}
said() { cat "$HANDFREE_SAY_LOG" 2>/dev/null; }

# Fake dictation app: answers tools/call after 20 s, the rest at once. It writes down each method it receives.
/usr/bin/python3 - "$FAKE_DICTATION_PORT" "$WORK/app-methods.log" <<'EOF' &
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        msg = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(sys.argv[2], "a") as f:
            f.write(str(msg.get("method")) + "\n")
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
/usr/bin/python3 "$ROOT/bin/bridge-server.py" 2>>"$WORK/bridge.log" &
BRIDGE_PID=$!
sleep 1

cloud() {  # a hook as a cloud session would run it: on Linux, hook.sh hands it to cloud-hook.py
  HANDFREE_BRIDGE_URL="http://127.0.0.1:$PORT" HANDFREE_BRIDGE_TOKEN="$TOKEN" HANDFREE_HOOK_LOG="$WORK/hook.log" python3 "$ROOT/bin/cloud-hook.py" "$@"
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
check "each cloud hook leaves a line in its log" "$(cat "$WORK/hook.log")" "question: HTTP 200"
printf '{"session_id":"c"}' | cloud --answered >/dev/null
printf '{"session_id":"c","transcript_path":"%s/cloud.jsonl","last_assistant_message":"Answered."}' "$WORK" | cloud >/dev/null; sleep 1.5
check "a cloud answer frees the queue through the bridge" "$(said)" "Answered."

out=$(printf '{"session_id":"c","transcript_path":"%s/cloud.jsonl","last_assistant_message":"Shall I push?"}' "$WORK" | cloud)
check "a cloud turn ending on a written question is sent back" "$out" '"decision":"block"'
printf '{"session_id":"c","prompt":"Never mind."}' | cloud --prompt-sent >/dev/null

rules=$(printf '{"session_id":"c"}' | cloud --session-rules)
check "a cloud session receives the voice rules" "$rules" "Voice mode is on"

rules=$(printf '{"session_id":"c"}' | HANDFREE_OVERRIDES='{"validation_word":"banana","say_path":"/bin/evil"}' cloud --session-rules)
check "a cloud environment can override safe settings" "$rules" 'saying "banana"'
: > "$HANDFREE_SAY_LOG"
printf '{"session_id":"c","transcript_path":"%s/cloud.jsonl","last_assistant_message":"Override."}' "$WORK" | HANDFREE_OVERRIDES='{"say_path":"/usr/bin/true"}' cloud >/dev/null; sleep 1.5
check "but not the program run on the Mac" "$(said)" "Override."

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/hook" -d '{}')
check "a request without the token is refused" "$code" "401"
for path in hook mcp; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/$path" -H "Authorization: Bearer wrong-token" -d '{}')
  check "a wrong token is refused on /$path" "$code" "^401$"
done
for command in --listen --off --read --dictate-behind --permission; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/hook" -H "Authorization: Bearer $TOKEN" -d "{\"command\":\"$command\"}")
  check "only hook commands are accepted: $command refused" "$code" "^400$"
done

out=$(curl -s -X POST "http://127.0.0.1:$PORT/mcp" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
check "MCP calls are relayed to the dictation app" "$out" "ask_user_dictation"

out=$(curl -s -N -X POST "http://127.0.0.1:$PORT/mcp" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"ask_user_dictation","arguments":{"questions":["x"]}}}')
check "a long dictation keeps the stream alive" "$out" ": keep-alive"
check "and ends with the dictation app's answer" "$out" '"id": 7'

# A cloud session holds the token: it may ask questions, never press keys or paste text on this Mac.
mcp() { curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/mcp" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$1"; }
check "the bridge refuses keys/press" "$(mcp '{"jsonrpc":"2.0","id":2,"method":"keys/press","params":{"key":"return"}}')" "^403$"
check "the bridge refuses dictation/insert" "$(mcp '{"jsonrpc":"2.0","id":3,"method":"dictation/insert","params":{"send":true}}')" "^403$"
check "the bridge refuses another tool" "$(mcp '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"other"}}')" "^403$"
check "a tool name that is not a string is refused, not a crash" "$(mcp '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":["ask_user_dictation"]}}')" "^403$"
check_not "none of them reaches the app" "$(cat "$WORK/app-methods.log")" "keys/press\|dictation/insert"
check "an MCP notification is relayed" "$(mcp '{"jsonrpc":"2.0","method":"notifications/initialized"}')" "^20[02]$"

# Malformed requests are answered, and the bridge keeps serving.
check "a JSON body that is not an object is refused" "$(mcp '[1, 2]')" "^400$"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/hook" -H "Authorization: Bearer $TOKEN" -d '"x"')
check "so on /hook" "$code" "^400$"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/hook" -H "Authorization: Bearer $TOKEN" -d '{"command":["--notify"]}')
check "a hook command that is not a string is refused" "$code" "^400$"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/ping" -H "$(printf 'Authorization: Bearer t\303\251st')")
check "a non-ASCII Authorization is refused" "$code" "^400$"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/ping" -H "Authorization: Bearer $TOKEN" -H 'Content-Length: -5')
check "a negative Content-Length is refused" "$code" "^413$"
code=$(curl -s -w ' %{http_code}' -X POST "http://127.0.0.1:$PORT/ping" -H "Authorization: Bearer $TOKEN")
check "the bridge still serves after them" "$code" "^handfree-bridge 200$"
kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null
check "the app not running: 502" "$(mcp '{"jsonrpc":"2.0","id":5,"method":"tools/list"}')" "^502$"

code=$(curl -s -w ' %{http_code}' -X POST "http://127.0.0.1:$PORT/ping" -H "Authorization: Bearer $TOKEN")
check "the bridge answers its check with its name" "$code" "^handfree-bridge 200$"

# The end-to-end check, run against this bridge as if it were the public address.
config() { printf '{"bridge_token": "%s", "bridge_url": "%s"}\n' "$1" "$2" > "$WORK/check.json"; }
verdict() { HANDFREE_CONFIG="$WORK/check.json" sh "$ROOT/bin/install-bridge.sh" --check >/dev/null 2>&1; echo $?; }
config "$TOKEN" "http://127.0.0.1:$PORT/"
check "check: the address reaching this bridge" "$(verdict)" "^0$"
config "$TOKEN" ""
check "check: no public address yet" "$(verdict)" "^2$"
config "$TOKEN" "http://127.0.0.1:$(free_port)"
check "check: nothing at the address" "$(verdict)" "^3$"
config "old-token" "http://127.0.0.1:$PORT"
check "check: a bridge refusing the token" "$(verdict)" "^5$"
OTHER_PORT=$(free_port)
(cd "$WORK" && exec /usr/bin/python3 -m http.server "$OTHER_PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
OTHER_PID=$!
sleep 0.5
config "$TOKEN" "http://127.0.0.1:$OTHER_PORT"
check "check: another server at the address" "$(verdict)" "^6$"
kill "$OTHER_PID" 2>/dev/null

# Edge key: a recorder stands in for the tunnel's edge, and writes down the headers of one request.
RECORDER_PORT=$(free_port)
record_one() {
  rm -f "$WORK/headers.txt"
  /usr/bin/python3 -c '
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        open(sys.argv[2], "w").write(str(self.headers))
        self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers()
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).handle_request()
' "$RECORDER_PORT" "$WORK/headers.txt" &
  RECORDER_PID=$!
  sleep 0.5
}
record_one
printf '{"session_id":"c"}' | HANDFREE_BRIDGE_URL="http://127.0.0.1:$RECORDER_PORT" HANDFREE_BRIDGE_TOKEN=x HANDFREE_BRIDGE_EDGE_KEY=edge-secret python3 "$ROOT/bin/cloud-hook.py" --notify
wait "$RECORDER_PID" 2>/dev/null
check "the edge key reaches the tunnel's edge" "$(cat "$WORK/headers.txt" 2>/dev/null)" "X-Handfree-Key: edge-secret"

# The check gives curl its keys on its standard input: they still arrive, and never show in its arguments.
record_one
printf '{"bridge_token": "check-token", "bridge_edge_key": "check-edge", "bridge_url": "http://127.0.0.1:%s"}\n' "$RECORDER_PORT" > "$WORK/check.json"
HANDFREE_CONFIG="$WORK/check.json" sh "$ROOT/bin/install-bridge.sh" --check >/dev/null 2>&1
wait "$RECORDER_PID" 2>/dev/null
check "check: the token reaches the address" "$(cat "$WORK/headers.txt" 2>/dev/null)" "Authorization: Bearer check-token"
check "check: so does the edge key" "$(cat "$WORK/headers.txt" 2>/dev/null)" "X-Handfree-Key: check-edge"
check_not "check: no key on curl's command line" "$(grep -h 'curl' "$ROOT/bin/install-bridge.sh" "$ROOT/bin/speak-openai.sh")" '\$token\|\$key\|\$KEY'

# Logs never fill the disk: past 200 KB, the bridge's and the cloud hook's keep their last lines.
small() { [ "$(wc -c < "$1")" -lt 200000 ] && echo trimmed || echo "$(wc -c < "$1") bytes"; }
yes 'an old line of the log' | head -20000 >> "$WORK/bridge.log"
curl -s -o /dev/null -X POST "http://127.0.0.1:$PORT/ping" -H "Authorization: Bearer $TOKEN"
check "the bridge's log is trimmed" "$(small "$WORK/bridge.log")" "^trimmed$"
yes 'an old line of the log' | head -20000 >> "$WORK/hook.log"
printf '{"session_id":"c"}' | cloud --prompt-sent >/dev/null
check "the cloud hook's log is trimmed" "$(small "$WORK/hook.log")" "^trimmed$"
check "and keeps its last line" "$(tail -1 "$WORK/hook.log")" "prompt-sent: HTTP 200"

kill "$BRIDGE_PID" 2>/dev/null; wait 2>/dev/null

# Without a token, the bridge refuses to start: anyone reaching the tunnel could use it.
printf '{"say_path": "%s"}\n' "$ROOT/tests/fake-say.sh" > "$WORK/no-token.json"
HANDFREE_CONFIG="$WORK/no-token.json" HANDFREE_BRIDGE_PORT=$(free_port) /usr/bin/python3 "$ROOT/bin/bridge-server.py" 2>"$WORK/no-token.log" &
NO_TOKEN_PID=$!
sleep 1
check "a bridge with no token refuses to start" "$(kill -0 "$NO_TOKEN_PID" 2>/dev/null && echo running || echo stopped)" "^stopped$"
check "and says why" "$(cat "$WORK/no-token.log")" "no bridge_token"
kill "$NO_TOKEN_PID" 2>/dev/null

# Each hook's time limits nest: the bridge under the cloud hook's request, the request under the hook's timeout.
nested=$(/usr/bin/python3 -I - "$ROOT" <<'PY'
import json, re, sys
root = sys.argv[1]
def table(path, name, default):
    text = open(f"{root}/bin/{path}").read()
    per = dict(re.findall(r'"(--[a-z-]+)": (\d+)', re.search(name + r" = \{([^}]*)\}", text).group(1)))
    return {k: int(v) for k, v in per.items()}, int(re.search(default + r" = (\d+)", text).group(1))
bridge, bridge_default = table("bridge-server.py", "HOOK_TIMEOUT_SECONDS", "DEFAULT_HOOK_TIMEOUT_SECONDS")
cloud, cloud_default = table("cloud-hook.py", "TIMEOUT_SECONDS", "DEFAULT_TIMEOUT_SECONDS")
hooks = json.load(open(f"{root}/hooks/hooks.json"))["hooks"]
timeouts = {}
for groups in hooks.values():
    for group in groups:
        for hook in group["hooks"]:
            command = hook["command"].rsplit(" ", 1)[-1]
            timeouts[command if command.startswith("--") else ""] = hook.get("timeout", 600)
bad = [c for c, t in timeouts.items()
       if not bridge.get(c, bridge_default) < cloud.get(c, cloud_default) < t and c != "--permission"]
print("nested" if not bad else "not nested: " + ", ".join(bad))
PY
)
check "each hook's limits nest: bridge, then the cloud hook's request, then the hook" "$nested" "^nested$"
osascript -l JavaScript "$ROOT/bin/handfree.js" --off >/dev/null 2>&1
[ "$FAILS" -eq 0 ] && echo "ALL PASSED" || { echo "$FAILS FAILED"; exit 1; }
