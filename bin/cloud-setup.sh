#!/bin/bash
# Setup script for a cloud environment: installs the plugin and declares Spokenly through the bridge.
# The bridge is set by HANDFREE_BRIDGE_URL and HANDFREE_BRIDGE_TOKEN, plus HANDFREE_BRIDGE_EDGE_KEY sent as
# X-Handfree-Key for the tunnel's edge to check. Never fails the environment.
REPO=${HANDFREE_REPO:-https://github.com/fourthscale/handfree-code.git}

claude plugin marketplace add "$REPO" || true
claude plugin install handfree-code@handfree-code || true

# An environment runs this once and reuses the result: the declaration names the variables, which Claude Code
# reads at each connection, so it works whether they were set before or after this ran, and follows their changes.
# Without them, the server only fails to connect and the hooks stay silent.
claude mcp remove --scope user spokenly >/dev/null 2>&1 || true
claude mcp add --scope user --transport http spokenly '${HANDFREE_BRIDGE_URL}/mcp' \
  --header 'Authorization: Bearer ${HANDFREE_BRIDGE_TOKEN}' \
  --header 'X-Handfree-Key: ${HANDFREE_BRIDGE_EDGE_KEY:-}' || true

# Spokenly waits as long as you take to answer; Claude Code stops the call at this timeout (2 minutes).
python3 - <<'PY' || true
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
