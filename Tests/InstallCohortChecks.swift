import Foundation

/// Lane D1 (0.5.387): InstallCohort (Sources/InstallCohort.swift), executed. Compiled with that file alone by
/// Tests/run-install-cohort.sh. Walks the whole decision table, then the live probes against a throwaway home and a
/// throwaway defaults suite. Prints "install cohort checks: N passed".
@main struct InstallCohortChecks {
    nonisolated(unsafe) static var passed = 0

    static func check(_ condition: Bool, _ what: String) {
        guard condition else { print("install cohort check FAILED: \(what)"); exit(1) }
        passed += 1
    }

    static func freshDefaults() -> UserDefaults {
        let name = "cos.install-cohort-checks.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    typealias E = InstallCohort.Evidence

    static func main() {
        let decide = InstallCohort.decide

        // ── A brand-new Mac: this build running, nothing else. The ONLY row that answers new.
        let clean = E(runningBuild: 441)
        check(decide(clean) == .new, "a clean Mac is new")
        // This launch already wrote its own build as last seen (ControllerModel's init runs first): still new.
        check(decide(E(runningBuild: 441, lastSeenBuild: 441)) == .new, "this build's own last-seen value is not a prior install")

        // ── A stored answer always wins, both ways, whatever else is true.
        check(decide(E(stored: "existing", runningBuild: 441)) == .existing, "stored existing is kept on a clean-looking Mac")
        check(decide(E(stored: "new", runningBuild: 441, lastSeenBuild: 439, priorSetupKey: true, runtimeFolder: true)) == .new,
              "stored new is kept after the user finishes setup")
        check(decide(E(stored: "garbage", runningBuild: 441)) == .new, "an unreadable stored value is decided again")
        check(decide(E(stored: "garbage", runningBuild: 441, runtimeFolder: true)) == .existing, "an unreadable stored value is decided again (existing)")

        // ── Unsure: the running build is unreadable.
        check(decide(E(runningBuild: nil)) == .existing, "no build number: existing")
        check(decide(E(runningBuild: 0)) == .existing, "build 0: existing")

        // ── Each prior-Control signal alone makes it existing.
        check(decide(E(runningBuild: 441, lastSeenBuild: 439)) == .existing, "an older build ran here (the 0.5.385 upgrade)")
        check(decide(E(runningBuild: 441, lastSeenBuild: 450)) == .existing, "a newer build ran here (a rollback)")
        check(decide(E(runningBuild: 441, priorSetupKey: true)) == .existing, "setup finished, hidden or past glasses")
        check(decide(E(runningBuild: 441, keyLanesInstall: "new")) == .existing, "key lanes decided on an earlier launch (new)")
        check(decide(E(runningBuild: 441, keyLanesInstall: "existing")) == .existing, "key lanes decided on an earlier launch (existing)")
        check(decide(E(runningBuild: 441, runtimeFolder: true)) == .existing, "a managed runtime folder")
        check(decide(E(runningBuild: 441, updaterRecord: true)) == .existing, "the updater swapped a build in")

        // ── Every combination of the five signals: new only when all are absent.
        for mask in 0..<32 {
            let e = E(runningBuild: 441, lastSeenBuild: mask & 1 != 0 ? 439 : nil, priorSetupKey: mask & 2 != 0,
                      keyLanesInstall: mask & 4 != 0 ? "new" : nil, runtimeFolder: mask & 8 != 0, updaterRecord: mask & 16 != 0)
            check(decide(e) == (mask == 0 ? .new : .existing), "signal mask \(mask)")
        }

        // ── Outside the shipped app: existing, and nothing written.
        check(!InstallCohort.isShippedApp, "this harness is not the shipped app")
        let d = freshDefaults()
        check(InstallCohort.current(defaults: d) == .existing, "a test host answers existing")
        check(d.object(forKey: InstallCohort.key) == nil, "a test host writes no cohort")
        check(!InstallCohort.isNewInstall, "isNewInstall is false in a test host")

        // ── Live probes read the right keys and folders (a throwaway home, never the real one).
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cos-install-cohort-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("Library/Application Support/COS Control", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        var live = InstallCohort.liveEvidence(defaults: d, home: home)
        check(live.runningBuild == nil, "the harness has no CFBundleVersion")
        check(!live.runtimeFolder && !live.updaterRecord && !live.priorSetupKey && live.lastSeenBuild == nil && live.keyLanesInstall == nil,
              "an empty COS Control folder is no evidence (ControlInstance makes it at launch)")
        try? FileManager.default.createDirectory(at: support.appendingPathComponent("runtime"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: support.appendingPathComponent("updates"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: support.appendingPathComponent("updates/success.json").path, contents: Data("{}".utf8))
        d.set(439, forKey: "cos.whatsNew.lastSeenBuild")
        d.set(true, forKey: "cos.setupGuide.hidden")
        d.set("existing", forKey: "cos.keyLanes.install")
        d.set("new", forKey: InstallCohort.key)
        live = InstallCohort.liveEvidence(defaults: d, home: home)
        check(live.runtimeFolder, "the runtime folder is seen")
        check(live.updaterRecord, "the updater record is seen")
        check(live.lastSeenBuild == 439, "the last-seen build is read")
        check(live.priorSetupKey, "a setup-guide key is seen")
        check(live.keyLanesInstall == "existing", "the key lanes answer is read")
        check(live.stored == "new", "the stored cohort is read")
        for key in InstallCohort.priorSetupKeys {
            let e = freshDefaults(); e.set(true, forKey: key)
            check(InstallCohort.liveEvidence(defaults: e, home: home).priorSetupKey, "\(key) counts as prior setup")
        }

        print("install cohort checks: \(passed) passed")
    }
}
