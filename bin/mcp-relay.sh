#!/bin/sh
# The `handfree` MCP server Claude starts for a local session: each JSON-RPC line it writes goes to the Handfree Code
# app on this Mac, each answer comes back as a line. A question waits as long as the user takes to answer.
URL=${HANDFREE_DICTATION_URL:-http://localhost:51290}
# Answers come back from requests running side by side: one at a time on the output, never mixed in one line.
LOCK="${TMPDIR:-/tmp}/handfree-relay.$$.lock"
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
answer() {
  until mkdir "$LOCK" 2>/dev/null; do sleep 0.05; done
  printf '%s\n' "$1"
  rmdir "$LOCK"
}
while IFS= read -r line; do
  [ -z "$line" ] && continue
  # Each request on its own: a question still waiting (one Claude gave up on included) holds up nothing else.
  {
    response=$(printf '%s' "$line" | curl -s --max-time 900 -X POST "$URL" -H 'Content-Type: application/json' --data-binary @-)
    if [ -n "$response" ]; then
      answer "$response"
    else
      # No answer: the app is not running, or failed. A request (it has an id) gets an error at once rather than
      # Claude waiting for its timeout; a notification needs nothing.
      error=$(printf '%s' "$line" | /usr/bin/python3 -c '
import json, sys
try:
    message = json.load(sys.stdin)
except ValueError:
    sys.exit()
if isinstance(message, dict) and message.get("id") is not None:
    print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32000, "message": "The Handfree Code app does not answer: is it running?"}}))
' 2>/dev/null)
      [ -z "$error" ] || answer "$error"
    fi
  } &
done
wait
