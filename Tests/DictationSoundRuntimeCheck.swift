import Foundation
import AVFoundation
import os

// 0.5.314: 0.5.313 crashed (EXC_BREAKPOINT, dispatch_assert_queue) every time a dictation start or stop sound finished:
// the completion closure was formed inside @MainActor DictationSoundPlayer and AVAudioPlayerNode called it on its own
// queue. Source pins cannot see that, so this EXECUTES the real player: run-dictation-sound-runtime.sh lifts the class
// verbatim out of Sources/MacDictation.swift, compiles it in Swift 6 mode, plays a short silent sound at volume 0, and
// requires the engine to stop by itself, which only the completion callback does.

let dictationLog = Logger(subsystem: "com.gotcos.control.tests", category: "dictation")

@main struct DictationSoundRuntimeCheck {
    @MainActor static func main() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cos-sound-check-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410)!
            buffer.frameLength = 4_410  // 0.1 s of silence
            try file.write(from: buffer)
        }
        let player = DictationSoundPlayer()
        for round in 1...2 {  // twice: the second play reuses the connected engine
            // 0.5.328: the player lives on DictationAudioQueues.output, as the app drives it.
            DictationAudioQueues.output.sync { player.play(url, volume: 0, semitones: 0) }
            guard DictationAudioQueues.output.sync(execute: { player.isRunning }) else {
                FileHandle.standardError.write("FAIL: sound engine did not start (no output device?); the check proves nothing\n".data(using: .utf8)!)
                exit(1)
            }
            var waited = 0
            while DictationAudioQueues.output.sync(execute: { player.isRunning }) && waited < 60 { try await Task.sleep(nanoseconds: 50_000_000); waited += 1 }
            guard !DictationAudioQueues.output.sync(execute: { player.isRunning }) else {
                FileHandle.standardError.write("FAIL: round \(round): the sound's completion never stopped the engine\n".data(using: .utf8)!)
                exit(1)
            }
        }
        print("PASS dictation sound runtime: a played sound's completion runs off-main without trapping and stops the engine (2 rounds)")
    }
}
