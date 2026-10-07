import SwiftUI

/// Calendar + list + detail for the Activity Meetings library.
///
/// Speakers still owns identity correction ("Meetings to review"). This surface
/// is the saved-call browser: domain, duration, summary, transcript, copy.
struct MeetingLibraryBody: View {
    @ObservedObject var model: ControllerModel
    var selectionOnly = false
    let onOpen: (LibraryMeeting) -> Void
    @State private var confirmRecoverAllOrphans = false
    @State private var confirmSaveAllStranded = false

    var body: some View {
        VStack(spacing: 0) {
            if !selectionOnly && (!model.recoverableOrphans.isEmpty || !model.strandedCaptures.isEmpty) {
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
        .task { if !selectionOnly { await model.loadOrphans(quiet: true) } }
        // The suggestion count on the doorway comes from the engine, so it is
        // fetched when Meetings opens rather than only once the pane is entered.
        .task { if !selectionOnly { await model.loadMeetingEngineStatus() } }
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
                    COSDropdown("Domain", selection: $model.libraryDomainFilter,
                                options: [COSDropdownOption("all", "All domains")]
                                    + domainOptions.filter { $0 != "all" }.map {
                                        COSDropdownOption($0, $0.replacingOccurrences(of: "_", with: " ").localizedCapitalized)
                                    })
                    .fixedSize()
                }

                COSDropdown("Recency", selection: $model.searchRecency,
                            options: SearchRecency.allCases.map { COSDropdownOption($0, $0.title) })
                .fixedSize()

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
            if !selectionOnly {
              ChipFlowLayout(spacing: 8) {
                Button("Import meetings") { model.openMeetingImport() }
                    .buttonStyle(COSQuietButtonStyle())
                    .controlSize(.small)
                Button(suggestionsLabel) { model.openMeetingSuggestions() }
                    .buttonStyle(COSQuietButtonStyle())
                    .controlSize(.small)
              }
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
                            meetingRow(meeting.title, subtitle: meeting.subtitle(clock: model.clockStyle), sessionId: meeting.sessionId,
                                       keys: meeting.contextKeys)
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
                                    Text(hit.meeting.subtitle(clock: model.clockStyle))
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

    private func meetingRow(_ title: String, subtitle: String, sessionId: String, keys: [String] = []) -> some View {
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
            // 0.5.258: the meeting holds files (the Work card face's paperclip and count), following the store.
            if !keys.isEmpty, let files = model.workHandoffStore?.meetingFiles { MeetingFileCount(files: files, keys: keys) }
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
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(COSIconButtonStyle(size: 24))
                .accessibilityLabel("Previous month")
                Spacer()
                Text(MeetingMonth.title(month))
                    .font(COSType.display(15, weight: .medium))
                Spacer()
                Button { onShift(1) } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(COSIconButtonStyle(size: 24))
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

struct MeetingWorkConnections {
    let tasks: [TaskRow]
    let reviews: [WorkReviewRecord]
    let receipts: [WorkHandoffReceipt]
    let sessions: [WorkSession]
    let loading: Bool
    let complete: Bool
    let errors: [String]

    func sessionDestination(for receipt: WorkHandoffReceipt) -> (sessionID: String, workID: String)? {
        guard receipts.contains(where: { $0.id == receipt.id }), let id = receipt.sessionID,
              sessions.contains(where: { $0.id == id && $0.provider == receipt.provider }) else { return nil }
        return (id, receipt.workID)
    }

    static func project(meeting: LibraryMeeting, tasks: [TaskRow], reviews: [WorkReviewRecord], receipts: [WorkHandoffReceipt], sessions: [WorkSession], loading: Bool, complete: Bool, errors: [String]) -> Self {
        let confirmed = tasks.filter { task in task.meetingRefs.contains { $0.matches(meeting) } }
        let meetingReviews = reviews.filter { $0.canonicalMeetingId == meeting.recordId }
        let workIDs = Set(confirmed.map { WorkSource.taskSnapshot($0).id } + ["meeting:" + meeting.recordId])
        let linkedReceipts = receipts.filter { receipt in
            guard workIDs.contains(receipt.workID), let sessionID = receipt.sessionID else { return false }
            return sessionID.hasPrefix(receipt.provider + ":")
        }.sorted { $0.createdAt > $1.createdAt }
        return Self(tasks: confirmed, reviews: meetingReviews, receipts: linkedReceipts, sessions: sessions,
            loading: loading, complete: complete, errors: errors)
    }
}

struct MeetingLibraryDetailPane: View {
    @ObservedObject var model: ControllerModel
    var onReviewVoices: (String, String?) -> Void
    var onOpenSource: (LibraryMeetingSource) -> Void = { _ in }
    var onReviewFollowUp: ((LibraryMeeting) -> Void)? = nil
    var onLinkTask: ((LibraryMeeting) -> Void)? = nil
    var workConnections: MeetingWorkConnections? = nil
    var onOpenWork: ((String) -> Void)? = nil
    var onOpenSession: ((String, String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let row = model.openLibraryRow {
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.title)
                        .font(COSType.display(22, weight: .medium))
                        .textSelection(.enabled)
                    Text(row.subtitle(clock: model.clockStyle))
                        .font(COSType.body(12))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if let onLinkTask {
                            Button("Link to existing task") { onLinkTask(row) }.buttonStyle(COSPrimaryButtonStyle())
                        }
                        if let onReviewFollowUp {
                            Button("Review follow-up in Work") { onReviewFollowUp(row) }.buttonStyle(COSQuietButtonStyle())
                        }
                    }.padding(.top, 4)
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
                // 0.5.232: THE FILE IS THE BODY. The scribe's `.md` already carries the
                // attendees, the summary, the topics, decisions, action items and the
                // transcript as one document; through 0.5.231 the pane printed Attendees
                // and Summary as fields and then the whole file again, raw, under a
                // Transcript label. A record whose transcript is not a document (an
                // import with a bare transcript, a legacy record) keeps its labelled
                // fields, each rendered as Markdown too.
                let isDocument = COSMarkdownParser.looksLikeDocument(detail.transcript)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // 0.5.258: screenshots, slides and files dropped on the meeting, sent with every linked card.
                        if let files = model.workHandoffStore?.meetingFiles, let row = model.openLibraryRow {
                            let keys = detail.contextKeys.isEmpty ? row.contextKeys : detail.contextKeys
                            MeetingFilesSection(files: files, keys: keys, supported: detail.contextSupported ?? row.contextSupported,
                                                ambiguous: detail.contextAmbiguous || row.contextAmbiguous,
                                                reason: detail.contextReason.isEmpty ? row.contextReason : detail.contextReason,
                                                info: WorkMeetingInfo(recordId: row.recordId, title: row.title, date: row.date))
                        }
                        if let workConnections { relatedWork(workConnections) }
                        if isDocument {
                            COSMarkdownView(text: detail.transcript, dropLeadingTitle: true)
                        } else {
                            if !detail.attendees.isEmpty {
                                labeled("Attendees", detail.attendees.joined(separator: ", "))
                            }
                            if !detail.summary.isEmpty {
                                labeled("Summary", detail.summary)
                            }
                            if !detail.transcript.isEmpty {
                                labeled("Transcript", detail.transcript)
                            }
                        }
                        if detail.summary.isEmpty && detail.transcript.isEmpty {
                            Text("This record has no summary or transcript stored.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(COSType.body(12.5))
                    .padding(24)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                if let onReviewFollowUp, let row = model.openLibraryRow {
                    HStack {
                        Button("Review follow-up in Work") { onReviewFollowUp(row) }.buttonStyle(COSPrimaryButtonStyle())
                        Spacer()
                    }.padding(.horizontal, 24).padding(.top, 10)
                }
                // Actions by weight (0.5.232): Copy as context is what this pane is for,
                // so it is the one filled button and it takes ⌘C; the other copies and
                // Reveal are quiet; Review voices is featured while it is new to this
                // record, with the pill inside the button rather than beside it.
                HStack(spacing: 8) {
                    Button("Copy as context") { model.copyLibraryMeeting(kind: .context) }
                        .buttonStyle(COSPrimaryButtonStyle())
                        .keyboardShortcut("c", modifiers: .command)
                    Button("Copy summary") { model.copyLibraryMeeting(kind: .summary) }
                        .disabled(detail.summary.isEmpty)
                    Button("Copy transcript") { model.copyLibraryMeeting(kind: .transcript) }
                        .disabled(detail.transcript.isEmpty)
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
                        let isNew = model.isInboxNew(row.sessionId)
                        Button { onReviewVoices(row.sessionId, row.recordId) } label: {
                            HStack(spacing: 8) {
                                Text("Review voices")
                                if isNew { COSNewPill() }
                            }
                        }
                        .buttonStyle(COSQuietButtonStyle(tone: isNew ? .featured : .standard))
                        if row.g2SessionIds.count > 1 {
                            Menu("Other recordings") {
                                ForEach(row.g2SessionIds.filter { $0 != row.sessionId }, id: \.self) { capture in
                                    Button(capture) { onReviewVoices(capture, row.recordId) }
                                }
                            }.cosMenu()
                        }
                        MeetingStatusPills(
                            isNew: false,
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

    private func relatedWork(_ links: MeetingWorkConnections) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connected work").font(COSType.display(19, weight: .medium))
                Spacer()
                if let onLinkTask, let row = model.openLibraryRow {
                    Button("Link to existing task") { onLinkTask(row) }.buttonStyle(COSQuietButtonStyle())
                }
            }
            if links.loading { ProgressView("Loading linked work…").controlSize(.small) }
            ForEach(links.errors, id: \.self) { Text($0).font(COSType.body(11)).foregroundStyle(COSPalette.danger) }
            if !links.complete { Text("The task inventory is not confirmed complete.").font(COSType.body(11)).foregroundStyle(COSPalette.muted) }
            ForEach(links.tasks, id: \.workSourceID) { task in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.text.isEmpty ? task.title : task.text).font(COSType.body(12, weight: .medium))
                        Text(task.domain + " · " + (task.checked ? "Complete" : task.workStage == "qa" ? "QA" : task.workStage.capitalized)).font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
                    }
                    Spacer()
                    if let onOpenWork { Button("Open work") { onOpenWork(WorkSource.taskSnapshot(task).id) }.buttonStyle(COSQuietButtonStyle()) }
                }
            }
            ForEach(links.reviews) { review in
                HStack {
                    Text("Meeting review · " + review.status).font(COSType.body(12))
                    Spacer()
                    if let onOpenWork { Button("Open review") { onOpenWork("meeting-review:" + review.id) }.buttonStyle(COSQuietButtonStyle()) }
                }
            }
            ForEach(links.receipts) { receipt in
                VStack(alignment: .leading, spacing: 4) {
                    Text(receipt.workTitle + " · " + receipt.status).font(COSType.body(12, weight: .medium))
                    Text(receipt.detail).font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                    if let destination = links.sessionDestination(for: receipt), let onOpenSession {
                        Button("Open session · " + receipt.sessionTitle) { onOpenSession(destination.sessionID, destination.workID) }.buttonStyle(COSQuietButtonStyle())
                    } else {
                        Text("Linked session is not currently available.").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                    }
                }
            }
            if !links.loading && links.complete && links.errors.isEmpty && links.tasks.isEmpty && links.reviews.isEmpty && links.receipts.isEmpty {
                Text("No connected tasks yet. Link this meeting to an existing task to keep its context with the work already underway.")
                    .font(COSType.body(12)).foregroundStyle(COSPalette.muted)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(COSPalette.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(COSPalette.line))
    }

    private func labeled(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(COSType.mono(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            COSMarkdownView(text: body)
        }
    }
}

// MARK: - Files on a meeting (0.5.258)

/// A meeting's Files: drop, Add files…, Paste screenshot (or ⌘V while the box is focused), and each file's row. The
/// files are COS's copies on this Mac, and every Work card linked to the meeting sends them after its own.
///
/// THE DROP IS ON THE BOX ITSELF, never in an `.overlay` (an overlay drop destination never fires, 0.5.246). A server
/// older than 6.64.0 sends no keys, so the box says to update rather than taking files it could not file.
struct MeetingFilesSection: View {
    @ObservedObject var files: WorkCardFileStore
    let keys: [String]
    /// nil: the server did not say (older than 6.64.0).
    let supported: Bool?
    /// Shown in its own line (unavailableLine); kept on the view for the states render.
    let ambiguous: Bool
    let reason: String
    let info: WorkMeetingInfo
    @State private var targeted = false
    @State private var preview: URL?
    @State private var hovered: String?
    @FocusState private var focused: Bool

    private var primaryID: String? { keys.first.flatMap(WorkCardFiles.meetingID(forKey:)) }
    private var canAdd: Bool { supported == true && files.enabled && primaryID != nil }

    var body: some View {
        let shown = files.meetingFiles(keys: keys)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Files").font(COSType.display(19, weight: .medium))
                Spacer()
                if !shown.isEmpty {
                    Text("\(shown.count) file\(shown.count == 1 ? "" : "s") · " + WorkCardFiles.sizeText(shown.filter { !$0.file.isLink }.reduce(0) { $0 + $1.file.bytes }))
                        .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
                }
            }
            if let line = unavailableLine {
                Text(line).font(COSType.body(11)).foregroundStyle(COSPalette.muted).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(shown, id: \.file.id) { entry in
                    row(entry.file, folder: entry.folder, id: entry.id)
                    Divider().overlay(COSPalette.line)
                }
                // Undo for a file removed from any of the meeting's folders (a merged meeting shows its captures' too).
                ForEach(keys.compactMap(WorkCardFiles.meetingID(forKey:)), id: \.self) { id in
                    ForEach(files.recentlyRemoved(for: id)) { file in
                        HStack(spacing: 8) {
                            Text("Removed \u{201C}\(file.display)\u{201D}.").lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 6)
                            if supported == true { Button("Undo") { files.undoRemove(file.id, workID: id) }.buttonStyle(COSTextButtonStyle()) }
                        }.font(COSType.body(11)).foregroundStyle(COSPalette.muted).padding(.horizontal, 10).padding(.vertical, 6)
                        Divider().overlay(COSPalette.line)
                    }
                }
                if canAdd { dropRow }
            }
            .background(targeted ? COSPalette.gold.opacity(0.06) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(targeted || focused ? COSPalette.gold : COSPalette.line, lineWidth: targeted ? 1.5 : 1))
            .modifier(MeetingFilesDrop(enabled: canAdd, targeted: $targeted) { providers in
                guard let key = keys.first else { return }
                let meeting = info
                Task { await files.intakeMeeting(providers: providers, key: key, info: meeting) }
            })
            // ⌘V pastes here only while the box has focus (a click on it), so the search field keeps its own paste. No
            // focus ring, and the box never takes a window's first focus by itself (COSBrand's .focusable note).
            .focusable(canAdd, interactions: .edit)
            .focusEffectDisabled()
            .focused($focused)
            .onTapGesture { if canAdd { focused = true } }
            .onPasteCommand(of: [.fileURL, .png, .tiff]) { _ in paste() }
            if let id = primaryID { WorkCardFlashView(files: files, workID: id) }
            if canAdd {
                Text(WorkCardFiles.meetingNote).font(COSType.body(10.5)).foregroundStyle(COSPalette.muted).fixedSize(horizontal: false, vertical: true)
            }
            if let error = files.error { Text(error).font(COSType.body(11)).foregroundStyle(COSPalette.danger) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(COSPalette.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(COSPalette.line))
        .quickLookPreview($preview)
        // Only a meeting files may be added under records its id on the folder: an ambiguous one never does (QA B2).
        .task(id: keys) { files.loadIfNeeded(); if supported == true { files.noteMeeting(keys: keys, info: info) } }
    }

    /// Why files cannot be added here, or nil.
    private var unavailableLine: String? {
        guard supported != true else { return nil }
        if supported == nil { return "Update the COS server to 6.64 or later to add files to meetings." }
        switch reason {
        case "ambiguous": return "Two meetings claim this recording, so files can't be added or removed here. Cards linked to this meeting get no new files from it until one of the two is removed."
        case "conflict_copy": return "This is an iCloud copy of a meeting. Add files on the original."
        case "read_only_record": return "Files can't be added to an imported or combined record. Add them on the meeting it came from."
        default: return "Files can't be added to this meeting yet: it has no recording or Fireflies id COS can file them under."
        }
    }

    private var dropRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "paperclip").font(.system(size: 11))
            Text(targeted ? "Drop to add to this meeting" : "Drop screenshots, slides or files here")
            Spacer(minLength: 6)
            Button { paste() } label: { Label("Paste screenshot", systemImage: "doc.on.clipboard") }
                .buttonStyle(COSQuietButtonStyle()).controlSize(.small)
            Button { addFiles() } label: { Label("Add files\u{2026}", systemImage: "plus") }
                .buttonStyle(COSQuietButtonStyle()).controlSize(.small)
        }
        .font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(COSPalette.raised.opacity(0.35))
    }

    private func paste() {
        guard canAdd, let key = keys.first else { return }
        let meeting = info
        Task { await files.pasteMeeting(from: NSPasteboard.general, key: key, info: meeting) }
    }

    /// Add files…: files and folders, several at once. Dragging is never required.
    private func addFiles() {
        guard canAdd, let key = keys.first else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "Add to meeting"; panel.message = "Choose screenshots, slides or files to add to this meeting."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls, meeting = info
        Task { await files.intakeMeeting(urls: urls, key: key, info: meeting) }
    }

    private func row(_ file: WorkContextFile, folder: URL, id: String) -> some View {
        let hover = hovered == file.id
        let (word, tint) = WorkCardFiles.secretFlagged(file) ? ("Not sent", COSPalette.amber) : WorkCardFilesSection.stateWord(file)
        var parts = WorkCardFilesSection.metaParts(file)
        if let text = file.companions.first(where: { $0.kind == "text" }), file.kind == "image" || file.kind == "heic" {
            switch text.state {
            case "ready": parts.append("text read on this Mac")
            case "preparing": parts.append("reading its text")
            default: parts.append(text.failure == WorkCardFiles.ocrSecretFailure ? "reads like a password or key, not sent" : "no text found")
            }
        }
        let location: URL? = file.kind == "folder" ? file.original.map { URL(fileURLWithPath: $0) }
            : file.kind == "link" ? file.original.flatMap(URL.init(string:)) : folder.appendingPathComponent(file.stored)
        return HStack(spacing: 10) {
            Image(systemName: WorkCardFilesSection.icon(file)).font(.system(size: 13))
                .foregroundStyle(WorkCardFiles.secretFlagged(file) ? COSPalette.amber : file.isLink ? COSPalette.muted : COSPalette.accent)
                .frame(width: 28, height: 28).background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(file.display).font(COSType.body(12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                (Text(word).bold().foregroundColor(tint) + Text(parts.isEmpty ? "" : " \u{00B7} " + parts.joined(separator: " \u{00B7} ")).foregroundColor(COSPalette.muted))
                    .font(COSType.body(10.5)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Group {
                HStack(spacing: 2) {
                    if !file.isLink { icon("eye", "Quick Look") { preview = location } }
                    icon(file.kind == "link" ? "arrow.up.right.square" : "magnifyingglass", file.kind == "link" ? "Open the link" : "Show in Finder") {
                        guard let location else { return }
                        if file.kind == "link" { NSWorkspace.shared.open(location) } else { NSWorkspace.shared.activateFileViewerSelecting([location]) }
                    }
                    if supported == true { icon("xmark", "Remove from this meeting (Undo is offered)") { files.remove(file.id, workID: id) } }
                }.foregroundStyle(COSPalette.muted)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(hover ? COSPalette.gold.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? file.id : (hovered == file.id ? nil : hovered) }
    }
    private func icon(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}

/// A meeting row's paperclip and count. Observes the meeting store, so a drop or a Remove shows at once (QA G7).
struct MeetingFileCount: View {
    @ObservedObject var files: WorkCardFileStore
    let keys: [String]
    var body: some View {
        let count = files.meetingFileCount(keys: keys)
        if count > 0 {
            HStack(spacing: 4) {
                Image(systemName: "paperclip").font(.system(size: 10, weight: .semibold))
                Text("\(count)")
            }
            .font(COSType.body(11)).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine).accessibilityLabel("\(count) file\(count == 1 ? "" : "s")")
        }
    }
}

/// The Files box's own drop: files only (a Work card dragged here is not a file), on the box, never in an overlay.
struct MeetingFilesDrop: ViewModifier {
    let enabled: Bool
    @Binding var targeted: Bool
    let onFiles: ([NSItemProvider]) -> Void
    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: WorkCardFiles.fileDropTypes, delegate: WorkCardFileDropDelegate(target: .filesBox, targeted: $targeted, onFiles: onFiles))
        } else {
            content
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
                COSDropdown("How far back", selection: $model.meetingImportWindow,
                            options: model.meetingImport.windowOptions.map { COSDropdownOption($0, "Last \($0) days") },
                            showsLabel: false)
                .frame(maxWidth: 160)
                COSDropdown("Plan", selection: planBinding,
                            options: model.meetingImport.planCaps.map { COSDropdownOption($0.id, $0.label) }, showsLabel: false)
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
                .toggleStyle(COSSwitchStyle())
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
                        Text(side.line(clock: model.clockStyle))
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


/// Both directions use the same canonical meeting descriptor and revision-guarded task writer.
enum MeetingTaskLinkOptions {
    static func rows(_ tasks: [TaskRow], query: String, includeCompleted: Bool) -> [TaskRow] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return tasks.filter { task in
            (includeCompleted || !task.checked) && words.allSatisfy {
                (task.text + " " + task.title + " " + task.domain).localizedStandardContains($0)
            }
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func refusal(_ task: TaskRow, meeting: WorkMeetingReference) -> String? {
        if task.meetingRefs.contains(where: { $0.recordId == meeting.recordId }) { return "Already linked" }
        if let error = task.workMetadataError { return error }
        if task.workRevision.isEmpty { return "Refresh Work before linking this task." }
        if task.meetingRefs.count >= 8 { return "This task already has eight meeting links." }
        return nil
    }
}

struct MeetingTaskLinkSheet: View {
    @ObservedObject var model: ControllerModel
    let meeting: LibraryMeeting
    var onOpenWork: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    // Keystrokes stay local to the picker; they do not republish the Activity model.
    @State private var query = ""
    @State private var includeCompleted = false
    @State private var selected: TaskRow?
    @State private var saving = false
    @State private var error: String?
    @State private var saved: TaskRow?

    private var reference: WorkMeetingReference? { WorkMeetingReference(meeting: meeting) }
    private var candidates: [TaskRow] { MeetingTaskLinkOptions.rows(model.workTasks, query: query, includeCompleted: includeCompleted) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Link to existing task").font(COSType.display(23, weight: .medium))
                Spacer()
                Button("Close") { dismiss() }.disabled(saving)
            }
            Text(meeting.title).font(COSType.body(13, weight: .semibold)).lineLimit(3)
            Text("Keep this meeting with an existing workstream. Its source reference and attached files become available from that task; its name, status and other meeting links stay intact.")
                .font(COSType.body(12)).foregroundStyle(COSPalette.muted)
            if let saved {
                Label("Linked to “\(saved.title)”.", systemImage: "checkmark.circle")
                    .font(COSType.body(13, weight: .semibold))
                Text("The meeting is now in Source meetings. The next task handoff includes its reference and attached files. Linking does not send a message to a running session.")
                    .font(COSType.body(12)).foregroundStyle(COSPalette.muted)
                if let onOpenWork {
                    Button("Open task") { dismiss(); onOpenWork(saved.workSourceID) }.buttonStyle(COSPrimaryButtonStyle())
                }
            } else {
                TextField("Search tasks across all domains", text: $query).textFieldStyle(.plain).cosField()
                    .onChange(of: query) { _, _ in selected = nil; error = nil }
                Toggle("Include completed tasks", isOn: $includeCompleted).font(COSType.body(12))
                    .onChange(of: includeCompleted) { _, _ in selected = nil; error = nil }
                if model.workTasksLoading { ProgressView("Loading tasks…").controlSize(.small) }
                if let issue = model.workTasksError { Text(issue).foregroundStyle(COSPalette.danger) }
                if !model.workTasksComplete && !model.workTasksLoading {
                    Text("The task list may be incomplete. Refresh if the task you need is missing.").foregroundStyle(COSPalette.muted)
                }
                if !model.workBoardWritable && !model.workTasksLoading {
                    Text("Linking needs a connected server with Work board support. Update the server and refresh.").foregroundStyle(COSPalette.danger)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(candidates, id: \.workSourceID) { task in
                            let reason = reference.flatMap { MeetingTaskLinkOptions.refusal(task, meeting: $0) }
                            Button { selected = task; error = nil } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: selected?.workSourceID == task.workSourceID ? "largecircle.fill.circle" : "circle")
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(task.text.isEmpty ? task.title : task.text).font(COSType.body(12, weight: .medium))
                                        Text(task.domain + " · " + (task.checked ? "Complete" : task.workStage.capitalized))
                                            .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                                        if let reason { Text(reason).font(COSType.body(11)).foregroundStyle(COSPalette.muted) }
                                    }
                                    Spacer()
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(10).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(reason != nil || saving || !model.workBoardWritable)
                        }
                        if candidates.isEmpty && !model.workTasksLoading {
                            Text(query.isEmpty ? "No tasks available." : "No matching tasks. Try another name or domain.")
                                .foregroundStyle(COSPalette.muted).padding(.vertical, 16)
                        }
                    }
                }.frame(minHeight: 160, maxHeight: 300)
                if reference == nil { Text("This meeting is not saved with a complete reference yet. Save it and refresh before linking.").foregroundStyle(COSPalette.danger) }
                if let error { Text(error).foregroundStyle(COSPalette.danger).textSelection(.enabled) }
                HStack {
                    Button("Refresh tasks") { selected = nil; Task { await model.loadWorkTasks(force: true) } }
                        .disabled(saving || model.workTasksLoading)
                    Spacer()
                    Button(saving ? "Linking…" : "Link selected task") { link() }
                        .buttonStyle(COSPrimaryButtonStyle())
                        .disabled(saving || model.workTasksLoading || !model.workBoardWritable || reference == nil || selected == nil)
                }
            }
        }.font(COSType.body(12)).padding(24).frame(width: 620)
            .background(COSPalette.panel).buttonStyle(COSQuietButtonStyle()).cosControlTheme()
            .interactiveDismissDisabled(saving)
            .task { await model.loadWorkTasks(force: true) }
    }

    private func link() {
        guard !saving, let selected, let reference else { return }
        if let reason = MeetingTaskLinkOptions.refusal(selected, meeting: reference) { error = reason; return }
        saving = true; error = nil
        Task {
            defer { saving = false }
            do { try await model.linkWorkMeeting(selected, meeting: reference); saved = selected }
            catch { self.error = error.localizedDescription }
        }
    }
}
