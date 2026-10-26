#!/bin/bash
# Builds "Deja Do.app" into ./build and signs it.
# Usage: ./build.sh          build only
#        ./build.sh run      build, then open the app
#        ./build.sh test     run the engine's unit tests
#        ./build.sh keys     once: make the update signing key (kept in your keychain) and put its public half in Info.plist
#        ./build.sh release 0.4.0   sign with Developer ID, notarize, zip, sign the update, and publish it on GitHub
#        ./build.sh selftest build, install, then drive Calculator and a web form in Safari end to end
#                            (results in self-test.txt; SUITE=calculator, web or apps runs one of them)
#        ./build.sh watch    wait for a .selftest-request file, then run the self test; repeats until Ctrl+C
#
# Release needs the paid Apple Developer Program, a "Developer ID Application"
# certificate (Xcode › Settings › Accounts › Manage Certificates › +), and the
# notary login saved once in your keychain:
#   xcrun notarytool store-credentials dejado-notary \
#     --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID --password APP_SPECIFIC_PASSWORD
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" = "watch" ]; then
  # Lets someone working on the code remotely ask for a build and self test by
  # creating .selftest-request in this folder. Output goes to build.log.
  echo "Waiting for test requests. Leave this window open, and the mouse alone while a test runs. Ctrl+C stops."
  while true; do
    if [ -f .selftest-request ]; then
      SUITE="$(cat .selftest-request 2>/dev/null | tr -d '[:space:]')"
      export SUITE
      rm -f .selftest-request .selftest-done
      echo "$(date '+%H:%M:%S') building and running the self test"
      if ./build.sh selftest > build.log 2>&1; then RESULT=passed; else RESULT=failed; fi
      echo "$(date '+%H:%M:%S') $RESULT"
      echo "$RESULT" > .selftest-done
    fi
    sleep 2
  done
fi

if [ "${1:-}" = "test" ]; then
  swift test
  exit 0
fi

# Sparkle's tools come with the package once it has been fetched.
sparkle_tool() {
  swift package resolve >/dev/null 2>&1 || true
  find .build/artifacts -type f -name "$1" -perm -u+x 2>/dev/null | head -1
}

if [ "${1:-}" = "keys" ]; then
  # The private key never leaves your login keychain. Anyone with it could push
  # an update to everyone, so don't export it unless you're moving Macs.
  GEN="$(sparkle_tool generate_keys)"
  [ -n "$GEN" ] || { echo "Couldn't find Sparkle's generate_keys. Run ./build.sh once first." >&2; exit 1; }
  "$GEN" >/dev/null 2>&1 || true
  PUB="$("$GEN" -p 2>/dev/null | tail -1 | tr -d '[:space:]')"
  [ -n "$PUB" ] || { echo "generate_keys didn't give a public key." >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUB" Support/Info.plist
  echo "Update key ready. Public key saved in Support/Info.plist: $PUB"
  exit 0
fi

if [ "${1:-}" = "release" ] && [ -n "${2:-}" ]; then
  # The version people see, and a build number that always goes up.
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $2" Support/Info.plist
  BUILD_NO="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Support/Info.plist)"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((BUILD_NO + 1))" Support/Info.plist
fi

swift build -c release --product DejaDo
BIN="$(swift build -c release --show-bin-path)/DejaDo"

APP="build/Deja Do.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DejaDo"
cp Support/Info.plist "$APP/Contents/Info.plist"

# Sparkle, for updates. SwiftPM puts the framework next to the binary.
FW_SRC="$(dirname "$BIN")/Sparkle.framework"
[ -d "$FW_SRC" ] || FW_SRC="$(find .build -type d -name Sparkle.framework -path '*macos*' 2>/dev/null | head -1)"
if [ -d "$FW_SRC" ]; then
  mkdir -p "$APP/Contents/Frameworks"
  ditto "$FW_SRC" "$APP/Contents/Frameworks/Sparkle.framework"
else
  echo "Sparkle.framework wasn't found; the app won't be able to update itself." >&2
fi

# Signs Sparkle's helpers from the inside out, then the app itself. --deep is
# avoided on purpose: it signs everything the same way, which Sparkle's
# installer and downloader don't want.
sign_app() {
  local id="$1"; shift
  local fw="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  if [ -d "$fw" ]; then
    codesign --force "$@" --sign "$id" "$fw/XPCServices/Installer.xpc"
    codesign --force "$@" --preserve-metadata=entitlements --sign "$id" "$fw/XPCServices/Downloader.xpc"
    codesign --force "$@" --sign "$id" "$fw/Autoupdate"
    codesign --force "$@" --sign "$id" "$fw/Updater.app"
    codesign --force "$@" --sign "$id" "$APP/Contents/Frameworks/Sparkle.framework"
  fi
  codesign --force "$@" --sign "$id" --identifier com.douglasbyfield.dejado "$APP"
}

# macOS ties Accessibility and Input Monitoring permission to the signature.
# With a real certificate the permission survives rebuilds. Ad hoc signing
# works too, but you have to re-tick the permissions after every build.
if [ "${1:-}" = "release" ]; then
  DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Developer ID Application[^"]*"' | tr -d '"' || true)"
  if [ -z "$DEV_ID" ]; then
    echo "No Developer ID Application certificate found. It comes with the paid Apple Developer Program." >&2
    exit 1
  fi
  if [ -z "$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' Support/Info.plist 2>/dev/null)" ]; then
    echo "No update key yet. Run ./build.sh keys once first, so people can get later versions." >&2
    exit 1
  fi
  echo "Signing for release with: $DEV_ID"
  # Notarization needs the hardened runtime and a secure timestamp.
  sign_app "$DEV_ID" --options runtime --timestamp
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

  # The update feed: one entry, signed with the update key from your keychain.
  BUILD_NO="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Support/Info.plist)"
  SIGN_UPDATE="$(sparkle_tool sign_update)"
  [ -n "$SIGN_UPDATE" ] || { echo "Couldn't find Sparkle's sign_update." >&2; exit 1; }
  SIG="$("$SIGN_UPDATE" "$ZIP")"
  TAG="v$VERSION"
  URL="https://github.com/Dougsworth/Deja-Do/releases/download/$TAG/$(basename "$ZIP")"
  cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Deja Do</title>
    <item>
      <title>Deja Do $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD_NO</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure url="$URL" $SIG type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
  echo "Ready to send: $ZIP"
  if command -v gh >/dev/null 2>&1; then
    NOTES="${NOTES:-Deja Do $VERSION}"
    gh release create "$TAG" "$ZIP" build/appcast.xml --repo Dougsworth/Deja-Do --title "Deja Do $VERSION" --notes "$NOTES"
    echo "Published $TAG. Copies already out there will offer it within a day, or from Check for Updates."
  else
    echo "To publish: make a GitHub release called $TAG and attach $ZIP and build/appcast.xml."
  fi
  exit 0
fi

SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Apple Development[^"]*"' | tr -d '"' || true)}"
if [ -n "$SIGN_ID" ]; then
  echo "Signing with: $SIGN_ID"
  sign_app "$SIGN_ID"
else
  echo "No Apple Development certificate found, signing ad hoc."
  sign_app -
fi

echo "Built $APP"
if [ "${1:-}" = "run" ] || [ "${1:-}" = "selftest" ]; then
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
  if [ "${1:-}" = "selftest" ]; then
    OUT="$PWD/self-test.txt"
    rm -f "$OUT"
    # SUITE=calculator or SUITE=web runs one suite; the default runs both.
    echo "Running the self test. Don't touch the mouse or keyboard for a few minutes."
    open -W -n "$DEST/Deja Do.app" --args --self-test "$OUT" ${SUITE:+--suite "$SUITE"} || true
    cat "$OUT" 2>/dev/null || echo "No results were written. Check that Deja Do has Accessibility and Input Monitoring."
    grep -q "ALL PASSED" "$OUT" 2>/dev/null
    exit $?
  fi
  open "$DEST/Deja Do.app"
fi
