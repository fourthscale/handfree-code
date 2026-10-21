---
description: Install or update everything on this Mac (the Handfree Code app, the listener, Claude's questions by voice), or remove it
argument-hint: "[remove]"
---

Run `sh "${CLAUDE_PLUGIN_ROOT}/bin/install.sh"`, with `--remove` if the argument is `remove`. Run it outside the sandbox, in the background if your tools allow it: the first time it builds the app (a few minutes), creates a signing certificate (macOS asks for the user's password to trust it), installs Vosk and a speech model, and declares the `handfree` MCP server. It is safe to run again: it brings everything up to date and keeps the user's settings, including how Claude's questions travel.

Then tell the user in a few lines what it printed, and the steps left to them that it lists at the end.
