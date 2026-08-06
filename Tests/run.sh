#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
TARGET="arm64-apple-macosx14.0"
TMP="$(mktemp -d /tmp/cos-control-tests.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/home"

swiftc -target "$TARGET" -swift-version 6 -strict-concurrency=complete \
  "$ROOT/HelperSources/main.swift" \
  -framework Security \
  -o "$TMP/cos-control-helper"

SELF_TEST="$(COS_CONTROL_TEST_HOME="$TMP/home" "$TMP/cos-control-helper" self-test)"
/usr/bin/python3 -c 'import json,sys; value=json.loads(sys.argv[1]); assert value["ok"] and value["details"]["tests"] >= 24' "$SELF_TEST"

swiftc -target "$TARGET" -swift-version 6 -strict-concurrency=complete \
  "$ROOT/Sources/Models.swift" \
  "$ROOT/Tests/ModelsContract.swift" \
  -framework AppKit \
  -o "$TMP/models-contract"
"$TMP/models-contract"
/usr/bin/grep -q 'cursor-probe-cache.json' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'recent-messages' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "fetch-media"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q '/api/media/\\(id)/content?variant=\\(variant)' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'Copy + images' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'MediaTransfers' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'Handoffs' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'inspect only its generated image-NN.jpg/png files before responding' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'footerLabel' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'npm latest' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'ControllerModel.currentVersion' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'model.status.version' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'Work Folder' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'Meetings Library' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'set-operations-dir' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'COS_OPERATIONS_DIR' "$ROOT/HelperSources/main.swift"

# --- 0.3.5 transcription policy + Cursor diagnostic contract ---------------
/usr/bin/grep -q 'case "set-transcription-tier"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'COS_WHISPER_TRANSCRIPTION_TIER' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'COS_WHISPER_COMMIT_MODEL' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'requireTranscriptionTier' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "set-background-jobs"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'requireBackgroundJobs' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "set-meeting-preview"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'COS_WHISPER_MEETING_PREVIEW' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'requireMeetingPreview' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'Meeting Turbo preview' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'stoppedCompatibleManagedServer' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'configuredRequestedTier' "$ROOT/HelperSources/main.swift"
/usr/bin/python3 - "$ROOT" <<'PY'
import pathlib, re, sys
source = (pathlib.Path(sys.argv[1]) / "HelperSources/main.swift").read_text()
invalid = re.findall(r'operationKind:\s*"(provider_env_update|workdir_update)"', source)
if invalid:
    raise SystemExit(f"internal labels leaked into maintenance operation contract: {invalid}")
PY
/usr/bin/grep -q 'running Balanced fallback because Large-v3 is unavailable' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'commitDegraded' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'previewDegraded' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'strictBootoutInPlace()' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q '"cursorCliVersion": probe.version' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'Preview, while dictating' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'Commit, live meeting' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'Polish, on save' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'Update Server to 6.21.0 or newer to enable transcription tier controls' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'onAppear' "$ROOT/Sources/Views.swift"
/usr/bin/grep -Fq 'transcription-tier \(normalized)' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -Fq 'Proving \(provider.capitalized) (up to \(proofWindow))' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'Server change in progress · recovery is armed' "$ROOT/Sources/Views.swift"
/usr/bin/python3 - "$ROOT" <<'PY'
import pathlib, sys
views = (pathlib.Path(sys.argv[1]) / "Sources/Views.swift").read_text()
pending = views.index("if model.status.transactionPending")
busy = views.index("if model.busy", pending)
interrupted = views.index("An interrupted server change needs Repair.", busy)
if not pending < busy < interrupted:
    raise SystemExit("active transactions must not render as interrupted")
PY

# --- 0.3.4 provider-proof and mixed-version hardening -----------------------
# Startup/ownership keeps its 60s gate, but the real provider/Kokoro requests
# must use their own bounded timeouts after startup. Reusing deadlineUptime here
# falsely rejected Codex after Claude consumed most of the shared budget.
/usr/bin/python3 - "$ROOT" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
source = (root / "HelperSources/main.swift").read_text()
needle = '''requireProviderEndpoint: versionAtLeast(expectedVersion, "6.15.2"),
                            operation: inheritedLease,
                            deadlineUptime: nil'''
if needle not in source:
    raise SystemExit("managed candidate proofs must not inherit the startup deadline")
views = (root / "Sources/Views.swift").read_text()
for field in ("livePreviewModel", "liveCommitModel", "hqPolishModel"):
    if f"if model.status.{field} != nil" not in views:
        raise SystemExit(f"mixed-version transcription row is not gated: {field}")
PY

# --- Version touchpoints agree ----------------------------------------------
# The footer went dynamic in 0.2.8, which removed the only assertion that could
# catch a wrong Info.plist. Version strings HAVE been reused across two different
# shipped binaries before (0.2.7/build 18), so pin Info.plist to the CHANGELOG
# heading instead of to any user-visible string.
/usr/bin/python3 - "$ROOT" <<'PY'
import plistlib, re, sys, pathlib
root = pathlib.Path(sys.argv[1])
info = plistlib.loads((root / "Resources/Info.plist").read_bytes())
version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
head = (root / "CHANGELOG.md").read_text().splitlines()
entry = next((l for l in head if l.startswith("## ")), "")
m = re.match(r"## (\d+\.\d+\.\d+) \(build (\d+)\)", entry)
if not m:
    sys.exit(f"CHANGELOG top entry is not '## X.Y.Z (build N)': {entry!r}")
if (m.group(1), m.group(2)) != (version, build):
    sys.exit(
        f"version touchpoints disagree: Info.plist {version} (build {build}) "
        f"vs CHANGELOG {m.group(1)} (build {m.group(2)})"
    )
PY

# --- 0.3.0 meeting sync status ----------------------------------------------
/usr/bin/grep -q 'Meeting sync' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'meetingSyncActive' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'meetingSyncStatusFields' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'pending-batch' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q '_batch_progress.json' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'Early meeting sync' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'HQ prefill' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'COS_MEETING_PROGRESSIVE_HQ_THREADS' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'Balanced CPU guardrail\|tier.*CPU guardrail' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'meetingLifecycleStatusFields' "$ROOT/HelperSources/main.swift"

# --- 0.2.9 fixes -------------------------------------------------------------
# A failed install must not strand in-place mode off: the marker is captured
# before the throw sites, dropped only at the point of no return, and restored
# when the switch rolls back.
/usr/bin/grep -q 'let inPlaceMarker = try? Data(contentsOf: inPlaceURL)' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'if let inPlaceMarker { try? inPlaceMarker.write(to: inPlaceURL' "$ROOT/HelperSources/main.swift"
# A support report must name the build that produced it.
/usr/bin/grep -q 'add("COS Control", "ok", appIdentity' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q '"--current-version", Self.currentVersion' "$ROOT/Sources/ControllerModel.swift"

# --- P1 app-update checker: behavior, not just needles -----------------------
# Each case is a regression the plan names. Failures print WHICH case broke, so this
# can never fail silently the way a bare `grep -q` does.
AC_DIR="$TMP/appcast"
/bin/mkdir -p "$AC_DIR"
/bin/cat > "$AC_DIR/newer.json" <<'JSON'
{"schemaVersion":1,"channels":{"stable":{"version":"0.3.0","build":17,"url":"https://x/y.zip","sha256":"a"}},"killSwitch":{"disableAutoUpdate":false}}
JSON
/bin/cat > "$AC_DIR/older.json" <<'JSON'
{"schemaVersion":1,"channels":{"stable":{"version":"0.1.0","build":1,"url":"https://x/y.zip","sha256":"a"}},"killSwitch":{"disableAutoUpdate":false}}
JSON
/bin/cat > "$AC_DIR/kill.json" <<'JSON'
{"schemaVersion":1,"channels":{"stable":{"version":"9.9.9","build":99,"url":"https://x/y.zip","sha256":"a"}},"killSwitch":{"disableAutoUpdate":true}}
JSON
/bin/cat > "$AC_DIR/bad.json" <<'JSON'
{"schemaVersion":1,"nonsense":true}
JSON

assert_update () {  # <label> <fixture-url> <expected-available> <expected-reason>
  local out
  out="$("$TMP/cos-control-helper" check-app-update --current-version 0.2.5 --current-build 16 --appcast-url "$2")"
  /usr/bin/python3 - "$1" "$out" "$3" "$4" <<'PY'
import json,sys
label, raw, want_avail, want_reason = sys.argv[1], sys.argv[2], sys.argv[3]=="true", sys.argv[4]
d = json.loads(raw); det = d.get("details", d)
if det.get("updateAvailable") is not want_avail or det.get("reason") != want_reason:
    print(f"app-update check FAILED [{label}]: got available={det.get('updateAvailable')} "
          f"reason={det.get('reason')}, wanted available={want_avail} reason={want_reason}", file=sys.stderr)
    raise SystemExit(1)
PY
}
assert_update "newer"       "file://$AC_DIR/newer.json" true  newer
assert_update "downgrade"   "file://$AC_DIR/older.json" false upToDate   # R6: never advertise a downgrade
assert_update "killSwitch"  "file://$AC_DIR/kill.json"  false killSwitch # R7: publisher can stop the fleet
assert_update "malformed"   "file://$AC_DIR/bad.json"   false malformed  # silent no-op
assert_update "unreachable" "file://$AC_DIR/absent.json" false unreachable # offline is not an error

# The check path must stay READ-ONLY: no lock, no launchd, no ~/.cos-glasses writes. [R1/R9]
if /usr/bin/grep -A60 'private func emitAppUpdateCheck' "$ROOT/HelperSources/main.swift" \
   | /usr/bin/grep -E 'withMutationLock|launchctl|glasses-server|\.cos-glasses'; then
  echo "check-app-update must not mutate state or touch the glasses server" >&2
  exit 1
fi

/usr/bin/grep -q 'com.cos.glasses-control-recovery' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q '"StartInterval": 60' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'flock(descriptor, LOCK_EX | LOCK_NB)' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'setServiceEnabled(false)' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'desiredState = "stopped"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'Restart this self-managed server?' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'retains the old LaunchAgent environment' "$ROOT/HelperSources/main.swift"

if /usr/bin/grep -RE 'details\["token"\]|"token"[[:space:]]*:[[:space:]]*try readToken' "$ROOT/Sources" "$ROOT/HelperSources"; then
  echo "Token material must never cross helper JSON or controller state" >&2
  exit 1
fi

swiftc -target "$TARGET" -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" \
  "$ROOT/Sources/HelperClient.swift" \
  "$ROOT/Sources/ControllerModel.swift" \
  "$ROOT/Sources/Views.swift" \
  "$ROOT/Sources/COSControlApp.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement \
  -o "$TMP/COS Control"

/usr/bin/vtool -show-build "$TMP/cos-control-helper" | /usr/bin/grep -q 'minos 14.0'
/usr/bin/vtool -show-build "$TMP/COS Control" | /usr/bin/grep -q 'minos 14.0'

echo "COS Control: helper self-tests, secret-boundary checks, and macOS 14 builds passed"
