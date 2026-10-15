import SwiftUI
import AVFoundation
import AudioToolbox
import CoreAudio
import ApplicationServices
import Carbon.HIToolbox

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
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in converterBox.consume(buffer) }
        tapped = true
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
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

/// Pin the actual field and caret before recording. Never paste into another app/field or press Return.
@MainActor final class DictationInsertionTarget {
    let pid: pid_t
    let element: AXUIElement
    let selection: CFRange?
    private init(pid: pid_t, element: AXUIElement, selection: CFRange?) { self.pid = pid; self.element = element; self.selection = selection }
    static func capture() -> DictationInsertionTarget? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(), let app = NSWorkspace.shared.frontmostApplication,
              let element = focused(app.processIdentifier), !secure(element) else { return nil }
        return DictationInsertionTarget(pid: app.processIdentifier, element: element, selection: selectedRange(element))
    }
    enum Insertion { case inserted, pasteRequested, retained }
    func insert(_ text: String) -> Insertion {
        guard let current = NSWorkspace.shared.frontmostApplication, let field = Self.focused(current.processIdentifier) else { return .retained }
        let now = Self.selectedRange(field)
        let sameSelection = selection.map { before in now.map { before.location == $0.location && before.length == $0.length } ?? false } ?? false
        guard MacDictationPolicy.mayInsert(originalPID: pid, currentPID: current.processIdentifier,
                                          sameElement: CFEqual(element, field), sameSelection: sameSelection,
                                          secure: IsSecureEventInputEnabled() || Self.secure(field), trusted: AXIsProcessTrusted()) else { return .retained }
        // AX selected text changes only the selection, never replaces the whole document.
        if AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFString) == .success { return .inserted }
        // Electron/browser editors often don't implement SelectedText. The user's gesture authorizes Paste,
        // with the exact same field still focused. The clipboard stays available for manual paste too.
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return .retained }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return .pasteRequested
    }
    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = value as! AXValue
        guard AXValueGetType(ax) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(ax, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return range
    }
    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }
    private static func focused(_ pid: pid_t) -> AXUIElement? {
        guard let value = attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func secure(_ element: AXUIElement) -> Bool {
        (attribute(element, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole
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
    @Published private(set) var microphones: [DictationMicrophone] = []
    @Published private(set) var holdCombo: HotKeyCombo?
    @Published private(set) var toggleCombo: HotKeyCombo?
    @Published private(set) var phase = "Off"
    @Published private(set) var message: String?
    @Published private(set) var transcript = ""
    @Published private(set) var provisional = ""
    @Published private(set) var audioLevel: Double = 0
    var bridge: (@MainActor (Data) async throws -> HelperResponse)?
    var petFrame: (() -> NSRect?)?
    private var capture: DictationMicrophoneCapture?
    private var target: DictationInsertionTarget?
    private var pendingAudio: Data?
    var canRetry: Bool { pendingAudio != nil && !busy }
    private var task: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var previewRequest: Task<HelperResponse?, Never>?
    private var sessionObservers: [NSObjectProtocol] = []
    private var handler: EventHandlerRef?
    private var registrations: [EventHotKeyRef] = []
    private var held = false
    private var toggleHeld = false
    private var holdPending = false
    private var generation = UUID()
    private var hud: NSPanel?
    var busy: Bool { ["Listening", "Starting", "Transcribing"].contains(phase) }
    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "dictation.enabled")
        microphoneUID = d.string(forKey: "dictation.microphoneUID") ?? ""
        func load(_ prefix: String) -> HotKeyCombo? {
            guard d.bool(forKey: prefix + ".enabled") else { return nil }
            return HotKeyCombo(keyCode: UInt32(clamping: d.integer(forKey: prefix + ".key")), modifiers: UInt32(clamping: d.integer(forKey: prefix + ".modifiers")))
        }
        holdCombo = load("dictation.hold"); toggleCombo = load("dictation.toggle")
        phase = enabled ? "Ready" : "Off"
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            sessionObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.cancel() }
            })
        }
    }
    func refreshMicrophones() { microphones = DictationAudioDevices.inputs() }
    func requestInsertionPermission() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    func setShortcut(_ combo: HotKeyCombo?, hold: Bool, activity: HotKeyCombo?) {
        guard !busy else { message = "Finish dictating before changing a shortcut."; return }
        guard combo == nil || (combo != activity && combo != (hold ? toggleCombo : holdCombo)) else {
            message = "That shortcut is already used by COS. Choose a different combination."; return
        }
        let prefix = hold ? "dictation.hold" : "dictation.toggle"
        let d = UserDefaults.standard
        d.set(combo != nil, forKey: prefix + ".enabled")
        if let combo { d.set(Int(combo.keyCode), forKey: prefix + ".key"); d.set(Int(combo.modifiers), forKey: prefix + ".modifiers") }
        if hold { holdCombo = combo } else { toggleCombo = combo }
        message = nil; registerHotKeys()
    }
    func registerHotKeys() {
        registrations.forEach { UnregisterEventHotKey($0) }; registrations.removeAll()
        guard enabled else { phase = "Off"; return }
        if handler == nil {
            var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)), EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            InstallEventHandler(GetApplicationEventTarget(), dictationHotKeyHandler, 2, &events, nil, &handler)
        }
        for (number, combo) in [(UInt32(1), holdCombo), (UInt32(2), toggleCombo)] {
            guard let combo else { continue }
            if combo == HotKeyCombo.load() { message = "Dictation shortcut conflicts with Open Activity. Choose another shortcut."; continue }
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: dictationHotKeySignature, id: number), GetApplicationEventTarget(), 0, &ref) == noErr, let ref { registrations.append(ref) }
            else { message = "Shortcut is unavailable. Another app may already use it. Choose another combination." }
        }
        if !busy { phase = "Ready" }
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
        target = DictationInsertionTarget.capture()
        pendingAudio = nil; transcript = ""; provisional = ""; audioLevel = 0; message = nil; phase = "Starting"; showHUD()
        task = Task {
            let permission: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: permission = true
            case .notDetermined: permission = await AVCaptureDevice.requestAccess(for: .audio)
            default: permission = false
            }
            guard generation == attempt, !Task.isCancelled else { return }
            guard permission else { phase = "Ready"; message = "Allow Microphone for COS Control in System Settings → Privacy & Security."; return }
            refreshMicrophones()
            let selected = microphones.first { $0.id == microphoneUID }
            guard microphoneUID.isEmpty || selected != nil else { phase = "Ready"; message = "Your selected microphone is disconnected. Choose another microphone."; return }
            do {
                let next = DictationMicrophoneCapture()
                try next.start(deviceID: selected?.deviceID); capture = next; phase = "Listening"
                meterTask = Task {
                    while !Task.isCancelled, phase == "Listening", generation == attempt {
                        if next.failure != nil { stop(); break }
                        audioLevel = min(1, next.level * 4)
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                previewTask = Task {
                    while !Task.isCancelled, generation == attempt, phase == "Listening" {
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled, generation == attempt, phase == "Listening", let bridge else { break }
                        let pcm = next.snapshot()
                        guard pcm.count >= 32_000, let audio = try? MacDictationPolicy.wav(pcm) else { continue }
                        let request = Task { try? await bridge(audio) }
                        previewRequest = request
                        let response = await request.value
                        if generation == attempt { previewRequest = nil }
                        if let response, generation == attempt, phase == "Listening", !Task.isCancelled,
                           response.ok, response.details["engine"]?.string == "parakeet-ultra" {
                            provisional = response.details["text"]?.string ?? provisional
                        }
                    }
                }
                timer = Task { try? await Task.sleep(for: .seconds(MacDictationPolicy.maximumSeconds)); if !Task.isCancelled { stop() } }
            } catch { phase = "Ready"; message = error.localizedDescription }
        }
    }
    func stop() {
        if phase == "Starting" { cancel(); return }
        guard phase == "Listening", let capture else { return }
        timer?.cancel(); timer = nil; self.capture = nil
        previewTask?.cancel(); previewTask = nil; meterTask?.cancel(); meterTask = nil
        let attempt = generation
        let pendingPreview = previewRequest
        do {
            let pcm = try capture.stop()
            guard pcm.count >= 3200 else { phase = "Ready"; message = "No usable speech was captured. Try holding the shortcut longer."; return }
            phase = "Transcribing"
            let wav = try MacDictationPolicy.wav(pcm)
            pendingAudio = wav
            transcribe(wav, attempt: attempt, pendingPreview: pendingPreview)
        } catch { phase = "Ready"; message = error.localizedDescription }
    }
    func retryTranscription() {
        guard canRetry, let audio = pendingAudio else { return }
        phase = "Transcribing"; message = nil
        transcribe(audio, attempt: generation, pendingPreview: nil)
    }
    private func transcribe(_ wav: Data, attempt: UUID, pendingPreview: Task<HelperResponse?, Never>?) {
        task = Task {
            // Drain a preview already decoding before asking Parakeet for the final clip.
            // Cancelling the timer cannot create two competing local model requests.
            _ = await pendingPreview?.value
            guard generation == attempt, !Task.isCancelled else { return }
            do {
                guard let bridge else { throw NSError(domain: "COSDictation", code: 2, userInfo: [NSLocalizedDescriptionKey: "The transcription server is not connected."]) }
                let response = try await bridge(wav)
                guard generation == attempt, !Task.isCancelled else { return }
                guard response.ok, let text = response.details["text"]?.string, !text.isEmpty,
                      response.details["engine"]?.string == "parakeet-ultra" else { phase = "Ready"; message = response.message; return }
                transcript = text; pendingAudio = nil
                // Leave the result visible if focus moved, permissions were not granted, or the field is secure.
                let insertion = target?.insert(text) ?? .retained
                phase = "Ready"
                switch insertion {
                case .inserted: message = "Text inserted. Review it before sending."
                case .pasteRequested: message = "Paste requested. Review the field; your text is also available to copy."
                case .retained: message = "Text ready to copy. Keep the same field and caret selected for automatic insertion; Accessibility access is required."
                }
                target = nil
            } catch { guard generation == attempt else { return }; phase = "Ready"; message = error.localizedDescription }
        }
    }
    func cancel() {
        generation = UUID(); pendingAudio = nil; task?.cancel(); task = nil; previewRequest?.cancel(); previewRequest = nil; timer?.cancel(); timer = nil
        previewTask?.cancel(); previewTask = nil; meterTask?.cancel(); meterTask = nil
        _ = try? capture?.stop(); capture = nil; target = nil; held = false; toggleHeld = false; holdPending = false
        phase = enabled ? "Ready" : "Off"; message = "Dictation canceled. No text was inserted."
        hud?.orderOut(nil)
    }
    func copyText() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(transcript, forType: .string) }
    private func showHUD() {
        if hud == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 260), styleMask: [.nonactivatingPanel, .titled], backing: .buffered, defer: false)
            panel.title = "COS Dictation"; panel.level = .floating; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: DictationHUD(store: self)); hud = panel
        }
        if let frame = petFrame?(), let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) {
            let bounds = screen.visibleFrame
            hud?.setFrameOrigin(NSPoint(x: min(max(bounds.minX, frame.midX - 195), bounds.maxX - 390),
                                       y: min(max(bounds.minY + 12, frame.minY - 290), bounds.maxY - 290)))
        } else if let screen = NSScreen.main { hud?.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 195, y: screen.visibleFrame.minY + 24)) }
        hud?.orderFrontRegardless() // nonactivating: the user's editing field retains focus
    }
}

private struct DictationHUD: View {
    @ObservedObject var store: MacDictationStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(store.phase, systemImage: store.phase == "Listening" ? "mic.fill" : "waveform").font(.headline)
            if store.phase == "Listening" {
                HStack(spacing: 3) {
                    ForEach(0..<18, id: \.self) { i in
                        Capsule().fill(COSPalette.accent).frame(width: 4, height: 4 + store.audioLevel * (i % 3 == 0 ? 24 : 16))
                    }
                }.frame(height: 28).accessibilityLabel("Microphone level")
                if !store.provisional.isEmpty {
                    Text("Live preview · may change").font(.caption2).foregroundStyle(.secondary)
                    Text(store.provisional).font(.caption).lineLimit(3)
                }
            }
            if !store.transcript.isEmpty {
                ScrollView { Text(store.transcript).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 88)
            }
            Text(store.message ?? "Parakeet Ultra · COS dictionary · local audio").font(.caption).fixedSize(horizontal: false, vertical: true)
            HStack {
                if store.phase == "Listening" { Button("Stop") { store.stop() } }
                if !store.transcript.isEmpty { Button("Copy text") { store.copyText() } }
                if store.canRetry { Button("Retry transcription") { store.retryTranscription() } }
                Button(store.busy ? "Cancel" : "Close") { store.cancel() }
            }.controlSize(.small)
        }.padding(16).frame(width: 390, height: 260, alignment: .topLeading).background(COSPalette.panel).cosControlTheme()
    }
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
                Text("Choose a key combination unused by Wispr Flow and other apps. A modifier plus a key is supported. Text is inserted only while the same field and caret remain selected; COS never presses Send.")
                    .font(.caption2).foregroundStyle(.secondary)
                if let message = store.message { Text(message).font(.caption2).foregroundStyle(COSPalette.amber) }
            }
        }.onAppear { store.refreshMicrophones() }
    }
}

private struct DictationShortcutRow: View {
    @ObservedObject var store: MacDictationStore
    let hold: Bool
    let activityShortcut: HotKeyCombo?
    @State private var monitor: Any?
    @State private var note: String?
    var body: some View {
        HStack {
            Text(hold ? "Push to talk" : "Start / stop").font(.caption)
            Text(monitor != nil ? "Press shortcut…" : ((hold ? store.holdCombo : store.toggleCombo)?.display ?? "Off")).font(.caption.monospaced())
            Button(monitor == nil ? "Change" : "Cancel") { monitor == nil ? record() : stop() }
            Button("Off") { store.setShortcut(nil, hold: hold, activity: activityShortcut); stop() }
            if let note { Text(note).font(.caption2) }
        }.controlSize(.mini).disabled(store.busy).onDisappear { stop() }
    }
    private func record() {
        note = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let key = event.keyCode; let modifiers = HotKeyCombo.carbonModifiers(from: event.modifierFlags)
            Task { @MainActor in
                if key == 53 { stop() }
                else if let combo = HotKeyCombo(keyCode: UInt32(key), modifiers: modifiers) { store.setShortcut(combo, hold: hold, activity: activityShortcut); stop() }
                else { note = "Add Command, Control or Option." }
            }
            return nil
        }
    }
    private func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}
