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
        centerKeys()
        centerRecording()
        centerRecordingRows()
        centerSessions()
        centerConfirms()
        centerAsk()
        centerResultLine()
        centerCopy()
        print("PASS: setup assistant, \(ran) checks")
    }

    // MARK: The command center (⌘K)

    typealias C = SA.Center

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
        let clear = C.listing(center { $0.foldedLine = "For tomorrow: 2 more things" }, words: "")
        check(row(clear, "info:no-waiting")?.title == "Nothing is waiting on you." && row(clear, "info:no-waiting")?.detail == "For tomorrow: 2 more things", "[no sessions]", "")
        check(row(clear, "info:no-running")?.title == "Nothing is running.", "[no sessions]", "")

        // Sessions off: says so, and opens where the switch is.
        let off = C.listing(center { $0.sessionsOff = true }, words: "")
        check(row(off, "command:openSessions")?.title == "Session tracking is off" && row(off, "command:openSessions")?.selectable == true, "[sessions off]", "\(rowIDs(off))")
        check(row(off, "info:no-running") == nil, "[sessions off]", "")
        check(row(off, "info:no-waiting")?.title == "Nothing else is waiting on you.", "[sessions off never says nothing waits]", "")

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
        // Nothing highlighted: one Work run, only for three or more words with no answer or command match.
        check(returned("draft the note to Dana") == .startRun, "[Return with no highlight runs Work]", "")
        check(returned("email Gina about pricing") == .startRun, "[Return with no highlight runs Work]", "")
        // A long text with a command word in it is still a run.
        check(returned("open the pricing page and check the hero copy") == .startRun, "[a long sentence is a run]", "")
        // Fewer than three words never starts a run.
        check(returned("hello") == .move("ask"), "[under three words moves to Ask]", "\(returned("hello"))")
        check(returned("call Gina") == .move("ask"), "[under three words moves to Ask]", "")
        // A saved answer never starts a run on Return.
        check(returned("my transcript never finished") == .move("ask"), "[a saved answer moves to Ask]", "\(returned("my transcript never finished"))")
        check(returned("how do i set up parakeet") == .move("ask"), "[a saved answer moves to Ask]", "")
        // A near-command never starts a run on Return.
        for phrase in ["restart server", "update", "update the deck", "stop recording the demo", "please start recording the call with Dana right now", "run doctor please"] {
            check(returned(phrase) == .move("ask"), "[a near-command moves to Ask]", "\(phrase): \(returned(phrase))")
        }
        // A command in the list, still being typed, never starts a run either.
        check(returned("go to se") == .move("ask"), "[a command in the list moves to Ask]", "\(returned("go to se"))")
        // The whole phrase runs at once; a highlight runs what it highlights.
        check(returned("start recording") == .activate("command:startRecording"), "[Return runs the highlight]", "")
        check(returned("sessions") == .activate("command:openSessions"), "[Return runs the highlight]", "")
        check(returned("draft the note to Dana", chosen: "file") == .activate("file"), "[Return runs the highlight]", "")
        check(returned("hello", chosen: "ask") == .activate("ask"), "[a second Return runs the Ask row]", "")
        // A highlight that went away is no highlight.
        check(returned("draft the note to Dana", chosen: "command:gone") == .startRun, "[a stale highlight is none]", "")
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
        // Server down: never a run. Return moves to File.
        var downSnapshot = healthy(); downSnapshot.serverReachable = false; downSnapshot.runtimeState = "stopped"
        check(returned("draft the note to Dana", inputs: center { $0.snapshot = downSnapshot }) == .move("file"), "[server down never starts a run]", "")
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
        check(C.hint(.startRun, typed, healthy()).contains("one Work run"), "[the hint says what Return does]", "")
        let start = C.listing(center(), words: "start recording")
        check(C.hint(.activate("command:startRecording"), start, healthy()) == "Return runs: Start recording", "[the hint says what Return does]", "")
        let live = center { $0.recording.stoppable = true; $0.recording.occupied = true }
        check(C.hint(.activate("command:stopRecording"), C.listing(live, words: "stop"), healthy()) == "Return asks first: Stop and save", "[the hint says what Return does]", "")
        check(C.announcement(row(start, "command:startRecording"), .activate("command:startRecording"), start, healthy()) == "Start recording. Return runs: Start recording", "[VoiceOver hears the highlight]", "")
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
        let glasses = center { $0.recording.busy = true; $0.recording.glassesLive = 1 }
        let glassesList = C.listing(glasses, words: "")
        check(row(glassesList, "command:startRecording")?.held == C.RecordingHeld.glasses, "[G2 recording holds Start]", "\(rowIDs(glassesList))")
        check(row(glassesList, "command:startRecording")?.selectable == false, "[G2 recording holds Start]", "")
        check(row(glassesList, "command:stopRecording") == nil, "[Stop never keys on a G2 recording]", "")
        check(row(glassesList, "info:glasses")?.title == "Stop it on the glasses.", "[G2 only says to stop it on the glasses]", "")
        let stopWords = C.listing(glasses, words: "stop recording")
        check(row(stopWords, "command:stopRecording") == nil && row(stopWords, "info:glasses")?.title == C.glassesLine, "[G2 only says to stop it on the glasses]", "\(rowIDs(stopWords))")
        // Both at once: Stop stops the Mac's, and the line says where the other one stops.
        let both = center { $0.recording.stoppable = true; $0.recording.occupied = true; $0.recording.busy = true; $0.recording.glassesLive = 1 }
        let bothList = C.listing(both, words: "")
        check(row(bothList, "command:stopRecording") != nil && row(bothList, "info:glasses")?.title == C.glassesLine, "[G2 and Mac both recording]", "\(rowIDs(bothList))")

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
        let both = C.listing(center { stoppable(&$0.recording); $0.recording.glassesLive = 1; $0.live = [mac, glasses]; $0.waiting = [waiting("a", "First")]; $0.running = [running("r", "Run")] }, words: "")
        // First, above Waiting and Running, with Stop under its own recording.
        check(Array(rowIDs(both).prefix(3)) == ["recording:mac_1", "command:stopRecording", "recording:g2-1"], "[recordings are the first rows]", "\(rowIDs(both))")
        check(both.rows.prefix(3).allSatisfy { $0.group == .recording }, "[recordings are the first rows]", "")
        check(both.rows.filter { $0.kind == .command(.stopRecording) }.count == 1, "[Stop lists once]", "\(rowIDs(both))")
        // A recording opens its live view; the glasses say where they stop; the Mac's Stop still confirms.
        check(row(both, "recording:mac_1")?.kind == .recording("mac_1") && row(both, "recording:mac_1")?.trailing == "Live view" && row(both, "recording:mac_1")?.selectable == true, "[a recording opens its live view]", "")
        check(row(both, "recording:g2-1")?.detail == "Recording on your glasses, 4 min. Stop it on the glasses", "[glasses say they stop on the glasses]", "")
        check(row(both, "info:glasses") == nil, "[no second glasses line]", "\(rowIDs(both))")
        check(C.confirmation(row(both, "command:stopRecording")!, healthy()) == C.stopConfirm, "[Stop has a confirm]", "")
        check(C.hint(.activate("recording:mac_1"), both, healthy()) == "Return opens: Zoom meeting 2:05 PM", "[the hint says what Return does]", "")
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
        check(returnedFor(title) == .move("ask"), "[two words move to Ask]", "")
        let long = C.listing(center { $0.sessions = [C.Item(id: "s1", title: "start recording the holiday promo", sessionID: "s1")] }, words: "holiday promo landing")
        check(returnedFor(long) == .startRun, "[a title never changes Return]", "")
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
        texts += [C.RecordingHeld.starting, C.RecordingHeld.os, C.RecordingHeld.saving, C.RecordingHeld.unsaved, C.RecordingHeld.glasses, C.RecordingHeld.server, C.glassesLine, C.noticeHint]
        texts += SA.Action.allCases.map(C.rowTitle)
        var off = healthy(); off.workRunsOn = false
        var down = healthy(); down.serverReachable = false; down.runtimeState = "stopped"
        let fixtures: [C.Inputs] = [
            center(), center { $0.snapshot = off }, center { $0.snapshot = down }, center { $0.sessionsOff = true }, center { $0.waitingKnown = false; $0.runningKnown = false },
            center { $0.recording.stoppable = true; $0.recording.occupied = true; $0.recording.busy = true }, center { $0.recording.busy = true; $0.recording.glassesLive = 1 },
            center { $0.recording.occupied = true; $0.recording.busy = true; $0.recording.saveLine = "Saving…" },
        ]
        for inputs in fixtures {
            for words in ["", "hello", "set up parakeet", "start recording", "stop recording", "my transcript never finished", "how do i use dictation", "rename a voice", "doctor"] {
                let listing = C.listing(inputs, words: words)
                check(Set(listing.rows.map(\.id)).count == listing.rows.count, "[row ids are unique]", "\(rowIDs(listing))")
                for row in listing.rows { texts += [row.title, row.detail ?? "", row.state ?? "", row.trailing ?? "", row.held ?? ""] }
                for outcome in [C.ReturnOutcome.nothing, .confirm, .startRun, .file, .move("ask"), .move("file")] + listing.rows.filter(\.selectable).map({ C.ReturnOutcome.activate($0.id) }) {
                    texts.append(C.hint(outcome, listing, inputs.snapshot))
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
        let everyHeld = [SA.Held.busy, SA.Held.ownerConflict, SA.Held.recording, SA.Held.saving, SA.Held.interruptedUpdate,
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
