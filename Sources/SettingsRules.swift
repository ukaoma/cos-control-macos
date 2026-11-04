import CoreAudio
import Foundation

// Settings Release A (Miles, 2026-11-03, "go a"): the rules behind the safer settings controls, in one file with no
// SwiftUI and no model, so Tests/SettingsRulesChecks.swift runs them alone (Tests/run-settings-a.sh). The views ask these
// and draw the answer; nothing here reads the server, a window or a clock the checks cannot set.

// MARK: The nine rows that restart the server

/// Quality tier, Background jobs, Fast preview, Show AI sessions, Continue sessions, Local model, Reliable video uploads,
/// GPU when idle and Playback cleanup. Each Apply restarts the server through a drain that waits up to 90 seconds for
/// running work and, in a live meeting, times out and leaves the gate closed for Repair. So an Apply is never live for
/// nothing, never live while work runs, and a failed one puts the switch back on what the server holds.
enum RestartApply {
    /// The hub's row id and the helper command each Apply runs.
    static let rows: [(id: String, command: String)] = [
        ("UT-03", "set-transcription-tier"), ("UT-04", "set-background-jobs"), ("UT-05", "set-meeting-preview"),
        ("UT-06", "set-claude-sessions"), ("UT-07", "set-thread-attach"), ("UT-08", "set-ollama-model"),
        ("UT-09", "set-video-upload-v2"), ("UT-11", "set-idle-metal-hq"), ("UT-12", "set-adaptive-audio-cleanup"),
    ]
    static func row(forCommand command: String) -> String? { rows.first { $0.command == command }?.id }

    /// Everything that a restart would interrupt or has to wait for. A server count, a Mac recording, a dictation, an
    /// upload, the server's own "meeting work blocks a restart", or a change already in progress.
    struct Work: Equatable, Sendable {
        var jobs = 0
        var transcriptionSessions = 0
        var macRecordings = 0
        var dictating = false
        var uploads = 0
        var meetingBlocksRestart = false
        var transactionPending = false
        init(jobs: Int? = 0, transcriptionSessions: Int? = 0, macRecordings: Int = 0, dictating: Bool = false, uploads: Int = 0,
             meetingBlocksRestart: Bool = false, transactionPending: Bool = false) {
            self.jobs = jobs ?? 0; self.transcriptionSessions = transcriptionSessions ?? 0; self.macRecordings = macRecordings
            self.dictating = dictating; self.uploads = uploads
            self.meetingBlocksRestart = meetingBlocksRestart; self.transactionPending = transactionPending
        }
        var active: Bool {
            jobs + transcriptionSessions + macRecordings + uploads > 0 || dictating || meetingBlocksRestart || transactionPending
        }
    }

    /// The selection is not what the server holds. A server that did not report the value cannot be compared, so the
    /// choice stays open to apply (an older server's row).
    static func differs<Value: Equatable>(selected: Value, server: Value?) -> Bool {
        guard let server else { return true }
        return selected != server
    }

    /// Apply is live only for a real change, with the server installed and no other change in progress (`locked`), and
    /// only while nothing is running.
    static func applyEnabled<Value: Equatable>(selected: Value, server: Value?, locked: Bool, work: Work) -> Bool {
        !locked && !work.active && differs(selected: selected, server: server)
    }

    static let notApplied = "Not applied yet."
    static let waitsForWork = "Waits for running work."
    static let appliesRestart = "Applying restarts the server."

    /// The line under a row: "Not applied yet." while the selection differs, with what it waits for when work runs.
    static func note(differs: Bool, work: Work) -> String? {
        guard differs else { return nil }
        return work.active ? notApplied + " " + waitsForWork : notApplied
    }

    /// A failed Apply, in words, on the row it came from.
    static func failureNote(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "It did not apply. Showing the server's setting." : "It did not apply: " + trimmed + " Showing the server's setting."
    }

    /// What a switch shows after a failed Apply: the server's value, never the one that was refused. A server that
    /// reports nothing leaves the choice where it is.
    static func reseeded<Value>(current: Value, server: Value?) -> Value { server ?? current }
}

// MARK: Confirms

/// What a confirm in the panel and the hub is about. One at a time.
enum ServerConfirm: Equatable, Sendable {
    case stop, rollback, repair, quit
}

enum SettingsConfirmCopy {
    static func title(_ confirm: ServerConfirm) -> String {
        switch confirm {
        case .stop: "Stop the server?"
        case .rollback: "Roll back the server?"
        case .repair: "Repair the server?"
        case .quit: "Quit COS Control?"
        }
    }
    static func message(_ confirm: ServerConfirm, workRunning: Bool, serverVersion: String?) -> String {
        let busy = " Work is running now. This waits up to 90 seconds for it, then fails and leaves the server closed until you run Repair."
        switch confirm {
        case .stop:
            return "Glasses, the phone and Work cannot reach COS until you press Start. Your meetings and settings stay as they are."
        case .rollback:
            let name = serverVersion.map { "server " + $0 } ?? "this server"
            return "COS Control stops \(name) and starts the version it kept. You can update again later." + (workRunning ? busy : "")
        case .repair:
            return "Repair rebuilds the server's runtime and restarts it. Use it when the server is not working." + (workRunning ? busy : "")
        case .quit:
            return "A Mac recording is running. Quitting stops it and saves what was recorded. The server keeps running."
        }
    }
    static func action(_ confirm: ServerConfirm) -> String {
        switch confirm {
        case .stop: "Stop server"
        case .rollback: "Roll back"
        case .repair: "Repair"
        case .quit: "Stop recording and quit"
        }
    }
    /// Quit asks only when something live would be cut short. Nothing live: it quits at once, as it always did.
    static func quitNeedsConfirm(macRecordingActive: Bool) -> Bool { macRecordingActive }

    /// Choosing a shorter time to keep dictations deletes the older ones at once; the dialog says how many. `days` is nil for
    /// Forever, which can only delete through the 5,000 cap.
    static func shortenTitle(count: Int, days: Int?) -> String {
        "Delete \(count) older \(count == 1 ? "dictation" : "dictations")?"
    }
    static func shortenMessage(count: Int, days: Int?) -> String {
        let noun = count == 1 ? "dictation" : "dictations"
        guard let days else { return "COS keeps at most 5,000 dictations, so this deletes the \(count) oldest. This cannot be undone." }
        return "Keeping dictations for \(days) days deletes \(count) \(noun) older than that from this Mac. This cannot be undone."
    }
    static func shortenAction(count: Int, days: Int?) -> String {
        days.map { "Delete \(count) and keep \($0) days" } ?? "Delete \(count)"
    }
}

// MARK: Typing into a stepper

/// What a typed count becomes, inside the server's own bounds. Never a value the server would refuse.
enum TypedCount {
    enum Result: Equatable, Sendable {
        /// The text was a count inside the range.
        case value(Int)
        /// A count outside the range: the nearest allowed value, and the sentence that says so.
        case clamped(Int, note: String)
        /// Not a whole number: the field goes back to what it showed.
        case invalid
        var accepted: Int? {
            switch self {
            case .value(let value), .clamped(let value, _): value
            case .invalid: nil
            }
        }
    }
    static func parse(_ text: String, low: Int, high: Int) -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isNumber }), let number = Int(trimmed) else { return .invalid }
        if number < low { return .clamped(low, note: "The least is \(low).") }
        if number > high { return .clamped(high, note: "The most is \(high).") }
        return .value(number)
    }
}

// MARK: A menu that always shows its saved value

enum ValueMenu {
    struct Choice: Equatable, Sendable {
        let value: Int
        let title: String
    }
    /// The stops, sorted, with the saved value among them: a saved value off the list (a limit the server allowed once,
    /// or one set another way) is its own choice, so the menu's face is never blank.
    static func choices(stops: [Int], current: Int, title: (Int) -> String) -> [Choice] {
        var values = Set(stops)
        let offList = !values.contains(current)
        values.insert(current)
        return values.sorted().map { value in
            Choice(value: value, title: value == current && offList ? title(value) + " (your setting)" : title(value))
        }
    }
}

// MARK: The daily cap

/// A key's daily cap: a few common amounts, the saved cap when it is not one of them, and "Other amount".
enum DailyCap {
    static let presets: [Double] = [1, 2, 5, 10, 25, 50, 100]
    static let other = "other"
    static let current = "current"
    struct Choice: Equatable, Sendable {
        let id: String
        let title: String
    }
    static func dollars(_ value: Double) -> String {
        value == value.rounded() ? "$\(Int(value))" : String(format: "$%.2f", value)
    }
    static func presetID(_ value: Double) -> String { "p" + String(format: "%.2f", value) }
    /// Presets in order; the saved cap as its own line when it is not a preset; Other amount last.
    static func choices(saved: Double?) -> [Choice] {
        var out = presets.map { Choice(id: presetID($0), title: dollars($0) + " a day") }
        if let saved, !presets.contains(where: { abs($0 - saved) < 0.005 }) {
            out.append(Choice(id: current, title: dollars(saved) + " a day (your cap)"))
        }
        out.append(Choice(id: other, title: "Other amount"))
        return out
    }
    /// Which choice the face shows. `draft` is what is in the amount field (nil: nothing typed), `saved` the server's cap,
    /// `otherOpen` that Other amount was picked, `parse` the one rule for an amount (KeyLanes.parseCap: $0.01 to $1000, cents).
    /// Always one of `choices(saved:)`: never blank.
    static func face(draft: String?, saved: Double?, otherOpen: Bool, parse: (String) -> Double?) -> String {
        if otherOpen { return other }
        let value = draft.flatMap(parse) ?? saved
        guard let value else { return other }
        if let preset = presets.first(where: { abs($0 - value) < 0.005 }) { return presetID(preset) }
        if let saved, abs(saved - value) < 0.005 { return current }
        return other
    }
    /// A preset's id back to its amount; nil for the saved-cap line and Other amount.
    static func amount(ofChoice id: String) -> Double? {
        presets.first { presetID($0) == id }
    }
    /// Set cap is live for an amount that parses and differs from the saved cap.
    static func canSet(draft: String?, saved: Double?, parse: (String) -> Double?) -> Bool {
        guard let draft, let value = parse(draft) else { return false }
        guard let saved else { return true }
        return abs(value - saved) >= 0.005
    }
}

// MARK: The Versions line

enum VersionsLine {
    /// "Controller 0.5.366  •  Server 6.99.0". It never says "(npm latest)": Control does not know the newest published
    /// server, so it never claims the one running is it. A server that is installed but not running says so.
    static func text(controller: String, running: String?, installed: String?, selfManaged: Bool) -> String {
        if let running, !running.isEmpty { return "Controller \(controller)  •  Server \(running)" }
        if let installed, !installed.isEmpty { return "Controller \(controller)  •  Server \(installed) (not running)" }
        if selfManaged { return "Controller \(controller)  •  Server self-managed" }
        return "Controller \(controller)  •  Server not installed"
    }
}

// MARK: Microphones that follow the Mac

/// Calls `refresh` when macOS adds or removes an audio device, so the Microphone list is never stale. One listener at a
/// time, started when a page that shows the list appears and stopped when it goes. When macOS refuses the listener,
/// `available` is false and the page keeps its Check again button as the way back.
@MainActor final class DeviceListWatcher {
    typealias Register = (_ onChange: @escaping @Sendable () -> Void) -> (stop: () -> Void, ok: Bool)
    private let register: Register
    private let debounce: Duration
    private var stopListening: (() -> Void)?
    private var refresh: (@MainActor () -> Void)?
    private var pending: Task<Void, Never>?
    private(set) var registrations = 0
    private(set) var available = true
    var watching: Bool { stopListening != nil }

    init(debounce: Duration = .milliseconds(250), register: @escaping Register = DeviceListWatcher.coreAudio) {
        self.debounce = debounce
        self.register = register
    }

    /// Listen. A second call while listening only swaps the callback: one registration, never two.
    func start(refresh: @escaping @MainActor () -> Void) {
        self.refresh = refresh
        guard stopListening == nil else { return }
        let result = register { [weak self] in
            Task { @MainActor in self?.devicesChanged() }
        }
        registrations += 1
        available = result.ok
        if result.ok { stopListening = result.stop }
    }

    func stop() {
        pending?.cancel(); pending = nil
        stopListening?()
        stopListening = nil
        refresh = nil
    }

    /// macOS reported a change. Several arrive for one plug (the device, then its streams), so one refresh follows the last.
    func devicesChanged() {
        guard watching else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            guard let self else { return }
            if self.debounce > .zero { try? await Task.sleep(for: self.debounce) }
            guard !Task.isCancelled else { return }
            self.refresh?()
        }
    }

    /// The real listener: the system object's device list.
    nonisolated static func coreAudio(_ onChange: @escaping @Sendable () -> Void) -> (stop: () -> Void, ok: Bool) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        guard status == noErr else { return ({}, false) }
        return ({
            var removed = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &removed, DispatchQueue.main, block)
        }, true)
    }
}
