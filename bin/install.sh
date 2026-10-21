#!/bin/sh
# Installs everything the plugin works with, on this Mac, in one go. Run it again any time: it brings everything up to
# date and keeps your settings, the way Claude's questions travel included.
#   1. the plugin's scripts, copied where plugin updates leave them (~/Library/Application Support/handfree-code)
#   2. the Handfree Code app: built here, signed with a certificate of this Mac's own, started with your session
#      (dictation, Claude's questions, the status panel)
#   3. the spoken-commands listener (Vosk, offline), and media-control on macOS 15.4 and later
#   4. Claude's `handfree` MCP server, for Claude's questions by voice
# Needs Apple's developer tools: xcode-select --install
#   sh bin/install.sh                 (or /handfree-code:install in Claude)
#   sh bin/install.sh --remove        stops and removes the app, the listener and the MCP server (models stay)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
PLUGIN=$(cd "$HERE/.." && pwd)
SUPPORT="$HOME/Library/Application Support/handfree-code"

if [ "${1:-}" = --remove ]; then
  sh "$PLUGIN/app/install.sh" --remove
  sh "$HERE/install-listener.sh" --remove
  command -v claude >/dev/null 2>&1 && claude mcp remove --scope user handfree >/dev/null 2>&1 || true
  echo "Removed. The plugin itself stays: claude plugin uninstall handfree-code@handfree-code"
  exit 0
fi

[ "$(uname)" = Darwin ] || { echo "Handfree Code runs on macOS only." >&2; exit 1; }
xcrun --find swift >/dev/null 2>&1 && /usr/bin/python3 -c "import venv" 2>/dev/null \
  || { echo "Apple's developer tools are missing: run  xcode-select --install  then this again." >&2; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "The claude command is missing: install Claude Code first." >&2; exit 1; }

echo "1/4 The plugin's scripts…"
# The plugin's own list (handfree.js STABLE_FILES) and the version they come from. The listener and the bridge, when
# installed, restart on their new version: Python does not reload its code.
osascript -l JavaScript "$HERE/handfree.js" --refresh-stable-copy >/dev/null

echo "2/4 The Handfree Code app…"
sh "$PLUGIN/app/install.sh"

echo "3/4 The spoken-commands listener…"
sh "$SUPPORT/install-listener.sh"

echo "4/4 Claude's questions by voice…"
# The way chosen before is kept; one that no longer works (the bridge without its settings) gives way to the app.
sh "$HERE/set-question-transport.sh" keep || sh "$HERE/set-question-transport.sh" mcp

# Settings of versions before 0.3 that no longer mean anything, and the Voice Control setup's backups (before 0.2).
rm -f "$SUPPORT"/voice-commands-backup-*.plist
CONFIG=${HANDFREE_CONFIG:-$HOME/.config/handfree-code.json}
[ -n "${HANDFREE_CONFIG:-}" ] || [ -e "$CONFIG" ] || [ ! -e "$HOME/.config/claude-speak.json" ] || CONFIG="$HOME/.config/claude-speak.json" # before 0.3.2
/usr/bin/python3 - "$CONFIG" "$HERE/voice-commands.json" <<'PY'
import json, os, sys
path = sys.argv[1]
try:
    config = json.load(open(path, encoding="utf-8"))
except (OSError, ValueError):
    sys.exit(0)
old = {k for k in ("spokenly_trigger", "double_tap_gap_seconds") if k in config}
if (config.get("question_tool") or "").startswith("mcp__spokenly__"):
    old.add("question_tool")
# The Voice Control names of the commands (before 0.2) become their ids, as the app writes them.
names = json.load(open(sys.argv[2], encoding="utf-8"))["old_names"]
phrases = config.get("voice_commands") or {}
renamed = {names.get(name, name): said for name, said in phrases.items() if names.get(name, name) not in phrases or name not in names}
if old or renamed != phrases:
    if renamed != phrases:
        config["voice_commands"] = renamed
    for key in old:
        config.pop(key)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
    os.chmod(path, 0o600)
PY

cat <<'TXT'

Done. Left to you, once:
  - System Settings > Privacy & Security > Accessibility: allow Handfree Code (the app asks).
  - Microphone: macOS asks Handfree Code once. The app records for the listener too: Python needs no permission.
  - Open a new Claude session: the hooks and the MCP server are read when a session starts.
The app's icon is in the menu bar: Settings and services, the dictation engine and model, keyboard shortcuts.
At its first start the app downloads the Whisper model (about 1.6 GB), then macOS prepares it once (a few minutes).
TXT
