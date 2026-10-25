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
    /// 0.5.334: the stranded Mac capture (no speech) the inline Discard confirmation is for.
    @State private var discardStrandedTarget: String?
    @AppStorage(LiveTranscript.enabledKey) private var showLiveTranscript = true

    var body: some View {
        VStack(spacing: 0) {
            if !selectionOnly {
                MacRecordingPanel(store: model.macRecording) { operation, payload in
                    let data = try JSONEncoder().encode(JSONValue.object(["operation": .string(operation), "payload": .object(payload)]))
                    return try await model.runHelper(["mac-recording"], timeout: 90, stdinData: data)
                }
            }
            if !selectionOnly && (!model.recoverableOrphans.isEmpty || !model.strandedCaptures.isEmpty) {
                unsavedCaptureBanner
            }
            // 0.5.278: a meeting recording now, pinned above the calendar and outside search. Never in the picker.
            if !selectionOnly && showLiveTranscript {
                LiveNowRows(model: model)
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
        .onAppear { if !selectionOnly { model.liveTranscriptViewer("meetings", visible: true) } }
        .onDisappear { if !selectionOnly { model.liveTranscriptViewer("meetings", visible: false) } }
        // The suggestion count on the doorway comes from the engine, so it is
        // fetched when Meetings opens rather than only once the pane is entered.
        .task { if !selectionOnly { await model.loadMeetingEngineStatus() } }
        .confirmationDialog(
            "Recover all unsaved captures?",
            isPresented: $confirmRecoverAllOrphans,
            titleVisibility: .visible
        ) {
            Button("Recover all") { model.recoverAllOrphans() }.keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Turns each unsaved capture into a meeting, one at a time. Session files are not deleted.")
        }
        .confirmationDialog(
            "Save still-live captures as meetings?",
            isPresented: $confirmSaveAllStranded,
            titleVisibility: .visible
        ) {
            Button("Save all") { model.saveAllStranded() }.keyboardShortcut(.defaultAction)
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
                    // 0.5.334: Save can never work for a Mac capture the server found no speech in; Discard can.
                    if MacRecordingDiscard.strandedOffersDiscard(sessionId: capture.sessionId, transcriptState: capture.transcriptState, canSave: capture.canSave) {
                        Button(MacRecordingDiscard.buttonTitle) { discardStrandedTarget = capture.sessionId }
                            .controlSize(.small)
                            .disabled(model.busy || model.orphanBusy)
                    } else {
                        Button("Save") { model.saveStranded(capture.sessionId) }
                            .controlSize(.small)
                            .disabled(model.busy || model.orphanBusy)
                    }
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
        .cosConfirm(MacRecordingDiscard.confirmTitle, isPresented: Binding(get: { discardStrandedTarget != nil }, set: { if !$0 { discardStrandedTarget = nil } }),
                    message: MacRecordingDiscard.confirmLine, actions: discardStrandedActions)
    }

    /// cosConfirm dismisses BEFORE it runs the action, and dismissal nils `discardStrandedTarget`, so the action closes
    /// over the id captured while the confirmation is on screen and never reads the state itself.
    private var discardStrandedActions: [COSConfirmAction] {
        let pending = discardStrandedTarget
        return [
            .destructive(MacRecordingDiscard.confirmButton) {
                guard let pending else { return }
                model.discardStrandedMac(pending)
            },
            .cancel { },
        ]
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
                // 0.5.309: the one COS dictionary, the opener the Dictionary pane's route flag reads.
                Button("Dictionary") { model.openDictionary() }
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

    /// 0.5.343: the list builds in place on its first load (COSBuildUp); the chain below is today's, untouched.
    private var content: some View {
        COSBuildUp(.rows(6), loading: model.libraryLoading && model.libraryMeetings.isEmpty, landed: !model.libraryMeetings.isEmpty,
                   interrupted: model.isLibraryQueryActive, failed: model.libraryError != nil, enabled: !selectionOnly,
                   label: "Loading meetings") { libraryContent }
    }

    @ViewBuilder
    private var libraryContent: some View {
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

    static func tasks(recordIds: [String], from tasks: [TaskRow]) -> [TaskRow] {
        let ids = Set(recordIds.filter { !$0.isEmpty })
        return tasks.filter { task in task.meetingRefs.contains { ids.contains($0.recordId) } }
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
    /// 0.5.340: Rename voice on a saved Mac recording (session, record, the `Voice N` to name).
    var onRenameVoice: ((String, String?, String) -> Void)? = nil
    var onOpenSource: (LibraryMeetingSource) -> Void = { _ in }
    var onReviewFollowUp: ((LibraryMeeting) -> Void)? = nil
    var onLinkTask: ((LibraryMeeting) -> Void)? = nil
    var onCreateTask: ((LibraryMeeting) -> Void)? = nil
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
                        if let onCreateTask {
                            Button("Create task") { onCreateTask(row) }.buttonStyle(COSPrimaryButtonStyle())
                        }
                        if let onLinkTask {
                            Button("Link to existing task") { onLinkTask(row) }.buttonStyle(COSQuietButtonStyle())
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

            // 0.5.343: the body builds in place under the header while the meeting loads (COSBuildUp); the chain is today's.
            COSBuildUp(.summary(turns: 5), loading: model.libraryDetailLoading && model.libraryDetail == nil,
                       landed: model.libraryDetail != nil, failed: model.libraryDetailError != nil, label: "Loading meeting", key: model.openLibraryRow.map { AnyHashable($0.id) }) {
                VStack(alignment: .leading, spacing: 0) {
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
                        if let row = model.openLibraryRow {
                            let keys = detail.contextKeys.isEmpty ? row.contextKeys : detail.contextKeys
                            if row.sourceSessionId != nil { Text("Ask history covers the whole original capture, including its other split pieces.").font(COSType.body(12)).foregroundStyle(.secondary) }
                            ForEach(Array(row.meetingAskSessions(keys: keys).enumerated()), id: \.element) { captureIndex, session in
                                // 0.5.327: a saved glasses recording shows its cues beside Meeting Ask (the server keeps them 30 days).
                                // 0.5.337 (loop audit W10): a saved Mac recording the server cued shows its Cues tab too.
                                MeetingSidePanel(store: model.meetingAsk.cueVerdicts, model: model, session: session,
                                                 macCues: model.liveMeetingCapability.macCues, askTitle: "Meeting Ask") {
                                    LiveAskPanel(state: model.meetingAsk, model: model, session: session, saved: true, captureLabel: "Original recording \(captureIndex + 1). Questions use its saved cutoff; each recording keeps its own history.", meeting: row)
                                }
                                .frame(minHeight: 300, idealHeight: 500, maxHeight: 600)
                            }
                        }
                        if let workConnections { relatedWork(workConnections) }
                        if isDocument {
                            COSMarkdownView(text: detail.transcript, dropLeadingTitle: true, meetingTranscript: true, bodySize: 14)
                        } else {
                            if !detail.attendees.isEmpty {
                                labeled("Attendees", detail.attendees.joined(separator: ", "))
                            }
                            if !detail.summary.isEmpty {
                                labeled("Summary", detail.summary)
                            }
                            if !detail.transcript.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Transcript").font(COSType.body(12, weight: .semibold))
                                    COSMarkdownView(text: detail.transcript, meetingTranscript: true, bodySize: 14)
                                }
                            }
                        }
                        if detail.summary.isEmpty && detail.transcript.isEmpty {
                            Text("This record has no summary or transcript stored.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(COSType.body(12.5))
                    .padding(24)
                    .frame(maxWidth: 700, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 0, maxHeight: .infinity)
                .clipped()
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
                    Button("Copy full context") { model.copyLibraryMeeting(kind: .context) }
                        .buttonStyle(COSPrimaryButtonStyle())
                        .keyboardShortcut("c", modifiers: .command)
                    Button("Copy summary") { model.copyLibraryMeeting(kind: .summary) }
                        .disabled(detail.summary.isEmpty)
                    Button(MeetingAskText.transcript(detail.transcript).document ? "Copy meeting document" : "Copy transcript") { model.copyLibraryMeeting(kind: .transcript) }
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
                        // 0.5.340: a saved Mac recording names its `Voice N` turns here, through the same
                        // per-meeting relabel the review uses. Text only; see MacVoiceCopy.renameNote.
                        let macVoices = MacVoiceLabel.isMacSession(row.sessionId) ? MacVoiceLabel.voices(inTranscript: detail.transcript) : []
                        if let onRenameVoice, !macVoices.isEmpty {
                            Menu(MacVoiceCopy.menuTitle) {
                                ForEach(macVoices, id: \.self) { label in
                                    Button(MacVoiceCopy.menuItem(label)) { onRenameVoice(row.sessionId, row.recordId, label) }
                                }
                            }.cosMenu()
                        }
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
        MeetingFileRow(files: files, file: file, folder: folder, id: id, removable: supported == true, preview: $preview)
    }
}

/// One file in a meeting's list: its icon, name, state and details, and Quick Look, Show in Finder (or Open the link) and
/// Remove (Undo is offered). Shared by the saved meeting's Files box and the live pane's Files row (0.5.339).
struct MeetingFileRow: View {
    @ObservedObject var files: WorkCardFileStore
    let file: WorkContextFile
    let folder: URL
    /// The meeting folder's id the file sits in (Remove and Undo act there).
    let id: String
    let removable: Bool
    @Binding var preview: URL?
    @State private var hover = false

    var body: some View {
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
                    if removable { icon("xmark", "Remove from this meeting (Undo is offered)") { files.remove(file.id, workID: id) } }
                }.foregroundStyle(COSPalette.muted)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(hover ? COSPalette.gold.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
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
                            .keyboardShortcut(.defaultAction)
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
                .keyboardShortcut(.defaultAction)
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
    var initiallyCreating = false
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDiscard = false
    @State private var creating = false
    @State private var taskName = ""
    @State private var taskDomain = ""
    @State private var createdWorkID: String?
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
                Text(creating ? "Create task from meeting" : "Link to existing task").font(COSType.display(23, weight: .medium))
                Spacer()
                Button("Close") { requestClose() }.disabled(saving)
            }
            Text(meeting.title).font(COSType.body(13, weight: .semibold)).lineLimit(3)
            if creating { createForm } else {
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
                Button("Link another task") { self.saved = nil; selected = nil; error = nil }
                    .buttonStyle(COSQuietButtonStyle())
            } else {
                Button("Create a new task instead") { creating = true; error = nil }.disabled(saving)
                TextField("Search tasks across all domains", text: $query).textFieldStyle(.plain).cosField()
                    .onChange(of: query) { _, _ in selected = nil; error = nil }
                Toggle("Include completed tasks", isOn: $includeCompleted).font(COSType.body(12))
                    .toggleStyle(COSCheckStyle())
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
                            HStack(spacing: 8) {
                            Button { selected = task; error = nil } label: {
                                HStack(alignment: .center, spacing: 10) {
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
                            if let onOpenWork {
                                Button("Open task") { dismiss(); onOpenWork(task.workSourceID) }
                                    .buttonStyle(COSQuietButtonStyle()).disabled(saving)
                            }
                            }
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
                        .keyboardShortcut(.defaultAction)
                }
            }
            }
        }.font(COSType.body(12)).padding(24).frame(width: 620)
            .background(COSPalette.panel).buttonStyle(COSQuietButtonStyle()).cosControlTheme()
            .interactiveDismissDisabled(saving || (creating && createdWorkID == nil))
            .cosConfirm("Discard new task?", isPresented: $confirmingDiscard,
                message: "Your new task has not been saved.",
                actions: [.destructive("Discard") { dismiss() }, .cancel("Keep editing")])
            .task {
                creating = initiallyCreating
                if taskName.isEmpty { taskName = meeting.title }
                taskDomain = model.domainOptions.contains { $0.name == meeting.domain } ? meeting.domain : ""
                await model.loadWorkTasks(force: true)
            }
    }

    private func requestClose() {
        guard !saving else { return }
        if creating && createdWorkID == nil && taskName != meeting.title { confirmingDiscard = true }
        else { dismiss() }
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let createdWorkID {
                Label("Task saved and linked to this meeting.", systemImage: "checkmark.circle")
                Text("Source meetings and saved meeting files are available from the task.").foregroundStyle(COSPalette.muted)
                if let issue = model.workTasksError { Text("Task saved; refreshing Work failed: " + issue).foregroundStyle(COSPalette.danger) }
                if let onOpenWork {
                    Button("Open task in Work") { dismiss(); onOpenWork(createdWorkID) }.buttonStyle(COSPrimaryButtonStyle())
                }
                Button("Create another task") { self.createdWorkID = nil; taskName = ""; error = nil }
            } else {
                Text("Name the follow-up. COS saves it in Mentioned with this meeting and its files as context.").foregroundStyle(COSPalette.muted)
                TextField("Task name", text: $taskName).textFieldStyle(.plain).cosField().accessibilityLabel("New task name").disabled(saving)
                COSDropdown("Domain", selection: $taskDomain,
                    options: [COSDropdownOption("", "Choose domain", placeholder: true)] + model.domainOptions.map { COSDropdownOption($0.name, $0.label) }).disabled(saving)
                if reference == nil { Text("Save this meeting with a complete reference before creating a task.").foregroundStyle(COSPalette.danger) }
                if let error { Text(error).foregroundStyle(COSPalette.danger).textSelection(.enabled) }
                HStack {
                    Button("Link to existing task instead") { creating = false; error = nil }.disabled(saving)
                    Spacer()
                    Button(saving ? "Creating…" : "Create task") { create() }
                        .buttonStyle(COSPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                        .disabled(saving || reference == nil || taskName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || taskName.utf16.count > 2000 || !model.domainOptions.contains { $0.name == taskDomain })
                }
            }
        }
    }

    private func create() {
        guard !saving, let reference else { return }
        let text = taskName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf16.count <= 2000, model.domainOptions.contains(where: { $0.name == taskDomain }) else { return }
        saving = true; error = nil
        Task {
            defer { saving = false }
            do { createdWorkID = try await model.createMeetingTask(domain: taskDomain, text: text, meeting: reference) }
            catch { self.error = error.localizedDescription }
        }
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

// MARK: - Live meeting transcript (0.5.278)
//
// A glasses meeting that is recording shows as a pinned "Live now" row at the top of Meetings, above the calendar and
// outside search, and opens the text so far in its own pane (its own route flag, `liveTranscriptRouteActive`, written
// only by `openLiveTranscript` and `closeLiveTranscript`). The transcript opens only when clicked: a shared screen never
// shows it unasked. Plain text, never Markdown; speaker names are muted guesses.

/// The pinned rows, one per live session, most recent first.
struct LiveNowRows: View {
    @ObservedObject var model: ControllerModel
    @State private var confirmEnd: LiveTranscriptRow?
    /// 0.5.321: the live glasses meeting the inline Stop and save confirmation is for.
    @State private var glassesStopTarget: String?

    var body: some View {
        let rows = model.liveTranscriptRows
        if !rows.isEmpty {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                VStack(spacing: 6) {
                    ForEach(rows) { row in
                        HStack(spacing: 8) {
                            LiveNowRow(row: row, now: context.date, clock: model.clockStyle) { model.openLiveTranscript(row.sessionId) }
                            // 2026-10-15 (Miles): a recording whose glasses dropped sat as "Live now · No audio for 22m"
                            // with no way to close it. Offered only once audio has stopped, never on a row still receiving.
                            if let title = LiveTranscript.endActionTitle(row: row, now: context.date) {
                                Button(title) {
                                    if row.sessionId.hasPrefix("mac_") { model.saveStranded(row.sessionId) } else { confirmEnd = row }
                                }
                                .controlSize(.small)
                                .disabled(model.busy || model.orphanBusy)
                            } else if row.phase == .live, G2MeetingStop.isGlassesSession(row.sessionId) {
                                // 0.5.321: a glasses meeting still receiving audio stops on the glasses, asked from here.
                                Button(G2MeetingStop.buttonLabel) { glassesStopTarget = row.sessionId }
                                    .controlSize(.small)
                                    .disabled(model.glassesMeetingStopping(row.sessionId))
                            }
                        }
                        if let line = model.glassesMeetingStopLine(row.sessionId) {
                            Text(line).font(COSType.body(11)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .cosConfirm(G2MeetingStop.confirmTitle, isPresented: Binding(get: { glassesStopTarget != nil }, set: { if !$0 { glassesStopTarget = nil } }),
                            message: G2MeetingStop.confirmMessage, actions: [
                    .destructive(G2MeetingStop.confirmAction) {
                        if let id = glassesStopTarget { model.stopGlassesMeeting(id) }
                        glassesStopTarget = nil
                    },
                    .cancel { glassesStopTarget = nil },
                ])
                .confirmationDialog("End this recording and save it?", isPresented: Binding(get: { confirmEnd != nil }, set: { if !$0 { confirmEnd = nil } }), presenting: confirmEnd) { row in
                    Button("End and save") { model.saveStranded(row.sessionId); confirmEnd = nil }
                    Button("Keep it open", role: .cancel) { confirmEnd = nil }
                } message: { _ in
                    Text("Saves everything the server received as a meeting. Audio the glasses or phone still hold is not added after this.")
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { Divider() }
            }
        }
    }
}

struct LiveNowRow: View {
    let row: LiveTranscriptRow
    let now: Date
    let clock: ClockStyle
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: 12) {
                LiveDot(live: row.phase == .live && row.deliveryLabel == nil)
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.deliveryLabel ?? (row.phase == .live ? "Live now" : (LiveTranscript.phaseLabel(row.phase) ?? "Live now")))
                        .font(COSType.body(13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    HStack(spacing: 0) {
                        Text(LiveTranscriptText.subtitle(start: row.startTime, now: now, clock: clock, endedAt: row.endedAt))
                            .foregroundStyle(.secondary)
                        if row.phase == .live, row.deliveryLabel == nil, let quiet = LiveTranscript.quietLabel(lastActivity: row.lastActivity, now: now) {
                            Text(" · " + quiet).foregroundStyle(COSPalette.amber)
                        }
                    }
                    .font(COSType.body(11))
                    .lineLimit(1)
                }
                Spacer()
                Text("Live transcript")
                    .font(COSType.body(11))
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .cosRowCard()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.phase == .live ? "Live meeting. Open the live transcript" : (LiveTranscript.phaseLabel(row.phase) ?? "Live meeting"))
    }
}

struct LiveDot: View {
    var live = true
    var size: CGFloat = 8
    var body: some View {
        Circle()
            .fill(live ? COSPalette.live : COSPalette.muted.opacity(0.6))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

enum LiveTranscriptText {
    /// "Started 7:27 AM · 12 min", or "Starting" before the first read.
    /// The duration stops when the recording ended.
    static func subtitle(start: Date?, now: Date, clock: ClockStyle, endedAt: Date? = nil) -> String {
        guard let start else { return "Starting" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = clock == .twentyFourHour ? "HH:mm" : "h:mm a"
        let started = "Started " + formatter.string(from: start)
        return LiveTranscript.durationLabel(start: start, now: now, endedAt: endedAt).map { started + " · " + $0 } ?? started
    }

    /// The pane's footer word for a failed poll: the reason code, never message text.
    static func paused(_ reason: String) -> String { "Live transcript paused · " + reason.replacingOccurrences(of: "_", with: " ") }
}

/// The live transcript pane: the header, the turns, Jump to live and Copy transcript.
struct LiveTranscriptPane: View {
    @ObservedObject var model: ControllerModel
    @State private var follow = LiveTranscriptFollow()
    @State private var atBottom = true
    @State private var showAsk = true
    /// 0.5.339 (approved mock wk43 mock-339): one place for files. The Files row stays collapsed until opened; adding
    /// moved to the whole pane (a drop anywhere on it) and the bar's Add file button, so nothing to add hides in it.
    @State private var filesOpen = false
    /// 0.5.339: a file is being dragged over the pane (the outline and "Drop to add to this meeting" on the transcript).
    @State private var dropTargeted = false
    /// 0.5.339: the Add file menu (inline, never a sheet or a popover window).
    @State private var addMenuOpen = false
    /// 0.5.339: Command-V adds a screenshot while the pane itself has focus (a click on its header or bar). A text field
    /// keeps its own paste: this is the responder chain's paste, never a key equivalent that could take it.
    @FocusState private var paneFocused: Bool
    @State private var askJumpID: Int?
    @AppStorage("meetingAskPanelWidth") private var askWidth = 360.0
    @State private var resizeStart: Double?
    /// 0.5.337 (performance audit W7): the width while the divider is dragged; AppStorage is written once, when it ends.
    @State private var dragWidth: Double?
    /// 0.5.321: the inline confirmation for Stop and save on a glasses meeting (COSConfirm, never a sheet).
    @State private var confirmGlassesStop = false
    /// 0.5.336: the cue history, observed so the inline cues and the header's counts redraw when it is read again.
    @ObservedObject private var cueStore: CueVerdictsStore

    init(model: ControllerModel) {
        _model = ObservedObject(wrappedValue: model)
        _cueStore = ObservedObject(wrappedValue: model.meetingAsk.cueVerdicts)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = min(max(280, dragWidth ?? askWidth), max(280, geometry.size.width - 440))
            HStack(spacing: 0) {
                meetingBody
                if showAsk, let session = model.liveTranscriptOpenID {
                    Rectangle().fill(COSPalette.line).frame(width: 6)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                            if resizeStart == nil { resizeStart = askWidth }
                            dragWidth = min(max(280, (resizeStart ?? askWidth) - value.translation.width), max(280, geometry.size.width - 440))
                        }.onEnded { _ in
                            if let dragWidth { askWidth = dragWidth }
                            dragWidth = nil; resizeStart = nil
                        })
                        .accessibilityLabel("Resize meeting assistant")
                        .accessibilityAdjustableAction { direction in
                            askWidth = min(max(280, askWidth + (direction == .increment ? 40 : -40)), max(280, geometry.size.width - 440))
                        }
                    // 0.5.327: the panel's Cues view sits beside Live COS Ask on a server with the cue history.
                    MeetingSidePanel(store: model.meetingAsk.cueVerdicts, model: model, session: session,
                                     live: model.openLiveTranscriptFeed?.ended != true, macCues: model.liveMeetingCapability.macCues) {
                        LiveAskPanel(state: model.meetingAsk, model: model, session: session, feed: model.openLiveTranscriptFeed) { id in
                            follow.selectionBegan(); askJumpID = id
                        }
                    }.frame(width: width)
                }
            }
        }
        .onChange(of: model.liveTranscriptOpenID) { _, _ in askJumpID = nil; confirmGlassesStop = false }
        .cosConfirm(G2MeetingStop.confirmTitle, isPresented: $confirmGlassesStop, message: G2MeetingStop.confirmMessage, actions: [
            .destructive(G2MeetingStop.confirmAction) {
                if let id = model.liveTranscriptOpenID { model.stopGlassesMeeting(id) }
            },
            .cancel(),
        ])
    }

    private var meetingBody: some View {
        let feed = model.openLiveTranscriptFeed
        let session = model.liveTranscriptOpenID
        let mac = session?.hasPrefix("mac_") == true
        return VStack(alignment: .leading, spacing: 0) {
            TimelineView(.periodic(from: .now, by: 15)) { context in header(feed, now: context.date) }
            if let session, !session.hasPrefix("mac_"), feed?.ended != true {
                MeetingSpeakerPolicyView(model: model, sessionId: session).id(session).padding(.horizontal, 22).padding(.bottom, 10)
            }
            // 0.5.336: the voices heard so far, with the one heard last.
            if let feed, !feed.turns.isEmpty {
                let strip = LiveMeeting.participants(feed.turns, mac: mac)
                if !strip.people.isEmpty { LiveParticipantStrip(people: strip.people, lastHeard: strip.lastHeard).padding(.bottom, 10) }
            }
            Divider()
            Group {
            if let feed, !feed.turns.isEmpty {
                transcript(feed)
            } else {
                VStack(spacing: 14) {
                    Text(feed?.ended == true ? "No words were transcribed before the recording ended." : "Waiting for the first words. Text appears a few seconds after it is spoken.")
                        .font(COSType.body(12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    if let session, feed?.ended != true, model.liveMeetingCapability.greyLine || mac {
                        LiveProvisionalLineView(feed: model.liveProvisional, sessionId: session, lastFinalChunk: LiveMeeting.lastFinalChunk(feed)) {}
                            .frame(maxWidth: 560)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(30)
            }
            }
            // 0.5.339: while a file is dragged over the pane, the transcript is outlined with where it goes. Drawn only:
            // the drop destination is the pane itself (an overlay drop destination never fires, 0.5.246).
            .overlay { if dropTargeted { LiveFilesDropOutline() } }
            .overlay { if addMenuOpen { menuDismissLayer } }
            // 0.5.336, 0.5.339: the bottom bar while it records, with Add file beside Stop. The line that used to sit under
            // it ("Drop in screenshots or files while it's on") is gone: the whole pane takes the drop.
            if let session, feed?.ended != true {
                LiveRecordingBar(start: feed?.startTime ?? macStart(session), mac: mac,
                                 levelStrip: !mac && model.liveMeetingCapability.levelStrip, sessionId: session) { labelled in
                    addFileControl(session, labelled: labelled)
                } stop: { stopControls(feed) }
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 2)
                .contentShape(Rectangle())
                .onTapGesture { if canAddFiles(session) { paneFocused = true } }
            } else {
                Divider()
            }
            footer(feed)
        }
        // 0.5.339: the whole live pane takes a file drop, into the same meeting-files store and intake as before.
        .modifier(MeetingFilesDrop(enabled: session.map(canAddFiles) ?? false, targeted: $dropTargeted) { providers in
            guard let session, let files = model.workHandoffStore?.meetingFiles else { return }
            let key = LibraryMeeting.captureContextKey(session), info = model.liveMeetingFileInfo(session)
            Task { await files.intakeMeeting(providers: providers, key: key, info: info) }
        })
        .focusable(session.map(canAddFiles) ?? false, interactions: .edit)
        .focusEffectDisabled()
        .focused($paneFocused)
        .onPasteCommand(of: [.fileURL, .png, .tiff]) { _ in if let session { pasteScreenshot(session) } }
        .onChange(of: dropTargeted) { _, targeted in if targeted { addMenuOpen = false } }
        .onChange(of: session) { _, _ in addMenuOpen = false; filesOpen = false }
        .task(id: "\(session ?? "") \(model.liveMeetingCapability.inlineCues) \(feed?.ended == true)") { await followInlineCues(session) }
        .frame(minWidth: 420, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity, alignment: .top)
        .background(COSPalette.panel)
        .onAppear { model.liveTranscriptViewer("live-pane", visible: true) }
        .onDisappear { model.liveTranscriptViewer("live-pane", visible: false) }
    }

    private func header(_ feed: LiveTranscriptFeed?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                LiveDot(live: feed?.ended != true, size: 10)
                // 0.5.336: the meeting's real title (typed, or the calendar's), never a fixed "Live meeting".
                Text(verbatim: model.liveTranscriptOpenID.map { model.liveMeetingTitle($0, start: feed?.startTime) } ?? "Live meeting")
                    .font(COSType.display(22, weight: .medium))
                    .lineLimit(1)
                // 0.5.313 (Miles 2026-10-15): a G2 meeting and a Mac recording can be live together; switch between them
                // here, without leaving the live view.
                let liveRows = model.liveTranscriptRows.filter { $0.phase == .live }
                if liveRows.count > 1, let current = model.liveTranscriptOpenID {
                    COSDropdown("Showing", selection: Binding(get: { current }, set: { model.openLiveTranscript($0) }),
                                options: liveRows.map { COSDropdownOption($0.sessionId, LiveTranscript.sourceLabel($0.sessionId, start: $0.startTime)) })
                        .fixedSize()
                }
                Spacer()
                Button(showAsk ? "Hide Ask" : "Live COS Ask") { showAsk.toggle() }
                    .buttonStyle(COSQuietButtonStyle())
            }
            // 0.5.336: where it records and, on a server that lists its cue kinds, what the cues found so far.
            if let id = model.liveTranscriptOpenID,
               let status = LiveMeeting.statusLine(mac: id.hasPrefix("mac_"), ended: feed?.ended == true,
                                                   kinds: model.liveMeetingCapability.counts ? inlineCues(id).map(\.kind) : nil) {
                Text(status).font(COSType.body(12.5, weight: .medium)).foregroundStyle(.primary)
            }
            if let arm = model.macRecording.manifest?.captureId == model.liveTranscriptOpenID ? model.macRecording.liveCuesArm : nil,
               let line = LiveMeeting.armLine(arm) {
                HStack(spacing: 8) {
                    Text(line).font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                    // 0.5.337 (loop audit W9): a missing key has a way forward, the key fields in Settings.
                    if LiveMeeting.needsDecisionKey(arm) {
                        Button(LiveCues.addKeyLabel) { model.showDecisionKeySettings?() }.buttonStyle(COSTextButtonStyle())
                    }
                }
            }
            Text(LiveTranscript.header)
                .font(COSType.body(12))
                .foregroundStyle(.secondary)
            if let line = model.glassesMeetingStopLine(model.liveTranscriptOpenID) {
                Text(line)
                    .font(COSType.body(11.5, weight: .semibold))
                    .foregroundStyle(model.glassesMeetingStop?.phase.nothingStopped == true ? COSPalette.danger : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.liveTranscriptOpenID?.hasPrefix("mac_") == true {
                Text("Mac playback · microphone off · speaker names only at high confidence").font(COSType.body(11)).foregroundStyle(.secondary)
                // An empty feed reads the same whether nothing was said or nothing reached COS; say which (2026-10-15).
                if model.macRecording.manifest?.captureId == model.liveTranscriptOpenID, let warning = model.macRecording.signalWarning {
                    Text(warning).font(COSType.body(11, weight: .semibold)).foregroundStyle(COSPalette.danger)
                }
            }
            HStack(spacing: 0) {
                Text(LiveTranscriptText.subtitle(start: feed?.startTime, now: now, clock: model.clockStyle, endedAt: feed?.endedAt))
                    .foregroundStyle(.tertiary)
                if feed?.ended != true, let quiet = LiveTranscript.quietLabel(lastActivity: feed?.lastActivityAt, now: now) {
                    Text(" · " + quiet).foregroundStyle(COSPalette.amber)
                }
            }
            .font(COSType.body(11.5))
            if let feed, feed.ended {
                // 0.5.334: a Mac capture with no sound has no meeting to find; say so instead of looking for one.
                if MacRecordingNoMeeting.endsHandoff(sessionId: feed.sessionId, noMeeting: model.macRecording.noMeetingCaptureIDs) {
                    Text(MacRecordingNoMeeting.line).font(COSType.body(11.5)).foregroundStyle(.secondary)
                } else { handoffLine(feed) }
            }
            // 0.5.339: one collapsed "Files · N" row (hidden with none); open, the list with Quick Look, Show in Finder and
            // Remove, and the note. No drop strip and no buttons of its own: adding is the pane's drop and the bar's Add file.
            if let session = model.liveTranscriptOpenID, let files = model.workHandoffStore?.meetingFiles {
                LiveMeetingFilesRow(files: files, key: LibraryMeeting.captureContextKey(session), info: model.liveMeetingFileInfo(session), open: $filesOpen)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            addMenuOpen = false
            if let session = model.liveTranscriptOpenID, canAddFiles(session) { paneFocused = true }
        }
    }

    /// Files may be added to this live meeting: meeting files are on and its capture key names a meeting folder.
    private func canAddFiles(_ session: String) -> Bool {
        guard let files = model.workHandoffStore?.meetingFiles, files.enabled else { return false }
        return WorkCardFiles.meetingID(forKey: LibraryMeeting.captureContextKey(session)) != nil
    }

    /// Paste screenshot: the clipboard's image or files, through the meeting-files paste (the same path as before).
    private func pasteScreenshot(_ session: String) {
        guard canAddFiles(session), let files = model.workHandoffStore?.meetingFiles else { return }
        let key = LibraryMeeting.captureContextKey(session), info = model.liveMeetingFileInfo(session)
        Task { await files.pasteMeeting(from: NSPasteboard.general, key: key, info: info) }
    }

    /// Choose files…: files and folders, several at once, through the same intake as a drop.
    private func chooseFiles(_ session: String) {
        guard canAddFiles(session), let files = model.workHandoffStore?.meetingFiles else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "Add to meeting"; panel.message = "Choose screenshots, slides or files to add to this meeting."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls, key = LibraryMeeting.captureContextKey(session), info = model.liveMeetingFileInfo(session)
        Task { await files.intakeMeeting(urls: urls, key: key, info: info) }
    }

    /// The bar's Add file button and its inline menu (Paste screenshot, Choose files…). Command-O chooses files while the
    /// live pane shows; Command-V is the pane's paste (above). Only while files may be added.
    @ViewBuilder
    private func addFileControl(_ session: String, labelled: Bool) -> some View {
        if canAddFiles(session) {
            LiveAddFileButton(labelled: labelled, open: $addMenuOpen,
                              paste: { addMenuOpen = false; pasteScreenshot(session) },
                              choose: { addMenuOpen = false; chooseFiles(session) })
        }
    }

    /// Under the open Add file menu: a click anywhere else on the pane closes it.
    private var menuDismissLayer: some View {
        Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { addMenuOpen = false }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func handoffLine(_ feed: LiveTranscriptFeed) -> some View {
        switch feed.phase {
        case .finalizing, .saved:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finalizing · the saved meeting opens here when it is ready")
            }
            .font(COSType.body(11.5))
            .foregroundStyle(.secondary)
        case .notFoundYet:
            HStack(spacing: 10) {
                Text(LiveTranscript.macHandoffNeedsServerUpdate(sessionId: feed.sessionId, serverVersion: model.status.version)
                     ? "Update the COS server to 6.73.14 to list saved Mac recordings" : "Saved meeting not found yet")
                    .foregroundStyle(COSPalette.amber)
                Button("Refresh") { model.refreshLiveTranscriptHandoff(feed.sessionId) }
                    .buttonStyle(COSQuietButtonStyle())
                    .controlSize(.small)
            }
            .font(COSType.body(11.5))
        case .endedUnsaved:
            Text("Recording ended without saving")
                .font(COSType.body(11.5, weight: .semibold))
                .foregroundStyle(COSPalette.amber)
        case .ended:
            Text("Recording ended")
                .font(COSType.body(11.5))
                .foregroundStyle(.secondary)
        case .live:
            EmptyView()
        }
    }

    private func transcript(_ feed: LiveTranscriptFeed) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    let hours = LiveTranscript.usesHours(feed.turns)
                    let cues = inlineCues(feed.sessionId)
                    let anchored = LiveMeeting.anchor(cues: cues.map { ($0.id, $0.createdAt) }, turns: feed.turns, start: feed.startTime)
                    // 0.5.337 (performance audit W7): each turn's cues looked up, not filtered per turn.
                    let byTurn = LiveMeeting.cuesByTurn(cues, id: \.id, anchored: anchored)
                    ForEach(feed.turns) { turn in
                        LiveTurnRow(turn: turn, hours: hours)
                        // 0.5.336: each cue under the turn it belongs to, with its verdicts.
                        ForEach(byTurn[turn.id] ?? []) { cue in
                            LiveInlineCueRow(cue: cue, saving: cueStore.saving.contains(cue.id), error: cueStore.rateErrors[cue.id]) { verdict in
                                Task { await cueStore.rate(cue, verdict: verdict, note: cue.rating?.note, run: CueReviewPane.run(model)) }
                            }
                        }
                    }
                    // 0.5.336: the words still being transcribed, greyed, replaced by the final text.
                    if feed.ended != true, model.liveMeetingCapability.greyLine || feed.sessionId.hasPrefix("mac_") {
                        LiveProvisionalLineView(feed: model.liveProvisional, sessionId: feed.sessionId, lastFinalChunk: LiveMeeting.lastFinalChunk(feed)) {
                            if follow.contentChanged(now: Date()) { proxy.scrollTo(LiveTranscriptPane.bottomID, anchor: .bottom) }
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(LiveTranscriptPane.bottomID)
                        .onAppear { atBottom = true; follow.bottomAppeared() }
                        .onDisappear { atBottom = false; follow.bottomDisappeared(now: Date()) }
                }
                .textSelection(.enabled)
                .padding(24)
                .frame(maxWidth: 700, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // An oversized source chunk must scroll inside the body, never draw over the fixed header/footer.
            .frame(minHeight: 0, maxHeight: .infinity)
            .clipped()
            // A drag in the text is a selection: hold the view still until a click or Jump to live.
            .simultaneousGesture(DragGesture(minimumDistance: 3).onChanged { _ in follow.selectionBegan() })
            .simultaneousGesture(TapGesture().onEnded { follow.tapped(atBottom: atBottom) })
            .onChange(of: LiveTranscriptFollow.signature(feed.turns)) { _, _ in
                if follow.contentChanged(now: Date()) { proxy.scrollTo(LiveTranscriptPane.bottomID, anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo(LiveTranscriptPane.bottomID, anchor: .bottom) }
            .onChange(of: askJumpID) { _, id in if let id { proxy.scrollTo(id, anchor: .top); askJumpID = nil } }
            .onChange(of: follow.jumpRequests) { _, _ in proxy.scrollTo(LiveTranscriptPane.bottomID, anchor: .bottom) }
        }
    }

    static let bottomID = "live-transcript-bottom"

    /// 0.5.336: the open meeting's cues for the inline lines, only on a server with the live meeting surface (an older
    /// server keeps the Cues tab alone). The history store's copy, so a verdict here shows in the Cues tab too.
    private func inlineCues(_ session: String) -> [LiveCueRecord] {
        guard model.liveMeetingCapability.inlineCues else { return [] }
        return cueStore.meetings[session]?.cues ?? []
    }

    /// While a meeting with inline cues is live: re-ask the cue history every few seconds; the store reads no more than
    /// once per 15 s per meeting, and one read at a time.
    private func followInlineCues(_ session: String?) async {
        guard let session, model.liveMeetingCapability.inlineCues, model.openLiveTranscriptFeed?.ended != true,
              G2MeetingStop.isGlassesSession(session) || model.liveMeetingCapability.macCues else { return }
        while !Task.isCancelled {
            await cueStore.loadMeeting(session, days: CueVerdicts.liveDays, run: CueReviewPane.run(model))
            try? await Task.sleep(for: .seconds(LiveMeeting.inlineCueCheckSeconds))
        }
    }

    /// The Mac recording's own start, before the first read gives the session's.
    private func macStart(_ session: String) -> Date? {
        guard let manifest = model.macRecording.manifest, manifest.captureId == session else { return nil }
        return Date(timeIntervalSince1970: manifest.startTime / 1000)
    }

    /// Stop in the bottom bar: a Mac recording stops and saves here (and with Command-Shift-R); a glasses meeting asks the
    /// glasses after the inline confirmation (0.5.321).
    @ViewBuilder
    private func stopControls(_ feed: LiveTranscriptFeed?) -> some View {
        if model.macRecording.isRecording, model.macRecording.manifest?.captureId == model.liveTranscriptOpenID {
            Button("Stop and save") { Task { await model.macRecording.stop() } }.buttonStyle(COSQuietButtonStyle())
                .help("Stop and save (Command-Shift-R)")
        }
        // 0.5.321: a live glasses meeting stops on the glasses, asked from here after an inline confirmation.
        if let id = model.liveTranscriptOpenID, G2MeetingStop.isGlassesSession(id), feed?.ended != true {
            Button(G2MeetingStop.buttonLabel) { confirmGlassesStop = true }
                .buttonStyle(COSQuietButtonStyle())
                .disabled(model.glassesMeetingStopping(id))
        }
    }

    private func footer(_ feed: LiveTranscriptFeed?) -> some View {
        HStack(spacing: 8) {
            Button("Copy transcript") { model.copyLiveTranscript() }
                .buttonStyle(COSPrimaryButtonStyle())
                .disabled(feed?.turns.isEmpty ?? true)
            Button("Copy full context") {
                guard let session = model.liveTranscriptOpenID,
                      let snapshot = model.meetingAsk.captureCopy(title: "Live meeting", transcript: model.liveTranscriptCopyText ?? "", sessions: [session], localFiles: model.meetingAskFiles(session: session)) else { return }
                Task {
                    if let text = await model.meetingAsk.prepareCopy(snapshot, model: model) { model.meetingAsk.copyPrepared(text) }
                    model.liveTranscriptCopyNote = model.meetingAsk.notice
                }
            }.buttonStyle(COSQuietButtonStyle())
            if !follow.following, !(feed?.turns.isEmpty ?? true) {
                Button("Jump to live") { follow.jumpToLive(now: Date()) }
                    .buttonStyle(COSQuietButtonStyle())
            }
            Spacer()
            if let note = model.liveTranscriptCopyNote {
                Text(note).foregroundStyle(.secondary)
            } else if let reason = model.liveTranscriptReason {
                Text(LiveTranscriptText.paused(reason)).foregroundStyle(COSPalette.amber)
            }
        }
        .font(COSType.body(11))
        .controlSize(.small)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

struct LiveTurnRow: View {
    let turn: LiveTranscriptTurn
    /// One stamp format for the whole transcript, as Copy writes it.
    var hours = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(verbatim: turn.speaker)
                    .font(COSType.body(11.5, weight: .semibold))
                    .foregroundStyle(COSPalette.muted)
                Text(verbatim: LiveTranscript.stamp(turn.elapsedMs, hours: hours))
                    .font(COSType.mono(10))
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: turn.text)
                .font(COSType.body(14))
                .lineSpacing(4)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Live meeting view (0.5.336, server 6.86.0)
//
// The parts of the live meeting window that move: each in its own small view observing its own object, so a level ten
// times a second or a grey line every 1.5 s redraws that view and nothing around it. The rules are LiveMeeting
// (Sources/LiveTranscript.swift).

/// The Mac recording's audiogram levels, ten a second (MacAudioCapture's drain). The DictationMeterFeed pattern: its own
/// object, observed only by the bar and the rail badge, never on ControllerModel or MacRecordingStore. One for the app,
/// since one Mac recording runs at a time.
@MainActor final class LiveAudiogramFeed: ObservableObject {
    static let live = LiveAudiogramFeed()
    @Published private(set) var ring = LiveAudiogramRing()
    private var meter = DictationLevelMeter()
    /// One drain tick's RMS (raw float samples, 0 to 1).
    func push(rms: Double) { var next = ring; next.push(meter.update(rms: rms)); ring = next }
    func reset() { meter = DictationLevelMeter(); if ring.pushed > 0 { ring = LiveAudiogramRing() } }
}

/// The grey line per live session, in memory only (ControllerModel.liveProvisional). Never logged or saved.
@MainActor final class LiveProvisionalFeed: ObservableObject {
    @Published private(set) var lines: [String: LiveProvisionalLine] = [:]
    func set(_ sessionId: String, _ line: LiveProvisionalLine?) { if lines[sessionId] != line { lines[sessionId] = line } }
    func clear() { if !lines.isEmpty { lines = [:] } }
}

/// The scrolling audiogram: one Canvas of the history ring, newest at the right, a bar per level and dotted segments
/// where it is silent. Reduce Motion: a static level bar, no scrolling.
struct LiveAudiogramView: View {
    @ObservedObject var feed: LiveAudiogramFeed
    var height: CGFloat = 22
    /// Points per level: the full 12 s ring is 300 pt.
    static let step: CGFloat = 2.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(COSPalette.line)
                        Capsule().fill(COSPalette.accent).frame(width: max(2, geometry.size.width * feed.ring.latest))
                    }
                }
                .frame(height: 4)
                .frame(height: height)
            } else {
                // 0.5.339: a fixed step per level, newest at the right edge. A narrower bar clips the OLDEST levels at
                // the left (faded), down to the 40 pt floor; it never squeezes the history.
                Canvas { context, size in
                    let levels = feed.ring.levels
                    let step = LiveAudiogramView.step
                    let mid = size.height / 2
                    for (back, level) in levels.reversed().enumerated() {
                        let x = size.width - (CGFloat(back) + 0.5) * step
                        guard x >= 0 else { break }
                        if LiveAudiogramRing.isSilent(level) {
                            if back % 3 == 0 {
                                context.fill(Path(ellipseIn: CGRect(x: x - 0.75, y: mid - 0.75, width: 1.5, height: 1.5)), with: .color(COSPalette.muted.opacity(0.7)))
                            }
                        } else {
                            let h = max(2, CGFloat(level) * size.height)
                            context.fill(Path(roundedRect: CGRect(x: x - step * 0.3, y: mid - h / 2, width: max(1, step * 0.6), height: h), cornerRadius: 1),
                                         with: .color(COSPalette.accent))
                        }
                    }
                }
                .frame(height: height)
                .mask(LiveMeterFade())
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Audio level")
        .accessibilityValue(LiveAudiogramRing.isSilent(feed.ring.latest) ? "Silent" : "Sound")
    }
}

/// The rail's Meetings badge while recording: the red dot, a small level glyph (live for a Mac recording, still for the
/// glasses) and the elapsed time, on its own one-second clock.
struct LiveRailBadge: View {
    let start: Date?
    let mac: Bool
    var body: some View {
        HStack(spacing: 4) {
            LiveDot(size: 6)
            if mac { LiveLevelGlyph(feed: LiveAudiogramFeed.live) } else { LiveLevelGlyph(feed: nil) }
            if let start {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(LiveMeeting.elapsed(context.date.timeIntervalSince(start))).font(COSType.mono(10)).monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Meeting recording now")
    }
}

/// Three small bars: the latest levels of a Mac recording, or a still glyph for the glasses (no level reaches the Mac).
struct LiveLevelGlyph: View {
    let feed: LiveAudiogramFeed?
    var body: some View {
        if let feed { LiveLevelBars(feed: feed) } else { Self.bars([0.45, 0.8, 0.55]) }
    }
    static func bars(_ levels: [Double]) -> some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule().fill(COSPalette.live.opacity(0.85)).frame(width: 2, height: 3 + 7 * min(1, max(0, level)))
            }
        }
        .frame(height: 10)
    }
}

struct LiveLevelBars: View {
    @ObservedObject var feed: LiveAudiogramFeed
    var body: some View { LiveLevelGlyph.bars(Array(feed.ring.levels.suffix(3))) }
}

/// The bottom bar while the meeting records (0.5.339, the approved mock): the red dot, the elapsed time on its own
/// one-second clock, the meter, Add file and Stop. The meter is the Mac recording's audiogram, the glasses meeting's level
/// strip on a 6.87.0 server, else the still glyph. Widths follow LiveRecordingBarLayout: the meter shrinks first (its
/// oldest samples clipped) to 40 pt, Add file goes icon-only under 560 pt, the still glyph takes the meter's place under
/// 340 pt, and the buttons never wrap.
struct LiveRecordingBar<Add: View, Stop: View>: View {
    let start: Date?
    let mac: Bool
    /// A glasses meeting on a server that keeps chunk levels.
    var levelStrip = false
    var sessionId: String? = nil
    @ViewBuilder let add: (_ labelled: Bool) -> Add
    @ViewBuilder let stop: () -> Stop

    static var height: CGFloat { 50 }

    var body: some View {
        GeometryReader { geometry in
            let mode = LiveRecordingBarLayout.mode(barWidth: geometry.size.width)
            HStack(spacing: 10) {
                LiveDot(size: 9)
                Group {
                    if let start {
                        TimelineView(.periodic(from: start, by: 1)) { context in
                            Text(LiveMeeting.elapsed(context.date.timeIntervalSince(start)))
                                .font(COSType.mono(12.5, weight: .medium)).monospacedDigit()
                        }
                    } else {
                        Text("Starting").font(COSType.body(12)).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1).fixedSize()
                meter(mode)
                add(mode.addFileLabelled).fixedSize()
                stop().lineLimit(1).fixedSize()
            }
            .padding(.leading, 14).padding(.trailing, 8)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
        }
        .frame(height: Self.height)
        .background(COSPalette.raised.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(COSPalette.line))
    }

    @ViewBuilder
    private func meter(_ mode: LiveRecordingBarLayout.Mode) -> some View {
        if mode.meter && mac {
            LiveAudiogramView(feed: .live).frame(minWidth: LiveRecordingBarLayout.meterFloor, maxWidth: .infinity)
        } else if mode.meter && levelStrip, let sessionId {
            LiveChunkLevelStripView(feed: .live, sessionId: sessionId).frame(minWidth: LiveRecordingBarLayout.meterFloor, maxWidth: .infinity)
        } else {
            LiveLevelGlyph(feed: nil).accessibilityHidden(true)
            Spacer(minLength: 0)
        }
    }
}

/// The meter's left edge fades out, so clipped history reads as older, not cut.
struct LiveMeterFade: View {
    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 28)
            Color.black
        }
    }
}

/// The glasses meeting's chunk levels (server 6.87.0), from the live transcript read. The DictationMeterFeed and
/// LiveAudiogramFeed pattern: its own object, observed only by the strip, never ControllerModel's published state. One
/// session at a time (the open one); in memory only, two numbers a chunk.
@MainActor final class LiveChunkLevelFeed: ObservableObject {
    static let live = LiveChunkLevelFeed()
    @Published private(set) var sessionId: String?
    @Published private(set) var levels: [LiveChunkLevel] = []
    func set(_ sessionId: String, _ levels: [LiveChunkLevel]) {
        if self.sessionId != sessionId { self.sessionId = sessionId }
        if self.levels != levels { self.levels = levels }
    }
    func clear() { if sessionId != nil { sessionId = nil }; if !levels.isEmpty { levels = [] } }
    func levels(for sessionId: String) -> [LiveChunkLevel] { self.sessionId == sessionId ? levels : [] }
}

/// The coarse strip for a glasses meeting: one bar per chunk, newest at the right, dotted where the chunk held almost no
/// speech, the oldest clipped first when narrow. It trails the room by a chunk, which VoiceOver says. Reduce Motion: a
/// static level bar of the newest chunk. No levels yet: the still glyph.
struct LiveChunkLevelStripView: View {
    @ObservedObject var feed: LiveChunkLevelFeed
    let sessionId: String
    var height: CGFloat = 22
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let levels = feed.levels(for: sessionId)
        Group {
            if levels.isEmpty {
                HStack(spacing: 0) { LiveLevelGlyph(feed: nil); Spacer(minLength: 0) }.frame(height: height)
            } else if reduceMotion {
                GeometryReader { geometry in
                    let latest = levels.last.map { LiveLevelStrip.isSilent($0) ? 0 : $0.level } ?? 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(COSPalette.line)
                        Capsule().fill(COSPalette.accent).frame(width: max(2, geometry.size.width * latest))
                    }
                }
                .frame(height: 4)
                .frame(height: height)
            } else {
                Canvas { context, size in
                    let shown = LiveLevelStrip.visible(levels, width: Double(size.width))
                    let step = CGFloat(LiveLevelStrip.step)
                    let mid = size.height / 2
                    for (back, level) in shown.reversed().enumerated() {
                        let x = size.width - (CGFloat(back) + 0.5) * step
                        if LiveLevelStrip.isSilent(level) {
                            context.fill(Path(ellipseIn: CGRect(x: x - 1, y: mid - 1, width: 2, height: 2)), with: .color(COSPalette.muted.opacity(0.7)))
                        } else {
                            let h = max(3, CGFloat(level.level) * size.height)
                            context.fill(Path(roundedRect: CGRect(x: x - 1.5, y: mid - h / 2, width: 3, height: h), cornerRadius: 1.5),
                                         with: .color(COSPalette.accent.opacity(0.8)))
                        }
                    }
                }
                .frame(height: height)
                .mask(LiveMeterFade())
            }
        }
        .accessibilityElement()
        .accessibilityLabel(LiveLevelStrip.accessibilityLabel)
        .accessibilityValue(LiveLevelStrip.accessibilityValue(levels))
    }
}

/// The bar's Add file button: a paperclip and "Add file", or the paperclip alone under 560 pt (VoiceOver still reads
/// "Add file"). It opens an inline menu above it: Paste screenshot (Command-V) and Choose files… (Command-O). Command-O
/// works while the button shows; Command-V is the live pane's own paste, so a text field keeps its paste.
struct LiveAddFileButton: View {
    let labelled: Bool
    @Binding var open: Bool
    let paste: () -> Void
    let choose: () -> Void

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "paperclip").font(.system(size: 12, weight: .semibold))
                if labelled { Text(LiveRecordingBarLayout.addFileLabel).lineLimit(1) }
            }
            .frame(minWidth: labelled ? nil : 18)
        }
        .buttonStyle(COSQuietButtonStyle())
        .accessibilityLabel(LiveRecordingBarLayout.addFileLabel)
        .help("Add a screenshot or files to this meeting")
        .overlay(alignment: .bottomTrailing) {
            if open {
                LiveAddFileMenu(paste: paste, choose: choose)
                    .offset(y: -40)
                    .transition(.opacity)
            }
        }
        .background {
            // Command-O, and Escape while the menu is open. Hidden buttons: window key equivalents that no text field uses.
            Button("") { choose() }.keyboardShortcut("o", modifiers: .command).opacity(0).allowsHitTesting(false).accessibilityHidden(true)
            if open {
                Button("") { open = false }.keyboardShortcut(.cancelAction).opacity(0).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}

/// The two rows of the Add file menu, each with its shortcut at the right.
struct LiveAddFileMenu: View {
    let paste: () -> Void
    let choose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row(LiveMeetingFiles.pasteLabel, symbol: "doc.on.clipboard", keys: "\u{2318}V", action: paste)
            row(LiveMeetingFiles.chooseLabel, symbol: "folder", keys: "\u{2318}O", action: choose)
        }
        .padding(5)
        .frame(width: 224)
        .background(COSPalette.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(COSPalette.line))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
        .fixedSize()
    }

    private func row(_ title: String, symbol: String, keys: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                Text(keys).font(COSType.mono(11.5)).foregroundStyle(COSPalette.muted)
            }
            .font(COSType.body(13))
            .padding(.horizontal, 9).frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// While a file is dragged over the live pane: a light outline on the transcript and where the file goes.
struct LiveFilesDropOutline: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(COSPalette.gold.opacity(0.55), lineWidth: 2)
            .background(COSPalette.gold.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                Label(LiveMeetingFiles.dropLabel, systemImage: "paperclip")
                    .font(COSType.body(14, weight: .semibold))
                    .foregroundStyle(COSPalette.accent)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(COSPalette.panel, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(COSPalette.gold.opacity(0.35)))
            }
            .padding(6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The live pane's one Files row (0.5.339): "Files · 2", the total size and a chevron. Open, the files with Quick Look,
/// Show in Finder and Remove, any Undo still offered, and the note. Hidden with no files. No drop strip and no buttons of
/// its own. A drop's or a paste's flash and any error show under it, open or not, so an add is never silent.
struct LiveMeetingFilesRow: View {
    @ObservedObject var files: WorkCardFileStore
    let key: String
    let info: WorkMeetingInfo
    @Binding var open: Bool
    @State private var preview: URL?

    var body: some View {
        let shown = files.meetingFiles(keys: [key])
        let id = WorkCardFiles.meetingID(forKey: key)
        let undo = id.map { files.recentlyRemoved(for: $0) } ?? []
        VStack(alignment: .leading, spacing: 6) {
            if LiveMeetingFiles.showsRow(count: shown.count, pendingUndo: undo.count) {
                VStack(alignment: .leading, spacing: 0) {
                    Button { open.toggle() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "paperclip").font(.system(size: 11, weight: .semibold)).foregroundStyle(COSPalette.muted)
                            Text(LiveMeetingFiles.rowTitle(count: shown.count)).font(COSType.body(12.5, weight: .semibold))
                            Spacer(minLength: 6)
                            Text(WorkCardFiles.sizeText(shown.filter { !$0.file.isLink }.reduce(0) { $0 + $1.file.bytes }))
                                .font(COSType.mono(11)).foregroundStyle(COSPalette.muted)
                            Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(COSPalette.muted)
                        }
                        .padding(.horizontal, 12).frame(height: 34)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(LiveMeetingFiles.rowTitle(count: shown.count))
                    .accessibilityValue(open ? "Open" : "Closed")
                    if open {
                        Divider().overlay(COSPalette.line)
                        ForEach(shown, id: \.file.id) { entry in
                            MeetingFileRow(files: files, file: entry.file, folder: entry.folder, id: entry.id, removable: true, preview: $preview)
                            Divider().overlay(COSPalette.line)
                        }
                        if let id {
                            ForEach(undo) { file in
                                HStack(spacing: 8) {
                                    Text("Removed \u{201C}\(file.display)\u{201D}.").lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 6)
                                    Button("Undo") { files.undoRemove(file.id, workID: id) }.buttonStyle(COSTextButtonStyle())
                                }.font(COSType.body(11)).foregroundStyle(COSPalette.muted).padding(.horizontal, 10).padding(.vertical, 6)
                                Divider().overlay(COSPalette.line)
                            }
                        }
                        Text(LiveMeetingFiles.note).font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
                    }
                }
                .background(COSPalette.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(COSPalette.line))
            }
            if let id { WorkCardFlashView(files: files, workID: id) }
            if let error = files.error { Text(error).font(COSType.body(11)).foregroundStyle(COSPalette.danger) }
        }
        .quickLookPreview($preview)
        .task(id: key) { files.loadIfNeeded(); files.noteMeeting(keys: [key], info: info) }
    }
}

/// The voices heard so far: initials and names, a small bar under the one heard last (it trails the room by 5 to 10 s,
/// as the transcript does). Still under Reduce Motion; otherwise the bar breathes.
struct LiveParticipantStrip: View {
    let people: [LiveMeetingParticipant]
    let lastHeard: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(people) { person in
                    let last = person.id == lastHeard
                    HStack(spacing: 7) {
                        Text(verbatim: person.initials)
                            .font(COSType.body(10.5, weight: .semibold))
                            .foregroundStyle(person.unidentified ? COSPalette.muted : COSPalette.ink)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(person.unidentified ? COSPalette.raised : COSPalette.gold.opacity(0.55)))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: person.name).font(COSType.body(11.5, weight: last ? .semibold : .regular))
                                .foregroundStyle(last ? .primary : .secondary).lineLimit(1)
                            if last { LiveLastHeardBar(still: reduceMotion) }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(last ? person.name + ", heard last" : person.name)
                }
            }
            .padding(.horizontal, 24)
        }
        .frame(height: 34)
    }
}

/// "Last heard": a short accent bar under the name. Breathes slowly unless Reduce Motion is on, then it is still.
struct LiveLastHeardBar: View {
    let still: Bool
    @State private var dim = false
    var body: some View {
        Capsule().fill(COSPalette.accent)
            .frame(width: 18, height: 2.5)
            .opacity(still ? 1 : (dim ? 0.45 : 1))
            .onAppear {
                guard !still else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
            }
            .help("Heard last. Names arrive with the text, a few seconds after they speak.")
    }
}

/// One cue under the turn it belongs to: its kind as the line's lead word (a plain cue for a kind this build does not
/// know), the cue, and the five verdicts, or the verdict it has with Change.
struct LiveInlineCueRow: View {
    let cue: LiveCueRecord
    let saving: Bool
    let error: String?
    let rate: (CueVerdict) -> Void
    @State private var changing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Group {
                if let label = LiveMeeting.kindLabel(cue.kind) {
                    Text(label + "  ").font(COSType.body(12.5, weight: .semibold)).foregroundColor(COSPalette.accent)
                        + Text(verbatim: cue.detail).font(COSType.body(13))
                } else {
                    Text(verbatim: cue.detail).font(COSType.body(13))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            if let rated = CueVerdicts.ratedLine(cue.rating), !changing {
                HStack(spacing: 8) {
                    Text(rated).font(COSType.body(11, weight: .medium)).foregroundStyle(COSPalette.accent)
                    Button("Change") { changing = true }.buttonStyle(COSTextButtonStyle())
                }
            } else {
                CueVerdictButtons(selected: cue.verdict, disabled: saving) { verdict in
                    changing = false
                    if verdict != cue.verdict { rate(verdict) }
                }
                .controlSize(.small)
            }
            if let error { Text(error).font(COSType.body(11)).foregroundStyle(COSPalette.amber).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.leading, 12)
        .padding(.vertical, 4)
        .overlay(alignment: .leading) { Rectangle().fill(COSPalette.accent.opacity(0.55)).frame(width: 2) }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The grey line: the newest words still being transcribed, below the last turn, replaced by the final text. Its own
/// view on its own object, so a new preview redraws only this.
struct LiveProvisionalLineView: View {
    @ObservedObject var feed: LiveProvisionalFeed
    let sessionId: String
    let lastFinalChunk: Int
    let changed: () -> Void

    var body: some View {
        let text = LiveMeeting.visibleProvisional(feed.lines[sessionId], lastFinalChunk: lastFinalChunk)
        Group {
            if let text {
                Text(verbatim: text)
                    .font(COSType.body(14))
                    .lineSpacing(4)
                    .foregroundStyle(COSPalette.muted.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Still transcribing")
                    .accessibilityValue(text)
            }
        }
        .onChange(of: text) { _, _ in changed() }
    }
}

// Live COS Ask: durable state and presentation live in MeetingAsk.swift.
