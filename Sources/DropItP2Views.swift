import SwiftUI

// 0.5.372: Settings, Work and agents, "COS reaching out" (work.reach). The same rows and words as COS Control Web
// (server/web-control/panes/settings.js). Shown only while Drop it is on and the server answers its P2 settings.
// Each change sends one field (DropItP2Store.set); the row then shows what the server saved.

struct DropItReachRows: View {
    @ObservedObject var store: DropItP2Store

    private func label(_ id: String) -> String { SettingsHubCatalog.item(id)?.label ?? id }
    private func detail(_ id: String) -> String { SettingsHubCatalog.item(id)?.detail ?? "" }

    private func row<C: View>(_ id: String, @ViewBuilder _ control: () -> C) -> some View {
        SettingsHubRow(label: label(id), detail: detail(id), anchor: "item." + id, control: control)
    }
    private func toggle(_ path: String, _ accessibility: String) -> some View {
        Toggle(isOn: Binding(get: { store.bool(path) }, set: { store.setBool(path, $0) })) { EmptyView() }
            .toggleStyle(COSSwitchStyle())
            .accessibilityLabel(accessibility)
    }
    private func switchRow(_ id: String, _ path: String) -> some View {
        row(id) { toggle(path, label(id)) }
    }
    /// A named switch under a row (one of its kinds).
    private func sub(_ title: String, _ path: String, _ id: String) -> some View {
        SettingsHubRow(label: title, detail: "", anchor: "item.\(id).\(path)") { toggle(path, title) }
    }
    private func stepper(_ id: String, _ path: String, _ range: ClosedRange<Int>, step: Int = 1, unit: String = "") -> some View {
        row(id) {
            COSStepper(label(id), value: Binding(get: { store.int(path) }, set: { store.setInt(path, min(range.upperBound, max(range.lowerBound, $0))) }),
                       in: range, step: step, valueText: unit.isEmpty ? "\(store.int(path))" : "\(store.int(path)) \(unit)", showsLabel: false)
        }
    }
    private func time(_ path: String, _ accessibility: String) -> some View {
        DatePicker("", selection: Binding(
            get: {
                let m = DropItP2.minutes(store.text(path)) ?? 540
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let value = DropItP2.hhmm((c.hour ?? 0) * 60 + (c.minute ?? 0))
                if value != store.text(path) { store.setText(path, value) }
            }), displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.field)
            .frame(width: 96)
            .accessibilityLabel(accessibility)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switchRow("REACH-01", "pings.on")
                stepper("REACH-02", "pings.dailyCap", 0...20)
                stepper("REACH-03", "pings.perSource", 1...10)
                stepper("REACH-04", "pings.gapMinutes", 0...240, step: 5, unit: "min")
                row("REACH-05") {
                    HStack(spacing: 6) {
                        time("pings.quietStart", "Quiet from")
                        Text("to").font(COSType.body(12.5)).foregroundStyle(TodayInk.sub)
                        time("pings.quietEnd", "Quiet until")
                    }
                }
                switchRow("REACH-06", "pings.weekendsQuiet")
                row("REACH-07") { time("pings.firstBanner", label("REACH-07")) }
            }
            Group {
                row("REACH-08") { EmptyView() }
                sub("Meeting prep", "pings.sources.prep", "REACH-08")
                sub("Agents finishing", "pings.sources.agent", "REACH-08")
                sub("Follow-ups ready", "pings.sources.followups", "REACH-08")
                sub("Threads gone quiet", "pings.sources.stale", "REACH-08")
                sub("Red signals", "pings.sources.signals", "REACH-08")
            }
            Group {
                SteerField(store: store, id: "REACH-09", path: "steer.about", label: label("REACH-09"), detail: detail("REACH-09"))
                SteerField(store: store, id: "REACH-10", path: "steer.leaveAlone", label: label("REACH-10"), detail: detail("REACH-10"))
            }
            Group {
                switchRow("REACH-11", "followUps.on")
                if store.bool("followUps.on") {
                    sub("Work cards", "followUps.kinds.card", "REACH-11")
                    sub("Handoffs", "followUps.kinds.handoff", "REACH-11")
                    sub("Sessions", "followUps.kinds.session", "REACH-11")
                    sub("Threads", "followUps.kinds.thread", "REACH-11")
                }
            }
            Group {
                switchRow("REACH-12", "checkin.on")
                if store.bool("checkin.on") {
                    SettingsHubRow(label: "Day and time", detail: "", anchor: "item.REACH-12.when") {
                        HStack(spacing: 8) {
                            COSDropdown("Day", selection: Binding(get: { store.int("checkin.weekday") }, set: { store.setInt("checkin.weekday", $0) }),
                                        options: DropItP2.weekdays.map { COSDropdownOption($0.0, $0.1) }, showsLabel: false)
                                .frame(width: 130)
                            time("checkin.time", "Check-in time")
                        }
                    }
                }
            }
            Group {
                row("REACH-13") { time("reminders.defaultTime", label("REACH-13")) }
                stepper("REACH-14", "reminders.snoozeMinutes", 5...1440, step: 5, unit: "min")
                switchRow("REACH-15", "reminders.banners")
                row("REACH-16") { toggle("reminders.lensPush", label("REACH-16")) }
            }
            Group {
                row("REACH-17") { EmptyView() }
                sub("Follow-ups on your drops", "banners.resolution", "REACH-17")
                sub("Meeting prep", "banners.prep", "REACH-17")
                sub("Agents finishing", "banners.agent", "REACH-17")
                sub("Follow-ups ready", "banners.followups", "REACH-17")
                sub("Threads and signals", "banners.stale", "REACH-17")
                sub("Weekly check-in", "banners.checkin", "REACH-17")
            }
            if let line = store.line {
                Text(line).font(COSType.body(12)).foregroundStyle(TodayInk.sub).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20).padding(.vertical, 10)
            }
        }
    }
}

/// A steer line: up to 300 characters, saved on Return or Save.
private struct SteerField: View {
    @ObservedObject var store: DropItP2Store
    let id: String
    let path: String
    let label: String
    let detail: String
    @State private var draft: String?

    var body: some View {
        let saved = store.text(path)
        SettingsHubRow(label: label, detail: detail, anchor: "item." + id) {
            HStack(spacing: 6) {
                TextField("Words, comma separated", text: Binding(get: { draft ?? saved }, set: { draft = String($0.prefix(300)) }))
                    .textFieldStyle(.plain)
                    .cosField()
                    .frame(width: 200)
                    .onSubmit(save)
                    .accessibilityLabel(label)
                if let draft, draft != saved {
                    Button("Save", action: save).buttonStyle(TodayLinkStyle(size: 13))
                }
            }
        }
    }
    private func save() {
        guard let value = draft, value != store.text(path) else { draft = nil; return }
        store.setText(path, value)
        draft = nil
    }
}
