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

// 0.5.328: the main thread's longest stall while a dictation starts, the 0.5.327 way (engine start and a mute-like
// private aggregate device built and started on the main thread) and the 0.5.328 way (both on DictationAudioQueues).
// The aggregate is the mute without its tap (the tap needs System Audio Recording and would silence this Mac): a private
// aggregate on the default output with a silent IO proc, started and torn down. The heartbeat is a 16 ms main-queue timer
// feeding the shipped DictationStallMeter.

final class CanaryAggregate: @unchecked Sendable {
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    func up() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var output = AudioObjectID(kAudioObjectUnknown); var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &output) == noErr,
              let uid = DictationAudioDevices.uid(of: output) else { return }
        let composition: [String: Any] = [kAudioAggregateDeviceNameKey: "COS start canary", kAudioAggregateDeviceUIDKey: "com.gotcos.start-canary.\(UUID().uuidString)",
                                          kAudioAggregateDeviceMainSubDeviceKey: uid, kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceIsStackedKey: false,
                                          kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]]]
        guard AudioHardwareCreateAggregateDevice(composition as CFDictionary, &device) == noErr else { return }
        _ = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { @Sendable _, _, _, _, _ in }
        _ = AudioDeviceStart(device, proc)
    }
    func down() {
        guard device != kAudioObjectUnknown else { return }
        _ = AudioDeviceStop(device, proc); if let proc { _ = AudioDeviceDestroyIOProcID(device, proc) }
        _ = AudioHardwareDestroyAggregateDevice(device); device = AudioObjectID(kAudioObjectUnknown)
    }
}

/// 0.5.329: what the early polish costs the press: a helper process launched from a detached task at the press, as
/// startPrewarm does (a Python process that waits a second stands in for the helper and its 2 s request).
func detachedProcessAtPress() {
    Task.detached(priority: .utility) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import time; time.sleep(1)"]
        try? process.run(); process.waitUntilExit()
    }
}

@MainActor func stallRound(offMain: Bool, prewarm: Bool = false) async -> (stallMs: Int, firstBufferMs: Int)? {
    let pressed = ProcessInfo.processInfo.systemUptime
    if prewarm { detachedProcessAtPress() }
    let meter = DictationStallMeter(start: pressed)
    let beat = DispatchSource.makeTimerSource(queue: .main)
    beat.schedule(deadline: .now(), repeating: .milliseconds(DictationStallMeter.tickMilliseconds))
    beat.setEventHandler { _ = meter.tick(ProcessInfo.processInfo.systemUptime) }
    beat.resume()
    defer { beat.cancel() }
    let aggregate = CanaryAggregate()
    let capture: DictationMicrophoneCapture
    if offMain {
        guard let opened = try? await DictationAudioQueues.perform(on: DictationAudioQueues.input, { () throws -> DictationMicrophoneCapture in
            let c = DictationMicrophoneCapture(); try c.start(deviceID: nil); return c
        }) else { return nil }
        capture = opened
    } else {
        capture = DictationMicrophoneCapture()
        guard (try? capture.start(deviceID: nil)) != nil else { return nil }
    }
    guard let at = await firstBuffer(capture) else { _ = try? capture.stop(); return nil }
    if offMain { DictationAudioQueues.output.async { aggregate.up() } } else { aggregate.up() }
    meter.end(at: ProcessInfo.processInfo.systemUptime + 1)
    try? await Task.sleep(for: .milliseconds(1_100))
    _ = try? capture.stop()
    if offMain { DictationAudioQueues.output.sync { aggregate.down() } } else { aggregate.down() }
    return (meter.maxGapMs ?? -1, Int((at - pressed * 1000).rounded()))  // firstBuffer returns milliseconds
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
        // Main-thread stall: the 0.5.327 way and the 0.5.328 way, alternating.
        var stalls: [[String: Any]] = []
        for round in 1...rounds {
            var row: [String: Any] = ["round": round]
            if let old = await stallRound(offMain: false) { row["stall_onMainMs"] = old.stallMs; row["stall_onMain_firstBufferMs"] = old.firstBufferMs }
            else { problems.append("round \(round): no first buffer (on main)") }
            try? await Task.sleep(for: .milliseconds(400))
            if let new = await stallRound(offMain: true) { row["stall_offMainMs"] = new.stallMs; row["stall_offMain_firstBufferMs"] = new.firstBufferMs }
            else { problems.append("round \(round): no first buffer (off main)") }
            try? await Task.sleep(for: .milliseconds(400))
            if let warm = await stallRound(offMain: true, prewarm: true) { row["stall_prewarmMs"] = warm.stallMs; row["stall_prewarm_firstBufferMs"] = warm.firstBufferMs }
            else { problems.append("round \(round): no first buffer (with the early polish)") }
            if ownInputRunning() == true { problems.append("round \(round): the microphone was still running after the stall rounds") }
            stalls.append(row)
            print(row.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            try? await Task.sleep(for: .milliseconds(400))
        }
        rows += stalls
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
            "median_stall_onMainMs": median("stall_onMainMs") ?? -1, "median_stall_offMainMs": median("stall_offMainMs") ?? -1,
            "max_stall_offMainMs": rows.compactMap { $0["stall_offMainMs"] as? Int }.max() ?? -1,
            "median_stall_prewarmMs": median("stall_prewarmMs") ?? -1, "max_stall_prewarmMs": rows.compactMap { $0["stall_prewarmMs"] as? Int }.max() ?? -1,
            "max_stall_onMainMs": rows.compactMap { $0["stall_onMainMs"] as? Int }.max() ?? -1,
        ]
        if let evidence {
            try? FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: ["summary": summary, "rounds": rows], options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: evidence.appendingPathComponent("start-canary.json"))
            }
        }
        print("medians (press to first buffer, ms): 0.5.326 order \(summary["median_old_pressToFirstBufferMs"]!), fresh \(summary["median_fresh_pressToFirstBufferMs"]!), spare \(summary["median_spare_pressToFirstBufferMs"]!); list read \(summary["median_old_listMs"]!) ms, spare warm \(summary["median_spare_warmMs"]!) ms (off the press)")
        if let on = summary["median_stall_onMainMs"] as? Int, let off = summary["median_stall_offMainMs"] as? Int, on > 0, off >= on {
            problems.append("moving the work off the main thread did not shorten the main thread's stall (\(off) ms vs \(on) ms)")
        }
        if let off = summary["median_stall_offMainMs"] as? Int, let warm = summary["median_stall_prewarmMs"] as? Int, off > 0, warm > max(off * 2, 50) {
            problems.append("the early polish at the press lengthened the main thread's stall (\(warm) ms vs \(off) ms)")
        }
        print("with the early polish started at the press (0.5.329): median \(summary["median_stall_prewarmMs"]!) max \(summary["max_stall_prewarmMs"]!)")
        print("main-thread stall (ms, 16 is smooth): 0.5.327 way median \(summary["median_stall_onMainMs"]!) max \(summary["max_stall_onMainMs"]!); 0.5.328 way median \(summary["median_stall_offMainMs"]!) max \(summary["max_stall_offMainMs"]!)")
        if problems.isEmpty {
            print("PASS dictation start canary: \(rounds) start rounds and \(rounds) stall pairs, a first buffer every time, the microphone off while a spare waits and after every stop")
        } else {
            print("FAIL dictation start canary: " + problems.joined(separator: "; "))
            exit(1)
        }
    }
}
