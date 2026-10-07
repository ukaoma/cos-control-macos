import AppKit
import SwiftUI
import WebKit

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

    /// 0.5.254 (Miles, 2026-10-01: resizing Work lagged): the window's content limits are set here, and the hosting
    /// controller no longer works them out. Its default sizing (.standardBounds) measured the whole Activity tree for its
    /// minimum and maximum on every layout pass, about half of each resize step. Measured with that sizing for home and
    /// every tab (Tests/run-activity-sizing.sh measure): minimum 760 x 560, the root frame's own, and no maximum. The
    /// window holds that minimum itself (ActivityHostWindow); Tests/run-activity-sizing.sh check holds it to what every
    /// tab needs.
    static let contentMinSize = NSSize(width: 760, height: 560)
    static let hostingSizing: NSHostingSizingOptions = []

    /// The Activity window, built and not shown: show() puts it on screen, and the sizing check measures it.
    static func makeWindow(model: ControllerModel) -> NSWindow {
        let hostingController = NSHostingController(rootView: ActivityWindow.live(model: model))
        hostingController.sizingOptions = hostingSizing
        let window = ActivityHostWindow(contentViewController: hostingController)
        window.contentFloor = contentMinSize
        window.title = "COS Activity"
        window.setContentSize(NSSize(width: 920, height: 680))
        // 0.5.222 — a CONTENT minimum. `minSize` counts the title bar, so the content could
        // shrink to about 532 pt while the root view asks for 560, and the root overflowed.
        window.contentMinSize = contentMinSize
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        return window
    }

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

        let window = Self.makeWindow(model: model)
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
        model?.stopGraphBuildPoll()
        model?.closeContextDetail()
        model?.closeLibraryDetail()
        // Session chat holds a poll Task and a live binding reference; a
        // window close must not leave either running against a stale row.
        model?.closeClaudeSession()
        windowController = nil
    }
}

/// 0.5.254: the Activity window never takes a content minimum below its floor. With the hosting controller's size
/// tracking off, the hosting view writes a zero minimum to its window as it lays out (measured: three times while the
/// window opens and resizes), which let the window shrink to 100 x 100 when asked; before, its own tracking wrote
/// SwiftUI's 760 x 560 over the explicit minimum each time instead.
final class ActivityHostWindow: NSWindow {
    var contentFloor = NSSize.zero { didSet { contentMinSize = super.contentMinSize } }
    override var contentMinSize: NSSize {
        get { super.contentMinSize }
        set { super.contentMinSize = NSSize(width: max(newValue.width, contentFloor.width), height: max(newValue.height, contentFloor.height)) }
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
    case work

    /// The same collection drives menu chips, Activity home and its peer rail.
    /// Work is the production Tasks home. A rollback switch preserves the old pane.
    static func visibleSections(environment: [String: String]) -> [ActivitySection] {
        let existing: [ActivitySection] = [.messages, .speakers, .meetings, .memories, .threads, .sessions, .tasks]
        return environment["COS_CONTROL_WORK_DISABLED"] == "1" ? existing : existing.map { $0 == .tasks ? .work : $0 }
    }
    static var allCases: [ActivitySection] { visibleSections(environment: ProcessInfo.processInfo.environment) }

    /// Keep old task launch links and session-pet actions useful after Work takes
    /// over the top-level slot. The caller still knows this requested Tasks.
    static func resolvedLaunch(_ requested: ActivitySection, environment: [String: String]) -> ActivitySection {
        requested == .tasks && environment["COS_CONTROL_WORK_DISABLED"] != "1" ? .work : requested
    }

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
        case .work: "Work"
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
        case .work: "tray.full"
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
        case .work: COSPalette.gold
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
        case .work: "Manage your tasks and turn meeting decisions into prepared work."
        }
    }
}

enum ActivityWorkSubview: String, CaseIterable, Identifiable {
    case tasks
    case meetingFollowUp
    var id: String { rawValue }
    var title: String { self == .tasks ? "Tasks" : "Meeting follow-up" }
}


private enum MessagesSubview: String, CaseIterable, Identifiable {
    case recent
    case archive

    var id: String { rawValue }
    var title: String { self == .archive ? "Archive" : "Recent" }
}

/// Memories is four peer views behind one picker (0.5.190). All memories is the
/// 0.5.189 list unchanged; the other three read server 6.44.5. Knowledge is a
/// PEER segment, not a nested browser.
private enum MemoriesSubview: String, CaseIterable, Identifiable {
    case recentLearning
    case allMemories
    case toReview
    case knowledge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentLearning: "Recent learning"
        case .allMemories: "All memories"
        case .toReview: "To review"
        case .knowledge: "Knowledge"
        }
    }
}

/// 0.5.222 — three views (Miles, 2026-09-13: "meetings to review, voice samples to
/// review, and voices would show us the active speakers"). Add a voice used to sit on top
/// of the voice directory, where it could not shrink: it squeezed the enrolled speakers to
/// nothing and pushed the toolbar and breadcrumbs off the window.
private enum SpeakerSubview: String, CaseIterable, Identifiable {
    case meetings
    case samples
    case voices

    var id: String { rawValue }
    /// The segmented control's label.
    var title: String {
        switch self {
        case .meetings: "Meetings to review"
        case .samples: "Samples to review"
        case .voices: "Voices"
        }
    }
    /// The pane hero's title.
    var headerTitle: String {
        switch self {
        case .meetings: "Meetings to review"
        case .samples: "Samples to review"
        case .voices: "Voice directory"
        }
    }
}

private enum VoiceDirectorySort: String, CaseIterable, Identifiable {
    case attention
    case recent
    case meetings
    case samples
    case confidence
    case name

    var id: String { rawValue }
    var title: String {
        switch self {
        case .attention: "Needs attention"
        case .recent: "Recently heard"
        case .meetings: "Most meetings"
        case .samples: "Most samples"
        case .confidence: "Lowest confidence"
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
    var isolatedWorkPreview = false
    @StateObject private var handoffStore = WorkHandoffStore()
    @StateObject private var reviewStore = WorkReviewStore()
    @StateObject private var workWorkspaceState = WorkWorkspaceState()
    @State private var showingLinkedSession = false
    @State private var historicalWorkID: String?
    private var connectedWorkTest: Bool {
        !isolatedWorkPreview && ProcessInfo.processInfo.environment["COS_WORK_CONNECTED_TEST"] == "1"
    }
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
    @State private var workSubview: ActivityWorkSubview = .tasks
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
    /// The default stays .allMemories in 0.5.190; the flip to Recent learning
    /// is 0.5.191 (open decision 1), so today's Memories tab renders as before.
    @State private var memoriesSubview: MemoriesSubview = .allMemories
    @State private var selectedLearningID: String?
    @State private var selectedGraphEntityID: String?
    /// Name being typed into Add a voice. Local to the view: it is transient and
    /// must not survive a tab switch.
    @State private var addVoiceName = ""
    /// 0.5.218 — which held chunk each Add-a-voice row is positioned on.
    @State private var heldSampleCursor: [String: Int] = [:]
    /// 0.5.219 — Listen cursor per held GROUP (and "loose"), the name being typed
    /// for a group, and the armed Discard. All transient to the view.
    @State private var heldGroupCursor: [String: Int] = [:]
    @State private var heldGroupName = ""
    @State private var confirmingHeldDiscard: String?
    @State private var heldNamingHistoryOpen = false
    @State private var heldNamingResultOpen = false
    @State private var heldNamingUndoHandle: String?
    @State private var voiceSearch = ""
    @State private var voiceSort: VoiceDirectorySort = .attention
    @State private var selectedContextID: String?
    @State private var selectedLibraryRecordID: String?
    @State private var meetingReturnWorkID: String?
    @State private var meetingReturnToWork = false
    @State private var meetingWorkLoaded = false
    @State private var selectedSessionID: String?
    @State private var taskCapture = ""
    @State private var taskDomain = "quilt"
    /// The task whose detail is open. Its own route flag, written only by
    /// openTaskDetail, so a board refresh cannot close the sheet under the user.
    @State private var taskDetail: TaskRow?
    @State private var taskDetailDraft = ""
    @State private var taskDoneWhenDraft = ""
    @State private var taskDetailBusy = false
    @State private var taskDetailError = ""
    @State private var taskSavedText = ""
    @State private var taskSavedDoneWhen = ""
    @State private var confirmingTaskDismiss = false
    /// Stamp used only by Schedule. Capture files to inbox with no time.
    @State private var taskRunAt = Date()
    /// Which row's Schedule popover is open. The picker used to sit above the
    /// list as a board-level "Run at", which read as a filter it was not.
    @State private var schedulePopoverID: String?
    @State private var taskBusy = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the gateway paint-in. Flips once on appear; every tile reads it with its
    /// own delay, which is how `anime.stagger` translates into SwiftUI.
    @State private var painted = false
    @State private var hoveredSection: ActivitySection?
    /// 0.5.259: the Needs you item Next ⌘] opened last, so the next press opens the one after it.
    @State private var homeNextCursor: ActivityHome.NextCursor?
    /// 0.5.259: how each source's load on opening came back, for the quiet line (ActivityHome.line).
    @State private var homeLoads: [ActivityHome.Source: ActivityHome.SourceState] = [:]
    /// 0.5.259: the view Memories opens on when an item asks for one ("review"); cleared by the next tab choice.
    @State private var memoriesOpenView: String?
    /// One indicator that travels between tabs instead of six that blink.
    @Namespace private var railIndicator

    /// Fixture-only native render: uses the actual window tree without fetching live data.
    static func heldSamplesCanary(model: ControllerModel) -> ActivityWindow {
        var view = ActivityWindow(model: model)
        view._section = State(initialValue: .speakers)
        view._speakerSubview = State(initialValue: .samples)
        return view
    }

    /// 0.5.247: the app's window, on the app's Work journal, which the tracker keeps current while this window is closed.
    static func live(model: ControllerModel) -> ActivityWindow {
        var view = ActivityWindow(model: model)
        if let store = model.workHandoffStore { view._handoffStore = StateObject(wrappedValue: store) }
        return view
    }

    /// Uses the actual app shell; other sections are visible but cannot load live data.
    static func workPreview(model: ControllerModel) -> ActivityWindow {
        var view = ActivityWindow(model: model, isolatedWorkPreview: true)
        view._section = State(initialValue: .work)
        let store = WorkHandoffStore(isolated: true)
        store.selectedWorkID = "task:Website:sample-task-website"
        view._handoffStore = StateObject(wrappedValue: store)
        view._reviewStore = StateObject(wrappedValue: WorkWorkspaceProjection.previewReviewStore())
        return view
    }

    /// Explicit connected candidate. Its caller enables only foreground Activity loads.
    static func workConnectedTest(model: ControllerModel) -> ActivityWindow {
        var view = ActivityWindow(model: model)
        view._section = State(initialValue: .work)
        return view
    }

    static func allowsLiveSectionLoads(isolatedWorkPreview: Bool, backgroundWorkEnabled: Bool) -> Bool {
        !isolatedWorkPreview && backgroundWorkEnabled
    }

    static func workSubviewForLaunch(_ requested: ActivitySection, current: ActivityWorkSubview) -> ActivityWorkSubview {
        requested == .tasks ? .tasks : current
    }

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
            case .samples:
                if a.embeddings != b.embeddings { return a.embeddings > b.embeddings }
            case .confidence:
                // Weakest profile first among voices with enough scored speech to judge; a thin
                // basis sorts after them and a voice never matched goes last, since one segment
                // swings a share from 0 to 100 (QA 2026-09-13, live data).
                let ra = confidenceRank(a), rb = confidenceRank(b)
                if ra.tier != rb.tier { return ra.tier < rb.tier }
                if let x = ra.share, let y = rb.share, x != y { return x < y }
                if a.observedMatchSegments != b.observedMatchSegments { return a.observedMatchSegments > b.observedMatchSegments }
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
        case .meetings:
            selectedLibraryRecordID != nil || model.meetingImportRouteActive || model.meetingSuggestionsRouteActive
        case .memories: selectedContextID != nil || selectedLearningID != nil || selectedGraphEntityID != nil
        case .threads: selectedContextID != nil
        case .sessions: selectedSessionID != nil
        case .tasks: taskDetail != nil
        case .work: !isolatedWorkPreview && workSubview == .tasks && taskDetail != nil
        case nil: false
        }
    }

    private var canGoBack: Bool { section != nil || hasDetail }

    private var activityFrame: some View {
        VStack(spacing: 0) {
            navigationBar
            if connectedWorkTest {
                HStack(spacing: 8) {
                    Image(systemName: "network")
                    Text("Connected Work candidate").font(COSType.body(11.5, weight: .semibold))
                    Text("Real tasks and sessions. Sending uses the selected agent’s existing permissions.")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 18).padding(.vertical, 8).background(COSPalette.raised)
            }
            lensRail
            Divider()
            Group {
                if section == .sessions && (isolatedWorkPreview || showingLinkedSession) {
                    WorkSessionsView(store: handoffStore, isPreview: isolatedWorkPreview, onOpenWork: openHandoffWork, onOpenFullSession: openFullHandoffSession)
                } else if isolatedWorkPreview, let selected = section, selected != .work, !(selected == .meetings && selectedLibraryRecordID != nil) {
                    previewOnlySection(selected)
                } else if section == .messages, let preview = model.selectedMediaPreview {
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
                } else if section == .memories, selectedLearningID != nil {
                    if model.learningRouteActive {
                        LearningDetailPane(
                            model: model,
                            showsBackButton: false,
                            onOpenSource: openLearningSource,
                            onExploreInGraph: exploreInGraph
                        )
                    } else {
                        centeredProgress("Loading lesson…")
                    }
                } else if section == .memories, selectedGraphEntityID != nil {
                    if model.graphRouteActive {
                        GraphEntityPane(model: model, showsBackButton: false, onOpenMemory: openMemoryFromGraph)
                    } else {
                        centeredProgress("Loading entity…")
                    }
                } else if (section == .memories || section == .threads), selectedContextID != nil {
                    if model.contextRouteActive {
                        ContextDetailPane(model: model, showsBackButton: false)
                    } else {
                        centeredProgress("Loading record…")
                    }
                } else if section == .meetings, selectedLibraryRecordID != nil {
                    if model.libraryRouteActive {
                        connectedMeetingDetailSurface
                    } else {
                        centeredProgress("Loading meeting…")
                    }
                // 6.47.0 — each of these is mounted on its OWN flag, which its own
                // opener writes. Placed after the detail so a meeting a person
                // actually opened wins; the model openers close the detail first,
                // so the two can never both be true.
                } else if section == .meetings, model.meetingImportRouteActive {
                    MeetingImportPane(model: model)
                } else if section == .meetings, model.meetingSuggestionsRouteActive {
                    MeetingSuggestionsPane(model: model)
                } else if section == .sessions, selectedSessionID != nil {
                    if model.claudeSessionRouteActive {
                        VStack(spacing: 0) {
                            // 0.5.241: a session Work started names its Work item however it was opened.
                            let workReceipt = workConnectionsEnabled
                                ? selectedSessionID.flatMap { WorkHandoffStore.latestReceipt(forSession: $0, in: handoffStore.receipts) }
                                : nil
                            if workReceipt == nil, let workID = handoffStore.selectedWorkID,
                               handoffStore.selectedSessionID == selectedSessionID {
                                Button("Back to linked work") { model.closeClaudeSession(); openHandoffWork(workID) }
                                    .buttonStyle(COSQuietButtonStyle()).padding(10)
                            }
                            if workConnectionsEnabled, workReceipt == nil, let sessionID = selectedSessionID {
                                if let link = handoffStore.confirmedSessionCards[sessionID] {
                                    Button("Linked to \(link.title)") { model.closeClaudeSession(); openHandoffWork(link.workID) }.buttonStyle(COSQuietButtonStyle()).padding(10)
                                } else if let row = model.openClaudeRow,
                                          let task = WorkSessionCardSuggestion.best(title: row.title, summary: row.discussionSummary, tasks: model.workTasks) {
                                    HStack {
                                        Text("This looks like: " + task.text).font(COSType.body(12)).lineLimit(2)
                                        Button("Link to card") { _ = handoffStore.confirmSessionCard(sessionID: sessionID, source: WorkSource.taskSnapshot(task)) }
                                    }.padding(10)
                                }
                            }
                            ClaudeSessionDetailPane(model: model, workReceipt: workReceipt,
                                                    onOpenWork: { id in model.closeClaudeSession(); openHandoffWork(id) })
                                .task { if workConnectionsEnabled { await model.loadWorkTasks() } }
                        }
                    } else {
                        centeredProgress("Loading session…")
                    }
                } else if let section {
                    sectionList(section)
                } else {
                    activityHome
                }
            }
            // 0.5.222 — THE TOOLBAR STAYS PUT. The content region takes exactly the space
            // left under the navigation bar and the lens rail (minWidth and minHeight 0),
            // aligned to the top, and clips what does not fit. A pane that cannot shrink
            // otherwise made the column taller than the window, and the window centered the
            // overflow: Home, Back and the breadcrumbs slid off the top (Add a voice,
            // 2026-08-26 and again 2026-09-13).
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .clipped()
        }
    }

    var body: some View {
        activityFrame
        .frame(minWidth: 760, minHeight: 560)
        .font(COSType.body(13))
        .background(COSPalette.panel)
        // 0.5.251: GOTCOS progress, disclosure and tint for every control in the window.
        .cosControlTheme()
        .task {
            if connectedWorkTest {
                await model.refresh(quiet: true)
                await load(.work)
            } else {
                await loadOverviewIfNeeded()
            }
        }
        .task(id: speakerPeekKey) { await peekMeetingsIfNeeded() }
        .alert("COS Control", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
        // Inline, like the task detail: the Tests/run.sh overlay guard forbids sheet
        // presentations in this view tree, and a refresh underneath cannot dismiss it.
        .overlay {
            if heldNamingOverlayOpen {
                ZStack {
                    Color.black.opacity(0.16).ignoresSafeArea()
                        .onTapGesture { if !model.addVoiceBusy { closeHeldNamingOverlay() } }
                    Group {
                        if model.heldNamingShowReview {
                            HeldNamingReviewSheet(model: model)
                        } else if heldNamingResultOpen {
                            HeldNamingResultSheet(model: model, onClose: { heldNamingResultOpen = false })
                        } else {
                            HeldNamingHistorySheet(model: model, onClose: { heldNamingHistoryOpen = false })
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(COSPalette.panel))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(COSPalette.line, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(24)
                }
            }
        }
        .overlay { taskEditorOverlay }
        .cosConfirm("Save task changes?", isPresented: $confirmingTaskDismiss,
            message: "Save your task text and finish line, discard these edits, or keep editing.",
            actions: [.normal("Save") { saveTaskEdits() }, .destructive("Discard") { closeTaskDetail() }, .cancel("Cancel")])
        .cosConfirm(
            "Restore this naming’s previous labels?",
            isPresented: Binding(get: { heldNamingUndoHandle != nil }, set: { if !$0 { heldNamingUndoHandle = nil } }),
            message: "Later naming is protected. Voice samples stay enrolled; deleted audio stays deleted.",
            actions: [
                // cosConfirm clears the binding before it runs an action, so the handle is
                // captured when the actions are built, not read afterwards.
                .destructive("Undo labels") { [handle = heldNamingUndoHandle] in
                    if let handle { Task { await model.undoHeldNaming(handle) } }
                },
                .cancel("Keep labels"),
            ]
        )
        .background(ActivityEscapeHandler(onEscape: handleActivityEscape).frame(width: 0, height: 0))
        .onExitCommand { if !handleActivityEscape() { goBack() } }
        .onAppear { applyLaunchSection() }
        .onChange(of: model.activityOpenSection) { _, _ in applyLaunchSection() }
        .onChange(of: model.activityOpenSessionID) { _, _ in applyLaunchSection() }
        .onChange(of: model.activityOpenWorkID) { _, _ in applyLaunchSection() }
    }

    private func applyLaunchSection() {
        if isolatedWorkPreview {
            model.activityOpenSection = nil
            model.activityOpenSessionID = nil
            model.activityOpenWorkID = nil
            return
        }
        if let workID = model.activityOpenWorkID {
            model.activityOpenWorkID = nil
            model.activityOpenSection = nil
            openHandoffWork(workID)
            return
        }
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
            .buttonStyle(COSQuietButtonStyle())
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .help("Activity home")

            Button { goBack() } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(COSQuietButtonStyle())
            .disabled(!canGoBack)
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .help("Go back one step")

            breadcrumb
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(isolatedWorkPreview ? COSPalette.gold : (model.status.running ? COSPalette.green : COSPalette.amber))
                    .frame(width: 7, height: 7)
                Text(isolatedWorkPreview ? "Isolated Work preview" : (model.status.running ? "Server connected" : "Server offline"))
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
                if section == .work, !isolatedWorkPreview {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                    Text(workSubview.title).font(COSType.body(11, weight: .semibold))
                }
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
        if section == .memories, selectedLearningID != nil {
            if let lesson = model.learningDetail, lesson.id == selectedLearningID { return lesson.title }
            if model.learningDetailLoading { return "Loading lesson" }
        }
        if section == .memories, selectedGraphEntityID != nil {
            if let entity = model.graphEntity, entity.id == selectedGraphEntityID { return "Knowledge · \(entity.id)" }
            if model.graphEntityLoading { return "Knowledge · loading entity" }
        }
        if section == .memories, memoriesSubview == .knowledge, selectedContextID == nil, selectedLearningID == nil {
            return "Knowledge"
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
                        .font(COSType.body(11.5, weight: section == item ? .semibold : .medium))
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

    private func select(_ requested: ActivitySection) {
        if taskDetail != nil { requestCloseTaskDetail(); return }
        memoriesOpenView = nil
        if !isolatedWorkPreview { showingLinkedSession = false; historicalWorkID = nil }
        let next = ActivitySection.resolvedLaunch(requested, environment: ProcessInfo.processInfo.environment)
        guard ActivitySection.allCases.contains(next) else { return }
        if isolatedWorkPreview { withOptionalAnimation { section = next }; return }
        clearDetail()
        workSubview = Self.workSubviewForLaunch(requested, current: workSubview)
        withOptionalAnimation { section = next }
        // Opening a section is what clears its dot: the cursor moves to the
        // newest stamp the last signals call saw.
        model.markActivityOpened(next == .work && workSubview == .tasks ? .tasks : next)
        Task { await load(next) }
    }

    private func goHome() {
        // A send being handed over keeps its overlay; it shows the result when you come back to Work.
        if !workWorkspaceState.startSending { workWorkspaceState.startItemID = nil }
        if taskDetail != nil { requestCloseTaskDetail(); return }
        if isolatedWorkPreview { withOptionalAnimation { section = nil }; return }
        clearDetail()
        withOptionalAnimation { section = nil }
    }

    /// Escape reaches these window-owned routes before TextEditor/ScrollView can
    /// consume it. Other child panes retain their own cancellation semantics.
    private func handleActivityEscape() -> Bool {
        // 0.5.244: Work's Start work overlay sits above everything in Work; Escape closes it first (not mid-send).
        if workWorkspaceState.startItemID != nil {
            if !workWorkspaceState.startSending { workWorkspaceState.startItemID = nil }
            return true
        }
        if confirmingTaskDismiss { confirmingTaskDismiss = false; return true }
        if heldNamingUndoHandle != nil { heldNamingUndoHandle = nil; return true }
        if taskDetail != nil { requestCloseTaskDetail(); return true }
        if heldNamingOverlayOpen {
            if !model.addVoiceBusy { closeHeldNamingOverlay() }
            return true
        }
        if section == .sessions, showingLinkedSession { goBack(); return true }
        if section == .meetings, meetingReturnToWork { goBack(); return true }
        return false
    }

    private func goBack() {
        // A send being handed over keeps its overlay; it shows the result when you come back to Work.
        if !workWorkspaceState.startSending { workWorkspaceState.startItemID = nil }
        // The linked receipt reader is a child of Work in both the integrated
        // candidate and production. Header Back and Escape keep that context.
        if section == .sessions, showingLinkedSession {
            if let workID = handoffStore.selectedWorkID ?? workWorkspaceState.selectedID {
                openConnectedWork(workID)
            } else {
                showingLinkedSession = false
                section = .work
            }
            return
        }
        if isolatedWorkPreview, section == .meetings, meetingReturnToWork {
            selectedLibraryRecordID = nil; model.closeLibraryDetail()
            returnFromMeetingToWork(); return
        }
        if isolatedWorkPreview { withOptionalAnimation { section = nil }; return }
        if (section == .tasks || (section == .work && workSubview == .tasks)), taskDetail != nil {
            requestCloseTaskDetail()
        } else if section == .work, workWorkspaceState.selectedID != nil || reviewStore.selectedMeeting != nil || workWorkspaceState.meetingPicker {
            workWorkspaceState.selectedID = nil; handoffStore.selectedWorkID = nil
            reviewStore.selectedMeeting = nil; workWorkspaceState.meetingPicker = false
        } else if section == .messages, model.selectedMediaPreview != nil {
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
        } else if section == .memories, selectedLearningID != nil {
            selectedLearningID = nil
            model.closeLearningDetail()
        } else if section == .memories, selectedGraphEntityID != nil {
            selectedGraphEntityID = nil
            model.closeGraphEntity()
        } else if (section == .memories || section == .threads), selectedContextID != nil {
            selectedContextID = nil
            model.closeContextDetail()
        } else if section == .meetings, selectedLibraryRecordID != nil {
            selectedLibraryRecordID = nil
            model.closeLibraryDetail()
            if meetingReturnToWork { returnFromMeetingToWork() }
        } else if section == .meetings, model.meetingImportRouteActive {
            model.closeMeetingImport()
        } else if section == .meetings, model.meetingSuggestionsRouteActive {
            model.closeMeetingSuggestions()
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
        // A send being handed over keeps its overlay; it shows the result when you come back to Work.
        if !workWorkspaceState.startSending { workWorkspaceState.startItemID = nil }; workWorkspaceState.focusOverride = false
        guard !isolatedWorkPreview else { return }
        if !taskDetailBusy { closeTaskDetail() }
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
        selectedLearningID = nil
        selectedGraphEntityID = nil
        selectedLibraryRecordID = nil
        meetingReturnWorkID = nil
        meetingReturnToWork = false
        selectedSessionID = nil
        model.closeSpeakerReview()
        model.closeContextDetail()
        model.closeLearningDetail()
        model.closeGraphEntity()
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
            // 0.5.259: one clock for the Needs you line, the cards and the desks, so a quiet session reads the same in all
            // three. It ticks each minute for the ages ("12 min").
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                let now = timeline.date
                let seats = homeSeats(now: now)
                let desks = seats.map(ActivityHome.desks)
                let sources = homeNeedSources(desks: desks)
                let needs = ActivityHome.needs(sources)
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
                        Text("Views into the work your COS already holds.")
                            .font(COSType.display(13, italic: true))
                            .foregroundStyle(.secondary)
                    }
                    needsYouLine(needs, states: homeSourceStates(desks: desks), now: now)
                    homeGrid(homeInputs(now: now, seats: seats), desks: desks, now: now)
                }
                .padding(28)
                // 0.5.259: wider than the 900 pt of before, so a card's lead line has room (the mock's home fills the
                // window); a very wide window still keeps the cards a readable width.
                .frame(maxWidth: 1120, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        // 0.5.259 (QA U-N9): with the pet off nothing else refreshes the sessions list, so a session that finished could
        // still read as quiet. While the home shows, read it once a minute; the task ends when the home goes.
        .task { await refreshHomeSessions() }
    }

    private func refreshHomeSessions() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            guard Self.allowsLiveSectionLoads(isolatedWorkPreview: isolatedWorkPreview, backgroundWorkEnabled: model.activityLoadsEnabled),
                  section == nil, !model.petEnabled else { continue }
            await model.loadClaudeSessions()
        }
    }

    /// 0.5.259 board 1: what waits on Miles. Sessions first, in full (three at most, then "+N sessions"); then the
    /// backlog as one short segment of counts (ActivityHome.parts). Next ⌘] opens the first item, then the next one each
    /// press (ActivityHome.nextTarget). ⌘] is also Speakers' Next to name;
    /// the two never both respond, because this line lives only on the home and the speaker review only on its own route
    /// of the same if/else chain (activityFrame). Tests/activity-home-pins.py pins both.
    @ViewBuilder
    private func needsYouLine(_ needs: [ActivityHome.Need], states: [ActivityHome.Source: ActivityHome.SourceState], now: Date) -> some View {
        switch ActivityHome.line(needs, states: states) {
        case .hidden:
            EmptyView()
        case .quiet:
            Text(ActivityHome.quietLine)
                .font(COSType.body(12.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .overlay(alignment: .top) { needsRule }
                .overlay(alignment: .bottom) { needsRule }
        case .items:
            HStack(alignment: .center, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("Needs you")
                    Text(needs.count.formatted()).foregroundStyle(COSPalette.amber).monospacedDigit()
                }
                .font(COSType.display(15.5, weight: .medium))
                .fixedSize()
                // A session item starts with its dot, which is what separates it from the one before, also where a row
                // wraps. The backlog is one segment, so it never splits across rows.
                let parts = ActivityHome.parts(needs)
                NeedsFlowLayout(spacing: 18, lineSpacing: 7) {
                    ForEach(parts.shown) { need in
                        needRow(need, in: needs, single: parts.sessions.count == 1, now: now)
                            .layoutValue(key: NeedsFlowShrinks.self, value: true)
                    }
                    if parts.moreSessions > 0 {
                        Button { select(.sessions) } label: {
                            Text(ActivityHome.moreSessionsLabel(parts.moreSessions)).font(COSType.body(12.5)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                        .help("Open Sessions")
                    }
                    if !parts.backlog.isEmpty {
                        backlogSegment(parts, in: needs)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    if let next = ActivityHome.nextTarget(needs, after: homeNextCursor) { openNeed(next, in: needs) }
                } label: {
                    HStack(spacing: 7) {
                        Text(ActivityHome.nextLabel(needs)).font(COSType.body(12, weight: .semibold))
                        Text("⌘]")
                            .font(COSType.mono(10))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(COSPalette.line, lineWidth: 1))
                    }
                    .foregroundStyle(COSPalette.accent)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(COSPalette.gold.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(COSPalette.gold, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("]", modifiers: .command)
                .help("Open the first thing waiting on you (⌘]). Press again for the next.")
                .fixedSize()
            }
            .padding(.vertical, 11)
            .overlay(alignment: .top) { needsRule }
            .overlay(alignment: .bottom) { needsRule }
        }
    }

    private var needsRule: some View { Rectangle().fill(COSPalette.gold.opacity(0.28)).frame(height: 1) }

    /// One session item: a filled amber dot when it is a fact (need.isFact: it asked, or failed), an open one when it
    /// is only quiet ("may need you", never a fact). Click opens it the way Sessions does.
    /// `single`: the only session item, which shows what it asked; it has the line's room, and its title never gives
    /// way to that text.
    private func needRow(_ need: ActivityHome.Need, in needs: [ActivityHome.Need], single: Bool, now: Date) -> some View {
        Button { openNeed(need, in: needs) } label: {
            HStack(spacing: 6) {
                Group {
                    if need.isFact {
                        Circle().fill(COSPalette.amber)
                    } else {
                        Circle().strokeBorder(COSPalette.amber, lineWidth: 1.4)
                    }
                }
                .frame(width: 7, height: 7)
                if let desk = need.desk {
                    ActivityProviderMark(session: desk.session, size: 11).foregroundStyle(.secondary)
                }
                // What a session did ("asked you a question") is the fact; its title gives way first. With one session,
                // what it asked is the extra, so that text gives way and the title stays.
                Text(need.what)
                    .font(COSType.body(12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(single ? 1 : 0)
                if !need.why.isEmpty {
                    Text(need.why).font(COSType.body(12.5)).foregroundStyle(.secondary).lineLimit(1)
                        .layoutPriority(single ? 0 : 1)
                }
                if let age = need.age(now: now) {
                    Text(age).font(COSType.mono(10.5)).foregroundStyle(.tertiary).fixedSize()
                }
            }
            .frame(maxWidth: single ? 560 : 360, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(need.desk.map { $0.help(now: now) } ?? [need.what, need.why].filter { !$0.isEmpty }.joined(separator: " · "))
    }

    /// The backlog as one segment of counts: "Also · 1 voice to name · 3 memories · 7 work items" after session items,
    /// the counts alone when there are none (ActivityHome.backlogPieces). Each count opens its section; its help text
    /// says the rest.
    private func backlogSegment(_ parts: ActivityHome.LineParts, in needs: [ActivityHome.Need]) -> some View {
        HStack(spacing: 6) {
            ForEach(ActivityHome.backlogPieces(parts)) { piece in
                switch piece {
                case .also: Text(piece.text).foregroundStyle(.secondary)
                case .dot: Text(piece.text).foregroundStyle(.tertiary)
                case .count(let need):
                    Button { openNeed(need, in: needs) } label: {
                        Text(piece.text).foregroundStyle(.primary).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help([need.what, need.why].filter { !$0.isEmpty }.joined(separator: " · "))
                }
            }
        }
        .font(COSType.body(12.5))
        .lineLimit(1)
        .fixedSize()
    }

    /// Each item in its own section: a session as Sessions opens it, the newest meeting with voices to name in Speakers'
    /// review, Memories on To review, and Work on what needs attention. It becomes where Next ⌘] carries on from.
    private func openNeed(_ need: ActivityHome.Need, in needs: [ActivityHome.Need]) {
        homeNextCursor = ActivityHome.NextCursor(id: need.id, index: needs.firstIndex { $0.id == need.id } ?? 0)
        switch need.kind {
        case .asked, .maybe:
            if let desk = need.desk { openDesk(desk) }
        case .voices:
            select(.speakers)
            guard let meeting = need.meeting else { return }
            speakerSubview = .meetings
            voiceParentName = nil
            selectedSpeakerSessionID = meeting.sessionId
            model.openSpeakerReview(meeting)
        case .memories:
            select(.memories)
            memoriesSubview = .toReview
            memoriesOpenView = "review"
        case .work:
            select(.work)
            workWorkspaceState.query = ""
            workWorkspaceState.domain = nil
            workWorkspaceState.scope = .attention
            workWorkspaceState.focusOverride = true
        }
    }

    /// A desk, or a session item, opens its session the way a Sessions row does.
    private func openDesk(_ desk: ActivityHome.Desk) {
        select(.sessions)
        selectedSessionID = desk.openRow.id
        model.openClaudeSession(desk.openRow)
    }

    /// Four columns, two rows: the seven visible tiles (Work, or Tasks when Work is off) stay above the fold. Three columns
    /// would put Work on a third row at the minimum window height. 0.5.259: each row is as tall as its tallest card (a
    /// card's body now varies), and a tap on a card opens its tab while its desks take their own clicks (a Button card
    /// would swallow them). `desks` is nil until the session list has loaded.
    private func homeGrid(_ inputs: ActivityHome.CardInputs, desks: [ActivityHome.Desk]?, now: Date) -> some View {
        let tiles = Array(ActivitySection.allCases.enumerated())
        let rows = stride(from: 0, to: tiles.count, by: 4).map { Array(tiles[$0..<min($0 + 4, tiles.count)]) }
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(alignment: .top, spacing: 14) {
                    ForEach(rows[row], id: \.element.id) { index, item in
                        activityHomeCard(item, index: index, body: homeCardBody(item, inputs),
                                         desks: item == .sessions ? desks : nil, now: now)
                            .onTapGesture { select(item) }
                            .accessibilityElement(children: .contain)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel("Open \(item.title)")
                            .accessibilityAction { select(item) }
                            // The description the card used to print, now its help text.
                            .help(item.summary)
                            // Plain and explicit. The earlier one-liner also cleared state for
                            // a tile that was no longer hovered, which races the enter event of
                            // the tile you just moved onto.
                            .onHover { inside in
                                if inside { hoveredSection = item }
                                else if hoveredSection == item { hoveredSection = nil }
                            }
                    }
                    ForEach(rows[row].count..<4, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { painted = true }
    }

    /// One gateway tile.
    ///
    /// The accent bar this replaced was a `RoundedRectangle(cornerRadius: 2)` overlaid on a
    /// 16pt-radius card: a CSS `border-left` moved into SwiftUI without reconciling the
    /// geometry, so the card curved away and the bar stayed straight. Nothing sits on the
    /// edge now. The stipple is the card's paper — gotcos `.chapcard` 9pt gold dots, a
    /// child clipped by the tile — not a corner glyph sitting on espresso.
    ///
    /// 0.5.259: the card says what is true now (ActivityHome.card): a lead line, amber when it waits on Miles, at most two
    /// sub lines, and a quiet footer naming what the big number counts. The mono caps caption is gone (it read as an
    /// eyebrow kicker) and the description moved to the card's help text.
    private func activityHomeCard(_ item: ActivitySection, index: Int, body: ActivityHome.CardBody,
                                  desks: [ActivityHome.Desk]?, now: Date) -> some View {
        let hot = hoveredSection == item
        // anime.stagger(45) is just an index-scaled delay.
        let step = Double(index) * 0.045

        let glyph = SectionGlyph(section: item)
            .trim(from: 0, to: (reduceMotion || painted) ? 1 : 0)
            .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .foregroundStyle(hot ? COSPalette.gold : Color.secondary)
            .frame(width: 17, height: 17)
            .animation(reduceMotion ? nil
                       : .timingCurve(0.42, 0, 0.22, 1, duration: 0.60).delay(step + 0.14),
                       value: painted)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18).delay(hot ? 0.04 : 0),
                       value: hot)
        // One line, never a mid-word break: "Meetings" beside "2,346" rendered as
        // "Meeting / s" in the four-column grid (Miles, 2026-09-06). At the default
        // 920 pt window a tile row is about 168 pt and the pair needs about 160, so
        // the one-line layout wins; at the 760 pt minimum the row is about 133 pt,
        // and ViewThatFits drops the metric under the title instead of truncating.
        let title = Text(item.title)
            .font(COSType.body(14.5, weight: .semibold))
            .foregroundStyle(hot ? COSPalette.gold : Color.primary)
            .lineLimit(1)
            .fixedSize()
            .wipeIn(painted, delay: step + 0.33, reduceMotion: reduceMotion)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18).delay(hot ? 0.07 : 0),
                       value: hot)
        // No number until its source has loaded: never a placeholder that reads as a value.
        let metric = Text(body.count ?? "")
            .font(COSType.display(22, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(hot ? COSPalette.gold : Color.primary)
            .lineLimit(1)
            .fixedSize()
            .wipeIn(painted, delay: step + 0.47, reduceMotion: reduceMotion)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18).delay(hot ? 0.10 : 0),
                       value: hot)
        return VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    glyph
                    title
                    Spacer(minLength: 8)
                    metric
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        glyph
                        title
                    }
                    metric
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                // The Sessions card keeps its one-row strip once the list has loaded, desks or not, so its height never
                // moves with the number of sessions.
                if let desks {
                    deskStrip(desks, now: now).padding(.bottom, 3)
                }
                if !body.lead.isEmpty {
                    leadLine(body.lead)
                        .font(COSType.body(12.5, weight: .medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(body.subs.prefix(2).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(COSType.body(11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.top, 2)

            Spacer(minLength: 0)

            if let footer = body.footer {
                // What the big number counts, in sentence case and quiet.
                Text(footer)
                    .font(COSType.mono(10))
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 138, maxHeight: .infinity, alignment: .topLeading)
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

    /// A lead line whose waiting part alone is amber ("2 working · 1 waiting on you").
    private func leadLine(_ spans: [ActivityHome.Span]) -> Text {
        spans.reduce(Text("")) { line, span in
            line + Text(span.text).foregroundStyle(span.waits ? COSPalette.amber : Color.primary)
        }
    }

    /// 0.5.259 board 3: a desk per running, waiting or finished-today session, at most 12, then "+N".
    private func deskStrip(_ desks: [ActivityHome.Desk], now: Date) -> some View {
        // One row, sized to the card (ActivityHome.deskFit): the desks that fit, then "+N" for the rest.
        GeometryReader { geometry in
            let fit = ActivityHome.deskFit(count: desks.count, width: geometry.size.width)
            HStack(spacing: ActivityHome.deskGap) {
                ForEach(desks.prefix(fit.shown)) { desk in
                    ActivityDeskMark(desk: desk, now: now, reduceMotion: reduceMotion) { openDesk(desk) }
                }
                if fit.more > 0 {
                    Button { select(.sessions) } label: {
                        Text("+\(fit.more)")
                            .font(COSType.mono(10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: ActivityHome.deskMoreWidth, height: ActivityHome.deskHeight, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(fit.more) more in Sessions")
                }
            }
        }
        .frame(height: ActivityHome.deskHeight)
    }

    /// The count and what it counts, read from the model rather than scraped out of
    /// prose.
    ///
    /// The first cut DID scrape it, taking leading digits and calling the remainder the
    /// unit. That turned "50 of 5528" into `50 / OF 5528` and "30 shown · 11 active" into
    /// `30 / SHOWN · 11 ACTIVE` — the smaller number promoted and the label a
    /// fragment. `status.memoryCount` and `status.threadCount` were there the whole time.
    private func formatted(_ value: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func homeCardBody(_ item: ActivitySection, _ inputs: ActivityHome.CardInputs) -> ActivityHome.CardBody {
        ActivityHome.Card(rawValue: item.rawValue).map { ActivityHome.card($0, inputs) } ?? ActivityHome.CardBody()
    }

    /// 0.5.259: the sessions the home reads, nil until a session list has loaded. With the pet on, its live list decides
    /// what is running or waiting: the rows the pet draws, so the two never disagree.
    private func homeSeats(now: Date) -> [ActivityHome.Seat]? {
        let live: [ClaudeSession]? = model.petEnabled ? model.petSessions : nil
        guard !model.claudeSessions.isEmpty || !(live ?? []).isEmpty else { return nil }
        return ActivityHome.seats(list: model.claudeSessions, live: live, now: now)
    }

    /// Voices to name, from the Speakers meetings to review (nil until they load).
    private var homeVoices: ActivityHome.VoicesToName? {
        ActivityHome.voicesToName(model.reviewableMeetings) { model.voiceTag(for: $0) }
    }

    /// Work's rows, the ones its header counts; nil until the board has loaded.
    private var homeWorkItems: [WorkWorkspaceItem]? {
        guard workConnectionsEnabled, !isolatedWorkPreview, model.workTasksError == nil,
              model.workTasksComplete || !model.workTasks.isEmpty else { return nil }
        return workWorkspaceState.board(model: model, handoffStore: handoffStore, reviewStore: reviewStore).items
    }

    /// When the oldest item to review was written, once the review list has loaded.
    private var homeOldestReview: Date? {
        model.toReviewEvents.compactMap { ActivityHome.stamp($0.ts) }.min()
    }

    private func homeNeedSources(desks: [ActivityHome.Desk]?) -> ActivityHome.NeedSources {
        ActivityHome.NeedSources(desks: desks, voices: homeVoices, memoriesToReview: model.status.learningToReview,
                                 memoriesOldest: homeOldestReview, workAttention: homeWorkItems?.filter(\.needsAttention).count)
    }

    /// Each source's state for the quiet line: the load on opening (homeLoads), or rows already in hand.
    private func homeSourceStates(desks: [ActivityHome.Desk]?) -> [ActivityHome.Source: ActivityHome.SourceState] {
        [
            .sessions: ActivityHome.sourceState(enabled: true, loaded: homeLoads[.sessions], hasData: desks != nil),
            .voices: ActivityHome.sourceState(enabled: true, loaded: homeLoads[.voices], hasData: !model.reviewableMeetings.isEmpty),
            .memories: ActivityHome.sourceState(enabled: true, loaded: homeLoads[.memories], hasData: model.status.learningToReview != nil),
            .work: ActivityHome.sourceState(enabled: workConnectionsEnabled && !isolatedWorkPreview, loaded: homeLoads[.work], hasData: homeWorkItems != nil),
        ]
    }

    private func homeInputs(now: Date, seats: [ActivityHome.Seat]?) -> ActivityHome.CardInputs {
        var input = ActivityHome.CardInputs()
        input.now = now
        input.clock = model.clockStyle
        input.messages = model.recentMessages
        input.messagesStatus = model.recentGlassesStatus
        input.enrolled = model.voiceDirectory.isEmpty ? nil : model.voiceDirectory.count
        input.voices = homeVoices
        if !model.libraryMeetings.isEmpty {
            input.monthCount = model.libraryMeetings.count
            input.monthTitle = MeetingMonth.title(model.libraryMonth)
        }
        input.storedMeetings = model.status.meetingLibraryCount > 0 ? model.status.meetingLibraryCount : nil
        input.recentMeetings = model.reviewableMeetings
        input.toReview = model.status.learningToReview
        input.oldestReview = homeOldestReview
        input.memories = model.status.memoryAvailable == true ? model.status.memoryCount : nil
        input.memorySetupNeeded = model.status.memoryAvailable == false
        input.threads = model.status.threadsAvailable == true ? model.status.threadCount : nil
        input.threadSetupNeeded = model.status.threadsAvailable == false
        input.activeThreads = model.status.activeThreadCount
        input.latestThread = model.threadRecords.filter { !$0.isResolved }.max { $0.createdAt < $1.createdAt }?.title
        input.sessions = seats.map(ActivityHome.tally)
        if let items = homeWorkItems {
            input.workAttention = items.filter(\.needsAttention).count
            input.workInProgress = items.filter(\.inProgress).count
            if model.workIntake.available, model.workIntakeError == nil {
                input.newToSort = model.workIntake.newCount + WorkSortGroup.mentioned(model.workTasks, catchUp: false, domain: nil).count
            }
        }
        input.tasks = model.tasks.isEmpty ? nil : model.tasks
        return input
    }

    // MARK: - Lists

    @ViewBuilder
    private func sectionList(_ item: ActivitySection) -> some View {
        switch item {
        case .messages: messagesList
        case .speakers: speakersList
        case .meetings: meetingsList
        case .memories: memoriesSurface()
        case .threads: contextList(kind: "thread")
        case .sessions: sessionsList
        case .tasks: tasksList
        case .work: workSurface
        }
    }

    @ViewBuilder private var workSurface: some View {
        WorkWorkspaceView(model: model, handoffStore: handoffStore, reviewStore: reviewStore,
            state: workWorkspaceState, onOpenSession: openHandoffSession, onOpenPlatform: openWorkInPlatform,
            onEditTask: openTaskDetail, onReviewMeeting: openMeetingWorkReview, onOpenMeeting: openWorkMeeting)
    }

    private var connectedMeetingDetailSurface: some View {
        MeetingLibraryDetailPane(model: model, onReviewVoices: openVoiceReviewFromLibrary,
            onOpenSource: openLibrarySource, onReviewFollowUp: meetingWorkReviewAction,
            workConnections: meetingConnections, onOpenWork: meetingWorkOpenAction,
            onOpenSession: meetingSessionOpenAction)
            .task(id: selectedLibraryRecordID) { await loadMeetingConnections() }
    }

    private var meetingWorkOpenAction: ((String) -> Void)? {
        guard workConnectionsEnabled else { return nil }
        return { id in openConnectedWork(id) }
    }
    private var meetingSessionOpenAction: ((String, String) -> Void)? {
        guard workConnectionsEnabled else { return nil }
        return { sessionID, workID in
            handoffStore.selectedWorkID = workID
            openHandoffSession(sessionID)
        }
    }

    private var workConnectionsEnabled: Bool {
        isolatedWorkPreview || ActivitySection.visibleSections(environment: ProcessInfo.processInfo.environment).contains(.work)
    }

    private var meetingConnections: MeetingWorkConnections? {
        guard workConnectionsEnabled, let meeting = model.openLibraryRow else { return nil }
        let errors = [model.workTasksError, reviewStore.error, handoffStore.error].compactMap { $0 }
        let tasks = isolatedWorkPreview ? WorkWorkspaceProjection.previewRows(handoffStore.previewTasks, stages: workWorkspaceState.previewStages) : model.workTasks
        return MeetingWorkConnections.project(meeting: meeting, tasks: tasks, reviews: reviewStore.reviews,
            receipts: handoffStore.receipts, sessions: handoffStore.observedSessions(),
            loading: !meetingWorkLoaded || model.workTasksLoading || reviewStore.busy,
            complete: isolatedWorkPreview || model.workTasksComplete, errors: errors)
    }

    private func loadMeetingConnections() async {
        guard workConnectionsEnabled else { return }
        if isolatedWorkPreview { meetingWorkLoaded = true; return }
        meetingWorkLoaded = false
        await model.loadWorkTasks()
        await reviewStore.refresh()
        await handoffStore.refresh()
        meetingWorkLoaded = true
    }

    private var meetingWorkReviewAction: ((LibraryMeeting) -> Void)? {
        guard workConnectionsEnabled else { return nil }
        return { meeting in openMeetingWorkReview(meeting) }
    }

    private func openMeetingWorkReview(_ meeting: LibraryMeeting) {
        if isolatedWorkPreview {
            if let review = reviewStore.reviews.first(where: { $0.canonicalMeetingId == meeting.recordId }) {
                openConnectedWork("meeting-review:" + review.id)
            }
            return
        }
        reviewStore.selectedMeeting = meeting
        workWorkspaceState.selectedID = nil
        handoffStore.selectedWorkID = nil
        workWorkspaceState.meetingPicker = false
        section = .work
        Task { await reviewStore.refresh() }
    }

    private func openWorkMeeting(_ reference: WorkMeetingReference) {
        guard workConnectionsEnabled, let row = reference.libraryMeeting else { return }
        meetingReturnToWork = section == .work
        meetingReturnWorkID = workWorkspaceState.selectedID
        meetingWorkLoaded = false
        if isolatedWorkPreview {
            guard reference.recordId == "sample-meeting", reference.domain == "Website", reference.month == "2026-09",
                  reference.filename == "2026-09-27_Website_Review.md" else {
                model.error = "That meeting is not part of this isolated sample."
                return
            }
            model.openLibraryRow = row
            model.libraryDetailError = nil
            model.libraryDetailLoading = false
            model.libraryDetail = LibraryMeetingDetail(.object([
                "recordId": .string(row.recordId), "title": .string(row.title), "domain": .string(row.domain),
                "transcript": .string("# Website review · local sample\nPrepare a clearer homepage call to action and verify mobile layout. Bring the result back for review before publishing."),
                "summary": .string("A local sample meeting. No live library was opened.")
            ]))
        } else { model.openWorkMeeting(reference) }
        selectedLibraryRecordID = row.recordId
        section = .meetings
    }

    private func returnFromMeetingToWork() {
        let workID = meetingReturnWorkID
        meetingReturnWorkID = nil; meetingReturnToWork = false
        if let workID { openConnectedWork(workID) }
        else {
            // A source link on a board card can open before a card is selected.
            // Keep the domain and return to its board, rather than Meetings list.
            workWorkspaceState.selectedID = nil; handoffStore.selectedWorkID = nil
            workWorkspaceState.meetingPicker = false; reviewStore.selectedMeeting = nil
            section = .work
        }
    }

    /// A related review may name a historical row while session receipts name
    /// stable work identity. Preserve both meanings without title matching.
    private func openConnectedWork(_ id: String) {
        // A send being handed over keeps its overlay; it shows the result when you come back to Work.
        if !workWorkspaceState.startSending { workWorkspaceState.startItemID = nil }
        if let review = reviewStore.reviews.first(where: { "meeting-review:" + $0.id == id }) {
            handoffStore.selectedWorkID = review.source.id
            workWorkspaceState.selectedID = id
            workWorkspaceState.meetingPicker = false
            reviewStore.selectedMeeting = nil
            showingLinkedSession = false
            section = .work
        } else { openHandoffWork(id) }
    }

    /// The work card stays where it is. Claude, Codex, or Cursor comes forward with this session.
    private func openWorkInPlatform(_ session: WorkSession) {
        guard !isolatedWorkPreview else { return }
        let value: JSONValue = .object([
            "id": .string(session.nativeID), "provider": .string(session.provider),
            "name": .string(session.title), "workspace": .string(session.project),
            "state": .string(session.status), "discussionSummary": .string(session.summary)
        ])
        guard let row = ClaudeSession(value) else { return }
        if WorkHandoffStore.serverHold(onSession: session.id, in: handoffStore.receipts) != nil {
            model.petNotice = "Still running on the COS server. It opens in the app when the first reply is done."
            return
        }
        model.openSessionInPlatform(row)
    }

    /// The receipt already names the Claude, Codex, or Cursor session. Bring that tab forward.
    /// Control's Sessions page is not that tab.
    private func openHandoffSession(_ id: String) {
        handoffStore.selectedSessionID = id
        guard !isolatedWorkPreview else {
            showingLinkedSession = true
            section = .sessions
            return
        }
        let session = handoffStore.sessions.first { $0.id == id }
            ?? handoffStore.receipts.lazy.compactMap { receipt -> WorkSession? in
                guard receipt.sessionID == id else { return nil }
                return WorkHandoffStore.rememberedSession(for: receipt)
            }.first
        guard let session else {
            showingLinkedSession = true
            section = .sessions
            return
        }
        openWorkInPlatform(session)
    }

    private func openHandoffWork(_ id: String) {
        // A send being handed over keeps its overlay; it shows the result when you come back to Work.
        if !workWorkspaceState.startSending { workWorkspaceState.startItemID = nil }
        handoffStore.selectedWorkID = id
        if !isolatedWorkPreview { model.closeClaudeSession(); selectedSessionID = nil }
        showingLinkedSession = false
        workSubview = .tasks
        section = .work
        workWorkspaceState.selectedID = id
        workWorkspaceState.meetingPicker = false
        reviewStore.selectedMeeting = nil
    }

    private func openFullHandoffSession(_ session: WorkSession) {
        guard !isolatedWorkPreview else { return }
        openWorkInPlatform(session)
    }

    private func previewOnlySection(_ item: ActivitySection) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.title).font(COSType.display(28, weight: .medium))
            Text("Your existing \(item.title.lowercased()) stay in COS Control. This isolated preview tests the new Work view without opening your live data.")
                .font(COSType.body(14)).foregroundStyle(.secondary)
            Button("Return to Work") { select(.work) }.buttonStyle(COSPrimaryButtonStyle())
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // The strip under a pane's title: what the pane holds right now, in the
    // value/label pair the home tiles use, read from the model it already has.
    private var meetingsStats: [(value: String, label: String)] {
        let scope = model.libraryDay.map { "ON \($0)" } ?? MeetingMonth.title(model.libraryMonth).uppercased()
        var stats: [(value: String, label: String)] = [(formatted(model.visibleLibraryMeetings.count), scope)]
        if model.status.meetingLibraryCount > 0 { stats.append((formatted(model.status.meetingLibraryCount), "STORED")) }
        let days = model.libraryDays.filter { $0.count > 0 }.count
        if days > 0 { stats.append((formatted(days), "DAYS WITH CALLS")) }
        return stats
    }

    private var sessionsStats: [(value: String, label: String)] {
        guard !visibleSessions.isEmpty else { return [] }
        let waiting = visibleSessions.filter(ClaudeSession.needsAPerson).count
        let pinned = visibleSessions.filter(\.pinned).count
        return [(formatted(visibleSessions.count), "ON DISK"), (formatted(waiting), "WAITING"), (formatted(pinned), "PINNED")]
    }

    private var tasksStats: [(value: String, label: String)] {
        guard !model.tasks.isEmpty else { return [] }
        let scheduled = model.tasks.filter { !$0.runAt.isEmpty }.count
        let flagged = model.tasks.filter { $0.missed == true || $0.failed == true }.count
        return [(formatted(model.tasks.count), "OPEN"), (formatted(scheduled), "SCHEDULED"), (formatted(flagged), "NEED ATTENTION")]
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
                refreshDisabled: model.libraryLoading,
                stats: meetingsStats
            )
            MeetingLibraryBody(model: model) { meeting in
                meetingReturnWorkID = nil
                meetingReturnToWork = false
                meetingWorkLoaded = false
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
                refresh: { Task { await model.loadClaudeSessions(force: true) } },
                refreshDisabled: model.claudeSessionsLoading,
                stats: sessionsStats,
                accessory: {
                    if !model.isSessionQueryActive {
                        COSViewSwitch("Clock", selection: $model.sessionClock,
                                      options: SessionClock.allCases.map { COSViewOption($0, $0.title) })
                        .frame(maxWidth: 278)
                    }
                }
            )
            sessionsSearchBar
            sessionHooksBanner
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
                    LazyVStack(spacing: 6) {
                        ForEach(visibleSessions) { session in
                            sessionRow(session)
                        }
                        // 0.5.229: today's finished scheduled job runs, under the live list.
                        if model.sessionClock != .pinned && !model.scheduledJobRuns.isEmpty {
                            scheduledJobRunsSection
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 22)
                }
            }
        }
    }

    private var scheduledJobRunsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SCHEDULED JOBS TODAY")
                .font(COSType.mono(9.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .padding(.top, 14)
                .padding(.bottom, 2)
            ForEach(model.scheduledJobRuns) { run in
                Button {
                    if let session = ClaudeSession.fromJobRun(run) {
                        selectedSessionID = session.id
                        model.openClaudeSession(session)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(COSPalette.green)
                        Text(run.label)
                            .font(COSType.body(12.5, weight: .semibold))
                            .lineLimit(1)
                        if !run.script.isEmpty {
                            Text(run.script)
                                .font(COSType.mono(10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(run.finishedAt.formatted(date: .omitted, time: .shortened))
                            .font(COSType.body(10.5))
                            .foregroundStyle(.secondary)
                        if let duration = run.duration {
                            Text(ScheduledJobRun.durationLabel(duration))
                                .font(COSType.mono(10.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .cosRowCard()
                }
                .buttonStyle(.plain)
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
                refreshDisabled: model.tasksLoading,
                stats: tasksStats
            )
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("Capture a task", text: $taskCapture)
                        .textFieldStyle(.plain)
                        .cosField()
                    // Server-resolved, not hardcoded: these were one user's
                    // four business units, so a second COS install had nothing
                    // it could file a task against. Falls back to the four only
                    // while an older server has no /api/domains to answer with.
                    COSDropdown("Domain", selection: $taskDomain,
                                options: model.domainOptions.map { COSDropdownOption($0.name, $0.label) }, showsLabel: false)
                    .frame(width: 160)
                    Button("Capture") {
                        Task { await captureTask() }
                    }
                    .buttonStyle(COSPrimaryButtonStyle())
                    .disabled(taskCapture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || taskBusy)
                }
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
                    LazyVStack(spacing: 6) {
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
            // The whole left side opens the detail. `text` is the full line;
            // `title` is capped at 44 for a lens row and was truncating every
            // task in a 1900px window.
            Button {
                openTaskDetail(task)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.text.isEmpty ? task.title : task.text)
                        .font(COSType.body(13.5))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    // Where the task sits, as three small marks rather than one
                    // dotted string: each is a fact the board can filter on.
                    HStack(spacing: 6) {
                        ForEach(Array([task.domain, task.column, task.section].filter { !$0.isEmpty }.enumerated()), id: \.offset) { _, part in
                            Text(part.uppercased())
                                .font(COSType.mono(8.5, weight: .semibold))
                                .tracking(0.5)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            if task.missed == true { Text("Missed").font(COSType.body(10.5, weight: .semibold)).foregroundStyle(COSPalette.amber) }
            if task.failed == true { Text("Failed").font(COSType.body(10.5, weight: .semibold)).foregroundStyle(.red) }
            Button("Schedule") {
                prepareSchedule(from: task)
                schedulePopoverID = task.id
            }
            .buttonStyle(COSQuietButtonStyle())
            .disabled(taskBusy)
            .popover(isPresented: Binding(
                get: { schedulePopoverID == task.id },
                set: { if !$0 { schedulePopoverID = nil } }
            )) {
                taskSchedulePopover(task)
            }
            Button("Run now") {
                Task { await runTask(task) }
            }
            .buttonStyle(COSQuietButtonStyle())
            .disabled(taskBusy)
            Button(task.checked ? "Reopen" : "Done") {
                Task { await checkTask(task) }
            }
            .buttonStyle(COSQuietButtonStyle())
            .disabled(taskBusy)
        }
        .cosRowCard()
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

    private func openTaskDetail(_ task: TaskRow) {
        guard !isolatedWorkPreview else { return }
        taskDetail = model.workTasks.first { $0.domain == task.domain && ($0.id == task.id || (!$0.workIdentity.isEmpty && $0.workIdentity == task.workIdentity)) } ?? task
        taskDetailDraft = task.text.isEmpty ? task.title : task.text
        taskDoneWhenDraft = task.doneWhen
        taskSavedText = taskDetailDraft
        taskSavedDoneWhen = taskDoneWhenDraft
        taskDetailError = ""
        prepareSchedule(from: task)
    }

    private var taskEditsDirty: Bool {
        taskDetailDraft != taskSavedText || taskDoneWhenDraft != taskSavedDoneWhen
    }

    private func requestCloseTaskDetail() {
        guard !taskDetailBusy else { return }
        if confirmingTaskDismiss { confirmingTaskDismiss = false; return }
        if taskEditsDirty { confirmingTaskDismiss = true } else { closeTaskDetail() }
    }

    private func saveTaskEdits() {
        guard let task = taskDetail, !taskDetailBusy else { return }
        let text = taskDetailDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let finish = taskDoneWhenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { taskDetailError = "Task text cannot be empty."; return }
        runDetailAction {
            try await model.saveWorkTaskEdits(task, text: text, doneWhen: finish)
            taskSavedDoneWhen = finish; taskDoneWhenDraft = finish; taskSavedText = text
        }
    }

    private func closeTaskDetail() {
        confirmingTaskDismiss = false
        taskDetail = nil
        taskDetailDraft = ""
        taskDoneWhenDraft = ""
        taskDetailError = ""
    }

    /// Runs one detail action and keeps the sheet open on failure, because the
    /// message is the only thing that explains why nothing changed.
    private func runDetailAction(_ work: @escaping () async throws -> Void, closeOnSuccess: Bool = true) {
        taskDetailBusy = true
        taskDetailError = ""
        Task {
            defer { taskDetailBusy = false }
            do {
                try await work()
                if ActivitySection.allCases.contains(.work) { await model.loadWorkTasks() }
                if closeOnSuccess { closeTaskDetail() }
                else if let original = taskDetail,
                        let refreshed = (ActivitySection.allCases.contains(.work) ? model.workTasks : model.tasks).first(where: { $0.id == original.id && $0.domain == original.domain }) {
                    taskDetail = refreshed
                }
            } catch {
                taskDetailError = error.localizedDescription
            }
        }
    }

    @ViewBuilder private var taskEditorOverlay: some View {
        if let task = taskDetail {
            ZStack {
                Color.black.opacity(0.22).ignoresSafeArea().contentShape(Rectangle())
                    .onTapGesture { requestCloseTaskDetail() }
                VStack(spacing: 0) {
                    HStack {
                        Text("Edit task").font(COSType.display(18, weight: .medium))
                        Spacer()
                        Button("Close") { requestCloseTaskDetail() }.buttonStyle(COSQuietButtonStyle()).disabled(taskDetailBusy)
                    }.padding(16)
                    Divider()
                    ScrollView { taskDetailSheet(task) }
                }.frame(width: 540, height: 450)
                    .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(COSPalette.line))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private func taskDetailSheet(_ task: TaskRow) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Task name").font(COSType.body(11, weight: .semibold)).foregroundStyle(COSPalette.muted)
            TextEditor(text: $taskDetailDraft)
                .accessibilityLabel("Task name")
                .font(COSType.body(13.5))
                .cosEditor()
                .disabled(taskDetailBusy)
                .frame(minHeight: 72, maxHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(COSPalette.line))
            VStack(alignment: .leading, spacing: 5) {
                Text("DONE WHEN").font(COSType.body(10)).foregroundStyle(
                    task.doneWhen.isEmpty ? Color.orange : Color.secondary)
                HStack(spacing: 8) {
                    TextField("What does finished look like?", text: $taskDoneWhenDraft)
                        .disabled(taskDetailBusy)
                        .textFieldStyle(.plain)
                        .cosField()
                    Button("Set") {
                        // Sheet stays open: setting the finish line is what UNBLOCKS
                        // Run now, so closing here would hide the button it enables.
                        runDetailAction({
                            try await model.saveWorkTaskEdits(task, text: task.text, doneWhen: taskDoneWhenDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                            taskSavedDoneWhen = taskDoneWhenDraft
                        }, closeOnSuccess: false)
                    }
                    .disabled(taskDetailBusy)
                }
                if task.doneWhen.isEmpty {
                    // Named here rather than left to a failed run: the server
                    // refuses the dispatch with 409 done_when_required.
                    Text("Run now needs a finish line.")
                        .font(COSType.body(10.5)).foregroundStyle(.orange)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                detailLine("Domain", task.domain)
                detailLine("Stage", task.stage.capitalized)
                detailLine("Lane", task.column)
                detailLine("Section", task.section)
                if !task.runAt.isEmpty { detailLine("Scheduled", task.runAt) }
                if !task.source.isEmpty { detailLine("Source", task.source) }
                if !task.agentState.isEmpty { detailLine("Agent", task.agentState) }
                detailLine("Ref", task.ref)
            }
            if !taskDetailError.isEmpty {
                Text(taskDetailError).font(COSType.body(11.5)).foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                Button("Cancel") { requestCloseTaskDetail() }.disabled(taskDetailBusy)
                Button("Save changes") { saveTaskEdits() }
                    .disabled(taskDetailBusy || !model.workTaskEditAvailable || taskDetailDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(task.checked ? "Reopen" : "Done") {
                    runDetailAction { try await model.setTaskChecked(id: task.id, domain: task.domain, checked: !task.checked) }
                }
                .disabled(taskDetailBusy || taskEditsDirty)
                Spacer()
            }
            if !model.workTaskEditAvailable {
                Text("Update the server and refresh Work to save task names safely.").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
            }
            HStack(spacing: 8) {
                Button("To inbox") {
                    runDetailAction { try await model.moveTask(id: task.id, domain: task.domain, section: "inbox") }
                }
                .disabled(taskDetailBusy || taskEditsDirty || task.section == "inbox")
                Spacer()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Legacy schedule for").font(COSType.body(11)).foregroundStyle(.secondary)
                DatePicker("Schedule for", selection: $taskRunAt, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden().disabled(taskDetailBusy)
                HStack(spacing: 8) {
                    Button("Schedule") {
                        runDetailAction { try await model.scheduleTask(id: task.id, domain: task.domain, runAt: taskRunAtStamp()) }
                    }.disabled(taskDetailBusy || taskEditsDirty)
                    Button("Legacy run now") {
                        runDetailAction { try await model.runTask(id: task.id, domain: task.domain) }
                    }.disabled(taskDetailBusy || taskEditsDirty || task.agentState == "running" || task.doneWhen.isEmpty)
                    Spacer()
                }
                Text("Uses the existing task dispatcher. Choose a session from Work’s agent workspace for a directed handoff.")
                    .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
            }
            HStack(spacing: 8) {
                Text("Move to").font(COSType.body(11)).foregroundStyle(.secondary)
                ForEach(["planning", "active", "review"], id: \.self) { stage in
                    Button(stage.capitalized) {
                        runDetailAction { try await model.setTaskStage(id: task.id, domain: task.domain, stage: stage) }
                    }
                    .disabled(taskDetailBusy || taskEditsDirty || task.stage == stage)
                }
                Spacer()
            }

        }
        .padding(20)
        .frame(width: 520)
        .buttonStyle(COSQuietButtonStyle())
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(COSType.body(11)).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            Text(value).font(COSType.body(11.5)).textSelection(.enabled)
            Spacer()
        }
    }

    private func taskRunAtStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: taskRunAt)
    }

    /// Prefill Schedule from the row's existing stamp, otherwise now.
    private func prepareSchedule(from task: TaskRow) {
        taskRunAt = task.runAtDate ?? Date()
    }

    @ViewBuilder
    private func taskSchedulePopover(_ task: TaskRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Schedule for")
                .font(COSType.body(11))
                .foregroundStyle(.secondary)
            DatePicker("Schedule for", selection: $taskRunAt, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.compact)
            Button("Set") {
                Task {
                    await scheduleTask(task)
                    schedulePopoverID = nil
                }
            }
            .buttonStyle(COSPrimaryButtonStyle())
            .disabled(taskBusy)
        }
        .padding(12)
        .frame(minWidth: 220)
    }

    private func captureTask() async {
        let text = taskCapture.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        taskBusy = true
        defer { taskBusy = false }
        do {
            try await model.captureTask(domain: taskDomain, text: text)
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

    private func checkTask(_ task: TaskRow) async {
        taskBusy = true
        defer { taskBusy = false }
        do {
            try await model.setTaskChecked(id: task.id, domain: task.domain, checked: !task.checked)
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
                .cosField()
                .frame(maxWidth: 320)
                COSDropdown("Recency", selection: $model.searchRecency,
                            options: SearchRecency.allCases.map { COSDropdownOption($0, $0.title) })
                .fixedSize()
                Spacer()
            }
            if model.isSessionQueryActive, !model.sessionSemanticAvailable {
                Text(sessionSemanticHint)
                    .font(COSType.body(11))
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
                    providerGlyph(session)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title)
                            .font(COSType.body(13.5, weight: .semibold))
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        if !snippet.isEmpty {
                            Text(snippet)
                                .font(COSType.body(11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        HStack(spacing: 8) {
                            providerBadge(session)
                            if session.pinned {
                                Text("PINNED")
                                    .font(COSType.mono(8.5, weight: .bold))
                                    .tracking(0.6)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                            }
                            if session.showsStateChip {
                                Text(session.stateLabel)
                                    .font(COSType.body(10.5, weight: .semibold))
                                    .foregroundStyle(sessionStateTint(session.state))
                            }
                            if let hint = sessionClockHint(session) {
                                Text(hint)
                                    .font(COSType.body(10.5))
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
                                    .font(COSType.body(10.5, weight: .medium))
                                    .foregroundStyle(COSPalette.amber)
                                    .lineLimit(1)
                                    .help("Another session on screen has the same name. This one was opened \(ClaudeSession.shortSessionDate(opened)).")
                            }
                            if session.isScheduledJob, !session.jobScript.isEmpty {
                                // 0.5.229: a job's script says more than its folder.
                                Text(session.jobScript)
                                    .font(COSType.mono(10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else if !session.workspace.isEmpty, session.workspace != session.title {
                                Text(session.workspace)
                                    .font(COSType.body(10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if !session.waitingFor.isEmpty {
                                Text(session.waitingFor)
                                    .font(COSType.body(10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer()
                    if let matchLabel {
                        Text(matchLabel)
                            .font(COSType.mono(9.5, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(ActivitySection.sessions.tint.opacity(0.16)))
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

    /// 0.5.233: a desktop app must be recoverable from its own UI. When the server says
    /// the hooks are missing or drifted, this offers the install; a server before 6.48.0
    /// says update; an unreachable server shows nothing.
    @ViewBuilder private var sessionHooksBanner: some View {
        let state = model.sessionHooksState
        if model.claudeSessionsEnabled, state == "missing" || state == "drift" || state == "script_outdated" || state == "route_absent" {
            HStack(spacing: 10) {
                Circle().fill(COSPalette.amber).frame(width: 7, height: 7)
                Text(state == "route_absent"
                     ? "Live session state needs COS server 6.48.0 or later."
                     : (state == "missing" ? "Claude Code hooks are not installed: sessions read from their transcripts only."
                        : "Claude Code hooks need a refresh (\(state == "drift" ? "settings changed" : "script outdated"))."))
                    .font(COSType.body(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if state == "route_absent" {
                    Button("Update Server") { model.perform("update") }
                        .buttonStyle(COSQuietButtonStyle())
                        .disabled(model.status.meetingWorkBlockingRestart)
                } else {
                    Button(model.sessionHooksInstalling ? "Installing…" : (state == "missing" ? "Install hooks" : "Reinstall hooks")) { model.installSessionHooks() }
                        .buttonStyle(COSQuietButtonStyle(tone: .featured))
                        .disabled(model.sessionHooksInstalling)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background(COSPalette.raised)
        }
        if let note = model.sessionHooksNote {
            Text(note)
                .font(COSType.body(11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.vertical, 6)
        }
    }

    private var sessionsStatus: String {
        if model.isSessionQueryActive {
            if model.sessionSearching { return "Looking up…" }
            return "Lookup across Claude, Codex, and Cursor"
        }
        if model.claudeSessionsLoading { return visibleSessions.isEmpty ? "Loading…" : "Refreshing…" }
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

    private func providerGlyph(_ session: ClaudeSession) -> some View {
        let mark = session.petProviderMark
        let tint = providerTint(session.provider)
        let label = session.provider == "codex" ? "ChatGPT" : session.providerLabel
        return ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.16))
                .frame(width: 28, height: 28)
            Group {
                switch mark {
                case .asset(let name):
                    Image(nsImage: COSBrand.svg(name))
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(tint)
        }
        .accessibilityLabel(label)
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

    /// Open one of a merged record's originals from its detail.
    ///
    /// A merge is additive, so every source is still a real row; this is the way
    /// back to it. A source the server could not name a record for (a G2 capture
    /// whose scribe the pipeline retired) leaves the detail where it is rather
    /// than opening a row that does not exist.
    private func openLibrarySource(_ source: LibraryMeetingSource) {
        guard !source.recordId.isEmpty else { return }
        if let row = model.libraryMeetings.first(where: { $0.recordId == source.recordId }) {
            selectedLibraryRecordID = row.id
            model.openLibraryMeeting(row)
            return
        }
        // Not in the loaded month. A G2 source still has a session, and the
        // speaker review is the surface that owns it.
        if source.kind == "g2" {
            openVoiceReviewFromLibrary(source.sourceId)
        }
    }

    private func openVoiceReviewFromLibrary(_ sessionId: String, _ recordId: String? = nil) {
        speakerSubview = .meetings
        selectedSpeakerSessionID = sessionId
        withOptionalAnimation { section = .speakers }
        model.openSpeakerReview(sessionId: sessionId, recordId: recordId)
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
                COSViewSwitch("Message view", selection: $messagesSubview,
                              options: MessagesSubview.allCases.map { COSViewOption($0, $0.title) }, showsLabel: true)
                .frame(maxWidth: 260, alignment: .leading)
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
                    .textFieldStyle(.plain)
                    .cosField()
                    .frame(maxWidth: 260)
                    .onSubmit { Task { await model.runArchiveSearch() } }
                if model.archiveSearching { ProgressView().controlSize(.small) }
                if !model.archiveQuery.isEmpty {
                    Button("Clear") { model.clearArchiveSearch() }
                        .buttonStyle(COSTextButtonStyle())
                }
                Spacer()
                // The one control in Control that spends model tokens. It
                // lives beside the search it governs rather than in the
                // toolbar, and it carries its cost in its own tooltip.
                Toggle("Meaning", isOn: Binding(
                    get: { model.semanticSearchEnabled },
                    set: { model.setSemanticSearchEnabled($0) }
                ))
                .toggleStyle(COSCheckStyle())
                .font(COSType.body(11))
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
                title: speakerSubview.headerTitle,
                detail: speakerDirectoryDetail,
                refresh: {
                    Task { await loadSpeakerSubview(speakerSubview, refresh: true) }
                },
                refreshDisabled: speakerRefreshDisabled,
                refreshTitle: speakerRefreshTitle,
                refreshProminent: speakerSubview == .meetings && model.meetingsRefreshNeeded
            )

            HStack(spacing: 12) {
                COSViewSwitch("Speaker view", selection: $speakerSubview,
                              options: SpeakerSubview.allCases.map { COSViewOption($0, $0.title) }, showsLabel: true)
                .fixedSize()
                .onChange(of: speakerSubview) { _, next in
                    selectedVoiceName = nil
                    selectedSpeakerSessionID = nil
                    model.closeSpeakerReview()
                    // A naming or discard result belongs to the view it happened in.
                    model.addVoiceResult = nil
                    Task { await loadSpeakerSubview(next, refresh: false) }
                }

                if speakerSubview == .voices {
                    TextField("Search voices", text: $voiceSearch)
                        .textFieldStyle(.plain)
                        .cosField()
                        .frame(maxWidth: 280)
                        .accessibilityLabel("Search enrolled voices")
                    COSDropdown("Sort voices", selection: $voiceSort,
                                options: VoiceDirectorySort.allCases.map { COSDropdownOption($0, $0.title) },
                                showsLabel: false, icon: "arrow.up.arrow.down")
                    .fixedSize()
                    .help("Needs attention puts voices with meetings to review first. Lowest confidence puts the weakest profiles with enough matched speech first.")
                } else if speakerSubview == .meetings {
                    Toggle("Hide reviewed", isOn: Binding(
                        get: { model.hideReviewedMeetings },
                        set: { model.setHideReviewed($0) }
                    ))
                    .toggleStyle(COSCheckStyle())
                    .font(COSType.body(11))
                    .help("Keep finished meetings off the list while you work through names.")
                    COSDropdown("Sort meetings", selection: Binding(
                        get: { model.meetingReviewSort },
                        set: { model.setMeetingReviewSort($0) }
                    ), options: MeetingReviewSort.allCases.map { COSDropdownOption($0, $0.title) },
                        showsLabel: false, icon: "arrow.up.arrow.down")
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

            switch speakerSubview {
            case .meetings: meetingsToReviewList
            case .samples: voiceSamplesPane
            case .voices: voiceDirectoryList
            }
        }
    }

    private var speakerRefreshDisabled: Bool {
        switch speakerSubview {
        case .meetings: model.meetingsLoading
        case .samples: model.extAudioLoading
        case .voices: model.voiceDirectoryLoading
        }
    }

    /// One loader per view, shared by the picker, the pane's Refresh and opening the
    /// section, so the three cannot drift apart. Samples reload the held sessions and
    /// the grouped voices together (loadExtAudio awaits loadHeldGroups).
    private func loadSpeakerSubview(_ view: SpeakerSubview, refresh: Bool) async {
        switch view {
        case .meetings: await model.loadReviewableMeetings()
        case .samples:
            await model.loadExtAudio()
            // The directory's names back the "Adds to" hint while naming a voice.
            if model.voiceDirectory.isEmpty { await model.loadVoiceDirectory() }
        case .voices: await model.loadVoiceDirectory(refresh: refresh)
        }
    }

    private var speakerDirectoryDetail: String {
        if speakerSubview == .samples { return heldSamplesDetail }
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
        let samples = model.voiceDirectory.reduce(0) { $0 + $1.embeddings }
        return "\(formatted(model.voiceDirectory.count)) enrolled · \(formatted(samples)) sample\(samples == 1 ? "" : "s") · \(formatted(review)) review occurrence\(review == 1 ? "" : "s")"
    }

    /// The Samples to review hero line: the counts at a glance, like the other two views.
    private var heldSamplesDetail: String {
        if model.heldGroupsState == nil { return "Asking the server what it is holding." }
        if model.heldGroupsState == "error" { return "Held voices could not be grouped. The card says why." }
        if model.extAudioLoadFailed && !heldGroupsUsable { return "Held audio could not be read. Refresh to try again." }
        if heldGroupsUsable {
            let voices = model.heldGroups.count
            let loose = model.heldLoose.count
            if voices == 0 && loose == 0 { return "Unrecognized voices wait here for 72 hours." }
            return "\(formatted(voices)) held voice\(voices == 1 ? "" : "s") · \(formatted(loose)) loose sample\(loose == 1 ? "" : "s") · kept 72 hours"
        }
        let sessions = model.extAudioSessions.count
        if sessions == 0 { return "Unrecognized voices wait here for 72 hours." }
        return "\(formatted(sessions)) unrecognized session\(sessions == 1 ? "" : "s") · kept 72 hours"
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
    /// Floor for the scrolling list once the limit is passed (0.5.222). The card has its
    /// own view now, so the list takes the height the window has instead of a fixed 250;
    /// Rows are 53 to 88 pt, so the floor keeps at least one visible in a short window,
    /// and the window's content clamp keeps even that from pushing the toolbar off.
    private static let extAudioListMinHeight: CGFloat = 88

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
        // 0.5.221 — the card speaks the gotcos vocabulary the rest of the window
        // uses (Miles, 2026-09-13: "the blue links are kinda odd"): card fill and
        // hairline, Fraunces title, DM Sans prose, JetBrains Mono for counts, COS
        // chips and text actions instead of system link buttons. Every color is
        // an adaptive COSPalette token, so light and dark both hold.
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(COSPalette.gold.opacity(0.16))
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(COSPalette.accent)
                }
                .frame(width: 34, height: 34)
                Text("Add a voice").font(COSType.display(18, weight: .medium))
                Spacer()
                // The pane hero's Refresh reloads this view (0.5.222); a second one on the
                // card was two buttons doing one thing.
                if model.extAudioLoading && model.heldGroupsState != nil { ProgressView().controlSize(.small) }
            }

            if let result = model.addVoiceResult {
                addVoiceNotice(result)
            }
            if model.heldNamingAvailable {
                heldNamingStatusBar
            } else if model.heldGroupsState != nil {
                Text("Update the COS server to 6.46.0 or newer to preview, apply and undo meeting labels.")
                    .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
            }

            // 0.5.219 — a server that groups held voices (6.45.4) gets the grouped
            // panel; an older one keeps the per-session rows below, unchanged.
            // 0.5.222 — until the grouping route has answered at all, the per-session
            // rows are a guess, not a fallback: their Name uses enroll-ext, the path that
            // wrote one household voice into two profiles on 2026-09-12. Say it is loading.
            if model.heldGroupsState == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Grouping held voices…")
                        .font(COSType.body(12)).foregroundStyle(COSPalette.muted)
                }
                .padding(.vertical, 6)
            } else if heldGroupsUsable {
                heldGroupsBody
            } else if model.extAudioSessions.isEmpty {
                heldGroupsFallbackNote
                Text(model.extAudioError
                     ?? "No unrecognized audio is being held. Record a meeting, then come back within 72 hours.")
                    .font(COSType.body(12)).foregroundStyle(COSPalette.muted)
            } else {
                heldGroupsFallbackNote
                Text(extAudioLead)
                    .font(COSType.body(12)).foregroundStyle(COSPalette.muted)
                // Said BEFORE the list (0.5.222): a short window clips the bottom of the
                // card first, and this is the only line that says naming uses the audio up.
                Text("A session can hold more than one unknown speaker, and naming it uses up the audio.")
                    .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
                // BOUNDED, ALWAYS. The server holds unrecognized audio for 72 hours, so a
                // busy week is dozens of sessions. Until 0.5.222 this card sat OUTSIDE the
                // voice directory's ScrollView, and an uncapped ForEach grew the layout past
                // the window and carried the section header, the view picker and the
                // breadcrumbs off screen (production, 2026-08-26, 30+ held sessions). Short
                // lists keep their natural height; long ones scroll in place in the card's
                // own view, above a floor of about one row.
                VStack(alignment: .leading, spacing: 0) {
                    if model.extAudioSessions.count > Self.extAudioInlineRowLimit {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(model.extAudioSessions) { session in
                                    heldRowDivider
                                    addVoiceRow(session)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: Self.extAudioListMinHeight, maxHeight: .infinity)
                    } else {
                        ForEach(model.extAudioSessions) { session in
                            heldRowDivider
                            addVoiceRow(session)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(COSPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(COSPalette.line, lineWidth: 1))
        .frame(maxWidth: 980)
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }

    /// SAMPLES TO REVIEW (0.5.222): Add a voice alone in its own view, so its list fills
    /// the pane instead of competing with the voice directory for the window's height.
    private var voiceSamplesPane: some View {
        addVoiceSection
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// A result or a reason, set on the card's raised strip rather than as loose
    /// grey text, so it reads as the answer to what was just done.
    private func addVoiceNotice(_ text: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(COSPalette.accent)
            Text(text)
                .font(COSType.body(11.5))
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 8))
    }

    /// The hairline between rows inside the Add-a-voice card.
    private var heldRowDivider: some View {
        Rectangle().fill(COSPalette.line).frame(height: 1)
    }

    /// Width of the Listen column, so play controls line up down the list.
    private static let heldListenColumnWidth: CGFloat = 136

    // ── 0.5.219 — held voices grouped by who they sound like ────────────────
    //
    // Miles, 2026-09-12: "group those samples together… clump users together so
    // that we're not constantly having to train… ability to throw out those
    // samples." A row is a VOICE across meetings, not a session; a suggested
    // name is one click; the loose samples that match nothing can be thrown out
    // or, hearing a real person in one, named on their own.

    /// Rows shown at natural height before the list starts scrolling in place.
    private static let heldGroupInlineRowLimit = 4
    /// Same floor as `extAudioListMinHeight`. The fixed 300 this replaced left the card
    /// taller than a 680-point window once it sat above the directory (Miles, 2026-09-13).
    private static let heldGroupListMinHeight: CGFloat = 88

    /// The grouped view stands in for the per-session rows only when the server
    /// answered the route AND could actually group what it holds. With the
    /// speaker model not loaded (or every sample still being read) the grouped
    /// answer is empty while wavs sit on disk; then the sessions stay visible
    /// and `heldGroupsFallbackNote` says why (QA 2026-09-12).
    private var heldGroupsUsable: Bool {
        model.heldGroupsState == "ready" && !(model.heldGroupsEmbedded == 0 && model.heldGroupsSamples > 0)
    }

    @ViewBuilder
    private var heldGroupsFallbackNote: some View {
        if model.heldGroupsState == "error", let error = model.heldGroupsError {
            addVoiceNotice("Voices could not be grouped: \(error)")
        } else if model.heldGroupsState == "ready", model.heldGroupsEmbedded == 0, model.heldGroupsSamples > 0 {
            addVoiceNotice(model.heldGroupsSpeakerModel
                 ? "\(model.heldGroupsSamples) held samples are still being read for grouping. Refresh in a moment."
                 : "\(model.heldGroupsSamples) held samples cannot be grouped yet: the speaker model is not loaded on this Mac (Run Doctor shows it). The sessions are listed below.")
        }
    }

    private var heldGroupsLead: String {
        let voices = model.heldGroups.count
        let loose = model.heldLoose.count
        let pending = model.heldGroupsPending
        if voices == 0 && loose == 0 {
            return pending > 0
                ? "Reading \(pending) held sample\(pending == 1 ? "" : "s"). Refresh in a moment."
                : "No unrecognized audio is being held. Record a meeting, then come back within 72 hours."
        }
        var parts: [String] = []
        if voices > 0 { parts.append("\(voices) voice\(voices == 1 ? "" : "s") the server is holding, grouped by who they sound like across meetings.") }
        if loose > 0 {
            let suggested = model.heldLoose.filter { $0.suggestion != nil }.count
            parts.append("\(loose) loose sample\(loose == 1 ? "" : "s") to review individually\(suggested > 0 ? ", \(suggested) with a suggestion" : "").")
        }
        if pending > 0 { parts.append("\(pending) still being read.") }
        if model.heldGroupsUnusable > 0 { parts.append("\(model.heldGroupsUnusable) could not be read and will expire with the window.") }
        // Naming needs the model on the server side; listening and discarding do not.
        if !model.heldGroupsSpeakerModel { parts.append("The speaker model is not loaded on this Mac (Run Doctor shows it): voices can be heard and discarded, not named yet.") }
        return parts.joined(separator: " ")
    }

    @ViewBuilder
    private var heldGroupsBody: some View {
        let rows = model.heldGroups.count + model.heldLoose.count
        VStack(alignment: .leading, spacing: 10) {
            Text(heldGroupsLead)
                .font(COSType.body(12)).foregroundStyle(COSPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            // The explanation stays above the scrolling rows, including an empty window after Apply.
            if rows > 0 {
                Text(model.heldNamingAvailable
                     ? "Preview first. Apply adds voice samples, labels matching segments in their own meetings, and uses up the audio. Discarding throws the audio out."
                     : "Listen to or discard held audio. Naming needs server 6.46.0 or newer.")
                    .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
            }
            if rows > Self.heldGroupInlineRowLimit {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) { heldGroupRows }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: Self.heldGroupListMinHeight, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) { heldGroupRows }
            }
        }
        // After a naming or a discard the samples under every cursor are gone;
        // start each row over rather than land on a sample nobody heard.
        .onChange(of: model.heldGroupsGeneration) { _, _ in
            heldGroupCursor = [:]
            confirmingHeldDiscard = nil
        }
    }

    @ViewBuilder
    private var heldGroupRows: some View {
        ForEach(model.heldGroups) { group in
            heldRowDivider
            heldGroupRow(group)
        }
        ForEach(model.heldLoose) { current in
            heldRowDivider
            heldLooseRow(current)
        }
    }

    @ViewBuilder
    private func heldGroupRow(_ group: HeldVoiceGroup) -> some View {
        let meetings = group.sessions.count
        HStack(alignment: .center, spacing: 14) {
            heldMembersListenControl(key: group.id, members: group.playOrder, voice: "heldgroup:\(group.id)")
                .frame(width: Self.heldListenColumnWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(group.sampleCount) sample\(group.sampleCount == 1 ? "" : "s")")
                        .font(COSType.body(13, weight: .semibold))
                    Text("\(meetings) MEETING\(meetings == 1 ? "" : "S")")
                        .font(COSType.mono(9.5)).tracking(0.6)
                        .foregroundStyle(COSPalette.muted)
                }
                if let name = group.suggestionName {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(group.suggestionTier == "high" ? "Sounds like" : "May be")
                            .font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
                        Text(name)
                            .font(COSType.body(11.5, weight: .semibold)).foregroundStyle(COSPalette.accent)
                        Text(group.suggestionOf > 0
                             ? "\(Int((group.suggestionSimilarity * 100).rounded()))% · \(group.suggestionAgreeing) of \(group.suggestionOf) samples agree"
                             : "\(Int((group.suggestionSimilarity * 100).rounded()))%")
                            .font(COSType.mono(9.5)).monospacedDigit()
                            .foregroundStyle(COSPalette.muted)
                    }
                    .lineLimit(1)
                }
                if group.ownerCaution {
                    Text("Also close to the owner voice. Listen carefully.")
                        .font(COSType.body(10.5)).foregroundStyle(COSPalette.accent)
                }
                if let note = model.playbackNote, note.voice == "heldgroup:\(group.id)" {
                    Text(note.text).font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            heldGroupActions(group)
        }
        .padding(.vertical, 12)
    }

    /// Both suggestion tiers open the same read-only preview before Apply.
    @ViewBuilder
    private func heldGroupActions(_ group: HeldVoiceGroup) -> some View {
        HStack(spacing: 8) {
            if let name = group.suggestionName, model.namingHeldGroup != group.id, confirmingHeldDiscard != group.id {
                Button("Add to \(name)") { Task { await model.nameHeld(group.members, as: name) } }
                    .buttonStyle(COSPrimaryButtonStyle())
                    .disabled(model.addVoiceBusy || !model.heldGroupsSpeakerModel || !model.heldNamingAvailable)
            }
            heldActionRow(key: group.id, members: group.members, count: group.sampleCount)
        }
    }

    @ViewBuilder
    private func heldLooseRow(_ current: HeldSampleRef) -> some View {
        HStack(alignment: .center, spacing: 14) {
            heldMembersListenControl(key: current.id, members: [current], voice: "heldloose:\(current.id)")
                .frame(width: Self.heldListenColumnWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text("Loose sample").font(COSType.body(13, weight: .semibold))
                if let suggestion = current.suggestion {
                    Text("Sounds like \(suggestion.name) · \(Int((suggestion.similarity * 100).rounded()))%")
                        .font(COSType.body(11.5, weight: .medium)).foregroundStyle(COSPalette.accent)
                    Text("\(suggestion.agreeing) voice samples agree")
                        .font(COSType.mono(9.5)).foregroundStyle(COSPalette.muted)
                    if suggestion.ownerCaution {
                        Text("Also close to the owner voice. Listen carefully.")
                            .font(COSType.body(10.5)).foregroundStyle(COSPalette.accent)
                    }
                } else {
                    Text("No existing voice suggestion").font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
                }
                Text(Self.heldSampleLabel(current))
                    .font(COSType.mono(10)).foregroundStyle(COSPalette.muted)
                if let note = model.playbackNote, note.voice == "heldloose:\(current.id)" {
                    Text(note.text).font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 7) {
                if let suggestion = current.suggestion, model.namingHeldGroup != "loose:\(current.id)", confirmingHeldDiscard != "loose:\(current.id)" {
                    Button("Add to \(suggestion.name)") { Task { await model.nameHeld([current], as: suggestion.name) } }
                        .buttonStyle(COSPrimaryButtonStyle())
                        .disabled(model.addVoiceBusy || !model.heldGroupsSpeakerModel || !model.heldNamingAvailable)
                }
                heldActionRow(key: "loose:\(current.id)", members: [current], count: 1)
            }
        }
        .padding(.vertical, 12)
        .accessibilityIdentifier("held-sample-\(current.id)")
    }

    private var heldNamingOverlayOpen: Bool {
        model.heldNamingShowReview || heldNamingResultOpen || heldNamingHistoryOpen
    }

    private func closeHeldNamingOverlay() {
        if model.heldNamingShowReview { model.cancelHeldNamingPreview() }
        heldNamingResultOpen = false
        heldNamingHistoryOpen = false
    }

    @ViewBuilder
    private var heldNamingStatusBar: some View {
        HStack(spacing: 10) {
            let interrupted = model.heldNamingBatches.filter(\.needsReview).count
            if interrupted > 0 {
                Button("Review \(interrupted) interrupted naming\(interrupted == 1 ? "" : "s")") { heldNamingHistoryOpen = true }
                    .buttonStyle(COSQuietButtonStyle())
            } else if !model.heldNamingBatches.isEmpty {
                Button("Recent naming (\(model.heldNamingBatches.count))") { heldNamingHistoryOpen = true }
                    .buttonStyle(COSQuietButtonStyle())
            }
            if let receipt = model.heldNamingResult {
                Button(receipt.kind == "undone" ? "Undo result" : "Naming result") { heldNamingResultOpen = true }
                    .buttonStyle(COSTextButtonStyle())
                if let handle = receipt.undoHandle, receipt.kind != "undone" || receipt.partial {
                    Button("Undo labels") { heldNamingUndoHandle = handle }
                        .buttonStyle(COSQuietButtonStyle())
                        .disabled(model.addVoiceBusy || !model.heldNamingAvailable)
                }
            }
            if let error = model.heldNamingHistoryError {
                Text(error).font(COSType.body(10.5)).foregroundStyle(COSPalette.muted).lineLimit(2)
            }
            Spacer(minLength: 0)
            if model.heldLoose.count > 1 {
                if confirmingHeldDiscard == "loose-all" {
                    Button("Discard all \(model.heldLoose.count)?") {
                        confirmingHeldDiscard = nil
                        Task { await model.discardHeld(model.heldLoose) }
                    }
                    .buttonStyle(COSQuietButtonStyle(tone: .destructive))
                    .disabled(model.addVoiceBusy)
                    Button("Keep") { confirmingHeldDiscard = nil }.buttonStyle(COSTextButtonStyle())
                } else {
                    Button("Discard all loose") { confirmingHeldDiscard = "loose-all" }
                        .buttonStyle(COSTextButtonStyle(tone: .destructive))
                        .disabled(model.addVoiceBusy)
                }
            }
        }
    }

    /// Name (a new person, or an existing one by typing their name) or discard.
    /// Discard is TWO clicks: the audio is gone for good, and a list of rows is
    /// a lot of buttons a cursor can land on by accident.
    @ViewBuilder
    private func heldActionRow(key: String, members: [HeldSampleRef], count: Int) -> some View {
        if model.namingHeldGroup == key {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Who is this?", text: $heldGroupName)
                        .textFieldStyle(.plain)
                        .cosField()
                        .frame(width: 190)
                        .onSubmit { commitHeldName(members) }
                    Button("Preview") { commitHeldName(members) }
                        .buttonStyle(COSPrimaryButtonStyle())
                        .disabled(model.addVoiceBusy || !model.heldGroupsSpeakerModel || !model.heldNamingAvailable
                                  || heldGroupName.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                    Button("Cancel") {
                        model.namingHeldGroup = nil
                        heldGroupName = ""
                    }
                    .buttonStyle(COSTextButtonStyle())
                    if model.addVoiceBusy { ProgressView().controlSize(.small) }
                }
                nameHint(heldGroupName) { heldGroupName = $0 }
            }
        } else if confirmingHeldDiscard == key {
            HStack(spacing: 8) {
                Text("Discard \(count) sample\(count == 1 ? "" : "s")?")
                    .font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
                Button("Discard") {
                    confirmingHeldDiscard = nil
                    Task { await model.discardHeld(members) }
                }
                .buttonStyle(COSQuietButtonStyle(tone: .destructive))
                .disabled(model.addVoiceBusy)
                Button("Keep") { confirmingHeldDiscard = nil }
                    .buttonStyle(COSTextButtonStyle())
            }
        } else {
            HStack(spacing: 8) {
                Button(count == 1 ? "Name this sample" : "Name this voice") {
                    model.namingHeldGroup = key
                    heldGroupName = ""
                }
                .buttonStyle(COSQuietButtonStyle())
                .disabled(model.addVoiceBusy || !model.heldGroupsSpeakerModel || !model.heldNamingAvailable)
                Button("Discard") { confirmingHeldDiscard = key }
                    .buttonStyle(COSTextButtonStyle(tone: .destructive))
                    .disabled(model.addVoiceBusy)
            }
        }
    }

    /// Match the server's compatibility normalization and case-folded name lookup.
    /// Ambiguous duplicates cannot be treated as a unique existing profile.
    @ViewBuilder
    private func nameHint(_ typed: String, fill: @escaping @MainActor (String) -> Void) -> some View {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count >= 2 {
            let folded = name.precomposedStringWithCompatibilityMapping.lowercased()
            let matches = model.voiceDirectory.filter { $0.name.precomposedStringWithCompatibilityMapping.lowercased() == folded }
            let exact = matches.count == 1 ? matches.first : nil
            let near = matches.isEmpty
                ? Array(model.voiceDirectory.filter { $0.name.localizedCaseInsensitiveContains(name) }.prefix(3))
                : []
            // Two lines, not one: squeezed beside the chips, the sentence wrapped mid-phrase.
            VStack(alignment: .leading, spacing: 4) {
                if matches.count > 1 {
                    Text("Several stored voices share this spelling. Resolve the duplicate names before applying.")
                } else if let exact {
                    Text("Adds to \(exact.name), who has \(exact.embeddings) sample\(exact.embeddings == 1 ? "" : "s").")
                    if exact.embeddings >= 40 { Text("At the 40-sample limit, the server chooses which voice samples to keep.") }
                    if exact.isOwner { Text("This is your owner voice. Preview requires owner verification.") }
                } else {
                    Text("Creates a new voice.")
                    if !near.isEmpty {
                        HStack(spacing: 6) {
                            Text("Did you mean")
                            ForEach(near) { person in
                                Button(person.name) { fill(person.name) }
                                    .buttonStyle(COSQuietButtonStyle())
                            }
                        }
                    }
                }
            }
            .font(COSType.body(10.5))
            .foregroundStyle(COSPalette.muted)
        }
    }

    private func commitHeldName(_ members: [HeldSampleRef]) {
        let name = heldGroupName
        Task {
            await model.nameHeld(members, as: name)
            // Keep what was typed when the server refused (a sentence for a name,
            // a set that is not one voice): the field closes only on success.
            if model.namingHeldGroup == nil { heldGroupName = "" }
        }
    }

    /// "Sep 12, 3:41 PM · chunk 9" for a `meeting_<ms>_<rand>` session, else the raw id.
    static func heldSampleLabel(_ ref: HeldSampleRef) -> String {
        let parts = ref.sessionId.split(separator: "_")
        if parts.count >= 2, parts[0] == "meeting", let ms = Double(parts[1]), ms > 1_000_000_000_000 {
            let date = Date(timeIntervalSince1970: ms / 1000)
            let f = DateFormatter()
            f.dateFormat = "MMM d, h:mm a"
            return "\(f.string(from: date)) · chunk \(ref.chunkIndex)"
        }
        return "\(ref.sessionId) · chunk \(ref.chunkIndex)"
    }

    /// Play or stop one held sample and step through the rest: the one Listen
    /// control for held groups, loose samples and held sessions.
    private func heldListenStrip(
        playing: Bool,
        position: Int,
        total: Int,
        play: @escaping @MainActor () -> Void,
        previous: @escaping @MainActor () -> Void,
        next: @escaping @MainActor () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Button(action: play) {
                Image(systemName: playing ? "stop.fill" : "play.fill")
            }
            .buttonStyle(COSIconButtonStyle(size: 28, prominent: playing))
            .help(playing ? "Stop" : "Listen to this sample")
            .accessibilityLabel(playing ? "Stop" : "Listen to sample \(position) of \(total)")
            Button(action: previous) { Image(systemName: "chevron.left") }
                .buttonStyle(COSIconButtonStyle(size: 20))
                .help("Previous sample")
                .disabled(total < 2)
            Text("\(position) of \(total)")
                .font(COSType.mono(10)).monospacedDigit()
                .foregroundStyle(COSPalette.muted)
                .lineLimit(1)
            Button(action: next) { Image(systemName: "chevron.right") }
                .buttonStyle(COSIconButtonStyle(size: 20))
                .help("Next sample")
                .disabled(total < 2)
        }
    }

    /// The 0.5.218 Listen control over any list of held samples: a group's
    /// members (seed first) or the loose ones. Plays through the shared player.
    @ViewBuilder
    private func heldMembersListenControl(key: String, members: [HeldSampleRef], voice: String) -> some View {
        if members.isEmpty {
            EmptyView()
        } else {
            heldMembersListenControlBody(key: key, members: members, voice: voice)
        }
    }

    @ViewBuilder
    private func heldMembersListenControlBody(key: String, members: [HeldSampleRef], voice: String) -> some View {
        let cursor = min(max(heldGroupCursor[key] ?? 0, 0), members.count - 1)
        let ref = members[cursor]
        let playKey = model.heldGroupSampleKey(ref)
        heldListenStrip(
            playing: model.playingVoice == playKey,
            position: cursor + 1,
            total: members.count,
            play: { model.playHeldGroupSample(ref, voice: voice) },
            previous: {
                model.stopPlayback()
                heldGroupCursor[key] = (cursor - 1 + members.count) % members.count
            },
            next: {
                model.stopPlayback()
                heldGroupCursor[key] = (cursor + 1) % members.count
            }
        )
    }

    @ViewBuilder
    private func addVoiceRow(_ session: ExtAudioSession) -> some View {
        HStack(alignment: .center, spacing: 14) {
            if !session.chunkIndices.isEmpty {
                heldSampleListenControl(session)
                    .frame(width: Self.heldListenColumnWidth, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(session.chunks) sample\(session.chunks == 1 ? "" : "s")")
                    .font(COSType.body(13, weight: .semibold))
                Text("EXPIRES IN \(session.expiresIn.uppercased())")
                    .font(COSType.mono(9.5)).tracking(0.6)
                    .foregroundStyle(COSPalette.muted)
                if let note = model.playbackNote, note.voice == "held:\(session.sessionId)" {
                    Text(note.text).font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.addingVoiceSession == session.sessionId {
                addVoiceNameField(session)
            } else {
                Button("Name this voice") { model.addingVoiceSession = session.sessionId }
                    .buttonStyle(COSQuietButtonStyle())
                    .disabled(true)
                    .help("Wait for sample grouping, or update the server to 6.46.0, to preview a name safely.")
            }
        }
        .padding(.vertical, 12)
    }

    /// 0.5.218 — Listen before naming: play one held chunk, step through the rest.
    /// Shown only when the server reported chunk indices, so the button never
    /// appears where the click would fail (an older server hides it).
    @ViewBuilder
    private func heldSampleListenControl(_ session: ExtAudioSession) -> some View {
        let indices = session.chunkIndices
        let cursor = min(max(heldSampleCursor[session.sessionId] ?? 0, 0), indices.count - 1)
        let chunkIndex = indices[cursor]
        let key = model.heldSampleKey(session.sessionId, chunkIndex: chunkIndex)
        heldListenStrip(
            playing: model.playingVoice == key,
            position: cursor + 1,
            total: indices.count,
            play: { model.playHeldSample(session, chunkIndex: chunkIndex) },
            previous: {
                model.stopPlayback()
                heldSampleCursor[session.sessionId] = (cursor - 1 + indices.count) % indices.count
            },
            next: {
                model.stopPlayback()
                heldSampleCursor[session.sessionId] = (cursor + 1) % indices.count
            }
        )
    }

    @ViewBuilder
    private func addVoiceNameField(_ session: ExtAudioSession) -> some View {
        HStack(spacing: 8) {
            TextField("Who is this?", text: $addVoiceName)
                .textFieldStyle(.plain)
                .cosField()
                .frame(width: 190)
                .onSubmit { commitAddVoice(session) }
            Button("Save") { commitAddVoice(session) }
                .buttonStyle(COSPrimaryButtonStyle())
                .disabled(model.addVoiceBusy
                          || addVoiceName.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
            Button("Cancel") {
                model.addingVoiceSession = nil
                addVoiceName = ""
            }
            .buttonStyle(COSTextButtonStyle())
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
            // A ZERO-PROFILE USER IS WHO NEEDS ADD A VOICE MOST. An empty state that only
            // explained the problem is what sent Chelsie to Discord instead of to the fix
            // (2026-08-24). The card has its own view now (0.5.222), so this state names it
            // and opens it in one click. A failed load is not "nobody enrolled": it retries.
            VStack(spacing: 14) {
                sectionGlyph(.speakers, large: true)
                if model.voiceDirectoryLoadFailed {
                    Text("The voice directory could not be loaded.")
                        .font(COSType.body(12.5, weight: .medium))
                    Text(model.voiceDirectoryError ?? "The helper did not answer.")
                        .font(COSType.body(12))
                        .foregroundStyle(COSPalette.muted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    Button("Retry") { Task { await model.loadVoiceDirectory(refresh: true) } }
                        .buttonStyle(COSQuietButtonStyle())
                } else {
                    Text("No voice profiles are enrolled yet.")
                        .font(COSType.body(12.5, weight: .medium))
                    Text("Voices the glasses did not recognize are held for 72 hours under " + SpeakerSubview.samples.title + ". Listen to one and name it to start a profile, or say \"enroll my voice\" on the glasses.")
                        .font(COSType.body(12))
                        .foregroundStyle(COSPalette.muted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    Button("Open " + SpeakerSubview.samples.title) { speakerSubview = .samples }
                        .buttonStyle(COSPrimaryButtonStyle())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(30)
        } else {
            VStack(spacing: 0) {
                if let error = model.voiceDirectoryError {
                    directoryNotice(error, stale: model.voiceDirectoryRouteAvailable != false)
                }
                if model.voiceDirectoryUnresolvedMeetings > 0 {
                    directoryNotice(
                        "\(formatted(model.voiceDirectoryUnresolvedSegments)) unidentified segments remain local to \(formatted(model.voiceDirectoryUnresolvedMeetings)) meeting\(model.voiceDirectoryUnresolvedMeetings == 1 ? "" : "s"). They are not treated as one person.",
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
                            Rectangle().fill(COSPalette.line).frame(height: 1).padding(.leading, 52)
                        }
                        if visibleVoices.isEmpty {
                            VStack(spacing: 10) {
                                Text("No voices match \u{201C}\(voiceSearch)\u{201D}.")
                                    .font(COSType.body(12)).foregroundStyle(COSPalette.muted)
                                Button("Clear search") { voiceSearch = "" }
                                    .buttonStyle(COSQuietButtonStyle())
                            }
                            .padding(.vertical, 28)
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

    /// Column widths shared by the header and every row, so the two cannot drift apart.
    private static let voiceSamplesColumn: CGFloat = 64
    private static let voiceConfidenceColumn: CGFloat = 86
    private static let voiceCountColumn: CGFloat = 70
    private static let voiceLastSeenColumn: CGFloat = 88
    private static let voiceChevronColumn: CGFloat = 12
    /// Below this many SCORED segments a confident share swings with one segment, so the row
    /// says "thin" and Lowest confidence sorts it after voices with a real basis. A display
    /// and sort choice made in Control, not a server threshold.
    static let confidenceMinimumBasis = 10

    private var voiceDirectoryColumnHeader: some View {
        HStack(spacing: 12) {
            Text("VOICE").frame(maxWidth: .infinity, alignment: .leading)
            Text("SAMPLES").frame(width: Self.voiceSamplesColumn, alignment: .trailing)
                .help("Voiceprints stored in this person's profile.")
            Text("CONFIDENCE").frame(width: Self.voiceConfidenceColumn, alignment: .trailing)
                .help("Share of this voice's scored speech the server matched confidently. Under it: the average match across that speech, marked thin below \(Self.confidenceMinimumBasis) scored segments.")
            Text("MEETINGS").frame(width: Self.voiceCountColumn, alignment: .trailing)
            Text("SEGMENTS").frame(width: Self.voiceCountColumn, alignment: .trailing)
            Text("LAST SEEN").frame(width: Self.voiceLastSeenColumn, alignment: .trailing)
            Color.clear.frame(width: Self.voiceChevronColumn)
        }
        .font(COSType.mono(9, weight: .semibold))
        .foregroundStyle(COSPalette.muted)
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
                    Text(person.name)
                        .font(COSType.body(12.5, weight: .semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    if person.isOwner { statusPill("OWNER", tint: COSPalette.green).fixedSize() }
                    if person.needsAttention { statusPill("REVIEW", tint: COSPalette.amber).fixedSize() }
                }
                Text(voiceSourceLine(person))
                    .font(COSType.body(10.5))
                    .foregroundStyle(COSPalette.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Samples come from the profile itself, so they show on any server.
            metric(formatted(person.embeddings), sub: nil, width: Self.voiceSamplesColumn)
            metric(historyAvailable ? confidenceValue(person) : "—", sub: historyAvailable ? confidenceDetail(person) : "update server", width: Self.voiceConfidenceColumn)
            metric(historyAvailable ? formatted(person.meetingCount) : "—", sub: historyAvailable && person.reviewMeetingCount > 0 ? "\(formatted(person.reviewMeetingCount)) review" : nil, width: Self.voiceCountColumn)
            metric(historyAvailable ? formatted(person.assertedSegments) : "—", sub: historyAvailable && person.candidateSegments > 0 ? "+\(formatted(person.candidateSegments)) review" : nil, width: Self.voiceCountColumn)
            metric(historyAvailable ? (person.lastSeen ?? "Never") : "—", sub: nil, width: Self.voiceLastSeenColumn)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(COSPalette.muted)
                .frame(width: Self.voiceChevronColumn)
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
                                        Text(meeting.dateLine(clock: model.clockStyle))
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


    // MARK: - Memories (the reviewed prototype, on live data)

    /// The Memories tab is the design prototype Miles reviewed
    /// (wk36_2026/design/cos-control-learning/index.html), hosted in a web view
    /// and fed through the helper: every op the page posts is answered by the
    /// same commands the native panes use. The native panes remain the fallback
    /// when the bundle is absent, so a broken resource copy never blanks the tab.
    @ViewBuilder
    private func memoriesSurface() -> some View {
        if MemoriesWebView.bundleURL != nil {
            MemoriesWebView(model: model, initialView: memoriesOpenView, openSection: { section in select(section) })
        } else {
            memoriesPane()
        }
    }

    // MARK: - Memories (Recent learning · All memories · To review · Knowledge)

    private enum LearningFilter { case recent, toReview }

    @ViewBuilder
    private func memoriesPane() -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                COSViewSwitch("Memories view", selection: $memoriesSubview,
                              options: MemoriesSubview.allCases.map { COSViewOption($0, $0.title) }, showsLabel: true)
                .frame(maxWidth: 460, alignment: .leading)
                .onChange(of: memoriesSubview) { _, next in
                    // A switch unwinds every drill-through, or an open lesson would
                    // survive into Knowledge and render under the wrong segment.
                    selectedContextID = nil
                    selectedLearningID = nil
                    selectedGraphEntityID = nil
                    model.closeContextDetail()
                    model.closeLearningDetail()
                    model.closeGraphEntity()
                    Task { await loadMemoriesSubview(next) }
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { Divider() }
            switch memoriesSubview {
            case .allMemories: contextList(kind: "memory")
            case .recentLearning: learningList(filter: .recent)
            case .toReview: learningList(filter: .toReview)
            case .knowledge: knowledgePane()
            }
        }
    }

    private func loadMemoriesSubview(_ view: MemoriesSubview? = nil) async {
        switch view ?? memoriesSubview {
        case .allMemories:
            if model.status.memoryAvailable == true { await model.loadContextRecords(kind: "memory") }
        case .recentLearning:
            await model.loadLearningEvents()
        case .toReview:
            await model.loadToReviewEvents()
        case .knowledge:
            await model.loadGraphStatus()
        }
    }

    /// A lesson's source record, when it is a memory the All memories list can
    /// open. Other stores have no record route in 0.5.190 and offer no button.
    private func openLearningSource(_ event: LearningEvent) {
        guard event.store == "bot_memory", !event.lessonID.isEmpty else { return }
        let record = ContextRecord.memory(["id": .string(event.lessonID), "summary": .string(event.title)])
        selectedLearningID = nil
        model.closeLearningDetail()
        memoriesSubview = .allMemories
        selectedContextID = record.id
        model.openContextRecord(record, kind: "memory")
        // The picker is unmounted while a detail shows, so its onChange never
        // fires here; load the segment explicitly (QA 2026-09-06).
        Task { await loadMemoriesSubview(.allMemories) }
    }

    /// Carry a lesson's focus into Knowledge as a SEARCH: the term is a
    /// category or a few title words, rarely an exact entity, so opening an
    /// entity pane straight away answered not-found as the normal case.
    private func exploreInGraph(_ term: String) {
        selectedLearningID = nil
        model.closeLearningDetail()
        memoriesSubview = .knowledge
        model.graphQuery = term
        model.scheduleGraphSearch()
        Task { await loadMemoriesSubview(.knowledge) }
    }

    private func openMemoryFromGraph(_ record: ContextRecord) {
        selectedGraphEntityID = nil
        model.closeGraphEntity()
        memoriesSubview = .allMemories
        selectedContextID = record.id
        model.openContextRecord(record, kind: "memory")
        Task { await loadMemoriesSubview(.allMemories) }
    }

    private var learningCoverageLine: String? {
        let gaps = model.learningCoverage.filter { $0.state != "ok" }
        guard !gaps.isEmpty else { return nil }
        return "Not instrumented: " + gaps.map { "\($0.store) (\($0.state))" }.joined(separator: ", ")
    }

    @ViewBuilder
    private func learningList(filter: LearningFilter) -> some View {
        let toReview = filter == .toReview
        let events = toReview ? model.toReviewEvents : model.learningEvents
        let loading = toReview ? model.toReviewLoading : model.learningLoading
        let error = toReview ? model.toReviewError : model.learningError
        let headline = toReview ? model.toReviewHeadline : model.learningHeadline
        VStack(spacing: 0) {
            sectionHeader(
                section: .memories,
                title: toReview ? "To review" : "Recent learning",
                detail: !headline.isEmpty
                    ? headline
                    : (toReview
                        ? "Promotable patterns and task proposals waiting on you."
                        : "What COS captured, proposed, checked and used, newest first."),
                refresh: { Task { if toReview { await model.loadToReviewEvents() } else { await model.loadLearningEvents() } } }
            )
            if loading, events.isEmpty {
                centeredProgress(toReview ? "Loading review queue…" : "Loading recent learning…")
            } else if events.isEmpty {
                VStack(spacing: 8) {
                    emptyState(.memories, text: error ?? (toReview ? "Nothing to review." : "Nothing learned yet."))
                    if let line = learningCoverageLine {
                        Text(line).font(.system(size: 10.5)).foregroundStyle(.tertiary).padding(.bottom, 16)
                    }
                }
            } else {
                if let error, !error.hasPrefix("Nothing") {
                    // A failed refresh must not hide behind rows that are already
                    // on screen (QA 2026-09-06).
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(COSPalette.amber)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 6)
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(events) { event in
                            Button {
                                selectedLearningID = event.id
                                model.openLearningEvent(event)
                            } label: {
                                learningRow(event)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 46)
                        }
                        if !toReview, model.learningNextCursor != nil {
                            Button {
                                Task { await model.loadMoreLearningEvents() }
                            } label: {
                                if model.learningLoadingMore { ProgressView().controlSize(.small) } else { Text("Load more") }
                            }
                            .controlSize(.small)
                            .padding(.top, 12)
                        }
                        if let line = learningCoverageLine {
                            Text(line)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 12)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 22)
                }
            }
        }
    }

    private func learningRow(_ event: LearningEvent) -> some View {
        HStack(spacing: 13) {
            Image(systemName: event.kindGlyph)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ActivitySection.memories.tint)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(event.rowSubtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(event.id)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Text(event.kindLabel)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(ActivitySection.memories.tint.opacity(0.16)))
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    // MARK: Knowledge

    private var knowledgeHeadline: String {
        if model.isGraphQueryActive {
            if model.graphSearching { return "Looking up…" }
            if let total = model.graphSearchTotal { return "\(total) matching entities" }
            return "Entities in the knowledge graph"
        }
        if let error = model.graphStatusError { return error }
        guard let g = model.graphStatus else { return "The knowledge graph, as this Mac sees it." }
        var parts: [String] = []
        if let e = g.entities { parts.append("\(e) entities") }
        if let r = g.relationships { parts.append("\(r) relationships") }
        parts.append("index \(g.indexState)")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func knowledgePane() -> some View {
        VStack(spacing: 0) {
            sectionHeader(
                section: .memories,
                title: "Knowledge",
                detail: knowledgeHeadline,
                refresh: { Task { await model.loadGraphStatus() } }
            )
            graphSearchBar
            if model.isGraphQueryActive {
                graphResults
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        syncCard
                        Text("Search above to open an entity: its descriptions, relationships by weight, neighbors, and the memories that mention it. Merging, renaming and removing arrive in a later release.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                }
            }
        }
    }

    private var graphSearchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search people, projects, companies…", text: $model.graphQuery)
                    .textFieldStyle(.plain)
                if !model.graphQuery.isEmpty {
                    Button {
                        model.graphQuery = ""
                        model.scheduleGraphSearch()
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
            .frame(maxWidth: 360)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
        .onChange(of: model.graphQuery) { _, _ in model.scheduleGraphSearch() }
    }

    @ViewBuilder
    private var graphResults: some View {
        if model.graphSearching, model.graphSearchHits.isEmpty {
            centeredProgress("Looking up…")
        } else if let error = model.graphSearchError, model.graphSearchHits.isEmpty {
            emptyState(.memories, text: error)
        } else if model.graphSearchHits.isEmpty {
            emptyState(.memories, text: model.graphSearchIndexState == "missing" || model.graphSearchIndexState == "source_missing"
                ? "No knowledge index on this Mac yet. Build it from the Sync card."
                : "No entities match that lookup.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.graphSearchHits) { hit in
                        Button {
                            selectedGraphEntityID = hit.id
                            model.openGraphEntity(hit)
                        } label: {
                            graphRow(hit)
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

    private func graphRow(_ entity: GraphEntity) -> some View {
        HStack(spacing: 13) {
            sectionGlyph(.memories)
            VStack(alignment: .leading, spacing: 4) {
                Text(entity.id)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                if !entity.description.isEmpty {
                    Text(entity.description)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if let degree = entity.degree {
                Text("\(degree)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if !entity.type.isEmpty {
                Text(entity.type)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(ActivitySection.memories.tint.opacity(0.16)))
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    /// `Ukaoma-Mac-Studio.local` reads as `Ukaoma Mac Studio`.
    private func hostLabel(_ host: String) -> String {
        var name = host
        if name.hasSuffix(".local") { name.removeLast(6) }
        return name.replacingOccurrences(of: "-", with: " ")
    }

    private func topologyLine(_ g: GraphStatus) -> String {
        var line: String
        switch g.ownerState {
        case "owner": line = "This Mac is the ingestion owner" + (g.ownerHost.map { " (\(hostLabel($0)))" } ?? "")
        case "replica": line = "Replica of " + (g.ownerHost.map(hostLabel) ?? "the owner") + "; reads the iCloud copy of the graph"
        default: line = "No ingestion owner set. Run --set-owner on the Mac that processes the queue."
        }
        if g.indexHostMismatch, let built = g.indexBuiltOnHost { line += ". Index built on \(hostLabel(built))" }
        return line
    }

    private func indexedLine(_ g: GraphStatus) -> String {
        var parts: [String] = []
        if let e = g.entities { parts.append("\(e) entities") }
        if let r = g.relationships { parts.append("\(r) relationships") }
        if let updated = g.sourceUpdatedAt { parts.append("graph written \(LearningEvent.shortStamp(updated))") }
        return parts.isEmpty ? "No graph on this Mac" : parts.joined(separator: " · ")
    }

    private func indexLine(_ g: GraphStatus) -> String {
        var line = g.indexState
        if let built = g.indexBuiltAt { line += " · built \(LearningEvent.shortStamp(built))" }
        if g.indexDegraded { line += " · degraded (a store was unreadable)" }
        return line
    }

    private func queueLine(_ g: GraphStatus) -> String {
        guard let pending = g.queuePending else { return "unknown" }
        var line = "\(pending) pending"
        if let failed = g.queueFailed, failed > 0 { line += " · \(failed) failed" }
        if let deferred = g.queueDeferred, deferred > 0 { line += " · \(deferred) deferred" }
        if let total = g.queueLiveTotal { line += " · \(total) live rows" }
        return line
    }

    private func oldestPendingLine(_ g: GraphStatus) -> String? {
        guard let oldest = g.oldestPendingAt else { return nil }
        var line = LearningEvent.shortStamp(oldest)
        if let age = g.oldestPendingAgeSeconds {
            let days = age / 86_400
            line += days > 0 ? " (\(days) day\(days == 1 ? "" : "s") ago)" : " (today)"
        }
        return line
    }

    private func budgetLine(_ g: GraphStatus) -> String {
        switch (g.budgetUsed, g.budgetCap) {
        case let (used?, cap?): return "\(used) of \(cap) calls today"
        case let (used?, nil): return "\(used) calls today"
        default: return "unknown"
        }
    }

    private func lockLine(_ g: GraphStatus) -> String {
        switch g.lock.state {
        case "free": return "free"
        case "exclusive": return "held by an ingest" + (g.lock.ownerPID.map { " (pid \($0), advisory)" } ?? "")
        case "shared": return "held by a backup"
        default: return g.lock.error.map { "unknown (\($0))" } ?? "unknown"
        }
    }

    private func processorLine(_ g: GraphStatus) -> String {
        if g.isOwner == false, let owner = g.ownerHost {
            return "Processing happens on \(hostLabel(owner))"
        }
        return g.processorLine
    }

    private func syncRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .trailing)
            Text(value)
                .font(.system(size: 11.5))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// The Sync card: read-only topology, queue, index, budget, lock and
    /// processor, plus the one kickoff a missing or stale index invites.
    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sync")
                    .font(.caption2.weight(.bold))
                    .tracking(1.3)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.graphStatusLoading { ProgressView().controlSize(.mini) }
            }
            if let error = model.graphStatusError {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(COSPalette.amber)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let g = model.graphStatus {
                syncRow("Topology", topologyLine(g))
                syncRow("Queued", queueLine(g))
                if let oldest = oldestPendingLine(g) { syncRow("Oldest pending", oldest) }
                if let missing = g.missingSources, missing > 0 { syncRow("Missing sources", "\(missing) queued meetings whose file is gone") }
                if let copies = g.conflictCopies, copies > 0 { syncRow("Conflict copies", "\(copies) iCloud copies beside the queue") }
                syncRow("Indexed", indexedLine(g))
                syncRow("Index", indexLine(g))
                syncRow("Budget", budgetLine(g))
                syncRow("Lock", lockLine(g))
                syncRow("Processor", processorLine(g))
                if let state = model.graphBuildState {
                    HStack(spacing: 6) {
                        if state == "starting" || state == "running" || state == "already_running" {
                            ProgressView().controlSize(.mini)
                        }
                        Text(model.graphBuildNote ?? state)
                            .font(.system(size: 10.5))
                            .foregroundStyle(state == "failed" ? COSPalette.amber : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // The index is per-Mac derived data, so a replica builds its own; no
                // owner clause here. `unknown` (the poll gave up) keeps the button.
                if g.invitesIndexBuild,
                   model.graphBuildState == nil || model.graphBuildState == "done" || model.graphBuildState == "failed" || model.graphBuildState == "unknown" {
                    Button("Build index (usually a few seconds)", systemImage: "hammer") { model.buildGraphIndex() }
                        .controlSize(.small)
                }
            } else {
                Text("Loading…").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(COSPalette.line, lineWidth: 1))
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
                refresh: { Task { await model.loadContextRecords(kind: kind) } },
                stats: available
                    ? [(formatted(isThread ? model.status.threadCount : model.status.memoryCount), isThread ? "TRACKED" : "STORED"),
                       (formatted(records.count), "SHOWN")]
                    : []
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
                    LazyVStack(spacing: 6) {
                        ForEach(records) { record in
                            Button {
                                selectedContextID = record.id
                                model.openContextRecord(record, kind: kind)
                            } label: {
                                contextRow(record, item: item)
                            }
                            .buttonStyle(.plain)
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
                .cosField()
                .frame(maxWidth: 320)
                COSDropdown("Recency", selection: $model.searchRecency,
                            options: SearchRecency.allCases.map { COSDropdownOption($0, $0.title) })
                .fixedSize()
                Spacer()
            }
            if queryActive, !semanticAvailable {
                Text(isThread
                     ? "Keyword only — threads have no meaning index"
                     : "Keyword only — meaning search needs the COS memory index")
                    .font(COSType.body(11))
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
                    .font(COSType.body(13.5, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !record.subtitle.isEmpty {
                    Text(record.subtitle)
                        .font(COSType.body(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(record.id)
                    .font(COSType.mono(9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .cosRowCard()
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
        secondaryDisabled: Bool = false,
        stats: [(value: String, label: String)] = []
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
            stats: stats,
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
        stats: [(value: String, label: String)] = [],
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        // The pane hero (0.5.193): the title in Fraunces like the Memories
        // page, one line of detail under it, and a strip of live numbers, the
        // same value/label pair the home tiles show. Buttons share the quiet
        // style; a prominent Refresh is the pane's single gold control.
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                sectionGlyph(item, large: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(COSType.display(24, weight: .medium)).lineLimit(1)
                    Text(detail).font(COSType.body(12)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                accessory()
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                        .buttonStyle(COSQuietButtonStyle())
                        .disabled(secondaryDisabled)
                }
                if refreshProminent {
                    Button(refreshTitle, systemImage: "arrow.clockwise", action: refresh)
                        .buttonStyle(COSPrimaryButtonStyle())
                        .disabled(refreshDisabled)
                } else {
                    Button(refreshTitle, systemImage: "arrow.clockwise", action: refresh)
                        .buttonStyle(COSQuietButtonStyle())
                        .disabled(refreshDisabled)
                }
            }
            if !stats.isEmpty {
                HStack(alignment: .top, spacing: 26) {
                    ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                        COSStat(value: stat.value, label: stat.label)
                    }
                    Spacer()
                }
                .padding(.top, 14)
                .padding(.leading, 56)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(item.tint.opacity(0.045))
        .overlay(alignment: .bottom) { Rectangle().fill(COSPalette.line).frame(height: 1) }
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
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: stale ? "clock.badge.exclamationmark" : "info.circle")
                .foregroundStyle(stale ? COSPalette.amber : COSPalette.accent)
            Text(text)
                .font(COSType.body(11))
                .foregroundStyle(COSPalette.muted)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 9)
        .background((stale ? COSPalette.amber : COSPalette.accent).opacity(0.07))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func statusPill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(COSType.mono(8, weight: .bold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.16), in: Capsule())
    }

    private func metric(_ value: String, sub: String?, width: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value).font(COSType.mono(11.5, weight: .semibold)).lineLimit(1)
            if let sub { Text(sub).font(COSType.body(9)).foregroundStyle(COSPalette.muted).lineLimit(1) }
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

    /// The row's second line: where the samples came from. The count has its own column.
    private func voiceSourceLine(_ person: VoiceDirectoryPerson) -> String {
        let summary = sourceSummary(person.sources)
        return summary.isEmpty ? "No recorded source" : summary
    }

    /// CONFIDENCE: the share of this voice's SCORED segments (the ones with a similarity, the
    /// same basis as `observedMatch`) that came from appearances the server rated confident,
    /// meaning at or above CONFIDENT_SIMILARITY with no speaker thrash
    /// (meeting-speaker-review.ts). The server sets that tier per voice per meeting and
    /// counts it in segments. It also rates unscored segments weak, so dividing by every tier
    /// read a voice with one scored segment as "0% confident" (QA 2026-09-13, live data).
    /// The denominator is the scored basis. Nil when nothing was scored.
    private func confidenceShare(_ person: VoiceDirectoryPerson) -> Double? {
        guard person.observedMatchSegments > 0 else { return nil }
        let confident = person.reliabilityCounts["confident"] ?? 0
        return min(1, Double(confident) / Double(person.observedMatchSegments))
    }

    private func confidenceValue(_ person: VoiceDirectoryPerson) -> String {
        confidenceShare(person).map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }

    /// Under the share: the average match as the server reports it (a similarity, not a
    /// second percentage), marked thin when the basis is too small to lean on.
    private func confidenceDetail(_ person: VoiceDirectoryPerson) -> String {
        guard let match = person.observedMatch, person.observedMatchSegments > 0 else { return "not matched yet" }
        let average = "avg " + String(format: "%.2f", match)
        return person.observedMatchSegments < Self.confidenceMinimumBasis ? average + " · thin" : average
    }

    /// Lowest confidence order: 0 = enough scored speech, 1 = a thin basis, 2 = never matched.
    private func confidenceRank(_ person: VoiceDirectoryPerson) -> (tier: Int, share: Double?) {
        guard let share = confidenceShare(person) else { return (2, nil) }
        return (person.observedMatchSegments < Self.confidenceMinimumBasis ? 1 : 0, share)
    }

    private func voiceAccessibilityLabel(_ person: VoiceDirectoryPerson) -> String {
        guard model.voiceDirectoryRouteAvailable != false else {
            return "\(person.name), \(person.embeddings) training samples, cross-meeting history requires a server update"
        }
        let confidence: String
        if let share = confidenceShare(person), let match = person.observedMatch {
            confidence = "confidence \(Int((share * 100).rounded())) percent of \(person.observedMatchSegments) scored segments, average match \(String(format: "%.2f", match))"
        } else {
            confidence = "not matched in a meeting yet"
        }
        return "\(person.name), \(person.embeddings) training samples, \(confidence), \(person.assertedSegments) attributed segments in \(person.meetingCount) meetings"
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
                    voiceMetricCard(title: "CONFIDENCE", value: historyAvailable ? confidenceValue(person) : "—", detail: historyAvailable ? (person.observedMatch.map { "avg match \(String(format: "%.2f", $0)) · \(formatted(person.observedMatchSegments)) scored" } ?? "Not matched yet") : "Update server")
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
                    .toggleStyle(COSSwitchStyle())
                    .font(COSType.body(10.5))
                    .fixedSize()
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
                .textFieldStyle(.plain)
                .cosField()
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
                    .buttonStyle(COSTextButtonStyle())
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
        guard Self.allowsLiveSectionLoads(isolatedWorkPreview: isolatedWorkPreview, backgroundWorkEnabled: model.activityLoadsEnabled) else { return }
        // Activity can be the first COS Control surface opened after launch.
        // Prove the server here instead of inheriting the model's initial
        // `running = false` placeholder from the unopened menu-bar panel.
        await model.refresh(quiet: true)
        // 0.5.259: a server that reports no review count leaves memories out of the quiet line rather than waited for.
        homeLoads[.memories] = model.status.learningToReview == nil ? .off : .answered
        async let sessions: Void = model.loadClaudeSessions()
        // 0.5.259 (QA U-W4): Work loads beside the sessions, not last, so the home's line is complete sooner.
        async let work: Void = loadHomeWork()
        if model.recentMessages.isEmpty { await model.refreshRecentMessages(quiet: true) }
        if model.reviewableMeetings.isEmpty { await model.loadReviewableMeetings() }
        homeLoads[.voices] = model.reviewableMeetings.isEmpty && model.reviewError != nil ? .failed : .answered
        if model.voiceDirectory.isEmpty { await model.loadVoiceDirectory() }
        if model.extAudioSessions.isEmpty { await model.loadExtAudio() }
        if model.status.memoryAvailable == true, model.memoryRecords.isEmpty {
            await model.loadContextRecords(kind: "memory")
        }
        if model.status.threadsAvailable == true, model.threadRecords.isEmpty {
            await model.loadContextRecords(kind: "thread")
        }
        await sessions
        homeLoads[.sessions] = model.claudeSessions.isEmpty && model.claudeSessionsError != nil ? .failed : .answered
        if model.tasks.isEmpty { await model.loadTasks(force: true) }
        await model.loadDomains()
        reconcileTaskDomain()
        await work
        // 0.5.259: the Memories card dates its oldest wait from the review list, the loader Memories already uses.
        if (model.status.learningToReview ?? 0) > 0, model.toReviewEvents.isEmpty { await model.loadToReviewEvents() }
    }

    /// 0.5.259: the home's Work card and Needs you line read Work's board, its meeting reviews and Intake: the loaders
    /// Work already uses.
    private func loadHomeWork() async {
        guard workConnectionsEnabled else { homeLoads[.work] = .off; return }
        if model.workTasks.isEmpty {
            await model.loadWorkTasks()
            await reviewStore.refresh()
            await model.loadWorkIntake()
        }
        homeLoads[.work] = model.workTasksError == nil ? .answered : .failed
    }

    private func load(_ item: ActivitySection) async {
        guard Self.allowsLiveSectionLoads(isolatedWorkPreview: isolatedWorkPreview, backgroundWorkEnabled: model.activityLoadsEnabled) else { return }
        switch item {
        case .messages: await model.refreshRecentMessages()
        case .speakers:
            await loadSpeakerSubview(speakerSubview, refresh: false)
        case .meetings:
            await model.loadLibraryMeetings()
            if model.reviewableMeetings.isEmpty {
                await model.loadReviewableMeetings()
            }
        case .memories:
            await loadMemoriesSubview()
        case .threads:
            if model.status.threadsAvailable == true { await model.loadContextRecords(kind: "thread") }
        case .sessions:
            await model.loadClaudeSessions()
        case .tasks:
            await model.loadDomains()
            reconcileTaskDomain()
            await model.loadTasks(force: true)
        case .work:
            await model.loadDomains()
            reconcileTaskDomain()
            await model.loadWorkTasks()
            await reviewStore.refresh()
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
        guard Self.allowsLiveSectionLoads(isolatedWorkPreview: isolatedWorkPreview, backgroundWorkEnabled: model.activityLoadsEnabled) else { return }
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
            Text(label).font(COSType.body(11.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(_ item: ActivitySection, text: String) -> some View {
        VStack(spacing: 12) {
            sectionGlyph(item, large: true)
            Text(text)
                .font(COSType.body(12))
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
    /// 0.5.241: the Work handoff that started or sent to this session, if any.
    var workReceipt: WorkHandoffReceipt? = nil
    var onOpenWork: ((String) -> Void)? = nil

    /// A server-run session has no title of its own ("Claude session"); the Work item names it.
    nonisolated static func headerTitle(detail: String?, row: String?, workTitle: String?) -> String {
        let generic: Set<String> = ["", "Claude session", "Session"]
        if let detail, !generic.contains(detail) { return detail }
        if let workTitle, !workTitle.isEmpty { return workTitle }
        if let row, !row.isEmpty { return row }
        return detail ?? "Session"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let row = model.openClaudeRow {
                        Text(row.providerLabel.uppercased())
                            .font(COSType.mono(9, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(Self.tint(row.provider))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Self.tint(row.provider).opacity(0.14)))
                    }
                    Text(Self.headerTitle(detail: model.claudeSessionDetail?.title, row: model.openClaudeRow?.title,
                                          workTitle: workReceipt?.sessionTitle))
                        .font(COSType.display(22, weight: .medium))
                        .textSelection(.enabled)
                }
                Text(model.openClaudeRow?.isScheduledJob == true
                     ? "Scheduled job · started by COS"
                     : (model.claudeSessionDetail?.subtitle ?? "Read-only · local transcript"))
                    .font(COSType.body(12))
                    .foregroundStyle(.secondary)
                if let cwd = model.claudeSessionDetail?.cwd, !cwd.isEmpty {
                    Text(cwd)
                        .font(COSType.mono(10.5))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                if let receipt = workReceipt {
                    HStack(spacing: 10) {
                        Text("From Work · \(receipt.workTitle) · \(receipt.status.capitalized)")
                            .font(COSType.body(12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let onOpenWork {
                            Button("Open in Work") { onOpenWork(receipt.workID) }
                                .buttonStyle(COSQuietButtonStyle())
                                .controlSize(.small)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 12)
            Divider()

            if let row = model.openClaudeRow, row.isScheduledJob {
                // 0.5.229: a scheduled job keeps no conversation; show what COS knows about the run.
                ScheduledJobFacts(row: row)
                Spacer()
            } else if model.claudeSessionDetailLoading && model.claudeSessionDetail == nil {
                ProgressView("Loading session…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.claudeSessionDetailError, model.claudeSessionDetail == nil {
                Text(error)
                    .font(COSType.body(12))
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
                        // 0.5.233: what the session is doing RIGHT NOW, from the server's
                        // stream; the turns below are the stored conversation.
                        SessionActivityFeed(feed: model.sessionFeed, queued: model.openClaudeRow?.queuedTurns ?? 0)
                        if detail.truncated {
                            Text("Showing the last \(detail.turns.count) of \(detail.totalTurns) turns. Copy session keeps the original request plus the newest context.")
                                .font(COSType.body(11.5))
                                .foregroundStyle(.secondary)
                        }
                        if detail.turns.isEmpty {
                            Text("This session has no user or assistant prose stored.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(detail.turns) { turn in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(turn.isUser ? "YOU" : "ASSISTANT")
                                    .font(COSType.mono(9.5, weight: .semibold))
                                    .tracking(1.2)
                                // 0.5.232: a reply is Markdown (headings, lists, tables,
                                // code); what you typed is shown as you typed it.
                                if turn.isUser {
                                    Text(turn.text)
                                        .font(COSType.body(12.5))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    COSMarkdownView(text: turn.text)
                                }
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
            if let row = model.openClaudeRow, !row.isScheduledJob {
                Divider()
                HStack(spacing: 10) {
                    // 0.5.250: not while the COS server is still running a Work New session's first turn (two writers).
                    Button("Open in platform") { model.openSessionInPlatform(row) }
                        .disabled(row.heldByServer)
                        .help(row.heldByServer ? "Still running on the COS server. It opens in the app when the first reply is done." : "")
                    if let detail = model.claudeSessionDetail {
                        Button("Copy session") { model.copyClaudeSession() }
                            .disabled(detail.copyText.isEmpty)
                        Spacer()
                        Text("Kickstart brief for another agent. Not a Claude Code resume.")
                            .font(COSType.body(11))
                            .foregroundStyle(.tertiary)
                    } else {
                        Spacer()
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
            }
            // At the pane ROOT, outside the `if let detail` branch, so the
            // composer renders on the local-transcript-error path too — a
            // Desktop-store session has no local JSONL, and it is exactly the
            // session the server-side Continue can still reach. 0.5.229: a
            // scheduled job has nothing to continue.
            if model.openClaudeRow?.workRunning == true {
                // 0.5.250: the COS server is still writing this Work New session; a Continue now would be a second writer.
                Text("Still running its first turn on the COS server. You can continue it once that finishes.")
                    .font(COSType.body(11.5)).foregroundStyle(.secondary)
                    .padding(.horizontal, 24).padding(.vertical, 12)
            } else if model.openClaudeRow?.isScheduledJob != true {
                SessionChatComposer(model: model)
            }
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

/// 0.5.229. What Control knows about a scheduled job's run, shown in place of a transcript it never kept.
struct ScheduledJobFacts: View {
    let row: ClaudeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            fact("Job", row.title)
            if !row.jobScript.isEmpty { fact("Script", row.jobScript) }
            if let started = row.createdDate {
                fact("Started", started.formatted(date: .omitted, time: .standard))
            }
            if row.alive {
                fact("Status", "Running")
            } else if let finished = row.updatedDate {
                fact("Finished", finished.formatted(date: .omitted, time: .standard))
                if let started = row.createdDate {
                    fact("Duration", ScheduledJobRun.durationLabel(finished.timeIntervalSince(started)))
                }
            }
            Text("COS started this Claude run in the background. It keeps no conversation to open or continue.")
                .font(COSType.body(11.5))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label.uppercased())
                .font(COSType.mono(9.5, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(COSType.body(12.5))
                .textSelection(.enabled)
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
            // 0.5.238: a thread mid-turn reads as waiting, not refused. Send parks the
            // message and it lands when the turn ends, as it does from the pet and the lens.
            if model.chatRefusal == nil, let hint = model.chatParkHint {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Text(verbatim: hint)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Fork stays available beside the park (QA, 0.5.238).
                    if model.chatForkAvailable {
                        Button("Fork with this message") { model.forkChatThread() }
                            .controlSize(.small)
                            .disabled(model.chatForkPrompt.isEmpty || model.chatForking)
                            .help("Runs your message in a copy of this thread. The original is untouched.")
                    }
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
                    .textFieldStyle(.plain)
                    .cosField()
                    .lineLimit(1...6)
                    .disabled(model.chatSending || model.chatPolling || model.chatForking)
                    .onSubmit { model.sendChatMessage() }
                Button(model.chatEditingTurn == nil ? "Send" : "Replace") { model.sendChatMessage() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.chatSending || model.chatPolling || model.chatForking
                        || model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if model.chatVerdict?.caution == true {
                // 0.5.233: the documented fork mode, named on the composer. The turn lands in
                // the session's transcript through a resume child; the open Desktop tab paints
                // it only when that session is resumed. Queue-and-deliver (server 6.48.1) makes
                // it land the moment the engine closes the turn.
                // 0.5.238: a Codex thread the Codex app holds is the exception (server 6.51.0):
                // the message goes into the app's own queue and shows there.
                Text(model.openClaudeRow?.provider == "codex"
                    ? "The Codex app has this thread open. COS will ask before the first send, then hands your message to the app's own queue, where it shows."
                    : "Another app on this Mac has this session open. COS will ask before the first send. The reply lands in the transcript; the open desk tab will not show it until you resume.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 0.5.235: the queue itself, not only its count. Each parked turn with
            // its place, its text (full when this Mac queued it, the server's
            // 80-character head otherwise) and Cancel while it is still waiting.
            // A delivering row cannot be recalled; a refused or expired row says so
            // for the half hour the server keeps it, so an outcome is never lost.
            let queue = model.chatQueuedTurns
            let waiting = queue.filter(\.isWaiting).count
            if !queue.isEmpty || (model.openClaudeRow?.queuedTurns ?? 0) > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text(waiting == 1 ? "1 follow-up queued; it lands when this turn ends."
                         : waiting > 1 ? "\(waiting) follow-ups queued; they land in order when this turn ends."
                         : "Queue")
                        .font(.system(size: 10.5))
                        .foregroundStyle(COSPalette.accent)
                    ForEach(queue) { turn in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(turn.stateLine)
                                .font(COSType.mono(9.5, weight: .bold))
                                .foregroundStyle(turn.isDelivering ? COSPalette.green
                                                 : turn.isWaiting ? COSPalette.accent : COSPalette.amber)
                                .frame(width: 118, alignment: .leading)
                            Text(verbatim: model.queuedTurnText(turn))
                                .font(.system(size: 11.5))
                                .foregroundStyle(turn.isWaiting || turn.isDelivering ? Color.primary : Color.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            if turn.cancellable {
                                if model.chatEditingTurn?.clientTurnId == turn.clientTurnId {
                                    Button("Keep it as it was") { model.cancelEditingChatTurn() }
                                        .controlSize(.small)
                                } else {
                                    Button("Edit") { model.beginEditingChatTurn(turn) }
                                        .controlSize(.small)
                                        .help("Put this message in the composer. Send replaces it in the queue.")
                                }
                                Button("Cancel") { model.cancelChatQueuedTurn(turn) }
                                    .controlSize(.small)
                                    .help("Cancel this queued message. It will not be sent.")
                            }
                        }
                        .padding(8)
                        .background(model.chatEditingTurn?.clientTurnId == turn.clientTurnId
                                    ? COSPalette.amber.opacity(0.10) : COSPalette.card,
                                    in: RoundedRectangle(cornerRadius: 9))
                    }
                    if let note = model.chatQueueNote {
                        Text(verbatim: note)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

/// The live block at the top of a session pane (0.5.233): the state line with its
/// clock, the current prompt, the last eight tool lines. Elapsed ticks locally once a
/// second; the feed itself moves only on the server's events. When the stream is not
/// available the block says so in one line and the polled turns below stand.
struct SessionActivityFeed: View {
    let feed: SessionLiveFeed?
    var queued: Int = 0
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var tint: Color {
        switch feed?.agentState ?? feed?.state {
        case "running", "working": COSPalette.green
        case "waiting": COSPalette.amber
        case "failed": COSPalette.danger
        default: COSPalette.muted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ACTIVITY")
                .font(COSType.mono(9.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            if let feed, feed.connected || feed.lastSeq > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(tint).frame(width: 8, height: 8)
                        .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
                    Text(feed.stateWord)
                        .font(COSType.body(13, weight: .semibold))
                    if !feed.stateDetail.isEmpty {
                        Text(feed.stateDetail)
                            .font(COSType.body(12.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Text(feed.elapsed(now: now))
                        .font(COSType.mono(11))
                        .foregroundStyle(COSPalette.muted)
                        .monospacedDigit()
                }
                if !feed.prompt.isEmpty {
                    Text(feed.prompt)
                        .font(COSType.body(12.5))
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !feed.tools.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(feed.tools) { tool in
                            Text(tool.line)
                                .font(COSType.mono(10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                HStack(spacing: 10) {
                    if feed.missed > 0 {
                        Text("missed \(feed.missed)").font(COSType.mono(9.5)).foregroundStyle(COSPalette.amber)
                    }
                    if queued > 0 {
                        Text(queued == 1 ? "1 queued" : "\(queued) queued").font(COSType.mono(9.5)).foregroundStyle(COSPalette.accent)
                    }
                    if let reason = feed.fallbackReason, reason == "reconnecting" {
                        Text("reconnecting…").font(COSType.mono(9.5)).foregroundStyle(COSPalette.muted)
                    }
                }
            } else if let reason = feed?.fallbackReason {
                Text(fallbackLine(reason))
                    .font(COSType.body(11.5))
                    .foregroundStyle(.secondary)
            } else {
                Text("Connecting to the live feed…")
                    .font(COSType.body(11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(COSPalette.line, lineWidth: 1))
        .onReceive(tick) { now = $0 }
    }

    private func fallbackLine(_ reason: String) -> String {
        switch reason {
        case "http_404": "No live feed for this session (no transcript to follow); showing the stored turns."
        case "http_503": "The server has no room for another live feed right now; showing the stored turns."
        case "reconnecting": "Reconnecting to the live feed…"
        case "stream_lost": "The live feed stopped answering; showing the stored turns. Reopen the session to try again."
        default: "Live feed unavailable (\(reason)); showing the stored turns."
        }
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
            .font(COSType.mono(8.5, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}


// ── Memories web host ─────────────────────────────────────────────

/// Marks a Needs you item that may give up part of its width (a session item, whose title truncates).
private struct NeedsFlowShrinks: LayoutValueKey {
    static let defaultValue = false
}

/// 0.5.259: the Needs you line's rows, placed by ActivityHome.flow. A session item that nearly fits the rest of a row
/// truncates its title rather than start a new row; the backlog segment never shrinks.
private struct NeedsFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    private func places(_ subviews: Subviews, width: CGFloat) -> [ActivityHome.FlowPlace] {
        ActivityHome.flow(ideal: subviews.map { $0.sizeThatFits(.unspecified).width },
                          shrinks: subviews.map { $0[NeedsFlowShrinks.self] }, width: width, spacing: spacing)
    }

    private func rows(_ subviews: Subviews, _ places: [ActivityHome.FlowPlace]) -> [CGFloat] {
        var heights: [CGFloat] = []
        for (subview, place) in zip(subviews, places) {
            let height = subview.sizeThatFits(ProposedViewSize(width: place.width, height: nil)).height
            if place.row < heights.count { heights[place.row] = max(heights[place.row], height) } else { heights.append(height) }
        }
        return heights
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
        let heights = rows(subviews, places(subviews, width: width))
        return CGSize(width: width, height: heights.reduce(0, +) + lineSpacing * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = places(subviews, width: bounds.width)
        let heights = rows(subviews, placed)
        for (subview, place) in zip(subviews, placed) {
            let y = bounds.minY + heights.prefix(place.row).reduce(0, +) + lineSpacing * CGFloat(place.row)
            subview.place(at: CGPoint(x: bounds.minX + place.x, y: y), proposal: ProposedViewSize(width: place.width, height: nil))
        }
    }
}

/// A session's provider mark (Resources/mark-claude.svg, mark-codex.svg, mark-cursor.svg), drawn the way Sessions draws
/// it: a template image tinted by its caller.
struct ActivityProviderMark: View {
    let session: ClaudeSession
    var size: CGFloat = 12

    var body: some View {
        switch session.petProviderMark {
        case .asset(let name):
            Image(nsImage: COSBrand.svg(name))
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size - 1, weight: .semibold))
        }
    }
}

/// 0.5.259 board 3: one session's desk on the Sessions card. Its provider mark, colored by state: working (gold, with a
/// slow glow that is still under Reduce Motion), asked you something (amber, with a dot), quiet and may need you (dashed
/// amber), finished today (green, with a tick). Help text: "<title> · <state> · <age>". A click opens the session the way
/// Sessions does. It plays no sound.
private struct ActivityDeskMark: View {
    let desk: ActivityHome.Desk
    let now: Date
    let reduceMotion: Bool
    let open: () -> Void
    @State private var glow = false

    private var tint: Color {
        switch desk.state {
        case .working: COSPalette.gold
        case .asked, .maybe: COSPalette.amber
        case .finished: COSPalette.green
        }
    }

    var body: some View {
        Button(action: open) {
            ActivityProviderMark(session: desk.session, size: 12)
                .foregroundStyle(tint)
                .frame(width: ActivityHome.deskWidth, height: ActivityHome.deskHeight)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(desk.state == .asked ? COSPalette.amber.opacity(0.14) : COSPalette.raised))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(tint.opacity(desk.state == .finished ? 0.7 : 1),
                                      style: StrokeStyle(lineWidth: desk.state == .maybe ? 1.4 : 1, dash: desk.state == .maybe ? [3, 2] : []))
                }
                .background {
                    // The glow: a soft gold ring that breathes while the session works.
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(COSPalette.gold.opacity(glow ? 0.30 : 0), lineWidth: 4)
                        .padding(-2)
                }
                .overlay(alignment: .topTrailing) {
                    if desk.state == .asked {
                        Circle().fill(COSPalette.amber)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(COSPalette.card, lineWidth: 1.5))
                            .offset(x: 3, y: -3)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if desk.state == .finished {
                        Image(systemName: "checkmark")
                            .font(.system(size: 6.5, weight: .heavy))
                            .foregroundStyle(COSPalette.green)
                            .frame(width: 11, height: 11)
                            .background(Circle().fill(COSPalette.card))
                            .offset(x: 4, y: 4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(desk.help(now: now))
        .accessibilityLabel(desk.help(now: now))
        .onAppear { breathe() }
        .onChange(of: reduceMotion) { _, _ in breathe() }
        .onChange(of: desk.state) { _, _ in breathe() }
    }

    /// The glow runs only where ActivityHome says it may: a working desk, and never under Reduce Motion.
    private func breathe() {
        guard desk.state.glows(reduceMotion: reduceMotion) else {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { glow = false }
            return
        }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { glow = true }
    }
}

/// Hosts Resources/memories/memories.html. The page never holds the API token:
/// it posts `{id, op, args}` and this coordinator runs the helper (or a native
/// action) and resolves the page's promise with `{ok, message, details}`.
struct MemoriesWebView: NSViewRepresentable {
    @ObservedObject var model: ControllerModel
    @Environment(\.colorScheme) private var colorScheme
    /// 0.5.259: the view the page opens on ("review" from the home's memories item), through the page's own
    /// cosBridge.show once it has loaded. nil opens it as before.
    var initialView: String? = nil
    var openSection: (ActivitySection) -> Void

    /// The script that opens the page on `view`. Only the page's own view names pass.
    static func openScript(_ view: String?) -> String? {
        guard let view, ["recent", "applied", "memories", "review", "knowledge"].contains(view) else { return nil }
        return "window.cosBridge && window.cosBridge.show('\(view)')"
    }

    static var bundleURL: URL? {
        Bundle.main.url(forResource: "memories", withExtension: "html", subdirectory: "memories")
    }

    /// Every op the page may post, mapped to the helper command that answers it.
    /// A name outside this table is refused, so the page cannot reach any other
    /// helper verb (and never a lifecycle or install command).
    static let helperOps: [String: ([String: Any]) -> [String]] = [
        "status": { _ in ["status"] },
        "learning.list": { a in
            var cmd = ["context-learning", "--limit", MemoriesWebView.bounded(a["limit"], 50, 1, 50), "--days", MemoriesWebView.bounded(a["days"], 90, 1, 3650)]
            // 0.5.216: the page may ask for one projector event kind (Applied this week
            // is `used`). Only the closed vocabulary is forwarded; anything else is
            // dropped, and the page fails closed when the rows come back unfiltered.
            if let kind = MemoriesWebView.learningKind(a["kind"]) { cmd += ["--kind", kind] }
            if let ts = a["sinceTs"] as? String, !ts.isEmpty { cmd += ["--since-ts", ts] }
            if let id = a["sinceEventId"] as? String, !id.isEmpty { cmd += ["--since-event-id", id] }
            return cmd
        },
        "learning.review": { a in ["context-learning", "--to-review", "--limit", MemoriesWebView.bounded(a["limit"], 200, 1, 200)] },
        "learning.event": { a in ["context-learning", "--id", MemoriesWebView.text(a["id"], 64)] },
        "learning.status": { _ in ["context-learning-status"] },
        "learning.decide": { a in ["context-learning-decide", "--id", MemoriesWebView.text(a["id"], 64), "--decision", MemoriesWebView.text(a["decision"], 16)] },
        "memories.list": { a in ["context-memories", "--limit", MemoriesWebView.bounded(a["limit"], 50, 1, 50)] },
        "memories.search": { a in ["context-memories-search", "--query", MemoriesWebView.text(a["q"], 160), "--limit", MemoriesWebView.bounded(a["limit"], 20, 1, 50)] },
        "memory.detail": { a in ["context-memories", "--id", MemoriesWebView.text(a["id"], 200)] },
        "graph.status": { _ in ["context-graph-status"] },
        "profile.owner": { _ in ["context-profile-owner"] },
        "profile.owner.set": { a in ["context-profile-owner", "--name", MemoriesWebView.text(a["name"], 120), "--expected", MemoriesWebView.text(a["expected"], 120)] },
        "graph.search": { a in ["context-graph-search", "--query", MemoriesWebView.text(a["q"], 160), "--limit", MemoriesWebView.bounded(a["limit"], 30, 1, 30)] },
        "graph.entity": { a in ["context-graph-entity", "--id", MemoriesWebView.text(a["id"], 200), "--limit", MemoriesWebView.bounded(a["limit"], 30, 1, 30), "--offset", MemoriesWebView.bounded(a["offset"], 0, 0, 100000)] },
        "graph.passages": { a in
            var command = ["context-graph-passages", "--limit", MemoriesWebView.bounded(a["limit"], 5, 1, 5)]
            if let source = a["source"] as? String, let target = a["target"] as? String {
                command += ["--relation-a", MemoriesWebView.text(source, 200), "--relation-b", MemoriesWebView.text(target, 200)]
            } else { command += ["--entity", MemoriesWebView.text(a["entity"], 200)] }
            return command
        },
        "graph.build": { _ in ["context-graph-index-build"] },
        "graph.ingest": { a in ["context-graph-ingest", "--limit", MemoriesWebView.bounded(a["limit"], 10, 1, 50)] },
        // Knowledge setup (0.5.194): six more ops, each bounded like the server.
        "graph.setup": { _ in ["context-graph-setup"] },
        "graph.setup.sources": { a in ["context-graph-setup-sources", "--action", MemoriesWebView.text(a["action"], 8), "--path", MemoriesWebView.text(a["path"], 1000)] },
        "graph.setup.owner": { _ in ["context-graph-setup-owner"] },
        "graph.sample": { a in ["context-graph-ingest-sample", "--limit", MemoriesWebView.bounded(a["limit"], 3, 1, 3)] },
        "graph.ask": { a in ["context-graph-ask", "--q", MemoriesWebView.text(a["q"], 400)] },
        "graph.progress": { _ in ["context-graph-ingest-progress"] },
        "graph.setup.embedding": { a in
            // 0.5.200: `provider` is optional when `local_only` (the down-select's one
            // question) rides alone; the helper refuses a call with neither.
            var cmd = ["context-graph-setup-embedding"]
            if let provider = a["provider"] as? String, !provider.isEmpty { cmd += ["--provider", MemoriesWebView.text(provider, 24)] }
            if let localOnly = a["local_only"] as? Bool { cmd += ["--local-only", localOnly ? "true" : "false"] }
            if let model = a["model"] as? String, !model.isEmpty { cmd += ["--model", MemoriesWebView.text(model, 120)] }
            if (a["fetch"] as? Bool) == true { cmd.append("--fetch") }
            return cmd
        },
        "graph.setup.extraction": { a in ["context-graph-setup-extraction", "--tier", MemoriesWebView.text(a["tier"], 8)] },
        // Memory review and guardrails (0.5.201): accept or prune one memory; read, set, run the rules.
        "memory.review": { a in
            var cmd = ["context-memory-review", "--id", MemoriesWebView.text(a["id"], 200), "--decision", MemoriesWebView.text(a["decision"], 8)]
            if let note = a["note"] as? String, !note.isEmpty { cmd += ["--note", MemoriesWebView.text(note, 400)] }
            return cmd
        },
        "memory.guardrails": { _ in ["context-memory-guardrails"] },
        "memory.guardrails.set": { a in ["context-memory-guardrails", "--json", MemoriesWebView.text(a["patch"], 16_000)] },
        // Curation (0.5.205, server 6.44.14): the Manage sheet's merge with a preview, its receipt, and the duplicates scan.
        "graph.merge.preview": { a in ["context-graph-merge-preview", "--source", MemoriesWebView.text(a["source"], 200), "--target", MemoriesWebView.text(a["target"], 200)] },
        "graph.merge": { a in
            var cmd = ["context-graph-merge", "--source", MemoriesWebView.text(a["source"], 200), "--target", MemoriesWebView.text(a["target"], 200)]
            if (a["confirm"] as? Bool) == true { cmd.append("--confirm") }
            if let rule = a["rule"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: rule), let json = String(data: data, encoding: .utf8) { cmd += ["--rule", MemoriesWebView.text(json, 1000)] }
            return cmd
        },
        "graph.merge.status": { _ in ["context-graph-merge-status"] },
        "graph.duplicates": { a in ["context-graph-duplicates", "--limit", MemoriesWebView.bounded(a["limit"], 25, 1, 100)] },
        "memory.guardrails.run": { a in
            var cmd = ["context-memory-guardrails-run", "--days", MemoriesWebView.bounded(a["days"], 30, 1, 3650)]
            if (a["apply"] as? Bool) == true { cmd.append("--apply") }
            if let llm = a["llm"] as? Bool { cmd += ["--llm", llm ? "true" : "false"] }
            return cmd
        },
        "graph.schedule": { a in ["context-graph-schedule", "--enabled", (a["enabled"] as? Bool) == true ? "true" : "false", "--interval-s", MemoriesWebView.bounded(a["intervalS"], 3600, 900, 86_400)] },
    ]

    /// How long the page may wait on each op: the graph question runs two
    /// model calls (the server bounds it at 150 s), the sample ingest runs the
    /// indexer's dedup as a child per document, a build is a few seconds.
    static func timeout(for op: String) -> TimeInterval {
        switch op {
        case "graph.ask": 170
        case "graph.merge.preview": 30
        case "graph.merge": 30
        case "graph.duplicates": 50
        case "graph.setup.embedding": 110
        case "memory.guardrails.run": 430
        case "graph.sample": 110
        case "graph.build": 45
        case "graph.setup": 35
        default: 30
        }
    }

    static func bounded(_ value: Any?, _ fallback: Int, _ low: Int, _ high: Int) -> String {
        let n = (value as? Int) ?? (value as? Double).map { Int($0) } ?? fallback
        return String(min(max(n, low), high))
    }

    static func text(_ value: Any?, _ limit: Int) -> String {
        String((value as? String ?? "").prefix(limit)).replacingOccurrences(of: "\n", with: " ")
    }

    /// The projector's event vocabulary (learning_events.EVENT_TYPES). A page
    /// may ask for a comma-joined subset; any other token drops the whole
    /// filter so the helper lists the full window instead of erroring.
    static let learningKinds: Set<String> = [
        "captured", "proposed", "promotable", "saved", "retrieved", "used", "checked",
        "dismissed", "reverted", "consolidated", "previewed", "accepted", "pruned",
    ]

    static func learningKind(_ value: Any?) -> String? {
        guard let raw = value as? String, !raw.isEmpty, raw.count <= 160 else { return nil }
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty, parts.allSatisfy({ learningKinds.contains($0) }) else { return nil }
        return parts.joined(separator: ",")
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model, openSection: openSection) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "cos")
        if let script = Self.openScript(initialView) {
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = view
        if let url = Self.bundleURL {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        context.coordinator.model = model
        context.coordinator.openSection = openSection
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "cos")
        coordinator.webView = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        var model: ControllerModel
        var openSection: (ActivitySection) -> Void
        weak var webView: WKWebView?

        init(model: ControllerModel, openSection: @escaping (ActivitySection) -> Void) {
            self.model = model
            self.openSection = openSection
        }

        nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            // WebKit delivers script messages on the main thread; the protocol
            // requirement is nonisolated, so state that fact and hop explicitly.
            MainActor.assumeIsolated {
                guard let body = message.body as? [String: Any], let id = body["id"] as? Int, let op = body["op"] as? String else { return }
                let args = body["args"] as? [String: Any] ?? [:]
                Task { @MainActor [weak self] in await self?.handle(id: id, op: op, args: args) }
            }
        }

        private func handle(id: Int, op: String, args: [String: Any]) async {
            switch op {
            case "copy":
                let text = MemoriesWebView.text(args["text"], 200_000)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                model.copyNote = "Copied as grounded context"
                reply(id, ok: true, message: "Copied", details: [:])
            case "workspace.request":
                do {
                    let data = try JSONSerialization.data(withJSONObject: args)
                    guard data.count <= 512 * 1024 else { throw HelperClientError.outputLimitExceeded }
                    let response = try await model.runHelper(["context-memory-workspace"], timeout: 30, stdinData: data)
                    reply(id, ok: response.ok, message: response.message, details: response.details)
                } catch {
                    reply(id, ok: false, message: error.localizedDescription, details: [:])
                }
            case "memory.reveal":
                let recordID = MemoriesWebView.text(args["id"], 200)
                do {
                    let response = try await model.runHelper(["context-memories", "--id", recordID], timeout: 30)
                    if let path = response.details["filePath"]?.string, !path.isEmpty {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        reply(id, ok: true, message: "Revealed", details: [:])
                    } else {
                        reply(id, ok: false, message: "This memory lives in the vector store; there is no file to reveal.", details: [:])
                    }
                } catch {
                    reply(id, ok: false, message: error.localizedDescription, details: [:])
                }
            case "open.section":
                if let name = args["section"] as? String, let section = ActivitySection(rawValue: name) {
                    openSection(section)
                    reply(id, ok: true, message: "Opened", details: [:])
                } else {
                    reply(id, ok: false, message: "Unknown section.", details: [:])
                }
            case "pick.folder":
                // The one native affordance the setup path needs: a real folder
                // picker, so nobody types a path. Folders only, one at a time.
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.message = "Choose a folder of notes or documents for Knowledge to index"
                panel.prompt = "Use this folder"
                let outcome = await panel.begin()
                if outcome == .OK, let url = panel.url {
                    reply(id, ok: true, message: "Chosen", details: ["path": .string(url.path)])
                } else {
                    reply(id, ok: false, message: "No folder chosen.", details: [:])
                }
            default:
                guard let build = MemoriesWebView.helperOps[op] else {
                    reply(id, ok: false, message: "This page cannot ask for \(op).", details: [:])
                    return
                }
                do {
                    let response = try await model.runHelper(build(args), timeout: MemoriesWebView.timeout(for: op))
                    reply(id, ok: response.ok, message: response.message, details: response.details)
                } catch {
                    reply(id, ok: false, message: error.localizedDescription, details: [:])
                }
            }
        }

        private func reply(_ id: Int, ok: Bool, message: String, details: [String: JSONValue]) {
            let payload = HelperResponse(ok: ok, message: message, details: details)
            guard let data = try? JSONEncoder().encode(payload), let json = String(data: data, encoding: .utf8) else { return }
            webView?.evaluateJavaScript("window.cosBridge && window.cosBridge.resolve(\(id), \(json))") { _, _ in }
        }
    }
}

// MARK: - Held naming review (0.5.223)

struct HeldNamingReviewSheet: View {
    @ObservedObject var model: ControllerModel
    @State private var revisedName = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("PREVIEW · NO CHANGES YET").font(COSType.mono(10)).foregroundStyle(COSPalette.muted)
            if let preview = model.heldNamingPreview {
                Text("Name this voice \(preview.speaker)?").font(COSType.display(24))
                HStack(spacing: 10) {
                    TextField("Who is this?", text: $revisedName).textFieldStyle(.plain).cosField()
                        .accessibilityIdentifier("held-preview-name")
                    Button("Preview name") { Task { await model.nameHeld(preview.members, as: revisedName) } }
                        .buttonStyle(COSQuietButtonStyle())
                        .disabled(model.addVoiceBusy || revisedName.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                }
                Text("\(preview.eligibleSamples) held sample\(preview.eligibleSamples == 1 ? "" : "s") eligible · \(preview.labelled) transcript segment\(preview.labelled == 1 ? "" : "s") in \(preview.meetings.count) meeting\(preview.meetings.count == 1 ? "" : "s")")
                    .font(COSType.body(12, weight: .medium))
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("The server selects distinct voiceprints to keep. Apply reports how many were enrolled; naming several samples does not always add that many voiceprints.")
                            .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                        if preview.noTranscriptCount > 0 {
                            Text("\(preview.noTranscriptCount) samples have no transcript position. They can help the voice profile without adding transcript labels.")
                                .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                        }
                        ForEach(preview.meetings) { meeting in
                            HeldNamingMeetingDetail(model: model, meeting: meeting, showPlayback: true)
                        }
                        if let note = model.playbackNote, note.voice == "held-naming-preview" {
                            Text(note.text).font(COSType.body(11)).foregroundStyle(COSPalette.accent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 120, maxHeight: .infinity)
                if preview.owner {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(preview.ownerWarning ?? "This is your owner voice. Confirm these samples are your own voice.")
                            .font(COSType.body(11, weight: .medium)).foregroundStyle(COSPalette.accent)
                        Toggle("I confirm these samples are my own voice.", isOn: $model.heldNamingOwnerAck)
                            .toggleStyle(COSCheckStyle()).font(COSType.body(12))
                            .accessibilityIdentifier("held-owner-ack")
                    }
                }
                if preview.requiresListening {
                    Toggle("I listened and these segments sound like the same person.", isOn: $model.heldNamingListened)
                        .toggleStyle(COSCheckStyle()).font(COSType.body(12))
                        .accessibilityIdentifier("held-listening-ack")
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(preview.expiresAt.map { $0 > Date() ? "Preview expires at \($0.formatted(date: .omitted, time: .shortened)). If a meeting changes, preview again." : "This preview expired. Choose Preview name to refresh it." } ?? "Preview expiration unavailable. Preview again.")
                        .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
                    HStack {
                        Button("Cancel") { model.cancelHeldNamingPreview() }.buttonStyle(COSTextButtonStyle())
                        Spacer()
                        if model.addVoiceBusy { ProgressView().controlSize(.small) }
                        Button("Apply") { Task { await model.applyHeldNaming() } }
                            .buttonStyle(COSPrimaryButtonStyle())
                            .disabled(!model.heldNamingCanApply)
                            .accessibilityIdentifier("held-preview-apply")
                    }
                }
            } else {
                Text(model.addVoiceBusy ? "Preparing a fresh preview…" : (model.addVoiceResult ?? "Preview unavailable. Close and try again."))
                    .font(COSType.body(12))
                Button("Close") { model.cancelHeldNamingPreview() }.buttonStyle(COSTextButtonStyle())
            }
        }
        .padding(24)
        .frame(minWidth: 600, idealWidth: 700, maxWidth: 780, minHeight: 430, idealHeight: 590, maxHeight: 700)
        .background(COSPalette.panel)
        .onAppear { revisedName = model.heldNamingPreview?.speaker ?? "" }
        .onChange(of: model.heldNamingPreview?.previewHash) { _, _ in revisedName = model.heldNamingPreview?.speaker ?? revisedName }
        .onDisappear { model.stopPlayback() }
    }
}

struct HeldNamingMeetingDetail: View {
    @ObservedObject var model: ControllerModel
    let meeting: HeldNamingMeeting
    var showPlayback = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(ActivityWindow.heldSampleLabel(HeldSampleRef(sessionId: meeting.sessionId, chunkIndex: 0)).replacingOccurrences(of: " · chunk 0", with: ""))
                    .font(COSType.body(12, weight: .semibold))
                Spacer()
                Text(meeting.status.uppercased()).font(COSType.mono(9.5)).foregroundStyle(COSPalette.muted)
            }
            Text("\(meeting.named.count) named · \(meeting.wider.count) wider matches · \(meeting.labelled) transcript positions")
                .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
            if meeting.wider.isEmpty && showPlayback && meeting.status == "ready" {
                Text("No wider match. The named segments still get a label.").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
            }
            if let error = meeting.error {
                Text(error).font(COSType.body(11, weight: .medium)).foregroundStyle(COSPalette.accent)
            }
            if meeting.roomRisk {
                Text("Room caution: all agreeing samples for a wider match came from this meeting. Listen carefully.")
                    .font(COSType.body(11)).foregroundStyle(COSPalette.accent)
            }
            if meeting.labelsNewerThanGraph {
                Text("LABELS NEWER THAN GRAPH").font(COSType.mono(9)).foregroundStyle(COSPalette.accent)
            }
            ForEach(Array(meeting.copySummaries.enumerated()), id: \.offset) { _, copy in
                Text(copy).font(COSType.mono(9.5)).foregroundStyle(COSPalette.muted)
            }
            if showPlayback {
                if meeting.playback.isEmpty {
                    Text("No mapped audio to play. Audio expired, vectors only, or no transcript position.")
                        .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
                } else {
                    ForEach(Array(meeting.playback.prefix(5))) { triple in playbackRow(triple) }
                    if meeting.playback.count > 5 {
                        DisclosureGroup("Listen to all \(meeting.playback.count) segments") {
                            LazyVStack(alignment: .leading, spacing: 7) {
                                ForEach(Array(meeting.playback.dropFirst(5))) { triple in playbackRow(triple) }
                            }
                        }
                        .font(COSType.body(11))
                    }
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(COSPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(COSPalette.line, lineWidth: 1))
    }
    private func playbackRow(_ triple: HeldNamingPlayback) -> some View {
        HStack(spacing: 10) {
            Button(model.playingVoice == "naming:\(triple.id)" ? "Stop" : "Listen · chunk \(triple.chunkIndex)") {
                model.playHeldNamingMatch(triple)
            }
            .buttonStyle(COSQuietButtonStyle())
            .accessibilityIdentifier("held-preview-play-\(triple.id)")
            if let score = (meeting.raw["widerScores"]?.array ?? []).first(where: { $0.object?["chunkIndex"]?.int == triple.chunkIndex })?.object?["similarity"]?.double {
                Text("Sounds like · \(Int((score * 100).rounded()))%")
                    .font(COSType.mono(10)).foregroundStyle(COSPalette.muted)
            } else {
                Text("Named sample").font(COSType.mono(10)).foregroundStyle(COSPalette.muted)
            }
        }
    }
}

struct HeldNamingResultContent: View {
    @ObservedObject var model: ControllerModel
    let receipt: HeldNamingReceipt
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(receipt.kind == "undone" ? (receipt.partial ? "Some labels still need review" : "Labels restored") : "Naming \(receipt.speaker)")
                .font(COSType.display(23))
            if let error = receipt.raw["error"]?.string {
                Text(error).font(COSType.body(12, weight: .medium)).foregroundStyle(COSPalette.accent)
            }
            if receipt.kind == "undone" {
                Text("\(receipt.restoredSegments) segment\(receipt.restoredSegments == 1 ? "" : "s") restored · \(receipt.labelled) remain\(receipt.labelled == 1 ? "s" : "") labelled by this naming")
                    .font(COSType.body(12, weight: .medium))
            } else if receipt.kind == "applied" {
                Text("\(receipt.enrolled) sample\(receipt.enrolled == 1 ? "" : "s") enrolled · \(receipt.labelled) segment\(receipt.labelled == 1 ? "" : "s") labelled · \(receipt.deleted) audio sample\(receipt.deleted == 1 ? "" : "s") deleted")
                    .font(COSType.body(12, weight: .medium))
            }
            if let total = receipt.profileEmbeddings {
                Text("\(total) voice samples retained in the profile").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
            }
            if receipt.partial { Text("Some meetings or copies could not be completed. Review each outcome below.").font(COSType.body(11)).foregroundStyle(COSPalette.accent) }
            Text("Undo restores labels. Voice samples stay enrolled; deleted audio stays deleted. Search catches up at up to 10 meetings per sync; graph labels may lag.")
                .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
            if receipt.raw["lockMode"]?.string == "standalone" {
                Text("Standalone meeting library: no COS sync lock was needed.").font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
            }
            ForEach(receipt.meetings) { meeting in HeldNamingMeetingDetail(model: model, meeting: meeting) }
            if !receipt.memberOutcomes.isEmpty {
                DisclosureGroup("Sample outcomes (\(receipt.memberOutcomes.count))") {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(receipt.memberOutcomes) { member in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(ActivityWindow.heldSampleLabel(member.sample)).font(COSType.mono(10))
                                Text(member.hasNoTranscriptPosition ? "\(member.enrollmentStatus) · no transcript position · audio \(member.audioStatus)" : "Voice \(member.enrollmentStatus) · labels \(member.labelStatus) · audio \(member.audioStatus)")
                                    .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                                if let reason = member.reason { Text(reason).font(COSType.body(10.5)).foregroundStyle(COSPalette.accent) }
                            }
                        }
                    }
                }.font(COSType.body(12))
            }
        }
    }
}

struct HeldNamingResultSheet: View {
    @ObservedObject var model: ControllerModel
    var onClose: () -> Void = {}
    @State private var pendingUndo: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            if let receipt = model.heldNamingResult {
                ScrollView { HeldNamingResultContent(model: model, receipt: receipt).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button("Close") { onClose() }.buttonStyle(COSTextButtonStyle())
                    Spacer()
                    if let handle = receipt.undoHandle, receipt.kind != "undone" || receipt.partial {
                        Button("Undo labels") { pendingUndo = handle }
                            .buttonStyle(COSQuietButtonStyle())
                            .disabled(model.addVoiceBusy || !model.heldNamingAvailable)
                    }
                    if model.addVoiceBusy { ProgressView().controlSize(.small) }
                }
            } else { Text("No naming receipt is selected."); Button("Close") { onClose() } }
        }
        .padding(24).frame(minWidth: 600, idealWidth: 700, minHeight: 400, idealHeight: 560, maxHeight: 680)
        .background(COSPalette.panel)
        .cosConfirm(
            "Restore this naming’s previous labels?",
            isPresented: Binding(get: { pendingUndo != nil }, set: { if !$0 { pendingUndo = nil } }),
            message: "Later naming is protected. Voice samples stay enrolled; deleted audio stays deleted.",
            actions: [
                .destructive("Undo labels") { [handle = pendingUndo] in
                    if let handle { Task { await model.undoHeldNaming(handle) } }
                },
                .cancel("Keep labels"),
            ]
        )
    }
}

struct HeldNamingHistorySheet: View {
    @ObservedObject var model: ControllerModel
    var onClose: () -> Void = {}
    @State private var undoHandle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Recent naming").font(COSType.display(25))
            Text("Interrupted naming never resumes automatically. Resume opens a fresh preview; Revert restores this naming’s labels where later changes allow it.")
                .font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
            if !model.heldNamingAvailable {
                Text("Update the COS server to 6.46.0 or newer to review and undo naming.").font(COSType.body(12))
            }
            if let result = model.addVoiceResult { Text(result).font(COSType.body(11.5)).foregroundStyle(COSPalette.accent) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.heldNamingBatches) { batch in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Text(batch.speaker).font(COSType.body(13, weight: .semibold))
                                Spacer()
                                Text(batch.needsReview ? "INTERRUPTED NAMING" : batch.status.uppercased())
                                    .font(COSType.mono(9)).foregroundStyle(COSPalette.accent)
                            }
                            ForEach(batch.meetings) { meeting in HeldNamingMeetingDetail(model: model, meeting: meeting) }
                            HStack(spacing: 10) {
                                if batch.needsReview {
                                    Button("Resume") {
                                        onClose()
                                        Task { await model.resumeHeldNaming(batch) }
                                    }
                                    .buttonStyle(COSPrimaryButtonStyle())
                                    .disabled(model.addVoiceBusy || !model.heldNamingAvailable)
                                }
                                if let handle = batch.undoHandle, batch.status != "reverted" {
                                    Button(batch.needsReview ? "Revert labels" : "Undo labels") { undoHandle = handle }
                                        .buttonStyle(COSQuietButtonStyle())
                                        .disabled(model.addVoiceBusy || !model.heldNamingAvailable)
                                }
                            }
                        }
                        .padding(13).background(COSPalette.card).clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Voice samples stay enrolled. Audio is never restored. Per-copy results show any labels that could not be reverted.")
                .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
            HStack { Button("Close") { onClose() }.buttonStyle(COSTextButtonStyle()); Spacer(); if model.addVoiceBusy { ProgressView().controlSize(.small) } }
        }
        .padding(24).frame(minWidth: 600, idealWidth: 700, minHeight: 400, idealHeight: 580, maxHeight: 680)
        .background(COSPalette.panel)
        .cosConfirm(
            "Restore this naming’s previous labels?",
            isPresented: Binding(get: { undoHandle != nil }, set: { if !$0 { undoHandle = nil } }),
            message: "Later naming is protected. Voice samples stay enrolled; deleted audio stays deleted.",
            actions: [
                .destructive("Undo labels") { [handle = undoHandle] in
                    if let handle { Task { await model.undoHeldNaming(handle) } }
                },
                .cancel("Keep labels"),
            ]
        )
    }
}


/// One local monitor for Activity-owned overlays and linked navigation. SwiftUI's
/// onExitCommand alone depends on the current responder accepting cancelOperation.
private struct ActivityEscapeHandler: NSViewRepresentable {
    var onEscape: () -> Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.action = onEscape
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
            guard event.keyCode == 53, !event.isARepeat,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  let coordinator, let window = coordinator.view?.window,
                  window.isKeyWindow, window.attachedSheet == nil,
                  (event.window ?? NSApplication.shared.keyWindow) === window else { return event }
            return coordinator.action?() == true ? nil : event
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.action = onEscape }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }
    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var action: (() -> Bool)?
    }
}
