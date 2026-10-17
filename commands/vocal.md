---
description: Turn voice mode on or off (spoken replies, questions through Spokenly)
argument-hint: "[on|off]"
---

Run `osascript -l JavaScript "$HOME/Library/Application Support/handfree-code/handfree.js" --$ARGUMENTS` if the argument is `on` or `off`, otherwise with `--toggle`. It writes under `~/Library/Caches/claude-speak/`, which the sandbox blocks: run it outside the sandbox.

Then say in one line whether voice mode is now on or off. When it is off, stop asking questions through Spokenly for the rest of this session and ask them as usual; when it is on, ask them through Spokenly again.
