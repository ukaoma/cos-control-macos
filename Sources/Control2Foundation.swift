import AppKit
import CryptoKit
import SwiftUI

struct Control2FoundationSnapshot: Codable, Sendable {
    struct Capabilities: Codable, Sendable { let publication: Bool; let automaticExecution: Bool; let manualDraft: Bool? }
    struct Gate: Codable, Sendable, Identifiable { let id: String; let status: String; let detail: String }
    struct Work: Codable, Sendable, Identifiable {
        struct Artifact: Codable, Sendable {
            struct Check: Codable, Sendable { let name: String; let passed: Bool }
            let path: String
            let sha256: String
            let kind: String
            let checks: [Check]
        }
        let id: String
        let meetingId: String
        let projectId: String
        let revision: String
        let status: String
        let title: String
        let createdAt: String
        let updatedAt: String
        let reason: String?
        let sourceExcerpt: String?
        let criteria: [String]?
        let artifact: Artifact?
    }
    let schemaVersion: Int
    let enabled: Bool
    let mode: String
    let capabilities: Capabilities
    let work: [Work]
    let gates: [Gate]

    static func decode(_ data: Data) throws -> Self {
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.schemaVersion == 1, result.enabled, result.mode == "foundation",
              !result.capabilities.publication, !result.capabilities.automaticExecution,
              Set(result.work.map(\.id)).count == result.work.count,
              result.work.allSatisfy({ ["needs_review", "superseded", "blocked"].contains($0.status) }) else {
            throw HelperClientError.invalidResponse("Unsupported Foundation Lab contract. No actions were enabled.")
        }
        return result
    }
}

struct Control2FoundationReplay: Codable, Sendable {
    let meetingId: String
    let revision: String
    let projectId: String
    let transcript: String
    let ready: Bool
    let sourceAliases: [String]
    let criteria: [String]

    static func sample(revision: String = "1", ready: Bool = true) -> Self {
        Self(meetingId: "foundation-native-sample", revision: revision, projectId: "foundation-website",
             transcript: "Synthetic website review. Operator: Prepare a clearer homepage CTA and verify mobile layout. Revision \(revision). Publication requires my separate approval.",
             ready: ready, sourceAliases: ["foundation-native-capture"],
             criteria: ["Clear homepage CTA", "Readable mobile layout", "Production unchanged"])
    }
}

@MainActor
final class Control2FoundationModel: ObservableObject {
    @Published var snapshot: Control2FoundationSnapshot?
    @Published var error: String?
    @Published var busy = false
    @Published var operation = ""
    @Published var selectedID: String?
    private let helper: HelperClient

    init(helper: HelperClient = HelperClient()) { self.helper = helper }

    func refresh() async { await perform(nil) }
    func replay(revision: String, ready: Bool = true) async { await perform(.sample(revision: revision, ready: ready)) }

    func preparePreview(workID: String) async {
        guard snapshot?.capabilities.manualDraft == true,
              snapshot?.work.contains(where: { $0.id == workID && $0.status == "needs_review" }) == true else { return }
        await perform(nil, draftWorkID: workID)
    }

    func openPreview(_ artifact: Control2FoundationSnapshot.Work.Artifact) {
        do {
            let url = try Self.verifiedPreviewURL(artifact)
            guard NSWorkspace.shared.open(url) else { throw HelperClientError.commandFailed("The preview could not be opened.") }
        } catch { self.error = error.localizedDescription }
    }

    static func verifiedPreviewURL(_ artifact: Control2FoundationSnapshot.Work.Artifact,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        guard artifact.kind == "preview", let home = environment["COS_CONTROL_TEST_HOME"], home.hasPrefix("/tmp/") else {
            throw HelperClientError.commandFailed("The preview is outside the disposable lab.")
        }
        let root = URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL.path
        let url = URL(fileURLWithPath: artifact.path).resolvingSymlinksInPath().standardizedFileURL
        guard (root.hasPrefix("/tmp/") || root.hasPrefix("/private/tmp/")), url.path.hasPrefix(root + "/"),
              url.pathExtension.lowercased() == "html",
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 2 * 1024 * 1024 else {
            throw HelperClientError.commandFailed("The preview is not a bounded HTML file in the disposable lab.")
        }
        let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        guard digest == artifact.sha256 else { throw HelperClientError.commandFailed("The preview changed after it was checked. Refresh and prepare a new revision.") }
        return url
    }

    private func perform(_ replay: Control2FoundationReplay?, draftWorkID: String? = nil) async {
        guard !busy else { return }
        busy = true
        error = nil
        operation = draftWorkID == nil ? "Refreshing" : "Preparing a text preview…"
        defer { busy = false; operation = "" }
        do {
            let payload = try replay.map { try JSONEncoder().encode($0) }
            let args = draftWorkID.map { ["foundation-draft", "--work-id", $0] } ?? [replay == nil ? "foundation-status" : "foundation-replay"]
            let result = try await helper.run(args, timeout: draftWorkID == nil ? 20 : 165, stdinData: payload)
            guard result.ok else { throw HelperClientError.commandFailed(result.message) }
            let current = try Control2FoundationSnapshot.decode(JSONEncoder().encode(result.details))
            snapshot = current
            if let replay, let active = current.work.first(where: {
                $0.meetingId == replay.meetingId && $0.projectId == replay.projectId && $0.status != "superseded"
            }) { selectedID = active.id }
            else if !current.work.contains(where: { $0.id == selectedID }) { selectedID = current.work.first?.id }
        } catch {
            self.error = error.localizedDescription
            snapshot = nil // stale packets must never look current after a transport failure
        }
    }
}

/// Disposable UI examples. These become read-only TaskRow projections, never canonical task writes objects or enter a task writer.
struct Control2PreviewTask: Identifiable {
    let id: String
    let title: String
    let domain: String
    let owner: String
    let schedule: String
    let source: String
    let finishLine: String
    let stage: String
    var completed = false

    static var samples: [Self] { [
        Self(id: "sample-task-website", title: "Check the homepage on mobile", domain: "Website", owner: "You", schedule: "Today", source: "Existing task · sample", finishLine: "Check the headline, primary CTA, and navigation at phone width. Record any changes needed.", stage: "Planning"),
        Self(id: "sample-task-review", title: "Review the revised launch copy", domain: "Website", owner: "You", schedule: "Unscheduled", source: "Manually captured · sample", finishLine: "Review the draft and record requested edits. Publication is a separate decision.", stage: "Review"),
        Self(id: "sample-task-complete", title: "Confirm the launch checklist", domain: "Website", owner: "You", schedule: "Unscheduled", source: "Existing task · sample", finishLine: "Check every launch checklist item.", stage: "Planning", completed: true)
    ] }
}

struct Control2FoundationView: View {
    var showTaskExamples = false
    @ObservedObject var handoffStore: WorkHandoffStore
    var onOpenSession: (String) -> Void = { _ in }
    private var previewTasks: [Control2PreviewTask] { handoffStore.previewTasks }
    private var selectedTaskID: String? {
        get { handoffStore.selectedWorkID }
        nonmutating set { handoffStore.selectedWorkID = newValue }
    }
    @State private var workFilter = "All work"
    private let workFilters = ["All work", "Tasks", "Meeting follow-up", "Completed"]
    private var selectedTask: Control2PreviewTask? {
        guard showTaskExamples else { return nil }
        return previewTasks.first { $0.id == selectedTaskID }
    }
    private var filteredTasks: [Control2PreviewTask] {
        guard showTaskExamples, workFilter != "Meeting follow-up" else { return [] }
        return previewTasks.filter { workFilter == "Completed" ? $0.completed : !$0.completed }
    }
    private var showsMeetings: Bool { !showTaskExamples || workFilter == "All work" || workFilter == "Meeting follow-up" }

    @StateObject private var model = Control2FoundationModel()
    @State private var diagnosticsOpen = false
    @State private var testControlsOpen = false
    private var selected: Control2FoundationSnapshot.Work? { model.snapshot?.work.first { $0.id == model.selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(showTaskExamples ? "Your work, in one place" : "From meeting to review").font(COSType.display(27, weight: .medium))
                    Text(showTaskExamples ? "Keep your tasks. Add context, prepared drafts, and decisions as work grows." : "Review the request, prepare a draft, and decide what comes next.")
                        .font(COSType.body(12)).foregroundStyle(COSPalette.muted)
                }
                Spacer(minLength: 16)
                if model.busy { ProgressView().controlSize(.small).help(model.operation) }
                Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(COSQuietButtonStyle()).disabled(model.busy)
            }.padding(20)
            HStack(spacing: 8) {
                Image(systemName: "flask").foregroundStyle(COSPalette.accent)
                Text("Test workspace").font(COSType.body(11.5, weight: .semibold))
                Text(showTaskExamples ? "Sample tasks and meetings. Task changes stay in this preview; automatic work and publishing are off." : "Sample meetings only. Automatic work and publishing are off.")
                    .font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
                Spacer(minLength: 0)
            }.padding(.horizontal, 20).padding(.vertical, 10).background(COSPalette.raised)
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(COSType.body(12)).foregroundStyle(COSPalette.danger)
                    .textSelection(.enabled).padding(14)
            }
            HStack(alignment: .top, spacing: 0) {
                workList.frame(width: 255)
                Rectangle().fill(COSPalette.line).frame(width: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let selectedTask { taskDetail(selectedTask) }
                        else if showsMeetings, let selected { detail(selected) }
                        else if !showsMeetings {
                            Text("No tasks in this view").font(COSType.display(22))
                            Text("Choose another view to see the sample work.").foregroundStyle(COSPalette.muted)
                        }
                        else {
                            Text("Your next review starts here").font(COSType.display(22))
                            Text("Load the sample meeting to explore how follow-up work will appear in COS.")
                                .foregroundStyle(COSPalette.muted)
                            Button("Load sample meeting") { Task { selectedTaskID = nil; workFilter = "Meeting follow-up"; await model.replay(revision: "1") } }
                                .buttonStyle(COSPrimaryButtonStyle()).disabled(model.busy || model.snapshot == nil)
                        }
                    }.frame(maxWidth: 740, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(22)
                }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }.frame(minHeight: 0, maxHeight: .infinity)
            Divider().overlay(COSPalette.line)
            DisclosureGroup("Test controls", isExpanded: $testControlsOpen) {
                HStack(spacing: 10) {
                    Button("Replay sample") { Task { selectedTaskID = nil; workFilter = "Meeting follow-up"; await model.replay(revision: "1") } }
                    Button("Replay correction") { Task { selectedTaskID = nil; workFilter = "Meeting follow-up"; await model.replay(revision: "2") } }
                    Spacer(minLength: 0)
                    Text("Replaying the same revision does not duplicate work.")
                        .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
                }.buttonStyle(COSQuietButtonStyle()).disabled(model.busy || model.snapshot == nil).padding(.top, 8)
            }.font(COSType.body(11.5, weight: .medium)).tint(COSPalette.accent).padding(14)
        }
        .font(COSType.body(13)).foregroundStyle(.primary)
        .background(COSPalette.panel).tint(COSPalette.accent)
        .task {
            if let task = selectedTask, task.completed { workFilter = "Completed" }
            await model.refresh()
            if let workID = handoffStore.selectedWorkID, model.snapshot?.work.contains(where: { $0.id == workID }) == true {
                model.selectedID = workID
                workFilter = "Meeting follow-up"
            }
        }
    }

    private var workList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if showTaskExamples {
                    ForEach(workFilters, id: \.self) { filter in
                        Button { selectFilter(filter) } label: {
                            HStack {
                                Text(filter).font(COSType.body(12, weight: workFilter == filter ? .semibold : .regular))
                                Spacer()
                                if workFilter == filter { Image(systemName: "chevron.right").font(.system(size: 9)) }
                            }.padding(.vertical, 7).padding(.horizontal, 9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .background(workFilter == filter ? COSPalette.raised : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).accessibilityAddTraits(workFilter == filter ? .isSelected : [])
                    }
                    Divider().padding(.vertical, 5)
                    if !filteredTasks.isEmpty {
                        Text(workFilter == "Completed" ? "Completed tasks" : "Tasks").font(COSType.body(12, weight: .semibold))
                    }
                    ForEach(filteredTasks) { task in
                        Button { selectedTaskID = task.id } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Label(task.title, systemImage: task.completed ? "checkmark.circle" : "checklist")
                                    .font(COSType.body(12.5, weight: .semibold)).multilineTextAlignment(.leading)
                                Text(task.completed ? "Completed" : "\(task.stage) · \(task.schedule)")
                                    .font(COSType.body(11)).foregroundStyle(COSPalette.accent)
                                Text("\(task.domain) · \(task.owner)").font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .background(selectedTaskID == task.id ? COSPalette.raised : COSPalette.card, in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(selectedTaskID == task.id ? COSPalette.gold : COSPalette.line, lineWidth: 1))
                        }.buttonStyle(.plain).accessibilityAddTraits(selectedTaskID == task.id ? .isSelected : [])
                    }
                }
                if showsMeetings {
                Text("Meeting follow-up").font(COSType.body(12, weight: .semibold)).padding(.bottom, 4)
                ForEach(model.snapshot?.work ?? []) { item in
                    Button { selectedTaskID = nil; model.selectedID = item.id } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(displayTitle(item)).font(COSType.body(13, weight: .semibold))
                                .lineLimit(3).multilineTextAlignment(.leading)
                            Text(statusLabel(item)).font(COSType.body(11, weight: .medium))
                                .foregroundStyle(item.status == "blocked" ? COSPalette.danger : COSPalette.accent)
                            Text("Revision \(item.revision)").font(COSType.mono(10)).foregroundStyle(COSPalette.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(13)
                            .contentShape(Rectangle())
                            .background((!showTaskExamples || selectedTaskID == nil) && model.selectedID == item.id ? COSPalette.raised : COSPalette.card)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9)
                                .stroke((!showTaskExamples || selectedTaskID == nil) && model.selectedID == item.id ? COSPalette.gold : COSPalette.line, lineWidth: 1))
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(displayTitle(item)), \(statusLabel(item)), revision \(item.revision)")
                        .accessibilityAddTraits((!showTaskExamples || selectedTaskID == nil) && model.selectedID == item.id ? .isSelected : [])
                }
                if model.snapshot?.work.isEmpty == true {
                    Text("No work to review yet.").font(COSType.body(12)).foregroundStyle(COSPalette.muted)
                }
                }
            }.padding(16)
        }.background(COSPalette.panel)
    }

    private func selectFilter(_ filter: String) {
        workFilter = filter
        selectedTaskID = filteredTasks.first?.id
    }

    @ViewBuilder private func taskDetail(_ task: Control2PreviewTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.title).font(COSType.display(23, weight: .medium))
            Text("Task · \(task.completed ? "Completed" : task.stage)").font(COSType.body(12, weight: .medium)).foregroundStyle(COSPalette.accent)
        }
        HStack(alignment: .top, spacing: 32) {
            taskFact("Owner", task.owner)
            taskFact("Schedule", task.schedule)
            taskFact("Project", task.domain)
        }
        packetSection("Done when", task.finishLine)
        packetSection("Where this came from", task.source)
        VStack(alignment: .leading, spacing: 12) {
            Text("The same task, inside Work").font(COSType.display(19, weight: .medium))
            Text("Existing tasks keep their task actions. On glasses, this remains a task in the Tasks view. Meeting follow-up sits alongside it, with its own draft and review steps.")
                .font(COSType.body(12)).foregroundStyle(COSPalette.muted)
            Button(task.completed ? "Reopen sample task" : "Complete sample task") {
                if let index = previewTasks.firstIndex(where: { $0.id == task.id }) {
                    handoffStore.previewTasks[index].completed.toggle()
                    workFilter = previewTasks[index].completed ? "Completed" : "Tasks"
                }
            }.buttonStyle(COSPrimaryButtonStyle())
            Text("Demo only. This changes the sample in this window and stays while you move between Work and Sessions; it resets when you restart the preview.")
                .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(COSPalette.line, lineWidth: 1))
        WorkHandoffView(store: handoffStore, source: WorkSource(id: task.id, title: task.title, revision: "preview-1", project: task.domain, context: "Task: \(task.title)\nDone when: \(task.finishLine)\nSource: \(task.source)"), isPreview: true, onOpenSession: onOpenSession)
        packetSection("Context as work grows", "A task can link to its meeting, relevant memories, and prior sessions. Prepared output and execution history belong here. Those connections are the next build step; the samples do not retrieve your real context.")
        Label("Completing a task does not approve or publish a draft.", systemImage: "lock")
            .font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
    }

    private func taskFact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
            Text(value).font(COSType.body(12, weight: .medium))
        }
    }

    @ViewBuilder private func detail(_ item: Control2FoundationSnapshot.Work) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(displayTitle(item)).font(COSType.display(23, weight: .medium))
            HStack(spacing: 8) {
                Text(statusLabel(item)).foregroundStyle(COSPalette.accent)
                Text("· Revision \(item.revision)").foregroundStyle(COSPalette.muted)
            }.font(COSType.body(11.5, weight: .medium))
        }
        if showTaskExamples, item.status != "superseded" {
            WorkHandoffView(store: handoffStore, source: WorkSource(id: item.id, title: item.title, revision: item.revision, project: item.projectId, context: "Meeting follow-up: \(item.title)\nSource: \(item.sourceExcerpt ?? "Sample meeting")\nDone when: \((item.criteria ?? []).joined(separator: "; "))"), isPreview: true, onOpenSession: onOpenSession)
        }
        if item.status == "superseded" {
            VStack(alignment: .leading, spacing: 9) {
                Label("A newer revision replaces this work.", systemImage: "arrow.triangle.2.circlepath")
                Text("This draft is kept as history. Continue with the latest request.")
                    .font(COSType.body(12)).foregroundStyle(COSPalette.muted)
                if let next = model.snapshot?.work.first(where: { $0.meetingId == item.meetingId && $0.projectId == item.projectId && $0.status != "superseded" }) {
                    Button("View current revision") { model.selectedID = next.id }.buttonStyle(COSQuietButtonStyle())
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 9))
        } else if item.status == "blocked" {
            Label("Waiting for a complete meeting before work can begin.", systemImage: "pause.circle")
                .foregroundStyle(COSPalette.muted)
        }
        if let excerpt = item.sourceExcerpt { packetSection("What was discussed", excerpt) }
        if let criteria = item.criteria, !criteria.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Text("What the work should accomplish").font(COSType.body(12, weight: .semibold))
                ForEach(Array(criteria.enumerated()), id: \.offset) { _, criterion in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "circle").font(.system(size: 7)).padding(.top, 5).foregroundStyle(COSPalette.muted)
                        Text(criterion).textSelection(.enabled)
                    }
                }
            }
        }
        VStack(alignment: .leading, spacing: 11) {
            Text(item.artifact == nil ? "Prepare a draft" : "Draft ready to review")
                .font(COSType.display(19, weight: .medium))
            Text("This preview prepares text copy. Website code, page layout, and production content are unchanged.")
                .font(COSType.body(12)).foregroundStyle(COSPalette.muted)
            if model.snapshot?.capabilities.manualDraft == true {
                Text("One draft attempt per test-server run. If the budget is used, quit and relaunch the preview to prepare another.")
                    .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
            }
            if let artifact = item.artifact {
                if item.status == "needs_review" {
                    Button { model.openPreview(artifact) } label: { Label("Open checked preview", systemImage: "arrow.up.right.square") }
                        .buttonStyle(COSPrimaryButtonStyle()).disabled(model.busy)
                }
                Label("Preview prepared. File integrity is checked when opened; website checks have not run.", systemImage: "doc.text")
                    .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
            } else if item.status == "needs_review", model.snapshot?.capabilities.manualDraft == true {
                Button { Task { await model.preparePreview(workID: item.id) } } label: {
                    Label(model.busy ? "Preparing preview…" : "Prepare text preview", systemImage: "doc.badge.gearshape")
                }.buttonStyle(COSPrimaryButtonStyle()).disabled(model.busy)
            } else if item.status == "needs_review" {
                Text("Text drafting is off for this test workspace.")
                    .font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(COSPalette.line, lineWidth: 1))
        DisclosureGroup("Technical details", isExpanded: $diagnosticsOpen) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Source: \(item.meetingId)\nProject: \(item.projectId)").font(COSType.mono(10)).textSelection(.enabled)
                if let artifact = item.artifact {
                    Text(artifact.path).font(COSType.mono(10)).textSelection(.enabled)
                    Text("SHA-256: \(artifact.sha256)").font(COSType.mono(10)).textSelection(.enabled)
                    ForEach(Array(artifact.checks.enumerated()), id: \.offset) { _, check in
                        Label(check.name, systemImage: check.passed ? "checkmark.circle" : "xmark.circle")
                            .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                    }
                }
                ForEach(model.snapshot?.gates ?? []) { gate in
                    Text("\(gate.id): \(gate.status)\n\(gate.detail)").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                }
            }.padding(.top, 10)
        }.font(COSType.body(11.5, weight: .medium))
    }

    private func displayTitle(_ item: Control2FoundationSnapshot.Work) -> String {
        item.meetingId == "foundation-native-sample" ? "Website follow-up · sample" : item.title
    }
    private func statusLabel(_ item: Control2FoundationSnapshot.Work) -> String {
        switch item.status {
        case "superseded": "Earlier revision"
        case "blocked": "Waiting for meeting"
        default: item.artifact == nil ? (model.snapshot?.capabilities.manualDraft == true ? "Ready to prepare" : "Captured for review") : "Ready for review"
        }
    }
    private func packetSection(_ heading: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(heading).font(COSType.body(12, weight: .semibold))
            Text(text).font(COSType.body(13)).lineSpacing(3).textSelection(.enabled)
        }
    }
}
