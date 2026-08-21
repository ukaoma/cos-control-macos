import SwiftUI

/// Calendar + list + detail for the Activity Meetings library.
///
/// Speakers still owns identity correction ("Meetings to review"). This surface
/// is the saved-call browser: domain, duration, summary, transcript, copy.
struct MeetingLibraryBody: View {
    @ObservedObject var model: ControllerModel
    let onOpen: (LibraryMeeting) -> Void
    @State private var confirmRecoverAllOrphans = false
    @State private var confirmSaveAllStranded = false

    var body: some View {
        VStack(spacing: 0) {
            if !model.recoverableOrphans.isEmpty || !model.strandedCaptures.isEmpty {
                unsavedCaptureBanner
            }
            if !model.isLibraryQueryActive {
                MeetingMonthCalendar(
                    month: model.libraryMonth,
                    days: model.libraryDays,
                    selectedDay: model.libraryDay,
                    tint: ActivitySection.meetings.tint,
                    onShift: { model.shiftLibraryMonth($0) },
                    onSelectDay: { model.selectLibraryDay($0) }
                )
            }
            toolbar
            content
        }
        .onChange(of: model.libraryQuery) { _, _ in model.scheduleLibrarySearch() }
        .onChange(of: model.libraryDomainFilter) { _, _ in
            if model.isLibraryQueryActive { model.scheduleLibrarySearch() }
        }
        .task { await model.loadOrphans(quiet: true) }
        .confirmationDialog(
            "Recover all unsaved captures?",
            isPresented: $confirmRecoverAllOrphans,
            titleVisibility: .visible
        ) {
            Button("Recover all") { model.recoverAllOrphans() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Turns each unsaved capture into a meeting, one at a time. Session files are not deleted.")
        }
        .confirmationDialog(
            "Save still-live captures as meetings?",
            isPresented: $confirmSaveAllStranded,
            titleVisibility: .visible
        ) {
            Button("Save all") { model.saveAllStranded() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Finalizes each still-live G2 capture. Session files become meetings; they are not deleted.")
        }
    }

    private var unsavedCaptureBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Unsaved captures")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(COSPalette.amber)
            Text("Audio that never became a meeting. This is not Speakers’ Meetings to review.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ForEach(model.recoverableOrphans) { capture in
                HStack {
                    Text(capture.label)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer()
                    Button("Recover") { model.recoverOrphan(capture.sessionId) }
                        .controlSize(.small)
                        .disabled(model.busy || model.orphanBusy || capture.recovering)
                }
            }
            if model.recoverableOrphans.count > 1 {
                Button("Recover all") { confirmRecoverAllOrphans = true }
                    .controlSize(.small)
                    .disabled(model.busy || model.orphanBusy)
            }
            ForEach(model.strandedCaptures) { capture in
                HStack {
                    Text(capture.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                    Button("Save") { model.saveStranded(capture.sessionId) }
                        .controlSize(.small)
                        .disabled(model.busy || model.orphanBusy)
                }
            }
            if model.strandedCaptures.count > 1 {
                Button("Save all still-live") { confirmSaveAllStranded = true }
                    .controlSize(.small)
                    .disabled(model.busy || model.orphanBusy)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(COSPalette.amber.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search topics, ideas…", text: $model.libraryQuery)
                        .textFieldStyle(.plain)
                    if !model.libraryQuery.isEmpty {
                        Button {
                            model.libraryQuery = ""
                            model.scheduleLibrarySearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                .frame(maxWidth: 320)

                if domainOptions.count > 2 || model.isLibraryQueryActive {
                    Picker("Domain", selection: $model.libraryDomainFilter) {
                        Text("All domains").tag("all")
                        ForEach(domainOptions.filter { $0 != "all" }, id: \.self) { domain in
                            Text(domain.replacingOccurrences(of: "_", with: " ").localizedCapitalized).tag(domain)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 180)
                }

                Picker("Recency", selection: $model.searchRecency) {
                    ForEach(SearchRecency.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 150)
                .accessibilityLabel("Recency")

                Spacer()
                Text(listDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if model.isLibraryQueryActive, !model.librarySemanticAvailable {
                Text("Keyword only — meaning search needs the COS meeting index")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLibraryQueryActive {
            searchResults
        } else if model.libraryLoading && model.libraryMeetings.isEmpty {
            ProgressView("Loading meetings…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.libraryError, model.libraryMeetings.isEmpty {
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(30)
        } else if model.visibleLibraryMeetings.isEmpty {
            Text(emptyCopy)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(30)
        } else {
            List(model.visibleLibraryMeetings) { meeting in
                Button { onOpen(meeting) } label: {
                    meetingRow(meeting.title, subtitle: meeting.subtitle, sessionId: meeting.sessionId)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if model.librarySearching && model.librarySearchHits.isEmpty && model.librarySearchError == nil {
            ProgressView("Looking up…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.librarySearchError, model.librarySearchHits.isEmpty {
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(30)
        } else if model.librarySearchHits.isEmpty {
            Text("No meetings match that lookup.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(30)
        } else {
            List(model.visibleLibrarySearchHits) { hit in
                Button { onOpen(hit.meeting) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(hit.meeting.title)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            if !hit.snippet.isEmpty {
                                Text(hit.snippet)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Text(hit.meeting.subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(hit.matchLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(ActivitySection.meetings.tint.opacity(0.16))
                            )
                        if !hit.meeting.sessionId.isEmpty {
                            MeetingStatusPills(
                                isNew: model.isInboxNew(hit.meeting.sessionId),
                                tag: model.voiceTag(sessionId: hit.meeting.sessionId)
                            )
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func meetingRow(_ title: String, subtitle: String, sessionId: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !sessionId.isEmpty {
                MeetingStatusPills(
                    isNew: model.isInboxNew(sessionId),
                    tag: model.voiceTag(sessionId: sessionId)
                )
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var domainOptions: [String] {
        model.isLibraryQueryActive ? model.librarySearchDomainOptions : model.libraryDomainOptions
    }

    private var listDetail: String {
        if model.isLibraryQueryActive {
            if model.librarySearching && model.librarySearchHits.isEmpty { return "Looking up…" }
            return "\(model.visibleLibrarySearchHits.count) across stored calls"
        }
        let visible = model.visibleLibraryMeetings.count
        if let day = model.libraryDay { return "\(visible) on \(day)" }
        return "\(visible) in \(MeetingMonth.title(model.libraryMonth))"
    }

    private var emptyCopy: String {
        if let day = model.libraryDay {
            return "No meetings stored on \(day). Pick another day, or show the whole month."
        }
        return "No meetings stored in \(MeetingMonth.title(model.libraryMonth))."
    }
}

struct MeetingMonthCalendar: View {
    let month: String
    let days: [LibraryMeetingDay]
    let selectedDay: String?
    let tint: Color
    let onShift: (Int) -> Void
    let onSelectDay: (String?) -> Void

    var body: some View {
        let counts = Dictionary(uniqueKeysWithValues: days.map { ($0.date, $0.count) })
        VStack(spacing: 10) {
            HStack {
                Button { onShift(-1) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Previous month")
                Spacer()
                Text(MeetingMonth.title(month))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { onShift(1) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Next month")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
                ForEach(weekdayHeaders, id: \.self) { name in
                    Text(name)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
                ForEach(Array(monthCells.enumerated()), id: \.offset) { _, cell in
                    if let cell {
                        let count = counts[cell.date] ?? 0
                        Button {
                            onSelectDay(selectedDay == cell.date ? nil : cell.date)
                        } label: {
                            VStack(spacing: 3) {
                                Text("\(cell.day)")
                                    .font(.system(size: 11.5, weight: selectedDay == cell.date ? .semibold : .regular))
                                Circle()
                                    .fill(count > 0 ? tint : Color.clear)
                                    .frame(width: 5, height: 5)
                            }
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selectedDay == cell.date ? tint.opacity(0.18) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(count == 0)
                        .opacity(count == 0 ? 0.38 : 1)
                        .accessibilityLabel("\(cell.date)\(count == 0 ? ", no meetings" : ", \(count) meetings")")
                    } else {
                        Color.clear.frame(minHeight: 28)
                    }
                }
            }
            if selectedDay != nil {
                Button("All month") { onSelectDay(nil) }
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var weekdayHeaders: [String] {
        let cal = Calendar.current
        let names = cal.veryShortWeekdaySymbols
        let start = cal.firstWeekday - 1
        return Array(names[start...] + names[..<start])
    }

    private var monthCells: [DayCell?] {
        guard let start = MeetingMonth.parse(month) else { return [] }
        let cal = Calendar.current
        guard let range = cal.range(of: .day, in: .month, for: start) else { return [] }
        let leading = (cal.component(.weekday, from: start) - cal.firstWeekday + 7) % 7
        var cells: [DayCell?] = Array(repeating: nil, count: leading)
        for day in range {
            guard let date = cal.date(byAdding: .day, value: day - 1, to: start) else { continue }
            cells.append(DayCell(day: day, date: MeetingMonth.dayKey(date)))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }
}

private struct DayCell {
    let day: Int
    let date: String
}

struct MeetingLibraryDetailPane: View {
    @ObservedObject var model: ControllerModel
    var onReviewVoices: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let row = model.openLibraryRow {
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.title)
                        .font(.system(size: 20, weight: .semibold))
                        .textSelection(.enabled)
                    Text(row.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 12)
                Divider()
            }

            if model.libraryDetailLoading && model.libraryDetail == nil {
                ProgressView("Loading meeting…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.libraryDetailError, model.libraryDetail == nil {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(24)
                if let row = model.openLibraryRow {
                    Button("Retry") { model.openLibraryMeeting(row) }
                        .padding(.horizontal, 24)
                }
                Spacer()
            } else if let detail = model.libraryDetail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !detail.attendees.isEmpty {
                            labeled("Attendees", detail.attendees.joined(separator: ", "))
                        }
                        if !detail.summary.isEmpty {
                            labeled("Summary", detail.summary)
                        }
                        if !detail.transcript.isEmpty {
                            labeled("Transcript", detail.transcript)
                        }
                        if detail.summary.isEmpty && detail.transcript.isEmpty {
                            Text("This record has no summary or transcript stored.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 12.5))
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack(spacing: 10) {
                    Button("Copy summary") { model.copyLibraryMeeting(kind: .summary) }
                        .disabled(detail.summary.isEmpty)
                    Button("Copy transcript") { model.copyLibraryMeeting(kind: .transcript) }
                        .disabled(detail.transcript.isEmpty)
                    Button("Copy as context") { model.copyLibraryMeeting(kind: .context) }
                    if model.canRevealLibraryMeeting {
                        Button("Reveal in Finder") { model.revealLibraryMeeting() }
                    }
                    Spacer()
                    if let sessionId = model.openLibraryRow?.sessionId, !sessionId.isEmpty {
                        Button("Review voices") { onReviewVoices(sessionId) }
                        MeetingStatusPills(
                            isNew: model.isInboxNew(sessionId),
                            tag: model.voiceTag(sessionId: sessionId)
                        )
                    }
                }
                .controlSize(.small)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                if let note = model.copyNote {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 10)
                }
            } else {
                Spacer()
            }
        }
        .background(COSPalette.panel)
    }

    private func labeled(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
