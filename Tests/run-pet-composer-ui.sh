#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${1:-/tmp/cos-pet-composer-ui}"
TMP="$(mktemp -d /tmp/cos-pet-composer-ui-build.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Sources/HelperClient.swift" "$ROOT/Sources/ControllerModel.swift" \
  "$ROOT/Sources/COSBrand.swift" "$ROOT/Sources/COSMotion.swift" "$ROOT/Sources/COSConfirm.swift" \
  "$ROOT/Sources/Views.swift" "$ROOT/Sources/ActivityWindow.swift" "$ROOT/Sources/ActivityMeetings.swift" \
  "$ROOT/Sources/COSMarkdownParser.swift" "$ROOT/Sources/COSMarkdown.swift" \
  "$ROOT/Sources/SessionLiveFeed.swift" \
  "$ROOT/Sources/SessionPet.swift" "$ROOT/Tests/PetComposerUI.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$TMP/pet-composer-ui"
"$TMP/pet-composer-ui" "$OUT" "$ROOT"
