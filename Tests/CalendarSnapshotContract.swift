import Foundation

// PH plan P1: the calendar snapshot Control writes for the server (server/lib/calendar-source.ts parseSnapshot). Compiled
// with Sources/CalendarSnapshotCore.swift and Sources/SessionUsageCore.swift only. With a second argument it also writes a
// sample snapshot there, so the server's parser can be run against Control's real output.

@main @MainActor
struct CalendarSnapshotContract {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1; FileHandle.standardError.write(Data("FAIL: calendar snapshot: \(what)\n".utf8)) }
    }

    static func main() async throws {
        typealias C = CalendarSnapshotCore
        let now = ISO8601DateFormatter().date(from: "2026-11-09T15:00:00Z")!

        // Meeting links: allowlisted hosts over https only, url then location then notes.
        check(C.meetingURL([nil, "Room 4", "Join https://acme.zoom.us/j/123?pwd=x now"]) == "https://acme.zoom.us/j/123?pwd=x", "zoom link in notes")
        check(C.meetingURL(["https://evil.example/zoom.us/j/1"]) == nil, "lookalike path is not a zoom host")
        check(C.meetingURL(["https://zoom.us.evil.example/j/1"]) == nil, "lookalike host is not a zoom host")
        check(C.meetingURL(["http://meet.google.com/abc"]) == nil, "plain http is refused")
        check(C.meetingURL(["https://meet.google.com/abc-defg-hij"]) == "https://meet.google.com/abc-defg-hij", "google meet")
        check(C.meetingURL(["https://teams.microsoft.com/l/meetup-join/1", "https://acme.zoom.us/j/9"]) == "https://teams.microsoft.com/l/meetup-join/1", "first candidate wins")

        // Attendee domains, never full addresses.
        check(C.emailDomain(URL(string: "mailto:Pat.Lee@Example.COM")) == "example.com", "mailto domain, lowercased")
        check(C.emailDomain(URL(string: "https://example.com")) == nil, "non-mailto has no domain")
        check(C.attendeeName("pat.lee@example.com") == nil, "an address in the name field is dropped")
        check(C.attendeeName("Pat Lee") == "Pat Lee", "a display name is kept")
        check(C.attendeeName("  ") == nil && C.attendeeName(nil) == nil, "blank or missing name is nil")

        // Only selected calendars' events are written, whatever the reader returned.
        let cals = [
            C.Calendar(id: "a", title: "Work", account: "m@example.com", sourceType: "exchange", shared: false, selected: true),
            C.Calendar(id: "b", title: "Holidays", account: "Subscribed", sourceType: "subscription", shared: true, selected: false),
        ]
        func ev(_ cal: String, _ title: String) -> C.Event {
            C.Event(calendarId: cal, eventId: "e-\(title)", externalId: "x-\(title)", occurrenceStart: C.iso(now), start: C.iso(now),
                    end: nil, allDay: false, floating: false, title: title, myStatus: "accepted", isOrganizer: false, attendees: [], meetingUrl: nil)
        }
        let snap = C.snapshot(calendars: cals, events: [ev("a", "Pipeline"), ev("b", "Holiday")], now: now)
        check(snap.events.map(\.title) == ["Pipeline"], "unselected calendar contributes no events")
        check(snap.access == "granted" && snap.version == 1, "envelope")
        check(snap.windowStart < snap.writtenAt && snap.writtenAt < snap.windowEnd, "window brackets now")

        let tomb = C.tombstone(access: "denied", now: now)
        check(tomb.events.isEmpty && tomb.calendars.isEmpty && tomb.access == "denied", "tombstone carries nothing")

        // The keys the server's parser reads (calendar-source.ts). A rename here breaks the server silently.
        let json = try JSONSerialization.jsonObject(with: try C.encode(snap)) as! [String: Any]
        check(Set(json.keys) == ["version", "writtenAt", "windowStart", "windowEnd", "access", "calendars", "events"], "envelope keys")
        let event = (json["events"] as! [[String: Any]])[0]
        let wantEvent: Set<String> = ["calendarId", "eventId", "externalId", "occurrenceStart", "start", "allDay", "floating", "title", "myStatus", "isOrganizer", "attendees"]
        check(wantEvent.isSubset(of: Set(event.keys)), "event keys \(Set(event.keys))")
        let cal = (json["calendars"] as! [[String: Any]])[0]
        check(Set(cal.keys).isSuperset(of: ["id", "title", "sourceType", "shared", "selected"]), "calendar keys")

        // The data dir follows COS_DATA_DIR in ~/.cos-glasses/.env, else the default.
        let home = URL(fileURLWithPath: "/Users/someone")
        check(C.dataDirectory(home: home, envText: "COS_DATA_DIR=/tmp/cosdata\n").path == "/tmp/cosdata", "COS_DATA_DIR honored")
        check(C.dataDirectory(home: home, envText: "# nothing\n").path == "/Users/someone/.cos-glasses/data", "default data dir")

        // The write: folder 0700, file 0600, and a symlinked folder is refused.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("cal-contract-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = C.snapshotURL(dataDirectory: scratch)
        try C.write(try C.encode(snap), to: file)
        let fileMode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        let dirMode = (try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue
        check(fileMode == 0o600, "file mode \(String(fileMode ?? -1, radix: 8))")
        check(dirMode == 0o700, "folder mode \(String(dirMode ?? -1, radix: 8))")
        let linked = scratch.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("real"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: scratch.appendingPathComponent("real"))
        let refused = (try? C.write(Data("{}".utf8), to: linked.appendingPathComponent("snapshot.json"))) == nil
        check(refused, "a symlinked folder is refused")


        // 0.5.379 (QA B2, W20, W22): one refresh, step by step (CalendarSnapshotCore.refresh). A fake reader stands in for
        // EventKit; `live` is the store's connected-and-not-cancelled; the file calls are counted.
        final class Probe { var live = true; var access = "granted"; var picked: Set<String> = ["a"]; var writes = 0; var removes = 0; var reads = 0
            var onCalendars: () -> Void = {}; var onEvents: () -> Void = {}; var onWrite: () -> Void = {} }
        func run(_ p: Probe) async -> C.WriteOutcome {
            await C.refresh(live: { p.live }, access: { p.access }, selected: { p.picked },
                            calendars: { ids in p.reads += 1; p.onCalendars(); return cals.map { var c = $0; c.selected = ids.contains(c.id); return c } },
                            events: { _, _ in p.reads += 1; p.onEvents(); return [ev("a", "Pipeline")] },
                            write: { _ in p.writes += 1; p.onWrite() }, remove: { p.removes += 1 }, now: now)
        }
        var p = Probe()
        check(await run(p) == .wrote(cals) && p.writes == 1 && p.removes == 0, "granted with a calendar picked writes once")
        // B2: Turn off lands during either EventKit await: nothing is written after it.
        p = Probe(); p.onCalendars = { p.live = false }
        check(await run(p) == .stopped && p.writes == 0 && p.reads == 1, "turned off during the calendars read: no write, no events read")
        p = Probe(); p.picked = []; p.onCalendars = { p.live = false }
        check(await run(p) == .stopped && p.removes == 0, "turned off during the read with nothing picked: stopped, the picker list is not put back")
        p = Probe(); p.onEvents = { p.live = false }
        check(await run(p) == .stopped && p.writes == 0, "turned off during the events read: no write")
        // A write that lost the race anyway is deleted again.
        p = Probe(); p.onWrite = { p.live = false }
        check(await run(p) == .stopped && p.writes == 1 && p.removes == 1, "a write that lost the race is removed again")
        p = Probe(); p.live = false
        check(await run(p) == .stopped && p.writes == 0 && p.removes == 0 && p.reads == 0, "not connected: nothing at all, not even a read")
        // W20: granted with nothing picked is not configured: no snapshot (an empty one reads as an empty day), any old one removed.
        p = Probe(); p.picked = []
        if case .notConfigured(let listed) = await run(p) { check(listed.count == 2 && !listed.contains(where: \.selected), "the picker still lists the calendars") }
        else { check(false, "granted, zero picked is not configured") }
        check(p.writes == 0 && p.removes == 1, "granted, zero picked writes nothing and removes an old snapshot")
        p = Probe(); p.picked = ["gone"]
        if case .notConfigured = await run(p) {} else { check(false, "a picked calendar that no longer exists is not a selection") }
        check(p.writes == 0, "a stale pick writes nothing")
        // W22: writeOnly or denied leaves the file absent (the CalendarFetch bridge still answers), never a tombstone.
        for state in ["writeOnly", "denied", "restricted", "notDetermined"] {
            p = Probe(); p.access = state
            check(await run(p) == .noAccess && p.writes == 0 && p.removes == 1, "\(state) leaves no snapshot")
        }
        if CommandLine.arguments.count > 2 {
            try C.encode(C.snapshot(calendars: cals, events: [ev("a", "Pipeline"), ev("b", "Holiday")], now: Date())).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        if failures > 0 { exit(1) }
        print("PASS: calendar snapshot contract (links, domains, selection, tombstone, keys, data dir, modes, refresh race, zero picked, no access)")
    }
}
