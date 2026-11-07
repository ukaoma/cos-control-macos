#!/bin/zsh
# Focused bridge checks. Run only after obtaining the shared Swift slot; the compile guard owns every compiler.
set -euo pipefail
umask 077
ROOT="${0:A:h:h}"
OUT="${1:?absolute private output directory required}"
MODE="${2:?stores or helper required}"
[[ "$OUT" == /tmp/cos-work-web-media-* ]] || { print -u2 'Use a private /tmp/cos-work-web-media-* directory'; exit 2; }
mkdir -p "$OUT/home" "$OUT/tmp" "$OUT/receipts"
chmod 700 "$OUT" "$OUT/home" "$OUT/tmp" "$OUT/receipts"
export COS_COMPILE_PROFILE=bounded
export COS_COMPILE_RECEIPT_DIR="$OUT/receipts"
export COS_TEST_KIT_DIR="$OUT/kits"
if [[ "$MODE" == stores ]]; then
  SOURCES=("$ROOT"/Sources/*.swift)
  SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc \
    -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
    "${SOURCES[@]}" "$ROOT/Tests/WorkLensPlansStoreChecks.swift" "$ROOT/Tests/WorkWebMediaChecks.swift" \
    -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$OUT/stores"
  env HOME="$OUT/home" CFFIXED_USER_HOME="$OUT/home" COS_CONTROL_TEST_HOME="$OUT/home" TMPDIR="$OUT/tmp/" "$OUT/stores"
elif [[ "$MODE" == helper ]]; then
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc \
    -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete \
    "$ROOT/HelperSources/main.swift" "$ROOT/HelperSources/ProviderStatusCore.swift" "$ROOT/HelperSources/PairingCore.swift" "$ROOT/HelperSources/SessionUsageCollector.swift" \
    "$ROOT/Sources/SessionUsageCore.swift" "$ROOT/Sources/WorkSessionLinks.swift" \
    -framework Security -framework AppKit -o "$OUT/cos-control-helper"
else
  print -u2 'Expected stores or helper'; exit 2
fi
