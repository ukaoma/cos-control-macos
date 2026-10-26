#!/bin/zsh
# Real WorkCardFileStore intake/reopen; fixture-only. Run after an explicit native-lane grant.
# The established harness needs the shared app type kit, but never compiles/runs COSControlApp.
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-phone-meeting-files.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/home"
env HOME="$DIR/home" CFFIXED_USER_HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home" \
  zsh "$ROOT/Tests/run-work-card-files.sh" --phone-meeting-only
