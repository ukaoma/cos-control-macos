import CoreAudio
import CoreGraphics
import Foundation
import os

/// Desktop dictation is a user gesture, separate from meeting recording and glasses gestures.
enum MacDictationPolicy {
    static let maximumSeconds = 120
    static let maximumPCMBytes = maximumSeconds * 16_000 * 2
    /// 0.5.313 (Miles 2026-10-15): a dictation something else ends (a key chord while talking, sleep, a session switch) is
    /// transcribed and copied, never thrown away, once it holds this much audio. Under a second is a shortcut combination
    /// (Fn+arrow) or a stray tap, not speech worth a card. 16 kHz mono Int16: 32,000 bytes a second.
    static let salvageMinimumBytes = 16_000 * 2
    static func salvages(pcmBytes: Int) -> Bool { pcmBytes >= salvageMinimumBytes }
    static func mayStart(enabled: Bool, busy: Bool) -> Bool {
        enabled && !busy
    }
    static func wav(_ pcm: Data) throws -> Data {
        guard !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= maximumPCMBytes else {
            throw NSError(domain: "COSDictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Dictation audio is empty or exceeds two minutes."])
        }
        var result = Data()
        func ascii(_ s: String) { result.append(contentsOf: s.utf8) }
        func u16(_ x: UInt16) { var n = x.littleEndian; withUnsafeBytes(of: &n) { result.append(contentsOf: $0) } }
        func u32(_ x: UInt32) { var n = x.littleEndian; withUnsafeBytes(of: &n) { result.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(pcm.count + 36)); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        ascii("data"); u32(UInt32(pcm.count)); result.append(pcm)
        return result
    }
}

// MARK: - Release tail (0.5.326)
//
// Miles, 2026-10-18 21:21: "It keeps happening now": the last word or two of a dictation went missing unless he held the
// key about a second longer. 0.5.325 closed the microphone the instant the key came up, so the speech still in flight
// (the input device's latency plus the tap's 2,048-frame buffer, roughly 50 to 150 ms) and the resampler's last
// samples were dropped. Now a person's stop keeps listening for a short tail, then closes the microphone and drains
// the converter.

enum DictationReleaseTail {
    /// The tail after a person's stop. Long enough for in-flight audio and a trailing consonant; short enough that the
    /// wait before transcription is not felt.
    static let milliseconds = 300
    /// How listening ends. Only the person's own stop (the hold key released, the toggle pressed again) takes the tail:
    /// the two-minute limit, a microphone failure and an interruption (a chord, sleep, a session switch) close at once,
    /// and cancel, quit and turning dictation off never transcribe at all.
    enum Ending: Sendable { case released, maximum, failure, interrupted }
    static func tail(for ending: Ending) -> Int { ending == .released ? milliseconds : 0 }
    /// A press while the tail runs: the microphone is still open and nothing has been sent, so the same dictation goes on
    /// (the release came early). It is never a second dictation, so no audio is lost and none is shared between two.
    enum PressDuringTail: Equatable, Sendable { case extend, normal }
    static func press(tailing: Bool, phase: String) -> PressDuringTail { tailing && phase == "Listening" ? .extend : .normal }
    /// 16 kHz mono Int16: 32 bytes a millisecond.
    static func bytes(milliseconds: Int) -> Int { max(0, milliseconds) * 32 }
    /// RMS level of a PCM16 byte range in dBFS, nil when the range is empty. Numbers only, for the timing line.
    static func dBFS(_ pcm: Data, from: Int, to: Int) -> Double? {
        let lower = max(0, min(from, pcm.count)) / 2 * 2, upper = max(0, min(to, pcm.count)) / 2 * 2
        guard upper > lower else { return nil }
        var sum = 0.0
        pcm.withUnsafeBytes { raw in
            for offset in stride(from: lower, to: upper, by: 2) {
                let x = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32768
                sum += x * x
            }
        }
        let rms = (sum / Double((upper - lower) / 2)).squareRoot()
        return rms > 0 ? (20 * log10(rms) * 10).rounded() / 10 : -120
    }
}

/// One dictation's timing: numbers and identifiers only, never text or audio. One JSON line each in
/// ~/Library/Application Support/COS Control/dictation-timing.jsonl, the authoritative record: on Miles's Mac,
/// `log show` returned no com.gotcos.control lines for 90 minutes of 0.5.325 dictations (2026-10-18), so the log line
/// with the same numbers is a convenience only.
struct DictationTiming: Codable, Equatable, Sendable {
    var at: String
    /// Key up (or toggle) to the microphone closed: the tail plus the close itself.
    var releaseToClosedMs: Int
    var tailMs: Int
    var capturedSeconds: Double
    /// Speech level of the 250 ms before the release and of the tail after it. A loud tail is speech the tail saved.
    var finalDBFS: Double?
    var tailDBFS: Double?
    var engine: String?
    var transcribeMs: Int?
    var polishMs: Int?
    /// 0.5.326: AI polish, when it ran: the model (haiku or sonnet) and DictationPolish.Outcome.logName.
    var polishModel: String? = nil
    var polishOutcome: String? = nil
    /// 0.5.329 (server 6.79.2): the polish process started at the press: used, missed, discarded, or none (no token
    /// went with the polish). prewarmMs: how long the helper took to start it.
    var polishPrewarm: String? = nil
    var prewarmMs: Int? = nil
    /// 0.5.335 (server 6.85.0): whether the person's polish instructions went to the model, and the server's 8-hex hash
    /// of them. Never the words. Absent when polish did not run.
    var polishCustom: Bool? = nil
    var polishInstructionsHash: String? = nil
    /// typed, copied, no_speech, failed, canceled.
    var outcome: String
    /// 0.5.327 truthful start (DictationStartMarks): the press to the microphone's first buffer, step by step, in ms.
    /// Each is nil when that step did not run (a failed permission has no engine time).
    var pressToTaskMs: Int? = nil
    var quietMs: Int? = nil
    var permissionMs: Int? = nil
    var refreshMicsMs: Int? = nil
    /// True when the press read the microphone list (a selected microphone its cached id could not vouch for).
    var micListRead: Bool? = nil
    /// True when a warmed engine (DictationSpare) opened the microphone, false when a fresh one did.
    var warmEngine: Bool? = nil
    var engineStartMs: Int? = nil
    var pressToFirstBufferMs: Int? = nil
    var pressToSoundMs: Int? = nil
    /// A failed dictation's DictationFailReason code: which step failed, never what was said.
    var failReason: String? = nil
    /// 0.5.328 smooth start (DictationStallMeter): the longest the main thread went without its 16 ms heartbeat from
    /// the press until three seconds after LISTENING (or the microphone closed, if sooner). 16 to 17 is smooth.
    var mainThreadStallMs: Int? = nil
    /// The mute's build (tap, aggregate device, IO proc) and its start (AudioDeviceStart), on the output queue.
    var quietBuildMs: Int? = nil
    var quietStartMs: Int? = nil
    /// The focused window's frame for the pill's placement (Accessibility, off the main thread since 0.5.328).
    var placementMs: Int? = nil
    /// How long the start sound took to start playing, on the output queue.
    var soundMs: Int? = nil
    /// An edit watch (Learn from my edits) was reading the last dictation's field when this one was pressed.
    var editWatchAtPress: Bool? = nil
    /// Typing or copying the text into the other app (Accessibility, the clipboard, ⌘V), on the main actor.
    var deliverMs: Int? = nil
    /// 0.5.330 press events (DictationPressEvent): a press that did not become a dictation, or a release COS had to
    /// reconcile. The phase it met, how long after the press (canceled_starting), whether the first buffer had arrived,
    /// the app version, and the hold key's state: what COS believed (held, the tracker) and what the keyboard said.
    var phase: String? = nil
    var msSincePress: Int? = nil
    var firstBufferArrived: Bool? = nil
    var appVersion: String? = nil
    var held: Bool? = nil
    var holdTrackerDown: Bool? = nil
    var holdHardwareDown: Bool? = nil
    /// release_reconciled: what noticed the missed release, the keyboard watch ("poll") or a key typed long after the
    /// press while the keyboard said the hold key was up ("key"). fnUsageType: macOS's own setting for the 🌐 key
    /// (com.apple.HIToolbox AppleFnUsageType, -1 when absent), when Fn is a dictation key.
    var reconcileSource: String? = nil
    var fnUsageType: Int? = nil
    /// 0.5.331 paste first, polish in place (DictationPolishSwap): the release to the first text in the app, what became
    /// of Claude's version (swapped, skipped:<reason>, off, identical, notPolished), how long from its answer to the swap
    /// landing or being skipped, and the route the swap took (accessibility or paste).
    var releaseToFirstTextMs: Int? = nil
    var swapOutcome: String? = nil
    var swapMs: Int? = nil
    var swapRoute: String? = nil
    /// 0.5.332: why a paste-first dictation was polished first instead (DictationPolishSwap.Unmeasurable: canvasEditor,
    /// unreadableField), beside swapOutcome=unmeasurable.
    var swapWhy: String? = nil
    static let finalWindowMilliseconds = 250
    /// The release-side numbers from the captured PCM and the byte count at the release.
    static func measure(pcm: Data, releaseBytes: Int, tailMs: Int, releaseToClosedMs: Int, at: Date) -> DictationTiming {
        let release = min(max(0, releaseBytes), pcm.count)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return DictationTiming(at: f.string(from: at), releaseToClosedMs: releaseToClosedMs, tailMs: tailMs,
                               capturedSeconds: (Double(pcm.count) / 32_000 * 100).rounded() / 100,
                               finalDBFS: DictationReleaseTail.dBFS(pcm, from: release - DictationReleaseTail.bytes(milliseconds: finalWindowMilliseconds), to: release),
                               tailDBFS: DictationReleaseTail.dBFS(pcm, from: release, to: pcm.count),
                               engine: nil, transcribeMs: nil, polishMs: nil, outcome: "pending")
    }
}

/// The timing file: append one line, keep it bounded. Past `maximumBytes` the file moves to `.1` (replacing the old one)
/// and a new one starts, so at most two files of 256 KB each exist. Private (0600). A failure to write is ignored.
enum DictationTimingLog {
    static let fileName = "dictation-timing.jsonl"
    static let maximumBytes = 256 * 1024
    static func line(_ timing: DictationTiming) -> Data? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(timing) else { return nil }
        data.append(0x0A)
        return data
    }
    static func append(_ timing: DictationTiming, to url: URL, fileManager: FileManager = .default) {
        guard let line = line(timing) else { return }
        appendBounded(line, to: url, maximumBytes: maximumBytes, fileManager: fileManager)
    }
    /// One line onto a bounded private file (0.5.338: the timing file and the learn canary share it).
    static func appendBounded(_ line: Data, to url: URL, maximumBytes: Int, fileManager: FileManager = .default) {
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size + line.count > maximumBytes, size > 0 {
            let rotated = url.appendingPathExtension("1")
            try? fileManager.removeItem(at: rotated)
            try? fileManager.moveItem(at: url, to: rotated)
        }
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }
}

/// 0.5.338: one line per Learn from my edits watch, so the per-app canary survives the unified log (which keeps COS
/// Control's notices about five hours). Counts, verdicts and the bundle id only: never text, never a word pair.
struct DictationLearnCanary: Codable, Equatable, Sendable {
    var at: String
    var bundle: String
    /// learn, probe
    var eligibility: String
    /// The first read held the dictation (exactly, or found again).
    var readable: Bool
    var reads: Int
    /// How the watch ended: cap, reads, focusLeft, cleared, emptied, lost, unreadable, secure, appGone, new.
    var stop: String
    var rebinds: Int
    var reanchors: Int
    /// Reads whose edit sat inside the dictation.
    var inside: Int
    var candidates: Int
    var learned: Int
    /// Why focus left, when it did: app, none, pid, role, identifier, window, frame, churn.
    var focusWhy: String?
}

/// `learn-canary.jsonl` next to the timing file, bounded the same way (one rotation, private).
enum DictationLearnCanaryLog {
    static let fileName = "learn-canary.jsonl"
    static let maximumBytes = 128 * 1024
    static func line(_ canary: DictationLearnCanary) -> Data? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(canary) else { return nil }
        data.append(0x0A)
        return data
    }
    static func append(_ canary: DictationLearnCanary, to url: URL, fileManager: FileManager = .default) {
        guard let line = line(canary) else { return }
        DictationTimingLog.appendBounded(line, to: url, maximumBytes: maximumBytes, fileManager: fileManager)
    }
}

// MARK: - Truthful start (0.5.327)
//
// Miles, 2026-10-19: "when I click the dictation, the sound immediately happens, which makes me think it's starting to
// record at that time. But if I look at the pet, it doesn't really start listening until like a second or so in." The
// start sound and LISTENING came on the press; the microphone's first buffer came later, after the mute was built, the
// microphone list read and a new engine opened (measured on his Mac: 0.3 to 0.9 s for the engine alone, about 3 s on a
// cold start). Now the pill says STARTING until the first buffer arrives, and only then do LISTENING and the start sound
// come, so both are true. The press no longer reads the microphone list or builds the mute before the microphone opens.

enum DictationStart {
    /// After the engine starts, how long COS waits for the microphone's first buffer before it says none came.
    static let firstBufferTimeoutMs = 3_000
    /// How often STARTING looks for the first buffer. The buffer's own time is exact; this is only the pill's lag.
    static let pollMs = 5
    enum Device: Equatable, Sendable { case systemDefault, device(AudioDeviceID), missing }
    /// What STARTING ends in: the first audio (its systemUptime), the microphone failing or sending nothing in time, or a
    /// newer press, cancel or release having replaced this dictation (which closed the microphone itself).
    enum FirstAudio: Equatable, Sendable { case arrived(TimeInterval), failed, timedOut, superseded }
    /// Which microphone to open. No selection: the system default, without reading the device list. A selection: its
    /// cached id while the device behind that id still reports the UID (one property read); only otherwise is the list
    /// read, once.
    static func resolve(selectedUID: String, cached: [String: AudioDeviceID], uidOf: (AudioDeviceID) -> String?,
                        enumerate: () -> [String: AudioDeviceID]) -> (device: Device, listRead: Bool) {
        guard !selectedUID.isEmpty else { return (.systemDefault, false) }
        if let id = cached[selectedUID], uidOf(id) == selectedUID { return (.device(id), false) }
        if let id = enumerate()[selectedUID] { return (.device(id), true) }
        return (.missing, true)
    }
}

/// The press's timeline, kept until the dictation's timing line takes it (or a start failure writes its own line).
struct DictationStartMarks: Equatable, Sendable {
    /// systemUptime of the press.
    let pressed: TimeInterval
    var pressToTaskMs: Int?
    var quietMs: Int?
    var permissionMs: Int?
    var refreshMicsMs: Int?
    var micListRead: Bool?
    var warmEngine: Bool?
    var engineStartMs: Int?
    var pressToFirstBufferMs: Int?
    var pressToSoundMs: Int?
    var mainThreadStallMs: Int?
    var quietBuildMs: Int?
    var quietStartMs: Int?
    var placementMs: Int?
    var soundMs: Int?
    var editWatchAtPress: Bool?
    init(pressed: TimeInterval) { self.pressed = pressed }
    /// Whole milliseconds from one uptime to another, never negative.
    static func ms(_ from: TimeInterval, _ to: TimeInterval) -> Int { max(0, Int(((to - from) * 1000).rounded())) }
    func since(_ now: TimeInterval) -> Int { Self.ms(pressed, now) }
}

extension DictationTiming {
    mutating func include(_ start: DictationStartMarks?) {
        guard let start else { return }
        pressToTaskMs = start.pressToTaskMs; quietMs = start.quietMs; permissionMs = start.permissionMs
        refreshMicsMs = start.refreshMicsMs; micListRead = start.micListRead; warmEngine = start.warmEngine
        engineStartMs = start.engineStartMs; pressToFirstBufferMs = start.pressToFirstBufferMs; pressToSoundMs = start.pressToSoundMs
        mainThreadStallMs = start.mainThreadStallMs; quietBuildMs = start.quietBuildMs; quietStartMs = start.quietStartMs
        placementMs = start.placementMs; soundMs = start.soundMs; editWatchAtPress = start.editWatchAtPress
    }
    /// A dictation that failed before the microphone captured anything: the start's numbers and nothing captured.
    static func startFailure(_ start: DictationStartMarks, at: Date) -> DictationTiming {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var timing = DictationTiming(at: f.string(from: at), releaseToClosedMs: 0, tailMs: 0, capturedSeconds: 0,
                                     finalDBFS: nil, tailDBFS: nil, engine: nil, transcribeMs: nil, polishMs: nil, outcome: "pending")
        timing.include(start)
        return timing
    }
}

/// Which step a failed dictation failed at. A code, never words: it goes on the timing line (0.5.327: a 10.7 s
/// dictation at 9:19 on 2026-10-19 failed with no engine and no transcription time, and nothing said why).
enum DictationFailReason: String, Sendable, CaseIterable {
    case microphoneDenied = "mic_denied"
    case microphoneMissing = "mic_missing"
    case engineStart = "engine_start"
    case noFirstBuffer = "no_first_buffer"
    case microphoneFailed = "mic_failed"
    case tooShort = "too_short"
    case notConnected = "not_connected"
    case helperTimeout = "helper_timeout"
    case helperFailed = "helper_failed"
    case refused = "refused"
    case noSpeech = "no_speech"
    case engineSwitch = "engine_switch"
    /// The code with a detail (the server's refusal reason, the helper error's kind) when the detail is itself a code:
    /// lowercase letters, digits and _ only, at most 40 characters. Anything else is dropped, so no words can ride along.
    func code(_ detail: String? = nil) -> String {
        guard let detail, !detail.isEmpty, detail.count <= 40,
              detail.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }) else { return rawValue }
        return rawValue + ":" + detail
    }
}

/// 0.5.327: an engine opened ahead of the press (AVAudioEngine and its input node built, never started), so the press
/// only installs the tap and starts it. Measured on Miles's Mac: building the engine and its input node took 88 to
/// 693 ms of the press-to-first-buffer time. The microphone is never running while a spare waits (the canary reads
/// the process's own input-running flag). A spare is used only while nothing it was built against has changed.
enum DictationSpare {
    /// A spare older than this is not trusted; the press opens a fresh engine. Half an hour: the checks below are the
    /// safety, the age only bounds what they cannot see. The first spare (built at launch) also takes the first-in-process
    /// cost of loading the audio components (about 0.7 to 3 s measured), whether or not it is ever used.
    static let maximumAgeSeconds: TimeInterval = 1_800
    /// What the spare was built against: the device its input node opened, the selection, and that device's nominal rate.
    struct Warmed: Equatable, Sendable {
        let device: AudioDeviceID
        let selectedUID: String
        let sampleRate: Double
        let at: TimeInterval
    }
    enum Verdict: Equatable, Sendable { case use, discard(String) }
    /// At the press: `device` is the device this dictation would open now, `sampleRate` its nominal rate now. A changed
    /// device, selection or rate means the spare's input format may be stale (a tap in a stale format is an exception
    /// AVAudioEngine raises, not an error COS can catch), so it is discarded and a fresh engine opens.
    static func check(_ warmed: Warmed, selectedUID: String, device: AudioDeviceID?, sampleRate: Double?, bluetooth: Bool, now: TimeInterval) -> Verdict {
        if bluetooth { return .discard("bluetooth") }
        if warmed.selectedUID != selectedUID { return .discard("selection") }
        guard let device, device == warmed.device else { return .discard("device") }
        guard let sampleRate, sampleRate > 0, sampleRate == warmed.sampleRate else { return .discard("rate") }
        guard now >= warmed.at, now - warmed.at <= maximumAgeSeconds else { return .discard("age") }
        return .use
    }
    /// Only with the microphone already allowed (building an input node is not a moment to ask) and never for a
    /// Bluetooth input (opening a headset's input can switch it to its call profile; only a dictation may do that).
    static func mayWarm(enabled: Bool, authorized: Bool, bluetooth: Bool) -> Bool { enabled && authorized && !bluetooth }
}

// MARK: - Smooth start (0.5.328)
//
// Miles, 2026-10-19 on 0.5.327: "the animation stops as the new listening pill comes in." His timing lines: quietMs
// 1,103 to 2,173 ms, the start sound 44 to 258 ms after the first buffer, and once 1,052 ms before the press's own task
// ran. All of it ran on the main actor, which also draws the pet (a TimelineView) and the pill, so both froze. CoreAudio
// and AVAudioEngine work now runs on two serial queues; the main actor only publishes state.

/// Where dictation's audio work runs, never the main thread. Each is serial, so work runs in the order it was asked.
enum DictationAudioQueues {
    /// Microphone engines: building a spare, and starting one. Stopping stays on the caller (DictationMicrophoneCapture
    /// serialises its own engine calls), so the 0.5.326 release tail closes exactly when it did.
    /// User-interactive: the press waits on it, as it used to wait on the main thread.
    static let input = DispatchQueue(label: "com.gotcos.control.dictation.input", qos: .userInteractive)
    /// Other apps' quiet (mute or lower volume) and COS's own start and stop sounds. The start sound is queued before the
    /// mute, so COS's own audio object exists when the mute excludes it, and every end follows its begin.
    static let output = DispatchQueue(label: "com.gotcos.control.dictation.output", qos: .userInitiated)
    /// `work` on `queue`; the caller (the main actor) is free until it returns.
    static func perform<T: Sendable>(on queue: DispatchQueue, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<T, Error>) in
            queue.async { done.resume(with: Result { try work() }) }
        }
    }
}

/// The mute's two costs, measured where they run.
struct DictationQuietTimes: Equatable, Sendable {
    var buildMs: Int?
    var startMs: Int?
}

/// The main thread's heartbeat: a 16 ms timer on the main run loop calls `tick`. The longest gap between beats (or from
/// the press to the first beat) is how long the pet and the pill could not move. Ticks after `end` are ignored.
final class DictationStallMeter: @unchecked Sendable {
    static let tickMilliseconds = 16
    /// After LISTENING, how long the heartbeat keeps measuring.
    static let afterListeningSeconds: TimeInterval = 3
    private let lock = NSLock()
    private var last: TimeInterval
    private var worst: TimeInterval = 0
    private var beats = 0
    private var endsAt: TimeInterval?
    init(start: TimeInterval) { last = start }
    /// One beat at `now`. False once `now` is past the end: the caller stops its timer.
    @discardableResult func tick(_ now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let endsAt, now > endsAt { return false }
        worst = max(worst, now - last); last = now; beats += 1
        return true
    }
    func end(at uptime: TimeInterval) { lock.lock(); endsAt = uptime; lock.unlock() }
    /// The longest gap in whole milliseconds, nil before the first beat.
    var maxGapMs: Int? {
        lock.lock(); defer { lock.unlock() }
        return beats > 0 ? Int((worst * 1000).rounded()) : nil
    }
}

// MARK: - AI polish started at the press (0.5.329, server 6.79.2)
//
// Polish was 1.8 to 4.1 s with Haiku, most of it the Claude CLI starting. The server can start that process when the
// key goes down; the finalize call then names it with the token. Measured on Miles's Mac: about 0.9 s off a polish whose
// process started 3 s or more before the text. Fire and forget: nothing waits on it at the press, and every refusal
// (an older server, a breaker, a cap) leaves the dictation exactly as it was.

enum DictationPolishPrewarm {
    /// Control's wait on the helper (its own request deadline is 2 s).
    static let helperTimeout: TimeInterval = 2.5
    /// At the polish, how long COS waits for a start still in flight before polishing without it.
    static let waitMilliseconds = 150
    static let pollMilliseconds = 10
    static let outcomes: Set<String> = ["used", "missed", "discarded"]
    static func isToken(_ value: String) -> Bool { value.range(of: "^[0-9a-f-]{36}$", options: .regularExpression) != nil }
    /// Start one only when AI polish is on, and not against a server that answered "unsupported" (until it changes).
    static func shouldStart(model: DictationPolishModel, unsupportedOn: String?, serverVersion: String?) -> Bool {
        if model == .off { return false }
        guard let unsupportedOn else { return true }
        return unsupportedOn != (serverVersion ?? "")
    }
    static func startRequest(model: DictationPolishModel) -> Data? {
        guard model != .off else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["model": model.rawValue], options: [.sortedKeys])
    }
    static func discardRequest(token: String) -> Data? {
        guard isToken(token) else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["discard": token], options: [.sortedKeys])
    }
    /// What a start came back with.
    enum Result: Equatable, Sendable {
        case token(String, ms: Int)
        case refused(String, ms: Int?)
        /// An older server (404): stop asking until the server version changes.
        case unsupported
        var token: String? { if case .token(let t, _) = self { t } else { nil } }
        var ms: Int? {
            switch self {
            case .token(_, let ms): ms
            case .refused(_, let ms): ms
            case .unsupported: nil
            }
        }
    }
    /// The helper's answer (nil: it threw or did not answer).
    static func read(ok: Bool?, token: String?, reason: String?, elapsedMs: Int?) -> Result {
        if ok == true, let token, isToken(token) { return .token(token, ms: elapsedMs ?? 0) }
        if reason == "unsupported" { return .unsupported }
        let why = reason.flatMap { $0.range(of: "^[a-z0-9_]{1,40}$", options: [.regularExpression]) != nil ? $0 : nil } ?? (ok == nil ? "helper" : "refused")
        return .refused(why, ms: elapsedMs)
    }
    /// The timing line's polishPrewarm: none when no token went with the polish; else the server's word, or missed when
    /// it did not say (it then ran cold, as before).
    static func outcome(sentToken: Bool, answer: String?) -> String {
        guard sentToken else { return "none" }
        return answer.flatMap { outcomes.contains($0) ? $0 : nil } ?? "missed"
    }
}

/// Where a press's start lands, written off the main actor and read by the polish without blocking.
final class DictationPrewarmBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DictationPolishPrewarm.Result?
    func set(_ result: DictationPolishPrewarm.Result) { lock.lock(); value = result; lock.unlock() }
    var result: DictationPolishPrewarm.Result? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Serial microphone callback owns conversion; this lock protects its bounded result from Stop.
final class DictationPCMBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var failure: String?
    private var level: Double = 0
    /// 0.5.327: systemUptime of the first audio appended: the moment the microphone truly started listening.
    private var firstAudio: TimeInterval?
    func append(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil else { return }
        if firstAudio == nil, !bytes.isEmpty { firstAudio = ProcessInfo.processInfo.systemUptime }
        // A callback may straddle the deadline. Keep the completed clip, rather than
        // turning a valid two-minute recording into an unrecoverable overflow error.
        let remaining = MacDictationPolicy.maximumPCMBytes - data.count
        data.append(bytes.prefix(max(0, min(remaining, bytes.count / 2 * 2))))
        // RMS, not peak (0.5.309): the meter maps it to dBFS, so quiet speech still moves the bars.
        level = bytes.withUnsafeBytes { raw in
            let samples = raw.count / 2
            guard samples > 0 else { return 0 }
            var sum = 0.0
            for offset in stride(from: 0, to: samples * 2, by: 2) {
                let x = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32768
                sum += x * x
            }
            return (sum / Double(samples)).squareRoot()
        }
    }
    func fail(_ message: String) { lock.lock(); failure = message; lock.unlock() }
    func result() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw NSError(domain: "COSDictation", code: 1, userInfo: [NSLocalizedDescriptionKey: failure]) }
        return data
    }
    func snapshot(maximumBytes: Int) -> Data { lock.lock(); defer { lock.unlock() }; return Data(data.suffix(max(0, maximumBytes / 2 * 2))) }
    /// 0.5.326: how much is captured so far (the release mark the timing line splits on).
    func byteCount() -> Int { lock.lock(); defer { lock.unlock() }; return data.count }
    func failureMessage() -> String? { lock.lock(); defer { lock.unlock() }; return failure }
    func firstAudioUptime() -> TimeInterval? { lock.lock(); defer { lock.unlock() }; return firstAudio }
    func currentLevel() -> Double { lock.lock(); defer { lock.unlock() }; return level }
}

/// 2026-10-15 (Miles): any key can start dictation, so Fn can move from Wispr Flow to COS. Three shapes:
/// a modifier plus a key and a bare function key register as Carbon hot keys; one modifier key pressed by
/// itself (Fn/🌐, Right ⌘…) is read from key events, which needs the Accessibility access insertion already uses.
enum DictationTrigger: Equatable, Sendable {
    case keys(keyCode: UInt32, modifiers: UInt32)
    case modifier(keyCode: UInt16)

    static let command: UInt32 = 0x100, shift: UInt32 = 0x200, option: UInt32 = 0x800, control: UInt32 = 0x1000
    static let functionKeys: [UInt32: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
    /// keyCode -> name, the key's own device bit, and its family's device-independent bit (NSEvent raw flags).
    static let modifierKeys: [UInt16: (name: String, device: UInt64, family: UInt64)] = [
        63: ("Fn 🌐", 0x800000, 0x800000),
        55: ("Left ⌘", 0x08, 0x100000), 54: ("Right ⌘", 0x10, 0x100000),
        58: ("Left ⌥", 0x20, 0x80000), 61: ("Right ⌥", 0x40, 0x80000),
        59: ("Left ⌃", 0x01, 0x40000), 62: ("Right ⌃", 0x2000, 0x40000),
        56: ("Left ⇧", 0x02, 0x20000), 60: ("Right ⇧", 0x04, 0x20000),
    ]
    /// Every modifier family a lone press must not share the moment with.
    static let modifierFamilies: UInt64 = 0x800000 | 0x100000 | 0x80000 | 0x40000 | 0x20000
    /// Left/right device bits: Left ⌘ held makes a Right ⌘ press a chord, though both share the ⌘ family bit.
    static let modifierDevices: UInt64 = 0x01 | 0x02 | 0x04 | 0x08 | 0x10 | 0x20 | 0x40 | 0x2000
    static func alone(_ keyCode: UInt16, flags: UInt64) -> Bool {
        guard let key = modifierKeys[keyCode] else { return false }
        return flags & modifierFamilies & ~key.family == 0 && flags & modifierDevices & ~key.device == 0
    }

    /// A key with no Command, Control or Option would capture plain typing; function keys are the exception.
    static func keys(_ keyCode: UInt32, modifiers raw: UInt32) -> DictationTrigger? {
        let modifiers = raw & (command | shift | option | control)
        guard modifiers & (command | control | option) != 0 || functionKeys[keyCode] != nil else { return nil }
        return .keys(keyCode: keyCode, modifiers: modifiers)
    }
    static func modifier(_ keyCode: UInt16) -> DictationTrigger? {
        modifierKeys[keyCode] == nil ? nil : .modifier(keyCode: keyCode)
    }
    var usesKeyMonitor: Bool { if case .modifier = self { return true }; return false }
    var isFn: Bool { self == .modifier(keyCode: 63) }

    /// UserDefaults shape: kind, key, modifiers. A missing kind is a pre-0.5.305 combo.
    var stored: (kind: String, key: Int, modifiers: Int) {
        switch self {
        case .keys(let key, let modifiers): ("keys", Int(key), Int(modifiers))
        case .modifier(let key): ("modifier", Int(key), 0)
        }
    }
    static func load(kind: String?, key: Int, modifiers: Int) -> DictationTrigger? {
        guard key >= 0, modifiers >= 0 else { return nil }
        if kind == "modifier" { return key <= Int(UInt16.max) ? modifier(UInt16(key)) : nil }
        guard key <= Int(UInt32.max), modifiers <= Int(UInt32.max) else { return nil }
        return keys(UInt32(key), modifiers: UInt32(modifiers))
    }
}

/// One lone-modifier trigger fed raw key events. A press counts only when no other modifier is held and
/// no other key goes down before release, so Fn+arrow or ⌘C never start dictation. A click is a chord only right after
/// the press (⌥-click, ⌘-click): once the person is talking, clicking or dragging to place the cursor or move a window
/// must not stop listening (Miles 2026-10-15, as in Wispr Flow).
struct LoneModifierTracker: Sendable {
    enum Output: Equatable, Sendable { case pressed, released, chord }
    /// A modifier-click lands within this of the modifier going down; a later click is the person working while they talk.
    static let clickChordWindow: TimeInterval = 0.4
    let keyCode: UInt16
    private let device: UInt64, family: UInt64
    private(set) var down = false
    private var clean = false
    /// 0.5.330: read by the missed-release rule (DictationHoldWatch.keyDownIsMissedRelease).
    private(set) var pressedAt: TimeInterval = 0
    init?(keyCode: UInt16) {
        guard let key = DictationTrigger.modifierKeys[keyCode] else { return nil }
        self.keyCode = keyCode; device = key.device; family = key.family
    }
    /// `at` is the event's timestamp (seconds since boot, NSEvent.timestamp); only clicks compare against it.
    mutating func flagsChanged(keyCode changed: UInt16, flags: UInt64, at time: TimeInterval = 0) -> Output? {
        guard changed == keyCode else {
            // Another modifier joined while ours is held: a chord, never dictation.
            guard down, clean else { return nil }
            clean = false; return .chord
        }
        let nowDown = flags & device != 0
        if nowDown, !down {
            down = true; pressedAt = time
            clean = DictationTrigger.alone(keyCode, flags: flags)
            return clean ? .pressed : nil
        }
        if !nowDown, down {
            down = false
            defer { clean = false }
            return clean ? .released : nil
        }
        return nil
    }
    mutating func keyDown() -> Output? {
        guard down, clean else { return nil }
        clean = false; return .chord
    }
    /// A mouse button went down. A chord only inside clickChordWindow of the press; later it is ignored, so the
    /// release still finishes the dictation where the person clicked.
    mutating func pointerDown(at time: TimeInterval) -> Output? {
        guard down, clean, time - pressedAt < Self.clickChordWindow else { return nil }
        clean = false; return .chord
    }
    /// The app lost key events (sleep, monitor removed): forget a press rather than stay latched.
    mutating func reset() { down = false; clean = false }
}

// MARK: - Wispr-style dictation (0.5.309)

/// Where finished text goes (Miles, 2026-10-15): it is ALWAYS copied, then dropped into whatever editable text element
/// has focus at the moment transcription finishes, so the person may click elsewhere while it transcribes. Insertion is
/// refused, and the text stays on the clipboard with the pet's card, when any of these hold. Never presses Return.
enum DictationInsertPolicy {
    /// Why nothing was typed. The raw value is what Recent dictations stores.
    enum Refusal: String, Equatable, Sendable, CaseIterable {
        case notTrusted, secureInput, secureField, ownOverlay, noTextBox, keysHeld, clipboardChanged, clipboardFailed, interrupted, interruptedClipboardKept
        /// The card's heading (mock 04).
        var title: String {
            switch self {
            case .notTrusted: "COPIED · ALLOW ACCESSIBILITY"
            case .secureInput: "SECURE INPUT ON · COPIED"
            case .secureField: "PASSWORD FIELD · COPIED"
            case .ownOverlay, .noTextBox: "NO TEXT BOX · COPIED"
            case .keysHeld: "KEYS HELD · COPIED"
            case .clipboardChanged: "CLIPBOARD CHANGED · NOT PASTED"
            case .clipboardFailed: "CLIPBOARD UNAVAILABLE"
            case .interrupted: "INTERRUPTED · COPIED"
            case .interruptedClipboardKept: "INTERRUPTED · NOT COPIED"
            }
        }
        var note: String {
            switch self {
            case .notTrusted: "Allow COS Control in Accessibility to drop text in for you. Already on? Reset and add again. For now, click where you want it and press ⌘V."
            case .secureInput: "Another app is holding secure keyboard input, so COS will not type. Click where you want it and press ⌘V."
            case .secureField: "COS never types into a password field. Press ⌘V yourself if you mean to."
            case .ownOverlay, .noTextBox: "Click where you want it, then press ⌘V."
            case .keysHeld: "A modifier key was still held, so COS did not paste. Click where you want it and press ⌘V."
            case .clipboardChanged: "Something else changed the clipboard before COS could paste. Copy it again here."
            case .clipboardFailed: "COS could not put the text on the clipboard. Copy it here."
            case .interrupted: "Dictation was interrupted, so COS copied what you said instead of typing it. Click where you want it and press ⌘V."
            case .interruptedClipboardKept: "Dictation was interrupted, and you copied something while COS transcribed it, so your clipboard was left alone. Copy it here."
            }
        }
        /// "copied, <this>" in Recent dictations.
        var historyLabel: String {
            switch self {
            case .notTrusted: "Accessibility off"
            case .secureInput: "secure input on"
            case .secureField: "password field"
            case .ownOverlay, .noTextBox: "no text box"
            case .keysHeld: "keys held"
            case .clipboardChanged: "clipboard changed"
            case .clipboardFailed: "clipboard unavailable"
            case .interrupted: "interrupted"
            case .interruptedClipboardKept: "interrupted, clipboard kept"
            }
        }
    }
    static let secureSubrole = "AXSecureTextField"
    /// nil means deliver. A text role alone is NOT enough (0.5.310 QA: iTerm2's read-only AXTextArea took a "successful"
    /// set and showed nothing): the focused element must take text (`textSettable`: AXSelectedText or AXValue is
    /// settable) or sit in a web editor (`editableAncestor`). A known terminal or Electron/Chromium app with no such
    /// element still gets ⌘V (`pasteApp`), labelled as unconfirmed.
    static func refusal(trusted: Bool, secureInput: Bool, subrole: String?, focused: Bool, textSettable: Bool,
                        editableAncestor: Bool, pasteApp: Bool, ownOverlay: Bool) -> Refusal? {
        guard trusted else { return .notTrusted }
        if subrole == secureSubrole { return .secureField }
        if secureInput { return .secureInput }
        if ownOverlay { return .ownOverlay }
        if focused, textSettable || editableAncestor { return nil }
        return pasteApp ? nil : .noTextBox
    }
    /// 0.5.332: a web editor that draws its own text (Google Slides, Docs and Sheets in a Chromium browser): nothing
    /// focused takes text and nothing sits in an editable ancestor. `refusal` gives it ⌘V (labelled unconfirmed, never
    /// NO TEXT BOX), and COS can never measure where it landed.
    static func canvasEditor(chromium: Bool, focused: Bool, textSettable: Bool, editableAncestor: Bool) -> Bool {
        chromium && !(focused && (textSettable || editableAncestor))
    }
}

/// Apps that need ⌘V rather than Accessibility. ClaudeSession.terminalHostBundleIds (Models.swift) is the subset whose
/// session jump is implemented; it must stay inside `terminals` (pinned by Tests/dictation-wispr-pins.py).
enum KnownApps {
    static let terminals: Set<String> = [
        "com.googlecode.iterm2", "com.apple.Terminal", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "com.github.wez.wezterm",
    ]
    static func isTerminal(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return terminals.contains(bundleID) || bundleID.hasPrefix("dev.warp.")
    }
    /// Electron and Chromium Embedded apps (Claude, Slack, Spotify), as opposed to a Chromium browser: their editors
    /// take ⌘V but have not shown COS a readable value yet, so Learn from my edits only measures them (0.5.318).
    static func isElectron(frameworks: [String]) -> Bool {
        frameworks.contains { $0 == "Electron Framework.framework" || $0 == "Chromium Embedded Framework.framework" }
    }
    /// Electron and Chromium apps expose their text fields to Accessibility only after AXManualAccessibility is set.
    /// 0.5.332 (Miles 2026-10-20 09:57, Google Slides in Comet): a Chromium browser is known by its STRUCTURE, not its
    /// name. Comet's engine is "Comet Framework.framework", which no name list had. Any `* Framework.framework` whose
    /// `Versions/Current/Helpers` holds a `* Helper (Renderer).app` is Chromium; the names stay as well. `helpers` lists
    /// that Helpers folder for one framework (empty when it has none); it is asked only for `* Framework.framework`.
    static func isChromiumFamily(frameworks: [String], helpers: (String) -> [String] = { _ in [] }) -> Bool {
        frameworks.contains { name in
            name == "Electron Framework.framework" || name == "Chromium Embedded Framework.framework"
                || (name.hasSuffix(" Framework.framework")
                    && (["Chrome", "Chromium", "Edge", "Brave", "Vivaldi", "Opera", "Arc"].contains { name.contains($0) } || hasRendererHelper(helpers(name))))
        }
    }
    /// Where a Chromium framework keeps its helper apps, relative to the framework.
    static let helpersPath = "Versions/Current/Helpers"
    /// Chromium's renderer process ships as "<Product> Helper (Renderer).app".
    static func hasRendererHelper(_ helpers: [String]) -> Bool { helpers.contains { $0.hasSuffix(" Helper (Renderer).app") } }
}

/// What COS can measure about the focused field without ever reading its text: AXNumberOfCharacters and
/// AXSelectedTextRange. Nil fields could not be read.
struct DictationFieldSnapshot: Equatable, Sendable {
    var characters: Int?
    var location: Int?
    var length: Int?
    var readable: Bool { characters != nil || location != nil }
    /// "n=120 r=40+0" for the delivery log; counts only, never text.
    var logDescription: String {
        "n=" + (characters.map(String.init) ?? "?") + " r=" + (location.map(String.init) ?? "?") + "+" + (length.map(String.init) ?? "?")
    }
}

enum DictationRoute: String, Sendable { case accessibility, paste, ownWindow }

/// How a dictation ended. Only `inserted` earns the ✓: a measured change in the field proved it.
enum DictationDeliveryOutcome: Equatable, Sendable {
    case inserted(app: String, viaPaste: Bool)
    case unconfirmed(app: String, viaPaste: Bool)
    case refused(DictationInsertPolicy.Refusal)
    var delivery: DictationRecord.Delivery {
        switch self {
        case .inserted(let app, _): .inserted(app: app)
        case .unconfirmed(let app, let viaPaste): .unconfirmed(app: app, viaPaste: viaPaste)
        case .refused(let refusal): .copied(refusal)
        }
    }
    /// The pill's flash, or nil when the card shows instead.
    var flash: DictationPill? {
        switch self {
        case .inserted(let app, _): .flash(label: "✓ INSERTED · " + app.uppercased(), confirmed: true)
        case .unconfirmed(_, true): .flash(label: "PASTED · ⌘V SENT", confirmed: false)
        case .unconfirmed(_, false): .flash(label: "SENT · NOT CONFIRMED", confirmed: false)
        case .refused: nil
        }
    }
}

enum DictationDecision: Equatable, Sendable { case wait, paste, done(DictationDeliveryOutcome) }

/// The delivery decision (0.5.310, after Miles's 20:07 field bug: iTerm2 flashed "✓ INSERTED" and nothing landed).
/// Pure, so every branch is tested and mutated. The app measures the field, calls `decide`, and acts.
enum DictationDelivery {
    /// When the app re-measures after setting AXSelectedText, in milliseconds after the set.
    static let pollMilliseconds = [0, 50, 150, 300]
    enum Verdict: Equatable, Sendable { case landed, changed, unchanged, unreadable }

    /// `count` is the inserted text's UTF-16 length, the unit AXNumberOfCharacters and AXSelectedTextRange count in.
    static func verdict(baseline: DictationFieldSnapshot, after: DictationFieldSnapshot, count: Int) -> Verdict {
        guard baseline.readable, after.readable else { return .unreadable }
        if after == baseline { return .unchanged }
        if let n0 = baseline.characters, let n = after.characters, let length0 = baseline.length, n == n0 - length0 + count { return .landed }
        if let location0 = baseline.location, let location = after.location, after.length == 0, location == location0 + count { return .landed }
        return .changed
    }

    /// COS's own windows take insertText directly; terminals and unmeasurable fields take ⌘V; everything else AX.
    static func route(isOwnApp: Bool, terminal: Bool, baselineReadable: Bool) -> DictationRoute {
        if isOwnApp { return .ownWindow }
        if terminal || !baselineReadable { return .paste }
        return .accessibility
    }

    /// One step. `pasted` is whether ⌘V has been sent; `afterPaste` is then the field measured after it.
    /// Any change after the AX set counts as landed and is NEVER followed by a paste (no double insert).
    static func decide(route: DictationRoute, baseline: DictationFieldSnapshot, setterSucceeded: Bool,
                       afterSetter: DictationFieldSnapshot, finalPoll: Bool, pasted: Bool,
                       afterPaste: DictationFieldSnapshot, count: Int, app: String) -> DictationDecision {
        if pasted {
            switch verdict(baseline: baseline, after: afterPaste, count: count) {
            case .landed, .changed: return .done(.inserted(app: app, viaPaste: true))
            // Once ⌘V is posted COS never says "press ⌘V": a slow app may still take it, and a second paste would
            // double the text. Unmeasured or unmoved, it is PASTED · ⌘V SENT, without the ✓.
            case .unchanged, .unreadable: return .done(.unconfirmed(app: app, viaPaste: true))
            }
        }
        if route == .paste { return .paste }
        guard baseline.readable else { return route == .ownWindow ? .done(.unconfirmed(app: app, viaPaste: false)) : .paste }
        switch verdict(baseline: baseline, after: afterSetter, count: count) {
        case .landed, .changed:
            return .done(.inserted(app: app, viaPaste: false))
        case .unchanged:
            guard !setterSucceeded || finalPoll else { return .wait }
            return route == .ownWindow ? .done(.refused(.noTextBox)) : .paste
        case .unreadable:
            return finalPoll ? .done(.unconfirmed(app: app, viaPaste: false)) : .wait
        }
    }

    /// A terminal runs a line on Return, so dictated line breaks become spaces there. COS never presses Return.
    static func terminalText(_ text: String) -> String {
        var out = text
        for breakSequence in ["\r\n", "\r", "\n", "\u{2028}", "\u{2029}"] { out = out.replacingOccurrences(of: breakSequence, with: " ") }
        return out
    }

    /// The virtual key that types `character` with ⌘ held on the current layout (Dvorak, AZERTY…), from a translate
    /// function the app backs with UCKeyTranslate. Nil when no key does; the caller falls back to ANSI V (9).
    static func keyCode(for character: String, translate: (UInt16) -> String?) -> UInt16? {
        for code in UInt16(0)..<128 where translate(code)?.lowercased() == character { return code }
        return nil
    }

    /// Left and right ⌘ ⌥ ⌃ ⇧ key codes. ⌘V must not be posted while one is physically down, or it becomes another chord.
    /// 0.5.311: asked key by key, never from CGEventSource.flagsState. Its Fn bit (0x800000) stays set after function-key
    /// events (Miles's F17 shortcut, 2026-10-15), so every paste read as "keys held". Fn never changes what ⌘V does.
    static let modifierKeyCodes: [UInt16] = [55, 54, 58, 61, 59, 62, 56, 60]
    static func modifiersHeld(isDown: (UInt16) -> Bool) -> Bool { modifierKeyCodes.contains(where: isDown) }
    static let modifierWaitMilliseconds = 600
}

/// The listening bars' level, fast rise and slow fall, ranged to THIS microphone (0.5.312).
///
/// 0.5.309-0.5.311 mapped a fixed -50..-10 dBFS window. Miles's default input is an AT2020USB+ (a USB condenser with
/// no hardware gain; System Information shows it as the default input, 2 ch at 16 kHz), where loud speech measures
/// about -45 dBFS RMS: 0.125 of that window, 3 to 4.5 pt bars of 15, the "flat dots" of 2026-10-15 21:16. Speech now
/// reads against the mic's own noise floor and recent peak, like Wispr: the floor falls instantly and rises 2 dB/s,
/// starts no higher than -50 dBFS (so speaking from the first tick still lights the bars), and gates 6 dB above it; the
/// peak jumps up instantly, decays 1 dB/s, and stays at least 20 dB over the floor. Silence stays at the floor.
struct DictationLevelMeter: Sendable {
    /// Below this is digital silence.
    static let silenceDB = -90.0
    static let startFloorDB = -50.0
    static let gateDB = 6.0
    static let minimumRangeDB = 20.0
    /// Per 50 ms tick.
    static let floorRiseDB = 0.1, peakDecayDB = 0.05
    /// Share of the previous level kept on each falling tick.
    static let release = 0.82
    private(set) var level = 0.0
    private(set) var floorDB: Double?
    private(set) var peakDB = -90.0
    static func dBFS(rms: Double) -> Double { rms > 0 ? 20 * log10(rms) : -160 }
    mutating func update(rms: Double) -> Double {
        let db = max(Self.silenceDB, Self.dBFS(rms: rms))
        let floor = floorDB.map { db < $0 ? db : $0 + Self.floorRiseDB } ?? min(db, Self.startFloorDB)
        floorDB = floor
        let gate = floor + Self.gateDB
        peakDB = max(db, peakDB - Self.peakDecayDB, floor + Self.minimumRangeDB)
        let target = db <= gate ? 0 : min(1, (db - gate) / (peakDB - gate))
        level = target >= level ? target : level * Self.release + target * (1 - Self.release)
        return level
    }
}

/// The listening pill's eleven bars, center weighted: the newest level at the center, older ones rippling outward.
/// Heights in points at the medium pet size (the view scales them). Pure, so the whole path is tested end to end.
enum DictationBars {
    static let count = 11
    static let minimum = 3.0, maximum = 15.0
    static func heights(_ history: [Double]) -> [Double] {
        let center = Double(count - 1) / 2
        return (0..<count).map { index in
            let offset = abs(Double(index) - center)
            let level = history.isEmpty ? 0 : history[max(0, history.count - 1 - Int(offset.rounded()))]
            let weight = 0.45 + 0.55 * (1 - offset / (center + 1))
            return minimum + (maximum - minimum) * min(1, max(0, level)) * weight
        }
    }
}

/// One finished dictation. The text is private: it lives only in this record, the history file and the clipboard.
struct DictationRecord: Codable, Equatable, Identifiable, Sendable {
    /// Where it went, honestly: typed and measured, sent but unconfirmed, or only copied and why.
    enum Delivery: Equatable, Sendable {
        case inserted(app: String)
        case unconfirmed(app: String, viaPaste: Bool)
        case copied(DictationInsertPolicy.Refusal)
    }
    let id: UUID
    let text: String
    let createdAt: Date
    let delivery: Delivery
    /// 0.5.317: which local engine transcribed it (parakeet-ultra or whisper), and why Automatic used Whisper when it
    /// wanted Parakeet. nil in records from before 0.5.317, which were all Parakeet Ultra.
    let engine: String?
    let fallbackReason: String?
    /// 0.5.325 AI polish: what the engine heard, kept only when Claude's polish changed it, and which model polished
    /// it (haiku or sonnet). Both nil in older records and whenever polish was off, failed or changed nothing.
    let heard: String?
    let polishModel: String?

    init(id: UUID, text: String, createdAt: Date, delivery: Delivery, engine: String? = nil, fallbackReason: String? = nil,
         heard: String? = nil, polishModel: String? = nil) {
        self.id = id; self.text = text; self.createdAt = createdAt; self.delivery = delivery
        self.engine = engine; self.fallbackReason = fallbackReason
        self.heard = heard; self.polishModel = polishModel
    }

    var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }
    var firstLine: String {
        text.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }
    /// "inserted · Slack", "pasted (unconfirmed) · iTerm2", "copied, password field" (mock 05).
    var outcomeLabel: String {
        switch delivery {
        case .inserted(let app): "inserted · " + app
        case .unconfirmed(let app, true): "pasted (unconfirmed) · " + app
        case .unconfirmed(let app, false): "sent (unconfirmed) · " + app
        case .copied(let refusal): "copied, " + refusal.historyLabel
        }
    }
    /// "Polished · Haiku" when Claude's polish changed this dictation; nil otherwise (or for a model this build does not know).
    var polishLabel: String? {
        guard heard != nil, let name = polishModel.flatMap(DictationPolishModel.init(rawValue:))?.shortName else { return nil }
        return "Polished · " + name
    }
    func metaLine(time: String) -> String {
        "\(time) · \(wordCount) \(wordCount == 1 ? "word" : "words") · \(outcomeLabel)" + (polishLabel.map { " · " + $0 } ?? "")
    }

    // Stored as kind/app/reason. 0.5.309 files carry insertedApp/pasted instead and still load.
    private enum Keys: String, CodingKey { case id, text, createdAt, kind, app, reason, viaPaste, insertedApp, pasted, engine, fallbackReason, heard, polishModel }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
        fallbackReason = try c.decodeIfPresent(String.self, forKey: .fallbackReason)
        // 0.5.325: absent before AI polish. A value of the wrong type reads as none rather than dropping the file.
        heard = (try? c.decodeIfPresent(String.self, forKey: .heard)) ?? nil
        polishModel = (try? c.decodeIfPresent(String.self, forKey: .polishModel)) ?? nil
        if let kind = try c.decodeIfPresent(String.self, forKey: .kind) {
            let app = try c.decodeIfPresent(String.self, forKey: .app) ?? "the app"
            switch kind {
            case "inserted": delivery = .inserted(app: app)
            case "unconfirmed": delivery = .unconfirmed(app: app, viaPaste: try c.decodeIfPresent(Bool.self, forKey: .viaPaste) ?? true)
            default: delivery = .copied(DictationInsertPolicy.Refusal(rawValue: try c.decodeIfPresent(String.self, forKey: .reason) ?? "") ?? .noTextBox)
            }
        } else if let app = try c.decodeIfPresent(String.self, forKey: .insertedApp) {
            // 0.5.309 called an unverified set "inserted"; it cannot be trusted now, so it reads as unconfirmed.
            delivery = .unconfirmed(app: app, viaPaste: try c.decodeIfPresent(Bool.self, forKey: .pasted) ?? false)
        } else {
            delivery = .copied(.noTextBox)
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id); try c.encode(text, forKey: .text); try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(engine, forKey: .engine); try c.encodeIfPresent(fallbackReason, forKey: .fallbackReason)
        try c.encodeIfPresent(heard, forKey: .heard); try c.encodeIfPresent(polishModel, forKey: .polishModel)
        switch delivery {
        case .inserted(let app): try c.encode("inserted", forKey: .kind); try c.encode(app, forKey: .app)
        case .unconfirmed(let app, let viaPaste):
            try c.encode("unconfirmed", forKey: .kind); try c.encode(app, forKey: .app); try c.encode(viaPaste, forKey: .viaPaste)
        case .copied(let refusal): try c.encode("copied", forKey: .kind); try c.encode(refusal.rawValue, forKey: .reason)
        }
    }
}

/// How long dictation history is kept (0.5.312, Miles 21:40: "how many dictations do we really want to store").
enum DictationRetention: String, CaseIterable, Sendable {
    case week = "7", month = "30", quarter = "90", forever = "forever", none = "none"
    static let `default` = DictationRetention.month
    var title: String {
        switch self {
        case .week: "7 days"
        case .month: "30 days"
        case .quarter: "90 days"
        case .forever: "Forever"
        case .none: "Don't keep"
        }
    }
    var days: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .forever, .none: nil
        }
    }
    /// "Don't keep" writes nothing to disk; this run still holds its last few so a card's Fix a word works.
    var writesToDisk: Bool { self != .none }
}

/// Dictation history, newest first, kept on this Mac (private file). 0.5.312: as long as the retention setting says,
/// never more than 5,000 entries.
enum DictationHistory {
    static let cap = 5_000
    /// What "Don't keep" holds in memory for this run only.
    static let sessionOnly = 10
    /// How many the pet's list shows; the rest live in COS Activity → Dictation history.
    static let petCount = 10
    /// The pet pill names the history and never counts it (Miles: a count "can become just arbitrarily large").
    static let pillLabel = "DICTATIONS"
    static func adding(_ record: DictationRecord, to list: [DictationRecord], retention: DictationRetention = .forever, now: Date = Date()) -> [DictationRecord] {
        pruned([record] + list.filter { $0.id != record.id }, retention: retention, now: now)
    }
    /// Keeps the list's own order (newest used first: `adding` puts a re-added record on top), drops anything older than the
    /// retention, never more than `cap`. "Don't keep": this run's last few only. Never re-sorts by date, or a retried
    /// dictation would sink back to where it was first made.
    static func pruned(_ list: [DictationRecord], retention: DictationRetention, now: Date) -> [DictationRecord] {
        if retention == .none { return Array(list.prefix(sessionOnly)) }
        let kept = retention.days.map { days in list.filter { now.timeIntervalSince($0.createdAt) <= Double(days) * 86_400 } } ?? list
        return Array(kept.prefix(cap))
    }
    /// Local substring search over the text, case and diacritic insensitive. Empty finds everything.
    static func search(_ list: [DictationRecord], _ query: String) -> [DictationRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return list }
        return list.filter { $0.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
    /// One day of the history pane: its records, newest first.
    struct Day: Identifiable, Sendable {
        let day: Date
        let records: [DictationRecord]
        var id: Date { day }
    }
    /// Grouped by calendar day, newest day first.
    static func days(_ list: [DictationRecord], calendar: Calendar = .current) -> [Day] {
        var groups: [Date: [DictationRecord]] = [:]
        for record in list { groups[calendar.startOfDay(for: record.createdAt), default: []].append(record) }
        return groups.keys.sorted(by: >).map { day in Day(day: day, records: groups[day]!.sorted { $0.createdAt > $1.createdAt }) }
    }
    static func removing(_ id: UUID, from list: [DictationRecord]) -> [DictationRecord] { list.filter { $0.id != id } }
    /// Fix a word's Save corrects the dictation itself (0.5.318, Miles: Heard still read "Y joule 360" after he saved
    /// "Jewel360"): same id, time, place and order; only the text changes.
    static func correcting(_ id: UUID, to text: String, in list: [DictationRecord]) -> [DictationRecord] {
        list.map { $0.id == id ? DictationRecord(id: $0.id, text: text, createdAt: $0.createdAt, delivery: $0.delivery, engine: $0.engine, fallbackReason: $0.fallbackReason,
                                                 heard: $0.heard, polishModel: $0.polishModel) : $0 }
    }
    /// 0.5.331 paste first, polish in place: Claude's version replaced the typed text in the field, so the dictation reads
    /// it, and keeps what was heard and the model, as a dictation polished before the paste does. Same id, time and place.
    static func polishing(_ id: UUID, to text: String, heard: String, model: String, in list: [DictationRecord]) -> [DictationRecord] {
        list.map { r in r.id == id ? DictationRecord(id: r.id, text: text, createdAt: r.createdAt, delivery: r.delivery, engine: r.engine, fallbackReason: r.fallbackReason,
                                                     heard: heard, polishModel: model) : r }
    }
    /// A file that exists but does not read is moved aside to `<name>.corrupt-<UTC stamp>` before anything is saved
    /// over it, so a bad build can never silently erase someone's history. `writable` is false when it could not move.
    static func loadOrQuarantine(from url: URL, now: Date) -> (records: [DictationRecord], movedTo: URL?, writable: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], nil, true) }
        if let data = try? Data(contentsOf: url), let file = try? decoder().decode(File.self, from: data) { return (ordered(file.dictations), nil, true) }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd-HHmmss"
        let aside = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".corrupt-" + f.string(from: now))
        guard rename(url.path, aside.path) == 0 else { return ([], nil, false) }
        return ([], aside, true)
    }
    static func ordered(_ list: [DictationRecord]) -> [DictationRecord] {
        Array(list.sorted { $0.createdAt > $1.createdAt }.prefix(cap))
    }
    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }
    private static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    private struct File: Codable { var version = 1; var dictations: [DictationRecord] }
    /// A missing or unreadable file is an empty history, never a crash.
    static func load(from url: URL) -> [DictationRecord] {
        guard let data = try? Data(contentsOf: url), let file = try? decoder().decode(File.self, from: data) else { return [] }
        return ordered(file.dictations)
    }
    /// Atomic and private: a 0600 temp file in the same folder, then rename(2). Default data protection (class C);
    /// never complete-unless-open, which the keybag locks minutes after the screen does.
    static func save(_ list: [DictationRecord], to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try encoder().encode(File(dictations: ordered(list)))
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "COSDictation", code: 3, userInfo: [NSLocalizedDescriptionKey: "Recent dictations could not be saved."])
        }
        guard rename(temp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw NSError(domain: "COSDictation", code: 3, userInfo: [NSLocalizedDescriptionKey: "Recent dictations could not be saved."])
        }
    }
}

/// The card's 20-second fold-away (mock 04). Hovering pauses it; leaving resumes from where it stopped.
struct DictationCountdown: Equatable, Sendable {
    static let seconds: TimeInterval = 20
    private var spent: TimeInterval = 0
    private var runningSince: Date?
    init(start: Date) { runningSince = start }
    var paused: Bool { runningSince == nil }
    func elapsed(at now: Date) -> TimeInterval { spent + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0) }
    func remaining(at now: Date) -> TimeInterval { max(0, Self.seconds - elapsed(at: now)) }
    /// 1 when fresh, 0 when it folds; the ring draws this.
    func fraction(at now: Date) -> Double { remaining(at: now) / Self.seconds }
    func expired(at now: Date) -> Bool { remaining(at: now) <= 0 }
    mutating func pause(at now: Date) { guard let since = runningSince else { return }; spent += max(0, now.timeIntervalSince(since)); runningSince = nil }
    mutating func resume(at now: Date) { if runningSince == nil { runningSince = now } }
}

/// Fix a word (mock 06): tap a word, tap another to widen to a phrase, type the spelling.
enum DictationFixText {
    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }
    /// The heard phrase for the dictionary: the tapped words, without punctuation hugging either end.
    static func heard(_ tokens: [String], _ range: ClosedRange<Int>) -> String {
        guard range.lowerBound >= 0, range.upperBound < tokens.count else { return "" }
        let edge = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespaces)
        return tokens[range].joined(separator: " ").trimmingCharacters(in: edge)
    }
    /// Nothing selected: start at the tap. The lone selected word again: clear. Outside a selection: widen to cover the
    /// tap. Inside a phrase: start over at the tap.
    static func select(_ index: Int, current: ClosedRange<Int>?) -> ClosedRange<Int>? {
        guard let current else { return index...index }
        if current == index...index { return nil }
        if current.contains(index) { return index...index }
        return min(current.lowerBound, index)...max(current.upperBound, index)
    }
}

/// 0.5.334 (server 6.84.0): a link, email or path Fix a word saves ("/pricing") is kept as a correction only, and the
/// server's learn answer says so (`correctionOnly: true`, `note`). Control shows that note, plain: one line, bounded, never
/// an em dash or an arrow, and nothing when the answer is not correction-only.
enum DictionaryLearnNote {
    static let maximumLength = 240
    static func line(correctionOnly: Bool?, note: String?) -> String? {
        guard correctionOnly == true, let raw = note else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maximumLength, !text.contains(where: \.isNewline),
              !text.contains("\u{2014}"), !text.contains("\u{2192}") else { return nil }
        return text
    }
}

/// The dictionary's "where and when" line (mock 06): "dictation · now", "meeting · Oct 12", "G2 · Oct 9".
enum DictionaryLabels {
    static func source(_ raw: String) -> String {
        switch raw {
        case "g2": "G2"
        case "manual": "added"
        case "dictation", "meeting": raw
        default: "COS"
        }
    }
    static func when(_ date: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let date else { return "" }
        if now.timeIntervalSince(date) < 60 { return "now" }
        if calendar.isDate(date, inSameDayAs: now) {
            let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "h:mm a"
            return f.string(from: date)
        }
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMM d"
        return f.string(from: date)
    }
    static func line(source raw: String, at date: Date?, now: Date, calendar: Calendar = .current) -> String {
        let when = when(date, now: now, calendar: calendar)
        return when.isEmpty ? source(raw) : source(raw) + " · " + when
    }
}

// MARK: - Presses that do not become a dictation, and missed releases (0.5.330)
//
// Miles, 2026-10-19: hold to dictate "locked": letting go did nothing and nothing was transcribed. None of the 55 lines
// in his timing file was near the two-minute limit, and the stuck attempts wrote no line at all: every way a press can
// end without a dictation was silent. Now each writes an event line, a press while the last dictation is still finishing
// says so, and a key release COS never heard is reconciled from the keyboard's own state.

/// A press that did not become a dictation, or a release COS reconciled. The raw value is the timing line's outcome.
enum DictationPressEvent: String, Sendable, CaseIterable {
    /// Pressed while the last dictation was still starting, listening, transcribing or polishing.
    case refusedBusy = "refused_busy"
    /// Released before the microphone's first buffer arrived (or before LISTENING showed).
    case canceledStarting = "canceled_starting"
    /// Another key joined the hold key mid-hold: what was said is copied, never typed.
    case interruptedChord = "interrupted_chord"
    /// The keyboard said the hold key was up, though COS never heard it go up.
    case releaseReconciled = "release_reconciled"
}

extension DictationTiming {
    /// One event line: nothing captured, and the event as its outcome.
    static func event(_ event: DictationPressEvent, at: Date) -> DictationTiming {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return DictationTiming(at: f.string(from: at), releaseToClosedMs: 0, tailMs: 0, capturedSeconds: 0.0,
                               finalDBFS: nil, tailDBFS: nil, engine: nil, transcribeMs: nil, polishMs: nil, outcome: event.rawValue)
    }
}

/// While the hold key is believed down, COS reads the keyboard's own state (CGEventSource) every 150 ms. Two reads in a
/// row that say "up" mean the release was missed (secure input, an app switch, a stalled main thread), so COS runs the
/// release itself. A key the keyboard state never showed as down is never released this way: on a keyboard or remapper
/// whose state does not carry the key, an "up" proves nothing, and a false release would cut every dictation short.
enum DictationHoldWatch {
    static let pollMilliseconds = 150
    static let upReadsToRelease = 2
    struct Reads: Equatable, Sendable {
        private(set) var seenDown = false
        private(set) var ups = 0
        /// One read. True when the release should run now.
        mutating func read(down: Bool) -> Bool {
            if down { seenDown = true; ups = 0; return false }
            guard seenDown else { return false }
            ups += 1
            return ups >= DictationHoldWatch.upReadsToRelease
        }
    }
    /// Watch while a hold dictation is starting or listening, or while the tracker still believes the key is down (a
    /// missed release then swallows the next press).
    static func watches(phase: String, held: Bool, trackerDown: Bool) -> Bool {
        (held && (phase == "Starting" || phase == "Listening")) || trackerDown
    }
    /// Miles 2026-10-19: Fn's release never arrived, so the next key he typed (seconds later) was taken as a chord and
    /// the dictation was copied, not typed. A key typed more than a second after the press, while the keyboard says the
    /// hold key is up (and once said it was down), is the missed release: a release that types, not a chord.
    static let keyDownReleaseAfterSeconds: TimeInterval = 1
    static func keyDownIsMissedRelease(trackerDown: Bool, hardwareDown: Bool?, seenDown: Bool, sincePress: TimeInterval) -> Bool {
        trackerDown && hardwareDown == false && seenDown && sincePress > keyDownReleaseAfterSeconds
    }
    /// The trigger's own device bit in a flags word (CGEventSource.flagsState's raw value); nil for a key that is not a
    /// lone-modifier trigger.
    static func modifierDown(flags: UInt64, keyCode: UInt16) -> Bool? {
        DictationTrigger.modifierKeys[keyCode].map { flags & $0.device != 0 }
    }
}

/// macOS gives the 🌐 key a job of its own (System Settings, Keyboard, "Press 🌐 key to"): stored as com.apple.HIToolbox
/// AppleFnUsageType, 0 for Do Nothing, absent for the system default. Anything but Do Nothing lets macOS act on the key,
/// and on Miles's Mac (2026-10-19, TextInputSwitcher started at 20:56) Fn's release stopped reaching COS from then on.
enum DictationFnUsage {
    static let doNothing = 0
    static func conflicts(usageType: Int?, fnIsDictationKey: Bool) -> Bool { fnIsDictationKey && usageType != doNothing }
    static let note = "Your 🌐 key also has a job in macOS, which can swallow its release. In System Settings, Keyboard, set Press 🌐 key to Do Nothing."
    static let keyboardSettingsURL = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
}

/// What the listening pill shows. It replaces the pet's ledger row only while it is not hidden (Miles picked A).
enum DictationPill: Equatable, Sendable {
    case hidden
    /// 0.5.327: pressed, the microphone not yet delivering audio. LISTENING (and the start sound) wait for its first buffer.
    case starting
    case listening(since: Date)
    case transcribing
    /// 0.5.325: Claude is polishing the heard text (AI polish), at most its budget.
    case polishing
    /// 0.5.330: a press while the last dictation is still transcribing or polishing, for `finishingSeconds`.
    case finishing
    /// About 1.5 seconds after delivery. `confirmed` (green, ✓) only when a measured change proved the text landed.
    case flash(label: String, confirmed: Bool)
    static let flashSeconds: TimeInterval = 1.5
    static let finishingSeconds: TimeInterval = 1.5
    var replacesLedger: Bool { self != .hidden }
    var label: String {
        switch self {
        case .hidden: ""
        case .starting: "STARTING"
        case .listening: "LISTENING"
        case .transcribing: "TRANSCRIBING"
        case .polishing: "POLISHING"
        case .finishing: "STILL FINISHING"
        case .flash(let label, _): label
        }
    }
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return "\(s / 60):" + (s % 60 < 10 ? "0" : "") + "\(s % 60)"
    }
}

// MARK: - Clipboard restore (0.5.312)
//
// Miles, 2026-10-15 21:23, after Wispr Flow: "if I have something copied and I want to dump in my transcription, it's
// going to copy it onto the clipboard, which then wipes what I have copied ... Ideally, it would [restore] the
// clipboard back to whatever that previous [item] was." COS now touches the clipboard only when it must: right before
// a ⌘V it posts (then puts the person's clipboard back), or when the card asks them to paste by hand.

/// One clipboard item: every type it carried, in order, with its bytes.
struct DictationClipboardItem: Equatable, Sendable {
    struct Entry: Equatable, Sendable { let type: String; let data: Data }
    let entries: [Entry]
}

struct DictationClipboardSnapshot: Equatable, Sendable {
    let items: [DictationClipboardItem]
    let changeCount: Int
}

/// What COS needs from a pasteboard, so the whole round trip runs against a fake in the checks.
protocol DictationPasteboardAccess: AnyObject {
    var changeCount: Int { get }
    /// Each item's types, in order.
    func itemTypes() -> [[String]]
    func data(item: Int, type: String) -> Data?
    /// clearContents, then one item per element with every entry, preserving order.
    func replace(with items: [DictationClipboardItem]) -> Bool
    /// The transcript as a plain string, plus marker types (empty data) that tell clipboard managers to skip it.
    func writeTranscript(_ text: String, markerTypes: [String]) -> Bool
}

enum DictationClipboard {
    static let maximumBytes = 64 * 1024 * 1024
    /// nspasteboard.org: clipboard managers skip transient and auto-generated items.
    static let transientTypes = ["org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
    /// After the ⌘V: no sooner than this, longer while the field is still changing, never past the maximum.
    static let restoreAfterMilliseconds = 500, restoreMaxMilliseconds = 1_500

    enum Use: Equatable, Sendable {
        /// Accessibility typed it, or COS's own window took it: the clipboard is never touched.
        case untouched
        /// COS posted ⌘V: write the transcript just before, put the person's clipboard back after.
        case pasteThenRestore
        /// The card asks the person to paste: the transcript stays on the clipboard.
        case keepForCard
    }
    static func use(for outcome: DictationDeliveryOutcome) -> Use {
        switch outcome {
        case .inserted(_, let viaPaste), .unconfirmed(_, let viaPaste): viaPaste ? .pasteThenRestore : .untouched
        case .refused: .keepForCard
        }
    }

    /// Every item and type, or nil when the clipboard is larger than `cap` (then it is not restored).
    static func snapshot(_ board: some DictationPasteboardAccess, cap: Int = maximumBytes) -> DictationClipboardSnapshot? {
        var total = 0
        var items: [DictationClipboardItem] = []
        for (index, types) in board.itemTypes().enumerated() {
            var entries: [DictationClipboardItem.Entry] = []
            for type in types {
                guard let data = board.data(item: index, type: type) else { continue }
                total += data.count
                guard total <= cap else { return nil }
                entries.append(.init(type: type, data: data))
            }
            items.append(DictationClipboardItem(entries: entries))
        }
        return DictationClipboardSnapshot(items: items, changeCount: board.changeCount)
    }

    enum Decision: Equatable, Sendable {
        case restore
        case skip(String)
    }
    /// Restore only after a ⌘V COS posted, with the setting on, a snapshot taken, and nobody having copied since COS
    /// wrote the transcript (`setChangeCount`).
    static func decision(enabled: Bool, pasted: Bool, snapshot: DictationClipboardSnapshot?, setChangeCount: Int, currentChangeCount: Int) -> Decision {
        guard enabled else { return .skip("setting off") }
        guard pasted else { return .skip("no paste") }
        guard snapshot != nil else { return .skip("clipboard too large to restore") }
        guard currentChangeCount == setChangeCount else { return .skip("clipboard changed since the paste") }
        return .restore
    }

    /// Keep waiting before the restore? Always until the minimum, while the field is still moving until the maximum.
    static func keepWaiting(elapsedMilliseconds: Int, fieldChanging: Bool) -> Bool {
        if elapsedMilliseconds < restoreAfterMilliseconds { return true }
        return fieldChanging && elapsedMilliseconds < restoreMaxMilliseconds
    }

    static func restore(_ snapshot: DictationClipboardSnapshot, to board: some DictationPasteboardAccess) -> Bool {
        board.replace(with: snapshot.items)
    }
}

// MARK: - Dictation sounds (0.5.312)
//
// Miles approved the library 2026-10-15 21:16-21:32 (design/dictation-sounds-preview.html; "Unstable saber" is v2,
// matched to his reference; v1 is "Unstable saber (bright)"), rendered offline to
// Resources/Sounds by scripts/render-dictation-sounds.py. Original synthesis only.
// 0.5.315: "Miles Windu saber" is NOT rendered: it is Miles's own design (made by him with an AI music tool, his to
// ship), bundled byte-identical to the files he saved as his custom start and stop sounds (48 kHz mono Int16; the
// player connects at each file's own format).

enum DictationPetKind: String, Sendable { case jedi, droid, other }

enum DictationSoundEdge: String, Sendable, CaseIterable { case start, stop }

enum DictationSoundLibrary {
    /// Bundled sounds, in menu order: id (file prefix) and the name Settings shows.
    static let sounds: [(id: String, name: String)] = [
        ("windu-saber", "Miles Windu lightsaber"),
        ("unstable-saber", "Unstable saber"), ("unstable-saber-bright", "Unstable saber (bright)"), ("dark-saber", "Dark saber"),
        ("saber-full", "Saber, full ignition"), ("saber-ignite", "Saber ignite"),
        ("saber-soft", "Saber, soft"), ("droid-chirp", "Droid chirp"), ("soft-chime", "Soft chime"),
    ]
    static let defaultVolume = 0.6
    /// Pitch at playback, in semitones (AVAudioUnitTimePitch: duration unchanged). Default 0.
    static let pitchRange = -12.0...6.0
    static func cents(_ semitones: Double) -> Double {
        guard semitones.isFinite else { return 0 }
        return min(pitchRange.upperBound, max(pitchRange.lowerBound, semitones.rounded())) * 100
    }
    /// Your own file: the SOURCE may be up to 20 MB (it is trimmed on import); what is stored is at most 3 s.
    static let maximumSourceBytes = 20 * 1024 * 1024
    static let maximumStoredSeconds = 3.0

    /// The shipped Jedi Miles Windu pack (PetSpriteStore.bundledCharacters).
    static let winduPackID = "jedi-miles-windu"
    /// THE pet to default table (Miles: the Jedi's crackling Unstable saber is his favorite). 0.5.315: his own saber
    /// design was the Jedi Miles Windu pack's default. 0.5.318 (Miles 2026-10-17, "my saber should be default but keep
    /// it named Miles Windu lightsaber"): every Jedi pack plays it, Nia Solari, Elara Vale and Rowan Vale too.
    /// `pack` stays for the sound's name and future per-pack sounds.
    static func petDefault(_ kind: DictationPetKind, pack: String? = nil) -> String {
        switch kind {
        case .jedi: "windu-saber"
        case .droid: "droid-chirp"
        case .other: "soft-chime"
        }
    }
    static func name(_ id: String) -> String { sounds.first { $0.id == id }?.name ?? id }
    static func fileName(_ id: String, _ edge: DictationSoundEdge) -> String { "\(id)-\(edge.rawValue).wav" }

    /// A pack with the duel and swarm stories is one of the Jedi packs; a pack whose files name a droid or robot is a
    /// droid; anything else (Cloud Puff, a gallery pet) is other.
    static func petKind(hasCombatStories: Bool, assetNames: [String]) -> DictationPetKind {
        if hasCombatStories { return .jedi }
        let names = assetNames.map { $0.lowercased() }
        return names.contains { $0.contains("droid") || $0.contains("robot") || $0.contains("astromech") } ? .droid : .other
    }

    /// Which shipped pack is installed: the ONE pack whose state map names exactly the pose files the installed map
    /// names. None, or several (Elara and Rowan Vale use the same file names), is nil, which keeps the kind's default.
    static func installedPack(_ installed: Set<String>, packs: [(id: String, files: Set<String>)]) -> String? {
        guard !installed.isEmpty else { return nil }
        let matches = packs.filter { $0.files == installed }
        return matches.count == 1 ? matches[0].id : nil
    }

    /// What Settings stores: "pet", "library:<id>" or "custom:<file name>".
    enum Choice: Equatable, Sendable {
        case pet, library(String), custom(String)
        init(stored: String) {
            if stored.hasPrefix("library:") { self = .library(String(stored.dropFirst(8))) }
            else if stored.hasPrefix("custom:") { self = .custom(String(stored.dropFirst(7))) }
            else { self = .pet }
        }
        var stored: String {
            switch self {
            case .pet: "pet"
            case .library(let id): "library:" + id
            case .custom(let file): "custom:" + file
            }
        }
    }

    enum Resolved: Equatable, Sendable {
        case silent(String)
        case bundled(String)
        case custom(String)
    }

    /// Pet default, then the person's choice; a custom file that is no longer valid falls back to the pet's sound.
    /// Volume 0 is off, and nothing plays while a COS recording is capturing (it would be recorded).
    static func resolve(_ choice: Choice, edge: DictationSoundEdge, pet: DictationPetKind, pack: String? = nil, volume: Double,
                        macRecording: Bool, customUsable: (String) -> Bool) -> Resolved {
        guard volume > 0 else { return .silent("volume off") }
        guard !macRecording else { return .silent("a COS recording is capturing") }
        switch choice {
        case .library(let id) where sounds.contains(where: { $0.id == id }): return .bundled(fileName(id, edge))
        case .custom(let file) where customUsable(file): return .custom(file)
        default: return .bundled(fileName(petDefault(pet, pack: pack), edge))
        }
    }

    /// Your own file's SOURCE: at most 20 MB and it must decode (a duration). Long files are trimmed, not refused.
    /// Nil means accepted.
    static func customRefusal(byteCount: Int, duration: Double?) -> String? {
        guard byteCount <= maximumSourceBytes else { return "That file is over 20 MB. Choose a shorter file." }
        guard let duration, duration.isFinite, duration > 0 else { return "COS could not play that file. Choose an audio file." }
        return nil
    }
}

/// Where the listening pill goes (Miles accepted 2026-10-15): on the pet when the pet is on the screen that holds the
/// focused window; otherwise the floating pill, bottom center of THAT screen (pet on another display, in another
/// space, or hidden).
enum DictationPlacement: Equatable, Sendable {
    case pet
    case floating(screen: CGRect)

    static func choose(petFrame: CGRect?, focusedWindow: CGRect?, screens: [CGRect], mainScreen: CGRect?) -> DictationPlacement? {
        let focused = focusedWindow.flatMap { window in
            screens.max { overlap($0, window) < overlap($1, window) }.flatMap { overlap($0, window) > 0 ? $0 : nil }
        } ?? mainScreen ?? screens.first
        if let petFrame, let focused, overlap(focused, petFrame) > 0 { return .pet }
        if petFrame != nil, focused == nil { return .pet }
        return focused.map { .floating(screen: $0) }
    }
    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }
}

/// Your own sound, trimmed on import (Miles, 2026-10-15). Loudness is RMS over 10 ms windows; the sound begins at the
/// first window at or above -40 dBFS and ends after the last one. START: up to 2.0 s from the onset, 5 ms fade-in,
/// 0.45 s fade-out. STOP, "Use the end of this file": the last 0.6 s, ending 50 ms past the final drop so the fade-out
/// covers it, 30 ms fade-in, 70 ms fade-out. Pure; the app decodes, trims with this, and stores only the result.
enum DictationSoundTrim {
    static let thresholdDB = -40.0
    static let windowSeconds = 0.010
    struct Window: Equatable, Sendable {
        let start: Double
        let end: Double
        let fadeIn: Double
        let fadeOut: Double
        var length: Double { end - start }
    }

    /// dBFS per 10 ms window of mono samples.
    static func levels(_ samples: [Float], sampleRate: Double) -> [Double] {
        let size = max(1, Int((sampleRate * windowSeconds).rounded()))
        return stride(from: 0, to: samples.count, by: size).map { first in
            let last = min(samples.count, first + size)
            var sum = 0.0
            for i in first..<last { sum += Double(samples[i]) * Double(samples[i]) }
            let rms = (sum / Double(last - first)).squareRoot()
            return rms > 0 ? 20 * log10(rms) : -160
        }
    }
    /// Seconds where the sound begins, or nil when the file never reaches -40 dBFS.
    static func onset(_ levels: [Double]) -> Double? {
        levels.firstIndex { $0 >= thresholdDB }.map { Double($0) * windowSeconds }
    }
    /// Seconds where the sound has ended: just after the last window at or above -40 dBFS.
    static func end(_ levels: [Double]) -> Double? {
        levels.lastIndex { $0 >= thresholdDB }.map { Double($0 + 1) * windowSeconds }
    }
    static func startWindow(onset: Double, duration: Double) -> Window {
        Window(start: onset, end: min(duration, onset + 2.0), fadeIn: 0.005, fadeOut: 0.45)
    }
    static func stopWindow(end: Double, duration: Double) -> Window {
        Window(start: max(0, end - 0.55), end: min(duration, end + 0.05), fadeIn: 0.030, fadeOut: 0.070)
    }
    /// The window's samples with linear fades (each at most half the window).
    static func apply(_ samples: [Float], sampleRate: Double, window: Window) -> [Float] {
        let first = max(0, min(samples.count, Int((window.start * sampleRate).rounded())))
        let last = max(first, min(samples.count, Int((window.end * sampleRate).rounded())))
        var out = Array(samples[first..<last])
        let fadeIn = min(out.count / 2, Int((window.fadeIn * sampleRate).rounded()))
        let fadeOut = min(out.count / 2, Int((window.fadeOut * sampleRate).rounded()))
        for i in 0..<fadeIn { out[i] *= Float(i) / Float(fadeIn) }
        for i in 0..<fadeOut { out[out.count - 1 - i] *= Float(i) / Float(fadeOut) }
        return out
    }
    /// Mono 16-bit PCM WAV of the trimmed sound, which is what gets stored.
    static func wav(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func ascii(_ s: String) { data.append(contentsOf: s.utf8) }
        func u16(_ x: UInt16) { var v = x.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u32(_ x: UInt32) { var v = x.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        ascii("RIFF"); u32(UInt32(36 + bytes)); ascii("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16); ascii("data"); u32(UInt32(bytes))
        for sample in samples {
            var v = Int16(max(-1, min(1, sample)) * 32767).littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        return data
    }
}

// MARK: - 0.5.313 editing and quiet (Miles, 2026-10-15 22:02-22:06)
//
// "Fix from the moment it lands": a Fix button on the pill for a few seconds and a shortcut for the latest dictation.
// "Replace the pasted text": the corrected dictation goes back where COS put it, only when COS can prove that spot
// still holds exactly what it inserted. "Mute the rest of the sound ... and as soon as you're done it picks back up."

/// The three dictation shortcuts. Each must differ from the other two and from Open Activity.
enum DictationShortcutSlot: String, CaseIterable, Sendable {
    case hold, toggle, fix
    /// UserDefaults prefix: dictation.hold, dictation.toggle, dictation.fix.
    var defaultsPrefix: String { "dictation." + rawValue }
    var title: String {
        switch self {
        case .hold: "Push to talk"
        case .toggle: "Start / stop"
        case .fix: "Fix last dictation"
        }
    }
    /// The Carbon hot key id, and the id `MacDictationStore.hotKey` dispatches on.
    var hotKeyID: UInt32 {
        switch self {
        case .hold: 1
        case .toggle: 2
        case .fix: 3
        }
    }
}

enum DictationShortcuts {
    /// ⌃⌥F (ANSI F is key code 3): Fix a word on the most recent dictation.
    static let defaultFix = DictationTrigger.keys(keyCode: 3, modifiers: DictationTrigger.control | DictationTrigger.option)
    /// True when `trigger` is already Open Activity's or another dictation slot's. Turning a slot off never conflicts.
    static func conflicts(_ trigger: DictationTrigger?, slot: DictationShortcutSlot,
                          assigned: [DictationShortcutSlot: DictationTrigger], activity: DictationTrigger?) -> Bool {
        guard let trigger else { return false }
        if trigger == activity { return true }
        return assigned.contains { $0.key != slot && $0.value == trigger }
    }
}

enum DictationQuickFix {
    /// The pill keeps its INSERTED / PASTED flash, with Fix, this long.
    static let offerSeconds: TimeInterval = 5
    /// The shortcut and the pill's Fix open the newest dictation, never while one is being dictated.
    static func target(_ recent: [DictationRecord], busy: Bool) -> UUID? { busy ? nil : recent.first?.id }
    /// Fix is offered on every flash (inserted, pasted, sent). A refusal shows the card, which has its own Fix a word.
    static func offers(_ outcome: DictationDeliveryOutcome) -> Bool { outcome.flash != nil }
}

/// Where COS put a dictation, measured: the app and the UTF-16 range the inserted text occupies.
struct DictationInsertedSpan: Equatable, Sendable {
    let pid: Int32
    let location: Int
    let length: Int
}

/// Replace it in <App> (after Save in Fix a word). Pure: the app reads a bounded window of the field around where the
/// dictation went, calls `plan`, picks the route (`route`), proves the selection for a paste (`pasteProof`), acts,
/// re-measures and calls `confirmed`. Anything short of proof copies the corrected text instead. Never Return or Send.
///
/// 0.5.318 (Miles, 2026-10-16 13:02, Claude desktop): "COS set the text in Claude but couldn't confirm it" and nothing
/// changed. The log shows why: in Electron and Chromium (Claude, Slack, Comet) setting AXSelectedText returns success and
/// does nothing (every delivery there reads `setter=0 after=<unchanged>` and lands only with ⌘V), and 0.5.313's replace
/// used only that setter. Replace now follows what delivery proved: the setter where it moved the field, else a ⌘V of
/// the corrected words over a selection COS has read back as exactly those words, in the app's own focused field.
enum DictationReplace {
    enum Reason: String, Sendable { case notMeasured, terminal, appGone, fieldGone, textMoved, notFocused, selectionUnproven, noChange }
    /// One whole-word change, in UTF-16 units (the unit AXSelectedTextRange counts): `original` at `location` becomes
    /// `replacement`. Relative to the dictation from `wordEdit`; in field coordinates once `plan` has placed it.
    struct Edit: Equatable, Sendable {
        let location: Int
        let length: Int
        let original: String
        let replacement: String
    }
    enum Plan: Equatable, Sendable {
        /// `dictationAt` is where the whole dictation now starts in the field, or nil when only the misheard words were
        /// found (the person edited the rest of it), so nothing more is known about where it sits.
        case edit(Edit, dictationAt: Int?)
        case copy(Reason)
    }
    enum Route: Equatable, Sendable { case accessibility, paste }
    /// The most COS reads on either side of where it put the dictation, in UTF-16 units. Never the field's whole value.
    static let windowRadius = 256
    /// The misheard words alone are looked for only when at least this long, and only when they occur once.
    static let minimumPhraseUnits = 3

    /// Recorded only when the measurement proved exactly `count` units landed at a known caret (verdict `landed`).
    /// A `changed` field (something else moved too) has no trustworthy range.
    static func span(pid: Int32, baseline: DictationFieldSnapshot, after: DictationFieldSnapshot, count: Int) -> DictationInsertedSpan? {
        guard let location = baseline.location, count > 0,
              DictationDelivery.verdict(baseline: baseline, after: after, count: count) == .landed else { return nil }
        return DictationInsertedSpan(pid: pid, location: location, length: count)
    }
    /// The smallest change of whole words that turns `old` into `new`: common leading and trailing words stay, only the
    /// words between are replaced ("uh Y joule 360 page" → "uh Jewel360 page" replaces "Y joule 360"). nil when equal.
    static func wordEdit(from old: String, to new: String) -> Edit? {
        func runs(_ text: String) -> [String] {
            var out: [String] = [], current = "", gap: Bool?
            for c in text {
                let g = c.isWhitespace || c.isNewline
                if gap != nil, g != gap { out.append(current); current = "" }
                current.append(c); gap = g
            }
            if !current.isEmpty { out.append(current) }
            return out
        }
        let a = runs(old), b = runs(new)
        guard a != b else { return nil }
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        let original = a[p..<(a.count - s)].joined(), replacement = b[p..<(b.count - s)].joined()
        return Edit(location: a[..<p].joined().utf16.count, length: original.utf16.count, original: original, replacement: replacement)
    }
    /// The bounded window to read: `windowRadius` either side of the recorded span, clipped to the field.
    static func window(span: DictationInsertedSpan, currentLength: Int, fieldCharacters: Int) -> (location: Int, length: Int) {
        let start = max(0, min(span.location, fieldCharacters) - windowRadius)
        let end = min(fieldCharacters, span.location + max(span.length, currentLength) + windowRadius)
        return (start, max(0, end - start))
    }
    /// Where the edit goes. `current` is what COS believes the field holds at the span (what it inserted, or put there
    /// on the last replace); `window` is the field's text from `windowStart`. In order: the dictation exactly where COS
    /// put it; else the dictation found once in the window (text was typed above it); else the misheard words found once,
    /// on word boundaries (the person edited other words of it). Anything else, or two candidates, copies.
    static func plan(span: DictationInsertedSpan?, terminal: Bool, appRunning: Bool, fieldCharacters: Int?,
                     window: String?, windowStart: Int, current: String, corrected: String) -> Plan {
        if terminal { return .copy(.terminal) }
        guard let span else { return .copy(.notMeasured) }
        guard appRunning else { return .copy(.appGone) }
        guard fieldCharacters != nil, let window else { return .copy(.fieldGone) }
        guard let edit = wordEdit(from: current, to: corrected) else { return .copy(.noChange) }
        let field = Array(window.utf16), whole = Array(current.utf16)
        func placed(_ at: Int) -> Edit {
            Edit(location: windowStart + at + edit.location, length: edit.length, original: edit.original, replacement: edit.replacement)
        }
        let expected = span.location - windowStart
        if !whole.isEmpty, matches(whole, in: field, at: expected) { return .edit(placed(expected), dictationAt: span.location) }
        let found = occurrences(whole, in: field, wordBounded: false)
        if found.count == 1 { return .edit(placed(found[0]), dictationAt: windowStart + found[0]) }
        let phrase = Array(edit.original.utf16)
        // Only when the dictation itself is gone: two copies of it are ambiguous even where one copy's words are not
        // on a word boundary.
        if found.isEmpty, phrase.count >= minimumPhraseUnits {
            let hits = occurrences(phrase, in: field, wordBounded: true)
            if hits.count == 1 {
                return .edit(Edit(location: windowStart + hits[0], length: edit.length, original: edit.original, replacement: edit.replacement), dictationAt: nil)
            }
        }
        return .copy(.textMoved)
    }
    /// The window holds exactly `text` at `offset` (UTF-16). Learn from my edits starts only from that proof.
    static func holds(_ window: String, at offset: Int, _ text: String) -> Bool {
        !text.isEmpty && matches(Array(text.utf16), in: Array(window.utf16), at: offset)
    }
    private static func matches(_ needle: [UInt16], in field: [UInt16], at index: Int) -> Bool {
        guard index >= 0, index + needle.count <= field.count else { return false }
        return field[index..<(index + needle.count)].elementsEqual(needle)
    }
    private static func occurrences(_ needle: [UInt16], in field: [UInt16], wordBounded: Bool) -> [Int] {
        guard !needle.isEmpty, needle.count <= field.count else { return [] }
        func wordUnit(_ unit: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(unit) else { return true }  // half of a surrogate pair: inside a word
            return CharacterSet.alphanumerics.contains(scalar)
        }
        return (0...(field.count - needle.count)).filter { i in
            guard matches(needle, in: field, at: i) else { return false }
            guard wordBounded else { return true }
            let before = i == 0 || !wordUnit(field[i - 1]), after = i + needle.count == field.count || !wordUnit(field[i + needle.count])
            return before && after
        }
    }
    /// Delivery proved which way works in this field: the Accessibility setter where it moved the field, else ⌘V
    /// (Electron and Chromium take the set, report success and change nothing).
    static func route(setterWorked: Bool) -> Route { setterWorked ? .accessibility : .paste }
    /// ⌘V replaces only what is selected in the focused field of the frontmost app, so COS pastes only when all of it is
    /// proved: the target app is frontmost, no COS window holds the keyboard, the focused element is the one COS
    /// inserted into, and the selection reads back as exactly the misheard words. nil means paste.
    static func pasteProof(frontmost: Bool, ownWindowKey: Bool, focusedIsTarget: Bool, selection: DictationFieldSnapshot,
                           selectedText: String?, edit: Edit) -> Reason? {
        guard frontmost, !ownWindowKey, focusedIsTarget else { return .notFocused }
        guard selection.location == edit.location, selection.length == edit.length else { return .selectionUnproven }
        guard edit.length == 0 || selectedText == edit.original else { return .selectionUnproven }
        return nil
    }
    /// After selecting the span and setting the corrected text: the count moved by exactly the difference and the caret
    /// sits after the new text. A same-length correction needs the caret, since the count cannot move.
    static func verified(before: DictationFieldSnapshot, after: DictationFieldSnapshot, span: DictationInsertedSpan, newLength: Int) -> Bool {
        let countOK = before.characters.flatMap { n0 in after.characters.map { $0 == n0 - span.length + newLength } }
        let caretOK = after.location.map { $0 == span.location + newLength && after.length == 0 }
        if countOK == false || caretOK == false { return false }
        if newLength == span.length { return caretOK == true }
        return countOK == true || caretOK == true
    }
    /// The edit landed: measured as `verified`, and where the field can be read back, the new words are there.
    static func confirmed(before: DictationFieldSnapshot, after: DictationFieldSnapshot, edit: Edit, readback: String?) -> Bool {
        let span = DictationInsertedSpan(pid: 0, location: edit.location, length: edit.length)
        guard verified(before: before, after: after, span: span, newLength: edit.replacement.utf16.count) else { return false }
        return readback == nil || readback == edit.replacement
    }
    /// The dictation with the tapped words replaced by the spelling, keeping punctuation that hugged either end and
    /// every other character as it was. nil when the range is not in the text.
    static func corrected(_ text: String, range: ClosedRange<Int>, written: String) -> String? {
        var spans: [Range<String.Index>] = []
        var start: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isWhitespace || text[i].isNewline {
                if let s = start { spans.append(s..<i); start = nil }
            } else if start == nil { start = i }
            i = text.index(after: i)
        }
        if let s = start { spans.append(s..<text.endIndex) }
        guard range.lowerBound >= 0, range.upperBound < spans.count, !written.isEmpty else { return nil }
        let whole = spans[range.lowerBound].lowerBound..<spans[range.upperBound].upperBound
        let phrase = Array(text[whole])
        let edge = CharacterSet.punctuationCharacters.union(.symbols)
        func isEdge(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { edge.contains($0) } }
        let lead = phrase.prefix(while: isEdge).count
        let trail = lead == phrase.count ? 0 : phrase.reversed().prefix(while: isEdge).count
        return String(text[..<whole.lowerBound]) + String(phrase.prefix(lead)) + written
            + String(phrase.suffix(trail)) + String(text[whole.upperBound...])
    }
    /// The note under Fix a word after a copy, by reason. Each says what the person can do next.
    static func copiedNote(_ reason: Reason, app: String) -> String {
        switch reason {
        case .terminal: "Copied the corrected text. COS can't swap words inside a terminal: delete the old words there and press ⌘V."
        case .notMeasured: "Copied the corrected text. COS couldn't measure where it went, so it won't touch \(app)."
        case .appGone: "Copied the corrected text. \(app) is no longer open."
        case .fieldGone, .textMoved: "Copied the corrected text. The text in \(app) changed since COS put it there, so COS left it alone."
        case .notFocused: "Copied the corrected text. COS couldn't get back to the text box in \(app): select the dictation there and press ⌘V."
        case .selectionUnproven: "Copied the corrected text. COS couldn't select the words in \(app) to swap them: select the dictation there and press ⌘V."
        case .noChange: "\(app) already has the corrected text."
        }
    }
    /// The note after a change COS made but could not measure. A ⌘V already sent is never sent again.
    static func unverifiedNote(app: String, pasted: Bool) -> String {
        pasted ? "COS pasted the fix into \(app) but couldn't confirm it. Check it there; the corrected text is on the clipboard too."
            : "COS set the text in \(app) but couldn't confirm it. Check it there; the corrected text is on the clipboard too."
    }
}

/// Fix a word's first tap: the likely misheard span, and a suggestion from the COS dictionary (Miles: "yellow fanduna"
/// is one mishearing of "yellowfin tuna"). Pure; the app passes the vocabulary and an English-word check.
enum DictationFixGuess {
    struct Guess: Equatable, Sendable {
        let range: ClosedRange<Int>
        let suggestion: String?
    }
    static let threshold = 0.78
    static let maximumWords = 3

    /// Lowercased letters and digits, accents folded.
    static func normalized(_ s: String) -> String {
        String(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().filter { $0.isLetter || $0.isNumber })
    }
    /// A sound-alike key: vowels dropped after the first letter, voiced and unvoiced pairs merged, repeats collapsed.
    /// "yellow fanduna" and "yellowfin tuna" share "alfntn".
    static func skeleton(_ s: String) -> String {
        var out: [Character] = []
        for (i, c) in normalized(s).enumerated() {
            let mapped: Character?
            switch c {
            case "a", "e", "i", "o", "u", "y", "h", "w": mapped = i == 0 ? "a" : nil
            case "b", "p": mapped = "p"
            case "d", "t": mapped = "t"
            case "c", "g", "j", "k", "q": mapped = "k"
            case "f", "v": mapped = "f"
            case "s", "x", "z": mapped = "s"
            case "m", "n": mapped = "n"
            default: mapped = c
            }
            if let mapped, out.last != mapped { out.append(mapped) }
        }
        return String(out)
    }
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]; row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }
    static func similarity(_ a: String, _ b: String) -> Double {
        let longest = max(a.count, b.count)
        return longest == 0 ? 0 : 1 - Double(distance(a, b)) / Double(longest)
    }
    /// The better of spelling and sound; sound counts a little less and only on keys of three or more.
    static func score(heard: String, term: String) -> Double {
        let spelled = similarity(normalized(heard), normalized(term))
        let h = skeleton(heard), t = skeleton(term)
        let sounded = h.count >= 3 && t.count >= 3 ? similarity(h, t) * 0.95 : 0
        return max(spelled, sounded)
    }
    /// Every span of up to three words around the tap is scored against the vocabulary; the best match at or above the
    /// threshold wins (ties go to the narrower span). With none, the tap widens over neighbors that are neither English
    /// words nor dictionary words. A span already spelled like a dictionary word is not suggested again.
    static func guess(tokens: [String], tapped: Int, vocabulary: [String], known: (String) -> Bool) -> Guess {
        guard tapped >= 0, tapped < tokens.count else { return Guess(range: max(0, tapped)...max(0, tapped), suggestion: nil) }
        var best: (score: Double, width: Int, range: ClosedRange<Int>, term: String)?
        for width in 1...maximumWords {
            for start in max(0, tapped - width + 1)...tapped where start + width - 1 < tokens.count {
                let range = start...(start + width - 1)
                let heard = DictationFixText.heard(tokens, range)
                let h = normalized(heard)
                guard h.count >= 3 else { continue }
                for term in vocabulary {
                    let t = normalized(term)
                    guard !t.isEmpty, t != h else { continue }
                    let s = score(heard: heard, term: term)
                    guard s >= threshold else { continue }
                    if best == nil || s > best!.score + 1e-9 || (abs(s - best!.score) <= 1e-9 && width < best!.width) {
                        best = (s, width, range, term)
                    }
                }
            }
        }
        if let best { return Guess(range: best.range, suggestion: best.term) }
        let dictionary = Set(vocabulary.map(normalized))
        func unknown(_ index: Int) -> Bool {
            let word = DictationFixText.heard(tokens, index...index)
            let n = normalized(word)
            return !n.isEmpty && !n.allSatisfy(\.isNumber) && !dictionary.contains(n) && !known(word)
        }
        var lower = tapped, upper = tapped
        while upper - lower + 1 < maximumWords {
            if lower > 0, unknown(lower - 1) { lower -= 1 }
            else if upper + 1 < tokens.count, unknown(upper + 1) { upper += 1 }
            else { break }
        }
        return Guess(range: lower...upper, suggestion: nil)
    }
}

/// Spoken lists (0.5.318, Miles 2026-10-16, as Wispr Flow does): "number one, … Number two, …" becomes "1. …\n2. …",
/// and "bullet, … next bullet, …" becomes "- …\n- …". Plain-text lines, so it reads the same in Claude, a browser or
/// Slack (a terminal gets spaces for the line breaks, DictationDelivery.terminalText). Conservative by rule, because a
/// wrong list is worse than none:
/// - a marker counts only at the start of a sentence (start of text, or after . ! ? : ; or a line break; after a comma
///   too for "number N", ordinals and bullets), and only when punctuation follows it ("Number one, …", "First: …");
///   "bullet point", "next bullet" and "new bullet" may go without it;
/// - one kind per list, numbered from one in order, at least two markers (bare "one, two, three" needs three);
/// - every item has words in it, or nothing is formatted.
/// So "my number one priority", "I have two kids", "Number one priority is sleep" and "One, two, three, go" stay prose.
/// One list per dictation; the last item runs to the end.
enum DictationListFormat {
    enum Kind: Int, Sendable, CaseIterable { case number, bullet, ordinal, cardinal }
    private struct Marker { let start: Int; let end: Int; let value: Int }
    private static let words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
    private static let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]
    private static let connector = #"(?:\b(?:and then|and|then|also|plus)\s+)?"#
    private static let punctuation = #"[,:;.\-–—]"#
    /// Built per dictation (four small patterns), so nothing non-Sendable is shared across threads.
    private static func pattern(_ kind: Kind) -> NSRegularExpression? {
        let n = words.joined(separator: "|"), o = ordinals.joined(separator: "|")
        let source = switch kind {
        case .number: connector + #"\bnumber\s+("# + n + #"|10|[1-9])\b\s*"# + punctuation + #"\s*"#
        case .ordinal: connector + #"\b("# + o + #")(?:ly)?(?:\s+of\s+all|\s+off)?\b\s*"# + punctuation + #"\s*"#
        case .cardinal: connector + #"\b("# + n + #")\b\s*"# + punctuation + #"\s*"#
        case .bullet: connector + #"\b((?:next|new|another)\s+bullet(?:\s+point)?|bullet\s+point|bullet|dash)\b(\s*"# + punctuation + #"\s*|\s+)"#
        }
        return try? NSRegularExpression(pattern: source, options: [.caseInsensitive])
    }
    /// The fewest markers that make a list.
    static func minimum(_ kind: Kind) -> Int { kind == .cardinal ? 3 : 2 }

    static func format(_ text: String) -> String {
        let ns = text as NSString
        var best: (kind: Kind, run: [Marker])?
        for kind in Kind.allCases {
            let run = sequence(markers(kind, in: ns), kind: kind)
            guard run.count >= minimum(kind) else { continue }
            if best == nil || run[0].start < best!.run[0].start { best = (kind, run) }
        }
        guard let best else { return text }
        var items: [String] = []
        for (i, marker) in best.run.enumerated() {
            let end = i + 1 < best.run.count ? best.run[i + 1].start : ns.length
            guard let item = clean(ns.substring(with: NSRange(location: marker.end, length: end - marker.end))) else { return text }
            items.append((best.kind == .bullet ? "- " : "\(i + 1). ") + item)
        }
        var lead = ns.substring(to: best.run[0].start).trimmingCharacters(in: .whitespacesAndNewlines)
        if lead.hasSuffix(",") { lead = String(lead.dropLast()) + ":" }
        return (lead.isEmpty ? "" : lead + "\n") + items.joined(separator: "\n")
    }

    private static func markers(_ kind: Kind, in ns: NSString) -> [Marker] {
        guard let regex = pattern(kind) else { return [] }
        return regex.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard atSentenceStart(match.range.location, in: ns, comma: kind != .cardinal) else { return nil }
            let word = ns.substring(with: match.range(at: 1)).lowercased()
            switch kind {
            case .bullet:
                // A bare "bullet" or "dash" needs punctuation after it: "Dash to the store", "Bullet points are…".
                let separator = ns.substring(with: match.range(at: 2))
                if word == "bullet" || word == "dash", separator.rangeOfCharacter(from: CharacterSet(charactersIn: ",:;.-–—")) == nil { return nil }
                return Marker(start: match.range.location, end: NSMaxRange(match.range), value: 0)
            case .ordinal:
                guard let index = ordinals.firstIndex(of: word) else { return nil }
                return Marker(start: match.range.location, end: NSMaxRange(match.range), value: index + 1)
            case .number, .cardinal:
                guard let value = words.firstIndex(of: word).map({ $0 + 1 }) ?? Int(word) else { return nil }
                return Marker(start: match.range.location, end: NSMaxRange(match.range), value: value)
            }
        }
    }
    /// From the first "one", each next number in order; markers out of order stay in the text. Bullets in any order.
    private static func sequence(_ found: [Marker], kind: Kind) -> [Marker] {
        if kind == .bullet { return found }
        var run: [Marker] = []
        for marker in found where marker.value == run.count + 1 { run.append(marker) }
        return run
    }
    private static func atSentenceStart(_ location: Int, in ns: NSString, comma: Bool) -> Bool {
        var i = location - 1
        while i >= 0, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 { i -= 1 }
        guard i >= 0 else { return true }
        let previous = ns.character(at: i)
        if [0x2E, 0x21, 0x3F, 0x3A, 0x3B, 0x0A, 0x0D].contains(previous) { return true }  // . ! ? : ; line breaks
        return comma && previous == 0x2C
    }
    /// The item's words, first letter capitalized, without the comma or semicolon that led into the next marker. nil
    /// when nothing is left ("number one, number two, number three" is counting, not a list).
    private static func clean(_ raw: String) -> String? {
        var item = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = item.last, last == "," || last == ";" { item = String(item.dropLast()).trimmingCharacters(in: .whitespaces) }
        guard item.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }), let first = item.first else { return nil }
        // "call Gina" → "Call Gina"; a word that already has a capital ("iPhone", "COS") is left as written.
        let word = item.prefix { $0.isLetter }
        return word == word.lowercased() ? first.uppercased() + item.dropFirst() : item
    }
}

// MARK: - Learn from my edits (0.5.318)

/// Settings → Learn from my edits (Miles, 2026-10-16 13:31): save automatically (his default), suggest only (kept a
/// week to review in a batch), or off.
enum DictationLearnMode: String, CaseIterable, Sendable {
    case automatic, suggest, off
    static let `default` = DictationLearnMode.automatic
    var title: String {
        switch self {
        case .automatic: "Save automatically"
        case .suggest: "Suggest only"
        case .off: "Off"
        }
    }
}

// MARK: - AI polish (0.5.325)
//
// Miles, 2026-10-18: Claude cleans a dictation before COS pastes it, through the server's POST /api/dictation/finalize
// (the glasses' dictation polish: dictionary fixes, then Claude Haiku or Sonnet through the CLI, with the server's own
// daily cap and breaker). Measured that night: it fixes filler ("Um"), punctuation, doubled words and dictionary
// spellings; it does NOT reliably fix a sound-alike mishearing, and Sonnet sometimes guesses wrong. So it is off by
// default and the setting says only what it does. Most dictations go into iTerm2 and Claude (Electron), where replacing
// text after the paste cannot be trusted, so polish runs BEFORE the paste and never longer than its budget: then COS
// pastes what it heard. A finalize call took 2.3 to 3.4 s with either model; a direct Sonnet call up to 7.6 s.

/// Settings, Dictation: AI polish. Off (default), Claude Haiku or Claude Sonnet. UserDefaults `dictation.polishModel`.
enum DictationPolishModel: String, CaseIterable, Sendable {
    case off, haiku, sonnet
    static let `default` = DictationPolishModel.off
    static let defaultsKey = "dictation.polishModel"
    /// A missing or unknown stored value is Off: polish runs only when the person chose a model.
    static func stored(_ value: String?) -> DictationPolishModel { value.flatMap(Self.init(rawValue:)) ?? .default }
    var title: String {
        switch self {
        case .off: "Off"
        case .haiku: "Claude Haiku"
        case .sonnet: "Claude Sonnet"
        }
    }
    /// The history's "Polished · Haiku". nil for Off.
    var shortName: String? {
        switch self {
        case .off: nil
        case .haiku: "Haiku"
        case .sonnet: "Sonnet"
        }
    }
}

/// The pure half of AI polish: when it runs, how long COS waits, what it sends, and which text is pasted. The app asks
/// these and acts; the helper's `dictation-polish` does the round trip (DictationPolishBridge in ProviderStatusCore).
enum DictationPolish {
    /// The server answers 413 above 8,000 characters (a JavaScript string length: UTF-16 units).
    static let maximumCharacters = 8_000
    /// An answer this much longer than what was heard is not a cleanup (a reply, or the model talking): paste the heard.
    static let maximumGrowth = 1.5
    static let growthAllowance = 40
    /// The app's whole wait, process start to answer. The helper's request ends half a second sooner
    /// (DictationPolishBridge.requestSeconds), so a slow model reads as a timeout from the helper, not a killed process.
    static func budget(for model: DictationPolishModel) -> TimeInterval? {
        switch model {
        case .off: nil
        case .haiku: 5
        case .sonnet: 9
        }
    }
    static func shouldPolish(text: String, model: DictationPolishModel) -> Bool {
        guard model != .off else { return false }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return text.utf16.count <= maximumCharacters
    }
    /// The helper's stdin: {text, model, app?}. The app is the frontmost app's name, one line, at most 64 characters,
    /// or left out. nil when polish is off.
    static func request(text: String, model: DictationPolishModel, app: String?, prewarmToken: String? = nil) -> Data? {
        guard model != .off else { return nil }
        var body: [String: String] = ["text": text, "model": model.rawValue]
        if let app = app?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty,
           app.count <= 64, !app.contains(where: \.isNewline) {
            body["app"] = app
        }
        // 0.5.329: the press's early polish process (DictationPolishPrewarm), only a token that is one.
        if let prewarmToken, DictationPolishPrewarm.isToken(prewarmToken) { body["prewarmToken"] = prewarmToken }
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
    enum Outcome: Equatable, Sendable {
        case applied(String)
        case unchanged
        case timeout
        case failed(String)
        /// 0.5.328 (server 6.79.1): the model did not polish, and the server said why (one of `skipReasons`).
        case skipped(String)
        /// The server's filler pass changed the text but the model did not run (`polished` true with a skip reason): the
        /// text is pasted, and the history does not call it Claude's polish.
        case fillersOnly(String, text: String)
        /// The log's outcome word: applied, unchanged, timeout, failed:<reason>, skipped:<code> or fillers_only:<code>.
        /// Never text.
        var logName: String {
            switch self {
            case .applied: "applied"
            case .unchanged: "unchanged"
            case .timeout: "timeout"
            case .failed(let reason): "failed:" + reason
            case .skipped(let code): "skipped:" + code
            case .fillersOnly(let code, _): "fillers_only:" + code
            }
        }
        /// What COS pastes: the polished (or filler-cleaned) text when there is one, otherwise what it heard.
        func text(heard: String) -> String {
            if case .applied(let polished) = self { return polished }
            if case .fillersOnly(_, let cleaned) = self { return cleaned }
            return heard
        }
    }
    /// Why the server's model did not polish (server 6.79.1 `polishSkipped`). Control checks the code again: the helper is
    /// one process away, and only these words may reach the timing line. 0.5.334 (server 6.84.0): link_guard, the
    /// server refused the model's answer for a link nobody said; it is not Claude's polish.
    static let skipReasons: Set<String> = ["daily_cap", "breaker_open", "too_long", "disabled", "failed", "clean", "link_guard"]
    /// The helper's answer, read. `ok` false (no server, an HTTP error, a bad answer, the helper's own timeout): the
    /// heard text. `polished` must be true: the server answers false with only the dictionary pass when Claude failed,
    /// which is not what the history would claim. An empty or runaway answer is never pasted.
    /// 0.5.328: `skipped`, the server's polishSkipped, read only when it is one of `skipReasons`. Polished false with one:
    /// skipped:<code>. Polished true with one: only the filler pass changed the text, fillers_only:<code> (pasted, under
    /// the same empty and growth guards). Without one, as before.
    static func choose(heard: String, ok: Bool, text: String?, polished: Bool?, reason: String?, skipped: String? = nil) -> Outcome {
        guard ok else {
            let why = reason.flatMap { $0.range(of: "^[a-z0-9_]{1,40}$", options: .regularExpression) != nil ? $0 : nil } ?? "refused"
            return why == "timeout" ? .timeout : .failed(why)
        }
        let skip = skipped.flatMap { skipReasons.contains($0) ? $0 : nil }
        guard polished == true else { return skip.map { .skipped($0) } ?? .failed("not_polished") }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failed("empty") }
        guard Double(text.count) <= Double(heard.count) * maximumGrowth + Double(growthAllowance) else { return .failed("grew") }
        if let skip { return text == heard ? .skipped(skip) : .fillersOnly(skip, text: text) }
        return text == heard ? .unchanged : .applied(text)
    }
    /// Settings' one line under AI polish.
    static func settingNote(_ model: DictationPolishModel) -> String {
        guard let budget = budget(for: model) else {
            return "Off: COS pastes what it heard. Haiku or Sonnet sends each dictation to Claude to clean up first."
        }
        return "Claude cleans filler, punctuation and dictionary spellings before COS pastes. It does not reliably fix misheard words. Uses your Claude plan. If it takes longer than \(Int(budget)) seconds, COS pastes what it heard."
    }
}

/// One AI polish: what it answered and its numbers for the timing line. 0.5.331: the caller writes them, since a
/// paste-first dictation's line outlives the next press (which starts a line of its own).
struct DictationPolishRun: Equatable, Sendable {
    let outcome: DictationPolish.Outcome
    let model: DictationPolishModel
    var ms = 0
    var prewarm: String? = nil
    var prewarmMs: Int? = nil
    /// 0.5.335 (server 6.85.0): whether the server gave the model the person's polish instructions, and their 8-hex hash
    /// (DictationPolishInstructions.used). Never the words.
    var customInstructions = false
    var instructionsHash: String? = nil
}

// MARK: - Your polish instructions (0.5.335, server 6.85.0)
//
// Miles, 2026-10-21 15:15: "I want the ability to change that polishing prompt ... make available to our users as well
// ... a custom AI polish. Like we still want to keep all of our kind of general rules, but this would allow them to
// provide further steer." The server keeps one setting (GET/PUT/DELETE /api/dictation/polish/instructions) and layers it
// AFTER its built-in rules, which keep precedence; GET /api/dictation/polish/rules shows those rules read-only. The box
// lives in Settings, Dictation, under AI polish, only on a server that advertises
// capabilities.dictationCleanup.customInstructions. The words go to the server through the helper's stdin, never argv,
// and never into a log; the timing line carries true or false and the server's hash.
enum DictationPolishInstructions {
    /// The server's cap (6.85.0 CUSTOM_INSTRUCTIONS_MAX_CHARS), a JavaScript string length: UTF-16 units, after trimming.
    static let maximumCharacters = 1_000
    /// The helper's stdin bound for a save: 1,000 characters at up to 4 UTF-8 bytes each, the JSON around them, and room
    /// for whitespace the server trims (it refuses more than 8,000 raw characters itself).
    static let inputLimit = 40_000
    /// Three short examples, shown in the empty box. Never saved: an empty box is off.
    static let placeholder = "Use Oxford commas.\nWrite product names as Bottle POS and IT Retail.\nIn Slack, keep it casual and skip the closing period."
    static let title = "Your polish instructions"
    /// The line under the box. Plain copy: no em dash, no arrow.
    static let note = "Extra direction for AI polish, used after COS's built-in rules. The built-in rules still win: your instructions never change what you meant, and never change links, paths, numbers or names you said. Used for Mac and glasses dictation, not meeting transcripts."
    static let offNote = "Mac dictation uses these when AI polish is on. Glasses dictation uses them whenever it polishes."

    /// What the server counts: the trimmed text's UTF-16 length.
    static func length(_ draft: String) -> Int { draft.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count }
    static func isOver(_ draft: String) -> Bool { length(draft) > maximumCharacters }
    /// "120 of 1,000 characters", or how many to cut.
    static func counter(_ draft: String) -> String {
        let n = length(draft)
        let over = n - maximumCharacters
        return over > 0 ? "\(grouped(n)) of \(grouped(maximumCharacters)) characters. Remove \(grouped(over)) to save."
            : "\(grouped(n)) of \(grouped(maximumCharacters)) characters"
    }
    private static func grouped(_ n: Int) -> String {
        let digits = String(n)
        guard digits.count > 3 else { return digits }
        return String(digits.dropLast(3)) + "," + String(digits.suffix(3))
    }
    /// Save: something changed, it fits, and the box is not saving already. Saving an empty box is Clear's job.
    static func canSave(draft: String, saved: String, busy: Bool) -> Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !busy && !trimmed.isEmpty && !isOver(draft) && trimmed != saved
    }
    /// Clear: there is something saved, or something typed.
    static func canClear(draft: String, saved: String, busy: Bool) -> Bool {
        !busy && (!saved.isEmpty || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    /// Shown only when the server says it has the setting. An older server omits the capability: no box at all.
    static func visible(available: Bool?) -> Bool { available == true }

    /// The helper's stdin for one operation. nil for an operation or a text the helper would refuse.
    static func request(_ operation: String, text: String? = nil) -> Data? {
        let object: [String: Any]
        switch operation {
        case "get", "clear", "rules":
            guard text == nil else { return nil }
            object = ["operation": operation]
        case "set":
            guard let text, !isOver(text), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            object = ["operation": "set", "customInstructions": text]
        default:
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), data.count <= inputLimit else { return nil }
        return data
    }

    /// What one helper answer says about the setting. `available` false: hide the box. The server's text is trusted for
    /// length only up to its own cap; anything longer reads as nothing saved.
    struct Saved: Equatable, Sendable {
        var available: Bool
        var text: String
        var instructionsHash: String?
    }
    static func saved(available: Bool?, text: String?, hash: String?) -> Saved {
        guard available == true else { return Saved(available: false, text: "", instructionsHash: nil) }
        let value = text ?? ""
        let fits = value.utf16.count <= maximumCharacters
        return Saved(available: true, text: fits ? value : "", instructionsHash: fits ? used(flag: !value.isEmpty, hash: hash).hash : nil)
    }

    /// A finalize answer's `customInstructions` and `instructionsHash`, read for the timing line: a JSON true and 8 hex
    /// characters only. Anything else is false and no hash.
    static func used(flag: Bool?, hash: String?) -> (on: Bool, hash: String?) {
        guard flag == true else { return (false, nil) }
        let valid = hash.flatMap { $0.range(of: "^[0-9a-f]{8}$", options: .regularExpression) != nil ? $0 : nil }
        return (true, valid)
    }

    /// The disclosure's heading: which built-in rules the server runs.
    static func rulesHeading(version: String?, rolledBack: Bool?) -> String {
        guard let version, version.range(of: "^v[0-9]{1,2}$", options: .regularExpression) != nil else { return "Built-in rules" }
        return rolledBack == true ? "Built-in rules (\(version), rolled back)" : "Built-in rules (\(version))"
    }
}

extension DictationTiming {
    /// The polish model, outcome word and milliseconds, and what became of the press's early process.
    mutating func includePolish(_ run: DictationPolishRun?) {
        guard let run else { return }
        polishMs = run.ms; polishModel = run.model.rawValue; polishOutcome = run.outcome.logName
        polishPrewarm = run.prewarm
        if let ms = run.prewarmMs { prewarmMs = ms }
        polishCustom = run.customInstructions
        polishInstructionsHash = run.customInstructions ? run.instructionsHash : nil
    }
    /// 0.5.331: what became of Claude's version, how long the swap took, and its route.
    mutating func settle(_ result: DictationPolishSwap.Result, ms: Int?, route: DictationReplace.Route?, why: DictationPolishSwap.Unmeasurable? = nil) {
        swapOutcome = result.logName; swapMs = ms; swapRoute = route.map(DictationPolishSwap.routeName)
        swapWhy = why?.rawValue
    }
}

// MARK: - Paste first, polish in place (0.5.331)
//
// Miles, 2026-10-20 07:49: "build paste-then-swap with those rules". Measured on his Mac (17 dictations that morning):
// after the key release, the tail took 0.32 s, transcription about 0.85 s, AI polish 2.2 to 3.8 s even warm, the paste
// 0.1 s. Polish was two thirds of the wait. Now the heard text is typed at once and Claude's version replaces it in the
// same spot when it is ready, only where COS can prove the spot still holds exactly what it typed. The focus rules are
// Miles's: the Accessibility route edits the field itself, wherever the person has gone, and puts their caret back; the
// paste route swaps only where the person already is, and never brings an app forward. Anything short of proof leaves
// the typed text alone and keeps Claude's version in Activity, Dictation, with Apply polished.

/// The pure half of paste first, polish in place. The app measures, asks these and acts (DictationInsertion.replace with
/// `automatic`, MacDictationStore.deliverThenPolish).
enum DictationPolishSwap {
    /// Settings, Dictation: "Paste right away, then polish in place", under AI polish. On unless turned off.
    static let defaultsKey = "dictation.pasteThenPolish"
    static func stored(_ value: Any?) -> Bool { (value as? Bool) ?? true }
    /// The person typed in the field this recently: wait for a quiet moment, at most the polish budget.
    static let quietMilliseconds = 600
    static let quietPollMilliseconds = 100
    /// A delivery waits at most this long for a swap that is editing a field right now.
    static let deliveryWaitMilliseconds = 2_000
    /// The pill's one line, only when a swap was skipped.
    static let skippedNotice = "POLISHED VERSION IN ACTIVITY"

    enum Sequence: String, Sendable {
        /// Today's order (and the toggle off): polish, then one delivery.
        case polishThenDeliver
        /// Type what was heard now; polish in parallel; swap it in place.
        case deliverThenPolish
    }
    /// Paste first only with the toggle on, a polish that will run, and a dictation that is typed (an interrupted one is
    /// copied, never typed, so it is polished first as before).
    /// 0.5.332 (Google Slides in Comet): and only where the swap could ever be proved. A target COS cannot measure
    /// (`unmeasurable`) gets the 0.5.330 order for this dictation: wait for polish, then paste once.
    static func sequence(pasteFirst: Bool, polishes: Bool, copyOnly: Bool, unmeasurable: Unmeasurable? = nil) -> Sequence {
        guard pasteFirst, polishes, !copyOnly else { return .polishThenDeliver }
        if unmeasurable != nil { return .polishThenDeliver }
        return .deliverThenPolish
    }
    /// 0.5.332: why the target can never prove a swap, read before delivery. A canvas web editor (Slides, Docs, Sheets)
    /// takes ⌘V with nothing to measure; any other field whose counts cannot be read cannot locate the span either.
    enum Unmeasurable: String, Sendable, CaseIterable { case canvasEditor, unreadableField }
    static func unmeasurable(canvas: Bool, baselineReadable: Bool) -> Unmeasurable? {
        if canvas { return .canvasEditor }
        return baselineReadable ? nil : .unreadableField
    }

    /// Why Claude's version was not swapped in. Codes only; they go on the timing line.
    /// 0.5.332: `keysHeld` (a modifier still down at the ⌘V) is its own reason; 0.5.331 read it as notFocused.
    enum Skip: String, Sendable, CaseIterable {
        case notTyped, terminal, appGone, fieldGone, textMoved, notFrontmost, ownWindowKey, notFocused, selectionUnproven,
             noChange, typing, busy, unverified, dictationOff, copyOnly, keysHeld
    }
    /// 0.5.332: `swappedUnconfirmed` (the ⌘V landed by count, the text could not be read back), `mismatch` (after the
    /// ⌘V the field did not hold the count it should), `unmeasurable` (polished first: nothing there could prove a swap).
    enum Result: Equatable, Sendable {
        case swapped, skipped(Skip), off, identical, notPolished, swappedUnconfirmed, mismatch, unmeasurable
        var logName: String {
            switch self {
            case .swapped: "swapped"
            case .skipped(let why): "skipped:" + why.rawValue
            case .off: "off"
            case .identical: "identical"
            case .notPolished: "notPolished"
            case .swappedUnconfirmed: "swappedUnconfirmed"
            case .mismatch: "mismatch"
            case .unmeasurable: "unmeasurable"
            }
        }
        /// Claude's version is (by measurement) in the field: the record reads it and the learner starts from it.
        var swappedIn: Bool { self == .swapped || self == .swappedUnconfirmed }
    }
    /// A dictation that was polished before its one delivery: off (the toggle), copy-only, unmeasurable, or not polished.
    static func unswapped(pasteFirst: Bool, polished: Bool, copyOnly: Bool, unmeasurable: Bool = false) -> Result {
        guard polished else { return .notPolished }
        if copyOnly, pasteFirst { return .skipped(.copyOnly) }
        if unmeasurable, pasteFirst { return .unmeasurable }
        return .off
    }

    enum Want: Equatable, Sendable { case swap(String), identical, notPolished }
    /// Only Claude's applied polish is swapped in: a failure, a timeout, a skip, the filler pass alone or no change
    /// leaves what was typed. `final` is the polished text after lists and the field's spellings, as it would be typed.
    static func want(outcome: DictationPolish.Outcome?, typed: String, final: String?) -> Want {
        guard case .applied? = outcome, let final else { return .notPolished }
        return final == typed ? .identical : .swap(final)
    }
    /// Claude's version as delivery would have typed it: spoken lists, then the field's own spellings (0.5.323), the
    /// same rules and order as before the paste.
    static func final(_ polished: String, formatLists: Bool, terms: [DictationFieldContext.Term],
                      known: (String) -> Bool) -> (text: String, fixes: [DictationFieldContext.Fix]) {
        let listed = formatLists ? DictationListFormat.format(polished) : polished
        guard !terms.isEmpty else { return (listed, []) }
        return DictationFieldContext.corrected(listed, terms: terms, known: known)
    }

    enum Step: Equatable, Sendable { case go, wait, skip(Skip) }
    /// Before the swap, polled every `quietPollMilliseconds`. Nothing to swap where nothing was measured as typed, in a
    /// terminal, or once the app is gone. A field the person typed in under 600 ms ago (its measured count or caret
    /// moved, or a key went down while it had the keyboard), or a newer delivery or Fix a word on this dictation, waits
    /// for a quiet moment, at most `budgetMs`, then skips.
    static func ready(inserted: Bool, measured: Bool, enabled: Bool, terminal: Bool, appRunning: Bool, busy: Bool,
                      sinceFieldChangeMs: Int?, sinceKeyMs: Int?, waitedMs: Int, budgetMs: Int) -> Step {
        guard inserted, measured else { return .skip(.notTyped) }
        guard enabled else { return .skip(.dictationOff) }
        if terminal { return .skip(.terminal) }
        guard appRunning else { return .skip(.appGone) }
        let typing = (sinceFieldChangeMs.map { $0 < quietMilliseconds } ?? false) || (sinceKeyMs.map { $0 < quietMilliseconds } ?? false)
        if !typing, !busy { return .go }
        if waitedMs >= budgetMs { return .skip(busy ? .busy : .typing) }
        return .wait
    }
    /// Replace's plan, read for an automatic swap: only the whole dictation, exactly where COS typed it or found once
    /// within the window (text typed above it moved it). Only the misheard words found means the person edited it: skip.
    static func placed(_ plan: DictationReplace.Plan) -> Skip? {
        switch plan {
        case .edit(_, dictationAt: .some): nil
        case .edit(_, dictationAt: nil): .textMoved
        case .copy(let reason): skip(for: reason)
        }
    }
    static func skip(for reason: DictationReplace.Reason) -> Skip {
        switch reason {
        case .notMeasured: .notTyped
        case .terminal: .terminal
        case .appGone: .appGone
        case .fieldGone: .fieldGone
        case .textMoved: .textMoved
        case .notFocused: .notFocused
        case .selectionUnproven: .selectionUnproven
        case .noChange: .noChange
        }
    }
    /// The focus rules at swap time. The Accessibility route edits the original element itself, so it may swap while
    /// the person is in another field or app. The paste route (⌘V lands wherever the keyboard is) swaps only when the
    /// target app is ALREADY frontmost, no COS window holds the keyboard, and the focused element is the target.
    static func gate(route: DictationReplace.Route, frontmost: Bool, focusedIsTarget: Bool, ownWindowKey: Bool) -> Skip? {
        guard route == .paste else { return nil }
        if !frontmost { return .notFrontmost }
        if ownWindowKey { return .ownWindowKey }
        if !focusedIsTarget { return .notFocused }
        return nil
    }
    /// An automatic swap never activates an app, never moves a COS window and never moves the person's focus. Fix a word
    /// and Apply polished, which the person asked for, may.
    static func mayActivate(automatic: Bool) -> Bool { !automatic }

    // 0.5.332 paste-route safety (Miles 2026-10-20 09:50, Claude desktop: the proof passed, the ⌘V went out and the field
    // read 37 characters where 154 were due). Miles's rule: an automatic swap never leaves the wrong text.

    /// On the paste route an automatic swap replaces the WHOLE dictation, never the smallest word change, so the worst a
    /// ⌘V that lands somewhere unexpected can leave is the whole polished dictation, never a fragment of it. The
    /// Accessibility route keeps the smallest edit (it measures before it trusts).
    static func pasteEdit(_ edit: DictationReplace.Edit, route: DictationReplace.Route, dictationAt: Int?, current: String,
                          corrected: String) -> DictationReplace.Edit {
        guard route == .paste, let at = dictationAt else { return edit }
        return DictationReplace.Edit(location: at, length: current.utf16.count, original: current, replacement: corrected)
    }
    /// Immediately before the ⌘V (after any wait for held keys), the proof again: the field's count is what the plan read
    /// and the proof measured, the selection is still exactly the span and still reads as it, and no key went down
    /// (Return included) in the last `quietMilliseconds`. Anything else skips, and nothing is pasted.
    static func reproof(planCount: Int?, proofCount: Int?, now: DictationFieldSnapshot, selectedText: String?,
                        edit: DictationReplace.Edit, sinceKeyMs: Int) -> Skip? {
        guard let planCount, let proofCount, let count = now.characters else { return .fieldGone }
        guard count == proofCount, count == planCount else { return .textMoved }
        guard now.location == edit.location, now.length == edit.length, selectedText == edit.original else { return .selectionUnproven }
        if sinceKeyMs < quietMilliseconds { return .typing }
        return nil
    }
    enum Landing: Equatable, Sendable { case swapped, unconfirmed, mismatch, pending }
    /// After the ⌘V, polled: the field must hold the count it had at the proof, less the span, plus the polished text.
    /// Read back as the polished text: swapped. The count right and the text unreadable: swapped (unconfirmed), and for a
    /// same-length swap only with the caret after the new text (the count alone cannot move). Anything else at the last
    /// poll is a mismatch; before it, keep waiting (an app may take the paste late). Never a second paste.
    static func landing(proofCount: Int, after: DictationFieldSnapshot, edit: DictationReplace.Edit, readback: String?, finalPoll: Bool) -> Landing {
        let newLength = edit.replacement.utf16.count
        if after.characters == proofCount - edit.length + newLength {
            if readback == edit.replacement { return .swapped }
            let caretAfter = after.location == edit.location + newLength && after.length == 0
            if readback == nil, newLength != edit.length || caretAfter { return .unconfirmed }
        }
        return finalPoll ? .mismatch : .pending
    }
    /// Why the paste route's ⌘V was not sent, as the swap's skip: held keys are their own reason.
    static func skip(forPaste refusal: DictationInsertPolicy.Refusal) -> Skip { refusal == .keysHeld ? .keysHeld : .notFocused }
    /// The pill after a mismatch, one line, the app's own name.
    static func mismatchNotice(app: String) -> String { "Check \(app): COS's polish swap may not have landed cleanly" }
    /// Where the person's caret or selection goes after the edit: unchanged before it, shifted by the length change
    /// after it (the usual case: the caret at the end of the dictation), else just after the new words.
    static func shifted(location: Int, length: Int, edit: DictationReplace.Edit) -> (location: Int, length: Int) {
        let end = edit.location + edit.length, newLength = edit.replacement.utf16.count
        if location >= end { return (location + newLength - edit.length, length) }
        if location + length <= edit.location { return (location, length) }
        return (edit.location + newLength, 0)
    }
    /// What Learn from my edits watches once the swap settles: the polished text where it landed after a swap (so COS's
    /// own swap is never read as the person's edit), else what was typed where it was typed.
    static func watch(span: DictationInsertedSpan, typed: String, polished: String, result: Result, swappedAt: Int?) -> (span: DictationInsertedSpan, text: String) {
        guard result.swappedIn, let at = swappedAt else { return (span, typed) }
        return (DictationInsertedSpan(pid: span.pid, location: at, length: polished.utf16.count), polished)
    }
    /// 0.5.332: after a mismatch nobody knows what the field holds, so Learn from my edits does not watch it.
    static func watches(_ result: Result) -> Bool { result != .mismatch }
    /// Claude's version waits in Activity, Dictation after any skip of a typed dictation, and after a mismatch (with what
    /// was heard, to check against).
    static func keepsPolished(_ result: Result) -> Bool {
        if result == .mismatch { return true }
        guard case .skipped(let why) = result else { return false }
        return why != .copyOnly
    }
    /// Apply polished only after a skip: COS never pastes again over a swap that may have landed (a mismatch).
    static func offersApply(_ result: Result) -> Bool { result != .mismatch && keepsPolished(result) }
    /// The pill says one short line only when a skip or a mismatch happened; nothing when the swap succeeded (confirmed or
    /// not) or there was nothing to do.
    static func notice(_ result: Result, app: String) -> String? {
        if result == .mismatch { return mismatchNotice(app: app) }
        return keepsPolished(result) ? skippedNotice : nil
    }
    static func routeName(_ route: DictationReplace.Route) -> String { route == .accessibility ? "accessibility" : "paste" }
    static func settingNote(_ model: DictationPolishModel) -> String {
        model == .off ? "Works with AI polish on."
            : "COS types what it heard right away. When Claude's version is ready, COS swaps it in at the same spot. If you moved on or changed the text, COS leaves it and keeps the polished version in Activity, Dictation."
    }
}

/// Claude's version of a dictation whose swap was skipped, for Apply polished. Memory only.
struct DictationPendingPolish: Equatable, Sendable {
    let text: String
    let heard: String
    let model: DictationPolishModel
    /// 0.5.332: false after a mismatch. The row shows what was heard and Claude's version, with Copy, never Apply.
    var applies = true
}

/// After COS types a dictation, it watches that one field until focus leaves it (three minutes at most) and learns a
/// word or two the person changed into something that sounds like it ("joule 360" → "Jewel360"). Pure, so every rule is
/// tested and mutated; the app measures, calls these and acts.
enum DictationEditLearning {
    static let watchSeconds: TimeInterval = 180
    static let maximumReads = 20
    static let debounceSeconds: TimeInterval = 1.5
    static let pollMilliseconds = 500
    static let maximumWords = 3
    /// 0.5.323: below the sound-alike threshold, a spelling the field also has outside the dictation still counts down
    /// to this score, so an unrelated rewrite never does.
    static let contextFloor = 0.6

    enum Eligibility: Equatable, Sendable {
        /// Watch and learn.
        case learn
        /// Watch and log only what was readable: Electron editors, and Chromium editors where the Accessibility set did
        /// nothing at delivery. Never learns until a probe has proved the field.
        case probe
        case skip(String)
    }
    /// Native apps first (Miles 13:31). `chromium` is any Chromium-family app; a browser's plain field is the one whose
    /// Accessibility set moved it at delivery (`setterWorked`). Terminals never: the AX text is scrollback.
    /// 0.5.338: an app in `proven` learns whatever its engine; one in `notYet` is only measured.
    static func eligibility(mode: DictationLearnMode, secure: Bool, terminal: Bool, electron: Bool, chromium: Bool, setterWorked: Bool,
                            bundle: String? = nil) -> Eligibility {
        if mode == .off { return .skip("off") }
        if secure { return .skip("secure") }
        if terminal { return .skip("terminal") }
        if let bundle, proven[bundle] != nil { return .learn }
        if let bundle, notYet.contains(where: { $0.bundle == bundle }) { return .probe }
        if electron { return .probe }
        if chromium, !setterWorked { return .probe }
        return .learn
    }

    enum Stop: String, Sendable { case secure, appGone, cap, reads, focusLeft, emptied, unreadable, cleared }
    /// Why the watch ends now, or nil to keep watching. Secure input is checked first, on every poll.
    /// 0.5.338 `cleared`: Chromium counts an empty contenteditable as one character (its newline), so a sent message in
    /// Claude never read as `emptied`; a field down to one character under a longer dictation was sent or cleared.
    static func stop(elapsed: TimeInterval, reads: Int, appRunning: Bool, secure: Bool, focused: Bool, fieldCharacters: Int?,
                     dictationLength: Int = 0) -> Stop? {
        if secure { return .secure }
        if !appRunning { return .appGone }
        if elapsed >= watchSeconds { return .cap }
        if reads >= maximumReads { return .reads }
        if !focused { return .focusLeft }
        guard let fieldCharacters else { return .unreadable }
        if fieldCharacters == 0 { return .emptied }
        if fieldCharacters <= 1, dictationLength > 1 { return .cleared }
        return nil
    }
    /// How much to read so the window covers the same text as the baseline: its length plus what the field gained.
    static func readLength(baselineLength: Int, baselineCharacters: Int, currentCharacters: Int, start: Int) -> Int {
        max(0, min(currentCharacters - start, baselineLength + currentCharacters - baselineCharacters))
    }

    enum Track: Equatable, Sendable {
        case unchanged
        /// The change was outside the dictation; it now sits at `start` with `length` (window units).
        case moved(start: Int, length: Int)
        /// The change was inside it, relative to the dictation's own start.
        case inside(DictationReplace.Edit, length: Int)
        /// The change crossed the dictation's edge: stop watching.
        case lost
    }
    /// The baseline window against the one read now. `start` and `length` place the dictation in the window.
    static func track(baseline: String, current: String, start: Int, length: Int) -> Track {
        guard let edit = DictationReplace.wordEdit(from: baseline, to: current) else { return .unchanged }
        let delta = edit.replacement.utf16.count - edit.length, end = start + length
        if edit.location + edit.length <= start, edit.length > 0 || edit.location <= start { return .moved(start: start + delta, length: length) }
        if edit.location >= end { return .moved(start: start, length: length) }
        if edit.location >= start, edit.location + edit.length <= end {
            let relative = DictationReplace.Edit(location: edit.location - start, length: edit.length, original: edit.original, replacement: edit.replacement)
            return .inside(relative, length: length + delta)
        }
        return .lost
    }

    struct Candidate: Equatable, Sendable {
        let heard: String
        let written: String
        /// 0.5.323: the written form is also in the same field outside the dictation.
        var evidence: DictationLearnEvidence? = nil
    }
    /// The pair to learn from one edit inside the dictation, or nil. A re-spelling of one to three words that sounds or
    /// is spelled like what was heard, never a rewording, a punctuation fix, a sentence-start capital, or a swap between
    /// two plain English words ("their" → "there"). `known` is the system spell checker; `learned` is the dictionary.
    /// `outside` is the field's text around the dictation (0.5.323, Miles 2026-10-17: a prompt he dropped in, then a
    /// dictated word fixed to a spelling that prompt already has). That evidence lets a spelling below the sound-alike
    /// threshold count, down to `contextFloor`, when it is not plain English and the heard side is not one plain word.
    static func candidate(_ edit: DictationReplace.Edit, known: (String) -> Bool, learned: (String, String) -> Bool,
                          outside: [String] = []) -> Candidate? {
        let edge = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines)
        let heard = edit.original.trimmingCharacters(in: edge), written = writtenSide(edit.replacement)
        guard !heard.isEmpty, !written.isEmpty, heard != written, !(heard + written).contains(where: \.isNewline) else { return nil }
        let heardWords = heard.split(whereSeparator: \.isWhitespace).map(String.init), writtenWords = written.split(whereSeparator: \.isWhitespace).map(String.init)
        guard (1...maximumWords).contains(heardWords.count), (1...maximumWords).contains(writtenWords.count) else { return nil }
        let evidence = evidence(written: written, outside: outside)
        if DictationFixGuess.normalized(heard) == DictationFixGuess.normalized(written) {
            // Only a change of capitals counts ("ios" → "iOS", "gina" → "Gina"), and not a sentence's first capital.
            guard heard.lowercased() == written.lowercased() else { return nil }
            let innerCapital = written.dropFirst().contains(where: \.isUppercase)
            guard innerCapital || !heardWords.allSatisfy(known) else { return nil }
        } else {
            // 0.5.338 (plan, 2026-10-22): the written side is a name or a term, never only plain English ("teh" to "the"
            // is a typo fix). Before, this held only when the heard side was plain English too.
            if writtenWords.allSatisfy(known) { return nil }
            let score = DictationFixGuess.score(heard: heard, term: written)
            if score < DictationFixGuess.threshold {
                guard evidence != nil else { return nil }
                guard score >= contextFloor else { return nil }
                guard heardWords.count > 1 || !heardWords.allSatisfy(known) else { return nil }
            }
        }
        guard !learned(heard, written) else { return nil }
        return Candidate(heard: heard, written: written, evidence: evidence)
    }

    /// 0.5.334 (Miles, 2026-10-21): what a link, handle or file name starts with. The written side keeps it ("/pricing",
    /// "@sam", "#launch", "~/notes", ".env", "\\share"); trimming it learned "forward slash pricing" as "pricing".
    static let writtenLeadKeep: Set<Character> = ["/", "\\", "@", "#", "~", "."]
    /// The written side of an edit: other leading punctuation, symbols and spaces go (a quote or bracket the edit picked
    /// up), a leading `writtenLeadKeep` mark stays, and at the end only punctuation and spaces go ("C++" and "Jewel360™" stay).
    static func writtenSide(_ raw: String) -> String {
        let lead = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines)
        let tail = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        var s = Substring(raw)
        while let c = s.first, !writtenLeadKeep.contains(c), c.unicodeScalars.allSatisfy({ lead.contains($0) }) { s = s.dropFirst() }
        while let c = s.last, c.unicodeScalars.allSatisfy({ tail.contains($0) }) { s = s.dropLast() }
        return String(s)
    }

    /// The field's text outside the dictation in one read: before `start` and after `start + length` (UTF-16 units).
    static func outside(window: String, start: Int, length: Int) -> [String] {
        let ns = window as NSString
        let lower = min(max(0, start), ns.length), upper = min(ns.length, max(lower, start + max(0, length)))
        return [ns.substring(to: lower), ns.substring(from: upper)].filter { !$0.isEmpty }
    }
    /// The exact written form (case and all) in any of `outside`, on word boundaries: "Jewel360" in "Jewel360's site"
    /// counts, in "Jewel3600" it does not.
    static func evidence(written: String, outside: [String]) -> DictationLearnEvidence? {
        guard !written.isEmpty else { return nil }
        for text in outside {
            let ns = text as NSString
            var from = 0
            while from < ns.length {
                let found = ns.range(of: written, options: [.literal], range: NSRange(location: from, length: ns.length - from))
                guard found.location != NSNotFound else { break }
                func wordUnit(_ i: Int) -> Bool {
                    guard let scalar = Unicode.Scalar(ns.character(at: i)) else { return true }
                    return CharacterSet.alphanumerics.contains(scalar)
                }
                let before = found.location == 0 || !wordUnit(found.location - 1)
                let after = NSMaxRange(found) == ns.length || !wordUnit(NSMaxRange(found))
                if before && after { return .nearbyText }
                from = found.location + 1
            }
        }
        return nil
    }
    /// The edit changes words COS spelled from the field (DictationFieldContext), not words the engine heard: putting
    /// back what was heard, or fixing COS's spelling to another. Neither is a pair to learn, since its "heard" side is
    /// COS's own guess.
    static func undoesContextFix(_ candidate: Candidate, fixes: [DictationFieldContext.Fix]) -> Bool {
        let heard = DictationFixGuess.normalized(candidate.heard)
        return fixes.contains { fix in
            let spelled = DictationFixGuess.normalized(fix.written)
            return !spelled.isEmpty && heard.contains(spelled)
        }
    }

    // MARK: 0.5.338 Learn from my edits in every app (design: operations/personal/wk43_2026/DESIGN_learn_edits_everywhere_0_5_338.md)

    /// Apps whose watches proved real reads on Miles's Mac (log canary 2026-10-22: Claude desktop read the exact dictation
    /// back in 4 of 5 watches, and later reads matched the field). In this table an Electron or Chromium app learns.
    static let proven: [String: String] = ["com.anthropic.claudefordesktop": "Claude"]
    /// Apps Miles dictates into that have no canary yet: watched, logged, never learned. ChatGPT is here because its
    /// Chromium engine ships "Codex (Renderer).app", which the structure check misses, so it would read as native.
    static let notYet: [(bundle: String, name: String)] = [
        ("com.tinyspeck.slackmacgap", "Slack"), ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("com.openai.codex", "ChatGPT"), ("com.openai.chat", "ChatGPT"),
    ]
    /// Settings names the apps where learning is not available yet, from the same table the rule reads.
    static var notYetNames: [String] {
        var seen: Set<String> = [], names: [String] = []
        for row in notYet where seen.insert(row.name).inserted { names.append(row.name) }
        return names
    }
    static var settingNote: String {
        "When you fix a word COS just typed, in that same field, COS learns it: until you leave the field or send the message, three minutes at most. "
            + "It learns names and terms, never plain English words. Works in native apps and "
            + proven.values.sorted().joined(separator: ", ")
            + ". Not available yet in " + notYetNames.joined(separator: ", ")
            + ", or text boxes in Chrome and Comet: COS only measures there for now. Suggest only keeps them a week in Activity, Dictation for you to add. Never in terminals or password fields."
    }

    /// At most this many pairs from one watch: a third edit inside one dictation is a rewrite, not a mishearing.
    static let maximumLearnedPerWatch = 2
    static func allowsAnother(learned: Int) -> Bool { learned < maximumLearnedPerWatch }
    /// A field that keeps re-mounting is not one field any more.
    static let maximumRebinds = 8
    /// How far (points) a re-mounted field's edges may move and still be the field COS typed into.
    static let frameSlack: Double = 4

    /// What COS knows about a focused element without its text: attributes only.
    struct FieldIdentity: Equatable, Sendable {
        var pid: Int32
        var role: String?
        /// AXIdentifier, else AXDOMIdentifier. Empty counts as none.
        var identifier: String?
        var frame: CGRect?
    }
    enum Focus: Equatable, Sendable {
        case same
        /// Another element, the same field (re-mounted): read through the new one from now on.
        case rebound
        case left(String)
    }
    /// Whether the field COS watches still has the keyboard. `sameElement`: the focused element is the watched one (or
    /// sits in it). `sameWindow`: the new element's window is the watched one's.
    static func focus(frontmost: Bool, sameElement: Bool, watched: FieldIdentity?, now: FieldIdentity?, sameWindow: Bool, rebinds: Int) -> Focus {
        guard frontmost else { return .left("app") }
        if sameElement { return .same }
        guard let watched, let now else { return .left("none") }
        guard watched.pid == now.pid else { return .left("pid") }
        guard watched.role == now.role else { return .left("role") }
        if let a = watched.identifier, let b = now.identifier, !a.isEmpty, !b.isEmpty {
            guard a == b else { return .left("identifier") }
        } else {
            guard sameWindow else { return .left("window") }
            guard let f0 = watched.frame, let f1 = now.frame else { return .left("frame") }
            let left = abs(f0.minX - f1.minX) <= frameSlack, width = abs(f0.width - f1.width) <= frameSlack
            let edge = abs(f0.minY - f1.minY) <= frameSlack || abs(f0.maxY - f1.maxY) <= frameSlack
            guard left, width, edge else { return .left("frame") }
        }
        guard rebinds < maximumRebinds else { return .left("churn") }
        return .rebound
    }

    enum Follow: Equatable, Sendable {
        case unchanged
        case moved(start: Int, length: Int)
        case inside(DictationReplace.Edit, length: Int)
        /// The dictation was found again in the read (`start`, `length` in window units); `edit` is what changed inside it.
        case reanchored(start: Int, length: Int, edit: DictationReplace.Edit?)
        /// The field is blank: the message was sent, or the text deleted.
        case cleared
        case lost
    }
    /// `track`, then what `track` calls lost: a cleared field, an edit at the dictation's edge, or the dictation found again.
    static func follow(baseline: String, current: String, start: Int, length: Int) -> Follow {
        if current.allSatisfy({ $0.isWhitespace || $0.isNewline }), !baseline.allSatisfy({ $0.isWhitespace || $0.isNewline }) { return .cleared }
        switch track(baseline: baseline, current: current, start: start, length: length) {
        case .unchanged: return .unchanged
        case .moved(let s, let l): return .moved(start: s, length: l)
        case .inside(let edit, let l): return .inside(edit, length: l)
        case .lost: break
        }
        if let (edit, l) = insideByCharacters(baseline: baseline, current: current, start: start, length: length) { return .inside(edit, length: l) }
        let ns = baseline as NSString
        guard start >= 0, length > 0, start + length <= ns.length else { return .lost }
        let dictation = ns.substring(with: NSRange(location: start, length: length))
        guard let found = reanchor(dictation, in: current) else { return .lost }
        let now = (current as NSString).substring(with: NSRange(location: found.start, length: found.length))
        return .reanchored(start: found.start, length: found.length, edit: DictationReplace.wordEdit(from: dictation, to: now))
    }
    /// The changed characters sit inside the dictation even though the word diff crossed its edge (a word glued to the
    /// text before it): the edit, widened to whole words but never past the dictation, relative to its start.
    static func insideByCharacters(baseline: String, current: String, start: Int, length: Int) -> (DictationReplace.Edit, Int)? {
        let a = Array(baseline.utf16), b = Array(current.utf16)
        let end = start + length
        guard start >= 0, length > 0, end <= a.count else { return nil }
        var lead = 0
        while lead < a.count, lead < b.count, a[lead] == b[lead] { lead += 1 }
        var trail = 0
        while trail < a.count - lead, trail < b.count - lead, a[a.count - 1 - trail] == b[b.count - 1 - trail] { trail += 1 }
        var lowA = lead, highA = a.count - trail, highB = b.count - trail
        guard lowA < highA || lead < highB else { return nil }
        guard lowA >= start, highA <= end else { return nil }
        func word(_ unit: UInt16) -> Bool { Unicode.Scalar(unit).map { CharacterSet.alphanumerics.contains($0) } ?? true }
        while lowA > start, word(a[lowA - 1]) { lowA -= 1 }
        while highA < end, word(a[highA]) { highA += 1; highB += 1 }
        let lowB = lowA
        guard highB >= lowB, highB <= b.count else { return nil }
        let original = String(utf16CodeUnits: Array(a[lowA..<highA]), count: highA - lowA)
        let replacement = String(utf16CodeUnits: Array(b[lowB..<highB]), count: highB - lowB)
        let delta = (highB - lowB) - (highA - lowA)
        return (DictationReplace.Edit(location: lowA - start, length: highA - lowA, original: original, replacement: replacement), length + delta)
    }
    /// The dictation in `window` again: the exact text once; else, for four words or more, its first and last word runs
    /// (up to three words each), each once on word boundaries, in order, no wider than twice the dictation plus 16.
    static func reanchor(_ dictation: String, in window: String) -> (start: Int, length: Int)? {
        let ns = window as NSString, d = dictation as NSString
        guard d.length > 0 else { return nil }
        let exact = literal(dictation, in: ns, wordBounded: false)
        if exact.count == 1 { return (exact[0], d.length) }
        // Twice exactly is ambiguous; its word runs are then found twice too, so the anchors below refuse it.
        var words: [NSRange] = []
        d.enumerateSubstrings(in: NSRange(location: 0, length: d.length), options: [.byWords, .substringNotRequired]) { _, range, _, _ in words.append(range) }
        guard words.count >= 4 else { return nil }
        let k = min(3, words.count / 2)
        let head = d.substring(with: NSRange(location: 0, length: NSMaxRange(words[k - 1])))
        let tailStart = words[words.count - k].location
        let tail = d.substring(from: tailStart)
        let heads = literal(head, in: ns, wordBounded: true), tails = literal(tail, in: ns, wordBounded: true)
        guard heads.count == 1, tails.count == 1 else { return nil }
        let from = heads[0], to = tails[0] + (tail as NSString).length
        guard tails[0] >= from + (head as NSString).length, to - from <= 2 * d.length + 16 else { return nil }
        return (from, to - from)
    }
    private static func literal(_ needle: String, in haystack: NSString, wordBounded: Bool) -> [Int] {
        let n = (needle as NSString).length
        guard n > 0 else { return [] }
        func wordUnit(_ i: Int) -> Bool { Unicode.Scalar(haystack.character(at: i)).map { CharacterSet.alphanumerics.contains($0) } ?? true }
        var out: [Int] = [], from = 0
        while from < haystack.length {
            let found = haystack.range(of: needle, options: [.literal], range: NSRange(location: from, length: haystack.length - from))
            guard found.location != NSNotFound else { break }
            let ok = !wordBounded || ((found.location == 0 || !wordUnit(found.location - 1)) && (NSMaxRange(found) == haystack.length || !wordUnit(NSMaxRange(found))))
            if ok { out.append(found.location) }
            from = found.location + 1
        }
        return out
    }
}

/// Why a learned pair is more than a sound-alike (0.5.323). Shown under the suggestion in Activity, Dictation.
enum DictationLearnEvidence: String, Codable, Sendable {
    /// The same spelling is in the field outside the dictation: text the person typed, pasted or dropped there.
    case nearbyText
    var words: String {
        switch self {
        case .nearbyText: "Also in the text around your dictation"
        }
    }
}

/// Suggest only: what COS noticed, kept a week for review in a batch (Miles 13:31), and what it learned on its own, so
/// the Dictation tab can label it and Undo it. A dismissed or undone pair is not offered again for 30 days.
struct DictationSuggestion: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let heard: String
    let written: String
    let app: String
    let at: Date
    /// 0.5.323. A 0.5.318 file has no key, and a kind this build does not know reads as none.
    var evidence: DictationLearnEvidence? = nil

    init(id: UUID, heard: String, written: String, app: String, at: Date, evidence: DictationLearnEvidence? = nil) {
        self.id = id; self.heard = heard; self.written = written; self.app = app; self.at = at; self.evidence = evidence
    }
    private enum CodingKeys: String, CodingKey { case id, heard, written, app, at, evidence }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        heard = try c.decode(String.self, forKey: .heard)
        written = try c.decode(String.self, forKey: .written)
        app = try c.decode(String.self, forKey: .app)
        at = try c.decode(Date.self, forKey: .at)
        evidence = (try? c.decodeIfPresent(String.self, forKey: .evidence)).flatMap { $0 }.flatMap(DictationLearnEvidence.init(rawValue:))
    }
    /// The same pair again keeps the evidence an earlier sighting had.
    func keeping(_ earlier: DictationSuggestion?) -> DictationSuggestion {
        DictationSuggestion(id: id, heard: heard, written: written, app: app, at: at, evidence: evidence ?? earlier?.evidence)
    }
}

enum DictationSuggestions {
    static let keepDays = 7
    static let dismissDays = 30
    static let learnedDays = 30
    static let cap = 200
    struct State: Codable, Equatable, Sendable {
        var version = 1
        var suggestions: [DictationSuggestion] = []
        var learned: [DictationSuggestion] = []
        var dismissed: [String: Date] = [:]
    }
    static func key(_ heard: String, _ written: String) -> String { DictationFixGuess.normalized(heard) + "\u{2192}" + written.lowercased() }
    private static func fresh(_ date: Date, days: Int, now: Date) -> Bool { now.timeIntervalSince(date) < Double(days) * 86_400 }
    /// Suggestions older than a week go, learned rows and dismissals after 30 days; never more than `cap` of each.
    static func pruned(_ state: State, now: Date) -> State {
        var next = state
        next.suggestions = Array(state.suggestions.filter { fresh($0.at, days: keepDays, now: now) }.prefix(cap))
        next.learned = Array(state.learned.filter { fresh($0.at, days: learnedDays, now: now) }.prefix(cap))
        next.dismissed = state.dismissed.filter { fresh($0.value, days: dismissDays, now: now) }
        return next
    }
    /// Newest first; the same pair again replaces the old row. A pair dismissed in the last 30 days is not offered.
    static func suggesting(_ item: DictationSuggestion, in state: State, now: Date) -> State {
        var next = pruned(state, now: now)
        let k = key(item.heard, item.written)
        guard !isQuiet(item.heard, item.written, in: next, now: now) else { return next }
        let earlier = next.suggestions.first { key($0.heard, $0.written) == k }
        next.suggestions = [item.keeping(earlier)] + next.suggestions.filter { key($0.heard, $0.written) != k }
        return pruned(next, now: now)
    }
    /// Save automatically: the pair goes on the learned list (the dictionary holds the correction itself).
    static func learning(_ item: DictationSuggestion, in state: State, now: Date) -> State {
        var next = pruned(state, now: now)
        let k = key(item.heard, item.written)
        let earlier = next.learned.first { key($0.heard, $0.written) == k } ?? next.suggestions.first { key($0.heard, $0.written) == k }
        next.learned = [item.keeping(earlier)] + next.learned.filter { key($0.heard, $0.written) != k }
        next.suggestions = next.suggestions.filter { key($0.heard, $0.written) != k }
        return pruned(next, now: now)
    }
    /// Added to the dictionary from the review: off the suggestion list, onto the learned list.
    static func applying(_ ids: Set<UUID>, in state: State, now: Date) -> State {
        var next = state
        for item in state.suggestions where ids.contains(item.id) { next = learning(item, in: next, now: now) }
        return next
    }
    /// Dismissed, or an auto-saved one undone: gone, and not offered again for 30 days.
    static func dismissing(_ id: UUID, in state: State, now: Date) -> State {
        var next = state
        for item in state.suggestions + state.learned where item.id == id { next.dismissed[key(item.heard, item.written)] = now }
        next.suggestions.removeAll { $0.id == id }
        next.learned.removeAll { $0.id == id }
        return pruned(next, now: now)
    }
    /// A pair dismissed or undone in the last 30 days: neither suggested nor saved automatically.
    static func isQuiet(_ heard: String, _ written: String, in state: State, now: Date) -> Bool {
        state.dismissed[key(heard, written)].map { fresh($0, days: dismissDays, now: now) } ?? false
    }
    /// Undo on a learned row reverses the dictionary entry it made: the newest Recent correction with the same pair.
    static func recentID(for item: DictationSuggestion, in recent: [(id: String, heard: String, written: String)]) -> String? {
        recent.first { $0.heard == item.heard && $0.written == item.written }?.id
    }
    private static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }
    private static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    static func load(from url: URL, now: Date) -> State {
        guard let data = try? Data(contentsOf: url), let state = try? decoder().decode(State.self, from: data) else { return State() }
        return pruned(state, now: now)
    }
    /// Private like the history: a 0600 temp file in a 0700 folder, then rename(2). Default data protection (class C).
    static func save(_ state: State, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try encoder().encode(state)
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "COSDictation", code: 4, userInfo: [NSLocalizedDescriptionKey: "Dictation suggestions could not be saved."])
        }
        guard rename(temp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw NSError(domain: "COSDictation", code: 4, userInfo: [NSLocalizedDescriptionKey: "Dictation suggestions could not be saved."])
        }
    }
}

// MARK: - The text around a dictation (0.5.323)

/// 0.5.323 (Miles, 2026-10-17): the words already in the text box are context. Before COS types a dictation it reads a
/// bounded part of the focused field (AXStringForRange, never AXValue) and spells a misheard name or term the way the
/// field already has it: "Ukoma" becomes "Ukaoma" when the field holds "Ukaoma". The same read is evidence for Learn
/// from my edits. The text stays in memory on this Mac for that one dictation and its watch: never logged, never written
/// to disk, never sent to the server. Never a password field, secure input or a terminal (whose text is scrollback).
/// Pure, so every rule is tested and mutated; the app reads the field, calls these and types the result.
enum DictationFieldContext {
    /// The most COS reads, in UTF-16 units: up to `beforeLimit` before the caret, the rest after the selection.
    static let maximumCharacters = 4_000
    static let beforeLimit = 3_000
    /// Each Accessibility read gives up after this; all of them together must finish inside `readBudgetSeconds`, or
    /// the dictation is typed as heard.
    static let readTimeoutSeconds: Float = 0.15
    static let readBudgetSeconds: TimeInterval = 0.3
    /// The field's distinctive words kept for one dictation, most frequent first.
    static let maximumTerms = 64
    /// A dictation longer than this many words is typed as heard (the comparison grows with words times terms).
    static let maximumWords = 800
    /// A context word is two to forty characters.
    static let maximumTermLength = 40

    struct Piece: Equatable, Sendable {
        let location: Int
        let length: Int
    }
    enum Plan: Equatable, Sendable {
        case read(before: Piece, after: Piece)
        case skip(String)
    }
    /// What to read: the text before the caret and after the selection (selected text is about to be replaced), at most
    /// `maximumCharacters` in all. Nothing from a password field, secure input, a terminal, or a field COS cannot measure.
    static func plan(enabled: Bool, secure: Bool, terminal: Bool, fieldCharacters: Int?, location: Int?, length: Int?) -> Plan {
        if !enabled { return .skip("off") }
        if secure { return .skip("password field or secure input") }
        if terminal { return .skip("terminal scrollback") }
        guard let n = fieldCharacters, let location else { return .skip("unmeasured") }
        guard n > 0 else { return .skip("empty") }
        let caret = min(max(0, location), n), end = min(n, caret + max(0, length ?? 0))
        let before = min(caret, beforeLimit)
        let after = min(n - end, maximumCharacters - before)
        guard before + after > 0 else { return .skip("empty") }
        return .read(before: Piece(location: caret - before, length: before), after: Piece(location: end, length: after))
    }
    static func inBudget(elapsed: TimeInterval) -> Bool { elapsed <= readBudgetSeconds }

    /// What was read. A piece that does not reach the field's edge was cut mid-word, so its outer word is dropped.
    struct Read: Equatable, Sendable {
        var before = ""
        var after = ""
        var beforeCut = false
        var afterCut = false
    }
    struct Term: Equatable, Sendable {
        let text: String
        /// A capital inside a word ("iOS", "HubSpot") or letters with digits ("Jewel360"): spelled on purpose. A plain
        /// English word that was heard may become one of these (and of nothing else).
        let strong: Bool
    }
    /// The field's distinctive words: a capital inside the word, letters with digits, a capitalized word in mid-sentence
    /// or one the spell checker does not know, an acronym. Never a plain lowercase word, which is more often a typo
    /// than a term, nor anything with a slash, @, colon or underscore (paths, links, addresses, code).
    static func terms(in read: Read, known: (String) -> Bool) -> [Term] {
        var counts: [String: (count: Int, first: Int, strong: Bool)] = [:]
        var index = 0
        // A caret inside a word splits it: neither half is a word of the field.
        let midWord = (read.before.last.map { $0.isLetter || $0.isNumber } ?? false) && (read.after.first.map { $0.isLetter || $0.isNumber } ?? false)
        for (text, dropFirst, dropLast) in [(read.before, read.beforeCut, midWord), (read.after, midWord, read.afterCut)] {
            let words = tokens(text)
            for (i, word) in words.enumerated() {
                defer { index += 1 }
                if i == 0, dropFirst { continue }
                if i == words.count - 1, dropLast { continue }
                // The after piece follows the dictation, so its first word is read as a sentence start (the strict case).
                let startsSentence = i == 0 || words[i - 1].endsSentence || word.breakBefore
                guard let term = classify(word.trimmed, startsSentence: startsSentence, known: known) else { continue }
                if let seen = counts[term.text] { counts[term.text] = (seen.count + 1, seen.first, seen.strong) }
                else { counts[term.text] = (1, index, term.strong) }
            }
        }
        return counts.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.value.first < $1.value.first }
            .prefix(maximumTerms).map { Term(text: $0.key, strong: $0.value.strong) }
    }
    static func classify(_ raw: String, startsSentence: Bool, known: (String) -> Bool) -> Term? {
        // "Ukaoma's" is the word "Ukaoma".
        let word = raw.count > 3 && (raw.hasSuffix("'s") || raw.hasSuffix("\u{2019}s")) ? String(raw.dropLast(2)) : raw
        guard (2...maximumTermLength).contains(word.count) else { return nil }
        let inner: Set<Character> = ["-", "'", "\u{2019}", ".", "&", "+"]
        guard word.allSatisfy({ $0.isLetter || $0.isNumber || inner.contains($0) }) else { return nil }
        let letters = word.filter(\.isLetter).count, digits = word.filter(\.isNumber).count
        guard letters >= 1, let first = word.first else { return nil }
        let lower = word.contains(where: \.isLowercase)
        if lower, word.dropFirst().contains(where: \.isUppercase) { return Term(text: word, strong: true) }
        // "Jewel360", "4BIS"; not "3pm" or "2nd".
        if digits > 0, letters >= 2, first.isLetter || letters >= 3 { return Term(text: word, strong: true) }
        guard digits == 0 else { return nil }
        if !lower, (2...6).contains(letters), letters == word.count { return Term(text: word, strong: false) }  // COS, SBU
        guard first.isUppercase, lower, letters >= 3 else { return nil }
        if !startsSentence || !known(word) { return Term(text: word, strong: false) }
        return nil
    }

    struct Fix: Equatable, Sendable {
        let heard: String
        let written: String
    }
    /// What `deliver` typed after reading the field: the text, the fixes it made, and the field's text outside the
    /// dictation, for Learn from my edits. Memory only.
    struct Applied: Equatable, Sendable {
        let text: String
        let fixes: [Fix]
        let outside: [String]
        /// 0.5.331: the field's terms that respelled it, so AI polish's version (swapped in later) is respelled the same way.
        var terms: [Term] = []
    }
    /// The dictation with words the field already spells differently fixed. One to three words that score at the Fix a
    /// word threshold against a field term become that term, best match first, never overlapping, never across a line
    /// break, punctuation at either end kept. Guards, because a wrong fix is worse than none:
    /// - words the field already has exactly stay as they are;
    /// - plain English words become only a spelled-on-purpose term ("joule 360" to "Jewel360", "hub spot" to "HubSpot"),
    ///   and one plain word only when the letters are the same, so "cloud" never becomes "iCloud" nor "and" "Andy";
    /// - a change of capitals alone needs a spelled-on-purpose term or a word the spell checker does not know.
    static func corrected(_ text: String, terms: [Term], known: (String) -> Bool) -> (text: String, fixes: [Fix]) {
        let words = tokens(text)
        guard !terms.isEmpty, !words.isEmpty, words.count <= maximumWords else { return (text, []) }
        let exact = Set(terms.map(\.text))
        let keyed = terms.map { (term: $0, normal: DictationFixGuess.normalized($0.text), sound: DictationFixGuess.skeleton($0.text)) }
        var cache: [String: Bool] = [:]
        func plain(_ word: String) -> Bool {
            if let k = cache[word] { return k }
            let k = known(word); cache[word] = k; return k
        }
        var found: [(start: Int, end: Int, score: Double, term: String, heard: String)] = []
        for start in words.indices {
            for width in 1...DictationFixGuess.maximumWords where start + width <= words.count {
                let end = start + width - 1
                // One span never crosses a line break or a mark between words ("joule, 360" stays two).
                if width > 1, words[end].breakBefore || words[end].leadMark || words[end - 1].trailMark { break }
                let heard = words[start...end].map(\.trimmed).joined(separator: " ")
                let h = DictationFixGuess.normalized(heard)
                guard h.count >= 3, !exact.contains(heard) else { continue }
                let hs = DictationFixGuess.skeleton(heard)
                var allPlain: Bool?
                for key in keyed where !key.normal.isEmpty {
                    let same = key.normal == h
                    let score: Double
                    if same { score = 1 } else {
                        let spelled = DictationFixGuess.similarity(h, key.normal)
                        let sounded = hs.count >= 3 && key.sound.count >= 3 ? DictationFixGuess.similarity(hs, key.sound) * 0.95 : 0
                        score = max(spelled, sounded)
                        guard score >= DictationFixGuess.threshold else { continue }
                    }
                    if allPlain == nil { allPlain = words[start...end].allSatisfy { $0.trimmed.allSatisfy(\.isNumber) || plain($0.trimmed) } }
                    if allPlain == true {
                        guard key.term.strong else { continue }
                        guard width > 1 || same else { continue }
                    }
                    found.append((start, end, score, key.term.text, heard))
                }
            }
        }
        found.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.end - a.start != b.end - b.start { return a.end - a.start < b.end - b.start }
            return a.start < b.start
        }
        var taken = Set<Int>(), chosen: [(start: Int, end: Int, term: String, heard: String)] = []
        for f in found where (f.start...f.end).allSatisfy({ !taken.contains($0) }) {
            chosen.append((f.start, f.end, f.term, f.heard)); for i in f.start...f.end { taken.insert(i) }
        }
        guard !chosen.isEmpty else { return (text, []) }
        chosen.sort { $0.start < $1.start }
        // Built from slices of the original, in order, so an index always belongs to the string it reads.
        var out = "", cursor = text.startIndex, fixes: [Fix] = []
        let edge = CharacterSet.punctuationCharacters.union(.symbols)
        func isEdge(_ ch: Character) -> Bool { ch.unicodeScalars.allSatisfy { edge.contains($0) } }
        for c in chosen {
            let range = words[c.start].range.lowerBound..<words[c.end].range.upperBound
            guard range.lowerBound >= cursor else { continue }
            let phrase = Array(text[range])
            let lead = phrase.prefix(while: isEdge).count
            let trail = lead == phrase.count ? 0 : phrase.reversed().prefix(while: isEdge).count
            out += text[cursor..<range.lowerBound] + String(phrase.prefix(lead)) + c.term + String(phrase.suffix(trail))
            cursor = range.upperBound
            fixes.append(Fix(heard: c.heard, written: c.term))
        }
        return (out + text[cursor...], fixes)
    }

    struct Word {
        let range: Range<String.Index>
        let trimmed: String
        /// A line break, or a mark standing alone ("—"), sits between this word and the one before.
        let breakBefore: Bool
        /// Punctuation hugs the word's start or end ("(Jewel360", "joule,").
        let leadMark: Bool
        let trailMark: Bool
        let endsSentence: Bool
    }
    /// Words split on white space, each without the punctuation hugging it, where it sits, and what separates it from
    /// its neighbours.
    static func tokens(_ text: String) -> [Word] {
        var out: [Word] = []
        var start: String.Index?, sawBreak = false
        let edge = CharacterSet.punctuationCharacters.union(.symbols)
        func close(_ s: String.Index, _ e: String.Index) {
            let raw = String(text[s..<e])
            let trimmed = raw.trimmingCharacters(in: edge)
            let tail = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"')]}\u{201D}\u{2019}"))
            let ends = tail.last.map { ".!?:;".contains($0) } ?? false
            if !trimmed.isEmpty {
                out.append(Word(range: s..<e, trimmed: trimmed, breakBefore: sawBreak, leadMark: !raw.hasPrefix(trimmed),
                                trailMark: !raw.hasSuffix(trimmed), endsSentence: ends))
                sawBreak = false
            } else {
                sawBreak = true
                if ends, let last = out.popLast() {
                    out.append(Word(range: last.range, trimmed: last.trimmed, breakBefore: last.breakBefore, leadMark: last.leadMark,
                                    trailMark: true, endsSentence: true))
                }
            }
        }
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c.isWhitespace || c.isNewline {
                if let s = start { close(s, i); start = nil }
                if c.isNewline { sawBreak = true }
            } else if start == nil { start = i }
            i = text.index(after: i)
        }
        if let s = start { close(s, text.endIndex) }
        return out
    }
}

// MARK: - Dictionary suggestions from the server (0.5.323 seam, server 6.77.0)

/// The glasses server's transcript cleanup (server 6.77.0, unpublished when this was written) proposes dictionary
/// spellings with evidence. This is the seam only: the model the list decodes into and the capability that says the
/// server has it. Nothing in COS Control calls the server for these yet, and the helper's `dictionary-suggestions` verb
/// answers dormant without a request, until 6.77.0 is published and its routes are proven:
///   GET  /api/transcript-cleanup/suggestions?status=pending|all  200 {"protocol": 1, "suggestions": [Suggestion]}
///   POST /api/transcript-cleanup/suggestions/:id/accept   {} adds the spelling; {"correction": true} learns heard[0]
///   POST /api/transcript-cleanup/suggestions/:id/dismiss  {}
/// advertised by "transcriptCleanup": {"protocol": 1, "suggestions": 1} in GET /api/transcribe/capabilities.
struct DictationServerSuggestion: Decodable, Equatable, Identifiable, Sendable {
    struct Evidence: Decodable, Equatable, Sendable {
        let source: String
        let sessionId: String?
        let heard: String?
        let at: String?
        /// A file name, memory id or app name. Never transcript or screen text.
        let detail: String?
    }
    let id: String
    let written: String
    let heard: [String]
    let status: String
    let count: Int
    let inVocabulary: Bool
    let evidence: [Evidence]
}

enum DictationServerSuggestions {
    static let protocolVersion = 1
    /// `sug_` and 16 lowercase hex digits, the only id the helper will put in a path.
    static func validID(_ id: String) -> Bool {
        id.count == 20 && id.hasPrefix("sug_") && id.dropFirst(4).allSatisfy { "0123456789abcdef".contains($0) }
    }
    /// GET /api/transcribe/capabilities says this server lists suggestions. Absent on an older server.
    static func available(capabilities: Data) -> Bool {
        guard let body = try? JSONSerialization.jsonObject(with: capabilities) as? [String: Any],
              let cleanup = body["transcriptCleanup"] as? [String: Any] else { return false }
        return (cleanup["protocol"] as? Int) == protocolVersion && (cleanup["suggestions"] as? Int) == 1
    }
    /// The list answer: rows with a valid id and a spelling, pending first as the server sends them. A row that does
    /// not decode is dropped, not the list.
    static func list(_ body: Data) -> [DictationServerSuggestion] {
        struct Envelope: Decodable {
            let version: Int
            let suggestions: [Lenient]
            enum CodingKeys: String, CodingKey { case version = "protocol", suggestions }
        }
        struct Lenient: Decodable {
            let value: DictationServerSuggestion?
            init(from decoder: Decoder) throws { value = try? DictationServerSuggestion(from: decoder) }
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: body), envelope.version == protocolVersion else { return [] }
        return envelope.suggestions.compactMap(\.value).filter { validID($0.id) && !$0.written.isEmpty && $0.written.utf16.count <= 100 }
    }
}

/// While dictating: mute other apps (default), lower other audio, or leave it alone.
enum DictationQuietMode: String, CaseIterable, Sendable {
    case mute, lower, off
    static let `default` = DictationQuietMode.mute
    var title: String {
        switch self {
        case .mute: "Mute other apps"
        case .lower: "Lower other audio"
        case .off: "Off"
        }
    }
}

enum DictationQuiet {
    enum Plan: Equatable, Sendable {
        case leave(String)
        /// A global process tap, COS excluded, with muteBehavior .muted, removed when listening ends.
        case muteTap
        /// The default output device's volume scalar, saved first and put back after.
        case lowerVolume(to: Float)
    }
    static let loweredFraction: Float = 0.25
    /// Never during a Mac recording: muting would silence the meeting the person is listening to.
    static func plan(mode: DictationQuietMode, macRecording: Bool, tapPermitted: Bool, volume: Float?, volumeSettable: Bool) -> Plan {
        if macRecording { return .leave("a COS recording is capturing") }
        switch mode {
        case .off: return .leave("off")
        case .mute where tapPermitted: return .muteTap
        case .mute, .lower:
            guard let volume, volumeSettable else { return .leave("output volume not adjustable") }
            guard volume > 0.001 else { return .leave("already silent") }
            return .lowerVolume(to: volume * loweredFraction)
        }
    }
    /// The exact saved scalar goes back, unless the person moved the volume while dictating: theirs wins.
    static func restoreVolume(saved: Float, lowered: Float, current: Float?) -> Float? {
        guard let current else { return saved }
        return abs(current - lowered) < 0.02 ? saved : nil
    }
    /// Written before COS lowers the volume and removed after it restores it, so a quit or crash in between is undone
    /// on the next launch.
    struct Pending: Codable, Equatable, Sendable {
        let deviceUID: String
        let saved: Float
        let lowered: Float
    }
    static func launchRestore(_ pending: Pending?, current: Float?) -> Float? {
        guard let pending else { return nil }
        return restoreVolume(saved: pending.saved, lowered: pending.lowered, current: current)
    }
}

/// 0.5.315 (Miles, 2026-10-16 11:20: Spotify kept playing at full level while the log said "other apps muted"): 0.5.313
/// created the muting tap and nothing ever read it. The mute is now built the way Apple's tap sample uses a tap: the tap,
/// its UID, a private aggregate device listing it, an IOProc, and the aggregate's IO running. Muted means every step
/// succeeded; a failed step tears down what exists, in reverse, and COS lowers the volume instead.
enum DictationMuteTap {
    enum Step: String, CaseIterable, Sendable { case tap, tapUID, aggregate, ioProc, start }
    enum Teardown: String, Sendable { case stop, destroyIOProc, destroyAggregate, destroyTap }
    /// What exists right now. `tapUID` creates nothing, so it has no flag.
    struct Built: Equatable, Sendable {
        var tap = false, aggregate = false, ioProc = false, running = false
        var muting: Bool { tap && aggregate && ioProc && running }
        mutating func record(_ step: Step) {
            switch step {
            case .tap: tap = true
            case .tapUID: break
            case .aggregate: aggregate = true
            case .ioProc: ioProc = true
            case .start: running = true
            }
        }
    }
    struct Failure: Equatable, Sendable { let step: Step; let status: Int32 }
    /// Runs the steps in order and stops at the first one that does not return noErr (0); later steps never run.
    static func build(_ perform: (Step) -> Int32) -> (built: Built, failure: Failure?) {
        var built = Built()
        for step in Step.allCases {
            let status = perform(step)
            guard status == 0 else { return (built, Failure(step: step, status: status)) }
            built.record(step)
        }
        return (built, nil)
    }
    /// Strictly the reverse of the build: IO stops before its IOProc goes, the IOProc before its aggregate, the
    /// aggregate before the tap it lists. Nothing built, nothing to do, so a second end() is a no-op.
    static func teardown(_ built: Built) -> [Teardown] {
        var steps: [Teardown] = []
        if built.running { steps.append(.stop) }
        if built.ioProc { steps.append(.destroyIOProc) }
        if built.aggregate { steps.append(.destroyAggregate) }
        if built.tap { steps.append(.destroyTap) }
        return steps
    }
    /// The default output changed while muted (AirPods connected, a display took over): the aggregate is clocked by the
    /// old device, so the mute ends rather than rebuilding inside a device change. A notice for the same device keeps it.
    static func keepOnOutputChange(mutedOn: String, now: String?) -> Bool { now == mutedOn }
}

/// The mute's IOProc and what it saw, outside any actor. The HAL calls the IOProc on its real-time IO thread; a closure
/// formed inside the @MainActor quiet controller would inherit main-actor isolation and Swift 6 traps on entry (the
/// 0.5.305 and 0.5.313 crashes). It reads the tapped audio only to measure its peak, writes silence to the output, and
/// never waits: the meter's lock is only tried here, so a contended callback is simply not counted.
final class DictationMuteMeter: Sendable {
    struct Reading: Equatable, Sendable { var callbacks = 0; var peak: Float = 0 }
    private let state = OSAllocatedUnfairLock(initialState: Reading())
    func record(peak: Float) { _ = state.withLockIfAvailable { $0.callbacks += 1; $0.peak = max($0.peak, peak) } }
    func reading() -> Reading { state.withLock { $0 } }
}
enum DictationMuteIO {
    /// AudioDeviceIOBlock, but @Sendable: the type says it runs off every actor.
    typealias Block = @Sendable (UnsafePointer<AudioTimeStamp>, UnsafePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>,
                                 UnsafeMutablePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>) -> Void
    static func silence(_ meter: DictationMuteMeter) -> Block {
        { @Sendable _, input, _, output, _ in
            var peak: Float = 0
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                for index in 0..<Int(buffer.mDataByteSize) / MemoryLayout<Float>.size { peak = max(peak, abs(samples[index])) }
            }
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            meter.record(peak: peak)
        }
    }
}

/// "Also pause music and video": not built. macOS 15.4 and later withhold Now Playing (MediaRemote) from apps without
/// Apple's entitlement, so COS cannot know whether anything plays, and the play/pause key toggles: sent while nothing
/// plays, it STARTS playback. COS pauses only on a known, playing state, which it never has.
enum DictationMedia {
    enum Action: Equatable, Sendable { case leave, pause }
    static func decide(playing: Bool?) -> Action { playing == true ? .pause : .leave }
}

// MARK: - Dictation for everyone (0.5.317, server 6.74.0)
//
// Mac dictation runs on any local engine the server has: Parakeet Ultra, or Whisper on this Mac. The server chooses by
// the person's Dictation engine setting (Automatic by default) and says which ran. When a dictation cannot be
// transcribed, the card names the reason and offers one action that can fix it.

enum DictationEngineName {
    static func title(_ engine: String?) -> String? {
        switch engine {
        case "parakeet-ultra": "Parakeet Ultra"
        case "whisper": "Whisper"
        default: nil
        }
    }
    /// Why Automatic used Whisper for this one, as the end of a sentence.
    static func fallbackPhrase(_ reason: String?) -> String? {
        switch reason {
        case "parakeet_not_installed": "Parakeet Ultra is not installed"
        case "parakeet_warming": "Parakeet Ultra was warming up"
        case "parakeet_warm_failed": "Parakeet Ultra could not start"
        case "parakeet_breaker_open": "Parakeet Ultra is paused after repeated errors"
        case "parakeet_busy": "Parakeet Ultra was busy"
        case "parakeet_failed": "Parakeet Ultra could not transcribe this audio"
        case "audio_not_pcm_wav": "this audio needed Whisper"
        default: nil
        }
    }
    /// The history detail's engine line. nil for a record from before 0.5.317 (no engine stored).
    static func detailLine(engine: String?, fallbackReason: String?) -> String? {
        guard let title = title(engine) else { return nil }
        if engine == "whisper", let why = fallbackPhrase(fallbackReason) { return "Transcribed on this Mac with Whisper, because \(why)." }
        return "Transcribed on this Mac with \(title)."
    }
}

/// The one action a failure card offers (0.5.317). From the helper's `action`: the server's own for a 6.74.0 refusal,
/// COS's for a transport failure or an older server. Retry is offered only while the audio is held and the server has
/// not said a retry cannot succeed.
enum DictationFailureAction: String, Equatable, Sendable {
    case installParakeet = "install_parakeet"
    case useWhisper = "use_whisper"
    case retry
    case openTranscriptionSettings = "open_transcription_settings"
    case openMicrophoneSettings = "open_microphone_settings"
    /// 0.5.330: the 🌐 key's own job in macOS (DictationFnUsage).
    case openKeyboardSettings = "open_keyboard_settings"
    case none

    var title: String? {
        switch self {
        case .installParakeet: "Install Parakeet (654 MB)"
        case .useWhisper: "Use Whisper"
        case .retry: "Retry"
        case .openTranscriptionSettings: "Open Transcription settings"
        case .openMicrophoneSettings: "Open Settings"
        case .openKeyboardSettings: "Open Keyboard settings"
        case .none: nil
        }
    }

    /// `action`: the helper's, nil for a failure COS raised itself (the server not connected). `retryable` false means
    /// the server said a retry cannot succeed.
    static func resolve(action: String?, retryable: Bool?, noSpeech: Bool, audioHeld: Bool) -> DictationFailureAction {
        if noSpeech { return .none }
        let asked = action.flatMap(Self.init(rawValue:))
        switch asked {
        case .retry?:
            if retryable == false { return .openTranscriptionSettings }
            return audioHeld ? .retry : .none
        case nil:
            return audioHeld && retryable != false ? .retry : .none
        case let other?:
            return other
        }
    }
}
