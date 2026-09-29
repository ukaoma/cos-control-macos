import SwiftUI
import CryptoKit

extension WorkSource {
    /// A display snapshot fingerprint, not the canonical task writer's CAS revision.
    static func taskSnapshot(_ task: TaskRow) -> WorkSource {
        var context = "Task: \(task.text.isEmpty ? task.title : task.text)\nProject: \(task.domain)\nDone when: \(task.doneWhen)\nSource: \(task.source)"
        if !task.meetingRefs.isEmpty {
            let references = task.meetingRefs.map { reference in
                "- \(reference.title) | canonical ID: \(reference.recordId) | saved source: \(reference.domain)/\(reference.month)/\(reference.filename)"
            }.joined(separator: "\n")
            context += "\nConfirmed meeting references (explicit links; transcript evidence is not included):\n" + references
        }
        let revision = SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined()
        return WorkSource(id: "task:\(task.domain):\(task.workIdentity)", title: task.title, revision: revision, project: task.domain, context: context)
    }
}

struct WorkHandoffView: View {
    @ObservedObject var store: WorkHandoffStore
    let source: WorkSource
    var isPreview = false
    var onOpenSession: (String) -> Void
    var validateBeforeSend: (@MainActor () async -> Bool)? = nil
    @State private var validating = false
    private var draft: WorkHandoffDraft { store.draft(for: source) }
    private var mode: WorkHandoffMode { draft.mode }
    private var sessionID: String { draft.sessionID }
    private var modelID: String { draft.modelID }
    private var provider: String { draft.provider }
    private var prompt: String { draft.prompt }
    private func draftBinding<Value>(_ path: WritableKeyPath<WorkHandoffDraft, Value>) -> Binding<Value> {
        let boundSource = source
        return Binding(get: { store.draft(for: boundSource)[keyPath: path] }, set: { value in
            var next = store.draft(for: boundSource); next[keyPath: path] = value
            store.updateDraft(next, for: boundSource)
        })
    }

    private var recommended: [WorkSession] { store.recommendations(for: source) }
    private var selectedSession: WorkSession? { store.sessions.first { $0.id == sessionID } }
    private var selectedModel: WorkModelChoice? { store.models.first { $0.id == modelID && $0.provider == provider } }
    private var providers: [String] { Array(Set(store.models.map(\.provider))).sorted() }
    private var choices: [WorkModelChoice] { store.models.filter { $0.provider == provider } }
    private var canSend: Bool {
        !validating && !store.busy && !store.receipts(for: source.id).contains(where: \.blocksNewHandoff) && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && prompt.utf16.count <= 32_000
            && destinationSupported
    }

    /// 0.5.243: a Fork with a target provider picked is a fork to another platform (a New session seeded with the
    /// conversation export). No provider means the native, same-platform fork.
    private var forkToPlatform: Bool { mode == .fork && WorkHandoffStore.crossPlatformTargets.contains(provider) && provider != selectedSession?.provider }

    private var destinationSupported: Bool {
        if mode == .newSession { return selectedModel?.available == true }
        guard let selectedSession else { return false }
        if forkToPlatform {
            return selectedModel?.available == true && WorkHandoffStore.exportableProviders.contains(selectedSession.provider)
        }
        return (mode == .fork ? WorkHandoffStore.nativeForkProviders : WorkHandoffStore.continueProviders).contains(selectedSession.provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Agent workspace").font(COSType.display(20, weight: .medium))
                Spacer()
                Button("Refresh") { Task { await store.refresh() } }
                    .buttonStyle(COSQuietButtonStyle()).disabled(store.busy || validating)
            }
            Text(isPreview ? "Local demonstration. No agent is contacted." : "Choose an agent and review the context. Sending does not complete or publish this work.")
                .font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
            adviceBlock
            Picker("Destination", selection: Binding(get: { mode }, set: { value in
                var next = draft; next.mode = value
                // A provider chosen for New session must not turn a Fork into a fork to another platform.
                if value == .fork && mode != .fork { next.provider = ""; next.modelID = "" }
                store.updateDraft(next, for: source)
            })) {
                ForEach(WorkHandoffMode.allCases, id: \.self) { value in Text(value.title).tag(value) }
            }.pickerStyle(.segmented).disabled(store.busy || validating)
            if mode == .newSession { newDestination } else { existingDestination }
            Text("Context to send").font(COSType.body(12, weight: .semibold))
            TextEditor(text: draftBinding(\.prompt)).font(COSType.body(12)).frame(minHeight: 100, maxHeight: 170)
                .scrollContentBackground(.hidden).padding(6).background(COSPalette.panel)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(COSPalette.line))
                .accessibilityLabel("Context to send")
                .disabled(store.busy || validating)
            if store.earlierDraftCount(for: source) > 0 {
                Text("Earlier revision drafts are retained. This revision has its own context and destination.")
                    .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
            }
            HStack {
                Text(forkToPlatform
                     ? "\(prompt.utf16.count.formatted()) / 32,000 characters · the conversation fills the rest"
                     : "\(prompt.utf16.count.formatted()) / 32,000 characters · review before sending")
                    .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
                Spacer()
                Button(mode == .newSession ? "Start new session" : forkToPlatform ? "Fork to \(WorkHandoffStore.providerName(provider))" : mode == .fork ? "Fork and send" : "Send to session") {
                    let sendingSource = source, sendingMode = mode, sendingSession = selectedSession, sendingModel = selectedModel, sendingPrompt = prompt
                    let crossPlatform = forkToPlatform
                    validating = true
                    Task {
                        defer { validating = false }
                        if let validateBeforeSend, !(await validateBeforeSend()) { return }
                        if crossPlatform, let sendingSession, let sendingModel {
                            await store.forkToPlatform(source: sendingSource, session: sendingSession, model: sendingModel, prompt: sendingPrompt)
                        } else {
                            // A plain New session has no source session (a stale selection must not read as a fork).
                            await store.submit(source: sendingSource, mode: sendingMode, session: sendingMode == .newSession ? nil : sendingSession,
                                               model: sendingModel, prompt: sendingPrompt)
                        }
                    }
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
        }.padding(16).background(COSPalette.raised.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(COSPalette.line))
            .task(id: source) {
                await store.refresh()
                await store.loadAdvice(for: source)
            }
    }

    /// Jev's suggestion. "Use this" fills Destination and Session in one explicit click; sending stays separate.
    @ViewBuilder private var adviceBlock: some View {
        if let advice = store.advice(for: source) {
            let session = advice.sessionID.flatMap { id in store.sessions.first { $0.id == id } }
            let applied = mode == (advice.action == .continueSession ? .continueSession : advice.action == .fork ? .fork : .newSession)
                && (advice.action == .newSession || sessionID == advice.sessionID) && !(advice.action == .fork && !provider.isEmpty)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkle").foregroundStyle(COSPalette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(adviceTitle(advice, session)).font(COSType.body(12, weight: .semibold))
                    Text("\(advice.reason) Jev · \(advice.percent)").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                }
                Spacer(minLength: 8)
                Button(applied ? "Selected" : "Use this") {
                    store.updateDraft(WorkHandoffStore.applying(advice, to: draft), for: source)
                }.buttonStyle(COSQuietButtonStyle()).disabled(applied || store.busy || validating)
            }.padding(10).background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 6))
        } else if let text = WorkHandoffStore.adviceUnavailableText(store.adviceUnavailableReason(for: source)) {
            Text(text).font(COSType.body(11)).foregroundStyle(COSPalette.muted)
        }
    }

    private func adviceTitle(_ advice: SessionAdvice, _ session: WorkSession?) -> String {
        switch advice.action {
        case .continueSession: return "Suggested: continue in “\(session?.title ?? "session")”"
        case .fork: return "Suggested: fork “\(session?.title ?? "session")”"
        case .newSession: return "Suggested: start a new session"
        }
    }

    private var existingDestination: some View {
        VStack(alignment: .leading, spacing: 9) {
            if store.sessions.isEmpty {
                Text(sessionID.isEmpty ? "No sessions available. Refresh or choose a new session." : "Your saved session is unavailable. Refresh to resolve it or explicitly choose a new destination.")
                    .font(COSType.body(12)).foregroundStyle(COSPalette.muted)
            } else {
                Picker("Session", selection: draftBinding(\.sessionID)) {
                    Text("Choose a session").tag("")
                    if !sessionID.isEmpty && selectedSession == nil { Text("Saved session unavailable · refresh to resolve").tag(sessionID) }
                    ForEach(store.sessions) { session in Text("\(session.title) · \(session.provider)").tag(session.id) }
                }.disabled(store.busy || validating)
                if mode == .fork { forkTarget }
                if let session = selectedSession {
                    if !destinationSupported && !forkToPlatform {
                        Text(mode == .fork
                             ? (WorkHandoffStore.exportableProviders.contains(session.provider)
                                ? "A \(WorkHandoffStore.providerName(session.provider)) session forks to Claude or Codex: choose one under Fork to."
                                : "This session cannot be forked. Choose a new session instead.")
                             : "This provider does not support continuing a session here.")
                            .font(COSType.body(11)).foregroundStyle(COSPalette.danger)
                    }
                    Text("\(session.status.capitalized) · \(session.project.isEmpty ? "Workspace unavailable" : session.project)")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                    if !session.summary.isEmpty { Text(session.summary).font(COSType.body(12)).lineLimit(3) }
                    Text(forkToPlatform
                         ? "Starts a new \(WorkHandoffStore.providerName(provider)) session with this context plus the conversation up to now from \u{201C}\(session.title)\u{201D}, read from its transcript (up to 32,000 characters in all). It uses the server\u{2019}s configured workspace and permissions, not the original session\u{2019}s. The original session is unchanged."
                         : mode == .fork ? "Creates a copy with \(WorkHandoffStore.providerName(session.provider)); the original remains unchanged." : "Uses this session’s model and permissions. Busy sessions may queue or refuse.")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                }
                if store.advice(for: source) == nil, let first = recommended.first {
                    Button {
                        var next = draft; next.sessionID = first.id
                        store.updateDraft(next, for: source)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Word match: \(first.title)").font(COSType.body(12, weight: .semibold))
                            Text(store.recommendationReason(for: first, source: source))
                                .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10).contentShape(Rectangle())
                    }.buttonStyle(.plain).background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 6)).disabled(store.busy || validating)
                }
            }
        }
    }

    /// Fork to: the same platform (native copy of the conversation) or any catalog provider and model.
    private var forkTarget: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Fork to", selection: Binding(get: { forkToPlatform ? provider : "" }, set: { value in
                var next = draft; next.provider = value; next.modelID = ""
                store.updateDraft(next, for: source)
            })) {
                Text("Same platform (copy the conversation)").tag("")
                ForEach(providers.filter { WorkHandoffStore.crossPlatformTargets.contains($0) && $0 != selectedSession?.provider }, id: \.self) {
                    Text(WorkHandoffStore.providerName($0)).tag($0)
                }
            }.disabled(store.busy || validating)
            if forkToPlatform {
                Picker("Model", selection: draftBinding(\.modelID)) {
                    Text("Choose model").tag("")
                    if !modelID.isEmpty && selectedModel == nil { Text("Saved model unavailable").tag(modelID) }
                    ForEach(choices) { choice in Text(choice.title + (choice.available ? "" : " · unavailable")).tag(choice.id) }
                }.disabled(store.busy || validating)
            }
        }
    }

    private var newDestination: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.models.isEmpty { Text("No configured models available.").foregroundStyle(COSPalette.muted) }
            Picker("Provider", selection: Binding(get: { provider }, set: { value in
                var next = draft; next.provider = value; next.modelID = ""
                store.updateDraft(next, for: source)
            })) {
                Text("Choose provider").tag("")
                if !provider.isEmpty && !providers.contains(provider) { Text("\(provider) · unavailable").tag(provider) }
                ForEach(providers, id: \.self) { Text(WorkHandoffStore.providerName($0)).tag($0) }
            }.disabled(store.busy || validating)
            Picker("Model", selection: draftBinding(\.modelID)) {
                Text("Choose model").tag("")
                if !modelID.isEmpty && selectedModel == nil { Text("Saved model unavailable").tag(modelID) }
                ForEach(choices) { choice in Text(choice.title + (choice.available ? "" : " · unavailable")).tag(choice.id) }
            }.disabled(store.busy || validating)
            if let reason = selectedModel?.reason, !reason.isEmpty {
                Text(reason).font(COSType.body(11)).foregroundStyle(COSPalette.muted)
            }
            Text("Uses the server’s configured workspace and permissions. This chooser does not change them.")
                .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Handoff history").font(COSType.display(18, weight: .medium))
                Spacer()
                Button("Check status") { Task { await store.refreshReceipts() } }.buttonStyle(COSQuietButtonStyle()).disabled(store.busy || validating)
            }
            if store.receipts(for: source.id).isEmpty {
                Text("No recorded handoff for this work. Earlier agent activity is not inferred.").font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
            }
            ForEach(store.receipts(for: source.id)) { receipt in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(receipt.status.capitalized).font(COSType.body(12, weight: .semibold))
                        Spacer()
                        Text(WorkHandoffStore.providerName(receipt.provider)).font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                    }
                    if let lineage = WorkHandoffStore.lineage(of: receipt, sessions: store.sessions) {
                        Text(lineage).font(COSType.body(11)).foregroundStyle(COSPalette.muted)
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
                            .buttonStyle(COSQuietButtonStyle()).disabled(store.busy || validating)
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
                            }.padding(14).background(COSPalette.raised.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
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
