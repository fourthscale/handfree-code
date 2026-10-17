#!/bin/sh
# Runs a handfree hook: on the Mac directly; elsewhere (a cloud session) through the bridge to the Mac, if configured.
ROOT=$(dirname "$0")
if [ "$(uname)" = Darwin ]; then
  exec osascript -l JavaScript "$ROOT/handfree.js" "$@"
fi
if [ -n "${HANDFREE_BRIDGE_URL:-}" ] && command -v python3 >/dev/null 2>&1; then
  exec python3 "$ROOT/cloud-hook.py" "$@"
fi
exit 0
