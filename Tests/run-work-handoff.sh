#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
BIN="$(mktemp /tmp/cos-work-handoff-contract.XXXXXX)"
LEGACY_DIR="$(mktemp -d /tmp/cos-work-handoff-legacy.XXXXXX)"
trap 'rm -f "$BIN" "$LEGACY_DIR/LegacyWorkHandoffStore.swift"; rmdir "$LEGACY_DIR"' EXIT
# Execute the actual pre-draft journal reader for downgrade verification. Keep
# its gate/body intact; rename only the class so it can share current models.
git -C "$ROOT" show be3bb89:Sources/WorkHandoffStore.swift | \
  awk 'BEGIN { print "import Foundation\nimport SwiftUI\nimport Darwin" }
       /^@MainActor final class WorkHandoffStore/ { found=1 }
       found { gsub(/WorkHandoffStore/, "LegacyWorkHandoffStore"); print }' \
  > "$LEGACY_DIR/LegacyWorkHandoffStore.swift"
# Exercise the shipping types and store; only the production @main is replaced.
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$LEGACY_DIR/LegacyWorkHandoffStore.swift" "$ROOT/Tests/WorkHandoffTests.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$BIN"
"$BIN"
