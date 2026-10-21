---
paths:
  - "bin/handfree.js"
---

# bin/handfree.js

- Every text said to the user or told to Claude, and every word answers are recognised by, lives in `TEXTS` at the top, per language. Never a literal string elsewhere.
- A new script the services or the app run from the stable copy goes in `STABLE_FILES`: the one list SessionStart and the installers copy (`--refresh-stable-copy`).
- A new command goes in `COMMANDS`, and in `RUNS_WHEN_OFF` only if it must run with voice mode off. Add it to the header comment of the file.
- A new setting goes in `DEFAULTS` with a comment, in the README's settings table, and in `CLOUD_OVERRIDABLE` only if it is harmless coming from a cloud session.
- A system effect (a key, a link opened, media, a service restarted) has a `HANDFREE_*` stand-in for the tests.
- Run with `osascript -l JavaScript`: no Node, no import. `doShellScript` returns lines separated by `\r`.
