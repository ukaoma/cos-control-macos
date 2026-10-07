#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-task-editor.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/WorkTaskEditor.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -o "$DIR/editor-checks"
SCRATCH_HOME="$DIR/cos-task-editor home.ü"
mkdir -p "$SCRATCH_HOME" "$DIR/Fonts"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
cat > "$DIR/cos-control-helper" <<'SH'
#!/bin/zsh
if [[ "$1" == work-tasks ]]; then cat "$COS_EDITOR_FIXTURE";
else print -r -- '{"ok":false,"message":"The editor fixture does not answer this command.","details":{}}'; fi
SH
chmod +x "$DIR/cos-control-helper"
CFFIXED_USER_HOME="$SCRATCH_HOME" HOME="$SCRATCH_HOME" COS_CONTROL_TEST_HOME="$SCRATCH_HOME" COS_EDITOR_FIXTURE="$DIR/work-tasks.json" \
  "$DIR/editor-checks" "$@" 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
