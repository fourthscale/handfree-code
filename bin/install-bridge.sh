#!/bin/sh
# The bridge for cloud sessions, on this Mac: its keys, its service, and the tunnel's service when a command is set.
# Any tunnel provider works: the bridge listens on 127.0.0.1, the tunnel gives it a public address.
#   sh install-bridge.sh              keys made if missing, the bridge (re)started, the tunnel's service set from
#                                     `tunnel_command` (run at login when set, removed when empty)
#   sh install-bridge.sh --new-keys   new keys first (one leaked): give them again to the provider and to claude.ai
#   sh install-bridge.sh --check      does the public address (`bridge_url`) reach this bridge? Exits 0 when it does
#   sh install-bridge.sh --uninstall  removes both services (the keys stay)
# The Handfree Code app (Settings > Cloud sessions) and /handfree-code:bridge run it from the stable copy.
set -eu
SOURCE=$(cd "$(dirname "$0")" && pwd)
STABLE="$HOME/Library/Application Support/handfree-code"
CONFIG=${HANDFREE_CONFIG:-$HOME/.config/handfree-code.json}
[ -n "${HANDFREE_CONFIG:-}" ] || [ -e "$CONFIG" ] || [ ! -e "$HOME/.config/claude-speak.json" ] || CONFIG="$HOME/.config/claude-speak.json" # before 0.3.2
AGENTS=${HANDFREE_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}
BRIDGE=com.handfree-code.bridge
TUNNEL=com.handfree-code.tunnel
DOMAIN="gui/$(id -u)"

setting() {
  /usr/bin/python3 - "$CONFIG" "$1" <<'EOF'
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2]) or "")
except (OSError, ValueError):
    print("")
EOF
}

# Exit codes, which the app shows in its own words: 0 reached, 2 not set up, 3 unreachable, 4 refused by the provider,
# 5 token refused, 6 another server.
check() {
  url=$(setting bridge_url)
  token=$(setting bridge_token)
  key=$(setting bridge_edge_key)
  [ -n "$token" ] || { echo "No bridge yet: run this script without --check first."; exit 2; }
  [ -n "$url" ] || { echo "No public address: set bridge_url to the tunnel's address."; exit 2; }
  # The keys go to curl on its standard input, not on its command line, where any process could read them.
  answer=$({ printf 'Authorization: Bearer %s\n' "$token"; [ -z "$key" ] || printf 'X-Handfree-Key: %s\n' "$key"; } |
    curl -s -m 15 -w '\n%{http_code}' -X POST -H @- "${url%/}/ping" 2>/dev/null || true)
  code=$(printf '%s\n' "$answer" | tail -n 1)
  body=$(printf '%s\n' "$answer" | sed '$d')
  case "$code" in
    200) [ "$body" != handfree-bridge ] || { echo "The public address reaches this Mac's bridge."; exit 0; } ;;
    000 | "") echo "The public address cannot be reached: is the tunnel running, and the address right?"; exit 3 ;;
    # The provider is there, the tunnel is not (Cloudflare says 530).
    502 | 503 | 504 | 530) echo "The provider answers but cannot reach the tunnel (HTTP $code): is the tunnel running on this Mac?"; exit 3 ;;
    403) echo "The tunnel provider refuses the request: check its rule on the X-Handfree-Key header."; exit 4 ;;
    401) echo "A bridge answered but refused the token: another Mac's, or this one not restarted since new keys."; exit 5 ;;
  esac
  echo "The address answers (HTTP $code), but not as this bridge: is the tunnel pointed at 127.0.0.1:$(setting bridge_port | sed 's/^$/8765/')?"
  exit 6
}

# A login agent, written with plistlib: a tunnel command may hold any character.
write_agent() {
  label=$1
  log=$2
  shift 2
  /usr/bin/python3 - "$AGENTS/$label.plist" "$label" "$HOME/Library/Logs/$log" "$@" <<'EOF'
import plistlib, sys
path, label, log, arguments = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
with open(path, "wb") as f:
    plistlib.dump({
        "Label": label, "ProgramArguments": arguments, "RunAtLoad": True, "KeepAlive": True,
        "StandardOutPath": log, "StandardErrorPath": log,
        # Homebrew's programs (cloudflared, ngrok…) are found as in a terminal.
        "EnvironmentVariables": {"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"},
    }, f)
EOF
}

# launchd takes a moment to let a service go: bootstrapping it again at once fails ("Input/output error").
restart_agent() {
  launchctl bootout "$DOMAIN/$1" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print "$DOMAIN/$1" >/dev/null 2>&1 || break
    sleep 0.5
  done
  for attempt in 1 2 3; do
    launchctl bootstrap "$DOMAIN" "$AGENTS/$1.plist" 2>/dev/null && return 0
    sleep 1
  done
  echo "Could not start $1: see launchctl print $DOMAIN/$1" >&2
  return 1
}

case "${1:-}" in
  --check) check ;;
  --uninstall)
    for label in $BRIDGE $TUNNEL; do
      launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
      rm -f "$AGENTS/$label.plist"
    done
    echo "The bridge and the tunnel's service are removed. The keys stay in $CONFIG."
    exit 0
    ;;
esac

mkdir -p "$STABLE" "$(dirname "$CONFIG")" "$AGENTS" "$HOME/Library/Logs"
# handfree.js reads voice-commands.json next to it.
# The scripts the bridge runs, copied by the plugin's own list (handfree.js STABLE_FILES).
[ "$SOURCE" = "$STABLE" ] || osascript -l JavaScript "$SOURCE/handfree.js" --refresh-stable-copy >/dev/null

/usr/bin/python3 - "$CONFIG" "${1:-}" <<'EOF'
import json, os, secrets, sys
path, option = sys.argv[1], sys.argv[2]
try:
    config = json.load(open(path, encoding="utf-8"))
except (OSError, ValueError):
    config = {}
keys = ("bridge_token", "bridge_edge_key")
made = [key for key in keys if option == "--new-keys" or not config.get(key)]
for key in made:
    config[key] = secrets.token_urlsafe(32)
if made:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
    os.chmod(path, 0o600)
    print("New keys written to " + path + ": " + ", ".join(made))
else:
    print("Keeping the keys already in " + path)
EOF

# The old service is let go first: it holds the port, and reads its keys only when it starts.
write_agent $BRIDGE handfree-bridge.log /usr/bin/python3 "$STABLE/bridge-server.py"
restart_agent $BRIDGE
echo "Bridge running on 127.0.0.1:$(setting bridge_port | sed 's/^$/8765/')."

command=$(setting tunnel_command)
if [ -n "$command" ]; then
  write_agent $TUNNEL handfree-tunnel.log /bin/sh -c "$command"
  restart_agent $TUNNEL
  echo "Tunnel service running: $command"
else
  launchctl bootout "$DOMAIN/$TUNNEL" 2>/dev/null || true
  rm -f "$AGENTS/$TUNNEL.plist"
  echo "No tunnel command: the tunnel runs on its own (its provider's service), or is still to set up."
fi
echo "Next: the public address (bridge_url), then the values for claude.ai: Handfree Code > Settings > Cloud sessions."
