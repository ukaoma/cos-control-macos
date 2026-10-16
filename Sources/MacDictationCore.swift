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

/// Serial microphone callback owns conversion; this lock protects its bounded result from Stop.
final class DictationPCMBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var failure: String?
    private var level: Double = 0
    func append(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil else { return }
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
    func failureMessage() -> String? { lock.lock(); defer { lock.unlock() }; return failure }
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
    private var pressedAt: TimeInterval = 0
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
            case .notTrusted: "Allow COS Control in Accessibility to drop text in for you. For now, click where you want it and press ⌘V."
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
    static func isChromiumFamily(frameworks: [String]) -> Bool {
        frameworks.contains { name in
            name == "Electron Framework.framework" || name == "Chromium Embedded Framework.framework"
                || (name.hasSuffix(" Framework.framework") && ["Chrome", "Chromium", "Edge", "Brave", "Vivaldi", "Opera", "Arc"].contains { name.contains($0) })
        }
    }
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

    init(id: UUID, text: String, createdAt: Date, delivery: Delivery, engine: String? = nil, fallbackReason: String? = nil) {
        self.id = id; self.text = text; self.createdAt = createdAt; self.delivery = delivery
        self.engine = engine; self.fallbackReason = fallbackReason
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
    func metaLine(time: String) -> String {
        "\(time) · \(wordCount) \(wordCount == 1 ? "word" : "words") · \(outcomeLabel)"
    }

    // Stored as kind/app/reason. 0.5.309 files carry insertedApp/pasted instead and still load.
    private enum Keys: String, CodingKey { case id, text, createdAt, kind, app, reason, viaPaste, insertedApp, pasted, engine, fallbackReason }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
        fallbackReason = try c.decodeIfPresent(String.self, forKey: .fallbackReason)
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
        list.map { $0.id == id ? DictationRecord(id: $0.id, text: text, createdAt: $0.createdAt, delivery: $0.delivery, engine: $0.engine, fallbackReason: $0.fallbackReason) : $0 }
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

/// What the listening pill shows. It replaces the pet's ledger row only while it is not hidden (Miles picked A).
enum DictationPill: Equatable, Sendable {
    case hidden
    case listening(since: Date)
    case transcribing
    /// About 1.5 seconds after delivery. `confirmed` (green, ✓) only when a measured change proved the text landed.
    case flash(label: String, confirmed: Bool)
    static let flashSeconds: TimeInterval = 1.5
    var replacesLedger: Bool { self != .hidden }
    var label: String {
        switch self {
        case .hidden: ""
        case .listening: "LISTENING"
        case .transcribing: "TRANSCRIBING"
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
        ("windu-saber", "Miles Windu saber"),
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
    /// THE pet → default table (Miles: the Jedi's crackling Unstable saber is his favorite). 0.5.315: his own saber
    /// design is the Jedi Miles Windu pack's default; Nia Solari, Elara Vale and Rowan Vale keep the Unstable saber.
    static func petDefault(_ kind: DictationPetKind, pack: String? = nil) -> String {
        switch kind {
        case .jedi: pack == winduPackID ? "windu-saber" : "unstable-saber"
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

/// After COS types a dictation, it watches that one field until focus leaves it (three minutes at most) and learns a
/// word or two the person changed into something that sounds like it ("joule 360" → "Jewel360"). Pure, so every rule is
/// tested and mutated; the app measures, calls these and acts.
enum DictationEditLearning {
    static let watchSeconds: TimeInterval = 180
    static let maximumReads = 20
    static let debounceSeconds: TimeInterval = 1.5
    static let pollMilliseconds = 500
    static let maximumWords = 3

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
    static func eligibility(mode: DictationLearnMode, secure: Bool, terminal: Bool, electron: Bool, chromium: Bool, setterWorked: Bool) -> Eligibility {
        if mode == .off { return .skip("off") }
        if secure { return .skip("secure") }
        if terminal { return .skip("terminal") }
        if electron { return .probe }
        if chromium, !setterWorked { return .probe }
        return .learn
    }

    enum Stop: String, Sendable { case secure, appGone, cap, reads, focusLeft, emptied, unreadable }
    /// Why the watch ends now, or nil to keep watching. Secure input is checked first, on every poll.
    static func stop(elapsed: TimeInterval, reads: Int, appRunning: Bool, secure: Bool, focused: Bool, fieldCharacters: Int?) -> Stop? {
        if secure { return .secure }
        if !appRunning { return .appGone }
        if elapsed >= watchSeconds { return .cap }
        if reads >= maximumReads { return .reads }
        if !focused { return .focusLeft }
        guard let fieldCharacters else { return .unreadable }
        if fieldCharacters == 0 { return .emptied }
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
    }
    /// The pair to learn from one edit inside the dictation, or nil. A re-spelling of one to three words that sounds or
    /// is spelled like what was heard, never a rewording, a punctuation fix, a sentence-start capital, or a swap between
    /// two plain English words ("their" → "there"). `known` is the system spell checker; `learned` is the dictionary.
    static func candidate(_ edit: DictationReplace.Edit, known: (String) -> Bool, learned: (String, String) -> Bool) -> Candidate? {
        let edge = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines)
        let heard = edit.original.trimmingCharacters(in: edge), written = edit.replacement.trimmingCharacters(in: edge)
        guard !heard.isEmpty, !written.isEmpty, heard != written, !(heard + written).contains(where: \.isNewline) else { return nil }
        let heardWords = heard.split(whereSeparator: \.isWhitespace).map(String.init), writtenWords = written.split(whereSeparator: \.isWhitespace).map(String.init)
        guard (1...maximumWords).contains(heardWords.count), (1...maximumWords).contains(writtenWords.count) else { return nil }
        if DictationFixGuess.normalized(heard) == DictationFixGuess.normalized(written) {
            // Only a change of capitals counts ("ios" → "iOS", "gina" → "Gina"), and not a sentence's first capital.
            guard heard.lowercased() == written.lowercased() else { return nil }
            let innerCapital = written.dropFirst().contains(where: \.isUppercase)
            guard innerCapital || !heardWords.allSatisfy(known) else { return nil }
        } else {
            guard DictationFixGuess.score(heard: heard, term: written) >= DictationFixGuess.threshold else { return nil }
            if heardWords.allSatisfy(known), writtenWords.allSatisfy(known) { return nil }
        }
        guard !learned(heard, written) else { return nil }
        return Candidate(heard: heard, written: written)
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
        next.suggestions = [item] + next.suggestions.filter { key($0.heard, $0.written) != k }
        return pruned(next, now: now)
    }
    /// Save automatically: the pair goes on the learned list (the dictionary holds the correction itself).
    static func learning(_ item: DictationSuggestion, in state: State, now: Date) -> State {
        var next = pruned(state, now: now)
        let k = key(item.heard, item.written)
        next.learned = [item] + next.learned.filter { key($0.heard, $0.written) != k }
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
    case none

    var title: String? {
        switch self {
        case .installParakeet: "Install Parakeet (654 MB)"
        case .useWhisper: "Use Whisper"
        case .retry: "Retry"
        case .openTranscriptionSettings: "Open Transcription settings"
        case .openMicrophoneSettings: "Open Settings"
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
