#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
TMP="$(mktemp -d /tmp/cos-onboarding-checks.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Tests/OnboardingChecks.swift" -framework AppKit -o "$TMP/checks"
"$TMP/checks"
# A normal build may use a stable local identity. The public entry point may not.
if COS_SIGN_IDENTITY='' COS_NOTARY_PROFILE='' "$ROOT/scripts/build-public-release.sh" >"$TMP/public.log" 2>&1; then
  print -u2 'Public release incorrectly accepted a missing Developer ID'; exit 1
fi
grep -q 'Public release needs' "$TMP/public.log"
print 'PASS: public release refuses missing Developer ID before building'
