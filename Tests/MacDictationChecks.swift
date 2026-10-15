import Foundation

@main struct MacDictationChecks {
    static func main() throws {
        var count = 0
        // 0.5.309 insert-target policy: the whole matrix against an independent statement of the rule.
        let roles: [String?] = [nil, "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea", "AXGroup", "AXButton"]
        let subroles: [String?] = [nil, "AXSecureTextField", "AXSearchField"]
        for trusted in [false, true] { for secureInput in [false, true] { for role in roles { for subrole in subroles {
            for settable in [false, true] { for ancestor in [false, true] { for own in [false, true] {
                let got = DictationInsertPolicy.refusal(trusted: trusted, secureInput: secureInput, role: role, subrole: subrole,
                                                        rangeSettable: settable, editableAncestor: ancestor, ownOverlay: own)
                let textRole = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role ?? "") || subrole == "AXSearchField"
                let want: DictationInsertPolicy.Refusal?
                if !trusted { want = .notTrusted }
                else if secureInput { want = .secureInput }
                else if subrole == "AXSecureTextField" { want = .secureField }
                else if own { want = .ownOverlay }
                else if role == nil { want = .noTextBox }
                else if textRole || settable || ancestor { want = nil }
                else { want = .noTextBox }
                precondition(got == want, "insert policy \(trusted) \(secureInput) \(role ?? "-") \(subrole ?? "-") \(settable) \(ancestor) \(own)")
                count += 1
            }}}
        }}}}
        // The cases Miles named, by name: a password field never gets text, the desktop gets the card.
        precondition(DictationInsertPolicy.refusal(trusted: true, secureInput: false, role: "AXTextField", subrole: "AXSecureTextField", rangeSettable: true, editableAncestor: false, ownOverlay: false) == .secureField)
        precondition(DictationInsertPolicy.refusal(trusted: true, secureInput: false, role: nil, subrole: nil, rangeSettable: false, editableAncestor: false, ownOverlay: false)?.title == "NO TEXT BOX · COPIED")
        precondition(DictationInsertPolicy.refusal(trusted: true, secureInput: false, role: "AXTextArea", subrole: nil, rangeSettable: false, editableAncestor: false, ownOverlay: false) == nil)
        count += 3
        for enabled in [false, true] { for busy in [false, true] {
            precondition(MacDictationPolicy.mayStart(enabled: enabled, busy: busy) == (enabled && !busy)); count += 1
        }}
        let pcm = Data(repeating: 9, count: MacDictationPolicy.maximumPCMBytes)
        let wav = try MacDictationPolicy.wav(pcm)
        precondition(wav.count == pcm.count + 44)
        precondition(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        precondition(wav[22] == 1 && wav[24] == 128 && wav[25] == 62 && wav[34] == 16)
        for invalid in [Data(), Data([1]), Data(repeating: 0, count: pcm.count + 2)] {
            do { _ = try MacDictationPolicy.wav(invalid); preconditionFailure("invalid WAV accepted") } catch { count += 1 }
        }
        let buffer = DictationPCMBuffer(); buffer.append(Data([1,2])); buffer.append(Data([3,4]))
        let accumulated = try buffer.result(); precondition(accumulated == Data([1,2,3,4]))
        buffer.fail("unplugged"); precondition(buffer.failureMessage() == "unplugged"); count += 1
        do { _ = try buffer.result(); preconditionFailure("input failure ignored") } catch { count += 1 }
        let bounded = DictationPCMBuffer(); bounded.append(pcm); bounded.append(Data([1,2]))
        let capped = try bounded.result(); precondition(capped.count == MacDictationPolicy.maximumPCMBytes); count += 1
        precondition(buffer.snapshot(maximumBytes: 3) == Data([3,4])); count += 1
        precondition(buffer.currentLevel() > 0); count += 1
        // 0.5.309: the level is the buffer's RMS (0.5 and 0 -> 0.354), not its peak (0.5), so the dB meter reads speech energy.
        let rms = DictationPCMBuffer(); rms.append(Data([0x00, 0x40, 0x00, 0x00]))
        precondition(abs(rms.currentLevel() - (0.125).squareRoot()) < 1e-9, "level is RMS"); count += 1
        // Any-key triggers (0.5.305): Fn alone, function keys alone, a modifier plus a key; never plain typing.
        func expect(_ value: Bool, _ name: String) { precondition(value, name); count += 1 }
        let C = DictationTrigger.command, O = DictationTrigger.option, S = DictationTrigger.shift, K = DictationTrigger.control
        expect(DictationTrigger.keys(49, modifiers: K | O) == .keys(keyCode: 49, modifiers: K | O), "modifier plus key accepted")
        expect(DictationTrigger.keys(0, modifiers: 0) == nil, "a bare letter would capture typing")
        expect(DictationTrigger.keys(0, modifiers: S) == nil, "Shift alone does not make a letter safe")
        expect(DictationTrigger.keys(105, modifiers: 0) == .keys(keyCode: 105, modifiers: 0), "F13 alone accepted")
        expect(DictationTrigger.keys(122, modifiers: S) != nil, "Shift-F1 accepted")
        expect(DictationTrigger.keys(49, modifiers: C | 0x40000) == .keys(keyCode: 49, modifiers: C), "non-Carbon bits stripped")
        expect(DictationTrigger.modifier(63)?.isFn == true, "Fn is a lone-modifier trigger")
        expect(DictationTrigger.modifier(49) == nil, "Space is not a modifier key")
        expect(DictationTrigger.modifier(54)?.usesKeyMonitor == true && DictationTrigger.keys(105, modifiers: 0)?.usesKeyMonitor == false, "only lone modifiers need the key monitor")
        for trigger in [DictationTrigger.modifier(keyCode: 63), .modifier(keyCode: 61), .keys(keyCode: 49, modifiers: K | O), .keys(keyCode: 105, modifiers: 0)] {
            let s = trigger.stored
            expect(DictationTrigger.load(kind: s.kind, key: s.key, modifiers: s.modifiers) == trigger, "stored trigger round-trips")
        }
        expect(DictationTrigger.load(kind: nil, key: 49, modifiers: Int(K | O)) == .keys(keyCode: 49, modifiers: K | O), "pre-0.5.305 combo still loads")
        expect(DictationTrigger.load(kind: "modifier", key: 49, modifiers: 0) == nil, "unknown lone key refused")
        expect(DictationTrigger.load(kind: nil, key: -1, modifiers: 0) == nil, "negative stored key refused")
        let fnDown: UInt64 = 0x800000, rightCmd: UInt64 = 0x10 | 0x100000, leftCmd: UInt64 = 0x08 | 0x100000
        var fn = LoneModifierTracker(keyCode: 63)!
        expect(fn.flagsChanged(keyCode: 63, flags: fnDown) == .pressed, "Fn press starts")
        expect(fn.flagsChanged(keyCode: 63, flags: 0) == .released, "Fn release finishes")
        expect(fn.flagsChanged(keyCode: 63, flags: fnDown) == .pressed && fn.keyDown() == .chord, "Fn+arrow is a chord")
        expect(fn.keyDown() == nil, "a chord reports once")
        expect(fn.flagsChanged(keyCode: 63, flags: 0) == nil, "release after a chord never dictates")
        expect(fn.flagsChanged(keyCode: 55, flags: leftCmd) == nil && fn.flagsChanged(keyCode: 63, flags: leftCmd | fnDown) == nil, "Fn pressed while Command is held is not lone")
        expect(fn.flagsChanged(keyCode: 63, flags: leftCmd) == nil && fn.flagsChanged(keyCode: 55, flags: 0) == nil, "nothing latched after a held-Command press")
        expect(fn.flagsChanged(keyCode: 63, flags: fnDown) == .pressed && fn.flagsChanged(keyCode: 56, flags: fnDown | 0x02 | 0x20000) == .chord, "Shift joining Fn is a chord")
        _ = fn.flagsChanged(keyCode: 56, flags: fnDown); _ = fn.flagsChanged(keyCode: 63, flags: 0)
        expect(fn.flagsChanged(keyCode: 63, flags: fnDown | 0x10000) == .pressed, "Caps Lock does not spoil a press")
        fn.reset(); expect(!fn.down && fn.flagsChanged(keyCode: 63, flags: 0) == nil, "reset forgets a held press")
        var right = LoneModifierTracker(keyCode: 54)!
        expect(right.flagsChanged(keyCode: 55, flags: leftCmd) == nil, "Left Command never fires a Right Command trigger")
        _ = right.flagsChanged(keyCode: 55, flags: 0)
        expect(right.flagsChanged(keyCode: 54, flags: rightCmd) == .pressed && right.flagsChanged(keyCode: 54, flags: 0) == .released, "Right Command alone fires")
        expect(right.flagsChanged(keyCode: 54, flags: rightCmd) == .pressed && right.flagsChanged(keyCode: 54, flags: rightCmd) == nil, "a repeated down is not a second press")
        _ = right.flagsChanged(keyCode: 54, flags: 0)
        var both = LoneModifierTracker(keyCode: 54)!
        expect(both.flagsChanged(keyCode: 55, flags: leftCmd) == nil && both.flagsChanged(keyCode: 54, flags: leftCmd | 0x10) == nil, "Right Command while Left Command is held is a chord")
        expect(both.flagsChanged(keyCode: 54, flags: leftCmd) == nil && both.flagsChanged(keyCode: 55, flags: 0) == nil, "releasing that chord never dictates")
        expect(both.flagsChanged(keyCode: 54, flags: rightCmd) == .pressed, "Right Command alone fires again after the chord")
        expect(DictationTrigger.alone(63, flags: 0x800000) && !DictationTrigger.alone(63, flags: 0x800000 | leftCmd) && !DictationTrigger.alone(49, flags: 0), "recorder uses the same lone rule")
        expect(LoneModifierTracker(keyCode: 49) == nil, "tracker only for modifier keys")
        // dB meter (0.5.309): -50..-10 dBFS onto 0..1, fast rise, slow fall.
        expect(DictationLevelMeter.normalized(dBFS: -50) == 0 && DictationLevelMeter.normalized(dBFS: -10) == 1, "meter endpoints")
        expect(abs(DictationLevelMeter.normalized(dBFS: -30) - 0.5) < 1e-9, "meter midpoint is -30 dBFS")
        expect(DictationLevelMeter.normalized(dBFS: -80) == 0 && DictationLevelMeter.normalized(dBFS: 0) == 1, "meter clamps")
        expect(abs(DictationLevelMeter.dBFS(rms: 0.1) - -20) < 1e-9 && DictationLevelMeter.dBFS(rms: 0) < -100, "rms to dBFS")
        expect(DictationLevelMeter.normalized(dBFS: DictationLevelMeter.dBFS(rms: 0.01)) > 0.2, "quiet speech (-40 dBFS) moves the bars")
        var meter = DictationLevelMeter()
        expect(abs(meter.update(rms: 0.1) - 0.75) < 1e-9, "attack is immediate")
        let fell = meter.update(rms: 0)
        expect(fell > 0.6 && fell < 0.75, "release is slow: one tick keeps most of the level")
        var falling = meter; for _ in 0..<60 { _ = falling.update(rms: 0) }
        expect(falling.level < 0.01, "silence settles")
        expect(abs(meter.update(rms: 0.1) - 0.75) < 1e-9, "a new peak jumps straight back up")
        // Recent dictations: newest first, last 50, private atomic file, round trip.
        func record(_ n: Int, app: String? = "Slack") -> DictationRecord {
            DictationRecord(id: UUID(), text: "Line \(n) of text\nsecond line", createdAt: Date(timeIntervalSince1970: 1_760_000_000 + Double(n)), insertedApp: app)
        }
        var history: [DictationRecord] = []
        for n in 0..<55 { history = DictationHistory.adding(record(n), to: history) }
        expect(history.count == DictationHistory.limit && history.first?.text.hasPrefix("Line 54") == true && history.last?.text.hasPrefix("Line 5 ") == true, "bounded to 50, newest first")
        let again = DictationHistory.adding(history[3], to: history)
        expect(again.count == 50 && again.first?.id == history[3].id && Set(again.map(\.id)).count == 50, "re-adding moves to the top, never duplicates")
        let one = record(1)
        expect(one.wordCount == 6 && one.firstLine == "Line 1 of text", "word count and first line")
        expect(one.metaLine(time: "6:02 PM") == "6:02 PM · 6 words · inserted · Slack", "row meta (mock 05)")
        expect(record(2, app: nil).outcomeLabel == "copied, no text box", "copied label")
        var pasted = record(3); pasted.pasted = true
        expect(pasted.outcomeLabel == "pasted · Slack", "a ⌘V insert says pasted")
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cos-dictation-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("COS Control/dictation-history.json")
        expect(DictationHistory.load(from: file).isEmpty, "a missing file is an empty history")
        try DictationHistory.save(history.reversed() + [pasted], to: file)
        let loaded = DictationHistory.load(from: file)
        expect(loaded.count == 50 && loaded == DictationHistory.ordered(history.reversed() + [pasted]), "round trip keeps order and bound")
        expect(loaded.first?.id == history.first?.id, "the file is newest first however it was handed in")
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        expect(mode == 0o600, "history file is 0600")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path).filter { $0.hasSuffix(".tmp") }
        expect(leftovers.isEmpty, "no temp file left behind")
        try Data("not json".utf8).write(to: file)
        expect(DictationHistory.load(from: file).isEmpty, "a corrupt file reads as empty, never a crash")
        // The 20 s card: hover pauses, leaving resumes where it stopped.
        let t0 = Date(timeIntervalSince1970: 1_000)
        var countdown = DictationCountdown(start: t0)
        expect(countdown.fraction(at: t0) == 1 && !countdown.expired(at: t0.addingTimeInterval(19.9)), "fresh card")
        expect(countdown.expired(at: t0.addingTimeInterval(20)), "folds at 20 s")
        countdown.pause(at: t0.addingTimeInterval(5))
        expect(countdown.paused && countdown.remaining(at: t0.addingTimeInterval(500)) == 15, "hover pauses")
        countdown.pause(at: t0.addingTimeInterval(600))
        expect(countdown.remaining(at: t0.addingTimeInterval(700)) == 15, "a second pause does not spend time")
        countdown.resume(at: t0.addingTimeInterval(100))
        expect(countdown.remaining(at: t0.addingTimeInterval(110)) == 5 && countdown.expired(at: t0.addingTimeInterval(115)), "leaving resumes")
        countdown.resume(at: t0.addingTimeInterval(112))
        expect(countdown.remaining(at: t0.addingTimeInterval(110)) == 5, "a second resume does not restart the clock")
        // Fix a word: tap a word, widen to a phrase, punctuation trimmed for the dictionary.
        let words = DictationFixText.tokens("make Whisper, really \"nice\" today")
        expect(words == ["make", "Whisper,", "really", "\"nice\"", "today"], "tokens keep the text as shown")
        expect(DictationFixText.heard(words, 1...1) == "Whisper" && DictationFixText.heard(words, 1...3) == "Whisper, really \"nice", "heard trims the phrase ends")
        expect(DictationFixText.heard(words, 3...3) == "nice" && DictationFixText.heard(words, 4...9) == "", "quotes trimmed; out of range is empty")
        expect(DictationFixText.select(2, current: nil) == 2...2, "first tap selects")
        expect(DictationFixText.select(2, current: 2...2) == nil, "tapping the lone word clears")
        expect(DictationFixText.select(4, current: 2...2) == 2...4 && DictationFixText.select(0, current: 2...4) == 0...4, "a tap outside widens")
        expect(DictationFixText.select(3, current: 2...4) == 3...3, "a tap inside a phrase starts over")
        // Where and when (mock 06).
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = Date(timeIntervalSince1970: 1_760_571_000) // 2025-10-15 18:30 CDT
        expect(DictionaryLabels.line(source: "dictation", at: now.addingTimeInterval(-20), now: now, calendar: calendar) == "dictation · now", "now")
        expect(DictionaryLabels.line(source: "g2", at: now.addingTimeInterval(-86_400 * 6), now: now, calendar: calendar) == "G2 · Oct 9", "older day")
        expect(DictionaryLabels.line(source: "meeting", at: now.addingTimeInterval(-3_600), now: now, calendar: calendar) == "meeting · 5:30 PM", "earlier today")
        expect(DictionaryLabels.line(source: "manual", at: nil, now: now, calendar: calendar) == "added", "no time")
        // The pill hands the ledger back the moment it hides.
        expect(!DictationPill.hidden.replacesLedger && DictationPill.transcribing.replacesLedger && DictationPill.listening(since: now).replacesLedger, "pill owns the ledger only while showing")
        expect(DictationPill.inserted(app: "Slack", pasted: false).label == "✓ INSERTED · SLACK" && DictationPill.inserted(app: "Notes", pasted: true).label == "✓ PASTED · NOTES", "flash label")
        expect(DictationPill.clock(4.9) == "0:04" && DictationPill.clock(65) == "1:05" && DictationPill.clock(-1) == "0:00", "elapsed clock")
        print("PASS Mac dictation: \(count) policy checks; insert-target matrix, dB meter, recent dictations file, card countdown, fix-a-word selection, bounded audio, PCM16 WAV, device failure, any-key triggers")
    }
}
