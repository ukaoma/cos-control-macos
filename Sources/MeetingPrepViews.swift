import SwiftUI
import AppKit

/// Messages can host Prep even when the optional Drop It chat is disabled.
struct DetachedMeetingPrepPane: View {
    @ObservedObject var store: MeetingPrepStore
    let ordinary: DropItStore
    let wireAsk: () -> Void
    @Binding var showDrafts: Bool
    @State private var remoteDrafts: [MeetingPrep.Draft] = []
    @State private var loadingDrafts = false
    @State private var draftsError: String?

    var body: some View {
        Group {
            if store.isOpen {
                ScrollView {
                    MeetingPrepComposer(store: store, close: close)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(TodayInk.page)
            } else if store.launch != nil {
                VStack(spacing: 12) {
                    ProgressView("Opening meeting prep…")
                    Button("Close", action: close).buttonStyle(TodayLinkStyle(size: 12))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(TodayInk.page)
            } else if showDrafts {
                draftPicker
            }
        }
        .task(id: store.launch?.id) {
            guard let launch = store.launch, !store.isOpen, !Task.isCancelled else { return }
            wireAsk()
            await store.open(launch, ordinary: .init(text: ordinary.composerDraft, attachments: ordinary.attachments))
        }
    }

    private func close() {
        if let draft = store.close() { ordinary.composerDraft = draft.text }
    }

    private var draftPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Prep drafts").font(COSType.body(16, weight: .semibold))
                    Spacer()
                    Button("Close", action: { showDrafts = false }).buttonStyle(TodayLinkStyle(size: 12))
                }
                let local = store.recoveryDrafts
                let remote = remoteDrafts.filter { draft in !local.contains { $0.id == draft.clientDraftId } }
                ForEach(local) { saved in
                    let state = saved.pending != nil ? " · Request pending" : (saved.files.isEmpty ? "" : " · Files waiting")
                    Button(draftLabel(saved.title, startsAt: saved.startsAt) + state) {
                        store.launch = .init(id: saved.id, title: saved.title, startsAt: saved.startsAt, resume: saved.draft)
                    }.buttonStyle(TodayLinkStyle(size: 12))
                }
                ForEach(remote) { draft in
                    Button(draftLabel(draft.title, startsAt: draft.startsAt)) {
                        store.launch = .init(id: draft.clientDraftId, title: draft.title, startsAt: draft.startsAt, resume: draft)
                    }.buttonStyle(TodayLinkStyle(size: 12))
                }
                if loadingDrafts {
                    ProgressView("Reading Prep drafts…").controlSize(.small)
                } else if let draftsError {
                    Text(draftsError).font(COSType.body(12)).foregroundStyle(COSPalette.amber)
                } else if local.isEmpty, remote.isEmpty {
                    Text("No saved Prep drafts.").font(COSType.body(12)).foregroundStyle(.secondary)
                }
            }
            .padding(18).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(TodayInk.page)
        .task {
            loadingDrafts = true; draftsError = nil; remoteDrafts = []
            defer { loadingDrafts = false }
            do {
                let drafts = try await store.availableDrafts()
                if !Task.isCancelled { remoteDrafts = drafts }
            }
            catch { if !Task.isCancelled { draftsError = error.localizedDescription } }
        }
    }

    private func draftLabel(_ title: String, startsAt: String?) -> String {
        guard let startsAt else { return title }
        let date = DropIt.date(.string(startsAt))?.formatted(date: .abbreviated, time: .shortened) ?? startsAt
        return title + " · " + date
    }
}

/// The normal chat composer stays mounted separately; Prep owns its own words and attachment store.
struct MeetingPrepComposer: View {
    @ObservedObject var store: MeetingPrepStore
    @ObservedObject private var uploads: DropItStore
    var close: () -> Void
    @State private var targeted = false
    init(store: MeetingPrepStore, close: @escaping () -> Void) {
        self.store = store; self.close = close
        _uploads = ObservedObject(wrappedValue: store.uploads)
    }
    var body: some View {
        let attachmentIDs = Set(uploads.attachments.map(\.id))
        let recovered = store.queuedFiles.filter { !attachmentIDs.contains($0.sourceRef) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.active?.title ?? store.launch?.title ?? "Meeting prep").font(COSType.body(16, weight: .semibold))
                    if let time = store.active?.startsAt ?? store.launch?.startsAt {
                        Text(time).font(COSType.body(12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Back to Ask", action: close).buttonStyle(TodayLinkStyle(size: 12))
            }
            Text(store.supported ? "Add context and files, then choose Prep. Nothing is added to a recording until you choose Add prep in that live meeting."
                 : "Plain Ask: context and files go with this question. This server cannot keep Prep with a recording.")
                .font(COSType.body(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let draft = store.active, !draft.currentFiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(draft.currentFiles) { file in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name).font(COSType.body(12, weight: .medium))
                                Text(file.notice ?? (file.status == "ready" ? "Saved in Prep" : file.status.replacingOccurrences(of: "-", with: " ")))
                                    .font(COSType.body(11)).foregroundStyle(file.status == "ready" ? Color.secondary : COSPalette.amber)
                            }
                            Spacer()
                            MeetingPrepDownloadButton(store: store, draft: draft, file: file)
                            Button("Remove") { Task { await store.removeFile(file) } }.buttonStyle(TodayLinkStyle(size: 11)).disabled(store.busy)
                        }
                    }
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(TodayInk.qopen))
            }
            if !uploads.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(uploads.attachments) { file in
                            DropItFileChip(file: file, remove: { store.removeQueuedFile(sourceRef: file.id) },
                                           retry: { uploads.retryAttachment(file.id) })
                                .disabled(store.busy || store.pending != nil)
                        }
                    }
                }
            }
            if !recovered.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(recovered, id: \.sourceRef) { file in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name).font(COSType.body(12, weight: .medium))
                                Text("Waiting to be saved in Prep").font(COSType.body(11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove") { store.removeQueuedFile(sourceRef: file.sourceRef) }
                                .buttonStyle(TodayLinkStyle(size: 11)).disabled(store.busy || store.pending != nil)
                                .accessibilityLabel("Remove " + file.name)
                        }
                    }
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(TodayInk.qopen))
            }
            MeetingAskComposer(text: Binding(get: { store.text }, set: { store.setText($0) }),
                               placeholder: "What should COS know before this call?", onSubmit: send,
                               onAttach: { attachment in Task { await DropItIntake.take(attachment, store: uploads) } }, fontSize: 14)
                .frame(minHeight: 62, maxHeight: 150)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(TodayInk.panel))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(targeted ? TodayInk.accent : TodayInk.btnBorder, lineWidth: 1))
                .disabled(store.busy || store.pending != nil)
                .modifier(MeetingFilesDrop(enabled: !store.busy && store.pending == nil, targeted: $targeted) { providers in
                    Task { await DropItIntake.take(.providers(providers), store: uploads) }
                })
            HStack(spacing: 12) {
                Button { addFiles() } label: { Label("Add files", systemImage: "paperclip") }.buttonStyle(TodayLinkStyle(size: 12))
                    .disabled(store.busy || store.pending != nil || (store.supported && store.active == nil))
                Button { Task { await DropItIntake.paste(NSPasteboard.general, store: uploads) } } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .buttonStyle(TodayLinkStyle(size: 12)).disabled(store.busy || store.pending != nil || (store.supported && store.active == nil))
                Spacer()
                if store.supported {
                    Button("Save notes") { Task { _ = await store.saveNotes() } }.buttonStyle(TodayButtonStyle(small: true)).disabled(store.busy || store.pending != nil)
                }
                Button(store.busy ? "Working…" : (store.supported ? "Prep" : "Ask"), action: send)
                    .buttonStyle(TodayButtonStyle(primary: true, small: true))
                    .disabled(!store.canSend || (store.supported && (!uploads.attachments.isEmpty || store.hasQueuedFiles || store.active == nil)))
            }
            if store.supported, !uploads.attachments.isEmpty || store.hasQueuedFiles {
                Button("Save uploaded files to Prep") { Task { await store.saveUploadedFiles() } }
                    .buttonStyle(TodayLinkStyle(size: 12))
                    .disabled(store.busy || store.pending != nil || uploads.attachments.contains(where: \.busy))
            }
            if let line = store.notice ?? store.flow.presentation?.notice ?? uploads.line {
                Text(line).font(COSType.body(12)).foregroundStyle(COSPalette.amber).fixedSize(horizontal: false, vertical: true)
            }
            if store.pending != nil {
                HStack {
                    Text(store.jobState ?? "Waiting for confirmation").font(COSType.body(12)).foregroundStyle(.secondary)
                    Button("Check request") { Task { await store.checkRequest() } }.buttonStyle(TodayLinkStyle(size: 12)).disabled(store.busy)
                    if store.canRetryRequest {
                        Button("Retry request") { Task { await store.retryRequest() } }.buttonStyle(TodayLinkStyle(size: 12)).disabled(store.busy)
                    }
                }
            } else if store.supported, store.active != nil {
                Button("Refresh saved version") { Task { await store.refreshDraft() } }.buttonStyle(TodayLinkStyle(size: 12)).disabled(store.busy)
            }
            if !store.partialText.isEmpty, store.answer?.isEmpty != false {
                Text("Working draft").font(COSType.body(11, weight: .semibold)).foregroundStyle(.secondary)
                ScrollView { COSMarkdownView(text: store.partialText, bodySize: 13).padding(8) }.frame(maxHeight: 180)
            }
            if let answer = store.answer, !answer.isEmpty {
                ScrollView { COSMarkdownView(text: answer, bodySize: 13).padding(8) }.frame(maxHeight: 260)
            }
        }
        .padding(18).frame(maxWidth: 760).frame(maxWidth: .infinity)
        .background(TodayInk.page)
        .task(id: store.pending?.clientRequestId) {
            while !Task.isCancelled, store.pending != nil {
                await store.checkRequest()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
    private func send() {
        Task {
            if store.supported { await store.send() }
            else if await store.sendPlainAsk() { close() }
        }
    }
    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.prompt = "Add to Prep"
        guard panel.runModal() == .OK else { return }
        uploads.attach(panel.urls.map { ($0, $0.lastPathComponent) })
    }
}

struct MeetingPrepDownloadButton: View {
    @ObservedObject var store: MeetingPrepStore
    let draft: MeetingPrep.Draft
    let file: MeetingPrep.File
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Button(busy ? "Downloading…" : "Save original") {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = URL(fileURLWithPath: file.name).lastPathComponent
                guard panel.runModal() == .OK, let destination = panel.url else { return }
                busy = true; error = nil
                Task {
                    defer { busy = false }
                    do {
                        let original = try await store.download(file, draft: draft)
                        defer { try? FileManager.default.removeItem(at: original) }
                        try Data(contentsOf: original).write(to: destination, options: .atomic)
                    } catch { self.error = error.localizedDescription }
                }
            }.buttonStyle(TodayLinkStyle(size: 11)).disabled(busy)
            if let error { Text(error).font(COSType.body(11)).foregroundStyle(COSPalette.amber) }
        }
    }
}

/// Reads are suggestions only. The Add button names the exact currently selected recording.
struct MeetingPrepMeetingSection: View {
    @ObservedObject var store: MeetingPrepStore
    let session: String
    let title: String
    var startedAt: Date?
    var live = false
    private struct Target: Hashable {
        let session: String
        let startedAt: Date?
        let live: Bool
    }
    private var target: Target { .init(session: session, startedAt: startedAt, live: live) }
    @State private var activeTarget: Target?
    @State private var bound: [MeetingPrep.SessionSnapshot] = []
    @State private var generation = UUID()
    @State private var suggestions: [MeetingPrep.Draft] = []
    @State private var otherDrafts: [MeetingPrep.Draft]?
    @State private var selected: MeetingPrep.Draft?
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        let requested = target
        let token = generation
        VStack(alignment: .leading, spacing: 8) {
            if activeTarget == requested, store.supported, live || !bound.isEmpty || error != nil {
                Text("Meeting prep").font(COSType.body(14, weight: .semibold))
                ForEach(bound) { snapshot in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(snapshot.title).font(COSType.body(12, weight: .medium))
                        Text("Revision \(snapshot.draftRevision) · " + snapshotStatus(snapshot))
                            .font(COSType.body(11)).foregroundStyle(.secondary)
                        if snapshot.held == true {
                            Text("Prep notes were held because they may contain a password or key.")
                                .font(COSType.body(11)).foregroundStyle(.secondary)
                        } else if !snapshot.steer.isEmpty {
                            COSMarkdownView(text: snapshot.steer, bodySize: 12)
                        }
                        ForEach(snapshot.files) { file in
                            if file.id != "prep_" + snapshot.draftId + "_steer" {
                                MeetingPrepSnapshotFile(store: store, snapshot: snapshot, file: file)
                            }
                        }
                        Button("Open latest editable prep") {
                            Task { await store.openLatestDraft(snapshot.draftId) }
                        }.buttonStyle(TodayLinkStyle(size: 11))
                        if snapshot.removedAt == nil, snapshot.current != false, snapshot.state == "applying" {
                            Button("Retry add prep") { retry(snapshot, to: requested, token: token) }
                                .buttonStyle(TodayLinkStyle(size: 11)).disabled(busy)
                        }
                        if live, snapshot.removedAt == nil, snapshot.current != false, snapshot.state == "applied" {
                            Text("To update this recording after edits, select the latest prep below and choose Add prep again.")
                                .font(COSType.body(11)).foregroundStyle(.secondary)
                        }
                    }
                }
                if live {
                    ForEach(suggestions) { draft in
                        Button("Add prep: " + draftLabel(draft)) { selected = draft }.buttonStyle(TodayLinkStyle(size: 12)).disabled(busy)
                    }
                    if let otherDrafts {
                        ForEach(otherDrafts) { draft in
                            Button("Add prep: " + draftLabel(draft)) { selected = draft }
                                .buttonStyle(TodayLinkStyle(size: 12)).disabled(busy)
                        }
                        if otherDrafts.isEmpty {
                            Text("No other Prep drafts are available.").font(COSType.body(11)).foregroundStyle(.secondary)
                        }
                        Button("Hide other drafts") { self.otherDrafts = nil }.buttonStyle(TodayLinkStyle(size: 11)).disabled(busy)
                    } else {
                        Button("Choose another Prep draft") { Task { await chooseOtherDrafts(requested, token: token) } }
                            .buttonStyle(TodayLinkStyle(size: 11)).disabled(busy)
                    }
                }
                if live, let selected {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Add \(selected.title) to \(title)?").font(COSType.body(12, weight: .semibold))
                        Text(draftDetails(selected)).font(COSType.body(11)).foregroundStyle(.secondary)
                        let preview = selected.steer.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !preview.isEmpty {
                            Text("Notes: " + String(preview.prefix(160)) + (preview.count > 160 ? "…" : ""))
                                .font(COSType.body(11)).foregroundStyle(.secondary).lineLimit(3)
                        }
                        let names = selected.files.filter { $0.status == "ready" }.map(\.name)
                        if !names.isEmpty {
                            Text("Files: " + names.prefix(4).joined(separator: ", ") + (names.count > 4 ? " and \(names.count - 4) more" : ""))
                                .font(COSType.body(11)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Text("\(selected.files.filter { $0.status == "ready" }.count) ready files and the saved Prep notes will be added to this recording only. Maximum meeting context: 100 files and 500 KB of text.")
                            .font(COSType.body(11)).foregroundStyle(.secondary)
                        HStack {
                            Button("Add prep") { bind(selected, to: requested, token: token) }
                                .buttonStyle(TodayButtonStyle(primary: true, small: true)).disabled(busy)
                            Button("Cancel") { self.selected = nil }.buttonStyle(TodayButtonStyle(small: true)).disabled(busy)
                        }
                    }.padding(10).background(RoundedRectangle(cornerRadius: 8).fill(TodayInk.qopen))
                }
                if let error { Text(error).font(COSType.body(12)).foregroundStyle(COSPalette.amber) }
                Button("Refresh prep") { Task { await refresh(requested, token: token) } }
                    .buttonStyle(TodayLinkStyle(size: 11)).disabled(busy)
            }
        }
        .task(id: requested) {
            guard !Task.isCancelled else { return }
            let next = UUID()
            generation = next; activeTarget = requested
            selected = nil; bound = []; suggestions = []; otherDrafts = nil; error = nil; busy = false
            await refresh(requested, token: next)
        }
        .onDisappear { generation = UUID(); activeTarget = nil }
    }
    private func snapshotStatus(_ snapshot: MeetingPrep.SessionSnapshot) -> String {
        if snapshot.removedAt != nil { return "Removed from current meeting context" }
        if snapshot.current == false { return "Earlier bind" }
        if snapshot.state == "applying" { return "Waiting to be added" }
        return "Current meeting context"
    }
    private func draftLabel(_ draft: MeetingPrep.Draft) -> String { draft.title + " · " + draftDetails(draft) }
    private func draftDetails(_ draft: MeetingPrep.Draft) -> String {
        func display(_ value: String) -> String {
            DropIt.date(.string(value))?.formatted(date: .abbreviated, time: .shortened) ?? value
        }
        let saved = "Updated " + display(draft.updatedAt) + " · revision \(draft.revision)"
        return draft.startsAt.map { display($0) + " · " + saved } ?? saved
    }
    private func isCurrent(_ requested: Target, token: UUID) -> Bool {
        activeTarget == requested && generation == token
    }
    private func refresh(_ requested: Target, token: UUID) async {
        guard isCurrent(requested, token: token), !Task.isCancelled, !busy else { return }
        busy = true
        defer { if isCurrent(requested, token: token) { busy = false } }
        selected = nil; otherDrafts = nil
        await read(requested, token: token)
    }
    private func chooseOtherDrafts(_ requested: Target, token: UUID) async {
        guard requested.live, isCurrent(requested, token: token), !Task.isCancelled, !busy else { return }
        busy = true
        defer { if isCurrent(requested, token: token) { busy = false } }
        do {
            let options = try await store.availableDrafts()
            guard !Task.isCancelled, isCurrent(requested, token: token) else { return }
            let suggestedIDs = Set(suggestions.map(\.id))
            selected = nil; otherDrafts = options.filter { !suggestedIDs.contains($0.id) }; error = nil
        } catch { if !Task.isCancelled, isCurrent(requested, token: token) { self.error = error.localizedDescription } }
    }
    private func read(_ requested: Target, token: UUID) async {
        do {
            let found = try await store.meetingSnapshots(session: requested.session)
            guard !Task.isCancelled, isCurrent(requested, token: token) else { return }
            bound = found
            let options = requested.live && requested.startedAt != nil
                ? try await store.meetingDrafts(session: requested.session, startedAt: requested.startedAt, suggestions: true) : []
            guard !Task.isCancelled, isCurrent(requested, token: token) else { return }
            suggestions = options; error = nil
        } catch { if !Task.isCancelled, isCurrent(requested, token: token) { self.error = error.localizedDescription } }
    }
    private func bind(_ draft: MeetingPrep.Draft, to requested: Target, token: UUID) {
        guard requested.live, selected == draft else { return }
        applyBinding(to: requested, token: token) { try await store.bind(draft, session: requested.session) }
    }
    private func retry(_ snapshot: MeetingPrep.SessionSnapshot, to requested: Target, token: UUID) {
        guard snapshot.sessionId == requested.session, snapshot.current != false, snapshot.removedAt == nil,
              snapshot.state == "applying", bound.contains(where: { $0.id == snapshot.id }) else { return }
        applyBinding(to: requested, token: token) { try await store.retryBinding(snapshot) }
    }
    private func applyBinding(to requested: Target, token: UUID, _ apply: @escaping () async throws -> Void) {
        guard isCurrent(requested, token: token), !busy else { return }
        busy = true
        Task {
            guard !Task.isCancelled, isCurrent(requested, token: token) else { return }
            defer { if isCurrent(requested, token: token) { busy = false } }
            do {
                try await apply()
                guard !Task.isCancelled, isCurrent(requested, token: token) else { return }
                selected = nil; otherDrafts = nil; await read(requested, token: token)
            } catch { if !Task.isCancelled, isCurrent(requested, token: token) { self.error = error.localizedDescription } }
        }
    }
}

/// Uses the frozen file hash, never the editable draft's newer content, to select an original for saving.
private struct MeetingPrepSnapshotFile: View {
    @ObservedObject var store: MeetingPrepStore
    let snapshot: MeetingPrep.SessionSnapshot
    let file: MeetingPrep.SessionSnapshot.File
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(file.name).font(COSType.body(12))
                Spacer()
                Button(busy ? "Downloading…" : "Save original") {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = URL(fileURLWithPath: file.name).lastPathComponent
                    guard panel.runModal() == .OK, let destination = panel.url else { return }
                    busy = true; error = nil
                    Task {
                        defer { busy = false }
                        do {
                            let original = try await store.downloadSnapshotFile(file, snapshot: snapshot)
                            defer { try? FileManager.default.removeItem(at: original) }
                            try Data(contentsOf: original).write(to: destination, options: .atomic)
                        } catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(TodayLinkStyle(size: 11)).disabled(busy)
            }
            if let error { Text(error).font(COSType.body(11)).foregroundStyle(COSPalette.amber) }
        }
    }
}
