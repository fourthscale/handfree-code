#!/bin/bash
# Setup script for a cloud environment: installs the plugin and declares the dictation tool through the bridge.
# The bridge is set by HANDFREE_BRIDGE_URL and HANDFREE_BRIDGE_TOKEN, plus HANDFREE_BRIDGE_EDGE_KEY sent as
# X-Handfree-Key for the tunnel's edge to check. Never fails the environment.
REPO=${HANDFREE_REPO:-https://github.com/fourthscale/handfree-code.git}

claude plugin marketplace add "$REPO" || true
claude plugin install handfree-code@handfree-code || true

# An environment runs this once and reuses the result: the declaration names the variables, which Claude Code
# reads at each connection, so it works whether they were set before or after this ran, and follows their changes.
# Without them, the server only fails to connect and the hooks stay silent.
# The whole declaration, its timeout included, goes through `claude mcp add-json`: Claude Code writes its own file.
# The dictation waits as long as you take to answer; Claude Code stops the call at this timeout (2 minutes).
claude mcp remove --scope user handfree >/dev/null 2>&1 || true
claude mcp add-json --scope user handfree '{"type": "http", "url": "${HANDFREE_BRIDGE_URL}/mcp", "timeout": 120000,
  "headers": {"Authorization": "Bearer ${HANDFREE_BRIDGE_TOKEN}", "X-Handfree-Key": "${HANDFREE_BRIDGE_EDGE_KEY:-}"}}' || true
