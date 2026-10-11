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
        // 0.5.281: the Ask composer is an attachment target (MeetingAskComposerIntake), and rule C.
        typealias Intake = MeetingAskComposerIntake
        let shot = "/var/folders/x1/T/TemporaryItems/NSIRD_screencaptureui_ab12/Screenshot 2026-10-10 at 7.23.21 PM.png"
        let notes = "/Users/fixture/Desktop/notes.txt"
        let existing: Set<String> = [shot, notes, "/Users/fixture/Desktop/my notes.txt", "/Users/fixture/a.txt"]
        let isFile: (String) -> Bool = { existing.contains($0) }
        let shotURL = URL(fileURLWithPath: shot)
        check(Intake.route(types: ["public.file-url", "public.utf8-plain-text"], fileURLs: [shotURL], text: shot, draft: "", isFile: isFile) == .attachFiles([shotURL]),
              "composer drop of a file attaches it, even with its path offered as text")
        check(Intake.route(types: ["public.file-url"], fileURLs: [shotURL], text: nil, draft: "What changed?", isFile: isFile) == .attachFiles([shotURL]),
              "a file dropped after words still attaches, never types its path")
        check(Intake.route(types: ["public.png"], fileURLs: [], text: nil, draft: "", isFile: isFile) == .attachImage,
              "a copied screenshot with no text pastes as an attachment")
        check(Intake.route(types: ["public.tiff", "public.utf8-plain-text"], fileURLs: [], text: "Slide title", draft: "", isFile: isFile) == .text,
              "an image beside text (a Keynote or web copy) pastes as text")
        check(Intake.route(types: ["public.utf8-plain-text"], fileURLs: [], text: "What did Jordan say?", draft: "", isFile: isFile) == .text,
              "plain text pastes as text")
        check(Intake.route(types: ["public.url", "public.utf8-plain-text"], fileURLs: [URL(string: "https://example.com/a")!], text: "https://example.com/a", draft: "", isFile: isFile) == .text,
              "a web link is text, not a file")
        check(Intake.route(types: ["public.utf8-plain-text"], fileURLs: [], text: shot, draft: "", isFile: isFile) == .attachFiles([shotURL]),
              "rule C at the insert: a lone existing file path into an empty composer attaches")
        check(Intake.route(types: ["public.utf8-plain-text"], fileURLs: [], text: shot, draft: "Summarize ", isFile: isFile) == .text,
              "rule C at the insert: a path pasted after words stays text")
        check(Intake.localFiles(in: shot, isFile: isFile) == [shotURL], "rule C: the 0.5.280 screenshot path is a file")
        check(Intake.localFiles(in: "  \(notes)\n", isFile: isFile) == [URL(fileURLWithPath: notes)], "rule C: surrounding whitespace is ignored")
        check(Intake.localFiles(in: "file://" + shot.replacingOccurrences(of: " ", with: "%20"), isFile: isFile) == [shotURL], "rule C: a file URL is a file")
        check(Intake.localFiles(in: "file://localhost" + notes, isFile: isFile) == [URL(fileURLWithPath: notes)], "rule C: a localhost file URL is a file")
        check(Intake.localFiles(in: "'" + notes + "'", isFile: isFile) == [URL(fileURLWithPath: notes)], "rule C: a quoted path is a file")
        check(Intake.localFiles(in: "/Users/fixture/Desktop/my\\ notes.txt", isFile: isFile) == [URL(fileURLWithPath: "/Users/fixture/Desktop/my notes.txt")],
              "rule C: Terminal's escaped spaces are a file")
        check(Intake.localFiles(in: "~/a.txt", isFile: isFile, home: "/Users/fixture") == [URL(fileURLWithPath: "/Users/fixture/a.txt")], "rule C: a home-relative path is a file")
        check(Intake.localFiles(in: notes + "\n" + shot, isFile: isFile)?.count == 2, "rule C: one path per line, several files")
        check(Intake.localFiles(in: "What is in " + notes + "?", isFile: isFile) == nil, "rule C: a question that mentions a path is a question")
        check(Intake.localFiles(in: notes + "\nWhat does it say?", isFile: isFile) == nil, "rule C: a path line plus a question line is a question")
        check(Intake.localFiles(in: notes + " please", isFile: isFile) == nil, "rule C: words after a path make it a question")
        check(Intake.localFiles(in: "/Users/fixture/Desktop/missing.txt", isFile: isFile) == nil, "rule C: a path that does not exist is a question")
        check(Intake.localFiles(in: "/summary", isFile: isFile) == nil, "rule C: a slash command is a question")
        check(Intake.localFiles(in: "/", isFile: { _ in true }) == nil, "rule C: the root alone is never a file")
        check(Intake.localFiles(in: "", isFile: isFile) == nil && Intake.localFiles(in: " \n ", isFile: isFile) == nil, "rule C: nothing is not a file")
        check(Intake.localFiles(in: Array(repeating: notes, count: 21).joined(separator: "\n"), isFile: isFile) == nil, "rule C: at most 20 lines")
        let realFolder = root.appendingPathComponent("rule-c")
        try FileManager.default.createDirectory(at: realFolder, withIntermediateDirectories: true)
        let realFile = realFolder.appendingPathComponent("Screenshot 2026-10-10 at 7.23.21 PM.png")
        try Data([0x89, 0x50]).write(to: realFile)
        check(Intake.localFiles(in: realFile.path, isFile: Intake.regularFileExists) == [realFile], "rule C live: an existing regular file")
        check(Intake.localFiles(in: realFolder.path, isFile: Intake.regularFileExists) == nil, "rule C live: a folder is a question")
        check(MeetingAskText.attached(["Screenshot 2026-10-10 at 7.23.21 PM.png"]) == "Attached Screenshot 2026-10-10 at 7.23.21 PM.png to this meeting. Ask about it when it shows Ready.",
              "attach confirmation names the file")
        check(MeetingAskText.attached(["a", "b"]).hasPrefix("Attached 2 files"), "attach confirmation counts several files")
        check(MeetingAskText.attached([]) == "Nothing new was attached to this meeting.", "attach confirmation is honest when nothing landed")
        check(MeetingAskText.attached(["a"], pathOnly: true).hasPrefix("That question was only a file path, so it was not sent. "), "rule C says why the question was not sent")
        for line in [MeetingAskText.attached(["a"]), MeetingAskText.attached(["a", "b"], pathOnly: true), MeetingAskText.attached([]), MeetingAskText.attachUnavailable] {
            check(!line.contains("\u{2014}") && !line.contains("->") && !line.contains("\u{2192}"), "attach copy has no em dash or arrow")
        }
        print("PASS Meeting Ask: \(count) checks")
    }
}
