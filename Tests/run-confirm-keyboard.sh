#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-confirm-keys.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
 "$ROOT/Sources/COSBrand.swift" "$ROOT/Sources/COSConfirm.swift" "$ROOT/Tests/fence-canary/Shim.swift" "$ROOT/Tests/ConfirmKeyboardChecks.swift" \
 -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -o "$DIR/checks"
mkdir -p "$DIR/home"
CFFIXED_USER_HOME="$DIR/home" HOME="$DIR/home" "$DIR/checks"
