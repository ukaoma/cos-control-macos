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
DIST_DIR="${COS_BUILD_DIST_DIR:-$ROOT/dist}"
APP="$BUILD_DIR/COS Control.app"
ZIP="$DIST_DIR/COS-Control-macOS-arm64-$VERSION.zip"
STAGED_ZIP="$BUILD_DIR/COS-Control-macOS-arm64-$VERSION.zip"

trap 'rm -rf "$BUILD_DIR"' EXIT

# 0.5.253 (Miles, 2026-09-30: "I really just want to remove the test click effect that was creating the noise."): no test
# drives the UI or touches the desktop (Tests/desktop-safety-check.py, with its self-test), checked before anything is built.
/usr/bin/python3 "$ROOT/Tests/desktop-safety-check.py" "$ROOT"
/usr/bin/python3 "$ROOT/Tests/desktop-safety-check.py" "$ROOT" --selftest
# 0.5.254: a build whose Work board rebuilds itself on a resize is not released (Tests/run-work-board-perf.sh; counts,
# never milliseconds).
"$ROOT/Tests/run-work-board-perf.sh" --gate

rm -rf "$ZIP" "$ZIP.sha256"
mkdir -p "$BUILD_DIR" "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST_DIR"

"$ROOT/Tests/compile-guard.sh" swiftc -target "$TARGET" -swift-version 6 -strict-concurrency=complete \
  "$ROOT/HelperSources/main.swift" "$ROOT/HelperSources/ProviderStatusCore.swift" "$ROOT/HelperSources/PairingCore.swift" \
  -framework Security -framework AppKit \
  -o "$APP/Contents/Resources/cos-control-helper"

"$ROOT/Tests/compile-guard.sh" swiftc -target "$TARGET" -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" \
  "$ROOT/Sources/HelperClient.swift" \
  "$ROOT/Sources/ControllerModel.swift" \
  "$ROOT/Sources/COSBrand.swift" \
  "$ROOT/Sources/COSMotion.swift" \
  "$ROOT/Sources/COSConfirm.swift" \
  "$ROOT/Sources/Views.swift" \
  "$ROOT/Sources/ActivityWindow.swift" \
  "$ROOT/Sources/ActivityMeetings.swift" \
  "$ROOT/Sources/COSMarkdownParser.swift" "$ROOT/Sources/COSMarkdown.swift" \
  "$ROOT/Sources/SessionLiveFeed.swift" \
  "$ROOT/Sources/SessionPet.swift" \
  "$ROOT/Sources/Control2Foundation.swift" "$ROOT/Sources/WorkHandoffStore.swift" "$ROOT/Sources/WorkProgress.swift" "$ROOT/Sources/WorkCardFiles.swift" "$ROOT/Sources/WorkProgressTracker.swift" "$ROOT/Sources/WorkTrackingViews.swift" "$ROOT/Sources/WorkHandoffView.swift" "$ROOT/Sources/WorkReviewStore.swift" "$ROOT/Sources/WorkWorkspaceView.swift" "$ROOT/Sources/PermissionGuideModel.swift" "$ROOT/Sources/PermissionGuideSystem.swift" "$ROOT/Sources/PermissionFlowVendored.swift" "$ROOT/Sources/PermissionDragFlow.swift" "$ROOT/Sources/PermissionGuideViews.swift" "$ROOT/Sources/ProviderConnectModel.swift" "$ROOT/Sources/ProviderConnectViews.swift" \
  "$ROOT/Sources/ControlSetup.swift" \
  "$ROOT/Sources/COSControlApp.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement \
  -o "$APP/Contents/MacOS/COS Control"

cp "$ROOT/Resources/whisper-runtime.json" "$APP/Contents/Resources/"
# 2026-10-09: this build's own What's New, shown once after an update when the appcast has moved on (used only when
# its "version" is this build's; WhatsNewAfterUpdate.bundledWhatsNew).
cp "$ROOT/Resources/WhatsNew.json" "$APP/Contents/Resources/"
cp -R "$ROOT/Resources/VoiceBenchmark" "$APP/Contents/Resources/"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/COSMark.svg" "$APP/Contents/Resources/COSMark.svg"
# Platform marks for the agent rows. A missing file renders NOTHING, so
# the contract loads and rasterizes each one.
cp "$ROOT/Resources/mark-"*.svg "$APP/Contents/Resources/"
cp "$ROOT/Resources/COSLockup.svg" "$APP/Contents/Resources/COSLockup.svg"
# Third-party licenses (PermissionFlow, MIT) travel with the code that uses them.
mkdir -p "$APP/Contents/Resources/ThirdParty"
cp -R "$ROOT/Resources/ThirdParty/." "$APP/Contents/Resources/ThirdParty/"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/ThirdParty/THIRD_PARTY_NOTICES.md"
mkdir -p "$APP/Contents/Resources/Fonts"
cp "$ROOT/Resources/Fonts/"*.ttf "$APP/Contents/Resources/Fonts/"
# The shipped character, already processed. A fresh install seeds it once.
# The Memories tab hosts the reviewed prototype on live data (0.5.191).
mkdir -p "$APP/Contents/Resources/memories"
cp "$ROOT/Resources/memories/memories.html" "$ROOT/Resources/memories/memories-app.js" "$ROOT/Resources/memories/memory-workspace.js" "$ROOT/Resources/memories/memory-stewardship.js" "$ROOT/Resources/memories/graph-explorer.js" "$ROOT/Resources/memories/memories-theme.css" "$ROOT/Resources/memories/graph-explorer.css" "$ROOT/Resources/memories/d3.min.js" "$APP/Contents/Resources/memories/"
mkdir -p "$APP/Contents/Resources/DefaultPet"
cp -R "$ROOT/Resources/StarterPet" "$APP/Contents/Resources/StarterPet"
cp "$ROOT/Resources/DefaultPet/"*.png "$ROOT/Resources/DefaultPet/"*.json "$APP/Contents/Resources/DefaultPet/"
# Additional processed characters live under one copied resource root. The
# Swift registry chooses them by stable ID; adding one never needs another
# packaging branch.
if [ -d "$ROOT/Resources/BundledCharacters" ]; then
  mkdir -p "$APP/Contents/Resources/BundledCharacters"
  cp -R "$ROOT/Resources/BundledCharacters/." "$APP/Contents/Resources/BundledCharacters/"
fi
python3 "$ROOT/scripts/prepare-node-runtime.py" "$APP/Contents/Resources/BundledNode"
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
APP_ENTITLEMENTS="$ROOT/Resources/COSControl.entitlements"
/usr/bin/plutil -lint "$APP_ENTITLEMENTS" >/dev/null
if [ -n "$SIGN_ID" ]; then
  /usr/bin/codesign --force --options runtime --timestamp --entitlements "$ROOT/Resources/Node.entitlements" --sign "$SIGN_ID" "$APP/Contents/Resources/BundledNode/bin/node"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP/Contents/Resources/cos-control-helper"
  # 0.5.267: the main executable and the bundle carry COSControl.entitlements (Apple Events only). Hardened runtime
  # without com.apple.security.automation.apple-events silently refuses every Apple Event, so 0.5.266's jump-to-session
  # reopen (NSAppleScript) and Guided Setup's Terminal script (osascript child) could not work. The helper gets none.
  /usr/bin/codesign --force --options runtime --timestamp --entitlements "$APP_ENTITLEMENTS" --sign "$SIGN_ID" "$APP/Contents/MacOS/COS Control"
  /usr/bin/codesign --force --options runtime --timestamp --entitlements "$APP_ENTITLEMENTS" --sign "$SIGN_ID" "$APP"
elif [ -n "$LOCAL_SIGN_ID" ]; then
  /usr/bin/codesign --force --sign "$LOCAL_SIGN_ID" "$APP/Contents/Resources/BundledNode/bin/node"
  # 0.5.217: sign the helper with an explicit identity-based designated requirement.
  # A --deep sign left the nested helper on a cdhash requirement, so every rebuild
  # re-prompted for Documents access and the status probe blocked inside the prompt.
  LOCAL_ROOT_HASH="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/grep -F "\"$LOCAL_SIGN_ID\"" | /usr/bin/awk '{print $2}' | /usr/bin/head -1)"
  if [ -z "$LOCAL_ROOT_HASH" ]; then echo "Could not resolve the certificate hash for \"$LOCAL_SIGN_ID\"" >&2; exit 68; fi
  # The requirement rides in a file: `-r=` treats a leading '=' as a syntax error.
  HELPER_REQ="$(mktemp /tmp/cos-control-helper-req.XXXXXX)"
  printf 'designated => identifier "cos-control-helper" and certificate root = H"%s"\n' "$LOCAL_ROOT_HASH" > "$HELPER_REQ"
  /usr/bin/csreq -r "$HELPER_REQ" -t >/dev/null || { echo "helper requirement did not parse" >&2; exit 70; }
  /usr/bin/codesign --force --sign "$LOCAL_SIGN_ID" -r "$HELPER_REQ" "$APP/Contents/Resources/cos-control-helper"
  rm -f "$HELPER_REQ"
  /usr/bin/codesign --force --entitlements "$APP_ENTITLEMENTS" --sign "$LOCAL_SIGN_ID" "$APP/Contents/MacOS/COS Control"
  /usr/bin/codesign --force --entitlements "$APP_ENTITLEMENTS" --sign "$LOCAL_SIGN_ID" "$APP"
  if /usr/bin/codesign -d -r- "$APP/Contents/Resources/cos-control-helper" 2>&1 | /usr/bin/grep -q 'designated => cdhash'; then
    echo "helper designated requirement fell back to cdhash; Documents access would re-prompt on every update" >&2; exit 69
  fi
else
  /usr/bin/codesign --force --deep --sign - "$APP"
fi
/usr/bin/codesign --verify --deep --strict "$APP"
# TCC (Accessibility) is keyed to the DESIGNATED REQUIREMENT. If we signed with
# a real identity, that requirement must be certificate-based; a bare cdhash
# means the signature silently fell back to ad-hoc and every installed grant
# would be stranded on update. Fail the BUILD, not a later test run.
if [ -n "$SIGN_ID" ] || [ -n "$LOCAL_SIGN_ID" ]; then
  if /usr/bin/codesign -d -r- "$APP" 2>&1 | /usr/bin/sed -n 's/.*designated => //p' \
     | /usr/bin/grep -q 'cdhash'; then
    echo "Refusing to ship: designated requirement is a per-build cdhash (ad-hoc). Installing this would strand every Accessibility grant." >&2
    exit 68
  fi
fi
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
  # 0.5.269: the FINAL archive carries no extended attributes or resource forks. With them, ditto writes an inline
  # "._name" AppleDouble entry for every file (com.apple.provenance is on all of them). Archive Utility, which a
  # double-click on a browser download uses, folds those back into attributes for regular files but cannot for the
  # three BundledNode/bin symlinks (npm, npx, corepack), so it leaves ._npm, ._npx and ._corepack inside the bundle.
  # Files added after signing break the seal and macOS says the app "is damaged" (0.5.263 to 0.5.268, every browser
  # download; the in-app updater extracts with ditto and was unaffected). The stapled ticket is a file
  # (Contents/CodeResources), not an attribute, so nothing the signature or Gatekeeper needs is dropped; the deep
  # codesign check on the extracted copy below proves it.
  /usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$APP" "$STAGED_ZIP"
else
  /usr/bin/ditto -c -k --norsrc --keepParent "$APP" "$STAGED_ZIP"
fi
/bin/mv "$STAGED_ZIP" "$ZIP"
# 0.5.269: refuse an archive that carries AppleDouble or __MACOSX entries (see above): Archive Utility can leave
# them inside the bundle as added files, which breaks the signature for every browser download.
if /usr/bin/zipinfo -1 "$ZIP" | /usr/bin/grep -E -q '(^|/)\._|^__MACOSX/'; then
  echo "Refusing to ship: $ZIP contains AppleDouble (._*) or __MACOSX entries; Archive Utility would break the signature." >&2
  /usr/bin/zipinfo -1 "$ZIP" | /usr/bin/grep -E '(^|/)\._|^__MACOSX/' | /usr/bin/head -5 >&2
  exit 69
fi
VERIFY_DIR="$BUILD_DIR/verify"
/bin/mkdir -p "$VERIFY_DIR"
/usr/bin/ditto -x -k "$ZIP" "$VERIFY_DIR"
/usr/bin/codesign --verify --deep --strict "$VERIFY_DIR/COS Control.app"
python3 "$ROOT/Tests/check-bundled-runtime.py" "$VERIFY_DIR/COS Control.app/Contents/Resources"
if [ -n "$SIGN_ID" ]; then
  /usr/bin/xcrun stapler validate "$VERIFY_DIR/COS Control.app"
  /usr/sbin/spctl -a -vv --type execute "$VERIFY_DIR/COS Control.app"
fi
# 0.5.267: the shipped app must be able to send Apple Events (entitlement + usage string), and the helper must carry no
# entitlements at all. Checked on the app extracted from the final ZIP.
if [ -n "$SIGN_ID" ] || [ -n "$LOCAL_SIGN_ID" ]; then
  python3 "$ROOT/Tests/check-release-entitlements.py" "$VERIFY_DIR/COS Control.app"
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
