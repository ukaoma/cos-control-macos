import Foundation

// The permission guide's logic (Sources/PermissionGuideModel.swift), compiled on its own: rows and their statuses,
// which rows a Mac gets, the floating bar's steps, the words, the just-in-time hook, old-build discovery, the drag
// source, and the launchd and CalendarFetch readers. Nothing here reads TCC, opens System Settings or shows a window.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passes = 0

func check(_ condition: Bool, _ behaviour: String, _ detail: @autoclosure () -> String = "") {
    if condition { passes += 1; return }
    failures += 1
    FileHandle.standardError.write(Data("check failed [\(behaviour)]: \(detail())\n".utf8))
}

let appPath = "/Volumes/QA Disk/Build 301/COS Control.app"
let home = "/Users/test home.ü"

func job(_ label: String, _ interpreter: String, protected: Bool = true, running: Bool = false, runs: Int? = nil, exit: Int? = nil) -> LaunchJob {
    var j = LaunchJob(label: label, interpreter: interpreter, readsProtectedFolder: protected)
    j.running = running; j.runs = runs; j.lastExit = exit
    return j
}

func rows(_ facts: PermissionFacts) -> [PermissionRow] {
    PermissionGuideRules.rows(facts, appName: "COS Control", appPath: appPath)
}

@MainActor
func freshDefaults() -> UserDefaults {
    let name = "cos.permission-guide-checks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor
func guide(_ probes: PermissionProbes = .inert, build: Int = 300, defaults: UserDefaults? = nil) -> PermissionGuide {
    PermissionGuide(probes: probes, appName: "COS Control", appPath: appPath, bundleID: "com.gotcos.control",
                    currentBuild: build, defaults: defaults ?? freshDefaults())
}

@main @MainActor
struct PermissionGuideChecks {
    static func main() async {
        statusModel()
        relevance()
        steps()
        copy()
        parsers()
        staleDiscovery()
        dragSource()
        await justInTime()
        await staleGrant()
        await staleReset()
        if failures > 0 {
            FileHandle.standardError.write(Data("\(failures) permission guide check(s) failed, \(passes) passed\n".utf8))
            exit(1)
        }
        print("PASS: permission guide logic (\(passes) checks)")
    }

    // MARK: Status model

    static func statusModel() {
        var facts = PermissionFacts()
        let ax = rows(facts).first { $0.kind == .accessibility }!
        check(ax.status == .notNeededYet, "accessibility status", "untrusted and nothing wants it: Not needed yet, got \(ax.status)")
        check(ax.action == .drag(.accessibility, PermissionDragSource(path: appPath, name: "COS Control")), "accessibility action", "\(ax.action)")
        facts.accessibilityWanted = true
        check(rows(facts).first { $0.kind == .accessibility }!.status == .needsYou, "accessibility status", "wanted and untrusted: Needs you")
        facts.accessibilityTrusted = true
        let trusted = rows(facts).first { $0.kind == .accessibility }!
        check(trusted.status == .allowed && trusted.action == .none, "accessibility status", "trusted: Allowed, no action")

        func note(_ fact: NotificationFact) -> PermissionRow {
            var f = PermissionFacts(); f.notifications = fact; return rows(f).first { $0.kind == .notifications }!
        }
        check(note(.notDetermined).status == .notNeededYet && note(.notDetermined).action == .askNotifications, "notifications status", "not asked: Not needed yet, Allow asks")
        check(note(.denied).status == .needsYou && note(.denied).action == .openSettings(.notifications), "notifications status", "denied: Needs you, Open settings")
        check(note(.allowed(alertsOn: false)).status == .needsYou && note(.allowed(alertsOn: false)).detail != nil, "notifications status", "alerts off: Needs you with why")
        check(note(.allowed(alertsOn: true)).status == .allowed && note(.allowed(alertsOn: true)).action == .none, "notifications status", "allowed")

        func login(_ fact: LoginItemFact) -> PermissionRow {
            var f = PermissionFacts(); f.loginItem = fact; return rows(f).first { $0.kind == .launchAtLogin }!
        }
        check(login(.enabled).status == .allowed, "login item status", "enabled")
        check(login(.requiresApproval).status == .needsYou && login(.requiresApproval).action == .openLoginItems, "login item status", "requiresApproval opens Login Items")
        check(login(.off).status == .notNeededYet && login(.off).action == .turnOnLoginItem, "login item status", "off: Turn on")

        // Background jobs: positive signals only.
        check(PermissionGuideRules.jobStatus([job("com.cos.a", "/p", exit: 78), job("com.cos.b", "/p", runs: 3, exit: 0)]) == .needsYou, "job status", "any exit 78 is Needs you")
        check(PermissionGuideRules.jobStatus([job("com.cos.a", "/p", runs: 2, exit: 0)]) == .allowed, "job status", "ran and exited 0: Allowed")
        check(PermissionGuideRules.jobStatus([job("com.cos.a", "/p", running: true, runs: 1)]) == .allowed, "job status", "running: Allowed")
        check(PermissionGuideRules.jobStatus([job("com.cos.a", "/p", runs: 0)]) == .notNeededYet, "job status", "never ran proves nothing")
        check(PermissionGuideRules.jobStatus([job("com.cos.a", "/p")]) == .notNeededYet, "job status", "unknown to launchd proves nothing")
        let detail = PermissionGuideRules.jobDetail((1...5).map { job("com.cos.j\($0)", "/p", exit: 78) })
        check(detail == "Stopped before starting: j1, j2, j3 and 2 more", "job detail", detail ?? "nil")

        func auto(_ fact: AutomationFact) -> PermissionRow {
            PermissionGuideRules.automation(AutomationTarget(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor"), fact)
        }
        check(AutomationFact(osStatus: 0) == .allowed && AutomationFact(osStatus: -1743) == .denied
              && AutomationFact(osStatus: -1744) == .notAsked && AutomationFact(osStatus: -600) == .notRunning
              && AutomationFact(osStatus: -50) == .unknown(-50), "automation codes", "OSStatus mapping")
        check(auto(.allowed).status == .allowed, "automation status", "allowed")
        check(auto(.denied).status == .needsYou && auto(.denied).action == .openSettings(.automation), "automation status", "denied opens Automation")
        check(auto(.notAsked).status == .notNeededYet && auto(.notAsked).action == .testAutomation(bundleID: "com.todesktop.230313mzl4w4u92"), "automation status", "not asked: Test")
        check(auto(.notRunning).detail?.contains("Cursor is open") == true, "automation status", "not running says when it is checked")

        var cal = PermissionFacts(); cal.calendarAppPath = "/x/bin/CalendarFetch.app"
        cal.calendar = .denied
        let deniedCal = rows(cal).first { $0.kind == .calendar }!
        check(deniedCal.status == .needsYou && deniedCal.action == .launchCalendarFetch(path: "/x/bin/CalendarFetch.app"), "calendar status", "denied: Fix launches CalendarFetch")
        cal.calendar = .allowed
        check(rows(cal).first { $0.kind == .calendar }!.status == .allowed, "calendar status", "allowed")
        cal.calendar = .unknown
        check(rows(cal).first { $0.kind == .calendar }!.status == .notNeededYet, "calendar status", "no run on record")
    }

    // MARK: Relevance

    static func relevance() {
        let bare = rows(PermissionFacts())
        check(bare.map(\.kind) == [.accessibility, .notifications, .launchAtLogin], "row relevance", "a Mac without COS scripts gets three rows: \(bare.map(\.id))")
        var facts = PermissionFacts()
        facts.jobs = [job("com.cos.meeting-sync", "/u/venv/bin/python", runs: 1, exit: 0),
                      job("com.cos.glasses-control-recovery", "/u/Library/Application Support/COS Control/bin/cos-control-helper", protected: false),
                      job("com.cos.daily-loop-morning", "/u/venv/bin/python", exit: 78),
                      job("com.cos.glasses-server", "/opt/homebrew/bin/node", running: true, runs: 1)]
        let bg = rows(facts).filter { $0.kind == .backgroundJobs }
        check(bg.count == 2, "row relevance", "one row per interpreter of a protected-folder job, got \(bg.map(\.id))")
        check(bg.first?.id == "backgroundJobs:/u/venv/bin/python" && bg.first?.status == .needsYou, "row relevance", "python row needs you")
        check(bg.last?.title == "Glasses server (Node)" && bg.last?.status == .allowed && bg.last?.action == .none, "row relevance", "node row is the glasses server, allowed: \(String(describing: bg.last))")
        check(!bg.contains { $0.id.contains("cos-control-helper") }, "row relevance", "a job outside protected folders has no row")
        facts.jobs = [job("com.cos.qdrant-server", "/Applications/Docker.app/Contents/Resources/bin/docker", protected: false)]
        check(rows(facts).filter { $0.kind == .backgroundJobs }.isEmpty, "row relevance", "no protected-folder job, no row")
        check(rows(facts).first { $0.kind == .calendar } == nil, "row relevance", "no CalendarFetch, no calendar row")
        facts.automation = [(AutomationTarget(bundleID: "com.apple.Terminal", name: "Terminal"), .notAsked)]
        check(rows(facts).filter { $0.kind == .automation }.map(\.id) == ["automation:com.apple.Terminal"], "row relevance", "automation rows only for installed targets")
    }

    // MARK: The bar's steps

    static func steps() {
        var step = HelperBarStep(startedAt: 0)
        check(step.observe(granted: false, settingsOpen: false, now: 1).isEmpty && step.phase == .waiting, "bar launch grace", "System Settings still launching is not closed")
        check(step.observe(granted: false, settingsOpen: true, now: 10).isEmpty, "bar waiting", "nothing yet")
        check(step.observe(granted: true, settingsOpen: true, now: 20) == [.showAllowed, .resume] && step.phase == .allowed, "bar grant", "a confirmed grant shows Allowed and resumes")
        check(step.observe(granted: true, settingsOpen: true, now: 21).isEmpty, "bar close delay", "still showing Allowed before 1.5 s")
        check(step.observe(granted: true, settingsOpen: true, now: 21.5) == [.close(returnToCOS: true)] && step.phase == .closed, "bar close delay", "closes 1.5 s after, back to COS")
        check(step.observe(granted: true, settingsOpen: true, now: 30).isEmpty, "bar closed", "closed stays closed")

        var closed = HelperBarStep(startedAt: 0)
        check(closed.observe(granted: false, settingsOpen: false, now: 6) == [.close(returnToCOS: false)], "bar settings closed", "closing System Settings closes the bar, COS stays put")

        var slow = HelperBarStep(startedAt: 0)
        check(slow.observe(granted: false, settingsOpen: true, now: 119).isEmpty, "bar trouble", "not before two minutes")
        check(slow.observe(granted: false, settingsOpen: true, now: 120) == [.offerTrouble] && slow.phase == .trouble, "bar trouble", "Having trouble? at two minutes")
        check(slow.observe(granted: false, settingsOpen: true, now: 200).isEmpty, "bar trouble", "offered once")
        check(slow.observe(granted: true, settingsOpen: true, now: 210) == [.showAllowed, .resume], "bar trouble", "a grant after trouble still lands")

        var dismissed = HelperBarStep(startedAt: 0)
        check(dismissed.dismiss() == [.close(returnToCOS: false)] && dismissed.dismiss().isEmpty, "bar dismiss", "the close button closes once")
    }

    // MARK: Words

    static func copy() {
        check(PermissionStatus.allowed.label == "Allowed" && PermissionStatus.needsYou.label == "Needs you" && PermissionStatus.notNeededYet.label == "Not needed yet", "status words", "the three statuses")
        func summary(_ needs: Int) -> String {
            PermissionGuideRules.summary((0..<needs).map { PermissionRow(id: "\($0)", kind: .automation, title: "", unlocks: "", status: .needsYou, detail: nil, action: .none) }
                + [PermissionRow(id: "x", kind: .notifications, title: "", unlocks: "", status: .notNeededYet, detail: nil, action: .none)])
        }
        check(summary(0) == "All set" && summary(1) == "1 needs you" && summary(2) == "2 need you", "panel summary", "\(summary(0)) / \(summary(1)) / \(summary(2))")
        check(PermissionPane.accessibility.settingsURL().absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility", "pane links", "Accessibility")
        check(PermissionPane.fullDiskAccess.settingsURL().absoluteString.hasSuffix("?Privacy_AllFiles"), "pane links", "Full Disk Access")
        check(PermissionPane.notifications.settingsURL(bundleID: "com.gotcos.control").absoluteString.hasSuffix("Notifications-Settings.extension?id=com.gotcos.control"), "pane links", "the app's own notification page")
        check(PermissionAction.resetAndAddAgain.title == "Reset and add again", "action words", "repair")
        for row in rows({ var f = PermissionFacts(); f.calendarAppPath = "/c"; f.jobs = [job("com.cos.x", "/p/python", exit: 78)]
                         f.automation = [(AutomationTarget(bundleID: "a", name: "Claude"), .notAsked)]; return f }()) {
            check(row.unlocks.hasPrefix("Lets ") || row.unlocks.hasPrefix("Starts "), "plain words", "\(row.id) says what it unlocks: \(row.unlocks)")
            check(!row.unlocks.contains("TCC") && !row.unlocks.contains("entitlement") && !row.unlocks.contains("\u{2014}"), "plain words", "\(row.id) has no jargon or em dash")
            if row.action != .none { check(!row.action.title.isEmpty, "action words", "\(row.id) has a named action") }
        }
        check(PermissionGuideRules.dragName(interpreter: "/x/venv/bin/python", server: false) == "COS background helper (Python)", "drag names", "python")
        check(PermissionGuideRules.dragName(interpreter: "/opt/homebrew/bin/node", server: true) == "COS glasses server (Node)", "drag names", "node")
    }

    // MARK: Parsers

    static func parsers() {
        let printed = "gui/501/com.cos.meeting-sync = {\n\tactive count = 0\n\tpath = /Users/u/Library/LaunchAgents/com.cos.meeting-sync.plist\n\tstate = not running\n\n\tprogram = /bin/sh\n\truns = 4\n\tlast exit code = 78: EX_CONFIG\n\tendpoints = {\n\t\tstate = running\n\t}\n}"
        let s = LaunchdParse.service(printed)
        check(!s.running && s.runs == 4 && s.lastExit == 78, "launchctl print", "\(s)")
        let never = LaunchdParse.service("x = {\n\tstate = running\n\truns = 1\n\tlast exit code = (never exited)\n}")
        check(never.running && never.runs == 1 && never.lastExit == nil, "launchctl print", "never exited is no exit code: \(never)")

        let py = "/Users/u/Documents/GitHub/Ukaoma Chief Of Staff/MU-Chief-Staff/operations/scripts/venv/bin/python"
        check(LaunchdParse.interpreter(["/bin/sh", "-lc", "exec '\(py)' '/Users/u/Documents/x/refresh_calendar_cache.py'"]) == py, "interpreter", "a shell exec wrapper is looked through")
        check(LaunchdParse.interpreter(["/bin/zsh", "-c", "FOO=1 \"\(py)\" run.py; echo done"]) == py, "interpreter", "assignments skipped, double quotes")
        check(LaunchdParse.interpreter(["/usr/bin/env", "-i", "python3", "x.py"]) == "python3", "interpreter", "env names the program")
        check(LaunchdParse.interpreter(["/opt/homebrew/bin/node", "--import", "x"]) == "/opt/homebrew/bin/node", "interpreter", "a direct program is itself")
        check(LaunchdParse.interpreter([]) == nil, "interpreter", "no arguments, no interpreter")
        check(LaunchdParse.shellWords("exec 'a b' c\\ d \"e\\\"f\" | g") == ["exec", "a b", "c d", "e\"f"], "shell words", "\(LaunchdParse.shellWords("exec 'a b' c\\ d \"e\\\"f\" | g"))")

        check(LaunchdParse.isProtected(home + "/Documents/x", home: home) && LaunchdParse.isProtected(home + "/Library/Mobile Documents/y", home: home + "/"), "protected folders", "Documents and iCloud Drive")
        check(!LaunchdParse.isProtected(home + "/Library/Application Support/COS Control/x", home: home) && !LaunchdParse.isProtected(home + "/Documents", home: home), "protected folders", "Application Support is not; the bare folder path is not a file in it")
        check(LaunchdParse.readsProtectedFolder(arguments: ["/opt/homebrew/bin/node", "/Users/x/server.ts"], environment: ["COS_SCRIPTS_DIR": home + "/Documents/cos/scripts"], workingDirectory: nil, home: home), "protected folders", "the server's COS_SCRIPTS_DIR counts")
        check(LaunchdParse.readsProtectedFolder(arguments: ["/bin/sh", "-lc", "exec '\(home)/Documents/v/python' x"], environment: [:], workingDirectory: nil, home: home), "protected folders", "words inside a shell command count")
        check(!LaunchdParse.readsProtectedFolder(arguments: ["/usr/bin/true"], environment: [:], workingDirectory: "/tmp", home: home), "protected folders", "none")

        check(LaunchdParse.isCOSAgentFile("com.cos.meeting-sync.plist"), "agent files", "a job")
        for name in ["com.cos.glasses-server.plist.backup.20260711080627", "com.cos.calendar-cache-refresh.plist.bak-2026-07-24", "com.cos..plist", "com.other.x.plist", "com.cos.x.plist.ROLLEDBACK-1"] {
            check(!LaunchdParse.isCOSAgentFile(name), "agent files", "\(name) is not a job")
        }

        let log = """
        {"ts": "1", "level": "error", "msg": "swift_permission_or_calendar_error"}
        not json
        {"ts": "2", "level": "info", "msg": "lock_held_skipping"}
        """
        check(CalendarFetchLog.status(log) == .denied, "calendar log", "the last answer wins over later unrelated lines")
        check(CalendarFetchLog.status(log + "\n{\"msg\": \"cache_refreshed\"}") == .allowed, "calendar log", "a refresh after a denial is Allowed")
        check(CalendarFetchLog.status("") == .unknown, "calendar log", "empty")
    }

    // MARK: Old test builds

    static func staleDiscovery() {
        let output = """
        /Applications/COS Control.app   kMDItemCFBundleIdentifier = com.gotcos.control
        /Users/u/Lab/COS Control Foundation Lab.app   kMDItemCFBundleIdentifier = com.gotcos.COSControl.FoundationLab
        /Users/u/x/A.app   kMDItemCFBundleIdentifier = com.gotcos.COSControl.WorkPreview019
        /Users/u/y/A copy.app   kMDItemCFBundleIdentifier = com.gotcos.COSControl.WorkPreview019
        /Users/u/z/Other.app   kMDItemCFBundleIdentifier = com.example.gotcos.thing
        /Users/u/z/Bad.app   kMDItemCFBundleIdentifier = com.gotcos.bad id; rm -rf
        garbage line
        """
        let found = StaleBuilds.parse(output, runningID: "com.gotcos.control")
        check(found.map(\.bundleID) == ["com.gotcos.COSControl.FoundationLab", "com.gotcos.COSControl.WorkPreview019"], "stale discovery", "\(found)")
        check(found.last?.copies == 2, "stale discovery", "copies counted")
        check(!found.contains { $0.bundleID == "com.gotcos.control" }, "stale discovery", "the running build is never listed")
        check(StaleBuilds.spotlightQuery == "kMDItemCFBundleIdentifier == \"com.gotcos.*\"", "stale discovery", "prefix query only")
    }

    // MARK: Drag source

    static func dragSource() {
        let ax = rows(PermissionFacts()).first { $0.kind == .accessibility }!
        guard case .drag(let pane, let source) = ax.action else { check(false, "drag source", "accessibility is a drag"); return }
        check(pane == .accessibility && source.path == appPath && source.name == "COS Control", "drag source", "the running bundle the guide was given: \(source)")
        var facts = PermissionFacts()
        facts.jobs = [job("com.cos.meeting-sync", "/u/venv/bin/python", exit: 78)]
        let bg = rows(facts).first { $0.kind == .backgroundJobs }!
        check(bg.action == .drag(.fullDiskAccess, PermissionDragSource(path: "/u/venv/bin/python", name: "COS background helper (Python)")), "drag source", "the interpreter the job runs: \(bg.action)")
    }

    // MARK: Just in time

    static func justInTime() async {
        nonisolated(unsafe) var trusted = false
        var probes = PermissionProbes.inert
        probes.accessibilityTrusted = { trusted }
        let g = guide(probes)
        var requests: [PermissionDragRequest] = []
        g.startDragFlow = { requests.append($0) }
        var resumed = 0
        let went = g.need(.accessibility, for: "Jump to your session") { resumed += 1 }
        check(!went, "just in time", "an untrusted need does not go ahead")
        check(requests.count == 1 && requests.first?.feature == "Jump to your session" && requests.first?.pane == .accessibility && requests.first?.source.path == appPath, "just in time", "the drag flow starts on that row, naming the feature: \(requests)")
        check(g.focusedRowID == "accessibility" && g.waitingFeature["accessibility"] == "Jump to your session", "just in time", "the guide opens on that row")
        check(g.row(kind: .accessibility)?.status == .needsYou, "just in time", "a feature that asked makes it Needs you")
        check(resumed == 0, "just in time", "nothing resumes before the grant")
        trusted = true
        g.granted(rowID: "accessibility")
        check(resumed == 1 && g.waitingFeature["accessibility"] == nil && g.focusedRowID == nil, "just in time resume", "the feature that asked continues once")
        await g.refresh()
        check(resumed == 1, "just in time resume", "a later refresh does not resume it again")
        check(g.need(.accessibility, for: "Jump to your session") && requests.count == 1, "just in time", "an allowed need goes ahead with no flow")

        // A background need opens the panel card on the row, never a flow.
        var probes2 = PermissionProbes.inert
        probes2.notifications = { .denied }
        let n = guide(probes2)
        var flows = 0
        n.startDragFlow = { _ in flows += 1 }
        var opened: [URL] = []
        n.openURL = { opened.append($0) }
        await n.refresh()
        check(!n.need(.notifications, for: "Meeting alerts", interactive: false), "just in time background", "denied does not go ahead")
        check(n.panelRouteActive && n.focusedRowID == "notifications" && flows == 0 && opened.isEmpty, "just in time background", "panel card on the row, no window, no Settings")
        check(n.need(.backgroundJobs, for: "Background jobs", interactive: false), "just in time background", "a kind with no row on this Mac goes ahead")

        // A refresh that finds the row Allowed resumes what waited.
        nonisolated(unsafe) var allowed = false
        var probes3 = PermissionProbes.inert
        probes3.notifications = { allowed ? .allowed(alertsOn: true) : .notDetermined }
        probes3.requestNotifications = { allowed = true; return true }
        let w = guide(probes3)
        await w.refresh()
        var workResumed = false
        _ = w.need(.notifications, for: "Work updates") { workResumed = true }
        for _ in 0..<50 where !workResumed { try? await Task.sleep(for: .milliseconds(20)) }
        check(workResumed && w.row(kind: .notifications)?.status == .allowed, "just in time resume", "the system prompt's yes resumes the feature")

        // Several rows of one kind: the first that is not Allowed.
        var probes4 = PermissionProbes.inert
        probes4.launchJobs = { [job("com.cos.glasses-server", "/n/node", running: true, runs: 1), job("com.cos.meeting-sync", "/v/python", exit: 78)] }
        let b = guide(probes4)
        var bgRequests: [PermissionDragRequest] = []
        b.startDragFlow = { bgRequests.append($0) }
        await b.refresh()
        check(!b.need(.backgroundJobs, for: "Background jobs") && bgRequests.first?.rowID == "backgroundJobs:/v/python", "just in time", "the row that needs you, not the first of its kind: \(bgRequests)")
    }

    // MARK: Stale grants

    static func staleGrant() async {
        let defaults = freshDefaults()
        nonisolated(unsafe) var trusted = true
        var probes = PermissionProbes.inert
        probes.accessibilityTrusted = { trusted }
        let first = guide(probes, build: 300, defaults: defaults)
        await first.refresh()
        check(defaults.integer(forKey: PermissionGuide.lastTrustedBuildKey) == 300, "stale grant", "the trusted build is remembered")
        trusted = false
        let updated = guide(probes, build: 301, defaults: defaults)
        await updated.refresh()
        let row = updated.row(kind: .accessibility)
        check(updated.facts.staleGrantSuspected && row?.status == .needsYou && row?.action == .resetAndAddAgain, "stale grant", "untrusted after an update: Reset and add again, \(String(describing: row))")
        let same = guide(probes, build: 300, defaults: defaults)
        await same.refresh()
        check(!same.facts.staleGrantSuspected, "stale grant", "untrusted on the build that was trusted is not a stale signature")

        var resets = 0, flows: [PermissionDragRequest] = []
        updated.resetOwnAccessibility = { resets += 1 }
        updated.startDragFlow = { flows.append($0) }
        updated.perform(row!)
        check(resets == 1 && flows.count == 1 && flows.first?.pane == .accessibility, "reset and add again", "resets the own grant, then the drag flow on a clean list")
        check(defaults.object(forKey: PermissionGuide.lastTrustedBuildKey) == nil, "reset and add again", "the old build is forgotten")
    }

    static func staleReset() async {
        nonisolated(unsafe) var reset: [String] = []
        var probes = PermissionProbes.inert
        probes.staleBuilds = { _ in [StaleBuild(bundleID: "com.gotcos.COSControl.FoundationLab", copies: 1)] }
        probes.resetAccessibility = { id in reset.append(id); return true }
        let g = guide(probes)
        await g.resetStaleBuild("com.gotcos.COSControl.FoundationLab")
        check(reset.isEmpty, "stale reset", "nothing is reset before it was found and listed")
        await g.findStaleBuilds()
        check(reset.isEmpty, "stale reset", "finding resets nothing")
        await g.resetStaleBuild("com.gotcos.control")
        await g.resetStaleBuild("com.gotcos.unlisted")
        check(reset.isEmpty, "stale reset", "never the running build, never an unlisted id")
        await g.resetStaleBuild("com.gotcos.COSControl.FoundationLab")
        check(reset == ["com.gotcos.COSControl.FoundationLab"] && g.staleResults["com.gotcos.COSControl.FoundationLab"] == "Removed from Accessibility", "stale reset", "a click resets that one")
    }
}
