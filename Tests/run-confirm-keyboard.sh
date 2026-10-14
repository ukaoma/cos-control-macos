#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-confirm-keys.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
 "${SOURCES[@]}" "$ROOT/Tests/ConfirmKeyboardChecks.swift" \
 -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -o "$DIR/checks"
mkdir -p "$DIR/home"
CFFIXED_USER_HOME="$DIR/home" HOME="$DIR/home" "$DIR/checks"
