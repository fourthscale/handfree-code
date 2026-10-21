---
paths:
  - "bin/voice-commands.json"
  - "bin/listener.py"
  - "app/Sources/VoiceCommands.swift"
---

# Voice commands and languages

A command or a language touches several programs: follow docs/development.md, *Adding a voice command* or *Adding a language*, every step. The listener and the app read `bin/voice-commands.json`; a phrase heard while Claude speaks or while you dictate must be in the listener's `WHILE_SPEAKING` or `WHILE_DICTATING`.
