#!/usr/bin/env python3
"""0.5.309-0.5.313 mutation gate for the pure dictation rules (Sources/MacDictationCore.swift + Tests/MacDictationChecks.swift).

SERIAL by design: one small two-file compile at a time, each through Tests/compile-guard.sh (never parallel; see the
2026-10-07 kernel panics). Works on a scratch copy, so the checkout is never mutated. A GREEN baseline is required
before the first mutant (a red suite would "kill" every mutant). Each mutant must replace its target exactly once.

A KILL counts only when the mutant compiles, runs, and a named check in Tests/MacDictationChecks.swift fails (its
precondition message is printed beside the mutant, so every kill is attributed to the behaviour that caught it).
Everything else fails this gate on its own line: SURVIVED (the checks passed), INVALID (did not compile, or timed
out: rewrite the mutant so it compiles and runs), CRASHED (a trap outside the checks, such as an index out of range:
rewrite the mutant, or add the check that names that behaviour). 0.5.318: before this, a mutant that did not compile
was counted as killed, which proves nothing about the checks.

Usage: python3 Tests/mutate-mac-dictation-core.py <repo root>
"""
import os
import pathlib, re, shutil, subprocess, sys, tempfile

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
    ("terminal edited in place", "        if terminal { return .copy(.terminal) }\n", ""),
    ("replace after the app quit", "        guard appRunning else { return .copy(.appGone) }\n", ""),
    # 0.5.318 replace (Miles 13:02, Claude): plan, route, paste proof, confirmation; Save corrects the record.
    ("replace ignores where COS put it", "        if !whole.isEmpty, matches(whole, in: field, at: expected) { return .edit(placed(expected), dictationAt: span.location) }\n", ""),
    ("moved dictation not followed", "        if found.count == 1 { return .edit(placed(found[0]), dictationAt: windowStart + found[0]) }\n", ""),
    ("ambiguous dictation replaced", "        if found.count == 1 { return .edit(placed(found[0]), dictationAt: windowStart + found[0]) }",
     "        if found.count >= 1 { return .edit(placed(found[0]), dictationAt: windowStart + found[0]) }"),
    ("words searched beside a second copy", "        if found.isEmpty, phrase.count >= minimumPhraseUnits {", "        if phrase.count >= minimumPhraseUnits {"),
    ("short words searched", "        if found.isEmpty, phrase.count >= minimumPhraseUnits {", "        if found.isEmpty, phrase.count >= 1 {"),
    ("words matched inside other words", "            let hits = occurrences(phrase, in: field, wordBounded: true)", "            let hits = occurrences(phrase, in: field, wordBounded: false)"),
    ("repeated words replaced", "            if hits.count == 1 {", "            if !hits.isEmpty {"),
    ("words-only edit still tracked", "replacement: edit.replacement), dictationAt: nil)", "replacement: edit.replacement), dictationAt: windowStart + hits[0])"),
    ("no change reported as moved text", "        guard let edit = wordEdit(from: current, to: corrected) else { return .copy(.noChange) }",
     "        guard let edit = wordEdit(from: current, to: corrected) else { return .copy(.textMoved) }"),
    ("edit drops the common words before", "        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }\n", ""),
    ("edit drops the common words after", "        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }\n", ""),
    ("edit suffix stops one word early", "        while s < a.count - p, s < b.count - p, a[a.count - 1 - s]", "        while s < a.count - p - 1, s < b.count - p, a[a.count - 1 - s]"),
    ("edit not on word boundaries", "                if gap != nil, g != gap { out.append(current); current = \"\" }", "                out.append(current); current = \"\""),
    ("window reads from the field's start", "        let start = max(0, min(span.location, fieldCharacters) - windowRadius)", "        let start = 0"),
    ("window ignores a longer dictation", "span.location + max(span.length, currentLength) + windowRadius)", "span.location + span.length + windowRadius)"),
    ("window not clipped to the field", "        let end = min(fieldCharacters, span.location + max(span.length, currentLength) + windowRadius)",
     "        let end = span.location + max(span.length, currentLength) + windowRadius"),
    ("Electron replace by the no-op setter", "    static func route(setterWorked: Bool) -> Route { setterWorked ? .accessibility : .paste }",
     "    static func route(setterWorked: Bool) -> Route { .accessibility }"),
    ("paste into a background app", "        guard frontmost, !ownWindowKey, focusedIsTarget else { return .notFocused }", "        guard !ownWindowKey, focusedIsTarget else { return .notFocused }"),
    ("paste into COS's own panel", "        guard frontmost, !ownWindowKey, focusedIsTarget else { return .notFocused }", "        guard frontmost, focusedIsTarget else { return .notFocused }"),
    ("paste into another field", "        guard frontmost, !ownWindowKey, focusedIsTarget else { return .notFocused }", "        guard frontmost, !ownWindowKey else { return .notFocused }"),
    ("selection length unchecked", "        guard selection.location == edit.location, selection.length == edit.length else { return .selectionUnproven }",
     "        guard selection.location == edit.location else { return .selectionUnproven }"),
    ("selection place unchecked", "        guard selection.location == edit.location, selection.length == edit.length else { return .selectionUnproven }",
     "        guard selection.length == edit.length else { return .selectionUnproven }"),
    ("selected text unchecked", "        guard edit.length == 0 || selectedText == edit.original else { return .selectionUnproven }\n", ""),
    ("read-back ignored", "        return readback == nil || readback == edit.replacement", "        return true"),
    ("Electron no-op confirmed", "        guard verified(before: before, after: after, span: span, newLength: edit.replacement.utf16.count) else { return false }\n", ""),
    ("Save corrects another dictation", "list.map { $0.id == id ? DictationRecord(", "list.map { $0.id != id ? DictationRecord("),
    # 0.5.318 Learn from my edits (Miles 13:31): default, native-only gating, secure exclusion, window cap, 7-day expiry, undo.
    ("learn mode defaults to Suggest only", "    static let `default` = DictationLearnMode.automatic", "    static let `default` = DictationLearnMode.suggest"),
    ("Off still watches", '        if mode == .off { return .skip("off") }\n', ""),
    ("password fields watched", '        if secure { return .skip("secure") }\n', ""),
    ("terminals watched", '        if terminal { return .skip("terminal") }\n', ""),
    ("Electron learned from", "        if electron { return .probe }\n", ""),
    ("web editors learned from", "        if chromium, !setterWorked { return .probe }\n", ""),
    ("secure checked after Electron", '        if secure { return .skip("secure") }\n        if terminal { return .skip("terminal") }\n        if electron { return .probe }',
     '        if electron { return .probe }\n        if secure { return .skip("secure") }\n        if terminal { return .skip("terminal") }'),
    ("secure input ignored while watching", "        if secure { return .secure }\n", ""),
    ("secure checked after the app", "        if secure { return .secure }\n        if !appRunning { return .appGone }", "        if !appRunning { return .appGone }\n        if secure { return .secure }"),
    ("watch never capped", "        if elapsed >= watchSeconds { return .cap }\n", ""),
    ("cap one tick late", "        if elapsed >= watchSeconds { return .cap }", "        if elapsed > watchSeconds { return .cap }"),
    ("five-minute cap", "    static let watchSeconds: TimeInterval = 180", "    static let watchSeconds: TimeInterval = 300"),
    ("reads never capped", "        if reads >= maximumReads { return .reads }\n", ""),
    ("one read too many", "        if reads >= maximumReads { return .reads }", "        if reads > maximumReads { return .reads }"),
    ("focus leaving ignored", "        if !focused { return .focusLeft }\n", ""),
    ("sent message still watched", "        if fieldCharacters == 0 { return .emptied }\n", ""),
    ("read not clipped to the field", "        max(0, min(currentCharacters - start, baselineLength + currentCharacters - baselineCharacters))",
     "        max(0, baselineLength + currentCharacters - baselineCharacters)"),
    ("typing after it reads as inside", "        if edit.location >= end { return .moved(start: start, length: length) }\n", ""),
    ("typing before it does not move it", "return .moved(start: start + delta, length: length) }", "return .moved(start: start, length: length) }"),
    ("inside edit keeps the old length", "            return .inside(relative, length: length + delta)", "            return .inside(relative, length: length)"),
    ("four-word edits learned", "    static let pollMilliseconds = 500\n    static let maximumWords = 3", "    static let pollMilliseconds = 500\n    static let maximumWords = 4"),
    ("punctuation fixes learned", "            guard heard.lowercased() == written.lowercased() else { return nil }\n", ""),
    ("sentence capitals learned", "            guard innerCapital || !heardWords.allSatisfy(known) else { return nil }\n", ""),
    ("rewordings learned", "            guard DictationFixGuess.score(heard: heard, term: written) >= DictationFixGuess.threshold else { return nil }\n", ""),
    ("homophones learned", "            if heardWords.allSatisfy(known), writtenWords.allSatisfy(known) { return nil }\n", ""),
    ("already learned learned again", "        guard !learned(heard, written) else { return nil }\n", ""),
    ("learned across a line break", ", !(heard + written).contains(where: \\.isNewline) else { return nil }", " else { return nil }"),
    ("watch starts from an empty proof", "        !text.isEmpty && matches(Array(text.utf16), in: Array(window.utf16), at: offset)", "        matches(Array(text.utf16), in: Array(window.utf16), at: offset)"),
    ("suggestions kept eight days", "    static let keepDays = 7", "    static let keepDays = 8"),
    ("suggestions kept through day seven", "    private static func fresh(_ date: Date, days: Int, now: Date) -> Bool { now.timeIntervalSince(date) < Double(days) * 86_400 }",
     "    private static func fresh(_ date: Date, days: Int, now: Date) -> Bool { now.timeIntervalSince(date) <= Double(days) * 86_400 }"),
    ("suggestions never expire", "        next.suggestions = Array(state.suggestions.filter { fresh($0.at, days: keepDays, now: now) }.prefix(cap))",
     "        next.suggestions = Array(state.suggestions.prefix(cap))"),
    ("learned rows never expire", "        next.learned = Array(state.learned.filter { fresh($0.at, days: learnedDays, now: now) }.prefix(cap))",
     "        next.learned = Array(state.learned.prefix(cap))"),
    ("dismissals never expire", "        next.dismissed = state.dismissed.filter { fresh($0.value, days: dismissDays, now: now) }", "        next.dismissed = state.dismissed"),
    ("dismissed pairs suggested again", "        guard !isQuiet(item.heard, item.written, in: next, now: now) else { return next }\n", ""),
    # 0.5.317: the day-29 clause was vacuous while its suggestion was stamped day 0 (pruned for age, so empty either way).
    # A 29-day dismissal is caught only by that clause, now that its suggestion is stamped day 29.
    ("dismissal lasts 29 days", "    static let dismissDays = 30", "    static let dismissDays = 29"),
    ("quiet forever", "        state.dismissed[key(heard, written)].map { fresh($0, days: dismissDays, now: now) } ?? false", "        state.dismissed[key(heard, written)] != nil"),
    ("the same pair listed twice", "        next.suggestions = [item] + next.suggestions.filter { key($0.heard, $0.written) != k }", "        next.suggestions = [item] + next.suggestions"),
    ("Add leaves it suggested", "        next.suggestions = next.suggestions.filter { key($0.heard, $0.written) != k }\n        return pruned(next, now: now)\n    }\n    /// Added",
     "        return pruned(next, now: now)\n    }\n    /// Added"),
    ("Add does nothing", "        for item in state.suggestions where ids.contains(item.id) { next = learning(item, in: next, now: now) }\n", ""),
    ("Dismiss and Undo forget the pair", "        for item in state.suggestions + state.learned where item.id == id { next.dismissed[key(item.heard, item.written)] = now }\n", ""),
    ("Undo leaves it learned", "        next.learned.removeAll { $0.id == id }\n", ""),
    ("Undo reverses the wrong entry", "        recent.first { $0.heard == item.heard && $0.written == item.written }?.id", "        recent.first { $0.heard == item.heard }?.id"),
    ("suggestions world-readable", 'contents: data, attributes: [.posixPermissions: 0o600]) else {\n            throw NSError(domain: "COSDictation", code: 4,',
     'contents: data, attributes: [.posixPermissions: 0o644]) else {\n            throw NSError(domain: "COSDictation", code: 4,'),
    ("CEF apps taken for browsers", '$0 == "Electron Framework.framework" || $0 == "Chromium Embedded Framework.framework" }', '$0 == "Electron Framework.framework" }'),
    # 0.5.318 spoken lists: prose stays prose.
    ("markers anywhere in a sentence", "            guard atSentenceStart(match.range.location, in: ns, comma: kind != .cardinal) else { return nil }\n", ""),
    ("counting after commas is a list", "comma: kind != .cardinal) else { return nil }", "comma: true) else { return nil }"),
    ("no punctuation needed after number N", '.number: connector + #"\\bnumber\\s+("# + n + #"|10|[1-9])\\b\\s*"# + punctuation + #"\\s*"#',
     '.number: connector + #"\\bnumber\\s+("# + n + #"|10|[1-9])\\b\\s*"# + punctuation + "?" + #"\\s*"#'),
    ("two bare numbers make a list", "    static func minimum(_ kind: Kind) -> Int { kind == .cardinal ? 3 : 2 }", "    static func minimum(_ kind: Kind) -> Int { 2 }"),
    ("one marker makes a list", "    static func minimum(_ kind: Kind) -> Int { kind == .cardinal ? 3 : 2 }", "    static func minimum(_ kind: Kind) -> Int { kind == .cardinal ? 3 : 1 }"),
    ("numbers out of order", "        for marker in found where marker.value == run.count + 1 { run.append(marker) }", "        for marker in found { run.append(marker) }"),
    ("punctuation-only items listed", "        guard item.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }), let first = item.first else { return nil }",
     "        guard let first = item.first else { return nil }"),
    ("bare dash or bullet without punctuation", '                if word == "bullet" || word == "dash", separator.rangeOfCharacter(from: CharacterSet(charactersIn: ",:;.-–—")) == nil { return nil }\n', ""),
    ("items not capitalized", "        return word == word.lowercased() ? first.uppercased() + item.dropFirst() : item", "        return item"),
    ("iPhone capitalized", "        return word == word.lowercased() ? first.uppercased() + item.dropFirst() : item", "        return first.uppercased() + item.dropFirst()"),
    ("lead-in comma kept", '        if lead.hasSuffix(",") { lead = String(lead.dropLast()) + ":" }\n', ""),
    ("later list wins", "            if best == nil || run[0].start < best!.run[0].start { best = (kind, run) }", "            if best == nil || run[0].start > best!.run[0].start { best = (kind, run) }"),
    ("connectors not consumed", '    private static let connector = #"(?:\\b(?:and then|and|then|also|plus)\\s+)?"#', '    private static let connector = #""#'),
    ("trailing comma kept on items", '        while let last = item.last, last == "," || last == ";" { item = String(item.dropLast()).trimmingCharacters(in: .whitespaces) }\n', ""),
    ("ordered bullets", '            items.append((best.kind == .bullet ? "- " : "\\(i + 1). ") + item)', '            items.append("\\(i + 1). " + item)'),
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
    ("history world-readable", 'attributes: [.posixPermissions: 0o600]) else {\n            throw NSError(domain: "COSDictation", code: 3,',
     'attributes: [.posixPermissions: 0o644]) else {\n            throw NSError(domain: "COSDictation", code: 3,'),
    ("temp file left behind", '        guard rename(temp.path, url.path) == 0 else {\n            try? FileManager.default.removeItem(at: temp)\n            throw NSError(domain: "COSDictation", code: 3,',
     '        guard link(temp.path, url.path) == 0 else {\n            try? FileManager.default.removeItem(at: temp)\n            throw NSError(domain: "COSDictation", code: 3,'),
    ("hover does not pause", "mutating func pause(at now: Date) { guard let since = runningSince else { return }; spent += max(0, now.timeIntervalSince(since)); runningSince = nil }",
     "mutating func pause(at now: Date) { }"),
    ("tap never clears", "        if current == index...index { return nil }\n", ""),
    ("pill never hands the ledger back", "var replacesLedger: Bool { self != .hidden }", "var replacesLedger: Bool { true }"),
    ("RMS becomes peak", "return (sum / Double(samples)).squareRoot()", "return sum > 0 ? 1 : 0"),
]


# A failed check, in either wording Swift uses for precondition (0.5.317 field run: this toolchain prints
# "checks/MacDictationChecks.swift:108: Precondition failed: <name>"; the first version of this gate matched only
# "Fatal error:", so every real kill read as CRASHED). A trap anywhere else names another file and stays CRASHED.
CHECK_FAILURE = re.compile(r"MacDictationChecks\.swift:\d+: (?:Fatal error|Precondition failed): (.+)"
                           r"|(?:Fatal error|Precondition failed): (.+?): file [^\n]*MacDictationChecks\.swift, line \d+")


def failed_check(output: str) -> "str | None":
    """The message of the named check that failed, or None when the run trapped outside the checks."""
    found = CHECK_FAILURE.search(output)
    return (found.group(1) or found.group(2)).strip() if found else None


def classifier_self_test() -> None:
    """Runs before the baseline, so the classifier cannot regress quietly in either direction."""
    cases = [
        ("checks/MacDictationChecks.swift:108: Precondition failed: left/right held blocks the paste", "left/right held blocks the paste"),
        ("/w/Tests/MacDictationChecks.swift:137: Fatal error: an added word is an insertion", "an added word is an insertion"),
        ("Precondition failed: spoken list: x: file /w/Tests/MacDictationChecks.swift, line 9", "spoken list: x"),
        ("checks/MacDictationCore.swift:88: Precondition failed: a trap in the core", None),
        ("Swift/ContiguousArrayBuffer.swift:600: Fatal error: Index out of range", None),
    ]
    for text, want in cases:
        got = failed_check(text)
        if got != want:
            sys.exit(f"classifier self-test failed: {text!r} read as {got!r}, expected {want!r}")
    print(f"classifier self-test: {len(cases)} cases (named check failures read as kills; core and stdlib traps stay CRASHED)")


def compile_checks(work: pathlib.Path) -> tuple[bool, str]:
    out = work / "checks"
    if out.exists():
        out.unlink()
    build = subprocess.run(["/usr/bin/python3", str(root / "Tests/kit-compile.py"), "/bin/zsh", str(root / "Tests/compile-guard.sh"), "swiftc", "-target", "arm64-apple-macosx14.0",
                            "-swift-version", "6", "-strict-concurrency=complete", "-parse-as-library",
                            str(work / CORE), str(work / "Tests/MacDictationChecks.swift"), "-o", str(out)],
                           capture_output=True, text=True)
    first_error = next((line for line in (build.stderr + build.stdout).splitlines() if "error:" in line), "")
    return build.returncode == 0, first_error.strip()


def classify(work: pathlib.Path) -> tuple[str, str]:
    """(verdict, detail): KILLED with the failing check's message, or SURVIVED, INVALID, CRASHED."""
    built, error = compile_checks(work)
    if not built:
        return "INVALID", "did not compile: " + error
    try:
        run = subprocess.run([str(work / "checks")], capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        return "INVALID", "timed out"
    if run.returncode == 0:
        return "SURVIVED", ""
    message = failed_check(run.stderr + run.stdout)
    if message:
        return "KILLED", message
    tail = (run.stderr + run.stdout).strip().splitlines()
    return "CRASHED", tail[-1] if tail else f"exit {run.returncode}"


classifier_self_test()
work = pathlib.Path(tempfile.mkdtemp(prefix="cos-dictation-mutants-", dir="/private/tmp"))
# Lanes compile against shared builds of Sources (Tests/kit-compile.py): keep them for every mutant of this run.
os.environ.setdefault("COS_TEST_KIT_DIR", str(work / ".kits"))
try:
    (work / "Sources").mkdir(); (work / "Tests").mkdir()
    shutil.copy(root / CORE, work / CORE)
    shutil.copy(root / "Tests/MacDictationChecks.swift", work / "Tests/MacDictationChecks.swift")
    original = (work / CORE).read_text()
    verdict, detail = classify(work)
    if verdict != "SURVIVED":
        sys.exit(f"baseline is not green ({verdict}: {detail}): fix the checks before reading any mutant")
    for name, old, _ in MUTANTS:
        if original.count(old) != 1:
            sys.exit(f"mutant '{name}' targets {original.count(old)} sites; it must land exactly once")
    results: dict[str, list[str]] = {"KILLED": [], "SURVIVED": [], "INVALID": [], "CRASHED": []}
    for name, old, new in MUTANTS:
        (work / CORE).write_text(original.replace(old, new))
        verdict, detail = classify(work)
        results[verdict].append(name)
        print(f"{verdict:9} {name}" + (f"  <- {detail}" if detail else ""), flush=True)
        (work / CORE).write_text(original)
    print(f"{len(results['KILLED'])} killed by a named check, {len(results['SURVIVED'])} survived, "
          f"{len(results['INVALID'])} invalid (did not compile or timed out), {len(results['CRASHED'])} crashed outside the checks")
    failing = {k: v for k, v in results.items() if k != "KILLED" and v}
    if failing:
        sys.exit("mutation gate FAILED: " + "; ".join(f"{k.lower()}: {v}" for k, v in failing.items()))
    print(f"PASS dictation core mutation gate: {len(MUTANTS)} mutants, each killed by a named check, green baseline")
finally:
    shutil.rmtree(work, ignore_errors=True)
