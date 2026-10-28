#!/bin/zsh
# 0.5.352: the pet drags itself on macOS 27.2. Models.swift (PetDragTracker) plus the checks, one small compile.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$(mktemp -d /tmp/cos-pet-drag.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
/usr/bin/python3 "$ROOT/Tests/pet-drag-source-contract.py" "$ROOT"
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Tests/PetDragChecks.swift" -framework AppKit -o "$OUT/checks"
"$OUT/checks"
