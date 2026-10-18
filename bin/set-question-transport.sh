#!/bin/sh
# Chooses how local sessions reach Spokenly, and declares the `spokenly` MCP server accordingly (user scope).
#   sh bin/set-question-transport.sh mcp      Spokenly's own local relay
#   sh bin/set-question-transport.sh bridge   through the tunnel (needs bridge_url and bridge_token in the config)
#   sh bin/set-question-transport.sh none     questions stay written
# Cloud sessions are configured in their environment instead (see README).
set -eu
TRANSPORT=${1:-}
CONFIG="$HOME/.config/claude-speak.json"
SPOKENLY_RELAY="$HOME/Library/Application Support/Spokenly/mcp-bridge.sh"
case "$TRANSPORT" in mcp|bridge|none) ;; *) echo "usage: $0 mcp|bridge|none" >&2; exit 2 ;; esac

setting() { /usr/bin/python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]) or '')" "$CONFIG" "$1" 2>/dev/null; }

claude mcp remove --scope user spokenly >/dev/null 2>&1 || true
case "$TRANSPORT" in
  mcp)
    [ -x "$SPOKENLY_RELAY" ] || { echo "Spokenly's relay is missing: $SPOKENLY_RELAY" >&2; exit 1; }
    claude mcp add --scope user spokenly "$SPOKENLY_RELAY"
    ;;
  bridge)
    URL=$(setting bridge_url); TOKEN=$(setting bridge_token)
    [ -n "$URL" ] && [ -n "$TOKEN" ] || { echo "Set bridge_url and bridge_token in $CONFIG first." >&2; exit 1; }
    # bridge_edge_key travels as X-Handfree-Key, for the tunnel's edge to check before anything reaches the Mac.
    EDGE_KEY=$(setting bridge_edge_key)
    set -- --header "Authorization: Bearer $TOKEN"
    [ -n "$EDGE_KEY" ] && set -- "$@" --header "X-Handfree-Key: $EDGE_KEY"
    claude mcp add --scope user --transport http spokenly "${URL%/}/mcp" "$@"
    ;;
esac

# Spokenly waits as long as you take to answer; Claude Code stops the call at this timeout (2 minutes).
[ "$TRANSPORT" = none ] || /usr/bin/python3 - <<'PY' || true
import json, os
path = os.path.expanduser("~/.claude.json")
try:
    config = json.load(open(path, encoding="utf-8"))
except (OSError, ValueError):
    config = {}
server = config.get("mcpServers", {}).get("spokenly")
if server is not None:
    server["timeout"] = 120000
    with open(path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
PY

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
echo "Local sessions now reach Spokenly through: $TRANSPORT. Open a new session for it to apply."
