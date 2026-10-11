import Foundation
@main struct MeetingAskChecks {
    static func main() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) { precondition(value(), name); count += 1 }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cos-meeting-ask-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = MeetingAskDisk(root: root)
        let a = MeetingAskDisk.scope(server: "s1", pairing: "p1", session: "meeting-1")
        let b = MeetingAskDisk.scope(server: "s1", pairing: "p1", session: "meeting-2")
        check(a != b, "meeting identity")
        check(a != MeetingAskDisk.scope(server: "s2", pairing: "p1", session: "meeting-1"), "server identity")
        check(a != MeetingAskDisk.scope(server: "s1", pairing: "p2", session: "meeting-1"), "pairing identity")
        var record = MeetingAskLocalRecord(scope: a)
        record.draft = "Keep this before admission"
        try disk.write(record)
        let protection = try root.appendingPathComponent(a + ".json").resourceValues(forKeys: [.fileProtectionKey]).fileProtection
        check(protection == .completeUntilFirstUserAuthentication, "record stays writable while the Mac is locked (class C, not class B)")
        let loaded = try disk.read(a)
        check(loaded.draft == record.draft, "restart draft")
        let other = try disk.read(b)
        check(other.draft.isEmpty, "no leakage")
        let broken = root.appendingPathComponent(a + ".json")
        try Data("broken".utf8).write(to: broken)
        do { _ = try disk.read(a); preconditionFailure("corruption must fail closed") } catch { count += 1 }
        check(FileManager.default.fileExists(atPath: broken.path), "corrupt file retained")
        let raw = "# Meeting\n## Summary\nA summary\n## Full Transcript\n[MU] 1:02 original words\n### Aside\nMore speech\n## Decisions\nNo"
        let transcript = MeetingAskText.transcript(raw)
        check(!transcript.document && transcript.text == "[MU] 1:02 original words\n### Aside\nMore speech", "extract section without altering source")
        check(MeetingAskText.transcript("Bare spoken words").text == "Bare spoken words", "bare transcript")
        check(MeetingAskText.transcript("# Meeting\n## Summary\nNo transcript").document, "honest document fallback")
        check(MeetingAskText.transcript("# Meeting\n```\n## Transcript\n```\n## Summary\nNot speech").document, "fenced heading not transcript")
        check(MeetingAskText.safeURL("https://example.com/article") != nil, "public source")
        check(MeetingAskText.safeURL("file:///etc/passwd") == nil, "no local links")
        check(MeetingAskText.safeURL("https://secret@example.com") == nil, "no credential URL")
        check(MeetingAskText.safeURL("http://127.0.0.1/test") == nil, "no loopback URL")
        check(MeetingAskText.failure("model_unavailable").contains("settings"), "unavailable model has an actionable recovery")
        check(!MeetingAskText.failure("PRIVATE raw provider stderr").contains("PRIVATE"), "unknown failure does not expose provider output")
        let source = LiveAskSource(id: "T1", kind: "transcript", title: "Speaker", text: "Evidence")
        let exchange = MeetingAskExchange(requestId: "a", sessionId: "s", serverInstanceId: "i", action: "ask", question: "Who?", status: "completed", createdAt: "t", updatedAt: "t", selectedModel: .init(engine: "claude", model: "haiku"), answer: "Answer [T1]", sources: [source], notices: [], throughMs: 100, files: [])
        var next = exchange; next.requestId = "b"
        let oldFile = MeetingAskFile(id: "file-123", revision: "old", name: "Notes", status: "ready", text: "Original evidence")
        let newFile = MeetingAskFile(id: "file-123", revision: "new", name: "Notes", status: "ready", text: "Revised evidence")
        var pinned = exchange; pinned.files = [oldFile]
        var removed = oldFile; removed.status = "removed"; removed.text = ""
        let evidence = MeetingAskText.evidenceFiles(exchanges: [pinned, pinned], current: [removed, newFile])
        check(evidence.count == 2 && evidence[0].text == "Original evidence" && evidence[1].text == "Revised evidence", "export retains admitted revisions exactly once after replacement/removal")
        let full = MeetingAskText.fullContext(title: "Meeting", transcript: "Speech", exchanges: [exchange, next], files: [.init(id: "f", revision: "r", name: "Slide", status: "unsupported", text: "must not claim read")])
        check(full.contains("[Q1:T1]") && full.contains("[Q2:T1]"), "answer citations namespaced")
        check(full.contains("Text unavailable") && !full.contains("must not claim read"), "unread files honest")
        check(LiveTranscript.errorPollingAllowed(serverLive: 0, errorSince: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 299)), "error cap permits bounded retry")
        check(!LiveTranscript.errorPollingAllowed(serverLive: 0, errorSince: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 300)), "error cap stops at five minutes")
        check(LiveTranscript.errorPollingAllowed(serverLive: 1, errorSince: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 600)), "live recording unaffected")
        print("PASS Meeting Ask: \(count) checks")
    }
}
