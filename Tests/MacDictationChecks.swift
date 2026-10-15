import Foundation

@main struct MacDictationChecks {
    static func main() throws {
        var count = 0
        for samePID in [false, true] { for element in [false, true] { for selection in [false, true] {
            for secure in [false, true] { for trusted in [false, true] {
                let got = MacDictationPolicy.mayInsert(originalPID: 42, currentPID: samePID ? 42 : 99,
                    sameElement: element, sameSelection: selection, secure: secure, trusted: trusted)
                precondition(got == (samePID && element && selection && !secure && trusted))
                count += 1
            }}
        }}}
        precondition(!MacDictationPolicy.mayInsert(originalPID: 0, currentPID: 0, sameElement: true, sameSelection: true, secure: false, trusted: true))
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
        print("PASS Mac dictation: \(count) policy checks; field/caret/secure-focus guards, bounded audio, PCM16 WAV, device failure, any-key triggers")
    }
}
