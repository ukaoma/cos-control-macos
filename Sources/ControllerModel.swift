import AppKit
import AVFoundation
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
    @Published var meetingLibraryGuidance: String?
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

    // MARK: Speaker review (0.4.0)
    @Published var reviewableMeetings: [ReviewableMeeting] = []
    @Published var meetingsLoading = false
    @Published var openReview: SpeakerReview?
    /// The readable meeting beside the speaker rows. nil when the server is
    /// older than 6.21.28 or the fetch failed — the review still renders.
    @Published var openContent: MeetingContent?
    @Published var copyNote: String?
    /// Why the write-up is absent: "route_absent" (server too old) or an error
    /// string. nil when content loaded. Previously a 404 and a real failure both
    /// rendered as silence, with no way to tell the user to update the server.
    @Published var contentUnavailable: String?
    @Published var reviewLoading = false
    @Published var reviewError: String?
    @Published var voiceProfiles: [VoiceProfileOption] = []
    @Published var voiceDirectory: [VoiceDirectoryPerson] = []
    @Published var voiceDirectoryLoading = false
    @Published var voiceDirectoryError: String?
    @Published var voiceDirectoryRouteAvailable: Bool?
    @Published var voiceDirectoryGeneratedAt: String?
    @Published var voiceDirectoryMeetingsScanned = 0
    @Published var voiceDirectoryUnresolvedMeetings = 0
    @Published var voiceDirectoryUnresolvedSegments = 0
    @Published var voiceDirectoryTruncated = false
    /// Which voice row has its naming field open. One at a time: two open fields
    /// invite naming the wrong row.
    @Published var namingVoice: String?
    @Published var pendingCorrection: PendingCorrection?
    /// Scope the reviewer has chosen for the next rename. Defaults to this
    /// meeting — the whole point of 0.5.0.
    @Published var correctionScope: CorrectionScope = .thisMeeting
    /// Which voice's audio is playing, so one row at a time shows a stop control.
    @Published var playingVoice: String?
    /// Why playback could not happen — shown on the row rather than as a dialog,
    /// because "no longer held" is ordinary information after the retention
    /// window, not an error the user did anything to cause.
    /// Keyed so a failure prints under the row that caused it, not all of them.
    @Published var playbackNote: (key: String, voice: String, text: String)?
    /// Raw chunk indices this meeting still has audio for. Empty until asked, and
    /// empty forever for meetings recorded before retention existed.
    @Published var retainedAudioChunks: Set<Int> = []
    /// How long audio is kept, straight from the server rather than assumed.
    @Published var audioRetentionDays: Int?
    @Published var mergeInFlight = false
    /// The session the open review asked for. Held separately from `openReview`
    /// because a retry has to work when the review failed to load and there is
    /// no review object to read the id back out of.
    ///
    /// @Published because the view's route condition reads it. As a plain
    /// private var SwiftUI could not observe it, so the route could read a stale
    /// value and never re-render — a real defect independent of the sheet issue.
    @Published private var lastReviewSession: String?

    /// Whether the panel should show the review instead of the main content.
    /// Includes the error case so a failed load is visible in place rather than
    /// silently doing nothing when a meeting row is clicked.
    var reviewRouteActive: Bool {
        openReview != nil || reviewLoading || (reviewError != nil && lastReviewSession != nil)
    }

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
    private var speakerReviewTask: Task<Void, Never>?
    private var contextDetailTask: Task<Void, Never>?
    private var libraryDetailTask: Task<Void, Never>?
    private var claudeSessionDetailTask: Task<Void, Never>?
    private var librarySearchTask: Task<Void, Never>?
    private var memorySearchTask: Task<Void, Never>?
    private var threadSearchTask: Task<Void, Never>?
    private var sessionSearchTask: Task<Void, Never>?
    private var mediaPreviewTask: Task<Void, Never>?
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
        speakerReviewTask?.cancel()
        contextDetailTask?.cancel()
        libraryDetailTask?.cancel()
        claudeSessionDetailTask?.cancel()
        librarySearchTask?.cancel()
        memorySearchTask?.cancel()
        threadSearchTask?.cancel()
        sessionSearchTask?.cancel()
        mediaPreviewTask?.cancel()
        thumbnailTasks.values.forEach { $0.cancel() }
    }

    func refresh(quiet: Bool = false) async {
        if !quiet { busy = true }
        defer { if !quiet { busy = false } }
        do {
            let response = try await helper.run(["status"])
            status = ServerStatus(response.details)
            if !quiet { error = nil }
            await loadOrphans(quiet: true)
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
        mediaPreviewTask?.cancel()
        previewingMediaID = attachment.id
        mediaPreviewTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if previewingMediaID == attachment.id {
                    previewingMediaID = nil
                    mediaPreviewTask = nil
                }
            }
            do {
                let file = try await fetchMediaFile(attachment, variant: "phone", purpose: "preview")
                defer { try? FileManager.default.removeItem(at: file.url) }
                guard !Task.isCancelled, previewingMediaID == attachment.id else { return }
                guard let image = RecentMediaImageDecoder.decode(url: file.url, expectedBytes: file.bytes) else {
                    throw MediaFetchError.invalidResponse
                }
                selectedMediaPreview = SelectedMediaPreview(attachment: attachment, image: image)
            } catch {
                guard !Task.isCancelled, previewingMediaID == attachment.id else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func closeMediaPreview() {
        mediaPreviewTask?.cancel()
        mediaPreviewTask = nil
        previewingMediaID = nil
        selectedMediaPreview = nil
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
                if command == "reset-message-era" {
                    await refreshRecentMessages(quiet: true)
                }
                if let nestedStatus = response.details["status"]?.object {
                    status = ServerStatus(nestedStatus)
                } else if response.details["running"] != nil {
                    status = ServerStatus(response.details)
                }
                await refresh(quiet: true)
            } catch {
                if command == "set-operations-dir" {
                    self.meetingLibraryGuidance = error.localizedDescription
                } else {
                    self.error = error.localizedDescription
                }
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
        panel.title = "Meetings Library"
        panel.message = "Choose the folder you already use for meetings. Most people should choose "
            + "the folder that directly contains month folders such as 2026-08. If you organize meetings "
            + "into several named folders, choose their parent instead; each named folder only needs its "
            + "own meetings folder. Your names are entirely up to you. COS never moves or reorganizes files."
        panel.prompt = "Use as Meetings Library"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform("set-operations-dir", arguments: [url.path])
    }

    func selectContextFolder() {
        let panel = NSOpenPanel()
        panel.title = "COS Data — Memory and Threads"
        panel.message = "Choose your COS workspace, or its operations/scripts folder. This is separate from the agent Work Folder and Meetings Library. COS validates the local bridge before changing the server."
        panel.prompt = "Use for Memory and Threads"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform("set-context-dir", arguments: [url.path])
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

    func setMeetingPreviewEnabled(_ enabled: Bool) {
        perform("set-meeting-preview", arguments: [enabled ? "on" : "off"])
    }

    func setVideoUploadV2Enabled(_ enabled: Bool) {
        perform("set-video-upload-v2", arguments: [enabled ? "on" : "off"])
    }

    func clearStrandedVideoUploads() {
        perform("clear-stranded-video-uploads")
    }

    func resetMessageEra() {
        perform("reset-message-era")
    }

    func recoverOrphan(_ sessionId: String) {
        guard !sessionId.isEmpty, !busy, !orphanBusy else { return }
        orphanBusy = true
        Task {
            defer { orphanBusy = false }
            do {
                let response = try await helper.run(["meeting-orphan-recover", "--session", sessionId])
                notice = response.message
                await loadOrphans(quiet: true)
                await refresh(quiet: true)
            } catch {
                self.error = error.localizedDescription
                await loadOrphans(quiet: true)
            }
        }
    }

    func recoverAllOrphans() {
        perform("meeting-orphan-recover-all")
    }

    func saveStranded(_ sessionId: String) {
        guard !sessionId.isEmpty, !busy, !orphanBusy else { return }
        orphanBusy = true
        Task {
            defer { orphanBusy = false }
            do {
                let response = try await helper.run(["meeting-stranded-save", "--session", sessionId])
                notice = response.message
                await loadOrphans(quiet: true)
                await refresh(quiet: true)
            } catch {
                self.error = error.localizedDescription
                await loadOrphans(quiet: true)
            }
        }
    }

    func saveAllStranded() {
        guard !busy, !orphanBusy else { return }
        orphanBusy = true
        Task {
            defer { orphanBusy = false }
            do {
                let response = try await helper.run(["meeting-stranded-save-all"])
                notice = response.message
                await loadOrphans(quiet: true)
                await refresh(quiet: true)
            } catch {
                self.error = error.localizedDescription
                await loadOrphans(quiet: true)
            }
        }
    }

    func setIdleMetalHqEnabled(_ enabled: Bool) {
        perform("set-idle-metal-hq", arguments: [enabled ? "on" : "off"])
    }

    func setAdaptiveAudioCleanupEnabled(_ enabled: Bool) {
        perform("set-adaptive-audio-cleanup", arguments: [enabled ? "on" : "off"])
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
    // MARK: - Speaker review

    func loadReviewableMeetings() async {
        meetingsLoading = true
        defer { meetingsLoading = false }
        do {
            // Over-request: the helper drops rows without a sessionId, so asking for
                // 15 returned 10-12 depending on how much of the day was G2-captured.
                // Ask 30, show the first MEETING_LIST_VISIBLE survivors.
                let response = try await helper.run(["meetings", "--limit", "30"])
            reviewableMeetings = (response.details["meetings"]?.array ?? []).compactMap(ReviewableMeeting.init)
            // A row without a sessionId is filtered out by the helper, because the
            // review is keyed on the session. Say so rather than showing an empty
            // list that looks like "no meetings".
            let skipped = response.details["skipped"]?.int ?? 0
            if reviewableMeetings.isEmpty && skipped > 0 {
                reviewError = "\(skipped) recent meeting(s) predate speaker review. Update the server to review new ones."
            } else {
                reviewError = nil
            }
        } catch {
            reviewableMeetings = []
            reviewError = error.localizedDescription
        }
    }

    // MARK: Meeting library (Activity)

    @Published var libraryMeetings: [LibraryMeeting] = []
    @Published var libraryMonths: [String] = []
    @Published var libraryDays: [LibraryMeetingDay] = []
    @Published var libraryMonth = ControllerModel.currentMeetingMonth()
    @Published var libraryDay: String?
    @Published var libraryDomainFilter = "all"
    /// Shared across Meetings / Sessions / Memories / Threads lookup.
    @Published var searchRecency: SearchRecency = .newest
    @Published var libraryLoading = false
    @Published var libraryError: String?
    @Published var openLibraryRow: LibraryMeeting?
    @Published var libraryDetail: LibraryMeetingDetail?
    @Published var libraryDetailLoading = false
    @Published var libraryDetailError: String?
    @Published var libraryQuery = ""
    @Published var librarySearchHits: [LibrarySearchHit] = []
    @Published var librarySearching = false
    @Published var librarySearchError: String?
    @Published var librarySemanticAvailable = true
    @Published var librarySemanticReason: String?
    @Published var orphanCaptures: [OrphanCapture] = []
    @Published var strandedCaptures: [StrandedCapture] = []
    @Published var orphanBusy = false
    @Published var claudeSessions: [ClaudeSession] = []
    @Published var claudeSessionsEnabled = false
    @Published var claudeSessionsReason = ""
    @Published var claudeSessionsLoading = false
    @Published var claudeSessionsError: String?
    @Published var sessionClock: SessionClock = .updated
    @Published var sessionQuery = ""
    @Published var sessionSearchHits: [SessionSearchHit] = []
    @Published var sessionSearching = false
    @Published var sessionSearchError: String?
    @Published var sessionSemanticAvailable = true
    @Published var sessionSemanticReason: String?
    @Published var openClaudeRow: ClaudeSession?
    @Published var claudeSessionDetail: ClaudeSessionDetail?
    @Published var claudeSessionDetailLoading = false
    @Published var claudeSessionDetailError: String?
    private var libraryLoadID = UUID()
    private var librarySearchID = UUID()
    private var sessionSearchID = UUID()
    private var libraryDayAutoApplied = false

    var isLibraryQueryActive: Bool {
        libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    var visibleLibrarySearchHits: [LibrarySearchHit] {
        SearchRecency.sorted(
            librarySearchHits,
            recency: searchRecency,
            date: { $0.meeting.recencyDate },
            score: { $0.score }
        )
    }

    var visibleSessionSearchHits: [SessionSearchHit] {
        SearchRecency.sorted(
            sessionSearchHits,
            recency: searchRecency,
            date: { $0.session.updatedDate ?? $0.session.createdDate },
            score: { $0.score }
        )
    }

    var visibleMemorySearchHits: [ContextSearchHit] {
        SearchRecency.sorted(
            memorySearchHits,
            recency: searchRecency,
            date: { SearchRecency.parseStamp($0.record.createdAt) },
            score: { $0.score }
        )
    }

    var visibleThreadSearchHits: [ContextSearchHit] {
        SearchRecency.sorted(
            threadSearchHits,
            recency: searchRecency,
            date: { SearchRecency.parseStamp($0.record.createdAt) },
            score: { $0.score }
        )
    }

    func scheduleLibrarySearch() {
        librarySearchTask?.cancel()
        let trimmed = libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 2 {
            librarySearchHits = []
            librarySearchError = nil
            librarySearching = false
            librarySemanticReason = nil
            return
        }
        let id = UUID()
        librarySearchID = id
        librarySearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, self?.librarySearchID == id else { return }
            await self?.runLibrarySearch(trimmed, id: id)
        }
    }

    private func runLibrarySearch(_ query: String, id: UUID) async {
        librarySearching = true
        defer { if librarySearchID == id { librarySearching = false } }
        do {
            var args = ["meetings-library-search", "--query", query, "--limit", "20"]
            if libraryDomainFilter != "all" { args += ["--domain", libraryDomainFilter] }
            let response = try await helper.run(args)
            guard librarySearchID == id else { return }
            librarySearchHits = (response.details["hits"]?.array ?? []).compactMap(LibrarySearchHit.init)
            librarySemanticAvailable = response.details["semanticAvailable"]?.bool ?? false
            let reason = response.details["semanticReason"]?.string ?? ""
            librarySemanticReason = reason.isEmpty ? nil : reason
            librarySearchError = nil
        } catch is CancellationError {
            return
        } catch {
            guard librarySearchID == id else { return }
            librarySearchHits = []
            librarySearchError = error.localizedDescription
        }
    }

    var libraryRouteActive: Bool {
        openLibraryRow != nil || libraryDetail != nil || libraryDetailLoading || libraryDetailError != nil
    }

    var visibleLibraryMeetings: [LibraryMeeting] {
        libraryMeetings.filter { meeting in
            if let libraryDay, meeting.date != libraryDay { return false }
            if libraryDomainFilter != "all", meeting.domain != libraryDomainFilter { return false }
            return true
        }
    }

    var libraryDomainOptions: [String] {
        ["all"] + Array(Set(libraryMeetings.map(\.domain).filter { !$0.isEmpty })).sorted()
    }

    var librarySearchDomainOptions: [String] {
        let known = ["quilt", "sprocket_rocket", "hermit_crabs", "personal"]
        let present = libraryMeetings.map(\.domain).filter { !$0.isEmpty }
        return ["all"] + Array(Set(known + present)).sorted()
    }

    var recoverableOrphans: [OrphanCapture] {
        orphanCaptures.filter(\.recoverable)
    }

    func loadOrphans(quiet: Bool = true) async {
        do {
            let response = try await helper.run(["meeting-orphans"])
            orphanCaptures = (response.details["items"]?.array ?? []).compactMap(OrphanCapture.init)
            strandedCaptures = (response.details["stranded"]?.array ?? []).compactMap(StrandedCapture.init)
        } catch {
            if !quiet { self.error = error.localizedDescription }
            if status.unsavedCaptures == 0 {
                orphanCaptures = []
                strandedCaptures = []
            }
        }
    }

    func loadClaudeSessions() async {
        claudeSessionsLoading = true
        defer { claudeSessionsLoading = false }
        do {
            let response = try await helper.run(["claude-sessions"])
            claudeSessionsEnabled = response.details["enabled"]?.bool ?? false
            claudeSessionsReason = response.details["reason"]?.string ?? ""
            claudeSessions = (response.details["sessions"]?.array ?? []).compactMap(ClaudeSession.init)
            claudeSessionsError = nil
        } catch {
            claudeSessionsError = error.localizedDescription
        }
    }

    var isSessionQueryActive: Bool {
        sessionQuery.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    func scheduleSessionSearch() {
        sessionSearchTask?.cancel()
        let trimmed = sessionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 2 {
            sessionSearchHits = []
            sessionSearchError = nil
            sessionSearching = false
            sessionSemanticReason = nil
            return
        }
        sessionSearchHits = SessionSearchHit.keywordHits(query: trimmed, sessions: claudeSessions)
        sessionSearchError = nil
        let id = UUID()
        sessionSearchID = id
        sessionSearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, self?.sessionSearchID == id else { return }
            await self?.runSessionSearch(trimmed, id: id)
        }
    }

    private func mergeSessionHits(_ instant: [SessionSearchHit], _ remote: [SessionSearchHit]) -> [SessionSearchHit] {
        var byId: [String: SessionSearchHit] = [:]
        for hit in instant + remote {
            if let existing = byId[hit.id], existing.score >= hit.score { continue }
            byId[hit.id] = hit
        }
        return byId.values.sorted { $0.score > $1.score }
    }

    private func runSessionSearch(_ query: String, id: UUID) async {
        sessionSearching = sessionSearchHits.isEmpty
        defer { if sessionSearchID == id { sessionSearching = false } }
        do {
            let response = try await helper.run(
                ["claude-sessions-search", "--query", query, "--limit", "20"],
                timeout: 12
            )
            guard sessionSearchID == id else { return }
            let remote = (response.details["hits"]?.array ?? []).compactMap(SessionSearchHit.init)
            sessionSearchHits = mergeSessionHits(sessionSearchHits, remote)
            sessionSemanticAvailable = response.details["semanticAvailable"]?.bool ?? false
            let reason = response.details["semanticReason"]?.string ?? ""
            sessionSemanticReason = reason.isEmpty ? nil : reason
            sessionSearchError = nil
        } catch is CancellationError {
            return
        } catch {
            guard sessionSearchID == id else { return }
            if sessionSearchHits.isEmpty {
                sessionSearchError = error.localizedDescription
            }
        }
    }

    var claudeSessionRouteActive: Bool {
        openClaudeRow != nil || claudeSessionDetail != nil || claudeSessionDetailLoading || claudeSessionDetailError != nil
    }

    func openClaudeSession(_ session: ClaudeSession) {
        claudeSessionDetailTask?.cancel()
        openClaudeRow = session
        claudeSessionDetail = nil
        claudeSessionDetailError = nil
        copyNote = nil
        claudeSessionDetailTask = Task { [weak self] in
            await self?.fetchClaudeSessionDetail(session)
        }
    }

    private func fetchClaudeSessionDetail(_ session: ClaudeSession) async {
        claudeSessionDetailLoading = true
        defer {
            if openClaudeRow?.id == session.id { claudeSessionDetailLoading = false }
        }
        do {
            let response = try await helper.run([
                "claude-session-detail",
                "--session", session.sessionId,
                "--provider", session.provider,
            ])
            guard !Task.isCancelled, openClaudeRow?.id == session.id else { return }
            guard let detail = ClaudeSessionDetail(.object(response.details)) else {
                claudeSessionDetailError = "The helper returned a session this build cannot read."
                return
            }
            claudeSessionDetail = detail
        } catch {
            guard !Task.isCancelled, openClaudeRow?.id == session.id else { return }
            claudeSessionDetailError = error.localizedDescription
        }
    }

    func closeClaudeSession() {
        claudeSessionDetailTask?.cancel()
        claudeSessionDetailTask = nil
        claudeSessionDetailLoading = false
        openClaudeRow = nil
        claudeSessionDetail = nil
        claudeSessionDetailError = nil
        copyNote = nil
    }

    func copyClaudeSession() {
        let text = claudeSessionDetail?.copyText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { copyNote = "Nothing to copy"; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyNote = "Copied kickstart for another agent"
    }

    static func currentMeetingMonth(_ now: Date = Date()) -> String {
        let parts = Calendar.current.dateComponents([.year, .month], from: now)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    static func currentMeetingDay(_ now: Date = Date()) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func loadLibraryMeetings() async {
        let id = UUID()
        libraryLoadID = id
        libraryLoading = true
        defer { if libraryLoadID == id { libraryLoading = false } }
        do {
            let args = ["meetings-library", "--month", libraryMonth, "--limit", "200"]
            let response = try await helper.run(args)
            guard libraryLoadID == id else { return }
            libraryMeetings = (response.details["meetings"]?.array ?? []).compactMap(LibraryMeeting.init)
            let months = response.details["months"]?.array?.compactMap(\.string) ?? []
            libraryMonths = months.isEmpty
                ? Array(Set(libraryMeetings.map(\.month))).sorted().reversed()
                : months
            let days = response.details["days"]?.array?.compactMap(LibraryMeetingDay.init) ?? []
            if days.isEmpty {
                var counts: [String: Int] = [:]
                for meeting in libraryMeetings { counts[meeting.date, default: 0] += 1 }
                libraryDays = counts.keys.sorted().map { LibraryMeetingDay(date: $0, count: counts[$0] ?? 0) }
            } else {
                libraryDays = days
            }
            if !libraryDayAutoApplied, libraryMonth == Self.currentMeetingMonth() {
                let today = Self.currentMeetingDay()
                if libraryDays.contains(where: { $0.date == today && $0.count > 0 }) {
                    libraryDay = today
                }
                libraryDayAutoApplied = true
            }
            libraryError = nil
        } catch {
            guard libraryLoadID == id else { return }
            libraryMeetings = []
            libraryError = error.localizedDescription
        }
    }

    func selectLibraryDay(_ day: String?) {
        libraryDay = day
        libraryDayAutoApplied = true
    }

    func shiftLibraryMonth(_ delta: Int) {
        guard let date = MeetingMonth.parse(libraryMonth),
              let next = Calendar.current.date(byAdding: .month, value: delta, to: date) else { return }
        libraryMonth = Self.currentMeetingMonth(next)
        libraryDay = nil
        Task { await loadLibraryMeetings() }
    }

    func openLibraryMeeting(_ meeting: LibraryMeeting) {
        libraryDetailTask?.cancel()
        openLibraryRow = meeting
        libraryDetail = nil
        libraryDetailError = nil
        copyNote = nil
        libraryDetailTask = Task { [weak self] in
            await self?.fetchLibraryDetail(meeting)
        }
    }

    private func fetchLibraryDetail(_ meeting: LibraryMeeting) async {
        libraryDetailLoading = true
        defer {
            if openLibraryRow?.id == meeting.id { libraryDetailLoading = false }
        }
        do {
            let response = try await helper.run([
                "meeting-library-detail",
                "--domain", meeting.domain,
                "--month", meeting.month,
                "--filename", meeting.filename,
            ])
            guard !Task.isCancelled, openLibraryRow?.id == meeting.id else { return }
            guard let detail = LibraryMeetingDetail(.object(response.details)) else {
                libraryDetailError = "The server returned a meeting this build cannot read."
                return
            }
            libraryDetail = detail
        } catch {
            guard !Task.isCancelled, openLibraryRow?.id == meeting.id else { return }
            libraryDetailError = error.localizedDescription
        }
    }

    func closeLibraryDetail() {
        libraryDetailTask?.cancel()
        libraryDetailTask = nil
        libraryDetailLoading = false
        openLibraryRow = nil
        libraryDetail = nil
        libraryDetailError = nil
        copyNote = nil
    }

    var canRevealLibraryMeeting: Bool {
        guard let row = openLibraryRow,
              let ops = status.operationsDirectory, !ops.isEmpty else { return false }
        return row.librarySource == "cos_operations"
            || (row.librarySource.isEmpty && row.domain != "library" && !row.domain.isEmpty)
    }

    func copyLibraryMeeting(kind: LibraryCopyKind) {
        guard let row = openLibraryRow else { return }
        let detail = libraryDetail
        let body: String
        switch kind {
        case .summary:
            body = detail?.summary ?? ""
        case .transcript:
            body = detail?.transcript ?? ""
        case .context:
            let source = detail?.sourceContent.isEmpty == false ? detail!.sourceContent
                : (detail?.transcript.isEmpty == false ? detail!.transcript : detail?.summary ?? row.title)
            body = """
            Meeting \(row.title)\(row.date.isEmpty ? "" : " (\(row.date)\(row.domain.isEmpty ? "" : ", \(row.domain)"))")

            \"\"\"
            \(source)
            \"\"\"
            """
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { copyNote = "Nothing to copy"; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(kind == .context ? body : trimmed, forType: .string)
        switch kind {
        case .summary: copyNote = "Copied summary"
        case .transcript: copyNote = "Copied transcript"
        case .context: copyNote = "Copied as grounded context"
        }
    }

    func revealLibraryMeeting() {
        guard let row = openLibraryRow,
              let ops = status.operationsDirectory, !ops.isEmpty,
              row.librarySource == "cos_operations" || (row.librarySource.isEmpty && row.domain != "library")
        else { return }
        let url = URL(fileURLWithPath: ops)
            .appendingPathComponent(row.domain)
            .appendingPathComponent("meetings")
            .appendingPathComponent(row.month)
            .appendingPathComponent(row.filename)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    enum LibraryCopyKind {
        case summary, transcript, context
    }

    // ── Memory and Threads review ───────────────────────────
    //
    // Miles: "It's mostly just exposing the read-only layer that we see from the
    // glasses... The expected action was going to be something more similar to what
    // we see with review speakers."
    //
    // So this is the SPEAKERS shape, which the first cut got wrong: a list card in
    // the main panel, and clicking a row routes the whole panel to a detail view.
    // The first version put two buttons in the controls row and mounted the pane
    // inside `if reviewRouteActive` — a flag only the speaker flow ever sets — so a
    // click updated state that nothing was rendering. Nothing happened, visibly.
    //
    // "Pick up from here" is COPY and REVEAL, not send. Control has no path to the
    // agent (no /api/query call exists in it), and arming a reference for the next
    // prompt would need a write route the amendment design does not have.

    @Published var memoryRecords: [ContextRecord] = []
    @Published var threadRecords: [ContextRecord] = []
    @Published var memoryRecordsLoading = false
    @Published var threadRecordsLoading = false
    @Published var memoryRecordsError: String?
    @Published var threadRecordsError: String?
    @Published var memoryHeadline = ""
    @Published var threadHeadline = ""
    @Published var memoryQuery = ""
    @Published var threadQuery = ""
    @Published var memorySearchHits: [ContextSearchHit] = []
    @Published var threadSearchHits: [ContextSearchHit] = []
    @Published var memorySearching = false
    @Published var threadSearching = false
    @Published var memorySearchError: String?
    @Published var threadSearchError: String?
    @Published var memorySemanticAvailable = true
    @Published var threadSemanticAvailable = false
    @Published var memorySemanticReason: String?
    @Published var threadSemanticReason: String?
    private var memorySearchID = UUID()
    private var threadSearchID = UUID()

    /// The open record, its kind, and the load/error states that make a click always
    /// produce something on screen — including a failure.
    @Published var contextDetail: ContextRecord?
    @Published var contextDetailKind: String?
    @Published var contextDetailLoading = false
    @Published var contextDetailError: String?

    /// Route the panel to the detail view.
    ///
    /// Mirrors `reviewRouteActive`, error case included, so a failed load is visible
    /// in place instead of silently doing nothing when a row is clicked.
    var contextRouteActive: Bool {
        contextDetail != nil || contextDetailLoading || contextDetailError != nil
    }

    func loadContextRecords(kind: String) async {
        let isThread = kind == "thread"
        if isThread { threadRecordsLoading = true } else { memoryRecordsLoading = true }
        defer { if isThread { threadRecordsLoading = false } else { memoryRecordsLoading = false } }
        do {
            let response = try await helper.run([isThread ? "context-threads" : "context-memories", "--limit", "50"])
            let rows = response.details[isThread ? "threads" : "memories"]?.array?.compactMap { $0.object } ?? []
            let records = rows.map { isThread ? ContextRecord.thread($0) : ContextRecord.memory($0) }
            // `shown` is this PAGE; `total`/`activeCount` cover the whole store. A live
            // probe printed "4 threads" beside "11 active", so both are named.
            let shown = response.details["shown"]?.int ?? records.count
            if isThread {
                threadRecords = records
                let active = response.details["activeCount"]?.int ?? 0
                threadHeadline = "\(shown) shown · \(active) active"
                threadRecordsError = records.isEmpty
                    ? "No threads yet. Threads are markdown files in threads/, or tracked automatically with a bridge."
                    : nil
            } else {
                memoryRecords = records
                let total = response.details["total"]?.int ?? shown
                memoryHeadline = total > shown ? "\(shown) of \(total)" : "\(shown) stored"
                memoryRecordsError = records.isEmpty
                    ? "No memories yet. Drop markdown into memory/, or configure a bridge for the vector store."
                    : nil
            }
        } catch {
            if isThread { threadRecordsError = error.localizedDescription }
            else { memoryRecordsError = error.localizedDescription }
        }
    }

    var isMemoryQueryActive: Bool {
        memoryQuery.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    var isThreadQueryActive: Bool {
        threadQuery.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    func scheduleContextSearch(kind: String) {
        let isThread = kind == "thread"
        if isThread { threadSearchTask?.cancel() } else { memorySearchTask?.cancel() }
        let trimmed = (isThread ? threadQuery : memoryQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 2 {
            if isThread {
                threadSearchHits = []
                threadSearchError = nil
                threadSearching = false
                threadSemanticReason = nil
            } else {
                memorySearchHits = []
                memorySearchError = nil
                memorySearching = false
                memorySemanticReason = nil
            }
            return
        }
        let id = UUID()
        if isThread { threadSearchID = id } else { memorySearchID = id }
        let task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            if isThread {
                guard self?.threadSearchID == id else { return }
            } else {
                guard self?.memorySearchID == id else { return }
            }
            await self?.runContextSearch(kind: kind, query: trimmed, id: id)
        }
        if isThread { threadSearchTask = task } else { memorySearchTask = task }
    }

    private func runContextSearch(kind: String, query: String, id: UUID) async {
        let isThread = kind == "thread"
        if isThread { threadSearching = true } else { memorySearching = true }
        defer {
            if isThread {
                if threadSearchID == id { threadSearching = false }
            } else if memorySearchID == id {
                memorySearching = false
            }
        }
        do {
            let command = isThread ? "context-threads-search" : "context-memories-search"
            let response = try await helper.run([command, "--query", query, "--limit", "20"])
            if isThread {
                guard threadSearchID == id else { return }
                threadSearchHits = (response.details["hits"]?.array ?? []).compactMap { ContextSearchHit(kind: "thread", $0) }
                threadSemanticAvailable = response.details["semanticAvailable"]?.bool ?? false
                let reason = response.details["semanticReason"]?.string ?? ""
                threadSemanticReason = reason.isEmpty ? nil : reason
                threadSearchError = nil
            } else {
                guard memorySearchID == id else { return }
                memorySearchHits = (response.details["hits"]?.array ?? []).compactMap { ContextSearchHit(kind: "memory", $0) }
                memorySemanticAvailable = response.details["semanticAvailable"]?.bool ?? false
                let reason = response.details["semanticReason"]?.string ?? ""
                memorySemanticReason = reason.isEmpty ? nil : reason
                memorySearchError = nil
            }
        } catch is CancellationError {
            return
        } catch {
            if isThread {
                guard threadSearchID == id else { return }
                threadSearchError = error.localizedDescription
            } else {
                guard memorySearchID == id else { return }
                memorySearchError = error.localizedDescription
            }
        }
    }

    /// Open one record. Routes immediately on the LIST row so the click always shows
    /// something, then replaces it with full detail when that arrives.
    func openContextRecord(_ record: ContextRecord, kind: String) {
        contextDetailTask?.cancel()
        contextDetailKind = kind
        contextDetail = record
        contextDetailError = nil
        copyNote = nil
        contextDetailTask = Task { [weak self] in
            await self?.fetchContextDetail(record: record, kind: kind)
        }
    }

    private func fetchContextDetail(record: ContextRecord, kind: String) async {
        contextDetailLoading = true
        defer {
            if contextDetail?.id == record.id, contextDetailKind == kind {
                contextDetailLoading = false
            }
        }
        do {
            let response = try await helper.run([
                kind == "thread" ? "context-threads" : "context-memories", "--id", record.id,
            ])
            guard !Task.isCancelled,
                  contextDetail?.id == record.id,
                  contextDetailKind == kind else { return }
            let raw = response.details.reduce(into: [String: JSONValue]()) { $0[$1.key] = $1.value }
            let full = kind == "thread" ? ContextRecord.thread(raw) : ContextRecord.memory(raw)
            // Keep the row when detail is thinner, so the header never blanks mid-read.
            if !full.id.isEmpty && !full.title.isEmpty { contextDetail = full }
        } catch {
            guard !Task.isCancelled,
                  contextDetail?.id == record.id,
                  contextDetailKind == kind else { return }
            // The row is already on screen; a detail failure annotates rather than
            // clearing it, which is why the route stays active.
            contextDetailError = error.localizedDescription
        }
    }

    func closeContextDetail() {
        contextDetailTask?.cancel()
        contextDetailTask = nil
        contextDetailLoading = false
        contextDetail = nil
        contextDetailKind = nil
        contextDetailError = nil
        copyNote = nil
    }

    /// Copy the record as grounded context, ready to paste into a prompt.
    ///
    /// Quoted and labelled with its id — the same data-not-instructions contract the
    /// glasses use when they attach a reference.
    func copyContextRecord(_ record: ContextRecord) {
        let label = contextDetailKind == "thread" ? "Thread" : "Memory"
        let text = """
        \(label) \(record.id)\(record.subtitle.isEmpty ? "" : " (\(record.subtitle))")

        \"\"\"
        \(record.body.isEmpty ? record.title : record.body)
        \"\"\"
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyNote = "Copied as grounded context"
    }

    /// Reveal the file behind a file-tier record. Absent for a vector-store record.
    func revealContextRecord(_ record: ContextRecord) {
        guard let path = record.filePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openSpeakerReview(_ meeting: ReviewableMeeting) {
        openSpeakerReview(sessionId: meeting.sessionId)
    }

    func openSpeakerReview(sessionId: String) {
        speakerReviewTask?.cancel()
        stopPlayback()
        playbackNote = nil
        correctionScope = .thisMeeting
        namingVoice = nil
        pendingCorrection = nil
        openReview = nil
        lastReviewSession = sessionId
        speakerReviewTask = Task { [weak self] in
            await self?.fetchReview(sessionId: sessionId)
        }
    }

    /// Load (or reload) one meeting's review. Keyed on the session id alone so a
    /// post-merge refresh does not need to reconstruct a list row it never had.
    private func fetchReview(sessionId: String) async {
        reviewLoading = true
        reviewError = nil
        // A relabel refetches; the old confirmation would otherwise keep asserting
        // a clipboard that no longer matches the panel.
        copyNote = nil
        contentUnavailable = nil
        defer {
            if lastReviewSession == sessionId { reviewLoading = false }
        }
        do {
            let response = try await helper.run(["meeting-speakers", "--session", sessionId])
            guard !Task.isCancelled, lastReviewSession == sessionId else { return }
            guard let review = SpeakerReview(response.details["review"]) else {
                reviewError = "The server returned a review this build cannot read."
                return
            }
            openReview = review
            if voiceProfiles.isEmpty { await loadVoiceProfiles() }
            guard !Task.isCancelled, lastReviewSession == sessionId else { return }
            await loadRetainedAudio(sessionId: sessionId)
            guard !Task.isCancelled, lastReviewSession == sessionId else { return }
            // Non-fatal on purpose: the review is the primary answer, and an
            // older server has no /content route. A failure here must not blank
            // the speaker rows that already loaded.
            await loadMeetingContent(sessionId: sessionId)
        } catch {
            guard !Task.isCancelled, lastReviewSession == sessionId else { return }
            reviewError = error.localizedDescription
        }
    }

    private func loadMeetingContent(sessionId: String) async {
        do {
            let response = try await helper.run(["meeting-content", "--session", sessionId])
            guard !Task.isCancelled, lastReviewSession == sessionId else { return }
            if let reason = response.details["unavailable"]?.string {
                openContent = nil
                contentUnavailable = reason
                return
            }
            openContent = MeetingContent(response.details["content"])
            contentUnavailable = openContent == nil ? "error" : nil
        } catch {
            guard !Task.isCancelled, lastReviewSession == sessionId else { return }
            openContent = nil
            contentUnavailable = "error"
        }
    }

    /// Put one of the server-built forms on the clipboard.
    func copyMeeting(full: Bool) {
        guard let c = openContent else { return }
        let text = full ? c.clipboardFull : c.clipboardSummary
        guard !text.isEmpty else { copyNote = "Nothing to copy"; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let kb = max(1, (full ? c.fullChars : c.summaryChars) / 1024)
        copyNote = full ? "Copied full meeting (\(kb) KB)" : "Copied summary (\(kb) KB)"
    }

    func retryOpenReview() {
        guard let session = lastReviewSession else { return }
        speakerReviewTask?.cancel()
        speakerReviewTask = Task { [weak self] in await self?.fetchReview(sessionId: session) }
    }

    func closeSpeakerReview() {
        speakerReviewTask?.cancel()
        speakerReviewTask = nil
        reviewLoading = false
        // Audio kept playing after the panel closed, and a stale note followed the
        // user into the next meeting's rows.
        stopPlayback()
        playbackNote = nil
        retainedAudioChunks = []
        audioRetentionDays = nil
        // Scope is per-correction, not per-launch: leaving it on "Every meeting"
        // is the irreversible global fold this release exists to prevent.
        correctionScope = .thisMeeting
        openReview = nil
        namingVoice = nil
        pendingCorrection = nil
        reviewError = nil
        lastReviewSession = nil
        openContent = nil
        copyNote = nil
        contentUnavailable = nil
    }

    func loadVoiceProfiles() async {
        do {
            let response = try await helper.run(["voice-profiles"])
            voiceProfiles = (response.details["profiles"]?.array ?? []).compactMap(VoiceProfileOption.init)
        } catch {
            voiceProfiles = []
        }
    }

    /// Load the all-voices directory without destroying last-good rows on a
    /// transient server/token failure. An older server returns its lightweight
    /// enrolled-profile list with an explicit route-absent state; that is useful
    /// training coverage, but it is never presented as meeting evidence.
    func loadVoiceDirectory(refresh: Bool = false) async {
        guard !voiceDirectoryLoading else { return }
        voiceDirectoryLoading = true
        voiceDirectoryError = nil
        defer { voiceDirectoryLoading = false }
        do {
            var args = ["voice-directory"]
            if refresh { args.append("--refresh") }
            let response = try await helper.run(args)
            let state = response.details["state"]?.string ?? "ready"
            let people = (response.details["profiles"]?.array ?? []).compactMap(VoiceDirectoryPerson.init)
            voiceDirectory = people
            voiceDirectoryRouteAvailable = state != "route_absent"
            voiceDirectoryGeneratedAt = response.details["generatedAt"]?.string
            voiceDirectoryMeetingsScanned = response.details["meetingsScanned"]?.int ?? 0
            voiceDirectoryUnresolvedMeetings = response.details["unresolvedMeetings"]?.int ?? 0
            voiceDirectoryUnresolvedSegments = response.details["unresolvedSegments"]?.int ?? 0
            voiceDirectoryTruncated = response.details["truncated"]?.bool ?? false
            if state == "route_absent" {
                voiceDirectoryError = "Update the COS server to add cross-meeting voice history. Training sample counts are still available."
            } else if people.isEmpty {
                voiceDirectoryError = "No voice profiles are enrolled yet. Enroll a voice before cross-meeting history can appear."
            }
        } catch {
            // Preserve last-good rows. Empty plus an error means unavailable;
            // non-empty plus an error means stale-but-readable.
            voiceDirectoryError = error.localizedDescription
        }
    }

    /// Ask the server what a correction WOULD do. Never applies it — the returned
    /// preview is what the confirmation is shown against, so the number the user
    /// agrees to is the number the server acted on.
    ///
    /// `scope` decides which endpoint answers. Until 0.5.0 only the global merge
    /// existed, so every rename rewrote every meeting; per-meeting is now the
    /// default and the global fold is an explicit opt-in.
    /// `isNameAssignment` marks the case where the row was never attributed to
    /// anyone. It changes no behaviour — only what the confirm card is allowed
    /// to say, so a click that labels an unverified cluster says so first.
    func previewRename(from: String, to: String, scope: CorrectionScope, isNameAssignment: Bool = false) {
        guard from != to else { return }
        guard let review = openReview, review.mutable else {
            reviewError = "This meeting comes from a read-only library. New COS meetings remain editable."
            return
        }
        let session = review.sessionId
        mergeInFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer { mergeInFlight = false }
            do {
                let args: [String] = scope == .thisMeeting
                    ? ["meeting-relabel", "--session", session, "--record-id", review.recordId, "--from", from, "--to", to]
                    : ["voice-merge", "--into", to, "--from", from]
                let response = try await helper.run(args)
                pendingCorrection = Self.correction(
                    from: from, to: to, scope: scope, response: response,
                    isNameAssignment: isNameAssignment
                )
                namingVoice = nil
                reviewError = nil
            } catch {
                // Never fail silently: a click that does nothing is worse than an
                // error, because the user cannot tell it was received.
                reviewError = "Could not check that name: \(error.localizedDescription)"
                pendingCorrection = nil
            }
        }
    }

    /// Vouch for a label the display floor demoted.
    ///
    /// No preview step, unlike rename and de-attribution. Those rewrite files;
    /// this rewrites nothing — the sidecar already carries the label, and the
    /// confirmation only records that a human stands behind it. A confirm
    /// dialog for a no-op edit trains people to click through the ones that
    /// matter.
    func confirmVoice(_ label: String) {
        guard let review = openReview, review.mutable else {
            reviewError = "This meeting comes from a read-only library. New COS meetings remain editable."
            return
        }
        let session = review.sessionId
        mergeInFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer { mergeInFlight = false }
            do {
                _ = try await helper.run(["meeting-confirm", "--session", session, "--record-id", review.recordId, "--label", label])
                reviewError = nil
                // Re-fetch so the row re-renders as asserted from the SERVER's
                // view rather than a local guess about what the confirmation did.
                await fetchReview(sessionId: session)
                await loadVoiceDirectory(refresh: true)
            } catch {
                reviewError = "Could not confirm that name: \(error.localizedDescription)"
            }
        }
    }

    /// Ask what removing a false attribution would do.
    ///
    /// Always per-meeting: "this person was not in THIS room" says nothing about
    /// any other meeting, so there is deliberately no global variant.
    func previewDeattribution(from: String) {
        guard let review = openReview, review.mutable else {
            reviewError = "This meeting comes from a read-only library. New COS meetings remain editable."
            return
        }
        let session = review.sessionId
        mergeInFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer { mergeInFlight = false }
            do {
                let response = try await helper.run([
                    "meeting-deattribute", "--session", session, "--record-id", review.recordId, "--from", from,
                ])
                pendingCorrection = Self.correction(
                    from: from, to: nil, scope: .thisMeeting, response: response
                )
                namingVoice = nil
                reviewError = nil
            } catch {
                reviewError = "Could not check that: \(error.localizedDescription)"
                pendingCorrection = nil
            }
        }
    }

    /// Build the preview from whichever endpoint answered.
    ///
    /// The two shapes differ — the per-meeting routes return surfaces/training
    /// counts, the global merge returns a similarity report — so this is where
    /// they are reconciled into one thing the view can render.
    private static func correction(
        from: String,
        to: String?,
        scope: CorrectionScope,
        response: HelperResponse,
        isNameAssignment: Bool = false
    ) -> PendingCorrection {
        let state = response.details["state"]?.string ?? ""
        let result = response.details["result"]?.object
        let refused = state == "refused" || state == "declined"
        let pendingEarlier = state == "pending_correction"
        let training = result?["training"]?.object

        let serverMessage = result?["message"]?.string
            ?? response.details["message"]?.string
            ?? ""
        let message: String
        if pendingEarlier {
            message = "An earlier correction on this meeting never finished, so its files may be part-written. Re-open it before trying again."
        } else if refused {
            message = serverMessage.isEmpty
                ? "The server declined this, so nothing was applied."
                : serverMessage
        } else if !serverMessage.isEmpty {
            message = serverMessage
        } else if to == nil {
            message = "Removes \(from) from this meeting."
        } else {
            message = scope == .thisMeeting
                ? "Renames \(from) to \(to ?? "") in this meeting only."
                : "Folds \(from) into \(to ?? "") across every meeting. This cannot be undone here."
        }

        return PendingCorrection(
            from: from,
            to: to,
            scope: scope,
            message: message,
            surfaces: CorrectionSurfaces(response.details["result"]?.object?["surfaces"]),
            similarity: result?["similarity"]?.object?[from]?.double,
            refused: refused || pendingEarlier,
            forceable: pendingEarlier,
            proseStale: result?["proseStale"]?.bool ?? false,
            isNameAssignment: isNameAssignment,
            wouldRetract: training?["wouldRetract"]?.int ?? 0,
            untraceable: training?["untraceable"]?.int ?? 0
        )
    }

    /// Retry a correction the server refused because an EARLIER one never
    /// finished, passing --force.
    ///
    /// Without this the 409 was a permanent dead end: nothing in the panel ever
    /// passed --force, no route closes a stalled intent, and the message told the
    /// user to "re-open the meeting", which touches no server state. The only
    /// exit was a terminal.
    func forceCorrection(_ correction: PendingCorrection) {
        confirmCorrection(correction, force: true)
    }

    func confirmCorrection(_ correction: PendingCorrection, force: Bool = false) {
        // A refusal that is only a stalled predecessor CAN be forced; a genuine
        // decline cannot.
        guard !correction.refused || force else { pendingCorrection = nil; return }
        guard let review = openReview, review.mutable else {
            reviewError = "This meeting comes from a read-only library. New COS meetings remain editable."
            return
        }
        let session = review.sessionId
        mergeInFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer { mergeInFlight = false }
            do {
                var args: [String]
                if correction.isDeattribution {
                    args = ["meeting-deattribute", "--session", session, "--record-id", review.recordId, "--from", correction.from, "--confirm"]
                } else if correction.scope == .thisMeeting {
                    args = ["meeting-relabel", "--session", session, "--record-id", review.recordId,
                            "--from", correction.from, "--to", correction.to ?? "", "--confirm"]
                } else {
                    args = ["voice-merge", "--into", correction.to ?? "", "--from", correction.from, "--confirm"]
                }
                if force { args.append("--force") }
                let response = try await helper.run(args)
                // READ the outcome. The helper deliberately does not throw on
                // 400/409/422 — it reports them as a state — so discarding the
                // response reported "Removed X from this meeting" for a server
                // that refused and changed nothing. Same defect 0.4.2 fixed one
                // layer down, reintroduced here.
                let state = response.details["state"]?.string ?? ""
                guard state == "applied" else {
                    let detail = response.details["result"]?.object?["message"]?.string
                        ?? response.details["message"]?.string
                    switch state {
                    case "route_missing":
                        reviewError = "This needs glasses-server 6.21.18 or newer — use Update Server."
                    case "pending_correction":
                        reviewError = detail ?? "An earlier correction on this meeting never finished."
                    default:
                        reviewError = detail ?? "The server did not apply that (\(state))."
                    }
                    // The card STAYS so the user can retry or cancel deliberately.
                    return
                }
                notice = correction.isDeattribution
                    ? "Removed \(correction.from) from this meeting"
                    : (correction.scope == .thisMeeting
                        ? "\(correction.from) is now \(correction.to ?? "") in this meeting"
                        : "Saved — \(correction.from) is now \(correction.to ?? "") everywhere")
                pendingCorrection = nil
                correctionScope = .thisMeeting
                await loadVoiceProfiles()
                // The review is now stale — a label may have changed or gone, so
                // re-read it rather than leave a row describing the old state.
                await fetchReview(sessionId: session)
                await loadVoiceDirectory(refresh: true)
            } catch {
                reviewError = error.localizedDescription
                pendingCorrection = nil
            }
        }
    }

    /// Which segments of this meeting can actually be played.
    ///
    /// Asked up front so a play button appears only where it will work. Before
    /// this, every row offered playback and 92% of clicks failed — the affordance
    /// was where the data was not.
    private func loadRetainedAudio(sessionId: String) async {
        guard lastReviewSession == sessionId else { return }
        retainedAudioChunks = []
        audioRetentionDays = nil
        do {
            let response = try await helper.run(["review-audio-list", "--session", sessionId])
            guard !Task.isCancelled, lastReviewSession == sessionId else { return }
            let chunks = (response.details["chunks"]?.array ?? []).compactMap { $0.int }
            retainedAudioChunks = Set(chunks)
            audioRetentionDays = response.details["retentionDays"]?.int
        } catch {
            guard !Task.isCancelled, lastReviewSession == sessionId else { return }
            // An older server has no such route. Silence is right here: the
            // buttons simply do not appear, rather than an error for something
            // the user did not ask for.
            retainedAudioChunks = []
        }
    }

    // MARK: - Review playback (0.5.0)

    /// Held so playback is not garbage-collected mid-sound, and so a second click
    /// can stop the first. AVAudioPlayer stops the moment its last reference
    /// drops, which makes a local variable silently play nothing.
    private var audioPlayer: AVAudioPlayer?
    private var playbackTask: Task<Void, Never>?
    private var playbackRequestID: UUID?

    /// Play THIS line's audio, from the meeting under review.
    ///
    /// Miles: "profile playback is for the stored audio for the chunk we're
    /// training on." Hearing the actual segment is what settles an identity
    /// question — a stored profile sample answers a different, weaker question,
    /// and for 71 of 77 profiles no such sample exists, because train-g2 deletes
    /// the audio it enrolls from.
    func playPhrase(_ phrase: SpeakerPhrase, voice: String) {
        guard let session = openReview?.sessionId, let index = phrase.chunkIndex else { return }
        play(key: "\(voice)#\(index)", voice: voice,
             args: ["review-audio", "--session", session, "--chunk", String(index)],
             missing: "That segment's audio is no longer held.")
    }

    /// Whether this line can be played: the server must still hold its chunk.
    func canPlay(_ phrase: SpeakerPhrase) -> Bool {
        guard let index = phrase.chunkIndex else { return false }
        return retainedAudioChunks.contains(index)
    }

    func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        playbackRequestID = nil
        audioPlayer?.stop()
        audioPlayer = nil
        playingVoice = nil
    }

    private func play(key: String, voice: String, args: [String], missing: String) {
        // A second click on the row that is already playing means stop.
        if playingVoice == key { stopPlayback(); return }
        stopPlayback()
        playbackNote = nil
        playingVoice = key
        let requestID = UUID()
        playbackRequestID = requestID
        playbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await helper.run(args)
                let state = response.details["state"]?.string ?? ""
                guard !Task.isCancelled,
                      self.playbackRequestID == requestID,
                      self.playingVoice == key else {
                    if state == "ready", let path = response.details["path"]?.string {
                        try? FileManager.default.removeItem(atPath: path)
                    }
                    return
                }
                guard state == "ready", let path = response.details["path"]?.string else {
                    // `expired` is the ordinary outcome once retention has passed;
                    // `route_missing` means the server predates this panel and must
                    // say so rather than claim the audio is gone.
                    let text: String
                    switch state {
                    case "expired": text = missing
                    case "route_missing": text = "This needs glasses-server 6.21.18 or newer — use Update Server."
                    default: text = "Audio unavailable (\(state))."
                    }
                    playbackNote = (key: key, voice: voice, text: text)
                    playingVoice = nil
                    playbackTask = nil
                    playbackRequestID = nil
                    return
                }
                let url = URL(fileURLWithPath: path)
                let player = try AVAudioPlayer(contentsOf: url)
                guard !Task.isCancelled,
                      self.playbackRequestID == requestID,
                      self.playingVoice == key else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                audioPlayer = player
                player.play()
                let playbackMode = response.details["playbackMode"]?.string
                let playbackBypass = response.details["playbackBypass"]?.string
                if playbackBypass == "live_recording" {
                    playbackNote = (key: key, voice: voice, text: "Played raw to protect the active meeting.")
                } else if playbackBypass == "cleanup_busy" {
                    playbackNote = (key: key, voice: voice, text: "Played raw because another cleanup was already running.")
                } else if playbackMode == "raw", status.adaptiveAudioCleanupEnabled == true {
                    playbackNote = (key: key, voice: voice, text: "Adaptive cleanup fell back safely to raw audio.")
                }
                // Clear the playing state when the sound ends. Polling the player
                // rather than using its delegate keeps this off the main-actor
                // delegate dance for what is a two-second clip.
                let duration = player.duration
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(0.2, duration) * 1_000_000_000))
                    guard let self,
                          self.playbackRequestID == requestID,
                          self.playingVoice == key else { return }
                    self.playingVoice = nil
                    self.audioPlayer = nil
                    self.playbackRequestID = nil
                }
                // The helper wrote this into its transfer directory; it is ours to
                // remove once loaded into the player.
                try? FileManager.default.removeItem(at: url)
                playbackTask = nil
            } catch {
                guard !Task.isCancelled,
                      self.playbackRequestID == requestID,
                      self.playingVoice == key else { return }
                playbackNote = (key: key, voice: voice, text: "Could not play that: \(error.localizedDescription)")
                playingVoice = nil
                playbackTask = nil
                playbackRequestID = nil
            }
        }
    }

    func cancelCorrection() {
        pendingCorrection = nil
        correctionScope = .thisMeeting
    }
}
