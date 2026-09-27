import Foundation
import CryptoKit

@main struct Control2FoundationContract {
    @MainActor static func main() throws {
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
        print("PASS: foundation contract, fail-closed capabilities, source identity, correction fixture, checked preview containment/hash")
    }
}
