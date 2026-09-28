#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
BIN="$(mktemp /tmp/cos-control2-contract.XXXXXX)"
trap 'rm -f "$BIN"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Sources/HelperClient.swift" "$ROOT/Sources/ControllerModel.swift" \
  "$ROOT/Sources/COSBrand.swift" "$ROOT/Sources/COSMotion.swift" "$ROOT/Sources/COSConfirm.swift" \
  "$ROOT/Sources/Views.swift" "$ROOT/Sources/ActivityWindow.swift" "$ROOT/Sources/ActivityMeetings.swift" \
  "$ROOT/Sources/COSMarkdownParser.swift" "$ROOT/Sources/COSMarkdown.swift" "$ROOT/Sources/SessionLiveFeed.swift" \
  "$ROOT/Sources/SessionPet.swift" "$ROOT/Sources/Control2Foundation.swift" "$ROOT/Sources/WorkHandoffStore.swift" "$ROOT/Sources/WorkHandoffView.swift" "$ROOT/Sources/WorkReviewStore.swift" "$ROOT/Sources/WorkWorkspaceView.swift" \
  "$ROOT/Tests/WorkMeetingConnectionsChecks.swift" "$ROOT/Tests/WorkActivityChecks.swift" "$ROOT/Tests/WorkWorkspaceProjectionChecks.swift" "$ROOT/Tests/WorkReviewStoreChecks.swift" "$ROOT/Tests/Control2ActivityIntegrationChecks.swift" "$ROOT/Tests/Control2FoundationContract.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$BIN"
"$BIN"
