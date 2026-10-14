import AppKit
import Foundation

@main struct WorkTaskContextChecks {
    @MainActor static func main() throws {
        let row = TaskRow(.object([
            "id": .string("mutable-row"), "domain": .string("quilt"), "workIdentity": .string("420a0114f1a9"),
            "workRevision": .string(String(repeating: "a", count: 64)), "workStage": .string("qa"),
            "title": .string("Truncated lens title"), "text": .string("**Full task** with `code`, quotes \" and ``` fences\nDo not run $(touch /tmp/nope)."),
            "doneWhen": .string("Checked against source"), "owner": .string("Miles"), "source": .string("Manual entry 2026-10-13"),
            "meetingRefs": .array([.object(["recordId": .string("ops:quilt:2026-10:call.md"), "domain": .string("quilt"),
                "month": .string("2026-10"), "filename": .string("call.md"), "title": .string("Linked meeting")])])
        ]))!
        let text = try WorkTaskContext.text(row)
        precondition(text.contains("Work ID: task:quilt:420a0114f1a9"), "Uses canonical Work ID, not mutable row ID")
        precondition(text.contains("--work-id 'task:quilt:420a0114f1a9'"), "Every command resolves canonical identity")
        let block = text.components(separatedBy: "```json\n")[1].components(separatedBy: "\n```")[0]
        let snapshot = try JSONSerialization.jsonObject(with: Data(block.utf8)) as! [String: Any]
        precondition(snapshot["taskText"] as? String == row.text, "Full text survives quotes, code and fences")
        precondition(snapshot["rowIDAtCopy"] as? String == row.id, "Mutable ID is labeled as a snapshot")
        precondition(snapshot["writerRevisionAtCopy"] as? String == row.workRevision, "Actual CAS snapshot retained")
        precondition(snapshot["displaySnapshotHash"] as? String != row.workRevision, "Snapshot digest not passed off as writer CAS")
        precondition(snapshot["doneWhen"] as? String == row.doneWhen && snapshot["stage"] as? String == "qa", "Actual finish line and stage")
        let refs = snapshot["confirmedMeetingReferences"] as! [[String: String]]
        precondition(refs.count == 1 && refs[0]["recordId"] == row.meetingRefs[0].recordId, "Canonical references preserved")
        precondition(text.components(separatedBy: "```").count == 3, "Task prose cannot escape evidence fence")
        precondition(text.contains("A copied task does not link, create, or start a session by itself."), "No fake automatic linkage")
        precondition(text.contains("When the user requests a board change, re-read work-context"), "No copied-stale stage writes")
        precondition(text.contains("Move to Complete only when the user asks"), "Completion remains a user decision")
        precondition(!text.contains("--expected-revision '" + row.workRevision + "'"), "Instructions never reuse stale copied CAS")
        precondition(WorkTaskContext.shellArgument("a'b$(x)`z`") == "'a'\"'\"'b$(x)`z`'", "Command arguments remain shell literals")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        _ = try WorkTaskClipboard.copy(row, context: false, to: pasteboard)
        precondition(pasteboard.string(forType: .string) == row.workSourceID, "Actual Copy task ID write")
        _ = try WorkTaskClipboard.copy(row, context: true, to: pasteboard)
        precondition(pasteboard.string(forType: .string) == text, "Actual Copy context write")
        let malformed = TaskRow(.object(["id": .string("bad"), "domain": .string("quilt"), "workIdentity": .string("bad\nidentity")]))!
        precondition(!WorkTaskContext.canExport(malformed), "Bad canonical identity refused")
        do { _ = try WorkTaskClipboard.copy(malformed, context: false, to: pasteboard); preconditionFailure("Bad ID copied") }
        catch { precondition(pasteboard.string(forType: .string) == text, "Refusal preserves clipboard") }
        precondition(row.workStage == "qa" && row.workRevision == String(repeating: "a", count: 64), "Copy performs no task mutation")
        print("PASS: Work task context (20 assertions): canonical ID, JSON source grounding, current-CAS instructions, shell arguments and private clipboard")
    }
}
