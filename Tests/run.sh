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
/usr/bin/grep -q 'case "meetings-library"' "$ROOT/HelperSources/main.swift"
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
/usr/bin/grep -q 'systemImage: model.status.running ? "eyeglasses"' "$ROOT/Sources/COSControlApp.swift"
/usr/bin/grep -q 'eyeglasses.slash' "$ROOT/Sources/COSControlApp.swift"
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
# Default-off flag: Off REMOVES the key. Writing "0" would leave a permanent
# artifact and contradict the server contract that absent means disabled.
/usr/bin/python3 - "$ROOT" <<'PY'
import sys, pathlib
text = pathlib.Path(sys.argv[1], "HelperSources/main.swift").read_text()
start = text.index("private func threadAttachEnvironment")
end = text.index("private func requireThreadAttach")
body = text[start:end]
if '"COS_THREAD_ATTACH_ENABLED": "0"' in body:
    sys.exit('Continue off must remove the key, not write "0"')
if "removing" not in body:
    sys.exit("Continue off must use the removingKeys delete path")
PY
/usr/bin/grep -q 'struct SpeakerReviewPane' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'activityLauncher' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'ActivitySection.allCases' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'Open Messages, Speakers, Meetings' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'ActivityWindowPresenter' "$ROOT/Sources/COSControlApp.swift"
/usr/bin/grep -q 'activityWindow.show(model: model)' "$ROOT/Sources/COSControlApp.swift"
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
  "$ROOT/Sources/COSBrand.swift" \
  "$ROOT/Sources/Views.swift" \
  "$ROOT/Sources/ActivityWindow.swift" \
  "$ROOT/Sources/ActivityMeetings.swift" \
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
need('openActivity()' in views, "the menu panel cannot open Activity")
need('ActivityWindowPresenter' in app and 'activityWindow.show(model: model)' in app,
     "the click-only Activity presenter is not wired")
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
ROUTECHK

echo "COS Control: helper self-tests, secret-boundary checks, and macOS 14 builds passed"
