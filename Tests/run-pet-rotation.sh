#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$(mktemp -d /tmp/cos-pet-rotation.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
python3 "$ROOT/Tests/extract-pet-rotation-controller.py" "$ROOT" "$OUT/PetRotationController.swift"
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Tests/PetRotationChecks.swift" "$ROOT/Tests/WinduMotionChecks.swift" "$ROOT/Tests/PetRotationRecoveryChecks.swift" "$OUT/PetRotationController.swift" -framework AppKit -o "$OUT/checks"
"$OUT/checks"
