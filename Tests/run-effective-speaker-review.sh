#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${1:?usage: run-effective-speaker-review.sh <new private output directory>}"
[[ ! -e "$OUT" ]] || { print -u2 'fresh output directory required'; exit 2; }
mkdir -m 700 "$OUT"
DIR="$(mktemp -d /tmp/cos-effective-model.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
mkdir -m 700 "$DIR/home"
export COS_COMPILE_PROFILE=bounded
export COS_COMPILE_RECEIPT_DIR="${COS_COMPILE_RECEIPT_DIR:-$OUT/compile-receipts}"
export COS_LIVE_CUES_V2=0 COS_SPEAKER_SHADOW=0 COS_MAC_SPEAKER_LIVE=0 COS_MAC_ACOUSTIC_VOICES=0
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
 "$ROOT/Sources/Models.swift" "$ROOT/Tests/EffectiveSpeakerReviewChecks.swift" -framework AppKit -o "$DIR/model-checks"
HOME="$DIR/home" CFFIXED_USER_HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home" "$DIR/model-checks" > "$OUT/model-checks.log"
cat "$OUT/model-checks.log"
