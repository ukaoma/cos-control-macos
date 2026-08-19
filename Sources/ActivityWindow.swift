import AppKit
import SwiftUI

/// Click-only host for Activity on every supported macOS release.
///
/// SwiftUI's `defaultLaunchBehavior(.suppressed)` begins at macOS 15, while
/// COS Control supports macOS 14. A retained AppKit window keeps Activity from
/// appearing at login and preserves its navigation state when the user closes
/// and reopens it from the menu-bar console.
@MainActor
final class ActivityWindowPresenter: NSObject, ObservableObject, NSWindowDelegate {
    private var windowController: NSWindowController?
    private weak var model: ControllerModel?

    func show(model: ControllerModel) {
        if let window = windowController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: ActivityWindow(model: model))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "COS Activity"
        window.setContentSize(NSSize(width: 920, height: 680))
        window.minSize = NSSize(width: 760, height: 560)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("COSActivityWindow")
        window.center()

        let controller = NSWindowController(window: window)
        self.model = model
        windowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        model?.closeMediaPreview()
        model?.closeSpeakerReview()
        model?.closeContextDetail()
        model?.closeLibraryDetail()
        windowController = nil
    }
}

enum ActivitySection: String, CaseIterable, Identifiable {
    case messages
    case speakers
    case meetings
    case memories
    case threads
    case sessions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .messages: "Messages"
        case .speakers: "Speakers"
        case .meetings: "Meetings"
        case .memories: "Memories"
        case .threads: "Threads"
        case .sessions: "Sessions"
        }
    }

    var icon: String {
        switch self {
        case .messages: "message"
        case .speakers: "waveform"
        case .meetings: "calendar"
        case .memories: "sparkles"
        case .threads: "point.3.connected.trianglepath.dotted"
        case .sessions: "terminal"
        }
    }

    var tint: Color {
        switch self {
        case .messages: Color(red: 0.24, green: 0.48, blue: 0.78)
        case .speakers: Color(red: 0.78, green: 0.34, blue: 0.39)
        case .meetings: Color(red: 0.82, green: 0.52, blue: 0.22)
        case .memories: Color(red: 0.48, green: 0.36, blue: 0.72)
        case .threads: Color(red: 0.22, green: 0.57, blue: 0.39)
        case .sessions: Color(red: 0.36, green: 0.36, blue: 0.40)
        }
    }

    var summary: String {
        switch self {
        case .messages: "Questions, answers, and image context from your glasses."
        case .speakers: "See enrolled voices, match quality, appearances, and meetings to review."
        case .meetings: "Browse saved calls by day, with transcript, summary, and copy."
        case .memories: "Browse the durable context your COS can recall."
        case .threads: "Follow work that develops across meetings and time."
        case .sessions: "Claude, Codex, and Cursor sessions on this Mac."
        }
    }
}


private enum SpeakerSubview: String, CaseIterable, Identifiable {
    case voices
    case meetings

    var id: String { rawValue }
    var title: String { self == .voices ? "Voices" : "Meetings to review" }
}

private enum VoiceDirectorySort: String, CaseIterable, Identifiable {
    case attention
    case recent
    case meetings
    case name

    var id: String { rawValue }
    var title: String {
        switch self {
        case .attention: "Needs attention"
        case .recent: "Recently heard"
        case .meetings: "Most meetings"
        case .name: "Name"
        }
    }
}

/// Persistent activity browser for the review surfaces.
///
/// Navigation is deliberately window-local. The controller owns data and
/// mutations; this view owns where the user is. That keeps opening a record here
/// from silently replacing the 390pt menu-bar console when it is opened later.
struct ActivityWindow: View {
    @ObservedObject var model: ControllerModel
    @State private var section: ActivitySection?
    @State private var selectedTurnID: String?
    @State private var selectedSpeakerSessionID: String?
    @State private var selectedVoiceName: String?
    @State private var voiceParentName: String?
    @State private var speakerSubview: SpeakerSubview = .voices
    @State private var voiceSearch = ""
    @State private var voiceSort: VoiceDirectorySort = .attention
    @State private var selectedContextID: String?
    @State private var selectedLibraryRecordID: String?
    @State private var selectedSessionID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedTurn: GlassesTurn? {
        guard let selectedTurnID else { return nil }
        return model.recentMessages.first { $0.id == selectedTurnID }
    }

    private var selectedVoice: VoiceDirectoryPerson? {
        guard let selectedVoiceName else { return nil }
        return model.voiceDirectory.first { $0.name == selectedVoiceName }
    }

    private var visibleVoices: [VoiceDirectoryPerson] {
        let needle = voiceSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = needle.isEmpty
            ? model.voiceDirectory
            : model.voiceDirectory.filter { person in
                person.name.lowercased().contains(needle)
                    || person.sources.keys.contains { $0.lowercased().contains(needle) }
            }
        return filtered.sorted { a, b in
            switch voiceSort {
            case .attention:
                if a.needsAttention != b.needsAttention { return a.needsAttention && !b.needsAttention }
                if a.reviewMeetingCount != b.reviewMeetingCount { return a.reviewMeetingCount > b.reviewMeetingCount }
                if a.meetingCount != b.meetingCount { return a.meetingCount > b.meetingCount }
            case .recent:
                if (a.lastSeen ?? "") != (b.lastSeen ?? "") { return (a.lastSeen ?? "") > (b.lastSeen ?? "") }
            case .meetings:
                if a.meetingCount != b.meetingCount { return a.meetingCount > b.meetingCount }
            case .name:
                break
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private var hasDetail: Bool {
        switch section {
        case .messages: model.selectedMediaPreview != nil || selectedTurnID != nil
        case .speakers: selectedVoiceName != nil || selectedSpeakerSessionID != nil
        case .meetings: selectedLibraryRecordID != nil
        case .memories, .threads: selectedContextID != nil
        case .sessions: selectedSessionID != nil
        case nil: false
        }
    }

    private var canGoBack: Bool { section != nil || hasDetail }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            lensRail
            Divider()
            Group {
                if section == .messages, let preview = model.selectedMediaPreview {
                    mediaDetail(preview)
                } else if section == .messages, let selectedTurn {
                    messageDetail(selectedTurn)
                } else if section == .speakers, let selectedVoice {
                    voiceDirectoryDetail(selectedVoice)
                } else if section == .speakers, selectedSpeakerSessionID != nil {
                    if model.reviewRouteActive {
                        SpeakerReviewPane(model: model, showsBackButton: false)
                    } else {
                        centeredProgress("Loading meeting…")
                    }
                } else if (section == .memories || section == .threads), selectedContextID != nil {
                    if model.contextRouteActive {
                        ContextDetailPane(model: model, showsBackButton: false)
                    } else {
                        centeredProgress("Loading record…")
                    }
                } else if section == .meetings, selectedLibraryRecordID != nil {
                    if model.libraryRouteActive {
                        MeetingLibraryDetailPane(model: model, onReviewVoices: openVoiceReviewFromLibrary)
                    } else {
                        centeredProgress("Loading meeting…")
                    }
                } else if section == .sessions, selectedSessionID != nil {
                    if model.claudeSessionRouteActive {
                        ClaudeSessionDetailPane(model: model)
                    } else {
                        centeredProgress("Loading session…")
                    }
                } else if let section {
                    sectionList(section)
                } else {
                    activityHome
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 560)
        .font(COSType.body(13))
        .background(COSPalette.panel)
        .task { await loadOverviewIfNeeded() }
        .alert("COS Control", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
        .onExitCommand { goBack() }
    }

    // MARK: - Navigation

    private var navigationBar: some View {
        HStack(spacing: 10) {
            COSLockupView(height: 12)
                .foregroundStyle(COSPalette.ink)
            Button { goHome() } label: {
                Label("Home", systemImage: "house")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .help("Activity home")

            Button { goBack() } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .disabled(!canGoBack)
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .help("Go back one step")

            breadcrumb
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(model.status.running ? COSPalette.green : COSPalette.amber)
                    .frame(width: 7, height: 7)
                Text(model.status.running ? "Server connected" : "Server offline")
                    .font(COSType.mono(10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(COSPalette.card.opacity(0.72))
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Text("COS Control")
                .font(COSType.body(11, weight: .semibold))
            if let section {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(section.title)
                    .font(.system(size: 11, weight: hasDetail ? .regular : .semibold))
                    .foregroundStyle(hasDetail ? .secondary : .primary)
            }
            if let detailTitle {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(detailTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 4)
    }

    private var detailTitle: String? {
        if section == .messages, let preview = model.selectedMediaPreview {
            return preview.attachment.displayLabel
        }
        if section == .messages, let turn = selectedTurn {
            return turn.no.map { "Message #\($0)" } ?? "Message"
        }
        if section == .speakers, selectedVoiceName != nil { return selectedVoiceName }
        if section == .speakers, selectedSpeakerSessionID != nil {
            if let review = model.openReview, review.sessionId == selectedSpeakerSessionID { return review.title }
            if model.reviewLoading { return "Loading meeting" }
        }
        if section == .meetings, selectedLibraryRecordID != nil {
            if let row = model.openLibraryRow, row.id == selectedLibraryRecordID { return row.title }
            if model.libraryDetailLoading { return "Loading meeting" }
        }
        if section == .sessions, selectedSessionID != nil {
            if let detail = model.claudeSessionDetail { return detail.title }
            if let row = model.openClaudeRow, row.id == selectedSessionID { return row.title }
            if model.claudeSessionDetailLoading { return "Loading session" }
        }
        if (section == .memories || section == .threads),
           selectedContextID != nil,
           let context = model.contextDetail,
           context.id == selectedContextID {
            return context.title
        }
        if (section == .memories || section == .threads), selectedContextID != nil, model.contextDetailLoading {
            return "Loading record"
        }
        return nil
    }

    /// The peer tabs form one continuous lens rail. Color identifies the data
    /// surface; position and label carry the navigation meaning.
    private var lensRail: some View {
        HStack(spacing: 6) {
            ForEach(Array(ActivitySection.allCases.enumerated()), id: \.element.id) { index, item in
                Button {
                    select(item)
                } label: {
                    VStack(spacing: 7) {
                        HStack(spacing: 7) {
                            Image(systemName: item.icon)
                            Text(item.title)
                        }
                        .font(.system(size: 11.5, weight: section == item ? .semibold : .medium))
                        .foregroundStyle(section == item ? .primary : .secondary)
                        Capsule()
                            .fill(section == item ? item.tint : Color.clear)
                            .frame(height: 3)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .accessibilityLabel("Open \(item.title)")
                .accessibilityValue(section == item ? "Selected" : "Not selected")
                .accessibilityAddTraits(section == item ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .background(COSPalette.card.opacity(0.50))
    }

    private func select(_ next: ActivitySection) {
        clearDetail()
        withOptionalAnimation { section = next }
        Task { await load(next) }
    }

    private func goHome() {
        clearDetail()
        withOptionalAnimation { section = nil }
    }

    private func goBack() {
        if section == .messages, model.selectedMediaPreview != nil {
            model.closeMediaPreview()
        } else if section == .messages, selectedTurnID != nil {
            selectedTurnID = nil
        } else if section == .speakers, selectedVoiceName != nil {
            selectedVoiceName = nil
        } else if section == .speakers, selectedSpeakerSessionID != nil {
            selectedSpeakerSessionID = nil
            model.closeSpeakerReview()
            if let parent = voiceParentName {
                selectedVoiceName = parent
                voiceParentName = nil
            }
        } else if (section == .memories || section == .threads), selectedContextID != nil {
            selectedContextID = nil
            model.closeContextDetail()
        } else if section == .meetings, selectedLibraryRecordID != nil {
            selectedLibraryRecordID = nil
            model.closeLibraryDetail()
        } else if section == .sessions, selectedSessionID != nil {
            selectedSessionID = nil
            model.closeClaudeSession()
        } else {
            withOptionalAnimation { section = nil }
        }
    }

    private func clearDetail() {
        model.closeMediaPreview()
        selectedTurnID = nil
        selectedVoiceName = nil
        voiceParentName = nil
        selectedSpeakerSessionID = nil
        selectedContextID = nil
        selectedLibraryRecordID = nil
        selectedSessionID = nil
        model.closeSpeakerReview()
        model.closeContextDetail()
        model.closeLibraryDetail()
        model.closeClaudeSession()
    }

    private func withOptionalAnimation(_ changes: () -> Void) {
        if reduceMotion { changes() }
        else { withAnimation(.easeOut(duration: 0.16), changes) }
    }

    // MARK: - Home

    private var activityHome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 12) {
                    COSLockupView(height: 17)
                        .foregroundStyle(COSPalette.ink)
                    Spacer()
                    COSGotcosCaption(size: 12)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Activity")
                        .font(COSType.display(28, weight: .medium))
                    Text("Six views into the work your COS already holds.")
                        .font(COSType.display(13, italic: true))
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 14) {
                    ForEach(ActivitySection.allCases) { item in
                        Button { select(item) } label: {
                            activityHomeCard(item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func activityHomeCard(_ item: ActivitySection) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(item.tint.opacity(0.13))
                    Image(systemName: item.icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(item.tint)
                }
                .frame(width: 42, height: 42)
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(item.tint)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(COSType.body(16, weight: .semibold))
                Text(item.summary)
                    .font(COSType.body(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(homeStat(item))
                .font(COSType.mono(10.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
        .padding(18)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(item.tint)
                .frame(width: 3)
                .padding(.vertical, 15)
        }
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(COSPalette.line, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    private func homeStat(_ item: ActivitySection) -> String {
        switch item {
        case .messages:
            return model.recentMessages.isEmpty ? "Refresh to load" : "\(model.recentMessages.count) recent"
        case .speakers:
            return model.voiceDirectory.isEmpty ? "Refresh to load" : "\(model.voiceDirectory.count) enrolled voices"
        case .meetings:
            if !model.libraryMeetings.isEmpty {
                return "\(model.libraryMeetings.count) in \(MeetingMonth.title(model.libraryMonth))"
            }
            if model.status.meetingLibraryCount > 0 {
                return "\(model.status.meetingLibraryCount) stored"
            }
            return "Browse by day"
        case .memories:
            return model.status.memoryAvailable == true
                ? (model.memoryHeadline.isEmpty ? "Ready" : model.memoryHeadline)
                : "Setup needed"
        case .threads:
            return model.status.threadsAvailable == true
                ? (model.threadHeadline.isEmpty ? "Ready" : model.threadHeadline)
                : "Setup needed"
        case .sessions:
            if model.claudeSessions.isEmpty { return "Refresh to load" }
            return "\(model.claudeSessions.count) session(s)"
        }
    }

    // MARK: - Lists

    @ViewBuilder
    private func sectionList(_ item: ActivitySection) -> some View {
        switch item {
        case .messages: messagesList
        case .speakers: speakersList
        case .meetings: meetingsList
        case .memories: contextList(kind: "memory")
        case .threads: contextList(kind: "thread")
        case .sessions: sessionsList
        }
    }

    private var meetingsList: some View {
        VStack(spacing: 0) {
            sectionHeader(
                section: .meetings,
                title: "Meetings",
                detail: model.isLibraryQueryActive
                    ? (model.librarySearching ? "Looking up…" : "Lookup across stored calls")
                    : (model.libraryLoading
                        ? "Loading…"
                        : (model.libraryError ?? "Saved calls by day · transcript and summary")),
                refresh: { Task { await model.loadLibraryMeetings() } },
                refreshDisabled: model.libraryLoading
            )
            MeetingLibraryBody(model: model) { meeting in
                selectedLibraryRecordID = meeting.id
                model.openLibraryMeeting(meeting)
            }
        }
    }

    private var sessionsList: some View {
        VStack(spacing: 0) {
            sectionHeader(
                section: .sessions,
                title: "Sessions",
                detail: sessionsStatus,
                refresh: { Task { await model.loadClaudeSessions() } },
                refreshDisabled: model.claudeSessionsLoading,
                accessory: {
                    if !model.isSessionQueryActive {
                        Picker("Clock", selection: $model.sessionClock) {
                            ForEach(SessionClock.allCases) { clock in
                                Text(clock.title).tag(clock)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 278)
                        .labelsHidden()
                    }
                }
            )
            sessionsSearchBar
            if model.isSessionQueryActive {
                sessionsSearchResults
            } else if model.claudeSessionsLoading && visibleSessions.isEmpty {
                centeredProgress("Loading sessions…")
            } else if let error = model.claudeSessionsError, visibleSessions.isEmpty {
                emptyState(.sessions, text: error)
            } else if visibleSessions.isEmpty {
                emptyState(.sessions, text: sessionsEmptyCopy)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleSessions) { session in
                            sessionRow(session)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 22)
                }
            }
        }
    }

    private var sessionsSearchBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search titles, transcripts…", text: $model.sessionQuery)
                        .textFieldStyle(.plain)
                    if !model.sessionQuery.isEmpty {
                        Button {
                            model.sessionQuery = ""
                            model.scheduleSessionSearch()
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
                Picker("Recency", selection: $model.searchRecency) {
                    ForEach(SearchRecency.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 150)
                .accessibilityLabel("Recency")
                Spacer()
            }
            if model.isSessionQueryActive, !model.sessionSemanticAvailable {
                Text(sessionSemanticHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
        .onChange(of: model.sessionQuery) { _, _ in model.scheduleSessionSearch() }
    }

    private var sessionSemanticHint: String {
        let reason = model.sessionSemanticReason ?? ""
        // These used to arrive as one string. A slow server, an unreachable one, a
        // missing token and a genuinely old build all reported "server_too_old", which
        // sent you looking for an update that was not the problem.
        if reason.hasPrefix("server_error_") {
            return "Keyword only — the server returned \(reason.dropFirst("server_error_".count))"
        }
        switch reason {
        case "server_too_old":
            return "Keyword only — meaning search needs a server update"
        case "server_unreachable":
            return "Keyword only — the server did not answer in time"
        case "no_server_token":
            return "Keyword only — no server token available"
        case "no_session_embeddings", "embeddings_unreachable":
            return "Keyword only — meaning search needs an OpenAI key"
        default:
            return "Keyword only — meaning search is unavailable"
        }
    }

    @ViewBuilder
    private var sessionsSearchResults: some View {
        if model.sessionSearching && model.sessionSearchHits.isEmpty && model.sessionSearchError == nil {
            centeredProgress("Looking up…")
        } else if let error = model.sessionSearchError, model.sessionSearchHits.isEmpty {
            emptyState(.sessions, text: error)
        } else if model.sessionSearchHits.isEmpty {
            emptyState(.sessions, text: "No sessions match that lookup.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.visibleSessionSearchHits) { hit in
                        sessionRow(hit.session, snippet: hit.snippet, matchLabel: hit.matchLabel)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
            }
        }
    }

    private var visibleSessions: [ClaudeSession] {
        let window: TimeInterval = 7 * 24 * 3600
        let now = Date()
        let real = model.claudeSessions.filter { !$0.isKeepWarm }
        switch model.sessionClock {
        case .updated:
            return real.sorted { $0.updatedAt > $1.updatedAt }
        case .opened:
            return real.filter { session in
                if session.alive { return true }
                guard let stamp = session.createdDate ?? session.updatedDate else { return false }
                return now.timeIntervalSince(stamp) <= window
            }.sorted {
                ($0.createdAt) > ($1.createdAt)
            }
        case .pinned:
            return real.filter(\.pinned).sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    /// Titles that appear more than once on screen right now.
    ///
    /// A Claude fork is `claude -p --resume <id> --fork-session`, which inherits the
    /// parent's history — so `firstClaudeUserTitle` derives the SAME title and the fork
    /// renders as a second row with an identical name, workspace and state. Measured
    /// 2026-08-18: two live sessions both titled "COS-glasses Server work (meetings)"
    /// with distinct ids (31732572… and a4b2b4dd…), and 8 duplicate-title groups across
    /// 69 rows. Miles: "I forked that COS glass server work, and now I can't see any of
    /// the forks. I do see the original running, though." They were never missing; there
    /// was nothing on the row to tell them apart.
    ///
    /// Unions BOTH surfaces because `sessionRow` is shared by the list and by search.
    /// Over-inclusion is harmless: showing when a session was opened is never wrong.
    private var ambiguousSessionTitles: Set<String> {
        ClaudeSession.ambiguousTitles(
            in: visibleSessions + model.visibleSessionSearchHits.map(\.session)
        )
    }

    private var sessionsEmptyCopy: String {
        switch model.sessionClock {
        case .updated:
            if let summary = model.sessionListDropped.summary, model.sessionListDropped.age > 0 {
                return "No sessions updated on this Mac in the last 7 days. \(summary.replacingOccurrences(of: " not shown", with: " — search to find them."))"
            }
            return "No Claude, Codex, or Cursor sessions updated on this Mac in the last 7 days."
        case .opened:
            return "No sessions opened in the last 7 days. Pins are under Pinned."
        case .pinned:
            return "No pinned sessions. Star Claude Desktop chats, pin Cursor chats, or pin Codex/ChatGPT threads to see them here."
        }
    }

    private func sessionClockHint(_ session: ClaudeSession) -> String? {
        session.clockHint(clock: model.sessionClock)
    }

    private func sessionRow(_ session: ClaudeSession, snippet: String = "", matchLabel: String? = nil) -> some View {
        VStack(spacing: 0) {
            Button {
                selectedSessionID = session.id
                model.openClaudeSession(session)
            } label: {
                HStack(spacing: 13) {
                    providerGlyph(session.provider)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        if !snippet.isEmpty {
                            Text(snippet)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        HStack(spacing: 8) {
                            providerBadge(session)
                            if session.pinned {
                                Text("PINNED")
                                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                    .tracking(0.6)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                            }
                            if session.showsStateChip {
                                Text(session.stateLabel)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(sessionStateTint(session.state))
                            }
                            if let hint = sessionClockHint(session) {
                                Text(hint)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            // Two rows with the same name are almost always a fork and
                            // its parent. The updated clock now always prints a real
                            // date, but two forks can share that date too. Show when
                            // each was opened — the one field that actually differs.
                            if ambiguousSessionTitles.contains(
                                session.title.trimmingCharacters(in: .whitespacesAndNewlines)
                            ), let opened = session.createdDate {
                                Text("Opened \(ClaudeSession.shortSessionDate(opened))")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(COSPalette.amber)
                                    .lineLimit(1)
                                    .help("Another session on screen has the same name. This one was opened \(ClaudeSession.shortSessionDate(opened)).")
                            }
                            if !session.workspace.isEmpty, session.workspace != session.title {
                                Text(session.workspace)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if !session.waitingFor.isEmpty {
                                Text(session.waitingFor)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer()
                    if let matchLabel {
                        Text(matchLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(ActivitySection.sessions.tint.opacity(0.16)))
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 46)
        }
    }

    private var sessionsStatus: String {
        if model.isSessionQueryActive {
            if model.sessionSearching { return "Looking up…" }
            return "Lookup across Claude, Codex, and Cursor"
        }
        if model.claudeSessionsLoading { return "Loading…" }
        if let error = model.claudeSessionsError { return error }
        if visibleSessions.isEmpty { return "No sessions" }
        switch model.sessionClock {
        case .updated:
            if let summary = model.sessionListDropped.summary {
                return "Last 7 days · \(summary)"
            }
            return "Claude · Codex · Cursor · updated in last 7 days"
        case .opened:
            return "Claude · Codex · Cursor · opened in last 7 days"
        case .pinned:
            return "Claude · Codex · Cursor · pinned"
        }
    }

    private func sessionStateTint(_ state: String) -> Color {
        switch state {
        case "waiting": COSPalette.amber
        case "running": Color(red: 0.22, green: 0.57, blue: 0.39)
        case "recent": COSPalette.ink
        default: .secondary
        }
    }

    private func providerTint(_ provider: String) -> Color {
        switch provider {
        case "codex": Color(red: 0.10, green: 0.55, blue: 0.48)
        case "cursor": Color(red: 0.42, green: 0.38, blue: 0.86)
        default: Color(red: 0.78, green: 0.45, blue: 0.22)
        }
    }

    private func providerGlyph(_ provider: String) -> some View {
        let symbol = provider == "codex" ? "chevron.left.forwardslash.chevron.right"
            : provider == "cursor" ? "macwindow"
            : "text.bubble"
        return ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(providerTint(provider).opacity(0.16))
                .frame(width: 28, height: 28)
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(providerTint(provider))
        }
    }

    private func providerBadge(_ session: ClaudeSession) -> some View {
        Text(session.providerLabel.uppercased())
            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
            .tracking(0.6)
            .foregroundStyle(providerTint(session.provider))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(providerTint(session.provider).opacity(0.14)))
    }

    private func openVoiceReviewFromLibrary(_ sessionId: String) {
        speakerSubview = .meetings
        selectedSpeakerSessionID = sessionId
        withOptionalAnimation { section = .speakers }
        model.openSpeakerReview(sessionId: sessionId)
    }

    private var messagesList: some View {
        VStack(spacing: 0) {
            sectionHeader(
                section: .messages,
                title: "Recent messages",
                detail: messagesStatus,
                refresh: { Task { await model.refreshRecentMessages() } },
                secondaryTitle: "Copy handoff",
                secondaryAction: { model.copyHandoff() },
                secondaryDisabled: model.recentMessages.isEmpty
            )
            if model.recentGlassesStatus == .loading {
                centeredProgress("Loading messages…")
            } else if model.recentMessages.isEmpty {
                emptyState(.messages, text: messagesEmptyCopy)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.recentMessages) { turn in
                            Button {
                                selectedTurnID = turn.id
                            } label: {
                                messageRow(turn)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 46)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 22)
                }
            }
        }
    }

    private var speakersList: some View {
        VStack(spacing: 0) {
            sectionHeader(
                section: .speakers,
                title: speakerSubview == .voices ? "Voice directory" : "Meetings to review",
                detail: speakerDirectoryDetail,
                refresh: {
                    Task {
                        if speakerSubview == .voices { await model.loadVoiceDirectory(refresh: true) }
                        else { await model.loadReviewableMeetings() }
                    }
                },
                refreshDisabled: speakerSubview == .voices ? model.voiceDirectoryLoading : model.meetingsLoading
            )

            HStack(spacing: 12) {
                Picker("Speaker view", selection: $speakerSubview) {
                    ForEach(SpeakerSubview.allCases) { item in Text(item.title).tag(item) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .onChange(of: speakerSubview) { _, next in
                    selectedVoiceName = nil
                    selectedSpeakerSessionID = nil
                    model.closeSpeakerReview()
                    Task {
                        if next == .voices { await model.loadVoiceDirectory() }
                        else { await model.loadReviewableMeetings() }
                    }
                }

                if speakerSubview == .voices {
                    TextField("Search voices", text: $voiceSearch)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                        .accessibilityLabel("Search enrolled voices")
                    Menu {
                        Picker("Sort voices", selection: $voiceSort) {
                            ForEach(VoiceDirectorySort.allCases) { sort in Text(sort.title).tag(sort) }
                        }
                    } label: {
                        Label(voiceSort.title, systemImage: "arrow.up.arrow.down")
                    }
                }
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(COSPalette.card.opacity(0.42))
            .overlay(alignment: .bottom) { Divider() }

            if speakerSubview == .voices {
                voiceDirectoryList
            } else {
                meetingsToReviewList
            }
        }
    }

    private var speakerDirectoryDetail: String {
        if speakerSubview == .meetings {
            return model.reviewableMeetings.isEmpty
                ? "Choose a saved meeting to name its voices."
                : "\(model.reviewableMeetings.count) recent saved meetings"
        }
        if model.voiceDirectory.isEmpty { return "Enrolled identities and cross-meeting evidence." }
        if model.voiceDirectoryRouteAvailable == false {
            return "\(model.voiceDirectory.count) enrolled profiles · history unavailable on this server"
        }
        let review = model.voiceDirectory.reduce(0) { $0 + $1.reviewMeetingCount }
        return "\(model.voiceDirectory.count) enrolled · \(review) review occurrence\(review == 1 ? "" : "s")"
    }

    @ViewBuilder
    private var voiceDirectoryList: some View {
        if model.voiceDirectoryLoading && model.voiceDirectory.isEmpty {
            centeredProgress("Building the voice directory…")
        } else if model.voiceDirectory.isEmpty {
            emptyState(.speakers, text: model.voiceDirectoryError ?? "No voice profiles are enrolled yet.")
        } else {
            VStack(spacing: 0) {
                if let error = model.voiceDirectoryError {
                    directoryNotice(error, stale: model.voiceDirectoryRouteAvailable != false)
                }
                if model.voiceDirectoryUnresolvedMeetings > 0 {
                    directoryNotice(
                        "\(model.voiceDirectoryUnresolvedSegments) unidentified segments remain local to \(model.voiceDirectoryUnresolvedMeetings) meeting\(model.voiceDirectoryUnresolvedMeetings == 1 ? "" : "s"). They are not treated as one person.",
                        stale: false
                    )
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        voiceDirectoryColumnHeader
                        ForEach(visibleVoices) { person in
                            Button { selectedVoiceName = person.name } label: {
                                voiceDirectoryRow(person)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(voiceAccessibilityLabel(person))
                            .accessibilityHint("Open voice history")
                            Divider().padding(.leading, 52)
                        }
                    }
                    .frame(maxWidth: 980)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 22)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var voiceDirectoryColumnHeader: some View {
        HStack(spacing: 12) {
            Text("VOICE").frame(maxWidth: .infinity, alignment: .leading)
            Text("SEGMENTS").frame(width: 78, alignment: .trailing)
            Text("MEETINGS").frame(width: 78, alignment: .trailing)
            Text("MATCH").frame(width: 76, alignment: .trailing)
            Text("LAST SEEN").frame(width: 88, alignment: .trailing)
            Color.clear.frame(width: 12)
        }
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.vertical, 10)
    }

    private func voiceDirectoryRow(_ person: VoiceDirectoryPerson) -> some View {
        let historyAvailable = model.voiceDirectoryRouteAvailable != false
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(ActivitySection.speakers.tint.opacity(0.12))
                Image(systemName: person.isOwner ? "person.crop.circle.badge.checkmark" : "waveform")
                    .foregroundStyle(ActivitySection.speakers.tint)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(person.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    if person.isOwner { statusPill("OWNER", tint: COSPalette.green) }
                    if person.needsAttention { statusPill("REVIEW", tint: COSPalette.amber) }
                }
                Text("\(person.embeddings) training samples · \(sourceSummary(person.sources))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            metric(historyAvailable ? "\(person.assertedSegments)" : "—", sub: historyAvailable && person.candidateSegments > 0 ? "+\(person.candidateSegments) review" : nil, width: 78)
            metric(historyAvailable ? "\(person.meetingCount)" : "—", sub: historyAvailable && person.reviewMeetingCount > 0 ? "\(person.reviewMeetingCount) review" : nil, width: 78)
            metric(historyAvailable ? percent(person.observedMatch) : "—", sub: historyAvailable ? (person.observedMatch == nil ? "no basis" : "observed") : "update server", width: 76)
            metric(historyAvailable ? (person.lastSeen ?? "Never") : "—", sub: nil, width: 88)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 12)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var meetingsToReviewList: some View {
        Group {
            if model.meetingsLoading {
                centeredProgress("Loading meetings…")
            } else if model.reviewableMeetings.isEmpty {
                emptyState(.speakers, text: model.reviewError ?? "No reviewable meetings yet.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.reviewableMeetings) { meeting in
                            Button {
                                voiceParentName = nil
                                selectedSpeakerSessionID = meeting.sessionId
                                model.openSpeakerReview(meeting)
                            } label: {
                                HStack(spacing: 13) {
                                    sectionGlyph(.speakers)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(meeting.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                        Text("\(meeting.date) · \(meeting.duration)")
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        Text(meeting.countsSummary).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 13)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 46)
                        }
                    }
                    .frame(maxWidth: 980)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 22)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func contextList(kind: String) -> some View {
        let isThread = kind == "thread"
        let item: ActivitySection = isThread ? .threads : .memories
        let records = isThread ? model.threadRecords : model.memoryRecords
        let loading = isThread ? model.threadRecordsLoading : model.memoryRecordsLoading
        let error = isThread ? model.threadRecordsError : model.memoryRecordsError
        let available = isThread ? model.status.threadsAvailable == true : model.status.memoryAvailable == true
        let headline = isThread ? model.threadHeadline : model.memoryHeadline
        let queryActive = isThread ? model.isThreadQueryActive : model.isMemoryQueryActive
        let searching = isThread ? model.threadSearching : model.memorySearching
        return VStack(spacing: 0) {
            sectionHeader(
                section: item,
                title: isThread ? "Review threads" : "Review memories",
                detail: queryActive
                    ? (searching ? "Looking up…" : "Lookup across stored \(item.title.lowercased())")
                    : (!headline.isEmpty ? headline : item.summary),
                refresh: { Task { await model.loadContextRecords(kind: kind) } }
            )
            if available {
                contextSearchBar(kind: kind)
            }
            if queryActive {
                contextSearchResults(kind: kind, item: item)
            } else if loading {
                centeredProgress("Loading \(item.title.lowercased())…")
            } else if !available {
                emptyState(item, text: "Choose COS Data in the menu-bar panel to connect this library.")
            } else if records.isEmpty {
                emptyState(item, text: error ?? "No \(item.title.lowercased()) yet.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(records) { record in
                            Button {
                                selectedContextID = record.id
                                model.openContextRecord(record, kind: kind)
                            } label: {
                                contextRow(record, item: item)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 46)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 22)
                }
            }
        }
    }

    private func contextSearchBar(kind: String) -> some View {
        let isThread = kind == "thread"
        let query = isThread ? model.threadQuery : model.memoryQuery
        let semanticAvailable = isThread ? model.threadSemanticAvailable : model.memorySemanticAvailable
        let queryActive = isThread ? model.isThreadQueryActive : model.isMemoryQueryActive
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search topics, ideas…", text: isThread ? $model.threadQuery : $model.memoryQuery)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button {
                            if isThread { model.threadQuery = "" } else { model.memoryQuery = "" }
                            model.scheduleContextSearch(kind: kind)
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
                Picker("Recency", selection: $model.searchRecency) {
                    ForEach(SearchRecency.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 150)
                .accessibilityLabel("Recency")
                Spacer()
            }
            if queryActive, !semanticAvailable {
                Text(isThread
                     ? "Keyword only — threads have no meaning index"
                     : "Keyword only — meaning search needs the COS memory index")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
        .onChange(of: isThread ? model.threadQuery : model.memoryQuery) { _, _ in
            model.scheduleContextSearch(kind: kind)
        }
    }

    @ViewBuilder
    private func contextSearchResults(kind: String, item: ActivitySection) -> some View {
        let isThread = kind == "thread"
        let searching = isThread ? model.threadSearching : model.memorySearching
        let hits = isThread ? model.visibleThreadSearchHits : model.visibleMemorySearchHits
        let error = isThread ? model.threadSearchError : model.memorySearchError
        if searching && hits.isEmpty && error == nil {
            centeredProgress("Looking up…")
        } else if let error, hits.isEmpty {
            emptyState(item, text: error)
        } else if hits.isEmpty {
            emptyState(item, text: "No \(item.title.lowercased()) match that lookup.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(hits) { hit in
                        Button {
                            selectedContextID = hit.record.id
                            model.openContextRecord(hit.record, kind: kind)
                        } label: {
                            HStack(spacing: 13) {
                                sectionGlyph(item)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(hit.record.title)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    if !hit.snippet.isEmpty {
                                        Text(hit.snippet)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    Text(hit.record.id)
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(hit.matchLabel)
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(item.tint.opacity(0.16)))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 13)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 46)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
            }
        }
    }

    private func contextRow(_ record: ContextRecord, item: ActivitySection) -> some View {
        HStack(spacing: 13) {
            sectionGlyph(item)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !record.subtitle.isEmpty {
                    Text(record.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(record.id)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    private func sectionHeader(
        section item: ActivitySection,
        title: String,
        detail: String,
        refresh: @escaping () -> Void,
        refreshDisabled: Bool = false,
        secondaryTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil,
        secondaryDisabled: Bool = false
    ) -> some View {
        sectionHeader(
            section: item,
            title: title,
            detail: detail,
            refresh: refresh,
            refreshDisabled: refreshDisabled,
            secondaryTitle: secondaryTitle,
            secondaryAction: secondaryAction,
            secondaryDisabled: secondaryDisabled,
            accessory: { EmptyView() }
        )
    }

    private func sectionHeader<Accessory: View>(
        section item: ActivitySection,
        title: String,
        detail: String,
        refresh: @escaping () -> Void,
        refreshDisabled: Bool = false,
        secondaryTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil,
        secondaryDisabled: Bool = false,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            sectionGlyph(item, large: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 19, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            accessory()
            if let secondaryTitle, let secondaryAction {
                Button(secondaryTitle, action: secondaryAction)
                    .disabled(secondaryDisabled)
            }
            Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                .disabled(refreshDisabled)
        }
        .controlSize(.small)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(item.tint.opacity(0.055))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func sectionGlyph(_ item: ActivitySection, large: Bool = false) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: large ? 10 : 8)
                .fill(item.tint.opacity(0.12))
            Image(systemName: item.icon)
                .font(.system(size: large ? 17 : 13, weight: .medium))
                .foregroundStyle(item.tint)
        }
        .frame(width: large ? 42 : 32, height: large ? 42 : 32)
    }

    private func directoryNotice(_ text: String, stale: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: stale ? "clock.badge.exclamationmark" : "info.circle")
                .foregroundStyle(stale ? COSPalette.amber : ActivitySection.speakers.tint)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 9)
        .background((stale ? COSPalette.amber : ActivitySection.speakers.tint).opacity(0.07))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func statusPill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.16), in: Capsule())
    }

    private func metric(_ value: String, sub: String?, width: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).lineLimit(1)
            if let sub { Text(sub).font(.system(size: 8.5)).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(width: width, alignment: .trailing)
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int((value * 100).rounded()))%"
    }

    private func sourceSummary(_ sources: [String: Int]) -> String {
        let rows = sources.filter { $0.value > 0 }.sorted { a, b in
            a.value == b.value ? a.key < b.key : a.value > b.value
        }
        return rows.prefix(2).map { "\($0.key) \($0.value)" }.joined(separator: " · ")
    }

    private func voiceAccessibilityLabel(_ person: VoiceDirectoryPerson) -> String {
        guard model.voiceDirectoryRouteAvailable != false else {
            return "\(person.name), \(person.embeddings) training samples, cross-meeting history requires a server update"
        }
        let match = person.observedMatch.map { "observed match \(Int(($0 * 100).rounded())) percent" } ?? "no observed match basis"
        return "\(person.name), \(person.embeddings) training samples, \(person.assertedSegments) attributed segments in \(person.meetingCount) meetings, \(match)"
    }

    private func messageRow(_ turn: GlassesTurn) -> some View {
        HStack(alignment: .top, spacing: 13) {
            sectionGlyph(.messages)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(turn.no.map { "Message #\($0)" } ?? "Message")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(turn.timeLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if !turn.attachments.isEmpty {
                        Label("\(turn.attachments.count)", systemImage: "photo")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(turn.previewQuery)
                    .font(.system(size: 12.5))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(turn.text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    // MARK: - Details

    private func voiceDirectoryDetail(_ person: VoiceDirectoryPerson) -> some View {
        let historyAvailable = model.voiceDirectoryRouteAvailable != false
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    sectionGlyph(.speakers, large: true)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(person.name).font(.system(size: 22, weight: .semibold))
                            if person.isOwner { statusPill("OWNER", tint: COSPalette.green) }
                            if person.needsAttention { statusPill("NEEDS REVIEW", tint: COSPalette.amber) }
                        }
                        Text("Enrolled identity · \(person.embeddings) training samples")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    voiceMetricCard(title: "OBSERVED MATCH", value: historyAvailable ? percent(person.observedMatch) : "—", detail: historyAvailable ? (person.observedMatch == nil ? "No scored segments" : "\(person.observedMatchSegments) segment basis") : "Update server")
                    voiceMetricCard(title: "ATTRIBUTED", value: historyAvailable ? "\(person.assertedSegments)" : "—", detail: historyAvailable ? "segments" : "History unavailable")
                    voiceMetricCard(title: "MEETINGS", value: historyAvailable ? "\(person.meetingCount)" : "—", detail: historyAvailable ? (person.reviewMeetingCount > 0 ? "\(person.reviewMeetingCount) need review" : "asserted") : "History unavailable")
                    voiceMetricCard(title: "LAST HEARD", value: historyAvailable ? (person.lastSeen ?? "Never") : "—", detail: historyAvailable ? (person.firstSeen.map { "since \($0)" } ?? "No occurrence") : "History unavailable")
                }

                HStack(alignment: .top, spacing: 12) {
                    directoryInfoCard(
                        title: "Training provenance",
                        rows: person.sources.isEmpty
                            ? ["No provenance recorded"]
                            : person.sources.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value) sample\($0.value == 1 ? "" : "s")" },
                        warning: person.sourcesAligned ? nil : "Sample and provenance counts do not align."
                    )
                    directoryInfoCard(
                        title: "Observed evidence",
                        rows: historyAvailable ? [
                            "\(person.assertedSegments) attributed segments",
                            "\(formatDuration(person.assertedSpeakingMs)) credited speaking time",
                            "\(person.candidateSegments) candidate segments awaiting review",
                        ] : ["Cross-meeting evidence requires the Voice Directory server route."],
                        warning: historyAvailable && person.candidateSegments > 0 ? "Candidates are not counted as confirmed identity." : nil
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("MEETING HISTORY")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(.secondary)
                    if person.appearances.isEmpty {
                        Text(model.voiceDirectoryRouteAvailable == false
                            ? "Update the server to add meeting history."
                            : "No attributed meeting appearances are available yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(person.appearances) { appearance in
                                Button {
                                    voiceParentName = person.name
                                    selectedVoiceName = nil
                                    selectedSpeakerSessionID = appearance.sessionId
                                    model.openSpeakerReview(sessionId: appearance.sessionId)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: appearance.needsReview ? "exclamationmark.waveform" : "waveform.badge.checkmark")
                                            .foregroundStyle(appearance.needsReview ? COSPalette.amber : ActivitySection.speakers.tint)
                                            .frame(width: 24)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(appearance.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                            Text("\(appearance.date) · \(appearance.segments) segments · \(formatDuration(appearance.speakingMs))")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 3) {
                                            Text(percent(appearance.observedMatch))
                                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            Text(appearance.confirmedByHuman ? "human confirmed" : appearance.needsReview ? "review" : "observed match")
                                                .font(.system(size: 8.5))
                                                .foregroundStyle(.secondary)
                                        }
                                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 11)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Open this meeting's speaker review")
                                Divider().padding(.leading, 36)
                            }
                        }
                        .padding(.horizontal, 16)
                        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(COSPalette.line, lineWidth: 1))
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func voiceMetricCard(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 8.5, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.75)
            Text(detail).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        .padding(13)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(COSPalette.line, lineWidth: 1))
    }

    private func directoryInfoCard(title: String, rows: [String], warning: String?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12.5, weight: .semibold))
            ForEach(rows, id: \.self) { Text($0).font(.system(size: 10.5)).foregroundStyle(.secondary) }
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.primary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 94, alignment: .topLeading)
        .padding(15)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(COSPalette.line, lineWidth: 1))
    }

    private func formatDuration(_ milliseconds: Int) -> String {
        if milliseconds <= 0 { return "0m" }
        let minutes = max(1, Int((Double(milliseconds) / 60_000).rounded()))
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    private func messageDetail(_ turn: GlassesTurn) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    sectionGlyph(.messages, large: true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(turn.no.map { "Message #\($0)" } ?? "Message")
                            .font(.system(size: 19, weight: .semibold))
                        Text("\(turn.timeLabel) · \(turn.source.isEmpty ? "COS Glasses" : turn.source)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Copy turn") { model.copyTurn(turn) }
                    if !turn.attachments.isEmpty {
                        Button("Copy + images") { model.copyTurnWithImages(turn) }
                            .disabled(model.mediaExportingTurnIDs.contains(turn.id))
                    }
                }
                .controlSize(.small)

                messageBlock(label: "You", text: turn.query, tint: ActivitySection.messages.tint)
                attachmentStrip(title: "Your image", attachments: turn.attachments.filter(\.isUserPhoto))
                messageBlock(label: "COS", text: turn.text, tint: COSPalette.green)
                attachmentStrip(title: "Answer image", attachments: turn.attachments.filter { !$0.isUserPhoto })
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func messageBlock(label: String, text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(.primary)
            Text(text.isEmpty ? "(empty)" : text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(17)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(tint.opacity(0.22), lineWidth: 1))
    }

    @ViewBuilder
    private func attachmentStrip(title: String, attachments: [GlassesAttachmentRef]) -> some View {
        if !attachments.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(attachments) { attachment in
                            Button { model.openMediaPreview(attachment) } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10).fill(COSPalette.card)
                                    switch model.mediaPreviewStates[attachment.id] {
                                    case .ready(let image):
                                        Image(nsImage: image)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                    case .unavailable:
                                        Image(systemName: "photo.badge.exclamationmark")
                                            .foregroundStyle(.secondary)
                                    case .loading, nil:
                                        ProgressView().controlSize(.small)
                                    }
                                    if model.previewingMediaID == attachment.id {
                                        Color.black.opacity(0.16)
                                        ProgressView().controlSize(.small)
                                    }
                                }
                                .frame(width: 148, height: 104)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(COSPalette.line, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .disabled(model.previewingMediaID != nil)
                            .onAppear { model.loadThumbnail(attachment) }
                            .onDisappear { model.cancelThumbnail(attachment) }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func mediaDetail(_ preview: SelectedMediaPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.attachment.displayLabel)
                        .font(.system(size: 19, weight: .semibold))
                    Text("\(preview.attachment.width) × \(preview.attachment.height)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Image(nsImage: preview.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(24)
    }

    // MARK: - Loading and copy

    private func loadOverviewIfNeeded() async {
        // Activity can be the first COS Control surface opened after launch.
        // Prove the server here instead of inheriting the model's initial
        // `running = false` placeholder from the unopened menu-bar panel.
        await model.refresh(quiet: true)
        if model.recentMessages.isEmpty { await model.refreshRecentMessages(quiet: true) }
        if model.voiceDirectory.isEmpty { await model.loadVoiceDirectory() }
        if model.status.memoryAvailable == true, model.memoryRecords.isEmpty {
            await model.loadContextRecords(kind: "memory")
        }
        if model.status.threadsAvailable == true, model.threadRecords.isEmpty {
            await model.loadContextRecords(kind: "thread")
        }
        if model.claudeSessions.isEmpty { await model.loadClaudeSessions() }
    }

    private func load(_ item: ActivitySection) async {
        switch item {
        case .messages: await model.refreshRecentMessages()
        case .speakers:
            if speakerSubview == .voices { await model.loadVoiceDirectory() }
            else { await model.loadReviewableMeetings() }
        case .meetings:
            await model.loadLibraryMeetings()
        case .memories:
            if model.status.memoryAvailable == true { await model.loadContextRecords(kind: "memory") }
        case .threads:
            if model.status.threadsAvailable == true { await model.loadContextRecords(kind: "thread") }
        case .sessions:
            await model.loadClaudeSessions()
        }
    }

    private var messagesStatus: String {
        switch model.recentGlassesStatus {
        case .loading: "Loading…"
        case .ready: "Newest first · \(model.recentMessages.count) turn(s)"
        case .empty: "No turns today"
        case .serverStopped: "Server stopped"
        case .unauthorized: "Pairing token rejected"
        case .error: "Could not load messages"
        case .idle: "Refresh to load"
        }
    }

    private var messagesEmptyCopy: String {
        switch model.recentGlassesStatus {
        case .serverStopped: "Start the COS server, then refresh."
        case .unauthorized: "The saved pairing token was rejected. Copy a new token from the menu-bar panel."
        case .error: "Messages could not be loaded. Open Logs from the menu-bar panel, then try again."
        default: "No glasses messages have landed today."
        }
    }

    private func centeredProgress(_ label: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(_ item: ActivitySection, text: String) -> some View {
        VStack(spacing: 12) {
            sectionGlyph(item, large: true)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

struct ClaudeSessionDetailPane: View {
    @ObservedObject var model: ControllerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let row = model.openClaudeRow {
                        Text(row.providerLabel.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(0.6)
                            .foregroundStyle(Self.tint(row.provider))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Self.tint(row.provider).opacity(0.14)))
                    }
                    Text(model.claudeSessionDetail?.title ?? model.openClaudeRow?.title ?? "Session")
                        .font(.system(size: 20, weight: .semibold))
                        .textSelection(.enabled)
                }
                Text(model.claudeSessionDetail?.subtitle ?? "Read-only · local transcript")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if let cwd = model.claudeSessionDetail?.cwd, !cwd.isEmpty {
                    Text(cwd)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 12)
            Divider()

            if model.claudeSessionDetailLoading && model.claudeSessionDetail == nil {
                ProgressView("Loading session…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.claudeSessionDetailError, model.claudeSessionDetail == nil {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(24)
                if let row = model.openClaudeRow {
                    Button("Retry") { model.openClaudeSession(row) }
                        .padding(.horizontal, 24)
                }
                Spacer()
            } else if let detail = model.claudeSessionDetail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if detail.truncated {
                            Text("Showing the last \(detail.turns.count) of \(detail.totalTurns) turns. Copy session keeps the original request plus the newest context.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        if detail.turns.isEmpty {
                            Text("This session has no user or assistant prose stored.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(detail.turns) { turn in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(turn.isUser ? "YOU" : "ASSISTANT")
                                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                    .tracking(1.2)
                                Text(turn.text)
                                    .font(.system(size: 12.5))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 13))
                            .overlay(
                                RoundedRectangle(cornerRadius: 13)
                                    .stroke((turn.isUser ? ActivitySection.sessions.tint : COSPalette.green).opacity(0.22), lineWidth: 1)
                            )
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack(spacing: 10) {
                    Button("Copy session") { model.copyClaudeSession() }
                        .disabled(detail.copyText.isEmpty)
                    Spacer()
                    Text("Kickstart brief for another agent. Not a Claude Code resume.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
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
            }
        }
    }

    private static func tint(_ provider: String) -> Color {
        switch provider {
        case "codex": Color(red: 0.10, green: 0.55, blue: 0.48)
        case "cursor": Color(red: 0.42, green: 0.38, blue: 0.86)
        default: Color(red: 0.78, green: 0.45, blue: 0.22)
        }
    }
}
