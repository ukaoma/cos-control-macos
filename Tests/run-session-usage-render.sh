#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${1:?usage: run-session-usage-render.sh /tmp/output-folder}"
TMP="$(mktemp -d /tmp/cos-usage-render.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home/.cursor" "$TMP/Fonts"
cp "$ROOT/Resources/Fonts/"*.ttf "$TMP/Fonts/"
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc \
  -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/SessionUsageRender.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework Vision -o "$TMP/render"
env HOME="$TMP/home" CFFIXED_USER_HOME="$TMP/home" COS_CONTROL_TEST_HOME="$TMP/home" "$TMP/render" "${OUT:A}"
