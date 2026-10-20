#!/bin/sh
# Stands in for /usr/bin/say: records what was spoken once "speaking" is over, so a caller that does not wait shows.
# The arguments it was given go to say-args.log next to the said log (the "--" before the text, say).
printf '%s\n' "$*" >> "${HANDFREE_SAY_LOG%/*}/say-args.log"
[ "${1:-}" = "--" ] && shift
sleep "${HANDFREE_FAKE_SAY_SECONDS:-0.2}"
printf '%s\n' "$*" >> "$HANDFREE_SAY_LOG"
