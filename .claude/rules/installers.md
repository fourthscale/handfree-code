---
paths:
  - "bin/*.sh"
  - "app/install.sh"
  - "commands/*.md"
---

# Installers and shell scripts

- POSIX `sh`, `set -eu`; safe to run again: they bring things up to date and keep the user's settings.
- Scripts reach the stable copy only through `osascript -l JavaScript handfree.js --refresh-stable-copy`.
- A key or token never goes on a command line, where any process can read it: to curl through its standard input (`-H @-`).
- The `handfree` MCP server is declared with `claude mcp add-json`, its `timeout` included. Never edit `~/.claude.json` directly.
- The settings file is `${HANDFREE_CONFIG:-$HOME/.config/handfree-code.json}`, with the same fallback to the old name as the other scripts.
