#!/usr/bin/env python3
"""Listens for the plugin's spoken commands and runs them: "Claude Listen", "Stop", "Claude Quiet"...

Recognition is Vosk's, offline, restricted to the commands' phrases: anything else is heard as unknown and ignored.
A second recognizer, free, transcribes the same audio: a command it heard as clearly other words is refused.
A command counts only said alone: set apart by a short silence from anything else heard. What is allowed depends on the plugin's state:
  - voice mode off: the plugin stops this listener altogether ("/vocal on" starts it again); if still running, only
    "voice mode on";
  - a dictation under way (a question, "Listen"): only "Stop" (once a second of silence follows it) and "Cancel";
  - the plugin speaking: only Quiet, Continue and Restart, and not a phrase that is in the text being read;
  - otherwise: every command but "Stop" and "Cancel" (no dictation).
Installed and kept running by bin/install-listener.sh. `listener.py --check "<phrase>"` prints the decision, for tests.
"""
import json
import os
import re
import subprocess
import sys
import time
import unicodedata
from difflib import SequenceMatcher

HOME = os.path.expanduser("~")
CONFIG_PATH = os.environ.get("HANDFREE_CONFIG") or os.path.join(HOME, ".config/claude-speak.json")
STATE_PATH = os.path.join(os.environ.get("HANDFREE_STATE_DIR") or os.path.join(HOME, "Library/Caches/claude-speak"), "state.json")
SUPPORT_DIR = os.path.join(HOME, "Library/Application Support/handfree-code")
SCRIPT = os.environ.get("HANDFREE_SCRIPT") or os.path.join(SUPPORT_DIR, "handfree.js")
MODELS = {"fr": "vosk-model-small-fr-0.22", "en": "vosk-model-small-en-us-0.15", "de": "vosk-model-small-de-0.15"}
MAX_DICTATION_SECONDS = 180  # as the plugin's own default: an older dictation no longer holds
REPEAT_SECONDS = 1.5  # the same command heard twice in a row is said once
INPUT_CHECK_SECONDS = 4  # how often the system's default microphone is checked (headphones put on, AirPods)
PAUSE_SECONDS = 0.3
FREE_MATCH = 0.8  # how close the free transcription must be to a command phrase
FREE_MARGIN_SECONDS = 0.3  # the free transcription compared is what was said while the command was, give or take this
STOP_SILENCE_SECONDS = 1.0  # "Stop" sends only once this much silence follows: said inside a sentence, speech goes on  # a command set apart by this much silence counts as said alone, whatever noise is around it
RETURN_KEY = 36
ESCAPE_KEY = 53
LOG_PATH = os.path.join(HOME, "Library/Logs/handfree-listener.log")
LOG_MAX_BYTES = 200_000  # beyond, the log keeps only its last lines: it never fills the disk
LOG_KEPT_LINES = 500

# Command -> plugin argument. "stop" also presses Return: it sends the dictation, as Voice Control's "Stop" did.
COMMANDS = {
    "listen": "--listen",
    "reply": "--reply",
    "session": "--search-session",
    "stop": "--done",
    "cancel": "--cancel",
    "quiet": "--stop",
    "continue": "--resume",
    "restart": "--restart",
    "voice_on": "--on",
    "voice_off": "--off",
}
WHILE_SPEAKING = {"quiet", "continue", "restart"}
WHILE_DICTATING = {"stop", "cancel"}
# Default phrases, lowercase. Several may lead to one command.
PHRASES = {
    "fr": {
        "listen": ["claude écoute"],
        "reply": ["claude réponds"],
        "session": ["claude session"],
        "stop": ["stop"],
        "cancel": ["claude annule"],
        "quiet": ["claude chut", "claude silence", "claude tais-toi"],
        "continue": ["claude continue"],
        "restart": ["claude recommence"],
        "voice_on": ["claude mode vocal activé"],
        "voice_off": ["claude mode vocal désactivé"],
    },
    "en": {
        "listen": ["claude listen"],
        "reply": ["claude reply"],
        "session": ["claude session"],
        "stop": ["stop"],
        "cancel": ["claude cancel"],
        "quiet": ["claude quiet"],
        "continue": ["claude continue"],
        "restart": ["claude restart"],
        "voice_on": ["claude voice mode on"],
        "voice_off": ["claude voice mode off"],
    },
    "de": {
        "listen": ["claude zuhören"],
        "reply": ["claude antworten"],
        "session": ["claude sitzung"],
        "stop": ["stopp"],
        "cancel": ["claude abbrechen"],
        "quiet": ["claude ruhe"],
        "continue": ["claude weiter"],
        "restart": ["claude neu"],
        "voice_on": ["claude sprachmodus an"],
        "voice_off": ["claude sprachmodus aus"],
    },
}
# The names the Voice Control setup used in `voice_commands`: a phrase chosen there is kept.
OLD_NAMES = {
    "Claude Listen": "listen",
    "Claude Reply": "reply",
    "Claude Session": "session",
    "Stop": "stop",
    "Claude Cancel": "cancel",
    "Claude Quiet": "quiet",
    "Claude Continue": "continue",
    "Claude Restart": "restart",
    "Claude Voice mode on": "voice_on",
    "Claude Voice mode off": "voice_off",
}


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def normalize(text):
    return " ".join(unicodedata.normalize("NFC", text or "").lower().replace("’", "'").split())


def language(config):
    chosen = (config.get("language") or "").lower()[:2]
    if chosen in PHRASES:
        return chosen
    # The Mac's first language, as the plugin itself does.
    try:
        output = subprocess.run(["defaults", "read", "-g", "AppleLanguages"], capture_output=True, text=True).stdout
    except OSError:
        output = ""
    match = re.search(r'"?([a-z]{2})[-_"]', output)
    return match.group(1) if match and match.group(1) in PHRASES else "en"


def phrases(config, lang):
    """Phrase -> command, the defaults of the language and the user's own (`voice_commands`)."""
    table = {command: list(said) for command, said in PHRASES[lang].items()}
    for name, said in (config.get("voice_commands") or {}).items():
        command = OLD_NAMES.get(name, name)
        if command in table and isinstance(said, (str, list)):
            table[command] = [said] if isinstance(said, str) else said
    return {normalize(p): command for command, said in table.items() for p in said if normalize(p)}


def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError, TypeError):
        return False


def speaking(state):
    # A voice noted but gone (a crash) does not count.
    return alive(state.get("speaker_pid")) or time.time() - float(state.get("last_speech_end") or 0) < 0.8


def dictating(state):
    since = state.get("dictating_since")
    return bool(since) and time.time() - float(since) < MAX_DICTATION_SECONDS


def text_being_read(state):
    current = state.get("current") or {}
    return normalize(" ".join(current.get("lines") or []))


def isolated_command(words, table):
    """The command phrase in `words` (Vosk's [{"word", "start", "end"}]) that silence sets apart, with when it was
    said: (phrase, start, end), or None.

    A breath or a noise just before a command is heard as one more word: the command still counts when a pause
    separates it from the rest. Words run together ("je pense que claude écoute mal") do not.
    """
    tokens = [normalize(w.get("word")) for w in words]
    for phrase in sorted(table, key=lambda p: -len(p.split())):
        size = len(phrase.split())
        for i in range(len(tokens) - size + 1):
            if " ".join(tokens[i:i + size]) != phrase:
                continue
            before = i == 0 or words[i]["start"] - words[i - 1]["end"] >= PAUSE_SECONDS
            after = i + size == len(words) or words[i + size]["start"] - words[i + size - 1]["end"] >= PAUSE_SECONDS
            if before and after:
                return phrase, words[i]["start"], words[i + size - 1]["end"]
    return None


def confirmed(phrase, free_text):
    """Whether the free transcription (no grammar) agrees with a command the closed grammar heard.

    The grammar maps any speech to its nearest phrase; free recognition writes what was said. Clearly other words
    (a video, a sentence of yours) refuse the command. Nothing or next to nothing transcribed keeps it: short
    commands are often lost there.
    """
    words = [w for w in normalize(free_text).split() if w != "[unk]"]
    if len(words) <= 1 and len(phrase.split()) > 1 or not words:
        return True
    if len(phrase.split()) == 1:
        return phrase in words
    size = len(phrase.split())
    best = 0.0
    for n in {size - 1, size, size + 1}:
        for i in range(max(1, len(words) - n + 1)):
            best = max(best, SequenceMatcher(None, phrase, " ".join(words[i:i + n])).ratio())
    return best >= FREE_MATCH


def decide(heard, state, table):
    """The command to run for what was heard, or None and why not."""
    heard = normalize(heard)
    command = table.get(heard)
    if not command:
        return None, "not a command said alone"
    if state.get("voice_off"):
        return (command, "") if command == "voice_on" else (None, "voice mode off")
    if dictating(state):
        return (command, "") if command in WHILE_DICTATING else (None, "a dictation is under way: only stop or cancel")
    if command in WHILE_DICTATING:
        return None, "no dictation under way"
    if speaking(state):
        if command not in WHILE_SPEAKING:
            return None, "the plugin is speaking: only quiet, continue, restart"
        if heard in text_being_read(state):
            return None, "it is in the text being read"
    return command, ""


def press(key):
    # The key goes to the app in front (Spokenly's recorder, Claude's field): Return sends, Escape cancels.
    subprocess.run(["osascript", "-e", 'tell application "System Events" to key code %d' % key], check=False)


def chime(config):
    """A short system sound when a command is taken, as Voice Control does. `listener_sound`: a sound's name, or false."""
    name = config.get("listener_sound", "Tink")
    path = f"/System/Library/Sounds/{name}.aiff" if name else ""
    if path and os.path.exists(path):
        subprocess.Popen(["afplay", path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def run(command):
    if command in ("stop", "cancel"):
        press(RETURN_KEY if command == "stop" else ESCAPE_KEY)
    subprocess.Popen(["osascript", "-l", "JavaScript", SCRIPT, COMMANDS[command]], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def default_input():
    """The system's default microphone right now: a fresh process sees devices plugged in since this one started."""
    try:
        return subprocess.run([sys.executable, "-c", "import sounddevice as sd; print(sd.query_devices(kind='input')['name'])"],
                              capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def follow_default_input(name):
    """When the default microphone changes, start over on the new one: the service brings this listener back at once."""
    import threading

    def watch():
        while True:
            time.sleep(INPUT_CHECK_SECONDS)
            now = default_input()
            if now and now != name:
                log(f"microphone changed: {name} -> {now}, starting over")
                os._exit(0)

    threading.Thread(target=watch, daemon=True).start()


def log(line):
    """The log holds the commands run (and, with `listener_log`: true, every phrase heard). No sound is ever kept."""
    print(time.strftime("%H:%M:%S"), line, flush=True)
    try:
        if os.path.getsize(LOG_PATH) > LOG_MAX_BYTES:
            with open(LOG_PATH, encoding="utf-8", errors="replace") as f:
                kept = f.readlines()[-LOG_KEPT_LINES:]
            with open(LOG_PATH, "w", encoding="utf-8") as f:
                f.writelines(kept)
    except OSError:
        pass


def listen():
    import queue
    import sounddevice as sd
    from vosk import KaldiRecognizer, Model, SetLogLevel

    SetLogLevel(-1)
    config = read_json(CONFIG_PATH)
    lang = language(config)
    model_dir = os.path.join(SUPPORT_DIR, "models", MODELS[lang])
    table = phrases(config, lang)
    device = config.get("listener_device")  # part of an input's name; the system's default input otherwise
    microphone = sd.query_devices(device, "input")
    rate = int(microphone["default_samplerate"])
    if not device:
        follow_default_input(microphone["name"])
    model = Model(model_dir)
    recognizer = KaldiRecognizer(model, rate, json.dumps(list(table) + ["[unk]"], ensure_ascii=False))
    recognizer.SetWords(True)
    free = KaldiRecognizer(model, rate)  # the same audio, without the grammar: what was really said
    free.SetWords(True)
    free.SetPartialWords(True)
    free_words = []  # its recent words, with their times in the stream (the same clock as the grammar's)
    audio = queue.Queue()
    last = (None, 0.0)
    log(f"listening on {microphone['name']} ({lang}, {rate} Hz): {', '.join(sorted(table))}")
    with sd.RawInputStream(samplerate=rate, blocksize=rate // 4, device=device, dtype="int16", channels=1,
                           callback=lambda data, frames, when, status: audio.put(bytes(data))):
        pending_stop = None  # when a "Stop" was heard, waiting for the silence that confirms it

        def free_text(start, end):
            """What free recognition wrote while the command was said: a video talking before or after does not count."""
            current = json.loads(free.PartialResult()).get("partial_result") or []
            return " ".join(w["word"] for w in free_words + current
                            if w["end"] >= start - FREE_MARGIN_SECONDS and w["start"] <= end + FREE_MARGIN_SECONDS)

        while True:
            chunk = audio.get()
            if free.AcceptWaveform(chunk):
                free_words.extend(json.loads(free.Result()).get("result") or [])
                del free_words[:-200]
            if not recognizer.AcceptWaveform(chunk):
                if pending_stop and json.loads(recognizer.PartialResult()).get("partial"):
                    log('"stop": ignored, speech went on after it')
                    pending_stop = None
                elif pending_stop and time.time() - pending_stop[0] >= STOP_SILENCE_SECONDS:
                    said = free_text(*pending_stop[1:])
                    pending_stop = None
                    if not confirmed("stop", said):
                        log(f'"stop": ignored, heard as "{said}"')
                        continue
                    last = ("stop", time.time())
                    chime(config)
                    log('"stop": stop')
                    run("stop")
                continue
            result = json.loads(recognizer.Result())
            heard = result.get("text", "")
            if pending_stop and heard:
                log('"stop": ignored, speech went on after it')
                pending_stop = None
            if not heard or heard == "[unk]":
                continue
            words = result.get("result") or []
            found = isolated_command(words, table)
            if found:
                heard, start, end = found
            else:
                start, end = (words[0]["start"], words[-1]["end"]) if words else (0.0, 0.0)
            command, why = decide(heard, read_json(STATE_PATH), table)
            if not command:
                if config.get("listener_log"):
                    log(f'"{heard}": ignored, {why}')
                continue
            if last[0] == command and time.time() - last[1] < REPEAT_SECONDS:
                continue
            said = free_text(start, end)
            if command != "stop" and not confirmed(normalize(heard), said):
                log(f'"{heard}": ignored, heard as "{said}"')
                continue
            if command == "stop":
                pending_stop = (time.time(), start, end)
                continue
            last = (command, time.time())
            chime(config)
            log(f'"{heard}": {command}')
            run(command)


def main():
    if len(sys.argv) > 3 and sys.argv[1] == "--check-free":
        # A command phrase and a free transcription: whether they agree.
        print("yes" if confirmed(normalize(sys.argv[2]), sys.argv[3]) else "no")
        return
    if len(sys.argv) > 2 and sys.argv[1] == "--check-words":
        # Words as [[word, start, end], ...]: the phrase silence sets apart, or none.
        config = read_json(CONFIG_PATH)
        words = [{"word": w, "start": a, "end": b} for w, a, b in json.loads(sys.argv[2])]
        found = isolated_command(words, phrases(config, language(config)))
        print(found[0] if found else "none")
        return
    if len(sys.argv) > 2 and sys.argv[1] == "--check":
        config = read_json(CONFIG_PATH)
        command, why = decide(sys.argv[2], read_json(STATE_PATH), phrases(config, language(config)))
        print(command or f"none: {why}")
        return
    listen()


if __name__ == "__main__":
    main()
