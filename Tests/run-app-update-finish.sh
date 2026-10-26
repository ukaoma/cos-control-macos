#!/bin/zsh
# 0.5.322: the update can no longer strand Control on Installing. Every compile goes through Tests/compile-guard.sh, one
# at a time.
#   run-app-update-finish.sh [<cos-control-helper>]   the gate: the wiring pins (Python), then the whole app compiled with
#                                                      Tests/AppUpdateFinishWiring.swift, run AS a bundle's executable
#                                                      against a stand-in helper (Finish installing, the install ending on
#                                                      the swap's give-up) and the real helper (the Mac recording state).
#                                                      Tests/run.sh passes the helper it built; alone, this builds one.
#   COS_APP_UPDATE_FINISH_LANE=pins|wiring run-app-update-finish.sh [helper]   one lane (Tests/mutate-app-update-escalation.py)
# The binary carries this build's version and build (Resources/Info.plist), runs with a scratch home, never reaches the
# appcast, the server or the real Control, never orders a window in and never becomes the active app. Any quit it asks
# for is refused by its own delegate, and the last line must be its PASS.
set -euo pipefail
ROOT="${0:A:h:h}"
LANE="${COS_APP_UPDATE_FINISH_LANE:-all}"
HELPER="${1:-}"
DIR="$(mktemp -d /tmp/cos-update-finish.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT

if [[ "$LANE" == "all" || "$LANE" == "pins" ]]; then
  /usr/bin/python3 "$ROOT/Tests/app-update-finish-pins.py" "$ROOT"
fi
[[ "$LANE" == "all" || "$LANE" == "wiring" ]] || exit 0

mkdir -p "$DIR/home" "$DIR/fake"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist")"
cat > "$DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.gotcos.control.update-finish-checks</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
</dict></plist>
PLIST
PLIST_FLAGS=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$DIR/Info.plist")
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
SWIFTC=(swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete)
APP="$DIR/Live/COS Control.app"
mkdir -p "$APP/Contents/MacOS"
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" -parse-as-library "${SOURCES[@]}" "$ROOT/Tests/AppUpdateFinishWiring.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement "${PLIST_FLAGS[@]}" -o "$APP/Contents/MacOS/COS Control"
if [[ -z "$HELPER" ]]; then
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" \
    "$ROOT/HelperSources/main.swift" "$ROOT/HelperSources/ProviderStatusCore.swift" "$ROOT/HelperSources/PairingCore.swift" "$ROOT/HelperSources/SessionUsageCollector.swift" "$ROOT/Sources/SessionUsageCore.swift" "$ROOT/Sources/WorkSessionLinks.swift" \
    -framework Security -framework AppKit -o "$DIR/cos-control-helper"
  HELPER="$DIR/cos-control-helper"
fi
# The stand-in: every call is logged; staged-app-update answers staged.json (else nothing staged); apply-app-update says
# detached only while apply-ok exists, else refuses the way the real one does when the staged app is gone.
cat > "$DIR/fake/helper" <<'SH'
#!/bin/sh
D="$(cd "$(dirname "$0")" && pwd)"
echo "$*" >> "$D/args.log"
case "$1" in
  staged-app-update)
    if [ -f "$D/staged.json" ]; then cat "$D/staged.json"; printf '\n'
    else printf '{"ok":true,"message":"No staged Control update","details":{"reason":"none"}}\n'; fi ;;
  apply-app-update)
    if [ -f "$D/apply-ok" ]; then printf '{"ok":true,"message":"detached","details":{"pid":1}}\n'
    else printf '{"ok":false,"message":"The staged update is missing.","details":{}}\n'; exit 1; fi ;;
  *)
    printf '{"ok":false,"message":"the stand-in does not answer %s","details":{}}\n' "$1"
    exit 1 ;;
esac
SH
chmod +x "$DIR/fake/helper"
OUT="$(env CFFIXED_USER_HOME="$DIR/home" HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home" "$APP/Contents/MacOS/COS Control" check "$DIR/fake/helper" "$HELPER")" || { print -r -- "$OUT"; exit 1; }
print -r -- "$OUT"
[[ "$OUT" == *"PASS: Finish installing wiring"* ]] || { print -u2 "the Finish installing wiring checks did not finish"; exit 1; }
