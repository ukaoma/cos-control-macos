import Foundation

// PH plan P1 (2026-11-07): the calendar snapshot's shape, window, link and domain rules, and the 0600 write. No EventKit and
// no UI, so Tests/CalendarSnapshotContract.swift compiles it with SessionUsageCore.swift alone. The EventKit reader and the
// Settings row are in CalendarSource.swift.

// MARK: Core (no EventKit, so tests can run it)

enum CalendarSnapshotCore {
    static let meetingHosts = ["zoom.us", "teams.microsoft.com", "meet.google.com"]
    /// Days back and ahead of today the snapshot covers.
    static let daysBack = 1
    static let daysAhead = 7

    struct Calendar: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var title: String
        var account: String?
        var sourceType: String
        var shared: Bool
        var selected: Bool
    }

    struct Attendee: Codable, Equatable, Sendable {
        var name: String?
        var domain: String?
    }

    struct Event: Codable, Equatable, Sendable {
        var calendarId: String
        var eventId: String?
        var externalId: String?
        var occurrenceStart: String
        var start: String
        var end: String?
        var allDay: Bool
        var floating: Bool
        var title: String
        var myStatus: String
        var isOrganizer: Bool
        var attendees: [Attendee]
        var meetingUrl: String?
    }

    struct Snapshot: Codable, Equatable, Sendable {
        var version = 1
        var writtenAt: String
        var windowStart: String
        var windowEnd: String
        var access: String
        var calendars: [Calendar]
        var events: [Event]
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// Yesterday's start through seven days ahead, in the Mac's time zone.
    static func window(now: Date, calendar: Foundation.Calendar = .current) -> (start: Date, end: Date) {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -daysBack, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: daysAhead + 1, to: today) ?? now
        return (start, end)
    }

    /// The first https link to an allowlisted meeting host, scanning the event URL, then location, then notes.
    static func meetingURL(_ candidates: [String?]) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in candidates.compactMap({ $0 }) where !text.isEmpty {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, options: [], range: range) {
                guard let url = match.url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { continue }
                if meetingHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    let s = url.absoluteString
                    return s.count <= 2048 ? s : nil
                }
            }
        }
        return nil
    }

    /// The domain of a mailto: participant URL. Full addresses are never kept.
    static func emailDomain(_ url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "mailto" else { return nil }
        let address = url.absoluteString.dropFirst("mailto:".count)
        guard let at = address.lastIndex(of: "@") else { return nil }
        let domain = address[address.index(after: at)...].lowercased()
        return domain.isEmpty || domain.count > 253 ? nil : String(domain)
    }

    /// A tombstone: the access state and no calendars or events.
    static func tombstone(access: String, now: Date) -> Snapshot {
        let stamp = iso(now)
        return Snapshot(writtenAt: stamp, windowStart: stamp, windowEnd: stamp, access: access, calendars: [], events: [])
    }

    /// Events from selected calendars only, whatever the reader returned.
    static func snapshot(calendars: [Calendar], events: [Event], now: Date) -> Snapshot {
        let (start, end) = window(now: now)
        let picked = Set(calendars.filter(\.selected).map(\.id))
        return Snapshot(writtenAt: iso(now), windowStart: iso(start), windowEnd: iso(end), access: "granted",
                        calendars: calendars, events: events.filter { picked.contains($0.calendarId) })
    }

    static func encode(_ snapshot: Snapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    /// ~/.cos-glasses/data, or COS_DATA_DIR as ~/.cos-glasses/.env sets it for the managed server.
    static func dataDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser, envText: String? = nil) -> URL {
        let text = envText ?? (try? String(contentsOf: home.appendingPathComponent(".cos-glasses/.env"), encoding: .utf8))
        if let text, let dir = CosCostRules.envValue(text, key: "COS_DATA_DIR") {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".cos-glasses/data")
    }

    static func snapshotURL(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("calendar", isDirectory: true).appendingPathComponent("snapshot.json")
    }

    /// Folder 0700, file 0600, atomic, class C. Refuses a symlinked folder.
    static func write(_ data: Data, to file: URL) throws {
        let fm = FileManager.default
        let folder = file.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try folder.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true { throw CocoaError(.fileWriteNoPermission) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
