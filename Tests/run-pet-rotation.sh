#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$(mktemp -d /tmp/cos-pet-rotation.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Tests/PetRotationChecks.swift" -framework AppKit -o "$OUT/checks"
"$OUT/checks"
