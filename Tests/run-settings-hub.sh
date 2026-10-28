#!/bin/zsh
# Settings hub (Miles, 2026-10-27, the A treatment with B's On this page rail): the catalog's pure logic. Every
# inventory row in one group, every group in one category, every deep-link anchor resolving, search by new label, old
# label and keyword, the breakpoints, the scroll-spy and the category status lines (Tests/SettingsHubChecks.swift).
# Compiled with the catalog alone, through the shared compile guard. Nothing is drawn, clicked or shown.
set -euo pipefail
ROOT="${0:A:h:h}"
BIN="$(mktemp /tmp/cos-settings-hub.XXXXXX)"
trap 'rm -f "$BIN"' EXIT
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/SettingsHubCatalog.swift" "$ROOT/Tests/SettingsHubChecks.swift" -o "$BIN"
"$BIN"
