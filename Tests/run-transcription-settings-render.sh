#!/bin/zsh
# Render the Transcription settings card (Tests/TranscriptionSettingsRender.swift) offscreen, light and dark, from the
# contract fixture: no window is shown, no helper runs. The one full app compile goes through the guard.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${1:?usage: run-transcription-settings-render.sh <folder for the PNGs>}"
OUT="${OUT:A}"
DIR="$(mktemp -d /tmp/cos-stt-render.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/TranscriptionSettingsRender.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -o "$DIR/stt-render"
HOME_DIR="$DIR/cos-stt-render home.ü"
mkdir -p "$DIR/Fonts" "$HOME_DIR"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
cp "$ROOT/Resources/"*.svg "$DIR/"   # the lockup and the provider marks, found beside the binary as in the app bundle
CFFIXED_USER_HOME="$HOME_DIR" HOME="$HOME_DIR" COS_CONTROL_TEST_HOME="$HOME_DIR" "$DIR/stt-render" "$OUT" "$ROOT/Tests/fixtures/stt-settings-6.72.0.json" 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
