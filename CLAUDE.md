# handfree-code

A Claude Code plugin to drive Claude Code by voice on macOS: replies read aloud, dictation and questions through the native Handfree Code app (Whisper, on the Mac), spoken commands through an offline listener (Vosk).

Read before changing anything:
- [docs/architecture.md](docs/architecture.md): how it works (hooks, shared state, the reading queue, questions, voice commands, the app, cloud bridge, time limits).
- [docs/development.md](docs/development.md): layout, conventions, tests, trying a change for real.

The project's rules are in `.claude/rules/`: the general ones always apply, the others when their files are touched.
