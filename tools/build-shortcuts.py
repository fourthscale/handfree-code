#!/usr/bin/python3
"""Builds the signed .shortcut files of shortcuts/import/ from the scripts of shortcuts/.

Run on a Mac after changing a script: python3 tools/build-shortcuts.py (run it again if Apple turns a signing down).
Each file imports with a double-click; its name is the shortcut's name.
"""
import os
import plistlib
import subprocess
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "shortcuts")
TARGET = os.path.join(SOURCE, "import")
# Shortcut name -> script file; the first line of each file names its action.
SHORTCUTS = {
    "Claude Listen": "listen.sh",
    "Claude Reply": "reply.sh",
    "Claude Session": "session.sh",
    "Stop": "stop.applescript",
    "Claude Quiet": "quiet.sh",
    "Claude Continue": "continue.sh",
    "Claude Restart": "restart.sh",
    "Claude Voice mode on": "voice-on.sh",
    "Claude Voice mode off": "voice-off.sh",
}


def action(path):
    script = open(path, encoding="utf-8").read()
    if path.endswith(".applescript"):
        return {"WFWorkflowActionIdentifier": "is.workflow.actions.runapplescript", "WFWorkflowActionParameters": {"Script": script}}
    body = "\n".join(line for line in script.splitlines() if not line.startswith("#")).strip()
    return {
        "WFWorkflowActionIdentifier": "is.workflow.actions.runshellscript",
        "WFWorkflowActionParameters": {"Script": body, "Shell": "/bin/sh", "InputMode": "to stdin"},
    }


def workflow(path):
    return {
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowClientVersion": "2302.0.4",
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 59511},
        "WFWorkflowTypes": [],
        "WFWorkflowInputContentItemClasses": [],
        "WFWorkflowImportQuestions": [],
        "WFWorkflowActions": [action(path)],
    }


def main():
    os.makedirs(TARGET, exist_ok=True)
    with tempfile.TemporaryDirectory() as work:
        for name, file in SHORTCUTS.items():
            unsigned = os.path.join(work, name + ".shortcut")
            with open(unsigned, "wb") as f:
                plistlib.dump(workflow(os.path.join(SOURCE, file)), f, fmt=plistlib.FMT_BINARY)
            signed = os.path.join(TARGET, name + ".shortcut")
            if up_to_date(signed, os.path.join(SOURCE, file)):
                continue
            sign(unsigned, signed)
            print("built", os.path.relpath(signed, ROOT))


def up_to_date(signed, script):
    """Signing is slow and rationed: a file newer than its script and than this builder is kept."""
    if not os.path.exists(signed):
        return False
    return os.path.getmtime(signed) > max(os.path.getmtime(script), os.path.getmtime(__file__))


def sign(unsigned, signed):
    """'anyone': importable on any Mac. Signing goes through Apple, which turns down requests in quick succession."""
    if os.path.exists(signed):
        os.remove(signed)  # sign does not overwrite
    for attempt in range(5):
        result = subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", unsigned, "--output", signed], capture_output=True, text=True)
        if result.returncode == 0 and os.path.exists(signed):
            return
        time.sleep(3 * (attempt + 1))
    errors = [line for line in result.stderr.splitlines() if "attribute string" not in line]
    raise SystemExit(f"could not sign {os.path.basename(signed)}: {' '.join(errors) or 'no reason given'}")


if __name__ == "__main__":
    main()
