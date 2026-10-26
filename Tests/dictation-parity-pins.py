#!/usr/bin/env python3
"""0.5.345 Wave A (plan r3, operations/personal/wk43_2026/PLAN_dictation_parity_2026-10-25.md): where the pure rules
(Tests/DictationParityChecks.swift runs them) are wired, the settings, the fixture's pin, the timing fields, the release
words and the logs. Each failure names its behaviour as "pin failed [<behaviour>]". Code only: comments never satisfy a
pin. Call sites are pinned, not definitions.

Then a self-test: each in-memory mutant below must land exactly once in its file and must make the pin it names fail,
so no pin here is decoration.

    python3 Tests/dictation-parity-pins.py <root>
"""
import hashlib, json, pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
FIXTURE_SHA256 = "a531d0a99b4661dedcde5d81dbaa304eae73f916eb30e2efd7589e1e0a71de55"
FILES = {"d": "Sources/MacDictation.swift", "core": "Sources/MacDictationCore.swift", "rec": "Sources/MacRecording.swift",
         "helper": "HelperSources/main.swift", "pcore": "HelperSources/ProviderStatusCore.swift", "pet": "Sources/SessionPet.swift",
         "model": "Sources/ControllerModel.swift", "whatsnew": "Resources/WhatsNew.json", "changelog": "CHANGELOG.md",
         "plist": "Resources/Info.plist", "run": "Tests/run.sh", "checks": "Tests/DictationParityChecks.swift"}


class PinFailed(Exception):
    pass


def code(text):
    return "\n".join(l for l in text.split("\n") if not l.strip().startswith("//"))


def pin(ok, behaviour, why):
    if not ok:
        raise PinFailed(f"pin failed [{behaviour}]: {why}")


def body(src, opener):
    pin(src.count(opener) == 1, "source shape", f"{opener!r} must appear exactly once")
    start = src.index(opener)
    depth, i, seen = 0, start, False
    while i < len(src):
        if src[i] == "{":
            depth += 1; seen = True
        elif src[i] == "}":
            depth -= 1
            if seen and depth == 0:
                return src[start:i + 1]
        i += 1
    return src[start:]


def check(src, fixture):
    d, core, rec, helper = code(src["d"]), code(src["core"]), code(src["rec"]), code(src["helper"])

    # 1. The canonical fillers fixture: a byte-identical copy of the server's, pinned by sha256 here and in the checks.
    pin(hashlib.sha256(fixture).hexdigest() == FIXTURE_SHA256 and f'"{FIXTURE_SHA256}"' in src["checks"], "fixture pinned",
        "Tests/fixtures/dictation-fillers.json is the server's file byte for byte (sha256 pinned in both repos)")

    # 2. One strip, right after transcription; polish gets the raw words; never in Mac recording; rawHeard on the record.
    transcribe = body(d, "    private func transcribe(_ wav: Data, attempt: UUID) {")
    pin(d.count("DictationFillers.clean(") == 1 and "let spoken = DictationFillers.clean(heard, enabled: removeFillers)" in transcribe
        and "DictationFillers" not in rec and "lastRawHeard = spoken.removed ? heard : nil" in transcribe
        and "rawHeard: lastPolish == nil ? lastRawHeard : nil)" in d, "fillers once",
        "one strip for every typed or copied path, never in Mac recording, and what was heard is kept when it changed")

    # 2b. QA B1: what is recorded is exactly what was typed (respelled and capitalized), on both delivery paths, and every
    # DictationDelivered carries it; the landed target holds the same text, so the watch and the record agree.
    deliver = body(d, "    static func deliver(_ raw: String, restoreClipboard: Bool, fieldContext: Bool = false,\n                        casing request: DictationCasing.Request = DictationCasing.Request(enabled: false)) async -> DictationDelivered {")
    pin(d.count("DictationDelivered(outcome:") == 4 and d.count("typed: text)") >= 4
        and "finish(delivered.typed, outcome: delivered.outcome, target: delivered.target, context: delivered.context, own: delivered.own)" in transcribe
        and "        let typed = delivered.typed\n" in d and "delivered.context?.text ?? text" not in d
        and deliver.count("terminal: terminal, app: name, text: text,") == 2 and "if request.enabled { text = capped; count = text.utf16.count }" in deliver,
        "record what was typed", "the record and the paste-first baseline are delivered.typed, the same text the landed target and the field hold")

    # 3. The six settings: shown in Settings, read with their tested default, stored under their key.
    for name, title, key, stored in (("removeFillers", "DictationFillers.settingTitle", "DictationFillers.defaultsKey", "DictationFillers.stored("),
                                     ("capitalizeStart", "DictationCasing.settingTitle", "DictationCasing.defaultsKey", "DictationCasing.stored("),
                                     ("swapWaitForKeys", "DictationSwapWait.settingTitle", "DictationSwapWait.defaultsKey", "DictationSwapWait.stored("),
                                     ("micFallback", "DictationMicFallback.settingTitle", "DictationMicFallback.defaultsKey", "DictationMicFallback.stored(")):
        pin(f"Toggle({title}, isOn: $store.{name})" in d and f"@Published var {name}: Bool = {stored}UserDefaults.standard.object(forKey: {key}))" in d
            and f"UserDefaults.standard.set({name}, forKey: {key})" in d, "settings", f"{name}: a Settings switch, its tested default, stored")
    pin("Button(DictationAudioCopy.playAgain) { store.resetSoundBreaker() }" in d and "Button(DictationAudioCopy.muteAgain) { store.resetMuteBreaker() }" in d
        and "func resetSoundBreaker() { soundPlayer.resetBreaker(); soundsPaused = false }" in d
        and "func resetMuteBreaker() { quiet.resetBreaker(); mutePaused = false; quietNote = nil }" in d, "breaker resets",
        "Play sounds again and Mute again reset their breakers")

    # 4. The timing fields of the contract (codes and numbers only) and where each is written.
    for field in ("preUploadMs: Int?", "postCloseStallMs: Int?", "slowListenerCalls: Int?", "micFallback: String?", "muteOwnObject: String?",
                  "swapHeldKeys: String?", "swapHeldMs: Int?", "swapWaitMs: Int?", "swapFrontmostChanged: Bool?", "swapFrontmostAtPostMismatch: Int?",
                  "swapClipboardNewerKept: Int?", "swapIntoClearedField: Int?", "wouldCapitalize: Bool?", "fillersRemoved: Bool?"):
        pin(f"var {field} = nil" in body(core, "struct DictationTiming: Codable, Equatable, Sendable {"), "timing fields", f"DictationTiming has {field}")
    pin('timing?.preUploadMs = response.details["preUploadMs"]?.int' in transcribe and "timing?.fillersRemoved = spoken.removed" in transcribe
        and d.count("timing?.wouldCapitalize = delivered.wouldCapitalize") == 2 and d.count("markFirstText()") == 3
        and "if let stall = closeBeat.finish() { timing?.postCloseStallMs = stall }" in d, "timing written",
        "the helper's preUploadMs, the strip, the casing shadow on both deliveries and the post-close heartbeat reach the line")
    pin('details["preUploadMs"] = preUploadMs' in helper and "MeetingListenerStats.note(ms:" in rec, "timing written",
        "the helper stamps preUploadMs; meeting detection counts its slow main-thread calls")

    # 5. Undo polish: the watch ends first, Fix a word's replace (non-automatic) on the whole span, the pending polish kept.
    undo = body(d, "    func undoPolish(_ id: UUID) {")
    order = [undo.find(s) for s in ['editWatcher.stop("undo polish")', "DictationInsertion.replace(target, corrected: restored, restoreClipboard: restoreClipboard, wholeOnly: true)",
                                    "pendingPolish[id] = DictationPendingPolish(", "recent = DictationHistory.unpolishing(id, in: recent); saveRecent()"]]
    pin(-1 not in order and order == sorted(order) and "automatic" not in undo and "copy(" not in undo, "undo polish",
        "the watch stops, the whole span is replaced without automatic, Claude's version waits for Apply polished, nothing is copied")
    replace_fn = body(d, "    static func replace(_ target: DictationInsertTarget, corrected: String, restoreClipboard: Bool, wholeOnly: Bool = false,\n                        waitForKeys: Bool = false, automatic: Bool = false) async -> Replaced {")
    pin("if wholeOnly, let reason = DictationUndoPolish.placed(plan, span: target.span) {" in replace_fn, "undo polish", "a moved span refuses through the tested rule")
    pin(body(d, "    func replaceCorrected() {").count("swappedIDs.remove(offer.recordID)") == 1, "undo polish",
        "a Fix a word replace clears Undo polish, so it never puts back text from before the fix")
    pin("swappedIDs.insert(id)" in d and "polishUndoID = id; polishUndoPill = flash" in d and "DictationHistory.polishing(id, to: polished, heard: heard," in d,
        "undo polish", "a landed swap offers Undo polish on the pill and the card")

    # 6. Polish already fixed this (A-W11) and the next-time lines (A-W12).
    ended = body(d, "    private func editWatchEnded(_ end: DictationWatchEnd) async {")
    pin("let matched = pending.map { DictationPolishMatch.subset(typed: end.typed, final: final, polished: $0.text) } ?? false" in ended
        and "matchedPolish: matched) else {" in ended and "if !matched {" in ended
        and "DictationEditCaptureLine.append(DictationEditCaptureLine(" in ended and "editMatchedPolish: matched," in ended, "polish had it",
        "a matched edit is recorded, never style evidence, and the edit-capture log says so (codes only)")
    learned = body(d, "    private func editLearned(_ candidate: DictationEditLearning.Candidate, app: String, record id: UUID? = nil) {")
    pin('dictationLog.notice("learn skipped polishHadIt"); return' in learned and learned.index("polishHadIt") < learned.index("TranscriptionDictionaryStore.shared.learn("),
        "polish had it", "no dictionary attempt for a pair polish had already made")
    pin("guard let edit = record.edit, edit.learned.isEmpty, !edit.matchedPolish else { return nil }" in d
        and "guard !words.allSatisfy(DictationFillers.isBuiltIn) else { return nil }" in core, "no filler chip",
        "no Always drop chip for a matched edit or a built-in filler")
    pin("if !counted.isEmpty { recent = DictationHistory.editing(id, edit: edit.with(styleKeys: counted), in: recent); saveRecent() }" in ended
        and "styles: (record.edit?.styleKeys ?? []).compactMap { DictationStyleStore.shared.progress($0) }," in d, "next time",
        "the rules an edit counted toward go on the edit and the card reads their progress")

    # 7. Audio: the gate before the sound queue, the breakers on error status only, the fallback scope.
    player = body(d, "final class DictationSoundPlayer: @unchecked Sendable {")
    pin("let verdict = DictationSoundGate.enqueue(outstanding: starting, breakerOpen: breaker.open(now: now))" in player
        and "let verdict = DictationSoundGate.dequeue(askedAt: askedAt, now: ProcessInfo.processInfo.systemUptime, breakerOpen: open)" in player
        and "breaker.record(status: status == 0 ? -1 : status, now: ProcessInfo.processInfo.systemUptime)" in player, "sound gate",
        "a sound is dropped while one is starting, when late, or while paused; an engine error pauses sounds")
    quiet = body(d, "final class DictationQuietController: @unchecked Sendable {")
    pin("tapPermitted: Self.tapPermitted && !paused," in quiet and "breaker.record(status: failure.status, now: ProcessInfo.processInfo.systemUptime)" in quiet
        and 'lastTimes.ownObject = own.isEmpty ? "absent" : "present"' in quiet and "fallbackNote = Self.note(step: failure.step, status: failure.status)" in quiet,
        "mute breaker", "an error status pauses muting (the volume is lowered), the own-object check is logged, and the note follows the status")

    # 8. A-W0d: one round trip less, and the stopped server keeps its Retry.
    dictate = body(helper, "    private func dictate(_ audio: Data) throws -> DictationBridge.Answer {")
    pin("speakerReviewToken" not in dictate and "/api/health" not in dictate and "try readToken()" in dictate
        and 'guard let status else { return Answer(ok: false, message: "Server stopped", details: ["action": "retry", "retryable": true]) }' in code(src["pcore"]),
        "one round trip less", "dictate() reads the token itself; no answer is Server stopped with Retry")

    # 9. The options the picker reads, and the reload on a server change.
    pin('meaningGuard: response.details["meaningGuard"]?.bool, stylePairs: pairs, available: true)' in d
        and 'haikuPrompt: response.details["effectiveByModel"]?.object?["haiku"]?.string,' in d
        and 'details["meaningGuard"] = flag.boolValue' in code(src["pcore"]) and 'details["stylePairs"] = kept' in code(src["pcore"])
        and "DictationStyleStore.shared.serverCameBack(changed: changed)" in code(src["model"]), "picker options",
        "Haiku's prompt, the guard and the style pairs reach the picker, and a changed server always reloads them")

    # 10. Logs: the new lines carry codes and counts only, never text, a device name, an app name or a domain.
    added = [l for l in d.split("\n") if "dictationLog." in l and any(k in l for k in ("undo polish", "polishHadIt", "microphone fallback", "sound dropped",
                                                                                         "muteOwnObject", "start failed: engine_start", "sounds paused", "muting paused"))]
    pin(len(added) >= 9 and not any(bad in l for l in added for bad in ("restored", "candidate.", ".name", "heard", "text)", "used.uid", "target.app")),
        "no text logged", f"{len(added)} new log lines, codes and counts only")

    # 11. Preserve Wave A's historical release notes on later versions, while the current
    # plist/notes/changelog agree and the current summary stays within the window cap.
    notes = json.loads(src["whatsnew"])
    build = re.search(r"<key>CFBundleVersion</key>\s*<string>(\d+)</string>", src["plist"])
    short = re.search(r"<key>CFBundleShortVersionString</key>\s*<string>([0-9.]+)</string>", src["plist"])
    pin(short is not None and tuple(map(int, short.group(1).split("."))) >= (0,5,345)
        and build is not None and int(build.group(1)) >= 399 and notes.get("version") == short.group(1)
        and src["changelog"].startswith(f"## {short.group(1)} (build {build.group(1)})"),
        "version", "current plist, notes and changelog agree at 0.5.345 (399) or later")
    summary = notes["whatsNew"]["summary"]
    pin(len(summary) <= 1200 and summary.count("Plus everything in") == 1
        and ("Plus everything in 0.5.344: " in summary if notes.get("version") == "0.5.345" else True),
        "summary cap", f"the summary fits 1,200 characters and chains one prior release ({len(summary)})")
    mine = [section for section in notes["whatsNew"]["sections"] if section["title"] == "0.5.345"]
    pin(len(mine) == 1, "version", "keep exactly one 0.5.345 section")
    first = mine[0]
    entries = src["changelog"].split("\n## ")
    entry = next(("## " + e if i else e for i,e in enumerate(entries)
                  if ("## " + e if i else e).startswith("## 0.5.345 (build 399)")), "")
    for text in [summary, entry] + first["items"]:
        pin("—" not in text and "→" not in text and " -> " not in text, "copy", f"no em dash or arrow: {text[:60]!r}")
    pin(entry != "" and 1 <= len(first["items"]) <= 12 and "6.92.0" in entry,
        "version", "the preserved 0.5.345 entry pairs with 6.92.0")
    e344 = src["changelog"].split("\n## 0.5.344 (build 398)", 1)[-1].split("\n## 0.5.343", 1)[0]
    pin("Pairs with COS server 6.91.1" in e344, "pairing", "the 0.5.344 entry pairs with 6.91.1")
    block = src["core"][src["core"].index("// MARK: - 0.5.345 Wave A (plan r3): filler sounds are never typed (A-W10)"):src["core"].index("// MARK: - Dictation for everyone (0.5.317, server 6.74.0)")]
    pin("—" not in block and "→" not in block, "copy", "no em dash or arrow anywhere in the Wave A core (patterns use \\u2014)")

    # 12. The lanes run in the suite.
    pin('zsh "$ROOT/Tests/run-dictation-parity.sh"' in src["run"] and 'zsh "$ROOT/Tests/run-history-backcompat.sh"' in src["run"], "lanes wired",
        "Tests/run.sh runs the parity lane and the history back-compat lane")


MUTANTS = [
    ("strip twice", "d", "let said = polished?.outcome.text(heard: spoken.text) ?? spoken.text", "let said = DictationFillers.clean(polished?.outcome.text(heard: spoken.text) ?? spoken.text, enabled: removeFillers).text", "fillers once"),
    ("rawHeard never kept", "d", "lastRawHeard = spoken.removed ? heard : nil", "lastRawHeard = nil", "fillers once"),
    ("capital toggle hidden", "d", "Toggle(DictationCasing.settingTitle, isOn: $store.capitalizeStart)", "Text(DictationCasing.settingTitle)", "settings"),
    ("Mute again does nothing", "d", "Button(DictationAudioCopy.muteAgain) { store.resetMuteBreaker() }", "Button(DictationAudioCopy.muteAgain) { }", "breaker resets"),
    ("preUploadMs dropped", "d", 'timing?.preUploadMs = response.details["preUploadMs"]?.int', "_ = 0", "timing written"),
    ("undo polish leaves the watch on", "d", '        editWatcher.stop("undo polish")\n', "", "undo polish"),
    ("undo polish copies on refusal", "d", "                polishNote = (id, DictationUndoPolish.refusedNote(reason, app: target.app))", "                copy(restored); polishNote = (id, DictationUndoPolish.refusedNote(reason, app: target.app))", "undo polish"),
    ("matched edit counts as style", "d", "        if !matched {\n", "        if true {\n", "polish had it"),
    ("polish pair learned", "d", 'dictationLog.notice("learn skipped polishHadIt"); return', 'dictationLog.notice("learn skipped polishHadIt")', "polish had it"),
    ("filler chip back", "core", "        guard !words.allSatisfy(DictationFillers.isBuiltIn) else { return nil }\n", "", "no filler chip"),
    ("mute breaker never trips", "d", "            breaker.record(status: failure.status, now: ProcessInfo.processInfo.systemUptime)\n", "", "mute breaker"),
    ("health probe back", "helper", "        do { token = try readToken() } catch { throw HelperError.message(\"Unauthorized\") }\n        let capabilities = request(\"/api/transcribe/capabilities\"",
     "        token = try speakerReviewToken()\n        let capabilities = request(\"/api/transcribe/capabilities\"", "one round trip less"),
    ("text in a log", "d", 'dictationLog.notice("undo polish result=replaced")', 'dictationLog.notice("undo polish result=replaced \\(restored, privacy: .public)")', "no text logged"),
    ("summary over the cap", "whatsnew", "Plus everything in 0.5.344: ", "Plus everything in 0.5.344: " + "x" * 1201 + " ", "summary cap"),
    ("summary chains twice", "whatsnew", "Plus everything in 0.5.344: ", "Plus everything in 0.5.343: and Plus everything in 0.5.344: ", "summary cap"),
    ("an em dash in the entry", "changelog", "## 0.5.345 (build 399), Dictation parity, Wave A:", "## 0.5.345 (build 399), Dictation parity — Wave A:", "copy"),
    ("no 6.91.1 pairing", "changelog", "Pairs with COS server 6.91.1", "Pairs with COS server 6.91.0", "pairing"),
    ("B1 back: record the respelled text only", "d", "finish(delivered.typed, outcome: delivered.outcome,", "finish(delivered.context?.text ?? text, outcome: delivered.outcome,", "record what was typed"),
    ("B1 back: swap baseline without the capital", "d", "        let typed = delivered.typed\n", "        let typed = delivered.context?.text ?? text\n", "record what was typed"),
    ("B1 back: a delivery without what it typed", "d", "            return DictationDelivered(outcome: outcome, target: nil, context: context, casing: casing, wouldCapitalize: would, typed: text)",
     "            return DictationDelivered(outcome: outcome, target: nil, context: context, casing: casing, wouldCapitalize: would)", "record what was typed"),
    ("Undo polish survives Fix a word", "d", "                swappedIDs.remove(offer.recordID)\n", "", "undo polish"),
    ("parity lane not wired", "run", 'zsh "$ROOT/Tests/run-dictation-parity.sh"', 'true "$ROOT/Tests/run-dictation-parity.sh"', "lanes wired"),
    ("picker never reads the guard", "d", 'meaningGuard: response.details["meaningGuard"]?.bool, stylePairs: pairs, available: true)', 'meaningGuard: nil, stylePairs: pairs, available: true)', "picker options"),
]

sources = {k: (root / v).read_text(encoding="utf-8") for k, v in FILES.items()}
fixture = (root / "Tests/fixtures/dictation-fillers.json").read_bytes()
try:
    check(sources, fixture)
except PinFailed as e:
    sys.exit(str(e))
caught = 0
for name, key, old, new, expected in MUTANTS:
    if name in ("summary over the cap", "summary chains twice"):
        current_summary = json.loads(sources["whatsnew"])["whatsNew"]["summary"]
        chain = re.search(r"Plus everything in [0-9.]+: ", current_summary).group(0)
        old = chain
        new = chain + "x" * 1201 if name == "summary over the cap" else chain + "Plus everything in 0.5.344: "
    if sources[key].count(old) != 1:
        sys.exit(f"pin self-test: mutant '{name}' lands {sources[key].count(old)} times in {FILES[key]}; it must land exactly once")
    try:
        check(dict(sources, **{key: sources[key].replace(old, new)}), fixture)
    except PinFailed as e:
        if f"[{expected}]" not in str(e):
            sys.exit(f"pin self-test: mutant '{name}' failed {e}, expected [{expected}]")
        caught += 1
        print(f"KILLED  {name}  <- {e}")
        continue
    sys.exit(f"pin self-test: mutant '{name}' landed and every pin still passed")
try:
    check(sources, fixture[:-1])
    sys.exit("pin self-test: a changed fixture still passed")
except PinFailed as e:
    caught += 1
    print(f"KILLED  fixture byte changed  <- {e}")
print(f"PASS dictation parity pins: fixture pinned, fillers once, settings, breaker resets, timing fields, Undo polish, polish had it, "
      f"no filler chip, next time, sound gate, mute breaker, one round trip less, picker options, no text logged, the release words, the lanes; "
      f"{caught} of {len(MUTANTS) + 1} in-memory mutants caught")
