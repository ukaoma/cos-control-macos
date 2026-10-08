import Foundation
import Combine

// The COS permission guide (Granola-style onboarding helper), the model half.
//
// Everything in this file is plain logic over facts the probes gathered: no window, no System Settings, no TCC call.
// It compiles on its own (Tests/run-permission-guide.sh builds it with Tests/PermissionGuideChecks.swift and nothing
// else), so a check never needs the whole app. The live probes are in PermissionGuideSystem.swift, the drag flow in
// PermissionDragFlow.swift, the views in PermissionGuideViews.swift.

/// One thing COS asks macOS for.
enum PermissionKind: String, Sendable, CaseIterable {
    case accessibility, notifications, launchAtLogin, backgroundJobs, automation, calendar
}

enum PermissionStatus: String, Sendable, Equatable {
    case allowed, needsYou, notNeededYet

    var label: String {
        switch self {
        case .allowed: "Allowed"
        case .needsYou: "Needs you"
        case .notNeededYet: "Not needed yet"
        }
    }
}

/// The System Settings panes the guide opens.
enum PermissionPane: String, Sendable, Equatable {
    case accessibility, fullDiskAccess, automation, notifications

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .fullDiskAccess: "Full Disk Access"
        case .automation: "Automation"
        case .notifications: "Notifications"
        }
    }

    /// The deep link. `bundleID` matters only for Notifications, which opens that app's own page.
    func settingsURL(bundleID: String = "com.gotcos.control") -> URL {
        let raw: String = switch self {
        case .accessibility: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .fullDiskAccess: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case .automation: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        case .notifications: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)"
        }
        return URL(string: raw)!
    }

    /// Panes whose list takes a dragged app or binary.
    var takesDrag: Bool { self == .accessibility || self == .fullDiskAccess }
}

/// What the floating bar holds as its drag source.
struct PermissionDragSource: Sendable, Equatable {
    /// The file a drop adds. For COS Control this is the RUNNING bundle, so the copy that asked is the copy added.
    let path: String
    /// What the bar calls it ("COS Control", "COS background helper (Python)").
    let name: String
}

/// The one action a row offers.
enum PermissionAction: Sendable, Equatable {
    case drag(PermissionPane, PermissionDragSource)
    case resetAndAddAgain
    case askNotifications
    case openSettings(PermissionPane)
    case turnOnLoginItem
    case openLoginItems
    case testAutomation(bundleID: String)
    case launchCalendarFetch(path: String)
    case none

    var title: String {
        switch self {
        case .drag: "Allow"
        case .resetAndAddAgain: "Reset and add again"
        case .askNotifications: "Allow"
        case .openSettings: "Open settings"
        case .turnOnLoginItem: "Turn on"
        case .openLoginItems: "Open Login Items"
        case .testAutomation: "Test"
        case .launchCalendarFetch: "Fix"
        case .none: ""
        }
    }
}

struct PermissionRow: Identifiable, Sendable, Equatable {
    let id: String
    let kind: PermissionKind
    let title: String
    /// What it unlocks, in plain words.
    let unlocks: String
    var status: PermissionStatus
    /// A second line with the evidence ("Stopped before starting: meeting-sync"), when there is any.
    var detail: String?
    var action: PermissionAction
}

// MARK: - Facts the probes gather

enum NotificationFact: Sendable, Equatable {
    case unknown, notDetermined, denied
    case allowed(alertsOn: Bool)
}

enum LoginItemFact: Sendable, Equatable { case enabled, requiresApproval, off }

/// One com.cos.* LaunchAgent, as its plist and launchd describe it.
struct LaunchJob: Sendable, Equatable {
    let label: String
    /// The executable launchd starts for the job's work (a `/bin/sh -c "exec …"` wrapper is looked through).
    let interpreter: String
    /// Whether the job reads a folder macOS protects (Documents, Desktop, Downloads, iCloud Drive).
    let readsProtectedFolder: Bool
    var running = false
    var runs: Int?
    /// launchd's last exit code; nil when it never exited or launchd does not know the job.
    var lastExit: Int?
}

enum CalendarFact: Sendable, Equatable {
    case allowed
    case denied
    case unknown
}

struct AutomationTarget: Sendable, Equatable {
    let bundleID: String
    let name: String
}

/// The answer AEDeterminePermissionToAutomateTarget gave, without asking.
enum AutomationFact: Sendable, Equatable {
    case allowed, denied, notAsked
    case notRunning
    case unknown(Int32)

    init(osStatus: Int32) {
        switch osStatus {
        case 0: self = .allowed
        case -1743: self = .denied          // errAEEventNotPermitted
        case -1744: self = .notAsked        // errAEEventWouldRequireUserConsent
        case -600: self = .notRunning       // procNotFound
        default: self = .unknown(osStatus)
        }
    }
}

struct PermissionFacts: Sendable, Equatable {
    var accessibilityTrusted = false
    /// A feature that needs Accessibility is on or has asked (the pet, a jump).
    var accessibilityWanted = false
    /// Untrusted on a build other than the last one that was trusted: the grant is keyed to an old signature.
    var staleGrantSuspected = false
    var notifications: NotificationFact = .unknown
    var loginItem: LoginItemFact = .off
    /// Every com.cos.* job on this Mac. Empty on a Mac without the COS pipeline.
    var jobs: [LaunchJob] = []
    /// Installed apps COS can automate, and macOS's answer for each.
    var automation: [(target: AutomationTarget, fact: AutomationFact)] = []
    /// CalendarFetch.app, when the COS pipeline has one, and its last run.
    var calendarAppPath: String?
    var calendar: CalendarFact = .unknown

    static func == (a: PermissionFacts, b: PermissionFacts) -> Bool {
        a.accessibilityTrusted == b.accessibilityTrusted && a.accessibilityWanted == b.accessibilityWanted
            && a.staleGrantSuspected == b.staleGrantSuspected && a.notifications == b.notifications
            && a.loginItem == b.loginItem && a.jobs == b.jobs && a.calendarAppPath == b.calendarAppPath
            && a.calendar == b.calendar
            && a.automation.map(\.target) == b.automation.map(\.target) && a.automation.map(\.fact) == b.automation.map(\.fact)
    }
}

// MARK: - Rows

enum PermissionGuideRules {
    /// The targets COS sends Apple Events to (sendReopenEvent, Guided Setup's Terminal script).
    static let automationTargets: [AutomationTarget] = [
        AutomationTarget(bundleID: "com.anthropic.claudefordesktop", name: "Claude"),
        AutomationTarget(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor"),
        AutomationTarget(bundleID: "com.apple.Terminal", name: "Terminal"),
        AutomationTarget(bundleID: "com.googlecode.iterm2", name: "iTerm"),
    ]

    /// The rows this Mac needs, in a fixed order. Rows that do not apply here are left out, never shown greyed.
    static func rows(_ facts: PermissionFacts, appName: String, appPath: String) -> [PermissionRow] {
        var rows = [accessibility(facts, appName: appName, appPath: appPath), notifications(facts), loginItem(facts)]
        rows += backgroundJobRows(facts.jobs)
        rows += facts.automation.map { automation($0.target, $0.fact) }
        if let calendar = calendarRow(facts) { rows.append(calendar) }
        return rows
    }

    static func accessibility(_ facts: PermissionFacts, appName: String, appPath: String) -> PermissionRow {
        let source = PermissionDragSource(path: appPath, name: appName)
        var row = PermissionRow(
            id: "accessibility", kind: .accessibility, title: "Accessibility",
            unlocks: "Lets COS jump straight to your Claude or Cursor session and bring its window forward.",
            status: .allowed, detail: nil, action: .none)
        guard !facts.accessibilityTrusted else { return row }
        row.status = facts.accessibilityWanted || facts.staleGrantSuspected ? .needsYou : .notNeededYet
        if facts.staleGrantSuspected {
            row.detail = "An update changed COS Control's signature, so the old switch no longer counts."
            row.action = .resetAndAddAgain
        } else {
            row.action = .drag(.accessibility, source)
        }
        return row
    }

    static func notifications(_ facts: PermissionFacts) -> PermissionRow {
        var row = PermissionRow(
            id: "notifications", kind: .notifications, title: "Notifications",
            unlocks: "Lets COS tell you when meeting audio stops reaching this Mac and when Work needs you.",
            status: .allowed, detail: nil, action: .none)
        switch facts.notifications {
        case .allowed(alertsOn: true): break
        case .allowed(alertsOn: false):
            row.status = .needsYou
            row.detail = "Allowed, but alerts are switched off."
            row.action = .openSettings(.notifications)
        case .denied:
            row.status = .needsYou
            row.action = .openSettings(.notifications)
        case .notDetermined, .unknown:
            row.status = .notNeededYet
            row.action = .askNotifications
        }
        return row
    }

    static func loginItem(_ facts: PermissionFacts) -> PermissionRow {
        var row = PermissionRow(
            id: "launchAtLogin", kind: .launchAtLogin, title: "Open at login",
            unlocks: "Starts COS Control when you log in, so the pet, meeting alerts and Work stay on.",
            status: .allowed, detail: nil, action: .none)
        switch facts.loginItem {
        case .enabled: break
        case .requiresApproval:
            row.status = .needsYou
            row.detail = "macOS is waiting for you to approve it in Login Items."
            row.action = .openLoginItems
        case .off:
            row.status = .notNeededYet
            row.action = .turnOnLoginItem
        }
        return row
    }

    // MARK: Background jobs

    /// One row per interpreter the protected-folder jobs run, so each drag adds the binary that actually reads the files.
    static func backgroundJobRows(_ jobs: [LaunchJob]) -> [PermissionRow] {
        var order: [String] = []
        var groups: [String: [LaunchJob]] = [:]
        for job in jobs where job.readsProtectedFolder {
            if groups[job.interpreter] == nil { order.append(job.interpreter) }
            groups[job.interpreter, default: []].append(job)
        }
        return order.map { interpreter in
            let group = groups[interpreter] ?? []
            let name = interpreterName(interpreter)
            let isServer = group.contains { $0.label == "com.cos.glasses-server" }
            let source = PermissionDragSource(path: interpreter, name: dragName(interpreter: interpreter, server: isServer))
            var row = PermissionRow(
                id: "backgroundJobs:" + interpreter, kind: .backgroundJobs,
                title: isServer && group.count == 1 ? "Glasses server (\(name))" : "Background jobs (\(name))",
                unlocks: isServer && group.count == 1
                    ? "Lets the glasses server read your COS scripts in Documents."
                    : "Lets COS's scheduled jobs, such as meeting sync, read your COS folder after macOS updates.",
                status: jobStatus(group), detail: jobDetail(group), action: .drag(.fullDiskAccess, source))
            if row.status == .allowed { row.action = .none }
            return row
        }
    }

    /// Positive signals only. Exit 78 (EX_CONFIG: launchd could not start the job, which is what a missing
    /// folder grant looks like) is Needs you. A job that is running, or that ran and exited with anything else, is
    /// Allowed. Jobs that have never run prove nothing either way: Not needed yet.
    static func jobStatus(_ jobs: [LaunchJob]) -> PermissionStatus {
        if jobs.contains(where: { $0.lastExit == 78 }) { return .needsYou }
        if jobs.contains(where: { $0.running || (($0.runs ?? 0) > 0 && $0.lastExit != nil) }) { return .allowed }
        return .notNeededYet
    }

    static func jobDetail(_ jobs: [LaunchJob]) -> String? {
        let stopped = jobs.filter { $0.lastExit == 78 }.map { shortLabel($0.label) }
        if !stopped.isEmpty {
            let shown = stopped.prefix(3).joined(separator: ", ")
            return "Stopped before starting: " + shown + (stopped.count > 3 ? " and \(stopped.count - 3) more" : "")
        }
        return nil
    }

    static func shortLabel(_ label: String) -> String {
        label.hasPrefix("com.cos.") ? String(label.dropFirst("com.cos.".count)) : label
    }

    static func interpreterName(_ path: String) -> String {
        let base = (path as NSString).lastPathComponent.lowercased()
        if base.hasPrefix("python") { return "Python" }
        if base == "node" { return "Node" }
        return (path as NSString).lastPathComponent
    }

    static func dragName(interpreter: String, server: Bool) -> String {
        let name = interpreterName(interpreter)
        return server && name == "Node" ? "COS glasses server (Node)" : "COS background helper (\(name))"
    }

    // MARK: Automation and Calendar

    static func automation(_ target: AutomationTarget, _ fact: AutomationFact) -> PermissionRow {
        var row = PermissionRow(
            id: "automation:" + target.bundleID, kind: .automation, title: "Automation: " + target.name,
            unlocks: "Lets COS reopen \(target.name) and bring your session forward.",
            status: .allowed, detail: nil, action: .none)
        switch fact {
        case .allowed: break
        case .denied:
            row.status = .needsYou
            row.detail = "Turned off for \(target.name) under Automation."
            row.action = .openSettings(.automation)
        case .notAsked:
            row.status = .notNeededYet
            row.action = .testAutomation(bundleID: target.bundleID)
        case .notRunning:
            row.status = .notNeededYet
            row.detail = "Checked when \(target.name) is open. Test opens it."
            row.action = .testAutomation(bundleID: target.bundleID)
        case .unknown(let code):
            row.status = .notNeededYet
            row.detail = "macOS answered \(code)."
            row.action = .testAutomation(bundleID: target.bundleID)
        }
        return row
    }

    static func calendarRow(_ facts: PermissionFacts) -> PermissionRow? {
        guard let path = facts.calendarAppPath else { return nil }
        var row = PermissionRow(
            id: "calendar", kind: .calendar, title: "Calendar (CalendarFetch)",
            unlocks: "Lets COS keep your meeting-prep calendar cache up to date.",
            status: .allowed, detail: nil, action: .none)
        switch facts.calendar {
        case .allowed: break
        case .denied:
            row.status = .needsYou
            row.detail = "Its last run was refused calendar access."
            row.action = .launchCalendarFetch(path: path)
        case .unknown:
            row.status = .notNeededYet
            row.action = .launchCalendarFetch(path: path)
        }
        return row
    }

    // MARK: Panel summary

    static func needCount(_ rows: [PermissionRow]) -> Int { rows.filter { $0.status == .needsYou }.count }

    static func summary(_ rows: [PermissionRow]) -> String {
        let count = needCount(rows)
        switch count {
        case 0: return "All set"
        case 1: return "1 needs you"
        default: return "\(count) need you"
        }
    }
}

// MARK: - Parsers (launchd, the CalendarFetch log, Spotlight)

enum LaunchdParse {
    /// `launchctl print gui/<uid>/<label>`: running, runs, last exit code.
    static func service(_ text: String) -> (running: Bool, runs: Int?, lastExit: Int?) {
        var running = false, runs: Int?, lastExit: Int?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Only the service's own top-level fields; nested endpoint blocks also say "state = active".
            guard raw.hasPrefix("\t"), !raw.hasPrefix("\t\t") else { continue }
            if line == "state = running" { running = true }
            if line.hasPrefix("runs = ") { runs = Int(line.dropFirst("runs = ".count)) }
            if line.hasPrefix("last exit code = ") {
                let value = line.dropFirst("last exit code = ".count)
                lastExit = Int(value.prefix { $0 == "-" || $0.isNumber })
            }
        }
        return (running, runs, lastExit)
    }

    /// The executable a job's ProgramArguments really run. A shell wrapper (`/bin/sh -lc "exec '/path/python' …"`)
    /// and `/usr/bin/env python3` are looked through, so the drag adds the binary that reads the files.
    static func interpreter(_ arguments: [String]) -> String? {
        guard let first = arguments.first else { return nil }
        let shells: Set<String> = ["/bin/sh", "/bin/zsh", "/bin/bash", "/bin/dash", "/usr/bin/env"]
        if (first as NSString).lastPathComponent == "env" || first == "/usr/bin/env" {
            return arguments.dropFirst().first { !$0.hasPrefix("-") && !$0.contains("=") }
        }
        guard shells.contains(first) else { return first }
        guard let flag = arguments.firstIndex(where: { $0.hasPrefix("-") && $0.contains("c") }),
              flag + 1 < arguments.count else { return first }
        return shellWords(arguments[flag + 1]).first(where: { $0 != "exec" && !isAssignment($0) }) ?? first
    }

    static func isAssignment(_ word: String) -> Bool {
        guard let eq = word.firstIndex(of: "="), eq != word.startIndex else { return false }
        return word[..<eq].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Splits a shell command line into words: single and double quotes, backslash escapes. Stops at ; & | so only
    /// the first command is read.
    static func shellWords(_ line: String) -> [String] {
        var words: [String] = [], current = "", inWord = false
        var quote: Character?
        var escape = false
        for ch in line {
            if escape { current.append(ch); escape = false; inWord = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else if ch == "\\" && q == "\"" { escape = true } else { current.append(ch) }
                continue
            }
            switch ch {
            case "'", "\"": quote = ch; inWord = true
            case "\\": escape = true
            case " ", "\t", "\n":
                if inWord { words.append(current); current = ""; inWord = false }
            case ";", "&", "|":
                if inWord { words.append(current) }
                return words
            default: current.append(ch); inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }

    /// Folders macOS guards with a per-app grant, which launchd cannot ask for.
    static func isProtected(_ path: String, home: String) -> Bool {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        return ["/Documents/", "/Desktop/", "/Downloads/", "/Library/Mobile Documents/"]
            .contains { path.hasPrefix(base + $0) }
    }

    /// Whether a job touches a protected folder: any argument, word of a shell command, working directory or
    /// COS_SCRIPTS_DIR under one.
    static func readsProtectedFolder(arguments: [String], environment: [String: String], workingDirectory: String?, home: String) -> Bool {
        var paths = arguments.flatMap { shellWords($0) } + arguments
        if let dir = workingDirectory { paths.append(dir) }
        if let scripts = environment["COS_SCRIPTS_DIR"] { paths.append(scripts + "/") }
        return paths.contains { isProtected($0, home: home) }
    }

    /// LaunchAgent file names COS owns. Backups (`.plist.bak-…`, `.plist.ROLLEDBACK-…`) do not end in `.plist`.
    static func isCOSAgentFile(_ name: String) -> Bool {
        name.hasPrefix("com.cos.") && name.hasSuffix(".plist") && name.count > "com.cos..plist".count
    }
}

enum CalendarFetchLog {
    /// The last line of refresh_calendar_cache.py's JSON log that says whether EventKit answered.
    static func status(_ text: String) -> CalendarFact {
        for raw in text.split(separator: "\n").reversed() {
            guard let data = raw.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = entry["msg"] as? String else { continue }
            switch message {
            case "swift_success", "cache_refreshed": return .allowed
            case "swift_permission_or_calendar_error": return .denied
            default: continue
            }
        }
        return .unknown
    }
}

/// An old COS build whose bundle id still has rows in Privacy & Security.
struct StaleBuild: Sendable, Equatable, Identifiable {
    var id: String { bundleID }
    let bundleID: String
    let copies: Int
}

enum StaleBuilds {
    static let prefixes = ["com.gotcos."]

    /// `mdfind -attr kMDItemCFBundleIdentifier '<query>'` output: "<path>   kMDItemCFBundleIdentifier = <id>" per
    /// line. The running build's id is never listed (that one is Reset and add again).
    static func parse(_ output: String, runningID: String) -> [StaleBuild] {
        var counts: [String: Int] = [:]
        let marker = "kMDItemCFBundleIdentifier = "
        for line in output.split(separator: "\n") {
            guard let range = line.range(of: marker, options: .backwards) else { continue }
            let id = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard prefixes.contains(where: { id.hasPrefix($0) }), id != runningID,
                  id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { continue }
            counts[id, default: 0] += 1
        }
        return counts.map { StaleBuild(bundleID: $0.key, copies: $0.value) }.sorted { $0.bundleID < $1.bundleID }
    }

    static var spotlightQuery: String {
        prefixes.map { "kMDItemCFBundleIdentifier == \"\($0)*\"" }.joined(separator: " || ")
    }
}

// MARK: - The floating bar's steps

/// The bar's life: waiting for the grant, offering help after two minutes, showing Allowed, closing.
struct HelperBarStep: Sendable, Equatable {
    enum Phase: Sendable, Equatable { case waiting, trouble, allowed, closed }
    enum Effect: Sendable, Equatable { case showAllowed, resume, offerTrouble, close(returnToCOS: Bool) }

    static let troubleAfter: TimeInterval = 120
    static let closeAfterAllowed: TimeInterval = 1.5
    /// System Settings takes a moment to launch; until then "not open" means "not open yet".
    static let launchGrace: TimeInterval = 5

    private(set) var phase: Phase = .waiting
    let startedAt: TimeInterval
    private(set) var allowedAt: TimeInterval?

    init(startedAt: TimeInterval) { self.startedAt = startedAt }

    /// One observation. `granted` is the API's answer AND a real read that worked: the API alone can say trusted while
    /// calls still fail, so it never closes the bar by itself.
    mutating func observe(granted: Bool, settingsOpen: Bool, now: TimeInterval) -> [Effect] {
        switch phase {
        case .closed:
            return []
        case .allowed:
            guard let at = allowedAt, now - at >= Self.closeAfterAllowed else { return [] }
            phase = .closed
            return [.close(returnToCOS: true)]
        case .waiting, .trouble:
            if granted {
                phase = .allowed
                allowedAt = now
                return [.showAllowed, .resume]
            }
            if !settingsOpen, now - startedAt >= Self.launchGrace {
                phase = .closed
                return [.close(returnToCOS: false)]
            }
            if phase == .waiting, now - startedAt >= Self.troubleAfter {
                phase = .trouble
                return [.offerTrouble]
            }
            return []
        }
    }

    /// The person closed the bar.
    mutating func dismiss() -> [Effect] {
        guard phase != .closed else { return [] }
        phase = .closed
        return [.close(returnToCOS: false)]
    }
}

// MARK: - Probes

/// Everything the guide reads from or asks of macOS, so the checks can stand in for it.
struct PermissionProbes: Sendable {
    var accessibilityTrusted: @Sendable () -> Bool
    var notifications: @Sendable () async -> NotificationFact
    var requestNotifications: @Sendable () async -> Bool
    var loginItem: @Sendable () -> LoginItemFact
    var launchJobs: @Sendable () async -> [LaunchJob]
    var installedApp: @Sendable (String) -> String?
    /// `ask` false never shows a prompt.
    var automation: @Sendable (_ bundleID: String, _ ask: Bool) async -> AutomationFact
    var calendarAppPath: @Sendable () -> String?
    var calendar: @Sendable () -> CalendarFact
    var staleBuilds: @Sendable (_ runningID: String) async -> [StaleBuild]
    var resetAccessibility: @Sendable (_ bundleID: String) async -> Bool
    /// Starts one job that stopped with exit 78, so a fresh run says whether the new grant worked.
    var kickstart: @Sendable (_ label: String) async -> Void

    /// A Mac where nothing has been granted and nothing is installed. The checks start from this.
    static let inert = PermissionProbes(
        accessibilityTrusted: { false }, notifications: { .unknown }, requestNotifications: { false },
        loginItem: { .off }, launchJobs: { [] }, installedApp: { _ in nil }, automation: { _, _ in .notRunning },
        calendarAppPath: { nil }, calendar: { .unknown }, staleBuilds: { _ in [] }, resetAccessibility: { _ in false },
        kickstart: { _ in })
}

/// A request to start the drag flow for a row.
struct PermissionDragRequest: Sendable, Equatable {
    let rowID: String
    let pane: PermissionPane
    let source: PermissionDragSource
    /// The feature that asked ("Jump to your session"), shown on the bar.
    let feature: String?
}

// MARK: - The guide

@MainActor
final class PermissionGuide: ObservableObject {
    @Published private(set) var facts = PermissionFacts()
    @Published private(set) var rows: [PermissionRow] = []
    /// The panel shows the guide card while this is true. Only the opener writes it.
    @Published var panelRouteActive = false
    /// The row the guide opened on, when a feature asked.
    @Published private(set) var focusedRowID: String?
    /// The feature waiting on each row ("Jump to your session").
    @Published private(set) var waitingFeature: [String: String] = [:]
    @Published private(set) var staleBuilds: [StaleBuild]?
    @Published private(set) var staleSearching = false
    @Published private(set) var staleResults: [String: String] = [:]
    @Published private(set) var lastRefresh: Date?
    @Published var notice: String?

    let probes: PermissionProbes
    let appName: String
    let appPath: String
    let bundleID: String
    let currentBuild: Int
    private let defaults: UserDefaults

    /// Starts the AppKit drag flow (PermissionDragFlow). nil in checks, which then record the request instead.
    var startDragFlow: (@MainActor (PermissionDragRequest) -> Void)?
    /// The model's Reset and add again for COS Control's own grant.
    var resetOwnAccessibility: (@MainActor () -> Void)?
    var turnOnLoginItem: (@MainActor () -> Void)?
    var openURL: (@MainActor (URL) -> Void)?
    var openLoginItems: (@MainActor () -> Void)?
    var launchApp: (@MainActor (String) -> Void)?
    /// Whether a feature that needs Accessibility is switched on (the session pet).
    var accessibilityWanted: @MainActor () -> Bool = { false }

    private(set) var lastDragRequest: PermissionDragRequest?
    private var resumes: [String: [@MainActor () -> Void]] = [:]
    private var refreshing: Task<Void, Never>?

    static let lastTrustedBuildKey = "cos.permissionGuide.lastTrustedBuild"
    static let onboardingDoneKey = "cos.permissionGuide.onboardingDone"

    init(probes: PermissionProbes, appName: String, appPath: String, bundleID: String, currentBuild: Int,
         defaults: UserDefaults = .standard) {
        self.probes = probes
        self.appName = appName
        self.appPath = appPath
        self.bundleID = bundleID
        self.currentBuild = currentBuild
        self.defaults = defaults
        rebuild()
    }

    var summary: String { PermissionGuideRules.summary(rows) }
    var needCount: Int { PermissionGuideRules.needCount(rows) }

    var onboardingDone: Bool {
        get { defaults.bool(forKey: Self.onboardingDoneKey) }
        set { defaults.set(newValue, forKey: Self.onboardingDoneKey); objectWillChange.send() }
    }

    func row(_ id: String) -> PermissionRow? { rows.first { $0.id == id } }
    func row(kind: PermissionKind) -> PermissionRow? { rows.first { $0.kind == kind } }

    // MARK: Reading

    /// Reads every fact again. Calls that overlap share one read.
    func refresh() async {
        if let running = refreshing { await running.value; return }
        let task = Task { await self.read() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func read() async {
        var next = PermissionFacts()
        next.accessibilityTrusted = probes.accessibilityTrusted()
        next.accessibilityWanted = accessibilityWanted() || waitingFeature["accessibility"] != nil
        next.staleGrantSuspected = staleGrant(trusted: next.accessibilityTrusted)
        next.notifications = await probes.notifications()
        next.loginItem = probes.loginItem()
        next.jobs = await probes.launchJobs()
        var automation: [(target: AutomationTarget, fact: AutomationFact)] = []
        for target in PermissionGuideRules.automationTargets where probes.installedApp(target.bundleID) != nil {
            automation.append((target, await probes.automation(target.bundleID, false)))
        }
        next.automation = automation
        next.calendarAppPath = probes.calendarAppPath()
        if next.calendarAppPath != nil { next.calendar = probes.calendar() }
        apply(next)
    }

    /// Remembers the last build Accessibility worked for, and suspects a stale grant on any other build.
    private func staleGrant(trusted: Bool) -> Bool {
        if trusted {
            defaults.set(currentBuild, forKey: Self.lastTrustedBuildKey)
            return false
        }
        let last = defaults.integer(forKey: Self.lastTrustedBuildKey)
        return last != 0 && last != currentBuild
    }

    /// Takes a new set of facts and runs whatever was waiting on a row that is now Allowed.
    func apply(_ next: PermissionFacts) {
        facts = next
        rebuild()
        lastRefresh = Date()
        for row in rows where row.status == .allowed { resumeWaiting(row.id) }
    }

    private func rebuild() {
        rows = PermissionGuideRules.rows(facts, appName: appName, appPath: appPath)
        if let focus = focusedRowID, row(focus) == nil { focusedRowID = nil }
    }

    // MARK: Just in time

    /// A feature declares the permission it needs. Returns true when it already has it, so the caller goes ahead.
    /// Otherwise the guide takes over: an interactive need (the person just clicked something) starts the row's own
    /// flow, a drag or the system prompt; a background need (a job that stopped, a meeting with alerts off) opens the
    /// guide on that row in the panel, never a window. `resume` runs once, when the row turns Allowed.
    @discardableResult
    func need(_ kind: PermissionKind, for feature: String, interactive: Bool = true,
              resume: (@MainActor () -> Void)? = nil) -> Bool {
        if kind == .accessibility {
            facts.accessibilityTrusted = probes.accessibilityTrusted()
            facts.accessibilityWanted = true
            facts.staleGrantSuspected = staleGrant(trusted: facts.accessibilityTrusted)
            rebuild()
        }
        // Several rows can share a kind (one per interpreter, one per app): the first that is not Allowed.
        guard let row = rows.first(where: { $0.kind == kind && $0.status != .allowed }) else { return true }
        waitingFeature[row.id] = feature
        if let resume { resumes[row.id, default: []].append(resume) }
        focusedRowID = row.id
        if interactive {
            perform(row, feature: feature)
        } else {
            panelRouteActive = true
        }
        return false
    }

    /// The row's one action, from a click on it (or from `need`).
    func perform(_ row: PermissionRow, feature: String? = nil) {
        let feature = feature ?? waitingFeature[row.id]
        switch row.action {
        case .none:
            break
        case .drag(let pane, let source):
            let request = PermissionDragRequest(rowID: row.id, pane: pane, source: source, feature: feature)
            lastDragRequest = request
            startDragFlow?(request)
        case .resetAndAddAgain:
            resetAndAddAgain(feature: feature)
        case .askNotifications:
            // The system prompt, at the moment of intent. A no is not followed by a jump to Settings: the row then
            // offers Open settings for the person to click.
            Task {
                _ = await probes.requestNotifications()
                await refresh()
            }
        case .openSettings(let pane):
            openURL?(pane.settingsURL(bundleID: bundleID))
        case .turnOnLoginItem:
            turnOnLoginItem?()
            Task { await refresh() }
        case .openLoginItems:
            openLoginItems?()
        case .testAutomation(let bundleID):
            Task {
                if await probes.automation(bundleID, false) == .notRunning {
                    if let path = probes.installedApp(bundleID) { launchApp?(path) }
                    try? await Task.sleep(for: .seconds(2))
                }
                _ = await probes.automation(bundleID, true)
                await refresh()
            }
        case .launchCalendarFetch(let path):
            launchApp?(path)
            Task { try? await Task.sleep(for: .seconds(4)); await refresh() }
        }
    }

    /// Reset and add again: clears COS Control's own Accessibility entry (it is keyed to an old signature), then
    /// opens the drag flow on a clean list.
    func resetAndAddAgain(feature: String? = nil) {
        let source = PermissionDragSource(path: appPath, name: appName)
        let request = PermissionDragRequest(rowID: "accessibility", pane: .accessibility, source: source,
                                            feature: feature ?? waitingFeature["accessibility"])
        lastDragRequest = request
        if let reset = resetOwnAccessibility {
            reset()
        } else {
            let id = bundleID
            Task { _ = await probes.resetAccessibility(id) }
        }
        defaults.removeObject(forKey: Self.lastTrustedBuildKey)
        startDragFlow?(request)
    }

    /// The drag flow saw the grant (Accessibility), or a fresh run of a stopped job worked (background jobs).
    func granted(rowID: String) {
        if rowID == "accessibility" {
            facts.accessibilityTrusted = true
            facts.staleGrantSuspected = staleGrant(trusted: true)
            rebuild()
        }
        resumeWaiting(rowID)
        Task { await refresh() }
    }

    private func resumeWaiting(_ rowID: String) {
        waitingFeature[rowID] = nil
        if focusedRowID == rowID { focusedRowID = nil }
        let pending = resumes.removeValue(forKey: rowID) ?? []
        for resume in pending { resume() }
    }

    /// Full Disk Access cannot be read for another binary. Check now starts one stopped job; its fresh exit code is
    /// the answer.
    func checkBackgroundJobs(rowID: String) async -> Bool {
        let interpreter = rowID.hasPrefix("backgroundJobs:") ? String(rowID.dropFirst("backgroundJobs:".count)) : ""
        guard let job = facts.jobs.first(where: { $0.interpreter == interpreter && $0.lastExit == 78 }) else {
            await refresh()
            return row(rowID)?.status == .allowed
        }
        await probes.kickstart(job.label)
        try? await Task.sleep(for: .seconds(5))
        await refresh()
        let fresh = facts.jobs.first { $0.label == job.label }
        let worked = fresh.map { $0.running || ($0.lastExit != nil && $0.lastExit != 78) } ?? false
        if worked { resumeWaiting(rowID) }
        return worked
    }

    // MARK: Panel route

    func openInPanel(focus rowID: String? = nil) {
        if let rowID { focusedRowID = rowID }
        panelRouteActive = true
        Task { await refresh() }
    }

    func closePanelRoute() {
        panelRouteActive = false
    }

    // MARK: Old test builds

    func findStaleBuilds() async {
        staleSearching = true
        staleResults = [:]
        staleBuilds = await probes.staleBuilds(bundleID)
        staleSearching = false
    }

    /// Resets one old build's Accessibility rows. Only ever from a click on that build's row.
    func resetStaleBuild(_ id: String) async {
        guard staleBuilds?.contains(where: { $0.bundleID == id }) == true, id != bundleID else { return }
        let ok = await probes.resetAccessibility(id)
        staleResults[id] = ok ? "Removed from Accessibility" : "macOS did not reset it"
    }
}
