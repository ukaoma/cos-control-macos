import AppKit
import Darwin
import Security
import CoreServices

final class ControlUILease {
    enum Failure: Error { case unavailable, alreadyOwned }
    private let descriptor: Int32

    init(url: URL) throws {
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let reason = errno
            Darwin.close(fd)
            if reason == EWOULDBLOCK { throw Failure.alreadyOwned }
            throw Failure.unavailable
        }
        descriptor = fd
    }

    deinit { Darwin.close(descriptor) }
}

/// Only the Control UI is exclusive. This lease never owns or stops the server.
/// Claim it before ControllerModel starts timers, helpers, hotkeys or windows.
@MainActor
final class ControlInstance {
    static let shared = ControlInstance()
    private var lease: ControlUILease?
    private var launchObserver: NSObjectProtocol?

    static func shouldReplaceLegacyCopy(current: URL, other: URL) -> Bool {
        current.standardizedFileURL.path == "/Applications/COS Control.app"
            && other.standardizedFileURL.path != current.standardizedFileURL.path
    }

    func claimOrExit() {
        // Isolated previews and native tests must never acquire the customer's lease.
        guard ProcessInfo.processInfo.environment["COS_CONTROL_TEST_HOME"] == nil,
              Bundle.main.bundleIdentifier == "com.gotcos.control" else { return }
        let current = Bundle.main.bundleURL.standardizedFileURL
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/COS Control", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { fail("Could not create the Control instance lease: \(error)") }
        do {
            lease = try ControlUILease(url: directory.appendingPathComponent("control-ui.lock"))
        } catch ControlUILease.Failure.alreadyOwned {
            // The other copy owns all UI work. Opening again brings it forward.
            trustedPeers().first?.activate(options: [.activateAllWindows])
            Darwin.exit(EXIT_SUCCESS)
        } catch { fail("Could not acquire the Control instance lease: \(error)") }

        for other in trustedPeers() {
            guard let otherURL = other.bundleURL,
                  Self.shouldReplaceLegacyCopy(current: current, other: otherURL) else {
                other.activate(options: [.activateAllWindows])
                Darwin.exit(EXIT_SUCCESS)
            }
            // An old backup predates the lease. Ask it to quit normally so its saves flush.
            // Never force-kill a copy, and never touch its managed server.
            other.terminate()
            let deadline = Date().addingTimeInterval(5)
            while !other.isTerminated && Date() < deadline { usleep(50_000) }
            guard other.isTerminated else {
                other.activate(options: [.activateAllWindows])
                Darwin.exit(EXIT_SUCCESS)
            }
        }

        // An unguarded legacy backup can be launched after us (for example by an old
        // login registration). Close only a verified copy of our own signed app.
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let pid, let other = NSRunningApplication(processIdentifier: pid),
                      self.isTrustedPeer(other) else { return }
                other.terminate()
            }
        }
        if current.path == "/Applications/COS Control.app" {
            _ = LSRegisterURL(current as CFURL, true)
        }
    }

    private func trustedPeers() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.gotcos.control")
            .filter { isTrustedPeer($0) }
    }

    private func isTrustedPeer(_ app: NSRunningApplication) -> Bool {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !app.isTerminated, app.bundleIdentifier == "com.gotcos.control",
              let url = app.bundleURL else { return false }
        var ownCode: SecStaticCode?
        var otherCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &ownCode) == errSecSuccess,
              let ownCode,
              SecCodeCopyDesignatedRequirement(ownCode, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(url as CFURL, [], &otherCode) == errSecSuccess,
              let otherCode else { return false }
        return SecStaticCodeCheckValidity(otherCode, [], requirement) == errSecSuccess
    }

    private func fail(_ message: String) -> Never {
        NSLog("COS Control: %@", message)
        Darwin.exit(EXIT_FAILURE)
    }
}
