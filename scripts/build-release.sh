#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
VERSION="${1:-$PLIST_VERSION}"
if [ "$VERSION" != "$PLIST_VERSION" ]; then
  echo "Release version $VERSION does not match Info.plist $PLIST_VERSION" >&2
  exit 64
fi
TARGET="arm64-apple-macosx14.0"
BUILD_DIR="$(mktemp -d /tmp/cos-control-release.XXXXXX)"
DIST_DIR="$ROOT/dist"
APP="$BUILD_DIR/COS Control.app"
ZIP="$DIST_DIR/COS-Control-macOS-arm64-$VERSION.zip"
STAGED_ZIP="$BUILD_DIR/COS-Control-macOS-arm64-$VERSION.zip"

trap 'rm -rf "$BUILD_DIR"' EXIT

rm -rf "$ZIP" "$ZIP.sha256"
mkdir -p "$BUILD_DIR" "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST_DIR"

swiftc -target "$TARGET" -swift-version 6 -strict-concurrency=complete \
  "$ROOT/HelperSources/main.swift" \
  -framework Security \
  -o "$APP/Contents/Resources/cos-control-helper"

swiftc -target "$TARGET" -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" \
  "$ROOT/Sources/HelperClient.swift" \
  "$ROOT/Sources/ControllerModel.swift" \
  "$ROOT/Sources/COSBrand.swift" \
  "$ROOT/Sources/COSMotion.swift" \
  "$ROOT/Sources/COSConfirm.swift" \
  "$ROOT/Sources/Views.swift" \
  "$ROOT/Sources/ActivityWindow.swift" \
  "$ROOT/Sources/ActivityMeetings.swift" \
  "$ROOT/Sources/SessionPet.swift" \
  "$ROOT/Sources/COSControlApp.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement \
  -o "$APP/Contents/MacOS/COS Control"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/COSMark.svg" "$APP/Contents/Resources/COSMark.svg"
# Platform marks for the agent rows. A missing file renders NOTHING, so
# the contract loads and rasterizes each one.
cp "$ROOT/Resources/mark-"*.svg "$APP/Contents/Resources/"
cp "$ROOT/Resources/COSLockup.svg" "$APP/Contents/Resources/COSLockup.svg"
mkdir -p "$APP/Contents/Resources/Fonts"
cp "$ROOT/Resources/Fonts/"*.ttf "$APP/Contents/Resources/Fonts/"
# The shipped character, already processed. A fresh install seeds it once.
mkdir -p "$APP/Contents/Resources/DefaultPet"
cp "$ROOT/Resources/DefaultPet/"*.png "$ROOT/Resources/DefaultPet/"*.json "$APP/Contents/Resources/DefaultPet/"
# Additional processed characters live under one copied resource root. The
# Swift registry chooses them by stable ID; adding one never needs another
# packaging branch.
if [ -d "$ROOT/Resources/BundledCharacters" ]; then
  mkdir -p "$APP/Contents/Resources/BundledCharacters"
  cp -R "$ROOT/Resources/BundledCharacters/." "$APP/Contents/Resources/BundledCharacters/"
fi
chmod 700 "$APP/Contents/MacOS/COS Control" "$APP/Contents/Resources/cos-control-helper"
/usr/bin/xattr -cr "$APP"
# Public releases fail closed unless both Developer ID signing and notarization
# are configured. COS_ALLOW_ADHOC=1 is an explicit local-QA escape hatch only.
# COS_SIGN_IDENTITY: "Developer ID Application: NAME (TEAMID)"
# COS_NOTARY_PROFILE: `xcrun notarytool store-credentials` profile name.
SIGN_ID="${COS_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${COS_NOTARY_PROFILE:-}"
# COS_LOCAL_SIGN_IDENTITY: a stable (self-signed) keychain identity. macOS
# keys TCC grants (Accessibility) to the designated requirement; ad-hoc
# signing changes the cdhash every build, stranding the grant while System
# Settings still shows the app enabled. A stable identity keeps the grant
# across updates. No notarization; Gatekeeper story matches ad-hoc.
LOCAL_SIGN_ID="${COS_LOCAL_SIGN_IDENTITY:-}"
ALLOW_ADHOC="${COS_ALLOW_ADHOC:-0}"
# The stable identity is ADOPTED AUTOMATICALLY when it is in the keychain, and
# it OUTRANKS the ad-hoc escape hatch. Ad-hoc re-keys the designated
# requirement every build, which strands the user's Accessibility grant while
# System Settings still shows the app enabled. That cost a debugging saga in
# 0.5.107, and again on 2026-09-01 when a QA build signed through
# release-adhoc.sh was installed over a release and broke the grant on a
# machine that already had one. Opting IN to a stable identity was the bug:
# the default must be the safe one, and ad-hoc must be unreachable while a
# stable identity exists.
LOCAL_IDENTITY_NAME="${COS_LOCAL_IDENTITY_NAME:-COS Control Local}"
if [ -z "$SIGN_ID" ] \
   && /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
      | /usr/bin/grep -qF "\"$LOCAL_IDENTITY_NAME\""; then
  if [ -z "$LOCAL_SIGN_ID" ]; then
    LOCAL_SIGN_ID="$LOCAL_IDENTITY_NAME"
    echo "Signing with the stable local identity \"$LOCAL_IDENTITY_NAME\" (adopted automatically; keeps Accessibility grants across updates)."
  fi
  if [ "$ALLOW_ADHOC" = "1" ]; then
    echo "Ignoring COS_ALLOW_ADHOC=1: \"$LOCAL_IDENTITY_NAME\" is available, and ad-hoc would strand every existing Accessibility grant." >&2
    ALLOW_ADHOC=0
  fi
fi
if [ -z "$SIGN_ID" ] && [ -z "$LOCAL_SIGN_ID" ] && [ "$ALLOW_ADHOC" != "1" ]; then
  echo "Release requires COS_SIGN_IDENTITY (public) or COS_LOCAL_SIGN_IDENTITY (stable local). COS_ALLOW_ADHOC=1 is throwaway-QA only, and only on a machine with no stable identity." >&2
  exit 66
fi
if [ -n "$SIGN_ID" ] && [ -z "$NOTARY_PROFILE" ]; then
  echo "Developer ID release requires COS_NOTARY_PROFILE for notarization." >&2
  exit 67
fi
if [ -n "$SIGN_ID" ]; then
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP/Contents/Resources/cos-control-helper"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP/Contents/MacOS/COS Control"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
elif [ -n "$LOCAL_SIGN_ID" ]; then
  /usr/bin/codesign --force --deep --sign "$LOCAL_SIGN_ID" "$APP"
else
  /usr/bin/codesign --force --deep --sign - "$APP"
fi
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/vtool -show-build "$APP/Contents/MacOS/COS Control" | /usr/bin/grep -q 'minos 14.0'
/usr/bin/vtool -show-build "$APP/Contents/Resources/cos-control-helper" | /usr/bin/grep -q 'minos 14.0'
if [ -n "$SIGN_ID" ]; then
  # Apple documents ditto --keepParent for notarization ZIPs. Preserve the
  # stapled app metadata when rebuilding the final archive.
  /usr/bin/ditto -c -k --keepParent "$APP" "$STAGED_ZIP"
  /usr/bin/xcrun notarytool submit "$STAGED_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$APP"
  /usr/bin/xcrun stapler validate "$APP"
  rm -f "$STAGED_ZIP"
  /usr/bin/ditto -c -k --keepParent "$APP" "$STAGED_ZIP"
else
  /usr/bin/ditto -c -k --norsrc --keepParent "$APP" "$STAGED_ZIP"
fi
/bin/mv "$STAGED_ZIP" "$ZIP"
VERIFY_DIR="$BUILD_DIR/verify"
/bin/mkdir -p "$VERIFY_DIR"
/usr/bin/ditto -x -k "$ZIP" "$VERIFY_DIR"
/usr/bin/codesign --verify --deep --strict "$VERIFY_DIR/COS Control.app"
if [ -n "$SIGN_ID" ]; then
  /usr/bin/xcrun stapler validate "$VERIFY_DIR/COS Control.app"
  /usr/sbin/spctl -a -vv --type execute "$VERIFY_DIR/COS Control.app"
fi
# Isolate self-test from the caller's COS_* / provider env so live harness
# variables (e.g. COS_HARNESS=foreground) cannot pollute allowlist assertions.
env -i \
  HOME="$HOME" \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" \
  TMPDIR="${TMPDIR:-/tmp}" \
  COS_CONTROL_TEST_HOME="$BUILD_DIR/test-home" \
  "$VERIFY_DIR/COS Control.app/Contents/Resources/cos-control-helper" self-test >/dev/null
if [ -z "$SIGN_ID" ] && /usr/bin/unzip -Z1 "$ZIP" | /usr/bin/grep -q '^__MACOSX/'; then
  echo "Release archive contains forbidden __MACOSX metadata" >&2
  exit 65
fi
# Relative basename in the sidecar: an absolute author path both leaks the
# local layout and breaks `shasum -c` against a downloaded copy (2026-07-27).
(cd "$DIST_DIR" && /usr/bin/shasum -a 256 "$(basename "$ZIP")" | tee "$(basename "$ZIP").sha256")

echo "Built $ZIP"
