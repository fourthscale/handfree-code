#!/usr/bin/python3
"""Creates the Voice Control commands that run the plugin's Shortcuts, in the language of Voice Control.

Import the Shortcuts of shortcuts/import/ first, turn Voice Control off, then:
    /usr/bin/python3 bin/install-voice-commands.py            (--dry-run to only show what it would do)
and turn Voice Control back on. A command whose phrase already exists is pointed at the new shortcut, not doubled.
Your commands are saved to ~/Library/Application Support/handfree-code/ first.
"""
import datetime
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import time

DOMAIN = "com.apple.speech.recognition.AppleSpeechRecognition.CustomCommands"
CONFIG_PATH = os.environ.get("HANDFREE_CONFIG") or os.path.expanduser("~/.config/claude-speak.json")
BACKUP_DIR = os.path.expanduser("~/Library/Application Support/handfree-code")
# Shortcut -> phrase, per language. Lowercase, as Voice Control stores them.
PHRASES = {
    "fr": {
        "Claude Listen": "claude écoute",
        "Claude Reply": "claude réponds",
        "Claude Session": "claude session",
        "Stop": "stop",
        "Claude Quiet": "claude chut",
        "Claude Continue": "claude continue",
        "Claude Restart": "claude recommence",
        "Claude Voice mode on": "claude mode vocal activé",
        "Claude Voice mode off": "claude mode vocal désactivé",
    },
    "en": {name: name.lower() for name in [
        "Claude Listen", "Claude Reply", "Claude Session", "Stop", "Claude Quiet",
        "Claude Continue", "Claude Restart", "Claude Voice mode on", "Claude Voice mode off"]},
    "de": {
        "Claude Listen": "claude zuhören",
        "Claude Reply": "claude antworten",
        "Claude Session": "claude sitzung",
        "Stop": "stopp",
        "Claude Quiet": "claude ruhe",
        "Claude Continue": "claude weiter",
        "Claude Restart": "claude neu",
        "Claude Voice mode on": "claude sprachmodus an",
        "Claude Voice mode off": "claude sprachmodus aus",
    },
}
APPLE_EPOCH = datetime.datetime(2001, 1, 1)


def shortcut_ids():
    output = subprocess.run(["shortcuts", "list", "--show-identifiers"], capture_output=True, text=True).stdout
    return {m.group(1): m.group(2) for m in re.finditer(r"^(.*) \(([0-9A-F-]{36})\)$", output, re.M)}


def read_commands():
    result = subprocess.run(["defaults", "export", DOMAIN, "-"], capture_output=True)
    return plistlib.loads(result.stdout) if result.returncode == 0 and result.stdout else {}


def custom(commands):
    return {key: value for key, value in commands.items() if key.startswith("Custom.") and isinstance(value, dict)}


def voice_control_locale(commands):
    """The language the user's own commands are in; English when there are none."""
    locales = [locale for value in custom(commands).values() for locale in (value.get("CustomCommands") or {})]
    return max(set(locales), key=locales.count) if locales else "en_US"


def own_phrases():
    """The user's phrases, from voice_commands in the settings: {"Claude Listen": "claude écoute", ...}."""
    try:
        with open(CONFIG_PATH, encoding="utf-8") as f:
            chosen = json.load(f).get("voice_commands") or {}
    except (OSError, ValueError):
        return {}
    return {name: phrase.strip().lower() for name, phrase in chosen.items() if isinstance(phrase, str) and phrase.strip()}


def main():
    dry_run = "--dry-run" in sys.argv
    commands = read_commands()
    locale = voice_control_locale(commands)
    phrases = dict(PHRASES.get(locale[:2], PHRASES["en"]), **{n: p for n, p in own_phrases().items() if n in PHRASES["en"]})
    ids = shortcut_ids()
    missing = [name for name in phrases if name not in ids]
    if missing:
        sys.exit("Import these Shortcuts first (shortcuts/import/): " + ", ".join(missing))

    by_phrase = {}
    for key, value in custom(commands).items():
        for phrase in (value.get("CustomCommands") or {}).get(locale, []):
            by_phrase[phrase.lower()] = key
    now = datetime.datetime.now()
    for name, phrase in phrases.items():
        key = by_phrase.get(phrase)
        if key and commands[key].get("CustomShortcutsWorkflow") == ids[name] and commands[key].get("Enabled"):
            print(f"kept      « {phrase} » → {name}")
            continue
        if key:
            print(f"repointed « {phrase} » → {name}")
            commands[key].update({"CustomShortcutsWorkflow": ids[name], "CustomType": "RunShortcutsWorkflow", "Enabled": True, "CustomModifyDate": now})
            continue
        print(f"added     « {phrase} » → {name}")
        key = f"Custom.{(datetime.datetime.now() - APPLE_EPOCH).total_seconds():.6f}"
        while key in commands:  # a key per command: the same one would overwrite the last
            time.sleep(0.001)
            key = f"Custom.{(datetime.datetime.now() - APPLE_EPOCH).total_seconds():.6f}"
        commands[key] = {
            "CustomCommands": {locale: [phrase]},
            "CustomModifyDate": now,
            "CustomScope": "com.apple.speech.SystemWideScope",
            "CustomShortcutsWorkflow": ids[name],
            "CustomType": "RunShortcutsWorkflow",
            "Enabled": True,
        }

    if dry_run:
        return print(f"Dry run, language {locale}: nothing written.")
    os.makedirs(BACKUP_DIR, exist_ok=True)
    backup = os.path.join(BACKUP_DIR, f"voice-commands-backup-{now:%Y%m%d-%H%M%S}.plist")
    subprocess.run(["defaults", "export", DOMAIN, backup], check=True)
    with tempfile.NamedTemporaryFile(suffix=".plist", delete=False) as f:
        plistlib.dump(commands, f)
    subprocess.run(["defaults", "import", DOMAIN, f.name], check=True)
    os.unlink(f.name)
    print(f"Done, language {locale}. Previous commands saved to {backup}")
    print("Turn Voice Control back on for it to read them.")


if __name__ == "__main__":
    main()
