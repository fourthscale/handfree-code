---
description: Install or update the spoken-commands listener (offline, Vosk), or remove it
argument-hint: "[remove]"
---

Run `sh "$HOME/Library/Application Support/handfree-code/install-listener.sh"` (the full install, app included, is /handfree-code:install), with `--remove` if the argument is `remove`. Run it outside the sandbox: it creates a Python environment, downloads Vosk and a speech model (about 65 MB) the first time, then starts a login service. It is safe to run again: the environment and the model are only downloaded when missing, the service is rewritten and restarted.

Then tell the user in a few lines what it printed. On an install, add the one step left to them: allow Handfree Code in System Settings > Privacy & Security > Accessibility if the app has not been allowed yet (the app records and presses Return for the listener; Python needs a permission only without the app, as the script then says).
