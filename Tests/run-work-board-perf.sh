#!/bin/zsh
# 0.5.254 resize pass, by hand only (never a gate): Tests/WorkBoardResizePerf.swift, the Work board with 268 tasks resized
# 1200 to 1900 pt in a window that is never ordered in. Built like the release (scripts/build-release.sh: no -O), with a
# scratch home and a stand-in helper beside the binary that replays the fixture JSON the harness writes. No server, no
# provider, nothing clicked, typed or dragged.
#   Tests/run-work-board-perf.sh <label>                  the timings
#   Tests/run-work-board-perf.sh <label> <folder>         PNGs of the board at 1280, 1800 and 820 pt, light and dark
set -euo pipefail
ROOT="${0:A:h:h}"
LABEL="${1:?usage: run-work-board-perf.sh <label> [folder for PNGs]}"
OUT="${2:-}"
DIR="$(mktemp -d /tmp/cos-board-perf.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/WorkBoardResizePerf.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$DIR/board-perf"
HOME_DIR="$DIR/scratch home.ü"
mkdir -p "$DIR/Fonts" "$HOME_DIR" "$DIR/fixtures"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
cat > "$DIR/cos-control-helper" <<'SH'
#!/bin/zsh
# Stand-in helper: answers a command from its fixture, refuses the rest.
f="$COS_PERF_FIXTURES/$1.json"
if [[ -f "$f" ]]; then cat "$f"; else print -r -- '{"ok":false,"message":"The resize harness does not answer this command.","details":{}}'; fi
SH
chmod +x "$DIR/cos-control-helper"
[[ -n "$OUT" ]] && OUT="${OUT:A}"
CFFIXED_USER_HOME="$HOME_DIR" HOME="$HOME_DIR" COS_CONTROL_TEST_HOME="$HOME_DIR" COS_PERF_FIXTURES="$DIR/fixtures" \
  "$DIR/board-perf" "$LABEL" ${OUT:+"$OUT"} 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
