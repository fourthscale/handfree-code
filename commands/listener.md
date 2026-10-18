---
description: Install or update the spoken-commands listener (offline, Vosk), or remove it
argument-hint: "[remove]"
---

Run `sh "$HOME/Library/Application Support/handfree-code/install-listener.sh"`, with `--remove` if the argument is `remove`. Run it outside the sandbox: it creates a Python environment, downloads Vosk and a speech model (about 65 MB) the first time, then starts a login service. Only what is missing is done, so it is safe to run again.

Then tell the user in a few lines what it printed. On an install, add the one step left to them: allow Python in System Settings > Privacy & Security > Accessibility (the script opened that page and shows the app to add), then restart the listener with the command it printed.
