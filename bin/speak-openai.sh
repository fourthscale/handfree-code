#!/bin/sh
# A voice for the speak_command setting: speaks its argument with OpenAI's text-to-speech.
# Reads from ~/.config/claude-speak.json: openai_api_key (required), openai_voice (default alloy), openai_tts_model.
# Any failure exits non-zero: the Mac's own voice reads the line instead.
set -eu
CONFIG=${HANDFREE_CONFIG:-$HOME/.config/claude-speak.json}
setting() { plutil -extract "$1" raw -o - "$CONFIG" 2>/dev/null >"$WORK/value" && cat "$WORK/value" || printf '%s' "$2"; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT # no TERM trap: stopped by "Quiet", the script must die of the signal
KEY=$(setting openai_api_key '')
[ -n "$KEY" ] || exit 1
# JSON.stringify keeps any quote or accent in the text valid.
osascript -l JavaScript -e 'function run(a) { return JSON.stringify({ model: a[0], voice: a[1], input: a[2] }) }' \
  "$(setting openai_tts_model gpt-4o-mini-tts)" "$(setting openai_voice alloy)" "$1" > "$WORK/request.json"
curl -sSf -m 30 https://api.openai.com/v1/audio/speech \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d @"$WORK/request.json" -o "$WORK/speech.mp3"
afplay "$WORK/speech.mp3"
