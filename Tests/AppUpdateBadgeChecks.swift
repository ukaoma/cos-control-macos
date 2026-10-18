import AppKit
import Foundation

/// 2026-10-09 (Miles, like Vorssant): the update-ready badge, executed against Sources/Models.swift alone. The version
/// rule, the check schedule, the banner's phases and the menu-bar icon that follows them. No helper, no network, no
/// window, no status item. Every failure names the behaviour it guards as "check failed [<behaviour>]", which is what
/// Tests/mutate-app-update-badge.py matches a killing failure against.
@main @MainActor struct AppUpdateBadgeChecks {
    static var passed = 0

    static func check(_ condition: Bool, _ behaviour: String, _ detail: String = "") {
        guard condition else {
            print("check failed [\(behaviour)]: \(detail)")
            exit(1)
        }
        passed += 1
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        versions()
        schedule()
        flow()
        icon()
        progressAndDeadline()
        finishAndEscalation()
        print("PASS: update-ready badge, \(passed) checks (version rule, schedule, phases, menu-bar icon, finish installing)")
    }

    static func info(_ available: Bool, _ version: String?, _ build: Int?, reason: String? = nil) -> AppUpdateInfo {
        var details: [String: JSONValue] = ["updateAvailable": .bool(available), "reason": .string(reason ?? (available ? "newer" : "upToDate"))]
        if let version { details["latestVersion"] = .string(version) }
        if let build { details["latestBuild"] = .number(Double(build)) }
        return AppUpdateInfo(details)
    }

    // MARK: version rule

    static func versions() {
        check(AppUpdateVersion.components("0.5.273") == [0, 5, 273], "version parse", "0.5.273")
        check(AppUpdateVersion.components(" 1.2 ") == [1, 2], "version parse", "spaces trimmed")
        for bad in ["", "0.5.", ".5", "0..5", "v0.5.274", "0.5.x", "0.5.-1", "0.5.274-beta", "٣.1", "1234567890.1"] {
            check(AppUpdateVersion.components(bad) == nil, "version malformed", "\"\(bad)\" must not parse")
        }
        check(AppUpdateVersion.compare("0.5.274", "0.5.273") == .orderedDescending, "version order", "274 > 273")
        check(AppUpdateVersion.compare("0.5.10", "0.5.9") == .orderedDescending, "version order", "numeric, not text")
        check(AppUpdateVersion.compare("0.6", "0.5.999") == .orderedDescending, "version order", "minor beats patch")
        check(AppUpdateVersion.compare("0.5", "0.5.0") == .orderedSame, "version order", "missing reads 0")
        check(AppUpdateVersion.compare("0.5.0", "0.5") == .orderedSame, "version order", "missing reads 0, either side")
        check(AppUpdateVersion.compare("0.5.1", "0.5") == .orderedDescending, "version order", "0.5.1 is newer than 0.5")
        check(AppUpdateVersion.compare("0.5", "0.5.1") == .orderedAscending, "version order", "0.5 is older than 0.5.1")
        check(AppUpdateVersion.compare("0.5.272", "0.5.273") == .orderedAscending, "version order", "older")
        check(AppUpdateVersion.compare("0.5.x", "0.5.273") == nil, "version malformed", "compare refuses")

        let current = ("0.5.273", 326)
        func newer(_ v: String?, _ b: Int?) -> Bool {
            AppUpdateVersion.isNewer(latestVersion: v, latestBuild: b, currentVersion: current.0, currentBuild: current.1)
        }
        check(newer("0.5.274", 327), "build newer", "a newer build is an update")
        check(!newer("0.5.273", 326), "build equal", "the same build is not an update")
        check(!newer("0.5.272", 325), "build older", "an older appcast is not an update")
        check(newer("0.5.273", 327), "build authoritative", "a rebuild of the same version is an update")
        check(!newer("0.5.280", 320), "build authoritative", "a higher version with a lower build is a rollback, not an update")
        check(newer("0.5.274", nil), "version without build", "no build: the version decides")
        check(!newer("0.5.273", nil), "version without build", "equal version, no build")
        check(!newer("0.5.200", nil), "version without build", "older version, no build")
        check(!newer(nil, 400), "offer malformed", "no version is never an update")
        check(!newer("", 400), "offer malformed", "an empty version is never an update")
        check(!newer("0.5.x", 400), "offer malformed", "a malformed version is never an update")
        check(!AppUpdateVersion.isNewer(latestVersion: "0.5.274", latestBuild: nil, currentVersion: "dev", currentBuild: 0),
              "offer malformed", "a running version that does not parse and no build: not newer")
    }

    // MARK: schedule

    static func schedule() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var s = AppUpdateCheckSchedule()
        check(s.nextNap(now: t0) == 1, "schedule launch", "before any check the loop does not wait")
        check(s.shouldStart(.panelOpen, now: t0) && s.shouldStart(.periodic, now: t0), "schedule launch", "nothing checked yet: every trigger may run")
        check(s.begin(.launch, now: t0), "schedule launch", "launch checks")
        // No overlap.
        for trigger in [AppUpdateCheckSchedule.Trigger.launch, .periodic, .panelOpen, .manual] {
            check(!s.begin(trigger, now: t0.addingTimeInterval(7 * 3600)), "schedule no overlap", "\(trigger) during a running check")
        }
        s.finish()
        check(!s.inFlight, "schedule no overlap", "finish frees the slot")
        // Panel open: 15 minutes.
        check(!s.shouldStart(.panelOpen, now: t0.addingTimeInterval(14 * 60 + 59)), "schedule panel open", "14:59 is fresh")
        check(s.shouldStart(.panelOpen, now: t0.addingTimeInterval(15 * 60)), "schedule panel open", "15:00 is stale")
        // Periodic: 6 hours.
        check(!s.shouldStart(.periodic, now: t0.addingTimeInterval(6 * 3600 - 1)), "schedule periodic", "5:59:59 is not due")
        check(s.shouldStart(.periodic, now: t0.addingTimeInterval(6 * 3600)), "schedule periodic", "6:00:00 is due")
        // The loop never sleeps past 15 minutes, and wakes at the due time.
        check(s.nextNap(now: t0) == AppUpdateCheckSchedule.maximumNap, "schedule nap", "right after a check: the 15 minute cap")
        check(abs(s.nextNap(now: t0.addingTimeInterval(6 * 3600 - 300)) - 300) < 0.001, "schedule nap", "five minutes before due: five minutes")
        check(s.nextNap(now: t0.addingTimeInterval(9 * 3600)) == 1, "schedule nap", "overdue (a Mac that slept): one second")
        // Manual always runs when nothing is in flight, and resets the clock for the others.
        check(s.begin(.manual, now: t0.addingTimeInterval(60)), "schedule manual", "Check for updates runs a minute after launch")
        s.finish()
        check(!s.shouldStart(.panelOpen, now: t0.addingTimeInterval(60 + 14 * 60)), "schedule panel open", "measured from the last check of any kind")
        check(!s.shouldStart(.periodic, now: t0.addingTimeInterval(6 * 3600 + 30)), "schedule periodic", "a manual check pushes the periodic one back")
        // A panel-open check is recorded like any other.
        check(s.begin(.panelOpen, now: t0.addingTimeInterval(60 + 15 * 60)), "schedule panel open", "stale panel open checks")
        check(s.lastStarted == t0.addingTimeInterval(60 + 15 * 60), "schedule panel open", "and is the new last check")
        s.finish()
        // The intervals are the ones Miles asked for.
        check(AppUpdateCheckSchedule.periodicInterval == 6 * 3600, "schedule periodic", "every 6 hours")
        check(AppUpdateCheckSchedule.panelOpenStaleAfter == 15 * 60, "schedule panel open", "15 minutes")
        check(AppUpdateCheckSchedule.helperTimeout > 8 && AppUpdateCheckSchedule.helperTimeout <= 30, "schedule timeout",
              "bounded, and longer than the helper's own 8 s fetch")
    }

    // MARK: 0.5.319 progress, time left, the install deadline and the helper's failure record

    static func progressAndDeadline() {
        let v = "0.5.318", b = 371
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var f = AppUpdateFlow()
        f.offer(info(true, "0.5.319", 372), currentVersion: v, currentBuild: b)
        _ = f.beginInstall()
        // The helper's byte line becomes "Downloading X of Y MB", and after 2 s of data the time left.
        f.progress("Downloading COS Control update…", now: t0)
        check(WhatsNewFooter(f.phase, busy: false).status == "Downloading…", "progress plain", "a line without bytes stays one word")
        f.progress("Downloading COS Control update… 10.0 MB of 137.2 MB", now: t0)
        check(WhatsNewFooter(f.phase, busy: false).status == "Downloading 10.0 of 137.2 MB", "progress bytes", "no estimate before 2 s: \(WhatsNewFooter(f.phase, busy: false).status ?? "nil")")
        f.progress("Downloading COS Control update… 14.0 MB of 137.2 MB", now: t0.addingTimeInterval(1))
        check(WhatsNewFooter(f.phase, busy: false).status == "Downloading 14.0 of 137.2 MB", "progress bytes", "one second of data is too little for an estimate")
        f.progress("Downloading COS Control update… 30.0 MB of 137.2 MB", now: t0.addingTimeInterval(10))   // 2 MB/s
        let line = WhatsNewFooter(f.phase, busy: false).status ?? ""
        check(line == "Downloading 30.0 of 137.2 MB, about 55 s left", "progress time left", "107.2 MB at 2 MB/s is 53.6 s, rounded to 5: \(line)")
        f.progress("Downloading COS Control update… 130.0 MB of 137.2 MB", now: t0.addingTimeInterval(60))
        check((WhatsNewFooter(f.phase, busy: false).status ?? "").hasSuffix("a few seconds left"), "progress time left", "the tail says a few seconds")
        check(AppUpdateDownloadLine.timeLeft(40) == "about 40 s left" && AppUpdateDownloadLine.timeLeft(200) == "about 3 min left", "progress time left", "seconds and minutes")
        check(AppUpdateDownloadLine.parse("Checking SHA-256…") == nil && AppUpdateDownloadLine.parse("Downloading 5.0 MB") == .init(received: 5, total: nil), "progress parse", "only download lines with bytes parse")
        // Installing says how long it usually takes; while the Mac recording saves, it says that instead.
        f.staged(now: t0.addingTimeInterval(70))
        check(WhatsNewFooter(f.phase, busy: false).status == WhatsNewFooter.installingWords, "installing words", "how long installing takes")
        f.waitingToQuit(on: "the Mac recording")
        check(WhatsNewPresentation.offer(info(true, "0.5.319", 372), flow: f, frozen: nil, busy: true).footer.status == "Saving the Mac recording first, then COS Control closes and installs.", "installing waits", "names what Control is finishing")
        // The deadline: still installing 75 s after apply started means the helper gave up.
        check(!f.applyOverdue(now: t0.addingTimeInterval(70 + AppUpdateFlow.applyDeadline - 1)), "apply deadline", "not before the deadline")
        check(f.applyOverdue(now: t0.addingTimeInterval(70 + AppUpdateFlow.applyDeadline)), "apply deadline", "overdue at the deadline")
        check(AppUpdateFlow.applyDeadline > 60, "apply deadline", "longer than the helper's 60 s quit wait")
        f.fail(AppUpdateFailureRecord.quitTimeoutWords)
        check(f.phase == .failed(AppUpdateFailureRecord.quitTimeoutWords) && f.quitWaitingOn == nil && !f.applyOverdue(now: t0.addingTimeInterval(10_000)), "apply deadline", "fails with words, Try again, and clears the wait")
        check(WhatsNewFooter(f.phase, busy: false).primaryTitle == WhatsNewFooter.retryTitle, "apply deadline", "Try again is offered")
        // The helper's failure record in words.
        let busy = AppUpdateFailureRecord.parse(Data(#"{"reason":"busy","blockers":["meeting=1","video upload"],"at":"2026-10-17T18:30:00Z"}"#.utf8))
        check(busy?.words == "Finish your meeting and the video upload first, then install. The glasses server was not touched.", "failure record", "busy: \(busy?.words ?? "nil")")
        check(busy?.at == ISO8601DateFormatter().date(from: "2026-10-17T18:30:00Z"), "failure record", "its time is read")
        check(AppUpdateFailureRecord.parse(Data(#"{"reason":"quitTimeout"}"#.utf8))?.words == AppUpdateFailureRecord.quitTimeoutWords, "failure record", "quit timeout")
        check(AppUpdateFailureRecord.parse(Data("not json".utf8)) == nil, "failure record", "junk is nil")
        // A refusal recorded after the old Control quit is restored on the offer, only while it stands.
        var g = AppUpdateFlow()
        g.offer(info(true, "0.5.319", 372), currentVersion: v, currentBuild: b)
        g.restoreFailure("Finish your meeting first, then install.")
        check(g.phase == .failed("Finish your meeting first, then install."), "restore failure", "shown on a standing offer")
        var h = AppUpdateFlow()
        h.restoreFailure("x")
        check(h.phase == .none, "restore failure", "never without an offer")
    }

    // MARK: 0.5.322 Finish installing, the words while applying, and the swap's give-up records

    static func finishAndEscalation() {
        let v = "0.5.321", b = 374
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let iso = ISO8601DateFormatter()
        func at(_ seconds: TimeInterval) -> JSONValue { .string(iso.string(from: now.addingTimeInterval(seconds))) }
        func staged(_ change: [String: JSONValue?] = [:]) -> [String: JSONValue] {
            var d: [String: JSONValue] = ["reason": .string("staged"), "version": .string("0.5.322"), "build": .number(375),
                                          "failureReason": .string("quitTimeout"), "failureAt": at(-60)]
            for (key, value) in change { d[key] = value }
            return d
        }
        func offered(_ d: [String: JSONValue], current: Int = b) -> Bool { AppUpdateFinishOffer.offer(d, currentBuild: current, now: now) != nil }
        // The launch offer: a checked stage, newer, after a quit that could not happen, in the last 30 minutes.
        let good = AppUpdateFinishOffer.offer(staged(), currentBuild: b, now: now)
        check(good?.version == "0.5.322" && good?.build == 375, "finish offer", "a checked stage after a quit timeout is offered")
        check(offered(staged(["failureReason": .string("recording")])), "finish offer", "and after the swap refused for a Mac recording")
        for reason in ["busy", "notStaged", "", "quittimeout"] {
            check(!offered(staged(["failureReason": .string(reason)])), "finish offer reasons", "\(reason.debugDescription) is not a quit that could not happen")
        }
        check(!offered(staged(["failureReason": nil])), "finish offer reasons", "no failure record, no offer")
        for reason in ["unverified", "missing", "noFailedQuit", "notNewer", "none"] {
            check(!offered(staged(["reason": .string(reason)])), "finish offer verified", "the helper's \(reason) is never offered")
        }
        check(!offered(staged(), current: 375) && !offered(staged(), current: 376), "finish offer newer", "only a build newer than the running one")
        check(offered(staged(["failureAt": at(-AppUpdateFinishOffer.window)])), "finish offer window", "30 minutes ago still counts")
        check(!offered(staged(["failureAt": at(-AppUpdateFinishOffer.window - 1)])), "finish offer window", "older than 30 minutes is not offered")
        check(offered(staged(["failureAt": at(60)])) && !offered(staged(["failureAt": at(AppUpdateFinishOffer.skew + 1)])),
              "finish offer window", "a little clock skew is allowed, a record far in the future is not")
        check(!offered(staged(["failureAt": nil])) && !offered(staged(["failureAt": .string("yesterday")])), "finish offer window", "no time, no offer")
        check(!offered(staged(["successAt": at(-30)])) && !offered(staged(["successAt": at(-60)])), "finish offer success",
              "an install that succeeded since (or at) the failure is not offered again")
        check(offered(staged(["successAt": at(-3600)])), "finish offer success", "an older success does not hide the offer")
        check(!offered(staged(["version": .string("0.5.x")])) && !offered(staged(["build": nil])), "finish offer verified", "a malformed stage is never offered")
        check(AppUpdateFinishOffer.window == 30 * 60, "finish offer window", "the window is 30 minutes")

        // The flow: offerFinish, the banner and footer words, one click to applying, and what a check may change.
        var f = AppUpdateFlow()
        f.offerFinish(version: "0.5.322", build: 375, currentBuild: b)
        check(f.phase == .ready && f.finishesStaged && f.versionLine == "Version 0.5.322 (build 375)", "finish flow", "a staged offer is ready")
        let banner = AppUpdateBannerWords(f)
        check(banner.title == "Finish installing 0.5.322" && banner.action == "Install" && banner.detail == WhatsNewFooter.finishWords,
              "finish words", "the banner: \(banner.title) / \(banner.action ?? "nil") / \(banner.detail)")
        let footer = WhatsNewFooter(f.phase, busy: false, finishesStaged: f.finishesStaged)
        check(footer.primaryTitle == WhatsNewFooter.finishTitle && footer.primaryEnabled && footer.status == WhatsNewFooter.finishWords,
              "finish words", "the What's New footer offers Finish installing")
        check(WhatsNewPresentation.offer(info(false, nil, nil, reason: "unreachable"), flow: f, frozen: nil, busy: false).footer.primaryTitle == WhatsNewFooter.finishTitle,
              "finish words", "the presentation passes the staged offer to the footer")
        check(!WhatsNewFooter(f.phase, busy: true, finishesStaged: true).primaryEnabled, "finish words", "busy waits")
        var restored = f
        restored.restoreFailure(AppUpdateFailureRecord.quitTimeoutWords)
        check(restored.phase == .ready && restored.finishesStaged, "finish flow", "the restored failure never replaces Finish installing")
        var g = f
        g.offer(info(false, nil, nil, reason: "unreachable"), currentVersion: v, currentBuild: b)
        check(g.finishesStaged && g.phase == .ready, "finish flow", "an unreachable feed keeps the staged offer (no download needed)")
        g.offer(info(false, nil, nil, reason: "malformed"), currentVersion: v, currentBuild: b)
        check(g.finishesStaged, "finish flow", "a malformed feed keeps it")
        g.offer(info(true, "0.5.322", 375), currentVersion: v, currentBuild: b)
        check(g.finishesStaged && g.phase == .ready, "finish flow", "the feed still offering the staged build keeps it")
        var newer = f
        newer.offer(info(true, "0.5.323", 376), currentVersion: v, currentBuild: b)
        check(!newer.finishesStaged && newer.phase == .ready && newer.build == 376, "finish flow", "a newer build replaces the staged one (it downloads)")
        var upToDate = f
        upToDate.offer(info(false, "0.5.321", b, reason: "upToDate"), currentVersion: v, currentBuild: b)
        check(!upToDate.finishesStaged && upToDate.phase == .none, "finish flow", "no update any more: the staged offer goes")
        var paused = f
        paused.offer(info(false, nil, nil, reason: "killSwitch"), currentVersion: v, currentBuild: b)
        check(!paused.finishesStaged && paused.phase == .none, "finish flow", "paused updates drop the staged offer")
        var notNewer = AppUpdateFlow()
        notNewer.offerFinish(version: "0.5.321", build: b, currentBuild: b)
        notNewer.offerFinish(version: "0.5.x", build: 999, currentBuild: b)
        check(notNewer.phase == .none && !notNewer.finishesStaged, "finish flow", "never a build that is not newer, never a malformed version")
        var plain = AppUpdateFlow()
        plain.offer(info(true, "0.5.322", 375), currentVersion: v, currentBuild: b)
        check(!plain.beginFinish(), "finish flow", "an ordinary offer never applies without its download")
        var h = f
        let t0 = now
        check(h.beginFinish(now: t0) && h.phase == .applying && !h.finishesStaged, "finish one click", "Finish installing goes straight to applying")
        check(!h.beginFinish(now: t0) && !h.beginInstall(), "finish one click", "a second press starts nothing")
        check(!h.applyOverdue(now: t0.addingTimeInterval(AppUpdateFlow.applyDeadline - 1)) && h.applyOverdue(now: t0.addingTimeInterval(AppUpdateFlow.applyDeadline)),
              "finish one click", "the same 75 s deadline as Download and install")
        var during = h
        during.offerFinish(version: "0.5.399", build: 450, currentBuild: b)
        check(during.phase == .applying && during.version == "0.5.322", "finish flow", "never during an install")
        var install = f
        check(install.beginInstall() && !install.finishesStaged, "finish flow", "a full install clears the staged offer")
        // Words while applying: Closing COS Control…, or what Control saves first.
        check(WhatsNewFooter.installingWords == "Closing COS Control\u{2026}", "applying words", "the footer says Closing COS Control…")
        check(AppUpdateBannerWords(h).detail == "Closing COS Control\u{2026}" && AppUpdateBannerWords(h).action == nil, "applying words",
              "the banner says it too, with no button: \(AppUpdateBannerWords(h).detail)")
        h.waitingToQuit(on: "the Mac recording")
        check(AppUpdateBannerWords(h).detail == "Saving the Mac recording first, then COS Control closes and installs."
              && WhatsNewFooter(h.phase, busy: true, quitWaitingOn: h.quitWaitingOn).status == AppUpdateBannerWords(h).detail,
              "applying words", "banner and footer name what Control saves first, in the same words")
        for words in [AppUpdateFailureRecord.recordingWords, WhatsNewFooter.finishWords, WhatsNewFooter.installingWords, AppUpdateBannerWords(f).title] {
            check(!words.contains("\u{2014}") && !words.contains("\u{2192}") && !words.contains("->"), "no dashes", "no em dash or arrow: \(words)")
        }
        // The swap's records: which end an install at once, and in what words.
        let recording = AppUpdateFailureRecord.parse(Data(#"{"reason":"recording","at":"2026-10-17T22:00:00Z"}"#.utf8))
        check(recording?.words == AppUpdateFailureRecord.recordingWords && recording?.endsApply == true, "failure record recording",
              "recording: \(recording?.words ?? "nil")")
        check(AppUpdateFailureRecord.recordingWords.hasSuffix("Finish the Mac recording, then choose Try again."), "failure record recording", "the words end with what to do")
        check(AppUpdateFailureRecord.parse(Data(#"{"reason":"quitTimeout"}"#.utf8))?.endsApply == true, "ends apply", "quitTimeout ends the install at once")
        for reason in ["busy", "notStaged", "other"] {
            check(AppUpdateFailureRecord.parse(Data("{\"reason\":\"\(reason)\"}".utf8))?.endsApply == false, "ends apply",
                  "\(reason): the swap waits for Control to quit and reopens it, so the install does not end early")
        }
        check(AppUpdateFlow.applyDeadline >= 20 + 10 + 5 + 30 && AppUpdateFlow.applyDeadline >= 60 + 10, "apply deadline",
              "longer than the swap's forced quit and its unknown-state wait plus linger")
    }

    // MARK: phases

    static func flow() {
        let v = "0.5.273", b = 326
        var f = AppUpdateFlow()
        check(f.phase == .none && !f.showsBanner, "flow none", "starts with no banner")
        f.offer(info(false, "0.5.273", 326), currentVersion: v, currentBuild: b)
        check(f.phase == .none, "flow none", "up to date stays none")
        f.offer(info(false, nil, nil, reason: "unreachable"), currentVersion: v, currentBuild: b)
        check(f.phase == .none, "flow check failure silent", "an unreachable feed never shows a banner")
        f.offer(info(true, "0.5.273", 326), currentVersion: v, currentBuild: b)
        check(f.phase == .none, "flow stale offer", "an offer of this very build is not an update")
        check(!f.beginInstall(), "flow install gate", "nothing to install from none")

        f.offer(info(true, "0.5.274", 327), currentVersion: v, currentBuild: b)
        check(f.phase == .ready && f.showsBanner, "flow ready", "a newer build is ready")
        check(f.versionLine == "Version 0.5.274 (build 327)", "flow ready", "banner line: \(f.versionLine)")
        f.progress("Downloading")
        f.staged()
        f.fail("x")
        check(f.phase == .ready, "flow install gate", "progress, staged and fail do nothing before Update")

        check(f.beginInstall(), "flow staging", "Update starts staging")
        check(f.phase == .staging(nil) && f.installing, "flow staging", "staging with no line yet")
        check(!f.beginInstall(), "flow install gate", "a second press never starts a second install")
        f.progress("  Checking SHA-256…\n")
        check(f.phase == .staging("Checking SHA-256…"), "flow staging", "the helper's progress line, trimmed")
        f.progress("   ")
        check(f.phase == .staging("Checking SHA-256…"), "flow staging", "a blank line keeps the last one")
        f.offer(info(false, "0.5.273", 326), currentVersion: v, currentBuild: b)
        check(f.phase == .staging("Checking SHA-256…") && f.versionLine.contains("0.5.274"), "flow install owns banner",
              "a check during the install changes nothing")
        f.staged()
        check(f.phase == .applying, "flow applying", "staged moves to applying")
        f.progress("late line")
        check(f.phase == .applying, "flow applying", "a late staging line does not move it back")
        f.fail("Could not start the updater.")
        check(f.phase == .failed("Could not start the updater."), "flow failed", "the helper's own words")
        check(f.showsBanner && !f.installing, "flow failed", "the banner stays, nothing is running")

        f.offer(info(true, "0.5.274", 327), currentVersion: v, currentBuild: b)
        check(f.phase == .failed("Could not start the updater."), "flow failed", "the failure stays while the offer stands")
        f.offer(info(false, nil, nil, reason: "unreachable"), currentVersion: v, currentBuild: b)
        // (merging keeps a live offer across an unreachable tick in the model; here the raw payload is not an offer)
        check(f.phase == .none, "flow failed", "no offer any more: the banner goes")
        f.offer(info(true, "0.5.274", 327), currentVersion: v, currentBuild: b)
        check(f.beginInstall(), "flow staging", "Update again")
        f.fail("   ")
        check(f.phase == .failed("The update did not install."), "flow failed", "an empty error still says something")
        check(f.beginInstall() && f.phase == .staging(nil), "flow retry", "Try again stages again")
        f.fail("The download did not match the published SHA-256. The file was discarded.")
        f.offer(info(true, "0.5.275", 328), currentVersion: v, currentBuild: b)
        check(f.versionLine == "Version 0.5.275 (build 328)", "flow retry", "a newer offer while failed names the newer build")
        f.offer(info(false, "0.5.275", 328), currentVersion: v, currentBuild: b)
        check(f.phase == .none && f.versionLine.isEmpty, "flow none", "up to date clears the banner and its version")

        // The sticky offer: the model merges an unreachable tick into the previous offer, and the flow keeps ready.
        let offer = info(true, "0.5.274", 327)
        let merged = AppUpdateInfo.merging(previous: offer, incoming: info(false, nil, nil, reason: "unreachable"))
        f.offer(merged, currentVersion: v, currentBuild: b)
        check(f.phase == .ready, "flow check failure silent", "an unreachable tick keeps a live offer ready")
        var noBuild = AppUpdateFlow()
        noBuild.offer(info(true, "0.5.274", nil), currentVersion: v, currentBuild: b)
        check(noBuild.phase == .ready && noBuild.versionLine == "Version 0.5.274", "flow ready", "no build named: the version alone")
    }

    // MARK: icon

    static func icon() {
        check(MenuBarIcon.variant(for: .none, recording: true) == .recording, "recording indicator", "recording without update")
        check(MenuBarIcon.variant(for: .ready, recording: true) == .recordingAndUpdate, "recording indicator", "recording and update coexist")
        check(MenuBarIcon.accessibilityLabel(.recordingAndUpdate).contains("meeting recording"), "recording accessibility")
        for variant in [MenuBarIcon.Variant.recording, .recordingAndUpdate] {
            let image = MenuBarIcon.compose(systemName: "eyeglasses", variant: variant)
            check(!image.isTemplate, "recording color preserved")
            check(image.size == MenuBarIcon.compose(systemName: "eyeglasses", variant: .updateReady).size, "recording glyph is not stretched")
        }

        check(MenuBarIcon.variant(for: .none) == .normal, "icon follows state", "none is the plain glasses")
        for phase in [AppUpdatePhase.ready, .staging(nil), .staging("x"), .applying, .failed("x")] {
            check(MenuBarIcon.variant(for: phase) == .updateReady, "icon follows state", "\(phase) is the gold glasses")
        }
        // The icon follows the flow end to end: a failed check never tints it.
        var f = AppUpdateFlow()
        f.offer(info(false, nil, nil, reason: "unreachable"), currentVersion: "0.5.273", currentBuild: 326)
        check(MenuBarIcon.variant(for: f.phase) == .normal, "icon follows state", "a failed check leaves the glasses plain")
        f.offer(info(true, "0.5.274", 327), currentVersion: "0.5.273", currentBuild: 326)
        check(MenuBarIcon.variant(for: f.phase) == .updateReady, "icon follows state", "a ready update tints them")
        check(MenuBarIcon.accessibilityLabel(.updateReady).contains("update available"), "icon follows state", "VoiceOver hears it")

        let plain = MenuBarIcon.compose(systemName: "eyeglasses", variant: .normal)
        let ready = MenuBarIcon.compose(systemName: "eyeglasses", variant: .updateReady)
        check(plain.isTemplate, "icon template", "the plain glasses follow the menu bar")
        check(!ready.isTemplate, "icon color", "the ready glasses are not a template (a menu bar drops a template's color)")
        check(ready.size.height == plain.size.height && ready.size.width == plain.size.width + MenuBarIcon.dotRoom
              && ready.size.width > ready.size.height + 1, "icon size", "the glyph 1:1, the dot's room on the right, still landscape")
        for name in ["eyeglasses", "eyeglasses.slash"] {
            let gap = dotClearance(MenuBarIcon.compose(systemName: name, variant: .normal))
            check(gap >= 0.75, "icon dot clear", "\(name): the dot must sit outside the glyph, at least 0.75 pt from its ink (\(String(format: "%.2f", gap)) pt)")
        }
        check(MenuBarIcon.image(systemName: "eyeglasses", variant: .updateReady) === MenuBarIcon.image(systemName: "eyeglasses", variant: .updateReady),
              "icon cache", "made once per variant")

        for (name, appearance, expected) in [("light", NSAppearance.Name.aqua, (0.537, 0.400, 0.176)),
                                             ("dark", NSAppearance.Name.darkAqua, (0.788, 0.659, 0.431))] {
            guard let a = NSAppearance(named: appearance) else { continue }
            var readyStats = (gold: 0, other: 0, dot: false), plainColored = 0
            a.performAsCurrentDrawingAppearance {
                readyStats = pixels(ready, expected: expected)
                let p = pixels(plain, expected: expected)
                plainColored = p.gold
            }
            check(readyStats.gold > 20, "icon color", "\(name): the ready glasses are drawn in gold (\(readyStats.gold) gold pixels)")
            check(readyStats.other == 0, "icon color", "\(name): every drawn pixel of the ready glasses is gold (\(readyStats.other) are not)")
            check(readyStats.dot, "icon dot", "\(name): the dot sits at the top-right corner")
            check(plainColored == 0, "icon template", "\(name): the plain glasses carry no gold")
        }
        // Contrast: the light gold against a white bar and a black bar, at or above 4:1 (and so legible where the
        // menu bar's appearance is resolved differently from the app's).
        func luminance(_ c: (Double, Double, Double)) -> Double {
            func lin(_ x: Double) -> Double { x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2)
        }
        let light = luminance((0.537, 0.400, 0.176)), dark = luminance((0.788, 0.659, 0.431))
        check(1.05 / (light + 0.05) >= 4 && (light + 0.05) / 0.05 >= 3.5, "icon contrast", "light gold on white and on black")
        check((dark + 0.05) / (luminance((0.12, 0.12, 0.12)) + 0.05) >= 4.5, "icon contrast", "dark gold on a dark bar")
    }

    /// The plain glyph at 8x; the shortest distance (pt) from any of its ink to the edge of the ready image's dot, which
    /// sits in the top-right corner of a canvas `dotRoom` wider. Negative when they overlap.
    static func dotClearance(_ glyph: NSImage) -> Double {
        let scale: CGFloat = 8
        let w = Int(glyph.size.width * scale), h = Int(glyph.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return -1 }
        rep.size = glyph.size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return -1 }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        glyph.draw(in: NSRect(origin: .zero, size: glyph.size))
        NSGraphicsContext.restoreGraphicsState()
        let r = Double(MenuBarIcon.dotDiameter) / 2
        // Dot centre, in points from the top-left of the glyph's own canvas.
        let cx = Double(glyph.size.width + MenuBarIcon.dotRoom) - r, cy = r
        var nearest = Double.infinity
        for y in 0..<h {
            for x in 0..<w {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.05 else { continue }
                let px = (Double(x) + 0.5) / Double(scale), py = (Double(y) + 0.5) / Double(scale)
                nearest = min(nearest, ((px - cx) * (px - cx) + (py - cy) * (py - cy)).squareRoot() - r)
            }
        }
        return nearest
    }

    /// Draws the image at 4x into a clear bitmap and counts opaque pixels that are (or are not) the expected gold, and
    /// whether the top-right corner (the dot) is gold.
    static func pixels(_ image: NSImage, expected: (Double, Double, Double)) -> (gold: Int, other: Int, dot: Bool) {
        let scale: CGFloat = 4
        let w = Int(image.size.width * scale), h = Int(image.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return (0, 0, false) }
        // The point size BEFORE the context: a context made first draws 1 pt to 1 pixel, in the bottom-left corner.
        rep.size = image.size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return (0, 0, false) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        var gold = 0, other = 0
        func isGold(_ c: NSColor) -> Bool {
            guard c.alphaComponent > 0.9, let rgb = c.usingColorSpace(.sRGB) ?? c.usingColorSpace(.deviceRGB) else { return false }
            return abs(Double(rgb.redComponent) - expected.0) < 0.09 && abs(Double(rgb.greenComponent) - expected.1) < 0.09
                && abs(Double(rgb.blueComponent) - expected.2) < 0.09
        }
        for y in 0..<h {
            for x in 0..<w {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.9 else { continue }
                if isGold(c) { gold += 1 } else { other += 1 }
            }
        }
        // The dot's centre: 2.5 pt in from the top-right corner (colorAt's y runs from the top).
        let cx = w - Int(MenuBarIcon.dotDiameter / 2 * scale), cy = Int(MenuBarIcon.dotDiameter / 2 * scale)
        let dot = rep.colorAt(x: cx, y: cy).map(isGold) ?? false
        return (gold, other, dot)
    }
}
