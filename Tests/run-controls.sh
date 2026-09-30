#!/bin/zsh
# 0.5.251 GOTCOS controls, executed: the shipped components in a window ordered in far off screen, driven by clicks and
# keys posted in-process; pure rules; rendered pixels. Fonts sit beside the binary, where COSType looks for them.
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-controls-contract.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/ControlsContract.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$DIR/controls-contract"
mkdir -p "$DIR/Fonts"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
# SwiftUI logs a font-weight notice per custom font it resolves; show the process's stderr only when it fails.
if ! "$DIR/controls-contract" 2>"$DIR/stderr.log"; then
  cat "$DIR/stderr.log" >&2
  exit 1
fi
