#!/usr/bin/env bash
# Local replacement for .github/workflows/release-tip.yml (macOS tip release).
# Mirrors the workflow step for step, using this Mac's keychain instead of CI secrets.
#   SKIP_NOTARIZE=1  skip notarization + stapling (dev use)
#   SKIP_UPLOAD=1    skip tag push + GitHub release upload
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
ROOT=$PWD
APP="$ROOT/macos/build/Release/Fastty.app"
OUT="$ROOT/zig-out/release"
REPO=imkarthikk/fastty
SPARKLE_VERSION=2.9.6
SPARKLE_KEY_PUB="v0xrrq9RWUKaXtBx3VvbPzbrC5cyudY86E76/M7o9tI="

T0=$SECONDS; TS=$SECONDS
step() { echo "[$(date +%T)] (+$((SECONDS - TS))s) == $*"; TS=$SECONDS; }

step "Extract build info"
export GHOSTTY_BUILD=$(git rev-list --count HEAD)
export GHOSTTY_COMMIT=$(git rev-parse --short HEAD)
export GHOSTTY_COMMIT_LONG=$(git rev-parse HEAD)
echo "build $GHOSTTY_BUILD commit $GHOSTTY_COMMIT"
IDENTITY=$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/')
echo "identity: $IDENTITY"
rm -rf "$OUT" && mkdir -p "$OUT"

step "Setup Sparkle"
SIGN_UPDATE=$(find ~/Library/Developer/Xcode/DerivedData -path '*parkle*/bin/sign_update' 2>/dev/null | head -1 || true)
if [ -z "$SIGN_UPDATE" ]; then
  SP=~/.cache/fastty/sparkle
  if [ ! -x "$SP/bin/sign_update" ]; then
    mkdir -p "$SP"
    curl -fL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-for-Swift-Package-Manager.zip" -o "$SP/sparkle.zip"
    unzip -q -o "$SP/sparkle.zip" -d "$SP"
  fi
  SIGN_UPDATE="$SP/bin/sign_update"
fi
echo "sign_update: $SIGN_UPDATE"

step "Build GhosttyKit"
ZIG=$(command -v zig || zsh -lc 'command -v zig')
"$ZIG" build -Doptimize=ReleaseFast -Demit-macos-app=false

step "Build Fastty.app"
rm -rf "$APP"  # fresh bundle so reruns do not re-sign / re-edit a stale one
(cd macos && xcodebuild -target Ghostty -configuration Release)

step "Update Info.plist"
P="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :GhosttyCommit $GHOSTTY_COMMIT" "$P"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $GHOSTTY_BUILD" "$P"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $GHOSTTY_COMMIT" "$P"
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_KEY_PUB" "$P"
/usr/libexec/PlistBuddy -c "Delete :SUEnableAutomaticChecks" "$P"

step "Codesign app bundle"
S=(/usr/bin/codesign --verbose -f -s "$IDENTITY" -o runtime --timestamp)
F="$APP/Contents/Frameworks/Sparkle.framework"
"${S[@]}" "$F/Versions/B/XPCServices/Downloader.xpc"
"${S[@]}" "$F/Versions/B/XPCServices/Installer.xpc"
"${S[@]}" "$F/Versions/B/Autoupdate"
"${S[@]}" "$F/Versions/B/Updater.app"
"${S[@]}" "$F"
"${S[@]}" "$APP/Contents/PlugIns/DockTilePlugin.plugin"
"${S[@]}" --entitlements macos/Ghostty.entitlements "$APP"

step "Create DMG"
npx --yes create-dmg "--identity=$IDENTITY" "$APP" "$OUT"
mv "$OUT"/Fastty*.dmg "$OUT/Fastty.dmg"

if [ "${SKIP_NOTARIZE:-}" != 1 ]; then
  step "Notarize DMG"
  KEY=$(umask 077; mktemp)
  trap 'rm -f "$KEY"' EXIT
  # -w prints hex when the item has newlines (PEM), so decode it.
  security find-generic-password -a fastty -s fastty-asc-notary-key -w | xxd -r -p > "$KEY"
  xcrun notarytool submit "$OUT/Fastty.dmg" --key "$KEY" \
    --key-id "$(security find-generic-password -a fastty -s fastty-asc-notary-key-id -w)" \
    --issuer "$(security find-generic-password -a fastty -s fastty-asc-notary-issuer -w)" --wait
  rm -f "$KEY"
  xcrun stapler staple "$OUT/Fastty.dmg"
  xcrun stapler staple "$APP"
fi

step "Zip App"
(cd macos/build/Release && zip -9 -q -r --symlinks "$OUT/fastty-macos-universal.zip" Fastty.app)

step "Generate Appcast"
cd "$OUT"
"$SIGN_UPDATE" --account fastty Fastty.dmg > sign_update.txt
python3 "$ROOT/dist/macos/update_appcast_tip.py"
test -f appcast_new.xml
mv appcast_new.xml appcast.xml

if [ "${SKIP_UPLOAD:-}" != 1 ]; then
  # Binaries go up before the appcast so it never points at a missing/old DMG.
  step "Release"
  git tag -f tip "$GHOSTTY_COMMIT_LONG"
  git push -f origin refs/tags/tip
  gh release view tip -R "$REPO" >/dev/null 2>&1 || gh release create tip -R "$REPO" --prerelease \
    --title 'Fastty Tip ("Nightly")' --notes "Automated build from the latest commit on main."
  gh release upload tip Fastty.dmg fastty-macos-universal.zip --clobber -R "$REPO"
  gh release upload tip appcast.xml --clobber -R "$REPO"
fi

step "Done in $((SECONDS - T0))s: $OUT"
