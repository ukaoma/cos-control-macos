import AppKit
import SwiftUI

// MARK: Drop it views (0.5.371)
//
// The pinned COS row above Messages' Recent list, the pinned chat with its Drop it composer, History, and the "Back to the chat"
// strip a deep link leaves on the pane it opened. Built to the approved mock (operations/personal/wk45_2026/drop-it-mock): his
// drops on the right, COS on the left as compact cards with one primary button and quiet links, day separators and an "N new"
// line. Every one of these mounts only while `model.status.dropIt.available` (Sources/ActivityWindow.swift); the chat and History
// each mount on their own route flag, which only their openers write. Inline navigation, never a sheet. The rules are in
// Sources/DropIt.swift.

enum DropInk {
    private static func pair(_ light: UInt32, _ dark: UInt32) -> Color {
        func color(_ v: UInt32) -> NSColor { NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1) }
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark) : color(light) })
    }
    /// His bubble (the mock's --you-bg, --you-border, --you-ink).
    static let youBg = pair(0xf1e4c9, 0x3a2c1e)
    static let youBorder = pair(0xe3cfa6, 0x56422c)
    static let youInk = pair(0x2b1f14, 0xf2e8da)
    static let tertiary = pair(0x8b857c, 0x8a7f70)
    static let note = Color(red: 0.66, green: 0.42, blue: 0.24)

    static func tint(_ glyph: DropIt.Glyph) -> Color {
        switch glyph {
        case .work: ActivitySection.work.tint
        case .thread: ActivitySection.threads.tint
        case .memory: ActivitySection.memories.tint
        case .session: ActivitySection.sessions.tint
        case .reminder, .note: note
        case .question: TodayInk.accent
        case .answer: ActivitySection.messages.tint
        }
    }
    static func symbol(_ glyph: DropIt.Glyph) -> String {
        switch glyph {
        case .work: "tray.full"
        case .thread: "point.3.connected.trianglepath.dotted"
        case .memory: "sparkles"
        case .session: "terminal"
        case .reminder: "bell"
        case .note: "doc.text"
        case .question: "sparkle"
        case .answer: "text.bubble"
        }
    }
}

/// The COS mark on its dark tile (the mock's .cosav).
struct DropItAvatar: View {
    var size: CGFloat = 36
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(TodayInk.runBg)
            .frame(width: size, height: size)
            .overlay(Image(nsImage: COSBrand.svg("COSMark")).renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
                .frame(width: size * 0.48, height: size * 0.52).foregroundStyle(TodayInk.runOpen))
            .accessibilityHidden(true)
    }
}

/// A tinted glyph tile (the mock's .gl).
struct DropItGlyph: View {
    let glyph: DropIt.Glyph
    var size: CGFloat = 28
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.29, style: .continuous).fill(DropInk.tint(glyph).opacity(0.14))
            .frame(width: size, height: size)
            .overlay(Image(systemName: DropInk.symbol(glyph)).font(.system(size: size * 0.5, weight: .regular)).foregroundStyle(DropInk.tint(glyph)))
            .accessibilityHidden(true)
    }
}

// MARK: The pinned row

/// The first row of Messages' Recent list: COS, its last line and time, and how many pings, follow-ups and questions are unread.
/// Above the existing list, which is unchanged under it.
struct DropItPinnedRow: View {
    @ObservedObject var store: DropItStore
    let open: () -> Void
    var now: Date = Date()
    /// Off in the render harness: the 30-second summary refresh.
    var polls = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: open) {
                HStack(alignment: .center, spacing: 14) {
                    DropItAvatar(size: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(DropIt.rowName).font(COSType.body(15, weight: .semibold)).foregroundStyle(TodayInk.ink)
                            Image(systemName: "pin").font(.system(size: 11)).foregroundStyle(TodayInk.accent).accessibilityLabel("Pinned")
                            Text(DropIt.rowTime(store.summary.lastAt, now: now)).font(COSType.mono(11.5)).foregroundStyle(TodayInk.grey)
                        }
                        Text(DropIt.rowLine(store.summary)).font(COSType.body(13.5)).foregroundStyle(TodayInk.sub)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 7) {
                        if let count = DropIt.unreadLabel(store.summary.unread) {
                            Text(count).font(COSType.body(12, weight: .semibold)).foregroundStyle(TodayInk.panel)
                                .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22)
                                .background(Capsule().fill(TodayInk.hot))
                                .accessibilityLabel("\(store.summary.unread) unread")
                        }
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(TodayInk.panel))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(TodayInk.panelBorder, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("COS, pinned chat")
            .accessibilityHint("Opens your drops and what COS did with them")
            Text(DropIt.pinNote).font(COSType.body(12)).foregroundStyle(DropInk.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .task {
            await store.refreshSummary()
            guard polls else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { break }
                await store.refreshSummary()
            }
        }
    }
}

// MARK: The chat

/// What the chat's composer can reach outside the store.
struct DropItComposerHooks {
    /// Mac dictation: whether it is on, and a press that starts or stops it (into the focused field, the composer).
    var dictationOn: Bool = false
    var dictate: () -> Void = {}
    /// The Work areas and threads Move offers, and their load.
    var domains: () -> [(name: String, label: String)] = { [] }
    var threads: () -> [(id: String, title: String)] = { [] }
    var loadMoveOptions: () async -> Void = {}
}

struct DropItChatPane: View {
    @ObservedObject var store: DropItStore
    var hooks = DropItComposerHooks()
    let onAllMessages: () -> Void
    let onHistory: () -> Void
    /// An open action on a chat item: the window navigates (Work, a session, Threads, Memories, Messages).
    let onOpen: (DropIt.Item, DropIt.Action) -> Void
    var now: Date = Date()
    /// Off in the render harness: the 10-second chat refresh.
    var polls = true
    /// The renders' typed words (the box starts empty in the app).
    var initialDraft = ""
    /// The renders' drag in progress over the box (false in the app until a drag enters).
    var initialTargeted = false
    @State private var draft = ""
    @State private var moving: String?
    @State private var movePick: String?
    @State private var moveSearch = ""
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            thread
            composer
        }
        .background(TodayInk.page)
        .task {
            await store.loadFeed(opening: true)
            guard polls else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { break }
                await store.loadFeed()
            }
        }
        // An Ask still answering is read back every 3 seconds, in the renders too only when it polls.
        .task(id: store.asks.filter { !$0.finished }.count) {
            if polls {
                while !Task.isCancelled, store.asks.contains(where: { !$0.finished }) {
                    await store.refreshAsks()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
        .onDisappear { store.closed() }
        .onAppear {
            if draft.isEmpty, !initialDraft.isEmpty { draft = initialDraft }
            if initialTargeted { dropTargeted = true }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            DropItAvatar(size: 42)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(DropIt.rowName).font(COSType.display(26, weight: .medium)).foregroundStyle(TodayInk.ink)
                    Image(systemName: "pin").font(.system(size: 11)).foregroundStyle(TodayInk.accent).accessibilityLabel("Pinned")
                }
                Text(DropIt.chatLine).font(COSType.body(13)).foregroundStyle(TodayInk.sub).lineLimit(2)
            }
            Spacer(minLength: 12)
            HStack(spacing: 18) {
                Button(DropIt.allMessages, action: onAllMessages).buttonStyle(TodayLinkStyle(color: TodayInk.grey, size: 13))
                Button(DropIt.historyLink, action: onHistory).buttonStyle(TodayLinkStyle(size: 13))
                Button(DropIt.markAllRead) { Task { await store.markAllRead() } }.buttonStyle(TodayLinkStyle(color: TodayInk.grey, size: 13))
                    .disabled(store.items.isEmpty)
            }
            // The links keep one line each; the line under the title wraps instead.
            .lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 28).padding(.vertical, 16)
        .background(TodayInk.rail.opacity(0.6))
    }

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if store.loaded && store.items.isEmpty && store.asks.isEmpty {
                        Text(DropIt.chatEmpty).font(COSType.body(13)).foregroundStyle(TodayInk.grey)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    } else if !store.loaded, let line = store.line {
                        Text(line).font(COSType.body(13)).foregroundStyle(TodayInk.grey).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(DropIt.rows(DropIt.merged(store.items, asks: store.asks), firstNew: store.newMark?.first, newCount: store.newMark?.count ?? 0, now: now)) { row in
                        rowView(row)
                    }
                    Color.clear.frame(height: 1).id("drop-it-bottom")
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 28).padding(.vertical, 18)
                .frame(maxWidth: .infinity)
            }
            // Opens on the newest line, and follows a new one in.
            .defaultScrollAnchor(.bottom)
            .onChange(of: store.items.count + store.asks.count) { _, _ in proxy.scrollTo("drop-it-bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("drop-it-bottom", anchor: .bottom) }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    @ViewBuilder
    private func rowView(_ row: DropIt.Row) -> some View {
        switch row {
        case .separator(_, let day, let time):
            HStack(spacing: 4) {
                if let day { Text(day).font(COSType.body(12, weight: .semibold)).foregroundStyle(TodayInk.sub) }
                Text(time).font(COSType.body(12)).foregroundStyle(DropInk.tertiary)
            }
            .frame(maxWidth: .infinity).padding(.top, 10).padding(.bottom, 2)
        case .newLine(_, let count):
            HStack(spacing: 10) {
                Rectangle().fill(TodayInk.hotBorder).frame(height: 1)
                Text("\(count) new").font(COSType.body(11.5, weight: .semibold)).foregroundStyle(TodayInk.hot)
            }
            .padding(.top, 8)
            .accessibilityElement(children: .combine)
        case .item(let item):
            if item.kind == "ask" { askRows(item) } else if item.fromYou { youBubble(item) } else { cosCard(item) }
        }
    }

    private func youBubble(_ item: DropIt.Item) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(item.line).font(COSType.body(14.5)).foregroundStyle(DropInk.youInk)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6, topTrailingRadius: 18, style: .continuous).fill(DropInk.youBg))
                .overlay(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6, topTrailingRadius: 18, style: .continuous).stroke(DropInk.youBorder, lineWidth: 1))
            // 6.99.13: the files that went with a drop are its file links.
            let files = item.links.filter { $0.kind == "file" }
            if !files.isEmpty {
                HStack(spacing: 6) { ForEach(files, id: \.id) { link in DropItSentFile(name: link.label, kind: DropIt.fileKind(name: link.label), thumb: nil) } }
            }
            if item.kind == "drop", !DropIt.sourcePhrase(item.source).isEmpty {
                Text(DropIt.sourcePhrase(item.source)).font(COSType.body(11.5)).foregroundStyle(DropInk.tertiary).padding(.trailing, 4)
            }
        }
        .frame(maxWidth: 560, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .id(item.id)
    }

    private func cosCard(_ item: DropIt.Item) -> some View {
        let glyph = DropIt.glyph(item)
        let buttons = DropIt.buttons(item)
        let busy = store.isBusy(item.threadId)
        let isMoving = moving == item.threadId && item.live
        return HStack(alignment: .bottom, spacing: 10) {
            DropItAvatar(size: 30).padding(.bottom, 18)
            VStack(alignment: .leading, spacing: 8) {
                if let quote = DropIt.quote(for: item, in: store.items) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(quote.who).font(COSType.body(11.5)).foregroundStyle(TodayInk.sub)
                        Text(quote.words).font(COSType.display(13.5, italic: true)).foregroundStyle(TodayInk.ink).lineLimit(1).truncationMode(.tail)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 8, topTrailingRadius: 8).fill(TodayInk.qopen))
                    .overlay(alignment: .leading) { Rectangle().fill(TodayInk.btnBorder).frame(width: 2) }
                }
                HStack(alignment: .top, spacing: 11) {
                    DropItGlyph(glyph: glyph)
                    VStack(alignment: .leading, spacing: 2) {
                        if let title = item.title {
                            Text(title).font(COSType.body(14, weight: .semibold)).foregroundStyle(TodayInk.ink).fixedSize(horizontal: false, vertical: true)
                        }
                        Text(item.line).font(COSType.body(item.title == nil ? 14 : 12.5)).foregroundStyle(item.title == nil ? TodayInk.ink : TodayInk.sub)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if item.kind == "question", item.live { choices(item, busy: busy) }
                        if isMoving {
                            moveBox(item, busy: busy)
                        } else if buttons.primary != nil || !buttons.quiet.isEmpty {
                            HStack(spacing: 12) {
                                if let primary = buttons.primary {
                                    Button(primary.label) { act(item, primary) }.buttonStyle(TodayButtonStyle(primary: true, small: true))
                                }
                                ForEach(buttons.quiet, id: \.id) { action in
                                    Button(action.label) { act(item, action) }.buttonStyle(TodayLinkStyle(color: TodayInk.grey, size: 13))
                                }
                            }
                            .disabled(busy)
                            .padding(.top, 8)
                        }
                        if let line = store.itemLines[item.threadId], item.live || item.kind == "drop" {
                            Text(line).font(COSType.body(12)).foregroundStyle(TodayInk.hot).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                        }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(minWidth: isMoving ? 440 : 0, alignment: .leading)
            .background(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 6, bottomTrailingRadius: 18, topTrailingRadius: 18, style: .continuous).fill(TodayInk.panel))
            .overlay(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 6, bottomTrailingRadius: 18, topTrailingRadius: 18, style: .continuous).stroke(TodayInk.panelBorder, lineWidth: 1))
        }
        .frame(maxWidth: isMoving ? 640 : 600, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(item.id)
    }

    /// The one question's answers: numbered rows, the server's labels with each choice's detail when the drop is known.
    private func choices(_ item: DropIt.Item, busy: Bool) -> some View {
        let known = store.drops[item.threadId]?.choices ?? []
        let rows = item.actions.filter(\.isChoice)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, action in
                let detail = known.first { "choose:" + $0.id == action.id }?.detail ?? ""
                Button { Task { await store.choose(item, action) } } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)").font(COSType.body(12.5, weight: .medium)).foregroundStyle(TodayInk.ink)
                            .frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 7).stroke(TodayInk.btnBorder, lineWidth: 1))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.label).font(COSType.body(13.5, weight: .semibold)).foregroundStyle(TodayInk.ink)
                            if !detail.isEmpty { Text(detail).font(COSType.body(12.5)).foregroundStyle(TodayInk.sub).fixedSize(horizontal: false, vertical: true) }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityLabel("Answer \(index + 1): \(action.label)")
            }
        }
        .padding(.top, 6)
        .task(id: item.threadId) { await store.loadDrop(item.threadId) }
    }

    private func act(_ item: DropIt.Item, _ action: DropIt.Action) {
        switch action.id {
        case "undo": Task { await store.undo(item) }
        case "move":
            moving = item.threadId; movePick = nil; moveSearch = ""
            Task { await store.loadDrop(item.threadId); await hooks.loadMoveOptions() }
        default:
            if action.isChoice { Task { await store.choose(item, action) } } else { onOpen(item, action) }
        }
    }

    // MARK: Move, inline under the receipt

    private func moveBox(_ item: DropIt.Item, busy: Bool) -> some View {
        let drop = store.drops[item.threadId]
        let places = DropIt.destinations(domains: hooks.domains(), threads: hooks.threads(), search: moveSearch)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(DropIt.moveTitle).font(COSType.body(13.5, weight: .semibold)).foregroundStyle(TodayInk.ink)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(TodayInk.grey)
                    TextField(DropIt.moveFind, text: $moveSearch).textFieldStyle(.plain).font(COSType.body(12.5))
                }
                .padding(.horizontal, 10).padding(.vertical, 6).frame(width: 200)
                .background(RoundedRectangle(cornerRadius: 8).fill(TodayInk.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(TodayInk.panelBorder, lineWidth: 1))
            }
            .padding(14)
            ForEach(places) { place in
                let current = DropIt.isCurrent(place, drop: drop)
                let picked = movePick == place.id
                Button { if !current { movePick = place.id } } label: {
                    HStack(spacing: 12) {
                        Circle().stroke(picked ? TodayInk.accent : TodayInk.btnBorder, lineWidth: 1.5).frame(width: 16, height: 16)
                            .overlay(Circle().fill(TodayInk.accent).frame(width: 8, height: 8).opacity(picked ? 1 : 0))
                        DropItGlyph(glyph: place.glyph, size: 26)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(place.title).font(COSType.body(13.5, weight: .semibold)).foregroundStyle(TodayInk.ink).lineLimit(1)
                            if !place.detail.isEmpty { Text(current ? "where it is now" : place.detail).font(COSType.body(12.5)).foregroundStyle(TodayInk.sub).lineLimit(1) }
                        }
                        Spacer(minLength: 8)
                        if current { Text("Here now").font(COSType.body(12)).foregroundStyle(TodayInk.sub) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(picked ? TodayInk.qopen : Color.clear)
                    .overlay(alignment: .leading) { if picked { Rectangle().fill(TodayInk.accent).frame(width: 3) } }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(current || busy)
            }
            Divider().padding(.top, 4)
            HStack(spacing: 10) {
                Button(DropIt.moveHere) {
                    guard let pick = places.first(where: { $0.id == movePick }) else { return }
                    Task { if await store.move(thread: item.threadId, to: pick) { moving = nil } }
                }
                .buttonStyle(TodayButtonStyle(primary: true, small: true)).disabled(movePick == nil || busy)
                Button(DropIt.moveCancel) { moving = nil }.buttonStyle(TodayButtonStyle(small: true))
                Text(DropIt.moveNote).font(COSType.body(12)).foregroundStyle(TodayInk.sub).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(TodayInk.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(TodayInk.panelBorder, lineWidth: 1))
        .padding(.top, 10)
    }

    // MARK: The composer: Ask and Drop (0.5.371 option A), with attachments

    /// The approved mock's row A: the box with the words and two buttons, Ask (filled) and Drop (outlined). The whole box is the
    /// drop target for files, as a meeting's Files box is (MeetingFilesDrop, on the box, never an overlay), and the text view is
    /// the meeting composer's (MeetingAskComposer), so a file dropped or pasted on the words becomes an attachment and never its
    /// path as text. Add and Paste sit under the box and never collapse away.
    private var composer: some View {
        let askReady = DropIt.askBlock(text: draft, files: store.attachments) == nil && !store.asking && !store.sending
        let dropReady = DropIt.cleaned(draft) != nil && !store.asking && !store.sending
        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 8) {
                if !store.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(store.attachments) { file in DropItFileChip(file: file, remove: { store.removeAttachment(file.id) }, retry: { store.retryAttachment(file.id) }) }
                        }
                        .padding(.vertical, 2)
                    }
                }
                HStack(alignment: .center, spacing: 8) {
                    MeetingAskComposer(text: $draft, placeholder: DropIt.placeholder, onSubmit: ask,
                                       onAttach: { attachment in Task { await DropItIntake.take(attachment, store: store) } },
                                       onOptionSubmit: drop, fontSize: 14)
                        .padding(.vertical, 7)
                        .accessibilityLabel("Message to COS")
                    if hooks.dictationOn {
                        Button(action: hooks.dictate) {
                            Image(systemName: "mic").font(.system(size: 14)).foregroundStyle(TodayInk.grey).frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain).help(DropIt.dictateHelp).accessibilityLabel(DropIt.dictateHelp)
                    }
                    Button(store.asking ? DropIt.askingLine : DropIt.askLabel, action: ask)
                        .buttonStyle(DropItComposerButtonStyle(filled: true, ready: askReady))
                        .disabled(!askReady)
                        .help("Return")
                    Button(store.sending ? DropIt.sendingLine : DropIt.dropLabel, action: drop)
                        .buttonStyle(DropItComposerButtonStyle(filled: false, ready: dropReady))
                        .disabled(!dropReady)
                        .help("Option-Return")
                }
            }
            .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(dropTargeted ? TodayInk.qopen : TodayInk.panel))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(dropTargeted ? TodayInk.accent : TodayInk.btnBorder, lineWidth: dropTargeted ? 1.5 : 1))
            .overlay {
                if dropTargeted {
                    Label(DropIt.dropZoneTarget, systemImage: "paperclip").font(COSType.body(13, weight: .semibold)).foregroundStyle(TodayInk.accent)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(TodayInk.panel))
                        .allowsHitTesting(false)
                }
            }
            // Files only, on the box itself (an overlay drop destination never fires, 0.5.246).
            .modifier(MeetingFilesDrop(enabled: true, targeted: $dropTargeted) { providers in
                Task { await DropItIntake.take(.providers(providers), store: store) }
            })
            if let line = store.line, store.loaded || !store.attachments.isEmpty {
                Text(line).font(COSType.body(12)).foregroundStyle(TodayInk.hot).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button { addFiles() } label: { Label(DropIt.addLabel, systemImage: "paperclip") }
                    .buttonStyle(TodayLinkStyle(color: TodayInk.grey, size: 12))
                    .help(DropIt.attachHelp).accessibilityLabel(DropIt.attachHelp)
                    .disabled(store.attachments.count >= DropIt.maxAttachments)
                Button { Task { await DropItIntake.paste(NSPasteboard.general, store: store) } } label: { Label(DropIt.pasteLabel, systemImage: "doc.on.clipboard") }
                    .buttonStyle(TodayLinkStyle(color: TodayInk.grey, size: 12))
                    .disabled(store.attachments.count >= DropIt.maxAttachments)
                Text(DropIt.footReturn)
                Spacer(minLength: 12)
                Text(DropIt.footNothingOut)
            }
            .lineLimit(1)
            .font(COSType.body(11.5)).foregroundStyle(TodayInk.grey).padding(.horizontal, 4)
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background(TodayInk.page)
        .overlay(alignment: .top) { Rectangle().fill(TodayInk.rowBorder).frame(height: 1) }
    }

    /// Return: Ask, with the files.
    private func ask() {
        // store.ask says why when the files are not up yet; an empty box does nothing.
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !store.asking, !store.sending else { return }
        let words = draft
        Task {
            // The box keeps the words until the run has started.
            if await store.ask(words), draft == words { draft = "" }
        }
    }

    /// Option-Return: Drop. With files, only on a server that takes them (store.send says why not).
    private func drop() {
        guard DropIt.cleaned(draft) != nil, !store.sending, !store.asking else { return }
        let words = draft
        Task {
            // The box keeps the words until the server has them.
            if await store.send(words) != nil, draft == words { draft = "" }
        }
    }

    /// Add: files, several at once, from the open panel. Dragging is never required.
    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.prompt = "Attach"; panel.message = "Choose photos, video, PDFs or documents to send with your message."
        guard panel.runModal() == .OK else { return }
        store.attach(panel.urls.map { ($0, $0.lastPathComponent) })
    }

    // MARK: This Mac's Asks

    /// His words with the files he sent, then COS's answer as it comes in.
    private func askRows(_ item: DropIt.Item) -> some View {
        let ask = store.asks.first { $0.id == item.threadId }
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.line).font(COSType.body(14.5)).foregroundStyle(DropInk.youInk)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6, topTrailingRadius: 18, style: .continuous).fill(DropInk.youBg))
                    .overlay(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6, topTrailingRadius: 18, style: .continuous).stroke(DropInk.youBorder, lineWidth: 1))
                if let files = ask?.files, !files.isEmpty {
                    HStack(spacing: 6) { ForEach(Array(files.enumerated()), id: \.offset) { _, file in DropItSentFile(name: file.name, kind: file.kind, thumb: file.thumb) } }
                }
                Text(DropIt.askSource).font(COSType.body(11.5)).foregroundStyle(DropInk.tertiary).padding(.trailing, 4)
            }
            .frame(maxWidth: 560, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            if let ask {
                HStack(alignment: .bottom, spacing: 10) {
                    DropItAvatar(size: 30).padding(.bottom, 18)
                    HStack(alignment: .top, spacing: 11) {
                        DropItGlyph(glyph: .answer)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(DropIt.askTitle(ask)).font(COSType.body(14, weight: .semibold)).foregroundStyle(TodayInk.ink)
                                Text(askStateWord(ask)).font(COSType.body(12)).foregroundStyle(TodayInk.sub)
                            }
                            if ["failed", "refused", "canceled"].contains(ask.status) {
                                Text(DropIt.askFailedLine).font(COSType.body(13)).foregroundStyle(TodayInk.hot).fixedSize(horizontal: false, vertical: true)
                            } else if let answer = ask.answer, !answer.isEmpty {
                                COSMarkdownView(text: answer).font(COSType.body(13.5)).foregroundStyle(TodayInk.ink).textSelection(.enabled)
                            } else {
                                Text(DropIt.askWaiting).font(COSType.body(13)).foregroundStyle(TodayInk.sub)
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 6, bottomTrailingRadius: 18, topTrailingRadius: 18, style: .continuous).fill(TodayInk.panel))
                    .overlay(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 6, bottomTrailingRadius: 18, topTrailingRadius: 18, style: .continuous).stroke(TodayInk.panelBorder, lineWidth: 1))
                }
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .id(item.id)
    }

    private func askStateWord(_ ask: DropIt.Ask) -> String {
        switch ask.status {
        case "completed", "delivered", "reviewed": "Answered"
        case "failed", "refused", "canceled": "Did not finish"
        default: "Answering"
        }
    }
}

/// One file on the composer: its thumbnail or kind, its name and state, Retry when it failed, and Remove.
struct DropItFileChip: View {
    let file: DropIt.Attachment
    let remove: () -> Void
    let retry: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            DropItFileThumb(kind: file.kind, thumb: file.thumb, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).font(COSType.body(12, weight: .medium)).foregroundStyle(TodayInk.ink).lineLimit(1).truncationMode(.middle)
                Text(file.meta).font(COSType.body(11)).foregroundStyle(file.state == .failed ? TodayInk.hot : TodayInk.sub).lineLimit(1)
            }
            .frame(maxWidth: 170, alignment: .leading)
            if file.busy { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14) }
            if file.state == .failed { Button("Retry", action: retry).buttonStyle(TodayLinkStyle(size: 12)) }
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(TodayInk.grey).frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Remove " + file.name).accessibilityLabel("Remove " + file.name)
        }
        .padding(.leading, 6).padding(.trailing, 4).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(TodayInk.page))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(file.state == .failed ? TodayInk.hotBorder : TodayInk.panelBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// A photo's own thumbnail, else the kind's symbol.
struct DropItFileThumb: View {
    let kind: DropIt.FileKind
    let thumb: URL?
    var size: CGFloat = 32
    var body: some View {
        Group {
            if let thumb, let image = NSImage(contentsOf: thumb) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: kind == .photo ? "photo" : kind == .video ? "film" : "doc.text")
                    .font(.system(size: size * 0.42)).foregroundStyle(TodayInk.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(TodayInk.qopen)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A file under his sent words.
struct DropItSentFile: View {
    let name: String
    let kind: DropIt.FileKind
    let thumb: URL?
    var body: some View {
        HStack(spacing: 6) {
            DropItFileThumb(kind: kind, thumb: thumb, size: 22)
            Text(name).font(COSType.body(11.5)).foregroundStyle(TodayInk.sub).lineLimit(1).truncationMode(.middle).frame(maxWidth: 150, alignment: .leading)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(TodayInk.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(TodayInk.panelBorder, lineWidth: 1))
        .accessibilityLabel("Attached " + name)
    }
}

/// What the composer is handed, read the meeting Files way: Finder files as they are, a screenshot or image as a PNG, and a
/// drop's providers through the meeting's own staging (WorkCardFileStore.stage), so a screenshot thumbnail, a Photos or Mail
/// promise and image data all arrive as files. A link is words, not a file.
@MainActor enum DropItIntake {
    static func take(_ attachment: MeetingAskAttachment, store: DropItStore) async {
        switch attachment {
        case .files(let urls): store.attach(urls.map { ($0, $0.lastPathComponent) })
        case .image(let data):
            guard let png = WorkCardFileStore.pngData(data) else { store.line = DropIt.nothingToPasteLine; return }
            store.attachImage(png)
        case .providers(let providers):
            var incoming: [DropIt.Incoming] = []
            var refusals: [String] = []
            let folder = store.stagingRoot
            for (ordinal, provider) in providers.enumerated() {
                let staged = await WorkCardFileStore.stage(provider, policy: .meeting, ordinal: ordinal, count: providers.count) {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    return folder
                }
                switch staged {
                case .finder(let url): incoming.append(DropIt.Incoming(url: url, name: url.lastPathComponent, owned: false))
                case .copy(let url, let display, _): incoming.append(DropIt.Incoming(url: url, name: display, owned: true))
                case .web: refusals.append(DropIt.linkNotFileLine)
                case .refused(let refusal): refusals.append(refusal.message)
                }
            }
            store.attach(incoming, refusals: refusals)
        }
    }

    /// Paste: Finder files as files, else a copied screenshot or image.
    static func paste(_ pasteboard: NSPasteboard, store: DropItStore) async {
        let payload = WorkCardFileStore.meetingPastePayload(pasteboard)
        if !payload.urls.isEmpty { await take(.files(payload.urls), store: store); return }
        guard let image = payload.image else { store.line = DropIt.nothingToPasteLine; return }
        await take(.image(image), store: store)
    }
}

/// The composer's two buttons: Ask filled with the accent, Drop outlined in it; both quiet until they can go.
struct DropItComposerButtonStyle: ButtonStyle {
    let filled: Bool
    let ready: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(COSType.body(13.5, weight: .semibold))
            .foregroundStyle(ready ? (filled ? TodayInk.onAccent : TodayInk.accent) : DropInk.tertiary)
            .padding(.horizontal, 14).frame(minHeight: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(filled && ready ? TodayInk.accent : filled ? TodayInk.btnBg : TodayInk.panel))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(ready ? TodayInk.accent : TodayInk.kbdBorder, lineWidth: filled ? 1 : 1.5))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: History

struct DropItHistoryPane: View {
    @ObservedObject var store: DropItStore
    let onBack: () -> Void
    /// Open where a drop lives (its first link), as the chat's open actions do.
    let onOpen: (DropIt.Drop) -> Void
    var now: Date = Date()
    @State private var query = ""
    @State private var kind = ""
    @State private var status = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(ActivitySection.messages.tint.opacity(0.14)).frame(width: 42, height: 42)
                    .overlay(Image(systemName: "clock").font(.system(size: 19)).foregroundStyle(ActivitySection.messages.tint)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(DropIt.historyTitle).font(COSType.display(26, weight: .medium)).foregroundStyle(TodayInk.ink)
                    Text(DropIt.historyLine).font(COSType.body(13)).foregroundStyle(TodayInk.sub).lineLimit(2)
                }
                Spacer(minLength: 12)
                Button(DropIt.backToChat, action: onBack).buttonStyle(TodayLinkStyle(size: 13))
            }
            .padding(.horizontal, 28).padding(.vertical, 16)
            .background(TodayInk.rail.opacity(0.6))
            Divider()
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(TodayInk.grey)
                    TextField(DropIt.historySearch, text: $query).textFieldStyle(.plain).font(COSType.body(13))
                }
                .padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: 360)
                .background(RoundedRectangle(cornerRadius: 9).fill(TodayInk.panel))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(TodayInk.panelBorder, lineWidth: 1))
                Spacer(minLength: 8)
                COSDropdown("Status", selection: $status, options: DropIt.historyStatuses.map { COSDropdownOption($0.value ?? "", $0.title) }, showsLabel: true)
                    .fixedSize()
            }
            .padding(.horizontal, 28).padding(.top, 14)
            COSViewSwitch("Kind", selection: $kind, options: DropIt.historyKinds.map { COSViewOption($0.value ?? "", $0.title) })
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    table
                    if let line = store.historyLine {
                        Text(line).font(COSType.body(12)).foregroundStyle(TodayInk.hot)
                    } else if !store.history.isEmpty {
                        Text(DropIt.historyFoot).font(COSType.body(12)).foregroundStyle(TodayInk.grey)
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 24)
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .background(TodayInk.page)
        .task(id: query + "|" + kind + "|" + status) {
            // Words wait for a pause in typing; a kind or status change reads at once.
            if !query.isEmpty { try? await Task.sleep(nanoseconds: 300_000_000) }
            if Task.isCancelled { return }
            await store.loadHistory(query: query, kind: kind.isEmpty ? nil : kind, status: status.isEmpty ? nil : status)
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("What you said").frame(maxWidth: .infinity, alignment: .leading)
                Text("When").frame(width: 132, alignment: .leading)
                Text("Where it went").frame(minWidth: 120, maxWidth: 230, alignment: .leading)
                Text("Status").frame(width: 100, alignment: .leading)
                Color.clear.frame(width: 40)
            }
            .font(COSType.body(12)).foregroundStyle(TodayInk.sub)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(TodayInk.qopen)
            if store.history.isEmpty {
                Text(store.historyLoading ? "Loading…" : (query.isEmpty && kind.isEmpty && status.isEmpty ? DropIt.historyEmpty : DropIt.historyMiss))
                    .font(COSType.body(13)).foregroundStyle(TodayInk.grey)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            ForEach(store.history) { drop in
                Rectangle().fill(TodayInk.rowBorder).frame(height: 1)
                row(drop)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(TodayInk.panel))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(TodayInk.panelBorder, lineWidth: 1))
    }

    private func row(_ drop: DropIt.Drop) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\u{201C}" + drop.text.replacingOccurrences(of: "\n", with: " ") + "\u{201D}").font(COSType.display(14.5, italic: true)).foregroundStyle(TodayInk.ink)
                    .lineLimit(1).truncationMode(.tail)
                Text(DropIt.kindLine(drop)).font(COSType.body(11.5)).foregroundStyle(DropInk.tertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(DropIt.rowTime(drop.createdAt, now: now)).font(COSType.mono(11.5)).foregroundStyle(TodayInk.sub).frame(width: 132, alignment: .leading)
            HStack(spacing: 9) {
                DropItGlyph(glyph: DropIt.glyph(for: drop), size: 24)
                Text(DropIt.whereItWent(drop)).font(COSType.body(13)).foregroundStyle(TodayInk.ink).lineLimit(1).truncationMode(.tail)
            }
            .frame(minWidth: 120, maxWidth: 230, alignment: .leading)
            HStack(spacing: 7) {
                Circle().fill(statusColor(drop.status)).frame(width: 7, height: 7)
                    .overlay(Circle().stroke(DropInk.tertiary, lineWidth: drop.status == "undone" ? 1.2 : 0))
                Text(DropIt.statusTitle(drop.status)).font(COSType.body(13)).foregroundStyle(drop.status == "undone" ? DropInk.tertiary : (drop.status == "done" ? TodayInk.ok : TodayInk.ink))
            }
            .frame(width: 100, alignment: .leading)
            Button("Open") { onOpen(drop) }.buttonStyle(TodayLinkStyle(size: 12.5)).frame(width: 40, alignment: .trailing)
                .disabled(drop.state == "undone" && drop.links.isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "done": TodayInk.ok
        case "in_progress": TodayInk.pulse
        case "undone": Color.clear
        default: TodayInk.hot
        }
    }
}

// MARK: Back to the chat

/// The strip a deep link from the chat leaves on the pane it opened, with the way back.
struct DropItCameBackStrip: View {
    let line: String
    let back: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Text(line).font(COSType.body(13)).foregroundStyle(TodayInk.sub).lineLimit(2)
            Spacer(minLength: 8)
            Button(DropIt.backToChatShort, action: back).buttonStyle(TodayLinkStyle(size: 13))
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(TodayInk.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(TodayInk.panelBorder, lineWidth: 1))
        .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 4)
    }
}

// MARK: Settings, Work and agents, Work chat: Drop it (DROP-01)

/// The one Drop it switch. Off by default on the server; this PUTs /api/drops/settings and the capability follows the answer.
/// With COS_DROP_IT set in the server's environment, the server says so and the row explains why the switch does not move.
struct DropItSettingRow: View {
    @ObservedObject var model: ControllerModel
    @ObservedObject var store: DropItStore

    var body: some View {
        let item = SettingsHubCatalog.item("DROP-01")
        let envDecides = model.status.dropIt.source == "env" || store.settings?.envDecides == true
        VStack(alignment: .leading, spacing: 0) {
            SettingsHubRow(label: item?.label ?? DropIt.settingLabel, detail: item?.detail ?? DropIt.settingDetail, anchor: "item.DROP-01") {
                Toggle(isOn: Binding(get: { model.status.dropIt.enabled }, set: { on in Task { await model.setDropItEnabled(on) } })) { EmptyView() }
                    .toggleStyle(COSSwitchStyle())
                    .accessibilityLabel(DropIt.settingLabel)
                    .disabled(store.settingsBusy || envDecides)
            }
            if let line = store.settingsLine ?? (envDecides ? DropIt.settingEnvLine : nil) {
                Text(line).font(COSType.body(12)).foregroundStyle(TodayInk.sub).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20).padding(.bottom, 12)
            }
        }
    }
}

// MARK: The Messages rail item's mark (0.5.371, plan section 12)

/// Beside "Messages" on the Today rail: a number for what COS is waiting on him to answer, a dot for unread only. Read from
/// GET /api/inbox/summary on the rail's own 30-second clock (no timer of its own). Nothing while Drop it is off or unsupported.
struct DropItRailMark: View {
    @ObservedObject var store: DropItStore
    let available: Bool
    var compact = false
    var body: some View {
        let mark = DropIt.railMark(store.summary, available: available)
        Group {
            switch mark {
            case .none: EmptyView()
            case .dot:
                Circle().fill(TodayInk.hot).frame(width: 7, height: 7)
                    .overlay(Circle().stroke(TodayInk.rail, lineWidth: compact ? 2 : 0))
            case .count(let n):
                Text(n > 99 ? "99+" : String(n))
                    .font(COSType.body(compact ? 10.5 : 14, weight: .semibold))
                    .foregroundStyle(compact ? TodayInk.panel : TodayInk.hot)
                    .padding(.horizontal, compact ? 4 : 0)
                    .frame(minWidth: compact ? 16 : nil, minHeight: compact ? 16 : nil)
                    .background(Capsule().fill(compact ? TodayInk.hot : Color.clear))
            }
        }
        .accessibilityLabel(DropIt.railMarkLabel(mark) ?? "")
        .accessibilityHidden(mark == .none)
    }
}
