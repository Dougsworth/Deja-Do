#!/bin/bash
# Builds "Deja Do.app" into ./build and signs it.
# Usage: ./build.sh          build only
#        ./build.sh run      build, then open the app
#        ./build.sh test     run the engine's unit tests
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
  # Install to ~/Applications so Spotlight and Launchpad can find it too.
  pkill -x DejaDo 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Deja Do.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "Installed to ~/Applications/Deja Do.app"
  open "$HOME/Applications/Deja Do.app"
fi
