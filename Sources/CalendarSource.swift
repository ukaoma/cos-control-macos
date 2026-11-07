import AppKit
import EventKit
import Foundation
import SwiftUI

// PH plan P1 (2026-11-07): every calendar macOS Calendar has (Exchange, iCloud, each Google account, subscribed ICS),
// read through EventKit here and written as a local snapshot the COS server reads (server/lib/calendar-source.ts).
//
// - Calendars access is asked for only when the Settings row is tapped, never at launch.
// - Only calendars the owner picks are written. Nothing is picked after the grant.
// - Notes are scanned in memory for an allowlisted meeting link and never stored.
// - The file is ~/.cos-glasses/data/calendar/snapshot.json (or under COS_DATA_DIR from ~/.cos-glasses/.env): folder 0700,
//   file 0600, atomic, class C protection (never class B: the keybag locks minutes after the screen does).
// - Losing access writes an `access: denied` tombstone, so the server stops using events it can no longer vouch for.
// - Turning the row off deletes the file: the server goes back to what it did before (the starter-kit bridge, if any).

// MARK: EventKit (an actor: EKEventStore is not Sendable)

actor CalendarReader {
    private let store = EKEventStore()

    static func accessState() -> String {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            switch status {
            case .fullAccess: return "granted"
            case .writeOnly, .denied: return "denied"
            case .restricted: return "restricted"
            case .notDetermined: return "notDetermined"
            @unknown default: return "denied"
            }
        }
        switch status {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        default: return "denied"
        }
    }

    /// The system prompt. Only from a tap on the Settings row.
    func requestAccess() async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            if #available(macOS 14.0, *) {
                store.requestFullAccessToEvents { granted, _ in done.resume(returning: granted) }
            } else {
                store.requestAccess(to: .event) { granted, _ in done.resume(returning: granted) }
            }
        }
    }

    func reset() { store.reset() }

    func calendars(selected: Set<String>) -> [CalendarSnapshotCore.Calendar] {
        store.calendars(for: .event).map { cal in
            let type: String
            switch cal.type {
            case .exchange: type = "exchange"
            case .calDAV: type = "caldav"
            case .subscription: type = "subscription"
            case .birthday: type = "birthdays"
            case .local: type = "local"
            @unknown default: type = "other"
            }
            return CalendarSnapshotCore.Calendar(
                id: cal.calendarIdentifier, title: cal.title, account: cal.source?.title, sourceType: type,
                shared: cal.type == .subscription || !cal.allowsContentModifications,
                selected: selected.contains(cal.calendarIdentifier))
        }
        .sorted { ($0.account ?? "", $0.title) < ($1.account ?? "", $1.title) }
    }

    func events(calendarIDs: Set<String>, now: Date) -> [CalendarSnapshotCore.Event] {
        let picked = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !picked.isEmpty else { return [] }
        let (start, end) = CalendarSnapshotCore.window(now: now)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: picked)
        return store.events(matching: predicate).compactMap { e in
            guard let calendar = e.calendar, let startDate = e.startDate else { return nil }
            let participants = e.attendees ?? []
            let me = participants.first { $0.isCurrentUser }
            let isOrganizer = e.organizer?.isCurrentUser == true
            let status: String
            switch me?.participantStatus {
            case .accepted?: status = "accepted"
            case .declined?: status = "declined"
            case .tentative?: status = "tentative"
            case .pending?: status = "pending"
            default: status = isOrganizer ? "accepted" : "none"
            }
            let attendees = participants.filter { !$0.isCurrentUser }.prefix(200).map {
                CalendarSnapshotCore.Attendee(name: $0.name, domain: CalendarSnapshotCore.emailDomain($0.url))
            }
            // Notes are read here, in memory, for a meeting link only. They are never stored.
            let link = CalendarSnapshotCore.meetingURL([e.url?.absoluteString, e.location, e.notes])
            return CalendarSnapshotCore.Event(
                calendarId: calendar.calendarIdentifier, eventId: e.eventIdentifier,
                externalId: e.calendarItemExternalIdentifier,
                occurrenceStart: CalendarSnapshotCore.iso(e.occurrenceDate ?? startDate),
                start: CalendarSnapshotCore.iso(startDate), end: e.endDate.map(CalendarSnapshotCore.iso),
                allDay: e.isAllDay, floating: e.timeZone == nil, title: e.title ?? "",
                myStatus: status, isOrganizer: isOrganizer, attendees: Array(attendees), meetingUrl: link)
        }
    }
}

// MARK: The store Settings draws

@MainActor
final class CalendarSourceStore: ObservableObject {
    static let connectedKey = "cos.calendar.connected"
    static let selectionKey = "cos.calendar.selectedIDs"
    static let refreshSeconds: UInt64 = 300

    @Published private(set) var connected: Bool
    @Published private(set) var access: String = CalendarReader.accessState()
    @Published private(set) var calendars: [CalendarSnapshotCore.Calendar] = []
    @Published private(set) var lastWritten: Date?
    @Published private(set) var line: String?
    @Published private(set) var busy = false

    private let reader = CalendarReader()
    private let defaults: UserDefaults
    private var loop: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.connected = defaults.bool(forKey: Self.connectedKey)
    }

    var selected: Set<String> { Set(defaults.stringArray(forKey: Self.selectionKey) ?? []) }
    private var file: URL { CalendarSnapshotCore.snapshotURL(dataDirectory: CalendarSnapshotCore.dataDirectory()) }

    /// At launch: resume a calendar the owner already connected. Never prompts.
    func resume() {
        guard connected else { return }
        access = CalendarReader.accessState()
        if access == "granted" { begin() } else { writeTombstone() }
    }

    /// The Settings row's Connect: the one place the system prompt can appear.
    func connect() async {
        busy = true
        defer { busy = false }
        let granted = access == "granted" ? true : await reader.requestAccess()
        access = CalendarReader.accessState()
        connected = true
        defaults.set(true, forKey: Self.connectedKey)
        if granted && access == "granted" {
            line = "Pick the calendars that count. None are picked yet."
            begin()
        } else {
            line = "Calendar access is off for COS Control."
            writeTombstone()
        }
    }

    /// Turn off: stop, forget the choice to connect, and delete the snapshot so the server falls back as before.
    func disconnect() {
        loop?.cancel(); loop = nil
        debounce?.cancel(); debounce = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        connected = false
        defaults.set(false, forKey: Self.connectedKey)
        calendars = []
        lastWritten = nil
        line = nil
        try? FileManager.default.removeItem(at: file)
    }

    func setSelected(_ id: String, _ on: Bool) {
        var ids = defaults.stringArray(forKey: Self.selectionKey) ?? []
        ids.removeAll { $0 == id }
        if on { ids.append(id) }
        defaults.set(ids, forKey: Self.selectionKey)
        if let i = calendars.firstIndex(where: { $0.id == id }) { calendars[i].selected = on }
        Task { await writeNow() }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    private func begin() {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.storeChanged() }
            }
        }
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.writeNow()
                try? await Task.sleep(nanoseconds: Self.refreshSeconds * 1_000_000_000)
            }
        }
    }

    /// EKEventStoreChanged comes in bursts while a calendar syncs: one write 2 s after the last.
    private func storeChanged() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.reader.reset()
            await self?.writeNow()
        }
    }

    func writeNow() async {
        guard connected else { return }
        access = CalendarReader.accessState()
        guard access == "granted" else { writeTombstone(); return }
        let picked = selected
        let now = Date()
        let cals = await reader.calendars(selected: picked)
        let events = await reader.events(calendarIDs: picked, now: now)
        calendars = cals
        do {
            let data = try CalendarSnapshotCore.encode(CalendarSnapshotCore.snapshot(calendars: cals, events: events, now: now))
            try CalendarSnapshotCore.write(data, to: file)
            lastWritten = now
        } catch {
            line = "Couldn't save the calendar for COS. It will try again in 5 minutes."
        }
    }

    private func writeTombstone() {
        calendars = []
        guard let data = try? CalendarSnapshotCore.encode(CalendarSnapshotCore.tombstone(access: access, now: Date())) else { return }
        try? CalendarSnapshotCore.write(data, to: file)
    }
}

// MARK: Settings, General, Activity home: Calendars (CAL-01)

struct CalendarSettingsBlock: View {
    @ObservedObject var store: CalendarSourceStore

    var body: some View {
        let item = SettingsHubCatalog.item("CAL-01")
        VStack(alignment: .leading, spacing: 0) {
            SettingsHubRow(label: item?.label ?? "Calendars", detail: item?.detail ?? "", anchor: "item.CAL-01") { control }
            if store.connected && store.access == "granted" {
                ForEach(groups) { group in
                    Text(group.account).font(COSType.body(12, weight: .semibold)).foregroundStyle(TodayInk.sub)
                        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 2)
                    ForEach(group.calendars) { cal in
                        Toggle(isOn: Binding(get: { cal.selected }, set: { store.setSelected(cal.id, $0) })) {
                            Text(cal.title).font(COSType.body(13)).foregroundStyle(TodayInk.ink)
                        }
                        .toggleStyle(COSCheckStyle())
                        .padding(.horizontal, 20).padding(.vertical, 2)
                    }
                }
                Text(statusLine).font(COSType.body(12)).foregroundStyle(TodayInk.sub)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 20).padding(.vertical, 12)
            } else if let line = store.line {
                Text(line).font(COSType.body(12)).foregroundStyle(TodayInk.sub)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 20).padding(.bottom, 12)
            }
        }
    }

    @ViewBuilder private var control: some View {
        if !store.connected {
            Button("Connect") { Task { await store.connect() } }.buttonStyle(COSQuietButtonStyle()).disabled(store.busy)
        } else if store.access != "granted" {
            HStack(spacing: 8) {
                Button("Open Privacy Settings") { store.openPrivacySettings() }.buttonStyle(COSQuietButtonStyle())
                Button("Turn off") { store.disconnect() }.buttonStyle(COSQuietButtonStyle())
            }
        } else {
            Button("Turn off") { store.disconnect() }.buttonStyle(COSQuietButtonStyle())
        }
    }

    private struct AccountGroup: Identifiable {
        let account: String
        let calendars: [CalendarSnapshotCore.Calendar]
        var id: String { account }
    }

    private var groups: [AccountGroup] {
        let byAccount = Dictionary(grouping: store.calendars) { $0.account ?? "On this Mac" }
        return byAccount.keys.sorted().map { AccountGroup(account: $0, calendars: byAccount[$0] ?? []) }
    }

    private var statusLine: String {
        let picked = store.calendars.filter(\.selected).count
        var text = "\(picked) of \(store.calendars.count) calendars count."
        if let at = store.lastWritten {
            text += " Read at " + at.formatted(date: .omitted, time: .shortened) + "."
        }
        if let line = store.line, picked == 0 { text = line }
        return text
    }
}
