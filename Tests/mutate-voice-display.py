#!/usr/bin/env python3
"""0.5.357 (server 6.96.3): the mutation gate for merged Speakers rows, Suggest names and the one-click batch.

SERIAL by design: one compile at a time, each through Tests/compile-guard.sh. Works on a scratch copy, so the checkout is never
mutated. A GREEN baseline of every lane is required before the first mutant, and each mutant must replace its target exactly once.

A KILL counts only when the mutant compiles, runs, and the check that fails first is the one the mutant names (its behaviour in
"check failed [<behaviour>]"). Everything else fails this gate on its own line: SURVIVED, MISATTRIBUTED, INVALID (did not compile
or timed out). A mutant named CRASH must trap: removing that guard makes Dictionary(uniqueKeysWithValues:) trap, which is the failure.

Model mutants take about 25 seconds each. A helper mutant rebuilds the helper. The controller mutants share one rebuild of the app kit, about 5 minutes.

Usage: python3 Tests/mutate-voice-display.py <repo root> [--lanes model,helper,controller] [--only <name prefix>[|<prefix>...]]
"""
import os, pathlib, shutil, subprocess, sys, tempfile

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import mutate_bounded

root = pathlib.Path(sys.argv[1]).resolve()
lanes = (sys.argv[sys.argv.index("--lanes") + 1] if "--lanes" in sys.argv else "model,helper,controller").split(",")
only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else ""
M, C, H = "Sources/Models.swift", "Sources/ControllerModel.swift", "HelperSources/main.swift"

MODEL = [
    ("layout: interval metadata ignored", M, "guard isMacRecording, !intervalViewReadOnly, effectiveSpeakerSummary == nil, !callViewApplied, let hint = voiceDisplay",
     "guard isMacRecording, effectiveSpeakerSummary == nil, !callViewApplied, let hint = voiceDisplay", "interval metadata leaves the list alone"),
    ("layout: applied view ignored", M, "effectiveSpeakerSummary == nil, !callViewApplied, let hint = voiceDisplay", "effectiveSpeakerSummary == nil, let hint = voiceDisplay", "applied view leaves the list alone"),
    ("layout: hint read on a G2 meeting", M, 'voiceDisplay = sessionId.hasPrefix("mac_") ? VoiceDisplayHint(o["voiceDisplay"]) : nil', 'voiceDisplay = VoiceDisplayHint(o["voiceDisplay"])', "mac only"),
    ("layout: Ext and names can move", M, "guard MacVoiceLabel.isVoice(label), let voice = byLabel[label], used.insert(label).inserted else { return nil }",
     "guard let voice = byLabel[label], used.insert(label).inserted else { return nil }", "named never folded"),
    ("layout: a label can land twice", M, "guard MacVoiceLabel.isVoice(label), let voice = byLabel[label], used.insert(label).inserted else { return nil }\n            return voice",
     "guard MacVoiceLabel.isVoice(label), let voice = byLabel[label] else { return nil }\n            used.insert(label)\n            return voice", "exactly once"),
    ("layout: a repeated label is placed", M, "        guard Set(ordered.map(\\.label)).count == ordered.count else { return nil }\n", "", "CRASH"),
    ("layout: a stale total kept", M, "seconds: whole ? group.seconds : nil", "seconds: group.seconds", "stale total dropped"),
    ("layout: a group of one stays a group", M, "if members.count >= 2 {", "if members.count >= 1 {", "group of one is a row"),
    ("layout: smallest group first", M, "func rank(_ a: Double?, _ b: Double?) -> Bool { (a ?? -1) > (b ?? -1) }", "func rank(_ a: Double?, _ b: Double?) -> Bool { (a ?? -1) < (b ?? -1) }", "order"),
    ("layout: an unmentioned voice is lost", M, "let rest = ordered.filter { !used.contains($0.label) }", "let rest = ordered.filter { !used.contains($0.label) && !MacVoiceLabel.isVoice($0.label) }", "unused hint keeps today's order"),
    ("hint: any source", M, 'guard let o = value?.object, o["source"]?.string == "speaker-shadow",\n', "guard let o = value?.object,\n", "malformed hint is absent"),
    ("hint: any fold floor", M, '              SpeakerGroupScope.exactInt(o["foldUnderSeconds"]) == Self.foldUnderSeconds,\n', "", "malformed hint is absent"),
    ("hint: a long voice folds", M, ', let seconds = Self.seconds(g["seconds"]), seconds < Double(Self.foldUnderSeconds) else { return nil }', ', let seconds = Self.seconds(g["seconds"]) else { return nil }', "short floor"),
    ("naming: a scoped voice named plainly", M, "            && !groupScopes.contains { $0.displayLabel == voice.label }\n", "", "scoped member keeps its path"),
    ("naming: read-only can name", M, "mutable && isMacRecording && voice.canRename && MacVoiceLabel.isVoice(voice.label)", "isMacRecording && voice.canRename && MacVoiceLabel.isVoice(voice.label)", "read-only never names together"),
    ("suggest: a read-only review offers it", M, "isMacRecording && mutable && !recordId.isEmpty && sourceRevision.map", "isMacRecording && !recordId.isEmpty && sourceRevision.map", "saved mac calls only"),
    ("suggest: no confirmation needed", M, 'guard let o = value.object, o["requiresConfirmation"]?.bool == true,\n', "guard let o = value.object,\n", "suggestion must require confirmation"),
    ("suggest: Ext can be suggested", M, "              labels.allSatisfy(MacVoiceLabel.isVoice),\n", "", "no ext suggestions"),
    ("suggest: another model space", M, 'if state == .done, o["modelSpace"]?.string == "192d", o["rule"]?.object != nil {', 'if state == .done, o["rule"]?.object != nil {', "model space bound"),
    ("suggest: not bound to the revision", M, "guard let job, job.state == .done, let revision = job.sourceRevision, revision == review.sourceRevision else { return [] }",
     "guard let job, job.state == .done else { return [] }", "new revision says why"),
    ("suggest: 404 does not hide", M, "func showsButton(for review: SpeakerReview) -> Bool { review.canSuggestNames && probed && !routeAbsent }", "func showsButton(for review: SpeakerReview) -> Bool { review.canSuggestNames && probed }", "404 hides the button"),
    ("suggest: button before any answer", M, "func showsButton(for review: SpeakerReview) -> Bool { review.canSuggestNames && probed && !routeAbsent }", "func showsButton(for review: SpeakerReview) -> Bool { review.canSuggestNames && !routeAbsent }", "button waits for the route"),
    ("suggest: stale line lost", M, "if job.state == .idle, self.job?.state == .done, self.job?.sourceRevision != job.sourceRevision {", "if false, job.state == .idle, self.job?.state == .done, self.job?.sourceRevision != job.sourceRevision {", "new revision says why"),
    ("suggest: a stopped job says nothing", M, 'case "recording_active": return "A recording started, so the voice check stopped. Try again when it ends."\n', "", "a stopped job says what stopped it"),
    ("suggest: code shown as words", M, 'case "recording_active": return "A recording is active. Try again when it ends."\n', "", "refusal in plain words"),
    ("suggest: across rows attaches", M, "row.contains(label) && review.voices.contains { $0.label == label && review.canNameAlone($0) }", "review.voices.contains { $0.label == label && review.canNameAlone($0) }", "single row holds its suggestion"),
    ("suggest: narrowest first", M, "a.element.labels.count != b.element.labels.count ? a.element.labels.count > b.element.labels.count : a.offset < b.offset", "a.element.labels.count != b.element.labels.count ? a.element.labels.count < b.element.labels.count : a.offset < b.offset", "two suggestions on one row"),
    ("suggest: coverage words gone", M, 'total > 1 ? "Suggested: \\(name) for \\(covering) of \\(total) voices" : "Suggested: \\(name)"', '"Suggested: \\(name)"', "coverage words"),
    ("batch: under .80 joins", M, "guard found.highConfidence, !owners.contains(found.name), used.isDisjoint(with: found.labels) else { return nil }", "guard !owners.contains(found.name), used.isDisjoint(with: found.labels) else { return nil }", "under .80 excluded"),
    ("batch: score recomputed", M, 'highConfidence = o["highConfidence"]?.bool == true', 'highConfidence = o["highConfidence"]?.bool == true && score >= 0.8', "the flag decides"),
    ("batch: a label travels twice", M, "guard found.highConfidence, !owners.contains(found.name), used.isDisjoint(with: found.labels) else { return nil }", "guard found.highConfidence, !owners.contains(found.name) else { return nil }", "a label travels once"),
    ("batch: the wearer joins", M, "guard found.highConfidence, !owners.contains(found.name), used.isDisjoint(with: found.labels) else { return nil }", "guard found.highConfidence, used.isDisjoint(with: found.labels) else { return nil }", "owner never in the batch"),
    ("batch: ticks ignored", M, "func ticked(_ candidates: [VoiceBatchCandidate]) -> [VoiceBatchCandidate] { candidates.filter(isTicked) }", "func ticked(_ candidates: [VoiceBatchCandidate]) -> [VoiceBatchCandidate] { candidates }", "count follows the ticks"),
    ("batch: sends at zero", M, "guard !rows.isEmpty, let revision = review.sourceRevision else { return nil }", "guard let revision = review.sourceRevision else { return nil }", "nothing to send at zero"),
    ("batch: a refusal keeps names", M, 'named = state == .refused ? [] : (o["named"]?.array ?? []).compactMap(VoiceBatchRow.init)', 'named = (o["named"]?.array ?? []).compactMap(VoiceBatchRow.init)', "refusal names nothing"),
    ("batch: a refusal lists rows", M, '        if state == .refused { return "Nothing was named. " + VoiceDisplayCopy.batchReason(reason ?? notNamed.first?.reason) + "." }\n', "", "refusal line"),
    ("batch: applied with no rows succeeds", M, "if state == .applied, notNamed.isEmpty, !named.isEmpty {", "if state == .applied, notNamed.isEmpty {", "applied with no rows is not a success"),
    ("batch: 404 does not hide", M, "func showsControls(for review: SpeakerReview) -> Bool { review.canSuggestNames && probed && !routeAbsent }", "func showsControls(for review: SpeakerReview) -> Bool { review.canSuggestNames && probed }", "404 hides the batch"),
    ("batch: a failed list shows controls", M, "        } else if let rows = details[\"batches\"]?.array {\n            next.probed = true\n", "        } else if let rows = details[\"batches\"]?.array {\n", "empty list shows controls"),
    ("outcome: one label too many named", M, "var named: [String] { Array(labels.prefix(namedCount)) }", "var named: [String] { Array(labels.prefix(namedCount + 1)) }", "partway named"),
    ("outcome: one label dropped", M, "var notNamed: [String] { Array(labels.dropFirst(namedCount)) }", "var notNamed: [String] { Array(labels.dropFirst(namedCount + 1)) }", "partway not named"),
    ("plan: a flagged label forced", M, "MacAssignRequest.flags(for: correction, renameOnly: correction.needsForceToAddSamples, addAnyway: false, armed: false) ?? []", "MacAssignRequest.flags(for: correction, renameOnly: false, addAnyway: true, armed: true) ?? []", "flagged stays text only"),
    ("r2 reveal: merged member not held", M, "if case .merged(let merged) = row, merged.labels.contains(label) { return .merged(merged.id) }", "if case .merged(let merged) = row, merged.labels.isEmpty { return .merged(merged.id) }", "holder of a merged member"),
    ("r2 reveal: short voice not held", M, "return short.contains { $0.label == label } ? .short : nil", "return nil", "holder of a short voice"),
    ("r2 header: plural row", M, 'in \\(layout.visibleRowCount) row\\(layout.visibleRowCount == 1 ? "" : "s")"', 'in \\(layout.visibleRowCount) rows"', "header singular"),
    ("r2 header: plural label", M, 'let labels = voices.count == 1 ? "1 voice label" : "\\(voices.count) voice labels"', 'let labels = "\\(voices.count) voice labels"', "header singular"),
    ("r2 hint: no date needed", M, '              o["recordedAt"]?.string?.isEmpty == false,\n', "", "malformed hint is absent"),
    ("r2 suggest: 0 of 0 shown", M, 'total > 0 ? "\\(checking), \\(done) of \\(total)" : checking', '"\\(checking), \\(done) of \\(total)"', "planning has no count"),
    ("r2 suggest: a dropped check says nothing", M, "if job.state == .idle, self.job?.state == .running || note == VoiceDisplayCopy.checkStoppedChanged { next.note = VoiceDisplayCopy.checkStoppedChanged }", "if false, job.state == .idle { next.note = VoiceDisplayCopy.checkStoppedChanged }", "a dropped check says why"),
    ("r2 suggest: the note does not last", M, "if job.state == .idle, self.job?.state == .running || note == VoiceDisplayCopy.checkStoppedChanged {", "if job.state == .idle, self.job?.state == .running {", "a dropped check says why"),
    ("r2 suggest: a stopped job says nothing", M, 'case "recording_active": return "A recording started, so the voice check stopped. Try again when it ends."\n', "", "a stopped job says what stopped it"),
    ("r2 fold: short suggestion unseen", M, "return layout.short.contains { !suggestions(heldBy: [$0.label], in: review).isEmpty }", "return false", "short suggestion opens the fold"),
    ("r2 fold: any suggestion opens it", M, "return layout.short.contains { !suggestions(heldBy: [$0.label], in: review).isEmpty }", "return !suggestions(for: review).isEmpty", "other suggestions leave it shut"),
    ("r2 outcome: skip note dropped", M, 'return sentence + skipped.filter { seen.insert($0).inserted }.map(MacVoiceCopy.appliedNoteForSkip).joined()', 'return sentence + skipped.filter { seen.insert($0).inserted }.map { _ in "" }.joined()', "group save warns of skipped samples"),
    ("r2 outcome: skip note repeated", M, 'skipped.filter { seen.insert($0).inserted }.map(MacVoiceCopy.appliedNoteForSkip)', 'skipped.map(MacVoiceCopy.appliedNoteForSkip)', "group save warns of skipped samples"),
    ("r2 batch: row reason ignored", M, 'parts.append("Stopped at \\(stopper.title): \\(VoiceDisplayCopy.batchReason(stopper.reason)).")', 'parts.append("Stopped at \\(stopper.title): \\(VoiceDisplayCopy.batchReason(reason)).")', "partial line"),
    ("r2 batch: not_attempted can stop it", M, 'notNamed.first(where: { $0.reason != nil && $0.reason != "not_attempted" })', "notNamed.first", "stop is the row that stopped it"),
    ("r2 batch: top reason lost", M, 'parts.append(VoiceDisplayCopy.batchReason(reason) + ".")', 'parts.append(VoiceDisplayCopy.batchReason(nil) + ".")', "contract: store unavailable earlier"),
    ("r2 batch: store_unavailable unmapped", M, 'case "store_unavailable": return "The voice samples could not be saved"\n', "", "every batch reason in plain words"),
    ("r2 batch: interrupted unmapped", M, 'case "interrupted": return "The batch was interrupted"\n', "", "every batch reason in plain words"),
    ("r2 batch: a reason shown as its code", M, 'case "audio_not_retained": return "This call\'s audio is no longer kept"\n', "", "stop is the row that stopped it"),
    ("r2 batch: a used undo stays", M, "var undoableBatch: VoiceBatchSummary? { newest(batches.filter { $0.undoAvailable && $0.state != \"running\" }) }", "var undoableBatch: VoiceBatchSummary? { newest(batches.filter { $0.state != \"running\" }) }", "undo survives reopening"),
    ("r2 batch: undo while running", M, "var undoableBatch: VoiceBatchSummary? { newest(batches.filter { $0.undoAvailable && $0.state != \"running\" }) }", "var undoableBatch: VoiceBatchSummary? { newest(batches.filter { $0.undoAvailable }) }", "running batch has no undo yet"),
    ("r2 batch: oldest undo wins", M, "rows.enumerated().max { a, b in a.element.at != b.element.at ? a.element.at < b.element.at : a.offset < b.offset }?.element", "rows.enumerated().max { a, b in a.element.at != b.element.at ? a.element.at > b.element.at : a.offset < b.offset }?.element", "undo survives reopening"),
    ("r2 batch: running unseen", M, 'var hasRunningBatch: Bool { batches.contains { $0.state == "running" } }', "var hasRunningBatch: Bool { false }", "running batch noticed"),
    ("r2 history: says no time", M, 'let when = VoiceDisplayCopy.when(at, timeZone: timeZone).map { " on " + $0 } ?? ""', 'let when = ""', "history says what and when"),
    ("r2 history: says no names", M, 'let who = names.isEmpty ? "" : ": " + names.prefix(3)', 'let who = names.count < 99 ? "" : ": " + names.prefix(3)', "history says what and when"),
    ("r2 history: names unbounded", M, '": " + names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " and \\(names.count - 3) more" : "")', '": " + names.joined(separator: ", ")', "history bounds its names"),
    ("r2 history: a spent batch still talks", M, 'default: return undoAvailable ? "Named \\(voices)\\(when)\\(who)." : nil', 'default: return "Named \\(voices)\\(when)\\(who)."', "a spent batch says nothing"),
    ("r2 history: interrupted reads as named", M, 'case "interrupted":\n            return "A batch was interrupted\\(when) after naming \\(voices)\\(who)." + (undoAvailable ? " Undo puts back what it named." : "")\n', "", "contract: list interrupted"),
    ("r2 history: unreadable silent", M, '        return newest(batches.filter { ["interrupted", "undo_partial", "unreadable"].contains($0.state) })?.line()\n', "        return nil\n", "contract: list unreadable"),
    ("r2 undo: older samples unsaid", M, 'if evictedNotRestored > 0 { parts.append("\\(samples(evictedNotRestored, "older ")) could not be restored.") }\n', "", "contract: samples not found"),
    ("r2 undo: restored samples unsaid", M, 'if evictedRestored > 0 { parts.append("Put back \\(samples(evictedRestored, "older "))." ) }\n', "", "contract: older samples back"),
    ("r2 undo: a refusal claims samples", M, 'func count(_ key: String) -> Int { state == .refused ? 0 : max(0, SpeakerGroupScope.exactInt(o[key]) ?? 0) }', 'func count(_ key: String) -> Int { max(0, SpeakerGroupScope.exactInt(o[key]) ?? 0) }', "refused undo did nothing"),
    ("r2 undo: samples_not_found reads as left", M, 'let held = left.filter { $0.reason != "samples_not_found" }', "let held = left", "samples missing without a revert"),
    ("r2 undo: reverted claimed without proof", M, 'parts.append(row.labels.allSatisfy(back.contains)\n', 'parts.append(row.labels.allSatisfy(back.contains) || true\n', "samples missing without a revert"),
    ("r2 undo: left row left out", M, 'if let first = held.first {', 'if let first = held.first, first.labels.isEmpty {', "partial undo line"),
    ("refusal: error unread", M, 'for key in ["message", "error"] {', 'for key in ["message"] {', "refusal reads error"),
]

HELPER = [
    ("helper: voiceDisplay filtered out", H, '            "review": body,\n', '            "review": body.filter { $0.key != "voiceDisplay" },\n', "voiceDisplay arrives verbatim"),
    ("helper: a 404 is not route absent", H, 'if response.status == 404 {\n            emit(ok: true, message: "Voice suggestions unavailable"', 'if response.status == 499 {\n            emit(ok: true, message: "Voice suggestions unavailable"', "404 is route absent"),
    ("helper: any body is a job", H, 'guard let body = response.body, body["state"] is String else {\n            emit(ok: true, message: "Voice suggestions failed"', 'guard let body = response.body else {\n            emit(ok: true, message: "Voice suggestions failed"', "failure is not a job"),
    ("helper: batch row keys unchecked", H, 'guard Set(item.keys) == ["labels", "name"], let labels', 'guard let labels', "bad batch never sent"),
    ("helper: batch needs no confirm", H, '                  let confirm = body["confirm"] as? NSNumber, CFGetTypeID(confirm) == CFBooleanGetTypeID(), confirm.boolValue,\n', "", "bad batch never sent"),
]

# Schemata: every controller mutant is compiled in once behind MUT("id") and chosen at run time by COS_VOICE_MUTANT, because one
# rebuild of the app kit takes about 5 minutes. Each still has to replace its target exactly once, and the baseline run has them all
# compiled in and none chosen. The check named has to be the one that fails.
CONTROLLER = [
    ("c1", "controller: a refusal does not stop", "stop = Self.groupStepRefusal(state: state, response: response); break steps", 'stop = Self.groupStepRefusal(state: state, response: response); if MUT("c1") { continue steps }; break steps', "refusal stops the run"),
    ("c2", "controller: the next write keeps the old revision", "                    review = next\n                    openReview = next\n", '                    if !MUT("c2") { review = next }\n                    openReview = next\n', "every label named"),
    ("c3", "controller: Use this name takes the whole row", "let members = suggestion.labels.compactMap { label in review.voices.first { $0.label == label } }\n        guard members.count == suggestion.labels.count, let first = members.first else { return }",
     'let members = (MUT("c3") ? rowLabels : suggestion.labels).compactMap { label in review.voices.first { $0.label == label } }\n        guard MUT("c3") || members.count == suggestion.labels.count, let first = members.first else { return }', "use this name names exactly its labels"),
    ("c4", "controller: confirm needs no open list", "guard !mergeInFlight, voiceBatch.previewOpen, !voiceBatch.hasRunningBatch, let review = openReview,", 'guard !mergeInFlight, MUT("c4") || voiceBatch.previewOpen, !voiceBatch.hasRunningBatch, let review = openReview,', "nothing writes until confirm"),
    ("c5", "controller: no refresh after a batch", "            if routeGone { voiceBatch.routeAbsent = true; voiceBatch.batches = [] }\n            await refreshAfterVoiceBatch(session: session, generation: generation)\n", '            if routeGone { voiceBatch.routeAbsent = true; voiceBatch.batches = [] }\n            if !MUT("c5") { await refreshAfterVoiceBatch(session: session, generation: generation) }\n', "refresh after confirm"),
    ("c6", "controller: Rename voice leaves its row shut", "if let wanted = pendingNameVoice { revealVoice(wanted, in: review) }", 'if !MUT("c6"), let wanted = pendingNameVoice { revealVoice(wanted, in: review) }', "rename voice opens its merged row"),
    ("c7", "controller: Rename voice leaves the fold shut", "        case .short: voiceDisplayShortExpanded = true\n", '        case .short: if !MUT("c7") { voiceDisplayShortExpanded = true }\n', "rename voice opens the fold"),
    ("c8", "controller: a skipped sample unsaid", "!skipped.isEmpty { skips.append(skipped) }", '!skipped.isEmpty, !MUT("c8") { skips.append(skipped) }', "group save warns of skipped samples"),
    ("c9", "controller: a running batch not followed", "if voiceBatch.hasRunningBatch { followRunningVoiceBatch(session: review.sessionId, generation: generation) }", 'if voiceBatch.hasRunningBatch, !MUT("c9") { followRunningVoiceBatch(session: review.sessionId, generation: generation) }', "fixture timeout"),
    ("c10", "controller: the fold stays shut on a short suggestion", "next.holdsShortSuggestion(in: review) { voiceDisplayShortExpanded = true }", 'next.holdsShortSuggestion(in: review), !MUT("c10") { voiceDisplayShortExpanded = true }', "short suggestion opens the fold"),
    ("c11", "controller: a lost reply after moving is silent", "                // A lost reply may follow a batch that ran. The refresh below shows the truth, and nothing offers to repeat it blind.\n                guard reviewSelectionGeneration == generation, lastReviewSession == session else { notice = VoiceDisplayCopy.batchLostReply; return }", '                guard reviewSelectionGeneration == generation, lastReviewSession == session else { if !MUT("c11") { notice = VoiceDisplayCopy.batchLostReply }; return }', "fixture timeout"),
]

work = pathlib.Path(tempfile.mkdtemp(prefix="cos-voice-mutate.", dir="/tmp"))
repo = work / "repo"
kits = work / "kits"
kits.mkdir(mode=0o700)
for name in ("Sources", "HelperSources", "Tests", "Resources"):
    shutil.copytree(root / name, repo / name, symlinks=True)
ENV = {**os.environ, "COS_TEST_KIT_DIR": str(kits), "COS_COMPILE_PROFILE": "bounded", "COS_COMPILE_RECEIPT_DIR": str(work / "receipts"),
       "COS_LIVE_CUES_V2": "0", "COS_SPEAKER_SHADOW": "0", "COS_MAC_SPEAKER_LIVE": "0", "COS_MAC_ACOUSTIC_VOICES": "0"}
SWIFTC = ["/usr/bin/python3", str(repo / "Tests/kit-compile.py"), str(repo / "Tests/compile-guard.sh"), "swiftc", "-target", "arm64-apple-macosx14.0", "-swift-version", "6", "-strict-concurrency=complete"]
FLAGS = ["-parse-as-library"]
HELPER_SOURCES = [str(repo / p) for p in ("HelperSources/main.swift", "HelperSources/ProviderStatusCore.swift", "HelperSources/PairingCore.swift", "HelperSources/SessionUsageCollector.swift", "Sources/SessionUsageCore.swift", "Sources/WorkSessionLinks.swift")]


def run(command, timeout, home=None):
    env = dict(ENV)
    if home:
        env.update(HOME=home, CFFIXED_USER_HOME=home, COS_CONTROL_TEST_HOME=home)
    return mutate_bounded.run(command, timeout, env=env, cwd=str(repo))


def lane(name):
    """(ok, output). ok False with no named check means it did not compile."""
    scratch = pathlib.Path(tempfile.mkdtemp(prefix="cos-voice-display-checks.", dir="/tmp"))
    home = scratch / "home"
    home.mkdir(mode=0o700)
    try:
        if name == "model":
            built = run(SWIFTC + FLAGS + [str(repo / "Sources/Models.swift"), str(repo / "Tests/VoiceDisplayChecks.swift"), "-framework", "AppKit", "-o", str(scratch / "checks")], 600)
            if built.returncode:
                return "invalid", built.stdout + built.stderr
            result = run([str(scratch / "checks"), str(repo / "Tests/fixtures/voice-display-server-6.96.3.json")], 240, home=str(home))
        elif name == "helper":
            built = run(SWIFTC + HELPER_SOURCES + ["-framework", "Security", "-framework", "AppKit", "-o", str(scratch / "helper")], 900)
            if built.returncode:
                return "invalid", built.stdout + built.stderr
            result = run(["/usr/bin/python3", str(repo / "Tests/voice-display-helper-checks.py"), str(scratch / "helper")], 300)
        return ("pass" if result.returncode == 0 else "fail"), result.stdout + result.stderr
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


GROUPS = {"model": MODEL, "helper": HELPER}
failed, rows = [], []
for name in [lane_name for lane_name in lanes if lane_name != "controller"]:
    state, output = lane(name)
    if state != "pass":
        sys.exit(f"baseline {name} is not green ({state}); no mutant can mean anything:\n{output[-3000:]}")
    print(f"baseline {name}: green: {output.strip().splitlines()[-1]}", flush=True)
    for label, path, old, new, behaviour in GROUPS[name]:
        if only and not any(label.startswith(prefix) for prefix in only.split("|")):
            continue
        target = repo / path
        source = target.read_text(encoding="utf-8")
        if source.count(old) != 1:
            failed.append(label)
            print(f"INVALID  {label}: the target appears {source.count(old)} times, not once", flush=True)
            continue
        target.write_text(source.replace(old, new), encoding="utf-8")
        try:
            state, output = lane(name)
        finally:
            target.write_text(source, encoding="utf-8")
        first = next((line.split("[", 1)[1].split("]", 1)[0] for line in output.splitlines() if line.startswith("check failed [")), None)
        if state == "pass":
            verdict = "SURVIVED"
        elif state == "invalid":
            verdict = "INVALID"
        elif behaviour == "CRASH":
            verdict = "KILLED" if first is None else "MISATTRIBUTED"
        elif first == behaviour:
            verdict = "KILLED"
        else:
            verdict = "MISATTRIBUTED"
        if verdict != "KILLED":
            failed.append(label)
        rows.append((verdict, label, behaviour, first))
        print(f"{verdict:13} {label}  <- {first or behaviour}" + (f"\n{output[-1500:]}" if verdict == "INVALID" else ""), flush=True)
if "controller" in lanes:
    target = repo / C
    source = target.read_text(encoding="utf-8")
    for key, label, old, new, behaviour in CONTROLLER:
        if source.count(old) != 1:
            sys.exit(f"INVALID  {label}: the target appears {source.count(old)} times, not once")
        source = source.replace(old, new)
    target.write_text(source + '\nfunc MUT(_ id: String) -> Bool { ProcessInfo.processInfo.environment["COS_VOICE_MUTANT"] == id }\n', encoding="utf-8")
    sources = sorted(str(p) for p in (repo / "Sources").glob("*.swift") if p.name != "COSControlApp.swift")
    built = run(SWIFTC + FLAGS + sources + [str(repo / "Tests/VoiceDisplayControllerChecks.swift"), "-framework", "SwiftUI", "-framework", "AppKit", "-framework", "ServiceManagement", "-framework", "WebKit", "-o", str(work / "controller-checks")], 1500)
    if built.returncode:
        sys.exit("controller schemata did not compile:\n" + (built.stdout + built.stderr)[-3000:])
    def controller(key):
        scratch = pathlib.Path(tempfile.mkdtemp(prefix="cos-voice-display-checks.", dir="/tmp"))
        (scratch / "home").mkdir(mode=0o700)
        ENV.pop("COS_VOICE_MUTANT", None)
        if key:
            ENV["COS_VOICE_MUTANT"] = key
        try:
            return run([str(work / "controller-checks"), str(scratch)], 300, home=str(scratch / "home"))
        finally:
            ENV.pop("COS_VOICE_MUTANT", None)
            shutil.rmtree(scratch, ignore_errors=True)
    baseline = controller(None)
    if baseline.returncode:
        sys.exit("baseline controller is not green, with every schema compiled in:\n" + (baseline.stdout + baseline.stderr)[-3000:])
    print(f"baseline controller: green: {baseline.stdout.strip().splitlines()[-1]}", flush=True)
    for key, label, old, new, behaviour in CONTROLLER:
        if only and not any(label.startswith(prefix) for prefix in only.split("|")):
            continue
        result = controller(key)
        output = result.stdout + result.stderr
        first = next((line.split("[", 1)[1].split("]", 1)[0] for line in output.splitlines() if line.startswith("check failed [")), None)
        verdict = "SURVIVED" if result.returncode == 0 else ("KILLED" if first == behaviour else "MISATTRIBUTED")
        if verdict != "KILLED":
            failed.append(label)
        rows.append((verdict, label, behaviour, first))
        print(f"{verdict:13} {label}  <- {first or behaviour}", flush=True)
shutil.rmtree(work, ignore_errors=True)
print(f"{sum(1 for r in rows if r[0] == 'KILLED')} of {len(rows)} killed and attributed")
if failed:
    sys.exit("not killed: " + "; ".join(failed))
