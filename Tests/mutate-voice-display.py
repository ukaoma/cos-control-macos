#!/usr/bin/env python3
"""0.5.357 (server 6.96.3): the mutation gate for merged Speakers rows, Suggest names and the one-click batch.

SERIAL by design: one compile at a time, each through Tests/compile-guard.sh. Works on a scratch copy, so the checkout is never
mutated. A GREEN baseline of every lane is required before the first mutant, and each mutant must replace its target exactly once.

A KILL counts only when the mutant compiles, runs, and the check that fails first is the one the mutant names (its behaviour in
"check failed [<behaviour>]"). Everything else fails this gate on its own line: SURVIVED, MISATTRIBUTED, INVALID (did not compile
or timed out). A mutant named CRASH must trap: removing that guard makes Dictionary(uniqueKeysWithValues:) trap, which is the failure.

Model mutants take about 25 seconds each. A helper mutant rebuilds the helper. A controller mutant rebuilds the app kit, about 5 minutes.

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
    ("batch: undo without the server's word", M, ' && !named.isEmpty && o["undoAvailable"]?.bool == true', " && !named.isEmpty", "undo needs the server's word"),
    ("batch: undo with nothing named", M, ' && !named.isEmpty && o["undoAvailable"]?.bool == true', ' && o["undoAvailable"]?.bool == true', "nothing named no undo"),
    ("batch: row reason ignored", M, 'Stopped at \\(first.title): \\(VoiceDisplayCopy.batchReason(first.reason ?? reason)).', 'Stopped at \\(first.title): \\(VoiceDisplayCopy.batchReason(reason)).', "partial line"),
    ("batch: stop at the first row listed", M, 'guard let first = notNamed.first(where: { $0.reason != "not_attempted" }) ?? notNamed.first else', 'guard let first = notNamed.first else', "stop is the row that stopped it"),
    ("batch: a refusal lists rows", M, '        if state == .refused { return "Nothing was named. " + VoiceDisplayCopy.batchReason(reason ?? notNamed.first?.reason) + "." }\n', "", "refusal line"),
    ("batch: a reason shown as its code", M, 'case "audio_not_retained": return "This call\'s audio is no longer kept"\n', "", "stop is the row that stopped it"),
    ("batch: applied with no rows succeeds", M, "if state == .applied, notNamed.isEmpty, !named.isEmpty {", "if state == .applied, notNamed.isEmpty {", "applied with no rows is not a success"),
    ("batch: a used undo stays", M, "batches.enumerated().filter(\\.element.undoAvailable).max { a, b in", "batches.enumerated().max { a, b in", "undo survives reopening"),
    ("batch: oldest undo wins", M, "a.element.at != b.element.at ? a.element.at < b.element.at : a.offset < b.offset", "a.element.at != b.element.at ? a.element.at > b.element.at : a.offset < b.offset", "undo survives reopening"),
    ("batch: 404 does not hide", M, "func showsControls(for review: SpeakerReview) -> Bool { review.canSuggestNames && probed && !routeAbsent }", "func showsControls(for review: SpeakerReview) -> Bool { review.canSuggestNames && probed }", "404 hides the batch"),
    ("batch: a failed list shows controls", M, "        } else if let rows = details[\"batches\"]?.array {\n            next.probed = true\n", "        } else if let rows = details[\"batches\"]?.array {\n", "empty list shows controls"),
    ("undo: refusal claims samples", M, 'samplesRemoved = state == .refused ? 0 : max(0, SpeakerGroupScope.exactInt(o["samplesRemoved"]) ?? 0)', 'samplesRemoved = max(0, SpeakerGroupScope.exactInt(o["samplesRemoved"]) ?? 0)', "refused undo did nothing"),
    ("undo: left row left out", M, 'guard let first = left.first else { return lead + " " + samples }', 'guard let first = left.first, first.labels.isEmpty else { return lead + " " + samples }', "partial undo line"),
    ("outcome: one label too many named", M, "var named: [String] { Array(labels.prefix(namedCount)) }", "var named: [String] { Array(labels.prefix(namedCount + 1)) }", "partway named"),
    ("outcome: one label dropped", M, "var notNamed: [String] { Array(labels.dropFirst(namedCount)) }", "var notNamed: [String] { Array(labels.dropFirst(namedCount + 1)) }", "partway not named"),
    ("plan: a flagged label forced", M, "MacAssignRequest.flags(for: correction, renameOnly: correction.needsForceToAddSamples, addAnyway: false, armed: false) ?? []", "MacAssignRequest.flags(for: correction, renameOnly: false, addAnyway: true, armed: true) ?? []", "flagged stays text only"),
    ("refusal: error unread", M, 'for key in ["message", "error"] {', 'for key in ["message"] {', "refusal reads error"),
]

HELPER = [
    ("helper: voiceDisplay filtered out", H, '            "review": body,\n', '            "review": body.filter { $0.key != "voiceDisplay" },\n', "voiceDisplay arrives verbatim"),
    ("helper: a 404 is not route absent", H, 'if response.status == 404 {\n            emit(ok: true, message: "Voice suggestions unavailable"', 'if response.status == 499 {\n            emit(ok: true, message: "Voice suggestions unavailable"', "404 is route absent"),
    ("helper: any body is a job", H, 'guard let body = response.body, body["state"] is String else {\n            emit(ok: true, message: "Voice suggestions failed"', 'guard let body = response.body else {\n            emit(ok: true, message: "Voice suggestions failed"', "failure is not a job"),
    ("helper: batch row keys unchecked", H, 'guard Set(item.keys) == ["labels", "name"], let labels', 'guard let labels', "bad batch never sent"),
    ("helper: batch needs no confirm", H, '                  let confirm = body["confirm"] as? NSNumber, CFGetTypeID(confirm) == CFBooleanGetTypeID(), confirm.boolValue,\n', "", "bad batch never sent"),
]

CONTROLLER = [
    ("controller: a refusal does not stop", C, "stop = Self.groupStepRefusal(state: state, response: response); break steps", "stop = Self.groupStepRefusal(state: state, response: response); continue steps", "refusal stops the run"),
    ("controller: the next write keeps the old revision", C, "                    review = next\n                    openReview = next\n", "                    openReview = next\n", "every label named"),
    ("controller: Use this name takes the whole row", C, "let members = suggestion.labels.compactMap { label in review.voices.first { $0.label == label } }\n        guard members.count == suggestion.labels.count, let first = members.first else { return }",
     "let members = rowLabels.compactMap { label in review.voices.first { $0.label == label } }\n        guard let first = members.first else { return }", "use this name names exactly its labels"),
    ("controller: confirm needs no open list", C, "guard !mergeInFlight, voiceBatch.previewOpen, let review = openReview,", "guard !mergeInFlight, let review = openReview,", "nothing writes until confirm"),
    ("controller: no refresh after a batch", C, "            if routeGone { voiceBatch.routeAbsent = true; voiceBatch.batches = [] }\n            await refreshAfterVoiceBatch(session: session, generation: generation)\n", "            if routeGone { voiceBatch.routeAbsent = true; voiceBatch.batches = [] }\n", "refresh after confirm"),
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
            result = run([str(scratch / "checks")], 240, home=str(home))
        elif name == "helper":
            built = run(SWIFTC + HELPER_SOURCES + ["-framework", "Security", "-framework", "AppKit", "-o", str(scratch / "helper")], 900)
            if built.returncode:
                return "invalid", built.stdout + built.stderr
            result = run(["/usr/bin/python3", str(repo / "Tests/voice-display-helper-checks.py"), str(scratch / "helper")], 300)
        else:
            sources = sorted(str(p) for p in (repo / "Sources").glob("*.swift") if p.name != "COSControlApp.swift")
            built = run(SWIFTC + FLAGS + sources + [str(repo / "Tests/VoiceDisplayControllerChecks.swift"), "-framework", "SwiftUI", "-framework", "AppKit", "-framework", "ServiceManagement", "-framework", "WebKit", "-o", str(scratch / "checks")], 1500)
            if built.returncode:
                return "invalid", built.stdout + built.stderr
            result = run([str(scratch / "checks"), str(scratch)], 300, home=str(home))
        return ("pass" if result.returncode == 0 else "fail"), result.stdout + result.stderr
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


GROUPS = {"model": MODEL, "helper": HELPER, "controller": CONTROLLER}
failed, rows = [], []
for name in lanes:
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
shutil.rmtree(work, ignore_errors=True)
print(f"{sum(1 for r in rows if r[0] == 'KILLED')} of {len(rows)} killed and attributed")
if failed:
    sys.exit("not killed: " + "; ".join(failed))
