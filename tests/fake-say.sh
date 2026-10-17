#!/bin/sh
# Stands in for /usr/bin/say: records what would be spoken.
printf '%s\n' "$*" >> "$HANDFREE_SAY_LOG"
sleep 0.2
