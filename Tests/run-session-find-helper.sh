#!/bin/zsh
# The ⌘K meaning search verb (0.5.362): the compiled helper against a stand-in server on loopback, through the shared compile guard.
# The helper builds the way Tests/run.sh builds it. Nothing real is asked: a scratch home with a fictional token, no provider, no key.
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-session-find-helper.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete \
  "$ROOT/HelperSources/main.swift" "$ROOT/HelperSources/ProviderStatusCore.swift" "$ROOT/HelperSources/PairingCore.swift" "$ROOT/HelperSources/SessionUsageCollector.swift" "$ROOT/Sources/SessionUsageCore.swift" "$ROOT/Sources/WorkSessionLinks.swift" \
  -framework Security -framework AppKit \
  -o "$DIR/cos-control-helper"
/usr/bin/python3 "$ROOT/Tests/session-find-helper-checks.py" "$DIR/cos-control-helper"
/usr/bin/python3 "$ROOT/Tests/local-session-search-checks.py" "$DIR/cos-control-helper"
