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
    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

/// No system input/output device is changed. Only this engine's input AudioUnit is selected.
@MainActor final class DictationMicrophoneCapture {
    private let engine = AVAudioEngine()
    private let pcm = DictationPCMBuffer()
    private var tapped = false
    private var observer: NSObjectProtocol?
    func snapshot() -> Data { pcm.snapshot(maximumBytes: 320_000) }
    var level: Double { pcm.currentLevel() }
    var failure: String? { pcm.failureMessage() }
    func start(deviceID: AudioDeviceID?) throws {
        let input = engine.inputNode
        if var deviceID {
            guard let unit = input.audioUnit,
                  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
                throw error("The selected microphone is unavailable. Refresh microphones and choose one.")
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: target) else { throw error("The microphone format is unavailable.") }
        let accumulator = pcm
        let converterBox = DictationConverter(converter: converter, target: target, pcm: accumulator)
        // @Sendable on both: a closure formed inside this @MainActor class otherwise inherits main-actor isolation,
        // Swift 6 checks it on entry, and AVAudioEngine calls from its own queue. 0.5.305 trapped on the first buffer.
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in converterBox.consume(buffer) }
        tapped = true
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { @Sendable _ in
            accumulator.fail("The microphone changed or disconnected. Stop and select it again.")
        }
        do { engine.prepare(); try engine.start() }
        catch { _ = try? stop(); throw error }
    }
    func stop() throws -> Data {
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        return try pcm.result()
    }
    private func error(_ text: String) -> NSError { NSError(domain: "COSDictation", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}

/// AVAudioEngine calls a tap serially. No UI, network or file IO runs in this callback.
private final class DictationConverter: @unchecked Sendable {
    let converter: AVAudioConverter
    let target: AVAudioFormat
    let pcm: DictationPCMBuffer
    init(converter: AVAudioConverter, target: AVAudioFormat, pcm: DictationPCMBuffer) { self.converter = converter; self.target = target; self.pcm = pcm }
    func consume(_ input: AVAudioPCMBuffer) {
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
@MainActor enum DictationInsertion {
    /// Bundle path → Electron/Chromium. A frontmost app's frameworks do not change while it runs.
    private static var chromium: [String: Bool] = [:]

    static func deliver(_ raw: String, restoreClipboard: Bool) async -> DictationDeliveryOutcome {
        let started = Date()
        let app = NSWorkspace.shared.frontmostApplication
        let bundle = app?.bundleIdentifier
        let name = app?.localizedName ?? "the app"
        let terminal = KnownApps.isTerminal(bundle)
        let text = terminal ? DictationDelivery.terminalText(raw) : raw
        let count = text.utf16.count
        var facts = "bundle=\(bundle ?? "-") terminal=\(terminal)"
        // 0.5.312: the clipboard is written only when COS must: just before a ⌘V it posts, or for the card that asks the
        // person to paste. Accessibility insertion never touches it (DictationClipboard.use).
        let board = SystemDictationPasteboard(NSPasteboard.general)
        var wroteTranscript = false
        // Durable, and never the text: what was focused, what COS measured, what it did (0.5.310).
        func done(_ outcome: DictationDeliveryOutcome) -> DictationDeliveryOutcome {
            if DictationClipboard.use(for: outcome) == .keepForCard, !wroteTranscript, outcome != .refused(.clipboardChanged) {
                wroteTranscript = board.writeTranscript(text, markerTypes: [])
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            dictationLog.notice("delivery \(facts, privacy: .public) outcome=\(String(describing: outcome), privacy: .public) ms=\(ms)")
            return outcome
        }

        let trusted = AXIsProcessTrusted()
        let own = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        // COS's own pet and dictation panels are never a target, even when one of them holds the keyboard.
        let ownOverlay = own && (NSApp.keyWindow is PetPanel || NSApp.keyWindow is DictationOverlayPanel)
        if own, !ownOverlay {
            facts += " route=ownWindow"
            return done(ownWindow(text, app: name))
        }

        var element: AXUIElement?
        var family = false
        if trusted, let app, !own {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.25)
            element = focused(appElement)
            family = isChromiumFamily(app)
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
                case .done(let outcome): facts += " after=\(after.logDescription)"; return done(outcome)
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
        if let refusal = await paste(changeCount: changeCount) { return done(.refused(refusal)) }
        let postedAt = Date()
        facts += " paste=sent"
        var waited = 0
        var decision = DictationDecision.wait
        for ms in [80, 200, 400] {
            try? await Task.sleep(for: .milliseconds(ms - waited)); waited = ms
            let after = snapshot(target)
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
        if case .done(let outcome) = decision { return done(outcome) }
        return done(.unconfirmed(app: name, viaPaste: true))
    }

    /// ⌘V on the current layout's V, only once no modifier is physically held and only while the clipboard still
    /// holds what COS put there. Returns why it did not paste.
    private static func paste(changeCount: Int) async -> DictationInsertPolicy.Refusal? {
        var waited = 0
        while DictationDelivery.modifiersHeld(isDown: { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) }) {
            guard waited < DictationDelivery.modifierWaitMilliseconds else { return .keysHeld }
            try? await Task.sleep(for: .milliseconds(30)); waited += 30
        }
        guard NSPasteboard.general.changeCount == changeCount else { return .clipboardChanged }
        let key = CGKeyCode(vKeyCode())
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return .noTextBox }
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
    private static func ownWindow(_ text: String, app: String) -> DictationDeliveryOutcome {
        guard let responder = NSApp.keyWindow?.firstResponder else { return .refused(.noTextBox) }
        if let view = responder as? NSTextView {
            if view.delegate is NSSecureTextField { return .refused(.secureField) }
            guard view.isEditable else { return .refused(.noTextBox) }
            func measure() -> DictationFieldSnapshot {
                let range = view.selectedRange()
                return DictationFieldSnapshot(characters: view.string.utf16.count, location: range.location, length: range.length)
            }
            let before = measure()
            view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            let decision = DictationDelivery.decide(route: .ownWindow, baseline: before, setterSucceeded: true, afterSetter: measure(),
                                                    finalPoll: true, pasted: false, afterPaste: DictationFieldSnapshot(), count: text.utf16.count, app: app)
            if case .done(let outcome) = decision { return outcome }
            return .refused(.noTextBox)
        }
        if let client = responder as? NSTextInputClient {
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            return .unconfirmed(app: app, viaPaste: false)
        }
        return .refused(.noTextBox)
    }

    private static func isChromiumFamily(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }
        if let known = chromium[url.path] { return known }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("Contents/Frameworks").path)) ?? []
        let result = KnownApps.isChromiumFamily(frameworks: names)
        chromium[url.path] = result
        return result
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

/// The focused window's frame in Cocoa screen coordinates, read through Accessibility (nil without it).
enum DictationFocusedWindow {
    @MainActor static func frame() -> CGRect? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              let primary = NSScreen.screens.first?.frame else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
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
        return CGRect(x: position.x, y: primary.maxY - position.y - size.height, width: size.width, height: size.height)
    }
}

/// Dictation's start and stop sounds, through a small output-only AVAudioEngine so the person's Pitch applies to every
/// sound, their own file included, without changing its length (AVAudioUnitTimePitch). Playback is scheduled and never
/// waited on; this engine has no input, so it never touches the dictation microphone.
///
/// The start sound is NOT trimmed from the recording and the microphone is NOT delayed for it: either would cost the
/// first words of someone who starts talking as they press. The microphone opens at once, the sound plays alongside,
/// and the stop sound plays only after the microphone has closed. Speech models ignore a short non-speech tone; a
/// person who hears it in a transcript can lower the volume or turn it off (0).
@MainActor final class DictationSoundPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private var format: AVAudioFormat?
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
        node.scheduleFile(file, at: nil)
        node.play()
    }
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

@MainActor final class MacDictationStore: ObservableObject {
    static let shared = MacDictationStore()
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "dictation.enabled"); if !enabled { cancel() }; registerHotKeys() } }
    @Published var microphoneUID: String { didSet { UserDefaults.standard.set(microphoneUID, forKey: "dictation.microphoneUID") } }
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
    /// Set by the app: which family the pet is (its default sound), and whether a Mac recording is capturing.
    var petKind: (() -> DictationPetKind)?
    var macRecordingActive: (() -> Bool)?
    /// The screen the floating pill uses, chosen when dictation starts (the focused window's screen).
    @Published private(set) var floatingScreen: CGRect?
    private let soundPlayer = DictationSoundPlayer()
    /// 0.5.312: put the person's clipboard back after a ⌘V COS posted (Wispr Flow does). On unless turned off.
    @Published var restoreClipboard: Bool = UserDefaults.standard.object(forKey: "dictation.restoreClipboard") as? Bool ?? true {
        didSet { UserDefaults.standard.set(restoreClipboard, forKey: "dictation.restoreClipboard") }
    }
    @Published private(set) var microphones: [DictationMicrophone] = []
    @Published private(set) var holdTrigger: DictationTrigger?
    @Published private(set) var toggleTrigger: DictationTrigger?
    @Published private(set) var phase = "Off"
    @Published private(set) var message: String?
    /// 0.5.309: the listening pill. It replaces the pet's ledger row only while it is not hidden, then hands it back.
    @Published private(set) var pill: DictationPill = .hidden
    /// Where this dictation shows, decided when it starts: on the pet, or (pet hidden) a pill above the Dock.
    @Published private(set) var surface: DictationSurface = .pet
    /// The short-lived card: no text box (mock 04), or a dictation that did not finish.
    @Published private(set) var card: DictationCard?
    /// Recent dictations, newest first, the last 50, kept on this Mac across restarts (mock 05).
    @Published private(set) var recent: [DictationRecord]
    /// Which dictation view is open: the pet's list, one dictation, or Fix a word.
    @Published private(set) var listRoute: DictationListRoute?
    @Published private(set) var fixSelection: ClosedRange<Int>?
    @Published var fixDraft = ""
    @Published private(set) var fixNote: String?
    @Published private(set) var fixSaving = false
    /// Levels for the bars. Its own object, so a 20 Hz meter redraws the pill and never the whole pet.
    let meter = DictationMeterFeed()
    var bridge: (@MainActor (Data) async throws -> HelperResponse)?
    var petFrame: (() -> NSRect?)?
    private var capture: DictationMicrophoneCapture?
    private var pendingAudio: Data?
    var canRetry: Bool { pendingAudio != nil && !busy }
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
    private var held = false
    private var toggleHeld = false
    private var holdPending = false
    private var generation = UUID()
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
        holdTrigger = load("dictation.hold"); toggleTrigger = load("dictation.toggle")
        phase = on ? "Ready" : "Off"
        // A history file that does not read is moved aside before anything can be saved over it (0.5.310); when it
        // cannot be moved, this run keeps its dictations in memory only.
        let history = Self.defaultHistoryURL()
        let loaded = history.map { DictationHistory.loadOrQuarantine(from: $0, now: Date()) }
        historyURL = loaded?.writable == false ? nil : history
        recent = loaded?.records ?? []
        if let aside = loaded?.movedTo { dictationLog.notice("recent dictations unreadable; moved aside to \(aside.lastPathComponent, privacy: .public)") }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            sessionObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.cancel() }
            })
        }
        overlay.bind(store: self)
    }
    /// ~/Library/Application Support/COS Control/dictation-history.json. A check run writes under its own test home,
    /// and perf fixtures write nothing, so no check can touch the real history.
    nonisolated static func defaultHistoryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let home = environment["COS_CONTROL_TEST_HOME"] { return URL(fileURLWithPath: home).appendingPathComponent("dictation-history.json") }
        guard environment["COS_PERF_FIXTURES"] == nil else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/COS Control/dictation-history.json")
    }
    func refreshMicrophones() { microphones = DictationAudioDevices.inputs() }
    func requestInsertionPermission() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    /// True when the Activity shortcut would collide with either dictation shortcut.
    func uses(_ combo: HotKeyCombo) -> Bool {
        let trigger = DictationTrigger.keys(keyCode: combo.keyCode, modifiers: combo.modifiers)
        return trigger == holdTrigger || trigger == toggleTrigger
    }
    func setShortcut(_ trigger: DictationTrigger?, hold: Bool, activity: HotKeyCombo?) {
        guard !busy else { message = "Finish dictating before changing a shortcut."; return }
        let activityTrigger = activity.map { DictationTrigger.keys(keyCode: $0.keyCode, modifiers: $0.modifiers) }
        guard trigger == nil || (trigger != activityTrigger && trigger != (hold ? toggleTrigger : holdTrigger)) else {
            message = "That shortcut is already used by COS. Choose a different one."; return
        }
        let prefix = hold ? "dictation.hold" : "dictation.toggle"
        let d = UserDefaults.standard
        d.set(trigger != nil, forKey: prefix + ".enabled")
        if let stored = trigger?.stored {
            d.set(stored.kind, forKey: prefix + ".kind"); d.set(stored.key, forKey: prefix + ".key"); d.set(stored.modifiers, forKey: prefix + ".modifiers")
        }
        if hold { holdTrigger = trigger } else { toggleTrigger = trigger }
        message = nil; registerHotKeys()
        if trigger?.isFn == true, message == nil {
            message = "Fn is set. In System Settings → Keyboard, set “Press 🌐 key to” Do Nothing, and move Wispr Flow off Fn."
        }
    }
    func registerHotKeys() {
        registrations.forEach { UnregisterEventHotKey($0) }; registrations.removeAll()
        keyMonitors.forEach { NSEvent.removeMonitor($0) }; keyMonitors.removeAll()
        holdTracker = nil; toggleTracker = nil
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
        for (number, trigger) in [(UInt32(1), holdTrigger), (UInt32(2), toggleTrigger)] {
            switch trigger {
            case nil: continue
            case .modifier(let key)?:
                if number == 1 { holdTracker = LoneModifierTracker(keyCode: key) } else { toggleTracker = LoneModifierTracker(keyCode: key) }
            case .keys(let key, let modifiers)?:
                if let activity, activity.keyCode == key, activity.modifiers == modifiers {
                    message = "Dictation shortcut conflicts with Open Activity. Choose another shortcut."; continue
                }
                var ref: EventHotKeyRef?
                if RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: dictationHotKeySignature, id: number), GetApplicationEventTarget(), 0, &ref) == noErr, let ref { registrations.append(ref) }
                else { dictationLog.error("shortcut \(number) unavailable"); message = "Shortcut is unavailable. Another app may already use it. Choose another one." }
            }
        }
        if holdTracker != nil || toggleTracker != nil {
            // Monitors run on the main thread in event order; never hop through a Task, which could reorder down/up.
            // A click while the modifier is down (⌥-click, ⌘-click) is a chord like a key, so the monitors take clicks too and
            // feed them as a key down. keyCode is read only from key events: NSEvent raises on a mouse event's keyCode.
            let handle: (NSEvent) -> Void = { [weak self] event in
                let flags = event.type == .flagsChanged, isKey = flags || event.type == .keyDown
                let key = isKey ? event.keyCode : 0, raw = UInt64(event.modifierFlags.rawValue)
                MainActor.assumeIsolated { self?.keyEvent(flags: flags, keyCode: key, raw: raw) }
            }
            let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handle) { keyMonitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { handle($0); return $0 }) { keyMonitors.append(local) }
            if !AXIsProcessTrusted() {
                message = "Fn and single-key shortcuts need Accessibility. Click Allow insertion into other apps…, then turn dictation off and on."
            }
        }
        if !busy { phase = "Ready" }
    }
    private func keyEvent(flags: Bool, keyCode: UInt16, raw: UInt64) {
        func feed(_ tracker: inout LoneModifierTracker?) -> LoneModifierTracker.Output? {
            guard var current = tracker else { return nil }
            let output = flags ? current.flagsChanged(keyCode: keyCode, flags: raw) : current.keyDown()
            tracker = current; return output
        }
        switch feed(&holdTracker) {
        case .pressed?: hotKey(1, down: true)
        case .released?: hotKey(1, down: false)
        // Fn+arrow, ⌘C: the press was a chord, so drop it quietly; nothing was inserted.
        case .chord?: if held { cancel(); message = nil }
        case nil: break
        }
        // A lone-modifier toggle acts on a clean tap, so holding Fn for a chord never toggles.
        if feed(&toggleTracker) == .released { hotKey(2, down: true); hotKey(2, down: false) }
    }
    func hotKey(_ id: UInt32, down: Bool) {
        if id == 1 {
            if down, !held { held = true; holdPending = true; start() }
            else if !down { held = false; if holdPending { holdPending = false; stop() } }
        } else if id == 2 {
            if down, !toggleHeld { toggleHeld = true; phase == "Listening" ? stop() : start() }
            else if !down { toggleHeld = false }
        }
    }
    func start() {
        guard MacDictationPolicy.mayStart(enabled: enabled, busy: busy) else { return }
        generation = UUID(); let attempt = generation
        flashTask?.cancel(); flashTask = nil; dismissCard()
        // On the pet only when the pet is on the screen with the focused window; else the pill on that screen.
        let placement = DictationPlacement.choose(petFrame: petFrame?(), focusedWindow: DictationFocusedWindow.frame(),
                                                  screens: NSScreen.screens.map(\.frame), mainScreen: NSScreen.main?.frame)
        if case .floating(let screen)? = placement { surface = .floating; floatingScreen = screen } else { surface = .pet; floatingScreen = nil }
        pendingAudio = nil; message = nil; phase = "Starting"
        levelMeter = DictationLevelMeter(); meter.reset()
        pill = .listening(since: Date())
        // The start sound plays as the pill appears and the microphone opens at once (no added latency). See
        // DictationSoundPlayer for why the sound is not trimmed from the recording.
        playSound(.start)
        task = Task {
            let permission: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: permission = true
            case .notDetermined: permission = await AVCaptureDevice.requestAccess(for: .audio)
            default: permission = false
            }
            guard generation == attempt, !Task.isCancelled else { return }
            guard permission else { fail("Allow Microphone for COS Control in System Settings → Privacy & Security.", microphone: true); return }
            refreshMicrophones()
            let selected = microphones.first { $0.id == microphoneUID }
            guard microphoneUID.isEmpty || selected != nil else { fail("Your selected microphone is disconnected. Choose another microphone."); return }
            do {
                let next = DictationMicrophoneCapture()
                try next.start(deviceID: selected?.deviceID); capture = next; phase = "Listening"
                // 50 ms ticks: the meter's fast rise and slow fall are tuned to this cadence.
                meterTask = Task {
                    var tick = 0
                    while !Task.isCancelled, phase == "Listening", generation == attempt {
                        if next.failure != nil { stop(); break }
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
                timer = Task { try? await Task.sleep(for: .seconds(MacDictationPolicy.maximumSeconds)); if !Task.isCancelled { stop() } }
            } catch { let reason = error.localizedDescription; dictationLog.error("start failed: \(reason, privacy: .public)"); fail(reason) }
        }
    }
    func stop() {
        if phase == "Starting" { cancel(); return }
        guard phase == "Listening", let capture else { return }
        timer?.cancel(); timer = nil; self.capture = nil
        meterTask?.cancel(); meterTask = nil
        let attempt = generation
        do {
            let pcm = try capture.stop()
            // A stray tap of the shortcut is not worth a card: the pill just goes away.
            guard pcm.count >= 3200 else { fail("No usable speech was captured. Try holding the shortcut longer.", card: false); return }
            phase = "Transcribing"; pill = .transcribing
            // After the microphone has closed, so the stop sound is never in the recording.
            playSound(.stop)
            let wav = try MacDictationPolicy.wav(pcm)
            pendingAudio = wav
            transcribe(wav, attempt: attempt)
        } catch { let reason = error.localizedDescription; dictationLog.error("stop failed: \(reason, privacy: .public)"); fail(reason) }
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
            do {
                guard let bridge else { throw NSError(domain: "COSDictation", code: 2, userInfo: [NSLocalizedDescriptionKey: "The transcription server is not connected."]) }
                let response = try await bridge(wav)
                guard generation == attempt, !Task.isCancelled else { return }
                guard response.ok, let text = response.details["text"]?.string, !text.isEmpty,
                      response.details["engine"]?.string == "parakeet-ultra" else {
                    // No speech (the server's 204) is an answer, not a failure: retrying the same audio cannot help.
                    let noSpeech = response.details["noSpeech"]?.bool == true
                    if noSpeech { pendingAudio = nil }
                    fail(response.message, retry: !noSpeech); return
                }
                pendingAudio = nil; phase = "Ready"; message = nil
                let outcome = await DictationInsertion.deliver(text, restoreClipboard: restoreClipboard)
                finish(text, outcome: outcome)
            } catch { guard generation == attempt else { return }; let reason = error.localizedDescription; dictationLog.error("transcribe failed: \(reason, privacy: .public)"); fail(reason) }
        }
    }
    /// The text is on the clipboard already. Measured or sent: flash the pill. Refused: the card, which never takes focus.
    private func finish(_ text: String, outcome: DictationDeliveryOutcome) {
        let record = DictationRecord(id: UUID(), text: text, createdAt: Date(), delivery: outcome.delivery)
        if let flash = outcome.flash {
            pill = flash
            flashTask = Task {
                try? await Task.sleep(for: .seconds(DictationPill.flashSeconds))
                if !Task.isCancelled, pill == flash { pill = .hidden }
            }
        } else if case .refused(let refusal) = outcome {
            pill = .hidden
            showCard(DictationCard(kind: .copied(refusal), recordID: record.id, text: text, countdown: DictationCountdown(start: Date())))
        }
        remember(record)
    }
    /// A dictation that did not finish: the reason on the card, with Retry while the audio is held and worth retrying,
    /// and Open Settings when the microphone is not allowed.
    private func fail(_ reason: String, card: Bool = true, retry: Bool = true, microphone: Bool = false) {
        phase = enabled ? "Ready" : "Off"; message = reason; pill = .hidden; meter.reset()
        if card {
            showCard(DictationCard(kind: .failed(reason, retry: retry, microphone: microphone), recordID: nil, text: "",
                                   countdown: DictationCountdown(start: Date())))
        }
    }
    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
    }
    func cancel() {
        generation = UUID(); pendingAudio = nil; task?.cancel(); task = nil; timer?.cancel(); timer = nil
        meterTask?.cancel(); meterTask = nil; flashTask?.cancel(); flashTask = nil
        _ = try? capture?.stop(); capture = nil; held = false; toggleHeld = false; holdPending = false
        holdTracker?.reset(); toggleTracker?.reset()
        phase = enabled ? "Ready" : "Off"; message = "Dictation canceled. No text was inserted."
        pill = .hidden; meter.reset()
    }

    // MARK: Sounds (0.5.312)

    func soundChoice(_ edge: DictationSoundEdge) -> String { edge == .start ? soundStart : soundStop }
    var petSoundName: String { DictationSoundLibrary.name(DictationSoundLibrary.petDefault(petKind?() ?? .other)) }

    private func resolvedSound(_ edge: DictationSoundEdge) -> DictationSoundLibrary.Resolved {
        DictationSoundLibrary.resolve(DictationSoundLibrary.Choice(stored: soundChoice(edge)), edge: edge, pet: petKind?() ?? .other,
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
    func playSound(_ edge: DictationSoundEdge) {
        let resolved = resolvedSound(edge)
        if case .silent(let why) = resolved { dictationLog.debug("sound \(edge.rawValue, privacy: .public) silent: \(why, privacy: .public)"); return }
        guard let url = soundURL(resolved) else { return }
        soundPlayer.play(url, volume: Float(soundVolume), semitones: soundPitch)
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
        if macRecordingActive?() == true { soundNote = "No sound: a Mac recording is capturing."; return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cos-dictation-sound-preview.wav")
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: pending.trimmedWAV, attributes: [.posixPermissions: 0o600]) else { return }
        soundPlayer.play(url, volume: Float(max(soundVolume, 0.2)), semitones: soundPitch)
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
        recent = DictationHistory.adding(record, to: recent)
        saveRecent()
    }
    private func saveRecent() {
        guard let historyURL else { return }
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
    /// Settings → Clear recent dictations.
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
    func openFix(_ id: UUID?) {
        guard let id, record(id) != nil else { return }
        dismissCard()
        listRoute = .fix(id); resetFix()
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
        fixSelection = DictationFixText.select(index, current: fixSelection)
        // Prefill the spelling with what was heard, but never over a spelling the person already typed.
        if fixDraft.isEmpty || fixDraft == before {
            fixDraft = fixSelection.map { DictationFixText.heard(DictationFixText.tokens(record.text), $0) } ?? ""
        }
        fixNote = nil
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
        Task {
            let saved = await dictionary.learn(heard: heard, written: written, source: "dictation")
            fixSaving = false
            if saved { fixSelection = nil; fixDraft = ""; fixNote = dictionary.message ?? "Saved. COS writes “\(written)” from the next sentence." }
            else { fixNote = dictionary.message ?? "The dictionary did not save. Try again." }
        }
    }
    private func resetFix() { fixSelection = nil; fixDraft = ""; fixNote = nil; fixSaving = false }
}

enum DictationSurface: Equatable, Sendable { case pet, floating }

enum DictationListRoute: Equatable, Sendable {
    case recent, detail(UUID), fix(UUID)
    var isFix: Bool { if case .fix = self { return true }; return false }
}

/// One card at a time. `countdown` folds it after 20 seconds; hovering pauses it.
struct DictationCard: Equatable, Identifiable {
    enum Kind: Equatable { case copied(DictationInsertPolicy.Refusal), failed(String, retry: Bool, microphone: Bool) }
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
        case .failed(let reason, _, _): reason
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
            Text("Parakeet Ultra and your COS dictionary. Glasses are optional. Dictation uses your microphone; Record on Mac captures meeting playback.")
                .font(.caption2).foregroundStyle(.secondary)
            if store.enabled {
                COSDropdown("Microphone", selection: $store.microphoneUID, options: microphoneOptions).disabled(store.busy)
                Button("Refresh microphones") { store.refreshMicrophones() }.controlSize(.small)
                DictationShortcutRow(store: store, hold: true, activityShortcut: activityShortcut)
                DictationShortcutRow(store: store, hold: false, activityShortcut: activityShortcut)
                Button("Allow insertion into other apps…") { store.requestInsertionPermission() }.controlSize(.small)
                DictationSoundSettings(store: store)
                Toggle("Restore my clipboard after pasting", isOn: $store.restoreClipboard).toggleStyle(COSSwitchStyle())
                    .help("When COS pastes with ⌘V, it puts back whatever you had copied once the app has the text.")
                Text("Any shortcut: a modifier plus a key, a function key, or one modifier key by itself such as Fn 🌐 or Right ⌘. Fn and single-key shortcuts use Accessibility. Finished text drops into the text box that has the cursor; with no text box it is copied, and the pet shows it with a Copy button. Some apps, such as terminals and Electron editors, get ⌘V; COS shows Pasted when it can't confirm, then puts your clipboard back. COS never presses Send or Return.")
                    .font(.caption2).foregroundStyle(.secondary)
                if let message = store.message { Text(message).font(.caption2).foregroundStyle(COSPalette.amber) }
            }
            // 0.5.310: Recent dictations stay on this Mac until cleared here (or one at a time on the pet).
            Button("Clear recent dictations (\(store.recent.count))") { store.clearRecent() }
                .controlSize(.small)
                .disabled(store.recent.isEmpty || store.busy)
        }.onAppear { store.refreshMicrophones() }
    }
}

private struct DictationShortcutRow: View {
    @ObservedObject var store: MacDictationStore
    let hold: Bool
    let activityShortcut: HotKeyCombo?
    @State private var monitor: Any?
    @State private var note: String?
    @State private var pendingModifier: UInt16?
    var body: some View {
        HStack {
            Text(hold ? "Push to talk" : "Start / stop").font(.caption)
            Text(monitor != nil ? "Press shortcut…" : ((hold ? store.holdTrigger : store.toggleTrigger)?.display ?? "Off")).font(.caption.monospaced())
            Button(monitor == nil ? "Change" : "Cancel") { monitor == nil ? record() : stop() }
            Button("Off") { store.setShortcut(nil, hold: hold, activity: activityShortcut); stop() }
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
            else if let trigger = DictationTrigger.keys(UInt32(key), modifiers: modifiers) { store.setShortcut(trigger, hold: hold, activity: activityShortcut); stop() }
            else { note = "Add Command, Control or Option, use a function key, or press one modifier key such as Fn by itself." }
            return
        }
        guard let info = DictationTrigger.modifierKeys[key] else { return }
        if raw & info.device != 0 {
            pendingModifier = DictationTrigger.alone(key, flags: raw) ? key : nil
        } else if pendingModifier == key, let trigger = DictationTrigger.modifier(key) {
            store.setShortcut(trigger, hold: hold, activity: activityShortcut); stop()
        } else { pendingModifier = nil }
    }
    private func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
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
        panel.ignoresMouseEvents = store.card == nil && !fixing
        panel.allowsKey = fixing
        let size = host?.fittingSize ?? NSSize(width: 360, height: 60)
        let chosen = store.floatingScreen.flatMap { frame in NSScreen.screens.first { $0.frame == frame } } ?? NSScreen.main ?? NSScreen.screens.first
        if let screen = chosen?.visibleFrame {
            panel.setFrame(NSRect(x: (screen.midX - size.width / 2).rounded(), y: screen.minY + 8, width: size.width, height: size.height), display: true)
        }
        if fixing { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
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
        return panel
    }
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
                DictationListeningPill(pill: store.pill, meter: store.meter, floating: true, size: size, reduceMotion: reduceMotion)
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

    /// Green with ✓ only for a measured insertion; an unconfirmed paste flashes in the neutral colors.
    private var done: Bool { if case .flash(_, true) = pill { return true }; return false }
    private var fill: Color { done ? COSPalette.green : (floating ? COSPalette.ink : COSPalette.card) }
    private var ink: Color { done ? .white : (floating ? COSPalette.cream : COSPalette.plateInk) }

    var body: some View {
        HStack(spacing: size.length(8)) {
            switch pill {
            case .hidden:
                EmptyView()
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
            case .transcribing:
                DictationWorkingBars(size: size, reduceMotion: reduceMotion)
                Text(pill.label)
            case .flash:
                Text(pill.label)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel({ () -> String in
            switch pill {
            case .transcribing: return "Transcribing dictation"
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
                    }
                    Button("Fix a word") { store.openFix(card.recordID) }
                        .buttonStyle(DictationButtonStyle(size: size))
                        .disabled(card.recordID == nil)
                case .failed(_, let retry, let microphone):
                    if microphone {
                        Button("Open Settings") { store.openMicrophoneSettings() }
                            .buttonStyle(DictationButtonStyle(primary: true, size: size))
                    } else if retry, store.canRetry {
                        Button("Retry") { store.retryTranscription() }
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
struct DictationRecordDetail: View {
    @ObservedObject var store: MacDictationStore
    let record: DictationRecord
    let size: PetSize
    var body: some View {
        VStack(alignment: .leading, spacing: size.length(7)) {
            ScrollView {
                Text(record.text)
                    .font(COSType.body(size.typeSize(11)))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: size.length(96))
            Text(record.metaLine(time: DictionaryLabels.when(record.createdAt, now: Date())))
                .font(COSType.mono(size.typeSize(8), weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: size.length(7)) {
                Button("Copy") { store.copy(record.text) }
                    .buttonStyle(DictationButtonStyle(primary: true, size: size))
                Button("Fix a word") { store.openFix(record.id) }
                    .buttonStyle(DictationButtonStyle(size: size))
                Spacer(minLength: 0)
                Button("Delete") { store.deleteRecord(record.id) }
                    .buttonStyle(COSTextButtonStyle(tone: .destructive))
                    .font(COSType.body(size.typeSize(10)))
                Button("Back") { store.backToRecent() }
                    .buttonStyle(COSTextButtonStyle())
                    .font(COSType.body(size.typeSize(10)))
            }
        }
        .padding(.vertical, size.length(6))
        .padding(.trailing, size.length(8))
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
    func undo(_ id: String) async { await send("undo", ["id": id]) }
    @discardableResult func addVocabulary(_ term: String) async -> Bool { await send("add-vocabulary", ["term": term]) }
    func removeVocabulary(_ term: String) async { await send("remove-vocabulary", ["term": term]) }
    func removeCorrection(_ heard: String) async { await send("remove-correction", ["heard": heard]) }

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
            Text("Unstable saber is mostly bass: use headphones or real speakers, laptop speakers reproduce little of it. Sounds never play while a Mac recording is capturing.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
