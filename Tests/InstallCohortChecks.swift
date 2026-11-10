import Foundation

/// Lane D1 (0.5.387): InstallCohort and CohortDefault (Sources/InstallCohort.swift) and the Today home default
/// (TodayHome.enabled, Sources/Models.swift), executed. Compiled with those two files by Tests/run-install-cohort.sh.
/// Walks the launch table, the KeyLanes adoption, the lazy defaults, then the live probes against a throwaway home and
/// throwaway defaults suites. Prints "install cohort checks: N passed".
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
        let launch: (E) -> InstallCohort.Cohort? = InstallCohort.decideAtLaunch

        // ── Launch, a brand-new Mac: no answer yet, it waits for KeyLanes.
        check(launch(E(runningBuild: 441)) == nil, "a clean Mac waits for KeyLanes")
        check(launch(E(runningBuild: 441, lastSeenBuild: 441)) == nil, "this build's own last-seen value (written this launch) is not a prior install")

        // ── A kept answer always wins, both ways, whatever else is true.
        check(launch(E(stored: "existing", runningBuild: 441)) == .existing, "kept existing stays")
        check(launch(E(stored: "new", runningBuild: 441, lastSeenBuild: 439, priorSetupKey: true, keyLanesInstall: "new", runtimeFolder: true)) == .new,
              "kept new stays after setup, an update and a key lanes answer")
        check(launch(E(stored: "garbage", runningBuild: 441)) == nil, "an unreadable kept value is decided again")

        // ── Unsure: the running build is unreadable.
        check(launch(E(runningBuild: nil)) == .existing, "no build number: existing")
        check(launch(E(runningBuild: 0)) == .existing, "build 0: existing")

        // ── The lead's required case: a Mac carrying cos.keyLanes.install = new from an older build is EXISTING.
        check(launch(E(runningBuild: 441, keyLanesInstall: "new")) == .existing, "key lanes new from an older build: existing")
        check(launch(E(runningBuild: 441, keyLanesInstall: "existing")) == .existing, "key lanes existing from an older build: existing")
        // Every other sign of an earlier Control, alone.
        check(launch(E(runningBuild: 441, lastSeenBuild: 439)) == .existing, "an older build ran here (the 0.5.385 upgrade)")
        check(launch(E(runningBuild: 441, lastSeenBuild: 450)) == .existing, "a newer build ran here (a rollback)")
        check(launch(E(runningBuild: 441, priorSetupKey: true)) == .existing, "setup finished, hidden or past glasses")
        check(launch(E(runningBuild: 441, runtimeFolder: true)) == .existing, "a managed runtime folder")
        check(launch(E(runningBuild: 441, updaterRecord: true)) == .existing, "the updater swapped a build in")
        // Every combination of the five signs: waits only when all are absent.
        for mask in 0..<32 {
            let e = E(runningBuild: 441, lastSeenBuild: mask & 1 != 0 ? 439 : nil, priorSetupKey: mask & 2 != 0,
                      keyLanesInstall: mask & 4 != 0 ? "new" : nil, runtimeFolder: mask & 8 != 0, updaterRecord: mask & 16 != 0)
            check(launch(e) == (mask == 0 ? nil : .existing), "sign mask \(mask)")
        }

        // ── Adoption, when KeyLanes decides on this launch.
        check(InstallCohort.adopt(stored: nil, keyLanes: "new") == .new, "KeyLanes says new: keep new")
        check(InstallCohort.adopt(stored: nil, keyLanes: "existing") == .existing, "KeyLanes says existing: keep existing")
        check(InstallCohort.adopt(stored: nil, keyLanes: nil) == nil, "KeyLanes has not decided: keep nothing")
        check(InstallCohort.adopt(stored: nil, keyLanes: "maybe") == nil, "an unreadable KeyLanes answer: keep nothing")
        check(InstallCohort.adopt(stored: "existing", keyLanes: "new") == nil, "a kept existing is never turned new")
        check(InstallCohort.adopt(stored: "new", keyLanes: "existing") == nil, "a kept new is never turned existing")
        check(InstallCohort.adopt(stored: "garbage", keyLanes: "new") == .new, "an unreadable kept value takes KeyLanes' answer")

        // ── The lead's table as launches over one Mac's defaults: (cohort kept?, key lanes at launch?, KeyLanes' answer this launch).
        // Simulates the shipped app's two writers with the pure rules, so a quit at any point is a row.
        func simulate(_ steps: [(lanesAtLaunch: String?, classifiesAs: String?)], start: String? = nil) -> String? {
            var kept = start
            var lanes: String? = nil
            for step in steps {
                if let at = step.lanesAtLaunch { lanes = at }
                if let decided = launch(E(stored: kept, runningBuild: 441, keyLanesInstall: lanes)) { kept = decided.rawValue }
                if let answer = step.classifiesAs, lanes == nil {   // KeyLanes decides only once, on a launch where it is unset
                    lanes = answer
                    if let adopted = InstallCohort.adopt(stored: kept, keyLanes: answer) { kept = adopted.rawValue }
                }
            }
            return kept
        }
        check(simulate([(nil, "new")]) == "new", "table: fresh Mac, KeyLanes says new this launch: new")
        check(simulate([(nil, "existing")]) == "existing", "table: fresh-looking Mac, KeyLanes says existing: existing")
        check(simulate([(nil, nil)]) == nil, "table: quit before the status is known: nothing kept (reads existing)")
        check(simulate([(nil, nil), (nil, nil), (nil, "new")]) == "new", "table: two quits before status, then KeyLanes new: new")
        check(simulate([("new", nil)]) == "existing", "table: key lanes new stored by an older build: existing")
        check(simulate([("existing", nil)]) == "existing", "table: key lanes existing stored by an older build: existing")
        check(simulate([("new", "new")]) == "existing", "table: key lanes stored at launch, never re-decided: existing")
        check(simulate([(nil, "new"), (nil, nil)]) == "new", "table: new stays new on the next launch")
        check(simulate([(nil, nil)], start: "existing") == "existing" && simulate([(nil, "new")], start: "existing") == "existing",
              "table: a kept existing never turns new")
        check(InstallCohort.current(freshDefaults()) == .existing, "table: undecided reads as not new")

        // ── The kept answer; undecided reads as existing.
        let d = freshDefaults()
        check(InstallCohort.current(d) == .existing, "undecided reads as existing")
        d.set("new", forKey: InstallCohort.key)
        check(InstallCohort.current(d) == .new, "kept new reads as new")
        d.set("garbage", forKey: InstallCohort.key)
        check(InstallCohort.current(d) == .existing, "an unreadable kept value reads as existing")

        // ── Lazy defaults (CohortDefault's rule): the person's value first, else the cohort's.
        let value = CohortDefault.value
        check(value(nil, nil, true, false) == false, "undecided: the existing default (classic home)")
        check(value(nil, "existing", true, false) == false, "existing: the existing default")
        check(value(nil, "new", true, false) == true, "new: the new-install default (Today home)")
        check(value(false, "new", true, false) == false, "a new Mac that turned Today off stays off")
        check(value(true, "existing", true, false) == true, "an existing Mac that turned Today on keeps it")
        check(value(nil, "garbage", true, false) == false, "an unreadable cohort: the existing default")
        check(value(nil, "new", false, true) == false && value(nil, nil, false, true) == true, "the rule is general (new off, existing on)")

        // ── TodayHome.enabled (Models.swift), the non-view reader, follows the same rule and writes nothing.
        let t = freshDefaults()
        check(!TodayHome.enabled(t), "Today: undecided Mac, classic home")
        t.set("existing", forKey: InstallCohort.key)
        check(!TodayHome.enabled(t), "Today: existing Mac that never chose, classic home")
        t.set("new", forKey: InstallCohort.key)
        check(TodayHome.enabled(t), "Today: new Mac that never chose, Today home")
        check(t.object(forKey: TodayHome.enabledKey) == nil, "Today: reading wrote no value")
        t.set(false, forKey: TodayHome.enabledKey)
        check(!TodayHome.enabled(t), "Today: new Mac that turned it off")
        let upgraded = freshDefaults()
        upgraded.set("new", forKey: InstallCohort.keyLanesInstallKey)
        upgraded.set(439, forKey: InstallCohort.lastSeenBuildKey)
        check(launch(InstallCohort.liveEvidence(defaults: upgraded, home: URL(fileURLWithPath: "/nonexistent-cos-home"))) == .existing,
              "the lead's case, from live defaults: key lanes new from 0.5.385 decides existing")
        upgraded.set("existing", forKey: InstallCohort.key)
        check(!TodayHome.enabled(upgraded), "the lead's case: the upgraded Mac keeps the classic home")

        // ── Outside the shipped app: the writers write nothing.
        check(!InstallCohort.isShippedApp, "this harness is not the shipped app")
        let host = freshDefaults()
        check(InstallCohort.decideAtLaunch(defaults: host) == nil && host.object(forKey: InstallCohort.key) == nil, "a test host keeps no answer at launch")
        InstallCohort.adoptKeyLanes("new", defaults: host)
        check(host.object(forKey: InstallCohort.key) == nil, "a test host keeps no adopted answer")

        // ── Live probes read the right keys and folders (a throwaway home, never the real one).
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cos-install-cohort-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("Library/Application Support/COS Control", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let p = freshDefaults()
        var live = InstallCohort.liveEvidence(defaults: p, home: home)
        check(live.runningBuild == nil, "the harness has no CFBundleVersion")
        check(!live.runtimeFolder && !live.updaterRecord && !live.priorSetupKey && live.lastSeenBuild == nil && live.keyLanesInstall == nil,
              "an empty COS Control folder is no evidence (ControlInstance makes it at launch)")
        try? FileManager.default.createDirectory(at: support.appendingPathComponent("runtime"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: support.appendingPathComponent("updates"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: support.appendingPathComponent("updates/success.json").path, contents: Data("{}".utf8))
        p.set(439, forKey: InstallCohort.lastSeenBuildKey)
        p.set(true, forKey: "cos.setupGuide.hidden")
        p.set("existing", forKey: InstallCohort.keyLanesInstallKey)
        p.set("new", forKey: InstallCohort.key)
        live = InstallCohort.liveEvidence(defaults: p, home: home)
        check(live.runtimeFolder, "the runtime folder is seen")
        check(live.updaterRecord, "the updater record is seen")
        check(live.lastSeenBuild == 439, "the last-seen build is read")
        check(live.priorSetupKey, "a setup-guide key is seen")
        check(live.keyLanesInstall == "existing", "the key lanes answer is read")
        check(live.stored == "new", "the kept cohort is read")
        for key in InstallCohort.priorSetupKeys {
            let e = freshDefaults(); e.set(true, forKey: key)
            check(InstallCohort.liveEvidence(defaults: e, home: home).priorSetupKey, "\(key) counts as prior setup")
        }

        print("install cohort checks: \(passed) passed")
    }
}
