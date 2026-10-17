#!/usr/bin/env python3
"""Cloud side of the bridge: forwards a hook to the Mac, with the parts of the transcript the Mac cannot read."""
import json
import os
import sys
import urllib.request

TRANSCRIPT_TAIL_LINES = 400
TIMEOUT_SECONDS = 110  # under the PreToolUse hook's 120 s


def transcript_tail(path):
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
    except (OSError, TypeError):
        return []
    tail = lines[-TRANSCRIPT_TAIL_LINES:]
    # The session's title can be far above the tail: keep its latest entry.
    titles = [line for line in lines if '"custom-title"' in line]
    return (titles[-1:] if titles and titles[-1] not in tail else []) + tail


EDGE_KEY_HEADER = "X-Handfree-Key"  # checked by the tunnel's edge (a WAF rule) before anything reaches the Mac


def edge_key_header():
    key = os.environ.get("HANDFREE_BRIDGE_EDGE_KEY", "")
    return {EDGE_KEY_HEADER: key} if key else {}


def main():
    url = os.environ.get("HANDFREE_BRIDGE_URL", "").rstrip("/")
    token = os.environ.get("HANDFREE_BRIDGE_TOKEN", "")
    if not url or not token:
        return
    try:
        hook = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        hook = {}
    payload = {
        "command": sys.argv[1] if len(sys.argv) > 1 else "",
        "hook": hook,
        "transcript_tail": transcript_tail(hook.get("transcript_path")),
        "overrides": os.environ.get("HANDFREE_OVERRIDES", ""),
    }
    request = urllib.request.Request(
        url + "/hook",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
            # Bot protections in front of tunnels often block Python's default user agent.
            "User-Agent": "handfree-code-bridge",
            **edge_key_header(),
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            sys.stdout.write(response.read().decode("utf-8"))
    except Exception as error:  # an unreachable Mac must never break the session
        sys.stderr.write(f"handfree bridge unreachable: {error}\n")


if __name__ == "__main__":
    main()
