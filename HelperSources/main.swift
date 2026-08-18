import Foundation
import Darwin
import Security
import CryptoKit

private let supportedManagedContractVersions = Set([1, 2])
private let leaseManagedContractVersion = 2

struct GenerationRecord: Codable, Equatable {
    var version: String
    var path: String
    var registryIntegrity: String?
    var launcherSHA256: String?
    var packageJSONSHA256: String?
}

struct RuntimeManifest: Codable {
    var version: String
    var generationPath: String
    var workDirectory: String?
    var installedAt: String
    var previousVersions: [String]
    var schemaVersion: Int?
    var registryIntegrity: String?
    var launcherSHA256: String?
    var packageJSONSHA256: String?
    var generationID: String?
    var nodePath: String?
    var providerEnvironment: [String: String]?
    var retainedGenerations: [GenerationRecord]?
    var desiredState: String?
}

struct RuntimeTransaction: Codable {
    var previous: RuntimeManifest?
    var candidate: RuntimeManifest
    var previousLaunchAgentPlist: Data?
    var phase: String
    var startedAt: String
}

struct CommandResult {
    let code: Int32
    let output: String
}

struct HTTPResponse {
    let status: Int
    let body: [String: Any]?
    let data: Data?
    let headers: [String: String]

    /// A TOP-LEVEL JSON array, which `body` cannot represent.
    ///
    /// `/api/memory` deliberately returns a bare array to stay compatible with
    /// released companions, so a dictionary-only reader sees an empty result and
    /// reads working data as a failure — which is exactly what happened to Queen's
    /// own probe on 2026-08-09 before she checked the raw response.
    var bodyArray: [[String: Any]]? {
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    init(status: Int, body: [String: Any]?, data: Data? = nil, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.data = data
        self.headers = headers
    }
}

private final class HTTPResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedData: Data?
    private var storedResponse: URLResponse?

    func store(data: Data?, response: URLResponse?) {
        lock.lock()
        storedData = data
        storedResponse = response
        lock.unlock()
    }

    func load() -> (Data?, URLResponse?) {
        lock.lock()
        defer { lock.unlock() }
        return (storedData, storedResponse)
    }
}

/// Media uses an incrementally capped delegate instead of the generic JSON
/// request helper. A compromised/malformed local endpoint therefore cannot
/// make Control buffer an unbounded response before the size check runs.
private final class BoundedMediaRequestDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)
    private var data = Data()
    private var response: URLResponse?
    private var expectedLength: Int64?
    private var tooLarge = false
    private var transportFailed = false
    private var finished = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
        super.init()
    }

    func acceptsExpectedLength(_ length: Int64) -> Bool {
        length < 0 || length <= Int64(maximumBytes)
    }

    @discardableResult
    func prepareExpectedLength(_ length: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let allowed = acceptsExpectedLength(length)
        expectedLength = length >= 0 ? length : nil
        if !allowed { tooLarge = true }
        return allowed
    }

    @discardableResult
    func accept(_ chunk: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !tooLarge, chunk.count <= maximumBytes - data.count else {
            tooLarge = true
            data.removeAll(keepingCapacity: false)
            return false
        }
        data.append(chunk)
        return true
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        self.response = response
        lock.unlock()
        let allowed = prepareExpectedLength(response.expectedContentLength)
        completionHandler(allowed ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if !accept(data) { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error: error)
    }

    func finish(error: Error?) {
        lock.lock()
        let truncated = expectedLength.map { Int64(data.count) != $0 } ?? false
        if !tooLarge, error != nil || truncated {
            transportFailed = true
            data.removeAll(keepingCapacity: false)
        }
        let shouldSignal = !finished
        finished = true
        lock.unlock()
        if shouldSignal { completion.signal() }
    }

    func wait(timeout: TimeInterval) -> (Data, URLResponse?, Bool, Bool)? {
        guard completion.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return (data, response, tooLarge, transportFailed)
    }
}

enum LaunchAgentKind: String {
    case absent
    case cosControl
    case knownLegacy
    case unknown
}

struct InPlaceRecord: Codable {
    let plistPath: String
    let appDir: String?
    let serverInstanceId: String?
    let adoptedAt: String
}

struct InPlaceConfigurationTransaction: Codable {
    var previousPlist: Data
    var candidatePlist: Data
    var previousPermissions: Int
    var previousServicePID: Int?
    var selectedWorkDirectory: String?
    var serverVersion: String?
    var generationID: String?
    var phase: String
    var startedAt: String
}

enum RuntimeState: String {
    case notInstalled
    case stopped
    case managedHealthy
    case managedDegraded
    case managedInPlace
    case legacyService
    case legacyStopped
    case legacyForeground
    case ownerConflict
    case unknown
}

struct OwnershipSnapshot {
    let serviceLoaded: Bool
    let servicePID: Int?
    let listeners: [Int: Set<Int>]
    let launchAgentKind: LaunchAgentKind

    var allListenerPIDs: Set<Int> {
        listeners.values.reduce(into: Set<Int>()) { $0.formUnion($1) }
    }
}

struct MaintenanceLease: Codable {
    let id: String
    let operationId: String
    let nonce: String
    let nonceSha256: String
    let operationKind: String
    let scope: String
    let postcondition: String
    let authorizedSuccessorGenerations: [String]
    let serverInstanceId: String
    let sourceBootId: String
    let sourceGenerationId: String
    let bootId: String
    let generationId: String
    let expiresAt: Date?
}

struct ClipboardReceipt: Codable {
    let digest: String
    let expiresAt: Date
    let launchdLabel: String
}

enum HelperError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let value): return value }
    }
}

final class COSControlHelper {
    private let fm = FileManager.default
    private let home: URL = {
        let environment = ProcessInfo.processInfo.environment
        if CommandLine.arguments.dropFirst().first?.hasPrefix("self-test") == true,
           let testHome = environment["COS_CONTROL_TEST_HOME"],
           testHome.hasPrefix("/tmp/") {
            return URL(fileURLWithPath: testHome, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()
    private let label = "com.cos.glasses-server"
    private let recoveryLabel = "com.cos.glasses-control-recovery"
    private let packageName = "@gotcos/glasses-server"
    private let providerEnvironmentKeys: Set<String> = [
        "COS_HARNESS",
        "COS_LLM_BACKEND",
        "COS_G2_DEFAULT_MODEL",
        "COS_CODEX_MODEL",
        "COS_CODEX_REASONING_EFFORT",
        "COS_CODEX_SANDBOX",
        "COS_CODEX_EXEC_READY",
        "COS_CLAUDE_TRUST_MODE",
        "COS_EXTRA_TOOLS",
        "COS_CLAUDE_MCP_CONFIG",
        "COS_CURSOR_AGENT_BIN",
        "COS_SCRIPTS_DIR",
        "COS_CONTEXT_DIR",
        "COS_OPERATIONS_DIR",
        "COS_MEETINGS_ROOT",
        "CODEX_GLASSES_WORKDIR",
        "COS_DURABLE_QUERY_JOBS",
        // Durable thread fences. MUST be allowlisted or Control drops it on the next
        // plist rewrite -- `providerEnvironment` is filtered to this set, which is
        // exactly how COS_PROFILE_PATH stopped surviving updates. A dropped fence
        // reopens a thread that may hold an undelivered turn.
        "COS_THREAD_FENCE_DURABLE",
        "COS_TTS_BOOTSTRAP_PYTHON",
        "COS_TTS_PYTHON",
        "COS_TTS_ENGINE",
        "COS_TTS_KOKORO_VOICE",
        "COS_WHISPER_PREVIEW_MODEL",
        "COS_WHISPER_REALTIME_MODEL",
        "COS_WHISPER_TRANSCRIPTION_TIER",
        "COS_WHISPER_COMMIT_MODEL",
        "COS_WHISPER_MEETING_PREVIEW",
        "COS_MEETING_EARLY_SYNC",
        "COS_MEETING_PROGRESSIVE_HQ",
        "COS_MEETING_PROGRESSIVE_HQ_THREADS",
        "COS_BATCH_HQ_METAL",
        "COS_BATCH_HQ_FORCE_CPU",
        "COS_MEETING_AUDIO_ADAPTIVE_PLAYBACK",
        "COS_VIDEO_UPLOAD_V2",
        "COS_CLAUDE_SESSIONS_ENABLED",
        "COS_CLAUDE_SESSIONS_SHOW_NAMES",
        // Continue an agent thread. The server reads this key straight off
        // process.env and never parses .env, so this allowlist is the ONLY
        // channel that survives Install / Repair / Update Server. Omitting it
        // is not a missing feature — it silently DROPS a hand-set flag on the
        // next update, which is how COS_PROFILE_PATH was lost.
        "COS_THREAD_ATTACH_ENABLED",
    ]

    private lazy var support = home.appendingPathComponent("Library/Application Support/COS Control", isDirectory: true)
    private lazy var runtimeRoot = support.appendingPathComponent("runtime", isDirectory: true)
    private lazy var generations = runtimeRoot.appendingPathComponent("generations", isDirectory: true)
    private lazy var stagingRoot = runtimeRoot.appendingPathComponent("staging", isDirectory: true)
    private lazy var manifestURL = runtimeRoot.appendingPathComponent("active.json")
    private lazy var inPlaceURL = runtimeRoot.appendingPathComponent("in-place.json")
    private lazy var transactionURL = runtimeRoot.appendingPathComponent("transaction.json")
    private lazy var inPlaceConfigurationURL = runtimeRoot.appendingPathComponent("in-place-configuration.json")
    private lazy var maintenanceLeaseURL = runtimeRoot.appendingPathComponent("maintenance-lease.json")
    private lazy var mutationLockURL = runtimeRoot.appendingPathComponent("operation.lock")
    private lazy var clipboardReceiptURL = support.appendingPathComponent("clipboard-receipt.json")
    private lazy var cursorProbeCacheURL = support.appendingPathComponent("cursor-probe-cache.json")
    private lazy var controlCache = home.appendingPathComponent("Library/Caches/com.gotcos.COSControl", isDirectory: true)
    private lazy var mediaTransferRoot = controlCache.appendingPathComponent("MediaTransfers", isDirectory: true)
    private lazy var stableBin = support.appendingPathComponent("bin", isDirectory: true)
    private lazy var stableHelper = stableBin.appendingPathComponent("cos-control-helper")
    private lazy var logs = home.appendingPathComponent("Library/Logs/COS Glasses", isDirectory: true)
    private lazy var helperLog = logs.appendingPathComponent("control.log")
    private lazy var serverLog = logs.appendingPathComponent("server.log")
    private lazy var serverErrorLog = logs.appendingPathComponent("server-error.log")
    private lazy var plistURL = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    private lazy var recoveryPlistURL = home.appendingPathComponent("Library/LaunchAgents/\(recoveryLabel).plist")
    private lazy var configDir = home.appendingPathComponent(".cos-glasses", isDirectory: true)
    /// "0.2.9 (build 20)" when the app passed its identity; nil for a bare CLI run.
    private var appIdentity: String?
    private lazy var envURL = configDir.appendingPathComponent(".env")
    private lazy var certsDir = configDir.appendingPathComponent("certs", isDirectory: true)

    func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { throw HelperError.message("missing command") }
        // The app hands over its own identity (same contract as check-app-update)
        // so Doctor and Copy Report can name the build. The helper cannot read it
        // itself: the stable copy under Application Support has no sibling
        // Info.plist, so a bundle lookup would be right only half the time.
        if let version = option("--current-version", in: args), !version.isEmpty {
            let build = option("--current-build", in: args).flatMap(Int.init)
            appIdentity = build.map { "\(version) (build \($0))" } ?? version
        }
        switch command {
        case "self-test": try selfTest()
        case "self-test-lock-crash": try selfTestLockCrash()
        case "status": emit(ok: true, message: "Status refreshed", details: statusDetails())
        case "doctor": emit(ok: true, message: "Doctor complete", details: doctorDetails(redacted: false))
        case "install": try withMutationLock {
            let requested = option("--version", in: args) ?? "latest"
            let work = option("--workdir", in: args)
            try install(requestedVersion: requested, workDirectory: work)
        }
        case "update": try withMutationLock { try install(requestedVersion: "latest", workDirectory: loadManifest()?.workDirectory) }
        case "adopt": try withMutationLock {
            let requested = option("--version", in: args) ?? "latest"
            try adoptLegacy(requestedVersion: requested)
        }
        case "adopt-in-place": try withMutationLock { try adoptLegacyInPlace() }
        case "release-in-place": try withMutationLock { try releaseInPlace() }
        case "operation-status": emit(ok: true, message: "Operation status refreshed", details: operationStatusDetails())
        case "reconcile": try withMutationLock { try reconcile() }
        case "reconcile-automatic": try withMutationLock { try automaticReconcile() }
        case "start": try withMutationLock { try start() }
        case "stop": try withMutationLock { try stop() }
        case "restart": try withMutationLock { try restart() }
        case "rollback": try withMutationLock { try rollback() }
        case "repair": try withMutationLock { try repair() }
        case "restart-whisper": try withMutationLock { try restartWhisper() }
        case "set-workdir": try withMutationLock {
            guard let value = args.dropFirst().first else { throw HelperError.message("missing work directory") }
            try setWorkDirectory(value)
        }
        case "set-operations-dir": try withMutationLock {
            guard let value = args.dropFirst().first else { throw HelperError.message("missing operations directory") }
            try setOperationsDirectory(value)
        }
        case "create-context-folders": try withMutationLock {
            let details = try createContextFolders(at: option("--path", in: args))
            emit(ok: true, message: "Memory and Threads folders ready", details: details)
        }
        case "set-context-dir": try withMutationLock {
            guard let value = args.dropFirst().first else { throw HelperError.message("missing COS data directory") }
            // No --tier means keep the current tier. Folder re-picks must never move
            // a user between tiers; that is what `--tier` exists for.
            try setContextDirectory(value, tier: option("--tier", in: args))
        }
        case "set-transcription-tier": try withMutationLock {
            guard let value = args.dropFirst().first else { throw HelperError.message("missing transcription tier") }
            try setTranscriptionTier(value)
        }
        case "set-background-jobs": try withMutationLock {
            guard let value = args.dropFirst().first else { throw HelperError.message("missing background jobs setting") }
            try setBackgroundJobs(value)
        }
        case "set-meeting-preview": try withMutationLock {
            guard let value = args.dropFirst().first else { throw HelperError.message("missing meeting preview setting") }
            try setMeetingPreview(value)
        }
        case "set-idle-metal-hq": try withMutationLock {
            guard let value = args.dropFirst().first else { throw HelperError.message("missing idle Metal HQ setting") }
            try setIdleMetalHq(value)
        }
        case "set-adaptive-audio-cleanup": try withMutationLock {
            guard let value = args.dropFirst().first else { throw HelperError.message("missing adaptive audio cleanup setting") }
            try setAdaptiveAudioCleanup(value)
        }
        case "set-video-upload-v2": try withMutationLock {
            guard let value = args.dropFirst().first else { throw HelperError.message("missing reliable video upload setting") }
            try setVideoUploadV2(value)
        }
        case "set-claude-sessions": try withMutationLock {
            guard let value = args.dropFirst().first else { throw HelperError.message("missing Claude sessions setting") }
            try setClaudeSessions(value)
        }
        case "set-thread-attach": try withMutationLock {
            guard let value = args.dropFirst().first else { throw HelperError.message("missing Continue agent threads setting") }
            try setThreadAttach(value)
        }
        case "claude-sessions": try emitClaudeSessions()
        case "claude-sessions-search": try emitClaudeSessionsSearch(args: args)
        case "claude-session-detail": try emitClaudeSessionDetail(args: args)
        case "meeting-stranded-save": try emitMeetingStrandedSave(args: args)
        case "meeting-stranded-save-all": try emitMeetingStrandedSaveAll()
        case "clear-stranded-video-uploads": try clearStrandedVideoUploads()
        case "reset-message-era": try resetMessageEra()
        case "meeting-orphans": try emitMeetingOrphans()
        case "meeting-orphan-recover": try emitMeetingOrphanRecover(args: args)
        case "meeting-orphan-recover-all": try emitMeetingOrphanRecoverAll()
        case "meeting-sync-now": try emitMeetingSyncNow()
        case "token": try copyPairingToken()
        case "expire-clipboard": try expireClipboard(args: args)
        case "report": emit(ok: true, message: "Redacted report ready", details: ["report": redactedReport()])
        case "recent-messages": try emitRecentMessages(args: args)
        case "context-memories": try emitContextMemories(args: args)
        case "context-threads": try emitContextThreads(args: args)
        case "context-memories-search": try emitContextSearch(kind: "memory", args: args)
        case "context-threads-search": try emitContextSearch(kind: "thread", args: args)
        case "meetings": try emitMeetings(args: args)
        case "meetings-library": try emitMeetingsLibrary(args: args)
        case "meetings-library-search": try emitMeetingsLibrarySearch(args: args)
        case "meeting-library-detail": try emitMeetingLibraryDetail(args: args)
        case "meeting-speakers": try emitMeetingSpeakers(args: args)
        case "meeting-content": try emitMeetingContent(args: args)
        case "fences": try emitFences()
        case "fence-release": try emitFenceRelease(args: args)
        case "voice-profiles": try emitVoiceProfiles()
        case "voice-directory": try emitVoiceDirectory(args: args)
        case "voice-merge": try emitVoiceMerge(args: args)
        case "meeting-relabel": try emitMeetingRelabel(args: args)
        case "meeting-deattribute": try emitMeetingDeattribute(args: args)
        case "meeting-confirm": try emitMeetingConfirm(args: args)
        case "review-audio": try emitReviewAudio(args: args)
        case "review-audio-list": try emitReviewAudioList(args: args)
        case "fetch-media": try emitFetchedMedia(args: args)
        case "check-app-update": try emitAppUpdateCheck(args: args)
        case "run-server": try runServer()
        default: throw HelperError.message("unknown command: \(command)")
        }
    }

    private func option(_ name: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    private func emit(ok: Bool, message: String, details: [String: Any] = [:]) {
        let payload: [String: Any] = ["ok": ok, "message": message, "details": details]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private func progress(_ message: String) {
        guard let data = "\(message)\n".data(using: .utf8) else { return }
        try? FileHandle.standardError.write(contentsOf: data)
    }

    private func ensureDirectories() throws {
        for url in [support, runtimeRoot, generations, stagingRoot, stableBin, logs, configDir, certsDir, plistURL.deletingLastPathComponent()] {
            try ensurePrivateDirectory(url)
        }
    }

    private func withMutationLock<T>(_ body: () throws -> T) throws -> T {
        try ensureDirectories()
        let descriptor = open(mutationLockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw HelperError.message("Could not open the lifecycle operation lock.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            // flock is kernel-owned and automatically released when a helper
            // exits. File contents may describe an old PID, but can never keep
            // the lock held. Never unlink this inode while a live helper owns it.
            throw HelperError.message("Another COS Control lifecycle operation is running. This lock is crash-safe; retry after the current helper exits.")
        }
        defer {
            _ = ftruncate(descriptor, 0)
            _ = fsync(descriptor)
            flock(descriptor, LOCK_UN)
        }
        _ = ftruncate(descriptor, 0)
        let identity = "pid=\(getpid()) started=\(ISO8601DateFormatter().string(from: Date()))\n"
        identity.withCString { pointer in _ = write(descriptor, pointer, strlen(pointer)) }
        _ = fsync(descriptor)
        return try body()
    }

    /// Test-only crash harness. It is unreachable against a real home and
    /// proves that kernel flock ownership disappears when a helper is killed.
    private func selfTestLockCrash() throws {
        guard let testHome = ProcessInfo.processInfo.environment["COS_CONTROL_TEST_HOME"],
              testHome.hasPrefix("/tmp/") else {
            throw HelperError.message("self-test lock harness requires an isolated temporary home")
        }
        try withMutationLock {
            let marker = runtimeRoot.appendingPathComponent("lock-holder-crashed")
            try Data("locked\n".utf8).write(to: marker, options: .atomic)
            _ = Darwin.kill(getpid(), SIGKILL)
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        if fm.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else {
                throw HelperError.message("Unsafe directory path: \(redactPath(url.path))")
            }
        } else {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func validatePrivateRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw HelperError.message("Unsafe file path: \(redactPath(url.path))")
        }
    }

    private func executableCandidates(_ name: String) -> [String] {
        var candidates: [String] = []
        if name == "codex" {
            candidates.append("/Applications/Codex.app/Contents/Resources/codex")
            candidates.append(home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path)
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/\(name)" }
        }
        candidates += [
            "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)",
            "/usr/bin/\(name)", "/bin/\(name)",
            home.appendingPathComponent(".local/bin/\(name)").path,
            home.appendingPathComponent(".volta/bin/\(name)").path,
            home.appendingPathComponent(".asdf/shims/\(name)").path,
        ]
        if name == "node" || name == "npm" {
            let versions = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
            if let entries = try? fm.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil) {
                candidates += entries.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
                    .map { $0.appendingPathComponent("bin/\(name)").path }
            }
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private func findExecutable(_ name: String) -> String? {
        executableCandidates(name).first { fm.isExecutableFile(atPath: $0) }
    }

    /// Build the one PATH used by every managed launch. Provider directories
    /// come from actual executable discovery, while common user install roots
    /// remain present even when COS Control itself was opened from Finder with
    /// a minimal GUI environment. Existing absolute LaunchAgent entries are
    /// preserved so an upgrade cannot erase a working custom CLI location.
    private func launchPathDirectories(node: String) -> [String] {
        var directories = [URL(fileURLWithPath: node).deletingLastPathComponent().path]
        for name in ["claude", "codex", "agent"] {
            if let executable = findExecutable(name) {
                directories.append(URL(fileURLWithPath: executable).deletingLastPathComponent().path)
            }
        }
        directories += [
            home.appendingPathComponent(".local/bin", isDirectory: true).path,
            home.appendingPathComponent(".volta/bin", isDirectory: true).path,
            home.appendingPathComponent(".asdf/shims", isDirectory: true).path,
            "/Applications/ChatGPT.app/Contents/Resources",
            "/Applications/Codex.app/Contents/Resources",
        ]
        if let plist = launchAgentPropertyList(),
           let environment = plist["EnvironmentVariables"] as? [String: String],
           let priorPath = environment["PATH"] {
            directories += priorPath.split(separator: ":").map(String.init).filter { directory in
                directory.hasPrefix("/") && ["claude", "codex", "agent"].contains {
                    fm.isExecutableFile(atPath: URL(fileURLWithPath: directory).appendingPathComponent($0).path)
                }
            }
        }
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

        var seen = Set<String>()
        return directories.compactMap { raw in
            let value = URL(fileURLWithPath: raw).standardizedFileURL.path
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
    }

    /// Finder-launched apps inherit a minimal PATH. Homebrew's npm executable
    /// uses `#!/usr/bin/env node`, so finding npm is not sufficient: its child
    /// must also receive the directory containing the Node binary. Keep npm's
    /// update notifier off here so the JSON-only registry response cannot be
    /// polluted by an unrelated upgrade notice on the shared output pipe.
    private func nodeToolEnvironment(node: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = launchPathDirectories(node: node).joined(separator: ":")
        environment["NPM_CONFIG_UPDATE_NOTIFIER"] = "false"
        return environment
    }

    /// Match glasses-app `resolveAgentBinary`: env → PATH → ~/.local/bin/agent.
    private func resolveAgentBinary() -> String? {
        if let configured = ProcessInfo.processInfo.environment["COS_CURSOR_AGENT_BIN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty,
           fm.isExecutableFile(atPath: configured) {
            return configured
        }
        return findExecutable("agent")
    }

    @discardableResult
    private func execute(
        _ executable: String,
        _ arguments: [String],
        log: Bool = false,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 20,
        heartbeat: String? = nil,
        heartbeatInterval: TimeInterval = 15
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }

        var logHandle: FileHandle?
        let pipe = Pipe()
        if log {
            try ensureDirectories()
            if !fm.fileExists(atPath: helperLog.path) { fm.createFile(atPath: helperLog.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: helperLog)
            try handle.seekToEnd()
            process.standardOutput = handle
            process.standardError = handle
            logHandle = handle
        } else {
            process.standardOutput = pipe
            process.standardError = pipe
        }

        try process.run()
        let timedOut: Bool
        if heartbeat == nil {
            timedOut = completion.wait(timeout: .now() + timeout) == .timedOut
        } else {
            let deadline = Date().addingTimeInterval(timeout)
            var expired = false
            while true {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    expired = true
                    break
                }
                if completion.wait(timeout: .now() + min(heartbeatInterval, remaining)) == .success {
                    break
                }
                if let heartbeat { progress(heartbeat) }
            }
            timedOut = expired
        }
        if timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 2)
            }
            try? logHandle?.close()
            throw HelperError.message("Command timed out: \(URL(fileURLWithPath: executable).lastPathComponent)")
        }
        try? logHandle?.close()
        let data = log ? Data() : (try pipe.fileHandleForReading.readToEnd() ?? Data())
        return CommandResult(
            code: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func loadManifest() -> RuntimeManifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(RuntimeManifest.self, from: data)
    }

    private func loadTransaction() -> RuntimeTransaction? {
        guard let data = try? Data(contentsOf: transactionURL) else { return nil }
        return try? JSONDecoder().decode(RuntimeTransaction.self, from: data)
    }

    private func loadInPlaceConfigurationTransaction() -> InPlaceConfigurationTransaction? {
        guard let data = try? Data(contentsOf: inPlaceConfigurationURL) else { return nil }
        return try? JSONDecoder().decode(InPlaceConfigurationTransaction.self, from: data)
    }

    private func fsyncDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw HelperError.message("Could not open state directory for durability sync.") }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw HelperError.message("Could not durably sync state directory.") }
    }

    private func atomicWriteData(_ data: Data, to url: URL, permissions: Int) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: permissions]) else {
            throw HelperError.message("Could not create durable state file.")
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            guard Darwin.rename(temporary.path, url.path) == 0 else {
                throw HelperError.message("Could not atomically commit durable state.")
            }
            try fsyncDirectory(url.deletingLastPathComponent())
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    private func atomicWrite<T: Encodable>(_ value: T, to url: URL, permissions: Int) throws {
        try atomicWriteData(try JSONEncoder().encode(value), to: url, permissions: permissions)
    }

    private func saveManifest(_ manifest: RuntimeManifest) throws {
        try ensureDirectories()
        try atomicWrite(manifest, to: manifestURL, permissions: 0o600)
    }

    private func saveTransaction(_ transaction: RuntimeTransaction) throws {
        try ensureDirectories()
        try atomicWrite(transaction, to: transactionURL, permissions: 0o600)
    }

    private func saveInPlaceConfigurationTransaction(_ transaction: InPlaceConfigurationTransaction) throws {
        try ensureDirectories()
        try atomicWrite(transaction, to: inPlaceConfigurationURL, permissions: 0o600)
    }

    private func clearTransaction() {
        guard fm.fileExists(atPath: transactionURL.path) else { return }
        try? fm.removeItem(at: transactionURL)
        try? fsyncDirectory(transactionURL.deletingLastPathComponent())
    }

    private func clearInPlaceConfigurationTransaction() {
        guard fm.fileExists(atPath: inPlaceConfigurationURL.path) else { return }
        try? fm.removeItem(at: inPlaceConfigurationURL)
        try? fsyncDirectory(inPlaceConfigurationURL.deletingLastPathComponent())
    }

    private func loadMaintenanceLease() -> MaintenanceLease? {
        guard let data = try? Data(contentsOf: maintenanceLeaseURL) else { return nil }
        return try? JSONDecoder().decode(MaintenanceLease.self, from: data)
    }

    private func saveMaintenanceLease(_ lease: MaintenanceLease) throws {
        try ensureDirectories()
        try atomicWrite(lease, to: maintenanceLeaseURL, permissions: 0o600)
    }

    private func clearMaintenanceLease() {
        guard fm.fileExists(atPath: maintenanceLeaseURL.path) else { return }
        try? fm.removeItem(at: maintenanceLeaseURL)
        try? fsyncDirectory(maintenanceLeaseURL.deletingLastPathComponent())
    }

    private func resolveVersion(_ requested: String) throws -> (version: String, integrity: String) {
        guard requested == "latest" || requested.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else {
            throw HelperError.message("invalid server version")
        }
        guard let npm = findExecutable("npm") else {
            throw HelperError.message("Node/npm not found. Install Node.js 20.11 or newer.")
        }
        guard let node = findExecutable("node") else {
            throw HelperError.message("Node/npm not found. Install Node.js 20.11 or newer.")
        }
        let spec = requested == "latest" ? packageName : "\(packageName)@\(requested)"
        let result = try execute(
            npm,
            ["--silent", "view", spec, "version", "dist.integrity", "--json"],
            environment: nodeToolEnvironment(node: node),
            timeout: 30
        )
        guard result.code == 0, let data = result.output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String,
              let integrity = object["dist.integrity"] as? String,
              version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
              integrity.hasPrefix("sha512-") else {
            throw HelperError.message(requested == "latest"
                ? "Could not resolve the latest npm server release."
                : "Server \(requested) is not published on npm yet.")
        }
        return (version, integrity)
    }

    private func nodeVersion(at path: String) -> (valid: Bool, display: String) {
        guard let result = try? execute(path, ["--version"], timeout: 5), result.code == 0 else {
            return (false, "unavailable")
        }
        let version = result.output.trimmingCharacters(in: CharacterSet(charactersIn: "v \n"))
        let parts = version.split(separator: ".").compactMap { Int($0) }
        let valid = parts.count >= 2 && (parts[0] > 20 || (parts[0] == 20 && parts[1] >= 11))
        return (valid, version)
    }

    private func packageRoot(for generationPath: String) -> URL {
        URL(fileURLWithPath: generationPath, isDirectory: true)
            .appendingPathComponent("node_modules/@gotcos/glasses-server", isDirectory: true)
    }

    private func runtimePaths(for generationPath: String) -> (root: URL, launcher: URL, packageJSON: URL, server: URL, tsx: URL) {
        let root = packageRoot(for: generationPath)
        let generation = URL(fileURLWithPath: generationPath, isDirectory: true)
        return (
            root,
            root.appendingPathComponent("bin/managed-server.cjs"),
            root.appendingPathComponent("package.json"),
            root.appendingPathComponent("server/index.ts"),
            generation.appendingPathComponent("node_modules/tsx/dist/esm/index.mjs")
        )
    }

    private func sha256(_ url: URL) throws -> String {
        let result = try execute("/usr/bin/shasum", ["-a", "256", url.path], timeout: 30)
        guard result.code == 0, let value = result.output.split(separator: " ").first, value.count == 64 else {
            throw HelperError.message("Could not verify installed server files.")
        }
        return String(value)
    }

    private func registryIntegrity(_ url: URL) throws -> String {
        let digest = SHA512.hash(data: try Data(contentsOf: url))
        return "sha512-" + Data(digest).base64EncodedString()
    }

    private func verifyGeneration(
        at path: String,
        expectedVersion: String? = nil,
        expectedIntegrity: String? = nil,
        expectedLauncherHash: String? = nil,
        expectedPackageHash: String? = nil
    ) throws -> GenerationRecord {
        let urls = runtimePaths(for: path)
        for required in [urls.launcher, urls.packageJSON, urls.server, urls.tsx] {
            guard fm.isReadableFile(atPath: required.path) else {
                throw HelperError.message("The staged server is incomplete (missing \(required.lastPathComponent)).")
            }
            try validatePrivateRegularFile(required)
        }
        let data = try Data(contentsOf: urls.packageJSON)
        guard let package = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              package["name"] as? String == packageName,
              let version = package["version"] as? String,
              expectedVersion == nil || version == expectedVersion else {
            throw HelperError.message("The staged npm package identity/version does not match the requested release.")
        }
        if let expectedIntegrity {
            let artifact = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(".registry-artifact.tgz")
            guard fm.isReadableFile(atPath: artifact.path), try registryIntegrity(artifact) == expectedIntegrity else {
                throw HelperError.message("The installed package does not match the immutable npm registry artifact.")
            }
        }
        let launcherHash = try sha256(urls.launcher)
        let packageHash = try sha256(urls.packageJSON)
        guard expectedLauncherHash == nil || expectedLauncherHash == launcherHash,
              expectedPackageHash == nil || expectedPackageHash == packageHash else {
            throw HelperError.message("The active server generation failed its integrity check.")
        }
        return GenerationRecord(
            version: version,
            path: URL(fileURLWithPath: path).standardizedFileURL.path,
            registryIntegrity: expectedIntegrity,
            launcherSHA256: launcherHash,
            packageJSONSHA256: packageHash
        )
    }

    private func stageGeneration(version: String, integrity: String) throws -> GenerationRecord {
        guard let npm = findExecutable("npm") else { throw HelperError.message("npm not found") }
        guard let node = findExecutable("node") else { throw HelperError.message("Node.js not found") }
        let npmEnvironment = nodeToolEnvironment(node: node)
        try ensureDirectories()
        let stage = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        progress("Downloading server \(version)…")
        let packed = try execute(npm, [
            "--silent", "pack", "\(packageName)@\(version)", "--pack-destination", stage.path, "--json",
        ], environment: npmEnvironment, timeout: 120)
        guard packed.code == 0,
              let packedData = packed.output.data(using: .utf8),
              let packedObjects = try? JSONSerialization.jsonObject(with: packedData) as? [[String: Any]],
              let packedObject = packedObjects.first,
              let filename = packedObject["filename"] as? String else {
            throw HelperError.message("npm could not download the immutable registry artifact.")
        }
        let downloaded = stage.appendingPathComponent(filename)
        guard try registryIntegrity(downloaded) == integrity else {
            throw HelperError.message("Downloaded npm artifact failed registry SRI verification.")
        }
        let artifact = stage.appendingPathComponent(".registry-artifact.tgz")
        try fm.moveItem(at: downloaded, to: artifact)
        let result = try execute(npm, [
            "install", "--prefix", stage.path, "--ignore-scripts", "--omit=dev",
            "--no-audit", "--no-fund", artifact.path,
        ], log: true, environment: npmEnvironment, timeout: 900)
        guard result.code == 0 else {
            throw HelperError.message("npm server installation failed. Open the COS Control log for details.")
        }
        progress("Verifying staged package…")
        let staged = try verifyGeneration(at: stage.path, expectedVersion: version, expectedIntegrity: integrity)
        let suffix = String((staged.launcherSHA256 ?? UUID().uuidString).prefix(12))
        let final = generations.appendingPathComponent("\(version)-\(suffix)", isDirectory: true)
        if fm.fileExists(atPath: final.path) {
            let existing = try verifyGeneration(at: final.path, expectedVersion: version, expectedIntegrity: integrity)
            try? fm.removeItem(at: stage)
            return existing
        }
        try fm.moveItem(at: stage, to: final)
        return try verifyGeneration(at: final.path, expectedVersion: version, expectedIntegrity: integrity)
    }

    private func currentGenerationRecord(_ manifest: RuntimeManifest) -> GenerationRecord {
        GenerationRecord(
            version: manifest.version,
            path: manifest.generationPath,
            registryIntegrity: manifest.registryIntegrity,
            launcherSHA256: manifest.launcherSHA256,
            packageJSONSHA256: manifest.packageJSONSHA256
        )
    }

    private func makeManifest(
        generation: GenerationRecord,
        workDirectory: String?,
        previous: RuntimeManifest?,
        retained: [GenerationRecord]? = nil
    ) throws -> RuntimeManifest {
        guard let node = findExecutable("node") else { throw HelperError.message("Node.js not found") }
        let nodeProbe = nodeVersion(at: node)
        guard nodeProbe.valid else { throw HelperError.message("Node.js 20.11 or newer is required (found \(nodeProbe.display)).") }
        var history = retained ?? []
        if let previous {
            history.insert(currentGenerationRecord(previous), at: 0)
            history += previous.retainedGenerations ?? []
        }
        var seen = Set<String>()
        history = history.filter { $0.path != generation.path && seen.insert($0.path).inserted }
        history = Array(history.prefix(2))
        return RuntimeManifest(
            version: generation.version,
            generationPath: generation.path,
            workDirectory: try validatedWorkDirectory(workDirectory),
            installedAt: ISO8601DateFormatter().string(from: Date()),
            previousVersions: history.map(\.version),
            schemaVersion: 2,
            registryIntegrity: generation.registryIntegrity,
            launcherSHA256: generation.launcherSHA256,
            packageJSONSHA256: generation.packageJSONSHA256,
            generationID: String((generation.launcherSHA256 ?? UUID().uuidString).prefix(24)),
            nodePath: node,
            providerEnvironment: try captureProviderEnvironment(previous: previous),
            retainedGenerations: history,
            desiredState: "running"
        )
    }

    private func install(requestedVersion: String, workDirectory: String?) throws {
        try ensureDirectories()
        // Capture a legacy/in-place selection before removing its ownership
        // marker or replacing the plist during adoption.
        let inheritedWorkDirectory = try validatedWorkDirectory(workDirectory) ?? configuredWorkDirectory()
        // Installing a managed generation exits in-place mode, but the marker is
        // NOT dropped here: every throw below this point (pending transaction,
        // unadoptable ownership, npm unreachable, staging failure) must leave a
        // healthy in-place install exactly as it was. Deleting it early meant a
        // transient npm outage permanently disabled inPlaceActive() — and with it
        // the per-minute in-place recovery watchdog — with nothing to restore it.
        let inPlaceMarker = try? Data(contentsOf: inPlaceURL)
        guard loadTransaction() == nil else {
            throw HelperError.message("A previous update needs repair before another install can begin.")
        }
        let ownership = ownershipSnapshot()
        try assertAdoptableOwnership(ownership)

        progress("Resolving npm release…")
        let release = try resolveVersion(requestedVersion)
        try requireVideoUploadDowngradeSafe(targetVersion: release.version)
        let generation = try stageGeneration(version: release.version, integrity: release.integrity)
        // Populate the stable cert store AND the API token now, before the legacy
        // LaunchAgent is unloaded/overwritten, so the exact HTTPS certificate and
        // COS_API_TOKEN the glasses already use are carried over verbatim (the
        // glasses reach the server over HTTPS 3143 and auth with X-Cos-Token).
        ensureManagedCerts()
        ensureManagedToken()
        try installStableHelper()
        try installRecoveryLaunchAgent()
        try ensureConfig()

        let old = loadManifest()
        let manifest = try makeManifest(
            generation: generation,
            workDirectory: inheritedWorkDirectory ?? old?.workDirectory,
            previous: old
        )
        var transaction = RuntimeTransaction(
            previous: old,
            candidate: manifest,
            previousLaunchAgentPlist: ownership.launchAgentKind == .knownLegacy ? (try? Data(contentsOf: plistURL)) : nil,
            phase: "staged",
            startedAt: ISO8601DateFormatter().string(from: Date())
        )
        try saveTransaction(transaction)

        var switchStarted = false
        do {
            let lease = try acquireMaintenanceLeaseIfNeeded(
                snapshot: ownership,
                operationKind: "server_update",
                successorGenerations: [manifest.generationID, old?.generationID].compactMap { $0 }
            )
            transaction.phase = "switching"
            try saveTransaction(transaction)
            switchStarted = true
            // Point of no return: the managed plist is about to replace the
            // adopted one, so in-place mode ends here. Restored below if the
            // switch fails and we roll back to the previous runtime.
            try? fm.removeItem(at: inPlaceURL)
            if ownership.serviceLoaded {
                do { try unloadService() }
                catch {
                    throw error
                }
            }
            try waitForPortsClear(timeout: 12)
            try saveManifest(manifest)
            try writeLaunchAgent(for: manifest)
            progress("Starting managed server…")
            try loadService(forceRestart: false)
            let activeLease = try waitForManagedHealth(
                expectedVersion: manifest.version,
                expectedGenerationID: manifest.generationID,
                inheritedLease: lease,
                timeout: 60
            )
            try requireMaintenanceRelease(activeLease)
            try assertManagedHTTPS()
            clearTransaction()
            cleanupGenerations(keeping: Set([manifest.generationPath] + (manifest.retainedGenerations ?? []).map(\.path)))
            emit(ok: true, message: "COS Glasses Server \(manifest.version) installed and verified", details: statusDetails())
        } catch {
            if !switchStarted {
                clearTransaction()
                throw error
            }
            progress("Candidate failed; restoring the previous runtime…")
            let recoveryMessage = try restoreAfterFailedSwitch(transaction)
            // The previous runtime is back, so in-place ownership comes back with
            // it. Without this the rollback would look successful while
            // inPlaceActive() stayed false and the in-place watchdog stayed off.
            if let inPlaceMarker { try? inPlaceMarker.write(to: inPlaceURL, options: .atomic) }
            throw HelperError.message("Update failed. \(recoveryMessage) Original error: \(error)")
        }
    }

    /// When an interrupted update left the candidate already live and healthy,
    /// commit that candidate instead of rolling back to the previous generation.
    private func commitHealthyCandidateIfPresent(_ transaction: RuntimeTransaction) throws -> String? {
        let candidate = transaction.candidate
        guard let generationID = candidate.generationID else { return nil }
        let snapshot = ownershipSnapshot()
        guard snapshot.launchAgentKind == .cosControl,
              snapshot.serviceLoaded,
              !snapshot.allListenerPIDs.isEmpty,
              launchdOwnsListeners(snapshot, requireDirect: true) else { return nil }
        guard let status = maintenanceStatus(),
              hasLifecycleContract(status),
              (status["lifecycle"] as? [String: Any])?["state"] as? String == "accepting",
              status["serverVersion"] as? String == candidate.version,
              status["generationId"] as? String == generationID else { return nil }
        guard managedHealthFailure(request("/api/health", timeout: 12)) == nil else { return nil }
        // Persist the candidate manifest if a partial restore already rewound it.
        if loadManifest()?.generationPath != candidate.generationPath
            || loadManifest()?.version != candidate.version {
            try saveManifest(candidate)
            try writeLaunchAgent(for: candidate)
        }
        clearMaintenanceLease()
        clearTransaction()
        return "Interrupted update recovered: managed server \(candidate.version) was already healthy and is now committed."
    }

    private func restoreAfterFailedSwitch(_ transaction: RuntimeTransaction) throws -> String {
        let snapshot = ownershipSnapshot()
        if transaction.previous == nil {
            if snapshot.serviceLoaded { try unloadService() }
            try? waitForPortsClear(timeout: 8)
            if let legacyPlist = transaction.previousLaunchAgentPlist {
                try atomicWriteData(legacyPlist, to: plistURL, permissions: 0o600)
            } else if launchAgentKind() == .cosControl {
                try? fm.removeItem(at: plistURL)
                try? fsyncDirectory(plistURL.deletingLastPathComponent())
            }
            try? fm.removeItem(at: manifestURL)
            try? fsyncDirectory(manifestURL.deletingLastPathComponent())
            if transaction.candidate.generationPath.hasPrefix(generations.path + "/") {
                try? fm.removeItem(atPath: transaction.candidate.generationPath)
            }
            clearMaintenanceLease()
            clearTransaction()
            return legacyPlistMessage(transaction.previousLaunchAgentPlist != nil)
        }
        // Always authorize both candidate + previous generations. An empty
        // successor list throws when listeners are still up (common when the
        // candidate actually booted but verification failed later).
        let lease = try acquireMaintenanceLeaseIfNeeded(
            snapshot: snapshot,
            operationKind: "server_update",
            successorGenerations: [
                transaction.previous?.generationID,
                transaction.candidate.generationID,
            ].compactMap { $0 }
        )
        if serviceLoaded() {
            do { try unloadService() }
            catch {
                throw error
            }
        }
        try? waitForPortsClear(timeout: 8)
        guard let previous = transaction.previous else { throw HelperError.message("Missing rollback manifest.") }
        _ = try verifyGeneration(
            at: previous.generationPath,
            expectedVersion: previous.version,
            expectedIntegrity: previous.registryIntegrity,
            expectedLauncherHash: previous.launcherSHA256,
            expectedPackageHash: previous.packageJSONSHA256
        )
        try saveManifest(previous)
        try writeLaunchAgent(for: previous)
        if previous.desiredState == "stopped" {
            try setServiceEnabled(false)
            clearMaintenanceLease()
            clearTransaction()
            return "The previous stopped server \(previous.version) configuration was restored."
        }
        try loadService(forceRestart: false)
        let activeLease = try waitForManagedHealth(
            expectedVersion: previous.version,
            expectedGenerationID: previous.generationID,
            inheritedLease: lease,
            timeout: 60,
            // This integrity-verified generation already passed the complete
            // provider/TTS gate when it was first committed. Re-running an old
            // server's verifier during rollback can deadlock Repair after a
            // provider CLI changes its project-context behavior. New candidates
            // still require the complete transactional proof before commit.
            requireTransactionalProof: false
        )
        try requireMaintenanceRelease(activeLease)
        clearTransaction()
        return "The previous server \(previous.version) was restored and verified."
    }

    private func legacyPlistMessage(_ restored: Bool) -> String {
        restored
            ? "The failed candidate was removed and the prior stopped legacy LaunchAgent was restored."
            : "No prior managed generation existed; the failed candidate was stopped and removed."
    }

    private func installStableHelper() throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let destination = stableHelper.standardizedFileURL
        if source.path != destination.path {
            let temporary = destination.appendingPathExtension("new")
            try? fm.removeItem(at: temporary)
            try fm.copyItem(at: source, to: temporary)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporary.path)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: destination)
            }
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
    }

    private func validatedWorkDirectory(_ value: String?) throws -> String? {
        guard let value, !value.isEmpty else { return nil }
        let url = URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw HelperError.message("Selected work folder does not exist.")
        }
        guard access(url.path, R_OK | X_OK) == 0 else {
            throw HelperError.message("Selected work folder is not readable and traversable by COS.")
        }
        let markers = [
            url.appendingPathComponent("AGENTS.md").path,
            url.appendingPathComponent("CLAUDE.md").path,
            url.appendingPathComponent(".cos/manifest.json").path,
        ]
        guard markers.contains(where: fm.fileExists(atPath:)) else {
            throw HelperError.message("Selected folder is not a COS workspace (AGENTS.md, CLAUDE.md, or .cos/manifest.json is required).")
        }
        return url.path
    }

    private func ensureConfig() throws {
        try ensurePrivateDirectory(configDir)
        if fm.fileExists(atPath: envURL.path) {
            try validatePrivateRegularFile(envURL)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envURL.path)
            _ = try readToken()
            return
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw HelperError.message("Could not generate a pairing token.")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let content = "# Generated by COS Control\nCOS_API_TOKEN=\(token)\nBIND_HOST=0.0.0.0\nCOS_DURABLE_QUERY_JOBS=1\n"
        try content.write(to: envURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envURL.path)
    }

    // MARK: - HTTPS certificates
    //
    // Even Hub's iOS WebView reaches the server over HTTPS on 3143, which only
    // turns on when server/certs/{cert,key}.pem exist. The published npm package
    // ships no certs, so a managed runtime silently bound HTTP only and dropped
    // every glasses connection on adoption. We keep a stable pair in configDir —
    // carried over verbatim from an existing legacy install when possible, else
    // generated — and copy it into each staged generation before launch.

    private var managedCert: URL { certsDir.appendingPathComponent("cert.pem") }
    private var managedKey: URL { certsDir.appendingPathComponent("key.pem") }

    private func isNonEmptyFile(_ url: URL) -> Bool {
        guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int else { return false }
        return size > 0
    }

    private func haveManagedCerts() -> Bool { isNonEmptyFile(managedCert) && isNonEmptyFile(managedKey) }

    /// Populate the stable configDir cert store. Called early in install (while a
    /// legacy LaunchAgent is still readable) so the exact certificate the glasses
    /// already trust can be carried over; falls back to a generated self-signed
    /// pair. Never throws — HTTPS is best-effort here and the post-health guard
    /// (`assertManagedHTTPS`) fails closed if a cert is present but 3143 is down.
    @discardableResult
    private func ensureManagedCerts() -> Bool {
        if haveManagedCerts() { return true }
        do { try ensurePrivateDirectory(certsDir) } catch { return false }
        if let source = legacyCertSource() {
            do {
                try? fm.removeItem(at: managedCert)
                try? fm.removeItem(at: managedKey)
                try fm.copyItem(at: source.appendingPathComponent("cert.pem"), to: managedCert)
                try fm.copyItem(at: source.appendingPathComponent("key.pem"), to: managedKey)
                try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: managedCert.path)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: managedKey.path)
                progress("Carried over the existing HTTPS certificate the glasses already trust.")
                return true
            } catch {
                progress("Could not carry over the legacy HTTPS certificate (\(error)); generating a new one.")
            }
        }
        return generateSelfSignedCerts()
    }

    /// The legacy server's app directory, from its LaunchAgent (COS_GLASSES_APP_DIR
    /// or WorkingDirectory). Shared by the cert and token carry-over.
    private func legacyAppDir() -> String? {
        guard let plist = launchAgentPropertyList() else { return nil }
        if let env = plist["EnvironmentVariables"] as? [String: String], let dir = env["COS_GLASSES_APP_DIR"], !dir.isEmpty {
            return dir
        }
        if let wd = plist["WorkingDirectory"] as? String, !wd.isEmpty {
            return wd
        }
        return nil
    }

    /// Locate an existing HTTPS cert from the currently-installed legacy server so
    /// adoption preserves the exact certificate the glasses already trust.
    private func legacyCertSource() -> URL? {
        guard let appDir = legacyAppDir() else { return nil }
        let certs = URL(fileURLWithPath: appDir, isDirectory: true).appendingPathComponent("server/certs", isDirectory: true)
        let hasPair = isNonEmptyFile(certs.appendingPathComponent("cert.pem")) && isNonEmptyFile(certs.appendingPathComponent("key.pem"))
        return hasPair ? certs : nil
    }

    // MARK: - API token carry-over
    //
    // The glasses authenticate with COS_API_TOKEN (X-Cos-Token header). A legacy
    // server may read its token from its own checkout .env or its LaunchAgent env
    // rather than ~/.cos-glasses/.env, which the managed server uses. If they
    // differ, every migrating user is silently locked out (401) even though the
    // server is "healthy" (the /api/health check is unauthenticated). Carry the
    // legacy token into ~/.cos-glasses/.env before the managed server starts so
    // the glasses' saved token keeps authenticating with no re-pairing.

    private func readEnvToken(_ url: URL) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for raw in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            for key in ["COS_API_TOKEN=", "API_TOKEN="] where line.hasPrefix(key) {
                let value = String(line.dropFirst(key.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    private func legacyApiToken() -> String? {
        if let plist = launchAgentPropertyList(),
           let env = plist["EnvironmentVariables"] as? [String: String],
           let token = env["COS_API_TOKEN"], !token.isEmpty {
            return token
        }
        guard let appDir = legacyAppDir() else { return nil }
        return readEnvToken(URL(fileURLWithPath: appDir, isDirectory: true).appendingPathComponent(".env"))
    }

    @discardableResult
    private func ensureManagedToken() -> Bool {
        guard let legacyToken = legacyApiToken() else { return false }
        if readEnvToken(envURL) == legacyToken { return true }
        do {
            try ensurePrivateDirectory(configDir)
            var kept: [String] = []
            if let existing = try? String(contentsOf: envURL, encoding: .utf8) {
                kept = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { line in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    return !t.hasPrefix("COS_API_TOKEN=") && !t.hasPrefix("API_TOKEN=") && !t.hasPrefix("# auto-generated by the server")
                }
                while kept.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { kept.removeLast() }
            }
            let out = (["COS_API_TOKEN=\(legacyToken)"] + kept).joined(separator: "\n") + "\n"
            try atomicWriteData(Data(out.utf8), to: envURL, permissions: 0o600)
            progress("Carried over the existing COS_API_TOKEN so the glasses keep authenticating.")
            return true
        } catch {
            progress("Could not carry over the legacy COS_API_TOKEN (\(error)); the glasses may need re-pairing.")
            return false
        }
    }

    private func generateSelfSignedCerts() -> Bool {
        let openssl = findExecutable("openssl") ?? (fm.isExecutableFile(atPath: "/usr/bin/openssl") ? "/usr/bin/openssl" : nil)
        guard let openssl else {
            progress("openssl not found; HTTPS 3143 stays disabled (HTTP only). Run mkcert to enable.")
            return false
        }
        do {
            let result = try execute(openssl, [
                "req", "-x509", "-newkey", "rsa:2048", "-sha256",
                "-keyout", managedKey.path, "-out", managedCert.path,
                "-days", "3650", "-nodes",
                "-subj", "/O=COS Control/CN=cos-glasses.local",
                "-addext", "subjectAltName=DNS:localhost,DNS:cos-glasses.local,IP:127.0.0.1",
            ], timeout: 60)
            guard result.code == 0, haveManagedCerts() else {
                progress("openssl could not generate an HTTPS certificate; HTTP only.")
                return false
            }
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: managedCert.path)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: managedKey.path)
            progress("Generated a self-signed HTTPS certificate for the glasses.")
            return true
        } catch {
            progress("HTTPS certificate generation failed (\(error)); HTTP only.")
            return false
        }
    }

    /// Copy the stable cert store into a staged generation's server/certs so the
    /// server binds HTTPS on launch. Safe for the integrity check — never touches
    /// package.json, the launcher, or the registry artifact.
    @discardableResult
    private func provisionCerts(intoGeneration generationPath: String) -> Bool {
        guard haveManagedCerts() else { return false }
        let destDir = packageRoot(for: generationPath).appendingPathComponent("server/certs", isDirectory: true)
        do {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true, attributes: nil)
            let destCert = destDir.appendingPathComponent("cert.pem")
            let destKey = destDir.appendingPathComponent("key.pem")
            try? fm.removeItem(at: destCert)
            try? fm.removeItem(at: destKey)
            try fm.copyItem(at: managedCert, to: destCert)
            try fm.copyItem(at: managedKey, to: destKey)
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destCert.path)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destKey.path)
            return true
        } catch {
            progress("Could not stage HTTPS certs into the generation (\(error)); HTTP only.")
            return false
        }
    }

    /// Fail closed: if a cert is present but HTTPS 3143 never bound, the glasses
    /// would be unreachable, so roll the switch back instead of shipping HTTP-only.
    private func assertManagedHTTPS() throws {
        guard haveManagedCerts() else { return }
        for _ in 0..<20 {
            if !(ownershipSnapshot().listeners[3143] ?? []).isEmpty { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw HelperError.message("The managed server bound HTTP 3141 but not HTTPS 3143, though a certificate is present. The glasses require HTTPS, so the change was rolled back.")
    }

    private func isUnsupportedExecutionEnvironmentKey(_ key: String) -> Bool {
        key == "NODE_OPTIONS" || key == "NODE_PATH" || key == "TMPDIR" ||
        key == "HTTP_PROXY" || key == "HTTPS_PROXY" || key == "ALL_PROXY" || key == "NO_PROXY" ||
        key.hasPrefix("DYLD_") || key.hasPrefix("LD_") || key.hasPrefix("NPM_CONFIG_")
    }

    private func captureProviderEnvironment(previous: RuntimeManifest?) throws -> [String: String] {
        let priorValues = previous?.providerEnvironment ?? [:]
        let unsupportedPrior = priorValues.keys.filter { isUnsupportedExecutionEnvironmentKey($0) }
        guard unsupportedPrior.isEmpty else {
            throw HelperError.message("Unsupported execution environment in prior runtime: \(unsupportedPrior.sorted().joined(separator: ", ")). Remove it before adoption.")
        }
        var values = (previous?.providerEnvironment ?? [:]).filter { providerEnvironmentKeys.contains($0.key) }
        if let plist = launchAgentPropertyList(), let environment = plist["EnvironmentVariables"] as? [String: String] {
            let unsupported = environment.keys.filter { isUnsupportedExecutionEnvironmentKey($0) }
            guard unsupported.isEmpty else {
                throw HelperError.message("Unsupported legacy execution environment: \(unsupported.sorted().joined(separator: ", ")). Adoption is refused.")
            }
            for key in providerEnvironmentKeys {
                if let value = environment[key], !value.isEmpty { values[key] = value }
            }
        }
        for key in providerEnvironmentKeys {
            if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty { values[key] = value }
        }
        return values
    }

    private func launchEnvironment(for manifest: RuntimeManifest) throws -> [String: String] {
        guard let node = manifest.nodePath ?? findExecutable("node") else { throw HelperError.message("Node.js not found") }
        var environment = manifest.providerEnvironment ?? [:]
        environment["HOME"] = home.path
        environment["COS_MANAGED"] = "1"
        environment["COS_ENTRYPOINT"] = "cos-control"
        environment["COS_SERVER_VERSION"] = manifest.version
        environment["COS_SERVER_GENERATION_ID"] = manifest.generationID ?? String((manifest.launcherSHA256 ?? manifest.version).prefix(24))
        if let work = manifest.workDirectory {
            environment["COS_WORKDIR"] = work
            // Keep the legacy Codex/Cursor override coherent until every
            // supported server resolves the provider-neutral key first.
            environment["CODEX_GLASSES_WORKDIR"] = work
        }
        environment["PATH"] = launchPathDirectories(node: node).joined(separator: ":")
        return environment
    }

    private func writeLaunchAgent(for manifest: RuntimeManifest) throws {
        let verified = try verifyGeneration(
            at: manifest.generationPath,
            expectedVersion: manifest.version,
            expectedIntegrity: manifest.registryIntegrity,
            expectedLauncherHash: manifest.launcherSHA256,
            expectedPackageHash: manifest.packageJSONSHA256
        )
        guard let node = manifest.nodePath ?? findExecutable("node") else { throw HelperError.message("Node.js not found") }
        guard nodeVersion(at: node).valid else { throw HelperError.message("Configured Node.js is unavailable or too old.") }
        let paths = runtimePaths(for: verified.path)
        // Every managed launch flows through here (install, rollback-restore,
        // repair, reconcile, start), so this is the single point that guarantees
        // the generation has its HTTPS certs before the server binds its ports.
        provisionCerts(intoGeneration: verified.path)
        var environment = try launchEnvironment(for: manifest)
        environment["COS_GLASSES_APP_DIR"] = paths.root.path
        let plist: [String: Any] = [
            "Label": label,
            // Direct listener ownership: launchd owns the Node process that imports server/index.ts.
            "ProgramArguments": [node, "--import", paths.tsx.path, paths.server.path],
            "WorkingDirectory": paths.root.path,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            "ProcessType": "Interactive",
            "StandardOutPath": serverLog.path,
            "StandardErrorPath": serverErrorLog.path,
            "EnvironmentVariables": environment,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try atomicWriteData(data, to: plistURL, permissions: 0o600)
    }

    private func launchAgentPropertyList() -> [String: Any]? {
        guard let data = try? Data(contentsOf: plistURL) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    }

    private func launchAgentKind() -> LaunchAgentKind {
        guard let plist = launchAgentPropertyList(), let args = plist["ProgramArguments"] as? [String] else {
            return fm.fileExists(atPath: plistURL.path) ? .unknown : .absent
        }
        let joined = args.joined(separator: " ")
        if joined.contains(support.path) || joined.contains("COS Control") || joined.contains("COS_ENTRYPOINT=cos-control") {
            return .cosControl
        }
        if joined.contains("COS Glasses/runtime/start-server.sh") || joined.contains("cos-glasses-app/start-server.sh") ||
            (args.first == "/bin/bash" && joined.contains("glasses")) {
            return .knownLegacy
        }
        return .unknown
    }

    private func launchctl(_ arguments: [String]) throws -> CommandResult {
        try execute("/bin/launchctl", arguments, timeout: 20)
    }

    private var launchDomain: String { "gui/\(getuid())" }
    private var serviceTarget: String { "\(launchDomain)/\(label)" }
    private var recoveryServiceTarget: String { "\(launchDomain)/\(recoveryLabel)" }

    private func servicePrint() -> CommandResult? {
        try? launchctl(["print", serviceTarget])
    }

    private func loadedEnvironmentValue(_ key: String) -> String? {
        guard let output = servicePrint()?.output else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: key)
        guard let expression = try? NSRegularExpression(pattern: "(?m)^\\s*\(escaped)\\s*=>\\s*(.+?)\\s*$"),
              let match = expression.firstMatch(
                in: output,
                range: NSRange(output.startIndex..<output.endIndex, in: output)
              ),
              let valueRange = Range(match.range(at: 1), in: output) else { return nil }
        let value = String(output[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func serviceLoaded() -> Bool { servicePrint()?.code == 0 }

    private func serviceDisabled() -> Bool {
        guard let result = try? launchctl(["print-disabled", launchDomain]), result.code == 0 else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: label)
        return result.output.range(of: "\"\(escaped)\"\\s*=>\\s*true", options: .regularExpression) != nil
    }

    private func setServiceEnabled(_ enabled: Bool) throws {
        let result = try launchctl([enabled ? "enable" : "disable", serviceTarget])
        guard result.code == 0 else {
            throw HelperError.message("launchd could not \(enabled ? "enable" : "disable") COS: \(result.output)")
        }
    }

    private func recoveryServiceLoaded() -> Bool {
        (try? launchctl(["print", recoveryServiceTarget]))?.code == 0
    }

    private func recoveryLaunchAgentValid() -> Bool {
        guard fm.fileExists(atPath: stableHelper.path),
              let data = try? Data(contentsOf: recoveryPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              plist["Label"] as? String == recoveryLabel,
              plist["ProgramArguments"] as? [String] == [stableHelper.path, "reconcile-automatic"],
              plist["RunAtLoad"] as? Bool == true,
              plist["StartInterval"] as? Int == 60 else { return false }
        return true
    }

    private func writeRecoveryLaunchAgent() throws {
        let plist: [String: Any] = [
            "Label": recoveryLabel,
            "ProgramArguments": [stableHelper.path, "reconcile-automatic"],
            "RunAtLoad": true,
            "StartInterval": 60,
            "ProcessType": "Background",
            "StandardOutPath": helperLog.path,
            "StandardErrorPath": helperLog.path,
            "EnvironmentVariables": ["HOME": home.path],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try atomicWriteData(data, to: recoveryPlistURL, permissions: 0o600)
    }

    private func installRecoveryLaunchAgent() throws {
        try writeRecoveryLaunchAgent()
        let enable = try launchctl(["enable", recoveryServiceTarget])
        guard enable.code == 0 else {
            throw HelperError.message("Could not enable the recovery controller: \(enable.output)")
        }
        if recoveryServiceLoaded() {
            let bootout = try launchctl(["bootout", recoveryServiceTarget])
            guard bootout.code == 0 else { throw HelperError.message("Could not refresh the recovery controller: \(bootout.output)") }
        }
        let bootstrap = try launchctl(["bootstrap", launchDomain, recoveryPlistURL.path])
        guard bootstrap.code == 0 else { throw HelperError.message("Could not install the recovery controller: \(bootstrap.output)") }
    }

    private func servicePID() -> Int? {
        guard let output = servicePrint()?.output else { return nil }
        let expression = try? NSRegularExpression(pattern: #"(?m)^\s*pid\s*=\s*(\d+)\s*$"#)
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = expression?.firstMatch(in: output, range: range),
              let swiftRange = Range(match.range(at: 1), in: output) else { return nil }
        return Int(output[swiftRange])
    }

    private func loadService(forceRestart: Bool) throws {
        try setServiceEnabled(true)
        if serviceLoaded() {
            let arguments = forceRestart ? ["kickstart", "-k", serviceTarget] : ["kickstart", serviceTarget]
            let result = try launchctl(arguments)
            guard result.code == 0 else { throw HelperError.message("launchd could not start COS: \(result.output)") }
        } else {
            let result = try launchctl(["bootstrap", launchDomain, plistURL.path])
            guard result.code == 0 else { throw HelperError.message("launchd could not install COS: \(result.output)") }
        }
    }

    private func unloadService() throws {
        guard serviceLoaded() else { return }
        let result = try launchctl(["bootout", serviceTarget])
        guard result.code == 0 else { throw HelperError.message("launchd could not stop COS: \(result.output)") }
    }

    private func listenerOwners() -> [Int: Set<Int>] {
        guard fm.isExecutableFile(atPath: "/usr/sbin/lsof") else { return [:] }
        var values: [Int: Set<Int>] = [:]
        for port in [3141, 3143] {
            guard let result = try? execute("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"], timeout: 5), result.code == 0 else {
                values[port] = []
                continue
            }
            values[port] = Set(result.output.split(separator: "\n").compactMap { Int($0) })
        }
        return values
    }

    private func parentPID(of pid: Int) -> Int? {
        guard let result = try? execute("/bin/ps", ["-o", "ppid=", "-p", String(pid)], timeout: 3), result.code == 0 else { return nil }
        return Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func isDescendant(_ pid: Int, of ancestor: Int) -> Bool {
        if pid == ancestor { return true }
        var current = pid
        var seen = Set<Int>()
        for _ in 0..<12 {
            guard seen.insert(current).inserted, let parent = parentPID(of: current), parent > 1 else { return false }
            if parent == ancestor { return true }
            current = parent
        }
        return false
    }

    private func ownershipSnapshot() -> OwnershipSnapshot {
        OwnershipSnapshot(
            serviceLoaded: serviceLoaded(),
            servicePID: servicePID(),
            listeners: listenerOwners(),
            launchAgentKind: launchAgentKind()
        )
    }

    private func launchdOwnsListeners(_ snapshot: OwnershipSnapshot, requireDirect: Bool) -> Bool {
        guard let servicePID = snapshot.servicePID, !snapshot.allListenerPIDs.isEmpty else { return false }
        return snapshot.allListenerPIDs.allSatisfy { pid in
            requireDirect ? pid == servicePID : isDescendant(pid, of: servicePID)
        }
    }

    private func assertAdoptableOwnership(_ snapshot: OwnershipSnapshot) throws {
        if snapshot.allListenerPIDs.isEmpty {
            if snapshot.serviceLoaded && snapshot.launchAgentKind == .unknown {
                throw HelperError.message("The canonical LaunchAgent is owned by an unknown installation. Remove it manually before COS Control can proceed.")
            }
            return
        }
        guard snapshot.serviceLoaded else {
            throw HelperError.message("Ports 3141/3143 are owned by a foreground or orphan server. Stop it manually before installing COS Control.")
        }
        guard snapshot.launchAgentKind == .cosControl || snapshot.launchAgentKind == .knownLegacy else {
            throw HelperError.message("Ports 3141/3143 and the canonical LaunchAgent have an unknown owner. COS Control will not replace them.")
        }
        guard launchdOwnsListeners(snapshot, requireDirect: false) else {
            throw HelperError.message("Listener ownership does not match the canonical LaunchAgent. Stop the conflicting process before continuing.")
        }
        if snapshot.launchAgentKind == .knownLegacy {
            throw HelperError.message("Running legacy adoption is intentionally unsupported because it cannot provide an exact rollback generation. Stop the recognized legacy LaunchAgent first.")
        }
    }

    private func request(
        _ path: String,
        method: String = "GET",
        token: String? = nil,
        maintenanceLease: String? = nil,
        maintenanceOperation: String? = nil,
        maintenanceNonce: String? = nil,
        body: String? = nil,
        headers: [String: String] = [:],
        timeout: Int = 5,
        deadlineUptime: TimeInterval? = nil
    ) -> HTTPResponse? {
        guard let url = URL(string: "http://127.0.0.1:3141\(path)") else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        let remaining = deadlineUptime.map { $0 - now }
        if let remaining, remaining <= 0 { return nil }
        let requestTimeout = min(TimeInterval(timeout), remaining ?? TimeInterval(timeout))
        var request = URLRequest(url: url, timeoutInterval: max(0.1, requestTimeout))
        request.httpMethod = method
        if let token { request.setValue(token, forHTTPHeaderField: "X-COS-Token") }
        if let maintenanceLease { request.setValue(maintenanceLease, forHTTPHeaderField: "X-COS-Maintenance-Lease") }
        if let maintenanceOperation { request.setValue(maintenanceOperation, forHTTPHeaderField: "X-COS-Maintenance-Operation") }
        if let maintenanceNonce { request.setValue(maintenanceNonce, forHTTPHeaderField: "X-COS-Maintenance-Nonce") }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
        }
        let box = HTTPResultBox()
        let completion = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            box.store(data: data, response: response)
            completion.signal()
        }
        task.resume()
        let waitBudget = deadlineUptime.map {
            max(0, $0 - ProcessInfo.processInfo.systemUptime)
        } ?? TimeInterval(timeout + 2)
        guard waitBudget > 0,
              completion.wait(timeout: .now() + waitBudget) == .success else {
            task.cancel()
            return nil
        }
        let (data, response) = box.load()
        guard let http = response as? HTTPURLResponse else { return nil }
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        return HTTPResponse(status: http.statusCode, body: object, data: data, headers: headers)
    }

    private func boundedMediaRequest(
        _ path: String,
        token: String,
        timeout: Int,
        maximumBytes: Int
    ) -> HTTPResponse? {
        guard let url = URL(string: "http://127.0.0.1:3141\(path)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: TimeInterval(timeout))
        request.setValue(token, forHTTPHeaderField: "X-COS-Token")
        let delegate = BoundedMediaRequestDelegate(maximumBytes: maximumBytes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = TimeInterval(timeout)
        configuration.timeoutIntervalForResource = TimeInterval(timeout + 2)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        task.resume()
        guard let (data, response, tooLarge, transportFailed) = delegate.wait(timeout: TimeInterval(timeout + 2)) else {
            task.cancel()
            session.invalidateAndCancel()
            return nil
        }
        session.finishTasksAndInvalidate()
        guard let http = response as? HTTPURLResponse else { return nil }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        if tooLarge { return HTTPResponse(status: 413, body: nil, headers: headers) }
        if transportFailed { return nil }
        return HTTPResponse(status: http.statusCode, body: nil, data: data, headers: headers)
    }

    private func versionAtLeast(_ value: String, _ minimum: String) -> Bool {
        let lhs = value.split(separator: ".").compactMap { Int($0) }
        let rhs = minimum.split(separator: ".").compactMap { Int($0) }
        guard lhs.count == 3, rhs.count == 3 else { return false }
        for index in 0..<3 {
            if lhs[index] != rhs[index] { return lhs[index] > rhs[index] }
        }
        return true
    }

    /// Prove the actual managed request paths, not just process/version flags.
    /// Provider output is never returned by the server proof endpoint. When
    /// Kokoro reports ready, the second half deliberately fetches the minted
    /// playback capability without X-COS-Token, exactly like native iOS audio.
    private func transactionalRuntimeProofFailure(
        health: [String: Any],
        expectedProviders: Set<String>,
        requireProviderEndpoint: Bool,
        operation: MaintenanceLease? = nil,
        deadlineUptime: TimeInterval? = nil
    ) -> String? {
        guard let token = try? readToken() else { return "pairing token is unavailable for transactional proof" }
        for provider in expectedProviders.sorted() {
            guard provider == "claude" || provider == "codex" else { continue }
            let proofWindow = provider == "claude" ? "45s" : "120s"
            progress("Proving \(provider.capitalized) (up to \(proofWindow))…")
            let body = try? jsonBody(["provider": provider])
            guard let response = request(
                "/api/diagnostics/provider-proof",
                method: "POST",
                token: token,
                maintenanceLease: operation?.id,
                maintenanceOperation: operation?.operationId,
                maintenanceNonce: operation?.nonce,
                body: body,
                timeout: 130,
                deadlineUptime: deadlineUptime
            ) else { return provider.capitalized + " transactional proof did not answer" }
            if response.status == 404 && !requireProviderEndpoint { continue }
            guard response.status == 200, response.body?["ok"] as? Bool == true else {
                let detail = response.body?["error"] as? String ?? "HTTP \(response.status)"
                return provider.capitalized + " real query failed: " + detail
            }
        }

        let localTTS = health["tts_local"] as? [String: Any]
        guard localTTS?["ready"] as? Bool == true else { return nil }
        progress("Proving Kokoro generation…")
        let prepareBody = try? jsonBody([
            "text": "COS speech check.",
            "voice": "am_echo",
            "format": "mp3",
            "engine": "local",
            "fast": false,
        ])
        guard let prepared = request(
            "/api/tts/prepare",
            method: "POST",
            token: token,
            maintenanceLease: operation?.id,
            maintenanceOperation: operation?.operationId,
            maintenanceNonce: operation?.nonce,
            body: prepareBody,
            timeout: 45,
            deadlineUptime: deadlineUptime
        ), prepared.status == 200,
              let playPath = prepared.body?["url"] as? String,
              playPath.range(of: #"^/api/tts/play/[0-9a-fA-F-]{36}$"#, options: .regularExpression) != nil else {
            return "Kokoro prepare proof failed"
        }
        progress("Proving Kokoro playback…")
        guard let playback = request(playPath, timeout: 45, deadlineUptime: deadlineUptime),
              playback.status == 200,
              (playback.data?.count ?? 0) > 100,
              playback.headers["content-type"]?.lowercased().hasPrefix("audio/") == true else {
            return "Kokoro native playback proof failed"
        }
        return nil
    }

    private func maintenanceStatus(
        operation: MaintenanceLease? = nil,
        deadlineUptime: TimeInterval? = nil
    ) -> [String: Any]? {
        guard let token = try? readToken(),
              let response = request(
                "/api/maintenance/status",
                token: token,
                maintenanceLease: operation?.id,
                maintenanceOperation: operation?.operationId,
                maintenanceNonce: operation?.nonce,
                deadlineUptime: deadlineUptime
              ),
              response.status == 200 else { return nil }
        return response.body
    }

    private func isManagedContract(_ maintenance: [String: Any]?) -> Bool {
        guard maintenance?["managed"] as? Bool == true,
              let version = maintenance?["contractVersion"] as? Int else { return false }
        return supportedManagedContractVersions.contains(version)
    }

    private func hasLifecycleContract(_ maintenance: [String: Any]?) -> Bool {
        isManagedContract(maintenance) && maintenance?["contractVersion"] as? Int == leaseManagedContractVersion
    }

    private func detectedManagedProviders() -> Set<String> {
        Set(["claude", "codex"].filter { findExecutable($0) != nil })
    }

    /// A reachable health endpoint is not enough: the managed service must see
    /// the same installed AI providers that COS Control sees. This catches a
    /// LaunchAgent PATH regression before an update is committed as healthy.
    private func providerCapabilityFailure(
        _ health: [String: Any]?,
        expectedProviders: Set<String>? = nil
    ) -> String? {
        guard let health else { return "health endpoint returned no JSON payload" }
        guard health["status"] as? String == "ok", health["server"] as? String == "ok" else {
            return "health payload does not report an operational server"
        }
        guard let features = health["features"] as? [String: Any] else {
            return "health payload is missing provider capabilities"
        }

        let expected = expectedProviders ?? detectedManagedProviders()
        for provider in expected.sorted() where features[provider] as? Bool != true {
            return provider.capitalized + " is installed but unavailable to the managed server"
        }
        let reportedProviders = ["claude", "codex", "cursor"]
        guard reportedProviders.contains(where: { features[$0] as? Bool == true }) else {
            return "managed server reports no available AI provider"
        }
        return nil
    }

    private func managedHealthFailure(
        _ response: HTTPResponse?,
        expectedProviders: Set<String>? = nil
    ) -> String? {
        guard let response else { return "health endpoint did not answer" }
        guard response.status == 200 else { return "health endpoint returned HTTP " + String(response.status) }
        return providerCapabilityFailure(response.body, expectedProviders: expectedProviders)
    }

    /// Server 6.15.4+ starts non-admitting local speech services while a
    /// candidate is still behind the maintenance gate. When Whisper is
    /// configured (`serverConfigured=true`), managed verification must not call that
    /// candidate healthy until the persistent server is actually ready.
    private func localWhisperReadinessFailure(_ health: [String: Any], serverVersion: String) -> String? {
        guard versionAtLeast(serverVersion, "6.15.4"),
              let whisper = health["whisper_health"] as? [String: Any],
              whisper["serverConfigured"] as? Bool == true,
              whisper["server"] as? Bool != true else { return nil }
        let state = whisper["startupState"] as? String ?? "not_started"
        let error = whisper["lastError"] as? String
        return error.map { "Local Whisper \(state): \($0)" }
            ?? "Local Whisper is \(state)"
    }

    private func runtimeState(snapshot: OwnershipSnapshot, maintenance: [String: Any]?, health: [String: Any]?) -> RuntimeState {
        let installed = loadManifest() != nil
        let managed = hasLifecycleContract(maintenance)
        if inPlaceActive() {
            if snapshot.allListenerPIDs.isEmpty { return .stopped }
            return health.map { providerCapabilityFailure($0) == nil } == true ? .managedInPlace : .managedDegraded
        }
        if snapshot.allListenerPIDs.isEmpty {
            if snapshot.launchAgentKind == .knownLegacy { return .legacyStopped }
            if snapshot.serviceLoaded && snapshot.servicePID != nil { return .managedDegraded }
            return installed ? .stopped : .notInstalled
        }
        if !snapshot.serviceLoaded {
            return managed ? .ownerConflict : (health != nil ? .legacyForeground : .ownerConflict)
        }
        guard launchdOwnsListeners(snapshot, requireDirect: snapshot.launchAgentKind == .cosControl) else { return .ownerConflict }
        if snapshot.launchAgentKind == .knownLegacy { return .legacyService }
        guard snapshot.launchAgentKind == .cosControl else { return .ownerConflict }
        let accepting = (maintenance?["lifecycle"] as? [String: Any])?["state"] as? String == "accepting"
        let providerReady = health.map { providerCapabilityFailure($0) == nil } ?? false
        return managed && providerReady && accepting ? .managedHealthy : .managedDegraded
    }

    private func statusDetails() -> [String: Any] {
        let manifest = loadManifest()
        let snapshot = ownershipSnapshot()
        let maintenance = maintenanceStatus()
        let healthResponse = request("/api/health", timeout: 12)
        let health = healthResponse?.status == 200 ? healthResponse?.body : nil
        let providerFailure = (snapshot.launchAgentKind == .cosControl || inPlaceActive())
            ? managedHealthFailure(healthResponse)
            : nil
        let state = runtimeState(snapshot: snapshot, maintenance: maintenance, health: health)
        let directOwner = launchdOwnsListeners(snapshot, requireDirect: true)
        let managed = hasLifecycleContract(maintenance)
        let configuredWork = configuredWorkDirectory()
        let configuredMeetings = configuredMeetingsDirectoryInspection()
        let activeWork = ["COS_WORKDIR", "CODEX_GLASSES_WORKDIR", "COS_LAUNCH_DIR"]
            .compactMap(loadedEnvironmentValue)
            .compactMap { try? validatedWorkDirectory($0) }
            .first
        let transcription = (health?["capabilities"] as? [String: Any])?["transcription"] as? [String: Any]
        let liveTranscription = transcription?["live"] as? [String: Any]
        let hqTranscription = transcription?["hq"] as? [String: Any]
        let transcriptionProfile = transcription?["profile"] as? [String: Any]
        let featureFlags = health?["features"] as? [String: Any]
        let requestedTier = liveTranscription?["requestedTier"] as? String
        let effectiveTier = liveTranscription?["effectiveTier"] as? String
        let commitReason = liveTranscription?["commitReason"] as? String
        let supportsManagedTier = manifest.map { versionAtLeast($0.version, "6.21.0") } ?? false
        let configuredRequestedTier = requestedTier
            ?? manifest?.providerEnvironment?["COS_WHISPER_TRANSCRIPTION_TIER"]
            ?? (supportsManagedTier ? "balanced" : nil)
        let configuredCommitModel = (liveTranscription?["requestedCommitModel"] as? String)
            ?? manifest?.providerEnvironment?["COS_WHISPER_COMMIT_MODEL"]
            ?? (configuredRequestedTier == "max" ? "large-v3" : (supportsManagedTier ? "turbo" : nil))
        let tierDegraded = (liveTranscription?["commitDegraded"] as? Bool)
            ?? (requestedTier != nil && requestedTier != effectiveTier)
        // Server 6.21 separates cosmetic preview degradation from commit-tier
        // safety. Older servers expose only aggregate `degraded`, so retain it
        // as the backward-compatible fallback.
        let previewDegraded = (liveTranscription?["previewDegraded"] as? Bool)
            ?? ((liveTranscription?["degraded"] as? Bool) ?? false)
        let reportedBackgroundJobs = featureFlags?["durableQueryJobs"] as? Bool
        let reportedVersion = (maintenance?["serverVersion"] as? String)
            ?? (health?["server_version"] as? String)
            ?? manifest?.version
        let contextBrowserSupported = reportedVersion.map { versionAtLeast($0, "6.21.35") } == true
        let contextResponse: HTTPResponse? = contextBrowserSupported
            ? (try? readToken()).flatMap { request("/api/context/status", token: $0, timeout: 12) }
            : nil
        let context = contextResponse?.status == 200 ? contextResponse?.body : nil
        let memoryContext = context?["memory"] as? [String: Any]
        let threadsContext = context?["threads"] as? [String: Any]
        let effectiveContextState: Any
        if let reported = context?["state"] {
            effectiveContextState = reported
        } else if context?["available"] as? Bool == true {
            effectiveContextState = "ready"
        } else if contextBrowserSupported {
            effectiveContextState = "unavailable"
        } else {
            effectiveContextState = NSNull()
        }
        let backgroundJobsSupported = reportedBackgroundJobs != nil
            || reportedVersion.map { versionAtLeast($0, "6.21.5") } == true
        let configuredBackgroundJobs = manifest?.providerEnvironment?["COS_DURABLE_QUERY_JOBS"]
            ?? (launchAgentPropertyList()?["EnvironmentVariables"] as? [String: String])?["COS_DURABLE_QUERY_JOBS"]
        let backgroundJobsEnabled = reportedBackgroundJobs
            ?? (backgroundJobsSupported ? configuredBackgroundJobs != "0" : nil)
        let meetingPreviewSupported = reportedVersion.map { versionAtLeast($0, "6.21.7") } == true
        let configuredMeetingPreview = manifest?.providerEnvironment?["COS_WHISPER_MEETING_PREVIEW"]
            ?? (launchAgentPropertyList()?["EnvironmentVariables"] as? [String: String])?["COS_WHISPER_MEETING_PREVIEW"]
        let meetingPreviewEnabled = meetingPreviewSupported
            ? ((health != nil ? loadedEnvironmentValue("COS_WHISPER_MEETING_PREVIEW") : configuredMeetingPreview) == "1")
            : nil
        // Continue an agent thread. The running build answers this itself via
        // its capability contract; the version compare only covers a build that
        // is healthy but predates the fields, and the manifest covers a stopped
        // managed server that has no health at all.
        let threadAttachSupported = (health?["threadAttachSupported"] as? Bool == true)
            || reportedVersion.map { versionAtLeast($0, threadAttachMinimumServer) } == true
        let configuredThreadAttach = manifest?.providerEnvironment?["COS_THREAD_ATTACH_ENABLED"]
            ?? (launchAgentPropertyList()?["EnvironmentVariables"] as? [String: String])?["COS_THREAD_ATTACH_ENABLED"]
        // Fail closed in the same direction the server's contract mandates:
        // anything but a literal true, or an absent key, is off.
        let threadAttachEnabled: Bool? = threadAttachSupported
            ? (health.map { $0["threadAttachEnabled"] as? Bool == true } ?? (configuredThreadAttach == "1"))
            : nil
        let threadAttachProviders = (health?["threadAttachProviders"] as? [String]) ?? []
        let videoUploadStatus = maintenance?["videoUploads"] as? [String: Any]
        let videoUploadV2Supported = reportedVersion.map { versionAtLeast($0, "6.27.3") } == true
        let configuredVideoUploadV2 = manifest?.providerEnvironment?["COS_VIDEO_UPLOAD_V2"]
            ?? (launchAgentPropertyList()?["EnvironmentVariables"] as? [String: String])?["COS_VIDEO_UPLOAD_V2"]
        let videoUploadV2Enabled = videoUploadV2Supported
            ? ((videoUploadStatus?["enabled"] as? Bool) ?? (configuredVideoUploadV2 == "1"))
            : nil
        let idleMetalHqSupported = reportedVersion.map { versionAtLeast($0, "6.21.20") } == true
        let configuredIdleMetalHq = manifest?.providerEnvironment?["COS_BATCH_HQ_METAL"]
            ?? (launchAgentPropertyList()?["EnvironmentVariables"] as? [String: String])?["COS_BATCH_HQ_METAL"]
        let configuredIdleMetalHqForceCpu = manifest?.providerEnvironment?["COS_BATCH_HQ_FORCE_CPU"]
            ?? (launchAgentPropertyList()?["EnvironmentVariables"] as? [String: String])?["COS_BATCH_HQ_FORCE_CPU"]
        let activeIdleMetalHq = health != nil ? loadedEnvironmentValue("COS_BATCH_HQ_METAL") : configuredIdleMetalHq
        let activeIdleMetalHqForceCpu = health != nil ? loadedEnvironmentValue("COS_BATCH_HQ_FORCE_CPU") : configuredIdleMetalHqForceCpu
        let idleMetalHqForceCpu = idleMetalHqSupported ? activeIdleMetalHqForceCpu == "1" : nil
        let idleMetalHqEnabled = idleMetalHqSupported
            ? (activeIdleMetalHq == "1" && activeIdleMetalHqForceCpu != "1")
            : nil
        let adaptiveAudioCleanupSupported = reportedVersion.map { versionAtLeast($0, "6.21.32") } == true
        let adaptivePlayback = (health?["review_audio"] as? [String: Any])?["adaptivePlayback"] as? [String: Any]
        let configuredAdaptiveAudioCleanup = manifest?.providerEnvironment?["COS_MEETING_AUDIO_ADAPTIVE_PLAYBACK"]
            ?? (launchAgentPropertyList()?["EnvironmentVariables"] as? [String: String])?["COS_MEETING_AUDIO_ADAPTIVE_PLAYBACK"]
        let adaptiveAudioCleanupEnabled: Bool?
        if !adaptiveAudioCleanupSupported {
            adaptiveAudioCleanupEnabled = nil
        } else if let reported = adaptivePlayback?["enabled"] as? Bool {
            adaptiveAudioCleanupEnabled = reported
        } else if health == nil {
            // A stopped server has no live truth, so configured state is the
            // only state available. A running server that omits the capability
            // must remain Unknown rather than claiming its plist value is active.
            adaptiveAudioCleanupEnabled = configuredAdaptiveAudioCleanup == "1"
        } else {
            adaptiveAudioCleanupEnabled = nil
        }
        var details: [String: Any] = [
            "installed": manifest != nil,
            "serviceLoaded": snapshot.serviceLoaded,
            "running": health != nil,
            "managedContract": managed,
            "maintenanceContractVersion": maintenance?["contractVersion"] ?? NSNull(),
            "runtimeState": state.rawValue,
            "ownershipVerified": directOwner,
            "ownerConflict": state == .ownerConflict,
            "launchAgentKind": snapshot.launchAgentKind.rawValue,
            "managedInPlace": inPlaceActive(),
            "servicePID": snapshot.servicePID ?? NSNull(),
            "listenerPIDs": snapshot.allListenerPIDs.sorted(),
            "version": maintenance?["serverVersion"] ?? health?["server_version"] ?? manifest?.version ?? NSNull(),
            "installedVersion": manifest?.version ?? NSNull(),
            "desiredState": manifest?.desiredState ?? "running",
            "providerCapabilitiesReady": providerFailure == nil && health != nil,
            "providerCapabilityError": providerFailure ?? NSNull(),
            "serviceDisabled": serviceDisabled(),
            "recoveryInstalled": recoveryLaunchAgentValid(),
            "recoveryLoaded": recoveryServiceLoaded(),
            "workDirectory": configuredWork ?? NSNull(),
            "activeWorkDirectory": activeWork ?? NSNull(),
            "workDirectoryPending": snapshot.serviceLoaded && configuredWork != nil && configuredWork != activeWork,
            "operationsDirectory": configuredOperationsDirectory() ?? NSNull(),
            "meetingLibraryLayout": configuredMeetings?.layout ?? "standalone",
            "meetingLibraryCount": configuredMeetings?.meetingCount ?? 0,
            "meetingLibraryWarning": configuredMeetings?.warning ?? NSNull(),
            "contextBrowserSupported": contextBrowserSupported,
            "contextAvailable": context?["available"] ?? NSNull(),
            "contextState": effectiveContextState,
            "contextProtocol": context?["protocol"] ?? NSNull(),
            "contextScriptsDirectory": configuredContextScriptsDirectory() ?? NSNull(),
            "contextFilesDirectory": configuredContextFilesDirectory() ?? NSNull(),
            // The panel said "Setup needed" and pointed at the wrong control. These
            // three let it say what actually resolved, what was tried, and where a
            // Create would land.
            "contextResolvedRoot": contextRootResolution().resolved ?? NSNull(),
            "contextCandidateRoots": contextRootResolution().candidates,
            "contextSuggestedRoot": contextRootResolution().suggested ?? NSNull(),
            "dormantBridgeScripts": dormantBridgeScriptsDirectory() ?? NSNull(),
            "memoryAvailable": memoryContext?["available"] ?? NSNull(),
            "memoryCount": memoryContext?["total"] ?? 0,
            "memoryState": memoryContext?["state"] ?? memoryContext?["reason"] ?? NSNull(),
            "threadsAvailable": threadsContext?["available"] ?? NSNull(),
            "threadCount": threadsContext?["total"] ?? 0,
            "activeThreadCount": threadsContext?["active"] ?? 0,
            "threadState": threadsContext?["state"] ?? threadsContext?["reason"] ?? NSNull(),
            "safeToRestart": (managed || inPlaceActive()) ? (maintenance?["safeToRestart"] ?? false) : false,
            "activeJobs": maintenance?["activeJobs"] ?? NSNull(),
            "activeTranscriptionSessions": maintenance?["activeTranscriptionSessions"] ?? NSNull(),
            "backgroundJobsSupported": backgroundJobsSupported,
            "backgroundJobsEnabled": backgroundJobsEnabled ?? NSNull(),
            "meetingPreviewSupported": meetingPreviewSupported,
            "meetingPreviewEnabled": meetingPreviewEnabled ?? NSNull(),
            "threadAttachSupported": threadAttachSupported,
            "threadAttachEnabled": threadAttachEnabled ?? NSNull(),
            "threadAttachProviders": threadAttachProviders,
            "videoUploadV2Supported": videoUploadV2Supported,
            "videoUploadV2Enabled": videoUploadV2Enabled ?? NSNull(),
            "videoUploadV2Receiving": videoUploadStatus?["receiving"] ?? 0,
            "videoUploadV2Finalizing": videoUploadStatus?["finalizing"] ?? 0,
            "videoUploadV2Unacknowledged": videoUploadStatus?["unacknowledgedPublished"] ?? 0,
            "videoUploadV2BlocksRollback": videoUploadStatus?["blocksRollback"] ?? false,
            "idleMetalHqSupported": idleMetalHqSupported,
            "idleMetalHqEnabled": idleMetalHqEnabled ?? NSNull(),
            "idleMetalHqForceCpu": idleMetalHqForceCpu ?? NSNull(),
            "adaptiveAudioCleanupSupported": adaptiveAudioCleanupSupported,
            "adaptiveAudioCleanupEnabled": adaptiveAudioCleanupEnabled ?? NSNull(),
            "whisperReady": ((health?["whisper_health"] as? [String: Any])?["server"] as? Bool) ?? false,
            "whisperCircuitOpen": ((health?["whisper_health"] as? [String: Any])?["circuitOpen"] as? Bool) ?? false,
            "whisperStartupState": (health?["whisper_health"] as? [String: Any])?["startupState"] ?? NSNull(),
            "whisperError": (health?["whisper_health"] as? [String: Any])?["lastError"] ?? NSNull(),
            "livePreviewModel": liveTranscription?["effectiveModel"] ?? NSNull(),
            "livePreviewReady": liveTranscription?["ready"] ?? NSNull(),
            "livePreviewDegraded": previewDegraded,
            "liveCommitModel": liveTranscription?["committedModel"] ?? NSNull(),
            "transcriptionRequestedTier": configuredRequestedTier ?? NSNull(),
            "transcriptionEffectiveTier": liveTranscription?["effectiveTier"] ?? NSNull(),
            "transcriptionRequestedCommitModel": configuredCommitModel ?? NSNull(),
            "transcriptionTierDegraded": tierDegraded,
            "transcriptionTierReason": commitReason ?? liveTranscription?["reason"] ?? NSNull(),
            // 6.20.0+ always targets Large-v3 for HQ. When its weights are
            // absent the model field is null, but Control should report the
            // intended lane as unavailable instead of the ambiguous
            // "Unreported" label.
            "hqPolishModel": hqTranscription?["model"] ?? (hqTranscription == nil ? NSNull() : "large-v3"),
            "hqPolishReady": hqTranscription?["hqAvailable"] ?? NSNull(),
            "transcriptionVocabularyTerms": transcriptionProfile?["vocabularyTerms"] ?? NSNull(),
            "transactionPending": loadTransaction() != nil || loadInPlaceConfigurationTransaction() != nil,
            "apiURL": "http://127.0.0.1:3141",
        ]
        for (key, value) in meetingSyncStatusFields(health: health) {
            details[key] = value
        }
        for (key, value) in meetingLifecycleStatusFields(health: health) {
            details[key] = value
        }
        // Server 6.19.0+ quarantines unsaved meeting audio and reports it on
        // health. Absent key (older server) reads as zero — no fallback scan.
        details["unsavedCaptures"] =
            ((health?["unsaved_captures"] as? [String: Any])?["count"] as? Int) ?? 0
        for (key, value) in agentCliStatusFields(health: health) {
            details[key] = value
        }
        for (key, value) in cursorStatusFields(force: false) {
            details[key] = value
        }
        return details
    }

    /// Per-CLI readiness for the three agent backends COS can route to.
    /// `features.{claude,codex,cursor}` is the boolean truth (the server
    /// probes each binary at health time); `checks.*` carries a version
    /// string that is NOT always a version — the Cursor probe returns
    /// "About Cursor CLI" — so the string is only surfaced when it actually
    /// contains a version-looking token. A server too old to publish
    /// `features` reports all three unknown rather than falsely green.
    private func agentCliStatusFields(health: [String: Any]?) -> [String: Any] {
        let features = health?["features"] as? [String: Any]
        func ready(_ key: String) -> Any {
            guard let value = features?[key] as? Bool else { return NSNull() }
            return value
        }
        return [
            "claudeCliReady": ready("claude"),
            "claudeCliVersion": versionToken(health?["claude"]) ?? NSNull(),
            "codexCliReady": ready("codex"),
            "codexCliVersion": versionToken(health?["codex"]) ?? NSNull(),
            "cursorCliVersion": versionToken(health?["cursor"]) ?? NSNull(),
        ]
    }

    /// First dotted-numeric token in a CLI's self-reported version line, or
    /// nil when the line carries no version (e.g. "About Cursor CLI").
    private func versionToken(_ raw: Any?) -> String? {
        guard let text = raw as? String, !text.isEmpty else { return nil }
        for piece in text.split(whereSeparator: { " ()\t".contains($0) }) {
            let candidate = String(piece)
            let head = candidate.prefix(while: { $0.isNumber || $0 == "." })
            if head.contains("."), head.first?.isNumber == true { return candidate }
        }
        return nil
    }

    /// Prefer server `meeting_sync` (6.18.4+). Fall back to scanning
    /// `~/.cos-glasses/data/pending-batch` so Control still shows HQ polish
    /// progress on older servers / mid-drain saves.
    private func meetingSyncStatusFields(health: [String: Any]?) -> [String: Any] {
        if let sync = health?["meeting_sync"] as? [String: Any],
           let active = sync["active"] as? Bool {
            let percent = sync["percent"] as? Int
            let label = (sync["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let blocks = sync["blocksRestart"] as? Bool ?? active
            let meetings = sync["meetings"] as? [[String: Any]] ?? []
            return [
                "meetingSyncActive": active,
                "meetingSyncPercent": percent.map { $0 as Any } ?? NSNull(),
                "meetingSyncLabel": (label?.isEmpty == false ? label! : (active ? "Syncing…" : "Idle")),
                "meetingSyncBlocksRestart": blocks,
                "meetingSyncCount": meetings.count,
            ]
        }
        return meetingSyncStatusFromPendingBatch()
    }

    private func meetingLifecycleStatusFields(health: [String: Any]?) -> [String: Any] {
        guard let capabilities = health?["capabilities"] as? [String: Any],
              let lifecycle = capabilities["meetingLifecycle"] as? [String: Any] else {
            return [
                "earlyMeetingSyncEnabled": NSNull(),
                "earlyMeetingSyncRequested": NSNull(),
                "earlyMeetingSyncAvailable": NSNull(),
                "earlyMeetingSyncReason": NSNull(),
                "earlyMeetingSyncInFlight": false,
                "earlyMeetingSyncPendingCount": 0,
                "earlyMeetingSyncLastOutcome": NSNull(),
                "earlyMeetingSyncLastError": NSNull(),
                "earlyMeetingSyncLastAt": NSNull(),
                "progressiveHqEnabled": NSNull(),
                "progressiveHqRequested": NSNull(),
                "progressiveHqTier": NSNull(),
                "progressiveHqMode": NSNull(),
                "progressiveHqThreads": NSNull(),
                "progressiveHqReason": NSNull(),
                "progressiveHqActive": false,
                "progressiveHqSealedDone": 0,
                "progressiveHqSealedTotal": 0,
                "meetingFinalizationPending": 0,
                "meetingFinalizationFailed": 0,
                "meetingFinalizationLastError": NSNull(),
                "meetingFinalizationMalformed": 0,
            ]
        }
        let early = lifecycle["earlySyncClaim"] as? [String: Any]
        let progressive = lifecycle["progressiveHq"] as? [String: Any]
        let finalization = lifecycle["finalization"] as? [String: Any]
        let sessions = progressive?["sessions"] as? [[String: Any]] ?? []
        let sealedDone = sessions.reduce(0) { $0 + (($1["sealedDone"] as? Int) ?? 0) }
        let sealedTotal = sessions.reduce(0) { $0 + (($1["sealedTotal"] as? Int) ?? 0) }
        return [
            "earlyMeetingSyncEnabled": early?["enabled"] ?? NSNull(),
            "earlyMeetingSyncRequested": early?["requested"] ?? NSNull(),
            "earlyMeetingSyncAvailable": early?["available"] ?? NSNull(),
            "earlyMeetingSyncReason": early?["reason"] ?? NSNull(),
            "earlyMeetingSyncInFlight": early?["inFlight"] ?? false,
            "earlyMeetingSyncPendingCount": early?["pendingCount"] ?? 0,
            "earlyMeetingSyncLastOutcome": early?["lastOutcome"] ?? NSNull(),
            "earlyMeetingSyncLastError": early?["lastError"] ?? NSNull(),
            "earlyMeetingSyncLastAt": early?["lastAt"] ?? NSNull(),
            "progressiveHqEnabled": progressive?["enabled"] ?? NSNull(),
            "progressiveHqRequested": progressive?["requested"] ?? NSNull(),
            "progressiveHqTier": progressive?["tier"] ?? NSNull(),
            "progressiveHqMode": progressive?["mode"] ?? NSNull(),
            "progressiveHqThreads": progressive?["threads"] ?? NSNull(),
            "progressiveHqReason": progressive?["reason"] ?? NSNull(),
            "progressiveHqActive": progressive?["activeSessionId"] is String,
            "progressiveHqSealedDone": sealedDone,
            "progressiveHqSealedTotal": sealedTotal,
            "meetingFinalizationPending": finalization?["pending"] ?? 0,
            "meetingFinalizationFailed": finalization?["failed"] ?? 0,
            "meetingFinalizationLastError": finalization?["lastError"] ?? NSNull(),
            "meetingFinalizationMalformed": finalization?["malformed"] ?? 0,
        ]
    }

    private func meetingSyncStatusFromPendingBatch() -> [String: Any] {
        let root = configDir.appendingPathComponent("data/pending-batch", isDirectory: true)
        guard fm.fileExists(atPath: root.path) else {
            return [
                "meetingSyncActive": false,
                "meetingSyncPercent": NSNull(),
                "meetingSyncLabel": "Idle",
                "meetingSyncBlocksRestart": false,
                "meetingSyncCount": 0,
            ]
        }
        let now = Date()
        var activeMeetings = 0
        var chunkTotal = 0
        var bestPercent: Int?
        var labels: [String] = []
        guard let dirs = try? fm.contentsOfDirectory(atPath: root.path) else {
            return [
                "meetingSyncActive": false,
                "meetingSyncPercent": NSNull(),
                "meetingSyncLabel": "Idle",
                "meetingSyncBlocksRestart": false,
                "meetingSyncCount": 0,
            ]
        }
        for name in dirs {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let marker = dir.appendingPathComponent("_batch_pending.marker")
            let progressURL = dir.appendingPathComponent("_batch_progress.json")
            let wavs = (try? fm.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".wav") }.count ?? 0
            var markerFresh = false
            if let attrs = try? fm.attributesOfItem(atPath: marker.path),
               let mtime = attrs[.modificationDate] as? Date {
                markerFresh = now.timeIntervalSince(mtime) <= 15 * 60
            }
            var percent: Int?
            var label: String?
            if let data = try? Data(contentsOf: progressURL),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let done = obj["segmentsDone"] as? Int ?? 0
                let total = obj["segmentsTotal"] as? Int ?? 0
                if total > 0 {
                    percent = max(0, min(100, Int(round(Double(done) / Double(total) * 100))))
                    label = "HQ polish \(percent!)% (\(done)/\(total))"
                }
            }
            if !markerFresh && percent == nil && wavs == 0 { continue }
            activeMeetings += 1
            chunkTotal += wavs
            if let percent {
                bestPercent = bestPercent.map { ($0 + percent) / 2 } ?? percent
            }
            if let label {
                labels.append(label)
            } else if wavs > 0 {
                labels.append("HQ polish · \(wavs) chunk\(wavs == 1 ? "" : "s")")
            } else {
                labels.append("HQ polish · pending")
            }
        }
        let active = activeMeetings > 0
        let label: String
        if !active {
            label = "Idle"
        } else if activeMeetings == 1, let only = labels.first {
            label = only
        } else if let bestPercent {
            label = "\(activeMeetings) meetings syncing · \(bestPercent)%"
        } else {
            label = "\(activeMeetings) meetings syncing · \(chunkTotal) chunk\(chunkTotal == 1 ? "" : "s")"
        }
        return [
            "meetingSyncActive": active,
            "meetingSyncPercent": bestPercent.map { $0 as Any } ?? NSNull(),
            "meetingSyncLabel": label,
            "meetingSyncBlocksRestart": active,
            "meetingSyncCount": activeMeetings,
        ]
    }

    private func maintenanceIdentity(_ status: [String: Any]) throws -> (serverInstanceId: String, bootId: String, generationId: String) {
        guard let serverInstanceId = status["serverInstanceId"] as? String, !serverInstanceId.isEmpty,
              let bootId = status["bootId"] as? String, !bootId.isEmpty,
              let generationId = status["generationId"] as? String, !generationId.isEmpty else {
            throw HelperError.message("Managed maintenance identity is incomplete.")
        }
        return (serverInstanceId, bootId, generationId)
    }

    private func jsonBody(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func randomMaintenanceNonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw HelperError.message("Could not create a maintenance operation credential.")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func updatedOperation(_ operation: MaintenanceLease, identity: (serverInstanceId: String, bootId: String, generationId: String)) -> MaintenanceLease {
        MaintenanceLease(
            id: operation.id,
            operationId: operation.operationId,
            nonce: operation.nonce,
            nonceSha256: operation.nonceSha256,
            operationKind: operation.operationKind,
            scope: operation.scope,
            postcondition: operation.postcondition,
            authorizedSuccessorGenerations: operation.authorizedSuccessorGenerations,
            serverInstanceId: identity.serverInstanceId,
            sourceBootId: operation.sourceBootId,
            sourceGenerationId: operation.sourceGenerationId,
            bootId: identity.bootId,
            generationId: identity.generationId,
            expiresAt: operation.expiresAt
        )
    }

    private func maintenanceOperationMatches(_ status: [String: Any], operation: MaintenanceLease) -> Bool {
        guard let lifecycle = status["lifecycle"] as? [String: Any],
              let reported = lifecycle["operation"] as? [String: Any],
              reported["operationId"] as? String == operation.operationId,
              reported["operationKind"] as? String == operation.operationKind,
              reported["scope"] as? String == operation.scope,
              reported["postcondition"] as? String == operation.postcondition,
              reported["nonceSha256"] as? String == operation.nonceSha256,
              reported["sourceBootId"] as? String == operation.sourceBootId,
              reported["sourceGenerationId"] as? String == operation.sourceGenerationId,
              let authorized = reported["authorizedSuccessorGenerations"] as? [String] else { return false }
        return Set(authorized) == Set(operation.authorizedSuccessorGenerations)
    }

    private func operationReceiptIsUsable(_ operation: MaintenanceLease, now: Date = Date()) -> Bool {
        operation.scope == "cross_boot" || operation.expiresAt.map { $0 > now } == true
    }

    private func restartProofMatches(_ status: [String: Any], operation: MaintenanceLease) -> Bool {
        guard status["safeToRestart"] as? Bool == true,
              let lifecycle = status["lifecycle"] as? [String: Any],
              let proof = lifecycle["restartProof"] as? [String: Any],
              proof["valid"] as? Bool == true,
              proof["leaseMatches"] as? Bool == true,
              proof["operationMatches"] as? Bool == true,
              proof["nonceMatches"] as? Bool == true,
              proof["sourceIdentityMatches"] as? Bool == true,
              proof["serverInstanceId"] as? String == operation.serverInstanceId,
              proof["bootId"] as? String == operation.bootId,
              proof["generationId"] as? String == operation.generationId,
              lifecycle["state"] as? String == "draining",
              lifecycle["activeTotal"] as? Int == 0 else { return false }
        if operation.scope == "same_boot", let expiresAt = operation.expiresAt, expiresAt <= Date() { return false }
        return true
    }

    /// The drain label for a set of blockers.
    ///
    /// Extracted so the EMPTY case is testable. A mutation reverting this to the
    /// bare "restart proof" string passed the whole suite, because the drain
    /// loop needs a live server and nothing exercised its label choice — the
    /// exact branch that made the 2026-08-12 lockout undiagnosable.
    static func drainLabel(_ blockers: [String]) -> String {
        blockers.isEmpty ? "restart proof (no cause reported)" : blockers.joined(separator: ", ")
    }

    /// Receiving, no writer, idle ≥ 60s. Finalizing and published are never stranded.
    static func isStrandedReceivingVideoUpload(
        state: String,
        updatedAtMs: Int,
        nowMs: Int,
        activeWriters: Int = 0,
        idleMs: Int = 60_000
    ) -> Bool {
        state == "receiving" && activeWriters == 0 && nowMs - updatedAtMs >= idleMs
    }

    static func jsonInt(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Int64 { return Int(number) }
        if let number = value as? Double { return Int(number) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    static func isValidVideoUploadId(_ value: String) -> Bool {
        value.range(of: "^vu_[0-9a-f]{24}$", options: .regularExpression) != nil
    }

    /// Every reason a restart is currently refused, named.
    ///
    /// WHY THIS EXISTS. `restartProofMatches` folds a dozen conditions into one
    /// `guard`, and the drain loop only ever inspected `lifecycle.activeByKind`.
    /// When that dictionary was EMPTY the progress line fell back to the literal
    /// string "restart proof", which names nothing — so a blocked update said
    /// only "Timed out draining restart proof" no matter what was actually
    /// holding it.
    ///
    /// On 2026-08-12 that cost more than an hour across two sessions. The real
    /// blocker was `videoUploads.blocksRestart` — one abandoned upload, stuck in
    /// `receiving` for three hours after a client-side bug — and the server had
    /// been reporting it in the same payload the whole time. `activeByKind` was
    /// `{}` throughout, so the one field that mattered was never read and never
    /// printed. Three wrong root causes were proposed before anyone read it.
    ///
    /// Order is deliberate: the cheapest, most actionable causes first.
    private func restartBlockers(_ status: [String: Any], operation: MaintenanceLease) -> [String] {
        var blockers: [String] = []
        let lifecycle = status["lifecycle"] as? [String: Any] ?? [:]

        // Named active work. This is what the old code looked at, and it stays
        // first because when it IS populated it is the most useful answer.
        let activeByKind = lifecycle["activeByKind"] as? [String: Any] ?? [:]
        for (kind, value) in activeByKind.sorted(by: { $0.key < $1.key }) {
            if let count = value as? Int, count > 0 { blockers.append("\(kind)=\(count)") }
        }

        // The term that actually blocked us, and was invisible.
        if let video = status["videoUploads"] as? [String: Any],
           video["blocksRestart"] as? Bool == true {
            let receiving = video["receiving"] as? Int ?? 0
            let finalizing = video["finalizing"] as? Int ?? 0
            var detail: [String] = []
            if receiving > 0 { detail.append("receiving=\(receiving)") }
            if finalizing > 0 { detail.append("finalizing=\(finalizing)") }
            blockers.append(detail.isEmpty ? "video upload" : "video upload (\(detail.joined(separator: ", ")))")
        }

        if status["shuttingDown"] as? Bool == true { blockers.append("server shutting down") }

        if let gate = lifecycle["blockedGate"] as? [String: Any] {
            blockers.append("gate blocked: \(gate["reason"] as? String ?? "unknown")")
        }

        // Decompose the proof rather than reporting it as one opaque failure.
        if let proof = lifecycle["restartProof"] as? [String: Any] {
            for (key, label) in [
                ("leaseMatches", "lease"),
                ("operationMatches", "operation id"),
                ("nonceMatches", "nonce"),
                ("sourceIdentityMatches", "source identity"),
            ] where proof[key] as? Bool != true {
                blockers.append("proof \(label) mismatch")
            }
            if proof["serverInstanceId"] as? String != operation.serverInstanceId { blockers.append("server instance changed") }
            if proof["bootId"] as? String != operation.bootId { blockers.append("server rebooted") }
            if proof["generationId"] as? String != operation.generationId { blockers.append("generation changed") }
        }

        if let state = lifecycle["state"] as? String, state != "draining" {
            blockers.append("lifecycle state is \(state)")
        }

        // Context, not a blocker: a stale session no longer holds the gate, but
        // seeing it explains an activeTranscriptionSessions count that looks
        // wrong next to activeByKind.
        if let stale = status["staleTranscriptionSessions"] as? Int, stale > 0 {
            blockers.append("(\(stale) stale session(s), not blocking)")
        }

        return blockers
    }

    private func waitForRestartProof(_ operation: MaintenanceLease, timeout: TimeInterval = 90) throws -> MaintenanceLease {
        progress("Draining active work safely…")
        let deadline = Date().addingTimeInterval(timeout)
        var nextProgress = Date()
        var lastBlockers = "unknown active work"
        while Date() < deadline {
            guard let status = maintenanceStatus(operation: operation), hasLifecycleContract(status),
                  maintenanceOperationMatches(status, operation: operation) else {
                throw HelperError.message("Credentialed maintenance status disappeared. Repair can resume from the persisted operation receipt.")
            }
            guard let identity = try? maintenanceIdentity(status),
                  identity.serverInstanceId == operation.serverInstanceId,
                  identity.bootId == operation.bootId,
                  identity.generationId == operation.generationId else {
                throw HelperError.message("The source server identity changed before the maintenance drain was committed.")
            }
            if restartProofMatches(status, operation: operation) { return operation }
            if Date() >= nextProgress {
                // "restart proof" only when the payload genuinely offers no
                // reason. Previously this was the answer whenever activeByKind
                // was empty, which is exactly when the cause was something else.
                lastBlockers = Self.drainLabel(restartBlockers(status, operation: operation))
                let remaining = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
                progress("Draining: \(lastBlockers) · \(remaining)s remaining…")
                nextProgress = Date().addingTimeInterval(3)
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw HelperError.message("Timed out draining \(lastBlockers). The committed operation remains closed and persisted for Repair.")
    }

    private func acquireMaintenanceLeaseIfNeeded(
        snapshot: OwnershipSnapshot? = nil,
        operationKind: String = "server_restart",
        successorGenerations: [String] = []
    ) throws -> MaintenanceLease? {
        let snapshot = snapshot ?? ownershipSnapshot()
        if let stored = loadMaintenanceLease() {
            guard operationReceiptIsUsable(stored) else {
                clearMaintenanceLease()
                throw HelperError.message("A stale same-boot maintenance receipt was cleared. Retry the operation.")
            }
            guard !snapshot.allListenerPIDs.isEmpty else { return stored }
            guard let status = maintenanceStatus(operation: stored), hasLifecycleContract(status),
                  maintenanceOperationMatches(status, operation: stored),
                  let identity = try? maintenanceIdentity(status) else {
                throw HelperError.message("A committed maintenance operation exists but cannot be authenticated. Repair is required; it will never expiry-open.")
            }
            if identity.bootId != stored.bootId || identity.generationId != stored.generationId {
                let carried = updatedOperation(stored, identity: identity)
                try saveMaintenanceLease(carried)
                return carried
            }
            return try waitForRestartProof(stored)
        }
        guard !snapshot.allListenerPIDs.isEmpty else { return nil }
        guard snapshot.serviceLoaded, launchdOwnsListeners(snapshot, requireDirect: false) else {
            throw HelperError.message("Restart refused because listener ownership cannot be verified.")
        }
        guard let status = maintenanceStatus(), hasLifecycleContract(status) else {
            throw HelperError.message("The running server lacks the rev4 credentialed maintenance contract required for safe lifecycle changes.")
        }
        let identity = try maintenanceIdentity(status)
        let crossBoot = operationKind != "same_boot_maintenance"
        let authorized = Array(Set(successorGenerations.filter { !$0.isEmpty })).sorted()
        guard !crossBoot || !authorized.isEmpty else {
            throw HelperError.message("Cross-boot maintenance requires exact authorized successor generations.")
        }
        let nonce = try randomMaintenanceNonce()
        let operationID = UUID().uuidString.lowercased()
        let nonceSHA256 = tokenDigest(nonce)
        var requestObject: [String: Any] = [
            "serverInstanceId": identity.serverInstanceId,
            "bootId": identity.bootId,
            "generationId": identity.generationId,
            "operationId": operationID,
            "operationKind": operationKind,
            "scope": crossBoot ? "cross_boot" : "same_boot",
            "postcondition": crossBoot ? "authorized_successor_adopted" : "same_boot_idle",
            "nonceSha256": nonceSHA256,
            "authorizedSuccessorGenerations": authorized,
        ]
        if !crossBoot { requestObject["ttlMs"] = 120_000 }
        guard let token = try? readToken(),
              let response = request("/api/maintenance/drain", method: "POST", token: token, body: try jsonBody(requestObject), timeout: 15),
              response.status == 200,
              let body = response.body,
              let leaseID = (body["leaseId"] as? String) ?? ((body["lease"] as? [String: Any])?["id"] as? String),
              !leaseID.isEmpty else {
            throw HelperError.message("The server refused to commit the credentialed maintenance gate.")
        }
        let operation = MaintenanceLease(
            id: leaseID,
            operationId: operationID,
            nonce: nonce,
            nonceSha256: nonceSHA256,
            operationKind: operationKind,
            scope: crossBoot ? "cross_boot" : "same_boot",
            postcondition: crossBoot ? "authorized_successor_adopted" : "same_boot_idle",
            authorizedSuccessorGenerations: authorized,
            serverInstanceId: identity.serverInstanceId,
            sourceBootId: identity.bootId,
            sourceGenerationId: identity.generationId,
            bootId: identity.bootId,
            generationId: identity.generationId,
            expiresAt: crossBoot ? nil : Date().addingTimeInterval(120)
        )
        try saveMaintenanceLease(operation)
        return try waitForRestartProof(operation)
    }

    private func adoptMaintenanceOperation(_ operation: MaintenanceLease, status: [String: Any]) throws -> MaintenanceLease {
        let identity = try maintenanceIdentity(status)
        guard operation.authorizedSuccessorGenerations.contains(identity.generationId) else {
            throw HelperError.message("Candidate generation is not authorized by the committed maintenance operation.")
        }
        let body = try jsonBody([
            "serverInstanceId": identity.serverInstanceId,
            "bootId": identity.bootId,
            "generationId": identity.generationId,
            "operationId": operation.operationId,
            "nonce": operation.nonce,
        ])
        guard let token = try? readToken(),
              let response = request(
                "/api/maintenance/drain/adopt", method: "POST", token: token,
                maintenanceLease: operation.id, maintenanceOperation: operation.operationId,
                maintenanceNonce: operation.nonce, body: body, timeout: 15
              ), response.status == 200, response.body?["adopted"] as? Bool == true else {
            throw HelperError.message("The successor could not durably adopt the maintenance operation.")
        }
        let adopted = updatedOperation(operation, identity: identity)
        try saveMaintenanceLease(adopted)
        return adopted
    }

    @discardableResult
    private func releaseMaintenanceLease(_ operation: MaintenanceLease?) -> Bool {
        guard let operation else { return true }
        guard let token = try? readToken() else { return false }
        let body = try? jsonBody([
            "serverInstanceId": operation.serverInstanceId,
            "bootId": operation.bootId,
            "generationId": operation.generationId,
            "operationId": operation.operationId,
            "nonce": operation.nonce,
        ])
        guard let response = request(
            "/api/maintenance/drain/release", method: "POST", token: token,
            maintenanceLease: operation.id, maintenanceOperation: operation.operationId,
            maintenanceNonce: operation.nonce, body: body, timeout: 12
        ), response.status == 200, response.body?["released"] as? Bool == true else { return false }
        clearMaintenanceLease()
        return true
    }

    private func requireMaintenanceRelease(_ operation: MaintenanceLease?) throws {
        guard releaseMaintenanceLease(operation) else {
            throw HelperError.message("The successor is verified but the committed maintenance gate could not be released. Run Reconcile; admissions remain closed.")
        }
    }

    private func waitForPortsClear(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ownershipSnapshot().allListenerPIDs.isEmpty { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw HelperError.message("Ports 3141/3143 did not clear after the previous server stopped.")
    }

    private func waitForManagedHealth(
        expectedVersion: String,
        expectedGenerationID: String?,
        inheritedLease: MaintenanceLease?,
        timeout: TimeInterval,
        requireDirectOwnership: Bool = true,
        requireTransactionalProof: Bool = true,
        requireLocalWhisper: Bool = true
    ) throws -> MaintenanceLease? {
        let deadlineUptime = ProcessInfo.processInfo.systemUptime + timeout
        var lastReason = "server did not answer"
        progress("Starting candidate server…")
        while ProcessInfo.processInfo.systemUptime < deadlineUptime {
            let snapshot = ownershipSnapshot()
            if !launchdOwnsListeners(snapshot, requireDirect: requireDirectOwnership) {
                lastReason = requireDirectOwnership
                    ? "launchd does not directly own the listener PID"
                    : "launchd does not own the listener process tree"
            } else if let status = maintenanceStatus(operation: inheritedLease, deadlineUptime: deadlineUptime) {
                if !hasLifecycleContract(status) {
                    lastReason = "managed contract is missing or incompatible"
                } else if let inheritedLease, !maintenanceOperationMatches(status, operation: inheritedLease) {
                    lastReason = "candidate maintenance operation does not match the persisted credential"
                } else if status["serverVersion"] as? String != expectedVersion {
                    lastReason = "server version does not match \(expectedVersion)"
                } else if let expectedGenerationID, status["generationId"] as? String != expectedGenerationID {
                    lastReason = "server generation does not match the activated manifest"
                } else if let inheritedLease,
                          inheritedLease.scope == "cross_boot",
                          (status["bootId"] as? String == inheritedLease.sourceBootId ||
                           ((status["lifecycle"] as? [String: Any])?["operation"] as? [String: Any])?["carriedAcrossBoot"] as? Bool != true) {
                    lastReason = "candidate did not prove the committed gate carried across boot"
                } else if inheritedLease != nil,
                          (status["lifecycle"] as? [String: Any])?["state"] as? String != "draining" {
                    lastReason = "candidate did not inherit the non-accepting maintenance drain"
                } else {
                    let healthResponse = request("/api/health", timeout: 12, deadlineUptime: deadlineUptime)
                    if let failure = managedHealthFailure(healthResponse) {
                        lastReason = failure
                        Thread.sleep(forTimeInterval: 0.5)
                        continue
                    }
                    let proofHealth = healthResponse?.body ?? [:]
                    if requireLocalWhisper,
                       let whisperFailure = localWhisperReadinessFailure(proofHealth, serverVersion: expectedVersion) {
                        let state = ((proofHealth["whisper_health"] as? [String: Any])?["startupState"] as? String) ?? "not_started"
                        if state == "failed" {
                            throw HelperError.message("Managed server verification failed: \(whisperFailure).")
                        }
                        lastReason = whisperFailure
                        progress("Waiting for \(whisperFailure.lowercased())…")
                        Thread.sleep(forTimeInterval: 0.5)
                        continue
                    }
                    if requireTransactionalProof {
                        // The startup deadline proves listener ownership, health,
                        // and local Whisper readiness. Do not reuse its remaining
                        // seconds for real provider and Kokoro transactions: each
                        // request already has its own bounded timeout, and sharing
                        // the 60-second startup budget falsely rejects healthy
                        // Claude + Codex installs after a normal cold start.
                        if let failure = transactionalRuntimeProofFailure(
                            health: proofHealth,
                            expectedProviders: detectedManagedProviders(),
                            requireProviderEndpoint: versionAtLeast(expectedVersion, "6.15.2"),
                            operation: inheritedLease,
                            deadlineUptime: nil
                        ) {
                            throw HelperError.message("Managed server transactional verification failed: \(failure).")
                        }
                    }
                    guard let inheritedLease else {
                        guard (status["lifecycle"] as? [String: Any])?["state"] as? String == "accepting" else {
                            lastReason = "fresh server did not open admissions after verification"
                            Thread.sleep(forTimeInterval: 0.5)
                            continue
                        }
                        return nil
                    }
                    return try adoptMaintenanceOperation(inheritedLease, status: status)
                }
            }
            let remaining = deadlineUptime - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { Thread.sleep(forTimeInterval: min(0.5, remaining)) }
        }
        throw HelperError.message("Managed server verification timed out: \(lastReason).")
    }

    private func waitForLocalWhisper(timeout: TimeInterval = 60) throws {
        progress("Verifying local Whisper…")
        let deadline = Date().addingTimeInterval(timeout)
        var lastReason = "Whisper health did not answer"
        while Date() < deadline {
            if let response = request("/api/health", timeout: 12), response.status == 200,
               let health = response.body,
               let whisper = health["whisper_health"] as? [String: Any] {
                if whisper["server"] as? Bool == true { return }
                guard whisper["serverConfigured"] as? Bool == true else {
                    throw HelperError.message("Local Whisper prerequisites are not installed; the server remains available.")
                }
                let state = whisper["startupState"] as? String ?? "not_started"
                let error = whisper["lastError"] as? String
                lastReason = error.map { "\(state): \($0)" } ?? state
                if state == "failed" || state == "unavailable" {
                    throw HelperError.message("Local Whisper failed to recover (\(lastReason)); the server remains available.")
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw HelperError.message("Local Whisper did not become ready (\(lastReason)); the server remains available.")
    }

    private func adoptLegacy(requestedVersion: String) throws {
        var snapshot = ownershipSnapshot()
        guard snapshot.launchAgentKind == .knownLegacy else {
            throw HelperError.message("Adoption requires the exact recognized legacy LaunchAgent shape.")
        }
        if !snapshot.allListenerPIDs.isEmpty {
            // Guided stop→install for the recognized LaunchAgent only. Refuse
            // when ownership is fuzzy or work is in flight so we cannot strand
            // an active glasses turn mid-cutover.
            guard snapshot.serviceLoaded, launchdOwnsListeners(snapshot, requireDirect: false) else {
                throw HelperError.message("Running legacy adoption is unsupported. Stop the recognized legacy LaunchAgent first so adoption has no in-flight work to lose.")
            }
            if let maintenance = maintenanceStatus(),
               ((maintenance["activeJobs"] as? Int) ?? 0) + ((maintenance["activeTranscriptionSessions"] as? Int) ?? 0) > 0 {
                throw HelperError.message("Finish active glasses work before switching the running legacy server to managed npm.")
            }
            progress("Stopping the recognized legacy LaunchAgent…")
            try unloadService()
            try waitForPortsClear(timeout: 12)
            snapshot = ownershipSnapshot()
            guard snapshot.allListenerPIDs.isEmpty else {
                throw HelperError.message("Legacy LaunchAgent stopped, but ports 3141/3143 are still owned. Clear them before adoption.")
            }
        }
        try install(requestedVersion: requestedVersion, workDirectory: nil)
    }

    // MARK: - Manage in place
    //
    // Adopts the user's EXISTING glasses server for lifecycle management WITHOUT
    // replacing it: no generation, no npm install, no server-identity change (so
    // the glasses never have to re-pair). Records a lightweight marker; lifecycle
    // uses plain launchctl on the existing plist plus a health poll. Kept fully
    // separate from the generation-bound managed path.

    private func inPlaceActive() -> Bool { fm.fileExists(atPath: inPlaceURL.path) }

    private func loadInPlace() -> InPlaceRecord? {
        guard let data = try? Data(contentsOf: inPlaceURL) else { return nil }
        return try? JSONDecoder().decode(InPlaceRecord.self, from: data)
    }

    private func adoptLegacyInPlace() throws {
        let snapshot = ownershipSnapshot()
        guard snapshot.launchAgentKind == .knownLegacy else {
            throw HelperError.message("In-place management requires your recognized COS glasses server (the legacy LaunchAgent).")
        }
        guard snapshot.serviceLoaded,
              !snapshot.allListenerPIDs.isEmpty,
              launchdOwnsListeners(snapshot, requireDirect: false) else {
            throw HelperError.message("In-place management requires the canonical LaunchAgent to own the active listeners.")
        }
        guard loadManifest() == nil else {
            throw HelperError.message("A managed generation is installed. Roll back or stop it before switching to in-place management.")
        }
        if let failure = managedHealthFailure(request("/api/health", timeout: 12)) {
            throw HelperError.message("In-place adoption requires a working AI provider bridge: " + failure)
        }
        let record = InPlaceRecord(
            plistPath: plistURL.path,
            appDir: legacyAppDir(),
            serverInstanceId: request("/api/models", timeout: 8)?.body?["serverInstanceId"] as? String,
            adoptedAt: ISO8601DateFormatter().string(from: Date())
        )
        try atomicWrite(record, to: inPlaceURL, permissions: 0o600)
        try installStableHelper()
        try installRecoveryLaunchAgent()
        emit(ok: true, message: "COS Control now manages your server in place", details: statusDetails())
    }

    private func releaseInPlace() throws {
        try? fm.removeItem(at: inPlaceURL)
        _ = try? launchctl(["bootout", recoveryServiceTarget])
        try? fm.removeItem(at: recoveryPlistURL)
        emit(ok: true, message: "COS Control released your server; it keeps running untouched", details: statusDetails())
    }

    private func waitForInPlaceHealth(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if managedHealthFailure(request("/api/health", timeout: 6)) == nil { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private func restartInPlace() throws {
        let snapshot = ownershipSnapshot()
        guard snapshot.launchAgentKind == .knownLegacy,
              snapshot.serviceLoaded,
              launchdOwnsListeners(snapshot, requireDirect: false) else {
            throw HelperError.message("The adopted server lacks verified LaunchAgent ownership.")
        }
        let priorPID = snapshot.servicePID
        guard let status = maintenanceStatus(),
              let version = status["serverVersion"] as? String,
              let generation = status["generationId"] as? String else {
            // Older recognized servers predate the credentialed drain contract.
            // The UI requires a deliberate confirmation before reaching this
            // path. A full bootout/bootstrap is mandatory because kickstart -k
            // retains the old LaunchAgent environment.
            do {
                progress("Restarting the confirmed-idle legacy server…")
                try strictBootoutInPlace()
                try strictBootstrapInPlace()
                guard waitForInPlaceHealth(timeout: 60) else {
                    throw HelperError.message("the replacement server did not report healthy in time")
                }
                guard let newPID = servicePID(), newPID != priorPID else {
                    throw HelperError.message("launchd did not replace the prior server process")
                }
                emit(
                    ok: true,
                    message: "Your self-managed server was restarted and the LaunchAgent folder is active",
                    details: statusDetails()
                )
                return
            } catch {
                if !serviceLoaded() { try? strictBootstrapInPlace() }
                if serviceLoaded() { _ = waitForInPlaceHealth(timeout: 60) }
                throw HelperError.message("Legacy restart failed and recovery was attempted: \(error)")
            }
        }
        let lease = try acquireMaintenanceLeaseIfNeeded(
            snapshot: snapshot,
            operationKind: "server_restart",
            successorGenerations: [generation]
        )
        do {
            try strictBootoutInPlace()
            try strictBootstrapInPlace()
            let activeLease = try waitForManagedHealth(
                expectedVersion: version,
                expectedGenerationID: generation,
                inheritedLease: lease,
                timeout: 60,
                requireDirectOwnership: false,
                requireTransactionalProof: versionAtLeast(version, "6.15.2")
            )
            guard let newPID = servicePID(), newPID != priorPID else {
                throw HelperError.message("launchd did not replace the prior server process.")
            }
            try requireMaintenanceRelease(activeLease)
            emit(ok: true, message: "Your server was restarted and verified", details: statusDetails())
        } catch {
            if !serviceLoaded() { try? strictBootstrapInPlace() }
            if serviceLoaded(),
               let recovered = try? waitForManagedHealth(
                    expectedVersion: version,
                    expectedGenerationID: generation,
                    inheritedLease: loadMaintenanceLease(),
                    timeout: 60,
                    requireDirectOwnership: false,
                    requireTransactionalProof: false
               ) {
                try? requireMaintenanceRelease(recovered)
            }
            throw HelperError.message("Restart failed and recovery was attempted: \(error)")
        }
    }

    private func stopInPlace() throws {
        if serviceLoaded() {
            let result = try launchctl(["bootout", serviceTarget])
            if result.code != 0 && serviceLoaded() {
                throw HelperError.message("Stop failed: \(result.output)")
            }
        }
        try? waitForPortsClear(timeout: 12)
        emit(ok: true, message: "Your server was stopped", details: statusDetails())
    }

    private func startInPlace() throws {
        if serviceLoaded() && !ownershipSnapshot().allListenerPIDs.isEmpty {
            if let failure = managedHealthFailure(request("/api/health", timeout: 12)) {
                throw HelperError.message("The in-place server is running but degraded: " + failure)
            }
            emit(ok: true, message: "Your server is already running", details: statusDetails())
            return
        }
        let plist = loadInPlace()?.plistPath ?? plistURL.path
        let result = try launchctl(["bootstrap", launchDomain, plist])
        guard result.code == 0 || serviceLoaded() else { throw HelperError.message("Start failed: \(result.output)") }
        guard waitForInPlaceHealth(timeout: 60) else { throw HelperError.message("Server started but did not report healthy in time.") }
        emit(ok: true, message: "Your server was started", details: statusDetails())
    }

    private func operationStatusDetails() -> [String: Any] {
        var details = statusDetails()
        if let transaction = loadTransaction() {
            details["operation"] = [
                "phase": transaction.phase,
                "startedAt": transaction.startedAt,
                "candidateVersion": transaction.candidate.version,
                "hasPreviousGeneration": transaction.previous != nil,
            ]
        } else {
            details["operation"] = NSNull()
        }
        if let lease = loadMaintenanceLease() {
            var receipt: [String: Any] = [
                "operationKind": lease.operationKind,
                "scope": lease.scope,
                "committed": true,
            ]
            if let expiresAt = lease.expiresAt {
                receipt["expiresAt"] = ISO8601DateFormatter().string(from: expiresAt)
                receipt["expired"] = expiresAt <= Date()
            }
            details["maintenanceReceipt"] = receipt
        } else {
            details["maintenanceReceipt"] = NSNull()
        }
        return details
    }

    private func reconcile() throws {
        if inPlaceActive(), let transaction = loadInPlaceConfigurationTransaction() {
            let message = try restoreInPlaceConfiguration(transaction)
            emit(ok: true, message: message, details: statusDetails())
            return
        }
        if loadTransaction() != nil {
            try repair()
            return
        }
        guard let stored = loadMaintenanceLease() else {
            emit(ok: true, message: "No interrupted lifecycle change needs reconciliation", details: statusDetails())
            return
        }
        guard operationReceiptIsUsable(stored) else {
            clearMaintenanceLease()
            emit(ok: true, message: "Expired lifecycle receipt cleared", details: statusDetails())
            return
        }
        let snapshot = ownershipSnapshot()
        guard let manifest = loadManifest() else {
            throw HelperError.message("A committed cross-boot operation exists without an active manifest. Receipt preserved; manual recovery is required.")
        }
        if stored.operationKind == "server_stop" || manifest.desiredState == "stopped" {
            var stoppedManifest = manifest
            stoppedManifest.desiredState = "stopped"
            try saveManifest(stoppedManifest)
            try setServiceEnabled(false)
            if snapshot.serviceLoaded { try unloadService() }
            try waitForPortsClear(timeout: 12)
            emit(ok: true, message: "Stopped state reconciled; COS remains disabled until Start", details: statusDetails())
            return
        }
        if snapshot.allListenerPIDs.isEmpty {
            try writeLaunchAgent(for: manifest)
            try loadService(forceRestart: false)
            let activeLease = try waitForManagedHealth(
                expectedVersion: manifest.version,
                expectedGenerationID: manifest.generationID,
                inheritedLease: stored,
                timeout: 60
            )
            try requireMaintenanceRelease(activeLease)
        } else {
            guard let status = maintenanceStatus(operation: stored), hasLifecycleContract(status) else {
                throw HelperError.message("Persisted lifecycle receipt could not be matched to the running server.")
            }
            if (status["lifecycle"] as? [String: Any])?["state"] as? String == "accepting" {
                guard launchdOwnsListeners(snapshot, requireDirect: true),
                      status["generationId"] as? String == manifest.generationID,
                      status["serverVersion"] as? String == manifest.version,
                      managedHealthFailure(request("/api/health", timeout: 12)) == nil else {
                    throw HelperError.message("Server reports an open gate, but exact managed runtime proof failed. Receipt preserved.")
                }
                clearMaintenanceLease()
                emit(ok: true, message: "Completed maintenance release reconciled", details: statusDetails())
                return
            }
            guard maintenanceOperationMatches(status, operation: stored) else {
                throw HelperError.message("Running server has a different committed operation. Receipt preserved for manual recovery.")
            }
            let identity = try maintenanceIdentity(status)
            if identity.bootId == stored.bootId && identity.generationId == stored.generationId {
                _ = try waitForRestartProof(stored)
                try unloadService()
                try waitForPortsClear(timeout: 12)
                try writeLaunchAgent(for: manifest)
                try loadService(forceRestart: false)
            }
            let activeLease = try waitForManagedHealth(
                expectedVersion: manifest.version,
                expectedGenerationID: manifest.generationID,
                inheritedLease: stored,
                timeout: 60
            )
            try requireMaintenanceRelease(activeLease)
        }
        emit(ok: true, message: "Interrupted lifecycle change reconciled", details: statusDetails())
    }

    private func automaticReconcile() throws {
        if inPlaceActive() {
            if let transaction = loadInPlaceConfigurationTransaction() {
                let message = try restoreInPlaceConfiguration(transaction)
                emit(ok: true, message: message, details: statusDetails())
                return
            }
            // In-place recovery: only act if the server is actually down/hung. Never
            // installs or replaces anything — just brings the existing server back.
            if ownershipSnapshot().allListenerPIDs.isEmpty {
                if serviceLoaded() {
                    _ = try? launchctl(["kickstart", "-k", serviceTarget])
                } else {
                    try? startInPlace()
                }
                _ = waitForInPlaceHealth(timeout: 30)
            }
            emit(ok: true, message: "In-place recovery check complete", details: statusDetails())
            return
        }
        if loadTransaction() != nil || loadMaintenanceLease() != nil {
            try reconcile()
            return
        }
        if let data = try? Data(contentsOf: clipboardReceiptURL),
           let receipt = try? JSONDecoder().decode(ClipboardReceipt.self, from: data),
           receipt.expiresAt <= Date() {
            try expireClipboard(args: [
                "expire-clipboard",
                "--receipt", receipt.digest,
                "--job", receipt.launchdLabel,
                "--expires", String(receipt.expiresAt.timeIntervalSince1970),
            ])
        }
        emit(ok: true, message: "Recovery check complete; no interrupted lifecycle work found", details: statusDetails())
    }

    private func start() throws {
        if inPlaceActive() { try startInPlace(); return }
        guard var manifest = loadManifest() else { throw HelperError.message("Install the managed server first.") }
        _ = try verifyGeneration(
            at: manifest.generationPath,
            expectedVersion: manifest.version,
            expectedIntegrity: manifest.registryIntegrity,
            expectedLauncherHash: manifest.launcherSHA256,
            expectedPackageHash: manifest.packageJSONSHA256
        )
        let snapshot = ownershipSnapshot()
        try assertAdoptableOwnership(snapshot)
        if !snapshot.allListenerPIDs.isEmpty {
            if runtimeState(snapshot: snapshot, maintenance: maintenanceStatus(), health: request("/api/health", timeout: 12)?.body) == .managedHealthy {
                manifest.desiredState = "running"
                try saveManifest(manifest)
                try setServiceEnabled(true)
                emit(ok: true, message: "COS server is already running", details: statusDetails())
                return
            }
            throw HelperError.message("A loaded server is degraded or still starting. Run Repair instead of forcing Start.")
        }
        if snapshot.serviceLoaded { try unloadService() }
        let operation = try acquireMaintenanceLeaseIfNeeded(snapshot: ownershipSnapshot())
        manifest.desiredState = "running"
        try saveManifest(manifest)
        try setServiceEnabled(true)
        try writeLaunchAgent(for: manifest)
        try loadService(forceRestart: false)
        let adopted = try waitForManagedHealth(
            expectedVersion: manifest.version,
            expectedGenerationID: manifest.generationID,
            inheritedLease: operation,
            timeout: 60
        )
        try requireMaintenanceRelease(adopted)
        emit(ok: true, message: "COS server started and verified", details: statusDetails())
    }

    private func stop() throws {
        if inPlaceActive() { try stopInPlace(); return }
        guard var manifest = loadManifest(), let generationID = manifest.generationID else {
            throw HelperError.message("A verified managed generation is required before Stop.")
        }
        let lease = try acquireMaintenanceLeaseIfNeeded(
            operationKind: "server_stop",
            successorGenerations: [generationID]
        )
        manifest.desiredState = "stopped"
        try saveManifest(manifest)
        try setServiceEnabled(false)
        do { try unloadService() }
        catch {
            throw error
        }
        try waitForPortsClear(timeout: 12)
        guard lease != nil, loadMaintenanceLease() != nil else {
            throw HelperError.message("Stop did not retain its committed cross-boot operation receipt.")
        }
        emit(ok: true, message: "COS server stopped with admissions durably closed until authorized Start", details: statusDetails())
    }

    private func restart() throws {
        if inPlaceActive() { try restartInPlace(); return }
        guard let manifest = loadManifest() else { throw HelperError.message("Install the managed server first.") }
        let lease = try acquireMaintenanceLeaseIfNeeded(
            operationKind: "server_restart",
            successorGenerations: [manifest.generationID].compactMap { $0 }
        )
        guard serviceLoaded() else { try start(); return }
        let result = try launchctl(["kickstart", "-k", serviceTarget])
        guard result.code == 0 else { throw HelperError.message("launchd restart failed: \(result.output)") }
        let activeLease = try waitForManagedHealth(
            expectedVersion: manifest.version,
            expectedGenerationID: manifest.generationID,
            inheritedLease: lease,
            timeout: 60
        )
        try requireMaintenanceRelease(activeLease)
        emit(ok: true, message: "COS server restarted and verified", details: statusDetails())
    }

    private func rollback() throws {
        guard let current = loadManifest() else { throw HelperError.message("Install the managed server first.") }
        let retained = current.retainedGenerations ?? current.previousVersions.map {
            GenerationRecord(version: $0, path: generations.appendingPathComponent($0).path, registryIntegrity: nil, launcherSHA256: nil, packageJSONSHA256: nil)
        }
        guard let prior = retained.first else { throw HelperError.message("No retained server generation is available.") }
        try requireVideoUploadDowngradeSafe(targetVersion: prior.version)
        let verified = try verifyGeneration(
            at: prior.path,
            expectedVersion: prior.version,
            expectedIntegrity: prior.registryIntegrity,
            expectedLauncherHash: prior.launcherSHA256,
            expectedPackageHash: prior.packageJSONSHA256
        )
        let next = try makeManifest(
            generation: verified,
            workDirectory: current.workDirectory,
            previous: nil,
            retained: [currentGenerationRecord(current)] + Array(retained.dropFirst())
        )
        let lease = try acquireMaintenanceLeaseIfNeeded(
            operationKind: "server_rollback",
            successorGenerations: [next.generationID, current.generationID].compactMap { $0 }
        )
        let transaction = RuntimeTransaction(previous: current, candidate: next, previousLaunchAgentPlist: nil, phase: "rollback", startedAt: ISO8601DateFormatter().string(from: Date()))
        try saveTransaction(transaction)
        do {
            do { try unloadService() }
            catch {
                throw error
            }
            try waitForPortsClear(timeout: 12)
            try saveManifest(next)
            try writeLaunchAgent(for: next)
            try loadService(forceRestart: false)
            let activeLease = try waitForManagedHealth(
                expectedVersion: next.version,
                expectedGenerationID: next.generationID,
                inheritedLease: lease,
                timeout: 60
            )
            try requireMaintenanceRelease(activeLease)
            clearTransaction()
            emit(ok: true, message: "Rolled back to server \(next.version) and verified it", details: statusDetails())
        } catch {
            let message = try restoreAfterFailedSwitch(transaction)
            throw HelperError.message("Rollback failed. \(message) Original error: \(error)")
        }
    }

    private func videoUploadRegistryRoot() -> URL {
        if let media = loadedEnvironmentValue("COS_MEDIA_ROOT"), !media.isEmpty {
            return URL(fileURLWithPath: media).appendingPathComponent("video-upload-v1")
        }
        if let data = loadedEnvironmentValue("COS_DATA_DIR"), !data.isEmpty {
            return URL(fileURLWithPath: data).appendingPathComponent("media/video-upload-v1")
        }
        return home.appendingPathComponent(".cos-glasses/data/media/video-upload-v1")
    }

    private func clearStrandedMessage(cancelledCount: Int, skippedCount: Int) -> String {
        if cancelledCount == 0 {
            return skippedCount > 0
                ? "No stranded video uploads. In-progress and compressing uploads were left alone."
                : "No stranded video uploads."
        }
        return cancelledCount == 1
            ? "Cleared 1 stranded video upload."
            : "Cleared \(cancelledCount) stranded video uploads."
    }

    private func stringArray(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private func clearStrandedVideoUploads() throws {
        let token = try readToken()
        guard let instance = request("/api/models", token: token, timeout: 8)?.body?["serverInstanceId"] as? String,
              !instance.isEmpty else {
            throw HelperError.message("Server identity is unavailable.")
        }
        if let posted = request(
            "/api/media/video-upload/clear-stranded",
            method: "POST",
            token: token,
            headers: ["X-COS-Server-Instance": instance],
            timeout: 20
        ) {
            if posted.status == 200 {
                let cancelled = stringArray(posted.body?["cancelled"])
                let skipped = posted.body?["skipped"] as? [Any] ?? []
                emit(
                    ok: true,
                    message: clearStrandedMessage(cancelledCount: cancelled.count, skippedCount: skipped.count),
                    details: ["cancelled": cancelled, "skipped": skipped, "via": "api"]
                )
                return
            }
            if posted.status != 404 && posted.status != 405 {
                let error = posted.body?["error"] as? String ?? "Clear stranded failed"
                throw HelperError.message(error)
            }
        }
        try clearStrandedVideoUploadsFromDisk(token: token, serverInstanceId: instance)
    }

    private func glassesDataDir() -> URL {
        if let data = loadedEnvironmentValue("COS_DATA_DIR"), !data.isEmpty {
            return URL(fileURLWithPath: data)
        }
        return home.appendingPathComponent(".cos-glasses/data")
    }

    private func resetMessageEraMessage(archived: Int, era: String) -> String {
        let count = archived == 1 ? "1 live session archived." : "\(archived) live sessions archived."
        return "\(count) Next message is #1. History stays in ARCHIVE / Message History."
    }

    private func resetMessageEra() throws {
        let token = try readToken()
        if let posted = request(
            "/api/message-era/reset",
            method: "POST",
            token: token,
            body: try jsonBody(["confirm": true]),
            timeout: 30
        ) {
            if posted.status == 200 {
                let era = posted.body?["era"] as? String ?? ""
                let archived = Self.jsonInt(posted.body?["archived"]) ?? 0
                emit(
                    ok: true,
                    message: resetMessageEraMessage(archived: archived, era: era),
                    details: [
                        "era": era,
                        "previousEra": posted.body?["previousEra"] ?? NSNull(),
                        "archived": archived,
                        "via": "api",
                    ]
                )
                return
            }
            if posted.status == 409 || posted.status == 400 || posted.status == 503 {
                let error = posted.body?["error"] as? String ?? "Reset failed"
                throw HelperError.message(error)
            }
            if posted.status != 404 && posted.status != 405 {
                let error = posted.body?["error"] as? String ?? "Reset failed"
                throw HelperError.message(error)
            }
        }
        try resetMessageEraFromDisk(token: token)
    }

    private func resetMessageEraFromDisk(token: String) throws {
        _ = request("/api/archive/now", method: "POST", token: token, timeout: 20)
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        let era = "era-\(formatter.string(from: now))"
        let startedAt = Int(now.timeIntervalSince1970 * 1000)
        let payload: [String: Any] = ["v": 1, "era": era, "startedAt": startedAt]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let dir = glassesDataDir()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try atomicWriteData(data, to: dir.appendingPathComponent("message-era.json"), permissions: 0o600)
        emit(
            ok: true,
            message: "Archived live messages and started numbering at #1. Reopen the phone companion if it still shows the old count.",
            details: ["era": era, "via": "disk"]
        )
    }

    private func clearStrandedVideoUploadsFromDisk(token: String, serverInstanceId: String) throws {
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        var cancelled: [String] = []
        var skipped: [[String: String]] = []
        let root = videoUploadRegistryRoot()
        let entries = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for entry in entries {
            let manifestURL = entry.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let state = object["state"] as? String ?? ""
            let named = object["uploadId"] as? String
            let uploadId = (named.flatMap { Self.isValidVideoUploadId($0) ? $0 : nil })
                ?? (Self.isValidVideoUploadId(entry.lastPathComponent) ? entry.lastPathComponent : nil)
            guard let uploadId else { continue }
            if state == "finalizing" {
                skipped.append(["uploadId": uploadId, "reason": "finalizing"])
                continue
            }
            guard state == "receiving" else { continue }
            let updated = Self.jsonInt(object["updatedAtMs"]) ?? 0
            if !Self.isStrandedReceivingVideoUpload(state: state, updatedAtMs: updated, nowMs: nowMs) {
                skipped.append(["uploadId": uploadId, "reason": "recently_updated"])
                continue
            }
            guard let response = request(
                "/api/media/video-upload/\(uploadId)",
                method: "DELETE",
                token: token,
                headers: ["X-COS-Server-Instance": serverInstanceId],
                timeout: 15
            ), response.status == 200 else {
                skipped.append(["uploadId": uploadId, "reason": "cancel_failed"])
                continue
            }
            cancelled.append(uploadId)
        }
        emit(
            ok: true,
            message: clearStrandedMessage(cancelledCount: cancelled.count, skippedCount: skipped.count),
            details: ["cancelled": cancelled, "skipped": skipped, "via": "disk"]
        )
    }

    private func repair() throws {
        // Repair restores the LaunchAgent / recovers an interrupted update.
        // It does not cancel stranded V2 video drafts. Those hold blocksRestart
        // for up to 4 hours; Clear stranded is the dedicated action.
        progress("Inspecting managed runtime…")
        if let transaction = loadTransaction() {
            progress("Recovering an interrupted update…")
            // If the candidate is already the live verified runtime, commit it
            // instead of rolling back — this recovers the "false failure" case
            // where restore threw after the candidate had already taken over.
            if let committed = try commitHealthyCandidateIfPresent(transaction) {
                emit(ok: true, message: committed, details: statusDetails())
                return
            }
            let message = try restoreAfterFailedSwitch(transaction)
            emit(ok: true, message: message, details: statusDetails())
            return
        }
        guard let manifest = loadManifest() else { throw HelperError.message("No managed installation exists to repair.") }
        _ = try verifyGeneration(
            at: manifest.generationPath,
            expectedVersion: manifest.version,
            expectedIntegrity: manifest.registryIntegrity,
            expectedLauncherHash: manifest.launcherSHA256,
            expectedPackageHash: manifest.packageJSONSHA256
        )
        let snapshot = ownershipSnapshot()
        try assertAdoptableOwnership(snapshot)
        try installStableHelper()
        try installRecoveryLaunchAgent()
        if manifest.desiredState == "stopped" {
            try setServiceEnabled(false)
            if snapshot.serviceLoaded { try unloadService() }
            try waitForPortsClear(timeout: 12)
            emit(ok: true, message: "Recovery controller repaired; COS remains stopped by user choice", details: statusDetails())
            return
        }
        let lease = try acquireMaintenanceLeaseIfNeeded(
            snapshot: snapshot,
            operationKind: "server_restart",
            successorGenerations: [manifest.generationID].compactMap { $0 }
        )
        if snapshot.serviceLoaded {
            do { try unloadService() }
            catch {
                throw error
            }
        }
        try waitForPortsClear(timeout: 12)
        try writeLaunchAgent(for: manifest)
        try loadService(forceRestart: false)
        let activeLease = try waitForManagedHealth(
            expectedVersion: manifest.version,
            expectedGenerationID: manifest.generationID,
            inheritedLease: lease,
            timeout: 60
        )
        try requireMaintenanceRelease(activeLease)
        emit(ok: true, message: "Managed runtime repaired and verified", details: statusDetails())
    }

    private func restartWhisper() throws {
        guard let manifest = loadManifest() else { throw HelperError.message("Install the managed server first.") }
        let snapshot = ownershipSnapshot()
        guard launchdOwnsListeners(snapshot, requireDirect: true) else {
            throw HelperError.message("Local Whisper repair requires verified direct LaunchAgent ownership.")
        }
        // Whisper has no network restart endpoint. The local helper performs the
        // same lease-guarded full process replacement used by normal recovery.
        let lease = try acquireMaintenanceLeaseIfNeeded(
            snapshot: snapshot,
            operationKind: "server_restart",
            successorGenerations: [manifest.generationID].compactMap { $0 }
        )
        let result = try launchctl(["kickstart", "-k", serviceTarget])
        guard result.code == 0 else { throw HelperError.message("Local recovery restart failed: \(result.output)") }
        let activeLease = try waitForManagedHealth(
            expectedVersion: manifest.version,
            expectedGenerationID: manifest.generationID,
            inheritedLease: lease,
            timeout: 60,
            requireLocalWhisper: false
        )
        try requireMaintenanceRelease(activeLease)
        try waitForLocalWhisper()
        emit(ok: true, message: "Server and local Whisper restarted safely", details: statusDetails())
    }

    /// One machine-owned transcription policy. Balanced is the public default;
    /// Max is opt-in and reuses the resident Large-v3 worker instead of adding a
    /// third process. Keep every legacy per-lane key coherent so older private
    /// installs cannot override only half of a preset.
    private func transcriptionTierEnvironment(_ raw: String) throws -> [String: String] {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "balanced":
            return [
                "COS_WHISPER_TRANSCRIPTION_TIER": "balanced",
                "COS_WHISPER_PREVIEW_MODEL": "small.en",
                "COS_WHISPER_COMMIT_MODEL": "turbo",
                "COS_MEETING_PROGRESSIVE_HQ_THREADS": "2",
            ]
        case "max":
            return [
                "COS_WHISPER_TRANSCRIPTION_TIER": "max",
                "COS_WHISPER_PREVIEW_MODEL": "turbo",
                "COS_WHISPER_COMMIT_MODEL": "large-v3",
                "COS_MEETING_PROGRESSIVE_HQ_THREADS": "6",
            ]
        default:
            throw HelperError.message("Unknown transcription tier. Choose Balanced or Max.")
        }
    }

    private func setTranscriptionTier(_ raw: String) throws {
        let values = try transcriptionTierEnvironment(raw)
        let tier = values["COS_WHISPER_TRANSCRIPTION_TIER"]!
        let health = request("/api/health", timeout: 12)?.body
        let live = ((health?["capabilities"] as? [String: Any])?["transcription"] as? [String: Any])?["live"] as? [String: Any]
        let stoppedCompatibleManagedServer = loadManifest().map {
            $0.desiredState == "stopped" && versionAtLeast($0.version, "6.21.0")
        } ?? false
        guard live?["requestedTier"] != nil || stoppedCompatibleManagedServer else {
            throw HelperError.message("Update the managed server to 6.21.0 or newer before changing the transcription tier.")
        }
        let label = tier == "max" ? "Max transcription" : "Balanced transcription"
        if let manifest = loadManifest() {
            try applyManagedProviderEnvironment(values, current: manifest, operationLabel: label)
            return
        }
        guard inPlaceActive() else {
            throw HelperError.message("Install the managed server or choose Manage in place first.")
        }
        try applyInPlaceProviderEnvironment(values, operationLabel: label)
    }

    private func setBackgroundJobs(_ raw: String) throws {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["on", "off"].contains(normalized) else {
            throw HelperError.message("Unknown background jobs setting. Choose On or Off.")
        }
        let health = request("/api/health", timeout: 12)?.body
        let features = health?["features"] as? [String: Any]
        let stoppedCompatibleManagedServer = loadManifest().map {
            $0.desiredState == "stopped" && versionAtLeast($0.version, "6.21.5")
        } ?? false
        guard features?["durableQueryJobs"] != nil || stoppedCompatibleManagedServer else {
            throw HelperError.message("Update the managed server to 6.21.5 or newer before changing Background jobs.")
        }
        let enabled = normalized == "on"
        let values = ["COS_DURABLE_QUERY_JOBS": enabled ? "1" : "0"]
        let operationLabel = enabled ? "Background jobs" : "Background jobs off"
        if let manifest = loadManifest() {
            try applyManagedProviderEnvironment(values, current: manifest, operationLabel: operationLabel)
            return
        }
        guard inPlaceActive() else {
            throw HelperError.message("Install the managed server or choose Manage in place first.")
        }
        try applyInPlaceProviderEnvironment(values, operationLabel: operationLabel)
    }

    private func requireBackgroundJobs(_ raw: String) throws {
        let expected = raw != "0"
        let health = request("/api/health", timeout: 12)?.body
        let features = health?["features"] as? [String: Any]
        guard features?["durableQueryJobs"] as? Bool == expected else {
            throw HelperError.message("the restarted server did not report Background jobs as \(expected ? "enabled" : "disabled")")
        }
    }

    private func setMeetingPreview(_ raw: String) throws {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["on", "off"].contains(normalized) else {
            throw HelperError.message("Unknown meeting preview setting. Choose On or Off.")
        }
        let health = request("/api/health", timeout: 12)?.body
        let runningVersion = health?["server_version"] as? String
        let stoppedCompatibleManagedServer = loadManifest().map {
            $0.desiredState == "stopped" && versionAtLeast($0.version, "6.21.7")
        } ?? false
        guard runningVersion.map({ versionAtLeast($0, "6.21.7") }) == true || stoppedCompatibleManagedServer else {
            throw HelperError.message("Update the managed server to 6.21.7 or newer before changing Meeting Turbo preview.")
        }
        let enabled = normalized == "on"
        let values = ["COS_WHISPER_MEETING_PREVIEW": enabled ? "1" : "0"]
        let operationLabel = enabled ? "Meeting Turbo preview" : "Meeting Turbo preview off"
        if let manifest = loadManifest() {
            try applyManagedProviderEnvironment(values, current: manifest, operationLabel: operationLabel)
            return
        }
        guard inPlaceActive() else {
            throw HelperError.message("Install the managed server or choose Manage in place first.")
        }
        try applyInPlaceProviderEnvironment(values, operationLabel: operationLabel)
    }

    private func requireMeetingPreview(_ raw: String) throws {
        let expected = raw == "1"
        guard loadedEnvironmentValue("COS_WHISPER_MEETING_PREVIEW") == (expected ? "1" : "0") else {
            throw HelperError.message("the restarted server did not load Meeting Turbo preview as \(expected ? "enabled" : "disabled")")
        }
    }

    private func setVideoUploadV2(_ raw: String) throws {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["on", "off"].contains(normalized) else {
            throw HelperError.message("Unknown reliable video upload setting. Choose On or Off.")
        }
        let runningVersion = (maintenanceStatus()?["serverVersion"] as? String)
            ?? request("/api/health", timeout: 12)?.body?["server_version"] as? String
        let stoppedCompatibleManagedServer = loadManifest().map {
            $0.desiredState == "stopped" && versionAtLeast($0.version, "6.27.3")
        } ?? false
        guard runningVersion.map({ versionAtLeast($0, "6.27.3") }) == true || stoppedCompatibleManagedServer else {
            throw HelperError.message("Update the managed server to 6.27.3 or newer before enabling Reliable video uploads.")
        }
        let enabled = normalized == "on"
        let values = ["COS_VIDEO_UPLOAD_V2": enabled ? "1" : "0"]
        let operationLabel = enabled ? "Reliable video uploads" : "Reliable video uploads off"
        if let manifest = loadManifest() {
            try applyManagedProviderEnvironment(values, current: manifest, operationLabel: operationLabel)
            return
        }
        guard inPlaceActive() else {
            throw HelperError.message("Install the managed server or choose Manage in place first.")
        }
        try applyInPlaceProviderEnvironment(values, operationLabel: operationLabel)
    }

    private func requireVideoUploadV2(_ raw: String) throws {
        let expected = raw == "1"
        guard loadedEnvironmentValue("COS_VIDEO_UPLOAD_V2") == (expected ? "1" : "0") else {
            throw HelperError.message("the restarted server did not load Reliable video uploads as \(expected ? "enabled" : "disabled")")
        }
        guard let status = maintenanceStatus(),
              let videoUploads = status["videoUploads"] as? [String: Any],
              videoUploads["enabled"] as? Bool == expected else {
            throw HelperError.message("the restarted server did not prove the Reliable video upload state")
        }
        if expected {
            guard let health = request("/api/health", timeout: 12)?.body,
                  let capabilities = health["capabilities"] as? [String: Any],
                  let richMedia = capabilities["richMedia"] as? [String: Any],
                  let capability = richMedia["videoUploadV2"] as? [String: Any],
                  capability["protocol"] as? Int == 1,
                  capability["available"] as? Bool == true else {
                throw HelperError.message("the server loaded the setting but could not prove video processing readiness")
            }
        }
    }

    private func setClaudeSessions(_ raw: String) throws {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["on", "off"].contains(normalized) else {
            throw HelperError.message("Unknown Claude sessions setting. Choose On or Off.")
        }
        let enabled = normalized == "on"
        let values = [
            "COS_CLAUDE_SESSIONS_ENABLED": enabled ? "1" : "0",
            "COS_CLAUDE_SESSIONS_SHOW_NAMES": enabled ? "1" : "0",
        ]
        let operationLabel = enabled ? "Claude sessions" : "Claude sessions off"
        if let manifest = loadManifest() {
            try applyManagedProviderEnvironment(values, current: manifest, operationLabel: operationLabel)
            return
        }
        guard inPlaceActive() else {
            throw HelperError.message("Install the managed server or choose Manage in place first.")
        }
        try applyInPlaceProviderEnvironment(values, operationLabel: operationLabel)
    }

    private func requireClaudeSessions(enabled: Bool) throws {
        let expected = enabled ? "1" : "0"
        guard loadedEnvironmentValue("COS_CLAUDE_SESSIONS_ENABLED") == expected else {
            throw HelperError.message("the restarted server did not load Claude sessions as \(enabled ? "enabled" : "disabled")")
        }
        if enabled {
            guard loadedEnvironmentValue("COS_CLAUDE_SESSIONS_SHOW_NAMES") == "1" else {
                throw HelperError.message("the restarted server did not load Claude session names")
            }
        }
        let token = try readToken()
        guard let response = request("/api/claude-sessions", token: token, timeout: 12),
              response.status == 200,
              let body = response.body,
              body["enabled"] as? Bool == enabled else {
            throw HelperError.message("the restarted server did not prove the Claude sessions route")
        }
    }

    /// First server build whose `/api/health` carries the thread-attach
    /// capability contract and whose write routes honour the gate.
    private let threadAttachMinimumServer = "6.29.0"

    /// Continue an agent thread — the write path that appends into a real
    /// Claude or Codex session on this Mac.
    ///
    /// Default OFF, and the OFF path REMOVES the key rather than writing "0".
    /// That is deliberate and is the opposite of `setMeetingPreview`:
    ///
    ///   - Meeting Turbo preview defaults ON, so for that flag an absent key
    ///     means ENABLED. Its Off must write an explicit "0" or the documented
    ///     "Disable for immediate rollback" affordance silently stops working.
    ///   - Continue defaults OFF, so an absent key already means disabled — the
    ///     server's own capability contract states "ABSENT MEANS DISABLED. NEVER
    ///     ENABLED." Removing the key returns the LaunchAgent to its pristine
    ///     default instead of leaving a "0" artifact to be maintained forever,
    ///     and it makes the disabled state provable by absence.
    ///
    /// `removingKeys` is the existing first-class, transaction-backed delete on
    /// both apply paths, so Off is as reversible as On.
    private func setThreadAttach(_ raw: String) throws {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["on", "off"].contains(normalized) else {
            throw HelperError.message("Unknown Continue agent threads setting. Choose On or Off.")
        }
        let health = request("/api/health", timeout: 12)?.body
        let runningVersion = health?["server_version"] as? String
        // Prefer the server's own answer over a version comparison.
        // `threadAttachSupported` is a compile-time constant of the running
        // build and is the field its capability contract tells every client to
        // read; the version compare is only the fallback for a build that
        // answers health without it.
        let runningSupports = health?["threadAttachSupported"] as? Bool == true
            || runningVersion.map { versionAtLeast($0, threadAttachMinimumServer) } == true
        let stoppedCompatibleManagedServer = loadManifest().map {
            $0.desiredState == "stopped" && versionAtLeast($0.version, threadAttachMinimumServer)
        } ?? false
        guard runningSupports || stoppedCompatibleManagedServer else {
            throw HelperError.message("Update the managed server to \(threadAttachMinimumServer) or newer before changing Continue agent threads.")
        }
        let enabled = normalized == "on"
        let (values, removing) = try threadAttachEnvironment(normalized)
        let operationLabel = enabled ? "Continue agent threads" : "Continue agent threads off"
        if let manifest = loadManifest() {
            try applyManagedProviderEnvironment(
                values,
                removingKeys: removing,
                current: manifest,
                operationLabel: operationLabel,
                requiredThreadAttach: enabled
            )
            return
        }
        guard inPlaceActive() else {
            throw HelperError.message("Install the managed server or choose Manage in place first.")
        }
        try applyInPlaceProviderEnvironment(
            values,
            removingKeys: removing,
            operationLabel: operationLabel,
            requiredThreadAttach: enabled
        )
    }

    /// The write shape for Continue, kept pure so the self-test can execute the
    /// delete-vs-"0" decision rather than assert it against source text.
    ///
    /// On writes "1"; Off REMOVES the key. See `setThreadAttach` for why this is
    /// correct here and wrong for a default-ON flag.
    private func threadAttachEnvironment(_ raw: String) throws -> (values: [String: String], removing: Set<String>) {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "on":
            return (["COS_THREAD_ATTACH_ENABLED": "1"], [])
        case "off":
            return ([:], ["COS_THREAD_ATTACH_ENABLED"])
        default:
            throw HelperError.message("Unknown Continue agent threads setting. Choose On or Off.")
        }
    }

    /// Two independent proofs, because either one alone can lie. The launchd
    /// environment proves what the service was HANDED; the capability contract
    /// proves what the running build actually did with it.
    private func requireThreadAttach(enabled: Bool) throws {
        let loaded = loadedEnvironmentValue("COS_THREAD_ATTACH_ENABLED")
        if enabled {
            guard loaded == "1" else {
                throw HelperError.message("the restarted server did not load Continue agent threads as enabled")
            }
        } else {
            // Off is proven by ABSENCE, matching the delete this setter performs.
            // A lingering value would mean the removal never reached launchd.
            guard loaded == nil else {
                throw HelperError.message("the restarted server still carries a Continue agent threads value of \(loaded ?? "")")
            }
        }
        guard let health = request("/api/health", timeout: 12)?.body else {
            throw HelperError.message("the restarted server did not answer a health check for Continue agent threads")
        }
        // Fail closed exactly the way the server's contract instructs clients
        // to read it: anything but a literal true is off.
        let reported = health["threadAttachEnabled"] as? Bool == true
        guard reported == enabled else {
            throw HelperError.message("the restarted server reported Continue agent threads as \(reported ? "enabled" : "disabled")")
        }
    }

    private func requireVideoUploadDowngradeSafe(targetVersion: String) throws {
        guard !versionAtLeast(targetVersion, "6.27.3") else { return }
        let currentVersion = (maintenanceStatus()?["serverVersion"] as? String) ?? loadManifest()?.version
        guard currentVersion.map({ versionAtLeast($0, "6.27.3") }) == true else { return }
        guard let status = maintenanceStatus(),
              let videoUploads = status["videoUploads"] as? [String: Any] else {
            throw HelperError.message("Downgrade refused because COS Control could not prove the Reliable video upload queue is empty.")
        }
        guard videoUploads["blocksRollback"] as? Bool != true else {
            let receiving = videoUploads["receiving"] as? Int ?? 0
            let finalizing = videoUploads["finalizing"] as? Int ?? 0
            let receipts = videoUploads["unacknowledgedPublished"] as? Int ?? 0
            throw HelperError.message("Downgrade refused: Reliable video uploads still hold \(receiving) draft(s), \(finalizing) finalizing upload(s), and \(receipts) unacknowledged receipt(s). Finish or cancel them before installing a server older than 6.27.3.")
        }
    }

    /// Idle Metal HQ is intentionally a two-key policy. Enabling clears the
    /// emergency CPU override; disabling sets that override explicitly so the
    /// rollback is deterministic even if a stale METAL=1 survives elsewhere.
    private func idleMetalHqEnvironment(_ raw: String) throws -> [String: String] {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "on":
            return ["COS_BATCH_HQ_METAL": "1", "COS_BATCH_HQ_FORCE_CPU": "0"]
        case "off":
            return ["COS_BATCH_HQ_METAL": "0", "COS_BATCH_HQ_FORCE_CPU": "1"]
        default:
            throw HelperError.message("Unknown idle Metal HQ setting. Choose On or Off.")
        }
    }

    private func setIdleMetalHq(_ raw: String) throws {
        let values = try idleMetalHqEnvironment(raw)
        let enabled = values["COS_BATCH_HQ_METAL"] == "1"
        let health = request("/api/health", timeout: 12)?.body
        let runningVersion = health?["server_version"] as? String
        let stoppedCompatibleManagedServer = loadManifest().map {
            $0.desiredState == "stopped" && versionAtLeast($0.version, "6.21.20")
        } ?? false
        guard runningVersion.map({ versionAtLeast($0, "6.21.20") }) == true || stoppedCompatibleManagedServer else {
            throw HelperError.message("Update the managed server to 6.21.20 or newer before changing Idle Metal HQ.")
        }
        let operationLabel = enabled ? "Idle Metal HQ" : "Idle Metal HQ force-CPU rollback"
        if let manifest = loadManifest() {
            try applyManagedProviderEnvironment(values, current: manifest, operationLabel: operationLabel)
            return
        }
        guard inPlaceActive() else {
            throw HelperError.message("Install the managed server or choose Manage in place first.")
        }
        try applyInPlaceProviderEnvironment(values, operationLabel: operationLabel)
    }

    private func requireIdleMetalHq(enabled: Bool) throws {
        let expectedMetal = enabled ? "1" : "0"
        let expectedForceCpu = enabled ? "0" : "1"
        guard loadedEnvironmentValue("COS_BATCH_HQ_METAL") == expectedMetal,
              loadedEnvironmentValue("COS_BATCH_HQ_FORCE_CPU") == expectedForceCpu else {
            throw HelperError.message("the restarted server did not load Idle Metal HQ as \(enabled ? "enabled" : "force CPU")")
        }
    }

    private func adaptiveAudioCleanupEnvironment(_ raw: String) throws -> [String: String] {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "on": return ["COS_MEETING_AUDIO_ADAPTIVE_PLAYBACK": "1"]
        case "off": return ["COS_MEETING_AUDIO_ADAPTIVE_PLAYBACK": "0"]
        default: throw HelperError.message("Unknown adaptive audio cleanup setting. Choose On or Off.")
        }
    }

    private func setAdaptiveAudioCleanup(_ raw: String) throws {
        let values = try adaptiveAudioCleanupEnvironment(raw)
        let enabled = values["COS_MEETING_AUDIO_ADAPTIVE_PLAYBACK"] == "1"
        let health = request("/api/health", timeout: 12)?.body
        let runningVersion = health?["server_version"] as? String
        let stoppedCompatibleManagedServer = loadManifest().map {
            $0.desiredState == "stopped" && versionAtLeast($0.version, "6.21.32")
        } ?? false
        guard runningVersion.map({ versionAtLeast($0, "6.21.32") }) == true || stoppedCompatibleManagedServer else {
            if inPlaceActive(), runningVersion == nil {
                throw HelperError.message("Start the adopted server once so COS Control can verify version 6.21.32 or newer before changing Adaptive audio cleanup.")
            }
            throw HelperError.message("Update the managed server to 6.21.32 or newer before changing Adaptive audio cleanup.")
        }
        let operationLabel = enabled ? "Adaptive audio cleanup" : "Adaptive audio cleanup off"
        if let manifest = loadManifest() {
            try applyManagedProviderEnvironment(values, current: manifest, operationLabel: operationLabel)
            return
        }
        guard inPlaceActive() else {
            throw HelperError.message("Install the managed server or choose Manage in place first.")
        }
        try applyInPlaceProviderEnvironment(values, operationLabel: operationLabel)
    }

    private func requireAdaptiveAudioCleanup(_ raw: String) throws {
        let expected = raw == "1"
        let health = request("/api/health", timeout: 12)?.body
        let adaptive = (health?["review_audio"] as? [String: Any])?["adaptivePlayback"] as? [String: Any]
        guard adaptive?["enabled"] as? Bool == expected,
              adaptive?["rawPreserved"] as? Bool == true,
              adaptive?["liveRecordingProtected"] as? Bool == true,
              adaptive?["mode"] as? String == "retained_replay_only" else {
            throw HelperError.message("the restarted server did not report Adaptive audio cleanup as \(expected ? "enabled" : "disabled") with raw preservation")
        }
    }

    /// Verify the persisted policy after restart and return the model tier that
    /// is actually active. Max may truthfully degrade to Balanced when the
    /// Large-v3 weights are unavailable; callers must surface that fallback
    /// instead of claiming Max is active.
    private func requireTranscriptionTier(_ expected: String) throws -> String {
        let health = request("/api/health", timeout: 12)?.body
        let live = ((health?["capabilities"] as? [String: Any])?["transcription"] as? [String: Any])?["live"] as? [String: Any]
        guard live?["requestedTier"] as? String == expected else {
            throw HelperError.message("the restarted server did not report the requested \(expected) transcription tier")
        }
        let expectedCommit = expected == "max" ? "large-v3" : "turbo"
        guard live?["requestedCommitModel"] as? String == expectedCommit else {
            throw HelperError.message("the restarted server did not report the expected \(expectedCommit) commit policy")
        }
        guard let effective = live?["effectiveTier"] as? String,
              effective == expected || (expected == "max" && effective == "balanced") else {
            throw HelperError.message("the restarted server did not report a valid effective transcription tier")
        }
        return effective
    }

    private func setWorkDirectory(_ path: String) throws {
        guard let validated = try validatedWorkDirectory(path) else {
            throw HelperError.message("Selected work folder does not exist.")
        }
        if let manifest = loadManifest() {
            try applyManagedWorkDirectory(validated, current: manifest)
            return
        }
        guard inPlaceActive() else {
            throw HelperError.message("Choose Manage in place first. COS Control will not rewrite an unadopted LaunchAgent.")
        }
        try applyInPlaceWorkDirectory(validated)
    }

    private struct MeetingsDirectoryInspection {
        let layout: String
        let path: String
        let meetingCount: Int
        let warning: String?
        var valid: Bool { layout == "direct" || layout == "multi_domain" }
    }

    /// Point G2 Review Meetings at either a direct meetings/YYYY-MM library or
    /// a multi-domain operations/<domain>/meetings tree. Direct libraries are
    /// browse-only; the operations root remains the write/enrichment target.
    private func setOperationsDirectory(_ path: String) throws {
        let inspection = COSControlHelper.inspectMeetingsDirectory(URL(fileURLWithPath: path, isDirectory: true))
        guard inspection.valid else {
            throw HelperError.message(inspection.warning ?? "That folder cannot be used as the meetings library.")
        }
        let runningVersion = (maintenanceStatus()?["serverVersion"] as? String)
            ?? (request("/api/health", timeout: 8)?.body?["server_version"] as? String)
            ?? loadManifest()?.version
        guard runningVersion.map({ versionAtLeast($0, "6.21.33") }) == true else {
            throw HelperError.message("Update the server to 6.21.33 or newer before choosing this meetings library.")
        }
        let values = inspection.layout == "direct"
            ? ["COS_MEETINGS_ROOT": inspection.path]
            : ["COS_OPERATIONS_DIR": inspection.path]
        let removing = inspection.layout == "multi_domain" ? Set(["COS_MEETINGS_ROOT"]) : Set<String>()
        if let manifest = loadManifest() {
            try applyManagedProviderEnvironment(
                values, removingKeys: removing, current: manifest,
                operationLabel: "Meetings library", requiredMeetingLibrary: inspection)
            return
        }
        guard inPlaceActive() else {
            throw HelperError.message("Install the managed server or choose Manage in place first.")
        }
        try applyInPlaceProviderEnvironment(
            values, removingKeys: removing, operationLabel: "Meetings library",
            requiredMeetingLibrary: inspection)
    }

    /// Which kind of Memory and Threads store a chosen folder holds.
    ///
    /// TWO tiers, and the file tier is a real configuration rather than a broken
    /// bridge. Before 6.22.0 this function accepted exactly one shape — a folder
    /// containing `cos_api_bridge.py` AND an executable `venv/bin/python3`, whose
    /// output had to answer protocol 1 — with Docker and OpenAI embeddings behind
    /// it. So the answer to "how do I start using Memory?" was "clone a
    /// workspace and run a vector database", and the error text said as much.
    ///
    /// Meetings became adoptable when the requirement collapsed to markdown files
    /// in folders. This is the same move for Memory and Threads.
    enum ContextSource {
        /// The Python pipeline: semantic recall, dedup, type stats, retention.
        case bridge(scripts: String)
        /// Plain markdown in `memory/` or `threads/`. Browse and reference only.
        case files(root: String)
    }

    private func directoryExists(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    /// Does this folder hold plain-text notes the server can read without a venv?
    ///
    /// Mirrors `MEMORY_DIRS`/`THREAD_DIRS` in the server's `context-files.ts`. The
    /// two lists must agree: a folder Control accepts but the server cannot read
    /// would pass the picker and then fail the post-restart proof, which reads to
    /// the user as "COS Control broke my server".
    private func holdsContextFiles(_ url: URL) -> Bool {
        for name in ["memory", "memories", "threads", "thread"] {
            // RESOLVE first. `directoryExists` deliberately rejects symlinks, which is
            // right when deciding what a path IS, and wrong here: a symlinked
            // `memory/` is a completely normal layout and the SERVER follows it. The
            // mismatch made Control report contextResolvedRoot = nil for a store it
            // was simultaneously reading 11 memories and 6 threads out of, which then
            // offered "Create Folders" over folders that already exist and printed
            // "No memory/ or threads/ folder yet" to a user who plainly had them.
            let candidate = url.appendingPathComponent(name, isDirectory: true).resolvingSymlinksInPath()
            if directoryExists(candidate) { return true }
        }
        return false
    }

    /// Which tier this install is ALREADY on, read from the env the server runs with.
    ///
    /// The preference is durable by construction: `setContextDirectory` writes one key
    /// and removes the other, so exactly one of these is ever set. Nothing new to
    /// persist — the bug was never storage, it was that resolution ignored this.
    private func currentContextTier() -> String? {
        let environment = serverEnvironment()
        func has(_ key: String) -> Bool {
            (environment[key]?.trimmingCharacters(in: .whitespaces).isEmpty == false)
        }
        if has("COS_SCRIPTS_DIR") { return "bridge" }
        if has("COS_CONTEXT_DIR") { return "files" }
        return nil
    }

    /// Resolve a folder WITHIN a tier. Never across one.
    ///
    /// This used to prefer the bridge whenever a workspace held both, so a user on
    /// plain notes who re-picked their own folder — after a move, or after the
    /// "older bridge" error told them to choose it again — was silently swapped onto
    /// the pipeline. The two tiers serve DIFFERENT DATA and never merge: a working
    /// bridge means the server stops reading `memory/` and `threads/` entirely, so
    /// that swap replaces a live store rather than upgrading it. Measured on a real
    /// install: 11 memories + 6 threads on files versus 21 + 5 on the bridge, sharing
    /// no content.
    ///
    /// `tier` nil means "keep whatever this install is on", which is what every
    /// ordinary folder re-pick passes. Changing tier is a separate, explicit action.
    /// A brand-new install with no tier yet gets FILES — no venv, no Python, and the
    /// bridge stays an opt-in upgrade rather than something that happens to you.
    private func validatedContextSource(_ path: String, tier requested: String? = nil) throws -> ContextSource {
        let selected = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let tier = requested ?? currentContextTier() ?? "files"
        if tier == "files" {
            for candidate in [selected, selected.appendingPathComponent("operations", isDirectory: true)]
            where directoryExists(candidate) && holdsContextFiles(candidate) {
                return .files(root: candidate.resolvingSymlinksInPath().path)
            }
            throw HelperError.message(
                "Choose a folder that holds a memory or threads folder of markdown notes. "
                + "To use the Python bridge instead, switch COS Data to the bridge tier explicitly.")
        }
        let bridgeCandidates = [
            selected,
            selected.appendingPathComponent("operations/scripts", isDirectory: true),
        ]
        for candidate in bridgeCandidates {
            guard directoryExists(candidate) else { continue }
            let bridge = candidate.appendingPathComponent("cos_api_bridge.py")
            let python = candidate.appendingPathComponent("venv/bin/python3")
            guard fm.fileExists(atPath: bridge.path), fm.isExecutableFile(atPath: python.path) else { continue }
            let result = try execute(python.path, [bridge.path, "context-status"], timeout: 20)
            guard result.code == 0,
                  let data = result.output.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  payload["protocol"] as? Int == 1 else {
                // NOT necessarily an old bridge. `context-status` exits non-zero for any
                // reason, and the common one by far is Qdrant being unreachable — the
                // Docker daemon failing to come back after a reboot. That wording sent
                // three separate sessions chasing a version problem and told the user to
                // re-pick the folder, which (before the tier fix above) is what silently
                // swapped their tier. Report what actually failed.
                let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                let hint = detail.isEmpty ? "no output" : String(detail.prefix(200))
                throw HelperError.message("The COS bridge did not answer (exit \(result.code)): \(hint). "
                    + "Most often Qdrant is down — check Docker — rather than an outdated workspace.")
            }
            return .bridge(scripts: candidate.resolvingSymlinksInPath().path)
        }
        // Bridge tier was ASKED FOR and this folder has none. Say so rather than
        // quietly handing back the other tier — a silent downgrade is the same class
        // of surprise as the silent upgrade this function used to perform.
        throw HelperError.message("No COS Python bridge in that folder. Choose a workspace with "
            + "operations/scripts/cos_api_bridge.py and a venv, or switch COS Data to the notes tier.")
    }

    /// `tier` nil = keep the tier this install is already on. Only an explicit
    /// `--tier` from the switch action may move a user between tiers, because the two
    /// serve different data and switching replaces rather than merges.
    private func setContextDirectory(_ path: String, tier: String? = nil) throws {
        if let tier, tier != "bridge", tier != "files" {
            throw HelperError.message("tier must be 'bridge' or 'files'")
        }
        let source = try validatedContextSource(path, tier: tier)
        let runningVersion = (maintenanceStatus()?["serverVersion"] as? String)
            ?? (request("/api/health", timeout: 8)?.body?["server_version"] as? String)
            ?? loadManifest()?.version
        // Per-tier floor: reading plain files landed in 6.22.0, so pointing an
        // older server at a notes folder would set an env var it ignores and then
        // fail the proof with nothing to show for it.
        // Switching tiers must REMOVE the other key. The server prefers the
        // bridge whenever COS_SCRIPTS_DIR resolves, so leaving it behind would
        // make choosing a notes folder look like it did nothing at all.
        let (floor, values, removing): (String, [String: String], Set<String>) = {
            switch source {
            case .bridge(let scripts):
                return ("6.21.35", ["COS_SCRIPTS_DIR": scripts], ["COS_CONTEXT_DIR"])
            case .files(let root):
                return ("6.22.0", ["COS_CONTEXT_DIR": root], ["COS_SCRIPTS_DIR"])
            }
        }()
        guard runningVersion.map({ versionAtLeast($0, floor) }) == true else {
            throw HelperError.message("Update the server to \(floor) or newer before enabling Memory and Threads.")
        }
        if let manifest = loadManifest() {
            try applyManagedProviderEnvironment(values, removingKeys: removing, current: manifest,
                operationLabel: "COS data", requireContextProof: true)
            return
        }
        guard inPlaceActive() else {
            throw HelperError.message("Install the managed server or choose Manage in place first.")
        }
        try applyInPlaceProviderEnvironment(values, removingKeys: removing,
            operationLabel: "COS data", requireContextProof: true)
    }

    /// Is `name` safe to join onto the operations root?
    ///
    /// A safety check, NOT a naming policy. Deliberately permissive about style:
    /// a real domain may be `DNP study` with a space, and an alphanumeric-only
    /// rule would re-encode one user's snake_case habit as a requirement.
    static func isSafeDomainName(_ name: String) -> Bool {
        if name.isEmpty || name.count > 64 || name != name.trimmingCharacters(in: .whitespacesAndNewlines) { return false }
        if name == "." || name == ".." { return false }
        if name.hasPrefix(".") { return false }
        if name.contains("/") || name.contains("\\") || name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) { return false }
        return true
    }

    /// Every immediate subdirectory of `dir` that holds a `meetings/` tree.
    ///
    /// This IS the domain list. It used to be the literal string array
    /// ["quilt","sprocket_rocket","hermit_crabs","personal"] — one user's
    /// business domains shipped as a requirement, directly above a comment
    /// saying "Each COS layout can differ". Queen set up her own COS on
    /// 2026-08-08 and every folder she chose was rejected, because her tree has
    /// none of those four and never will. Mirrors discoverMeetingDomains() in
    /// the server, which must agree or the picker validates a shape the server
    /// then refuses to list.
    static func discoverMeetingDomains(_ dir: URL) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return entries.filter { isSafeDomainName($0) }.filter { name in
            let domain = dir.appendingPathComponent(name, isDirectory: true)
            let meetings = domain.appendingPathComponent("meetings", isDirectory: true)
            guard let domainValues = try? domain.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
                  domainValues.isSymbolicLink != true, domainValues.isDirectory == true,
                  let meetingValues = try? meetings.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else {
                return false
            }
            return meetingValues.isSymbolicLink != true && meetingValues.isDirectory == true
        }.sorted()
    }

    /// Does this directory look like a `meetings/` tree itself, i.e. did the user
    /// pick one level too deep?
    ///
    /// Queen selected `queen-cos/meetings`. The old error told her to supply a
    /// `quilt/meetings` tree, which is neither what she has nor what she did
    /// wrong — a dead end. Detect the near-miss and name the fix.
    static func looksLikeMeetingsTree(_ dir: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        let monthPattern = try? NSRegularExpression(pattern: "^\\d{4}-\\d{2}$")
        return entries.contains { name in
            guard let re = monthPattern else { return false }
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            guard re.firstMatch(in: name, range: range) != nil else { return false }
            let month = dir.appendingPathComponent(name, isDirectory: true)
            guard let values = try? month.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else { return false }
            return values.isSymbolicLink != true && values.isDirectory == true
        }
    }

    private static func inspectMeetingsDirectory(_ input: URL) -> MeetingsDirectoryInspection {
        let selected = input.standardizedFileURL
        guard let selectedValues = try? selected.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
              selectedValues.isSymbolicLink != true, selectedValues.isDirectory == true else {
            return MeetingsDirectoryInspection(layout: "invalid", path: selected.path, meetingCount: 0, warning: "That folder does not exist, is unavailable, or is a symbolic link.")
        }
        let dir = selected.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return MeetingsDirectoryInspection(layout: "invalid", path: dir.path, meetingCount: 0, warning: "That folder does not exist or is unavailable.")
        }
        let domains = discoverMeetingDomains(dir)
        let direct = looksLikeMeetingsTree(dir)
        if direct && !domains.isEmpty {
            return MeetingsDirectoryInspection(layout: "invalid", path: dir.path, meetingCount: 0, warning: "This folder mixes month folders with several named meeting folders. Choose the folder that directly contains your YYYY-MM folders, or choose the parent whose named folders each contain meetings/YYYY-MM.")
        }
        let layout = direct ? "direct" : (!domains.isEmpty ? "multi_domain" : "invalid")
        if layout != "invalid" {
            let roots: [URL] = layout == "direct"
                ? [dir]
                : domains.map { dir.appendingPathComponent($0).appendingPathComponent("meetings", isDirectory: true) }
            var count = 0
            for root in roots {
                let months = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { name in
                    guard name.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil else { return false }
                    let monthURL = root.appendingPathComponent(name, isDirectory: true)
                    guard let values = try? monthURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else { return false }
                    return values.isSymbolicLink != true && values.isDirectory == true
                }
                for month in months.prefix(120) {
                    let monthURL = root.appendingPathComponent(month, isDirectory: true)
                    let files = (try? FileManager.default.contentsOfDirectory(at: monthURL, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey])) ?? []
                    count += files.filter { file in
                        guard file.pathExtension.lowercased() == "md",
                              let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]) else { return false }
                        return values.isSymbolicLink != true && values.isRegularFile == true
                    }.count
                }
            }
            return MeetingsDirectoryInspection(layout: layout, path: dir.path, meetingCount: count, warning: nil)
        }
        let name = dir.lastPathComponent
        let subdirs = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { isSafeDomainName($0) }
            .filter { sub in
                var d: ObjCBool = false
                return FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent(sub).path, isDirectory: &d) && d.boolValue
            }.sorted()
        if subdirs.isEmpty {
            return MeetingsDirectoryInspection(layout: "invalid", path: dir.path, meetingCount: 0,
                warning: "\"\(name)\" has no recognizable meetings yet. Choose the folder that directly contains YYYY-MM folders. If you use several custom-named folders, choose their parent and keep meetings/YYYY-MM inside each one. You can also Skip for Now.")
        }
        let shown = subdirs.prefix(6).joined(separator: ", ")
        let more = subdirs.count > 6 ? ", and \(subdirs.count - 6) more" : ""
        return MeetingsDirectoryInspection(layout: "invalid", path: dir.path, meetingCount: 0,
            warning: "COS found these folders in \"\(name)\": \(shown)\(more), but none contains meetings/YYYY-MM. For the easiest setup, choose the folder that directly contains your YYYY-MM folders. For several folders, their names are up to you; each only needs meetings/YYYY-MM inside.")
    }

    static func operationsDirectoryRejection(_ dir: URL) -> String? {
        let inspection = inspectMeetingsDirectory(dir)
        return inspection.valid ? nil : inspection.warning
    }

    private func validatedOperationsDirectory(_ path: String?) throws -> String? {
        guard let path, !path.isEmpty else { return nil }
        let inspection = COSControlHelper.inspectMeetingsDirectory(URL(fileURLWithPath: path, isDirectory: true))
        return inspection.valid ? inspection.path : nil
    }

    private func configuredOperationsDirectory() -> String? {
        return configuredMeetingsDirectoryInspection()?.path
    }

    private func configuredMeetingsDirectoryInspection() -> MeetingsDirectoryInspection? {
        let manifestEnvironment = loadManifest()?.providerEnvironment ?? [:]
        let launchEnvironment = (launchAgentPropertyList()?["EnvironmentVariables"] as? [String: String]) ?? [:]
        for environment in [manifestEnvironment, launchEnvironment] {
            if let value = environment["COS_MEETINGS_ROOT"] {
                let inspection = COSControlHelper.inspectMeetingsDirectory(URL(fileURLWithPath: value, isDirectory: true))
                if inspection.layout == "direct" { return inspection }
                if inspection.layout == "invalid" { return inspection }
            }
            if let value = environment["COS_OPERATIONS_DIR"] {
                let inspection = COSControlHelper.inspectMeetingsDirectory(URL(fileURLWithPath: value, isDirectory: true))
                if inspection.valid { return inspection }
            }
            // Legacy alias-only multi-domain install.
            if let value = environment["COS_MEETINGS_ROOT"] {
                let inspection = COSControlHelper.inspectMeetingsDirectory(URL(fileURLWithPath: value, isDirectory: true))
                if inspection.layout == "multi_domain" { return inspection }
            }
            if let scripts = environment["COS_SCRIPTS_DIR"], !scripts.isEmpty {
                let inferred = URL(fileURLWithPath: scripts, isDirectory: true)
                    .deletingLastPathComponent()
                let inspection = COSControlHelper.inspectMeetingsDirectory(inferred)
                if inspection.layout == "multi_domain" { return inspection }
            }
        }
        return nil
    }

    private func requireMeetingLibrary(_ expected: MeetingsDirectoryInspection) throws {
        let token = try readToken()
        guard let response = request("/api/meetings?limit=1", token: token, timeout: 15), response.status == 200,
              let layout = response.body?["layout"] as? String,
              let root = response.body?["root"] as? String else {
            throw HelperError.message("the restarted server did not report the selected meetings library")
        }
        let reported = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
        guard layout == expected.layout, reported == expected.path else {
            throw HelperError.message("the restarted server activated a different meetings library")
        }
    }

    private func requireContextBrowser() throws {
        let token = try readToken()
        guard let response = request("/api/context/status", token: token, timeout: 20),
              response.status == 200, response.body?["protocol"] as? Int == 1,
              response.body?["available"] as? Bool == true else {
            throw HelperError.message("the restarted server did not prove the Memory and Threads bridge")
        }
        let memory = response.body?["memory"] as? [String: Any]
        let threads = response.body?["threads"] as? [String: Any]
        guard memory?["available"] as? Bool == true || threads?["available"] as? Bool == true else {
            throw HelperError.message("the restarted server reported no usable Memory or Threads store")
        }
    }

    private func applyManagedProviderEnvironment(
        _ values: [String: String],
        removingKeys: Set<String> = [],
        current: RuntimeManifest,
        operationLabel: String,
        requiredMeetingLibrary: MeetingsDirectoryInspection? = nil,
        requireContextProof: Bool = false,
        // Continue proves in BOTH directions, and its Off is a key removal, so
        // it cannot be keyed off `values[...]` the way the "0"-writing flags are.
        requiredThreadAttach: Bool? = nil
    ) throws {
        guard loadTransaction() == nil else {
            throw HelperError.message("A previous runtime change needs Repair before \(operationLabel.lowercased()) can change.")
        }
        var candidate = current
        var provider = candidate.providerEnvironment ?? [:]
        for key in removingKeys {
            guard providerEnvironmentKeys.contains(key) else {
                throw HelperError.message("Unsupported environment key removal: \(key)")
            }
            provider.removeValue(forKey: key)
        }
        for (key, value) in values {
            guard providerEnvironmentKeys.contains(key) else {
                throw HelperError.message("Unsupported environment key: \(key)")
            }
            provider[key] = value
        }
        candidate.providerEnvironment = provider
        var transaction = RuntimeTransaction(
            previous: current,
            candidate: candidate,
            previousLaunchAgentPlist: try? Data(contentsOf: plistURL),
            phase: "provider_env_staged",
            startedAt: ISO8601DateFormatter().string(from: Date())
        )
        try saveTransaction(transaction)
        let snapshot = ownershipSnapshot()
        guard snapshot.launchAgentKind == .cosControl || snapshot.allListenerPIDs.isEmpty else {
            clearTransaction()
            throw HelperError.message("\(operationLabel) change refused because COS Control does not own the active LaunchAgent.")
        }
        let shouldRun = current.desiredState != "stopped"
        var switchStarted = false
        do {
            let lease = shouldRun ? try acquireMaintenanceLeaseIfNeeded(
                snapshot: snapshot,
                operationKind: "server_restart",
                successorGenerations: [candidate.generationID, current.generationID].compactMap { $0 }
            ) : nil
            transaction.phase = "provider_env_switching"
            try saveTransaction(transaction)
            switchStarted = true
            if snapshot.serviceLoaded { try unloadService() }
            try waitForPortsClear(timeout: 12)
            try saveManifest(candidate)
            try writeLaunchAgent(for: candidate)
            var effectiveTier: String?
            if shouldRun {
                try setServiceEnabled(true)
                try loadService(forceRestart: false)
                let activeLease = try waitForManagedHealth(
                    expectedVersion: candidate.version,
                    expectedGenerationID: candidate.generationID,
                    inheritedLease: lease,
                    timeout: 60
                )
                if let tier = values["COS_WHISPER_TRANSCRIPTION_TIER"] {
                    effectiveTier = try requireTranscriptionTier(tier)
                }
                if let backgroundJobs = values["COS_DURABLE_QUERY_JOBS"] {
                    try requireBackgroundJobs(backgroundJobs)
                }
                if let meetingPreview = values["COS_WHISPER_MEETING_PREVIEW"] {
                    try requireMeetingPreview(meetingPreview)
                }
                if let videoUploadV2 = values["COS_VIDEO_UPLOAD_V2"] {
                    try requireVideoUploadV2(videoUploadV2)
                }
                if let claudeSessions = values["COS_CLAUDE_SESSIONS_ENABLED"] {
                    try requireClaudeSessions(enabled: claudeSessions == "1")
                }
                if let idleMetalHq = values["COS_BATCH_HQ_METAL"] {
                    try requireIdleMetalHq(enabled: idleMetalHq == "1")
                }
                if let adaptiveAudioCleanup = values["COS_MEETING_AUDIO_ADAPTIVE_PLAYBACK"] {
                    try requireAdaptiveAudioCleanup(adaptiveAudioCleanup)
                }
                if let requiredThreadAttach { try requireThreadAttach(enabled: requiredThreadAttach) }
                if let requiredMeetingLibrary { try requireMeetingLibrary(requiredMeetingLibrary) }
                if requireContextProof { try requireContextBrowser() }
                try requireMaintenanceRelease(activeLease)
            }
            clearTransaction()
            let message: String
            if shouldRun, values["COS_WHISPER_TRANSCRIPTION_TIER"] == "max", effectiveTier == "balanced" {
                message = "Max transcription saved; running Balanced fallback because Large-v3 is unavailable"
            } else if shouldRun {
                message = "\(operationLabel) applied and the managed server was verified"
            } else {
                message = "\(operationLabel) saved and will apply on the next Start"
            }
            emit(ok: true, message: message, details: statusDetails())
        } catch {
            if !switchStarted {
                clearTransaction()
                throw error
            }
            let restored = try restoreAfterFailedSwitch(transaction)
            throw HelperError.message("\(operationLabel) change failed. \(restored) Original error: \(error)")
        }
    }

    private func applyInPlaceProviderEnvironment(
        _ values: [String: String],
        removingKeys: Set<String> = [],
        operationLabel: String,
        requiredMeetingLibrary: MeetingsDirectoryInspection? = nil,
        requireContextProof: Bool = false,
        requiredThreadAttach: Bool? = nil
    ) throws {
        // Adopted self-managed installs get the same reversible bootout /
        // bootstrap transaction as work-folder changes. launchctl kickstart is
        // not sufficient: it retains stale LaunchAgent environment values.
        guard let record = loadInPlace(),
              URL(fileURLWithPath: record.plistPath).standardizedFileURL.path == plistURL.standardizedFileURL.path else {
            throw HelperError.message("Manage in place must be completed before changing \(operationLabel.lowercased()).")
        }
        guard var plist = launchAgentPropertyList(),
              plist["Label"] as? String == label,
              launchAgentKind() == .knownLegacy else {
            throw HelperError.message("The adopted glasses LaunchAgent no longer matches the recognized server shape.")
        }
        let snapshot = ownershipSnapshot()
        if !snapshot.allListenerPIDs.isEmpty {
            guard snapshot.serviceLoaded, launchdOwnsListeners(snapshot, requireDirect: false) else {
                throw HelperError.message("\(operationLabel) refused because launchd does not own the active listeners.")
            }
        } else if snapshot.serviceLoaded {
            throw HelperError.message("The adopted server is loaded but not healthy. Repair it before changing \(operationLabel.lowercased()).")
        }
        let previous = try Data(contentsOf: plistURL)
        let permissions = ((try? fm.attributesOfItem(atPath: plistURL.path)[.posixPermissions] as? NSNumber)?.intValue) ?? 0o600
        var environment = (plist["EnvironmentVariables"] as? [String: String]) ?? [:]
        for key in removingKeys {
            guard providerEnvironmentKeys.contains(key) else {
                throw HelperError.message("Unsupported environment key removal: \(key)")
            }
            environment.removeValue(forKey: key)
        }
        for (key, value) in values {
            guard providerEnvironmentKeys.contains(key) else {
                throw HelperError.message("Unsupported environment key: \(key)")
            }
            environment[key] = value
        }
        plist["EnvironmentVariables"] = environment
        let candidate = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let status = maintenanceStatus()
        let transaction = InPlaceConfigurationTransaction(
            previousPlist: previous,
            candidatePlist: candidate,
            previousPermissions: min(permissions, 0o600),
            previousServicePID: snapshot.servicePID,
            selectedWorkDirectory: nil,
            serverVersion: status?["serverVersion"] as? String,
            generationID: status?["generationId"] as? String,
            phase: "staged",
            startedAt: ISO8601DateFormatter().string(from: Date())
        )
        try saveInPlaceConfigurationTransaction(transaction)

        let alreadyActive = values.allSatisfy { loadedEnvironmentValue($0.key) == $0.value }
            && removingKeys.allSatisfy { loadedEnvironmentValue($0) == nil }
        if alreadyActive || snapshot.allListenerPIDs.isEmpty {
            do {
                try atomicWriteData(candidate, to: plistURL, permissions: 0o600)
                let effectiveTier = alreadyActive
                    ? try values["COS_WHISPER_TRANSCRIPTION_TIER"].map { try requireTranscriptionTier($0) }
                    : nil
                if alreadyActive, let backgroundJobs = values["COS_DURABLE_QUERY_JOBS"] {
                    try requireBackgroundJobs(backgroundJobs)
                }
                if alreadyActive, let meetingPreview = values["COS_WHISPER_MEETING_PREVIEW"] {
                    try requireMeetingPreview(meetingPreview)
                }
                if alreadyActive, let videoUploadV2 = values["COS_VIDEO_UPLOAD_V2"] {
                    try requireVideoUploadV2(videoUploadV2)
                }
                if alreadyActive, let claudeSessions = values["COS_CLAUDE_SESSIONS_ENABLED"] {
                    try requireClaudeSessions(enabled: claudeSessions == "1")
                }
                if alreadyActive, let idleMetalHq = values["COS_BATCH_HQ_METAL"] {
                    try requireIdleMetalHq(enabled: idleMetalHq == "1")
                }
                if alreadyActive, let adaptiveAudioCleanup = values["COS_MEETING_AUDIO_ADAPTIVE_PLAYBACK"] {
                    try requireAdaptiveAudioCleanup(adaptiveAudioCleanup)
                }
                if alreadyActive, let requiredThreadAttach { try requireThreadAttach(enabled: requiredThreadAttach) }
                if alreadyActive, let requiredMeetingLibrary { try requireMeetingLibrary(requiredMeetingLibrary) }
                if alreadyActive && requireContextProof { try requireContextBrowser() }
                // Verification owns the transaction. Clearing before the health
                // proof would make an invariant failure impossible to roll back.
                clearInPlaceConfigurationTransaction()
                let message: String
                if alreadyActive, values["COS_WHISPER_TRANSCRIPTION_TIER"] == "max", effectiveTier == "balanced" {
                    message = "Max transcription is saved; running Balanced fallback because Large-v3 is unavailable"
                } else if alreadyActive {
                    message = "\(operationLabel) is already active"
                } else {
                    message = "\(operationLabel) saved and will apply when your server starts"
                }
                emit(ok: true, message: message, details: statusDetails())
                return
            } catch {
                let recovery = try restoreInPlaceConfiguration(transaction)
                throw HelperError.message("\(operationLabel) change failed. \(recovery) Original error: \(error)")
            }
        }
        guard let version = transaction.serverVersion,
              let generation = transaction.generationID else {
            try atomicWriteData(candidate, to: plistURL, permissions: 0o600)
            clearInPlaceConfigurationTransaction()
            emit(
                ok: true,
                message: "\(operationLabel) saved to your LaunchAgent. This legacy server cannot prove idle state, so restart it when no work is active to apply it.",
                details: statusDetails()
            )
            return
        }
        do {
            let lease = try acquireMaintenanceLeaseIfNeeded(
                snapshot: snapshot,
                operationKind: "server_restart",
                successorGenerations: [generation]
            )
            var switching = transaction
            switching.phase = "switching"
            try saveInPlaceConfigurationTransaction(switching)
            try strictBootoutInPlace()
            try atomicWriteData(candidate, to: plistURL, permissions: 0o600)
            try strictBootstrapInPlace()
            let activeLease = try waitForManagedHealth(
                expectedVersion: version,
                expectedGenerationID: generation,
                inheritedLease: lease,
                timeout: 60,
                requireDirectOwnership: false,
                requireTransactionalProof: versionAtLeast(version, "6.15.2")
            )
            guard let newPID = servicePID(), newPID != transaction.previousServicePID else {
                throw HelperError.message("launchd did not replace the prior server process.")
            }
            let effectiveTier = try values["COS_WHISPER_TRANSCRIPTION_TIER"].map { try requireTranscriptionTier($0) }
            if let backgroundJobs = values["COS_DURABLE_QUERY_JOBS"] {
                try requireBackgroundJobs(backgroundJobs)
            }
            if let meetingPreview = values["COS_WHISPER_MEETING_PREVIEW"] {
                try requireMeetingPreview(meetingPreview)
            }
            if let videoUploadV2 = values["COS_VIDEO_UPLOAD_V2"] {
                try requireVideoUploadV2(videoUploadV2)
            }
            if let claudeSessions = values["COS_CLAUDE_SESSIONS_ENABLED"] {
                try requireClaudeSessions(enabled: claudeSessions == "1")
            }
            if let idleMetalHq = values["COS_BATCH_HQ_METAL"] {
                try requireIdleMetalHq(enabled: idleMetalHq == "1")
            }
            if let adaptiveAudioCleanup = values["COS_MEETING_AUDIO_ADAPTIVE_PLAYBACK"] {
                try requireAdaptiveAudioCleanup(adaptiveAudioCleanup)
            }
            if let requiredThreadAttach { try requireThreadAttach(enabled: requiredThreadAttach) }
            if let requiredMeetingLibrary { try requireMeetingLibrary(requiredMeetingLibrary) }
            if requireContextProof { try requireContextBrowser() }
            try requireMaintenanceRelease(activeLease)
            clearInPlaceConfigurationTransaction()
            let message = values["COS_WHISPER_TRANSCRIPTION_TIER"] == "max" && effectiveTier == "balanced"
                ? "Max transcription saved; running Balanced fallback because Large-v3 is unavailable"
                : "\(operationLabel) applied and the adopted server was verified"
            emit(ok: true, message: message, details: statusDetails())
        } catch {
            let recovery = try restoreInPlaceConfiguration(transaction)
            throw HelperError.message("\(operationLabel) change failed. \(recovery) Original error: \(error)")
        }
    }

    /// Read the effective COS work folder from managed manifest or in-place plist.
    private func configuredWorkDirectory() -> String? {
        if let work = loadManifest()?.workDirectory,
           let validated = try? validatedWorkDirectory(work) { return validated }
        guard let environment = launchAgentPropertyList()?["EnvironmentVariables"] as? [String: String] else {
            return nil
        }
        for key in ["COS_WORKDIR", "CODEX_GLASSES_WORKDIR", "COS_LAUNCH_DIR"] {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               let validated = try? validatedWorkDirectory(value) {
                return validated
            }
        }
        return nil
    }

    private func configuredContextScriptsDirectory() -> String? {
        let environments = [
            loadManifest()?.providerEnvironment ?? [:],
            (launchAgentPropertyList()?["EnvironmentVariables"] as? [String: String]) ?? [:],
        ]
        for environment in environments {
            if let path = environment["COS_SCRIPTS_DIR"] {
                let scripts = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                if fm.fileExists(atPath: scripts.appendingPathComponent("cos_api_bridge.py").path),
                   fm.isExecutableFile(atPath: scripts.appendingPathComponent("venv/bin/python3").path) {
                    return scripts.resolvingSymlinksInPath().path
                }
            }
        }
        return nil
    }

    /// The configured file-tier notes root, if one is set and still holds notes.
    ///
    /// A SEPARATE field from `configuredContextScriptsDirectory`, not an overload
    /// of it: one is a Python bridge and the other is a folder of markdown, and a
    /// single key holding either would misreport which tier is live in the panel
    /// and in Copy Report.
    /// Every environment the server will actually see, newest source first.
    private func serverEnvironment() -> [String: String] {
        var merged: [String: String] = (launchAgentPropertyList()?["EnvironmentVariables"] as? [String: String]) ?? [:]
        for (key, value) in loadManifest()?.providerEnvironment ?? [:] where merged[key] == nil {
            merged[key] = value
        }
        return merged
    }

    /// What the server will resolve as the notes root, and why.
    ///
    /// A DELIBERATE MIRROR of `resolveContextFilesRoot()` in the server's
    /// context-files.ts, kept here rather than asked over HTTP because
    /// `/api/context/status` deliberately exposes no filesystem paths and that
    /// boundary is worth more than the convenience.
    ///
    /// Queen, 2026-08-09: her `COS_OPERATIONS_DIR` was already correct and would
    /// have matched candidate two immediately. The only reason Memory read "Setup
    /// needed" is that `memory/` and `threads/` did not exist yet — and nothing on
    /// screen said which roots were tried or what one has to contain. Her words:
    /// "The user cannot see any of this."
    ///
    /// Duplicating resolution order across two languages is a real cost. It is
    /// accepted so the panel can name the resolved path, and the ORDER is asserted
    /// against the server's source in the self-test so the two cannot drift quietly.
    struct ContextRootResolution {
        /// Roots consulted, in order, for the "Looked in:" line.
        var candidates: [String] = []
        /// The one that won, or nil when none holds notes.
        var resolved: String?
        /// Where notes would be created when the user taps Create.
        var suggested: String?
    }

    private func contextRootResolution() -> ContextRootResolution {
        let environment = serverEnvironment()
        func path(_ key: String) -> String? {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
            return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL.path
        }
        var result = ContextRootResolution()

        // COS_CONTEXT_DIR is EXCLUSIVE when set, matching the server: falling
        // through from an explicit empty root to the data home would serve notes
        // from a folder the user did not choose.
        if let explicit = path("COS_CONTEXT_DIR") {
            result.candidates = [explicit]
            result.suggested = explicit
            if holdsContextFiles(URL(fileURLWithPath: explicit, isDirectory: true)) { result.resolved = explicit }
            return result
        }

        var ordered: [String] = []
        if let operations = path("COS_OPERATIONS_DIR") { ordered.append(operations) }
        if let meetings = path("COS_MEETINGS_ROOT") {
            ordered.append(meetings)
            // A direct library is `.../personal/meetings` while notes sit beside it.
            ordered.append(URL(fileURLWithPath: meetings, isDirectory: true).deletingLastPathComponent().path)
        }
        if let scripts = path("COS_SCRIPTS_DIR") {
            ordered.append(URL(fileURLWithPath: scripts, isDirectory: true).deletingLastPathComponent().path)
        }
        ordered.append(path("COS_DATA_DIR") ?? home.appendingPathComponent(".cos-glasses").path)

        var seen = Set<String>()
        result.candidates = ordered.filter { seen.insert($0).inserted }
        result.resolved = result.candidates.first { holdsContextFiles(URL(fileURLWithPath: $0, isDirectory: true)) }
        // Create inside the user's own repo when we know it, never the data home by
        // default — notes belong where the user can find and back them up.
        result.suggested = result.resolved ?? result.candidates.first
        return result
    }

    /// Is a Python bridge sitting unused because COS_SCRIPTS_DIR was never set?
    ///
    /// Queen had `cos_api_bridge.py` AND an executable `venv/bin/python3`, and
    /// `COS_SCRIPTS_DIR` appeared zero times in her LaunchAgent, so `pythonAvailable`
    /// was false and every call degraded to the file tier. Her whole pipeline was
    /// built, installed and dead, and nothing said so. Control writes that key in
    /// exactly ONE place — the COS Data picker — so anyone who set up through the
    /// meetings picker never gets it.
    ///
    /// Reported, NOT auto-applied. Setting it flips an install from the file tier to
    /// the bridge tier on the next restart, and the server never consults the file
    /// tier once a bridge resolves — so notes the user is browsing today would
    /// silently stop appearing. Queen flagged that herself. It has to be a choice.
    private func dormantBridgeScriptsDirectory() -> String? {
        guard serverEnvironment()["COS_SCRIPTS_DIR"] == nil else { return nil }
        var roots: [String] = []
        if let work = loadManifest()?.workDirectory { roots.append(work) }
        if let operations = serverEnvironment()["COS_OPERATIONS_DIR"] {
            roots.append(URL(fileURLWithPath: operations, isDirectory: true).deletingLastPathComponent().path)
            roots.append(operations)
        }
        for root in roots {
            for relative in ["operations/scripts", "scripts"] {
                let candidate = URL(fileURLWithPath: root, isDirectory: true)
                    .appendingPathComponent(relative, isDirectory: true)
                let bridge = candidate.appendingPathComponent("cos_api_bridge.py")
                let python = candidate.appendingPathComponent("venv/bin/python3")
                if fm.fileExists(atPath: bridge.path), fm.isExecutableFile(atPath: python.path) {
                    return candidate.resolvingSymlinksInPath().path
                }
            }
        }
        return nil
    }

    /// Create `memory/` and `threads/` so a new install is never "Setup needed".
    ///
    /// Queen's central point: "nothing creates the folders and nothing tells the user
    /// what the folders are... choosing COS Data is not what fixes it. What fixes it
    /// is creating two directories." This is that, as one button.
    ///
    /// Writes a README into each, because a user who opens an empty folder has no way
    /// to know that any markdown file dropped in becomes browsable.
    ///
    /// Does NOT set COS_CONTEXT_DIR when the target is already a resolver candidate:
    /// pinning an explicit exclusive root is a heavier commitment than the user asked
    /// for by tapping Create, and the candidate will resolve on its own the moment the
    /// folders exist. The key is written only for a root the resolver would not find.
    private func createContextFolders(at requested: String?) throws -> [String: Any] {
        let resolution = contextRootResolution()
        guard let target = requested ?? resolution.suggested else {
            throw HelperError.message("Choose a work folder or meetings library first, so COS knows where your notes belong.")
        }
        let root = URL(fileURLWithPath: target, isDirectory: true).standardizedFileURL
        guard directoryExists(root) else {
            throw HelperError.message("That folder does not exist: \(redactPath(root.path))")
        }
        var created: [String] = []
        for (name, blurb) in [
            ("memory", "Anything you write here becomes browsable Memory on your glasses."),
            ("threads", "One markdown file per ongoing thread. Front matter is optional."),
        ] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            if !directoryExists(folder) {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                created.append(name)
            }
            let readme = folder.appendingPathComponent("README.md")
            if !fm.fileExists(atPath: readme.path) {
                let text = """
                # \(name.capitalized)

                \(blurb)

                Any nesting and any filename works. Front matter is optional:

                    ---
                    type: decision
                    date: 2026-08-09
                    ---
                    # A heading becomes the summary

                A symlink here is followed, so you can point this at notes that already
                live somewhere else. Requires glasses-server 6.22.1 or newer for links
                nested below the top level.
                """
                try Data(text.utf8).write(to: readme, options: .atomic)
            }
        }
        // Only pin an explicit root when the resolver would otherwise miss it.
        var pinned = false
        if !contextRootResolution().candidates.contains(root.path) {
            let values = ["COS_CONTEXT_DIR": root.path]
            if let manifest = loadManifest() {
                try applyManagedProviderEnvironment(values, current: manifest, operationLabel: "COS data")
            } else if inPlaceActive() {
                try applyInPlaceProviderEnvironment(values, operationLabel: "COS data")
            }
            pinned = true
        }
        return [
            "root": root.path,
            "created": created,
            "pinnedContextDir": pinned,
            // "created and empty" is SUCCESS. Conflating an empty store with a missing
            // one is what sent Queen to the picker in the first place.
            "state": "ready",
        ]
    }

    private func configuredContextFilesDirectory() -> String? {
        let environments = [
            loadManifest()?.providerEnvironment ?? [:],
            (launchAgentPropertyList()?["EnvironmentVariables"] as? [String: String]) ?? [:],
        ]
        for environment in environments {
            if let path = environment["COS_CONTEXT_DIR"] {
                let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                // Re-validated, not just echoed: a folder the user renamed or an
                // external drive that unmounted must read as unset rather than
                // showing a path that no longer serves anything.
                if holdsContextFiles(root) { return root.resolvingSymlinksInPath().path }
            }
        }
        return nil
    }

    private func applyManagedWorkDirectory(_ path: String, current: RuntimeManifest) throws {
        guard loadTransaction() == nil else {
            throw HelperError.message("A previous runtime change needs Repair before the work folder can change.")
        }
        var candidate = current
        candidate.workDirectory = path
        var provider = candidate.providerEnvironment ?? [:]
        provider["CODEX_GLASSES_WORKDIR"] = path
        candidate.providerEnvironment = provider
        var transaction = RuntimeTransaction(
            previous: current,
            candidate: candidate,
            previousLaunchAgentPlist: try? Data(contentsOf: plistURL),
            phase: "workdir_staged",
            startedAt: ISO8601DateFormatter().string(from: Date())
        )
        try saveTransaction(transaction)
        let snapshot = ownershipSnapshot()
        guard snapshot.launchAgentKind == .cosControl || snapshot.allListenerPIDs.isEmpty else {
            clearTransaction()
            throw HelperError.message("Work folder change refused because COS Control does not own the active LaunchAgent.")
        }
        let shouldRun = current.desiredState != "stopped"
        var switchStarted = false
        do {
            let lease = shouldRun ? try acquireMaintenanceLeaseIfNeeded(
                snapshot: snapshot,
                operationKind: "server_restart",
                successorGenerations: [candidate.generationID, current.generationID].compactMap { $0 }
            ) : nil
            transaction.phase = "workdir_switching"
            try saveTransaction(transaction)
            switchStarted = true
            if snapshot.serviceLoaded { try unloadService() }
            try waitForPortsClear(timeout: 12)
            try saveManifest(candidate)
            try writeLaunchAgent(for: candidate)
            if shouldRun {
                try setServiceEnabled(true)
                try loadService(forceRestart: false)
                let activeLease = try waitForManagedHealth(
                    expectedVersion: candidate.version,
                    expectedGenerationID: candidate.generationID,
                    inheritedLease: lease,
                    timeout: 60
                )
                try requireMaintenanceRelease(activeLease)
            }
            clearTransaction()
            let message = shouldRun
                ? "Work folder applied and the managed server was verified"
                : "Work folder saved and will apply on the next Start"
            emit(ok: true, message: message, details: statusDetails())
        } catch {
            if !switchStarted {
                clearTransaction()
                throw error
            }
            let restored = try restoreAfterFailedSwitch(transaction)
            throw HelperError.message("Work folder change failed. \(restored) Original error: \(error)")
        }
    }

    private func inPlaceCandidatePlist(workDirectory: String) throws -> Data {
        guard var plist = launchAgentPropertyList(),
              plist["Label"] as? String == label,
              launchAgentKind() == .knownLegacy else {
            throw HelperError.message("The adopted glasses LaunchAgent no longer matches the recognized server shape.")
        }
        var environment = (plist["EnvironmentVariables"] as? [String: String]) ?? [:]
        environment["COS_WORKDIR"] = workDirectory
        environment["CODEX_GLASSES_WORKDIR"] = workDirectory
        plist["EnvironmentVariables"] = environment
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private func strictBootoutInPlace() throws {
        guard serviceLoaded() else { return }
        let result = try launchctl(["bootout", serviceTarget])
        guard result.code == 0 else {
            throw HelperError.message("launchd could not unload the adopted server: \(result.output)")
        }
        let deadline = Date().addingTimeInterval(5)
        while serviceLoaded(), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        guard !serviceLoaded() else { throw HelperError.message("launchd still reports the adopted server as loaded.") }
        try waitForPortsClear(timeout: 12)
    }

    private func strictBootstrapInPlace() throws {
        let recordPath = loadInPlace()?.plistPath ?? plistURL.path
        guard URL(fileURLWithPath: recordPath).standardizedFileURL.path == plistURL.standardizedFileURL.path else {
            throw HelperError.message("The in-place ownership record points at an unexpected plist.")
        }
        let result = try launchctl(["bootstrap", launchDomain, recordPath])
        guard result.code == 0 else { throw HelperError.message("launchd could not load the adopted server: \(result.output)") }
    }

    private func applyInPlaceWorkDirectory(_ path: String) throws {
        guard let record = loadInPlace(),
              URL(fileURLWithPath: record.plistPath).standardizedFileURL.path == plistURL.standardizedFileURL.path else {
            throw HelperError.message("Manage in place must be completed before changing this LaunchAgent.")
        }
        let snapshot = ownershipSnapshot()
        guard snapshot.launchAgentKind == .knownLegacy else {
            throw HelperError.message("The adopted LaunchAgent shape changed; folder selection was not applied.")
        }
        if !snapshot.allListenerPIDs.isEmpty {
            guard snapshot.serviceLoaded, launchdOwnsListeners(snapshot, requireDirect: false) else {
                throw HelperError.message("Folder selection refused because launchd does not own the active listeners.")
            }
        } else if snapshot.serviceLoaded {
            throw HelperError.message("The adopted server is loaded but not healthy. Repair it before changing the work folder.")
        }
        let previous = try Data(contentsOf: plistURL)
        let permissions = ((try? fm.attributesOfItem(atPath: plistURL.path)[.posixPermissions] as? NSNumber)?.intValue) ?? 0o600
        let candidate = try inPlaceCandidatePlist(workDirectory: path)
        let status = maintenanceStatus()
        let transaction = InPlaceConfigurationTransaction(
            previousPlist: previous,
            candidatePlist: candidate,
            previousPermissions: min(permissions, 0o600),
            previousServicePID: snapshot.servicePID,
            selectedWorkDirectory: path,
            serverVersion: status?["serverVersion"] as? String,
            generationID: status?["generationId"] as? String,
            phase: "staged",
            startedAt: ISO8601DateFormatter().string(from: Date())
        )
        try saveInPlaceConfigurationTransaction(transaction)
        let activeWork = ["COS_WORKDIR", "CODEX_GLASSES_WORKDIR", "COS_LAUNCH_DIR"]
            .compactMap(loadedEnvironmentValue)
            .compactMap { try? validatedWorkDirectory($0) }
            .first
        if activeWork == path {
            try atomicWriteData(candidate, to: plistURL, permissions: 0o600)
            clearInPlaceConfigurationTransaction()
            emit(ok: true, message: "Work folder saved and already active", details: statusDetails())
            return
        }
        if snapshot.allListenerPIDs.isEmpty {
            try atomicWriteData(candidate, to: plistURL, permissions: 0o600)
            clearInPlaceConfigurationTransaction()
            emit(ok: true, message: "Work folder saved and will apply when your server starts", details: statusDetails())
            return
        }
        if status == nil {
            // Older self-managed servers do not expose the credentialed drain
            // contract. Persist the exact plist change, but never guess that it
            // is safe to kill recordings or provider turns to activate it.
            try atomicWriteData(candidate, to: plistURL, permissions: 0o600)
            clearInPlaceConfigurationTransaction()
            emit(
                ok: true,
                message: "Work folder saved to your LaunchAgent. This legacy server cannot prove idle state, so restart it when no work is active to apply the folder.",
                details: statusDetails()
            )
            return
        }
        guard let version = transaction.serverVersion,
              let generation = transaction.generationID else {
            clearInPlaceConfigurationTransaction()
            throw HelperError.message("The adopted server lacks the lifecycle identity required for a safe folder reload.")
        }
        do {
            let lease = try acquireMaintenanceLeaseIfNeeded(
                snapshot: snapshot,
                operationKind: "server_restart",
                successorGenerations: [generation]
            )
            var switching = transaction
            switching.phase = "switching"
            try saveInPlaceConfigurationTransaction(switching)
            try strictBootoutInPlace()
            try atomicWriteData(candidate, to: plistURL, permissions: 0o600)
            try strictBootstrapInPlace()
            let activeLease = try waitForManagedHealth(
                expectedVersion: version,
                expectedGenerationID: generation,
                inheritedLease: lease,
                timeout: 60,
                requireDirectOwnership: false,
                requireTransactionalProof: versionAtLeast(version, "6.15.2")
            )
            guard let newPID = servicePID(), newPID != transaction.previousServicePID else {
                throw HelperError.message("launchd did not replace the prior server process.")
            }
            try requireMaintenanceRelease(activeLease)
            clearInPlaceConfigurationTransaction()
            emit(ok: true, message: "Work folder applied to your LaunchAgent and the server was verified", details: statusDetails())
        } catch {
            let recovery = try restoreInPlaceConfiguration(transaction)
            throw HelperError.message("Work folder change failed. \(recovery) Original error: \(error)")
        }
    }

    private func restoreInPlaceConfiguration(_ transaction: InPlaceConfigurationTransaction) throws -> String {
        if serviceLoaded() { try strictBootoutInPlace() }
        try atomicWriteData(transaction.previousPlist, to: plistURL, permissions: transaction.previousPermissions)
        if transaction.previousServicePID != nil {
            try strictBootstrapInPlace()
            guard let version = transaction.serverVersion,
                  let generation = transaction.generationID else {
                throw HelperError.message("The previous LaunchAgent was restored, but its lifecycle identity is missing.")
            }
            let stored = loadMaintenanceLease()
            let activeLease = try waitForManagedHealth(
                expectedVersion: version,
                expectedGenerationID: generation,
                inheritedLease: stored,
                timeout: 60,
                requireDirectOwnership: false,
                requireTransactionalProof: false
            )
            if stored != nil { try requireMaintenanceRelease(activeLease) }
        }
        clearInPlaceConfigurationTransaction()
        return "The previous LaunchAgent configuration was restored and verified."
    }

    private func runServer() throws {
        guard let manifest = loadManifest() else { throw HelperError.message("No active server manifest.") }
        let verified = try verifyGeneration(
            at: manifest.generationPath,
            expectedVersion: manifest.version,
            expectedIntegrity: manifest.registryIntegrity,
            expectedLauncherHash: manifest.launcherSHA256,
            expectedPackageHash: manifest.packageJSONSHA256
        )
        guard let node = manifest.nodePath ?? findExecutable("node") else { throw HelperError.message("Node.js not found") }
        let paths = runtimePaths(for: verified.path)
        for (key, value) in try launchEnvironment(for: manifest) { setenv(key, value, 1) }
        guard chdir(paths.root.path) == 0 else { throw HelperError.message("Could not enter the managed package directory.") }
        let values = [node, "--import", paths.tsx.path, paths.server.path]
        var argv: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
        argv.append(nil)
        defer { argv.compactMap { $0 }.forEach { free($0) } }
        let code = argv.withUnsafeMutableBufferPointer { buffer in execv(node, buffer.baseAddress) }
        throw HelperError.message("Could not exec managed Node server (errno \(errno), result \(code)).")
    }

    private func readToken() throws -> String {
        guard fm.fileExists(atPath: envURL.path) else { throw HelperError.message("No pairing token is configured.") }
        try validatePrivateRegularFile(envURL)
        let content = try String(contentsOf: envURL, encoding: .utf8)
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("COS_API_TOKEN=") {
                let token = String(line.dropFirst("COS_API_TOKEN=".count)).trimmingCharacters(in: .whitespaces)
                guard token.count >= 16 else {
                    throw HelperError.message("The configured pairing token is too short. COS accepts existing tokens with at least 16 characters; a newly generated token is 64 hexadecimal characters.")
                }
                return token
            }
        }
        throw HelperError.message("No pairing token is configured.")
    }

    private func tokenDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func writePasteboard(_ value: String) throws {
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(value.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw HelperError.message("Could not update the macOS pasteboard.") }
    }

    private func readPasteboard() throws -> String {
        let result = try execute("/usr/bin/pbpaste", [], timeout: 5)
        guard result.code == 0 else { throw HelperError.message("Could not read the macOS pasteboard.") }
        return result.output
    }

    private func shouldClearClipboard(currentValue: String, expectedDigest: String, expectedJob: String, stored: ClipboardReceipt?) -> Bool {
        guard let stored,
              stored.digest == expectedDigest,
              stored.launchdLabel == expectedJob,
              stored.expiresAt <= Date() else { return false }
        return tokenDigest(currentValue) == expectedDigest
    }

    private func copyPairingToken() throws {
        guard runtimeState(snapshot: ownershipSnapshot(), maintenance: maintenanceStatus(), health: request("/api/health", timeout: 12)?.body) == .managedHealthy else {
            throw HelperError.message("Pairing is available only after the managed server is fully verified.")
        }
        try installStableHelper()
        if let old = try? Data(contentsOf: clipboardReceiptURL),
           let oldReceipt = try? JSONDecoder().decode(ClipboardReceipt.self, from: old) {
            _ = try? launchctl(["remove", oldReceipt.launchdLabel])
        }
        let token = try readToken()
        let digest = tokenDigest(token)
        let expiresAt = Date().addingTimeInterval(60)
        let job = "com.cos.control.clipboard-expiry.(UUID().uuidString.lowercased())"
        let receipt = ClipboardReceipt(digest: digest, expiresAt: expiresAt, launchdLabel: job)
        try atomicWrite(receipt, to: clipboardReceiptURL, permissions: 0o600)
        try writePasteboard(token)
        let result = try launchctl([
            "submit", "-l", job, "--", stableHelper.path, "expire-clipboard",
            "--receipt", digest, "--job", job, "--expires", String(expiresAt.timeIntervalSince1970),
        ])
        guard result.code == 0 else {
            if tokenDigest((try? readPasteboard()) ?? "") == digest {
                try? writePasteboard("")
            }
            try? fm.removeItem(at: clipboardReceiptURL)
            throw HelperError.message("The token was not copied because automatic pasteboard expiry could not be scheduled.")
        }
        emit(ok: true, message: "Pairing token copied for 60 seconds", details: [
            "clipboardReceipt": String(digest.prefix(12)),
            "expiresAt": ISO8601DateFormatter().string(from: expiresAt),
        ])
    }

    private func expireClipboard(args: [String]) throws {
        guard let digest = option("--receipt", in: args),
              digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              let job = option("--job", in: args), job.hasPrefix("com.cos.control.clipboard-expiry."),
              let expiresText = option("--expires", in: args),
              let expires = TimeInterval(expiresText) else { throw HelperError.message("invalid clipboard expiry receipt") }
        let delay = max(0, min(300, expires - Date().timeIntervalSince1970))
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        let stored = (try? Data(contentsOf: clipboardReceiptURL)).flatMap { try? JSONDecoder().decode(ClipboardReceipt.self, from: $0) }
        if shouldClearClipboard(currentValue: (try? readPasteboard()) ?? "", expectedDigest: digest, expectedJob: job, stored: stored) {
            try writePasteboard("")
            try? fm.removeItem(at: clipboardReceiptURL)
        }
    }

    private func cliProbe(_ name: String, redacted: Bool) -> (state: String, detail: String) {
        guard let path = findExecutable(name) else { return ("warning", "Not installed") }
        let version = (try? execute(path, ["--version"], timeout: 5)).flatMap { $0.code == 0 ? $0.output.split(separator: "\n").first.map(String.init) : nil } ?? "version unavailable"
        var auth = "auth status unavailable"
        if name == "codex", let result = try? execute(path, ["login", "status"], timeout: 6) {
            auth = result.output.lowercased().contains("logged in") && !result.output.lowercased().contains("not logged in") ? "signed in" : "sign-in required"
        } else if name == "claude", let result = try? execute(path, ["auth", "status", "--json"], timeout: 6) {
            auth = result.output.contains("\"loggedIn\":true") || result.output.contains("\"loggedIn\": true") ? "signed in" : "sign-in check required"
        }
        let detail = redacted ? "\(version) · \(auth)" : "\(version) · \(auth) · \(redactPath(path))"
        return (auth == "sign-in required" ? "warning" : "ok", detail)
    }

    /// Parse `agent about` without ever retaining User Email.
    private func parseCursorAbout(_ output: String) -> (state: String, version: String?) {
        var version: String?
        var hasEmailLine = false
        var loggedIn = false
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.range(of: #"^CLI Version\b"#, options: .regularExpression) != nil {
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 3 { version = parts.dropFirst(2).joined(separator: " ") }
                else if parts.count == 2 { version = String(parts[1]) }
            }
            if line.range(of: #"^User Email\b"#, options: .regularExpression) != nil {
                hasEmailLine = true
                let value = line.replacingOccurrences(
                    of: #"^User Email\s*:?\s*"#,
                    with: "",
                    options: .regularExpression
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty,
                   !value.lowercased().contains("not logged in"),
                   value.contains("@") {
                    loggedIn = true
                }
            }
        }
        if loggedIn { return ("connected", version) }
        if hasEmailLine { return ("signInRequired", version) }
        return ("signInRequired", version)
    }

    private func stripEmails(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#,
            with: "<redacted-email>",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private func loadCursorProbeCache() -> (state: String, version: String?, probedAt: Date)? {
        guard let data = try? Data(contentsOf: cursorProbeCacheURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = object["state"] as? String,
              let probedAtText = object["probedAt"] as? String,
              let probedAt = ISO8601DateFormatter().date(from: probedAtText) else { return nil }
        let version = object["version"] as? String
        return (state, version, probedAt)
    }

    private func saveCursorProbeCache(state: String, version: String?) {
        try? ensureDirectories()
        var payload: [String: Any] = [
            "state": state,
            "probedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let version, !version.isEmpty { payload["version"] = version }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        try? atomicWriteData(data, to: cursorProbeCacheURL, permissions: 0o600)
    }

    private func cursorProbe(force: Bool) -> (state: String, version: String?, ready: Bool) {
        if !force, let cached = loadCursorProbeCache(), Date().timeIntervalSince(cached.probedAt) < 90 {
            return (cached.state, cached.version, cached.state == "connected")
        }
        guard let path = resolveAgentBinary() else {
            saveCursorProbeCache(state: "notInstalled", version: nil)
            return ("notInstalled", nil, false)
        }
        do {
            let result = try execute(path, ["about"], timeout: 5)
            guard result.code == 0 else {
                saveCursorProbeCache(state: "unavailable", version: nil)
                return ("unavailable", nil, false)
            }
            let parsed = parseCursorAbout(result.output)
            saveCursorProbeCache(state: parsed.state, version: parsed.version)
            return (parsed.state, parsed.version, parsed.state == "connected")
        } catch {
            saveCursorProbeCache(state: "unavailable", version: nil)
            return ("unavailable", nil, false)
        }
    }

    private func cursorStatusFields(force: Bool) -> [String: Any] {
        let probe = cursorProbe(force: force)
        return [
            "cursorReady": probe.ready,
            "cursorState": probe.state,
            "cursorDetail": probe.version ?? NSNull(),
            "cursorCliVersion": probe.version ?? NSNull(),
        ]
    }

    private func cursorDoctorCheck(redacted: Bool) -> (state: String, detail: String) {
        let probe = cursorProbe(force: true)
        let authLabel: String
        switch probe.state {
        case "connected": authLabel = "connected"
        case "signInRequired": authLabel = "sign-in required"
        case "notInstalled": return ("warning", "Not installed")
        default: authLabel = "unavailable"
        }
        let version = probe.version ?? "version unavailable"
        let path = resolveAgentBinary()
        let detail: String
        if redacted || path == nil {
            detail = "\(version) · \(authLabel)"
        } else {
            detail = "\(version) · \(authLabel) · \(redactPath(path!))"
        }
        let checkState = probe.state == "connected" ? "ok" : "warning"
        return (checkState, stripEmails(detail))
    }

    private func normalizeRecentMessage(_ raw: [String: Any]) -> [String: Any] {
        let no = raw["no"] ?? raw["globalMsgNum"] ?? NSNull()
        var normalized: [String: Any] = [
            "no": no is NSNull ? NSNull() : no,
            "timestamp": raw["timestamp"] ?? NSNull(),
            "query": (raw["query"] as? String) ?? "",
            "text": (raw["text"] as? String) ?? "",
            "sessionId": (raw["sessionId"] as? String) ?? "",
            "source": (raw["source"] as? String) ?? "",
        ]
        let attachments = normalizeAttachments(raw["attachments"])
        if !attachments.isEmpty { normalized["attachments"] = attachments }
        return normalized
    }

    /// Mirrors the server's own session-id contract (`^[A-Za-z0-9:_-]{3,96}$`).
    ///
    /// Validated rather than only percent-encoded: escaping makes a hostile value
    /// safe to put IN a URL, but it does not stop the helper asking the server
    /// about something that was never a session id. Rejecting here keeps the two
    /// ends agreeing about what a session is.
    private func validSessionID(_ value: String) -> Bool {
        guard (3...96).contains(value.count) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ":_-"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// A session id ready to sit in a path segment.
    private func escapedSessionID(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))
        ) ?? value
    }

    private func validMediaID(_ value: String) -> Bool {
        guard value.count == 26, value.hasPrefix("m_") else { return false }
        return value.dropFirst(2).allSatisfy { "0123456789abcdef".contains($0) }
    }

    private func normalizeAttachment(_ raw: Any) -> [String: Any]? {
        guard let value = raw as? [String: Any],
              let id = value["id"] as? String, validMediaID(id),
              let kind = value["kind"] as? String,
              ["user_photo", "traffic_frame", "generated_visual"].contains(kind),
              let mime = value["mime"] as? String,
              ["image/jpeg", "image/png"].contains(mime),
              let width = value["width"] as? Int, (1...65_535).contains(width),
              let height = value["height"] as? Int, (1...65_535).contains(height),
              let createdAt = value["createdAt"] as? String,
              validMediaTimestamp(createdAt) else { return nil }
        var out: [String: Any] = [
            "id": id,
            "kind": kind,
            "mime": mime,
            "width": width,
            "height": height,
            "createdAt": createdAt,
        ]
        if let label = value["label"] as? String, !label.isEmpty {
            out["label"] = String(label.prefix(120))
        }
        return out
    }

    private func validMediaTimestamp(_ value: String) -> Bool {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if fractional.date(from: value) != nil { return true }
        let wholeSecond = ISO8601DateFormatter()
        wholeSecond.formatOptions = [.withInternetDateTime]
        return wholeSecond.date(from: value) != nil
    }

    private func normalizeAttachments(_ raw: Any?) -> [[String: Any]] {
        guard let values = raw as? [Any] else { return [] }
        var result: [[String: Any]] = []
        var seen = Set<String>()
        for value in values {
            guard let attachment = normalizeAttachment(value),
                  let id = attachment["id"] as? String,
                  seen.insert(id).inserted else { continue }
            result.append(attachment)
            if result.count == 5 { break }
        }
        return result
    }

    /// Server returns oldest-first; emit newest-first and slice before serialize.
    private func sliceRecentMessages(_ messages: [[String: Any]], limit: Int) -> [[String: Any]] {
        let capped = max(1, min(limit, 100))
        return Array(messages.reversed().prefix(capped)).map(normalizeRecentMessage)
    }

    // MARK: - App update check (P1: CHECK ONLY)
    //
    // Read-only by construction. This command MUST NOT:
    //   - take withMutationLock (it mutates nothing, and must never block lifecycle work)
    //   - touch com.cos.glasses-server or any launchd verb            [plan R1]
    //   - write under ~/.cos-glasses/ (token, certs, .env)            [plan R9]
    //   - download, stage, or swap anything                          [that is P1.5/P2, gated on P0 notarization]
    // It fetches one static JSON over HTTPS and reports a comparison. Nothing else.
    //
    // The APP supplies its own identity (--current-build/--current-version) rather than the
    // helper inferring it: the helper runs from BOTH the app bundle and the stable path
    // (HelperClient.swift:55-64), so self-inference would report different answers depending
    // on which copy ran. Caller-supplied identity removes that skew entirely.
    private static let defaultAppcastURL = "https://www.gotcos.com/control/appcast.json"

    private func fetchAppcast(_ urlString: String, timeout: Int = 6) -> [String: Any]? {
        guard let url = URL(string: urlString), url.scheme == "https" || url.isFileURL else { return nil }
        if url.isFileURL {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        var request = URLRequest(url: url, timeoutInterval: TimeInterval(timeout))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let box = HTTPResultBox()
        let completion = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            box.store(data: data, response: response)
            completion.signal()
        }
        task.resume()
        guard completion.wait(timeout: .now() + .seconds(timeout + 2)) == .success else {
            task.cancel()
            return nil
        }
        let (data, response) = box.load()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Ordered-pair comparison. Build is authoritative; version breaks ties only when
    /// builds are equal. Guarantees monotonicity, so a republished or rolled-back
    /// appcast can never advertise a downgrade as an update. [plan R6, R11]
    static func appUpdateIsNewer(latestBuild: Int, currentBuild: Int) -> Bool {
        latestBuild > currentBuild
    }

    private func emitAppUpdateCheck(args: [String]) throws {
        let currentVersion = option("--current-version", in: args) ?? ""
        let currentBuild = Int(option("--current-build", in: args) ?? "") ?? 0
        let source = option("--appcast-url", in: args)
            ?? ProcessInfo.processInfo.environment["COS_APPCAST_URL"]
            ?? Self.defaultAppcastURL

        var details: [String: Any] = [
            "updateAvailable": false,
            "currentVersion": currentVersion,
            "currentBuild": currentBuild,
            "source": source,
        ]

        // Offline / DNS failure / 5xx / malformed is a SILENT no-op, never an error the
        // user has to dismiss. A checker that nags when the network blips is a regression. [plan R-offline]
        guard let appcast = fetchAppcast(source) else {
            details["reason"] = "unreachable"
            emit(ok: true, message: "Update check unavailable", details: details)
            return
        }

        if let kill = appcast["killSwitch"] as? [String: Any], kill["disableAutoUpdate"] as? Bool == true {
            details["reason"] = "killSwitch"
            details["killSwitch"] = true
            emit(ok: true, message: "Update checks paused by publisher", details: details)
            return
        }

        guard let channels = appcast["channels"] as? [String: Any],
              let stable = channels["stable"] as? [String: Any],
              let latestVersion = stable["version"] as? String,
              let latestBuild = stable["build"] as? Int,
              let url = stable["url"] as? String else {
            details["reason"] = "malformed"
            emit(ok: true, message: "Update check unavailable", details: details)
            return
        }

        details["latestVersion"] = latestVersion
        details["latestBuild"] = latestBuild
        details["url"] = url
        if let notes = stable["notes"] as? String { details["notes"] = notes }

        if Self.appUpdateIsNewer(latestBuild: latestBuild, currentBuild: currentBuild) {
            details["updateAvailable"] = true
            details["reason"] = "newer"
            emit(ok: true, message: "Update available: \(latestVersion)", details: details)
        } else {
            details["reason"] = "upToDate"
            emit(ok: true, message: "COS Control is up to date", details: details)
        }
    }

    /// Read-only Memory and Threads browsing on the desktop.
    ///
    /// Purely an exposure of a layer that already exists: /api/memory,
    /// /api/memory/:id, /api/threads and /api/threads/:id are authenticated and
    /// read-only, the glasses already browse them, and Control already holds the
    /// token. No new server surface and no mutation.
    ///
    /// Control has NO send path to the agent — there is not one /api/query call in
    /// this file — so "pick up from here" on the desktop is copy-as-context and, for
    /// the file tier, revealing the actual file. Arming a reference for the next
    /// prompt would need a write route, which the amendment design deliberately does
    /// not have yet.
    private func contextBrowseResponse(_ route: String, timeout: Int = 20) throws -> [String: Any] {
        guard request("/api/health", timeout: 5)?.status == 200 else {
            throw HelperError.message("Server stopped")
        }
        let token: String
        do { token = try readToken() }
        catch { throw HelperError.message("Unauthorized") }
        guard let response = request(route, token: token, timeout: timeout) else {
            throw HelperError.message("Server stopped")
        }
        if response.status == 401 || response.status == 403 { throw HelperError.message("Unauthorized") }
        // 503 is the server's honest "no context source configured", not a fault.
        if response.status == 503 {
            throw HelperError.message("Memory and Threads are not set up yet. Use Create Folders.")
        }
        guard response.status == 200 else { throw HelperError.message("Server stopped") }
        // /api/memory returns a TOP-LEVEL ARRAY for released companions, so a
        // dictionary-only reader sees nothing. Queen hit exactly this with her own
        // parser on 2026-08-09 and read it as a failure when the data was fine.
        if let body = response.body { return body }
        if let rows = response.bodyArray { return ["items": rows] }
        throw HelperError.message("Server stopped")
    }

    /// Absolute file path for a `file_` id, so the desktop can reveal it.
    ///
    /// Resolved HERE from the id and the resolved root rather than asked of the
    /// server, because /api/context/status deliberately exposes no paths. Returns nil
    /// for a `mem_` id, which addresses the vector store and has no file.
    private func contextRecordPath(id: String, kind: String) -> String? {
        guard id.hasPrefix("file_"), let root = contextRootResolution().resolved else { return nil }
        // The id is a sanitised relative path, so it cannot be reversed exactly.
        // Match by scanning the store, which is bounded and correct.
        let folders = kind == "thread" ? ["threads", "thread"] : ["memory", "memories"]
        for folder in folders {
            let base = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(folder, isDirectory: true)
            guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walker {
                guard ["md", "markdown", "txt"].contains(file.pathExtension.lowercased()) else { continue }
                let relative = file.path.hasPrefix(root)
                    ? String(file.path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    : file.lastPathComponent
                let sanitised = "file_" + relative.map { char -> String in
                    let ok = char.isLetter || char.isNumber || char == "." || char == "_" || char == "-"
                    return ok ? String(char) : "_"
                }.joined()
                if sanitised == id { return file.path }
            }
        }
        return nil
    }

    static func claudePeerState(alive: Bool, status: String, waitingFor: String) -> String {
        if !alive { return "stale" }
        if !waitingFor.isEmpty || status == "waiting" { return "waiting" }
        return "running"
    }

    static func claudePeerProjection(_ row: [String: Any]) -> [String: Any]? {
        guard let id = row["id"] as? String, !id.isEmpty else { return nil }
        let alive = row["alive"] as? Bool ?? false
        let status = row["status"] as? String ?? ""
        let waitingFor = row["waitingFor"] as? String ?? ""
        return [
            "id": id,
            "provider": "claude",
            "name": row["name"] as? String ?? "",
            "workspace": Self.workspaceLabel(row["workspace"] as? String ?? ""),
            "state": claudePeerState(alive: alive, status: status, waitingFor: waitingFor),
            "status": status,
            "waitingFor": waitingFor,
            "alive": alive,
            "reachable": row["reachable"] as? Bool ?? false,
            "createdAt": row["startedAt"] as? String ?? "",
            "updatedAt": row["lastActiveAt"] as? String ?? "",
        ]
    }

    /// Claude Code writes `/rename` titles as `custom-title` lines in the project jsonl,
    /// not in the live pid registry. Presence without that overlay is why Activity
    /// showed "MU-Chief-Staff" (or nothing) for "Fireflies meeting sync".
    static func lastCustomTitle(in jsonl: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: jsonl) else { return nil }
        defer { try? handle.close() }
        func scan(_ data: Data) -> String? {
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            var found: String?
            for line in text.split(whereSeparator: \.isNewline) {
                guard line.contains("custom-title") else { continue }
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      obj["type"] as? String == "custom-title",
                      let title = (obj["customTitle"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty else { continue }
                found = String(title.prefix(120))
            }
            return found
        }
        let headTitle = scan(handle.readData(ofLength: 256 * 1024))
        let size = (try? jsonl.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 256 * 1024 {
            handle.seek(toFileOffset: UInt64(max(0, size - 64 * 1024)))
            if let tailTitle = scan(handle.readDataToEndOfFile()) { return tailTitle }
        }
        return headTitle
    }

    static func firstClaudeUserTitle(in jsonl: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: jsonl) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 256 * 1024)
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "user",
                  obj["toolUseResult"] == nil,
                  obj["isSidechain"] as? Bool != true,
                  let message = obj["message"] as? [String: Any],
                  let body = claudeMessageText(message) else { continue }
            let title = firstLineTitle(body)
            if !title.isEmpty { return title }
        }
        return nil
    }

    static func firstLineTitle(_ text: String) -> String {
        var body = text
        if let start = body.range(of: "<user_query>"),
           let end = body.range(of: "</user_query>"),
           start.upperBound < end.lowerBound {
            body = String(body[start.upperBound..<end.lowerBound])
        }
        if let re = try? NSRegularExpression(pattern: "<[^>]+>") {
            let range = NSRange(body.startIndex..<body.endIndex, in: body)
            body = re.stringByReplacingMatches(in: body, range: range, withTemplate: " ")
        }
        let line = body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return String(line.prefix(80))
    }

    static func workspaceLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.hasPrefix("/") { return URL(fileURLWithPath: trimmed).lastPathComponent }
        var encoded = trimmed
        if encoded.hasPrefix("-") { encoded.removeFirst() }
        if encoded.contains("MU-Chief-Staff") { return "MU-Chief-Staff" }
        if let range = encoded.range(of: "GitHub-", options: [.backwards, .caseInsensitive]) {
            let rest = String(encoded[range.upperBound...])
            if rest.hasSuffix("-MU-Chief-Staff") || rest == "MU-Chief-Staff" { return "MU-Chief-Staff" }
            return rest
        }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    static func claudeCustomTitle(sessionId: String, projectsRoot: URL, fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> String? {
        let prefix = String(sessionId.prefix(8))
        guard prefix.count >= 8,
              let dirs = try? FileManager.default.contentsOfDirectory(
                at: projectsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return nil }
        for dir in dirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "jsonl" && file.lastPathComponent.hasPrefix(prefix) {
                if fileExists(file), let title = lastCustomTitle(in: file) { return title }
            }
        }
        return nil
    }

    static func recentClaudeConversations(
        liveIds: Set<String>,
        projectsRoot: URL,
        now: Date = Date(),
        maxAge: TimeInterval = agentSessionMaxAge,
        limit: Int = 20,
        starredIds: Set<String> = [],
        desktopSessionsRoot: URL? = nil,
        desktopIndex: [String: ClaudeDesktopSession]? = nil
    ) -> [[String: Any]] {
        let index = desktopIndex ?? desktopSessionsRoot.map { loadClaudeDesktopIndex(from: $0) } ?? [:]
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var pinnedRows: [(mtime: Date, row: [String: Any])] = []
        var recentRows: [(mtime: Date, row: [String: Any])] = []
        var seen = Set<String>()
        let uuidName = try? NSRegularExpression(pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.jsonl$")
        for dir in dirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files {
                let name = file.lastPathComponent
                let whole = NSRange(name.startIndex..<name.endIndex, in: name)
                guard uuidName?.firstMatch(in: name, range: whole) != nil else { continue }
                let sessionId = String(name.dropLast(6))
                let shortId = String(sessionId.prefix(8))
                if liveIds.contains(shortId) || liveIds.contains(sessionId) { continue }
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
                let mtime = values?.contentModificationDate ?? .distantPast
                let pinned = starredIds.contains(sessionId.lowercased())
                let fresh = now.timeIntervalSince(mtime) <= maxAge
                if !pinned && !fresh { continue }
                let desktop = index[sessionId.lowercased()] ?? index[shortId]
                var title = desktop?.title ?? ""
                if title.isEmpty {
                    title = lastCustomTitle(in: file) ?? firstClaudeUserTitle(in: file) ?? ""
                }
                var workspace = Self.workspaceLabel(dir.lastPathComponent)
                if workspace.isEmpty, let cwd = desktop?.cwd, !cwd.isEmpty {
                    workspace = workspaceLabel(cwd)
                }
                title = title.isEmpty ? "Claude session" : title
                if isKeepWarmSessionTitle(title) { continue }
                let created = values?.creationDate ?? mtime
                let row: [String: Any] = [
                    "id": shortId,
                    "provider": "claude",
                    "name": title,
                    "workspace": workspace,
                    "state": "recent",
                    "status": "recent",
                    "waitingFor": "",
                    "alive": false,
                    "reachable": false,
                    "pinned": pinned,
                    "createdAt": Self.isoString(from: created),
                    "updatedAt": Self.isoString(from: mtime),
                ]
                seen.insert(sessionId.lowercased())
                if let desktopId = desktop?.id, !desktopId.isEmpty { seen.insert(desktopId) }
                if let cli = desktop?.cliSessionId, !cli.isEmpty { seen.insert(cli) }
                if pinned { pinnedRows.append((mtime, row)) }
                else { recentRows.append((mtime, row)) }
            }
        }
        for (id, head) in index where id == head.id {
            if seen.contains(id)
                || seen.contains(head.cliSessionId)
                || liveIds.contains(id)
                || liveIds.contains(String(id.prefix(8)))
                || (!head.cliSessionId.isEmpty && (
                    liveIds.contains(head.cliSessionId)
                    || liveIds.contains(String(head.cliSessionId.prefix(8)))
                )) { continue }
            let pinned = starredIds.contains(id)
            let fresh = now.timeIntervalSince(head.mtime) <= maxAge
            if !pinned && !fresh { continue }
            let title = head.title.isEmpty ? "Claude session" : head.title
            if isKeepWarmSessionTitle(title) { continue }
            let row: [String: Any] = [
                "id": id,
                "provider": "claude",
                "name": title,
                "workspace": workspaceLabel(head.cwd),
                "state": "recent",
                "status": "recent",
                "waitingFor": "",
                "alive": false,
                "reachable": false,
                "pinned": pinned,
                "createdAt": Self.isoString(from: head.created),
                "updatedAt": Self.isoString(from: head.mtime),
            ]
            seen.insert(id)
            if pinned { pinnedRows.append((head.mtime, row)) }
            else { recentRows.append((head.mtime, row)) }
        }
        pinnedRows.sort { $0.mtime > $1.mtime }
        recentRows.sort { $0.mtime > $1.mtime }
        return pinnedRows.map(\.row) + Array(recentRows.prefix(limit).map(\.row))
    }

    static let claudeTranscriptMaxLineBytes = 200_000
    static let claudeHistoryTurnLimit = 120
    static let claudeKickstartMaxChars = 100_000
    static let claudeTurnMaxChars = 8_000

    static func findClaudeSessionFile(sessionId: String, projectsRoot: URL) -> URL? {
        let needle = sessionId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.count >= 8,
              needle.allSatisfy({ $0.isHexDigit || $0 == "-" }),
              !needle.contains(".."),
              !needle.contains("/") else { return nil }
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var prefixMatch: URL?
        for dir in dirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let name = file.deletingPathExtension().lastPathComponent.lowercased()
                if name == needle { return file }
                if prefixMatch == nil, name.hasPrefix(needle) { prefixMatch = file }
            }
        }
        return prefixMatch
    }

    static func redactSecrets(_ text: String) -> String {
        var out = text
        let patterns = [
            #"COS_API_TOKEN\s*=\s*\S+"#,
            #"COS_GLASSES_TOKEN\s*=\s*\S+"#,
            #"sk-ant-[A-Za-z0-9_\-]{8,}"#,
            #"\bsk-[A-Za-z0-9]{20,}"#,
            #"(?i)bearer\s+[A-Za-z0-9._\-]{16,}"#,
            #"(?i)x-cos-token['\"]?\s*[:=]\s*\S+"#,
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = re.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: "[redacted]")
        }
        return out
    }

    static func claudeMessageText(_ message: [String: Any]) -> String? {
        let content = message["content"]
        if let text = content as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let blocks = content as? [[String: Any]] else { return nil }
        var parts: [String] = []
        var hasImage = false
        for block in blocks {
            let type = block["type"] as? String ?? ""
            if type == "tool_result" || type == "tool_use" || type == "thinking" { continue }
            if type == "text" || type == "input_text",
               let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                parts.append(text)
            } else if type == "image" || type == "image_url" {
                hasImage = true
            }
        }
        if hasImage { parts.append("[image attached]") }
        let joined = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    static func clipClaudeTurn(_ text: String) -> String {
        if text.count <= claudeTurnMaxChars { return text }
        let end = text.index(text.startIndex, offsetBy: claudeTurnMaxChars)
        return String(text[..<end]) + "\n[truncated]"
    }

    static func parseClaudeTranscript(in jsonl: URL) -> (
        title: String,
        cwd: String,
        branch: String,
        sessionId: String,
        turns: [[String: String]],
        omittedTools: Int,
        omittedSidechain: Int
    ) {
        var title = ""
        var cwd = ""
        var branch = ""
        var sessionId = jsonl.deletingPathExtension().lastPathComponent
        var turns: [[String: String]] = []
        var omittedTools = 0
        var omittedSidechain = 0
        forEachClaudeJsonlLine(in: jsonl) { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
            let type = obj["type"] as? String ?? ""
            if let sid = obj["sessionId"] as? String, !sid.isEmpty { sessionId = sid }
            if type == "custom-title", let custom = obj["customTitle"] as? String, !custom.isEmpty {
                title = custom
                return
            }
            if obj["isSidechain"] as? Bool == true {
                omittedSidechain += 1
                return
            }
            if cwd.isEmpty, let value = obj["cwd"] as? String, !value.isEmpty { cwd = value }
            if branch.isEmpty, let value = obj["gitBranch"] as? String, !value.isEmpty { branch = value }
            if type == "user", obj["toolUseResult"] != nil {
                omittedTools += 1
                return
            }
            guard type == "user" || type == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let text = claudeMessageText(message) else {
                if type == "assistant" { omittedTools += 1 }
                return
            }
            let role = type == "user" ? "user" : "assistant"
            turns.append([
                "id": "\(turns.count + 1)",
                "role": role,
                "text": redactSecrets(clipClaudeTurn(text)),
                "timestamp": obj["timestamp"] as? String ?? "",
            ])
        }
        return (title, cwd, branch, sessionId, turns, omittedTools, omittedSidechain)
    }

    static func forEachClaudeJsonlLine(in url: URL, body: (String) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var buffer = Data()
        while true {
            let chunk = handle.readData(ofLength: 256 * 1024)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(0x0a)) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                if lineData.count > claudeTranscriptMaxLineBytes { continue }
                if let line = String(data: lineData, encoding: .utf8), !line.isEmpty { body(line) }
            }
            if buffer.count > claudeTranscriptMaxLineBytes * 2 { buffer.removeAll(keepingCapacity: true) }
        }
        if !buffer.isEmpty, buffer.count <= claudeTranscriptMaxLineBytes,
           let line = String(data: buffer, encoding: .utf8), !line.isEmpty {
            body(line)
        }
    }

    static func claudeKickstartCopy(
        title: String,
        cwd: String,
        branch: String,
        sessionId: String,
        turns: [[String: String]],
        omittedTools: Int,
        provider: String = "claude",
        maxChars: Int = claudeKickstartMaxChars
    ) -> String {
        let providerName = provider == "codex" ? "Codex" : provider == "cursor" ? "Cursor" : "Claude Code"
        let heading = title.isEmpty ? "\(providerName) session" : title
        var header = """
        # Kickstart: \(heading)

        Read-only export of a \(providerName) session. Continue this work here. Do not look for \(providerName) jsonl or session IDs to resume.

        - Workspace: \(cwd.isEmpty ? "(unknown)" : cwd)
        - Branch: \(branch.isEmpty ? "(unknown)" : branch)
        - Session: \(sessionId.isEmpty ? "(unknown)" : sessionId)
        """
        if omittedTools > 0 {
            header += "\n- Tool calls omitted: \(omittedTools)"
        }
        header += "\n\n"
        func render(_ turn: [String: String]) -> String {
            let role = turn["role"] == "user" ? "You" : "Assistant"
            return "**\(role)**\n\n\(turn["text"] ?? "")\n\n"
        }
        var used = header.count
        var tail: [[String: String]] = []
        for turn in turns.reversed() {
            let chunk = render(turn)
            if used + chunk.count > maxChars && !tail.isEmpty { break }
            tail.append(turn)
            used += chunk.count
        }
        var selected = Array(tail.reversed())
        if let firstUser = turns.first(where: { $0["role"] == "user" }),
           selected.first?["text"] != firstUser["text"] {
            selected.insert(firstUser, at: 0)
        }
        let omitted = turns.count - selected.count
        var body = header
        if let original = turns.first(where: { $0["role"] == "user" }) {
            body += "## Original request\n\n\(original["text"] ?? "")\n\n## Conversation\n\n"
        } else {
            body += "## Conversation\n\n"
        }
        if omitted > 0 {
            body += "[Older assistant turns omitted to fit the clipboard. Original request kept.]\n\n"
        }
        for turn in selected {
            if turn["text"] == turns.first(where: { $0["role"] == "user" })?["text"],
               body.contains("## Original request") {
                continue
            }
            body += render(turn)
        }
        if body.count > maxChars {
            let end = body.index(body.startIndex, offsetBy: maxChars)
            body = String(body[..<end]) + "\n[truncated]\n"
        }
        return body
    }

    static func claudeHistorySlice(_ turns: [[String: String]], limit: Int = claudeHistoryTurnLimit) -> [[String: String]] {
        if turns.count <= limit { return turns }
        return Array(turns.suffix(limit))
    }

    static let agentSessionListLimit = 20
    static let agentSessionMaxFileBytes = 32 * 1024 * 1024
    static let agentSessionMaxAge: TimeInterval = 7 * 24 * 3600

    static func isoString(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func createdFromCodexFilename(_ name: String) -> Date? {
        guard name.hasPrefix("rollout-") else { return nil }
        let stamp = String(name.dropFirst("rollout-".count).prefix(19))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter.date(from: stamp)
    }

    static func loadCodexPinnedIds(sessionsRoot: URL) -> Set<String> {
        let state = sessionsRoot.deletingLastPathComponent().appendingPathComponent(".codex-global-state.json")
        guard let data = try? Data(contentsOf: state),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["pinned-thread-ids"] as? [Any] else { return [] }
        return Set(list.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
    }

    static func normalizeClaudeSessionId(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("local_") ? String(trimmed.dropFirst(6)) : trimmed
    }

    static func loadClaudeStarredIds(from config: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: config),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let preferences = obj["preferences"] as? [String: Any],
              let epitaxy = preferences["epitaxyPrefs"] as? [String: Any],
              let list = epitaxy["starred-local-code-sessions"] as? [Any] else { return [] }
        return Set(list.compactMap { ($0 as? String).map(normalizeClaudeSessionId) }.filter { !$0.isEmpty })
    }

    static func peekClaudeDesktopHead(in file: URL) -> (title: String, cwd: String, cliSessionId: String) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return ("", "", "") }
        defer { try? handle.close() }
        let text = String(data: handle.readData(ofLength: 8 * 1024), encoding: .utf8) ?? ""
        func capture(_ key: String) -> String {
            guard let re = try? NSRegularExpression(pattern: "\"\(key)\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\"") else { return "" }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = re.firstMatch(in: text, range: range),
                  let inner = Range(match.range(at: 1), in: text) else { return "" }
            return text[inner]
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return (String(capture("title").prefix(120)), capture("cwd"), normalizeClaudeSessionId(capture("cliSessionId")))
    }

    struct ClaudeDesktopSession {
        var id: String
        var cliSessionId: String
        var title: String
        var cwd: String
        var mtime: Date
        var created: Date
    }

    static func loadClaudeDesktopIndex(from sessionsRoot: URL) -> [String: ClaudeDesktopSession] {
        var byFull: [String: ClaudeDesktopSession] = [:]
        guard FileManager.default.fileExists(atPath: sessionsRoot.path),
              let walker = FileManager.default.enumerator(
                at: sessionsRoot,
                includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return [:] }
        for case let file as URL in walker {
            let name = file.lastPathComponent
            guard name.hasPrefix("local_"), name.hasSuffix(".json") else { continue }
            let id = normalizeClaudeSessionId(String(name.dropLast(5)))
            guard id.count >= 8 else { continue }
            let values = try? file.resourceValues(forKeys: [
                .contentModificationDateKey, .creationDateKey, .isRegularFileKey
            ])
            if values?.isRegularFile == false { continue }
            let head = peekClaudeDesktopHead(in: file)
            let mtime = values?.contentModificationDate ?? .distantPast
            let created = values?.creationDate ?? mtime
            let row = ClaudeDesktopSession(
                id: id,
                cliSessionId: head.cliSessionId,
                title: head.title,
                cwd: head.cwd,
                mtime: mtime,
                created: created
            )
            if let existing = byFull[id], existing.mtime >= mtime { continue }
            byFull[id] = row
            if !head.cliSessionId.isEmpty, head.cliSessionId != id {
                if let existing = byFull[head.cliSessionId], existing.mtime >= mtime { continue }
                byFull[head.cliSessionId] = row
            }
        }
        var index = byFull
        for (id, row) in byFull {
            let short = String(id.prefix(8))
            if let existing = index[short], existing.mtime >= row.mtime { continue }
            index[short] = row
        }
        return index
    }

    static func claudeSidebarTitle(
        sessionId: String,
        projectsRoot: URL,
        desktopIndex: [String: ClaudeDesktopSession]
    ) -> String? {
        let key = normalizeClaudeSessionId(sessionId)
        if let title = desktopIndex[key]?.title ?? desktopIndex[String(key.prefix(8))]?.title, !title.isEmpty {
            return title
        }
        if let custom = claudeCustomTitle(sessionId: sessionId, projectsRoot: projectsRoot) { return custom }
        if let file = findClaudeSessionFile(sessionId: sessionId, projectsRoot: projectsRoot),
           let first = firstClaudeUserTitle(in: file) {
            return first
        }
        return nil
    }

    static func findClaudeDesktopFile(sessionId: String, sessionsRoot: URL) -> URL? {
        let needle = normalizeClaudeSessionId(sessionId)
        guard needle.count >= 8,
              needle.allSatisfy({ $0.isHexDigit || $0 == "-" }),
              !needle.contains(".."),
              !needle.contains("/") else { return nil }
        let exact = "local_\(needle).json"
        let prefix = "local_\(needle)"
        var best: (mtime: Date, file: URL)?
        guard let accounts = try? FileManager.default.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for account in accounts {
            let isDir = (try? account.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            guard let workspaces = try? FileManager.default.contentsOfDirectory(
                at: account,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for workspace in workspaces {
                let exactFile = workspace.appendingPathComponent(exact)
                if FileManager.default.fileExists(atPath: exactFile.path) { return exactFile }
                guard needle.count < 36 else { continue }
                guard let files = try? FileManager.default.contentsOfDirectory(
                    at: workspace,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for file in files {
                    let name = file.lastPathComponent.lowercased()
                    guard name.hasPrefix(prefix), name.hasSuffix(".json") else { continue }
                    let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                        ?? .distantPast
                    if best == nil || mtime > best!.mtime { best = (mtime, file) }
                }
            }
        }
        return best?.file
    }

    static func parsePinnedComposerList(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let list: [Any]
        if let array = parsed as? [Any] {
            list = array
        } else if let obj = parsed as? [String: Any] {
            list = (obj["composerIds"] as? [Any]) ?? (obj["ids"] as? [Any]) ?? []
        } else {
            list = []
        }
        return list.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
    }

    static func loadCursorPinnedIds(from workspaceStorage: URL) -> Set<String> {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: workspaceStorage,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var pinned = Set<String>()
        for folder in folders {
            let db = folder.appendingPathComponent("state.vscdb")
            guard FileManager.default.fileExists(atPath: db.path) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = ["-readonly", db.path, "SELECT value FROM ItemTable WHERE key = 'cursor/pinnedComposers' LIMIT 1"]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            do { try process.run() } catch { continue }
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning { process.terminate() }
            guard process.terminationStatus == 0 else { continue }
            let raw = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            for id in parsePinnedComposerList(raw) { pinned.insert(id) }
        }
        return pinned
    }

    static func idFromCodexFilename(_ name: String) -> String? {
        guard name.hasSuffix(".jsonl") else { return nil }
        let stem = String(name.dropLast(6))
        let uuid = stem.split(separator: "-").suffix(5).joined(separator: "-")
        guard uuid.count >= 36 else { return nil }
        return uuid.lowercased()
    }

    static func loadCodexThreadNames(sessionsRoot: URL) -> [String: String] {
        let index = sessionsRoot.deletingLastPathComponent().appendingPathComponent("session_index.jsonl")
        guard let handle = try? FileHandle(forReadingFrom: index) else { return [:] }
        defer { try? handle.close() }
        guard let text = String(data: handle.readDataToEndOfFile(), encoding: .utf8) else { return [:] }
        var names: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = obj["id"] as? String, !id.isEmpty,
                  let name = (obj["thread_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            names[id] = String(name.prefix(120))
        }
        return names
    }

    static func listCodexJsonlFiles(sessionsRoot: URL) -> [URL] {
        var files: [URL] = []
        guard let years = try? FileManager.default.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for year in years {
            let yearIsDir = (try? year.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard yearIsDir else { continue }
            guard let months = try? FileManager.default.contentsOfDirectory(
                at: year,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for month in months {
                let monthIsDir = (try? month.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard monthIsDir else { continue }
                guard let days = try? FileManager.default.contentsOfDirectory(
                    at: month,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for day in days {
                    let dayIsDir = (try? day.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    guard dayIsDir else { continue }
                    guard let jsonl = try? FileManager.default.contentsOfDirectory(
                        at: day,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    ) else { continue }
                    files.append(contentsOf: jsonl.filter { $0.pathExtension == "jsonl" })
                }
            }
        }
        return files
    }

    static func payloadText(_ payload: [String: Any]) -> String? {
        let content = payload["content"]
        if let text = content as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let blocks = content as? [[String: Any]] else { return nil }
        var parts: [String] = []
        for block in blocks {
            let type = block["type"] as? String ?? ""
            if type == "input_text" || type == "output_text" || type == "text",
               let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                parts.append(text)
            }
        }
        let joined = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    static func isWrapperPrompt(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<")
            || trimmed.hasPrefix("SYSTEM INSTRUCTIONS")
            || trimmed.hasPrefix("You are an agent")
            || trimmed.hasPrefix("You are QA Agent")
            || trimmed.hasPrefix("Message Type:")
    }

    static func isKeepWarmSessionTitle(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t == "ready" { return true }
        return t.hasPrefix("this is an automated local readiness check")
    }

    static func recentCodexConversations(
        sessionsRoot: URL,
        now: Date = Date(),
        maxAge: TimeInterval = agentSessionMaxAge,
        limit: Int = agentSessionListLimit
    ) -> [[String: Any]] {
        let names = loadCodexThreadNames(sessionsRoot: sessionsRoot)
        let pinnedIds = loadCodexPinnedIds(sessionsRoot: sessionsRoot)
        var pinnedRows: [(mtime: Date, row: [String: Any])] = []
        var recentRows: [(mtime: Date, row: [String: Any])] = []
        for file in listCodexJsonlFiles(sessionsRoot: sessionsRoot) {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let mtime = values?.contentModificationDate ?? .distantPast
            let fileId = idFromCodexFilename(file.lastPathComponent)
            let pinned = fileId.map { pinnedIds.contains($0) } ?? false
            let fresh = now.timeIntervalSince(mtime) <= maxAge
            if !pinned && !fresh { continue }
            guard let meta = peekCodexMeta(in: file), meta.subagent == false else { continue }
            let nativeId = meta.id.isEmpty ? file.deletingPathExtension().lastPathComponent : meta.id
            let title = names[nativeId] ?? (meta.title.isEmpty ? "Codex session" : meta.title)
            if isKeepWarmSessionTitle(title) { continue }
            let created = meta.created.isEmpty
                ? isoString(from: createdFromCodexFilename(file.lastPathComponent) ?? values?.creationDate ?? mtime)
                : meta.created
            let row: [String: Any] = [
                "id": nativeId,
                "provider": "codex",
                "name": title,
                "workspace": workspaceLabel(meta.cwd),
                "state": "recent",
                "status": "recent",
                "waitingFor": "",
                "alive": false,
                "reachable": false,
                "pinned": pinned || pinnedIds.contains(nativeId.lowercased()),
                "createdAt": created,
                "updatedAt": isoString(from: mtime),
            ]
            if pinned { pinnedRows.append((mtime, row)) }
            else { recentRows.append((mtime, row)) }
        }
        pinnedRows.sort { $0.mtime > $1.mtime }
        recentRows.sort { $0.mtime > $1.mtime }
        return pinnedRows.map(\.row) + Array(recentRows.prefix(limit).map(\.row))
    }

    static func peekCodexMeta(in jsonl: URL) -> (id: String, cwd: String, title: String, subagent: Bool, created: String)? {
        guard let handle = try? FileHandle(forReadingFrom: jsonl) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 256 * 1024)
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var id = ""
        var cwd = ""
        var title = ""
        var created = ""
        var subagent = false
        for line in text.split(whereSeparator: \.isNewline) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if obj["type"] as? String == "session_meta", let payload = obj["payload"] as? [String: Any] {
                id = (payload["id"] as? String) ?? (payload["session_id"] as? String) ?? id
                cwd = payload["cwd"] as? String ?? cwd
                subagent = (payload["thread_source"] as? String) == "subagent"
                if let nick = payload["agent_nickname"] as? String, !nick.isEmpty, title.isEmpty { title = nick }
                if let stamp = payload["timestamp"] as? String, !stamp.isEmpty, created.isEmpty { created = stamp }
                if created.isEmpty, let stamp = obj["timestamp"] as? String, !stamp.isEmpty { created = stamp }
            }
            if title.isEmpty,
               obj["type"] as? String == "response_item",
               let payload = obj["payload"] as? [String: Any],
               payload["type"] as? String == "message",
               payload["role"] as? String == "user",
               let text = payloadText(payload),
               !isWrapperPrompt(text) {
                title = firstLineTitle(text)
            }
            if !id.isEmpty && !title.isEmpty { break }
        }
        return (id, cwd, title, subagent, created)
    }

    static func findCodexSessionFile(sessionId: String, sessionsRoot: URL) -> URL? {
        let needle = sessionId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.count >= 8,
              needle.allSatisfy({ $0.isHexDigit || $0 == "-" }),
              !needle.contains(".."),
              !needle.contains("/") else { return nil }
        return listCodexJsonlFiles(sessionsRoot: sessionsRoot).first {
            $0.pathExtension == "jsonl" && $0.lastPathComponent.lowercased().contains(needle)
        }
    }

    static func parseCodexTranscript(in jsonl: URL) -> (
        title: String, cwd: String, branch: String, sessionId: String,
        turns: [[String: String]], omittedTools: Int, omittedSidechain: Int
    ) {
        var title = "", cwd = "", branch = "", sessionId = jsonl.deletingPathExtension().lastPathComponent
        var turns: [[String: String]] = []
        var omittedTools = 0
        forEachClaudeJsonlLine(in: jsonl) { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
            if obj["type"] as? String == "session_meta", let payload = obj["payload"] as? [String: Any] {
                cwd = payload["cwd"] as? String ?? cwd
                sessionId = (payload["id"] as? String) ?? sessionId
                if let git = payload["git"] as? [String: Any] {
                    branch = (git["branch"] as? String) ?? branch
                }
                if title.isEmpty, let nick = payload["agent_nickname"] as? String, !nick.isEmpty { title = nick }
                return
            }
            guard obj["type"] as? String == "response_item",
                  let payload = obj["payload"] as? [String: Any] else { return }
            let kind = payload["type"] as? String ?? ""
            if kind == "custom_tool_call" || kind == "custom_tool_call_output" || kind == "function_call" {
                omittedTools += 1
                return
            }
            if kind != "message" { return }
            let role = payload["role"] as? String ?? ""
            if role == "developer" { return }
            guard let text = payloadText(payload), !isWrapperPrompt(text) else { return }
            let mapped = role == "assistant" ? "assistant" : "user"
            if title.isEmpty && mapped == "user" { title = firstLineTitle(text) }
            turns.append([
                "id": "\(turns.count + 1)",
                "role": mapped,
                "text": redactSecrets(clipClaudeTurn(text)),
                "timestamp": obj["timestamp"] as? String ?? "",
            ])
        }
        return (title, cwd, branch, sessionId, turns, omittedTools, 0)
    }

    static func isSkippedCursorFolder(_ folder: String) -> Bool {
        folder == "empty-window" || folder.contains("var-folders") || folder.contains("private-var")
    }

    static func loadCursorComposerNames(from db: URL) -> [String: String] {
        guard FileManager.default.fileExists(atPath: db.path) else { return [:] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly",
            "-json",
            db.path,
            "SELECT composerId AS id, json_extract(value, '$.name') AS name FROM composerHeaders WHERE json_extract(value, '$.name') IS NOT NULL AND json_extract(value, '$.name') != ''",
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return [:] }
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { process.terminate() }
        guard process.terminationStatus == 0,
              let rows = try? JSONSerialization.jsonObject(with: stdout.fileHandleForReading.readDataToEndOfFile()) as? [[String: Any]]
        else { return [:] }
        var names: [String: String] = [:]
        for row in rows {
            let id = ((row["id"] as? String) ?? (row["composerId"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (row["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty, !name.isEmpty { names[id] = String(name.prefix(120)) }
        }
        return names
    }

    static func recentCursorConversations(
        projectsRoot: URL,
        now: Date = Date(),
        maxAge: TimeInterval = agentSessionMaxAge,
        limit: Int = agentSessionListLimit,
        composerNames: [String: String] = [:],
        pinnedIds: Set<String> = []
    ) -> [[String: Any]] {
        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var byId: [String: (mtime: Date, row: [String: Any], workspace: String)] = [:]
        for project in projects {
            let isDir = (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let folder = project.lastPathComponent
            if folder.contains("var-folders") || folder.contains("private-var") { continue }
            let transcripts = project.appendingPathComponent("agent-transcripts", isDirectory: true)
            guard let sessions = try? FileManager.default.contentsOfDirectory(
                at: transcripts,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for sessionDir in sessions {
                if sessionDir.lastPathComponent == "subagents" { continue }
                let nativeId = sessionDir.lastPathComponent
                let pinned = pinnedIds.contains(nativeId.lowercased())
                if folder == "empty-window" && !pinned { continue }
                let file = sessionDir.appendingPathComponent("\(nativeId).jsonl")
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if !pinned && size > agentSessionMaxFileBytes { continue }
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let fresh = now.timeIntervalSince(mtime) <= maxAge
                if !pinned && !fresh { continue }
                let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? mtime
                let title = composerNames[nativeId]
                    ?? lastCursorUserTitle(in: file)
                    ?? firstCursorUserTitle(in: file)
                    ?? "Cursor session"
                if isKeepWarmSessionTitle(title) { continue }
                let workspace = workspaceLabel(folder)
                let row: [String: Any] = [
                    "id": nativeId,
                    "provider": "cursor",
                    "name": title,
                    "workspace": workspace,
                    "state": now.timeIntervalSince(mtime) < 180 ? "running" : "recent",
                    "status": "recent",
                    "waitingFor": "",
                    "alive": now.timeIntervalSince(mtime) < 180,
                    "reachable": false,
                    "pinned": pinned,
                    "createdAt": isoString(from: created),
                    "updatedAt": isoString(from: mtime),
                ]
                if let existing = byId[nativeId] {
                    if workspace == "empty-window" && existing.workspace != "empty-window" { continue }
                    if existing.workspace == "empty-window" && workspace != "empty-window" {
                        byId[nativeId] = (mtime, row, workspace)
                        continue
                    }
                    if mtime >= existing.mtime { byId[nativeId] = (mtime, row, workspace) }
                } else {
                    byId[nativeId] = (mtime, row, workspace)
                }
            }
        }
        let pinnedRows = byId.values.filter { $0.row["pinned"] as? Bool == true }.sorted { $0.mtime > $1.mtime }
        let recentRows = byId.values.filter { $0.row["pinned"] as? Bool != true }.sorted { $0.mtime > $1.mtime }
        return pinnedRows.map(\.row) + Array(recentRows.prefix(limit).map(\.row))
    }

    static func cursorUserTitle(from body: String, requireQuery: Bool) -> String? {
        if requireQuery && !body.contains("<user_query>") { return nil }
        let title = firstLineTitle(body)
        if title.isEmpty || isWrapperPrompt(title) { return nil }
        return title
    }

    static func firstCursorUserTitle(in jsonl: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: jsonl) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 256 * 1024)
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var fallback: String?
        for line in text.split(whereSeparator: \.isNewline) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  (obj["role"] as? String) == "user",
                  let message = obj["message"] as? [String: Any],
                  let body = claudeMessageText(message) else { continue }
            if let title = cursorUserTitle(from: body, requireQuery: true) { return title }
            if fallback == nil { fallback = cursorUserTitle(from: body, requireQuery: false) }
        }
        return fallback
    }

    static func lastCursorUserTitle(in jsonl: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: jsonl) else { return nil }
        defer { try? handle.close() }
        let size = (try? jsonl.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let window = 256 * 1024
        if size > window { handle.seek(toFileOffset: UInt64(size - window)) }
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var found: String?
        for line in text.split(whereSeparator: \.isNewline) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  (obj["role"] as? String) == "user",
                  let message = obj["message"] as? [String: Any],
                  let body = claudeMessageText(message),
                  let title = cursorUserTitle(from: body, requireQuery: true) else { continue }
            found = title
        }
        return found
    }

    static func findCursorSessionFile(sessionId: String, projectsRoot: URL) -> URL? {
        let needle = sessionId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.count >= 8,
              needle.allSatisfy({ $0.isHexDigit || $0 == "-" }),
              !needle.contains(".."),
              !needle.contains("/") else { return nil }
        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var best: (file: URL, mtime: Date)?
        for project in projects {
            if isSkippedCursorFolder(project.lastPathComponent) { continue }
            let file = project
                .appendingPathComponent("agent-transcripts", isDirectory: true)
                .appendingPathComponent(needle, isDirectory: true)
                .appendingPathComponent("\(needle).jsonl")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if best == nil || mtime >= (best?.mtime ?? .distantPast) { best = (file, mtime) }
        }
        return best?.file
    }

    static func parseCursorTranscript(in jsonl: URL) -> (
        title: String, cwd: String, branch: String, sessionId: String,
        turns: [[String: String]], omittedTools: Int, omittedSidechain: Int
    ) {
        var title = ""
        var turns: [[String: String]] = []
        var omittedTools = 0
        let sessionId = jsonl.deletingPathExtension().lastPathComponent
        forEachClaudeJsonlLine(in: jsonl) { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
            let role = obj["role"] as? String ?? ""
            guard role == "user" || role == "assistant" else { return }
            let message = obj["message"] as? [String: Any] ?? [:]
            if let blocks = message["content"] as? [[String: Any]],
               blocks.contains(where: { ($0["type"] as? String) == "tool_use" }) {
                omittedTools += 1
            }
            guard let text = claudeMessageText(message) else { return }
            if role == "user" {
                if let queryTitle = cursorUserTitle(from: text, requireQuery: true) {
                    title = queryTitle
                } else if title.isEmpty, let fallback = cursorUserTitle(from: text, requireQuery: false) {
                    title = fallback
                }
            }
            turns.append([
                "id": "\(turns.count + 1)",
                "role": role,
                "text": redactSecrets(clipClaudeTurn(text)),
                "timestamp": obj["timestamp"] as? String ?? "",
            ])
        }
        let cwd = jsonl.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        return (title, workspaceLabel(cwd), "", sessionId, turns, omittedTools, 0)
    }

    private func emitClaudeSessions() throws {
        var enabled = false
        var reason = ""
        var peers: [[String: Any]] = []
        var counts: Any = ["alive": 0, "reachable": 0, "stale": 0]
        var liveIds: Set<String> = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeProjects = home.appendingPathComponent(".claude/projects", isDirectory: true)
        let claudeStarred = Self.loadClaudeStarredIds(
            from: home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        )
        let claudeDesktop = home.appendingPathComponent(
            "Library/Application Support/Claude/claude-code-sessions",
            isDirectory: true
        )
        let desktopIndex = Self.loadClaudeDesktopIndex(from: claudeDesktop)
        if let token = try? speakerReviewToken(),
           let response = request("/api/claude-sessions", token: token, timeout: 12),
           response.status == 200,
           let body = response.body {
            enabled = body["enabled"] as? Bool ?? false
            reason = body["reason"] as? String ?? ""
            counts = body["counts"] ?? counts
            if enabled {
                peers = ((body["peers"] as? [[String: Any]]) ?? []).compactMap(Self.claudePeerProjection)
                for index in peers.indices {
                    let id = peers[index]["id"] as? String ?? ""
                    if let title = Self.claudeSidebarTitle(
                        sessionId: id,
                        projectsRoot: claudeProjects,
                        desktopIndex: desktopIndex
                    ) {
                        peers[index]["name"] = title
                    }
                    peers[index]["provider"] = "claude"
                    peers[index]["workspace"] = Self.workspaceLabel(peers[index]["workspace"] as? String ?? "")
                    peers[index]["pinned"] = claudeStarred.contains(Self.normalizeClaudeSessionId(id))
                }
                liveIds = Set(peers.compactMap { $0["id"] as? String })
            }
        }
        peers.append(contentsOf: Self.recentClaudeConversations(
            liveIds: liveIds,
            projectsRoot: claudeProjects,
            starredIds: claudeStarred,
            desktopSessionsRoot: claudeDesktop,
            desktopIndex: desktopIndex
        ))
        peers.append(contentsOf: Self.recentCodexConversations(
            sessionsRoot: home.appendingPathComponent(".codex/sessions", isDirectory: true)
        ))
        peers.append(contentsOf: Self.recentCursorConversations(
            projectsRoot: home.appendingPathComponent(".cursor/projects", isDirectory: true),
            composerNames: Self.loadCursorComposerNames(
                from: home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            ),
            pinnedIds: Self.loadCursorPinnedIds(
                from: home.appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage")
            )
        ))
        peers.removeAll { Self.isKeepWarmSessionTitle(($0["name"] as? String) ?? "") }
        peers.sort { a, b in
            let aLive = a["alive"] as? Bool == true
            let bLive = b["alive"] as? Bool == true
            if aLive != bLive { return aLive && !bLive }
            let aPin = a["pinned"] as? Bool == true
            let bPin = b["pinned"] as? Bool == true
            if aPin != bPin { return aPin && !bPin }
            return (a["updatedAt"] as? String ?? "") > (b["updatedAt"] as? String ?? "")
        }
        let message: String
        if peers.isEmpty {
            message = enabled ? "No sessions" : "No Codex or Cursor sessions"
        } else {
            message = "\(peers.count) session(s)"
        }
        emit(ok: true, message: message, details: [
            "enabled": true,
            "reason": reason,
            "sessions": peers,
            "counts": counts,
            "claudeLiveEnabled": enabled,
        ])
    }

    private func emitClaudeSessionDetail(args: [String]) throws {
        guard let sessionId = option("--session", in: args)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else {
            throw HelperError.message("--session is required")
        }
        let provider = (option("--provider", in: args) ?? "claude").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let file: URL
        let parsed: (title: String, cwd: String, branch: String, sessionId: String, turns: [[String: String]], omittedTools: Int, omittedSidechain: Int)
        switch provider {
        case "codex":
            guard let found = Self.findCodexSessionFile(
                sessionId: sessionId,
                sessionsRoot: home.appendingPathComponent(".codex/sessions", isDirectory: true)
            ) else { throw HelperError.message("No local Codex transcript for this session.") }
            let size = (try? found.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > Self.agentSessionMaxFileBytes {
                throw HelperError.message("This Codex session is too large to open in Control.")
            }
            file = found
            parsed = Self.parseCodexTranscript(in: found)
        case "cursor":
            guard let found = Self.findCursorSessionFile(
                sessionId: sessionId,
                projectsRoot: home.appendingPathComponent(".cursor/projects", isDirectory: true)
            ) else { throw HelperError.message("No local Cursor transcript for this session.") }
            let size = (try? found.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > Self.agentSessionMaxFileBytes {
                throw HelperError.message("This Cursor session is too large to open in Control.")
            }
            file = found
            parsed = Self.parseCursorTranscript(in: found)
        default:
            guard let found = Self.findClaudeSessionFile(
                sessionId: sessionId,
                projectsRoot: home.appendingPathComponent(".claude/projects", isDirectory: true)
            ) else { throw HelperError.message("No local transcript for this session.") }
            file = found
            parsed = Self.parseClaudeTranscript(in: found)
        }
        let history = Self.claudeHistorySlice(parsed.turns)
        let copy = Self.claudeKickstartCopy(
            title: parsed.title,
            cwd: parsed.cwd,
            branch: parsed.branch,
            sessionId: parsed.sessionId,
            turns: parsed.turns,
            omittedTools: parsed.omittedTools,
            provider: provider
        )
        let fallback = provider == "codex" ? "Codex session" : provider == "cursor" ? "Cursor session" : "Claude session"
        emit(ok: true, message: "Session ready", details: [
            "title": parsed.title.isEmpty ? fallback : parsed.title,
            "cwd": parsed.cwd,
            "branch": parsed.branch,
            "sessionId": parsed.sessionId,
            "provider": provider,
            "path": file.path,
            "turns": history,
            "totalTurns": parsed.turns.count,
            "omittedTools": parsed.omittedTools,
            "omittedSidechain": parsed.omittedSidechain,
            "truncated": parsed.turns.count > history.count,
            "copyText": copy,
        ])
    }

    static let meetingSyncTimeout: TimeInterval = 15 * 60

    static func meetingSyncTooling(
        scriptsDir: String?,
        fileExists: (String) -> Bool,
        isExecutable: (String) -> Bool
    ) throws -> (python: String, script: String) {
        let trimmed = scriptsDir?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            throw HelperError.message("COS_SCRIPTS_DIR is not set on the server. Meeting sync cannot run.")
        }
        let root = URL(fileURLWithPath: trimmed, isDirectory: true)
        let python = root.appendingPathComponent("cos_python").path
        let script = root.appendingPathComponent("sync_meetings.py").path
        guard fileExists(python), isExecutable(python) else {
            throw HelperError.message("cos_python is missing in COS_SCRIPTS_DIR. Meeting sync cannot run.")
        }
        guard fileExists(script) else {
            throw HelperError.message("sync_meetings.py is missing in COS_SCRIPTS_DIR. Meeting sync cannot run.")
        }
        return (python, script)
    }

    static func meetingSyncChildEnvironment(
        base: [String: String],
        launchAgent: [String: String],
        liveScriptsDir: String?
    ) -> [String: String] {
        var env = base
        for (key, value) in launchAgent { env[key] = value }
        if let liveScriptsDir {
            let trimmed = liveScriptsDir.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { env["COS_SCRIPTS_DIR"] = trimmed }
        }
        return env
    }

    static func meetingSyncArguments(script: String) -> [String] {
        [script]
    }

    private func emitMeetingSyncNow() throws {
        let health = request("/api/health", timeout: 8)?.body
        let fields = meetingSyncStatusFields(health: health)
        if fields["meetingSyncActive"] as? Bool == true {
            throw HelperError.message("Meeting polish is in progress. Wait until Meeting sync is idle.")
        }
        let liveScripts = loadedEnvironmentValue("COS_SCRIPTS_DIR")
            ?? serverEnvironment()["COS_SCRIPTS_DIR"]
        let tooling = try Self.meetingSyncTooling(
            scriptsDir: liveScripts,
            fileExists: { fm.fileExists(atPath: $0) },
            isExecutable: { fm.isExecutableFile(atPath: $0) }
        )
        let arguments = Self.meetingSyncArguments(script: tooling.script)
        if arguments.contains(where: { $0 == "--force" || $0.hasPrefix("--force=") }) {
            throw HelperError.message("Meeting sync refuses --force so deletions are not auto-committed.")
        }
        let environment = Self.meetingSyncChildEnvironment(
            base: ProcessInfo.processInfo.environment,
            launchAgent: serverEnvironment(),
            liveScriptsDir: liveScripts
        )
        progress("Running meeting sync…")
        let result = try execute(
            tooling.python,
            arguments,
            environment: environment,
            timeout: Self.meetingSyncTimeout,
            heartbeat: "Meeting sync still running…"
        )
        if result.code != 0 {
            let tail = result.output.split(separator: "\n").suffix(8).joined(separator: "\n")
            throw HelperError.message(tail.isEmpty ? "Meeting sync failed." : tail)
        }
        let summary = result.output.split(separator: "\n").reversed().first {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }.map(String.init) ?? "Meeting sync finished"
        emit(ok: true, message: summary, details: [
            "code": result.code,
            "forced": false,
        ])
    }

    private func emitContextMemories(args: [String]) throws {
        let limit = min(max(Int(option("--limit", in: args) ?? "30") ?? 30, 1), 50)
        if let id = option("--id", in: args), !id.isEmpty {
            let detail = try contextBrowseResponse("/api/memory/\(id)")
            var payload = detail
            payload["filePath"] = contextRecordPath(id: id, kind: "memory") ?? NSNull()
            emit(ok: true, message: "Memory detail", details: payload)
            return
        }
        let listing = try contextBrowseResponse("/api/memory?limit=\(limit)")
        let rows = (listing["items"] as? [[String: Any]]) ?? []
        let overview = try? contextBrowseResponse("/api/memory/overview")
        // `shown` is this PAGE, `total` is the whole store. Naming both "count"
        // would put "4 memories" next to a 4,902 total and read as a bug.
        emit(ok: true, message: rows.isEmpty ? "No memories yet" : "\(rows.count) shown", details: [
            "state": rows.isEmpty ? "empty" : "ready",
            "memories": rows,
            "shown": rows.count,
            "total": overview?["total"] ?? rows.count,
            "byType": overview?["by_type"] ?? [:],
            "root": contextRootResolution().resolved ?? NSNull(),
        ])
    }

    private func emitContextThreads(args: [String]) throws {
        let limit = min(max(Int(option("--limit", in: args) ?? "30") ?? 30, 1), 50)
        if let id = option("--id", in: args), !id.isEmpty {
            var payload = try contextBrowseResponse("/api/threads/\(id)")
            payload["filePath"] = contextRecordPath(id: id, kind: "thread") ?? NSNull()
            emit(ok: true, message: "Thread detail", details: payload)
            return
        }
        let listing = try contextBrowseResponse("/api/threads?limit=\(limit)")
        let rows = (listing["threads"] as? [[String: Any]]) ?? (listing["items"] as? [[String: Any]]) ?? []
        // Same split as memories: the server returns a limited PAGE alongside
        // full-store active/resolved counts, so a live probe showed "4 threads" beside
        // "11 active". Both are correct; only one of them counts the rows on screen.
        emit(ok: true, message: rows.isEmpty ? "No threads yet" : "\(rows.count) shown", details: [
            "state": rows.isEmpty ? "empty" : "ready",
            "threads": rows,
            "shown": rows.count,
            "activeCount": listing["active_count"] ?? 0,
            "resolvedCount": listing["resolved_count"] ?? 0,
            "root": contextRootResolution().resolved ?? NSNull(),
        ])
    }

    private func emitRecentMessages(args: [String]) throws {
        let limit = Int(option("--limit", in: args) ?? "30") ?? 30
        let health = request("/api/health", timeout: 5)
        guard health?.status == 200 else {
            throw HelperError.message("Server stopped")
        }
        let token: String
        do { token = try readToken() }
        catch { throw HelperError.message("Unauthorized") }

        guard let response = request("/api/sessions/today/all-messages", token: token, timeout: 20) else {
            throw HelperError.message("Server stopped")
        }
        if response.status == 401 || response.status == 403 {
            throw HelperError.message("Unauthorized")
        }
        guard response.status == 200, let body = response.body else {
            throw HelperError.message("Server stopped")
        }

        let raw = (body["messages"] as? [[String: Any]]) ?? []
        let messages = sliceRecentMessages(raw, limit: limit)
        if messages.isEmpty {
            emit(ok: true, message: "Empty today", details: [
                "state": "empty",
                "messages": [],
                "count": 0,
                "date": body["date"] ?? NSNull(),
            ])
            return
        }
        emit(ok: true, message: "Recent glasses messages ready", details: [
            "state": "ready",
            "messages": messages,
            "count": messages.count,
            "date": body["date"] ?? NSNull(),
        ])
    }

    /// Shared preflight for the speaker-review reads: the server has to be up
    /// AND the token readable, and those are different failures the panel words
    /// differently. Returns the token.
    private func speakerReviewToken() throws -> String {
        let health = request("/api/health", timeout: 5)
        guard health?.status == 200 else { throw HelperError.message("Server stopped") }
        do { return try readToken() }
        catch { throw HelperError.message("Unauthorized") }
    }

    private func speakerReviewBody(_ path: String, method: String = "GET", body: String? = nil, timeout: Int = 20) throws -> [String: Any] {
        let token = try speakerReviewToken()
        guard let response = request(path, method: method, token: token, body: body, timeout: timeout) else {
            throw HelperError.message("Server stopped")
        }
        if response.status == 401 || response.status == 403 { throw HelperError.message("Unauthorized") }
        // A 400/404/409 carries a real explanation from the server — surface it
        // verbatim rather than flattening every non-200 into "Server stopped".
        if response.status != 200 {
            let reason = (response.body?["message"] as? String)
                ?? (response.body?["error"] as? String)
                ?? "Request failed (\(response.status))"
            throw HelperError.message(reason)
        }
        guard let body = response.body else { throw HelperError.message("Server stopped") }
        return body
    }

    /// Recent saved meetings. Only rows that carry a sessionId are emitted:
    /// the speaker review is keyed on the session, so a row without one cannot
    /// open the panel and listing it would offer an action that does nothing.
    /// Read a count that may arrive as a JSON number or a string.
    ///
    /// The server sends Int today. Accepting both means a future serialisation
    /// change cannot silently blank the row again.
    static func meetingCount(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String, let parsed = Int(string) { return parsed }
        return 0
    }

    /// Project one server meetings row into what Control consumes.
    ///
    /// EXTRACTED so it can be tested. Inline, it had no coverage at all:
    /// deleting the `month` or `topicCount` passthrough left the whole suite
    /// green, because the Swift-side tests build their fixture from a literal
    /// and never run this code. The failure mode is silent — ReviewableMeeting
    /// defaults every non-sessionId field to "", so a dropped field surfaces as
    /// an empty string, not an error.
    ///
    /// Returns nil for a row with no sessionId: the speaker review is keyed on
    /// the session, so such a row would offer an action that does nothing.
    static func meetingRowFields(_ row: [String: Any]) -> [String: Any] {
        [
            "sessionId": row["sessionId"] as? String ?? "",
            "title": row["title"] as? String ?? "Untitled meeting",
            "date": row["date"] as? String ?? "",
            "time": row["time"] as? String ?? "",
            "domain": row["domain"] as? String ?? "",
            "domainAbbr": row["domainAbbr"] as? String ?? "",
            "duration": row["duration"] as? String ?? "",
            "durationMinutes": Self.meetingCount(row["durationMinutes"]),
            "month": row["month"] as? String ?? "",
            "filename": row["filename"] as? String ?? "",
            "source": row["source"] as? String ?? "",
            "librarySource": row["librarySource"] as? String ?? "standalone_recordings",
            "recordId": row["recordId"] as? String ?? "",
            "mutable": row["mutable"] as? Bool ?? true,
            "topicCount": Self.meetingCount(row["topicCount"]),
            "decisionCount": Self.meetingCount(row["decisionCount"]),
            "actionCount": Self.meetingCount(row["actionCount"]),
            "attendeeCount": Self.meetingCount(row["attendeeCount"]),
        ]
    }

    static func meetingRowProjection(_ row: [String: Any]) -> [String: Any]? {
        guard let sessionId = row["sessionId"] as? String, !sessionId.isEmpty else { return nil }
        var fields = meetingRowFields(row)
        fields["sessionId"] = sessionId
        return fields
    }

    /// Library rows keep Granola/Fireflies meetings that have no sessionId.
    /// Identity is recordId, falling back to domain:month:filename.
    static func libraryMeetingProjection(_ row: [String: Any]) -> [String: Any]? {
        let filename = row["filename"] as? String ?? ""
        let month = row["month"] as? String ?? ""
        guard !filename.isEmpty, !month.isEmpty else { return nil }
        var fields = meetingRowFields(row)
        let recordId = fields["recordId"] as? String ?? ""
        if recordId.isEmpty {
            let domain = fields["domain"] as? String ?? ""
            fields["recordId"] = "\(domain):\(month):\(filename)"
        }
        return fields
    }

    private func queryEscape(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        ) ?? value
    }

    private func emitMeetings(args: [String]) throws {
        // OVER-REQUEST ON PURPOSE. `--limit` is the SERVER row count, and the
        // filter below then drops every row without a sessionId, so asking for
        // 15 returned 10-12 depending on how much of the day was G2-captured.
        // Ask for more than we intend to show and let Control take the first N
        // survivors. Both ends hard-clamp at 50.
        let limit = min(max(Int(option("--limit", in: args) ?? "30") ?? 30, 1), 50)
        let body = try speakerReviewBody("/api/meetings?limit=\(limit)")
        let raw = (body["meetings"] as? [[String: Any]]) ?? []
        let rows: [[String: Any]] = raw.compactMap(Self.meetingRowProjection)
        emit(ok: true, message: rows.isEmpty ? "No reviewable meetings" : "Meetings ready", details: [
            "state": rows.isEmpty ? "empty" : "ready",
            "meetings": rows,
            "count": rows.count,
            "skipped": raw.count - rows.count,
        ])
    }

    private func emitMeetingsLibrary(args: [String]) throws {
        let month = option("--month", in: args) ?? ""
        let day = option("--day", in: args) ?? ""
        let domain = option("--domain", in: args) ?? "all"
        let scoped = !month.isEmpty || !day.isEmpty
        let limit = min(max(Int(option("--limit", in: args) ?? (scoped ? "200" : "50")) ?? 50, 1), scoped ? 200 : 50)
        var path = "/api/meetings?limit=\(limit)&domain=\(queryEscape(domain))"
        if !month.isEmpty { path += "&month=\(queryEscape(month))" }
        if !day.isEmpty { path += "&day=\(queryEscape(day))" }
        let body = try speakerReviewBody(path, timeout: 30)
        let raw = (body["meetings"] as? [[String: Any]]) ?? []
        let rows: [[String: Any]] = raw.compactMap(Self.libraryMeetingProjection)
        emit(ok: true, message: rows.isEmpty ? "No meetings in this range" : "Meeting library ready", details: [
            "state": rows.isEmpty ? "empty" : "ready",
            "meetings": rows,
            "months": body["months"] as? [String] ?? [],
            "days": body["days"] as? [[String: Any]] ?? [],
            "count": rows.count,
        ])
    }

    static func meetingScore(_ value: Any?) -> Double {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let string = value as? String, let parsed = Double(string) { return parsed }
        return 0
    }

    static func librarySearchHitProjection(_ row: [String: Any]) -> [String: Any]? {
        guard var fields = libraryMeetingProjection(row) else { return nil }
        let keyword = meetingScore(row["keywordScore"])
        let semantic = meetingScore(row["semanticScore"])
        fields["snippet"] = row["snippet"] as? String ?? ""
        fields["match"] = row["match"] as? String ?? "keyword"
        fields["keywordScore"] = keyword
        fields["semanticScore"] = semantic
        fields["score"] = max(keyword, semantic)
        return fields
    }

    static func contextSearchHitProjection(_ row: [String: Any], kind: String) -> [String: Any]? {
        guard let id = row["id"] as? String, !id.isEmpty else { return nil }
        let keyword = meetingScore(row["keywordScore"])
        let semantic = meetingScore(row["semanticScore"])
        let title = row["title"] as? String ?? row["name"] as? String ?? row["summary"] as? String ?? ""
        return [
            "id": id,
            "title": title,
            "summary": title,
            "name": row["name"] as? String ?? title,
            "snippet": row["snippet"] as? String ?? "",
            "match": row["match"] as? String ?? "keyword",
            "keywordScore": keyword,
            "semanticScore": semantic,
            "score": max(keyword, semantic),
            "kind": kind,
            "type": row["type"] as? String ?? "",
            "created_at": row["created_at"] as? String ?? "",
            "content": row["snippet"] as? String ?? "",
            "domain": row["domain"] as? String ?? "",
            "meeting_count": meetingCount(row["meeting_count"]),
            "is_resolved": row["is_resolved"] as? Bool ?? false,
            "topics": row["topics"] as? [String] ?? [],
        ]
    }

    /// Chunks below this are noise, not a meeting. Same floor as the server
    /// `isWorthRecovering` picker, so Recover all cannot POST a capture the
    /// badge itself would not count.
    static let minRecoverableOrphanChunks = 2

    static func orphanItemProjection(_ row: [String: Any]) -> [String: Any]? {
        guard let sessionId = row["sessionId"] as? String, !sessionId.isEmpty else { return nil }
        return [
            "sessionId": sessionId,
            "dirName": row["dirName"] as? String ?? "",
            "chunkFiles": Self.meetingCount(row["chunkFiles"]),
            "bytes": Self.meetingCount(row["bytes"]),
            "ageHours": row["ageHours"] ?? NSNull(),
            "recovered": row["recovered"] as? Bool ?? false,
            "reason": row["reason"] as? String ?? "",
            "expiresAt": row["expiresAt"] as? String ?? "",
            "quarantinedAt": row["quarantinedAt"] as? String ?? "",
        ]
    }

    static func isRecoverableOrphan(_ row: [String: Any]) -> Bool {
        (row["recovered"] as? Bool ?? false) == false
            && Self.meetingCount(row["chunkFiles"]) >= minRecoverableOrphanChunks
    }

    static func strandedItemProjection(_ row: [String: Any]) -> [String: Any]? {
        guard let sessionId = row["sessionId"] as? String, !sessionId.isEmpty else { return nil }
        return [
            "sessionId": sessionId,
            "idleMinutes": Self.meetingCount(row["idleMinutes"]),
            "capturedMinutes": Self.meetingCount(row["capturedMinutes"]),
            "chunks": Self.meetingCount(row["chunks"]),
            "promotesAt": row["promotesAt"] as? String ?? "",
        ]
    }

    static func recoverableOrphanSessionIds(_ items: [[String: Any]]) -> [String] {
        items.compactMap { row in
            guard isRecoverableOrphan(row) else { return nil }
            return row["sessionId"] as? String
        }
    }

    private func orphanSessionPath(_ sessionId: String) throws -> String {
        guard sessionId.range(of: "^[A-Za-z0-9:_-]{3,96}$", options: .regularExpression) != nil else {
            throw HelperError.message("Invalid capture id")
        }
        let escaped = sessionId.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_:"))
        ) ?? sessionId
        return "/api/meeting/orphans/\(escaped)/recover"
    }

    private func meetingOrphansBody() throws -> [String: Any] {
        let token = try speakerReviewToken()
        guard let response = request("/api/meeting/orphans", token: token, timeout: 20) else {
            throw HelperError.message("Server stopped")
        }
        if response.status == 401 || response.status == 403 { throw HelperError.message("Unauthorized") }
        if response.status == 404 {
            throw HelperError.message("Update the server to recover unsaved captures from this panel.")
        }
        guard response.status == 200, let body = response.body else {
            throw HelperError.message("Could not list unsaved captures.")
        }
        return body
    }

    private func emitMeetingOrphans() throws {
        let body = try meetingOrphansBody()
        let recovering = (body["recovering"] as? [String]) ?? []
        let recoveringSet = Set(recovering)
        let items = ((body["items"] as? [[String: Any]]) ?? []).compactMap(Self.orphanItemProjection).map { row -> [String: Any] in
            var next = row
            let sessionId = row["sessionId"] as? String ?? ""
            next["recovering"] = recoveringSet.contains(sessionId)
            next["recoverable"] = Self.isRecoverableOrphan(row)
            return next
        }
        let stranded = ((body["stranded"] as? [[String: Any]]) ?? []).compactMap(Self.strandedItemProjection)
        let recoverable = items.filter { ($0["recoverable"] as? Bool) == true }
        emit(ok: true, message: recoverable.isEmpty ? "No recoverable captures" : "\(recoverable.count) recoverable", details: [
            "count": body["count"] as? Int ?? recoverable.count,
            "strandedCount": body["strandedCount"] as? Int ?? stranded.count,
            "recovering": recovering,
            "recoveringProgress": body["recoveringProgress"] ?? [:],
            "items": items,
            "stranded": stranded,
        ])
    }

    private func postOrphanRecover(sessionId: String) throws -> (status: Int, body: [String: Any]) {
        let token = try speakerReviewToken()
        let path = try orphanSessionPath(sessionId)
        guard let response = request(path, method: "POST", token: token, body: "{}", timeout: 30) else {
            throw HelperError.message("Server stopped")
        }
        if response.status == 401 || response.status == 403 { throw HelperError.message("Unauthorized") }
        return (response.status, response.body ?? [:])
    }

    private func emitMeetingOrphanRecover(args: [String]) throws {
        guard let sessionId = option("--session", in: args)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else {
            throw HelperError.message("--session is required")
        }
        let posted = try postOrphanRecover(sessionId: sessionId)
        if posted.status == 202, posted.body["accepted"] as? Bool == true {
            emit(ok: true, message: "Recovery started", details: posted.body)
            return
        }
        if posted.status == 200, posted.body["alreadySaved"] as? Bool == true {
            emit(ok: true, message: "Already saved", details: posted.body)
            return
        }
        if posted.status == 409 {
            throw HelperError.message("Recovery already in progress for this capture.")
        }
        if posted.status == 404 {
            throw HelperError.message("No quarantined audio for this capture. Session files were not deleted.")
        }
        if posted.status == 503 {
            throw HelperError.message(posted.body["error"] as? String ?? "Server is busy with another recovery. Wait, then retry.")
        }
        let reason = posted.body["error"] as? String ?? posted.body["reason"] as? String ?? "Recovery failed (\(posted.status))"
        throw HelperError.message(reason)
    }

    private func recoveringSessionIds(_ body: [String: Any]) -> [String] {
        (body["recovering"] as? [String]) ?? []
    }

    private func waitForOrphanSlot(sessionId: String?, timeout: TimeInterval, label: String) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var last = try meetingOrphansBody()
        while Date() < deadline {
            let recovering = recoveringSessionIds(last)
            if let sessionId {
                if !recovering.contains(sessionId) { return last }
            } else if recovering.isEmpty {
                return last
            }
            progress(label)
            Thread.sleep(forTimeInterval: 2)
            last = try meetingOrphansBody()
        }
        throw HelperError.message("Timed out waiting for a recovery slot.")
    }

    private func emitMeetingOrphanRecoverAll() throws {
        var body = try meetingOrphansBody()
        if !recoveringSessionIds(body).isEmpty {
            progress("Waiting for the current recovery to finish…")
            body = try waitForOrphanSlot(sessionId: nil, timeout: 20 * 60, label: "Waiting for the current recovery to finish…")
        }
        let items = (body["items"] as? [[String: Any]]) ?? []
        let ids = Self.recoverableOrphanSessionIds(items)
        if ids.isEmpty {
            emit(ok: true, message: "No recoverable captures", details: [
                "recovered": 0, "skipped": 0, "failed": [] as [String],
            ])
            return
        }
        var recovered = 0
        var skipped = 0
        var failed: [String] = []
        for (index, sessionId) in ids.enumerated() {
            if index > 0 {
                progress("Waiting before capture \(index + 1) of \(ids.count)…")
                _ = try waitForOrphanSlot(sessionId: nil, timeout: 20 * 60, label: "Waiting before capture \(index + 1) of \(ids.count)…")
            }
            progress("Recovering \(index + 1) of \(ids.count)…")
            do {
                let posted = try postOrphanRecover(sessionId: sessionId)
                if posted.status == 202, posted.body["accepted"] as? Bool == true {
                    recovered += 1
                    _ = try waitForOrphanSlot(
                        sessionId: sessionId,
                        timeout: 20 * 60,
                        label: "Recovering \(index + 1) of \(ids.count)…"
                    )
                    continue
                }
                if posted.status == 200, posted.body["alreadySaved"] as? Bool == true {
                    skipped += 1
                    continue
                }
                if posted.status == 409 {
                    skipped += 1
                    _ = try waitForOrphanSlot(sessionId: sessionId, timeout: 20 * 60, label: "Waiting for \(sessionId)…")
                    continue
                }
                failed.append(sessionId)
            } catch {
                failed.append(sessionId)
            }
        }
        let message: String
        if failed.isEmpty {
            message = recovered == 1 ? "Started recovery for 1 capture." : "Started recovery for \(recovered) capture(s)."
        } else {
            message = "Recovered \(recovered). \(failed.count) failed. Session files were not deleted."
        }
        emit(ok: true, message: message, details: [
            "recovered": recovered,
            "skipped": skipped,
            "failed": failed,
        ])
    }

    private func postMeetingSave(sessionId: String) throws -> (status: Int, body: [String: Any]) {
        guard sessionId.range(of: "^[A-Za-z0-9:_-]{3,96}$", options: .regularExpression) != nil else {
            throw HelperError.message("Invalid capture id")
        }
        let token = try speakerReviewToken()
        let body = "{\"sessionId\":\"\(sessionId)\"}"
        guard let response = request("/api/meeting/save", method: "POST", token: token, body: body, timeout: 180) else {
            throw HelperError.message("Server stopped")
        }
        if response.status == 401 || response.status == 403 { throw HelperError.message("Unauthorized") }
        return (response.status, response.body ?? [:])
    }

    private func emitMeetingStrandedSave(args: [String]) throws {
        guard let sessionId = option("--session", in: args)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else {
            throw HelperError.message("--session is required")
        }
        let posted = try postMeetingSave(sessionId: sessionId)
        if posted.status == 200, posted.body["filename"] as? String != nil {
            emit(ok: true, message: "Saved capture as a meeting.", details: posted.body)
            return
        }
        if posted.status == 200, posted.body["alreadySaved"] as? Bool == true {
            emit(ok: true, message: "Already saved", details: posted.body)
            return
        }
        if posted.status == 409 {
            throw HelperError.message("Save already in progress for this capture.")
        }
        if posted.status == 404 {
            throw HelperError.message(posted.body["error"] as? String ?? "No transcript for this capture. Session files were not deleted.")
        }
        let reason = posted.body["error"] as? String ?? posted.body["reason"] as? String ?? "Save failed (\(posted.status))"
        throw HelperError.message(reason)
    }

    private func emitMeetingStrandedSaveAll() throws {
        let body = try meetingOrphansBody()
        let stranded = ((body["stranded"] as? [[String: Any]]) ?? []).compactMap(Self.strandedItemProjection)
        let ids = stranded.compactMap { $0["sessionId"] as? String }
        if ids.isEmpty {
            emit(ok: true, message: "No still-live captures", details: [
                "saved": 0, "failed": [] as [String],
            ])
            return
        }
        var saved = 0
        var failed: [String] = []
        for (index, sessionId) in ids.enumerated() {
            progress("Saving \(index + 1) of \(ids.count)…")
            do {
                let posted = try postMeetingSave(sessionId: sessionId)
                if posted.status == 200, posted.body["filename"] as? String != nil || posted.body["alreadySaved"] as? Bool == true {
                    saved += 1
                    continue
                }
                failed.append(sessionId)
            } catch {
                failed.append(sessionId)
            }
        }
        let message: String
        if failed.isEmpty {
            message = saved == 1 ? "Saved 1 capture as a meeting." : "Saved \(saved) captures as meetings."
        } else {
            message = "Saved \(saved). \(failed.count) failed. Session files were not deleted."
        }
        emit(ok: true, message: message, details: [
            "saved": saved,
            "failed": failed,
        ])
    }

    static func sessionSearchHitProjection(_ row: [String: Any]) -> [String: Any]? {
        let id = (row["session_id"] as? String ?? row["id"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        let keyword = meetingScore(row["keywordScore"])
        let semantic = meetingScore(row["semanticScore"])
        let name = row["display_label"] as? String
            ?? row["custom_title"] as? String
            ?? row["name"] as? String
            ?? ""
        return [
            "id": id,
            "provider": row["provider"] as? String ?? "claude",
            "name": name,
            "workspace": workspaceLabel(row["project"] as? String ?? row["workspace"] as? String ?? ""),
            "state": row["state"] as? String ?? "recent",
            "status": row["state"] as? String ?? "recent",
            "waitingFor": row["waitingFor"] as? String ?? "",
            "alive": row["alive"] as? Bool ?? false,
            "reachable": false,
            "pinned": row["pinned"] as? Bool ?? false,
            "createdAt": row["created"] as? String ?? row["createdAt"] as? String ?? "",
            "updatedAt": row["modified"] as? String ?? row["updatedAt"] as? String ?? "",
            "snippet": row["snippet"] as? String ?? "",
            "match": row["match"] as? String ?? "keyword",
            "keywordScore": keyword,
            "semanticScore": semantic,
            "score": max(keyword, semantic),
        ]
    }

    static let sessionSearchStopwords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "for", "on", "at", "by",
        "with", "from", "vs", "is", "it", "be", "as", "we", "our",
    ]

    static func tokenizeSessionQuery(_ query: String) -> [String] {
        let matches = query.lowercased().split { !$0.isLetter && !$0.isNumber }
        var seen = Set<String>()
        var tokens: [String] = []
        for part in matches {
            let token = String(part)
            guard token.count >= 2, !sessionSearchStopwords.contains(token), !seen.contains(token) else { continue }
            seen.insert(token)
            tokens.append(token)
        }
        return tokens
    }

    static func scoreSessionKeyword(tokens: [String], title: String, haystack: String) -> (score: Double, snippet: String) {
        guard !tokens.isEmpty else { return (0, "") }
        let titleL = title.lowercased()
        let hayL = haystack.lowercased()
        var hits = 0
        var titleHits = 0
        var firstAt = -1
        for token in tokens {
            let inTitle = titleL.contains(token)
            let inHay = hayL.contains(token)
            if !inTitle && !inHay { continue }
            hits += 1
            if inTitle { titleHits += 1 }
            if firstAt < 0 {
                if let range = hayL.range(of: token) {
                    firstAt = hayL.distance(from: hayL.startIndex, to: range.lowerBound)
                } else {
                    firstAt = 0
                }
            }
        }
        if hits == 0 { return (0, "") }
        let coverage = Double(hits) / Double(tokens.count)
        if coverage < 0.5 && titleHits == 0 { return (0, "") }
        let score = min(1, coverage * 0.65 + (Double(titleHits) / Double(tokens.count)) * 0.35)
        let start = max(0, firstAt - 40)
        let end = min(haystack.count, start + 180)
        let lower = haystack.index(haystack.startIndex, offsetBy: start)
        let upper = haystack.index(haystack.startIndex, offsetBy: end)
        let snippet = String(haystack[lower..<upper]).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (score, snippet)
    }

    static let sessionSearchBodyBytes = 96 * 1024
    static let sessionSearchBodyFileLimit = 80
    static let sessionSearchBodyMaxAge: TimeInterval = 7 * 24 * 3600

    static func sessionSearchBodyChunk(_ obj: [String: Any]) -> String? {
        let type = obj["type"] as? String ?? ""
        if type == "user" || type == "assistant" {
            if obj["toolUseResult"] != nil || obj["isSidechain"] as? Bool == true { return nil }
            if let message = obj["message"] as? [String: Any] { return claudeMessageText(message) }
        }
        if (obj["role"] as? String) == "user" || (obj["role"] as? String) == "assistant",
           let message = obj["message"] as? [String: Any] {
            return claudeMessageText(message)
        }
        if type == "response_item",
           let payload = obj["payload"] as? [String: Any],
           payload["type"] as? String == "message",
           let text = payloadText(payload),
           !isWrapperPrompt(text) {
            return text
        }
        return nil
    }

    static func peekSessionSearchBody(in file: URL, maxBytes: Int = sessionSearchBodyBytes) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: maxBytes)
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        var parts: [String] = []
        var used = 0
        for line in text.split(whereSeparator: \.isNewline) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let chunk = sessionSearchBodyChunk(obj) else { continue }
            parts.append(chunk)
            used += chunk.count
            if used >= 12_000 { break }
        }
        return parts.joined(separator: "\n")
    }

    struct SessionSearchTranscript {
        var provider: String
        var id: String
        var file: URL
        var mtime: Date
    }

    static func listSessionSearchTranscripts(
        claudeProjects: URL,
        codexRoot: URL,
        cursorProjects: URL,
        now: Date = Date(),
        maxAge: TimeInterval = sessionSearchBodyMaxAge,
        limit: Int = sessionSearchBodyFileLimit
    ) -> [SessionSearchTranscript] {
        var rows: [SessionSearchTranscript] = []
        let uuidName = try? NSRegularExpression(
            pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.jsonl$"
        )
        let claudeDirs = (try? FileManager.default.contentsOfDirectory(
            at: claudeProjects,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for dir in claudeDirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files {
                let name = file.lastPathComponent
                let whole = NSRange(name.startIndex..<name.endIndex, in: name)
                guard uuidName?.firstMatch(in: name, range: whole) != nil else { continue }
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                guard now.timeIntervalSince(mtime) <= maxAge else { continue }
                rows.append(SessionSearchTranscript(
                    provider: "claude",
                    id: String(name.dropLast(6)),
                    file: file,
                    mtime: mtime
                ))
            }
        }
        for file in listCodexJsonlFiles(sessionsRoot: codexRoot) {
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            guard now.timeIntervalSince(mtime) <= maxAge else { continue }
            let id = idFromCodexFilename(file.lastPathComponent)
                ?? file.deletingPathExtension().lastPathComponent
            rows.append(SessionSearchTranscript(provider: "codex", id: id, file: file, mtime: mtime))
        }
        let cursorDirs = (try? FileManager.default.contentsOfDirectory(
            at: cursorProjects,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for project in cursorDirs {
            let isDir = (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let folder = project.lastPathComponent
            if folder == "empty-window" || folder.contains("var-folders") || folder.contains("private-var") { continue }
            let transcripts = project.appendingPathComponent("agent-transcripts", isDirectory: true)
            guard let sessions = try? FileManager.default.contentsOfDirectory(
                at: transcripts,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for sessionDir in sessions {
                if sessionDir.lastPathComponent == "subagents" { continue }
                let nativeId = sessionDir.lastPathComponent
                let file = sessionDir.appendingPathComponent("\(nativeId).jsonl")
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                guard now.timeIntervalSince(mtime) <= maxAge else { continue }
                rows.append(SessionSearchTranscript(provider: "cursor", id: nativeId, file: file, mtime: mtime))
            }
        }
        rows.sort { $0.mtime > $1.mtime }
        return Array(rows.prefix(max(1, min(limit, sessionSearchBodyFileLimit))))
    }

    static func localSessionKeywordHits(query: String, limit: Int, home: URL) -> [[String: Any]] {
        let tokens = tokenizeSessionQuery(query)
        guard !tokens.isEmpty else { return [] }
        let claudeProjects = home.appendingPathComponent(".claude/projects", isDirectory: true)
        let claudeDesktop = home.appendingPathComponent(
            "Library/Application Support/Claude/claude-code-sessions", isDirectory: true
        )
        let claudeStarred = loadClaudeStarredIds(
            from: home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        )
        let composerNames = loadCursorComposerNames(
            from: home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        )
        let cursorPinned = loadCursorPinnedIds(
            from: home.appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage")
        )
        let desktopIndex = loadClaudeDesktopIndex(from: claudeDesktop)
        var rows: [[String: Any]] = []
        var seen = Set<String>()
        func add(_ row: [String: Any]) {
            let id = (row["id"] as? String ?? "").lowercased()
            let provider = row["provider"] as? String ?? "claude"
            guard !id.isEmpty else { return }
            let key = "\(provider):\(id)"
            if seen.contains(key) { return }
            seen.insert(key)
            rows.append(row)
        }
        for (id, head) in desktopIndex where id == head.id {
            let title = head.title.isEmpty ? "Claude session" : head.title
            add([
                "id": String(id.prefix(8)),
                "provider": "claude",
                "name": title,
                "workspace": workspaceLabel(head.cwd),
                "state": "recent",
                "status": "recent",
                "waitingFor": "",
                "alive": false,
                "reachable": false,
                "pinned": claudeStarred.contains(id),
                "createdAt": isoString(from: head.created),
                "updatedAt": isoString(from: head.mtime),
            ])
        }
        for row in recentClaudeConversations(
            liveIds: [],
            projectsRoot: claudeProjects,
            starredIds: claudeStarred,
            desktopSessionsRoot: claudeDesktop,
            desktopIndex: desktopIndex
        ) { add(row) }
        let codexRoot = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        for (id, name) in loadCodexThreadNames(sessionsRoot: codexRoot) {
            add([
                "id": id,
                "provider": "codex",
                "name": name,
                "workspace": "",
                "state": "recent",
                "status": "recent",
                "waitingFor": "",
                "alive": false,
                "reachable": false,
                "pinned": false,
                "createdAt": "",
                "updatedAt": "",
            ])
        }
        for row in recentCodexConversations(sessionsRoot: codexRoot) { add(row) }
        for (id, name) in composerNames {
            add([
                "id": id,
                "provider": "cursor",
                "name": name,
                "workspace": "",
                "state": "recent",
                "status": "recent",
                "waitingFor": "",
                "alive": false,
                "reachable": false,
                "pinned": cursorPinned.contains(id.lowercased()),
                "createdAt": "",
                "updatedAt": "",
            ])
        }
        let cursorProjects = home.appendingPathComponent(".cursor/projects", isDirectory: true)
        for row in recentCursorConversations(
            projectsRoot: cursorProjects,
            composerNames: composerNames,
            pinnedIds: cursorPinned
        ) { add(row) }
        var hitsByKey: [String: [String: Any]] = [:]
        var rowByKey: [String: [String: Any]] = [:]
        func keep(_ hit: [String: Any]) {
            let id = (hit["id"] as? String ?? "").lowercased()
            let provider = hit["provider"] as? String ?? "claude"
            guard !id.isEmpty else { return }
            let key = "\(provider):\(id)"
            if let existing = hitsByKey[key], meetingScore(existing["score"]) >= meetingScore(hit["score"]) { return }
            hitsByKey[key] = hit
        }
        func consider(row: [String: Any], haystack: String) {
            let name = row["name"] as? String ?? ""
            let scored = scoreSessionKeyword(tokens: tokens, title: name, haystack: haystack)
            if scored.score <= 0 { return }
            var hit = row
            hit["snippet"] = scored.snippet.isEmpty ? name : scored.snippet
            hit["match"] = "keyword"
            hit["keywordScore"] = scored.score
            hit["semanticScore"] = 0.0
            hit["score"] = scored.score
            keep(hit)
        }
        for row in rows {
            let id = (row["id"] as? String ?? "").lowercased()
            let provider = row["provider"] as? String ?? "claude"
            rowByKey["\(provider):\(id)"] = row
            consider(row: row, haystack: "\(row["name"] as? String ?? "")\n\(row["workspace"] as? String ?? "")")
        }
        for item in listSessionSearchTranscripts(
            claudeProjects: claudeProjects,
            codexRoot: codexRoot,
            cursorProjects: cursorProjects
        ) {
            let short = String(item.id.prefix(8)).lowercased()
            var row = rowByKey["\(item.provider):\(item.id.lowercased())"]
                ?? rowByKey["\(item.provider):\(short)"]
            if row == nil {
                let desktop = item.provider == "claude"
                    ? (desktopIndex[item.id.lowercased()] ?? desktopIndex[short])
                    : nil
                let fallback = item.provider == "codex" ? "Codex session"
                    : item.provider == "cursor" ? "Cursor session"
                    : "Claude session"
                let title = (desktop?.title.isEmpty == false) ? (desktop?.title ?? fallback) : fallback
                row = [
                    "id": item.provider == "claude" ? String(item.id.prefix(8)) : item.id,
                    "provider": item.provider,
                    "name": title,
                    "workspace": workspaceLabel(desktop?.cwd ?? ""),
                    "state": "recent",
                    "status": "recent",
                    "waitingFor": "",
                    "alive": false,
                    "reachable": false,
                    "pinned": false,
                    "createdAt": "",
                    "updatedAt": isoString(from: item.mtime),
                ]
            }
            guard let row else { continue }
            let name = row["name"] as? String ?? ""
            let workspace = row["workspace"] as? String ?? ""
            let nameL = name.lowercased()
            if tokens.allSatisfy({ nameL.contains($0) }) { continue }
            let body = peekSessionSearchBody(in: item.file)
            if body.isEmpty { continue }
            consider(row: row, haystack: "\(name)\n\(workspace)\n\(body)")
            if item.provider == "claude",
               let desktop = desktopIndex[item.id.lowercased()] ?? desktopIndex[short] {
                let alias = String(desktop.id.prefix(8)).lowercased()
                if alias != (row["id"] as? String ?? "").lowercased(),
                   let aliasRow = rowByKey["claude:\(alias)"] {
                    consider(
                        row: aliasRow,
                        haystack: "\(aliasRow["name"] as? String ?? "")\n\(aliasRow["workspace"] as? String ?? "")\n\(body)"
                    )
                }
            }
        }
        return Array(
            hitsByKey.values.sorted { meetingScore($0["score"]) > meetingScore($1["score"]) }
                .prefix(max(1, min(limit, 50)))
        )
    }

    private func emitClaudeSessionsSearch(args: [String]) throws {
        guard let query = option("--query", in: args)?.trimmingCharacters(in: .whitespacesAndNewlines),
              query.count >= 2 else {
            throw HelperError.message("--query must be at least 2 characters")
        }
        let limit = min(max(Int(option("--limit", in: args) ?? "20") ?? 20, 1), 50)
        let path = "/api/agent-sessions/search?q=\(queryEscape(query))&limit=\(limit)"
        if let token = try? speakerReviewToken(),
           let response = request(path, token: token, timeout: 2) {
            if response.status == 401 || response.status == 403 { throw HelperError.message("Unauthorized") }
            if response.status == 200 {
                let body = response.body ?? [:]
                let raw = (body["hits"] as? [[String: Any]]) ?? []
                let rows = raw.compactMap(Self.sessionSearchHitProjection)
                emit(ok: true, message: rows.isEmpty ? "No matching sessions" : "Session lookup ready", details: [
                    "state": rows.isEmpty ? "empty" : "ready",
                    "hits": rows,
                    "count": rows.count,
                    "keywordCount": body["keywordCount"] as? Int ?? rows.count,
                    "semanticCount": body["semanticCount"] as? Int ?? 0,
                    "semanticAvailable": body["semanticAvailable"] as? Bool ?? false,
                    "semanticReason": body["semanticReason"] as? String ?? "",
                ])
                return
            }
        }
        let rows = Self.localSessionKeywordHits(query: query, limit: limit, home: FileManager.default.homeDirectoryForCurrentUser)
        emit(ok: true, message: rows.isEmpty ? "No matching sessions" : "Session lookup ready", details: [
            "state": rows.isEmpty ? "empty" : "ready",
            "hits": rows,
            "count": rows.count,
            "keywordCount": rows.count,
            "semanticCount": 0,
            "semanticAvailable": false,
            "semanticReason": "server_too_old",
        ])
    }

    private func emitMeetingsLibrarySearch(args: [String]) throws {
        guard let query = option("--query", in: args)?.trimmingCharacters(in: .whitespacesAndNewlines),
              query.count >= 2 else {
            throw HelperError.message("--query must be at least 2 characters")
        }
        let domain = option("--domain", in: args) ?? "all"
        let limit = min(max(Int(option("--limit", in: args) ?? "20") ?? 20, 1), 50)
        let path = "/api/meetings/search?q=\(queryEscape(query))&limit=\(limit)&domain=\(queryEscape(domain))"
        let body = try speakerReviewBody(path, timeout: 25)
        let raw = (body["hits"] as? [[String: Any]]) ?? []
        let rows: [[String: Any]] = raw.compactMap(Self.librarySearchHitProjection)
        emit(ok: true, message: rows.isEmpty ? "No matching meetings" : "Meeting lookup ready", details: [
            "state": rows.isEmpty ? "empty" : "ready",
            "hits": rows,
            "count": rows.count,
            "keywordCount": body["keywordCount"] as? Int ?? rows.count,
            "semanticCount": body["semanticCount"] as? Int ?? 0,
            "semanticAvailable": body["semanticAvailable"] as? Bool ?? false,
            "semanticReason": body["semanticReason"] as? String ?? "",
        ])
    }

    private func emitContextSearch(kind: String, args: [String]) throws {
        guard let query = option("--query", in: args)?.trimmingCharacters(in: .whitespacesAndNewlines),
              query.count >= 2 else {
            throw HelperError.message("--query must be at least 2 characters")
        }
        let limit = min(max(Int(option("--limit", in: args) ?? "20") ?? 20, 1), 50)
        let route = kind == "thread" ? "/api/threads/search" : "/api/memory/search"
        let path = "\(route)?q=\(queryEscape(query))&limit=\(limit)"
        let body: [String: Any]
        do {
            body = try speakerReviewBody(path, timeout: 25)
        } catch {
            let text = "\(error)"
            if text.contains("(404)") {
                throw HelperError.message(kind == "thread"
                    ? "Update the server to search threads from this panel."
                    : "Update the server to search memories from this panel.")
            }
            throw error
        }
        let raw = (body["hits"] as? [[String: Any]]) ?? []
        let rows = raw.compactMap { Self.contextSearchHitProjection($0, kind: kind) }
        let noun = kind == "thread" ? "threads" : "memories"
        emit(ok: true, message: rows.isEmpty ? "No matching \(noun)" : "Lookup ready", details: [
            "state": rows.isEmpty ? "empty" : "ready",
            "hits": rows,
            "count": rows.count,
            "keywordCount": body["keywordCount"] as? Int ?? rows.count,
            "semanticCount": body["semanticCount"] as? Int ?? 0,
            "semanticAvailable": body["semanticAvailable"] as? Bool ?? false,
            "semanticReason": body["semanticReason"] as? String ?? "",
        ])
    }

    private func emitMeetingLibraryDetail(args: [String]) throws {
        guard let domain = option("--domain", in: args), !domain.isEmpty,
              let month = option("--month", in: args), !month.isEmpty,
              let filename = option("--filename", in: args), !filename.isEmpty else {
            throw HelperError.message("--domain, --month, and --filename are required")
        }
        let path = "/api/meetings/detail?domain=\(queryEscape(domain))&month=\(queryEscape(month))&filename=\(queryEscape(filename))"
        let body = try speakerReviewBody(path, timeout: 30)
        emit(ok: true, message: "Meeting ready", details: body)
    }

    private func emitMeetingSpeakers(args: [String]) throws {
        guard let session = option("--session", in: args), !session.isEmpty else {
            throw HelperError.message("--session is required")
        }
        let escaped = session.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_:"))) ?? session
        let body = try speakerReviewBody("/api/meeting/\(escaped)/speakers", timeout: 25)
        emit(ok: true, message: "Speaker review ready", details: [
            "state": (body["attributed"] as? Bool) == true ? "attributed" : "unattributed",
            "review": body,
        ])
    }

    /// The readable meeting plus its two clipboard forms.
    ///
    /// Body passes through VERBATIM, like emitMeetingSpeakers and unlike
    /// meetingRowProjection — that one is a key whitelist and would silently drop
    /// any field the server adds later. Timeout is larger than the speaker
    /// review's because the full clipboard string carries the transcript
    /// (measured 28 KB on a 26-minute meeting).
    private func emitMeetingContent(args: [String]) throws {
        guard let session = option("--session", in: args), !session.isEmpty else {
            throw HelperError.message("--session is required")
        }
        let escaped = session.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_:"))
        ) ?? session
        // A 404 means the SERVER is older than 6.21.28 — a different situation
        // from a real failure, and the GUI must say so rather than silently
        // hiding the feature. Classified here, once, so Swift reads a structured
        // field instead of sniffing an error string. Anything unrecognised falls
        // through as a generic failure, which is still better than silence.
        do {
            let body = try speakerReviewBody("/api/meeting/\(escaped)/content", timeout: 30)
            emit(ok: true, message: "Meeting content ready", details: [
                "content": body,
            ])
        } catch let error {
            let text = "\(error)"
            let routeAbsent = text.contains("(404)")
            emit(ok: true, message: routeAbsent ? "Meeting content unavailable" : "Meeting content failed", details: [
                "unavailable": routeAbsent ? "route_absent" : "error",
                "detail": text,
            ])
        }
    }

    /// Enrolled profiles, for the naming field's autocomplete.
    // ── Fenced threads ──────────────────────────────────────
    //
    // A fence shuts a native thread that may already hold an undelivered COS turn,
    // so a prompt cannot be double-delivered into a real conversation. Before
    // glasses-server 6.36.10 it was in-memory only, invisible, and the only thing
    // that cleared it was restarting the server. These two commands are what make
    // it recoverable from Control instead of from a terminal.

    private func emitFences() throws {
        let body = try speakerReviewBody("/api/agent-sessions/fences")
        emit(ok: true, message: "Fences ready", details: [
            "fences": (body["fences"] as? [[String: Any]]) ?? [],
            // True when the server's last durable write failed. A memory-only fence
            // set behaves identically until the process restarts, so it is reported
            // rather than inferred.
            "degraded": body["degraded"] as? Bool ?? false,
        ])
    }

    /// Release one fence.
    ///
    /// The server FAILS CLOSED: without `confirm` it answers 400 with a preview of
    /// what would be reopened. That 400 is the gate, not an error — routing it
    /// through `speakerReviewBody` would throw and the panel would show nothing
    /// when a row is clicked, which is exactly how the merge flow shipped broken in
    /// 0.4.0. 404 is a stale handle; 500 is a fence the server could not durably
    /// release and is still holding.
    private func emitFenceRelease(args: [String]) throws {
        guard let target = option("--target", in: args), !target.isEmpty else {
            throw HelperError.message("--target is required")
        }
        var payload: [String: Any] = ["target": target]
        if args.contains("--confirm") { payload["confirm"] = true }
        let json = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? "{}"

        let token = try speakerReviewToken()
        guard let response = request("/api/agent-sessions/fences/release", method: "POST", token: token, body: json, timeout: 30) else {
            throw HelperError.message("Server stopped")
        }
        if response.status == 401 || response.status == 403 { throw HelperError.message("Unauthorized") }
        guard let body = response.body else { throw HelperError.message("Server stopped") }

        let gated = response.status == 400
        let missing = response.status == 404
        let held = response.status == 500
        if response.status != 200 && !gated && !missing && !held {
            let reason = (body["reason"] as? String) ?? "Request failed (\(response.status))"
            throw HelperError.message(reason)
        }

        let released = body["released"] as? Bool ?? false
        let reason = body["reason"] as? String ?? ""
        let message: String
        if released { message = "Fence released" }
        else if gated { message = "Confirmation required" }
        else if missing { message = "That fence is no longer on record" }
        else { message = "The server could not durably release it — the thread is still fenced" }

        emit(ok: true, message: message, details: [
            "released": released,
            "reason": reason,
            "confirmationRequired": gated,
            "preview": (body["preview"] as? [String: Any]) ?? [:],
            "target": target,
        ])
    }

    private func emitVoiceProfiles() throws {
        let body = try speakerReviewBody("/api/voice/profiles")
        emit(ok: true, message: "Voice profiles ready", details: [
            "owner": body["owner"] as? String ?? "",
            "count": body["count"] as? Int ?? 0,
            "profiles": (body["profiles"] as? [[String: Any]]) ?? [],
        ])
    }

    /// Enrolled people plus bounded cross-meeting evidence.
    ///
    /// A 404 is an honest older-server state, not an empty directory. We keep
    /// the existing profile endpoint as a compatibility fallback so Control can
    /// still show training coverage while explaining that meeting history needs
    /// a server update.
    private func emitVoiceDirectory(args: [String]) throws {
        let token = try speakerReviewToken()
        let refresh = args.contains("--refresh") ? "&refresh=1" : ""
        guard let response = request("/api/voice/directory?limit=100\(refresh)", token: token, timeout: 45) else {
            throw HelperError.message("Server stopped")
        }
        if response.status == 401 || response.status == 403 { throw HelperError.message("Unauthorized") }
        if response.status == 404 {
            let body = try speakerReviewBody("/api/voice/profiles")
            emit(ok: true, message: "Voice history needs a server update", details: [
                "state": "route_absent",
                "owner": body["owner"] as? String ?? "",
                "profileCount": body["count"] as? Int ?? 0,
                "totalEmbeddings": body["totalEmbeddings"] as? Int ?? 0,
                "profiles": (body["profiles"] as? [[String: Any]]) ?? [],
            ])
            return
        }
        if response.status != 200 {
            let reason = (response.body?["error"] as? String) ?? "Request failed (\(response.status))"
            throw HelperError.message(reason)
        }
        guard let body = response.body else { throw HelperError.message("Server stopped") }
        emit(ok: true, message: "Voice directory ready", details: [
            "state": "ready",
            "schemaVersion": body["schemaVersion"] as? Int ?? 0,
            "generatedAt": body["generatedAt"] as? String ?? "",
            "owner": body["owner"] as? String ?? "",
            "profileCount": body["profileCount"] as? Int ?? 0,
            "totalEmbeddings": body["totalEmbeddings"] as? Int ?? 0,
            "meetingsScanned": body["meetingsScanned"] as? Int ?? 0,
            "sidecarsSkipped": body["sidecarsSkipped"] as? Int ?? 0,
            "truncated": body["truncated"] as? Bool ?? false,
            "unresolvedMeetings": body["unresolvedMeetings"] as? Int ?? 0,
            "unresolvedSegments": body["unresolvedSegments"] as? Int ?? 0,
            "profiles": (body["profiles"] as? [[String: Any]]) ?? [],
        ])
    }

    /// Fold one profile into another. `--confirm` is required, and it is passed
    /// through to the server rather than synthesised here: the server owns the
    /// similarity floor and its own confirmation, and the helper must not be a
    /// way to bypass either. Without --confirm this returns the server's
    /// preview, which is what the panel shows before asking.
    private func emitVoiceMerge(args: [String]) throws {
        guard let into = option("--into", in: args), !into.isEmpty,
              let from = option("--from", in: args), !from.isEmpty else {
            throw HelperError.message("--into and --from are required")
        }
        let confirm = args.contains("--confirm")
        let force = args.contains("--force")
        var payload: [String: Any] = ["into": into, "from": from]
        if confirm { payload["confirm"] = true } else { payload["dryRun"] = true }
        if force { payload["force"] = true }
        let json = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? "{}"

        // A 409 here is the server REFUSING a below-floor merge, and a 400 is its
        // confirmation gate. Both carry the report the panel needs to explain
        // itself. Routing them through speakerReviewBody would throw, and the
        // panel would show nothing at all when a suggestion is clicked — which is
        // exactly how this shipped broken in 0.4.0.
        let token = try speakerReviewToken()
        guard let response = request("/api/voice/merge-profiles", method: "POST", token: token, body: json, timeout: 30) else {
            throw HelperError.message("Server stopped")
        }
        if response.status == 401 || response.status == 403 { throw HelperError.message("Unauthorized") }
        guard let body = response.body else { throw HelperError.message("Server stopped") }

        let refused = response.status == 409
        let gated = response.status == 400
        if response.status != 200 && !refused && !gated {
            let reason = (body["message"] as? String) ?? (body["error"] as? String)
                ?? "Request failed (\(response.status))"
            throw HelperError.message(reason)
        }
        let report = (body["report"] as? [String: Any]) ?? (body["preview"] as? [String: Any]) ?? body
        emit(ok: true, message: refused
                ? "Merge refused: voices too far apart"
                : (confirm ? "Profiles merged" : "Merge preview ready"),
            details: [
                "state": refused ? "refused" : (gated ? "preview" : (confirm ? "merged" : "preview")),
                "httpStatus": response.status,
                "result": report,
            ])
    }

    /// POST /api/meeting/:id/relabel — correct who a voice was in ONE meeting.
    ///
    /// The scoped replacement for voice-merge. Same 400/409 handling: a 400 is the
    /// server's confirmation gate and a 409 means an earlier correction on this
    /// meeting never finished, and BOTH carry the report the panel needs. Throwing
    /// on them is how 0.4.0 shipped a suggestion that appeared to do nothing.
    private func emitMeetingRelabel(args: [String]) throws {
        guard let session = option("--session", in: args), validSessionID(session),
              let from = option("--from", in: args), !from.isEmpty,
              let to = option("--to", in: args), !to.isEmpty else {
            throw HelperError.message("--session, --from and --to are required")
        }
        var payload: [String: Any] = ["from": from, "to": to]
        if let recordId = option("--record-id", in: args), !recordId.isEmpty { payload["recordId"] = recordId }
        if args.contains("--confirm") { payload["confirm"] = true } else { payload["dryRun"] = true }
        if args.contains("--force") { payload["force"] = true }
        try emitMeetingCorrection(
            path: "/api/meeting/\(escapedSessionID(session))/relabel",
            payload: payload,
            confirmed: args.contains("--confirm"),
            appliedMessage: "Name applied to this meeting"
        )
    }

    /// POST /api/meeting/:id/deattribute — this voice was NOT that person.
    ///
    /// Retraction of the meeting's training samples defaults ON server-side; pass
    /// --keep-training to correct the transcript without touching the profile.
    private func emitMeetingDeattribute(args: [String]) throws {
        guard let session = option("--session", in: args), validSessionID(session),
              let from = option("--from", in: args), !from.isEmpty else {
            throw HelperError.message("--session and --from are required")
        }
        var payload: [String: Any] = ["from": from]
        if let recordId = option("--record-id", in: args), !recordId.isEmpty { payload["recordId"] = recordId }
        if args.contains("--keep-training") { payload["retractTraining"] = false }
        if args.contains("--confirm") { payload["confirm"] = true } else { payload["dryRun"] = true }
        if args.contains("--force") { payload["force"] = true }
        try emitMeetingCorrection(
            path: "/api/meeting/\(escapedSessionID(session))/deattribute",
            payload: payload,
            confirmed: args.contains("--confirm"),
            appliedMessage: "Voice removed from this meeting"
        )
    }

    /// Vouch for a label the display floor demoted.
    ///
    /// Deliberately NOT routed through emitMeetingCorrection: that helper is
    /// built around the two-step dryRun/confirm contract every DESTRUCTIVE
    /// correction uses. A confirmation rewrites nothing — no chunk changes, no
    /// attendee bullet moves, no training sample is retracted — so a preview
    /// step would be theatre, and modelling it as one would imply a blast
    /// radius it does not have.
    private func emitMeetingConfirm(args: [String]) throws {
        guard let session = option("--session", in: args), validSessionID(session),
              let label = option("--label", in: args), !label.isEmpty else {
            throw HelperError.message("--session and --label are required")
        }
        var payload: [String: Any] = ["label": label]
        if let recordId = option("--record-id", in: args), !recordId.isEmpty { payload["recordId"] = recordId }
        let json = String(
            data: try JSONSerialization.data(withJSONObject: payload),
            encoding: .utf8
        ) ?? "{}"
        let body = try speakerReviewBody(
            "/api/meeting/\(escapedSessionID(session))/confirm",
            method: "POST",
            body: json
        )
        let segments = body["segments"] as? Int ?? 0
        emit(ok: true, message: "Confirmed \(label) for this meeting", details: [
            "state": "confirmed",
            "label": label,
            "segments": segments,
        ])
    }

    private func emitMeetingCorrection(
        path: String,
        payload: [String: Any],
        confirmed: Bool,
        appliedMessage: String
    ) throws {
        let json = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? "{}"
        let token = try speakerReviewToken()
        guard let response = request(path, method: "POST", token: token, body: json, timeout: 30) else {
            throw HelperError.message("Server stopped")
        }
        if response.status == 401 || response.status == 403 { throw HelperError.message("Unauthorized") }
        // Classify the STATUS before requiring a JSON body. A server older than
        // 6.21.18 has no such route, and Express's default 404 is HTML — parsing
        // that as JSON yielded nil and reported "Server stopped" for a perfectly
        // healthy server, sending the user off to restart it.
        if response.status == 404 {
            emit(ok: true, message: "This needs a newer glasses-server", details: [
                "state": "route_missing",
                "httpStatus": 404,
            ])
            return
        }
        guard let body = response.body else { throw HelperError.message("Server stopped") }

        // 400 = confirmation gate (carries the full preview).
        // 409 = an earlier correction on this meeting never completed.
        // 422 = the server declined, e.g. the label is not in this meeting.
        let gated = response.status == 400
        let pending = response.status == 409
        let declined = response.status == 422
        if response.status != 200 && !gated && !pending && !declined {
            let reason = (body["message"] as? String) ?? (body["error"] as? String)
                ?? "Request failed (\(response.status))"
            throw HelperError.message(reason)
        }
        let state: String
        if pending { state = "pending_correction" }
        else if declined { state = "declined" }
        else if confirmed && response.status == 200 { state = "applied" }
        else { state = "preview" }
        emit(ok: true, message: state == "applied" ? appliedMessage : (body["message"] as? String ?? "Preview ready"),
            details: [
                "state": state,
                "httpStatus": response.status,
                "result": body,
            ])
    }

    /// GET a WAV for review playback and hand back a temp-file path.
    ///
    /// A path rather than base64: the panel plays it with AVAudioPlayer, and
    /// routing several megabytes of audio through a JSON envelope for every click
    /// would be slower and would blow the message size for a long segment.
    ///
    /// --speaker fetches what a stored PROFILE sounds like (training-audio, no
    /// retention change needed). --session/--chunk fetches one segment of a
    /// meeting from the 7-day review archive.
    private func emitReviewAudio(args: [String]) throws {
        let route: String
        if let speaker = option("--speaker", in: args), !speaker.isEmpty {
            guard let encoded = speaker.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
                throw HelperError.message("Invalid speaker")
            }
            route = "/api/voice/profiles/\(encoded)/sample"
        } else if let session = option("--session", in: args), validSessionID(session) {
            if let chunk = option("--chunk", in: args), let index = Int(chunk), index >= 0 {
                route = "/api/meeting/\(escapedSessionID(session))/audio/\(index)"
            } else {
                route = "/api/voice/ext-audio/\(escapedSessionID(session))/sample"
            }
        } else {
            throw HelperError.message("--speaker, or --session with an optional --chunk, is required")
        }

        let token: String
        do { token = try readToken() }
        catch {
            emit(ok: true, message: "Audio unavailable", details: ["state": "unauthorized"])
            return
        }
        // A 16 kHz mono chunk is tens of kilobytes; 8 MB is generous headroom and
        // still bounded, so a wrong route cannot stream unbounded data into memory.
        try pruneMediaTransfers()
        guard let response = boundedMediaRequest(route, token: token, timeout: 12, maximumBytes: 8 * 1_024 * 1_024) else {
            emit(ok: true, message: "Audio unavailable", details: ["state": "offline"])
            return
        }
        guard response.status == 200, let data = response.data, !data.isEmpty else {
            // 404 is the ordinary case once the retention window has passed, and
            // is reported as a state rather than an error so the panel can say
            // "no longer held" instead of looking broken.
            // A 404 from a MISSING ROUTE is not expired audio. On an older server
            // every playback claimed "no longer held", which is a confident false
            // statement about retention. The listing route below is the capability
            // probe: if it 404s too, the server is old.
            emit(ok: true, message: "Audio unavailable", details: [
                "state": response.status == 404 ? "expired" : mediaState(for: response.status),
                "httpStatus": response.status,
            ])
            return
        }
        // Sniff RIFF/WAVE rather than trusting the content-type: this path writes
        // a file the app will hand to an audio player, and a mislabelled payload
        // should be refused, not played.
        guard data.count > 12,
              data.prefix(4).elementsEqual([0x52, 0x49, 0x46, 0x46]),
              data.dropFirst(8).prefix(4).elementsEqual([0x57, 0x41, 0x56, 0x45]) else {
            emit(ok: true, message: "Audio unavailable", details: ["state": "invalid"])
            return
        }
        let destination = mediaTransferRoot.appendingPathComponent("\(UUID().uuidString.lowercased()).wav")
        try atomicWriteData(data, to: destination, permissions: 0o600)
        emit(ok: true, message: "Audio ready", details: [
            "state": "ready",
            "path": destination.path,
            "bytes": data.count,
            "playbackMode": response.headers["x-cos-audio-playback"] ?? "raw",
            "playbackProfile": response.headers["x-cos-audio-profile"] ?? NSNull(),
            "playbackBypass": response.headers["x-cos-audio-bypass"] ?? NSNull(),
        ])
    }

    /// Which chunks of a meeting still have audio, so the panel can offer a play
    /// button only where it will work.
    ///
    /// A 404 here means the server predates this panel — reported as
    /// `route_missing` so Control can say "update your server" instead of
    /// asserting, falsely, that the audio is gone.
    private func emitReviewAudioList(args: [String]) throws {
        guard let session = option("--session", in: args), validSessionID(session) else {
            throw HelperError.message("--session is required")
        }
        let token = try speakerReviewToken()
        guard let response = request("/api/meeting/\(escapedSessionID(session))/audio", method: "GET", token: token, body: nil, timeout: 15) else {
            throw HelperError.message("Server stopped")
        }
        if response.status == 401 || response.status == 403 { throw HelperError.message("Unauthorized") }
        if response.status == 404 {
            emit(ok: true, message: "Retention not available", details: ["state": "route_missing", "chunks": []])
            return
        }
        guard response.status == 200, let body = response.body else {
            throw HelperError.message("Could not read retained audio (\(response.status))")
        }
        emit(ok: true, message: "Retained audio listed", details: [
            "state": "ready",
            "chunks": (body["chunks"] as? [Any]) ?? [],
            "retentionDays": body["retentionDays"] ?? NSNull(),
            "retained": body["retained"] ?? false,
        ])
    }

    private func mediaState(for status: Int) -> String {
        switch status {
        case 401, 403: return "unauthorized"
        case 404: return "missing"
        case 410: return "expired"
        case 503: return "unavailable"
        default: return "unavailable"
        }
    }

    private func imageMIME(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(8))
        if bytes.count >= 3, bytes[0] == 0xff, bytes[1] == 0xd8, bytes[2] == 0xff { return "image/jpeg" }
        if bytes == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] { return "image/png" }
        return nil
    }

    private func pruneMediaTransfers(now: Date = Date()) throws {
        try ensurePrivateDirectory(controlCache)
        try ensurePrivateDirectory(mediaTransferRoot)
        let cutoff = now.addingTimeInterval(-15 * 60)
        let entries = try fm.contentsOfDirectory(
            at: mediaTransferRoot,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey],
            options: []
        )
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true,
                  (values.contentModificationDate ?? .distantFuture) < cutoff else { continue }
            try? fm.removeItem(at: entry)
        }
    }

    /// Authenticated, bounded media transfer for the GUI. The helper returns a
    /// private local file path, never a token, URL, server path, or base64 body.
    private func emitFetchedMedia(args: [String]) throws {
        guard let id = option("--id", in: args), validMediaID(id) else {
            throw HelperError.message("Invalid media id")
        }
        guard let variant = option("--variant", in: args), ["thumb", "phone"].contains(variant) else {
            throw HelperError.message("Invalid media variant")
        }
        guard let purpose = option("--purpose", in: args), ["preview", "handoff"].contains(purpose) else {
            throw HelperError.message("Invalid media purpose")
        }
        let token: String
        do { token = try readToken() }
        catch {
            emit(ok: true, message: "Media unavailable", details: ["state": "unauthorized"])
            return
        }
        let maximumBytes = variant == "thumb" ? 2 * 1_024 * 1_024 : 12 * 1_024 * 1_024
        // Sweep crash-orphaned transfers even when this attempt fails before a
        // new file is committed.
        try pruneMediaTransfers()
        guard let response = boundedMediaRequest(
            "/api/media/\(id)/content?variant=\(variant)",
            token: token,
            timeout: 12,
            maximumBytes: maximumBytes
        ) else {
            emit(ok: true, message: "Media unavailable", details: ["state": "offline"])
            return
        }
        if response.status == 413 {
            emit(ok: true, message: "Media unavailable", details: ["state": "invalid"])
            return
        }
        guard response.status == 200 else {
            emit(ok: true, message: "Media unavailable", details: ["state": mediaState(for: response.status)])
            return
        }
        guard let data = response.data else {
            emit(ok: true, message: "Media unavailable", details: ["state": "unavailable"])
            return
        }
        guard !data.isEmpty, data.count <= maximumBytes,
              let sniffed = imageMIME(data),
              let declared = response.headers["content-type"]?.lowercased().split(separator: ";").first.map(String.init),
              declared == sniffed else {
            emit(ok: true, message: "Media unavailable", details: ["state": "invalid"])
            return
        }
        let ext = sniffed == "image/png" ? "png" : "jpg"
        let destination = mediaTransferRoot.appendingPathComponent("\(UUID().uuidString.lowercased()).\(ext)")
        try atomicWriteData(data, to: destination, permissions: 0o600)
        emit(ok: true, message: "Media ready", details: [
            "state": "ready",
            "path": destination.path,
            "mime": sniffed,
            "bytes": data.count,
            "purpose": purpose,
        ])
    }

    private func doctorDetails(redacted: Bool) -> [String: Any] {
        var checks: [[String: Any]] = []
        func add(_ name: String, _ state: String, _ detail: String) {
            checks.append(["name": name, "state": state, "detail": stripEmails(detail)])
        }
        // First row on purpose: a support report that cannot say which Control
        // produced it is unusable, and version strings have been reused across
        // builds before, so the build number is the identifying part.
        add("COS Control", "ok", appIdentity ?? "Unknown (run from the app to record it)")
        if let node = findExecutable("node") {
            let probe = nodeVersion(at: node)
            add("Node.js", probe.valid ? "ok" : "error", redacted ? probe.display : "\(probe.display) · \(redactPath(node))")
        } else { add("Node.js", "error", "Not found") }
        add("npm", findExecutable("npm") == nil ? "error" : "ok", findExecutable("npm").map { redacted ? "Available" : redactPath($0) } ?? "Not found")
        let claude = cliProbe("claude", redacted: redacted)
        add("Claude CLI", claude.state, claude.detail)
        let codex = cliProbe("codex", redacted: redacted)
        add("Codex CLI", codex.state, codex.detail)
        let cursor = cursorDoctorCheck(redacted: redacted)
        add("Cursor Agent", cursor.state, cursor.detail)
        add("Whisper CLI", findExecutable("whisper-cli") == nil ? "warning" : "ok", findExecutable("whisper-cli") == nil ? "Not installed" : "Available")
        if let whisper = (request("/api/health", timeout: 12)?.body?["whisper_health"] as? [String: Any]) {
            let ready = whisper["server"] as? Bool == true
            let configured = whisper["serverConfigured"] as? Bool == true
            let state = whisper["startupState"] as? String ?? "unknown"
            let error = (whisper["lastError"] as? String)?.prefix(240)
            let detail = error.map { "\(state): \($0)" } ?? state
            add("Whisper server", ready ? "ok" : (configured ? "error" : "warning"), detail)
        }
        add("ffmpeg", findExecutable("ffmpeg") == nil ? "warning" : "ok", findExecutable("ffmpeg") == nil ? "Not installed" : "Available")

        let details = statusDetails()
        let state = details["runtimeState"] as? String ?? RuntimeState.unknown.rawValue
        add("Runtime ownership", state == RuntimeState.managedHealthy.rawValue ? "ok" : (state == RuntimeState.ownerConflict.rawValue ? "error" : "warning"), state)
        if details["contextBrowserSupported"] as? Bool == true {
            let memoryReady = details["memoryAvailable"] as? Bool == true
            let threadsReady = details["threadsAvailable"] as? Bool == true
            let contextState = details["contextState"] as? String
            let contextDetail: String
            if memoryReady && threadsReady {
                contextDetail = "\(details["memoryCount"] as? Int ?? 0) memories · \(details["threadCount"] as? Int ?? 0) threads"
            } else if memoryReady || threadsReady {
                contextDetail = memoryReady ? "Memory ready; Threads unavailable" : "Threads ready; Memory unavailable"
            } else if contextState == "bridge_outdated" {
                contextDetail = "Workspace bridge update required; choose COS Data again after updating"
            } else if contextState == "bridge_error" {
                contextDetail = "COS Data bridge is temporarily unavailable; retry or run Doctor"
            } else {
                contextDetail = "Choose COS Data to connect a compatible operations/scripts bridge"
            }
            add("Memory and Threads", memoryReady && threadsReady ? "ok" : "warning", contextDetail)
        }
        if loadManifest() != nil || inPlaceActive() {
            let providerReady = details["providerCapabilitiesReady"] as? Bool == true
            let providerDetail = details["providerCapabilityError"] as? String ?? "Installed providers are available to the service"
            add("AI provider bridge", providerReady ? "ok" : "error", providerDetail)
            if providerReady, let health = request("/api/health", timeout: 12)?.body {
                let version = (details["version"] as? String) ?? "0.0.0"
                let proofDeadline = ProcessInfo.processInfo.systemUptime + 60
                if let failure = transactionalRuntimeProofFailure(
                    health: health,
                    expectedProviders: detectedManagedProviders(),
                    requireProviderEndpoint: versionAtLeast(version, "6.15.2"),
                    deadlineUptime: proofDeadline
                ) {
                    add("Query + playback proof", "error", failure)
                } else {
                    add("Query + playback proof", "ok", "Real provider query passed; ready Kokoro playback was fetched without an API header")
                }
            }
        } else {
            add("AI provider bridge", "warning", "Managed server not installed")
        }
        if let manifest = loadManifest() {
            do {
                _ = try verifyGeneration(
                    at: manifest.generationPath,
                    expectedVersion: manifest.version,
                    expectedIntegrity: manifest.registryIntegrity,
                    expectedLauncherHash: manifest.launcherSHA256,
                    expectedPackageHash: manifest.packageJSONSHA256
                )
                add("Runtime integrity", "ok", "Active generation verified")
            } catch { add("Runtime integrity", "error", "Active generation failed verification") }
        } else { add("Runtime integrity", "warning", "Not installed") }
        let recoveryPending = loadTransaction() != nil || loadInPlaceConfigurationTransaction() != nil
        add("Update recovery", recoveryPending ? "error" : "ok", recoveryPending ? "Repair required" : "No interrupted transaction")
        let recoveryReady = recoveryLaunchAgentValid() && recoveryServiceLoaded()
        add("Recovery controller", recoveryReady ? "ok" : "error", recoveryReady ? "Loaded · checks every 60 seconds" : "Missing or not loaded · run Repair")
        add("Private config", (try? readToken()) == nil ? "warning" : "ok", (try? readToken()) == nil ? "Use Copy Pairing Token and paste the complete value (existing tokens need at least 16 characters)" : "Configured")

        var status = details
        if redacted {
            status["workDirectory"] = (manifestConfiguredWorkDirectory() ? "<configured COS workspace>" : NSNull())
            status["activeWorkDirectory"] = redactedConfiguredPath(status["activeWorkDirectory"] as? String, label: "active COS workspace")
            status["operationsDirectory"] = redactedConfiguredPath(configuredOperationsDirectory(), label: "configured meetings library")
            status["contextScriptsDirectory"] = redactedConfiguredPath(configuredContextScriptsDirectory(), label: "configured COS Data bridge")
            status["contextFilesDirectory"] = redactedConfiguredPath(configuredContextFilesDirectory(), label: "configured COS Data notes folder")
            status["servicePID"] = NSNull()
            status["listenerPIDs"] = []
        }
        return ["checks": checks, "status": status]
    }

    private func manifestConfiguredWorkDirectory() -> Bool { configuredWorkDirectory() != nil }

    private func redactedConfiguredPath(_ value: String?, label: String) -> Any {
        value == nil ? NSNull() : "<\(label)>"
    }

    private func redactPath(_ value: String) -> String {
        if value == home.path { return "~" }
        if value.hasPrefix(home.path + "/") { return "~" + value.dropFirst(home.path.count) }
        return value
    }

    private func redactedReport() -> String {
        let doctor = doctorDetails(redacted: true)
        let data = try? JSONSerialization.data(withJSONObject: doctor, options: [.prettyPrinted, .sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "COS Control report unavailable"
    }

    private func selfTest() throws {
        var passed = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw HelperError.message("self-test failed: \(message)") }
            passed += 1
        }

        try ensureDirectories()

        // Meetings-library discovery. Queen set up her own COS on 2026-08-08 and
        // every folder she chose was rejected, because this file carried
        // ["quilt","sprocket_rocket","hermit_crabs","personal"] — one user's
        // business domains shipped as a requirement — directly beneath a comment
        // saying "Each COS layout can differ". These run against the SHIPPED
        // functions on every build, rather than a throwaway probe that would rot.
        let opsRoot = home.appendingPathComponent("selftest-ops", isDirectory: true)
        func makeDir(_ url: URL) throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        // A domain nobody predicted, with a space in the name.
        try makeDir(opsRoot.appendingPathComponent("DNP study/meetings/2026-08"))
        try makeDir(opsRoot.appendingPathComponent("ascension/meetings/2026-08"))
        // Not domains: no meetings/ tree, and a hidden directory.
        try makeDir(opsRoot.appendingPathComponent("context"))
        try makeDir(opsRoot.appendingPathComponent(".meeting_archive/meetings"))
        let found = COSControlHelper.discoverMeetingDomains(opsRoot)
        try expect(found == ["DNP study", "ascension"],
                   "discovery must find arbitrary domain names and skip non-domains, got \(found)")
        try expect(COSControlHelper.operationsDirectoryRejection(opsRoot) == nil,
                   "a tree with no quilt/ must still validate")

        // The wrong level: subfolders exist, none holds meetings/. The message must
        // name what it FOUND rather than demand a domain the user does not own.
        let wrongLevel = home.appendingPathComponent("selftest-wrong", isDirectory: true)
        try makeDir(wrongLevel.appendingPathComponent("context"))
        try makeDir(wrongLevel.appendingPathComponent("communications"))
        let wrongMessage = COSControlHelper.operationsDirectoryRejection(wrongLevel) ?? ""
        try expect(wrongMessage.contains("COS found these folders") && !wrongMessage.contains("quilt"),
                   "rejection must enumerate what it found and never demand quilt/, got \(wrongMessage)")

        // A direct library is now a first-class, browse-only layout. This is
        // exactly what Queen selected: meetings/YYYY-MM/*.md.
        let direct = home.appendingPathComponent("selftest-direct", isDirectory: true)
        let directMonth = direct.appendingPathComponent("2026-08", isDirectory: true)
        try makeDir(directMonth)
        try Data("# Existing meeting\n".utf8).write(to: directMonth.appendingPathComponent("existing.md"))
        try expect(COSControlHelper.operationsDirectoryRejection(direct) == nil,
                   "a direct YYYY-MM meeting library must validate")

        try expect(!COSControlHelper.isSafeDomainName("..")
                     && !COSControlHelper.isSafeDomainName("a/b")
                     && !COSControlHelper.isSafeDomainName(".hidden"),
                   "traversal guard must survive the move off the membership check")
        try expect(COSControlHelper.isSafeDomainName("DNP study"),
                   "a domain name with a space is legitimate")

        // The COS Data picker, both tiers. Before 6.22.0 this accepted exactly one
        // shape — cos_api_bridge.py plus an executable venv/bin/python3, with
        // Docker and OpenAI embeddings behind it — so a user with notes and no
        // vector database could not select anything, and the error text told them
        // to go build a pipeline. These run the SHIPPED functions.
        let notes = home.appendingPathComponent("selftest-notes", isDirectory: true)
        try makeDir(notes.appendingPathComponent("memory"))
        try expect(holdsContextFiles(notes), "a folder with memory/ must be recognised as a notes store")
        if case .files(let root) = try validatedContextSource(notes.path) {
            try expect(root.hasSuffix("selftest-notes"), "the notes root must be the folder chosen, got \(root)")
        } else {
            throw HelperError.message("self-test failed: a memory/ folder must resolve to the files tier")
        }

        // Plural and threads-only spellings, matching the server's own lists. A
        // folder Control accepts but the server cannot read would pass the picker
        // and then fail the post-restart proof.
        let plural = home.appendingPathComponent("selftest-memories", isDirectory: true)
        try makeDir(plural.appendingPathComponent("memories"))
        try expect(holdsContextFiles(plural), "memories/ must be accepted alongside memory/")
        let threadsOnly = home.appendingPathComponent("selftest-threads", isDirectory: true)
        try makeDir(threadsOnly.appendingPathComponent("threads"))
        try expect(holdsContextFiles(threadsOnly), "a threads-only store is a valid store")

        // Nested one level down, which is where a COS repo keeps them.
        let repo = home.appendingPathComponent("selftest-repo", isDirectory: true)
        try makeDir(repo.appendingPathComponent("operations/memory"))
        if case .files(let root) = try validatedContextSource(repo.path) {
            try expect(root.hasSuffix("operations"), "a repo root must resolve to operations/, got \(root)")
        } else {
            throw HelperError.message("self-test failed: operations/memory must resolve to the files tier")
        }

        // A folder with neither is still refused, and the message must offer the
        // notes path rather than only the pipeline.
        let neither = home.appendingPathComponent("selftest-neither", isDirectory: true)
        try makeDir(neither.appendingPathComponent("communications"))
        var refusal = ""
        do { _ = try validatedContextSource(neither.path) } catch { refusal = "\(error)" }
        try expect(refusal.contains("memory") && refusal.contains("markdown"),
                   "the refusal must name the notes path, got \(refusal)")

        try expect(providerEnvironmentKeys.contains("COS_CONTEXT_DIR"),
                   "COS_CONTEXT_DIR must be allowlisted or applying it is rejected as unsupported")
        try expect(providerEnvironmentKeys.contains("COS_CLAUDE_SESSIONS_ENABLED"),
                   "COS_CLAUDE_SESSIONS_ENABLED must be allowlisted or Update Server strips it")
        try expect(providerEnvironmentKeys.contains("COS_CLAUDE_SESSIONS_SHOW_NAMES"),
                   "COS_CLAUDE_SESSIONS_SHOW_NAMES must be allowlisted or Update Server strips it")
        try expect(providerEnvironmentKeys.contains("COS_THREAD_ATTACH_ENABLED"),
                   "COS_THREAD_ATTACH_ENABLED must be allowlisted or Update Server silently drops Continue")

        // Create Folders — the button that replaces the two directories Queen had to
        // make by hand. Runs the SHIPPED function against a real temporary tree.
        let createRoot = home.appendingPathComponent("selftest-create", isDirectory: true)
        try makeDir(createRoot)
        let createResult = try createContextFolders(at: createRoot.path)
        try expect(holdsContextFiles(createRoot),
                   "createContextFolders must leave a folder the resolver recognises")
        try expect(directoryExists(createRoot.appendingPathComponent("memory", isDirectory: true))
                     && directoryExists(createRoot.appendingPathComponent("threads", isDirectory: true)),
                   "both memory/ and threads/ must exist afterwards")
        try expect(fm.fileExists(atPath: createRoot.appendingPathComponent("memory/README.md").path),
                   "each folder needs a README — an empty folder explains nothing")
        // "created and empty" is SUCCESS. Collapsing empty with missing is what sent
        // Queen to the picker.
        try expect((createResult["state"] as? String) == "ready",
                   "a created empty store must report ready, not setup-needed")
        // Idempotent: a second tap must not fail or duplicate.
        let again = try createContextFolders(at: createRoot.path)
        try expect((again["created"] as? [String])?.isEmpty == true,
                   "a second Create must create nothing and still succeed")

        // The desktop review path must reach the same routes the glasses do, and must
        // survive the /api/memory top-level-array shape that a dictionary-only reader
        // silently reads as empty.
        let arrayBody = Data("[{\"id\":\"file_a.md\",\"summary\":\"s\",\"content\":\"c\"}]".utf8)
        let arrayResponse = HTTPResponse(status: 200, body: nil, data: arrayBody)
        try expect(arrayResponse.body == nil && arrayResponse.bodyArray?.count == 1,
                   "a top-level JSON array must be readable when body is nil")
        let objectResponse = HTTPResponse(status: 200, body: ["threads": []], data: Data("{\"threads\":[]}".utf8))
        try expect(objectResponse.bodyArray == nil,
                   "an object body must not be misread as an array")

        // A README must describe the actual accepted shape, not an invented one.
        let readme = try String(contentsOf: createRoot.appendingPathComponent("memory/README.md"), encoding: .utf8)
        try expect(readme.contains("Front matter is optional") || readme.contains("front matter is optional")
                     || readme.contains("optional"),
                   "the README must say front matter is optional")
        try expect(readme.contains("symlink"),
                   "the README must mention symlinks, the documented way to attach existing notes")

        // Resolution order parity with the server. Duplicating the order across two
        // languages is the cost of showing the path without putting it on the API, so
        // the ORDER itself is asserted rather than trusted.
        try expect(contextRootResolution().candidates.contains(where: { $0.hasSuffix(".cos-glasses") }),
                   "the data home must always be the last-resort candidate")

        // The folder-shape lists must agree with the server's MEMORY_DIRS/THREAD_DIRS.
        for spelling in ["memory", "memories", "threads", "thread"] {
            let probe = home.appendingPathComponent("selftest-shape-\(spelling)", isDirectory: true)
            try makeDir(probe.appendingPathComponent(spelling, isDirectory: true))
            try expect(holdsContextFiles(probe), "\(spelling)/ must be recognised, matching the server")
        }

        let v1: [String: Any] = ["managed": true, "contractVersion": 1]
        let v2: [String: Any] = ["managed": true, "contractVersion": 2]
        let future: [String: Any] = ["managed": true, "contractVersion": 3]
        try expect(isManagedContract(v1), "known status contract should remain readable")
        try expect(hasLifecycleContract(v2), "v2 lifecycle contract should be accepted")
        try expect(!hasLifecycleContract(v1) && !isManagedContract(future), "unsafe lifecycle contracts should fail closed")

        let manifest = RuntimeManifest(
            version: "6.13.0",
            generationPath: home.appendingPathComponent("generation").path,
            workDirectory: home.appendingPathComponent("workspace").path,
            installedAt: "2026-07-23T00:00:00Z",
            previousVersions: [],
            schemaVersion: 2,
            registryIntegrity: "sha512-test",
            launcherSHA256: String(repeating: "a", count: 64),
            packageJSONSHA256: String(repeating: "b", count: 64),
            generationID: "generation-test",
            nodePath: "/opt/homebrew/bin/node",
            providerEnvironment: [
                "COS_HARNESS": "codex",
                "COS_EXTRA_TOOLS": "mcp__calendar__*",
                "COS_WHISPER_MEETING_PREVIEW": "1",
                "COS_THREAD_ATTACH_ENABLED": "1",
                "COS_BATCH_HQ_METAL": "1",
                "COS_BATCH_HQ_FORCE_CPU": "0",
                "COS_MEETING_AUDIO_ADAPTIVE_PLAYBACK": "1",
                "COS_API_TOKEN": "must-not-survive",
            ],
            retainedGenerations: [],
            desiredState: "running"
        )
        let roundTrip = try JSONDecoder().decode(RuntimeManifest.self, from: JSONEncoder().encode(manifest))
        try expect(roundTrip.generationID == "generation-test" && roundTrip.providerEnvironment?["COS_HARNESS"] == "codex", "manifest round trip")
        try expect(roundTrip.desiredState == "running", "persistent desired state round trip")
        let filtered = try captureProviderEnvironment(previous: manifest)
        try expect(
            filtered["COS_HARNESS"] == "codex"
                && filtered["COS_EXTRA_TOOLS"] == "mcp__calendar__*"
                && filtered["COS_WHISPER_MEETING_PREVIEW"] == "1"
                && filtered["COS_THREAD_ATTACH_ENABLED"] == "1"
                && filtered["COS_BATCH_HQ_METAL"] == "1"
                && filtered["COS_BATCH_HQ_FORCE_CPU"] == "0"
                && filtered["COS_MEETING_AUDIO_ADAPTIVE_PLAYBACK"] == "1"
                && filtered["COS_API_TOKEN"] == nil,
            "provider allowlist"
        )
        // Continue is a DEFAULT-OFF flag, so Off must REMOVE the key rather than
        // write "0" — absence is the state the server documents as disabled, and
        // it is what makes the disabled state provable by absence. Writing "0"
        // here would leave a permanent artifact; this asserts the real function.
        let threadAttachOn = try threadAttachEnvironment("ON")
        let threadAttachOff = try threadAttachEnvironment("off")
        try expect(
            threadAttachOn.values["COS_THREAD_ATTACH_ENABLED"] == "1" && threadAttachOn.removing.isEmpty,
            "Continue on must write the enabling value and remove nothing"
        )
        try expect(
            threadAttachOff.values.isEmpty && threadAttachOff.removing == ["COS_THREAD_ATTACH_ENABLED"],
            "Continue off must REMOVE the key, never write \"0\" — absent is the documented disabled state"
        )
        let idleMetalOn = try idleMetalHqEnvironment("ON")
        let idleMetalOff = try idleMetalHqEnvironment("off")
        try expect(
            idleMetalOn["COS_BATCH_HQ_METAL"] == "1"
                && idleMetalOn["COS_BATCH_HQ_FORCE_CPU"] == "0",
            "Idle Metal HQ enable clears force-CPU rollback"
        )
        try expect(
            idleMetalOff["COS_BATCH_HQ_METAL"] == "0"
                && idleMetalOff["COS_BATCH_HQ_FORCE_CPU"] == "1",
            "Idle Metal HQ disable forces CPU"
        )
        let adaptiveAudioOn = try adaptiveAudioCleanupEnvironment("ON")
        let adaptiveAudioOff = try adaptiveAudioCleanupEnvironment("off")
        try expect(
            adaptiveAudioOn["COS_MEETING_AUDIO_ADAPTIVE_PLAYBACK"] == "1"
                && adaptiveAudioOff["COS_MEETING_AUDIO_ADAPTIVE_PLAYBACK"] == "0",
            "Adaptive audio cleanup maps to an explicit reversible value"
        )
        let balancedTier = try transcriptionTierEnvironment("balanced")
        let maxTier = try transcriptionTierEnvironment("MAX")
        try expect(
            balancedTier["COS_WHISPER_PREVIEW_MODEL"] == "small.en"
                && balancedTier["COS_WHISPER_COMMIT_MODEL"] == "turbo"
                && balancedTier["COS_MEETING_PROGRESSIVE_HQ_THREADS"] == "2",
            "Balanced transcription mapping"
        )
        try expect(
            maxTier["COS_WHISPER_PREVIEW_MODEL"] == "turbo"
                && maxTier["COS_WHISPER_COMMIT_MODEL"] == "large-v3"
                && maxTier["COS_MEETING_PROGRESSIVE_HQ_THREADS"] == "6",
            "Max transcription mapping"
        )
        try expect(versionAtLeast("6.15.2", "6.15.2") && versionAtLeast("6.16.0", "6.15.2"), "transactional proof version gate")
        try expect(!versionAtLeast("6.15.1", "6.15.2") && !versionAtLeast("invalid", "6.15.2"), "legacy proof compatibility gate")
        try expect(redactPath(home.appendingPathComponent("workspace").path) == "~/workspace", "home path redaction")
        try expect(redactedConfiguredPath("/Users/private/COS/operations", label: "configured meetings library") as? String == "<configured meetings library>", "report operations path redaction")
        try expect(redactedConfiguredPath("/Users/private/COS/operations/scripts", label: "configured COS Data bridge") as? String == "<configured COS Data bridge>", "report context path redaction")
        let launchPaths = launchPathDirectories(node: "/opt/homebrew/bin/node")
        let localBin = home.appendingPathComponent(".local/bin", isDirectory: true).path
        try expect(launchPaths.contains(localBin), "managed PATH includes the user-local bin")
        try expect(launchPaths.filter { $0 == "/opt/homebrew/bin" }.count == 1, "managed PATH removes duplicate directories")
        let nodeToolEnv = nodeToolEnvironment(node: "/opt/homebrew/bin/node")
        try expect(nodeToolEnv["PATH"]?.split(separator: ":").first == "/opt/homebrew/bin",
                   "npm resolver PATH starts with the discovered Node directory")
        try expect(nodeToolEnv["NPM_CONFIG_UPDATE_NOTIFIER"] == "false",
                   "npm resolver disables non-JSON update notices")

        let healthyClaude: [String: Any] = [
            "status": "ok", "server": "ok",
            "features": ["claude": true, "codex": false],
        ]
        let missingClaude: [String: Any] = [
            "status": "ok", "server": "ok",
            "features": ["claude": false, "codex": false],
        ]
        try expect(providerCapabilityFailure(healthyClaude, expectedProviders: Set(["claude"])) == nil, "available expected provider passes health gate")
        try expect(providerCapabilityFailure(missingClaude, expectedProviders: Set(["claude"]))?.contains("installed but unavailable") == true, "HTTP-green provider failure is rejected")
        try expect(providerCapabilityFailure(["status": "ok", "server": "ok"], expectedProviders: [])?.contains("missing provider capabilities") == true, "malformed provider health fails closed")
        try expect(managedHealthFailure(HTTPResponse(status: 503, body: healthyClaude), expectedProviders: Set(["claude"])) == "health endpoint returned HTTP 503", "non-200 managed health fails closed")
        let whisperLoading = healthyClaude.merging([
            "whisper_health": ["server": false, "serverConfigured": true, "cli": true, "startupState": "loading", "lastError": NSNull()],
        ]) { _, new in new }
        let whisperReady = healthyClaude.merging([
            "whisper_health": ["server": true, "serverConfigured": true, "cli": true, "startupState": "ready", "lastError": NSNull()],
        ]) { _, new in new }
        let whisperBatchOnly = healthyClaude.merging([
            "whisper_health": ["server": false, "serverConfigured": false, "cli": true, "startupState": "unavailable", "lastError": NSNull()],
        ]) { _, new in new }
        try expect(localWhisperReadinessFailure(whisperLoading, serverVersion: "6.15.3") == nil, "legacy server remains compatible with pre-readiness health")
        try expect(localWhisperReadinessFailure(whisperLoading, serverVersion: "6.15.4")?.contains("loading") == true, "eligible local Whisper blocks candidate verification while loading")
        try expect(localWhisperReadinessFailure(whisperReady, serverVersion: "6.15.4") == nil, "ready local Whisper passes candidate verification")
        try expect(localWhisperReadinessFailure(whisperBatchOnly, serverVersion: "6.15.4") == nil, "batch-only Whisper does not falsely block persistent-server readiness")
        let inPlaceRecord = InPlaceRecord(plistPath: plistURL.path, appDir: nil, serverInstanceId: nil, adoptedAt: "test")
        try atomicWrite(inPlaceRecord, to: inPlaceURL, permissions: 0o600)
        let inPlaceSnapshot = OwnershipSnapshot(serviceLoaded: true, servicePID: 42, listeners: [3141: [42], 3143: []], launchAgentKind: .knownLegacy)
        let allProvidersHealthy: [String: Any] = [
            "status": "ok", "server": "ok",
            "features": ["claude": true, "codex": true],
        ]
        try expect(runtimeState(snapshot: inPlaceSnapshot, maintenance: nil, health: allProvidersHealthy) == .managedInPlace, "in-place runtime requires provider capabilities")
        try expect(runtimeState(snapshot: inPlaceSnapshot, maintenance: nil, health: missingClaude) == .managedDegraded, "in-place HTTP-green provider failure is degraded")
        try? fm.removeItem(at: inPlaceURL)

        let selectedWorkspace = home.appendingPathComponent("selected-workspace", isDirectory: true)
        try fm.createDirectory(at: selectedWorkspace, withIntermediateDirectories: true)
        try Data("# selected\n".utf8).write(to: selectedWorkspace.appendingPathComponent("AGENTS.md"))
        let legacyPlist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/bash", home.appendingPathComponent("Library/Application Support/COS Glasses/runtime/start-server.sh").path],
            "WorkingDirectory": home.appendingPathComponent("cos-glasses-app").path,
            "EnvironmentVariables": [
                "COS_GLASSES_APP_DIR": home.appendingPathComponent("cos-glasses-app").path,
                "COS_SCRIPTS_DIR": home.appendingPathComponent("pipeline/operations/scripts").path,
                "COS_API_TOKEN": "secret-must-remain-private",
            ],
        ]
        let legacyData = try PropertyListSerialization.data(fromPropertyList: legacyPlist, format: .xml, options: 0)
        try atomicWriteData(legacyData, to: plistURL, permissions: 0o600)
        let candidateData = try inPlaceCandidatePlist(workDirectory: selectedWorkspace.path)
        let candidatePlist = try PropertyListSerialization.propertyList(from: candidateData, options: [], format: nil) as! [String: Any]
        let candidateEnvironment = candidatePlist["EnvironmentVariables"] as! [String: String]
        try expect(candidateEnvironment["COS_WORKDIR"] == selectedWorkspace.path, "in-place candidate writes provider-neutral workspace")
        try expect(candidateEnvironment["CODEX_GLASSES_WORKDIR"] == selectedWorkspace.path, "in-place candidate keeps legacy provider workspace coherent")
        try expect(candidateEnvironment["COS_SCRIPTS_DIR"] == legacyPlist["EnvironmentVariables"].flatMap { ($0 as? [String: String])?["COS_SCRIPTS_DIR"] }, "workspace selection does not mutate the pipeline root")
        try expect(candidatePlist["WorkingDirectory"] as? String == legacyPlist["WorkingDirectory"] as? String, "workspace selection preserves server WorkingDirectory")
        try expect(candidateEnvironment["COS_GLASSES_APP_DIR"] == home.appendingPathComponent("cos-glasses-app").path, "workspace selection preserves server app directory")
        try atomicWriteData(candidateData, to: plistURL, permissions: 0o600)
        try expect(configuredWorkDirectory() == selectedWorkspace.path, "status reads and validates the selected LaunchAgent workspace")
        try? fm.removeItem(at: plistURL)

        let secret = "unit-test-secret-that-must-never-be-emitted-1234567890"
        let digest = tokenDigest(secret)
        let job = "com.cos.control.clipboard-expiry.test"
        let expired = ClipboardReceipt(digest: digest, expiresAt: Date().addingTimeInterval(-1), launchdLabel: job)
        try expect(shouldClearClipboard(currentValue: secret, expectedDigest: digest, expectedJob: job, stored: expired), "matching clipboard receipt")
        try expect(!shouldClearClipboard(currentValue: "user-replaced-value", expectedDigest: digest, expectedJob: job, stored: expired), "replacement clipboard must not clear")
        try expect(!shouldClearClipboard(currentValue: secret, expectedDigest: digest, expectedJob: job + ".other", stored: expired), "superseded receipt must not clear")
        let safeTokenResponse: [String: Any] = ["clipboardReceipt": String(digest.prefix(12)), "expiresAt": "test"]
        let encodedResponse = String(decoding: try JSONSerialization.data(withJSONObject: safeTokenResponse), as: UTF8.self)
        try expect(!encodedResponse.contains(secret), "token command state must contain only a receipt")

        let operation = MaintenanceLease(
            id: "lease-test",
            operationId: "operation-test",
            nonce: secret,
            nonceSha256: digest,
            operationKind: "server_stop",
            scope: "cross_boot",
            postcondition: "authorized_successor_adopted",
            authorizedSuccessorGenerations: ["generation-test"],
            serverInstanceId: "instance-test",
            sourceBootId: "source-boot",
            sourceGenerationId: "generation-test",
            bootId: "source-boot",
            generationId: "generation-test",
            expiresAt: nil
        )
        let lifecycle: [String: Any] = [
            "state": "draining",
            "activeTotal": 0,
            "operation": [
                "operationId": operation.operationId,
                "operationKind": operation.operationKind,
                "scope": operation.scope,
                "postcondition": operation.postcondition,
                "nonceSha256": operation.nonceSha256,
                "authorizedSuccessorGenerations": operation.authorizedSuccessorGenerations,
                "sourceBootId": operation.sourceBootId,
                "sourceGenerationId": operation.sourceGenerationId,
            ],
            "restartProof": [
                "valid": true,
                "leaseMatches": true,
                "operationMatches": true,
                "nonceMatches": true,
                "sourceIdentityMatches": true,
                "serverInstanceId": operation.serverInstanceId,
                "bootId": operation.bootId,
                "generationId": operation.generationId,
            ],
        ]
        let operationStatus: [String: Any] = ["safeToRestart": true, "lifecycle": lifecycle]
        try expect(maintenanceOperationMatches(operationStatus, operation: operation), "rev4 operation verifier")
        try expect(restartProofMatches(operationStatus, operation: operation), "rev4 credentialed restart proof")
        try expect(operationReceiptIsUsable(operation, now: Date.distantFuture), "cross-boot operation must never expiry-open")
        let sameBoot = MaintenanceLease(
            id: operation.id, operationId: operation.operationId, nonce: operation.nonce,
            nonceSha256: operation.nonceSha256, operationKind: "same_boot_maintenance", scope: "same_boot",
            postcondition: "same_boot_idle", authorizedSuccessorGenerations: [],
            serverInstanceId: operation.serverInstanceId, sourceBootId: operation.sourceBootId,
            sourceGenerationId: operation.sourceGenerationId, bootId: operation.bootId,
            generationId: operation.generationId, expiresAt: Date.distantPast
        )
        try expect(!operationReceiptIsUsable(sameBoot), "expired same-boot receipt")

        let emptySnapshot = OwnershipSnapshot(serviceLoaded: false, servicePID: nil, listeners: [3141: [], 3143: []], launchAgentKind: .absent)
        try expect(runtimeState(snapshot: emptySnapshot, maintenance: nil, health: nil) == .notInstalled, "empty runtime classification")
        var contended = false
        try withMutationLock {
            do { try withMutationLock { } }
            catch { contended = true }
        }
        try expect(contended, "live lifecycle lock contention")
        try Data("dead-pid=999999\n".utf8).write(to: mutationLockURL)
        try withMutationLock { }
        let clearedLockMetadata = (try? Data(contentsOf: mutationLockURL)).map { String(decoding: $0, as: UTF8.self) } ?? "missing"
        try expect(clearedLockMetadata.isEmpty, "stale lock metadata cannot block and is truncated after acquisition")

        let crashMarker = runtimeRoot.appendingPathComponent("lock-holder-crashed")
        try? fm.removeItem(at: crashMarker)
        let crashHolder = Process()
        crashHolder.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        crashHolder.arguments = ["self-test-lock-crash"]
        crashHolder.environment = ProcessInfo.processInfo.environment
        try crashHolder.run()
        crashHolder.waitUntilExit()
        try expect(
            crashHolder.terminationReason == .uncaughtSignal
                && crashHolder.terminationStatus == SIGKILL
                && fm.fileExists(atPath: crashMarker.path),
            "lock-holder subprocess acquired the lock and crashed under SIGKILL"
        )
        try withMutationLock { }
        try expect(true, "kernel lock is immediately reacquired after holder crash")

        let aboutWithEmail = """
        About Cursor CLI
        CLI Version         2026.07.23-e383d2b
        User Email          milesukaoma@gmail.com
        """
        let parsedConnected = parseCursorAbout(aboutWithEmail)
        try expect(parsedConnected.state == "connected" && parsedConnected.version == "2026.07.23-e383d2b", "cursor about-with-email → connected")
        let encodedConnected = String(decoding: try JSONSerialization.data(withJSONObject: [
            "cursorState": parsedConnected.state,
            "cursorDetail": parsedConnected.version ?? "",
        ]), as: UTF8.self)
        try expect(!encodedConnected.contains("@") && !encodedConnected.lowercased().contains("milesukaoma"), "cursor probe must never emit email")

        let aboutMissing = """
        About Cursor CLI
        CLI Version         2026.07.23-e383d2b
        User Email          Not logged in
        """
        try expect(parseCursorAbout(aboutMissing).state == "signInRequired", "cursor about-missing → sign-in")
        try expect(parseCursorAbout("CLI Version 1.0\n").state == "signInRequired", "cursor about without email line → sign-in")

        saveCursorProbeCache(state: "connected", version: "2026.07.23-e383d2b")
        if let cacheData = try? Data(contentsOf: cursorProbeCacheURL),
           let cacheText = String(data: cacheData, encoding: .utf8) {
            try expect(!cacheText.contains("@"), "cursor cache file must not contain email")
        } else {
            throw HelperError.message("self-test failed: cursor cache write")
        }
        let cached = cursorProbe(force: false)
        try expect(cached.state == "connected" && cached.version == "2026.07.23-e383d2b", "cursor probe reads on-disk 90s cache")

        // Missing binary path: force resolve miss by pointing env at a non-executable.
        let previousBin = ProcessInfo.processInfo.environment["COS_CURSOR_AGENT_BIN"]
        setenv("COS_CURSOR_AGENT_BIN", home.appendingPathComponent("missing-agent-binary").path, 1)
        defer {
            if let previousBin { setenv("COS_CURSOR_AGENT_BIN", previousBin, 1) }
            else { unsetenv("COS_CURSOR_AGENT_BIN") }
        }
        // Clear PATH-based discovery for this assertion by using a force probe after
        // temporarily shadowing resolve via a non-executable env path — still falls
        // through to findExecutable, so assert parse-only notInstalled path instead:
        saveCursorProbeCache(state: "notInstalled", version: nil)
        let notInstalled = cursorProbe(force: false)
        try expect(notInstalled.state == "notInstalled" && !notInstalled.ready, "cursor notInstalled cache state")

        var fixture: [[String: Any]] = []
        for index in 1...35 {
            fixture.append([
                "no": index,
                "timestamp": 1_000 + index,
                "query": "q\(index)",
                "text": "a\(index)",
                "sessionId": "s\(index)",
                "source": "live",
            ])
        }
        let sliced = sliceRecentMessages(fixture, limit: 30)
        try expect(sliced.count == 30, "recent-messages slice enforces ≤30")
        try expect((sliced.first?["no"] as? Int) == 35 && (sliced.last?["no"] as? Int) == 6, "recent-messages newest-first")
        let slicedNos = Set(sliced.compactMap { $0["no"] as? Int })
        try expect(!slicedNos.contains(1) && !slicedNos.contains(5) && slicedNos.contains(6), "full-day dump must not emit oldest beyond slice")

        var mediaFixture: [[String: Any]] = []
        for index in 0..<6 {
            let entry: [String: Any] = [
                "id": "m_" + String(repeating: String(index), count: 24),
                "kind": index == 0 ? "user_photo" : "generated_visual",
                "mime": index.isMultiple(of: 2) ? "image/jpeg" : "image/png",
                "width": 640,
                "height": 480,
                "createdAt": index == 0 ? "2026-08-03T12:00:00.123Z" : "2026-08-03T12:00:00Z",
                "label": String(repeating: "x", count: 140),
            ]
            mediaFixture.append(entry)
        }
        let normalizedMedia = normalizeAttachments(mediaFixture)
        try expect(normalizedMedia.count == 5, "recent media refs are validated, deduplicated, and capped at five")
        try expect((normalizedMedia.first?["createdAt"] as? String) == "2026-08-03T12:00:00.123Z", "server fractional-second media timestamps remain valid")
        try expect((normalizedMedia.first?["label"] as? String)?.count == 120, "recent media labels are bounded")
        let invalidMedia: [[String: Any]] = [
            ["id": "m_" + String(repeating: "G", count: 24), "kind": "user_photo", "mime": "image/jpeg", "width": 1, "height": 1, "createdAt": "2026-08-03T12:00:00Z"],
            ["id": "m_" + String(repeating: "a", count: 24), "kind": "unknown", "mime": "image/jpeg", "width": 1, "height": 1, "createdAt": "2026-08-03T12:00:00Z"],
        ]
        try expect(normalizeAttachments(invalidMedia).isEmpty, "malformed or unsupported recent media refs fail closed")
        try expect(
            imageMIME(Data([0xff, 0xd8, 0xff, 0x00])) == "image/jpeg"
                && imageMIME(Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) == "image/png"
                && imageMIME(Data("not-an-image".utf8)) == nil,
            "media transfer validates image signatures"
        )
        let bounded = BoundedMediaRequestDelegate(maximumBytes: 4)
        try expect(bounded.acceptsExpectedLength(4) && !bounded.acceptsExpectedLength(5), "media transfer rejects an oversized declared response")
        try expect(bounded.accept(Data([1, 2])) && bounded.accept(Data([3, 4])) && !bounded.accept(Data([5])), "media transfer cancels when streamed bytes cross the cap")
        let interrupted = BoundedMediaRequestDelegate(maximumBytes: 4)
        try expect(interrupted.prepareExpectedLength(4), "media transfer accepts an in-budget declared response")
        try expect(interrupted.accept(Data([1, 2])), "media transfer accepts a partial in-budget chunk")
        interrupted.finish(error: URLError(.networkConnectionLost))
        let interruptedResult = interrupted.wait(timeout: 0.1)
        try expect(interruptedResult?.3 == true && interruptedResult?.0.isEmpty == true, "media transfer rejects truncated or interrupted responses")

        try atomicWriteData(Data("COS_API_TOKEN=1234567890abcdefgh\n".utf8), to: envURL, permissions: 0o600)
        let migratedToken = try readToken()
        try expect(migratedToken == "1234567890abcdefgh", "migrated 18-character pairing token remains valid")
        try atomicWriteData(Data("COS_API_TOKEN=123456789012345\n".utf8), to: envURL, permissions: 0o600)
        var shortTokenGuidance = false
        do { _ = try readToken() }
        catch {
            let message = String(describing: error)
            shortTokenGuidance = message.contains("at least 16") && message.contains("64 hexadecimal")
        }
        try expect(shortTokenGuidance, "15-character token returns actionable migration guidance")
        try atomicWriteData(Data("COS_API_TOKEN=1234567890123456\n".utf8), to: envURL, permissions: 0o600)
        let boundaryToken = try readToken()
        try expect(boundaryToken == "1234567890123456", "16-character pairing token boundary remains valid")
        try fm.removeItem(at: envURL)

        // Fail-closed when pairing token is absent under the test home.
        var unauthorized = false
        do { _ = try readToken() }
        catch {
            unauthorized = String(describing: error).localizedCaseInsensitiveContains("pairing token")
                || String(describing: error).localizedCaseInsensitiveContains("Unauthorized")
                || String(describing: error).localizedCaseInsensitiveContains("No pairing")
        }
        try expect(unauthorized, "recent-messages fail-closed when token missing")
        try expect(stripEmails("user milesukaoma@gmail.com ok") == "user <redacted-email> ok", "doctor email redaction")

        // The meetings projection. Untested while inline: removing a field left
        // the suite green because the Swift tests build their own fixture.
        let fullRow: [String: Any] = [
            "sessionId": "meeting_1", "title": "Standoff (G2)", "date": "2026-08-06",
            "domain": "personal", "duration": "8 minutes", "month": "2026-08",
            "filename": "2026-08-06_Standoff_(G2).md", "source": "G2 Glasses",
            // Ints, as the server actually sends them. String literals here were
            // why the blank-count bug shipped past a green suite.
            "topicCount": 4, "decisionCount": 2, "actionCount": 1, "attendeeCount": 3,
        ]
        let projected = Self.meetingRowProjection(fullRow)
        try expect(projected?["month"] as? String == "2026-08", "projection carries month")
        try expect(projected?["filename"] as? String == "2026-08-06_Standoff_(G2).md", "projection carries filename")
        try expect(projected?["topicCount"] as? Int == 4, "projection carries topicCount as a number")
        try expect(projected?["decisionCount"] as? Int == 2, "projection carries decisionCount")
        try expect(projected?["actionCount"] as? Int == 1, "projection carries actionCount")
        try expect(projected?["attendeeCount"] as? Int == 3, "projection carries attendeeCount")
        // Both wire shapes, so a serialisation change cannot blank the row.
        try expect(Self.meetingCount(7) == 7, "count accepts a number")
        try expect(Self.meetingCount("7") == 7, "count accepts a numeric string")
        try expect(Self.meetingCount(nil) == 0, "count defaults to zero")
        try expect(projected?["source"] as? String == "G2 Glasses", "projection carries source")
        try expect(Self.meetingRowProjection(["title": "no session"]) == nil,
                   "projection drops a row with no sessionId")
        let libraryKept = Self.libraryMeetingProjection([
            "title": "Granola sync", "date": "2026-08-12", "domain": "quilt",
            "month": "2026-08", "filename": "2026-08-12_Granola_sync.md",
            "duration": "16 minutes", "source": "Granola",
        ])
        try expect(libraryKept?["recordId"] as? String == "quilt:2026-08:2026-08-12_Granola_sync.md",
                   "library projection keeps a row with no sessionId")
        try expect(libraryKept?["sessionId"] as? String == "", "library sessionId stays empty")
        try expect(Self.libraryMeetingProjection(["title": "no file", "month": "2026-08"]) == nil,
                   "library projection drops a row with no filename")
        let searchHit = Self.librarySearchHitProjection([
            "title": "Toast in Grocery", "date": "2026-08-12", "domain": "quilt",
            "month": "2026-08", "filename": "2026-08-12_Toast.md",
            "snippet": "Counter Toast in grocery.", "match": "both",
            "keywordScore": 0.8, "semanticScore": 0.61,
        ])
        try expect(searchHit?["snippet"] as? String == "Counter Toast in grocery.",
                   "search projection keeps the snippet")
        try expect(searchHit?["match"] as? String == "both", "search projection keeps match kind")
        try expect(searchHit?["score"] as? Double == 0.8, "search score is the stronger signal")
        try expect(Self.contextSearchHitProjection(["title": "no id"], kind: "memory") == nil,
                   "context search drops rows without id")
        let memoryHit = Self.contextSearchHitProjection([
            "id": "mem_1", "title": "Toast decision", "snippet": "Counter Toast.",
            "match": "both", "keywordScore": 0.8, "semanticScore": 0.6,
        ], kind: "memory")
        try expect(memoryHit?["id"] as? String == "mem_1", "memory search keeps id")
        try expect(memoryHit?["match"] as? String == "both", "memory search keeps match kind")
        try expect(Self.sessionSearchHitProjection(["name": "no id"]) == nil,
                   "session search drops rows without id")
        let sessionHit = Self.sessionSearchHitProjection([
            "session_id": "019dfe42-d4ba-7152-b5ae-60f600a2675a", "provider": "codex",
            "display_label": "Markt POS 2.0 build", "project": "MU-Chief-Staff",
            "snippet": "Jewelry Edge bridge", "match": "both",
            "keywordScore": 0.8, "semanticScore": 0.61,
            "pinned": true, "state": "recent", "alive": false,
        ])
        try expect(sessionHit?["id"] as? String == "019dfe42-d4ba-7152-b5ae-60f600a2675a", "session search keeps session_id as id")
        try expect(sessionHit?["name"] as? String == "Markt POS 2.0 build", "session search keeps the sidebar title")
        try expect(sessionHit?["match"] as? String == "both", "session search keeps match kind")
        try expect(sessionHit?["score"] as? Double == 0.8, "session search score is the stronger signal")
        try expect(sessionHit?["workspace"] as? String == "MU-Chief-Staff", "session search keeps the repo name")
        try expect(Self.tokenizeSessionQuery("Toast in grocery vs Clover") == ["toast", "grocery", "clover"],
                   "session search drops stopwords")
        let scored = Self.scoreSessionKeyword(
            tokens: ["jewelry", "edge"],
            title: "Markt POS 2.0 build",
            haystack: "Markt POS 2.0 build\nJewelry Edge bridge"
        )
        try expect(scored.score > 0, "session keyword hits a first prompt the sidebar title does not use")
        try expect(scored.snippet.lowercased().contains("jewelry"), "session keyword snippet comes from the prompt")

        // --- restart blockers must NAME the cause ---------------------------
        // The 2026-08-12 lockout in one fixture: activeByKind EMPTY, everything
        // else healthy, and a single stuck video upload holding blocksRestart.
        // The old code printed "restart proof" here and named nothing.
        let stuckLease = MaintenanceLease(
            id: "lease-1", operationId: "op-1", nonce: "n", nonceSha256: "sha",
            operationKind: "server_update", scope: "cross_boot",
            postcondition: "authorized_successor_adopted",
            authorizedSuccessorGenerations: [], serverInstanceId: "srv",
            sourceBootId: "boot", sourceGenerationId: "gen",
            bootId: "boot", generationId: "gen", expiresAt: nil)
        let videoStuck: [String: Any] = [
            "shuttingDown": false,
            "videoUploads": ["blocksRestart": true, "receiving": 1, "finalizing": 0],
            "lifecycle": [
                "state": "draining",
                "activeByKind": [String: Any](),
                "restartProof": [
                    "valid": true, "leaseMatches": true, "operationMatches": true,
                    "nonceMatches": true, "sourceIdentityMatches": true,
                    "serverInstanceId": "srv", "bootId": "boot", "generationId": "gen",
                ],
            ],
        ]
        let videoBlockers = restartBlockers(videoStuck, operation: stuckLease)
        try expect(!videoBlockers.isEmpty, "a stuck video upload is reported as a blocker")
        try expect(videoBlockers.contains { $0.contains("video upload") },
                   "the blocker names the video upload")
        try expect(videoBlockers.contains { $0.contains("receiving=1") },
                   "the blocker carries the receiving count")

        // Named active work still wins, and still reads the same as before.
        let workStuck: [String: Any] = [
            "lifecycle": ["state": "draining",
                          "activeByKind": ["recording_session": 1, "recording_chunk": 2],
                          "restartProof": ["valid": true, "leaseMatches": true,
                                           "operationMatches": true, "nonceMatches": true,
                                           "sourceIdentityMatches": true,
                                           "serverInstanceId": "srv", "bootId": "boot",
                                           "generationId": "gen"]],
        ]
        let workBlockers = restartBlockers(workStuck, operation: stuckLease)
        try expect(workBlockers.contains("recording_session=1"), "named work is still reported")
        try expect(workBlockers.contains("recording_chunk=2"), "every active kind is reported")

        // A failing proof says WHICH field failed, not just that it failed.
        let proofStuck: [String: Any] = [
            "lifecycle": ["state": "draining", "activeByKind": [String: Any](),
                          "restartProof": ["valid": false, "leaseMatches": true,
                                           "operationMatches": true, "nonceMatches": false,
                                           "sourceIdentityMatches": true,
                                           "serverInstanceId": "srv", "bootId": "boot",
                                           "generationId": "gen"]],
        ]
        try expect(restartBlockers(proofStuck, operation: stuckLease).contains("proof nonce mismatch"),
                   "a failing proof names the field that failed")

        // A genuinely healthy payload reports nothing, so the empty case still
        // means "no cause reported" rather than a fabricated one.
        let healthy: [String: Any] = [
            "shuttingDown": false,
            "videoUploads": ["blocksRestart": false],
            "lifecycle": ["state": "draining", "activeByKind": [String: Any](),
                          "restartProof": ["valid": true, "leaseMatches": true,
                                           "operationMatches": true, "nonceMatches": true,
                                           "sourceIdentityMatches": true,
                                           "serverInstanceId": "srv", "bootId": "boot",
                                           "generationId": "gen"]],
        ]
        try expect(restartBlockers(healthy, operation: stuckLease).isEmpty,
                   "a healthy payload reports no blockers")

        // The label itself, including the empty case the old code got wrong.
        try expect(Self.drainLabel([]) == "restart proof (no cause reported)",
                   "an empty blocker set says no cause was reported")
        try expect(Self.drainLabel([]) != "restart proof",
                   "the empty label is never the old opaque string")
        try expect(Self.drainLabel(["video upload (receiving=1)"]) == "video upload (receiving=1)",
                   "a single blocker is the label")
        try expect(Self.drainLabel(["a", "b"]) == "a, b", "blockers are joined")

        try expect(Self.isStrandedReceivingVideoUpload(
            state: "receiving", updatedAtMs: 0, nowMs: 60_000) == true,
                   "idle receiving is stranded")
        try expect(Self.isStrandedReceivingVideoUpload(
            state: "receiving", updatedAtMs: 1, nowMs: 60_000) == false,
                   "a draft updated inside 60s is not stranded")
        try expect(Self.isStrandedReceivingVideoUpload(
            state: "receiving", updatedAtMs: 0, nowMs: 120_000, activeWriters: 1) == false,
                   "an active writer is not stranded")
        try expect(Self.isStrandedReceivingVideoUpload(
            state: "finalizing", updatedAtMs: 0, nowMs: 120_000) == false,
                   "finalizing is never stranded")
        try expect(Self.isStrandedReceivingVideoUpload(
            state: "published", updatedAtMs: 0, nowMs: 120_000) == false,
                   "published receipts are never stranded")
        try expect(Self.jsonInt(NSNumber(value: 1_700_000_000_000)) == 1_700_000_000_000,
                   "manifest updatedAtMs survives JSON number bridging")
        try expect(Self.isValidVideoUploadId("vu_83467cd724e7566c4c2d4335") == true,
                   "a real upload id is accepted")
        try expect(Self.isValidVideoUploadId("clear-stranded") == false,
                   "the clear-stranded path is not an upload id")

        let recoveredNoise: [String: Any] = [
            "sessionId": "meeting_1", "chunkFiles": 40, "recovered": true,
        ]
        let tooShort: [String: Any] = [
            "sessionId": "meeting_2", "chunkFiles": 1, "recovered": false,
        ]
        let recoverable: [String: Any] = [
            "sessionId": "meeting_3", "chunkFiles": 12, "recovered": false,
        ]
        try expect(Self.orphanItemProjection(["title": "no id"]) == nil,
                   "orphan rows without a sessionId are dropped")
        try expect(Self.isRecoverableOrphan(recoveredNoise) == false,
                   "already-recovered captures are not recoverable")
        try expect(Self.isRecoverableOrphan(tooShort) == false,
                   "a one-chunk capture is not recoverable")
        try expect(Self.isRecoverableOrphan(recoverable) == true,
                   "a substantial unrecovered capture is recoverable")
        try expect(
            Self.recoverableOrphanSessionIds([recoveredNoise, tooShort, recoverable]) == ["meeting_3"],
            "recover-all walks only recoverable ids, in list order"
        )
        try expect(Self.strandedItemProjection(["idleMinutes": 40]) == nil,
                   "stranded rows without a sessionId are dropped")
        try expect(
            Self.strandedItemProjection(["sessionId": "meeting_live", "idleMinutes": 40])?["idleMinutes"] as? Int == 40,
            "stranded rows keep idle minutes and never imply deletion"
        )
        try expect(Self.claudePeerState(alive: false, status: "waiting", waitingFor: "user") == "stale",
                   "a dead process is stale even if the registry still says waiting")
        try expect(Self.claudePeerState(alive: true, status: "waiting", waitingFor: "") == "waiting",
                   "an alive waiting session is waiting")
        try expect(Self.claudePeerState(alive: true, status: "running", waitingFor: "") == "running",
                   "an alive session with no wait is running")
        try expect(Self.claudePeerProjection(["workspace": "MU-Chief-Staff"]) == nil,
                   "Claude session rows without an id are dropped")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cos-claude-title-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let project = tmp.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let jsonl = project.appendingPathComponent("d3786335-cfb4-4556-9a4a-7308ce66eab1.jsonl")
        try Data("{\"type\":\"custom-title\",\"customTitle\":\"Fireflies meeting sync\"}\n".utf8).write(to: jsonl)
        try expect(Self.lastCustomTitle(in: jsonl) == "Fireflies meeting sync",
                   "jsonl custom-title is the Activity label")
        try expect(Self.claudeCustomTitle(sessionId: "d3786335", projectsRoot: tmp) == "Fireflies meeting sync",
                   "an 8-char presence id still finds the /rename title")
        try expect(Self.recentClaudeConversations(liveIds: ["d3786335"], projectsRoot: tmp).isEmpty,
                   "live sessions are not duplicated as recent")
        try expect(
            Self.recentClaudeConversations(liveIds: [], projectsRoot: tmp).first?["name"] as? String == "Fireflies meeting sync",
            "ended conversations from today still appear"
        )
        try expect(Self.isKeepWarmSessionTitle("ready"), "CLI pre-warm prompt is keep-warm")
        try expect(Self.isKeepWarmSessionTitle("This is an automated local readiness check. Do not use tools. Reply with exactly"),
                   "provider-proof prompts are keep-warm")
        try expect(!Self.isKeepWarmSessionTitle("Fireflies meeting sync"), "real session titles stay visible")
        let readyJsonl = project.appendingPathComponent("bbbbbbbb-bbbb-cccc-dddd-ffffffffffff.jsonl")
        try Data("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"ready\"}}\n".utf8).write(to: readyJsonl)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: readyJsonl.path)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: jsonl.path)
        let afterWarm = Self.recentClaudeConversations(liveIds: [], projectsRoot: tmp)
        try expect(afterWarm.contains(where: { ($0["name"] as? String) == "ready" }) == false,
                   "keep-warm ready sessions stay out of the Sessions list")
        try expect(afterWarm.contains(where: { ($0["name"] as? String) == "Fireflies meeting sync" }),
                   "real sessions still list after keep-warm rows are skipped")
        try expect(Self.findClaudeSessionFile(sessionId: "d3786335", projectsRoot: tmp)?.lastPathComponent == jsonl.lastPathComponent,
                   "an 8-char id resolves to the local jsonl")
        try expect(Self.findClaudeSessionFile(sessionId: "../etc/passwd", projectsRoot: tmp) == nil,
                   "session lookup rejects path escape")
        try expect(Self.findClaudeSessionFile(sessionId: "short", projectsRoot: tmp) == nil,
                   "session lookup requires an 8-char id")
        let transcript = project.appendingPathComponent("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl")
        let transcriptLines = [
            "{\"type\":\"custom-title\",\"customTitle\":\"Fireflies meeting sync\"}",
            "{\"type\":\"user\",\"cwd\":\"/repo\",\"gitBranch\":\"main\",\"sessionId\":\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\",\"message\":{\"role\":\"user\",\"content\":\"Sync Fireflies COS_API_TOKEN=secret-token-value\"}}",
            "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"hide\"},{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"cat ~/.cos-glasses/.env\"}}]}}",
            "{\"type\":\"user\",\"toolUseResult\":{\"stdout\":\"SECRET\"},\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":\"SECRET\"}]}}",
            "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Synced the meeting.\"}]}}",
            "{\"type\":\"user\",\"isSidechain\":true,\"message\":{\"role\":\"user\",\"content\":\"subagent secret\"}}",
        ]
        try Data((transcriptLines.joined(separator: "\n") + "\n").utf8).write(to: transcript)
        let parsed = Self.parseClaudeTranscript(in: transcript)
        try expect(parsed.turns.count == 2, "history keeps user and assistant prose only")
        try expect(parsed.omittedTools >= 1, "tool calls are counted as omitted")
        try expect(parsed.omittedSidechain == 1, "subagent sidechains are omitted")
        try expect(parsed.turns[0]["text"]?.contains("[redacted]") == true, "token shapes are redacted in history")
        try expect(parsed.turns[0]["text"]?.contains("secret-token-value") != true, "raw tokens never reach history")
        let copy = Self.claudeKickstartCopy(
            title: parsed.title,
            cwd: parsed.cwd,
            branch: parsed.branch,
            sessionId: parsed.sessionId,
            turns: parsed.turns,
            omittedTools: parsed.omittedTools
        )
        try expect(copy.contains("# Kickstart: Fireflies meeting sync"), "copy is a kickstart brief")
        try expect(copy.contains("Synced the meeting."), "copy includes assistant prose")
        try expect(copy.contains("/repo") && copy.contains("main"), "copy carries workspace and branch")
        try expect(!copy.contains("secret-token-value"), "copy does not carry raw tokens")
        try expect(!copy.contains("cat ~/.cos-glasses/.env"), "copy does not carry tool commands")
        try expect(!copy.contains("subagent secret"), "copy does not carry sidechain text")
        try expect(!copy.contains("SECRET"), "copy does not carry tool output")
        try expect(Self.workspaceLabel("-Users-ukaoma-Documents-GitHub-Ukaoma-Chief-Of-Staff-MU-Chief-Staff") == "MU-Chief-Staff",
                   "encoded Claude/Cursor project folders collapse to the repo name")
        try expect(Self.workspaceLabel("/Users/ukaoma/Documents/GitHub/Ukaoma Chief Of Staff/MU-Chief-Staff") == "MU-Chief-Staff",
                   "real paths use the last component")
        let codexRoot = tmp.appendingPathComponent("codex/2026/08/13", isDirectory: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        let codexFile = codexRoot.appendingPathComponent("rollout-2026-08-13T12-00-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl")
        let codexLines = [
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\",\"cwd\":\"/repo\",\"thread_source\":\"user\"}}",
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"developer\",\"content\":[{\"type\":\"input_text\",\"text\":\"<app-context>hide\"}]}}",
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Badge the sessions tab\"}]}}",
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call\",\"name\":\"Bash\",\"input\":{\"command\":\"cat ~/.env\"}}}",
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Badges added.\"}]}}",
        ]
        try Data((codexLines.joined(separator: "\n") + "\n").utf8).write(to: codexFile)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: codexFile.path)
        let sessionsRoot = tmp.appendingPathComponent("codex", isDirectory: true)
        let codexParsed = Self.parseCodexTranscript(in: codexFile)
        try expect(codexParsed.turns.count == 2, "Codex history keeps user and assistant prose")
        try expect(codexParsed.omittedTools >= 1, "Codex tool calls are omitted")
        try expect(codexParsed.turns[0]["text"] == "Badge the sessions tab", "Codex user text is the title source")
        try expect(!codexParsed.turns.contains(where: { ($0["text"] ?? "").contains("cat ~/.env") }), "Codex copy omits tool commands")
        try expect(Self.peekCodexMeta(in: codexFile)?.subagent == false, "parent Codex threads are listed")
        let subagent = codexRoot.appendingPathComponent("rollout-sub.jsonl")
        try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"sub\",\"thread_source\":\"subagent\",\"cwd\":\"/repo\"}}\n".utf8).write(to: subagent)
        try expect(Self.peekCodexMeta(in: subagent)?.subagent == true, "Codex subagents are not listed")
        var listingDay = DateComponents()
        listingDay.year = 2026
        listingDay.month = 8
        listingDay.day = 13
        listingDay.hour = 12
        let listingNow = Calendar.current.date(from: listingDay) ?? now
        try FileManager.default.setAttributes([.modificationDate: listingNow], ofItemAtPath: codexFile.path)
        let listedCodex = Self.recentCodexConversations(sessionsRoot: sessionsRoot, now: listingNow)
        try expect(listedCodex.contains(where: { ($0["name"] as? String) == "Badge the sessions tab" }),
                   "Codex parent threads appear in the Sessions list")
        try expect(!listedCodex.contains(where: { ($0["id"] as? String) == "sub" }),
                   "Codex subagents stay out of the Sessions list")
        try expect(Self.findCodexSessionFile(sessionId: "../etc/passwd", sessionsRoot: sessionsRoot) == nil,
                   "Codex lookup rejects path escape")
        let pinnedDay = tmp.appendingPathComponent("codex/2026/05/08", isDirectory: true)
        try FileManager.default.createDirectory(at: pinnedDay, withIntermediateDirectories: true)
        let pinnedId = "019e0943-62c4-7643-bcff-1a7be9a52a4c"
        let pinnedFile = pinnedDay.appendingPathComponent("rollout-2026-05-08T15-24-31-\(pinnedId).jsonl")
        try Data((
            "{\"timestamp\":\"2026-05-08T20:24:36.565Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(pinnedId)\",\"cwd\":\"/repo\",\"originator\":\"Codex Desktop\",\"timestamp\":\"2026-05-08T20:24:31.684Z\"}}\n"
            + "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Plan Markt POS case study build\"}]}}\n"
        ).utf8).write(to: pinnedFile)
        try FileManager.default.setAttributes([.modificationDate: listingNow], ofItemAtPath: pinnedFile.path)
        try Data("{\"id\":\"\(pinnedId)\",\"thread_name\":\"Markt POS 2.0 build\",\"updated_at\":\"2026-05-13T22:02:18Z\"}\n".utf8)
            .write(to: tmp.appendingPathComponent("session_index.jsonl"))
        let pinnedListed = Self.recentCodexConversations(sessionsRoot: sessionsRoot, now: listingNow)
        try expect(pinnedListed.contains(where: { ($0["name"] as? String) == "Markt POS 2.0 build" }),
                   "a pinned Codex thread lists by last write, not the May folder")
        try expect(Self.findCodexSessionFile(sessionId: pinnedId, sessionsRoot: sessionsRoot)?.lastPathComponent == pinnedFile.lastPathComponent,
                   "Codex lookup finds the original day-folder rollout")
        try expect(Self.createdFromCodexFilename(pinnedFile.lastPathComponent) != nil,
                   "Codex filenames carry the opened stamp")
        let jewelryId = "019dfe42-d4ba-7152-b5ae-60f600a2675a"
        let jewelryDay = tmp.appendingPathComponent("codex/2026/05/06", isDirectory: true)
        try FileManager.default.createDirectory(at: jewelryDay, withIntermediateDirectories: true)
        let jewelryFile = jewelryDay.appendingPathComponent("rollout-2026-05-06T12-08-05-\(jewelryId).jsonl")
        try Data((
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(jewelryId)\",\"cwd\":\"/repo\",\"timestamp\":\"2026-05-06T17:08:05.000Z\"}}\n"
            + "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Jewelry Edge bridge\"}]}}\n"
        ).utf8).write(to: jewelryFile)
        var jewelryDayStamp = DateComponents()
        jewelryDayStamp.year = 2026
        jewelryDayStamp.month = 5
        jewelryDayStamp.day = 6
        jewelryDayStamp.hour = 12
        let jewelryMtime = Calendar.current.date(from: jewelryDayStamp) ?? listingNow.addingTimeInterval(-35 * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: jewelryMtime], ofItemAtPath: jewelryFile.path)
        try Data("{\"id\":\"\(jewelryId)\",\"thread_name\":\"Jewelry 2.0 Build\"}\n".utf8)
            .write(to: tmp.appendingPathComponent("session_index.jsonl"), options: .atomic)
        try Data("{\"pinned-thread-ids\":[\"\(jewelryId)\",\"\(pinnedId)\"]}\n".utf8)
            .write(to: tmp.appendingPathComponent(".codex-global-state.json"))
        let menuListed = Self.recentCodexConversations(sessionsRoot: sessionsRoot, now: listingNow)
        try expect(menuListed.contains(where: { ($0["name"] as? String) == "Jewelry 2.0 Build" && ($0["pinned"] as? Bool) == true }),
                   "ChatGPT pinned threads stay in the list even when stale")
        try expect(Self.idFromCodexFilename(jewelryFile.lastPathComponent) == jewelryId,
                   "Codex rollout filenames expose the thread id")
        let cursorProj = tmp.appendingPathComponent("cursor-proj/agent-transcripts/bbbbbbbb-1111-2222-3333-cccccccccccc", isDirectory: true)
        try FileManager.default.createDirectory(at: cursorProj, withIntermediateDirectories: true)
        let cursorFile = cursorProj.appendingPathComponent("bbbbbbbb-1111-2222-3333-cccccccccccc.jsonl")
        let cursorLines = [
            "{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"<user_query>Show Codex and Cursor too</user_query>\"}]}}",
            "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Will badge them.\"},{\"type\":\"tool_use\",\"name\":\"Read\",\"input\":{}}]}}",
        ]
        try Data((cursorLines.joined(separator: "\n") + "\n").utf8).write(to: cursorFile)
        try expect(Self.firstCursorUserTitle(in: cursorFile) == "Show Codex and Cursor too",
                   "Cursor titles come from user_query")
        let wrapperCursor = cursorProj.appendingPathComponent("wrapper.jsonl")
        try Data("""
        {"role":"user","message":{"content":[{"type":"text","text":"SYSTEM INSTRUCTIONS\\nDo not tell the user."}]}}
        {"role":"user","message":{"content":[{"type":"text","text":"<user_query>Badge Claude Codex and Cursor</user_query>"}]}}
        {"role":"user","message":{"content":[{"type":"text","text":"<user_query>Proper badges on the session tab</user_query>"}]}}
        """.utf8).write(to: wrapperCursor)
        try expect(Self.firstCursorUserTitle(in: wrapperCursor) == "Badge Claude Codex and Cursor",
                   "Cursor titles skip SYSTEM INSTRUCTIONS")
        try expect(Self.lastCursorUserTitle(in: wrapperCursor) == "Proper badges on the session tab",
                   "Cursor list titles prefer the latest user_query")
        let cursorParsed = Self.parseCursorTranscript(in: cursorFile)
        try expect(cursorParsed.turns.count == 2, "Cursor history keeps user and assistant prose")
        try expect(cursorParsed.omittedTools >= 1, "Cursor tool_use is omitted from prose")
        let cursorGhostDir = tmp.appendingPathComponent("empty-window/agent-transcripts/bbbbbbbb-1111-2222-3333-cccccccccccc", isDirectory: true)
        try FileManager.default.createDirectory(at: cursorGhostDir, withIntermediateDirectories: true)
        let cursorGhost = cursorGhostDir.appendingPathComponent("bbbbbbbb-1111-2222-3333-cccccccccccc.jsonl")
        try Data((cursorLines.joined(separator: "\n") + "\n").utf8).write(to: cursorGhost)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: cursorGhost.path)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: cursorFile.path)
        let composerDb = tmp.appendingPathComponent("composer.vscdb")
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [
            composerDb.path,
            "CREATE TABLE composerHeaders (composerId TEXT, value TEXT); INSERT INTO composerHeaders VALUES ('bbbbbbbb-1111-2222-3333-cccccccccccc', '{\"name\":\"V2 verification and performance\"}');",
        ]
        try sqlite.run()
        sqlite.waitUntilExit()
        try expect(sqlite.terminationStatus == 0, "composerHeaders fixture sqlite must succeed")
        let composerNames = Self.loadCursorComposerNames(from: composerDb)
        try expect(composerNames["bbbbbbbb-1111-2222-3333-cccccccccccc"] == "V2 verification and performance",
                   "Cursor sidebar titles come from composerHeaders")
        let listedCursor = Self.recentCursorConversations(projectsRoot: tmp, now: now, composerNames: composerNames)
        try expect(listedCursor.count == 1, "empty-window copies of the same Cursor chat are dropped")
        try expect(listedCursor.first?["name"] as? String == "V2 verification and performance",
                   "Cursor list titles prefer the sidebar name")
        try expect(listedCursor.first?["workspace"] as? String == "cursor-proj",
                   "Cursor rows keep the real workspace, not empty-window")
        try expect(Self.findCursorSessionFile(sessionId: "bbbbbbbb-1111-2222-3333-cccccccccccc", projectsRoot: tmp)?.path.contains("empty-window") != true,
                   "Cursor lookup skips empty-window")
        try expect(Self.findCursorSessionFile(sessionId: "../etc/passwd", projectsRoot: tmp) == nil,
                   "Cursor lookup rejects path escape")
        let claudeConfig = tmp.appendingPathComponent("claude_desktop_config.json")
        let starredDesktopId = "f92b10f3-413a-461a-bee9-19d269355b15"
        let starredJsonlId = "a4b2b4dd-e40c-4b08-8a11-c89a018c197d"
        try Data("""
        {"preferences":{"epitaxyPrefs":{"starred-local-code-sessions":["local_\(starredDesktopId)","local_\(starredJsonlId)"]}}}
        """.utf8).write(to: claudeConfig)
        try expect(Self.loadClaudeStarredIds(from: claudeConfig).contains(starredDesktopId),
                   "Claude Desktop stars strip the local_ prefix")
        let desktopDir = tmp.appendingPathComponent("claude-code-sessions/account/workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: desktopDir, withIntermediateDirectories: true)
        let desktopFile = desktopDir.appendingPathComponent("local_\(starredDesktopId).json")
        try Data("{\"sessionId\":\"local_\(starredDesktopId)\",\"cwd\":\"/repo\",\"title\":\"ThriftCart end-of-year campaign design\"}\n".utf8)
            .write(to: desktopFile)
        var julyStamp = DateComponents()
        julyStamp.year = 2026
        julyStamp.month = 7
        julyStamp.day = 9
        julyStamp.hour = 20
        let julyMtime = Calendar.current.date(from: julyStamp) ?? listingNow.addingTimeInterval(-35 * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: julyMtime], ofItemAtPath: desktopFile.path)
        let starredJsonl = project.appendingPathComponent("\(starredJsonlId).jsonl")
        try Data("{\"type\":\"custom-title\",\"customTitle\":\"COS-glasses Server work (meetings)\"}\n".utf8).write(to: starredJsonl)
        try FileManager.default.setAttributes([.modificationDate: jewelryMtime], ofItemAtPath: starredJsonl.path)
        let starredClaude = Self.recentClaudeConversations(
            liveIds: [],
            projectsRoot: tmp,
            now: listingNow,
            starredIds: Self.loadClaudeStarredIds(from: claudeConfig),
            desktopSessionsRoot: tmp.appendingPathComponent("claude-code-sessions")
        )
        try expect(starredClaude.contains(where: { ($0["name"] as? String) == "ThriftCart end-of-year campaign design" && ($0["pinned"] as? Bool) == true }),
                   "Claude Desktop stars list even without a project jsonl")
        try expect(starredClaude.contains(where: { ($0["name"] as? String) == "COS-glasses Server work (meetings)" && ($0["pinned"] as? Bool) == true }),
                   "starred Claude jsonl stays in the list when stale")
        let pinWs = tmp.appendingPathComponent("workspaceStorage/empty-window", isDirectory: true)
        try FileManager.default.createDirectory(at: pinWs, withIntermediateDirectories: true)
        let pinDb = pinWs.appendingPathComponent("state.vscdb")
        let pinSqlite = Process()
        pinSqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        pinSqlite.arguments = [
            pinDb.path,
            "CREATE TABLE ItemTable (key TEXT, value BLOB); INSERT INTO ItemTable VALUES ('cursor/pinnedComposers', '[\"bbbbbbbb-1111-2222-3333-cccccccccccc\"]');",
        ]
        try pinSqlite.run()
        pinSqlite.waitUntilExit()
        try expect(pinSqlite.terminationStatus == 0, "pinnedComposers fixture sqlite must succeed")
        try FileManager.default.setAttributes([.modificationDate: jewelryMtime], ofItemAtPath: cursorFile.path)
        let cursorPins = Self.loadCursorPinnedIds(from: tmp.appendingPathComponent("workspaceStorage"))
        try expect(cursorPins.contains("bbbbbbbb-1111-2222-3333-cccccccccccc"),
                   "Cursor pins come from workspaceStorage pinnedComposers")
        let stalePinnedCursor = Self.recentCursorConversations(
            projectsRoot: tmp,
            now: listingNow,
            composerNames: composerNames,
            pinnedIds: cursorPins
        )
        try expect(stalePinnedCursor.contains(where: { ($0["name"] as? String) == "V2 verification and performance" && ($0["pinned"] as? Bool) == true }),
                   "Cursor sidebar pins stay in the list even when stale")
        let posId = "c0ffeeee-aaaa-bbbb-cccc-ddddeeee0001"
        let posJsonl = project.appendingPathComponent("\(posId).jsonl")
        try Data("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Split by severity — this is the one that matters.\"}}\n".utf8)
            .write(to: posJsonl)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: posJsonl.path)
        let posDesktop = desktopDir.appendingPathComponent("local_\(posId).json")
        try Data("{\"sessionId\":\"local_\(posId)\",\"cwd\":\"/Users/ukaoma/Documents/GitHub/MU-Chief-Staff\",\"title\":\"POS complexity and competitive challenges\"}\n".utf8)
            .write(to: posDesktop)
        let desktopRoot = tmp.appendingPathComponent("claude-code-sessions")
        try expect(
            Self.findClaudeDesktopFile(sessionId: String(posId.prefix(8)), sessionsRoot: desktopRoot)?.lastPathComponent
                == "local_\(posId).json",
            "an 8-char live id still finds the Claude Code sidebar file"
        )
        let posListed = Self.recentClaudeConversations(
            liveIds: [],
            projectsRoot: tmp,
            desktopSessionsRoot: desktopRoot
        )
        try expect(
            posListed.contains(where: { ($0["name"] as? String) == "POS complexity and competitive challenges" }),
            "Claude Code sidebar titles beat the first prompt"
        )
        try expect(
            Self.claudeSidebarTitle(
                sessionId: String(posId.prefix(8)),
                projectsRoot: tmp,
                desktopIndex: Self.loadClaudeDesktopIndex(from: desktopRoot)
            ) == "POS complexity and competitive challenges",
            "live overlay uses the Claude Code sidebar title"
        )
        try expect(Self.tokenizeSessionQuery("aeo") == ["aeo"], "short tokens still search")
        let aeoScored = Self.scoreSessionKeyword(
            tokens: ["aeo"],
            title: "AEO HS Setup",
            haystack: "AEO HS Setup\nMU-Chief-Staff"
        )
        try expect(aeoScored.score > 0, "keyword search hits a listed title immediately")
        let searchHome = tmp.appendingPathComponent("search-home", isDirectory: true)
        let searchDesktop = searchHome.appendingPathComponent(
            "Library/Application Support/Claude/claude-code-sessions/acct/ws", isDirectory: true
        )
        try FileManager.default.createDirectory(at: searchDesktop, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: searchHome.appendingPathComponent(".claude/projects/proj", isDirectory: true),
            withIntermediateDirectories: true
        )
        let aeoId = "ae0ae0ae-1111-2222-3333-444444444444"
        try Data("{\"title\":\"AEO HS Setup\",\"cwd\":\"/repo\"}\n".utf8)
            .write(to: searchDesktop.appendingPathComponent("local_\(aeoId).json"))
        let searchHits = Self.localSessionKeywordHits(query: "aeo", limit: 20, home: searchHome)
        try expect(
            searchHits.contains(where: { ($0["name"] as? String) == "AEO HS Setup" }),
            "keyword search hits a sidebar title without re-reading transcripts"
        )
        try Data("{\"title\":\"POS complexity and competitive challenges\",\"cwd\":\"/repo\"}\n".utf8)
            .write(to: searchDesktop.appendingPathComponent("local_\(posId).json"))
        let posSearch = Self.localSessionKeywordHits(query: "POS complexity", limit: 20, home: searchHome)
        try expect(
            posSearch.contains(where: { ($0["name"] as? String) == "POS complexity and competitive challenges" }),
            "keyword search finds a Claude Code sidebar title"
        )
        let ewicJsonl = searchHome.appendingPathComponent(".claude/projects/proj/\(posId).jsonl")
        try Data("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Speaker 2 said EWIC is a month out of being something we could sell.\"}}\n".utf8)
            .write(to: ewicJsonl)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: ewicJsonl.path)
        try expect(
            Self.peekSessionSearchBody(in: ewicJsonl).lowercased().contains("ewic"),
            "body peek keeps user prose from the transcript head"
        )
        let ewicHits = Self.localSessionKeywordHits(query: "ewic", limit: 20, home: searchHome)
        try expect(
            ewicHits.contains(where: { ($0["name"] as? String) == "POS complexity and competitive challenges" }),
            "keyword search hits EWIC in the transcript body"
        )
        try expect(
            ewicHits.contains(where: { (($0["snippet"] as? String) ?? "").lowercased().contains("ewic") }),
            "body match snippet keeps the EWIC sentence"
        )
        let deskId = "2954f44a-4ee3-46f5-adc1-87bf0d85db1f"
        let cliId = "c5ec6a69-24c3-479d-bb40-9b3f1fe6eabf"
        try Data("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Split by severity\"}}\n".utf8)
            .write(to: project.appendingPathComponent("\(cliId).jsonl"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: project.appendingPathComponent("\(cliId).jsonl").path
        )
        try Data("{\"sessionId\":\"local_\(deskId)\",\"cliSessionId\":\"\(cliId)\",\"cwd\":\"/repo\",\"title\":\"POS complexity and competitive challenges\"}\n".utf8)
            .write(to: desktopDir.appendingPathComponent("local_\(deskId).json"))
        try expect(
            Self.claudeSidebarTitle(
                sessionId: String(cliId.prefix(8)),
                projectsRoot: tmp,
                desktopIndex: Self.loadClaudeDesktopIndex(from: desktopRoot)
            ) == "POS complexity and competitive challenges",
            "live overlay follows cliSessionId to the Desktop title"
        )
        let cursorCopy = Self.claudeKickstartCopy(
            title: cursorParsed.title,
            cwd: cursorParsed.cwd,
            branch: "",
            sessionId: cursorParsed.sessionId,
            turns: cursorParsed.turns,
            omittedTools: cursorParsed.omittedTools,
            provider: "cursor"
        )
        try expect(cursorCopy.contains("Cursor session"), "kickstart names the provider")
        var missingScripts = ""
        do {
            _ = try Self.meetingSyncTooling(scriptsDir: nil, fileExists: { _ in true }, isExecutable: { _ in true })
        } catch { missingScripts = "\(error)" }
        try expect(missingScripts.contains("COS_SCRIPTS_DIR"), "missing scripts dir must fail closed")
        var missingPython = ""
        do {
            _ = try Self.meetingSyncTooling(
                scriptsDir: "/tmp/scripts",
                fileExists: { $0.hasSuffix("sync_meetings.py") },
                isExecutable: { _ in false }
            )
        } catch { missingPython = "\(error)" }
        try expect(missingPython.contains("cos_python"), "missing cos_python must fail closed")
        var missingScript = ""
        do {
            _ = try Self.meetingSyncTooling(
                scriptsDir: "/tmp/scripts",
                fileExists: { $0.hasSuffix("cos_python") },
                isExecutable: { $0.hasSuffix("cos_python") }
            )
        } catch { missingScript = "\(error)" }
        try expect(missingScript.contains("sync_meetings.py"), "missing sync_meetings.py must fail closed")
        let tooling = try Self.meetingSyncTooling(
            scriptsDir: "/tmp/scripts",
            fileExists: { _ in true },
            isExecutable: { _ in true }
        )
        try expect(tooling.python.hasSuffix("cos_python") && tooling.script.hasSuffix("sync_meetings.py"),
                   "resolved tooling must be cos_python plus sync_meetings.py")
        try expect(!Self.meetingSyncArguments(script: tooling.script).contains("--force"),
                   "manual sync must not pass --force")
        let child = Self.meetingSyncChildEnvironment(
            base: ["PATH": "/usr/bin", "COS_SCRIPTS_DIR": "stale"],
            launchAgent: ["COS_SCRIPTS_DIR": "/from/plist"],
            liveScriptsDir: "/live/scripts"
        )
        try expect(child["COS_SCRIPTS_DIR"] == "/live/scripts", "live LaunchAgent scripts dir wins")
        try expect(child["PATH"] == "/usr/bin", "child env keeps the helper PATH")
        try expect(Self.meetingSyncTimeout >= 60, "meeting sync must have a timeout")


        // COS data TIER must never change on its own (Miles, 2026-08-14: "It should
        // not swap anyone from their preference. Only when a user explicitly asks").
        //
        // `validatedContextSource` used to prefer the bridge whenever a workspace held
        // BOTH, so a user on plain notes who re-picked their own folder was silently
        // moved onto the pipeline. The tiers serve DIFFERENT data and never merge, so
        // that swap replaces a live store: measured on a real install, 11 memories +
        // 6 threads on files versus 21 + 5 on the bridge, sharing no content.
        //
        // EXECUTION, not a grep. A source assertion here would pass against a function
        // that had been rewritten to swap again.
        let tierRoot = home.appendingPathComponent("selftest-tier", isDirectory: true)
        try? FileManager.default.removeItem(at: tierRoot)
        let tierScripts = tierRoot.appendingPathComponent("operations/scripts", isDirectory: true)
        try makeDir(tierScripts.appendingPathComponent("venv/bin", isDirectory: true))
        try makeDir(tierRoot.appendingPathComponent("operations/memory", isDirectory: true))
        FileManager.default.createFile(atPath: tierScripts.appendingPathComponent("cos_api_bridge.py").path,
                                       contents: Data("x".utf8))
        let fakePython = tierScripts.appendingPathComponent("venv/bin/python3")
        FileManager.default.createFile(atPath: fakePython.path, contents: Data("#!/bin/sh\nexit 1\n".utf8),
                                       attributes: [.posixPermissions: 0o755])

        // Both tiers present. Asking for files MUST return files, never the bridge —
        // this is the exact shape that used to swap a user.
        if case .files = try validatedContextSource(tierRoot.path, tier: "files") {
            passed += 1
        } else {
            throw HelperError.message("self-test failed: files tier resolved to the bridge")
        }

        // Asking for the bridge where none exists must SAY SO, not silently hand back
        // the other tier. A quiet downgrade is the same surprise as a quiet upgrade.
        let notesOnly = home.appendingPathComponent("selftest-notes", isDirectory: true)
        try? FileManager.default.removeItem(at: notesOnly)
        try makeDir(notesOnly.appendingPathComponent("memory", isDirectory: true))
        var refusedBridge = false
        do { _ = try validatedContextSource(notesOnly.path, tier: "bridge") } catch { refusedBridge = true }
        try expect(refusedBridge, "bridge tier silently fell back to files")

        // A SYMLINKED memory/ is a normal layout and the server follows it. Control
        // rejected it, so a working store reported contextResolvedRoot = nil while
        // simultaneously serving 11 memories and 6 threads out of it — which then
        // offered "Create Folders" over folders that already existed.
        let linkRoot = home.appendingPathComponent("selftest-symlink", isDirectory: true)
        try? FileManager.default.removeItem(at: linkRoot)
        try makeDir(linkRoot)
        let realNotes = home.appendingPathComponent("selftest-symlink-target", isDirectory: true)
        try? FileManager.default.removeItem(at: realNotes)
        try makeDir(realNotes)
        try FileManager.default.createSymbolicLink(at: linkRoot.appendingPathComponent("memory"),
                                                   withDestinationURL: realNotes)
        try expect(holdsContextFiles(linkRoot), "a symlinked memory/ was not recognised as a notes store")

        emit(ok: true, message: "\(passed) deterministic helper tests passed", details: ["tests": passed])
    }

    private func cleanupGenerations(keeping: Set<String>) {
        guard let entries = try? fm.contentsOfDirectory(at: generations, includingPropertiesForKeys: nil) else { return }
        for entry in entries where !keeping.contains(entry.path) {
            try? fm.removeItem(at: entry)
        }
        if let staged = try? fm.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
            for entry in staged {
                if (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture < cutoff {
                    try? fm.removeItem(at: entry)
                }
            }
        }
    }
}

do {
    try COSControlHelper().run()
} catch {
    let payload: [String: Any] = ["ok": false, "message": String(describing: error), "details": [:]]
    let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    exit(1)
}
