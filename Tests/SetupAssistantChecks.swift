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
        print("PASS: setup assistant, \(ran) checks")
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
        "parakeet-install": ["Parakeet won't install", "parakeet install failed", "can't download parakeet"],
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
