#!/bin/zsh
# Settings Release A (Miles, 2026-11-03, "go a"): the rules behind the safer controls (Sources/SettingsRules.swift), compiled
# alone with Tests/SettingsRulesChecks.swift through the shared compile guard. Nothing is drawn, no window opens, no sound
# plays, and nothing reads a server. Wiring pins for the views are in Tests/settings-a-pins.py.
set -euo pipefail
ROOT="${0:A:h:h}"
BIN="$(mktemp /tmp/cos-settings-a.XXXXXX)"
trap 'rm -f "$BIN"' EXIT
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/SettingsRules.swift" "$ROOT/Tests/SettingsRulesChecks.swift" -o "$BIN"
"$BIN"
# Return never confirms a destructive action: the shipped COSConfirm.swift and COSBrand.swift with the fence canary's palette stand-in.
CBIN="$(mktemp /tmp/cos-confirm-return.XXXXXX)"
trap 'rm -f "$BIN" "$CBIN"' EXIT
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/COSBrand.swift" "$ROOT/Sources/COSConfirm.swift" "$ROOT/Tests/fence-canary/Shim.swift" "$ROOT/Tests/ConfirmReturnChecks.swift" \
  -framework SwiftUI -framework AppKit -o "$CBIN"
"$CBIN"
