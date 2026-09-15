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
        // The suggestion count on the doorway comes from the engine, so it is
        // fetched when Meetings opens rather than only once the pane is entered.
        .task { await model.loadMeetingEngineStatus() }
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
                .font(COSType.body(11, weight: .semibold))
                .foregroundStyle(COSPalette.amber)
            Text("Audio that never became a meeting. This is not Speakers’ Meetings to review.")
                .font(COSType.body(11))
                .foregroundStyle(.secondary)
            ForEach(model.recoverableOrphans) { capture in
                HStack {
                    Text(capture.label)
                        .font(COSType.body(11))
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
                        .font(COSType.body(11))
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
        .buttonStyle(COSQuietButtonStyle())
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
                .cosField()
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
                    .font(COSType.body(11))
                    .foregroundStyle(.secondary)
            }
            if model.isLibraryQueryActive, !model.librarySemanticAvailable {
                Text("Keyword only — meaning search needs the COS meeting index")
                    .font(COSType.body(11))
                    .foregroundStyle(.secondary)
            }
            // 6.47.0 — the two doorways into import and merge. THESE ARE THE
            // OPENERS the route flags read: each writes its own pane's flag and
            // nothing else, which is the link 0.5.17 was missing.
            ChipFlowLayout(spacing: 8) {
                Button("Import meetings") { model.openMeetingImport() }
                    .buttonStyle(COSQuietButtonStyle())
                    .controlSize(.small)
                Button(suggestionsLabel) { model.openMeetingSuggestions() }
                    .buttonStyle(COSQuietButtonStyle())
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// The count earns its place: a suggestion nobody looks at is a merge that
    /// never happens, and a bare label gives no reason to open the pane.
    private var suggestionsLabel: String {
        let open = model.meetingEngineStatus.suggested
        return open > 0 ? "Suggested merges · \(open)" : "Suggested merges"
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
                .font(COSType.body(12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(30)
        } else if model.visibleLibraryMeetings.isEmpty {
            Text(emptyCopy)
                .font(COSType.body(12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(30)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.visibleLibraryMeetings) { meeting in
                        Button { onOpen(meeting) } label: {
                            meetingRow(meeting.title, subtitle: meeting.subtitle, sessionId: meeting.sessionId)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
            }
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
                .font(COSType.body(12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(30)
        } else if model.librarySearchHits.isEmpty {
            Text("No meetings match that lookup.")
                .font(COSType.body(12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(30)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.visibleLibrarySearchHits) { hit in
                        Button { onOpen(hit.meeting) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(hit.meeting.title)
                                        .font(COSType.body(13.5, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading)
                                    if !hit.snippet.isEmpty {
                                        Text(hit.snippet)
                                            .font(COSType.body(11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    Text(hit.meeting.subtitle)
                                        .font(COSType.body(11))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(hit.matchLabel)
                                    .font(COSType.mono(9.5, weight: .semibold))
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
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                            .cosRowCard()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func meetingRow(_ title: String, subtitle: String, sessionId: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(COSType.body(13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(COSType.body(11))
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
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .cosRowCard()
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
                    .font(COSType.display(15, weight: .medium))
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
                        .font(COSType.mono(9, weight: .semibold))
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
                                    .font(COSType.body(11.5, weight: selectedDay == cell.date ? .semibold : .regular))
                                Circle()
                                    .fill(count > 0 ? tint : Color.clear)
                                    .frame(width: 5, height: 5)
                            }
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selectedDay == cell.date ? tint.opacity(0.18) : Color.clear)
                            )
                            // THE WHOLE CELL IS THE TARGET. With a plain
                            // button style SwiftUI hit-tests only the RENDERED
                            // content, so a clear background is not clickable:
                            // the tap target was the 11.5pt date glyph and a
                            // 5pt dot, and every pixel of the highlighted
                            // square around them did nothing.
                            .contentShape(Rectangle())
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
                    .buttonStyle(COSQuietButtonStyle())
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
    var onOpenSource: (LibraryMeetingSource) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let row = model.openLibraryRow {
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.title)
                        .font(COSType.display(22, weight: .medium))
                        .textSelection(.enabled)
                    Text(row.subtitle)
                        .font(COSType.body(12))
                        .foregroundStyle(.secondary)
                    // 6.47.0 — a record COS derived says so, and offers the way
                    // back out. A row COS did not derive gets nothing here.
                    if row.isDerived || row.isImported {
                        MergedRecordActions(model: model, row: row, onOpenSource: onOpenSource)
                            .padding(.top, 4)
                    }
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
                    .font(COSType.body(12))
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
                    .font(COSType.body(12.5))
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
                    // THE MUTABLE GUARD. `canReviewVoices` is false for an
                    // imported meeting (no audio) and for a split piece (a span,
                    // not a capture); the server refuses both by id kind, and
                    // offering a button it will refuse is an action that does
                    // nothing. A merged row keeps it: its session is a real
                    // capture with real audio.
                    if let row = model.openLibraryRow, row.canReviewVoices {
                        Button("Review voices") { onReviewVoices(row.sessionId) }
                        MeetingStatusPills(
                            isNew: model.isInboxNew(row.sessionId),
                            tag: model.voiceTag(sessionId: row.sessionId)
                        )
                    }
                }
                .buttonStyle(COSQuietButtonStyle())
                .controlSize(.small)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                if let note = model.copyNote {
                    Text(note)
                        .font(COSType.body(11))
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
                .font(COSType.mono(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Text(body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Import and merge meetings (server 6.47.0, WS6)
//
// Three surfaces, each mounted on its OWN route flag written by its own opener.
// 0.5.17 shipped two buttons that did nothing because the opener set one thing
// and the mount condition read another; the shape that works is
// `reviewableMeetingsCard` + `reviewRouteActive` + `openSpeakerReview`, and these
// copy it.
//
// WIDTH. Every card below is laid out to hold at 390 pt, the menu-bar panel's
// width, because that is the narrowest surface a Control card ever renders in and
// a row that only works at 760 is a row that silently truncates. Lists scroll in
// place inside a flexible frame with a floor (0.5.222): a fixed cap bounds the
// list, not the card that holds it, and a server-fed list is an unbounded input.

/// The narrowest width these cards are laid out for: the menu-bar panel's own.
///
/// A CONSTRAINT, NOT A `minWidth`. Setting a minimum of 390 inside 22 pt of
/// padding makes the content 434 pt wide in a 390 pt window, which is the same
/// mistake one layer out — the card escapes instead of the list. Nothing here
/// sets a minWidth at all; rows wrap, and `Tests/run-merge-ui.sh` renders every
/// surface at exactly this width to prove it holds.
/// The width `Tests/run-merge-ui.sh` renders every one of these surfaces at.
/// Read there, not here: it is the number the layout is proven against, and a
/// constant nothing uses is a claim nothing checks.
let MERGE_PANEL_WIDTH: CGFloat = 390
/// Floor for a scrolling server-fed list, matching the Speakers panes.
let MERGE_LIST_MIN_HEIGHT: CGFloat = 88

/// Bring in meetings another recorder made, and say what is happening when COS
/// cannot.
///
/// EVERY IMPORTER STATE HAS COPY AND AN AFFORDANCE. That is principle 6 of this
/// release: a failure a person can read but not act on is the 0.5.75 shape, where
/// Control rendered "or fork it" with no fork control anywhere.
struct MeetingImportPane: View {
    @ObservedObject var model: ControllerModel
    /// Fixture renders set this false. The pane's own `.task` would otherwise run
    /// the helper and overwrite the fixture with a failed load, which is how an
    /// offscreen render can silently stop rendering the thing it is testing.
    var autoLoads = true
    @State private var keyDraft = ""
    @State private var confirmDeleteKey = false

    /// Fixture-only: the real view, with its loading task off.
    static func canary(model: ControllerModel) -> MeetingImportPane {
        MeetingImportPane(model: model, autoLoads: false)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if model.meetingImport.routeAbsent {
                    routeAbsentCard
                } else if !model.meetingImport.importsHere {
                    pipelineOwnsCard
                } else {
                    connectCard
                    runCard
                }
                if let error = model.meetingImportError {
                    Text(error)
                        .font(COSType.body(11))
                        .foregroundStyle(COSPalette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                MeetingEngineStatusRow(model: model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
        }
        // THE PANE CLAMPS ITSELF. `maxHeight: .infinity` alone leaves the ideal
        // height intact, so a long card is taller than the window and the window
        // centers the overflow: the header slides off the top (0.5.222, twice).
        // `minHeight: 0` is what lets it take the height it is offered, and this
        // pane also renders inside the 390 pt panel, which has no outer clamp.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
        .background(COSPalette.panel)
        .task { if autoLoads { await model.loadMeetingImport() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Import meetings")
                    .font(COSType.display(20, weight: .medium))
                Spacer()
                if model.meetingImportLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Refresh") { Task { await model.loadMeetingImport() } }
                        .buttonStyle(COSQuietButtonStyle())
                        .controlSize(.small)
                }
                Button("Close") { model.closeMeetingImport() }
                    .buttonStyle(COSQuietButtonStyle())
                    .controlSize(.small)
            }
            Text(model.meetingImport.headline)
                .font(COSType.body(12.5))
                .fixedSize(horizontal: false, vertical: true)
            Text(model.meetingImport.guidance)
                .font(COSType.body(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A 6.46.x server. NOT AN ERROR: COS Control and the npm server ship on
    /// separate trains, and this pairing is expected.
    private var routeAbsentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Update the COS server to 6.47.0", systemImage: "arrow.down.circle")
                .font(COSType.body(12, weight: .medium))
                .foregroundStyle(COSPalette.amber)
            Text("This Mac's COS server does not bring in meetings from other recorders yet.")
                .font(COSType.body(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Update Server") { model.perform("update") }
                .buttonStyle(COSQuietButtonStyle())
                .controlSize(.small)
                .disabled(model.busy)
        }
        .mergeCard()
    }

    /// A pipeline Mac. The server refuses to import here, and that refusal is
    /// correct: two writers producing near-identical records is how one meeting
    /// becomes two rows that each look canonical.
    private var pipelineOwnsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your COS pipeline already brings in Fireflies meetings.")
                .font(COSType.body(12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Text("COS files them into your meetings tree, so the server does not import them a second time. What COS can still do here is spot the ones that are the same meeting as a G2 recording.")
                .font(COSType.body(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("See suggested merges") { model.openMeetingSuggestions() }
                .buttonStyle(COSQuietButtonStyle())
                .controlSize(.small)
        }
        .mergeCard()
    }

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("FIREFLIES")
                .font(COSType.mono(9.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            if let fireflies = model.meetingRecorders.first(where: { $0.id == "fireflies" }), fireflies.installed {
                Text("Fireflies is on this Mac. Its API key is in Fireflies under Integrations.")
                    .font(COSType.body(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(model.firefliesKey.summary)
                .font(COSType.body(12))
                .foregroundStyle(model.firefliesKey.needsNewKey ? COSPalette.danger : .primary)
            if model.firefliesKey.source == "env" {
                Text("This key comes from FIREFLIES_API_KEY in the environment and wins over a stored one.")
                    .font(COSType.body(10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                SecureField("Paste your Fireflies API key", text: $keyDraft)
                    .textFieldStyle(.plain)
                    .cosField()
                Button("Save") {
                    let key = keyDraft
                    keyDraft = ""
                    Task { await model.saveFirefliesKey(key) }
                }
                .buttonStyle(COSQuietButtonStyle())
                .controlSize(.small)
                .disabled(model.firefliesKeyBusy || keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).count < 8)
            }
            Text("The key is stored on this Mac and never shown again.")
                .font(COSType.body(10.5))
                .foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                Button("Check") { Task { await model.checkFirefliesKey() } }
                    .buttonStyle(COSQuietButtonStyle())
                    .controlSize(.small)
                    .disabled(model.firefliesKeyBusy || !model.firefliesKey.configured)
                Button("Remove key") { confirmDeleteKey = true }
                    .buttonStyle(COSTextButtonStyle(tone: .destructive))
                    .controlSize(.small)
                    .disabled(model.firefliesKeyBusy || !model.firefliesKey.configured)
                if model.firefliesKeyBusy { ProgressView().controlSize(.mini) }
            }
            if let note = model.firefliesKeyNote {
                Text(note)
                    .font(COSType.body(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .mergeCard()
        .cosConfirm(
            "Remove the Fireflies key?",
            isPresented: $confirmDeleteKey,
            message: "COS stops bringing in Fireflies meetings. Meetings already brought in stay where they are.",
            actions: [
                .destructive("Remove") { Task { await model.deleteFirefliesKey() } },
                .cancel(),
            ]
        )
    }

    private var runCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("BRING THEM IN")
                .font(COSType.mono(9.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            // Wraps rather than truncating: at 390 pt a picker row plus a button
            // plus a plan menu does not fit on one line.
            // NEITHER LIST IS TYPED HERE. The windows the server accepts and the
            // plans it knows are the server's, and a menu built from literals
            // goes stale silently when it changes them.
            ChipFlowLayout(spacing: 8) {
                Picker("How far back", selection: $model.meetingImportWindow) {
                    ForEach(model.meetingImport.windowOptions, id: \.self) { days in
                        Text("Last \(days) days").tag(days)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 160)
                Picker("Plan", selection: planBinding) {
                    ForEach(model.meetingImport.planCaps, id: \.id) { plan in
                        Text(plan.label).tag(plan.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 130)
                Button("Import now") { Task { await model.runMeetingImport() } }
                    .buttonStyle(COSQuietButtonStyle())
                    .controlSize(.small)
                    .disabled(!model.firefliesKey.configured || model.meetingImport.running || model.meetingImportLoading)
            }
            Text(model.meetingImport.planCapLine)
                .font(COSType.body(10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Keep bringing in new meetings", isOn: keepImportingBinding)
                .toggleStyle(.switch)
                .font(COSType.body(11.5))
                .disabled(!model.firefliesKey.configured)
            Text(model.meetingImport.budgetLine)
                .font(COSType.body(10.5))
                .foregroundStyle(.tertiary)
            if model.meetingImport.imported > 0 {
                Button("See suggested merges") { model.openMeetingSuggestions() }
                    .buttonStyle(COSQuietButtonStyle())
                    .controlSize(.small)
            }
        }
        .mergeCard()
    }

    private var planBinding: Binding<String> {
        Binding(
            get: { model.meetingImport.planCap },
            set: { next in Task { await model.setMeetingImportSettings(planCap: next) } }
        )
    }

    private var keepImportingBinding: Binding<Bool> {
        Binding(
            get: { model.meetingImport.keepImporting },
            set: { next in Task { await model.setMeetingImportSettings(keepImporting: next) } }
        )
    }
}

/// Mode, what the pipeline sees, first-run progress, last run.
///
/// The mode SWITCH only appears on a pipeline Mac, because there is nothing to
/// choose anywhere else, and it always goes through a confirmation that names
/// what apply does.
struct MeetingEngineStatusRow: View {
    @ObservedObject var model: ControllerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HOW COS MERGES")
                .font(COSType.mono(9.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Text(model.meetingEngineStatus.modeLine)
                .font(COSType.body(12))
                .fixedSize(horizontal: false, vertical: true)
            // THE ONE ALARM ON THIS ROW. A Mac that changed kind changed which
            // writer owns the blend, and nothing else on screen says so.
            if let alarm = model.meetingEngineStatus.macClassAlarm {
                Label(alarm, systemImage: "exclamationmark.octagon")
                    .font(COSType.body(11, weight: .medium))
                    .foregroundStyle(COSPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let warning = model.meetingEngineStatus.mismatchWarning {
                VStack(alignment: .leading, spacing: 5) {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(COSType.body(11))
                        .foregroundStyle(COSPalette.amber)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Check again") { Task { await model.loadMeetingEngineStatus() } }
                        .buttonStyle(COSQuietButtonStyle())
                        .controlSize(.small)
                        .disabled(model.meetingEngineBusy)
                }
            }
            // ADVISE WITH MERGES STILL APPLIED IS THE EXPECTED POST-ROLLBACK
            // STATE, not a disagreement. It reads as a plain fact, not a warning.
            if let remain = model.meetingEngineStatus.mergesRemainAppliedLine {
                Text(remain)
                    .font(COSType.body(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let first = model.meetingEngineStatus.firstRunLine {
                Text(first)
                    .font(COSType.body(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.meetingEngineStatus.firstRunInProgress {
                ProgressView().controlSize(.mini)
            }
            if let last = model.meetingEngineStatus.lastRunLine {
                Text(last)
                    .font(COSType.body(10.5))
                    .foregroundStyle(.tertiary)
            }
            // A RUN THAT DID NOTHING SAYS WHY. Silence and a broken engine read
            // the same on this row otherwise.
            if let skipped = model.meetingEngineStatus.skippedReasonLine {
                Text(skipped)
                    .font(COSType.body(10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.meetingEngineStatus.isPipelineMac, !model.meetingEngineStatus.routeAbsent,
               model.meetingEngineStatus.modeKnown {
                modeSwitch
            }
            revertAll
            if let error = model.meetingEngineError {
                Text(error)
                    .font(COSType.body(11))
                    .foregroundStyle(COSPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .mergeCard()
        .cosConfirm(
            model.pendingEngineMode == .apply ? "Let COS merge into your meetings?" : "Go back to suggesting only?",
            isPresented: Binding(
                get: { model.pendingEngineMode != nil },
                set: { if !$0 { model.cancelEngineMode() } }
            ),
            message: model.pendingEngineMode == .apply
                ? "COS writes merged scribes into your operations tree. Each original is copied to the archive first and every merge can be undone. Your pipeline stops blending G2 recordings while this is on."
                : "COS stops writing into your operations tree. Merges already made stay where they are, and each one can still be undone.",
            actions: confirmActions
        )
    }

    /// Built while the confirmation is on screen, so the target is captured HERE
    /// rather than read inside the action: `cosConfirm` dismisses BEFORE it runs
    /// the action, and dismissal nils `pendingEngineMode`.
    private var confirmActions: [COSConfirmAction] {
        let pending = model.pendingEngineMode
        return [
            .normal(pending == .apply ? "Merge into my meetings" : "Suggest only") {
                guard let pending else { return }
                Task { await model.setEngineMode(pending) }
            },
            .cancel(),
        ]
    }

    /// Undo every merge COS made, behind the SAME preview-then-apply flow a single
    /// Undo uses. Rollback tells a person to run this before downgrading, and
    /// 0.5.230 shipped the whole code path with nothing anywhere that reached it.
    @ViewBuilder
    private var revertAll: some View {
        if model.canRevertAllMerges {
            if let preview = model.mergeRevertPreview, preview.isAll {
                VStack(alignment: .leading, spacing: 7) {
                    Text(preview.summary)
                        .font(COSType.body(11.5))
                        .fixedSize(horizontal: false, vertical: true)
                    if let caution = preview.caution {
                        Label(caution, systemImage: "exclamationmark.triangle")
                            .font(COSType.body(11))
                            .foregroundStyle(COSPalette.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Every G2 recording and Fireflies meeting stays where it is.")
                        .font(COSType.body(10.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    ChipFlowLayout(spacing: 8) {
                        Button("Undo them all") { Task { await model.applyMergeRevert() } }
                            .buttonStyle(COSQuietButtonStyle())
                            .controlSize(.small)
                            .disabled(model.mergeRevertBusy)
                        Button("Cancel") { model.cancelMergeRevert() }
                            .buttonStyle(COSTextButtonStyle())
                            .controlSize(.small)
                        if model.mergeRevertBusy { ProgressView().controlSize(.mini) }
                    }
                }
            } else {
                Button("Undo all merges") { Task { await model.previewRevertAllMerges() } }
                    .buttonStyle(COSTextButtonStyle(tone: .destructive))
                    .controlSize(.small)
                    .disabled(model.mergeRevertBusy)
            }
            if let note = model.mergeRevertNote, model.mergeRevertPreview == nil {
                Text(note)
                    .font(COSType.body(10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modeSwitch: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(model.meetingEngineStatus.mode?.switchTitle ?? "")
                    .font(COSType.body(11.5, weight: .medium))
                Spacer(minLength: 4)
                if model.meetingEngineBusy {
                    ProgressView().controlSize(.mini)
                } else if model.meetingEngineStatus.mode == .advise {
                    Button("Merge into my meetings") { model.armEngineMode(.apply) }
                        .buttonStyle(COSQuietButtonStyle())
                        .controlSize(.small)
                } else {
                    Button("Suggest only") { model.armEngineMode(.advise) }
                        .buttonStyle(COSQuietButtonStyle())
                        .controlSize(.small)
                }
            }
            if model.meetingEngineStatus.mode == .advise, model.meetingEngineStatus.firstRunLine != nil {
                Button("Read the report first") { model.openMeetingSuggestions() }
                    .buttonStyle(COSTextButtonStyle())
                    .controlSize(.small)
            }
        }
    }
}

/// What COS wants a person to decide, laid out like Samples to review.
///
/// SCROLLS IN PLACE inside a flexible frame with a floor. The server holds
/// suggestions until they are answered, so the row count is unbounded by design
/// and a card that grows with it carries the header off the window (0.5.222).
struct MeetingSuggestionsPane: View {
    @ObservedObject var model: ControllerModel
    /// Fixture renders set this false, for the same reason `MeetingImportPane` does.
    var autoLoads = true

    /// Fixture-only: the real view, with its loading task off.
    static func canary(model: ControllerModel) -> MeetingSuggestionsPane {
        MeetingSuggestionsPane(model: model, autoLoads: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
        .background(COSPalette.panel)
        .task { if autoLoads { await model.loadMeetingSuggestions() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Suggested merges")
                    .font(COSType.display(20, weight: .medium))
                Spacer()
                if model.meetingSuggestionsLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Refresh") { Task { await model.loadMeetingSuggestions() } }
                        .buttonStyle(COSQuietButtonStyle())
                        .controlSize(.small)
                }
                Button("Close") { model.closeMeetingSuggestions() }
                    .buttonStyle(COSQuietButtonStyle())
                    .controlSize(.small)
            }
            // THE MODE DECIDES EVERY LABEL BELOW, so when it is not known the
            // header says that and the agree buttons stay off. 0.5.230 defaulted
            // an unread mode to imports and drew "Merge" on a pane where agreeing
            // writes nothing.
            if let engineError = model.meetingEngineError, !model.meetingEngineStatus.modeKnown {
                VStack(alignment: .leading, spacing: 5) {
                    Text("COS could not say how it is merging right now, so answering is off.")
                        .font(COSType.body(11))
                        .foregroundStyle(COSPalette.amber)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(engineError)
                        .font(COSType.body(10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Check again") { Task { await model.loadMeetingEngineStatus() } }
                        .buttonStyle(COSQuietButtonStyle())
                        .controlSize(.small)
                        .disabled(model.meetingEngineBusy)
                }
            } else if model.meetingEngineStatus.modeKnown, model.meetingEngineStatus.mode != .imports {
                // ADVISE MODE SAYS SO, IN THE HEADER. An answer that changes
                // nothing must not look like one that did. "in advise mode", not
                // "in this version": the version is not what decides it.
                Text("COS does not change your pipeline's files in advise mode. Your answers are saved.")
                    .font(COSType.body(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if model.meetingSuggestionsState == "route_absent" {
            emptyState(
                "Update the COS server to 6.47.0",
                detail: "This Mac's COS server does not look for meetings that are the same meeting yet.",
                button: ("Update Server", { model.perform("update") })
            )
        } else if let error = model.meetingSuggestionsError {
            emptyState(error, detail: "", button: ("Retry", { Task { await model.loadMeetingSuggestions() } }))
        } else if model.meetingSuggestionsState == nil && model.meetingSuggestionsLoading {
            ProgressView("Looking…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.pendingMeetingSuggestions.isEmpty {
            emptyState(
                "Nothing to decide",
                detail: "COS asks here when a recording and a meeting look like the same conversation and it is not sure.",
                button: nil
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !model.wouldMergeSuggestions.isEmpty {
                        group("Would merge automatically", rows: model.wouldMergeSuggestions)
                    }
                    if !model.undecidedSuggestions.isEmpty {
                        group(model.meetingEngineStatus.mode == .imports ? "Same meeting?" : "Suggestions",
                              rows: model.undecidedSuggestions)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
            }
            // A FLEXIBLE FRAME WITH A FLOOR, never a fixed height: a fixed cap
            // bounds the list and not the card that holds it.
            .frame(minHeight: MERGE_LIST_MIN_HEIGHT, maxHeight: .infinity)
        }
    }

    private func group(_ title: String, rows: [MeetingSuggestion]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(COSType.mono(9.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            ForEach(rows) { suggestion in
                // The group already said it. A row repeating its own group's
                // title is noise in a list a person is reading forty of.
                suggestionRow(suggestion, showHeadline: suggestion.headline.caseInsensitiveCompare(title) != .orderedSame)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suggestionRow(_ suggestion: MeetingSuggestion, showHeadline: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if showHeadline {
                Text(suggestion.headline)
                    .font(COSType.body(11.5, weight: .semibold))
            }
            // BOTH SIDES COME FROM THE SERVER, and only a side it could not place
            // in the library carries the caption. 0.5.230 put one sentence on the
            // header that spoke for every row, resolved or not.
            ForEach(suggestion.sides) { side in
                VStack(alignment: .leading, spacing: 1) {
                    Text(side.displayTitle)
                        .font(COSType.body(12))
                        .fixedSize(horizontal: false, vertical: true)
                    if !side.line.isEmpty {
                        Text(side.line)
                            .font(COSType.mono(10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note = side.unresolvedNote {
                        Text(note)
                            .font(COSType.body(10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(suggestion.evidenceLine)
                .font(COSType.body(11))
                .foregroundStyle(.secondary)
            // A SPLIT IS ONLY ACCEPTABLE WHERE THE SERVER CAN WRITE PIECES. In
            // apply mode it refuses with `split_not_supported_in_apply_mode`, so
            // the button is not offered and the row says why.
            if splitIsUnavailable(suggestion) {
                Text("Splits arrive as suggestions in apply mode.")
                    .font(COSType.body(10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ChipFlowLayout(spacing: 8) {
                if !splitIsUnavailable(suggestion) {
                    Button(agreeLabel(suggestion)) {
                        Task { await model.decideSuggestion(suggestion, agree: true) }
                    }
                    .buttonStyle(COSQuietButtonStyle())
                    .controlSize(.small)
                    .disabled(model.decidingSuggestion != nil || !model.meetingEngineStatus.modeKnown)
                }
                Button("Not the same meeting") {
                    Task { await model.decideSuggestion(suggestion, agree: false) }
                }
                .buttonStyle(COSTextButtonStyle(tone: .destructive))
                .controlSize(.small)
                .disabled(model.decidingSuggestion != nil || !model.meetingEngineStatus.modeKnown)
                if model.decidingSuggestion == suggestion.id {
                    ProgressView().controlSize(.mini)
                }
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cosRowCard()
    }

    /// IMPORTS MODE MERGES; ADVISE MODE REMEMBERS. The label says which, because
    /// "Merge" on a surface that writes nothing is a lie a person only finds out
    /// about later.
    private func agreeLabel(_ suggestion: MeetingSuggestion) -> String {
        model.meetingEngineStatus.mode == .imports ? "Merge" : "Looks right"
    }

    /// True for a split the server will refuse. Imports mode writes the pieces;
    /// apply mode answers 409 `split_not_supported_in_apply_mode`, and a button
    /// that can only fail is worse than one that is not there.
    private func splitIsUnavailable(_ suggestion: MeetingSuggestion) -> Bool {
        suggestion.isSplit && model.meetingEngineStatus.mode != .imports
    }

    private func emptyState(_ title: String, detail: String, button: (String, () -> Void)?) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(COSType.body(12.5))
                .multilineTextAlignment(.center)
            if !detail.isEmpty {
                Text(detail)
                    .font(COSType.body(11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let button {
                Button(button.0) { button.1() }
                    .buttonStyle(COSQuietButtonStyle())
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

/// What COS did to the record on screen, and how to undo it.
///
/// UNDO IS TWO CALLS. The dry run is shown first and applying sends back the hash
/// that preview covered, so a person confirms the thing they were shown or
/// nothing at all. This is the held-groups enroll gate, for the same reason.
struct MergedRecordActions: View {
    @ObservedObject var model: ControllerModel
    let row: LibraryMeeting
    let onOpenSource: (LibraryMeetingSource) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline)
                .font(COSType.body(11.5, weight: .semibold))
            if let action = model.mergeAction(for: row) {
                Text(action.stateLine)
                    .font(COSType.body(11))
                    .foregroundStyle(action.isFailed ? COSPalette.danger : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if row.isSplitPiece {
                Text("Split from a longer recording")
                    .font(COSType.body(10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let preview = model.mergeRevertPreview, !preview.isAll, preview.actionId == (row.actionId ?? "") {
                previewBlock(preview)
            } else {
                controls
            }
            if let note = model.mergeRevertNote {
                Text(note)
                    .font(COSType.body(10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // A FAILED LOAD IS WHY THE CONTROLS ARE MISSING, and until now it was
            // recorded in a field nothing rendered: the card silently looked like
            // a record COS had not made.
            if let error = model.mergeActionsError {
                Text(error)
                    .font(COSType.body(10.5))
                    .foregroundStyle(COSPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            sourceLinks
        }
        .mergeCard()
        // The list is capped at 100 rows, so an older merge is not in it. Fetch
        // THIS action by id rather than leaving the card blank.
        .task(id: row.actionId) {
            if model.mergeActions.isEmpty { await model.loadMergeActions() }
            if let id = row.actionId, !id.isEmpty { await model.loadMergeAction(id: id) }
        }
    }

    private var headline: String {
        if let action = model.mergeAction(for: row) { return action.headline }
        if row.isSplitPiece { return "Split from a longer recording" }
        if row.isMerged { return "Merged automatically: G2 + Fireflies" }
        return "Brought in from Fireflies"
    }

    @ViewBuilder
    private var controls: some View {
        let action = model.mergeAction(for: row)
        ChipFlowLayout(spacing: 8) {
            // UNDO NEEDS AN ACTION COS OWNS. A merge the pipeline made before this
            // release is real and COS did not make it, so COS does not offer to
            // take it apart; `isRevertible` is false for it and for anything not
            // currently applied.
            if let action, action.isRevertible {
                Button(row.isSplitPiece ? "Revert" : "Undo") {
                    Task { await model.previewMergeRevert(actionId: action.id) }
                }
                .buttonStyle(COSQuietButtonStyle())
                .controlSize(.small)
                .disabled(model.mergeRevertBusy)
            } else if let action, action.isLegacy {
                Text("Your COS pipeline made this merge, so COS does not undo it.")
                    .font(COSType.body(10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // RETRY IS A ROUTE AND IT KNOWS THE DIRECTION. A parked undo gets one
            // too: before 6.47.0 nothing re-drove it until the server restarted.
            if let action, action.isRetryable {
                Button(action.retryLabel) { Task { await model.retryMergeAction(action) } }
                    .buttonStyle(COSQuietButtonStyle())
                    .controlSize(.small)
                    .disabled(model.mergeRevertBusy)
            }
            if let action {
                Button("Copy diagnostics") { model.copyMergeDiagnostics(action) }
                    .buttonStyle(COSTextButtonStyle())
                    .controlSize(.small)
            }
            // SEPARATE FROM RETRY. Refresh re-reads; Retry asks the server to run
            // the thing again. 0.5.230 had one button doing the first under the
            // second's name.
            Button("Refresh") { Task { await model.loadMergeActions() } }
                .buttonStyle(COSTextButtonStyle())
                .controlSize(.small)
                .disabled(model.mergeActionsLoading)
            if model.mergeRevertBusy { ProgressView().controlSize(.mini) }
        }
    }

    private func previewBlock(_ preview: MergeRevertPreview) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(preview.summary)
                .font(COSType.body(11.5))
                .fixedSize(horizontal: false, vertical: true)
            if let caution = preview.caution {
                Label(caution, systemImage: "exclamationmark.triangle")
                    .font(COSType.body(11))
                    .foregroundStyle(COSPalette.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("The G2 recording and the Fireflies meeting stay where they are.")
                .font(COSType.body(10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            ChipFlowLayout(spacing: 8) {
                Button(row.isSplitPiece ? "Revert it" : "Undo it") {
                    Task { await model.applyMergeRevert() }
                }
                .buttonStyle(COSQuietButtonStyle())
                .controlSize(.small)
                .disabled(model.mergeRevertBusy)
                Button("Cancel") { model.cancelMergeRevert() }
                    .buttonStyle(COSTextButtonStyle())
                    .controlSize(.small)
                if model.mergeRevertBusy { ProgressView().controlSize(.mini) }
            }
        }
    }

    @ViewBuilder
    private var sourceLinks: some View {
        let sources = model.libraryDetail?.sources ?? []
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("MADE FROM")
                    .font(COSType.mono(9, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(.secondary)
                ForEach(sources) { source in
                    Button {
                        onOpenSource(source)
                    } label: {
                        HStack(spacing: 6) {
                            Text(source.label)
                                .font(COSType.body(11))
                            Text(source.sourceId)
                                .font(COSType.mono(9.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(source.recordId.isEmpty)
                }
            }
        }
    }
}

private struct MergeCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(COSPalette.line, lineWidth: 1))
    }
}

extension View {
    func mergeCard() -> some View { modifier(MergeCard()) }
}
