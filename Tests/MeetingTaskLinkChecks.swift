import AppKit
import SwiftUI

@main @MainActor struct MeetingTaskLinkChecks {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        precondition(NSHomeDirectory().contains("cos-meeting-link-test"))
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let descriptor: [String: JSONValue] = ["recordId": .string("split:chosen"), "domain": .string("quilt"),
            "month": .string("2026-10"), "filename": .string("2026-10-07_Promo.md"), "title": .string("Scotch promo review")]
        let reference = WorkMeetingReference(.object(descriptor))!
        let meeting = reference.libraryMeeting!
        func task(_ id: String, domain: String = "quilt", revision: String = "rev-before", checked: Bool = false, refs: [JSONValue] = []) -> TaskRow {
            TaskRow(.object(["id": .string(id), "domain": .string(domain), "title": .string("Review promotion"),
                "text": .string("Review promotion and demand channels"), "workIdentity": .string(id), "checked": .bool(checked),
                "workRevision": .string(revision), "meetingRefs": .array(refs)]))!
        }
        let chosen = task("chosen"), unrelated = task("other", domain: "personal")
        let linked = task("linked", refs: [reference.jsonValue]), completed = task("complete", checked: true)
        precondition(MeetingTaskLinkOptions.rows([chosen, unrelated, completed], query: "demand quilt", includeCompleted: false).map(\.id) == ["chosen"])
        precondition(MeetingTaskLinkOptions.rows([completed], query: "", includeCompleted: true).count == 1)
        precondition(MeetingTaskLinkOptions.rows([completed], query: "", includeCompleted: false).isEmpty)
        precondition(MeetingTaskLinkOptions.refusal(linked, meeting: reference) == "Already linked")
        precondition(MeetingTaskLinkOptions.refusal(task("stale", revision: ""), meeting: reference) != nil)
        precondition(MeetingTaskLinkOptions.refusal(chosen, meeting: reference) == nil)
        let before = WorkSource.taskSnapshot(chosen)
        let after = WorkSource.taskSnapshot(task("chosen", refs: [reference.jsonValue]))
        precondition(before.id == after.id && before.revision != after.revision && after.context.contains("split:chosen"))
        print("PASS: search, completed filter, duplicate/stale guards and task context revision")

        // The real model writes the exact task snapshot and canonical meeting; it never creates a task.
        let payload = "{\"ok\":true,\"message\":\"saved\",\"details\":{\"tasks\":[],\"complete\":true,\"capabilities\":{\"version\":1,\"writable\":true}}}"
        let script = "#!/bin/sh\nif [ \"$1\" = work-link-meeting ]; then /bin/cat > \"$0.request\"; fi\n/usr/bin/printf '%s\\n' '" + payload + "'\n"
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let model = ControllerModel(startBackgroundWork: false, helper: HelperClient(executableOverride: helper))
        model.workBoardWritable = true
        try await model.linkWorkMeeting(chosen, meeting: reference)
        let sent = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: helper.path + ".request"))) as! [String: Any]
        precondition(sent["id"] as? String == chosen.id && sent["domain"] as? String == chosen.domain)
        precondition(sent["expectedRevision"] as? String == "rev-before" && sent["expectedText"] as? String == chosen.text)
        precondition((sent["meeting"] as? [String: String]) == reference.json)
        let refusal = "#!/bin/sh\n/usr/bin/printf '%s\\n' '{\"ok\":false,\"message\":\"Task changed; refresh before linking\",\"details\":{}}'\n"
        try refusal.write(to: helper, atomically: true, encoding: .utf8)
        do { try await model.linkWorkMeeting(chosen, meeting: reference); preconditionFailure("A refused write must not report success") }
        catch { precondition(error.localizedDescription.contains("Task changed")) }
        print("PASS: canonical link payload and stale-write refusal propagation")

        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Render through a private, never-shown window; the fixture does not contact a server.
        try script.write(to: helper, atomically: true, encoding: .utf8)
        let host = NSHostingView(rootView: MeetingTaskLinkSheet(model: model, meeting: meeting))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 668, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(20)) }
        model.workTasks = [chosen, unrelated, linked, completed]; model.workTasksComplete = true
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded() }
            host.displayIfNeeded()
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(appearance == .aqua ? "meeting-task-link-light.png" : "meeting-task-link-dark.png"))
        }
        window.close()
        print("PASS: isolated light/dark picker render")
    }
}
