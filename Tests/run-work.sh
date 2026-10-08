#!/bin/zsh
# Reproducible native Work contracts. Synthetic transports; no agent messages.
set -euo pipefail
ROOT="${0:A:h:h}"
TMP="$(mktemp -d /tmp/cos-work-contracts.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
SOURCES=(Models HelperClient ControllerModel COSBrand COSMotion COSConfirm Views Control2Foundation WorkHandoffStore WorkProgress WorkCardFiles WorkProgressTracker WorkTrackingViews WorkHandoffView WorkReviewStore WorkWorkspaceView ActivityWindow ActivityMeetings COSMarkdownParser COSMarkdown SessionLiveFeed SessionPet)
FILES=()
for source in $SOURCES; do FILES+=("$ROOT/Sources/$source.swift"); done
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  $FILES "$ROOT/Tests/Control2FoundationContract.swift" "$ROOT/Tests/Control2ActivityIntegrationChecks.swift" \
  "$ROOT/Tests/WorkWorkspaceProjectionChecks.swift" "$ROOT/Tests/WorkReviewStoreChecks.swift" "$ROOT/Tests/WorkActivityChecks.swift" "$ROOT/Tests/WorkMeetingConnectionsChecks.swift" "$ROOT/Tests/WorkIntakeChecks.swift" "$ROOT/Tests/WorkBoardCacheChecks.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$TMP/work-contracts"
"$TMP/work-contracts"
# Exercise the real pre-draft reader against the upgraded journal.
git -C "$ROOT" show be3bb89:Sources/WorkHandoffStore.swift > "$TMP/baseline.swift"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
s=(root/'baseline.swift').read_text()
s=s[s.index('@MainActor final class WorkHandoffStore'):].replace('class WorkHandoffStore:', 'class LegacyWorkHandoffStore:', 1)
(root/'LegacyWorkHandoffStore.swift').write_text('import Foundation\nimport SwiftUI\nimport Darwin\n'+s)
PY
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  $FILES "$ROOT/Tests/WorkHandoffTests.swift" "$TMP/LegacyWorkHandoffStore.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$TMP/work-handoffs"
"$TMP/work-handoffs"
