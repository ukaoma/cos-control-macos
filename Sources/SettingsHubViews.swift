import SwiftUI

// Settings hub (Miles, 2026-10-27 23:40, design/settings-hub): the shell drawn around ControlPanel's own pieces. The A
// treatment's sidebar and cards, and B's On this page rail. Every setting inside a card is ControlPanel's existing view
// or a row built from its existing binding and action, so behaviour, gates and confirmations are the classic panel's.
// Colours are TodayInk's light and dark pairs; type is COSType (Fraunces for display, DM Sans, JetBrains Mono).

/// What Activity hands ControlPanel from its Settings route. Its presence is what draws the hub: the menu-bar panel and
/// the standalone Settings window pass none and keep the one-page panel.
struct SettingsHubHost {
    /// Where "‹" goes: "Today", or the tab Settings was opened from.
    var backTitle: String
    var back: () -> Void
    /// ⌘← on "‹": only where no toolbar Back holds it (the Today frame), so the shortcut is never registered twice.
    var backShortcut = true
}

/// A hub row (A's `.row`): the label and its one-line description on the left, the control on the right, a hairline
/// above. The control keeps its one line at its own width; the words take what is left and wrap beside it.
struct SettingsHubRow<Control: View>: View {
    let label: String
    let detail: String
    var advanced = false
    var anchor: String?
    let control: Control

    init(label: String, detail: String, advanced: Bool = false, anchor: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label; self.detail = detail; self.advanced = advanced; self.anchor = anchor; self.control = control()
    }

    var body: some View {
        // One layout, never ViewThatFits: a measured second copy would give a stateful control (a recorder, a dropdown)
        // a second identity. The page keeps 480 pt or more (SettingsHubLayout), so the words wrap beside the control.
        HStack(alignment: .center, spacing: 16) {
            words
            // One line per button and value: a label never wraps inside its button (QA: "Recor/d").
            control.lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(advanced ? TodayInk.hubAdvancedBg : Color.clear)
        .overlay(alignment: .top) { SettingsHubHairline() }
        .id(anchor ?? "row." + label + "." + detail)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(COSType.body(14.5, weight: .semibold)).foregroundStyle(TodayInk.ink)
            if !detail.isEmpty {
                Text(detail).font(COSType.body(13)).foregroundStyle(TodayInk.sub)
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// An existing ControlPanel view placed in a card as it is: the card's padding and the hairline above.
struct SettingsHubBlock<Content: View>: View {
    var advanced = false
    let content: Content
    init(advanced: Bool = false, @ViewBuilder content: () -> Content) { self.advanced = advanced; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) { content }
            .font(COSType.body(13))
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(advanced ? TodayInk.hubAdvancedBg : Color.clear)
            .overlay(alignment: .top) { SettingsHubHairline() }
    }
}

/// A status value on the right of a row: a dot and words, green when good.
struct SettingsHubValue: View {
    let text: String
    var good: Bool? = nil
    var mono = false
    var body: some View {
        HStack(spacing: 7) {
            if let good {
                Circle().fill(good ? TodayInk.ok : TodayInk.grey.opacity(0.6)).frame(width: 8, height: 8).accessibilityHidden(true)
            }
            Text(text)
                .font(mono ? COSType.mono(12) : COSType.body(13))
                .foregroundStyle(good == true ? TodayInk.ok : TodayInk.sub)
                .lineLimit(2).multilineTextAlignment(.trailing)
        }
    }
}

struct SettingsHubHairline: View {
    var body: some View { Rectangle().fill(TodayInk.rowBorder).frame(height: 1).accessibilityHidden(true) }
}

/// A group (A's `section`): the title, its rows, and when the inventory marks rows Advanced, a disclosure with the count
/// at the bottom. The disclosure's state belongs to the hub, so a deep link or a search result can open it.
struct SettingsHubCard<Content: View, Advanced: View>: View {
    let group: SettingsHubGroup
    let advancedCount: Int
    @Binding var advancedOpen: Bool
    let content: Content
    let advanced: Advanced
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(group: SettingsHubGroup, advancedCount: Int, advancedOpen: Binding<Bool>, @ViewBuilder content: () -> Content,
         @ViewBuilder advanced: () -> Advanced) {
        self.group = group; self.advancedCount = advancedCount; _advancedOpen = advancedOpen
        self.content = content(); self.advanced = advanced()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(group.title)
                .font(COSType.body(16, weight: .semibold)).foregroundStyle(TodayInk.ink)
                .padding(EdgeInsets(top: 16, leading: 20, bottom: 12, trailing: 20))
                .accessibilityAddTraits(.isHeader)
            content
            if advancedCount > 0 {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { advancedOpen.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(advancedOpen ? 90 : 0))
                        Text("Advanced").font(COSType.body(13, weight: .medium))
                        Text("\(advancedCount)").font(COSType.body(13)).foregroundStyle(TodayInk.grey)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(TodayInk.sub)
                    .padding(.horizontal, 20).padding(.vertical, 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(TodayInk.hubAdvancedBg)
                    .overlay(alignment: .top) { SettingsHubHairline() }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Advanced, \(advancedCount) settings")
                .accessibilityValue(advancedOpen ? "Open" : "Closed")
                if advancedOpen { advanced }
            }
        }
        .frame(maxWidth: SettingsHubLayout.pageMaxWidth, alignment: .leading)
        .background(TodayInk.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(TodayInk.panelBorder, lineWidth: 1))
        .id(group.anchor)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.title)
    }
}

/// The search field (A): a magnifier, the placeholder with the catalogue's count, and the ⌘F hint.
struct SettingsHubSearchField: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(TodayInk.grey)
            TextField("Search settings", text: $query)
                .textFieldStyle(.plain).font(COSType.body(13)).foregroundStyle(TodayInk.ink)
                .focused(focused)
                .onExitCommand { query = "" }
                .accessibilityLabel("Search settings")
            if query.isEmpty {
                Text("⌘F").font(COSType.mono(11)).foregroundStyle(TodayInk.grey)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(TodayInk.panelBorder, lineWidth: 1))
                    .accessibilityHidden(true)
            } else {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(TodayInk.grey) }
                    .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(TodayInk.page))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(TodayInk.panelBorder, lineWidth: 1))
    }
}

/// The sidebar (A). Full: "‹ Today", the serif title, search, then each category with its icon, name and live status.
/// Narrow: icons only, with the name and status on hover; search moves to the top of the page.
struct SettingsHubSidebar: View {
    let mode: SettingsHubLayout.Mode
    let backTitle: String
    let back: () -> Void
    var backShortcut = true
    @Binding var query: String
    var searchFocused: FocusState<Bool>.Binding
    /// Nil while search results are showing.
    let selected: SettingsHubCategory?
    let status: (SettingsHubCategory) -> (text: String, tone: SettingsHubStatus.Tone)
    let select: (SettingsHubCategory) -> Void

    var body: some View {
        let full = mode != .narrow
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: full ? .leading : .center, spacing: 4) {
                Button(action: back) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        if full { Text(backTitle).font(COSType.body(13, weight: .medium)) }
                    }
                    .foregroundStyle(TodayInk.sub)
                    .padding(.horizontal, 8).frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(backShortcut ? KeyboardShortcut(.leftArrow, modifiers: .command) : nil)
                .help("Back to \(backTitle)")
                .accessibilityLabel("Back to \(backTitle)")
                if full {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Settings").font(COSType.display(30, weight: .medium)).foregroundStyle(TodayInk.ink)
                            .accessibilityAddTraits(.isHeader)
                        SettingsHubSearchField(query: $query, focused: searchFocused)
                    }
                    .padding(EdgeInsets(top: 10, leading: 12, bottom: 14, trailing: 12))
                } else {
                    Button { searchFocused.wrappedValue = true } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(TodayInk.sub)
                            .frame(width: 40, height: 36).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Search settings").accessibilityLabel("Search settings")
                    .padding(.bottom, 6)
                }
                ForEach(SettingsHubCategory.allCases) { category in
                    item(category, full: full)
                }
            }
            .padding(EdgeInsets(top: 22, leading: full ? 14 : 10, bottom: 28, trailing: full ? 14 : 10))
        }
        .frame(width: SettingsHubLayout.sidebar(mode))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(TodayInk.rail)
        .overlay(alignment: .trailing) { Rectangle().fill(TodayInk.railBorder).frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings categories")
    }

    private func item(_ category: SettingsHubCategory, full: Bool) -> some View {
        let active = selected == category
        let line = status(category)
        let tone: Color = line.tone == .hot ? TodayInk.hot : line.tone == .good ? TodayInk.ok : TodayInk.sub
        return Button { select(category) } label: {
            Group {
                if full {
                    HStack(alignment: .top, spacing: 12) {
                        // Beside the name's first line on purpose, as on the board (a list mark, not a label icon).
                        Image(systemName: category.symbol).frame(width: 18, height: 18).padding(.top, 1)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(active ? TodayInk.accent : TodayInk.grey)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.title).font(COSType.body(14, weight: .semibold)).foregroundStyle(TodayInk.ink)
                            Text(line.text).font(COSType.body(12.5)).foregroundStyle(tone).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Image(systemName: category.symbol).font(.system(size: 15, weight: .regular))
                        .foregroundStyle(active ? TodayInk.accent : TodayInk.grey)
                        .frame(width: 42, height: 40)
                        .overlay(alignment: .topTrailing) {
                            if line.tone == .hot {
                                Circle().fill(TodayInk.hot).frame(width: 7, height: 7).padding(6)
                            }
                        }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(active ? TodayInk.railActive : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(active ? TodayInk.panelBorder : Color.clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(category.title + ", " + line.text)
        .accessibilityLabel(category.title + ", " + line.text)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// On this page (B's rail): the open category's groups. The group in view has the ink colour, semibold and an accent
/// rule on its left; the rest the sub colour and a hairline rule. A click scrolls to the group.
struct SettingsHubOnThisPage: View {
    let groups: [SettingsHubGroup]
    let active: String?
    let go: (SettingsHubGroup) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("On this page").font(COSType.body(12, weight: .semibold)).foregroundStyle(TodayInk.grey)
                .padding(EdgeInsets(top: 0, leading: 12, bottom: 8, trailing: 0))
            ForEach(groups) { group in
                let on = group.id == active
                Button { go(group) } label: {
                    Text(group.title)
                        .font(COSType.body(13, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? TodayInk.ink : TodayInk.sub)
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .padding(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 0))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(on ? TodayInk.accent : TodayInk.panelBorder).frame(width: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(group.blurb)
                .accessibilityLabel(group.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(width: SettingsHubLayout.railWidth - 20, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("On this page")
    }
}

/// The page header: the category in Fraunces about 40 pt and its one line.
struct SettingsHubPageHeader: View {
    let title: String
    let line: String
    /// The panel's busy spinner, beside the title.
    var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Text(title).font(COSType.display(40, weight: .medium)).foregroundStyle(TodayInk.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if busy { ProgressView().controlSize(.small) }
            }
            Text(line).font(COSType.body(15)).foregroundStyle(TodayInk.sub).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: SettingsHubLayout.pageMaxWidth, alignment: .leading)
    }
}

/// Search results across the whole catalogue, grouped by category. Choosing a row opens its category, its group and,
/// when the row sits there, Advanced.
struct SettingsHubSearchResults: View {
    let query: String
    let sections: [SettingsHubSearch.Section]
    let open: (SettingsHubItem) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            let count = sections.reduce(0) { $0 + $1.items.count }
            SettingsHubPageHeader(title: "Search", line: count == 0
                ? "No settings match “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”. Try fewer words, or the name a setting used to have."
                : (count == 1 ? "1 setting matches" : "\(count) settings match") + " “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”.")
            ForEach(sections, id: \.category) { section in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: section.category.symbol).foregroundStyle(TodayInk.grey)
                        Text(section.category.title).font(COSType.body(16, weight: .semibold)).foregroundStyle(TodayInk.ink)
                    }
                    .padding(EdgeInsets(top: 16, leading: 20, bottom: 12, trailing: 20))
                    ForEach(section.items) { item in
                        Button { open(item) } label: { resultRow(item) }.buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: SettingsHubLayout.pageMaxWidth, alignment: .leading)
                .background(TodayInk.panel)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(TodayInk.panelBorder, lineWidth: 1))
            }
        }
    }

    private func resultRow(_ item: SettingsHubItem) -> some View {
        let where_ = item.group.flatMap { SettingsHubCatalog.group($0)?.title } ?? ""
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.label).font(COSType.body(14.5, weight: .semibold)).foregroundStyle(TodayInk.ink)
                Text(item.detail).font(COSType.body(13)).foregroundStyle(TodayInk.sub).fixedSize(horizontal: false, vertical: true)
                // Only a real former label, and only when the old name is what matched.
                if let former = item.formerLabel, let rank = SettingsHubSearch.rank(item, query: query), rank == 2 {
                    Text("Was: " + former).font(COSType.body(12)).foregroundStyle(TodayInk.grey).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.advanced ? where_ + ", Advanced" : where_).font(COSType.body(12.5)).foregroundStyle(TodayInk.grey).lineLimit(1)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(TodayInk.grey)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .overlay(alignment: .top) { SettingsHubHairline() }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(where_)")
    }
}

/// On this page's scroll-spy. The cards report where their tops are on every scroll step; only the rail observes the
/// result, so scrolling never redraws the page or ControlPanel (it holds this in `@State`, which does not observe it).
@MainActor final class SettingsHubSpyModel: ObservableObject {
    @Published private(set) var active: String?
    /// How far below the top of the page a group's title has to pass to count as in view.
    static let line: CGFloat = 140
    private var order: [String] = []
    private var tops: [String: CGFloat] = [:]
    private var viewport: CGFloat = 0
    private var bottom: CGFloat = .greatestFiniteMagnitude
    private var contentTop: CGFloat = 0

    /// A new page: these groups, in order.
    func page(_ groups: [String]) {
        guard groups != order else { return }
        order = groups
        tops = tops.filter { groups.contains($0.key) }
        recompute()
    }
    func top(_ group: String, _ minY: CGFloat) { tops[group] = minY; recompute() }
    func viewport(_ height: CGFloat) { viewport = height; recompute() }
    func bottom(_ maxY: CGFloat) { bottom = maxY; recompute() }
    func content(top minY: CGFloat, bottom maxY: CGFloat) { contentTop = minY; bottom = maxY; recompute() }

    private var computed: String?
    private var publishQueued = false

    private func recompute() {
        let measured = order.compactMap { id in tops[id].map { (id: id, minY: $0) } }
        // A page that fits has no end to reach: its first group stays in view.
        let atEnd = viewport > 0 && contentTop < -1 && bottom <= viewport + 2 && measured.count > 1
        // Until a group has passed the line (or the end is reached), the page's first group is in view, measured or not:
        // the cards report from the bottom up, so the first one measured is often the last on the page.
        let passed = atEnd || measured.contains { $0.minY <= Self.line }
        computed = passed ? SettingsHubSpy.active(tops: measured, line: Self.line, atEnd: atEnd) : order.first
        // Published after the layout pass that measured it: a change published inside a view update is dropped, which
        // left On this page on the first group measured (2026-10-28 renders).
        guard !publishQueued else { return }
        publishQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.publishQueued = false
            if self.computed != self.active { self.active = self.computed }
        }
    }
}

/// The rail, observing the spy.
struct SettingsHubSpyRail: View {
    @ObservedObject var spy: SettingsHubSpyModel
    let groups: [SettingsHubGroup]
    let go: (SettingsHubGroup) -> Void
    var body: some View {
        SettingsHubOnThisPage(groups: groups, active: spy.active ?? groups.first?.id, go: go)
    }
}

extension View {
    /// Reports this group's top, in the page's scroll space, to the spy. Called on every scroll step; it publishes only
    /// when the group in view changes.
    func settingsHubSpyTop(_ group: String, space: String, spy: SettingsHubSpyModel) -> some View {
        background(GeometryReader { geometry in
            Color.clear.onChange(of: geometry.frame(in: .named(space)).minY, initial: true) { _, y in spy.top(group, y) }
        })
    }
}

/// The live facts behind the sidebar's status lines, read from the stores that publish them, so a line changes when its
/// store does without redrawing the page.
struct SettingsHubFactsReader<Content: View>: View {
    @ObservedObject var model: ControllerModel
    @ObservedObject var permissions: PermissionGuide
    @ObservedObject var dictation: MacDictationStore
    @ObservedObject var cues: LiveCuesStore
    @ObservedObject var stt: TranscriptionSettingsStore
    @ObservedObject var setup: SetupGuideState
    @AppStorage(TodayHome.enabledKey) private var todayHome = false
    let content: (SettingsHubFacts) -> Content

    init(model: ControllerModel, permissions: PermissionGuide, dictation: MacDictationStore, cues: LiveCuesStore,
         stt: TranscriptionSettingsStore, setup: SetupGuideState, @ViewBuilder content: @escaping (SettingsHubFacts) -> Content) {
        self.model = model; self.permissions = permissions; self.dictation = dictation; self.cues = cues
        self.stt = stt; self.setup = setup; self.content = content
    }

    var body: some View { content(facts) }

    private var facts: SettingsHubFacts {
        var f = SettingsHubFacts()
        let status = model.status
        f.todayHome = todayHome
        f.serverChecked = status.runtimeState != "unknown"
        f.serverRunning = status.running
        if status.running {
            // Claude and Codex readiness is optional (an older server omits it); Cursor's comes with every answer.
            let known = [status.claudeCliReady, status.codexCliReady].compactMap { $0 } + [status.cursorReady]
            f.aiKnown = known.count
            f.aiReady = known.filter { $0 }.count
        }
        f.glassesPath = setup.devicePath == .glasses
        f.liveCuesOn = cues.settings?.enabled
        f.recording = model.recordingCount > 0
        f.dictationOn = dictation.enabled
        f.dictationEngine = stt.settings?.dictation?.selected
        f.usesParakeet = setup.voice?.usesParakeet
        f.whisperReady = status.whisperReady
        if status.morningBriefSupported, let enabled = status.morningBriefEnabled {
            f.briefEnabled = enabled
            f.briefTime = status.morningBriefTime.map { model.clockStyle.format($0) }
        }
        f.permissionsNeed = permissions.rows.isEmpty ? nil : permissions.needCount
        f.petOn = model.petEnabled
        f.updateReady = model.appUpdateFlow.phase == .ready
        return f
    }
}

/// One of the setup guide's own rows (Ollama, Voice, the dictation engine) placed in its category, observing the guide's
/// stores so it reads as the guide does.
struct SettingsHubSetupRow: View {
    @ObservedObject var model: ControllerModel
    @ObservedObject var provider: ProviderGuide
    @ObservedObject var guide: SetupGuideState
    let id: SetupRowID
    var body: some View {
        let rows = SetupGuideRules.rows(model.setupFacts(provider: provider, guide: guide), skipped: guide.skipped)
        if let row = rows.first(where: { $0.id == id }) {
            SetupRowView(model: model, guide: guide, row: row)
        }
    }
}

/// OUT-04, Track session usage on this Mac, from the store Activity's Usage view shares (it starts and stops the count).
struct SettingsHubUsageSwitch: View {
    @ObservedObject var store: SessionUsageStore
    let label: String
    var body: some View {
        Toggle(isOn: $store.enabled) { EmptyView() }
            .toggleStyle(COSSwitchStyle())
            .accessibilityLabel(label)
    }
}

/// The permission summary ("All set", "1 needs you") for PM-01's row.
struct SettingsHubPermissionsSummary: View {
    @ObservedObject var guide: PermissionGuide
    var body: some View {
        SettingsHubValue(text: guide.summary, good: guide.rows.isEmpty ? nil : guide.needCount == 0)
    }
}

/// Copy the hub adds around the existing settings.
enum SettingsHubCopy {
    static let appliesRestart = "Applying restarts the server."
    /// What set-workdir, set-operations-dir and set-context-dir do: restart through the drain, which waits for running
    /// work (a stopped server takes the folder when it starts; an older server shows the pending line instead).
    static let chooseRestarts = "Changing it restarts the server when no work is running."
    static let todayFirst = "Turn on Today home to use this."
    static let waitsForWork = "Apply is off until running work finishes."
    static let plannerNote = "Used when the server offers a choice."
}

/// A part of the hub that reads a store ControlPanel does not observe (Transcription's, the key lanes'), so it appears the
/// moment that store answers rather than at the next status refresh.
struct SettingsHubObserving<Object: ObservableObject, Content: View>: View {
    @ObservedObject var object: Object
    let content: (Object) -> Content
    init(_ object: Object, @ViewBuilder content: @escaping (Object) -> Content) {
        self.object = object; self.content = content
    }
    var body: some View { content(object) }
}

/// Which part of MeetingAskSettings draws: both (the panel), or one of the hub's two groups.
enum MeetingAskSettingsPart: Sendable { case all, assistant, liveCues }

extension SettingsHubRow {
    /// A row in the catalog's words for inventory row `id`.
    init(_ id: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        let item = SettingsHubCatalog.item(id)
        self.init(label: item?.label ?? id, detail: detail ?? item?.detail ?? "", advanced: item?.advanced ?? false,
                  anchor: "item." + id, control: control)
    }
}

/// AI and accounts, Your own key (KL-01 to KL-15): KeyLanesSettingsRow, drawn only when it would draw (server 6.80.0,
/// lanes on, keys saved here, or an install waiting on them).
struct SettingsHubOwnKeyCard: View {
    @ObservedObject var model: ControllerModel
    @ObservedObject var store: KeyLanesStore = .shared
    let spy: SettingsHubSpyModel
    let space: String
    @Binding var advancedOpen: Bool
    static func shown(_ model: ControllerModel, _ store: KeyLanesStore = .shared) -> Bool {
        KeyLanes.rowVisible(serverVersion: model.status.version, enabled: store.enabled, savedKeys: store.savedKeys) || store.blockedInstall != nil
    }
    /// The rows behind Advanced right now: the downgrade's Remove saved keys and continue (KL-02), Remove saved keys while
    /// lanes are off (KL-03), and Remove all keys with the ledger switch (KL-14, KL-15) while a key is saved.
    static func advancedCount(_ store: KeyLanesStore) -> Int {
        var n = 0
        if store.blockedInstall != nil { n += 1 }
        if !store.enabled, store.blockedInstall == nil, KeyLanes.savedKeysRowVisible(enabled: false, savedKeys: store.savedKeys) { n += 1 }
        if store.enabled, store.hasKey { n += 2 }
        return n
    }
    var body: some View {
        if Self.shown(model, store), let group = SettingsHubCatalog.group("ai.keys") {
            // A waiting install needs its row, so Advanced opens on its own then.
            SettingsHubCard(group: group, advancedCount: Self.advancedCount(store),
                            advancedOpen: Binding(get: { advancedOpen || store.blockedInstall != nil }, set: { advancedOpen = $0 })) {
                KeyLanesSettingsRow(model: model, part: .main)
            } advanced: {
                KeyLanesSettingsRow(model: model, part: .advanced).background(TodayInk.hubAdvancedBg)
            }
            .settingsHubSpyTop(group.id, space: space, spy: spy)
        }
    }
}

/// AI and accounts, Search (OUT-07): search messages by meaning, beside the cost it carries. The same switch as the
/// Messages search's own checkbox.
struct SettingsHubSemanticSearchRow: View {
    @ObservedObject var model: ControllerModel
    var body: some View {
        SettingsHubRow("OUT-07") {
            Toggle(isOn: Binding(get: { model.semanticSearchEnabled }, set: { model.setSemanticSearchEnabled($0) })) { EmptyView() }
                .toggleStyle(COSSwitchStyle())
                .accessibilityLabel(SettingsHubCatalog.item("OUT-07")?.label ?? "Search by meaning")
        }
    }
}

/// Redraws its content when the key lanes' store changes (On this page lists Your own key only while it draws).
struct SettingsHubOwnKeyObserving<Content: View>: View {
    @ObservedObject var store: KeyLanesStore = .shared
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
}

// MARK: Hosted sub-views

/// True inside the hub's page. A view the hub hosts (Meeting assistant, Live cues, Transcription, Your own key, Dictation,
/// recording suggestions, the setup and permission rows) reads it to drop its own card, padding and repeated title, and to
/// lay its switches and pickers out as hub rows. Absent (false) everywhere else, so the menu-bar panel, the Settings
/// window and Activity's Dictation tab draw exactly as before.
private struct SettingsHubHostedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var settingsHubHosted: Bool {
        get { self[SettingsHubHostedKey.self] }
        set { self[SettingsHubHostedKey.self] = newValue }
    }
}

/// A line a hosted view keeps under its rows (a server's refusal, a note, a state): the rows' inset, in the hub's type.
struct SettingsHubNote: View {
    enum Tone { case plain, warning }
    let text: String
    var tone: Tone = .plain
    var body: some View {
        Text(text)
            .font(COSType.body(13)).foregroundStyle(tone == .warning ? TodayInk.hot : TodayInk.sub)
            .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            .padding(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20))
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { SettingsHubHairline() }
    }
}

/// A switch for a hub row: the COS switch without words (the row says them).
struct SettingsHubSwitch: View {
    let label: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) { EmptyView() }
            .toggleStyle(COSSwitchStyle())
            .accessibilityLabel(label)
    }
}

extension View {
    /// The card a sub-view draws around itself in the panel. Hosted in the hub, the hub's card is the card: nothing.
    func settingsPanelCard(padding: CGFloat = 12, radius: CGFloat = 12) -> some View {
        modifier(SettingsPanelCard(padding: padding, radius: radius))
    }
}

private struct SettingsPanelCard: ViewModifier {
    let padding: CGFloat
    let radius: CGFloat
    @Environment(\.settingsHubHosted) private var hosted
    func body(content: Content) -> some View {
        if hosted {
            content
        } else {
            content.padding(padding).background(COSPalette.card, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}

/// MacDictationSettings in the hub: one group each. `.all` is the panel's and the Dictation tab's single view.
enum DictationSettingsSection: String, CaseIterable, Sendable {
    case all, dictation, microphone, shortcuts, sounds, text, polish, history
}

/// KeyLanesSettingsRow in the hub: the card's rows, or the rows behind its Advanced disclosure (KL-02, KL-03, KL-14,
/// KL-15). `.all` is the panel's.
enum KeyLanesSettingsPart: Sendable { case all, main, advanced }

extension View {
    /// One setting inside a hosted view: in the hub, the row's inset and hairline, the hub's label type, and the
    /// description under it. Outside the hub, nothing changes.
    func settingsHubRow(_ detail: String? = nil) -> some View { modifier(SettingsHubRowChrome(detail: detail, block: false)) }
    /// A hosted part that keeps its own layout (a shortcut recorder, the sound pickers): the rows' inset and hairline.
    func settingsHubBlock() -> some View { modifier(SettingsHubRowChrome(detail: nil, block: true)) }
    /// A lone control (a button) inside a hosted view: in the hub, a full row with the catalog row's label and description
    /// on the left and the control on the right. Outside the hub, nothing changes.
    func settingsHubLabeled(_ id: String) -> some View { modifier(SettingsHubLabeledChrome(item: SettingsHubCatalog.item(id))) }
    /// A hosted row's search anchor ("item.<id>"), so a result lands on the row itself, not only its card.
    func settingsHubAnchor(_ id: String) -> some View { modifier(SettingsHubAnchorChrome(id: id)) }
    /// The hub root's read of Your own key (QA 2026-10-28 S4): once for every page, when the server starts, stops or
    /// changes version, since the key state feeds Continue and Fork's guard. The row's own read stays off in the hub.
    @MainActor func settingsHubOwnKeyReader(_ model: ControllerModel) -> some View {
        task(id: "\(model.status.running) \(model.status.version ?? "")") { await KeyLanesSettingsRow.load(model) }
    }
}

private struct SettingsHubAnchorChrome: ViewModifier {
    let id: String
    @Environment(\.settingsHubHosted) private var hosted
    func body(content: Content) -> some View {
        if hosted { content.id("item." + id) } else { content }
    }
}

private struct SettingsHubLabeledChrome: ViewModifier {
    let item: SettingsHubItem?
    @Environment(\.settingsHubHosted) private var hosted
    func body(content: Content) -> some View {
        if hosted, let item {
            SettingsHubRow(label: item.label, detail: item.detail, advanced: item.advanced, anchor: "item." + item.id) { content }
        } else {
            content
        }
    }
}

private struct SettingsHubRowChrome: ViewModifier {
    let detail: String?
    let block: Bool
    @Environment(\.settingsHubHosted) private var hosted
    func body(content: Content) -> some View {
        if hosted {
            VStack(alignment: .leading, spacing: 4) {
                if block {
                    content
                } else {
                    content.font(COSType.body(14.5, weight: .semibold)).foregroundStyle(TodayInk.ink)
                }
                if let detail, !detail.isEmpty {
                    Text(detail).font(COSType.body(13)).foregroundStyle(TodayInk.sub).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, block ? 12 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { SettingsHubHairline() }
        } else {
            content
        }
    }
}
