import Foundation

// Ask COS as a setup and repair assistant (Miles, 2026-10-27: "turn this into the setup widget that can run the commands
// necessary to get things running ... I can repair X, Y or Z or set up X, Y or Z"). This file is the logic half. The
// views are not built yet: Miles picks a layout from design/ask-cos-setup-mock.html first. Wiring plan:
// docs/setup-assistant/PLAN.md.
//
// HARD RULES
//   1. Local first. Every suggestion comes from a Snapshot of state COS Control already holds. No model call, no network,
//      no shell, so it answers when the server is down, which is when people need it most.
//   2. Actions are the closed enum below. Each maps to an existing helper command (HelperSources/main.swift, the command
//      switch) or an existing opener in the app. Text a person types picks a knowledge-base entry by keyword and never
//      becomes a command or an argument.
//   3. A change is confirmed inline first, with one consequence line read from the code that runs it. The restart gates
//      COS Control already has hold here too (a job, a recording, a meeting still saving, an ownership conflict, an
//      interrupted update). There is no force path.
//   4. "Ask COS to troubleshoot" is offered only while the server answers and Start Work runs from Today is on. It
//      starts one Work run through the Today cap with a redacted Doctor packet, and the prompt says to ask before
//      changing anything.
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

        init() {}
    }

    // MARK: - Actions

    enum Action: String, Sendable, CaseIterable {
        // Helper commands (HelperSources/main.swift, the command switch).
        case runDoctor, copyReport, setUp, startServer, restartServer, repairRuntime, repairWhisper, updateServer
        // In the app.
        case retryAppUpdate, resetAccessibility
        // Openers: they change nothing.
        case openUnstuck, openSetupGuide, openPermissions, openSettings, openDictationSettings, openMicrophoneSettings, openTailscale
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
            if s.meetingWorkBlockingRestart { return .held(Held.saving) }
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
             .openMicrophoneSettings, .openTailscale, .openUnstuck, .resetAccessibility:
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
                                consequence: "COS downloads the latest server, tests it with a real question, and puts the current one back if that test fails.",
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
              actions: [.openDictationSettings],
              source: "cos-starter control/docs/index.html:1229 (Parakeet will not install)",
              groups: [Terms.parakeet, Terms.setUp], boosts: ["parakeet"]),
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
        let packet = report.map { scrubbed(String($0.prefix(maxPacket))) } ?? "The redacted report could not be read."
        let prompt = """
        Someone needs help with COS on their own Mac. Diagnose the problem and propose a fix. Do not change anything yet.

        Their words: "\(words)"

        Rules:
        - Read what COS Control sees and the Doctor packet below first. Paths and names in the packet are redacted.
        - Say what is wrong in two or three short sentences, then propose the smallest fix.
        - Ask before you run anything that changes this Mac: installs, restarts, deleting files, System Settings.
        - Never use sudo, pkill or killall. Never restart the COS server while a meeting is recording or a job is running.
        - Prefer COS Control's own buttons when one fits: Run Doctor, Repair Managed Runtime, Repair Whisper, Restart, Update Server, Reset and add again.
        - If you cannot tell, say what you would check next and why.

        What COS Control sees now:
        \(seen.map { "- " + $0 }.joined(separator: "\n"))

        Doctor packet (redacted):
        \(packet)
        """
        return Troubleshoot(target: targetPrefix + id, title: "Troubleshoot: " + String(words.prefix(48)), prompt: prompt,
                            context: "Asked from Ask COS setup help on \(asked).")
    }

    /// Any "/Users/<name>" left in the packet becomes "~".
    static func scrubbed(_ text: String) -> String {
        text.replacingOccurrences(of: "/Users/[^/\"\\s]+", with: "~", options: .regularExpression)
    }
}
