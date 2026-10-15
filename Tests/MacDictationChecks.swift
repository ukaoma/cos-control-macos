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
        print("PASS Mac dictation: \(count) policy checks; field/caret/secure-focus guards, bounded audio, PCM16 WAV, device failure")
    }
}
