import Combine
import Foundation

/// 0.5.372 Drop it P2 (DropItP2 and DropItP2Store in Sources/DropItP2.swift), executed against a stand-in helper. Compiled with
/// DropIt.swift, DropItP2.swift and Models.swift alone by Tests/run-drop-it.sh (lane p2): no helper, no server, no window, no
/// notification center. Prints "drop it p2 checks: N passed". Every failure names its behaviour in brackets.
@main struct DropItP2Checks {
    nonisolated(unsafe) static var passed = 0

    static func check(_ condition: Bool, _ what: String) {
        guard condition else { print("drop it p2 check FAILED: \(what)"); exit(1) }
        passed += 1
    }
    static func details(_ json: String) -> [String: JSONValue] {
        let wrapped = #"{"ok":true,"message":"x","details":"# + json + "}"
        return try! JSONDecoder().decode(HelperResponse.self, from: Data(wrapped.utf8)).details
    }
    static func answered(_ status: Int, _ body: String = "") -> [String: JSONValue] {
        details(#"{"transport":"answered","httpStatus":"# + "\(status)" + (body.isEmpty ? "" : "," + body) + "}")
    }
    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: date)
    }

    static let drop = "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"
    static let drop2 = "2b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"
    static let settingsJSON = #"{"pings":{"on":true,"dailyCap":6,"perSource":2,"gapMinutes":45,"quietStart":"18:00","quietEnd":"06:00","weekendsQuiet":true,"firstBanner":"08:00","sources":{"prep":true,"agent":true,"followups":true,"stale":true,"signals":true}},"followUps":{"on":true,"kinds":{"card":true,"handoff":true,"session":true,"thread":true}},"checkin":{"on":true,"weekday":1,"time":"09:00"},"reminders":{"defaultTime":"09:00","snoozeMinutes":60,"banners":true,"lensPush":true},"banners":{"reminder":true,"resolution":true,"prep":false,"agent":false,"followups":false,"stale":false,"checkin":false},"steer":{"about":"","leaveAlone":""}}"#

    @MainActor final class Stand {
        var log: [(args: [String], stdin: Data?)] = []
        var answers: [String: [String: JSONValue]] = [:]
        func op(_ args: [String]) -> String { args.firstIndex(of: "--op").map { args[$0 + 1] } ?? "" }
        func calls(_ op: String) -> [[String]] { log.filter { self.op($0.args) == op }.map(\.args) }
        func run(_ args: [String], _ stdin: Data?) async throws -> HelperResponse {
            log.append((args, stdin))
            guard let d = answers[op(args)] else { throw CancellationError() }
            return HelperResponse(ok: true, message: "x", details: d)
        }
    }

    @MainActor static func main() async {
        let now = Date(timeIntervalSince1970: 1_793_900_000)

        // MARK: Pure rules
        func banner(_ seq: Int, ago: TimeInterval, notify: String? = nil, feed: [String] = ["fi_" + String(repeating: "a", count: 32)]) -> DropItP2.Banner {
            DropItP2.Banner(seq: seq, at: now.addingTimeInterval(-ago), title: "T\(seq)", line: "L", feedIds: feed, sources: ["resolution"], notifyId: notify)
        }
        let old = banner(1, ago: 11 * 60), recent = banner(2, ago: 60)
        check(DropItP2.toShow([old, recent], sameBoot: true, after: 0, now: now) == [old, recent], "[same boot] every banner after the cursor shows")
        check(DropItP2.toShow([old, recent], sameBoot: true, after: 1, now: now) == [recent], "[same boot] a banner at or before the cursor does not")
        check(DropItP2.toShow([old, recent], sameBoot: false, after: 0, now: now) == [recent], "[fresh boot] only the last 10 minutes show")
        check(DropItP2.toShow([banner(3, ago: 600)], sameBoot: false, after: 0, now: now).count == 1, "[fresh boot edge] exactly 10 minutes still shows")
        let n1 = DropItP2.notice(recent, boot: "b1")
        check(n1.identifier == "cos-ping-b1-2" && n1.fireAt == nil && n1.userInfo["inboxID"] == recent.feedIds.first && n1.userInfo["cosChat"] == "1",
              "[banner notice] a ping's id is per boot and seq, now, and opens its chat item")
        check(DropItP2.notice(banner(4, ago: 0, notify: "reminder-" + drop), boot: "b1").identifier == "reminder-" + drop, "[reminder notice] a reminder banner uses the server's id")
        check(DropItP2.notice(banner(5, ago: 0, feed: []), boot: "b").userInfo["inboxID"] == nil, "[banner notice] no feed id, no inboxID")
        check(n1.title == "T2" && n1.body == "L", "[banner notice] the server's title and line")

        let r1 = DropItP2.Reminder(id: drop, at: now.addingTimeInterval(3600), title: "Reminder: call Silas", notifyId: "reminder-" + drop)
        let r2 = DropItP2.Reminder(id: drop2, at: now.addingTimeInterval(7200), title: "Reminder: deck", notifyId: "reminder-" + drop2)
        var plan = DropItP2.reminderPlan(pending: [r1, r2], scheduled: [:], allowed: true, now: now)
        check(plan.add.map(\.identifier) == ["reminder-" + drop, "reminder-" + drop2] && plan.remove.isEmpty, "[backup] each pending reminder is scheduled")
        check(plan.add[0].fireAt == r1.at && plan.add[0].userInfo["dropReminder"] == drop && plan.add[0].body == DropItP2.reminderBody, "[backup] at its time, with its drop")
        plan = DropItP2.reminderPlan(pending: [r1, r2], scheduled: [r1.notifyId: r1.at, r2.notifyId: r2.at], allowed: true, now: now)
        check(plan.add.isEmpty && plan.remove.isEmpty, "[backup steady] scheduled at the same time: nothing to do")
        plan = DropItP2.reminderPlan(pending: [r1], scheduled: [r1.notifyId: r1.at.addingTimeInterval(-1800), r2.notifyId: r2.at], allowed: true, now: now)
        check(plan.add.map(\.identifier) == [r1.notifyId], "[backup snoozed] a reminder at a new time is scheduled again")
        check(plan.remove == [r2.notifyId], "[backup done] a reminder the server no longer has is removed")
        plan = DropItP2.reminderPlan(pending: [r1], scheduled: [r1.notifyId: r1.at, "other-id": now], allowed: true, now: now)
        check(plan.remove.isEmpty, "[backup scope] only reminder- ids are ours")
        plan = DropItP2.reminderPlan(pending: [r1, r2], scheduled: [r1.notifyId: r1.at], allowed: false, now: now)
        check(plan.add.isEmpty && plan.remove == [r1.notifyId], "[backup off] Notify me off removes every one and adds none")
        let past = DropItP2.Reminder(id: drop, at: now.addingTimeInterval(2), title: "t", notifyId: "reminder-" + drop)
        let far = DropItP2.Reminder(id: drop2, at: now.addingTimeInterval(9 * 24 * 3600), title: "t", notifyId: "reminder-" + drop2)
        check(DropItP2.reminderPlan(pending: [past, far], scheduled: [:], allowed: true, now: now).add.isEmpty, "[backup window] due now or beyond eight days is the server's")
        let many = (0..<60).map { i in DropItP2.Reminder(id: "\(i)", at: now.addingTimeInterval(Double(3600 + i)), title: "t", notifyId: "reminder-\(i)") }
        let capped = DropItP2.reminderPlan(pending: many.reversed(), scheduled: [:], allowed: true, now: now).add
        check(capped.count == DropItP2.reminderBackupMax && capped.first?.identifier == "reminder-0", "[backup cap] at most 40, the soonest first")

        // Paths
        let s0 = details(settingsJSON)
        check(DropItP2.value(s0, "pings.sources.prep")?.bool == true && DropItP2.value(s0, "checkin.weekday")?.int == 1, "[paths] a dotted path reads")
        check(DropItP2.value(s0, "pings.nope") == nil, "[paths] a missing path is nil")
        let c = DropItP2.change("pings.sources.prep", false)
        check(((c["pings"] as? [String: Any])?["sources"] as? [String: Any])?["prep"] as? Bool == false && c.count == 1, "[paths] a change is one field, nested")
        let s1 = DropItP2.setting(s0, "pings.sources.prep", .bool(false))
        check(DropItP2.value(s1, "pings.sources.prep")?.bool == false && DropItP2.value(s1, "pings.sources.agent")?.bool == true
              && DropItP2.value(s1, "pings.dailyCap")?.int == 6, "[paths] setting one field keeps its neighbours")
        check(DropItP2.minutes("09:30") == 570 && DropItP2.minutes("24:00") == nil && DropItP2.minutes("9") == nil, "[time] HH:MM reads")
        check(DropItP2.hhmm(570) == "09:30" && DropItP2.hhmm(0) == "00:00", "[time] minutes write HH:MM")
        check(DropItP2.weekdays.count == 7 && DropItP2.weekdays.first?.0 == 1 && DropItP2.weekdays.last?.0 == 0, "[weekdays] Monday first, Sunday 0")

        // MARK: The store
        let stand = Stand()
        let defaults = UserDefaults(suiteName: "cos-drop-it-p2-checks-\(UUID().uuidString)")!
        let store = DropItP2Store(run: { a, i in try await stand.run(a, i) }, defaults: defaults)
        var on = false
        var posted: [DropItP2.Notice] = []
        var delivered: Set<String> = []
        var scheduled: [String: Date] = [:]
        var removed: [String] = []
        store.available = { on }
        store.post = { posted.append($0) }
        store.delivered = { delivered }
        store.scheduled = { scheduled }
        store.removePending = { removed += $0 }
        store.now = { now }

        await store.step()
        check(stand.log.isEmpty, "[off] nothing is read while Drop it is off")
        on = true
        stand.answers["p2"] = answered(200, #""protocol":1,"settings":"# + settingsJSON)
        stand.answers["banners"] = answered(200, #""bootId":"b1","seq":2,"banners":[{"seq":1,"at":"\#(iso(now.addingTimeInterval(-3600)))","title":"Old","line":"x","feedIds":[],"sources":[],"exempt":false},{"seq":2,"at":"\#(iso(now.addingTimeInterval(-30)))","title":"New","line":"y","feedIds":[],"sources":["resolution"],"exempt":false}]"#)
        stand.answers["reminders"] = answered(200, #""reminders":[{"id":"\#(drop)","at":"\#(iso(r1.at))","title":"Reminder: call Silas","notifyId":"reminder-\#(drop)"}]"#)
        await store.step()
        check(store.settings != nil && stand.calls("p2").count == 1, "[first step] the settings are read")
        check(stand.calls("banners").first == ["drop-it", "--op", "banners"], "[first step] no cursor yet: the whole outbox")
        check(posted.map(\.title) == ["New", "Reminder: call Silas"], "[first step] a fresh boot shows only the recent banner, then the backup: \(posted.map(\.title))")
        check(defaults.string(forKey: DropItP2Store.bootKey) == "b1" && defaults.integer(forKey: DropItP2Store.seqKey) == 2, "[cursor] the boot and seq are kept")

        posted = []
        stand.answers["banners"] = answered(200, #""bootId":"b1","seq":3,"banners":[{"seq":3,"at":"\#(iso(now.addingTimeInterval(-7200)))","title":"Held","line":"z","feedIds":[],"sources":[],"exempt":false}]"#)
        await store.step()
        check(stand.calls("banners").last == ["drop-it", "--op", "banners", "--boot", "b1", "--seq", "2"], "[cursor] the next read sends the cursor")
        check(posted.map(\.title) == ["Held"], "[same boot] an older banner after the cursor still shows (it was held through quiet hours)")
        check(stand.calls("reminders").count == 1, "[cadence] reminders are read every third step, not every step")
        check(stand.calls("p2").count == 1, "[cadence] settings are read every fifteenth step")

        posted = []
        delivered = ["reminder-" + drop]
        stand.answers["banners"] = answered(200, #""bootId":"b1","seq":4,"banners":[{"seq":4,"at":"\#(iso(now))","title":"Reminder","line":"call Silas","feedIds":[],"sources":["reminder"],"exempt":true,"notifyId":"reminder-\#(drop)"}]"#)
        await store.pollBanners()
        check(posted.isEmpty, "[one reminder] the backup already showed it: the server's banner is skipped")
        delivered = []
        await store.pollBanners()
        check(posted.isEmpty, "[cursor] a banner is shown once per cursor")
        defaults.set(3, forKey: DropItP2Store.seqKey)
        await store.pollBanners()
        check(posted.map(\.identifier) == ["reminder-" + drop], "[one reminder] with no backup showing, the server's banner shows under the same id")

        posted = []
        stand.answers["banners"] = answered(200, #""bootId":"b2","seq":1,"banners":[{"seq":1,"at":"\#(iso(now.addingTimeInterval(-1200)))","title":"Stale","line":"x","feedIds":[],"sources":[],"exempt":false}]"#)
        await store.pollBanners()
        check(posted.isEmpty && defaults.string(forKey: DropItP2Store.bootKey) == "b2", "[restart] a new boot does not replay old banners, and the cursor moves to it")
        stand.answers["banners"] = answered(503, #""error":"pings_unavailable""#)
        await store.pollBanners()
        check(defaults.string(forKey: DropItP2Store.bootKey) == "b2" && defaults.integer(forKey: DropItP2Store.seqKey) == 1, "[refused] a refused read keeps the cursor")

        // Reminders: off removes and never reads
        let readsBefore = stand.calls("reminders").count
        scheduled = ["reminder-" + drop: r1.at]
        stand.answers["p2-set"] = answered(200, #""protocol":1,"settings":"# + settingsJSON.replacingOccurrences(of: #""banners":true,"lensPush""#, with: #""banners":false,"lensPush""#))
        await store.set("reminders.banners", .bool(false), raw: false)
        check(store.bool("reminders.banners") == false, "[set] the saved value shows")
        check(removed == ["reminder-" + drop] && stand.calls("reminders").count == readsBefore, "[backup off] turning Notify me off removes the backups without a read")
        let sent = stand.log.last(where: { stand.op($0.args) == "p2-set" })?.stdin.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        check((sent?["reminders"] as? [String: Any])?["banners"] as? Bool == false && sent?.count == 1, "[set] one field is sent")

        // Clamped answer replaces, refusal reverts
        stand.answers["p2-set"] = answered(200, #""protocol":1,"settings":"# + settingsJSON.replacingOccurrences(of: #""dailyCap":6"#, with: #""dailyCap":20"#))
        await store.set("pings.dailyCap", .number(50), raw: 50)
        check(store.int("pings.dailyCap") == 20, "[set clamped] the server's clamped value shows, not what was sent")
        stand.answers["p2-set"] = answered(503, #""error":"settings_unwritable""#)
        await store.set("pings.gapMinutes", .number(90), raw: 90)
        check(store.int("pings.gapMinutes") == 45 && store.line == DropItP2.savedFailedLine, "[set refused] the old value comes back and the line says why")
        stand.answers["p2-set"] = answered(400, #""error":"invalid_settings","message":"Quiet hours need a start and an end.""#)
        await store.set("pings.gapMinutes", .number(90), raw: 90)
        check(store.int("pings.gapMinutes") == 45 && store.line == "Quiet hours need a start and an end.", "[set refused] the server's own reason shows when it gives one")
        stand.answers["p2-set"] = nil
        await store.set("checkin.weekday", .number(3), raw: 3)
        check(store.int("checkin.weekday") == 1 && store.line == DropItP2.savedUnreachableLine, "[set unreachable] an unreachable helper reverts too, with the settings line, never the drop's 'words are still in the box'")

        // A server without the P2 settings hides the card
        stand.answers["p2"] = details(#"{"transport":"unsupported","httpStatus":404}"#)
        await store.readSettings()
        check(store.settings == nil, "[old server] no settings: the card hides")
        stand.answers["p2"] = details(#"{"transport":"unavailable"}"#)
        stand.answers["p2-set"] = nil
        let empty = DropItP2Store(run: { a, i in try await stand.run(a, i) }, defaults: defaults)
        await empty.set("pings.on", .bool(false), raw: false)
        check(empty.settings == nil && empty.line == nil, "[no settings] a change before a read sends nothing")

        // Words
        for text in [DropItP2.groupTitle, DropItP2.reminderBody, DropItP2.savedFailedLine, DropItP2.savedUnreachableLine] {
            check(text.range(of: "[\u{2014}\u{2013}\u{2192}]|->", options: .regularExpression) == nil, "[copy] no em dash, en dash or arrow: \(text)")
        }
        check(DropIt.serverActions == ["reminder_done", "snooze_1h", "snooze_tomorrow", "when:tomorrow_9", "when:monday_9", "dismiss"], "[actions] the six server actions")
        check(DropIt.Action(id: "snooze_1h", label: "Snooze").isServerAction && !DropIt.Action(id: "open_card", label: "Open").isServerAction
              && !DropIt.Action(id: "choose:o1", label: "x").isServerAction, "[actions] only the server actions are server actions")
        print("drop it p2 checks: \(passed) passed")
    }
}
