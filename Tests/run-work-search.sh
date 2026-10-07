#!/bin/zsh
# 0.5.259 Work search and order (Tests/WorkSearchChecks.swift): the words and matches, Jev's thresholds, a late answer
# dropped, Best matches, the counts, other domains, the degrade lines, the keys, Order and its memory, the dates from each
# source, and the stage-move journal. The journal is written through the app's own stage writes, answered by a stand-in
# helper beside the binary that replays fixture JSON the checks write (no server, no provider). The scratch home has a
# space, a dot and a non-ASCII letter, because production paths have them. Nothing is shown, clicked or typed.
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-work-search.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/WorkSearchChecks.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$DIR/work-search-checks"
HOME_DIR="$DIR/search home.ü"
mkdir -p "$HOME_DIR" "$DIR/fixtures"
cat > "$DIR/cos-control-helper" <<'SH'
#!/bin/zsh
# Stand-in helper: notes the command, keeps a body it was sent, answers from its fixture, refuses the rest.
print -r -- "$1" >> "$COS_SEARCH_FIXTURES/calls.log"
case "$1" in work-set-stage|work-loop|work-search) cat > "$COS_SEARCH_FIXTURES/$1.stdin" ;; esac
f="$COS_SEARCH_FIXTURES/$1.json"
if [[ -f "$f" ]]; then cat "$f"; else print -r -- '{"ok":false,"message":"The search checks do not answer this command.","details":{}}'; fi
SH
chmod +x "$DIR/cos-control-helper"
CFFIXED_USER_HOME="$HOME_DIR" HOME="$HOME_DIR" COS_CONTROL_TEST_HOME="$HOME_DIR" COS_SEARCH_FIXTURES="$DIR/fixtures" \
  "$DIR/work-search-checks"
