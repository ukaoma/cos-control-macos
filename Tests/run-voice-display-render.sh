#!/bin/zsh
# 0.5.357, by hand only (never a gate): the Speakers surface drawn off screen to PNGs in <folder>, at the 390 pt panel width, light and
# dark, with invented names and words. A stand-in helper serves fixtures the harness writes. A scratch home: no server, no provider.
# No window is ordered in and nothing is clicked, typed or dragged.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${1:?usage: run-voice-display-render.sh <folder for the PNGs>}"
OUT="${OUT:A}"
DIR="$(mktemp -d /tmp/cos-voice-display-render.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/VoiceDisplayRender.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -o "$DIR/voice-display-render"
mkdir -p "$DIR/Fonts" "$DIR/home" "$DIR/fixtures"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
cat > "$DIR/stand-in-helper" <<'SH'
#!/bin/zsh
# Answers a command from its fixture, and refuses the rest.
f="$COS_RENDER_FIXTURES/$1.json"
if [[ -f "$f" ]]; then cat "$f"; else print -r -- '{"ok":false,"message":"The render harness does not answer this command.","details":{}}'; fi
SH
chmod +x "$DIR/stand-in-helper"
CFFIXED_USER_HOME="$DIR/home" HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home" COS_RENDER_FIXTURES="$DIR/fixtures" COS_RENDER_HELPER="$DIR/stand-in-helper" \
  "$DIR/voice-display-render" "$OUT" 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
