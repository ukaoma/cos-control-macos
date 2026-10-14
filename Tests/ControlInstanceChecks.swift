import Foundation
import Darwin

@main
struct ControlInstanceChecks {
    @MainActor static func main() throws {
        let args = CommandLine.arguments
        if args.count == 3 && args[1] == "contend" {
            do {
                let lease = try ControlUILease(url: URL(fileURLWithPath: args[2]))
                withExtendedLifetime(lease) { Darwin.exit(9) }
            } catch ControlUILease.Failure.alreadyOwned { Darwin.exit(0) }
            catch { Darwin.exit(10) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("control-instance-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = root.appendingPathComponent("ui.lock")
        var owner: ControlUILease? = try ControlUILease(url: lock)
        let contender = Process()
        contender.executableURL = URL(fileURLWithPath: args[0])
        contender.arguments = ["contend", lock.path]
        try contender.run(); contender.waitUntilExit()
        precondition(contender.terminationStatus == 0, "second process acquired a live UI lease")
        withExtendedLifetime(owner) {}
        owner = nil
        // An ordinary exit or crash closes the descriptor; a stale file never strands startup.
        let next = try ControlUILease(url: lock)
        withExtendedLifetime(next) {}
        let symlink = root.appendingPathComponent("symlink.lock")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: lock)
        do { _ = try ControlUILease(url: symlink); preconditionFailure("followed a symlink") }
        catch ControlUILease.Failure.unavailable {}
        let live = URL(fileURLWithPath: "/Applications/COS Control.app")
        let backup = URL(fileURLWithPath: "/Applications/COS Control Previous.app")
        precondition(ControlInstance.shouldReplaceLegacyCopy(current: live, other: backup))
        precondition(!ControlInstance.shouldReplaceLegacyCopy(current: backup, other: live))
        precondition(!ControlInstance.shouldReplaceLegacyCopy(current: live, other: live))
        print("Control instance checks passed: cross-process exclusion, release, symlink refusal, legacy-copy policy")
    }
}
