import Foundation

@main struct OnboardingChecks {
    static func main() {
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name)
        }
        check(!ServerStatus().needsFirstRun, "Unknown is not a fresh install")
        var fresh = ServerStatus(["runtimeState": .string("notInstalled"), "launchAgentKind": .string("absent")])
        check(fresh.needsFirstRun, "Proven absence opens setup")
        for state in ["managedHealthy", "managedDegraded", "managedInPlace", "legacyStopped", "legacyService", "legacyForeground", "ownerConflict", "stopped", "unknown"] {
            var value = fresh
            value.runtimeState = state
            check(!value.needsFirstRun, "Existing state must not be adopted: \(state)")
        }
        for key in ["installed", "running", "serviceLoaded", "ownerConflict", "transactionPending"] {
            let value = ServerStatus(["runtimeState": .string("notInstalled"), "launchAgentKind": .string("absent"), key: .bool(true)])
            check(!value.needsFirstRun, "Contradictory evidence blocks setup: \(key)")
        }
        for kind in ["cosControl", "knownLegacy", "unknown"] {
            fresh.launchAgentKind = kind
            check(!fresh.needsFirstRun, "Foreign or existing LaunchAgent blocks setup")
        }
        check(!ServerStatus([:]).setupProviderInstalled, "Missing provider is not ready")
        check(ServerStatus(["setupProviderInstalled": .bool(true)]).setupProviderInstalled, "Provider preflight decodes")
        print("PASS: 21 first-run state checks")
    }
}
