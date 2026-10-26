import CoreAudio
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
            // 0.5.332 (Miles 09:57): Google Slides in Comet focuses an AXEmptyGroup; Comet is Chromium, so it gets ⌘V.
            ("Comet's Slides canvas gets ⌘V, not NO TEXT BOX", true, false, "AXEmptyGroup", true, false, false, true, false, nil),
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
        expect(L.petDefault(.jedi) == "windu-saber" && L.petDefault(.droid) == "droid-chirp" && L.petDefault(.other) == "soft-chime", "one pet table")
        // 0.5.315: Miles's own saber is the Jedi Miles Windu pack's default; the other three Jedi packs keep Unstable saber.
        // The file sets are the shipped state maps' pose files (dictation-wispr-pins.py checks they still match).
        let shippedPacks: [(id: String, files: Set<String>)] = [
            (id: "jedi-miles-windu", files: ["windu-ambient-illustrated-v1-patrol-1x.png", "windu-ambient-illustrated-v2-idle-1x.png", "windu-ambient-illustrated-v2-waiting-1x.png", "windu-illustrated-v1-1-swarm-a-full-1x.png", "windu-illustrated-v1-duel-a-full-1x.png", "windu-illustrated-v1-trio-a-full-1x.png", "windu-motion-v1-working-a-full-1x.png", "windu-pack15-attention-1x.png", "windu-pack15-done-1x.png", "windu-pack15-error-1x.png"]),
            (id: "jedi-nia-solari", files: ["combat-20261018-session-pet-idle-v2.png", "combat-20261018-session-pet-idle.png", "combat-20261018-session-pet-patrol-v3.png", "combat-20261018-session-pet-waiting-v3.png", "combat-20261018-working-a-full.png", "jedi360-v2-nia-duel-a-full-1x.png", "jedi360-v2-nia-swarm-a-full-1x.png", "jedi360-v2-nia-trio-a-full-1x.png"]),
            (id: "jedi-elara-vale", files: ["combat-20261018-session-pet-idle-v2.png", "combat-20261018-session-pet-idle.png", "combat-20261018-session-pet-patrol-v3.png", "combat-20261018-working-motion-full.png", "jedi360-v2-elara-duel-a-full-1x.png", "jedi360-v2-elara-swarm-a-full-1x.png", "jedi360-v2-elara-trio-a-full-1x.png"]),
            (id: "jedi-rowan-vale", files: ["combat-20261018-session-pet-idle-v2.png", "combat-20261018-session-pet-idle.png", "combat-20261018-session-pet-patrol-v3.png", "combat-20261018-working-motion-full.png", "jedi360-v2-rowan-duel-a-full-1x.png", "jedi360-v2-rowan-swarm-a-full-1x.png", "jedi360-v2-rowan-trio-a-full-1x.png"]),
        ]
        let packFiles = Dictionary(uniqueKeysWithValues: shippedPacks.map { ($0.id, $0.files) })
        let installed = { (id: String) in L.installedPack(packFiles[id]!, packs: shippedPacks) }
        for pack in shippedPacks {
            expect(installed(pack.id) == pack.id, "V2 character-specific filenames identify \(pack.id)")
        }
        expect(L.installedPack(["shared.png"], packs: [(id: "one", files: ["shared.png"]), (id: "two", files: ["shared.png"])]) == nil,
               "ambiguous filenames never select a shipped pack")
        expect(L.installedPack([], packs: shippedPacks) == nil && L.installedPack(["session-pet-idle.png"], packs: shippedPacks) == nil
               && L.installedPack(packFiles["jedi-miles-windu"]!.union(["custom.png"]), packs: shippedPacks) == nil
               && L.installedPack([], packs: [(id: "empty", files: [])]) == nil, "an unknown, edited or empty pack is no shipped pack")
        // 0.5.318: Miles's saber is every Jedi's default (Miles 2026-10-17).
        for pack in ["jedi-miles-windu", "jedi-nia-solari", "jedi-elara-vale", "jedi-rowan-vale"] {
            expect(L.petDefault(.jedi, pack: installed(pack)) == "windu-saber", "\(pack): Miles Windu lightsaber")
        }
        expect(L.petDefault(.droid, pack: L.winduPackID) == "droid-chirp" && L.petDefault(.other, pack: L.winduPackID) == "soft-chime"
               && L.petDefault(.droid) == "droid-chirp" && L.petDefault(.other) == "soft-chime", "droid and other are unchanged, pack or not")
        expect(L.resolve(.pet, edge: .stop, pet: .jedi, pack: L.winduPackID, volume: 0.6, macRecording: false, customUsable: { _ in true }) == .bundled("windu-saber-stop.wav")
               && L.resolve(.custom("start-229CA5A4.wav"), edge: .start, pet: .jedi, pack: L.winduPackID, volume: 0.6, macRecording: false, customUsable: { _ in true })
                  == .custom("start-229CA5A4.wav"), "Pet default plays the Windu saber; a saved custom choice still wins")
        expect(L.petKind(hasCombatStories: true, assetNames: ["session-pet-duel-two-droid-v15.png"]) == .jedi
               && L.petKind(hasCombatStories: false, assetNames: ["Astromech-Droid-idle.png"]) == .droid
               && L.petKind(hasCombatStories: false, assetNames: ["cloud-puff-idle.png"]) == .other, "pet kind")
        let usable: (String) -> Bool = { $0 == "start-ok.m4a" }
        func pick(_ stored: String, _ edge: DictationSoundEdge = .start, pet: DictationPetKind = .jedi, volume: Double = 0.6, recording: Bool = false) -> L.Resolved {
            L.resolve(L.Choice(stored: stored), edge: edge, pet: pet, volume: volume, macRecording: recording, customUsable: usable)
        }
        expect(pick("pet") == .bundled("windu-saber-start.wav") && pick("pet", .stop, pet: .other) == .bundled("soft-chime-stop.wav"), "the pet's sound by default")
        expect(pick("library:droid-chirp", pet: .jedi) == .bundled("droid-chirp-start.wav"), "a library choice overrides the pet")
        expect(pick("library:not-a-sound") == .bundled("windu-saber-start.wav"), "an unknown library id falls back to the pet")
        expect(pick("custom:start-ok.m4a") == .custom("start-ok.m4a") && pick("custom:gone.m4a") == .bundled("windu-saber-start.wav"),
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
               && L.name("dark-saber") == "Dark saber" && L.name("windu-saber") == "Miles Windu lightsaber" && L.sounds.first?.id == "windu-saber"
               && L.sounds.count == 9, "names; Miles Windu lightsaber first")
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
        let s14 = DictationInsertedSpan(pid: 42, location: 40, length: 14)
        // 0.5.318 replace planning (Miles 13:02: "Y joule 360" → "Jewel360" in Claude). Hand-written fields and answers.
        typealias Edit = DictationReplace.Edit
        let said = "redirect into this uh Y joule 360 page", fixed = "redirect into this uh Jewel360 page"
        expect(DictationReplace.wordEdit(from: said, to: fixed) == Edit(location: 22, length: 11, original: "Y joule 360", replacement: "Jewel360"),
               "only the misheard words change, in UTF-16 units of the dictation")
        expect(DictationReplace.wordEdit(from: "I caught a yellow fanduna, today.", to: "I caught a yellowfin tuna, today.")
               == Edit(location: 11, length: 15, original: "yellow fanduna,", replacement: "yellowfin tuna,"), "punctuation stays with its word")
        expect(DictationReplace.wordEdit(from: "hi there", to: "hi you there") == Edit(location: 3, length: 0, original: "", replacement: "you "),
               "an added word is an insertion at a word boundary")
        expect(DictationReplace.wordEdit(from: "1. Call Gina.\n2. Ship it.", to: "1. Call Gina.\n2. Ship COS.")
               == Edit(location: 22, length: 3, original: "it.", replacement: "COS."), "line breaks are kept as they are")
        expect(DictationReplace.wordEdit(from: said, to: said) == nil, "nothing changed: no edit")
        expect(DictationReplace.window(span: DictationInsertedSpan(pid: 1, location: 1000, length: 20), currentLength: 20, fieldCharacters: 5000) == (744, 532)
               && DictationReplace.window(span: DictationInsertedSpan(pid: 1, location: 10, length: 20), currentLength: 20, fieldCharacters: 5000) == (0, 286)
               && DictationReplace.window(span: DictationInsertedSpan(pid: 1, location: 1000, length: 20), currentLength: 40, fieldCharacters: 5000) == (744, 552)
               && DictationReplace.window(span: DictationInsertedSpan(pid: 1, location: 1000, length: 20), currentLength: 20, fieldCharacters: 100) == (0, 100),
               "the window is 256 either side of the dictation, clipped to the field, never the whole value")
        let at7 = DictationInsertedSpan(pid: 42, location: 7, length: 38)
        func plan(_ field: String?, span: DictationInsertedSpan? = at7, terminal: Bool = false, running: Bool = true, start: Int = 0,
                  current: String = said, corrected: String = fixed) -> DictationReplace.Plan {
            DictationReplace.plan(span: span, terminal: terminal, appRunning: running, fieldCharacters: field?.utf16.count, window: field,
                                  windowStart: start, current: current, corrected: corrected)
        }
        let swap = Edit(location: 29, length: 11, original: "Y joule 360", replacement: "Jewel360")
        expect(plan("Please " + said + " now.") == .edit(swap, dictationAt: 7), "where COS put it: replace only the misheard words")
        expect(plan(" " + said + " now.", start: 6) == .edit(swap, dictationAt: 7), "a window that starts before the span is offset")
        expect(plan("Hi. Please " + said + " now.") == .edit(Edit(location: 33, length: 11, original: "Y joule 360", replacement: "Jewel360"), dictationAt: 11),
               "text typed above it: found once, moved with it")
        expect(plan("Please redirect into that uh Y joule 360 page now.") == .edit(swap, dictationAt: nil),
               "another word of it edited: the misheard words found once, no longer tracked as a whole")
        expect(plan("Please redirect into that uh Y joule 360 page, Y joule 360 now.") == .copy(.textMoved), "the words twice: copy")
        expect(plan("x " + said + " " + said, span: DictationInsertedSpan(pid: 42, location: 0, length: 38)) == .copy(.textMoved),
               "the dictation twice, neither where COS put it: copy")
        expect(plan("Please " + said + " " + said) == .edit(swap, dictationAt: 7), "the dictation twice, one where COS put it: that one")
        expect(plan("XY joule 360 page and Y joule 360 page", span: DictationInsertedSpan(pid: 42, location: 30, length: 16),
                    current: "Y joule 360 page", corrected: "Jewel360 page") == .copy(.textMoved),
               "two copies of the dictation stay ambiguous even when one copy's words are not on a word boundary")
        expect(plan("Please redirect into that uh XY joule 360 page now.") == .copy(.textMoved), "the words inside another word are not the words")
        expect(plan("so uh a b d", span: DictationInsertedSpan(pid: 42, location: 3, length: 8), current: "uh a b c", corrected: "uh a B c") == .copy(.textMoved),
               "a misheard word shorter than three units is never searched for")
        expect(plan("Please " + said, terminal: true) == .copy(.terminal) && plan("Please " + said, span: nil) == .copy(.notMeasured)
               && plan("Please " + said, running: false) == .copy(.appGone) && plan(nil) == .copy(.fieldGone),
               "terminal, unmeasured paste, a quit app, an unreadable field: copy")
        expect(plan("Please " + said + " now.", corrected: said) == .copy(.noChange), "nothing to change: say so")
        expect(plan("Please redirect elsewhere now.") == .copy(.textMoved), "the text is gone: copy")
        // Route: what delivery proved. Electron's set reports success and changes nothing (Claude 13:02:42 setter=0
        // after=n=183 r=183+0), so there a replace pastes.
        expect(DictationReplace.route(setterWorked: true) == .accessibility && DictationReplace.route(setterWorked: false) == .paste,
               "the setter where it moved the field, else ⌘V")
        let selectedSwap = DictationFieldSnapshot(characters: 200, location: 29, length: 11)
        func proof(frontmost: Bool = true, own: Bool = false, focused: Bool = true, selection: DictationFieldSnapshot = selectedSwap,
                   text: String? = "Y joule 360", edit: Edit = swap) -> DictationReplace.Reason? {
            DictationReplace.pasteProof(frontmost: frontmost, ownWindowKey: own, focusedIsTarget: focused, selection: selection, selectedText: text, edit: edit)
        }
        expect(proof() == nil, "frontmost, focused, and the selection reads back as exactly the words: paste")
        expect(proof(frontmost: false) == .notFocused && proof(own: true) == .notFocused && proof(focused: false) == .notFocused,
               "another app in front, COS's own panel holding the keyboard, or another field focused: never paste")
        expect(proof(selection: DictationFieldSnapshot(characters: 200, location: 30, length: 11)) == .selectionUnproven
               && proof(selection: DictationFieldSnapshot(characters: 200, location: 29, length: 10)) == .selectionUnproven
               && proof(selection: DictationFieldSnapshot()) == .selectionUnproven,
               "a selection that is not exactly the range (or unread) is not proof")
        expect(proof(text: "Y joule 36") == .selectionUnproven && proof(text: nil) == .selectionUnproven, "the selected text must read back as the words")
        expect(proof(selection: DictationFieldSnapshot(characters: 200, location: 3, length: 0), text: nil,
                     edit: Edit(location: 3, length: 0, original: "", replacement: "you ")) == nil, "an insertion needs only the caret")
        func confirmed(_ after: DictationFieldSnapshot, _ back: String?) -> Bool {
            DictationReplace.confirmed(before: selectedSwap, after: after, edit: swap, readback: back)
        }
        expect(confirmed(DictationFieldSnapshot(characters: 197, location: 37, length: 0), "Jewel360")
               && confirmed(DictationFieldSnapshot(characters: 197, location: 37, length: 0), nil), "measured, and read back where the field allows")
        expect(!confirmed(selectedSwap, nil) && !confirmed(selectedSwap, "Jewel360"),
               "the Electron no-op (nothing moved after a successful set) is never confirmed")
        expect(!confirmed(DictationFieldSnapshot(characters: 197, location: 37, length: 0), "Y joule"), "a read-back of other words is not the fix")
        let reasons: [DictationReplace.Reason] = [.notMeasured, .terminal, .appGone, .fieldGone, .textMoved, .notFocused, .selectionUnproven, .noChange]
        expect(reasons.allSatisfy { !DictationReplace.copiedNote($0, app: "Claude").isEmpty }
               && DictationReplace.copiedNote(.selectionUnproven, app: "Claude").contains("press ⌘V")
               && DictationReplace.copiedNote(.notFocused, app: "Claude").contains("press ⌘V")
               && DictationReplace.unverifiedNote(app: "Claude", pasted: true).hasPrefix("COS pasted")
               && DictationReplace.unverifiedNote(app: "Claude", pasted: false).hasPrefix("COS set"),
               "every copy says what to do next; an unconfirmed paste says it pasted")
        // Save corrects the stored dictation (Miles: Heard still read "Y joule 360").
        let first = DictationRecord(id: UUID(), text: said, createdAt: t0, delivery: .inserted(app: "Claude"))
        let second = DictationRecord(id: UUID(), text: "other", createdAt: t0.addingTimeInterval(-5), delivery: .copied(.noTextBox))
        let corrected = DictationHistory.correcting(first.id, to: fixed, in: [first, second])
        expect(corrected.map(\.id) == [first.id, second.id] && corrected[0].text == fixed && corrected[0].createdAt == t0
               && corrected[0].delivery == .inserted(app: "Claude") && corrected[1] == second, "only the text of that dictation changes")
        expect(DictationHistory.correcting(UUID(), to: "x", in: [first, second]) == [first, second], "an unknown dictation changes nothing")
        // 0.5.318 spoken lists: a golden table, positives with their exact output and negatives that stay prose.
        let lists: [(String, String)] = [
            ("number one, I want to do X, Y or Z. Number two, I want to do Z, E and F. Number three, I want to do C, B and J.",
             "1. I want to do X, Y or Z.\n2. I want to do Z, E and F.\n3. I want to do C, B and J."),
            ("Here's the plan for today. Number one, call Gina. Number two, review the deck.", "Here's the plan for today.\n1. Call Gina.\n2. Review the deck."),
            ("I have three goals, number one, sleep more, number two, ship COS, and number three, call Justin.",
             "I have three goals:\n1. Sleep more\n2. Ship COS\n3. Call Justin."),
            ("Number 1: buy milk. Number 2: pick up the kids.", "1. Buy milk.\n2. Pick up the kids."),
            ("Number one. Fix the replace bug. Number two. Format spoken lists.", "1. Fix the replace bug.\n2. Format spoken lists."),
            ("First, book the flight. Second, reserve the hotel. Third, tell Queen.", "1. Book the flight.\n2. Reserve the hotel.\n3. Tell Queen."),
            ("First of all, thank the team. Secondly, send the recap.", "1. Thank the team.\n2. Send the recap."),
            ("One, call Gina. Two, call Graham. Three, call Ryan.", "1. Call Gina.\n2. Call Graham.\n3. Call Ryan."),
            ("Bullet, eggs. Bullet, milk. Next bullet, bread.", "- Eggs.\n- Milk.\n- Bread."),
            ("Bullet point call the vendor. Next bullet point confirm the booth.", "- Call the vendor.\n- Confirm the booth."),
            ("Groceries. Dash, eggs. Dash, milk.", "Groceries.\n- Eggs.\n- Milk."),
            ("Number one, update the iPhone app. Number two, iOS release notes.", "1. Update the iPhone app.\n2. iOS release notes."),
            ("Number one, X. Number three, Y. Number two, Z.", "1. X. Number three, Y.\n2. Z."),
        ]
        for (spoken, written) in lists {
            expect(DictationListFormat.format(spoken) == written, "spoken list: \(spoken)")
            expect(DictationListFormat.format(written) == written, "a formatted list is left alone: \(spoken)")
        }
        expect(DictationListFormat.format("Number one, pack. Number two, drive. First, unpack. Second, rest.") == "1. Pack.\n2. Drive. First, unpack. Second, rest.",
               "one list per dictation: the kind that starts first wins, later markers stay in the last item")
        let prose = [
            "I have two kids.", "Sleep is my number one priority.", "Number one priority is sleep. Number two priority is family.",
            "Number one, I love this.", "One, two, three, go!", "First, I went home.", "Number one, number two, number three.",
            "Number one, ... Number two, ...", "Number one, call Gina. Number three, call Ryan.", "Number two, call Gina. Number three, call Ryan.",
            "One, call Gina. Two, call Graham.", "Bullet points are great. Bullet points are bad.", "Dash to the store. Dash home.",
            "We have two options, one is cheap and one is fast.", "My first, second and third choices were taken.",
            "It was the first, then the second, then the third.", "Wait a second. Second, we need the deck.",
            "I'll take number one, and number two can wait.", "Count with me. One, Mississippi, two, Mississippi, three, Mississippi.", "",
        ]
        for text in prose { expect(DictationListFormat.format(text) == text, "prose stays prose: \(text)") }
        // 0.5.318 Learn from my edits (Miles 13:31): Save automatically by default; native apps first; never secure.
        expect(DictationLearnMode.default == .automatic && DictationLearnMode.allCases.map(\.title) == ["Save automatically", "Suggest only", "Off"],
               "Save automatically is the default; Suggest only and Off are the others")
        typealias L = DictationEditLearning
        func eligible(_ mode: DictationLearnMode = .automatic, secure: Bool = false, terminal: Bool = false, electron: Bool = false,
                      chromium: Bool = false, setter: Bool = true) -> L.Eligibility {
            L.eligibility(mode: mode, secure: secure, terminal: terminal, electron: electron, chromium: chromium, setterWorked: setter)
        }
        expect(eligible() == .learn && eligible(.suggest) == .learn && eligible(setter: false) == .learn, "a native field learns, either mode")
        expect(eligible(.off) == .skip("off") && eligible(.off, electron: true) == .skip("off"), "Off watches nothing, not even a probe")
        expect(eligible(secure: true) == .skip("secure") && eligible(secure: true, electron: true) == .skip("secure")
               && eligible(.suggest, secure: true, chromium: true) == .skip("secure"), "never a password field or secure input, in any app")
        expect(eligible(terminal: true) == .skip("terminal") && eligible(terminal: true, electron: true) == .skip("terminal"), "never a terminal")
        expect(eligible(electron: true) == .probe && eligible(electron: true, chromium: true, setter: true) == .probe,
               "Claude, Slack and other Electron apps are measured, never learned from, until proven")
        expect(eligible(chromium: true, setter: false) == .probe && eligible(chromium: true, setter: true) == .learn,
               "a browser's plain field (the set moved it) learns; a web editor where the set did nothing is measured")
        func stop(_ elapsed: TimeInterval = 10, reads: Int = 0, running: Bool = true, secure: Bool = false, focused: Bool = true, n: Int? = 100) -> L.Stop? {
            L.stop(elapsed: elapsed, reads: reads, appRunning: running, secure: secure, focused: focused, fieldCharacters: n)
        }
        expect(stop() == nil && stop(179.9) == nil && stop(180) == .cap && stop(600) == .cap, "until focus leaves, three minutes at most")
        expect(stop(reads: 19) == nil && stop(reads: 20) == .reads, "twenty reads at most")
        expect(stop(focused: false) == .focusLeft && stop(n: 0) == .emptied && stop(n: nil) == .unreadable && stop(running: false) == .appGone,
               "focus left, the message was sent, the field went unreadable, the app quit")
        expect(stop(secure: true) == .secure && stop(600, reads: 30, running: false, secure: true, focused: false, n: 0) == .secure,
               "secure input ends the watch before anything else")
        expect(L.readLength(baselineLength: 300, baselineCharacters: 1000, currentCharacters: 1010, start: 700) == 310
               && L.readLength(baselineLength: 300, baselineCharacters: 1000, currentCharacters: 990, start: 700) == 290
               && L.readLength(baselineLength: 300, baselineCharacters: 1000, currentCharacters: 1010, start: 900) == 110
               && L.readLength(baselineLength: 300, baselineCharacters: 1000, currentCharacters: 500, start: 700) == 0,
               "the read covers the baseline's text plus what the field gained, clipped to the field")
        let page = "Hi. " + said + ". Bye."
        expect(DictationReplace.holds(page, at: 4, said) && !DictationReplace.holds(page, at: 3, said) && !DictationReplace.holds(page, at: 0, "")
               && !DictationReplace.holds(page, at: 30, said), "a watch starts only where the window holds exactly what COS typed")
        expect(L.track(baseline: page, current: page, start: 4, length: 38) == .unchanged, "nothing changed")
        expect(L.track(baseline: page, current: "Hi. " + fixed + ". Bye.", start: 4, length: 38)
               == .inside(Edit(location: 22, length: 11, original: "Y joule 360", replacement: "Jewel360"), length: 35),
               "Miles's fix, inside the dictation, relative to its start")
        expect(L.track(baseline: page, current: page + " More", start: 4, length: 38) == .moved(start: 4, length: 38), "typing after it")
        expect(L.track(baseline: page, current: "Hey " + page, start: 4, length: 38) == .moved(start: 8, length: 38)
               && L.track(baseline: page, current: "Yo. " + said + ". Bye.", start: 4, length: 38) == .moved(start: 4, length: 38),
               "typing or editing before it moves it")
        expect(L.track(baseline: page, current: "Hello, redirecting into this uh Y joule 360 page. Bye.", start: 4, length: 38) == .lost,
               "an edit across its edge loses it")
        let editEnglish: Set<String> = ["redirect", "into", "this", "uh", "joule", "page", "the", "deck", "slides", "complement", "compliment", "its", "it's", "ios"]
        func learn(_ heard: String, _ written: String, learned: Bool = false) -> L.Candidate? {
            L.candidate(Edit(location: 0, length: heard.utf16.count, original: heard, replacement: written),
                        known: { editEnglish.contains($0.lowercased()) }, learned: { _, _ in learned })
        }
        expect(learn("Y joule 360", "Jewel360") == .init(heard: "Y joule 360", written: "Jewel360")
               && learn("joule 360,", "Jewel360,") == .init(heard: "joule 360", written: "Jewel360"), "Miles's fix is learned, without punctuation at the edges")
        expect(learn("yellow fanduna", "yellowfin tuna") != nil && learn("gina", "Gina") != nil && learn("ios", "iOS") != nil,
               "a sound-alike re-spelling, a name's capital, a capital inside a word")
        expect(learn("the", "The") == nil, "a sentence's first capital is not a correction")
        expect(learn("its", "it's") == nil && learn("jewel360", "jewel-360") == nil, "a punctuation fix is not a correction, known word or not")
        expect(learn("complement", "compliment") == nil, "two plain English words is a homophone or grammar fix")
        expect(learn("the deck", "the slides") == nil && learn("cat", "dog") == nil, "a rewording is not a mishearing")
        expect(learn("one two three fore", "one two three four") == nil && learn("", "very") == nil && learn("very", "") == nil,
               "more than three words, an insertion, a deletion")
        expect(learn("Y joule\n360", "Jewel360") == nil, "never across a line break")
        expect(learn("Y joule 360", "Jewel360", learned: true) == nil, "already in the dictionary")
        // Suggest only keeps a week; dismissed and undone pairs stay quiet for 30 days.
        typealias S = DictationSuggestions
        let now = Date(timeIntervalSince1970: 1_760_600_000)
        func item(_ heard: String, _ written: String, age: TimeInterval = 0) -> DictationSuggestion {
            DictationSuggestion(id: UUID(), heard: heard, written: written, app: "Notes", at: now.addingTimeInterval(-age))
        }
        let week = 7 * 86_400.0
        let young = item("joule 360", "Jewel360", age: week - 60), old = item("bottle pause", "Bottle POS", age: week)
        let pruned = S.pruned(S.State(suggestions: [young, old]), now: now)
        expect(pruned.suggestions == [young], "a suggestion lasts seven days, not one second more")
        let s1 = item("joule 360", "Jewel360"), s2 = item("Joule 360", "Jewel360")
        var state = S.suggesting(s1, in: S.State(), now: now)
        state = S.suggesting(s2, in: state, now: now)
        expect(state.suggestions == [s2], "the same pair again replaces the older row")
        let other = item("carrot iq", "CaratIQ")
        state = S.suggesting(other, in: state, now: now)
        let applied = S.applying([s2.id], in: state, now: now)
        expect(applied.suggestions == [other] && applied.learned == [s2], "Add moves a suggestion onto the learned list")
        let all = S.applying(Set(state.suggestions.map(\.id)), in: state, now: now)
        expect(all.suggestions.isEmpty && all.learned.count == 2, "Add all applies every suggestion")
        let dismissed = S.dismissing(other.id, in: state, now: now)
        expect(dismissed.suggestions == [s2] && dismissed.dismissed[S.key("carrot iq", "CaratIQ")] == now, "Dismiss removes it and remembers the pair")
        expect(S.suggesting(item("Carrot IQ", "CaratIQ"), in: dismissed, now: now.addingTimeInterval(86_400)).suggestions.map(\.heard) == ["Joule 360"]
               // Stamped on day 29 too: one stamped day 0 is pruned for age, so empty would hold with dismissal broken.
               && S.suggesting(item("Carrot IQ", "CaratIQ", age: -29 * 86_400), in: dismissed, now: now.addingTimeInterval(29 * 86_400)).suggestions.isEmpty
               // The day-30 suggestion is made on day 30 (age -30 days); one stamped day 0 would already be past its week.
               && S.suggesting(item("Carrot IQ", "CaratIQ", age: -30 * 86_400), in: dismissed, now: now.addingTimeInterval(30 * 86_400)).suggestions.map(\.heard) == ["Carrot IQ"],
               "a dismissed pair is not offered again for 30 days")
        let auto = S.learning(item("joule 360", "Jewel360"), in: S.State(suggestions: [s1]), now: now)
        expect(auto.learned.count == 1 && auto.suggestions.isEmpty, "Save automatically puts it on the learned list and clears the same suggestion")
        let undone = S.dismissing(auto.learned[0].id, in: auto, now: now)
        expect(undone.learned.isEmpty && undone.dismissed[S.key("joule 360", "Jewel360")] == now
               && S.isQuiet("Joule 360", "Jewel360", in: undone, now: now) && !S.isQuiet("joule 360", "Jewel360", in: auto, now: now)
               && !S.isQuiet("joule 360", "Jewel360", in: undone, now: now.addingTimeInterval(30 * 86_400))
               && S.suggesting(item("joule 360", "Jewel360"), in: undone, now: now).suggestions.isEmpty,
               "Undo takes it off the learned list and keeps it from being saved or suggested again for 30 days")
        expect(S.pruned(S.State(learned: [item("a b", "AB", age: 30 * 86_400)]), now: now).learned.isEmpty, "learned rows go after 30 days")
        let recentRows: [(id: String, heard: String, written: String)] = [("r3", "joule 360", "Jewel 360"), ("r2", "joule 360", "Jewel360"),
                                                                             ("r1", "joule 360", "Jewel360"), ("r0", "x", "y")]
        expect(S.recentID(for: auto.learned[0], in: recentRows) == "r2" && S.recentID(for: item("q", "Q"), in: recentRows) == nil,
               "Undo reverses the newest dictionary entry with that pair, and none other")
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cos-suggestions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("dictation-suggestions.json")
        try S.save(applied, to: file)
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        expect(S.load(from: file, now: now) == applied && mode == 0o600, "suggestions round-trip in a private file")
        expect(S.load(from: file, now: now.addingTimeInterval(week)).suggestions.isEmpty, "a week later the suggestions load expired")
        expect(KnownApps.isElectron(frameworks: ["Electron Framework.framework"]) && KnownApps.isElectron(frameworks: ["Chromium Embedded Framework.framework"])
               && !KnownApps.isElectron(frameworks: ["Google Chrome Framework.framework"]) && KnownApps.isChromiumFamily(frameworks: ["Google Chrome Framework.framework"]),
               "Electron apps are told apart from Chromium browsers")
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
        // 0.5.315 mute tap: muted only when every step ran; a failure at any step tears down exactly what exists, in reverse.
        var ran: [DictationMuteTap.Step] = []
        let full = DictationMuteTap.build { ran.append($0); return 0 }
        expect(full.failure == nil && full.built.muting && ran == DictationMuteTap.Step.allCases, "every step runs in order and the result is muting")
        expect(DictationMuteTap.teardown(full.built) == [.stop, .destroyIOProc, .destroyAggregate, .destroyTap],
               "teardown: stop the IO, then the IOProc, the aggregate, the tap")
        let expected: [DictationMuteTap.Step: [DictationMuteTap.Teardown]] = [
            .tap: [], .tapUID: [.destroyTap], .aggregate: [.destroyTap], .ioProc: [.destroyAggregate, .destroyTap],
            .start: [.destroyIOProc, .destroyAggregate, .destroyTap],
        ]
        for failing in DictationMuteTap.Step.allCases {
            ran = []
            let result = DictationMuteTap.build { step in ran.append(step); return step == failing ? -50 : 0 }
            expect(result.failure == .init(step: failing, status: -50) && !result.built.muting && ran.last == failing,
                   "a failure at \(failing) is reported with its status, is not muting, and no later step runs")
            expect(DictationMuteTap.teardown(result.built) == expected[failing], "a failure at \(failing) tears down exactly what exists")
        }
        expect(DictationMuteTap.teardown(.init()).isEmpty, "a second end() has nothing to tear down")
        expect(DictationMuteTap.keepOnOutputChange(mutedOn: "BuiltInSpeakerDevice", now: "BuiltInSpeakerDevice")
               && !DictationMuteTap.keepOnOutputChange(mutedOn: "BuiltInSpeakerDevice", now: "AirPods")
               && !DictationMuteTap.keepOnOutputChange(mutedOn: "BuiltInSpeakerDevice", now: nil),
               "a different (or no) default output ends the mute; the same one keeps it")
        // The real IOProc, EXECUTED off the main thread the way the HAL calls it: measures the tapped peak, writes silence.
        let meter = DictationMuteMeter()
        let io = DictationMuteIO.silence(meter)
        let tapped = UnsafeMutablePointer<Float>.allocate(capacity: 4), speaker = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        let inList = AudioBufferList.allocate(maximumBuffers: 1), outList = AudioBufferList.allocate(maximumBuffers: 1)
        let stamp = UnsafeMutablePointer<AudioTimeStamp>.allocate(capacity: 1)
        defer { tapped.deallocate(); speaker.deallocate(); free(inList.unsafeMutablePointer); free(outList.unsafeMutablePointer); stamp.deallocate() }
        for (index, value) in [Float(0.1), -0.7, 0.3, 0.2].enumerated() { tapped[index] = value; speaker[index] = 0.5 }
        stamp.initialize(to: AudioTimeStamp())
        inList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: tapped)
        outList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: speaker)
        nonisolated(unsafe) let input = inList.unsafePointer, output = outList.unsafeMutablePointer, time = UnsafePointer(stamp)
        let ioDone = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ranOffMain = false
        Thread { ranOffMain = !Thread.isMainThread; for _ in 0..<2 { io(time, input, time, output, time) }; ioDone.signal() }.start()
        ioDone.wait()
        expect(ranOffMain, "the IOProc check ran off the main thread")
        expect(meter.reading() == .init(callbacks: 2, peak: 0.7) && (0..<4).allSatisfy { speaker[$0] == 0 },
               "the IOProc counts each callback, keeps the tapped peak and outputs silence")
        // Media: never a blind play/pause key.
        expect(DictationMedia.decide(playing: nil) == .leave && DictationMedia.decide(playing: false) == .leave && DictationMedia.decide(playing: true) == .pause,
               "pause only a known, playing state; unknown is left alone")
        }
        // 0.5.317 dictation for everyone: each failure's one action, and Retry only when it can work.
        typealias A = DictationFailureAction
        expect(A.resolve(action: "install_parakeet", retryable: false, noSpeech: false, audioHeld: true) == .installParakeet, "server action: Install Parakeet")
        expect(A.resolve(action: "use_whisper", retryable: false, noSpeech: false, audioHeld: true) == .useWhisper, "server action: Use Whisper")
        expect(A.resolve(action: "open_transcription_settings", retryable: false, noSpeech: false, audioHeld: true) == .openTranscriptionSettings, "server action: Open Transcription settings")
        expect(A.resolve(action: "retry", retryable: true, noSpeech: false, audioHeld: true) == .retry, "a retry the server says can succeed, with the audio held")
        expect(A.resolve(action: "retry", retryable: false, noSpeech: false, audioHeld: true) == .openTranscriptionSettings, "never Retry when the server says it cannot succeed")
        expect(A.resolve(action: "retry", retryable: true, noSpeech: false, audioHeld: false) == .none, "never Retry without the audio")
        expect(A.resolve(action: nil, retryable: nil, noSpeech: false, audioHeld: true) == .retry, "a failure COS raised retries the held audio")
        expect(A.resolve(action: nil, retryable: nil, noSpeech: false, audioHeld: false) == .none, "nothing held, nothing to retry")
        expect(A.resolve(action: "install_parakeet", retryable: true, noSpeech: true, audioHeld: true) == .none, "no speech offers nothing")
        expect(A.resolve(action: "format_disk", retryable: true, noSpeech: false, audioHeld: true) == .retry, "an unknown action is COS's own")
        expect(A.installParakeet.title == "Install Parakeet (654 MB)" && A.useWhisper.title == "Use Whisper" && A.openTranscriptionSettings.title == "Open Transcription settings"
               && A.retry.title == "Retry" && A.none.title == nil, "button titles name what happens")
        expect(DictationEngineName.detailLine(engine: "parakeet-ultra", fallbackReason: nil) == "Transcribed on this Mac with Parakeet Ultra.", "history names Parakeet Ultra")
        expect(DictationEngineName.detailLine(engine: "whisper", fallbackReason: "parakeet_warming") == "Transcribed on this Mac with Whisper, because Parakeet Ultra was warming up.",
               "history says why Automatic used Whisper")
        expect(DictationEngineName.detailLine(engine: "whisper", fallbackReason: nil) == "Transcribed on this Mac with Whisper.", "Whisper by choice")
        expect(DictationEngineName.detailLine(engine: nil, fallbackReason: nil) == nil && DictationEngineName.title("openai") == nil, "no engine line for an old record or an unknown engine")
        for reason in ["parakeet_not_installed", "parakeet_warming", "parakeet_warm_failed", "parakeet_breaker_open", "parakeet_busy", "parakeet_failed", "audio_not_pcm_wav"] {
            let line = DictationEngineName.detailLine(engine: "whisper", fallbackReason: reason) ?? ""
            expect(line.hasPrefix("Transcribed on this Mac with Whisper, because ") && !line.contains("\u{2014}"), "every fallback reason reads as a sentence: \(reason)")
        }
        // The engine survives the history file, and a 0.5.316 record (no engine) still loads.
        let engineRecord = DictationRecord(id: UUID(), text: "ask not", createdAt: Date(timeIntervalSince1970: 1_760_000_000), delivery: .inserted(app: "Notes"),
                                           engine: "whisper", fallbackReason: "parakeet_busy")
        let roundTrip = try JSONDecoder().decode(DictationRecord.self, from: JSONEncoder().encode(engineRecord))
        expect(roundTrip == engineRecord && roundTrip.engine == "whisper" && roundTrip.fallbackReason == "parakeet_busy", "the engine is saved with the dictation")
        let legacyRecord = try JSONDecoder().decode(DictationRecord.self, from: Data(#"{"id":"5A0C2A3C-6A7B-4C8D-9E0F-1A2B3C4D5E6F","text":"old","createdAt":0,"kind":"inserted","app":"Notes"}"#.utf8))
        expect(legacyRecord.engine == nil && legacyRecord.text == "old", "a record from before 0.5.317 loads without an engine")
        expect(DictationHistory.correcting(engineRecord.id, to: "ask now", in: [engineRecord]).first?.engine == "whisper", "Fix a word keeps the engine")
        do {
            typealias EL = DictationEditLearning
            typealias DS = DictationSuggestions
            let at0 = Date(timeIntervalSince1970: 1_760_600_000)
            // 0.5.323 (Miles, 2026-10-17): the text around a dictation is evidence for Learn from my edits. A spelling that is
            // also in the same field outside the dictation counts below the sound-alike threshold, down to the floor.
            let plainWords: Set<String> = ["graph", "ton", "nile", "a", "ah", "the", "budget", "bottle", "market", "comma", "joule", "email", "about"]
            func edited(_ heard: String, _ written: String, outside: [String] = []) -> EL.Candidate? {
                EL.candidate(DictationReplace.Edit(location: 0, length: heard.utf16.count, original: heard, replacement: written),
                            known: { plainWords.contains($0.lowercased()) }, learned: { _, _ in false }, outside: outside)
            }
            let prompt = ["Prompt: email Nicole Grafton about the referral, and Niala, Marktpos and Bottle POS. Mention Ukaoma."]
            expect(DictationLearnEvidence.nearbyText.words == "Also in the text around your dictation", "the evidence reads as words")
            expect(edited("graph ton", "Grafton", outside: prompt) == .init(heard: "graph ton", written: "Grafton", evidence: .nearbyText)
                   && edited("graph ton", "Grafton") == nil,
                   "a spelling in the text you dropped in qualifies below the sound-alike threshold, and only with that evidence")
            expect(edited("Nile a", "Niala", outside: prompt) == .init(heard: "Nile a", written: "Niala", evidence: .nearbyText)
                   && edited("Nile ah", "Niala", outside: prompt) == nil, "the floor is 0.6 and includes 0.6 (\"Nile a\" scores exactly 0.6, \"Nile ah\" 0.5)")
            expect(edited("the budget", "Bottle POS", outside: prompt) == nil, "an unrelated rewrite never qualifies, evidence or not")
            expect(edited("Ukomma", "comma", outside: ["a comma here"]) == nil, "a plain English spelling is not a dictionary term, evidence or not")
            expect(edited("market", "Marktpos", outside: prompt) == nil, "one plain word never learns a below-threshold spelling: it would rewrite every \"market\"")
            expect(edited("Ukoma", "Ukaoma", outside: prompt) == .init(heard: "Ukoma", written: "Ukaoma", evidence: .nearbyText)
                   && edited("Ukoma", "Ukaoma") == .init(heard: "Ukoma", written: "Ukaoma"), "a sound-alike that qualifies anyway carries the evidence when there is some")
            // 0.5.334: the server's correction-only note, shown plain or not at all.
            let serverNote = "Saved as a correction. Links, emails and paths are never added to the words that guide transcription, so COS rewrites what it hears instead."
            expect(DictionaryLearnNote.line(correctionOnly: true, note: "  " + serverNote + " ") == serverNote, "a correction-only learn shows the server's note")
            expect(DictionaryLearnNote.line(correctionOnly: false, note: serverNote) == nil && DictionaryLearnNote.line(correctionOnly: nil, note: serverNote) == nil
                   && DictionaryLearnNote.line(correctionOnly: true, note: nil) == nil && DictionaryLearnNote.line(correctionOnly: true, note: "  ") == nil,
                   "no note unless the answer is correction-only and carries one")
            expect(DictionaryLearnNote.line(correctionOnly: true, note: "Saved \u{2014} kept") == nil && DictionaryLearnNote.line(correctionOnly: true, note: "a \u{2192} b") == nil
                   && DictionaryLearnNote.line(correctionOnly: true, note: "two\nlines") == nil
                   && DictionaryLearnNote.line(correctionOnly: true, note: String(repeating: "a", count: DictionaryLearnNote.maximumLength + 1)) == nil
                   && DictionaryLearnNote.line(correctionOnly: true, note: String(repeating: "a", count: DictionaryLearnNote.maximumLength)) != nil,
                   "a note with an em dash, an arrow, a line break or past the length is not shown")
            // 0.5.334 (Miles, 2026-10-21): the written side keeps what a link, handle or file name starts with, and loses
            // only trailing punctuation. Before, "/pricing" was learned as "pricing" and "@Ukaoma" as "Ukaoma".
            for mark in ["/", "\\", "@", "#", "~", "."] {
                expect(edited("Ukoma", mark + "Ukaoma")?.written == mark + "Ukaoma", "a leading \(mark) stays on the written side")
            }
            expect(edited("Ukoma", "(Ukaoma).")?.written == "Ukaoma" && edited("Ukoma", "\u{201C}Ukaoma\u{201D},")?.written == "Ukaoma",
                   "a bracket or quote the edit picked up still goes, and trailing punctuation goes")
            expect(edited("Ukoma", "/Ukaoma/.")?.written == "/Ukaoma" && edited("Ukoma", "@Ukaoma:")?.written == "@Ukaoma",
                   "trailing punctuation goes after a kept leading mark too")
            expect(edited("Ukoma", "Ukaoma++")?.written == "Ukaoma++" && edited("Ukoma", "Ukaoma\u{2122}")?.written == "Ukaoma\u{2122}",
                   "a trailing symbol is part of the spelling (C++, a trademark)")
            expect(edited("Ukoma", "$Ukaoma")?.written == "Ukaoma", "a leading symbol outside the kept marks still goes")
            expect(edited("slash", "/") == nil && edited("Ukoma", " / ") == nil, "a mark with no word is never learned")
            expect(EL.writtenSide(" /pricing, ") == "/pricing" && EL.writtenSide("\"#launch\"") == "#launch" && EL.writtenSide("...") == "",
                   "writtenSide keeps the lead mark and drops the rest of the edge")
            expect(EL.evidence(written: "Jewel360", outside: ["see Jewel360's site"]) == .nearbyText && EL.evidence(written: "Jewel360", outside: ["(Jewel360)"]) == .nearbyText
                   && EL.evidence(written: "Jewel360", outside: ["Jewel3600 and xJewel360"]) == nil && EL.evidence(written: "Jewel360", outside: ["jewel360"]) == nil
                   && EL.evidence(written: "Jewel360", outside: []) == nil && EL.evidence(written: "", outside: ["x"]) == nil,
                   "evidence is the exact spelling on word boundaries")
            let around = "Draft for Jewel360: uh Jewel360 page"
            expect(EL.outside(window: around, start: 20, length: 16) == ["Draft for Jewel360: "] && EL.outside(window: around, start: 0, length: 36).isEmpty
                   && EL.outside(window: "abc DICT xyz", start: 4, length: 4) == ["abc ", " xyz"] && EL.outside(window: "abc", start: 9, length: 4) == ["abc"],
                   "outside is the window before and after the dictation, clipped")
            expect(EL.evidence(written: "Jewel360", outside: EL.outside(window: "uh Jewel360 page", start: 0, length: 16)) == nil,
                   "the dictation itself is never its own evidence")
            expect(EL.eligibility(mode: .automatic, secure: true, terminal: false, electron: false, chromium: false, setterWorked: true) == .skip("secure")
                   && EL.eligibility(mode: .suggest, secure: false, terminal: true, electron: false, chromium: false, setterWorked: true) == .skip("terminal")
                   && DictationFieldContext.plan(enabled: true, secure: true, terminal: false, fieldCharacters: 500, location: 10, length: 0) == .skip("password field or secure input")
                   && DictationFieldContext.plan(enabled: true, secure: false, terminal: true, fieldCharacters: 500, location: 10, length: 0) == .skip("terminal scrollback"),
                   "secure fields and terminals give no evidence: no watch, and no context read")
            let fix = DictationFieldContext.Fix(heard: "Ukoma", written: "Ukaoma")
            expect(EL.undoesContextFix(.init(heard: "Ukaoma", written: "Ukoma"), fixes: [fix]) && EL.undoesContextFix(.init(heard: "ukaoma", written: "ukoma"), fixes: [fix])
                   && EL.undoesContextFix(.init(heard: "Ukaoma", written: "Okoma"), fixes: [fix]) && EL.undoesContextFix(.init(heard: "Ukaoma Smith", written: "UkaomaSmith"), fixes: [fix])
                   && !EL.undoesContextFix(.init(heard: "Ukoma", written: "Ukaoma"), fixes: [fix]) && !EL.undoesContextFix(.init(heard: "graph ton", written: "Grafton"), fixes: [fix])
                   && !EL.undoesContextFix(.init(heard: "Ukaoma", written: "Ukoma"), fixes: []),
                   "an edit of words COS spelled from the field, back or onward, is never learned: its heard side is COS's guess")
            // The suggestion keeps its evidence: on disk, from an older file, and when the same pair comes back without it.
            let evidenced = DictationSuggestion(id: UUID(), heard: "graph ton", written: "Grafton", app: "Claude", at: at0, evidence: .nearbyText)
            let iso = JSONEncoder(); iso.dateEncodingStrategy = .iso8601
            let isoIn = JSONDecoder(); isoIn.dateDecodingStrategy = .iso8601
            expect(try isoIn.decode(DictationSuggestion.self, from: iso.encode(evidenced)) == evidenced, "evidence is saved with the suggestion")
            let older = try isoIn.decode(DictationSuggestion.self, from: Data(#"{"id":"5A0C2A3C-6A7B-4C8D-9E0F-1A2B3C4D5E6F","heard":"a","written":"A1","app":"Notes","at":"2026-10-16T10:00:00Z"}"#.utf8))
            let future = try? isoIn.decode(DictationSuggestion.self, from: Data(#"{"id":"5A0C2A3C-6A7B-4C8D-9E0F-1A2B3C4D5E6F","heard":"a","written":"A1","app":"Notes","at":"2026-10-16T10:00:00Z","evidence":"screen"}"#.utf8))
            expect(older.evidence == nil && older.written == "A1" && future?.evidence == nil && future?.written == "A1",
                   "a 0.5.318 suggestion loads without evidence, and an evidence kind this build does not know reads as none")
            let again = DictationSuggestion(id: UUID(), heard: "graph ton", written: "Grafton", app: "Notes", at: at0)
            let twice = DS.suggesting(again, in: DS.suggesting(evidenced, in: DS.State(), now: at0), now: at0)
            expect(twice.suggestions.count == 1 && twice.suggestions[0].id == again.id && twice.suggestions[0].evidence == .nearbyText,
                   "the same pair again keeps the evidence an earlier sighting had")
            let relearned = DS.learning(again, in: DS.learning(evidenced, in: DS.State(), now: at0), now: at0)
            expect(relearned.learned.count == 1 && relearned.learned[0].evidence == .nearbyText, "a pair saved again keeps its evidence")
            expect(DS.applying([evidenced.id], in: DS.suggesting(evidenced, in: DS.State(), now: at0), now: at0).learned.first?.evidence == .nearbyText,
                   "Add moves the evidence with the suggestion")
            // Insert-time context (0.5.323): read a bounded part of the field, never a password field or a terminal.
            typealias FC = DictationFieldContext
            func contextPlan(_ n: Int?, _ at: Int?, _ selected: Int? = 0, enabled: Bool = true) -> FC.Plan {
                FC.plan(enabled: enabled, secure: false, terminal: false, fieldCharacters: n, location: at, length: selected)
            }
            expect(contextPlan(500, 10, enabled: false) == .skip("off") && contextPlan(nil, 3) == .skip("unmeasured") && contextPlan(500, nil) == .skip("unmeasured")
                   && contextPlan(0, 0) == .skip("empty"), "off, unmeasured and empty fields are typed as heard")
            expect(FC.plan(enabled: true, secure: true, terminal: true, fieldCharacters: 500, location: 10, length: 0) == .skip("password field or secure input"),
                   "secure is checked first")
            expect(contextPlan(100, 40) == .read(before: .init(location: 0, length: 40), after: .init(location: 40, length: 60)), "a short field is read whole")
            expect(contextPlan(100, 40, 10) == .read(before: .init(location: 0, length: 40), after: .init(location: 50, length: 50)),
                   "selected text is about to be replaced, so it is not context")
            expect(contextPlan(100_000, 50_000, 10) == .read(before: .init(location: 47_000, length: 3_000), after: .init(location: 50_010, length: 1_000))
                   && contextPlan(10_000, 0) == .read(before: .init(location: 0, length: 0), after: .init(location: 0, length: 4_000))
                   && contextPlan(10_000, 10_000) == .read(before: .init(location: 7_000, length: 3_000), after: .init(location: 10_000, length: 0))
                   && contextPlan(100, 90, 50) == .read(before: .init(location: 0, length: 90), after: .init(location: 100, length: 0)),
                   "at most 3,000 before the caret and 4,000 in all, clipped to the field")
            for (n, at, selected) in [(5_000, 2_000, 0), (9_999, 9_000, 500), (3_000, 3_000, 0), (40_000, 1_000, 30_000), (4_001, 4_000, 1)] {
                if case .read(let b, let a) = contextPlan(n, at, selected) {
                    expect(b.length + a.length <= FC.maximumCharacters && b.location >= 0 && a.location + a.length <= n, "the read stays bounded: \(n) \(at) \(selected)")
                } else { expect(false, "a measured field is read: \(n) \(at) \(selected)") }
            }
            expect(FC.inBudget(elapsed: 0.3) && !FC.inBudget(elapsed: 0.301), "a read slower than 0.3 s is dropped and the dictation typed as heard")
            let englishWords: Set<String> = ["thanks", "ping", "please", "and", "cloud", "apple", "receive", "joule", "hub", "spot", "a", "the", "see", "you",
                                             "to", "save", "it", "my", "phone", "call", "y", "we", "met", "today", "smith", "international", "team"]
            let known: (String) -> Bool = { englishWords.contains($0.lowercased()) }
            let field = FC.Read(before: "Thanks, this is Miles Ukaoma from Quilt. Ping Jewel360 and HubSpot about the COS rollout.\nRecieve the recieve file at Docs/HubSpot",
                               after: " or https://Quilt.com/x, a@b.com, 3pm, 2nd, 4BIS, Ukaoma's notes", beforeCut: false, afterCut: false)
            let found = FC.terms(in: field, known: known)
            expect(found.map(\.text) == ["Ukaoma", "Miles", "Quilt", "Jewel360", "HubSpot", "COS", "Recieve", "4BIS"],
                   "distinctive words, most frequent first: names mid-sentence, unknown names, capitals inside, letters with digits, acronyms; got \(found.map(\.text))")
            expect(found.filter(\.strong).map(\.text) == ["Jewel360", "HubSpot", "4BIS"], "only a capital inside or letters with digits is spelled on purpose")
            expect(FC.terms(in: FC.Read(before: "met recieve ukaoma", after: ""), known: known).isEmpty, "a lowercase word is never a term, known or not")
            expect(FC.terms(in: FC.Read(before: "Kaoma Sokolic said", after: " and Nia", beforeCut: true, afterCut: true), known: known).map(\.text) == ["Sokolic"],
                   "a word cut by the bounded read is not a word of the field")
            expect(FC.terms(in: FC.Read(before: "we met Ukao", after: "ma today"), known: known).isEmpty, "a caret inside a word splits it: neither half counts")
            let many = (0..<70).map { "Term\($0)X" }
            let ranked = FC.terms(in: FC.Read(before: many.joined(separator: " ") + " Term69X Term69X Term5X", after: ""), known: known)
            expect(ranked.count == FC.maximumTerms && ranked.prefix(2).map(\.text) == ["Term69X", "Term5X"] && ranked[2].text == "Term0X",
                   "at most 64 terms, the most frequent first, then in order")
            // Corrections at insert time: the field's terms spell what was misheard, and nothing else.
            let terms = [FC.Term(text: "Ukaoma", strong: false), FC.Term(text: "Jewel360", strong: true), FC.Term(text: "HubSpot", strong: true),
                         FC.Term(text: "iCloud", strong: true), FC.Term(text: "Andy", strong: false), FC.Term(text: "Claude", strong: false),
                         FC.Term(text: "Recieve", strong: false), FC.Term(text: "Apple", strong: false), FC.Term(text: "Niala", strong: false),
                         FC.Term(text: "Nyala", strong: false), FC.Term(text: "COS", strong: false), FC.Term(text: "UkomaSmith", strong: true)]
            func fixes(_ text: String, _ with: [FC.Term]? = nil) -> (text: String, fixes: [FC.Fix]) { FC.corrected(text, terms: with ?? terms, known: known) }
            expect(fixes("Thanks Ukoma, see you.") == ("Thanks Ukaoma, see you.", [FC.Fix(heard: "Ukoma", written: "Ukaoma")]),
                   "Ukoma becomes Ukaoma when the field has Ukaoma")
            expect(fixes("Thanks Ukoma, see you.", terms.filter { $0.text != "Ukaoma" }) == ("Thanks Ukoma, see you.", []), "and stays Ukoma when it does not")
            expect(fixes("Thanks Ukoma.", []) == ("Thanks Ukoma.", []), "no terms, no change")
            expect(fixes("Y joule 360 page") == ("Y Jewel360 page", [FC.Fix(heard: "joule 360", written: "Jewel360")])
                   && fixes("ping hub spot today").text == "ping HubSpot today", "plain words become a term spelled on purpose, best match first")
            expect(fixes("save it to the cloud").fixes.isEmpty && fixes("call my phone and see").fixes.isEmpty && fixes("receive Apple and apple").fixes.isEmpty,
                   "one plain word never becomes iCloud, Andy, Claude, Recieve or Apple")
            expect(fixes("ukaoma said").text == "Ukaoma said" && fixes("cos said").text == "COS said", "a change of capitals for a word the spell checker does not know")
            expect(fixes("Ukaoma and Nyala").fixes.isEmpty && fixes("Ukaoma and Nyala").text == "Ukaoma and Nyala", "a word the field already has exactly stays as it is")
            expect(fixes("the international 5 team", [FC.Term(text: "Internationale", strong: false)]).fixes.isEmpty
                   && fixes("the international 5 team", [FC.Term(text: "International5", strong: true)]).text == "the International5 team",
                   "a number is a plain word: plain words and a number become only a term spelled on purpose (\"international 5\" scores 0.93)")
            expect(fixes("Nyalla came", [FC.Term(text: "Niala", strong: false)]).fixes.isEmpty, "below the threshold nothing changes (\"Nyalla\" scores 0.67 against \"Niala\")")
            expect(fixes("joule\n360").fixes.isEmpty && fixes("joule, 360").fixes.isEmpty && fixes("joule - 360").fixes.isEmpty,
                   "never across a line break or a mark between words")
            expect(fixes("(Ukoma). and \"Ukoma\"").text == "(Ukaoma). and \"Ukaoma\"", "punctuation at either end stays")
            expect(fixes("a Ukoma here").text == "a Ukaoma here", "a tie goes to the narrower span, so a neighbour is never swallowed")
            expect(fixes("Ukoma Smith wrote").text == "UkomaSmith wrote", "the better match wins over a narrower weaker one")
            let long = Array(repeating: "Ukoma", count: FC.maximumWords + 1).joined(separator: " ")
            expect(fixes(long).fixes.isEmpty && fixes(Array(repeating: "Ukoma", count: FC.maximumWords).joined(separator: " ")).fixes.count == FC.maximumWords,
                   "a dictation over 800 words is typed as heard; up to 800, every word is checked")
            // Server dictionary suggestions (server 6.77.0): the seam decodes the contract and checks the capability only.
            typealias SV = DictationServerSuggestions
            expect(SV.validID("sug_0123456789abcdef") && !SV.validID("sug_0123456789ABCDEF") && !SV.validID("sug_0123456789abcde")
                   && !SV.validID("sug_../../../x/abcde") && !SV.validID("xyz_0123456789abcdef"), "only sug_ and 16 hex digits")
            expect(SV.available(capabilities: Data(#"{"transcriptCleanup":{"protocol":1,"suggestions":1,"screenContext":1}}"#.utf8))
                   && !SV.available(capabilities: Data(#"{"engines":[]}"#.utf8)) && !SV.available(capabilities: Data(#"{"transcriptCleanup":{"protocol":2,"suggestions":1}}"#.utf8))
                   && !SV.available(capabilities: Data("not json".utf8)), "suggestions only from a server that advertises protocol 1")
            let listed = SV.list(Data(#"""
            {"protocol":1,"suggestions":[
              {"id":"sug_0123456789abcdef","written":"Ukaoma","heard":["Ukoma","Yukoma"],"status":"pending","count":3,"createdAt":"2026-10-17T10:00:00Z",
               "updatedAt":"2026-10-17T11:00:00Z","inVocabulary":false,"evidence":[{"source":"screen","sessionId":"s1","heard":"Ukoma","at":"2026-10-17T11:00:00Z","detail":"Zoom"}]},
              {"id":"bad","written":"X","heard":[],"status":"pending","count":1,"inVocabulary":false,"evidence":[]},
              {"id":"sug_fedcba9876543210","written":"Broken"}
            ]}
            """#.utf8))
            expect(listed.count == 1 && listed[0].written == "Ukaoma" && listed[0].heard == ["Ukoma", "Yukoma"] && listed[0].count == 3
                   && listed[0].evidence.first?.source == "screen" && listed[0].evidence.first?.detail == "Zoom",
                   "the list decodes the contract and drops a bad id or a malformed row, not the list")
            let protocol2 = #"{"protocol":2,"suggestions":[{"id":"sug_0123456789abcdef","written":"Ukaoma","heard":["Ukoma"],"status":"pending","count":1,"inVocabulary":false,"evidence":[]}]}"#
            expect(SV.list(Data(protocol2.utf8)).isEmpty && SV.list(Data(protocol2.replacingOccurrences(of: #""protocol":2"#, with: #""protocol":1"#).utf8)).count == 1
                   && SV.list(Data("{}".utf8)).isEmpty, "another protocol reads as nothing, even with rows that would decode")
        }
        do {
            // 0.5.325 AI polish (Miles, 2026-10-18). Off by default; Claude's cleanup only within its budget; every failure
            // pastes what was heard; the history keeps what was heard only when polish changed it.
            typealias PM = DictationPolishModel
            typealias P = DictationPolish
            expect(PM.default == .off && PM.stored(nil) == .off && PM.stored("") == .off && PM.stored("opus") == .off,
                   "polish: off by default, and an unknown stored value is off")
            expect(PM.stored("haiku") == .haiku && PM.stored("sonnet") == .sonnet && PM.defaultsKey == "dictation.polishModel",
                   "polish: the chosen model is kept under dictation.polishModel")
            expect(PM.allCases.map(\.title) == ["Off", "Claude Haiku", "Claude Sonnet"] && PM.off.shortName == nil
                   && PM.haiku.shortName == "Haiku" && PM.sonnet.shortName == "Sonnet", "polish: the setting's choices and the history's names")
            expect(P.budget(for: .off) == nil && P.budget(for: .haiku) == 5 && P.budget(for: .sonnet) == 9,
                   "polish: COS waits 5 s for Haiku and 9 s for Sonnet (measured 2.3 to 3.4 s, a direct Sonnet call up to 7.6 s)")
            expect(!P.shouldPolish(text: "um so the thing", model: .off), "polish: off never polishes")
            expect(P.shouldPolish(text: "um so the thing", model: .haiku) && P.shouldPolish(text: "x", model: .sonnet), "polish: a chosen model polishes")
            expect(!P.shouldPolish(text: " \n ", model: .haiku) && !P.shouldPolish(text: "", model: .sonnet), "polish: nothing to polish in blank text")
            let atLimit = String(repeating: "a", count: 8_000), overLimit = String(repeating: "a", count: 8_001)
            expect(P.shouldPolish(text: atLimit, model: .haiku) && !P.shouldPolish(text: overLimit, model: .haiku),
                   "polish: up to 8,000 characters (the server's 413 limit), never over")
            // The server counts a JavaScript string: an emoji is two units, so 4,001 of them is over 8,000.
            expect(!P.shouldPolish(text: String(repeating: "😀", count: 4_001), model: .haiku) && P.shouldPolish(text: String(repeating: "😀", count: 4_000), model: .haiku),
                   "polish: the limit is counted in UTF-16 units, as the server counts")
            func decoded(_ data: Data?) -> [String: String]? { data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } }
            expect(decoded(P.request(text: "um hi", model: .haiku, app: " iTerm2 ")) == ["text": "um hi", "model": "haiku", "app": "iTerm2"],
                   "polish: the request is the text, the model and the app's name")
            expect(decoded(P.request(text: "um hi", model: .sonnet, app: nil)) == ["text": "um hi", "model": "sonnet"]
                   && decoded(P.request(text: "um hi", model: .sonnet, app: String(repeating: "A", count: 65))) == ["text": "um hi", "model": "sonnet"]
                   && decoded(P.request(text: "um hi", model: .sonnet, app: "Two\nlines")) == ["text": "um hi", "model": "sonnet"]
                   && decoded(P.request(text: "um hi", model: .sonnet, app: "  ")) == ["text": "um hi", "model": "sonnet"],
                   "polish: no app, a long app name, one with a line break or a blank one is left out")
            expect(P.request(text: "um hi", model: .off, app: "Notes") == nil, "polish: off sends nothing")
            let heard = "Um so the the plan is ready"
            expect(P.choose(heard: heard, ok: true, text: "So the plan is ready.", polished: true, reason: nil) == .applied("So the plan is ready."),
                   "polish: a polished answer is applied")
            expect(P.choose(heard: heard, ok: true, text: heard, polished: true, reason: nil) == .unchanged, "polish: the same text is unchanged")
            expect(P.choose(heard: heard, ok: true, text: "So the plan is ready.", polished: false, reason: nil) == .failed("not_polished")
                   && P.choose(heard: heard, ok: true, text: "So the plan is ready.", polished: nil, reason: nil) == .failed("not_polished"),
                   "polish: the server's dictionary-only fallback is not called polished")
            expect(P.choose(heard: heard, ok: true, text: "  \n", polished: true, reason: nil) == .failed("empty")
                   && P.choose(heard: heard, ok: true, text: nil, polished: true, reason: nil) == .failed("empty"), "polish: an empty answer is never pasted")
            // 27 characters heard: 27 x 1.5 + 40 = 80.5. 80 is a cleanup at the edge; 81 is a reply.
            expect(P.choose(heard: heard, ok: true, text: String(repeating: "b", count: 80), polished: true, reason: nil) == .applied(String(repeating: "b", count: 80))
                   && P.choose(heard: heard, ok: true, text: String(repeating: "b", count: 81), polished: true, reason: nil) == .failed("grew"),
                   "polish: an answer much longer than what was heard is pasted as heard")
            expect(P.choose(heard: heard, ok: false, text: "leaked text", polished: true, reason: "timeout") == .timeout,
                   "polish: the helper's timeout reads as a timeout")
            expect(P.choose(heard: heard, ok: false, text: "leaked text", polished: true, reason: "needs_server_update") == .failed("needs_server_update")
                   && P.choose(heard: heard, ok: false, text: "So it.", polished: true, reason: nil) == .failed("refused")
                   && P.choose(heard: heard, ok: false, text: "So it.", polished: true, reason: "Bad Reason; rm -rf") == .failed("refused"),
                   "polish: a refusal never applies its text, and only a short identifier reaches the log")
            // 0.5.328 (server 6.79.1 polishSkipped): skipped, fillers only, and only the five codes.
            expect(P.skipReasons == ["daily_cap", "breaker_open", "too_long", "disabled", "failed", "clean", "link_guard"],
                   "polish: seven skip codes (0.5.329 adds clean, 0.5.334 adds link_guard)")
            expect(P.choose(heard: heard, ok: true, text: heard, polished: false, reason: nil, skipped: "clean") == .skipped("clean"),
                   "polish: a dictation the server found clean is skipped:clean")
            for code in ["daily_cap", "breaker_open", "too_long", "disabled", "failed", "link_guard"] {
                let skipped = P.choose(heard: heard, ok: true, text: heard, polished: false, reason: nil, skipped: code)
                expect(skipped == .skipped(code) && skipped.logName == "skipped:" + code && skipped.text(heard: heard) == heard,
                       "polish: polished false with \(code) is skipped:\(code) and pastes what was heard")
            }
            let fillers = P.choose(heard: heard, ok: true, text: "So the the plan is ready", polished: true, reason: nil, skipped: "daily_cap")
            expect(fillers == .fillersOnly("daily_cap", text: "So the the plan is ready") && fillers.logName == "fillers_only:daily_cap"
                   && fillers.text(heard: heard) == "So the the plan is ready",
                   "polish: polished true with a skip code is fillers_only:<code>, and the filler-cleaned text is pasted")
            // 0.5.334 (server 6.84.0): the server refused the model's answer (a link nobody said). Its deterministic pass may
            // still have changed the text ("/pricing"), so polished is true; that is not Claude's polish.
            let guarded = P.choose(heard: heard, ok: true, text: "So go to /pricing", polished: true, reason: nil, skipped: "link_guard")
            expect(guarded == .fillersOnly("link_guard", text: "So go to /pricing") && guarded.logName == "fillers_only:link_guard",
                   "polish: a link_guard refusal is never labeled polished")
            expect(P.choose(heard: heard, ok: true, text: heard, polished: true, reason: nil, skipped: "disabled") == .skipped("disabled"),
                   "polish: a filler pass that changed nothing is still skipped:<code>")
            expect(P.choose(heard: heard, ok: true, text: String(repeating: "b", count: 81), polished: true, reason: nil, skipped: "daily_cap") == .failed("grew")
                   && P.choose(heard: heard, ok: true, text: " ", polished: true, reason: nil, skipped: "daily_cap") == .failed("empty"),
                   "polish: a filler-only answer is held to the same empty and growth guards")
            expect(P.choose(heard: heard, ok: true, text: heard, polished: false, reason: nil, skipped: "quota; rm -rf") == .failed("not_polished")
                   && P.choose(heard: heard, ok: true, text: "So the plan is ready.", polished: true, reason: nil, skipped: "Daily_Cap") == .applied("So the plan is ready.")
                   && P.choose(heard: heard, ok: false, text: nil, polished: nil, reason: "busy", skipped: "daily_cap") == .failed("busy"),
                   "polish: an unknown skip word is ignored, and a refusal stays a refusal")
            for outcome in [P.Outcome.unchanged, .timeout, .failed("unreachable")] {
                expect(outcome.text(heard: heard) == heard, "polish: every outcome but applied pastes what was heard (\(outcome.logName))")
            }
            expect(P.Outcome.applied("So.").text(heard: heard) == "So." && P.Outcome.applied("Secret words").logName == "applied"
                   && P.Outcome.failed("grew").logName == "failed:grew" && P.Outcome.timeout.logName == "timeout",
                   "polish: the log names the outcome and never the text")
            for model in PM.allCases {
                let note = P.settingNote(model)
                expect(!note.contains("\u{2014}") && !note.contains("\u{2192}") && !note.contains("->"), "polish: the setting line has no em dash or arrow")
            }
            expect(P.settingNote(.haiku).contains("longer than 5 seconds") && P.settingNote(.sonnet).contains("longer than 9 seconds")
                   && P.settingNote(.haiku).contains("does not reliably fix misheard words") && P.settingNote(.haiku).contains("Uses your Claude plan"),
                   "polish: the setting says what it fixes, what it does not, and the wait")
            expect(DictationPill.polishing.label == "POLISHING" && DictationPill.polishing.replacesLedger, "polish: the pill says POLISHING")
            // The record: what was heard and the model survive the history file; older files still load.
            let polishedRecord = DictationRecord(id: UUID(), text: "So the plan is ready.", createdAt: Date(timeIntervalSince1970: 1_760_800_000),
                                                 delivery: .unconfirmed(app: "iTerm2", viaPaste: true), engine: "parakeet-ultra",
                                                 heard: heard, polishModel: "haiku")
            let polishedTrip = try JSONDecoder().decode(DictationRecord.self, from: JSONEncoder().encode(polishedRecord))
            expect(polishedTrip == polishedRecord && polishedTrip.heard == heard && polishedTrip.polishModel == "haiku",
                   "polish: what was heard and the model are saved with the dictation")
            let plainJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(engineRecord)) as? [String: Any] ?? [:]
            expect(plainJSON["heard"] == nil && plainJSON["polishModel"] == nil, "polish: an unpolished dictation stores neither")
            let oldFile = #"{"id":"5A0C2A3C-6A7B-4C8D-9E0F-1A2B3C4D5E6F","text":"old","createdAt":0,"kind":"inserted","app":"Notes","engine":"whisper"}"#
            let oldRecord = try JSONDecoder().decode(DictationRecord.self, from: Data(oldFile.utf8))
            expect(oldRecord.heard == nil && oldRecord.polishModel == nil && oldRecord.engine == "whisper" && oldRecord.polishLabel == nil,
                   "polish: a 0.5.324 record loads without polish")
            let oddFile = #"{"id":"5A0C2A3C-6A7B-4C8D-9E0F-1A2B3C4D5E6F","text":"odd","createdAt":0,"kind":"inserted","app":"Notes","heard":7,"polishModel":["haiku"]}"#
            let oddRecord = try? JSONDecoder().decode(DictationRecord.self, from: Data(oddFile.utf8))
            expect(oddRecord?.text == "odd" && oddRecord?.heard == nil && oddRecord?.polishModel == nil,
                   "polish: a polish field of the wrong type reads as none, never dropping the file")
            expect(polishedRecord.polishLabel == "Polished · Haiku"
                   && polishedRecord.metaLine(time: "9:41 AM") == "9:41 AM · 5 words · pasted (unconfirmed) · iTerm2 · Polished · Haiku",
                   "polish: the history row says Polished and the model")
            let sonnetRecord = DictationRecord(id: UUID(), text: "x", createdAt: Date(), delivery: .inserted(app: "Notes"), heard: "um x", polishModel: "sonnet")
            expect(sonnetRecord.polishLabel == "Polished · Sonnet", "polish: Sonnet is named")
            expect(engineRecord.metaLine(time: "9:41 AM") == "9:41 AM · 2 words · inserted · Notes"
                   && DictationRecord(id: UUID(), text: "x", createdAt: Date(), delivery: .inserted(app: "Notes"), polishModel: "haiku").polishLabel == nil
                   && DictationRecord(id: UUID(), text: "x", createdAt: Date(), delivery: .inserted(app: "Notes"), heard: "y", polishModel: "opus").polishLabel == nil,
                   "polish: no label without what was heard, or for a model this build does not know")
            let corrected: DictationRecord? = DictationHistory.correcting(polishedRecord.id, to: "So the plan is done.", in: [polishedRecord]).first
            let correctedHeard: String? = corrected?.heard
            let correctedModel: String? = corrected?.polishModel
            expect(correctedHeard == heard && correctedModel == "haiku" && corrected?.text == "So the plan is done.",
                   "polish: Fix a word keeps what was heard and the model")
        }
        do {
            // 0.5.326 release tail (Miles, 2026-10-18 21:21: the last word or two went missing on release).
            typealias T = DictationReleaseTail
            expect(T.milliseconds == 300 && T.tail(for: .released) == 300, "tail: the person's stop keeps listening 300 ms")
            expect(T.tail(for: .maximum) == 0 && T.tail(for: .failure) == 0 && T.tail(for: .interrupted) == 0,
                   "tail: the two-minute limit, a microphone failure and an interruption close at once")
            expect(T.press(tailing: true, phase: "Listening") == .extend, "tail: a press during the tail continues the same dictation")
            expect(T.press(tailing: false, phase: "Listening") == .normal && T.press(tailing: true, phase: "Transcribing") == .normal
                   && T.press(tailing: false, phase: "Ready") == .normal, "tail: outside the tail a press is an ordinary press")
            expect(T.bytes(milliseconds: 250) == 8_000 && T.bytes(milliseconds: -5) == 0, "tail: 32 bytes a millisecond at 16 kHz PCM16")
            func tone(_ amplitude: Int16, ms: Int) -> Data {
                var d = Data(); for i in 0..<(ms * 16) { let v = (i % 2 == 0 ? amplitude : -amplitude).littleEndian; withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }; return d
            }
            let loud = tone(16_384, ms: 500), quiet = tone(164, ms: 300)
            expect(T.dBFS(loud, from: 0, to: loud.count) == -6.0 && T.dBFS(quiet, from: 0, to: quiet.count) == -46.0,
                   "tail: dBFS is RMS (half scale reads -6.0, a hundredth -46.0)")
            expect(T.dBFS(loud, from: 10, to: 10) == nil && T.dBFS(Data(count: 64), from: 0, to: 64) == -120
                   && T.dBFS(loud, from: -100, to: 99_999) == -6.0, "tail: an empty range is nil, silence -120, a range is clamped")
            // Quiet, then 250 ms of speech right up to the release, then a quiet tail: the final window is that speech alone.
            let speech = tone(16_384, ms: 250)
            let pcm = quiet + speech + quiet
            let timing = DictationTiming.measure(pcm: pcm, releaseBytes: quiet.count + speech.count, tailMs: 300, releaseToClosedMs: 312,
                                                 at: Date(timeIntervalSince1970: 1_760_000_000))
            expect(timing.finalDBFS == -6.0 && timing.tailDBFS == -46.0 && timing.capturedSeconds == 0.85 && timing.tailMs == 300
                   && timing.releaseToClosedMs == 312 && timing.outcome == "pending",
                   "tail: the timing line splits the 250 ms before the release from the tail after it")
            expect(DictationTiming.measure(pcm: pcm, releaseBytes: 99_999_999, tailMs: 0, releaseToClosedMs: 3, at: Date()).tailDBFS == nil,
                   "tail: no tail, no tail level")
            let line = DictationTimingLog.line(timing).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let keys = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]).map { Set($0.keys) } ?? []
            expect(line.hasSuffix("\n") && line.filter({ $0 == "\n" }).count == 1
                   && keys == ["at", "releaseToClosedMs", "tailMs", "capturedSeconds", "finalDBFS", "tailDBFS", "outcome"],
                   "tail: one JSON line, numbers and identifiers only (nil fields left out)")
            // AI polish rides on the same line when it ran: the model and its outcome word, never the text.
            var polishedTiming = timing
            polishedTiming.engine = "parakeet-ultra"; polishedTiming.transcribeMs = 410; polishedTiming.polishMs = 2_930
            polishedTiming.polishModel = "haiku"; polishedTiming.polishOutcome = DictationPolish.Outcome.applied("So the plan is ready.").logName
            polishedTiming.outcome = "typed"
            let polishedLine = DictationTimingLog.line(polishedTiming).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let decoded = try? JSONDecoder().decode(DictationTiming.self, from: Data(polishedLine.utf8))
            expect(decoded == polishedTiming && polishedLine.contains("\"polishModel\":\"haiku\"") && polishedLine.contains("\"polishOutcome\":\"applied\"")
                   && !polishedLine.contains("plan is ready"), "tail: the line carries the polish model and outcome, never the text")
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cos-timing-\(UUID().uuidString)")
            let url = folder.appendingPathComponent(DictationTimingLog.fileName)
            defer { try? FileManager.default.removeItem(at: folder) }
            DictationTimingLog.append(timing, to: url)
            DictationTimingLog.append(timing, to: url)
            let perms = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0
            expect(((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").count == 2 && perms == 0o600,
                   "tail: the timing file appends one line each and is private")
            let lineBytes = DictationTimingLog.line(timing)!.count
            for _ in 0..<(2 * (DictationTimingLog.maximumBytes / lineBytes) + 5) { DictationTimingLog.append(timing, to: url) }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? .max
            let rotated = (try? FileManager.default.attributesOfItem(atPath: url.appendingPathExtension("1").path)[.size] as? Int) ?? 0
            expect(size <= DictationTimingLog.maximumBytes && rotated > 0 && rotated <= DictationTimingLog.maximumBytes,
                   "tail: the timing file is bounded: it rotates to .1 past 256 KB, two files at most")
        }
        do {
            // 0.5.327 truthful start (Miles, 2026-10-19: the sound came on the press, the pet listened a second later).
            typealias S = DictationStart
            var reads = 0, lists = 0
            let none = S.resolve(selectedUID: "", cached: ["usb": 7], uidOf: { _ in reads += 1; return "usb" }, enumerate: { lists += 1; return ["usb": 7] })
            expect(none.device == .systemDefault && !none.listRead && reads == 0 && lists == 0,
                   "start: no microphone chosen opens the system default and never reads the microphone list on the press")
            let cached = S.resolve(selectedUID: "usb", cached: ["usb": 7], uidOf: { id in reads += 1; return id == 7 ? "usb" : nil }, enumerate: { lists += 1; return [:] })
            expect(cached.device == .device(7) && !cached.listRead && reads == 1 && lists == 0,
                   "start: a chosen microphone opens its cached id after one UID read, without the list")
            let moved = S.resolve(selectedUID: "usb", cached: ["usb": 7], uidOf: { _ in "other" }, enumerate: { lists += 1; return ["usb": 9] })
            expect(moved.device == .device(9) && moved.listRead && lists == 1,
                   "start: a cached id that no longer reports the chosen UID reads the list once and opens the new id")
            let uncached = S.resolve(selectedUID: "usb", cached: [:], uidOf: { _ in "usb" }, enumerate: { lists += 1; return ["usb": 11] })
            expect(uncached.device == .device(11) && uncached.listRead && lists == 2, "start: a chosen microphone not yet cached reads the list once")
            let gone = S.resolve(selectedUID: "usb", cached: ["usb": 7], uidOf: { _ in nil }, enumerate: { [:] })
            expect(gone.device == .missing && gone.listRead, "start: a chosen microphone that is unplugged is missing, not the default")
            expect(S.firstBufferTimeoutMs == 3_000 && S.pollMs == 5, "start: STARTING waits at most 3 s for the first buffer, looking every 5 ms")

            // The first buffer is the moment listening began: stamped by the audio side, once, and only for real audio.
            let first = DictationPCMBuffer()
            expect(first.firstAudioUptime() == nil, "start: no first-audio time before any audio")
            first.append(Data())
            expect(first.firstAudioUptime() == nil, "start: an empty conversion is not audio")
            let before = ProcessInfo.processInfo.systemUptime
            first.append(Data([1, 2, 3, 4]))
            let stamped = first.firstAudioUptime()
            expect(stamped.map { $0 >= before && $0 <= ProcessInfo.processInfo.systemUptime } == true, "start: the first audio is stamped as it is appended")
            first.append(Data([5, 6]))
            expect(first.firstAudioUptime() == stamped, "start: later audio never moves the first-audio time")

            // STARTING is its own pill: it owns the ledger, says STARTING, and is not LISTENING.
            expect(DictationPill.starting.label == "STARTING" && DictationPill.starting.replacesLedger
                   && DictationPill.starting != .listening(since: Date(timeIntervalSince1970: 0)), "start: the pill says STARTING until the first buffer")

            // The spare engine: used only while nothing it was built against has changed.
            typealias W = DictationSpare
            let warmed = W.Warmed(device: 145, selectedUID: "", sampleRate: 48_000, at: 1_000)
            expect(W.maximumAgeSeconds == 1_800 && W.check(warmed, selectedUID: "", device: 145, sampleRate: 48_000, bluetooth: false, now: 1_010) == .use, "spare: an unchanged spare is used")
            expect(W.check(warmed, selectedUID: "", device: 146, sampleRate: 48_000, bluetooth: false, now: 1_010) == .discard("device")
                   && W.check(warmed, selectedUID: "", device: nil, sampleRate: 48_000, bluetooth: false, now: 1_010) == .discard("device"),
                   "spare: a different (or unknown) input device discards it")
            expect(W.check(warmed, selectedUID: "", device: 145, sampleRate: 44_100, bluetooth: false, now: 1_010) == .discard("rate")
                   && W.check(warmed, selectedUID: "", device: 145, sampleRate: nil, bluetooth: false, now: 1_010) == .discard("rate"),
                   "spare: a changed (or unreadable) sample rate discards it, so a tap never meets a stale format")
            expect(W.check(warmed, selectedUID: "usb", device: 145, sampleRate: 48_000, bluetooth: false, now: 1_010) == .discard("selection"),
                   "spare: a changed microphone choice discards it")
            expect(W.check(warmed, selectedUID: "", device: 145, sampleRate: 48_000, bluetooth: true, now: 1_010) == .discard("bluetooth"),
                   "spare: never used for a Bluetooth input")
            expect(W.check(warmed, selectedUID: "", device: 145, sampleRate: 48_000, bluetooth: false, now: 1_000 + W.maximumAgeSeconds + 1) == .discard("age")
                   && W.check(warmed, selectedUID: "", device: 145, sampleRate: 48_000, bluetooth: false, now: 999) == .discard("age")
                   && W.check(warmed, selectedUID: "", device: 145, sampleRate: 48_000, bluetooth: false, now: 1_000 + W.maximumAgeSeconds) == .use,
                   "spare: older than half an hour (or from a clock that went back) is not used")
            expect(W.mayWarm(enabled: true, authorized: true, bluetooth: false) && !W.mayWarm(enabled: false, authorized: true, bluetooth: false)
                   && !W.mayWarm(enabled: true, authorized: false, bluetooth: false) && !W.mayWarm(enabled: true, authorized: true, bluetooth: true),
                   "spare: built only with dictation on, the microphone allowed, and a non-Bluetooth input")

            // Failure codes: codes only, a detail only when it is itself a code.
            typealias F = DictationFailReason
            expect(Set(F.allCases.map(\.rawValue)).count == F.allCases.count
                   && F.allCases.allSatisfy { $0.rawValue.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || $0 == "_" } },
                   "fail reason: every code is distinct, lowercase and underscores")
            expect(F.refused.code("engine_unavailable") == "refused:engine_unavailable" && F.helperTimeout.code() == "helper_timeout",
                   "fail reason: a code-shaped detail rides along")
            expect(F.refused.code("Parakeet is not installed") == "refused" && F.refused.code("ABC") == "refused"
                   && F.refused.code(String(repeating: "a", count: 41)) == "refused" && F.refused.code("") == "refused" && F.refused.code(nil) == "refused",
                   "fail reason: words, capitals, over 40 characters or nothing never ride along")

            // The timing line: the start numbers and the fail code, numbers and codes only.
            var marks = DictationStartMarks(pressed: 100)
            expect(DictationStartMarks.ms(1.0, 1.2346) == 235 && DictationStartMarks.ms(2, 1) == 0 && marks.since(100.25) == 250,
                   "start: milliseconds round and never go negative")
            marks.pressToTaskMs = 2; marks.quietMs = 41; marks.permissionMs = 0; marks.refreshMicsMs = 0; marks.micListRead = false
            marks.warmEngine = true; marks.engineStartMs = 120; marks.pressToFirstBufferMs = 228; marks.pressToSoundMs = 231
            var withStart = DictationTiming.measure(pcm: Data(count: 64_000), releaseBytes: 60_000, tailMs: 300, releaseToClosedMs: 330, at: Date(timeIntervalSince1970: 1_760_000_000))
            withStart.include(marks)
            let startLine = DictationTimingLog.line(withStart).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let startKeys = (try? JSONSerialization.jsonObject(with: Data(startLine.utf8)) as? [String: Any]) ?? [:]
            expect(startKeys["pressToTaskMs"] as? Int == 2 && startKeys["permissionMs"] as? Int == 0 && startKeys["refreshMicsMs"] as? Int == 0
                   && startKeys["engineStartMs"] as? Int == 120 && startKeys["pressToFirstBufferMs"] as? Int == 228 && startKeys["pressToSoundMs"] as? Int == 231
                   && startKeys["quietMs"] as? Int == 41 && startKeys["warmEngine"] as? Bool == true && startKeys["micListRead"] as? Bool == false
                   && startKeys["tailMs"] as? Int == 300 && startKeys["failReason"] == nil,
                   "start: the timing line carries every start number beside the release numbers")
            withStart.include(nil)
            expect(withStart.pressToFirstBufferMs == 228, "start: no marks leaves the line as it was")
            var early = DictationStartMarks(pressed: 5); early.pressToTaskMs = 1; early.permissionMs = 3
            var failed = DictationTiming.startFailure(early, at: Date(timeIntervalSince1970: 1_760_000_000))
            failed.failReason = F.noFirstBuffer.code(); failed.outcome = "failed"
            let failedLine = DictationTimingLog.line(failed).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let failedKeys = (try? JSONSerialization.jsonObject(with: Data(failedLine.utf8)) as? [String: Any]) ?? [:]
            expect(failedKeys["failReason"] as? String == "no_first_buffer" && failedKeys["capturedSeconds"] as? Double == 0
                   && failedKeys["permissionMs"] as? Int == 3 && failedKeys["pressToFirstBufferMs"] == nil && failedKeys["outcome"] as? String == "failed"
                   && Set(failedKeys.keys) == ["at", "releaseToClosedMs", "tailMs", "capturedSeconds", "outcome", "pressToTaskMs", "permissionMs", "failReason"],
                   "start: a start that failed writes its own line: the steps that ran, nothing captured, and why")
        }
        do {
            // 0.5.328 smooth start (Miles 2026-10-19 on 0.5.327: "the animation stops as the new listening pill comes in").
            let meter = DictationStallMeter(start: 10)
            expect(meter.maxGapMs == nil, "smooth: no beat, no stall number")
            expect(meter.tick(10.016) && meter.tick(10.032) && meter.maxGapMs == 16, "smooth: steady 16 ms beats read 16")
            meter.tick(11.132)
            expect(meter.maxGapMs == 1_100, "smooth: a main thread held 1.1 s reads 1,100 ms")
            meter.tick(11.148)
            expect(meter.maxGapMs == 1_100, "smooth: the longest gap is kept, not the latest")
            let late = DictationStallMeter(start: 0)
            expect(late.tick(0.75) && late.maxGapMs == 750, "smooth: the press to the first beat counts (a press that landed on a busy main thread)")
            late.end(at: 1)
            expect(late.tick(1.0) && !late.tick(2.5) && late.maxGapMs == 750, "smooth: beats past the end are not counted, and stop the timer")
            expect(DictationStallMeter.tickMilliseconds == 16 && DictationStallMeter.afterListeningSeconds == 3,
                   "smooth: a 16 ms beat, measured until three seconds after LISTENING")

            // The audio queues: two, serial, and never the main thread; perform runs its work there and returns its value.
            let inputKey = DispatchSpecificKey<String>(), outputKey = DispatchSpecificKey<String>()
            DictationAudioQueues.input.setSpecific(key: inputKey, value: "input")
            DictationAudioQueues.output.setSpecific(key: outputKey, value: "output")
            expect(DictationAudioQueues.input !== DictationAudioQueues.output
                   && DictationAudioQueues.input.label == "com.gotcos.control.dictation.input" && DictationAudioQueues.output.label == "com.gotcos.control.dictation.output",
                   "smooth: microphones and sounds/quiet have their own queues")
            final class Box: @unchecked Sendable { var value: String?; var onMain = true; var failed = false }
            let box = Box()
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                box.value = try? await DictationAudioQueues.perform(on: DictationAudioQueues.input) { () -> String in
                    box.onMain = Thread.isMainThread
                    return DispatchQueue.getSpecific(key: inputKey) ?? "elsewhere"
                }
                do { _ = try await DictationAudioQueues.perform(on: DictationAudioQueues.output) { () throws -> Int in throw CancellationError() } }
                catch { box.failed = error is CancellationError }
                done.signal()
            }
            expect(done.wait(timeout: .now() + 5) == .success && box.value == "input" && !box.onMain,
                   "smooth: perform runs its work on the queue it names, off the main thread, and returns the result")
            expect(box.failed, "smooth: perform hands an error back to the caller")
            let order = Box(); order.value = ""
            for n in 0..<20 { DictationAudioQueues.output.async { order.value! += "\(n)," } }
            DictationAudioQueues.output.sync {}
            expect(order.value == (0..<20).map { "\($0)," }.joined(), "smooth: the output queue runs work in the order it was asked (a mute's end never overtakes its begin)")

            // The new numbers ride on the timing line, numbers only.
            var marks = DictationStartMarks(pressed: 0)
            marks.mainThreadStallMs = 17; marks.quietBuildMs = 1_090; marks.quietStartMs = 64; marks.placementMs = 3; marks.soundMs = 120; marks.editWatchAtPress = true
            var line = DictationTiming.startFailure(marks, at: Date(timeIntervalSince1970: 1_760_000_000))
            let json = DictationTimingLog.line(line).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            expect(json["mainThreadStallMs"] as? Int == 17 && json["quietBuildMs"] as? Int == 1_090 && json["quietStartMs"] as? Int == 64
                   && json["placementMs"] as? Int == 3 && json["soundMs"] as? Int == 120 && json["editWatchAtPress"] as? Bool == true,
                   "smooth: the line carries the stall, the mute's build and start, placement, the sound and an edit watch at the press")
            line.include(nil)
            expect(line.mainThreadStallMs == 17, "smooth: no marks leaves the line as it was")
        }
        do {
            // 0.5.330 (Miles 2026-10-19: hold to dictate "locked", and nothing on the timing line said why).
            typealias H = DictationHoldWatch
            var blind = H.Reads()
            expect(!blind.read(down: false) && !blind.read(down: false) && !blind.read(down: false),
                   "hold watch: a key the keyboard state never showed as down is never released (an up proves nothing)")
            var reads = H.Reads()
            expect(!reads.read(down: true) && !reads.read(down: false) && reads.read(down: true) == false,
                   "hold watch: one up read, then down again, is a key still held")
            expect(!reads.read(down: false) && reads.read(down: false), "hold watch: two up reads in a row after a down run the missed release")
            var flicker = H.Reads()
            _ = flicker.read(down: true)
            expect(!flicker.read(down: false) && !flicker.read(down: true) && !flicker.read(down: false), "hold watch: a down between ups starts the count again")
            expect(H.pollMilliseconds == 150 && H.upReadsToRelease == 2, "hold watch: every 150 ms, two up reads")
            expect(H.watches(phase: "Starting", held: true, trackerDown: false) && H.watches(phase: "Listening", held: true, trackerDown: false),
                   "hold watch: watches a held dictation that is starting or listening")
            expect(!H.watches(phase: "Transcribing", held: true, trackerDown: false) && !H.watches(phase: "Listening", held: false, trackerDown: false)
                   && !H.watches(phase: "Ready", held: false, trackerDown: false), "hold watch: nothing to watch once the microphone closed or nothing is held")
            expect(H.watches(phase: "Ready", held: false, trackerDown: true), "hold watch: a tracker still latched down is watched, or the next press is swallowed")
            expect(H.modifierDown(flags: 0x800000 | 0x800000, keyCode: 63) == true && H.modifierDown(flags: 0, keyCode: 63) == false,
                   "hold watch: Fn reads its own device bit")
            expect(H.modifierDown(flags: 0x08 | 0x100000, keyCode: 54) == false && H.modifierDown(flags: 0x10 | 0x100000, keyCode: 54) == true,
                   "hold watch: Left Command held is not Right Command held")
            expect(H.modifierDown(flags: 0xFFFF_FFFF, keyCode: 49) == nil, "hold watch: no answer for a key that is not a lone modifier")
            expect(DictationPressEvent.allCases.map(\.rawValue) == ["refused_busy", "canceled_starting", "interrupted_chord", "release_reconciled"],
                   "press events: the four outcome words")
            var event = DictationTiming.event(.canceledStarting, at: Date(timeIntervalSince1970: 1_760_000_000))
            event.phase = "Starting"; event.msSincePress = 812; event.firstBufferArrived = false; event.appVersion = "0.5.330"
            event.held = false; event.holdTrackerDown = false; event.holdHardwareDown = true
            let json = DictationTimingLog.line(event).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            expect(json["outcome"] as? String == "canceled_starting" && json["phase"] as? String == "Starting" && json["msSincePress"] as? Int == 812
                   && json["firstBufferArrived"] as? Bool == false && json["appVersion"] as? String == "0.5.330" && json["held"] as? Bool == false
                   && json["holdTrackerDown"] as? Bool == false && json["holdHardwareDown"] as? Bool == true && json["capturedSeconds"] as? Double == 0,
                   "press events: one line with the phase, the timing, the version and the hold key's state, nothing captured")
            let plain = DictationTimingLog.line(DictationTiming.event(.refusedBusy, at: Date())).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            expect(Set(plain.keys) == ["at", "releaseToClosedMs", "tailMs", "capturedSeconds", "outcome"], "press events: nothing else rides along unless set")
            expect(H.keyDownIsMissedRelease(trackerDown: true, hardwareDown: false, seenDown: true, sincePress: 4.2),
                   "missed release: a key typed seconds later while the keyboard says Fn is up is the release (it types, never a chord)")
            expect(!H.keyDownIsMissedRelease(trackerDown: true, hardwareDown: true, seenDown: true, sincePress: 4.2)
                   && !H.keyDownIsMissedRelease(trackerDown: true, hardwareDown: nil, seenDown: true, sincePress: 4.2),
                   "missed release: Fn still down (or a keyboard that cannot say) keeps the chord")
            expect(!H.keyDownIsMissedRelease(trackerDown: true, hardwareDown: false, seenDown: true, sincePress: 0.6) && H.keyDownReleaseAfterSeconds == 1,
                   "missed release: a key within a second of the press is still a chord (Fn+arrow)")
            expect(!H.keyDownIsMissedRelease(trackerDown: true, hardwareDown: false, seenDown: false, sincePress: 4.2)
                   && !H.keyDownIsMissedRelease(trackerDown: false, hardwareDown: false, seenDown: true, sincePress: 4.2),
                   "missed release: never from a keyboard that never showed the key down, and never when nothing is held")
            typealias FU = DictationFnUsage
            expect(FU.conflicts(usageType: nil, fnIsDictationKey: true) && FU.conflicts(usageType: 1, fnIsDictationKey: true)
                   && FU.conflicts(usageType: 2, fnIsDictationKey: true) && !FU.conflicts(usageType: 0, fnIsDictationKey: true),
                   "fn usage: anything but Do Nothing (absent is the system default) is a conflict while Fn dictates")
            expect(!FU.conflicts(usageType: nil, fnIsDictationKey: false) && !FU.conflicts(usageType: 2, fnIsDictationKey: false),
                   "fn usage: no conflict when Fn is not a dictation key")
            expect(!FU.note.contains("\u{2192}") && !FU.note.contains("\u{2014}") && FU.note.contains("Do Nothing")
                   && FU.keyboardSettingsURL == "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
                   && DictationFailureAction.openKeyboardSettings.title == "Open Keyboard settings",
                   "fn usage: the card says the fix in plain words and opens Keyboard settings")
            expect(DictationPill.finishing.label == "STILL FINISHING" && DictationPill.finishing.replacesLedger && DictationPill.finishingSeconds == 1.5,
                   "busy press: the pill says STILL FINISHING for a moment")
        }
        do {
            // 0.5.329 (server 6.79.2): AI polish's process started at the key press.
            typealias W = DictationPolishPrewarm
            let token = "0a1b2c3d-4e5f-6a7b-8c9d-0e1f2a3b4c5d"
            expect(W.isToken(token) && !W.isToken("0A1B2C3D-4E5F-6A7B-8C9D-0E1F2A3B4C5D") && !W.isToken(token + "0")
                   && !W.isToken("../../api/x") && !W.isToken(""), "prewarm: a token is a lowercase uuid and nothing else")
            expect(!W.shouldStart(model: .off, unsupportedOn: nil, serverVersion: "6.79.2"), "prewarm: AI polish off never starts one")
            expect(W.shouldStart(model: .haiku, unsupportedOn: nil, serverVersion: nil) && W.shouldStart(model: .sonnet, unsupportedOn: nil, serverVersion: "6.79.2"),
                   "prewarm: Haiku or Sonnet starts one")
            expect(!W.shouldStart(model: .haiku, unsupportedOn: "6.79.1", serverVersion: "6.79.1") && W.shouldStart(model: .haiku, unsupportedOn: "6.79.1", serverVersion: "6.79.2"),
                   "prewarm: an older server that said unsupported is not asked again until its version changes")
            let started = (W.startRequest(model: .haiku).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }) ?? [:]
            expect(started == ["model": "haiku"] && W.startRequest(model: .off) == nil, "prewarm: the start carries the model only (there is no text yet)")
            let discard = (W.discardRequest(token: token).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }) ?? [:]
            expect(discard == ["discard": token] && W.discardRequest(token: "x") == nil, "prewarm: a discard carries the token only, and only a real one")
            expect(W.read(ok: true, token: token, reason: nil, elapsedMs: 180) == .token(token, ms: 180), "prewarm: a token answer is kept with its time")
            expect(W.read(ok: true, token: "nope", reason: nil, elapsedMs: 5) == .refused("refused", ms: 5)
                   && W.read(ok: false, token: nil, reason: "breaker_open", elapsedMs: 9) == .refused("breaker_open", ms: 9)
                   && W.read(ok: false, token: nil, reason: "Bad; rm", elapsedMs: 9) == .refused("refused", ms: 9),
                   "prewarm: a refusal keeps a short reason, never a malformed token")
            expect(W.read(ok: nil, token: nil, reason: nil, elapsedMs: nil) == .refused("helper", ms: nil) && W.read(ok: nil, token: nil, reason: nil, elapsedMs: nil).token == nil,
                   "prewarm: a helper that threw or timed out gives no token, so the polish runs cold as before")
            expect(W.read(ok: false, token: nil, reason: "unsupported", elapsedMs: 4) == .unsupported, "prewarm: an older server (404) is unsupported")
            expect(W.outcome(sentToken: false, answer: "used") == "none" && W.outcome(sentToken: true, answer: "used") == "used"
                   && W.outcome(sentToken: true, answer: "discarded") == "discarded" && W.outcome(sentToken: true, answer: nil) == "missed"
                   && W.outcome(sentToken: true, answer: "weird") == "missed", "prewarm: the line says used, missed, discarded or none")
            expect(W.waitMilliseconds == 150 && W.helperTimeout == 2.5, "prewarm: the polish waits at most 150 ms for it; the helper at most 2.5 s")
            func body(_ data: Data?) -> [String: String] { (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }) ?? [:] }
            expect(body(DictationPolish.request(text: "um hi", model: .haiku, app: nil, prewarmToken: token)) == ["text": "um hi", "model": "haiku", "prewarmToken": token]
                   && body(DictationPolish.request(text: "um hi", model: .haiku, app: nil, prewarmToken: nil)) == ["text": "um hi", "model": "haiku"]
                   && body(DictationPolish.request(text: "um hi", model: .haiku, app: nil, prewarmToken: "nope")) == ["text": "um hi", "model": "haiku"],
                   "prewarm: the polish request carries the token only when there is a real one")
            let box = DictationPrewarmBox()
            expect(box.result == nil, "prewarm: an empty box has no answer")
            box.set(.token(token, ms: 3))
            expect(box.result?.token == token && box.result?.ms == 3, "prewarm: the box hands the answer over")
            var line = DictationTiming.startFailure(DictationStartMarks(pressed: 0), at: Date(timeIntervalSince1970: 1_760_000_000))
            line.polishPrewarm = "used"; line.prewarmMs = 212
            let json = DictationTimingLog.line(line).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            expect(json["polishPrewarm"] as? String == "used" && json["prewarmMs"] as? Int == 212, "prewarm: the timing line carries the outcome and the start's time")
        }
        // 0.5.331 paste first, polish in place (Miles 2026-10-20 07:49): every branch of DictationPolishSwap, each check named.
        do {
            func expect(_ value: Bool, _ name: String) { precondition(value, name); count += 1 }
            typealias P = DictationPolishSwap
            expect(P.sequence(pasteFirst: false, polishes: true, copyOnly: false) == .polishThenDeliver, "swap: toggle off is today's order, polish then one delivery")
            expect(P.sequence(pasteFirst: true, polishes: true, copyOnly: false) == .deliverThenPolish, "swap: toggle on with a polish to run types first")
            expect(P.sequence(pasteFirst: true, polishes: false, copyOnly: false) == .polishThenDeliver, "swap: no polish to run is one delivery as before")
            expect(P.sequence(pasteFirst: true, polishes: true, copyOnly: true) == .polishThenDeliver, "swap: an interrupted dictation is copied after polish, never typed first")
            expect(P.stored(nil) && P.stored(true) && !P.stored(false) && P.stored("x"), "swap: the setting is on unless turned off")
            expect(P.defaultsKey == "dictation.pasteThenPolish", "swap: the setting's key")
            expect(P.unswapped(pasteFirst: true, polished: false, copyOnly: false) == .notPolished && P.unswapped(pasteFirst: false, polished: false, copyOnly: true) == .notPolished,
                   "swap: no polish ran reads notPolished")
            expect(P.unswapped(pasteFirst: true, polished: true, copyOnly: true) == .skipped(.copyOnly), "swap: an interrupted dictation reads skipped:copyOnly")
            expect(P.unswapped(pasteFirst: false, polished: true, copyOnly: true) == .off && P.unswapped(pasteFirst: false, polished: true, copyOnly: false) == .off,
                   "swap: the toggle off reads off")
            expect(P.unswapped(pasteFirst: true, polished: true, copyOnly: false) == .off, "swap: polished first with the toggle on (the model changed mid-dictation) reads off")
            // Claude's applied polish swaps, and (0.5.344 QA W1, as 0.5.343 did) text the server's own pass cleaned.
            expect(P.want(outcome: .applied("Hi there."), typed: "um hi there", final: "Hi there.") == .swap("Hi there."), "swap: an applied polish that differs swaps")
            expect(P.want(outcome: .applied("Hi there."), typed: "Hi there.", final: "Hi there.") == .identical, "swap: identical text changes nothing")
            expect(P.want(outcome: .applied("x"), typed: "y", final: nil) == .notPolished, "swap: no final text is nothing to swap")
            expect(P.want(outcome: .fillersOnly("unchanged", text: "hi"), typed: "um hi", final: "hi") == .swap("hi")
                   && P.want(outcome: .fillersOnly("failed", text: "hi"), typed: "um hi", final: "hi") == .swap("hi"), "swap: cleaned text swaps")
            for (outcome, name) in [(DictationPolish.Outcome.unchanged, "unchanged"), (.timeout, "timeout"), (.failed("helper"), "failed"), (.skipped("daily_cap"), "skipped")] {
                expect(P.want(outcome: outcome, typed: "um hi", final: "hi") == .notPolished, "swap: polish \(name) changes nothing")
            }
            expect(P.want(outcome: nil, typed: "a", final: "b") == .notPolished, "swap: polish that never ran changes nothing")
            // The polished text as delivery would have typed it.
            expect(P.final("Number one, pack. Number two, drive.", formatLists: true, terms: [], known: { _ in true }).text == "1. Pack.\n2. Drive.",
                   "swap: Claude's version gets spoken lists like the typed text")
            expect(P.final("Number one, pack. Number two, drive.", formatLists: false, terms: [], known: { _ in true }).text == "Number one, pack. Number two, drive.",
                   "swap: lists off leaves Claude's version as it came")
            let plain: Set<String> = ["the", "page", "joule", "open"]
            let respelled = P.final("Open the joule 360 page.", formatLists: false, terms: [DictationFieldContext.Term(text: "Jewel360", strong: true)], known: { plain.contains($0) })
            expect(respelled.text == "Open the Jewel360 page." && respelled.fixes == [DictationFieldContext.Fix(heard: "joule 360", written: "Jewel360")],
                   "swap: Claude's version is respelled from the same field words, so a swap never undoes a field fix")
            // Before the swap: the quiet moment and the reasons to skip.
            func ready(inserted: Bool = true, measured: Bool = true, enabled: Bool = true, terminal: Bool = false, running: Bool = true, busy: Bool = false,
                       field: Int? = 5_000, key: Int? = nil, waited: Int = 0, budget: Int = 5_000) -> P.Step {
                P.ready(inserted: inserted, measured: measured, enabled: enabled, terminal: terminal, appRunning: running, busy: busy,
                        sinceFieldChangeMs: field, sinceKeyMs: key, waitedMs: waited, budgetMs: budget)
            }
            expect(ready() == .go, "swap: a quiet field swaps now")
            expect(ready(inserted: false) == .skip(.notTyped), "swap: a copied or refused delivery is not swapped")
            expect(ready(measured: false) == .skip(.notTyped), "swap: an unmeasured delivery is not swapped")
            expect(ready(enabled: false) == .skip(.dictationOff), "swap: dictation turned off skips")
            expect(ready(terminal: true) == .skip(.terminal), "swap: a terminal skips")
            expect(ready(running: false) == .skip(.appGone), "swap: the app gone skips")
            expect(ready(field: 200) == .wait, "swap: the person typed in the field 200 ms ago: wait")
            expect(ready(field: 600) == .go, "swap: 600 ms quiet is quiet")
            expect(ready(field: 599) == .wait, "swap: 599 ms is still typing")
            expect(ready(key: 100) == .wait, "swap: a key down while the field had the keyboard: wait")
            expect(ready(field: nil, key: nil) == .go, "swap: nothing measured as typing is quiet")
            expect(ready(field: 100, waited: 5_000) == .skip(.typing), "swap: still typing at the polish budget skips")
            expect(ready(field: 100, waited: 4_900) == .wait, "swap: the wait is bounded by the budget, not shorter")
            expect(ready(busy: true) == .wait, "swap: a newer delivery or Fix a word waits")
            expect(ready(busy: true, waited: 5_000) == .skip(.busy), "swap: still busy at the budget skips busy")
            // The plan, read for an automatic swap: only the whole dictation where COS typed it, or moved within the window.
            let typed = "um open the page", polished = "Open the page."
            let span = DictationInsertedSpan(pid: 1, location: 6, length: typed.utf16.count)
            let exact = DictationReplace.plan(span: span, terminal: false, appRunning: true, fieldCharacters: 6 + typed.utf16.count, window: "Hello " + typed,
                                              windowStart: 0, current: typed, corrected: polished)
            expect(P.placed(exact) == nil, "swap: the dictation exactly where COS typed it is swapped")
            let moved = DictationReplace.plan(span: span, terminal: false, appRunning: true, fieldCharacters: 12 + typed.utf16.count, window: "Hello there " + typed,
                                              windowStart: 0, current: typed, corrected: polished)
            expect(P.placed(moved) == nil, "swap: the dictation found once, moved within the window, is swapped")
            let edited = DictationReplace.plan(span: span, terminal: false, appRunning: true, fieldCharacters: 30, window: "Hello um open that page now",
                                               windowStart: 0, current: typed, corrected: polished)
            expect(P.placed(edited) == .textMoved, "swap: text the person edited is never swapped")
            let terminalPlan = DictationReplace.plan(span: span, terminal: true, appRunning: true, fieldCharacters: 30, window: "Hello " + typed,
                                                     windowStart: 0, current: typed, corrected: polished)
            expect(P.placed(terminalPlan) == .terminal, "swap: a terminal skips at the plan too")
            expect(P.placed(.edit(DictationReplace.Edit(location: 0, length: 2, original: "um", replacement: "Um"), dictationAt: nil)) == .textMoved,
                   "swap: only the misheard words found means the person edited it")
            let reasons: [(DictationReplace.Reason, P.Skip)] = [(.notMeasured, .notTyped), (.terminal, .terminal), (.appGone, .appGone), (.fieldGone, .fieldGone),
                                                                (.textMoved, .textMoved), (.notFocused, .notFocused), (.selectionUnproven, .selectionUnproven), (.noChange, .noChange)]
            for (reason, skip) in reasons { expect(P.skip(for: reason) == skip && P.placed(.copy(reason)) == skip, "swap: replace's \(reason.rawValue) reads skipped:\(skip.rawValue)") }
            // The focus rules.
            expect(P.gate(route: .accessibility, frontmost: false, focusedIsTarget: false, ownWindowKey: true) == nil,
                   "swap: the Accessibility route swaps while another app is frontmost")
            expect(P.gate(route: .paste, frontmost: false, focusedIsTarget: true, ownWindowKey: false) == .notFrontmost && !P.mayActivate(automatic: true),
                   "swap: the paste route with the app not frontmost skips and never activates")
            expect(P.gate(route: .paste, frontmost: false, focusedIsTarget: false, ownWindowKey: true) == .notFrontmost, "swap: not frontmost is the first paste-route reason")
            expect(P.gate(route: .paste, frontmost: true, focusedIsTarget: true, ownWindowKey: true) == .ownWindowKey, "swap: a COS window holding the keyboard skips the paste route")
            expect(P.gate(route: .paste, frontmost: true, focusedIsTarget: false, ownWindowKey: false) == .notFocused, "swap: another field focused skips the paste route")
            expect(P.gate(route: .paste, frontmost: true, focusedIsTarget: true, ownWindowKey: false) == nil, "swap: the paste route where the person already is swaps")
            expect(P.mayActivate(automatic: false), "swap: Fix a word and Apply polished may still bring the app forward")
            // The person's caret afterwards.
            let edit = DictationReplace.Edit(location: 10, length: 6, original: "um hi.", replacement: "Hi.")
            expect(P.shifted(location: 16, length: 0, edit: edit) == (13, 0), "swap: a caret at the end of the dictation moves with it")
            expect(P.shifted(location: 30, length: 4, edit: edit) == (27, 4), "swap: a selection after the dictation shifts by the length change")
            expect(P.shifted(location: 2, length: 3, edit: edit) == (2, 3), "swap: a selection before the dictation stays")
            expect(P.shifted(location: 10, length: 0, edit: edit) == (10, 0), "swap: a caret at the dictation's start stays")
            expect(P.shifted(location: 12, length: 2, edit: edit) == (13, 0), "swap: a selection inside the dictation lands after the new words")
            expect(P.shifted(location: 5, length: 0, edit: DictationReplace.Edit(location: 5, length: 0, original: "", replacement: ".")) == (6, 0),
                   "swap: an insertion at the caret moves the caret past it")
            // Learn from my edits after the swap.
            let watchedSwap = P.watch(span: span, typed: typed, polished: polished, result: .swapped, swappedAt: 12)
            expect(watchedSwap.text == polished && watchedSwap.span == DictationInsertedSpan(pid: 1, location: 12, length: polished.utf16.count),
                   "swap: after a swap the learner baseline is the polished text where it landed")
            let watchedSkip = P.watch(span: span, typed: typed, polished: polished, result: .skipped(.typing), swappedAt: 12)
            expect(watchedSkip.text == typed && watchedSkip.span == span, "swap: after a skip the learner watches what was typed")
            expect(P.watch(span: span, typed: typed, polished: polished, result: .swapped, swappedAt: nil).text == typed, "swap: a swap with no landing place watches what was typed")
            // What is kept and shown.
            expect(P.keepsPolished(.skipped(.notFrontmost)) && P.keepsPolished(.skipped(.typing)) && !P.keepsPolished(.skipped(.copyOnly)),
                   "swap: a skip keeps Claude's version for Apply polished; copy-only already delivered it")
            expect(!P.keepsPolished(.swapped) && !P.keepsPolished(.identical) && !P.keepsPolished(.notPolished) && !P.keepsPolished(.off), "swap: nothing kept otherwise")
            expect(P.notice(.skipped(.notFocused), app: "Notes") == P.skippedNotice && P.notice(.swapped, app: "Notes") == nil && P.notice(.notPolished, app: "Notes") == nil && P.notice(.identical, app: "Notes") == nil,
                   "swap: the pill says one line only when a skip happened")
            expect(P.Result.swapped.logName == "swapped" && P.Result.skipped(.notFrontmost).logName == "skipped:notFrontmost" && P.Result.off.logName == "off"
                   && P.Result.identical.logName == "identical" && P.Result.notPolished.logName == "notPolished", "swap: the timing line's outcome words")
            expect(P.routeName(.accessibility) == "accessibility" && P.routeName(.paste) == "paste", "swap: the timing line's route words")
            for copy in [P.settingNote(.haiku), P.settingNote(.off), P.skippedNotice] {
                expect(!copy.contains("\u{2014}") && !copy.contains("\u{2192}") && !copy.contains("->"), "swap: copy has no em dash or arrow")
            }
            // The timing line: numbers and codes only.
            var line = DictationTiming.startFailure(DictationStartMarks(pressed: 0), at: Date(timeIntervalSince1970: 1_760_000_000))
            line.includePolish(DictationPolishRun(outcome: .applied("secret words"), model: .haiku, ms: 2_400, prewarm: "used", prewarmMs: 120))
            line.releaseToFirstTextMs = 1_180
            line.settle(.skipped(.notFrontmost), ms: 310, route: .paste)
            let data = DictationTimingLog.line(line) ?? Data()
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            expect(json["releaseToFirstTextMs"] as? Int == 1_180 && json["swapOutcome"] as? String == "skipped:notFrontmost" && json["swapMs"] as? Int == 310
                   && json["swapRoute"] as? String == "paste", "swap: the timing line carries first text, outcome, time and route")
            expect(json["polishMs"] as? Int == 2_400 && json["polishModel"] as? String == "haiku" && json["polishOutcome"] as? String == "applied"
                   && json["polishPrewarm"] as? String == "used" && json["prewarmMs"] as? Int == 120, "swap: the polish run reaches the line")
            expect(!(String(data: data, encoding: .utf8) ?? "secret").contains("secret"), "swap: the timing line never carries the words")
            var unset = line; unset.includePolish(nil)
            expect(unset == line, "swap: no polish run leaves the line as it was")
            // The record after a swap reads what the field holds and keeps what was heard.
            let id = UUID(), other = DictationRecord(id: UUID(), text: "keep", createdAt: Date(timeIntervalSince1970: 1), delivery: .inserted(app: "Notes"))
            let before = [DictationRecord(id: id, text: typed, createdAt: Date(timeIntervalSince1970: 2), delivery: .inserted(app: "Notes"), engine: "parakeet-ultra"), other]
            let after = DictationHistory.polishing(id, to: polished, heard: "um open the page", model: "haiku", in: before)
            expect(after[0].text == polished && after[0].heard == "um open the page" && after[0].polishModel == "haiku" && after[0].polishLabel == "Polished · Haiku"
                   && after[0].engine == "parakeet-ultra" && after[0].createdAt == before[0].createdAt && after[1] == other, "swap: the dictation reads the swap and keeps what was heard")
        }
        // 0.5.332 (Miles 2026-10-20 09:50 to 09:58): Chromium by structure, canvas editors, paste-route swap safety.
        do {
            func expect(_ value: Bool, _ name: String) { precondition(value, name); count += 1 }
            typealias P = DictationPolishSwap
            // 1. Chromium by structure: a "* Framework.framework" with Versions/Current/Helpers/"* Helper (Renderer).app".
            let cometHelpers = ["Comet Helper (Aperitif GPU).app", "Comet Helper (Aperitif Renderer).app", "Comet Helper (GPU).app", "Comet Helper (Renderer).app",
                                "Comet Helper.app", "CometUpdater.app", "chrome_crashpad_handler"]
            func listing(_ table: [String: [String]]) -> (String) -> [String] { { table[$0] ?? [] } }
            expect(KnownApps.isChromiumFamily(frameworks: ["Comet Framework.framework"], helpers: listing(["Comet Framework.framework": cometHelpers])),
                   "chromium: Comet is Chromium by its Renderer helper")
            expect(!KnownApps.isChromiumFamily(frameworks: ["Comet Framework.framework"]), "chromium: Comet's name alone is not on the list (the 0.5.331 bug)")
            expect(KnownApps.isChromiumFamily(frameworks: ["Google Chrome Framework.framework"],
                                              helpers: listing(["Google Chrome Framework.framework": ["Google Chrome Helper (Renderer).app", "Google Chrome Helper.app"]])),
                   "chromium: Chrome by name and by structure")
            expect(KnownApps.isChromiumFamily(frameworks: ["Arc Framework.framework"]), "chromium: Arc still by name")
            expect(KnownApps.isChromiumFamily(frameworks: ["Electron Framework.framework", "Squirrel.framework", "Claude Helper (Renderer).app"]), "chromium: Electron still by name")
            expect(!KnownApps.isChromiumFamily(frameworks: ["Sparkle.framework"], helpers: { _ in ["Any Helper (Renderer).app"] }),
                   "chromium: a native app's framework that is not \"* Framework.framework\" is never asked")
            expect(!KnownApps.isChromiumFamily(frameworks: ["Foo Framework.framework"], helpers: listing(["Foo Framework.framework": ["Foo Helper.app", "Foo Helper (GPU).app", "Foo Helper (Aperitif Renderer).app"]])),
                   "chromium: a non-Chromium framework without a Renderer helper is not Chromium")
            expect(KnownApps.helpersPath == "Versions/Current/Helpers", "chromium: the helpers live in Versions/Current/Helpers")
            // 2. Canvas web editors: Chromium, nothing focused takes text, no editable ancestor.
            expect(DictationInsertPolicy.canvasEditor(chromium: true, focused: true, textSettable: false, editableAncestor: false), "canvas: Slides in Comet is a canvas editor")
            expect(DictationInsertPolicy.canvasEditor(chromium: true, focused: false, textSettable: true, editableAncestor: false), "canvas: nothing focused in Chromium is a canvas")
            expect(!DictationInsertPolicy.canvasEditor(chromium: true, focused: true, textSettable: true, editableAncestor: false), "canvas: a settable Chromium field is not")
            expect(!DictationInsertPolicy.canvasEditor(chromium: true, focused: true, textSettable: false, editableAncestor: true), "canvas: a web editor's editable ancestor is not")
            expect(!DictationInsertPolicy.canvasEditor(chromium: false, focused: true, textSettable: false, editableAncestor: false), "canvas: never outside Chromium")
            expect(P.unmeasurable(canvas: true, baselineReadable: true) == .canvasEditor, "canvas: a canvas is unmeasurable even if it reports counts")
            expect(P.unmeasurable(canvas: false, baselineReadable: false) == .unreadableField, "canvas: an unreadable field is unmeasurable")
            expect(P.unmeasurable(canvas: false, baselineReadable: true) == nil, "canvas: a readable field is measurable")
            expect(P.sequence(pasteFirst: true, polishes: true, copyOnly: false, unmeasurable: .canvasEditor) == .polishThenDeliver,
                   "canvas: an unmeasurable target waits for polish, then pastes once")
            expect(P.sequence(pasteFirst: true, polishes: true, copyOnly: false, unmeasurable: nil) == .deliverThenPolish, "canvas: a measurable target still pastes first")
            expect(P.unswapped(pasteFirst: true, polished: true, copyOnly: false, unmeasurable: true) == .unmeasurable && P.Result.unmeasurable.logName == "unmeasurable",
                   "canvas: the line reads swapOutcome=unmeasurable")
            expect(P.unswapped(pasteFirst: false, polished: true, copyOnly: false, unmeasurable: true) == .off, "canvas: the toggle off still reads off")
            expect(P.unswapped(pasteFirst: true, polished: false, copyOnly: false, unmeasurable: true) == .notPolished, "canvas: no polish still reads notPolished")
            var canvasLine = DictationTiming.startFailure(DictationStartMarks(pressed: 0), at: Date(timeIntervalSince1970: 1_760_000_000))
            canvasLine.settle(.unmeasurable, ms: nil, route: nil, why: .canvasEditor)
            let canvasJSON = DictationTimingLog.line(canvasLine).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            expect(canvasJSON["swapOutcome"] as? String == "unmeasurable" && canvasJSON["swapWhy"] as? String == "canvasEditor", "canvas: the line carries the timing reason")
            // 3a. The paste route replaces the whole dictation, never a fragment (Claude, 09:50: edit 86+42 of a 159 field).
            let heardText = "so um the launch is next Tuesday", polishedText = "So the launch is next Tuesday."
            let small = DictationReplace.Edit(location: 90, length: 5, original: "so um", replacement: "So")
            let whole = P.pasteEdit(small, route: .paste, dictationAt: 86, current: heardText, corrected: polishedText)
            expect(whole == DictationReplace.Edit(location: 86, length: heardText.utf16.count, original: heardText, replacement: polishedText),
                   "whole span: the paste route replaces the whole dictation")
            expect(P.pasteEdit(small, route: .accessibility, dictationAt: 86, current: heardText, corrected: polishedText) == small, "whole span: the Accessibility route keeps the smallest edit")
            expect(P.pasteEdit(small, route: .paste, dictationAt: nil, current: heardText, corrected: polishedText) == small, "whole span: no known start keeps the plan's edit")
            // 3b. The re-proof immediately before the ⌘V.
            let n = 159, selected = DictationFieldSnapshot(characters: n, location: 86, length: whole.length)
            func reproof(plan: Int? = 159, proof: Int? = 159, now: DictationFieldSnapshot = selected, text: String? = heardText, key: Int = 5_000) -> P.Skip? {
                P.reproof(planCount: plan, proofCount: proof, now: now, selectedText: text, edit: whole, sinceKeyMs: key)
            }
            expect(reproof() == nil, "re-proof: nothing moved, paste")
            expect(reproof(now: DictationFieldSnapshot(characters: 0, location: 0, length: 0)) == .textMoved, "re-proof: the field emptied by a send skips")
            expect(reproof(proof: 160) == .textMoved, "re-proof: the count changed since the proof skips")
            expect(reproof(plan: 158) == .textMoved, "re-proof: the count changed since the plan read skips")
            expect(reproof(now: DictationFieldSnapshot(characters: nil, location: 86, length: whole.length)) == .fieldGone, "re-proof: an unreadable count skips")
            expect(reproof(plan: nil) == .fieldGone && reproof(proof: nil) == .fieldGone, "re-proof: no count at the plan or the proof skips")
            expect(reproof(now: DictationFieldSnapshot(characters: n, location: 159, length: 0)) == .selectionUnproven, "re-proof: the selection moved skips")
            expect(reproof(now: DictationFieldSnapshot(characters: n, location: 86, length: 3)) == .selectionUnproven, "re-proof: the selection shrank skips")
            expect(reproof(text: "so um the launch") == .selectionUnproven && reproof(text: nil) == .selectionUnproven, "re-proof: the selected text no longer reads as the dictation skips")
            expect(reproof(key: 120) == .typing, "re-proof: a key (Return included) in the last 600 ms skips")
            expect(reproof(key: 599) == .typing && reproof(key: 600) == nil, "re-proof: 600 ms without a key is quiet")
            // 3c. After the ⌘V: the count it must leave (proof count, less the span, plus the new text).
            let expected = n - whole.length + polishedText.utf16.count
            func land(_ after: Int?, read: String?, caret: Int? = nil, final: Bool = true, edit: DictationReplace.Edit = whole, proof: Int = 159) -> P.Landing {
                P.landing(proofCount: proof, after: DictationFieldSnapshot(characters: after, location: caret, length: caret == nil ? nil : 0), edit: edit, readback: read, finalPoll: final)
            }
            expect(land(expected, read: polishedText) == .swapped, "after paste: the expected count and the polished text read back is swapped")
            expect(land(expected, read: nil) == .unconfirmed, "after paste: the expected count, unreadable, is swapped (unconfirmed)")
            expect(land(37, read: nil) == .mismatch, "after paste: 37 where 154 were due is a mismatch (Claude, 09:50)")
            expect(land(37, read: nil, final: false) == .pending, "after paste: before the last poll a wrong count keeps waiting")
            expect(land(n, read: nil, final: true) == .mismatch, "after paste: an unmoved field at the last poll is a mismatch")
            expect(land(expected, read: "something else") == .mismatch, "after paste: the right count with the wrong text read back is a mismatch")
            expect(land(nil, read: nil) == .mismatch, "after paste: an unreadable count at the last poll is a mismatch")
            expect(land(expected + 1, read: polishedText) == .mismatch, "after paste: one character off is a mismatch")
            let same = DictationReplace.Edit(location: 10, length: 5, original: "hello", replacement: "Hello")
            expect(land(20, read: nil, caret: 15, edit: same, proof: 20) == .unconfirmed, "after paste: a same-length swap unreadable needs the caret after the new text")
            expect(land(20, read: nil, caret: 10, edit: same, proof: 20) == .mismatch, "after paste: a same-length swap with the caret not moved is not unconfirmed")
            expect(land(20, read: nil, edit: same, proof: 20) == .mismatch, "after paste: a same-length swap with no caret is not unconfirmed")
            // 3d. What each outcome shows and keeps.
            expect(P.Result.swappedUnconfirmed.swappedIn && P.Result.swapped.swappedIn && !P.Result.mismatch.swappedIn && !P.Result.skipped(.typing).swappedIn,
                   "unconfirmed: a swap that landed by count reads as swapped in")
            expect(!P.keepsPolished(.swappedUnconfirmed) && P.notice(.swappedUnconfirmed, app: "Claude") == nil && !P.offersApply(.swappedUnconfirmed),
                   "unconfirmed: no POLISHED VERSION IN ACTIVITY and no Apply polished")
            expect(P.Result.swappedUnconfirmed.logName == "swappedUnconfirmed" && P.Result.mismatch.logName == "mismatch", "unconfirmed: the line's words")
            expect(P.notice(.mismatch, app: "Claude") == "Check Claude: COS's polish swap may not have landed cleanly", "mismatch: the pill's one line names the app")
            expect(P.keepsPolished(.mismatch) && !P.offersApply(.mismatch), "mismatch: both versions kept in Activity, never Apply polished")
            expect(P.offersApply(.skipped(.notFocused)) && !P.offersApply(.skipped(.copyOnly)) && !P.offersApply(.swapped), "mismatch: Apply polished stays for a skip only")
            expect(!P.watches(.mismatch) && P.watches(.swapped) && P.watches(.swappedUnconfirmed) && P.watches(.skipped(.typing)), "mismatch: Learn from my edits never watches it")
            let watched = P.watch(span: DictationInsertedSpan(pid: 1, location: 86, length: 32), typed: heardText, polished: polishedText, result: .swappedUnconfirmed, swappedAt: 86)
            expect(watched.text == polishedText, "unconfirmed: the learner starts from the polished text, so COS's swap is not the person's edit")
            expect(P.skip(forPaste: .keysHeld) == .keysHeld && P.skip(forPaste: .clipboardChanged) == .notFocused, "keys held: its own skip reason, not notFocused (Slack 09:51)")
            expect(DictationPendingPolish(text: "a", heard: "b", model: .haiku).applies, "mismatch: a pending polish applies unless a mismatch says not")
            for copy in [P.mismatchNotice(app: "Claude")] {
                expect(!copy.contains("\u{2014}") && !copy.contains("\u{2192}") && !copy.contains("->"), "mismatch: copy has no em dash or arrow")
            }
        }
        // 0.5.335 (server 6.85.0): Your polish instructions. Synthetic text only.
        do {
            func expect(_ value: Bool, _ name: String) { precondition(value, name); count += 1 }
            typealias I = DictationPolishInstructions
            let full = String(repeating: "a", count: 1_000), over = String(repeating: "b", count: 1_001)
            expect(I.maximumCharacters == 1_000 && !I.isOver(full) && I.isOver(over), "instructions: 1,000 fits, 1,001 is over")
            expect(!I.isOver("  \n" + full + "\n  ") && I.length("  Use Oxford commas.  ") == 18, "instructions: counted after trimming, as the server counts")
            expect(I.length("\u{1F600}") == 2, "instructions: counted in UTF-16 units, as the server counts")
            expect(I.counter("Use Oxford commas.") == "18 of 1,000 characters" && I.counter(over) == "1,001 of 1,000 characters. Remove 1 to save.",
                   "instructions: the counter, and how many to cut")
            expect(I.canSave(draft: "Use Oxford commas.", saved: "", busy: false), "instructions: a new text can be saved")
            expect(!I.canSave(draft: "Use Oxford commas.", saved: "", busy: true) && !I.canSave(draft: " Use Oxford commas. ", saved: "Use Oxford commas.", busy: false)
                   && !I.canSave(draft: over, saved: "", busy: false) && !I.canSave(draft: "   ", saved: "x", busy: false),
                   "instructions: no Save while saving, when nothing changed, when over the cap, or for an empty box (that is Clear)")
            expect(I.canClear(draft: "", saved: "x", busy: false) && I.canClear(draft: "typed", saved: "", busy: false)
                   && !I.canClear(draft: "  ", saved: "", busy: false) && !I.canClear(draft: "", saved: "x", busy: true),
                   "instructions: Clear when something is saved or typed, never while saving")
            expect(I.visible(available: true) && !I.visible(available: false) && !I.visible(available: nil), "instructions: hidden unless the server says it has them")
            func object(_ data: Data?) -> [String: String]? { data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } }
            expect(object(I.request("get")) == ["operation": "get"] && object(I.request("rules")) == ["operation": "rules"]
                   && object(I.request("clear")) == ["operation": "clear"], "instructions: get, rules and clear send the operation only")
            expect(object(I.request("set", text: "Use Oxford commas.")) == ["operation": "set", "customInstructions": "Use Oxford commas."],
                   "instructions: set sends the words on stdin with the operation")
            expect(I.request("set", text: over) == nil && I.request("set", text: "  ") == nil && I.request("set") == nil
                   && I.request("get", text: "x") == nil && I.request("delete") == nil, "instructions: an over-cap, empty or unknown request is not sent")
            expect(I.saved(available: true, text: "Use Oxford commas.", hash: "0a1b2c3d") == .init(available: true, text: "Use Oxford commas.", instructionsHash: "0a1b2c3d"),
                   "instructions: a saved answer reads its text and hash")
            expect(I.saved(available: false, text: "x", hash: "0a1b2c3d") == .init(available: false, text: "", instructionsHash: nil)
                   && I.saved(available: nil, text: "x", hash: nil).available == false, "instructions: an older server reads as no box and nothing saved")
            expect(I.saved(available: true, text: over, hash: "0a1b2c3d") == .init(available: true, text: "", instructionsHash: nil)
                   && I.saved(available: true, text: "", hash: nil) == .init(available: true, text: "", instructionsHash: nil),
                   "instructions: an answer past the cap reads as nothing saved; empty is off with no hash")
            expect(I.used(flag: true, hash: "0a1b2c3d") == (true, "0a1b2c3d") && I.used(flag: true, hash: "XYZ") == (true, nil)
                   && I.used(flag: true, hash: "0a1b2c3d9") == (true, nil) && I.used(flag: false, hash: "0a1b2c3d") == (false, nil) && I.used(flag: nil, hash: nil) == (false, nil),
                   "instructions: the finalize flag is true only for a JSON true, the hash only 8 lowercase hex")
            expect(I.rulesHeading(version: "v3", rolledBack: false) == "Built-in rules (v3)" && I.rulesHeading(version: "v2", rolledBack: true) == "Built-in rules (v2, rolled back)"
                   && I.rulesHeading(version: "v3; rm", rolledBack: false) == "Built-in rules" && I.rulesHeading(version: nil, rolledBack: nil) == "Built-in rules",
                   "instructions: the rules heading names the version, or nothing it cannot read")
            expect(I.placeholder.split(separator: "\n").count == 3 && I.placeholder.contains("Use Oxford commas.")
                   && I.placeholder.contains("Bottle POS and IT Retail") && I.placeholder.contains("Keep sentences short.") && !I.placeholder.contains("Slack"),
                   "instructions: three example lines, none about an app the model cannot see (0.5.344)")
            for copy in [I.title, I.note, I.offNote, I.placeholder, I.counter(over), I.rulesHeading(version: "v2", rolledBack: true)] {
                expect(!copy.contains("\u{2014}") && !copy.contains("\u{2192}") && !copy.contains("->"), "instructions: copy has no em dash or arrow")
            }
            // The timing line: true or false and the hash, never the words.
            var line = DictationTiming.startFailure(DictationStartMarks(pressed: 0), at: Date(timeIntervalSince1970: 1_760_000_000))
            line.includePolish(DictationPolishRun(outcome: .applied("secret words"), model: .haiku, ms: 2_400, customInstructions: true, instructionsHash: "0a1b2c3d"))
            let json = (try? JSONSerialization.jsonObject(with: DictationTimingLog.line(line) ?? Data()) as? [String: Any]) ?? [:]
            expect(json["polishCustom"] as? Bool == true && json["polishInstructionsHash"] as? String == "0a1b2c3d", "instructions: the timing line says they went, by hash")
            var plain = DictationTiming.startFailure(DictationStartMarks(pressed: 0), at: Date(timeIntervalSince1970: 1_760_000_000))
            plain.includePolish(DictationPolishRun(outcome: .applied("x"), model: .haiku, ms: 1, instructionsHash: "0a1b2c3d"))
            let plainJSON = (try? JSONSerialization.jsonObject(with: DictationTimingLog.line(plain) ?? Data()) as? [String: Any]) ?? [:]
            expect(plainJSON["polishCustom"] as? Bool == false && plainJSON["polishInstructionsHash"] == nil, "instructions: without them the line says false and no hash")
            var none = DictationTiming.startFailure(DictationStartMarks(pressed: 0), at: Date(timeIntervalSince1970: 1_760_000_000))
            none.includePolish(nil)
            let noneJSON = (try? JSONSerialization.jsonObject(with: DictationTimingLog.line(none) ?? Data()) as? [String: Any]) ?? [:]
            expect(noneJSON["polishCustom"] == nil, "instructions: no polish, no field")
        }
        // 0.5.338 Learn from my edits in every app (design: DESIGN_learn_edits_everywhere_0_5_338.md). Fictional text only.
        do {
            typealias EL = DictationEditLearning
            typealias E = DictationReplace.Edit
            func eligible338(_ bundle: String?, electron: Bool = true, chromium: Bool = true, setter: Bool = false,
                             secure: Bool = false, terminal: Bool = false, mode: DictationLearnMode = .automatic) -> EL.Eligibility {
                EL.eligibility(mode: mode, secure: secure, terminal: terminal, electron: electron, chromium: chromium, setterWorked: setter, bundle: bundle)
            }
            expect(eligible338("com.anthropic.claudefordesktop") == .learn, "Claude desktop learns: its watches read the dictation back (canary 2026-10-22)")
            expect(eligible338("com.tinyspeck.slackmacgap") == .learn && EL.proven["com.tinyspeck.slackmacgap"] == "Slack"
                   && !EL.notYet.contains(where: { $0.bundle == "com.tinyspeck.slackmacgap" }),
                   "0.5.340: Slack learns: its watches read the dictation back and stopped cleared on send (canary 2026-10-23)")
            expect(eligible338("com.tinyspeck.slackmacgap", secure: true) == .skip("secure") && eligible338("com.tinyspeck.slackmacgap", mode: .off) == .skip("off"),
                   "0.5.340: Slack still never watches a password field or with learning off")
            expect(eligible338("com.todesktop.230313mzl4w4u92") == .probe,
                   "Cursor is Electron with no canary: measured, never learned")
            expect(eligible338("com.openai.codex", electron: false, chromium: false, setter: true) == .probe
                   && eligible338("com.openai.chat", electron: false, chromium: false, setter: true) == .probe,
                   "ChatGPT reads as native to the structure check but is Chromium: measured, never learned")
            expect(eligible338("com.google.Chrome", electron: false, chromium: true, setter: false) == .probe
                   && eligible338("ai.perplexity.comet", electron: false, chromium: true, setter: true) == .learn,
                   "a browser's rich editor is measured; its plain field (the set moved it) learns, as in 0.5.318")
            expect(eligible338("com.apple.Safari", electron: false, chromium: false, setter: true) == .learn && eligible338(nil, electron: true) == .probe,
                   "a native app learns; an Electron app with no bundle id is measured")
            expect(eligible338("com.anthropic.claudefordesktop", secure: true) == .skip("secure")
                   && eligible338("com.anthropic.claudefordesktop", terminal: true) == .skip("terminal")
                   && eligible338("com.anthropic.claudefordesktop", mode: .off) == .skip("off"),
                   "a proven app still never watches a password field, a terminal, or with learning off")
            expect(EL.notYetNames == ["Cursor", "ChatGPT"], "Settings names each not-yet app once, in order")
            expect(EL.settingNote.contains("Not available yet in Cursor, ChatGPT, or text boxes in Chrome and Comet")
                   && EL.settingNote.contains("Works in native apps, Claude and Slack.") && !EL.settingNote.contains("\u{2014}") && !EL.settingNote.contains("\u{2192}")
                   && !EL.settingNote.contains("until you leave the field or send the message") && EL.settingNote.contains("a few style habits (Your style)"),
                   "the Settings line names where learning works and where it does not yet, from the same table, with no em dash or arrow")
            // Track the field, not the element.
            let watched = EL.FieldIdentity(pid: 42, role: "AXTextArea", identifier: nil, frame: CGRect(x: 100, y: 600, width: 500, height: 40))
            func moved(_ f: CGRect, role: String = "AXTextArea", pid: Int32 = 42, id: String? = nil) -> EL.FieldIdentity {
                EL.FieldIdentity(pid: pid, role: role, identifier: id, frame: f)
            }
            func focus(_ now: EL.FieldIdentity?, frontmost: Bool = true, same: Bool = false, window: Bool = true, rebinds: Int = 0, from: EL.FieldIdentity? = nil) -> EL.Focus {
                EL.focus(frontmost: frontmost, sameElement: same, watched: from ?? watched, now: now, sameWindow: window, rebinds: rebinds)
            }
            expect(focus(nil, same: true) == .same && focus(nil, frontmost: false, same: true) == .left("app"), "the same element holds; another app in front leaves")
            expect(focus(moved(CGRect(x: 100, y: 520, width: 500, height: 120))) == .rebound
                   && focus(moved(CGRect(x: 103, y: 600, width: 497, height: 90))) == .rebound,
                   "a re-mounted composer that grew up (bottom kept) or down (top kept) is the same field")
            expect(focus(moved(CGRect(x: 100, y: 300, width: 500, height: 40))) == .left("frame")
                   && focus(moved(CGRect(x: 105, y: 600, width: 500, height: 40))) == .left("frame")
                   && focus(moved(CGRect(x: 100, y: 600, width: 505, height: 40))) == .left("frame"),
                   "moved more than 4 points on both edges, or the left edge or width more than 4: another field")
            expect(focus(moved(CGRect(x: 104, y: 604, width: 504, height: 40))) == .rebound, "4 points is still the same field")
            expect(focus(moved(watched.frame!), window: false) == .left("window") && focus(moved(watched.frame!, role: "AXButton")) == .left("role")
                   && focus(moved(watched.frame!, pid: 7)) == .left("pid") && focus(nil) == .left("none")
                   && focus(EL.FieldIdentity(pid: 42, role: "AXTextArea", identifier: nil, frame: nil)) == .left("frame"),
                   "another window, role or process, or no frame to compare, is not the field")
            let tagged = EL.FieldIdentity(pid: 42, role: "AXTextArea", identifier: "composer", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
            expect(focus(moved(CGRect(x: 900, y: 0, width: 80, height: 10), id: "composer"), window: false, from: tagged) == .rebound
                   && focus(moved(tagged.frame!, id: "search"), from: tagged) == .left("identifier")
                   && focus(moved(tagged.frame!, id: ""), from: tagged) == .rebound,
                   "a matching identifier decides, even moved or in another window; a different one leaves; an empty one falls back to the frame")
            expect(focus(moved(watched.frame!), rebinds: EL.maximumRebinds - 1) == .rebound && focus(moved(watched.frame!), rebinds: EL.maximumRebinds) == .left("churn"),
                   "eight rebinds at most: a field that keeps re-mounting ends the watch")
            // Re-anchor on the dictated words instead of "lost".
            let said338 = "please email Jerry Sakolik about the launch plan today"
            let page338 = "Notes: " + said338 + " Thanks."
            let start338 = 7, length338 = (said338 as NSString).length
            expect(EL.follow(baseline: page338, current: "\n", start: start338, length: length338) == .cleared
                   && EL.follow(baseline: page338, current: "", start: start338, length: length338) == .cleared
                   && EL.follow(baseline: page338, current: "  ", start: start338, length: length338) == .cleared,
                   "a blank field (Chromium's empty composer reads as one newline) is a sent message, not a lost dictation")
            expect(EL.follow(baseline: "\n", current: "\n", start: 0, length: 1) == .unchanged, "a field that was already blank is not cleared again")
            let fixed338 = page338.replacingOccurrences(of: "Sakolik", with: "Sokolic")
            expect(EL.follow(baseline: page338, current: fixed338, start: start338, length: length338)
                   == .inside(E(location: 19, length: 7, original: "Sakolik", replacement: "Sokolic"), length: length338),
                   "a fix inside the dictation is inside, as before")
            let glued = "Notes" + said338.replacingOccurrences(of: "please", with: "pleese")
            let gluedFixed = "Notes" + said338
            expect(EL.track(baseline: glued, current: gluedFixed, start: 5, length: length338) == .lost
                   && EL.follow(baseline: glued, current: gluedFixed, start: 5, length: length338)
                   == .inside(E(location: 0, length: 6, original: "pleese", replacement: "please"), length: length338),
                   "a fix of a first word glued to the text before it was lost; now it is inside, widened only to the dictation's edge")
            let tailGlued = said338 + "Bye"
            let tailFixed = said338.replacingOccurrences(of: "today", with: "tooday") + "Bye"
            expect(EL.follow(baseline: tailGlued, current: tailFixed, start: 0, length: length338)
                   == .inside(E(location: length338 - 5, length: 5, original: "today", replacement: "tooday"), length: length338 + 1),
                   "a fix of a last word glued to the text after it stops at the dictation's edge")
            let rewritten = "Hello Jerry, " + "please email Jerry Sokolic about the launch plan today" + " Thanks."
            expect(EL.follow(baseline: page338, current: rewritten, start: start338, length: length338)
                   == .reanchored(start: 13, length: length338, edit: E(location: 19, length: 7, original: "Sakolik", replacement: "Sokolic")),
                   "an edit across its edge plus a fix inside it: found again by its first and last words, the fix inside reported")
            expect(EL.follow(baseline: page338, current: "Hello, " + said338 + " Thanks.", start: start338, length: length338) != .lost,
                   "the same dictation after a rewritten prefix is found again")
            expect(EL.follow(baseline: page338, current: "Hi. Totally different words here now. Bye.", start: start338, length: length338) == .lost
                   && EL.follow(baseline: page338, current: "Notes: totally different words here now. Thanks.", start: start338, length: length338)
                   != .lost,
                   "a dictation rewritten past recognition, across its edges, is lost; a rewrite inside its edges is an inside edit, which the word cap refuses")
            expect(EL.reanchor(said338, in: "x " + said338 + " y").map { $0.start == 2 && $0.length == length338 } == true,
                   "the exact dictation once is found where it is")
            expect(EL.reanchor(said338, in: said338 + " " + said338) == nil, "the exact dictation twice is ambiguous")
            expect(EL.reanchor("call Jerry today", in: "call Jerri today") == nil, "three words or fewer need the exact text")
            let twoHeads = "please email Jerry about this. please email Jerry Sokolic about the launch plan today"
            expect(EL.reanchor(said338, in: twoHeads) == nil, "a first word run found twice is ambiguous")
            let wide = "please email Jerry " + String(repeating: "word ", count: 40) + "launch plan today"
            expect(EL.reanchor(said338, in: wide) == nil, "anchors further apart than twice the dictation plus 16 are not it")
            expect(EL.reanchor(said338, in: "launch plan today please email Jerry") == nil, "the last words before the first are not it")
            expect(EL.reanchor(said338, in: "xplease email Jerry Sokolic about the launch plan today") == nil,
                   "anchors count only on word boundaries")
            // Confidence rules.
            let plain338: Set<String> = ["please", "the", "tuna", "fish", "launch"]
            func learn338(_ heard: String, _ written: String) -> EL.Candidate? {
                EL.candidate(E(location: 0, length: heard.utf16.count, original: heard, replacement: written),
                             known: { plain338.contains($0.lowercased()) }, learned: { _, _ in false })
            }
            expect(learn338("Sakolik", "Sokolic") == .init(heard: "Sakolik", written: "Sokolic"), "Jeremy's surname fixed by hand is learned")
            expect(learn338("teh", "the") == nil && learn338("tunna", "tuna") == nil && learn338("feesh", "fish") == nil,
                   "a fix to a plain English word is a typo fix, never a dictionary term")
            expect(EL.allowsAnother(learned: 0) && EL.allowsAnother(learned: EL.maximumLearnedPerWatch - 1) && !EL.allowsAnother(learned: EL.maximumLearnedPerWatch)
                   && EL.maximumLearnedPerWatch == 2, "two learned pairs per watch at most")
            // The watch ends cleared when a Chromium field drops to its empty newline.
            expect(EL.stop(elapsed: 5, reads: 2, appRunning: true, secure: false, focused: true, fieldCharacters: 1, dictationLength: 40) == .cleared
                   && EL.stop(elapsed: 5, reads: 2, appRunning: true, secure: false, focused: true, fieldCharacters: 1, dictationLength: 1) == nil
                   && EL.stop(elapsed: 5, reads: 2, appRunning: true, secure: false, focused: true, fieldCharacters: 2, dictationLength: 40) == nil,
                   "a field down to one character, under a longer dictation, was sent or cleared")
            // The canary ledger: counts, verdicts and the bundle id; never text.
            let canary = DictationLearnCanary(at: "2026-10-22T21:00:00Z", bundle: "com.anthropic.claudefordesktop", eligibility: "learn", readable: true,
                                              reads: 3, stop: "cleared", rebinds: 1, reanchors: 0, inside: 1, candidates: 1, learned: 1, focusWhy: "frame")
            let canaryLine = DictationLearnCanaryLog.line(canary).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            expect(canaryLine.hasSuffix("}\n") && canaryLine.contains("\"stop\":\"cleared\"") && canaryLine.contains("\"rebinds\":1")
                   && Set((try? JSONSerialization.jsonObject(with: Data(canaryLine.utf8)) as? [String: Any])?.keys.map { $0 } ?? [])
                   == ["at", "bundle", "eligibility", "readable", "reads", "stop", "rebinds", "reanchors", "inside", "candidates", "learned", "focusWhy"],
                   "one canary line per watch, exactly these fields: no text, no word pair")
            expect(DictationLearnCanaryLog.fileName == "learn-canary.jsonl" && DictationLearnCanaryLog.maximumBytes == 128 * 1024, "a 128 KB canary file")
            let canaryDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cos-canary-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: canaryDir) }
            let canaryURL = canaryDir.appendingPathComponent(DictationLearnCanaryLog.fileName)
            for _ in 0..<((DictationLearnCanaryLog.maximumBytes / canaryLine.utf8.count) + 3) { DictationLearnCanaryLog.append(canary, to: canaryURL) }
            let canarySize = (try? FileManager.default.attributesOfItem(atPath: canaryURL.path)[.size] as? Int) ?? 0
            expect(canarySize > 0 && canarySize <= DictationLearnCanaryLog.maximumBytes && FileManager.default.fileExists(atPath: canaryURL.path + ".1")
                   && ((try? FileManager.default.attributesOfItem(atPath: canaryURL.path)[.posixPermissions] as? Int) ?? 0) == 0o600,
                   "the canary file rotates at its cap and is private")
        }
        print("PASS Mac dictation: \(count) policy checks; insert-target table, measured delivery, terminals, layout ⌘V, listening bars end to end, clipboard restore, sounds, pill placement, recent dictations file, card countdown, fix-a-word selection, quick fix, replace, span guess, quiet and restore, bounded audio, PCM16 WAV, device failure, any-key triggers, field context and its evidence, AI polish, release tail and timing, truthful start, smooth start, missed releases, early polish, paste first and polish in place, Chromium by structure, canvas editors, paste-route swap safety, polish instructions, learning in every app (0.5.338)")
    }
}
