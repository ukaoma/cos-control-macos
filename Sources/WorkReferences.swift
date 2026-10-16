import SwiftUI
import Foundation

/// 0.5.317: one reference session as bounded, read-only evidence: its title, summary (1,000 characters), and its recent
/// outputs and change counts since it was linked (1,500). The same for Work chat and a manual handoff.
struct WorkReferenceEvidence: Equatable {
    let id: String
    let title: String
    let summary: String
    let result: String
    var body: String { let text = [summary, result].filter { !$0.isEmpty }.joined(separator: "\n"); return text.isEmpty ? "No summary yet." : text }
    var text: String { WorkContextMeter.referenceText(title: title, body: body) }
}
typealias WorkReferenceFacts = @MainActor (_ sessionID: String, _ since: Double) -> (outputs: [String], changes: String?)?

/// 0.5.317 (Miles 2026-10-16 12:16): the sessions a card references, read-only. A reference link (WorkSessionLinks
/// references file) is never a send target, never part of the fence or the queue and never moves the card's stage; the
/// card's planner and new assignments may read its summary, outputs and change counts. Open and Unlink only.
struct WorkReferencesGroup: View {
    let rows: [WorkReferenceRow]
    @ObservedObject var handoffStore: WorkHandoffStore
    let workID: String
    let onOpenSession: (String) -> Void
    @State private var confirmUnlink: String?
    /// A reference's outputs (file names) and change counts since it was linked, for the planner. Nil when unknown.
    /// From the Connections session cards' meters, as cached; nil until read.
    static func liveFacts(_ sessionID: String, _ since: Double) -> (outputs: [String], changes: String?)? {
        facts(WorkSessionMeterStore.shared.snapshot(sessionID, since: since))
    }
    static func facts(_ snapshot: WorkSessionMeterSnapshot?) -> (outputs: [String], changes: String?)? {
        guard let snapshot else { return nil }
        let changes = snapshot.changes.map { "\($0.files) file\($0.files == 1 ? "" : "s"), +\($0.insertions) -\($0.deletions)" }
        return (snapshot.outputs.map(\.name), changes)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("References").font(COSType.body(13, weight: .semibold))
            Text("Read-only. COS may use these sessions' summaries, outputs and changes as context for this task. It never sends to them from here, and they never change this task's stage.")
                .font(COSType.body(11)).foregroundStyle(COSPalette.muted).fixedSize(horizontal: false, vertical: true)
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Text(row.provider.capitalized).font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                        Text(row.title).font(COSType.body(13, weight: .semibold)).lineLimit(2)
                        Spacer()
                        Text(handoffStore.confirmedSessionCards[row.id].map { _ in "Works on another task" } ?? "Reference")
                            .font(COSType.mono(10)).foregroundStyle(COSPalette.muted)
                    }
                    if let summary = row.session?.summary, !summary.isEmpty {
                        Text(String(summary.prefix(300))).font(COSType.body(11)).lineLimit(4).textSelection(.enabled)
                    }
                    WorkSessionMeterSections(store: WorkSessionMeterStore.shared, sessionID: row.id, since: row.link.at)
                    HStack {
                        Button(row.provider == "cursor" ? "Open Cursor Agents" : "Open " + row.provider.capitalized) { onOpenSession(row.id) }
                            .buttonStyle(COSTextButtonStyle())
                        if confirmUnlink == row.id {
                            Text("Remove this reference? The session and its other links stay.").font(COSType.body(11))
                            Button("Unlink") { if handoffStore.removeReference(sessionID: row.id, workID: workID) { confirmUnlink = nil } }
                                .buttonStyle(COSQuietButtonStyle()).accessibilityIdentifier("work-confirm-unlink-reference-" + row.id)
                            Button("Cancel") { confirmUnlink = nil }.buttonStyle(COSTextButtonStyle())
                        } else {
                            Button("Unlink") { confirmUnlink = row.id }.buttonStyle(COSTextButtonStyle())
                                .accessibilityIdentifier("work-unlink-reference-" + row.id)
                        }
                    }.disabled(handoffStore.busy)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
