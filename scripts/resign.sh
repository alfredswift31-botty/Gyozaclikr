#!/bin/sh
# Re-sign a downloaded build with your own code-signing certificate, so macOS
# keeps the Accessibility and Screen Recording grants across updates (an
# ad-hoc signature is tied to one build; a certificate's identity is stable).
# Make the certificate once in Keychain Access › Certificate Assistant ›
# Create a Certificate, type "Code Signing", name it "Gyozaclikr Dev".
# Usage: scripts/resign.sh [/Applications/Gyozaclikr.app] ["Gyozaclikr Dev"]
set -e
APP="${1:-/Applications/Gyozaclikr.app}"
IDENTITY="${2:-Gyozaclikr Dev}"
ENT="$(mktemp -t gyozaclikr-entitlements).plist"
codesign -d --entitlements - --xml "$APP" > "$ENT"
codesign --force --deep --options runtime --entitlements "$ENT" --identifier com.gyoza.Gyozaclikr -s "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "Signed $APP as $IDENTITY. Launch it once; macOS will ask for its grants one more time, then keep them."
