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
            if !current.work.contains(where: { $0.id == selectedID }) { selectedID = current.work.first?.id }
        } catch {
            self.error = error.localizedDescription
            snapshot = nil // stale packets must never look current after a transport failure
        }
    }
}

@MainActor
final class Control2FoundationPresenter: ObservableObject {
    private var controller: NSWindowController?
    func show() {
        guard ProcessInfo.processInfo.environment["COS_CONTROL2_FOUNDATION"] == "1" else { return }
        if let controller { controller.showWindow(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentViewController: NSHostingController(rootView: Control2FoundationView()))
        window.title = "COS Control 2 · Foundation Lab"
        window.setContentSize(NSSize(width: 1080, height: 740))
        window.contentMinSize = NSSize(width: 850, height: 580)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        let controller = NSWindowController(window: window)
        self.controller = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct Control2FoundationView: View {
    @StateObject private var model = Control2FoundationModel()
    private var selected: Control2FoundationSnapshot.Work? { model.snapshot?.work.first { $0.id == model.selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Meetings become reviewable work").font(.title2.weight(.semibold))
                    Text("FOUNDATION LAB · DISPOSABLE DATA").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { Text(model.operation).font(.caption).foregroundStyle(.secondary); ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await model.refresh() } }.disabled(model.busy)
            }.padding(22)
            HStack {
                Label("Automatic execution off", systemImage: "pause.circle")
                Spacer()
                Label("Publication unavailable", systemImage: "lock")
            }.font(.callout).padding(.horizontal, 22).padding(.bottom, 18).foregroundStyle(.secondary)
            Divider()
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled).padding()
            }
            HSplitView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Meeting work").font(.headline).padding(.horizontal)
                    List(model.snapshot?.work ?? [], selection: $model.selectedID) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title).font(.headline).lineLimit(2)
                            Text(item.status.replacingOccurrences(of: "_", with: " ").capitalized).foregroundStyle(item.status == "blocked" ? Color.orange : Color.secondary)
                            Text("Revision \(item.revision) · \(item.projectId)").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 6).tag(item.id)
                    }.overlay {
                        if model.snapshot?.work.isEmpty == true { Text("Replay the sample to create your first packet.").foregroundStyle(.secondary).padding() }
                    }
                }.padding(.top, 18).frame(minWidth: 270, idealWidth: 320)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let selected {
                            Text(selected.title).font(.title2.weight(.semibold))
                            Text("Source: \(selected.meetingId) · revision \(selected.revision)").font(.caption.monospaced()).textSelection(.enabled)
                            if let reason = selected.reason { Label(reason, systemImage: "info.circle").foregroundStyle(.secondary) }
                            if let excerpt = selected.sourceExcerpt { packetSection("Source excerpt", excerpt) }
                            if let criteria = selected.criteria, !criteria.isEmpty { packetSection("Operator-provided criteria", criteria.map { "• \($0)" }.joined(separator: "\n")) }
                            if let artifact = selected.artifact {
                                packetSection("Prepared text preview", artifact.path)
                                Text("Draft content for review. Website code and production pages are unchanged.").font(.caption).foregroundStyle(.secondary)
                                Button("Open checked preview") { model.openPreview(artifact) }.disabled(model.busy || selected.status != "needs_review")
                                Text("SHA-256: \(artifact.sha256)").font(.caption.monospaced()).textSelection(.enabled)
                                ForEach(Array(artifact.checks.enumerated()), id: \.offset) { _, check in
                                    Label(check.name, systemImage: check.passed ? "checkmark.circle" : "xmark.circle").foregroundStyle(check.passed ? Color.green : Color.orange)
                                }
                            } else { Text("No build output exists for this packet yet.").foregroundStyle(.secondary) }
                            if model.snapshot?.capabilities.manualDraft == true {
                                Button("Prepare text preview") { Task { await model.preparePreview(workID: selected.id) } }
                                    .disabled(model.busy || selected.status != "needs_review")
                            }
                            Divider()
                        } else {
                            Text("From meeting to decision").font(.title2.weight(.semibold))
                            Text("Test source readiness, duplicate replay, revision changes and durable review packets. This slice does not run builders or publish changes.").foregroundStyle(.secondary)
                        }
                        Text("Build gates").font(.headline)
                        ForEach(model.snapshot?.gates ?? []) { gate in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(gate.id) · \(gate.status)").font(.callout.weight(.semibold))
                                Text(gate.detail).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
                }.frame(minWidth: 450)
            }
            Divider()
            HStack {
                Button("Replay sample") { Task { await model.replay(revision: "1") } }
                Button("Replay correction") { Task { await model.replay(revision: "2") } }
                Spacer()
                Text("Synthetic meeting · isolated local server").font(.caption).foregroundStyle(.secondary)
            }.disabled(model.busy || model.snapshot == nil).padding(18)
        }.frame(minWidth: 850, minHeight: 580).task { await model.refresh() }
    }
    private func packetSection(_ heading: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(heading).font(.headline)
            Text(text).font(.body).textSelection(.enabled)
        }
    }
}
