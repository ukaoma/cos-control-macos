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

# THE APP ITSELF MUST COMPILE.
#
# Until 0.5.44 this suite built the helper and Models.swift and then only grepped
# Views.swift and ControllerModel.swift -- so every UI and model change shipped
# without ever being type-checked here, and "builds passed" meant something much
# narrower than it read. Same source list as scripts/build-release.sh.
swiftc -target "$TARGET" -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" \
  "$ROOT/Sources/HelperClient.swift" \
  "$ROOT/Sources/ControllerModel.swift" \
  "$ROOT/Sources/COSBrand.swift" \
  "$ROOT/Sources/COSMotion.swift" \
  "$ROOT/Sources/COSConfirm.swift" \
  "$ROOT/Sources/Views.swift" \
  "$ROOT/Sources/ActivityWindow.swift" \
  "$ROOT/Sources/ActivityMeetings.swift" \
  "$ROOT/Sources/SessionPet.swift" \
  "$ROOT/Sources/COSControlApp.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement \
  -o "$TMP/COS Control"

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

# Release build must compile the component too, or the shipped app loses it.
/usr/bin/grep -q 'Sources/COSConfirm.swift' "$ROOT/scripts/build-release.sh"

# ── Confirmations must never go back to .confirmationDialog ──────────────────
# Inside MenuBarExtra(.window) a confirmationDialog's non-cancel button action
# NEVER RUNS. Proven on-device 2026-08-23 by Tests/fence-canary: variants A and B
# logged the dismissal and never the action; the inline component logged it every
# time. Nine dialogs shipped that way and every destructive action among them was
# inert -- Release fence, Reset live message count, Clear stranded video uploads,
# Restart self-managed server, Stop legacy and install.
#
# Comments are stripped first ON PURPOSE. Views.swift and COSConfirm.swift both
# explain this rule in prose, so a plain grep would match the explanation and pass
# no matter what the code did -- the exact shape of assertion that let this through.
/usr/bin/python3 - "$ROOT" <<'PYCHK'
import io, re, sys, pathlib
root = pathlib.Path(sys.argv[1])

def code(rel):
    text = io.open(root / rel, encoding='utf-8').read()
    return chr(10).join(l for l in text.split(chr(10)) if not l.strip().startswith('//'))

views = code('Sources/Views.swift')
assert '.confirmationDialog(' not in views, \
    'Views.swift uses .confirmationDialog - its actions do not run in MenuBarExtra(.window). Use .cosConfirm.'
n = views.count('.cosConfirm(')
assert n >= 10, 'expected >=10 .cosConfirm call sites, found %d' % n

# Any surviving .alert may carry ONLY a cancel-role button: cancel actions do run,
# everything else does not.
for m in re.finditer(r'\.alert\(', views):
    block = views[m.start():m.start() + 900]
    for label, role in re.findall(r'Button\("([^"]+)"(?:, role: \.(\w+))?\)', block):
        assert role == 'cancel', \
            '.alert button "%s" has role=%s; only role:.cancel runs in this panel' % (label, role or 'none')

confirm = code('Sources/COSConfirm.swift')
assert '.confirmationDialog(' not in confirm and '.alert(' not in confirm, \
    'COSConfirm must stay a plain inline overlay'
assert 'overlay' in confirm, 'COSConfirm lost its inline overlay'

# cosConfirm dismisses BEFORE running the action, and dismissal nils
# fencePendingRelease, so an action that read the model would guard-out and release
# nothing. The record is captured while the confirmation is on screen.
assert 'let pending = model.fencePendingRelease' in views, \
    'fenceConfirmActions must capture the record at build time, not read it in the action'

# The canary compiles the SHIPPED component, not a copy of it.
canary = io.open(root / 'Tests/fence-canary/run.sh', encoding='utf-8').read()
assert 'Sources/COSConfirm.swift' in canary, 'canary must compile the real component'
print('  confirmation-presentation guards passed (%d cosConfirm sites)' % n)
PYCHK

# Claude sessions toggle. The helper shipped set-claude-sessions and wrote both env
# keys through the manifest, but NOTHING in the app ever invoked it, so the feature
# was reachable only via an undocumented env var and read as broken to a beta
# tester. Pin all three links: helper command, model call, and a view that calls the
# model. Three working parts with no wiring between them is the failure this catches.
/usr/bin/grep -q 'case "set-claude-sessions"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'perform("set-claude-sessions"' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'model.setClaudeSessionsEnabled(' "$ROOT/Sources/Views.swift"

# ── Every panel toggle must be bound from STATUS ─────────────────────────────
# Extracted to its own file: the check needs regexes with backslashes, and inlining
# it in a heredoc mangled them into a syntax error that LOOKED like a failing test.
/usr/bin/python3 "$ROOT/Tests/panel-toggle-source.py" "$ROOT/Sources/Views.swift"

# THE FOUR DEFAULT-ON GATES MUST GO THROUGH THE SHARED RESOLVER.
#
# featureGateDefaultOn is unit-tested in the helper self-test, but that proves
# nothing if a call site quietly reverts to `== "1"`. This asserts the wiring.
# Comment lines are stripped first: the prose above each site explains the rule
# and would otherwise satisfy the check on its own.
/usr/bin/python3 - "$ROOT/HelperSources/main.swift" <<'PY'
import io, re, sys
code = '\n'.join(
    l for l in io.open(sys.argv[1], encoding='utf-8').read().split('\n')
    if not l.strip().startswith('//')
)
for key in ('COS_WHISPER_MEETING_PREVIEW', 'configuredThreadAttach',
            'configuredVideoUploadV2', 'configuredAdaptiveAudioCleanup'):
    # The key must appear within a featureGateDefaultOn(...) call.
    if not re.search(r'featureGateDefaultOn\(\s*(?:\n\s*)?[^)]*' + re.escape(key), code):
        raise SystemExit(
            'FAIL: %s no longer resolves through featureGateDefaultOn. '
            'A default-ON gate compared with == "1" renders OFF for every user '
            'who never set the variable.' % key
        )
    # And it must NOT also be compared to "1" anywhere.
    if re.search(re.escape(key) + r'\s*==\s*"1"', code):
        raise SystemExit('FAIL: %s is still compared to == "1"' % key)
print('default-on gate wiring: 4/4 OK')
PY
# and the switched-off state must say so rather than render an ordinary empty list
/usr/bin/grep -q 'Claude sessions are switched off' "$ROOT/Sources/ActivityWindow.swift"
echo "COS Control: Claude sessions toggle wired helper -> model -> view"
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
/usr/bin/grep -q 'case "set-idle-metal-hq"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'COS_BATCH_HQ_METAL' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'COS_BATCH_HQ_FORCE_CPU' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'requireIdleMetalHq' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'Idle Metal HQ' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'case "set-adaptive-audio-cleanup"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "set-video-upload-v2"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "clear-stranded-video-uploads"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "reset-message-era"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "meeting-orphans"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "meeting-orphan-recover"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "meeting-stranded-save"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "meeting-stranded-save-all"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'Save still-live captures as meetings' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'model.saveStranded' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'model.saveAllStranded' "$ROOT/Sources/ActivityMeetings.swift"
/usr/bin/grep -q 'lastCustomTitle' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'recentClaudeConversations' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "claude-session-detail"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'claudeKickstartCopy' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'recentCodexConversations' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'recentCursorConversations' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'empty-window' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'loadCursorComposerNames' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'pinned-thread-ids' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'providerBadge' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'Claude · Codex · Cursor' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'isKeepWarmSessionTitle' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case pinned' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'case .pinned:' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'Fireflies meeting sync' "$ROOT/Tests/ModelsContract.swift"
/usr/bin/grep -q 'case "meeting-sync-now"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'Run sync now' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'meetingSyncTooling' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'cos_python' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'recoverableOrphanSessionIds' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'waitForOrphanSlot' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'Recover all unsaved captures' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'Recover all unsaved captures' "$ROOT/Sources/ActivityMeetings.swift"
/usr/bin/grep -q 'recoverableOrphans.isEmpty || !model.strandedCaptures.isEmpty' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'model.recoverAllOrphans' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'model.recoverOrphan' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'Unsaved captures' "$ROOT/Sources/ActivityMeetings.swift"
/usr/bin/grep -q "This is not Speakers" "$ROOT/Sources/ActivityMeetings.swift"
if /usr/bin/grep -q '/api/meeting/orphans route' "$ROOT/Sources/Views.swift"; then
  echo "COS Control: user-facing copy still tells the user to curl orphans" >&2
  exit 1
fi
/usr/bin/grep -q 'struct OrphanCapture' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'isStrandedReceivingVideoUpload' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'Clear stranded' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'clearStrandedVideoUploads' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'resetMessageEra' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'Archive live messages and start numbering at #1' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'Reset live message count' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'Repair does not do this' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'It does not cancel stranded V2 video drafts' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'COS_MEETING_AUDIO_ADAPTIVE_PLAYBACK' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'requireAdaptiveAudioCleanup' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'Adaptive audio cleanup' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'playbackTask?.cancel()' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'playbackRequestID == requestID' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'stoppedCompatibleManagedServer' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'configuredRequestedTier' "$ROOT/HelperSources/main.swift"
/usr/bin/python3 - "$ROOT" <<'PY'
import pathlib, re, sys
source = (pathlib.Path(sys.argv[1]) / "HelperSources/main.swift").read_text()
invalid = re.findall(r'operationKind:\s*"(provider_env_update|workdir_update)"', source)
if invalid:
    raise SystemExit(f"internal labels leaked into maintenance operation contract: {invalid}")
branch = source.index("if alreadyActive || snapshot.allListenerPIDs.isEmpty")
proof = source.index("try requireAdaptiveAudioCleanup", branch)
clear = source.index("clearInPlaceConfigurationTransaction()", branch)
restore = source.index("restoreInPlaceConfiguration(transaction)", branch)
if not proof < clear < restore:
    raise SystemExit("in-place adaptive proof must run before transaction clear, with rollback retained")
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
/usr/bin/grep -q 'case "voice-directory"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'struct VoiceDirectoryPerson' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'private var voiceDirectoryList' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'Meetings to review' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'speakerSubview: SpeakerSubview = .meetings' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'case meetings' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'meetingsRefreshNeeded' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'peekReviewableMeetings' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'struct SpeakerListMemory' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'nextUnnamed' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'voicesForReview' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'Hide reviewed' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'Next to name' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'struct MeetingStatusPills' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'meetingStatusTags' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'voiceReview' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "meetings-library"' "$ROOT/HelperSources/main.swift"

# --- 0.5.65 empty-review reason (issues #1, #2) --------------------------------
# An empty speaker-review list has more than one cause and the old text named the
# only one that could not help: "predate speaker review. Update the server."
# `skipped` counts rows dropped for having no sessionId, never a version problem.
# The real cause for a new user is zero enrolled voices, which cannot self-heal
# (autoEnroll needs a match against an existing profile and skips Ext).
#
# These pin the three things that would silently regress:
#   1. the misleading sentence never comes back
#   2. the zero-profile case is reported, and names the action
#   3. the count is asked for, not inferred from a list another subview loads
# COMMENT-AWARE. A plain grep here matched the doc comment that RECORDS the old
# wording, so the guard failed on the very explanation that makes it legible.
# That is the "assertion satisfied by the file's own prose" failure, caught by
# running it. Strip comments, then assert against code only.
/usr/bin/python3 - "$ROOT/Sources/ControllerModel.swift" <<'PYEOF'
import io, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
code = '\n'.join(l for l in src.split('\n') if not l.strip().startswith('//'))
for banned in ('predate speaker review', 'Update the server to review new ones'):
    assert banned not in code, f"FAIL: the 'Update the server' review error returned ({banned!r})"
print('    misleading review error is gone from code (comments may still cite it)')
PYEOF
/usr/bin/grep -q 'func emptyReviewReason' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'voice-directory' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'No voices are enrolled yet' "$ROOT/Sources/ControllerModel.swift"
# Both empty-state messages must name the enrolment phrase, or the user is told
# what is wrong with no way to act on it. Control's Speakers pane is view-only.
/usr/bin/python3 - "$ROOT/Sources/ControllerModel.swift" <<'PYEOF'
import io, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
code = '\n'.join(l for l in src.split('\n') if not l.strip().startswith('//'))
hits = code.count('enroll my voice')
assert hits >= 2, f'expected both empty-state messages to name the enrolment phrase, found {hits}'
print('    empty-state messages name the enrolment phrase (%d sites)' % hits)
PYEOF
echo "    empty-review reason: misleading text gone, zero-profile case named"

# --- 0.5.66 add a voice (#2) ---------------------------------------------------
# The explicit surface for creating a NET-NEW profile. Naming inside a meeting
# review can only rename a voice the system already separated; a user whose whole
# transcript came back Ext has nothing to rename.
#
# Same shape as the other panel guards: tie the OPENER to the thing it renders,
# and pin the safety properties that would regress silently.
/usr/bin/grep -q 'case "voice-ext-audio"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "voice-enroll-ext"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'struct ExtAudioSession' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'func loadExtAudio' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'func addVoice' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'private var addVoiceSection' "$ROOT/Sources/ActivityWindow.swift"
# The opener must reach the renderer. A button bound to state nothing renders is
# the dead-wiring failure this suite already guards elsewhere.
/usr/bin/grep -q 'addingVoiceSession = session.sessionId' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'addVoiceNameField(session)' "$ROOT/Sources/ActivityWindow.swift"
# ZERO-PROFILE USERS ARE THE POINT. If addVoiceSection renders only in the
# non-empty branch, the people who need it most never see it.
/usr/bin/python3 - "$ROOT/Sources/ActivityWindow.swift" <<'PYEOF'
import io, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
code = '\n'.join(l for l in src.split('\n') if not l.strip().startswith('//'))
uses = code.count('addVoiceSection')
# one declaration + at least two render sites (empty and non-empty branches)
assert uses >= 3, f'addVoiceSection must render in BOTH the empty and populated directory; found {uses} references'

# THE CARD MUST STAY A CARD. addVoiceSection renders OUTSIDE the voice
# directory's ScrollView, so an uncapped ForEach over held sessions grew the
# layout past the window and took the section header, the view picker and the
# breadcrumbs with it (production, 2026-08-26, 30+ held sessions).
import re as _re
section = code[code.index('private var addVoiceSection'):]
section = section[:section.index('private func addVoiceRow')]
assert 'extAudioInlineRowLimit' in section, \
    'the held-audio list must be capped before it renders inline'
assert 'ScrollView' in section and 'extAudioListHeight' in section, \
    'a capped held-audio list must scroll inside a fixed frame, never expand the layout'
assert _re.search(r'\.frame\(height: Self\.extAudioListHeight\)', section), \
    'the held-audio ScrollView needs an explicit height; maxHeight lets it grow'
print('    add-a-voice renders in both empty and populated directory')
PYEOF
# SAFETY: the helper must never offer the unscoped enrol. The server calls it a
# profile-poisoning default -- it assumes one speaker across every held session
# and deletes them all.
/usr/bin/python3 - "$ROOT/HelperSources/main.swift" <<'PYEOF'
import io, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
code = '\n'.join(l for l in src.split('\n') if not l.strip().startswith('//') and not l.strip().startswith('///'))
assert 'confirmAllSessions' not in code, 'helper must never send confirmAllSessions'
i = code.find('func emitVoiceEnrollExt')
assert i > 0, 'emitVoiceEnrollExt missing'
body = code[i:i + 2000]
# Testing for the STRING '--session' only proves the flag is MENTIONED, not that
# it is required: a mutation replacing the guard with a defaulted `?? ""` passed
# that check. Pin the REFUSAL instead. This message lives only in the guard's
# else branch, so it cannot survive the guard being removed.
assert 'is not offered' in body, 'enrol-ext must REFUSE a missing session, not default it'
assert 'guard let session' in body, 'enrol-ext must guard the session, not read it optionally'
assert 'sessionId' in body, 'enrol-ext must scope the payload to one session'
print('    enrol-ext is scoped to one session; unscoped form unreachable')
PYEOF
# The user must be told the audio is consumed and may hold more than one speaker.
/usr/bin/grep -q 'more than one unknown speaker' "$ROOT/Sources/ActivityWindow.swift"
echo "    add a voice: helper, model, view, and safety copy wired"

# --- 0.5.67 manual update check -----------------------------------------------
# The automatic check runs at launch then every 6h and is deliberately SILENT on
# failure. Silence is the wrong contract for a button: a user who clicks and sees
# nothing cannot tell "up to date" from "the check failed" from "this is broken".
# Measured 2026-08-24: a Control up since the previous afternoon was two builds
# behind with no banner and no way to ask.
/usr/bin/grep -q 'func checkForAppUpdateManually' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'Check for updates' "$ROOT/Sources/Views.swift"

# --- 0.5.71 publisher notice --------------------------------------------------
# The property that matters is INDEPENDENCE FROM updateAvailable. The audience is
# people who just finished updating, so any coupling to the update-offer path
# hides the notice from exactly the readers it is written for.
/usr/bin/python3 - "$ROOT" <<'PYEOF'
import io, pathlib, sys
root = pathlib.Path(sys.argv[1])
helper = io.open(root / "HelperSources/main.swift", encoding="utf-8").read()
models = io.open(root / "Sources/Models.swift", encoding="utf-8").read()
ctrl   = io.open(root / "Sources/ControllerModel.swift", encoding="utf-8").read()
views  = io.open(root / "Sources/Views.swift", encoding="utf-8").read()

# The notice must be parsed BEFORE the early returns, or killSwitch/malformed/
# requiresMacOS silently swallow it.
i_notice = helper.index('details["noticeId"] = noticeId')
i_kill   = helper.index('details["reason"] = "killSwitch"')
assert i_notice < i_kill, 'notice must be attached BEFORE the killSwitch early return'
assert 'currentBuild >= minBuild' in helper, 'minBuild must gate the notice to builds that have the feature'

assert 'noticeId = details["noticeId"]?.string' in models, 'model must parse noticeId'
assert 'var hasNotice: Bool' in models, 'model must expose hasNotice'
assert 'updateAvailable && ' not in models.split('var hasNotice')[1][:200], \
    'hasNotice must NOT depend on updateAvailable'

assert 'dismissedNoticeIds' in ctrl and 'UserDefaults' in ctrl, 'dismissal must persist'
assert 'dismissedNoticeIds.contains(id)' in ctrl, 'dismissal must be keyed per notice id'

assert 'noticeBanner' in views.split('updateBanner')[1][:400], 'banner must render in the panel'
assert 'model.dismissNotice(id)' in views, 'banner must offer dismiss'
print('    publisher notice: parsed pre-return, minBuild-gated, update-independent, dismissible')
PYEOF

# --- 0.5.72 archive browser ---------------------------------------------------
# Same shape as the other panel guards: tie the OPENER to the thing it renders and
# pin the properties that would regress silently.
#
# The route_absent branch is the load-bearing one. COS Control updates
# independently of the npm server, and an older server does NOT 404 for
# /archive/search -- it falls the path through to /archive/:date and answers 400
# "Invalid date". Verified live against 6.37.3. Without that discriminator a user
# on an older server sees "Invalid date" instead of "update your server".
/usr/bin/grep -q 'case "archive-dates"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "archive-search"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "archive-day"' "$ROOT/HelperSources/main.swift"
/usr/bin/python3 - "$ROOT" <<'PYEOF'
import io, pathlib, sys
root = pathlib.Path(sys.argv[1])
helper = io.open(root / "HelperSources/main.swift", encoding="utf-8").read()
model  = io.open(root / "Sources/ControllerModel.swift", encoding="utf-8").read()
view   = io.open(root / "Sources/ActivityWindow.swift", encoding="utf-8").read()
models = io.open(root / "Sources/Models.swift", encoding="utf-8").read()

assert 'response.status == 400' in helper and '"Invalid date"' in helper, \
    'search must treat an older server\'s 400 "Invalid date" as route_absent'
assert 'response.status == 404 || oldServerFallthrough' in helper, \
    'both the 404 and the 400 fallthrough must reach route_absent'
assert 'isArchiveDateString(date)' in helper, 'a date reaching a filesystem path must be validated'
# The listing must PROBE before it lists. On a server predating the archive index,
# GET /api/archive parses every day file (1.2 GB on the real corpus). Opening the
# view must never be what triggers that.
assert '__cos_probe__' in helper, 'archive-dates must probe the search route before calling /api/archive'
probe_at = helper.index('__cos_probe__')
list_at = helper.index('request("/api/archive", token: token')
assert probe_at < list_at, 'the probe must run BEFORE the expensive listing call'

assert 'func loadArchiveDays()' in model and 'func runArchiveSearch()' in model
assert 'archiveQuery.trimmingCharacters' in model, 'search must reject a too-short query before calling out'

assert 'messagesSubview == .archive' in view, 'the Archive subview must render on its own flag'
assert 'archiveBody' in view, 'the picker must reach a body'
assert '.onSubmit { Task { await model.runArchiveSearch() } }' in view, \
    'search runs on submit, never per keystroke -- a wide window is a multi-second server scan'
# `day.countsSummary`, not bare 'countsSummary': meeting.countsSummary also lives
# in this file, so the loose form is satisfied by an unrelated row and the
# assertion survives deleting the archive counts entirely. Caught by mutating the
# archive row and watching the suite stay green.
assert 'Text(day.countsSummary)' in view, 'the ARCHIVE day list must show chat/message VOLUME, not just a date'
assert 'chat\\(chatCount == 1 ? "" : "s")' in models, 'countsSummary must report chat count'
print('    archive browser: helper, model, view, and route_absent discriminator wired')
PYEOF

# --- 0.5.74 ollama acknowledgement ----------------------------------------------
# The row is HIDE-UNLESS-READY, and the failure mode is painting a red mark on
# every Mac without a local daemon. Pin the whole chain and its guards.
/usr/bin/python3 - "$ROOT" <<'PYEOF'
import io, pathlib, sys
root = pathlib.Path(sys.argv[1])
helper = io.open(root / "HelperSources/main.swift", encoding="utf-8").read()
models = io.open(root / "Sources/Models.swift", encoding="utf-8").read()
views  = io.open(root / "Sources/Views.swift", encoding="utf-8").read()

assert 'features["ollama"] as? Bool' in helper, 'ready must come from features.ollama'
# Scoped to the ollamaReady closure: the Doctor check also reads models["ready"],
# so a bare substring is satisfied even with the statusDetails gate gutted --
# caught by mutation M1 staying green against the loose form.
r = helper.index('"ollamaReady": {')
closure = helper[r:r+700]
assert 'models["ready"] as? Bool' in closure, 'statusDetails ready must ALSO require ollama_models.ready (TTL-lag gate)'
assert 'featureFlag && modelsReady' in closure, 'the gate must be the conjunction of BOTH bools'
assert 'health?["ollama"] as? Bool' not in helper, \
    'the top-level ollama key is a spread-check STRING ("fetch failed"); a Bool read is always nil'
o = helper.index('"ollamaModel": {')
assert 'versionToken' not in helper[o:o+400], 'the model tag must never route through versionToken'
assert 'ollamaReady = details["ollamaReady"]?.bool' in models
assert 'model.status.ollamaReady == true' in views, 'the row renders only on an explicit true'
assert 'good: model.status.ollamaReady ?? false' not in views, \
    'coalescing nil to false paints a red mark on every pre-6.39.0 server'
assert 'add("Ollama", "ok", tag)' in helper, 'doctor emits ok+tag only; no warning row for daemonless Macs'
print('    ollama acknowledgement: both-bools gate, no versionToken, hide-unless-ready pinned')
PYEOF

# --- 0.5.70 speaker-model banner -----------------------------------------------
# The failure this guards is INVISIBILITY, so the test pins the whole chain:
# helper reads the field, model exposes it, view renders on it. Any link broken
# and the banner silently never appears, which is the exact bug being fixed.
#
# The path assertion is the load-bearing one. health.ts assigns `checks.speaker_id`
# but spreads `checks` into the body, so a nested read is always nil.
/usr/bin/python3 - "$ROOT" <<'PYEOF'
import io, pathlib, sys
root = pathlib.Path(sys.argv[1])
helper = io.open(root / "HelperSources/main.swift", encoding="utf-8").read()
models = io.open(root / "Sources/Models.swift", encoding="utf-8").read()
views  = io.open(root / "Sources/Views.swift", encoding="utf-8").read()

assert '"speakerId": (health?["speaker_id"] as? String)' in helper, \
    'helper must read speaker_id from the TOP LEVEL of /api/health'
assert 'health?["checks"] as? [String: Any])?["speaker_id"]' not in helper, \
    'speaker_id is NOT under checks; that nested read is always nil'
assert 'speakerId = details["speakerId"]?.string' in models, 'model must parse speakerId'
assert 'speakerId != nil && speakerId != "active"' in models, \
    'nil (older server) must NOT trigger the banner'
assert 'model.status.speakerIdNeedsSetup' in views, 'view must render on the flag'
assert 'showGuidedSetupTier = true' in views.split('speakerIdNeedsSetup')[1][:1200], \
    'the banner must offer Guided Setup, the only path that fetches the model'
print('    speaker-model banner: helper -> model -> view, top-level path pinned')
PYEOF

# --- 0.5.69 duplicate Recover ---------------------------------------------------
# With exactly ONE recoverable capture the panel rendered two buttons both
# reading "Recover": a bulk button whose label collapsed to the singular, and the
# per-row button. Both fired the same recovery on the same session, one appeared
# greyed, and nothing told the user which was authoritative. Miles, 2026-08-25.
# The bulk button must be guarded on count > 1.
/usr/bin/grep -q 'if model.recoverableOrphans.count > 1 {' "$ROOT/Sources/Views.swift"
# And its label must be the plural one only -- a ternary here means the singular
# duplicate is back.
/usr/bin/grep -q 'Button("Recover all") { confirmRecoverAllOrphans = true }' "$ROOT/Sources/Views.swift"
! /usr/bin/grep -q 'recoverableOrphans.count == 1 ? "Recover"' "$ROOT/Sources/Views.swift"

# --- 0.5.69 footer CTAs ---------------------------------------------------------
# Both were .buttonStyle(.link) with no spacing, reading as one run-on string in
# a panel where every other action is a bordered chip. Quit especially must not
# look like body text.
/usr/bin/grep -q 'Button("Quit", systemImage: "power")' "$ROOT/Sources/Views.swift"
! /usr/bin/grep -q 'buttonStyle(.link)' "$ROOT/Sources/Views.swift"
echo '  Recover is single-CTA; footer actions are chips'
# Opener must reach the method it claims to call.
/usr/bin/grep -q 'await model.checkForAppUpdateManually()' "$ROOT/Sources/Views.swift"
# EVERY path must report. This is the whole point of the manual variant.
/usr/bin/python3 - "$ROOT/Sources/ControllerModel.swift" <<'PYEOF'
import io, re, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
code = '\n'.join(l for l in src.split('\n')
                 if not l.strip().startswith('//') and not l.strip().startswith('///'))
i = code.find('func checkForAppUpdateManually')
assert i > 0, 'checkForAppUpdateManually missing'
body = code[i:i + 1800]
assert 'is the latest version' in body, 'manual check must SAY when already up to date'
assert 'Could not reach the update feed' in body, 'manual check must REPORT a failure'
assert 'catch let' in body, 'must bind the caught error; a bare catch shadows self.error'
# It must not inherit the background check's swallow.
assert 'Intentionally swallowed' not in body, 'manual check must not swallow its failure'
print('    manual update check reports up-to-date, offer, and failure')
PYEOF
echo "    manual update check: button, method, and all three outcomes"
/usr/bin/grep -q 'case "meetings-library-search"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "context-memories-search"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "context-threads-search"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'struct ContextSearchHit' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'scheduleContextSearch' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'contextSearchBar' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'case "meeting-library-detail"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'libraryMeetingProjection' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'struct LibrarySearchHit' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'Search topics, ideas' "$ROOT/Sources/ActivityMeetings.swift"
/usr/bin/grep -q 'Six views into the work' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'Image(systemName: model.status.running ? "eyeglasses"' "$ROOT/Sources/COSControlApp.swift"
/usr/bin/grep -q '\.fixedSize()' "$ROOT/Sources/COSControlApp.swift"
! /usr/bin/grep -q 'Image(nsImage:' "$ROOT/Sources/COSControlApp.swift"
/usr/bin/grep -q 'eyeglasses.slash' "$ROOT/Sources/COSControlApp.swift"
/usr/bin/grep -q 'model.appUpdate.shouldSurface' "$ROOT/Sources/COSControlApp.swift"
! /usr/bin/grep -q 'hasNotice' "$ROOT/Sources/COSControlApp.swift"
/usr/bin/grep -q 'AppUpdateInfo.merging(previous: appUpdate, incoming:' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'static func merging(previous: AppUpdateInfo, incoming: AppUpdateInfo)' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'enum MenuBarIcon' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'case "openpets-catalog"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "openpets-thumb"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'static func isAllowedThumbURL' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -F -q 'COSControl/\(label) (macOS; +https://www.gotcos.com)' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'func loadOpenPetsCatalog' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'func installOpenPetsThumb' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'Pet gallery' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'Pet gallery unavailable right now.' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q '.frame(height: OpenPetsGallery.height)' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'TextField("Search pets"' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'await model.loadOpenPetsCatalog()' "$ROOT/Sources/Views.swift"
! /usr/bin/grep -q 'DisclosureGroup("Pet gallery"' "$ROOT/Sources/Views.swift"
/usr/bin/python3 - "$ROOT" <<'PY'
import io, pathlib, sys
root = pathlib.Path(sys.argv[1])
models = io.open(root / "Sources/Models.swift", encoding="utf-8").read()
helper = io.open(root / "HelperSources/main.swift", encoding="utf-8").read()
code_models = "\n".join(l for l in models.splitlines() if not l.strip().startswith("//"))
assert 'static let allowedExtensions: Set<String> = ["png", "gif", "jpg", "jpeg", "tiff", "tif", "webp"]' in code_models, \
    'PetSpriteStore allowedExtensions drifted'
assert '"zip"' not in code_models.split("allowedExtensions")[1].split("\n")[0], \
    "zip must not enter PetSpriteStore allowedExtensions"
assert 'url.host?.lowercased() == "openpets.dev"' in helper, 'thumb host gate missing'
assert 'refuseRedirects: true' in helper, 'OpenPets fetches must refuse redirects'
assert 'static func isOpenPetsWebP' in helper, 'webp magic check must be shared'
assert 'if let existing = try? Data(contentsOf: dest), Self.isOpenPetsWebP(existing)' in helper, \
    'openpets-thumb must reuse a valid on-disk thumb'
controller = io.open(root / "Sources/ControllerModel.swift", encoding="utf-8").read()
assert 'openPetsThumbOrder' not in controller, '32-thumb LRU must not evict gallery stills'
assert 'NSImage(data: data)' in controller, 'gallery thumbs must be memory-backed'
print("    openpets gallery pins: extensions, host gate, no-redirect")
PY
/usr/bin/grep -q 'COSLockupView' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'COSLockupView' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'COSGotcosCaption' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'Font.custom("Fraunces"' "$ROOT/Sources/COSBrand.swift"
/usr/bin/grep -q 'Font.custom("DM Sans"' "$ROOT/Sources/COSBrand.swift"
/usr/bin/grep -q 'Font.custom("JetBrains Mono"' "$ROOT/Sources/COSBrand.swift"
/usr/bin/grep -q 'ATSApplicationFontsPath' "$ROOT/Resources/Info.plist"
test -s "$ROOT/Resources/Fonts/Fraunces.ttf"
test -s "$ROOT/Resources/Fonts/Fraunces-Italic.ttf"
test -s "$ROOT/Resources/Fonts/DMSans.ttf"
test -s "$ROOT/Resources/Fonts/JetBrainsMono.ttf"
/usr/bin/grep -q 'Resources/Fonts/' "$ROOT/scripts/build-release.sh"
/usr/bin/grep -q 'COSLockupView(height: 17)' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'COSLockupView(height: 12)' "$ROOT/Sources/ActivityWindow.swift"
test -s "$ROOT/Resources/COSMark.svg"
test -s "$ROOT/Resources/COSLockup.svg"
/usr/bin/grep -q 'COSMark.svg' "$ROOT/scripts/build-release.sh"
/usr/bin/grep -q 'COSLockup.svg' "$ROOT/scripts/build-release.sh"
/usr/bin/grep -q 'case .meetings: meetingsList' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'struct MeetingLibraryDetailPane' "$ROOT/Sources/ActivityMeetings.swift"
/usr/bin/grep -q 'struct MeetingMonthCalendar' "$ROOT/Sources/ActivityMeetings.swift"
/usr/bin/grep -q 'struct LibraryMeeting' "$ROOT/Sources/Models.swift"
if /usr/bin/grep -q 'Five views into the work' "$ROOT/Sources/ActivityWindow.swift"; then
  echo "COS Control: Activity home still says Five views" >&2
  exit 1
fi
if /usr/bin/grep -q 'Four views into the work' "$ROOT/Sources/ActivityWindow.swift"; then
  echo "COS Control: Activity home still says Four views" >&2
  exit 1
fi
/usr/bin/grep -q 'case .sessions: sessionsList' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'case sessions' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'struct ClaudeSession' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'case "claude-sessions"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "claude-sessions-search"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'struct SessionSearchHit' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'scheduleSessionSearch' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'sessionsSearchBar' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'Search titles, transcripts' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'localSessionKeywordHits' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'server_too_old' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'loadClaudeDesktopIndex' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'claudeSidebarTitle' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'keywordHits' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'timeout: 12' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'peekSessionSearchBody' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'sessionSearchBodyFileLimit' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'enum SearchRecency' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'searchRecency' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'visibleLibrarySearchHits' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'visibleSessionSearchHits' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'visibleMemorySearchHits' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'visibleThreadSearchHits' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'Picker("Recency"' "$ROOT/Sources/ActivityMeetings.swift"
/usr/bin/grep -q 'Picker("Recency"' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1], "HelperSources/main.swift").read_text()
start = text.index("static func localSessionKeywordHits")
end = text.index("private func emitClaudeSessionsSearch")
body = text[start:end]
for needle in ("findCodexSessionFile", "findClaudeSessionFile", "findCursorSessionFile", "sessionSearchMaxAge"):
    if needle in body:
        sys.exit(f"local session search must not {needle}")
PY
/usr/bin/grep -q 'if response.status == 404' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'COS_CLAUDE_SESSIONS_ENABLED' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'COS_CLAUDE_SESSIONS_SHOW_NAMES' "$ROOT/HelperSources/main.swift"

# --- 0.5.43 Continue an agent thread -------------------------------------
# The server reads COS_THREAD_ATTACH_ENABLED straight off process.env and never
# parses .env, so the LaunchAgent plist is the only channel and this helper
# allowlist is the only thing that carries it through Install / Repair / Update
# Server. Allowlist membership and the delete-on-off write shape are both
# EXECUTED in the helper self-test; these pin the surfaces around them.
/usr/bin/grep -q 'case "set-thread-attach"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'COS_THREAD_ATTACH_ENABLED' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'requireThreadAttach' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'threadAttachEnvironment' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'Continue agent threads' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'setThreadAttachEnabled' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'threadAttachSupported' "$ROOT/Sources/Models.swift"
# The toggle must mount under the support flag the helper actually publishes. A
# control gated on an unrelated flag compiles, reads correctly, and never appears.
/usr/bin/grep -q 'if model.status.threadAttachSupported {' "$ROOT/Sources/Views.swift"
# DEFAULT-ON flag since server 6.37 (`!== '0'`): Off must WRITE "0". The old
# delete-on-Off left the key absent, which a 6.37+ server reads as ENABLED —
# the toggle silently re-enabled the feature for anyone who opted out, and the
# post-restart proof then threw mid-transaction. This guard used to enforce
# that inverted behavior; it now enforces the write, and the self-test
# EXECUTES threadAttachEnvironment("off") to prove it.
/usr/bin/python3 - "$ROOT" <<'PY'
import sys, pathlib
text = pathlib.Path(sys.argv[1], "HelperSources/main.swift").read_text()
start = text.index("private func threadAttachEnvironment")
end = text.index("private func requireThreadAttach")
body = text[start:end]
if '"COS_THREAD_ATTACH_ENABLED": "0"' not in body:
    sys.exit('Continue off must write an explicit "0" — deleting the key re-enables the feature on a 6.37+ server')
if '["COS_THREAD_ATTACH_ENABLED"]' in body:
    sys.exit("Continue off must not use the removingKeys delete path any more")
PY
/usr/bin/grep -q 'struct SpeakerReviewPane' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'activityLauncher' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'ActivitySection.allCases' "$ROOT/Sources/Views.swift"
/usr/bin/python3 - "$ROOT/Sources/Views.swift" <<'PY'
import sys
views = open(sys.argv[1]).read()
panel = views[views.index("private var mainPanel"): views.index("private var activityLauncher")]
# Activity is the first destination in the menu bar, above Restart/Stop/Update.
for name in ("header", "updateBanner", "activityLauncher", "statusCard", "controls"):
    if name not in panel:
        raise SystemExit(f"mainPanel lost {name}")
if panel.index("activityLauncher") > panel.index("statusCard"):
    raise SystemExit("Activity is below status again")
if panel.index("activityLauncher") > panel.index("controls"):
    raise SystemExit("Activity is below Restart/Stop/Update Server again")
if "openActivity(item)" not in views:
    raise SystemExit("chips do not call openActivity(item)")
if "func activityChip(_ item: ActivitySection)" not in views:
    raise SystemExit("chips are display-only again")
print("Activity sits above controls; chips open their tab")
PY
/usr/bin/grep -q 'Open Messages, Speakers, Meetings' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'ActivityWindowPresenter' "$ROOT/Sources/COSControlApp.swift"
/usr/bin/grep -q 'activityWindow.show(model: model, section: section)' "$ROOT/Sources/COSControlApp.swift"
/usr/bin/grep -q 'SessionPetPresenter' "$ROOT/Sources/COSControlApp.swift"
/usr/bin/grep -q 'Session pet' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'Choose sprite' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'Open in platform' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'func openSessionInPlatform' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'jumpFromReveal' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'try await NSWorkspace.shared.open' "$ROOT/Sources/ControllerModel.swift"
! /usr/bin/grep -q 'func applySessionReveal' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'func choosePetSprite' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'enum PetSpriteStore' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'case "session-pet-live"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'emitClaudeSessions(liveOnly: true)' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "session-reveal"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'if model.petExpanded { model.petExpanded = false }' "$ROOT/Sources/SessionPet.swift"
/usr/bin/grep -q 'activityOpenSessionID' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'object(forKey: ControllerModel.petEnabledKey) as? Bool ?? true' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'window.isReleasedWhenClosed = false' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'window.setFrameAutosaveName("COSActivityWindow")' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'struct ActivityWindow' "$ROOT/Sources/ActivityWindow.swift"
# A merge must be a two-step: no --confirm means the helper asks the server for a
# dryRun preview, never a merge. Losing this makes the confirmation decorative.
/usr/bin/grep -q 'if confirm { payload\["confirm"\] = true } else { payload\["dryRun"\] = true }' "$ROOT/HelperSources/main.swift"
# The owner profile is checked first on every live chunk; absorbing it away would
# silently break identification for the wearer.
#
# This pinned the whole expression `reliability != .unattributed && !isOwner`
# until 0.5.2, which made it a test of the DEFECT: the `!= .unattributed` half
# blocked naming an unidentified voice while the row's own copy told the user to
# do exactly that, so fixing the bug failed the suite. Only `!isOwner` was ever
# the contract the comment describes. The behaviour now has real execution
# coverage in ModelsContract.swift; this line just keeps the owner guard present.
/usr/bin/grep -q '!isOwner' "$ROOT/Sources/Models.swift"
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

# Meeting-level coverage decodes with NO `?? 0`. A count has no safe scalar
# default: an older server omits the field entirely, and defaulting to zero
# would report "0 of 379 segments named" on a well-attributed meeting — the same
# confident-false-statement class as the 404-means-audio-expired guard above.
# nil means unknown and the header omits the line, so pin decode AND render.
/usr/bin/grep -q 'assertedSegments = o\["assertedSegments"\]?.int$' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'let asserted = review.assertedSegments' "$ROOT/Sources/Views.swift"

# The meeting write-up and its two clipboard forms. Both strings are built
# SERVER-SIDE with the display floor applied to the attendee block — the scribe's
# own `## Attendees` applies none and lists names already confirmed absent. Pin
# that Control passes them through and never re-derives them here.
/usr/bin/grep -q 'case "meeting-content"' "$ROOT/HelperSources/main.swift"
# Pass-through is asserted by EXECUTION in ModelsContract (checkMeetingContent),
# not by grepping for an assignment's exact spelling — that grep broke on a
# refactor that changed nothing about the behaviour, which is how a shape test
# trains you to edit the test instead of the code.
/usr/bin/grep -q 'model.copyMeeting(full: true)' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'model.copyMeeting(full: false)' "$ROOT/Sources/Views.swift"

# WIRING, not existence. /qa mutation-tested the previous four guards and found
# two feature-killing mutations that kept the suite GREEN: no-op'ing the content
# fetch (write-up and both buttons dead forever) and making Full copy the summary.
# Source-shape greps cannot see behaviour, so pin the two exact call expressions.
# ANCHORED to line start: an unanchored grep matched the string inside a
# commented-out line, so a mutation that disabled the whole feature stayed green.
/usr/bin/grep -qE '^[[:space:]]*await loadMeetingContent\(sessionId: sessionId\)' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'full ? c.clipboardFull : c.clipboardSummary' "$ROOT/Sources/ControllerModel.swift"
# A 404 is "server too old", not a silent failure. The MESSAGE logic is covered by
# execution in ModelsContract; this pins that the reason is actually assigned.
/usr/bin/grep -qE '^[[:space:]]*contentUnavailable = reason$' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'MeetingContent.unavailableMessage(reason)' "$ROOT/Sources/Views.swift"
# The clipboard must never quote a size the confirmation disagrees with.
/usr/bin/grep -q 'content.fullChars / 1024' "$ROOT/Sources/Views.swift"

# Talk time decodes with no `?? 0` (same no-safe-default rule as coverage), and
# is rendered ONLY behind nameAsserted — showing minutes for a voice the panel
# refuses to name would assert an identity by the back door.
/usr/bin/grep -q 'speakingMs = o\["speakingMs"\]?.int$' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'voice.nameAsserted, let ms = voice.speakingMs' "$ROOT/Sources/Views.swift"

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
# The ribbon must not render at all without spans. An older server returns none,
# and the unguarded version drew a blank strip plus "Hover the bar to see who is
# speaking" for a bar that was not there.
/usr/bin/grep -q 'if !review.timeline.isEmpty {' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'needs glasses-server 6.21.18 or newer' "$ROOT/Sources/Views.swift"

# The playback note is keyed to ONE row: a shared string printed the same failure
# under all eleven voices at once.
/usr/bin/grep -q 'note.voice == voice.label' "$ROOT/Sources/Views.swift"
# Closing the panel stops audio and resets scope. Audio kept playing after close,
# and a sticky "Every meeting" is the irreversible global fold this release removes.
/usr/bin/grep -A12 'func closeSpeakerReview' "$ROOT/Sources/ControllerModel.swift" | /usr/bin/grep -q 'stopPlayback()'
# COUNTED rather than pinned to a line offset: scope must be reset on open, on
# close, on cancel and after a successful save. A `grep -A8` guard broke the
# moment a comment moved the line, which is the wrong thing to be sensitive to.
[ "$(/usr/bin/grep -c 'correctionScope = .thisMeeting' "$ROOT/Sources/ControllerModel.swift")" -ge 4 ]

# The this-meeting scope must say it enrols a voice profile. Until 0.5.57 the
# copy claimed the path was unbuilt while server 6.27.12+ already enrolled Ext,
# and 6.36.17 enrols a new name from a wrong existing label (Nick → Milo).
if /usr/bin/grep -q 'enrolment path is not built' "$ROOT/Sources/Models.swift"; then
  echo "COS Control: scope copy still claims enrolment is unbuilt" >&2
  exit 1
fi
if ! /usr/bin/grep -q 'adds samples to the voice profile' "$ROOT/Sources/Models.swift"; then
  echo "COS Control: this-meeting scope copy does not mention the voice profile" >&2
  exit 1
fi
if ! /usr/bin/grep -q '\["enrolment"\]' "$ROOT/Sources/ControllerModel.swift"; then
  echo "COS Control: confirm path does not read the server enrolment report" >&2
  exit 1
fi

# --- 0.4.1 overlay regression ---------------------------------------------------
# MenuBarExtra(.window) is a transient panel that closes when it loses key status,
# so ANY sheet presented from it dismisses the panel mid-interaction. This is the
# regression guard: zero sheet presentations in the panel's view tree.
if /usr/bin/grep -q '\.sheet(' "$ROOT/Sources/Views.swift" "$ROOT/Sources/ActivityWindow.swift"; then
  echo 'COS Control: FAIL — a .sheet reappeared in Views.swift; MenuBarExtra panels must route overlays inline' >&2
  exit 1
fi
/usr/bin/grep -q 'struct SpeakerReviewPane' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'struct MediaPreviewPane' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'reviewRouteActive' "$ROOT/Sources/ActivityWindow.swift"
# The route reads lastReviewSession, so it must be observable or the panel can
# read a stale value and never re-render.
/usr/bin/grep -q '@Published private var lastReviewSession' "$ROOT/Sources/ControllerModel.swift"

# 0. The durability flag survives a Control plist rewrite. `providerEnvironment` is
#    FILTERED to providerEnvironmentKeys, so a key missing from that set is dropped
#    on the next Update Server -- silently reopening every fenced thread. This is the
#    same seam that stopped COS_PROFILE_PATH from surviving updates.
/usr/bin/python3 - "$ROOT/HelperSources/main.swift" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
block = re.search(r"providerEnvironmentKeys: Set<String> = \[(.*?)\]", src, re.S)
assert block, "providerEnvironmentKeys not found"
assert '"COS_THREAD_FENCE_DURABLE"' in block.group(1), \
    "COS_THREAD_FENCE_DURABLE is not allowlisted -- Control will drop it on the next plist rewrite"
PY

# --- 0.5.46 fork / duplicate-title disambiguation ----------------------------
# The LOGIC is covered by execution in ModelsContract (checkAmbiguousTitles). These
# pin the WIRING, which a SwiftUI view cannot express in a unit test: the shared row
# must actually consult the helper and render the opened date. Without both, the
# helper is correct and invisible — the 0.5.17 shape.
/usr/bin/grep -q 'static func ambiguousTitles(in sessions: \[ClaudeSession\]) -> Set<String>' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'ClaudeSession.ambiguousTitles(' "$ROOT/Sources/ActivityWindow.swift"
# The row must consume it AND render createdDate — the one field that differs between
# a fork and its parent.
/usr/bin/python3 - "$ROOT/Sources/ActivityWindow.swift" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
start = src.index("private func sessionRow(")
end = src.index("\n    private ", start + 10)
row = src[start:end]
assert "ambiguousSessionTitles.contains(" in row, \
    "sessionRow does not consult ambiguousSessionTitles -- forks stay indistinguishable"
assert "session.createdDate" in row, \
    "sessionRow does not render createdDate -- nothing on the row differs between a fork and its parent"
PY
# The ambiguity set must union BOTH surfaces; the row is shared by the list and search.
/usr/bin/grep -q 'visibleSessions + model.visibleSessionSearchHits' "$ROOT/Sources/ActivityWindow.swift"

# --- 0.5.50 the gateway paints itself in -------------------------------------
# The accent bar was a 3pt pill overlaid on a 16pt-radius card: a CSS border-left moved
# into SwiftUI without reconciling the geometry. It is gone, and the plate that replaced
# it is a CHILD clipped by the tile, so the mismatch is impossible rather than avoided.
/usr/bin/python3 - "$ROOT/Sources/ActivityWindow.swift" "$ROOT/Sources/COSMotion.swift" <<'PY'
import re, sys
win = open(sys.argv[1]).read()
mot = open(sys.argv[2]).read()

card = win[win.index("private func activityHomeCard"):]
card = card[:card.index("\n    /// The count and what it counts")]

# 1. No overlaid edge, in any form.
assert ".overlay(alignment: .leading)" not in card, "the leading accent bar is back"
assert "item.tint" not in card, "the gateway must use one accent, not six hues"
assert "clipShape(RoundedRectangle" in card, "the plate must be clipped to the card radius"

# 2. The draw is real: trim is what makes sketch-then-ink possible at all.
# Not just "a trim exists" — the trim must be DRIVEN by the paint state, or the glyph
# renders complete and the draw never happens. A weaker assertion passed this mutation.
assert re.search(r"trim\(from: 0, to: [^\n]*painted", card), \
    "the glyph trim must be bound to `painted`, not a constant"
assert "wipeIn(painted" in card, "headings take the wipe half of the paint-in"

# 3. Stagger applies on the way IN only. A staggered exit reads as lag, not polish.
assert "delay(hot ? 0.04 : 0)" in card, "hover delay must collapse to 0 on exit"

# 4. Reduced motion lands the finished frame — a pre-state that hides content must never
#    survive with animation disabled.
assert "(reduceMotion || painted) ? 1 : 0" in card, "reduce-motion must not strand the tile hidden"
assert "(reduceMotion || shown)" in mot, "reduce-motion must not strand a heading clipped to zero"

# 5. One travelling indicator, not six that toggle.
rail = win[win.index("private var lensRail"):]
rail = rail[:rail.index("\n    private var ")]
assert 'matchedGeometryEffect(id: "railIndicator"' in rail, "the rail indicator must travel"
assert "section == item ? item.tint : Color.clear" not in rail, "per-tab tinted underline is back"

# 6. The open panes speak the same vocabulary as the gateway.
glyph = win[win.index("private func sectionGlyph"):]
glyph = glyph[:glyph.index("\n    private func directoryNotice")]
assert "SectionGlyph(section: item)" in glyph, "panes must use the same mark as the gateway"
assert "Image(systemName: item.icon)" not in glyph, "the tinted pane chip is back"
assert "large ? 42 : 32" in glyph, "pane glyph frame must stay 32/42pt — 8 call sites lay out around it"

# 7. Two things that actually shipped broken in 0.5.53 and were visible on first launch.
#    COSPalette.ink is a FIXED dark: correct on the brand tile, black-on-black on the
#    espresso panel. The header lockup must take an adaptive style.
header = win[win.index("private var activityHome"):]
header = header[:header.index("\n    /// One gateway tile")]
# Comments are stripped first: the fix's own explanation names COSPalette.ink, and an
# assertion that reads prose about the code instead of the code always "finds" it.
header_code = "\n".join(l for l in header.split("\n") if not l.strip().startswith("//"))
assert "COSLockupView(height: 17)" in header_code, "header lockup missing"
assert "COSPalette.ink" not in header_code, "the header lockup is fixed-dark again — invisible in dark mode"

#    And the counts must come from the model, not from scraping homeStat's prose. Scraping
#    turned "50 of 5528" into 50 / OF 5528: the smaller number promoted, the label a fragment.
metric = win[win.index("private func homeMetric"):]
metric = metric[:metric.index("\n    private func homeStat")]
assert "status.memoryCount" in metric and "status.threadCount" in metric, \
    "counts must read structured fields, not parse a sentence"
assert "prefix(while:" not in metric and "drop(while:" not in metric, \
    "the count is being scraped out of prose again"

# 8. Every lockup must be adaptive. COSPalette.ink is a fixed dark and renders black on the
#    espresso panel; three instances exist and fixing only the obvious one shipped twice.
import glob, os
root = os.path.dirname(os.path.dirname(sys.argv[1]))
for f in glob.glob(os.path.join(root, "Sources", "*.swift")):
    src = open(f).read()
    code = "\n".join(l for l in src.split("\n") if not l.strip().startswith("//"))
    for i, line in enumerate(code.split("\n")):
        if "COSLockupView(" in line and "struct" not in line:
            near = "\n".join(code.split("\n")[i:i+4])
            assert "COSPalette.ink" not in near, \
                f"fixed-dark lockup in {os.path.basename(f)} — invisible in dark mode"
PY

# The new source must be in BOTH build lists or it ships as a compile error, not a feature.
/usr/bin/grep -q 'Sources/COSMotion.swift' "$ROOT/scripts/build-release.sh"

# --- 0.5.49 the sessions list has ONE source ---------------------------------
# Control rebuilt the list locally and that copy compared pins against an 8-character
# id when they are stored as full UUIDs, and walked only ~/.claude/projects so a
# Desktop-store session produced no row. 7 starred Claude sessions, 0 shown.
/usr/bin/python3 - "$ROOT/HelperSources/main.swift" <<'PY'
import re, sys
helper = open(sys.argv[1]).read()

fn = helper[helper.index("private func emitClaudeSessions"):]
fn = fn[:fn.index("\n    private func ", 10)]

assert '"/api/agent-sessions?limit=80"' in fn, \
    "the list must come from the server, not a second local scanner"

# The local scan is the FALLBACK. If it runs unconditionally the divergent copy is back.
assert "if serverRows.isEmpty {" in fn, "local scan must be gated on the server failing"
assert fn.index("serverRows = raw.compactMap") < fn.index("recentClaudeConversations"), \
    "the server must be consulted BEFORE the local scan"
assert fn.count("recentClaudeConversations") == 1, "local scan must appear once, in the fallback"

proj = helper[helper.index("static func agentSessionRowProjection"):]
proj = proj[:proj.index("\n    /// Live status")]
for src, dst in (("session_id", '"id"'), ("display_label", '"name"'), ("project", '"workspace"')):
    assert src in proj, f"projection drops {src}"
# `project` already arrives labelled; re-labelling it mangles the workspace column.
assert "workspaceLabel(row[\"project\"]" not in proj, "project must not be re-labelled"

ov = helper[helper.index("static func overlayLiveState"):]
ov = ov[:ov.index("\n    static func claudePeerProjection")]
assert "hasPrefix(peerId)" in ov, \
    "live ids are the 8-char short form -- equality alone silently matches nothing"
assert "waitingFor" in ov, "waitingFor exists only on the live route and must be overlaid"
PY

# --- 0.5.50 Today is gone; LIST caps are counted -----------------------------
# `recent` meant "not running" and Control printed "Today" for it, so an 82-day-old
# row looked fresh. The 36-hour hint suppression hid the real timestamp on the
# default clock. Caps (7-day / 20-per-provider / 32 MB) dropped rows with no
# signal. dropped is a SIBLING of the session array, never a 13th row key.
/usr/bin/grep -q 'case "recent": ""' "$ROOT/Sources/Models.swift"
! /usr/bin/grep -q 'case "recent": "Today"' "$ROOT/Sources/Models.swift"
! /usr/bin/grep -q '36 \* 3600' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'func clockHint(clock: SessionClock' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'session.clockHint(clock: model.sessionClock)' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'session.showsStateChip' "$ROOT/Sources/ActivityWindow.swift"
/usr/bin/grep -q 'struct SessionListDropped' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'sessionListDropped' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'static func agentSessionDroppedProjection' "$ROOT/HelperSources/main.swift"
/usr/bin/python3 - "$ROOT/HelperSources/main.swift" "$ROOT/Sources/ActivityWindow.swift" <<'PY'
import sys
helper = open(sys.argv[1]).read()
ui = open(sys.argv[2]).read()

proj = helper[helper.index("static func agentSessionRowProjection"):]
proj = proj[:proj.index("static func agentSessionDroppedProjection")]
ret = proj[proj.index("return ["): proj.rindex("]") + 1]
assert '"pinned"' in ret
assert "dropped" not in ret, "dropped leaked into the 12-key row projection"

drop = helper[helper.index("static func agentSessionDroppedProjection"):]
drop = drop[:drop.index("\n    /// Live status")]
for key in ('"age"', '"limit"', '"oversized"'):
    assert key in drop, f"dropped projection missing {key}"

fn = helper[helper.index("private func emitClaudeSessions"):]
fn = fn[:fn.index("\n    private func ", 10)]
assert "agentSessionDroppedProjection(body)" in fn
assert '"dropped": dropped' in fn

assert "sessionListDropped.summary" in ui
assert "Last 7 days" in ui
PY

# --- 0.5.48 the search must not discard the server's answer on timing ---------
# The route measured 1.44-2.40s against the running server and the client allowed 2s,
# so the slowest of six consecutive calls already fell back to the local scanner -- and
# reported "server_too_old" while doing it, which is a diagnosis the client had no basis
# for. Four distinct failures shared that one label.
/usr/bin/python3 - "$ROOT/HelperSources/main.swift" "$ROOT/Sources/ActivityWindow.swift" <<'PY'
import re, sys
helper = open(sys.argv[1]).read()
ui = open(sys.argv[2]).read()

fn = helper[helper.index("private func emitClaudeSessionsSearch"):]
fn = fn[:fn.index("\n    private func ", 10)]

assert "timeout: 2)" not in fn, "the 2s search timeout is back -- it is inside the route's own variance"
m = re.search(r"request\(path, token: token, timeout: (\d+)\)", fn)
assert m and int(m.group(1)) >= 10, f"search timeout must leave real headroom, got {m and m.group(1)}"

assert '"semanticReason": fallbackReason' in fn, \
    "the fallback must report why it fired, not a hardcoded server_too_old"
for reason in ('"server_unreachable"', '"no_server_token"', 'server_error_'):
    assert reason in fn, f"missing fallback reason {reason}"
assert 'response.status == 404 ? "server_too_old"' in fn, \
    "only a 404 means the route is actually missing"

hint = ui[ui.index("private var sessionSemanticHint"):]
hint = hint[:hint.index("\n    @ViewBuilder")]
for reason in ("server_unreachable", "no_server_token", "server_error_"):
    assert reason in hint, f"the hint does not distinguish {reason}"
PY

# --- 0.5.47 the release must not race its own dialog --------------------------
# Dismissing the confirmation nils `fencePendingRelease`, and the Release button
# defers into a Task. Reading the record inside that task races the dismissal and
# can return silently -- a button that does nothing, which is the 0.5.17 shape and
# is invisible to every source grep. The record is therefore a PARAMETER, captured
# synchronously in the closure.
/usr/bin/python3 - "$ROOT/Sources/ControllerModel.swift" "$ROOT/Sources/Views.swift" <<'PY'
import re, sys
model = open(sys.argv[1]).read()
views = open(sys.argv[2]).read()

assert re.search(r"func releaseFence\(_ record: FenceRecord, confirm: Bool\) async", model), \
    "releaseFence must take the record as a parameter, not read fencePendingRelease"

body = model[model.index("func releaseFence(_ record"):]
body = body[:body.index("\n    func ", 10)]
assert "guard let record = fencePendingRelease" not in body, \
    "releaseFence re-reads fencePendingRelease -- it races the dialog dismissal"

# 0.5.63 RETARGETED. The previous form matched a `Button("Release", role: .destructive)`
# inside a confirmationDialog and asserted the capture preceded the Task. It PASSED
# for months against a button whose action never ran at all -- the text was in the
# right order and the closure was unreachable. Assert the invariant, not the layout.
#
# `cosConfirm` dismisses BEFORE it runs the action, and dismissal nils
# `fencePendingRelease`, so the action must close over a value captured while the
# confirmation was still on screen and must never read the model itself.
actions = views[views.index("private var fenceConfirmActions"):]
actions = actions[:actions.index("\n    }\n") + 6]

assert "let pending = model.fencePendingRelease" in actions, \
    "fenceConfirmActions must capture the record into a local"
assert actions.index("let pending = model.fencePendingRelease") < actions.index(".destructive("), \
    "the capture must happen BEFORE the action is built"

destructive = actions[actions.index(".destructive("):]
destructive = destructive[:destructive.index(".cancel")]
assert "model.fencePendingRelease" not in destructive, \
    "the Release action reads model.fencePendingRelease -- dismissal has already nil'd it"
assert "guard let pending" in destructive and "releaseFence(pending" in destructive, \
    "the Release action must use the captured record"
PY

# --- 0.5.44 fenced threads ---------------------------------------------------
# A fence shuts a native thread that may already hold an undelivered turn. Before
# glasses-server 6.36.10 the only way to clear one was restarting the server. These
# assertions exist because 0.5.17 shipped two buttons that did nothing: the opener
# wrote state no view was watching. Each link in the chain is pinned separately, so
# a break names itself instead of silently going inert.

# 1. The helper actually has the two commands the model calls.
/usr/bin/grep -q 'case "fences": try emitFences()' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "fence-release": try emitFenceRelease(args: args)' "$ROOT/HelperSources/main.swift"

# 2. The release is CONFIRM-GATED at the helper: --confirm is the only thing that
#    puts `confirm` on the wire, so a release can never be one accidental call.
/usr/bin/grep -q 'if args.contains("--confirm") { payload\["confirm"\] = true }' "$ROOT/HelperSources/main.swift"

# 3. The helper must NOT throw on the server's 400 confirmation gate — that 400
#    carries the preview. Throwing it is how the merge flow shipped broken in 0.4.0.
#    Scoped to emitFenceRelease: `let gated = response.status == 400` appears in
#    three helpers, so a bare grep passes even after this one is neutered (measured).
/usr/bin/python3 - "$ROOT/HelperSources/main.swift" <<'PY'
import sys
src = open(sys.argv[1]).read()
start = src.index("private func emitFenceRelease")
end = src.index("\n    private func ", start + 10)
body = src[start:end]
assert "let gated = response.status == 400" in body, \
    "emitFenceRelease no longer treats the server's 400 as the confirmation gate"
assert "response.status != 200 && !gated" in body, \
    "emitFenceRelease would throw on the gate instead of returning the preview"
PY

# 4. The model calls the helper, and only the confirmed path appends --confirm.
/usr/bin/grep -q 'helper.run(\["fences"\])' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'if confirm { args.append("--confirm") }' "$ROOT/Sources/ControllerModel.swift"

# 5. THE 0.5.17 LINK. The card is mounted, its rows call the opener, and the dialog
#    is bound to the variable the opener writes. Without all three the feature is
#    reachable-looking and dead.
/usr/bin/grep -q 'if !model.fenceRecords.isEmpty { fencesCard }' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'private var fencesCard: some View' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'model.askReleaseFence(fence)' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'get: { model.fencePendingRelease != nil }' "$ROOT/Sources/Views.swift"

# 6. Something must LOAD the fences on APPEAR, or a card gated on a non-empty list
#    can never show up. Pinned to the onAppear site by its own comment, not to the
#    bare call: the card's Refresh button contains the identical expression, so a
#    plain grep for it passes even after the automatic load is deleted (measured --
#    that exact mutation survived the first version of this assertion).
/usr/bin/python3 - "$ROOT/Sources/Views.swift" <<'PY'
import sys
lines = open(sys.argv[1]).read().split("\n")
# Walk the FIRST `.onAppear {` (the panel's own) to its closing brace at the same
# indent, line by line -- a regex with a character cap silently matched the wrong
# block when this was first written.
start = next(i for i, l in enumerate(lines) if l.strip() == ".onAppear {")
indent = len(lines[start]) - len(lines[start].lstrip())
end = next(i for i in range(start + 1, len(lines))
           if lines[i].strip() == "}" and len(lines[i]) - len(lines[i].lstrip()) == indent)
block = "\n".join(lines[start:end])
assert "await model.loadFences()" in block, \
    "fences are never loaded when the panel appears -- the card can never render"
PY

# 7. The degraded flag reaches the user. A memory-only fence set behaves exactly
#    like a durable one until the server restarts, so silence would be a lie.
/usr/bin/grep -q 'model.fenceDegraded' "$ROOT/Sources/Views.swift"

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

# --- 0.5.51 click-to-update: SHA, swap, never touch the glasses server --------
/usr/bin/grep -q 'case "stage-app-update"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "apply-app-update"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "complete-app-update"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'Button("Install")' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'func installAppUpdate' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'preferStable: true' "$ROOT/Sources/ControllerModel.swift"
/usr/bin/grep -q 'completeAppUpdateIfNeeded' "$ROOT/Sources/ControllerModel.swift"
# Apply must not drive the glasses-server lifecycle. Drain, launchctl on that
# label, and ~/.cos-glasses writes are the R1/R9 forbid-list.
/usr/bin/python3 - "$ROOT/HelperSources/main.swift" <<'PY'
import sys
src = open(sys.argv[1]).read()
start = src.index("private func emitStageAppUpdate")
end = src.index("/// Read-only Memory and Threads browsing on the desktop.")
block = src[start:end]
for needle, label in [
    ("withMutationLock", "lifecycle lock"),
    ("launchctl", "launchctl"),
    ("com.cos.glasses-server", "glasses-server label"),
    ("/api/maintenance/", "maintenance drain"),
    ("configDir", "cos-glasses configDir"),
]:
    if needle in block:
        raise SystemExit(f"app-update path touches {label} via {needle}")
if "sha256(zipURL)" not in block:
    raise SystemExit("stage does not SHA-256 the downloaded zip")
if "replaceItemAt" not in block:
    raise SystemExit("swap does not atomically replace the live bundle")
if 'COS_CONTROL_TEST_HOME"] == nil' not in block:
    raise SystemExit("swap must not /usr/bin/open during isolated tests")
print("app-update forbid-list and SHA/swap wiring passed")
PY

make_dummy_app () {  # <dir> <version> <build>
  local app="$1/COS Control.app"
  /bin/mkdir -p "$app/Contents/MacOS"
  /bin/cp /bin/echo "$app/Contents/MacOS/COS Control"
  /usr/bin/plutil -create xml1 "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.gotcos.control' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleName string COS Control' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string COS Control' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $2" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $3" "$app/Contents/Info.plist"
  /usr/bin/codesign --force --deep --sign - "$app" >/dev/null
  /usr/bin/codesign --verify --deep --strict "$app"
}

AU_HOME="$TMP/app-update-home"
AU_LIVE="$TMP/app-update-live"
AU_NEW="$TMP/app-update-new"
/bin/mkdir -p "$AU_HOME" "$AU_LIVE" "$AU_NEW" "$AC_DIR"
make_dummy_app "$AU_LIVE" "0.5.50" "88"
make_dummy_app "$AU_NEW" "0.5.99" "199"
AU_ZIP="$AC_DIR/COS-Control-macOS-arm64-0.5.99.zip"
/usr/bin/ditto -c -k --norsrc --keepParent "$AU_NEW/COS Control.app" "$AU_ZIP"
AU_SHA="$(/usr/bin/shasum -a 256 "$AU_ZIP" | /usr/bin/awk '{print $1}')"
/bin/cat > "$AC_DIR/apply-good.json" <<JSON
{"schemaVersion":1,"channels":{"stable":{"version":"0.5.99","build":199,"url":"file://$AU_ZIP","sha256":"$AU_SHA","minMacOS":"14.0"}},"killSwitch":{"disableAutoUpdate":false}}
JSON
/bin/cat > "$AC_DIR/apply-bad-sha.json" <<JSON
{"schemaVersion":1,"channels":{"stable":{"version":"0.5.99","build":199,"url":"file://$AU_ZIP","sha256":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","minMacOS":"14.0"}},"killSwitch":{"disableAutoUpdate":false}}
JSON

AU_ENV=(
  COS_CONTROL_TEST_HOME="$AU_HOME"
)
# Wrong SHA must discard the file and leave no pending install.
if COS_CONTROL_TEST_HOME="$AU_HOME" "$TMP/cos-control-helper" stage-app-update \
    --current-version 0.5.50 --current-build 88 \
    --appcast-url "file://$AC_DIR/apply-bad-sha.json" \
    --live-bundle "$AU_LIVE/COS Control.app"; then
  echo "stage-app-update accepted a SHA mismatch" >&2
  exit 1
fi
if [ -f "$AU_HOME/Library/Application Support/COS Control/updates/pending.json" ]; then
  echo "SHA mismatch left a pending update" >&2
  exit 1
fi

GOOD_STAGE="$(COS_CONTROL_TEST_HOME="$AU_HOME" "$TMP/cos-control-helper" stage-app-update \
    --current-version 0.5.50 --current-build 88 \
    --appcast-url "file://$AC_DIR/apply-good.json" \
    --live-bundle "$AU_LIVE/COS Control.app")"
/usr/bin/python3 - "$GOOD_STAGE" <<'PY'
import json,sys
d=json.loads(sys.argv[1])
assert d.get("ok") is True, d
assert d.get("details",{}).get("reason")=="staged", d
PY
test -f "$AU_HOME/Library/Application Support/COS Control/updates/pending.json"

COS_CONTROL_TEST_HOME="$AU_HOME" "$TMP/cos-control-helper" apply-app-update \
    --swap --live-bundle "$AU_LIVE/COS Control.app" >/dev/null
LIVE_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$AU_LIVE/COS Control.app/Contents/Info.plist")"
LIVE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$AU_LIVE/COS Control.app/Contents/Info.plist")"
PREV_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$AU_HOME/Library/Application Support/COS Control/updates/previous/COS Control.app/Contents/Info.plist")"
if [ "$LIVE_VER" != "0.5.99" ] || [ "$LIVE_BUILD" != "199" ]; then
  echo "swap did not install the staged app (live=$LIVE_VER $LIVE_BUILD)" >&2
  exit 1
fi
if [ "$PREV_VER" != "0.5.50" ]; then
  echo "swap did not retain the previous app (previous=$PREV_VER)" >&2
  exit 1
fi
COMPLETE="$(COS_CONTROL_TEST_HOME="$AU_HOME" "$TMP/cos-control-helper" complete-app-update --current-build 199)"
/usr/bin/python3 - "$COMPLETE" <<'PY'
import json,sys
d=json.loads(sys.argv[1])
assert d.get("ok") is True, d
assert d.get("details",{}).get("reason")=="complete", d
PY
if [ -f "$AU_HOME/Library/Application Support/COS Control/updates/pending.json" ]; then
  echo "complete-app-update left pending.json" >&2
  exit 1
fi
echo "click-to-update SHA refuse, stage, swap, and complete passed"

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
  "$ROOT/Sources/COSBrand.swift" \
  "$ROOT/Sources/COSMotion.swift" \
  "$ROOT/Sources/COSConfirm.swift" \
  "$ROOT/Sources/Views.swift" \
  "$ROOT/Sources/ActivityWindow.swift" \
  "$ROOT/Sources/ActivityMeetings.swift" \
  "$ROOT/Sources/SessionPet.swift" \
  "$ROOT/Sources/COSControlApp.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement \
  -o "$TMP/COS Control"

/usr/bin/vtool -show-build "$TMP/cos-control-helper" | /usr/bin/grep -q 'minos 14.0'
/usr/bin/vtool -show-build "$TMP/COS Control" | /usr/bin/grep -q 'minos 14.0'

# --- Every route a click can enter must actually render -----------------------
# The 0.5.17 Review Memories / Review Threads buttons did NOTHING when clicked. The
# opener set `contextBrowseKind`, but the pane was mounted inside
# `if model.reviewRouteActive` — a flag only the speaker flow ever sets — so state
# changed and no view was watching. It compiled, the helper worked, and 110 self-test
# assertions passed, because nothing tied the OPENER to the RENDER CONDITION.
/usr/bin/python3 - "$ROOT" <<'ROUTECHK'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
views = (root / "Sources/Views.swift").read_text()
activity = (root / "Sources/ActivityWindow.swift").read_text()
app = (root / "Sources/COSControlApp.swift").read_text()
model = (root / "Sources/ControllerModel.swift").read_text()

def need(condition, message):
    if not condition:
        sys.exit(f"route wiring: {message}")

# 1. Every *RouteActive flag the model defines is consumed by the view. An
#    unrendered route is a dead click by construction.
flags = re.findall(r"var (\w*RouteActive)\s*:\s*Bool", model)
need(len(flags) >= 2, f"expected the speaker and context routes, found {flags}")
for flag in flags:
    need(f"model.{flag}" in activity, f"{flag} is never read by ActivityWindow.swift")

# 2. The context pane reads its own route flag inside a window-local selection
#    gate. The local id prevents a late response from another tab reopening a
#    detail the user already left; the model flag prevents a false rendered pane.
need("ContextDetailPane(model: model, showsBackButton: false)" in activity, "ContextDetailPane is never mounted")
need('selectedContextID != nil' in activity, "context detail has no window-local selection gate")
need(re.search(r"if model\.contextRouteActive\s*\{\s*ContextDetailPane", activity) is not None,
     "ContextDetailPane is not gated on model.contextRouteActive")
need('selectedSpeakerSessionID != nil' in activity, "speaker detail has no window-local selection gate")
need(re.search(r"if model\.reviewRouteActive\s*\{\s*SpeakerReviewPane", activity) is not None,
     "SpeakerReviewPane is not gated on model.reviewRouteActive")

# 3. The route flag reads the var the opener writes. This is the exact link that was
#    missing: openContextRecord set one thing, the mount condition read another.
route = re.search(r"var contextRouteActive[^}]*\}", model, re.S)
need(route is not None, "contextRouteActive not found")
# Word-boundary, because `contextDetailLoading` CONTAINS `contextDetail`: a mutation
# that reduced the flag to just the loading bool passed a plain substring check.
need(re.search(r"\bcontextDetail\b", route.group(0)) is not None,
     "contextRouteActive does not read contextDetail itself")
opener = re.search(r"func openContextRecord\(.*?\n    \}", model, re.S)
need(opener is not None, "openContextRecord not found")
need(re.search(r"contextDetail\s*=", opener.group(0)) is not None,
     "openContextRecord never assigns contextDetail, so the route can never activate")

need('case .meetings: meetingsList' in activity, "Meetings is not mounted")
need('selectedLibraryRecordID != nil' in activity, "meeting library detail has no window-local selection gate")
need(re.search(r"if model\.libraryRouteActive\s*\{\s*MeetingLibraryDetailPane", activity) is not None,
     "MeetingLibraryDetailPane is not gated on model.libraryRouteActive")
library_route = re.search(r"var libraryRouteActive[^}]*\}", model, re.S)
need(library_route is not None, "libraryRouteActive not found")
need(re.search(r"\bopenLibraryRow\b", library_route.group(0)) is not None,
     "libraryRouteActive does not read openLibraryRow itself")
library_opener = re.search(r"func openLibraryMeeting\(.*?\n    \}", model, re.S)
need(library_opener is not None, "openLibraryMeeting not found")
need(re.search(r"openLibraryRow\s*=", library_opener.group(0)) is not None,
     "openLibraryMeeting never assigns openLibraryRow, so the route can never activate")

need('selectedSessionID != nil' in activity, "session detail has no window-local selection gate")
need(re.search(r"if model\.claudeSessionRouteActive\s*\{\s*ClaudeSessionDetailPane", activity) is not None,
     "ClaudeSessionDetailPane is not gated on model.claudeSessionRouteActive")
session_route = re.search(r"var claudeSessionRouteActive[^}]*\}", model, re.S)
need(session_route is not None, "claudeSessionRouteActive not found")
need(re.search(r"\bopenClaudeRow\b", session_route.group(0)) is not None,
     "claudeSessionRouteActive does not read openClaudeRow itself")
session_opener = re.search(r"func openClaudeSession\(.*?\n    \}", model, re.S)
need(session_opener is not None, "openClaudeSession not found")
need(re.search(r"openClaudeRow\s*=", session_opener.group(0)) is not None,
     "openClaudeSession never assigns openClaudeRow, so the route can never activate")
need('Copy session' in activity, "session detail has no Copy session button")
need('copyClaudeSession' in model, "Copy session is not wired")
need('"--provider", session.provider' in model, "session detail does not pass provider")
need('providerBadge' in activity, "Sessions tab has no provider badge")

# 4. The narrow menu panel has one doorway. Peer sections live in the
#    persistent window, whose shell owns Home, Back, and the breadcrumb.
need('openActivity(nil)' in views, "the menu panel cannot open Activity")
need('openActivity(item)' in views, "Activity chips do not open their own tab")
need('activityWindow.show(model: model, section: section)' in app,
     "the click-only Activity presenter is not wired")
need('func show(model: ControllerModel, section: ActivitySection?' in activity,
     "Activity cannot be opened onto a specific tab")
need('activityOpenSection' in model, "the menu chips have no way to name a tab")
need('applyLaunchSection' in activity, "Activity does not consume the chip's tab")
need('case .messages: messagesList' in activity, "Messages is not mounted")
need('case .speakers: speakersList' in activity, "Speakers is not mounted")
need('case .memories: contextList(kind: "memory")' in activity, "Memories is not mounted")
need('case .threads: contextList(kind: "thread")' in activity, "Threads is not mounted")
need('case .sessions: sessionsList' in activity, "Sessions is not mounted")
need('case sessions' in activity, "Sessions is not an ActivitySection")
need('private func goHome()' in activity and 'private func goBack()' in activity,
     "Activity does not own Home and Back navigation")
need('private var breadcrumb' in activity, "Activity has no breadcrumb")
need('windowWillClose' in activity and 'model?.closeSpeakerReview()' in activity,
     "closing Activity does not stop speaker playback and detail work")
need('selectedVoiceName' in activity and 'voiceDirectoryDetail' in activity,
     "Speakers has no enrolled-voice directory/detail route")
need('observed match' in activity.lower(),
     "voice similarity is not labelled as an occurrence-level observed match")
need('loadVoiceDirectory' in model and 'voiceDirectoryError' in model,
     "voice directory has no explicit loading/error contract")
main_panel = re.search(r"private var mainPanel: some View \{(.*?)\n    \}\n\n", views, re.S)
need(main_panel is not None, "mainPanel not found")
need('recentGlassesCard' not in main_panel.group(1), "Recent Glasses is still nested in the menu panel")
need('reviewableMeetingsCard' not in main_panel.group(1), "Review Speakers is still nested in the menu panel")
need('contextListCard' not in main_panel.group(1), "Memory/Threads are still nested in the menu panel")
need('SessionPetPresenter' in app, "the pet presenter is not constructed at launch")
need('sessionPet.bindIfNeeded' in app, "the pet does not start unless the menu opens")
need('Toggle("Session pet"' in views, "the Session pet toggle is missing")
need('Picker("Pet size"' in views, "Session pet has no size picker")
need('setPetSizePreset' in model, "pet size presets are not wired")
need('setPetCustomPixels' in model, "custom pet pixels are not wired")
need('petSizeKey' in model, "pet size is not persisted")
need('petSizePixelsKey' in model, "custom pet pixels are not persisted")
need('Choose sprite' in views, "Session pet has no Choose sprite control")
need('Install sprite pack' in views, "Session pet has no sprite pack install")
need('State sprites' in views, "Session pet has no per-state sprite controls")
need('choosePetSpritePack' in model, "sprite pack install is not wired")
need('installPetSpritePack' in model, "sprite pack install has no install path")
need('enum PetSpritePose' in (root / "Sources/Models.swift").read_text(),
     "per-state pet sprites are not modeled")
need('sessionCount >= 4' in (root / "Sources/Models.swift").read_text(),
     "four or more live sessions must play the swarm pose")
need('return .duel' in (root / "Sources/Models.swift").read_text(),
     "two live sessions must play the duel pose")
need('return .trio' in (root / "Sources/Models.swift").read_text(),
     "three live sessions must play the three-droid pose")
need('sliceGrid' in (root / "Sources/Models.swift").read_text(),
     "V2 state boards cannot be sliced as a grid")
need('installGrid' in (root / "Sources/Models.swift").read_text(),
     "V2 state boards have no install path")
need('frames: [NSImage]' in (root / "Sources/COSMotion.swift").read_text(),
     "the pet sprite cannot play a pose strip")
need('Open in platform' in activity, "session detail has no Open in platform button")
need('openSessionInPlatform' in model, "Open in platform is not wired")
need('choosePetSprite' in model, "Choose sprite is not wired")
need('installPetSprite' in model, "dropped sprites have no install path")
need('customImage' in (root / "Sources/COSMotion.swift").read_text(), "the pet sprite cannot render a custom PNG")
need('drawUpright' not in (root / "Sources/Models.swift").read_text(),
     "the spurious Quartz flip is back; buffer round trips are orientation-true (see checkPetSpritePipeline)")
need('forceCount: true' in (root / "Sources/Models.swift").read_text(),
     "cell boards no longer force the manifest scene count in the island split")
need('sliceStripByValleys' in (root / "Sources/Models.swift").read_text(),
     "strips no longer valley-align their declared frame cuts")
need('cinematicFrameCount(in: directory)' in model,
     "cinematic playback regressed to the aspect guess that bled half-droids across frame edges")
models_src = (root / "Sources/Models.swift").read_text()
need(models_src.count('suppressTruncatedEdgeSlivers(') >= 3,
     "edge-sliver suppression is not wired into BOTH the strip and board install paths")
need(models_src.count('dropSubjectlessFrames(') >= 2,
     "story strips no longer drop the scenes their subject is absent from (definition alone is not a call site)")
need('enum PetCharacterScale' in models_src,
     "the character dial is gone; pet size would grow the card and the figure together")
pet_src = (root / "Sources/SessionPet.swift").read_text()
need(pet_src.count('scale: model.petCharacterFactor') >= 2,
     "the character dial must size BOTH the panel envelope and the sprite frame")
need('characterScale: model.petCharacterFactor' in pet_src,
     "the sprite view never receives the character dial")
need('Character size' in views, "Settings has no character-size control")
need('retireCinematic: false' in model,
     "a pack install retires its own board's cinematic strip mid-install")
need('schedulePetNoticeExpiry' in model,
     "a pet notice never expires, pinning the pet in the attention pose")
need(model.count('cursorTextFocusReady') >= 2 and 'guard await cursorTextFocusReady(app)' in model,
     "the search fallback types without proving a text field has focus (definition alone is not a guard)")
need('agentsWindowExists' in model,
     "the New Agent fallback keys off activate() again and fires on an open window")
motion_src = (root / "Sources/COSMotion.swift").read_text()
need('func renderSize(' in models_src,
     "the shared sprite-size function is gone")
need(motion_src.count('pose.renderSize(') >= 2 and pet_src.count('renderSize(') >= 2,
     "panel width and rendered sprite width are two formulas again")
need('spriteWidth(' not in motion_src and 'spriteWidth(' not in pet_src,
     "a view sizes off the fixed-aspect spriteWidth instead of the measured art")
need('model.petSpriteFrameCount(pose) > 1' not in views,
     "the frame-count stepper is hidden by the value it exists to raise")
need('COSPalette.plateInk' in (root / "Sources/SessionPet.swift").read_text(),
     "pet controls regressed to fixed ink: black-on-black in dark mode")
need('foregroundStyle(COSPalette.ink)' not in (root / "Sources/SessionPet.swift").read_text(),
     "a pet control paints fixed ink on the adaptive card: black-on-black in dark mode")
need('arrow.up.forward.app' in (root / "Sources/SessionPet.swift").read_text(), "the pet has no Open in platform control")
need('petButton("scope"' in (root / "Sources/SessionPet.swift").read_text(), "Activity jump must be a target, not a waveform")
need('Open in Activity' in (root / "Sources/SessionPet.swift").read_text(), "the target control must name Activity")
need('Open Agents Window' in (root / "Sources/SessionPet.swift").read_text(), "the Cursor target must name the Agents Window")
need('openTarget' in (root / "Sources/SessionPet.swift").read_text(), "the target control has no Cursor/Activity split")
need('petTargetOpensAgentWindow' in (root / "Sources/Models.swift").read_text(),
     "Cursor target routing is not on the session model")
need('petButton("waveform"' not in (root / "Sources/SessionPet.swift").read_text(), "waveform on the pet collides with Codex playback")
need('jumpFromReveal' in model, "platform jump is not isolated from the Launch Services queue")
need('try await NSWorkspace.shared.open' in model, "NSWorkspace completion handlers crash Control on the LS queue")
need('applySessionReveal' not in model, "the MainActor LS completion path must stay gone")
need('openMode == "chat"' in model, "Cursor reveal must branch off the IDE folder open")
need('openMode == "thread"' in model, "Codex reveal must branch off the workspace folder open")
need('openMode == "session"' in model, "Claude reveal must branch off the workspace folder open")
need('revealCodexThread' in model, "Codex jump does not open the thread deep link")
need('revealClaudeSession' in model, "Claude jump does not press the Desktop sidebar")
need('sessionName: session.name' in model,
     "Claude row match must use the session name, not the workspace fallback title")
need('codexThreadID' in model, "Codex deep link is not checked before opening")
need('lowercased() != "new"' in model, "a Codex pet click must not start a blank chat")
codex_jump = model.split("func revealCodexThread")[1].split("func revealClaudeSession")[0]
need('open([folder]' not in codex_jump, "Codex thread jump still opens the workspace folder")
claude_jump = model.split("func revealClaudeSession")[1].split("func revealCursorAgentsWindow")[0]
need('open([folder]' not in claude_jump, "Claude session jump still opens the workspace folder")
need('AXManualAccessibility' in claude_jump, "Claude sidebar is hidden until Chromium AX is on")
need('pressClaudeSessionRow' in claude_jump, "Claude jump does not press the sidebar row")
need('pressClaudeCodeTab' in claude_jump, "Claude jump does not switch to the Code tab")
need('AXPopUpButton' in claude_jump, "Claude jump must not press the row overflow menu")
need('AXWindow' in claude_jump, "Claude row press does not skip AXWindow")
need('AXMenuBar' in claude_jump, "Claude row press does not skip AXMenuBar")
need('AXTextField' in claude_jump, "Claude row press does not skip text fields")
need('activateAllWindows' not in claude_jump,
     "raising Claude must not activate every window as a substitute for the row")
need('code/new' not in claude_jump, "a Claude pet click must not start a blank Code session")
need('codex://threads/' in (root / "HelperSources/main.swift").read_text(),
     "Codex thread deep link is not named")
need('sessionRevealDeepLink' in (root / "HelperSources/main.swift").read_text(),
     "Codex thread deep link is not built")
need('["--glass", "--new-window"]' in model, "cold-start still launches cursor --glass --new-window")
need('proc.arguments = ["--glass"]' not in model, "Cursor --glass alone focuses the IDE")
need('["--chat"]' not in model, "Cursor --chat is unused and raises the IDE")
need('revealCursorAgentsWindow' in model, "Cursor jump does not raise the Agents Window")
need('localizedCaseInsensitiveContains("Cursor Agents")' in model,
     "Cursor Agents window title is not matched")
need('localizedCaseInsensitiveContains("Agents Window")' in model,
     "Agents Window title is not matched")
need('["New Agent", "Cursor Agents"]' in model,
     "the closed-Agents-window fallback does not press the menu items current Cursor actually has")
need('Switch to Agents Window' not in model,
     "stale Cursor menu names are back; current Cursor has no such items (menu bar probed 2026-08-27)")
need('searchAndPressCursorAgentTab' in model,
     "a virtualized (scrolled-away) Agents row has no search fallback")
need('cursorFrontmostVerified' in model,
     "the raise is not verified against the frontmost app before the notice claims Opened")
need('Could not bring the Agents window forward' in model,
     "a failed raise has no honest notice")
need('AXIsProcessTrusted()' in model, "Cursor miss notice does not record Accessibility trust")
need('Toggle it off and on' in model,
     "an untrusted AX jump does not say to re-key the stale grant")
need(model.count('Toggle it off and on') == 1,
     "the Accessibility repair notice must live in exactly one shared gate")
need('Privacy_Accessibility' in model,
     "an untrusted AX jump does not open the Accessibility pane")
need('Quit COS Control and open it again' not in model,
     "the relaunch advice is back; relaunching cannot repair a stale TCC grant")
need(model.count('ensureAccessibilityTrust()') >= 3,
     "Claude and Cursor jumps do not share the single Accessibility gate")
need('Opened Agents. Could not select that tab' in model,
     "a tab miss is not named on the pet")
need('pressCursorAgentTab' in model, "Cursor jump does not press the Agents list row")
need('agentTab: session.name' in model,
     "Cursor tab match must use the session name, not the workspace fallback title")
need('Agents miss' in model, "Cursor miss is not named on the pet")
need('did not open the folder' in model, "a missing Cursor.app path still opens the IDE folder")
need('no spawn' in model, "the running-Cursor miss notice does not say no spawn")
reveal = model.split("func revealCursorAgentsWindow")[1].split("func cursorWindowTitles")[0]
running_branch = reveal.split("if let running = runningCursor()")[1].split("spawnCursorAgentsWindow")[0]
need('activateRunningApp(running)' not in running_branch,
     "running Cursor still raises every Cursor window, including the IDE")
need('activateCursorAgentsApp' in running_branch,
     "running Cursor does not activate Cursor without raising the IDE")
need('pressCursorAgentTab' in running_branch,
     "running Cursor does not press the Agents list row")
need('ensureAccessibilityTrust()' in running_branch,
     "running Cursor does not gate on Accessibility before the tab press")
need('spawnCursorAgentsWindow(' not in running_branch,
     "running Cursor still spawns --glass --new-window")
need('localizedCaseInsensitiveContains(trimmed)' not in model,
     "matching the session title against Cursor windows raises the IDE")
tab = "func pressCursorAgentTab".join(model.split("func pressCursorAgentTab")[1:]).split("func pressCursorMenuItems")[0]
need('AXWindow' in tab, "the tab press does not skip AXWindow")
need('AXMenuBar' in tab, "the tab press does not skip AXMenuBar")
need('AXTextField' in tab, "the tab press does not skip text fields")
need('cursorAgentsWindow(from: element) else { return false }' in tab,
     "tab press must not walk the IDE when the Agents window is missing")
need('activateAllWindows' not in model.split("func revealCursorAgentsWindow")[1].split("func activateProcess")[0],
     "raising the Agents Window must not also raise the IDE")
need('enum CursorAgentTabMatch' in (root / "Sources/Models.swift").read_text(),
     "Agents tab matching is not named")
need('enum ClaudeSessionRowMatch' in (root / "Sources/Models.swift").read_text(),
     "Claude sidebar matching is not named")
need('sendReopenEvent' in model, "minimized platform windows have no Dock-click reopen")
need('deminiaturizeWindows' in model, "miniaturized windows are not restored")
need('sessionRevealOpenMode' in (root / "HelperSources/main.swift").read_text(),
     "Cursor reveal openMode is not named")
need('petPreferredFocus' in (root / "Sources/Models.swift").read_text(),
     "pet focus does not prefer the running session")
need('applyLiveWorkingState' in (root / "HelperSources/main.swift").read_text(),
     "server Cursor rows are not overlaid with composer working state")
helper_src = (root / "HelperSources/main.swift").read_text()
live_work = helper_src.split("func applyLiveWorkingState")[1].split("func loadCursorComposerMeta")[0]
need('provider == "codex"' in live_work,
     "server Codex rows are not overlaid with transcript working state")
need('readDataToEndOfFile' in (root / "HelperSources/main.swift").read_text().split("func loadCursorComposerMeta")[1].split("func loadCursorComposerNames")[0],
     "composer sqlite must drain stdout or a 64KB JSON pipe deadlocks")
need('activityOpenSessionID' in activity, "waveform open does not consume activityOpenSessionID")
need('openClaudeSession(staged)' in activity, "waveform open does not restage the session after select()")
need('model.$petSize.sink' in (root / "Sources/SessionPet.swift").read_text(),
     "the pet panel does not refit when size changes")
need('model.$petNotice.sink' in (root / "Sources/SessionPet.swift").read_text(),
     "the pet panel does not refit when a Cursor miss notice appears")
need('size: CGFloat' in (root / "Sources/COSMotion.swift").read_text(),
     "the pet sprite cannot take a pixel size")
need('case custom' in (root / "Sources/Models.swift").read_text(),
     "pet size has no custom pixel preset")
need('PetPanelFrame.clamped' in (root / "Sources/SessionPet.swift").read_text(),
     "an off-screen pet frame is not snapped back onto a display")
need('top - frame.size.height' not in (root / "Sources/SessionPet.swift").read_text(),
     "growing the pet downward parks it under the screen")
need('if model.petExpanded { model.petExpanded = false }' in
     (root / "Sources/SessionPet.swift").read_text(),
     "hiding the pet must not assign petExpanded when it is already false")
pet = (root / "Sources/SessionPet.swift").read_text()
need('} else if let focus {' not in pet,
     "a Cursor miss notice must not replace the clickable status bubble")
listed = pet.split("private var sessionList")[1].split("private func statusBubble")[0]
need('model.openSessionInPlatform(session)' in listed,
     "a pet list row only changes focus and does not open the session")
need('.contentShape(Rectangle())' in listed,
     "the pet list row does not hit-test the empty card")
need('model.petFocusID = session.id' in listed,
     "opening a list row must still focus that session")
bubble = pet.split("private func statusBubble")[1].split("private var targetHelp")[0]
need('model.openSessionInPlatform(session)' in bubble,
     "the focused pet card does not open the session")
need('.contentShape(Capsule())' in bubble,
     "the focused pet card does not hit-test the empty capsule")
close = re.search(r"func windowWillClose\([^)]*\)[^{]*\{(.*?)(?:\n    \}|\n\}\n)", activity, re.S)
need(close is not None, "windowWillClose not found")
need('SessionPet' not in close.group(0), "closing Activity must not tear down the pet")
ROUTECHK

# ── Calendar day cell hit target (0.5.86) ────────────────────────────
#
# Under .buttonStyle(.plain) SwiftUI hit-tests only rendered content, so a
# clear background is dead space. Without contentShape the tap target is the
# date glyph and a 5pt dot rather than the square the user can see.
/usr/bin/python3 - "$ROOT" <<'CALCHK'
import sys, pathlib, re
meetings = (pathlib.Path(sys.argv[1]) / "Sources/ActivityMeetings.swift").read_text()
# Anchored on the day cell's OWN action, which is unique. A generic
# RoundedRectangle anchor matched an unrelated button earlier in the file
# and failed against correct code.
block = re.search(r"onSelectDay\(selectedDay == cell\.date(.{0,1400}?)\.buttonStyle\(\.plain\)", meetings, re.S)
if block is None: sys.exit("calendar: day-cell button block not found")
if ".contentShape(" not in block.group(1):
    sys.exit("calendar: the day cell has no contentShape, so only the date glyph is clickable")
CALCHK

# ── Video and file attachments (0.5.80) ──────────────────────────────
#
# The MODEL half (parsing the server's real video ref, category fallback,
# extension mapping) is EXECUTED by Tests/ModelsContract.swift. These pin
# the wiring the contract test cannot see.
/usr/bin/python3 - "$ROOT" <<'MEDIACHK'
import sys, pathlib
root = pathlib.Path(sys.argv[1])
activity = (root / "Sources/ActivityWindow.swift").read_text()
model = (root / "Sources/ControllerModel.swift").read_text()

def need(cond, msg):
    if not cond: sys.exit(f"media-attachments: {msg}")

# A non-image must never be decoded as an NSImage -- that is how a video
# used to fail -- and its temp file must survive for the system opener.
need("attachment.opensInline" in model, "the preview path does not branch on opensInline")
need("NSWorkspace.shared.open" in model, "there is no external open path for video or documents")
need("openExternally" in model, "the external opener is not wired")
# Extension comes from the MIME, never the server-supplied label.
need("attachment.fileExtension" in model, "the temp file does not carry a mime-derived extension")
need("attachment.label" not in model.split("func openExternally")[1].split("func ")[0],
     "the external opener must not build a filename from the untrusted label")

# The left glyph wears the type. A row that renders the bare section glyph
# cannot tell a video from a text-only turn, which is the whole point.
need("messageGlyph(turn)" in activity, "the message row does not use the badged glyph")
need("AttachmentMark(category:" in activity, "the corner badge is not drawn")
mark_shape = (root / "Sources/COSMotion.swift").read_text()
need("struct AttachmentMark" in mark_shape, "the AttachmentMark shape is missing")
# FILLED, not stroked: a 1.15pt outline at 11pt collapses into a speck, which
# is exactly what the first design pass proved.
need(".fill(attachmentTint(" in activity, "the badge must be filled, never stroked")

# The list badge names the TYPE. A hardcoded photo glyph over a video is
# the same lie one layer out from the strip.
need('systemImage: "photo"' not in activity,
     "a hardcoded photo glyph survives in the row badge")
need("turn.attachmentGlyph" in activity, "the row badge does not derive its icon from the attachments")

# A video reads as a video before you click it.
# BOUND to its condition, not merely present. A bare substring check for
# `attachment.isVideo` passed while the play affordance was disabled,
# because the same identifier appears in the fallback-glyph ternary.
import re
play_block = re.search(r"if attachment\.isVideo \{(.{0,900}?)\n\s*\}", activity, re.S)
need(play_block is not None, "the play affordance is not guarded by attachment.isVideo")
need("play.circle.fill" in play_block.group(1),
     "the video branch does not render a play affordance")
need("attachment.isDocument" in activity, "the strip has no document fallback glyph")
need("durationLabel" in activity, "the poster does not show duration")
# Titles derive from CONTENTS. The old signature passed a hardcoded
# title:, which put "Your image" over a .mov. Checked as a call
# signature, not as a bare string -- the string legitimately appears in
# the doc comment explaining why it is gone.
need("attachmentStrip(title:" not in activity,
     "the hardcoded-title attachmentStrip signature survives")
need("attachmentStrip(attachments:" in activity and "fallback:" in activity,
     "the strip is not called with a derived title")
MEDIACHK

# ── Local model picker (0.5.79) ──────────────────────────────────────
#
# The pin's write shape and charset guard are EXECUTED by the helper
# self-test. These pins cover the wiring: the picker renders the configured
# pin even when its model is gone from the daemon, Apply routes through the
# same perform() transaction as every other setting, and the allowlist
# carries the key (0.5.73's lesson).
/usr/bin/python3 - "$ROOT" <<'OLLAMACHK'
import sys, pathlib
root = pathlib.Path(sys.argv[1])
helper = (root / "HelperSources/main.swift").read_text()
model = (root / "Sources/ControllerModel.swift").read_text()
views = (root / "Sources/Views.swift").read_text()

def need(cond, msg):
    if not cond: sys.exit(f"ollama-picker: {msg}")

need('case "set-ollama-model"' in helper and "withMutationLock" in helper,
     "set-ollama-model is not dispatched under the mutation lock")
need('"ollamaConfiguredModel": loadedEnvironmentValue("COS_OLLAMA_MODEL")' in helper,
     "status does not expose the configured pin")
need('perform("set-ollama-model"' in model, "the picker does not route through perform()")
need('(not pulled)' in views, "a pin whose model is gone from the daemon must still render")
need('Automatic (newest pull)' in views, "the automatic option is not rendered")
need('"daemon_down"' in model and "Ollama is not running" in views,
     "an unreachable daemon must render as a state, not an error")
OLLAMACHK

# ── Session Chat (0.5.75) ────────────────────────────────────────────
#
# The pure contract surface (targetKey format, poll classifier, id shapes,
# the toggle's Off write) is EXECUTED by the helper self-test above. These
# pins cover what only source shape can see: which call site carries the
# Continue-Anyway override, that the prompt never rides argv, and that the
# caution and teardown paths exist where the composer mounts.
/usr/bin/python3 - "$ROOT" <<'CHATCHK'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
helper = (root / "HelperSources/main.swift").read_text()
model = (root / "Sources/ControllerModel.swift").read_text()
models = (root / "Sources/Models.swift").read_text()
activity = (root / "Sources/ActivityWindow.swift").read_text()

def need(cond, msg):
    if not cond: sys.exit(f"session-chat: {msg}")

# The prompt travels over stdin, never argv — argv is world-readable via ps.
send_start = helper.index("private func emitSessionChatSend")
send_end = helper.index("private func emitSessionChatTurn")
send = helper[send_start:send_end]
need("readDataToEndOfFile" in send, "send does not read the prompt from stdin")
need('option("--text"' not in send and 'option("--prompt"' not in send,
     "send must not accept the prompt as an argv option")

# targetKey is built helper-side from provider+threadId, never accepted as an
# argument — the app never touches the cross-repo format contract.
need('option("--target-key"' not in helper, "the helper must never accept a targetKey argument")
need("sessionChatTargetKey(provider: provider, threadId: threadId)" in send,
     "send does not reconstruct targetKey itself")

# acknowledgedRevision is the Continue-Anyway override. Exactly one app call
# site passes a real revision — the explicit user gesture — and every other
# post passes nil. Auto-echoing the refusal's revision would be an
# un-consented write into a thread a human just edited.
need(model.count("acknowledgedRevision: revision") == 1,
     "exactly one call site may pass a real acknowledgedRevision")
anyway = re.search(r"func continueChatAnyway\(\).*?\n    \}", model, re.S)
need(anyway is not None and "acknowledgedRevision: revision" in anyway.group(0),
     "the real acknowledgedRevision must come from continueChatAnyway only")
retry = re.search(r"func retryChatTurn\(\).*?\n    \}", model, re.S)
need(retry is not None and "acknowledgedRevision: nil" in retry.group(0),
     "retry must re-post WITHOUT an acknowledgement")

# Retry never re-mints: the same clientTurnId is the idempotency key that
# prevents a second copy landing in a real conversation.
need("UUID().uuidString" not in (retry.group(0) if retry else ""),
     "retry must reuse the pending clientTurnId, never mint a new one")

# ownerCount is load-bearing: attachable-with-owners is caution behind an
# explicit confirm, never a green light.
need("attachable && ownerCount > 0" in models, "SessionChatVerdict.caution does not read ownerCount")
send_fn = re.search(r"func sendChatMessage\(\).*?\n    \}", model, re.S)
need(send_fn is not None and "chatCautionPending = true" in send_fn.group(0),
     "sendChatMessage does not gate on the caution verdict")
need("Send into an open session?" in activity, "the caution confirm is not rendered")

# A wait-class refusal retries the same turn; it must NEVER trigger a
# re-attach (create() would refuse target_busy against our own live binding).
wait_set = re.search(r"chatWaitReasons: Set<String> = \[(.*?)\]", model, re.S)
reattach_set = re.search(r"chatReattachReasons: Set<String> = \[(.*?)\]", model, re.S)
need(wait_set is not None and "native_thread_working" in wait_set.group(1),
     "native_thread_working is not a wait-class refusal")
need(reattach_set is not None and "native_thread_working" not in reattach_set.group(1),
     "native_thread_working must never trigger a re-attach")

# Fork (0.5.76). The button appears wherever the rendered copy recommends it,
# and the match is CASE-INSENSITIVE — the server writes "or fork it" in
# lowercase, and a capital-F match shipped in 0.5.75 rendered the instruction
# with no affordance at all (caught live, first session).
fork_fn = re.search(r"static func chatCopyRecommendsFork.*?\n    \}", model, re.S)
need(fork_fn is not None and ".caseInsensitive" in fork_fn.group(0),
     "fork copy matching must be case-insensitive — the server says 'fork it' in lowercase")
need(model.count("chatCopyRecommendsFork(") >= 5,
     "every refusal path must arm the Fork button from its rendered copy")
need("Fork with this message" in activity and "forkChatThread()" in activity,
     "the Fork button is not rendered")
fork_send = helper[helper.index("private func emitSessionChatFork"):helper.index("private func emitSessionChatReply")]
need("readDataToEndOfFile" in fork_send, "fork does not read the prompt from stdin")
need('option("--text"' not in fork_send and 'option("--prompt"' not in fork_send,
     "fork must not accept the prompt as an argv option")
fork_done = re.search(r'case "forked":.*?case "route_absent"', model, re.S)
need(fork_done is not None and "clearPendingTurn()" in fork_done.group(0),
     "a successful fork must abandon the original pending turn — the message went to the fork")

# Composer mounts INSIDE ClaudeSessionDetailPane (the route regex above pins
# the pane as the branch's first token) and consults the gate.
need("SessionChatComposer(model: model)" in activity, "the composer is not mounted in the session pane")
need("sessionChatGateMessage" in activity, "the composer does not consult the gate")
need("model?.closeClaudeSession()" in activity, "windowWillClose does not tear the chat down")
close_fn = re.search(r"func closeClaudeSession\(\).*?\n    \}", model, re.S)
need(close_fn is not None and "resetSessionChat()" in close_fn.group(0),
     "closeClaudeSession does not reset chat state")
CHATCHK

echo "COS Control: helper self-tests, secret-boundary checks, and macOS 14 builds passed"
