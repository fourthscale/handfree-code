#!/bin/sh
# Builds the Handfree Code app on this Mac, signs it, installs it in ~/Applications and starts it with your session.
#   sh app/install.sh            build, install, (re)start
#   sh app/install.sh --remove   stop it and remove it (its models and settings stay)
# Needs Apple's developer tools (xcode-select --install): Swift builds the app here, nothing prebuilt is downloaded
# but the Swift packages it uses (WhisperKit).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
PLUGIN=$(cd "$HERE/.." && pwd)
VERSION=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PLUGIN/.claude-plugin/plugin.json")
APP="$HOME/Applications/Handfree Code.app"
LABEL=com.handfree-code.app
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ "${1:-}" = --remove ]; then
  pkill -x HandfreeCode 2>/dev/null || true
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  rm -rf "$APP" "$PLIST"
  echo "Removed."; exit 0
fi

# A signing identity of this Mac's own, made once: macOS then keeps the app's permissions (microphone, accessibility)
# from one build to the next. Without it each build is a new app to macOS and asks again.
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# The identity of the app already installed, when this Mac still has it: another one would be a new app to macOS.
INSTALLED=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)
if [ -n "$INSTALLED" ] && security find-identity -v -p codesigning "$KEYCHAIN" | grep -qF "\"$INSTALLED\""; then :; else INSTALLED=""; fi
IDENTITY=${HANDFREE_SIGNING_IDENTITY:-${INSTALLED:-Handfree Code Local Signing}}
ensure_identity() {
  security find-identity -v -p codesigning "$KEYCHAIN" | grep -q "$IDENTITY" && return 0
  echo "Creating the local signing certificate \"$IDENTITY\" (once; macOS asks for your password to trust it)…"
  TMP=$(mktemp -d)
  cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
  openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/identity.p12" -passout pass:handfree
  security import "$TMP/identity.p12" -k "$KEYCHAIN" -P handfree -T /usr/bin/codesign >/dev/null
  security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
  rm -rf "$TMP"
}

BUILD="$HERE/build/Handfree Code.app"
rm -rf "$BUILD"; mkdir -p "$BUILD/Contents/MacOS"
mkdir -p "$HERE/build"
command -v xcrun >/dev/null 2>&1 && xcrun --find swift >/dev/null 2>&1 || { echo "Swift is missing: run  xcode-select --install  then this again." >&2; exit 1; }
echo "Building Handfree Code $VERSION (the first time takes a few minutes)…"
if ! (cd "$HERE" && xcrun swift build -c release > "$HERE/build/swift-build.log" 2>&1); then
  grep "error:" "$HERE/build/swift-build.log" >&2; echo "Build failed (app/build/swift-build.log)." >&2; exit 1
fi
BIN=$(cd "$HERE" && xcrun swift build -c release --show-bin-path)
[ -x "$BIN/HandfreeCode" ] || { echo "Build failed." >&2; exit 1; }
cp "$BIN/HandfreeCode" "$BUILD/Contents/MacOS/HandfreeCode"
mkdir -p "$BUILD/Contents/Resources"
for bundle in "$BIN"/*.bundle; do [ -e "$bundle" ] && cp -R "$bundle" "$BUILD/Contents/Resources/"; done
cp -R "$HERE"/Resources/*.lproj "$BUILD/Contents/Resources/"
cp "$PLUGIN/bin/mcp-relay.sh" "$BUILD/Contents/Resources/mcp-relay.sh"
cp "$PLUGIN/bin/voice-commands.json" "$BUILD/Contents/Resources/voice-commands.json"
# The icon: the halo, drawn by the app itself, at every size macOS asks for.
ICONSET="$HERE/build/AppIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
if "$BIN/HandfreeCode" --render-icon "$HERE/build/icon.png" 2>/dev/null; then
  for size in 16 32 128 256 512; do
    sips -z $size $size "$HERE/build/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$HERE/build/icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$BUILD/Contents/Resources/AppIcon.icns" || echo "The icon could not be made: the app keeps the default one."
fi
cat > "$BUILD/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Handfree Code</string>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleExecutable</key><string>HandfreeCode</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>fr</string><string>de</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Handfree Code runs the plugin's commands for its keyboard shortcuts: they find Claude's message field and the app in front through System Events.</string>
  <key>NSMicrophoneUsageDescription</key><string>Handfree Code listens to your dictation to transcribe it on this Mac.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Handfree Code transcribes your dictation with Apple's speech recognition, on this Mac.</string>
</dict></plist>
PL
echo "Signing with $IDENTITY (if macOS asks to use the key, or for the keychain's password, answer it: \"Always Allow\")…"
if ensure_identity && codesign --force --sign "$IDENTITY" "$BUILD" 2>/dev/null; then
  echo "Signed with $IDENTITY."
else
  echo "Signing with the local certificate failed: signed ad hoc (permissions asked again after each build)."
  codesign --force --sign - "$BUILD" >/dev/null 2>&1 || true
fi
# The running app is stopped only now: while the build runs, dictation and questions keep working.
pkill -x HandfreeCode 2>/dev/null || true
mkdir -p "$HOME/Applications"; rm -rf "$APP"; cp -R "$BUILD" "$APP"

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/HandfreeCode</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Handfree Code $VERSION installed and started: $APP (it starts with your session)."
