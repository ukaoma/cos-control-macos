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

# --- 0.4.0 speaker review ------------------------------------------------------
# Shape checks, so treat the macOS build above as the real gate. What they pin is
# the set of invariants that would break SILENTLY rather than fail to compile.
/usr/bin/grep -q 'case "meeting-speakers"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "voice-merge"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "voice-profiles"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'struct SpeakerReviewPane' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'reviewableMeetingsCard' "$ROOT/Sources/Views.swift"
# A merge must be a two-step: no --confirm means the helper asks the server for a
# dryRun preview, never a merge. Losing this makes the confirmation decorative.
/usr/bin/grep -q 'if confirm { payload\["confirm"\] = true } else { payload\["dryRun"\] = true }' "$ROOT/HelperSources/main.swift"
# The owner profile is checked first on every live chunk; absorbing it away would
# silently break identification for the wearer.
/usr/bin/grep -q 'reliability != .unattributed && !isOwner' "$ROOT/Sources/Models.swift"
# Phrases are the primary evidence in a row — a score cannot identify anyone.
/usr/bin/grep -q 'voice.phrases' "$ROOT/Sources/Views.swift"

# --- 0.5.0 scoped corrections, playback, real ribbon ---------------------------
# Every view struct the review pane composes. Added after a refactor sliced from
# TurnRibbon to SpeakerReviewPane and silently deleted ConfidenceRamp and VoiceRow
# in between — the suite only noticed via an unrelated `voice.phrases` guard, and
# the build stage that would have caught it runs AFTER these checks.
for symbol in 'struct TurnRibbon' 'struct ConfidenceRamp' 'struct VoiceRow' 'struct MediaPreviewPane'; do
  /usr/bin/grep -q "$symbol" "$ROOT/Sources/Views.swift" || {
    echo "COS Control: $symbol is missing from Views.swift" >&2; exit 1; }
done

# The scoped endpoints exist, and each is a TWO-STEP like voice-merge: without
# --confirm the helper asks for a dryRun. Losing this makes confirmation
# decorative — the user would be agreeing to something already applied.
/usr/bin/grep -q 'case "meeting-relabel"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "meeting-deattribute"' "$ROOT/HelperSources/main.swift"
# BOTH scoped endpoints must be two-step, counted rather than matched once: a
# single grep passes while the other endpoint applies without a preview.
[ "$(/usr/bin/grep -c 'if args.contains("--confirm") { payload\["confirm"\] = true } else { payload\["dryRun"\] = true }' "$ROOT/HelperSources/main.swift")" -ge 2 ]

# PER-MEETING IS THE DEFAULT. This is the whole point of 0.5.0: until now every
# rename called the global merge, so correcting one meeting rewrote every meeting
# that person appears in.
/usr/bin/grep -q 'correctionScope: CorrectionScope = .thisMeeting' "$ROOT/Sources/ControllerModel.swift"
# ...and the per-meeting path must actually route to the per-meeting endpoint.
# The line FOLLOWING the scope test must be the per-meeting endpoint. A bare grep
# for "meeting-relabel" anywhere in the file is not enough: it also appears in
# confirmCorrection, so pointing the preview branch at the global merge left the
# guard green while restoring exactly the 0.4.x behaviour this release removes.
/usr/bin/grep -A1 'scope == .thisMeeting$' "$ROOT/Sources/ControllerModel.swift" | /usr/bin/grep -q 'meeting-relabel'
# And confirming must route the same way, or the preview would describe one thing
# and the save would do another.
/usr/bin/grep -A2 'correction.scope == .thisMeeting {' "$ROOT/Sources/ControllerModel.swift" | /usr/bin/grep -q 'meeting-relabel'

# The assertion decision is READ from the server, never re-derived here, so the
# lens, the phone and this panel cannot disagree about who was identified.
/usr/bin/grep -q 'nameAsserted = o\["nameAsserted"\]' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'voice.displayName' "$ROOT/Sources/Views.swift"

# The ribbon is a TIMELINE. It previously drew one rect per voice sized by share
# of segments while calling itself "who spoke, in order", so hover had nothing
# true to report. It must read the server's spans.
/usr/bin/grep -q 'review.timeline' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'timeline = (o\["timeline"\]' "$ROOT/Sources/Models.swift"
# Hover and legend both exist, and the legend shares the bar's tint function so
# the two cannot drift apart.
/usr/bin/grep -q 'Hover the bar to see who is speaking' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'Self.tint(for: speaker, order: order, review: review)' "$ROOT/Sources/Views.swift"

# Playback must verify it received actual audio. This path writes a file handed
# to an audio player, so a mislabelled payload is refused rather than played.
/usr/bin/grep -q 'case "review-audio"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q '0x52, 0x49, 0x46, 0x46' "$ROOT/HelperSources/main.swift"
# One player reference is held on the model: AVAudioPlayer stops the instant its
# last reference drops, so a local would silently play nothing.
/usr/bin/grep -q 'private var audioPlayer: AVAudioPlayer?' "$ROOT/Sources/ControllerModel.swift"

# De-attribution is offered in the row, and is always per-meeting — "not in THIS
# room" says nothing about any other meeting, so there is no global variant.
/usr/bin/grep -q 'Not in this meeting' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'previewDeattribution' "$ROOT/Sources/ControllerModel.swift"

# --- 0.5.1 QA blocker fixes ----------------------------------------------------
# Confirming a correction must READ the outcome. The helper reports 400/409/422 as
# a state rather than throwing, so discarding the response reported "Removed X"
# for a server that refused and changed nothing — the same defect 0.4.2 fixed one
# layer down.
/usr/bin/grep -q 'guard state == "applied" else' "$ROOT/Sources/ControllerModel.swift"
# A stalled earlier correction must have a reachable exit. Nothing passed --force
# before, and the message told the user to re-open the meeting, which changes no
# server state.
/usr/bin/grep -q 'func forceCorrection' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'Apply anyway' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'if force { args.append("--force") }' "$ROOT/Sources/ControllerModel.swift"

# Playback plays THIS LINE's audio, addressed by the RAW capture index. Position
# in the chunk array is a different number — on the 2026-08-06 Ditto sidecar
# position 884 is raw chunk 940, so the array position plays the wrong speaker.
/usr/bin/grep -q 'chunkIndex = o\["chunkIndex"\]' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'func playPhrase' "$ROOT/Sources/ControllerModel.swift"
# A button only appears where the server still HOLDS that chunk.
/usr/bin/grep -A4 'func canPlay' "$ROOT/Sources/ControllerModel.swift" | /usr/bin/grep -q 'retainedAudioChunks.contains'
/usr/bin/grep -q 'model.canPlay(phrase)' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'review-audio-list' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'case "review-audio-list"' "$ROOT/HelperSources/main.swift"
# A 404 from a MISSING ROUTE must not claim the audio expired — that is a
# confident false statement about retention on any older server.
[ "$(/usr/bin/grep -c 'route_missing' "$ROOT/HelperSources/main.swift")" -ge 2 ]
/usr/bin/grep -q 'route_missing' "$ROOT/Sources/ControllerModel.swift"

# Span identity is POSITIONAL. Value-based ids collided on 28 real sidecars (161
# duplicates on one), which SwiftUI answers with dropped or misdrawn rows.
/usr/bin/grep -q 'var id: Int { index }' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'SpeakerTimelineSpan($1, index: $0)' "$ROOT/Sources/Models.swift"
# The ribbon aggregates into fixed columns. One rect per span needed 1,079pt in a
# 358pt panel and overflowed on 133 of 133 meetings over 200 segments.
/usr/bin/grep -q 'private func columns(width' "$ROOT/Sources/Views.swift"

# The playback note is keyed to ONE row: a shared string printed the same failure
# under all eleven voices at once.
/usr/bin/grep -q 'note.key.hasPrefix(voice.label)' "$ROOT/Sources/Views.swift"
# Closing the panel stops audio and resets scope. Audio kept playing after close,
# and a sticky "Every meeting" is the irreversible global fold this release removes.
/usr/bin/grep -A12 'func closeSpeakerReview' "$ROOT/Sources/ControllerModel.swift" | /usr/bin/grep -q 'stopPlayback()'
# COUNTED rather than pinned to a line offset: scope must be reset on open, on
# close, on cancel and after a successful save. A `grep -A8` guard broke the
# moment a comment moved the line, which is the wrong thing to be sensitive to.
[ "$(/usr/bin/grep -c 'correctionScope = .thisMeeting' "$ROOT/Sources/ControllerModel.swift")" -ge 4 ]

# The scope copy must not claim profile training. The correction-to-enrolment path
# is not built: the per-chunk embedding store is write-only and nothing writes
# `correction:` provenance.
if /usr/bin/grep -q 'teaches the voice profile' "$ROOT/Sources/Models.swift"; then
  echo "COS Control: the scope copy claims profile training that no code performs" >&2
  exit 1
fi

# --- 0.4.1 overlay regression ---------------------------------------------------
# MenuBarExtra(.window) is a transient panel that closes when it loses key status,
# so ANY sheet presented from it dismisses the panel mid-interaction. This is the
# regression guard: zero sheet presentations in the panel's view tree.
if /usr/bin/grep -q '\.sheet(' "$ROOT/Sources/Views.swift"; then
  echo 'COS Control: FAIL — a .sheet reappeared in Views.swift; MenuBarExtra panels must route overlays inline' >&2
  exit 1
fi
/usr/bin/grep -q 'struct SpeakerReviewPane' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'struct MediaPreviewPane' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'reviewRouteActive' "$ROOT/Sources/Views.swift"
# The route reads lastReviewSession, so it must be observable or the panel can
# read a stale value and never re-render.
/usr/bin/grep -q '@Published private var lastReviewSession' "$ROOT/Sources/ControllerModel.swift"

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
