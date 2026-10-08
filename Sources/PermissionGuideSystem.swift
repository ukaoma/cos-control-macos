import AppKit
import ApplicationServices
import CoreServices
import ServiceManagement
import UserNotifications

// The permission guide's live probes: the only place it reads TCC state, launchd or Spotlight. Nothing here prompts
// unless a row's action asked it to (requestNotifications, automation with ask: true).

extension PermissionProbes {
    /// `home` is the real home: the guide reads LaunchAgents and Logs there.
    static func live(home: String = NSHomeDirectory()) -> PermissionProbes {
        PermissionProbes(
            accessibilityTrusted: { AXIsProcessTrusted() },
            notifications: {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                switch settings.authorizationStatus {
                case .notDetermined: return .notDetermined
                case .denied: return .denied
                case .authorized, .provisional: return .allowed(alertsOn: settings.alertSetting == .enabled)
                @unknown default: return .unknown
                }
            },
            requestNotifications: {
                (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            },
            loginItem: {
                switch SMAppService.mainApp.status {
                case .enabled: return .enabled
                case .requiresApproval: return .requiresApproval
                default: return .off
                }
            },
            launchJobs: { await PermissionSystem.launchJobs(home: home) },
            installedApp: { id in NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.path },
            automation: { id, ask in await PermissionSystem.automation(bundleID: id, ask: ask) },
            calendarAppPath: { PermissionSystem.calendarAppPath(home: home) },
            calendar: { PermissionSystem.calendarFact(home: home) },
            staleBuilds: { running in
                let output = await PermissionSystem.run("/usr/bin/mdfind", ["-attr", "kMDItemCFBundleIdentifier", StaleBuilds.spotlightQuery])
                return StaleBuilds.parse(output.text, runningID: running)
            },
            resetAccessibility: { id in
                await PermissionSystem.run("/usr/bin/tccutil", ["reset", "Accessibility", id]).status == 0
            },
            kickstart: { label in
                _ = await PermissionSystem.run("/bin/launchctl", ["kickstart", "gui/\(getuid())/\(label)"])
            })
    }
}

/// Lets the timeout stop a tool from another queue. Process is used only through these two calls there.
private final class RunningProcess: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    func stopIfRunning() { if process.isRunning { process.terminate() } }
}

enum PermissionSystem {
    struct Output: Sendable { let status: Int32; let text: String }

    /// Runs a tool off the main thread and returns its exit status and stdout. Never through a shell.
    static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 15) async -> Output {
        await withCheckedContinuation { (continuation: CheckedContinuation<Output, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: Output(status: -1, text: ""))
                    return
                }
                let running = RunningProcess(process)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { running.stopIfRunning() }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Output(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// Every com.cos.* LaunchAgent with the interpreter it really runs and launchd's record of its last run.
    static func launchJobs(home: String) async -> [LaunchJob] {
        let folder = URL(fileURLWithPath: home).appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter(LaunchdParse.isCOSAgentFile).sorted()
        var jobs: [LaunchJob] = []
        for name in names {
            guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent(name).path),
                  let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let label = plist["Label"] as? String else { continue }
            var arguments = plist["ProgramArguments"] as? [String] ?? []
            if let program = plist["Program"] as? String, arguments.first != program { arguments.insert(program, at: 0) }
            guard let interpreter = LaunchdParse.interpreter(arguments) else { continue }
            let environment = plist["EnvironmentVariables"] as? [String: String] ?? [:]
            var job = LaunchJob(
                label: label, interpreter: interpreter,
                readsProtectedFolder: LaunchdParse.readsProtectedFolder(
                    arguments: arguments, environment: environment,
                    workingDirectory: plist["WorkingDirectory"] as? String, home: home))
            if job.readsProtectedFolder {
                let printed = await run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"], timeout: 5)
                if printed.status == 0 {
                    let service = LaunchdParse.service(printed.text)
                    job.running = service.running
                    job.runs = service.runs
                    job.lastExit = service.lastExit
                }
            }
            jobs.append(job)
        }
        return jobs
    }

    /// AEDeterminePermissionToAutomateTarget for one app. With `ask` false it never prompts; with true it shows the
    /// prompt for that app (off the main thread: the call waits for the answer).
    static func automation(bundleID: String, ask: Bool) async -> AutomationFact {
        await withCheckedContinuation { (continuation: CheckedContinuation<AutomationFact, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var address = AEAddressDesc()
                let bytes = Array(bundleID.utf8)
                let created = bytes.withUnsafeBytes { buffer in
                    AECreateDesc(DescType(typeApplicationBundleID), buffer.baseAddress, buffer.count, &address)
                }
                guard created == OSErr(noErr) else {
                    continuation.resume(returning: .unknown(Int32(created)))
                    return
                }
                let status = AEDeterminePermissionToAutomateTarget(&address, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
                _ = AEDisposeDesc(&address)
                continuation.resume(returning: AutomationFact(osStatus: Int32(status)))
            }
        }
    }

    /// The calendar-cache job's own LaunchAgent names the scripts folder; CalendarFetch.app sits in its bin/.
    /// Read as a string only: nothing here opens a file under Documents.
    static func calendarAppPath(home: String) -> String? {
        guard let plist = agentPlist("com.cos.calendar-cache-refresh", home: home) else { return nil }
        let arguments = plist["ProgramArguments"] as? [String] ?? []
        let words = arguments.flatMap(LaunchdParse.shellWords)
        guard let script = words.first(where: { $0.hasSuffix("/refresh_calendar_cache.py") }) else { return nil }
        return (script as NSString).deletingLastPathComponent + "/bin/CalendarFetch.app"
    }

    /// CalendarFetch's last answer, from the log the job's LaunchAgent writes (under ~/Library/Logs, never Documents).
    static func calendarFact(home: String) -> CalendarFact {
        guard let plist = agentPlist("com.cos.calendar-cache-refresh", home: home),
              let log = (plist["StandardOutPath"] as? String) ?? (plist["StandardErrorPath"] as? String),
              !LaunchdParse.isProtected(log, home: home),
              let handle = FileHandle(forReadingAtPath: log) else { return .unknown }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 16_384 ? size - 16_384 : 0)
        let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        return CalendarFetchLog.status(tail)
    }

    static func agentPlist(_ label: String, home: String) -> [String: Any]? {
        let path = home + "/Library/LaunchAgents/\(label).plist"
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// The file a background-jobs drag adds: the interpreter itself, with a venv's symlink followed to the binary
    /// macOS checks. Resolved only when the person starts the drag.
    static func resolvedInterpreter(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
