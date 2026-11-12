import AppKit
import SwiftUI

/// Reply in the message reader (D4; asked for 2026-11-11 13:59, parity with the web). The Mac twin of Control Web's Reply
/// block (server 6.99.12, web-control/panes/cos-chat.js replyHtml), inline under the answer, in the web's words: "Reply",
/// the line saying whether it continues this conversation, a box labelled "Reply to Message #N", files (Add, Paste, drop),
/// Model, Effort only where the server serves efforts for that model's agent, and Ask. A reply is the same Today Work run as
/// the COS chat's Ask (POST /api/query-jobs) with the turn's session; its answer lands in Messages with its own number, and
/// this Mac's replies to this turn show above the box as they answer. It uses its own store (ControllerModel.messageReply),
/// so the COS chat's composer and its files are never touched.
struct MessageReplyBlock: View {
    @ObservedObject var store: DropItStore
    @ObservedObject var handoff: WorkHandoffStore
    let turn: GlassesTurn
    /// The window wires the store's run (wireMessageReply) and reads the models once.
    var onAppear: () -> Void = {}
    /// Off in the render harness: the 3-second read-back of answering replies, and the models read.
    var polls = true
    /// The renders' typed words (the box starts empty in the app).
    var initialDraft = ""
    /// Anand parity (lead 2026-11-12, as the web's reader): the Reply card is pinned under the reader's scroll (.composer),
    /// and this Mac's replies to the turn read in the scroll under the answer (.replies). .all is both in one card.
    enum Part { case all, replies, composer }
    var part: Part = .all
    /// Settings' "Work runs from Today" (TodayHome.workRunsOn): off, the card says so in place of the box (Q1 F3).
    var runsOn = true
    @AppStorage(MessageReply.modelKey) private var pickedModel = ""
    @AppStorage(MessageReply.effortKey) private var pickedEffort = ""
    @State private var draft = ""
    @State private var dropTargeted = false

    static let footReturn = "Return asks. Shift-Return starts a new line."

    /// Shown only where a reply can run: the server takes query jobs and Work has a model (the helper marks none available
    /// when durable query jobs are off), as Control Web shows it only while Ask is on (askOn).
    var body: some View {
        Group {
            if MessageReply.available(handoff.models.map { ($0.id, $0.available, $0.resolvedModel) }) {
                if part == .replies { repliesList } else { block }
            }
        }
        .onAppear {
            guard part != .replies else { return }
            onAppear()
            if draft.isEmpty, !initialDraft.isEmpty { draft = initialDraft }
        }
        .task {
            if polls, part != .replies, handoff.models.isEmpty { await handoff.refresh() }
        }
    }

    /// This Mac's replies to the turn, in the reader's scroll under the answer (part .replies); nothing when there are none.
    @ViewBuilder private var repliesList: some View {
        let replies = store.asks.filter { $0.replyTo == turn.id }
        if !replies.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(replies) { reply in replyRow(reply) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var block: some View {
        let label = MessageReply.label(no: turn.no)
        let replies = store.asks.filter { $0.replyTo == turn.id }
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(MessageReply.title)
                    .font(COSType.body(14, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(MessageReply.subline(sessionId: turn.sessionId))
                    .font(COSType.body(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if part == .all, !replies.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(replies) { reply in replyRow(reply) }
                }
            }
            if runsOn {
                composer(label: label)
            } else {
                Text(MessageReply.runsOffLine)
                    .font(COSType.body(12))
                    .foregroundStyle(TodayInk.hot)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(COSPalette.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(COSPalette.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        // A reply still answering is read back every 3 seconds, as the COS chat's Ask is.
        .task(id: replies.filter { !$0.finished }.count) {
            guard polls else { return }
            while !Task.isCancelled, store.asks.contains(where: { $0.replyTo == turn.id && !$0.finished }) {
                await store.refreshAsks()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    // MARK: A reply sent from this Mac

    /// Pick A (2026-11-12, sides): his reply right in the reader's bubble, captioned; the answer left by COS's mark.
    private func replyRow(_ reply: DropIt.Ask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ActivityMessageCard(label: "You", text: reply.words, tint: ActivitySection.messages.tint, side: .you,
                                caption: reply.files.isEmpty ? "Replied on this Mac"
                                    : "Replied on this Mac, with " + reply.files.map(\.name).joined(separator: ", "))
            HStack(alignment: .top, spacing: 10) {
            DropItAvatar(size: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(DropIt.askTitle(reply))
                        .font(COSType.body(11.5, weight: .semibold))
                    Text(Self.stateWord(reply))
                        .font(COSType.body(11.5))
                        .foregroundStyle(reply.status == "failed" || reply.status == "refused" || reply.status == "canceled" ? COSPalette.danger : Color.secondary)
                }
                if let answer = reply.answer, !answer.isEmpty {
                    Text(answer)
                        .font(COSType.body(13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
    }

    static func stateWord(_ reply: DropIt.Ask) -> String {
        switch reply.status {
        case "completed", "delivered", "reviewed": "Answered"
        case "failed", "refused", "canceled": "Did not finish"
        default: "Answering"
        }
    }

    // MARK: The composer

    private func composer(label: String) -> some View {
        let askReady = DropIt.askBlock(text: draft, files: store.attachments) == nil && !store.asking && !store.sending
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // The web's menu (MessageReply.menu): Claude Opus, Fable and Sonnet, then Codex, Cursor and Ollama while they can run.
        let menu = MessageReply.menu(handoff.models.map { ($0.id, $0.available, $0.resolvedModel) })
        let selected = MessageReply.model(picked: pickedModel.isEmpty ? nil : pickedModel, menu: menu)
        let provider = selected.flatMap { id in handoff.models.first { $0.id == id }?.provider }
        let efforts = provider.map { MessageReply.effortChoices(provider: $0, efforts: handoff.efforts) } ?? []
        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 8) {
                if !store.attachments.isEmpty || dropTargeted {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(store.attachments) { file in
                                DropItFileChip(file: file, remove: { store.removeAttachment(file.id) }, retry: { store.retryAttachment(file.id) })
                            }
                            if dropTargeted { DropItDropSlot() }
                        }
                        .padding(.vertical, 2)
                    }
                }
                HStack(alignment: .center, spacing: 8) {
                    MeetingAskComposer(text: $draft, placeholder: label, onSubmit: ask,
                                       onAttach: { attachment in Task { await DropItIntake.take(attachment, store: store) } },
                                       fontSize: 13.5)
                        .padding(.vertical, 6)
                        .accessibilityLabel(label)
                    Button(store.asking ? DropIt.askingLine : DropIt.askLabel, action: ask)
                        .buttonStyle(DropItComposerButtonStyle(filled: true, ready: askReady))
                        .disabled(!askReady)
                        .help("Return")
                }
            }
            .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(dropTargeted ? TodayInk.qopen : TodayInk.panel))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(dropTargeted ? TodayInk.accent : TodayInk.btnBorder, lineWidth: dropTargeted ? 1.5 : 1))
            // Files only, on the box itself, as the COS chat's box takes them.
            .modifier(MeetingFilesDrop(enabled: true, targeted: $dropTargeted) { providers in
                Task { await DropItIntake.take(.providers(providers), store: store) }
            })
            if let line = store.line {
                Text(line).font(COSType.body(12)).foregroundStyle(TodayInk.hot).fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    fileButtons
                    Spacer(minLength: 8)
                    pickers(menu: menu, selected: selected, efforts: efforts)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) { fileButtons; Spacer(minLength: 0) }
                    HStack(spacing: 10) { pickers(menu: menu, selected: selected, efforts: efforts); Spacer(minLength: 0) }
                }
            }
            Text(Self.footReturn)
                .font(COSType.body(11)).foregroundStyle(TodayInk.grey).padding(.horizontal, 4)
        }
        .onChange(of: provider) { _, _ in
            // An effort the new model's agent does not offer is not kept.
            if !pickedEffort.isEmpty, !efforts.contains(where: { $0.value == pickedEffort }) { pickedEffort = "" }
        }
    }

    private var fileButtons: some View {
        HStack(spacing: 10) {
            Button { addFiles() } label: { Label(DropIt.addLabel, systemImage: "paperclip") }
                .buttonStyle(TodayLinkStyle(color: TodayInk.grey, size: 12))
                .help(DropIt.attachHelp).accessibilityLabel(DropIt.attachHelp)
                .disabled(store.attachments.count >= DropIt.maxAttachments)
            Button { Task { await DropItIntake.paste(NSPasteboard.general, store: store) } } label: { Label(DropIt.pasteLabel, systemImage: "doc.on.clipboard") }
                .buttonStyle(TodayLinkStyle(color: TodayInk.grey, size: 12))
                .disabled(store.attachments.count >= DropIt.maxAttachments)
        }
        .lineLimit(1)
    }

    /// Model, always (the web's menu); Effort only when the server serves efforts for the chosen model's agent.
    @ViewBuilder
    private func pickers(menu: [MessageReply.Choice], selected: String?, efforts: [WorkEffortChoice]) -> some View {
        if let selected, !menu.isEmpty {
            COSDropdown("Model", selection: Binding(get: { selected }, set: { pickedModel = $0 }),
                        options: menu.map { COSDropdownOption($0.id, $0.label) })
            .fixedSize()
            .accessibilityLabel("Model for Ask")
        }
        if !efforts.isEmpty {
            COSDropdown("Effort", selection: $pickedEffort,
                        options: [COSDropdownOption("", "Default")] + efforts.map { COSDropdownOption($0.value, $0.label) })
            .fixedSize()
            .accessibilityLabel("Effort for Ask")
        }
    }

    // MARK: Actions

    /// Return: the reply, with the files. The box keeps the words until the run has started.
    private func ask() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !store.asking, !store.sending else { return }
        let words = draft
        Task {
            if await store.reply(words, to: turn.id, session: MessageReply.session(turn.sessionId)), draft == words { draft = "" }
        }
    }

    /// Add: files, several at once, from the open panel.
    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.prompt = "Attach"; panel.message = "Choose photos, video, PDFs or documents to send with your reply."
        guard panel.runModal() == .OK else { return }
        store.attach(panel.urls.map { ($0, $0.lastPathComponent) })
    }
}
