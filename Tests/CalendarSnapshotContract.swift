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

    static func main() throws {
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

        if CommandLine.arguments.count > 2 {
            try C.encode(C.snapshot(calendars: cals, events: [ev("a", "Pipeline"), ev("b", "Holiday")], now: Date())).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        if failures > 0 { exit(1) }
        print("PASS: calendar snapshot contract (links, domains, selection, tombstone, keys, data dir, modes)")
    }
}
