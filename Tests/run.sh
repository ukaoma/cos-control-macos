#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
TARGET="arm64-apple-macosx14.0"
# Keep the self-test home under /tmp: loopbackAPIPort honors COS_CONTROL_TEST_HOME only
# when it starts with /tmp/, and with a home elsewhere the self-test failed its workspace
# fixture (measured 2026-09-13, released 0.5.223 helper included).
TMP="$(mktemp -d /tmp/cos-control-tests.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/home"

node "$ROOT/Tests/MemoryWorkspaceStartup.cjs"
node "$ROOT/Tests/MemoryOwnerRaces.cjs"
node "$ROOT/Tests/MemoriesAppliedCanary.cjs"

swiftc -target "$TARGET" -swift-version 6 -strict-concurrency=complete \
  "$ROOT/HelperSources/main.swift" \
  -framework Security -framework AppKit \
  -o "$TMP/cos-control-helper"

# The helper prints WHICH expectation failed. Capturing that into a variable
# under `set -e` threw it away: a failing self-test aborted this script at this
# line having printed nothing at all, so the whole suite reported "exit 1" with
# zero bytes of output (measured 2026-08-31, mutating firstJSONArray). Every
# helper self-test failure was silent. Show it, then fail.
if ! SELF_TEST="$(COS_CONTROL_TEST_HOME="$TMP/home" "$TMP/cos-control-helper" self-test 2>&1)"; then
  print -u2 "helper self-test FAILED (helper exited non-zero):"
  print -u2 -r -- "$SELF_TEST"
  exit 1
fi
/usr/bin/python3 -c '
import json, sys
try:
    value = json.loads(sys.argv[1])
except ValueError:
    sys.exit("helper self-test emitted no JSON:\n" + sys.argv[1][:2000])
if not value.get("ok"):
    sys.exit("helper self-test FAILED: " + str(value.get("message") or value)[:2000])
count = value.get("details", {}).get("tests", 0)
if count < 727:
    sys.exit(f"helper self-test ran only {count} checks; expected at least 727 (727 at 0.5.238: the Codex rollout reader, open-thread list, discovery and the pet pipeline over them)")
' "$SELF_TEST"

python3 "$ROOT/Tests/HeldNamingTransport.py" "$TMP/cos-control-helper"
python3 "$ROOT/Tests/HeldNamingGuardMutations.py"

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
  "$ROOT/Sources/COSMarkdownParser.swift" "$ROOT/Sources/COSMarkdown.swift" \
  "$ROOT/Sources/SessionLiveFeed.swift" \
  "$ROOT/Sources/SessionPet.swift" \
  "$ROOT/Sources/COSControlApp.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement \
  -o "$TMP/COS Control"

swiftc -target "$TARGET" -swift-version 6 -strict-concurrency=complete \
  "$ROOT/Sources/Models.swift" \
  "$ROOT/Tests/ModelsContract.swift" \
  -framework AppKit \
  -o "$TMP/models-contract"
swiftc -target "$TARGET" -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Sources/HelperClient.swift" "$ROOT/Tests/HelperTransportContract.swift" \
  -framework AppKit -o "$TMP/helper-transport-contract"
"$TMP/helper-transport-contract"
"$TMP/models-contract"
# 0.5.232: the Markdown parser is pure Foundation and pinned by an EXECUTED contract
# (the scribe's meeting, lists, tasks, tables, code, quotes, details, speaker lines).
swiftc -target "$TARGET" -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/COSMarkdownParser.swift" "$ROOT/Tests/MarkdownContract.swift" \
  -o "$TMP/markdown-contract"
"$TMP/markdown-contract"
# 0.5.233: the live feed reducer is pure Foundation and pinned by an EXECUTED contract
# over recorded 6.48.2 stream frames (reseed, gap, prompt window, state line, elapsed).
swiftc -target "$TARGET" -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/SessionLiveFeed.swift" "$ROOT/Tests/SessionLiveFeedContract.swift" \
  -o "$TMP/session-live-feed-contract"
"$TMP/session-live-feed-contract" "$ROOT"
swiftc -target "$TARGET" -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Tests/JediUpgradeContract.swift" \
  -framework AppKit -o "$TMP/jedi-upgrade-contract"
"$TMP/jedi-upgrade-contract" "$ROOT"
swiftc -target "$TARGET" -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Tests/JediGalleryContract.swift" \
  -framework AppKit -o "$TMP/jedi-gallery-contract"
"$TMP/jedi-gallery-contract" "$ROOT/Resources"
swiftc -target "$TARGET" -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Sources/HelperClient.swift" "$ROOT/Sources/ControllerModel.swift" \
  "$ROOT/Sources/COSBrand.swift" "$ROOT/Sources/COSMotion.swift" "$ROOT/Sources/COSConfirm.swift" \
  "$ROOT/Sources/Views.swift" "$ROOT/Sources/ActivityWindow.swift" "$ROOT/Sources/ActivityMeetings.swift" \
  "$ROOT/Sources/COSMarkdownParser.swift" "$ROOT/Sources/COSMarkdown.swift" \
  "$ROOT/Sources/SessionLiveFeed.swift" \
  "$ROOT/Sources/SessionPet.swift" \
  "$ROOT/Tests/JediIdleContract.swift" -framework AppKit -framework SwiftUI -o "$TMP/jedi-idle-contract"
"$TMP/jedi-idle-contract" "$ROOT/Resources"
if [[ -n "${COS_JEDI_CANARY_OUTPUT:-}" ]]; then
  "$TMP/jedi-idle-contract" "$ROOT/Resources" "$COS_JEDI_CANARY_OUTPUT"
fi
# The executable pixel test must cover the same loader the gallery calls.
/usr/bin/python3 - "$ROOT" <<'GALLERY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
source = (root / 'Sources/ControllerModel.swift').read_text()
method = source.split('func bundledCharacterThumb(for character:', 1)[1].split('\n    }', 1)[0]
assert 'PetSpriteStore.galleryThumbnail(in: folder)' in method
assert 'poseFileName' not in method and 'PetSpriteStrip.slice' not in method
assert 'model.bundledCharacterThumb(for: character)' in (root / 'Sources/Views.swift').read_text()
GALLERY
/usr/bin/grep -q 'cursor-probe-cache.json' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'recent-messages' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "fetch-media"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q '/api/media/\\(id)/content?variant=\\(variant)' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'Copy + images' "$ROOT/Sources/ActivityWindow.swift"

# ── Morning brief (0.5.181) ───────────────────────────────────────────────────
# The card must be mounted, the helper must carry all three commands, and the
# settings model must build its patch from the same keys the server validates.
/usr/bin/grep -q 'case "morning-brief": try emitMorningBrief()' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "set-morning-brief": try setMorningBrief()' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "run-morning-brief": try runMorningBrief()' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q '"/api/morning-brief/run", method: "POST"' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q '"morningBriefSupported": morningBriefSupported' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'if model.status.morningBriefSupported { morningBriefCard }' "$ROOT/Sources/Views.swift"
/usr/bin/python3 - "$ROOT" <<'BRIEF'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
models = (root / 'Sources/Models.swift').read_text()
patch = models.split('func patch() -> [String: Any] {', 1)[1].split('\n    }', 1)[0]
for key in ('"enabled"', '"time"', '"timezone"', '"days"', '"sources"', '"closingInstruction"'):
    assert key in patch, 'MorningBriefSettings.patch() lost %s' % key
views = (root / 'Sources/Views.swift').read_text()
# The save path must go through the DRAFT, never straight from model state.
assert 'if let draft = briefDraft { model.saveMorningBrief(draft) }' in views
# The source list is capped and scrolls, per the 390pt panel rule.
sources = views.split('private func morningBriefSources(', 1)[1].split('\n    }', 1)[0]
assert 'ScrollView' in sources and '.frame(maxHeight: 230)' in sources
# 0.5.183 — server 6.43.1 coverage: parsed by source id, rendered under the
# description, amber ONLY for unavailable; and the last run's section outcome.
assert 'details["coverage"]?.object?["sources"]?.array' in models
assert 'let coverage: [String: Coverage]' in models
row = views.split('private func morningBriefSourceRow(', 1)[1].split('\n    }', 1)[0]
assert 'model.morningBrief?.coverage[source.id]' in row and 'coverage.state == "unavailable" ? COSPalette.amber' in row
assert 'var sectionsLabel: String?' in models and 'object["sections"]?.array' in models
assert 'if let sections = run.sectionsLabel { return "Delivered' in views
BRIEF

# ── Origin label (0.5.185) ────────────────────────────────────────────────────
# Server 6.43.4 stamps origin/originId on a run the Mac started. The helper
# passes exactly four bounded keys through its allowlist, the model reads them
# through the failable init with the same bounds, and the Activity window rows
# render the label. What EXECUTES: the allowlist (helper self-test) and the
# failable init + every derived label incl. detailMetaLine order and the hover
# titles (ModelsContract). What is SHAPE-ONLY, because Views/ActivityWindow are
# compiled and never run here: the row segments, their order, the legend, the
# brief card's reason line. Those pins stop the wiring from being removed and
# nothing more.
/usr/bin/python3 - "$ROOT" <<'ORIGIN'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
helper = (root / 'HelperSources/main.swift').read_text()
norm = helper.split('private func normalizeRecentMessage(', 1)[1].split('\n    }', 1)[0]
for key in ('"modelPreference"', '"origin"', '"originId"', '"messageEra"'):
    assert key in norm, 'helper allowlist lost %s' % key
assert 'Self.recentOriginKinds.contains(origin)' in norm and 'validOriginID(originId)' in norm
assert 'validToken(model, max: 64)' in norm and 'era.count <= 80' in norm
assert 'recentOriginKinds: Set<String> = ["routine", "task"]' in helper
assert 'guard (1...64).contains(value.count)' in helper.split('private func validOriginID(', 1)[1].split('\n    }', 1)[0]
models = (root / 'Sources/Models.swift').read_text()
turn = models.split('struct GlassesTurn:', 1)[1].split('\nstruct ', 1)[0]
for key in ('object["modelPreference"]?.string', 'object["origin"]?.string', 'object["originId"]?.string', 'object["messageEra"]?.string'):
    assert key in turn, 'GlassesTurn failable init lost %s' % key
assert 'let idBase = [no.map(String.init) ?? "x", sessionId, object["timestamp"]?.int.map(String.init) ?? UUID().uuidString].joined(separator: "|")' in turn
assert 'var originLabel: String?' in turn and 'var modelLabel: String?' in turn
assert 'originKinds: Set<String> = ["routine", "task"]' in turn
activity = (root / 'Sources/ActivityWindow.swift').read_text()
row = activity.split('private func messageRow(', 1)[1].split('\n    }', 1)[0]
# Each segment is GUARDED, never rendered empty: an unstamped row (any server
# before 6.43.4) must carry neither. Label before model.
assert 'if let origin = turn.originLabel {' in row and 'if let modelLabel = turn.modelLabel {' in row, 'messageRow lost a guarded segment'
assert row.index('if let origin = turn.originLabel {') < row.index('if let modelLabel = turn.modelLabel {'), 'label must precede model'
assert 'turn.sessionId.prefix(8)' not in row, 'the session chunk would appear on every row from any server'
detail = activity.split('private func messageDetail(', 1)[1].split('\n    }', 1)[0]
assert 'turn.detailMetaLine' in detail
# The legend is a positive claim, above the list, and the panel has no message list at all.
assert 'ROUTINE and TASK mark a run your Mac started.' in activity, 'Activity window legend missing'
assert activity.index('ROUTINE and TASK mark a run your Mac started.') < activity.index('ForEach(visibleRecentMessages)'), 'legend must sit above the list'
# No sentence about UNLABELED rows in either voice: on a pre-6.43.4 server the
# Mac's own brief is unlabeled, so both "were started by you" and "runs your
# Mac started are labeled" are false there.
assert 'Unlabeled rows were started by you' not in activity and 'Runs your Mac started are labeled' not in activity
views = (root / 'Sources/Views.swift').read_text()
assert 'recentGlassesCard' not in views and 'turnRowTitle' not in views, 'the dead panel message card is back'
assert 'attachmentStrip(title:' not in views, 'orphaned helper of the deleted panel card is back'
assert 'Last brief failed · ' in views and '.help(morningBriefRunLabel(last))' in views
assert '@ViewBuilder private var morningBriefActions' in views or '@ViewBuilder\n    private var morningBriefActions' in views
ORIGIN

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
import json, pathlib, re, sys
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
# 0.5.184 — fail-open provider proof: every installed provider is tried, the
# update commits on ANY real-query pass, a vendor quota is a skip with a named
# reason, and zero proofs still fails closed. On 2026-09-01 Claude's session
# limit rolled six 6.43.1 updates back while Codex proved in 7s.
/usr/bin/python3 - "$ROOT" <<'PROOF'
import pathlib, sys
src = (pathlib.Path(sys.argv[1]) / 'HelperSources/main.swift').read_text()
body = src.split('private func transactionalRuntimeProofFailure(', 1)[1].split('\n    private func maintenanceStatus(', 1)[0]
assert 'return provider.capitalized + " real query failed: "' not in body, 'proof loop still fails on the first provider'
assert 'let proofProviders = transactionalProofProviders(expectedProviders)' in body
assert 'skipped.append(provider.capitalized + " skipped: " + proofSkipReason(code: code, detail: detail))' in body
assert '} else if proved.isEmpty {' in body and 'return "no AI provider proved a real query ("' in body, 'zero proofs must fail closed'
assert 'recordProofSummary(proved: proved, skipped: skipped, committed: true)' in body
# Kokoro gates stay after the provider block, unchanged.
assert body.index('recordProofSummary(proved: proved, skipped: skipped, committed: true)') < body.index('progress("Proving Kokoro generation…")')
assert 'return "Kokoro native playback proof failed"' in body
assert 'if resolveAgentBinary() != nil { providers.append("cursor") }' in src
assert 'case "provider_quota": return "session or usage limit"' in src
assert '"lastProofSummary": lastProofSummaryLine() ?? NSNull(),' in src
PROOF
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

# --- Signing: a shipped build must never be ad-hoc --------------------------
# macOS keys TCC (Accessibility) to the DESIGNATED REQUIREMENT. Ad-hoc signing
# makes that requirement a per-build cdhash, so every install strands the
# user's grant while System Settings still shows the toggle ON. The stable
# self-signed identity "COS Control Local" gives a constant requirement
# (certificate root) instead. Cost of not pinning this: the 0.5.107 saga, then
# again on 2026-09-01 when a release-adhoc.sh build went over a release.
/usr/bin/python3 - "$ROOT" <<'SIGNCHK'
import re, subprocess, sys, pathlib, tempfile, shutil
root = pathlib.Path(sys.argv[1])
def need(c, m):
    if not c: sys.exit(f"signing: {m}")

rel = (root / "Scripts/build-release.sh").read_text()
# The safe identity must be the DEFAULT, not something a builder opts into.
need("security find-identity" in rel,
     "build-release.sh no longer looks for the stable identity, so a build "
     "silently falls back to ad-hoc and strands every Accessibility grant")
need(re.search(r'ALLOW_ADHOC=0', rel) is not None,
     "build-release.sh no longer overrides COS_ALLOW_ADHOC when the stable "
     "identity exists — release-adhoc.sh could ship an ad-hoc build again")
adhoc = (root / "Scripts/release-adhoc.sh").read_text()
need("ONLY shipping path" not in adhoc,
     "release-adhoc.sh again claims to be the shipping path; that stale "
     "header is what caused the 2026-09-01 Accessibility regression")

# Real artifacts, not just source shape: anything staged in dist/ must carry
# the stable requirement. A source-shape check alone cannot see the signature.
STABLE_ROOT = "c520fc85c286e47d67da5e9b6af583be30a20d06"
# ONLY the artifact for the version being built. dist/ accumulates every
# historical zip (189 of them, 2.3 GB, as of 2026-09-01); globbing them all
# made this check unpack the entire archive on every run.
import plistlib
_v = plistlib.loads((root / "Resources/Info.plist").read_bytes())["CFBundleShortVersionString"]
for zf in sorted((root / "dist").glob(f"COS-Control-macOS-arm64-{_v}.zip")):
    tmp = tempfile.mkdtemp()
    try:
        subprocess.run(["/usr/bin/ditto", "-xk", str(zf), tmp],
                       check=True, capture_output=True)
        app = pathlib.Path(tmp) / "COS Control.app"
        if not app.exists(): continue
        req = subprocess.run(["/usr/bin/codesign", "-d", "-r-", str(app)],
                             capture_output=True, text=True).stderr \
            + subprocess.run(["/usr/bin/codesign", "-d", "-r-", str(app)],
                             capture_output=True, text=True).stdout
        need("cdhash" not in req.split("designated =>")[-1],
             f"{zf.name} is AD-HOC signed (designated requirement is a per-build "
             "cdhash). Installing it strands the user's Accessibility grant. "
             "Rebuild with the stable identity.")
        need(STABLE_ROOT in req,
             f"{zf.name} is not signed by the stable 'COS Control Local' root; "
             "TCC grants will not survive the update")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
SIGNCHK

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
# ZERO-PROFILE USERS ARE THE POINT. Add a voice has its own view (0.5.222); the
# empty voice directory must open it, or the people who need it most never find it.
/usr/bin/python3 - "$ROOT/Sources/ActivityWindow.swift" <<'PYEOF'
import io, sys, re as _re
src = io.open(sys.argv[1], encoding='utf-8').read()
code = '\n'.join(l for l in src.split('\n') if not l.strip().startswith('//'))
assert code.count('addVoiceSection') == 2, \
    f'addVoiceSection must be declared once and rendered once, in Samples to review; found {code.count("addVoiceSection")}'
pane = code[code.index('private var voiceSamplesPane'):]
pane = pane[:pane.index('private func addVoiceNotice')]
assert 'addVoiceSection' in pane, 'Samples to review must render the Add a voice card'
directory = code[code.index('private var voiceDirectoryList'):]
directory = directory[:directory.index('private var voiceDirectoryColumnHeader')]
e = directory.index('} else if model.voiceDirectory.isEmpty {')
# The empty branch has its own if/else (failed load vs nobody enrolled), so it ends
# where the populated branch's VStack begins, not at the first else.
empty = directory[e:directory.index('        } else {\n            VStack(spacing: 0) {', e)]
assert 'speakerSubview = .samples' in empty and 'Button(' in empty, \
    'an empty voice directory must open Samples to review in one click'
assert 'if model.voiceDirectoryLoadFailed {' in empty and 'Button("Retry")' in empty, \
    'a directory that failed to load must offer Retry, not the zero-profile guidance'

# THE LIST SCROLLS IN PLACE. An uncapped ForEach over held sessions grew the layout
# past the window (production, 2026-08-26). The card has its own view now, so a long
# list fills it inside a flexible frame with a floor; the root clamp is pinned in 0.5.222.
section = code[code.index('private var addVoiceSection'):]
section = section[:section.index('private func addVoiceRow')]
assert 'extAudioInlineRowLimit' in section, 'the held-audio list must be capped before it renders inline'
assert _re.search(r'ScrollView \{[^}]*?ForEach\(model\.extAudioSessions\)[\s\S]{0,400}?\.frame\(minHeight: Self\.extAudioListMinHeight, maxHeight: \.infinity\)', section), \
    'the long held-audio list must scroll inside a flexible frame with a floor'
assert 'private static let extAudioListMinHeight: CGFloat = 88' in code, 'the held-audio list floor is 88 pt'
assert not _re.search(r'\.frame\(height: (?!1\))', section), 'no fixed heights in the Add a voice card except 1 pt hairlines'
assert section.index('naming it uses up the audio') < section.index('addVoiceRow(session)'), \
    'the uses-up-the-audio line must come before the session list, where a short window cannot clip it'
assert section.index('if model.heldGroupsState == nil {') < section.index('} else if heldGroupsUsable {'), \
    'before the grouping route answers, the card must say it is loading, not show enroll-ext rows'
print('    add-a-voice has its own view; the empty directory opens it')
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

# Slice the REAL panel body, not a fixed window after a symbol name: the old
# 400-char probe broke the moment the row was renamed (0.5.167).
_panel = views[views.index('private var mainPanel'):]
_panel = _panel[:_panel.index('\n    }')]
assert 'updateRow' in _panel and 'noticeBanner' in _panel, \
    'the panel must render both the update row and the notice banner'
# Updates answer "am I current?" FIRST. Buried under the status card and the
# utilities, the only way to ask was to scroll to the very bottom (Miles).
assert _panel.index('updateRow') < _panel.index('statusCard'), \
    'the update row must sit at the top of the panel, above the status card'
# The CALL SITE, not the words: the footer's own comment quotes the old label
# ("Check for updates Quit"), so a bare string check trips on documentation.
_row = views.split('private var updateRow')[1].split('private var updateBanner')[0]
assert 'Button("Check for updates"' in _row, \
    'the manual check must live in the top update row'
# The whole footer body, bounded by the next declaration. A 1200-char window
# stopped one line short of the Quit button — the third fixed-window pin to
# break this way today, so this one slices to a real boundary.
_footer = views.split('private var footer')[1].split('private var footerLabel')[0]
assert 'Button("Check for updates"' not in _footer, \
    'the manual check must no longer be buried in the footer'
assert 'Button("Quit"' in _footer, 'Quit stays in the footer'
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

# --- 0.5.128 archive drill-through ---------------------------------------------
# The day list counted months of history it could never open. Pin every rung:
# helper command, model loaders, the openers, and the render conditions they
# write -- an opener that sets no flag the body reads is an unreachable pane.
assert '"archive-chat": try emitArchiveChat' in helper, 'the leaf command must be dispatched'
assert 'chats/\\(index)/messages' in helper, 'archive-chat must call the per-chat messages route'
assert 'Int(raw), index >= 0' in helper, 'an index reaching a path segment must be validated'

assert 'func loadArchiveChats(date: String)' in model, 'the day rung needs a loader'
assert 'func loadArchiveMessages(date: String, index: Int)' in model, 'the chat rung needs a loader'
# Cleared BEFORE the await, not after: otherwise the previous day's chats sit on
# screen under the new day's title for the length of the request.
day_fn = model.index('func loadArchiveChats(date: String)')
# The FUNCTION BODY, not a fixed byte window: a 420-char slice silently stopped
# covering the await the moment the function grew (0.5.166), turning a real
# ordering guard into a crash.
day_body = model[day_fn:]
day_body = day_body[:day_body.index('\n    }')]
assert day_body.index('archiveChats = []') < day_body.index('await helper.run'), \
    'stale chats must be cleared before the request, not after it returns'

# Opener -> render condition. Both panes mount on flags the openers write.
assert 'func openArchiveDay(' in view and 'func openArchiveChat(' in view
assert 'let date = selectedArchiveDate, let chat = selectedArchiveChat' in view, \
    'the chat pane must mount on BOTH flags, so Back can land on the day'
assert 'archiveDayDetail(date: date)' in view and 'archiveChatDetail(date: date, index: chat)' in view
assert 'Button { openArchiveDay(day.date) }' in view, 'an archive DAY row must open its day'
assert 'Button { openArchiveDay(hit.date) }' in view, 'a SEARCH HIT is a day and must open too'
assert 'Button { openArchiveChat(date: date, index: chat.index) }' in view, \
    'a CHAT row must open its transcript'
# Back unwinds one rung at a time. Chat must be tested BEFORE date, or a chat's
# Back would drop straight past its day to the day list.
chat_at = view.index('section == .messages, selectedArchiveChat != nil')
date_at = view.index('section == .messages, selectedArchiveDate != nil')
assert chat_at < date_at, 'goBack must unwind chat before date, one rung per press'
print('    archive drill-through: day -> chats -> transcript, openers bound to panes')
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
/usr/bin/grep -q 'Seven views into the work' "$ROOT/Sources/ActivityWindow.swift"
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
/usr/bin/grep -q 'Label("Characters", systemImage: "person.3")' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'Community characters unavailable right now.' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q '.frame(height: CharacterGallery.height)' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'TextField("Search characters"' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'await model.loadOpenPetsCatalog()' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'DisclosureGroup(isExpanded: \$petCharactersExpanded)' "$ROOT/Sources/Views.swift"
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
# updateRow replaced updateBanner in the panel (0.5.167): it renders the offer
# when there is one and the standing version when there is not, and carries the
# manual check either way.
for name in ("header", "updateRow", "activityLauncher", "statusCard", "controls"):
    if name not in panel:
        raise SystemExit(f"mainPanel lost {name}")
if panel.index("updateRow") > panel.index("activityLauncher"):
    raise SystemExit("the update row must be the first card in the panel")
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
/usr/bin/grep -q 'Sessions, and Tasks' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'Open Messages, Speakers, Meetings' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'case "tasks": try emitTasks' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "task-capture": try emitTaskCapture' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "task-schedule": try emitTaskSchedule' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "task-move": try emitTaskMove' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "task-run": try emitTaskRun' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'case "task-set-cap": try emitTaskSetCap' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'struct TaskRow' "$ROOT/Sources/Models.swift"
/usr/bin/grep -q 'func loadTasks' "$ROOT/Sources/ControllerModel.swift"

# The Tasks pane kept only today/carried/scheduled plus anything flagged, so a
# server holding 80 captured rows and nothing due reported "No open tasks" and
# read as broken. And the domain picker hardcoded one user's four business units,
# so a second install had nothing it could file against. Both are executable
# checks on the real files, not comment matches.
/usr/bin/python3 - "$ROOT" <<'PY'
import re, sys
root = sys.argv[1]
helper = open(f"{root}/HelperSources/main.swift", encoding="utf-8").read()
activity = open(f"{root}/Sources/ActivityWindow.swift", encoding="utf-8").read()
model = open(f"{root}/Sources/ControllerModel.swift", encoding="utf-8").read()
models = open(f"{root}/Sources/Models.swift", encoding="utf-8").read()

def need(cond, msg):
    if not cond: raise SystemExit(f"tasks/domains contract: {msg}")

# 1. The filter must not be a due-only whitelist any more.
body = helper[helper.index("static func filterTaskRows"):]
body = body[:body.index("\n    private func emitTasks")]
need('if column != "done" { kept.append(row) }' in body,
     "filterTaskRows no longer keeps every open row")
need('column == "today" || column == "carried" || column == "scheduled"' not in body,
     "filterTaskRows still whitelists only due columns")
# The 30-row limit only keeps the right rows if it is ranked.
need("func rank(" in body and "a.offset < b.offset" in body,
     "filterTaskRows lost its stable urgency ranking")

# 2. The picker reads the server's list; no hardcoded business units anywhere.
need("ForEach(model.domainOptions)" in activity, "the domain picker is not server-driven")
for name in ('Text("Quilt").tag', 'Text("Hermit Crabs").tag', 'Text("Sprocket Rocket").tag'):
    need(name not in activity, f"the picker still hardcodes {name}")
need('let known = ["quilt", "sprocket_rocket", "hermit_crabs", "personal"]' not in model,
     "librarySearchDomainOptions still hardcodes four domains")
need("struct DomainOption" in models, "DomainOption is gone")
need('case "domains": try emitDomains' in helper, "the helper has no domains command")

# 3. A Picker whose selection is not among its tags renders BLANK, and the
#    default is the literal "quilt". The reconcile must run wherever domains load.
need("private func reconcileTaskDomain()" in activity, "reconcileTaskDomain is gone")
need(len(re.findall(r"reconcileTaskDomain\(\)", activity)) >= 4,
     "reconcileTaskDomain is not called on every domain-load path")
need("func loadDomains" in model, "loadDomains is gone")
# Fails soft on purpose: an older server has no /api/domains, and emptying the
# picker would remove the only way to file a task.
soft = model[model.index("func loadDomains"):]
soft = soft[:soft.index("\n    }")]
need("if !parsed.isEmpty" in soft, "loadDomains would empty the picker on an older server")
# An EMPTY picker is worse than a hardcoded one: it removes the only way to file
# a task. /api/domains landed in 6.44.2, so every older server takes this path.
need("derivedDomainOptions()" in soft, "loadDomains has no fallback for a server without /api/domains")
derived = model[model.index("func derivedDomainOptions"):]
derived = derived[:derived.index("\n    /// Same derivation")]
need("tasks.map(\\.domain)" in derived, "the fallback does not derive from the board's own rows")
need('["personal", "business"]' in derived, "the fallback has no last-resort defaults")
for baked in ("quilt", "hermit_crabs", "sprocket_rocket"):
    need(baked not in derived, f"the fallback bakes in {baked}")
# The 404 text must name the route's OWN requirement: a blanket 6.44.0 told a
# user already on 6.44.1 to update to a version they had.
need('path.hasPrefix("/api/domains") ? "6.44.2"' in helper,
     "the 404 message does not name the per-route version")

# 0.5.188: the row opens a detail, and domains have a place to be set.
views = open(f"{root}/Sources/Views.swift", encoding="utf-8").read()
need("openTaskDetail(task)" in activity, "the task row does not open a detail")
need("private func taskDetailSheet" in activity, "the task detail sheet is gone")
# The row rendered `title`, which the server caps at 44 for a G2 lens row.
need("task.text.isEmpty ? task.title : task.text" in activity,
     "the row still renders the lens-capped title instead of the full text")
detail = activity[activity.index("private func taskDetailSheet"):]
detail = detail[:detail.index("\n    private func detailLine")]
for action in ("setTaskText", "setTaskChecked", "moveTask", "scheduleTask", "runTask"):
    need(f"model.{action}(" in detail, f"the detail view cannot {action}")
need('Text(task.checked ? "Reopen" : "Done")' in detail or 'task.checked ? "Reopen" : "Done"' in detail,
     "the detail view has no Done/Reopen")
# A running agent owns the line; Run now must not offer to race it.
need('task.agentState == "running"' in detail, "Run now is offered while an agent is already running")
# Its own route flag, written only by the opener, so a board refresh cannot
# dismiss the sheet under the user.
need(len(re.findall(r"taskDetail = ", activity)) == 2,
     "taskDetail is written from somewhere other than open/close")

need("private var domainsCard" in views, "there is no Domains settings card")
need("model.saveDomains(" in views, "the Domains card cannot save")
need("func saveDomains" in model, "saveDomains is gone from the model")
need('case "set-domains"' in helper, "the helper cannot set domains")
need('case "task-set-text"' in helper, "the helper cannot edit task text")
# Removing a name must not read as deleting the folder's tasks.
need("Removing a name only unlists it" in views,
     "the Domains card does not say what removing a name does")

# 0.5.189: the three-stage board reaches Control.
models = open(f"{root}/Sources/Models.swift", encoding="utf-8").read()
need('stage = (rawStage == "active" || rawStage == "review") ? rawStage : "planning"' in models,
     "TaskRow does not default an unknown stage to planning")
need('doneWhen = o["doneWhen"]?.string ?? ""' in models, "TaskRow does not decode doneWhen")

need('case "task-set-stage"' in helper, "the helper cannot set a stage")
need('case "task-set-done-when"' in helper, "the helper cannot set a finish line")
need('case "task-check"' in helper and 'jsonObject(["domain": domain, "checked": checked])' in helper,
     "Done/Reopen must send task-check instead of unknown command")
# planning|active|review and nothing else reaches the server.
need('["planning", "active", "review"].contains(stage)' in helper,
     "the helper does not validate the stage value")

need("func setTaskStage" in model, "setTaskStage is gone from the model")
need("func setTaskDoneWhen" in model, "setTaskDoneWhen is gone from the model")

# Run now is gated on the finish line, because the server refuses that dispatch
# with 409 done_when_required and a button that only fails is worse than none.
need('task.agentState == "running" || task.doneWhen.isEmpty' in detail,
     "Run now is offered on a task with no finish line")
# Setting the finish line must NOT close the sheet: it unblocks the very button
# it enables, and closing would hide the result of the action.
need("}, closeOnSuccess: false)" in detail,
     "setting the finish line closes the sheet it just unblocked")
need('ForEach(["planning", "active", "review"]' in detail, "the detail view has no stage moves")

# 0.5.212: Run at is not a board-level orphan. Capture files to inbox.
# Schedule owns the timestamp. Every row can Done without opening the overlay.
need('Text("Run at")' not in activity, "Run at is still a board-level orphan")
capture_fn = activity[activity.index("private func captureTask"):]
capture_fn = capture_fn[:capture_fn.index("\n    private func scheduleTask")]
need("runAt" not in capture_fn, "capture still stamps every new task with a run-at")
need("try await model.captureTask(domain: taskDomain, text: text)" in capture_fn,
     "capture no longer posts the text")
row = activity[activity.index("private func taskRow"):]
row = row[:row.index("\n    /// Keeps `taskDomain`")]
need('task.checked ? "Reopen" : "Done"' in row, "the row has no Done/Reopen CTA")
need("await checkTask(task)" in row, "the row Done CTA does not complete the task")
need(".popover(" in row, "Schedule on the row has no timestamp picker")
need("private func taskSchedulePopover" in activity, "the Schedule popover is gone")
need('Text("Schedule for")' in detail, "the overlay Schedule action has no timestamp")
need("DatePicker" in detail, "the overlay lost its schedule DatePicker")
overlay = activity[activity.index("// Inline overlay"):]
overlay = overlay[:overlay.index("private var tasksStatus")]
need(".shadow(" not in overlay, "the task overlay still has a drop shadow")
need("COSPalette.card" in overlay and "COSPalette.line" in overlay,
     "the task overlay is not the board's card/hairline")
print("Stage, finish line, and the run gate are wired")
print("Task detail and Domains settings are wired")
print("Tasks pane keeps every open row; domain picker is server-resolved")
print("Task rows carry Schedule, Run now, and Done; overlay has no drop shadow")
PY
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
/usr/bin/grep -A1 'scope == .thisMeeting$' "$ROOT/Sources/ControllerModel.swift" | /usr/bin/grep 'meeting-relabel' >/dev/null
# And confirming must route the same way, or the preview would describe one thing
# and the save would do another.
/usr/bin/grep -A2 'correction.scope == .thisMeeting {' "$ROOT/Sources/ControllerModel.swift" | /usr/bin/grep 'meeting-relabel' >/dev/null

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
/usr/bin/grep -A4 'func canPlay' "$ROOT/Sources/ControllerModel.swift" | /usr/bin/grep 'retainedAudioChunks.contains' >/dev/null
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
/usr/bin/grep -A12 'func closeSpeakerReview' "$ROOT/Sources/ControllerModel.swift" | /usr/bin/grep 'stopPlayback()' >/dev/null
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

dispatch = helper[helper.index("private func emitClaudeSessions"):]
dispatch = dispatch[:dispatch.index("\n    private func emitLiveClaudeSessions")]
assert "emitQuickClaudeSessions" in dispatch
assert "emitLiveClaudeSessions" in dispatch
assert '"--quick"' in dispatch
assert '"--fresh"' in dispatch

fresh = helper[helper.index("private func emitFreshClaudeSessions"):]
fresh = fresh[:fresh.index("\n    private func saveSessionListCache")]
assert '"/api/agent-sessions?limit=80"' in fresh, \
    "the list must come from the server, not a second local scanner"
assert "if serverRows.isEmpty {" in fresh, "local scan must be gated on the server failing"
assert fresh.index("serverRows = raw.compactMap") < fresh.index("collectAgentSessionIndex"), \
    "the server must be consulted BEFORE the local index"
assert "recentClaudeConversations(" not in fresh, \
    "full-list fallback must not open transcript bodies"

assert "session-list-cache.json" in helper
assert "agentSessionIndexDropped" in helper
assert "readSessionListCache" in helper
assert "collectAgentSessionIndex" in helper
# Live pet must not wait for the 7-day /api/agent-sessions walk.
live = helper[helper.index("private func emitLiveClaudeSessions"):]
live = live[:live.index("\n    private func emitQuickClaudeSessions")]
assert "/api/agent-sessions?limit=80" not in live, \
    "session-pet-live must not wait for the 7-day agent-sessions walk"
assert "readSessionListCache" in live

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
# 0.5.232: the literal is built as `var out = [...]`, then the eight server-state keys
# are merged in and `out` returned; the pinned shape is the literal itself.
ret = proj[proj.index("var out: [String: Any] = ["): proj.index("out.merge(serverStateProjection(row))")]
assert '"pinned"' in ret
assert "dropped" not in ret, "dropped leaked into the 12-key row projection"

drop = helper[helper.index("static func agentSessionDroppedProjection"):]
drop = drop[:drop.index("\n    /// Live status")]
for key in ('"age"', '"limit"', '"oversized"'):
    assert key in drop, f"dropped projection missing {key}"

fn = helper[helper.index("private func emitFreshClaudeSessions"):]
fn = fn[:fn.index("\n    private func emitSessionList")]
assert "agentSessionDroppedProjection(body)" in fn
assert "dropped: dropped" in fn
emit = helper[helper.index("private func emitSessionList"):]
emit = emit[:emit.index("\n    private func saveSessionListCache")]
assert '"dropped": dropped' in emit

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
  "$ROOT/Sources/COSMarkdownParser.swift" "$ROOT/Sources/COSMarkdown.swift" \
  "$ROOT/Sources/SessionLiveFeed.swift" \
  "$ROOT/Sources/SessionPet.swift" \
  "$ROOT/Sources/COSControlApp.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement \
  -o "$TMP/COS Control"

/usr/bin/vtool -show-build "$TMP/cos-control-helper" | /usr/bin/grep 'minos 14.0' >/dev/null
/usr/bin/vtool -show-build "$TMP/COS Control" | /usr/bin/grep 'minos 14.0' >/dev/null

# Bundled still characters share the importer contract: exact canvas, real alpha,
# and one state map. This catches the painted-checkerboard and cross-pose sizing
# regressions before a release can package them.
for bundled_id in jedi-nia-solari jedi-elara-vale jedi-rowan-vale; do
  bundled_png="$ROOT/Resources/BundledCharacters/$bundled_id/session-pet-idle.png"
  bundled_meta="$(/usr/bin/sips -g pixelWidth -g pixelHeight -g hasAlpha "$bundled_png")"
  /usr/bin/grep -q 'pixelWidth: 960' <<<"$bundled_meta"
  /usr/bin/grep -q 'pixelHeight: 900' <<<"$bundled_meta"
  /usr/bin/grep -q 'hasAlpha: yes' <<<"$bundled_meta"
done
/usr/bin/python3 "$ROOT/Tests/pet-layout-source-contract.py" "$ROOT"
/usr/bin/python3 "$ROOT/Tests/pet-settings-source-contract.py" "$ROOT"
/usr/bin/python3 "$ROOT/Tests/pet-animation-source-contract.py" "$ROOT"

# --- Every route a click can enter must actually render -----------------------
# The 0.5.17 Review Memories / Review Threads buttons did NOTHING when clicked. The
# opener set `contextBrowseKind`, but the pane was mounted inside
# `if model.reviewRouteActive` — a flag only the speaker flow ever sets — so state
# changed and no view was watching. It compiled, the helper worked, and 110 self-test
# assertions passed, because nothing tied the OPENER to the RENDER CONDITION.
/usr/bin/python3 - "$ROOT" <<'ROUTECHK'
import hashlib, json, pathlib, re, subprocess, sys
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
# 0.5.190: Memories mounts a four-view pane whose All memories segment is the
# 0.5.189 list unchanged, and the picker's default stays .allMemories (the flip
# is 0.5.191). Both the mapping and the initializer are pinned.
need('case .memories: memoriesSurface()' in activity, "Memories is not mounted on the reviewed surface")
need('case .allMemories: contextList(kind: "memory")' in activity, "All memories no longer renders the memory list")
need('@State private var memoriesSubview: MemoriesSubview = .allMemories' in activity,
     "the Memories picker must default to .allMemories in 0.5.190")
need('case .threads: contextList(kind: "thread")' in activity, "Threads is not mounted")
need('case .sessions: sessionsList' in activity, "Sessions is not mounted")
need('case .tasks: tasksList' in activity, "Tasks is not mounted")
need('case sessions' in activity, "Sessions is not an ActivitySection")
need('case tasks' in activity, "Tasks is not an ActivitySection")
need('case .tasks: "checklist"' in activity, "Tasks chip does not use checklist")
section_enum = re.search(r"enum ActivitySection: String, CaseIterable, Identifiable \{(.*?)\n    var id:", activity, re.S)
need(section_enum is not None, "ActivitySection enum block not found")
section_cases = re.findall(r"^\s+case \w+", section_enum.group(1), re.M)
need(len(section_cases) <= 9, f"ActivitySection has {len(section_cases)} cases; keyboard shortcuts only cover 1-9")
need(len(section_cases) == 7, f"ActivitySection should have 7 panes, found {section_cases}")
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
need('active >= 4' in (root / "Sources/Models.swift").read_text(),
     "four or more sessions IN PLAY must play the swarm pose")
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
need('let show = model.petEnabled\n' in pet_src,
     "an enabled pet must stay visible and resolve to idle when there are zero sessions")
need('model.petEnabled && !sessions.isEmpty' not in pet_src,
     "the zero-session hide guard returned; enabled pets must remain visible")
need('viewportSize: CGSize' in pet_src and
     '.frame(width: viewportSize.width, height: viewportSize.height, alignment: .bottom)' in pet_src,
     "the current pose is not mounted inside one stable collapsed viewport")
need(pet_src.count('petSpriteKit.viewportSize(') >= 2 and
     'petSpriteKit.fittedViewportScale(' in pet_src,
     "the presenter sizes or fits against only the current lifecycle pose")
# 0.5.142: the reserved-slot rule lives in the LEDGER now — a fixed-height
# slot the pills cross-fade into, so hover never resizes anything above the
# sprite. The idleBubble/petButtonPlaceholder chrome it replaced must be gone.
need('private var ledgerSlot' in pet_src and 'idleBubble' not in pet_src
     and 'petButtonPlaceholder' not in pet_src,
     "the ledger slot must replace the pre-0.5.142 idle chrome outright")
ledger_slot_src = pet_src[pet_src.index('private var ledgerSlot'):pet_src.index('private func ledgerBar')]
need('.frame(height:' in ledger_slot_src and 'maxHeight' not in ledger_slot_src,
     "the ledger slot must be FIXED height — hover must never resize above the sprite")
# Body only: toggleSessionMenu sits between handleSpriteClick and
# handleSpriteDrop as of 0.5.130 and legitimately names petExpanded.
handle_sprite = pet_src.split('private func handleSpriteClick()', 1)[1].split('\n    }', 1)[0]
need('petExpanded' not in handle_sprite,
     "a SINGLE click on the character must open its focus, never expand the session list")
_exp_owners = set()
for _m in re.finditer(r"model\.petExpanded(?:\.toggle\(\)|\s*=\s*true)", pet_src):
    _fn = None
    for _f in re.finditer(r"private (?:func|var) (\w+)", pet_src[:_m.start()]):
        _fn = _f.group(1)
    _exp_owners.add(_fn)
need(_exp_owners == {"pillsRow", "toggleSessionMenu"},
     f"the session list can be expanded from {sorted(_exp_owners)}; only the "
     "pills and the double-click handler may expand it")
need('.onTapGesture(count: 2) { toggleSessionMenu() }' in pet_src,
     "the double-click route into the session list is gone")
need('scale: characterScale' in pet_src and 'characterScale: characterScale' in pet_src,
     "the fitted character dial must size BOTH the stable panel envelope and the sprite frame")
need('characterScale: characterScale' in pet_src,
     "the sprite view never receives the character dial")
need('Character size' in views, "Settings has no character-size control")
need('Character speed' in views and 'petAnimationSpeedPercent' in views,
     "Settings has no independent character-speed control")
motion_for_speed = (root / "Sources/COSMotion.swift").read_text()
need('enum PetAnimationSpeed' in models_src and
     'petAnimationSpeedPercentKey' in model and
     'PetAnimationSpeed.loadPersistedPercent(' in model,
     "the character-speed preference is not modeled and persisted")
need('animationSpeed: model.petAnimationSpeedFactor' in pet_src,
     "the saved character speed never reaches the live sprite")
need('resolvedAnimationSpeed' in motion_for_speed and
     'timeIntervalSinceReferenceDate * resolvedAnimationSpeed' in motion_for_speed and
     'authored / resolvedAnimationSpeed' in motion_for_speed,
     "character speed must scale the full animation clock and timeline cadence")
need('petCharacterScaleGenerationKey' in model and
     'PetCharacterScale.loadPersistedPercent(' in model,
     "the doubled character range does not migrate an existing saved preference")
character_initializer = model.split('@Published var petCharacterPercent', 1)[1].split('\n', 1)[0]
need('ControllerModel.loadPetCharacterPercent()' in character_initializer,
     "the published character dial bypasses the one-time migration loader")
need('enum PetPlaylist' in models_src and 'usesActivityPlaylist' in models_src,
     "patrol no longer uses its calm ambient playlist")
cosmotion_src = (root / "Sources/COSMotion.swift").read_text()
sessionpet_src = (root / "Sources/SessionPet.swift").read_text()
need('PetPlaylist.plan(' in cosmotion_src and 'restClips' in cosmotion_src,
     "the sprite view does not run the activity playlist")
need('restClips: model.petRestClips(for: pose)' in sessionpet_src,
     "the playlist has no rest clips to settle into")
need('func petRestClips(' in model,
     "the activity playlist has no settled clips")
rest_body = model.split('func petRestClips(', 1)[1].split('func setPetCharacterPercent', 1)[0]
need('PetSpriteStore.restPoses(for: pose, stateMap: petStateMap)' in rest_body,
     "solo patrol lost its calm idle/meditation rests")
need('exactFrames(for:' in rest_body and 'case .working' not in rest_body and 'case .duel' not in rest_body,
     "authored story strips must not borrow fallback-resolved or higher-session art")
need('.done' not in rest_body and '.attention' not in rest_body,
     "success/attention draw the saber and must remain signal states, not ambient rests")
need('func restClip(' in models_src,
     "settled beats no longer rotate across rest clips")
sprite_struct = cosmotion_src.split('struct SessionPetSprite', 1)[1]
sprite_body = sprite_struct.split('var body: some View', 1)[1].split('private var measuredAspect', 1)[0]
need('let dissolves' not in sprite_body and '.opacity(' not in sprite_body,
     "combat playback cross-dissolves adjacent animation frames into ghost scenes")
need(models_src.count('normalizeStrip(') >= 2,
     "strip frames are normalised individually again, so the character resizes mid-animation")
sprite_height_body = models_src.split('func spriteHeight(', 1)[1].split('func spriteWidth(', 1)[0]
need('cinematic ?' not in sprite_height_body,
     "multi-session poses regained the 1.55x height multiplier")
need('func viewportSize(' in models_src and 'func fittedViewportScale(' in models_src,
     "the shared lifecycle viewport contract is gone")
need('visualScale' not in models_src and '.scaleEffect(pose.visualScale' not in cosmotion_src,
     "a global duel transform can crop or resize arbitrary character packs")
need('private var timelineInterval' in cosmotion_src and
     'usableRestClips.map(\.frameInterval)' in cosmotion_src,
     "ambient secondary clips are not scheduled at their authored cadence")
apply_pet_body = model.split('private func applyPetSessions(', 1)[1].split('private func beginPetCompletion', 1)[0]
need('petExpanded = true' not in apply_pet_body and 'previousCount < 2' not in apply_pet_body,
     "session-count transitions must not open the list without a dropdown click")
# 0.5.150: the RUNNING pill legitimately opens a ONE-row list, so the poll
# closes it only when it is truly empty (the <2 threshold shut it under the
# cursor within one 20s poll).
need('if petSessions.isEmpty && petDismissals.stamps.isEmpty' in apply_pet_body
     and 'petSessions.count < 2' not in apply_pet_body,
     "the live list must auto-close only when nothing is left to show — the "
     "restore row must survive dropping the last session")
need('installBundledDefault(into: directory)' in model,
     "a fresh install no longer seeds the shipped character")
need('petDefaultSeededKey' in model,
     "default seeding is not gated by a flag, so Use COS figure would be undone on relaunch")
need('petDefaultArtGenerationKey' in model and 'refreshRecognizedBundledDefault' in model,
     "existing Miles installs will not receive the new authored story assets")
need('Jedi Miles Windu' in models_src, "the shipped character lost its name")
need('static let bundledCharacters' in models_src,
     "shipped characters fell back to a one-off default instead of a selectable catalog")
need('id: "jedi-miles-windu"' in models_src,
     "Miles Windu is no longer registered as a bundled character")
bundled_ids = ["jedi-nia-solari", "jedi-elara-vale", "jedi-rowan-vale"]
# The list lives in Models.swift, on disk, and twice in this file. Pin disk
# against the registry so a fifth character cannot ship untested and a deleted
# folder cannot surface only at runtime as "This build does not carry X".
on_disk = {d.name for d in (root / "Resources/BundledCharacters").iterdir() if d.is_dir()}
need(on_disk == set(bundled_ids),
     f"BundledCharacters/ holds {sorted(on_disk)} but the suite tests {sorted(bundled_ids)}")
for bundled_id in sorted(on_disk):
    need(f'id: "{bundled_id}"' in models_src,
         f"{bundled_id} ships on disk but is not in the bundledCharacters registry")
for bundled_id in bundled_ids:
    need(f'id: "{bundled_id}"' in models_src,
         f"{bundled_id} is missing from the bundled-character registry")
    pack = root / "Resources/BundledCharacters" / bundled_id
    states = pack / "session-pet-states.json"
    art = pack / "session-pet-idle.png"
    need(states.is_file() and art.is_file(),
         f"{bundled_id} must ship both its state map and canonical sprite")
    poses = json.loads(states.read_text()).get("poses", {})
    need(set(poses) == {"idle", "patrol", "waiting", "working", "done", "error", "attention", "duel", "trio", "swarm"},
         f"{bundled_id} must map all ten deployable pet states")
    # 0.5.151 idle/combat retained; 0.5.154 adds three walks and Nia meditation.
    stories = {
        "jedi-nia-solari": {"idle": (8,348,.24), "working": (12,348,.14), "duel": (16,440,.14), "trio": (14,440,.14), "swarm": (19,440,.14)},
        "jedi-elara-vale": {"idle": (8,256,.24), "working": (16,358,.14), "duel": (16,544,.16), "trio": (16,544,.18), "swarm": (24,704,.18)},
        "jedi-rowan-vale": {"idle": (8,320,.24), "working": (12,340,.16), "duel": (12,372,.17), "trio": (18,372,.17), "swarm": (24,396,.16)},
    }[bundled_id]
    for pose, row in poses.items():
        if pose == "patrol" or (pose == "waiting" and bundled_id == "jedi-nia-solari"):
            expected_interval = .14 if pose == "patrol" else .24
            need(row == {"file": f"session-pet-{pose}-v3.png", "frames": 8,
                         "interval": expected_interval, "renderScale": 1},
                 f"{bundled_id}/{pose} must use its authored ambient strip")
            manifest = json.loads((pack / "approved-ambient-v3.json").read_text())
            record = next(r for r in manifest["scenes"] if r["role"] == pose)
            need(hashlib.sha256((pack / row["file"]).read_bytes()).hexdigest() == record["sha256"],
                 f"{bundled_id}/{pose} ambient pixels drifted from native canary")
        elif pose == "waiting":
            need(row == poses["idle"], f"{bundled_id}/waiting keeps the authored idle")
        elif pose in stories:
            expected_frames, _, expected_interval = stories[pose]
            expected_file = "session-pet-idle-v2.png" if pose == "idle" else f"session-pet-{pose}-story-v2.png"
            need(row.get("file") == expected_file and row.get("frames") == expected_frames
                 and abs(row.get("interval", 0) - expected_interval) < 0.000001,
                 f"{bundled_id}/{pose} must map to its complete story, got {row}")
            strip = pack / expected_file
            need(strip.is_file(), f"{bundled_id} declares {pose} but ships no {strip.name}")
        else:
            need(row.get("file") == "session-pet-idle.png" and row.get("frames") == 1,
                 f"{bundled_id}/{pose} is a still state and must map to the one canonical frame")
    # Geometry is asserted, not assumed. A correct frame count against the
    # wrong width still slices every pose mid-cell.
    for pose, (frames, cell_width, _) in sorted(stories.items()):
        strip = pack / ("session-pet-idle-v2.png" if pose == "idle" else f"session-pet-{pose}-story-v2.png")
        dims = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(strip)],
                              capture_output=True, text=True).stdout
        w = re.search(r"pixelWidth: (\d+)", dims)
        h = re.search(r"pixelHeight: (\d+)", dims)
        need(w is not None and h is not None, f"{bundled_id}/{pose}: sips could not read {strip.name}")
        need(int(w.group(1)) == frames * cell_width and int(h.group(1)) == 256,
             f"{bundled_id}/{pose} is {w.group(1)}x{h.group(1)}, must be "
             f"{frames * cell_width}x256 ({frames} {cell_width}px cells)")
        need(int(w.group(1)) % frames == 0,
             f"{bundled_id}/{pose} width does not divide into {frames} cells")
    if bundled_id == "jedi-elara-vale":
        approved_elara = {
            "session-pet-working-story-v1-1.png": "4ab1596d89d4e553ee837cb0f920e9aafc696deca49756796359e28cde190239",
            "session-pet-duel-story-v1-1.png": "2f0dff811b1d9ad2d6a3f09700c7c225860a9fe85de605766d3406a9bd8d4e48",
            "session-pet-trio-story-v1-1.png": "cb692d9eaf3287cc5ba357270c2c49b1851b3496a50699160b1791768924d28c",
            "session-pet-swarm-story-v1-1.png": "e0a24f9c8846c0afbccd56adbc674c0156f8aa961e39590e204ab14d488bd7be",
        }
        for file, expected_hash in approved_elara.items():
            actual_hash = hashlib.sha256((pack / file).read_bytes()).hexdigest()
            need(actual_hash == expected_hash,
                 f"Elara V1.1 corrected transparency drifted: {file}")

# Shipping new bundled art without advancing the generation constant means the
# refresh never fires, so anyone who ALREADY picked that character keeps the old
# assets forever. useBundledCharacter stamps the generation the moment a
# character is chosen, so those users are already at the current value.
gen = re.search(r"petDefaultArtGeneration = (\d+)", model)
need(gen is not None, "the art-generation constant is gone")
need(int(gen.group(1)) >= 17,
     "walking/meditation loops require art generation17 for existing users")
need("refreshRecognizedBundledCharacter(" in model,
     "launch must call the retained-stock Jedi migration")
retained_fn = models_src[models_src.index("static func refreshRecognizedBundledCharacter("):]
retained_fn = retained_fn[:retained_fn.index("\n    static func installDefault(")]
need("canonicalState(data) == installedState" in retained_fn and "installed == retained" in retained_fn,
     "Jedi migration must match complete metadata and retained image bytes")
need("character.id != defaultCharacterID" in retained_fn,
     "the Jedi migration must not target Miles")
need("removeAll(" not in retained_fn,
     "stock upgrade must not clear the active character before landing files")
need(retained_fn.index("try data.write") < retained_fn.index("try sourceState.write"),
     "replacement files must land before the active state map changes")
need("refreshStillBundledCharacter(" not in model and "refreshRecognizedBundledElaraV1(" not in model,
     "legacy destructive/partial refresh paths must not bypass strict recognition")
need("loadRenderScales" in models_src and "petRenderScales" in model,
     "pack-owned pose scale metadata is declared but never loaded")
need("frameInterval: model.petFrameInterval(for: pose)" in pet_src,
     "the session pet does not pass the selected character's authored cadence")
need("primaryFrameInterval" in cosmotion_src
     and "interval: primaryFrameInterval" in cosmotion_src,
     "authored cadence does not drive both the timeline and frame index")
need('func installBundledCharacter(' in models_src,
     "bundled characters cannot be selected through the sprite store")
# Scope to the gallery card's BODY: str.index finds the `private var`
# declaration first, so an ordering check against the whole file passed even
# after the row was moved below the attribution.
need('private var petGalleryCard' in views, "the pet gallery card is gone")
gallery_body = views.split('private var petGalleryCard')[1]
need('openpets.dev' in gallery_body, "the OpenPets attribution is gone")
need('ForEach(visibleBundledCharacters)' in gallery_body,
     "the bundled-character catalog is declared but never mounted in the gallery card")
need(gallery_body.index('ForEach(visibleBundledCharacters)') < gallery_body.index('openpets.dev'),
     "bundled characters must render ABOVE the OpenPets attribution, not inside that gallery")
need('PetSpriteStore.bundledCharacters.count + model.openPetsRows.count' in views,
     "the Characters count excludes bundled characters, so Miles never becomes character 301")
need('Label("Characters", systemImage: "person.3")' in views and
     'Text("\\(availableCharacterCount)")' in views,
     "the combined character count is not visible in the nested gallery label")
need('TextField("Search characters"' in views and 'visibleBundledCharacters' in views,
     "search does not cover the shipped character catalog")
need('@State private var petSettingsExpanded = false' in views and
     'DisclosureGroup(isExpanded: $petSettingsExpanded)' in views,
     "Session pet settings must default to one collapsed disclosure")
need('@State private var petStateSpritesExpanded = false' in views and
     'DisclosureGroup(isExpanded: $petStateSpritesExpanded)' in views,
     "the ten state-sprite rows must be nested instead of permanently expanding the panel")
need('@State private var petCharactersExpanded = false' in views and
     'DisclosureGroup(isExpanded: $petCharactersExpanded)' in views,
     "the 304-character gallery must be nested instead of permanently expanding the panel")
need('Text("ADVANCED")' in views and 'character.isAdvanced' in views,
     "advanced characters have no capability badge in the unified gallery")
need('Ships with COS Control' not in gallery_body,
     "bundled Jedi still render as a separate catalog instead of sharing the character grid")
grid_body = gallery_body.split('LazyVGrid(', 1)[1].split('\n                    }', 1)[0]
need('ForEach(visibleBundledCharacters)' in grid_body and
     'ForEach(visibleOpenPetsRows)' in grid_body,
     "bundled Jedi and OpenPets stills must render inside the same character grid")
need('pendingBundledCharacter = character' in views and 'confirmBundledCharacter = true' in views,
     "selecting a shipped character bypasses the destructive replacement confirmation")
need('model.useBundledCharacter(character)' in views,
     "the bundled-character confirmation has no install action")
need('DefaultPet' in (root / "scripts/build-release.sh").read_text(),
     "the release does not bundle the shipped character")
need('Resources/BundledCharacters' in (root / "scripts/build-release.sh").read_text(),
     "future registered characters are not copied into the release")
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
need(motion_src.count('pose.renderSize(') >= 2 and
     'static func resolvedAspect(frames:' in models_src and
     'aspect: resolvedAspect(for: pose)' in models_src and
     'PetSpriteKit.resolvedAspect(frames: frames)' in motion_src and
     'petSpriteKit.viewportSize(' in pet_src,
     "panel viewport and rendered sprite returned to unrelated size formulas")
need('spriteWidth(' not in motion_src and 'spriteWidth(' not in pet_src,
     "a view sizes off the fixed-aspect spriteWidth instead of the measured art")
need('model.petSpriteFrameCount(pose) > 1' not in views,
     "the frame-count stepper is hidden by the value it exists to raise")
need('COSPalette.plateInk' in (root / "Sources/SessionPet.swift").read_text(),
     "pet controls regressed to fixed ink: black-on-black in dark mode")
need('foregroundStyle(COSPalette.ink)' not in (root / "Sources/SessionPet.swift").read_text(),
     "a pet control paints fixed ink on the adaptive card: black-on-black in dark mode")
# 0.5.155 mission rows: the whole row IS the jump; the old trailing glyph is
# clutter the meta column replaced. The affordance is pinned as the row help
# plus the openSessionInPlatform call the ROUTECHK slice already asserts.
_pet_code = (root / "Sources/SessionPet.swift").read_text()
_pet_code = "\n".join(l.split("//")[0] if l.strip().startswith("//") else l
                      for l in _pet_code.splitlines())
# Direction D routes every row through petRowD, so the help string lives on
# the shared builder and each row proves only that it wires the jump.
for _row, _end in [("private func missionRow", "private func idleRow"),
                   ("private func idleRow", "private struct PetRowActions")]:
    _slice = _pet_code[_pet_code.index(_row):_pet_code.index(_end)]
    need("model.openSessionInPlatform(session)" in _slice and "petRowD(" in _slice,
         f"{_row.split()[-1]} lost its whole-row jump; a shared slice let one "
         "occurrence cover both rows")
_shared_row = _pet_code[_pet_code.index("private func petRowD"):
                        _pet_code.index("private func petRowSlot")]
need('.help("Open in platform")' in _shared_row,
     "the shared row builder lost the affordance naming what a click does")
# 0.5.147: the scope/target button and openTarget split are REMOVED with the
# hover bubble (Miles, on-device) — the pills, list rows, and the sprite click
# are the only openers. Keep the dead chrome out.
need('petButton("scope"' not in (root / "Sources/SessionPet.swift").read_text()
     and 'openTarget' not in (root / "Sources/SessionPet.swift").read_text(),
     "the removed target/scope chrome returned to the pet")
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
_chat_branch_src = model[model.index('if openMode == "chat"'):]
_chat_branch_src = _chat_branch_src[:_chat_branch_src.index('if openMode ==', 20)]
# The RULE is that the tab match keys on `name`, never on `title` (which falls
# back to the workspace). Pinning the exact expression broke on 2026-09-01 when
# an ambiguity check was added around it; the rule was intact throughout.
need('session.name' in _chat_branch_src and 'session.title' not in _chat_branch_src,
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
listed = pet.split("private var sessionList")[1].split("private var spriteHelp")[0]
need('model.openSessionInPlatform(session)' in listed,
     "a pet list row only changes focus and does not open the session")
need('.contentShape(Rectangle())' in listed,
     "the pet list row does not hit-test the empty card")
need('model.petFocusID = session.id' in listed,
     "opening a list row must still focus that session")
# 0.5.147: the focused-session bubble and action buttons are REMOVED on
# purpose (Miles, on-device) — the pills open whatever is active, so the card
# and a second set of openers were redundancy. Keep them out.
need("statusBubble" not in pet and "actionsRow" not in pet and "petButton(" not in pet,
     "the hover bubble/action chrome returned; the pills are the only openers")
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

# Enable-time Accessibility ask (0.5.136). The prompt used to live only inside
# the jump, so the first anyone heard of the permission was a click that had
# already failed. Queen hit exactly that with the grant visible in her settings.
/usr/bin/python3 - "$ROOT" <<'AXCHK'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
model = (root / "Sources/ControllerModel.swift").read_text()
views = (root / "Sources/Views.swift").read_text()
def need(c, m):
    if not c: sys.exit(f"pet-accessibility: {m}")

# Ask when the feature is switched on, not when a jump fails.
enable = model[model.index("func setPetEnabled("):]
enable = enable[:enable.index("\n    }")]
need("requestPetJumpAccessibility()" in enable,
     "turning the pet on must ask for Accessibility; otherwise the first signal "
     "a user gets is a failed jump")
need(enable.index("requestPetJumpAccessibility()") < enable.index("loadPetSessions()"),
     "ask before the first poll, while the user is still in Settings")

ask = model[model.index("func requestPetJumpAccessibility()"):]
ask = ask[:ask.index("\n    func setPetEnabled")]
need("AXTrustedCheckOptionPrompt" in ask, "the ask never raises the system prompt")
need("openAccessibilitySettings()" in ask, "the ask never opens the pane it is talking about")
# Positional: a bare substring check passed when the pre-prompt guard was
# deleted, because an identical guard exists AFTER the prompt.
need(ask.index("guard !petJumpTrusted else { return }") < ask.index("AXTrustedCheckOptionPrompt"),
     "an already-granted user must not be prompted again; the guard has to precede the prompt")
need(ask.count("guard !petJumpTrusted else { return }") == 2,
     "expected one guard before the prompt and one before opening the pane")
need("petNotice" not in ask,
     "enabling a feature is not a failure; the ask must not post an error notice")

# The state has to be visible without failing first, and must stop nagging.
need("model.petJumpTrusted" in views, "settings never shows whether the jump can work")
need("model.requestPetJumpAccessibility()" in views, "the Grant button is not wired")
need("didBecomeActiveNotification" in views and "refreshPetJumpTrust()" in views,
     "the grant happens in System Settings while the app is inactive; without a "
     "re-read on activation the warning would persist after it was granted")
need("Everything else about the pet works without it" in views,
     "the row must say the permission is scoped to the jump, so nobody grants it needlessly")
AXCHK

# Claude jump diagnostics (0.5.135). Four failures used to render one sentence,
# so Queen's report from her own Mac carried no information about which happened.
/usr/bin/python3 - "$ROOT" <<'JUMPCHK'
import re, sys, pathlib
model = (pathlib.Path(sys.argv[1]) / "Sources/ControllerModel.swift").read_text()
def need(c, m):
    if not c: sys.exit(f"claude-jump: {m}")

scan = model[model.index("struct ClaudeRowScan {"):model.index("private func codexThreadID")]
for field in ["nameTooShort", "windows", "rowsSeen", "deepestReached", "truncatedAtLimit", "pressRefused"]:
    need(field in scan, f"the scan lost its {field} discriminator")

notice = scan[scan.index("func notice(want:"):]
notice = notice[:notice.index("\n        }")]
# Every branch must name a DIFFERENT step, or the report is useless again.
need(notice.count("return ") >= 5,
     "notice() must distinguish at least five failure modes; it collapses them")
need("nameTooShort" in notice and "windows == 0" in notice
     and "pressRefused" in notice and "truncatedAtLimit" in notice,
     "notice() does not branch on every recorded discriminator")

# The depth cap must SET the flag, not return a bare false -- a truncated walk
# is otherwise indistinguishable from a genuine no-match.
walk = model[model.index("named want: String, from element: AXUIElement, depth: Int, scan: inout ClaudeRowScan"):]
walk = walk[:walk.index("private func codexThreadID")]
need("scan.truncatedAtLimit = true" in walk,
     "hitting the depth limit must record that it truncated")
need("if depth > scan.deepestReached" in walk, "the walk does not record how deep it got")
need("scan.rowsSeen += 1" in walk, "the walk does not count the rows it considered")

# And it must actually log, or a remote user has nothing to send back.
reveal = model[model.index("func revealClaudeSession("):model.index("private func enableClaudeSidebarAccess")]
# The recursive overload's signature wraps across two lines, so slice on the
# wrapped form rather than a one-line signature that does not exist.
press = model[model.index("private func pressClaudeSessionRow(named rawWant:"):]
press = press[:press.index("    private func pressClaudeSessionRow(\n")]
need(press.count("NSLog(") >= 3,
     "the jump path must log its discriminating values; it had zero NSLog calls before 0.5.135")
need("scan.notice(want:" in reveal, "the reveal path does not surface the scan's reason")
JUMPCHK

# Pet character switching (0.5.130). Installing a pack or a single sprite used
# to layer ON TOP of whatever was already installed, so every pose the incoming
# character did not declare stayed owned by the outgoing one -- and because the
# plain custom sprite is only the LAST-RESORT rung of PetSpriteKit.frames(for:),
# picking a legacy pet after an advanced pack was structurally unable to change
# anything on screen. Checks below read the exact call sites, not definitions.
/usr/bin/python3 - "$ROOT" <<'PETCHK'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
model = (root / "Sources/ControllerModel.swift").read_text()
models = (root / "Sources/Models.swift").read_text()
pet = (root / "Sources/SessionPet.swift").read_text()

def need(cond, msg):
    if not cond: sys.exit(f"pet-character: {msg}")

# -- whole-character single sprite clears first; a NAMED pose must not.
install = model[model.index("func installPetSprite(from url: URL"):
                model.index("func installPetSpritePack(")]
branches = install.split("} else {")
need(len(branches) == 2, "installPetSprite no longer has the pose/no-pose split")
need("PetSpriteStore.removeAll(" not in branches[0],
     "a single-pose override must NOT wipe the rest of the installed character")
need("PetSpriteStore.removeAll(from: directory)" in branches[1],
     "adopting a whole new sprite must clear the previous character's poses first")
need(branches[1].index("PetSpriteStore.removeAll(from: directory)")
     < branches[1].index("PetSpriteStore.install(from: url"),
     "the clear has to happen BEFORE the new sprite is written")

# -- pack install stages, then swaps whole. Nothing may write into the live
#    support directory while the pack is being assembled.
pack = model[model.index("func installPetSpritePack("):
             model.index("func setPetSpriteFrames(")]
need(pack.count("into: staging") == 2,
     "both the grid and the pose install must target the staging folder")
need("into: directory" not in pack,
     "a pack must never install straight into the live support directory")
need("PetSpriteStore.replaceContents(of: directory, with: staging)" in pack,
     "the staged pack is never swapped in")
need(pack.index("try PetSpriteStore.replaceContents") > pack.rindex("into: staging"),
     "the swap must come after every item is staged")

# -- the swap clears. Dropping this line lets a stale cinematic.png outlive the
#    pack that wrote it, and frames(for:) prefers the cinematic over a
#    single-frame trio/swarm, so the OLD character keeps fighting.
swap = models[models.index("static func replaceContents("):]
swap = swap[:swap.index("\n    private static func saveStateMap")]
# The swap must never leave the user with NEITHER character. Clearing first and
# then throwing mid-copy (disk full, sandbox denial) left a half-erased folder
# whose state map could reference PNGs that never arrived.
need("removeAll(from: directory" not in swap,
     "replaceContents must not delete the outgoing character outright; hold it aside so a "
     "failed copy can be rolled back")
need("moveItem(at: file, to: saved)" in swap and "held.append" in swap,
     "the outgoing character is not held aside before the copy")
need("catch {" in swap and "moveItem(at: row.saved, to: row.live)" in swap,
     "a failed copy must restore the character that was held aside")
need(swap.index("held.append") < swap.index("for file in staged"),
     "the outgoing files must be held aside before the staged copy begins")
need("guard !staged.isEmpty" in swap,
     "an empty staging folder must not be allowed to erase the installed character")

# The single-sprite path must validate the SOURCE before it clears anything.
need("try PetSpriteStore.assertInstallable(url)" in branches[1],
     "adopting a new sprite must validate the file before wiping the old character")
need(branches[1].index("assertInstallable") < branches[1].index("PetSpriteStore.removeAll"),
     "validation has to run BEFORE the clear, or a rejected file costs the user their pet")

# -- every fallback chain terminates somewhere a MINIMAL pack declares. error
#    and attention pointed only at each other, so a legacy pack carrying
#    neither rendered nothing at all for both once leftovers stopped covering.
chain = models[models.index("var fallbackPoses: [PetSpritePose] {"):]
chain = chain[:chain.index("\n    }")]
# Drive this off the SOURCE, not a hand-written list. The previous version
# enumerated only the rows that already passed, so duel/trio/swarm -- the three
# that actually cycled among themselves -- were never checked. A full revert of
# the .swarm arm passed it.
rows = re.findall(r"case ((?:\.\w+(?:, )?)+): \[(.*?)\]", chain)
need(len(rows) >= 7, f"fallbackPoses parsed only {len(rows)} rows; the regex lost the switch")
for poses_txt, targets in rows:
    if not targets.strip():
        continue
    need(".idle" in targets or ".done" in targets,
         f"fallbackPoses `case {poses_txt}` -> [{targets}] never terminates at a pose a "
         "minimal pack declares, so it can resolve to nothing")

# -- idle rows can be dropped from the pet list without touching the session.
need("func dismissPetSession(" in model and "func canDismissPetSession(" in model,
     "the pet list has no drop control")
dismiss = model[model.index("func dismissPetSession("):model.index("func restorePetDismissals(")]
need("guard canDismissPetSession(session) else { return }" in dismiss,
     "a running session must not be droppable")
need("applyPetSessions(petSessionsRaw)" in dismiss,
     "re-applying from the FILTERED list prunes the dismissal and hands the row back")
apply = model[model.index("private func applyPetSessions("):model.index("/// Offered only once")]
need(apply.index("petDismissals.prune(against: sessions)") < apply.index("petDismissals.filter(sessions)"),
     "prune must run against the unfiltered list, before the filter")
# Assert the CALL SET, not the absence of three words. Inserting
# closeClaudeSession(session) into this body passed the old substring check.
# "dismissPetSession" is the declaration itself, not a call.
calls = set(re.findall(r"\b(\w+)\(", dismiss)) - {"guard", "if", "return", "dismissPetSession"}
need(calls <= {"canDismissPetSession", "dismiss", "savePetDismissals", "applyPetSessions"},
     f"dropping a row must only touch list state; it also calls {sorted(calls)}")

# -- the X is a SIBLING of the row button. Nested inside, it never gets clicked.
rows = pet[pet.index("private var sessionList:"):pet.index("private var spriteHelp")]
need("model.canDismissPetSession(session)" in rows, "the drop control is not gated on idle time")
need("HStack(spacing: 0)" in rows and "model.petFocusID = session.id" in rows,
     "the session row lost either its wrapper or its open action")
# The drop control must appear AFTER the row button has been closed and
# styled. Merely being later than the opener is satisfied by nesting it inside
# the label, which is the bug this guards (a Button inside another Button's
# label never receives the click on macOS).
need(rows.index("model.canDismissPetSession(session)") > rows.index('.buttonStyle(.plain)'),
     "the drop control must sit beside the row button, not inside its label")

# -- double-click the figure opens the session list; the chevron was the only way in.
need(".onTapGesture(count: 2) { toggleSessionMenu() }" in pet, "no double-click handler on the pet")
need(pet.index(".onTapGesture(count: 2)") < pet.index(".onTapGesture { handleSpriteClick() }"),
     "the double-click must be declared first or the single tap wins the race")
menu = pet[pet.index("private func toggleSessionMenu()"):]
menu = menu[:menu.index("\n    }") + 6]
# Same rule, same correction as the pet-layout contract: "inert when there is
# nothing to show" was spelled as a session COUNT, which was also inert at
# exactly one running session and silently killed the gesture (2026-09-01).
need("sessions.count > 1" not in menu and "isEmpty" in menu,
     "double-click must be inert when there is no list to show")
PETCHK

# Completion signal + terminal jump (0.5.141). Source-shape guards IN ADDITION
# to the executable ModelsContract suites, never instead of them.
/usr/bin/python3 - "$ROOT" <<'SIGCHK'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
model = (root / "Sources/ControllerModel.swift").read_text()
pet = (root / "Sources/SessionPet.swift").read_text()
def need(c, m):
    if not c: sys.exit(f"completion-signal: {m}")

# The fleet boolean is DEAD. wasWorking && !isWorking could not say WHICH of N
# sessions finished, which is defect D1 this release exists to fix.
apply_body = model[model.index("private func applyPetSessions("):]
apply_body = apply_body[:apply_body.index("\n    private func mergeCompletions")]
need("wasWorking" not in apply_body and "isWorking =" not in apply_body,
     "the fleet wasWorking/isWorking boolean is back; per-id detection is D1")
need("PetCompletionDetector.diff" in apply_body,
     "applyPetSessions no longer runs the per-id detector")
need(apply_body.count("lastAuthoritativeRaw = sessions") == 1,
     "the diff baseline must advance exactly once, inside the authoritative arm")
need("petNotice" not in apply_body, "completions never assign petNotice")

for fn in ["dismissPetSession", "restorePetDismissals"]:
    body = model[model.index(f"func {fn}(")-1:]
    body = body[:body.index("\n    }")]
    need("PetCompletionDetector" not in body,
         f"{fn} must replay without diffing — a dismissal is not a finish")

# Call sites only — the definition line also contains the substring.
calls = len(re.findall(r"^\s+beginPetCompletion\(\)\s*$", model, re.M))
need(calls == 1, f"beginPetCompletion has {calls} call sites; only the authoritative merge may fire it")
need("loadPetCompletions()" in model[model.index("loadPetDismissals()"):
                                     model.index("loadPetSprite()")],
     "persisted chips are not loaded at init")
for fn in ["setPetEnabled", "resetPetSprite"]:
    body = model[model.index(f"func {fn}("):]
    body = body[:body.index("\n    }")]
    need("lastAuthoritativeRaw = nil" in body,
         f"{fn} must drop the diff baseline or the next enable diffs a stale snapshot")

# The load-time scrub lives in ControllerModel (not constructible from
# ModelsContract), so pin its two guards by shape.
load = model[model.index("func loadPetCompletions("):]
load = load[:load.index("\n    }")]
need('$0.id == "claude:a"' in load, "the leaked live fixture must be scrubbed on load")
need("PetCompletionDetector.maxAge" in load and "PetCompletionDetector.ringCap" in load,
     "load must age out and cap through the detector's own constants")

merge = model[model.index("private func mergeCompletions("):]
merge = merge[:merge.index("\n    }")]
need("petNotice" not in merge, "mergeCompletions must not assign petNotice")

# Pills (0.5.142) replaced the chip; the mutual-exclusion invariant carries
# over control-for-control: DONE touches only the finished list, RUNNING
# clears the finished list when it opens the live one.
need("petCompletionsExpanded" in pet, "nothing toggles the finished list")
# Comment-stripped: a mutant that deleted the WAITING routing and left the
# symbol names in a comment satisfied these pins (QA, 2026-08-31).
pet_code = "\n".join(
    (l.split("//")[0] if "//" in l and l.count('"') % 2 == 0 else l)
    for l in pet.splitlines()
)
pills = pet_code[pet_code.index("private func pillsRow("):pet_code.index("private func ledgerPill(")]
run_pill = pills[pills.index('label: "RUNNING"'):pills.index('label: "DONE"')]
need("petExpanded.toggle" in run_pill and "petCompletionsExpanded = false" in run_pill,
     "the RUNNING pill must toggle the live list and clear the finished one")
wait_pill = pills[pills.index('label: "WAITING"'):]
need("ClaudeSession.petWaitingJumpTarget(" in wait_pill,
     "the WAITING pill must route through the executable jump-target helper")
need("model.petExpanded = true" in wait_pill,
     "several waiting sessions must open the list, never jump to an arbitrary one")
need(wait_pill.index("ClaudeSession.petWaitingJumpTarget(") < wait_pill.index("model.petExpanded = true"),
     "the WAITING pill must consult the jump target BEFORE falling back to the list")
need('sessions.first(where: { $0.state == "waiting" })' not in wait_pill,
     "the arbitrary-jump path returned to the WAITING pill")
done_pill = pills[pills.index('label: "DONE"'):pills.index('label: "WAITING"')]
need("petCompletionsExpanded.toggle" in done_pill and "petExpanded.toggle" not in done_pill,
     "the DONE pill must not toggle the LIVE list")
comp = pet[pet.index("private var completionsList"):]
comp = comp[:comp.index("private var spriteHelp")]
need("ScrollView" in comp and ".frame(height:" in comp and "maxHeight" not in comp,
     "the finished list must use a FIXED scroll frame — maxHeight collapses under "
     "the panel's sizeThatFits and rendered six chips as an empty white capsule")
need("petCompletions.count > 3" in comp,
     "small chip counts render flat, like sessionList's >5 rule")
mon = pet[pet.index("private func syncOutsideClickMonitor"):]
mon = mon[:mon.index("\n    }")]
need("petCompletionsExpanded = false" in mon,
     "outside click must clear the finished list too")
sync = pet[pet.index("func syncLists()"):pet.index("func syncLists()") + 300]
need("petExpanded" in sync and "petCompletionsExpanded" in sync
     and "syncOutsideClickMonitor(" in sync,
     "the monitor must key on BOTH lists or the chip tears it down")
SIGCHK

# Panel radius scale (0.5.150): cards 12, tiles 8, small controls 5, plus
# micro radii 1/2/3 on few-pixel geometry. Eight accumulated values were the
# fingerprint of features added one at a time — keep the scale closed.
/usr/bin/python3 - "$ROOT" <<'RADCHK'
import re, sys, pathlib
views = (pathlib.Path(sys.argv[1]) / "Sources/Views.swift").read_text()
found = set(int(n) for n in re.findall(r"cornerRadius: (\d+)\b", views))
allowed = {1, 2, 3, 5, 8, 12}
if not found <= allowed:
    sys.exit(f"panel-radius: off-scale corner radii {sorted(found - allowed)} in Views.swift — the 12/8/5 scale is closed")
RADCHK

# Ledger hover motion (0.5.142). The vocabulary is EXECUTED by
# ModelsContract.checkPetLedger; these pin the motion wiring it cannot see.
/usr/bin/python3 - "$ROOT" <<'LEDGCHK'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
model = (root / "Sources/ControllerModel.swift").read_text()
pet = (root / "Sources/SessionPet.swift").read_text()
def need(c, m):
    if not c: sys.exit(f"ledger-hover: {m}")

# Asymmetric intent: a shorter beat in, a longer grace out. Equal or inverted
# delays reintroduce the skim-trigger and edge-flicker the prototype was
# rebuilt to kill (verified by measurement in the browser, 2026-08-30).
exp = float(re.search(r"petHoverExpandDelay: TimeInterval = ([0-9.]+)", model).group(1))
col = float(re.search(r"petHoverCollapseDelay: TimeInterval = ([0-9.]+)", model).group(1))
need(exp < col, f"expand delay {exp} must be shorter than the collapse grace {col}")

# petHoverRevealed is written ONLY by setPetHover (expand true, collapse
# false) and the pet-disable reset. The declaration's default is excluded.
writers = re.findall(r"(?<!@Published var )petHoverRevealed = (?:true|false|inside)", model)
need(len(writers) == 2, f"petHoverRevealed has {len(writers)} writers; setPetHover owns this flag")
need(re.search(r"petHoverRevealed\s*=", pet) is None
     and re.search(r"petHoverRevealed\.toggle", pet) is None,
     "the view must never write petHoverRevealed; setPetHover owns it")

# Single-phase by design since the hover bubble died (0.5.150): the settle
# machinery faded content that no longer exists and was deleted as dead
# wiring (QA Ghost Hunter, 2026-08-30). Keep it dead.
need("petHoverSettling" not in model and "petHoverSettling" not in pet,
     "the dead two-phase settle machinery returned")

# The sensor is an .activeAlways AppKit tracking area. SwiftUI's .onHover is
# tied to app activation and the pet is a nonactivating panel of a menu-bar
# app that is almost never active — its hover would effectively never fire.
need(re.search(r"\.onHover\s*[({]", pet) is None,
     "SwiftUI .onHover is activation-tied; use HoverSensor")
sensor = pet[pet.index("final class HoverSensorView"):]
need(".activeAlways" in sensor, "the tracking area must arm while the app is inactive")
need("override func hitTest(_ point: NSPoint) -> NSView? { nil }" in sensor,
     "the sensor must never swallow a click meant for the sprite or a pill")

# The bar is a nameplate UNDER the figure (Miles 2026-08-30): in the body the
# sprite mounts before the ledger slot, both riding the stable bottom edge.
body = pet[pet.index("var body: some View"):pet.index("// MARK: - Ledger")]
need(body.index("SessionPetSprite(") < body.index("\n            ledgerSlot"),
     "the ledger must render BELOW the sprite, never above it")

# 0.5.150 surface-family pins, hardened after the QA mutation pass: every
# assertion below reads COMMENT-STRIPPED code and pins the WIRING, so a
# comment naming a symbol can neither satisfy nor trip it.
# Strips BOTH full-line and trailing comments. Stripping only full lines
# let `private var showPills: Bool { true } // was: revealActive && revealArmed`
# satisfy every guard pin while killing the guard (QA mutation, 2026-08-31).
def strip_comments(src):
    out = []
    for line in src.splitlines():
        cut, quoted, i = None, False, 0
        while i < len(line) - 1:
            ch = line[i]
            if ch == '"' and (i == 0 or line[i - 1] != "\\"):
                quoted = not quoted
            elif ch == "/" and line[i + 1] == "/" and not quoted:
                cut = i
                break
            i += 1
        out.append(line if cut is None else line[:cut])
    return "\n".join(out)
code = strip_comments(pet)
model_code = strip_comments(model)
# Quiet-pet guard: pin the USE — showPills must gate all three render sites
# and be composed from revealActive AND revealArmed. (Computing the guard and
# discarding it compiled green against the old pin.)
need("revealActive && revealArmed" in code,
     "showPills no longer composes hover intent with the armed guard")
armed_src = code[code.index("private var revealArmed"):code.index("private var showPills")]
for term in ["sessions.isEmpty", "model.petCompletions.isEmpty", "model.petDismissals.stamps.isEmpty"]:
    need(term in armed_src,
         f"revealArmed lost its {term} term — a constant guard arms dead pills or strands a dismissed session")
slot = code[code.index("private var ledgerSlot"):code.index("private func ledgerBar")]
need(slot.count("showPills") >= 3 and "revealActive" not in slot,
     "the ledger slot must key every opacity and hit test on showPills alone")
need("value: showPills" in slot,
     "the crossfade must animate on showPills or an armed-state flip snaps")
# Focus dot: pin the STRUCTURE, not the deleted symbol name — the dot came
# back once as an inline Circle in a ZStack without ever naming petStateColor.
body_code = code[code.index("var body: some View"):code.index("private var ledgerSlot")]
need("Circle()" not in body_code and "petStateColor" not in code,
     "a focus-dot shape returned to the sprite body")
# Floating text: pin the CALL SITES (reverting a caller to a Capsule while
# the helper stayed intact passed the old pin) and the helper's surface.
# Scope the Capsule ban to the hint/notice region. A body-wide ban also
# outlawed any NEW capsule control in the stack — it fired on 2026-09-01 for
# the Close all button, which is not a hint/notice caller at all. The rule is
# "a hint/notice caller must not revert to a bare Capsule", so check there.
_float_region = body_code[body_code.index("model.petTerminalHint"):]
_float_region = _float_region[:_float_region.index("SessionPetSprite")]
need(body_code.count("petFloatingText(") == 2,
     "hint/notice no longer route through the shared floating surface")
need("Capsule" not in _float_region,
     "a hint/notice caller was reverted to a bare Capsule instead of the "
     "shared floating surface")
float_src = code[code.index("private func petFloatingText"):code.index("private var spriteHelp")]
need(".regularMaterial" in float_src and "RoundedRectangle" in float_src and "Capsule" not in float_src,
     "petFloatingText must use the lists' regularMaterial rounded rect — "
     "petNotice is the error channel and may never be LESS opaque than 0.5.149")
# Materials + insets: per-list slices, not file-wide counts (a whole-file
# count passed with one list off-family and both insets in the other).
live_src = code[code.index("private var sessionList"):code.index("private var completionsList")]
done_src = code[code.index("private var completionsList"):code.index("private func petFloatingText")]
for name, src in (("live", live_src), ("finished", done_src)):
    need(src.count(".regularMaterial") == 1,
         f"the {name} list left the material surface family")
    # Direction D (0.5.171): the 10pt inset that dodged the overlay scroll
    # indicator IS the dead space Miles kept pointing at, twice. The indicator
    # is hidden instead, and the row breaks the list padding to reach the edge.
    need('content.padding(.trailing, size.length(10))' not in src,
         f"the {name} list re-inset its rows off the card edge")
    need(".scrollIndicators(.hidden)" in src,
         f"the {name} list must hide the overlay indicator; it paints on the "
         "same right edge the row controls now occupy")

# Mission rows (0.5.155, design B): sectioning comes from the executable
# ClaudeSession.petSections — never re-derived in the view — in RUNNING,
# WAITING ON YOU, IDLE order.
need("ClaudeSession.petSections(sessions)" in live_src,
     "the live list no longer sections through the executable helper")
for a, b in [('"RUNNING"', '"WAITING ON YOU"'), ('"WAITING ON YOU"', '"IDLE"')]:
    need(live_src.index(a) < live_src.index(b),
         f"section {a} must render before {b} — weight order is the design")

# ---- Direction D (0.5.171), approved from the artboard --------------------
# ONE row shape for all three lists. Three call sites plus the definition; a
# list that grows its own row shape is how the finished row and the mission
# row drifted into two different anatomies in the first place.
need(code.count("petRowD(") == 4,
     "every list must render through the ONE Direction D row builder "
     "(3 call sites + 1 definition)")
mission_src = code[code.index("private func missionRow"):code.index("private func idleRow")]
idle_src = code[code.index("private func idleRow"):code.index("private struct PetRowActions")]
for _name, _src in (("mission", mission_src), ("idle", idle_src)):
    need("petRowD(" in _src and "model.openSessionInPlatform(session)" in _src,
         f"the {_name} row lost its whole-row jump through the shared builder")
row_src = code[code.index("private func petRowD"):code.index("private func petRowSlot")]
need('.help("Open in platform")' in row_src,
     "the row lost the affordance naming what a click does")
# Line one is the OUTCOME. Before D every finished row printed the literal
# "Finished", so two forked sessions read as the same three tokens no matter
# how wide the row got.
need("row.summary.isEmpty ?" in done_src and "row.summary" in done_src,
     "the finished row went back to a literal instead of what the session did")
_models_code = strip_comments((root / "Sources/Models.swift").read_text())
need("summary: prior.petOutcomeLine" in _models_code,
     "nothing captures the outcome at the moment a session stops")
need("petOutcomeLine" in _models_code and 'summary.isEmpty ? "Finished"' in _models_code,
     "petOutcomeLine is gone; petLiveLine falls back to \"working\", which is "
     "wrong once nothing is running")
# The outcome is measured in the face it is DRAWN in. The 0.6em fast path is a
# fact about JetBrains Mono only; asking it about a proportional face answers
# "it fits" for text that overflows, and the window clips it with neither
# motion nor an ellipsis.
need("face: .body" in row_src, "the outcome line is no longer measured as body text")
need("face == .mono, text.allSatisfy" in _models_code,
     "the monospace fast path is no longer guarded by the face")
# Hover starts exactly ONE ticker: the pointer is on one row, and four rows
# scrolling at once is noise.
need("active: hovered" in row_src, "the row ticker is no longer hover gated")
need("!reduceMotion && active" in code,
     "TickerLine stopped honouring the hover gate")
# Hover must change NO layout. The slot is a FIXED frame whose two occupants
# cross-fade; a size that keys on hover re-measures the panel through
# sizeThatFits and reads as the jumpiness Miles rejected in the prototype.
slot_src = code[code.index("private func petRowSlot"):code.index("private var completionsList")]
# 74 since 0.5.234: four glyphs (a paperplane joined the three) at 17pt each
# plus the shared 4pt edge. The number moved once, for a fourth control; the
# rule is that it is a FIXED literal, so a row with three glyphs and a row with
# four share one frame and hover moves nothing.
need(".frame(width: size.length(74), alignment: .trailing)" in slot_src,
     "the trailing slot lost its fixed frame")
need(".opacity(hovered ? 0 : 1)" in slot_src and ".opacity(hovered ? 1 : 0)" in slot_src,
     "the slot occupants no longer cross-fade")
for _bad in ["frame(width: hovered", "frame(height: hovered", "hovered ? size.",
             "padding(hovered", "size.length(hovered"]:
    need(_bad not in slot_src,
         f"a hover-keyed size returned to the slot ({_bad}); hover must move nothing")
need(".allowsHitTesting(hovered)" in slot_src,
     "the hidden actions still take clicks; a resting row would fire them")
# Pointer-only actions need a non-pointer path.
need(".contextMenu {" in row_src and row_src.count("Button(") >= 3,
     "the three paths are pointer-only; a right-click must reach them too")
# Per-row hover comes from the SAME .activeAlways sensor the root uses.
need("HoverSensor { inside in" in row_src and "hoveredRowID" in code,
     "per-row hover is not on the activeAlways sensor; .onHover does not fire "
     "on a nonactivating panel")
# Trailing inset, FOURTH correction, and the first one with a measurement
# behind it. Both lists wrap their rows in a ScrollView past three items, and a
# ScrollView CLIPS to its bounds — so a NEGATIVE trailing inset here does not
# move the trailing slot outward, it CUTS it. Measured on 0.5.173 against a
# window capture: the age rendered "7" for "7m" and the workspace
# "mu-chief-staf" for "mu-chief-staff", with no ellipsis, and on hover the
# trailing action glyph was sliced (row 4pt + glyph row 4pt = 8pt outside the
# clip). Three prior attempts tuned the MAGNITUDE of that overhang; every one
# of them was clipping, just by different amounts. No overhang is allowed.
need(not re.search(r"\.padding\(\.trailing, -size\.length\(", row_src),
     "the row overhangs its container again. The lists clip in a ScrollView, "
     "so this cuts the age/workspace/actions instead of moving them. Put the "
     "tucked edge on the CONTAINER's trailing inset.")
# Reverting the tuck to the 10pt default — the spacing rejected twice — kept
# the suite green (2026-09-01 QA). Pin it, and ban the other overhang spellings.
need(code.count(".padding(.trailing, size.length(2))") == 2
     and code.count(".padding(.leading, size.length(10))") == 2,
     "the lists lost their asymmetric trailing tuck; .horizontal 10pt restores "
     "the dead space that was rejected twice")
for _src, _nm in ((row_src, "row"), (slot_src, "slot")):
    need(not re.search(r"\.offset\(x:", _src),
         f"the {_nm} re-creates the overhang with .offset(x:), which clips "
         "inside the ScrollView exactly like a negative inset")
    need(not re.search(r"\.padding\(\.trailing, size\.length\(-", _src),
         f"the {_nm} re-creates the overhang with a negative length()")
need(not re.search(r"\.padding\(\.trailing, -size\.length\(", slot_src),
     "the trailing slot overhangs again; the glyph row is inside the same "
     "ScrollView clip and its last action gets sliced")
# Both occupants must share one trailing edge: rowAction ships 4pt of hit
# padding, so the resting text is inset by the same 4pt rather than the glyphs
# being pushed out past the clip.
need(re.search(r"\.padding\(\.trailing, size\.length\(4\)\)", slot_src),
     "the resting text lost the 4pt inset that matches rowAction's hit "
     "padding; text and hover glyphs no longer share a trailing edge")
# (Superseded 2026-09-01. This used to require the glyph row to OVERHANG by
# 4pt so its ink matched the age and workspace. That overhang crossed the
# ScrollView's clip boundary and sliced the trailing action; the same edge is
# now achieved by insetting the TEXT instead, asserted just above.)
# A LIVE row leads with the session NAME, not its live summary. Every resumed
# session's summary is the same boilerplate ("This session is being continued
# from a previous..."), so leading with it made running rows indistinguishable
# while their real names sat on the second line (Miles, 2026-09-01). Finished
# rows still lead with their outcome — that is the 0.5.171 design and is right.
# The idle row reads petIdleLine (0.5.226): the same summary, but a blank
# summary says "idle" instead of petLiveLine's "working".
for _fn, _line in (("missionRow", "petLiveLine"), ("idleRow", "petIdleLine")):
    _row = code[code.index(f"private func {_fn}("):]
    _row = _row[:_row.index("actions: PetRowActions")]
    need("outcome: session.title" in _row,
         f"{_fn} no longer leads with the session name; running rows become "
         "indistinguishable whenever their summaries match")
    need(f"title: session.{_line}" in _row,
         f"{_fn} lost its live summary from the second line")
_done = code[code.index("private var completionsList"):]
_done = _done[:_done.index("actions: PetRowActions")]
# Finished rows lead with the NAME, like the live rows and the Sessions tab.
# Leading with the summary reproduced the collision 0.5.171 was fixing: every
# resumed session carries identical boilerplate (Miles, 2026-09-01).
need("outcome: row.name.isEmpty" in _done,
     "finished rows stopped leading with the session name; every resumed "
     "session shares one summary, so the rows become indistinguishable")
# 0.5.229: a scheduled job's one row counts its runs instead; every session row keeps its outcome.
need('title: row.isScheduledJob ? row.runsLabel() : (row.summary.isEmpty ? "Finished" : row.summary)' in _done,
     "finished rows lost the outcome from their second line")

# The pet panel sizes ITSELF. NSHostingController defaults to
# .preferredContentSize on macOS 13+, which resizes the window from the
# SwiftUI content — and an AppKit content-size resize is anchored TOP-LEFT, so
# the panel grew downward and pushed a bottom-parked figure off the display
# (measured 2026-09-01: collapsed bottom=1620, expanded bottom=1788). syncPanel
# anchors the BOTTOM on purpose; without this the anchor is silently overridden.
# The position fix hangs on this handler being DELIVERED and correcting toward
# the PARKED anchor. Both were deletable with the suite green (2026-09-01 QA):
# dropping `panel.delegate = self` killed both handlers, and swapping
# `anchor: anchor` for `anchor: panel.frame.origin` made it a permanent no-op.
need("panel.delegate = self" in code,
     "the panel has no delegate, so windowDidResize and windowDidMove are both "
     "dead and the figure drifts with nothing looking wrong")
need("func windowDidResize(" in code,
     "windowDidResize is gone or renamed; NSWindowDelegate dispatch is by name")
_resize = code[code.index("func windowDidResize("):code.index("func windowDidMove")]
need("guard !applyingFrame" in _resize,
     "windowDidResize lost its !applyingFrame guard, so our own setFrame "
     "re-enters it — the documented ratchet")
need("anchor: anchor" in _resize and "restingAnchor" in _resize,
     "windowDidResize no longer corrects toward the PARKED anchor; computing "
     "from the current frame makes the correction a permanent no-op")
need("host.sizingOptions" not in code,
     "disabling the hosting controller's sizing also stops the hosting VIEW "
     "tracking the window, so lists lay out at a stale width and overflow "
     "their card (2026-09-01 field regression)")

# The Cursor jump presses an Agents row BY NAME. That is only safe while the
# name identifies one agent, and the session index emits duplicates (measured
# 2026-09-01: two Cursor rows named "COS glasses session update"), so an
# unguarded press silently opens the wrong agent.
_chat = model[model.index('if openMode == "chat"'):]
_chat = _chat[:_chat.index("if openMode ==", 20)]
need("PetRowIdentity.indistinguishable" in _chat,
     "the Cursor jump no longer checks whether the name is ambiguous; it will "
     "press whichever Agents row matches first and open the wrong session")
need('agentTab: clash ? "" : session.name' in _chat,
     "the Cursor jump passes an ambiguous name to the tab press instead of "
     "declining it")
_rev = model[model.index("private func revealCursorAgentsWindow("):]
_rev = _rev[:_rev.index("\n    }\n")]
need("if let clashHint" in _rev and _rev.index("if let clashHint") < _rev.index("pressCursorAgentTab"),
     "the clash check must come BEFORE the tab press, or the wrong row is "
     "pressed before the notice is ever shown")

# The slot's second line must actually be RESOLVED, not passed straight through.# The slot's second line must actually be RESOLVED, not passed straight through.
# PetRowIdentity is pure and executed in ModelsContract, but a pure helper the
# views never call is dead code that tests green (2026-09-01).
need("private func slotSecondLine(for session: ClaudeSession)" in code
     and "private func slotSecondLine(for row: PetCompletion)" in code,
     "the slot resolvers are gone; the second line falls back to a workspace "
     "that cannot tell duplicate rows apart")
need("workspace: slotSecondLine(for: session)" in code
     and "workspace: slotSecondLine(for: row)" in code,
     "a row passes its workspace straight to the slot again, bypassing the "
     "duplicate check")
need(code.count("workspace: slotSecondLine(for: session)") == 2,
     "only one of the two live row builders resolves its slot line")
_slot_s = code[code.index("private func slotSecondLine(for session: ClaudeSession)"):]
_slot_s = _slot_s[:_slot_s.index("\n    }") + 6]
need("createdDate" in _slot_s and "PetRowIdentity.clockLabel" in _slot_s,
     "live rows no longer fall back to their opened time")
_slot_c = code[code.index("private func slotSecondLine(for row: PetCompletion)"):]
_slot_c = _slot_c[:_slot_c.index("\n    }") + 6]
need("finishedAt" in _slot_c,
     "finished rows must show when they FINISHED, not another clock")

# Double-tap is the only gesture that both opens AND closes the menu.# Double-tap is the only gesture that both opens AND closes the menu.
# It previously guarded on `sessions.count > 1`, so at one running session it
# was a silent no-op, and it only toggled the RUNNING list, so a double-tap
# while DONE was open did nothing visible (Miles, 2026-09-01, at RUNNING 1).
_toggle = code[code.index("private func toggleSessionMenu"):]
_toggle = _toggle[:_toggle.index("\n    }") + 6]
need("sessions.count > 1" not in _toggle,
     "double-tap guards on a session count again; at RUNNING 1 the gesture "
     "silently does nothing")
need(re.search(r"petLastOpenList = model\.petCompletionsExpanded", _toggle),
     "double-tap no longer records which list it closed, so reopening snaps "
     "back to RUNNING instead of where the user was")
need("petCompletionsExpanded = false" in _toggle and "petExpanded = false" in _toggle,
     "double-tap must close BOTH lists; closing only one leaves the other "
     "pinned over the figure")
# An explicit pill click is also a choice of tab; the memory has to follow it.
_pills = code[code.index("private func pillsRow"):]
_pills = _pills[:_pills.index("private func ledgerPill")]
need(_pills.count("petLastOpenList") >= 2,
     "the RUNNING/DONE pills no longer record the tab, so a later double-tap "
     "reopens a list the user did not last use")
# Bulk clear exists and is gated on the finished list actually being open.
need("clearAllPetCompletions" in code,
     "the Close all control is gone; clearing eight finished rows one X at a "
     "time is what it exists to avoid")
# Structural, not a 400-character proximity window: the gate sat 382 chars away
# and one cosmetic modifier would have false-alarmed it.
_cta_if = code.rindex("if model.petCompletionsExpanded", 0, code.index("Close all"))
need("petCompletions.isEmpty" in code[_cta_if:code.index("Close all")],
     "the Close all control is not gated on the finished list being open and "
     "non-empty; it would float over the pet on its own")
need("clearAllPetCompletions" in model,
     "clearAllPetCompletions vanished from the model")
# Name-only pins let the button ship dead: emptying the body, or dropping
# either half of its contract, kept the suite green (2026-09-01 QA).
_clr = model[model.index("func clearAllPetCompletions("):]
_clr = _clr[:_clr.index("\n    }") + 6]
need("petCompletions.removeAll()" in _clr, "Close all clears nothing; the button is dead")
need("savePetCompletions()" in _clr, "Close all does not persist; rows return on relaunch")
need("petCompletionsExpanded = false" in _clr, "Close all leaves an emptied list pinned open")
need("guard !petCompletions.isEmpty" in _clr, "Close all lost its empty guard")

# The reading surface is no longer sized by the sprite.
need("size.length(392)" in code,
     "the card went back to the 248 root, where a finished title is 68pt "
     "(ten characters of DM Sans 11, measured)")

# Every row wears its platform mark through the ONE shared builder.
# D collapsed three row anatomies into one, so there is exactly ONE place a
# platform mark is drawn: the shared row's identity line, plus the definition.
# 0.5.234 adds the one other place a mark belongs: the composer card's target
# line, which names WHERE a message goes and must wear the same mark the row
# did. Three, and the third is pinned to the card below.
need(code.count("providerGlyph(") == 3,
     "the platform mark is drawn somewhere other than the one shared row "
     "builder (1 call site + 1 definition)")
need("providerGlyph(mark, tint: markTint)" in row_src,
     "the shared row lost its platform mark")
_mark_src = code[code.index("private func providerGlyph"):code.index("private func rowAction")]
need("COSBrand.svg(name)" in _mark_src and "Image(systemName: name)" in _mark_src,
     "the platform mark must render the bundled brand logo, with an SF Symbol "
     "only where no brand mark ships")
for _asset in ["mark-claude", "mark-codex", "mark-cursor"]:
    need((root / f"Resources/{_asset}.svg").exists(),
         f"Resources/{_asset}.svg is missing; the row would render nothing")
need('cp "$ROOT/Resources/mark-"*.svg' in (root / "scripts/build-release.sh").read_text(),
     "the release build does not ship the platform marks")
# The rail must be an OVERLAY of the row content, never an HStack child: a
# bare Shape child accepts any offered height, and under the panel's
# sizeThatFits probe one running row absorbed ~800px of blank card (shipped
# in 0.5.155, caught by Miles's screenshot within the hour).
label_src = row_src[:row_src.index(".overlay(alignment: .leading)")]
# D's row button takes a trailing closure rather than `label:`, so anchor on
# the button itself. Getting this wrong silently empties the window and the
# height check below stops checking anything.
need("Button(action: primary) {" in label_src,
     "the row button changed shape; the bare-Shape height check below is "
     "reading the wrong window and would pass on an empty string")
_label_body = label_src.split("Button(action: primary) {")[1]
for _m in re.finditer(r"\b(RoundedRectangle|Rectangle|Capsule|Circle|Ellipse)\s*\(", _label_body):
    _before = _label_body[max(0, _m.start() - 24):_m.start()]
    if any(k in _before for k in ("contentShape(", "clipShape(", "in: ", "background(")):
        continue
    _tail = _label_body[_m.start():_m.start() + 240]
    need("height:" in _tail,
         f"a {_m.group(1)} in the row label declares no height; it will "
         "stretch to whatever the row is offered — give it a height or make it "
         "an overlay like the rail")
rail_src = row_src[row_src.index(".overlay(alignment: .leading)"):]
need("RoundedRectangle" in rail_src and ".frame(width: size.length(3))" in rail_src,
     "the row lost its state rail overlay")

_aw = strip_comments((root / "Sources/ActivityWindow.swift").read_text())
# Semantic layer (0.5.170): the helper's FIRST model call, so every stop the
# cost policy requires is pinned. The parsing is executed in the self-test.
_sem_helper = strip_comments((root / "HelperSources/main.swift").read_text())
_sem = _sem_helper[_sem_helper.index("private func emitArchiveSemantic"):]
_sem = _sem[:_sem.index("private func emitArchiveDay")]
need('args.contains("--enabled")' in _sem and 'COS_CONTROL_SEMANTIC_SEARCH' in _sem,
     "the master switch is gone; a model call must never be reachable by default")
need("ledger.failures >= 2" in _sem, "the breaker is gone")
need("ledger.used >= Self.semanticDailyCap" in _sem, "the daily cap is gone")
need("guard enabled else" in _sem,
     "the master switch is no longer an unconditional guard")
need('findExecutable("claude")' in _sem, "the model call itself is gone")
need(_sem.index("guard enabled else") < _sem.index("findExecutable(\"claude\")"),
     "the switch must be checked BEFORE the model is invoked")
need(_sem.index("ledger.used >= Self.semanticDailyCap") < _sem.index("findExecutable(\"claude\")"),
     "the cap must be checked BEFORE the spend, not after")
need('"--model", Self.semanticModel' in _sem,
     "the model must be pinned on the command line")
# VERIFY-BEFORE-SHOW is what makes this safe without embeddings.
need("known.contains(date)" in _sem and "guard !exchanges.isEmpty else { continue }" in _sem,
     "a suggested day must be verified against the archive before it is shown")
# The OFFER is automatic; the CALL is not.
need("archiveResultIsThin" in model_code,
     "nothing decides when a keyword answer is thin enough to offer meaning")
_run = model_code[model_code.index("func runArchiveSemantic("):]
_run = _run[:_run.index("\n    }")]
need("semanticSearchEnabled" in _run,
     "the semantic call must respect the user's setting")
need("runArchiveSemantic" not in _aw.split("Button(\"Search by meaning\")")[0].split("semanticSection")[-1],
     "the semantic call must be reachable only from the explicit button")

# Search quality (0.5.168). The maths is EXECUTED in the helper self-test;
# these pin the wiring.
_helper_code = strip_comments((root / "HelperSources/main.swift").read_text())
need("cleanedSnippet(" in _helper_code,
     "day-level snippets must be cleaned or raw JSON reaches the UI")
need("fuzzyMatches(" in _helper_code,
     "search lost its typo tolerance")
_only = model_code[model_code.index("archiveMatchingChats = response.details"):]
_only = _only[:_only.index("\n        } catch")]
need("archiveOnlyMatches = !query.isEmpty && archiveMatchingChats > 0" in _only,
     "a search must default to showing its matches, and must NOT filter when "
     "nothing matched or the day would look empty")

# Search everywhere, visible while you scroll, with the TERM marked (0.5.169).
need("visibleRecentMessages" in _aw,
     "Recent has no search; the newest turns were the one place you could not look")
need('TextField("Search recent and archive"' in _aw,
     "the Recent view lost its search field")
# ONE term spans both surfaces (0.5.170). Two boxes meant "No recent message
# contains thule" while the archive held 34 hits one tap away, and you had to
# retype the word to find that out (Miles, 2026-08-31).
need('@State private var recentQuery' not in _aw
     and 'private var recentQuery: String { model.archiveQuery }' in _aw,
     "Recent went back to its own search term; the two surfaces must share one")
need(_aw.count('TextField("Search') == 1 or 'Search the archive"' not in _aw,
     "a second top-level message search box returned")
need("messageSearchCrossing" in _aw and "func crossingCount(" in _aw,
     "nothing tells you how many matches are on the side you are not looking at")
need("archiveHitsQuery == query else { return \"press return\" }" in _aw,
     "the archive count must not report the PREVIOUS term's answer beside a new term")
need("runPendingArchiveSearch()" in _aw and _aw.count("runPendingArchiveSearch()") >= 3,
     "crossing into the archive with a term already typed must run it, from both "
     "the picker and the count")
need("recentMissCopy" in _aw,
     "a miss in Recent must name the archive rather than dead-ending")
_model_thin = model_code[model_code.index("var archiveResultIsThin"):]
_model_thin = _model_thin[:_model_thin.index("\n    }")]
need("archiveHitsQuery == q" in _model_thin,
     "the semantic offer must key on an answer to the CURRENT term")
# The bars sit OUTSIDE their ScrollViews, or they scroll away with the content
# and you lose sight of what you searched for.
_chat_body = _aw[_aw.index("private func archiveChatDetail"):_aw.index("private var visibleRecentMessages")]
need(_chat_body.index("chatSearchBar(proxy:") < _chat_body.index("ScrollView {"),
     "the in-chat search bar must sit above the ScrollView, not inside it")
_day_body = _aw[_aw.index("private func archiveDayDetail"):_aw.index("private func archiveDaySubtitle")]
need("archiveDaySearchBar(date: date)" in _day_body
     and _day_body.index("archiveDaySearchBar(date: date)") < _day_body.rindex("ScrollView {"),
     "the day search bar must stay visible while the chat list scrolls")
# The TERM is marked, not merely the row: a tinted row says "somewhere in here".
need("func highlighted(" in _aw and "SearchMark.ranges(in: text, query: query)" in _aw,
     "the highlighter must mark the ranges SearchMark finds")
need("SearchMark.matches(query: recentQuery" in _aw,
     "the recent filter must run through the executed matcher")
need("colorScheme == .dark" in _aw,
     "the highlight must pick a high-contrast fill per appearance")
need(_aw.count("highlight: chatQuery") == 2 and _aw.count("highlight: recentQuery") == 2,
     "both sides of a turn must highlight, in both the archive and recent views")

# In-chat search (0.5.167): the THIRD rung. Day -> chat -> the passage itself.
# A 28-message transcript with 46 matches and no way to jump was the same dead
# end one level deeper (Miles, 2026-08-31).
# The VIEW BODY only. A slice that ran to messageDetail also swallowed
# chatSearchBar's own definition, so deleting the CALL still satisfied the pin.
_chat = _aw[_aw.index("private func archiveChatDetail"):_aw.index("private func messageMatches")]
need("ScrollViewReader" in _chat and "proxy.scrollTo(" in _aw,
     "the transcript cannot jump to a match without a ScrollViewReader")
need(".id(message.id)" in _chat,
     "matched turns need stable ids or scrollTo has nothing to aim at")
need("chatSearchBar(proxy:" in _chat, "the transcript has no in-chat search")
need("chatQuery = model.archiveChatsQuery" in _chat,
     "the day's term must seed the chat search rather than being typed a third time")
_jump = _aw[_aw.index("private func jumpToMatch"):]
_jump = _jump[:_jump.index("\n    }")]
need("% ids.count + ids.count) % ids.count" in _jump,
     "match navigation must wrap at both ends, not dead-end at the last hit")

# Archive topics + within-day search (0.5.166). The topic/match maths is
# EXECUTED in the helper self-test; these pin the wiring it cannot see.
need("chat.headline" in _aw,
     "the archive row must lead with the topic, not the ordinal")
need('Text("Chat \\(chat.index + 1) ·' in _aw,
     "the ordinal must survive as a reference line, just not as the headline")
need("visibleArchiveChats" in _aw and "archiveOnlyMatches" in _aw,
     "the day view cannot filter to the chats that matched")
_load = model_code[model_code.index("func loadArchiveChats("):]
_load = _load[:_load.index("\n    }")]
need('if query.count >= 2 { args += ["--q", query] }' in _load,
     "the search that found the day must carry INTO the day — the argument line "
     "alone can sit behind a dead condition")
need("archiveMatchingChats" in _load,
     "the day never records how many of its chats matched")
need('request("/api/archive/\\(date)"' in _helper_code,
     "archive-day must read the FULL day; /chats carries no exchanges to search")
need("archiveChatTopic(" in _helper_code and "archiveChatMatches(" in _helper_code,
     "the topic and match helpers are gone")

# Calm motion (0.5.165) is a FIGURE preference, never a status one: it feeds
# the pose resolver and must never touch the ledger, which carries the counts.
need("calm: petCalmMotion" in model_code,
     "the calm preference does not reach the pose resolver")
_ledger_src = model_code[model_code.index("var petLedger"):model_code.index("var petSpritePose")]
need("petCalmMotion" not in _ledger_src,
     "calm motion must not touch the ledger; lower motion may not cost status")
_calm_setter = model_code[model_code.index("func setPetCalmMotion("):]
_calm_setter = _calm_setter[:_calm_setter.index("\n    }")]
need("UserDefaults.standard.set(enabled, forKey: Self.petCalmMotionKey)" in _calm_setter,
     "setPetCalmMotion does not persist the choice; it would reset every launch")
need("UserDefaults.standard.bool(forKey: ControllerModel.petCalmMotionKey)" in model_code,
     "the calm preference is never read back at launch")
need("Calm motion" in (root / "Sources/Views.swift").read_text(),
     "calm motion has no control in Session Pet settings")
# The token-spending switch lives beside the search it governs, NOT in the
# toolbar panel, where it sat third between Activity and Server status
# (Miles, 2026-09-01: "should be out of the way"). Wherever it lives it must
# read as a cost before it reads as a feature.
_v = strip_comments((root / "Sources/Views.swift").read_text())
need("searchModeRow" not in _v and "semanticSearchEnabled" not in _v,
     "the search-by-meaning switch is back in the toolbar panel")
_awv = strip_comments((root / "Sources/ActivityWindow.swift").read_text())
_msg_row = _awv[_awv.index('TextField("Search recent and archive"'):]
_msg_row = _msg_row[:_msg_row.index("messageSearchCrossing")]
need("model.setSemanticSearchEnabled($0)" in _msg_row,
     "the meaning switch is not in the row that owns search")
need("your Claude usage" in _msg_row and "keyword only" in _msg_row,
     "the switch must state the cost; a bare checkbox hides what it spends")
# An off-state that names a pane it no longer lives in is an instruction with
# no affordance, which is the Control defect from 2026-08-26 one layer smaller.
need("turn it on in Settings" not in _awv,
     "the offer still sends the user to Settings for a switch that moved")
_off = _awv[_awv.index("Search by meaning is off"):]
_off = _off[:_off.index("} else {")]
need("setSemanticSearchEnabled(true)" in _off,
     "the off-state must offer to turn it on, not merely say that it is off")
_pet_pane = _v[_v.index("private struct PetSizeControls"):]
_pet_pane = _pet_pane[:_pet_pane.index("onAppear { pixelDraft")]
need("semanticSearchEnabled" not in _pet_pane,
     "the search flag is back in the pet settings pane")
# The first version of that flag orphaned calm motion's caption: it sat between
# the toggle and the text explaining it, so the text read as the flag's.
_calm_gap = _pet_pane[_pet_pane.index('Toggle("Calm motion"'):
                      _pet_pane.index("Rests the character")]
need("Toggle(" not in _calm_gap.replace('Toggle("Calm motion"', "", 1),
     "another control sits between the Calm motion toggle and its own caption; "
     "the caption now reads as that control's")

# The pet must return to where it was parked. Every frame is rebuilt from the
# resting anchor: reading the last CLAMPED origin back walked a high-parked
# pet 450pt down the screen in one open (measured 2026-08-31).
sync = code[code.index("private func syncPanel"):code.index("private func fittedCharacterScale")]
need("PetPanelFrame.positioned(" in sync,
     "syncPanel no longer rebuilds the frame from the resting anchor")
# The anchor must come from MEMORY, with the live frame only as the first-run
# fallback. Calling positioned() with the panel's current (already clamped)
# origin reintroduces the walk while still looking correct.
need("restingAnchor ??" in sync,
     "syncPanel must anchor from the stored rest, not read the live frame back")
need("PetPanelFrame.clamped(" not in sync,
     "syncPanel must place through positioned(); calling clamped() on the live "
     "frame restores the walk while positioned() sits there looking correct")
need(sync.index("panel.setFrame(") < sync.index("PetPanelFrame.positioned("),
     "positioned() must BE the setFrame argument, not a discarded call")
# P — the guard must BRACKET the setFrame, not merely appear twice.
need(sync.index("applyingFrame = true") < sync.index("panel.setFrame(")
     < sync.index("applyingFrame = false"),
     "the applyingFrame guard must wrap the setFrame, not just exist")
need("frame.size =" not in sync,
     "syncPanel mutates the live panel frame again; a clamped slide becomes the new rest")
move = code[code.index("func windowDidMove"):code.index("private func syncLists")]
need("guard !applyingFrame" in move,
     "windowDidMove must ignore our own setFrame or a clamped slide re-parks the pet")
# Every PROGRAMMATIC setFrame must be wrapped, so windowDidMove/windowDidResize
# never mistake our own correction for the user re-parking the pet. This used to
# count the guard sites as exactly 1, which was a proxy for "there is only one
# such setFrame" — it broke on 2026-09-01 when the resize re-anchor added a
# second, equally guarded one. Assert the RULE: balanced, and every site wrapped.
_true = len(re.findall(r"(?<!var )applyingFrame = true", code))
_false = len(re.findall(r"(?<!var )applyingFrame = false", code))
need(_true == _false and _true >= 1,
     f"the applyingFrame guard is unbalanced ({_true} on, {_false} off); an "
     "unguarded setFrame lets a clamped slide re-park the pet")
for _fn in ("syncPanel", "windowDidResize"):
    _body = code[code.index(f"func {_fn}("):]
    _body = _body[:_body.index("\n    }") + 6]
    # No `continue`. Skipping a setFrame-less body is how gutting
    # windowDidResize passed with the suite green (2026-09-01 QA).
    need("panel.setFrame(" in _body,
         f"{_fn} no longer applies a frame; the correction is computed and discarded")
    # `defer { applyingFrame = false }` is the stronger spelling — it resets on
    # every exit path, including one a future edit inserts — but it puts the
    # reset textually BEFORE the setFrame, so a positional check rejects it.
    _deferred = re.search(r"defer\s*\{\s*applyingFrame = false\s*\}", _body)
    if _deferred:
        need(_body.index("applyingFrame = true") < _deferred.start()
             < _body.index("panel.setFrame("),
             f"{_fn} defers the reset before it arms the guard")
    else:
        need(_body.index("applyingFrame = true") < _body.index("panel.setFrame(")
             < _body.index("applyingFrame = false"),
             f"{_fn}'s setFrame is not wrapped by the applyingFrame guard")

# The LIVE line is a ticker: fixed window, hidden overflow, motion only when
# the text genuinely overflows.
need("TickerLine(" in row_src, "the outcome line lost its ticker")
tick = code[code.index("private struct TickerLine"):code.index("private struct PetReveal")]
need(".clipped()" in tick, "the ticker window must hide its overflow")
need("PetTicker.scrolls(" in tick and "!reduceMotion" in tick,
     "the ticker must stay still when the text fits or motion is reduced")
_task_key = tick[tick.index(".task(id:"):tick.index(".task(id:") + 140]
need("text" in _task_key and "scrolls" in _task_key,
     "the ticker task must key on the text AND the geometry that decides whether "
     "it scrolls — keying on text alone froze the line when the row narrowed")
need(".truncationMode(.tail)" in tick and tick.count(".fixedSize()") == 1,
     "a non-scrolling line must ellipsise; fixedSize on that branch hard-cuts it")

# The pet floats over arbitrary wallpaper: the ledger needs its own surface.
bar_src = pet[pet.index("private func ledgerBar"):pet.index("private func pillsRow")]
need(".background(.thinMaterial, in: Capsule())" in bar_src,
     "the ledger lost its blur backing and is unreadable on busy wallpaper")

# Hover changes NO layout (pills cross-fade in the bar's fixed slot), so the
# presenter must NOT re-measure the panel on every hover flip — that sink was
# two full sizeThatFits passes per hover for nothing (QA, 2026-08-30).
need("$petHoverRevealed.sink" not in code,
     "a hover-driven panel refit returned; hover must stay layout-free")
# Finished entries are clearable like live rows (Miles 2026-08-30): a
# SIBLING x per chip, wired to a model clear that persists and closes an
# emptied list instead of pinning an empty card over the figure.
comp2 = pet[pet.index("private var completionsList"):pet.index("private func petFloatingText")]
need("clearPetCompletion(" in comp2, "finished rows have no clear control")
# Three paths off a row (Miles, 2026-08-31): open in the platform, open the
# session view in Control, clear the entry. Since D they live in the shared
# slot, so pin them THERE and pin that the finished row still supplies all
# three — a row that passes no clear closure silently loses the control.
for _sym, _what in [('"arrow.up.forward.app"', "open in platform"),
                    ('"text.alignleft"', "open the session view"),
                    ('"xmark"', "clear the entry")]:
    need(f"rowAction({_sym}" in slot_src,
         f"the row slot lost its {_what} control")
for _arg in ["openInPlatform:", "openInControl:", "clear:"]:
    need(_arg in comp2, f"the finished row supplies no {_arg} action")
need("model.openSessionInPlatform(session)" in comp2 and "presenter.openInControl(session)" in comp2,
     "the finished row's two open paths must reach different destinations")
# Oversized transcripts are WINDOWED, never refused. The window itself is
# EXECUTED by the helper self-test; this pins that the refusal stays dead.
helper = strip_comments((root / "HelperSources/main.swift").read_text())
need("too large to open in Control" not in helper,
     "the size refusal returned; oversized transcripts must be windowed")
need("forEachTranscriptLine(" in helper and "agentSessionTailWindowBytes" in helper,
     "the windowed transcript reader is gone")
clr = model[model.index("func clearPetCompletion("):]
clr = clr[:clr.index("\n    }")]
need("removeAll { $0.id == row.id }" in clr and "savePetCompletions()" in clr,
     "clear must remove exactly one chip and persist")
need("petCompletionsExpanded = false" in clr,
     "an emptied finished list must close, not pin an empty card")
# The pin must die on EVERY path that can empty the chips behind the user's
# back — a resumed session dropping its chip, and the 4h age-out — or the pet
# wedges in pills state with no list and no cursor nearby (QA, 2026-08-30).
for fn in ["private func mergeCompletions(", "private func reconcilePersistedChips("]:
    fn_src = model[model.index(fn):]
    fn_src = fn_src[:fn_src.index("\n    }")]
    need("if petCompletions.isEmpty { petCompletionsExpanded = false }" in fn_src,
         f"{fn.split('(')[0].split()[-1]} can empty the chips without releasing the finished-list pin")

# ---- Pet composer (0.5.234): message a session from the pet -------------
# The send path is a FOURTH row action, offered only where the model says the
# session can take a message, on BOTH live row builders, in the slot AND the
# context menu. It opens the card; it never sends by itself.
for _name, _src in (("mission", mission_src), ("idle", idle_src)):
    need("send: model.canMessagePetSession(session) ? { model.openPetComposer(for: session) } : nil" in _src,
         f"the {_name} row no longer offers the message path through the model's gate")
need('rowAction("paperplane", help: "Message this session", action: send)' in slot_src,
     "the row slot lost its message control")
need('Button("Message this session", action: send)' in row_src,
     "the message path is pointer-only; the context menu must carry it too")
need("send: model.canMessagePetSession" not in comp2 and "openPetComposer" not in comp2,
     "a finished row must not offer a message path")
# The card takes the list's slot and names its target; one card, never a card
# and a list. The chip is what the acceptance lands on.
card_src = code[code.index("private func composerCard"):code.index("private func composerPlaceholder")]
need('Text("TO")' in card_src and "providerGlyph(target.petProviderMark" in card_src
     and "Text(target.title)" in card_src,
     "the composer card does not name its target")
need("if let sent = model.petSentText" in card_src and ".transition(" in card_src,
     "the sent chip is gone, or it no longer moves out of the field")
# 0.5.236: Escape goes through escapePetComposer, which folds an edit before it
# closes the card (pinned below, with the fold-before-close order).
need(".focused($composerFocused)" in card_src and ".onSubmit { model.sendPetMessage() }" in card_src
     and ".onExitCommand { model.escapePetComposer() }" in card_src,
     "the field lost focus, Return-to-send or Escape")
need(".stroke(accepted ? COSPalette.gold : COSPalette.line" in card_src,
     "the card no longer goes gold on acceptance")
need("composerCard(target)" in body_code and "petComposeTarget" in body_code,
     "the card is not mounted in the pet's column")
btn_src = code[code.index("private func sendButton"):code.index("private struct TickerLine")]
for _needle, _what in (("ProgressView()", "the in-flight ring"),
                       ('Image(systemName: "checkmark")', "the accepted check"),
                       ('Image(systemName: "paperplane.fill")', "the resting paperplane")):
    need(_needle in btn_src, f"the send button lost {_what}")
need(".disabled(!ready)" in btn_src, "the send button can be pressed with nothing to send")
open_src = model[model.index("func openPetComposer(for session: ClaudeSession)"):]
open_src = open_src[:open_src.index("\n    }")]
need("petExpanded = false" in open_src and "petCompletionsExpanded = false" in open_src,
     "opening the card must close the lists; the card takes their slot")
# The panel may become key without activating the app, and gives the keyboard
# back on close by stepping out and in — orderFrontRegardless never takes key.
need("final class PetPanel: NSPanel" in pet and "override var canBecomeKey: Bool { true }" in pet
     and "PetPanel(contentRect:" in pet,
     "the pet panel cannot take a keystroke: no key-window override, or it is not the panel in use")
close_src = pet[pet.index("private func composerTargetChanged(open: Bool)"):]
close_src = close_src[:close_src.index("\n    }")]
need("panel.makeKeyAndOrderFront(nil)" in close_src and "panel.orderOut(nil)" in close_src
     and "panel.orderFrontRegardless()" in close_src,
     "the composer no longer takes the keyboard on open or gives it back on close")
need("petComposerYieldsToOutsideClick()" in pet,
     "an outside click no longer asks the model whether the card may close")
# The Sessions pane and the pet attach through ONE cache, or one refuses the
# other as busy against COS Control's own binding.
need("sessionBindings[Self.bindingKey(session)] = binding" in model
     and model.count("sessionBindings[Self.bindingKey(session)] = nil") >= 2
     and "chatBinding = cachedBinding(session)" in model,
     "the pane and the pet no longer share the binding cache")
need('"via": body["via"] as? String ?? ""' in (root / "HelperSources/main.swift").read_text(),
     "the helper dropped via; a live hand-off would read as a replay")
need('details["via"]?.string == "live"' in model, "the pet does not read via")
# The G2's queued approach (Miles, 2026-09-17, after the first live send read
# "Your Mac is writing to this thread right now"): a thread mid-turn is PARKED on
# the server's queued-turns route and delivered when the turn ends, never
# refused. The two queueable reasons mirror the server's set, the probe turns
# them into a hint instead of a block, the send goes to the queue FIRST when the
# probe saw a busy thread, and a refusal met after the probe parks the same id.
helper_src = (root / "HelperSources/main.swift").read_text()
need('case "session-chat-queue": try emitSessionChatQueue(args: args)' in helper_src
     and '/queued-turns", method: "POST"' in helper_src,
     "the helper has no park verb, or it does not POST the queued-turns route")
need('static let sessionChatQueueableReasons: Set<String> = ["native_thread_working", "native_target_busy"]' in helper_src
     and 'static let petQueueableReasons: Set<String> = ["native_thread_working", "native_target_busy"]' in model,
     "the queueable pair drifted between the helper and the model, or from the server's QUEUEABLE_REFUSALS")
probe_src = model[model.index("private func probePetComposeTarget("):]
probe_src = probe_src[:probe_src.index("\n    }\n")]
need("if Self.petQueueableReasons.contains(reason) {" in probe_src
     and "petComposeParkReason = reason" in probe_src
     and probe_src.index("petComposeParkReason = reason") < probe_src.index('petSendPhase = .blocked(copy.isEmpty ? "COS cannot reach'),
     "the probe blocks the send on a busy thread instead of arming the park path")
perform_src = model[model.index("private func performPetSend("):]
perform_src = perform_src[:perform_src.index("\n    }\n")]
need("if petComposeParkReason != nil {" in perform_src
     and perform_src.index("parkPetTurn(") < perform_src.index("cachedBinding(session)"),
     "a send on a probed-busy thread must go to the queue BEFORE any attach")
need("case .threadFree: petComposeParkReason = nil" in perform_src,
     "a 409 thread_free must fall through to the ordinary send with the same turn id")
need("if Self.petQueueableReasons.contains(reason) { return .park(copy) }" in model,
     "a queueable refusal from the turn route no longer parks")
need('"session-chat-queue",' in model and '"--client-turn-id", clientTurnId,' in model,
     "the model does not call the park verb with the turn id")
# ---- Queued turns: list and cancel (0.5.235) ----------------------------
need('case "session-chat-queued": try emitSessionChatQueued(args: args)' in helper_src
     and 'case "session-chat-queue-cancel": try emitSessionChatQueueCancel(args: args)' in helper_src,
     "the helper lost a queue verb")
need('/queued-turns/\\(clientTurnId)", method: "DELETE"' in helper_src,
     "cancel does not DELETE the server's queued-turn route")
need('"session-chat-queued",' in model and '"session-chat-queue-cancel",' in model,
     "the model does not call both queue verbs")
need("rememberQueuedPrompt(clientTurnId, prompt)" in model and "pruneQueuedPromptLedger(keeping:" in model
     and model.count("pruneQueuedPromptLedger(keeping: Set(turns.map(\\.clientTurnId)))") == 2,
     "the full-text ledger is not written on park or not pruned on both loads")
need("row.queuedTurns != petQueuedTurns.filter(\\.isWaiting).count" in model
     and "row.queuedTurns != chatQueuedTurns.filter(\\.isWaiting).count" in model,
     "a moved queued count no longer reloads the list on both surfaces")
qrows = code[code.index("private func queuedRows("):code.index("private func sendButton")]
need("QueuedSessionTurn.cardRows(model.petQueuedTurns)" in qrows and "if turn.cancellable {" in qrows
     and "model.cancelPetQueuedTurn(turn)" in qrows,
     "the card's queue rows lost the cancel gated on a waiting row")
need("queuedRows(target)" in card_src, "the card does not mount its queue rows")
activity_src = (root / "Sources/ActivityWindow.swift").read_text()
need('Button("Cancel") { model.cancelChatQueuedTurn(turn) }' in activity_src and "if turn.cancellable {" in activity_src
     and "model.queuedTurnText(turn)" in activity_src,
     "the pane lists the queue without Cancel, or draws the preview instead of the text")
need("follow-up queued; it lands when this turn ends." in activity_src,
     "the pane lost its queued line")
# ---- Queued turns: expand and edit (0.5.236) --------------------------
need("model.togglePetExpandedTurn(turn)" in qrows and "lineLimit(expanded ? 12 : 1)" in qrows,
     "the card row no longer opens to its whole text on tap")
need('Button("Edit") { model.beginEditingPetTurn(turn) }' in qrows and qrows.index("if turn.cancellable {") < qrows.index('Button("Edit")'),
     "Edit is offered on a row that cannot be cancelled")
replace_src = model[model.index("private func performPetReplace("):]
replace_src = replace_src[:replace_src.index("\n    }\n")]
need(replace_src.index("cancelQueuedTurn(session, turn)") < replace_src.index("parkPetTurn(session, clientTurnId: clientTurnId, prompt: prompt)"),
     "the card's replace parks before it cancels; that is two copies")
need("Too late to edit: the session already has it." in replace_src and "petComposeDraft = prompt" in replace_src,
     "a too-late replace no longer keeps the text in the field")
need("case .threadFree:" in replace_src and "performPetSend(session, prompt: prompt)" in replace_src,
     "a thread that freed between cancel and park drops the message")
pane_replace = model[model.index("func replaceChatQueuedTurn()"):]
pane_replace = pane_replace[:pane_replace.index("\n    }\n")]
need(pane_replace.index("cancelQueuedTurn(session, turn)") < pane_replace.index("parkPetTurn(session, clientTurnId: UUID().uuidString, prompt: prompt)"),
     "the pane's replace parks before it cancels")
need("if chatEditingTurn != nil { replaceChatQueuedTurn(); return }" in model,
     "the pane's Send does not route to replace while editing")
esc = model[model.index("func escapePetComposer()"):]
esc = esc[:esc.index("\n    }\n")]
need("if petEditingTurn != nil { cancelEditingPetTurn() } else { closePetComposer() }" in esc
     and ".onExitCommand { model.escapePetComposer() }" in card_src,
     "Escape closes the card under an edit instead of folding the edit first")
need("QueuedSessionTurn.cancelVerdict(state: state, status: status)" in model,
     "the cancel outcome no longer reads the settled status; a delivered row would read cancelled")
need('Button(model.chatEditingTurn == nil ? "Send" : "Replace")' in activity_src
     and 'Button("Edit") { model.beginEditingChatTurn(turn) }' in activity_src
     and 'Button("Keep it as it was") { model.cancelEditingChatTurn() }' in activity_src,
     "the pane lost Edit, Keep it as it was, or the Replace label")
# The Sessions pane parks the same way (the docs have claimed it since 6.48.1).
refusal_src = model[model.index("private func handleChatRefusal("):]
refusal_src = refusal_src[:refusal_src.index("\n    }\n")]
need("if Self.petQueueableReasons.contains(reason) {" in refusal_src
     and "parkPetTurn(session, clientTurnId: pending.clientTurnId, prompt: pending.prompt)" in refusal_src
     and refusal_src.index("parkPetTurn(") < refusal_src.index("chatRetryAvailable = true"),
     "the pane's wait-class refusal no longer parks before offering Retry")
# 0.5.238: the pane parks on a probed-busy thread and on a busy attach, as the pet does.
chat_probe = model[model.index("private func probeChatAttachability("):]
chat_probe = chat_probe[:chat_probe.index("\n    }\n")]
need("if Self.petQueueableReasons.contains(reason) {" in chat_probe
     and "chatParkReason = reason" in chat_probe
     and "chatParkHint = Self.petParkHint(for: session)" in chat_probe
     and chat_probe.index("chatParkReason = reason") < chat_probe.index("chatRefusal = chatVerdict?.reasonCopy"),
     "the pane's probe renders a mid-turn thread as a refusal instead of arming the park path")
chat_send = model[model.index("private func performChatSend("):]
chat_send = chat_send[:chat_send.index("\n    }\n")]
need("if chatParkReason != nil {" in chat_send
     and chat_send.index("parkPetTurn(") < chat_send.index("cachedBinding(session)"),
     "a pane send on a probed-busy thread must go to the queue BEFORE any attach")
need("case .threadFree:\n                chatParkReason = nil" in chat_send,
     "a 409 thread_free must fall through to the ordinary pane send")
need("if let reason = lastAttachRefusalReason, Self.petQueueableReasons.contains(reason) {" in chat_send,
     "a busy attach in the pane no longer parks")
need("lastAttachRefusalReason = response.details[\"reason\"]?.string" in model,
     "the attach refusal reason is not kept for the park path")
need("if model.chatRefusal == nil, let hint = model.chatParkHint {" in activity_src,
     "the pane does not show the park hint")
hint_block = activity_src[activity_src.index("if model.chatRefusal == nil, let hint = model.chatParkHint {"):]
hint_block = hint_block[:hint_block.index("if let refusal = model.chatRefusal {")]
need('Button("Fork with this message") { model.forkChatThread() }' in hint_block and "if model.chatForkAvailable {" in hint_block,
     "Fork must stay available beside the park hint: parking is added, nothing removed")
need("chatForkAvailable = Self.chatCopyRecommendsFork(chatVerdict?.reasonCopy ?? \"\")" in chat_probe,
     "the park path must keep the Fork affordance the refusal offered")
parked_note = model[model.index("private func noteChatParked("):]
parked_note = parked_note[:parked_note.index("\n    }\n")]
need("chatParkReason = nil" in parked_note and "chatParkHint = nil" in parked_note,
     "a parked message must clear the stale park hint")
need('model.openClaudeRow?.provider == "codex"' in activity_src,
     "the composer's held-session line is not provider-aware for Codex")
# 0.5.238: the pet reads Codex rollouts and discovers open Codex threads and active Cursor composers.
pet_pipe = helper_src[helper_src.index("static func petLiveRows("):]
pet_pipe = pet_pipe[:pet_pipe.index("\n    }\n")]
need(pet_pipe.index("refreshClaudeTranscriptActivity(") < pet_pipe.index("refreshCodexRolloutActivity(") < pet_pipe.index("applyLiveWorkingState("),
     "the Codex rollout refresh must run after the Claude refresh (which clears turn keys) and before the working-state rule")
live_emit = helper_src[helper_src.index("private func emitLiveClaudeSessions("):]
live_emit = live_emit[:live_emit.index("\n    }\n")]
need("codexActivity: { id in" in live_emit and "discovered: discovered" in live_emit
     and "Self.codexOpenThreadIds(locksDir:" in live_emit,
     "session-pet-live does not read Codex rollouts or discover open threads")
need("openCodex.contains(id.lowercased()) || Date().timeIntervalSince(modified) <= Self.petUnfinishedMaxAge" in live_emit,
     "the pet must only read the markers of Codex threads that are open or recent")

# Result never swallowed: a card that closed mid-send reports as a notice.
settle_src = model[model.index("private func settlePetSend("):]
settle_src = settle_src[:settle_src.index("\n    }\n")]
need("petNotice = " in settle_src and "loadPetSessions()" in settle_src,
     "a settled send must reach the pet even with the card closed, and refresh the rows")
# ---- Meetings clock (0.5.234) --------------------------------------------
views_src = (root / "Sources/Views.swift").read_text()
adv = views_src[views_src.index('DisclosureGroup("Advanced")'):]
adv = adv[:adv.index("}.font(.caption)")]
need('Picker("Clock"' in adv and "model.setClockStyle($0)" in adv and "ClockStyle.allCases" in adv,
     "the clock picker is not under Advanced, or does not persist through the model")
meetings_src = (root / "Sources/ActivityMeetings.swift").read_text()
for _needle in ("meeting.subtitle(clock: model.clockStyle)", "hit.meeting.subtitle(clock: model.clockStyle)",
                "row.subtitle(clock: model.clockStyle)", "side.line(clock: model.clockStyle)"):
    need(_needle in meetings_src, f"a Meetings surface draws the wire clock: {_needle} missing")
need("meeting.dateLine(clock: model.clockStyle)" in (root / "Sources/ActivityWindow.swift").read_text(),
     "Meetings to review draws the wire clock")
need('UserDefaults.standard.set(style.rawValue, forKey: ClockStyle.defaultsKey)' in model,
     "the clock choice does not persist")
print("    pet composer and Meetings clock pins passed (0.5.234)")

LEDGCHK

# Terminal jump routing (0.5.141)
/usr/bin/python3 - "$ROOT" <<'JUMPRT'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
model = (root / "Sources/ControllerModel.swift").read_text()
models = (root / "Sources/Models.swift").read_text()
def need(c, m):
    if not c: sys.exit(f"terminal-jump: {m}")

jump = model[model.index("private func jumpFromReveal("):]
jump = jump[:jump.index("private func revealClaudeSession")]
# The terminal branch decides BEFORE the Desktop sidebar branch, and it
# TERMINATES: the one legal open([folder] is the generic tail, after it.
need(jump.index("PetJumpRoute.route(") < jump.index('openMode == "session"'),
     "the terminal route must be consulted before the Desktop sidebar branch")
need(jump.count("open([folder]") == 1,
     "exactly one folder-open belongs in jumpFromReveal (the generic app tail)")
need(jump.index("activateHostAppQuietly(") < jump.index("open([folder]"),
     "the terminal branch must terminate before the folder-open tail")
need("procStartMatches" in jump, "the recycled-pid gate is not consulted")
need("postPetTerminalHint(" in jump,
     "terminal success must use the non-attention hint channel")
branch = jump[jump.index("PetJumpRoute.route("):jump.index('openMode == "session"')]
need('petNotice = "Opened' not in branch,
     "a SUCCESS through petNotice ignites the attention blade for 12s")
need(branch.count("return") >= 2,
     "the terminal branch and the no-host branch must both TERMINATE; a "
     "fall-through reaches the folder-open tail")

# The walk moved out of activateProcess so routing can classify before acting.
act = model[model.index("func activateProcess("):]
act = act[:act.index("\n    }")]
need("for _ in 0..<12" not in act, "activateProcess should delegate to resolveHostApp")
resolve = model[model.index("func resolveHostApp("):]
resolve = resolve[:resolve.index("\n    }")]
need("for _ in 0..<12" in resolve and "NSRunningApplication(processIdentifier: pid)" in resolve,
     "resolveHostApp must keep BOTH success paths of the original walk")
quiet = model[model.index("private func activateHostAppQuietly("):]
quiet = quiet[:quiet.index("\n    }")]
need("sendReopenEvent" not in quiet and "activateAllWindows" not in quiet,
     "the quiet activator must send no Apple Event and raise no extra windows")

# The falsification, pinned in source as well as in the executable matrix.
need('"com.googlecode.iterm2"' in models and '"com.apple.Terminal"' in models,
     "the terminal allowlist lost a member")
need("terminalHostBundleIds" in models, "the allowlist constant was renamed")
JUMPRT

# --- Recent learning and Knowledge (0.5.190, server 6.44.5) --------------------
# Same discipline as the context routes above: every opener is tied to its
# render condition, every new count is an optional, and the things this build
# deliberately does NOT ship (a Dismiss, an explorer web view) are asserted absent.
/usr/bin/python3 - "$ROOT" <<'LEARNCHK'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
activity = (root / "Sources/ActivityWindow.swift").read_text()
views = (root / "Sources/Views.swift").read_text()
model = (root / "Sources/ControllerModel.swift").read_text()
models = (root / "Sources/Models.swift").read_text()
helper = (root / "HelperSources/main.swift").read_text()
release = (root / "scripts/build-release.sh").read_text()
app = (root / "Sources/COSControlApp.swift").read_text()

def need(condition, message):
    if not condition:
        sys.exit(f"learning wiring: {message}")

# 1. Routes: the flag reads the var the opener writes, and the pane is gated on it.
for flag, var, opener, pane in (
    ("learningRouteActive", "learningDetail", "openLearningEvent", "LearningDetailPane"),
    ("graphRouteActive", "graphEntity", "openGraphEntity", "GraphEntityPane"),
):
    route = re.search(r"var %s: Bool \{[^}]*\}" % flag, model, re.S)
    need(route is not None, f"{flag} not found")
    need(re.search(r"\b%s\b" % var, route.group(0)) is not None, f"{flag} does not read {var} itself")
    fn = re.search(r"func %s\(_ [^)]*\) \{.*?\n    \}" % opener, model, re.S)
    need(fn is not None, f"{opener} not found")
    need(re.search(r"\n\s+%s = " % var, fn.group(0)) is not None, f"{opener} never assigns {var}, so the route can never activate")
    need(re.search(r"if model\.%s\s*\{\s*%s\(" % (flag, pane), activity) is not None, f"{pane} is not gated on model.{flag}")
need("selectedLearningID != nil" in activity and "selectedGraphEntityID != nil" in activity,
     "learning and graph details have no window-local selection gate")

# 2. The picker exists, Knowledge is a peer segment, and switching clears all three selections.
need('Picker("Memories view", selection: $memoriesSubview)' in activity, "the Memories picker is missing")
need(re.search(r"case knowledge\b", activity) is not None and "case toReview" in activity and "case recentLearning" in activity,
     "MemoriesSubview lost a segment")
on_change = re.search(r"\.onChange\(of: memoriesSubview\) \{ _, next in(.*?)\n                \}", activity, re.S)
need(on_change is not None, "the Memories picker has no onChange")
for cleared in ("selectedContextID = nil", "selectedLearningID = nil", "selectedGraphEntityID = nil"):
    need(cleared in on_change.group(1), f"switching Memories views does not clear {cleared.split(' ')[0]}")

# 3. No new count decodes with `?? 0`. Enumerated BY NAME, one physical line each,
#    because thirteen pre-existing `?.int ?? 0` sites are legitimate. A mutation that
#    adds `?? 0` to any of these fails here (proved on 2026-09-06).
for name in ("learningCount", "learningToReview", "learningPatterns", "learningTaskProposals",
             "graphEntities", "graphRelationships", "graphQueuePending"):
    line = re.search(r'^\s+%s = details\["%s"\]\?\.int(.*)$' % (name, name), models, re.M)
    need(line is not None, f"ServerStatus does not decode {name} from its own key")
    need("??" not in line.group(1), f"{name} decodes with a default; a count has no safe scalar default")
for name in ("needsYou", "newest"):
    line = re.search(r'^\s+%s: o\["%s"\]\?\.(int|string)(.*)$' % (name, name), models, re.M)
    need(line is not None, f"ActivitySignals.Mark does not decode {name}")
    need("??" not in line.group(2), f"signal {name} decodes with a default")
need(re.search(r"graphSearchTotal = response\.details\[\"total\"\]\?\.int$", model, re.M) is not None,
     "graph search total decodes with a default")

# 4. Nothing this build must not ship: no Dismiss in the Memories pane, no explorer
#    web view, no explorer assets in the release script or the resources.
def between(text, start, stop):
    # An ordered slice: reordering the anchors made a bare a:b slice empty and
    # every "not in" below pass vacuously (QA 2026-09-06).
    a, b = text.index(start), text.index(stop)
    need(a < b, f"anchor order: {start!r} must precede {stop!r}")
    return text[a:b]
memories_pane = between(activity, "private func memoriesPane()", "private func contextList(kind: String)")
need("Dismiss" not in memories_pane and "dismiss" not in memories_pane, "0.5.190 is read-only; the Memories pane must carry no Dismiss")
learning_pane = between(views, "struct LearningDetailPane", "struct GraphEntityPane")
need("Dismiss" not in learning_pane, "the lesson detail must carry no Dismiss in 0.5.190")
# 0.5.191 (Miles, 2026-09-06 21:39): the Memories tab hosts the REVIEWED prototype on
# live data, explorer included. Plan v8's X2 (no web view) is superseded by that
# decision. The web view is confined to the Memories host; the page never sees the
# token; every op it may post is allowlisted to a read command or a native action.
need("import WebKit" in activity and "import WebKit" not in views, "the web view belongs to the Memories host only")
need("struct MemoriesWebView: NSViewRepresentable" in activity and "case .memories: memoriesSurface()" in activity,
     "Memories must mount the reviewed page")
need("if MemoriesWebView.bundleURL != nil {" in activity and "memoriesPane()" in activity, "the native panes must remain the fallback")
for asset in ("memories.html", "memories-app.js", "graph-explorer.js", "graph-explorer.css", "memories-theme.css", "d3.min.js"):
    need((root / "Resources/memories" / asset).exists(), f"Resources/memories/{asset} is missing")
    need(f'"$ROOT/Resources/memories/{asset}"' in release, f"build-release.sh does not copy {asset}")
bundle = "".join((root / "Resources/memories" / a).read_text(errors="ignore") for a in ("memories.html", "memories-app.js", "graph-explorer.js"))
need("X-Cos-Token" not in bundle and "X-COS-Token" not in bundle and "COS_API_TOKEN" not in bundle, "the page must never carry the token")
need("fetch(endpoint + path" in (root / "Resources/memories/graph-explorer.js").read_text() and "fetchActual.request" in (root / "Resources/memories/graph-explorer.js").read_text(),
     "the explorer must accept the host transport")
need('configuration.userContentController.add(context.coordinator, name: "cos")' in activity, "the bridge handler is not registered")
ops = between(activity, "static let helperOps: [String: ([String: Any]) -> [String]] = [", "    static func bounded(")
for forbidden in ("install", "update", "rollback", "reconcile", "adopt", "set-", "task-run", "fence-release", "graph-index-build\"] ", "context-graph-index-build\"]"):
    pass
for verb in ('"install"', '"update"', '"rollback"', '"reconcile"', '"adopt"', '"set-', '"task-', '"fence-release"', '"meeting-'):
    need(verb not in ops, f"the page op table must never reach {verb}")
need('"graph.build": { _ in ["context-graph-index-build"] }' in ops, "the index-build kickoff op is gone")
# The two kickoffs are the only writes besides a review decision: the ingest op
# is bounded to the server's 50 and reaches nothing but its own helper command.
need('"graph.ingest": { a in ["context-graph-ingest", "--limit", MemoriesWebView.bounded(a["limit"], 10, 1, 50)] }' in ops,
     "the queue-ingest kickoff must be a bounded op")
need(ops.count('"context-graph-ingest"') == 1 and ops.count('"context-graph-index-build"') == 1, "each kickoff command appears once in the op table")
need('case "context-graph-ingest": try emitContextGraphIngest(args: args)' in helper and 'static let ingestNeeds = "6.44.8"' in helper
     and 'needs: Self.ingestNeeds, accepted: [202]' in helper and 'where text.contains("not_owner")' in helper,
     "the ingest command must name 6.44.8, accept only 202, and turn not_owner into a sentence")
need("cosApp.startIngest()" in (root / "Resources/memories/memories-app.js").read_text() and "'graph.ingest'" in (root / "Resources/memories/memories-app.js").read_text(),
     "the Sync card must offer Index now through the graph.ingest op")
need('"learning.decide": { a in ["context-learning-decide"' in ops, "Dismiss must go through the decide command")
need('reply(id, ok: false, message: "This page cannot ask for \\(op).", details: [:])' in activity, "an unknown op must be refused")
# The graph opens on the person this COS is about: status carries the profile's
# owner_name (masked in the redacted report), and the page resolves it through a
# search before falling back to COS; a focus the user picks is never overridden.
need('details["ownerName"] = profileOwnerName() ?? NSNull()' in helper and 'static func ownerName(fromProfileJSON data: Data) -> String?' in helper,
     "status must carry the profile owner name")
need('copy["ownerName"] = "<owner>"' in helper, "the redacted report must mask the owner name")
page = (root / "Resources/memories/memories-app.js").read_text()
need("function chooseDefaultFocus()" in page and "state.status.ownerName" in page and "graphFocusChosen" in page,
     "the page must default the graph focus to the owner and keep a chosen focus")
need(page.count("state.graphFocusChosen = true") >= 3, "recenter, Focus and Explore in graph must all mark the focus as chosen")
# 0.5.193: the native panes use the brand type and the shared surface styles,
# so no pane row or header falls back to the system font; the only system-font
# line a row may keep is the chevron glyph.
brand = (root / "Sources/COSBrand.swift").read_text()
need("struct COSStat: View" in brand and "struct COSQuietButtonStyle: ButtonStyle" in brand and "struct COSPrimaryButtonStyle: ButtonStyle" in brand
     and "func cosRowCard() -> some View" in brand and "func cosField() -> some View" in brand, "the shared surface styles are gone")
header = between(activity, "    private func sectionHeader<Accessory: View>(", "    /// The section mark inside an open pane.")
need("COSType.display(24, weight: .medium)" in header and "COSStat(value: stat.value, label: stat.label)" in header and ".font(.system(" not in header,
     "the pane header must set its title in Fraunces with a stat strip and no system font")
for name, start, end in (("sessionRow", "    private func sessionRow(", "    private var sessionsStatus: String {"),
                         ("contextRow", "    private func contextRow(", "    private func sectionHeader("),
                         ("taskRow", "    private func taskRow(", "    /// Keeps `taskDomain` inside the resolved list.")):
    row = between(activity, start, end)
    need(".cosRowCard()" in row, f"{name} is not a card")
    need(row.count(".font(.system(size:") == row.count('Image(systemName: "chevron.right")'), f"{name} still sets prose in the system font")
need("stats: meetingsStats" in activity and "stats: sessionsStats" in activity and "stats: tasksStats" in activity, "each pane must pass its stat strip")
meetings_src = (root / "Sources/ActivityMeetings.swift").read_text()
# 3 from 0.5.230: the library row, the search hit, and the suggestion row. The
# rule is "cards in a shared scroll list, never a List"; the count is how it is
# expressed, so a new row surface raises it rather than relaxing it.
need(meetings_src.count(".cosRowCard()") == 3 and "List(" not in meetings_src, "the meeting rows must be cards in the shared scroll list, not a List")
need("COSType.display(22, weight: .medium)" in meetings_src and "COSType.display(15, weight: .medium)" in meetings_src, "the meeting detail title and the calendar month must be Fraunces")
need("Search topics, ideas" in meetings_src, "the meetings search placeholder changed")
# 0.5.194: the Knowledge setup path. Six bounded ops plus one native folder
# picker; the helper names 6.44.9 and turns a not_owner refusal into a sentence.
for op in ('"graph.setup": { _ in ["context-graph-setup"] }',
           '"graph.setup.sources": { a in ["context-graph-setup-sources", "--action", MemoriesWebView.text(a["action"], 8), "--path", MemoriesWebView.text(a["path"], 1000)] }',
           '"graph.setup.owner": { _ in ["context-graph-setup-owner"] }',
           '"graph.sample": { a in ["context-graph-ingest-sample", "--limit", MemoriesWebView.bounded(a["limit"], 3, 1, 3)] }',
           '"graph.ask": { a in ["context-graph-ask", "--q", MemoriesWebView.text(a["q"], 400)] }',
           '"graph.schedule": { a in ["context-graph-schedule", "--enabled"'):
    need(op in ops, f"the setup op table lost {op[:24]}")
need('case "pick.folder":' in activity and "panel.canChooseFiles = false" in activity and "panel.allowsMultipleSelection = false" in activity,
     "the folder picker must pick one folder and never a file")
need('static let setupNeeds = "6.44.9"' in helper and "case 404 where klass == nil:" in helper and "klass == \"not_owner\" ? Self.setupOwnerMessage" in helper,
     "the setup requests must name 6.44.9, keep a classed 404 apart from a missing route, and word not_owner")
for command in ("context-graph-setup", "context-graph-setup-sources", "context-graph-setup-owner", "context-graph-ingest-sample", "context-graph-ask", "context-graph-schedule"):
    need(f'case "{command}":' in helper, f"helper dispatch lost {command}")
setup_page = (root / "Resources/memories/memories-app.js").read_text()
need('"graph.progress": { _ in ["context-graph-ingest-progress"] }' in ops and 'case "context-graph-ingest-progress":' in helper
     and 'static let progressNeeds = "6.44.10"' in helper, "the progress op and command must exist and name 6.44.10")
need("cosApp.viewAs" not in (root / "Resources/memories/memories-app.js").read_text() and "the Air" not in (root / "Resources/memories/memories-app.js").read_text(),
     "the Sync card must not carry a one-desk View as toggle (0.5.197)")
need('"graph.setup.embedding": { a in' in ops and '"graph.setup.extraction": { a in ["context-graph-setup-extraction", "--tier", MemoriesWebView.text(a["tier"], 8)] }' in ops
     and 'case "context-graph-setup-embedding":' in helper and 'case "context-graph-setup-extraction":' in helper and 'static let choiceNeeds = "6.44.11"' in helper
     and helper.count("needs: Self.choiceNeeds)") == 1 and helper.count("needs: localOnly == nil ? Self.choiceNeeds : Self.preferenceNeeds)") == 1,
     "the embedding and extraction ops and commands must exist and name 6.44.11 (the embedding call gates on 6.44.12 only when local_only rides)")
mem_page = (root / "Resources/memories/memories-app.js").read_text()
need('"memory.review": { a in' in ops and '"memory.guardrails": { _ in ["context-memory-guardrails"] }' in ops and '"memory.guardrails.set": { a in' in ops and '"memory.guardrails.run": { a in' in ops,
     "the memory review and guardrails ops must exist")
for command in ("context-memory-review", "context-memory-guardrails", "context-memory-guardrails-run"):
    need(f'case "{command}":' in helper, f"helper dispatch lost {command}")
need('static let guardrailNeeds = "6.44.13"' in helper and 'decision == "accept" || decision == "prune"' in helper, "memory review must name 6.44.13 and refuse any other decision")
need("function askBlockInner(" in mem_page and "cosApp.askGraphGo()" in mem_page and "askGraphAbout(" in mem_page, "the graph pane must offer a plain-language ask from the focus")
need("function askProgressHtml(" in mem_page and "startAskTick" in mem_page and 'data-role="ask-progress-copy"' in mem_page
     and "function askBusyCopy(" in mem_page and "Searching the graph" in mem_page and "if (state.askBusy) return;" in mem_page,
     "Ask must show a live spinner and elapsed status while the graph question runs")
need(".cgx-panel{isolation:isolate" in (root / "Resources/memories/graph-explorer.css").read_text()
     and "backdrop-filter:none;-webkit-backdrop-filter:none" in (root / "Resources/memories/graph-explorer.css").read_text(),
     "graph rail labels must not use backdrop blur")
theme_css = (root / "Resources/memories/memories-theme.css").read_text()
need('href="graph-explorer.css"' in (root / "Resources/memories/memories.html").read_text()
     and 'href="memories-theme.css"' in (root / "Resources/memories/memories.html").read_text()
     and ".ask-progress" in theme_css
     and ".ask-spin" in theme_css
     and ".ask-refs" in theme_css,
     "Ask progress styles must load from the Memories theme")
# 0.5.213: Recent learning modal above graph rail; Index now hairline; Real records navigates.
need("#modalRoot{position:relative;z-index:300}" in theme_css
     and ".modal-backdrop{position:fixed;inset:0;z-index:300;background:rgba(16,12,9,.84)" in theme_css
     and ".cgx-stage{isolation:isolate}" in theme_css
     and "body.modal-open .cgx-rail" in theme_css
     and "body:has(#modalRoot .modal-backdrop) .cgx-rail" in theme_css,
     "the learning modal must stack above the graph rail with an opaque backdrop")
need("document.body.classList.add('modal-open')" in mem_page
     and "document.body.classList.remove('modal-open')" in mem_page,
     "opening a modal must mark the body so graph chrome can hide")
need("'the next ' + n" not in mem_page
     and 'label for="ingestLimit">Batch size</label>' in mem_page
     and 'class="ingest-pending">' in mem_page
     and "fmt(pendingN) + ' pending</span>" in mem_page
     and 'class="hairline" onclick="cosApp.startIngest()"' in mem_page
     and 'button class="quiet" onclick="cosApp.startIngest()"' not in mem_page,
     "INDEXING must name pending count and batch size, not 'the next N'")
need("button.hairline{background:var(--card);border:1px solid var(--line)" in theme_css
     and ".sync-card .ingest-control button.hairline" in theme_css,
     "Index now must carry a --line hairline on the white Sync card")
need("function openSourceRecords()" in mem_page
     and "state.knowledgeTab = 'sources'" in mem_page
     and 'data-role="real-records"' in mem_page
     and "cosApp.openSourceRecords()" in mem_page
     and 'id="sourceRecords"' in mem_page
     and "openSourceRecords: openSourceRecords" in mem_page,
     "Real records must navigate to the source records surface")
need("func overlayIdleMeetingWork(" in helper and "applyIdleMeetingWorkOverlay" in helper
     and "Self.jsonInt(details[\"meetingFinalizationPending\"])" in helper
     and "displayedMeetingSync" in (root / "Sources/Models.swift").read_text()
     and "meetingWorkBlockingRestart" in (root / "Sources/Models.swift").read_text()
     and 'Button("Update Server")' in (root / "Sources/Views.swift").read_text()
     and "|| model.status.meetingWorkBlockingRestart" in (root / "Sources/Views.swift").read_text()
     and "applyIdleMeetingWorkOverlay(&fields)" in helper,
     "Idle meeting work must overlay library handoff, block Restart/Update, and refuse sync-now")
need("function renderMarkdown(" in mem_page and "function askEntityCard(" in mem_page and "cosApp.copyAsk(" in mem_page and "askEntityPassages(" in mem_page,
     "the answer must render, copy, and hand back entity cards with passages")
need("function parseAskAnswer(" in mem_page and "ask-ref-" in mem_page and "Evidence references:" in mem_page
     and r"/\[(S?\d+)\]/g" in mem_page,
     "Ask must turn [S#] into source links and render the evidence footer as a Sources list")
need("var lines = esc(md || '').split(" in mem_page, "the answer renderer must escape before it marks up")
need("function whenLabel(" in mem_page and "n < 1e11 ? n * 1000 : n" in mem_page, "the card must turn epoch seconds into a date")
need("function memoryActions(" in mem_page and "'memory.review'" in mem_page and "function guardrailsSection(" in mem_page and "'memory.guardrails.run'" in mem_page,
     "the page must offer Accept and Prune on a captured memory and the guardrails in settings")
explorer_src = (root / "Resources/memories/graph-explorer.js").read_text()
# 0.5.206: the helper names skipped review rows with their source; Control composes the reason from them.
need('"skippedRows": skippedRows,' in helper and 'static func isG2Source(_ source: String) -> Bool' in helper, "the meetings command must report skipped rows and their source")
model_src = (root / "Sources/ControllerModel.swift").read_text()
need('static func skippedReviewSentence(skipped: Int, rows: [[String: JSONValue]]) -> String' in model_src and 'skippedRows: skippedRows' in model_src
     and 'have no session id and cannot be reviewed' not in model_src, "the empty state must name skipped meetings by source and title, never the bare no-session-id sentence")
# 0.5.205: the Manage sheet's merge runs for real behind a second, owner-Mac preview and a polled receipt; duplicates only propose.
need('"graph.merge.preview": { a in' in ops and '"graph.merge": { a in' in ops and 'if (a["confirm"] as? Bool) == true { cmd.append("--confirm") }' in ops
     and '"graph.merge.status": { _ in ["context-graph-merge-status"] }' in ops and '"graph.duplicates": { a in' in ops,
     "the merge preview, merge, merge status and duplicates ops must exist and pass confirm only as a boolean")
for command in ("context-graph-merge-preview", "context-graph-merge", "context-graph-merge-status", "context-graph-duplicates"):
    need(f'case "{command}":' in helper, f"helper dispatch lost {command}")
need('static let mergeNeeds = "6.44.14"' in helper and helper.count("needs: Self.mergeNeeds)") == 4
     and 'guard args.contains("--confirm") else { throw HelperError.message("--confirm is required' in helper,
     "the four merge commands must name 6.44.14 and the helper must refuse a merge without --confirm")
need("function mergeFlow(" in mem_page and "'graph.merge.preview'" in mem_page and "'graph.merge'" in mem_page and "confirm: true" in mem_page
     and "'graph.merge.status'" in mem_page and "function pollMerge(" in mem_page and "if (pv.blocked) { finishMerge(false" in mem_page,
     "the page must preview, confirm, start and poll a merge, and undo a blocked one")
need("return mergeFlow(change.source, change.target" in mem_page and "if (change.op !== 'merge')" in mem_page,
     "the explorer's Manage sheet must hand a merge to the page and refuse rename and remove")
need("function duplicatesCard(" in mem_page and "'graph.duplicates'" in mem_page and "cosApp.mergeFrom(" in mem_page,
     "the page must offer the duplicates scan with Preview merge per member")
need("if (verdict === false) { undoChange(change); change.status = 'refused'" in explorer_src and "verdict.then(function (ok) { if (ok === false) { undoChange(change)" in explorer_src,
     "the explorer must undo a change the host refuses or fails")
need("function embeddingCards(" in (root / "Resources/memories/memories-app.js").read_text() and "'graph.setup.embedding'" in (root / "Resources/memories/memories-app.js").read_text()
     and "'graph.setup.extraction'" in (root / "Resources/memories/memories-app.js").read_text(),
     "the page must render the embedding and extraction pickers")
# 0.5.200: the down-select. The op passes local_only alone, the helper names 6.44.12 for it, the page asks the one
# question, marks Recommended, and the Index button fails closed with the fix when the chosen embedding is not ready.
need('if let localOnly = a["local_only"] as? Bool { cmd += ["--local-only", localOnly ? "true" : "false"] }' in ops
     and 'if let provider = a["provider"] as? String, !provider.isEmpty { cmd += ["--provider"' in ops,
     "the embedding op must pass local_only and treat provider as optional (0.5.200)")
need('static let preferenceNeeds = "6.44.12"' in helper and 'needs: localOnly == nil ? Self.choiceNeeds : Self.preferenceNeeds' in helper
     and 'throw HelperError.message("--provider and/or --local-only true|false is required")' in helper
     and 'where preferenceOnly && text.hasPrefix("provider must be one of")' in helper,
     "the helper must name 6.44.12 for local_only, refuse a call with neither flag, and translate a 6.44.11 server's 400")
need("function localOnlyStrip(" in setup_page and "cosApp.answerLocalOnly(" in setup_page and "answerLocalOnly: function (localOnly)" in setup_page
     and "{ local_only: localOnly === true }" in setup_page and "May your text leave this Mac for embeddings?" in setup_page
     and 'pick-badge">Recommended<' in setup_page and "Recommended: ' + esc(rec.label)" in setup_page
     and "localOnlyStrip(embBlock, busy) + embeddingCards(embBlock, busy)" in setup_page,
     "the page must ask the one question, post local_only alone, and mark the Recommended card")
need("var embNotReady = embBlock.ready === false;" in setup_page and "busy || !checksOk || embNotReady ? 'disabled' : ''" in setup_page
     and "Blocked: ' + esc(embBlock.label || embBlock.provider) + ' is not ready. ' + esc(embBlock.fix || '')" in setup_page
     and "embBlock.mismatch || embNotReady ? 'blocked' : 'todo'" in setup_page and "is chosen but not ready on this Mac. ' + esc(emb.fix || '')" in setup_page,
     "a not-ready embedding must block Index with the fix named, in step 4 and on the button")
need("The recommendation needs server 6.44.12." in setup_page, "an older server must be named, never a blank strip")
need("function progressBlock(" in (root / "Resources/memories/memories-app.js").read_text() and "'graph.progress'" in (root / "Resources/memories/memories-app.js").read_text(),
     "the page must render progress from the graph.progress op")
need("function setupDetail(" in setup_page and "'graph.setup'" in setup_page and "'pick.folder'" in setup_page and "'graph.ask'" in setup_page,
     "the page must render the setup path from the graph.setup op with the folder picker and the question")

# 5. Every list fed by server state in the entity pane is capped by COUNT with a
#    Show all button, inside the pane's one ScrollView; nested scrolls are gone.
entity_pane = between(views, "struct GraphEntityPane", "struct ChipFlowLayout")
for pair, toggle in (("graphRel", "showAllRelationships"), ("graphMention", "showAllMentions")):
    need(f"private static let {pair}InlineRowLimit" in entity_pane, f"{pair} list has no inline limit")
    need(f"prefix(Self.{pair}InlineRowLimit)" in entity_pane and f"{toggle}.toggle()" in entity_pane,
         f"{pair} list is not capped by count with a Show all toggle")
need(entity_pane.count("ScrollView {") == 1, "the entity pane must have exactly one ScrollView (no nested scrolls)")
need("lineLimit(showAllDescriptions ? nil : Self.descriptionLineLimit)" in entity_pane, "descriptions are not length-capped")

# 6. Helper: the GET wrapper takes `needs:` and its 404 branch passes it into the
#    message that interpolates it; the GET wrapper still maps 202 to "Server
#    stopped"; the mutate wrapper accepts 202 and nothing else; the memory and
#    threads 503 sentence is byte-identical through the default parameter.
browse = helper[helper.index("private func contextBrowseResponse("):helper.index("private func contextRecordPath(")]
need("needs: String? = nil" in browse, "contextBrowseResponse lost its needs parameter (nil default keeps memory/threads 404s honest)")
need(re.search(r"if response\.status == 404, let needs \{\s*throw HelperError\.message\(Self\.learningNotFoundMessage\(errorClass: [^,]+, needs: needs\)\)", browse) is not None,
     "the 404 branch does not pass needs into the message")
need('default: return "Update the managed server to \\(needs) or newer to see recent learning and knowledge."' in helper,
     "learningNotFoundMessage does not interpolate needs")
need('guard response.status == 200 else { throw HelperError.message("Server stopped") }' in browse,
     "the GET wrapper no longer rejects 202 as Server stopped")
mutate = helper[helper.index("private func contextMutateResponse("):helper.index("// ── Recent learning and Knowledge (server 6.44.5")]
need("accepted: Set<Int> = [202]" in mutate and "guard accepted.contains(response.status) else" in mutate,
     "contextMutateResponse must accept exactly 202 by default; a caller widens it per route (the review route answers 200)")
need('"Server stopped"' not in mutate.split("if response.status == 404")[1], "the mutate wrapper says Server stopped after a 404 or a refusal")
need('throw HelperError.message("Update the managed server to \\(needs) or newer for this (\\(route) is not there).")' in mutate,
     "the mutate wrapper's own 404 does not name the version that ships the route")
need("guard accepted.contains(response.status) else" in mutate and "return response.body ?? [:]" in mutate,
     "a bare 202 with no body must still count as accepted")
need('static let contextNotConfiguredMessage = "Memory and Threads are not set up yet. Use Create Folders."' in helper
     and "notConfiguredMessage: String = COSControlHelper.contextNotConfiguredMessage" in browse,
     "the memory/threads 503 sentence changed")
for command in ("context-learning", "context-learning-status", "context-graph-status", "context-graph-search",
                "context-graph-entity", "context-graph-passages", "context-graph-index-build", "context-graph-ingest", "activity-signals"):
    need(f'case "{command}":' in helper, f"helper dispatch lost {command}")
need("details.merge(Self.learningStatusDetails(enrichLearningWithNeedsYou(context)))" in helper, "status details lost the learning rows")
need('add("Recent learning and Knowledge", line.state, line.detail)' in helper, "Doctor (and so redactedReport) lost the learning line")
redacted_block = between(helper, "        var status = details\n        if redacted {", '        return ["checks": checks, "status": status]')
need("status = Self.redactedStatusDetails(status)" in redacted_block, "the redacted report does not mask the graph owner hostname")
need('case "index_missing": return "No knowledge index on this Mac yet. Build it from the Sync card."' in helper,
     "a missing index must point at Build index")
need('or run Doctor' not in helper.split("static func contextUnavailableMessage")[1].split("}")[0],
     "an unavailable class must not send the user to Doctor")
need('if args.contains("--to-review")' in helper and 'needs: Self.reviewNeeds' in helper and 'static let reviewNeeds = "6.44.6"' in helper,
     "To review must come from the strict-set route, naming 6.44.6")
need('case "context-learning-decide": try emitContextLearningDecide(args: args)' in helper and 'static let decideNeeds = "6.44.7"' in helper
     and 'needs: Self.decideNeeds, accepted: [200]' in helper,
     "Dismiss must go through the 6.44.7 review route with its own version and a 200 acceptance")
need('decision == "dismissed" || decision == "reopened"' in helper, "the helper must refuse any decision outside the ledger vocabulary")
# Quoted argv literals, so a comment naming the flag cannot trip this and a real
# execute(python, [..., "--build-index"]) cannot hide from it.
need('min(max(Int(option("--limit", in: args) ?? "30") ?? 30, 1), 30)  // the server and the bridge both cap at 30' in helper,
     "the helper's graph-entity limit must match the server's 30")
need("emitContextGraphIndexBuild" in helper and '"--build-index"' not in helper and '"--apply-curation"' not in helper
     and '"--process-queue"' not in helper,
     "the helper must only ask the server to spawn a build, never run the pipeline")

# 7. Activity signals: the legend line renders under the chips, every mark names its
#    source (self-tested in the helper), the chip reads number then dot, and opening
#    a section advances its cursor.
need("model.activitySignals?.legend" in views, "the chip legend is not rendered")
need("ChipFlowLayout(spacing: 7) {" in views and "struct ChipFlowLayout: Layout" in views, "the chips must wrap, not sit in two fixed rows")
need('Text(number > 99 ? "99+" : "\\(number)")' in views, "a chip number is not clamped to 99+")
need("model.activitySignalsError" in views, "a failed signals call is invisible")
need("model.activityNumber(item)" in views and "model.activityDot(item)" in views, "chips do not read the two marks")
select_fn = between(activity, "private func select(_ next: ActivitySection)", "private func goHome()")
need("model.markActivityOpened(next)" in select_fn, "opening a section does not advance its cursor")
need("pendingActivityOpens" in model and "for section in pending { markActivityOpened(section) }" in model,
     "a section opened before the first signals answer must advance its cursor when it lands")
need('"legend": activitySignalsLegend' in helper and "Number = needs you" in helper, "the helper does not ship the legend")

# 8. The Sync card renders inside a ScrollView and carries the owner line.
knowledge = between(activity, "private func knowledgePane()", "private var graphSearchBar")
need("syncCard" in knowledge.split("ScrollView {", 1)[1] if "ScrollView {" in knowledge else False,
     "the Sync card is not inside a ScrollView")
need('syncRow("Topology", topologyLine(g))' in activity, "the Sync card lost its owner line")
need('"No processor configured on this Mac"' in models and '"Processor installed, no run recorded yet"' in models,
     "the two processor sentences are gone")
# The Activity home tile: title and metric on one line when the pair fits, the
# metric under the title when it does not; never a mid-word break, never a
# truncated "Meeti…". A four-column tile row is ~168 pt at the default window
# and ~133 pt at the 760 pt minimum; "Meetings" + "2,346" need ~160 (2026-09-06).
home_card = between(activity, "private func activityHomeCard(_ item: ActivitySection, index: Int)", "private func homeMetric(")
need("ViewThatFits(in: .horizontal)" in home_card, "the home tile header must use ViewThatFits, not a fixed HStack")
title_chain = home_card[home_card.index("let title = Text(item.title)"):home_card.index("let metric = Text(")]
need(".lineLimit(1)" in title_chain and ".fixedSize()" in title_chain, "the tile title must be one whole line (lineLimit(1) + fixedSize())")
need("minimumScaleFactor" not in title_chain and "truncationMode" not in title_chain, "the tile title must not scale or truncate; the metric drops instead")
metric_chain = home_card[home_card.index("let metric = Text("):home_card.index("return VStack(alignment: .leading, spacing: 8)")]
need(".lineLimit(1)" in metric_chain and ".fixedSize()" in metric_chain, "the tile metric must never shrink or wrap")
need(home_card.count("metric\n") == 2 and home_card.count("title\n") == 2, "both ViewThatFits branches must render the same title and metric views")
# The Activity hotkey (0.5.190): Carbon registration (no Accessibility grant),
# wired at launch to the same presenter the chips use, persisted with the
# combo, recorded in the panel, and never a modifier-less chord.
need("RegisterEventHotKey(combo.keyCode, combo.modifiers" in views and "UnregisterEventHotKey(hotKeyRef)" in views,
     "the hotkey must register through Carbon and unregister the previous chord")
need("addGlobalMonitorForEvents" not in views, "a global NSEvent monitor would need an Accessibility grant; Carbon does not")
need("HotKeyCenter.shared.onFire = { activityWindow.show(model: model, section: nil) }" in app
     and "HotKeyCenter.shared.register(model.activityHotKey)" in app,
     "the hotkey is not wired to the Activity presenter at launch")
setter = between(model, "func setActivityHotKey(_ combo: HotKeyCombo?)", "func setLaunchAtLogin(")
need("HotKeyCombo.save(combo)" in setter and "HotKeyCenter.shared.register(combo)" in setter,
     "setting the hotkey must persist AND re-register in the same step")
need("HotKeyRecorderRow(model: model)" in views, "the panel has no hotkey recorder")
need("guard modifiers & (Self.command | Self.control | Self.option) != 0 else { return nil }" in models,
     "a chord without Command, Control or Option must be refused")
need('"Build index (usually a few seconds)"' in activity, "the Sync card does not offer the build (and must not quote an unmeasured 30 s)")
need('model.graphBuildState == "unknown"' in activity, "the poll giving up must leave the Build button reachable")
need("g.isOwner" not in activity.split('Button("Build index')[0].rsplit("if g.invitesIndexBuild", 1)[1],
     "a replica builds its own per-Mac index; the button must not be owner-gated")
LEARNCHK

# --- 0.5.214 Sessions first paint: cache + mtime index, no week-scan gate ---
/usr/bin/python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
helper = (root / "HelperSources/main.swift").read_text()
model = (root / "Sources/ControllerModel.swift").read_text()
activity = (root / "Sources/ActivityWindow.swift").read_text()
models = (root / "Sources/Models.swift").read_text()
contract = (root / "Tests/ModelsContract.swift").read_text()

def fail(msg):
    sys.exit(msg)

if "struct SessionListCache" not in models:
    fail("SessionListCache is missing")
if "static func indexDropped(" not in models:
    fail("cap/older counts must be computed from mtime/size, not transcript bodies")
if "FileHandle" in models[models.index("struct SessionListCache"):models.index("enum SessionClock")]:
    fail("SessionListCache must not open session bodies")
if "hydrateClaudeSessionsFromCache()" not in model:
    fail("ControllerModel must hydrate Sessions from cache before helper RPC")
init = model[model.index("init(startBackgroundWork: Bool = true) {"):model.index("func checkForAppUpdate(")]
if "hydrateClaudeSessionsFromCache()" not in init:
    fail("first paint must read the session cache in init, not after the week scan")
load = model[model.index("func loadClaudeSessions"):model.index("private func fetchClaudeSessions")]
if '["claude-sessions", "--quick"]' not in model:
    fail("empty first paint must use --quick, not wait for --fresh")
if '["claude-sessions", "--fresh"]' not in model:
    fail("Refresh / background fill must still run --fresh")
non_force = load[load.index("if claudeSessions.isEmpty"):]
gate = non_force.split("if claudeSessionsLoadInFlight")[0]
if "await fetchClaudeSessions(quick: false)" in gate:
    fail("non-force loadClaudeSessions must not await the full enumeration before returning")
if "claudeSessionsLoadInFlight == nil" not in load:
    fail("full week scan must be scheduled, not blocking first paint")
if "SessionListCache.staleAfter" not in load:
    fail("repeat visits must skip the week scan when the cache is still fresh")
if "checkSessionListCache()" not in contract:
    fail("ModelsContract must execute the cache and index-dropped contract")
if '"Refreshing…"' not in activity:
    fail("cached rows must show Refreshing, not freeze as a finished list")
if "loadClaudeSessions(force: true)" not in activity:
    fail("Sessions Refresh must force a fresh walk")
if "async let sessions" not in activity:
    fail("overview must start Sessions without waiting on the rest of the waterfall")
if "emitLiveClaudeSessions" not in helper or "/api/agent-sessions?limit=80" in helper[helper.index("private func emitLiveClaudeSessions"):helper.index("private func emitQuickClaudeSessions")]:
    fail("session-pet-live must not walk /api/agent-sessions")
if "FileHandle" in helper[helper.index("static func collectAgentSessionIndex"):helper.index("static func readSessionListCache")]:
    fail("the mtime index must not open transcript bodies")
print("COS Control: Sessions lazy cache + mtime index contract pinned")
PY

# --- 0.5.215 Memories chrome: needs_you chip, hide unobserved evidence ------
/usr/bin/python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
helper = (root / "HelperSources/main.swift").read_text()
page = (root / "Resources/memories/memories-app.js").read_text()

def fail(msg):
    sys.exit(msg)

fn = helper[helper.index("static func learningToReview"):helper.index("static func needsYouCount(from learning")]
body = fn.split("{", 1)[1]
if "to_review" in body or "task_proposals" in body or "patterns" in body:
    fail("learningToReview must not read the SIQ to_review split")
if "needsYouCount" not in body:
    fail("learningToReview must delegate to needsYouCount")
if 'learningToReview(["count": 7]) == 7' in helper:
    fail("bare count must not be a Needs-you number")
if 'fullStatus["learningToReview"] as? Int == 121' in helper or 'signal("memories", "needsYou") as? Int == 121' in helper:
    fail("helper self-test still pins the SIQ dump as the Memories number")
if "SIQ to_review must not become the Memories chip" not in helper:
    fail("helper self-test must refuse a SIQ-only learning block")
if "enrichLearningWithNeedsYou" not in helper or "learning_events.py" not in helper or '"needs-you"' not in helper:
    fail("status must overlay projector needs-you when the server strips it")

if "function needsYouCount()" not in page:
    fail("WK To review (N) must read needsYouCount")
if "state.reviewCount != null ? state.reviewCount" in page:
    fail("To review (N) must not prefer review_page matched_total / SIQ dump")
if "projected rows are not observed" in page:
    fail("empty evidence chrome must not ship the always-on unobserved badge")
if "No later retrieval, use, or result has been recorded" in page or "Next use" in page:
    fail("unobserved Next use must be hidden, not hardcoded empty")
if "function relatedUseRows(" not in page or "function useEventBody(" not in page:
    fail("captured card must render used/checked rows from the same lesson")
if "No check recorded" in page or "No repeat data" in page or "Scope not resolved on this Mac" in page:
    fail("unobserved Expected effect / Checks / Repeat rows must stay hidden")
print("COS Control: Memories needs-you chip + captured-card evidence contract pinned")
PY

# --- 0.5.216/0.5.217 reward chrome: Applied this week, kind passthrough, gated ranking sentence, path-aware empties ------
/usr/bin/python3 - "$ROOT" <<'PY'
from pathlib import Path
import re, sys
root = Path(sys.argv[1])
helper = (root / "HelperSources/main.swift").read_text()
page = (root / "Resources/memories/memories-app.js").read_text()
host = (root / "Sources/ActivityWindow.swift").read_text()

def fail(msg):
    sys.exit(msg)

# 1. The page can ask the helper for one projector kind; the host forwards only the closed vocabulary.
ops = host[host.index('"learning.list": { a in'):host.index('"learning.review"')]
if 'MemoriesWebView.learningKind(a["kind"])' not in ops or '"--kind"' not in ops:
    fail("helperOps learning.list must forward kind through learningKind")
if "static func learningKind(" not in host or 'learningKinds.contains' not in host:
    fail("learningKind must validate against the projector vocabulary")
if not re.search(r'static let learningKinds: Set<String> = \[[^\]]*"used"[^\]]*"checked"', host, re.S):
    fail("learningKinds must include used and checked")

# 2. Applied this week is its own helper window, never the first Recent page filtered in JS.
if "function loadApplied(" not in page or "{kind:'used',days:state.appliedDays" not in page:
    fail("Applied must call learning.list with kind used and its own day window")
applied_code = page[page.index("function loadApplied("):page.index("function setAppliedDays(")] + page[page.index("function renderApplied("):page.index("function renderMemories(")]
if "state.recent" in applied_code:
    fail("Applied must not read the loaded Recent page")
if page.count("state.applied=more?state.applied.concat(rows):rows") != 1 or "state.applied =" in page.replace("state.applied=more", ""):
    fail("loadApplied must be the only writer of state.applied")
if "['applied', 'Applied this week']" not in page or "function renderApplied(" not in page:
    fail("Applied this week must be a learning filter with its own renderer")
if "appliedDays: 7" not in page:
    fail("Applied defaults to a 7-day window")

# 3. Path-aware empties: bridge saw none; files / Knowledge cannot detect; unreadable trace invents nothing.
for sentence in ("This memory path cannot detect use.", "Knowledge citations are not lesson reward.",
                 "Retrieval without acknowledgment is not use.", "The use trace could not be read on this Mac.",
                 "Use has not been recorded on this Mac yet.", "Checking this install", "Could not read this Mac"):
    if sentence not in page:
        fail("missing path-aware empty state: " + sentence)
if "function memoryPath()" not in page:
    fail("the page must resolve the install's memory path before choosing Applied copy")

# 4. Reward chrome is a sentence gated on the projector flag, never a number.
if "function rewardEnabled()" not in page or "learningRewardEnabled === true" not in page:
    fail("the ranking sentence must be gated on the literal learningRewardEnabled flag")
if page.count("This lesson now ranks ahead of unused memories like it in later recall.") != 1:
    fail("the ranking sentence must live in exactly one place (rankingSentence)")
if page.count("rankingSentence()") < 3:
    fail("both cards must render the sentence through rankingSentence()")
for leak in ("+0.03", "+0.05", "-0.05", "reward_term", "REWARD_PENALTY", "moved later recall", "Reward on +", "rank behind"):
    if leak in page:
        fail("ranking magnitudes must never reach the page: " + leak)
if "static func learningRewardEnabled(" not in helper or '"learningRewardEnabled": learningRewardEnabled(learning) ?? NSNull()' not in helper:
    fail("helper status must expose learningRewardEnabled as a literal or NSNull")
overlay = helper[helper.index("private func runNeedsYouCLI()"):helper.index("static func parseJSONObject")]
if '"reward_enabled"' not in overlay:
    fail("the needs-you overlay key list must carry reward_enabled")
if 'helper.run(["status"], timeout:' not in (root / "Sources/ControllerModel.swift").read_text():
    fail("status refresh must carry a deadline so a blocked helper errors instead of hanging")
swap = helper[helper.index("private func swapStagedApp"):helper.index("private func swapStagedApp") + 4000]
if "liveBuild != build" not in swap or "version.json" not in swap:
    fail("the updater must not overwrite the rollback copy with the same build, and must name it")
if "needsYouStaleFlagLimit" not in helper:
    fail("a stale needs-you cache must drop the reward flag")

# 5. The activity log names lessons; the Home chip stays Needs you (0.5.215 pins above still hold).
if "Applied ' + (state.appliedDays === 90 ? 'in 90 days' : 'this week') + '</h3>'" not in page:
    fail("the activity log must list the lessons a later answer used")
nav = page[page.index("function memoryNav()"):page.index("function summary()")]
if "applied" in nav and "needsYouCount" in nav and "state.applied" in nav:
    fail("the Applied count must never feed the To review number or the Home chip")
if "'1 time'" in page:
    fail("the Applied card must not fabricate a count")
if "function appliedCountFromTitle(" not in page:
    fail("the count comes from the projector title or is omitted")
print("COS Control: reward chrome contract pinned (Applied this week, kind passthrough, gated ranking sentence, path-aware empties, honest count)")
PY

# --- 0.5.216 Sessions rows wear Claude / Cursor / ChatGPT marks -------------
# The list used SF Symbol bubbles. Codex must read as ChatGPT (bundled OpenAI
# blossom), Cursor as the bundled cube, Claude as the bundled spark. Do not
# scrape vendor logos; these three SVGs already ship for the pet.
/usr/bin/python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
activity = (root / "Sources/ActivityWindow.swift").read_text()
models = (root / "Sources/Models.swift").read_text()

def fail(msg):
    sys.exit(msg)

glyph = activity[activity.index("private func providerGlyph(_ session: ClaudeSession)"):]
glyph = glyph[:glyph.index("private func providerBadge")]
if "session.petProviderMark" not in glyph:
    fail("Sessions rows must resolve marks through ClaudeSession.petProviderMark")
if "COSBrand.svg(name)" not in glyph:
    fail("Sessions rows must render the bundled brand SVG, not an SF bubble")
if "text.bubble" in glyph or "macwindow" in glyph or "chevron.left.forwardslash" in glyph:
    fail("generic SF Symbols must not stand in for Claude / Cursor / ChatGPT")
if '"ChatGPT"' not in glyph:
    fail("Codex rows must be announced as ChatGPT")
if "providerGlyph(session)" not in activity:
    fail("the session row must pass the whole session into providerGlyph")
if "providerGlyph(session.provider)" in activity:
    fail("providerGlyph must not take a raw provider string; that path drew bubbles")
if ".asset(\"mark-codex\")" not in models or ".asset(\"mark-cursor\")" not in models or ".asset(\"mark-claude\")" not in models:
    fail("PetProvider.mark lost a platform asset")
for asset in ("mark-claude", "mark-codex", "mark-cursor"):
    svg = (root / f"Resources/{asset}.svg").read_text()
    if "<svg" not in svg or len(svg) < 80:
        fail(f"Resources/{asset}.svg is empty or missing")
codex = (root / "Resources/mark-codex.svg").read_text()
if "OpenAI" not in codex:
    fail("mark-codex.svg must remain the ChatGPT/OpenAI blossom, not a Codex wordmark")
if "Codex" in codex:
    fail("mark-codex.svg picked up a Codex wordmark")
print("COS Control: Sessions provider marks pinned")
PY

# 0.5.218 — listen to a held voice before naming it (Queen, 2026-09-12).
/usr/bin/python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
activity = (root / "Sources/ActivityWindow.swift").read_text()
models = (root / "Sources/Models.swift").read_text()
controller = (root / "Sources/ControllerModel.swift").read_text()
helper = (root / "HelperSources/main.swift").read_text()

def fail(msg):
    sys.exit(msg)

if "if !session.chunkIndices.isEmpty {" not in activity or "heldSampleListenControl(session)" not in activity:
    fail("Add-a-voice rows must show the Listen control only when the server reported chunk indices")
if "model.playHeldSample(session, chunkIndex: chunkIndex)" not in activity:
    fail("the Listen control must play the held chunk through the shared player")
if 'chunkIndices = (o["chunkIndices"]?.array ?? [])' not in models:
    fail("ExtAudioSession must parse chunkIndices from the listing")
if '"--ext-chunk", String(chunkIndex)' not in controller:
    fail("playHeldSample must ask the helper for one held chunk")
if 'sample?chunk=\\(index)' not in helper:
    fail("the helper must map --ext-chunk to the per-chunk sample route")
print("COS Control: held-voice Listen control pinned (0.5.218)")
PY

# 0.5.219 — held voices grouped by who they sound like (Miles, 2026-09-12).
/usr/bin/python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
activity = (root / "Sources/ActivityWindow.swift").read_text()
models = (root / "Sources/Models.swift").read_text()
controller = (root / "Sources/ControllerModel.swift").read_text()
helper = (root / "HelperSources/main.swift").read_text()

def fail(msg):
    sys.exit(msg)

for cmd, route in (('"voice-held-groups"', '"/api/voice/held-groups"'),
                   ('"voice-held-enroll"', '"/api/voice/held-groups/enroll"'),
                   ('"voice-held-discard"', '"/api/voice/held-groups/discard"')):
    if f"case {cmd}:" not in helper:
        fail(f"helper lost the {cmd} command")
    if route not in helper:
        fail(f"helper must call {route}")
if helper.count('try Self.heldMembersPayload(option("--members", in: args))') != 2:
    fail("both held-group mutations must validate --members through heldMembersPayload before any request")
if '"state": "route_absent", "groups": []' not in helper:
    fail("an older server must answer route_absent so the panel keeps the per-session rows")
if 'model.heldGroupsState == "ready" && !(model.heldGroupsEmbedded == 0 && model.heldGroupsSamples > 0)' not in activity or "heldGroupsBody" not in activity:
    fail("Add-a-voice must render the grouped view only when the server answered the held-groups route AND could group what it holds")
if "addVoiceRow(session)" not in activity:
    fail("the per-session rows must remain as the fallback for an older server")
if "confirmingHeldDiscard = key" not in activity or "confirmingHeldDiscard == key" not in activity:
    fail("Discard must be two clicks: arm, then confirm")
if "await model.discardHeld(members)" not in activity:
    fail("the confirmed Discard must go through the model")
if 'Button("Add to \\(name)")' not in activity or "await model.nameHeld(group.members, as: name)" not in activity:
    fail("a suggested group must offer one-click Add to <name>")
if "if rows > Self.heldGroupInlineRowLimit {" not in activity or ".frame(minHeight: Self.heldGroupListMinHeight, maxHeight: .infinity)" not in activity:
    fail("the grouped list must be capped and scroll in place inside a flexible frame with a floor (2026-08-26 regression, 0.5.222 layout)")
if 'payload["confirm"] = true' not in helper or 'payload: ["members": members, "confirm": true]' not in helper:
    fail("Apply and discard must pass confirm to a server that fails closed")
if 'static let heldGroupsNeeds = "6.46.0"' not in helper \
   or 'emit(ok: true, message: Self.heldGroupsUpdateMessage("group held voices")' not in helper \
   or 'throw HelperError.message(Self.heldGroupsUpdateMessage("name held voices by group"))' not in helper:
    fail("a held-groups 404 must name the route's own requirement, in both places")
if "if heldGroupsUsable {" not in activity or activity.count("\n                heldGroupsFallbackNote\n") != 2 or "private var heldGroupsFallbackNote: some View {" not in activity:
    fail("the grouped view stands in for the sessions only when the server could group; both fallback branches must explain why")
if 'model.heldGroupsSpeakerModel = response.details["speakerModel"]?.bool ?? true' not in controller and 'heldGroupsSpeakerModel = response.details["speakerModel"]?.bool ?? true' not in controller:
    fail("loadHeldGroups must read whether the speaker model is loaded")
# 0.5.220: the read above passed while the helper never forwarded the field, so
# the controller always fell back to true and naming stayed enabled with no model.
held_start = helper.find("private func emitVoiceHeldGroups() throws {")
held_body = helper[held_start:helper.find("\n    }\n", held_start)] if held_start >= 0 else ""
if helper.count('"speakerModel": (body["speakerModel"] as? Bool) ?? true') != 1 \
   or '"speakerModel": (body["speakerModel"] as? Bool) ?? true' not in held_body:
    fail("emitVoiceHeldGroups must forward the server's speakerModel exactly once, or every naming button stays enabled on a Mac with no model")
if 'model.heldGroupsState == "error", let error = model.heldGroupsError' not in activity:
    fail("a held-groups failure must be shown, not swallowed into the per-session rows")
if '"voice-held-preview"' not in controller or 'Button("Apply")' not in activity or "await model.applyHeldNaming()" not in activity:
    fail("every suggestion must preview before explicit Apply")
if "static let heldDiscardBatchSize = 200" not in controller or "Self.heldDiscardBatchSize" not in controller:
    fail("discard must be sent in bounded slices: a full loose set exceeds one request")
if "heldGroupsReloadRequested = true" not in controller:
    fail("a reload requested during a load must be queued, not dropped")
if ".onChange(of: model.heldGroupsGeneration)" not in activity:
    fail("cursors and armed confirmations must reset after a naming or discard")
if "if members.isEmpty {" not in activity:
    fail("the Listen control must guard an empty list")
if "Self.heldSampleLabel(current)" not in activity:
    fail("the loose row must say which clip the cursor is on")
if activity.count("|| !model.heldGroupsSpeakerModel") < 4:
    fail("every naming affordance must be disabled while the server has no speaker model (a click would 503)")
if "voices can be heard and discarded, not named yet" not in activity or "model.heldGroupsUnusable > 0" not in activity:
    fail("the lead must say why naming is unavailable and count the samples that cannot be read")
if 'Discarded \\(removed) of \\(members.count) samples before an error' not in controller or "if removed > 0 {" not in controller:
    fail("a discard that fails mid-way must report the partial count and refresh")
if 'heldActionRow(key: "loose:' not in activity:
    fail("a loose sample must be nameable on its own — sample by sample")
if "members: group.playOrder" not in activity or "var playOrder: [HeldSampleRef] { [seed] + members.filter { $0 != seed } }" not in models:
    fail("a group's Listen control must start on the server's seed sample")
if "struct HeldVoiceGroup" not in models or 'suggestionTier = suggestion?["tier"]?.string' not in models:
    fail("HeldVoiceGroup must parse the server's suggestion")
if 'suggestionAgreeing = suggestion?["agreeing"]?.int ?? 0' not in models or "of \\(group.suggestionOf) samples agree" not in activity:
    fail("a suggestion row must say how many of the profile's samples agree")
if '"voice-held-preview", "--name", trimmed, "--members", Self.heldMembersJSON(members)' not in controller:
    fail("nameHeld must send the member list as JSON to the helper")
if "await loadHeldGroups()" not in controller:
    fail("loadExtAudio must refresh the grouped view alongside the sessions")
print("COS Control: held-voice groups pinned (0.5.219)")
PY

# 0.5.221 — Add a voice speaks the gotcos theme in light and dark (Miles, 2026-09-13).
/usr/bin/python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
activity = (root / "Sources/ActivityWindow.swift").read_text()
views = (root / "Sources/Views.swift").read_text()
brand = (root / "Sources/COSBrand.swift").read_text()

def fail(msg):
    sys.exit(msg)

card = activity[activity.index("private var addVoiceSection: some View {"):activity.index("private func commitAddVoice(")]
for banned, why in ((".buttonStyle(.link)", "system link buttons read as web hyperlinks in a warm pane"),
                    (".buttonStyle(.plain)", "Listen controls use COSIconButtonStyle"),
                    (".textFieldStyle(.roundedBorder)", "name fields use cosField()"),
                    (".foregroundStyle(.secondary)", "secondary text uses COSPalette.muted"),
                    (".foregroundStyle(.tertiary)", "footnotes use COSPalette.muted")):
    if banned in card:
        fail(f"Add a voice must not use {banned}: {why}")
for needed, why in ((".background(COSPalette.card)", "the card sits on the adaptive card fill"),
                    (".stroke(COSPalette.line, lineWidth: 1)", "the card carries the adaptive hairline"),
                    ("COSQuietButtonStyle(tone: .destructive)", "confirming a discard is a danger chip"),
                    ("COSTextButtonStyle(tone: .destructive)", "arming a discard is a danger text action"),
                    ("COSIconButtonStyle(size: 28, prominent: playing)", "play fills gold while a sample plays"),
                    ('Text("Add a voice").font(COSType.display(', "the title is set in Fraunces")):
    if needed not in card:
        fail(f"Add a voice lost {needed!r}: {why}")
if card.count(".cosField()") != 2:
    fail("both name fields (held group and held session) must use cosField()")
for token, light, dark in (("accentNS", "red: 0.537, green: 0.400, blue: 0.176", "red: 0.788, green: 0.659, blue: 0.431"),
                           ("dangerNS", "red: 0.647, green: 0.278, blue: 0.196", "red: 0.910, green: 0.643, blue: 0.580"),
                           ("mutedNS", "red: 0.455, green: 0.447, blue: 0.427", "red: 0.733, green: 0.682, blue: 0.604"),
                           ("raisedNS", "red: 0.933, green: 0.910, blue: 0.867", "red: 0.188, green: 0.153, blue: 0.122")):
    i = views.find(f"static let {token} = adaptiveNSColor(")
    block = views[i:i + 260] if i >= 0 else ""
    if light not in block or dark not in block:
        fail(f"COSInk.{token} must be adaptive with light ({light}) and dark ({dark}), the Memories theme values")
for decl in ("static let accent = Color(nsColor: COSInk.accentNS)", "static let danger = Color(nsColor: COSInk.dangerNS)",
             "static let muted = Color(nsColor: COSInk.mutedNS)", "static let raised = Color(nsColor: COSInk.raisedNS)"):
    if decl not in views:
        fail(f"COSPalette lost {decl}")
for decl in ("struct COSTextButtonStyle: ButtonStyle", "struct COSIconButtonStyle: ButtonStyle", "enum Tone { case standard, destructive }"):
    if decl not in brand:
        fail(f"COSBrand.swift lost {decl}")
print("COS Control: Add a voice gotcos theme pinned (0.5.221)")
PY

# 0.5.222 — Speakers has three views and the toolbar stays put (Miles, 2026-09-13:
# "There's no place for us to review existing speakers" and "the header... is being truncated").
/usr/bin/python3 - "$ROOT" <<'PY'
from pathlib import Path
import re, sys
root = Path(sys.argv[1])
activity = (root / "Sources/ActivityWindow.swift").read_text()
controller = (root / "Sources/ControllerModel.swift").read_text()

def fail(msg):
    sys.exit(msg)

def body(src, start, end):
    i = src.index(start)
    return src[i:src.index(end, i + len(start))]

enum = body(activity, "private enum SpeakerSubview", "private enum VoiceDirectorySort")
if re.findall(r"^\s*case (\w+)$", enum, re.M) != ["meetings", "samples", "voices"]:
    fail("SpeakerSubview must be exactly meetings, samples, voices, in that order")
title = body(enum, "var title: String {", "var headerTitle: String {")
header_title = enum[enum.index("var headerTitle: String {"):]
for part, need in ((title, 'case .meetings: "Meetings to review"'), (title, 'case .samples: "Samples to review"'), (title, 'case .voices: "Voices"'),
                   (header_title, 'case .samples: "Samples to review"'), (header_title, 'case .voices: "Voice directory"')):
    if need not in part:
        fail(f"SpeakerSubview picker and hero titles lost {need!r}")
speakers = body(activity, "private var speakersList: some View {", "private var speakerDirectoryDetail: String {")
for need in ("case .meetings: meetingsToReviewList", "case .samples: voiceSamplesPane", "case .voices: voiceDirectoryList",
             "title: speakerSubview.headerTitle,", "refreshDisabled: speakerRefreshDisabled,",
             "Task { await loadSpeakerSubview(next, refresh: false) }", "Task { await loadSpeakerSubview(speakerSubview, refresh: true) }",
             "model.addVoiceResult = nil", ".textFieldStyle(.plain)\n                        .cosField()"):
    if need not in speakers:
        fail(f"speakersList lost {need!r}")
if ".roundedBorder" in speakers or speakers.count(".menuStyle(.button)") != 2 or speakers.count(".buttonStyle(COSQuietButtonStyle())") < 2:
    fail("the Speakers controls row must use cosField and COS quiet menus, not system styles")
loader = body(activity, "private func loadSpeakerSubview(", "\n    }\n")
for need in ("case .meetings: await model.loadReviewableMeetings()", "case .samples:\n            await model.loadExtAudio()",
             "if model.voiceDirectory.isEmpty { await model.loadVoiceDirectory() }", "case .voices: await model.loadVoiceDirectory(refresh: refresh)"):
    if need not in loader:
        fail(f"loadSpeakerSubview lost {need!r}")
if "case .speakers:\n            await loadSpeakerSubview(speakerSubview, refresh: false)" not in activity:
    fail("opening Speakers must load the current view through loadSpeakerSubview")
root_body = body(activity, "    var body: some View {\n        VStack(spacing: 0) {\n            navigationBar", ".frame(minWidth: 760, minHeight: 560)")
if not re.search(r"activityHome\n\s*\}\n\s*\}\n(?:\s*//.*\n)*\s*\.frame\(minWidth: 0, maxWidth: \.infinity, minHeight: 0, maxHeight: \.infinity, alignment: \.top\)\n\s*\.clipped\(\)\n\s*\}\n\s*$", root_body):
    fail("the content under the toolbar must be .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top).clipped()")
if "window.contentMinSize = NSSize(width: 760, height: 560)" not in activity or "window.minSize =" in activity:
    fail("the Activity window minimum must be a content size; minSize counts the title bar")
held = body(activity, "private var heldGroupsBody: some View {", "private var heldGroupRows: some View {")
if held.index("uses up the audio") > held.index("if rows > Self.heldGroupInlineRowLimit {"):
    fail("the uses-up-the-audio line must come before the grouped list")
if not re.search(r"ScrollView \{[\s\S]{0,200}?heldGroupRows[\s\S]{0,200}?\.frame\(minHeight: Self\.heldGroupListMinHeight, maxHeight: \.infinity\)", held):
    fail("the grouped list must scroll inside a flexible frame with a floor")
if "private static let heldGroupListMinHeight: CGFloat = 88" not in activity or re.search(r"\.frame\(height: (?!1\))", held):
    fail("the grouped list floor is 88 pt and it has no fixed height")
card = body(activity, "private var addVoiceSection: some View {", "private func commitAddVoice(")
if 'Button("Refresh"' in card or "Grouping held voices" not in card:
    fail("the card has no second Refresh and says when it is still grouping")
if "nameHint(heldGroupName) { heldGroupName = $0 }" not in card:
    fail("naming a held group must show whether the name adds to someone")
hint = body(activity, "private func nameHint(", "private func commitHeldName(")
if "precomposedStringWithCompatibilityMapping.lowercased()" not in hint or "matches.count > 1" not in hint or "localizedCaseInsensitiveContains" not in hint:
    fail("nameHint must resolve normalized case, refuse ambiguous duplicate names, and offer near matches")
detail = body(activity, "private var heldSamplesDetail: String {", "\n    }\n")
if "model.heldGroupsState == nil" not in detail or "model.extAudioLoadFailed" not in detail:
    fail("the Samples hero line must not read as an empty window while loading or after a failure")
header = body(activity, "private var voiceDirectoryColumnHeader: some View {", "private func voiceDirectoryRow(")
if re.findall(r'Text\("([A-Z ]+)"\)', header) != ["VOICE", "SAMPLES", "CONFIDENCE", "MEETINGS", "SEGMENTS", "LAST SEEN"]:
    fail("voice directory columns must be VOICE, SAMPLES, CONFIDENCE, MEETINGS, SEGMENTS, LAST SEEN")
row = body(activity, "private func voiceDirectoryRow(", "private var meetingsToReviewList: some View {")
order = [row.find(t) for t in ("metric(formatted(person.embeddings)", "confidenceValue(person)", "formatted(person.meetingCount)", "formatted(person.assertedSegments)", "person.lastSeen ??")]
if -1 in order or order != sorted(order):
    fail("row metrics must be samples, confidence, meetings, segments, last seen, the same order as the header")
share = body(activity, "private func confidenceShare(", "\n    }\n")
if "Double(confident) / Double(person.observedMatchSegments)" not in share or ">=" in share or re.search(r"\d\.\d", share):
    fail("confidence divides confident segments by the SCORED basis and never re-derives a similarity threshold")
if "static let confidenceMinimumBasis = 10" not in activity or activity.count("Self.confidenceMinimumBasis") < 3:
    fail("the thin-basis mark and the confidence sort must share confidenceMinimumBasis")
if 'title: "OBSERVED MATCH"' in activity or 'voiceMetricCard(title: "CONFIDENCE"' not in activity:
    fail("the detail pane must use the same CONFIDENCE name as the list")
rank = body(activity, "private func confidenceRank(", "\n    }\n")
if "return (2, nil)" not in rank or "< Self.confidenceMinimumBasis ? 1 : 0" not in rank:
    fail("confidenceRank must put never-matched last and thin bases after real ones")
sort = body(activity, "private var visibleVoices: [VoiceDirectoryPerson] {", "private var hasDetail: Bool {")
for need in ("if a.embeddings != b.embeddings { return a.embeddings > b.embeddings }", "if ra.tier != rb.tier { return ra.tier < rb.tier }",
             "if let x = ra.share, let y = rb.share, x != y { return x < y }", "return a.observedMatchSegments > b.observedMatchSegments"):
    if need not in sort:
        fail(f"voice sort lost {need!r}")
for need in ('case .samples: "Most samples"', 'case .confidence: "Lowest confidence"', 'Button("Clear search")', "No voices match"):
    if need not in activity:
        fail(f"Voices lost {need!r}")
for need, why in (("guard !extAudioLoading else { extAudioReloadRequested = true; return }", "a held-sessions reload asked for mid-load must be queued"),
                  ("extAudioReloadRequested = false\n            await loadExtAudio()", "the queued held-sessions reload must run"),
                  ("if refresh { voiceDirectoryRefreshQueued = true }", "a directory refresh asked for mid-load must be queued"),
                  ("voiceDirectoryRefreshQueued = false\n            await loadVoiceDirectory(refresh: true)", "the queued directory refresh must run"),
                  ("voiceDirectoryLoadFailed = true", "a failed directory load must be distinguishable from nobody enrolled"),
                  ("extAudioLoadFailed = true", "a failed held-sessions load must be distinguishable from nothing held"),
                  ("there is nothing to review. Name a held voice under Samples to review", "the Meetings zero-profile state must point to Samples to review")):
    if need not in controller:
        fail(why)
print("COS Control: Speakers views and toolbar clamp pinned (0.5.222)")
PY

# 0.5.223 — held naming Undo confirmations capture their target. `cosConfirm` dismisses
# BEFORE it runs the action, and dismissal nils the handle binding, so an action that
# read the binding would guard-out and undo nothing: the fence Release bug again.
/usr/bin/python3 - "$ROOT" <<'UNDOCAP'
from pathlib import Path
import re, sys
root = Path(sys.argv[1])
activity = (root / "Sources/ActivityWindow.swift").read_text()

def fail(msg):
    sys.exit(msg)

sites = list(re.finditer(r'\.destructive\("Undo labels"\) \{ \[handle = (\w+)\] in\n', activity))
if len(sites) != 3 or activity.count('.destructive("Undo labels")') != 3:
    fail("the status bar, result and history Undo confirmations must each capture the handle in the action's capture list")
for m in sites:
    var = m.group(1)
    action = activity[m.end():activity.index("\n", activity.index("undoHeldNaming(", m.end()))]
    if "if let handle { Task { await model.undoHeldNaming(handle) } }" not in action:
        fail(f"the Undo action for {var} must undo the captured handle")
    if re.search(rf"\b{var}\b", action):
        fail(f"the Undo action reads {var}, which dismissal has already cleared")
print("COS Control: held naming Undo captures its target before dismissal (0.5.223)")
UNDOCAP

# 0.5.225 — the pet's live rows take their activity from transcript records (Miles, 2026-09-13:
# "our pet isn't actually tracking our sessions anymore"). Checks read code with comments
# stripped, because a clause that matches its own explanatory comment cannot fail.
/usr/bin/python3 - "$ROOT" <<'PETLIVE'
from pathlib import Path
import re, sys
root = Path(sys.argv[1])
helper = (root / "HelperSources/main.swift").read_text()
model = (root / "Sources/ControllerModel.swift").read_text()

def fail(msg):
    sys.exit(msg)

def code(text):
    return re.sub(r"//[^\n]*", "", text)

def body(src, name):
    start = src.index(name)
    return code(src[start:src.index("\n    }\n", start)])

live = code(helper[helper.index("private func emitLiveClaudeSessions("):helper.index("private func emitQuickClaudeSessions(")])
if ("Self.petLiveRows(" not in live or "Self.claudeSessionActivity(sessionId: $0, projectsRoot: claudeProjects)" not in live
        or "serverAnswered && enabled ? live : nil" not in live):
    fail("session-pet-live must run petLiveRows with transcript activity, passing live peers only when the server answered")
pipeline = body(helper, "static func petLiveRows(")
order = [pipeline.find(t) for t in ("overlayLiveState(", "markUnlistedClaudeRowsGone(", "refreshClaudeTranscriptActivity(", "applyLiveWorkingState(", "isPetLiveRow(")]
if -1 in order or order != sorted(order):
    fail("petLiveRows must overlay, mark unlisted rows gone, read transcript records, apply state, then filter")
quick = code(helper[helper.index("private func emitQuickClaudeSessions("):helper.index("private func emitFreshClaudeSessions(")])
if "Self.refreshClaudeTranscriptActivity(cachedRows)" not in quick:
    fail("the quick Sessions path must read transcript records, so Activity agrees with the pet")
fresh_start = helper.index("private func emitFreshClaudeSessions(")
fresh = code(helper[fresh_start:helper.index("saveSessionListCache(sessions: peers", fresh_start)])
if not (0 <= fresh.find("Self.refreshClaudeTranscriptActivity(peers)") < fresh.find("Self.applyLiveWorkingState(peers")):
    fail("the fresh Sessions path must read transcript records before its working-state pass")
locator = body(helper, "static func claudeTranscriptURL(")
for banned in ("Data(contentsOf", "FileHandle", "InputStream", "String(contentsOf", "contents(atPath", "read(upToCount", "claudeTranscriptTurn("):
    if banned in locator:
        fail(f"claudeTranscriptURL must stat, never open, the transcript ({banned})")
lines = body(helper, "static func claudeTailLines(")
reader = body(helper, "static func claudeTranscriptTurn(")
if "handle.read(upToCount: end - start)" not in lines or "seek(toOffset:" not in lines:
    fail("claudeTailLines must seek and read only its window, with throwing FileHandle calls")
for banned in ("Data(contentsOf", "String(contentsOf", "readToEnd", "readDataToEndOfFile", "forEachClaudeJsonlLine", "claudeTranscriptMaxLineBytes"):
    if banned in lines or banned in reader:
        fail(f"the activity reader must read a bounded window with no line cap ({banned})")
if "min(window, maxBytes)" not in reader or "maxBytes: Int = claudeActivityTailMaxBytes" not in reader:
    fail("claudeTranscriptTurn must cap each read at maxBytes, defaulting to claudeActivityTailMaxBytes")
parser = body(helper, "static func claudeTurnFromTail(")
if 'type == "user" || type == "assistant"' not in parser or 'obj["isMeta"] as? Bool != true' not in parser:
    fail("only user and assistant records are activity, and isMeta records are skipped")
if "current" in body(helper, "static func refreshClaudeTranscriptActivity("):
    fail("the newest record replaces the cached stamp; a newer-only rule keeps a touched file time")
apply = body(helper, "static func applyLiveWorkingState(")
if 'out[index]["activitySource"] as? String == "transcript", state != "stale", state != "waiting"' not in apply or "claudeTurnState(" not in apply:
    fail("applyLiveWorkingState must let transcript records decide a live Claude row, after a dead PID and a registry wait")
if 'now.timeIntervalSince(last) <= petUnfinishedMaxAge ? "running" : "waiting"' not in body(helper, "static func claudeTurnState("):
    fail("a turn in flight past petUnfinishedMaxAge must read waiting, never a finish")
projection = body(helper, "static func claudePeerProjection(")
for need in ('"createdAt": peerTimeISO(row["startedAt"])', '"updatedAt": peerTimeISO(row["lastActiveAt"])'):
    if need not in projection:
        fail(f"the server sends peer times as epoch milliseconds; claudePeerProjection lost {need!r}")
prepass = code(model[model.index("func loadPetSessions() async"):model.index('helper.run(["session-pet-live"]')])
if "lastAuthoritativeRaw == nil, petSessions.isEmpty, !claudeSessions.isEmpty" not in prepass:
    fail("the pet may paint Activity's snapshot only before the helper's first live answer")
refresh = body(helper, "static func refreshClaudeTranscriptActivity(")
if 'if let title = activity.title, !title.isEmpty { out[index]["name"] = title }' not in refresh:
    fail("a live Claude row must take its Claude Desktop tab title from the transcript (0.5.226)")
if "claudeCustomTitleFromLines(lines)" not in reader:
    fail("the activity reader must read the tab title from the lines it already holds (0.5.226)")
if "title: main?.title ?? lastCustomTitle(in: url)" not in body(helper, "static func claudeSessionActivity("):
    fail("a title record outside the activity window must come from the transcript head (0.5.226)")
if not (0 <= fresh.find("Self.applyClaudeDesktopTitles(peers, desktopIndex: desktopIndex)") < fresh.find("Self.refreshClaudeTranscriptActivity(peers)")):
    fail("the fresh Sessions walk must apply Claude Desktop tab titles before reading transcript records (0.5.226)")
pet = (root / "Sources/SessionPet.swift").read_text()
if "title: session.petIdleLine" not in body(pet, "private func idleRow("):
    fail("an idle pet row must use petIdleLine, never petLiveLine's working fallback (0.5.226)")
print("COS Control: pet live rows follow transcript records and tab titles (0.5.226)")
PETLIVE

/usr/bin/python3 - "$ROOT" <<'MEETAUDIO'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
def code(path):
    return re.sub(r"//[^\n]*", "", (root / path).read_text())
helper = code("HelperSources/main.swift")
model = code("Sources/ControllerModel.swift")
views = code("Sources/Views.swift")
def fail(message):
    sys.exit(f"meeting-audio: {message}")
def body(text, marker):
    start = text.find(marker)
    if start < 0:
        fail(f"missing {marker}")
    depth = 0
    for j in range(text.index("{", start), len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[start:j + 1]
    fail(f"unterminated {marker}")
if 'case "meeting-audio-watch": try emitMeetingAudioWatch()' not in helper:
    fail("the helper must dispatch meeting-audio-watch")
for name, value in (("meetingAudioSilenceAlertSeconds", "60"), ("meetingAudioHeartbeatFreshSeconds", "180"),
                    ("meetingAudioHeartbeatLeadSeconds", "30"), ("meetingAudioForgetSeconds", "30 * 60")):
    if f"static let {name}: TimeInterval = {value}" not in helper:
        fail(f"{name} must stay {value}; change it with the self-tests, the replay and the CHANGELOG")
if "static let meetingAudioPendingRise = 2" not in helper:
    fail("meetingAudioPendingRise must stay 2; change it with the self-tests, the replay and the CHANGELOG")
verdict = body(helper, "static func meetingAudioVerdict(")
if "meetingAudioHeartbeatLeadSeconds" not in verdict or "!fresh || !spokeAfterAudio" not in verdict:
    fail("an alert needs a heartbeat that arrived after the audio stopped (0.5.228)")
refresh = body(model, "func refresh(quiet: Bool = false) async {")
catch_at = refresh.find("} catch {")
watch_at, orphans_at = refresh.find("await loadMeetingAudioWatch()"), refresh.find("await loadOrphans(quiet: true)")
if watch_at < 0 or orphans_at < 0 or catch_at < 0 or watch_at < orphans_at or catch_at < watch_at:
    fail("every successful status refresh must check meeting audio, after the captures load")
if "meetingAudio = []" not in refresh[catch_at:]:
    fail("a failed status refresh must clear the Meeting audio rows")
load = body(model, "func loadMeetingAudioWatch() async {")
if '"meeting-audio-watch"' not in load or "} catch {" not in load:
    fail("the check must run the helper's meeting-audio-watch and handle its failure")
load_do, load_catch = load.split("} catch {", 1)
posting = load_do.split("for watch in update.post {", 1)
if "let update = meetingAudioLedger.update(watches)" not in load_do or len(posting) != 2 or "meetingAudioNotifier.post(watch)" not in posting[1]:
    fail("alerts must pass the one-per-drop ledger before posting")
if "meetingAudioNotifier.removeDelivered(sessionIds: update.resolved)" not in load_do:
    fail("audio reaching the Mac again must take its notification down")
if load.count("guard generation == meetingAudioGeneration else { return }") != 2:
    fail("a check overtaken by a newer one must be ignored on both paths")
if "meetingAudio = []" not in load_catch:
    fail("a failed check must clear its rows, never keep a stale Reaching this Mac")
init = body(model, "init(startBackgroundWork: Bool = true) {")
guard_at, ask_at = init.find("guard startBackgroundWork else { return }"), init.find("meetingAudioNotifier.requestAuthorization()")
if guard_at < 0 or ask_at < guard_at:
    fail("notification permission is asked at launch, and only by the background-work model")
notifier = body(model, "final class MeetingAudioNotifier")
if "private lazy var center" not in notifier or "center.delegate = self" not in notifier or ".alert" not in notifier:
    fail("the notifier must create its center on first use, own the delegate and ask for alerts")
if notifier.count("meetingAudioLog.") < 2 or "NSLog(" in notifier or "privacy: .public" not in notifier:
    fail("permission answers and posting errors must be logged in the open with meetingAudioLog, never NSLog (0.5.229)")
_load_and_permission = load + body(model, "private func loadMeetingAlertPermission() async {")
if "NSLog(" in _load_and_permission or _load_and_permission.count("meetingAudioLog.") < 2:
    fail("failed checks and alert state changes must be logged with meetingAudioLog in the open (0.5.229)")
permission = body(model, "private func loadMeetingAlertPermission() async {")
if ".notDetermined" not in permission or "requestAuthorization()" not in permission or "meetingAlertsOff = off" not in permission:
    fail("a Mac with no answer on record is asked again, and alerts that are off show in the panel")
if "ForEach(model.meetingAudio)" not in views or "watch.rowLabel(amongLive: model.meetingAudio.count)" not in views or "Text(watch.panelCaption)" not in views:
    fail("the panel must show a labeled Meeting audio row and caption per live meeting")
if "model.meetingAlertsOff && !model.meetingAudio.isEmpty" not in views:
    fail("the panel must say when macOS is not showing COS Control's alerts")
print("COS Control: meeting audio alert wiring (0.5.228)")
MEETAUDIO

/usr/bin/python3 - "$ROOT" <<'SCHEDJOBS'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
def code(path):
    return re.sub(r"//[^\n]*", "", (root / path).read_text())
helper = code("HelperSources/main.swift")
model = code("Sources/ControllerModel.swift")
models = code("Sources/Models.swift")
pet = code("Sources/SessionPet.swift")
activity = code("Sources/ActivityWindow.swift")
def fail(message):
    sys.exit(f"scheduled-jobs: {message}")
def body(text, marker):
    start = text.find(marker)
    if start < 0:
        fail(f"missing {marker}")
    depth = 0
    for j in range(text.index("{", start), len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[start:j + 1]
    fail(f"unterminated {marker}")
live = body(helper, "private func emitLiveClaudeSessions(")
at_rows = live.find("Self.petLiveRows(")
at_jobs = live.find("annotatedScheduledJobs(peers, home: home, previous: previousRows)")
at_emit = live.find("emitSessionList(")
if min(at_rows, at_jobs, at_emit) < 0 or not at_rows < at_jobs < at_emit:
    fail("the pet's live rows must be marked as scheduled jobs after petLiveRows and before they are emitted")
fresh = body(helper, "private func emitFreshClaudeSessions(")
if not 0 <= fresh.find("annotatedScheduledJobs(") < fresh.find("saveSessionListCache("):
    fail("the Sessions list must be marked before it is cached, so a finished job keeps its label")
walker = body(helper, "private func annotatedScheduledJobs(")
if "Self.processNode(pid: $0, includeArgs: $0 != pid)" not in walker:
    fail("the walk must never read the Claude run's own arguments; they can carry its prompt")
origin = body(helper, "static func scheduledJobOrigin(")
if 'label.hasPrefix("com.cos.")' not in origin or 'node.comm == "claude"' not in origin:
    fail("only a com.cos LaunchAgent or a parent Claude session makes a run a job")
apply_sessions = body(model, "private func applyPetSessions(")
if not 0 <= apply_sessions.find("mergeCompletions(") < apply_sessions.find("ScheduledJobLedger.record(") \
        or "saveScheduledJobRuns()" not in apply_sessions:
    fail("finished job runs must be recorded and saved on the authoritative pet poll")
init = body(model, "init(startBackgroundWork: Bool = true) {")
if not 0 <= init.find("guard startBackgroundWork else { return }") < init.find("loadScheduledJobRuns()"):
    fail("today's runs must load at launch, only in the background-work model")
opener = body(model, "func openClaudeSession(")
guard_at = opener.find("guard !session.isScheduledJob")
if guard_at < 0 or guard_at > opener.find("claudeSessionDetailTask = Task") or guard_at > opener.find("prepareSessionChat(session)"):
    fail("opening a scheduled job must not fetch a transcript or prepare Continue")
for fn in ("private func missionRow(", "private func idleRow("):
    row_body = body(pet, fn)
    if "openInPlatform: session.isScheduledJob ? nil :" not in row_body:
        fail(f"{fn} still offers a platform window for a scheduled job")
    branch_at = row_body.find("if session.isScheduledJob {")
    else_at = row_body.find("} else {", branch_at) if branch_at >= 0 else -1
    if branch_at < 0 or else_at < 0 or "presenter.openInControl(session)" not in row_body[branch_at:else_at]:
        fail(f"{fn}: tapping a scheduled job must open it in Control, not a platform window")
done = pet[pet.index("private var completionsList"):pet.index("private func petFloatingText")]
if "openInPlatform: row.isScheduledJob ? nil :" not in done or "row.runsLabel()" not in done:
    fail("a finished job row must count its runs and offer no platform window")
if 'if session.isScheduledJob { return "Scheduled job" }' not in body(pet, "private func slotSecondLine(for session: ClaudeSession)"):
    fail("a job row's second line must say Scheduled job, not its folder")
pane = body(activity, "struct ClaudeSessionDetailPane")
if "ScheduledJobFacts(row: row)" not in pane or "if model.openClaudeRow?.isScheduledJob != true {" not in pane \
        or "if let row = model.openClaudeRow, !row.isScheduledJob {" not in pane \
        or "if let row = model.openClaudeRow, row.isScheduledJob {" not in pane:
    fail("a scheduled job must show its facts, with no Continue composer and no Open in platform")
if "scheduledJobRunsSection" not in body(activity, "private var sessionsList: some View {"):
    fail("Sessions must list today's finished scheduled job runs")
if "model.openClaudeSession(session)" not in body(activity, "private var scheduledJobRunsSection: some View {"):
    fail("a finished run must open as its facts")
detector = body(models, "static func diff(")
if "seen: true" not in detector or 'sessionId: "job:\\(label)"' not in detector:
    fail("a finished job must emit one row per job, already seen")
if "rows.filter({ !$0.isScheduledJob })" not in body(models, "static func canonicalized("):
    fail("job rows must never be prefix-merged")
print("COS Control: scheduled jobs pinned (0.5.229)")
SCHEDJOBS

/usr/bin/python3 - "$ROOT" <<'MERGEUI'
import os, re, sys, pathlib
root = pathlib.Path(sys.argv[1])

def code(path):
    # Comments are stripped: a clause that matches its own explanatory comment
    # cannot fail, and every check below is meant to be able to fail.
    return re.sub(r"//[^\n]*", "", (root / path).read_text())

helper = code("HelperSources/main.swift")
helper_raw = (root / "HelperSources/main.swift").read_text()
model = code("Sources/ControllerModel.swift")
models = code("Sources/Models.swift")
activity = code("Sources/ActivityWindow.swift")
meetings = code("Sources/ActivityMeetings.swift")

def fail(message):
    sys.exit(f"import-and-merge: {message}")

def body(text, marker):
    start = text.find(marker)
    if start < 0:
        fail(f"missing {marker}")
    depth = 0
    for j in range(text.index("{", start), len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[start:j + 1]
    fail(f"unterminated {marker}")

# 1. EVERY VERB IS DISPATCHED. A helper function nothing routes to is a feature
#    that does not exist, and the Swift side would fail with "unknown command".
for verb, fn in (
    ("meeting-recorders-detect", "emitMeetingRecordersDetect()"),
    ("fireflies-key-set", "emitFirefliesKeySet()"),
    ("fireflies-key-status", "emitFirefliesKeyStatus()"),
    ("fireflies-key-check", "emitFirefliesKeyCheck()"),
    ("fireflies-key-delete", "emitFirefliesKeyDelete()"),
    ("meeting-import-run", "emitMeetingImportRun(args: args)"),
    ("meeting-import-status", "emitMeetingImportStatus()"),
    ("meeting-import-settings", "emitMeetingImportSettings(args: args)"),
    ("meeting-suggestions", "emitMeetingSuggestions(args: args)"),
    ("meeting-suggestion-accept", 'emitMeetingSuggestionDecision(args: args, verb: "accept")'),
    ("meeting-suggestion-confirm", 'emitMeetingSuggestionDecision(args: args, verb: "confirm")'),
    ("meeting-suggestion-dismiss", 'emitMeetingSuggestionDecision(args: args, verb: "dismiss")'),
    ("meeting-actions", "emitMeetingActions(args: args)"),
    ("meeting-action", "emitMeetingAction(args: args)"),
    ("meeting-action-retry", "emitMeetingActionRetry(args: args)"),
    ("meeting-action-revert", "emitMeetingActionRevert(args: args)"),
    ("meeting-actions-revert-all", "emitMeetingActionsRevertAll(args: args)"),
    ("meeting-engine-status", "emitMeetingEngineStatus()"),
    ("meeting-engine-mode", "emitMeetingEngineMode(args: args)"),
):
    if f'case "{verb}": try {fn}' not in helper:
        fail(f"the helper must dispatch {verb} to {fn}")

# 2. THE KEY NEVER TOUCHES argv. `ps` shows every argument of every process on
#    this Mac to every user on it, and HelperClient logs its argument list.
key_set = body(helper, "private func emitFirefliesKeySet(")
if "FileHandle.standardInput.readDataToEndOfFile()" not in key_set:
    fail("fireflies-key-set must read the key from stdin")
if 'case "fireflies-key-set": try emitFirefliesKeySet()' not in helper:
    fail("fireflies-key-set must take no arguments at all, so there is no argument for a key to arrive in")
if "private func emitFirefliesKeySet() throws" not in helper:
    fail("emitFirefliesKeySet must take no args parameter")
for banned in ('option("--key"', "--key ", "--api-key", "--token"):
    if banned in key_set:
        fail(f"fireflies-key-set reads {banned!r}; a key in argv is a key published to this Mac")
save = body(model, "func saveFirefliesKey(")
if 'helper.run(["fireflies-key-set"], timeout: 60, stdinData: Data(trimmed.utf8))' not in save:
    fail("Control must send the key as stdinData with an argument list of exactly the verb")
if re.search(r'"fireflies-key-set",\s*"', save):
    fail("Control appends an argument to fireflies-key-set; the key must ride on stdin alone")
# And it must never be echoed back.
for surface in (key_set, save, body(meetings, "private var connectCard: some View {")):
    if "keyDraft" in surface and "SecureField" not in surface:
        fail("the key field must be a SecureField, and the key must never be rendered back")
if 'emit(ok: true, message: "Key saved"' not in helper:
    fail("the save confirmation must not quote what was typed")

# 3. ROUTE FLAGS AND OPENERS. 0.5.17 shipped two dead buttons because the opener
#    set one thing and the mount condition read another.
for flag, pane, opener, writes in (
    ("meetingImportRouteActive", "MeetingImportPane(model: model)", "func openMeetingImport()", "meetingImportOpen"),
    ("meetingSuggestionsRouteActive", "MeetingSuggestionsPane(model: model)", "func openMeetingSuggestions()", "meetingSuggestionsOpen"),
):
    if re.search(rf"else if section == \.meetings, model\.{flag} \{{\s*{re.escape(pane)}", activity) is None:
        fail(f"{pane} must sit on its own else if whose condition is exactly model.{flag}")
    route = re.search(rf"var {flag}: Bool \{{[^}}]*\}}", model, re.S)
    if route is None:
        fail(f"{flag} not found")
    # Word boundary: `meetingImportOpen` is a prefix of nothing here today, but
    # `contextDetailLoading` CONTAINS `contextDetail` and a substring check once
    # passed a flag reduced to its loading bool.
    if re.search(rf"\b{writes}\b", route.group(0)) is None:
        fail(f"{flag} does not read {writes}, the var its opener writes")
    body_opener = body(model, opener)
    if re.search(rf"\b{writes} = true\b", body_opener) is None:
        fail(f"{opener} does not set {writes}")
    if f"model.{flag}" not in activity:
        fail(f"{flag} is never read by ActivityWindow.swift")

# The openers are reachable, and they are mutually exclusive: opening one closes
# the other and the detail, or two panes claim the same route.
toolbar = body(meetings, "private var toolbar: some View {")
if 'Button("Import meetings") { model.openMeetingImport() }' not in toolbar:
    fail("Meetings must carry the Import meetings doorway")
if "model.openMeetingSuggestions() }" not in toolbar:
    fail("Meetings must carry the Suggested merges doorway")
for opener, closes in (("func openMeetingImport()", "meetingSuggestionsOpen = false"),
                       ("func openMeetingSuggestions()", "meetingImportOpen = false")):
    o = body(model, opener)
    if closes not in o or "closeLibraryDetail()" not in o:
        fail(f"{opener} must close the other pane and the detail")
# Back must leave each pane, or a person is stuck in it.
back = body(activity, "private func goBack() {")
for flag, closer in (("meetingImportRouteActive", "model.closeMeetingImport()"),
                     ("meetingSuggestionsRouteActive", "model.closeMeetingSuggestions()")):
    if re.search(rf"section == \.meetings, model\.{flag} \{{\s*{re.escape(closer)}", back) is None:
        fail(f"Back must leave the {flag} pane through {closer}")
if "model.meetingImportRouteActive || model.meetingSuggestionsRouteActive" not in activity:
    fail("hasDetail must count the new panes, or Back is not offered at all")

# 4. COPY. Each of these is the sentence the release plan specifies, verbatim.
for needle, why in (
    ('"Update the COS server to 6.47.0"', "route_absent names the version"),
    ('Button("Update Server") { model.perform("update") }', "route_absent carries the Update Server affordance"),
    ('"Your COS pipeline already brings in Fireflies meetings."', "a pipeline Mac says why it does not import"),
    ('"COS does not change your pipeline\'s files in advise mode. Your answers are saved."',
     "an advise-mode answer must not look like one that changed something"),
    ('"Would merge automatically"', "the advise-mode group title"),
    ('"Suggestions"', "the advise-mode undecided group title"),
    ('"Not the same meeting"', "the refuse action"),
    ('"Looks right"', "the advise-mode agree action"),
    ('"Merge"', "the imports-mode agree action"),
    ('"Import meetings"', "the import doorway"),
    ('"Suggested merges"', "the suggestions doorway"),
):
    if needle not in meetings:
        fail(f"copy lost {needle}: {why}")
for needle in ('"Merged automatically: G2 + Fireflies"', '"Merged from your suggestion"',
               '"Split from a longer recording"', '"Merged by your COS pipeline"'):
    if needle not in models:
        fail(f"a derived record's headline lost {needle}")
# 0.5.75: a case-sensitive test against prose is invisible when broken. The agree
# label is chosen by the MODE, never by a string match on server copy.
agree = body(meetings, "private func agreeLabel(")
if "model.meetingEngineStatus.mode == .imports" not in agree:
    fail("the agree label must follow the mode, because only imports mode writes anything")
# No em dashes or arrows in the copy THIS release writes. Scoped to the new
# views and models: pre-existing copy elsewhere is not this change's to rewrite.
raw_meetings = (root / "Sources/ActivityMeetings.swift").read_text()
new_copy = "".join(
    body(raw_meetings, marker)
    for marker in ("struct MeetingImportPane", "struct MeetingEngineStatusRow",
                   "struct MeetingSuggestionsPane", "struct MergedRecordActions")
)
raw_models = (root / "Sources/Models.swift").read_text()
new_copy += "".join(
    body(raw_models, marker)
    for marker in ("struct MeetingImportState", "struct MeetingSuggestion:", "struct MergeAction",
                   "struct MergeRevertPreview", "struct MeetingEngineStatus")
)
for line in new_copy.splitlines():
    stripped = line.lstrip()
    if stripped.startswith("//"):
        continue
    if "Text(" not in line and "return \"" not in line and ": \"" not in line:
        continue
    for bad in ("\u2014", "->", "\u2192"):
        if bad in line:
            fail(f"new copy renders {bad!r}: {stripped[:90]}")

# 5. THE MUTABLE GUARD. An imported meeting has no audio and a split piece is a
#    span; offering Review voices on either is an action the server refuses.
guard = body(models, "var canReviewVoices: Bool")
for need in ("!sessionId.isEmpty", "!isImported", "!isSplitPiece"):
    if need not in guard:
        fail(f"canReviewVoices lost {need}")
detail = body(meetings, "struct MeetingLibraryDetailPane")
if "if let row = model.openLibraryRow, row.canReviewVoices {" not in detail:
    fail("the detail's Review voices button must be gated on canReviewVoices")
if "MergedRecordActions(model: model, row: row, onOpenSource: onOpenSource)" not in detail:
    fail("a derived or imported record must show how it was made")
if "if row.isDerived || row.isImported {" not in detail:
    fail("only a derived or imported record shows the merge actions")

# 6. UNDO IS TWO CALLS, and the second sends back the hash the first returned.
preview_fn = body(model, "func previewMergeRevert(")
apply_fn = body(model, "func applyMergeRevert() async {")
if '"--dry-run"' not in preview_fn:
    fail("the Undo preview must ask for the dry run")
if "--preview-hash" in preview_fn:
    fail("the preview call must not send a hash; there is nothing to confirm yet")
if 'args += ["--preview-hash", preview.previewHash]' not in apply_fn:
    fail("applying an Undo must send back the preview's own hash")
if "--dry-run" in apply_fn:
    fail("the apply call must not be a dry run")
if "guard let preview = mergeRevertPreview else { return }" not in apply_fn:
    fail("an Undo may only apply a preview that is on screen")
revert_payload = body(helper, "private func revertPayload(")
if 'if args.contains("--dry-run") { return ["dryRun": true] }' not in revert_payload:
    fail("the helper must send dryRun for a preview")
if "Self.validPreviewHash(hash)" not in revert_payload:
    fail("a mangled preview hash must be refused here, not silently omitted and read as no preview at all")
actions_block = body(meetings, "struct MergedRecordActions")
if "if let preview = model.mergeRevertPreview, !preview.isAll, preview.actionId == (row.actionId ?? \"\") {" not in actions_block:
    fail("the preview must be shown before the second click, only for the record it belongs to, and never for revert-all")
if "model.previewMergeRevert(actionId: action.id)" not in actions_block:
    fail("Undo's first click asks for the preview")
if "model.applyMergeRevert()" not in actions_block:
    fail("the preview block must carry the button that applies it")
if "if let action, action.isRevertible {" not in actions_block:
    fail("a legacy pipeline merge must not be offered an Undo")
if "action.isLegacy" not in actions_block:
    fail("a merge the pipeline made must say who made it, rather than silently offering nothing")
for need in ("Button(action.retryLabel)", 'Button("Copy diagnostics")'):
    if need not in actions_block:
        fail(f"a failed merge lost {need}")

# 7. A DERIVED ROW IS NOT A CAPTURE. Its source reads "G2 Glasses + Fireflies",
#    so the string test says yes and would blame the glasses for a missing id.
if 'static func isG2Source(_ row: [String: Any]) -> Bool' not in helper:
    fail("isG2Source must have a row overload that can see derivedKind")
row_overload = body(helper, "static func isG2Source(_ row: [String: Any]) -> Bool")
if 'row["derivedKind"] as? String' not in row_overload or "return false" not in row_overload:
    fail("the row overload must answer false for a derived row")
if 'Self.isG2Source(row["source"] as? String ?? ""),' in helper:
    fail("the skipped-rows line must pass the ROW, so a merged record is not reported as a capture without a session id")
if '"isG2": Self.isG2Source(row),' not in helper:
    fail("the skipped-rows line must call the row overload")

# 7b. A RECORD 404 IS NOT AN UPDATE PROMPT. suggestion_not_found and
#     action_not_found come from a route that IS there.
absent = body(helper, "private func isRouteAbsent(")
if 'answer.body?["error"] == nil' not in absent or "answer.status == 404" not in absent:
    fail("isRouteAbsent must require BOTH a 404 and no error block")
# `helper` has its comments stripped, so the section is found by CODE.
merge_block = helper[helper.index("static let meetingMergeNeeds"):helper.index("private func queryEscape(")]
if "if answer.status == 404 {" in merge_block:
    fail("a raw 404 branch would tell a person to update their server because a record is gone")
# EQUALITY, NOT A FLOOR. A floor of 6 against 10 sites passed while four routes
# answered a 404 some other way; it could not fail. Every `route_absent` emit in
# this section must come from a discriminator call, and every discriminator call
# must lead to one, so the two counts move together or this goes red.
discriminated = merge_block.count("isRouteAbsent(answer)")
absent_emits = merge_block.count('"routeState": "route_absent"')
if discriminated == 0 or absent_emits == 0:
    fail("the merge routes lost their route-absent discrimination entirely")
if discriminated != absent_emits:
    fail(f"{discriminated} isRouteAbsent(answer) sites against {absent_emits} route_absent emits; "
         "a route either discriminates and says so, or does neither")

# 8. SERVER-FED LISTS SCROLL IN PLACE, inside a flexible frame with a floor. A
#    fixed cap bounds the list, not the card that holds it (0.5.222).
content = body(meetings, "private var content: some View {\n        if model.meetingSuggestionsState")
if re.search(r"ScrollView \{[\s\S]*?\.frame\(minHeight: MERGE_LIST_MIN_HEIGHT, maxHeight: \.infinity\)", content) is None:
    fail("the suggestions list must scroll inside a flexible frame with a floor")
if re.search(r"\.frame\(height: ", content):
    fail("the suggestions list must have no fixed height")
if "let MERGE_LIST_MIN_HEIGHT: CGFloat = 88" not in meetings:
    fail("the list floor is 88 pt, the same as the Speakers panes")
if "let MERGE_PANEL_WIDTH: CGFloat = 390" not in meetings:
    fail("the panel width the layout is proven against must be one named constant")
if "MERGE_CARD_MIN_WIDTH" in meetings:
    fail("MERGE_CARD_MIN_WIDTH was a constant nothing used; a claim nothing checks")
# NO minWidth ANYWHERE. A 390 pt minimum inside 22 pt of padding makes the
# content 434 pt wide in a 390 pt window: the card escapes instead of the list,
# which is the 0.5.222 mistake one layer out. `Tests/run-merge-ui.sh` renders
# every surface at exactly 390 pt and asserts the content stays inside it.
for view in ("struct MeetingImportPane", "struct MeetingSuggestionsPane", "struct MergedRecordActions",
             "struct MeetingEngineStatusRow"):
    # `minWidth: 0` is the 0.5.222 clamp and is required; any OTHER minimum is
    # the thing that broke, so the check names the value rather than the key.
    for match in re.findall(r"minWidth: ([^,)]+)", body(meetings, view)):
        if match.strip() != "0":
            fail(f"{view} sets minWidth: {match.strip()}; nothing here may be wider than the narrowest window")
for view in ("struct MeetingImportPane", "struct MeetingSuggestionsPane"):
    if "minHeight: 0, maxHeight: .infinity, alignment: .top)" not in body(meetings, view):
        fail(f"{view} must clamp itself; maxHeight alone leaves the ideal height and the header slides off the top")
if "minWidth" in body(meetings, "private struct MergeCard: ViewModifier"):
    fail("the shared card must not set a minWidth")

# 9. EVERY NEW MODEL FIELD HAS A WRITER. A field read in four places and assigned
#    nowhere is a feature that does not exist (glasses 0.5.229, taskLensStage).
#
#    THE DECLARATION IS NOT A WRITER. `@Published var meetingSuggestionsLoading =
#    false` matches `<field> =` on its own line, so the first version of this pin
#    passed for a field nothing else ever assigned: it could not fail. The
#    declaration line is removed before counting, and the count that matters is
#    what is left. Proven by deleting a writer in a scratch copy and watching this
#    go red (QA round 1, 2026-09-15).
declaration_lines = 0
for field in ("meetingImportOpen", "meetingSuggestionsOpen", "meetingSuggestions", "meetingSuggestionsState",
              "meetingSuggestionsLoading", "meetingSuggestionsError", "decidingSuggestion", "meetingEngineStatus",
              "meetingImport", "firefliesKey", "meetingRecorders", "mergeActions", "mergeRevertPreview",
              "pendingEngineMode", "meetingImportWindow", "meetingEngineError",
              "mergeActionsError", "mergeRevertNote", "firefliesKeyNote", "meetingImportError", "meetingImportLoading",
              "firefliesKeyBusy", "meetingEngineBusy", "mergeRevertBusy", "mergeActionsLoading"):
    if f"@Published var {field}" not in model:
        fail(f"{field} is not declared")
    # Drop the declaration ITSELF, whether or not it carries a default value.
    without_declaration, removed = re.subn(
        rf"^[ \t]*@Published var {field}\b[^\n]*\n", "", model, flags=re.M)
    if removed != 1:
        fail(f"{field} is declared {removed} times; the writer count below would be read against the wrong text")
    declaration_lines += removed
    writers = len(re.findall(rf"(?<![\w.]){field}\s*=(?!=)", without_declaration))
    if writers < 1:
        fail(f"{field} has no writer in ControllerModel outside its own declaration; "
             "it is read-only state that nothing can ever change")
if declaration_lines != 25:
    fail(f"the writer pin stripped {declaration_lines} declarations, not one per field it was given")

# 10. THE MODE SWITCH IS CONFIRMED, and the confirmation names what apply does.
mode_row = body(meetings, "struct MeetingEngineStatusRow")
if "model.armEngineMode(.apply)" not in mode_row or "model.armEngineMode(.advise)" not in mode_row:
    fail("the mode switch must arm a confirmation, never change the mode directly")
if "model.setEngineMode(pending)" not in mode_row:
    fail("only the confirmation may change the mode")
if "writes merged scribes into your operations tree" not in mode_row or "can be undone" not in mode_row:
    fail("the apply confirmation must name what apply does")
if "model.meetingEngineStatus.isPipelineMac" not in mode_row:
    fail("the mode switch belongs to a pipeline Mac only; there is nothing to choose elsewhere")
# cosConfirm dismisses BEFORE it runs the action, and dismissal nils the binding.
confirm_actions = body(meetings, "private var confirmActions: [COSConfirmAction] {")
if "let pending = model.pendingEngineMode" not in confirm_actions or "guard let pending else { return }" not in confirm_actions:
    fail("the confirmation action must capture its target before dismissal clears it")
if re.search(r"model\.pendingEngineMode", confirm_actions.split("return [", 1)[1]):
    fail("the confirmation action reads pendingEngineMode, which dismissal has already cleared")
# A 409 while a run is in flight is a wait message, not a failure.
set_mode = body(model, "func setEngineMode(")
if "state == .refused" not in set_mode or "meetingEngineError = " not in set_mode:
    fail("a refused mode change must land in meetingEngineError where the row renders it")
# The refusal SENTENCE is the server's and Control renders it verbatim, so there
# is nothing here to pin about its words. What IS Control's: the refusal must not
# be swallowed, and the row must have somewhere to show it.
if "meetingEngineError" not in body(meetings, "struct MeetingEngineStatusRow"):
    fail("the status row must render meetingEngineError, or a refused mode change is invisible")
# An unknown mode arms nothing: a switch away from a mode COS could not read is a
# change whose starting point nobody knows.
arm = body(model, "func armEngineMode(")
if "guard let current = meetingEngineStatus.mode" not in arm:
    fail("armEngineMode must require a KNOWN mode before it arms anything")

# 10b. THE ENGINE STATUS SHAPES ARE THE SERVER'S (docs/meeting-merge-contract.md).
#      `mergesRemainApplied` is a FLAG, `macClass` an OBJECT, and the five skip
#      reasons are its own words. Reading any of them as something else is a
#      decoder that renders a blank where a sentence belongs.
if 'mergesRemainApplied = details["mergesRemainApplied"]?.bool ?? false' not in models:
    fail("mergesRemainApplied is a flag on the wire, not a count")
if 'if let macClass = details["macClass"]?.object {' not in models:
    fail("macClass is an object on the wire: { observed, recorded, changed }")
if 'macClassChanged = macClass["changed"]?.bool ?? false' not in models:
    fail("the change flag lives inside the macClass object, not beside it")
if 'revertPending = counts?["revertPending"]?.int ?? 0' not in models:
    fail("an undo that cannot finish is counted on its own; folding it into pending hid it")
skipped = body(models, "var skippedReasonLine: String? {")
for reason in ("maintenance_deferred", "capture_active", "inputs_unchanged",
               "inputs_unreadable", "too_many_inputs"):
    if f'"{reason}"' not in skipped:
        fail(f"the {reason} skip has no sentence; it is one of the five the server sends")
if "default:" not in skipped:
    fail("a reason COS has no sentence for must still be shown, never swallowed")

# 11. THE MODE IS NOT KNOWN UNTIL THE SERVER SAYS SO (QA round 1). A failed status
#     load left the `.imports` default in place and a pipeline Mac in advise mode
#     drew the imports surface: "Merge", where agreeing writes nothing.
if "var mode: MeetingEngineMode?" not in models:
    fail("MeetingEngineStatus.mode must be optional; a default is a guess rendered as a fact")
status_init = body(models, "struct MeetingEngineStatus")
if 'MeetingEngineMode(rawValue: details["mode"]?.string ?? "") ?? .imports' in status_init:
    fail("the engine status must not default an unread mode to imports")
suggestions_pane = body(meetings, "struct MeetingSuggestionsPane")
if "model.meetingEngineStatus.modeKnown" not in suggestions_pane:
    fail("the suggestions pane must wait on a known mode before it labels anything")
gated = suggestions_pane.count("model.decidingSuggestion != nil || !model.meetingEngineStatus.modeKnown")
if gated != 2:
    fail(f"{gated} of the 2 answer buttons wait on a known mode; a substring check passed while only one did")
if "COS could not say how it is merging right now, so answering is off." not in suggestions_pane:
    fail("a failed engine-status load must be visible in the Suggested merges header")
# THE MODE IS READ FIRST, then the rows, or one render lands with rows on screen
# and no mode to label them by.
load_suggestions = body(model, "func loadMeetingSuggestions()")
head = load_suggestions.split('helper.run(["meeting-suggestions"', 1)[0]
if "await loadMeetingEngineStatus()" not in head:
    fail("loadMeetingSuggestions must read the engine status BEFORE it fetches the rows")
if load_suggestions.count("await loadMeetingEngineStatus()") != 1:
    fail("the status is read once, before the rows; a second read after them is the old order kept alive")

# 12. RETRY IS A ROUTE (QA round 1 blocker 4). 0.5.230's Retry only reloaded the
#     list, under a comment claiming the runner re-drove failed actions on its
#     next pass. It did not: a merge that failed twice was terminal from the UI.
retry = body(model, "func retryMergeAction(")
if '"meeting-action-retry", "--id", action.id' not in retry:
    fail("Retry must call the retry route, not refresh the list and hope")
if "response.message" not in retry:
    fail("the button must reflect the SERVER'S answer, including its 409 wait")
retry_verb = body(helper, "private func emitMeetingActionRetry(")
if '/retry' not in retry_verb or 'method: "POST"' not in retry_verb:
    fail("the helper's retry verb must POST to the action's retry route")
if "Self.validMergeActionID(id)" not in retry_verb:
    fail("a mangled action id must be refused here, not sent to a route")
# THE ROUTE ANSWERS {ok, state, direction}, not {action}. Reading a nested action
# would find nothing and report every retry as a merge, undos included.
if 'let direction = body["direction"] as? String ?? ""' not in retry_verb:
    fail("the retry verb must read the direction from the route's own body")
if 'Self.retryQueuedMessage(direction: direction)' not in retry_verb:
    fail("and the message it emits must be chosen by that direction")
# The side's `source` is a STORE NAME on the wire. Putting one in front of a
# person is the machine talking to itself.
if 'var sourceLabel: String' not in models or '"cos_operations"' not in models:
    fail("a side's store name must become a word before it is rendered")
if "if !sourceLabel.isEmpty { parts.append(sourceLabel) }" not in models:
    fail("the side's detail line must use the word, not the raw store name")
# Refresh stays its own affordance. One button doing both under the other's name
# is what made the false comment survive review.
actions_controls = body(meetings, "private var controls: some View {")
if 'Button("Refresh") { Task { await model.loadMergeActions() } }' not in actions_controls:
    fail("Refresh must be its own button; Retry asks the server to run the thing again")
if "action.isRetryable" not in actions_controls or "action.retryLabel" not in actions_controls:
    fail("Retry is offered by state and labelled by direction, never by a hardcoded word")
# A DEFERRED UNDO IS RECOVERABLE FROM THE UI (blocker 1's Control half).
if '"Undo waiting for the meeting sync"' not in models:
    fail("a parked undo must say it is waiting, not that it is running")
if "var isRetryable: Bool { isFailed || isRevertPending }" not in models:
    fail("revert_pending must be retryable, or the state has no way out of itself")
# A FAILED REVERT IS NOT A FAILED MERGE (blocker 2's Control half).
if 'let direction: String' not in models:
    fail("MergeAction must carry the direction its last attempt was going")
if '"Undo failed"' not in models:
    fail("a failed undo must say Undo failed")
# PASSED THROUGH, NEVER DEFAULTED. The server does not derive the direction from
# the state and says why: a retryable failure sends an action back to a WAITING
# state, so reading the direction out of it turned the retry of an undo into a
# redo. Stamping "apply" in the helper would erase the one distinction the Swift
# side is allowed to derive.
if 'row["direction"] as? String ?? "apply"' in helper:
    fail("the helper must not stamp a direction on a row that carries none")
if 'if let direction = row["direction"] as? String, !direction.isEmpty {' not in helper:
    fail("the helper must pass the direction through when the server sends one")
derive = body(models, "static func resolvedDirection(")
if 'actionState == "revert_pending" || actionState == "reverted"' not in derive:
    fail("the display fallback may derive only from the two states nothing but an undo produces")
if '"failed"' in derive:
    fail("a legacy failed row must NOT be guessed; that is the ambiguous case the server's rule exists for")
# A failed action's spawn detail travels whole. `Command failed` with an empty
# stderr is a non-zero exit, a timeout kill and a failed fork, told apart only by
# fields that are individually falsy.
if 'if let diagnostics = row["diagnostics"] as? [String: Any], !diagnostics.isEmpty {' not in helper:
    fail("the helper must carry the whole diagnostics block, not one readable field of it")
diag = body(models, "static func diagnosticLines(")
for field in ("code", "signal", "timedOut", "elapsedMs", "spawnError", "decisionInvalid", "stderr"):
    if f'"{field}"' not in diag:
        fail(f"Copy diagnostics drops {field}, which is one of the three bugs it exists to tell apart")
if "diagnosticLines" not in body(models, "var diagnostics: String {"):
    fail("Copy diagnostics must include the spawn detail, or it is a summary of a summary")

# 13. BOTH SIDES COME FROM THE SERVER (blocker 6). Control re-deriving the
#     Fireflies record id could only ever resolve an IMPORTED record, so on a
#     pipeline Mac every Fireflies side rendered as an id.
if "importedRecordID" in helper:
    fail("the helper must not re-derive an imported record id; the server resolves both sides")
if "meetingRowIndex" in helper:
    fail("the suggestions list must not join against GET /api/meetings")
if "/api/meetings?limit=50&domain=all" in helper:
    fail("the suggestions list must not restate the server's own list cap")
side = body(helper, "static func suggestionSide(")
if 'raw["resolved"] as? Bool ?? false' not in side:
    fail("resolved is the server's answer, not a flag derived from a list Control happened to hold")
if "index" in body(helper, "static func suggestionProjection("):
    fail("suggestionProjection must take no library index at all")
if 'var unresolvedNote: String?' not in models:
    fail("the caption belongs to a SIDE; one sentence on the header spoke for every row")
if "meetingSuggestionsUnresolved" in model or "meetingSuggestionsUnresolved" in meetings:
    fail("the pane-wide unresolved flag is gone; the caption is per side now")
if "if let note = side.unresolvedNote {" not in meetings:
    fail("the row must render the per-side caption, guarded by nothing but the note itself")

# 14. REVERT ALL HAS AN AFFORDANCE. Rollback tells a person to run this before
#     downgrading, and 0.5.230 shipped the whole code path with nothing anywhere
#     that reached it.
status_row = body(meetings, "struct MeetingEngineStatusRow")
if '"Undo all merges"' not in status_row:
    fail("the engine status row must offer Undo all merges")
if "model.previewRevertAllMerges()" not in status_row:
    fail("Undo all must go through the SAME preview-then-apply flow a single Undo uses")
if "model.applyMergeRevert()" not in status_row:
    fail("the revert-all preview must carry the button that applies it")
if "model.canRevertAllMerges" not in status_row:
    fail("Undo all is offered only when there is something to undo")
revert_all = body(model, "func previewRevertAllMerges()")
if 'previewMergeRevert(actionId: "")' not in revert_all:
    fail("Undo all is the empty-id preview, the branch applyMergeRevert already knows")
# The single-record card must not claim the revert-all preview.
if "let preview = model.mergeRevertPreview, !preview.isAll," not in body(meetings, "struct MergedRecordActions"):
    fail("a record's card must ignore a revert-all preview, or every open record shows it")

# 15. A FAILED ACTION LOAD IS VISIBLE, and an action off the end of the list is
#     fetched by id rather than leaving the card blank.
merged_card = body(meetings, "struct MergedRecordActions")
if "if let error = model.mergeActionsError {" not in merged_card:
    fail("mergeActionsError must render on the card; it was recorded and shown nowhere")
if "model.loadMergeAction(id: id)" not in merged_card:
    fail("an action older than the 100-row list must be fetched by id")
single = body(model, "func loadMergeAction(")
if '"meeting-action", "--id", id' not in single:
    fail("the single-action fetch must call the single-action verb")
if "!mergeActions.contains(where: { $0.id == id })" not in single:
    fail("the single fetch must skip an action the list already holds, or every open costs a request")

# 16. NO RESTATED SERVER LITERALS IN THE COPY OR THE PICKERS. The windows and the
#     plan caps belong to the server; Control keeps ONE pinned fallback for a
#     server that does not send them, and builds every sentence from whichever
#     list is in force. The definitions:
#       IMPORT_WINDOW_DAYS   server/lib/meeting-import.ts
#       FIREFLIES_PLAN_CAPS  server/lib/fireflies-client.ts
run_card = body(meetings, "private var runCard: some View {")
for banned in ('Text("Last 7 days").tag(7)', 'Text("Free").tag("free")', "Free is 50, Pro is 500"):
    if banned in run_card:
        fail(f"the import card restates {banned!r}; the server owns that number")
if "ForEach(model.meetingImport.windowOptions" not in run_card:
    fail("the window picker must be built from the windows in force")
if "ForEach(model.meetingImport.planCaps" not in run_card:
    fail("the plan picker must be built from the plans in force")
if "Text(model.meetingImport.planCapLine)" not in run_card:
    fail("the plan sentence must be built from the caps, never typed")
import_state = body(models, "struct MeetingImportState")
if "static let fallbackWindowOptions = [7, 30, 90]" not in import_state:
    fail("the window fallback must match IMPORT_WINDOW_DAYS in server/lib/meeting-import.ts")
for plan, calls in (("free", "50"), ("pro", "500")):
    if f'FirefliesPlanCap(id: "{plan}", label: "{plan.capitalize()}", calls: {calls})' not in import_state:
        fail(f"the {plan} fallback must match FIREFLIES_PLAN_CAPS in server/lib/fireflies-client.ts")
if 'FirefliesPlanCap(id: "business", label: "Business", calls: nil)' not in import_state:
    fail("business is uncapped in FIREFLIES_PLAN_CAPS, and nil must not become a cap of zero")
for path in ("server/lib/meeting-import.ts", "server/lib/fireflies-client.ts"):
    if path not in (root / "Sources/Models.swift").read_text():
        fail(f"the fallback list must name {path}, where the value it mirrors actually lives")

# 17. A SPLIT IS ONLY ACCEPTABLE WHERE THE SERVER CAN WRITE PIECES (blocker 7's
#     Control half). Apply mode answers 409 split_not_supported_in_apply_mode, so
#     a button that can only fail is not offered.
if "private func splitIsUnavailable(" not in suggestions_pane:
    fail("the pane must know when a split cannot be accepted")
split_gate = body(meetings, "private func splitIsUnavailable(")
if "suggestion.isSplit" not in split_gate or "model.meetingEngineStatus.mode != .imports" not in split_gate:
    fail("a split is unavailable exactly when the mode is not imports")
if "Splits arrive as suggestions in apply mode." not in suggestions_pane:
    fail("and the row must say so rather than showing nothing")
if "if !splitIsUnavailable(suggestion) {" not in suggestions_pane:
    fail("the agree button must be hidden for a split the server will refuse")

# 18. THE TWO NATIVE RENDER HARNESSES ARE SEPARATE ON PURPOSE, and pinned here so
#     they cannot rot unnoticed.
#
#     `Tests/HeldNamingUI.swift` and `Tests/MergeUI.swift` render real SwiftUI
#     views offscreen, which needs a WindowServer session. `Tests/run.sh` is run
#     headless (ssh, agents, CI), where NSHostingView cannot draw at all, so
#     folding them in would make the whole suite unrunnable there rather than
#     catching anything. They are release gates, run by hand on a logged-in Mac:
#         ./Tests/run-merge-ui.sh && ./Tests/run-held-ui.sh
#     What run.sh CAN see is that the harness still exists, still compiles the
#     same sources, and still carries the assertion that matters. This is a SHAPE
#     check standing in for a run, and it says so.
for script, entry in (("Tests/run-merge-ui.sh", "Tests/MergeUI.swift"),
                      ("Tests/run-held-ui.sh", "Tests/HeldNamingUI.swift")):
    path = root / script
    if not path.exists() or not os.access(path, os.X_OK):
        fail(f"{script} must exist and be executable; it is a release gate")
    text = path.read_text()
    if entry not in text:
        fail(f"{script} must compile {entry}")
    for source in ("Sources/ActivityMeetings.swift", "Sources/ActivityWindow.swift", "Sources/ControllerModel.swift"):
        if source not in text:
            fail(f"{script} must compile {source}, or it renders a view that is not the shipped one")
merge_ui = (root / "Tests/MergeUI.swift").read_text()
# THE LIST MUST ACTUALLY SCROLL. A document taller than its viewport is geometry;
# a clip view that moves is behaviour, and the two came apart in 0.5.222.
if "list.contentView.scroll(to:" not in merge_ui or "reflectScrolledClipView" not in merge_ui:
    fail("the merge UI harness must scroll the list, not only measure it")
if "list.contentView.bounds.origin.y != resting" not in merge_ui:
    fail("the merge UI harness must assert the list MOVED when it was scrolled")
if "MERGE_PANEL_WIDTH" not in merge_ui:
    fail("the harness must render at the panel width the views are laid out for")
if "undo-failed" not in merge_ui:
    fail("the harness must render a failed undo, the state whose words this release fixed")

# 19. NO CONSTANT CONDITIONS in the views this release wrote. `if false, let x`
#     leaves every mention of `x` in place, so a presence check reads green while
#     the branch is dead — the shape that got five mutations past the first
#     version of these pins (QA round 1).
for marker in ("struct MeetingImportPane", "struct MeetingEngineStatusRow",
               "struct MeetingSuggestionsPane", "struct MergedRecordActions"):
    section = body(meetings, marker)
    for dead in ("if false", "if true"):
        if dead in section:
            fail(f"{marker} carries `{dead}`; a branch switched off in place is invisible to every other check here")

print("COS Control: import and merge routes, openers, copy, mutable guard and Undo preview pinned (0.5.230)")
MERGEUI

# ── 0.5.232: Markdown panes, action weights, server-derived session state ─────
#
# The parser is EXECUTED above (markdown-contract). What is pinned here is the wiring
# that the contract cannot see: which panes render through the view, that the meeting
# file is the body ONCE, that the copy actions still copy the stored text, the three
# button weights, and that the server's state reaches ClaudeSession and outranks the
# helper's transcript guess only when its source says so.
/usr/bin/python3 - "$ROOT" <<'MARKDOWN'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
def code(rel): return (root / rel).read_text()
def fail(msg): sys.exit("0.5.232 pin: " + msg)
def body(text, marker):
    i = text.index(marker)
    depth = 0; j = i
    while j < len(text):
        if text[j] == "{": depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0: return text[i:j + 1]
        j += 1
    fail(f"unbalanced braces after {marker}")

md = code("Sources/COSMarkdown.swift")
parser = code("Sources/COSMarkdownParser.swift")
meetings = code("Sources/ActivityMeetings.swift")
views = code("Sources/Views.swift")
activity = code("Sources/ActivityWindow.swift")
models = code("Sources/Models.swift")
brand = code("Sources/COSBrand.swift")
helper = code("HelperSources/main.swift")

# 1. The parser never imports SwiftUI: the contract compiles it alone, on purpose.
if "import SwiftUI" in parser or "import AppKit" in parser:
    fail("COSMarkdownParser.swift must stay Foundation-only so the contract can execute it")
if "struct COSMarkdownView" not in md or "COSMarkdownParser.parse(" not in md:
    fail("COSMarkdownView must render the parser's blocks")

# 2. Every pane renders through the ONE view, and each is the body once.
pane = body(meetings, "struct MeetingLibraryDetailPane")
if "COSMarkdownParser.looksLikeDocument(detail.transcript)" not in pane:
    fail("the meeting pane must decide document-vs-fields with looksLikeDocument")
if "COSMarkdownView(text: detail.transcript, dropLeadingTitle: true)" not in pane:
    fail("a document meeting renders the file once, title dropped")
if 'labeled("Attendees"' not in pane or 'labeled("Summary"' not in pane:
    fail("a non-document record keeps its labelled fields")
if "COSMarkdownView(text: body)" not in pane:
    fail("the labelled fields render as Markdown too")
ctx = body(views, "struct ContextDetailPane")
if "COSMarkdownView(text: record.body, dropLeadingTitle: true" not in ctx:
    fail("threads and memories render their body as Markdown, title dropped")
if 'Text(record.body.isEmpty ? "(no stored body)" : record.body)' in ctx:
    fail("the raw thread body Text is still there")
sessions = body(activity, "struct ClaudeSessionDetailPane")
if "COSMarkdownView(text: turn.text)" not in sessions or "if turn.isUser {" not in sessions:
    fail("an assistant turn renders as Markdown and a user turn as typed")

# 3. Copy actions copy the stored text: no copy path goes through the renderer.
for src in (code("Sources/ControllerModel.swift"),):
    for name in ("func copyLibraryMeeting", "func copyContextRecord", "func copyClaudeSession"):
        if name not in src: fail(f"{name} moved; the copy-stays-raw pin must follow it")
        if "COSMarkdown" in body(src, name): fail(f"{name} must copy the stored Markdown, not the rendered text")

# 4. The three weights, and where they sit.
if "case standard, destructive, featured" not in brand: fail("COSQuietButtonStyle needs the featured tone")
if "struct COSNewPill" not in brand: fail("the NEW pill is missing")
actions = pane[pane.index("Actions by weight"):]
first_button = re.search(r'Button\("([^"]+)"', actions).group(1)
if first_button != "Copy as context": fail(f"the meeting pane's first action must be Copy as context, got {first_button}")
if ".buttonStyle(COSPrimaryButtonStyle())" not in actions.split('Button("Copy summary")')[0]:
    fail("Copy as context must be the primary button")
if '.keyboardShortcut("c", modifiers: .command)' not in actions: fail("Copy as context takes ⌘C")
if "COSQuietButtonStyle(tone: isNew ? .featured : .standard)" not in actions or "if isNew { COSNewPill() }" not in actions:
    fail("Review voices is featured with its NEW pill inside the label while the meeting is new")
if "MeetingStatusPills(\n                            isNew: false," not in actions:
    fail("the standalone New pill beside Review voices must be off; it lives inside the button now")
ctx_actions = ctx[ctx.index("Actions by weight"):]
if 'Button("Copy as Context") { model.copyContextRecord(record) }\n                        .buttonStyle(COSPrimaryButtonStyle())' not in ctx_actions:
    fail("Copy as Context is the primary on a thread or memory")

# 5. Server-derived state: the eight fields, the mapping, and its precedence.
for key in ("agentState", "stateSource", "stateSince", "waitingKind", "waitingDetail", "failure", "lastReply"):
    if f'{key} = o["{key}"]' not in models: fail(f"ClaudeSession must decode {key}")
if 'queuedTurns = o["queuedTurns"]?.int ?? 0' not in models: fail("ClaudeSession must decode queuedTurns as a number")
if "static func serverStateProjection" not in helper or "static func sessionStateFromServer" not in helper:
    fail("the helper's server-state projection and mapping are missing")
for fn in ("agentSessionRowProjection", "claudePeerProjection", "sessionSearchHitProjection"):
    if "serverStateProjection(row)" not in body(helper, f"static func {fn}"):
        fail(f"{fn} must carry the server state")
if "for (_, key) in serverStateKeys where peer[key] != nil" not in body(helper, "static func overlayLiveState"):
    fail("the overlay must copy the server state from the peer")
live = body(helper, "static func applyLiveWorkingState")
if live.index("sessionStateFromServer(") > live.index('activitySource"] as? String == "transcript"'):
    fail("the server-state branch must come BEFORE the transcript branch in applyLiveWorkingState")
if 'stateSource == "hook" || stateSource == "registry"' not in helper:
    fail("only a hook- or registry-sourced state may outrank the transcript")
if '"failed": return "error"' not in helper: fail("failed maps to the pet's error word")
if 'case "error": "Failed"' not in models: fail("a failed session never captions Idle")
if "static func needsAPerson" not in models or "session.state == \"waiting\" || session.state == \"error\"" not in models:
    fail("a failed turn rides the waiting channel")
label = body(models, "var stateLabel: String")
if 'case "error": failure.isEmpty ? "Failed"' not in label or "queued" not in label:
    fail("stateLabel must read Failed and count queued follow-ups")

print("COS Control: Markdown panes, action weights and server-derived session state pinned (0.5.232)")
MARKDOWN

# ── 0.5.233: live session pane, hooks banner, composer queue line ─────────────
#
# The reducer is EXECUTED above (session-live-feed-contract) and the helper's SSE
# parser in its self-test. Pinned here is the wiring neither can see: the helper verb
# exists and streams on the PROGRESS channel (stdout is buffered until exit), the app
# reaches it only through HelperClient with no timeout and cancels it on close, the
# reconnect is bounded and resumes with the last id, the pane draws the feed above the
# stored turns, the composer names the fork mode and the queue, and the hooks banner
# offers Install for missing/drift and Update Server for a pre-6.48.0 route.
/usr/bin/python3 - "$ROOT" <<'LIVEPANE'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
def code(rel): return (root / rel).read_text()
def fail(msg): sys.exit("0.5.233 pin: " + msg)
def body(text, marker):
    i = text.index(marker)
    j = text.find("\n    // MARK:", i + 1)
    return text[i:j if j > 0 else len(text)]

helper = code("HelperSources/main.swift")
for verb in ('case "session-stream": try emitSessionStream(args: args)',
             'case "session-hooks-status": try emitSessionHooksStatus()',
             'case "session-hooks-install": try withMutationLock { try emitSessionHooksInstall() }'):
    if helper.count(verb) != 1:
        fail("helper verb missing or duplicated: " + verb)
stream = body(helper, "private func emitSessionStream(args: [String]) throws")
if "progress(line)" not in stream:
    fail("session-stream must write each event line on the progress channel (stderr), never stdout")
if 'emit(ok: true, message: "Stream ended", details: ["reason": reason' not in stream:
    fail("session-stream ends with one JSON on stdout carrying the reason")
if 'reason = "heartbeat_gap"' not in stream or 'reason = "max_seconds"' not in stream or 'reason = "http_\\(status)"' not in stream:
    fail("session-stream names heartbeat_gap, max_seconds and http_<status> as end reasons")
if 'request.setValue(token, forHTTPHeaderField: "X-COS-Token")' not in stream:
    fail("session-stream authenticates with the app token header")
if r"^[0-9]{1,16}(\\.[0-9]{1,12})?$" not in stream:
    fail("--after accepts only an <epoch>.<cursor> cursor")
install = body(helper, "private func emitSessionHooksInstall() throws")
if 'request("/api/session-hooks/status"' not in install or 'hooks["installed"] as? Bool == true' not in install:
    fail("session-hooks-install re-checks status and requires installed == true (mirrors requireClaudeSessions)")
status = body(helper, "private func emitSessionHooksStatus() throws")
if '"state": "route_absent"' not in status or '"state": "unreachable"' not in status:
    fail("hooks status distinguishes route_absent (404) from unreachable (no answer)")

model = code("Sources/ControllerModel.swift")
if model.count('helper.run(args, timeout: nil)') != 1 or '["session-stream", "--provider", session.provider, "--session", session.sessionId]' not in model:
    fail("the app opens the stream through HelperClient.run with no timeout, exactly once")
if "static let sessionStreamRetryDelays: [UInt64] = [2, 4, 8]" not in model:
    fail("reconnect is bounded to three tries with backoff")
if 'args += ["--after", after]' not in model or 'args += ["--seed", "turn"]' not in model:
    fail("a reconnect resumes with --after; a first open seeds the current turn")
if 'return .retry(lastID: sessionFeed?.lastID)' not in model:
    fail("a retry carries the last id the feed saw")
if 'case "heartbeat_gap", "closed", "max_seconds": return .retry' not in model or 'default:\n                // http_404' not in model:
    fail("heartbeat_gap/closed/max_seconds retry; http_404/http_503 stop and fall back to the poll")
close = body(model, "func closeClaudeSession()")
if "stopSessionStream()" not in close:
    fail("closing the pane cancels the stream process")
if model.count("startSessionStream(session)") != 1:
    fail("the stream starts once, when the pane opens")
if "sessionStreamTask?.cancel()" not in body(model, "private func startSessionStream("):
    fail("opening a second pane cancels the first stream")
if "Task { [weak self] in await self?.refreshSessionHooksStatus(force: force) }" not in body(model, "func loadClaudeSessions(force: Bool = false) async"):
    fail("the hooks status refreshes with the sessions list")
if 'if !force, Date().timeIntervalSince(sessionHooksCheckedAt) < 60 { return }' not in model:
    fail("the hooks status is cached 60 s")

window = code("Sources/ActivityWindow.swift")
pane = body(window, "struct ClaudeSessionDetailPane: View")
if "SessionActivityFeed(feed: model.sessionFeed, queued: model.openClaudeRow?.queuedTurns ?? 0)" not in pane:
    fail("the detail pane draws the live feed above the stored turns")
if pane.index("SessionActivityFeed(") > pane.index("ForEach(detail.turns"):
    fail("the feed sits ABOVE the turns")
feedview = body(window, "struct SessionActivityFeed: View")
if "Timer.publish(every: 1, on: .main, in: .common).autoconnect()" not in feedview or "feed.elapsed(now: now)" not in feedview:
    fail("elapsed ticks locally once a second off the feed's clock")
if "ForEach(feed.tools)" not in feedview or "Text(feed.stateWord)" not in feedview or "Text(feed.prompt)" not in feedview:
    fail("the feed draws the state word, the prompt and the tool lines")
for reason in ('case "http_404"', 'case "http_503"', 'case "stream_lost"'):
    if reason not in feedview:
        fail("the fallback line names " + reason)
composer = body(window, "struct SessionChatComposer: View")
if "The reply lands in the transcript; the open desk tab will not show it until you resume." not in composer:
    fail("the composer names the fork mode when another app holds the session")
if "follow-up queued; it lands when this turn ends." not in composer:
    fail("the composer shows the queued follow-ups")
banner = body(window, "@ViewBuilder private var sessionHooksBanner: some View")
if 'state == "missing" || state == "drift" || state == "script_outdated" || state == "route_absent"' not in banner:
    fail("the banner shows for missing, drift, script_outdated and route_absent only")
if 'Button("Update Server") { model.perform("update") }' not in banner:
    fail("a pre-6.48.0 server offers Update Server, never Install")
if "model.installSessionHooks()" not in banner or '.buttonStyle(COSQuietButtonStyle(tone: .featured))' not in banner:
    fail("Install hooks is the featured action")
if "unreachable" in banner.split("if model.claudeSessionsEnabled")[1].split("{")[0]:
    fail("an unreachable server shows no banner")
if window.count("sessionHooksBanner") != 2:
    fail("the banner is declared once and mounted once, under the sessions search bar")

models = code("Sources/Models.swift")
if 'queuedTurns = o["queuedTurns"]?.int ?? 0' not in models:
    fail("ClaudeSession decodes queuedTurns")

for rel in ("Tests/run.sh", "scripts/build-release.sh", "Tests/run-held-ui.sh", "Tests/run-merge-ui.sh", "Tests/run-markdown-ui.sh"):
    if "Sources/SessionLiveFeed.swift" not in code(rel):
        fail(rel + " must compile SessionLiveFeed.swift")
print("COS Control: live session pane, hooks banner and composer queue line pinned (0.5.233)")
LIVEPANE

# ---- Meeting sync rows (0.5.237) --------------------------------------
/usr/bin/grep -q '"meetingSyncMeetings": Self.meetingSyncRows(meetings),' "$ROOT/HelperSources/main.swift"
/usr/bin/grep -q 'ForEach(model.status.meetingSyncMeetings.prefix(4)) { row in' "$ROOT/Sources/Views.swift"
/usr/bin/grep -q 'let prefillValue = model.status.progressiveHqValue' "$ROOT/Sources/Views.swift"
if /usr/bin/grep -q 'sealed · \\(tier)\\(threadLabel)' "$ROOT/Sources/Views.swift"; then
  echo "FAIL: the panel builds its own prefill string again; it must read progressiveHqValue" >&2; exit 1
fi
echo "COS Control: meeting sync rows and prefill wording pinned (0.5.237)"

echo "COS Control: helper self-tests, secret-boundary checks, and macOS 14 builds passed"
