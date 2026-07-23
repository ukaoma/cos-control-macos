import Foundation
import Darwin
import Security

struct RuntimeManifest: Codable {
    var version: String
    var generationPath: String
    var workDirectory: String?
    var installedAt: String
    var previousVersions: [String]
}

struct CommandResult {
    let code: Int32
    let output: String
}

enum HelperError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let value): return value }
    }
}

final class COSControlHelper {
    private let fm = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let label = "com.cos.glasses-server"
    private let packageName = "@gotcos/glasses-server"

    private lazy var support = home.appendingPathComponent("Library/Application Support/COS Control", isDirectory: true)
    private lazy var runtimeRoot = support.appendingPathComponent("runtime", isDirectory: true)
    private lazy var generations = runtimeRoot.appendingPathComponent("generations", isDirectory: true)
    private lazy var manifestURL = runtimeRoot.appendingPathComponent("active.json")
    private lazy var stableBin = support.appendingPathComponent("bin", isDirectory: true)
    private lazy var stableHelper = stableBin.appendingPathComponent("cos-control-helper")
    private lazy var logs = home.appendingPathComponent("Library/Logs/COS Glasses", isDirectory: true)
    private lazy var helperLog = logs.appendingPathComponent("control.log")
    private lazy var serverLog = logs.appendingPathComponent("server.log")
    private lazy var serverErrorLog = logs.appendingPathComponent("server-error.log")
    private lazy var plistURL = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    private lazy var configDir = home.appendingPathComponent(".cos-glasses", isDirectory: true)
    private lazy var envURL = configDir.appendingPathComponent(".env")

    func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { throw HelperError.message("missing command") }
        switch command {
        case "status": emit(ok: true, message: "Status refreshed", details: statusDetails())
        case "doctor": emit(ok: true, message: "Doctor complete", details: doctorDetails())
        case "install":
            let requested = option("--version", in: args) ?? "latest"
            let work = option("--workdir", in: args)
            try install(requestedVersion: requested, workDirectory: work)
        case "update": try install(requestedVersion: "latest", workDirectory: loadManifest()?.workDirectory)
        case "start": try start()
        case "stop": try stop()
        case "restart": try restart()
        case "rollback": try rollback()
        case "set-workdir":
            guard let value = args.dropFirst().first else { throw HelperError.message("missing work directory") }
            try setWorkDirectory(value)
        case "token": emit(ok: true, message: "Pairing token loaded", details: ["token": try readToken()])
        case "report": emit(ok: true, message: "Redacted report ready", details: ["report": redactedReport()])
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

    private func fail(_ message: String) -> Never {
        emit(ok: false, message: message)
        exit(1)
    }

    private func ensureDirectories() throws {
        for url in [support, runtimeRoot, generations, stableBin, logs, configDir, plistURL.deletingLastPathComponent()] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }

    private func findExecutable(_ name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)",
            "/usr/bin/\(name)", "/bin/\(name)",
            home.appendingPathComponent(".local/bin/\(name)").path,
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    private func execute(_ executable: String, _ arguments: [String], log: Bool = false,
                         environment: [String: String]? = nil) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if log {
            try ensureDirectories()
            if !fm.fileExists(atPath: helperLog.path) { fm.createFile(atPath: helperLog.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: helperLog)
            try handle.seekToEnd()
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            process.waitUntilExit()
            try handle.close()
            return CommandResult(code: process.terminationStatus, output: "")
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        return CommandResult(code: process.terminationStatus, output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func loadManifest() -> RuntimeManifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(RuntimeManifest.self, from: data)
    }

    private func saveManifest(_ manifest: RuntimeManifest) throws {
        try ensureDirectories()
        let data = try JSONEncoder().encode(manifest)
        let temporary = manifestURL.appendingPathExtension("tmp")
        try data.write(to: temporary, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fm.fileExists(atPath: manifestURL.path) { try fm.removeItem(at: manifestURL) }
        try fm.moveItem(at: temporary, to: manifestURL)
    }

    private func resolveVersion(_ requested: String) throws -> String {
        if requested != "latest" {
            guard requested.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else {
                throw HelperError.message("invalid server version")
            }
            return requested
        }
        guard let npm = findExecutable("npm") else { throw HelperError.message("Node/npm not found. Install Node.js 20.11 or newer.") }
        let result = try execute(npm, ["view", packageName, "version", "--json"])
        guard result.code == 0 else { throw HelperError.message("could not resolve the latest npm server version") }
        let value = result.output.trimmingCharacters(in: CharacterSet(charactersIn: "\"\n "))
        guard value.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else {
            throw HelperError.message("npm returned an invalid server version")
        }
        return value
    }

    private func install(requestedVersion: String, workDirectory: String?) throws {
        try ensureDirectories()
        if unknownPortOwner() { throw HelperError.message("Ports 3141/3143 are owned by another server. Stop the foreground server, then retry.") }
        if serviceLoaded(), isServerReachable() {
            try requireSafeRestart()
            try unloadService()
        }
        guard let npm = findExecutable("npm") else { throw HelperError.message("Node/npm not found. Install Node.js 20.11 or newer.") }
        let version = try resolveVersion(requestedVersion)
        let generation = generations.appendingPathComponent(version, isDirectory: true)
        if !fm.fileExists(atPath: generation.appendingPathComponent("node_modules/@gotcos/glasses-server/bin/managed-server.cjs").path) {
            try fm.createDirectory(at: generation, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let result = try execute(npm, [
                "install", "--prefix", generation.path, "--ignore-scripts", "--omit=dev",
                "--no-audit", "--no-fund", "\(packageName)@\(version)",
            ], log: true)
            guard result.code == 0 else { throw HelperError.message("npm server installation failed. Open the COS Control log for details.") }
        }
        let launcher = generation.appendingPathComponent("node_modules/@gotcos/glasses-server/bin/managed-server.cjs")
        guard fm.isReadableFile(atPath: launcher.path) else { throw HelperError.message("managed server launcher is missing from the npm package") }
        try installStableHelper()
        try ensureConfig()
        let old = loadManifest()
        let previous = ([old?.version].compactMap { $0 } + (old?.previousVersions ?? [])).filter { $0 != version }
        let manifest = RuntimeManifest(
            version: version,
            generationPath: generation.path,
            workDirectory: try validatedWorkDirectory(workDirectory),
            installedAt: ISO8601DateFormatter().string(from: Date()),
            previousVersions: Array(previous.prefix(2))
        )
        try saveManifest(manifest)
        try writeLaunchAgent()
        try loadService()
        cleanupGenerations(keeping: Set([version] + manifest.previousVersions))
        emit(ok: true, message: "COS Glasses Server \(version) installed and started", details: statusDetails())
    }

    private func installStableHelper() throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let destination = stableHelper.standardizedFileURL
        if source.path != destination.path {
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: source, to: destination)
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
    }

    private func validatedWorkDirectory(_ value: String?) throws -> String? {
        guard let value, !value.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: value, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw HelperError.message("selected work folder does not exist")
        }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }

    private func ensureConfig() throws {
        if fm.fileExists(atPath: envURL.path) {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envURL.path)
            return
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw HelperError.message("could not generate a pairing token")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let content = "# Generated by COS Control\nCOS_API_TOKEN=\(token)\nBIND_HOST=0.0.0.0\nCOS_DURABLE_QUERY_JOBS=1\n"
        try content.write(to: envURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envURL.path)
    }

    private func writeLaunchAgent() throws {
        guard let node = findExecutable("node") else { throw HelperError.message("Node.js not found") }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [stableHelper.path, "run-server"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            "ProcessType": "Interactive",
            "StandardOutPath": serverLog.path,
            "StandardErrorPath": serverErrorLog.path,
            "EnvironmentVariables": [
                "PATH": [nodeURL(node).deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":"),
                "HOME": home.path,
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)
    }

    private func nodeURL(_ path: String) -> URL { URL(fileURLWithPath: path) }

    private func launchctl(_ arguments: [String]) throws -> CommandResult {
        try execute("/bin/launchctl", arguments)
    }

    private var launchDomain: String { "gui/\(getuid())" }
    private var serviceTarget: String { "\(launchDomain)/\(label)" }

    private func serviceLoaded() -> Bool {
        (try? launchctl(["print", serviceTarget]).code) == 0
    }

    private func loadService() throws {
        if serviceLoaded() {
            let result = try launchctl(["kickstart", "-k", serviceTarget])
            guard result.code == 0 else { throw HelperError.message("launchd could not restart COS") }
        } else {
            let result = try launchctl(["bootstrap", launchDomain, plistURL.path])
            guard result.code == 0 else { throw HelperError.message("launchd could not install COS") }
        }
    }

    private func unloadService() throws {
        guard serviceLoaded() else { return }
        let result = try launchctl(["bootout", serviceTarget])
        guard result.code == 0 else { throw HelperError.message("launchd could not stop COS") }
    }

    private func start() throws {
        guard loadManifest() != nil, fm.fileExists(atPath: plistURL.path) else {
            throw HelperError.message("Install the managed server first")
        }
        if unknownPortOwner() { throw HelperError.message("Another process owns the COS ports") }
        try loadService()
        emit(ok: true, message: "COS server started", details: statusDetails())
    }

    private func stop() throws {
        try requireSafeRestart()
        try unloadService()
        emit(ok: true, message: "COS server stopped", details: statusDetails())
    }

    private func restart() throws {
        try requireSafeRestart()
        guard serviceLoaded() else { try start(); return }
        let result = try launchctl(["kickstart", "-k", serviceTarget])
        guard result.code == 0 else { throw HelperError.message("launchd restart failed") }
        emit(ok: true, message: "COS server restarted", details: statusDetails())
    }

    private func rollback() throws {
        guard var manifest = loadManifest(), let prior = manifest.previousVersions.first else {
            throw HelperError.message("No retained server generation is available")
        }
        try requireSafeRestart()
        let priorPath = generations.appendingPathComponent(prior).path
        guard fm.fileExists(atPath: URL(fileURLWithPath: priorPath).appendingPathComponent("node_modules/@gotcos/glasses-server/bin/managed-server.cjs").path) else {
            throw HelperError.message("The retained generation is incomplete")
        }
        let current = manifest.version
        manifest.version = prior
        manifest.generationPath = priorPath
        manifest.previousVersions = [current] + Array(manifest.previousVersions.dropFirst())
        try saveManifest(manifest)
        try restart()
    }

    private func setWorkDirectory(_ path: String) throws {
        guard var manifest = loadManifest() else { throw HelperError.message("Install the managed server first") }
        manifest.workDirectory = try validatedWorkDirectory(path)
        try saveManifest(manifest)
        emit(ok: true, message: "Work folder saved. Restart when no work is active to apply it.", details: statusDetails())
    }

    private func runServer() throws {
        guard let manifest = loadManifest(), let node = findExecutable("node") else { exit(78) }
        let launcher = URL(fileURLWithPath: manifest.generationPath).appendingPathComponent("node_modules/@gotcos/glasses-server/bin/managed-server.cjs")
        guard fm.isReadableFile(atPath: launcher.path) else { exit(78) }
        var environment = ProcessInfo.processInfo.environment
        environment["COS_MANAGED"] = "1"
        environment["COS_SERVER_VERSION"] = manifest.version
        if let work = manifest.workDirectory { environment["COS_WORKDIR"] = work }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [launcher.path]
        process.environment = environment
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        term.setEventHandler { if process.isRunning { process.terminate() } }
        interrupt.setEventHandler { if process.isRunning { process.interrupt() } }
        term.resume(); interrupt.resume()
        try process.run()
        process.waitUntilExit()
        exit(process.terminationStatus)
    }

    private func request(_ path: String, token: String? = nil) -> [String: Any]? {
        var arguments = ["--fail", "--silent", "--show-error", "--max-time", "3"]
        if let token { arguments += ["--header", "x-cos-token: \(token)"] }
        arguments.append("http://127.0.0.1:3141\(path)")
        guard let response = try? execute("/usr/bin/curl", arguments), response.code == 0,
              let data = response.output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private func statusDetails() -> [String: Any] {
        let manifest = loadManifest()
        let health = request("/api/health")
        let token = try? readToken()
        let maintenance = token.flatMap { request("/api/maintenance/status", token: $0) }
        return [
            "installed": manifest != nil,
            "serviceLoaded": serviceLoaded(),
            "running": health != nil,
            "managedContract": maintenance != nil,
            "version": maintenance?["serverVersion"] ?? manifest?.version ?? NSNull(),
            "installedVersion": manifest?.version ?? NSNull(),
            "workDirectory": manifest?.workDirectory ?? NSNull(),
            "safeToRestart": maintenance?["safeToRestart"] ?? false,
            "activeJobs": maintenance?["activeJobs"] ?? NSNull(),
            "activeTranscriptionSessions": maintenance?["activeTranscriptionSessions"] ?? NSNull(),
            "whisperReady": ((health?["whisper_health"] as? [String: Any])?["server"] as? Bool) ?? false,
            "apiURL": "http://127.0.0.1:3141",
        ]
    }

    private func isServerReachable() -> Bool { request("/api/health") != nil }

    private func requireSafeRestart() throws {
        guard isServerReachable() else { return }
        guard let token = try? readToken(), let status = request("/api/maintenance/status", token: token) else {
            throw HelperError.message("The running server does not expose managed restart safety. Stop the foreground server manually first.")
        }
        guard status["safeToRestart"] as? Bool == true else {
            let jobs = status["activeJobs"] ?? "?"
            let recordings = status["activeTranscriptionSessions"] ?? "?"
            throw HelperError.message("Restart blocked: \(jobs) active job(s), \(recordings) active recording session(s).")
        }
    }

    private func portPIDs() -> [String] {
        guard fm.isExecutableFile(atPath: "/usr/sbin/lsof") else { return [] }
        var values = Set<String>()
        for port in [3141, 3143] {
            if let result = try? execute("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]), result.code == 0 {
                result.output.split(separator: "\n").forEach { values.insert(String($0)) }
            }
        }
        return values.sorted()
    }

    private func unknownPortOwner() -> Bool { !portPIDs().isEmpty && !serviceLoaded() }

    private func readToken() throws -> String {
        let content = try String(contentsOf: envURL, encoding: .utf8)
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("COS_API_TOKEN=") { return String(line.dropFirst("COS_API_TOKEN=".count)).trimmingCharacters(in: .whitespaces) }
        }
        throw HelperError.message("No pairing token is configured")
    }

    private func doctorDetails() -> [String: Any] {
        var checks: [[String: Any]] = []
        func add(_ name: String, _ state: String, _ detail: String) {
            checks.append(["name": name, "state": state, "detail": detail])
        }
        add("Node.js", findExecutable("node") == nil ? "error" : "ok", findExecutable("node") ?? "Not found")
        add("npm", findExecutable("npm") == nil ? "error" : "ok", findExecutable("npm") ?? "Not found")
        add("Claude CLI", findExecutable("claude") == nil ? "warning" : "ok", findExecutable("claude") ?? "Not installed")
        add("Codex CLI", findExecutable("codex") == nil ? "warning" : "ok", findExecutable("codex") ?? "Not installed")
        add("Whisper", findExecutable("whisper-cli") == nil ? "warning" : "ok", findExecutable("whisper-cli") ?? "Not installed")
        add("ffmpeg", findExecutable("ffmpeg") == nil ? "warning" : "ok", findExecutable("ffmpeg") ?? "Not installed")
        let portDetail = portPIDs().isEmpty ? "Clear" : (serviceLoaded() ? "Owned by the COS LaunchAgent" : "Owned by another process")
        add("Server ports", unknownPortOwner() ? "error" : "ok", portDetail)
        add("Private config", fm.fileExists(atPath: envURL.path) ? "ok" : "warning", fm.fileExists(atPath: envURL.path) ? "Configured" : "Run guided setup")
        add("Managed API", (statusDetails()["managedContract"] as? Bool) == true ? "ok" : "warning", (statusDetails()["managedContract"] as? Bool) == true ? "Connected" : "Not connected")
        return ["checks": checks, "status": statusDetails()]
    }

    private func redactedReport() -> String {
        let doctor = doctorDetails()
        let data = try? JSONSerialization.data(withJSONObject: doctor, options: [.prettyPrinted, .sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "COS Control report unavailable"
    }

    private func cleanupGenerations(keeping: Set<String>) {
        guard let entries = try? fm.contentsOfDirectory(at: generations, includingPropertiesForKeys: nil) else { return }
        for entry in entries where !keeping.contains(entry.lastPathComponent) {
            try? fm.removeItem(at: entry)
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
