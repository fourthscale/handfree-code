#!/usr/bin/env python3
"""Cloud side of the bridge: forwards a hook to the Mac, with the parts of the transcript the Mac cannot read."""
import json
import os
import sys
import time
import urllib.error
import urllib.request

TRANSCRIPT_TAIL_LINES = 400
# One line per hook, for troubleshooting a cloud session: event, outcome, never a key or the conversation.
LOG_PATH = os.environ.get("HANDFREE_HOOK_LOG", "/tmp/handfree-hook.log")
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


def trim_log(path, max_bytes=200_000, kept_lines=500):
    """Past max_bytes, a log keeps only its last lines: it never fills the disk."""
    try:
        if os.path.getsize(path) > max_bytes:
            with open(path, encoding="utf-8", errors="replace") as f:
                kept = f.readlines()[-kept_lines:]
            with open(path, "w", encoding="utf-8") as f:
                f.writelines(kept)
    except OSError:
        pass


def log(command, outcome):
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%H:%M:%S')} {command or 'stop'}: {outcome}\n")
    except OSError:
        pass
    trim_log(LOG_PATH)


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    url = os.environ.get("HANDFREE_BRIDGE_URL", "").rstrip("/")
    token = os.environ.get("HANDFREE_BRIDGE_TOKEN", "")
    if not url or not token:
        return log(command, "no HANDFREE_BRIDGE_URL or HANDFREE_BRIDGE_TOKEN in the hook's environment")
    try:
        hook = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        hook = {}
    payload = {
        "command": command,
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
            output = response.read().decode("utf-8")
            sys.stdout.write(output)
            log(command, f"HTTP {response.status}, {len(output)} bytes back")
    except urllib.error.HTTPError as error:
        # Who refused: the tunnel's edge, a proxy on the way, or the Mac. The body is the refusal page, not ours.
        detail = error.read(300).decode("utf-8", "replace").replace("\n", " ")
        log(command, f"failed: HTTP {error.code}, server {error.headers.get('server', '?')}, {len(payload['transcript_tail'])} transcript lines: {detail}")
        sys.stderr.write(f"handfree bridge refused: HTTP {error.code}\n")
    except Exception as error:  # an unreachable Mac must never break the session
        log(command, f"failed: {type(error).__name__}: {error}")
        sys.stderr.write(f"handfree bridge unreachable: {error}\n")


if __name__ == "__main__":
    main()
