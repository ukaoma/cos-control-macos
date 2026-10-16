import CoreGraphics
import Foundation

/// 0.5.312: a pasteboard the clipboard-restore checks can watch.
final class FakeDictationBoard: DictationPasteboardAccess {
    var changeCount = 0
    var stored: [DictationClipboardItem] = []
    var lastMarkers: [String] = []
    func itemTypes() -> [[String]] { stored.map { $0.entries.map(\.type) } }
    func data(item: Int, type: String) -> Data? { stored[item].entries.first { $0.type == type }?.data }
    func replace(with items: [DictationClipboardItem]) -> Bool { stored = items; changeCount += 1; return true }
    func writeTranscript(_ text: String, markerTypes: [String]) -> Bool {
        lastMarkers = markerTypes
        stored = [DictationClipboardItem(entries: [.init(type: "public.utf8-plain-text", data: Data(text.utf8))] + markerTypes.map { .init(type: $0, data: Data()) })]
        changeCount += 1; return true
    }
}

@main struct MacDictationChecks {
    static func main() throws {
        var count = 0
        // 0.5.310 insert-target policy: hand-written rows, each with its own expected answer (not a re-derivation).
        typealias R = DictationInsertPolicy.Refusal
        let rows: [(String, Bool, Bool, String?, Bool, Bool, Bool, Bool, Bool, R?)] = [
            // name, trusted, secureInput, subrole, focused, textSettable, ancestor, pasteApp, ownOverlay, expected
            ("Accessibility off", false, false, nil, true, true, false, false, false, .notTrusted),
            ("Accessibility off beats secure input", false, true, "AXSecureTextField", true, true, false, false, false, .notTrusted),
            ("another app holds secure input", true, true, nil, true, true, false, false, false, .secureInput),
            ("a real password field", true, false, "AXSecureTextField", true, true, false, false, false, .secureField),
            ("a password field, secure input on too", true, true, "AXSecureTextField", true, true, false, false, false, .secureField),
            ("COS's own pet holds the keyboard", true, false, nil, true, true, false, false, true, .ownOverlay),
            ("own panel even in a terminal-like app", true, false, nil, true, false, false, true, true, .ownOverlay),
            ("an editable text field", true, false, nil, true, true, false, false, false, nil),
            ("a web editor via its editable ancestor", true, false, nil, true, false, true, false, false, nil),
            ("a read-only AXTextArea in an ordinary app", true, false, nil, true, false, false, false, false, .noTextBox),
            ("iTerm2's read-only AXTextArea gets ⌘V", true, false, nil, true, false, false, true, false, nil),
            ("Finder or the desktop", true, false, nil, false, false, false, false, false, .noTextBox),
            ("Electron with no focused element gets ⌘V", true, false, nil, false, false, false, true, false, nil),
            ("settable but nothing focused is not a target", true, false, nil, false, true, false, false, false, .noTextBox),
        ]
        for (name, trusted, secureInput, subrole, focused, settable, ancestor, pasteApp, own, expected) in rows {
            let got = DictationInsertPolicy.refusal(trusted: trusted, secureInput: secureInput, subrole: subrole, focused: focused,
                                                    textSettable: settable, editableAncestor: ancestor, pasteApp: pasteApp, ownOverlay: own)
            precondition(got == expected, "insert policy: \(name)"); count += 1
        }
        precondition(R.secureInput.title == "SECURE INPUT ON · COPIED" && R.secureField.title == "PASSWORD FIELD · COPIED"
                     && !R.allCases.contains { $0.title.contains("PRESS ⌘V") }, "distinct card titles; no refusal tells you to press ⌘V"); count += 1
        precondition(Set(R.allCases.map(\.historyLabel)).count == R.allCases.count - 1, "every reason but ownOverlay/noTextBox reads differently"); count += 1

        // 0.5.310 measured delivery (Miles 20:07: iTerm2 flashed ✓ INSERTED and nothing landed).
        func snap(_ n: Int?, _ location: Int?, _ length: Int?) -> DictationFieldSnapshot { DictationFieldSnapshot(characters: n, location: location, length: length) }
        let none = DictationFieldSnapshot()
        let field = snap(100, 100, 0)
        func step(_ route: DictationRoute, _ baseline: DictationFieldSnapshot, setter: Bool = true, after: DictationFieldSnapshot,
                  final: Bool, pasted: Bool = false, afterPaste: DictationFieldSnapshot = DictationFieldSnapshot()) -> DictationDecision {
            DictationDelivery.decide(route: route, baseline: baseline, setterSucceeded: setter, afterSetter: after, finalPoll: final,
                                     pasted: pasted, afterPaste: afterPaste, count: 5, app: "iTerm2")
        }
        precondition(step(.accessibility, field, after: field, final: false) == .wait, "setter said success, nothing moved yet: wait"); count += 1
        precondition(step(.accessibility, field, after: field, final: true) == .paste, "iTerm2 shape: success but unchanged after 300 ms → ⌘V, never ✓"); count += 1
        precondition(step(.accessibility, field, setter: false, after: field, final: false) == .paste, "a failed set goes to ⌘V at once"); count += 1
        precondition(step(.accessibility, snap(nil, 10, 0), after: snap(nil, 15, 0), final: false) == .done(.inserted(app: "iTerm2", viaPaste: false)), "landed via the caret"); count += 1
        precondition(step(.accessibility, snap(100, 10, 3), after: snap(102, 99, 7), final: false) == .done(.inserted(app: "iTerm2", viaPaste: false)), "landed via the count"); count += 1
        precondition(step(.accessibility, field, after: snap(130, 0, 0), final: false) == .done(.inserted(app: "iTerm2", viaPaste: false)), "any other change counts and is never followed by ⌘V"); count += 1
        precondition(step(.accessibility, field, after: none, final: false) == .wait && step(.accessibility, field, after: none, final: true) == .done(.unconfirmed(app: "iTerm2", viaPaste: false)),
                     "a field that stops answering is unconfirmed, never pasted over"); count += 1
        precondition(step(.accessibility, none, after: none, final: true) == .paste, "an unreadable baseline never tries AX"); count += 1
        precondition(step(.paste, field, after: none, final: true) == .paste, "the paste route pastes"); count += 1
        precondition(step(.paste, field, after: none, final: true, pasted: true, afterPaste: snap(105, 105, 0)) == .done(.inserted(app: "iTerm2", viaPaste: true)), "⌘V verified"); count += 1
        precondition(step(.paste, field, after: none, final: true, pasted: true, afterPaste: none) == .done(.unconfirmed(app: "iTerm2", viaPaste: true)), "⌘V unverifiable"); count += 1
        // A terminal whose counters do not move after ⌘V: the paste may still land, so it reads PASTED, never "press ⌘V".
        precondition(step(.paste, field, after: none, final: true, pasted: true, afterPaste: field) == .done(.unconfirmed(app: "iTerm2", viaPaste: true)), "⌘V that moved nothing is PASTED"); count += 1
        precondition(DictationDeliveryOutcome.unconfirmed(app: "iTerm2", viaPaste: true).flash?.label == "PASTED · ⌘V SENT"
                     && DictationDeliveryOutcome.unconfirmed(app: "iTerm2", viaPaste: true).delivery == .unconfirmed(app: "iTerm2", viaPaste: true), "and history says pasted (unconfirmed)"); count += 1
        precondition(step(.ownWindow, field, after: field, final: true) == .done(.refused(.noTextBox)), "COS's own window that did not take it"); count += 1
        precondition(step(.ownWindow, field, after: snap(105, 105, 0), final: true) == .done(.inserted(app: "iTerm2", viaPaste: false)), "COS's own window measured"); count += 1
        precondition(DictationDelivery.verdict(baseline: snap(100, 10, 5), after: snap(100, 10, 5), count: 5) == .unchanged, "same-length replace with no change is not landed"); count += 1
        precondition(DictationDelivery.verdict(baseline: snap(100, 10, 0), after: snap(105, 15, 0), count: 5) == .landed
                     && DictationDelivery.verdict(baseline: snap(100, 10, 0), after: snap(101, 3, 0), count: 5) == .changed
                     && DictationDelivery.verdict(baseline: snap(nil, 10, 0), after: snap(nil, 15, 0), count: 5) == .landed
                     && DictationDelivery.verdict(baseline: snap(100, 10, 2), after: snap(103, 0, 0), count: 5) == .landed
                     && DictationDelivery.verdict(baseline: none, after: field, count: 5) == .unreadable, "verdicts"); count += 1
        precondition(DictationDelivery.route(isOwnApp: false, terminal: true, baselineReadable: true) == .paste
                     && DictationDelivery.route(isOwnApp: false, terminal: false, baselineReadable: false) == .paste
                     && DictationDelivery.route(isOwnApp: false, terminal: false, baselineReadable: true) == .accessibility
                     && DictationDelivery.route(isOwnApp: true, terminal: true, baselineReadable: false) == .ownWindow, "routes"); count += 1
        let stripped = DictationDelivery.terminalText("ls -la\r\nrm old\nnext\rlast\u{2028}end")
        precondition(stripped == "ls -la rm old next last end" && !stripped.contains("\n") && !stripped.contains("\r"), "terminals never get a line break"); count += 1
        precondition(DictationDeliveryOutcome.inserted(app: "iTerm2", viaPaste: true).flash == .flash(label: "✓ INSERTED · ITERM2", confirmed: true), "✓ only for a measured change"); count += 1
        let unverified = DictationDeliveryOutcome.unconfirmed(app: "iTerm2", viaPaste: true).flash
        precondition(unverified == .flash(label: "PASTED · ⌘V SENT", confirmed: false) && unverified?.label.contains("✓") == false, "unconfirmed ⌘V has no ✓"); count += 1
        precondition(DictationDeliveryOutcome.unconfirmed(app: "Notes", viaPaste: false).flash?.label.contains("✓") == false
                     && DictationDeliveryOutcome.refused(.noTextBox).flash == nil, "unconfirmed AX has no ✓; a refusal shows the card"); count += 1
        precondition(KnownApps.isTerminal("com.googlecode.iterm2") && KnownApps.isTerminal("com.apple.Terminal") && KnownApps.isTerminal("dev.warp.Warp-Preview")
                     && KnownApps.isTerminal("com.mitchellh.ghostty") && KnownApps.isTerminal("net.kovidgoyal.kitty") && KnownApps.isTerminal("io.alacritty")
                     && KnownApps.isTerminal("org.alacritty") && KnownApps.isTerminal("com.github.wez.wezterm")
                     && !KnownApps.isTerminal("com.apple.TextEdit") && !KnownApps.isTerminal(nil), "known terminals"); count += 1
        precondition(KnownApps.isChromiumFamily(frameworks: ["Sparkle.framework", "Electron Framework.framework"])
                     && KnownApps.isChromiumFamily(frameworks: ["Google Chrome Framework.framework"])
                     && !KnownApps.isChromiumFamily(frameworks: ["Sparkle.framework", "Squirrel.framework"]), "Electron and Chromium detected"); count += 1
        let dvorak: [UInt16: String] = [9: "k", 47: "v", 0: "a"]
        precondition(DictationDelivery.keyCode(for: "v") { $0 == 9 ? "v" : nil } == 9
                     && DictationDelivery.keyCode(for: "v") { dvorak[$0] } == 47
                     && DictationDelivery.keyCode(for: "v") { _ in "x" } == nil, "⌘V on the current layout's V"); count += 1
        precondition(!DictationDelivery.modifiersHeld(isDown: { _ in false }), "nothing down: paste"); count += 1
        for code: UInt16 in [55, 54, 58, 61, 59, 62, 56, 60] {
            precondition(DictationDelivery.modifiersHeld(isDown: { $0 == code }), "left/right ⌘ ⌥ ⌃ ⇧ \(code) held blocks the paste"); count += 1
        }
        // Fn (63), Caps Lock (57) and F17 (64), Miles's shortcut, never block it.
        for code: UInt16 in [63, 57, 64] {
            precondition(!DictationDelivery.modifiersHeld(isDown: { $0 == code }), "key \(code) does not block the paste"); count += 1
        }
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
        // 0.5.313 (Miles 2026-10-15): clicking or dragging while holding the key must not stop listening. A click right
        // after the press is still ⌥-click / ⌘-click; boundaries derive from the shipped window, never a restated number.
        let window = LoneModifierTracker.clickChordWindow
        expect(window > 0 && window <= 1, "click-chord window is a fraction of a second")
        var talk = LoneModifierTracker(keyCode: 63)!
        expect(talk.flagsChanged(keyCode: 63, flags: fnDown, at: 100) == .pressed, "held Fn starts at t=100")
        expect(talk.pointerDown(at: 100 + window + 0.5) == nil, "a click while talking is ignored")
        expect(talk.pointerDown(at: 100 + window * 10) == nil, "a drag later is ignored too")
        expect(talk.flagsChanged(keyCode: 63, flags: 0, at: 105) == .released, "release after clicking still finishes the dictation")
        var optClick = LoneModifierTracker(keyCode: 58)!
        expect(optClick.flagsChanged(keyCode: 58, flags: 0x20 | 0x80000, at: 50) == .pressed, "Option press")
        expect(optClick.pointerDown(at: 50 + window / 2) == .chord, "⌥-click right after the press is a chord")
        expect(optClick.pointerDown(at: 50 + window / 2) == nil && optClick.flagsChanged(keyCode: 58, flags: 0, at: 51) == nil, "that chord never dictates")
        var edge = LoneModifierTracker(keyCode: 63)!
        // Press at 0 so the click at `window` is exactly the window in Double: 7 + 0.4 - 7 is 0.40000000000000036, which
        // passes `<` and `<=` alike, so the old edge check could not tell an exclusive window from an inclusive one.
        _ = edge.flagsChanged(keyCode: 63, flags: fnDown, at: 0)
        expect(edge.pointerDown(at: window) == nil, "a click exactly at the window edge is talking, not a chord")
        var inside = LoneModifierTracker(keyCode: 63)!
        _ = inside.flagsChanged(keyCode: 63, flags: fnDown, at: 0)
        expect(inside.pointerDown(at: window.nextDown) == .chord, "a click just inside the window is still a chord")
        var idle = LoneModifierTracker(keyCode: 63)!
        expect(idle.pointerDown(at: 1) == nil, "a click with the key up is nothing")
        _ = idle.flagsChanged(keyCode: 63, flags: fnDown, at: 1000)
        expect(idle.pointerDown(at: 1000 + window / 2) == .chord, "the window runs from THIS press, not the first")
        _ = idle.flagsChanged(keyCode: 63, flags: 0, at: 1001)
        _ = idle.flagsChanged(keyCode: 63, flags: fnDown, at: 2000)
        expect(idle.keyDown() == .chord, "a key while talking is still a chord (Fn+arrow), however late")
        // 0.5.313: an interrupted dictation keeps what was said once there is a second of it (16 kHz mono Int16).
        let second = 16_000 * 2
        expect(MacDictationPolicy.salvageMinimumBytes == second, "salvage threshold is one second of dictation audio")
        expect(MacDictationPolicy.salvages(pcmBytes: second) && MacDictationPolicy.salvages(pcmBytes: MacDictationPolicy.maximumPCMBytes), "a second or more is kept")
        expect(!MacDictationPolicy.salvages(pcmBytes: second - 2) && !MacDictationPolicy.salvages(pcmBytes: 0), "under a second (a shortcut combination) is dropped")
        expect(DictationInsertPolicy.Refusal.interrupted.title == "INTERRUPTED · COPIED" && DictationInsertPolicy.Refusal.interrupted.note.contains("⌘V"), "interrupted card says it was copied and how to paste")
        expect(DictationClipboard.use(for: .refused(.interrupted)) == .keepForCard, "an interrupted transcript stays on the clipboard")
        let cut = DictationRecord(id: UUID(), text: "half a thought", createdAt: Date(timeIntervalSince1970: 0), delivery: .copied(.interrupted))
        if let data = try? JSONEncoder().encode(cut), let back = try? JSONDecoder().decode(DictationRecord.self, from: data) {
            expect(back.delivery == .copied(.interrupted) && back.outcomeLabel == "copied, interrupted", "interrupted round-trips in history")
        } else { expect(false, "interrupted record encodes and decodes") }
        // 0.5.312 listening bars, end to end through the path the app runs: an Int16 microphone buffer → DictationPCMBuffer
        // RMS → DictationLevelMeter (50 ms ticks) → the feed's last eleven levels → DictationBars heights.
        // Field bug 2026-10-15 21:16: loud speech on Miles's AT2020USB+ (about -45 dBFS RMS) drew flat dots.
        expect(abs(DictationLevelMeter.dBFS(rms: 0.1) - -20) < 1e-9 && DictationLevelMeter.dBFS(rms: 0) < -100, "rms to dBFS")
        func tone(_ dbfs: Double) -> Data {
            guard dbfs > -150 else { return Data(count: 683 * 2) }
            let amplitude = pow(10, dbfs / 20) * 2.0.squareRoot() * 32767
            var data = Data()
            for i in 0..<683 {
                var sample = Int16(clamping: Int((amplitude * sin(2 * Double.pi * 220 * Double(i) / 16_000)).rounded())).littleEndian
                withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
            }
            return data
        }
        func bars(_ ticks: [Double]) -> (heights: [Double], meter: DictationLevelMeter) {
            var meter = DictationLevelMeter()
            var history = [Double](repeating: 0, count: DictationBars.count)
            for dbfs in ticks {
                let buffer = DictationPCMBuffer(); buffer.append(tone(dbfs))
                history.removeFirst(); history.append(meter.update(rms: buffer.currentLevel()))
            }
            return (DictationBars.heights(history), meter)
        }
        func mean(_ h: [Double]) -> Double { h.reduce(0, +) / Double(h.count) }
        let tall = 0.6 * DictationBars.maximum
        let room = [Double](repeating: -65, count: 20)
        let quietMic = bars(room + (0..<20).map { $0 % 2 == 0 ? -45 : -50 })
        expect(quietMic.heights[5] > tall && mean(quietMic.heights) > tall, "loud speech on a quiet USB mic (-45 dBFS) swings the bars past 60% (was 30%)")
        for speech in [-20.0, -6.0] {
            let fromStart = bars([Double](repeating: speech, count: 20))
            expect(fromStart.heights[5] > tall && mean(fromStart.heights) > tall, "\(speech) dBFS from the first tick is tall")
            let afterRoom = bars(room + [Double](repeating: speech, count: 20))
            expect(mean(afterRoom.heights) > tall, "\(speech) dBFS after room noise is tall")
        }
        for silence in [[Double](repeating: -65, count: 40), [Double](repeating: -55, count: 40), [Double](repeating: -200, count: 40)] {
            expect(bars(silence).heights.allSatisfy { $0 == DictationBars.minimum }, "silence (\(silence[0]) dBFS) stays at the floor")
        }
        // A hum 4 dB over the room (under the 6 dB gate) is not speech; without the gate it would light 20% bars.
        let hum = bars(room + [Double](repeating: -65 + DictationLevelMeter.gateDB - 2, count: 20))
        expect(hum.heights.allSatisfy { $0 == DictationBars.minimum }, "noise under the gate above the floor stays at the floor")
        let quieted = bars(room + [Double](repeating: -20, count: 10) + [Double](repeating: -65, count: 40))
        expect(quieted.heights.allSatisfy { $0 < DictationBars.minimum + 0.5 }, "the bars fall back to the floor when speech stops")
        let firstTick = bars([-40])
        expect(firstTick.meter.floorDB == -50 && firstTick.heights[5] > DictationBars.minimum, "the floor starts no higher than -50 dBFS")
        let falls = bars([-48, -70])
        expect(abs((falls.meter.floorDB ?? 0) - -70) < 0.5, "the floor falls instantly to a quieter room")
        var held = DictationLevelMeter(); let peak = held.update(rms: 0.1); let afterOne = held.update(rms: 0.0001)
        expect(peak == 1 && afterOne > 0.8 && afterOne < 1, "fast rise, slow fall: one quiet tick keeps most of the level")
        expect(DictationBars.heights([1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1])[5] == DictationBars.maximum && DictationBars.heights([])[0] == DictationBars.minimum,
               "bar heights span minimum to maximum")
        // Dictation history: newest first, private atomic file, round trip (bounded by retention and 5,000 since 0.5.312).
        func record(_ n: Int, _ delivery: DictationRecord.Delivery = .inserted(app: "Slack")) -> DictationRecord {
            DictationRecord(id: UUID(), text: "Line \(n) of text\nsecond line", createdAt: Date(timeIntervalSince1970: 1_760_000_000 + Double(n)), delivery: delivery)
        }
        var history: [DictationRecord] = []
        let kinds: [DictationRecord.Delivery] = [.inserted(app: "Slack"), .unconfirmed(app: "iTerm2", viaPaste: true), .copied(.secureInput)]
        for n in 0..<55 { history = DictationHistory.adding(record(n, kinds[n % 3]), to: history) }
        expect(history.count == 55 && history.first?.text.hasPrefix("Line 54") == true && history.last?.text.hasPrefix("Line 0 ") == true, "newest first, nothing lost under the cap")
        let again = DictationHistory.adding(history[3], to: history)
        expect(again.count == 55 && again.first?.id == history[3].id && Set(again.map(\.id)).count == 55, "re-adding moves to the top, never duplicates")
        let one = record(1)
        expect(one.wordCount == 6 && one.firstLine == "Line 1 of text", "word count and first line")
        expect(one.metaLine(time: "6:02 PM") == "6:02 PM · 6 words · inserted · Slack", "row meta (mock 05)")
        expect(record(2, .copied(.noTextBox)).outcomeLabel == "copied, no text box" && record(2, .copied(.secureField)).outcomeLabel == "copied, password field", "copied says why")
        let pasted = record(3, .unconfirmed(app: "iTerm2", viaPaste: true))
        expect(pasted.outcomeLabel == "pasted (unconfirmed) · iTerm2" && record(4, .unconfirmed(app: "Notes", viaPaste: false)).outcomeLabel == "sent (unconfirmed) · Notes", "unconfirmed is said")
        expect(DictationDeliveryOutcome.refused(.keysHeld).delivery == .copied(.keysHeld) && DictationDeliveryOutcome.inserted(app: "Slack", viaPaste: true).delivery == .inserted(app: "Slack"), "history keeps the honest outcome")
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cos-dictation-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("COS Control/dictation-history.json")
        expect(DictationHistory.load(from: file).isEmpty, "a missing file is an empty history")
        try DictationHistory.save(history.reversed() + [pasted], to: file)
        let loaded = DictationHistory.load(from: file)
        expect(loaded.count == 56 && loaded == DictationHistory.ordered(history.reversed() + [pasted]), "round trip keeps order")
        expect(loaded.first?.id == history.first?.id, "the file is newest first however it was handed in")
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        expect(mode == 0o600, "history file is 0600")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path).filter { $0.hasSuffix(".tmp") }
        expect(leftovers.isEmpty, "no temp file left behind")
        let reread = DictationHistory.loadOrQuarantine(from: file, now: Date())
        expect(reread.records == loaded && reread.movedTo == nil && reread.writable, "a good file is read, never moved")
        expect(loaded.contains(where: { $0.delivery == .copied(.secureInput) }) && loaded.contains(where: { $0.delivery == .unconfirmed(app: "iTerm2", viaPaste: true) })
               && loaded.contains(where: { $0.delivery == .inserted(app: "Slack") }), "every kind of delivery round-trips")
        expect(DictationHistory.removing(loaded[1].id, from: loaded).count == 55 && !DictationHistory.removing(loaded[1].id, from: loaded).contains(loaded[1]), "delete one")
        do { // own scope: names here must not collide with earlier sections
        // 0.5.312 retention (Miles 21:40): by age, then the 5,000 cap; "Don't keep" writes nothing.
        let now = Date(timeIntervalSince1970: 1_760_000_000 + 100 * 86_400)
        func aged(_ days: Double) -> DictationRecord { DictationRecord(id: UUID(), text: "aged \(days)", createdAt: now.addingTimeInterval(-days * 86_400), delivery: .inserted(app: "Notes")) }
        let ages = [aged(1), aged(6.9), aged(8), aged(29), aged(31), aged(89), aged(91), aged(400)]
        let byAge = { (r: DictationRetention) in DictationHistory.pruned(ages, retention: r, now: now).map(\.text) }
        expect(byAge(.week) == ["aged 1.0", "aged 6.9"] && byAge(.month) == ["aged 1.0", "aged 6.9", "aged 8.0", "aged 29.0"]
               && byAge(.quarter).count == 6 && byAge(.forever).count == 8, "kept by age, newest first")
        let many = (0..<(DictationHistory.cap + 7)).map { DictationRecord(id: UUID(), text: "n\($0)", createdAt: now.addingTimeInterval(-Double($0)), delivery: .inserted(app: "Notes")) }
        let capped = DictationHistory.pruned(many, retention: .forever, now: now)
        expect(capped.count == DictationHistory.cap && capped.first?.text == "n0" && capped.last?.text == "n4999", "never more than 5,000; the oldest go")
        expect(DictationHistory.adding(aged(0), to: capped, retention: .forever, now: now).count == DictationHistory.cap, "adding past the cap drops the oldest")
        expect(DictationRetention.default == .month && DictationRetention.month.rawValue == "30" && !DictationRetention.none.writesToDisk
               && DictationRetention.allCases.filter(\.writesToDisk).count == 4, "30 days by default; Don't keep never writes")
        let dontKeep = (0..<15).reduce([DictationRecord]()) { list, n in DictationHistory.adding(aged(Double(n) / 1000), to: list, retention: .none, now: now) }
        expect(dontKeep.count == DictationHistory.sessionOnly, "Don't keep holds only this run's last few, in memory")
        expect(DictationHistory.search(ages, "AGED 8.0").map(\.text) == ["aged 8.0"] && DictationHistory.search(ages, "  ").count == 8
               && DictationHistory.search([DictationRecord(id: UUID(), text: "Café Santé", createdAt: now, delivery: .copied(.noTextBox))], "cafe sante").count == 1,
               "search: local substring, case and accent insensitive")
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let grouped = DictationHistory.days([aged(0.01), aged(1.2), aged(0.02)], calendar: utc)
        expect(grouped.count == 2 && grouped[0].records.count == 2 && grouped[0].day > grouped[1].day, "grouped by day, newest day first")
        expect(DictationHistory.pillLabel == "DICTATIONS" && DictationHistory.pillLabel.allSatisfy { !$0.isNumber } && DictationHistory.petCount == 10,
               "the pet pill names the history, with no count")
        }
        // 0.5.309 files carry insertedApp/pasted; they still load, and an old "inserted" reads as unconfirmed.
        let legacy = Data(#"{"version":1,"dictations":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","text":"hi","createdAt":"2026-10-15T18:00:00Z","insertedApp":"Slack","pasted":false},{"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","text":"yo","createdAt":"2026-10-15T17:00:00Z"}]}"#.utf8)
        try legacy.write(to: file)
        let old = DictationHistory.load(from: file)
        expect(old.map(\.delivery) == [.unconfirmed(app: "Slack", viaPaste: false), .copied(.noTextBox)], "0.5.309 history still loads, honestly")
        let migrated = DictationHistory.pruned(old, retention: .default, now: Date(timeIntervalSince1970: 1_760_571_000 + 365 * 86_400 * 2))
        expect(DictationHistory.pruned(old, retention: .default, now: old[0].createdAt.addingTimeInterval(86_400)).count == 2 && migrated.isEmpty,
               "0.5.309-0.5.311 history migrates under the 30-day default")
        try Data("not json".utf8).write(to: file)
        expect(DictationHistory.load(from: file).isEmpty, "a corrupt file reads as empty, never a crash")
        let moved = DictationHistory.loadOrQuarantine(from: file, now: Date(timeIntervalSince1970: 1_760_571_000))
        expect(moved.records.isEmpty && moved.writable && moved.movedTo?.lastPathComponent == "dictation-history.json.corrupt-20251015-233000", "a corrupt file is moved aside")
        expect(!FileManager.default.fileExists(atPath: file.path) && moved.movedTo.map { FileManager.default.fileExists(atPath: $0.path) } == true, "nothing is saved over it")
        expect(DictationHistory.loadOrQuarantine(from: file, now: Date()).movedTo == nil, "a missing file is not moved")
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
        expect(DictationPill.flash(label: "PASTED · ⌘V SENT", confirmed: false).label == "PASTED · ⌘V SENT" && DictationPill.flash(label: "x", confirmed: true).replacesLedger, "flash label")
        expect(DictationPill.clock(4.9) == "0:04" && DictationPill.clock(65) == "1:05" && DictationPill.clock(-1) == "0:00", "elapsed clock")
        // 0.5.312 clipboard restore (Miles 21:23, like Wispr Flow): touched only for a posted ⌘V or the card, put back after.
        let original = [
            DictationClipboardItem(entries: [.init(type: "public.utf8-plain-text", data: Data("what I copied".utf8)), .init(type: "public.rtf", data: Data("{\\rtf1 x}".utf8)),
                                             .init(type: "public.file-url", data: Data("file:///Users/x/a.pdf".utf8))]),
            DictationClipboardItem(entries: [.init(type: "public.png", data: Data(repeating: 7, count: 300)), .init(type: "com.example.custom", data: Data([1, 2, 3]))]),
        ]
        let board = FakeDictationBoard(); board.stored = original; board.changeCount = 41
        let saved = DictationClipboard.snapshot(board)
        expect(saved?.items == original && saved?.changeCount == 41, "every item and type is snapshotted, in order")
        expect(board.writeTranscript("dictated", markerTypes: DictationClipboard.transientTypes) && board.lastMarkers == ["org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"],
               "the transcript is marked transient for clipboard managers")
        let setCount = board.changeCount
        expect(DictationClipboard.decision(enabled: true, pasted: true, snapshot: saved, setChangeCount: setCount, currentChangeCount: board.changeCount) == .restore, "restore after a posted ⌘V")
        expect(DictationClipboard.restore(saved!, to: board) && board.stored == original, "restored exactly: every item, type and byte, in order")
        expect(DictationClipboard.snapshot(board, cap: 100) == nil && DictationClipboard.snapshot(board, cap: 1_000) != nil, "over the cap: no snapshot, no restore")
        expect(DictationClipboard.decision(enabled: true, pasted: true, snapshot: nil, setChangeCount: 1, currentChangeCount: 1) == .skip("clipboard too large to restore"), "too large is said")
        expect(DictationClipboard.decision(enabled: true, pasted: true, snapshot: saved, setChangeCount: 5, currentChangeCount: 6) == .skip("clipboard changed since the paste"),
               "never over something copied after the paste")
        expect(DictationClipboard.decision(enabled: true, pasted: false, snapshot: saved, setChangeCount: 5, currentChangeCount: 5) == .skip("no paste"), "the card path keeps the transcript")
        expect(DictationClipboard.decision(enabled: false, pasted: true, snapshot: saved, setChangeCount: 5, currentChangeCount: 5) == .skip("setting off"), "the setting turns it off")
        let empty = FakeDictationBoard()
        let emptySaved = DictationClipboard.snapshot(empty)
        _ = empty.writeTranscript("dictated", markerTypes: [])
        expect(emptySaved?.items == [] && DictationClipboard.restore(emptySaved!, to: empty) && empty.stored.isEmpty, "an empty clipboard is put back empty")
        expect(DictationClipboard.use(for: .inserted(app: "Notes", viaPaste: false)) == .untouched
               && DictationClipboard.use(for: .unconfirmed(app: "Notes", viaPaste: false)) == .untouched, "Accessibility insertion never touches the clipboard")
        expect(DictationClipboard.use(for: .inserted(app: "iTerm2", viaPaste: true)) == .pasteThenRestore
               && DictationClipboard.use(for: .unconfirmed(app: "iTerm2", viaPaste: true)) == .pasteThenRestore, "a posted ⌘V restores")
        expect(DictationInsertPolicy.Refusal.allCases.allSatisfy { DictationClipboard.use(for: .refused($0)) == .keepForCard }, "every card keeps the transcript")
        expect(DictationClipboard.keepWaiting(elapsedMilliseconds: 100, fieldChanging: false) && !DictationClipboard.keepWaiting(elapsedMilliseconds: 500, fieldChanging: false)
               && DictationClipboard.keepWaiting(elapsedMilliseconds: 700, fieldChanging: true) && !DictationClipboard.keepWaiting(elapsedMilliseconds: 1_500, fieldChanging: true),
               "restore no sooner than 500 ms, later while the field moves, never past 1.5 s")
        // 0.5.312 sounds: pet default → the person's choice → a custom file that must still be usable.
        typealias L = DictationSoundLibrary
        expect(L.petDefault(.jedi) == "unstable-saber" && L.petDefault(.droid) == "droid-chirp" && L.petDefault(.other) == "soft-chime", "one pet table")
        expect(L.petKind(hasCombatStories: true, assetNames: ["session-pet-duel-two-droid-v15.png"]) == .jedi
               && L.petKind(hasCombatStories: false, assetNames: ["Astromech-Droid-idle.png"]) == .droid
               && L.petKind(hasCombatStories: false, assetNames: ["cloud-puff-idle.png"]) == .other, "pet kind")
        let usable: (String) -> Bool = { $0 == "start-ok.m4a" }
        func pick(_ stored: String, _ edge: DictationSoundEdge = .start, pet: DictationPetKind = .jedi, volume: Double = 0.6, recording: Bool = false) -> L.Resolved {
            L.resolve(L.Choice(stored: stored), edge: edge, pet: pet, volume: volume, macRecording: recording, customUsable: usable)
        }
        expect(pick("pet") == .bundled("unstable-saber-start.wav") && pick("pet", .stop, pet: .other) == .bundled("soft-chime-stop.wav"), "the pet's sound by default")
        expect(pick("library:droid-chirp", pet: .jedi) == .bundled("droid-chirp-start.wav"), "a library choice overrides the pet")
        expect(pick("library:not-a-sound") == .bundled("unstable-saber-start.wav"), "an unknown library id falls back to the pet")
        expect(pick("custom:start-ok.m4a") == .custom("start-ok.m4a") && pick("custom:gone.m4a") == .bundled("unstable-saber-start.wav"),
               "your own file, or the pet's sound once it is gone")
        expect(pick("pet", volume: 0) == .silent("volume off") && pick("custom:start-ok.m4a", volume: 0) == .silent("volume off"), "volume 0 is silent")
        expect(pick("pet", recording: true) == .silent("a COS recording is capturing") && pick("library:soft-chime", .stop, recording: true) == .silent("a COS recording is capturing"),
               "never during a Mac recording (it would be recorded)")
        expect(L.Choice(stored: "garbage") == .pet && L.Choice(stored: L.Choice.custom("a b.wav").stored) == .custom("a b.wav"), "stored choices round-trip")
        expect(L.customRefusal(byteCount: 500_000, duration: 1.2) == nil && L.customRefusal(byteCount: L.maximumSourceBytes + 1, duration: 1) != nil
               && L.customRefusal(byteCount: 19_000_000, duration: 8.76) == nil && L.customRefusal(byteCount: 10, duration: nil) != nil
               && L.customRefusal(byteCount: 10, duration: 0) != nil, "your own file: a source up to 20 MB that decodes; long files are trimmed, not refused")
        do { // own scope: names here must not collide with earlier sections
        // Trim on import, on Miles's test file's shape: 8.76 s at 48 kHz, the ignition at 0.30 s, the sound over at 8.26 s.
        let rate = 48_000.0
        var file = [Float](repeating: 0, count: Int(8.76 * rate))
        for i in 0..<file.count {
            let t = Double(i) / rate
            let loud = t >= 0.30 && t < 8.26
            file[i] = Float(loud ? 0.25 * sin(2 * Double.pi * 82 * t) : 0.0005 * sin(2 * Double.pi * 1_000 * t)) // -15 dBFS sound, -69 dBFS floor
        }
        let trimLevels = DictationSoundTrim.levels(file, sampleRate: rate)
        let onset = DictationSoundTrim.onset(trimLevels)!, soundEnd = DictationSoundTrim.end(trimLevels)!
        expect(abs(onset - 0.30) < 1e-9 && abs(soundEnd - 8.26) < 1e-9, "the onset and end of the sound at -40 dBFS in 10 ms windows")
        let startWindow = DictationSoundTrim.startWindow(onset: onset, duration: 8.76), stopWindow = DictationSoundTrim.stopWindow(end: soundEnd, duration: 8.76)
        expect(abs(startWindow.start - 0.30) < 1e-9 && abs(startWindow.end - 2.30) < 1e-9 && startWindow.fadeIn == 0.005 && startWindow.fadeOut == 0.45,
               "start window 0.30-2.30 s, 5 ms in, 0.45 s out")
        expect(abs(stopWindow.start - 7.71) < 1e-9 && abs(stopWindow.end - 8.31) < 1e-9 && stopWindow.fadeIn == 0.030 && stopWindow.fadeOut == 0.070,
               "stop window 7.71-8.31 s, 30 ms in, 70 ms out")
        let trimmed = DictationSoundTrim.apply(file, sampleRate: rate, window: startWindow)
        expect(trimmed.count == Int(2.0 * rate) && trimmed[0] == 0 && trimmed[trimmed.count - 1] == 0 && Double(trimmed.count) / rate <= L.maximumStoredSeconds,
               "the stored start sound is 2.0 s with silent edges")
        expect(abs(DictationSoundTrim.startWindow(onset: 7.5, duration: 8.0).length - 0.5) < 1e-9 && DictationSoundTrim.stopWindow(end: 0.3, duration: 0.32).start == 0,
               "windows stay inside the file")
        expect(DictationSoundTrim.onset(DictationSoundTrim.levels([Float](repeating: 0.001, count: 48_000), sampleRate: rate)) == nil, "a file that never reaches -40 dBFS is silent")
        let stored = DictationSoundTrim.wav(trimmed, sampleRate: 48_000)
        expect(stored.count == 44 + trimmed.count * 2 && String(decoding: stored.prefix(4), as: UTF8.self) == "RIFF" && stored[22] == 1, "stored as mono 16-bit WAV")
        expect(L.cents(0) == 0 && L.cents(-4) == -400 && L.cents(2.4) == 200 && L.cents(-20) == -1_200 && L.cents(9) == 600 && L.cents(.nan) == 0,
               "pitch: whole semitones, -12 to +6, in cents")
        expect(L.name("unstable-saber") == "Unstable saber" && L.name("unstable-saber-bright") == "Unstable saber (bright)"
               && L.name("dark-saber") == "Dark saber" && L.sounds.count == 8, "names")
        expect(L.defaultVolume == 0.6 && L.sounds.map(\.id).allSatisfy { !$0.isEmpty } && Set(L.sounds.map(\.id)).count == L.sounds.count, "library")
        }
        do { // own scope: names here must not collide with earlier sections
        // The pill goes where the person is looking.
        let left = CGRect(x: 0, y: 0, width: 1512, height: 982), right = CGRect(x: 1512, y: 0, width: 3440, height: 1440)
        let petOnLeft = CGRect(x: 1200, y: 40, width: 300, height: 260)
        expect(DictationPlacement.choose(petFrame: petOnLeft, focusedWindow: CGRect(x: 100, y: 100, width: 800, height: 600), screens: [left, right], mainScreen: left) == .pet,
               "pet on the focused screen: the pill rides the pet")
        expect(DictationPlacement.choose(petFrame: petOnLeft, focusedWindow: CGRect(x: 2000, y: 200, width: 1200, height: 900), screens: [left, right], mainScreen: left) == .floating(screen: right),
               "pet on another display: the pill on the focused window's screen")
        expect(DictationPlacement.choose(petFrame: nil, focusedWindow: CGRect(x: 2000, y: 200, width: 1200, height: 900), screens: [left, right], mainScreen: left) == .floating(screen: right),
               "pet hidden or in another space: the focused screen")
        expect(DictationPlacement.choose(petFrame: nil, focusedWindow: nil, screens: [left, right], mainScreen: right) == .floating(screen: right)
               && DictationPlacement.choose(petFrame: petOnLeft, focusedWindow: nil, screens: [left, right], mainScreen: right) == .floating(screen: right),
               "no Accessibility: the main screen")
        expect(DictationPlacement.choose(petFrame: petOnLeft, focusedWindow: CGRect(x: 1400, y: 100, width: 600, height: 400), screens: [left, right], mainScreen: left) == .floating(screen: right),
               "a window across both screens counts where most of it is")
        }
        do { // 0.5.313 editing and quiet; own scope
        // Shortcuts: ⌃⌥F by default; no slot may take another's combo or Open Activity's.
        let fix = DictationShortcuts.defaultFix, f9 = DictationTrigger.keys(101, modifiers: 0)!
        expect(fix == .keys(keyCode: 3, modifiers: DictationTrigger.control | DictationTrigger.option), "Fix last dictation defaults to ⌃⌥F (ANSI F is 3)")
        let assigned: [DictationShortcutSlot: DictationTrigger] = [.hold: .modifier(keyCode: 63), .toggle: f9, .fix: fix]
        expect(DictationShortcuts.conflicts(fix, slot: .hold, assigned: assigned, activity: nil)
               && DictationShortcuts.conflicts(f9, slot: .fix, assigned: assigned, activity: nil)
               && DictationShortcuts.conflicts(.modifier(keyCode: 63), slot: .toggle, assigned: assigned, activity: nil),
               "a combo another dictation slot holds conflicts")
        expect(!DictationShortcuts.conflicts(fix, slot: .fix, assigned: assigned, activity: nil) && !DictationShortcuts.conflicts(nil, slot: .fix, assigned: assigned, activity: fix),
               "re-setting a slot's own combo, or turning it off, is not a conflict")
        expect(DictationShortcuts.conflicts(fix, slot: .fix, assigned: [:], activity: fix), "Open Activity's combo conflicts")
        expect(DictationShortcutSlot.allCases.map(\.hotKeyID) == [1, 2, 3] && DictationShortcutSlot.fix.defaultsPrefix == "dictation.fix",
               "hot key ids and stored keys")
        // Fix from the moment it lands.
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        let newest = DictationRecord(id: UUID(), text: "new", createdAt: t0, delivery: .inserted(app: "Notes"))
        let older = DictationRecord(id: UUID(), text: "old", createdAt: t0.addingTimeInterval(-60), delivery: .inserted(app: "Notes"))
        expect(DictationQuickFix.target([newest, older], busy: false) == newest.id && DictationQuickFix.target([newest], busy: true) == nil
               && DictationQuickFix.target([], busy: false) == nil, "the shortcut opens the newest dictation, never while dictating")
        expect(DictationQuickFix.offerSeconds == 5 && DictationQuickFix.offers(.inserted(app: "Notes", viaPaste: false))
               && DictationQuickFix.offers(.unconfirmed(app: "iTerm2", viaPaste: true)) && !DictationQuickFix.offers(.refused(.noTextBox)),
               "Fix rides every flash for 5 s; a refusal has the card")
        // Replace the pasted text: the span is recorded only on an exact measurement.
        let base = DictationFieldSnapshot(characters: 100, location: 40, length: 0)
        let span = DictationReplace.span(pid: 42, baseline: base, after: DictationFieldSnapshot(characters: 112, location: 52, length: 0), count: 12)
        expect(span == DictationInsertedSpan(pid: 42, location: 40, length: 12), "a landed insertion records where it went")
        expect(DictationReplace.span(pid: 42, baseline: base, after: DictationFieldSnapshot(characters: 130, location: 70, length: 0), count: 12) == nil
               && DictationReplace.span(pid: 42, baseline: DictationFieldSnapshot(characters: 100, location: nil, length: nil),
                                        after: DictationFieldSnapshot(characters: 112, location: nil, length: nil), count: 12) == nil,
               "a field that moved more than the text, or no caret, records nothing")
        let inserted = "yellow fanduna"
        let s14 = DictationInsertedSpan(pid: 42, location: 40, length: 14)
        func decide(_ span: DictationInsertedSpan?, terminal: Bool = false, running: Bool = true, n: Int? = 120, at: String? = "yellow fanduna") -> DictationReplace.Decision {
            DictationReplace.decide(span: span, terminal: terminal, appRunning: running, fieldCharacters: n, textAtSpan: at, inserted: inserted)
        }
        expect(decide(s14) == .replace(location: 40, length: 14), "range still matches: replace")
        expect(decide(s14, at: "low fanduna to") == .copy(.textMoved), "text moved (typed above it): copy")
        expect(decide(s14, at: "yellow fandunas") == .copy(.textMoved) && decide(s14, at: nil) == .copy(.textMoved), "edited or unreadable span: copy")
        expect(decide(s14, n: 30) == .copy(.fieldChanged) && decide(s14, n: nil) == .copy(.fieldGone), "field changed or gone: copy")
        expect(decide(s14, terminal: true) == .copy(.terminal) && decide(nil) == .copy(.notMeasured) && decide(s14, running: false) == .copy(.appGone),
               "terminal, unmeasured paste and a quit app: copy")
        // Before the set, the span is selected: 120 characters, 40+14.
        let selected = DictationFieldSnapshot(characters: 120, location: 40, length: 14)
        func verified(_ n: Int?, _ caret: Int?, _ length: Int? = 0, new: Int) -> Bool {
            DictationReplace.verified(before: selected, after: DictationFieldSnapshot(characters: n, location: caret, length: caret == nil ? nil : length), span: s14, newLength: new)
        }
        expect(verified(120, 54, new: 14) && !verified(120, nil, new: 14) && !verified(120, 40, 14, new: 14) && !verified(120, 40, 0, new: 14),
               "a same-length fix is proved by the caret after it, never by the unchanged count")
        expect(!verified(125, 54, new: 14), "a count that moved on a same-length fix is not proof")
        expect(verified(123, 57, new: 17) && verified(123, nil, new: 17) && verified(nil, 57, new: 17),
               "a longer fix: the count moved by the difference, or the caret sits after it")
        expect(!verified(120, 54, new: 17) && !verified(123, 40, 14, new: 17) && !verified(123, 54, new: 17) && !verified(nil, nil, new: 17),
               "anything else is unproved")
        expect(DictationReplace.corrected("I caught a yellow fanduna, today.", range: 3...4, written: "yellowfin tuna") == "I caught a yellowfin tuna, today."
               && DictationReplace.corrected("\"Kubernetes\"\nnext", range: 0...0, written: "Kubernetes") == "\"Kubernetes\"\nnext"
               && DictationReplace.corrected("hi  there", range: 1...1, written: "you") == "hi  you"
               && DictationReplace.corrected("hi", range: 1...1, written: "x") == nil,
               "the corrected dictation keeps punctuation and spacing")
        // Smarter selection: the likely misheard span, and a suggestion from the dictionary.
        let tokens = DictationFixText.tokens("I caught a yellow fanduna today")
        let english: Set<String> = ["I", "caught", "a", "yellow", "today"]
        let guess = DictationFixGuess.guess(tokens: tokens, tapped: 4, vocabulary: ["Bottle POS", "yellowfin tuna"], known: { english.contains($0) })
        expect(guess == .init(range: 3...4, suggestion: "yellowfin tuna"), "\"yellow fanduna\" is one mishearing of \"yellowfin tuna\"")
        expect(DictationFixGuess.guess(tokens: tokens, tapped: 3, vocabulary: ["yellowfin tuna"], known: { english.contains($0) }).suggestion == "yellowfin tuna",
               "tapping either word finds it")
        expect(DictationFixGuess.guess(tokens: ["open", "bottle", "pause", "now"], tapped: 2, vocabulary: ["Bottle POS"], known: { _ in true })
               == .init(range: 1...2, suggestion: "Bottle POS"), "a sound-alike the spelling alone misses (\"bottle pause\")")
        expect(DictationFixGuess.skeleton("yellow fanduna") == DictationFixGuess.skeleton("yellowfin tuna") && DictationFixGuess.distance("kitten", "sitting") == 3,
               "sound-alike key and edit distance")
        let plain = DictationFixGuess.guess(tokens: DictationFixText.tokens("ship it to kuberneetus prod now"), tapped: 3, vocabulary: [], known: { ["ship", "it", "to", "now"].contains($0) })
        expect(plain == .init(range: 3...4, suggestion: nil), "no dictionary match: the tap widens over neighbors that are not English words")
        expect(DictationFixGuess.guess(tokens: tokens, tapped: 1, vocabulary: ["yellowfin tuna"], known: { english.contains($0) }) == .init(range: 1...1, suggestion: nil),
               "a known word far from any match stays one word")
        expect(DictationFixGuess.guess(tokens: DictationFixText.tokens("yellowfin tuna again"), tapped: 0, vocabulary: ["yellowfin tuna"], known: { _ in false }).suggestion == nil,
               "a span already spelled like the dictionary is not suggested again")
        expect(DictationFixGuess.guess(tokens: ["dog", "food"], tapped: 0, vocabulary: ["Bottle POS"], known: { _ in true }) == .init(range: 0...0, suggestion: nil),
               "an unrelated dictionary suggests nothing")
        // Quiet: mute (default), lower, off; never during a Mac recording; the exact volume back.
        expect(DictationQuietMode.default == .mute && DictationQuietMode.allCases.map(\.title) == ["Mute other apps", "Lower other audio", "Off"], "Mute by default")
        expect(DictationQuiet.plan(mode: .mute, macRecording: false, tapPermitted: true, volume: 0.5, volumeSettable: true) == .muteTap,
               "permitted: a muting tap")
        expect(DictationQuiet.plan(mode: .mute, macRecording: false, tapPermitted: false, volume: 0.5, volumeSettable: true) == .lowerVolume(to: 0.125)
               && DictationQuiet.plan(mode: .lower, macRecording: false, tapPermitted: true, volume: 0.8, volumeSettable: true) == .lowerVolume(to: 0.2),
               "no System Audio Recording, or Lower: the volume to a quarter")
        for mode in DictationQuietMode.allCases {
            if case .leave = DictationQuiet.plan(mode: mode, macRecording: true, tapPermitted: true, volume: 0.5, volumeSettable: true) {} else {
                expect(false, "never during a Mac recording (\(mode))")
            }
        }
        if case .leave = DictationQuiet.plan(mode: .off, macRecording: false, tapPermitted: true, volume: 0.5, volumeSettable: true) {} else { expect(false, "Off leaves it") }
        if case .leave = DictationQuiet.plan(mode: .lower, macRecording: false, tapPermitted: false, volume: 0.5, volumeSettable: false) {} else { expect(false, "fixed volume: left alone") }
        if case .leave = DictationQuiet.plan(mode: .lower, macRecording: false, tapPermitted: false, volume: 0, volumeSettable: true) {} else { expect(false, "silent: left alone") }
        expect(DictationQuiet.restoreVolume(saved: 0.62, lowered: 0.155, current: 0.155) == 0.62 && DictationQuiet.restoreVolume(saved: 0.62, lowered: 0.155, current: nil) == 0.62,
               "the exact saved scalar goes back")
        expect(DictationQuiet.restoreVolume(saved: 0.62, lowered: 0.155, current: 0.9) == nil, "a volume the person changed while dictating stays theirs")
        let pending = DictationQuiet.Pending(deviceUID: "BuiltInSpeakerDevice", saved: 0.62, lowered: 0.155)
        let decoded = try JSONDecoder().decode(DictationQuiet.Pending.self, from: try JSONEncoder().encode(pending))
        expect(decoded == pending && DictationQuiet.launchRestore(decoded, current: 0.155) == 0.62 && DictationQuiet.launchRestore(nil, current: 0.1) == nil,
               "interrupted dictation: the next launch puts the volume back")
        // Media: never a blind play/pause key.
        expect(DictationMedia.decide(playing: nil) == .leave && DictationMedia.decide(playing: false) == .leave && DictationMedia.decide(playing: true) == .pause,
               "pause only a known, playing state; unknown is left alone")
        }
        print("PASS Mac dictation: \(count) policy checks; insert-target table, measured delivery, terminals, layout ⌘V, listening bars end to end, clipboard restore, sounds, pill placement, recent dictations file, card countdown, fix-a-word selection, quick fix, replace, span guess, quiet and restore, bounded audio, PCM16 WAV, device failure, any-key triggers")
    }
}
