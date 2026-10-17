#!/bin/sh
# Installs the bridge service on the Mac: a secret token, then a login agent that keeps bridge-server.py running.
# Run once:   sh bin/install-bridge.sh        Remove:   sh bin/install-bridge.sh --uninstall
set -eu
SOURCE=$(cd "$(dirname "$0")" && pwd)
STABLE="$HOME/Library/Application Support/handfree-code"
CONFIG="$HOME/.config/claude-speak.json"
LABEL=com.handfree-code.bridge
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if [ "${1:-}" = --uninstall ]; then
  launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Bridge service removed. The token stays in $CONFIG."
  exit 0
fi

mkdir -p "$STABLE" "$HOME/.config" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp "$SOURCE/handfree.js" "$SOURCE/bridge-server.py" "$STABLE/"

/usr/bin/python3 - "$CONFIG" <<'EOF'
import json, os, secrets, sys
path = sys.argv[1]
try:
    config = json.load(open(path, encoding="utf-8"))
except (OSError, ValueError):
    config = {}
if not config.get("bridge_token"):
    config["bridge_token"] = secrets.token_urlsafe(32)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
    os.chmod(path, 0o600)
    print("A new bridge token was written to " + path)
else:
    print("Keeping the bridge token already in " + path)
EOF

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/python3</string><string>$STABLE/bridge-server.py</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/handfree-bridge.log</string>
</dict>
</plist>
EOF

launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Bridge service running on 127.0.0.1:$(/usr/bin/python3 -c "import json;print(json.load(open('$CONFIG')).get('bridge_port', 8765))")."
echo "Point your tunnel at it, then give the cloud environment HANDFREE_BRIDGE_URL and the token (see README)."
