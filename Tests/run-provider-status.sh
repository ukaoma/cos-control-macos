#!/bin/zsh
# provider-status (HelperSources/ProviderStatusCore.swift) against fixtures (Tests/ProviderStatusChecks.swift): the
# server's binary order, the ChatGPT app's codex, aliases ignored, sign-in states, Cursor's identity, Ollama. It imports
# only Foundation, so this compile is small. No real CLI runs. The one compile goes through Tests/compile-guard.sh.
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-provider-status.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/HelperSources/ProviderStatusCore.swift" "$ROOT/Tests/ProviderStatusChecks.swift" -o "$DIR/provider-status-checks"
"$DIR/provider-status-checks"
