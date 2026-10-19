import Foundation
import AVFoundation
import CoreAudio

// 0.5.327 truthful-start canary, on THIS Mac's real default microphone. Run by hand (it opens the microphone for a few
// seconds in total), never by Tests/run.sh: run-dictation-start-canary.sh lifts DictationAudioDevices,
// DictationMicrophoneCapture and its converter verbatim out of Sources/MacDictation.swift and compiles them with
// MacDictationCore, so every number below is the shipped capture code's, not a re-implementation.
//
// Each round measures press to first buffer three ways, numbers only (no audio is kept):
//   0.5.326 order:  read the microphone list, then a fresh engine (the mute it also built first cannot run here);
//   fresh:          DictationStart.resolve (no list), then a fresh engine;
//   spare:          an engine warmed a second earlier (DictationSpare), then started.
// And it reads this process's own input-running flag (the one behind the orange microphone indicator) while a spare
// waits and after every stop: it must be off both times. FAIL on a missing first buffer or a microphone left running.

func uptimeMs() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }

/// This process's own "running input" flag (macOS 14.2+), nil when the HAL has no process object for it yet.
func ownInputRunning() -> Bool? {
    var pid = getpid()
    var object = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object) == noErr,
          object != kAudioObjectUnknown else { return nil }
    var running = UInt32(0)
    size = UInt32(MemoryLayout<UInt32>.size)
    address.mSelector = kAudioProcessPropertyIsRunningInput
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running) == noErr else { return nil }
    return running != 0
}

@MainActor func firstBuffer(_ capture: DictationMicrophoneCapture) async -> Double? {
    let deadline = ProcessInfo.processInfo.systemUptime + Double(DictationStart.firstBufferTimeoutMs) / 1000
    while ProcessInfo.processInfo.systemUptime < deadline {
        if let at = capture.firstAudioUptime { return at * 1000 }
        if capture.failure != nil { return nil }
        try? await Task.sleep(for: .milliseconds(DictationStart.pollMs))
    }
    return nil
}

@main struct DictationStartCanary {
    @MainActor static func main() async {
        let arguments = CommandLine.arguments
        let rounds = arguments.count > 1 ? Int(arguments[1]) ?? 5 : 5
        let evidence = arguments.count > 2 ? URL(fileURLWithPath: arguments[2]) : nil
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            print("SKIP dictation start canary: this process may not use the microphone (status \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)); "
                  + "run it from a terminal that has Microphone access, or read the timing file after a real dictation")
            exit(2)
        }
        guard let device = DictationAudioDevices.defaultInput() else { print("FAIL: no default input device"); exit(1) }
        let bluetooth = DictationAudioDevices.isBluetooth(device)
        print("default input: id \(device), nominal \(DictationAudioDevices.nominalSampleRate(device) ?? 0) Hz, bluetooth \(bluetooth)")
        var rows: [[String: Any]] = []
        var problems: [String] = []
        func close(_ capture: DictationMicrophoneCapture, _ label: String) async {
            _ = try? capture.stop()
            try? await Task.sleep(for: .milliseconds(150))
            if ownInputRunning() == true { problems.append("\(label): the microphone was still running after stop") }
        }
        for round in 1...rounds {
            var row: [String: Any] = ["round": round]
            // 0.5.326 order: the list, then a fresh engine.
            do {
                let pressed = uptimeMs()
                let listMs = { let t = uptimeMs(); _ = DictationAudioDevices.inputs(); return uptimeMs() - t }()
                let capture = DictationMicrophoneCapture()
                try capture.start(deviceID: nil)
                guard let at = await firstBuffer(capture) else { problems.append("round \(round) 0.5.326 order: no first buffer"); await close(capture, "0.5.326"); continue }
                row["old_listMs"] = Int(listMs.rounded()); row["old_pressToFirstBufferMs"] = Int((at - pressed).rounded())
                try? await Task.sleep(for: .milliseconds(250))
                await close(capture, "round \(round) 0.5.326 order")
            } catch { problems.append("round \(round) 0.5.326 order: \(error.localizedDescription)") }
            try? await Task.sleep(for: .milliseconds(400))
            // Fresh: no list, a fresh engine.
            do {
                let pressed = uptimeMs()
                let chosen = DictationStart.resolve(selectedUID: "", cached: [:], uidOf: { DictationAudioDevices.uid(of: $0) }, enumerate: { [:] })
                precondition(chosen.device == .systemDefault && !chosen.listRead)
                let capture = DictationMicrophoneCapture()
                let opening = uptimeMs()
                try capture.start(deviceID: nil)
                row["fresh_engineStartMs"] = Int((uptimeMs() - opening).rounded())
                guard let at = await firstBuffer(capture) else { problems.append("round \(round) fresh: no first buffer"); await close(capture, "fresh"); continue }
                row["fresh_pressToFirstBufferMs"] = Int((at - pressed).rounded())
                try? await Task.sleep(for: .milliseconds(250))
                await close(capture, "round \(round) fresh")
            } catch { problems.append("round \(round) fresh: \(error.localizedDescription)") }
            // Spare: warmed off the press, idle for a second (the microphone must stay off), then started.
            if DictationSpare.mayWarm(enabled: true, authorized: true, bluetooth: bluetooth) {
                do {
                    let warming = uptimeMs()
                    let spare = DictationMicrophoneCapture()
                    try spare.warm(deviceID: nil)
                    let warmed = DictationSpare.Warmed(device: device, selectedUID: "", sampleRate: DictationAudioDevices.nominalSampleRate(device) ?? 0,
                                                       at: ProcessInfo.processInfo.systemUptime)
                    row["spare_warmMs"] = Int((uptimeMs() - warming).rounded())
                    try? await Task.sleep(for: .seconds(1))
                    let idle = ownInputRunning()
                    row["spare_idleInputRunning"] = idle.map { $0 ? 1 : 0 } ?? -1
                    if idle == true { problems.append("round \(round): a waiting spare had the microphone running") }
                    // Exactly the app's check, so a spare the app would discard is counted as a failure here.
                    let verdict = DictationSpare.check(warmed, selectedUID: "", device: DictationAudioDevices.defaultInput(),
                                                       sampleRate: DictationAudioDevices.nominalSampleRate(device), bluetooth: bluetooth,
                                                       now: ProcessInfo.processInfo.systemUptime)
                    row["spare_verdict"] = verdict == .use ? "use" : "\(verdict)"
                    if verdict != .use { problems.append("round \(round): the app would discard this spare (\(verdict))") }
                    let pressed = uptimeMs()
                    try spare.start(deviceID: nil)
                    row["spare_engineStartMs"] = Int((uptimeMs() - pressed).rounded())
                    guard let at = await firstBuffer(spare) else { problems.append("round \(round) spare: no first buffer"); await close(spare, "spare"); continue }
                    row["spare_pressToFirstBufferMs"] = Int((at - pressed).rounded())
                    try? await Task.sleep(for: .milliseconds(250))
                    await close(spare, "round \(round) spare")
                } catch { problems.append("round \(round) spare: \(error.localizedDescription)") }
            }
            rows.append(row)
            print(row.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            try? await Task.sleep(for: .milliseconds(500))
        }
        func median(_ key: String) -> Int? {
            let values = rows.compactMap { $0[key] as? Int }.sorted()
            return values.isEmpty ? nil : values[values.count / 2]
        }
        let summary: [String: Any] = [
            "rounds": rows.count, "problems": problems,
            "median_old_pressToFirstBufferMs": median("old_pressToFirstBufferMs") ?? -1,
            "median_fresh_pressToFirstBufferMs": median("fresh_pressToFirstBufferMs") ?? -1,
            "median_spare_pressToFirstBufferMs": median("spare_pressToFirstBufferMs") ?? -1,
            "median_old_listMs": median("old_listMs") ?? -1, "median_spare_warmMs": median("spare_warmMs") ?? -1,
        ]
        if let evidence {
            try? FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: ["summary": summary, "rounds": rows], options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: evidence.appendingPathComponent("start-canary.json"))
            }
        }
        print("medians (press to first buffer, ms): 0.5.326 order \(summary["median_old_pressToFirstBufferMs"]!), fresh \(summary["median_fresh_pressToFirstBufferMs"]!), spare \(summary["median_spare_pressToFirstBufferMs"]!); list read \(summary["median_old_listMs"]!) ms, spare warm \(summary["median_spare_warmMs"]!) ms (off the press)")
        if problems.isEmpty {
            print("PASS dictation start canary: \(rows.count) rounds, a first buffer every time, the microphone off while a spare waits and after every stop")
        } else {
            print("FAIL dictation start canary: " + problems.joined(separator: "; "))
            exit(1)
        }
    }
}
