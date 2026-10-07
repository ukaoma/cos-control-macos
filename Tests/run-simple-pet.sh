#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${1:?usage: run-simple-pet.sh <output directory>}"
OUT="${OUT:A}"
DIR="$(mktemp -d /tmp/cos-simple-pet-test.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/SimplePetDefault.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -o "$DIR/simple-pet"
mkdir -p "$DIR/home" "$DIR/Fonts"
cp -R "$ROOT/Resources/DefaultPet" "$ROOT/Resources/BundledCharacters" "$ROOT/Resources/StarterPet" "$DIR/"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
CFFIXED_USER_HOME="$DIR/home" HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home" "$DIR/simple-pet" "$OUT"
