#!/bin/zsh
# The permission guide's logic (Tests/PermissionGuideChecks.swift) against Sources/PermissionGuideModel.swift alone: it
# imports only Foundation, so this compile is small. Then the pins (Tests/permission-guide-pins.py) for the wiring in
# the app. Nothing is shown, clicked or typed; no TCC read, no System Settings.
# The one compile goes through Tests/compile-guard.sh; run the script itself plainly.
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-permission-guide.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/PermissionGuideModel.swift" "$ROOT/Tests/PermissionGuideChecks.swift" -o "$DIR/permission-guide-checks"
HOME_DIR="$DIR/guide home.ü"
mkdir -p "$HOME_DIR"
CFFIXED_USER_HOME="$HOME_DIR" HOME="$HOME_DIR" "$DIR/permission-guide-checks"
/usr/bin/python3 "$ROOT/Tests/permission-guide-pins.py" "$ROOT"
