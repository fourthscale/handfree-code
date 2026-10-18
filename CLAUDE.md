# handfree-code

A Claude Code plugin to drive Claude Code by voice on macOS: replies read aloud, questions answered through Spokenly, commands through Voice Control.

Read before changing anything:
- [docs/architecture.md](docs/architecture.md): how it works (hooks, shared state, the reading queue, questions, voice commands, cloud bridge).
- [docs/development.md](docs/development.md): layout, conventions, tests, trying a change for real.

## Rules

- Everything in the repository is in English. Only the phrases spoken to the user are translated (fr, en, de).
- No personal data: no company names, hostnames, keys or user-specific paths.
- Run `tests/run.sh` (and `tests/bridge.sh` for bridge changes) outside the sandbox before calling a change done. Add a check for each new behaviour.
- To try a change in the real app: bump `.claude-plugin/plugin.json`, update the plugin, open a new session (see development.md).
- Keep the README in step with what the user can notice, and docs/architecture.md with how it works.
- New state fields are optional: sessions on older versions share the same state file.
- Prefer the simple solution; say so when one is not worth its complexity.
