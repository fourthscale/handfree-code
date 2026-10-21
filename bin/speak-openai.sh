#!/bin/sh
# A voice for the speak_command setting: speaks its argument with OpenAI's text-to-speech.
# Reads from ~/.config/handfree-code.json: openai_api_key (required), openai_voice (default alloy), openai_tts_model.
# Any failure exits non-zero: the Mac's own voice reads the line instead.
set -eu
CONFIG=${HANDFREE_CONFIG:-$HOME/.config/handfree-code.json}
[ -n "${HANDFREE_CONFIG:-}" ] || [ -e "$CONFIG" ] || [ ! -e "$HOME/.config/claude-speak.json" ] || CONFIG="$HOME/.config/claude-speak.json" # before 0.3.2
setting() { plutil -extract "$1" raw -o - "$CONFIG" 2>/dev/null >"$WORK/value" && cat "$WORK/value" || printf '%s' "$2"; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT # no TERM trap: stopped by "Quiet", the script must die of the signal
KEY=$(setting openai_api_key '')
[ -n "$KEY" ] || exit 1
# JSON.stringify keeps any quote or accent in the text valid.
osascript -l JavaScript -e 'function run(a) { return JSON.stringify({ model: a[0], voice: a[1], input: a[2] }) }' \
  "$(setting openai_tts_model gpt-4o-mini-tts)" "$(setting openai_voice alloy)" "$1" > "$WORK/request.json"
# The key goes to curl on its standard input, not on its command line, where any process could read it.
printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$KEY" |
  curl -sSf -m 30 https://api.openai.com/v1/audio/speech -H @- -d @"$WORK/request.json" -o "$WORK/speech.mp3"
afplay "$WORK/speech.mp3"
