#!/bin/sh
# Stands in for /usr/bin/say: records what was spoken once "speaking" is over, so a caller that does not wait shows.
sleep "${HANDFREE_FAKE_SAY_SECONDS:-0.2}"
printf '%s\n' "$*" >> "$HANDFREE_SAY_LOG"
