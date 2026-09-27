import SwiftUI
import CryptoKit

extension WorkSource {
    /// A display snapshot fingerprint, not the canonical task writer's CAS revision.
    static func taskSnapshot(_ task: TaskRow) -> WorkSource {
        let context = "Task: \(task.text.isEmpty ? task.title : task.text)\nProject: \(task.domain)\nDone when: \(task.doneWhen)\nSource: \(task.source)"
        let revision = SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined()
        return WorkSource(id: "task:\(task.domain):\(task.id)", title: task.title, revision: revision, project: task.domain, context: context)
    }
}

struct WorkHandoffView: View {
    @ObservedObject var store: WorkHandoffStore
    let source: WorkSource
    var isPreview = false
    var onOpenSession: (String) -> Void
    @State private var mode: WorkHandoffMode = .continueSession
    @State private var sessionID = ""
    @State private var modelID = ""
    @State private var provider = ""
    @State private var prompt = ""
    @State private var initializedID = ""

    private var recommended: [WorkSession] { store.recommendations(for: source) }
    private var selectedSession: WorkSession? { store.sessions.first { $0.id == sessionID } }
    private var selectedModel: WorkModelChoice? { store.models.first { $0.id == modelID && $0.provider == provider } }
    private var providers: [String] { Array(Set(store.models.map(\.provider))).sorted() }
    private var choices: [WorkModelChoice] { store.models.filter { $0.provider == provider } }
    private var canSend: Bool {
        !store.busy && !store.receipts(for: source.id).contains(where: \.blocksNewHandoff) && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && prompt.utf16.count <= 32_000
            && destinationSupported
    }

    private var destinationSupported: Bool {
        if mode == .newSession { return selectedModel?.available == true }
        guard let selectedSession else { return false }
        return (mode == .fork ? ["claude", "codex"] : ["claude", "codex", "cursor"]).contains(selectedSession.provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Choose where to work").font(COSType.display(20, weight: .medium))
                Spacer()
                Button("Refresh") { Task { await store.refresh(); chooseDefaults() } }
                    .buttonStyle(COSQuietButtonStyle()).disabled(store.busy)
            }
            Text(isPreview ? "Local demonstration. No agent is launched and no message leaves this preview." : "Send this context to an agent you choose. The session keeps its own permissions; this does not complete the task or authorize publication.")
                .font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
            Picker("Destination", selection: $mode) {
                ForEach(WorkHandoffMode.allCases, id: \.self) { value in Text(value.title).tag(value) }
            }.pickerStyle(.segmented)
            if mode == .newSession { newDestination } else { existingDestination }
            Text("Context to send").font(COSType.body(12, weight: .semibold))
            TextEditor(text: $prompt).font(COSType.body(12)).frame(minHeight: 100, maxHeight: 170)
                .padding(6).background(COSPalette.panel)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(COSPalette.line))
                .accessibilityLabel("Context to send")
            HStack {
                Text("\(prompt.utf16.count.formatted()) / 32,000 characters · review before sending")
                    .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
                Spacer()
                Button(mode == .newSession ? "Start new session" : mode == .fork ? "Fork and send" : "Send to session") {
                    Task { await store.submit(source: source, mode: mode, session: selectedSession, model: selectedModel, prompt: prompt) }
                }.buttonStyle(COSPrimaryButtonStyle()).disabled(!canSend)
            }
            if prompt.utf16.count > 32_000 {
                Text("Context exceeds 32,000 characters. Shorten it before sending; nothing has been removed.")
                    .font(COSType.body(11)).foregroundStyle(COSPalette.danger)
            }
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle").font(COSType.body(12)).foregroundStyle(COSPalette.danger)
            }
            if store.busy { ProgressView("Checking destination…").controlSize(.small) }
            Divider()
            history
        }.padding(16).background(COSPalette.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(COSPalette.line))
            .task(id: source.id + ":" + source.revision) {
                let identity = source.id + ":" + source.revision
                if initializedID != identity { prompt = source.suggestedPrompt; initializedID = identity }
                await store.refresh()
                chooseDefaults()
            }
            .task { await pollVisibleReceipts() }
    }

    private func pollVisibleReceipts() async {
        guard !isPreview else { return }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard !Task.isCancelled else { return }
            if !store.busy, store.receipts.contains(where: { $0.blocksNewHandoff && $0.status != "delivered" }) {
                await store.refreshReceipts()
            }
        }
    }

    private var existingDestination: some View {
        VStack(alignment: .leading, spacing: 9) {
            if store.sessions.isEmpty {
                Text("No sessions available. Refresh or choose a new session.").font(COSType.body(12)).foregroundStyle(COSPalette.muted)
            } else {
                Picker("Session", selection: $sessionID) {
                    Text("Choose a session").tag("")
                    ForEach(store.sessions) { session in Text("\(session.title) · \(session.provider)").tag(session.id) }
                }
                if let session = selectedSession {
                    if !destinationSupported {
                        Text(mode == .fork ? "Fork is available for Claude and Codex sessions only. Choose Continue or a new session for this provider." : "This provider does not support continuing a session here.")
                            .font(COSType.body(11)).foregroundStyle(COSPalette.danger)
                    }
                    Text("\(session.status.capitalized) · \(session.project.isEmpty ? "Workspace unavailable" : session.project)")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                    if !session.summary.isEmpty { Text(session.summary).font(COSType.body(12)).lineLimit(3) }
                    Text(mode == .fork ? "Creates a separate conversation with this session's context. The provider stays \(session.provider)." : "Continues this exact conversation with its current provider, model, and permissions. A busy session may queue or refuse the handoff.")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                }
                if let first = recommended.first {
                    Button {
                        sessionID = first.id
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Suggested: \(first.title)").font(COSType.body(12, weight: .semibold))
                            Text(first.project == source.project && !source.project.isEmpty ? "Same project as this work." : "Ranked by project and relevant words in this work.")
                                .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10).contentShape(Rectangle())
                    }.buttonStyle(.plain).background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private var newDestination: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.models.isEmpty { Text("No configured models available.").foregroundStyle(COSPalette.muted) }
            Picker("Provider", selection: $provider) {
                Text("Choose provider").tag("")
                ForEach(providers, id: \.self) { Text($0.capitalized).tag($0) }
            }.onChange(of: provider) { _, _ in modelID = choices.first(where: \.available)?.id ?? "" }
            Picker("Model", selection: $modelID) {
                Text("Choose model").tag("")
                ForEach(choices) { choice in Text(choice.title + (choice.available ? "" : " · unavailable")).tag(choice.id) }
            }
            if let reason = selectedModel?.reason, !reason.isEmpty {
                Text(reason).font(COSType.body(11)).foregroundStyle(COSPalette.muted)
            }
            Text("A new session starts in the server’s configured workspace with its existing permissions. This chooser does not override that workspace. Review the context below; publication is not authorized by this handoff.")
                .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Handoff history").font(COSType.display(18, weight: .medium))
                Spacer()
                Button("Check status") { Task { await store.refreshReceipts() } }.buttonStyle(COSQuietButtonStyle()).disabled(store.busy)
            }
            if store.receipts(for: source.id).isEmpty {
                Text("No recorded handoff for this work. Earlier agent activity is not inferred.").font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
            }
            ForEach(store.receipts(for: source.id)) { receipt in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(receipt.status.capitalized).font(COSType.body(12, weight: .semibold))
                        Spacer()
                        Text(receipt.provider).font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                    }
                    Text(receipt.detail).font(COSType.body(12)).textSelection(.enabled)
                    if let result = receipt.result, !result.isEmpty { COSMarkdownView(text: result) }
                    if let sessionID = receipt.sessionID {
                        Button("Open session") { store.selectedWorkID = source.id; onOpenSession(sessionID) }.buttonStyle(COSQuietButtonStyle())
                    } else {
                        Text("Session link not yet confirmed.").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                    }
                    if receipt.status == "delivered" {
                        Button("I reviewed this session") { store.markReviewed(receiptID: receipt.id) }
                            .buttonStyle(COSQuietButtonStyle()).disabled(store.busy)
                        Text("Acknowledges your review and allows another handoff. The task stays unchanged.")
                            .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
                    }
                    if isPreview {
                        HStack {
                            Button("Show running") { store.simulate(receiptID: receipt.id, outcome: "running") }
                            Button("Show result") { store.simulate(receiptID: receipt.id, outcome: "completed") }
                            Button("Show failure") { store.simulate(receiptID: receipt.id, outcome: "failed") }
                        }.buttonStyle(COSQuietButtonStyle()).controlSize(.small)
                    }
                }.padding(12).background(COSPalette.panel, in: RoundedRectangle(cornerRadius: 8))
            }
            Text("An unknown delivery outcome needs a status check; do not send another copy blindly. Session output does not approve or publish work.")
                .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
        }
    }

    private func chooseDefaults() {
        if !store.sessions.contains(where: { $0.id == sessionID }) { sessionID = recommended.first?.id ?? "" }
        if !providers.contains(provider) { provider = store.models.first(where: \.available)?.provider ?? providers.first ?? "" }
        if !choices.contains(where: { $0.id == modelID }) { modelID = choices.first(where: \.available)?.id ?? "" }
    }
}

struct WorkSessionsView: View {
    @ObservedObject var store: WorkHandoffStore
    var isPreview = false
    var onOpenWork: (String) -> Void
    var onOpenFullSession: ((WorkSession) -> Void)? = nil
    private var selected: WorkSession? { store.sessions.first { $0.id == store.selectedSessionID } }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sessions").font(COSType.display(23, weight: .medium))
                    Text(isPreview ? "Shared preview conversations" : "Linked agent conversations").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                    ForEach(store.sessions) { session in
                        Button { store.selectedSessionID = session.id } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(session.title).font(COSType.body(12, weight: .semibold))
                                Text("\(session.provider) · \(session.status)").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10).contentShape(Rectangle())
                        }.buttonStyle(.plain).background(store.selectedSessionID == session.id ? COSPalette.raised : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }
                }.padding(18)
            }.frame(width: 250)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let session = selected {
                        Text(session.title).font(COSType.display(25, weight: .medium))
                        Text("\(session.provider) · \(session.status)").font(COSType.body(12)).foregroundStyle(COSPalette.muted)
                        Text(session.summary).font(COSType.body(13))
                        if let open = onOpenFullSession, !isPreview {
                            Button("Open full session") { open(session) }.buttonStyle(COSPrimaryButtonStyle())
                        }
                        ForEach(store.receipts.filter { $0.sessionID == session.id }) { receipt in
                            VStack(alignment: .leading, spacing: 10) {
                                Button("Back to work: \(receipt.workTitle)") { onOpenWork(receipt.workID) }.buttonStyle(COSQuietButtonStyle())
                                Text(receipt.status.capitalized + " · " + receipt.detail).font(COSType.body(12))
                                Text(receipt.prompt).font(COSType.body(12)).textSelection(.enabled)
                                if let result = receipt.result { COSMarkdownView(text: result) }
                            }.padding(14).background(COSPalette.card, in: RoundedRectangle(cornerRadius: 8))
                        }
                    } else {
                        Text("Choose a session").font(COSType.display(24, weight: .medium))
                        Text("A handoff links its exact conversation here. No title matching is used.").foregroundStyle(COSPalette.muted)
                    }
                    if isPreview { Text("Local demonstration only. These conversations do not contact a provider.").font(COSType.body(11)).foregroundStyle(COSPalette.muted) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
        }.background(COSPalette.panel).task { await store.refresh() }
            .task { await pollVisibleReceipts() }
    }

    private func pollVisibleReceipts() async {
        guard !isPreview else { return }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard !Task.isCancelled else { return }
            if !store.busy, store.receipts.contains(where: { $0.blocksNewHandoff && $0.status != "delivered" }) {
                await store.refreshReceipts()
            }
        }
    }
}
