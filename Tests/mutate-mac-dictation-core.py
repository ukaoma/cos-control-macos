#!/usr/bin/env python3
"""0.5.309-0.5.313 mutation gate for the pure dictation rules (Sources/MacDictationCore.swift + Tests/MacDictationChecks.swift).

SERIAL by design: one small two-file compile at a time, each through Tests/compile-guard.sh (never parallel; see the
2026-10-07 kernel panics). Works on a scratch copy, so the checkout is never mutated. A GREEN baseline is required
before the first mutant (a red suite would "kill" every mutant). Each mutant must replace its target exactly once and
must make the checks FAIL; a mutant that compiles, runs and passes is a SURVIVOR and fails this gate.

Usage: python3 Tests/mutate-mac-dictation-core.py <repo root>
"""
import os
import pathlib, shutil, subprocess, sys, tempfile

root = pathlib.Path(sys.argv[1]).resolve()
CORE = "Sources/MacDictationCore.swift"
MUTANTS = [
    # 0.5.310 measured delivery: each of these is a way to show ✓ when nothing landed, or to paste twice.
    # 0.5.311: the held-key guard asks physical keys; both directions are bugs (paste during a chord, or never paste).
    ("held-key guard never blocks", "    static func modifiersHeld(isDown: (UInt16) -> Bool) -> Bool { modifierKeyCodes.contains(where: isDown) }",
     "    static func modifiersHeld(isDown: (UInt16) -> Bool) -> Bool { false }"),
    ("Fn counted as held again (the F17 bug)", "    static let modifierKeyCodes: [UInt16] = [55, 54, 58, 61, 59, 62, 56, 60]",
     "    static let modifierKeyCodes: [UInt16] = [55, 54, 58, 61, 59, 62, 56, 60, 63, 64]"),
    ("verification deleted: an unchanged field counts as landed", "        if after == baseline { return .unchanged }\n", ""),
    ("iTerm2 bug back: a final unchanged poll reports inserted", "            return route == .ownWindow ? .done(.refused(.noTextBox)) : .paste",
     "            return .done(.inserted(app: app, viaPaste: false))"),
    ("inserted and pasted swapped", "            case .landed, .changed: return .done(.inserted(app: app, viaPaste: true))",
     "            case .landed, .changed: return .done(.inserted(app: app, viaPaste: false))"),
    ("an unmoved or unverifiable ⌘V earns the ✓", "            case .unchanged, .unreadable: return .done(.unconfirmed(app: app, viaPaste: true))",
     "            case .unchanged, .unreadable: return .done(.inserted(app: app, viaPaste: true))"),
    ("an unmoved ⌘V tells you to press ⌘V again (double paste)", "            case .unchanged, .unreadable: return .done(.unconfirmed(app: app, viaPaste: true))",
     "            case .unchanged: return .done(.refused(.noTextBox))\n            case .unreadable: return .done(.unconfirmed(app: app, viaPaste: true))"),
    ("a changed field is pasted over (double insert)", "        case .landed, .changed:\n            return .done(.inserted(app: app, viaPaste: false))",
     "        case .landed:\n            return .done(.inserted(app: app, viaPaste: false))\n        case .changed:\n            return .paste"),
    ("no wait for a slow field", "            guard !setterSucceeded || finalPoll else { return .wait }\n", ""),
    ("unreadable baseline still tries AX", "        guard baseline.readable else { return route == .ownWindow ? .done(.unconfirmed(app: app, viaPaste: false)) : .paste }\n", ""),
    ("landed-by-count dropped", "n == n0 - length0 + count { return .landed }", "n == n0 + count + 1 { return .landed }"),
    ("landed-by-caret dropped", "after.length == 0, location == location0 + count { return .landed }", "after.length == 0, location == location0 + count + 1 { return .landed }"),
    ("terminals take the AX route", "        if terminal || !baselineReadable { return .paste }", "        if !baselineReadable { return .paste }"),
    ("unreadable baseline takes the AX route", "        if terminal || !baselineReadable { return .paste }", "        if terminal { return .paste }"),
    ("line breaks reach a terminal", 'for breakSequence in ["\\r\\n", "\\r", "\\n", "\\u{2028}", "\\u{2029}"]', 'for breakSequence in ["\\u{2028}", "\\u{2029}"]'),
    ("unconfirmed ⌘V shows a ✓", 'case .unconfirmed(_, true): .flash(label: "PASTED · ⌘V SENT", confirmed: false)', 'case .unconfirmed(_, true): .flash(label: "✓ PASTED · ⌘V SENT", confirmed: true)'),
    ("Warp prefix forgotten", 'terminals.contains(bundleID) || bundleID.hasPrefix("dev.warp.")', "terminals.contains(bundleID)"),
    ("Electron not detected", 'name == "Electron Framework.framework" || ', ""),
    ("layout ignored", "for code in UInt16(0)..<128 where translate(code)?.lowercased() == character { return code }", "return 9"),
    ("Shift no longer blocks the paste", "static let modifierKeyCodes: [UInt16] = [55, 54, 58, 61, 59, 62, 56, 60]", "static let modifierKeyCodes: [UInt16] = [55, 54, 58, 61, 59, 62]"),
    # Policy: a role alone is not a text box; distinct refusals stay distinct.
    ("trust ignored", "        guard trusted else { return .notTrusted }\n", ""),
    ("password field reads as secure input", "        if subrole == secureSubrole { return .secureField }\n", ""),
    ("secure input ignored", "        if secureInput { return .secureInput }\n", ""),
    ("own panel allowed", "        if ownOverlay { return .ownOverlay }\n", ""),
    ("read-only field accepted", "        if focused, textSettable || editableAncestor { return nil }", "        if focused { return nil }"),
    ("web editor ignored", "        if focused, textSettable || editableAncestor { return nil }", "        if focused, textSettable { return nil }"),
    ("terminal/Electron refused", "        return pasteApp ? nil : .noTextBox", "        return .noTextBox"),
    # History, meter, card, fix-a-word.
    ("legacy inserted trusted as inserted", "            delivery = .unconfirmed(app: app, viaPaste: try c.decodeIfPresent(Bool.self, forKey: .pasted) ?? false)",
     "            delivery = .inserted(app: app)"),
    ("corrupt history overwritten", "        guard rename(url.path, aside.path) == 0 else { return ([], nil, false) }\n        return ([], aside, true)", "        return ([], nil, true)"),
    ("delete removes nothing", "list.filter { $0.id != id } }", "list }"),
    ("root cause back: fixed -50..-10 dBFS window", "        let target = db <= gate ? 0 : min(1, (db - gate) / (peakDB - gate))",
     "        let target = min(1, max(0, (db + 50) / 40))"),
    ("no silence gate", "        let target = db <= gate ? 0 : min(1, (db - gate) / (peakDB - gate))", "        let target = min(1, max(0, (db - floor) / (peakDB - floor)))"),
    ("speech-first start sets the floor", "?? min(db, Self.startFloorDB)", "?? db"),
    ("floor never falls", "floorDB.map { db < $0 ? db : $0 + Self.floorRiseDB }", "floorDB.map { $0 + Self.floorRiseDB }"),
    ("restore when the clipboard changed", "        guard currentChangeCount == setChangeCount else { return .skip(\"clipboard changed since the paste\") }\n", ""),
    ("restore after a card path", "        guard pasted else { return .skip(\"no paste\") }\n", ""),
    ("never restoring", "        return .restore\n    }", "        return .skip(\"never\")\n    }"),
    ("Accessibility path overwrites the clipboard", "viaPaste ? .pasteThenRestore : .untouched", "viaPaste ? .pasteThenRestore : .keepForCard"),
    ("snapshot ignores the cap", "                guard total <= cap else { return nil }\n", ""),
    ("item order lost", "            items.append(DictationClipboardItem(entries: entries))", "            items.insert(DictationClipboardItem(entries: entries), at: 0)"),
    ("restore too early", "        if elapsedMilliseconds < restoreAfterMilliseconds { return true }\n", ""),
    ("sound plays at volume 0", "        guard volume > 0 else { return .silent(\"volume off\") }\n", ""),
    ("sound plays during a Mac recording", "        guard !macRecording else { return .silent(\"a COS recording is capturing\") }\n", ""),
    ("a stale custom file is played", "        case .custom(let file) where customUsable(file): return .custom(file)", "        case .custom(let file): return .custom(file)"),
    ("library choice ignored", "        case .library(let id) where sounds.contains(where: { $0.id == id }): return .bundled(fileName(id, edge))\n", ""),
    ("Jedi default changed", 'case .jedi: pack == winduPackID ? "windu-saber" : "unstable-saber"', 'case .jedi: pack == winduPackID ? "windu-saber" : "soft-chime"'),
    ("source size unchecked", "        guard byteCount <= maximumSourceBytes else {", "        guard byteCount <= Int.max else {"),
    ("trim start ignores the onset", "Window(start: onset, end: min(duration, onset + 2.0), fadeIn: 0.005, fadeOut: 0.45)", "Window(start: 0, end: min(duration, 2.0), fadeIn: 0.005, fadeOut: 0.45)"),
    ("stop window without the tail", "Window(start: max(0, end - 0.55), end: min(duration, end + 0.05), fadeIn: 0.030, fadeOut: 0.070)", "Window(start: max(0, end - 0.6), end: min(duration, end), fadeIn: 0.030, fadeOut: 0.070)"),
    ("end at the last loud window's start", "levels.lastIndex { $0 >= thresholdDB }.map { Double($0 + 1) * windowSeconds }", "levels.lastIndex { $0 >= thresholdDB }.map { Double($0) * windowSeconds }"),
    ("no fade-out", "        for i in 0..<fadeOut { out[out.count - 1 - i] *= Float(i) / Float(fadeOut) }\n", ""),
    ("pill always on the pet", "        if let petFrame, let focused, overlap(focused, petFrame) > 0 { return .pet }", "        if petFrame != nil { return .pet }"),
    ("pitch not clamped", "return min(pitchRange.upperBound, max(pitchRange.lowerBound, semitones.rounded())) * 100", "return semitones.rounded() * 100"),
    ("pitch in semitones, not cents", "return min(pitchRange.upperBound, max(pitchRange.lowerBound, semitones.rounded())) * 100", "return min(pitchRange.upperBound, max(pitchRange.lowerBound, semitones.rounded()))"),
    ("bars ignore the level", "return minimum + (maximum - minimum) * min(1, max(0, level)) * weight", "return minimum + (maximum - minimum) * 0.1 * weight"),
    ("slow attack", "level = target >= level ? target : level * Self.release + target * (1 - Self.release)", "level = level * Self.release + target * (1 - Self.release)"),
    # 0.5.313 quiet: the volume always comes back, never during a Mac recording, never a blind media key.
    ("never restores the volume", "        return abs(current - lowered) < 0.02 ? saved : nil\n", "        return nil\n"),
    ("the person's volume change overwritten", "        return abs(current - lowered) < 0.02 ? saved : nil\n", "        return saved\n"),
    ("launch never restores", "        guard let pending else { return nil }\n        return restoreVolume(saved: pending.saved, lowered: pending.lowered, current: current)",
     "        _ = pending; _ = current; return nil"),
    ("mute during a Mac recording", "        if macRecording { return .leave(\"a COS recording is capturing\") }\n", ""),
    ("mute without System Audio Recording", "        case .mute where tapPermitted: return .muteTap", "        case .mute: return .muteTap"),
    ("lowered to silence", "            return .lowerVolume(to: volume * loweredFraction)", "            return .lowerVolume(to: 0)"),
    ("Mute not the default", "    static let `default` = DictationQuietMode.mute", "    static let `default` = DictationQuietMode.lower"),
    ("blind media key", "playing == true ? .pause : .leave", "playing == false ? .leave : .pause"),
    # 0.5.315 Miles Windu saber: his pack only, recognized only when exactly one shipped pack matches.
    ("Windu back to the Unstable saber", 'case .jedi: pack == winduPackID ? "windu-saber" : "unstable-saber"', 'case .jedi: "unstable-saber"'),
    ("every Jedi gets the Windu saber", 'case .jedi: pack == winduPackID ? "windu-saber" : "unstable-saber"', 'case .jedi: "windu-saber"'),
    ("an ambiguous pack is named", "        return matches.count == 1 ? matches[0].id : nil", "        return matches.first?.id"),
    ("an empty pack matches", "        guard !installed.isEmpty else { return nil }\n", ""),
    ("the pack is ignored when playing", "        default: return .bundled(fileName(petDefault(pet, pack: pack), edge))", "        default: return .bundled(fileName(petDefault(pet), edge))"),
    # 0.5.315 mute tap: muted only when the IO runs; a failure tears down exactly what exists, in reverse; the IOProc
    # outputs silence and measures the tapped peak.
    ("mute tap: build runs on after a failure", "            guard status == 0 else { return (built, Failure(step: step, status: status)) }\n",
     "            guard status == 0 else { continue }\n"),
    ("mute tap: the failing step counts as built", "            guard status == 0 else { return (built, Failure(step: step, status: status)) }\n            built.record(step)",
     "            built.record(step)\n            guard status == 0 else { return (built, Failure(step: step, status: status)) }"),
    ("mute tap: muted without the IO running", "        var muting: Bool { tap && aggregate && ioProc && running }", "        var muting: Bool { tap && aggregate && ioProc }"),
    ("mute tap: a started IO is not recorded", "            case .start: running = true", "            case .start: break"),
    ("mute tap: the UID step claims an aggregate", "            case .tapUID: break", "            case .tapUID: aggregate = true"),
    ("mute tap: IO never stopped", "        if built.running { steps.append(.stop) }\n", ""),
    ("mute tap: tap left behind", "        if built.tap { steps.append(.destroyTap) }\n", ""),
    ("mute tap: IOProc destroyed before the IO stops", "        if built.running { steps.append(.stop) }\n        if built.ioProc { steps.append(.destroyIOProc) }",
     "        if built.ioProc { steps.append(.destroyIOProc) }\n        if built.running { steps.append(.stop) }"),
    ("mute tap: aggregate destroyed before its IOProc", "        if built.ioProc { steps.append(.destroyIOProc) }\n        if built.aggregate { steps.append(.destroyAggregate) }",
     "        if built.aggregate { steps.append(.destroyAggregate) }\n        if built.ioProc { steps.append(.destroyIOProc) }"),
    ("mute tap: a new output keeps the mute", "    static func keepOnOutputChange(mutedOn: String, now: String?) -> Bool { now == mutedOn }",
     "    static func keepOnOutputChange(mutedOn: String, now: String?) -> Bool { true }"),
    ("mute tap: a vanished output keeps the mute", "    static func keepOnOutputChange(mutedOn: String, now: String?) -> Bool { now == mutedOn }",
     "    static func keepOnOutputChange(mutedOn: String, now: String?) -> Bool { now == nil || now == mutedOn }"),
    ("mute IO: no silence written", "                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }\n", ""),
    ("mute IO: peak not reported", "            meter.record(peak: peak)", "            meter.record(peak: 0)"),
    ("mute IO: negative samples ignored", "peak = max(peak, abs(samples[index]))", "peak = max(peak, samples[index])"),
    ("mute IO: callbacks not counted", "$0.callbacks += 1; ", ""),
    # 0.5.313 shortcuts, quick fix, replace, span guess.
    ("slot conflicts ignored", "        return assigned.contains { $0.key != slot && $0.value == trigger }", "        return false"),
    ("Open Activity conflict ignored", "        if trigger == activity { return true }\n", ""),
    ("default Fix shortcut changed", "modifiers: DictationTrigger.control | DictationTrigger.option)", "modifiers: DictationTrigger.control)"),
    ("quick fix while dictating", "busy ? nil : recent.first?.id", "recent.first?.id"),
    ("Fix offered on a refusal", "    static func offers(_ outcome: DictationDeliveryOutcome) -> Bool { outcome.flash != nil }",
     "    static func offers(_ outcome: DictationDeliveryOutcome) -> Bool { true }"),
    ("a changed field records a span", "DictationDelivery.verdict(baseline: baseline, after: after, count: count) == .landed else { return nil }",
     "DictationDelivery.verdict(baseline: baseline, after: after, count: count) != .unreadable else { return nil }"),
    ("replace over moved text", "guard inserted.utf16.count == span.length, let textAtSpan, textAtSpan == inserted else", "guard let textAtSpan, !textAtSpan.isEmpty else"),
    ("terminal edited in place", "        if terminal { return .copy(.terminal) }\n", ""),
    ("replace in a shorter field", "        guard fieldCharacters >= span.location + span.length else { return .copy(.fieldChanged) }\n", ""),
    ("replace after the app quit", "        guard appRunning else { return .copy(.appGone) }\n", ""),
    ("same-length fix proved by the count", "        if newLength == span.length { return caretOK == true }\n", ""),
    ("corrected text loses trailing punctuation", "            + String(phrase.suffix(trail)) + String(text[whole.upperBound...])", "            + String(text[whole.upperBound...])"),
    ("guess ignores sound", "let sounded = h.count >= 3 && t.count >= 3 ? similarity(h, t) * 0.95 : 0", "let sounded = 0.0"),
    ("guess prefers the wider span", "(abs(s - best!.score) <= 1e-9 && width < best!.width)", "(abs(s - best!.score) <= 1e-9 && width > best!.width)"),
    ("the tap never widens", "            if lower > 0, unknown(lower - 1) { lower -= 1 }\n            else if upper + 1 < tokens.count, unknown(upper + 1) { upper += 1 }\n            else { break }",
     "            break"),
    ("suggests what is already spelled right", "                    guard !t.isEmpty, t != h else { continue }", "                    guard !t.isEmpty else { continue }"),
    # 0.5.312 retention: Keep dictations for 7/30/90 days, Forever or Don't keep, never more than 5,000.
    ("retention ignored", "        let kept = retention.days.map { days in list.filter { now.timeIntervalSince($0.createdAt) <= Double(days) * 86_400 } } ?? list\n",
     "        let kept = list\n"),
    ("every click cancels", "        guard down, clean, time - pressedAt < Self.clickChordWindow else { return nil }\n", "        guard down, clean else { return nil }\n"),
    ("clicks never chord", "        guard down, clean, time - pressedAt < Self.clickChordWindow else { return nil }\n", "        guard down, clean, false else { return nil }\n"),
    ("click window inclusive", "time - pressedAt < Self.clickChordWindow", "time - pressedAt <= Self.clickChordWindow"),
    ("press time not kept", "            down = true; pressedAt = time\n", "            down = true\n"),
    ("click chord does not latch", "        guard down, clean, time - pressedAt < Self.clickChordWindow else { return nil }\n        clean = false; return .chord", "        guard down, clean, time - pressedAt < Self.clickChordWindow else { return nil }\n        return .chord"),
    ("salvage keeps a tap", "    static func salvages(pcmBytes: Int) -> Bool { pcmBytes >= salvageMinimumBytes }", "    static func salvages(pcmBytes: Int) -> Bool { pcmBytes > 0 }"),
    ("salvage never", "    static func salvages(pcmBytes: Int) -> Bool { pcmBytes >= salvageMinimumBytes }", "    static func salvages(pcmBytes: Int) -> Bool { false }"),
    ("cap ignored", "        return Array(kept.prefix(cap))\n", "        return kept\n"),
    ("Don't keep keeps everything", "        if retention == .none { return Array(list.prefix(sessionOnly)) }\n", ""),
    ("Don't keep still writes", "    var writesToDisk: Bool { self != .none }", "    var writesToDisk: Bool { true }"),
    ("default retention is Forever", "    static let `default` = DictationRetention.month", "    static let `default` = DictationRetention.forever"),
    ("search is case sensitive", "range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])", "range(of: needle, options: [.diacriticInsensitive])"),
    ("days out of order", "groups.keys.sorted(by: >)", "groups.keys.sorted(by: <)"),
    ("a count back on the pill", 'static let pillLabel = "DICTATIONS"', 'static let pillLabel = "DICTATIONS 10"'),
    ("history world-readable", "attributes: [.posixPermissions: 0o600]", "attributes: [.posixPermissions: 0o644]"),
    ("temp file left behind", "        guard rename(temp.path, url.path) == 0 else {", "        guard link(temp.path, url.path) == 0 else {"),
    ("hover does not pause", "mutating func pause(at now: Date) { guard let since = runningSince else { return }; spent += max(0, now.timeIntervalSince(since)); runningSince = nil }",
     "mutating func pause(at now: Date) { }"),
    ("tap never clears", "        if current == index...index { return nil }\n", ""),
    ("pill never hands the ledger back", "var replacesLedger: Bool { self != .hidden }", "var replacesLedger: Bool { true }"),
    ("RMS becomes peak", "return (sum / Double(samples)).squareRoot()", "return sum > 0 ? 1 : 0"),
]


def compile_and_run(work: pathlib.Path) -> int:
    out = work / "checks"
    if out.exists():
        out.unlink()
    build = subprocess.run(["/usr/bin/python3", str(root / "Tests/kit-compile.py"), "/bin/zsh", str(root / "Tests/compile-guard.sh"), "swiftc", "-target", "arm64-apple-macosx14.0",
                            "-swift-version", "6", "-strict-concurrency=complete", "-parse-as-library",
                            str(work / CORE), str(work / "Tests/MacDictationChecks.swift"), "-o", str(out)],
                           capture_output=True, text=True)
    if build.returncode != 0:
        return 2
    return subprocess.run([str(out)], capture_output=True, text=True).returncode


work = pathlib.Path(tempfile.mkdtemp(prefix="cos-dictation-mutants-", dir="/private/tmp"))
# Lanes compile against shared builds of Sources (Tests/kit-compile.py): keep them for every mutant of this run.
os.environ.setdefault("COS_TEST_KIT_DIR", str(work / ".kits"))
try:
    (work / "Sources").mkdir(); (work / "Tests").mkdir()
    shutil.copy(root / CORE, work / CORE)
    shutil.copy(root / "Tests/MacDictationChecks.swift", work / "Tests/MacDictationChecks.swift")
    original = (work / CORE).read_text()
    if compile_and_run(work) != 0:
        sys.exit("baseline is not green: fix the checks before reading any mutant")
    survivors = []
    for name, old, new in MUTANTS:
        if original.count(old) != 1:
            sys.exit(f"mutant '{name}' targets {original.count(old)} sites; it must land exactly once")
        (work / CORE).write_text(original.replace(old, new))
        code = compile_and_run(work)
        verdict = "KILLED (did not compile)" if code == 2 else ("KILLED" if code != 0 else "SURVIVED")
        print(f"{verdict:24} {name}")
        if code == 0:
            survivors.append(name)
        (work / CORE).write_text(original)
    if survivors:
        sys.exit(f"{len(survivors)} survivor(s): {survivors}")
    print(f"PASS dictation core mutation gate: {len(MUTANTS)} mutants, all killed, green baseline")
finally:
    shutil.rmtree(work, ignore_errors=True)
