---
description: Turn voice mode on or off (spoken replies, questions by voice), for all sessions or this one only
argument-hint: "[on|off|here|mute]"
---

Run `osascript -l JavaScript "$HOME/Library/Application Support/handfree-code/handfree.js"` with:
- `--on` or `--off` if the argument is `on` or `off` (every session);
- `--session-on "$CLAUDE_CODE_SESSION_ID"` if it is `here`: voice mode for this session only, or this one too when others already have it;
- `--session-off "$CLAUDE_CODE_SESSION_ID"` if it is `mute`: no voice for this session;
- `--toggle` otherwise.

It writes under `~/Library/Caches/handfree-code/`, which the sandbox blocks: run it outside the sandbox.

Then say in one line what changed. When voice mode is now off for this session (`off`, `mute`), stop asking questions through the dictation tool for the rest of this session and ask them as usual; when it is on for it (`on`, `here`), ask them through it again.
