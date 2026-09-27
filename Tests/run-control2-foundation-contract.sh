#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
BIN="$(mktemp /tmp/cos-control2-contract.XXXXXX)"
trap 'rm -f "$BIN"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Sources/HelperClient.swift" "$ROOT/Sources/Control2Foundation.swift" \
  "$ROOT/Tests/Control2FoundationContract.swift" -framework SwiftUI -framework AppKit -o "$BIN"
"$BIN"
