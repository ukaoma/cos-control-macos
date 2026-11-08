import AppKit
import Foundation

// 0.5.380 (preview engine phase 1, plan item 6): the Sessions pane's file and image cards (Sources/SessionPreviews.swift),
// executed. Compiled with Models.swift and SessionPreviews.swift alone by Tests/run-session-previews.sh. No helper, no server,
// no window, no Quick Look panel: a stand-in runner answers as the helper does and writes its copies under a private /tmp home.
// Prints "session previews checks: N passed".

private let hexA = String(repeating: "a", count: 64)
private let hexB = String(repeating: "b", count: 64)
private let hexC = String(repeating: "c", count: 64)

private func item(_ source: String, _ id: String, name: String = "plan.md", kind: String = "markdown", available: Bool = true,
                  reason: String? = nil, extra: [String: JSONValue] = [:]) -> JSONValue {
    var o: [String: JSONValue] = ["id": .string(id), "source": .string(source), "name": .string(name), "kind": .string(kind),
                                  "type": .string("Markdown"), "available": .bool(available)]
    if let reason { o["reason"] = .string(reason) }
    for (k, v) in extra { o[k] = v }
    return .object(o)
}

private func turn(_ role: String, _ at: String, _ items: [JSONValue], off: Bool = false, more: Int = 0) -> JSONValue {
    .object(["role": .string(role), "at": .string(at), "items": .array(items), "more": .number(Double(more)), "previewsOff": .bool(off)])
}

/// What the stand-in helper was asked, and how it answers.
private final class FakeHelper: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var _requests: [[String: String]] = []
    let root: URL
    var fetchState = "ready"
    var listing: [String: JSONValue] = ["state": .string("ready"), "turns": .array([])]
    var bytes = Data("# Plan\n".utf8)
    var reportedSize: Int?

    init(root: URL) { self.root = root }

    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }
    var requests: [[String: String]] { lock.lock(); defer { lock.unlock() }; return _requests }
    var fetches: Int { calls.filter { $0 == ["session-preview-fetch"] }.count }

    func answer(_ args: [String], _ stdin: Data?) throws -> [String: JSONValue] {
        lock.lock()
        _calls.append(args)
        let request = stdin.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
        if !request.isEmpty { _requests.append(request) }
        lock.unlock()
        if args.first == "session-previews" { return listing }
        guard fetchState == "ready" else { return ["state": .string(fetchState)] }
        let folder = root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(request["name"] ?? "file")
        try bytes.write(to: file)
        return ["state": .string("ready"), "path": .string(file.path), "bytes": .number(Double(reportedSize ?? bytes.count))]
    }
}

private func png() -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

private func children(_ url: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
}

@main struct SessionPreviewsChecks {
    @MainActor static func main() async throws {
        guard let home = ProcessInfo.processInfo.environment["COS_CONTROL_TEST_HOME"], home.hasPrefix("/tmp/") else {
            preconditionFailure("Run with a private /tmp COS_CONTROL_TEST_HOME")
        }
        // The real root's shape: a dot component and a space (the cache lives under ~/Library/Caches/com.gotcos.COSControl).
        let base = URL(fileURLWithPath: home).appendingPathComponent("Library Caches/com.gotcos.COSControl-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("SessionPreviews", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }

        func harness() -> (FakeHelper, SessionPreviewStore) {
            let fake = FakeHelper(root: root)
            let store = SessionPreviewStore(root: root) { args, stdin in try fake.answer(args, stdin) }
            return (fake, store)
        }

        // ── Descriptors: a secret name never opens, whatever its state says.
        do {
            let secret = SessionPreviewItem(item("file", "af_" + hexA, name: ".env", kind: "text", available: true, reason: "secret_file"))
            check(secret != nil && secret?.available == false && secret?.opens == false, "a secret_file card is never available")
            check(secret?.unavailableLine == "Not shown: this file may hold secrets.", "a secret card says so in the pane's words")
            let blocked = SessionPreviewItem(item("link", "al_" + hexA, name: "x-key.json", kind: "code", available: true, reason: "blocked_name"))
            check(blocked?.opens == false && blocked?.unavailableLine == SessionPreviewItem.secretLine, "a blocked_name link never opens")
            check(SessionPreviewItem(item("file", "ai_" + hexA)) == nil, "an id with another source's prefix is dropped")
            check(SessionPreviewItem(item("file", "af_" + String(hexA.prefix(63)))) == nil, "a short id is dropped")
            check(SessionPreviewItem(item("file", "af_" + hexA.uppercased())) == nil, "an upper-case id is dropped")
            check(SessionPreviewItem(item("file", "af_" + hexA, name: "../secrets/plan.md")) == nil, "a name with a directory is dropped")
            let missing = SessionPreviewItem(item("file", "af_" + hexA, available: false, reason: "missing"))
            check(missing?.opens == false && missing?.unavailableLine == "Not available on this Mac.", "a missing file says it is not available")
            let outside = SessionPreviewItem(item("file", "af_" + hexA, available: false, reason: "outside_workspace"))
            check(outside?.unavailableLine == "Not available on this Mac.", "outside the workspace reads the same, no path")
            let folder = SessionPreviewItem(item("link", "al_" + hexA, name: "wk45_2026", kind: "folder"))
            check(folder?.opens == false && folder?.unavailableLine == "A folder. Open it on your Mac.", "a folder card has no Quick Look")
            let link = SessionPreviewItem(item("link", "al_" + hexA, name: "ask.ts", kind: "code",
                                               extra: ["label": .string("the ask route"), "line": .number(42), "size": .number(2048)]))
            check(link?.title == "the ask route" && link?.meta == "ask.ts · Markdown · 2 KB · line 42", "a link card shows its words, then its file")
            let tool = SessionPreviewItem(item("tool", "ti_" + hexA, name: "Read", kind: "image", extra: ["index": .number(2), "total": .number(3)]))
            check(tool?.title == "Read 2 of 3" && tool?.hasThumbnail == true, "a tool image reads Read 2 of 3 and has a thumbnail")
            let gif = SessionPreviewItem(item("file", "af_" + hexA, name: "loop.gif", kind: "image"))
            check(gif?.hasThumbnail == false && gif?.opens == true, "a sent GIF opens but asks for no thumbnail route")
            let pdf = SessionPreviewItem(item("file", "af_" + hexA, name: "Q3 plan.pdf", kind: "pdf"))
            check(pdf?.badge == "PDF" && pdf?.unavailableLine == nil, "a PDF card opens with its badge")
            for copy in [secret?.unavailableLine, missing?.unavailableLine, outside?.unavailableLine, folder?.unavailableLine,
                         SessionPreviewStore.offLine] + ["secret", "off", "missing", "absent", "too_large", "unauthorized", "offline", "invalid", "x"].map(SessionPreviewStore.refusalLine) {
                let text = copy ?? ""
                check(!text.contains("\u{2014}") && !text.contains("\u{2192}") && !text.contains("->"), "no em dash or arrow in copy: \(text)")
            }
        }

        // ── A message marked previews off carries nothing, whatever it was sent.
        do {
            let off = SessionPreviewTurn(turn("assistant", "2026-11-08T10:00:00.000Z", [item("file", "af_" + hexA)], off: true, more: 3), index: 0)
            check(off?.previewsOff == true && off?.items.isEmpty == true && off?.more == 0, "an off message keeps no cards and no count")
            check(SessionPreviewTurn(turn("assistant", "", []), index: 1) == nil, "a message with nothing to show is dropped")
        }

        // ── Placement: the same record, then the reply before it, then the closing group.
        do {
            let local: [SessionPreviewPlacement.LocalTurn] = [
                .init(id: "1", role: "user", timestamp: "2026-11-08T10:00:00.000Z"),
                .init(id: "2", role: "assistant", timestamp: "2026-11-08T10:00:00.000Z"),
                .init(id: "3", role: "assistant", timestamp: "2026-11-08T10:05:00.000Z"),
            ]
            let a = SessionPreviewTurn(id: "a", role: "assistant", at: "2026-11-08T10:00:00.000Z", items: [])
            let b = SessionPreviewTurn(id: "b", role: "assistant", at: "2026-11-08T10:07:30Z", items: [])
            let c = SessionPreviewTurn(id: "c", role: "assistant", at: "2026-11-08T09:00:00.000Z", items: [])
            let d = SessionPreviewTurn(id: "d", role: "assistant", at: "", items: [])
            let placed = SessionPreviewPlacement.place([a, b, c, d], local: local)
            check(placed.byTurn["2"]?.map(\.id) == ["a"], "an exact timestamp lands on the same record, same role first")
            check(placed.byTurn["3"]?.map(\.id) == ["b"], "a later step lands on the latest reply before it (no fractional seconds)")
            check(placed.unplaced.map(\.id) == ["c", "d"], "older than the turns on screen, or undated, closes the pane")
            check(SessionPreviewPlacement.place([a], local: []).unplaced.map(\.id) == ["a"], "no local turns: the closing group")
        }

        // ── An older server, a missing session, no server: no cards and no error.
        do {
            let (fake, store) = harness()
            for state in ["absent", "missing", "unreachable", "unauthorized", "unavailable"] {
                fake.listing = ["state": .string(state), "turns": .array([turn("assistant", "", [item("file", "af_" + hexA)])])]
                await store.load(provider: "claude", sessionID: "00000000-0000-4000-8000-000000000001")?.value
                check(store.turns.isEmpty && !store.hasCards && !store.previewsOff && store.notes.isEmpty, "\(state) is quiet: no cards, no error")
            }
            check(fake.calls.allSatisfy { $0 == ["session-previews", "--provider", "claude", "--session-id", "00000000-0000-4000-8000-000000000001"] },
                  "the listing asks the helper for exactly this session")
            check(fake.fetches == 0, "listing fetches no bytes")
        }

        // ── Previews off: no cards, and nothing is fetched.
        do {
            let (fake, store) = harness()
            fake.listing = ["state": .string("ready"), "previewsOff": .bool(true),
                            "turns": .array([turn("assistant", "2026-11-08T10:00:00.000Z", [], off: true)])]
            await store.load(provider: "claude", sessionID: "00000000-0000-4000-8000-000000000002")?.value
            check(store.previewsOff && !store.hasCards && store.turns.count == 1, "previews off keeps the mark and no cards")
            let card = SessionPreviewItem(item("file", "af_" + hexA, name: "plan.md"))!
            check(store.open(card) == nil, "open refuses while previews are off")
            await store.loadThumbnail(SessionPreviewItem(item("image", "ai_" + hexA, name: "shot.png", kind: "image"))!)
            check(fake.fetches == 0 && store.quickLookURL == nil && store.thumbnails.isEmpty, "previews off fetches nothing")
            // A mixed answer: one message off, another still carrying cards. Off wins; its cards are dropped.
            fake.listing = ["state": .string("ready"), "turns": .array([
                turn("assistant", "2026-11-08T10:00:00.000Z", [], off: true),
                turn("assistant", "2026-11-08T10:01:00.000Z", [item("file", "af_" + hexB)]),
            ])]
            await store.reload()?.value
            check(store.previewsOff && !store.hasCards, "one message off means no cards anywhere")
        }

        // ── Open: Quick Look on a private copy; closing deletes it; another card replaces and deletes it.
        do {
            let (fake, store) = harness()
            fake.listing = ["state": .string("ready"), "turns": .array([turn("assistant", "2026-11-08T10:00:00.000Z", [
                item("file", "af_" + hexA, name: "plan.md"), item("link", "al_" + hexB, name: "notes.md")])])]
            await store.load(provider: "codex", sessionID: "00000000-0000-4000-8000-000000000003")?.value
            check(store.hasCards && store.turns.first?.items.count == 2, "cards land")
            let plan = store.turns[0].items[0], notes = store.turns[0].items[1]
            await store.open(plan)?.value
            guard let first = store.quickLookURL else { preconditionFailure("open sets the Quick Look copy") }
            check(first.lastPathComponent == "plan.md" && first.path.hasPrefix(root.path + "/"), "Quick Look shows the copy under the private root")
            check(fake.requests.last == ["provider": "codex", "session": "00000000-0000-4000-8000-000000000003", "id": "af_" + hexA,
                                          "part": "raw", "name": "plan.md"], "the fetch names the session, the id, raw, and the base name only")
            check(FileManager.default.fileExists(atPath: first.path) && store.opening == nil, "the copy exists while Quick Look shows it")
            await store.open(notes)?.value
            check(!FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path), "opening another card deletes the first copy's folder")
            guard let second = store.quickLookURL else { preconditionFailure("the second card opens") }
            store.quickLookURL = nil
            check(!FileManager.default.fileExists(atPath: second.deletingLastPathComponent().path), "closing Quick Look deletes the copy's folder")
            check(children(root).isEmpty, "nothing is left in the private root after close")
            await store.open(plan)?.value
            let third = store.quickLookURL
            store.clear()
            check(third != nil && !FileManager.default.fileExists(atPath: third!.path) && children(root).isEmpty, "leaving the session deletes the open copy")
        }

        // ── Refusals at open are said under the card; nothing is shown.
        do {
            let (fake, store) = harness()
            fake.listing = ["state": .string("ready"), "turns": .array([turn("assistant", "", [item("file", "af_" + hexA, name: "creds.txt", kind: "text")])])]
            await store.load(provider: "claude", sessionID: "00000000-0000-4000-8000-000000000004")?.value
            let card = store.turns[0].items[0]
            for (state, words) in [("secret", SessionPreviewItem.secretLine), ("off", SessionPreviewStore.refusalLine("off")),
                                   ("missing", SessionPreviewStore.refusalLine("missing")), ("too_large", "Too large to open here.")] {
                fake.fetchState = state
                await store.open(card)?.value
                check(store.quickLookURL == nil && store.notes[card.id] == words && store.opening == nil, "a \(state) refusal is said under the card")
            }
            fake.fetchState = "ready"
            fake.reportedSize = 999
            await store.open(card)?.value
            check(store.quickLookURL == nil && store.notes[card.id] == "COS could not verify this file.", "a copy of the wrong size is not believed")
            check(children(root).isEmpty, "a copy that is not believed is deleted")
        }

        // ── The copy is believed only inside the root, one folder down, a regular file of the named size.
        do {
            let (_, store) = harness()
            let folder = root.appendingPathComponent("verify", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("a.md")
            try Data("abc".utf8).write(to: file)
            check(store.verified(path: file.path, bytes: 3) == file.standardizedFileURL, "a regular file of the named size is believed")
            check(store.verified(path: file.path, bytes: 4) == nil, "a size mismatch is refused")
            let deep = folder.appendingPathComponent("deeper", isDirectory: true)
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
            try Data("abc".utf8).write(to: deep.appendingPathComponent("b.md"))
            check(store.verified(path: deep.appendingPathComponent("b.md").path, bytes: 3) == nil, "two folders down is refused")
            let outside = base.appendingPathComponent("outside.md")
            try Data("abc".utf8).write(to: outside)
            check(store.verified(path: outside.path, bytes: 3) == nil, "outside the root is refused")
            let link = folder.appendingPathComponent("link.md")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            check(store.verified(path: link.path, bytes: 3) == nil, "a symlink is refused")
            check(store.verified(path: folder.appendingPathComponent("../verify/a.md").path, bytes: 3) == file.standardizedFileURL, "dots are standardized first")
            store.discard(outside)
            check(FileManager.default.fileExists(atPath: outside.path), "discard never deletes outside the root")
            store.discard(file)
            check(!FileManager.default.fileExists(atPath: folder.path), "discard deletes the copy's own folder")
            try? FileManager.default.removeItem(at: outside)
        }

        // ── Thumbnails: pictures only, decoded then deleted, at most 24 a session.
        do {
            let (fake, store) = harness()
            fake.bytes = png()
            var pictures: [JSONValue] = []
            for n in 0..<30 { pictures.append(item("image", "ai_" + String(format: "%064x", n), name: "shot\(n).png", kind: "image")) }
            pictures.append(item("file", "af_" + hexC, name: "Q3.pdf", kind: "pdf"))
            fake.listing = ["state": .string("ready"), "turns": .array([turn("assistant", "", pictures)])]
            await store.load(provider: "claude", sessionID: "00000000-0000-4000-8000-000000000005")?.value
            for card in store.turns[0].items { await store.loadThumbnail(card) }
            check(fake.fetches == SessionPreviewStore.thumbnailsPerSession && store.thumbnails.count == SessionPreviewStore.thumbnailsPerSession,
                  "at most 24 thumbnails a session, and never one for a PDF")
            check(fake.requests.allSatisfy { $0["part"] == "thumb" }, "a thumbnail asks for the thumb part")
            check(children(root).isEmpty, "each thumbnail copy is deleted once decoded")
            await store.loadThumbnail(store.turns[0].items[0])
            check(fake.fetches == SessionPreviewStore.thumbnailsPerSession, "a drawn thumbnail is not fetched again")
            store.clear()
        }

        // ── Launch sweep: every leftover goes, the root stays.
        do {
            let leftover = root.appendingPathComponent("left", isDirectory: true)
            try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: leftover.appendingPathComponent("q.pdf"))
            try Data("x".utf8).write(to: root.appendingPathComponent("stray"))
            SessionPreviewStore.sweep(root: root)
            check(children(root).isEmpty && FileManager.default.fileExists(atPath: root.path), "the launch sweep empties the root")
            let outsider = base.appendingPathComponent("keep.txt")
            try Data("k".utf8).write(to: outsider)
            let linked = base.appendingPathComponent("linked-root", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: base)
            SessionPreviewStore.sweep(root: linked)
            check(FileManager.default.fileExists(atPath: outsider.path), "a root that is a symlink is never swept")
            check(SessionPreviewStore.defaultRoot().path.hasSuffix("Library/Caches/com.gotcos.COSControl/SessionPreviews"), "the real root is Control's cache")
        }

        try? FileManager.default.removeItem(at: base)
        print("session previews checks: \(checks) passed")
    }
}
