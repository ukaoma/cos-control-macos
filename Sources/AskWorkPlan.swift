import SwiftUI
import Foundation

/// A proposal is not a receipt or an authorization. Only the native Work journal mints assignment receipt IDs.
enum AskWorkPlan {
    static let pendingState = "Ask proposal"
    static let scope = "This proposal uses the task, confirmed meeting references and server session evidence. It does not read local files, Work chat history or prior results. Review the full local context in Work before sending."
    static let unavailable = "This server does not offer Work proposals. Your normal Ask conversation is still available."
    static func offered(_ capabilities: [String: JSONValue]) -> Bool {
        capabilities["protocolVersion"]?.int == 1 && capabilities["planOnly"]?.bool == true
            && capabilities["dispatch"]?.bool == false && capabilities["requiresExistingWork"]?.bool == true
            && capabilities["controlSnapshot"]?.int == 1
    }
    static func validQuestion(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf16.count <= 2000
            && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" && $0 != "\r" }
    }
    struct Request: Identifiable { let id = UUID(); let question: String }
    struct Assignment: Decodable {
        let sessionID: String
        let prompt: String
        let mode: String?
    }
    struct Target: Decodable {
        let id: String
        let title: String
        let automatic: Bool
        let forkable: Bool
        let reason: String?
    }
    struct Evidence: Decodable {
        let sessions: [Target]
        let eligibleContinueSessionIDs: [String]
        let eligibleForkSessionIDs: [String]
        let newSessionProviders: [String]
    }
    struct Proposal: Decodable {
        let protocolVersion: Int
        let planOnly: Bool
        let proposalID: String
        let workID: String
        let revision: String
        let question: String
        let answer: String
        let assignments: [Assignment]
        let model: String?
        let effort: String?
        let evidence: Evidence
        let revalidatedEvidence: Evidence

        func valid(workID expectedWork: String, revision expectedRevision: String, question expectedQuestion: String) -> Bool {
            let evidence = revalidatedEvidence
            guard protocolVersion == 1, planOnly, workID == expectedWork, revision == expectedRevision,
                  question == expectedQuestion, AskWorkPlan.validQuestion(question),
                  proposalID.range(of: "^awp_[a-f0-9]{64}$", options: .regularExpression) != nil,
                  !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, answer.utf16.count <= 6000,
                  assignments.count <= 3, Set(assignments.map(\.sessionID)).count == assignments.count,
                  evidence.sessions.count <= 12, Set(evidence.sessions.map(\.id)).count == evidence.sessions.count,
                  evidence.newSessionProviders.isEmpty,
                  evidence.eligibleContinueSessionIDs.count <= 12, evidence.eligibleForkSessionIDs.count <= 12 else { return false }
            return assignments.allSatisfy { assignment in
                guard WorkSessionLinks.validSessionID(assignment.sessionID), WorkChatPolicy.validPrompt(assignment.prompt),
                      let target = evidence.sessions.first(where: { $0.id == assignment.sessionID }), target.title.count <= 300 else { return false }
                switch assignment.mode {
                case nil, "continue": return target.automatic && evidence.eligibleContinueSessionIDs.contains(target.id)
                case "fork": return target.forkable && evidence.eligibleForkSessionIDs.contains(target.id)
                default: return false
                }
            }
        }
    }
}

/// A small native sheet off the existing COS composer. Existing cards only; it neither creates a card nor sends work.
struct AskWorkPlanSheet: View {
    @ObservedObject var model: ControllerModel
    @ObservedObject var handoff: WorkHandoffStore
    let request: AskWorkPlan.Request
    let onOpenWork: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var chat = WorkTaskChatStore()
    @State private var selectedID = ""
    @State private var question = ""
    @State private var operation: Task<Void, Never>?
    @State private var discovering = true
    @State private var offered = false
    @State private var notice: String?
    private var tasks: [TaskRow] {
        model.workTasks.filter { !$0.checked && $0.workStage != "complete" && $0.workMetadataError == nil
            && !$0.workIdentity.isEmpty && $0.workRevision.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
    }
    private var task: TaskRow? { tasks.first { $0.workSourceID == selectedID } }
    private var proposal: WorkChatRound? {
        chat.record?.workID == selectedID ? chat.record?.rounds.last(where: { $0.askProposalID != nil && $0.askImportedAt == nil }) : nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Plan for Work").font(COSType.display(25, weight: .medium))
                Spacer()
                Button("Close") { operation?.cancel(); dismiss() }.buttonStyle(COSQuietButtonStyle())
            }
            Text("Choose an existing card. COS proposes assignments; you review them in Work before sending.")
                .font(COSType.body(13)).foregroundStyle(COSPalette.muted)
            Picker("Work card", selection: $selectedID) {
                Text("Choose a card…").tag("")
                ForEach(tasks, id: \.workSourceID) { row in Text(row.title + " · " + row.domain).tag(row.workSourceID) }
            }.disabled(chat.busy || discovering || !model.workTasksComplete)
            TextEditor(text: $question).font(COSType.body(13)).frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(COSPalette.line))
                .disabled(chat.busy)
            Text("\(question.utf16.count) / 2,000 characters").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
            Text(AskWorkPlan.scope).font(COSType.body(12)).foregroundStyle(COSPalette.muted)
            if discovering { ProgressView("Checking Work proposals…") }
            if let line = notice ?? chat.error { Text(line).foregroundStyle(COSPalette.muted).textSelection(.enabled) }
            if chat.busy { ProgressView(chat.phase.isEmpty ? "Preparing proposal…" : chat.phase) }
            if let round = proposal {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(round.question).font(COSType.body(14, weight: .semibold))
                        COSMarkdownText(round.answer, bodySize: 13)
                        ForEach(round.assignments) { assignment in
                            VStack(alignment: .leading, spacing: 4) {
                                Text((assignment.mode == "fork" ? "Fork · " : "Continue · ") +
                                     (round.orchestrated?.first(where: { $0.id == assignment.sessionID })?.title ?? assignment.sessionID))
                                    .font(COSType.body(13, weight: .semibold))
                                Text(assignment.prompt).font(COSType.body(13)).textSelection(.enabled)
                            }
                        }
                        Text("Saved on this Mac with the card. Nothing has been sent.").font(COSType.body(12)).foregroundStyle(COSPalette.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 260)
                Button("Add to Work review") {
                    guard let task else { return }
                    operation = Task { @MainActor in
                        if await chat.importAskProposal(roundID: round.id, source: .taskSnapshot(task), handoff: handoff) {
                            onOpenWork(selectedID); dismiss()
                        }
                    }
                }.buttonStyle(COSPrimaryButtonStyle()).disabled(chat.busy || chat.refreshing || task == nil || !model.workTasksComplete)
            }
            HStack {
                Button(proposal == nil ? "Prepare proposal" : "Prepare another proposal") {
                    guard let task else { return }
                    let words = question
                    operation = Task { @MainActor in
                        await chat.prepareAskProposal(question: words, source: .taskSnapshot(task), handoff: handoff,
                                                      conversationEnabled: model.status.dropIt.threaded)
                    }
                }.buttonStyle(COSQuietButtonStyle())
                    .disabled(!offered || task == nil || !AskWorkPlan.validQuestion(question) || chat.busy || chat.refreshing || !model.workTasksComplete)
                Spacer()
                if chat.busy { Button("Cancel request") { operation?.cancel() }.buttonStyle(COSQuietButtonStyle()) }
            }
        }
        .padding(24).frame(width: 680).font(COSType.body(13))
        .interactiveDismissDisabled(chat.busy)
        .task {
            question = request.question
            chat.enabled = Bundle.main.object(forInfoDictionaryKey: "COSWorkChatEnabled") as? Bool == true
                || ProcessInfo.processInfo.environment["COS_WORK_ORCHESTRATION_CANDIDATE"] == "1"
            chat.referenceFacts = WorkReferencesGroup.liveFacts
            defer { discovering = false }
            await model.loadWorkTasks(force: true)
            await handoff.refresh()
            guard chat.enabled else { notice = "Work chat is unavailable in this build."; return }
            do {
                let capabilities = try await handoff.taskChatCall(["ask-work-plan-capabilities"])
                offered = AskWorkPlan.offered(capabilities)
                if !offered { notice = AskWorkPlan.unavailable }
            } catch { notice = error.localizedDescription }
            if !model.workTasksComplete { notice = model.workTasksError ?? "The complete Work board is unavailable. Refresh before planning." }
        }
        .onChange(of: selectedID) { _, _ in
            guard let task else { return }
            chat.open(source: .taskSnapshot(task), handoff: handoff)
            chat.syncFromDisk()
        }
        .onDisappear { operation?.cancel(); _ = chat.flushDraft() }
    }
}
