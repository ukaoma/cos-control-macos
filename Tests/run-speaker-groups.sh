#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-speaker-group-checks.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/home"
export COS_TEST_KIT_DIR="${COS_TEST_KIT_DIR:-/tmp/cos-control-speaker-group-kits-$UID}"
mkdir -p "$COS_TEST_KIT_DIR"
chmod 700 "$COS_TEST_KIT_DIR"
export COS_COMPILE_PROFILE="${COS_COMPILE_PROFILE:-bounded}"
export COS_LIVE_CUES_V2=0 COS_SPEAKER_SHADOW=0 COS_MAC_SPEAKER_LIVE=0 COS_MAC_ACOUSTIC_VOICES=0
HELPER=""
if (( $# )); then
  [[ $# == 2 && "$1" == --helper && -x "$2" ]] || { print -u2 'usage: run-speaker-groups.sh [--helper compiled-helper]'; exit 2; }
  HELPER="$2"
fi
/usr/bin/python3 "$ROOT/Tests/desktop-safety-check.py" "$ROOT"
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Tests/SpeakerGroupChecks.swift" -framework AppKit -o "$DIR/model-checks"
HOME="$DIR/home" CFFIXED_USER_HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home" "$DIR/model-checks"
if [[ -z "$HELPER" ]]; then
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete \
    "$ROOT/HelperSources/main.swift" "$ROOT/HelperSources/ProviderStatusCore.swift" "$ROOT/HelperSources/PairingCore.swift" "$ROOT/HelperSources/SessionUsageCollector.swift" "$ROOT/Sources/SessionUsageCore.swift" "$ROOT/Sources/WorkSessionLinks.swift" \
    -framework Security -framework AppKit -o "$DIR/cos-control-helper"
  HELPER="$DIR/cos-control-helper"
fi
/usr/bin/python3 "$ROOT/Tests/speaker-group-helper-checks.py" "$HELPER"
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/SpeakerGroupReviewChecks.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -o "$DIR/review-checks"
HOME="$DIR/home" CFFIXED_USER_HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home" "$DIR/review-checks" "$DIR"
print 'PASS: speaker group exact-membership, compiled loopback helper, controller and never-shown views'
