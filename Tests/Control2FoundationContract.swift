import Foundation
import CryptoKit

@main struct Control2FoundationContract {
    @MainActor static func main() async throws {
        runControl2ActivityIntegrationChecks()
        let valid = #"{"schemaVersion":1,"enabled":true,"mode":"foundation","capabilities":{"publication":false,"automaticExecution":false},"work":[{"id":"work-1","meetingId":"m1","projectId":"p1","revision":"1","status":"needs_review","title":"Review","createdAt":"2026-09-27","updatedAt":"2026-09-27","sourceExcerpt":"Operator request","criteria":["Mobile layout"]}],"gates":[{"id":"publication","status":"unrun","detail":"No publication capability"}]}"#
        let decoded = try Control2FoundationSnapshot.decode(Data(valid.utf8))
        precondition(decoded.work[0].sourceExcerpt == "Operator request")
        precondition(decoded.work[0].artifact == nil)
        for invalid in [valid.replacingOccurrences(of: "\"publication\":false", with: "\"publication\":true"), valid.replacingOccurrences(of: "\"automaticExecution\":false", with: "\"automaticExecution\":true"), valid.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2"), valid.replacingOccurrences(of: "needs_review", with: "published"), valid.replacingOccurrences(of: "\"enabled\":true", with: "\"enabled\":false")] {
            do { _ = try Control2FoundationSnapshot.decode(Data(invalid.utf8)); fatalError("Unsafe contract accepted") } catch { }
        }
        let first = Control2FoundationReplay.sample()
        let correction = Control2FoundationReplay.sample(revision: "2")
        precondition(first.meetingId == correction.meetingId && first.projectId == correction.projectId)
        precondition(first.revision != correction.revision && first.transcript != correction.transcript)
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first))
        precondition(payload is [String: Any])
        let root = URL(fileURLWithPath: "/tmp/cos-control2-preview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let html = Data("<html>Checked draft</html>".utf8)
        let file = root.appendingPathComponent("preview.html")
        try html.write(to: file)
        let digest = SHA256.hash(data: html).map { String(format: "%02x", $0) }.joined()
        let artifact = Control2FoundationSnapshot.Work.Artifact(path: file.path, sha256: digest, kind: "preview", checks: [])
        _ = try Control2FoundationModel.verifiedPreviewURL(artifact, environment: ["COS_CONTROL_TEST_HOME": root.path])
        try Data("changed".utf8).write(to: file)
        do { _ = try Control2FoundationModel.verifiedPreviewURL(artifact, environment: ["COS_CONTROL_TEST_HOME": root.path]); fatalError("Changed preview accepted") } catch { }
        do { _ = try Control2FoundationModel.verifiedPreviewURL(artifact, environment: ["COS_CONTROL_TEST_HOME": "/tmp/other-root"]); fatalError("Outside preview accepted") } catch { }
        try await modelBehaviorChecks()
        print("PASS: foundation contract, fail-closed capabilities, source identity, correction fixture, checked preview containment/hash")
    }

    /// Exercise the real helper transport and model transitions with a disposable
    /// executable. No production helper, server, provider or browser is involved.
    @MainActor private static func modelBehaviorChecks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cos-control2-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fixture-helper")
        let script = #"""
        #!/bin/sh
        ROOT=$(/usr/bin/dirname "$0")
        printf '%s\n' "$*" >> "$ROOT/calls"
        if [ "$1" = foundation-replay ]; then /bin/cat > "$ROOT/payload.json"; fi
        if [ -f "$ROOT/fail" ]; then printf 'invalid fixture response'; exit 1; fi
        /bin/cat "$ROOT/reply.json"
        """# + "\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let model = Control2FoundationModel(helper: HelperClient(executableOverride: executable))
        func row(_ id: String, _ revision: String, _ status: String = "needs_review") -> [String: Any] {
            ["id": id, "meetingId": "foundation-native-sample", "projectId": "foundation-website",
             "revision": revision, "status": status, "title": "Synthetic review", "createdAt": "2026-09-27",
             "updatedAt": "2026-09-27", "sourceExcerpt": "Synthetic evidence", "criteria": ["Synthetic criterion"]]
        }
        func reply(_ rows: [[String: Any]], manualDraft: Bool = true) throws {
            let packet: [String: Any] = ["schemaVersion": 1, "enabled": true, "mode": "foundation",
                "capabilities": ["publication": false, "automaticExecution": false, "manualDraft": manualDraft],
                "work": rows, "gates": []]
            let envelope: [String: Any] = ["ok": true, "message": "fixture", "details": packet]
            try JSONSerialization.data(withJSONObject: envelope).write(to: root.appendingPathComponent("reply.json"))
        }
        func calls() throws -> [String] {
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent("calls").path) else { return [] }
            return try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8).split(separator: "\n").map(String.init)
        }

        func checkCalls(_ predicate: ([String]) -> Bool, _ message: String = "Unexpected helper commands") throws {
            let actual = try calls()
            precondition(predicate(actual), message)
        }

        try reply([row("work-1", "1")])
        await model.refresh()
        precondition(model.selectedID == "work-1" && model.snapshot?.work.count == 1 && model.error == nil)
        try reply([row("work-2", "2"), row("work-1", "1", "superseded")])
        await model.replay(revision: "2")
        precondition(model.selectedID == "work-2", "Correction must select current work, not the historical selection")
        precondition(model.snapshot?.work.first(where: { $0.id == "work-1" })?.status == "superseded")
        let payload = try JSONDecoder().decode(Control2FoundationReplay.self, from: Data(contentsOf: root.appendingPathComponent("payload.json")))
        precondition(payload.revision == "2" && payload.meetingId == "foundation-native-sample")
        try checkCalls { $0 == ["foundation-status", "foundation-replay"] }

        let beforeSuperseded = try calls().count
        await model.preparePreview(workID: "work-1")
        try checkCalls({ $0.count == beforeSuperseded }, "Superseded work must not dispatch a helper")
        // Positive control makes the no-dispatch assertions meaningful.
        await model.preparePreview(workID: "work-2")
        try checkCalls { $0.last == "foundation-draft --work-id work-2" }

        try reply([row("work-2", "2")], manualDraft: false)
        await model.refresh()
        let beforeDisabled = try calls().count
        await model.preparePreview(workID: "work-2")
        try checkCalls({ $0.count == beforeDisabled }, "Absent capability must prevent helper dispatch")

        try reply([row("work-3", "3", "blocked")])
        await model.refresh()
        precondition(model.selectedID == "work-3", "Missing selection must reconcile to the remaining work")
        let beforeBlocked = try calls().count
        await model.preparePreview(workID: "work-3")
        try checkCalls({ $0.count == beforeBlocked }, "Blocked work must not dispatch a helper")

        try Data().write(to: root.appendingPathComponent("fail"))
        await model.refresh()
        precondition(model.snapshot == nil && model.error != nil && !model.busy && model.operation.isEmpty,
                     "Transport failure must clear stale packets and restore idle state")
        let beforeFailureDispatch = try calls().count
        await model.preparePreview(workID: "work-3")
        try checkCalls({ $0.count == beforeFailureDispatch }, "A stale selection after failure must not dispatch")
        print("PASS: real helper model transitions, correction selection, capability/status denial, transport failure clears stale state")
    }
}
