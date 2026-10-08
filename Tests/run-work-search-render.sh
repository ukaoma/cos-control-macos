#!/bin/zsh
# 0.5.259, by hand only (never a gate): the Work board with a search active and with Order = Recent activity, drawn off
# screen to PNGs in <folder> for a side-by-side check against board 4 of the 10/6 mock. A stand-in helper beside the
# binary serves the board; Jev is a fake. A scratch home: no server, no provider. No window is ordered in and nothing is
# clicked, typed or dragged.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${1:?usage: run-work-search-render.sh <folder for the PNGs>}"
OUT="${OUT:A}"
DIR="$(mktemp -d /tmp/cos-search-render.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/WorkSearchRender.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$DIR/search-render"
mkdir -p "$DIR/Fonts" "$DIR/home" "$DIR/fixtures"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
cat > "$DIR/cos-control-helper" <<'SH'
#!/bin/zsh
# Stand-in helper: answers a command from its fixture, refuses the rest.
f="$COS_SEARCH_FIXTURES/$1.json"
if [[ -f "$f" ]]; then cat "$f"; else print -r -- '{"ok":false,"message":"The render harness does not answer this command.","details":{}}'; fi
SH
chmod +x "$DIR/cos-control-helper"
CFFIXED_USER_HOME="$DIR/home" HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home" COS_SEARCH_FIXTURES="$DIR/fixtures" \
  "$DIR/search-render" "$OUT" 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
