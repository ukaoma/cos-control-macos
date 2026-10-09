#!/bin/zsh
# 2026-10-09 (Miles, like Vorssant): the update-ready badge. Every compile goes through Tests/compile-guard.sh, one at a
# time.
#   run-app-update-badge.sh                the gate: the version rule, the schedule, the phases and the icon against
#                                          Models.swift alone, then the model wiring with the whole app compiled
#   run-app-update-badge.sh wiring         the model wiring alone (the mutation lane's app compile)
#   run-app-update-badge.sh render <dir>   by hand: PNGs of the banner, the panel and the menu-bar glasses
# The binaries carry this build's version and build (Resources/Info.plist), run with a scratch home, never reach the
# helper, the appcast or the server, never order a window in and never become the active app.
set -euo pipefail
ROOT="${0:A:h:h}"
MODE="${1:-check}"
DIR="$(mktemp -d /tmp/cos-update-badge.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/home" "$DIR/Fonts"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist")"
cat > "$DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.gotcos.control.update-badge-checks</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
</dict></plist>
PLIST
PLIST_FLAGS=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$DIR/Info.plist")
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
RUN_ENV=(CFFIXED_USER_HOME="$DIR/home" HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home")

if [[ "$MODE" == "check" ]]; then
  "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
    "$ROOT/Sources/Models.swift" "$ROOT/Tests/AppUpdateBadgeChecks.swift" -framework AppKit -o "$DIR/badge-checks"
  env "${RUN_ENV[@]}" "$DIR/badge-checks"
  [[ "${COS_UPDATE_BADGE_SKIP_WIRING:-}" == "1" ]] && exit 0
fi
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/AppUpdateBadgeRender.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement "${PLIST_FLAGS[@]}" -o "$DIR/badge-render"
if [[ "$MODE" == "check" || "$MODE" == "wiring" ]]; then
  # A stand-in helper: the first check-app-update waits for a release file (up to 10 s), every call is logged.
  mkdir -p "$DIR/fake"
  cat > "$DIR/fake/helper" <<'SH'
#!/bin/sh
D="$(cd "$(dirname "$0")" && pwd)"
echo "$1" >> "$D/calls.log"
n=$(grep -c . "$D/calls.log")
if [ "$n" -eq 1 ]; then i=0; while [ ! -f "$D/release" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done; fi
printf '{"ok":true,"message":"COS Control is up to date","details":{"updateAvailable":false,"reason":"upToDate"}}\n'
SH
  chmod +x "$DIR/fake/helper"
  env "${RUN_ENV[@]}" "$DIR/badge-render" check "$DIR/fake/helper"
elif [[ "$MODE" == "render" ]]; then
  OUT="${2:?usage: run-app-update-badge.sh render <folder for the PNGs>}"
  env "${RUN_ENV[@]}" "$DIR/badge-render" render "$OUT" 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
else
  print -u2 "usage: run-app-update-badge.sh [check | render <dir>]"; exit 64
fi
