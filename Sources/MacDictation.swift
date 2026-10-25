import SwiftUI
import Combine
import UniformTypeIdentifiers
import AVFoundation
import AudioToolbox
import CoreAudio
import ApplicationServices
import Carbon.HIToolbox
import os

private let dictationLog = Logger(subsystem: "com.gotcos.control", category: "dictation")

struct DictationMicrophone: Identifiable, Equatable {
    let id: String // stable UID, never an ephemeral AudioDeviceID
    let deviceID: AudioDeviceID
    let name: String
}

enum DictationAudioDevices {
    static func inputs() -> [DictationMicrophone] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0, size <= 65_536 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return DictationMicrophone(id: uid, deviceID: id, name: name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    /// 0.5.327: the list read off the main actor (a nonisolated async function runs on the global executor), for the
    /// refresh after listening began; the result comes back to the caller's actor.
    static func inputsOffMain() async -> [DictationMicrophone] { inputs() }
    /// 0.5.327: single property reads for the press (DictationStart.resolve, DictationSpare.check): no enumeration.
    static func uid(of id: AudioDeviceID) -> String? { string(id, kAudioDevicePropertyDeviceUID) }
    static func defaultInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }
    static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }
    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else { return true }  // unknown: treat as Bluetooth, never warm
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

/// No system input/output device is changed. Only this engine's input AudioUnit is selected.
/// 0.5.328: not on the main actor. `warm` and `start` run on DictationAudioQueues.input (building and starting an
/// engine took 132 to 326 ms on Miles's Mac, about 3 s cold); `stop` runs where the store closes the microphone, as in
/// 0.5.326. One lock serialises every engine call, so a stop can never overlap a start. The readers below read the
/// lock-protected PCM buffer and are safe anywhere.
final class DictationMicrophoneCapture: @unchecked Sendable {
    private let engineLock = NSRecursiveLock()
    private let engine = AVAudioEngine()
    private let pcm = DictationPCMBuffer()
    private var tapped = false
    private var observer: NSObjectProtocol?
    private var converter: DictationConverter?
    func snapshot() -> Data { pcm.snapshot(maximumBytes: 320_000) }
    /// 0.5.326: bytes captured so far (the release mark for the timing line).
    var capturedBytes: Int { pcm.byteCount() }
    var level: Double { pcm.currentLevel() }
    var failure: String? { pcm.failureMessage() }
    /// 0.5.327: when the first audio arrived (systemUptime), nil until it has.
    var firstAudioUptime: TimeInterval? { pcm.firstAudioUptime() }
    /// 0.5.327 spare (DictationSpare): builds the engine's input node and selects the device, the slow part of opening.
    /// Never prepares or starts: the microphone stays off until `start`.
    func warm(deviceID: AudioDeviceID?) throws {
        engineLock.lock(); defer { engineLock.unlock() }
        try select(deviceID)
        _ = engine.inputNode.inputFormat(forBus: 0)
    }
    private func select(_ deviceID: AudioDeviceID?) throws {
        let input = engine.inputNode
        if var deviceID {
            guard let unit = input.audioUnit,
                  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
                throw error("The selected microphone is unavailable. Refresh microphones and choose one.")
            }
        }
    }
    func start(deviceID: AudioDeviceID?) throws {
        engineLock.lock(); defer { engineLock.unlock() }
        let input = engine.inputNode
        try select(deviceID)
        // 0.5.329 (Miles 2026-10-19 21:51, crash on every press with the Studio Display Microphone selected): the tap's
        // format is the device's own, read AFTER the switch. The node's outputFormat still described the default input
        // (2 ch, 48 kHz) while the Studio Display microphone runs at 1 ch, 96 kHz, and AVAudioEngine raised "Failed to
        // create tap due to format mismatch", an exception Swift cannot catch. A probe on this Mac (one file) reproduced
        // it: outputFormat 48000/2 after the switch, inputFormat 96000/1; tapping with inputFormat delivered audio.
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: target) else { throw error("The microphone format is unavailable.") }
        let accumulator = pcm
        let converterBox = DictationConverter(converter: converter, target: target, pcm: accumulator)
        self.converter = converterBox
        // @Sendable on both: a closure formed inside a @MainActor class otherwise inherits main-actor isolation, Swift 6
        // checks it on entry, and AVAudioEngine calls from its own queue. 0.5.305 trapped on the first buffer. Kept
        // explicit since 0.5.328 moved this class off the main actor, so moving it back can never reintroduce the trap.
        // Never two taps on one bus (another exception): a reused spare always starts from none.
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in converterBox.consume(buffer) }
        tapped = true
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { @Sendable _ in
            accumulator.fail("The microphone changed or disconnected. Stop and select it again.")
        }
        do { engine.prepare(); try engine.start() }
        catch { _ = try? stop(); throw error }
    }
    func stop() throws -> Data {
        engineLock.lock(); defer { engineLock.unlock() }
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        // 0.5.326: the resampler holds its last few milliseconds until it is told the stream ended. Keep them.
        converter?.finish(); converter = nil
        return try pcm.result()
    }
    private func error(_ text: String) -> NSError { NSError(domain: "COSDictation", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}

/// AVAudioEngine calls a tap serially. No UI, network or file IO runs in this callback. 0.5.326: `finish` runs on the main
/// actor after the tap is removed; the lock keeps it from ever overlapping a late callback.
private final class DictationConverter: @unchecked Sendable {
    let converter: AVAudioConverter
    let target: AVAudioFormat
    let pcm: DictationPCMBuffer
    private let lock = NSLock()
    private var finished = false
    init(converter: AVAudioConverter, target: AVAudioFormat, pcm: DictationPCMBuffer) { self.converter = converter; self.target = target; self.pcm = pcm }
    /// Drain: the converter's held samples come out once it is told the input ended. Called once, at stop.
    func finish() {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else { return }
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, state in state.pointee = .endOfStream; return nil }
        guard status != .error, failure == nil, output.frameLength > 0, let data = output.int16ChannelData?[0] else { return }
        pcm.append(Data(bytes: data, count: Int(output.frameLength) * 2))
    }
    func consume(_ input: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { pcm.fail("Microphone conversion failed."); return }
        var supplied = false
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard status != .error, failure == nil else { pcm.fail("Microphone conversion failed."); return }
        guard let data = output.int16ChannelData?[0] else { return }
        pcm.append(Data(bytes: data, count: Int(output.frameLength) * 2))
    }
}

/// Wispr-style delivery. The text is ALWAYS put on the clipboard and left there, then dropped into the editable text
/// element focused NOW in the frontmost app, so the person may click elsewhere while it transcribes. Never presses
/// Return or Send.
///
/// 0.5.310 (Miles, 2026-10-15 20:07: iTerm2 focused, the pet flashed "✓ INSERTED · ITERM2", nothing landed): an AX set
/// that returns success proves nothing. COS measures the field before and after (AXNumberOfCharacters and
/// AXSelectedTextRange, never AXValue) and DictationDelivery.decide (pure, tested) turns the measurements into the
/// outcome. ✓ INSERTED only when a measured change proves it. Terminals go straight to ⌘V.
/// Where a measured insertion landed (0.5.313): the element COS set or pasted into and the range it proved. Held in
/// memory only, for Replace it in <App>; an AXUIElement means nothing to another run. Unchecked: it is created and
/// used only on the main actor (DictationInsertion and MacDictationStore).
struct DictationInsertTarget: @unchecked Sendable {
    let element: AXUIElement
    let span: DictationInsertedSpan
    let terminal: Bool
    let app: String
    /// 0.5.318: what COS believes the field holds at `span` (what it typed, or put there on the last replace), so the
    /// stored dictation can take Fix a word's correction at Save while this still describes the field.
    let text: String
    /// The Accessibility set moved this field at delivery. False where only ⌘V landed (Electron, Chromium, terminals):
    /// there the set reports success and changes nothing, so a replace must paste.
    let setterWorked: Bool
    let bundle: String?
    /// Learn from my edits (0.5.318): any Chromium-family app, and the Electron or CEF apps among them.
    var chromium = false
    var electron = false
}

/// After Save in Fix a word: the corrected dictation and the app it can go back into (nil: copy only).
struct DictationReplaceOffer: Equatable {
    let recordID: UUID
    let corrected: String
    let app: String?
}

/// What `deliver` did, and where, when it can prove it.
struct DictationDelivered: Sendable {
    let outcome: DictationDeliveryOutcome
    let target: DictationInsertTarget?
    /// 0.5.323: the field was read before typing. What was typed (it may differ from what was heard), the fixes, and
    /// the field's text outside the dictation for Learn from my edits. Memory only; never logged, saved or sent.
    var context: DictationFieldContext.Applied? = nil
    /// 0.5.337 (Miles 2026-10-22 21:11): COS's own text view, when the dictation went into one (route ownWindow). Learn
    /// from my edits watches it the way it watches another app's field.
    var own: DictationOwnTarget? = nil
}

/// 0.5.337: a dictation typed into one of COS Control's own text views (the Work task editor, the Ask box). Held weakly:
/// the watch ends when the view goes.
struct DictationOwnTarget: @unchecked Sendable {
    weak var view: NSTextView?
    let span: DictationInsertedSpan
    let text: String
    let app: String
}

@MainActor enum DictationInsertion {
    /// Bundle path → Electron/Chromium. A frontmost app's frameworks do not change while it runs.
    private static var chromium: [String: Bool] = [:]
    private static var electron: [String: Bool] = [:]

    static func deliver(_ raw: String, restoreClipboard: Bool, fieldContext: Bool = false) async -> DictationDelivered {
        let started = Date()
        let app = NSWorkspace.shared.frontmostApplication
        let bundle = app?.bundleIdentifier
        let name = app?.localizedName ?? "the app"
        let terminal = KnownApps.isTerminal(bundle)
        // 0.5.323: the field's own words may respell it before it is typed (DictationFieldContext, below).
        var text = terminal ? DictationDelivery.terminalText(raw) : raw
        var count = text.utf16.count
        var facts = "bundle=\(bundle ?? "-") terminal=\(terminal)"
        // 0.5.312: the clipboard is written only when COS must: just before a ⌘V it posts, or for the card that asks the
        // person to paste. Accessibility insertion never touches it (DictationClipboard.use).
        let board = SystemDictationPasteboard(NSPasteboard.general)
        var wroteTranscript = false
        // 0.5.313: set only when a measurement proved exactly where the text landed.
        var landed: DictationInsertTarget?
        var context: DictationFieldContext.Applied?
        // Durable, and never the text: what was focused, what COS measured, what it did (0.5.310).
        func done(_ outcome: DictationDeliveryOutcome) -> DictationDelivered {
            if DictationClipboard.use(for: outcome) == .keepForCard, !wroteTranscript, outcome != .refused(.clipboardChanged) {
                wroteTranscript = board.writeTranscript(text, markerTypes: [])
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000), span = landed != nil ? "measured" : "none"
            dictationLog.notice("delivery \(facts, privacy: .public) outcome=\(String(describing: outcome), privacy: .public) ms=\(ms) span=\(span, privacy: .public)")
            if case .inserted = outcome { return DictationDelivered(outcome: outcome, target: landed, context: context) }
            return DictationDelivered(outcome: outcome, target: nil, context: context)
        }

        let trusted = AXIsProcessTrusted()
        let own = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        // COS's own pet and dictation panels are never a target, even when one of them holds the keyboard.
        let ownOverlay = own && (NSApp.keyWindow is PetPanel || NSApp.keyWindow is DictationOverlayPanel)
        if own, !ownOverlay {
            facts += " route=ownWindow"
            let (outcome, target) = ownWindow(text, app: name)
            var delivered = done(outcome)
            if case .inserted = outcome { delivered.own = target }
            return delivered
        }

        var element: AXUIElement?
        var family = false, electronApp = false
        if trusted, let app, !own {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.25)
            element = focused(appElement)
            family = isChromiumFamily(app)
            electronApp = isElectron(app)
            // Electron and Chromium build their accessibility tree only when asked (ControllerModel's Claude jump does
            // the same), then focus is read again before anything is refused.
            if family, element.map({ !textCapable($0) }) ?? true {
                AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                element = focused(appElement)
            }
        }
        if let element { AXUIElementSetMessagingTimeout(element, 0.25) }
        let role = element.flatMap { attribute($0, kAXRoleAttribute) as? String }
        let subrole = element.flatMap { attribute($0, kAXSubroleAttribute) as? String }
        let settable = element.map { textSettable($0) } ?? false
        let ancestor = element.flatMap { editableAncestor($0) }
        facts += " family=\(family) role=\(role ?? "-") subrole=\(subrole ?? "-") settable=\(settable) ancestor=\(ancestor != nil)"
        // 0.5.332: a canvas web editor (Slides in Comet) takes ⌘V below, unconfirmed; the log says which it was.
        let canvas = DictationInsertPolicy.canvasEditor(chromium: family, focused: element != nil, textSettable: settable, editableAncestor: ancestor != nil)
        facts += " canvas=\(canvas)"
        if let refusal = DictationInsertPolicy.refusal(
            trusted: trusted, secureInput: IsSecureEventInputEnabled(), subrole: subrole, focused: element != nil,
            textSettable: settable, editableAncestor: ancestor != nil, pasteApp: terminal || family, ownOverlay: ownOverlay) {
            return done(.refused(refusal))
        }
        // A web editor's caret lives on its editable ancestor; that is the element to set and measure.
        let target = settable ? element : (ancestor ?? element)
        let baseline = snapshot(target)
        let route = DictationDelivery.route(isOwnApp: false, terminal: terminal, baselineReadable: baseline.readable)
        facts += " route=\(route.rawValue) before=\(baseline.logDescription)"
        // 0.5.323: the words already in this field spell a misheard name the way the field has it. Counts only in the log.
        if let target {
            context = readContext(target, enabled: fieldContext, terminal: terminal, baseline: baseline, dictation: text, facts: &facts)
            if let context { text = context.text; count = text.utf16.count }
        }

        if route == .accessibility, let target {
            let setter = AXUIElementSetAttributeValue(target, kAXSelectedTextAttribute as CFString, text as CFString)
            facts += " setter=\(setter.rawValue)"
            var elapsed = 0
            polling: for (index, ms) in DictationDelivery.pollMilliseconds.enumerated() {
                if ms > elapsed { try? await Task.sleep(for: .milliseconds(ms - elapsed)); elapsed = ms }
                let after = snapshot(target)
                switch DictationDelivery.decide(route: route, baseline: baseline, setterSucceeded: setter == .success, afterSetter: after,
                                                finalPoll: index == DictationDelivery.pollMilliseconds.count - 1, pasted: false,
                                                afterPaste: DictationFieldSnapshot(), count: count, app: name) {
                case .wait: continue
                case .done(let outcome):
                    facts += " after=\(after.logDescription)"
                    if let app, let span = DictationReplace.span(pid: app.processIdentifier, baseline: baseline, after: after, count: count) {
                        landed = DictationInsertTarget(element: target, span: span, terminal: terminal, app: name, text: text, setterWorked: true, bundle: bundle,
                                                       chromium: family, electron: electronApp)
                    }
                    return done(outcome)
                case .paste: facts += " after=\(after.logDescription)"; break polling
                }
            }
        }

        // ⌘V. Nothing above changed the field, so this cannot double the text. The person's clipboard is snapshotted,
        // the transcript written (marked transient for clipboard managers), and put back after the paste is read.
        let saved = DictationClipboard.snapshot(board)
        guard board.writeTranscript(text, markerTypes: DictationClipboard.transientTypes) else { return done(.refused(.clipboardFailed)) }
        wroteTranscript = true
        let changeCount = board.changeCount
        let beforePaste = snapshot(target)
        if let stop = await paste(changeCount: changeCount) { return done(.refused(stop.refusal)) }
        let postedAt = Date()
        facts += " paste=sent"
        var waited = 0
        var decision = DictationDecision.wait
        var measuredAfterPaste = DictationFieldSnapshot()
        for ms in [80, 200, 400] {
            try? await Task.sleep(for: .milliseconds(ms - waited)); waited = ms
            let after = snapshot(target)
            measuredAfterPaste = after
            decision = DictationDelivery.decide(route: .paste, baseline: beforePaste, setterSucceeded: false, afterSetter: DictationFieldSnapshot(),
                                                finalPoll: true, pasted: true, afterPaste: after, count: count, app: name)
            facts += " afterPaste=\(after.logDescription)"
            // Keep watching until the field moves; an app may take the paste late. Never a second paste.
            if case .done(.inserted) = decision { break }
        }
        // Put the clipboard back once the target has read it: no sooner than 500 ms, longer while the field still moves.
        var last = snapshot(target)
        while true {
            let elapsed = Int(Date().timeIntervalSince(postedAt) * 1000)
            try? await Task.sleep(for: .milliseconds(100))
            let now = snapshot(target)
            defer { last = now }
            if !DictationClipboard.keepWaiting(elapsedMilliseconds: elapsed + 100, fieldChanging: now != last) { break }
        }
        switch DictationClipboard.decision(enabled: restoreClipboard, pasted: true, snapshot: saved, setChangeCount: changeCount,
                                           currentChangeCount: board.changeCount) {
        case .restore:
            let restored = saved.map { DictationClipboard.restore($0, to: board) } ?? false
            dictationLog.notice("clipboard \(restored ? "restored" : "restore failed", privacy: .public) items=\(saved?.items.count ?? 0)")
        case .skip(let reason):
            dictationLog.notice("clipboard not restored: \(reason, privacy: .public)")
        }
        if let app, let target, let span = DictationReplace.span(pid: app.processIdentifier, baseline: beforePaste, after: measuredAfterPaste, count: count) {
            landed = DictationInsertTarget(element: target, span: span, terminal: terminal, app: name, text: text, setterWorked: false, bundle: bundle,
                                           chromium: family, electron: electronApp)
        }
        if case .done(let outcome) = decision { return done(outcome) }
        return done(.unconfirmed(app: name, viaPaste: true))
    }

    /// 0.5.332 (automatic swaps on the paste route only): `replacedUnconfirmed`, the ⌘V landed by count and could not be
    /// read back; `mismatch`, after the ⌘V the field did not hold the count it should.
    enum ReplaceResult: Equatable { case replaced, copied(DictationReplace.Reason), unverified(pasted: Bool), replacedUnconfirmed, mismatch }
    /// What a replace did, and where the dictation now is (nil: no longer tracked, so a later replace copies).
    struct Replaced {
        let result: ReplaceResult
        let target: DictationInsertTarget?
        /// 0.5.331: an automatic swap's own reason (the focus rules), more precise than `result`'s.
        var skip: DictationPolishSwap.Skip? = nil
        /// The route it took (accessibility or paste), once the plan placed the edit.
        var route: DictationReplace.Route? = nil
    }

    /// Replace it in <App> (0.5.313; 0.5.318 routes and proof). Reads only a bounded window around where the dictation
    /// went (AXStringForRange; else the span selected and read), plans the smallest whole-word edit, then takes the route
    /// delivery proved works in this field: the Accessibility set, or ⌘V over a selection read back as exactly the
    /// misheard words. Measures after either. The only key it can post is ⌘V, after that proof; never Return.
    /// One `replace` line per attempt: bundle, route, where the text was found, the selection and focus proof, the
    /// read-back. Counts and booleans only, never text.
    /// 0.5.331 `automatic`: AI polish's swap (paste first, polish in place). Only the whole dictation, exactly where COS
    /// typed it or found moved within the window; the paste route only where the person already is (the app frontmost,
    /// its focused element the target, no COS window holding the keyboard), with no activation and no window moved;
    /// the person's caret goes back afterwards, shifted by the length change. The clipboard goes back as delivery's does.
    static func replace(_ target: DictationInsertTarget, corrected: String, restoreClipboard: Bool, automatic: Bool = false) async -> Replaced {
        let element = target.element
        AXUIElementSetMessagingTimeout(element, 0.25)
        var facts = "bundle=\(target.bundle ?? "-") setterWorked=\(target.setterWorked) terminal=\(target.terminal) automatic=\(automatic)"
        var routeTaken: DictationReplace.Route?
        func done(_ result: ReplaceResult, _ next: DictationInsertTarget?, skip: DictationPolishSwap.Skip? = nil) -> Replaced {
            if let skip { facts += " skip=\(skip.rawValue)" }
            dictationLog.notice("replace \(facts, privacy: .public) result=\(String(describing: result), privacy: .public)")
            return Replaced(result: result, target: next, skip: skip, route: routeTaken)
        }
        let running = NSRunningApplication(processIdentifier: target.span.pid).map { !$0.isTerminated } ?? false
        let original = running && !target.terminal ? snapshot(element) : DictationFieldSnapshot()
        // The window around the span; else the span alone, by AXStringForRange or by selecting it to read.
        var window: String?, windowStart = target.span.location, read = "none"
        if let n = original.characters {
            let bounds = DictationReplace.window(span: target.span, currentLength: target.text.utf16.count, fieldCharacters: n)
            if let text = string(element, location: bounds.location, length: bounds.length) { window = text; windowStart = bounds.location; read = "window" }
            else if let text = string(element, location: target.span.location, length: target.span.length) { window = text; read = "span" }
            else if n >= target.span.location + target.span.length, select(element, location: target.span.location, length: target.span.length) {
                window = attribute(element, kAXSelectedTextAttribute) as? String; read = window == nil ? "none" : "selection"
                if let l = original.location, let len = original.length { _ = select(element, location: l, length: len) }
            }
        }
        let plan = DictationReplace.plan(span: target.span, terminal: target.terminal, appRunning: running, fieldCharacters: original.characters,
                                         window: window, windowStart: windowStart, current: target.text, corrected: corrected)
        facts += " n=\(original.characters.map(String.init) ?? "?") read=\(read)"
        if automatic, let skip = DictationPolishSwap.placed(plan) {
            if case .copy(let reason) = plan { return done(.copied(reason), target, skip: skip) }
            return done(.copied(.textMoved), target, skip: skip)
        }
        guard case .edit(let planned, let dictationAt) = plan else {
            if case .copy(let reason) = plan { facts += " found=\(reason.rawValue)"; return done(.copied(reason), target) }
            return done(.copied(.notMeasured), target)
        }
        let route = DictationReplace.route(setterWorked: target.setterWorked)
        // 0.5.332: an automatic swap on the paste route replaces the whole dictation, never a fragment of it.
        let edit = automatic ? DictationPolishSwap.pasteEdit(planned, route: route, dictationAt: dictationAt, current: target.text, corrected: corrected) : planned
        let found = dictationAt == nil ? "words" : dictationAt == target.span.location ? "exact" : "moved"
        facts += " found=\(found) edit=\(edit.location)+\(edit.length)>\(edit.replacement.utf16.count)"
        // Where the dictation sits once the edit lands; nil when only the misheard words were found.
        let next = dictationAt.map { at in
            DictationInsertTarget(element: element, span: DictationInsertedSpan(pid: target.span.pid, location: at, length: corrected.utf16.count),
                                  terminal: target.terminal, app: target.app, text: corrected, setterWorked: target.setterWorked, bundle: target.bundle,
                                  chromium: target.chromium, electron: target.electron)
        }
        routeTaken = route
        facts += " route=\(route)"
        func putBack() { if let l = original.location, let len = original.length { _ = select(element, location: l, length: len) } }
        // 0.5.331: after an automatic swap the person's caret or selection goes back where it was, shifted past the edit.
        func restoreCaret() {
            guard automatic, let l = original.location, let len = original.length else { return }
            let to = DictationPolishSwap.shifted(location: l, length: len, edit: edit)
            facts += " caret=\(select(element, location: to.location, length: to.length) ? "restored" : "failed")"
        }

        if route == .accessibility {
            guard select(element, location: edit.location, length: edit.length) else { facts += " select=failed"; return done(.copied(.fieldGone), target) }
            let before = snapshot(element)
            let setter = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, edit.replacement as CFString)
            facts += " setter=\(setter.rawValue)"
            guard setter == .success else { putBack(); return done(.copied(.fieldGone), target) }
            var elapsed = 0
            for ms in DictationDelivery.pollMilliseconds {
                if ms > elapsed { try? await Task.sleep(for: .milliseconds(ms - elapsed)); elapsed = ms }
                let after = snapshot(element), back = string(element, location: edit.location, length: edit.replacement.utf16.count)
                if DictationReplace.confirmed(before: before, after: after, edit: edit, readback: back) {
                    facts += " after=\(after.logDescription) readback=\(back == nil ? "unreadable" : "match")"
                    restoreCaret()
                    return done(.replaced, next)
                }
            }
            facts += " after=\(snapshot(element).logDescription)"
            return done(.unverified(pasted: false), target)
        }

        // ⌘V. COS's own pet or editor holds the keyboard while Fix a word is open: give it back to the app's window
        // the way the composer does (out and front again never takes key), bring the app forward, then prove focus.
        // 0.5.331: an automatic swap does none of this. It never activates an app or moves a window (DictationPolishSwap).
        if DictationPolishSwap.mayActivate(automatic: automatic) {
            if let key = NSApp.keyWindow, key is PetPanel || key is DictationOverlayPanel { key.orderOut(nil); key.orderFrontRegardless() }
            if let app = NSRunningApplication(processIdentifier: target.span.pid), NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                app.activate()
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.span.pid
        let appElement = AXUIElementCreateApplication(target.span.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        let focusedNow = focused(appElement)
        var focusedIsTarget = false
        if let focusedNow {
            focusedIsTarget = CFEqual(focusedNow, element) || editableAncestor(focusedNow).map { ancestor in CFEqual(ancestor, element) } == true
        }
        if automatic, let skip = DictationPolishSwap.gate(route: route, frontmost: frontmost, focusedIsTarget: focusedIsTarget, ownWindowKey: NSApp.keyWindow != nil) {
            facts += " frontmost=\(frontmost) ownKey=\(NSApp.keyWindow != nil) focused=\(focusedIsTarget)"
            return done(.copied(.notFocused), target, skip: skip)
        }
        // Chromium applies a selection asynchronously: poll until it reads back as the edit range.
        var selection = DictationFieldSnapshot()
        if frontmost, focusedIsTarget, select(element, location: edit.location, length: edit.length) {
            var elapsed = 0
            for ms in DictationDelivery.pollMilliseconds {
                if ms > elapsed { try? await Task.sleep(for: .milliseconds(ms - elapsed)); elapsed = ms }
                selection = snapshot(element)
                if selection.location == edit.location, selection.length == edit.length { break }
            }
        }
        let selected = attribute(element, kAXSelectedTextAttribute) as? String
        let proof = DictationReplace.pasteProof(frontmost: frontmost, ownWindowKey: NSApp.keyWindow != nil, focusedIsTarget: focusedIsTarget,
                                                selection: selection, selectedText: selected, edit: edit)
        facts += " frontmost=\(frontmost) ownKey=\(NSApp.keyWindow != nil) focused=\(focusedIsTarget) selection=\(selection.logDescription) selectedMatch=\(selected == edit.original)"
        if let proof { if frontmost, focusedIsTarget { putBack() }; return done(.copied(proof), target) }
        let board = SystemDictationPasteboard(NSPasteboard.general)
        let saved = DictationClipboard.snapshot(board)
        guard board.writeTranscript(edit.replacement, markerTypes: DictationClipboard.transientTypes) else { putBack(); return done(.copied(.fieldGone), target) }
        let changeCount = board.changeCount
        // 0.5.332: an automatic swap proves it again immediately before the ⌘V (after any wait for held keys): the count
        // the plan read and the proof measured, the selection still exactly the span and reading as it, no key in 600 ms.
        let planCount = original.characters, proofCount = selection.characters
        func reproof() -> DictationPolishSwap.Skip? {
            guard automatic else { return nil }
            let now = snapshot(element), selectedNow = attribute(element, kAXSelectedTextAttribute) as? String
            let sinceKey = msSinceKeyDown()
            let skip = DictationPolishSwap.reproof(planCount: planCount, proofCount: proofCount, now: now, selectedText: selectedNow, edit: edit, sinceKeyMs: sinceKey)
            facts += " reproof=\(skip?.rawValue ?? "ok") now=\(now.logDescription) sinceKeyMs=\(sinceKey)"
            return skip
        }
        if let stop = await paste(changeCount: changeCount, recheck: reproof) {
            // Not pasted: the person's clipboard goes back now; the caller copies the corrected dictation.
            if let saved { _ = DictationClipboard.restore(saved, to: board) }
            switch stop {
            case .refused(let refusal):
                facts += " paste=\(refusal.rawValue)"
                putBack(); return done(.copied(.notFocused), target, skip: automatic ? DictationPolishSwap.skip(forPaste: refusal) : nil)
            case .moved(let skip):
                facts += " paste=skipped"
                // The field moved under the selection: leave the caret where the person put it.
                if skip != .textMoved, skip != .fieldGone { putBack() }
                return done(.copied(.textMoved), target, skip: skip)
            }
        }
        facts += " paste=sent"
        let postedAt = Date()
        var landed = false, waited = 0
        var landing = DictationPolishSwap.Landing.pending
        let polls = [80, 200, 400, 700]
        for ms in polls {
            try? await Task.sleep(for: .milliseconds(ms - waited)); waited = ms
            let after = snapshot(element), back = string(element, location: edit.location, length: edit.replacement.utf16.count)
            // 0.5.332: an automatic swap is judged by the count it must leave: proof count, less the span, plus the new text.
            if automatic, let proofCount {
                landing = DictationPolishSwap.landing(proofCount: proofCount, after: after, edit: edit, readback: back, finalPoll: ms == polls.last)
                if landing != .pending { facts += " after=\(after.logDescription) expected=\(proofCount - edit.length + edit.replacement.utf16.count) readback=\(back == nil ? "unreadable" : back == edit.replacement ? "match" : "mismatch") landing=\(landing)" }
                if landing != .pending { break }
                continue
            }
            if DictationReplace.confirmed(before: selection, after: after, edit: edit, readback: back) {
                facts += " after=\(after.logDescription) readback=\(back == nil ? "unreadable" : "match")"; landed = true; break
            }
            if ms == 700 { facts += " after=\(after.logDescription) readback=\(back == nil ? "unreadable" : back == edit.replacement ? "match" : "mismatch")" }
        }
        // Unconfirmed: the caller leaves the corrected dictation on the clipboard. Confirmed: the person's goes back.
        // 0.5.331: an automatic swap puts the person's clipboard back either way, as delivery does.
        if landed || automatic {
            let elapsed = Int(Date().timeIntervalSince(postedAt) * 1000)
            if elapsed < DictationClipboard.restoreAfterMilliseconds { try? await Task.sleep(for: .milliseconds(DictationClipboard.restoreAfterMilliseconds - elapsed)) }
            if case .restore = DictationClipboard.decision(enabled: restoreClipboard, pasted: true, snapshot: saved, setChangeCount: changeCount,
                                                           currentChangeCount: board.changeCount), let saved {
                _ = DictationClipboard.restore(saved, to: board)
            }
            if landed { restoreCaret(); return done(.replaced, next) }
        }
        if automatic {
            switch landing {
            case .swapped: restoreCaret(); return done(.replaced, next)
            case .unconfirmed: restoreCaret(); return done(.replacedUnconfirmed, next)
            // Never a second paste. Where the dictation is now is unknown, so nothing tracks it.
            case .mismatch, .pending:
                dictationLog.notice("swap mismatch bundle=\(target.bundle ?? "-", privacy: .public) \(facts, privacy: .public)")
                return done(.mismatch, nil)
            }
        }
        return done(.unverified(pasted: true), target)
    }
    nonisolated private static func string(_ element: AXUIElement, location: Int, length: Int) -> String? {
        guard location >= 0, length >= 0 else { return nil }
        return string(element, at: DictationInsertedSpan(pid: 0, location: location, length: length))
    }
    nonisolated private static func string(_ element: AXUIElement, at span: DictationInsertedSpan) -> String? {
        var range = CFRange(location: span.location, length: span.length)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success else { return nil }
        return value as? String
    }
    nonisolated private static func select(_ element: AXUIElement, location: Int, length: Int) -> Bool {
        var range = CFRange(location: location, length: length)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    /// 0.5.332: milliseconds since any key went down (Return included), from the session's own event record. Read only.
    private static func msSinceKeyDown() -> Int {
        Int((CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) * 1000).rounded())
    }
    /// 0.5.332: why a ⌘V was not posted: a delivery refusal, or (an automatic swap's re-proof) something moved.
    enum PasteStop: Equatable {
        case refused(DictationInsertPolicy.Refusal)
        case moved(DictationPolishSwap.Skip)
        var refusal: DictationInsertPolicy.Refusal { if case .refused(let refusal) = self { refusal } else { .noTextBox } }
    }
    /// ⌘V on the current layout's V, only once no modifier is physically held and only while the clipboard still
    /// holds what COS put there. Returns why it did not paste. 0.5.332: `recheck` runs last, immediately before the
    /// key is posted; a reason from it posts nothing.
    private static func paste(changeCount: Int, recheck: () -> DictationPolishSwap.Skip? = { nil }) async -> PasteStop? {
        var waited = 0
        while DictationDelivery.modifiersHeld(isDown: { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) }) {
            guard waited < DictationDelivery.modifierWaitMilliseconds else { return .refused(.keysHeld) }
            try? await Task.sleep(for: .milliseconds(30)); waited += 30
        }
        guard NSPasteboard.general.changeCount == changeCount else { return .refused(.clipboardChanged) }
        if let moved = recheck() { return .moved(moved) }
        let key = CGKeyCode(vKeyCode())
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return .refused(.noTextBox) }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return nil
    }

    /// The key that types "v" with ⌘ held on the current layout (Dvorak, AZERTY, Dvorak-QWERTY ⌘). ANSI V (9) when the
    /// layout cannot be read.
    private static func vKeyCode() -> UInt16 {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return 9 }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let commandState = UInt32((cmdKey >> 8) & 0xFF)
        let keyboard = UInt32(LMGetKbdType())
        return layoutData.withUnsafeBytes { bytes -> UInt16 in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return 9 }
            let found = DictationDelivery.keyCode(for: "v") { code in
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), commandState, keyboard,
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, 4, &length, &chars)
                return status == noErr && length > 0 ? String(utf16CodeUnits: chars, count: length) : nil
            }
            return found ?? 9
        }
    }

    /// One of COS's own windows (Activity, Settings) has the keyboard: insert through its first responder, and measure
    /// the field editor the same way.
    /// 0.5.313: an interrupted dictation is copied and never typed, since where the person was typing may have changed.
    /// An interrupted dictation is copied, never typed. If the person copied something while it was transcribing, their
    /// clipboard wins (QA 0.5.313: the salvage overwrote it): the card holds the text to copy instead.
    static func copyOnly(_ text: String, clipboardMoved: Bool) -> DictationDelivered {
        if clipboardMoved {
            dictationLog.notice("delivery route=interrupted outcome=clipboard kept")
            return DictationDelivered(outcome: .refused(.interruptedClipboardKept), target: nil)
        }
        let wrote = SystemDictationPasteboard(NSPasteboard.general).writeTranscript(text, markerTypes: [])
        let outcome: DictationDeliveryOutcome = .refused(wrote ? .interrupted : .clipboardFailed)
        dictationLog.notice("delivery route=interrupted outcome=\(String(describing: outcome), privacy: .public)")
        return DictationDelivered(outcome: outcome, target: nil)
    }

    private static func ownWindow(_ text: String, app: String) -> (DictationDeliveryOutcome, DictationOwnTarget?) {
        guard let responder = NSApp.keyWindow?.firstResponder else { return (.refused(.noTextBox), nil) }
        if let view = responder as? NSTextView {
            if view.delegate is NSSecureTextField { return (.refused(.secureField), nil) }
            guard view.isEditable else { return (.refused(.noTextBox), nil) }
            func measure() -> DictationFieldSnapshot {
                let range = view.selectedRange()
                return DictationFieldSnapshot(characters: view.string.utf16.count, location: range.location, length: range.length)
            }
            let before = measure()
            view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            let decision = DictationDelivery.decide(route: .ownWindow, baseline: before, setterSucceeded: true, afterSetter: measure(),
                                                    finalPoll: true, pasted: false, afterPaste: DictationFieldSnapshot(), count: text.utf16.count, app: app)
            if case .done(let outcome) = decision {
                // The text went in at the selection's start (insertText replaces the selection).
                let target = DictationOwnTarget(view: view, span: DictationInsertedSpan(pid: ProcessInfo.processInfo.processIdentifier,
                                                                                     location: before.location ?? 0, length: text.utf16.count),
                                                text: text, app: app)
                return (outcome, target)
            }
            return (.refused(.noTextBox), nil)
        }
        if let client = responder as? NSTextInputClient {
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            return (.unconfirmed(app: app, viaPaste: false), nil)
        }
        return (.refused(.noTextBox), nil)
    }

    private static func isElectron(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }
        if let known = electron[url.path] { return known }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("Contents/Frameworks").path)) ?? []
        let result = KnownApps.isElectron(frameworks: names)
        electron[url.path] = result
        return result
    }

    /// 0.5.323: the field's text before the caret and after the selection, bounded (DictationFieldContext.plan), read
    /// with AXStringForRange under a short timeout, then the dictation respelled from its terms. nil when there is
    /// nothing to read, the read is too slow, or the field is a password field, secure input or a terminal. The text
    /// stays in this value and the watch that follows: never logged, never written, never sent.
    private static func readContext(_ target: AXUIElement, enabled: Bool, terminal: Bool, baseline: DictationFieldSnapshot, dictation: String,
                                    facts: inout String) -> DictationFieldContext.Applied? {
        let plan = DictationFieldContext.plan(enabled: enabled, secure: secure(target), terminal: terminal,
                                              fieldCharacters: baseline.characters, location: baseline.location, length: baseline.length)
        guard case .read(let before, let after) = plan else {
            if case .skip(let why) = plan { facts += " context=\(why.replacingOccurrences(of: " ", with: "_"))" }
            return nil
        }
        let started = Date()
        AXUIElementSetMessagingTimeout(target, DictationFieldContext.readTimeoutSeconds)
        defer { AXUIElementSetMessagingTimeout(target, 0.25) }
        let n = baseline.characters ?? 0
        var read = DictationFieldContext.Read(beforeCut: before.location > 0, afterCut: after.location + after.length < n)
        var readable = false
        if before.length > 0, let piece = string(target, location: before.location, length: before.length) { read.before = piece; readable = true }
        if after.length > 0, DictationFieldContext.inBudget(elapsed: Date().timeIntervalSince(started)),
           let piece = string(target, location: after.location, length: after.length) { read.after = piece; readable = true }
        let readMs = Int(Date().timeIntervalSince(started) * 1000)
        guard readable else { facts += " context=unreadable ms=\(readMs)"; return nil }
        guard DictationFieldContext.inBudget(elapsed: Date().timeIntervalSince(started)) else { facts += " context=slow ms=\(readMs)"; return nil }
        var spelled: [String: Bool] = [:]
        func known(_ word: String) -> Bool {
            if let k = spelled[word] { return k }
            let k = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
            spelled[word] = k; return k
        }
        let terms = DictationFieldContext.terms(in: read, known: known)
        let result = DictationFieldContext.corrected(dictation, terms: terms, known: known)
        facts += " context=read terms=\(terms.count) fixes=\(result.fixes.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))"
        return DictationFieldContext.Applied(text: result.text, fixes: result.fixes, outside: [read.before, read.after].filter { !$0.isEmpty }, terms: terms)
    }

    /// 0.5.331: AI polish's version as delivery would have typed it: lists, then the same field words' spellings.
    static func polishedFinal(_ polished: String, formatLists: Bool, context: DictationFieldContext.Applied?) -> (text: String, fixes: [DictationFieldContext.Fix]) {
        var spelled: [String: Bool] = [:]
        return DictationPolishSwap.final(polished, formatLists: formatLists, terms: context?.terms ?? []) { word in
            if let k = spelled[word] { return k }
            let k = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
            spelled[word] = k; return k
        }
    }

    // Learn from my edits (0.5.318) reads through these: counts and the caret, a bounded range, focus, secure fields.
    nonisolated static func measure(_ element: AXUIElement) -> DictationFieldSnapshot { snapshot(element) }
    nonisolated static func text(_ element: AXUIElement, location: Int, length: Int) -> String? { string(element, location: location, length: length) }
    /// The app is frontmost and its focused element is this one (or sits in it, for a web editor).
    nonisolated static func holdsFocus(_ element: AXUIElement, pid: Int32) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        guard let now = focused(appElement) else { return false }
        return CFEqual(now, element) || editableAncestor(now).map { ancestor in CFEqual(ancestor, element) } == true
    }
    /// 0.5.338: what the watch sees now. The focused element (for a web editor, the one delivery would have taken: the
    /// settable element or its editable ancestor), whether it is the watched one, whether it shares its window, and its
    /// identity and count. Attributes and counts only, never text.
    struct FocusedField: @unchecked Sendable {
        var element: AXUIElement? = nil
        var frontmost = false
        var sameElement = false
        var sameWindow = false
        var identity: DictationEditLearning.FieldIdentity? = nil
        var characters: Int? = nil
    }
    nonisolated static func focusedField(pid: Int32, watched: AXUIElement) -> FocusedField {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return FocusedField() }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        guard let now = focused(appElement) else { return FocusedField(frontmost: true) }
        if CFEqual(now, watched) || editableAncestor(now).map({ CFEqual($0, watched) }) == true {
            return FocusedField(element: watched, frontmost: true, sameElement: true)
        }
        AXUIElementSetMessagingTimeout(now, 0.25)
        let field = textSettable(now) ? now : (editableAncestor(now) ?? now)
        AXUIElementSetMessagingTimeout(field, 0.25)
        var sameWindow = false
        if let a = attribute(watched, kAXWindowAttribute), let b = attribute(field, kAXWindowAttribute) { sameWindow = CFEqual(a, b) }
        return FocusedField(element: field, frontmost: true, sameWindow: sameWindow, identity: fieldIdentity(field, pid: pid),
                            characters: snapshot(field).characters)
    }
    /// Role, AXIdentifier (else AXDOMIdentifier) and frame. Never AXValue.
    nonisolated static func fieldIdentity(_ element: AXUIElement, pid: Int32) -> DictationEditLearning.FieldIdentity {
        let role = attribute(element, kAXRoleAttribute) as? String
        let axID = (attribute(element, kAXIdentifierAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
        let identifier = axID ?? (attribute(element, "AXDOMIdentifier") as? String).flatMap { $0.isEmpty ? nil : $0 }
        var frame: CGRect?
        if let p = attribute(element, kAXPositionAttribute), let z = attribute(element, kAXSizeAttribute),
           CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(z) == AXValueGetTypeID() {
            var point = CGPoint.zero, size = CGSize.zero
            if AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(z as! AXValue, .cgSize, &size) { frame = CGRect(origin: point, size: size) }
        }
        return DictationEditLearning.FieldIdentity(pid: pid, role: role, identifier: identifier, frame: frame)
    }
    /// A password field, or any app holding secure keyboard input.
    nonisolated static func secure(_ element: AXUIElement) -> Bool {
        IsSecureEventInputEnabled() || (attribute(element, kAXSubroleAttribute) as? String) == DictationInsertPolicy.secureSubrole
    }

    private static func isChromiumFamily(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }
        if let known = chromium[url.path] { return known }
        let frameworks = url.appendingPathComponent("Contents/Frameworks")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
        // 0.5.332: by structure too (a Renderer helper inside the framework), so Comet and future Chromium browsers count.
        let result = KnownApps.isChromiumFamily(frameworks: names) { name in
            (try? FileManager.default.contentsOfDirectory(atPath: frameworks.appendingPathComponent(name).appendingPathComponent(KnownApps.helpersPath).path)) ?? []
        }
        chromium[url.path] = result
        return result
    }

    /// 0.5.332 (Google Slides in Comet): before a paste-first dictation, whether its target could ever prove a swap.
    /// Reads what delivery reads (the focused element after Chromium's AXManualAccessibility, settable, the editable
    /// ancestor, the counts), never text. nil: measurable, or a case delivery handles on its own (no Accessibility, COS's
    /// own window, a terminal). One `probe` log line, codes only.
    static func unmeasurableTarget() -> DictationPolishSwap.Unmeasurable? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier, !KnownApps.isTerminal(app.bundleIdentifier) else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        var element = focused(appElement)
        let family = isChromiumFamily(app)
        if family, element.map({ !textCapable($0) }) ?? true {
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            element = focused(appElement)
        }
        if let element { AXUIElementSetMessagingTimeout(element, 0.25) }
        let settable = element.map { textSettable($0) } ?? false
        let ancestor = element.flatMap { editableAncestor($0) }
        let canvas = DictationInsertPolicy.canvasEditor(chromium: family, focused: element != nil, textSettable: settable, editableAncestor: ancestor != nil)
        let baseline = snapshot(settable ? element : (ancestor ?? element))
        let why = DictationPolishSwap.unmeasurable(canvas: canvas, baselineReadable: baseline.readable)
        dictationLog.notice("probe bundle=\(app.bundleIdentifier ?? "-", privacy: .public) family=\(family) settable=\(settable) ancestor=\(ancestor != nil) canvas=\(canvas) before=\(baseline.logDescription, privacy: .public) unmeasurable=\(why?.rawValue ?? "no", privacy: .public)")
        return why
    }

    /// AXNumberOfCharacters and AXSelectedTextRange only. The field's text (AXValue) is never read.
    nonisolated private static func snapshot(_ element: AXUIElement?) -> DictationFieldSnapshot {
        guard let element else { return DictationFieldSnapshot() }
        var result = DictationFieldSnapshot()
        result.characters = (attribute(element, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
        if let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            let ax = value as! AXValue
            var range = CFRange()
            if AXValueGetType(ax) == .cfRange, AXValueGetValue(ax, .cfRange, &range), range.location >= 0, range.length >= 0 {
                result.location = range.location; result.length = range.length
            }
        }
        return result
    }
    /// The element takes text: AXSelectedText or AXValue is settable. A role alone proves nothing (iTerm2).
    nonisolated private static func textSettable(_ element: AXUIElement) -> Bool {
        isSettable(element, kAXSelectedTextAttribute) || isSettable(element, kAXValueAttribute)
    }
    nonisolated private static func textCapable(_ element: AXUIElement) -> Bool {
        textSettable(element) || editableAncestor(element) != nil
    }
    nonisolated private static func editableAncestor(_ element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(element, "AXEditableAncestor"), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    nonisolated private static func isSettable(_ element: AXUIElement, _ key: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, key as CFString, &settable) == .success && settable.boolValue
    }
    nonisolated private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }
    nonisolated private static func focused(_ application: AXUIElement) -> AXUIElement? {
        guard let value = attribute(application, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

/// Learn from my edits (0.5.318, Miles 2026-10-16 13:31). After a measured insertion COS watches ONLY the field it typed
/// into, until focus leaves it or three minutes pass (DictationEditLearning.stop). Twice a second it measures the count
/// and caret, never text; after a 1.5 s pause in a change it reads the same bounded window Replace reads (at most 20
/// reads), diffs it against the last read, and hands an edit inside the dictation to DictationEditLearning.candidate.
/// The window lives in memory for the watch only. Electron editors are probed (what was readable is logged, counts and
/// verdicts only) and never learned from; terminals, secure input and password fields are never watched.
@MainActor final class DictationEditWatcher {
    private var task: Task<Void, Never>?
    private var watching: UUID?
    /// 0.5.344: the running watch's trigger stream (Return, Enter or a click, from the shortcut monitor).
    private var signal: DictationWatchSignal?
    /// 0.5.328: a watch is reading a field now (for the timing line's editWatchAtPress).
    var isWatching: Bool { task != nil }
    /// 0.5.344: the shortcut monitor is installed (only when a lone-modifier trigger such as Fn is set), so Return and
    /// clicks can reach a watch. Set by the store when it installs or removes the monitors; on each canary line.
    var monitor = false
    /// 0.5.342 Your edit, confirmed: the dictation the next watch belongs to, set by the store just before it starts one,
    /// and where every watch's ending goes (DictationWatchEnd). Each run takes its owner when it starts, so an ending
    /// that lands after a newer watch began still names its own dictation.
    var pendingRecord: UUID?
    var finished: (@MainActor @Sendable (DictationWatchEnd) async -> Void)?
    private var nextOwner: (record: UUID?, app: String)?
    func stop(_ why: String) {
        guard let task else { return }
        task.cancel(); self.task = nil; watching = nil
        signal?.close(); signal = nil
        dictationLog.notice("learn stop=\(why, privacy: .public)")
    }
    /// A watch that ended on its own clears only itself, never a newer one.
    private func ended(_ id: UUID) { if watching == id { task = nil; watching = nil; signal = nil } }
    /// 0.5.344: the shortcut monitor heard Return, Enter or a click while this watch runs. One lock and one resume on the
    /// main thread; the read itself runs inside the watch's own task. The event itself goes on untouched.
    func trigger(_ trigger: DictationEditLearning.Trigger) { signal?.fire(trigger) }
    /// 0.5.344: a typed dictation that got no watch writes its canary line too, with the reason (QA W3), off the main thread.
    nonisolated static func skipped(_ reason: String, bundle: String?) {
        guard DictationLearnCanary.recordsSkip(reason) else { return }
        let row = DictationLearnCanary.skipped(reason, bundle: bundle ?? "-", at: Date())
        dictationLog.notice("learn skip-row reason=\(reason, privacy: .public)")
        Task.detached(priority: .utility) { Self.record(row) }
    }
    func start(_ target: DictationInsertTarget, mode: DictationLearnMode, context: DictationFieldContext.Applied? = nil,
               found: @escaping @MainActor @Sendable (DictationEditLearning.Candidate) -> Void) {
        stop("new dictation")
        nextOwner = (pendingRecord, target.app); pendingRecord = nil
        let element = target.element
        // 0.5.338: the bundle id decides for the apps the canary proved (Claude) or has not measured yet (Slack, Cursor, ChatGPT).
        let eligibility = DictationEditLearning.eligibility(mode: mode, secure: DictationInsertion.secure(element), terminal: target.terminal,
                                                            electron: target.electron, chromium: target.chromium, setterWorked: target.setterWorked,
                                                            bundle: target.bundle)
        let facts = "bundle=\(target.bundle ?? "-") electron=\(target.electron) chromium=\(target.chromium) setterWorked=\(target.setterWorked)"
        if case .skip(let reason) = eligibility {
            dictationLog.notice("learn skip=\(reason, privacy: .public) \(facts, privacy: .public)")
            Self.skipped(reason, bundle: target.bundle)
            return
        }
        // 0.5.328: off the main actor. Each read is several Accessibility calls into the other app (0.25 s each at most
        // when it is busy), every 500 ms for up to three minutes; on the main actor they froze the pet, and a press that
        // landed during one waited for it (Miles: 1,052 ms from press to the dictation's own task, 2026-10-19). Only an
        // ending, a learned candidate and the spell check hop to the main actor. 0.5.344: the field's closures are
        // @Sendable (DictationEditWatch.Field), so none of them inherits the main actor from this method. A probe of the
        // same shape (2026-10-24) showed the 0.5.338 to 0.5.343 closures, formed here without @Sendable, ran on the main
        // thread even when awaited from the detached task.
        let pid = target.span.pid
        // 0.5.338: the field, not the element. Claude's composer is re-mounted (an empty composer filling, a first message
        // opening its chat), so the element the watch reads through is rebound when the focus rule says it is the same field.
        let box = AXField(element)
        let field = DictationEditWatch.Field(measure: { DictationInsertion.measure(box.element) },
                                             text: { DictationInsertion.text(box.element, location: $0, length: $1) },
                                             secure: { DictationInsertion.secure(box.element) },
                                             focus: { rebinds in
                                                 if box.identity == nil { box.identity = DictationInsertion.fieldIdentity(box.element, pid: pid) }
                                                 let seen = DictationInsertion.focusedField(pid: pid, watched: box.element)
                                                 let verdict = DictationEditLearning.focus(frontmost: seen.frontmost, sameElement: seen.sameElement, watched: box.identity,
                                                                                           now: seen.identity, sameWindow: seen.sameWindow, rebinds: rebinds)
                                                 if verdict == .rebound, let next = seen.element { box.element = next; box.identity = seen.identity }
                                                 return (verdict, seen.characters)
                                             },
                                             running: { NSRunningApplication(processIdentifier: pid).map { !$0.isTerminated } ?? false })
        run(field, span: target.span, typed: target.text, facts: facts, bundle: target.bundle ?? "-", learning: eligibility == .learn, context: context, found: found)
    }

    /// 0.5.337 (Miles 2026-10-22 21:11): COS's own text view, through the same rules: eligibility (native, so it learns),
    /// the three-minute window, the read cap, the bounded window around the dictation, the debounce and the candidate rule.
    /// It reads the view itself on the main actor (an Accessibility read of this app from itself would wait on its own
    /// main thread). 0.5.338: the same re-anchor and canary line; the view is one object, so it never rebinds.
    func startOwn(_ target: DictationOwnTarget, mode: DictationLearnMode, found: @escaping @MainActor @Sendable (DictationEditLearning.Candidate) -> Void) {
        stop("new dictation")
        nextOwner = (pendingRecord, target.app); pendingRecord = nil
        let eligibility = DictationEditLearning.eligibility(mode: mode, secure: IsSecureEventInputEnabled(), terminal: false,
                                                            electron: false, chromium: false, setterWorked: true)
        let facts = "bundle=own route=ownWindow"
        if case .skip(let reason) = eligibility {
            dictationLog.notice("learn skip=\(reason, privacy: .public) \(facts, privacy: .public)")
            Self.skipped(reason, bundle: "com.gotcos.control")
            return
        }
        let box = OwnView(target.view)
        let field = DictationEditWatch.Field(measure: { await MainActor.run { box.view.map { DictationOwnField.snapshot(text: $0.string, selection: $0.selectedRange()) } ?? DictationFieldSnapshot() } },
                                             text: { location, length in await MainActor.run { box.view.flatMap { DictationOwnField.read($0.string, location: location, length: length) } } },
                                             secure: { IsSecureEventInputEnabled() },
                                             focus: { _ in
                                                 let held = await MainActor.run { box.view.map { NSApp.isActive && $0.window?.firstResponder === $0 } ?? false }
                                                 return (held ? .same : .left("app"), nil)
                                             },
                                             running: { await MainActor.run { box.view != nil } })
        run(field, span: target.span, typed: target.text, facts: facts, bundle: "com.gotcos.control", learning: eligibility == .learn, context: nil, found: found)
    }

    final class OwnView: @unchecked Sendable {
        weak var view: NSTextView?
        init(_ view: NSTextView?) { self.view = view }
    }
    /// 0.5.338: the element a watch reads through, and the field identity it was taken for. Touched only by the one watch
    /// task, one call at a time (the watch makes every read itself, a trigger's included: 0.5.344).
    final class AXField: @unchecked Sendable {
        var element: AXUIElement
        var identity: DictationEditLearning.FieldIdentity?
        init(_ element: AXUIElement) { self.element = element }
    }

    private func run(_ field: DictationEditWatch.Field, span: DictationInsertedSpan, typed: String, facts: String, bundle: String, learning: Bool,
                     context: DictationFieldContext.Applied?, found: @escaping @MainActor @Sendable (DictationEditLearning.Candidate) -> Void) {
        let id = UUID()
        watching = id
        let owner = nextOwner, finished = self.finished, monitor = self.monitor
        nextOwner = nil
        // 0.5.344: this watch's own trigger stream, raced against its poll timer inside the watch.
        let signal = DictationWatchSignal()
        self.signal = signal
        let clock = DictationEditWatch.Clock(now: { ProcessInfo.processInfo.systemUptime }, wall: { Date() }, pause: { await signal.pause($0) })
        let consider: DictationEditWatch.Consider = { edit, window, start, length in
            await Self.consider(edit, window: window, start: start, length: length, context: context)
        }
        task = Task.detached(priority: .utility) { [weak self] in
            let started = Date()
            let ending = await DictationEditWatch.run(field, span: span, typed: typed, facts: facts, bundle: bundle, learning: learning, monitor: monitor,
                                                      clock: clock, log: { dictationLog.notice("\($0, privacy: .public)") }, consider: consider,
                                                      found: found, sink: { Self.record($0) })
            await self?.ended(id)
            if let finished, let owner {
                await finished(DictationWatchEnd(recordID: owner.record, app: owner.app, typed: typed, finalText: ending.final,
                                                 inside: ending.tail.sawInside, started: started, candidates: ending.tail.candidates))
            }
        }
    }

    /// 0.5.323: the field outside the dictation, in this read and in the one before typing, is evidence; an edit that
    /// undoes a spelling COS took from the field is not a pair to learn.
    nonisolated private static func consider(_ edit: DictationReplace.Edit, window: String, start: Int, length: Int,
                                             context: DictationFieldContext.Applied?) async -> DictationEditLearning.Candidate? {
        let outside = DictationEditLearning.outside(window: window, start: start, length: length) + (context?.outside ?? [])
        guard let candidate = await MainActor.run(body: { DictationEditWatcher.candidate(edit, outside: outside) }) else { return nil }
        return DictationEditLearning.undoesContextFix(candidate, fixes: context?.fixes ?? []) ? nil : candidate
    }
    /// 0.5.338: the watch's counts-only canary line, next to the timing file.
    nonisolated private static func record(_ canary: DictationLearnCanary) {
        guard let url = MacDictationStore.defaultHistoryURL()?.deletingLastPathComponent().appendingPathComponent(DictationLearnCanaryLog.fileName) else { return }
        DictationLearnCanaryLog.append(canary, to: url)
    }
    /// The tested rule, with the spell checker asked only about the edit's own words and the dictionary read once.
    static func candidate(_ edit: DictationReplace.Edit, outside: [String]) -> DictationEditLearning.Candidate? {
        let edge = CharacterSet.punctuationCharacters.union(.symbols)
        let tokens = (edit.original + " " + edit.replacement).split(whereSeparator: \.isWhitespace)
            .flatMap { [String($0), String($0).trimmingCharacters(in: edge)] }
        let english = Set(tokens.filter { !$0.isEmpty && NSSpellChecker.shared.checkSpelling(of: $0, startingAt: 0).location == NSNotFound })
        let corrections = TranscriptionDictionaryStore.shared.corrections
        return DictationEditLearning.candidate(edit, known: { english.contains($0) }, learned: { heard, written in
            corrections.contains { DictationFixGuess.normalized($0.heard) == DictationFixGuess.normalized(heard) && $0.written == written }
        }, outside: outside)
    }
}

/// 0.5.331: when the dictated field last changed (its count or caret), measured off the main actor every 100 ms while
/// AI polish works, so a swap waits for a quiet moment. Counts and the caret only, never text.
final class DictationFieldQuiet: @unchecked Sendable {
    private let last = OSAllocatedUnfairLock(initialState: ProcessInfo.processInfo.systemUptime)
    private var task: Task<Void, Never>?
    init(_ target: DictationInsertTarget) {
        let last = self.last
        task = Task.detached(priority: .utility) {
            let element = target.element
            var previous = DictationInsertion.measure(element)
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(DictationPolishSwap.quietPollMilliseconds))
                let now = DictationInsertion.measure(element)
                if now != previous { previous = now; last.withLock { $0 = ProcessInfo.processInfo.systemUptime } }
            }
        }
    }
    var sinceChangeMs: Int { DictationStartMarks.ms(last.withLock { $0 }, ProcessInfo.processInfo.systemUptime) }
    func stop() { task?.cancel(); task = nil }
}

/// System Audio Recording through TCC, the way Apple's AudioCap sample reads and asks for it (0.5.318). macOS lists an
/// app under System Audio Recording Only only once that app has asked and the person answered, and Queen's Mac had no
/// COS Control row at all: nothing ever asked. A tap alone does not ask either (Apple: the prompt comes "the first
/// time you start recording from an aggregate device that contains a tap"), so the request is TCCAccessRequest, the
/// call AudioCap makes. The routing around it is SystemAudioAsk; ControllerModel.requestSystemAudio is the one caller.
enum SystemAudioPermission {
    private static let path = "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC"
    private static let service = "kTCCServiceAudioCapture"

    /// TCCAccessPreflight's answer, or nil when the SPI is missing. Never shows anything.
    nonisolated static var preflight: Int32? {
        guard let handle = dlopen(path, RTLD_NOW), let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
        return unsafeBitCast(symbol, to: Preflight.self)(service as CFString, nil)
    }
    nonisolated static var fact: SystemAudioFact { SystemAudioFact(preflight: preflight) }

    /// macOS's own prompt, answered by the person. False when the SPI is missing, when macOS answers no without asking
    /// (it was answered before), or when no answer comes within `timeout`, so a caller can never hang on it. Asked from
    /// the main actor, as AudioCap asks from its button.
    @MainActor static func request(timeout: Duration = .seconds(90)) async -> Bool {
        guard let handle = dlopen(path, RTLD_NOW), let symbol = dlsym(handle, "TCCAccessRequest") else {
            dictationLog.error("system audio: TCCAccessRequest not found")
            return false
        }
        typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) @Sendable (Bool) -> Void) -> Void
        let answered = OSAllocatedUnfairLock(initialState: false)
        let claim: @Sendable () -> Bool = { answered.withLock { done in defer { done = true }; return !done } }
        let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            unsafeBitCast(symbol, to: Request.self)(service as CFString, nil) { granted in
                if claim() { continuation.resume(returning: granted) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if claim() { continuation.resume(returning: false) }
            }
        }
        dictationLog.notice("system audio: asked, granted=\(granted, privacy: .public) preflight=\(preflight ?? -1, privacy: .public)")
        return granted
    }
}

/// Quiet while dictating (0.5.313, Miles 22:06: "mute the rest of the sound playing through the speakers when dictation
/// mode is running ... as soon as you're done it picks back up"). Without System Audio Recording, COS lowers the default
/// output's volume instead and saves the exact scalar first, on disk too, so a quit or crash in between is put back at
/// the next launch. `end()` is safe to call any time.
///
/// Mute (0.5.315): 0.5.313 created a global process tap with muteBehavior .muted and never read it; Miles's Spotify kept
/// playing at full level while the log said "muted". Apple's headers do not say a tap mutes only while it is read (the
/// CATapMuted text is "Audio is captured by the tap but no audio is sent from the process to the audio hardware"), so
/// this is built exactly as Apple's tap sample uses a tap and logs what each step returned, plus the callbacks and the
/// peak the tap delivered, so one test with music playing settles which it was. The steps (DictationMuteTap, tested):
/// the tap (COS excluded, so its own start and stop sounds still play), its UID, a PRIVATE aggregate device clocked by
/// the default output that lists the tap, an IOProc that measures the tapped audio and outputs silence, and the IO
/// running. Tap auto-start stays off: its header says AudioDeviceStart then "will wait until a tapped process begins
/// receiving its first audio", and this runs on the main actor. A crash cannot leave apps muted: the tap is private
/// ("only visible to the client process that created the tap") and so is the aggregate ("private to the process that
/// created it ... not persistent across launches"), and the HAL drops a client's objects with its connection.
///
/// 0.5.328: not on the main actor. Every call arrives on DictationAudioQueues.output, in the order the store made it
/// (DictationQuietHandle): building and starting the mute took 1.1 to 2.2 s on Miles's Mac, and on the main actor that
/// froze the pet and the pill just as LISTENING appeared. `lastTimes` splits that cost for the timing line.
final class DictationQuietController: @unchecked Sendable {
    private static let pendingKey = "dictation.quiet.pending"
    private struct Mute {
        let id = UUID()
        var built = DictationMuteTap.Built()
        var tap = AudioObjectID(kAudioObjectUnknown)
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        var ioProc: AudioDeviceIOProcID?
        var listener: AudioObjectPropertyListenerBlock?
        let outputUID: String
        let meter = DictationMuteMeter()
    }
    private var mute: Mute?
    private var lowered: (device: AudioObjectID, pending: DictationQuiet.Pending)?
    /// One line for Settings when the last Mute could not mute and COS lowered the volume instead; nil once it mutes.
    private(set) var fallbackNote: String?
    /// The last begin's build and start, in milliseconds.
    private(set) var lastTimes = DictationQuietTimes()

    func begin(mode: DictationQuietMode, macRecording: Bool) {
        end()
        lastTimes = DictationQuietTimes()
        let device = Self.defaultOutput()
        let volume = device.flatMap { Self.volume($0) }
        let settable = device.map { Self.volumeSettable($0) } ?? false
        var plan = DictationQuiet.plan(mode: mode, macRecording: macRecording, tapPermitted: Self.tapPermitted,
                                       volume: volume, volumeSettable: settable)
        if plan == .muteTap, !muteOtherApps() {
            plan = DictationQuiet.plan(mode: mode, macRecording: macRecording, tapPermitted: false, volume: volume, volumeSettable: settable)
        }
        switch plan {
        case .leave(let reason): dictationLog.notice("quiet: left alone (\(reason, privacy: .public))")
        case .muteTap: break  // muteOtherApps logged "other apps muted" once the IO was running
        case .lowerVolume(let target):
            guard let device, let volume, let uid = Self.uid(device) else { return }
            let pending = DictationQuiet.Pending(deviceUID: uid, saved: volume, lowered: target)
            // On disk BEFORE the change, so no exit path can lose the volume to put back.
            if let data = try? JSONEncoder().encode(pending) { UserDefaults.standard.set(data, forKey: Self.pendingKey) }
            if Self.setVolume(device, target) {
                lowered = (device, pending)
                dictationLog.notice("quiet: output lowered")
            } else {
                UserDefaults.standard.removeObject(forKey: Self.pendingKey)
            }
        }
    }

    /// Listening ended (stop, fail, cancel, quit, sleep): unmute and put the volume back.
    func end() {
        if let session = mute {
            mute = nil
            if let listener = session.listener {
                var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DictationAudioQueues.output, listener)
            }
            let report = Self.tearDown(session)
            let reading = session.meter.reading()
            dictationLog.notice("quiet: other apps unmuted \(report, privacy: .public) callbacks=\(reading.callbacks, privacy: .public) tapPeak=\(reading.peak, format: .fixed(precision: 4), privacy: .public)")
        }
        if let lowered {
            self.lowered = nil
            if let value = DictationQuiet.restoreVolume(saved: lowered.pending.saved, lowered: lowered.pending.lowered,
                                                        current: Self.volume(lowered.device)) {
                _ = Self.setVolume(lowered.device, value)
            }
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
            dictationLog.notice("quiet: output restored")
        }
    }

    /// Launch: a lowered volume a quit or crash never put back goes back on the device it was taken from.
    func restoreAfterInterruptedRun() {
        guard let data = UserDefaults.standard.data(forKey: Self.pendingKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        guard let pending = try? JSONDecoder().decode(DictationQuiet.Pending.self, from: data),
              let device = Self.device(uid: pending.deviceUID) else { return }
        if let value = DictationQuiet.launchRestore(pending, current: Self.volume(device)) {
            _ = Self.setVolume(device, value)
            dictationLog.notice("quiet: restored the output volume an interrupted dictation lowered")
        }
    }

    /// System Audio Recording, through TCC's preflight (the check Apple's AudioCap sample uses). Unknown reads as no,
    /// which only means COS lowers the volume instead of muting.
    nonisolated static var tapPermitted: Bool { SystemAudioPermission.fact == .allowed }

    private func muteOtherApps() -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        guard let output = Self.defaultOutput(), let outputUID = Self.uid(output) else {
            dictationLog.error("quiet: mute failed step=output (no default output); lowering the volume instead")
            fallbackNote = Self.note(permission: false); return false
        }
        let began = ContinuousClock.now
        let own = Self.ownProcessObject()
        // Without COS's own object the tap would mute the start sound too: say so (QA 2026-10-15).
        if own.isEmpty { dictationLog.notice("quiet: COS's own audio object not found; its sounds may be muted too") }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: own)
        description.name = "COS dictation quiet"
        description.isPrivate = true
        description.muteBehavior = .muted
        var session = Mute(outputUID: outputUID)
        var tapUID = ""
        var statuses: [String] = []
        let result = DictationMuteTap.build { step in
            let status: OSStatus
            switch step {
            case .tap:
                status = AudioHardwareCreateProcessTap(description, &session.tap)
            case .tapUID:
                let uid = Self.string(session.tap, kAudioTapPropertyUID)
                tapUID = uid ?? ""
                status = uid == nil ? kAudioHardwareUnknownPropertyError : noErr
            case .aggregate:
                let composition: [String: Any] = [
                    kAudioAggregateDeviceNameKey: "COS dictation quiet",
                    kAudioAggregateDeviceUIDKey: "com.gotcos.dictation-quiet.\(session.id.uuidString)",
                    kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                    kAudioAggregateDeviceIsPrivateKey: true,
                    kAudioAggregateDeviceIsStackedKey: false,
                    kAudioAggregateDeviceTapAutoStartKey: false,
                    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
                ]
                status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &session.aggregate)
            case .ioProc:
                status = AudioDeviceCreateIOProcIDWithBlock(&session.ioProc, session.aggregate, nil, DictationMuteIO.silence(session.meter))
            case .start:
                let starting = ContinuousClock.now
                status = AudioDeviceStart(session.aggregate, session.ioProc)
                lastTimes = DictationQuietTimes(buildMs: Int((starting - began) / .milliseconds(1)),
                                                startMs: Int((ContinuousClock.now - starting) / .milliseconds(1)))
            }
            statuses.append("\(step.rawValue)=\(status)")
            // A noErr that handed back no object is a failure too, or teardown would act on kAudioObjectUnknown.
            if status == noErr, step == .tap, session.tap == kAudioObjectUnknown { return kAudioHardwareBadObjectError }
            if status == noErr, step == .aggregate, session.aggregate == kAudioObjectUnknown { return kAudioHardwareBadObjectError }
            if status == noErr, step == .ioProc, session.ioProc == nil { return kAudioHardwareIllegalOperationError }
            return status
        }
        session.built = result.built
        let elapsed = Int((ContinuousClock.now - began) / .milliseconds(1))
        if let failure = result.failure {
            let report = Self.tearDown(session)
            dictationLog.error("quiet: mute failed step=\(failure.step.rawValue, privacy: .public) status=\(failure.status, privacy: .public) [\(statuses.joined(separator: " "), privacy: .public)] teardown [\(report, privacy: .public)] output=\(outputUID, privacy: .public); lowering the volume instead")
            // Apple: the system asks for System Audio Recording "the first time you start recording from an aggregate
            // device that contains a tap", so a refused start is the step permission most plausibly blocks.
            fallbackNote = Self.note(permission: failure.step == .start)
            return false
        }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        let listener = Self.outputListener(self)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DictationAudioQueues.output, listener) == noErr { session.listener = listener }
        mute = session; fallbackNote = nil
        let playing = Self.playingProcesses(excluding: own)
        dictationLog.notice("quiet: other apps muted [\(statuses.joined(separator: " "), privacy: .public)] subTaps=\(Self.subTapCount(session.aggregate), privacy: .public) running=\(Self.isRunning(session.aggregate), privacy: .public) playing=\(playing.count, privacy: .public) \(playing.joined(separator: ","), privacy: .public) output=\(outputUID, privacy: .public) ms=\(elapsed, privacy: .public)")
        // One second in: did the HAL call the IOProc, and did the tap carry audio? callbacks=0 means the IO never ran;
        // tapPeak=0 with music playing means the tap is not receiving it.
        let id = session.id, aggregate = session.aggregate, meter = session.meter
        DictationAudioQueues.output.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.mute?.id == id else { return }
            let reading = meter.reading()
            dictationLog.notice("quiet: muted 1s callbacks=\(reading.callbacks, privacy: .public) tapPeak=\(reading.peak, format: .fixed(precision: 4), privacy: .public) subTaps=\(Self.subTapCount(aggregate), privacy: .public) running=\(Self.isRunning(aggregate), privacy: .public)")
        }
        return true
    }
    private static func note(permission: Bool) -> String {
        permission ? "Last time COS couldn't mute other apps, so it lowered the volume instead. Check System Audio Recording for COS Control."
                   : "Last time COS couldn't mute other apps, so it lowered the volume instead."
    }
    /// The reverse of what was built (DictationMuteTap.teardown, tested), every status logged.
    private static func tearDown(_ session: Mute) -> String {
        DictationMuteTap.teardown(session.built).map { step in
            let status: OSStatus
            switch step {
            case .stop: status = AudioDeviceStop(session.aggregate, session.ioProc)
            case .destroyIOProc: status = session.ioProc.map { AudioDeviceDestroyIOProcID(session.aggregate, $0) } ?? noErr
            case .destroyAggregate: status = AudioHardwareDestroyAggregateDevice(session.aggregate)
            case .destroyTap:
                if #available(macOS 14.2, *) { status = AudioHardwareDestroyProcessTap(session.tap) } else { status = noErr }
            }
            return "\(step.rawValue)=\(status)"
        }.joined(separator: " ")
    }
    /// Built outside any actor: the HAL calls it on DictationAudioQueues.output (0.5.328; it was `.main`), the queue the
    /// controller lives on, so it calls straight in.
    nonisolated private static func outputListener(_ controller: DictationQuietController) -> AudioObjectPropertyListenerBlock {
        { @Sendable [weak controller] _, _ in
            dispatchPrecondition(condition: .onQueue(DictationAudioQueues.output))
            controller?.defaultOutputChanged()
        }
    }
    /// See DictationMuteTap.keepOnOutputChange: a new default output ends the mute (the aggregate is clocked by the old
    /// one); dictation carries on with other apps audible.
    private func defaultOutputChanged() {
        guard let session = mute else { return }
        let now = Self.defaultOutput().flatMap { Self.uid($0) }
        guard !DictationMuteTap.keepOnOutputChange(mutedOn: session.outputUID, now: now) else { return }
        dictationLog.notice("quiet: default output changed from \(session.outputUID, privacy: .public) to \(now ?? "none", privacy: .public); ending the mute")
        end()
    }
    /// Bundle IDs of the other processes playing audio right now: what the global tap should be covering.
    nonisolated private static func playingProcesses(excluding own: [AudioObjectID]) -> [String] {
        var address = address(kAudioHardwarePropertyProcessObjectList, scope: kAudioObjectPropertyScopeGlobal)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.filter { !own.contains($0) }.compactMap { object in
            var running = UInt32(0); var length = UInt32(MemoryLayout<UInt32>.size)
            var key = Self.address(kAudioProcessPropertyIsRunningOutput, scope: kAudioObjectPropertyScopeGlobal)
            guard AudioObjectGetPropertyData(object, &key, 0, nil, &length, &running) == noErr, running != 0 else { return nil }
            return string(object, kAudioProcessPropertyBundleID) ?? "process-\(object)"
        }
    }
    /// Header: kAudioAggregateDevicePropertySubTapList is "all the active sub-taps in the aggregate device".
    nonisolated private static func subTapCount(_ aggregate: AudioObjectID) -> Int {
        var address = address(kAudioAggregateDevicePropertySubTapList, scope: kAudioObjectPropertyScopeGlobal)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(aggregate, &address, 0, nil, &size) == noErr else { return -1 }
        return Int(size) / MemoryLayout<AudioObjectID>.size
    }
    nonisolated private static func isRunning(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyDeviceIsRunning, scope: kAudioObjectPropertyScopeGlobal)
        var running = UInt32(0); var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
    }
    /// COS's own audio object (it exists once the start sound has been scheduled), so its sounds are never muted.
    nonisolated private static func ownProcessObject() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject, scope: kAudioObjectPropertyScopeGlobal)
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown); var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? [object] : []
    }
    nonisolated private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    nonisolated private static func defaultOutput() -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioObjectID(kAudioObjectUnknown); var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }
    nonisolated private static func volume(_ device: AudioObjectID) -> Float? {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        var value = Float32(0); var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
    nonisolated private static func volumeSettable(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        var settable = DarwinBoolean(false)
        return AudioObjectHasProperty(device, &address) && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }
    nonisolated private static func setVolume(_ device: AudioObjectID, _ value: Float) -> Bool {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        var scalar = Float32(min(1, max(0, value)))
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar) == noErr
    }
    nonisolated private static func uid(_ device: AudioObjectID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }
    nonisolated private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector, scope: kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    nonisolated private static func device(uid: String) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice, scope: kAudioObjectPropertyScopeGlobal)
        var cfUID = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown); var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }
}

/// The focused window's frame in Cocoa screen coordinates, read through Accessibility (nil without it).
/// 0.5.328: the store's handle on DictationQuietController. Each call is queued, in order, on
/// DictationAudioQueues.output and returns at once; `begin`'s `done` comes back on the main actor with the fallback
/// note and the times. The main actor never waits on the mute, except `flush` at quit, so the volume a lowered dictation
/// saved is put back before COS Control exits.
@MainActor final class DictationQuietHandle {
    private let controller = DictationQuietController()
    func begin(mode: DictationQuietMode, macRecording: Bool,
               done: (@MainActor @Sendable (_ note: String?, _ totalMs: Int, _ times: DictationQuietTimes) -> Void)? = nil) {
        let controller = controller
        DictationAudioQueues.output.async {
            let began = ProcessInfo.processInfo.systemUptime
            controller.begin(mode: mode, macRecording: macRecording)
            let total = DictationStartMarks.ms(began, ProcessInfo.processInfo.systemUptime)
            let note = controller.fallbackNote, times = controller.lastTimes
            if let done { Task { @MainActor in done(note, total, times) } }
        }
    }
    func end() {
        let controller = controller
        DictationAudioQueues.output.async { controller.end() }
    }
    func restoreAfterInterruptedRun() {
        let controller = controller
        DictationAudioQueues.output.async { controller.restoreAfterInterruptedRun() }
    }
    /// Quit: wait for every queued begin and end (and the sounds) to finish.
    func flush() { DictationAudioQueues.output.sync {} }
}

enum DictationFocusedWindow {
    /// What the lookup needs from AppKit, read on the main actor: the frontmost app and the primary screen's top.
    struct Lookup: Sendable { let pid: pid_t; let primaryMaxY: CGFloat }
    @MainActor static func lookup() -> Lookup? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              let primary = NSScreen.screens.first?.frame else { return nil }
        return Lookup(pid: app.processIdentifier, primaryMaxY: primary.maxY)
    }
    @MainActor static func frame() -> CGRect? { lookup().flatMap { frame($0) } }
    /// Accessibility only (three calls, 0.25 s each at most when the app is busy), so dictation runs it off the main
    /// thread (0.5.328).
    static func frame(_ lookup: Lookup) -> CGRect? {
        let element = AXUIElementCreateApplication(lookup.pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let window = value, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let ax = window as! AXUIElement
        var position = CGPoint.zero, size = CGSize.zero
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXPositionAttribute as CFString, &raw) == .success, let p = raw,
              CFGetTypeID(p) == AXValueGetTypeID(), AXValueGetValue(p as! AXValue, .cgPoint, &position) else { return nil }
        raw = nil
        guard AXUIElementCopyAttributeValue(ax, kAXSizeAttribute as CFString, &raw) == .success, let z = raw,
              CFGetTypeID(z) == AXValueGetTypeID(), AXValueGetValue(z as! AXValue, .cgSize, &size) else { return nil }
        // Accessibility measures from the top-left of the primary screen; Cocoa from its bottom-left.
        return CGRect(x: position.x, y: lookup.primaryMaxY - position.y - size.height, width: size.width, height: size.height)
    }
}

/// Dictation's start and stop sounds, through a small output-only AVAudioEngine so the person's Pitch applies to every
/// sound, their own file included, without changing its length (AVAudioUnitTimePitch). Playback is scheduled and never
/// waited on; this engine has no input, so it never touches the dictation microphone.
///
/// The start sound is NOT trimmed from the recording and the microphone is NOT delayed for it: either would cost the
/// first words of someone who starts talking as they press. The stop sound plays only after the microphone has closed.
/// Speech models ignore a short non-speech tone; a person who hears it in a transcript can lower the volume or turn it
/// off (0). 0.5.327: the start sound plays when the microphone's first buffer arrives (it used to play on the press, up
/// to a second before COS could hear), so it now tells the truth and sits at the very start of the recording, before
/// the speech it invites. Tests/dictation-start-canary.py sends the pinned speech sample with the start sound mixed in
/// at its front through the real engine and requires the same words as without it.
///
/// 0.5.328: not on the main actor. Every call arrives on DictationAudioQueues.output (opening the file and starting the
/// output engine took up to about 250 ms on Miles's Mac, during which the pet could not move).
final class DictationSoundPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private var format: AVAudioFormat?
    /// 0.5.313: the newest sound. Its end stops the engine; an older sound's end (stopped by a newer one) does nothing.
    private var playID = 0
    init() { engine.attach(node); engine.attach(pitch) }
    func play(_ url: URL, volume: Float, semitones: Double) {
        guard let file = try? AVAudioFile(forReading: url) else { return }
        if format != file.processingFormat {
            engine.stop()
            engine.disconnectNodeOutput(node); engine.disconnectNodeOutput(pitch)
            engine.connect(node, to: pitch, format: file.processingFormat)
            engine.connect(pitch, to: engine.mainMixerNode, format: file.processingFormat)
            format = file.processingFormat
        }
        pitch.pitch = Float(DictationSoundLibrary.cents(semitones))
        node.volume = max(0, min(1, volume))
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch { dictationLog.error("sound output unavailable: \(error.localizedDescription, privacy: .public)"); return }
        }
        node.stop()
        playID &+= 1
        let id = playID
        // 0.5.313: the engine stops when the sound has played. It was left running after the first start or stop sound,
        // so an idle Mac kept an output stream open (an audio IO thread here and render work in coreaudiod) for as long as
        // COS Control ran.
        node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack, completionHandler: Self.playedBack(self, id: id))
        node.play()
    }
    /// 0.5.314: AVAudioPlayerNode calls this on its own completion queue. A closure written inside this @MainActor
    /// class inherits main-actor isolation, and Swift 6 checks that on entry: 0.5.313 trapped (EXC_BREAKPOINT in
    /// dispatch_assert_queue) the moment a start or stop sound finished. Built here, outside any actor, the closure
    /// carries no isolation and only hops to the output queue the player lives on (0.5.328; it hopped to the main actor).
    private nonisolated static func playedBack(_ owner: DictationSoundPlayer, id: Int) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { [weak owner] _ in
            guard let owner else { return }
            DictationAudioQueues.output.async { owner.finished(id) }
        }
    }
    /// For the runtime check (run-dictation-sound-runtime.sh): true while a sound plays, false once its end stopped it.
    var isRunning: Bool { engine.isRunning }
    private func finished(_ id: Int) {
        guard DictationSoundPlayer.stopsAfter(finished: id, newest: playID), engine.isRunning else { return }
        node.stop(); engine.stop()
    }
    /// Only the newest sound's end stops the engine.
    nonisolated static func stopsAfter(finished: Int, newest: Int) -> Bool { finished == newest }
}

/// A chosen file, decoded to mono, with where its sound begins and ends; `window` is what Save keeps.
struct DictationSoundImport {
    let edge: DictationSoundEdge
    let sourceName: String
    let samples: [Float]
    let sampleRate: Double
    let duration: Double
    let onset: Double
    let end: Double
    /// Stop sounds may use the end of the file (the default for Stop).
    var useEnd: Bool
    var window: DictationSoundTrim.Window {
        useEnd ? DictationSoundTrim.stopWindow(end: end, duration: duration) : DictationSoundTrim.startWindow(onset: onset, duration: duration)
    }
    var trimmedWAV: Data {
        DictationSoundTrim.wav(DictationSoundTrim.apply(samples, sampleRate: sampleRate, window: window), sampleRate: Int(sampleRate.rounded()))
    }
    /// "Keeps 0.30-2.30 s (2.00 s of 8.76 s)"
    var summary: String {
        String(format: "Keeps %.2f-%.2f s (%.2f s of %.2f s)", window.start, window.end, window.length, duration)
    }
}

/// Decodes any audio file AVAudioFile reads (MP3, M4A, WAV, AIFF...) to mono floats at its own sample rate.
enum DictationAudioDecode {
    static func mono(_ url: URL) -> (samples: [Float], sampleRate: Double)? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              file.length <= AVAudioFramePosition(file.processingFormat.sampleRate * 600) else { return nil }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        do { try file.read(into: buffer) } catch { return nil }
        guard let channels = buffer.floatChannelData, format.channelCount > 0 else { return nil }
        let count = Int(buffer.frameLength), channelCount = Int(format.channelCount)
        var out = [Float](repeating: 0, count: count)
        for channel in 0..<channelCount {
            let data = channels[channel]
            for i in 0..<count { out[i] += data[i] / Float(channelCount) }
        }
        return (out, format.sampleRate)
    }
}

/// A pasteboard behind DictationPasteboardAccess (NSPasteboard.general in the app). Items are read once, on first use.
/// Not actor-isolated so it can satisfy the plain protocol; DictationInsertion only uses it on the main actor.
final class SystemDictationPasteboard: DictationPasteboardAccess {
    private let pasteboard: NSPasteboard
    init(_ pasteboard: NSPasteboard) { self.pasteboard = pasteboard }
    private lazy var items: [NSPasteboardItem] = pasteboard.pasteboardItems ?? []
    var changeCount: Int { pasteboard.changeCount }
    func itemTypes() -> [[String]] { items.map { $0.types.map(\.rawValue) } }
    func data(item: Int, type: String) -> Data? {
        items.indices.contains(item) ? items[item].data(forType: NSPasteboard.PasteboardType(type)) : nil
    }
    func replace(with saved: [DictationClipboardItem]) -> Bool {
        let rebuilt = saved.map { item -> NSPasteboardItem in
            let next = NSPasteboardItem()
            for entry in item.entries { next.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type)) }
            return next
        }
        pasteboard.clearContents()
        return rebuilt.isEmpty || pasteboard.writeObjects(rebuilt)
    }
    func writeTranscript(_ text: String, markerTypes: [String]) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return false }
        for type in markerTypes { item.setData(Data(), forType: NSPasteboard.PasteboardType(type)) }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}

private let dictationHotKeySignature: OSType = 0x434F5344 // COSD, separate from Activity COSH
private let dictationHotKeyHandler: EventHandlerUPP = { _, event, _ in
    guard let event else { return noErr }
    var id = EventHotKeyID()
    guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                            MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr, id.signature == dictationHotKeySignature else { return OSStatus(eventNotHandledErr) }
    let kind = UInt32(GetEventKind(event))
    let key = id.id
    Task { @MainActor in MacDictationStore.shared.hotKey(key, down: kind == UInt32(kEventHotKeyPressed)) }
    return noErr
}

/// What a spare build on DictationAudioQueues.input came back with (0.5.328), and the microphone list when it read one.
enum DictationSpareBuild: Sendable {
    case none([DictationMicrophone]?)
    case keep([DictationMicrophone]?)
    case built(DictationMicrophoneCapture, DictationSpare.Warmed, [DictationMicrophone]?)
}

/// 0.5.328: the main thread's heartbeat while a dictation starts (DictationStallMeter): a 16 ms timer on the main run
/// loop in the common modes, from the press until three seconds after LISTENING or until the microphone closes.
@MainActor final class DictationMainHeartbeat {
    private var timer: Timer?
    private var meter: DictationStallMeter?
    func begin(at pressed: TimeInterval) {
        timer?.invalidate()
        let meter = DictationStallMeter(start: pressed)
        self.meter = meter
        let timer = Timer(timeInterval: Double(DictationStallMeter.tickMilliseconds) / 1000, repeats: true) { timer in
            if !meter.tick(ProcessInfo.processInfo.systemUptime) { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func listening(at uptime: TimeInterval) { meter?.end(at: uptime + DictationStallMeter.afterListeningSeconds) }
    /// Stops the beat; the longest gap in ms, nil when none was running.
    func finish() -> Int? {
        timer?.invalidate(); timer = nil
        defer { meter = nil }
        return meter?.maxGapMs
    }
}

@MainActor final class MacDictationStore: ObservableObject {
    static let shared = MacDictationStore()
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "dictation.enabled"); if !enabled { cancel() }; registerHotKeys() } }
    @Published var microphoneUID: String {
        didSet { UserDefaults.standard.set(microphoneUID, forKey: "dictation.microphoneUID"); spare = nil; prepareSpare() }
    }
    /// 0.5.312 sounds: "pet", "library:<id>" or "custom:<file>" for each edge, and a volume (0 is off).
    @Published var soundStart: String = UserDefaults.standard.string(forKey: "dictation.sound.start") ?? "pet" {
        didSet { UserDefaults.standard.set(soundStart, forKey: "dictation.sound.start") }
    }
    @Published var soundStop: String = UserDefaults.standard.string(forKey: "dictation.sound.stop") ?? "pet" {
        didSet { UserDefaults.standard.set(soundStop, forKey: "dictation.sound.stop") }
    }
    @Published var soundVolume: Double = UserDefaults.standard.object(forKey: "dictation.sound.volume") as? Double ?? DictationSoundLibrary.defaultVolume {
        didSet { UserDefaults.standard.set(soundVolume, forKey: "dictation.sound.volume") }
    }
    @Published var soundPitch: Double = UserDefaults.standard.object(forKey: "dictation.sound.pitch") as? Double ?? 0 {
        didSet { UserDefaults.standard.set(soundPitch, forKey: "dictation.sound.pitch") }
    }
    @Published private(set) var soundNote: String?
    /// Your own file, decoded and measured, waiting for Save.
    @Published private(set) var pendingImport: DictationSoundImport?
    /// Set by the app: which family the pet is (its default sound), and whether a COS recording is capturing.
    var petKind: (() -> DictationPetKind)?
    /// The shipped pack installed now (DictationSoundLibrary.installedPack), for the Jedi Miles Windu saber.
    var petPack: (() -> String?)?
    var macRecordingActive: (() -> Bool)?
    /// 0.5.317: what a failure card's one action does (ControllerModel, wired in COSControlApp). Install Parakeet and
    /// Open Transcription settings act in COS; Use Whisper sets the Dictation engine, then retries the held audio.
    var installParakeet: (() -> Void)?
    var useWhisper: (@MainActor () async -> Bool)?
    var openTranscriptionSettings: (() -> Void)?
    /// 0.5.318: Accessibility and System Audio Recording through the permission guide (ControllerModel, wired in
    /// COSControlApp). The closure runs once the grant is seen. nil in a check build, which then asks macOS directly.
    var requestAccessibility: ((@escaping @MainActor () -> Void) -> Void)?
    var resetAccessibility: ((@escaping @MainActor () -> Void) -> Void)?
    /// `wantsPane`: the person asked to see the setting itself. True once System Audio Recording is allowed.
    var requestSystemAudio: (@MainActor (_ wantsPane: Bool) async -> Bool)?
    /// The server version a dictation succeeded on, for the setup guide's Voice row (DictationProof).
    var serverVersion: (() -> String?)?
    /// The screen the floating pill uses, chosen when dictation starts (the focused window's screen).
    @Published private(set) var floatingScreen: CGRect?
    private let soundPlayer = DictationSoundPlayer()
    /// 0.5.312: put the person's clipboard back after a ⌘V COS posted (Wispr Flow does). On unless turned off.
    @Published var restoreClipboard: Bool = UserDefaults.standard.object(forKey: "dictation.restoreClipboard") as? Bool ?? true {
        didSet { UserDefaults.standard.set(restoreClipboard, forKey: "dictation.restoreClipboard") }
    }
    /// 0.5.318 Learn from my edits: Save automatically (Miles's default), Suggest only, or Off. Off stops any watch now.
    @Published var learnMode: DictationLearnMode = DictationLearnMode(rawValue: UserDefaults.standard.string(forKey: "dictation.learnMode") ?? "") ?? .default {
        didSet { UserDefaults.standard.set(learnMode.rawValue, forKey: "dictation.learnMode"); if learnMode == .off { editWatcher.stop("learning off") } }
    }
    /// What Learn from my edits suggested (kept a week) and saved on its own (kept 30 days, with Undo). On this Mac only.
    @Published private(set) var suggestions = DictationSuggestions.State()
    private let editWatcher = DictationEditWatcher()
    private var suggestionsURL: URL?
    /// 0.5.318: "number one, … number two, …" and "bullet, …" become a numbered or bulleted list (DictationListFormat).
    @Published var formatLists: Bool = UserDefaults.standard.object(forKey: "dictation.formatLists") as? Bool ?? true {
        didSet { UserDefaults.standard.set(formatLists, forKey: "dictation.formatLists") }
    }
    /// 0.5.323: read the words already in the text box before typing, to spell names and terms the way it has them.
    @Published var useFieldContext: Bool = UserDefaults.standard.object(forKey: "dictation.fieldContext") as? Bool ?? true {
        didSet { UserDefaults.standard.set(useFieldContext, forKey: "dictation.fieldContext") }
    }
    /// 0.5.325 AI polish: Claude cleans the heard text before COS pastes it (DictationPolish). Off unless chosen.
    @Published var polishModel: DictationPolishModel = DictationPolishModel.stored(UserDefaults.standard.string(forKey: DictationPolishModel.defaultsKey)) {
        didSet { UserDefaults.standard.set(polishModel.rawValue, forKey: DictationPolishModel.defaultsKey) }
    }
    /// 0.5.331 paste first, polish in place: with AI polish on, type what was heard at once and swap Claude's version in
    /// place when it is ready (DictationPolishSwap). On unless turned off; off is the order before 0.5.331.
    @Published var pasteThenPolish: Bool = DictationPolishSwap.stored(UserDefaults.standard.object(forKey: DictationPolishSwap.defaultsKey)) {
        didSet { UserDefaults.standard.set(pasteThenPolish, forKey: DictationPolishSwap.defaultsKey) }
    }
    /// Claude's version of a dictation whose swap was skipped, for Apply polished in Activity, Dictation. Memory only.
    @Published private(set) var pendingPolish: [UUID: DictationPendingPolish] = [:]
    /// The last Apply polished's one line, on that dictation's row.
    @Published private(set) var polishNote: (id: UUID, text: String)?
    @Published private(set) var microphones: [DictationMicrophone] = []
    @Published private(set) var holdTrigger: DictationTrigger?
    @Published private(set) var toggleTrigger: DictationTrigger?
    /// 0.5.313: Fix last dictation, ⌃⌥F unless the person changed or turned it off.
    @Published private(set) var fixTrigger: DictationTrigger?
    /// The dictation the pill's Fix opens, for DictationQuickFix.offerSeconds after the flash.
    @Published private(set) var fixOfferID: UUID?
    /// 0.5.338: what Learn from my edits just saved, while its pill offers Undo.
    @Published private(set) var learnedUndoID: UUID?
    private var learnedUndoPill: DictationPill?
    /// Undo shows only on that "✓ LEARNED" flash: any later pill (a new dictation) has none.
    var pillUndoID: UUID? { pill == learnedUndoPill ? learnedUndoID : nil }
    /// 0.5.342 Your edit, confirmed: the dictation "✓ EDIT SAVED" opens with View, only on that flash. Set before the pill,
    /// so the overlay's pill sink reads it (no sink of its own).
    private var editViewID: UUID?
    private var editViewPill: DictationPill?
    var pillViewID: UUID? { pill == editViewPill ? editViewID : nil }
    /// Learn from my edits saves still running, which a watch's ending waits for.
    private var learnSaves: [Task<Void, Never>] = []
    /// Opens Activity, Dictation history (View when the pet is not showing). Set by the app.
    var openHistory: (() -> Void)?
    /// After Save in Fix a word: put the corrected dictation back where COS inserted it, or copy it.
    @Published private(set) var replaceOffer: DictationReplaceOffer?
    /// While dictating: mute other apps (default), lower other audio, or off (0.5.313).
    @Published var quietMode: DictationQuietMode = DictationQuietMode(rawValue: UserDefaults.standard.string(forKey: "dictation.quiet") ?? "") ?? .default {
        didSet { UserDefaults.standard.set(quietMode.rawValue, forKey: "dictation.quiet") }
    }
    /// Settings' one line when the last Mute fell back to lowering the volume (0.5.315); the log has the failed step.
    @Published private(set) var quietNote: String?
    @Published private(set) var phase = "Off"
    @Published private(set) var message: String?
    /// 0.5.337 (loop audit W4): the server paused AI polish (daily_cap or breaker_open); Settings says so under AI polish.
    @Published private(set) var polishPause: String?
    /// 0.5.309: the listening pill. It replaces the pet's ledger row only while it is not hidden, then hands it back.
    @Published private(set) var pill: DictationPill = .hidden
    /// Where this dictation shows, decided when it starts: on the pet, or (pet hidden) a pill above the Dock.
    @Published private(set) var surface: DictationSurface = .pet
    /// The short-lived card: no text box (mock 04), or a dictation that did not finish.
    @Published private(set) var card: DictationCard?
    /// Dictation history, newest first, decoded once and kept in memory; on disk as long as `retention` says, never more
    /// than 5,000 (0.5.312). The pet shows the first 10 (`petRecent`); COS Activity shows them all.
    @Published private(set) var recent: [DictationRecord]
    var petRecent: [DictationRecord] { Array(recent.prefix(DictationHistory.petCount)) }
    /// Settings → Keep dictations for. 30 days by default. Changing it prunes now; "Don't keep" is set through
    /// `stopKeepingHistory()` after the person confirms.
    @Published private(set) var retention: DictationRetention
    /// Which dictation view is open: the pet's list, one dictation, or Fix a word.
    @Published private(set) var listRoute: DictationListRoute?
    @Published private(set) var fixSelection: ClosedRange<Int>?
    @Published var fixDraft = ""
    @Published private(set) var fixNote: String?
    @Published private(set) var fixSaving = false
    /// What the first tap pre-filled from the dictionary, so a later tap may replace it.
    private var fixSuggestion: String?
    /// Where the latest dictations landed, measured, for Replace it in <App>. Memory only; the newest few.
    private var insertTargets: [UUID: DictationInsertTarget] = [:]
    private let quiet = DictationQuietHandle()
    /// Levels for the bars. Its own object, so a 20 Hz meter redraws the pill and never the whole pet.
    let meter = DictationMeterFeed()
    var bridge: (@MainActor (Data) async throws -> HelperResponse)?
    /// 0.5.325: the helper's `dictation-polish`, given the request and the whole wait (DictationPolish.budget).
    var polishBridge: (@MainActor (Data, TimeInterval) async throws -> HelperResponse)?
    /// 0.5.329: the helper's dictation-polish-prewarm (start or discard AI polish's process early). Sendable and not tied
    /// to the main actor: it is called only from detached tasks, never awaited at the press.
    var prewarmBridge: (@Sendable (Data) async throws -> HelperResponse)?
    /// The press's early polish: its dictation, the model it was started for, where its answer lands, and the task.
    private var prewarm: (attempt: UUID, model: DictationPolishModel, box: DictationPrewarmBox, task: Task<Void, Never>)?
    /// The server version that answered "unsupported" (an older server): no early polish against it until it changes.
    private var prewarmUnsupportedOn: String?
    var petFrame: (() -> NSRect?)?
    private var capture: DictationMicrophoneCapture?
    private var pendingAudio: Data? { didSet { if pendingAudio == nil { pendingInterrupted = false; interruptedChangeCount = nil } } }
    /// The clipboard as it stood when listening was interrupted; a copy made since is never overwritten by the salvage.
    private var interruptedChangeCount: Int?
    /// The held audio is from an interrupted dictation: a retry copies it too, never types it.
    private var pendingInterrupted = false
    /// 0.5.313 (QA): someone clicked while holding the key. No speech then means a modifier-click, not a failed dictation.
    private var pointerDuringHold = false
    var canRetry: Bool { pendingAudio != nil && !busy }
    /// The engine the latest answer named, kept until finish() stores it with the record.
    private var lastEngine: (engine: String, fallback: String?)?
    /// 0.5.325: what was heard and which model polished it, only when AI polish changed the text; kept until finish().
    private var lastPolish: (heard: String, model: DictationPolishModel)?
    /// 0.5.344 (server 6.91.0): the prompt that applied polish used, v3 or v4, for the record's card label.
    private var lastPolishPrompt: String?
    /// 0.5.331: a delivery is typing into an app, and an automatic swap is editing one. Never both at once.
    private var deliveryInFlight = false
    private var swapEditing = false
    /// 0.5.331: the person's stop (systemUptime), for the timing line's releaseToFirstTextMs.
    private var releasedAt: TimeInterval?
    private var task: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private var cardTask: Task<Void, Never>?
    private var levelMeter = DictationLevelMeter()
    private let historyURL: URL?
    private let overlay = DictationOverlayPresenter()
    private var sessionObservers: [NSObjectProtocol] = []
    private var handler: EventHandlerRef?
    private var registrations: [EventHotKeyRef] = []
    /// Lone-modifier triggers (Fn, Right ⌘…) read key events; Carbon cannot register a modifier by itself.
    private var keyMonitors: [Any] = []
    private var holdTracker: LoneModifierTracker?
    private var toggleTracker: LoneModifierTracker?
    private var fixTracker: LoneModifierTracker?
    private var held = false
    private var toggleHeld = false
    private var holdPending = false
    private var generation = UUID()
    /// 0.5.326 release tail: listening continues for DictationReleaseTail.milliseconds after the person's stop.
    private var tailing = false
    private var tailTask: Task<Void, Never>?
    /// When and where (bytes captured) the person stopped, and the tail it took. Cleared when the microphone closes.
    private var releaseMark: (uptime: TimeInterval, bytes: Int, tailMs: Int)?
    /// This dictation's numbers (DictationTiming), written once it is typed, copied or fails.
    private var timing: DictationTiming?
    /// 0.5.327: the press's timeline (DictationStartMarks) until the timing line takes it.
    private var startMarks: DictationStartMarks?
    /// 0.5.327: the next dictation's engine, built off the press and never started (DictationSpare), and what it was built against.
    private var spare: (capture: DictationMicrophoneCapture, warmed: DictationSpare.Warmed)?
    private var spareTask: Task<Void, Never>?
    /// 0.5.328: the pill's placement (Accessibility off the main thread) and the main thread's heartbeat.
    private var placing: Task<Void, Never>?
    /// 0.5.330: the hold key's watch (DictationHoldWatch) and the STILL FINISHING note's timer.
    private var holdWatch: Task<Void, Never>?
    private var finishingTask: Task<Void, Never>?
    /// The keyboard has shown this press's hold key down at least once (the missed-release rules trust an "up" only then).
    private var holdSeenDown = false
    /// macOS's 🌐 key setting at the last check (DictationFnUsage), and whether a missed release or chord this dictation
    /// should end with the card that says how to fix it.
    private var fnUsageType: Int?
    private var fnCardPending = false
    /// The app version on each press event line.
    private static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    private let heartbeat = DictationMainHeartbeat()
    var busy: Bool { ["Listening", "Starting", "Transcribing"].contains(phase) }
    private init() {
        let d = UserDefaults.standard
        let on = d.bool(forKey: "dictation.enabled")
        enabled = on
        microphoneUID = d.string(forKey: "dictation.microphoneUID") ?? ""
        func load(_ prefix: String) -> DictationTrigger? {
            guard d.bool(forKey: prefix + ".enabled") else { return nil }
            return DictationTrigger.load(kind: d.string(forKey: prefix + ".kind"), key: d.integer(forKey: prefix + ".key"), modifiers: d.integer(forKey: prefix + ".modifiers"))
        }
        let hold = load("dictation.hold"), toggle = load("dictation.toggle")
        holdTrigger = hold; toggleTrigger = toggle
        // Never stored: ⌃⌥F, unless that is already Push to talk, Start / stop or Open Activity.
        let activityTrigger = HotKeyCombo.load().map { DictationTrigger.keys(keyCode: $0.keyCode, modifiers: $0.modifiers) }
        var others: [DictationShortcutSlot: DictationTrigger] = [:]
        if let hold { others[.hold] = hold }
        if let toggle { others[.toggle] = toggle }
        fixTrigger = d.object(forKey: "dictation.fix.enabled") == nil
            ? (DictationShortcuts.conflicts(DictationShortcuts.defaultFix, slot: .fix, assigned: others, activity: activityTrigger) ? nil : DictationShortcuts.defaultFix)
            : load("dictation.fix")
        phase = on ? "Ready" : "Off"
        // A history file that does not read is moved aside before anything can be saved over it (0.5.310); when it
        // cannot be moved, this run keeps its dictations in memory only.
        let history = Self.defaultHistoryURL()
        let loaded = history.map { DictationHistory.loadOrQuarantine(from: $0, now: Date()) }
        historyURL = loaded?.writable == false ? nil : history
        // Prune on launch: older than the retention, past the 5,000 cap; "Don't keep" leaves nothing on disk.
        // From a local: a @Published property cannot be read before every stored property is set (Swift 6 init order).
        let keep = DictationRetention(rawValue: d.string(forKey: "dictation.history.retention") ?? "") ?? .default
        retention = keep
        let kept = DictationHistory.pruned(loaded?.records ?? [], retention: keep, now: Date())
        recent = keep.writesToDisk ? kept : []
        let suggestionFile = history?.deletingLastPathComponent().appendingPathComponent("dictation-suggestions.json")
        suggestionsURL = suggestionFile
        suggestions = suggestionFile.map { DictationSuggestions.load(from: $0, now: Date()) } ?? DictationSuggestions.State()
        if let aside = loaded?.movedTo { dictationLog.notice("recent dictations unreadable; moved aside to \(aside.lastPathComponent, privacy: .public)") }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            sessionObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.interrupt() }
            })
        }
        overlay.bind(store: self)
        editWatcher.finished = { [weak self] end in await self?.editWatchEnded(end) }
        if recent.count != (loaded?.records.count ?? 0) || !retention.writesToDisk { saveRecent() }
        // A volume COS lowered and never put back (a quit or crash mid-dictation) goes back now.
        quiet.restoreAfterInterruptedRun()
    }
    /// ~/Library/Application Support/COS Control/dictation-history.json. A check run writes under its own test home,
    /// and perf fixtures write nothing, so no check can touch the real history.
    nonisolated static func defaultHistoryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let home = environment["COS_CONTROL_TEST_HOME"] { return URL(fileURLWithPath: home).appendingPathComponent("dictation-history.json") }
        guard environment["COS_PERF_FIXTURES"] == nil else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/COS Control/dictation-history.json")
    }
    func refreshMicrophones() { microphones = DictationAudioDevices.inputs() }
    /// The cached list as UID to device id, for DictationStart.resolve.
    private var microphoneIDs: [String: AudioDeviceID] { Dictionary(microphones.map { ($0.id, $0.deviceID) }, uniquingKeysWith: { first, _ in first }) }
    /// 0.5.327: builds the next dictation's engine a moment after the microphone closes (or dictation turns on), so the
    /// press only starts it. Never while a microphone is open, never for a Bluetooth input, never before the microphone
    /// is allowed; the spare's input is never started here (DictationSpare).
    func prepareSpare(after delay: Duration = .seconds(1)) {
        spareTask?.cancel()
        spareTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.capture == nil, !self.busy else { return }
            await self.warmSpare()
        }
    }
    /// 0.5.328: the list read (a chosen microphone) and the engine build run on DictationAudioQueues.input; the main
    /// actor only reads three settings before and stores the result after.
    private func warmSpare() async {
        let selected = microphoneUID, enabled = enabled
        let authorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let held = spare?.warmed
        let built: DictationSpareBuild
        do {
            built = try await DictationAudioQueues.perform(on: DictationAudioQueues.input) { () throws -> DictationSpareBuild in
                var list: [DictationMicrophone]?
                var deviceID: AudioDeviceID?
                if !selected.isEmpty {
                    list = DictationAudioDevices.inputs()
                    guard let id = list?.first(where: { $0.id == selected })?.deviceID else { return .none(list) }
                    deviceID = id
                }
                guard let device = deviceID ?? DictationAudioDevices.defaultInput(),
                      DictationSpare.mayWarm(enabled: enabled, authorized: authorized, bluetooth: DictationAudioDevices.isBluetooth(device)) else { return .none(list) }
                let now = ProcessInfo.processInfo.systemUptime
                if let held, DictationSpare.check(held, selectedUID: selected, device: device,
                                                  sampleRate: DictationAudioDevices.nominalSampleRate(device), bluetooth: false, now: now) == .use { return .keep(list) }
                // The device's own rate, compared again at the press (the input node's format can differ from it and still
                // work: measured 2026-10-19, an AT2020USB+ at 16 kHz with the node reporting 48 kHz).
                guard let rate = DictationAudioDevices.nominalSampleRate(device) else { return .none(list) }
                let next = DictationMicrophoneCapture()
                try next.warm(deviceID: deviceID)
                return .built(next, DictationSpare.Warmed(device: device, selectedUID: selected, sampleRate: rate, at: now), list)
            }
        } catch {
            spare = nil
            dictationLog.notice("spare engine not built: \(error.localizedDescription, privacy: .public)"); return
        }
        switch built {
        case .none(let list): spare = nil; if let list { microphones = list }
        case .keep(let list): if let list { microphones = list }
        case .built(let next, let warmed, let list): spare = (next, warmed); if let list { microphones = list }
        }
    }
    /// The press: the spare, only while nothing it was built against has changed (DictationSpare.check). Taken once.
    private func takeSpare(device: AudioDeviceID?) -> DictationMicrophoneCapture? {
        guard let held = spare else { return nil }
        spare = nil
        let verdict = DictationSpare.check(held.warmed, selectedUID: microphoneUID, device: device,
                                           sampleRate: device.flatMap { DictationAudioDevices.nominalSampleRate($0) },
                                           bluetooth: device.map { DictationAudioDevices.isBluetooth($0) } ?? true,
                                           now: ProcessInfo.processInfo.systemUptime)
        if case .discard(let why) = verdict { dictationLog.notice("spare engine discarded: \(why, privacy: .public)"); return nil }
        return held.capture
    }
    /// 0.5.330: one event line for a press that did not become a dictation, or a reconciled release. Numbers, codes and
    /// the hold key's state only; never text or audio.
    private func recordPressEvent(_ event: DictationPressEvent, msSincePress: Int? = nil, firstBufferArrived: Bool? = nil, reconcileSource: String? = nil) {
        var line = DictationTiming.event(event, at: Date())
        line.reconcileSource = reconcileSource
        if fnIsDictationKey, fnUsageChecked { line.fnUsageType = fnUsageType ?? -1 }
        line.phase = phase; line.msSincePress = msSincePress; line.firstBufferArrived = firstBufferArrived
        line.appVersion = Self.appVersion
        line.held = held; line.holdTrackerDown = holdTracker?.down; line.holdHardwareDown = holdKeyHardwareDown()
        let hardware = line.holdHardwareDown.map { $0 ? "down" : "up" } ?? "-"
        dictationLog.notice("press event=\(event.rawValue, privacy: .public) phase=\(self.phase, privacy: .public) held=\(self.held) hardware=\(hardware, privacy: .public)")
        if let url = Self.defaultHistoryURL()?.deletingLastPathComponent().appendingPathComponent(DictationTimingLog.fileName) {
            DictationTimingLog.append(line, to: url)
        }
    }
    /// A press while the last dictation is still transcribing or polishing: STILL FINISHING for a moment, then the pill
    /// it replaced. Nothing is queued: the press is refused, and says so.
    private func noteStillFinishing() {
        message = "Still finishing the last dictation."
        guard pill == .transcribing || pill == .polishing || pill == .finishing else { return }
        let previous = pill == .finishing ? (finishingReturn ?? .transcribing) : pill
        finishingReturn = previous
        pill = .finishing
        finishingTask?.cancel()
        finishingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(DictationPill.finishingSeconds))
            guard let self, !Task.isCancelled, self.pill == .finishing else { return }
            self.pill = previous
        }
    }
    private var finishingReturn: DictationPill?
    /// The hold key as the keyboard reports it (CGEventSource, the HID system state): nil when there is no hold key.
    private func holdKeyHardwareDown() -> Bool? {
        switch holdTrigger {
        case .modifier(let key)?: DictationHoldWatch.modifierDown(flags: CGEventSource.flagsState(.hidSystemState).rawValue, keyCode: key)
        case .keys(let key, _)?: CGEventSource.keyState(.hidSystemState, key: CGKeyCode(key))
        case nil: nil
        }
    }
    /// While COS believes the hold key is down, read the keyboard every 150 ms; two "up" reads after one "down" run the
    /// release COS missed.
    private func ensureHoldWatch() {
        guard holdWatch == nil, holdTrigger != nil,
              DictationHoldWatch.watches(phase: phase, held: held, trackerDown: holdTracker?.down == true) else { return }
        holdWatch = Task { [weak self] in
            var reads = DictationHoldWatch.Reads()
            while let self, !Task.isCancelled,
                  DictationHoldWatch.watches(phase: self.phase, held: self.held, trackerDown: self.holdTracker?.down == true),
                  let down = self.holdKeyHardwareDown() {
                if down { self.holdSeenDown = true }
                if reads.read(down: down) { self.reconcileRelease(source: "poll"); break }
                try? await Task.sleep(for: .milliseconds(DictationHoldWatch.pollMilliseconds))
            }
            self?.holdWatch = nil
        }
    }
    /// The release COS never heard: the same path as a real key-up, and the tracker forgets the press.
    private func reconcileRelease(source: String) {
        let wasHeld = held
        recordPressEvent(.releaseReconciled, reconcileSource: source)
        holdTracker?.reset(); holdSeenDown = false
        if fnConflictNow { fnCardPending = true }
        if wasHeld { hotKey(1, down: false) }
    }
    /// 0.5.330: macOS's own 🌐 key setting, read at launch and on every Fn press, logged when it changes.
    private func checkFnUsage() {
        guard fnIsDictationKey else { return }
        let value = (CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? NSNumber)?.intValue
        if value != fnUsageType || !fnUsageChecked {
            dictationLog.notice("fn usage: AppleFnUsageType=\(value.map(String.init) ?? "absent", privacy: .public) conflict=\(DictationFnUsage.conflicts(usageType: value, fnIsDictationKey: true))")
        }
        fnUsageType = value; fnUsageChecked = true
    }
    private var fnUsageChecked = false
    private var fnIsDictationKey: Bool { holdTrigger?.isFn == true || toggleTrigger?.isFn == true }
    private var fnConflictNow: Bool { fnUsageChecked && DictationFnUsage.conflicts(usageType: fnUsageType, fnIsDictationKey: fnIsDictationKey) }
    /// 0.5.330 (team lead, from Miles's 2026-10-19 lock): at the moment Fn is pressed while macOS still gives the 🌐 key a
    /// job of its own, say so: the card once per run of COS Control (after start(), which clears cards), and a log line on
    /// every such press. A missed release later in the same run brings the card back when that dictation ends.
    private func warnFnAtPress() {
        guard holdTrigger?.isFn == true, fnConflictNow else { return }
        dictationLog.notice("fn usage: pressed with AppleFnUsageType=\(self.fnUsageType.map(String.init) ?? "absent", privacy: .public); macOS may take the release")
        guard !fnWarnedThisRun, card == nil else { return }
        fnWarnedThisRun = true
        fnCardPending = true
        showFnCardIfPending()
    }
    private var fnWarnedThisRun = false
    /// After a dictation whose Fn release was missed (or that a chord cut short): the card that says why, unless another
    /// card is already showing.
    private func showFnCardIfPending() {
        guard fnCardPending else { return }
        fnCardPending = false
        guard fnConflictNow, card == nil else { return }
        showCard(DictationCard(kind: .failed(DictationFnUsage.note, action: .openKeyboardSettings), recordID: nil, text: "",
                               countdown: DictationCountdown(start: Date())))
    }
    /// 0.5.329 (server 6.79.2): ask the server to start AI polish's process for this press. Only with AI polish on, and
    /// not against a server that said it cannot. The answer lands in a box the polish reads later; nothing awaits it here.
    private func startPrewarm(_ attempt: UUID) {
        discardPrewarm()
        let model = polishModel
        guard DictationPolishPrewarm.shouldStart(model: model, unsupportedOn: prewarmUnsupportedOn, serverVersion: serverVersion?()),
              let bridge = prewarmBridge, let request = DictationPolishPrewarm.startRequest(model: model) else { return }
        let box = DictationPrewarmBox()
        let task = Task.detached(priority: .utility) {
            let response = try? await bridge(request)
            box.set(DictationPolishPrewarm.read(ok: response?.ok, token: response?.details["prewarmToken"]?.string,
                                                reason: response?.details["reason"]?.string, elapsedMs: response?.details["elapsedMs"]?.int))
        }
        prewarm = (attempt, model, box, task)
    }
    /// The polish takes this press's token, waiting at most 150 ms for a start still in flight. A token for another model
    /// (the setting changed mid-hold) or one that arrives late is discarded, never reused.
    /// 0.5.331: only this press's token. A newer press's (a paste-first polish runs after the next press may have
    /// started its own) is left for that press.
    private func takePrewarm(_ model: DictationPolishModel, attempt: UUID) async -> (token: String?, ms: Int?) {
        guard let held = prewarm, held.attempt == attempt else { return (nil, nil) }
        prewarm = nil
        guard held.model == model else { Self.discardWhenReady(held.task, held.box, prewarmBridge); return (nil, nil) }
        var waited = 0
        while held.box.result == nil, waited < DictationPolishPrewarm.waitMilliseconds {
            try? await Task.sleep(for: .milliseconds(DictationPolishPrewarm.pollMilliseconds))
            waited += DictationPolishPrewarm.pollMilliseconds
        }
        guard let result = held.box.result else { Self.discardWhenReady(held.task, held.box, prewarmBridge); return (nil, nil) }
        if result == .unsupported { prewarmUnsupportedOn = serverVersion?() ?? "" }
        return (result.token, result.ms)
    }
    /// A token no polish will use (cancel, no text, polish off): discarded off the main actor once its start has answered.
    private func discardPrewarm(_ attempt: UUID? = nil) {
        guard let held = prewarm, attempt.map({ $0 == held.attempt }) ?? true else { return }
        prewarm = nil
        Self.discardWhenReady(held.task, held.box, prewarmBridge)
    }
    private nonisolated static func discardWhenReady(_ task: Task<Void, Never>, _ box: DictationPrewarmBox, _ bridge: (@Sendable (Data) async throws -> HelperResponse)?) {
        guard let bridge else { return }
        Task.detached(priority: .utility) {
            await task.value
            guard let token = box.result?.token, let request = DictationPolishPrewarm.discardRequest(token: token) else { return }
            _ = try? await bridge(request)
        }
    }
    /// 0.5.328: a start number measured after the fact on the output queue: onto the press's marks while they are held,
    /// else onto this dictation's open timing line; dropped once the line is written or a newer dictation began.
    private func lateMarks(_ attempt: UUID, _ apply: (inout DictationStartMarks) -> Void) {
        guard generation == attempt else { return }
        if startMarks != nil { apply(&startMarks!); return }
        guard timing != nil else { return }
        var late = DictationStartMarks(pressed: 0)
        apply(&late)
        if let v = late.soundMs { timing?.soundMs = v }
        if let v = late.quietMs { timing?.quietMs = v }
        if let v = late.quietBuildMs { timing?.quietBuildMs = v }
        if let v = late.quietStartMs { timing?.quietStartMs = v }
    }
    /// 0.5.327: STARTING waits here for the microphone's first buffer, the moment COS can truly hear the person.
    private func awaitFirstAudio(_ capture: DictationMicrophoneCapture, attempt: UUID) async -> DictationStart.FirstAudio {
        let deadline = ProcessInfo.processInfo.systemUptime + Double(DictationStart.firstBufferTimeoutMs) / 1000
        while generation == attempt, !Task.isCancelled {
            if let at = capture.firstAudioUptime { return .arrived(at) }
            if capture.failure != nil { return .failed }
            if ProcessInfo.processInfo.systemUptime >= deadline { return .timedOut }
            try? await Task.sleep(for: .milliseconds(DictationStart.pollMs))
        }
        return .superseded
    }
    /// Allow… (the pet's card and Settings). 0.5.317 only raised macOS's prompt, which shows nothing once COS Control
    /// has a row in the Accessibility list (Queen: the row read ON, this copy was not trusted, the button did nothing).
    /// Now it is the guide's drag flow, as the pet jump uses: the exact pane, the bar holding this copy, and the card
    /// goes once the grant is seen.
    func requestInsertionPermission() {
        guard let ask = requestAccessibility else {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            if !AXIsProcessTrusted(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        ask { [weak self] in self?.insertionAllowed() }
    }
    /// Reset (the card), for a row that reads ON while this copy is not trusted: Reset and add again.
    func resetInsertionPermission() {
        guard let reset = resetAccessibility else { requestInsertionPermission(); return }
        reset { [weak self] in self?.insertionAllowed() }
    }
    /// The grant landed: the card that asked for it has done its job.
    private func insertionAllowed() {
        dictationLog.notice("insertion: Accessibility allowed")
        if case .copied(.notTrusted) = card?.kind { dismissCard() }
    }
    /// Mute other apps' Allow and the fallback note's Check (0.5.318): ControllerModel.requestSystemAudio, which asks
    /// macOS first and opens the drag flow only when macOS will not ask again.
    func requestSystemAudioPermission(wantsPane: Bool = false) async -> Bool {
        if let ask = requestSystemAudio { return await ask(wantsPane) }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
        return DictationQuietController.tapPermitted
    }
    func trigger(_ slot: DictationShortcutSlot) -> DictationTrigger? {
        switch slot {
        case .hold: holdTrigger
        case .toggle: toggleTrigger
        case .fix: fixTrigger
        }
    }
    private var assignedShortcuts: [DictationShortcutSlot: DictationTrigger] {
        var out: [DictationShortcutSlot: DictationTrigger] = [:]
        for slot in DictationShortcutSlot.allCases { if let bound = trigger(slot) { out[slot] = bound } }
        return out
    }
    /// True when the Activity shortcut would collide with any dictation shortcut.
    func uses(_ combo: HotKeyCombo) -> Bool {
        assignedShortcuts.values.contains(DictationTrigger.keys(keyCode: combo.keyCode, modifiers: combo.modifiers))
    }
    func setShortcut(_ trigger: DictationTrigger?, slot: DictationShortcutSlot, activity: HotKeyCombo?) {
        guard !busy else { message = "Finish dictating before changing a shortcut."; return }
        let activityTrigger = activity.map { DictationTrigger.keys(keyCode: $0.keyCode, modifiers: $0.modifiers) }
        guard !DictationShortcuts.conflicts(trigger, slot: slot, assigned: assignedShortcuts, activity: activityTrigger) else {
            message = "That shortcut is already used by COS. Choose a different one."; return
        }
        let prefix = slot.defaultsPrefix
        let d = UserDefaults.standard
        d.set(trigger != nil, forKey: prefix + ".enabled")
        if let stored = trigger?.stored {
            d.set(stored.kind, forKey: prefix + ".kind"); d.set(stored.key, forKey: prefix + ".key"); d.set(stored.modifiers, forKey: prefix + ".modifiers")
        }
        switch slot {
        case .hold: holdTrigger = trigger
        case .toggle: toggleTrigger = trigger
        case .fix: fixTrigger = trigger
        }
        message = nil; registerHotKeys()
        if trigger?.isFn == true, message == nil {
            message = "Fn is set. In System Settings, Keyboard, set “Press 🌐 key to” Do Nothing, and move Wispr Flow off Fn."
        }
    }
    func registerHotKeys() {
        registrations.forEach { UnregisterEventHotKey($0) }; registrations.removeAll()
        keyMonitors.forEach { NSEvent.removeMonitor($0) }; keyMonitors.removeAll()
        editWatcher.monitor = false
        holdTracker = nil; toggleTracker = nil; fixTracker = nil
        guard enabled else { phase = "Off"; return }
        if handler == nil {
            var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)), EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let status = InstallEventHandler(GetApplicationEventTarget(), dictationHotKeyHandler, 2, &events, nil, &handler)
            if status != noErr {
                handler = nil
                dictationLog.error("hot key handler install failed: \(status)")
                message = "Dictation shortcuts could not be set up (error \(status)). Turn dictation off and on to retry."
            }
        }
        let activity = HotKeyCombo.load()
        for slot in DictationShortcutSlot.allCases {
            let number = slot.hotKeyID
            switch trigger(slot) {
            case nil: continue
            case .modifier(let key)?:
                switch slot {
                case .hold: holdTracker = LoneModifierTracker(keyCode: key)
                case .toggle: toggleTracker = LoneModifierTracker(keyCode: key)
                case .fix: fixTracker = LoneModifierTracker(keyCode: key)
                }
            case .keys(let key, let modifiers)?:
                if let activity, activity.keyCode == key, activity.modifiers == modifiers {
                    message = "Dictation shortcut conflicts with Open Activity. Choose another shortcut."; continue
                }
                var ref: EventHotKeyRef?
                if RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: dictationHotKeySignature, id: number), GetApplicationEventTarget(), 0, &ref) == noErr, let ref { registrations.append(ref) }
                else { dictationLog.error("shortcut \(number) unavailable"); message = "Shortcut is unavailable. Another app may already use it. Choose another one." }
            }
        }
        if holdTracker != nil || toggleTracker != nil || fixTracker != nil {
            // Monitors run on the main thread in event order; never hop through a Task, which could reorder down/up.
            // A click right after the modifier goes down (⌥-click, ⌘-click) is a chord, so the monitors take clicks too;
            // a later click (placing the cursor, dragging a window) is ignored and listening continues. keyCode is read
            // only from key events: NSEvent raises on a mouse event's keyCode.
            // 0.5.344: the same events, observed only, also reach a running Learn from my edits watch: Return, Enter or a
            // click asks it for one read now. Nothing is held, swallowed or posted; isARepeat is read from key-downs only.
            let handle: (NSEvent) -> Void = { [weak self] event in
                let flags = event.type == .flagsChanged, isKey = flags || event.type == .keyDown
                let key = isKey ? event.keyCode : 0, raw = UInt64(event.modifierFlags.rawValue), time = event.timestamp
                let down = event.type == .keyDown, again = down && event.isARepeat
                MainActor.assumeIsolated {
                    self?.editTrigger(keyDown: down, keyCode: key, isRepeat: again, pointer: !isKey)
                    self?.keyEvent(flags: flags, pointer: !isKey, keyCode: key, raw: raw, at: time)
                }
            }
            let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handle) { keyMonitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { handle($0); return $0 }) { keyMonitors.append(local) }
            editWatcher.monitor = !keyMonitors.isEmpty
            if !AXIsProcessTrusted() {
                message = "Fn and single-key shortcuts need Accessibility. Click Allow insertion into other apps…, then turn dictation off and on."
            }
        }
        // 0.5.330: the 🌐 key's own job in macOS, checked when the shortcuts are set (launch included).
        checkFnUsage()
        if fnConflictNow, message == nil { message = DictationFnUsage.note }
        // The first spare waits for launch to settle; it also takes the one-time cost of loading the audio components.
        if !busy { phase = "Ready"; prepareSpare(after: .seconds(5)) }
    }
    /// 0.5.344: Return or Enter (any modifier, not its auto-repeat) or a click, while a watch runs with learning on, asks
    /// that watch for one read now (DictationEditLearning.trigger). It never means sent and never changes the event.
    private func editTrigger(keyDown: Bool, keyCode: UInt16, isRepeat: Bool, pointer: Bool) {
        guard let trigger = DictationEditLearning.trigger(keyDown: keyDown, keyCode: keyCode, isRepeat: isRepeat, pointer: pointer,
                                                          watching: editWatcher.isWatching, learning: learnMode != .off) else { return }
        editWatcher.trigger(trigger)
    }
    private func keyEvent(flags: Bool, pointer: Bool, keyCode: UInt16, raw: UInt64, at time: TimeInterval) {
        // A click while the hold key is down: if nothing was said, a slow ⌥-click or ⌘-click must not end in a card.
        if pointer, held { pointerDuringHold = true }
        // Only the HOLD key talks while the mouse works. A lone-modifier toggle or Fix shortcut acts on a clean tap, so
        // any click while its key is down is a chord there, as before 0.5.313 (QA: a slow ⌘-click on a Right ⌘
        // toggle started or stopped dictation).
        func feed(_ tracker: inout LoneModifierTracker?, clickWindow: Bool = false) -> LoneModifierTracker.Output? {
            guard var current = tracker else { return nil }
            let output = flags ? current.flagsChanged(keyCode: keyCode, flags: raw, at: time)
                : pointer && clickWindow ? current.pointerDown(at: time) : current.keyDown()
            tracker = current; return output
        }
        // 0.5.330: a key typed long after the press while the keyboard says the hold key is up is the release COS
        // missed (Miles 2026-10-19, Fn), not a chord: it ends the dictation and types it.
        if !flags, !pointer, let tracker = holdTracker, tracker.down,
           DictationHoldWatch.keyDownIsMissedRelease(trackerDown: true, hardwareDown: holdKeyHardwareDown(), seenDown: holdSeenDown,
                                                     sincePress: time - tracker.pressedAt) {
            reconcileRelease(source: "key")
        }
        switch feed(&holdTracker, clickWindow: true) {
        case .pressed?: hotKey(1, down: true)
        case .released?: hotKey(1, down: false)
        // Fn+arrow, ⌘C: the press was a chord. Right after the press nothing was said, so it is dropped quietly; after
        // a second of talking, what was said is transcribed and copied (interrupt).
        case .chord?: if held { recordPressEvent(.interruptedChord); if fnConflictNow { fnCardPending = true }; interrupt() }
        case nil: break
        }
        // 0.5.330: while COS believes the hold key is down, the keyboard's own state is read too (missed releases).
        if holdTracker?.down == true { ensureHoldWatch() }
        // A lone-modifier toggle acts on a clean tap, so holding Fn for a chord never toggles.
        if feed(&toggleTracker) == .released { hotKey(2, down: true); hotKey(2, down: false) }
        if feed(&fixTracker) == .released { hotKey(3, down: true) }
    }
    /// A recording (Mac or glasses) started while listening (QA 2026-10-15): other apps' sound comes back at once, or the recording
    /// would capture the mute. Listening itself continues.
    func recordingStarted() {
        guard busy else { return }
        dictationLog.notice("quiet: a recording started while dictating; other apps' sound restored")
        quiet.end()
    }
    func hotKey(_ id: UInt32, down: Bool) {
        if id == 1 {
            if down, !held, DictationReleaseTail.press(tailing: tailing, phase: phase) == .extend {
                held = true; holdPending = true; extendTail()
            } else if down, !held {
                holdSeenDown = false; checkFnUsage()
                held = true; holdPending = true; start()
                warnFnAtPress()
                // QA 0.5.313: a press while the last dictation is still transcribing is refused. Latching `held` anyway
                // let a chord on that refused press turn the LAST dictation into copy-only, and a chord's release never
                // reaches `.released`, so `held` stuck and every later press did nothing.
                if !["Starting", "Listening"].contains(phase) { held = false; holdPending = false }
                ensureHoldWatch()
            }
            else if !down { held = false; if holdPending { holdPending = false; stop() } }
        } else if id == 2 {
            if down, !toggleHeld {
                toggleHeld = true
                if DictationReleaseTail.press(tailing: tailing, phase: phase) == .extend { extendTail() }
                else { phase == "Listening" ? stop() : start() }
            }
            else if !down { toggleHeld = false }
        } else if id == 3, down {
            quickFix()
        }
    }
    func start() {
        guard MacDictationPolicy.mayStart(enabled: enabled, busy: busy) else {
            // 0.5.330: never silent. The press is on the timing line, and the pill says the last one is still finishing.
            if enabled, busy { recordPressEvent(.refusedBusy); noteStillFinishing() }
            return
        }
        // 0.5.327: the press's own time; every start number on the timing line counts from it.
        let pressed = ProcessInfo.processInfo.systemUptime
        // 0.5.328: the main thread's heartbeat from the press (mainThreadStallMs on the timing line).
        heartbeat.begin(at: pressed)
        generation = UUID(); let attempt = generation
        // 0.5.329: AI polish's process starts now, off the main actor; nothing here or at LISTENING waits on it.
        startPrewarm(attempt)
        flashTask?.cancel(); flashTask = nil; fixOfferID = nil; dismissCard()
        let watching = editWatcher.isWatching
        editWatcher.stop("new dictation")
        pendingAudio = nil; message = nil; phase = "Starting"; pointerDuringHold = false
        levelMeter = DictationLevelMeter(); meter.reset()
        startMarks = DictationStartMarks(pressed: pressed); startMarks?.editWatchAtPress = watching
        spareTask?.cancel(); spareTask = nil
        // On the pet only when the pet is on the screen with the focused window; else the pill on that screen. 0.5.328:
        // the focused window comes from Accessibility off the main thread (three calls of up to 0.25 s each when that app
        // is busy); the pill appears as soon as it is back, and the microphone starts opening meanwhile.
        // 0.5.327 (Miles 2026-10-19): STARTING until the microphone's first buffer. LISTENING, the start sound and the
        // mute all wait for it, so nothing tells the person to talk before COS can hear them.
        let petNow = petFrame?(), screens = NSScreen.screens.map(\.frame), mainScreen = NSScreen.main?.frame
        let lookup = DictationFocusedWindow.lookup()
        placing = Task { [weak self] in
            let asked = ProcessInfo.processInfo.systemUptime
            let window: CGRect? = if let lookup {
                (try? await DictationAudioQueues.perform(on: .global(qos: .userInitiated)) { DictationFocusedWindow.frame(lookup) }) ?? nil
            } else { nil }
            guard let self, self.generation == attempt else { return }
            self.startMarks?.placementMs = DictationStartMarks.ms(asked, ProcessInfo.processInfo.systemUptime)
            let placement = DictationPlacement.choose(petFrame: petNow, focusedWindow: window, screens: screens, mainScreen: mainScreen)
            if case .floating(let screen)? = placement { self.surface = .floating; self.floatingScreen = screen } else { self.surface = .pet; self.floatingScreen = nil }
            if self.phase == "Starting" { self.pill = .starting }
        }
        task = Task {
            // A local first: reading and writing startMarks in one statement is an overlapping access (Swift 6 exclusivity).
            let toTask = startMarks?.since(ProcessInfo.processInfo.systemUptime)
            startMarks?.pressToTaskMs = toTask
            let asking = ProcessInfo.processInfo.systemUptime
            let permission: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: permission = true
            case .notDetermined: permission = await AVCaptureDevice.requestAccess(for: .audio)
            default: permission = false
            }
            startMarks?.permissionMs = DictationStartMarks.ms(asking, ProcessInfo.processInfo.systemUptime)
            guard generation == attempt, !Task.isCancelled else { return }
            guard permission else {
                fail("Allow Microphone for COS Control in System Settings → Privacy & Security.", code: DictationFailReason.microphoneDenied.code(), action: .openMicrophoneSettings); return
            }
            // No microphone chosen: the system default, and the device list is never read on the press. A chosen one: its
            // cached id while that device still reports the UID; the list is read only when it does not.
            let choosing = ProcessInfo.processInfo.systemUptime
            let chosen = DictationStart.resolve(selectedUID: microphoneUID, cached: microphoneIDs, uidOf: { DictationAudioDevices.uid(of: $0) },
                                                enumerate: { refreshMicrophones(); return microphoneIDs })
            startMarks?.refreshMicsMs = DictationStartMarks.ms(choosing, ProcessInfo.processInfo.systemUptime); startMarks?.micListRead = chosen.listRead
            let deviceID: AudioDeviceID?
            switch chosen.device {
            case .missing: fail("Your selected microphone is disconnected. Choose another microphone.", code: DictationFailReason.microphoneMissing.code()); return
            case .systemDefault: deviceID = nil
            case .device(let id): deviceID = id
            }
            let next: DictationMicrophoneCapture
            do {
                let opening = ProcessInfo.processInfo.systemUptime
                // 0.5.328: the engine opens on DictationAudioQueues.input; the main actor (the pet, the pill) never waits on
                // it. The spare when it still fits; a spare that will not start gives way to a fresh engine at once.
                let warm = takeSpare(device: deviceID ?? DictationAudioDevices.defaultInput())
                let opened = try await DictationAudioQueues.perform(on: DictationAudioQueues.input) { () throws -> (DictationMicrophoneCapture, Bool) in
                    if let warm, (try? warm.start(deviceID: deviceID)) != nil { return (warm, true) }
                    let fresh = DictationMicrophoneCapture()
                    try fresh.start(deviceID: deviceID)
                    return (fresh, false)
                }
                // Released or canceled while it opened: cancel() had no microphone to close, so close this one here.
                guard generation == attempt, !Task.isCancelled else {
                    let orphan = opened.0
                    DictationAudioQueues.input.async { _ = try? orphan.stop() }
                    return
                }
                next = opened.0; startMarks?.warmEngine = opened.1
                capture = next
                startMarks?.engineStartMs = DictationStartMarks.ms(opening, ProcessInfo.processInfo.systemUptime)
            } catch {
                guard generation == attempt else { return }
                let reason = error.localizedDescription; dictationLog.error("start failed: \(reason, privacy: .public)"); fail(reason, code: DictationFailReason.engineStart.code()); return
            }
            switch await awaitFirstAudio(next, attempt: attempt) {
            case .superseded: return  // cancel() closed the microphone
            case .failed, .timedOut:
                let silent = next.failure == nil
                capture = nil; _ = try? next.stop()
                let waited = startMarks?.since(ProcessInfo.processInfo.systemUptime) ?? -1
                dictationLog.error("start failed: \(silent ? "no first buffer" : "microphone failed", privacy: .public) after \(waited) ms")
                fail(silent ? "The microphone sent no sound. Check it in System Settings → Sound, then try again."
                            : "The microphone changed or disconnected. Try again.",
                     code: (silent ? DictationFailReason.noFirstBuffer : DictationFailReason.microphoneFailed).code())
                return
            case .arrived(let at):
                startMarks?.pressToFirstBufferMs = DictationStartMarks.ms(pressed, at)
            }
            // The pill's placement is known before LISTENING shows (it is almost always back long before the first buffer).
            await placing?.value
            guard generation == attempt, !Task.isCancelled else { return }
            // The microphone is hearing: now LISTENING, and the start sound. See DictationSoundPlayer for why the sound is
            // not trimmed from the recording.
            phase = "Listening"; pill = .listening(since: Date())
            heartbeat.listening(at: ProcessInfo.processInfo.systemUptime)
            // 0.5.328: the sound and the mute are queued, in that order, on DictationAudioQueues.output; their times come
            // back later (lateMarks). pressToSoundMs is now when the sound was queued; soundMs is how long it took to start.
            playSound(.start) { [weak self] took in self?.lateMarks(attempt) { $0.soundMs = took } }
            let toSound = startMarks?.since(ProcessInfo.processInfo.systemUptime)
            startMarks?.pressToSoundMs = toSound
            // After the start sound is scheduled (COS is excluded from the mute, so it still plays); never during a Mac
            // recording. Every way listening ends calls quiet.end(): stop (before the stop sound), fail and cancel. Built
            // after the microphone opened, so building it never delays the first words (0.5.327; on Miles's Mac the
            // mute's aggregate device took 38 to 630 ms, and starting it under a running microphone changed nothing).
            quiet.begin(mode: quietMode, macRecording: macRecordingActive?() ?? false) { [weak self] note, total, times in
                self?.quietNote = note
                self?.lateMarks(attempt) { $0.quietMs = total; $0.quietBuildMs = times.buildMs; $0.quietStartMs = times.startMs }
            }
            // 50 ms ticks: the meter's fast rise and slow fall are tuned to this cadence.
            meterTask = Task {
                var tick = 0
                while !Task.isCancelled, phase == "Listening", generation == attempt {
                    if next.failure != nil { stop(ending: .failure); break }
                    let rms = next.level
                    meter.push(levelMeter.update(rms: rms))
                    // Levels only, never audio: once a second, to confirm the meter's range on a real microphone.
                    if tick % 20 == 0 {
                        dictationLog.debug("listening dBFS=\(DictationLevelMeter.dBFS(rms: rms), format: .fixed(precision: 1)) floor=\(self.levelMeter.floorDB ?? 0, format: .fixed(precision: 1)) peak=\(self.levelMeter.peakDB, format: .fixed(precision: 1))")
                    }
                    tick += 1
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            timer = Task { try? await Task.sleep(for: .seconds(MacDictationPolicy.maximumSeconds)); if !Task.isCancelled { stop(ending: .maximum) } }
            // A chosen microphone: the list follows device changes for the next press, read off this one.
            if !microphoneUID.isEmpty {
                Task { [weak self] in
                    let list = await DictationAudioDevices.inputsOffMain()
                    self?.microphones = list
                }
            }
        }
    }
    /// The person's stop: the hold key released, or the toggle pressed again.
    func stop() { stop(ending: .released) }
    /// 0.5.326: the person's stop keeps listening for the release tail (the pill stays LISTENING), then closes the
    /// microphone; the two-minute limit and a microphone failure close at once, even mid-tail.
    func stop(ending: DictationReleaseTail.Ending) {
        if phase == "Starting" {
            // 0.5.330: released before COS could hear (or before LISTENING showed): on the line, then canceled as before.
            let since = startMarks.map { $0.since(ProcessInfo.processInfo.systemUptime) }
            recordPressEvent(.canceledStarting, msSincePress: since, firstBufferArrived: capture?.firstAudioUptime != nil)
            cancel(); return
        }
        guard phase == "Listening", let capture else { return }
        let tail = DictationReleaseTail.tail(for: ending)
        if tailing { if tail == 0 { closeMicrophone() }; return }
        releaseMark = (ProcessInfo.processInfo.systemUptime, capture.capturedBytes, tail)
        guard tail > 0 else { closeMicrophone(); return }
        tailing = true
        let attempt = generation
        tailTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(tail))
            guard let self, !Task.isCancelled, self.generation == attempt, self.tailing else { return }
            self.closeMicrophone()
        }
    }
    /// A press during the tail: the release came early. The same dictation goes on; nothing was closed or sent.
    private func extendTail() {
        tailing = false; tailTask?.cancel(); tailTask = nil; releaseMark = nil
        dictationLog.notice("tail: pressed again during the tail; the same dictation continues")
    }
    private func closeMicrophone() {
        guard phase == "Listening", let capture else { return }
        tailing = false; tailTask?.cancel(); tailTask = nil
        timer?.cancel(); timer = nil; self.capture = nil
        meterTask?.cancel(); meterTask = nil
        let attempt = generation
        do {
            let pcm = try capture.stop()
            if let mark = releaseMark {
                releasedAt = mark.uptime
                timing = DictationTiming.measure(pcm: pcm, releaseBytes: mark.bytes, tailMs: mark.tailMs,
                                                 releaseToClosedMs: Int(((ProcessInfo.processInfo.systemUptime - mark.uptime) * 1000).rounded()), at: Date())
                startMarks?.mainThreadStallMs = heartbeat.finish()
                timing?.include(startMarks)
            }
            releaseMark = nil; startMarks = nil
            prepareSpare()
            // The microphone is closed: other apps come back before the stop sound plays.
            quiet.end()
            // A stray tap of the shortcut is not worth a card: the pill just goes away.
            guard pcm.count >= 3200 else { fail("No usable speech was captured. Try holding the shortcut longer.", code: DictationFailReason.tooShort.code(), card: false); return }
            phase = "Transcribing"; pill = .transcribing
            // After the microphone has closed, so the stop sound is never in the recording.
            playSound(.stop)
            let wav = try MacDictationPolicy.wav(pcm)
            pendingAudio = wav
            transcribe(wav, attempt: attempt)
        } catch { let reason = error.localizedDescription; dictationLog.error("stop failed: \(reason, privacy: .public)"); fail(reason, code: DictationFailReason.microphoneFailed.code()) }
    }
    /// 0.5.313 (Miles 2026-10-15: "if the transcription does get broken… copy to the clipboard what's been transcribed so
    /// it's not a complete loss"). Listening ended by something other than the person's stop: a key chord while
    /// talking, sleep or a session switch. A second or more of audio is transcribed and COPIED, never typed, with the
    /// card; less is dropped as before. Quit and turning dictation off still cancel: there is nothing left to show it in.
    func interrupt() {
        // Already transcribing (slept between stop and the answer): finish it, but copy rather than type after wake.
        if phase == "Transcribing" {
            pendingInterrupted = pendingAudio != nil
            if pendingInterrupted { interruptedChangeCount = NSPasteboard.general.changeCount }
            return
        }
        guard phase == "Listening", let capture else { cancel(); message = nil; return }
        // 0.5.326: sleep or a session switch inside the release tail closes now and copies, as any interruption does.
        tailing = false; tailTask?.cancel(); tailTask = nil; releaseMark = nil; timing = nil
        timer?.cancel(); timer = nil; self.capture = nil; startMarks = nil; _ = heartbeat.finish()
        meterTask?.cancel(); meterTask = nil
        held = false; toggleHeld = false; holdPending = false
        holdTracker?.reset(); toggleTracker?.reset()
        let attempt = generation
        let pcm: Data
        defer { prepareSpare() }
        do { pcm = try capture.stop() } catch {
            dictationLog.error("interrupted; capture stop failed: \(error.localizedDescription, privacy: .public)")
            cancel(); message = nil; return
        }
        guard MacDictationPolicy.salvages(pcmBytes: pcm.count), let wav = try? MacDictationPolicy.wav(pcm) else {
            dictationLog.notice("interrupted after \(pcm.count / MacDictationPolicy.salvageMinimumBytes) s; under the salvage minimum, dropped")
            cancel(); message = nil; return
        }
        quiet.end()
        dictationLog.notice("interrupted after \(pcm.count / MacDictationPolicy.salvageMinimumBytes) s; transcribing to copy")
        phase = "Transcribing"; pill = .transcribing
        pendingAudio = wav; pendingInterrupted = true; interruptedChangeCount = NSPasteboard.general.changeCount
        transcribe(wav, attempt: attempt)
    }
    func retryTranscription() {
        guard canRetry, let audio = pendingAudio else { return }
        dismissCard()
        phase = "Transcribing"; pill = .transcribing; message = nil
        transcribe(audio, attempt: generation)
    }
    private func transcribe(_ wav: Data, attempt: UUID) {
        task = Task {
            guard generation == attempt, !Task.isCancelled else { return }
            var asked: TimeInterval?
            do {
                guard let bridge else { throw NSError(domain: "COSDictation", code: 2, userInfo: [NSLocalizedDescriptionKey: "The transcription server is not connected."]) }
                let started = ProcessInfo.processInfo.systemUptime; asked = started
                let response = try await bridge(wav)
                timing?.transcribeMs = Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded())
                timing?.engine = response.details["engine"]?.string
                guard generation == attempt, !Task.isCancelled else { return }
                // 0.5.317: any local engine the helper accepted (Parakeet Ultra, or Whisper on a 6.74.0 server). The
                // helper refuses every other engine, and on an older server everything but Parakeet Ultra.
                guard response.ok, let heard = response.details["text"]?.string, !heard.isEmpty,
                      let engine = response.details["engine"]?.string, DictationEngineName.title(engine) != nil else {
                    // No speech (the server's 204) is an answer, not a failure: retrying the same audio cannot help.
                    let noSpeech = response.details["noSpeech"]?.bool == true
                    if noSpeech { pendingAudio = nil; timing?.outcome = "no_speech" }
                    let reason = response.details["reason"]?.string ?? (noSpeech ? "no_speech" : "unknown")
                    let action = DictationFailureAction.resolve(action: response.details["action"]?.string, retryable: response.details["retryable"]?.bool,
                                                                noSpeech: noSpeech, audioHeld: pendingAudio != nil)
                    dictationLog.notice("transcription refused reason=\(reason, privacy: .public) noSpeech=\(noSpeech) action=\(action.rawValue, privacy: .public)")
                    // A click while holding and nothing said: the person was ⌥-clicking slowly, not dictating. No card.
                    fail(response.message, code: noSpeech ? DictationFailReason.noSpeech.code() : DictationFailReason.refused.code(reason),
                         card: !(noSpeech && pointerDuringHold), action: action); return
                }
                let fallback = response.details["fallbackReason"]?.string
                lastEngine = (engine, fallback)
                dictationLog.notice("transcribed engine=\(engine, privacy: .public) fallback=\(fallback ?? "none", privacy: .public)")
                DictationProof.record(engine: engine, serverVersion: serverVersion?())
                // 0.5.331 paste first, polish in place: with the toggle on and a polish that will run, what was heard is
                // typed now and Claude's version swapped in place when it is ready. Off: today's order, below.
                // 0.5.332: a target that can never prove a swap (a canvas editor like Slides) is polished first instead.
                let polishes = polishBridge != nil && DictationPolish.shouldPolish(text: heard, model: polishModel)
                let unmeasurable = pasteThenPolish && polishes && !pendingInterrupted ? DictationInsertion.unmeasurableTarget() : nil
                let sequence = DictationPolishSwap.sequence(pasteFirst: pasteThenPolish, polishes: polishes,
                                                            copyOnly: pendingInterrupted, unmeasurable: unmeasurable)
                if sequence == .deliverThenPolish { await deliverThenPolish(heard, attempt: attempt); return }
                // 0.5.325 AI polish, before lists and delivery: Claude's cleanup within its budget, or what was heard.
                let polished = await polish(heard, attempt: attempt)
                guard generation == attempt, !Task.isCancelled else { return }
                timing?.includePolish(polished)
                let said = polished?.outcome.text(heard: heard) ?? heard
                if case .applied? = polished?.outcome, let model = polished?.model { lastPolish = (heard, model) } else { lastPolish = nil }
                lastPolishPrompt = lastPolish == nil ? nil : polished?.prompt
                let text = formatLists ? DictationListFormat.format(said) : said
                let copyOnly = pendingInterrupted
                let clipboardMoved = interruptedChangeCount.map { $0 != NSPasteboard.general.changeCount } ?? false
                pendingAudio = nil; phase = "Ready"; message = nil
                // 0.5.328: delivery still runs on the main actor (Accessibility into the target app, the clipboard, ⌘V);
                // deliverMs says how long, so a stutter at the end of a dictation can be told from one at its start.
                await waitForSwapEdit()
                let delivering = ProcessInfo.processInfo.systemUptime
                deliveryInFlight = true
                let delivered = copyOnly ? DictationInsertion.copyOnly(text, clipboardMoved: clipboardMoved)
                    : await DictationInsertion.deliver(text, restoreClipboard: restoreClipboard, fieldContext: useFieldContext)
                deliveryInFlight = false
                timing?.deliverMs = DictationStartMarks.ms(delivering, ProcessInfo.processInfo.systemUptime)
                timing?.releaseToFirstTextMs = firstTextMs()
                timing?.settle(DictationPolishSwap.unswapped(pasteFirst: pasteThenPolish, polished: polished != nil, copyOnly: copyOnly, unmeasurable: unmeasurable != nil),
                               ms: nil, route: nil, why: unmeasurable)
                // What was typed, after the field's own words respelled it (0.5.323), is what is kept and watched.
                finish(delivered.context?.text ?? text, outcome: delivered.outcome, target: delivered.target, context: delivered.context, own: delivered.own)
            } catch {
                guard generation == attempt else { return }; let reason = error.localizedDescription; dictationLog.error("transcribe failed: \(reason, privacy: .public)")
                // 0.5.327: how long the helper ran before it failed, and which way it failed (a code, not its words).
                if let asked { timing?.transcribeMs = DictationStartMarks.ms(asked, ProcessInfo.processInfo.systemUptime) }
                fail(reason, code: Self.failCode(error), action: DictationFailureAction.resolve(action: nil, retryable: nil, noSpeech: false, audioHeld: pendingAudio != nil))
            }
        }
    }
    /// 0.5.325 AI polish. nil when it does not run (Off, empty, over 8,000 characters, no helper). Otherwise one helper
    /// round trip bounded by the model's budget; every failure is an outcome that pastes what was heard, never a card and
    /// never a failed dictation. The log line has the model, the outcome and the time, never the text.
    /// 0.5.331: the run comes back to the caller, which writes it on this dictation's own timing line (a paste-first
    /// dictation's line outlives the next press). `attempt` is the press whose early process this polish may take;
    /// `showPill` is false when the text is already typed (paste first).
    private func polish(_ heard: String, attempt: UUID, showPill: Bool = true) async -> DictationPolishRun? {
        let model = polishModel
        guard DictationPolish.shouldPolish(text: heard, model: model), let budget = DictationPolish.budget(for: model), let polishBridge else {
            discardPrewarm(attempt); return nil
        }
        if showPill { pill = .polishing }
        let started = Date()
        // 0.5.329: the press's early process, when it is ready (at most 150 ms more); without one, polish runs cold as before.
        let (warm, warmMs) = await takePrewarm(model, attempt: attempt)
        guard let request = DictationPolish.request(text: heard, model: model, app: NSWorkspace.shared.frontmostApplication?.localizedName,
                                                    prewarmToken: warm) else { return nil }
        var prewarm = DictationPolishPrewarm.outcome(sentToken: warm != nil, answer: nil)
        var instructions: (on: Bool, hash: String?) = (false, nil)
        var prompt: String?
        let outcome: DictationPolish.Outcome
        do {
            let response = try await polishBridge(request, budget)
            prewarm = DictationPolishPrewarm.outcome(sentToken: warm != nil, answer: response.details["prewarm"]?.string)
            outcome = DictationPolish.choose(heard: heard, ok: response.ok, text: response.details["text"]?.string,
                                             polished: response.details["polished"]?.bool, reason: response.details["reason"]?.string,
                                             skipped: response.details["polishSkipped"]?.string,
                                             polishOutcome: response.details["polishOutcome"]?.string)
            // 0.5.335 (server 6.85.0): whether the person's polish instructions went with it, for the timing line only.
            instructions = DictationPolishInstructions.used(flag: response.details["customInstructions"]?.bool,
                                                            hash: response.details["instructionsHash"]?.string)
            // 0.5.344 (server 6.91.0): which prompt polished it, v3 or v4, for the timing line and the card.
            prompt = DictationPolish.promptVersion(response.details["polishPrompt"]?.string)
        } catch HelperClientError.timedOut {
            outcome = .timeout
        } catch {
            outcome = .failed(error is CancellationError ? "canceled" : "helper")
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        dictationLog.notice("polish model=\(model.rawValue, privacy: .public) outcome=\(outcome.logName, privacy: .public) ms=\(elapsed)")
        notePolishPause(outcome)
        return DictationPolishRun(outcome: outcome, model: model, ms: elapsed, prewarm: prewarm, prewarmMs: warmMs,
                                  customInstructions: instructions.on, instructionsHash: instructions.hash).with(prompt: prompt)
    }
    /// The text is on the clipboard already. Measured or sent: flash the pill. Refused: the card, which never takes focus.
    /// 0.5.331 `swapPending`: Claude's version is still coming (paste first). Its timing line and its watch wait for the
    /// swap to settle (deliverThenPolish), so the swap is never read as the person's own edit.
    @discardableResult
    private func finish(_ text: String, outcome: DictationDeliveryOutcome, target: DictationInsertTarget?, context: DictationFieldContext.Applied? = nil,
                        swapPending: Bool = false, own: DictationOwnTarget? = nil) -> UUID {
        let record = DictationRecord(id: UUID(), text: text, createdAt: Date(), delivery: outcome.delivery,
                                     engine: lastEngine?.engine, fallbackReason: lastEngine?.fallback,
                                     heard: lastPolish?.heard, polishModel: lastPolish?.model.rawValue, polishPrompt: lastPolishPrompt)
        lastEngine = nil; lastPolish = nil
        lastPolishPrompt = nil
        if !swapPending { if case .refused = outcome { recordTiming("copied") } else { recordTiming("typed") } }
        if let target { rememberTarget(target, for: record.id) }
        // 0.5.342: the watch that starts below (or after the swap) belongs to this dictation.
        editWatcher.pendingRecord = record.id
        // 0.5.318: watch the field it went into for the person's own fixes (native apps; Electron is only measured).
        if swapPending {
            editWatcher.stop("polish pending")
        } else if let target, case .inserted = outcome {
            editWatcher.start(target, mode: learnMode, context: context) { [weak self] candidate in self?.editLearned(candidate, app: target.app) }
        } else if let own, case .inserted = outcome {
            // 0.5.337: COS's own text views (the Work task editor) learn too, under the same rules, window and caps.
            editWatcher.startOwn(own, mode: learnMode) { [weak self] candidate in self?.editLearned(candidate, app: own.app) }
        } else {
            editWatcher.stop("not inserted")
            // 0.5.344 (QA W3): a typed dictation that got no watch still writes its canary line, with the reason.
            if let reason = DictationEditLearning.unwatched(learnOff: learnMode == .off, outcome: outcome, hasTarget: false) {
                DictationEditWatcher.skipped(reason, bundle: target?.bundle)
            }
        }
        if let flash = outcome.flash {
            pill = flash
            // 0.5.313: the flash carries Fix for a few seconds, so a mishearing can be fixed the moment it lands.
            let offer = DictationQuickFix.offers(outcome)
            fixOfferID = offer ? record.id : nil
            flashTask = Task {
                try? await Task.sleep(for: .seconds(offer ? DictationQuickFix.offerSeconds : DictationPill.flashSeconds))
                if !Task.isCancelled, pill == flash { pill = .hidden; fixOfferID = nil }
            }
        } else if case .refused(let refusal) = outcome {
            pill = .hidden
            showCard(DictationCard(kind: .copied(refusal), recordID: record.id, text: text, countdown: DictationCountdown(start: Date())))
        }
        remember(record)
        // 0.5.330: a dictation whose Fn release was missed ends with the card that says how to stop it happening.
        showFnCardIfPending()
        return record.id
    }
    /// A dictation that did not finish: the reason on the card, with its one action (0.5.317): Retry while the audio is
    /// held and a retry can succeed, Install Parakeet, Use Whisper, Open Transcription settings, or Open Settings when
    /// the microphone is not allowed. A failure COS raised itself retries the held audio (DictationFailureAction).
    /// 0.5.326: one timing line per dictation, numbers only: the log (public, notice) and dictation-timing.jsonl.
    /// 0.5.331: `line` is a paste-first dictation's own line, written once its swap settles; nil is the store's current one.
    private func recordTiming(_ outcome: String, line: DictationTiming? = nil) {
        guard var finished = line ?? timing else { return }
        if line == nil { timing = nil }
        if finished.outcome == "pending" { finished.outcome = outcome }
        func n(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "-" }
        dictationLog.notice("timing release_to_closed_ms=\(finished.releaseToClosedMs) tail_ms=\(finished.tailMs) captured_s=\(n(finished.capturedSeconds), privacy: .public) final_dbfs=\(n(finished.finalDBFS), privacy: .public) tail_dbfs=\(n(finished.tailDBFS), privacy: .public) engine=\(finished.engine ?? "-", privacy: .public) transcribe_ms=\(finished.transcribeMs ?? -1) polish_ms=\(finished.polishMs ?? -1) polish=\(finished.polishModel ?? "-", privacy: .public):\(finished.polishOutcome ?? "-", privacy: .public) polish_prompt=\(finished.polishPrompt ?? "-", privacy: .public) first_text_ms=\(finished.releaseToFirstTextMs ?? -1) swap=\(finished.swapOutcome ?? "-", privacy: .public) swap_ms=\(finished.swapMs ?? -1) swap_route=\(finished.swapRoute ?? "-", privacy: .public) swap_why=\(finished.swapWhy ?? "-", privacy: .public) outcome=\(finished.outcome, privacy: .public)")
        if let url = Self.defaultHistoryURL()?.deletingLastPathComponent().appendingPathComponent(DictationTimingLog.fileName) {
            DictationTimingLog.append(finished, to: url)
        }
    }
    // MARK: Paste first, polish in place (0.5.331)

    /// The release to now, once, for the timing line (nil on a retry, which has no release).
    private func firstTextMs() -> Int? {
        guard let released = releasedAt else { return nil }
        releasedAt = nil
        return DictationStartMarks.ms(released, ProcessInfo.processInfo.systemUptime)
    }
    /// A delivery never types while an automatic swap is editing a field (bounded; the swap is a few hundred ms).
    private func waitForSwapEdit() async {
        var waited = 0
        while swapEditing, waited < DictationPolishSwap.deliveryWaitMilliseconds {
            try? await Task.sleep(for: .milliseconds(20)); waited += 20
        }
    }
    /// Type what was heard now (lists and the field's spellings as always), polish in parallel, then swap Claude's version
    /// in place when it differs, under DictationPolishSwap's rules. This dictation's timing line and its edit watch wait
    /// for the swap to settle. A newer dictation may start meanwhile: nothing here waits on it or blocks it.
    private func deliverThenPolish(_ heard: String, attempt: UUID) async {
        let polishing = Task { await self.polish(heard, attempt: attempt, showPill: false) }
        let lists = formatLists
        let text = lists ? DictationListFormat.format(heard) : heard
        lastPolish = nil; lastPolishPrompt = nil
        pendingAudio = nil; phase = "Ready"; message = nil
        await waitForSwapEdit()
        let delivering = ProcessInfo.processInfo.systemUptime
        deliveryInFlight = true
        let delivered = await DictationInsertion.deliver(text, restoreClipboard: restoreClipboard, fieldContext: useFieldContext)
        deliveryInFlight = false
        timing?.deliverMs = DictationStartMarks.ms(delivering, ProcessInfo.processInfo.systemUptime)
        timing?.releaseToFirstTextMs = firstTextMs()
        // This dictation's own line from here: a newer press stops and measures a line of its own.
        var line = timing; timing = nil
        let typed = delivered.context?.text ?? text
        let id = finish(typed, outcome: delivered.outcome, target: delivered.target, context: delivered.context, swapPending: true)
        var inserted = false
        if case .inserted = delivered.outcome { inserted = true }
        let quiet = delivered.target.map { DictationFieldQuiet($0) }
        let run = await polishing.value
        line?.includePolish(run)
        let answered = ProcessInfo.processInfo.systemUptime
        var result = DictationPolishSwap.Result.notPolished, route: DictationReplace.Route?, swapMs: Int?
        var watchTarget = delivered.target, watchContext = delivered.context
        var final: (text: String, fixes: [DictationFieldContext.Fix])?
        if case .applied(let polished)? = run?.outcome { final = DictationInsertion.polishedFinal(polished, formatLists: lists, context: delivered.context) }
        switch DictationPolishSwap.want(outcome: run?.outcome, typed: typed, final: final?.text) {
        case .notPolished: result = .notPolished
        case .identical: result = .identical
        case .swap(let polished):
            let budgetMs = Int((DictationPolish.budget(for: run?.model ?? polishModel) ?? 5) * 1000)
            let swapped = await swapPolished(id: id, target: delivered.target, inserted: inserted, polished: polished, budgetMs: budgetMs, quiet: quiet)
            result = swapped.result; route = swapped.route
            swapMs = DictationStartMarks.ms(answered, ProcessInfo.processInfo.systemUptime)
            if let target = delivered.target {
                let watched = DictationPolishSwap.watch(span: target.span, typed: typed, polished: polished, result: result, swappedAt: swapped.target?.span.location)
                watchTarget = DictationInsertTarget(element: target.element, span: watched.span, terminal: target.terminal, app: target.app, text: watched.text,
                                                    setterWorked: target.setterWorked, bundle: target.bundle, chromium: target.chromium, electron: target.electron)
            }
            if result.swappedIn, let model = run?.model {
                // The dictation now reads what the field holds, and keeps what was heard (Fix a word, Heard, history).
                recent = DictationHistory.polishing(id, to: polished, heard: heard, model: model.rawValue, prompt: run?.prompt, in: recent); saveRecent()
                if let watchTarget { rememberTarget(watchTarget, for: id) }
                watchContext = delivered.context.map { DictationFieldContext.Applied(text: polished, fixes: final?.fixes ?? [], outside: $0.outside, terms: $0.terms) }
            } else if DictationPolishSwap.keepsPolished(result), let model = run?.model, record(id) != nil {
                // 0.5.332: after a mismatch the row shows what was heard and Claude's version, with Copy, never Apply.
                pendingPolish[id] = DictationPendingPolish(text: polished, heard: heard, model: model, applies: DictationPolishSwap.offersApply(result), prompt: run?.prompt)
            }
        }
        quiet?.stop()
        line?.settle(result, ms: swapMs, route: route)
        if case .refused = delivered.outcome { recordTiming("copied", line: line) } else { recordTiming("typed", line: line) }
        dictationLog.notice("swap outcome=\(result.logName, privacy: .public) route=\(route.map(DictationPolishSwap.routeName) ?? "-", privacy: .public) ms=\(swapMs ?? -1)")
        // Learn from my edits starts once the swap settled, from what the field now holds, unless a newer dictation began.
        if generation == attempt, inserted, DictationPolishSwap.watches(result), let watchTarget {
            editWatcher.pendingRecord = id
            editWatcher.start(watchTarget, mode: learnMode, context: watchContext) { [weak self] candidate in self?.editLearned(candidate, app: watchTarget.app) }
        } else if let reason = DictationEditLearning.unwatched(learnOff: learnMode == .off, outcome: delivered.outcome, hasTarget: watchTarget != nil,
                                                               newer: generation != attempt, swapWatches: DictationPolishSwap.watches(result)) {
            // 0.5.344 (QA W3): the swap's mismatch, a newer dictation or no target: the canary says which.
            DictationEditWatcher.skipped(reason, bundle: delivered.target?.bundle)
        }
        if let notice = DictationPolishSwap.notice(result, app: delivered.target?.app ?? "the app"), !busy {
            let flash = DictationPill.flash(label: notice, confirmed: false)
            pill = flash
            flashTask?.cancel()
            flashTask = Task {
                try? await Task.sleep(for: .seconds(DictationQuickFix.offerSeconds))
                if !Task.isCancelled, pill == flash { pill = .hidden; fixOfferID = nil }
            }
        }
    }
    /// Waits for a quiet moment, then the automatic replace (no activation; the focus rules inside). The edit and a
    /// delivery never overlap.
    private func swapPolished(id: UUID, target: DictationInsertTarget?, inserted: Bool, polished: String, budgetMs: Int,
                              quiet: DictationFieldQuiet?) async -> (result: DictationPolishSwap.Result, route: DictationReplace.Route?, target: DictationInsertTarget?) {
        var waited = 0
        while true {
            let running = target.flatMap { NSRunningApplication(processIdentifier: $0.span.pid) }.map { !$0.isTerminated } ?? false
            // A key typed counts only while the target field has the keyboard ("typed in that field").
            let sinceKey: Int? = target.map { DictationInsertion.holdsFocus($0.element, pid: $0.span.pid) } == true
                ? Int((CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) * 1000).rounded()) : nil
            let step = DictationPolishSwap.ready(inserted: inserted, measured: target != nil, enabled: enabled && !Task.isCancelled,
                                                 terminal: target?.terminal ?? false, appRunning: running,
                                                 busy: deliveryInFlight || listRoute == .fix(id), sinceFieldChangeMs: quiet?.sinceChangeMs,
                                                 sinceKeyMs: sinceKey, waitedMs: waited, budgetMs: budgetMs)
            if case .skip(let why) = step { return (.skipped(why), nil, nil) }
            if step == .go { break }
            try? await Task.sleep(for: .milliseconds(DictationPolishSwap.quietPollMilliseconds)); waited += DictationPolishSwap.quietPollMilliseconds
        }
        guard let target else { return (.skipped(.notTyped), nil, nil) }
        swapEditing = true
        defer { swapEditing = false }
        let replaced = await DictationInsertion.replace(target, corrected: polished, restoreClipboard: restoreClipboard, automatic: true)
        insertTargets[id] = replaced.target
        switch replaced.result {
        case .replaced: return (.swapped, replaced.route, replaced.target)
        // 0.5.332: landed by count, not read back: swapped, unconfirmed. Never skipped, so never Apply polished.
        case .replacedUnconfirmed: return (.swappedUnconfirmed, replaced.route, replaced.target)
        case .mismatch: return (.mismatch, replaced.route, nil)
        case .copied(let reason): return (.skipped(replaced.skip ?? DictationPolishSwap.skip(for: reason)), replaced.route, nil)
        case .unverified: return (.skipped(.unverified), replaced.route, nil)
        }
    }
    /// Apply polished (Activity, Dictation): the person asked, so this is Fix a word's own replace, which may bring the
    /// app forward. Anything short of proof copies Claude's version and says why.
    func applyPolished(_ id: UUID) {
        guard let pending = pendingPolish[id], pending.applies, record(id) != nil else { return }
        pendingPolish[id] = nil
        // COS's own edit is never the person's: the watch on that field ends first.
        editWatcher.stop("apply polished")
        guard let target = insertTargets[id] else {
            copy(pending.text); polishNote = (id, "Copied the polished version."); return
        }
        Task {
            let replaced = await DictationInsertion.replace(target, corrected: pending.text, restoreClipboard: restoreClipboard)
            insertTargets[id] = replaced.target
            switch replaced.result {
            case .replaced:
                recent = DictationHistory.polishing(id, to: pending.text, heard: pending.heard, model: pending.model.rawValue, prompt: pending.prompt, in: recent); saveRecent()
                polishNote = (id, "Polished it in \(target.app).")
            case .copied(let reason):
                copy(pending.text); polishNote = (id, DictationReplace.copiedNote(reason, app: target.app))
            case .unverified(let pasted):
                copy(pending.text); polishNote = (id, DictationReplace.unverifiedNote(app: target.app, pasted: pasted))
            case .replacedUnconfirmed, .mismatch:
                copy(pending.text); polishNote = (id, DictationReplace.unverifiedNote(app: target.app, pasted: true))
            }
        }
    }
    /// 0.5.332: after a mismatch, Claude's version is copied, never pasted again.
    func copyPolished(_ id: UUID) {
        guard let pending = pendingPolish[id] else { return }
        copy(pending.text); polishNote = (id, "Copied the polished version.")
    }
    /// `code` (DictationFailReason) names the failed step on the timing line; `reason` is the card's words and never logged there.
    private func fail(_ reason: String, code: String, card: Bool = true, action: DictationFailureAction? = nil) {
        // 0.5.327: a failure before the microphone captured anything writes its own line, with the start's numbers.
        let stall = heartbeat.finish()
        if startMarks != nil { startMarks?.mainThreadStallMs = stall }
        if timing == nil, let marks = startMarks { timing = DictationTiming.startFailure(marks, at: Date()) }
        startMarks = nil
        timing?.failReason = code
        recordTiming("failed")
        let action = action ?? DictationFailureAction.resolve(action: nil, retryable: nil, noSpeech: false, audioHeld: pendingAudio != nil)
        discardPrewarm()
        quiet.end()
        phase = enabled ? "Ready" : "Off"; message = reason; pill = .hidden; meter.reset()
        prepareSpare()
        if card {
            showCard(DictationCard(kind: .failed(reason, action: action), recordID: nil, text: "",
                                   countdown: DictationCountdown(start: Date())))
        }
    }
    /// The helper call's failure as a DictationFailReason code: which way it failed, never the error's words.
    private static func failCode(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == "COSDictation", ns.code == 2 { return DictationFailReason.notConnected.code() }
        if error is CancellationError { return DictationFailReason.helperFailed.code("canceled") }
        guard let helper = error as? HelperClientError else { return DictationFailReason.helperFailed.code() }
        if case .timedOut = helper { return DictationFailReason.helperTimeout.code() }
        if case .helperMissing = helper { return DictationFailReason.helperFailed.code("missing") }
        if case .invalidResponse = helper { return DictationFailReason.helperFailed.code("invalid_response") }
        if case .commandFailed = helper { return DictationFailReason.helperFailed.code("command_failed") }
        if case .outputLimitExceeded = helper { return DictationFailReason.helperFailed.code("output_limit") }
        if case .streamDidNotClose = helper { return DictationFailReason.helperFailed.code("stream_open") }
        return DictationFailReason.helperFailed.code("other")
    }
    /// The failure card's button.
    func performFailureAction(_ action: DictationFailureAction) {
        switch action {
        case .retry: retryTranscription()
        case .openMicrophoneSettings: openMicrophoneSettings()
        case .openKeyboardSettings:
            dismissCard()
            if let url = URL(string: DictationFnUsage.keyboardSettingsURL) { NSWorkspace.shared.open(url) }
        case .openTranscriptionSettings: dismissCard(); openTranscriptionSettings?()
        case .installParakeet:
            // The held audio stays; Install runs in the background and dictation keeps working with Whisper.
            dismissCard(); installParakeet?()
        case .useWhisper:
            dismissCard()
            Task {
                guard await useWhisper?() == true else { fail("COS could not switch dictation to Whisper. Open Transcription settings to choose an engine.", code: DictationFailReason.engineSwitch.code(), action: .openTranscriptionSettings); return }
                if canRetry { retryTranscription() }
            }
        case .none: break
        }
    }
    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
    }
    /// 0.5.328 quit (COSAppDelegate.onTerminate, after cancel): the queued unmute or volume restore runs before exit.
    func flushAudio() { quiet.flush() }
    /// Also the quit path (COSAppDelegate.onTerminate) and turning dictation off; sleep and a session switch reach
    /// interrupt(), which falls back here. Other apps' sound always comes back.
    func cancel() {
        quiet.end()
        generation = UUID(); pendingAudio = nil; task?.cancel(); task = nil; timer?.cancel(); timer = nil
        tailing = false; tailTask?.cancel(); tailTask = nil; releaseMark = nil; timing = nil; releasedAt = nil
        meterTask?.cancel(); meterTask = nil; flashTask?.cancel(); flashTask = nil
        _ = try? capture?.stop(); capture = nil; held = false; toggleHeld = false; holdPending = false
        holdTracker?.reset(); toggleTracker?.reset(); startMarks = nil; _ = heartbeat.finish(); placing?.cancel(); placing = nil
        discardPrewarm()
        phase = enabled ? "Ready" : "Off"; message = "Dictation canceled. No text was inserted."
        pill = .hidden; fixOfferID = nil; meter.reset()
        prepareSpare()
    }

    // MARK: Sounds (0.5.312)

    func soundChoice(_ edge: DictationSoundEdge) -> String { edge == .start ? soundStart : soundStop }
    var petSoundName: String { DictationSoundLibrary.name(DictationSoundLibrary.petDefault(petKind?() ?? .other, pack: petPack?())) }

    private func resolvedSound(_ edge: DictationSoundEdge) -> DictationSoundLibrary.Resolved {
        DictationSoundLibrary.resolve(DictationSoundLibrary.Choice(stored: soundChoice(edge)), edge: edge, pet: petKind?() ?? .other, pack: petPack?(),
                                      volume: soundVolume, macRecording: macRecordingActive?() ?? false,
                                      customUsable: { [directory = Self.customSoundDirectory()] file in
                                          FileManager.default.isReadableFile(atPath: directory.appendingPathComponent(file).path) })
    }
    private func soundURL(_ resolved: DictationSoundLibrary.Resolved) -> URL? {
        switch resolved {
        case .silent: nil
        case .bundled(let file): Bundle.main.url(forResource: (file as NSString).deletingPathExtension, withExtension: "wav", subdirectory: "Sounds")
        case .custom(let file): Self.customSoundDirectory().appendingPathComponent(file)
        }
    }
    /// 0.5.328: queued on DictationAudioQueues.output; `played` (the main actor) gets how long it took to start.
    func playSound(_ edge: DictationSoundEdge, played: (@MainActor @Sendable (Int) -> Void)? = nil) {
        let resolved = resolvedSound(edge)
        if case .silent(let why) = resolved { dictationLog.debug("sound \(edge.rawValue, privacy: .public) silent: \(why, privacy: .public)"); return }
        guard let url = soundURL(resolved) else { return }
        play(url, volume: Float(soundVolume), played: played)
    }
    private func play(_ url: URL, volume: Float, played: (@MainActor @Sendable (Int) -> Void)? = nil) {
        let player = soundPlayer, pitch = soundPitch
        DictationAudioQueues.output.async {
            let began = ProcessInfo.processInfo.systemUptime
            player.play(url, volume: volume, semitones: pitch)
            let took = DictationStartMarks.ms(began, ProcessInfo.processInfo.systemUptime)
            if let played { Task { @MainActor in played(took) } }
        }
    }
    /// Settings' Preview. Same rules as dictation, so a preview during a Mac recording says why it is silent.
    func previewSound(_ edge: DictationSoundEdge) {
        if case .silent(let why) = resolvedSound(edge) { soundNote = "No sound: \(why)."; return }
        soundNote = nil
        playSound(edge)
    }
    /// ~/Library/Application Support/COS Control/dictation-sounds (a check run uses its own test home).
    nonisolated static func customSoundDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let home = environment["COS_CONTROL_TEST_HOME"] { return URL(fileURLWithPath: home).appendingPathComponent("dictation-sounds", isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/COS Control/dictation-sounds", isDirectory: true)
    }
    /// Your own file…: any decodable audio file up to 20 MB, trimmed on import (DictationSoundTrim). Nothing is saved
    /// until the person has seen the resulting length, previewed it if they like, and pressed Save.
    func importCustomSound(_ edge: DictationSoundEdge) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "Choose a sound for when dictation \(edge == .start ? "starts" : "stops"). COS keeps the part that matters, at most a few seconds."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let bytes = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        let decoded = bytes <= DictationSoundLibrary.maximumSourceBytes ? DictationAudioDecode.mono(source) : nil
        let duration = decoded.map { Double($0.samples.count) / $0.sampleRate }
        if let refusal = DictationSoundLibrary.customRefusal(byteCount: bytes, duration: duration) { soundNote = refusal; return }
        guard let decoded, let duration else { return }
        let levels = DictationSoundTrim.levels(decoded.samples, sampleRate: decoded.sampleRate)
        guard let onset = DictationSoundTrim.onset(levels), let end = DictationSoundTrim.end(levels) else {
            soundNote = "That file is silent (never louder than -40 dBFS). Choose another."; return
        }
        soundNote = nil
        pendingImport = DictationSoundImport(edge: edge, sourceName: source.lastPathComponent, samples: decoded.samples,
                                             sampleRate: decoded.sampleRate, duration: duration, onset: onset, end: end, useEnd: edge == .stop)
    }
    func setImportUseEnd(_ value: Bool) { pendingImport?.useEnd = value }
    func cancelImport() { pendingImport = nil }
    /// The trimmed sound, played with the current volume and pitch, from a private temporary file.
    func previewImport() {
        guard let pending = pendingImport else { return }
        if macRecordingActive?() == true { soundNote = "No sound: a COS recording is capturing."; return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cos-dictation-sound-preview.wav")
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: pending.trimmedWAV, attributes: [.posixPermissions: 0o600]) else { return }
        play(url, volume: Float(max(soundVolume, 0.2)))
    }
    /// Stores only the trimmed result (at most 3 s, WAV) in the app's dictation-sounds folder, 0600, and selects it.
    func saveImport() {
        guard let pending = pendingImport, pending.window.length <= DictationSoundLibrary.maximumStoredSeconds else { return }
        let directory = Self.customSoundDirectory()
        let name = "\(pending.edge.rawValue)-\(UUID().uuidString.prefix(8)).wav"
        let target = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { soundNote = "COS could not save that sound."; return }
        guard FileManager.default.createFile(atPath: target.path, contents: pending.trimmedWAV, attributes: [.posixPermissions: 0o600]) else {
            soundNote = "COS could not save that sound."; return
        }
        // The previous file for this edge goes; the new one is the choice.
        if case .custom(let old) = DictationSoundLibrary.Choice(stored: soundChoice(pending.edge)) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(old))
        }
        let stored = DictationSoundLibrary.Choice.custom(name).stored
        if pending.edge == .start { soundStart = stored } else { soundStop = stored }
        pendingImport = nil
        soundNote = nil
    }

    // MARK: Recent dictations (0.5.309)

    private func remember(_ record: DictationRecord) {
        recent = DictationHistory.adding(record, to: recent, retention: retention, now: Date())
        saveRecent()
    }
    /// Prunes on every save. "Don't keep" removes the file instead of writing one.
    private func saveRecent() {
        guard let historyURL else { return }
        guard retention.writesToDisk else {
            if FileManager.default.fileExists(atPath: historyURL.path) { try? FileManager.default.removeItem(at: historyURL) }
            return
        }
        // Dictated text is private: a failure is logged by its reason only, never with the text.
        do { try DictationHistory.save(recent, to: historyURL) }
        catch { dictationLog.error("recent dictations not saved: \(error.localizedDescription, privacy: .public)") }
    }
    /// Delete one dictation from this Mac (its row, or its detail).
    func deleteRecord(_ id: UUID) {
        recent = DictationHistory.removing(id, from: recent)
        if let card, card.recordID == id { dismissCard() }
        switch listRoute {
        case .detail(id)?, .fix(id)?: listRoute = recent.isEmpty ? nil : .recent; resetFix()
        default: if recent.isEmpty { listRoute = nil }
        }
        saveRecent()
    }
    /// Keep dictations for 7, 30 or 90 days, or forever. Applies now.
    func setRetention(_ next: DictationRetention) {
        guard next.writesToDisk else { return }   // "Don't keep" goes through stopKeepingHistory, after a confirm
        retention = next
        UserDefaults.standard.set(next.rawValue, forKey: "dictation.history.retention")
        recent = DictationHistory.pruned(recent, retention: next, now: Date())
        saveRecent()
    }
    /// "Don't keep", confirmed: the history is cleared and nothing is written from now on.
    func stopKeepingHistory() {
        retention = .none
        UserDefaults.standard.set(DictationRetention.none.rawValue, forKey: "dictation.history.retention")
        clearRecent()
    }
    /// Clear dictation history (Settings and COS Activity, each after a confirm).
    func clearRecent() {
        recent = []
        if card?.recordID != nil { dismissCard() }
        listRoute = nil; resetFix()
        saveRecent()
    }
    func record(_ id: UUID?) -> DictationRecord? { id.flatMap { id in recent.first { $0.id == id } } }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }

    // MARK: The card (mock 04)

    private func showCard(_ next: DictationCard) {
        card = next
        let id = next.id
        cardTask?.cancel()
        cardTask = Task {
            while !Task.isCancelled, let current = card, current.id == id {
                let now = Date()
                if current.countdown.expired(at: now) { card = nil; break }
                try? await Task.sleep(for: .seconds(current.countdown.paused ? 0.25 : min(0.5, current.countdown.remaining(at: now))))
            }
        }
    }
    func dismissCard() { cardTask?.cancel(); cardTask = nil; card = nil }
    /// Hovering the card pauses its fold-away; leaving resumes from where it stopped.
    func setCardHover(_ inside: Bool) {
        guard var current = card else { return }
        if inside { current.countdown.pause(at: Date()) } else { current.countdown.resume(at: Date()) }
        if current != card { card = current }
    }

    // MARK: The pet's dictation views (mock 05, 06)

    /// The DICTATED pill. Opening it is a choice of the pet's list, so it always shows on the pet.
    func toggleRecent() {
        if listRoute != nil { closeList(); return }
        if !busy { surface = .pet }
        listRoute = .recent
    }
    func openDetail(_ id: UUID) { guard record(id) != nil else { return }; listRoute = .detail(id); resetFix() }
    /// Fix a word from COS Activity's history: on the pet when it is showing, else in the floating editor.
    func openFixFromHistory(_ id: UUID) {
        guard record(id) != nil, !busy else { return }
        surface = petFrame?() != nil ? .pet : .floating
        openFix(id)
    }
    func openFix(_ id: UUID?) {
        guard let id, record(id) != nil else { return }
        // Fix a word teaches the dictionary itself, and its Replace edits the field: the watch would read that as an edit.
        editWatcher.stop("fix a word")
        dismissCard()
        listRoute = .fix(id); resetFix()
    }
    /// The pill's Fix and the Fix last dictation shortcut (⌃⌥F): Fix a word on the newest dictation, no navigation.
    /// On the pet when it shares the screen with the focused window, else the floating editor there.
    func quickFix() {
        guard let id = DictationQuickFix.target(recent, busy: busy) else {
            if !busy { message = "Nothing dictated yet to fix." }
            return
        }
        flashTask?.cancel(); flashTask = nil; fixOfferID = nil
        if case .flash = pill { pill = .hidden }
        let placement = DictationPlacement.choose(petFrame: petFrame?(), focusedWindow: DictationFocusedWindow.frame(),
                                                  screens: NSScreen.screens.map(\.frame), mainScreen: NSScreen.main?.frame)
        if case .floating(let screen)? = placement { surface = .floating; floatingScreen = screen } else { surface = .pet; floatingScreen = nil }
        openFix(id)
    }
    func closeList() { listRoute = nil; resetFix() }
    func backToRecent() { listRoute = .recent; resetFix() }
    /// Cancel on Fix a word goes back to the dictation on the pet; the floating editor has nothing behind it.
    func cancelFix() {
        guard case .fix(let id)? = listRoute else { return }
        if surface == .pet { listRoute = .detail(id); resetFix() } else { closeList() }
    }
    /// An outside click closes the list like the session lists, unless a fix is half typed.
    func closeListOnOutsideClick() {
        if case .fix? = listRoute, fixSelection != nil || !fixDraft.isEmpty || fixSaving { return }
        closeList()
    }
    func selectFixWord(_ index: Int) {
        guard case .fix(let id)? = listRoute, let record = self.record(id) else { return }
        let before = fixHeard
        let tokens = DictationFixText.tokens(record.text)
        guard tokens.indices.contains(index) else { return }
        var suggestion: String?
        if fixSelection == nil {
            // 0.5.313 first tap: the likely misheard span and a dictionary suggestion ("yellow fanduna" → "yellowfin tuna").
            let nearby = max(0, index - DictationFixGuess.maximumWords)...min(max(0, tokens.count - 1), index + DictationFixGuess.maximumWords)
            let english = Set(tokens.indices.filter { nearby.contains($0) }.map { DictationFixText.heard(tokens, $0...$0) }.filter { Self.isEnglishWord($0) })
            let guess = DictationFixGuess.guess(tokens: tokens, tapped: index, vocabulary: TranscriptionDictionaryStore.shared.vocabulary,
                                                known: { english.contains($0) })
            fixSelection = guess.range; suggestion = guess.suggestion
        } else {
            fixSelection = DictationFixText.select(index, current: fixSelection)
        }
        // Prefill the suggestion, else what was heard, but never over a spelling the person already typed.
        if fixDraft.isEmpty || fixDraft == before || fixDraft == fixSuggestion {
            fixDraft = suggestion ?? fixSelection.map { DictationFixText.heard(tokens, $0) } ?? ""
        }
        fixSuggestion = suggestion
        replaceOffer = nil
        fixNote = suggestion.map { "Suggested from your dictionary. Press Return to save “\($0)”." }
    }
    /// A word the system spell checker accepts. Only the few words around the tap are checked.
    private static func isEnglishWord(_ word: String) -> Bool {
        !word.isEmpty && NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
    }
    var fixHeard: String {
        guard case .fix(let id)? = listRoute, let record = self.record(id), let range = fixSelection else { return "" }
        return DictationFixText.heard(DictationFixText.tokens(record.text), range)
    }
    func saveFix(to dictionary: TranscriptionDictionaryStore) {
        let heard = fixHeard, written = fixDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fixSaving else { return }
        guard !heard.isEmpty, !written.isEmpty, heard != written else {
            fixNote = heard.isEmpty ? "Tap the word COS got wrong first." : "Type how it should be written."; return
        }
        fixSaving = true; fixNote = nil
        let selection = fixSelection
        let recordID: UUID? = { if case .fix(let id)? = listRoute { return id }; return nil }()
        Task {
            let saved = await dictionary.learn(heard: heard, written: written, source: "dictation")
            fixSaving = false
            if saved {
                fixSelection = nil; fixDraft = ""; fixSuggestion = nil
                fixNote = dictionary.message ?? "Saved. COS writes “\(written)” from the next sentence."
                if let recordID, let selection, let fixed = self.record(recordID),
                   let corrected = DictationReplace.corrected(fixed.text, range: selection, written: written) {
                    // 0.5.318: the dictation itself now reads the fix (Heard, history, Copy), whether or not it is
                    // replaced in the app; the insert target still describes what the field holds.
                    recent = DictationHistory.correcting(recordID, to: corrected, in: recent)
                    saveRecent()
                    // 0.5.331: Claude's waiting version predates this fix; Apply polished would undo it.
                    pendingPolish[recordID] = nil
                    fixNote = (dictionary.message.map { $0 + " " } ?? "Saved. ") + "This dictation now reads “\(written)”, and COS writes it that way from the next sentence."
                    // 0.5.313: offer the corrected dictation back where it went (or on the clipboard).
                    replaceOffer = DictationReplaceOffer(recordID: recordID, corrected: corrected, app: insertTargets[recordID]?.app)
                }
            }
            else { fixNote = dictionary.message ?? "The dictionary did not save. Try again." }
        }
    }
    /// Replace it in <App>: only where COS can prove the spot still holds exactly what it inserted; anything else
    /// (a terminal, a paste it could not measure, an edited field) copies the corrected text. Never presses Return.
    func replaceCorrected() {
        guard let offer = replaceOffer, record(offer.recordID) != nil else { return }
        replaceOffer = nil
        guard let target = insertTargets[offer.recordID] else {
            copy(offer.corrected); fixNote = "Copied the corrected text."; return
        }
        Task {
            // The record already reads the fix (saveFix); this moves the field to match, or says why it could not.
            let replaced = await DictationInsertion.replace(target, corrected: offer.corrected, restoreClipboard: restoreClipboard)
            insertTargets[offer.recordID] = replaced.target
            switch replaced.result {
            case .replaced:
                fixNote = "Replaced it in \(target.app)."
            case .copied(let reason):
                copy(offer.corrected); fixNote = DictationReplace.copiedNote(reason, app: target.app)
            case .unverified(let pasted):
                copy(offer.corrected); fixNote = DictationReplace.unverifiedNote(app: target.app, pasted: pasted)
            case .replacedUnconfirmed, .mismatch:
                copy(offer.corrected); fixNote = DictationReplace.unverifiedNote(app: target.app, pasted: true)
            }
        }
    }
    private func rememberTarget(_ target: DictationInsertTarget, for id: UUID) {
        insertTargets[id] = target
        let keep = Set(([id] + recent.prefix(DictationHistory.petCount).map(\.id)))
        insertTargets = insertTargets.filter { keep.contains($0.key) }
        pendingPolish = pendingPolish.filter { keep.contains($0.key) }
    }
    /// 0.5.337 (loop audit W4): the Settings line follows the server's pause; the pill says it once a day, after this
    /// dictation's own pill is done.
    private func notePolishPause(_ outcome: DictationPolish.Outcome) {
        if DictationPolishPause.clears(outcome) { if polishPause != nil { polishPause = nil }; return }
        guard let code = DictationPolishPause.code(outcome) else { return }
        if polishPause != code { polishPause = code }
        let today = ActivityHome.dayKey(Date())
        guard DictationPolishPause.shouldFlash(lastFlashedDay: UserDefaults.standard.string(forKey: DictationPolishPause.flashedDayKey), today: today) else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.pill == .hidden, !self.busy else { return }
            UserDefaults.standard.set(today, forKey: DictationPolishPause.flashedDayKey)
            let flash = DictationPill.flash(label: DictationPolishPause.pill(code), confirmed: false)
            self.pill = flash
            self.flashTask?.cancel()
            self.flashTask = Task {
                try? await Task.sleep(for: .seconds(DictationQuickFix.offerSeconds))
                if !Task.isCancelled, self.pill == flash { self.pill = .hidden }
            }
            dictationLog.notice("polish paused code=\(code, privacy: .public) pill shown")
        }
    }
    // MARK: Learn from my edits (0.5.318)

    /// A watched edit gave a pair: saved now (with Undo in Recent corrections and the Dictation tab), or suggested.
    private func editLearned(_ candidate: DictationEditLearning.Candidate, app: String) {
        let now = Date()
        guard learnMode != .off, !DictationSuggestions.isQuiet(candidate.heard, candidate.written, in: suggestions, now: now) else {
            dictationLog.notice("learn quiet mode=\(self.learnMode.rawValue, privacy: .public)"); return
        }
        let item = DictationSuggestion(id: UUID(), heard: candidate.heard, written: candidate.written, app: app, at: now, evidence: candidate.evidence)
        if learnMode == .suggest {
            suggestions = DictationSuggestions.suggesting(item, in: suggestions, now: now); saveSuggestions()
            dictationLog.notice("learn suggested")
            return
        }
        // 0.5.342: the watch's ending waits for this save, so its pill and card know what was learned.
        learnSaves.append(Task {
            guard await TranscriptionDictionaryStore.shared.learn(heard: item.heard, written: item.written, source: "dictation") else {
                // 0.5.337 (loop audit W14): a failed save keeps the edit as a suggestion, so Add in Dictation is the retry.
                suggestions = DictationSuggestions.suggesting(item, in: suggestions, now: Date()); saveSuggestions()
                dictationLog.notice("learn save failed, kept as a suggestion"); return
            }
            suggestions = DictationSuggestions.learning(item, in: suggestions, now: Date()); saveSuggestions()
            dictationLog.notice("learn saved")
            if pill == .hidden, !busy {
                let flash = DictationPill.flash(label: "✓ LEARNED · " + item.written.uppercased(), confirmed: true)
                pill = flash
                // 0.5.338: Undo right on the pill, for as long as Fix would show; the Learned list keeps it 30 days.
                learnedUndoID = item.id; learnedUndoPill = flash
                flashTask?.cancel()
                flashTask = Task {
                    try? await Task.sleep(for: .seconds(DictationQuickFix.offerSeconds))
                    if !Task.isCancelled, pill == flash { pill = .hidden }
                    if learnedUndoID == item.id { learnedUndoID = nil; learnedUndoPill = nil }
                }
            }
        })
    }
    /// 0.5.338: the pill's Undo on "✓ LEARNED · WORD": the same Undo as the Learned list, then the pill goes.
    func undoLearnedFromPill() {
        guard let id = pillUndoID else { return }
        learnedUndoID = nil; learnedUndoPill = nil
        flashTask?.cancel()
        pill = .hidden
        Task { await undoLearned(id) }
    }
    // MARK: Your edit, confirmed (0.5.342)

    /// A watch ended. The person's own edit inside the dictation goes on its history record, and the pill says so once:
    /// "✓ EDIT SAVED" with View, or "✓ EDIT SAVED · LEARNED WORD" with Undo when a word was learned and more was edited.
    /// A learned-only edit keeps the pill it had when it was learned. The log has counts and verdicts, never the words.
    private func editWatchEnded(_ end: DictationWatchEnd) async {
        let saves = learnSaves; learnSaves = []
        for save in saves { await save.value }
        guard let id = end.recordID, let final = end.finalText, let record = record(id) else {
            if end.inside > 0 { dictationLog.notice("learn edit saved=false inside=\(end.inside) read=\(end.finalText != nil)") }
            return
        }
        let learned = suggestions.learned.filter { item in
            item.at >= end.started && end.candidates.contains { $0.heard == item.heard && $0.written == item.written }
        }
        guard let edit = DictationEditConfirm.edit(typed: end.typed, recordText: record.text, final: final, app: end.app, at: Date(),
                                                   inside: end.inside, learned: learned) else {
            dictationLog.notice("learn edit saved=false inside=\(end.inside) record=changed"); return
        }
        recent = DictationHistory.editing(id, edit: edit, in: recent); saveRecent()
        let shown = DictationEditConfirm.pill(typed: record.text, final: final, learned: learned.map { (heard: $0.heard, written: $0.written) })
        dictationLog.notice("learn edit saved=true edits=\(edit.edits) learned=\(learned.count) pill=\(shown.logName, privacy: .public)")
        // Never over a newer dictation's pill: only a hidden pill, or this watch's own LEARNED flash, gives way.
        guard DictationEditConfirm.showsAtEnd(shown), let label = DictationEditConfirm.label(shown), !busy,
              pill == .hidden || (learnedUndoPill != nil && pill == learnedUndoPill) else { return }
        let flash = DictationPill.flash(label: label, confirmed: true)
        if case .savedAndLearned = shown, let undo = learned.last {
            editViewID = nil; editViewPill = nil
            learnedUndoID = undo.id; learnedUndoPill = flash
        } else {
            learnedUndoID = nil; learnedUndoPill = nil
            editViewID = id; editViewPill = flash
        }
        pill = flash
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(for: .seconds(DictationQuickFix.offerSeconds))
            if !Task.isCancelled, pill == flash { pill = .hidden }
            if editViewPill == flash { editViewID = nil; editViewPill = nil }
            if learnedUndoPill == flash { learnedUndoID = nil; learnedUndoPill = nil }
        }
    }
    /// View on "✓ EDIT SAVED": that dictation's card on the pet, or Activity, Dictation history when the pet is not showing.
    func viewEditFromPill() {
        guard let id = pillViewID else { return }
        editViewID = nil; editViewPill = nil
        flashTask?.cancel()
        pill = .hidden
        if petFrame?() != nil, !busy {
            surface = .pet
            openDetail(id)
        } else {
            openHistory?()
        }
    }
    /// Undo learn on the card: the same Undo as the pill and the Learned list, for each word this edit taught.
    func undoLearnedFromCard(_ record: DictationRecord) async {
        for id in record.edit?.learnedIDs ?? [] where suggestions.learned.contains(where: { $0.id == id }) { await undoLearned(id) }
    }
    /// The written forms an edit taught that are still in the dictionary (an Undo takes one out).
    func liveLearned(_ record: DictationRecord) -> [String] {
        guard let edit = record.edit else { return [] }
        return zip(edit.learnedIDs, edit.learned).filter { pair in suggestions.learned.contains { $0.id == pair.0 } }.map { $0.1 }
    }
    /// The chip's phrase for this card, from the tested rule and the person's dictionary.
    func dropPhrase(_ record: DictationRecord) -> String? {
        guard let edit = record.edit, edit.learned.isEmpty else { return nil }
        let dictionary = TranscriptionDictionaryStore.shared
        let terms = Set(dictionary.vocabulary.map { $0.lowercased() } + dictionary.corrections.map { $0.written.lowercased() })
        return DictationEditConfirm.dropPhrase(parts: DictationWordDiff.diff(original: record.text, final: edit.text),
                                               isTerm: { terms.contains($0.lowercased()) })
    }

    /// Suggest only's review: Add one, or Add all. Only the ones the dictionary took leave the list.
    func applySuggestions(_ ids: Set<UUID>) async {
        var added: Set<UUID> = []
        for item in suggestions.suggestions where ids.contains(item.id) {
            if await TranscriptionDictionaryStore.shared.learn(heard: item.heard, written: item.written, source: "dictation") { added.insert(item.id) }
        }
        suggestions = DictationSuggestions.applying(added, in: suggestions, now: Date()); saveSuggestions()
    }
    func dismissSuggestion(_ id: UUID) {
        suggestions = DictationSuggestions.dismissing(id, in: suggestions, now: Date()); saveSuggestions()
    }
    /// Undo on something COS saved on its own: the dictionary entry it made is reversed, and the pair stays quiet.
    func undoLearned(_ id: UUID) async {
        guard let item = suggestions.learned.first(where: { $0.id == id }) else { return }
        let dictionary = TranscriptionDictionaryStore.shared
        let rows = dictionary.recent.map { (id: $0.id, heard: $0.heard, written: $0.written) }
        let undone: Bool
        if let entry = DictationSuggestions.recentID(for: item, in: rows) { undone = await dictionary.undo(entry) }
        else { undone = await dictionary.removeCorrection(item.heard) }
        // 0.5.337 (loop audit N15): a failed Undo keeps the row (the dictionary's message says why), so Undo is the retry.
        guard undone else { dictationLog.notice("learn undo failed"); return }
        suggestions = DictationSuggestions.dismissing(id, in: suggestions, now: Date()); saveSuggestions()
    }
    /// Suggestions past their week drop out while COS runs, not only at launch.
    func pruneSuggestions() {
        let next = DictationSuggestions.pruned(suggestions, now: Date())
        if next != suggestions { suggestions = next; saveSuggestions() }
    }
    private func saveSuggestions() {
        guard let suggestionsURL else { return }
        do { try DictationSuggestions.save(suggestions, to: suggestionsURL) }
        catch { dictationLog.error("dictation suggestions not saved: \(error.localizedDescription, privacy: .public)") }
    }
    private func resetFix() { fixSelection = nil; fixDraft = ""; fixNote = nil; fixSaving = false; fixSuggestion = nil; replaceOffer = nil }
}

enum DictationSurface: Equatable, Sendable { case pet, floating }

enum DictationListRoute: Equatable, Sendable {
    case recent, detail(UUID), fix(UUID)
    var isFix: Bool { if case .fix = self { return true }; return false }
}

/// One card at a time. `countdown` folds it after 20 seconds; hovering pauses it.
struct DictationCard: Equatable, Identifiable {
    enum Kind: Equatable { case copied(DictationInsertPolicy.Refusal), failed(String, action: DictationFailureAction) }
    let id = UUID()
    let kind: Kind
    let recordID: UUID?
    let text: String
    var countdown: DictationCountdown
    var title: String {
        switch kind {
        case .copied(let refusal): refusal.title
        case .failed: "NOTHING INSERTED"
        }
    }
    var note: String {
        switch kind {
        case .copied(let refusal): refusal.note
        case .failed(let reason, _): reason
        }
    }
}

/// The bars' levels, newest last.
@MainActor final class DictationMeterFeed: ObservableObject {
    static let bars = DictationBars.count
    @Published private(set) var history = [Double](repeating: 0, count: DictationMeterFeed.bars)
    func push(_ level: Double) { history.removeFirst(); history.append(level) }
    func reset() { if history.contains(where: { $0 != 0 }) { history = [Double](repeating: 0, count: Self.bars) } }
}

struct MacDictationSettings: View {
    @ObservedObject var store: MacDictationStore
    let activityShortcut: HotKeyCombo?
    @State private var confirmingDontKeep = false
    @State private var confirmingClear = false
    /// "Don't keep" waits for a confirm, because choosing it deletes the history already on this Mac.
    private var retentionChoice: Binding<DictationRetention> {
        Binding(get: { store.retention }, set: { next in
            if next.writesToDisk { store.setRetention(next) } else if store.retention.writesToDisk { confirmingDontKeep = true }
        })
    }
    private var microphoneOptions: [COSDropdownOption<String>] {
        var options = [COSDropdownOption("", "System default")]
        options += store.microphones.map { COSDropdownOption($0.id, $0.name) }
        if !store.microphoneUID.isEmpty, !store.microphones.contains(where: { $0.id == store.microphoneUID }) {
            options.append(COSDropdownOption(store.microphoneUID, "Selected microphone disconnected"))
        }
        return options
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Dictate into Mac apps", isOn: $store.enabled).toggleStyle(COSSwitchStyle()).disabled(store.busy)
            Text("Transcribed on this Mac with your COS dictionary, by Parakeet Ultra or Whisper (Settings, Transcription). Glasses are optional. Dictation uses your microphone; Record on Mac captures meeting playback.")
                .font(.caption2).foregroundStyle(.secondary)
            if store.enabled {
                COSDropdown("Microphone", selection: $store.microphoneUID, options: microphoneOptions).disabled(store.busy)
                Button("Refresh microphones") { store.refreshMicrophones() }.controlSize(.small)
                DictationShortcutRow(store: store, slot: .hold, activityShortcut: activityShortcut)
                DictationShortcutRow(store: store, slot: .toggle, activityShortcut: activityShortcut)
                DictationShortcutRow(store: store, slot: .fix, activityShortcut: activityShortcut)
                Button("Allow insertion into other apps…") { store.requestInsertionPermission() }.controlSize(.small)
                DictationSoundSettings(store: store)
                DictationQuietSettings(store: store)
                Toggle("Restore my clipboard after pasting", isOn: $store.restoreClipboard).toggleStyle(COSSwitchStyle())
                    .help("When COS pastes with ⌘V, it puts back whatever you had copied once the app has the text.")
                COSDropdown("Learn from my edits", selection: $store.learnMode,
                            options: DictationLearnMode.allCases.map { COSDropdownOption($0, $0.title) })
                Text(DictationEditLearning.settingNote)
                    .font(.caption2).foregroundStyle(.secondary)
                Toggle("Spell words the way the text box has them", isOn: $store.useFieldContext).toggleStyle(COSSwitchStyle())
                    .help("Before COS types, it reads the words already in the text box, on this Mac only, so a name or term written there comes out spelled the same way.")
                Text("COS reads the text around the cursor before it types, keeps it only for that dictation and never saves or sends it. When you fix a word to a spelling that text already has, Learn from my edits takes it even if it sounds less alike. Never in terminals or password fields.")
                    .font(.caption2).foregroundStyle(.secondary)
                Toggle("Format spoken lists", isOn: $store.formatLists).toggleStyle(COSSwitchStyle())
                    .help("Say “number one, … number two, …” or “bullet, … next bullet, …” and COS writes a numbered or bulleted list, one item per line.")
                // 0.5.325 AI polish: Off by default; the line says what it fixes, what it does not, and how long COS waits.
                COSDropdown("AI polish", selection: $store.polishModel,
                            options: DictationPolishModel.allCases.map { COSDropdownOption($0, $0.title) })
                Text(DictationPolish.settingNote(store.polishModel))
                    .font(.caption2).foregroundStyle(.secondary)
                if store.polishModel != .off, let pause = store.polishPause {
                    Text(DictationPolishPause.settingLine(pause)).font(.caption2).foregroundStyle(COSPalette.amber)
                }
                // 0.5.331 paste first, polish in place: on by default; off is the order before 0.5.331.
                Toggle("Paste right away, then polish in place", isOn: $store.pasteThenPolish).toggleStyle(COSSwitchStyle())
                    .disabled(store.polishModel == .off)
                Text(DictationPolishSwap.settingNote(store.polishModel))
                    .font(.caption2).foregroundStyle(.secondary)
                // 0.5.335 (server 6.85.0): Your polish instructions, after the built-in rules. Absent on an older server.
                DictationPolishInstructionsCard(store: DictationPolishInstructionsStore.shared, polishOn: store.polishModel != .off)
                Text("Any shortcut: a modifier plus a key, a function key, or one modifier key by itself such as Fn 🌐 or Right ⌘. Fn and single-key shortcuts use Accessibility. Finished text drops into the text box that has the cursor; with no text box it is copied, and the pet shows it with a Copy button. Some apps, such as terminals and Electron editors, get ⌘V; COS shows Pasted when it can't confirm, then puts your clipboard back. COS never presses Send or Return.")
                    .font(.caption2).foregroundStyle(.secondary)
                if let message = store.message { Text(message).font(.caption2).foregroundStyle(COSPalette.amber) }
            }
            // 0.5.312: dictations stay on this Mac for the chosen time, never more than DictationHistory.cap.
            COSDropdown("Keep dictations for", selection: retentionChoice,
                        options: DictationRetention.allCases.map { COSDropdownOption($0, $0.title) })
                .disabled(store.busy)
            Button("Clear dictation history") { confirmingClear = true }
                .controlSize(.small)
                .disabled(store.recent.isEmpty || store.busy)
        }
        .onAppear { store.refreshMicrophones() }
        .cosConfirm(
            "Stop keeping dictations?",
            isPresented: $confirmingDontKeep,
            message: "COS deletes the dictations kept on this Mac and saves none from now on. The pet still shows this session's.",
            actions: [
                .destructive("Delete and stop keeping") { store.stopKeepingHistory() },
                .cancel(),
            ]
        )
        .cosConfirm(
            "Clear dictation history?",
            isPresented: $confirmingClear,
            message: "Every dictation kept on this Mac is deleted. Your dictionary stays as it is.",
            actions: [
                .destructive("Clear history") { store.clearRecent() },
                .cancel(),
            ]
        )
    }
}

/// While dictating: Mute other apps (default) / Lower other audio / Off (0.5.313). "Also pause music and video" is not
/// offered: COS cannot read what is playing (see DictationMedia), and a blind play/pause key can start playback.
private struct DictationQuietSettings: View {
    @ObservedObject var store: MacDictationStore
    @State private var permitted = DictationQuietController.tapPermitted
    var body: some View {
        COSDropdown("While dictating", selection: $store.quietMode,
                    options: DictationQuietMode.allCases.map { COSDropdownOption($0, $0.title) })
            .disabled(store.busy)
        if store.quietMode == .mute, !permitted {
            Text("Muting other apps needs System Audio Recording for COS Control. Until it's allowed, COS lowers your Mac's volume while you dictate and puts it back after.")
                .font(.caption2).foregroundStyle(COSPalette.amber)
            // 0.5.318: macOS's own prompt first, which is what adds COS Control to the list; then the drag flow.
            Button("Allow System Audio Recording…") {
                Task { permitted = await store.requestSystemAudioPermission() }
            }.controlSize(.small)
        }
        if store.quietMode == .mute, permitted, let note = store.quietNote {
            Text(note).font(.caption2).foregroundStyle(COSPalette.amber)
            Button("Check System Audio Recording…") {
                Task { permitted = await store.requestSystemAudioPermission(wantsPane: true) }
            }.controlSize(.small)
        }
        Text("Never during a Mac recording. Music and video stay muted, not paused: COS can't tell what's playing, so it never presses Play/Pause.")
            .font(.caption2).foregroundStyle(.secondary)
            .onAppear { permitted = DictationQuietController.tapPermitted }
    }
}

private struct DictationShortcutRow: View {
    @ObservedObject var store: MacDictationStore
    let slot: DictationShortcutSlot
    let activityShortcut: HotKeyCombo?
    @State private var monitor: Any?
    @State private var note: String?
    @State private var pendingModifier: UInt16?
    /// 0.5.329: reads the keyboard while a lone modifier is pending (watchPending).
    @State private var recorderWatch: Task<Void, Never>?
    var body: some View {
        HStack {
            Text(slot.title).font(.caption)
            Text(monitor != nil ? "Press shortcut…" : (store.trigger(slot)?.display ?? "Off")).font(.caption.monospaced())
            Button(monitor == nil ? "Change" : "Cancel") { monitor == nil ? record() : stop() }
            Button("Off") { store.setShortcut(nil, slot: slot, activity: activityShortcut); stop() }
            if let note { Text(note).font(.caption2) }
        }.controlSize(.mini).disabled(store.busy).onDisappear { stop() }
    }
    private func record() {
        note = nil; pendingModifier = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let keyDown = event.type == .keyDown, key = event.keyCode, raw = UInt64(event.modifierFlags.rawValue)
            let modifiers = HotKeyCombo.carbonModifiers(from: event.modifierFlags)
            MainActor.assumeIsolated { recorded(keyDown: keyDown, key: key, raw: raw, modifiers: modifiers) }
            return nil
        }
    }
    /// A key with modifiers or a function key is a Carbon shortcut. A modifier pressed and released with
    /// nothing else (Fn, Right ⌘) becomes a lone-modifier shortcut.
    private func recorded(keyDown: Bool, key: UInt16, raw: UInt64, modifiers: UInt32) {
        if keyDown {
            pendingModifier = nil
            if key == 53 { stop() }
            else if let trigger = DictationTrigger.keys(UInt32(key), modifiers: modifiers) { store.setShortcut(trigger, slot: slot, activity: activityShortcut); stop() }
            else { note = "Add Command, Control or Option, use a function key, or press one modifier key such as Fn by itself." }
            return
        }
        guard let info = DictationTrigger.modifierKeys[key] else { return }
        if raw & info.device != 0 {
            pendingModifier = DictationTrigger.alone(key, flags: raw) ? key : nil
            if pendingModifier == key { watchPending(key) }
        } else if pendingModifier == key {
            finishModifier(key)
        } else { pendingModifier = nil }
    }
    private func finishModifier(_ key: UInt16) {
        guard let trigger = DictationTrigger.modifier(key) else { return }
        store.setShortcut(trigger, slot: slot, activity: activityShortcut); stop()
    }
    /// 0.5.329 (Miles 2026-10-19): macOS can swallow Fn's release (TextInputSwitcher), so recording Fn by itself sat at
    /// "Press shortcut…" for good. While a lone modifier is pending, read the keyboard's own state with the hold watch's
    /// rule and cadence: two up reads after a down read finish the recording, as the release would have. A keyboard that
    /// never showed the key down is never finished this way.
    private func watchPending(_ key: UInt16) {
        recorderWatch?.cancel()
        recorderWatch = Task { @MainActor in
            var reads = DictationHoldWatch.Reads()
            while !Task.isCancelled, monitor != nil, pendingModifier == key,
                  let down = DictationHoldWatch.modifierDown(flags: CGEventSource.flagsState(.hidSystemState).rawValue, keyCode: key) {
                if reads.read(down: down) { finishModifier(key); break }
                try? await Task.sleep(for: .milliseconds(DictationHoldWatch.pollMilliseconds))
            }
        }
    }
    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        recorderWatch?.cancel(); recorderWatch = nil
    }
}

extension DictationTrigger {
    /// Menu-style: ⌃⌥⇧⌘ then the key, or the lone modifier's name.
    var display: String {
        switch self {
        case .modifier(let key): return Self.modifierKeys[key]?.name ?? "Key \(key)"
        case .keys(let key, let modifiers):
            var text = ""
            if modifiers & Self.control != 0 { text += "⌃" }
            if modifiers & Self.option != 0 { text += "⌥" }
            if modifiers & Self.shift != 0 { text += "⇧" }
            if modifiers & Self.command != 0 { text += "⌘" }
            return text + (Self.functionKeys[key] ?? HotKeyCombo.keyName(key))
        }
    }
}

// MARK: - Wispr-style surfaces (0.5.309)
//
// Built to the approved mock (design/dictation-wispr-mock.html, moments 01-07; Miles picked A/A/A, 2026-10-15 18:16)
// from the pet's own pieces: the ledger pill, the session list and its card. The persistent "COS Dictation" window is
// gone. With the pet showing, the pill takes the ledger's slot (SessionPet.swift ledgerSlot); with the pet hidden, the
// same pill and card float above the Dock in DictationOverlayPresenter's panel.

/// The overlay's panel. It becomes key only while Fix a word's field is open, so it never takes focus by showing.
final class DictationOverlayPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// The first click on Copy acts, rather than only reaching a window of an app that is not active.
private final class DictationHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Pet hidden (mock 02, 04): a dark pill at the bottom center of the main screen above the Dock, and the card rising
/// from it. Borderless and nonactivating; it ignores the mouse while only the pill shows, so it cannot steal focus.
@MainActor final class DictationOverlayPresenter {
    private var panel: DictationOverlayPanel?
    private var host: DictationHostingView<DictationOverlayRoot>?
    private var observers: [AnyCancellable] = []
    private weak var store: MacDictationStore?

    func bind(store: MacDictationStore) {
        self.store = store
        // @Published fires before the value lands; the hop reads the new state, as SessionPetPresenter does.
        observers = [
            store.$pill.map(\.label).removeDuplicates().sink { [weak self] _ in Task { @MainActor in self?.sync() } },
            store.$card.map { $0?.id }.removeDuplicates().sink { [weak self] _ in Task { @MainActor in self?.sync() } },
            store.$listRoute.removeDuplicates().sink { [weak self] _ in Task { @MainActor in self?.sync() } },
            store.$surface.removeDuplicates().sink { [weak self] _ in Task { @MainActor in self?.sync() } },
            store.$fixNote.removeDuplicates().sink { [weak self] _ in Task { @MainActor in self?.sync() } },
            store.$fixOfferID.removeDuplicates().sink { [weak self] _ in Task { @MainActor in self?.sync() } },
            store.$learnedUndoID.removeDuplicates().sink { [weak self] _ in Task { @MainActor in self?.sync() } },
            store.$replaceOffer.removeDuplicates().sink { [weak self] _ in Task { @MainActor in self?.sync() } },
        ]
    }

    private func sync() {
        guard let store else { return }
        let fixing = store.listRoute?.isFix == true
        guard store.surface == .floating, store.pill != .hidden || store.card != nil || fixing else {
            panel?.allowsKey = false
            if panel?.isVisible == true { panel?.orderOut(nil) }
            return
        }
        let panel = existingPanel(store)
        host?.rootView = DictationOverlayRoot(store: store)
        // The pill's Fix (0.5.313) is the one control on a bare pill, so the panel takes clicks while it shows.
        panel.ignoresMouseEvents = store.card == nil && !fixing && store.fixOfferID == nil && store.pillUndoID == nil && store.pillViewID == nil
        panel.allowsKey = fixing
        place(panel, size: host?.fittingSize ?? NSSize(width: 360, height: 60))
        if fixing { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
    }

    /// 0.5.337: inside the visible frame of the panel's screen (DictationOverlayFrame), now and whenever its content resizes it.
    private var placing = false
    private func place(_ panel: DictationOverlayPanel, size: NSSize) {
        let chosen = store?.floatingScreen.flatMap { frame in NSScreen.screens.first { $0.frame == frame } } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = chosen?.visibleFrame else { return }
        let frame = DictationOverlayFrame.place(size: size, caret: nil, screen: screen)
        guard frame != panel.frame else { return }
        placing = true; defer { placing = false }
        panel.setFrame(frame, display: true)
    }
    private func panelResized() {
        guard !placing, let panel, panel.isVisible else { return }
        place(panel, size: panel.frame.size)
    }

    private func existingPanel(_ store: MacDictationStore) -> DictationOverlayPanel {
        if let panel { return panel }
        let host = DictationHostingView(rootView: DictationOverlayRoot(store: store))
        let panel = DictationOverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 60),
                                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        self.host = host
        self.panel = panel
        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelResized() }
        }
        return panel
    }
    private var resizeObserver: NSObjectProtocol?
}

struct DictationOverlayRoot: View {
    @ObservedObject var store: MacDictationStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let size = PetSize(preset: .medium, customPixels: PetSize.mediumPixels)
    var body: some View {
        VStack(spacing: 8) {
            if let card = store.card {
                DictationCardView(store: store, card: card, size: size, reduceMotion: reduceMotion)
            }
            if case .fix(let id)? = store.listRoute, let record = store.record(id) {
                DictationFixEditor(store: store, dictionary: TranscriptionDictionaryStore.shared, record: record, size: size, onOpenDictionary: nil)
                    .frame(width: 340)
                    .dictationSurface(size)
            }
            if store.pill != .hidden {
                DictationListeningPill(pill: store.pill, meter: store.meter, floating: true, size: size, reduceMotion: reduceMotion,
                                       onFix: store.fixOfferID == nil ? nil : { store.quickFix() },
                                       onView: store.pillViewID == nil ? nil : { store.viewEditFromPill() },
                                       onUndo: store.pillUndoID == nil ? nil : { store.undoLearnedFromPill() })
            }
        }
        .padding(14)
        .fixedSize()
    }
}

/// One pill for both places (mock 01, 02, 03), so its meaning never changes. On the pet it sits in the ledger's slot
/// on the card fill; above the Dock it is dark. Levels come from DictationMeterFeed, so only the pill redraws at 20 Hz.
struct DictationListeningPill: View {
    let pill: DictationPill
    @ObservedObject var meter: DictationMeterFeed
    let floating: Bool
    let size: PetSize
    let reduceMotion: Bool
    /// 0.5.313: Fix on the flash, for DictationQuickFix.offerSeconds. Nil: no button.
    var onFix: (() -> Void)? = nil
    /// 0.5.342: View on "✓ EDIT SAVED", for the same time: the dictation's card. Nil: no button.
    var onView: (() -> Void)? = nil
    /// 0.5.338: Undo on "✓ LEARNED · WORD", for the same time. Nil: no button.
    var onUndo: (() -> Void)? = nil

    /// Green with ✓ only for a measured insertion; an unconfirmed paste flashes in the neutral colors.
    private var done: Bool { if case .flash(_, true) = pill { return true }; return false }
    private var fill: Color { done ? COSPalette.green : (floating ? COSPalette.ink : COSPalette.card) }
    private var ink: Color { done ? .white : (floating ? COSPalette.cream : COSPalette.plateInk) }

    var body: some View {
        HStack(spacing: size.length(8)) {
            switch pill {
            case .hidden:
                EmptyView()
            case .starting:
                // 0.5.327: an open ring, no bars, no clock: the microphone is not hearing yet. Talk at LISTENING.
                Circle().stroke(ink.opacity(0.55), lineWidth: 1)
                    .frame(width: size.length(6), height: size.length(6))
                    .padding(size.length(2))
                Text(pill.label)
            case .listening(let since):
                Circle().fill(COSPalette.green)
                    .frame(width: size.length(6), height: size.length(6))
                    .padding(size.length(2))
                    .background(Circle().fill(COSPalette.green.opacity(0.3)))
                liveBars
                if floating {
                    Text("COS")
                } else {
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text("LISTENING " + DictationPill.clock(context.date.timeIntervalSince(since))).monospacedDigit()
                    }
                }
            case .transcribing, .polishing, .finishing:
                DictationWorkingBars(size: size, reduceMotion: reduceMotion)
                Text(pill.label)
            case .flash:
                Text(pill.label)
                if let onFix {
                    Button(action: onFix) {
                        Text("FIX")
                            .padding(.horizontal, size.length(7))
                            .padding(.vertical, size.length(2))
                            .background(Capsule().fill(ink.opacity(0.16)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Fix a word in this dictation")
                    .accessibilityLabel("Fix a word in this dictation")
                }
                if let onUndo {
                    Button(action: onUndo) {
                        Text("UNDO")
                            .padding(.horizontal, size.length(7))
                            .padding(.vertical, size.length(2))
                            .background(Capsule().fill(ink.opacity(0.16)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Remove this word from the dictionary")
                    .accessibilityLabel("Undo, remove this word from the dictionary")
                }
                if let onView {
                    Button(action: onView) {
                        Text("VIEW")
                            .padding(.horizontal, size.length(7))
                            .padding(.vertical, size.length(2))
                            .background(Capsule().fill(ink.opacity(0.16)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("See your edit on this dictation's card")
                    .accessibilityLabel("View your edit")
                }
            }
        }
        .font(COSType.mono(size.typeSize(8), weight: .bold))
        .kerning(0.6)
        .lineLimit(1)
        .foregroundStyle(ink)
        .padding(.leading, size.length(10))
        .padding(.trailing, size.length(12))
        .padding(.vertical, size.length(6))
        .background(Capsule().fill(fill))
        .overlay(Capsule().stroke(floating || done ? Color.clear : COSPalette.line, lineWidth: 1))
        .shadow(color: .black.opacity(floating ? 0.18 : 0), radius: 9, y: 6)
        .accessibilityElement(children: onFix == nil && onUndo == nil && onView == nil ? .combine : .contain)
        .accessibilityLabel({ () -> String in
            switch pill {
            case .transcribing: return "Transcribing dictation"
            case .polishing: return "Polishing dictation"
            case .finishing: return "Still finishing the last dictation"
            case .starting: return "Dictation starting"
            case .flash(let label, _): return label
            default: return "Dictation listening"
            }
        }())
    }

    /// Eleven bars from DictationBars (pure, tested from microphone buffer to height).
    private var liveBars: some View {
        let levels = meter.history
        let heights = DictationBars.heights(levels)
        return HStack(spacing: max(1, size.length(2))) {
            ForEach(0..<DictationBars.count, id: \.self) { index in
                Capsule()
                    .frame(width: max(2, size.length(2.5)), height: max(3, CGFloat(heights[index]) * size.scale))
            }
        }
        .frame(height: size.length(15))
        .animation(reduceMotion ? nil : .linear(duration: 0.07), value: levels)
    }
}

/// TRANSCRIBING: seven bars sweeping; still under Reduce Motion.
struct DictationWorkingBars: View {
    let size: PetSize
    let reduceMotion: Bool
    private static let rest: [Double] = [5, 9, 13, 9, 5, 7, 4]
    var body: some View {
        Group {
            if reduceMotion {
                bars { Self.rest[$0] }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    bars { index in
                        let phase: Double = t / 1.1 - Double(index) * 0.09 / 1.1
                        return 3 + 9 * (0.5 - 0.5 * cos(2 * Double.pi * phase))
                    }
                }
            }
        }
        .frame(height: size.length(15))
    }
    private func bars(_ height: @escaping (Int) -> Double) -> some View {
        HStack(spacing: max(1, size.length(2))) {
            ForEach(0..<7, id: \.self) { index in
                Capsule().frame(width: max(2, size.length(2.5)), height: max(3, CGFloat(height(index)) * size.scale))
            }
        }
    }
}

/// The card's two buttons: Copy on the ink fill (the mock's primary), everything else on the card with a hairline.
struct DictationButtonStyle: ButtonStyle {
    var primary = false
    let size: PetSize
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(COSType.body(size.typeSize(10), weight: .semibold))
            .foregroundStyle(primary ? COSPalette.cream : Color.primary)
            .padding(.horizontal, size.length(10))
            .padding(.vertical, size.length(5))
            .background(RoundedRectangle(cornerRadius: size.length(7), style: .continuous)
                .fill(primary ? COSPalette.ink : COSPalette.card))
            .overlay(RoundedRectangle(cornerRadius: size.length(7), style: .continuous)
                .stroke(primary ? Color.clear : COSPalette.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: size.length(7)))
    }
}

extension View {
    /// The pet's card surface: card fill, hairline, 12 pt corners, a soft lift.
    func dictationSurface(_ size: PetSize) -> some View {
        self
            .padding(.horizontal, size.length(12))
            .padding(.vertical, size.length(10))
            .background(COSPalette.card, in: RoundedRectangle(cornerRadius: size.length(12), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size.length(12), style: .continuous).stroke(COSPalette.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.14), radius: 14, y: 8)
    }
}

/// No text box (mock 04): the transcript, Copy first, Fix a word, and a ring on × that folds the card after 20 s.
/// Hover pauses the ring. Shown with orderFrontRegardless only, so the app being typed in keeps focus.
struct DictationCardView: View {
    @ObservedObject var store: MacDictationStore
    let card: DictationCard
    let size: PetSize
    let reduceMotion: Bool
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: size.length(7)) {
            HStack(spacing: size.length(7)) {
                DictationWorkingBars(size: size, reduceMotion: true)
                    .foregroundStyle(COSPalette.plateInk)
                Text(card.title)
                    .font(COSType.mono(size.typeSize(8), weight: .bold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button { store.dismissCard() } label: {
                    ZStack {
                        Circle().stroke(COSPalette.line, lineWidth: 1)
                        TimelineView(.periodic(from: .now, by: reduceMotion ? 1 : 0.1)) { context in
                            Circle()
                                .trim(from: 0, to: card.countdown.fraction(at: context.date))
                                .stroke(COSPalette.gold, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        Image(systemName: "xmark").font(.system(size: size.typeSize(8), weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .frame(width: size.length(20), height: size.length(20))
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close. The text stays in Recent dictations.")
                .accessibilityLabel("Close")
            }
            if !card.text.isEmpty {
                Text(card.text)
                    .font(COSType.body(size.typeSize(11)))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(card.note)
                .font(COSType.body(size.typeSize(10)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: size.length(7)) {
                switch card.kind {
                case .copied(let refusal):
                    Button(copied ? "Copied" : "Copy") {
                        store.copy(card.text); copied = true
                        Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
                    }
                    .buttonStyle(DictationButtonStyle(primary: true, size: size))
                    // 0.5.310: the card that says Accessibility is off carries the way to turn it on.
                    if refusal == .notTrusted {
                        Button("Allow…") { store.requestInsertionPermission() }
                            .buttonStyle(DictationButtonStyle(size: size))
                        // 0.5.318: the row can read ON for an older copy; the note says "Already on? Reset and add again."
                        Button("Reset") { store.resetInsertionPermission() }
                            .buttonStyle(DictationButtonStyle(size: size))
                            .help("Already on in System Settings? Removes COS Control's old Accessibility entry so you can add this copy.")
                    }
                    Button("Fix a word") { store.openFix(card.recordID) }
                        .buttonStyle(DictationButtonStyle(size: size))
                        .disabled(card.recordID == nil)
                case .failed(_, let action):
                    // One action, and Retry only while the held audio can be retried (QA: never a dead Retry).
                    if let title = action.title, action != .retry || store.canRetry {
                        Button(title) { store.performFailureAction(action) }
                            .buttonStyle(DictationButtonStyle(primary: true, size: size))
                    }
                }
            }
        }
        .frame(width: size.length(300), alignment: .leading)
        .dictationSurface(size)
        .background(HoverSensor { store.setCardHover($0) })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dictation ready")
    }
}

/// One row of Recent dictations (mock 05): first line, time · words · where it went, Copy.
struct DictationRecordRow: View {
    let record: DictationRecord
    let size: PetSize
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var copied = false
    var body: some View {
        HStack(spacing: size.length(8)) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: size.length(2)) {
                    Text(record.firstLine)
                        .font(COSType.body(size.typeSize(11)))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(record.metaLine(time: DictionaryLabels.when(record.createdAt, now: Date())))
                        .font(COSType.mono(size.typeSize(8), weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("See the full text and Fix a word")
            Button(copied ? "Copied" : "Copy") {
                onCopy(); copied = true
                Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
            }
            .buttonStyle(DictationButtonStyle(size: size))
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: size.typeSize(8), weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(size.length(3))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete this dictation from this Mac")
            .accessibilityLabel("Delete this dictation")
        }
        .padding(.vertical, size.length(6))
        .padding(.trailing, size.length(6))
        .contextMenu {
            Button("Copy", action: onCopy)
            Button("Delete", action: onDelete)
        }
    }
}

/// One dictation, opened from its row: the full text, Copy, and Fix a word.
/// 0.5.342 Your edit, confirmed (mock: wk43_2026/mock-edit-confirm): an edited dictation shows its final words with the
/// edit marked (removed words struck through, added words tinted and underlined), the edits on the meta line, one line on
/// whether anything went to the dictionary, Show original, Undo learn for a learned word, and the drop-a-filler chip.
@MainActor struct DictationRecordDetail: View {
    @ObservedObject var store: MacDictationStore
    let record: DictationRecord
    let size: PetSize
    @ObservedObject var instructions = DictationPolishInstructionsStore.shared
    /// Show original: exactly what COS typed, no marks. Copy follows it.
    @State private var showOriginal = false
    /// The chip was tapped: the phrase it added, for Undo. Nil: not tapped (or undone).
    @State private var dropped: String?
    @State private var dropBusy = false

    private var parts: [DictationWordDiff.Part]? {
        record.edit.flatMap { DictationWordDiff.diff(original: record.text, final: $0.text) }
    }
    private var learnedLive: [String] { store.liveLearned(record) }
    private var dropPhrase: String? { store.dropPhrase(record) }
    private var offersDrop: Bool {
        dropped != nil || DictationEditConfirm.offersDrop(phrase: dropPhrase, available: instructions.available,
                                                          polishOn: store.polishModel != .off, saved: instructions.saved)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: size.length(7)) {
            ScrollView {
                Group {
                    if let edit = record.edit, !showOriginal { Text(Self.marked(parts, final: edit.text)) } else { Text(record.text) }
                }
                .font(COSType.body(size.typeSize(11)))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: size.length(96))
            Text(record.metaLine(time: DictionaryLabels.when(record.createdAt, now: Date())))
                .font(COSType.mono(size.typeSize(8), weight: .medium))
                .foregroundStyle(.secondary)
            if record.edit != nil {
                Text(DictationEditConfirm.reason(parts: parts, learned: learnedLive))
                    .font(COSType.body(size.typeSize(9)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let phrase = dropped ?? dropPhrase, offersDrop { dropChip(phrase) }
            }
            // 0.5.317: which engine ran, and why Automatic used Whisper when it did.
            if let engine = DictationEngineName.detailLine(engine: record.engine, fallbackReason: record.fallbackReason) {
                Text(engine)
                    .font(COSType.body(size.typeSize(9)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 0.5.325: AI polish changed it. What the engine heard stays one click away.
            if let heard = record.heard {
                HStack(alignment: .firstTextBaseline, spacing: size.length(7)) {
                    Text("What was heard: " + heard)
                        .font(COSType.body(size.typeSize(9)))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Copy") { store.copy(heard) }
                        .buttonStyle(DictationButtonStyle(size: size))
                        .help("Copy what was heard, before AI polish")
                }
            }
            actionRow
        }
        .padding(.vertical, size.length(6))
        .padding(.trailing, size.length(8))
        .onChange(of: record.id) { _, _ in showOriginal = false; dropped = nil }
        .task(id: record.edit != nil) {
            if record.edit != nil, !instructions.loaded, !instructions.busy { await instructions.load() }
        }
    }

    /// 0.5.342 (Miles 10:26, the mock card narrow: "Fix a word" broke inside its button, "Show original" wrapped beside
    /// it): one row as designed when it fits, else two rows with the same actions in the same order, nothing hidden. No
    /// label ever wraps inside its control: each is one line at its own width.
    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: size.length(7)) {
                copyButton; learnOrFixButton
                if record.edit != nil { originalLink }
                Spacer(minLength: 0)
                deleteButton; backButton
            }
            VStack(alignment: .leading, spacing: size.length(5)) {
                HStack(spacing: size.length(7)) { copyButton; learnOrFixButton; Spacer(minLength: 0) }
                HStack(spacing: size.length(7)) {
                    if record.edit != nil { originalLink }
                    Spacer(minLength: 0)
                    deleteButton; backButton
                }
            }
        }
    }

    private var copyButton: some View {
        Button("Copy") { store.copy(DictationEditConfirm.copyText(record, showOriginal: showOriginal)) }
            .buttonStyle(DictationButtonStyle(primary: true, size: size))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder private var learnOrFixButton: some View {
        if !learnedLive.isEmpty {
            Button("Undo learn") { Task { await store.undoLearnedFromCard(record) } }
                .buttonStyle(DictationButtonStyle(size: size))
                .help("Remove what COS learned from this edit from your dictionary")
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        } else {
            Button("Fix a word") { store.openFix(record.id) }
                .buttonStyle(DictationButtonStyle(size: size))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var deleteButton: some View {
        Button("Delete") { store.deleteRecord(record.id) }
            .buttonStyle(COSTextButtonStyle(tone: .destructive))
            .font(COSType.body(size.typeSize(10)))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var backButton: some View {
        Button("Back") { store.backToRecent() }
            .buttonStyle(COSTextButtonStyle())
            .font(COSType.body(size.typeSize(10)))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var originalLink: some View {
        Button(showOriginal ? "Show edit" : "Show original") { showOriginal.toggle() }
            .buttonStyle(COSTextButtonStyle())
            .font(COSType.body(size.typeSize(10)))
            .help(showOriginal ? "Show the text with your edit" : "Show exactly what COS typed")
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    /// Always drop "<phrase>" from my dictation: one tap adds it to the polish instructions, through the same setting as
    /// Settings, Dictation. Then it says so, with Undo. Never added without the tap.
    @ViewBuilder private func dropChip(_ phrase: String) -> some View {
        if dropped == phrase {
            HStack(spacing: size.length(7)) {
                Text(DictationEditConfirm.chipAdded)
                    .font(COSType.body(size.typeSize(9)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Undo") {
                    Task {
                        dropBusy = true; defer { dropBusy = false }
                        let next = DictationEditConfirm.removing(phrase, from: instructions.saved)
                        let undone: Bool
                        if next.isEmpty { undone = await instructions.clear() } else { undone = await instructions.save(next) }
                        if undone { dropped = nil }
                    }
                }
                .buttonStyle(COSTextButtonStyle())
                .font(COSType.body(size.typeSize(9)))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(dropBusy)
            }
        } else {
            Button {
                Task {
                    dropBusy = true; defer { dropBusy = false }
                    guard let next = DictationEditConfirm.adding(phrase, to: instructions.saved) else { return }
                    if await instructions.save(next) { dropped = phrase }
                }
            } label: {
                (Text("Always drop ") + Text("\"\(phrase)\"").fontWeight(.semibold).foregroundColor(COSPalette.accent) + Text(" from my dictation"))
                    .font(COSType.body(size.typeSize(9)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, size.length(7))
                    .padding(.vertical, size.length(4))
                    .overlay(RoundedRectangle(cornerRadius: size.length(6), style: .continuous)
                        .stroke(COSPalette.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(dropBusy || instructions.busy)
            .help("Adds this to your polish instructions, so AI polish drops it from later dictations")
            .accessibilityLabel(DictationEditConfirm.chipLabel(phrase))
        }
    }

    /// The final words with the edit marked: removed words struck through in the muted ink, added words with a light
    /// gold tint and a gold underline. No diff (too long): the final words alone.
    static func marked(_ parts: [DictationWordDiff.Part]?, final: String) -> AttributedString {
        guard let parts else { return AttributedString(final) }
        typealias UI = AttributeScopes.SwiftUIAttributes
        var out = AttributedString()
        for part in parts {
            var run = AttributedString(part.text)
            switch part.kind {
            case .same:
                break
            case .removed:
                run[UI.ForegroundColorAttribute.self] = COSPalette.muted
                run[UI.StrikethroughStyleAttribute.self] = Text.LineStyle(pattern: .solid, color: COSPalette.muted)
            case .added:
                run[UI.BackgroundColorAttribute.self] = COSPalette.gold.opacity(0.22)
                run[UI.UnderlineStyleAttribute.self] = Text.LineStyle(pattern: .solid, color: COSPalette.accent)
            }
            out += run
            out += AttributedString(part.trailing)
        }
        return out
    }
}

/// "EDITED IN CLAUDE" in the dictation card's header row (0.5.342): green, as in the mock.
struct DictationEditedTag: View {
    let app: String
    let size: PetSize
    var body: some View {
        Text(DictationEditConfirm.tag(app: app))
            .font(COSType.mono(size.typeSize(7), weight: .bold))
            .kerning(0.4)
            .lineLimit(1)
            .foregroundStyle(COSPalette.green)
            .padding(.horizontal, size.length(5))
            .padding(.vertical, size.length(2))
            .background(COSPalette.green.opacity(0.14), in: RoundedRectangle(cornerRadius: size.length(4), style: .continuous))
            .padding(.trailing, size.length(8))
            .accessibilityLabel("Edited in " + app)
    }
}

/// Fix a word (mock 06): tap the word COS got wrong (tap another to widen to a phrase), type the spelling, Save. It goes
/// into the one COS dictionary that G2 meetings, Mac recordings and dictation already use, so the fix follows Miles
/// everywhere from the next sentence. Recent corrections show what was learned, from where and when, each with Undo.
struct DictationFixEditor: View {
    @ObservedObject var store: MacDictationStore
    @ObservedObject var dictionary: TranscriptionDictionaryStore
    let record: DictationRecord
    let size: PetSize
    /// Opens the Dictionary pane in Activity. Nil where Activity is not the next step (the floating editor).
    let onOpenDictionary: (() -> Void)?
    /// 0.5.318: opens Activity → Dictation to review every suggestion. Nil on the floating editor.
    var onReview: (() -> Void)? = nil
    @FocusState private var fieldFocused: Bool

    private var tokens: [String] { DictationFixText.tokens(record.text) }
    private var learnUnavailable: Bool { dictionary.loaded && !dictionary.learnAvailable }

    var body: some View {
        VStack(alignment: .leading, spacing: size.length(8)) {
            VStack(alignment: .leading, spacing: size.length(7)) {
                Text("Heard:")
                    .font(COSType.body(size.typeSize(10)))
                    .foregroundStyle(.secondary)
                Group {
                    if tokens.count > 24 {
                        ScrollView { words }.frame(height: size.length(84))
                    } else {
                        words
                    }
                }
                Text("ALWAYS WRITE IT AS")
                    .font(COSType.mono(size.typeSize(8), weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(.secondary)
                TextField(store.fixSelection == nil ? "Tap a word above first" : "Spelling", text: $store.fixDraft)
                    .textFieldStyle(.plain)
                    .font(COSType.body(size.typeSize(11)))
                    .focused($fieldFocused)
                    .onSubmit { store.saveFix(to: dictionary) }
                    .onExitCommand { store.cancelFix() }
                    .disabled(store.fixSelection == nil || store.fixSaving)
                    .padding(.horizontal, size.length(9))
                    .padding(.vertical, size.length(5))
                    .background(COSPalette.card, in: RoundedRectangle(cornerRadius: size.length(8), style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: size.length(8), style: .continuous)
                        .stroke(fieldFocused ? COSPalette.gold.opacity(0.7) : COSPalette.line, lineWidth: 1))
                HStack(spacing: size.length(8)) {
                    Button(store.fixSaving ? "Saving…" : "Save to dictionary") { store.saveFix(to: dictionary) }
                        .buttonStyle(DictationButtonStyle(primary: true, size: size))
                        .disabled(store.fixSelection == nil || store.fixSaving || learnUnavailable)
                    Button("Cancel") { store.cancelFix() }
                        .buttonStyle(COSTextButtonStyle())
                        .font(COSType.body(size.typeSize(10)))
                }
                if let offer = store.replaceOffer, offer.recordID == record.id {
                    // 0.5.313: the corrected dictation back where it went, or on the clipboard. Never Return.
                    Button(offer.app.map { "Replace it in \($0)" } ?? "Copy the corrected text") { store.replaceCorrected() }
                        .buttonStyle(DictationButtonStyle(primary: true, size: size))
                        .help("Puts the corrected dictation in place of what COS inserted, only if that text is unchanged; otherwise copies it")
                }
                if let note = store.fixNote {
                    Text(note)
                        .font(COSType.body(size.typeSize(10)))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let message = dictionary.message {
                    // A failed load or undo says so here, rather than leaving "Loading…" forever.
                    Text(message)
                        .font(COSType.body(size.typeSize(10)))
                        .foregroundStyle(COSPalette.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(size.length(10))
            .background(COSPalette.gold.opacity(0.14), in: RoundedRectangle(cornerRadius: size.length(10), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size.length(10), style: .continuous).stroke(COSPalette.gold.opacity(0.45), lineWidth: 1))

            HStack(spacing: size.length(5)) {
                Circle().fill(COSPalette.amber).frame(width: size.length(6), height: size.length(6))
                Text("RECENT CORRECTIONS")
                    .font(COSType.mono(size.typeSize(8), weight: .bold))
                    .kerning(0.5)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let onOpenDictionary {
                    Button("Dictionary…", action: onOpenDictionary)
                        .buttonStyle(COSTextButtonStyle())
                        .font(COSType.body(size.typeSize(9)))
                        .help("Open the whole dictionary in COS Activity")
                }
            }
            if learnUnavailable {
                Text("Update the COS server to 6.73.12 to save corrections from here.")
                    .font(COSType.body(size.typeSize(10)))
                    .foregroundStyle(COSPalette.amber)
                    .fixedSize(horizontal: false, vertical: true)
            } else if dictionary.recent.isEmpty {
                Text(dictionary.loaded ? "Nothing learned yet." : "Loading…")
                    .font(COSType.body(size.typeSize(10)))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(dictionary.recent.prefix(3)) { entry in
                    DictionaryLearnedRow(entry: entry, fontSize: size.typeSize(10), busy: dictionary.busy || store.fixSaving) {
                        Task { await dictionary.undo(entry.id) }
                    }
                }
            }
            // 0.5.318 Suggest only: what COS noticed you fix, here where Fix a word lives (Miles 13:31).
            if !store.suggestions.suggestions.isEmpty {
                HStack(spacing: size.length(5)) {
                    Circle().fill(COSPalette.gold).frame(width: size.length(6), height: size.length(6))
                    Text("SUGGESTED FROM YOUR EDITS")
                        .font(COSType.mono(size.typeSize(8), weight: .bold))
                        .kerning(0.5)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let onReview {
                        Button("Review all…", action: onReview)
                            .buttonStyle(COSTextButtonStyle())
                            .font(COSType.body(size.typeSize(9)))
                            .help("Review every suggestion in COS Activity → Dictation")
                    }
                }
                ForEach(store.suggestions.suggestions.prefix(3)) { item in
                    DictationSuggestionRow(item: item, fontSize: size.typeSize(10), busy: dictionary.busy || store.fixSaving,
                                           onAdd: { Task { await store.applySuggestions([item.id]) } },
                                           onDismiss: { store.dismissSuggestion(item.id) })
                }
            }
        }
        .task(id: record.id) { await dictionary.load() }
    }

    /// The transcript as tappable words, the picked ones marked like the mock's highlight.
    private var words: some View {
        ChipFlowLayout(spacing: max(2, size.length(3))) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                let picked = store.fixSelection?.contains(index) == true
                Button { store.selectFixWord(index); fieldFocused = store.fixSelection != nil } label: {
                    Text(token)
                        .font(COSType.body(size.typeSize(11)))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, size.length(2))
                        .background(RoundedRectangle(cornerRadius: size.length(3)).fill(picked ? COSPalette.amber.opacity(0.3) : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
        }
    }
}

/// heard → written, where and when, Undo. Shared by the pet's Fix a word and the Dictionary pane.
struct DictionaryLearnedRow: View {
    let entry: TranscriptionDictionaryStore.Learned
    let fontSize: CGFloat
    let busy: Bool
    let onUndo: () -> Void
    var body: some View {
        HStack(spacing: 7) {
            Text(entry.heard).strikethrough().foregroundStyle(.secondary).lineLimit(1)
            Text("→").font(COSType.mono(fontSize, weight: .bold)).foregroundStyle(.secondary)
            Text(entry.written).fontWeight(.semibold).lineLimit(1)
            Spacer(minLength: 4)
            Text(DictionaryLabels.line(source: entry.source, at: entry.at, now: Date()))
                .font(COSType.mono(max(8, fontSize - 1), weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button("Undo", action: onUndo)
                .buttonStyle(COSTextButtonStyle())
                .disabled(busy)
                .help("Take this correction back out of the dictionary")
        }
        .font(COSType.body(fontSize))
        .padding(.vertical, 5)
        .overlay(alignment: .top) { Rectangle().fill(COSPalette.line).frame(height: 1) }
    }
}

/// One thing Learn from my edits noticed (Suggest only), with Add and Dismiss; or one it saved on its own, with Undo.
/// Shared by the pet's Fix a word and Activity → Dictation (0.5.318).
struct DictationSuggestionRow: View {
    let item: DictationSuggestion
    let fontSize: CGFloat
    let busy: Bool
    /// Suggested: Add and Dismiss. Learned: Undo only (`onAdd` nil).
    let onAdd: (() -> Void)?
    let onDismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            pair
            // 0.5.323: why COS thinks this is a term, under the pair, in words.
            if let evidence = item.evidence {
                Text(evidence.words)
                    .font(COSType.body(max(8, fontSize - 1)))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(COSType.body(fontSize))
        .padding(.vertical, 5)
        .overlay(alignment: .top) { Rectangle().fill(COSPalette.line).frame(height: 1) }
    }
    private var pair: some View {
        HStack(spacing: 7) {
            Text(item.heard).strikethrough().foregroundStyle(.secondary).lineLimit(1)
            Text("→").font(COSType.mono(fontSize, weight: .bold)).foregroundStyle(.secondary)
            Text(item.written).fontWeight(.semibold).lineLimit(1)
            Spacer(minLength: 4)
            Text(item.app + " · " + DictionaryLabels.when(item.at, now: Date()))
                .font(COSType.mono(max(8, fontSize - 1), weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let onAdd {
                Button("Add", action: onAdd)
                    .buttonStyle(COSTextButtonStyle())
                    .disabled(busy)
                    .help("Save this correction to the dictionary")
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(COSTextButtonStyle())
                    .disabled(busy)
                    .help("Drop it; COS won't suggest this pair again for 30 days")
            } else {
                Button("Undo", action: onDismiss)
                    .buttonStyle(COSTextButtonStyle())
                    .disabled(busy)
                    .help("Take this correction back out of the dictionary; COS won't learn it again for 30 days")
            }
        }
    }
}

/// COS Activity → Dictation (0.5.318, Miles 13:31): what Learn from my edits suggested (review and add in a batch) and
/// saved on its own (Undo), the dictionary's recent corrections, and the latest dictations. The full history and the
/// whole dictionary open as their own panes, on their own route flags, from the header.
/// 0.5.330 (Miles 2026-10-19): COS Activity → Dictation → Settings. The same settings the menu-bar panel shows, in the
/// tab. Mounted on `model.dictationSettingsRouteActive`, which only openDictationSettings and closeDictationSettings write.
struct DictationSettingsPane: View {
    @ObservedObject var model: ControllerModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Dictation settings").font(COSType.display(20, weight: .medium))
                    Spacer()
                    Button("Close") { model.closeDictationSettings() }.buttonStyle(COSQuietButtonStyle()).controlSize(.small)
                }
                MacDictationSettings(store: model.dictation, activityShortcut: model.activityHotKey)
            }
            .padding(16)
            .frame(maxWidth: 560, alignment: .leading)
        }
    }
}

struct DictationActivityPane: View {
    @ObservedObject var model: ControllerModel
    @ObservedObject private var store: MacDictationStore
    @ObservedObject private var dictionary: TranscriptionDictionaryStore
    @State private var applying = false

    init(model: ControllerModel) {
        self.model = model
        self.store = model.dictation
        self.dictionary = model.dictionary
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Dictation").font(COSType.display(15, weight: .semibold))
                    Spacer()
                    Button("History") { model.openDictationHistory() }.buttonStyle(COSTextButtonStyle())
                    Button("Dictionary") { model.openDictionary() }.buttonStyle(COSTextButtonStyle())
                    // 0.5.330: every dictation setting, here in the tab.
                    Button("Settings") { model.openDictationSettings() }.buttonStyle(COSTextButtonStyle())
                }
                Text(modeLine).font(COSType.body(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if store.learnMode == .off {
                    Button("Turn it on in Dictation settings") { model.openDictationSettings() }.buttonStyle(COSTextButtonStyle())
                }
                suggested
                learned
                corrections
                latest
            }
            .padding(16)
        }
        .task {
            store.pruneSuggestions()
            await dictionary.load()
        }
    }

    private var modeLine: String {
        switch store.learnMode {
        case .automatic: "Learn from my edits saves your fixes on its own. Undo any of them below."
        case .suggest: "Learn from my edits suggests your fixes and keeps them for a week. Add the ones you want."
        case .off: "Learn from my edits is off."
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(COSType.mono(9, weight: .bold)).kerning(0.6).foregroundStyle(.secondary)
    }

    @ViewBuilder private var suggested: some View {
        let items = store.suggestions.suggestions
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                heading("SUGGESTED FROM YOUR EDITS")
                Spacer()
                if items.count > 1 {
                    Button(applying ? "Adding…" : "Add all \(items.count)") {
                        applying = true
                        Task { await store.applySuggestions(Set(items.map(\.id))); applying = false }
                    }
                    .buttonStyle(COSTextButtonStyle())
                    .disabled(applying || dictionary.busy)
                }
            }
            if items.isEmpty {
                Text("Nothing waiting. Each suggestion is kept for seven days.").font(COSType.body(11)).foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    DictationSuggestionRow(item: item, fontSize: 11, busy: applying || dictionary.busy,
                                           onAdd: { Task { await store.applySuggestions([item.id]) } },
                                           onDismiss: { store.dismissSuggestion(item.id) })
                }
            }
        }
    }

    @ViewBuilder private var learned: some View {
        VStack(alignment: .leading, spacing: 4) {
            heading("LEARNED FROM YOUR EDITS")
            if store.suggestions.learned.isEmpty {
                Text("Nothing learned from your edits yet.").font(COSType.body(11)).foregroundStyle(.secondary)
            } else {
                ForEach(store.suggestions.learned.prefix(20)) { item in
                    DictationSuggestionRow(item: item, fontSize: 11, busy: dictionary.busy, onAdd: nil,
                                           onDismiss: { Task { await store.undoLearned(item.id) } })
                }
            }
        }
    }

    @ViewBuilder private var corrections: some View {
        VStack(alignment: .leading, spacing: 4) {
            heading("RECENT CORRECTIONS")
            if dictionary.recent.isEmpty {
                Text(dictionary.loaded ? "Nothing learned yet." : "Loading…").font(COSType.body(11)).foregroundStyle(.secondary)
            } else {
                ForEach(dictionary.recent.prefix(10)) { entry in
                    DictionaryLearnedRow(entry: entry, fontSize: 11, busy: dictionary.busy) { Task { await dictionary.undo(entry.id) } }
                }
            }
            if let message = dictionary.message {
                Text(message).font(COSType.body(11)).foregroundStyle(COSPalette.amber).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var latest: some View {
        VStack(alignment: .leading, spacing: 4) {
            heading("LATEST DICTATIONS")
            if store.recent.isEmpty {
                Text("No dictations on this Mac yet.").font(COSType.body(11)).foregroundStyle(.secondary)
            } else {
                ForEach(store.recent.prefix(5)) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.firstLine).font(COSType.body(11)).lineLimit(2)
                        Text(record.metaLine(time: record.createdAt.formatted(date: .omitted, time: .shortened)))
                            .font(COSType.mono(9, weight: .medium)).foregroundStyle(.secondary)
                        // 0.5.331: Claude's version, when COS could not swap it in place.
                        if let pending = store.pendingPolish[record.id] {
                            if pending.applies {
                                Button("Apply polished") { store.applyPolished(record.id) }.buttonStyle(COSTextButtonStyle())
                            } else {
                                // 0.5.332: a swap that may not have landed cleanly: both versions, to check the app against.
                                Text("Heard: " + pending.heard).font(COSType.body(11)).foregroundStyle(.secondary).lineLimit(3)
                                Text("Polished: " + pending.text).font(COSType.body(11)).foregroundStyle(.secondary).lineLimit(3)
                                Button("Copy polished") { store.copyPolished(record.id) }.buttonStyle(COSTextButtonStyle())
                            }
                        }
                        if let note = store.polishNote, note.id == record.id {
                            Text(note.text).font(COSType.body(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(COSPalette.line).frame(height: 1) }
                }
                Button("All dictations") { model.openDictationHistory() }.buttonStyle(COSTextButtonStyle())
            }
        }
    }
}

// MARK: - Your polish instructions (0.5.335, server 6.85.0)

/// The server's one polish-instructions setting and its read-only built-in rules. Every call goes through the helper's
/// `dictation-polish-instructions` verb; the words ride on stdin, never argv, and are never logged.
@MainActor final class DictationPolishInstructionsStore: ObservableObject {
    static let shared = DictationPolishInstructionsStore()
    struct Rules: Equatable { let heading: String; let text: String; let userBlock: String? }
    /// False until a server says it has the setting (capabilities.dictationCleanup.customInstructions): no box.
    @Published private(set) var available = false
    @Published private(set) var saved = ""
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var rules: Rules?
    @Published private(set) var rulesMessage: String?
    /// 0.5.337 (loop audit W13): the first read failed (not an older server, which answers available false), so the card
    /// says why with Try again instead of vanishing.
    @Published private(set) var loadFailed = false
    /// The last operation succeeded, so its message (Saved., Cleared.) is a confirmation.
    @Published private(set) var lastOK = false
    var bridge: (@MainActor (Data) async throws -> HelperResponse)?

    func load() async { loadFailed = !(await send("get")) }
    @discardableResult func save(_ text: String) async -> Bool { await send("set", text: text) }
    @discardableResult func clear() async -> Bool { await send("clear") }
    func loadRules() async {
        guard let bridge, let body = DictationPolishInstructions.request("rules") else { rulesMessage = "COS Control is not connected to its helper yet."; return }
        do {
            let response = try await bridge(body)
            guard response.ok, let text = response.details["rules"]?.string else {
                rulesMessage = response.ok ? "This COS server has no built-in rules view." : response.message; return
            }
            rules = Rules(heading: DictationPolishInstructions.rulesHeading(version: response.details["version"]?.string,
                                                                           rolledBack: response.details["rolledBack"]?.bool),
                          text: text, userBlock: response.details["userBlock"]?.string)
            rulesMessage = nil
        } catch {
            rulesMessage = error.localizedDescription
        }
    }

    private func send(_ operation: String, text: String? = nil) async -> Bool {
        guard let bridge else { message = "COS Control is not connected to its helper yet."; lastOK = false; return false }
        guard let body = DictationPolishInstructions.request(operation, text: text) else {
            message = "Polish instructions are at most \(DictationPolishInstructions.maximumCharacters) characters."; lastOK = false; return false
        }
        busy = true
        defer { busy = false; loaded = true }
        do {
            let response = try await bridge(body)
            guard response.ok else { message = response.message; lastOK = false; return false }
            let state = DictationPolishInstructions.saved(available: response.details["available"]?.bool,
                                                          text: response.details["customInstructions"]?.string,
                                                          hash: response.details["instructionsHash"]?.string)
            available = state.available
            saved = state.text
            message = operation == "set" ? "Saved." : operation == "clear" ? "Cleared." : nil
            lastOK = true
            return true
        } catch {
            message = error.localizedDescription
            lastOK = false
            return false
        }
    }
}

/// Settings, Dictation, under AI polish: the box, its counter, Save and Clear, and the built-in rules read-only. Shown
/// only on a server that advertises the setting. Plain copy, no em dashes.
struct DictationPolishInstructionsCard: View {
    @ObservedObject var store: DictationPolishInstructionsStore
    let polishOn: Bool
    @State private var draft = ""
    /// The draft was typed in, so a reload never replaces what the person is writing.
    @State private var touched = false
    @State private var rulesOpen = false
    var body: some View {
        Group {
            if !DictationPolishInstructions.visible(available: store.available), store.loadFailed, !store.busy {
                VStack(alignment: .leading, spacing: 4) {
                    Text(DictationPolishInstructions.title).font(COSType.body(12.5))
                    HStack(spacing: 8) {
                        Text(store.message ?? "Your polish instructions could not be read.").font(.caption2).foregroundStyle(COSPalette.amber)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try again") { Task { await store.load(); if !touched { draft = store.saved } } }.buttonStyle(COSTextButtonStyle())
                    }
                }
            }
            if DictationPolishInstructions.visible(available: store.available) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(DictationPolishInstructions.title).font(COSType.body(12.5))
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: Binding(get: { draft }, set: { draft = $0; touched = true }))
                            .font(COSType.body(12)).frame(minHeight: 72, maxHeight: 140).cosEditor()
                            .accessibilityLabel(DictationPolishInstructions.title)
                            .accessibilityIdentifier("dictation-polish-instructions-editor")
                        if draft.isEmpty {
                            Text(DictationPolishInstructions.placeholder).font(COSType.body(12)).foregroundStyle(COSPalette.muted)
                                .padding(.horizontal, 6).padding(.vertical, 2).allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    HStack(spacing: 8) {
                        Text(DictationPolishInstructions.counter(draft)).font(COSType.mono(10))
                            .foregroundStyle(DictationPolishInstructions.isOver(draft) ? COSPalette.danger : COSPalette.muted)
                        Spacer()
                        Button("Clear") { Task { if await store.clear() { draft = ""; touched = false } } }
                            .buttonStyle(COSTextButtonStyle())
                            .disabled(!DictationPolishInstructions.canClear(draft: draft, saved: store.saved, busy: store.busy))
                        Button("Save") { Task { if await store.save(draft) { draft = store.saved; touched = false } } }
                            .buttonStyle(COSQuietButtonStyle())
                            .disabled(!DictationPolishInstructions.canSave(draft: draft, saved: store.saved, busy: store.busy))
                    }
                    Text(DictationPolishInstructions.note).font(.caption2).foregroundStyle(.secondary)
                    if !polishOn { Text(DictationPolishInstructions.offNote).font(.caption2).foregroundStyle(.secondary) }
                    // 0.5.337 (loop audit N17): Saved. and Cleared. are confirmations, not warnings.
                    if let message = store.message {
                        Text(message).font(.caption2).foregroundStyle(store.lastOK ? Color.secondary : COSPalette.amber)
                    }
                    DisclosureGroup("See the built-in rules", isExpanded: $rulesOpen) {
                        VStack(alignment: .leading, spacing: 6) {
                            if let rules = store.rules {
                                Text(rules.heading).font(COSType.body(12))
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(rules.text).font(COSType.mono(10)).textSelection(.enabled)
                                        if let block = rules.userBlock {
                                            Text("Your instructions go after the rules, in this block:").font(.caption2).foregroundStyle(.secondary)
                                            Text(block).font(COSType.mono(10)).textSelection(.enabled)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(minHeight: 0, maxHeight: 220)
                            } else {
                                Text(store.rulesMessage ?? "Loading the built-in rules\u{2026}").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.caption)
                    .onChange(of: rulesOpen) { _, open in
                        if open, store.rules == nil { Task { await store.loadRules() } }
                    }
                }
            }
        }
        .task {
            await store.load()
            if !touched { draft = store.saved }
        }
    }
}

// MARK: - The one COS dictionary (0.5.309)

/// Vocabulary and corrections from the server's transcription glossary, and what Fix a word taught it. Every change
/// goes through the helper's `transcription-dictionary` verb; words ride on stdin, never argv.
@MainActor final class TranscriptionDictionaryStore: ObservableObject {
    static let shared = TranscriptionDictionaryStore()
    struct Correction: Identifiable, Equatable { var id: String { heard }; let heard: String; let written: String }
    struct Learned: Identifiable, Equatable { let id: String; let heard: String; let written: String; let source: String; let at: Date? }
    @Published private(set) var vocabulary: [String] = []
    @Published private(set) var corrections: [Correction] = []
    @Published private(set) var recent: [Learned] = []
    /// False on a server older than 6.73.11: the dictionary reads and edits, but Fix a word and Undo need the update.
    @Published private(set) var learnAvailable = true
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    var bridge: (@MainActor (Data) async throws -> HelperResponse)?

    func load() async { await send("get") }
    @discardableResult func learn(heard: String, written: String, source: String) async -> Bool {
        await send("learn", ["heard": heard, "written": written, "source": source])
    }
    @discardableResult func undo(_ id: String) async -> Bool { await send("undo", ["id": id]) }
    @discardableResult func addVocabulary(_ term: String) async -> Bool { await send("add-vocabulary", ["term": term]) }
    func removeVocabulary(_ term: String) async { await send("remove-vocabulary", ["term": term]) }
    @discardableResult func removeCorrection(_ heard: String) async -> Bool { await send("remove-correction", ["heard": heard]) }

    @discardableResult private func send(_ operation: String, _ payload: [String: String] = [:]) async -> Bool {
        guard let bridge else { message = "COS Control is not connected to its helper yet."; return false }
        guard let body = try? JSONSerialization.data(withJSONObject: ["operation": operation, "payload": payload]) else { return false }
        busy = true
        defer { busy = false }
        do {
            let response = try await bridge(body)
            if response.details["vocabulary"] != nil { apply(response.details) }
            if response.ok, response.details["stale"]?.bool == true {
                message = "Saved. The dictionary could not be read back; Refresh to see it."
            } else if response.ok, response.details["unchanged"]?.bool == true {
                message = "Already in the dictionary."
            } else if response.ok, let note = DictionaryLearnNote.line(correctionOnly: response.details["correctionOnly"]?.bool,
                                                                      note: response.details["note"]?.string) {
                // 0.5.334 (server 6.84.0): "/pricing" is kept as a correction only; say so, in the server's words.
                message = note
            } else {
                message = response.ok ? nil : response.message
            }
            loaded = true
            return response.ok
        } catch {
            message = error.localizedDescription
            // A failed first load must not leave "Loading…" up forever.
            loaded = true
            return false
        }
    }

    private func apply(_ details: [String: JSONValue]) {
        vocabulary = details["vocabulary"]?.array?.compactMap(\.string) ?? []
        corrections = details["corrections"]?.array?.compactMap { value in
            guard let row = value.object, let heard = row["heard"]?.string, let written = row["written"]?.string else { return nil }
            return Correction(heard: heard, written: written)
        } ?? []
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        recent = details["recent"]?.array?.compactMap { value in
            guard let row = value.object, let id = row["id"]?.string, let heard = row["heard"]?.string,
                  let written = row["written"]?.string else { return nil }
            return Learned(id: id, heard: heard, written: written, source: row["source"]?.string ?? "", at: row["at"]?.string.flatMap(iso.date(from:)))
        } ?? []
        learnAvailable = details["learnAvailable"]?.bool ?? false
        loaded = true
    }
}

/// COS Activity → Meetings → Dictionary (mock 07): recent corrections first, then the vocabulary and every correction,
/// each searchable and editable. The dictionary already existed on the server; this is its first home in COS Control.
/// Mounted on `model.dictionaryRouteActive`, which only `openDictionary()` and `closeDictionary()` write.
/// COS Activity → Meetings → Dictation history (0.5.312): every kept dictation by day, searched on this Mac.
/// Opened from the pet's "All dictations" row, the Dictionary pane's History button and Dictation → History….
struct DictationHistoryPane: View {
    @ObservedObject var model: ControllerModel
    @ObservedObject private var store: MacDictationStore
    @State private var search = ""
    @State private var confirmingClear = false

    init(model: ControllerModel) {
        self.model = model
        self.store = model.dictation
    }

    private var days: [DictationHistory.Day] {
        DictationHistory.days(DictationHistory.search(store.recent, search))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                header
                TextField("Search dictations", text: $search)
                    .textFieldStyle(.plain)
                    .cosField()
                if store.recent.isEmpty {
                    Text(store.retention.writesToDisk ? "No dictations yet. Anything you dictate shows up here."
                         : "Dictations aren't kept.")
                        .font(COSType.body(12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !store.retention.writesToDisk {
                        Button("Choose how long to keep them") { model.openDictationSettingsInActivity() }.buttonStyle(COSTextButtonStyle())
                    }
                } else if days.isEmpty {
                    Text("No dictation matches that search.")
                        .font(COSType.body(12)).foregroundStyle(.secondary)
                }
                ForEach(days) { group in
                    Text(Self.dayTitle(group.day))
                        .font(COSType.mono(10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                    ForEach(group.records) { record in
                        DictationHistoryRow(record: record, busy: store.busy,
                                            onCopy: { store.copy(record.finalText) },
                                            onFix: { store.openFixFromHistory(record.id) },
                                            onDelete: { store.deleteRecord(record.id) })
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
        }
        // The pane clamps itself, like the Dictionary pane: a long list must never push the toolbar off the window.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
        .background(COSPalette.panel)
        .cosConfirm(
            "Clear dictation history?",
            isPresented: $confirmingClear,
            message: "Every dictation kept on this Mac is deleted. Your dictionary stays as it is.",
            actions: [
                .destructive("Clear history") { store.clearRecent() },
                .cancel(),
            ]
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Dictation history").font(COSType.display(20, weight: .medium))
                Spacer()
                Button("Clear history…") { confirmingClear = true }
                    .buttonStyle(COSQuietButtonStyle()).controlSize(.small)
                    .disabled(store.recent.isEmpty || store.busy)
                Button("Close") { model.closeDictationHistory() }
                    .buttonStyle(COSQuietButtonStyle()).controlSize(.small)
            }
            Text(Self.keepLine(store.retention, count: store.recent.count))
                .font(COSType.body(12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Dictation settings") { model.openDictationSettingsInActivity() }.buttonStyle(COSTextButtonStyle())
        }
    }

    static func keepLine(_ retention: DictationRetention, count: Int) -> String {
        let kept = "\(count) \(count == 1 ? "dictation" : "dictations") on this Mac"
        switch retention {
        case .none: return "Not kept: this session only, never saved."
        case .forever: return kept + ", kept until you delete them (at most \(DictationHistory.cap.formatted()))."
        default: return kept + ", kept for \(retention.title) (at most \(DictationHistory.cap.formatted()))."
        }
    }

    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "TODAY" }
        if calendar.isDateInYesterday(day) { return "YESTERDAY" }
        return day.formatted(date: .complete, time: .omitted).uppercased()
    }
}

private struct DictationHistoryRow: View {
    let record: DictationRecord
    let busy: Bool
    let onCopy: () -> Void
    let onFix: () -> Void
    let onDelete: () -> Void
    @State private var copied = false
    private var meta: String {
        let words = record.finalWordCount
        let line = "\(words) \(words == 1 ? "word" : "words") · \(record.outcomeLabel)" + (record.polishLabel.map { " · " + $0 } ?? "")
        guard let edit = record.edit else { return line }
        return line + " · edited in " + edit.app + " · " + DictationEditConfirm.editsLabel(edit.edits)
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(record.createdAt.formatted(date: .omitted, time: .shortened))
                .font(COSType.mono(10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                // 0.5.342: an edited dictation reads as it was sent, and says it was edited.
                Text(record.finalFirstLine)
                    .font(COSType.body(12))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                Text(meta)
                    .font(COSType.mono(9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let engine = DictationEngineName.detailLine(engine: record.engine, fallbackReason: record.fallbackReason) {
                    Text(engine).font(COSType.body(10)).foregroundStyle(.secondary).lineLimit(2)
                }
                // 0.5.325: what the engine heard before AI polish, selectable to copy.
                if let heard = record.heard {
                    Text("What was heard: " + heard).font(COSType.body(10)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                onCopy(); copied = true
                Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
            }
            .buttonStyle(COSQuietButtonStyle()).controlSize(.small)
            Button("Fix a word", action: onFix)
                .buttonStyle(COSQuietButtonStyle()).controlSize(.small)
                .disabled(busy)
                .help("Opens on the pet: tap the word COS got wrong")
            Button("Delete", action: onDelete)
                .buttonStyle(COSQuietButtonStyle()).controlSize(.small)
                .help("Delete this dictation from this Mac")
        }
        .padding(.vertical, 4)
    }
}

struct TranscriptionDictionaryPane: View {
    @ObservedObject var model: ControllerModel
    @ObservedObject private var dictionary: TranscriptionDictionaryStore
    @State private var search = ""
    @State private var newTerm = ""
    @State private var newHeard = ""
    @State private var newWritten = ""
    @State private var showAllVocabulary = false

    init(model: ControllerModel) {
        self.model = model
        self.dictionary = model.dictionary
    }

    private var needle: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var vocabulary: [String] {
        needle.isEmpty ? dictionary.vocabulary : dictionary.vocabulary.filter { $0.localizedCaseInsensitiveContains(needle) }
    }
    private var corrections: [TranscriptionDictionaryStore.Correction] {
        needle.isEmpty ? dictionary.corrections
            : dictionary.corrections.filter { $0.heard.localizedCaseInsensitiveContains(needle) || $0.written.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                TextField("Search words and corrections", text: $search)
                    .textFieldStyle(.plain)
                    .cosField()
                HStack(alignment: .top, spacing: 22) {
                    recentColumn.frame(maxWidth: .infinity, alignment: .topLeading)
                    vocabularyColumn.frame(maxWidth: .infinity, alignment: .topLeading)
                }
                correctionsSection
                if let message = dictionary.message {
                    Text(message)
                        .font(COSType.body(11))
                        .foregroundStyle(COSPalette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
        }
        // The pane clamps itself, like MeetingImportPane: a long list must never push the toolbar off the window.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
        .background(COSPalette.panel)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Dictionary").font(COSType.display(20, weight: .medium))
                Spacer()
                if dictionary.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Refresh") { Task { await dictionary.load() } }
                        .buttonStyle(COSQuietButtonStyle()).controlSize(.small)
                }
                Button("History") { model.openDictationHistory() }
                    .buttonStyle(COSQuietButtonStyle()).controlSize(.small)
                    .help("Every dictation kept on this Mac, by day")
                Button("Close") { model.closeDictionary() }
                    .buttonStyle(COSQuietButtonStyle()).controlSize(.small)
            }
            Text("One dictionary for G2 meetings, Mac recordings and dictation. A word you add or fix applies from the next sentence.")
                .font(COSType.body(12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recentColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent corrections").font(COSType.display(16, weight: .semibold))
            if !dictionary.learnAvailable && dictionary.loaded {
                Text("Update the COS server to 6.73.11 to see what COS learned and undo it.")
                    .font(COSType.body(11)).foregroundStyle(COSPalette.amber)
                    .fixedSize(horizontal: false, vertical: true)
            } else if dictionary.recent.isEmpty {
                Text(dictionary.loaded ? "Nothing learned yet. Use Fix a word on a dictation, or add a correction below." : "Loading…")
                    .font(COSType.body(11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(dictionary.recent) { entry in
                    DictionaryLearnedRow(entry: entry, fontSize: 12, busy: dictionary.busy) {
                        Task { await dictionary.undo(entry.id) }
                    }
                }
            }
        }
    }

    private var vocabularyColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Vocabulary · \(dictionary.vocabulary.count)").font(COSType.display(16, weight: .semibold))
            HStack(spacing: 6) {
                TextField("Add a word or name", text: $newTerm)
                    .textFieldStyle(.plain)
                    .cosField()
                    .onSubmit(addTerm)
                Button("Add", action: addTerm)
                    .buttonStyle(COSQuietButtonStyle()).controlSize(.small)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty || dictionary.busy)
            }
            let shown = showAllVocabulary || !needle.isEmpty ? vocabulary : Array(vocabulary.prefix(60))
            ChipFlowLayout(spacing: 6) {
                ForEach(shown, id: \.self) { term in
                    HStack(spacing: 4) {
                        Text(term).font(COSType.body(12)).foregroundStyle(COSPalette.plateInk)
                        Button { Task { await dictionary.removeVocabulary(term) } } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(term) from the vocabulary")
                        .accessibilityLabel("Remove \(term)")
                        .disabled(dictionary.busy)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .overlay(Capsule().stroke(COSPalette.line, lineWidth: 1))
                }
                if shown.count < vocabulary.count {
                    Button("+\(vocabulary.count - shown.count)") { showAllVocabulary = true }
                        .buttonStyle(COSTextButtonStyle())
                        .help("Show every word")
                }
            }
        }
    }

    private var correctionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Corrections · \(dictionary.corrections.count)").font(COSType.display(16, weight: .semibold))
            Text("When COS hears the word on the left, it writes the one on the right.")
                .font(COSType.body(11)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("Heard", text: $newHeard).textFieldStyle(.plain).cosField()
                Text("→").font(COSType.mono(12, weight: .bold)).foregroundStyle(.secondary)
                TextField("Written", text: $newWritten).textFieldStyle(.plain).cosField().onSubmit(addCorrection)
                Button("Add", action: addCorrection)
                    .buttonStyle(COSQuietButtonStyle()).controlSize(.small)
                    .disabled(newHeard.trimmingCharacters(in: .whitespaces).isEmpty || newWritten.trimmingCharacters(in: .whitespaces).isEmpty || dictionary.busy)
            }
            ForEach(corrections) { row in
                HStack(spacing: 8) {
                    Text(row.heard).strikethrough().foregroundStyle(.secondary).lineLimit(1)
                    Text("→").font(COSType.mono(12, weight: .bold)).foregroundStyle(.secondary)
                    Text(row.written).fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { Task { await dictionary.removeCorrection(row.heard) } } label: { Image(systemName: "xmark") }
                        .buttonStyle(COSIconButtonStyle())
                        .help("Remove this correction")
                        .accessibilityLabel("Remove the correction for \(row.heard)")
                        .disabled(dictionary.busy)
                }
                .font(COSType.body(12.5))
                .padding(.vertical, 4)
                .overlay(alignment: .top) { Rectangle().fill(COSPalette.line).frame(height: 1) }
            }
        }
    }

    private func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        Task { if await dictionary.addVocabulary(term) { newTerm = "" } }
    }

    /// A hand-added correction is learned like a fix (source "manual"), so it shows in Recent corrections with Undo.
    private func addCorrection() {
        let heard = newHeard.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = newWritten.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !written.isEmpty else { return }
        Task { if await dictionary.learn(heard: heard, written: written, source: "manual") { newHeard = ""; newWritten = "" } }
    }
}

/// Settings → Dictation → Sound (0.5.312): the pet's sound by default, any library sound, or your own file, for start
/// and stop separately, a volume (0 is off) and a Preview for each.
struct DictationSoundSettings: View {
    @ObservedObject var store: MacDictationStore
    private func options(_ edge: DictationSoundEdge) -> [COSDropdownOption<String>] {
        var list = [COSDropdownOption("pet", "Pet's sound (\(store.petSoundName))")]
        list += DictationSoundLibrary.sounds.map { COSDropdownOption(DictationSoundLibrary.Choice.library($0.id).stored, $0.name) }
        if case .custom(let file) = DictationSoundLibrary.Choice(stored: store.soundChoice(edge)) {
            list.append(COSDropdownOption(store.soundChoice(edge), "Your file (\(file))"))
        }
        list.append(COSDropdownOption("import", "Your own file…"))
        return list
    }
    /// The trimmed result's length and a Preview before anything is saved.
    private func importPanel(_ pending: DictationSoundImport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pending.sourceName).font(.caption).lineLimit(1).truncationMode(.middle)
            Text(pending.summary).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            if pending.edge == .stop {
                Toggle("Use the end of this file", isOn: Binding(get: { store.pendingImport?.useEnd ?? false }, set: { store.setImportUseEnd($0) }))
                    .toggleStyle(COSSwitchStyle()).font(.caption)
            }
            HStack {
                Button("Preview") { store.previewImport() }
                Button("Save") { store.saveImport() }
                Button("Cancel") { store.cancelImport() }
            }.controlSize(.small)
        }
        .padding(8)
        .background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 8))
    }
    static func semitones(_ value: Double) -> String {
        let n = Int(DictationSoundLibrary.cents(value) / 100)
        return n == 0 ? "0 st" : (n > 0 ? "+\(n) st" : "−\(-n) st")
    }
    private func binding(_ edge: DictationSoundEdge) -> Binding<String> {
        Binding(get: { store.soundChoice(edge) }, set: { value in
            if value == "import" { store.importCustomSound(edge) }
            else if edge == .start { store.soundStart = value } else { store.soundStop = value }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sound").font(.caption)
            ForEach(DictationSoundEdge.allCases, id: \.self) { edge in
                HStack {
                    COSDropdown(edge == .start ? "Start" : "Stop", selection: binding(edge), options: options(edge))
                    Button("Preview") { store.previewSound(edge) }.controlSize(.small)
                }
                if let pending = store.pendingImport, pending.edge == edge { importPanel(pending) }
            }
            HStack {
                Text("Volume").font(.caption)
                Slider(value: $store.soundVolume, in: 0...1)
                Text(store.soundVolume <= 0 ? "Off" : "\(Int((store.soundVolume * 100).rounded()))%").font(.caption.monospacedDigit())
            }
            HStack {
                Text("Pitch").font(.caption)
                Slider(value: $store.soundPitch, in: DictationSoundLibrary.pitchRange, step: 1)
                Text(Self.semitones(store.soundPitch)).font(.caption.monospacedDigit())
            }
            if let note = store.soundNote { Text(note).font(.caption2).foregroundStyle(COSPalette.amber) }
            Text("Unstable saber is mostly bass: use headphones or real speakers, laptop speakers reproduce little of it. Sounds never play while a COS recording is capturing.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
