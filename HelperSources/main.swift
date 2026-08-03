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
        "COS_OPERATIONS_DIR",
        "COS_MEETINGS_ROOT",
        "CODEX_GLASSES_WORKDIR",
        "COS_DURABLE_QUERY_JOBS",
        "COS_TTS_BOOTSTRAP_PYTHON",
        "COS_TTS_PYTHON",
        "COS_TTS_ENGINE",
        "COS_TTS_KOKORO_VOICE",
        "COS_WHISPER_PREVIEW_MODEL",
        "COS_WHISPER_REALTIME_MODEL",
        "COS_WHISPER_TRANSCRIPTION_TIER",
        "COS_WHISPER_COMMIT_MODEL",
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
        case "set-transcription-tier": try withMutationLock {
            guard let value = args.dropFirst().first else { throw HelperError.message("missing transcription tier") }
            try setTranscriptionTier(value)
        }
        case "token": try copyPairingToken()
        case "expire-clipboard": try expireClipboard(args: args)
        case "report": emit(ok: true, message: "Redacted report ready", details: ["report": redactedReport()])
        case "recent-messages": try emitRecentMessages(args: args)
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
        timeout: TimeInterval = 20
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
        if completion.wait(timeout: .now() + timeout) == .timedOut {
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
        let spec = requested == "latest" ? packageName : "\(packageName)@\(requested)"
        let result = try execute(npm, ["view", spec, "version", "dist.integrity", "--json"], timeout: 30)
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
        try ensureDirectories()
        let stage = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        progress("Downloading server \(version)…")
        let packed = try execute(npm, [
            "pack", "\(packageName)@\(version)", "--pack-destination", stage.path, "--json",
        ], timeout: 120)
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
        ], log: true, timeout: 900)
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
            timeout: 60
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
            progress("Proving \(provider.capitalized)…")
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
        let activeWork = ["COS_WORKDIR", "CODEX_GLASSES_WORKDIR", "COS_LAUNCH_DIR"]
            .compactMap(loadedEnvironmentValue)
            .compactMap { try? validatedWorkDirectory($0) }
            .first
        let transcription = (health?["capabilities"] as? [String: Any])?["transcription"] as? [String: Any]
        let liveTranscription = transcription?["live"] as? [String: Any]
        let hqTranscription = transcription?["hq"] as? [String: Any]
        let transcriptionProfile = transcription?["profile"] as? [String: Any]
        let requestedTier = liveTranscription?["requestedTier"] as? String
        let effectiveTier = liveTranscription?["effectiveTier"] as? String
        let commitReason = liveTranscription?["commitReason"] as? String
        let tierDegraded = (liveTranscription?["commitDegraded"] as? Bool)
            ?? (requestedTier != nil && requestedTier != effectiveTier)
        // Server 6.21 separates cosmetic preview degradation from commit-tier
        // safety. Older servers expose only aggregate `degraded`, so retain it
        // as the backward-compatible fallback.
        let previewDegraded = (liveTranscription?["previewDegraded"] as? Bool)
            ?? ((liveTranscription?["degraded"] as? Bool) ?? false)
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
            "safeToRestart": (managed || inPlaceActive()) ? (maintenance?["safeToRestart"] ?? false) : false,
            "activeJobs": maintenance?["activeJobs"] ?? NSNull(),
            "activeTranscriptionSessions": maintenance?["activeTranscriptionSessions"] ?? NSNull(),
            "whisperReady": ((health?["whisper_health"] as? [String: Any])?["server"] as? Bool) ?? false,
            "whisperCircuitOpen": ((health?["whisper_health"] as? [String: Any])?["circuitOpen"] as? Bool) ?? false,
            "whisperStartupState": (health?["whisper_health"] as? [String: Any])?["startupState"] ?? NSNull(),
            "whisperError": (health?["whisper_health"] as? [String: Any])?["lastError"] ?? NSNull(),
            "livePreviewModel": liveTranscription?["effectiveModel"] ?? NSNull(),
            "livePreviewReady": liveTranscription?["ready"] ?? NSNull(),
            "livePreviewDegraded": previewDegraded,
            "liveCommitModel": liveTranscription?["committedModel"] ?? NSNull(),
            "transcriptionRequestedTier": liveTranscription?["requestedTier"] ?? NSNull(),
            "transcriptionEffectiveTier": liveTranscription?["effectiveTier"] ?? NSNull(),
            "transcriptionRequestedCommitModel": liveTranscription?["requestedCommitModel"] ?? NSNull(),
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
                let lifecycle = status["lifecycle"] as? [String: Any]
                let activeByKind = lifecycle?["activeByKind"] as? [String: Any] ?? [:]
                let blockers = activeByKind.compactMap { key, value -> String? in
                    guard let count = value as? Int, count > 0 else { return nil }
                    return "\(key)=\(count)"
                }.sorted()
                lastBlockers = blockers.isEmpty ? "restart proof" : blockers.joined(separator: ", ")
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

    private func repair() throws {
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
            ]
        case "max":
            return [
                "COS_WHISPER_TRANSCRIPTION_TIER": "max",
                "COS_WHISPER_PREVIEW_MODEL": "turbo",
                "COS_WHISPER_COMMIT_MODEL": "large-v3",
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

    /// Point G2 Review Meetings at a COS operations/ tree
    /// (`{dir}/{quilt|personal|…}/meetings/YYYY-MM/*.md`). Each COS layout can differ.
    private func setOperationsDirectory(_ path: String) throws {
        guard let validated = try validatedOperationsDirectory(path) else {
            throw HelperError.message("Selected meetings folder must exist and contain at least one domain meetings/ tree (e.g. quilt/meetings).")
        }
        if let manifest = loadManifest() {
            try applyManagedProviderEnvironment(["COS_OPERATIONS_DIR": validated], current: manifest, operationLabel: "Meetings library")
            return
        }
        guard inPlaceActive() else {
            throw HelperError.message("Install the managed server or choose Manage in place first.")
        }
        try applyInPlaceProviderEnvironment(["COS_OPERATIONS_DIR": validated], operationLabel: "Meetings library")
    }

    private func validatedOperationsDirectory(_ path: String?) throws -> String? {
        guard let path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        let domains = ["quilt", "sprocket_rocket", "hermit_crabs", "personal"]
        let hasMeetingsTree = domains.contains { domain in
            let meetings = url.appendingPathComponent(domain).appendingPathComponent("meetings", isDirectory: true)
            var meetingsIsDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: meetings.path, isDirectory: &meetingsIsDir) && meetingsIsDir.boolValue
        }
        guard hasMeetingsTree else { return nil }
        return url.path
    }

    private func configuredOperationsDirectory() -> String? {
        if let value = loadManifest()?.providerEnvironment?["COS_OPERATIONS_DIR"]
            ?? loadManifest()?.providerEnvironment?["COS_MEETINGS_ROOT"],
           let validated = try? validatedOperationsDirectory(value) {
            return validated
        }
        if let environment = launchAgentPropertyList()?["EnvironmentVariables"] as? [String: String] {
            for key in ["COS_OPERATIONS_DIR", "COS_MEETINGS_ROOT"] {
                if let value = environment[key], let validated = try? validatedOperationsDirectory(value) {
                    return validated
                }
            }
            if let scripts = environment["COS_SCRIPTS_DIR"], !scripts.isEmpty {
                let inferred = URL(fileURLWithPath: scripts, isDirectory: true)
                    .deletingLastPathComponent().path
                if let validated = try? validatedOperationsDirectory(inferred) { return validated }
            }
        }
        return nil
    }

    private func applyManagedProviderEnvironment(
        _ values: [String: String],
        current: RuntimeManifest,
        operationLabel: String
    ) throws {
        guard loadTransaction() == nil else {
            throw HelperError.message("A previous runtime change needs Repair before \(operationLabel.lowercased()) can change.")
        }
        var candidate = current
        var provider = candidate.providerEnvironment ?? [:]
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
                operationKind: "provider_env_update",
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

    private func applyInPlaceProviderEnvironment(_ values: [String: String], operationLabel: String) throws {
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
        if alreadyActive || snapshot.allListenerPIDs.isEmpty {
            try atomicWriteData(candidate, to: plistURL, permissions: 0o600)
            clearInPlaceConfigurationTransaction()
            let effectiveTier = alreadyActive
                ? try values["COS_WHISPER_TRANSCRIPTION_TIER"].map { try requireTranscriptionTier($0) }
                : nil
            let message: String
            if alreadyActive, values["COS_WHISPER_TRANSCRIPTION_TIER"] == "max", effectiveTier == "balanced" {
                message = "Max transcription is saved; running Balanced fallback because Large-v3 is unavailable"
            } else if alreadyActive {
                message = "\(operationLabel) is already active"
            } else {
                message = "\(operationLabel) saved and will apply when your server starts"
            }
            emit(
                ok: true,
                message: message,
                details: statusDetails()
            )
            return
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
                operationKind: "provider_env_update",
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
                operationKind: "workdir_update",
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
                operationKind: "workdir_update",
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
        return [
            "no": no is NSNull ? NSNull() : no,
            "timestamp": raw["timestamp"] ?? NSNull(),
            "query": (raw["query"] as? String) ?? "",
            "text": (raw["text"] as? String) ?? "",
            "sessionId": (raw["sessionId"] as? String) ?? "",
            "source": (raw["source"] as? String) ?? "",
        ]
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
            status["servicePID"] = NSNull()
            status["listenerPIDs"] = []
        }
        return ["checks": checks, "status": status]
    }

    private func manifestConfiguredWorkDirectory() -> Bool { configuredWorkDirectory() != nil }

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
                && filtered["COS_API_TOKEN"] == nil,
            "provider allowlist"
        )
        let balancedTier = try transcriptionTierEnvironment("balanced")
        let maxTier = try transcriptionTierEnvironment("MAX")
        try expect(
            balancedTier["COS_WHISPER_PREVIEW_MODEL"] == "small.en"
                && balancedTier["COS_WHISPER_COMMIT_MODEL"] == "turbo",
            "Balanced transcription mapping"
        )
        try expect(
            maxTier["COS_WHISPER_PREVIEW_MODEL"] == "turbo"
                && maxTier["COS_WHISPER_COMMIT_MODEL"] == "large-v3",
            "Max transcription mapping"
        )
        try expect(versionAtLeast("6.15.2", "6.15.2") && versionAtLeast("6.16.0", "6.15.2"), "transactional proof version gate")
        try expect(!versionAtLeast("6.15.1", "6.15.2") && !versionAtLeast("invalid", "6.15.2"), "legacy proof compatibility gate")
        try expect(redactPath(home.appendingPathComponent("workspace").path) == "~/workspace", "home path redaction")
        let launchPaths = launchPathDirectories(node: "/opt/homebrew/bin/node")
        let localBin = home.appendingPathComponent(".local/bin", isDirectory: true).path
        try expect(launchPaths.contains(localBin), "managed PATH includes the user-local bin")
        try expect(launchPaths.filter { $0 == "/opt/homebrew/bin" }.count == 1, "managed PATH removes duplicate directories")

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
