#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$ROOT/dist/work-session-hub-checks"
mkdir -p "$OUT"
sed 's/@main struct WorkTaskContextChecks/struct WorkTaskContextChecks/' "$ROOT/Tests/WorkTaskContextChecks.swift" > "$OUT/ContextChecks.swift"
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
COS_COMPILE_PROFILE=bounded "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
 "${SOURCES[@]}" "$ROOT/Tests/WorkInputChecks.swift" "$ROOT/Tests/WorkSessionHubChecks.swift" "$ROOT/Tests/WorkActivityChecks.swift" "$ROOT/Tests/WorkOrchestrationChecks.swift" "$ROOT/Tests/WorkBoardCacheChecks.swift" "$OUT/ContextChecks.swift" -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$OUT/hub-checks"
"$OUT/hub-checks" --render "$OUT/renders"
