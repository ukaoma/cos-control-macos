import Foundation
import Combine

// 0.5.372 (server Drop it P2, 6.99.11): the Mac half of "COS reaching out".
//
// - Banners: the server decides what may interrupt (its budget, quiet hours, steer, which kinds may interrupt) and puts each
//   banner in an outbox, once per server boot. This reads the outbox every 20 s with its cursor and shows each banner through
//   the existing notifier. A cursor from another boot shows only banners from the last 10 minutes, so a restart or a first
//   install never floods Notification Center.
// - Reminders: a local backup. Each pending reminder is also a scheduled macOS notification with the server's own id
//   (`reminder-<dropId>`), so a reminder fires on time even if the server is busy; the server's banner for the same reminder
//   carries the same id and is skipped when the backup already showed. Done, Snooze and Undo on the server remove or move it
//   on the next read. "Notify me about reminders" (reminders.banners) off removes them all.
// - Settings: GET/PUT /api/drops/settings/p2. Each change sends one field; the row shows what the server saved (it clamps).

enum DropItP2 {
    static let groupTitle = "COS reaching out"
    static let bannerPollSeconds: UInt64 = 20
    static let reminderSyncEvery = 3          // reminder reads happen every third banner read (60 s)
    static let settingsReadEvery = 15         // settings reads every fifteenth (5 min), and after every change
    static let freshBootWindow: TimeInterval = 10 * 60
    /// macOS keeps 64 pending requests per app; the backup takes at most this many, the soonest first.
    static let reminderBackupMax = 40
    static let reminderHorizon: TimeInterval = 8 * 24 * 3600
    static let reminderBody = "From your COS chat."
    static let savedFailedLine = "That setting did not save. Try again."
    static let savedUnreachableLine = "The COS server is not answering, so that setting did not save."

    /// Why a settings change did not save: the server's own one-line reason when it gave one, else the settings line. Drop it's
    /// fallbacks ("That did not go through", "Your words are still in the box") are written for drops, not for a settings row.
    static func setFailedLine(_ reply: DropIt.Reply) -> String {
        switch reply {
        case .refused(_, let line) where line != DropIt.failedLine: return line
        case .off, .unsupported, .noToken: return DropIt.line(reply) ?? savedFailedLine
        case .unreachable: return savedUnreachableLine
        default: return savedFailedLine
        }
    }

    struct Banner: Equatable, Sendable {
        var seq: Int
        var at: Date
        var title: String
        var line: String
        var feedIds: [String]
        var sources: [String]
        var notifyId: String?
    }
    struct Reminder: Equatable, Sendable {
        var id: String
        var at: Date
        var title: String
        var notifyId: String
    }
    /// One notification to post: now (`fireAt` nil) or at a time.
    struct Notice: Equatable, Sendable {
        var identifier: String
        var title: String
        var body: String
        var userInfo: [String: String]
        var fireAt: Date?
    }

    static func banner(_ value: JSONValue) -> Banner? {
        guard let o = value.object, let seq = o["seq"]?.int, let at = DropIt.date(o["at"]), let title = o["title"]?.string,
              let line = o["line"]?.string else { return nil }
        return Banner(seq: seq, at: at, title: title, line: line, feedIds: (o["feedIds"]?.array ?? []).compactMap(\.string),
                      sources: (o["sources"]?.array ?? []).compactMap(\.string), notifyId: o["notifyId"]?.string)
    }
    static func reminder(_ value: JSONValue) -> Reminder? {
        guard let o = value.object, let id = o["id"]?.string, let at = DropIt.date(o["at"]), let title = o["title"]?.string,
              let notify = o["notifyId"]?.string else { return nil }
        return Reminder(id: id, at: at, title: title, notifyId: notify)
    }

    /// The banners a read should show. Same boot: everything after the cursor (the server filters by seq too). Another boot,
    /// or no cursor yet: only the last 10 minutes.
    static func toShow(_ banners: [Banner], sameBoot: Bool, after: Int, now: Date) -> [Banner] {
        sameBoot ? banners.filter { $0.seq > after } : banners.filter { now.timeIntervalSince($0.at) <= freshBootWindow }
    }

    static func notice(_ banner: Banner, boot: String) -> Notice {
        var info = ["cosChat": "1"]
        if let first = banner.feedIds.first { info["inboxID"] = first }
        return Notice(identifier: banner.notifyId ?? "cos-ping-\(boot)-\(banner.seq)", title: banner.title, body: banner.line,
                      userInfo: info, fireAt: nil)
    }
    static func notice(_ reminder: Reminder) -> Notice {
        Notice(identifier: reminder.notifyId, title: reminder.title, body: reminderBody,
               userInfo: ["cosChat": "1", "dropReminder": reminder.id], fireAt: reminder.at)
    }

    /// The local backup's plan. `scheduled`: the pending reminder notifications now, by id, with their fire dates.
    /// Adds a pending reminder that is not scheduled, or scheduled at another time; removes one the server no longer has.
    /// With `allowed` false (reminders.banners off), removes every one and adds none.
    static func reminderPlan(pending: [Reminder], scheduled: [String: Date], allowed: Bool, now: Date) -> (add: [Notice], remove: [String]) {
        let ours = scheduled.filter { $0.key.hasPrefix("reminder-") }
        guard allowed else { return ([], ours.keys.sorted()) }
        let keep = pending.filter { $0.at > now.addingTimeInterval(5) && $0.at < now.addingTimeInterval(reminderHorizon) }
            .sorted { $0.at < $1.at }.prefix(reminderBackupMax)
        let wanted = Set(keep.map(\.notifyId))
        let add = keep.filter { r in ours[r.notifyId].map { abs($0.timeIntervalSince(r.at)) > 1 } ?? true }.map(notice)
        return (add, ours.keys.filter { !wanted.contains($0) }.sorted())
    }

    // MARK: Settings paths

    /// The value at a dotted path ("pings.sources.prep") in the settings.
    static func value(_ settings: [String: JSONValue]?, _ path: String) -> JSONValue? {
        var node: JSONValue? = settings.map { .object($0) }
        for key in path.split(separator: ".") { node = node?.object?[String(key)] }
        return node
    }
    /// The one-field change for a dotted path: {"pings": {"sources": {"prep": false}}}.
    static func change(_ path: String, _ value: Any) -> [String: Any] {
        var out: Any = value
        for key in path.split(separator: ".").reversed() { out = [String(key): out] }
        return out as? [String: Any] ?? [:]
    }
    /// The settings with one field set locally (shown at once; the server's answer replaces it).
    static func setting(_ settings: [String: JSONValue], _ path: String, _ value: JSONValue) -> [String: JSONValue] {
        let keys = path.split(separator: ".").map(String.init)
        func put(_ node: [String: JSONValue], _ rest: ArraySlice<String>) -> [String: JSONValue] {
            guard let key = rest.first else { return node }
            var copy = node
            copy[key] = rest.count == 1 ? value : .object(put(node[key]?.object ?? [:], rest.dropFirst()))
            return copy
        }
        return put(settings, keys[...])
    }

    static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }
    static func hhmm(_ minutes: Int) -> String { String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60) }
    static let weekdays: [(Int, String)] = [(1, "Monday"), (2, "Tuesday"), (3, "Wednesday"), (4, "Thursday"), (5, "Friday"), (6, "Saturday"), (0, "Sunday")]
}

// MARK: The store

@MainActor
final class DropItP2Store: ObservableObject {
    typealias Run = @MainActor ([String], Data?) async throws -> HelperResponse

    /// The P2 settings as the server last answered them. nil: not read yet, or a server without them.
    @Published private(set) var settings: [String: JSONValue]?
    /// The line under the card: why a change did not save.
    @Published var line: String?
    /// How many banners and reminder backups this run posted (the checks read them).
    private(set) var posted: [DropItP2.Notice] = []

    var run: Run
    var available: @MainActor () -> Bool = { false }
    var post: @MainActor (DropItP2.Notice) -> Void = { _ in }
    var delivered: @MainActor () async -> Set<String> = { [] }
    var scheduled: @MainActor () async -> [String: Date] = { [:] }
    var removePending: @MainActor ([String]) -> Void = { _ in }
    var now: @MainActor () -> Date = { Date() }
    let defaults: UserDefaults

    static let bootKey = "dropItP2.bannerBoot"
    static let seqKey = "dropItP2.bannerSeq"

    private var loop: Task<Void, Never>?
    private var tick = 0

    /// No default closure in the signature: a main-actor default argument does not compile in the whole app (Swift 6).
    init(run: Run? = nil, defaults: UserDefaults = .standard) {
        self.run = run ?? { _, _ in throw CancellationError() }
        self.defaults = defaults
    }

    private func ask(_ arguments: [String], _ stdin: Data? = nil) async -> DropIt.Reply {
        do { return DropIt.reply(try await run(arguments, stdin).details) } catch { return .unreachable }
    }

    // MARK: The loop

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.step()
                try? await Task.sleep(nanoseconds: DropItP2.bannerPollSeconds * 1_000_000_000)
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }

    /// One pass: banners every time, reminders every third, settings every fifteenth. Nothing while Drop it is off.
    func step() async {
        guard available() else { tick = 0; return }
        if tick % DropItP2.settingsReadEvery == 0 || settings == nil { await readSettings() }
        await pollBanners()
        if tick % DropItP2.reminderSyncEvery == 0 { await syncReminders() }
        tick += 1
    }

    func pollBanners() async {
        let boot = defaults.string(forKey: Self.bootKey)
        var args = DropIt.call("banners")
        if let boot { args += ["--boot", boot, "--seq", String(defaults.integer(forKey: Self.seqKey))] }
        guard case .ok(let details) = await ask(args), let serverBoot = details["bootId"]?.string else { return }
        let banners = (details["banners"]?.array ?? []).compactMap(DropItP2.banner)
        let show = DropItP2.toShow(banners, sameBoot: boot == serverBoot, after: defaults.integer(forKey: Self.seqKey), now: now())
        let shown = show.isEmpty ? [] : await delivered()
        for banner in show {
            let notice = DropItP2.notice(banner, boot: serverBoot)
            // The reminder's local backup already showed it: one reminder, one notification.
            if banner.notifyId != nil, shown.contains(notice.identifier) { continue }
            post(notice)
            posted.append(notice)
        }
        defaults.set(serverBoot, forKey: Self.bootKey)
        // A new boot starts its cursor over; the same boot only moves forward.
        let floor = boot == serverBoot ? defaults.integer(forKey: Self.seqKey) : 0
        defaults.set(max(floor, details["seq"]?.int ?? 0, banners.map(\.seq).max() ?? 0), forKey: Self.seqKey)
    }

    func syncReminders() async {
        let allowed = DropItP2.value(settings, "reminders.banners")?.bool ?? true
        var pending: [DropItP2.Reminder] = []
        if allowed {
            guard case .ok(let details) = await ask(DropIt.call("reminders")) else { return }
            pending = (details["reminders"]?.array ?? []).compactMap(DropItP2.reminder)
        }
        let plan = DropItP2.reminderPlan(pending: pending, scheduled: await scheduled(), allowed: allowed, now: now())
        if !plan.remove.isEmpty { removePending(plan.remove) }
        for notice in plan.add { post(notice); posted.append(notice) }
    }

    // MARK: Settings

    func readSettings() async {
        let reply = await ask(DropIt.call("p2"))
        switch reply {
        case .ok(let details): if let s = details["settings"]?.object { settings = s }
        case .unsupported, .off: settings = nil
        default: break
        }
    }

    /// One field. Shown at once; the server's answer (clamped) replaces it. A refusal puts the old value back and says why.
    func set(_ path: String, _ value: JSONValue, raw: Any) async {
        guard let before = settings else { return }
        settings = DropItP2.setting(before, path, value)
        line = nil
        guard let body = DropIt.json(DropItP2.change(path, raw)) else { settings = before; return }
        let reply = await ask(DropIt.call("p2-set"), body)
        guard case .ok(let details) = reply, let saved = details["settings"]?.object else {
            settings = before
            line = DropItP2.setFailedLine(reply)
            return
        }
        settings = saved
        // A reminder switch or time may change what the backup holds.
        if path.hasPrefix("reminders.") { await syncReminders() }
    }

    func bool(_ path: String) -> Bool { DropItP2.value(settings, path)?.bool ?? false }
    func int(_ path: String) -> Int { DropItP2.value(settings, path)?.int ?? 0 }
    func text(_ path: String) -> String { DropItP2.value(settings, path)?.string ?? "" }
    func setBool(_ path: String, _ on: Bool) { Task { await set(path, .bool(on), raw: on) } }
    func setInt(_ path: String, _ n: Int) { Task { await set(path, .number(Double(n)), raw: n) } }
    func setText(_ path: String, _ t: String) { Task { await set(path, .string(t), raw: t) } }
}
