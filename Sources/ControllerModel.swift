import AppKit
import Foundation
import ServiceManagement

private actor MediaFetchGate {
    private var available = 2
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { available = min(2, available + 1) }
        else { waiters.removeFirst().resume() }
    }
}

private enum MediaFetchError: LocalizedError {
    case unavailable(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable(let state):
            switch state {
            case "expired": return "This image has expired."
            case "missing": return "This image is no longer available."
            case "unauthorized": return "Image access is unauthorized. Refresh the pairing token."
            case "offline": return "The COS server is offline."
            default: return "This image is unavailable."
            }
        case .invalidResponse: return "COS returned an invalid image response."
        }
    }
}

@MainActor
final class ControllerModel: ObservableObject {
    /// Install / Adopt / Update Server always resolve npm `@latest` — the panel
    /// footer shows the *live* managed server version from status. The old
    /// `releaseServerVersion` "QA'd against" constant was removed 2026-08-02:
    /// nothing referenced it, and a hardcoded server version is exactly the
    /// stale-pin class the 0.2.8 footer fix retired — it read "6.20.1" forever
    /// while npm latest moves on without a Control rebuild.
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
    @Published var mediaPreviewStates: [String: RecentMediaPreviewState] = [:]
    @Published var selectedMediaPreview: SelectedMediaPreview?
    @Published var previewingMediaID: String?
    @Published var mediaExportingTurnIDs: Set<String> = []

    /// This build's identity, handed to the helper so the answer can never depend on
    /// WHICH helper copy ran (bundled vs stable, HelperClient.helperURL():55-64).
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
    static var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    private let helper = HelperClient()
    private let mediaFetchGate = MediaFetchGate()
    private var refreshTask: Task<Void, Never>?
    private var updateCheckTask: Task<Void, Never>?
    private var thumbnailTasks: [String: Task<Void, Never>] = [:]
    private var thumbnailLoadIDs: [String: UUID] = [:]

    init() {
        try? Self.pruneMediaHandoffs()
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
        thumbnailTasks.values.forEach { $0.cancel() }
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
        } else {
            cancelAllThumbnailLoads()
        }
    }

    func refreshRecentMessages(quiet: Bool = false) async {
        cancelAllThumbnailLoads()
        if !quiet { recentGlassesStatus = .loading }
        do {
            let response = try await helper.run(["recent-messages", "--limit", "30"])
            let messages = Self.parseMessages(response.details["messages"])
            recentMessages = messages
            reconcilePreviewCache(with: messages)
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

    func loadThumbnail(_ attachment: GlassesAttachmentRef) {
        guard mediaPreviewStates[attachment.id] == nil, thumbnailTasks[attachment.id] == nil else { return }
        let loadID = UUID()
        thumbnailLoadIDs[attachment.id] = loadID
        mediaPreviewStates[attachment.id] = .loading
        thumbnailTasks[attachment.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if thumbnailLoadIDs[attachment.id] == loadID {
                    thumbnailTasks[attachment.id] = nil
                    thumbnailLoadIDs[attachment.id] = nil
                }
            }
            do {
                let file = try await fetchMediaFile(attachment, variant: "thumb", purpose: "preview")
                defer { try? FileManager.default.removeItem(at: file.url) }
                guard !Task.isCancelled, thumbnailLoadIDs[attachment.id] == loadID,
                      let image = RecentMediaImageDecoder.decode(url: file.url, expectedBytes: file.bytes) else {
                    if !Task.isCancelled, thumbnailLoadIDs[attachment.id] == loadID {
                        mediaPreviewStates[attachment.id] = .unavailable("Invalid image")
                    }
                    return
                }
                mediaPreviewStates[attachment.id] = .ready(image)
            } catch {
                if !Task.isCancelled, thumbnailLoadIDs[attachment.id] == loadID {
                    mediaPreviewStates[attachment.id] = .unavailable(error.localizedDescription)
                }
            }
        }
    }

    func cancelThumbnail(_ attachment: GlassesAttachmentRef) {
        guard case .loading? = mediaPreviewStates[attachment.id] else { return }
        thumbnailLoadIDs.removeValue(forKey: attachment.id)
        thumbnailTasks.removeValue(forKey: attachment.id)?.cancel()
        mediaPreviewStates.removeValue(forKey: attachment.id)
    }

    func openMediaPreview(_ attachment: GlassesAttachmentRef) {
        guard previewingMediaID == nil else { return }
        previewingMediaID = attachment.id
        Task { [weak self] in
            guard let self else { return }
            defer { previewingMediaID = nil }
            do {
                let file = try await fetchMediaFile(attachment, variant: "phone", purpose: "preview")
                defer { try? FileManager.default.removeItem(at: file.url) }
                guard let image = RecentMediaImageDecoder.decode(url: file.url, expectedBytes: file.bytes) else {
                    throw MediaFetchError.invalidResponse
                }
                selectedMediaPreview = SelectedMediaPreview(attachment: attachment, image: image)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func copyTurnWithImages(_ turn: GlassesTurn) {
        guard !turn.attachments.isEmpty, mediaExportingTurnIDs.insert(turn.id).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { mediaExportingTurnIDs.remove(turn.id) }
            do {
                let manifest = try await exportMediaHandoff(for: turn)
                let copy = "Continue from this COS Glasses handoff:\n\(manifest.path)\n\nOpen the handoff and inspect only its generated image-NN.jpg/png files before responding."
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copy, forType: .string)
                notice = "Image handoff copied · pruned after 24h on next launch or export"
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func cancelAllThumbnailLoads() {
        for (id, task) in thumbnailTasks {
            task.cancel()
            if case .loading? = mediaPreviewStates[id] { mediaPreviewStates.removeValue(forKey: id) }
        }
        thumbnailTasks.removeAll()
        thumbnailLoadIDs.removeAll()
    }

    private func reconcilePreviewCache(with turns: [GlassesTurn]) {
        let activeIDs = Set(turns.flatMap { $0.attachments.map(\.id) })
        mediaPreviewStates = mediaPreviewStates.filter { id, state in
            guard activeIDs.contains(id) else { return false }
            if case .ready = state { return true }
            return false
        }
    }

    private func fetchMediaFile(
        _ attachment: GlassesAttachmentRef,
        variant: String,
        purpose: String
    ) async throws -> (url: URL, mime: String, bytes: Int) {
        await mediaFetchGate.acquire()
        let response: HelperResponse
        do {
            try Task.checkCancellation()
            response = try await helper.run([
                "fetch-media", "--id", attachment.id,
                "--variant", variant,
                "--purpose", purpose,
            ])
            await mediaFetchGate.release()
        } catch {
            await mediaFetchGate.release()
            throw error
        }
        let state = response.details["state"]?.string ?? "invalid"
        guard state == "ready" else { throw MediaFetchError.unavailable(state) }
        guard let path = response.details["path"]?.string,
              let mime = response.details["mime"]?.string,
              ["image/jpeg", "image/png"].contains(mime),
              let bytes = response.details["bytes"]?.int, bytes > 0 else {
            throw MediaFetchError.invalidResponse
        }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.gotcos.COSControl/MediaTransfers", isDirectory: true)
            .standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else { throw MediaFetchError.invalidResponse }
        let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true,
              values.fileSize == bytes else { throw MediaFetchError.invalidResponse }
        return (file, mime, bytes)
    }

    private func exportMediaHandoff(for turn: GlassesTurn) async throws -> URL {
        try Self.pruneMediaHandoffs()
        let fm = FileManager.default
        let root = try Self.privateHandoffRoot()
        let suffix = String(UUID().uuidString.lowercased().prefix(8))
        let number = turn.no.map(String.init) ?? "turn"
        let staging = root.appendingPathComponent(".staging-\(suffix)", isDirectory: true)
        let final = root.appendingPathComponent("msg-\(number)-\(suffix)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var committed = false
        defer { if !committed { try? fm.removeItem(at: staging) } }

        var imageLines: [String] = []
        var totalBytes = 0
        for (index, attachment) in turn.attachments.prefix(5).enumerated() {
            do {
                let file = try await fetchMediaFile(attachment, variant: "phone", purpose: "handoff")
                defer { if fm.fileExists(atPath: file.url.path) { try? fm.removeItem(at: file.url) } }
                guard totalBytes + file.bytes <= 25 * 1_024 * 1_024 else {
                    imageLines.append("- \(attachment.displayLabel) (\(attachment.mime), \(attachment.width)×\(attachment.height)): omitted (25 MiB handoff limit)")
                    continue
                }
                guard RecentMediaImageDecoder.decode(url: file.url, expectedBytes: file.bytes) != nil else {
                    throw MediaFetchError.invalidResponse
                }
                let ext = file.mime == "image/png" ? "png" : "jpg"
                let name = String(format: "image-%02d.%@", index + 1, ext)
                let destination = staging.appendingPathComponent(name)
                try fm.moveItem(at: file.url, to: destination)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                totalBytes += file.bytes
                let safeLabel = Self.safeManifestLabel(attachment.label ?? attachment.displayLabel)
                imageLines.append("- \(attachment.displayLabel) (\(attachment.mime), \(attachment.width)×\(attachment.height), \(safeLabel))\n\n  ![\(attachment.displayLabel)](\(name))")
            } catch {
                imageLines.append("- \(attachment.displayLabel) (\(attachment.mime), \(attachment.width)×\(attachment.height)): unavailable (\(error.localizedDescription))")
            }
        }

        let label = turn.no.map { "Msg \($0)" } ?? "Msg"
        let manifest = """
        # COS Glasses image handoff

        Temporary local export. Bundles older than 24 hours are pruned on the
        next COS Control launch or image export.

        ## \(label)

        **User**

        \(Self.inertManifestText(turn.query))

        **COS**

        \(Self.inertManifestText(turn.text))

        ## Images

        \(imageLines.isEmpty ? "- No image bytes were available." : imageLines.joined(separator: "\n"))
        """
        let manifestURL = staging.appendingPathComponent("handoff.md")
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        try fm.moveItem(at: staging, to: final)
        committed = true
        return final.appendingPathComponent("handoff.md")
    }

    private static func inertManifestText(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "    \($0)" }
            .joined(separator: "\n")
    }

    private static func safeManifestLabel(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_."))
        let sanitized = String(value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : " " })
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((sanitized.isEmpty ? "image" : sanitized).prefix(120))
    }

    private static func privateHandoffRoot() throws -> URL {
        let fm = FileManager.default
        let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.gotcos.COSControl", isDirectory: true)
        let root = cache.appendingPathComponent("Handoffs", isDirectory: true)
        for directory in [cache, root] {
            if fm.fileExists(atPath: directory.path) {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw MediaFetchError.invalidResponse }
            } else {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        return root.standardizedFileURL
    }

    private static func pruneMediaHandoffs(now: Date = Date()) throws {
        let fm = FileManager.default
        let root = try privateHandoffRoot()
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        let entries = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: []
        )
        for entry in entries {
            let normalized = entry.standardizedFileURL
            guard normalized.path.hasPrefix(root.path + "/") else { continue }
            let values = try normalized.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  (values.contentModificationDate ?? .distantFuture) < cutoff else { continue }
            try? fm.removeItem(at: normalized)
        }
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
        // Doctor and Copy Report name this build. Injected here, not at the call
        // sites, so a new caller cannot ship a report that omits its version.
        let identity = ["doctor", "report"].contains(command)
            ? ["--current-version", Self.currentVersion, "--current-build", String(Self.currentBuild)]
            : []
        Task {
            defer {
                busy = false
                operationProgress = nil
            }
            do {
                let response = try await helper.run([command] + arguments + identity) { [weak self] message in
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

    func setTranscriptionTier(_ tier: String) {
        perform("set-transcription-tier", arguments: [tier])
    }

    func setBackgroundJobsEnabled(_ enabled: Bool) {
        perform("set-background-jobs", arguments: [enabled ? "on" : "off"])
    }

    func runGuidedSetup(tier: String) {
        let normalized = tier.lowercased() == "max" ? "max" : "balanced"
        let command = "npx --yes @gotcos/glasses-server@latest --setup-transcription --transcription-tier \(normalized) --prepare-only"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"\(escaped)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
        notice = "\(normalized == "max" ? "Max" : "Balanced") setup opened in Terminal. When provisioning finishes, install or update the server if needed, then Apply that tier so Control can restart and verify it transactionally."
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
