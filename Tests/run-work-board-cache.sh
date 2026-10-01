#!/bin/zsh
# 0.5.254 resize pass: the Work board's cached rows (Tests/WorkBoardCacheChecks.swift) on their own, for the mutation lane
# (Tests/mutate-work-board-cache.py). The same checks run in Tests/run-work.sh. No window, no event, no server.
set -euo pipefail
ROOT="${0:A:h:h}"
TMP="$(mktemp -d /tmp/cos-board-cache.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
SOURCES=(Models HelperClient ControllerModel COSBrand COSMotion COSConfirm Views Control2Foundation WorkHandoffStore WorkProgress WorkCardFiles WorkProgressTracker WorkTrackingViews WorkHandoffView WorkReviewStore WorkWorkspaceView ActivityWindow ActivityMeetings COSMarkdownParser COSMarkdown SessionLiveFeed SessionPet)
FILES=()
for source in $SOURCES; do FILES+=("$ROOT/Sources/$source.swift"); done
print -r -- '@main struct WorkBoardCacheMain { @MainActor static func main() async throws { try await runWorkBoardCacheChecks() } }' > "$TMP/main.swift"
swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  $FILES "$ROOT/Tests/WorkBoardCacheChecks.swift" "$TMP/main.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$TMP/board-cache"
"$TMP/board-cache"
