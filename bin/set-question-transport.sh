#!/bin/sh
# Chooses how local sessions reach the dictation, and declares the `handfree` MCP server accordingly (user scope).
#   sh bin/set-question-transport.sh mcp      the Handfree Code app on this Mac, through mcp-relay.sh
#   sh bin/set-question-transport.sh bridge   through the tunnel (needs bridge_url and bridge_token in the config)
#   sh bin/set-question-transport.sh none     questions stay written
#   sh bin/set-question-transport.sh keep     the one already chosen (mcp when none was), as the install does
# Cloud sessions are configured in their environment instead (see README).
set -eu
TRANSPORT=${1:-}
CONFIG=${HANDFREE_CONFIG:-$HOME/.config/handfree-code.json}
[ -n "${HANDFREE_CONFIG:-}" ] || [ -e "$CONFIG" ] || [ ! -e "$HOME/.config/claude-speak.json" ] || CONFIG="$HOME/.config/claude-speak.json" # before 0.3.2
SUPPORT=${HANDFREE_SUPPORT_DIR:-$HOME/Library/Application Support/handfree-code}
RELAY="$SUPPORT/mcp-relay.sh"
HERE=$(cd "$(dirname "$0")" && pwd)
case "$TRANSPORT" in mcp|bridge|none|keep) ;; *) echo "usage: $0 mcp|bridge|none|keep" >&2; exit 2 ;; esac

setting() { /usr/bin/python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]) or '')" "$CONFIG" "$1" 2>/dev/null; }
if [ "$TRANSPORT" = keep ]; then
  TRANSPORT=$(/usr/bin/python3 -c "
import json, sys
try:
    chosen = (json.load(open(sys.argv[1])).get('question_transport') or {}).get('local')
except (OSError, ValueError, AttributeError):
    chosen = None
print(chosen if chosen in ('mcp', 'bridge', 'none') else 'mcp')" "$CONFIG")
fi

claude mcp remove --scope user handfree >/dev/null 2>&1 || true
claude mcp remove --scope user spokenly >/dev/null 2>&1 || true # the server's name in versions before 0.3
# The server's whole declaration, its timeout included, goes through `claude mcp add-json`: Claude Code writes its own
# file. The dictation waits as long as you take to answer; Claude Code stops the call at this timeout (2 minutes).
# The bridge's keys end up in Claude's settings either way; `claude` takes them on its command line, only an instant.
case "$TRANSPORT" in
  mcp)
    # A copy that survives plugin updates (the plugin's own list), where the sessions' hooks keep theirs.
    [ "$HERE" = "$SUPPORT" ] || osascript -l JavaScript "$HERE/handfree.js" --refresh-stable-copy >/dev/null
    SERVER=$(/usr/bin/python3 -c 'import json, sys; print(json.dumps({"type": "stdio", "command": "/bin/sh", "args": [sys.argv[1]], "timeout": 120000}))' "$RELAY")
    claude mcp add-json --scope user handfree "$SERVER" # through sh: the copy may lose its execute bit
    ;;
  bridge)
    URL=$(setting bridge_url); TOKEN=$(setting bridge_token)
    [ -n "$URL" ] && [ -n "$TOKEN" ] || { echo "Set bridge_url and bridge_token in $CONFIG first." >&2; exit 1; }
    # bridge_edge_key travels as X-Handfree-Key, for the tunnel's edge to check before anything reaches the Mac.
    SERVER=$(/usr/bin/python3 -c '
import json, sys
url, token, edge_key = sys.argv[1:4]
headers = {"Authorization": "Bearer " + token}
if edge_key:
    headers["X-Handfree-Key"] = edge_key
print(json.dumps({"type": "http", "url": url.rstrip("/") + "/mcp", "headers": headers, "timeout": 120000}))' "$URL" "$TOKEN" "$(setting bridge_edge_key)")
    claude mcp add-json --scope user handfree "$SERVER"
    ;;
esac

/usr/bin/python3 - "$CONFIG" "$TRANSPORT" <<'EOF'
import json, os, sys
path, transport = sys.argv[1], sys.argv[2]
try:
    config = json.load(open(path, encoding="utf-8"))
except (OSError, ValueError):
    config = {}
config.setdefault("question_transport", {})["local"] = transport
with open(path, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
os.chmod(path, 0o600)
EOF
echo "Local sessions now reach the dictation through: $TRANSPORT. Open a new session for it to apply."
