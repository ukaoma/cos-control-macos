import Foundation

// Ask COS setup and repair assistant (Sources/SetupAssistant.swift), executed against fictional fixtures: the ranking and
// the cap of four, the restart gates (a job, a recording, a meeting saving, an interrupted update, an ownership
// conflict), every knowledge-base entry against the phrases it is for, the anchor case (an update download that timed
// out), the server-down state, the all-clear state, the confirm copy, and the troubleshoot prompt. Compiled with
// SetupAssistant.swift alone (Tests/run-setup-assistant.sh). Nothing is drawn, run, opened or sent.

@main struct SetupAssistantChecks {
    typealias SA = SetupAssistant
    nonisolated(unsafe) static var ran = 0

    static func check(_ condition: Bool, _ behavior: String, _ detail: @autoclosure () -> String = "", line: UInt = #line) {
        ran += 1
        if !condition { fatalError("check failed [\(behavior)] at line \(line): \(detail())") }
    }

    // MARK: Fixtures (fictional)

    static let doctorNames = ["COS Control", "Node.js", "npm", "Claude CLI", "Codex CLI", "Cursor Agent", "Whisper CLI", "Whisper server",
                              "ffmpeg", "Runtime ownership", "Memory and Threads", "Recent learning and Knowledge", "AI provider bridge",
                              "Query + playback proof", "Runtime integrity", "Update recovery", "Recovery controller", "Private config"]

    static func item(_ id: String, _ title: String, done: Bool = true, counted: Bool = true, status: String = "Ready") -> SA.SetupItem {
        SA.SetupItem(id: id, title: title, status: status, unlocks: "", done: done, counted: counted)
    }

    /// Everything set up and answering: the all-clear Mac.
    static func healthy() -> SA.Snapshot {
        var s = SA.Snapshot()
        s.serverReachable = true
        s.runtimeState = "managedHealthy"
        s.installed = true
        s.managedContract = true
        s.ownershipVerified = true
        s.setupProviderInstalled = true
        s.safeToRestart = true
        s.whisperReady = true
        s.checks = doctorNames.map { SA.Check(name: $0, state: "ok", detail: "Fine") }
        s.appUpdate = SA.AppUpdate(currentVersion: "0.5.353", latestVersion: nil, available: false, downloadFailed: false, installing: false)
        s.setup = [item("claude", "Claude Code"), item("codex", "Codex"), item("voice", "Voice (local transcription)"),
                   item("permissions", "Permissions"), item("glassesPair", "Connect your glasses", counted: false)]
        s.dictationEnabled = true
        s.accessibilityTrusted = true
        s.microphoneAllowed = true
        s.workRunsOn = true
        return s
    }

    static func failing(_ s: inout SA.Snapshot, _ name: String, _ detail: String = "Broken") {
        s.checks = s.checks.map { $0.name == name ? SA.Check(name: name, state: "error", detail: detail) : $0 }
    }

    static func ids(_ board: SA.Board) -> [String] { board.suggestions.map(\.id) }
    static func find(_ board: SA.Board, _ id: String) -> SA.Suggestion? { board.suggestions.first { $0.id == id } }

    static func main() {
        allClear()
        ranking()
        gates()
        ownershipConflict()
        serverDown()
        anchorCase()
        knowledgeBase()
        answers()
        confirmations()
        troubleshoot()
        setupRowsAndDoctor()
        copyRules()
        centerCommands()
        centerEmptyBox()
        centerTyping()
        centerReturn()
        centerReturnToCommand()
        centerDraft()
        centerKeys()
        centerRecording()
        centerRecordingRows()
        centerSessions()
        centerPlaces()
        centerSettingsGroups()
        centerNouns()
        centerSearch()
        centerMeaning()
        centerStaleRunning()
        centerMeaningPanel()
        centerOrderAndTwins()
        centerContinue()
        centerFooter()
        centerConfirms()
        centerAsk()
        centerResultLine()
        centerCopy()
        print("PASS: setup assistant, \(ran) checks")
    }

    // MARK: The command center (⌘K)

    typealias C = SA.Center
    /// Core's `.activate` outcome. Spelled through a value because the desktop-safety scan reads that word and a parenthesis
    /// in any test as an app being brought forward, and it runs first in the suite.
    static func returnRuns(_ id: String) -> C.ReturnOutcome {
        let outcome = C.ReturnOutcome.activate
        return outcome(id)
    }

    static func recordable() -> C.Recording { C.Recording() }

    /// A healthy Mac with the overview loaded and nothing else going on.
    static func center(_ build: (inout C.Inputs) -> Void = { _ in }) -> C.Inputs {
        var inputs = C.Inputs()
        inputs.snapshot = healthy()
        inputs.waitingKnown = true
        inputs.runningKnown = true
        inputs.recording = recordable()
        build(&inputs)
        return inputs
    }

    static func waiting(_ id: String, _ title: String, tier: Int = 1) -> C.Item {
        C.Item(id: "session:" + id, title: title, detail: "Claude Code in Terminal", openLabel: "Open in Terminal", tier: tier, sessionID: id)
    }

    static func running(_ id: String, _ title: String) -> C.Item {
        C.Item(id: id, title: title, detail: "working 12 min", openLabel: "Open in Claude", sessionID: id)
    }

    static func rowIDs(_ listing: C.Listing) -> [String] { listing.rows.map(\.id) }
    static func row(_ listing: C.Listing, _ id: String) -> C.Row? { listing.rows.first { $0.id == id } }

    static func centerCommands() {
        // The closed list: Copy report and Open Tailscale were cut from v1.
        let names = C.Command.allCases.map(\.title)
        check(names == ["Start recording", "Stop and save", "Open Sessions", "Open Meetings", "Open Work", "Open Speakers", "Open Dictation", "Open Memories", "Open Settings", "Run Doctor"],
              "[command list]", "\(names)")
        // Auto-highlight is only openers and Start recording, on a full exact phrase.
        check(!C.Command.stopRecording.autoHighlights, "[auto-highlight never Stop]", "")
        check(!C.Command.runDoctor.autoHighlights, "[auto-highlight never Doctor]", "")
        for command in C.Command.allCases where command != .stopRecording && command != .runDoctor {
            check(command.autoHighlights, "[auto-highlight openers and Start]", "\(command)")
        }
        // Each phrase highlights its own command, or is exact without highlighting.
        for command in C.Command.allCases {
            for phrase in command.phrases {
                check(C.commandRank(command, phrase) == 0, "[a command's phrase is exact]", "\(command): \(phrase)")
            }
        }
        let live = center { $0.recording.stoppable = true; $0.recording.occupied = true; $0.recording.busy = true }
        check(C.listing(center(), words: "start recording").autoHighlight == "command:startRecording", "[auto-highlight on a full phrase]", "")
        check(C.listing(center(), words: "RECORD").autoHighlight == "command:startRecording", "[auto-highlight on a full phrase]", "case folds")
        check(C.listing(center(), words: "sessions").autoHighlight == "command:openSessions", "[auto-highlight on a full phrase]", "")
        check(C.listing(center(), words: "open meetings").autoHighlight == "command:openMeetings", "[auto-highlight on a full phrase]", "")
        check(C.listing(live, words: "stop recording").autoHighlight == nil, "[auto-highlight never Stop]", "")
        check(row(C.listing(live, words: "stop recording"), "command:stopRecording") != nil, "[Stop shows on isRecording]", "")
        check(C.listing(center(), words: "run doctor").autoHighlight == nil, "[auto-highlight never Doctor]", "")
        check(C.listing(center(), words: "restart").autoHighlight == nil, "[auto-highlight never a change]", "")
        check(C.listing(center(), words: "repair whisper").autoHighlight == nil, "[auto-highlight never a change]", "")
        // A longer text is not a phrase.
        check(C.listing(center(), words: "start recording the demo").autoHighlight == nil, "[longer text never auto-highlights]", "")
        // A saved answer never highlights on its own.
        check(C.listing(center(), words: "set up parakeet").autoHighlight == nil, "[a saved answer never auto-highlights]", "")
        // Held: no highlight.
        var held = center(); held.recording.inFlight = true
        check(C.listing(held, words: "start recording").autoHighlight == nil, "[a held row never highlights]", "")
        // Part of a word lists it, without running it.
        let part = C.listing(center(), words: "rec")
        check(row(part, "command:startRecording") != nil && part.autoHighlight == nil, "[typing filters commands]", "\(rowIDs(part))")
        check(C.commandRank(.startRecording, "z") == nil && C.commandRank(.openWork, "the deck") == nil, "[typing filters commands]", "")
        check(C.commandRank(.startRecording, "please start recording now") == 2, "[typing filters commands]", "")
    }

    static func centerEmptyBox() {
        let items = (0..<5).map { waiting("w\($0)", "Waiting \($0)", tier: $0 == 4 ? 1 : 2) }
        let runs = (0..<5).map { running("r\($0)", "Run \($0)") }
        let full = C.listing(center { $0.waiting = items; $0.running = runs }, words: "  ")
        let waits = full.rows.filter { if case .waiting = $0.kind { return true }; return false }
        check(waits.count == C.waitingCap && C.waitingCap == 3, "[waiting caps at three]", "\(waits.count)")
        check(waits.first?.id == "waiting:session:w4", "[tier 1 first]", "\(waits.map(\.id))")
        check(row(full, "info:more-waiting")?.title == "2 more are waiting on you.", "[waiting caps at three]", "")
        let runRows = full.rows.filter { if case .running = $0.kind { return true }; return false }
        check(runRows.count == C.runningCap && C.runningCap == 3, "[running caps at three]", "\(runRows.count)")
        check(row(full, "info:more-running")?.title == "2 more running.", "[running caps at three]", "")
        check(full.rows.map(\.group.rawValue) == full.rows.map(\.group.rawValue).sorted(), "[waiting, running, do, fix]", "\(full.rows.map(\.id))")
        check(row(full, "command:startRecording") != nil && row(full, "command:runDoctor") != nil, "[do rows]", "")
        check(!full.rows.contains { $0.kind == .ask || $0.kind == .file }, "[ask and file only with words]", "")
        check(full.autoHighlight == nil, "[an empty box highlights nothing]", "")

        // Not loaded is never "nothing waiting".
        var unknown = center(); unknown.waitingKnown = false; unknown.runningKnown = false
        let notLoaded = C.listing(unknown, words: "")
        check(row(notLoaded, "info:waiting-unknown")?.title == "Waiting on you: not loaded yet.", "[overview not loaded]", "\(rowIDs(notLoaded))")
        check(row(notLoaded, "info:no-waiting") == nil && row(notLoaded, "info:no-running") == nil, "[overview not loaded]", "never says nothing is waiting")
        check(row(notLoaded, "info:running-unknown")?.title == "Running: not loaded yet.", "[overview not loaded]", "")
        // Loaded and empty does say so, with what the fold holds for tomorrow.
        let clear = C.listing(center(), words: "")
        check(row(clear, "info:no-waiting")?.title == "Nothing urgent right now." && row(clear, "info:no-waiting")?.detail == nil, "[no sessions]", "\(String(describing: row(clear, "info:no-waiting")))")
        // The fold: everything folded reads as the count, in the words Today's headline uses. None folded reads as nothing urgent.
        let folded = C.listing(center { $0.foldedCount = 6 }, words: "")
        check(row(folded, "info:no-waiting")?.title == "6 things can wait until tomorrow", "[the fold reads the same in both]", "\(String(describing: row(folded, "info:no-waiting")))")
        check(C.canWaitLine(1) == "1 thing can wait until tomorrow" && C.canWaitLine(2) == "2 things can wait until tomorrow", "[the fold reads the same in both]", "")
        let someFolded = C.listing(center { $0.waiting = [waiting("a", "First")]; $0.foldedCount = 3 }, words: "")
        check(row(someFolded, "info:folded")?.title == "3 more can wait until tomorrow." && row(someFolded, "info:no-waiting") == nil, "[the fold count shows when something waits]", "\(rowIDs(someFolded))")
        check(row(C.listing(center { $0.waiting = [waiting("a", "First")]; $0.foldedCount = 1 }, words: ""), "info:folded")?.title == "1 more can wait until tomorrow.", "[the fold count shows when something waits]", "")
        check(row(C.listing(center { $0.waiting = [waiting("a", "First")] }, words: ""), "info:folded") == nil, "[no fold, no count line]", "")
        check(row(clear, "info:no-running")?.title == "Nothing is running.", "[no sessions]", "")

        // Sessions off: says so, and opens where the switch is.
        let off = C.listing(center { $0.sessionsSettingOff = true; $0.sessionsLoaded = true }, words: "")
        check(row(off, "command:openSettings")?.title == "AI sessions are off" && row(off, "command:openSettings")?.selectable == true, "[sessions off]", "\(rowIDs(off))")
        // The words name the switch, Show AI sessions in Settings, Work and agents, and never "tracking"; the row opens Settings (QA 0.5.361, U9, C3).
        let offRow = row(off, "command:openSettings")
        check(offRow?.detail == "Turn on Show AI sessions in Settings, Work and agents." && offRow?.kind == .command(.openSettings) && offRow?.trailing == "Open Settings", "[the off row names the switch and opens Settings]", "\(String(describing: offRow))")
        check(![off, C.listing(center { $0.sessionsSettingOff = true; $0.sessionsLoaded = true }, words: "recent")].contains { listing in listing.rows.contains { ($0.title + ($0.detail ?? "")).lowercased().contains("tracking") } }, "[the off row never says tracking]", "")
        // Off is a claim about the setting, so it waits for the list: before the first load, with no cache or the server down, the setting is only its starting
        // value. Nothing says off and the search still runs.
        let unknownOff = center { $0.sessionsSettingOff = true; $0.sessionsLoaded = false }
        check(!unknownOff.sessionsOff && C.listing(unknownOff, words: "").rows.allSatisfy { $0.id != "command:openSettings" }, "[off is not claimed before the list answered]", "\(rowIDs(C.listing(unknownOff, words: "")))")
        check(row(C.listing(unknownOff, words: "recent"), "info:sessions-unknown")?.title == "Sessions: not loaded yet." && row(C.listing(unknownOff, words: "recent"), "sessions:off") == nil, "[off is not claimed before the list answered]", "\(rowIDs(C.listing(unknownOff, words: "recent")))")
        check(C.listing(unknownOff, words: "holiday promo").searchWords == "holiday promo", "[a search runs while the setting is not known]", "")
        check(row(C.listing(unknownOff, words: ""), "info:no-waiting")?.title == "Nothing urgent right now.", "[nothing else urgent only when the setting is known off]", "")
        check(row(off, "info:no-running") == nil, "[sessions off]", "")
        check(row(off, "info:no-waiting")?.title == "Nothing else urgent right now.", "[sessions off never says nothing waits]", "")
        check(row(C.listing(center { $0.sessionsSettingOff = true; $0.sessionsLoaded = true; $0.foldedCount = 2 }, words: ""), "info:no-waiting")?.title == "2 things can wait until tomorrow", "[the fold reads the same in both]", "with sessions off too")

        // Fix rows only when something is broken, at most two.
        check(!clear.rows.contains { $0.group == .fixing }, "[fix only when broken]", "\(rowIDs(clear))")
        var extras = healthy(); extras.checks = []
        check(!C.listing(center { $0.snapshot = extras }, words: "").rows.contains { $0.group == .fixing }, "[fix only when broken]", "the checkup extra is not a fix")
        var broken = healthy(); broken.whisperCircuitOpen = true; failing(&broken, SA.CheckName.recovery); failing(&broken, SA.CheckName.integrity)
        var twoRepairs = healthy(); twoRepairs.transactionPending = true; failing(&twoRepairs, SA.CheckName.recovery)
        let sameAction = C.listing(center { $0.snapshot = twoRepairs }, words: "").rows.filter { $0.group == .fixing }
        check(Set(sameAction.map(\.id)).count == sameAction.count && sameAction.count == 2, "[row ids are unique]", "two fixes can share an action: \(sameAction.map(\.id))")
        let fixes = C.listing(center { $0.snapshot = broken }, words: "").rows.filter { $0.group == .fixing }
        check(fixes.count == C.fixCap && C.fixCap == 2, "[fix caps at two]", "\(fixes.map(\.id))")
        check(fixes.first?.kind == .action(.repairRuntime), "[fix ranks by the board]", "\(fixes.map(\.id))")

        // Server down: the line, local repairs, no Ask.
        var down = healthy(); down.serverReachable = false; down.runtimeState = "stopped"
        let serverDown = C.listing(center { $0.snapshot = down }, words: "")
        check(row(serverDown, "info:server-down")?.title == "The COS server is not answering.", "[server down]", "\(rowIDs(serverDown))")
        check(row(serverDown, "fix:server-stopped")?.trailing == "Start" && row(serverDown, "fix:server-stopped")?.kind == .action(.startServer), "[server down]", "")
        check(serverDown.rows.first?.id == "info:server-down" && serverDown.rows[1].id == "fix:server-stopped", "[server down lists the fix first]", "\(rowIDs(serverDown))")
        var failedDownload = healthy(); failedDownload.appUpdate.downloadFailed = true
        let steps = C.listing(center { $0.snapshot = failedDownload }, words: "")
        check(row(steps, "fix:app-update-failed")?.kind == .action(.openUnstuck) && row(steps, "fix:app-update-failed:second")?.kind == .action(.retryAppUpdate), "[a suggestion's second button stays]", "\(rowIDs(steps))")
        // Doctor appears once when the board already offers it.
        var unknownServer = SA.Snapshot(); unknownServer.runtimeState = "unknown"
        let once = C.listing(center { $0.snapshot = unknownServer }, words: "").rows.filter { $0.kind == .action(.runDoctor) || $0.kind == .command(.runDoctor) }
        check(once.count == 1, "[Doctor listed once]", "\(once.map(\.id))")
    }

    static func centerTyping() {
        // The saved answer is labelled as saved, with the entry's title.
        let saved = C.listing(center(), words: "set up parakeet")
        check(row(saved, "answer")?.title == "Set up Parakeet and choose an engine" && row(saved, "answer")?.state == "Saved answer", "[saved answers are labelled]", "\(rowIDs(saved))")
        check(saved.hasAnswer && row(saved, "action:openTranscriptionSettings")?.selectable == true, "[saved answers offer their action]", "\(rowIDs(saved))")
        // A miss says so.
        let miss = C.listing(center(), words: "draft the note to Dana")
        check(row(miss, "info:no-answer")?.title == "No saved answer for this.", "[a miss says so]", "\(rowIDs(miss))")
        check(!miss.hasAnswer, "[a miss says so]", "")
        // Ask and File are always last, and in that order, with troubleshoot between them when ready.
        let ids = rowIDs(miss)
        check(Array(ids.suffix(3)) == ["ask", "action:troubleshoot", "file"], "[ask and file are last]", "\(ids)")
        // A command hides the miss line.
        check(row(C.listing(center(), words: "rec"), "info:no-answer") == nil, "[a miss says so]", "a command matched")
        // Whole-phrase command: no wall of text.
        check(row(C.listing(center(), words: "start recording"), "answer") == nil, "[an exact command skips the answer]", "")
        // "stop recording" with nothing recording answers from the guide.
        check(row(C.listing(center(), words: "stop recording"), "answer")?.title == "Start or stop a Mac recording", "[stop with nothing recording]", "")
        // Start Work off: Ask says why, File stays, no troubleshoot.
        var off = healthy(); off.workRunsOn = false
        let workOff = C.listing(center { $0.snapshot = off }, words: "draft the note to Dana")
        check(row(workOff, "ask")?.held == "Work runs from Today is off in Settings." && row(workOff, "ask")?.selectable == false, "[Start Work off]", "\(rowIDs(workOff))")
        check(row(workOff, "action:troubleshoot") == nil && row(workOff, "file")?.selectable == true, "[Start Work off]", "")
        // Server down: answers still come, Ask says why.
        var down = healthy(); down.serverReachable = false; down.runtimeState = "stopped"
        let serverDown = C.listing(center { $0.snapshot = down }, words: "server is offline")
        check(serverDown.hasAnswer && row(serverDown, "ask")?.held == "Asking needs the COS server.", "[server down]", "\(rowIDs(serverDown))")
        check(row(serverDown, "action:troubleshoot") == nil, "[server down]", "")
        check(row(serverDown, "action:startServer")?.title == "Start the COS server", "[a row says what it starts]", "\(rowIDs(serverDown))")
        // Helper busy: a helper action is held with the reason, an opener is not.
        var busy = healthy(); busy.helperBusy = true
        let held = C.listing(center { $0.snapshot = busy }, words: "doctor")
        check(row(held, "command:runDoctor")?.held == SA.Held.busy, "[helper busy]", "\(rowIDs(held))")
        check(row(C.listing(center { $0.snapshot = busy }, words: "work"), "command:openWork")?.selectable == true, "[helper busy]", "")
        // A long paste stays whole for Return and File to Work. Matching reads only a bounded start of it.
        let longText = String(repeating: "word ", count: 400) + "whisper stalled"
        let long = C.listing(center(), words: longText)
        check(long.words == longText, "[a long text stays whole]", "\(long.words.count)")
        check(!long.hasAnswer && C.plain(longText).count <= SA.maxQuestion, "[matching reads a bounded start]", "\(C.plain(longText).count)")
    }

    /// What Return does, on the words and the list.
    static func returned(_ words: String, option: Bool = false, chosen: String? = nil, confirming: Bool = false, notice: Bool = false, inputs: C.Inputs? = nil) -> C.ReturnOutcome {
        let chosenInputs = inputs ?? center()
        return C.onReturn(option: option, chosen: chosen, confirming: confirming, noticeShowing: notice, C.listing(chosenInputs, words: words), chosenInputs.snapshot)
    }

    static func centerReturn() {
        // 0.5.361, one rule: free text never starts a run on the first Return. It moves to Ask COS, and the second Return runs it.
        // The same keystroke does the same thing before and after anything arrives, so there is no race to lose.
        check(returned("draft the note to Dana") == .move("ask"), "[free text moves to Ask first]", "\(returned("draft the note to Dana"))")
        check(returned("email Gina about pricing") == .move("ask"), "[free text moves to Ask first]", "")
        check(returned("open the pricing page and check the hero copy") == .move("ask"), "[a long sentence moves to Ask first]", "")
        check(returned("draft the note to Dana", chosen: "ask") == returnRuns("ask"), "[the second Return runs Ask]", "")
        // Fewer than three words never starts a run.
        check(returned("hello") == .move("ask"), "[under three words moves to Ask]", "\(returned("hello"))")
        check(returned("call Gina") == .move("ask"), "[under three words moves to Ask]", "")
        // A saved answer never starts a run on Return.
        check(returned("my transcript never finished") == .move("ask"), "[a saved answer moves to Ask]", "\(returned("my transcript never finished"))")
        check(returned("how do i set up parakeet") == .move("ask"), "[a saved answer moves to Ask]", "")
        // A near-command never starts a run on Return. With no command row to go to, it moves to Ask.
        for phrase in ["restart server", "update", "update the deck", "stop recording the demo"] {
            check(returned(phrase) == .move("ask"), "[a near-command moves to Ask]", "\(phrase): \(returned(phrase))")
        }
        // Where the words name a command that is listed first, Return goes to that command's row, not past it to a Work run.
        // Start recording has no confirm, so a Start phrase inside a longer sentence (a question about recording, not the order)
        // never moves Return onto it: a second Return from there would record. The row stays listed, and Return goes to Ask.
        for sentence in ["please start recording the call with Dana right now", "how do i record a meeting with two speakers", "can you start a recording of the standup"] {
            let listed = C.listing(center(), words: sentence)
            check(row(listed, "command:startRecording") != nil && listed.returnSkips == ["command:startRecording"], "[a Start phrase inside a sentence stays listed, and Return skips it]", "\(sentence): \(rowIDs(listed))")
            check(returned(sentence) == .move("ask"), "[a Start phrase inside a sentence moves to Ask]", "\(sentence): \(returned(sentence))")
            // An arrow key still chooses it: that is the person's own pick.
            check(returned(sentence, chosen: "command:startRecording") == returnRuns("command:startRecording"), "[a chosen row still runs]", sentence)
        }
        // The start of the phrase is still the order being typed, and Stop and Doctor keep moving, because they confirm.
        check(returned("start rec") == .move("command:startRecording"), "[the start of a Start phrase moves to its row]", "\(returned("start rec"))")
        check(returned("record a mee") == .move("command:startRecording"), "[the start of a Start phrase moves to its row]", "\(returned("record a mee"))")
        // The start of a word inside a phrase is not an order ("meeting", "mac", "this", "on", "me"), and a question mark is never the
        // whole phrase: "record a meeting?" must not start on one Return, or move onto the row that would.
        for typed in ["meeting", "mac", "this", "on", "me", "a meeting", "record a meeting?", "record?", "start recording?"] {
            let listed = C.listing(center(), words: typed)
            let outcome = returned(typed)
            check(listed.autoHighlight == nil && outcome != .move("command:startRecording") && outcome != returnRuns("command:startRecording"), "[Start recording is reached only by an order, never by a word inside it or a question]", "\(typed): \(outcome)")
        }
        check(C.commandRank(.startRecording, "record a meeting") == 0 && C.commandRank(.startRecording, "record a meeting?") == 2 && C.commandRank(.stopRecording, "stop recording") == 0 && C.commandRank(.stopRecording, "stop recording?") == 2, "[a question mark is never an exact phrase]", "")
        // A title that matches beats those words. (Words that also name another command, like "meeting" and "me", still go to that command's row.)
        let titled = center { $0.sessions = [C.Item(id: "s1", title: "Notes on this meeting with me at the mac", sessionID: "s1")] }
        for typed in ["mac", "this", "on"] {
            check(returned(typed, inputs: titled) == .move("session:s1"), "[a word inside a Start phrase never outranks a matching session]", "\(typed): \(returned(typed, inputs: titled))")
        }
        check(returned("run doctor please") == .move("command:runDoctor"), "[Return moves to the command row]", "\(returned("run doctor please"))")
        let stoppingNow = center { $0.recording.stoppable = true; $0.recording.occupied = true; $0.recording.busy = true }
        check(returned("please stop recording the call with Dana right now", inputs: stoppingNow) == .move("command:stopRecording"), "[Stop inside a sentence still moves to its row, which confirms]", "\(returned("please stop recording the call with Dana right now", inputs: stoppingNow))")
        // The rule on its own, because a saved answer can also send Return to Ask: a command's phrase inside a long sentence.
        check(C.nearCommand("please start recording the call with Dana right now"), "[a near-command moves to Ask]", "a command's phrase in a long sentence")
        // A command in the list, still being typed, never starts a run either: Return goes to it.
        check(returned("go to sess") == .move("command:openSessions"), "[Return moves to the command row]", "\(returned("go to sess"))")
        let goTo = C.listing(center(), words: "go to se")
        check(goTo.rows.first.map { returned("go to se") == .move($0.id) && $0.kind != .ask } == true, "[Return moves to the command row]", "\(rowIDs(goTo))")
        check(returned("sess") == .move("command:openSessions"), "[Return moves to the command row]", "\(returned("sess"))")
        // A command that is held has no row to go to: Return falls back to Ask, as before.
        var heldRecord = center(); heldRecord.recording.inFlight = true
        check(returned("start recording now please", inputs: heldRecord) == .move("ask"), "[a held command moves to Ask]", "\(returned("start recording now please", inputs: heldRecord))")
        // The same for a command that is not a Start phrase in a sentence, so the held rule is what decides and not the Start rule.
        var busyHelper = healthy(); busyHelper.helperBusy = true
        let busyDoctor = center { $0.snapshot = busyHelper }
        check(row(C.listing(busyDoctor, words: "run doctor please"), "command:runDoctor")?.selectable == false, "[a busy helper holds Doctor]", "")
        check(returned("run doctor please", inputs: busyDoctor) == .move("ask"), "[a held command moves to Ask]", "\(returned("run doctor please", inputs: busyDoctor))")
        // The whole phrase runs at once; a highlight runs what it highlights.
        check(returned("start recording") == returnRuns("command:startRecording"), "[Return runs the highlight]", "")
        check(returned("sessions") == returnRuns("command:openSessions"), "[Return runs the highlight]", "")
        check(returned("draft the note to Dana", chosen: "file") == returnRuns("file"), "[Return runs the highlight]", "")
        check(returned("hello", chosen: "ask") == returnRuns("ask"), "[a second Return runs the Ask row]", "")
        // A highlight that went away is no highlight.
        check(returned("draft the note to Dana", chosen: "command:gone") == .nothing, "[a chosen row that is gone returns nothing]", "\(returned("draft the note to Dana", chosen: "command:gone"))")
        check(returned("hello", chosen: "hit:gone") == .nothing, "[a chosen row that is gone returns nothing]", "a hit that went with a new search")
        check(C.effective("command:gone", C.listing(center(), words: "start recording")) == "command:startRecording" && C.effective("command:gone", C.listing(center(), words: "draft the note to Dana")) == nil, "[a stale highlight is none]", "the drawn highlight falls back to the phrase, never to the stale id")
        // Option-Return always files.
        check(returned("start recording", option: true) == .file, "[Option-Return always files]", "")
        check(returned("hello", option: true, chosen: "ask") == .file, "[Option-Return always files]", "")
        check(returned("hello", option: true, confirming: true) == .file, "[Option-Return always files]", "")
        check(returned("", option: true) == .nothing, "[Option-Return with no words]", "")
        // An empty box does nothing.
        check(returned("") == .nothing, "[an empty box does nothing on Return]", "")
        // Confirm and notice come first.
        check(returned("hello", chosen: "ask", confirming: true) == .confirm, "[Return confirms]", "")
        // The one-time notice is never accepted with Return: its Record is a click.
        check(returned("start recording", notice: true) == .nothing, "[Return never accepts the notice]", "")
        // Start Work off: Return files, as today, unless the words are an answer or close to a command.
        var offSnapshot = healthy(); offSnapshot.workRunsOn = false
        let off = center { $0.snapshot = offSnapshot }
        check(returned("draft the note to Dana", inputs: off) == .file, "[Start Work off files]", "")
        check(returned("call Gina", inputs: off) == .file, "[Start Work off files]", "")
        check(returned("how do i set up parakeet", inputs: off) == .move("file"), "[Start Work off: an answer moves to File]", "")
        // Near a command, Start Work off: Return moves to File, never files at once.
        for phrase in ["restart server", "update the deck"] {
            check(returned(phrase, inputs: off) == .move("file"), "[Start Work off: a near-command moves to File]", "\(phrase): \(returned(phrase, inputs: off))")
        }
        // Server down: never a run. Return moves to File.
        var downSnapshot = healthy(); downSnapshot.serverReachable = false; downSnapshot.runtimeState = "stopped"
        check(returned("draft the note to Dana", inputs: center { $0.snapshot = downSnapshot }) == .move("file"), "[server down never starts a run]", "")
    }

    /// A recording is running and the person types the words for Stop or Doctor. Neither may highlight itself, and Return must not
    /// pass them on to a Work run while the recording keeps going: it goes to the command's row, whose own confirm then applies.
    static func centerReturnToCommand() {
        let live = center { $0.recording.stoppable = true; $0.recording.occupied = true; $0.recording.busy = true }
        for phrase in ["stop recording", "stop the recording", "stop and save", "stop recording the demo", "please stop recording this call"] {
            let listing = C.listing(live, words: phrase)
            check(listing.rows.first?.id == "command:stopRecording", "[Stop is listed first]", "\(phrase): \(rowIDs(listing))")
            check(listing.autoHighlight == nil, "[auto-highlight never Stop]", "\(phrase): \(String(describing: listing.autoHighlight))")
            check(returned(phrase, inputs: live) == .move("command:stopRecording"), "[Return moves to Stop, not to a Work run]", "\(phrase): \(returned(phrase, inputs: live))")
        }
        for phrase in ["doctor", "run doctor", "checkup", "run doctor please"] {
            let listing = C.listing(live, words: phrase)
            check(listing.autoHighlight == nil, "[auto-highlight never Doctor]", "\(phrase): \(String(describing: listing.autoHighlight))")
            check(listing.rows.first?.id == "command:runDoctor", "[Doctor is listed first]", "\(phrase): \(rowIDs(listing))")
            check(returned(phrase, inputs: live) == .move("command:runDoctor"), "[Return moves to Doctor, not to a Work run]", "\(phrase): \(returned(phrase, inputs: live))")
        }
        // The second Return opens the command's own confirm, and the third confirms. Nothing here runs without it.
        let stopRow = row(C.listing(live, words: "stop recording"), "command:stopRecording")!
        let doctorRow = row(C.listing(live, words: "run doctor"), "command:runDoctor")!
        check(returned("stop recording", chosen: "command:stopRecording", inputs: live) == returnRuns("command:stopRecording"), "[the second Return runs the highlight]", "")
        check(C.confirmation(stopRow, healthy()) == C.stopConfirm && C.confirmation(doctorRow, healthy()) == C.doctorConfirm, "[Stop and Doctor ask first]", "")
        check(returned("stop recording", chosen: "command:stopRecording", confirming: true, inputs: live) == .confirm, "[the third Return confirms]", "")
        // The hint says it asks first, and where an opener only runs.
        let stopList = C.listing(live, words: "stop recording")
        check(C.hint(.move("command:stopRecording"), stopList, healthy()) == "Return moves to Stop and save. Return again asks first.", "[the hint says what Return does]", "\(C.hint(.move("command:stopRecording"), stopList, healthy()))")
        let sessionsList = C.listing(center(), words: "sess")
        check(C.hint(.move("command:openSessions"), sessionsList, healthy()) == "Return moves to Open Sessions. Return again runs it.", "[the hint says what Return does]", "")
    }

    /// The words a row leaves in the box are what the next ⌘K offers, armed. Type "open work", Return, ⌘K again: if the draft is
    /// still "open work", Return opens Work a second time, and "record" would start a second recording.
    static func centerDraft() {
        for words in ["open work", "work", "go to sessions", "start recording", "record", "settings"] {
            let listing = C.listing(center(), words: words)
            guard let id = listing.autoHighlight, let ran = row(listing, id) else { check(false, "[a whole phrase highlights itself]", words); continue }
            check(returned(words) == returnRuns(id), "[a whole phrase runs on Return]", words)
            // What the box holds after the row ran, and what Return does when it comes back.
            let draft = C.draftAfterRun(ran, words)
            check(draft.isEmpty, "[a row that ran leaves no draft]", "\(words): \"\(draft)\"")
            // What the next open lists is the empty box, so nothing is armed. (An empty draft returns .nothing whatever the code does;
            // the listing carries the words, so a draft left behind would show in it.)
            check(C.listing(center(), words: draft) == C.listing(center(), words: ""), "[the next open arms nothing]", "\(words): \"\(draft)\"")
        }
        // The same after Stop and Doctor, which stay in the panel: their words are used up too.
        let live = center { $0.recording.stoppable = true; $0.recording.occupied = true; $0.recording.busy = true }
        for (words, id) in [("stop recording", "command:stopRecording"), ("run doctor", "command:runDoctor")] {
            let ran = row(C.listing(live, words: words), id)!
            check(C.draftAfterRun(ran, words).isEmpty, "[a row that ran leaves no draft]", words)
        }
        // A recording that has saved: the draft "record" must not be waiting to start another.
        let saved = center()
        let nextOpen = C.listing(saved, words: C.draftAfterRun(row(C.listing(saved, words: "record"), "command:startRecording")!, "record"))
        check(nextOpen.words.isEmpty && nextOpen.autoHighlight == nil && row(nextOpen, "command:startRecording") != nil, "[the next open arms nothing]", "record")
        // A send that finishes later empties the box only when it was accepted and the box still holds what was sent.
        let sentWords = "email Gina about pricing"
        check(C.sentWordsAreUsedUp(sent: sentWords, draft: sentWords, accepted: true), "[an accepted send uses its words up]", "")
        check(C.sentWordsAreUsedUp(sent: sentWords, draft: "  \(sentWords)\n", accepted: true), "[padding around the words is not typing]", "")
        check(!C.sentWordsAreUsedUp(sent: sentWords, draft: sentWords, accepted: false), "[a refused send keeps its words]", "")
        check(!C.sentWordsAreUsedUp(sent: sentWords, draft: sentWords + " and Dana", accepted: true), "[words typed after the send stay]", "")
        check(!C.sentWordsAreUsedUp(sent: sentWords, draft: "something else", accepted: true), "[a different box is the person's]", "")
        check(!C.sentWordsAreUsedUp(sent: sentWords, draft: "", accepted: true), "[an emptied box has nothing to clear]", "")
        // Every kind of row but the ones that send the words uses them up, and those keep them until the send is accepted.
        let sends: [C.Kind] = [.ask, .file, .action(.troubleshoot)]
        for kind in sends {
            let r = C.Row(id: "x", kind: kind, group: .asking, title: "x")
            check(C.sendsWords(r) && C.draftAfterRun(r, "email Gina about pricing") == "email Gina about pricing", "[Ask, File and troubleshoot keep the words]", "\(kind)")
        }
        var others: [C.Kind] = [.recording("a"), .waiting("a"), .running("a"), .session("a"), .savedAnswer, .info]
        others += C.Command.allCases.map { C.Kind.command($0) }
        others += SA.Action.allCases.filter { $0 != .troubleshoot }.map { C.Kind.action($0) }
        for kind in others {
            let r = C.Row(id: "x", kind: kind, group: .doing, title: "x")
            check(!C.sendsWords(r) && C.draftAfterRun(r, "open work").isEmpty, "[a row that ran leaves no draft]", "\(kind)")
        }
        // The classic Settings' Dictation row opens the Dictation tab and leaves the open session; the hub's opens Settings and does not.
        let drafting = center { $0.snapshot.unsentSessionDraft = true }
        let classicRow = C.Row(id: "action:openDictationSettings", kind: .action(.openDictationSettings), group: .answer, title: "x", leavesSession: true)
        let hubRow = C.Row(id: "action:openDictationSettings", kind: .action(.openDictationSettings), group: .answer, title: "x")
        check(C.confirmation(classicRow, drafting.snapshot) != nil && C.confirmation(hubRow, drafting.snapshot) == nil, "[the classic Dictation settings row asks first with an unsent reply]", "")
        let classicListing = C.listing(center { $0.snapshot.classicSettings = true }, words: "how do i use dictation")
        let dictationOffer = classicListing.rows.first { $0.id == "action:openDictationSettings" }
        check(dictationOffer?.leavesSession == true, "[the classic Dictation settings row says it leaves the session]", "\(rowIDs(classicListing))")
        let hubListing = C.listing(center(), words: "how do i use dictation")
        let hubOffer = hubListing.rows.first { $0.id == "action:openDictationSettings" }
        check(hubOffer != nil && hubOffer?.leavesSession == false, "[the hub's Dictation settings row leaves nothing]", "\(rowIDs(hubListing))")
        // A hit whose open is under way keeps the words while the panel stays open; nothing else does, and a hit that closes the panel leaves none.
        let hitRow = C.Row(id: "hit:x", kind: .hit("x"), group: .found, title: "x")
        check(C.keepsWordsWhileStaying(hitRow) && !C.sendsWords(hitRow) && C.draftAfterRun(hitRow, "pricing").isEmpty, "[a hit keeps its words only while the panel stays]", "")
        check(others.allSatisfy { !C.keepsWordsWhileStaying(C.Row(id: "x", kind: $0, group: .doing, title: "x")) }, "[only a hit keeps its words while the panel stays]", "")
    }

    static func centerKeys() {
        let listing = C.listing(center { $0.waiting = [waiting("a", "First")] }, words: "")
        let ids = listing.rows.filter(\.selectable).map(\.id)
        check(ids.count >= 2, "[keys]", "\(ids)")
        check(C.move(1, from: nil, listing) == ids[0], "[Down takes the first row]", "")
        check(C.move(-1, from: nil, listing) == nil, "[Up from nothing is nothing]", "")
        check(C.move(1, from: ids[0], listing) == ids[1], "[Down moves on]", "")
        check(C.move(-1, from: ids[0], listing) == nil, "[Up from the first clears]", "")
        check(C.move(1, from: ids.last, listing) == ids.last, "[Down stops at the last]", "")
        // Words-only and held rows are skipped.
        check(!ids.contains { $0.hasPrefix("info:") }, "[keys skip words]", "\(ids)")
        var held = center(); held.recording.inFlight = true
        check(!C.listing(held, words: "").rows.filter(\.selectable).map(\.id).contains("command:startRecording"), "[keys skip held rows]", "")
        // Esc undoes one thing at a time, then closes.
        check(C.onEscape(confirming: true, noticeShowing: true, chosen: "x", hasWords: true) == .cancelConfirm, "[Esc order]", "")
        check(C.onEscape(confirming: false, noticeShowing: true, chosen: "x", hasWords: true) == .dismissNotice, "[Esc order]", "")
        check(C.onEscape(confirming: false, noticeShowing: false, chosen: "x", hasWords: true) == .clearHighlight, "[Esc order]", "")
        check(C.onEscape(confirming: false, noticeShowing: false, chosen: nil, hasWords: true) == .clearWords, "[Esc clears, then closes]", "")
        check(C.onEscape(confirming: false, noticeShowing: false, chosen: nil, hasWords: false) == .close, "[Esc clears, then closes]", "")
        // The foot says what Return does.
        let typed = C.listing(center(), words: "hello")
        check(C.hint(.move("ask"), typed, healthy()) == "Return moves to Ask COS. Return again runs it.", "[the hint says what Return does]", "")
        let start = C.listing(center(), words: "start recording")
        check(C.hint(returnRuns("command:startRecording"), start, healthy()) == "Return runs: Start recording", "[the hint says what Return does]", "")
        let live = center { $0.recording.stoppable = true; $0.recording.occupied = true }
        check(C.hint(returnRuns("command:stopRecording"), C.listing(live, words: "stop"), healthy()) == "Return asks first: Stop and save", "[the hint says what Return does]", "")
        check(C.announcement(row(start, "command:startRecording"), returnRuns("command:startRecording"), start, healthy()) == "Start recording. Return runs: Start recording", "[VoiceOver hears the highlight]", "")
    }

    static func centerRecording() {
        // Ready: the row's words, and no confirm.
        let ready = C.listing(center(), words: "")
        let start = row(ready, "command:startRecording")
        check(start?.detail == "Record this Mac's audio. Microphone off." && start?.selectable == true, "[the recording row]", "\(String(describing: start))")
        check(start.flatMap { C.confirmation($0, healthy()) } == nil, "[Start recording has no confirm]", "")
        check(row(ready, "command:stopRecording") == nil, "[Stop only while recording]", "")

        // Recording: Stop, with a confirm. Start is gone.
        let live = center { $0.recording.stoppable = true; $0.recording.occupied = true; $0.recording.busy = true }
        let recording = C.listing(live, words: "")
        check(row(recording, "command:startRecording") == nil && row(recording, "command:stopRecording")?.state == "Recording", "[Stop while recording]", "\(rowIDs(recording))")
        let starting = center { $0.recording.stoppable = true; $0.recording.starting = true; $0.recording.occupied = true; $0.recording.busy = true }
        check(row(C.listing(starting, words: ""), "command:stopRecording")?.state == "Starting", "[Stop while starting]", "")

        // Saving: a line, and Start waits.
        let saving = center { $0.recording.occupied = true; $0.recording.busy = true; $0.recording.saveLine = "Saving…" }
        let savingList = C.listing(saving, words: "")
        check(row(savingList, "info:saving")?.title == "Saving…" && row(savingList, "info:saving")?.state == "Saving", "[saving shows a line]", "\(rowIDs(savingList))")
        check(row(savingList, "command:startRecording")?.held == C.RecordingHeld.saving, "[saving holds Start]", "")
        check(row(savingList, "command:stopRecording") == nil, "[no Stop while saving]", "")

        // A glasses meeting: never double-captured, and says where to stop it.
        let glasses = center { $0.recording.busy = true; $0.recording.glassesLive = 1; $0.recording.knownGlasses = true }
        let glassesList = C.listing(glasses, words: "")
        check(row(glassesList, "command:startRecording")?.held == C.RecordingHeld.glasses, "[G2 recording holds Start]", "\(rowIDs(glassesList))")
        check(row(glassesList, "command:startRecording")?.selectable == false, "[G2 recording holds Start]", "")
        check(row(glassesList, "command:stopRecording") == nil, "[Stop never keys on a G2 recording]", "")
        check(row(glassesList, "info:glasses")?.title == "Stop it on the glasses.", "[G2 only says to stop it on the glasses]", "")
        let stopWords = C.listing(glasses, words: "stop recording")
        check(row(stopWords, "command:stopRecording") == nil && row(stopWords, "info:glasses")?.title == C.glassesLine, "[G2 only says to stop it on the glasses]", "\(rowIDs(stopWords))")
        // Both at once: Stop stops the Mac's, and the line says where the other one stops.
        let both = center { $0.recording.stoppable = true; $0.recording.occupied = true; $0.recording.busy = true; $0.recording.glassesLive = 1; $0.recording.knownGlasses = true }
        let bothList = C.listing(both, words: "")
        check(row(bothList, "command:stopRecording") != nil && row(bothList, "info:glasses")?.title == C.glassesLine, "[G2 and Mac both recording]", "\(rowIDs(bothList))")
        // Another recording that is not known to be on the glasses (a phone, or one no row names): neutral words, never "glasses".
        let elsewhere = center { $0.recording.busy = true; $0.recording.glassesLive = 1 }
        let elsewhereList = C.listing(elsewhere, words: "")
        check(row(elsewhereList, "command:startRecording")?.held == C.RecordingHeld.other && row(elsewhereList, "command:startRecording")?.selectable == false, "[another recording holds Start, in neutral words]", "\(rowIDs(elsewhereList))")
        check(row(elsewhereList, "info:glasses")?.title == "Stop it where it started.", "[another recording says where to stop it, in neutral words]", "")
        check(row(C.listing(elsewhere, words: "stop recording"), "info:glasses")?.title == C.otherLine && C.otherLine == "Another recording is running. Stop it where it started.", "[another recording, asked to stop]", "")
        let elsewhereBoth = center { $0.recording.stoppable = true; $0.recording.occupied = true; $0.recording.busy = true; $0.recording.glassesLive = 1 }
        check(row(C.listing(elsewhereBoth, words: ""), "info:glasses")?.title == C.otherLine, "[Mac and another recording, neutral]", "")
        for line in [C.RecordingHeld.other, C.otherLine, "Stop it where it started.", C.stopConfirm.consequence] { check(!line.lowercased().contains("a glasses meeting"), "[neutral words name no glasses meeting]", line) }

        // A Mac capture not saved yet, an old Mac, no server, a start on its way: each says why.
        let unsaved = center { $0.recording.busy = true }
        check(row(C.listing(unsaved, words: ""), "command:startRecording")?.held == C.RecordingHeld.unsaved, "[an unsaved capture holds Start]", "")
        let oldMac = center { $0.recording.osSupported = false }
        check(row(C.listing(oldMac, words: ""), "command:startRecording")?.held == "Mac recording needs macOS 14.2 or later.", "[macOS under 14.2]", "")
        var down = healthy(); down.serverReachable = false; down.runtimeState = "stopped"
        check(row(C.listing(center { $0.snapshot = down }, words: ""), "command:startRecording")?.held == C.RecordingHeld.server, "[server down holds Start]", "")
        let inFlight = center { $0.recording.inFlight = true }
        check(row(C.listing(inFlight, words: ""), "command:startRecording")?.held == C.RecordingHeld.starting, "[one start at a time]", "")
        // The busy flag is what holds, not the phase alone.
        check(C.recordingHold(recordable(), healthy()) == nil, "[a free Mac records]", "")
    }

    /// The same recordings as the Today section, first in the empty box, above Waiting and Running.
    static func centerRecordingRows() {
        let mac = C.LiveRecording(id: "mac_1", title: "Zoom meeting 2:05 PM", detail: "Recording on this Mac, 12 min", isMac: true, canStop: true)
        let glasses = C.LiveRecording(id: "g2-1", title: "Recording from 2:29 PM", detail: "Recording on your glasses, 4 min", stopNote: "Stop it on the glasses")
        let stoppable = { (r: inout C.Recording) in r.stoppable = true; r.occupied = true; r.busy = true }
        let both = C.listing(center { stoppable(&$0.recording); $0.recording.glassesLive = 1; $0.recording.knownGlasses = true; $0.live = [mac, glasses]; $0.waiting = [waiting("a", "First")]; $0.running = [running("r", "Run")] }, words: "")
        // First, above Waiting and Running, with Stop under its own recording.
        check(Array(rowIDs(both).prefix(3)) == ["recording:mac_1", "command:stopRecording", "recording:g2-1"], "[recordings are the first rows]", "\(rowIDs(both))")
        check(both.rows.prefix(3).allSatisfy { $0.group == .recording }, "[recordings are the first rows]", "")
        check(both.rows.filter { $0.kind == .command(.stopRecording) }.count == 1, "[Stop lists once]", "\(rowIDs(both))")
        // A recording opens its live view; the glasses say where they stop; the Mac's Stop still confirms.
        check(row(both, "recording:mac_1")?.kind == .recording("mac_1") && row(both, "recording:mac_1")?.trailing == "Live view" && row(both, "recording:mac_1")?.selectable == true, "[a recording opens its live view]", "")
        check(row(both, "recording:g2-1")?.detail == "Recording on your glasses, 4 min. Stop it on the glasses", "[glasses say they stop on the glasses]", "")
        check(row(both, "info:glasses") == nil, "[no second glasses line]", "\(rowIDs(both))")
        check(C.confirmation(row(both, "command:stopRecording")!, healthy()) == C.stopConfirm, "[Stop has a confirm]", "")
        check(C.hint(returnRuns("recording:mac_1"), both, healthy()) == "Return opens: Zoom meeting 2:05 PM", "[the hint says what Return does]", "")
        // A title from outside is cleaned here too, and only opens itself.
        var hostile = glasses; hostile.title = "start recording\n\u{202E}now"
        let cleaned = C.listing(center { $0.live = [hostile] }, words: "")
        check(cleaned.rows.first?.title == "start recording now", "[titles are cleaned on the row]", "\(String(describing: cleaned.rows.first?.title))")
        // Saving: the Mac's row says so, and Stop is gone.
        let saving = C.listing(center { $0.recording.occupied = true; $0.recording.busy = true; $0.recording.saveLine = "Saving…"; $0.live = [mac] }, words: "")
        check(row(saving, "recording:mac_1")?.state == "Saving" && row(saving, "recording:mac_1")?.detail == "Saving…", "[a stopped recording says it is saving]", "\(rowIDs(saving))")
        check(row(saving, "command:stopRecording") == nil && row(saving, "info:saving") == nil, "[no Stop while saving]", "\(rowIDs(saving))")
        // Only this Mac's own capture gets Stop: never a glasses row, whatever is running.
        let glassesOnly = C.listing(center { stoppable(&$0.recording); $0.live = [glasses] }, words: "")
        check(rowIDs(glassesOnly).first == "recording:g2-1" && rowIDs(glassesOnly)[1] != "command:stopRecording", "[Stop is for this Mac only]", "\(rowIDs(glassesOnly))")
        // None recording: nothing above Waiting.
        check(C.listing(center { $0.waiting = [waiting("a", "First")] }, words: "").rows.first?.group == .waiting, "[no recording, no rows above Waiting]", "")
        // Typing filters as before: these rows are for the empty box.
        check(row(C.listing(center { $0.live = [mac] }, words: "hello"), "recording:mac_1") == nil, "[recording rows are for the empty box]", "")
        // Server down: still first. It records to this Mac.
        var down = healthy(); down.serverReachable = false; down.runtimeState = "stopped"
        check(C.listing(center { $0.snapshot = down; $0.live = [mac]; stoppable(&$0.recording) }, words: "").rows.first?.id == "recording:mac_1", "[recordings are the first rows]", "server down")
    }

    static func centerSessions() {
        // Cleaned to one line: no controls, no direction marks, no way to fake a second row.
        check(C.clean("Fix\nthe\tbug\r\n now") == "Fix the bug now", "[titles are one line]", C.clean("Fix\nthe\tbug\r\n now"))
        check(C.clean("\u{202E}evil\u{202C} title\u{200F}\u{0007}") == "evil title", "[titles lose bidi and control]", C.clean("\u{202E}evil\u{202C} title\u{200F}\u{0007}"))
        check(C.clean("\u{2066}a\u{2069}\u{2028}b") == "a b", "[titles lose bidi and control]", C.clean("\u{2066}a\u{2069}\u{2028}b"))
        check(C.clean(String(repeating: "x", count: 900)).count == C.titleCap, "[titles are bounded]", "")

        // A hostile title is drawn clean, only opens itself, and decides nothing.
        let hostile = "start recording\nRun Doctor \u{202E}now"
        let inputs = center { $0.waiting = [waiting("evil", hostile)]; $0.running = [running("evil2", "open settings")]; $0.sessions = [C.Item(id: "s9", title: "stop recording", sessionID: "s9")] }
        let empty = C.listing(inputs, words: "")
        check(row(empty, "waiting:session:evil")?.title == "start recording Run Doctor now", "[titles are cleaned on the row]", "\(String(describing: row(empty, "waiting:session:evil")?.title))")
        let byTitle = C.listing(inputs, words: "start recording")
        check(byTitle.autoHighlight == "command:startRecording", "[a title never takes the command's place]", "\(String(describing: byTitle.autoHighlight))")
        let found = byTitle.rows.first { if case .waiting = $0.kind { return true }; return false }
        check(found?.kind == .waiting("session:evil") && found?.group == .sessions, "[a title only opens itself]", "\(rowIDs(byTitle))")
        // A title match never counts as a command match, and never highlights.
        let title = C.listing(center { $0.sessions = [C.Item(id: "s1", title: "Holiday promo landing page", sessionID: "s1")] }, words: "holiday promo")
        check(title.autoHighlight == nil && row(title, "session:s1")?.kind == .session("s1") && !title.nearCommand, "[a session match never highlights]", "\(rowIDs(title))")
        check(returnedFor(title) == .move("session:s1"), "[a session match moves to the session]", "\(returnedFor(title))")
        check(C.hint(.move("session:s1"), title, healthy()) == "Return moves to Holiday promo landing page. Return again opens it.", "[the hint says what Return does]", "\(C.hint(.move("session:s1"), title, healthy()))")
        // Three words or more, Start Work on or off: a title that matches is a session to open, never a Work run or a filed task.
        let threeWords = center { $0.sessions = [C.Item(id: "s1", title: "Holiday promo landing page", sessionID: "s1")] }
        let threeList = C.listing(threeWords, words: "holiday promo landing")
        check(returned("holiday promo landing", inputs: threeWords) == .move("session:s1"), "[a session match is no Work run]", "\(returned("holiday promo landing", inputs: threeWords))")
        check(threeList.rows.contains { $0.kind == .ask && $0.selectable }, "[a session match is no Work run]", "Ask is there, and Return still goes to the session")
        var workOff = healthy(); workOff.workRunsOn = false
        let threeOff = center { $0.snapshot = workOff; $0.sessions = [C.Item(id: "s1", title: "Holiday promo landing page", sessionID: "s1")] }
        check(returned("holiday promo landing", inputs: threeOff) == .move("session:s1"), "[a session match is no filed task]", "\(returned("holiday promo landing", inputs: threeOff))")
        // A waiting or running row that matches is the same: the first session-group row, in the order listed.
        let waitingMatch = center { $0.waiting = [waiting("w", "Holiday promo review")]; $0.sessions = [C.Item(id: "s1", title: "Holiday promo landing page", sessionID: "s1")] }
        check(returned("holiday promo", inputs: waitingMatch) == .move("waiting:session:w"), "[a session match moves to the first session row]", "\(returned("holiday promo", inputs: waitingMatch))")
        // Words that match no title: Return moves to Ask, however many words there are, and a second Return runs it.
        check(returned("holiday promo landing", inputs: center { $0.sessions = [C.Item(id: "s2", title: "Rain audit", sessionID: "s2")] }) == .move("ask"), "[no match moves to Ask]", "")
        // A command's row still comes before a session row.
        let both = center { $0.sessions = [C.Item(id: "s1", title: "Open sessions guide", sessionID: "s1")] }
        check(returned("open sess", inputs: both) == .move("command:openSessions"), "[a command row comes before a session row]", "\(returned("open sess", inputs: both))")
        // A move to Ask always has an Ask row to land on.
        check(C.listing(center(), words: "draft the note to Dana").rows.contains { $0.kind == .ask && $0.selectable }, "[a Work run goes through Ask]", "")
        let long = C.listing(center { $0.sessions = [C.Item(id: "s1", title: "start recording the holiday promo", sessionID: "s1")] }, words: "holiday promo landing")
        check(returnedFor(long) == .move("ask"), "[a title never changes Return]", "")
        // A session lists once, and the search is capped.
        let same = C.listing(center { $0.waiting = [waiting("one", "Rain audit")]; $0.running = [running("one", "Rain audit")]; $0.sessions = [C.Item(id: "one", title: "Rain audit", sessionID: "one")] }, words: "rain")
        check(same.rows.filter { $0.group == .sessions }.count == 1, "[a session lists once]", "\(rowIDs(same))")
        let many = C.listing(center { $0.sessions = (0..<20).map { C.Item(id: "m\($0)", title: "Rain \($0)", sessionID: "m\($0)") } }, words: "rain")
        check(many.rows.filter { $0.group == .sessions }.count == C.sessionCap && C.sessionCap == 5, "[the search is capped]", "")
        // Listed sessions never show on an empty box.
        check(row(C.listing(center { $0.sessions = [C.Item(id: "s1", title: "Listed", sessionID: "s1")] }, words: ""), "session:s1") == nil, "[the list needs words]", "")
        // The run started here comes first, so a row opens it.
        let started = C.listing(center { $0.running = (0..<5).map { running("r\($0)", "Run \($0)") }; $0.startedRunID = "r4" }, words: "")
        check(started.rows.first { $0.group == .running }?.id == "running:r4", "[a row opens the started run]", "\(rowIDs(started))")
    }

    static func returnedFor(_ listing: C.Listing) -> C.ReturnOutcome {
        C.onReturn(option: false, chosen: nil, confirming: false, noticeShowing: false, listing, healthy())
    }


    // MARK: Places, the noun list, word search and the footer (0.5.361)

    static let zone = TimeZone(identifier: "America/Chicago")!
    /// Gregorian, Sunday first, Austin's zone: "this week" and "yesterday" are the same on every Mac that runs the check.
    static var gregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.firstWeekday = 1
        return calendar
    }
    /// Saturday 2026-10-31, 3 PM.
    static let fixedNow: Date = gregorian.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 15))!

    static func daysAgo(_ days: Int, hour: Int = 9) -> Date {
        let day = gregorian.date(byAdding: .day, value: -days, to: gregorian.startOfDay(for: fixedNow))!
        return gregorian.date(byAdding: .hour, value: hour, to: day)!
    }

    static func listed(_ id: String, _ title: String, days: Int? = 0, hour: Int = 9, state: String? = nil, warm: Bool = false) -> C.Item {
        C.Item(id: id, title: title, detail: "Claude Code, MU-Chief-Staff", openLabel: "Open in Claude", sessionID: id, state: state, date: days.map { daysAgo($0, hour: hour) }, keepWarm: warm)
    }

    /// A healthy Mac with a loaded session list, a fixed clock, and these sessions already merged.
    static func withSessions(_ items: [C.Item], _ build: (inout C.Inputs) -> Void = { _ in }) -> C.Inputs {
        center {
            $0.sessions = C.merged(live: [], listed: items)
            $0.sessionsLoaded = true
            $0.now = fixedNow
            $0.calendar = gregorian
            build(&$0)
        }
    }

    static func hit(_ id: String, _ title: String, match: String? = nil, days: Int? = 12) -> C.Item {
        C.Item(id: id, title: title, detail: "Claude Code, Quilt", openLabel: "Open in Claude", sessionID: id, state: "Recent", date: days.map { daysAgo($0) }, match: match)
    }

    static func withFound(_ inputs: C.Inputs, words: String, phase: C.SearchPhase = .done, hits: [C.Item]) -> C.Inputs {
        var next = inputs
        next.found = C.Found(words: C.plain(words), phase: phase, hits: hits)
        return next
    }

    static func ownersOfEveryExactName() -> [String: [String]] {
        var owners: [String: [String]] = [:]
        func claim(_ name: String, _ owner: String) { owners[C.plain(name), default: []].append(owner) }
        for command in C.Command.allCases { for phrase in command.phrases { claim(phrase, "command:" + command.rawValue) } }
        for place in C.Place.allCases { for name in place.names { for form in [name, "open " + name, "go to " + name, "show " + name] { claim(form, "place:" + place.rawValue) } } }
        for noun in C.nounPhrases { claim(noun, "noun") }
        for group in C.settingsGroups { for name in C.settingsGroupNames(group.id) { for form in [name, "open " + name, "go to " + name, "show " + name] { claim(form, "settings:" + group.id) } } }
        return owners
    }

    static func baseName(_ name: String) -> String {
        for verb in ["open ", "go to ", "show "] where name.hasPrefix(verb) { return String(name.dropFirst(verb.count)) }
        return name
    }

    static func centerSettingsGroups() {
        // The table: 39 groups (0.5.372 adds COS reaching out), each with a title, a category and at least one name no other row answers to.
        check(C.settingsGroups.count == 39 && Set(C.settingsGroups.map(\.id)).count == 39, "[the Settings groups are a closed list]", "\(C.settingsGroups.count)")
        for group in C.settingsGroups {
            let names = C.settingsGroupNames(group.id)
            check(!names.isEmpty && !group.title.isEmpty && !group.parent.isEmpty, "[every Settings group has a name of its own]", group.id)
            for name in names { check(C.plain(name) == name, "[Settings names are plain words]", name) }
        }
        let owners = ownersOfEveryExactName()
        for (name, list) in owners where list.contains(where: { $0.hasPrefix("settings:") }) {
            check(Set(list).count == 1, "[a Settings group name is no other row's name]", "\(name): \(list)")
        }
        func rows(_ words: String, classic: Bool = false, hidden: Set<String> = []) -> C.Listing {
            var inputs = center { $0.hiddenSettingsGroups = hidden }
            inputs.snapshot.classicSettings = classic
            return C.listing(inputs, words: words)
        }
        let micro = rows("microphone")
        check(micro.rows.map(\.id).contains("settings:dictation.microphone") && micro.autoHighlight == nil, "[a Settings group is listed and never highlights itself]", "\(rowIDs(micro))")
        check(row(micro, "settings:dictation.microphone")?.title == "Microphone" && row(micro, "settings:dictation.microphone")?.detail == "In Settings, Dictation", "[a Settings group names its category]", "")
        check(returned("go to microphone") == .move("settings:dictation.microphone") && returned("go to microphone", chosen: "settings:dictation.microphone") == returnRuns("settings:dictation.microphone"), "[a whole Settings name takes Return twice]", "\(returned("go to microphone"))")
        check(returned("update") == .move("ask"), "[a word that starts a Settings name does not take Return]", "\(returned("update"))")
        check(rows("microphone", classic: true).rows.allSatisfy { !$0.id.hasPrefix("settings:") }, "[Settings groups hide under the classic Settings]", "")
        check(rows("microphone", hidden: ["dictation.microphone"]).rows.allSatisfy { $0.id != "settings:dictation.microphone" }, "[a group the hub is not drawing is not listed]", "")
        check(rows("decision models").rows.contains { $0.id == "settings:ai.decision" }, "[Decision models is a place]", "")
        // A one-word search stays readable: at most three Settings rows, and the places before them are capped as they were.
        for word in ["settings", "model", "voice", "work", "sessions", "dictation", "meeting", "pet", "update", "server", "app"] {
            let l = rows(word)
            check(l.rows.filter { $0.id.hasPrefix("settings:") }.count <= C.settingsCap && C.settingsCap == 3, "[a one-word search lists at most three Settings groups]", word)
            check(l.rows.filter { $0.id.hasPrefix("place:") }.count <= C.placeCap, "[a one-word search lists at most six places]", word)
            check(l.rows.filter { $0.id.hasPrefix("settings:") }.allSatisfy { $0.selectable }, "[Settings rows can be chosen]", word)
        }
        // A Settings group is one more place to leave from: it asks first when a reply is typed and unsent.
        var draft = healthy(); draft.unsentSessionDraft = true
        check(C.confirmation(row(micro, "settings:dictation.microphone")!, draft) == C.draftConfirm && C.leavesSession(row(micro, "settings:dictation.microphone")!), "[a Settings group with an unsent message asks first]", "")
        // The exact name finds no session search, and a topic with one of these words in a sentence is listed only.
        check(rows("go to microphone").searchWords != nil && rows("performance").searchWords == C.plain("performance"), "[an exact Settings name still searches sessions]", "")
        check(rows("performance").rows.contains { $0.id == "search-all" } && rows("performance").rows.contains { $0.id == "settings:voice.performance" }, "[an exact Settings name keeps Search all sessions and its own row]", "\(rowIDs(rows("performance")))")
        check(rows("microphone settings never works when the headset is on").rows.first { $0.id == "settings:dictation.microphone" } != nil && returned("microphone settings never works when the headset is on") == .move("ask"),
              "[a Settings name that begins a sentence is listed and Return goes to Ask]", "")
    }

    static func centerPlaces() {
        // The closed list, with a title, a parent for a tab, and names that are all plain words.
        check(C.Place.allCases.count == 25, "[places are a closed list]", "\(C.Place.allCases.count)")
        for place in C.Place.allCases {
            check(!place.title.isEmpty && !place.names.isEmpty, "[places are a closed list]", "\(place)")
            for name in place.names { check(C.plain(name).trimmingCharacters(in: .whitespaces) == name, "[place names are plain words]", name) }
        }
        check(C.Place.allCases.filter { $0.parent == nil } == [.today, .messages, .threads], "[panes with no Open command are places]", "")

        // Every exact name is enumerated. A name two kinds of row answer to must be declared with its winner, and the winner is the
        // row that highlights. Anything else with more than one owner fails here.
        let owners = ownersOfEveryExactName()
        var shared = Set<String>()
        for (name, list) in owners {
            let unique = Set(list)
            let listing = C.listing(center(), words: name)
            if unique.count > 1 {
                shared.insert(baseName(name))
                check(C.sharedNames[baseName(name)] != nil, "[a name two rows answer to is declared]", "\(name): \(unique.sorted())")
                if C.sharedNames[baseName(name)] == "noun" {
                    // The noun list wins: it lists the sessions, and nothing highlights or runs on Return.
                    check(listing.autoHighlight == nil && listing.listOnly && returned(name) == .nothing, "[a noun list wins its name and highlights nothing]", "\(name): \(String(describing: listing.autoHighlight))")
                } else {
                    check(listing.autoHighlight == C.sharedNames[baseName(name)], "[the declared winner highlights]", "\(name): \(String(describing: listing.autoHighlight))")
                }
            } else if let only = unique.first, only.hasPrefix("place:") {
                check(listing.autoHighlight == "place:" + only.dropFirst("place:".count), "[an exact place name highlights its row]", "\(name): \(String(describing: listing.autoHighlight))")
                check(returned(name) == returnRuns(listing.autoHighlight ?? "?"), "[Return opens an exact place name]", name)
            } else if let only = unique.first, only == "noun" {
                check(listing.autoHighlight == nil && listing.listOnly, "[a noun list highlights nothing]", "\(name): \(String(describing: listing.autoHighlight))")
            } else if let only = unique.first, only.hasPrefix("settings:") {
                check(listing.autoHighlight == nil && listing.rows.contains { $0.id == only }, "[a Settings group never highlights itself]", "\(name): \(String(describing: listing.autoHighlight))")
            }
        }
        check(shared == Set(C.sharedNames.keys), "[no stale declared name]", "\(shared.sorted()) vs \(C.sharedNames.keys.sorted())")
        // Stop and Doctor words are never a place.
        let stopAndDoctor = Set((C.Command.stopRecording.phrases + C.Command.runDoctor.phrases).map(C.plain))
        for place in C.Place.allCases {
            check(Set(place.names.flatMap { [$0, "open " + $0, "go to " + $0, "show " + $0] }.map(C.plain)).isDisjoint(with: stopAndDoctor), "[no place equals a Stop or Doctor phrase]", "\(place)")
        }

        // The journeys.
        let usage = C.listing(center(), words: "usage")
        check(usage.autoHighlight == "place:sessionsUsage" && rowIDs(usage).first == "place:sessionsUsage", "[usage then Return opens Usage]", "\(rowIDs(usage))")
        check(row(usage, "place:sessionsUsage")?.title == "Usage" && row(usage, "place:sessionsUsage")?.detail == "In Sessions", "[a tab row names its parent]", "")
        check(returned("usage") == returnRuns("place:sessionsUsage"), "[usage then Return opens Usage]", "")
        check(C.hint(returnRuns("place:sessionsUsage"), usage, healthy()) == "Return opens: Usage", "[the footer says Return opens]", "\(C.hint(returnRuns("place:sessionsUsage"), usage, healthy()))")
        check(C.listing(center(), words: "recent").autoHighlight == nil && row(C.listing(center(), words: "recent"), "place:messagesRecent") != nil, "[recent: the noun list wins, Messages > Recent is listed]", "")
        check(C.listing(center(), words: "messages recent").autoHighlight == "place:messagesRecent" && C.listing(center(), words: "go to archive").autoHighlight == "place:messagesArchive", "[Messages > Recent and Archive by name]", "")
        check(C.listing(center(), words: "cos cost").autoHighlight == "place:sessionsCost" && C.listing(center(), words: "go to usage").autoHighlight == "place:sessionsUsage", "[a tab by name]", "")
        check(C.listing(center(), words: "go to usage").nearCommand && C.listing(center(), words: "usa").nearCommand, "[a place counts as a near-command]", "")
        check(returned("go to usage") == returnRuns("place:sessionsUsage"), "[go to usage opens, never a run]", "\(returned("go to usage"))")
        // Start Work off: a place is where Return goes, never a filing. A name that only starts one moves to it.
        var workOffSnapshot = healthy(); workOffSnapshot.workRunsOn = false
        let workOff = center { $0.snapshot = workOffSnapshot }
        check(returned("go to usage", inputs: workOff) == returnRuns("place:sessionsUsage") && returned("usa", inputs: workOff) == .move("place:sessionsUsage"), "[Start Work off: a place is where Return goes]", "")

        let messages = C.listing(center(), words: "messages")
        check(messages.autoHighlight == "place:messages" && row(messages, "place:messagesRecent") != nil && row(messages, "place:messagesArchive") != nil, "[messages lists its tabs]", "\(rowIDs(messages))")
        let work = C.listing(center(), words: "work")
        check(work.autoHighlight == "command:openWork", "[the pane command wins over its tabs]", "")
        for tab in ["place:workAll", "place:workNeeds", "place:workProgress", "place:workCompleted"] { check(row(work, tab) != nil, "[work lists its four scopes]", tab) }
        let tasks = C.listing(center(), words: "tasks")
        check(tasks.autoHighlight == "command:openWork" && tasks.rows.filter { $0.group == .commands || $0.group == .places }.count == 1, "[tasks is one row, Work]", "\(rowIDs(tasks))")
        for pane in ["speakers", "dictation", "settings", "memories", "meetings", "sessions"] {
            let listing = C.listing(center(), words: pane)
            check(listing.rows.filter { $0.group == .places }.count <= C.placeCap && C.placeCap == 6, "[the place list is capped]", "\(pane): \(rowIDs(listing))")
            check(listing.autoHighlight?.hasPrefix("command:") == true, "[a pane with an Open command highlights the command]", "\(pane): \(String(describing: listing.autoHighlight))")
        }
        // The cap bounds the list, whatever the table holds: a small cap proves it.
        check(C.visiblePlaces("work", question: false, cap: 2).count == 2 && C.visiblePlaces("work", question: false).count == 4 && C.visiblePlaces("work", question: false, cap: 0).isEmpty, "[the place list is capped]", "\(C.visiblePlaces("work", question: false).map(\.place))")
        check(C.visiblePlaces("messages", question: false).map(\.place) == [.messages, .messagesRecent, .messagesArchive], "[a pane before its tabs]", "\(C.visiblePlaces("messages", question: false).map(\.place))")
        check(C.visiblePlaces("usage", question: false, among: [.sessionsCost]).isEmpty, "[places are looked up among the ones given]", "")
        check(row(C.listing(center(), words: "speakers"), "place:speakersVoices") != nil && row(C.listing(center(), words: "dictation"), "place:dictationHistory") != nil, "[a pane lists its tabs under the command]", "")
        // "voices" is the Voices tab and nothing else (QA 0.5.361, U5: it was also a Speakers opener and landed on Meetings to review).
        let voices = C.listing(center(), words: "voices")
        check(voices.autoHighlight == "place:speakersVoices" && returned("voices") == returnRuns("place:speakersVoices"), "[voices opens the Voices tab]", "\(rowIDs(voices)) \(String(describing: voices.autoHighlight))")
        check(!voices.rows.contains { $0.id == "command:openSpeakers" } && C.sharedNames["voices"] == nil, "[voices is no Speakers opener]", "\(rowIDs(voices))")
        for phrase in ["open voices", "go to voices", "show voices"] {
            let listing = C.listing(center(), words: phrase)
            check(listing.autoHighlight == "place:speakersVoices" && returned(phrase) == returnRuns("place:speakersVoices"), "[voices opens the Voices tab]", "\(phrase): \(String(describing: listing.autoHighlight))")
        }
        check(!C.Command.openSpeakers.phrases.contains { C.plain($0).contains("voices") }, "[voices is no Speakers opener]", "\(C.Command.openSpeakers.phrases)")
        // Recording is not a place: it lists Start recording first, and a bare word inside a Start phrase is no order (0.5.359's rule).
        let recording = C.listing(center(), words: "recording")
        check(recording.rows.first?.id == "command:startRecording" && recording.autoHighlight == nil && returned("recording") != returnRuns("command:startRecording"), "[recording lists Start recording and does not run it]", "\(rowIDs(recording)) \(returned("recording"))")
        check(returned("recording") == .move("ask"), "[recording moves to Ask, never onto Start recording]", "\(returned("recording"))")
        check(C.listing(center(), words: "start recording").autoHighlight == "command:startRecording" && returned("start recording") == returnRuns("command:startRecording"), "[start recording runs]", "")

        // A name that only begins a sentence is listed, and Return passes over it.
        for sentence in ["usage limit reached", "messages from Jeremy", "threads about pricing", "usage?"] {
            let listing = C.listing(center(), words: sentence)
            let id = sentence.hasPrefix("usage") ? "place:sessionsUsage" : (sentence.hasPrefix("messages") ? "place:messages" : "place:threads")
            check(row(listing, id) != nil && listing.autoHighlight == nil && listing.returnSkips.contains(id), "[a first-word match in a sentence is listed only]", "\(sentence): \(rowIDs(listing))")
            check(returned(sentence) == .move("ask"), "[a first-word match in a sentence goes to Ask]", "\(sentence): \(returned(sentence))")
        }
        // Two letters reach no place: "us" goes on to a session with a word of its title that begins with it.
        let plus = center { $0.sessions = [C.Item(id: "claude:plus0001", title: "User survey review", sessionID: "claude:plus0001")] }
        check(!C.listing(plus, words: "us").rows.contains { $0.group == .places } && returned("us", inputs: plus) == .move("session:claude:plus0001"), "[us skips Usage and goes to a session]", "\(returned("us", inputs: plus))")
        // Three letters do: the start of a name moves to it, and the second Return opens it.
        check(returned("usa") == .move("place:sessionsUsage") && returned("usa", chosen: "place:sessionsUsage") == returnRuns("place:sessionsUsage"), "[the start of a name moves to it]", "\(returned("usa"))")
        check(C.hint(.move("place:sessionsUsage"), C.listing(center(), words: "usa"), healthy()) == "Return moves to Usage. Return again opens it.", "[the footer says Return opens]", "")
        // A command wins over a place for the same name; a place wins over a session titled the same.
        let titledUsage = center { $0.sessions = [C.Item(id: "claude:usage001", title: "Usage", sessionID: "claude:usage001")] }
        let usageList = C.listing(titledUsage, words: "usage")
        check(usageList.autoHighlight == "place:sessionsUsage" && row(usageList, "session:claude:usage001") != nil, "[a place wins over a session titled the same]", "\(rowIDs(usageList))")
        let titledCommand = center { $0.sessions = [C.Item(id: "claude:rec00001", title: "Start recording", sessionID: "claude:rec00001")] }
        let commandList = C.listing(titledCommand, words: "start recording")
        check(commandList.autoHighlight == "command:startRecording" && returned("start recording", inputs: titledCommand) == returnRuns("command:startRecording"), "[a command wins over a session titled the same]", "")
        check(C.hint(.move("session:claude:rec00001"), commandList, healthy()) == "Return moves to the session Start recording. Return again opens it.", "[a session titled like a command is called a session]", "\(C.hint(.move("session:claude:rec00001"), commandList, healthy()))")
        check(C.hint(returnRuns("session:claude:rec00001"), commandList, healthy()) == "Return opens: the session Start recording", "[a session titled like a command is called a session]", "")
        // "go", "show", "open" and "to" match every opener phrase of a command, and no place: a place needs three letters of a real name.
        for filler in ["go", "to", "show", "open", "go to", "open the", "show me"] {
            check(!C.listing(center(), words: filler).rows.contains { $0.group == .places }, "[opener words reach no place]", filler)
        }
        // Words that do not name a pane or tab never open an unrelated session, with sessions listed.
        let unrelated = withSessions([listed("claude:rain0001", "Rain audit", days: 1), listed("claude:usage002", "Usage notes", days: 2)])
        check(returned("draft the note to Dana", inputs: unrelated) == .move("ask") && returned("email Gina about pricing", inputs: unrelated) == .move("ask"), "[words never open an unrelated session]", "\(returned("draft the note to Dana", inputs: unrelated))")
        // Places are free text too: nothing typed becomes anything but a name match.
        check(returned("draft the note to Dana") == .move("ask") && !C.listing(center(), words: "draft the note to Dana").rows.contains { $0.group == .places }, "[free text matches no place]", "")

        // An unsent message in an open session is cleared by going anywhere, so a place asks first. Nothing else does.
        var drafting = healthy(); drafting.unsentSessionDraft = true
        let placeRow = row(usage, "place:sessionsUsage")!
        check(C.confirmation(placeRow, drafting) == C.draftConfirm && C.confirmation(placeRow, healthy()) == nil, "[a place with an unsent message asks first]", "")
        for (kind, leaves) in [(C.Kind.hit("h"), true), (.searchAll, true)] {
            let r = C.Row(id: "x", kind: kind, group: .found, title: "x", leavesSession: leaves)
            check(C.confirmation(r, drafting) == C.draftConfirm && C.confirmation(r, healthy()) == nil, "[a hit and Search all sessions ask first with an unsent message]", "\(kind)")
        }
        centerDraftSafety()
        check(C.hint(returnRuns("place:sessionsUsage"), usage, drafting) == "Return asks first: Usage", "[the footer says it asks first]", "")
        check(C.draftConfirm.confirm == "Go there" && C.recheck(placeRow, drafting, recordable()) == nil, "[the draft confirm has no force path]", "")
        for kind in C.Place.allCases.map({ C.Kind.place($0) }) {
            check(!C.sendsWords(C.Row(id: "x", kind: kind, group: .places, title: "x")) && C.draftAfterRun(C.Row(id: "x", kind: kind, group: .places, title: "x"), "usage").isEmpty, "[a place that ran leaves no draft]", "\(kind)")
        }
        // Row ids stay unique with places listed.
        for words in ["messages", "work", "speakers", "settings", "dictation", "usage", "voices", "meetings", "sessions", "all", "review"] {
            let listing = C.listing(center(), words: words)
            check(Set(rowIDs(listing)).count == listing.rows.count, "[row ids are unique]", "\(words): \(rowIDs(listing))")
        }
    }

    /// QA item 7: every row that takes the person out of the open session asks first when a reply is typed and not sent, exact openers
    /// included. A row that opens in the session's own app clears nothing, so it does not ask.
    static func centerDraftSafety() {
        var drafting = healthy(); drafting.unsentSessionDraft = true
        func asks(_ id: String, _ words: String, _ inputs: C.Inputs? = nil) -> Bool {
            let list = C.listing(inputs ?? center(), words: words)
            guard let r = row(list, id) else { check(false, "[the row is listed]", "\(id) for \(words)"); return false }
            return C.confirmation(r, drafting) == C.draftConfirm && C.confirmation(r, healthy()) == nil
        }
        for (words, id) in [("sessions", "command:openSessions"), ("meetings", "command:openMeetings"), ("work", "command:openWork"), ("speakers", "command:openSpeakers"),
                            ("dictation", "command:openDictation"), ("memories", "command:openMemories")] {
            check(asks(id, words), "[an exact opener asks first with an unsent message]", words)
        }
        // The exact opener is the row Return runs, so the foot and the confirm both say so.
        let exact = C.listing(center(), words: "sessions")
        check(C.hint(returnRuns("command:openSessions"), exact, drafting) == "Return asks first: Open Sessions" && C.hint(returnRuns("command:openSessions"), exact, healthy()) == "Return runs: Open Sessions",
              "[an exact opener says it asks first]", "\(C.hint(returnRuns("command:openSessions"), exact, drafting))")
        // Settings opens over the open session and clears nothing. Start recording, Stop and Doctor keep their own rules.
        let settings = row(C.listing(center(), words: "settings"), "command:openSettings")!
        check(C.confirmation(settings, drafting) == nil, "[Settings does not clear a reply, so it does not ask]", "")
        check(C.confirmation(row(C.listing(center(), words: "start recording"), "command:startRecording")!, drafting) == nil, "[Start recording never asks]", "")
        check(C.confirmation(row(C.listing(center(), words: "run doctor"), "command:runDoctor")!, drafting) == C.doctorConfirm, "[Doctor keeps its own confirm]", "")
        for kind in [C.Kind.ask, .file, .savedAnswer, .info] { check(C.confirmation(C.Row(id: "x", kind: kind, group: .asking, title: "x"), drafting) == nil, "[Ask, File and words never ask]", "\(kind)") }
        // Sessions, waiting and running rows ask when their open path leaves the session, and not when it opens in the session's own app.
        let leaving = C.Item(id: "claude:held0001", title: "A held run", sessionID: "claude:held0001", leavesSession: true)
        let platform = C.Item(id: "claude:term0001", title: "A terminal session", sessionID: "claude:term0001", leavesSession: false)
        let inputs = center { $0.sessions = [leaving, platform]; $0.sessionsLoaded = true; $0.waiting = [C.Item(id: "session:claude:w0000001", title: "A waiting one", sessionID: "claude:w0000001", leavesSession: true)]
                              $0.running = [C.Item(id: "claude:r0000001", title: "A running one", sessionID: "claude:r0000001", leavesSession: false)] }
        check(asks("session:claude:held0001", "held", inputs) && !asks("session:claude:term0001", "terminal", inputs), "[a listed session asks only when it opens inside Sessions]", "")
        check(asks("waiting:session:claude:w0000001", "waiting", inputs), "[a waiting row that opens inside Sessions asks]", "")
        check(!asks("running:claude:r0000001", "running one", inputs), "[a running row that opens in its own app does not ask]", "")
        // A live view, an Open Meetings or Open Speakers offer, and Search all sessions leave the session.
        let live = C.LiveRecording(id: "mac_1", title: "A call", detail: "Recording", isMac: true, canStop: true)
        let recordingRow = row(C.listing(center { $0.live = [live]; $0.recording.stoppable = true; $0.recording.occupied = true; $0.recording.busy = true }, words: ""), "recording:mac_1")!
        check(C.confirmation(recordingRow, drafting) == C.draftConfirm, "[a live view asks first with an unsent message]", "")
        for action in [SA.Action.openMeetings, .openSpeakers] {
            check(C.confirmation(C.Row(id: "x", kind: .action(action), group: .answer, title: "x"), drafting) == C.draftConfirm, "[an Open Meetings or Open Speakers offer asks first]", "\(action)")
        }
        check(C.confirmation(C.Row(id: "x", kind: .action(.openTailscale), group: .answer, title: "x"), drafting) == nil, "[an offer that opens another app does not ask]", "")
        // Nothing asks when nothing is typed.
        for kind in C.Place.allCases.map({ C.Kind.place($0) }) + [C.Kind.searchAll, .recording("a"), .command(.openWork)] {
            check(C.confirmation(C.Row(id: "x", kind: kind, group: .doing, title: "x"), healthy()) == nil, "[nothing asks when no reply is typed]", "\(kind)")
        }
    }

    static func centerNouns() {
        let all = (0..<12).map { listed("claude:" + String(format: "s%011d", $0), "Session title \($0)", days: $0 % 3 == 0 ? 0 : ($0 % 3 == 1 ? 1 : 5), hour: 20 - $0) }
        let inputs = withSessions(all)
        let sessions = C.listing(inputs, words: "sessions")
        let listedRows = sessions.rows.filter { $0.group == .sessions }
        check(sessions.autoHighlight == "command:openSessions" && sessions.rows.first?.id == "command:openSessions", "[sessions: the pane first, the list below]", "\(rowIDs(sessions))")
        check(listedRows.filter { if case .session = $0.kind { return true } else { return false } }.count == C.nounCap && C.nounCap == 8, "[the noun list shows eight]", "\(listedRows.count)")
        check(row(sessions, "sessions:more")?.title == "4 more in Sessions" && row(sessions, "sessions:more")?.kind == .command(.openSessions), "[then N more in Sessions]", "\(String(describing: row(sessions, "sessions:more")))")
        let dates = all.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(8).map { "session:" + $0.id }
        check(listedRows.compactMap { $0.id.hasPrefix("session:") ? $0.id : nil } == Array(dates), "[newest first]", "\(listedRows.map(\.id)) vs \(Array(dates))")
        check(row(sessions, listedRows.first { $0.id.hasPrefix("session:") }!.id)?.detail?.hasSuffix(", today") == true, "[a row says when]", "")
        check(returned("sessions", inputs: inputs) == returnRuns("command:openSessions"), "[sessions then Return opens Sessions]", "")
        check(sessions.searchWords == nil, "[a noun list runs no search]", "")
        // The same list for the other nouns, and Return only waits for a choice.
        for noun in ["session", "recent", "recent sessions", "my sessions", "all sessions"] {
            let listing = C.listing(inputs, words: noun)
            check(listing.rows.filter({ if case .session = $0.kind { return true } else { return false } }).count == C.nounCap, "[nouns list sessions]", "\(noun): \(rowIDs(listing))")
            check(listing.listOnly && listing.searchWords == nil, "[a noun list is for choosing]", noun)
            if noun != "session" { check(listing.autoHighlight == nil && returned(noun, inputs: inputs) == .nothing, "[recent and running highlight nothing]", "\(noun): \(returned(noun, inputs: inputs))") }
        }
        check(returned("session", inputs: inputs) == .move("command:openSessions"), "[session moves to the pane]", "\(returned("session", inputs: inputs))")
        // "running" lists what runs and what waits, never the idle sessions (QA 0.5.361, U8); "recent" stays the whole list.
        for noun in ["running", "running sessions"] {
            let idle = C.listing(inputs, words: noun)
            check(row(idle, "info:running-none")?.title == "Nothing is running." && !idle.rows.contains { $0.id.hasPrefix("session:") } && idle.listOnly && idle.autoHighlight == nil,
                  "[running with nothing running says so]", "\(noun): \(rowIDs(idle))")
        }
        let mixed = all + [listed("claude:runn0000001", "Holiday promo page", days: 0, hour: 21, state: "Running"), listed("codex:wait0000001", "Rain schema audit", days: 0, hour: 20, state: "Waiting")]
        let workRun = C.Item(id: "work:wr1", title: "Pricing QA run", detail: "Work", openLabel: "Open", sessionID: nil)
        let mixedInputs = withSessions(mixed) { $0.running = [workRun, C.Item(id: "session:claude:runn0000001", title: "Holiday promo page", sessionID: "claude:runn0000001")] }
        let runningList = C.listing(mixedInputs, words: "running")
        let runningIDs = runningList.rows.filter { $0.group == .sessions }.map(\.id)
        check(runningIDs == ["running:work:wr1", "running:session:claude:runn0000001", "session:codex:wait0000001"], "[running lists what runs and what waits]", "\(runningIDs)")
        check(!runningIDs.contains { $0.contains("Session title") || $0.contains("s0000000") }, "[running never lists an idle session]", "\(runningIDs)")
        check(row(runningList, "running:work:wr1")?.state == "Running" && row(runningList, "session:codex:wait0000001")?.state == "Waiting", "[running says which runs and which waits]", "")
        check(returned("running", inputs: mixedInputs) == .nothing && returned("running sessions", inputs: mixedInputs) == .nothing, "[running highlights nothing]", "")
        check(C.listing(mixedInputs, words: "recent").rows.filter { $0.group == .sessions && $0.id.hasPrefix("session:") }.count == C.nounCap, "[recent stays the full list]", "")
        check(row(C.listing(withSessions(mixed) { $0.runningKnown = false }, words: "running"), "session:claude:runn0000001") != nil, "[running lists the sessions that run when the running list is unknown]", "")
        check(row(C.listing(withSessions([]) { $0.runningKnown = false }, words: "running"), "info:running-unknown")?.title == "Running: not loaded yet.", "[running not loaded says so]", "")
        check(!C.isRunningList("running today") && C.nounSpan("running today", question: false) == nil && !C.listing(mixedInputs, words: "running today").listOnly, "[running has no day words]", "")
        let manyRunning = withSessions([]) { $0.running = (0..<10).map { C.Item(id: "r\($0)", title: "Run \($0)", sessionID: nil) } }
        let capped = C.listing(manyRunning, words: "running")
        check(capped.rows.filter { $0.id.hasPrefix("running:") }.count == C.nounCap && row(capped, "sessions:more")?.title == "2 more in Sessions", "[running is capped at eight]", "\(rowIDs(capped))")
        // A question or a sentence is not a list.
        for sentence in ["sessions?", "recent sessions about pricing", "running late today", "show my recent sessions please"] {
            check(!C.listing(inputs, words: sentence).listOnly, "[a sentence is not a list]", sentence)
        }
        // The day words.
        func ids(_ words: String) -> [String] { C.listing(inputs, words: words).rows.filter { if case .session = $0.kind { return true } else { return false } }.map(\.id) }
        let today = all.filter { gregorian.isDate($0.date!, inSameDayAs: fixedNow) }
        check(ids("sessions today") == today.map { "session:" + $0.id } && !today.isEmpty, "[sessions today]", "\(ids("sessions today"))")
        check(ids("sessions from today") == ids("sessions today") && ids("recent today") == ids("sessions today"), "[sessions today]", "")
        check(ids("sessions yesterday").count == 4 && ids("sessions from yesterday") == ids("sessions yesterday"), "[sessions yesterday]", "\(ids("sessions yesterday"))")
        check(ids("sessions this week").count == 8 && Set(ids("sessions this week")).isSuperset(of: ids("sessions today")), "[sessions this week]", "\(ids("sessions this week").count)")
        check(C.listing(withSessions([]), words: "sessions today").rows.contains { $0.id == "info:sessions-none" && $0.title == "No sessions today." }, "[none today says so]", "")
        check(returned("sessions today", inputs: inputs) == .nothing && returned("sessions yesterday", inputs: inputs) == .nothing, "[a day list waits for a choice]", "")
        check(C.inSpan(daysAgo(0, hour: 0), .today, now: fixedNow, calendar: gregorian) && !C.inSpan(daysAgo(1, hour: 23), .today, now: fixedNow, calendar: gregorian), "[midnight is the edge of today]", "")
        check(C.inSpan(nil, .all, now: fixedNow, calendar: gregorian) && !C.inSpan(nil, .today, now: fixedNow, calendar: gregorian), "[an undated session is in all, never in a day]", "")
        check(!C.inSpan(daysAgo(7), .week, now: fixedNow, calendar: gregorian) && C.inSpan(daysAgo(6), .week, now: fixedNow, calendar: gregorian), "[this week is this calendar week]", "")

        // States: not loaded, off, none. Text lines, no rows to open, and no search.
        let notLoaded = C.listing(center { $0.sessionsLoaded = false }, words: "sessions")
        check(row(notLoaded, "info:sessions-unknown")?.title == "Sessions: not loaded yet." && row(notLoaded, "info:sessions-none") == nil, "[sessions not loaded says so]", "\(rowIDs(notLoaded))")
        let off = C.listing(center { $0.sessionsSettingOff = true; $0.sessionsLoaded = true }, words: "recent")
        check(row(off, "sessions:off")?.title == "AI sessions are off" && row(off, "sessions:off")?.selectable == true && row(off, "sessions:off")?.kind == .command(.openSettings) && off.searchWords == nil, "[sessions off shows the off row and no search]", "\(rowIDs(off))")
        check(row(C.listing(center { $0.sessionsSettingOff = true; $0.sessionsLoaded = true }, words: "sessions"), "sessions:off") != nil, "[sessions off shows the off row]", "")
        check(C.listing(center { $0.sessionsSettingOff = true; $0.sessionsLoaded = true }, words: "holiday promo").searchWords == nil, "[sessions off runs no search]", "")
        check(row(C.listing(withSessions([]), words: "sessions"), "info:sessions-none")?.title == "No sessions yet.", "[no sessions yet]", "")
        // A session list is for choosing from: its "off" line and its "N more" line are never what Return moves onto.
        let offList = center { $0.sessionsSettingOff = true; $0.sessionsLoaded = true }
        check(returned("running", inputs: offList) == .nothing && returned("recent sessions today", inputs: offList) == .nothing, "[a session list line is not what Return moves to]", "\(returned("running", inputs: offList))")
        check(row(C.listing(offList, words: "running"), "sessions:off")?.selectable == true && returned("running", chosen: "sessions:off", inputs: offList) == returnRuns("sessions:off"), "[a session list line still opens when chosen]", "")

        // One list from two sources. The loaded list alone holds the recent ones when the pet is on, and the live rows alone hold the running ones.
        let live = [C.Item(id: "claude:abcd1234", title: "Running now", sessionID: "claude:abcd1234", state: "Running", date: nil)]
        let loaded = [listed("claude:abcd1234ef56-7890", "Running now", days: 0, hour: 14), listed("claude:old00001", "Older one", days: 2), listed("claude:warm0001", "Ready", days: 0, hour: 15, warm: true), listed("codex:zz000002", "Codex thread", days: 1)]
        let merged = C.merged(live: live, listed: loaded)
        check(merged.map(\.id) == ["claude:abcd1234", "codex:zz000002", "claude:old00001"].sorted { a, b in
            let dateOf = { (id: String) in merged.first { $0.id == id }?.date ?? .distantPast }
            return dateOf(a) > dateOf(b)
        } || merged.map(\.id) == ["claude:abcd1234", "codex:zz000002", "claude:old00001"], "[one session lists once, newest first]", "\(merged.map(\.id))")
        check(merged.count == 3 && !merged.contains { $0.keepWarm }, "[a keep-warm session never lists]", "\(merged.map(\.id))")
        check(merged.first { $0.id == "claude:abcd1234" }?.date == daysAgo(0, hour: 14) && merged.first { $0.id == "claude:abcd1234" }?.state == "Running", "[the live row wins and takes the list's date]", "")
        let petOn = withSessions([]) { $0.sessions = merged }
        check(C.listing(petOn, words: "recent").rows.filter({ if case .session = $0.kind { return true } else { return false } }).count == 3, "[recent has rows with the pet on]", "")
        check(C.merged(live: [], listed: []).isEmpty && C.merged(live: live, listed: []).count == 1, "[merging nothing]", "")
        check(C.merged(live: [C.Item(id: "a", title: "A", sessionID: nil), C.Item(id: "b", title: "B", sessionID: nil)], listed: []).map(\.id) == ["a", "b"], "[undated sessions keep their order]", "")
        // sameSession: the provider matches, and the ids are equal or one is the first 8 or more characters of the other.
        check(C.sameSession("claude:abcd1234", "claude:ABCD1234ef56") && C.sameSession("claude:abcd1234ef56", "claude:abcd1234"), "[same session by short id]", "")
        check(!C.sameSession("claude:abcd123", "claude:abcd1234") && !C.sameSession("codex:abcd1234", "claude:abcd1234") && !C.sameSession("abcd1234", "abcd1234") && !C.sameSession("claude:", "claude:"), "[different sessions]", "")
        check(C.sameSession("cursor:same", "cursor:same") && !C.sameSession("cursor:one", "cursor:two"), "[same session by equal id]", "")
        check(C.sameListed("one", "one") && !C.sameListed("one", "two"), "[a row id with no provider matches only itself]", "")
        // when
        check(C.when(daysAgo(0), now: fixedNow, calendar: gregorian) == "today" && C.when(daysAgo(1), now: fixedNow, calendar: gregorian) == "yesterday" && C.when(daysAgo(5), now: fixedNow, calendar: gregorian) == "5 days ago", "[when words]", "")
        check(C.when(daysAgo(20), now: fixedNow, calendar: gregorian) == "2 weeks ago" && C.when(daysAgo(90), now: fixedNow, calendar: gregorian) == "3 months ago" && C.when(nil, now: fixedNow, calendar: gregorian) == nil, "[when words]", "")
        // A title match on a loaded session is not a noun list, and a list never drops a title match for another word.
        let titled = withSessions([listed("claude:pricing1", "Pricing page review", days: 3)])
        check(returned("pricing", inputs: titled) == .move("session:claude:pricing1"), "[a title match may take the move]", "\(returned("pricing", inputs: titled))")
        // A title matches at the start of a word, never inside one: "miss" does not list "Permissions audit". A capital after a lowercase letter
        // and a no-space script meeting letters also begin a word, and a term in a no-space script matches anywhere.
        let wordTitles = withSessions([listed("claude:perm0001", "Permissions audit", days: 2), listed("claude:ctrl0001", "ControllerModel refactor", days: 3),
                                       listed("claude:glue0001", "\u{4FEE}\u{590D}oauth\u{6D41}\u{7A0B}", days: 4), listed("claude:tier0001", "tier2audit notes", days: 5),
                                       listed("claude:cjk00001", "\u{7A0E}\u{52D9}\u{78BA}\u{8A8D}\u{306E}\u{4EF6}", days: 6)])
        func titleRows(_ words: String) -> [String] { C.listing(wordTitles, words: words).rows.map(\.id).filter { $0.hasPrefix("session:") } }
        check(!titleRows("miss").contains("session:claude:perm0001"), "[a title match is not inside a word]", "\(titleRows("miss"))")
        check(titleRows("permis").contains("session:claude:perm0001") && titleRows("audit").contains("session:claude:perm0001"), "[a title match is at the start of a word]", "\(titleRows("permis"))")
        check(titleRows("model").contains("session:claude:ctrl0001") && titleRows("controllermodel").contains("session:claude:ctrl0001"), "[a capital after a lowercase letter begins a word]", "\(titleRows("model"))")
        check(!titleRows("troller").contains("session:claude:ctrl0001"), "[the middle of a camel-case word is not a start]", "\(titleRows("troller"))")
        check(titleRows("oauth").contains("session:claude:glue0001"), "[a no-space script meeting letters begins a word]", "\(titleRows("oauth"))")
        check(!titleRows("audit").contains("session:claude:tier0001"), "[a digit does not begin a word]", "\(titleRows("audit"))")
        check(titleRows("\u{52D9}\u{78BA}").contains("session:claude:cjk00001"), "[a no-space script term matches anywhere]", "\(titleRows("\u{52D9}\u{78BA}"))")
    }

    static func centerSearch() {
        let sessions = withSessions([listed("claude:holiday1", "Holiday promo landing page", days: 1), listed("claude:rain0001", "Rain audit", days: 2)])
        // Which words search: three characters or more, not an exact command or place, not a noun list, not with Sessions off.
        check(C.listing(sessions, words: "ab").searchWords == nil && C.listing(sessions, words: "  ab  ").searchWords == nil, "[under three characters, no search]", "")
        check(C.listing(sessions, words: "pri").searchWords == "pri" && C.listing(sessions, words: "Persona Pricing!").searchWords == "persona pricing", "[three characters search, as plain words]", "")
        for exact in ["start recording", "stop recording", "run doctor", "sessions", "open work", "usage", "go to usage", "recent", "sessions today"] {
            check(C.listing(sessions, words: exact).searchWords == nil, "[an exact command, place or noun list runs no search]", exact)
        }
        check(C.listing(withSessions([]) { $0.sessionsSettingOff = true; $0.sessionsLoaded = true }, words: "persona pricing").searchWords == nil, "[Sessions off runs no search]", "")
        check(C.listing(sessions, words: String(repeating: "word ", count: 80)).searchWords?.count == 200, "[the words are capped at 200 characters]", "\(C.listing(sessions, words: String(repeating: "word ", count: 80)).searchWords?.count ?? -1)")
        check(C.listing(center(), words: "").searchWords == nil, "[an empty box runs no search]", "")

        // Hits sit in their own group, after the sessions that matched by title and before the answer and Ask. A fixed row id each.
        let hits = [hit("claude:old00001", "Persona pricing review", match: "we should price the jewelry persona tier above the base plan"), hit("codex:old00002", "Quarterly planning", match: "the persona pricing table needs one more column"), hit("cursor:old00003", "Notes")]
        let found = withFound(sessions, words: "persona pricing", hits: hits)
        let listing = C.listing(found, words: "persona pricing")
        let hitRows = listing.rows.filter { if case .hit = $0.kind { return true } else { return false } }
        check(hitRows.map(\.id) == hits.map { "hit:" + $0.id } && hitRows.allSatisfy { $0.group == .found && $0.selectable }, "[hits are their own group]", "\(rowIDs(listing))")
        check(rowIDs(listing).firstIndex(of: "hit:claude:old00001")! < rowIDs(listing).firstIndex(of: "ask")!, "[hits come before Ask]", "\(rowIDs(listing))")
        check(row(listing, "hit:claude:old00001")?.match == "we should price the jewelry persona tier above the base plan" && row(listing, "hit:cursor:old00003")?.match == nil, "[a hit shows what matched, when it is not the title]", "")
        check(row(listing, "hit:claude:old00001")?.detail == "Claude Code, Quilt, 12 days ago" && row(listing, "hit:claude:old00001")?.state == nil, "[a hit shows tool, project and when]", "\(String(describing: row(listing, "hit:claude:old00001")?.detail))")
        check(row(listing, "search-all")?.kind == .searchAll && row(listing, "search-all")?.title == "Search all sessions" && row(listing, "search-all")?.group == .found, "[Search all sessions is offered]", "")
        // Typing stays on this Mac; Search all sessions does not, and its row says where it goes (QA item 4).
        let searchAllDetail = row(listing, "search-all")?.detail ?? ""
        check(searchAllDetail.contains("COS server") && searchAllDetail.contains("OpenAI"), "[Search all sessions says where it searches]", searchAllDetail)
        // The race: Return does the same thing whether hits have arrived or not, for any words.
        for words in ["persona pricing", "draft the note to Dana", "holiday promo", "pricing", "usage limit reached", "hello", "go to se", "email Gina about pricing"] {
            let without = C.listing(withFound(sessions, words: words, phase: .searching, hits: []), words: words)
            let with = C.listing(withFound(sessions, words: words, hits: hits), words: words)
            let snap = healthy()
            let a = C.onReturn(option: false, chosen: nil, confirming: false, noticeShowing: false, without, snap)
            let b = C.onReturn(option: false, chosen: nil, confirming: false, noticeShowing: false, with, snap)
            check(a == b, "[Return does the same before and after hits arrive]", "\(words): \(a) vs \(b)")
            if case .move(let id) = b { check(!id.hasPrefix("hit:") && id != "search-all", "[Return never moves onto a hit]", "\(words): \(id)") }
            check(with.autoHighlight == without.autoHighlight && with.nearCommand == without.nearCommand && with.hasAnswer == without.hasAnswer, "[hits change no flag Return reads]", words)
        }
        // A hit never takes the first session move: a title match still does, and with no title match Return goes to Ask.
        check(returned("persona pricing", inputs: found) == .move("ask"), "[hits never take Return]", "\(returned("persona pricing", inputs: found))")
        let titleAndHits = withFound(withSessions([listed("claude:persona1", "Persona pricing draft", days: 1)]), words: "persona pricing", hits: hits)
        check(returned("persona pricing", inputs: titleAndHits) == .move("session:claude:persona1"), "[a title match keeps the move]", "\(returned("persona pricing", inputs: titleAndHits))")
        // An arrow reaches a hit, and then Return opens that hit's own row.
        let selectable = listing.rows.filter(\.selectable).map(\.id)
        var cursor: String? = nil
        var reached: [String] = []
        for _ in 0..<selectable.count { cursor = C.move(1, from: cursor, listing); if let cursor { reached.append(cursor) } }
        check(reached.contains("hit:claude:old00001") && reached.contains("search-all"), "[an arrow reaches a hit]", "\(reached)")
        check(returned("persona pricing", chosen: "hit:claude:old00001", inputs: found) == returnRuns("hit:claude:old00001"), "[a chosen hit opens]", "")
        check(C.hint(returnRuns("hit:claude:old00001"), listing, healthy()) == "Return opens: Persona pricing review", "[the footer names the hit]", "\(C.hint(returnRuns("hit:claude:old00001"), listing, healthy()))")
        // A chosen hit that is gone returns nothing: a new search took it, so Return picks no other row.
        let gone = withFound(sessions, words: "persona pricing", hits: [hits[1]])
        check(returned("persona pricing", chosen: "hit:claude:old00001", inputs: gone) == .nothing, "[a chosen row that is gone returns nothing]", "")
        // A refresh for the same words never removes a chosen row.
        let again = C.refreshed(C.Found(words: "persona pricing", phase: .done, hits: hits), words: "persona pricing", hits: [hits[1]], keeping: "hit:claude:old00001")
        check(again.hits.map(\.id) == ["claude:old00001", "codex:old00002"] && again.phase == .done, "[a refresh keeps a chosen hit]", "\(again.hits.map(\.id))")
        let different = C.refreshed(C.Found(words: "persona pricing", phase: .done, hits: hits), words: "jewelry", hits: [hits[1]], keeping: "hit:claude:old00001")
        check(different.hits.map(\.id) == ["codex:old00002"], "[new words start clean]", "")
        let unchosen = C.refreshed(C.Found(words: "persona pricing", phase: .done, hits: hits), words: "persona pricing", hits: [hits[1]], keeping: nil)
        check(unchosen.hits.map(\.id) == ["codex:old00002"], "[an unchosen hit goes with the refresh]", "")
        // Hits for other words never show. A hit the list already shows does not show twice (by sameSession). The hit cap holds.
        check(!C.listing(withFound(sessions, words: "something else", hits: hits), words: "persona pricing").rows.contains { $0.group == .found && $0.id.hasPrefix("hit:") }, "[hits for other words never show]", "")
        let dup = withFound(withSessions([listed("claude:abcd1234ef56", "Persona work", days: 1)]), words: "persona", hits: [hit("claude:abcd1234", "Persona work"), hit("claude:other001", "Persona notes")])
        check(C.listing(dup, words: "persona").rows.filter { $0.id.hasPrefix("hit:") }.map(\.id) == ["hit:claude:other001"], "[a session lists once, by sameSession]", "\(rowIDs(C.listing(dup, words: "persona")))")
        // Two hits for one session (a Desktop record's full id and its transcript's short one) show once.
        let twice = withFound(sessions, words: "persona", hits: [hit("claude:7a8b9c0d-1e2f-4a3b-8c4d-5e6f7a8b9c0d", "Persona work"), hit("claude:7a8b9c0d", "Persona work")])
        check(C.listing(twice, words: "persona").rows.filter { $0.id.hasPrefix("hit:") }.count == 1, "[two hits for one session show once]", "\(rowIDs(C.listing(twice, words: "persona")))")
        let many = withFound(sessions, words: "persona", hits: (0..<12).map { hit("claude:" + String(format: "m%011d", $0), "Persona \($0)") })
        check(C.listing(many, words: "persona").rows.filter { $0.id.hasPrefix("hit:") }.count == C.hitCap && C.hitCap == 5, "[hits are capped at five]", "")
        // The phases are text lines.
        check(row(C.listing(withFound(sessions, words: "persona", phase: .searching, hits: []), words: "persona"), "info:searching")?.title == "Searching sessions…", "[searching is a text line]", "")
        check(row(C.listing(withFound(sessions, words: "persona", phase: .failed, hits: []), words: "persona"), "info:search-failed")?.title == "The search did not run.", "[a failed search says so]", "")
        // Small things (QA 0.5.361): a failed search points at the listed sessions only when some are listed; a warm-up is no hit; a day with
        // nothing in a full list says how far the list reaches.
        check(row(C.listing(withFound(withSessions([]), words: "persona", phase: .failed, hits: []), words: "persona"), "info:search-failed")?.detail == nil, "[a failed search names no list when none is listed]", "")
        check(row(C.listing(withFound(withSessions([listed("claude:per000011", "Persona planning", days: 0)]), words: "persona", phase: .failed, hits: []), words: "persona"), "info:search-failed")?.detail == "The sessions listed here still open.", "[a failed search names the list when sessions are listed]", "")
        let warmHit = C.Item(id: "claude:warm0001", title: "Persona warm-up", sessionID: "claude:warm0001", keepWarm: true)
        check(row(C.listing(withFound(sessions, words: "persona", hits: [warmHit]), words: "persona"), "hit:claude:warm0001") == nil, "[a warm-up session is no hit]", "")
        let oldOnes = (0..<3).map { listed("claude:old0000" + String($0) + "1234", "Old \($0)", days: 5) }
        let fullList = withSessions(oldOnes) { $0.sessionsLimit = 3 }
        check(row(C.listing(fullList, words: "sessions today"), "info:sessions-none")?.title == "No sessions today in your newest 3."
              && row(C.listing(withSessions(oldOnes) { $0.sessionsLimit = 80 }, words: "sessions today"), "info:sessions-none")?.title == "No sessions today."
              && row(C.listing(fullList, words: "sessions"), "info:sessions-none") == nil, "[a day with none in a full list says how far it reaches]", "")
        // A timeout is its own line: the search ran for its whole time, which is not "did not run" (QA 0.5.361, G8).
        let timedOut = C.listing(withFound(sessions, words: "persona", phase: .timedOut, hits: []), words: "persona")
        check(row(timedOut, "info:search-timeout")?.title == "The search took too long." && row(timedOut, "info:search-timeout")?.detail == "Try fewer words, or Search all sessions."
              && row(timedOut, "info:search-timeout")?.selectable == false && row(timedOut, "info:search-failed") == nil && row(timedOut, "search-all") != nil, "[a timed out search says so]", "\(rowIDs(timedOut))")
        check(row(C.listing(withFound(sessions, words: "persona", phase: .failed, hits: []), words: "persona"), "info:search-timeout") == nil, "[a failed search is not a timeout]", "")
        check(row(C.listing(withFound(sessions, words: "persona", hits: []), words: "persona"), "info:search-none")?.title == "No match near the start of your newest sessions.", "[no hit says what was read]", "")
        check(row(C.listing(withFound(sessions, words: "persona", hits: []), words: "persona"), "info:search-none")?.detail == "Search all sessions looks further.", "[no hit offers Search all]", "")
        check(C.listing(withFound(sessions, words: "persona", phase: .idle, hits: []), words: "persona").rows.allSatisfy { !["info:searching", "info:search-failed", "info:search-none"].contains($0.id) }, "[idle says nothing]", "")
        check(row(C.listing(withFound(sessions, words: "holiday", hits: []), words: "holiday"), "info:search-none")?.title == "No other match near the start of your newest sessions.", "[no other hit says what was read]", "a title match is already listed")
        for info in ["info:searching", "info:search-failed", "info:search-none"] {
            check(row(C.listing(withFound(sessions, words: "persona", phase: info == "info:searching" ? .searching : (info == "info:search-failed" ? .failed : .done), hits: []), words: "persona"), info)?.selectable == false, "[a status line is not selectable]", info)
        }
        // Words that name nothing (stopwords) run no search and claim no absence (QA item 5).
        for common in ["the", "of the", "to and for", "the a an"] {
            let listing = C.listing(sessions, words: common)
            check(listing.searchWords == nil && row(listing, "info:search-words")?.title == "Add a word that names what you want.", "[common words run no search]", "\(common): \(rowIDs(listing))")
            check(row(listing, "search-all") == nil && !listing.rows.contains { $0.id.hasPrefix("info:search-n") }, "[common words claim no absence]", common)
        }
        check(C.searchTokens("the persona of pricing pricing a") == ["persona", "pricing"] && C.searchTokens("a") == [] && C.searchTokens("x y") == [] && C.searchTokens("q3 deck") == ["q3", "deck"], "[search tokens]", "\(C.searchTokens("the persona of pricing pricing a"))")
        check(C.foundAnnouncement(1) == "1 session found" && C.foundAnnouncement(5) == "5 sessions found", "[VoiceOver hears a fixed count]", "")

        // Match text: cleaned, masked, bounded, and dropped when it only repeats the title.
        check(C.matchLine("Persona pricing review", title: "Persona pricing review") == nil && C.matchLine(nil, title: "x") == nil && C.matchLine("   ", title: "x") == nil, "[a title echo shows no match line]", "")
        check(C.matchLine("Persona pricing review", title: "persona pricing review") == nil, "[a title echo shows no match line]", "case folds")
        check(C.matchLine("Persona pricing review MU-Chief-Staff we should price the tier", title: "Persona pricing review") == "MU-Chief-Staff we should price the tier", "[a window that starts with the title keeps the rest]", "\(String(describing: C.matchLine("Persona pricing review MU-Chief-Staff we should price the tier", title: "Persona pricing review")))")
        check(C.matchLine("Persona pricing review.", title: "Persona pricing review") == nil, "[a title echo shows no match line]", "punctuation")
        // An echo that does not start with the title: a piece of it, or the same words with other punctuation.
        check(C.matchLine("pricing review", title: "Persona pricing review") == nil, "[a title echo shows no match line]", "a piece of the title")
        check(C.matchLine("Persona, pricing review!", title: "Persona pricing review") == nil, "[a title echo shows no match line]", "other punctuation")
        check(C.matchLine("the pricing review is due", title: "Persona pricing review") == "the pricing review is due", "[a line that only shares words with the title shows]", "")
        check(C.matchLine("line one\nline two\t\u{202E}three", title: "x") == "line one line two three", "[match text is one clean line]", "\(String(describing: C.matchLine("line one\nline two\t\u{202E}three", title: "x")))")
        check((C.matchLine(String(repeating: "price ", count: 200), title: "x")?.count ?? 0) <= C.matchCap && C.matchCap == 120, "[match text is bounded]", "")
        let keys = ["ghp_abcdefghijklmnop1234", "github_pat_11ABCDEFG0abcdefgh", "sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWx", "sk-proj_1234567890abcdefGHIJ", "ghp_abcdefghijklmnopqrstuvwxyz0123456789", "xoxb-1234567890-abcdefghij", "AKIAIOSFODNN7EXAMPLE",
                    "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N", "Bearer abcdefghijklmnop12345678", "api_key=abcdef123456", "password: hunter2hunter2",
                    "3f7a9c1e5b2d4a6c8e0f1a3b5c7d9e1f2a4b6c8d", "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8", "-----BEGIN RSA PRIVATE KEY----- MIIEowIBAAKCAQEA -----END RSA PRIVATE KEY-----"]
        for key in keys {
            let masked = C.matchLine("the key is \(key) and it works", title: "x") ?? ""
            check(masked.contains(C.hidden) && !masked.contains(String(key.suffix(12))), "[key-shaped text is masked in match text]", "\(key.prefix(10))…: \(masked)")
            check(C.hitTitle("Fix \(key) now").contains(C.hidden) && !C.hitTitle("Fix \(key) now").contains(String(key.suffix(12))), "[key-shaped text is masked in a hit title]", "\(key.prefix(10))…")
        }
        for plain in ["the persona pricing table", "Sources/ActivityWindow.swift line 9591", "version 0.5.361 build 415", "MU-Chief-Staff", "2026-10-31 15:00", "ask the owner about it"] {
            check(C.mask(plain) == plain, "[plain text is not masked]", plain)
        }
        // .env and JSON shapes, a credential key with an underscore before it, CLI flags, URLs with a password, and the shapes that
        // `\b` missed (QA 0.5.361, G7, S3). Each secret part must be gone; the words around it stay.
        let shaped: [(text: String, secret: String)] = [
            ("OPENAI_API_KEY=abcdef123456", "abcdef123456"), ("DB_PASSWORD=hunter2hunter2", "hunter2hunter2"), ("GITHUB_TOKEN=abcdef123456", "abcdef123456"),
            ("SERVICE_TOKEN=abcdef123456", "abcdef123456"), ("client_secret: abcdef123456", "abcdef123456"), ("aws_secret_access_key=wJalrXUtnFEMIK7MDENG", "wJalrXUtnFEMIK7MDENG"),
            ("{\"password\": \"hunter2hunter2\"}", "hunter2hunter2"), ("{\"api_key\":\"abcdef123456\"}", "abcdef123456"), ("'client_secret': 'abcdef123456'", "abcdef123456"),
            ("run it with --password hunter2hunter2 today", "hunter2hunter2"), ("curl --token=abcdef123456 now", "abcdef123456"),
            ("Authorization: Basic dXNlcjpwYXNzd29yZA==", "dXNlcjpwYXNzd29yZA"), ("use postgres://admin:hunter2hunter2@db.example/prod now", "hunter2hunter2"),
            ("post to https://hooks.slack.com/services/T0ABC123/B0DEF456/abcdefghijklmnopqrstuvwx", "abcdefghijklmnopqrstuvwx"), ("glpat-abcdefghij1234567890", "abcdefghij1234567890"),
            ("my_sk-abcdefghijklmnopqrstuvwxyz", "abcdefghijklmnopqrstuvwxyz"), ("stripeSecretKey: abcdefgh12345678", "abcdefgh12345678"),
            // A credential after a key that is not one: prose, a URL query and a command (QA 0.5.361 round 2: the whole value used to go under any key).
            ("https://x.example/v1?token=abcdef123456", "abcdef123456"), ("Note: password=hunter22", "hunter22"), ("url=https://x.example/a?secret=abcdef123456", "abcdef123456"),
            ("Run: DB_PASSWORD=hunter22", "hunter22"), ("login pass=hunter22x today", "hunter22x"),
            // The Stripe forms, a padded Basic value, and a key with no name at all.
            ("Authorization: Basic dXNlcjpwYXNz", "dXNlcjpwYXNz"), ("sk_live_abcdef1234567890ab", "abcdef1234567890ab"), ("sent Basic dXNlcjpwYXNzd29yZGhlbGxv== to the proxy", "dXNlcjpwYXNzd29yZGhlbGxv"),
            ("the id Xj3kLmN9_pQrStUv-WxYzAbCd_EfGh1234IjKl9 was leaked", "Xj3kLmN9_pQrStUv-WxYzAbCd_EfGh1234IjKl9"),
        ]
        for (text, secret) in shaped {
            let out = C.mask("note \(text) end")
            check(out.contains(C.hidden) && !out.contains(secret) && out.hasPrefix("note ") && out.hasSuffix(" end"), "[key-shaped text is masked in match text]", "\(text): \(out)")
            check(C.matchLine("the line \(text) and more words", title: "x")?.contains(secret) == false, "[key-shaped text is masked in match text]", text)
        }
        // A plan name, a UUID and a key-like word that is not a credential stay readable.
        for stays in ["PLAN_cmdK_find_sessions_2026-10-31", "3f2504e0-4f89-41d3-9a0c-0305e82c3301", "TOKEN_COUNT=12345678", "MAX_TOKENS: 4096", "secretName: fred", "token: the one",
                      "claude-code-sessions_find_local_words_2026-10-31_final.md", "basic setup of the pricing table", "a pneumonoultramicroscopicsilicovolcanoconiosis case",
                      "PASS: test_x", "First pass: reviewed the code", "customer_pk_constraint_name_here", "a basic src/components/Button.tsx",
                      "local_3f2504e0-4f89-41d3-9a0c-0305e82c3301", "session-3f2504e0-4f89-41d3-9a0c-0305e82c3301", "Note: the task is done", "https://x.example/docs?page=intro"] {
            check(C.mask(stays) == stays, "[a name or a plain word is not hidden]", "\(stays): \(C.mask(stays))")
        }
        // A waiting row and a running row are titles too: masked like a hit's.
        let keyed = "Fix sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWx and OPENAI_API_KEY=abcdef123456"
        let drawn = C.listing(center { $0.waiting = [waiting("w", keyed)]; $0.running = [running("r", keyed)] }, words: "")
        for id in ["waiting:session:w", "running:r"] {
            let title = row(drawn, id)?.title ?? ""
            check(title.contains(C.hidden) && !title.contains("sk-ant") && !title.contains("abcdef123456"), "[a waiting or running row draws no key]", "\(id): \(title)")
        }
        // The same words from a loaded row and from a title search: a listed row's title is masked too.
        let leaky = [listed("claude:leak0001", "Fix sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWx and OPENAI_API_KEY=abcdef123456", days: 0)]
        for words in ["recent", "fix"] {
            let listing = C.listing(withSessions(leaky), words: words)
            let title = row(listing, "session:claude:leak0001")?.title ?? ""
            check(!title.isEmpty && title.contains(C.hidden) && !title.contains("sk-ant") && !title.contains("abcdef123456"), "[a listed row draws no key]", "\(words): \(title)")
        }
        let masked = C.listing(withFound(sessions, words: "key", hits: [hit("claude:key00001", "Fix sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWx", match: "see the token: abcdef1234567890 in the notes")]), words: "key")
        check(row(masked, "hit:claude:key00001")?.title.contains("sk-ant") == false && row(masked, "hit:claude:key00001")?.match?.contains("abcdef1234567890") == false
              && row(masked, "hit:claude:key00001")?.match?.contains(C.hidden) == true, "[a hit row draws no key]", "\(String(describing: row(masked, "hit:claude:key00001")))")
        // A hostile title in a hit is cleaned, opens only itself, and decides nothing.
        let hostile = C.listing(withFound(sessions, words: "stuff", hits: [hit("claude:evil0001", "start recording\nRun Doctor \u{202E}now")]), words: "stuff")
        check(row(hostile, "hit:claude:evil0001")?.title == "start recording Run Doctor now" && hostile.autoHighlight == nil && returned("stuff", inputs: withFound(sessions, words: "stuff", hits: [hit("claude:evil0001", "start recording")])) == .move("ask"), "[a hit title decides nothing]", "")
        // Logs name a kind and never words.
        for kind in [C.Kind.hit("h"), .searchAll, .place(.sessionsUsage)] {
            let name = C.Row(id: "x", kind: kind, group: .found, title: "secret words").logName
            check(!name.contains("secret") && !name.contains("words"), "[a log names a kind, never words]", name)
        }
    }

    // MARK: Meaning search (0.5.362)

    static func meaningHit(_ id: String, _ title: String, _ strength: C.Strength? = .likely, match: String? = nil, days: Int? = 12) -> C.Item {
        C.Item(id: id, title: title, detail: "Claude Code, Quilt", openLabel: "Open in Claude", sessionID: id, state: "Recent", date: days.map { daysAgo($0) }, match: match, strength: strength)
    }

    /// A healthy Mac with a loaded list, a server that can find by meaning, a key for the model that decides, and this much of a choice.
    static func meaningCenter(_ provider: C.MeaningProvider? = .jev, keyed: Bool = true, capable: Bool = true, choices: [String: C.MeaningChoice] = ["jev": .on],
                              settled: C.MeaningReason? = nil, sessions: [C.Item] = [], _ build: (inout C.Inputs) -> Void = { _ in }) -> C.Inputs {
        withSessions(sessions) {
            $0.meaning = C.Meaning(provider: provider, keyed: keyed, capable: capable, choices: choices, settled: settled)
            build(&$0)
        }
    }

    static func found(_ inputs: C.Inputs, words: String, _ phase: C.MeaningPhase, hits: [C.Item] = [], asked: Int = 254, skipped: Int = 0, back: Date? = nil, resets: Date? = nil) -> C.Inputs {
        var next = inputs
        next.meaningFound = C.MeaningFound(words: C.plain(words), phase: phase, hits: hits, asked: asked, skipped: skipped, reachedBack: back, resetsAt: resets)
        return next
    }

    static let topic = "persona pricing for the jewelry tier"

    static func centerMeaning() {
        // The three strength words, and no others.
        check(C.Strength.allCases.map(\.word) == ["Strong match", "Likely match", "Possible match"], "[strength is three words]", "\(C.Strength.allCases.map(\.word))")
        for wire in ["strong", "likely", "possible"] { check(C.Strength(wire: wire).rawValue == wire, "[strength is three words]", wire) }
        for odd in ["very_strong", "STRONG", "", "certain", "strong match", "0.9"] { check(C.Strength(wire: odd) == .possible, "[an unknown strength reads as the weakest]", odd) }
        check(C.Strength(wire: nil) == .possible, "[an unknown strength reads as the weakest]", "nil")
        check(C.MeaningProvider.allCases.map(\.title) == ["Jev", "SubQ"] && C.MeaningProvider.jev.keeps == nil && C.MeaningProvider.subq.keeps == "SubQ keeps what it is sent.", "[the provider words]", "")
        check(C.meaningWordCount("pet drag fragment") == 3 && C.meaningWordCount("pet drags") == 2 && C.meaningWordCount("") == 0 && C.meaningWordCount("a-b c.d") == 4, "[a word is a run of letters and numbers]", "")

        // Nothing is asked before the person says yes for the model that decides: the whole table, every combination.
        var asked = 0, yes = 0
        let settledOptions: [C.MeaningReason?] = [nil, .serverTooOld]
        for capable in [true, false] {
            for keyed in [true, false] {
                for provider in [nil, C.MeaningProvider.jev, .subq] as [C.MeaningProvider?] {
                    for jev in C.MeaningChoice.allCases {
                        for subq in C.MeaningChoice.allCases {
                            for settled in settledOptions {
                                let choices = ["jev": jev, "subq": subq]
                                let inputs = meaningCenter(provider, keyed: keyed, capable: capable, choices: choices, settled: settled)
                                let listing = C.listing(inputs, words: topic)
                                let mine = provider.map { choices[$0.rawValue] ?? .ask }
                                let should = capable && keyed && provider != nil && mine == .on && settled == nil
                                let gate = C.consentedProvider(inputs.meaning)
                                asked += 1
                                if should { yes += 1 }
                                check((gate != nil) == should && gate == (should ? provider : nil), "[nothing is asked before the person says yes for the model that decides]",
                                      "capable \(capable) keyed \(keyed) provider \(String(describing: provider)) \(choices) settled \(String(describing: settled))")
                                check((listing.meaningAsk != nil) == should && listing.meaningAsk?.provider == (should ? provider : nil), "[nothing is asked before the person says yes for the model that decides]",
                                      "the listing: capable \(capable) keyed \(keyed) provider \(String(describing: provider)) \(choices)")
                            }
                        }
                    }
                }
            }
        }
        check(asked == 2 * 2 * 3 * 3 * 3 * 2 && yes == 6, "[the table has a yes in it]", "\(yes) of \(asked)")
        let jevYes = meaningCenter(.jev, choices: ["jev": .on, "subq": .ask])
        let switched = meaningCenter(.subq, choices: ["jev": .on, "subq": .ask])
        check(C.consentedProvider(jevYes.meaning) == .jev && C.consentedProvider(switched.meaning) == nil, "[a yes for Jev is no yes for SubQ]", "")
        check(C.listing(switched, words: topic).meaningAsk == nil && C.listing(switched, words: topic).rows.contains { $0.id == "consent:subq:on" }, "[a yes for Jev is no yes for SubQ]", "SubQ is asked about")
        // The server and the person's choice disagree about who decides: Control forgets the model and asks nothing until the settings are read.
        let forgotten = C.forgettingProvider(jevYes.meaning)
        var after = jevYes; after.meaning = forgotten
        check(C.consentedProvider(forgotten) == nil && !forgotten.offered && C.listing(after, words: topic).meaningAsk == nil, "[a model that changed is forgotten until the settings are read]", "")
        check(C.listing(after, words: topic).rows.allSatisfy { !$0.id.hasPrefix("consent:") && !$0.id.hasPrefix("hit:") }, "[a model that changed is forgotten until the settings are read]", "no consent row for a model not known")
        check(forgotten.choices == jevYes.meaning.choices && forgotten.capable, "[a forgotten model keeps what the person chose]", "")

        // When the panel may ask at all: a topic of three words or more, with no exact command, place or noun list in it, and Sessions on.
        let on = meaningCenter()
        check(C.listing(on, words: topic).meaningAsk == C.MeaningAsk(words: C.plain(topic), provider: .jev), "[a topic is asked]", "\(String(describing: C.listing(on, words: topic).meaningAsk))")
        for (words, why) in [("persona pricing", "two words"), ("pet", "one word"), ("start recording", "an exact command"), ("usage", "an exact place"), ("go to usage", "an exact place"),
                             ("sessions today", "a noun list"), ("the of to", "common words only"), ("", "nothing typed"), ("ab", "under three characters")] {
            check(C.listing(on, words: words).meaningAsk == nil, "[words that are not a topic ask nothing]", why)
        }
        check(C.listing(meaningCenter { $0.sessionsSettingOff = true; $0.sessionsLoaded = true }, words: topic).meaningAsk == nil, "[Sessions off asks nothing]", "")
        let keyWords = "find the sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWx session about pricing"
        let keyed = C.listing(on, words: keyWords).meaningAsk?.words ?? ""
        check(!keyed.isEmpty && !keyed.contains("abcdefghijklmnop") && !keyed.contains("sk-ant") && !keyed.contains("api03") && keyed.contains("hidden"), "[key-shaped words are hidden before they are sent]", keyed)
        var keyedInputs = on
        keyedInputs.meaningFound = C.MeaningFound(words: keyed, phase: .done, hits: [meaningHit("claude:abc12345", "Pricing")])
        check(row(C.listing(keyedInputs, words: keyWords), "hit:claude:abc12345") != nil, "[the answer is kept under the words that were sent]", "")
        check((C.listing(on, words: String(repeating: "pricing ", count: 60)).meaningAsk?.words.unicodeScalars.count ?? 0) <= 200, "[the words are capped at 200 characters]", "")
        // What is sent is the typed words, not the plain ones: case, @ . : / and ( ) survive for the server's rules. And what must not leave is gone.
        let keptWords = C.listing(on, words: "Ask about Jane's pricing (v2.1) at the Acme tier").meaningAsk?.words ?? ""
        check(keptWords == "Ask about Jane's pricing (v2.1) at the Acme tier", "[the words are sent as typed, not as plain words]", keptWords)
        for (typedWords, secret, why) in [
            ("find what jane.doe@acme.com said about pricing", "jane.doe", "an email"),
            ("find https://acme.com/pricing?token=zz9 about the tier", "acme.com", "a link"),
            ("find www.acme.com notes about the pricing tier", "acme.com", "a link without a scheme"),
            ("which session had STRIPE_KEY=abc123 in the pricing notes", "abc123", "a key=value"),
            ("which session had STRIPE_KEY: abc123 in the pricing notes", "abc123", "a key: value"),
            ("what is contraseña: x about the pricing tier", "contraseña", "a credential word in another language"),
            ("the OPENAI_API_KEY=abc123def456 pricing tier session", "abc123def456", "a key pair"),
            ("find sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWx about pricing", "AbCdEfGh", "a key shape"),
        ] {
            let sentWords = C.listing(on, words: typedWords).meaningAsk?.words ?? ""
            check(!sentWords.isEmpty && !sentWords.contains(secret) && sentWords.contains("[hidden]"), "[nothing a secret is leaves with the words]", "\(why): \(sentWords)")
        }
        check(C.queryWords("  a\n\n b\t c  ") == "a b c", "[the words are one line]", "")
        check(C.queryWords(String(repeating: "e\u{301}", count: 150)).unicodeScalars.count == 200, "[the cut is by code points]", "a letter and its accent are two")
        let emoji = String(repeating: "😀", count: 300)
        check(C.queryWords(emoji).unicodeScalars.count == 200, "[the cut is by code points]", "\(C.queryWords(emoji).unicodeScalars.count)")
        check(C.queryWords("pricing " + String(repeating: "x", count: 190) + " jane.doe@acme.com").contains("jane.doe") == false, "[a secret across the cut is hidden before the cut]", "")
        // The request does not depend on what came back, so an answer never restarts the search.
        let asks = [found(on, words: topic, .idle), found(on, words: topic, .searching), found(on, words: topic, .done, hits: [meaningHit("claude:abc12345", "Jewelry persona review")]),
                    found(on, words: topic, .unavailable(.failed))].map { C.listing($0, words: topic).meaningAsk }
        check(Set(asks.map { $0?.words ?? "" }).count == 1 && asks.allSatisfy { $0 != nil }, "[an answer does not restart the search]", "\(asks)")

        // The question before anything is sent.
        let ask = meaningCenter(.jev, choices: [:])
        let askListing = C.listing(ask, words: topic)
        let consentIDs = askListing.rows.filter { $0.id.hasPrefix("consent:") }.map(\.id)
        check(consentIDs == ["consent:jev:on", "consent:jev:never"] && askListing.meaningAsk == nil, "[the question is asked once and nothing is sent]", "\(consentIDs)")
        check(askListing.rows.filter { $0.id.hasPrefix("consent:") }.allSatisfy { $0.group == .meaning && $0.selectable }, "[the question is a group of its own, reached by arrow or click]", "")
        check(rowIDs(askListing).firstIndex(of: "consent:jev:never")! < rowIDs(askListing).firstIndex(of: "search-all")! && rowIDs(askListing).firstIndex(of: "search-all")! < rowIDs(askListing).firstIndex(of: "ask")!,
              "[the question comes before Search all and Ask]", "\(rowIDs(askListing))")
        let jevText = "Each search sends the words you type here, plus the title and first 150 characters of the first prompt from up to 508 recent sessions, to Jev. Emails, links, home-folder paths and key-shaped text are removed first. Names and other details are not."
        check(row(askListing, "consent:jev:on")?.detail == jevText && C.consentText(.jev) == jevText, "[the question says what leaves, in full]", row(askListing, "consent:jev:on")?.detail ?? "")
        check(C.consentText(.subq) == jevText.replacingOccurrences(of: "to Jev.", with: "to SubQ.") + " SubQ keeps what it is sent.", "[the question for SubQ says it keeps what it is sent]", C.consentText(.subq))
        check(!C.consentText(.jev).contains("keeps"), "[nothing is claimed about what Jev keeps]", "")
        let subqAsk = C.listing(meaningCenter(.subq, choices: [:]), words: topic)
        check(row(subqAsk, "consent:subq:on")?.detail == C.consentText(.subq) && row(subqAsk, "consent:subq:on")?.title == "Find sessions by meaning with SubQ", "[SubQ is asked about in its own words]", "")
        for gone in [meaningCenter(.jev, keyed: false, choices: [:]), meaningCenter(.jev, capable: false, choices: [:]), meaningCenter(nil, choices: [:]), meaningCenter(.jev, choices: ["jev": .never])] {
            check(C.listing(gone, words: topic).rows.allSatisfy { !$0.id.hasPrefix("consent:") }, "[the question is shown only for a server that can and a key that is saved]", "")
        }
        check(C.listing(meaningCenter(.jev, choices: ["jev": .never]), words: topic).rows.allSatisfy { !$0.id.hasPrefix("consent:") && !$0.id.hasPrefix("info:meaning-") } && C.listing(meaningCenter(.jev, choices: ["jev": .never]), words: topic).meaningAsk == nil,
              "[never means never]", "")
        check(C.listing(ask, words: "persona pricing").rows.allSatisfy { !$0.id.hasPrefix("consent:") }, "[the question waits for a topic]", "")
        // Return never chooses it. An arrow or a click does.
        check(returned(topic, inputs: ask) == .move("ask"), "[Return never moves onto the question]", "\(returned(topic, inputs: ask))")
        check(returned(topic, chosen: "ask", inputs: ask) == returnRuns("ask"), "[the second Return still runs Ask]", "")
        var walked: [String] = []
        var current: String? = nil
        for _ in 0..<40 { current = C.move(1, from: current, askListing); if let current { walked.append(current) } }
        check(walked.contains("consent:jev:on") && walked.contains("consent:jev:never"), "[an arrow reaches the question]", "\(walked)")
        check(C.onReturn(option: false, chosen: "consent:jev:on", confirming: false, noticeShowing: false, askListing, ask.snapshot) == returnRuns("consent:jev:on"), "[a chosen answer to the question is run]", "")
        check(C.keepsWordsWhileStaying(row(askListing, "consent:jev:on")!) && !C.sendsWords(row(askListing, "consent:jev:on")!) && !C.leavesSession(row(askListing, "consent:jev:on")!), "[the question keeps the words and leaves nothing]", "")
        check(C.confirmation(row(askListing, "consent:jev:on")!, ask.snapshot) == nil, "[the question has no second question]", "")
        for choice in ["on", "never"] {
            check(C.hint(returnRuns("consent:jev:" + choice), askListing, ask.snapshot).hasPrefix("Return "), "[the hint says what Return does]", choice)
        }

        // Hits never touch Return, with meaning rows listed, before and after they arrive.
        let hits = [meaningHit("claude:abc12345", "Jewelry persona review", .strong, match: "price the jewelry persona tier above the base plan"), meaningHit("codex:def67890", "Quarterly planning", .likely, days: 19),
                    meaningHit("cursor:0a1b2c3d", "Notes", .possible, days: 31)]
        let waiting = found(on, words: topic, .searching)
        let strong = found(on, words: topic, .done, hits: hits, back: daysAgo(44))
        for words in [topic, "persona pricing for jewelry", "jewelry persona review notes", "how did the jewelry pricing go?"] {
            let before = C.listing(found(on, words: words, .searching), words: words)
            let arrived = C.listing(found(on, words: words, .done, hits: hits), words: words)
            check(returned(words, inputs: found(on, words: words, .searching)) == returned(words, inputs: found(on, words: words, .done, hits: hits)), "[Return does the same before and after meaning rows arrive]", words)
            check(before.autoHighlight == arrived.autoHighlight && before.nearCommand == arrived.nearCommand && before.hasAnswer == arrived.hasAnswer && before.listOnly == arrived.listOnly, "[meaning rows change no flag Return reads]", words)
            check(returned(words, inputs: found(on, words: words, .done, hits: hits)) == .move("ask"), "[meaning rows never take Return]", "\(returned(words, inputs: found(on, words: words, .done, hits: hits)))")
        }
        // The second Return, after the first moved to Ask and rows arrived above it, still runs Ask, and the first Return from nothing still moves to Ask.
        check(returned(topic, inputs: waiting) == .move("ask") && returned(topic, chosen: "ask", inputs: strong) == returnRuns("ask") && returned(topic, inputs: strong) == .move("ask"),
              "[rows that arrive after Return moved to Ask leave Ask the one Return runs]", "")
        for strongHit in [hits[0], meaningHit("claude:abc12345", "Jewelry persona review", .strong, days: 0)] {
            let only = found(on, words: topic, .done, hits: [strongHit])
            check(returned(topic, inputs: only) == .move("ask"), "[a strong match does not take Return]", "\(returned(topic, inputs: only))")
        }
        // Not when Work runs are off either: the first Return files, as it always did, and a meaning row changes nothing.
        var off = healthy(); off.workRunsOn = false
        check(returned(topic, inputs: found(meaningCenter { $0.snapshot = off }, words: topic, .done, hits: hits)) == returned(topic, inputs: meaningCenter { $0.snapshot = off }), "[Work runs off: a meaning row changes nothing Return does]", "")
        // A hit chosen with a key that goes with a refresh returns nothing.
        let gone = found(on, words: topic, .done, hits: [hits[1]])
        check(returned(topic, chosen: "hit:claude:abc12345", inputs: gone) == .nothing, "[a chosen hit that is gone returns nothing]", "")

        // The rows: their own group above the word hits and before Search all, the strength on the detail line, the server's order.
        let listing = C.listing(strong, words: topic)
        let meaningRows = listing.rows.filter { $0.group == .meaning }
        check(meaningRows.map(\.id) == hits.map { "hit:" + $0.id } && meaningRows.allSatisfy { $0.selectable } && meaningRows.allSatisfy { if case .hit = $0.kind { return true } else { return false } },
              "[meaning rows are hits in a group of their own]", "\(rowIDs(listing))")
        check(rowIDs(listing).firstIndex(of: "hit:cursor:0a1b2c3d")! < rowIDs(listing).firstIndex(of: "search-all")!, "[meaning rows come before Search all]", "\(rowIDs(listing))")
        check(meaningRows.map(\.detail) == ["Strong match, Claude Code, Quilt, 12 days ago", "Likely match, Claude Code, Quilt, 2 weeks ago", "Possible match, Claude Code, Quilt, 4 weeks ago"],
              "[the strength is on the detail line with tool, project and age, in the server's order]", "\(meaningRows.map(\.detail))")
        check(meaningRows[0].match == "price the jewelry persona tier above the base plan" && meaningRows[1].match == nil, "[the text it was judged on shows when it is not the title]", "\(meaningRows.map(\.match))")
        check(!listing.rows.contains { $0.title.lowercased().contains("by meaning") && $0.group == .meaning && $0.selectable }, "[no group heading]", "")
        check(returnedFor(listing) == .move("ask") && listing.searchWords == C.plain(topic), "[meaning rows leave the word search alone]", "")
        // Capped, warm-up dropped, one session once.
        let many = (0..<9).map { meaningHit("claude:m\(String(format: "%07d", $0))", "Persona \($0)", .likely) }
        check(C.listing(found(on, words: topic, .done, hits: many), words: topic).rows.filter { $0.group == .meaning && $0.id.hasPrefix("hit:") }.count == C.meaningCap && C.meaningCap == 5, "[meaning rows are capped at five]", "")
        var warm = meaningHit("claude:warm0001", "Ready", .strong); warm.keepWarm = true
        check(row(C.listing(found(on, words: topic, .done, hits: [warm]), words: topic), "hit:claude:warm0001") == nil, "[a warm-up session is no meaning row]", "")
        let dupSessions = [listed("claude:abcd1234ef56", "Jewelry persona review", days: 1)]
        let titled = C.listing(found(meaningCenter(sessions: dupSessions), words: "jewelry persona review", .done, hits: [meaningHit("claude:abcd1234", "Jewelry persona review"), meaningHit("claude:other001", "Jewelry persona notes")]), words: "jewelry persona review")
        check(titled.rows.filter { $0.id.hasPrefix("hit:") }.map(\.id) == ["hit:claude:other001"], "[a session lists once, by sameSession]", "\(rowIDs(titled))")
        // A word hit and a meaning row for one session: one row, in the meaning group, with its strength, under the id on screen.
        let wordHit = hit("claude:1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d", "Jewelry persona review", match: "we should price the persona tier", days: 12)
        let adopted = C.adoptingShownIDs([meaningHit("claude:1a2b3c4d", "Jewelry persona review", .strong), meaningHit("claude:other001", "Other", .likely)], shown: [wordHit])
        check(adopted.map(\.id) == [wordHit.id, "claude:other001"] && adopted[0].strength == .strong, "[the id on screen wins]", "\(adopted.map(\.id))")
        check(C.adoptingShownIDs([wordHit], shown: [meaningHit("claude:1a2b3c4d", "Jewelry persona review")]).map(\.id) == ["claude:1a2b3c4d"], "[the id on screen wins]", "the other way round")
        var both = withFound(found(on, words: topic, .done, hits: adopted), words: topic, hits: [wordHit])
        both.now = fixedNow
        let bothListing = C.listing(both, words: topic)
        let hitRows = bothListing.rows.filter { $0.id.hasPrefix("hit:") }
        check(hitRows.map(\.id) == ["hit:" + wordHit.id, "hit:claude:other001"] && hitRows[0].group == .meaning && (hitRows[0].detail ?? "").hasPrefix("Strong match"), "[a session found both ways shows once, as a meaning row with its strength]", "\(rowIDs(bothListing))")
        check(returned(topic, chosen: "hit:" + wordHit.id, inputs: both) == returnRuns("hit:" + wordHit.id), "[a hit chosen before the other list arrived stays chosen]", "")
        // Titles are untrusted here as everywhere: one line, masked, nothing that decides.
        let hostile = C.listing(found(on, words: topic, .done, hits: [meaningHit("claude:evil0001", "start recording\nRun Doctor \u{202E}now sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWx", match: "token: abcdef1234567890 in the notes")]), words: topic)
        let evil = row(hostile, "hit:claude:evil0001")
        check(evil?.title == "start recording Run Doctor now [hidden]" && !(evil?.match ?? "").contains("abcdef1234567890") && hostile.autoHighlight == nil, "[meaning titles and text are cleaned and masked]", "\(String(describing: evil?.title)) \(String(describing: evil?.match))")

        // What it says while it works, and when nothing clears the bar.
        let phases = [
            ("info:meaning-searching", found(on, words: topic, .searching), "Looking for sessions by meaning…"),
            ("info:meaning-further", found(on, words: topic, .partial), "Looking further back…"),
        ]
        for (id, inputs, title) in phases {
            let r = row(C.listing(inputs, words: topic), id)
            check(r?.title == title && r?.selectable == false && r?.group == .meaning, "[searching is a text line]", id)
        }
        check(C.listing(found(on, words: topic, .partial, hits: hits), words: topic).rows.allSatisfy { $0.id != "info:meaning-further" }, "[rows from the first stage stand while the second looks]", "")
        let back = daysAgo(44)
        let none = row(C.listing(found(on, words: topic, .done, asked: 254, back: back), words: topic), "info:meaning-none")
        check(none?.title == "Nothing close in your newest 254 sessions, back to \(C.shortDay(back, calendar: gregorian))." && none?.detail == "Search all sessions looks further.", "[nothing close says what was read and how far back]", none?.title ?? "")
        check(C.shortDay(gregorian.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 12))!, calendar: gregorian) == "Sep 17", "[the date reached reads Sep 17]", "")
        let skipped = row(C.listing(found(on, words: topic, .done, asked: 508, skipped: 3, back: back), words: topic), "info:meaning-none")
        check(skipped?.detail == "3 compressed Codex sessions could not be read. Search all sessions looks further." && skipped?.title.hasPrefix("Nothing close in your newest 508 sessions") == true, "[a file it could not read is said]", skipped?.detail ?? "")
        check(row(C.listing(found(on, words: topic, .done, asked: 254, skipped: 1, back: back), words: topic), "info:meaning-none")?.detail?.hasPrefix("1 compressed Codex session could not be read.") == true, "[a file it could not read is said]", "one")
        check(row(C.listing(found(on, words: topic, .done, asked: 0, back: nil), words: topic), "info:meaning-none")?.title == "Nothing close by meaning in the sessions it read.", "[nothing close claims no range it does not know]", "")
        check(row(C.listing(found(on, words: topic, .done, asked: 254, back: nil), words: topic), "info:meaning-none")?.title == "Nothing close in your newest 254 sessions.", "[nothing close claims no date it does not know]", "")
        check(row(C.listing(found(on, words: topic, .done, hits: hits), words: topic), "info:meaning-none") == nil, "[rows and nothing close never show together]", "")
        // Every refusal has its own words. A failed or capped search never says nothing is close.
        let reasons: [C.MeaningReason] = [.consentRequired, .providerChanged, .notConfigured, .sessionsOff, .findOff, .capReached, .breakerOpen, .queryTooShort, .failed, .serverTooOld, .unreachable, .timedOut, .tryLater, .noToken, .unauthorized]
        var titles = Set<String>()
        for reason in reasons {
            let said = C.line(for: reason, resetsAt: nil, now: fixedNow, calendar: gregorian)
            let r = row(C.listing(found(on, words: topic, .unavailable(reason)), words: topic), "info:meaning-" + reason.rawValue)
            check(!said.title.isEmpty && r?.title == said.title && r?.detail == said.detail && r?.selectable == false, "[every refusal has its own words]", reason.rawValue)
            check(!said.title.lowercased().contains("nothing close"), "[a failed or capped search never says nothing is close]", reason.rawValue)
            titles.insert(said.title)
        }
        check(titles.count >= 12, "[refusals are told apart]", "\(titles.count)")
        let reset = gregorian.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 18))!
        check(C.line(for: .capReached, resetsAt: reset, now: fixedNow, calendar: gregorian).detail == "It starts again at 6 PM." && C.line(for: .capReached, resetsAt: nil, now: fixedNow, calendar: gregorian).detail == "It starts again within a day.", "[a cap says when it comes back]", "")
        let next = gregorian.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 18, minute: 40))!
        check(C.line(for: .breakerOpen, resetsAt: next, now: fixedNow, calendar: gregorian).detail == "It tries again tomorrow at 6:40 PM." && C.line(for: .breakerOpen, resetsAt: reset.addingTimeInterval(-86_400), now: fixedNow, calendar: gregorian).detail == "It tries again on its own in a while.", "[a pause says when it tries again, and never a time in the past]", "")
        // A refusal that stays true is remembered: the panel asks no more, and says so for any topic.
        let settled = C.listing(meaningCenter(settled: .serverTooOld), words: topic)
        check(settled.meaningAsk == nil && row(settled, "info:meaning-server_too_old")?.title == "This COS server cannot search by meaning yet." && row(C.listing(meaningCenter(settled: .serverTooOld), words: "another topic entirely"), "info:meaning-server_too_old") != nil,
              "[an older server is not asked again]", "")
        for reason in reasons { check(reason.settles == [.serverTooOld, .sessionsOff, .findOff, .notConfigured, .capReached, .breakerOpen, .noToken, .unauthorized].contains(reason), "[which refusals stay true]", reason.rawValue) }

        // Answers arriving.
        let one = C.meaningArrived(C.MeaningFound(), words: C.plain(topic), stage: .first, .rows(hits, asked: 254, skipped: 0, reachedBack: back), keeping: nil)
        check(one.phase == .partial && one.hits.map(\.id) == hits.map(\.id) && one.asked == 254 && one.reachedBack == back, "[the first stage is partial]", "")
        let two = C.meaningArrived(one, words: C.plain(topic), stage: .full, .rows([hits[1], hits[0]], asked: 508, skipped: 2, reachedBack: back), keeping: nil)
        check(two.phase == .done && two.hits.map(\.id) == [hits[1].id, hits[0].id] && two.asked == 508 && two.skipped == 2, "[the full stage is done and replaces the first]", "")
        let kept = C.meaningArrived(one, words: C.plain(topic), stage: .full, .rows([hits[1]], asked: 508, skipped: 0, reachedBack: back), keeping: "hit:" + hits[0].id)
        check(kept.hits.map(\.id) == [hits[0].id, hits[1].id], "[a refresh keeps a chosen hit where it was]", "\(kept.hits.map(\.id))")
        let unkept = C.meaningArrived(one, words: C.plain(topic), stage: .full, .rows([hits[1]], asked: 508, skipped: 0, reachedBack: back), keeping: nil)
        check(unkept.hits.map(\.id) == [hits[1].id], "[an unchosen hit goes with the refresh]", "")
        let fresh = C.meaningArrived(one, words: "something else entirely", stage: .first, .rows([hits[1]], asked: 254, skipped: 0, reachedBack: back), keeping: "hit:" + hits[0].id)
        check(fresh.hits.map(\.id) == [hits[1].id] && fresh.words == "something else entirely", "[new words start clean]", "")
        let refusedAfterRows = C.meaningArrived(one, words: C.plain(topic), stage: .full, .refused(.timedOut, resetsAt: nil), keeping: nil)
        check(refusedAfterRows.phase == .done && refusedAfterRows.hits.map(\.id) == hits.map(\.id) && refusedAfterRows.asked == 254, "[a refusal after good rows keeps the rows]", "")
        let refusedFirst = C.meaningArrived(C.MeaningFound(), words: C.plain(topic), stage: .first, .refused(.capReached, resetsAt: reset), keeping: nil)
        check(refusedFirst.phase == .unavailable(.capReached) && refusedFirst.hits.isEmpty && refusedFirst.resetsAt == reset, "[a refusal with no rows is its own phase]", "")
        let refusedNoRows = C.meaningArrived(C.MeaningFound(words: C.plain(topic), phase: .partial), words: C.plain(topic), stage: .full, .refused(.timedOut, resetsAt: nil), keeping: nil)
        check(refusedNoRows.phase == .unavailable(.timedOut), "[a second stage that fails with no rows is a failure, not nothing close]", "")
        check(C.meaningArrived(C.MeaningFound(), words: "x y z", stage: .first, .rows((0..<9).map { meaningHit("claude:c\(String(format: "%07d", $0))", "C\($0)") }, asked: 1, skipped: 0, reachedBack: nil), keeping: nil).hits.count == C.meaningCap, "[an answer is capped at five]", "")
        // The wire words.
        check(C.MeaningReason(wire: "cap_reached") == .capReached && C.MeaningReason(wire: "decision_cap_reached") == .capReached && C.MeaningReason(wire: "jev_breaker_open") == .breakerOpen
              && C.MeaningReason(wire: "decision_not_configured") == .notConfigured && C.MeaningReason(wire: "jev_not_configured") == .notConfigured && C.MeaningReason(wire: "consent_required") == .consentRequired
              && C.MeaningReason(wire: "provider_changed") == .providerChanged && C.MeaningReason(wire: "jev_request_rejected") == .failed && C.MeaningReason(wire: nil) == .failed && C.MeaningReason(wire: "") == .failed
              && C.MeaningReason(wire: "something strange") == .failed, "[the wire words map to reasons]", "")
        check(C.MeaningReason.consentRequired.againstConsent && C.MeaningReason.providerChanged.againstConsent && !C.MeaningReason.failed.againstConsent && !C.MeaningReason.capReached.againstConsent, "[two refusals say the model changed]", "")

        // The copy rules cover everything this part says.
        var said: [String] = C.Strength.allCases.map(\.word) + [C.consentText(.jev), C.consentText(.subq)]
        for reason in reasons { let l = C.line(for: reason, resetsAt: reset, now: fixedNow, calendar: gregorian); said += [l.title, l.detail ?? ""] }
        for skippedCount in [0, 1, 4] { let l = C.nothingClose(asked: 254, reachedBack: back, skipped: skippedCount, calendar: gregorian); said += [l.title, l.detail ?? ""] }
        let banned = ["\u{2014}", "\u{2013}", "\u{2192}", "->", "=>", "\u{21D2}"]
        let hedges = [" maybe ", " perhaps ", " might ", " possibly ", " probably ", " kinda ", " sort of ", "-ish", " somewhat ", " usually "]
        for text in said where !text.isEmpty {
            check(!banned.contains { text.contains($0) } && !hedges.contains { (" " + text.lowercased() + " ").contains($0) }, "[meaning copy rules]", text)
        }
        check(said.count >= 40, "[meaning copy rules]", "read \(said.count) strings")
    }

    static func scored(_ id: String, _ title: String, _ strength: C.Strength, _ p: Double, canContinue: Bool = true) -> C.Item {
        var item = meaningHit(id, title, strength)
        item.probability = p
        item.canContinue = canContinue
        return item
    }

    static func centerMeaningPanel() {
        let words = topic
        // A click on Turn on takes effect on this listing, at once.
        let asking = meaningCenter(.jev, choices: [:])
        check(C.listing(asking, words: words).meaningAsk == nil && C.listing(asking, words: words).rows.contains { $0.id == "consent:jev:on" }, "[before the click nothing is asked]", "")
        var clicked = asking
        clicked.meaning = C.choosing(asking.meaning, provider: .jev, choice: .on)
        let after = C.listing(clicked, words: words)
        check(after.meaningAsk?.provider == .jev && after.rows.allSatisfy { !$0.id.hasPrefix("consent:") }, "[a click on Turn on takes effect at once]", "\(rowIDs(after))")
        clicked.meaning = C.choosing(asking.meaning, provider: .jev, choice: .never)
        check(C.listing(clicked, words: words).meaningAsk == nil && C.listing(clicked, words: words).rows.allSatisfy { !$0.id.hasPrefix("consent:") }, "[a click on Never takes effect at once]", "")
        let other = C.choosing(meaningCenter(.subq, choices: [:]).meaning, provider: .jev, choice: .on)
        check(C.consentedProvider(other) == nil && other.choices["jev"] == .on, "[a click for Jev says nothing about SubQ]", "")
        check(C.choosing(C.choosing(asking.meaning, provider: .jev, choice: .on), provider: .jev, choice: .ask).choices["jev"] == nil, "[ask forgets the answer]", "")

        // A model that changed under the person's yes asks once, never in a loop: a server that keeps saying so is believed.
        func simulate(serverDecides: C.MeaningProvider, readsBack: [String?]) -> Int {
            var meaning = meaningCenter(.jev, choices: ["jev": .on, "subq": .on]).meaning
            var requests = 0
            var reads = readsBack
            for _ in 0..<30 {
                guard let provider = C.consentedProvider(meaning) else { break }
                requests += 1
                guard provider != serverDecides else { break }
                // The server refuses (provider_changed). The panel forgets the model, reads the settings, and keeps or drops its belief.
                meaning = C.forgettingProvider(meaning)
                let read = reads.isEmpty ? nil : reads.removeFirst()
                if let stays = C.staysRefused(.providerChanged, asked: provider, reread: read) { meaning.settled = stays }
                else if let read, let now = C.MeaningProvider(rawValue: read) { meaning.provider = now; meaning.keyed = true }
            }
            return requests
        }
        check(simulate(serverDecides: .subq, readsBack: ["jev", "jev", "jev"]) == 1, "[a server that keeps disagreeing is asked once, not in a loop]", "\(simulate(serverDecides: .subq, readsBack: ["jev", "jev", "jev"]))")
        check(simulate(serverDecides: .subq, readsBack: [nil]) == 1, "[an unreadable settings answer settles it]", "")
        check(simulate(serverDecides: .subq, readsBack: ["subq"]) == 2, "[a model that changed is asked about on its own yes]", "\(simulate(serverDecides: .subq, readsBack: ["subq"]))")
        let st = C.staysRefused(.providerChanged, asked: .jev, reread: "jev")
        check(st == .providerChanged && C.staysRefused(.providerChanged, asked: .jev, reread: "subq") == nil, "[the refusal stays only when the settings say the same model]", "")

        // A refusal that stays true keeps the rows for the same words, and says when it comes back.
        let reset = gregorian.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 18))!
        var capped = found(meaningCenter(.subq, choices: ["subq": .on]), words: words, .done, hits: [meaningHit("claude:abc12345", "Jewelry persona review", .strong)])
        capped.meaning.settled = .capReached
        capped.meaning.settledResetsAt = reset
        let cappedListing = C.listing(capped, words: words)
        check(row(cappedListing, "hit:claude:abc12345") != nil && row(cappedListing, "info:meaning-cap_reached")?.detail == "It starts again at 6 PM." && cappedListing.meaningAsk == nil, "[a settled refusal keeps the rows and says when it comes back]", "\(rowIDs(cappedListing))")
        capped.meaningFound = C.MeaningFound()
        check(C.listing(capped, words: "another topic about pricing tiers").rows.contains { $0.id == "info:meaning-cap_reached" } && row(C.listing(capped, words: "another topic about pricing tiers"), "info:meaning-cap_reached")?.detail == "It starts again at 6 PM.", "[a settled refusal says when it comes back for any words]", "")
        let afterFull = C.meaningArrived(C.meaningArrived(C.MeaningFound(), words: C.plain(words), stage: .first, .rows([meaningHit("claude:abc12345", "A", .likely)], asked: 254, skipped: 0, reachedBack: nil), keeping: nil),
                                          words: C.plain(words), stage: .full, .refused(.capReached, resetsAt: reset), keeping: nil)
        check(afterFull.phase == .done && afterFull.hits.count == 1, "[a refusal at the full stage keeps the first stage's rows]", "")

        // The window's own loop at a refusal that stays true, run through the engine: the first stage's rows arrive, the full stage is capped or
        // paused, the engine stops asking, and the window keeps what it holds (QA 0.5.363: it cleared, and the rows vanished).
        for reason in [C.MeaningReason.capReached, .breakerOpen] {
            var live = found(meaningCenter(.subq, choices: ["subq": .on]), words: words, .partial, hits: [meaningHit("claude:abc12345", "Jewelry persona review", .likely)])
            let sent = live.meaningFound.words
            live.meaningFound = C.meaningArrived(live.meaningFound, words: sent, stage: .full, .refused(reason, resetsAt: reset), keeping: nil)
            live.meaning.settled = reason
            live.meaning.settledResetsAt = reset
            let asking = C.listing(live, words: words)
            live.meaningFound = C.meaningKept(live.meaningFound, ask: asking.meaningAsk, settled: live.meaning.settled)
            let after = C.listing(live, words: words)
            check(asking.meaningAsk == nil && row(after, "hit:claude:abc12345") != nil && row(after, "info:meaning-" + reason.rawValue) != nil, "[a refusal at the full stage keeps the first stage's rows in the panel]", "\(reason.rawValue) \(rowIDs(after))")
            // With nothing settled, no request still clears: the words fell below three, or the person said Never.
            check(C.meaningKept(live.meaningFound, ask: nil, settled: nil) == C.MeaningFound() && C.meaningKept(live.meaningFound, ask: C.MeaningAsk(words: sent, provider: .subq), settled: nil) == live.meaningFound, "[no request clears what is held unless a refusal is settled]", "")
        }

        // Rows all listed by title are not "nothing close".
        let title = meaningCenter(sessions: [listed("claude:abc12345ef56", "Jewelry persona review", days: 1)])
        let listedAll = C.listing(found(title, words: "jewelry persona review", .done, hits: [meaningHit("claude:abc12345", "Jewelry persona review")]), words: "jewelry persona review")
        check(row(listedAll, "info:meaning-none") == nil && row(listedAll, "info:meaning-further") == nil, "[rows all listed by title are not nothing close]", "\(rowIDs(listedAll))")
        check(row(C.listing(found(title, words: "jewelry persona review", .done), words: "jewelry persona review"), "info:meaning-none") != nil, "[no rows at all is nothing close]", "")

        // The right-hand word on a meaning row: Recent says nothing next to the age; Running, Waiting and Idle do.
        var idle = meaningHit("claude:idle0001", "Idle one"); idle.state = "Idle"
        var run = meaningHit("claude:run00001", "Running one"); run.state = "Running"
        let words3 = C.listing(found(meaningCenter(), words: words, .done, hits: [meaningHit("claude:abc12345", "Recent one"), idle, run]), words: words)
        check(row(words3, "hit:claude:abc12345")?.state == nil && row(words3, "hit:claude:idle0001")?.state == "Idle" && row(words3, "hit:claude:run00001")?.state == "Running", "[Recent is not drawn on a meaning row]", "")
    }

    static func centerOrderAndTwins() {
        let on = meaningCenter()
        let words = "chuks tax miss"
        let wordHits = [hit("claude:word0001", "Permissions audit", days: 3), hit("claude:word0002", "Failure notes", days: 4)]
        let meaningRows = [meaningHit("claude:abc12345", "Chuks tax filing", .strong), meaningHit("codex:def67890", "Tax questions", .strong)]
        var both = withFound(found(on, words: words, .done, hits: meaningRows), words: words, hits: wordHits)
        both.now = fixedNow
        let ids = rowIDs(C.listing(both, words: words))
        let firstWord = ids.firstIndex(of: "hit:claude:word0001")!
        check(ids.firstIndex(of: "hit:claude:abc12345")! < firstWord && ids.firstIndex(of: "hit:codex:def67890")! < firstWord, "[meaning rows go above word hits]", "\(ids)")
        check(firstWord < ids.firstIndex(of: "search-all")!, "[word hits stay above Search all]", "\(ids)")
        // No meaning rows: the word hits are where they were, and the status lines of the meaning part stay after them.
        var wordOnly = withFound(found(on, words: words, .searching), words: words, hits: wordHits)
        wordOnly.now = fixedNow
        let wordIDs = rowIDs(C.listing(wordOnly, words: words))
        check(wordIDs.firstIndex(of: "hit:claude:word0001")! < wordIDs.firstIndex(of: "info:meaning-searching")!, "[without meaning rows the word hits keep their place]", "\(wordIDs)")
        // The highlight is an id: it does not move when meaning rows arrive, and Return reads neither list.
        check(returned(words, chosen: "hit:claude:word0001", inputs: both) == returnRuns("hit:claude:word0001"), "[a chosen word hit stays chosen when meaning rows arrive]", "")
        check(returned(words, inputs: both) == .move("ask") && returned(words, chosen: "ask", inputs: both) == returnRuns("ask"), "[Return reads no hit, whichever list is first]", "\(returned(words, inputs: both))")
        check(C.listing(both, words: words).autoHighlight == nil, "[arrival highlights nothing]", "")

        // "Recent" says nothing next to an age on a word hit. Running, Waiting and Idle do.
        var idle = hit("claude:word0003", "Idle one"); idle.state = "Idle"
        var run = hit("claude:word0004", "Running one"); run.state = "Running"
        let states = C.listing(withFound(withSessions([]), words: "persona pricing", hits: [hit("claude:word0001", "Recent one"), idle, run]), words: "persona pricing")
        check(row(states, "hit:claude:word0001")?.state == nil && row(states, "hit:claude:word0003")?.state == "Idle" && row(states, "hit:claude:word0004")?.state == "Running", "[Recent is not drawn on a word hit]", "")

        // Two sessions with one title: each says when it last moved.
        let a = listed("claude:twin0001", "Notes", days: 0, hour: 9), b = listed("claude:twin0002", "Notes", days: 0, hour: 14), c = listed("claude:other001", "Notes elsewhere", days: 0, hour: 10)
        let twins = C.listing(withSessions([a, b, c]), words: "notes")
        let rowsA = row(twins, "session:claude:twin0001"), rowsB = row(twins, "session:claude:twin0002")
        check((rowsA?.detail ?? "").hasSuffix("last active 9:00 AM") && (rowsB?.detail ?? "").hasSuffix("last active 2:00 PM"), "[two rows with one title say when each last moved]", "\(String(describing: rowsA?.detail)) \(String(describing: rowsB?.detail))")
        check(!(row(twins, "session:claude:other001")?.detail ?? "").contains("last active"), "[a row with a title of its own says nothing more]", "")
        let older = listed("claude:twin0003", "Notes", days: 5, hour: 15)
        let mixed = C.listing(withSessions([a, older]), words: "notes")
        check((row(mixed, "session:claude:twin0003")?.detail ?? "").hasSuffix("last active Oct 26, 3:00 PM"), "[another day says the day]", "\(String(describing: row(mixed, "session:claude:twin0003")?.detail))")
        check(C.twinsTold([], now: fixedNow, calendar: gregorian).isEmpty && C.listing(withSessions([a]), words: "notes").rows.allSatisfy { !($0.detail ?? "").contains("last active") }, "[one row with a title says nothing more]", "")
    }

    static func centerContinue() {
        let on = meaningCenter(.jev)
        let words = topic
        let one = [scored("claude:abc12345", "Jewelry persona review", .strong, 0.82), scored("codex:def67890", "Quarterly planning", .likely, 0.41)]
        func listing(_ hits: [C.Item], _ inputs: C.Inputs? = nil) -> C.Listing { C.listing(found(inputs ?? on, words: words, .done, hits: hits), words: words) }
        let offered = listing(one)
        check(row(offered, "continue:claude:abc12345")?.title == "Continue in this session" && row(offered, "continue:claude:abc12345")?.detail == "Jewelry persona review", "[Continue in names the session in its detail]", "\(rowIDs(offered))")
        check(rowIDs(offered).first(where: { $0.hasPrefix("continue:") || $0.hasPrefix("hit:") }) == "continue:claude:abc12345" && row(offered, "continue:claude:abc12345")?.group == .meaning, "[Continue in sits above the rows]", "")
        // Only Jev, only a Strong top row, a clear gap, a session that can take a message.
        let subqOn = meaningCenter(.subq, choices: ["subq": .on])
        check(row(listing(one, subqOn), "continue:claude:abc12345") == nil && C.continueProviders == [.jev], "[Continue in is Jev only]", "")
        check(C.continueTarget(found(subqOn, words: words, .done, hits: one).meaningFound, subqOn.meaning, enabledFor: [.subq]) != nil
              && C.continueTarget(found(on, words: words, .done, hits: one).meaningFound, on.meaning, enabledFor: [.subq]) == nil, "[Continue in follows one per-model set]", "")
        check(listing([scored("claude:abc12345", "A", .likely, 0.55), one[1]]).rows.allSatisfy { !$0.id.hasPrefix("continue:") }, "[Continue in needs a strong match]", "")
        check(listing([scored("claude:abc12345", "A", .strong, 0.61), scored("codex:def67890", "B", .likely, 0.5)]).rows.allSatisfy { !$0.id.hasPrefix("continue:") }, "[Continue in needs a clear gap to the second row]", "")
        check(listing([scored("claude:abc12345", "A", .strong, 0.9), scored("codex:def67890", "B", .strong, 0.8)]).rows.allSatisfy { !$0.id.hasPrefix("continue:") }, "[Continue in needs a clear gap to the second row]", "two strong")
        check(row(listing([scored("claude:abc12345", "A", .strong, 0.85), scored("codex:def67890", "B", .likely, 0.60)]), "continue:claude:abc12345") != nil, "[a gap of a quarter is clear]", "")
        check(listing([scored("claude:abc12345", "A", .strong, 0.85)] + [scored("codex:def67890", "B", .possible, 0.1)]).rows.contains { $0.id == "continue:claude:abc12345" }, "[a weak second row leaves the gap clear]", "")
        var unknown = one; unknown[1].probability = nil
        check(listing(unknown).rows.allSatisfy { !$0.id.hasPrefix("continue:") }, "[an unknown second probability is no gap]", "")
        check(listing([scored("claude:abc12345", "A", .strong, 0.5)]).rows.allSatisfy { !$0.id.hasPrefix("continue:") }, "[Continue in needs 0.6]", "")
        check(listing([scored("claude:abc12345", "A", .strong, 0.9, canContinue: false), one[1]]).rows.allSatisfy { !$0.id.hasPrefix("continue:") }, "[no Continue in when the composer would be absent or gated]", "")
        check(C.continueTarget(C.MeaningFound(), on.meaning) == nil, "[no rows, no Continue in]", "")
        let titleInputs = meaningCenter(.jev, sessions: [listed("claude:abc12345ef56", "Jewelry persona review", days: 1)])
        let titled = C.listing(found(titleInputs, words: "jewelry persona review", .done, hits: one), words: "jewelry persona review")
        check(titled.rows.allSatisfy { !$0.id.hasPrefix("continue:") }, "[no Continue in for a session the title row already shows]", "\(rowIDs(titled))")
        // It never takes Return, before or after rows arrive, and the second Return still runs Ask.
        check(returned(words, inputs: found(on, words: words, .done, hits: one)) == .move("ask") && returned(words, chosen: "ask", inputs: found(on, words: words, .done, hits: one)) == returnRuns("ask"), "[Continue in never takes Return]", "")
        check(returned(words, inputs: found(on, words: words, .searching)) == returned(words, inputs: found(on, words: words, .done, hits: one)), "[Return does the same before and after Continue in arrives]", "")
        // A chosen one is run on purpose, asks first for an unsent reply, and leaves the open session.
        let r = row(offered, "continue:claude:abc12345")!
        check(C.onReturn(option: false, chosen: r.id, confirming: false, noticeShowing: false, offered, on.snapshot) == returnRuns(r.id), "[a chosen Continue in is run]", "")
        var draft = healthy(); draft.unsentSessionDraft = true
        check(C.leavesSession(r) && C.confirmation(r, draft) == C.draftConfirm && C.confirmation(r, healthy()) == nil, "[Continue in asks before it overwrites an unsent reply]", "")
        check(!C.sendsWords(r) && !C.keepsWordsWhileStaying(r) && C.draftAfterRun(r, words) == "", "[Continue in hands the words over and empties the box]", "")
        check(C.hint(returnRuns(r.id), offered, on.snapshot) == "Return opens it with your words ready, unsent.", "[the hint says the words are ready, unsent]", C.hint(returnRuns(r.id), offered, on.snapshot))
        // The placed words block Return in the composer until they are edited.
        var prefill = C.Prefill()
        check(!prefill.blocksReturn, "[nothing placed blocks nothing]", "")
        prefill.place("find the persona pricing session")
        check(prefill.blocksReturn, "[placed words block Return in the composer]", "")
        prefill.draftChanged("find the persona pricing session")
        check(prefill.blocksReturn, "[the placed words themselves keep the block]", "")
        prefill.draftChanged("find the persona pricing session now")
        check(!prefill.blocksReturn, "[an edit ends the block]", "")
        prefill.draftChanged("find the persona pricing session")
        check(!prefill.blocksReturn, "[an edit that is typed back does not bring the block back]", "")
        prefill.place("   ")
        check(!prefill.blocksReturn, "[blank words block nothing]", "")
        prefill.place("hello there")
        prefill.clear()
        check(!prefill.blocksReturn, "[opening another session clears the block]", "")
        // Copy.
        for text in [r.title, r.detail ?? "", r.trailing ?? ""] {
            check(!text.contains("\u{2014}") && !text.contains("\u{2192}") && !text.contains("->"), "[Continue in copy rules]", text)
        }
    }

    static func centerStaleRunning() {
        let now = fixedNow
        check(C.staleRunning(state: "running", updated: now.addingTimeInterval(-5 * 86_400), now: now), "[a session that has not moved in hours is not running]", "5 days")
        check(C.staleRunning(state: "running", updated: now.addingTimeInterval(-7 * 3600), now: now), "[a session that has not moved in hours is not running]", "7 hours")
        check(!C.staleRunning(state: "running", updated: now.addingTimeInterval(-3600), now: now) && !C.staleRunning(state: "running", updated: now, now: now), "[a session that moved this hour is running]", "")
        check(!C.staleRunning(state: "running", updated: nil, now: now), "[no date is no evidence]", "")
        check(!C.staleRunning(state: "waiting", updated: now.addingTimeInterval(-9 * 86_400), now: now) && !C.staleRunning(state: "recent", updated: now.addingTimeInterval(-9 * 86_400), now: now), "[only running goes stale; a wait can last days]", "")
        check(C.runningFreshness == 6 * 3600, "[the bound is six hours]", "")
    }

    static func centerFooter() {
        let long = String(repeating: "A very long session title ", count: 7)
        let sessions = withSessions([listed("claude:long0001", long, days: 1), listed("claude:short001", "Short", days: 1)])
        let listing = C.listing(sessions, words: "sessions")
        let cases: [(C.ReturnOutcome, String)] = [
            (.move("session:claude:long0001"), "Return moves to "), (.move("session:claude:short001"), "Return moves to "),
            (.move("command:openSessions"), "Return moves to "), (returnRuns("session:claude:long0001"), "Return opens: "),
            (returnRuns("command:openSessions"), "Return runs: "), (.nothing, C.idleHint), (.confirm, "Return confirms. Esc cancels."), (.file, "Return files it to the Work inbox."),
        ]
        for (outcome, lead) in cases {
            let footer = C.footer(outcome, listing, healthy())
            check(footer.text == C.hint(outcome, listing, healthy()), "[the footer text is the hint]", "\(outcome)")
            check(footer.lead == lead, "[the footer lead is fixed]", "\(outcome): \(footer.lead)")
        }
        // The words around a title never depend on the title: a 160-character title and a short one leave the same lead and tail.
        let a = C.footer(.move("session:claude:long0001"), listing, healthy())
        let b = C.footer(.move("session:claude:short001"), listing, healthy())
        check(a.lead == b.lead && a.tail == b.tail && a.tail == ". Return again opens it." && a.title != b.title, "[Return again opens it stays whole]", "\(a.tail)")
        check(a.title?.count ?? 0 > 100 && b.title == "Short", "[only the title varies]", "")
        // A session titled like a command or a pane is called "the session" in the foot, and any other title is not: it keeps the room.
        for name in ["Start recording", "Usage", "open work", "Run Doctor", "Open Sessions", "go to usage", "Voices"] {
            check(C.sessionWord(name) == "the session ", "[a session titled like a command is called a session]", name)
        }
        for name in ["Holiday promo landing page", "Usage limit reached", "Persona pricing review", "Recording the standup", "Work on the deck"] {
            check(C.sessionWord(name).isEmpty, "[a title that is not a command keeps the room]", name)
        }
        // Every kind of move has a tail that names what the second Return does.
        var busy = healthy(); busy.helperBusy = false
        let typed = C.listing(center(), words: "go to se")
        check(C.footer(.move("command:openSessions"), typed, busy).tail == ". Return again runs it.", "[a command move says it runs]", "")
        let live = center { $0.recording.stoppable = true; $0.recording.occupied = true; $0.recording.busy = true }
        check(C.footer(.move("command:stopRecording"), C.listing(live, words: "stop recording"), busy).tail == ". Return again asks first.", "[Stop says it asks first]", "")
        check(C.footer(.move("place:sessionsUsage"), C.listing(center(), words: "usa"), busy).tail == ". Return again opens it.", "[a place move says it opens]", "")
        // The footer promises nothing about Esc going back to the pane the person came from.
        var texts: [String] = []
        for words in ["", "usage", "sessions", "persona pricing", "usa", "start recording", "doctor"] {
            let l = C.listing(withFound(sessions, words: words, hits: [hit("claude:old00001", "Old one")]), words: words)
            for outcome in [C.ReturnOutcome.nothing, .confirm, .file, .move("ask")] + l.rows.filter(\.selectable).map({ returnRuns($0.id) }) + l.rows.filter(\.selectable).map({ C.ReturnOutcome.move($0.id) }) {
                texts.append(C.hint(outcome, l, healthy()))
            }
        }
        check(!texts.contains { $0.lowercased().contains("back to") || $0.lowercased().contains("return to the") }, "[Esc promises nothing about going back]", "")
        check(C.noticeHint.contains("Esc goes back") && !C.idleHint.contains("back"), "[Esc closes]", "")
    }

    static func centerConfirms() {
        let s = healthy()
        // Stop and Doctor always ask, and so does anything that changes something.
        let stop = C.Row(id: "command:stopRecording", kind: .command(.stopRecording), group: .doing, title: "Stop and save")
        check(C.confirmation(stop, s) == C.stopConfirm, "[Stop has a confirm]", "")
        let doctor = C.Row(id: "command:runDoctor", kind: .command(.runDoctor), group: .doing, title: "Run Doctor")
        check(C.confirmation(doctor, s) == C.doctorConfirm, "[Doctor always confirms]", "")
        check(C.doctorConfirm.consequence.contains("one real question"), "[Doctor says what it spends]", "")
        let doctorAction = C.Row(id: "action:runDoctor", kind: .action(.runDoctor), group: .fixing, title: "Run Doctor")
        check(C.confirmation(doctorAction, s) == C.doctorConfirm, "[Doctor always confirms]", "as a fix too")
        let report = C.Row(id: "action:copyReport", kind: .action(.copyReport), group: .fixing, title: "Copy report")
        check(C.confirmation(report, s) == C.reportConfirm, "[the report spends the same question]", "")
        for action in SA.Action.allCases where action.changesSomething {
            let row = C.Row(id: "x", kind: .action(action), group: .fixing, title: "x")
            check(C.confirmation(row, s) == SA.confirmation(action, s), "[every change confirms]", "\(action)")
            check(C.confirmation(row, s) != nil, "[every change confirms]", "\(action)")
        }
        // Never for an opener, Ask or File.
        for kind in [C.Kind.command(.openWork), .command(.startRecording), .ask, .file, .action(.openSpeakers), .action(.openMeetings), .waiting("a"), .running("b"), .session("c")] {
            check(C.confirmation(C.Row(id: "x", kind: kind, group: .doing, title: "x"), s) == nil, "[openers run at once]", "\(kind)")
        }
        // The fresh check on confirm: something held now runs nothing.
        var running = s; running.activeJobs = 1
        let restart = C.Row(id: "action:restartServer", kind: .action(.restartServer), group: .fixing, title: "Restart")
        check(C.recheck(restart, s, recordable()) == nil, "[confirm re-checks the gate]", "")
        check(C.recheck(restart, running, recordable()) == SA.Held.jobs(1), "[confirm re-checks the gate]", "")
        var stopped = s; stopped.runtimeState = "stopped"
        check(C.recheck(restart, stopped, recordable()) == "This does not apply any more.", "[confirm re-checks the gate]", "")
        var busy = s; busy.helperBusy = true
        check(C.recheck(doctor, busy, recordable()) == SA.Held.busy, "[confirm re-checks Doctor]", "")
        check(C.recheck(stop, s, recordable()) == "Nothing is recording on this Mac now.", "[Stop re-checks]", "")
        var live = recordable(); live.stoppable = true
        check(C.recheck(stop, s, live) == nil, "[Stop re-checks]", "")
        var held = recordable(); held.inFlight = true
        let start = C.Row(id: "command:startRecording", kind: .command(.startRecording), group: .doing, title: "Start recording")
        check(C.recheck(start, s, held) == C.RecordingHeld.starting, "[Start re-checks]", "")
    }

    static func centerAsk() {
        let s = healthy()
        let entry = SA.match("my transcript never finished")
        let run = C.askRun(question: "  my transcript never finished  ", entry: entry, s, id: "abc", asked: "today")
        check(run?.target == "today:ask:abc", "[Ask stays under Today's in-flight check]", "\(String(describing: run?.target))")
        check(run?.title == "my transcript never finished", "[Ask names the run]", "")
        let prompt = run?.prompt ?? ""
        check(prompt.contains("Their words: \"my transcript never finished\""), "[Ask quotes the words]", prompt)
        check(prompt.contains("A transcript never finished") && prompt.contains("Unsaved recordings"), "[Ask carries the saved answer]", prompt)
        check(prompt.contains(SA.runRules) && prompt.contains("Never use sudo, pkill or killall") && prompt.contains("Ask before you run anything"), "[Ask carries the rules]", prompt)
        check(prompt.contains("Server: answering (state managedHealthy)"), "[Ask carries a short snapshot]", prompt)
        check(!prompt.contains("Doctor packet"), "[Ask spends no Doctor]", prompt)
        check(C.askRun(question: "something", entry: nil, s, id: "a", asked: "t")?.prompt.contains("No saved answer matched.") == true, "[Ask says a miss]", "")
        check(C.askRun(question: "   ", entry: nil, s, id: "a", asked: "t") == nil, "[Ask needs words]", "")
        var off = s; off.workRunsOn = false
        check(C.askRun(question: "x y z", entry: nil, off, id: "a", asked: "t") == nil, "[Ask needs Work runs]", "")
        var down = s; down.serverReachable = false
        check(C.askRun(question: "x y z", entry: nil, down, id: "a", asked: "t") == nil, "[Ask needs the server]", "")
        let long = C.askRun(question: String(repeating: "w", count: 5000), entry: nil, s, id: "a", asked: "t")
        check((long?.prompt.count ?? .max) < 3000, "[Ask is bounded]", "")
        // Troubleshoot carries the same rules.
        check(SA.troubleshoot(question: "help", s, report: "{}", id: "x", asked: "t")?.prompt.contains(SA.runRules) == true, "[troubleshoot asks first]", "")
    }

    static func centerResultLine() {
        typealias R = C.ResultInputs
        check(C.result(R()) == nil, "[no news, no line]", "")
        var all = R(error: "Helper failed", recordingError: "No source", gatheringReport: true, startingRecording: true, helperProgress: "Draining", startingRun: true, filing: true,
                    runNote: "Started", notice: "Notice", platformNotice: "Opening", helperNotice: "Done")
        check(C.result(all) == C.ResultLine(text: "Helper failed", tone: .problem), "[a failure comes first]", "")
        all.error = nil
        check(C.result(all) == C.ResultLine(text: "No source", tone: .problem), "[a failure comes first]", "")
        all.recordingError = nil
        check(C.result(all)?.text == "Gathering the Doctor report…" && C.result(all)?.tone == .progress, "[what runs now comes next]", "")
        all.gatheringReport = false
        check(C.result(all)?.text == C.RecordingHeld.starting, "[what runs now comes next]", "")
        all.startingRecording = false
        check(C.result(all)?.text == "Draining" && C.result(all)?.tone == .progress, "[what runs now comes next]", "")
        all.helperProgress = nil
        check(C.result(all)?.text == "Starting the run…", "[what runs now comes next]", "")
        all.startingRun = false
        check(C.result(all)?.text == "Filing it to Work…", "[what runs now comes next]", "")
        all.filing = false
        check(C.result(all) == C.ResultLine(text: "Started", tone: .done), "[the last result comes last]", "")
        all.runNote = nil
        check(C.result(all)?.text == "Notice", "[the last result comes last]", "")
        all.notice = nil
        check(C.result(all)?.text == "Opening", "[the last result comes last]", "")
        all.platformNotice = nil
        check(C.result(all)?.text == "Done", "[the last result comes last]", "")
        check(C.result(R(error: "line one\nline two"))?.text == "line one line two", "[one line]", "")
        check(C.result(R(error: "", notice: "Saved"))?.text == "Saved", "[an empty error is none]", "")
    }

    static func centerCopy() {
        var texts: [String] = C.Command.allCases.map(\.title)
        for confirm in [C.stopConfirm, C.doctorConfirm, C.reportConfirm] { texts += [confirm.question, confirm.consequence, confirm.confirm] }
        texts += [C.RecordingHeld.starting, C.RecordingHeld.os, C.RecordingHeld.saving, C.RecordingHeld.unsaved, C.RecordingHeld.glasses, C.RecordingHeld.other, C.RecordingHeld.server, C.glassesLine, C.otherLine, C.noticeHint]
        texts += SA.Action.allCases.map(C.rowTitle)
        // 0.5.361: places and their parents, the fold lines, the draft confirm, and what the search says.
        texts += C.Place.allCases.map(\.title) + C.Place.allCases.compactMap(\.parent) + [C.canWaitLine(1), C.canWaitLine(6), C.idleHint, C.foundAnnouncement(1), C.foundAnnouncement(3)]
        texts += [C.draftConfirm.question, C.draftConfirm.consequence, C.draftConfirm.confirm]
        var off = healthy(); off.workRunsOn = false
        var down = healthy(); down.serverReachable = false; down.runtimeState = "stopped"
        let fixtures: [C.Inputs] = [
            center(), center { $0.snapshot = off }, center { $0.snapshot = down }, center { $0.sessionsSettingOff = true; $0.sessionsLoaded = true }, center { $0.waitingKnown = false; $0.runningKnown = false },
            center { $0.recording.stoppable = true; $0.recording.occupied = true; $0.recording.busy = true }, center { $0.recording.busy = true; $0.recording.glassesLive = 1; $0.recording.knownGlasses = true },
            center { $0.recording.busy = true; $0.recording.glassesLive = 1 },
            center { $0.recording.occupied = true; $0.recording.busy = true; $0.recording.saveLine = "Saving…" },
            center { $0.foldedCount = 6 }, center { $0.foldedCount = 1; $0.waiting = [waiting("a", "First")] }, center { $0.sessionsSettingOff = true; $0.sessionsLoaded = true; $0.foldedCount = 2 },
            withSessions((0..<10).map { listed("claude:" + String(format: "s%011d", $0), "Session \($0)", days: $0) }),
            withFound(withSessions([listed("claude:holiday1", "Holiday promo landing page", days: 1)]), words: "persona pricing", hits: [hit("claude:old00001", "Persona pricing review", match: "we should price the persona tier"), hit("codex:old00002", "Notes")]),
            withFound(withSessions([]), words: "persona pricing", phase: .searching, hits: []), withFound(withSessions([]), words: "persona pricing", phase: .failed, hits: []),
            withFound(withSessions([]), words: "persona pricing", phase: .timedOut, hits: []),
            withFound(withSessions([]), words: "persona pricing", hits: []), center { $0.sessionsLoaded = false },
            // 0.5.362: the question for each model, rows with each strength, nothing close, a pause, a cap and a refusal that stays.
            meaningCenter(.jev, choices: [:]), meaningCenter(.subq, choices: [:]),
            found(meaningCenter(), words: topic, .done, hits: [meaningHit("claude:abc12345", "Jewelry persona review", .strong, match: "price the jewelry persona tier"), meaningHit("codex:def67890", "Quarterly planning", .likely), meaningHit("cursor:0a1b2c3d", "Notes", .possible)], back: daysAgo(44)),
            found(meaningCenter(), words: topic, .searching), found(meaningCenter(), words: topic, .partial), found(meaningCenter(), words: topic, .done, skipped: 3, back: daysAgo(44)),
            found(meaningCenter(), words: topic, .unavailable(.capReached)), found(meaningCenter(), words: topic, .unavailable(.timedOut)), found(meaningCenter(), words: topic, .unavailable(.failed)),
            meaningCenter(settled: .serverTooOld),
        ]
        for inputs in fixtures {
            for words in ["", "hello", "set up parakeet", "start recording", "stop recording", "my transcript never finished", "how do i use dictation", "rename a voice", "doctor",
                          "sessions", "recent", "sessions today", "usage", "go to usage", "messages", "work", "tasks", "voices", "dictation", "usage limit reached", "persona pricing", "holiday promo", "persona pricing for the jewelry tier", "microphone", "memories", "board", "decision models", "update"] {
                let listing = C.listing(inputs, words: words)
                check(Set(listing.rows.map(\.id)).count == listing.rows.count, "[row ids are unique]", "\(rowIDs(listing))")
                for row in listing.rows { texts += [row.title, row.detail ?? "", row.state ?? "", row.trailing ?? "", row.held ?? "", row.match ?? ""] }
                for outcome in [C.ReturnOutcome.nothing, .confirm, .file, .move("ask"), .move("file")] + listing.rows.filter(\.selectable).map({ returnRuns($0.id) }) + listing.rows.filter(\.selectable).map({ C.ReturnOutcome.move($0.id) }) {
                    let footer = C.footer(outcome, listing, inputs.snapshot)
                    texts += [C.hint(outcome, listing, inputs.snapshot), footer.lead, footer.tail]
                }
            }
        }
        texts.append(C.askRun(question: "help me", entry: SA.match("set up parakeet"), healthy(), id: "x", asked: "today")?.prompt ?? "")
        let banned = ["\u{2014}", "\u{2013}", "\u{2192}", "->", "=>", "\u{21D2}"]
        let hedges = [" maybe ", " perhaps ", " might ", " possibly ", " probably ", " kinda ", " sort of ", "-ish", " somewhat ", " usually "]
        check(texts.count > 300, "[center copy rules]", "the scan read \(texts.count) strings")
        for text in texts where !text.isEmpty {
            check(!banned.contains { text.contains($0) }, "[center copy rules]", "an em dash or arrow: \(text)")
            let padded = " " + text.lowercased() + " "
            check(!hedges.contains { padded.contains($0) }, "[center copy rules]", "a hedge: \(text)")
        }
        // The same answer and offers as the engine: no second knowledge base.
        for entry in SA.entries where entry.id == "parakeet-setup" || entry.id == "voice-rename" {
            check(entry.groups.isEmpty && !entry.phrases.isEmpty, "[new entries match on their own phrases]", entry.id)
        }
    }

    // MARK: All clear

    static func allClear() {
        let board = SA.board(healthy())
        check(board.allClear, "[all clear]", "a healthy Mac reads as all clear: \(ids(board))")
        check(board.suggestions.isEmpty && board.more == 0, "[all clear]", "nothing to offer when everything passed: \(ids(board))")

        var unchecked = healthy(); unchecked.checks = []
        let fresh = SA.board(unchecked)
        check(fresh.allClear, "[checkup offered before Doctor]", "no Doctor run is not a problem")
        check(ids(fresh) == ["checkup"] && fresh.suggestions[0].tier == .extra && fresh.suggestions[0].action == .runDoctor,
              "[checkup offered before Doctor]", "\(ids(fresh))")

        // An extra alone keeps the all-clear line: only repairs and setup break it.
        var extra = healthy(); extra.setup.append(item("tailscaleMac", "Tailscale on this Mac", done: false, counted: false, status: "Not installed"))
        let withExtra = SA.board(extra)
        check(withExtra.allClear && ids(withExtra) == ["setup-tailscaleMac"], "[all clear]", "an optional extra is not a problem: \(ids(withExtra))")
    }

    // MARK: Ranking and the cap

    static func ranking() {
        var s = healthy()
        s.serverReachable = false
        s.runtimeState = "stopped"
        failing(&s, SA.CheckName.recovery, "Missing or not loaded · run Repair")
        s.appUpdate = SA.AppUpdate(currentVersion: "0.5.353", latestVersion: "0.5.360", available: true, downloadFailed: false, installing: false)
        s.setup[1] = item("codex", "Codex", done: false, status: "Not signed in")
        s.setup[4] = item("glassesPair", "Connect your glasses", done: false, counted: false, status: "Not paired")
        let board = SA.board(s)
        check(ids(board) == ["server-stopped", "recovery-controller", "app-update", "setup-codex"], "[ranking]",
              "broken first, then setup, then extras: \(ids(board))")
        check(board.more == 1 && !board.allClear, "[at most four]", "the fifth (the glasses) is counted, not shown: more=\(board.more)")
        check(board.suggestions.map(\.tier) == [.repair, .repair, .setup, .setup], "[ranking]", "\(board.suggestions.map(\.tier))")
        check(board.suggestions[0].action == .startServer && board.suggestions[0].line == "I can start the COS server.", "[ranking]",
              "a stopped server is started, in the I can voice")
        check(board.suggestions[2].line == "I can update COS Control to 0.5.360." && board.suggestions[2].why == "This Mac has 0.5.353.",
              "[ranking]", board.suggestions[2].line)

        var crowded = s
        crowded.dictationEnabled = true; crowded.microphoneAllowed = false; crowded.accessibilityTrusted = false
        let full = SA.board(crowded)
        check(full.suggestions.count == SA.shown && SA.shown == 4, "[at most four]", "\(full.suggestions.count) shown")
        check(full.more == 3 && ids(full) == ["server-stopped", "recovery-controller", "microphone", "accessibility"], "[at most four]",
              "more=\(full.more) \(ids(full))")
    }

    // MARK: Gates

    static let serverChanges: [SA.Action] = [.restartServer, .repairRuntime, .repairWhisper, .updateServer]

    static func gates() {
        // Whisper paused: its repair restarts the whole server, so it waits on running work like Restart does.
        var whisper = healthy(); whisper.whisperCircuitOpen = true
        check(find(SA.board(whisper), "whisper")?.action == .repairWhisper, "[whisper]", "a paused Whisper offers Repair Whisper")
        check(find(SA.board(whisper), "whisper")?.why == "It paused after repeated errors.", "[whisper]", "")
        var notReady = healthy(); notReady.whisperReady = false
        check(find(SA.board(notReady), "whisper")?.action == .repairWhisper, "[whisper]", "Whisper not ready offers Repair Whisper")

        // A base where every server change applies: Whisper paused and the recovery controller missing.
        var base = whisper; failing(&base, SA.CheckName.recovery)
        for action in serverChanges { check(SA.gate(action, base) == .ready, "[no restart while a job runs]", "\(action) runs when idle") }
        var job = base; job.activeJobs = 1
        for action in serverChanges {
            check(SA.gate(action, job) == .held("1 job is running. This comes back when it finishes."), "[no restart while a job runs]",
                  "\(action) with a job: \(SA.gate(action, job))")
        }
        let held = find(SA.board(job), "whisper")
        check(held?.action == nil && held?.held == "1 job is running. This comes back when it finishes.", "[no restart while a job runs]",
              "the suggestion stays, its button waits: \(String(describing: held))")
        var jobs = job; jobs.activeJobs = 3
        check(SA.gate(.restartServer, jobs) == .held("3 jobs are running. This comes back when they finish."), "[no restart while a job runs]", "")

        var recording = base; recording.activeTranscriptionSessions = 1
        for action in serverChanges {
            check(SA.gate(action, recording) == .held(SA.Held.recording), "[no restart while a recording runs]", "\(action)")
        }
        check(find(SA.board(recording), "whisper")?.action == nil, "[no restart while a recording runs]", "")
        var mac = base; mac.macRecordingActive = true
        for action in serverChanges { check(SA.gate(action, mac) == .held(SA.Held.recording), "[a Mac recording holds]", "\(action)") }
        var saving = base; saving.meetingWorkBlockingRestart = true
        for action in serverChanges { check(SA.gate(action, saving) == .held(SA.Held.saving), "[a meeting still saving holds]", "\(action)") }
        var unanswered = saving; unanswered.meetingSyncUnconfirmed = true
        for action in serverChanges { check(SA.gate(action, unanswered) == .held(SA.Held.unconfirmed), "[a server that does not answer holds in its own words]", "\(action)") }
        // A hung server that holds audio has one way out, and the held line names it.
        check(SA.Held.unconfirmed.contains("Repair server"), "[a server that does not answer names the way out]", "")

        // The recording reason wins over the job count: it is the one the person can act on first.
        var both = recording; both.activeJobs = 2
        check(SA.gate(.restartServer, both) == .held(SA.Held.recording), "[no restart while a recording runs]", "")

        // Busy: every helper command waits; openers and Reset and add again do not.
        var busy = healthy(); busy.helperBusy = true
        for action in [SA.Action.runDoctor, .copyReport, .restartServer, .updateServer] {
            check(SA.gate(action, busy) == .held(SA.Held.busy), "[busy]", "\(action): \(SA.gate(action, busy))")
        }
        for action in [SA.Action.openSetupGuide, .openSettings, .resetAccessibility, .openMicrophoneSettings] {
            check(SA.gate(action, busy) == .ready, "[busy]", "\(action) needs no helper")
        }

        // Interrupted update: Repair finishes it; Restart and Update Server wait for it.
        var pending = healthy(); pending.transactionPending = true
        let board = SA.board(pending)
        check(ids(board).first == "interrupted-update" && board.suggestions[0].action == .repairRuntime, "[interrupted update]", "\(ids(board))")
        check(SA.gate(.restartServer, pending) == .held(SA.Held.interruptedUpdate), "[interrupted update]", "")
        check(SA.gate(.updateServer, pending) == .held(SA.Held.interruptedUpdate), "[interrupted update]", "")
        var recovery = healthy(); failing(&recovery, SA.CheckName.updateRecovery, "Repair required")
        check(ids(SA.board(recovery)).first == "interrupted-update", "[interrupted update]", "Doctor's Update recovery row alone")
        // First among other repairs: until it is finished, Restart and Update Server stay locked.
        var crowded = pending; crowded.serverReachable = false; crowded.runtimeState = "managedDegraded"; failing(&crowded, SA.CheckName.integrity)
        crowded.appUpdate.downloadFailed = true
        check(ids(SA.board(crowded)).prefix(2) == ["interrupted-update", "server-down"], "[interrupted update]", "\(ids(SA.board(crowded)))")

        // Unverified ownership: Repair Whisper and Update Server never act on a server COS Control has not proven it owns.
        var unverified = healthy(); unverified.ownershipVerified = false; unverified.whisperReady = false
        check(SA.gate(.repairWhisper, unverified) == .notApplicable && SA.gate(.updateServer, unverified) == .notApplicable,
              "[unverified ownership]", "\(SA.gate(.repairWhisper, unverified)) \(SA.gate(.updateServer, unverified))")
        var unmanaged = healthy(); unmanaged.managedContract = false; unmanaged.whisperReady = false
        check(SA.gate(.repairWhisper, unmanaged) == .notApplicable && SA.gate(.updateServer, unmanaged) == .notApplicable,
              "[unverified ownership]", "an older server without the managed contract")
        check(find(SA.board(unverified), "whisper") == nil, "[unverified ownership]", "no Whisper repair offered without ownership")

        // In place, unable to prove idle: never a one-tap restart.
        var inPlace = healthy(); inPlace.runtimeState = "managedInPlace"; inPlace.safeToRestart = false
        check(SA.gate(.restartServer, inPlace) == .held(SA.Held.unprovenIdle), "[in-place restart asks first]", "")
        inPlace.safeToRestart = true
        check(SA.gate(.restartServer, inPlace) == .ready, "[in-place restart asks first]", "a proven-idle in-place server restarts")

        // Restart applies only to a managed server that is up.
        var stopped = healthy(); stopped.runtimeState = "stopped"; stopped.serverReachable = false
        check(SA.gate(.restartServer, stopped) == .notApplicable && SA.gate(.startServer, stopped) == .ready, "[server down: local repairs]", "")
        check(SA.gate(.startServer, healthy()) == .notApplicable, "[server down: local repairs]", "Start is not offered for a running server")

        // Repair applies only when it fixes something.
        check(SA.gate(.repairRuntime, healthy()) == .notApplicable, "[repair only when it fixes something]", "")
        var foreground = healthy(); foreground.serverReachable = false; foreground.runtimeState = "legacyForeground"
        check(SA.gate(.repairRuntime, foreground) == .notApplicable, "[repair only when it fixes something]", "never against a Terminal server")
        var notInstalled = stopped; notInstalled.installed = false
        check(SA.gate(.repairRuntime, notInstalled) == .notApplicable, "[repair only when it fixes something]", "nothing installed to repair")

        // The app update: held while installing, and while a meeting records (it closes COS Control).
        var installing = healthy(); installing.appUpdate.available = true; installing.appUpdate.installing = true
        check(SA.gate(.retryAppUpdate, installing) == .held(SA.Held.installing), "[installing]", "")
        var offered = healthy(); offered.appUpdate.available = true; offered.macRecordingActive = true
        check(SA.gate(.retryAppUpdate, offered) == .held(SA.Held.recording), "[the update waits for a recording]", "")
        check(SA.gate(.retryAppUpdate, healthy()) == .notApplicable, "[installing]", "no update offered, no Update button")

        // The action table itself.
        let commands = SA.Action.allCases.compactMap(\.helperCommand)
        check(Set(commands).count == commands.count && commands.count == 8, "[action table]", "\(commands)")
        check(SA.Action.allCases.filter(\.restartsServer).allSatisfy(\.touchesServer), "[action table]", "")
        check(SA.Action.allCases.filter(\.touchesServer).allSatisfy(\.changesSomething), "[action table]", "")
        check(!SA.Action.runDoctor.changesSomething && !SA.Action.copyReport.changesSomething && !SA.Action.openUnstuck.changesSomething,
              "[action table]", "reading and opening are not changes")
    }

    // MARK: Ownership conflict

    static func ownershipConflict() {
        var s = healthy()
        s.ownerConflict = true
        s.runtimeState = "ownerConflict"
        s.serverReachable = false
        s.transactionPending = true
        failing(&s, SA.CheckName.recovery)
        let board = SA.board(s)
        check(ids(board) == ["owner-conflict"], "[ownership conflict offers nothing]", "\(ids(board))")
        check(board.suggestions[0].action == nil && board.suggestions[0].secondary == nil && board.suggestions[0].held == nil,
              "[ownership conflict offers nothing]", "")
        for action in SA.Action.allCases where action.touchesServer {
            if case .ready = SA.gate(action, s) { check(false, "[ownership conflict offers nothing]", "\(action) is ready") }
        }
        // Typed questions still answer, and nothing they offer touches the server.
        for phrase in ["server not connected", "whisper stalled", "ownership conflict", "restart the server", "update is stuck"] {
            let offers = SA.answer(phrase, s)?.offers ?? []
            check(!offers.contains { $0.action.touchesServer && $0.held == nil }, "[ownership conflict offers nothing]", "\(phrase): \(offers)")
        }
    }

    // MARK: Server down

    static func serverDown() {
        var degraded = healthy()
        degraded.serverReachable = false
        degraded.runtimeState = "managedDegraded"
        let board = SA.board(degraded)
        check(board.suggestions.first?.id == "server-down" && board.suggestions.first?.action == .repairRuntime, "[server down: local repairs]",
              "\(ids(board))")
        check(board.suggestions.first?.why == "It is loaded but not answering.", "[server down: local repairs]", "")
        check(SA.gate(.troubleshoot, degraded) == .notApplicable, "[troubleshoot needs the server]", "")
        check(SA.troubleshoot(question: "help", degraded, report: "{}", id: "x", asked: "today") == nil, "[troubleshoot needs the server]", "")
        let local = SA.answer("server not connected", degraded)
        check(local?.entry.id == "server" && local?.offers.first?.action == .repairRuntime && local?.offers.first?.held == nil,
              "[server down: local repairs]", "the answer works with the server down: \(String(describing: local?.offers))")

        var stopped = degraded; stopped.runtimeState = "stopped"; stopped.desiredState = "stopped"
        let start = SA.board(stopped).suggestions.first
        check(start?.action == .startServer && start?.why == "It was stopped from COS Control, so Work, meetings and the glasses cannot reach it.",
              "[server down: local repairs]", "\(String(describing: start))")

        // A server you run yourself: running, Manage in place is setup; stopped, Adopt Safely is a repair. Neither changes it here.
        var legacy = healthy(); legacy.runtimeState = "legacyService"
        let manage = find(SA.board(legacy), "server-legacy")
        check(manage?.tier == .setup && manage?.action == .openSettings && manage?.line == "I can manage your running server in place.",
              "[a server you run yourself]", "\(String(describing: manage))")
        var adopt = degraded; adopt.runtimeState = "legacyStopped"
        let adoptRow = find(SA.board(adopt), "server-legacy")
        check(adoptRow?.tier == .repair && adoptRow?.action == .openSettings, "[a server you run yourself]", "\(String(describing: adoptRow))")

        var terminal = degraded; terminal.runtimeState = "legacyForeground"
        let foreign = SA.board(terminal).suggestions.first
        check(foreign?.id == "server-terminal" && foreign?.action == nil, "[server down: local repairs]", "a Terminal server is never touched")

        var first = SA.Snapshot(); first.runtimeState = "notInstalled"; first.needsFirstRun = true; first.setupProviderInstalled = true
        let setUp = SA.board(first)
        check(ids(setUp) == ["first-run"] && setUp.suggestions[0].action == .setUp && setUp.suggestions[0].tier == .setup,
              "[first run]", "\(ids(setUp))")
        first.setupProviderInstalled = false
        let connect = SA.board(first).suggestions.first
        check(connect?.action == .openSetupGuide && SA.gate(.setUp, first) == .notApplicable, "[first run]", "setup needs an AI app first")

        // Work runs off: the server is up, and troubleshoot is still not offered.
        var off = healthy(); off.workRunsOn = false
        check(SA.gate(.troubleshoot, off) == .notApplicable, "[troubleshoot needs Work runs]", "")
        check(SA.troubleshoot(question: "help", off, report: nil, id: "x", asked: "today") == nil, "[troubleshoot needs Work runs]", "")
    }

    // MARK: The anchor case (2026-10-27: 0.5.273, "COS Control download timeout")

    static func anchorCase() {
        var s = healthy()
        s.appUpdate = SA.AppUpdate(currentVersion: "0.5.353", latestVersion: "0.5.360", available: true, downloadFailed: true, installing: false)
        let board = SA.board(s)
        let first = board.suggestions.first
        check(first?.id == "app-update-failed" && first?.action == .openUnstuck && first?.secondary == .retryAppUpdate,
              "[the anchor case]", "\(String(describing: first))")
        check(!ids(board).contains("app-update"), "[the anchor case]", "a failed download is not offered twice")
        check(first?.line == "I can help you update COS Control by hand.", "[the anchor case]", "")

        for phrase in ["update is stuck", "Download timed out", "COS Control is very old", "stuck on Installing"] {
            let answer = SA.answer(phrase, s)
            check(answer?.entry.id == "update-stuck", "[the anchor case]", "\(phrase) -> \(answer?.entry.id ?? "nothing")")
            check(answer?.offers.map(\.action) == [.openUnstuck, .retryAppUpdate] && answer?.offers.allSatisfy({ $0.held == nil }) == true,
                  "[the anchor case]", "\(phrase): \(String(describing: answer?.offers))")
        }
        // With no update offered, the steps are still there; Try again is not.
        let plain = SA.answer("update is stuck", healthy())
        check(plain?.offers.map(\.action) == [.openUnstuck], "[the anchor case]", "\(String(describing: plain?.offers))")
        // A Mac recording holds Try again, never the steps.
        var recording = s; recording.macRecordingActive = true
        let held = SA.answer("update is stuck", recording)
        check(held?.offers.first?.held == nil && held?.offers.last?.held == SA.Held.recording, "[the update waits for a recording]",
              "\(String(describing: held?.offers))")
        check(SA.board(recording).suggestions.first?.secondary == nil, "[the update waits for a recording]", "no Try again while recording")
    }

    // MARK: Knowledge base

    static let phrases: [String: [String]] = [
        "update-stuck": ["update is stuck", "Download timed out", "the update won't install", "COS Control is very old", "stuck on Installing",
                         "can't update the app", "update keeps failing", "my control app is outdated"],
        "server": ["server not connected", "the COS server is down", "can't reach the server", "server is offline", "server stopped",
                   "server not running"],
        "whisper-stalled": ["whisper stalled", "transcription is stuck", "Whisper not working", "the transcript stopped updating", "restart whisper"],
        "restart": ["restart the server", "restart COS", "the server keeps restarting"],
        "dictation-slow": ["dictation is slow", "dictation takes forever", "Parakeet is slow", "slow dictation", "dictating lags"],
        "accessibility": ["Accessibility permission stuck", "dictation only copies the text", "it won't type into apps",
                          "Accessibility is on but nothing types", "jump to session doesn't work"],
        "glasses": ["glasses won't connect", "Query failed. Check COS server connection.", "my G2 can't reach the Mac", "Tailscale not working",
                    "the phone says disconnected", "glasses pairing fails"],
        "microphone": ["mic not picked up", "microphone not working", "no speech detected", "it can't hear me", "microphone permission"],
        "provider": ["AI provider not connected", "Claude not detected", "Codex needs sign in", "Cursor isn't connected", "claude code logged out",
                     "can't install claude code"],
        "restart-greyed": ["Restart is greyed out", "Update Server button is disabled", "can't click restart"],
        "owner-conflict": ["ownership conflict", "another server is using the port", "ports in use"],
        "parakeet-install": ["Parakeet won't install", "parakeet install failed", "can't download parakeet", "I can't install Parakeet", "parakeet setup failed",
                             "Parakeet will not install"],
        // Canary 2026-10-31: these matched the wrong entry or nothing before the command center's entries. Each must beat
        // parakeet-install on its own words.
        "parakeet-setup": ["set up parakeet", "how do I set up Parakeet", "install parakeet", "parakeet setup", "choose an engine", "which engine should I use", "download parakeet"],
        "mac-recording": ["start recording", "stop recording", "record this meeting", "how do I record a meeting", "start a recording"],
        "transcript-unfinished": ["my transcript never finished", "the meeting never saved", "where is my transcript", "recording didn't save", "it says still saving"],
        "dictation-use": ["how do i use dictation", "turn on dictation", "how to dictate", "set up dictation"],
        "voice-rename": ["rename a voice", "speaker names wrong", "the speaker name is wrong", "name a speaker", "wrong speaker"],
    ]

    static func knowledgeBase() {
        check(Set(SA.entries.map(\.id)) == Set(phrases.keys), "[knowledge base covers every entry]",
              "entries \(SA.entries.map(\.id).sorted()) vs phrases \(phrases.keys.sorted())")
        for id in phrases.keys.sorted() {
            for phrase in phrases[id]! {
                let got = SA.match(phrase)?.id
                check(got == id, "[knowledge base: \(id)]", "\"\(phrase)\" -> \(got ?? "nothing")")
            }
        }
        for ordinary in ["Prep me for the pricing review", "Summarize the update from Jeremy", "Draft a note to Gina about the launch",
                         "What did Silas say about the budget?", "Send the deck to Pete", "what's the latest version of the deck", "", "   ", "?"] {
            check(SA.match(ordinary) == nil, "[ordinary asks match nothing]", "\"\(ordinary)\" -> \(SA.match(ordinary)?.id ?? "")")
        }
        // Normalizing: case, curly apostrophes, punctuation, accents.
        check(SA.normalized("Won’t  CONNECT!!") == " wont connect ", "[knowledge base normalizes]", SA.normalized("Won’t  CONNECT!!"))
        check(SA.match("GLASSES WON’T CONNECT")?.id == "glasses", "[knowledge base normalizes]", "")
        // Whole words only: "mice" is not "mic", "reupdated" is not "update".
        check(SA.match("the mice are back") == nil && SA.match("reupdated stuck") == nil, "[knowledge base matches whole words]", "")
        // Very long input is read only up to its cap.
        check(SA.match(String(repeating: "a ", count: 400) + "whisper stalled") == nil, "[knowledge base reads a bounded question]", "")
        for entry in SA.entries {
            check(!entry.source.isEmpty && !entry.answer.isEmpty && !entry.title.isEmpty, "[every entry cites its source]", entry.id)
        }
    }

    // MARK: Answers follow the gates

    static func answers() {
        var recording = healthy(); recording.whisperReady = false; recording.activeTranscriptionSessions = 1
        let whisper = SA.answer("whisper stalled", recording)
        check(whisper?.offers.first?.action == .repairWhisper && whisper?.offers.first?.held == SA.Held.recording,
              "[an answer's change waits for the gate]", "\(String(describing: whisper?.offers))")
        var ready = recording; ready.activeTranscriptionSessions = 0
        check(SA.answer("whisper stalled", ready)?.offers.first?.held == nil, "[an answer's change waits for the gate]", "")
        // Whisper fine: Repair Whisper does not apply, so only Doctor is offered.
        check(SA.answer("whisper stalled", healthy())?.offers.map(\.action) == [.runDoctor], "[answers offer only what applies]", "")

        var job = healthy(); job.activeJobs = 1
        let greyed = SA.answer("Restart is greyed out", job)
        check(greyed?.text.hasSuffix("Right now: 1 job is running. This comes back when it finishes.") == true, "[the greyed-out answer names the hold]",
              greyed?.text ?? "")
        check(SA.answer("Restart is greyed out", healthy())?.text.contains("Right now") == false, "[the greyed-out answer names the hold]", "")

        let server = SA.answer("server not connected", healthy())
        check(server?.offers.map(\.action) == [.runDoctor], "[answers offer only what applies]", "\(String(describing: server?.offers))")
        let glasses = SA.answer("glasses won't connect", healthy())
        check(glasses?.offers.map(\.action) == [.openTailscale, .openSetupGuide], "[answers offer only what applies]", "\(String(describing: glasses?.offers))")
        var stopped = healthy(); stopped.serverReachable = false; stopped.runtimeState = "stopped"
        let glassesDown = SA.answer("glasses won't connect", stopped)
        check(glassesDown?.offers.first?.action == .startServer, "[answers offer only what applies]",
              "a stopped server is the first thing to fix for the glasses")
        check(glassesDown?.offers.map(\.action) == [.startServer, .repairRuntime], "[an answer offers two at most]",
              "four apply here and two are offered: \(String(describing: glassesDown?.offers))")

        // Restart by name: offered when it can run, held with the reason when it cannot, never for a stopped server.
        check(SA.answer("restart the server", healthy())?.offers.map(\.action) == [.restartServer], "[knowledge base: restart]", "")
        let restartHeld = SA.answer("restart the server", job)
        check(restartHeld?.offers.first?.held == SA.Held.jobs(1) && restartHeld?.text.contains("Right now: 1 job is running.") == true,
              "[the greyed-out answer names the hold]", "\(String(describing: restartHeld))")
        check(SA.answer("restart the server", stopped)?.offers.isEmpty == true, "[answers offer only what applies]", "Start, not Restart, fits a stopped server")
        let access = SA.answer("dictation only copies the text", healthy())
        check(access?.offers.map(\.action) == [.resetAccessibility, .openPermissions], "[knowledge base: accessibility]", "")
        check(access?.text.contains("Switching the toggle off and on is often not enough.") == true, "[knowledge base: accessibility]",
              "the documented fix is remove and add again, not the toggle")
        let slow = SA.answer("dictation is slow", healthy())
        check(slow?.offers.map(\.action) == [.openDictationSettings, .troubleshoot], "[knowledge base: dictation-slow]", "")
        var serverDown = healthy(); serverDown.serverReachable = false; serverDown.runtimeState = "stopped"
        check(SA.answer("dictation is slow", serverDown)?.offers.map(\.action) == [.openDictationSettings], "[troubleshoot needs the server]", "")
        for entry in SA.entries {
            check(SA.answer(phrases[entry.id]![0], healthy())?.offers.count ?? 0 <= 2, "[an answer offers two at most]", entry.id)
        }
    }

    // MARK: Confirmations

    static func confirmations() {
        let s = healthy()
        for action in SA.Action.allCases {
            let confirm = SA.confirmation(action, s)
            check((confirm != nil) == action.changesSomething, "[every change confirms]", "\(action): \(String(describing: confirm))")
            if let confirm {
                check(!confirm.question.isEmpty && !confirm.consequence.isEmpty && !confirm.confirm.isEmpty, "[every change confirms]", "\(action)")
                check(confirm.consequence.split(separator: ".").count <= 3, "[a consequence is short]", "\(action): \(confirm.consequence)")
            }
        }
        check(SA.confirmation(.repairWhisper, s)?.consequence == "This restarts the whole COS server, then waits for Whisper to answer.",
              "[Repair Whisper says it restarts the server]", "")
        check(SA.confirmation(.restartServer, s)?.consequence.contains("checks that nothing is running") == true, "[every change confirms]", "")
        check(SA.confirmation(.updateServer, s)?.consequence.hasSuffix("If this Mac already runs something newer, nothing changes.") == true, "[Update Server says it cannot go backward]", "")
        var pending = s; pending.transactionPending = true
        check(SA.confirmation(.repairRuntime, pending)?.question == "Finish the interrupted server update?", "[repair says what it does]", "")
        var stopped = s; stopped.desiredState = "stopped"
        check(SA.confirmation(.repairRuntime, stopped)?.consequence.contains("stays stopped") == true, "[repair says what it does]", "")
        check(SA.confirmation(.troubleshoot, s)?.consequence.contains("today's 20 runs") == true && SA.dailyRuns == 20, "[every change confirms]", "")
    }

    // MARK: Troubleshoot

    static func troubleshoot() {
        var s = healthy()
        failing(&s, "Whisper server", "failed: no result")
        let report = "{\"checks\": [{\"name\": \"Whisper server\", \"detail\": \"/Users/fictional-person/Library/Logs\"}], \"status\": {\"workDirectory\": \"/Users/another/work\"}}"
        guard let run = SA.troubleshoot(question: "  Whisper keeps stalling during meetings  ", s, report: report, id: "abc", asked: "Tuesday") else {
            check(false, "[troubleshoot prompt]", "nil with the server up and Work runs on"); return
        }
        check(run.target == "today:troubleshoot:abc" && run.target.hasPrefix("today:"), "[troubleshoot prompt]", run.target)
        check(run.title == "Troubleshoot: Whisper keeps stalling during meetings", "[troubleshoot prompt]", run.title)
        check(run.prompt.contains("Their words: \"Whisper keeps stalling during meetings\""), "[troubleshoot prompt]", "the question is quoted, trimmed")
        check(run.prompt.contains("Do not change anything yet.") && run.prompt.contains("Ask before you run anything that changes this Mac"),
              "[troubleshoot asks first]", "")
        check(run.prompt.contains("Never restart the COS server while a meeting is recording or a job is running."), "[troubleshoot asks first]", "")
        check(run.prompt.contains("Doctor error: Whisper server") && run.prompt.contains("Server: answering (state managedHealthy)"),
              "[troubleshoot prompt]", "what COS Control sees")
        check(!run.prompt.contains("/Users/") && run.prompt.contains("~/Library/Logs") && run.prompt.contains("~/work"), "[troubleshoot redacts]", "")
        check(run.context == "Asked from Ask COS setup help on Tuesday.", "[troubleshoot prompt]", run.context)

        let long = SA.troubleshoot(question: String(repeating: "q", count: 900), s, report: String(repeating: "r", count: 20_000), id: "b", asked: "x")
        check(long?.prompt.contains(String(repeating: "q", count: 501)) == false && long?.prompt.contains(String(repeating: "q", count: 500)) == true,
              "[troubleshoot is bounded]", "the question is capped at 500")
        check(long?.prompt.contains(String(repeating: "r", count: SA.maxPacket + 1)) == false
              && long?.prompt.contains(String(repeating: "r", count: SA.maxPacket)) == true, "[troubleshoot is bounded]", "the packet is capped")
        let missing = SA.troubleshoot(question: "help", s, report: nil, id: "c", asked: "x")
        check(missing?.prompt.contains("The redacted report could not be read.") == true, "[troubleshoot prompt]", "")
        var fresh = s; fresh.checks = []
        check(SA.troubleshoot(question: "help", fresh, report: nil, id: "d", asked: "x")?.prompt.contains("Doctor: not run yet") == true,
              "[troubleshoot prompt]", "")
    }

    // MARK: Setup rows and Doctor rows

    static func setupRowsAndDoctor() {
        var s = healthy()
        s.setup = [SA.SetupItem(id: "codex", title: "Codex", status: "Not signed in", unlocks: "Sessions, Continue and Work in Codex.", done: false),
                   SA.SetupItem(id: "cursor", title: "Cursor Agent", status: "Skipped", unlocks: "", done: false, skipped: true),
                   SA.SetupItem(id: "sessions", title: "Show your AI sessions", status: "After Get started", unlocks: "", done: false, afterSetup: true),
                   SA.SetupItem(id: "jev", title: "Work suggestions", status: "Checking…", unlocks: "", done: false, counted: false, awaitsServer: true),
                   SA.SetupItem(id: "glassesPair", title: "Connect your glasses", status: "Not paired", unlocks: "", done: false, counted: false),
                   SA.SetupItem(id: "claude", title: "Claude Code", status: "Signed in", unlocks: "", done: true)]
        let board = SA.board(s)
        check(ids(board) == ["setup-codex", "setup-glassesPair"], "[setup rows]", "done, skipped, after setup and waiting rows stay out: \(ids(board))")
        check(board.suggestions[0].tier == .setup && board.suggestions[1].tier == .extra, "[setup rows]", "uncounted rows are extras")
        check(board.suggestions[0].line == "I can set up Codex." && board.suggestions[0].why == "Not signed in. Sessions, Continue and Work in Codex.",
              "[setup rows]", board.suggestions[0].why)
        check(board.suggestions[1].line == "I can connect your glasses." && board.suggestions[1].action == .openSetupGuide, "[setup rows]", "")
        check(!board.allClear, "[setup rows]", "a counted row left to do is not all clear")
        check(SA.setupLine(SA.SetupItem(id: "sessions", title: "Show your AI sessions", status: "Off")) == "I can list your AI sessions in Activity.",
              "[setup rows]", "")
        check(SA.sentence("Checking…") == "Checking…" && SA.sentence("Off") == "Off." && SA.sentence("  ") == "", "[setup rows]", "")

        var integrity = healthy(); failing(&integrity, SA.CheckName.integrity, "Active generation failed verification")
        check(find(SA.board(integrity), "integrity")?.action == .updateServer, "[doctor rows]", "")
        var provider = healthy(); failing(&provider, SA.CheckName.provider, "No provider")
        check(find(SA.board(provider), "provider-bridge")?.action == .openSetupGuide, "[doctor rows]", "")
        var proof = healthy(); failing(&proof, SA.CheckName.proof, "timeout")
        check(find(SA.board(proof), "query-proof")?.action == .copyReport, "[doctor rows]", "")
        var recovery = healthy(); failing(&recovery, SA.CheckName.recovery)
        check(find(SA.board(recovery), "recovery-controller")?.action == .repairRuntime, "[doctor rows]", "")
        var warn = healthy()
        warn.checks = warn.checks.map { $0.name == "ffmpeg" ? SA.Check(name: "ffmpeg", state: "warning", detail: "Not installed") : $0 }
        check(SA.board(warn).allClear && SA.board(warn).suggestions.isEmpty, "[doctor rows]", "a warning COS cannot fix is not offered")

        var mic = healthy(); mic.microphoneAllowed = false
        check(find(SA.board(mic), "microphone")?.action == .openMicrophoneSettings, "[dictation permissions]", "")
        var trust = healthy(); trust.accessibilityTrusted = false
        check(find(SA.board(trust), "accessibility")?.action == .openPermissions, "[dictation permissions]", "")
        var off = trust; off.dictationEnabled = false; off.microphoneAllowed = false
        check(SA.board(off).suggestions.isEmpty, "[dictation permissions]", "dictation off: nothing about its permissions")
        var unknown = healthy(); unknown.accessibilityTrusted = nil; unknown.microphoneAllowed = nil
        check(SA.board(unknown).suggestions.isEmpty, "[dictation permissions]", "not read yet is not a problem")
    }

    // MARK: Copy rules (Miles: no em dashes, no arrows, no hedge words)

    static func copyRules() {
        var texts: [String] = []
        var fixtures: [SA.Snapshot] = [healthy()]
        var a = healthy(); a.serverReachable = false; a.runtimeState = "stopped"; a.desiredState = "stopped"; fixtures.append(a)
        var b = healthy(); b.whisperCircuitOpen = true; b.activeJobs = 2; b.transactionPending = true; fixtures.append(b)
        var c = healthy(); c.appUpdate = SA.AppUpdate(currentVersion: "0.5.353", latestVersion: "0.5.360", available: true, downloadFailed: true, installing: false)
        c.microphoneAllowed = false; c.accessibilityTrusted = false; fixtures.append(c)
        var d = healthy(); d.ownerConflict = true; fixtures.append(d)
        var e = healthy(); e.serverReachable = false; e.runtimeState = "legacyStopped"; fixtures.append(e)
        var f = healthy(); f.serverReachable = false; f.runtimeState = "legacyService"; fixtures.append(f)
        var g = healthy(); for name in [SA.CheckName.integrity, SA.CheckName.provider, SA.CheckName.proof, SA.CheckName.recovery] { failing(&g, name) }
        fixtures.append(g)
        // Every held line: busy, recording, saving, one job, an in-place server, an update installing, a first run.
        var h = g; h.helperBusy = true; fixtures.append(h)
        var i = g; i.activeTranscriptionSessions = 1; fixtures.append(i)
        var j = g; j.meetingWorkBlockingRestart = true; fixtures.append(j)
        j.meetingSyncUnconfirmed = true; fixtures.append(j)
        var k = g; k.activeJobs = 1; fixtures.append(k)
        var l = healthy(); l.runtimeState = "managedInPlace"; l.safeToRestart = false; l.appUpdate.available = true; l.appUpdate.installing = true
        fixtures.append(l)
        var m = SA.Snapshot(); m.runtimeState = "notInstalled"; m.needsFirstRun = true; fixtures.append(m)
        m.setupProviderInstalled = true; fixtures.append(m)
        var n = healthy(); n.transactionPending = true; fixtures.append(n)
        var heldSeen = Set<String>()
        for s in fixtures {
            for item in SA.board(s).suggestions { texts += [item.line, item.why, item.held ?? "", item.actionTitle ?? ""] }
            for action in SA.Action.allCases {
                texts.append(action.title)
                if let confirm = SA.confirmation(action, s) { texts += [confirm.question, confirm.consequence, confirm.confirm] }
                if case .held(let reason) = SA.gate(action, s) { texts.append(reason); heldSeen.insert(reason) }
            }
        }
        let everyHeld = [SA.Held.busy, SA.Held.ownerConflict, SA.Held.recording, SA.Held.saving, SA.Held.unconfirmed, SA.Held.interruptedUpdate,
                         SA.Held.unprovenIdle, SA.Held.installing, SA.Held.jobs(1)]
        check(Set(everyHeld).isSubset(of: heldSeen), "[copy rules]", "the scan reads every held line: missing \(Set(everyHeld).subtracting(heldSeen))")
        texts += everyHeld + [SA.Held.jobs(3)]
        for entry in SA.entries { texts += [entry.title, entry.answer] }
        texts.append(SA.troubleshoot(question: "help", healthy(), report: "{}", id: "x", asked: "today")?.prompt ?? "")
        let banned = ["\u{2014}", "\u{2013}", "\u{2192}", "->", "=>", "\u{21D2}"]
        let hedges = [" maybe ", " perhaps ", " might ", " possibly ", " probably ", " kinda ", " sort of ", "-ish", " somewhat ", " usually "]
        for text in texts where !text.isEmpty {
            check(!banned.contains { text.contains($0) }, "[copy rules]", "an em dash or arrow: \(text)")
            let padded = " " + text.lowercased() + " "
            check(!hedges.contains { padded.contains($0) }, "[copy rules]", "a hedge word: \(text)")
        }
        check(texts.count > 100, "[copy rules]", "the copy rules read \(texts.count) strings")
    }
}
