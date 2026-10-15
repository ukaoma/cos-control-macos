import Foundation

/// Desktop dictation is a user gesture, separate from meeting recording and glasses gestures.
enum MacDictationPolicy {
    static let maximumSeconds = 120
    static let maximumPCMBytes = maximumSeconds * 16_000 * 2
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
/// no other key goes down before release, so Fn+arrow, ⌘C or ⌥-click never start dictation.
struct LoneModifierTracker: Sendable {
    enum Output: Equatable, Sendable { case pressed, released, chord }
    let keyCode: UInt16
    private let device: UInt64, family: UInt64
    private(set) var down = false
    private var clean = false
    init?(keyCode: UInt16) {
        guard let key = DictationTrigger.modifierKeys[keyCode] else { return nil }
        self.keyCode = keyCode; device = key.device; family = key.family
    }
    mutating func flagsChanged(keyCode changed: UInt16, flags: UInt64) -> Output? {
        guard changed == keyCode else {
            // Another modifier joined while ours is held: a chord, never dictation.
            guard down, clean else { return nil }
            clean = false; return .chord
        }
        let nowDown = flags & device != 0
        if nowDown, !down {
            down = true
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
    /// The app lost key events (sleep, monitor removed): forget a press rather than stay latched.
    mutating func reset() { down = false; clean = false }
}

// MARK: - Wispr-style dictation (0.5.309)

/// Where finished text goes (Miles, 2026-10-15): it is ALWAYS copied, then dropped into whatever editable text element
/// has focus at the moment transcription finishes, so the person may click elsewhere while it transcribes. Insertion is
/// refused, and the text stays on the clipboard with the pet's card, when any of these hold. Never presses Return.
enum DictationInsertPolicy {
    enum Refusal: Equatable, Sendable {
        case notTrusted, secureInput, secureField, ownOverlay, noTextBox
        /// The card's heading (mock 04).
        var title: String {
            switch self {
            case .notTrusted: "COPIED · ALLOW ACCESSIBILITY"
            case .secureInput, .secureField: "PASSWORD FIELD · COPIED"
            case .ownOverlay, .noTextBox: "NO TEXT BOX · COPIED"
            }
        }
        var note: String {
            switch self {
            case .notTrusted: "Allow COS Control in Accessibility to drop text in for you. For now, click where you want it and press ⌘V."
            case .secureInput, .secureField: "COS never types into a password field or secure input. Press ⌘V yourself if you mean to."
            case .ownOverlay, .noTextBox: "Click where you want it, then press ⌘V."
            }
        }
    }
    static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    static let secureSubrole = "AXSecureTextField"
    /// nil means insert. `role` nil means nothing has keyboard focus. `rangeSettable` is AXSelectedTextRange being
    /// settable; `editableAncestor` is a web editor's AXEditableAncestor (contenteditable, rich editors).
    static func refusal(trusted: Bool, secureInput: Bool, role: String?, subrole: String?, rangeSettable: Bool,
                        editableAncestor: Bool, ownOverlay: Bool) -> Refusal? {
        guard trusted else { return .notTrusted }
        guard !secureInput else { return .secureInput }
        if subrole == secureSubrole { return .secureField }
        if ownOverlay { return .ownOverlay }
        guard let role else { return .noTextBox }
        if editableRoles.contains(role) || subrole.map({ editableRoles.contains($0) }) == true { return nil }
        return rangeSettable || editableAncestor ? nil : .noTextBox
    }
}

/// Level on a decibel scale (-50 to -10 dBFS), fast rise and slow fall, so quiet speech still moves the bars.
struct DictationLevelMeter: Sendable {
    static let floorDB = -50.0, ceilingDB = -10.0
    /// Share of the previous level kept on each falling tick (one tick is 50 ms).
    static let release = 0.82
    private(set) var level = 0.0
    static func dBFS(rms: Double) -> Double { rms > 0 ? 20 * log10(rms) : -160 }
    static func normalized(dBFS: Double) -> Double { min(1, max(0, (dBFS - floorDB) / (ceilingDB - floorDB))) }
    mutating func update(rms: Double) -> Double {
        let target = Self.normalized(dBFS: Self.dBFS(rms: rms))
        level = target >= level ? target : level * Self.release + target * (1 - Self.release)
        return level
    }
}

/// One finished dictation. The text is private: it lives only in this record, the history file and the clipboard.
struct DictationRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let createdAt: Date
    /// The app the text went into, or nil when it was only copied (no text box, or insertion refused).
    let insertedApp: String?
    /// True when the text went in through ⌘V, which COS cannot confirm landed.
    var pasted: Bool = false

    var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }
    var firstLine: String {
        text.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }
    /// "inserted · Slack", "pasted · Slack", or "copied, no text box" (mock 05).
    var outcomeLabel: String {
        guard let app = insertedApp else { return "copied, no text box" }
        return (pasted ? "pasted · " : "inserted · ") + app
    }
    func metaLine(time: String) -> String {
        "\(time) · \(wordCount) \(wordCount == 1 ? "word" : "words") · \(outcomeLabel)"
    }
}

/// Recent dictations: the last 50, newest first, kept on this Mac across restarts (Miles picked A, 2026-10-15).
enum DictationHistory {
    static let limit = 50
    static func adding(_ record: DictationRecord, to list: [DictationRecord]) -> [DictationRecord] {
        Array(([record] + list.filter { $0.id != record.id }).prefix(limit))
    }
    static func ordered(_ list: [DictationRecord]) -> [DictationRecord] {
        Array(list.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
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
    /// About 1.5 seconds after the text went in.
    case inserted(app: String, pasted: Bool)
    static let flashSeconds: TimeInterval = 1.5
    var replacesLedger: Bool { self != .hidden }
    var label: String {
        switch self {
        case .hidden: ""
        case .listening: "LISTENING"
        case .transcribing: "TRANSCRIBING"
        case .inserted(let app, let pasted): (pasted ? "✓ PASTED · " : "✓ INSERTED · ") + app.uppercased()
        }
    }
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return "\(s / 60):" + (s % 60 < 10 ? "0" : "") + "\(s % 60)"
    }
}
