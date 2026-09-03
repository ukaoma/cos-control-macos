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

    func show(model: ControllerModel, section: ActivitySection? = nil) {
        self.model = model
        if let section {
            model.activityOpenSection = section
        }
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
        // Session chat holds a poll Task and a live binding reference; a
        // window close must not leave either running against a stale row.
        model?.closeClaudeSession()
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
    case tasks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .messages: "Messages"
        case .speakers: "Speakers"
        case .meetings: "Meetings"
        case .memories: "Memories"
        case .threads: "Threads"
        case .sessions: "Sessions"
        case .tasks: "Tasks"
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
        case .tasks: "checklist"
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
        case .tasks: Color(red: 0.18, green: 0.45, blue: 0.52)
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
        case .tasks: "Capture, schedule, and run the work sitting in tasks.md."
        }
    }
}


private enum MessagesSubview: String, CaseIterable, Identifiable {
    case recent
    case archive

    var id: String { rawValue }
    var title: String { self == .archive ? "Archive" : "Recent" }
}

private enum SpeakerSubview: String, CaseIterable, Identifiable {
    case meetings
    case voices

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
    /// In-chat search: the term and which match the cursor is on.
    @Environment(\.colorScheme) private var colorScheme
    /// Recent-view search. Recent turns are already in memory, so this filters
    /// locally — the archive is the only side that needs the server.
    /// Recent and Archive search the SAME term. This mirrors it rather than
    /// holding a second one: a term absent from the last few turns is usually
    /// months back, and retyping it to find that out was the whole complaint.
    private var recentQuery: String { model.archiveQuery }
    @State private var chatQuery = ""
    @State private var chatMatchCursor = 0
    @State private var section: ActivitySection?
    @State private var selectedTurnID: String?
    /// The archive drill-through: a date, then a chat index inside that date.
    /// Two flags rather than one enum because they nest — the chat pane needs its
    /// parent date to load, and Back has to land on the day, not the day list.
    @State private var selectedArchiveDate: String?
    @State private var selectedArchiveChat: Int?
    @State private var selectedSpeakerSessionID: String?
    @State private var selectedVoiceName: String?
    @State private var voiceParentName: String?
    @State private var speakerSubview: SpeakerSubview = .meetings
    @State private var messagesSubview: MessagesSubview = .recent
    /// Name being typed into Add a voice. Local to the view: it is transient and
    /// must not survive a tab switch.
    @State private var addVoiceName = ""
    @State private var voiceSearch = ""
    @State private var voiceSort: VoiceDirectorySort = .attention
    @State private var selectedContextID: String?
    @State private var selectedLibraryRecordID: String?
    @State private var selectedSessionID: String?
    @State private var taskCapture = ""
    @State private var taskDomain = "quilt"
    @State private var taskRunAt = Date()
    @State private var taskBusy = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the gateway paint-in. Flips once on appear; every tile reads it with its
    /// own delay, which is how `anime.stagger` translates into SwiftUI.
    @State private var painted = false
    @State private var hoveredSection: ActivitySection?
    /// One indicator that travels between tabs instead of six that blink.
    @Namespace private var railIndicator

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
        case .messages:
            model.selectedMediaPreview != nil || selectedTurnID != nil
                || selectedArchiveDate != nil || selectedArchiveChat != nil
        case .speakers: selectedVoiceName != nil || selectedSpeakerSessionID != nil
        case .meetings: selectedLibraryRecordID != nil
        case .memories, .threads: selectedContextID != nil
        case .sessions: selectedSessionID != nil
        case .tasks: false
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
                } else if section == .messages,
                          let date = selectedArchiveDate, let chat = selectedArchiveChat {
                    archiveChatDetail(date: date, index: chat)
                } else if section == .messages, let date = selectedArchiveDate {
                    archiveDayDetail(date: date)
                } else if section == .speakers, let selectedVoice {
                    voiceDirectoryDetail(selectedVoice)
                } else if section == .speakers, selectedSpeakerSessionID != nil {
                    if model.reviewRouteActive {
                        SpeakerReviewPane(
                            model: model,
                            showsBackButton: false,
                            onNextUnnamed: openNextUnnamedReview,
                            nextUnnamedAvailable: nextUnnamedReview != nil
                        )
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
        .task(id: speakerPeekKey) { await peekMeetingsIfNeeded() }
        .alert("COS Control", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
        .onExitCommand { goBack() }
        .onAppear { applyLaunchSection() }
        .onChange(of: model.activityOpenSection) { _, _ in applyLaunchSection() }
        .onChange(of: model.activityOpenSessionID) { _, _ in applyLaunchSection() }
    }

    private func applyLaunchSection() {
        let sessionID = model.activityOpenSessionID
        let next = model.activityOpenSection
        if next == nil && sessionID == nil { return }
        model.activityOpenSection = nil
        model.activityOpenSessionID = nil
        let staged = sessionID.flatMap { model.petSession(id: $0) }
        if let next { select(next) }
        if let staged {
            selectedSessionID = staged.id
            model.openClaudeSession(staged)
        }
    }

    // MARK: - Navigation

    private var navigationBar: some View {
        HStack(spacing: 10) {
            COSLockupView(height: 12)
                // Adaptive, like the header lockup. COSPalette.ink is a fixed dark meant
                // for the brand tile; on the toolbar it renders black on espresso.
                .foregroundStyle(.primary)
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
        if section == .messages, let date = selectedArchiveDate {
            guard let chat = selectedArchiveChat else { return date }
            return "\(date) · chat \(chat + 1)"
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
                    if reduceMotion { select(item) }
                    else { withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { select(item) } }
                } label: {
                    VStack(spacing: 7) {
                        HStack(spacing: 7) {
                            SectionGlyph(section: item)
                                .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                                .frame(width: 13, height: 13)
                            Text(item.title)
                        }
                        .font(.system(size: 11.5, weight: section == item ? .semibold : .medium))
                        .foregroundStyle(section == item ? .primary : .secondary)
                        // The indicator is ONE view that moves between tabs, not six that
                        // toggle. `matchedGeometryEffect` interpolates its frame across the
                        // change, so switching reads as travel rather than a hard cut.
                        ZStack {
                            Capsule().fill(Color.clear).frame(height: 3)
                            if section == item {
                                Capsule()
                                    .fill(COSPalette.gold)
                                    .frame(height: 2.5)
                                    .matchedGeometryEffect(id: "railIndicator", in: railIndicator)
                            }
                        }
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
        } else if section == .messages, selectedArchiveChat != nil {
            // One rung only: a chat's Back lands on its day, not the day list.
            selectedArchiveChat = nil
            model.closeArchiveChat()
        } else if section == .messages, selectedArchiveDate != nil {
            selectedArchiveDate = nil
            model.closeArchiveDay()
        } else if section == .speakers, selectedVoiceName != nil {
            selectedVoiceName = nil
        } else if section == .speakers, selectedSpeakerSessionID != nil {
            selectedSpeakerSessionID = nil
            model.closeSpeakerReview()
            if let parent = voiceParentName {
                selectedVoiceName = parent
                voiceParentName = nil
            }
            Task { await model.peekReviewableMeetings() }
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

    /// Open one archived day. The load is fired here, at the opener, so the pane
    /// never has to guess whether its data was requested.
    private func openArchiveDay(_ date: String) {
        selectedArchiveChat = nil
        model.closeArchiveChat()
        withOptionalAnimation { selectedArchiveDate = date }
        Task { await model.loadArchiveChats(date: date) }
    }

    private func openArchiveChat(date: String, index: Int) {
        withOptionalAnimation { selectedArchiveChat = index }
        Task { await model.loadArchiveMessages(date: date, index: index) }
    }

    private func clearDetail() {
        model.closeMediaPreview()
        selectedTurnID = nil
        selectedArchiveDate = nil
        selectedArchiveChat = nil
        model.closeArchiveDay()
        model.closeArchiveChat()
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
                        // NOT COSPalette.ink: that is a fixed dark, correct on the brand
                        // tile and black-on-black on the espresso panel in dark mode.
                        .foregroundStyle(.primary)
                    Spacer()
                    COSGotcosCaption(size: 12)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Activity")
                        .font(COSType.display(28, weight: .medium))
                    Text("Seven views into the work your COS already holds.")
                        .font(COSType.display(13, italic: true))
                        .foregroundStyle(.secondary)
                }

                // Four columns, two rows: seven tiles stay above the fold. Three
                // columns would put Tasks on a third row at the minimum window height.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
                    ForEach(Array(ActivitySection.allCases.enumerated()), id: \.element.id) { index, item in
                        Button { select(item) } label: {
                            activityHomeCard(item, index: index)
                        }
                        .buttonStyle(.plain)
                        // Plain and explicit. The earlier one-liner also cleared state for
                        // a tile that was no longer hovered, which races the enter event of
                        // the tile you just moved onto.
                        .onHover { inside in
                            if inside { hoveredSection = item }
                            else if hoveredSection == item { hoveredSection = nil }
                        }
                    }
                }
                .onAppear { painted = true }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// One gateway tile.
    ///
    /// The accent bar this replaced was a `RoundedRectangle(cornerRadius: 2)` overlaid on a
    /// 16pt-radius card: a CSS `border-left` moved into SwiftUI without reconciling the
    /// geometry, so the card curved away and the bar stayed straight. Nothing sits on the
    /// edge now. The stipple is the card's paper — gotcos `.chapcard` 9pt gold dots, a
    /// child clipped by the tile — not a corner glyph sitting on espresso.
    private func activityHomeCard(_ item: ActivitySection, index: Int) -> some View {
        let hot = hoveredSection == item
        // anime.stagger(45) is just an index-scaled delay.
        let step = Double(index) * 0.045

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionGlyph(section: item)
                    .trim(from: 0, to: (reduceMotion || painted) ? 1 : 0)
                    .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(hot ? COSPalette.gold : Color.secondary)
                    .frame(width: 17, height: 17)
                    .animation(reduceMotion ? nil
                               : .timingCurve(0.42, 0, 0.22, 1, duration: 0.60).delay(step + 0.14),
                               value: painted)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18).delay(hot ? 0.04 : 0),
                               value: hot)

                Text(item.title)
                    .font(COSType.body(14.5, weight: .semibold))
                    .foregroundStyle(hot ? COSPalette.gold : Color.primary)
                    .wipeIn(painted, delay: step + 0.33, reduceMotion: reduceMotion)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18).delay(hot ? 0.07 : 0),
                               value: hot)

                Spacer(minLength: 8)

                Text(homeMetric(item).count)
                    .font(COSType.display(22, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(hot ? COSPalette.gold : Color.primary)
                    .lineLimit(1)
                    .wipeIn(painted, delay: step + 0.47, reduceMotion: reduceMotion)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18).delay(hot ? 0.10 : 0),
                               value: hot)
            }

            Text(item.summary)
                .font(COSType.body(11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Text(homeMetric(item).unit)
                .font(COSType.mono(9.5))
                .tracking(hot ? 1.1 : 0.6)
                .foregroundStyle(hot ? COSPalette.gold : Color.secondary.opacity(0.75))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.24).delay(hot ? 0.13 : 0),
                           value: hot)
        }
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(hot ? COSPalette.gold.opacity(0.07) : Color.clear)
        .background {
            HalftonePlate(strong: hot)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.26), value: hot)
        }
        .background(COSPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))   // clips the stipple to the radius
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(hot ? COSPalette.gold : COSPalette.line, lineWidth: 1))
        .shadow(color: .black.opacity(hot ? 0.16 : 0), radius: hot ? 9 : 0, x: 0, y: hot ? 4 : 0)
        .offset(y: hot ? -1 : 0)
        .opacity((reduceMotion || painted) ? 1 : 0)
        .offset(y: (reduceMotion || painted) ? 0 : 9)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.88).delay(step),
                   value: painted)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hot)
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    /// The count and what it counts, read from the model rather than scraped out of
    /// `homeStat`'s prose.
    ///
    /// The first cut DID scrape it, taking leading digits and calling the remainder the
    /// unit. That turned "50 of 5528" into `50 / OF 5528` and "30 shown · 11 active" into
    /// `30 / SHOWN · 11 ACTIVE` — the smaller number promoted and the label left a
    /// fragment. `status.memoryCount` and `status.threadCount` were there the whole time.
    private func homeMetric(_ item: ActivitySection) -> (count: String, unit: String) {
        func n(_ value: Int) -> String {
            let f = NumberFormatter(); f.numberStyle = .decimal
            return f.string(from: NSNumber(value: value)) ?? "\(value)"
        }
        switch item {
        case .messages:
            return model.recentMessages.isEmpty ? ("—", "REFRESH") : (n(model.recentMessages.count), "RECENT")
        case .speakers:
            return model.voiceDirectory.isEmpty ? ("—", "REFRESH") : (n(model.voiceDirectory.count), "ENROLLED")
        case .meetings:
            if !model.libraryMeetings.isEmpty {
                return (n(model.libraryMeetings.count), MeetingMonth.title(model.libraryMonth).uppercased())
            }
            if model.status.meetingLibraryCount > 0 { return (n(model.status.meetingLibraryCount), "STORED") }
            return ("—", "BY DAY")
        case .memories:
            guard model.status.memoryAvailable == true else { return ("—", "SETUP NEEDED") }
            return (n(model.status.memoryCount), "STORED")
        case .threads:
            guard model.status.threadsAvailable == true else { return ("—", "SETUP NEEDED") }
            return (n(model.status.threadCount), "TRACKED")
        case .sessions:
            return model.claudeSessions.isEmpty ? ("—", "REFRESH") : (n(model.claudeSessions.count), "ON DISK")
        case .tasks:
            return model.tasks.isEmpty ? ("—", "REFRESH") : (n(model.tasks.count), "OPEN")
        }
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
        case .tasks:
            if model.tasks.isEmpty { return "Refresh to load" }
            let flagged = model.tasks.filter { $0.missed == true || $0.failed == true }.count
            return flagged > 0 ? "\(flagged) need attention" : "\(model.tasks.count) open"
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
        case .tasks: tasksList
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
            } else if !model.claudeSessionsEnabled && visibleSessions.isEmpty {
                // Off by default: the endpoint projects Claude Code's private 0700
                // state dir over a LAN-bound socket, so it is opt-in. Showing the
                // ordinary empty copy here made a switched-off feature look broken.
                emptyState(.sessions, text: "Claude sessions are switched off. Turn them on in Advanced \u{2192} Show Claude sessions.")
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

    private var tasksList: some View {
        VStack(spacing: 0) {
            sectionHeader(
                section: .tasks,
                title: "Tasks",
                detail: tasksStatus,
                refresh: { Task { await model.loadDomains(force: true); reconcileTaskDomain(); await model.loadTasks(force: true) } },
                refreshDisabled: model.tasksLoading
            )
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("Capture a task", text: $taskCapture)
                        .textFieldStyle(.roundedBorder)
                    // Server-resolved, not hardcoded: these were one user's
                    // four business units, so a second COS install had nothing
                    // it could file a task against. Falls back to the four only
                    // while an older server has no /api/domains to answer with.
                    Picker("Domain", selection: $taskDomain) {
                        ForEach(model.domainOptions) { option in
                            Text(option.label).tag(option.name)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Button("Capture") {
                        Task { await captureTask() }
                    }
                    .disabled(taskCapture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || taskBusy)
                }
                DatePicker("Run at", selection: $taskRunAt, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            if model.tasksLoading && model.tasks.isEmpty {
                centeredProgress("Loading tasks…")
            } else if let error = model.tasksError, model.tasks.isEmpty {
                emptyState(.tasks, text: error)
            } else if model.tasks.isEmpty {
                emptyState(.tasks, text: "No open tasks. Capture one above, or say \"save as task\" on the glasses.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.tasks) { task in
                            taskRow(task)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 22)
                }
            }
        }
    }

    private var tasksStatus: String {
        if model.tasksLoading { return "Loading…" }
        if let error = model.tasksError { return error }
        if let gate = model.status.tasksGate, gate != "ready" { return "Gate \(gate)" }
        return model.tasks.isEmpty ? "Nothing captured" : "\(model.tasks.count) open"
    }

    private func taskRow(_ task: TaskRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(COSType.body(13.5))
                Text([task.domain, task.column, task.section].joined(separator: " · "))
                    .font(COSType.body(11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if task.missed == true { Text("Missed").font(COSType.body(10.5)).foregroundStyle(.orange) }
            if task.failed == true { Text("Failed").font(COSType.body(10.5)).foregroundStyle(.red) }
            Button("Schedule") {
                Task { await scheduleTask(task) }
            }
            .disabled(taskBusy)
            Button("Run now") {
                Task { await runTask(task) }
            }
            .disabled(taskBusy)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Keeps `taskDomain` inside the resolved list.
    ///
    /// A SwiftUI Picker whose selection is not among its tags renders blank, and
    /// the default here is the literal "quilt" — a domain that exists on exactly
    /// one machine. Without this, a fresh install would show an empty picker and
    /// Capture would post a domain the server rejects as unknown.
    private func reconcileTaskDomain() {
        let names = model.domainOptions.map(\.name)
        guard !names.isEmpty else { return }
        if !names.contains(taskDomain) {
            taskDomain = names.first ?? taskDomain
        }
    }

    private func taskRunAtStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: taskRunAt)
    }

    private func captureTask() async {
        let text = taskCapture.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        taskBusy = true
        defer { taskBusy = false }
        do {
            try await model.captureTask(domain: taskDomain, text: text, runAt: taskRunAtStamp())
            taskCapture = ""
        } catch {
            model.tasksError = error.localizedDescription
        }
    }

    private func scheduleTask(_ task: TaskRow) async {
        taskBusy = true
        defer { taskBusy = false }
        do {
            try await model.scheduleTask(id: task.id, domain: task.domain, runAt: taskRunAtStamp())
        } catch {
            model.tasksError = error.localizedDescription
        }
    }

    private func runTask(_ task: TaskRow) async {
        taskBusy = true
        defer { taskBusy = false }
        do {
            try await model.runTask(id: task.id, domain: task.domain)
        } catch {
            model.tasksError = error.localizedDescription
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

    private var nextUnnamedReview: ReviewableMeeting? {
        guard let current = selectedSpeakerSessionID else { return nil }
        return model.nextUnnamedMeeting(after: current)
    }

    private func openNextUnnamedReview() {
        guard let next = nextUnnamedReview else { return }
        voiceParentName = nil
        selectedSpeakerSessionID = nil
        model.closeSpeakerReview()
        selectedSpeakerSessionID = next.sessionId
        model.openSpeakerReview(next)
    }

    /// Archived days, or search results when a search is active. Results REPLACE
    /// the day list rather than sitting beside it: a hit is a day, so showing both
    /// would render the same rows twice under two headings.
    @ViewBuilder private var archiveBody: some View {
        if let notice = model.archiveNotice {
            VStack(spacing: 8) {
                Image(systemName: model.archiveRouteAbsent ? "arrow.up.circle" : "exclamationmark.triangle")
                    .font(.system(size: 22)).foregroundStyle(.secondary)
                Text(notice)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.archiveLoading {
            centeredProgress("Reading the archive…")
        } else if !model.archiveHits.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    semanticSection
                    if let meta = model.archiveSearchMeta {
                        Text(meta)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 14).padding(.bottom, 6)
                    }
                    ForEach(model.archiveHits) { hit in
                        // A hit IS a day, so it opens the same day route as the
                        // date list. Finding a conversation by search and then
                        // being unable to open it is the same dead end twice.
                        Button { openArchiveDay(hit.date) } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(hit.date).font(.system(size: 12, weight: .semibold))
                                        Text("\(hit.matches) match\(hit.matches == 1 ? "" : "es")")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    ForEach(Array(hit.snippets.enumerated()), id: \.offset) { _, snippet in
                                        Text(snippet)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(3)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().opacity(0.4)
                    }
                }
                .padding(.top, 4)
            }
        } else if model.archiveResultIsThin && model.archiveDays.isEmpty {
            ScrollView { semanticSection.padding(.top, 8) }
        } else if model.archiveDays.isEmpty {
            emptyState(.messages, text: model.archiveQuery.isEmpty
                       ? "Nothing is archived yet. Conversations move here at the end of each day."
                       : "No archived day matched that search.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let meta = model.archiveSearchMeta {
                        Text(meta)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 14).padding(.bottom, 6)
                    }
                    ForEach(model.archiveDays) { day in
                        Button { openArchiveDay(day.date) } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 8) {
                                        Text(day.date).font(.system(size: 12, weight: .semibold))
                                        // Volume at a glance. A date list showing only the
                                        // latest line cannot tell a busy day from an idle one.
                                        Text(day.countsSummary)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    if let summary = day.summary, !summary.isEmpty {
                                        Text(summary)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            // The row is mostly empty space, and a plain button style
                            // hit-tests only rendered content, so without this the
                            // target is the date text rather than the whole row.
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().opacity(0.4)
                    }
                }
                .padding(.top, 4)
            }
        }
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
            // Recent vs Archive. Recent is what the glasses hold now; Archive is the
            // daily conversation store, which on a working install runs to months of
            // history that nothing in Control could reach before 0.5.72.
            HStack(spacing: 12) {
                Picker("Message view", selection: $messagesSubview) {
                    ForEach(MessagesSubview.allCases) { item in Text(item.title).tag(item) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                .onChange(of: messagesSubview) { _, next in
                    selectedTurnID = nil
                    // Switching Recent/Archive must also unwind the archive drill-
                    // through, or an open day would survive the switch and render
                    // under the Recent tab.
                    selectedArchiveDate = nil
                    selectedArchiveChat = nil
                    model.closeArchiveDay()
                    model.closeArchiveChat()
                    if next == .archive {
                        if model.archiveDays.isEmpty { Task { await model.loadArchiveDays() } }
                        runPendingArchiveSearch()
                    }
                }

                // ONE box for both surfaces. Recent filters as you type because
                // it is a handful of turns in memory; the archive is a real scan
                // of months, so it still runs on Return.
                TextField("Search recent and archive", text: $model.archiveQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit { Task { await model.runArchiveSearch() } }
                if model.archiveSearching { ProgressView().controlSize(.small) }
                if !model.archiveQuery.isEmpty {
                    Button("Clear") { model.clearArchiveSearch() }
                        .buttonStyle(.link).font(.system(size: 11))
                }
                Spacer()
                // The one control in Control that spends model tokens. It
                // lives beside the search it governs rather than in the
                // toolbar, and it carries its cost in its own tooltip.
                Toggle("Meaning", isOn: Binding(
                    get: { model.semanticSearchEnabled },
                    set: { model.setSemanticSearchEnabled($0) }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.system(size: 11))
                // Each concatenated chunk is a whole clause on purpose: a
                // phrase split across the + never appears in the source, so a
                // pin on it would be asserting where the line happens to wrap.
                .help("Search by meaning uses your Claude usage. "
                      + "Off is keyword only, with no model calls. "
                      + "On, Control offers it when a search comes up thin, "
                      + "and only asks when you tap. Up to 25 a day.")
            }
            .padding(.horizontal, 12)
            messageSearchCrossing
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 8)

            if messagesSubview == .archive {
                archiveBody
            } else if model.recentGlassesStatus == .loading {
                centeredProgress("Loading messages…")
            } else if model.recentMessages.isEmpty {
                emptyState(.messages, text: messagesEmptyCopy)
            } else if visibleRecentMessages.isEmpty {
                emptyState(.messages, text: recentMissCopy)
            } else {
                // 0.5.185 — the legend explains the two labels and says NOTHING
                // about a row that carries none: on a server that does not stamp
                // (before 6.43.4) the Mac's own brief is unlabeled, so any sentence
                // about unlabeled rows, positive or negative, would be false there.
                Text("ROUTINE and TASK mark a run your Mac started.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleRecentMessages) { turn in
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
                        if speakerSubview == .voices {
                            await model.loadVoiceDirectory(refresh: true)
                            await model.loadExtAudio()
                        }
                        else { await model.loadReviewableMeetings() }
                    }
                },
                refreshDisabled: speakerSubview == .voices ? model.voiceDirectoryLoading : model.meetingsLoading,
                refreshTitle: speakerRefreshTitle,
                refreshProminent: speakerSubview == .meetings && model.meetingsRefreshNeeded
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
                        if next == .voices {
                            await model.loadVoiceDirectory()
                            await model.loadExtAudio()
                        }
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
                } else {
                    Toggle("Hide reviewed", isOn: Binding(
                        get: { model.hideReviewedMeetings },
                        set: { model.setHideReviewed($0) }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help("Keep finished meetings off the list while you work through names.")
                    Menu {
                        Picker("Sort meetings", selection: Binding(
                            get: { model.meetingReviewSort },
                            set: { model.setMeetingReviewSort($0) }
                        )) {
                            ForEach(MeetingReviewSort.allCases) { sort in Text(sort.title).tag(sort) }
                        }
                    } label: {
                        Label(model.meetingReviewSort.title, systemImage: "arrow.up.arrow.down")
                    }
                    .fixedSize()
                    .help("Needs review first is the naming queue. Newest or oldest reads the list by capture time instead.")
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
            if model.reviewableMeetings.isEmpty {
                return "Choose a saved meeting to name its voices."
            }
            var parts = ["\(model.reviewableMeetings.count) recent saved meetings"]
            let unnamed = model.reviewableMeetings.filter {
                if case .needsNames = model.voiceTag(for: $0) { return true }
                return false
            }.count
            let fresh = model.reviewableMeetings.filter { model.isNewReviewableMeeting($0.sessionId) }.count
            let done = model.reviewableMeetings.filter {
                if case .reviewed = model.voiceTag(for: $0) { return true }
                return false
            }.count
            if unnamed > 0 { parts.append("\(unnamed) still need names") }
            if done > 0 { parts.append("\(done) reviewed") }
            if fresh > 0 { parts.append("\(fresh) new") }
            return parts.joined(separator: " · ")
        }
        if model.voiceDirectory.isEmpty { return "Enrolled identities and cross-meeting evidence." }
        if model.voiceDirectoryRouteAvailable == false {
            return "\(model.voiceDirectory.count) enrolled profiles · history unavailable on this server"
        }
        let review = model.voiceDirectory.reduce(0) { $0 + $1.reviewMeetingCount }
        return "\(model.voiceDirectory.count) enrolled · \(review) review occurrence\(review == 1 ? "" : "s")"
    }

    /// ADD A VOICE — the explicit surface for creating a NET-NEW profile.
    ///
    /// Naming an unidentified voice inside a meeting review already worked, but
    /// it can only ever rename a voice the system has already separated out. A
    /// user whose whole transcript came back `[Ext]` has nothing to rename and no
    /// reason to know the glasses voice command exists. Chelsie hit exactly that
    /// on 2026-08-24: latest server, model installed, 170 lines, all Ext.
    ///
    /// The audio is real meeting audio the server is already holding for 72
    /// hours, so this teaches from the same material a review would.
    ///
    /// Three things are stated before the user commits, all server behaviour and
    /// none of them guesses:
    ///   - a held session can contain MORE THAN ONE unknown speaker
    ///   - a successful enrolment CONSUMES the audio; there is no undo
    ///   - the window closes, and the countdown is the server's own
    /// Rows shown at natural height before the list starts scrolling in place.
    private static let extAudioInlineRowLimit = 5
    /// Height of the scrolling frame once the limit is passed. Roughly six rows,
    /// so the card stays a card and never becomes the whole window.
    private static let extAudioListHeight: CGFloat = 200

    /// Says how many are held once the list is capped, because a scrolling box
    /// hides its own length and "some audio" is not an amount.
    private var extAudioLead: String {
        let count = model.extAudioSessions.count
        if count > Self.extAudioInlineRowLimit {
            return "\(count) unrecognized sessions the server is holding. Naming one creates a new voice from it."
        }
        return "Unrecognized audio the server is holding. Naming a session creates a new voice from it."
    }

    @ViewBuilder
    private var addVoiceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("Add a voice", systemImage: "person.badge.plus")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.extAudioLoading { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await model.loadExtAudio() } }
                    .buttonStyle(.link).font(.system(size: 11))
                    .disabled(model.extAudioLoading)
            }

            if let result = model.addVoiceResult {
                Text(result).font(.system(size: 11)).foregroundStyle(.secondary)
            }

            if model.extAudioSessions.isEmpty {
                Text(model.extAudioError
                     ?? "No unrecognized audio is being held. Record a meeting, then come back within 72 hours.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text(extAudioLead)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                // BOUNDED, ALWAYS. The server holds unrecognized audio for 72
                // hours, so a busy week is dozens of sessions. This card sits
                // OUTSIDE the voice directory's ScrollView, so an uncapped
                // ForEach grew the whole layout past the window and carried the
                // section header, the view picker and the breadcrumbs off
                // screen with it. Reported in production 2026-08-26 with 30+
                // held sessions. Short lists keep their natural height; long
                // ones scroll inside a fixed frame instead of pushing chrome.
                if model.extAudioSessions.count > Self.extAudioInlineRowLimit {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(model.extAudioSessions) { session in
                                addVoiceRow(session)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: Self.extAudioListHeight)
                } else {
                    ForEach(model.extAudioSessions) { session in
                        addVoiceRow(session)
                    }
                }
                Text("A session can hold more than one unknown speaker, and naming it uses up the audio.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func addVoiceRow(_ session: ExtAudioSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(session.chunks) sample\(session.chunks == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium))
                Text("expires in \(session.expiresIn)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if model.addingVoiceSession != session.sessionId {
                    Button("Name this voice") { model.addingVoiceSession = session.sessionId }
                        .buttonStyle(.link).font(.system(size: 11))
                        .disabled(model.addVoiceBusy)
                }
            }
            if model.addingVoiceSession == session.sessionId {
                addVoiceNameField(session)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func addVoiceNameField(_ session: ExtAudioSession) -> some View {
        HStack(spacing: 6) {
            TextField("Who is this?", text: $addVoiceName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .frame(maxWidth: 180)
                .onSubmit { commitAddVoice(session) }
            Button("Save") { commitAddVoice(session) }
                .font(.system(size: 11))
                .disabled(model.addVoiceBusy
                          || addVoiceName.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
            Button("Cancel") {
                model.addingVoiceSession = nil
                addVoiceName = ""
            }
            .buttonStyle(.link).font(.system(size: 11))
            if model.addVoiceBusy { ProgressView().controlSize(.small) }
        }
    }

    private func commitAddVoice(_ session: ExtAudioSession) {
        let name = addVoiceName
        Task {
            await model.addVoice(named: name, from: session.sessionId)
            addVoiceName = ""
        }
    }

    @ViewBuilder
    private var voiceDirectoryList: some View {
        if model.voiceDirectoryLoading && model.voiceDirectory.isEmpty {
            centeredProgress("Building the voice directory…")
        } else if model.voiceDirectory.isEmpty {
            // ADD-A-VOICE IS SHOWN HERE TOO, and this is the case that matters.
            // A user with zero profiles is exactly who needs it, and an empty
            // state that only explains the problem is what sent Chelsie to
            // Discord instead of to the fix.
            VStack(spacing: 10) {
                emptyState(.speakers, text: model.voiceDirectoryError ?? "No voice profiles are enrolled yet.")
                addVoiceSection
            }
        } else {
            VStack(spacing: 0) {
                if let error = model.voiceDirectoryError {
                    directoryNotice(error, stale: model.voiceDirectoryRouteAvailable != false)
                }
                addVoiceSection
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
            } else if model.visibleReviewableMeetings.isEmpty {
                emptyState(.speakers, text: "All recent meetings are reviewed. Turn off Hide reviewed to see them.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visibleReviewableMeetings) { meeting in
                            Button {
                                voiceParentName = nil
                                selectedSpeakerSessionID = meeting.sessionId
                                model.openSpeakerReview(meeting)
                            } label: {
                                HStack(spacing: 13) {
                                    sectionGlyph(.speakers)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(meeting.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                        Text(meeting.dateLine)
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        Text(meeting.countsSummary).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    meetingStatusTags(meeting)
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
        refreshTitle: String = "Refresh",
        refreshProminent: Bool = false,
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
            refreshTitle: refreshTitle,
            refreshProminent: refreshProminent,
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
        refreshTitle: String = "Refresh",
        refreshProminent: Bool = false,
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
            Button(refreshTitle, systemImage: "arrow.clockwise", action: refresh)
                .disabled(refreshDisabled)
                .tint(refreshProminent ? COSPalette.amber : Color.accentColor)
        }
        .controlSize(.small)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(item.tint.opacity(0.055))
        .overlay(alignment: .bottom) { Divider() }
    }

    /// The section mark inside an open pane.
    ///
    /// Same stroked `SectionGlyph` the gateway and the rail use, so a pane does not
    /// present a different vocabulary for the same six things. The tinted chip it replaced
    /// was six pastel squares carrying no information — the section is already named in
    /// the breadcrumb and the rail beside it.
    ///
    /// Frame sizes are unchanged at 32/42pt: eight call sites lay out around this, and a
    /// visual change should not become a layout change.
    /// Tint per attachment category, drawn from the Activity section palette
    /// so the badge speaks a color the app already uses.
    private func attachmentTint(_ category: String) -> Color {
        switch category {
        case "video": return ActivitySection.memories.tint
        case "document": return ActivitySection.meetings.tint
        case "photo": return ActivitySection.threads.tint
        default: return ActivitySection.messages.tint
        }
    }

    /// The message bubble wearing a filled type mark on its corner.
    ///
    /// The glyph grows 16 -> 20pt INSIDE the existing 32pt frame, so the badge
    /// has room without any row moving. The mark sits over a background-colored
    /// halo so it reads against the bubble stroke rather than merging with it.
    private func messageGlyph(_ turn: GlassesTurn) -> some View {
        ZStack(alignment: .bottomTrailing) {
            SectionGlyph(section: .messages)
                .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .foregroundStyle(.secondary)
                .frame(width: turn.attachmentCategory == nil ? 16 : 20,
                       height: turn.attachmentCategory == nil ? 16 : 20)
            if let category = turn.attachmentCategory {
                AttachmentMark(category: category)
                    .fill(attachmentTint(category))
                    .frame(width: 11, height: 11)
                    .padding(1.7)
                    .background(Circle().fill(COSPalette.panel))
                    .offset(x: 5, y: 5)
            }
        }
        .frame(width: 32, height: 32)
    }

    private func sectionGlyph(_ item: ActivitySection, large: Bool = false) -> some View {
        SectionGlyph(section: item)
            .stroke(style: StrokeStyle(lineWidth: large ? 1.6 : 1.4, lineCap: .round, lineJoin: .round))
            .foregroundStyle(.secondary)
            .frame(width: large ? 21 : 16, height: large ? 21 : 16)
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
            messageGlyph(turn)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(turn.no.map { "Message #\($0)" } ?? "Message")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(turn.timeLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    // 0.5.185 — two tertiary segments, each omitted when unknown.
                    // The label comes first: it is the one thing that changes
                    // what the row IS. A row with no label says nothing on a
                    // server that does not stamp; nothing is inferred from it.
                    if let origin = turn.originLabel {
                        Text(origin)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(0.6)
                            .foregroundStyle(.tertiary)
                            .help(turn.originTitle ?? "")
                    }
                    if let modelLabel = turn.modelLabel {
                        Text(modelLabel)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    if let glyph = turn.attachmentGlyph {
                        Label("\(turn.attachments.count)", systemImage: glyph)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .help(turn.attachmentSummary ?? "")
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

    /// One archived DAY: the chats it holds, each opening its own transcript.
    @ViewBuilder private func archiveDayDetail(date: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                sectionGlyph(.messages, large: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(date).font(.system(size: 19, weight: .semibold))
                    Text(archiveDaySubtitle(date: date))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)

            Divider().opacity(0.5)

            if model.archiveChatsLoading {
                centeredProgress("Reading \(date)…")
            } else if let notice = model.archiveChatsNotice {
                emptyState(.messages, text: notice)
            } else if model.archiveChats.isEmpty {
                emptyState(.messages, text: "No conversations were archived on \(date).")
            } else {
                if !model.archiveChatsQuery.isEmpty {
                    archiveDaySearchBar(date: date)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleArchiveChats) { chat in
                            Button { openArchiveChat(date: date, index: chat.index) } label: {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        // The TOPIC leads. "Chat 1 … Chat 11" is
                                        // an ordinal, not a memory aid, and every
                                        // opening line starts the same way.
                                        HStack(spacing: 8) {
                                            Text(chat.headline)
                                                .font(.system(size: 12, weight: .semibold))
                                                .lineLimit(1)
                                            if chat.matches > 0 {
                                                Text("\(chat.matches) match\(chat.matches == 1 ? "" : "es")")
                                                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                                    .foregroundStyle(COSPalette.cream)
                                                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                                                    .background(Capsule().fill(COSPalette.green))
                                            }
                                        }
                                        // 1-based for display only. The index is
                                        // the server's array position and stays
                                        // 0-based everywhere it is sent.
                                        Text("Chat \(chat.index + 1) · \(chat.timeLabel) · \(chat.countLabel)")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        // A matched chat shows WHY it matched;
                                        // otherwise the opening line still reads.
                                        if !chat.snippet.isEmpty {
                                            Text(chat.snippet)
                                                .font(.system(size: 11))
                                                .foregroundStyle(.primary)
                                                .lineLimit(3)
                                                .fixedSize(horizontal: false, vertical: true)
                                        } else if let summary = chat.summary, !summary.isEmpty {
                                            Text(summary)
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().opacity(0.4)
                        }
                        if visibleArchiveChats.isEmpty {
                            Text("No chat on this day contains \"\(model.archiveChatsQuery)\".")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    /// Chats shown for the open day: everything, or only those that matched the
    /// search that got you here.
    private var visibleArchiveChats: [ArchiveChat] {
        guard model.archiveOnlyMatches, !model.archiveChatsQuery.isEmpty else {
            return model.archiveChats
        }
        return model.archiveChats.filter { $0.matches > 0 }
    }

    /// The search that found this day, carried in and made actionable.
    @ViewBuilder private func archiveDaySearchBar(date: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\"\(model.archiveChatsQuery)\" · \(model.archiveMatchingChats) of \(model.archiveChats.count) chat\(model.archiveChats.count == 1 ? "" : "s")")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if model.archiveMatchingChats > 0 {
                Toggle("Only matches", isOn: $model.archiveOnlyMatches)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 10.5))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        Divider().opacity(0.4)
    }

    /// Counts come from the day list rather than being recomputed, so the header
    /// stays honest while the chats are still loading.
    private func archiveDaySubtitle(date: String) -> String {
        if let day = model.archiveDays.first(where: { $0.date == date }) {
            return day.countsSummary
        }
        let count = model.archiveChats.count
        return "\(count) chat\(count == 1 ? "" : "s")"
    }

    /// One archived CHAT, rendered as the full conversation. The chat is the unit
    /// a person remembers, so its turns read as a transcript here rather than
    /// making them tap once more per exchange.
    @ViewBuilder private func archiveChatDetail(date: String, index: Int) -> some View {
        if model.archiveMessagesLoading {
            centeredProgress("Reading chat \(index + 1)…")
        } else if let notice = model.archiveMessagesNotice {
            emptyState(.messages, text: notice)
        } else if model.archiveMessages.isEmpty {
            emptyState(.messages, text: "That chat holds no messages.")
        } else {
            // ScrollViewReader so a match can be JUMPED to. Finding the day,
            // then the chat, and then scrolling a 28-message transcript by eye
            // was the last rung of the same dead end (Miles, 2026-08-31).
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                // The bar stays put while the transcript scrolls: losing sight
                // of what you searched for halfway down is the whole problem.
                chatSearchBar(proxy: proxy)
                    .padding(.horizontal, 28).padding(.top, 14).padding(.bottom, 10)
                Divider().opacity(0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .top) {
                            sectionGlyph(.messages, large: true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Chat \(index + 1)")
                                    .font(.system(size: 19, weight: .semibold))
                                Text("\(date) · \(model.archiveMessages.count) message\(model.archiveMessages.count == 1 ? "" : "s")")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }

                        ForEach(model.archiveMessages) { message in
                            let hit = chatQuery.count >= 2 && messageMatches(message)
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Text(message.title)
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(message.timeLabel)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    if hit {
                                        Text("match")
                                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(COSPalette.cream)
                                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                                            .background(Capsule().fill(COSPalette.green))
                                    }
                                    Spacer()
                                    Button("Copy turn") { model.copyArchiveMessage(message) }
                                        .controlSize(.small)
                                }
                                messageBlock(label: "You", text: message.query,
                                             tint: ActivitySection.messages.tint, highlight: chatQuery)
                                messageBlock(label: "COS", text: message.text,
                                             tint: COSPalette.green, highlight: chatQuery)
                            }
                            .padding(hit ? 10 : 0)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(hit ? COSPalette.green.opacity(0.07) : .clear)
                            )
                            .id(message.id)
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                }
                // The term that found the day is the term you are still looking
                // for; seed it rather than making it be typed a third time.
                .onAppear { if chatQuery.isEmpty { chatQuery = model.archiveChatsQuery } }
            }
        }
    }

    /// The count for the side you are NOT on. Both numbers answer the same term,
    /// so the answer to "is it here or back there" is on screen before you cross.
    @ViewBuilder private var messageSearchCrossing: some View {
        let q = model.archiveQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.count >= SearchMark.minimumQuery {
            HStack(spacing: 7) {
                crossingCount(.recent, value: "\(visibleRecentMessages.count)")
                Text("·").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                crossingCount(.archive, value: archiveCountLabel(for: q))
                if let meta = model.archiveSearchMeta, messagesSubview == .archive {
                    Text(meta)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
    }

    /// Its own side is a label; the other side is the door.
    @ViewBuilder private func crossingCount(_ side: MessagesSubview, value: String) -> some View {
        let text = Text("\(side.title) \(value)")
            .font(.system(size: 10.5, design: .monospaced))
        if messagesSubview == side {
            text.foregroundStyle(.secondary)
        } else {
            Button {
                messagesSubview = side
                selectedTurnID = nil
                selectedArchiveDate = nil
                selectedArchiveChat = nil
                model.closeArchiveDay()
                model.closeArchiveChat()
                if side == .archive {
                    if model.archiveDays.isEmpty { Task { await model.loadArchiveDays() } }
                    runPendingArchiveSearch()
                }
            } label: {
                HStack(spacing: 3) {
                    text
                    Image(systemName: "arrow.right").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(COSPalette.gold)
            }
            .buttonStyle(.plain)
        }
    }

    /// Never report a count the current term did not earn: until the scan runs,
    /// say what to press instead of showing the previous term's answer.
    private func archiveCountLabel(for query: String) -> String {
        if model.archiveSearching { return "…" }
        guard model.archiveHitsQuery == query else { return "press return" }
        let n = model.archiveHits.count
        return n == 1 ? "1 day" : "\(n) days"
    }

    private func runPendingArchiveSearch() {
        let q = model.archiveQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= SearchMark.minimumQuery, model.archiveHitsQuery != q else { return }
        Task { await model.runArchiveSearch() }
    }

    /// A miss in Recent is only half an answer while the archive holds months.
    private var recentMissCopy: String {
        let q = model.archiveQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.archiveHitsQuery == q, !model.archiveHits.isEmpty else {
            return "No recent message contains \"\(recentQuery)\". The archive goes back further."
        }
        let n = model.archiveHits.count
        return "No recent message contains \"\(recentQuery)\", but \(n) archived "
            + "day\(n == 1 ? "" : "s") do."
    }

    /// Recent turns matching the recent-view query, on either side of the turn.
    private var visibleRecentMessages: [GlassesTurn] {
        model.recentMessages.filter {
            SearchMark.matches(query: recentQuery, in: [$0.query, $0.text])
        }
    }

    /// Does this turn contain the in-chat query, on either side of it?
    private func messageMatches(_ message: ArchiveMessage) -> Bool {
        guard chatQuery.trimmingCharacters(in: .whitespacesAndNewlines).count >= SearchMark.minimumQuery
        else { return false }
        return SearchMark.matches(query: chatQuery, in: [message.query, message.text])
    }

    private var chatMatchIDs: [ArchiveMessage.ID] {
        model.archiveMessages.filter { messageMatches($0) }.map(\.id)
    }

    /// Search WITHIN one transcript, with jump-to-match. The chat is the last
    /// place the term can hide, and a 28-message chat is too long to scan.
    @ViewBuilder private func chatSearchBar(proxy: ScrollViewProxy) -> some View {
        let ids = chatMatchIDs
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Find in this chat", text: $chatQuery)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 260)
                .onSubmit { jumpToMatch(step: 1, ids: ids, proxy: proxy) }
            if chatQuery.count >= 2 {
                Text(ids.isEmpty ? "no matches"
                     : "\(min(chatMatchCursor + 1, ids.count)) of \(ids.count)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button { jumpToMatch(step: -1, ids: ids, proxy: proxy) } label: {
                    Image(systemName: "chevron.up")
                }
                .controlSize(.small).disabled(ids.isEmpty)
                Button { jumpToMatch(step: 1, ids: ids, proxy: proxy) } label: {
                    Image(systemName: "chevron.down")
                }
                .controlSize(.small).disabled(ids.isEmpty)
                Button("Clear") { chatQuery = ""; chatMatchCursor = 0 }
                    .buttonStyle(.link).controlSize(.small)
            }
            Spacer()
        }
    }

    /// Move the cursor and scroll. Wraps at both ends so a match is never a
    /// dead end at the bottom of a transcript.
    private func jumpToMatch(step: Int, ids: [ArchiveMessage.ID], proxy: ScrollViewProxy) {
        guard !ids.isEmpty else { return }
        chatMatchCursor = ((chatMatchCursor + step) % ids.count + ids.count) % ids.count
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(ids[chatMatchCursor], anchor: .center)
        }
    }

    private func messageDetail(_ turn: GlassesTurn) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    sectionGlyph(.messages, large: true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(turn.no.map { "Message #\($0)" } ?? "Message")
                            .font(.system(size: 19, weight: .semibold))
                        Text(turn.detailMetaLine)
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

                messageBlock(label: "You", text: turn.query,
                             tint: ActivitySection.messages.tint, highlight: recentQuery)
                attachmentStrip(attachments: turn.attachments.filter(\.isUserPhoto), fallback: "Your attachments")
                messageBlock(label: "COS", text: turn.text,
                             tint: COSPalette.green, highlight: recentQuery)
                attachmentStrip(attachments: turn.attachments.filter { !$0.isUserPhoto }, fallback: "From COS")
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// Offered on its own when the keyword answer comes back thin, because
    /// that is the moment you would otherwise conclude the conversation never
    /// happened. The offer appears automatically; the CALL never does — it
    /// spends model tokens, so it waits for a tap (Miles, 2026-08-31).
    @ViewBuilder private var semanticSection: some View {
        if model.archiveResultIsThin || !model.archiveSemanticHits.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(COSPalette.gold)
                    if model.archiveSemanticRunning {
                        Text("Looking for related days…")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        ProgressView().controlSize(.small)
                    } else if !model.semanticSearchEnabled {
                        Text("Search by meaning is off.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("Turn it on") { model.setSemanticSearchEnabled(true) }
                            .controlSize(.small)
                            .help("Uses your Claude usage. Up to 25 a day.")
                    } else {
                        Text(model.archiveHits.isEmpty
                             ? "No exact match. Try searching by meaning?"
                             : "Only one day matched. Try searching by meaning?")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("Search by meaning") {
                            Task { await model.runArchiveSemantic() }
                        }
                        .controlSize(.small)
                    }
                    Spacer()
                }
                if let notice = model.archiveSemanticNotice {
                    Text(notice).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                // Always its own labelled section: a guess and an exact match
                // must never read as the same kind of answer.
                ForEach(model.archiveSemanticHits) { hit in
                    Button { openArchiveDay(hit.date) } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(hit.date).font(.system(size: 12, weight: .semibold))
                                    Text("related")
                                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(COSPalette.cream)
                                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                                        .background(Capsule().fill(COSPalette.gold))
                                    Text("\(hit.chatCount) chats")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Text(hit.why).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(COSPalette.card.opacity(0.5))
            Divider().opacity(0.5)
        }
    }

    /// Marks every occurrence of the query inside the text. A tinted ROW says
    /// "somewhere in here"; this says exactly where, which is the difference
    /// between finding a passage and re-reading a chat (Miles, 2026-08-31).
    /// Yellow on dark, amber on light — both carry dark ink, so the mark reads
    /// at a glance in either scheme rather than blending into the card.
    private func highlighted(_ text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        let fill = colorScheme == .dark
            ? Color(red: 1.0, green: 0.85, blue: 0.30)
            : Color(red: 1.0, green: 0.80, blue: 0.20)
        for r in SearchMark.ranges(in: text, query: query) {
            if let lo = AttributedString.Index(r.lowerBound, within: attributed),
               let hi = AttributedString.Index(r.upperBound, within: attributed) {
                attributed[lo..<hi].backgroundColor = fill
                attributed[lo..<hi].foregroundColor = Color.black
            }
        }
        return attributed
    }

    private func messageBlock(
        label: String, text: String, tint: Color, highlight: String = ""
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(.primary)
            Text(text.isEmpty ? AttributedString("(empty)") : highlighted(text, query: highlight))
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(17)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(tint.opacity(0.22), lineWidth: 1))
    }

    /// Titles itself from what it holds, because a turn can now carry a video
    /// or a file, not just an image -- a hardcoded "Your image" over a .mov
    /// would be the same lie the old parser told by dropping it.
    private func attachmentStrip(attachments: [GlassesAttachmentRef], fallback: String) -> some View {
        let title = Set(attachments.map(\.category)).count == 1
            ? (attachments.first?.displayLabel ?? fallback)
            : fallback
        return Group {
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
                                        // A video's `thumb` variant is a real
                                        // JPEG poster frame, so this renders
                                        // for video exactly as for a photo.
                                        Image(nsImage: image)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                    case .unavailable:
                                        // A text file has no poster to fetch.
                                        // That is expected, not an error state.
                                        Image(systemName: attachment.isDocument
                                              ? "doc.text"
                                              : (attachment.isVideo ? "film" : "photo.badge.exclamationmark"))
                                            .font(.system(size: 21))
                                            .foregroundStyle(.secondary)
                                    case .loading, nil:
                                        ProgressView().controlSize(.small)
                                    }
                                    if attachment.isVideo {
                                        // Reads as a video at a glance, and
                                        // says how long before you commit to
                                        // launching a player.
                                        Image(systemName: "play.circle.fill")
                                            .font(.system(size: 27))
                                            .foregroundStyle(.white.opacity(0.93))
                                            .shadow(radius: 3)
                                    }
                                    if let badge = attachment.durationLabel ?? attachment.sizeLabel {
                                        VStack {
                                            Spacer()
                                            HStack {
                                                Spacer()
                                                Text(badge)
                                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                                    .foregroundStyle(.white)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 2)
                                                    .background(Color.black.opacity(0.62), in: Capsule())
                                                    .padding(6)
                                            }
                                        }
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
        if model.reviewableMeetings.isEmpty { await model.loadReviewableMeetings() }
        if model.voiceDirectory.isEmpty { await model.loadVoiceDirectory() }
        if model.extAudioSessions.isEmpty { await model.loadExtAudio() }
        if model.status.memoryAvailable == true, model.memoryRecords.isEmpty {
            await model.loadContextRecords(kind: "memory")
        }
        if model.status.threadsAvailable == true, model.threadRecords.isEmpty {
            await model.loadContextRecords(kind: "thread")
        }
        if model.claudeSessions.isEmpty { await model.loadClaudeSessions() }
        if model.tasks.isEmpty { await model.loadTasks(force: true) }
        await model.loadDomains()
        reconcileTaskDomain()
    }

    private func load(_ item: ActivitySection) async {
        switch item {
        case .messages: await model.refreshRecentMessages()
        case .speakers:
            if speakerSubview == .voices {
                await model.loadVoiceDirectory()
                await model.loadExtAudio()
            }
            else { await model.loadReviewableMeetings() }
        case .meetings:
            await model.loadLibraryMeetings()
            if model.reviewableMeetings.isEmpty {
                await model.loadReviewableMeetings()
            }
        case .memories:
            if model.status.memoryAvailable == true { await model.loadContextRecords(kind: "memory") }
        case .threads:
            if model.status.threadsAvailable == true { await model.loadContextRecords(kind: "thread") }
        case .sessions:
            await model.loadClaudeSessions()
        case .tasks:
            await model.loadDomains()
            reconcileTaskDomain()
            await model.loadTasks(force: true)
        }
    }

    private var speakerPeekKey: String {
        "\(section?.rawValue ?? "home")-\(speakerSubview.rawValue)-\(selectedSpeakerSessionID ?? "")"
    }

    private var speakerRefreshTitle: String {
        guard speakerSubview == .meetings, model.meetingsRefreshNeeded else { return "Refresh" }
        let count = model.pendingNewMeetingCount
        if count == 1 { return "Refresh · 1 new recording" }
        if count > 1 { return "Refresh · \(count) new recordings" }
        return "Refresh needed"
    }

    private func peekMeetingsIfNeeded() async {
        guard section == .speakers, speakerSubview == .meetings, selectedSpeakerSessionID == nil else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled else { return }
            guard section == .speakers, speakerSubview == .meetings, selectedSpeakerSessionID == nil else { return }
            await model.peekReviewableMeetings()
        }
    }

    private func meetingStatusTags(_ meeting: ReviewableMeeting) -> some View {
        MeetingStatusPills(
            isNew: model.isNewReviewableMeeting(meeting.sessionId),
            tag: model.voiceTag(for: meeting)
        )
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
            }
            if let row = model.openClaudeRow {
                Divider()
                HStack(spacing: 10) {
                    Button("Open in platform") { model.openSessionInPlatform(row) }
                    if let detail = model.claudeSessionDetail {
                        Button("Copy session") { model.copyClaudeSession() }
                            .disabled(detail.copyText.isEmpty)
                        Spacer()
                        Text("Kickstart brief for another agent. Not a Claude Code resume.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    } else {
                        Spacer()
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
            }
            // At the pane ROOT, outside the `if let detail` branch, so the
            // composer renders on the local-transcript-error path too — a
            // Desktop-store session has no local JSONL, and it is exactly the
            // session the server-side Continue can still reach.
            SessionChatComposer(model: model)
        }
        .cosConfirm(
            "Send into an open session?",
            isPresented: Binding(
                get: { model.chatCautionPending },
                set: { if !$0 { model.cancelChatCaution() } }
            ),
            message: "Another app on this Mac has this session open. It looks idle right now, but a reply will run with that session's own permissions.",
            actions: [
                .destructive("Send anyway") { model.confirmChatCaution() },
                .cancel(),
            ]
        )
    }

    private static func tint(_ provider: String) -> Color {
        switch provider {
        case "codex": Color(red: 0.10, green: 0.55, blue: 0.48)
        case "cursor": Color(red: 0.42, green: 0.38, blue: 0.86)
        default: Color(red: 0.78, green: 0.45, blue: 0.22)
        }
    }
}

/// Text-only continue under the Session view (0.5.75). Renders only when the
/// server publishes the session's provider as bindable AND the Continue toggle
/// is on — the gate message otherwise. Refusals are verdicts: the server copy
/// renders verbatim (Text(verbatim:) — the LocalizedStringKey overload parses
/// markdown) with the composer disabled, never a spinner.
struct SessionChatComposer: View {
    @ObservedObject var model: ControllerModel

    var body: some View {
        if let session = model.openClaudeRow {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                if let gate = model.sessionChatGateMessage(for: session) {
                    Text(gate)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                } else {
                    chatBody
                }
            }
        }
    }

    @ViewBuilder
    private var chatBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.chatMessages) { message in
                switch message.role {
                case .user:
                    HStack {
                        Spacer(minLength: 60)
                        Text(verbatim: message.text)
                            .font(.system(size: 12.5))
                            .textSelection(.enabled)
                            .padding(10)
                            .background(ActivitySection.sessions.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                    }
                case .assistant:
                    HStack {
                        Text(verbatim: message.text)
                            .font(.system(size: 12.5))
                            .textSelection(.enabled)
                            .padding(10)
                            .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 11))
                        Spacer(minLength: 60)
                    }
                case .status:
                    Text(verbatim: message.text)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if model.chatPolling {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working — it keeps running if you close this window.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if model.chatForking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Forking — copying this thread and running your message there…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if let refusal = model.chatRefusal {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: refusal)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    if let supplement = model.chatSupplement {
                        Text(verbatim: supplement)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 8) {
                        if model.chatChangedRevision != nil {
                            Button("Refresh") { model.refreshChatTranscript() }
                            Button("Continue anyway") { model.continueChatAnyway() }
                        }
                        if model.chatRetryAvailable {
                            Button("Retry") { model.retryChatTurn() }
                        }
                        if model.chatForkAvailable {
                            Button("Fork with this message") { model.forkChatThread() }
                                .disabled(model.chatForkPrompt.isEmpty || model.chatForking)
                                .help("Runs your message in a copy of this thread. The original is untouched.")
                        }
                    }
                    .controlSize(.small)
                    if model.chatForkAvailable && model.chatForkPrompt.isEmpty && !model.chatForking {
                        Text("Type a message below to fork with it.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Continue this session…", text: $model.chatDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .disabled(model.chatSending || model.chatPolling || model.chatForking)
                    .onSubmit { model.sendChatMessage() }
                Button("Send") { model.sendChatMessage() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.chatSending || model.chatPolling || model.chatForking
                        || model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if model.chatVerdict?.caution == true {
                Text("Another app on this Mac has this session open. COS will ask before the first send.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

struct MeetingStatusPills: View {
    let isNew: Bool
    let tag: MeetingVoiceTag?

    var body: some View {
        HStack(spacing: 6) {
            if isNew { pill("New", COSPalette.amber) }
            switch tag {
            case .reviewed:
                pill("Reviewed", COSPalette.green)
            case .needsNames(let count):
                pill(count == 1 ? "1 to name" : "\(count) to name", COSPalette.amber)
            case nil:
                EmptyView()
            }
        }
    }

    private func pill(_ text: String, _ tint: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}
