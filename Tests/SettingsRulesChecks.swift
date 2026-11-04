import Foundation

/// Settings Release A (Miles, 2026-11-03): the rules in Sources/SettingsRules.swift, compiled alone (Tests/run-settings-a.sh).
/// Each check names the behaviour it protects, so a mutant that breaks one is killed by a check that says what broke.
@main struct SettingsRulesChecks {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passes = 0
    static func check(_ ok: Bool, _ what: String) {
        if ok { passes += 1 } else { failures += 1; print("FAIL: \(what)") }
    }

    @MainActor static func main() async {
        restartApply()
        confirms()
        typedCount()
        valueMenu()
        dailyCap()
        versions()
        await watcher()
        print(failures == 0 ? "settings rules checks: \(passes) passed" : "settings rules checks: \(failures) FAILED of \(passes + failures)")
        exit(failures == 0 ? 0 : 1)
    }

    // ── The nine restart rows.
    static func restartApply() {
        let idle = RestartApply.Work()
        check(RestartApply.rows.count == 9 && Set(RestartApply.rows.map(\.id)).count == 9, "nine restart rows, each once")
        check(RestartApply.rows.map(\.id) == ["UT-03", "UT-04", "UT-05", "UT-06", "UT-07", "UT-08", "UT-09", "UT-11", "UT-12"], "the nine rows are UT-03 to UT-12 without UT-10")
        check(RestartApply.row(forCommand: "set-claude-sessions") == "UT-06", "a failed command finds its row")
        check(RestartApply.row(forCommand: "restart") == nil, "a command that is not one of the nine finds no row")

        check(!RestartApply.applyEnabled(selected: true, server: true, locked: false, work: idle), "Apply is off when the selection equals the server's value")
        check(RestartApply.applyEnabled(selected: false, server: true, locked: false, work: idle), "Apply is on when the selection differs from the server's value")
        check(!RestartApply.applyEnabled(selected: "max", server: "balanced", locked: true, work: idle), "Apply is off while the page is locked")
        check(RestartApply.applyEnabled(selected: "max", server: "balanced", locked: false, work: idle), "a tier change applies")
        check(!RestartApply.applyEnabled(selected: "balanced", server: "balanced", locked: false, work: idle), "the same tier does not apply")
        check(RestartApply.differs(selected: false, server: nil), "a value the server did not report can be applied")
        check(!RestartApply.differs(selected: "", server: ""), "automatic (empty) equals automatic")

        // Every kind of running work holds Apply, for a row that does differ.
        let kinds: [(String, RestartApply.Work)] = [
            ("a job", .init(jobs: 1)),
            ("a transcription session", .init(transcriptionSessions: 1)),
            ("a Mac recording", .init(macRecordings: 1)),
            ("a dictation", .init(dictating: true)),
            ("an upload", .init(uploads: 1)),
            ("the server's own meeting-work block", .init(meetingBlocksRestart: true)),
            ("a change already in progress", .init(transactionPending: true)),
        ]
        for (name, work) in kinds {
            check(work.active, "\(name) counts as running work")
            check(!RestartApply.applyEnabled(selected: true, server: false, locked: false, work: work), "Apply waits for \(name)")
        }
        check(!idle.active, "nothing running is not running work")
        check(RestartApply.Work(jobs: nil, transcriptionSessions: nil) == idle, "counts the server did not send are zero")

        check(RestartApply.note(differs: false, work: idle) == nil, "no note when the row matches the server")
        check(RestartApply.note(differs: true, work: idle) == "Not applied yet.", "a changed row says Not applied yet")
        check(RestartApply.note(differs: true, work: .init(jobs: 2)) == "Not applied yet. Waits for running work.", "a changed row says it waits when work runs")
        check(RestartApply.note(differs: false, work: .init(jobs: 2)) == nil, "an unchanged row says nothing while work runs")

        check(RestartApply.reseeded(current: true, server: false) == false, "after a failed Apply the switch shows the server's value")
        check(RestartApply.reseeded(current: "max", server: "balanced") == "balanced", "after a failed Apply the tier shows the server's value")
        check(RestartApply.reseeded(current: true, server: nil as Bool?) == true, "a server that reports nothing leaves the choice")
        check(RestartApply.failureNote("Timed out.").hasPrefix("It did not apply: Timed out."), "a failed Apply says why")
        check(RestartApply.failureNote("  ").contains("Showing the server's setting"), "a failed Apply with no reason still says it did not apply")
        for line in [RestartApply.notApplied, RestartApply.waitsForWork, RestartApply.failureNote("x")] {
            check(!line.contains("—") && !line.contains("→"), "restart copy has no em dash or arrow: \(line)")
        }
    }

    // ── Confirms.
    static func confirms() {
        for confirm in [ServerConfirm.stop, .rollback, .repair, .quit] {
            check(!SettingsConfirmCopy.title(confirm).isEmpty && !SettingsConfirmCopy.action(confirm).isEmpty, "\(confirm) has a title and an action")
            let message = SettingsConfirmCopy.message(confirm, workRunning: false, serverVersion: "6.99.0")
            check(!message.contains("—") && !message.contains("→"), "\(confirm) copy has no em dash or arrow")
        }
        check(SettingsConfirmCopy.message(.rollback, workRunning: true, serverVersion: nil).contains("Work is running now"), "rolling back while work runs says what happens")
        check(!SettingsConfirmCopy.message(.rollback, workRunning: false, serverVersion: nil).contains("Work is running now"), "rolling back with nothing running does not warn")
        check(SettingsConfirmCopy.message(.rollback, workRunning: false, serverVersion: "6.99.0").contains("server 6.99.0"), "rolling back names the server version")
        check(SettingsConfirmCopy.message(.repair, workRunning: true, serverVersion: nil).contains("leaves the server closed until you run Repair"), "repair while work runs says what a timeout leaves")
        check(SettingsConfirmCopy.message(.quit, workRunning: false, serverVersion: nil).contains("stops it and saves"), "quit during a Mac recording says it stops and saves")
        check(SettingsConfirmCopy.quitNeedsConfirm(macRecordingActive: true), "quit asks while a Mac recording runs")
        check(!SettingsConfirmCopy.quitNeedsConfirm(macRecordingActive: false), "quit does not ask when nothing is recording")
        check(SettingsConfirmCopy.shortenTitle(count: 1, days: 7) == "Delete 1 older dictation?", "one dictation is singular")
        check(SettingsConfirmCopy.shortenTitle(count: 212, days: 7) == "Delete 212 older dictations?", "the count is in the title")
        check(SettingsConfirmCopy.shortenMessage(count: 212, days: 7).contains("212 dictations older than that"), "the message says how many and for how long")
        check(SettingsConfirmCopy.shortenMessage(count: 1, days: 30).contains("1 dictation older"), "the message is singular for one")
        check(SettingsConfirmCopy.shortenAction(count: 212, days: 7) == "Delete 212 and keep 7 days", "the action names the count and the period")
        check(SettingsConfirmCopy.shortenMessage(count: 3, days: nil).contains("5,000") && SettingsConfirmCopy.shortenAction(count: 3, days: nil) == "Delete 3",
              "Forever can only delete through the 5,000 cap, and says so")
    }

    // ── Typing into a stepper.
    static func typedCount() {
        check(TypedCount.parse("18", low: 1, high: 50) == .value(18), "a count inside the range is accepted")
        check(TypedCount.parse(" 7 ", low: 1, high: 50) == .value(7), "spaces around a count are ignored")
        check(TypedCount.parse("1", low: 1, high: 50) == .value(1) && TypedCount.parse("50", low: 1, high: 50) == .value(50), "both ends of the range are accepted")
        check(TypedCount.parse("51", low: 1, high: 50) == .clamped(50, note: "The most is 50."), "above the server's most is held to the most, with a sentence")
        check(TypedCount.parse("0", low: 1, high: 50) == .clamped(1, note: "The least is 1."), "below the server's least is held to the least, with a sentence")
        check(TypedCount.parse("100", low: 1, high: 25).accepted == 25, "the bound is the one passed in, never a fixed one")
        check(TypedCount.parse("", low: 1, high: 50) == .invalid, "an empty field goes back")
        check(TypedCount.parse("abc", low: 1, high: 50) == .invalid, "words go back")
        check(TypedCount.parse("-5", low: 1, high: 50) == .invalid, "a minus sign goes back")
        check(TypedCount.parse("3.5", low: 1, high: 50) == .invalid, "a fraction goes back")
        check(TypedCount.parse("٣", low: 1, high: 50) == .invalid, "digits from another script go back")
        check(TypedCount.parse("99999999999999999999", low: 1, high: 50) == .invalid, "a number too large to read goes back")
    }

    // ── A menu that never shows a blank face.
    static func valueMenu() {
        let text: (Int) -> String = { "\($0) s" }
        let onList = ValueMenu.choices(stops: [20, 30, 45], current: 30, title: text)
        check(onList.map(\.value) == [20, 30, 45] && onList.map(\.title) == ["20 s", "30 s", "45 s"], "a saved value on the list adds nothing")
        let off = ValueMenu.choices(stops: [20, 30, 45], current: 37, title: text)
        check(off.map(\.value) == [20, 30, 37, 45], "a saved value off the list is added in order")
        check(off.first { $0.value == 37 }?.title == "37 s (your setting)", "the off-list value says it is the person's own")
        check(off.filter { $0.title.contains("your setting") }.count == 1, "only the off-list value is marked")
        check(ValueMenu.choices(stops: [], current: 5, title: text).map(\.value) == [5], "no stops still gives a face")
        check(ValueMenu.choices(stops: [1, 1, 2], current: 2, title: text).map(\.value) == [1, 2], "a repeated stop appears once")
        check(Set(ValueMenu.choices(stops: [20, 30], current: 900, title: text).map(\.value)).contains(900), "a value above every stop still has a choice")
    }

    // ── The daily cap. The amount rule is KeyLanes.parseCap (its own checks); a plain reader stands in for it here.
    static func dailyCap() {
        let parse: (String) -> Double? = { text in
            let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
            guard let value = Double(t), value >= 0.01, value <= 1000 else { return nil }
            return value
        }
        check(DailyCap.choices(saved: 5).map(\.title) == ["$1 a day", "$2 a day", "$5 a day", "$10 a day", "$25 a day", "$50 a day", "$100 a day", "Other amount"],
              "presets, then Other amount")
        let odd = DailyCap.choices(saved: 3.5)
        check(odd.map(\.title).contains("$3.50 a day (your cap)"), "a saved cap that is not a preset is its own line")
        check(odd.last?.id == DailyCap.other, "Other amount stays last")
        check(DailyCap.choices(saved: 7).filter { $0.id == DailyCap.current }.count == 1, "one saved-cap line")
        check(DailyCap.choices(saved: 10).filter { $0.id == DailyCap.current }.isEmpty, "a preset cap adds no saved-cap line")
        check(DailyCap.choices(saved: nil).filter { $0.id == DailyCap.current }.isEmpty, "no saved cap adds no saved-cap line")
        // The face is always one of the choices.
        for saved in [Optional(0.01), 1, 3.5, 5, 99.99, 1000, nil] {
            for draft in [nil, "", "5", "12", "abc", "3.50", "2000"] {
                for open in [false, true] {
                    let face = DailyCap.face(draft: draft, saved: saved, otherOpen: open, parse: parse)
                    check(DailyCap.choices(saved: saved).contains { $0.id == face }, "the face is a real choice (saved \(String(describing: saved)), draft \(String(describing: draft)), open \(open))")
                }
            }
        }
        check(DailyCap.face(draft: nil, saved: 25, otherOpen: false, parse: parse) == DailyCap.presetID(25), "a preset cap shows as that preset")
        check(DailyCap.face(draft: nil, saved: 3.5, otherOpen: false, parse: parse) == DailyCap.current, "an off-list cap shows as your cap")
        check(DailyCap.face(draft: "10", saved: 3.5, otherOpen: false, parse: parse) == DailyCap.presetID(10), "a picked preset shows as itself")
        check(DailyCap.face(draft: "12", saved: 3.5, otherOpen: false, parse: parse) == DailyCap.other, "a typed amount shows as Other amount")
        check(DailyCap.face(draft: nil, saved: 25, otherOpen: true, parse: parse) == DailyCap.other, "Other amount stays picked while it is open")
        check(DailyCap.amount(ofChoice: DailyCap.presetID(25)) == 25, "a preset id gives its amount")
        check(DailyCap.amount(ofChoice: DailyCap.other) == nil && DailyCap.amount(ofChoice: DailyCap.current) == nil, "Other amount and your cap give no preset amount")
        check(DailyCap.canSet(draft: "10", saved: 5, parse: parse), "Set cap is live for a different amount")
        check(!DailyCap.canSet(draft: "5", saved: 5, parse: parse), "Set cap is off for the saved amount")
        check(!DailyCap.canSet(draft: "x", saved: 5, parse: parse) && !DailyCap.canSet(draft: nil, saved: 5, parse: parse), "Set cap is off for an unreadable or empty amount")
        check(DailyCap.canSet(draft: "5", saved: nil, parse: parse), "Set cap is live when no cap is saved")
    }

    // ── The Versions line.
    static func versions() {
        check(VersionsLine.text(controller: "0.5.366", running: "6.99.0", installed: "6.99.0", selfManaged: false) == "Controller 0.5.366  •  Server 6.99.0", "a running server's version, with no claim about npm")
        check(!VersionsLine.text(controller: "0.5.366", running: "6.99.0", installed: nil, selfManaged: false).contains("npm"), "the line never says npm latest")
        check(VersionsLine.text(controller: "1", running: nil, installed: "6.98.0", selfManaged: false).hasSuffix("Server 6.98.0 (not running)"), "an installed server that is not running says so")
        check(VersionsLine.text(controller: "1", running: "", installed: "6.98.0", selfManaged: false).hasSuffix("(not running)"), "an empty running version is not running")
        check(VersionsLine.text(controller: "1", running: nil, installed: nil, selfManaged: true).hasSuffix("Server self-managed"), "a self-managed server")
        check(VersionsLine.text(controller: "1", running: nil, installed: nil, selfManaged: false).hasSuffix("Server not installed"), "no server")
    }

    // ── The microphone listener.
    @MainActor static func watcher() async {
        final class Box: @unchecked Sendable { var fire: (@Sendable () -> Void)?; var stops = 0; var starts = 0 }
        let box = Box()
        let fake: DeviceListWatcher.Register = { onChange in
            box.starts += 1; box.fire = onChange
            return ({ box.stops += 1 }, true)
        }
        let watcher = DeviceListWatcher(debounce: .zero, register: fake)
        var refreshes = 0
        check(!watcher.watching, "not watching before start")
        watcher.start { refreshes += 1 }
        check(watcher.watching && box.starts == 1, "start registers one listener")
        watcher.start { refreshes += 1 }
        check(box.starts == 1, "a second start does not register again")
        watcher.devicesChanged()
        try? await Task.sleep(for: .milliseconds(80))
        check(refreshes == 1, "a device change refreshes the list once")
        watcher.devicesChanged(); watcher.devicesChanged(); watcher.devicesChanged()
        try? await Task.sleep(for: .milliseconds(120))
        check(refreshes == 2, "several changes at once refresh once (\(refreshes))")
        box.fire?()
        try? await Task.sleep(for: .milliseconds(80))
        check(refreshes == 3, "the registered callback reaches the refresh")
        watcher.stop()
        check(!watcher.watching && box.stops == 1, "stop removes the listener")
        watcher.devicesChanged()
        try? await Task.sleep(for: .milliseconds(60))
        check(refreshes == 3, "a change after stop refreshes nothing")
        watcher.start { refreshes += 1 }
        check(box.starts == 2 && watcher.watching, "it can start again after a stop")
        watcher.stop()

        // The delayed refresh is cancelled by stop: nothing fires after the page is gone.
        let slow = DeviceListWatcher(debounce: .milliseconds(150), register: fake)
        var slowRefreshes = 0
        slow.start { slowRefreshes += 1 }
        slow.devicesChanged()
        slow.stop()
        try? await Task.sleep(for: .milliseconds(300))
        check(slowRefreshes == 0, "stop cancels a refresh that was waiting")

        // macOS refuses the listener: not available, the page keeps Check again.
        let refused = DeviceListWatcher(debounce: .zero, register: { _ in ({}, false) })
        refused.start { refreshes += 1 }
        check(!refused.available && !refused.watching, "a refused listener is reported and not watching")

        // The real CoreAudio listener registers on this Mac and removes cleanly.
        let real = DeviceListWatcher()
        real.start { }
        check(real.available == true && real.watching, "the CoreAudio device-list listener registers")
        real.stop()
        check(!real.watching, "and stops")
    }
}
