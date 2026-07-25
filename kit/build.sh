#!/bin/bash
# Dictate — build the app on THIS machine. Creates a local self-signed identity
# once ("Dictate Dev"), compiles the Swift shell, assembles Dictate.app, signs it.
# Locally-built = never quarantined, so no notarization needed.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CN="Dictate Dev"
BUNDLE_ID="com.dictate.voice"
APP="$HERE/build/Dictate.app"

# One-time stable signing identity (TCC permissions key off it — never delete it).
if ! security find-certificate -c "$CN" >/dev/null 2>&1; then
  echo "[cert] creating self-signed identity '$CN' (one-time)"
  TMP=$(mktemp -d)
  cat > "$TMP/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CN
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF
  openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -config "$TMP/cert.conf" >/dev/null 2>&1
  openssl pkcs12 -export -out "$TMP/cert.p12" -inkey "$TMP/key.pem" \
    -in "$TMP/cert.pem" -passout pass:dictate >/dev/null 2>&1
  security import "$TMP/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P dictate -T /usr/bin/codesign >/dev/null
  # allow codesign to use the key without a password prompt
  security set-key-partition-list -S apple-tool:,apple: -s \
    -k "" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true
  rm -rf "$TMP"
else
  echo "[cert] '$CN' exists — reusing (do NOT regenerate; TCC grants depend on it)"
fi

echo "[build] swift build -c release"
cd "$HERE/shell"
swift build -c release
BIN="$HERE/shell/.build/release/WhisperDemo"
[ -x "$BIN" ] || { echo "[build] FATAL: binary not produced" >&2; exit 1; }

echo "[build] assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Dictate"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>Dictate</string>
    <key>CFBundleDisplayName</key><string>Dictate</string>
    <key>CFBundleExecutable</key><string>Dictate</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Dictate uses the microphone to transcribe your speech on this Mac. Audio never leaves your computer.</string>
</dict>
</plist>
PLIST

echo "[build] codesign with '$CN'"
codesign --force --sign "$CN" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP"
echo "[build] DONE → $APP"
