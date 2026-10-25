#!/bin/bash
# Builds "Deja Do.app" into ./build and signs it.
# Usage: ./build.sh          build only
#        ./build.sh run      build, then open the app
#        ./build.sh test     run the engine's unit tests
#        ./build.sh release  sign with Developer ID, notarize, and zip it to send to people
#
# Release needs the paid Apple Developer Program, a "Developer ID Application"
# certificate (Xcode › Settings › Accounts › Manage Certificates › +), and the
# notary login saved once in your keychain:
#   xcrun notarytool store-credentials dejado-notary \
#     --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID --password APP_SPECIFIC_PASSWORD
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" = "test" ]; then
  swift test
  exit 0
fi

swift build -c release --product DejaDo
BIN="$(swift build -c release --show-bin-path)/DejaDo"

APP="build/Deja Do.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DejaDo"
cp Support/Info.plist "$APP/Contents/Info.plist"

# macOS ties Accessibility and Input Monitoring permission to the signature.
# With a real certificate the permission survives rebuilds. Ad hoc signing
# works too, but you have to re-tick the permissions after every build.
if [ "${1:-}" = "release" ]; then
  DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Developer ID Application[^"]*"' | tr -d '"' || true)"
  if [ -z "$DEV_ID" ]; then
    echo "No Developer ID Application certificate found. It comes with the paid Apple Developer Program." >&2
    exit 1
  fi
  echo "Signing for release with: $DEV_ID"
  # Notarization needs the hardened runtime and a secure timestamp.
  codesign --force --options runtime --timestamp --sign "$DEV_ID" --identifier com.douglasbyfield.dejado "$APP"
  codesign --verify --deep --strict "$APP"

  VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Support/Info.plist)"
  ZIP="build/Deja-Do-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Sending to Apple for notarization. This usually takes a few minutes."
  xcrun notarytool submit "$ZIP" --keychain-profile "${NOTARY_PROFILE:-dejado-notary}" --wait
  # Attach the ticket so the app opens even without an internet connection, then zip it again.
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  spctl --assess --type execute --verbose "$APP"
  echo "Ready to send: $ZIP"
  exit 0
fi

SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Apple Development[^"]*"' | tr -d '"' || true)}"
if [ -n "$SIGN_ID" ]; then
  echo "Signing with: $SIGN_ID"
  codesign --force --sign "$SIGN_ID" --identifier com.douglasbyfield.dejado "$APP"
else
  echo "No Apple Development certificate found, signing ad hoc."
  codesign --force --sign - --identifier com.douglasbyfield.dejado "$APP"
fi

echo "Built $APP"
if [ "${1:-}" = "run" ]; then
  # Install to /Applications, where Spotlight, Launchpad and other tools look
  # first. Falls back to ~/Applications if this account can't write there.
  pkill -x DejaDo 2>/dev/null || true
  DEST="/Applications"
  [ -w "$DEST" ] || DEST="$HOME/Applications"
  mkdir -p "$DEST"
  rm -rf "$DEST/Deja Do.app"
  cp -R "$APP" "$DEST/"
  # An older copy in the other folder would show up twice in Spotlight.
  if [ "$DEST" = "/Applications" ] && [ -d "$HOME/Applications/Deja Do.app" ]; then rm -rf "$HOME/Applications/Deja Do.app"; fi
  echo "Installed to $DEST/Deja Do.app"
  open "$DEST/Deja Do.app"
fi
