import SwiftUI

/// The server owns this per-capture setting. No local preference pretends to
/// disable matching when a server does not support the contract.
struct MeetingSpeakerPolicyView: View {
    @ObservedObject var model: ControllerModel
    let sessionId: String
    var recordId: String? = nil
    var sourceRevision: String? = nil
    @State private var mode = "standard"
    @State private var savedMode = "standard"
    @State private var revision: String?
    @State private var busy = false
    @State private var error: String?
    @State private var generation = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Voice identity").font(COSType.body(11, weight: .medium))
                Picker("Voice identity", selection: $mode) {
                    Text("Standard").tag("standard")
                    Text("High-confidence only").tag("high-confidence")
                    Text("Anonymous / video").tag("anonymous")
                }.labelsHidden().frame(maxWidth: 220).disabled(busy || revision == nil)
                Button(revision == "unreadable" ? "Repair settings" : "Apply") { Task { await save() } }.disabled(busy || revision == nil || (mode == savedMode && revision != "unreadable"))
                if busy { ProgressView().controlSize(.mini) }
            }
            Text("Applies to new audio in this recording. Strict modes keep transcription, skip automatic profile training, and never assume the wearer is speaking. Existing names need a speaker correction.")
                .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
            if let error { Text(error).font(COSType.body(11)).foregroundStyle(COSPalette.danger) }
            if revision == nil && !busy { Button("Retry voice settings") { Task { await load() } } }
        }.task(id: sessionId) { await load() }
    }

    private func load() async {
        let token = UUID(); generation = token; busy = true; revision = nil; error = nil
        defer { if generation == token { busy = false } }
        do {
            let response = try await model.runHelper(["meeting-speaker-policy", "--session", sessionId], timeout: 25)
            guard generation == token, !Task.isCancelled else { return }
            guard response.ok, let value = response.details["mode"]?.string,
                  ["standard", "high-confidence", "anonymous"].contains(value),
                  let next = response.details["revision"]?.string else {
                throw PolicyError.unavailable(response.message)
            }
            mode = value; savedMode = value; revision = next
            if next == "unreadable" { error = "Anonymous safe mode is active because these voice settings could not be read. " + (response.details["error"]?.string ?? "") + " Choose a mode and click Repair settings to save it deliberately." }
        } catch {
            if generation == token && !Task.isCancelled { self.error = "Voice settings unavailable: \(error.localizedDescription)" }
        }
    }

    private func save() async {
        guard !busy, let revision else { return }
        let token = generation; let selected = mode
        busy = true; error = nil
        defer { if generation == token { busy = false } }
        var args = ["meeting-speaker-policy", "--session", sessionId, "--mode", selected, "--policy-revision", revision]
        if let recordId { args += ["--record-id", recordId] }
        if let sourceRevision { args += ["--expected-revision", sourceRevision] }
        do {
            let response = try await model.runHelper(args, timeout: 25)
            guard generation == token, !Task.isCancelled else { return }
            guard response.ok, response.details["mode"]?.string == selected, let next = response.details["revision"]?.string else {
                throw PolicyError.unavailable(response.message)
            }
            savedMode = selected; self.revision = next
        } catch { if generation == token && !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private enum PolicyError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? { if case let .unavailable(message) = self { return message }; return nil }
    }
}
