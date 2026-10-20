---
paths:
  - "bin/handfree.js"
  - "bin/listener.py"
  - "app/Sources/StateMonitor.swift"
---

# The shared state (`state.json`)

Sessions on older plugin versions write the same file at the same time. See docs/architecture.md, *Shared state*.

- A new field is optional: missing means off. A field is never renamed or given another meaning.
- Never bump `STATE_VERSION`: each version would wipe the other's state at every write.
- The hold changes only through `hold`, `releaseHold` and `releaseHoldOf` in `handfree.js`; `heldByAnother` and `isHeld` tell whether it is on. Never set `dictating_*`, `held_by` or `finishing_current` by hand.
- A field read by the listener or the app goes in the *Read by* column of the state table, and they judge it the way `handfree.js` does (the hold with `max_dictation_seconds`).
- Nothing slow runs inside `withState` (no player, no network, no waiting): ask first, then change the state. A look without changing anything is `readState()`.
