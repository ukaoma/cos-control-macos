#!/bin/zsh
# 0.5.259, by hand only (never a gate): the Activity home's first frame with the loads on opening off and on, and when
# each load starts and ends relative to that frame (Tests/ActivityHomeFirstRender.swift). A stand-in helper answers every
# command after 300 ms and logs it. Built like the release (no -O). Pass another tree's root to measure it with the same
# harness, for a before and after:
#   Tests/run-activity-home-perf.sh            this tree
#   Tests/run-activity-home-perf.sh <root>     another tree's Sources and Resources (git archive <sha> Sources Resources)
# A scratch home: no server, no provider. No window is ordered in and nothing is clicked, typed or dragged.
set -euo pipefail
ROOT="${0:A:h:h}"
SRC="${1:-$ROOT}"
SRC="${SRC:A}"
DIR="$(mktemp -d /tmp/cos-home-perf.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
SOURCES=("$SRC"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/ActivityHomeFirstRender.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -o "$DIR/home-perf"
HOME_DIR="$DIR/cos-home-perf home.ü"
mkdir -p "$DIR/Fonts" "$HOME_DIR"
cp "$SRC/Resources/Fonts/"*.ttf "$DIR/Fonts/"
cp "$SRC/Resources/"*.svg "$DIR/"
# The stand-in helper, found beside the binary as the app finds its own in Resources.
cat > "$DIR/cos-control-helper" <<'SH'
#!/bin/sh
ms() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }
echo "$(ms) start $*" >> "$COS_PERF_HELPER_LOG"
sleep 0.3
printf '{"ok":true,"message":"perf stand-in","details":{"learningToReview":3}}\n'
echo "$(ms) end $*" >> "$COS_PERF_HELPER_LOG"
SH
chmod +x "$DIR/cos-control-helper"
CFFIXED_USER_HOME="$HOME_DIR" HOME="$HOME_DIR" COS_CONTROL_TEST_HOME="$HOME_DIR" COS_PERF_HELPER_LOG="$DIR/helper.log" \
  "$DIR/home-perf" 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
