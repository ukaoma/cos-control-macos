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
        let secondLink = task("second-linked", refs: [reference.jsonValue])
        let multi = MeetingWorkConnections.tasks(recordIds: [reference.recordId], from: [linked, secondLink, completed, unrelated])
        precondition(Set(multi.map(\.id)) == ["linked", "second-linked"], "A meeting can link to more than one task")
        precondition(MeetingWorkConnections.tasks(recordIds: ["other-record"], from: [linked]).isEmpty, "Titles or search matches never establish a link")
        precondition(MeetingWorkConnections.tasks(recordIds: ["raw-source", reference.recordId, reference.recordId], from: [linked]).count == 1, "Merged and raw identities must not duplicate a task")
        precondition(WorkSource.taskSnapshot(linked).context.contains(reference.recordId), "The agent handoff must carry the same canonical relationship shown in Speakers")
        print("PASS: search, multiple canonical links, duplicate/stale guards and agent context")

        // The real model writes the exact task snapshot and canonical meeting; it never creates a task.
        let payload = "{\"ok\":true,\"message\":\"saved\",\"details\":{\"tasks\":[],\"complete\":true,\"capabilities\":{\"version\":1,\"writable\":true}}}"
        let script = "#!/bin/sh\nif [ \"$1\" = work-link-meeting ]; then /bin/cat > \"$0.request\"; fi\n/usr/bin/printf '%s\\n' '" + payload + "'\n"
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let model = ControllerModel(startBackgroundWork: false, helper: HelperClient(executableOverride: helper))
        model.domainOptions = [DomainOption(.object(["name": .string("quilt")]))!]
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

        let createScript = """
        #!/bin/sh
        if [ "$1" = work-create-meeting-task ]; then
          /bin/cat > "$0.create-request"
          /usr/bin/printf '%s\\n' '{"ok":true,"message":"saved","details":{"linked":true,"id":"aaaaaaaaaaaa","workID":"task:quilt:aaaaaaaaaaaa"}}'
        else
          /usr/bin/printf '%s\\n' '\(payload)'
        fi

        """
        try createScript.write(to: helper, atomically: true, encoding: .utf8)
        let created = try await model.createMeetingTask(domain: "quilt", text: "Prepare bookings data", meeting: reference)
        precondition(created == "task:quilt:aaaaaaaaaaaa")
        let createSent = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: helper.path + ".create-request"))) as! [String: Any]
        precondition(Set(createSent.keys) == ["domain", "text", "meeting"])
        precondition(createSent["text"] as? String == "Prepare bookings data" && (createSent["meeting"] as? [String: String]) == reference.json)
        try refusal.write(to: helper, atomically: true, encoding: .utf8)
        do { _ = try await model.createMeetingTask(domain: "quilt", text: "Keep this draft", meeting: reference); preconditionFailure("Refused creation cannot report success") }
        catch { precondition(error.localizedDescription.contains("Task changed")) }
        print("PASS: one-write meeting creation payload, exact saved identity and refusal propagation")

        // Exercise the real cache loader with corrected evidence and out-of-order reads.
        let peopleInput = URL(fileURLWithPath: helper.path + ".people-input")
        let peopleStarted = URL(fileURLWithPath: helper.path + ".people-started")
        let peopleHelper = "#!/usr/bin/python3\nimport json,time,pathlib\np=pathlib.Path(__file__)\nv=json.loads(pathlib.Path(str(p)+'.people-input').read_text())\npathlib.Path(str(p)+'.people-started').write_text('started')\ntime.sleep(v.pop('delay',0))\nprint(json.dumps(v))\n"
        try peopleHelper.write(to: helper, atomically: true, encoding: .utf8)
        func peopleResponse(_ names: [String], delay: Double = 0, record: String? = nil) throws {
            let body: [String: Any] = ["ok": true, "message": "fixture", "delay": delay,
                "details": ["recordId": record ?? reference.recordId, "attendees": names, "actionItems": []]]
            try JSONSerialization.data(withJSONObject: body).write(to: peopleInput)
        }
        try peopleResponse(["False Match"])
        await model.loadWorkMeetingPeople(reference)
        precondition(model.workMeetingPeople[reference.recordId]?.people == ["False Match"])
        try peopleResponse(["Verified Person"])
        await model.retryWorkMeetingPeople(reference)
        precondition(model.workMeetingPeople[reference.recordId]?.people == ["Verified Person"], "Refresh replaces successful cached people")
        try? FileManager.default.removeItem(at: peopleStarted)
        try peopleResponse(["Stale Person"], delay: 0.6)
        let oldRead = Task { await model.loadWorkMeetingPeople(reference, force: true) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: peopleStarted.path) { try await Task.sleep(for: .milliseconds(10)) }
        precondition(FileManager.default.fileExists(atPath: peopleStarted.path))
        try peopleResponse(["Latest Person"])
        await model.retryWorkMeetingPeople(reference)
        await oldRead.value
        precondition(model.workMeetingPeople[reference.recordId]?.people == ["Latest Person"], "Older in-flight read must not restore false names")
        try peopleResponse(["Wrong Meeting Person"], record: "other-record")
        await model.retryWorkMeetingPeople(reference)
        precondition(model.workMeetingPeople[reference.recordId] == nil && model.workMeetingPeopleFailed.contains(reference.recordId), "Wrong meeting cannot provide task people")
        print("PASS: task people refresh, older read fencing and canonical-record refusal")

        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Render through a private, never-shown window; the fixture does not contact a server.
        try script.write(to: helper, atomically: true, encoding: .utf8)
        var openedTask: String?
        let host = NSHostingView(rootView: MeetingTaskLinkSheet(model: model, meeting: meeting, onOpenWork: { openedTask = $0 }))
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
        // SwiftUI's accessibility tree is not exposed by a never-shown hosting window.
        // Full Open task activation and return navigation remain candidate app acceptance gates.
        let createHost = NSHostingView(rootView: MeetingTaskLinkSheet(model: model, meeting: meeting, initiallyCreating: true))
        window.contentView = createHost
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for _ in 0..<20 { try await Task.sleep(for: .milliseconds(20)); createHost.layoutSubtreeIfNeeded() }
            let rep = createHost.bitmapImageRepForCachingDisplay(in: createHost.bounds)!
            createHost.cacheDisplay(in: createHost.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(appearance == .aqua ? "meeting-task-create-light.png" : "meeting-task-create-dark.png"))
        }
        window.close()
        try await runWorkInputChecks(root: output)
        print("PASS: isolated light/dark picker render with already-linked Open task controls")
    }
}
