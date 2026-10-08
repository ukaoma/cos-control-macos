#!/bin/zsh
# Connect your AI (onboarding P1). Three parts, one compile at a time through Tests/compile-guard.sh:
#   1. provider-status's core against fixtures (Tests/run-provider-status.sh);
#   2. the app's model alone (Sources/ProviderConnectModel.swift + Tests/ProviderConnectChecks.swift, Foundation only);
#   3. the wiring pins (Tests/provider-connect-pins.py).
# Nothing opens Terminal, an app, a link or System Settings: every effect in the checks is a stand-in.
set -euo pipefail
ROOT="${0:A:h:h}"
"$ROOT/Tests/run-provider-status.sh"
DIR="$(mktemp -d /tmp/cos-provider-connect.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/ProviderConnectModel.swift" "$ROOT/Tests/ProviderConnectChecks.swift" -o "$DIR/provider-connect-checks"
HOME_DIR="$DIR/connect home.ü"
mkdir -p "$HOME_DIR"
CFFIXED_USER_HOME="$HOME_DIR" HOME="$HOME_DIR" "$DIR/provider-connect-checks"
/usr/bin/python3 "$ROOT/Tests/provider-connect-pins.py" "$ROOT"
