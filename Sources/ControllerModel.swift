import AppKit
import Foundation
import ServiceManagement

@MainActor
final class ControllerModel: ObservableObject {
    /// Known-good server this Control build was verified against (footer / release notes).
    /// Install, adopt, and Update Server always resolve npm `@gotcos/glasses-server@latest`
    /// so the same UI path picks up 6.16.2+ without a Control rebuild.
    static let releaseServerVersion = "6.16.6"
    static let managedServerInstallVersion = "latest"

    @Published var status = ServerStatus()
    @Published var doctorChecks: [DoctorCheck] = []
    @Published var busy = false
    @Published var operationProgress: String?
    @Published var notice: String?
    @Published var error: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var recentMessages: [GlassesTurn] = []
    @Published var recentGlassesExpanded = false
    @Published var recentGlassesStatus: RecentGlassesStatus = .idle
    @Published var recentGlassesDate: String?
    @Published var appUpdate = AppUpdateInfo()

    /// This build's identity, handed to the helper so the answer can never depend on
    /// WHICH helper copy ran (bundled vs stable, HelperClient.helperURL():55-64).
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
    static var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    private let helper = HelperClient()
    private var refreshTask: Task<Void, Never>?
    private var updateCheckTask: Task<Void, Never>?

    init() {
        refreshTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(12))
                await self?.refresh(quiet: true)
            }
        }
        // Update check: once at launch, then every 6h. Deliberately NOT on the 12s
        // status loop -- this is a network call to a static file, not live state.
        updateCheckTask = Task { [weak self] in
            await self?.checkForAppUpdate()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
                await self?.checkForAppUpdate()
            }
        }
    }

    /// P1 check-only. Never mutates anything, never blocks the UI, and stays SILENT on
    /// failure: offline or a bad appcast leaves the previous state untouched rather than
    /// raising an error the user has to dismiss.
    func checkForAppUpdate() async {
        do {
            let response = try await helper.run([
                "check-app-update",
                "--current-version", Self.currentVersion,
                "--current-build", String(Self.currentBuild),
            ])
            appUpdate = AppUpdateInfo(response.details)
        } catch {
            // Intentionally swallowed: a failed check is not a user-facing problem.
        }
    }

    /// The ONLY action a check-only build offers. Opens the download page; it does not
    /// download, stage, or swap anything (that is P1.5/P2, gated on P0 notarization).
    func openUpdatePage() {
        let target = appUpdate.url.flatMap(URL.init(string:))
            ?? URL(string: "https://www.gotcos.com/control/")
        if let target { NSWorkspace.shared.open(target) }
    }

    deinit {
        refreshTask?.cancel()
        updateCheckTask?.cancel()
    }

    func refresh(quiet: Bool = false) async {
        if !quiet { busy = true }
        defer { if !quiet { busy = false } }
        do {
            let response = try await helper.run(["status"])
            status = ServerStatus(response.details)
            if !quiet { error = nil }
        } catch {
            status.running = false
            if !quiet { self.error = error.localizedDescription }
        }
    }

    func setRecentGlassesExpanded(_ expanded: Bool) {
        recentGlassesExpanded = expanded
        if expanded {
            Task { await refreshRecentMessages() }
        }
    }

    func refreshRecentMessages(quiet: Bool = false) async {
        if !quiet { recentGlassesStatus = .loading }
        do {
            let response = try await helper.run(["recent-messages", "--limit", "30"])
            let messages = Self.parseMessages(response.details["messages"])
            recentMessages = messages
            recentGlassesDate = response.details["date"]?.string
            if messages.isEmpty || response.details["state"]?.string == "empty" {
                recentGlassesStatus = .empty
            } else {
                recentGlassesStatus = .ready
            }
            if !quiet { error = nil }
        } catch {
            recentMessages = []
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("Server stopped") {
                recentGlassesStatus = .serverStopped
            } else if message.localizedCaseInsensitiveContains("Unauthorized") {
                recentGlassesStatus = .unauthorized
            } else {
                recentGlassesStatus = .error
            }
            if !quiet { notice = message }
        }
    }

    func copyTurn(_ turn: GlassesTurn) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(turn.turnClipboardText, forType: .string)
        notice = "Copied"
    }

    func copyHandoff() {
        let day = recentGlassesDate ?? String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var lines: [String] = [
            "COS Glasses handoff · \(day) · last \(recentMessages.count) turns",
            "Continue from this context. Global msg numbers refer to glasses history.",
            "",
        ]
        // Handoff reads oldest→newest for chat continuity (list UI is newest-first).
        for turn in recentMessages.reversed() {
            let label = turn.no.map { "Msg \($0)" } ?? "Msg"
            lines.append("[\(label)] User: \(turn.query)")
            lines.append("[\(label)] COS: \(turn.text)")
            lines.append("")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        notice = "Copied"
    }

    func openCursor() {
        let cursorApp = URL(fileURLWithPath: "/Applications/Cursor.app")
        guard FileManager.default.fileExists(atPath: cursorApp.path) else {
            error = "Cursor.app not found in /Applications"
            return
        }
        if let work = status.workDirectory, !work.isEmpty {
            let folder = URL(fileURLWithPath: work, isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.path) {
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open([folder], withApplicationAt: cursorApp, configuration: configuration) { [weak self] _, openError in
                    Task { @MainActor in
                        if let openError {
                            self?.error = openError.localizedDescription
                        } else {
                            self?.notice = "Opened work folder in Cursor"
                        }
                    }
                }
                return
            }
        }
        NSWorkspace.shared.openApplication(at: cursorApp, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, openError in
            Task { @MainActor in
                if let openError {
                    self?.error = openError.localizedDescription
                } else {
                    self?.notice = "Opened Cursor"
                }
            }
        }
    }

    func perform(_ command: String, arguments: [String] = []) {
        guard !busy else { return }
        busy = true
        operationProgress = "Starting \(command.replacingOccurrences(of: "-", with: " "))…"
        notice = nil
        error = nil
        Task {
            defer {
                busy = false
                operationProgress = nil
            }
            do {
                let response = try await helper.run([command] + arguments) { [weak self] message in
                    Task { @MainActor in self?.operationProgress = message }
                }
                notice = response.message
                if command == "doctor" {
                    doctorChecks = Self.parseChecks(response.details["checks"])
                }
                if let report = response.details["report"]?.string {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                    notice = "Redacted report copied"
                }
                if let nestedStatus = response.details["status"]?.object {
                    status = ServerStatus(nestedStatus)
                } else if response.details["running"] != nil {
                    status = ServerStatus(response.details)
                }
                await refresh(quiet: true)
            } catch {
                self.error = error.localizedDescription
                await refresh(quiet: true)
            }
        }
    }

    func installCurrentRelease() {
        perform("install", arguments: ["--version", Self.managedServerInstallVersion])
    }

    /// Stop recognized legacy (if needed) and install the current npm latest managed server.
    func installLatestManagedFromLegacy() {
        perform("adopt", arguments: ["--version", Self.managedServerInstallVersion])
    }

    func selectWorkFolder() {
        let panel = NSOpenPanel()
        panel.title = "Work Folder — COS agent workspace"
        panel.message = "This is the repo/workdir Claude, Codex, and Cursor use for tools and edits. It is not the meetings library."
        panel.prompt = "Use as Work Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform("set-workdir", arguments: [url.path])
    }

    func selectOperationsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Meetings Library — COS operations folder"
        panel.message = "Select the operations/ directory that contains quilt/meetings, personal/meetings, etc. This is only for G2 Review Meetings — not the agent work folder."
        panel.prompt = "Use as Meetings Library"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform("set-operations-dir", arguments: [url.path])
    }

    func openLogs() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/COS Glasses", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func openSetupGuide() {
        if let url = URL(string: "https://gotcos.com/control/") { NSWorkspace.shared.open(url) }
    }

    func openHealth() {
        if let url = URL(string: "http://127.0.0.1:3141/api/health") { NSWorkspace.shared.open(url) }
    }

    func runGuidedSetup() {
        let command = "npx --yes @gotcos/glasses-server@latest --prepare-only"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"\(escaped)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
        notice = "Guided setup opened in Terminal"
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            self.error = "Launch at Login could not be changed: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private static func parseChecks(_ value: JSONValue?) -> [DoctorCheck] {
        value?.array?.compactMap { item in
            guard let object = item.object, let name = object["name"]?.string,
                  let state = object["state"]?.string, let detail = object["detail"]?.string else { return nil }
            return DoctorCheck(name: name, state: state, detail: detail)
        } ?? []
    }

    private static func parseMessages(_ value: JSONValue?) -> [GlassesTurn] {
        value?.array?.compactMap { item in
            guard let object = item.object else { return nil }
            return GlassesTurn(object)
        } ?? []
    }
}
