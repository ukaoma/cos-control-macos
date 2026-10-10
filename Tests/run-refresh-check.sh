#!/bin/zsh
# 2026-10-09 (Miles, after the 0.5.276 gold banner): the version card is gone; the header's refresh button refreshes AND
# checks for updates, the subtitle answers, and a version stamp sits after the title. Every compile goes through
# Tests/compile-guard.sh, one at a time.
#   run-refresh-check.sh                     the gate, in order: the pins (Python), the subtitle state machine against
#                                            Models.swift alone (Tests/RefreshCheckChecks.swift), then the model with
#                                            the whole app compiled against a stand-in helper (Tests/RefreshCheckRender.swift check)
#   COS_REFRESH_CHECK_LANE=pins|models|wiring run-refresh-check.sh   one lane alone (Tests/mutate-refresh-check.py)
#   run-refresh-check.sh render <dir>        by hand: PNGs of the panel, light and dark
# The binaries carry this build's version and build (Resources/Info.plist), run with a scratch home, never reach the
# real helper, the appcast or the server, never order a window in and never become the active app.
set -euo pipefail
ROOT="${0:A:h:h}"
MODE="${1:-check}"
LANE="${COS_REFRESH_CHECK_LANE:-all}"
DIR="$(mktemp -d /tmp/cos-refresh-check.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/home" "$DIR/Fonts"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
# The lockup beside the binary (Bundle.main), so the render shows the header as the app draws it.
cp "$ROOT/Resources/"*.svg "$DIR/"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist")"
cat > "$DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.gotcos.control.refresh-check</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
</dict></plist>
PLIST
PLIST_FLAGS=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$DIR/Info.plist")
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
RUN_ENV=(CFFIXED_USER_HOME="$DIR/home" HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home")
SWIFTC=(swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete)

# A stand-in helper. Every verb is logged. check-app-update answers by "mode": uptodate, fail (the helper's refusal),
# unreachable (the feed), update (9.9.9), hold (waits up to 10 s for "release", then up to date). status answers a
# running server; anything else is refused.
fake_helper() {
  mkdir -p "$DIR/fake"
  cat > "$DIR/fake/helper" <<'FAKE'
#!/bin/sh
D="$(cd "$(dirname "$0")" && pwd)"
echo "$1" >> "$D/calls.log"
case "$1" in
  status)
    printf '{"ok":true,"message":"ok","details":{"installed":true,"running":true,"runtimeState":"managedHealthy","version":"6.66.0"}}\n' ;;
  check-app-update)
    mode="$(cat "$D/mode" 2>/dev/null)"
    if [ "$mode" = "hold" ]; then i=0; while [ ! -f "$D/release" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done; mode=uptodate; fi
    case "$mode" in
      fail) printf '{"ok":false,"message":"the stand-in refuses","details":{}}\n'; exit 1 ;;
      unreachable) printf '{"ok":true,"message":"unreachable","details":{"updateAvailable":false,"reason":"unreachable"}}\n' ;;
      update) printf '{"ok":true,"message":"Update available","details":{"updateAvailable":true,"reason":"newer","latestVersion":"9.9.9","latestBuild":999999}}\n' ;;
      *) printf '{"ok":true,"message":"COS Control is up to date","details":{"updateAvailable":false,"reason":"upToDate"}}\n' ;;
    esac ;;
  *)
    printf '{"ok":false,"message":"the stand-in does not answer %s","details":{}}\n' "$1"; exit 1 ;;
esac
FAKE
  chmod +x "$DIR/fake/helper"
}

app_binary() {
  "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" -parse-as-library "${SOURCES[@]}" "$ROOT/Tests/RefreshCheckRender.swift" \
    -framework SwiftUI -framework AppKit -framework ServiceManagement "${PLIST_FLAGS[@]}" -o "$DIR/refresh-check"
}

if [[ "$MODE" == "render" ]]; then
  OUT="${2:?usage: run-refresh-check.sh render <folder for the PNGs>}"
  app_binary
  fake_helper
  env "${RUN_ENV[@]}" "$DIR/refresh-check" render "$OUT" "$DIR/fake/helper" 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
  exit 0
fi
[[ "$MODE" == "check" ]] || { print -u2 "usage: run-refresh-check.sh [check | render <dir>]"; exit 64; }

if [[ "$LANE" == "all" || "$LANE" == "pins" ]]; then
  /usr/bin/python3 "$ROOT/Tests/refresh-check-pins.py" "$ROOT"
fi

if [[ "$LANE" == "all" || "$LANE" == "models" ]]; then
  "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" -parse-as-library "$ROOT/Sources/Models.swift" "$ROOT/Tests/RefreshCheckChecks.swift" \
    -framework AppKit -o "$DIR/refresh-check-checks"
  OUT="$(env "${RUN_ENV[@]}" "$DIR/refresh-check-checks")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  # A floor on the count: a check that silently stops running must fail this.
  COUNT="${${OUT##*subtitle, }%% checks*}"
  (( COUNT >= 25 )) || { print -u2 "refresh-check checks ran only $COUNT (expected at least 25)"; exit 1; }
fi

if [[ "$LANE" == "all" || "$LANE" == "wiring" ]]; then
  app_binary
  fake_helper
  # The last line must be the binary's own.
  OUT="$(env "${RUN_ENV[@]}" "$DIR/refresh-check" check "$DIR/fake/helper")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  [[ "$OUT" == *"PASS: refresh-check model"* ]] || { print -u2 "the refresh-check model checks did not finish"; exit 1; }
fi
