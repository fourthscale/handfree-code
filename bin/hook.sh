#!/bin/sh
# Runs a handfree hook: on the Mac directly; elsewhere (a cloud session) through the bridge to the Mac, if configured.
ROOT=$(dirname "$0")
if [ "$(uname)" = Darwin ]; then
  exec osascript -l JavaScript "$ROOT/handfree.js" "$@"
fi
if command -v python3 >/dev/null 2>&1; then
  exec python3 "$ROOT/cloud-hook.py" "$@"
fi
echo "$(date +%H:%M:%S) ${1:-stop}: no python3" >> "${HANDFREE_HOOK_LOG:-/tmp/handfree-hook.log}" 2>/dev/null
exit 0
