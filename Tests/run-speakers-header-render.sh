#!/bin/zsh
# 0.5.259, by hand only (never a gate): the Speakers meeting review header with Open meeting, drawn off screen to PNGs in
# <folder>. <fixtures> holds saved helper answers, meeting-speakers.json and meeting-content.json (for example
# `cos-control-helper meeting-speakers --session <id> > meeting-speakers.json`); they name real people, so they stay out
# of the repo. A stand-in helper beside the binary serves them. A scratch home: no server, no provider. No window is
# ordered in and nothing is clicked, typed or dragged.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${1:?usage: run-speakers-header-render.sh <folder for the PNGs> <fixtures folder>}"
FIX="${2:?usage: run-speakers-header-render.sh <folder for the PNGs> <fixtures folder>}"
OUT="${OUT:A}"; FIX="${FIX:A}"
SESSION="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["details"]["review"]["sessionId"])' "$FIX/meeting-speakers.json")"
DIR="$(mktemp -d /tmp/cos-speakers-render.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/SpeakersHeaderRender.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$DIR/speakers-render"
mkdir -p "$DIR/Fonts" "$DIR/home"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
cat > "$DIR/cos-control-helper" <<'SH'
#!/bin/zsh
# Stand-in helper: answers a command from its fixture, refuses the rest.
f="$COS_RENDER_FIXTURES/$1.json"
if [[ -f "$f" ]]; then cat "$f"; else print -r -- '{"ok":false,"message":"The render harness does not answer this command.","details":{}}'; fi
SH
chmod +x "$DIR/cos-control-helper"
CFFIXED_USER_HOME="$DIR/home" HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home" COS_RENDER_FIXTURES="$FIX" COS_RENDER_SESSION="$SESSION" \
  "$DIR/speakers-render" "$OUT" 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
