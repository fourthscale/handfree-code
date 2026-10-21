# Tests

- Run `tests/run.sh` (and `tests/bridge.sh` for anything the bridge or a cloud session touches) outside the sandbox before calling a change done. Both must end on `ALL PASSED`.
- Each new behaviour gets a check, named after what should happen.
- Pure logic decided from text or state alone goes in `tests/unit.js` (fast, no voice, no process; add the name to its `NAMES`). Hooks, processes and timing go in `tests/run.sh`.
- Tests never touch the real state, settings, stable copy or services: they use the `HANDFREE_*` variables listed in docs/development.md, *Tests*. A new system effect gets its own variable there.
- A change to the app (`app/`) is done only once `sh app/install.sh` builds it; the app has no automated tests beyond the phantom filter.
