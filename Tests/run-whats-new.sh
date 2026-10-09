#!/bin/zsh
# 2026-10-09 (Miles, 13:09, like Vorssant): the What's New window. Every compile goes through Tests/compile-guard.sh,
# one at a time.
#   run-whats-new.sh                     the gate, in order: the wiring pins (Python), the pure pieces against
#                                        Models.swift alone (Tests/WhatsNewChecks.swift), the compiled helper's
#                                        check-app-update against whatsNew fixtures (Tests/whats-new-helper-checks.py),
#                                        then the window and the install path with the whole app compiled
#                                        (Tests/WhatsNewRender.swift check, against a stand-in helper)
#   COS_WHATS_NEW_LANE=pins|models|helper|wiring run-whats-new.sh   one lane alone (Tests/mutate-whats-new.py)
#   run-whats-new.sh render <dir> [whatsNew.json]                   by hand: PNGs of the window, light and dark
# The binaries carry this build's version and build (Resources/Info.plist), run with a scratch home, never reach the
# real helper, the appcast or the server, never order a window in and never become the active app.
set -euo pipefail
ROOT="${0:A:h:h}"
MODE="${1:-check}"
LANE="${COS_WHATS_NEW_LANE:-all}"
DIR="$(mktemp -d /tmp/cos-whats-new.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/home" "$DIR/Fonts"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist")"
cat > "$DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.gotcos.control.whats-new-checks</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
</dict></plist>
PLIST
PLIST_FLAGS=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$DIR/Info.plist")
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
RUN_ENV=(CFFIXED_USER_HOME="$DIR/home" HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home")
SWIFTC=(swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete)

app_binary() {
  "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" -parse-as-library "${SOURCES[@]}" "$ROOT/Tests/WhatsNewRender.swift" \
    -framework SwiftUI -framework AppKit -framework ServiceManagement "${PLIST_FLAGS[@]}" -o "$DIR/whats-new-render"
}

if [[ "$MODE" == "render" ]]; then
  OUT="${2:?usage: run-whats-new.sh render <folder for the PNGs> [whatsNew.json]}"
  JSON="${3:-$ROOT/Tests/fixtures/whats-new/whats-new-0.5.275.json}"
  app_binary
  env "${RUN_ENV[@]}" "$DIR/whats-new-render" render "$OUT" "$JSON" 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
  exit 0
fi
[[ "$MODE" == "check" ]] || { print -u2 "usage: run-whats-new.sh [check | render <dir> [whatsNew.json]]"; exit 64; }

if [[ "$LANE" == "all" || "$LANE" == "pins" ]]; then
  /usr/bin/python3 "$ROOT/Tests/whats-new-pins.py" "$ROOT"
fi

if [[ "$LANE" == "all" || "$LANE" == "models" ]]; then
  "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" -parse-as-library "$ROOT/Sources/Models.swift" "$ROOT/Tests/WhatsNewChecks.swift" \
    -framework AppKit -o "$DIR/whats-new-checks"
  OUT="$(env "${RUN_ENV[@]}" "$DIR/whats-new-checks")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  # A floor on the count: a check that silently stops running must fail this.
  COUNT="${${OUT##*checks: }%% passed*}"
  (( COUNT >= 81 )) || { print -u2 "What's New checks ran only $COUNT (expected at least 81)"; exit 1; }
fi

if [[ "$LANE" == "all" || "$LANE" == "helper" ]]; then
  "$ROOT/Tests/compile-guard.sh" "${SWIFTC[@]}" \
    "$ROOT/HelperSources/main.swift" "$ROOT/HelperSources/ProviderStatusCore.swift" "$ROOT/HelperSources/PairingCore.swift" \
    -framework Security -framework AppKit -o "$DIR/cos-control-helper"
  OUT="$(/usr/bin/python3 "$ROOT/Tests/whats-new-helper-checks.py" "$DIR/cos-control-helper")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  COUNT="${${OUT##*checks: }%% passed*}"
  (( COUNT >= 44 )) || { print -u2 "whatsNew helper checks ran only $COUNT (expected at least 44)"; exit 1; }
fi

if [[ "$LANE" == "all" || "$LANE" == "wiring" ]]; then
  app_binary
  # A stand-in helper. check-app-update offers 9.9.9 with a whatsNew (or says up to date once "mode" says so);
  # stage-app-update sends the real helper's progress lines, waits for a release file (consumed), then refuses the way
  # the real one does during a meeting. It never answers apply-app-update, so Control is never asked to quit.
  mkdir -p "$DIR/fake"
  cat > "$DIR/fake/helper" <<'SH'
#!/bin/sh
D="$(cd "$(dirname "$0")" && pwd)"
echo "$1" >> "$D/calls.log"
case "$1" in
  check-app-update)
    if [ "$(cat "$D/mode" 2>/dev/null)" = "uptodate" ]; then
      printf '{"ok":true,"message":"COS Control is up to date","details":{"updateAvailable":false,"reason":"upToDate","latestVersion":"0.5.274","latestBuild":1}}\n'
    else
      printf '{"ok":true,"message":"Update available: 9.9.9","details":{"updateAvailable":true,"reason":"newer","latestVersion":"9.9.9","latestBuild":999999,"url":"https://example.invalid/COS-Control.zip","sha256":"%s","notes":"Old notes.","whatsNew":{"summary":"From the stand-in.","sections":[{"title":"Added","items":["One"]},{"title":"Fixed","items":["Two"]}]}}}\n' "0000000000000000000000000000000000000000000000000000000000000000"
    fi ;;
  stage-app-update)
    printf 'Downloading COS Control update\342\200\246\n' >&2
    sleep 0.3
    printf 'Checking SHA-256\342\200\246\n' >&2
    i=0; while [ ! -f "$D/release" ] && [ $i -lt 400 ]; do sleep 0.05; i=$((i+1)); done
    rm -f "$D/release"
    printf '{"ok":false,"message":"Finish this first, then install: meeting=1. The glasses server was not touched.","details":{"reason":"busy"}}\n'
    exit 1 ;;
  *)
    printf '{"ok":false,"message":"the stand-in does not answer %s","details":{}}\n' "$1"
    exit 1 ;;
esac
SH
  chmod +x "$DIR/fake/helper"
  env "${RUN_ENV[@]}" "$DIR/whats-new-render" check "$DIR/fake/helper"
fi
