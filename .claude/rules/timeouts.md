---
paths:
  - "hooks/hooks.json"
  - "bin/bridge-server.py"
  - "bin/cloud-hook.py"
  - "bin/mcp-relay.sh"
---

# Time limits

Each wait must fit inside the one around it: the bridge's under the cloud hook's request, the request under the hook's timeout in `hooks/hooks.json`, the question's reading under its hook. A change to any of them updates the *Time limits* table in docs/architecture.md; `tests/bridge.sh` checks that the hooks' limits nest.
