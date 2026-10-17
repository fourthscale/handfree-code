#!/bin/bash
# Setup script for a cloud environment: installs the plugin and declares Spokenly through the bridge.
# Needs HANDFREE_BRIDGE_URL and HANDFREE_BRIDGE_TOKEN; HANDFREE_BRIDGE_EDGE_KEY is sent as X-Handfree-Key for the
# tunnel's edge to check. Never fails the environment: a missing piece only leaves the session silent.
REPO=${HANDFREE_REPO:-https://github.com/fourthscale/handfree-code.git}

claude plugin marketplace add "$REPO" || true
claude plugin install handfree-code@handfree-code || true

if [ -z "${HANDFREE_BRIDGE_URL:-}" ] || [ -z "${HANDFREE_BRIDGE_TOKEN:-}" ]; then
  echo "handfree-code: no bridge configured, cloud sessions stay silent." >&2
  exit 0
fi

# The headers name the variables, not their values: Claude Code reads them at each connection, so changing a
# variable in the environment applies without rerunning this script (whose result an environment may reuse).
HEADERS=(--header 'Authorization: Bearer ${HANDFREE_BRIDGE_TOKEN}')
[ -n "${HANDFREE_BRIDGE_EDGE_KEY:-}" ] && HEADERS+=(--header 'X-Handfree-Key: ${HANDFREE_BRIDGE_EDGE_KEY}')

claude mcp remove --scope user spokenly >/dev/null 2>&1 || true
claude mcp add --scope user --transport http spokenly "${HANDFREE_BRIDGE_URL%/}/mcp" "${HEADERS[@]}" || true
