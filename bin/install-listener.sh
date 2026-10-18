#!/bin/sh
# Installs or updates the spoken-commands listener: Vosk in a Python environment of its own, the model of your
# language, and a background service started with your session. Run it again any time: only what is missing is done.
#   sh install-listener.sh            install, or update after a plugin update (/handfree-code:listener in Claude)
#   sh install-listener.sh --remove   stop and remove the service (the environment and models stay)
# It runs from the plugin's bin/ or from the copy each session refreshes in ~/Library/Application Support/handfree-code/.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SUPPORT="$HOME/Library/Application Support/handfree-code"
VENV="$SUPPORT/listener-venv"
MODELS="$SUPPORT/models"
LABEL=com.handfree-code.listener
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/handfree-listener.log"
DOMAIN="gui/$(id -u)"

if [ "${1:-}" = --remove ]; then
  launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Listener stopped and removed. Its environment and models stay in $SUPPORT."
  exit 0
fi

/usr/bin/python3 -c "import venv" 2>/dev/null || { echo "Python 3 is missing: run  xcode-select --install  then this again." >&2; exit 1; }
mkdir -p "$SUPPORT" "$MODELS" "$HOME/Library/LaunchAgents"

if ! "$VENV/bin/python" -c "import vosk, sounddevice" 2>/dev/null; then
  echo "Installing Vosk (speech recognition, offline) in $VENV…"
  /usr/bin/python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --disable-pip-version-check vosk sounddevice
fi

[ "$HERE" = "$SUPPORT" ] || cp "$HERE/listener.py" "$SUPPORT/listener.py"
[ -f "$SUPPORT/handfree.js" ] || cp "$HERE/handfree.js" "$SUPPORT/handfree.js"

MODEL=$("$VENV/bin/python" -c 'import sys; sys.path.insert(0, sys.argv[1]); import listener as l; print(l.MODELS[l.language(l.read_json(l.CONFIG_PATH))])' "$SUPPORT" 2>/dev/null)
if [ ! -d "$MODELS/$MODEL" ]; then
  echo "Downloading the speech model $MODEL…"
  ZIP=$(mktemp -t handfree-model).zip
  curl -fsSL -o "$ZIP" "https://alphacephei.com/vosk/models/$MODEL.zip"
  unzip -q -o "$ZIP" -d "$MODELS"
  rm -f "$ZIP"
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$VENV/bin/python</string><string>$SUPPORT/listener.py</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>EnvironmentVariables</key><dict><key>PYTHONWARNINGS</key><string>ignore</string></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"

# The listener runs in Python's app: that is what macOS must allow to start Spokenly and press Return ("Stop").
PYTHON_APP=$("$VENV/bin/python" -c 'import os, sys; b = os.path.realpath(sys.executable); print(os.path.normpath(os.path.join(os.path.dirname(b), "..", "Resources", "Python.app")))')
echo "Listener running ($MODEL). Its log: $LOG"
echo
echo "One permission to give, once: System Settings > Privacy & Security > Accessibility > allow Python."
if [ -d "$PYTHON_APP" ]; then
  echo "It is this app (opened in the Finder, drag it into the list): $PYTHON_APP"
  open -R "$PYTHON_APP" || true
fi
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true
echo "The microphone: macOS asks once, or allow Python in Privacy & Security > Microphone."
echo "Then restart it:  launchctl kickstart -k $DOMAIN/$LABEL"
