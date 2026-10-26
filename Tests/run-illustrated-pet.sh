#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/Tests/illustrated-pack-pins.py" "$ROOT"
DIR="$(mktemp -d)"; trap 'rm -rf "$DIR"' EXIT
"$ROOT/Tests/compile-guard.sh" swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library "$ROOT/Sources/Models.swift" "$ROOT/Tests/IllustratedPetUpgrade.swift" -framework AppKit -o "$DIR/check"
"$DIR/check" "$ROOT"
