import Foundation

// Ask COS as a setup and repair assistant, and the logic half of the ⌘K command center (Miles, 2026-10-27: "turn this into
// the setup widget that can run the commands necessary to get things running ... I can repair X, Y or Z or set up X, Y or
// Z"; 2026-10-31: "a main operation center rather than just ... a task creation system"). The views live in
// Sources/ActivityWindow.swift (the extension marked Command center), so they can reach the window's private openers.
// Wiring plan and what each piece reads: docs/setup-assistant/PLAN.md.
//
// HARD RULES
//   1. Local first. Every suggestion comes from a Snapshot of state COS Control already holds. No model call, no network,
//      no shell, so it answers when the server is down, which is when people need it most.
//   2. Actions, Center.Command and Center.Place are closed enums. Each maps to an existing helper command (HelperSources/main.swift,
//      the command switch) or an existing opener in the app. Text a person types picks a knowledge-base entry, a command or a
//      place by keyword and never becomes a command or an argument. One stated exception (0.5.361): the words of the local
//      session search go to the helper's stdin, never its arguments, for the one fixed verb `claude-sessions-search --local`,
//      which reads this Mac's own session files, calls no server and sends nothing off the Mac.
//   3. A change is confirmed inline first, with one consequence line read from the code that runs it. The restart gates
//      COS Control already has hold here too (a job, a recording, a meeting still saving, an ownership conflict, an
//      interrupted update). There is no force path. Doctor changes nothing but spends a real question, so the panel
//      confirms it too (Center.confirmation).
//   4. "Ask COS to troubleshoot" is offered only while the server answers and Start Work runs from Today is on. It
//      starts one Work run through the Today cap with a redacted Doctor packet, and the prompt says to ask before
//      changing anything. "Ask COS" is the same run without Doctor.
//   5. Session titles are untrusted. They are cleaned to one line, drawn verbatim, only open their own session, are never
//      matched for dispatch and never go into a prompt.
//   6. Match text (0.5.361) is a line from inside a session that the local search found. It is held to rule 5, masked when it
//      looks like a key, shown on its row only and never decides anything. A hit sits in its own group: Return never moves
//      onto one and never runs one. It is reached by an arrow or a click. This is the one stated exception to "a question's
//      words never reach the panel": the panel shows what a session said, and nothing else from a question.
//
// Imports Foundation only and needs no other source file: Tests/run-setup-assistant.sh compiles it alone with
// Tests/SetupAssistantChecks.swift. Everything lives inside `enum SetupAssistant`, so it cannot collide with app types.

enum SetupAssistant {

    // MARK: - Snapshot (plain values, built from ControllerModel; see docs/setup-assistant/PLAN.md)

    /// One Doctor row (DoctorCheck): name, `ok` | `warning` | `error`, detail.
    struct Check: Sendable, Equatable {
        var name: String
        var state: String
        var detail: String
    }

    /// One setup-guide row (SetupRow from SetupGuideRules.rows), reduced to what ranking reads.
    struct SetupItem: Sendable, Equatable {
        var id: String
        var title: String
        var status: String
        /// What it unlocks (SetupRow.unlocks).
        var unlocks = ""
        var done = false
        var skipped = false
        /// False for the Glasses rows and Work suggestions: optional, never part of Finish setup.
        var counted = true
        /// Needs the COS server first (before Get started).
        var afterSetup = false
        /// A check is running or the server did not answer: no suggestion until it settles.
        var awaitsServer = false
    }

    /// The app update banner's state (AppUpdateInfo and AppUpdateFlow).
    struct AppUpdate: Sendable, Equatable {
        var currentVersion = ""
        var latestVersion: String?
        /// The appcast offers a newer build.
        var available = false
        /// The download failed or timed out (AppUpdateFlow.offersUnstuck, 0.5.352).
        var downloadFailed = false
        /// Staging or applying right now.
        var installing = false
    }

    struct Snapshot: Sendable, Equatable {
        /// ServerStatus.running: /api/health answered 200.
        var serverReachable = false
        /// ServerStatus.runtimeState (RuntimeState in HelperSources/main.swift).
        var runtimeState = "unknown"
        var installed = false
        var needsFirstRun = false
        var setupProviderInstalled = false
        var managedContract = false
        var ownershipVerified = false
        var ownerConflict = false
        var transactionPending = false
        var desiredState = "running"
        var safeToRestart = false
        var activeJobs = 0
        var activeTranscriptionSessions = 0
        var meetingWorkBlockingRestart = false
        /// A running server did not answer, so what holds Restart and Update is not known to be a save.
        var meetingSyncUnconfirmed = false
        /// A Mac recording in COS Control (recordingCount > 0).
        var macRecordingActive = false
        var whisperReady = false
        var whisperCircuitOpen = false
        /// ControllerModel.busy: another helper command is running.
        var helperBusy = false
        /// The last Run Doctor (empty until it has run).
        var checks: [Check] = []
        var appUpdate = AppUpdate()
        var setup: [SetupItem] = []
        var dictationEnabled = false
        /// AXIsProcessTrusted for this copy. nil: not read.
        var accessibilityTrusted: Bool?
        /// The microphone authorization. nil: not asked yet.
        var microphoneAllowed: Bool?
        /// Settings > Activity: Start Work runs from Today (TodayHome.workRunsOn).
        var workRunsOn = false
        /// A message typed into an open session and not sent (ControllerModel.chatDraft). Going anywhere else clears it, so a
        /// place row asks first.
        var unsentSessionDraft = false

        init() {}
    }

    // MARK: - Actions

    enum Action: String, Sendable, CaseIterable {
        // Helper commands (HelperSources/main.swift, the command switch).
        case runDoctor, copyReport, setUp, startServer, restartServer, repairRuntime, repairWhisper, updateServer
        // In the app.
        case retryAppUpdate, resetAccessibility
        // Openers: they change nothing.
        case openUnstuck, openSetupGuide, openPermissions, openSettings, openDictationSettings, openMicrophoneSettings, openTailscale,
             openTranscriptionSettings, openMeetings, openSpeakers
        // One Work run (only with the server up and Work runs on).
        case troubleshoot

        /// The helper command it runs through `model.perform`, or nil when it is not a helper command.
        var helperCommand: String? {
            switch self {
            case .runDoctor: return "doctor"
            case .copyReport: return "report"
            case .setUp: return "setup"
            case .startServer: return "start"
            case .restartServer: return "restart"
            case .repairRuntime: return "repair"
            case .repairWhisper: return "restart-whisper"
            case .updateServer: return "update"
            default: return nil
            }
        }

        /// Changes something, so it is confirmed inline first.
        var changesSomething: Bool {
            switch self {
            case .setUp, .startServer, .restartServer, .repairRuntime, .repairWhisper, .updateServer,
                 .retryAppUpdate, .resetAccessibility, .troubleshoot: return true
            default: return false
            }
        }

        /// Acts on the COS server's process (install, start, restart, repair, update).
        var touchesServer: Bool {
            switch self {
            case .setUp, .startServer, .restartServer, .repairRuntime, .repairWhisper, .updateServer: return true
            default: return false
            }
        }

        /// Replaces the running server process. Each one drains through the server's maintenance gate first
        /// (acquireMaintenanceLeaseIfNeeded), so COS Control's restart gates apply: a job, a recording, a meeting saving.
        var restartsServer: Bool {
            switch self {
            case .restartServer, .repairRuntime, .repairWhisper, .updateServer: return true
            default: return false
            }
        }

        /// The button's words.
        var title: String {
            switch self {
            case .runDoctor: return "Run Doctor"
            case .copyReport: return "Copy report"
            case .setUp: return "Set up"
            case .startServer: return "Start"
            case .restartServer: return "Restart"
            case .repairRuntime: return "Repair"
            case .repairWhisper: return "Repair Whisper"
            case .updateServer: return "Update Server"
            case .retryAppUpdate: return "Update"
            case .resetAccessibility: return "Reset and add again"
            case .openUnstuck: return "Show the steps"
            case .openSetupGuide: return "Open the setup guide"
            case .openPermissions: return "Review permissions"
            case .openSettings: return "Open Settings"
            case .openDictationSettings: return "Open Dictation settings"
            case .openMicrophoneSettings: return "Open Microphone settings"
            case .openTailscale: return "Open Tailscale"
            case .openTranscriptionSettings: return "Open Transcription and voice"
            case .openMeetings: return "Open Meetings"
            case .openSpeakers: return "Open Speakers"
            case .troubleshoot: return "Ask COS to troubleshoot"
            }
        }
    }

    // MARK: - Gates

    enum Gate: Sendable, Equatable {
        case ready
        /// It applies, and it waits: the line says why. The button is not offered.
        case held(String)
        /// It does not apply in this state, so it is not offered at all.
        case notApplicable
    }

    enum Held {
        static let busy = "COS Control is finishing another task. Try again when it is done."
        static let ownerConflict = "Another server owns the COS ports, so COS Control will not touch it."
        static let recording = "A meeting is recording. Save or end it first."
        static let saving = "A meeting is still saving. This comes back when it is done."
        static let unconfirmed = "The server is not answering, so COS cannot tell whether a save is running. This comes back when it answers or stops. If it never does, Repair server in Settings brings it back."
        static let interruptedUpdate = "An interrupted server update needs Repair first."
        static let unprovenIdle = "This server cannot prove it is idle. Restart in Settings asks first."
        static let installing = "The update is already installing."
        static func jobs(_ count: Int) -> String {
            count == 1 ? "1 job is running. This comes back when it finishes." : "\(count) jobs are running. This comes back when they finish."
        }
    }

    /// Whether `action` can run now. Order matters: what blocks every change comes first, then the restart gates, then
    /// what the action itself needs (each mirrors the existing button's own condition, cited per case).
    static func gate(_ action: Action, _ s: Snapshot) -> Gate {
        guard applies(action, s) else { return .notApplicable }
        // model.perform and installAppUpdate both return at once while busy; say so instead of a button that does nothing.
        if s.helperBusy, action.helperCommand != nil || action == .retryAppUpdate { return .held(Held.busy) }
        if action.touchesServer, s.ownerConflict { return .held(Held.ownerConflict) }
        if action.restartsServer {
            // Views.swift controls: Restart is disabled while activeJobs + activeTranscriptionSessions > 0, a transaction is
            // pending, or meetingWorkBlockingRestart; Update Server while meetingWorkBlockingRestart.
            if s.activeTranscriptionSessions > 0 || s.macRecordingActive { return .held(Held.recording) }
            if s.meetingWorkBlockingRestart { return .held(s.meetingSyncUnconfirmed ? Held.unconfirmed : Held.saving) }
            if s.activeJobs > 0 { return .held(Held.jobs(s.activeJobs)) }
        }
        switch action {
        case .restartServer:
            if s.transactionPending { return .held(Held.interruptedUpdate) }
            // Views.swift: an in-place server that cannot prove idle gets the legacy confirm, never a one-tap restart.
            if s.runtimeState == "managedInPlace", !s.safeToRestart { return .held(Held.unprovenIdle) }
        case .updateServer:
            // install() refuses while a transaction is pending ("A previous update needs repair before another install").
            if s.transactionPending { return .held(Held.interruptedUpdate) }
        case .retryAppUpdate:
            if s.appUpdate.installing { return .held(Held.installing) }
            // The update quits and reopens COS Control: a meeting is saved first (control docs, Updating COS Control).
            if s.macRecordingActive || s.activeTranscriptionSessions > 0 { return .held(Held.recording) }
        default:
            break
        }
        return .ready
    }

    /// Whether the action makes sense in this state at all.
    static func applies(_ action: Action, _ s: Snapshot) -> Bool {
        switch action {
        case .runDoctor, .copyReport, .openSetupGuide, .openPermissions, .openSettings, .openDictationSettings,
             .openMicrophoneSettings, .openTailscale, .openUnstuck, .resetAccessibility, .openTranscriptionSettings, .openMeetings, .openSpeakers:
            return true
        case .setUp:
            // main.swift "setup": refuses an existing service or an unfinished setup, and needs an AI app first.
            return s.needsFirstRun && s.setupProviderInstalled
        case .startServer:
            // Views.swift: Start is offered only when the runtime is stopped.
            return s.runtimeState == "stopped"
        case .restartServer:
            // Views.swift: Restart shows for a managed healthy or in-place server.
            return s.runtimeState == "managedHealthy" || s.runtimeState == "managedInPlace"
        case .repairRuntime:
            // Views.swift: Repair is disabled when not installed or for a foreground server; offered only when it fixes
            // something here (an interrupted update, a server that does not answer, a missing recovery controller).
            guard s.installed, s.runtimeState != "legacyForeground" else { return false }
            return s.transactionPending || failing(CheckName.updateRecovery, s) || failing(CheckName.recovery, s)
                || !s.serverReachable || s.runtimeState == "managedDegraded"
        case .repairWhisper:
            // Views.swift: Repair Whisper shows for a verified managed server whose Whisper is not ready or is paused.
            return s.serverReachable && s.managedContract && s.ownershipVerified && (!s.whisperReady || s.whisperCircuitOpen)
        case .updateServer:
            // Views.swift: Update Server shows for an installed managed server with verified ownership.
            return s.installed && s.managedContract && s.ownershipVerified
        case .retryAppUpdate:
            return s.appUpdate.available || s.appUpdate.downloadFailed
        case .troubleshoot:
            return s.serverReachable && s.workRunsOn
        }
    }

    // MARK: - Confirmations

    struct Confirmation: Sendable, Equatable {
        var question: String
        var consequence: String
        var confirm: String
    }

    /// The inline confirm for a change, or nil for an action that changes nothing. Each consequence is what the code
    /// that runs it does (cited per case).
    static func confirmation(_ action: Action, _ s: Snapshot) -> Confirmation? {
        switch action {
        case .setUp:
            // main.swift "setup" then install(requestedVersion: "latest"); control docs: setup needs an internet connection.
            return Confirmation(question: "Set up COS on this Mac?",
                                consequence: "COS downloads the server, installs it for this Mac and starts it. This needs an internet connection.",
                                confirm: "Set up")
        case .startServer:
            // main.swift start(): load the LaunchAgent, then waitForManagedHealth(timeout: 60).
            return Confirmation(question: "Start the COS server?",
                                consequence: "COS starts the server and waits up to a minute for it to answer.",
                                confirm: "Start")
        case .restartServer:
            // main.swift restart(): the maintenance drain proof, launchctl kickstart -k, waitForManagedHealth(timeout: 60).
            return Confirmation(question: "Restart the COS server?",
                                consequence: "COS checks that nothing is running, restarts the server and waits up to a minute for it to answer.",
                                confirm: "Restart")
        case .repairRuntime:
            // main.swift repair(): a pending transaction is committed when its candidate is healthy, else restored; a
            // server stopped by choice stays stopped; otherwise the helper, the recovery agent and the LaunchAgent are
            // reinstalled, the server restarted and checked.
            if s.transactionPending {
                return Confirmation(question: "Finish the interrupted server update?",
                                    consequence: "COS keeps the new server if it answers, or puts the previous one back.",
                                    confirm: "Repair")
            }
            if s.desiredState == "stopped" {
                return Confirmation(question: "Repair COS?",
                                    consequence: "COS reinstalls its recovery controller. The server stays stopped, as you left it.",
                                    confirm: "Repair")
            }
            return Confirmation(question: "Repair the COS server?",
                                consequence: "COS reinstalls its background service and recovery controller, restarts the server and checks it.",
                                confirm: "Repair")
        case .repairWhisper:
            // main.swift restartWhisper(): "Whisper has no network restart endpoint": the same full process replacement.
            return Confirmation(question: "Repair local Whisper?",
                                consequence: "This restarts the whole COS server, then waits for Whisper to answer.",
                                confirm: "Repair Whisper")
        case .updateServer:
            // control docs, Updating the server: health and a real query, else the previous generation comes back.
            return Confirmation(question: "Update the COS server?",
                                consequence: "COS downloads the latest server, tests it with a real question, and puts the current one back if that test fails. If this Mac already runs something newer, nothing changes.",
                                confirm: "Update")
        case .retryAppUpdate:
            // ControllerModel.installAppUpdate: download, SHA-256, swap, reopen. The glasses server keeps running.
            return Confirmation(question: s.appUpdate.downloadFailed ? "Try the update again?" : "Update COS Control?",
                                consequence: "COS Control downloads the update, checks it, then closes and opens again on the new version. The COS server keeps running.",
                                confirm: "Download and install")
        case .resetAccessibility:
            // ControllerModel.resetAccessibilityAndAddAgain: tccutil reset Accessibility <bundle id>, then the pane.
            return Confirmation(question: "Reset Accessibility for COS Control?",
                                consequence: "COS removes only its own entry from the Accessibility list, then opens the list so you can turn COS Control on again.",
                                confirm: "Reset and add again")
        case .troubleshoot:
            // TodayRunGuard.dailyCap (Sources/Models.swift) and the prompt below.
            return Confirmation(question: "Ask COS to troubleshoot?",
                                consequence: "This starts one Work run with your words and a redacted Doctor report. It counts toward today's \(Self.dailyRuns) runs, and the agent is told to ask before it changes anything.",
                                confirm: "Ask COS")
        default:
            return nil
        }
    }

    /// TodayRunGuard.dailyCap, the Today home's Work-run cap.
    static let dailyRuns = 20

    // MARK: - Suggestions

    enum Tier: Int, Sendable, Comparable {
        case repair = 0, setup = 1, extra = 2
        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    struct Suggestion: Sendable, Equatable, Identifiable {
        var id: String
        var tier: Tier
        /// "I can repair local Whisper."
        var line: String
        /// One short sentence: what is wrong, or what it unlocks.
        var why: String
        /// The button, offered only when its gate is ready.
        var action: Action?
        var actionTitle: String?
        /// A second, lighter button (Try again beside Show the steps).
        var secondary: Action?
        /// Why the action waits. Set when the action applies and is held.
        var held: String?
        var rank: Int
    }

    struct Board: Sendable, Equatable {
        /// At most `shown`, broken things first, then setup, then extras.
        var suggestions: [Suggestion]
        /// Nothing broken and nothing left to set up.
        var allClear: Bool
        /// Found beyond `shown`.
        var more: Int
    }

    static let shown = 4

    /// The Doctor rows the board reads (HelperSources/main.swift doctorDetails).
    enum CheckName {
        static let recovery = "Recovery controller"
        static let updateRecovery = "Update recovery"
        static let integrity = "Runtime integrity"
        static let provider = "AI provider bridge"
        static let proof = "Query + playback proof"
        static let whisperServer = "Whisper server"
    }

    static func failing(_ name: String, _ s: Snapshot) -> Bool {
        s.checks.contains { $0.name == name && $0.state == "error" }
    }

    static func board(_ s: Snapshot) -> Board {
        // An ownership conflict: COS Control never stops or replaces a process it does not own, so nothing is offered.
        if s.ownerConflict {
            let only = Suggestion(id: "owner-conflict", tier: .repair, line: "Another server is using the COS ports.",
                                  why: "COS Control will not stop or replace a server it did not start. Stop the one you started in Terminal with Control-C, then check again.",
                                  rank: 0)
            return Board(suggestions: [only], allClear: false, more: 0)
        }
        var found: [Suggestion] = []
        func add(_ id: String, _ tier: Tier, _ rank: Int, _ line: String, _ why: String, _ action: Action?, title: String? = nil,
                 secondary: Action? = nil) {
            guard !found.contains(where: { $0.id == id }) else { return }
            var item = Suggestion(id: id, tier: tier, line: line, why: why, rank: rank)
            if let action {
                switch gate(action, s) {
                case .ready: item.action = action; item.actionTitle = title ?? action.title
                case .held(let reason): item.held = reason
                case .notApplicable: break
                }
            }
            if let secondary, gate(secondary, s) == .ready { item.secondary = secondary }
            found.append(item)
        }

        // Repair: broken things.
        if s.transactionPending || failing(CheckName.updateRecovery, s) {
            add("interrupted-update", .repair, 10, "I can finish the interrupted server update.",
                "A server update stopped partway, so Restart and Update Server stay locked until it is finished.", .repairRuntime)
        }
        if !s.serverReachable && !s.needsFirstRun {
            switch s.runtimeState {
            case "stopped":
                add("server-stopped", .repair, 20, "I can start the COS server.",
                    s.desiredState == "stopped" ? "It was stopped from COS Control, so Work, meetings and the glasses cannot reach it."
                        : "It is not running, so Work, meetings and the glasses cannot reach it.", .startServer)
            case "legacyForeground":
                add("server-terminal", .repair, 20, "A server started in Terminal is using the COS ports.",
                    "Finish active work, then stop it in Terminal with Control-C. COS Control can then run the server for you.", nil)
            case "legacyStopped":
                add("server-legacy", .repair, 20, "I can take over your existing COS server.",
                    "COS Control found a stopped server it recognizes. Adopt Safely in Settings installs the managed server.", .openSettings)
            default:
                if s.installed {
                    add("server-down", .repair, 20, "I can repair the COS server.",
                        s.runtimeState == "managedDegraded" ? "It is loaded but not answering." : "It is not answering.", .repairRuntime)
                } else {
                    add("server-unknown", .repair, 20, "I can find out why the server is not answering.",
                        "Doctor checks the server, Whisper and your AI apps, and names anything failing.", .runDoctor)
                }
            }
        }
        // A server you run yourself, answering: Views.swift offers Manage in place, which replaces nothing.
        if s.runtimeState == "legacyService" {
            add("server-legacy", .setup, 105, "I can manage your running server in place.",
                "Manage in place, in Settings, adds status, restart and recovery without replacing it.", .openSettings)
        }
        if s.appUpdate.downloadFailed {
            add("app-update-failed", .repair, 30, "I can help you update COS Control by hand.",
                "The update download failed or timed out. Updating by hand takes a few minutes, and your settings and meetings stay where they are.",
                .openUnstuck, secondary: .retryAppUpdate)
        }
        if failing(CheckName.recovery, s) {
            add("recovery-controller", .repair, 40, "I can repair the recovery controller.",
                "It brings the server back if it stops. Doctor found it missing or not loaded.", .repairRuntime)
        }
        if (s.serverReachable && s.managedContract && s.ownershipVerified && (!s.whisperReady || s.whisperCircuitOpen)) || failing(CheckName.whisperServer, s) {
            add("whisper", .repair, 50, "I can repair local Whisper.",
                s.whisperCircuitOpen ? "It paused after repeated errors." : "It is not answering, so this Mac cannot transcribe meetings.", .repairWhisper)
        }
        if s.dictationEnabled && s.microphoneAllowed == false {
            add("microphone", .repair, 60, "I can open the Microphone setting for dictation.",
                "macOS has not allowed COS Control to use the microphone, so dictation cannot hear you.", .openMicrophoneSettings)
        }
        if s.dictationEnabled && s.accessibilityTrusted == false {
            add("accessibility", .repair, 70, "I can help dictation type for you again.",
                "Accessibility is off for this copy of COS Control, so dictation only copies its text.", .openPermissions)
        }
        if failing(CheckName.provider, s) {
            add("provider-bridge", .repair, 80, "I can help connect your AI app.",
                "Doctor says the server cannot use your AI app yet.", .openSetupGuide)
        }
        if failing(CheckName.integrity, s) {
            add("integrity", .repair, 90, "I can reinstall the COS server.",
                "Doctor says the installed server failed its integrity check. Update Server installs a fresh, verified copy.", .updateServer)
        }
        if failing(CheckName.proof, s) {
            add("query-proof", .repair, 95, "I can make a support report about Doctor's failed test question.",
                "COS asked your AI app a real question and got no answer. Copy report makes a redacted report you can send to support.", .copyReport)
        }

        // Setup: what has not been done.
        if s.needsFirstRun {
            if s.setupProviderInstalled {
                add("first-run", .setup, 100, "I can set up COS on this Mac.",
                    "Your AI app is ready. Setup installs the COS server and starts it.", .setUp)
            } else {
                add("first-run", .setup, 100, "I can set up COS once an AI app is connected.",
                    "COS works with Claude Code, Codex or Cursor Agent. The setup guide walks you through it.", .openSetupGuide)
            }
        }
        if s.appUpdate.available && !s.appUpdate.downloadFailed && !s.appUpdate.installing {
            let latest = s.appUpdate.latestVersion.map { " to \($0)" } ?? ""
            add("app-update", .setup, 110, "I can update COS Control\(latest).",
                s.appUpdate.currentVersion.isEmpty ? "A newer COS Control is ready." : "This Mac has \(s.appUpdate.currentVersion).", .retryAppUpdate)
        }
        for (index, item) in s.setup.enumerated() where !item.done && !item.skipped && !item.afterSetup && !item.awaitsServer {
            let why = [sentence(item.status), sentence(item.unlocks)].filter { !$0.isEmpty }.joined(separator: " ")
            add("setup-" + item.id, item.counted ? .setup : .extra, (item.counted ? 120 : 200) + index, setupLine(item), why, .openSetupGuide)
        }

        // Extras.
        if s.checks.isEmpty && !s.needsFirstRun {
            add("checkup", .extra, 300, "I can run a full checkup.",
                "Doctor checks the server, Whisper and your AI apps, and names anything failing.", .runDoctor)
        }

        let ranked = found.sorted { ($0.tier, $0.rank) < ($1.tier, $1.rank) }
        let clear = !ranked.contains { $0.tier != .extra }
        return Board(suggestions: Array(ranked.prefix(shown)), allClear: clear, more: max(0, ranked.count - shown))
    }

    /// "I can set up ..." for a setup-guide row (SetupRowID raw values). Rows whose titles are not things you set up get
    /// their own words.
    static func setupLine(_ item: SetupItem) -> String {
        switch item.id {
        case "voice": return "I can set up local transcription."
        case "dictationEngine": return "I can set up the dictation engine."
        case "sessions": return "I can list your AI sessions in Activity."
        case "continueThreads": return "I can let COS continue your agent threads."
        case "permissions": return "I can walk you through permissions."
        case "glassesPair": return "I can connect your glasses."
        default: return "I can set up \(item.title)."
        }
    }

    /// A setup row's status as a sentence ("Not signed in" -> "Not signed in.").
    static func sentence(_ status: String) -> String {
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        return ".?!…".contains(last) ? trimmed : trimmed + "."
    }

    // MARK: - Knowledge base

    /// One troubleshooting answer. `source` names where the answer comes from (cos-starter paths are at origin/main
    /// 7879f48, the gotcos.com site source; code paths at 2dbadec). Nothing here is shown as a citation; it keeps the
    /// answers honest and lets a reviewer check each one.
    struct Entry: Sendable, Equatable {
        var id: String
        var title: String
        var answer: String
        /// In order. Each is offered when it applies: ready, or held with its reason.
        var actions: [Action]
        var source: String
        /// Every group must match (any one term in it).
        var groups: [[String]]
        /// Any one of these matches the entry on its own.
        var phrases: [String] = []
        /// Each one present adds a point, so the closer entry wins a tie.
        var boosts: [String] = []
        /// Adds what holds Restart right now, from the gate.
        var namesRestartHold = false
    }

    struct Offer: Sendable, Equatable {
        var action: Action
        var title: String
        var held: String?
    }

    struct Answer: Sendable, Equatable {
        var entry: Entry
        /// The answer, with the live hold appended when the entry asks for it.
        var text: String
        var offers: [Offer]
    }

    enum Terms {
        static let update = ["update", "updates", "updating", "updated", "upgrade", "upgrading", "new version", "latest version",
                             "download", "downloading", "downloaded", "install", "installing", "installed"]
        static let stuck = ["stuck", "stalled", "stall", "stalls", "stopped", "hung", "hang", "hangs", "hanging", "frozen", "freeze",
                            "freezes", "timed out", "timeout", "times out", "spinning", "never finishes", "wont finish", "not finishing",
                            "sits", "sitting", "loop", "looping"]
        static let fail = ["fail", "failed", "fails", "failing", "failure", "error", "errors", "broken", "wont", "doesnt work",
                           "not working", "isnt working", "cant", "cannot", "unable"]
        static let old = ["old", "older", "outdated", "out of date", "behind"]
        static let server = ["server", "cos server", "backend", "service", "3141", "localhost"]
        static let connect = ["connect", "connected", "connecting", "connection", "disconnected", "reach", "reachable", "unreachable",
                              "offline", "down", "not running", "stopped", "not responding", "unavailable", "cant reach"]
        static let whisper = ["whisper", "transcription", "transcribe", "transcribing", "transcript", "transcripts"]
        static let slow = ["slow", "slowly", "slower", "lag", "lags", "laggy", "lagging", "delay", "delayed", "takes forever",
                           "forever", "sluggish", "long time", "takes long", "takes a while"]
        static let dictation = ["dictation", "dictate", "dictating", "dictated", "voice typing", "speech to text", "push to talk", "parakeet"]
        static let accessibility = ["accessibility", "permission", "permissions", "only copies", "copies the text", "copies text",
                                    "only pastes", "clipboard", "wont type", "doesnt type", "not typing", "cant type", "nothing types",
                                    "jump to session"]
        static let glasses = ["glasses", "g2", "even app", "even realities", "lens", "companion", "phone", "iphone", "tailscale", "query failed"]
        static let pairing = ["pair", "pairing", "pairs", "paired"]
        static let mic = ["mic", "microphone", "microphones", "input device", "cant hear", "doesnt hear", "not hearing", "no speech",
                          "no sound", "picked up", "picking up", "hears nothing"]
        static let provider = ["claude", "claude code", "codex", "cursor", "ai app", "ai provider", "provider", "providers", "chatgpt"]
        static let signIn = ["not detected", "detected", "sign in", "signin", "signed in", "signed out", "login", "log in", "logged out",
                             "not found", "cant find", "missing", "auth"]
        static let restart = ["restart", "restarting", "update server", "button", "buttons"]
        static let greyed = ["greyed", "grayed", "grey", "gray", "disabled", "dimmed", "cant click", "cannot click", "unclickable", "locked"]
        static let conflict = ["ownership conflict", "ownership", "another server", "port", "ports", "address in use", "eaddrinuse", "conflict"]
        static let parakeet = ["parakeet"]
        static let setUp = ["install", "installs", "installing", "installed", "download", "downloading", "set up", "setup"]
    }

    /// Specific entries first: a tie goes to the earlier one.
    static let entries: [Entry] = [
        Entry(id: "owner-conflict", title: "Ownership conflict",
              answer: "Another server owns the COS ports, and COS Control will not stop or replace a process it did not start. Stop the server you started in Terminal with Control-C, then try again.",
              actions: [.runDoctor],
              source: "cos-starter control/docs/index.html:1212 (Server setup fails), :1107 (The managed server); Sources/Views.swift:1866",
              groups: [Terms.conflict]),
        Entry(id: "restart-greyed", title: "Restart or Update Server is greyed out",
              answer: "A job or recording is active, and COS will not interrupt it. Save or end the meeting and let jobs finish, and the buttons come back.",
              actions: [],
              source: "cos-starter control/docs/index.html:1249 (Restart or Update Server is greyed out), :1123 (Safe restarts); Sources/Views.swift:1830-1832",
              groups: [Terms.restart, Terms.greyed], namesRestartHold: true),
        Entry(id: "restart", title: "Restart the COS server",
              answer: "Restart replaces the server process and checks it again. It is locked while a job or recording is active, so nothing is cut off.",
              actions: [.restartServer],
              source: "cos-starter control/docs/index.html:1123 (Safe restarts); HelperSources/main.swift:4132-4150 restart(); Sources/Views.swift:1823-1832",
              groups: [["restart", "restarting", "reboot", "relaunch"]], boosts: ["server", "cos server"], namesRestartHold: true),
        Entry(id: "parakeet-install", title: "Parakeet will not install",
              answer: "Parakeet needs 1.5 GB free. Free some space, then choose Check again. It installs only after a recording ends, and Use Whisper keeps dictation working meanwhile.",
              actions: [.openTranscriptionSettings, .openDictationSettings],
              source: "cos-starter control/docs/index.html:1229 (Parakeet will not install)",
              groups: [Terms.parakeet, Terms.setUp],
              // A failure named in the words stays here: these beat the same words in parakeet-setup by the boost.
              phrases: ["cant install parakeet", "wont install parakeet", "cant download parakeet", "parakeet install failed", "parakeet setup failed"],
              boosts: ["parakeet"]),
        Entry(id: "parakeet-setup", title: "Set up Parakeet and choose an engine",
              answer: "Parakeet Ultra is the local dictation engine. In Settings, Transcription and voice, Models, choose Install Parakeet (654 MB). It needs 1.5 GB free, installs after any recording ends, and dictation uses Whisper until it is ready. Then choose the engine in Settings, Dictation, Dictation engine. Automatic uses Parakeet Ultra once it is ready. Test on this Mac compares the engines.",
              actions: [.openTranscriptionSettings, .openDictationSettings],
              source: "cos-starter control/docs/index.html:760-761 (Engines), :516 (Test on this Mac); Sources/SettingsHubCatalog.swift TR-01, TR-07, SG-06 (Dictation engine, Parakeet engine, Test engines); Sources/MeetingAskCore.swift installTitle; Sources/ProviderConnectViews.swift (Test on this Mac)",
              groups: [],
              phrases: ["set up parakeet", "setup parakeet", "parakeet setup", "install parakeet", "get parakeet", "use parakeet", "turn on parakeet", "download parakeet",
                        "choose an engine", "choose the engine", "pick an engine", "change the engine", "dictation engine", "which engine", "switch engine"]),
        Entry(id: "update-stuck", title: "Update stuck, or COS Control is very old",
              answer: "If an update times out or will not finish, update by hand: download the current COS Control from gotcos.com, quit the old copy and drag the new one into Applications. It takes a few minutes, and your settings and meetings stay where they are. If it sits on Installing, finish any meeting first.",
              actions: [.openUnstuck, .retryAppUpdate],
              source: "gotcos.com/control/#unstuck (cos-starter control/index.html:590-598); cos-starter control/docs/index.html:1188 (An update sits on Installing), :1171 (Updating by hand); Sources/Models.swift AppUpdateFlow.unstuckURL",
              groups: [Terms.update, Terms.stuck + Terms.fail + Terms.old],
              phrases: ["download timed out", "timed out downloading", "very old version", "control is very old", "control is old",
                        "control is outdated", "control app is outdated", "app is outdated", "app is very old", "out of date app"],
              boosts: ["cos control", "app", "control", "version"]),
        Entry(id: "dictation-slow", title: "Dictation is slow",
              answer: "When Parakeet Ultra is warming up or cannot start, COS dictates with Whisper for that dictation, and its card says why. Activity, Dictation, Settings shows the engine in use. If every dictation is slow, ask COS to troubleshoot.",
              actions: [.openDictationSettings, .troubleshoot],
              source: "Sources/MacDictationCore.swift:6175-6177 (parakeet_warming, parakeet_warm_failed); HelperSources/main.swift:4798-4800 (warm: cold, warming, warm, failed); cos-starter control/docs/index.html:723 (Settings holds the engine)",
              groups: [Terms.dictation, Terms.slow], boosts: ["dictation", "parakeet"]),
        Entry(id: "whisper-stalled", title: "Whisper or transcription is stuck",
              answer: "Repair Whisper restarts the COS server and local Whisper together, then waits for Whisper to answer. Save or end any meeting first.",
              actions: [.repairWhisper, .runDoctor],
              source: "Sources/Views.swift:2801-2803 (Repair Whisper); HelperSources/main.swift:4464-4487 restartWhisper(); cos-starter control/docs/index.html:1133 (Repair Managed Runtime and Repair Whisper)",
              groups: [Terms.whisper, Terms.stuck + Terms.fail + Terms.slow], phrases: ["restart whisper", "repair whisper"],
              boosts: ["whisper", "transcript", "transcription", "meeting", "recording"]),
        Entry(id: "microphone", title: "The microphone is not picked up",
              answer: "Check which microphone COS uses in Activity, Dictation, Settings. Refresh microphones finds a new one. If macOS has not allowed COS Control, allow it under Privacy and Security, Microphone. Mac meeting recording never records your microphone. It records what the Mac plays.",
              actions: [.openDictationSettings, .openMicrophoneSettings],
              source: "cos-starter control/docs/index.html:738 (Choose a Microphone, Refresh microphones), :801 (Open Settings when the microphone is not allowed), :887 (Mac recording does not record the microphone); Sources/MacDictation.swift:3470",
              groups: [Terms.mic]),
        Entry(id: "accessibility", title: "Accessibility is on, but dictation only copies the text",
              answer: "macOS can keep an old Accessibility entry that no longer matches the installed app, often after an update. Reset and add again removes COS Control's own entry so you can turn it on fresh. Switching the toggle off and on is often not enough.",
              actions: [.resetAccessibility, .openPermissions],
              source: "cos-starter control/docs/index.html:1192 (Accessibility is on, but dictation only copies the text); control/index.html:588 (Stuck during setup?); Sources/ControllerModel.swift:6211-6214 resetAccessibilityAndAddAgain()",
              groups: [Terms.accessibility], boosts: ["accessibility", "dictation", "stuck"]),
        Entry(id: "glasses", title: "The glasses will not connect",
              answer: "The phone has to reach this Mac. Check that the Mac is awake and the COS server answers. Away from home, Tailscale must be on for both the Mac and the iPhone, and the server URL in the companion's COS settings, under System, Connection, must be the Mac's 100.x address. After a server restart, force-quit the Even app and reopen it.",
              actions: [.startServer, .repairRuntime, .openTailscale, .openSetupGuide],
              source: "cos-starter docs/index.html:1984 (Query failed. Check COS server connection.), :2000 (Restarted the server?), :1037 (Same Wi-Fi or anywhere), :1940 (System, Connection: server URL)",
              groups: [Terms.glasses, Terms.connect + Terms.fail + Terms.pairing],
              phrases: ["query failed"], boosts: ["tailscale", "mac", "glasses", "g2"]),
        Entry(id: "provider", title: "Your AI app is not connected",
              answer: "Open your AI app and sign in, then choose Check again in the setup guide. Claude Desktop alone is not Claude Code. Sign-in happens on the Mac: run claude auth login or codex login in Terminal, then choose Check again.",
              actions: [.openSetupGuide],
              source: "cos-starter control/docs/index.html:1204 (Your AI is not detected), :1208 (Claude or Codex needs sign-in)",
              groups: [Terms.provider, Terms.connect + Terms.fail + Terms.signIn], boosts: ["claude", "codex", "cursor", "provider"]),
        Entry(id: "server", title: "The COS server is not connected",
              answer: "COS Control runs the server for you. If it is stopped, Start brings it back. If it will not start or answer, Repair reinstalls its background service and checks it. If Settings says Ownership conflict, another server owns the COS ports: stop the one you started in Terminal with Control-C.",
              actions: [.startServer, .repairRuntime, .setUp, .runDoctor],
              source: "cos-starter control/docs/index.html:1212 (Server setup fails); Sources/Views.swift:1823-1838 (Restart, Stop, Start); HelperSources/main.swift:4089 (Run Repair instead of forcing Start)",
              groups: [Terms.server, Terms.connect + Terms.fail + Terms.stuck], boosts: ["cos server", "running"]),
        Entry(id: "mac-recording", title: "Start or stop a Mac recording",
              answer: "COS records what this Mac plays and your microphone stays off, so let people know. Use Start recording here, or Record under Record on Mac in Meetings. Stop and save ends it, and the meeting opens in Meetings once it is saved. A recording stops at two hours and keeps everything up to then. Mac recording needs macOS 14.2 or later.",
              actions: [.openMeetings],
              source: "cos-starter control/docs/index.html:884 (needs macOS 14.2), :890 (Record under Record on Mac), :916 (Stop and save), :923 (two hours); Sources/MacRecording.swift MacRecordingPanel, MacRecordingNotice",
              groups: [],
              phrases: ["start recording", "start a recording", "stop recording", "stop a recording", "stop the recording", "record this meeting", "record a meeting",
                        "record my meeting", "record the meeting", "how do i record", "how to record", "record on mac", "record this mac", "record my mac"]),
        Entry(id: "transcript-unfinished", title: "A transcript never finished",
              answer: "Saving can take a while after a long meeting. In Meetings, if it says Saved meeting not found yet, wait for it to finish and choose Refresh. Audio that never became a meeting stays on this Mac under Unsaved recordings, with Recover. If Whisper has stopped, Repair Whisper restarts the COS server and Whisper together.",
              actions: [.openMeetings, .repairWhisper],
              source: "cos-starter control/docs/index.html:919, :1206 (A saved Mac recording is not in Meetings); Sources/ActivityMeetings.swift unsavedCaptureBanner (Unsaved recordings, Recover), Saved meeting not found yet",
              groups: [],
              phrases: ["transcript never finished", "transcript never finishes", "transcript didnt finish", "transcript did not finish", "transcript not finished",
                        "transcript isnt finished", "transcript is missing", "transcript missing", "no transcript", "where is my transcript", "meeting never saved",
                        "meeting never finished", "meeting did not save", "meeting didnt save", "recording never saved", "recording did not save", "recording didnt save",
                        "still saving", "stuck saving"]),
        Entry(id: "dictation-use", title: "Use dictation",
              answer: "Turn on Dictate into Mac apps in Settings, Dictation, then set a shortcut. Push to talk listens while you hold the key and transcribes when you let go. Start and stop takes one press to start and one to stop. Allow typing in apps lets COS type for you. Dictation uses your microphone and runs on this Mac.",
              actions: [.openDictationSettings],
              source: "cos-starter control/docs/index.html:730-741 (Turn it on and pick a shortcut); Sources/SettingsHubCatalog.swift DI-01, DI-05, DI-06, DI-08; Sources/MacDictationCore.swift shortcut names",
              groups: [],
              phrases: ["how do i use dictation", "how does dictation work", "how to use dictation", "how do i dictate", "how to dictate", "use dictation", "start dictation",
                        "start dictating", "turn on dictation", "set up dictation", "setup dictation", "dictation shortcut", "dictate into apps"]),
        Entry(id: "voice-rename", title: "Rename a voice",
              answer: "Speakers has three lists: Meetings to review, Samples to review and Voices. To fix a name, open the meeting under Meetings to review and choose Actually someone else on that voice, or Name this voice if it was never named. It asks whether to change this meeting or everywhere before it renames anything. A saved Mac recording has Rename voice in Meetings. Voice names are suggestions, never certainties.",
              actions: [.openSpeakers],
              source: "cos-starter control/docs/index.html:686 (Three lists); Sources/ActivityWindow.swift SpeakerSubview; Sources/Views.swift voice rows (Name this voice, Actually someone else, the rename confirm); Sources/ActivityMeetings.swift and Sources/Models.swift menuTitle (Rename voice)",
              groups: [],
              phrases: ["rename a voice", "rename voice", "rename a speaker", "rename speaker", "rename the speaker", "speaker names wrong", "speaker name wrong", "speaker name is wrong",
                        "speaker names are wrong", "wrong speaker", "wrong speaker name", "wrong name on a voice", "fix a speaker name", "fix speaker name", "name a voice",
                        "name a speaker", "name this voice"]),
    ]

    /// Lower case, accents folded, apostrophes dropped ("won't" is "wont"), everything else a single space, padded so a
    /// term matches whole words only.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var out = ""
        var space = true
        for scalar in folded.unicodeScalars {
            if scalar == "'" || scalar == "\u{2019}" { continue }
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar); space = false
            } else if !space {
                out.append(" "); space = true
            }
        }
        return " " + out.trimmingCharacters(in: .whitespaces) + " "
    }

    static let maxQuestion = 500

    /// The best entry for these words, or nil. Only the words choose: nothing typed reaches an action except by picking
    /// an entry.
    static func match(_ text: String) -> Entry? {
        let words = normalized(String(text.prefix(maxQuestion)))
        guard words.count > 2 else { return nil }
        func has(_ term: String) -> Bool { words.contains(normalized(term)) }
        var best: (entry: Entry, score: Int)?
        for entry in entries {
            var score = 0
            if entry.phrases.contains(where: has) {
                score = 30
            } else if !entry.groups.isEmpty, entry.groups.allSatisfy({ $0.contains(where: has) }) {
                score = 10 * entry.groups.count
            }
            guard score > 0 else { continue }
            score += entry.boosts.filter(has).count
            if score > (best?.score ?? 0) { best = (entry, score) }
        }
        return best?.entry
    }

    /// The matched entry with its offers for this state: at most two, each ready or held, never one that does not apply.
    static func answer(_ text: String, _ s: Snapshot) -> Answer? {
        guard let entry = match(text) else { return nil }
        var offers: [Offer] = []
        for action in entry.actions where offers.count < 2 {
            switch gate(action, s) {
            case .ready: offers.append(Offer(action: action, title: action.title, held: nil))
            case .held(let reason): offers.append(Offer(action: action, title: action.title, held: reason))
            case .notApplicable: continue
            }
        }
        var text = entry.answer
        if entry.namesRestartHold, case .held(let reason) = gate(.restartServer, s) { text += " Right now: " + reason }
        return Answer(entry: entry, text: text, offers: offers)
    }

    // MARK: - Ask COS to troubleshoot

    struct Troubleshoot: Sendable, Equatable {
        /// The Work target. "today:" so Today's in-flight check holds one run per target.
        var target: String
        var title: String
        var prompt: String
        var context: String
    }

    static let targetPrefix = "today:troubleshoot:"
    static let maxPacket = 12_000

    /// The Work run for "Ask COS to troubleshoot": nil unless its gate is ready (the server answers and Work runs are on).
    /// `report` is the helper's `report` output (doctorDetails(redacted: true)); it is capped and any home path is cut to
    /// "~" again in case one slipped through. The person's words go in as a quoted question, never as a command.
    static func troubleshoot(question: String, _ s: Snapshot, report: String?, id: String, asked: String) -> Troubleshoot? {
        guard gate(.troubleshoot, s) == .ready else { return nil }
        let words = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxQuestion))
        let packet = report.map { scrubbed(String($0.prefix(maxPacket))) } ?? "The redacted report could not be read."
        let prompt = """
        Someone needs help with COS on their own Mac. Diagnose the problem and propose a fix. Do not change anything yet.

        Their words: "\(words)"

        Rules:
        - Read what COS Control sees and the Doctor packet below first. Paths and names in the packet are redacted.
        - Say what is wrong in two or three short sentences, then propose the smallest fix.
        \(runRules)
        - If you cannot tell, say what you would check next and why.

        What COS Control sees now:
        \(seen(s).map { "- " + $0 }.joined(separator: "\n"))

        Doctor packet (redacted):
        \(packet)
        """
        return Troubleshoot(target: targetPrefix + id, title: "Troubleshoot: " + String(words.prefix(48)), prompt: prompt,
                            context: "Asked from Ask COS setup help on \(asked).")
    }

    /// The rules every run this assistant starts carries (troubleshoot and Ask COS).
    static let runRules = """
    - Ask before you run anything that changes this Mac: installs, restarts, deleting files, System Settings.
    - Never use sudo, pkill or killall. Never restart the COS server while a meeting is recording or a job is running.
    - Prefer COS Control's own buttons when one fits: Run Doctor, Repair Managed Runtime, Repair Whisper, Restart, Update Server, Reset and add again.
    """

    /// What COS Control sees now, as short lines for a prompt.
    static func seen(_ s: Snapshot) -> [String] {
        let errors = s.checks.filter { $0.state == "error" }.map(\.name)
        let warnings = s.checks.filter { $0.state == "warning" }.map(\.name)
        var seen: [String] = [
            "Server: " + (s.serverReachable ? "answering" : "not answering") + " (state \(s.runtimeState))",
            "Running work: \(s.activeJobs) jobs, \(s.activeTranscriptionSessions) recordings" + (s.macRecordingActive ? ", a Mac recording" : ""),
        ]
        if !s.appUpdate.currentVersion.isEmpty {
            seen.append("COS Control \(s.appUpdate.currentVersion)" + (s.appUpdate.available ? ", \(s.appUpdate.latestVersion ?? "a newer build") offered" : ""))
        }
        if s.checks.isEmpty {
            seen.append("Doctor: not run yet")
        } else {
            seen.append("Doctor: \(s.checks.count - errors.count - warnings.count) ok, \(warnings.count) warnings, \(errors.count) errors")
            seen += errors.map { "Doctor error: " + $0 } + warnings.map { "Doctor warning: " + $0 }
        }
        return seen
    }

    /// Any "/Users/<name>" left in the packet becomes "~".
    static func scrubbed(_ text: String) -> String {
        text.replacingOccurrences(of: "/Users/[^/\"\\s]+", with: "~", options: .regularExpression)
    }

    // MARK: - The command center (⌘K)

    /// What the ⌘K panel lists and what each key does, from plain values the window builds on each frame. No views and no
    /// app types: Tests/SetupAssistantChecks.swift runs every rule here against fixtures. Only the view knows how to run a
    /// row (ActivityWindow's Command center extension), and its switches have no default, so a new case will not compile
    /// until it is dispatched.
    enum Center {

        // MARK: Commands

        /// The closed command list. Typed words choose one by phrase; nothing typed reaches it any other way.
        enum Command: String, CaseIterable, Sendable {
            case startRecording, stopRecording, openSessions, openMeetings, openWork, openSpeakers, openDictation, openMemories, openSettings, runDoctor

            var title: String {
                switch self {
                case .startRecording: return "Start recording"
                case .stopRecording: return "Stop and save"
                case .openSessions: return "Open Sessions"
                case .openMeetings: return "Open Meetings"
                case .openWork: return "Open Work"
                case .openSpeakers: return "Open Speakers"
                case .openDictation: return "Open Dictation"
                case .openMemories: return "Open Memories"
                case .openSettings: return "Open Settings"
                case .runDoctor: return "Run Doctor"
                }
            }

            /// The words that name it, in full. A row is highlighted on its own only when the whole text is one of these.
            var phrases: [String] {
                func opener(_ name: String) -> [String] { [name, "open " + name, "go to " + name, "show " + name] }
                switch self {
                case .startRecording:
                    return ["start recording", "start a recording", "record", "record this mac", "record on mac", "record this meeting", "record a meeting", "start mac recording"]
                case .stopRecording:
                    return ["stop recording", "stop a recording", "stop the recording", "stop and save", "stop mac recording", "end recording", "save recording"]
                case .openSessions: return opener("sessions")
                case .openMeetings: return opener("meetings")
                case .openWork: return opener("work") + opener("tasks")
                case .openSpeakers: return opener("speakers")
                case .openDictation: return opener("dictation")
                case .openMemories: return opener("memories")
                case .openSettings: return opener("settings")
                case .runDoctor: return ["doctor", "run doctor", "checkup", "run a checkup", "run a full checkup"]
                }
            }

            /// Return may run it straight from an exact phrase: the openers and Start recording. Never Stop, never Doctor,
            /// and an Action is never a Command, so nothing in `changesSomething` can get here.
            var autoHighlights: Bool {
                switch self {
                case .stopRecording, .runDoctor: return false
                default: return true
                }
            }
        }

        // MARK: Places

        /// A pane or a tab the panel can go to (Miles, 2026-10-31: "the tabs that are available for each of those panes would be
        /// surfaced and I'd be able to navigate to them"). Closed, local and instant: no model, no network. Separate from
        /// `Command`, which keeps its openers. Where a pane has an Open command (Sessions, Meetings, Work, Speakers, Dictation,
        /// Memories, Settings) that command is the pane's row and only its tabs are places; Today, Messages and Threads have no
        /// command, so they are places. The window runs one with `commandGo`, a switch with no default. Not in 0.5.361: the Settings
        /// hub groups (the hub has its own search), the Dictation settings sections, Work's layout (it needs a new setter) and the
        /// Memories tabs (they are a web view that reads its view once, when it is made).
        enum Place: String, CaseIterable, Sendable {
            case today, messages, threads
            case messagesRecent, messagesArchive
            case speakersMeetings, speakersSamples, speakersVoices
            case sessionsUsage, sessionsCost
            case workAll, workNeeds, workProgress, workCompleted
            case dictationHistory, dictationDictionary, dictationSettings

            var title: String {
                switch self {
                case .today: return "Open Today"
                case .messages: return "Open Messages"
                case .threads: return "Open Threads"
                case .messagesRecent: return "Recent"
                case .messagesArchive: return "Archive"
                case .speakersMeetings: return "Meetings to review"
                case .speakersSamples: return "Samples to review"
                case .speakersVoices: return "Voices"
                case .sessionsUsage: return "Usage"
                case .sessionsCost: return "COS cost"
                case .workAll: return "All work"
                case .workNeeds: return "Needs attention"
                case .workProgress: return "In progress"
                case .workCompleted: return "Completed"
                case .dictationHistory: return "History"
                case .dictationDictionary: return "Dictionary"
                case .dictationSettings: return "Dictation settings"
                }
            }

            /// The pane a tab lives in. Nil for a pane.
            var parent: String? {
                switch self {
                case .today, .messages, .threads: return nil
                case .messagesRecent, .messagesArchive: return "Messages"
                case .speakersMeetings, .speakersSamples, .speakersVoices: return "Speakers"
                case .sessionsUsage, .sessionsCost: return "Sessions"
                case .workAll, .workNeeds, .workProgress, .workCompleted: return "Work"
                case .dictationHistory, .dictationDictionary, .dictationSettings: return "Dictation"
                }
            }

            /// The words that name it. "open", "go to" and "show" are added when the words are read, not stored.
            var names: [String] {
                switch self {
                case .today: return ["today", "home"]
                case .messages: return ["messages"]
                case .threads: return ["threads"]
                case .messagesRecent: return ["recent", "messages recent", "recent messages"]
                case .messagesArchive: return ["archive", "messages archive"]
                case .speakersMeetings: return ["meetings to review", "speakers meetings", "speaker meetings"]
                case .speakersSamples: return ["samples to review", "voice samples", "speakers samples"]
                case .speakersVoices: return ["voices", "speakers voices", "voice directory"]
                case .sessionsUsage: return ["usage", "session usage", "sessions usage", "token usage"]
                case .sessionsCost: return ["cos cost", "sessions cost", "cost"]
                case .workAll: return ["all work", "work all"]
                case .workNeeds: return ["needs attention", "work needs attention"]
                case .workProgress: return ["in progress", "work in progress"]
                case .workCompleted: return ["completed", "work completed"]
                case .dictationHistory: return ["dictation history", "history"]
                case .dictationDictionary: return ["dictionary", "dictation dictionary"]
                case .dictationSettings: return ["dictation settings"]
                }
            }
        }

        /// Every phrase the noun list answers to, for the check that enumerates every exact name.
        static var nounPhrases: [String] { nounForms.keys.sorted() }

        /// Names that two kinds of row both answer to, and who wins. Commands first, then panes, then tabs. "sessions" is the Sessions
        /// opener and the noun list: the opener runs, and the sessions are listed under it. "recent" is Messages > Recent and the noun
        /// list: the list wins and nothing highlights ("noun"). "voices" is only the Voices tab (0.5.361): it was also a Speakers opener,
        /// which landed on Meetings to review, so it is no shared name. A new shared name fails a check until it is declared here.
        static let sharedNames: [String: String] = ["sessions": "command:openSessions", "recent": "noun"]

        /// Each place's names, normalized once. The panel builds a listing several times a keystroke, and `normalized` builds a Locale.
        private static let placeNames: [Place: [String]] = Dictionary(uniqueKeysWithValues: Place.allCases.map { place in (place, place.names.map(plain)) })

        private static let openerVerbs = ["open ", "go to ", "show "]

        /// The places these words reach, closest first (panes are declared before tabs, so a pane comes before a tab at the same rank), at
        /// most `cap` of them. `typed` is
        /// `plain(words)`.
        static func visiblePlaces(_ typed: String, question: Bool, among places: [Place] = Place.allCases, cap: Int = placeCap) -> [(place: Place, rank: Int)] {
            let found = places.enumerated().compactMap { index, place in
                placeRank(place, typed, question: question).map { (place: place, rank: $0, order: index) }
            }.sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }
            return found.prefix(cap).map { (place: $0.place, rank: $0.rank) }
        }

        /// How a place matches the words, as `commandRank` does for a command: 0 is a whole name ("usage", "go to usage"), 1 the start
        /// of a name (three letters or more, so "us" reaches nothing), 2 a name that begins a longer sentence ("usage limit reached")
        /// or a question. A 2 is listed and Return passes over it. Nil: no match. `typed` is `plain(words)`.
        static func placeRank(_ place: Place, _ typed: String, question: Bool) -> Int? {
            var core = typed
            for verb in openerVerbs where typed.hasPrefix(verb) && typed.count > verb.count {
                core = String(typed.dropFirst(verb.count))
                break
            }
            guard !core.isEmpty, let names = placeNames[place] else { return nil }
            if names.contains(core) { return question ? 2 : 0 }
            guard core.count >= 3 else { return nil }
            if names.contains(where: { $0.hasPrefix(core) || $0.split(separator: " ").contains { $0.hasPrefix(core) } }) { return 1 }
            if names.contains(where: { core.hasPrefix($0 + " ") }) { return 2 }
            return nil
        }

        // MARK: The noun list

        /// How far back "sessions today" reads.
        enum Span: Sendable { case all, today, yesterday, week }

        /// "session", "sessions", "recent" and "running" list sessions (Miles: searching "sessions" should "pull up all of my existing
        /// sessions"), alone or with a day. A closed set of whole phrases: a sentence that holds one of these words is not a list.
        private static let nounForms: [String: Span] = {
            var out: [String: Span] = [:]
            let days: [(String, Span)] = [("today", .today), ("from today", .today), ("yesterday", .yesterday), ("from yesterday", .yesterday),
                                          ("this week", .week), ("from this week", .week)]
            for noun in ["session", "sessions", "recent", "recent sessions", "my sessions", "all sessions"] {
                out[noun] = .all
                for (suffix, span) in days { out[noun + " " + suffix] = span }
            }
            // "running" lists what runs and what waits (0.5.361), now. It has no day words: nothing runs "yesterday".
            for noun in ["running", "running sessions"] { out[noun] = .all }
            return out
        }()

        /// "running" and "running sessions" list what runs and what waits. Every other noun lists the whole list.
        static func isRunningList(_ typed: String) -> Bool { typed == "running" || typed == "running sessions" }

        /// The list these words ask for, or nil. `typed` is `plain(words)`. A question mark is a question, never a list.
        static func nounSpan(_ typed: String, question: Bool) -> Span? { question ? nil : nounForms[typed] }

        static func inSpan(_ date: Date?, _ span: Span, now: Date, calendar: Calendar) -> Bool {
            switch span {
            case .all: return true
            case .today: return date.map { calendar.isDate($0, inSameDayAs: now) } ?? false
            case .yesterday:
                guard let date, let day = calendar.date(byAdding: .day, value: -1, to: now) else { return false }
                return calendar.isDate(date, inSameDayAs: day)
            case .week:
                guard let date, let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return false }
                return week.contains(date)
            }
        }

        static func spanWords(_ span: Span) -> String {
            switch span {
            case .all: return ""
            case .today: return "today"
            case .yesterday: return "yesterday"
            case .week: return "this week"
            }
        }

        /// "today", "yesterday", "5 days ago". Nil with no date.
        static func when(_ date: Date?, now: Date, calendar: Calendar) -> String? {
            guard let date else { return nil }
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
            if days <= 0 { return "today" }
            if days == 1 { return "yesterday" }
            if days < 14 { return "\(days) days ago" }
            if days < 60 { return "\(days / 7) weeks ago" }
            return "\(days / 30) months ago"
        }

        // MARK: One session, listed once

        /// Two `provider:native` ids name one session when the provider matches and the native ids are equal, or one is the first 8 or
        /// more characters of the other (the live list gives a Claude session by its first 8). The same rule as
        /// `ClaudeSession.sameSession` (Sources/Models.swift), which this file cannot import; Tests/setup-assistant-pins.py holds the
        /// two bodies equal.
        static func sameSession(_ a: String, _ b: String) -> Bool {
            let x = a.split(separator: ":", maxSplits: 1).map { String($0).lowercased() }
            let y = b.split(separator: ":", maxSplits: 1).map { String($0).lowercased() }
            guard x.count == 2, y.count == 2, x[0] == y[0], !x[1].isEmpty, !y[1].isEmpty else { return false }
            if x[1] == y[1] { return true }
            let (short, long) = x[1].count <= y[1].count ? (x[1], y[1]) : (y[1], x[1])
            return short.count >= 8 && long.hasPrefix(short)
        }

        /// The same session, or the same row id with no provider in it (a Today row id is not always `provider:native`).
        static func sameListed(_ a: String, _ b: String) -> Bool { a == b || sameSession(a, b) }

        /// Ids that can be the same session share this key, so a list of hundreds merges in one pass.
        private static func sessionKey(_ id: String) -> String {
            let parts = id.split(separator: ":", maxSplits: 1).map { String($0).lowercased() }
            guard parts.count == 2, !parts[1].isEmpty else { return id.lowercased() }
            return parts[0] + ":" + String(parts[1].prefix(8))
        }

        /// The loaded list and the live rows as one list: a session in both lists once (the live row wins and takes the list's date
        /// when it has none), warm-ups gone, newest first, undated last. With the pet on the live rows are all `todaySessions` has,
        /// so a list built from them alone had no "recent" in it.
        static func merged(live: [Item], listed: [Item]) -> [Item] {
            var out: [Item] = []
            var byKey: [String: [Int]] = [:]
            for item in live + listed where !item.keepWarm {
                if let id = item.sessionID {
                    let key = sessionKey(id)
                    if let at = byKey[key]?.first(where: { out[$0].sessionID.map { sameListed($0, id) } ?? false }) {
                        if out[at].date == nil { out[at].date = item.date }
                        continue
                    }
                    byKey[key, default: []].append(out.count)
                }
                out.append(item)
            }
            return out.enumerated().sorted { a, b in
                switch (a.element.date, b.element.date) {
                case let (x?, y?): return x != y ? x > y : a.offset < b.offset
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return a.offset < b.offset
                }
            }.map(\.element)
        }

        // MARK: Word search

        /// The words the local search ignores: the helper's (`sessionSearchStopwords`) and the Sessions tab's, which Tests/setup-assistant-pins.py holds equal.
        static let searchStopwords: Set<String> = ["the", "a", "an", "and", "or", "of", "to", "in", "for", "on", "at", "by", "with", "from", "vs", "is", "it", "be", "as", "we", "our"]

        /// What a search would look for in these words: two letters or more, no stopword, no repeat. "the" has none, and searching for
        /// nothing would say "no match" about a question that was never asked. `typed` is `plain(words)`.
        static func searchTokens(_ typed: String) -> [String] {
            var seen = Set<String>()
            return typed.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 && !searchStopwords.contains($0) && seen.insert($0).inserted }
        }

        enum SearchPhase: Sendable { case idle, searching, done, failed }

        /// What the local word search found for one set of words. The panel owns the search (its words, its debounce, its one run at a
        /// time); the core only draws the result, and only for the words that are in the box now.
        struct Found: Equatable, Sendable {
            /// `plain(words)` these hits are for.
            var words = ""
            var phase = SearchPhase.idle
            var hits: [Item] = []
        }

        /// A search for the same words that finishes again never takes away a hit the person has already chosen with a key.
        static func refreshed(_ old: Found, words: String, hits: [Item], keeping chosen: String?) -> Found {
            var kept = hits
            if old.words == words, let chosen, let gone = old.hits.first(where: { "hit:" + $0.id == chosen }), !kept.contains(where: { $0.id == gone.id }) {
                kept.insert(gone, at: 0)
            }
            return Found(words: words, phase: .done, hits: kept)
        }

        /// What VoiceOver hears when hits arrive: fixed words and a count, never what a session said.
        static func foundAnnouncement(_ count: Int) -> String { count == 1 ? "1 session found" : "\(count) sessions found" }

        static let hidden = "[hidden]"
        static let matchCap = 120

        /// Text that looks like a key, a token or a secret, replaced by shape (not by a list of known secrets).
        private static let keyShapes = [
            #"\b(?:sk|pk|rk|sess)[-_][A-Za-z0-9_\-]{16,}"#,
            #"\bgh[pousr]_[A-Za-z0-9]{16,}|\bgithub_pat_[A-Za-z0-9_]{16,}"#,
            #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#,
            #"\b(?:AKIA|ASIA)[0-9A-Z]{12,}"#,
            #"\beyJ[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]{6,}"#,
            #"(?i)\bbearer\s+[A-Za-z0-9._~+/\-]{16,}=*"#,
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----[^-]*(?:-----END [A-Z ]*PRIVATE KEY-----)?"#,
            #"(?i)\b(?:api[_-]?key|token|secret|password|passwd)\s*[:=]\s*\S{6,}"#,
            #"(?<![A-Za-z0-9_\-])(?=[A-Za-z0-9_\-]*[A-Za-z])(?=[A-Za-z0-9_\-]*[0-9])[A-Za-z0-9_\-]{32,}(?![A-Za-z0-9_\-])"#,
        ]

        static func mask(_ text: String) -> String {
            keyShapes.reduce(text) { $0.replacingOccurrences(of: $1, with: hidden, options: .regularExpression) }
        }

        /// A hit's title: one line like every title, and masked.
        static func hitTitle(_ title: String) -> String { mask(clean(title)) }

        /// The line a hit shows under its title, or nil. Cleaned like a title, masked, bounded, and dropped when all it says is the title
        /// again (the helper's window can begin with the title itself). Match text only draws; it decides nothing.
        static func matchLine(_ snippet: String?, title: String) -> String? {
            guard let snippet else { return nil }
            var text = mask(clean(snippet))
            let own = hitTitle(title)
            if !own.isEmpty, let range = text.range(of: own, options: [.caseInsensitive, .anchored]) {
                text = String(text[range.upperBound...]).trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
            }
            let said = plain(text)
            let named = plain(own)
            if said.count < 4 || said == named || named.contains(said) { return nil }
            return String(text.prefix(matchCap))
        }

        // MARK: Rows

        enum Kind: Equatable, Sendable {
            /// Opens by id: the window looks the row up again at open, so a session that went away never opens stale.
            case recording(String), waiting(String), running(String), session(String)
            case command(Command), action(Action)
            /// A pane or a tab (Place). It opens by a closed switch in the window, like a command.
            case place(Place)
            /// A word-search hit. The panel keeps the hit's own session and opens that object, so a session older than the list opens too.
            case hit(String)
            /// Opens Sessions with the words in its search box, for anything older than the local search reaches.
            case searchAll
            case ask, file
            /// Words only: the saved answer, and lines like "Nothing is running."
            case savedAnswer, info
        }

        /// What a row is. A rule between groups is the only section marking.
        enum Group: Int, Sendable { case recording, waiting, running, doing, fixing, commands, places, sessions, found, answer, asking }

        struct Row: Identifiable, Equatable, Sendable {
            var id: String
            var kind: Kind
            var group: Group
            var title: String
            var detail: String? = nil
            /// The word on the row itself: Waiting, Running, Saved answer.
            var state: String? = nil
            /// What running it does (Open in Claude, Repair Whisper).
            var trailing: String? = nil
            /// Why it waits. A held row has no action.
            var held: String? = nil
            /// The line the local search matched, for a hit. Not named `why`: that word is banned in the view half.
            var match: String? = nil
            /// For a waiting, running, listed or hit row: opening it closes the session that is open in Sessions, and with it a reply typed
            /// and not sent. A platform open (the app's own window) clears nothing. The window decides, from the open path it will take.
            var leavesSession = false

            var selectable: Bool {
                switch kind {
                case .savedAnswer, .info: return false
                default: return held == nil
                }
            }
            /// For a log line: never a title or anything typed.
            var logName: String {
                switch kind {
                case .recording: return "recording"
                case .waiting: return "waiting"
                case .running: return "running"
                case .session: return "session"
                case .command(let command): return "command." + command.rawValue
                case .action(let action): return "action." + action.rawValue
                case .place(let place): return "place." + place.rawValue
                case .hit: return "hit"
                case .searchAll: return "search"
                case .ask: return "ask"
                case .file: return "file"
                case .savedAnswer: return "answer"
                case .info: return "info"
                }
            }
        }

        /// A waiting, running or listed session, as plain values. Titles are cleaned where the row is made.
        struct Item: Equatable, Sendable {
            var id: String
            var title: String
            var detail: String? = nil
            var openLabel: String? = nil
            /// 1 blocks an agent; waiting rows list by tier.
            var tier = 1
            /// The session behind the row, so one session lists once.
            var sessionID: String? = nil
            var state: String? = nil
            /// When it last moved: newest first in the noun list, and what "sessions today" reads.
            var date: Date? = nil
            /// A warm-up the app keeps open. Never listed.
            var keepWarm = false
            /// The text the local search matched. Cleaned, masked and shortened where the row is made.
            var match: String? = nil
            /// Opening it takes the person out of the open session (a Sessions row, a held Work or routine run, Cursor without Accessibility).
            var leavesSession = false
        }

        /// One live recording, for the rows above everything else. Stop and save reaches only this Mac's own capture.
        struct LiveRecording: Equatable, Sendable {
            var id: String
            var title: String
            var detail: String
            var isMac = false
            var canStop = false
            /// Where it stops when Stop and save cannot reach it.
            var stopNote: String? = nil
        }

        /// The Mac recording, as plain values. `busy` is MeetingDetectedCard.recordingBusy, which also counts a glasses
        /// meeting (`canStart` alone does not, and `recordingCount` must never decide Stop).
        struct Recording: Equatable, Sendable {
            /// macOS 14.2 or later.
            var osSupported = true
            /// Recording or starting: the only time Stop and save is offered.
            var stoppable = false
            var starting = false
            var occupied = false
            var busy = false
            /// Saving… from Stop until it has saved. Nil once it has, or once the save stopped on an error (Meetings has Retry).
            var saveLine: String? = nil
            /// Recordings live right now that are not this Mac's capture. Named for the glasses, but a phone or a recording whose
            /// device is not known counts too: `knownGlasses` says whether the words may call them glasses meetings.
            var glassesLive = 0
            /// Every one of those is known to be on the glasses. Anything else gets neutral words.
            var knownGlasses = false
            /// A start from the panel is on its way.
            var inFlight = false
        }

        struct Inputs: Equatable, Sendable {
            var snapshot = Snapshot()
            /// What is recording now: the first rows on an empty box.
            var live: [LiveRecording] = []
            /// What the quiet-hours fold leaves now.
            var waiting: [Item] = []
            /// False while the overview has not loaded: "not loaded", never "nothing waiting".
            var waitingKnown = false
            /// How many things the quiet-hours fold moved to tomorrow. Today's headline reads the same count.
            var foldedCount = 0
            var running: [Item] = []
            var runningKnown = false
            /// Listed sessions: the loaded list and the live rows merged (`merged`), newest first. Searched by title once words are
            /// typed, and listed whole by the noun list.
            var sessions: [Item] = []
            /// The session list answered. Until then the noun list says "not loaded yet", never "no sessions".
            var sessionsLoaded = false
            /// For "today", "yesterday" and "3 days ago". The tests set both.
            var now = Date(timeIntervalSince1970: 0)
            var calendar = Calendar(identifier: .gregorian)
            /// What the word search found so far for the words in the box. The panel owns the search; this is only its result.
            var found = Found()
            /// Settings: session tracking is off, so waiting and running sessions cannot show.
            var sessionsOff = false
            var recording = Recording()
            /// The run started from here, listed first so a row opens it.
            var startedRunID: String? = nil
        }

        static let waitingCap = 3
        static let runningCap = 3
        static let fixCap = 2
        static let commandCap = 4
        /// Tabs under one pane name: "work" lists its four.
        static let placeCap = 6
        static let sessionCap = 5
        /// The noun list shows this many, then "N more in Sessions".
        static let nounCap = 8
        /// Word-search hits shown at once.
        static let hitCap = 5
        static let titleCap = 160

        /// One line, control and direction characters gone, whitespace collapsed, bounded. Session titles come from outside
        /// the app: a title must not fake a second row, reorder what is drawn or carry a hidden instruction.
        static func clean(_ text: String) -> String {
            var out = String.UnicodeScalarView()
            var space = true
            for scalar in text.unicodeScalars {
                if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    if !space { out.append(" "); space = true }
                } else if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.illegalCharacters.contains(scalar) {
                    continue
                } else {
                    out.append(scalar); space = false
                }
            }
            return String(String(out).trimmingCharacters(in: .whitespaces).prefix(titleCap))
        }

        /// The words without the padding `normalized` adds.
        static func plain(_ text: String) -> String {
            normalized(String(text.prefix(maxQuestion))).trimmingCharacters(in: .whitespaces)
        }

        // MARK: Recording gates

        enum RecordingHeld {
            static let starting = "Starting the recording…"
            static let os = "Mac recording needs macOS 14.2 or later."
            static let saving = "The last recording is still saving."
            static let unsaved = "The last recording has not saved yet. Meetings shows it."
            static let glasses = "A glasses meeting is recording, so this Mac does not record it twice."
            static let other = "Another recording is running, so this Mac does not record it twice."
            static let server = "Recording needs the COS server. Start it first."
        }

        /// Why Start recording waits, or nil. Refused System Audio is not here: it still records, as today.
        static func recordingHold(_ r: Recording, _ s: Snapshot) -> String? {
            if r.inFlight { return RecordingHeld.starting }
            if !r.osSupported { return RecordingHeld.os }
            if r.busy {
                if r.occupied || r.saveLine != nil { return RecordingHeld.saving }
                return r.glassesLive > 0 ? (r.knownGlasses ? RecordingHeld.glasses : RecordingHeld.other) : RecordingHeld.unsaved
            }
            return s.serverReachable ? nil : RecordingHeld.server
        }

        // MARK: The rows

        private static func commandRow(_ command: Command, _ inputs: Inputs, group: Group) -> Row? {
            let s = inputs.snapshot
            let r = inputs.recording
            var row = Row(id: "command:" + command.rawValue, kind: .command(command), group: group, title: command.title)
            switch command {
            case .startRecording:
                if r.stoppable { return nil }
                row.detail = "Record this Mac's audio. Microphone off."
                row.held = recordingHold(r, s)
            case .stopRecording:
                guard r.stoppable else { return nil }
                row.detail = "Stops this Mac's recording and saves the meeting."
                // Under its recording's own row the word is already on the line above.
                row.state = r.starting ? "Starting" : (group == .recording ? nil : "Recording")
            case .runDoctor:
                row.detail = "Checks the server, Whisper and your AI apps."
                if case .held(let reason) = gate(.runDoctor, s) { row.held = reason }
            case .openSessions, .openMeetings, .openWork, .openSpeakers, .openDictation, .openMemories, .openSettings:
                break
            }
            return row
        }

        static let glassesLine = "A glasses meeting is recording. Stop it on the glasses."
        static let otherLine = "Another recording is running. Stop it where it started."
        /// Where another recording stops, in words that fit what is known about it.
        static func elsewhereLine(_ r: Recording, alone: Bool = false) -> String {
            if r.knownGlasses { return alone ? "Stop it on the glasses." : glassesLine }
            return alone ? "Stop it where it started." : otherLine
        }

        private static func info(_ id: String, _ group: Group, _ title: String, detail: String? = nil, state: String? = nil) -> Row {
            Row(id: "info:" + id, kind: .info, group: group, title: title, detail: detail, state: state)
        }

        private static func waitingRow(_ item: Item) -> Row {
            Row(id: "waiting:" + item.id, kind: .waiting(item.id), group: .waiting, title: clean(item.title), detail: item.detail.map(clean),
                state: item.tier == 1 ? "Waiting" : nil, trailing: item.openLabel, leavesSession: item.leavesSession)
        }

        private static func runningRow(_ item: Item) -> Row {
            Row(id: "running:" + item.id, kind: .running(item.id), group: .running, title: clean(item.title), detail: item.detail.map(clean),
                state: "Running", trailing: item.openLabel, leavesSession: item.leavesSession)
        }

        /// A button's word beside its question reads fine ("Start"). Alone on a row it has to say what it starts.
        static func rowTitle(_ action: Action) -> String {
            switch action {
            case .setUp: return "Set up COS"
            case .startServer: return "Start the COS server"
            case .restartServer: return "Restart the COS server"
            case .repairRuntime: return "Repair the COS server"
            case .retryAppUpdate: return "Update COS Control"
            default: return action.title
            }
        }

        /// Tier 1 first, otherwise in the order given.
        private static func byTier(_ items: [Item]) -> [Item] {
            items.enumerated().sorted { ($0.element.tier, $0.offset) < ($1.element.tier, $1.offset) }.map(\.element)
        }

        private static func startedFirst(_ items: [Item], _ started: String?) -> [Item] {
            guard let started, let index = items.firstIndex(where: { $0.id == started }) else { return items }
            var out = items
            out.insert(out.remove(at: index), at: 0)
            return out
        }

        /// "6 things can wait until tomorrow". Today's headline (TodayHome.brief) reads the same count in the same words.
        static func canWaitLine(_ count: Int) -> String {
            count == 1 ? "1 thing can wait until tomorrow" : "\(count) things can wait until tomorrow"
        }

        /// An empty box: what waits, what runs, what to do, and what is broken.
        private static func emptyRows(_ inputs: Inputs) -> [Row] {
            let s = inputs.snapshot
            var rows: [Row] = []

            let waiting = byTier(inputs.waiting)
            rows += waiting.prefix(waitingCap).map(waitingRow)
            if waiting.count > waitingCap {
                let more = waiting.count - waitingCap
                rows.append(info("more-waiting", .waiting, more == 1 ? "1 more is waiting on you." : "\(more) more are waiting on you."))
            }
            if waiting.isEmpty {
                // The same words as Today's headline. Everything folded to tomorrow reads as that count; nothing at all reads as
                // "urgent", never "waiting": with session tracking off, sessions cannot be seen, so this cannot say nothing waits.
                if !inputs.waitingKnown {
                    rows.append(info("waiting-unknown", .waiting, "Waiting on you: not loaded yet."))
                } else if inputs.foldedCount > 0 {
                    rows.append(info("no-waiting", .waiting, canWaitLine(inputs.foldedCount)))
                } else {
                    rows.append(info("no-waiting", .waiting, inputs.sessionsOff ? "Nothing else urgent right now." : "Nothing urgent right now."))
                }
            } else if inputs.foldedCount > 0 {
                rows.append(info("folded", .waiting, inputs.foldedCount == 1 ? "1 more can wait until tomorrow." : "\(inputs.foldedCount) more can wait until tomorrow."))
            }

            let running = startedFirst(inputs.running, inputs.startedRunID)
            rows += running.prefix(runningCap).map(runningRow)
            if running.count > runningCap {
                rows.append(info("more-running", .running, "\(running.count - runningCap) more running."))
            }
            if running.isEmpty {
                if inputs.sessionsOff {
                    rows.append(Row(id: "command:openSessions", kind: .command(.openSessions), group: .running, title: "Session tracking is off",
                                    detail: "Turn it on in Sessions to see agents here.", trailing: Command.openSessions.title))
                } else {
                    rows.append(inputs.runningKnown ? info("no-running", .running, "Nothing is running.") : info("running-unknown", .running, "Running: not loaded yet."))
                }
            }

            var fixes: [Row] = []
            if !s.serverReachable && !s.needsFirstRun {
                fixes.append(info("server-down", .fixing, "The COS server is not answering.",
                                  detail: "What is listed here runs on this Mac without it. Typed questions still get saved answers."))
            }
            for suggestion in board(s).suggestions.filter({ $0.tier == .repair }).prefix(fixCap) {
                // By the suggestion's id: two suggestions can share an action (Repair, for an interrupted update and for the recovery controller).
                if let action = suggestion.action {
                    fixes.append(Row(id: "fix:" + suggestion.id, kind: .action(action), group: .fixing, title: suggestion.line, detail: suggestion.why,
                                     trailing: suggestion.actionTitle))
                } else {
                    fixes.append(Row(id: "fix:" + suggestion.id, kind: .info, group: .fixing, title: suggestion.line, detail: suggestion.why, held: suggestion.held))
                }
                if let secondary = suggestion.secondary {
                    fixes.append(Row(id: "fix:" + suggestion.id + ":second", kind: .action(secondary), group: .fixing, title: rowTitle(secondary)))
                }
            }

            let r = inputs.recording

            // What is recording comes first of all, each with its way to stop.
            var live: [Row] = []
            for item in inputs.live {
                let saving = item.isMac && !r.stoppable
                live.append(Row(id: "recording:" + item.id, kind: .recording(item.id), group: .recording, title: clean(item.title),
                                detail: saving ? (r.saveLine ?? item.detail) : ([item.detail] + (item.stopNote.map { [$0] } ?? [])).joined(separator: ". "),
                                state: saving ? "Saving" : nil, trailing: "Live view"))
                if item.canStop, let stop = commandRow(.stopRecording, inputs, group: .recording) { live.append(stop) }
            }
            let macListed = inputs.live.contains { $0.isMac }
            let glassesListed = inputs.live.contains { !$0.isMac }

            if let start = commandRow(.startRecording, inputs, group: .doing) { rows.append(start) }
            if !inputs.live.contains(where: \.canStop), let stop = commandRow(.stopRecording, inputs, group: .doing) { rows.append(stop) }
            if !macListed, !r.stoppable, let line = r.saveLine { rows.append(info("saving", .doing, line, state: "Saving")) }
            if !glassesListed, r.glassesLive > 0 { rows.append(info("glasses", .doing, elsewhereLine(r, alone: !r.stoppable))) }
            if !fixes.contains(where: { $0.kind == .action(.runDoctor) }), let doctor = commandRow(.runDoctor, inputs, group: .doing) { rows.append(doctor) }
            // With the server down the fix comes next: most of the rest leans on it.
            return live + (s.serverReachable ? rows + fixes : fixes + rows)
        }

        /// How a command matches the words: 0 is the whole phrase, 1 a start of a phrase or of one of its words, 2 a phrase
        /// inside longer words. Nil: no match.
        static func commandRank(_ command: Command, _ words: String) -> Int? {
            let typed = plain(words)
            guard !typed.isEmpty else { return nil }
            let phrases = command.phrases.map(plain)
            // A typed question mark is a question, never the whole order: "record a meeting?" is not "record a meeting".
            if phrases.contains(typed) { return words.contains("?") ? 2 : 0 }
            if typed.count >= 2, phrases.contains(where: { $0.hasPrefix(typed) || $0.split(separator: " ").contains { $0.hasPrefix(typed) } }) { return 1 }
            let padded = " " + typed + " "
            if phrases.contains(where: { $0.contains(" ") && padded.contains(" " + $0 + " ") }) { return 2 }
            return nil
        }

        /// Whether the words are the start of one of the command's whole phrases ("start rec"), as opposed to the start of a word inside
        /// one ("meeting", "mac", "on", "me"). Only the first is an order being typed.
        static func startsAPhrase(_ command: Command, _ words: String) -> Bool {
            let typed = plain(words)
            return typed.count >= 2 && command.phrases.map(plain).contains { $0.hasPrefix(typed) }
        }

        /// Words that read as a command when the text is short.
        private static let commandWords: Set<String> = ["start", "stop", "record", "recording", "restart", "repair", "update", "upgrade", "install", "reset", "doctor", "checkup",
                                                        "troubleshoot", "open", "settings", "sessions", "meetings", "speakers", "dictation", "memories", "setup"]

        /// Close to a command without being one ("restart server", "update", "stop recording the demo"). Return never spends
        /// a run on these: it moves to the Ask row first.
        static func nearCommand(_ words: String) -> Bool {
            let typed = plain(words)
            let parts = typed.split(separator: " ").map(String.init)
            if parts.count <= 4, parts.contains(where: commandWords.contains) { return true }
            let padded = " " + typed + " "
            return Command.allCases.contains { $0.phrases.contains { $0.contains(" ") && padded.contains(" " + plain($0) + " ") } }
        }

        /// Why Ask COS waits, or nil.
        static func askHeld(_ s: Snapshot) -> String? {
            if !s.workRunsOn { return "Work runs from Today is off in Settings." }
            return s.serverReachable ? nil : "Asking needs the COS server."
        }

        struct Listing: Equatable, Sendable {
            var rows: [Row] = []
            /// Trimmed and whole, as typed: Return and File to Work take all of it. Matching reads a bounded start of it.
            var words = ""
            /// Runs on Return with nothing else highlighted. Only a full exact phrase of a command or a place that allows it.
            var autoHighlight: String? = nil
            var hasAnswer = false
            var nearCommand = false
            var entry: Entry? = nil
            /// Rows Return may list but never move to: a Start phrase inside a longer sentence ("how do I record a meeting with two
            /// speakers", which asks nothing before it records), a place that only begins a sentence ("usage limit reached"), and every
            /// place while the words ask for a session list.
            var returnSkips: Set<String> = []
            /// The words ask for a session list ("sessions", "recent"). Return has nothing to do but wait for a choice.
            var listOnly = false
            /// What the panel's word search should look for, or nil: under three characters, an exact command or place, a noun list,
            /// and Sessions off all skip it. `plain` words, at most 200 characters.
            var searchWords: String? = nil
        }

        /// A row Return may move onto from the top of the list: a command or a place. Never a hit, and never the "Session tracking is off"
        /// or "N more in Sessions" line of a session list, which is for choosing from.
        private static func isOrder(_ row: Row) -> Bool {
            switch row.kind {
            case .command, .place: return row.group != .sessions
            default: return false
            }
        }

        /// Everything the panel shows for these words.
        static func listing(_ inputs: Inputs, words raw: String) -> Listing {
            let words = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            var result = Listing()
            result.words = words
            guard !words.isEmpty else {
                result.rows = emptyRows(inputs)
                return result
            }
            let s = inputs.snapshot
            let typed = plain(words)
            let question = words.contains("?")
            var rows: [Row] = []

            // Commands, closest first. Only a whole phrase highlights itself, and only where the command allows it.
            let ranked = Command.allCases.compactMap { command in commandRank(command, words).map { (command, $0) } }.sorted { $0.1 < $1.1 }
            for (command, rank) in ranked.prefix(commandCap) {
                if let row = commandRow(command, inputs, group: .commands) {
                    if rank == 0, command.autoHighlights, row.selectable, result.autoHighlight == nil { result.autoHighlight = row.id }
                    // Start recording asks nothing before it records, so Return moves onto it only when the words are an exact phrase
                    // (which runs) or the start of one. A question, a sentence, or the start of a word inside a phrase goes to Ask.
                    if command == .startRecording, rank != 0, !(rank == 1 && startsAPhrase(command, words)) { result.returnSkips.insert(row.id) }
                    rows.append(row)
                } else if command == .stopRecording, inputs.recording.glassesLive > 0 {
                    rows.append(info("glasses", .commands, elsewhereLine(inputs.recording)))
                }
            }

            // Places: panes and tabs, after the commands. An exact name highlights its row unless a command already has, and a noun
            // list ("recent") is the list, not Messages > Recent.
            let span = nounSpan(typed, question: question)
            let placed = visiblePlaces(typed, question: question)
            for found in placed {
                let row = Row(id: "place:" + found.place.rawValue, kind: .place(found.place), group: .places, title: found.place.title,
                              detail: found.place.parent.map { "In " + $0 })
                if found.rank == 0, span == nil, result.autoHighlight == nil { result.autoHighlight = row.id }
                if found.rank == 2 || span != nil { result.returnSkips.insert(row.id) }
                rows.append(row)
            }

            // Sessions: a noun list ("sessions", "recent sessions today"), or else what waits, what runs and the list by title. Titles
            // only filter here. They choose no command and no answer.
            var seen: [String] = []
            var sessions: [Row] = []
            func listed(_ id: String?) -> Bool { id.map { id in seen.contains { sameListed($0, id) } } ?? false }
            func listRow(_ item: Item) -> Row {
                let ago = when(item.date, now: inputs.now, calendar: inputs.calendar)
                let detail = [item.detail.map(clean), ago].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
                return Row(id: "session:" + item.id, kind: .session(item.id), group: .sessions, title: clean(item.title),
                           detail: detail.isEmpty ? nil : detail, state: item.state, trailing: item.openLabel, leavesSession: item.leavesSession)
            }
            if let span {
                result.listOnly = true
                if inputs.sessionsOff {
                    sessions.append(Row(id: "sessions:off", kind: .command(.openSessions), group: .sessions, title: "Session tracking is off",
                                        detail: "Turn it on in Sessions to list sessions here.", trailing: Command.openSessions.title))
                } else if !inputs.sessionsLoaded {
                    sessions.append(info("sessions-unknown", .sessions, "Sessions: not loaded yet."))
                } else if isRunningList(typed) {
                    // What runs (Today's Running: agents, Work runs, a question, a routine), then the sessions that run or wait that it
                    // does not hold. Idle sessions are "recent", never here. A Work run with no session yet is in the first part.
                    var items = startedFirst(inputs.running, inputs.startedRunID)
                    for item in inputs.sessions where item.state == "Running" || item.state == "Waiting" {
                        guard !items.contains(where: { held in held.sessionID.flatMap { id in item.sessionID.map { sameListed(id, $0) } } ?? false }) else { continue }
                        items.append(item)
                    }
                    if items.isEmpty {
                        sessions.append(inputs.runningKnown ? info("running-none", .sessions, "Nothing is running.") : info("running-unknown", .sessions, "Running: not loaded yet."))
                    }
                    for item in items.prefix(nounCap) {
                        if inputs.running.contains(where: { $0.id == item.id }) {
                            var row = runningRow(item)
                            row.group = .sessions
                            sessions.append(row)
                        } else {
                            sessions.append(listRow(item))
                        }
                        if let id = item.sessionID { seen.append(id) }
                    }
                    if items.count > nounCap {
                        sessions.append(Row(id: "sessions:more", kind: .command(.openSessions), group: .sessions, title: "\(items.count - nounCap) more in Sessions",
                                            trailing: Command.openSessions.title))
                    }
                } else {
                    let inside = inputs.sessions.filter { inSpan($0.date, span, now: inputs.now, calendar: inputs.calendar) }
                    if inside.isEmpty {
                        sessions.append(info("sessions-none", .sessions, span == .all ? "No sessions yet." : "No sessions " + spanWords(span) + "."))
                    }
                    for item in inside.prefix(nounCap) {
                        sessions.append(listRow(item))
                        if let id = item.sessionID { seen.append(id) }
                    }
                    if inside.count > nounCap {
                        sessions.append(Row(id: "sessions:more", kind: .command(.openSessions), group: .sessions, title: "\(inside.count - nounCap) more in Sessions",
                                            trailing: Command.openSessions.title))
                    }
                }
            } else {
                func take(_ item: Item, _ make: (Item) -> Row) {
                    guard sessions.count < sessionCap, typed.count >= 2, plain(item.title).contains(typed), !listed(item.sessionID) else { return }
                    if let session = item.sessionID { seen.append(session) }
                    var row = make(item)
                    row.group = .sessions
                    sessions.append(row)
                }
                for item in byTier(inputs.waiting) { take(item, waitingRow) }
                for item in inputs.running { take(item, runningRow) }
                for item in inputs.sessions {
                    take(item) { Row(id: "session:" + $0.id, kind: .session($0.id), group: .sessions, title: clean($0.title), detail: $0.detail.map(clean), state: $0.state, trailing: $0.openLabel, leavesSession: $0.leavesSession) }
                }
            }
            rows += sessions

            // Word search: hits in their own group, after the sessions that matched by title. Return never moves onto one and never
            // runs one. An arrow or a click does. A hit the list already shows is not shown twice.
            let exact = ranked.contains { $0.1 == 0 } || placed.contains { $0.rank == 0 }
            if typed.count >= 3, span == nil, !exact, !inputs.sessionsOff, searchTokens(typed).isEmpty {
                // Only common words ("the", "of to"): nothing to look for, so no search runs and no "no match" is claimed.
                rows.append(info("search-words", .found, "Add a word that names what you want.", detail: "Common words like the, of and to are skipped."))
            } else if typed.count >= 3, span == nil, !exact, !inputs.sessionsOff {
                let search = String(typed.prefix(200))
                result.searchWords = search
                let found = inputs.found
                if found.words == search {
                    switch found.phase {
                    case .idle: break
                    case .searching: rows.append(info("searching", .found, "Searching sessions…"))
                    case .failed: rows.append(info("search-failed", .found, "The search did not run.", detail: "The sessions listed here still open."))
                    case .done:
                        var shown = 0
                        for item in found.hits where shown < hitCap && !listed(item.sessionID) {
                            let ago = when(item.date, now: inputs.now, calendar: inputs.calendar)
                            let detail = [item.detail.map(clean), ago].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
                            rows.append(Row(id: "hit:" + item.id, kind: .hit(item.id), group: .found, title: hitTitle(item.title),
                                            detail: detail.isEmpty ? nil : detail,
                                            state: item.state, trailing: item.openLabel, match: matchLine(item.match, title: item.title), leavesSession: item.leavesSession))
                            shown += 1
                            // A second hit for the same session (a Desktop record's id and its transcript's) is not shown either.
                            if let id = item.sessionID { seen.append(id) }
                        }
                        // The search reads the start of the newest sessions, so "none" cannot mean none: it says what was read, and offers the rest.
                        if shown == 0 {
                            rows.append(info("search-none", .found, sessions.isEmpty ? "No match near the start of your newest sessions." : "No other match near the start of your newest sessions.",
                                             detail: "Search all sessions looks further."))
                        }
                    }
                }
                rows.append(Row(id: "search-all", kind: .searchAll, group: .found, title: "Search all sessions",
                                detail: "Opens Sessions with your words in its search box. Sessions' search asks the COS server and can use your OpenAI key.", trailing: "Open Sessions"))
            }

            // The saved answer, unless a whole-phrase command already runs on Return. A miss says so.
            let saved = result.autoHighlight == nil ? answer(words, s) : nil
            if let saved {
                result.hasAnswer = true
                result.entry = saved.entry
                rows.append(Row(id: "answer", kind: .savedAnswer, group: .answer, title: saved.entry.title, detail: saved.text, state: "Saved answer"))
                for offer in saved.offers {
                    rows.append(Row(id: "action:" + offer.action.rawValue, kind: .action(offer.action), group: .answer, title: rowTitle(offer.action), held: offer.held))
                }
            } else if result.autoHighlight == nil, ranked.isEmpty, placed.isEmpty, sessions.isEmpty {
                rows.append(info("no-answer", .answer, "No saved answer for this."))
            }

            // Always last.
            rows.append(Row(id: "ask", kind: .ask, group: .asking, title: "Ask COS",
                            detail: saved != nil ? "One Work run with your words, this saved answer and what COS Control sees." : "One Work run with your words and what COS Control sees. It shows in Running.",
                            held: askHeld(s)))
            if gate(.troubleshoot, s) == .ready, !rows.contains(where: { $0.kind == .action(.troubleshoot) }) {
                rows.append(Row(id: "action:troubleshoot", kind: .action(.troubleshoot), group: .asking, title: Action.troubleshoot.title,
                                detail: "Runs Doctor first, then one Work run. It asks before it changes anything."))
            }
            rows.append(Row(id: "file", kind: .file, group: .asking, title: "File to Work", detail: "Saves your words to the Work inbox. No run.", trailing: "Option-Return"))

            result.rows = rows
            // Any command or place in the list counts: "go to se" shows Open Sessions, "go to usage" shows Usage, and Return must not
            // spend a run on them.
            result.nearCommand = !ranked.isEmpty || !placed.isEmpty || nearCommand(words)
            return result
        }

        // MARK: Keys

        /// The one highlight in force: what was chosen by key or click, else the whole-phrase command.
        static func effective(_ chosen: String?, _ listing: Listing) -> String? {
            if let chosen, listing.rows.contains(where: { $0.id == chosen && $0.selectable }) { return chosen }
            return listing.autoHighlight
        }

        /// Down from nothing takes the first row and stops at the last. Up from the first goes back to nothing.
        static func move(_ delta: Int, from current: String?, _ listing: Listing) -> String? {
            let ids = listing.rows.filter(\.selectable).map(\.id)
            guard let first = ids.first else { return nil }
            guard let current, let index = ids.firstIndex(of: current) else { return delta > 0 ? first : nil }
            let next = index + delta
            return next < 0 ? nil : ids[min(next, ids.count - 1)]
        }

        enum ReturnOutcome: Equatable, Sendable {
            case nothing
            /// Run the row, or open its confirm first.
            case activate(String)
            /// The confirm that is open.
            case confirm
            case file
            /// Highlight this row. A second Return runs it.
            case move(String)
        }

        /// What Return does now. Option-Return always files. Free text never starts a run on the first Return (0.5.361): it moves
        /// to the Ask row, and a second Return runs it. That is one rule, not a race: the same keystroke does the same thing before and
        /// after anything arrives. A command, a place or a loaded session the words point at is where Return goes first; a word-search
        /// hit is never one of them, so it only opens by an arrow or a click. A highlight that is gone returns nothing.
        static func onReturn(option: Bool, chosen: String?, confirming: Bool, noticeShowing: Bool, _ listing: Listing, _ s: Snapshot) -> ReturnOutcome {
            if option { return listing.words.isEmpty ? .nothing : .file }
            if noticeShowing { return .nothing }
            if confirming { return .confirm }
            // A row the person chose that is not there any more (a hit that went with a new search) is no reason to act on another.
            if let chosen, !listing.rows.contains(where: { $0.id == chosen && $0.selectable }) { return .nothing }
            if let id = effective(chosen, listing) { return .activate(id) }
            guard !listing.words.isEmpty else { return .nothing }
            // The top row is a command or a place that Return may not run on its own (Stop, Doctor, a name that only starts one): Return
            // goes to that row, never past it to a Work run on the same words. Its own confirm still applies. Start recording inside a
            // longer sentence has no confirm, so Return skips it and goes to Ask like any near-command.
            if let top = listing.rows.first, isOrder(top), top.selectable, !listing.returnSkips.contains(top.id) { return .move(top.id) }
            // A session list asked for by name is for choosing from.
            if listing.listOnly { return .nothing }
            // A title that matches is a session to open, not a request: Return goes to the first of them.
            if let session = listing.rows.first(where: { $0.group == .sessions && $0.selectable }) { return .move(session.id) }
            let askable = listing.rows.first { $0.kind == .ask && $0.selectable }
            let cautious = listing.hasAnswer || listing.nearCommand
            if !s.workRunsOn, !cautious { return .file }
            if let target = askable ?? listing.rows.first(where: { $0.kind == .file }) { return .move(target.id) }
            return .nothing
        }

        /// The foot of the panel, in three parts so a long title is cut and the words around it never are. `text` is the whole line,
        /// which VoiceOver reads.
        struct Footer: Equatable, Sendable {
            /// Always drawn whole.
            var lead: String
            /// The one part that may be cut.
            var title: String? = nil
            /// Always drawn whole: "Return again opens it."
            var tail = ""
            var text: String { lead + (title ?? "") + tail }
        }

        static let idleHint = "Up and Down choose. Esc closes."

        /// A title can be anything, even "Start recording" or "Usage". When one reads like something the panel does itself, the foot calls
        /// the row "the session", so it is not mistaken for the command. Otherwise the title gets the room: at the panel's 320 pt floor
        /// the words around it leave little.
        private static let orderWords: Set<String> = Set(
            (Command.allCases.flatMap { [$0.title] + $0.phrases } + Place.allCases.flatMap { place in [place.title] + place.names.flatMap { [$0, "open " + $0, "go to " + $0, "show " + $0] } }).map(plain))

        static func sessionWord(_ title: String) -> String { orderWords.contains(plain(title)) ? "the session " : "" }

        /// What Return will do, in parts. The foot of the panel and VoiceOver both read it.
        static func footer(_ outcome: ReturnOutcome, _ listing: Listing, _ s: Snapshot) -> Footer {
            switch outcome {
            case .nothing:
                return Footer(lead: idleHint)
            case .confirm:
                return Footer(lead: "Return confirms. Esc cancels.")
            case .file:
                return Footer(lead: "Return files it to the Work inbox.")
            case .move(let id):
                guard let row = listing.rows.first(where: { $0.id == id }) else { return Footer(lead: idleHint) }
                switch row.kind {
                case .session, .hit:
                    return Footer(lead: "Return moves to " + sessionWord(row.title), title: row.title, tail: ". Return again opens it.")
                case .recording, .waiting, .running, .place, .searchAll:
                    return Footer(lead: "Return moves to ", title: row.title, tail: ". Return again opens it.")
                default:
                    return Footer(lead: "Return moves to ", title: row.title, tail: ". Return again " + (confirmation(row, s) != nil ? "asks first." : "runs it."))
                }
            case .activate(let id):
                guard let row = listing.rows.first(where: { $0.id == id }) else { return Footer(lead: idleHint) }
                switch row.kind {
                case .session, .hit:
                    return Footer(lead: (confirmation(row, s) != nil ? "Return asks first: " : "Return opens: ") + sessionWord(row.title), title: row.title)
                case .recording, .waiting, .running, .place, .searchAll:
                    return Footer(lead: confirmation(row, s) != nil ? "Return asks first: " : "Return opens: ", title: row.title)
                default:
                    return Footer(lead: (confirmation(row, s) != nil ? "Return asks first: " : "Return runs: "), title: row.title)
                }
            }
        }

        /// What Return will do, in words.
        static func hint(_ outcome: ReturnOutcome, _ listing: Listing, _ s: Snapshot) -> String { footer(outcome, listing, s).text }

        /// While the one-time notice shows: its Record is a click, so a quick second Return can never accept it.
        static let noticeHint = "Choose Record on the card to start. Esc goes back."

        /// What VoiceOver hears when the highlight moves.
        static func announcement(_ row: Row?, _ outcome: ReturnOutcome, _ listing: Listing, _ s: Snapshot) -> String {
            let hint = hint(outcome, listing, s)
            return row.map { $0.title + ". " + hint } ?? hint
        }

        enum EscapeStep: Equatable, Sendable { case cancelConfirm, dismissNotice, clearHighlight, clearWords, close }

        /// Esc undoes one thing at a time and then closes. A highlight the words made on their own goes with the words.
        static func onEscape(confirming: Bool, noticeShowing: Bool, chosen: String?, hasWords: Bool) -> EscapeStep {
            if confirming { return .cancelConfirm }
            if noticeShowing { return .dismissNotice }
            if chosen != nil { return .clearHighlight }
            return hasWords ? .clearWords : .close
        }

        /// Ask COS, File to Work and troubleshoot send the typed words. They keep them until the run or the filing is accepted, so a
        /// refusal (the cap, the breaker, Work busy) costs nothing typed.
        static func sendsWords(_ row: Row) -> Bool {
            switch row.kind {
            case .ask, .file, .action(.troubleshoot): return true
            default: return false
            }
        }

        /// The words left in the box once a row has run. Every other row has used them up: a draft left behind comes back at the
        /// next ⌘K, armed, and one Return would fire the same row again (open work, record, stop).
        static func draftAfterRun(_ row: Row, _ draft: String) -> String {
            sendsWords(row) ? draft : ""
        }

        /// Whether a send that has finished uses up the words in the box: it was accepted, and the box still holds what was sent
        /// (ignoring the padding around it). A refused send keeps its words, and so does a box the person has typed more into.
        static func sentWordsAreUsedUp(sent: String, draft: String, accepted: Bool) -> Bool {
            accepted && draft.trimmingCharacters(in: .whitespacesAndNewlines) == sent.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // MARK: Confirms

        static let stopConfirm = Confirmation(question: "Stop and save this recording?",
                                              consequence: "COS stops this Mac's recording and saves the meeting. A recording on your glasses or iPhone keeps running.", confirm: "Stop and save")
        /// main.swift doctorDetails: Query + playback proof asks the provider a real question, up to 60 s.
        static let doctorConfirm = Confirmation(question: "Run Doctor?",
                                                consequence: "Doctor checks the server, Whisper and your AI apps, and asks your AI app one real question. It can take a minute.", confirm: "Run Doctor")
        /// The report runs Doctor too.
        static let reportConfirm = Confirmation(question: "Copy a redacted report?",
                                                consequence: "This runs Doctor first, which asks your AI app one real question, then copies the report.", confirm: "Copy report")

        /// A message typed into an open session and not sent is cleared by going anywhere else (the session closes, and its chat resets).
        static let draftConfirm = Confirmation(question: "Leave your unsent message?",
                                               consequence: "You started a message in a session and have not sent it. Going there clears it.", confirm: "Go there")

        /// Whether running this row takes the person out of the session that is open in Sessions, which discards a reply typed there and not
        /// sent (`select` closes the open session). Every pane opener, every place, Search all sessions and a live view do. Settings does
        /// not, and neither does a session that opens in its own app: the window says which, per row.
        static func leavesSession(_ row: Row) -> Bool {
            switch row.kind {
            case .place, .searchAll, .recording: return true
            case .command(let command):
                switch command {
                case .openSessions, .openMeetings, .openWork, .openSpeakers, .openDictation, .openMemories: return true
                case .startRecording, .stopRecording, .openSettings, .runDoctor: return false
                }
            case .action(let action): return action == .openMeetings || action == .openSpeakers
            case .waiting, .running, .session, .hit: return row.leavesSession
            case .ask, .file, .savedAnswer, .info: return false
            }
        }

        /// The inline confirm a row needs. Stop and Doctor always ask, as does anything in `changesSomething`. Every row that leaves the
        /// open session asks only when an unsent message would be lost. Start recording, Ask COS and File to Work never ask.
        static func confirmation(_ row: Row, _ s: Snapshot) -> Confirmation? {
            if s.unsentSessionDraft, leavesSession(row) { return draftConfirm }
            switch row.kind {
            case .command(.stopRecording): return stopConfirm
            case .command(.runDoctor), .action(.runDoctor): return doctorConfirm
            case .action(.copyReport): return reportConfirm
            case .action(let action): return SetupAssistant.confirmation(action, s)
            default: return nil
            }
        }

        /// Checked again on confirm, with fresh state: a recording can start between the two. Nil runs it; a line means it
        /// waits now and nothing runs. There is no force path.
        static func recheck(_ row: Row, _ s: Snapshot, _ r: Recording) -> String? {
            switch row.kind {
            case .command(.stopRecording):
                return r.stoppable ? nil : "Nothing is recording on this Mac now."
            case .command(.startRecording):
                return recordingHold(r, s)
            case .command(.runDoctor):
                if case .held(let reason) = gate(.runDoctor, s) { return reason }
                return nil
            case .action(let action):
                switch gate(action, s) {
                case .ready: return nil
                case .held(let reason): return reason
                case .notApplicable: return "This does not apply any more."
                }
            default:
                return nil
            }
        }

        // MARK: The result line

        enum Tone: Sendable { case progress, done, problem }
        struct ResultLine: Equatable, Sendable {
            var text: String
            var tone: Tone
        }
        struct ResultInputs: Equatable, Sendable {
            var error: String? = nil
            var recordingError: String? = nil
            var gatheringReport = false
            var startingRecording = false
            /// ControllerModel.operationProgress while the helper runs.
            var helperProgress: String? = nil
            var startingRun = false
            var filing = false
            var runNote: String? = nil
            var notice: String? = nil
            var platformNotice: String? = nil
            /// model.notice, only for something this panel ran. It stays set long after, so it is not news otherwise.
            var helperNotice: String? = nil
        }

        /// One line: a failure first, then what is running now, then the last result.
        static func result(_ r: ResultInputs) -> ResultLine? {
            func text(_ value: String?) -> String? {
                guard let value, !value.isEmpty else { return nil }
                return clean(value)
            }
            if let line = text(r.error) ?? text(r.recordingError) { return ResultLine(text: line, tone: .problem) }
            if r.gatheringReport { return ResultLine(text: "Gathering the Doctor report…", tone: .progress) }
            if r.startingRecording { return ResultLine(text: RecordingHeld.starting, tone: .progress) }
            if let line = text(r.helperProgress) { return ResultLine(text: line, tone: .progress) }
            if r.startingRun { return ResultLine(text: "Starting the run…", tone: .progress) }
            if r.filing { return ResultLine(text: "Filing it to Work…", tone: .progress) }
            if let line = text(r.runNote) ?? text(r.notice) ?? text(r.platformNotice) ?? text(r.helperNotice) { return ResultLine(text: line, tone: .done) }
            return nil
        }

        // MARK: Ask COS

        /// One Work run for the Ask row: the person's words quoted, the saved answer when there is one, a short snapshot and
        /// the same rules as troubleshoot. No Doctor, so it spends no provider question before the run. Nil unless the server
        /// answers and Work runs are on. Takes no session titles: they never reach a prompt.
        static func askRun(question: String, entry: Entry?, _ s: Snapshot, id: String, asked: String) -> Troubleshoot? {
            guard askHeld(s) == nil else { return nil }
            let words = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SetupAssistant.maxQuestion))
            guard !words.isEmpty else { return nil }
            let saved = entry.map { "Saved answer from the COS Control guide, \"\($0.title)\":\n\($0.answer)" } ?? "No saved answer matched."
            let prompt = """
            Someone asked COS Control a question on their own Mac. Answer it in a few short sentences, or propose the smallest fix.

            Their words: "\(words)"

            \(saved)

            Rules:
            - Start from the saved answer and what COS Control sees.
            \(runRules)
            - If you cannot tell, say what you would check next and why.

            What COS Control sees now:
            \(seen(s).map { "- " + $0 }.joined(separator: "\n"))
            """
            return Troubleshoot(target: "today:ask:" + id, title: String(words.prefix(60)), prompt: prompt, context: "Asked from the COS command center on \(asked).")
        }
    }
}
