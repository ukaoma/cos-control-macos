import Combine
import Foundation
import ImageIO

/// The stand-in helper being down.
struct StandDown: Error {}

/// 0.5.371 Drop it (DropIt and DropItStore in Sources/DropIt.swift, the capability in Sources/Models.swift), executed. Compiled
/// against those two files alone by Tests/run-drop-it.sh, with a stand-in for the helper: no helper binary, no server, no window.
/// Prints "drop it checks: N passed". Every failure names its behaviour in brackets, which Tests/mutate-drop-it.py matches.
@main struct DropItChecks {
    nonisolated(unsafe) static var passed = 0

    static func check(_ condition: Bool, _ what: String) {
        guard condition else { print("drop it check FAILED: \(what)"); exit(1) }
        passed += 1
    }

    static func details(_ json: String) -> [String: JSONValue] {
        let wrapped = #"{"ok":true,"message":"x","details":"# + json + "}"
        return try! JSONDecoder().decode(HelperResponse.self, from: Data(wrapped.utf8)).details
    }
    static func answered(_ status: Int, _ body: String = "") -> [String: JSONValue] {
        details(#"{"transport":"answered","httpStatus":"# + "\(status)" + (body.isEmpty ? "" : "," + body) + "}")
    }

    static let drop = "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"
    static func item(_ id: String, kind: String, at: String, read: Bool = true, title: String? = nil, line: String = "x",
                     links: String = "[]", actions: String = "[]", live: Bool = true, thread: String = drop, source: String = "cos") -> String {
        #"{"id":"\#(id)","kind":"\#(kind)","threadId":"\#(thread)","createdAt":"\#(at)","readAt":\#(read ? "\"" + at + "\"" : "null"),"source":"\#(source)","# +
        (title.map { #""title":"\#($0)","# } ?? "") + #""line":"\#(line)","links":\#(links),"actions":\#(actions),"state":"\#(live ? "live" : "done")"}"#
    }
    static let view = #"{"id":"\#(drop)","text":"send Gina the numbers","source":"mac","createdAt":"2026-11-04T19:12:00.000Z","updatedAt":null,"state":"filed","dest":"new_card","kind":"task","status":"open","links":[{"kind":"card","id":"wid_1","label":"Quilt","domain":"quilt"}],"undoUntil":"2026-11-05T19:12:00.000Z","canUndo":true}"#
    static let receiptActions = #"[{"id":"open_card","label":"Open card"},{"id":"undo","label":"Undo"},{"id":"move","label":"Move"}]"#
    static func dropAnswer(_ items: [String], next: String? = nil) -> [String: JSONValue] {
        answered(200, #""drop":\#(view),"items":[\#(items.joined(separator: ","))],"replayed":false"# + (next.map { #","next":\#($0)"# } ?? ""))
    }
    static func feedID(_ n: Int) -> String { "fi_" + String(repeating: String(n % 10), count: 32) }

    @MainActor final class Stand {
        var log: [(args: [String], stdin: Data?)] = []
        var answers: [String: [String: JSONValue]] = [:]
        /// Held ops wait until released.
        var holding: Set<String> = []
        var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
        var down = false
        func op(_ args: [String]) -> String { args.count > 2 ? args[2] : "" }
        func run(_ args: [String], _ stdin: Data?) async throws -> HelperResponse {
            log.append((args, stdin))
            let op = op(args)
            if holding.contains(op) { await withCheckedContinuation { waiting[op, default: []].append($0) } }
            if down { throw StandDown() }
            return HelperResponse(ok: true, message: "x", details: answers[op] ?? answered(500))
        }
        func release(_ op: String) { holding.remove(op); for c in waiting[op] ?? [] { c.resume() }; waiting[op] = nil }
        func calls(_ op: String) -> [[String]] { log.filter { self.op($0.args) == op }.map(\.args) }
    }

    static func stdinObject(_ data: Data?) -> [String: Any] {
        (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
    }

    @MainActor static func main() async {
        // A failsafe: a change that makes a held call wait forever fails here instead of hanging the lane.
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 120)
            print("drop it check FAILED: [timeout] the checks did not finish in 120 s"); exit(1)
        }
        // ── Replies
        check(DropIt.reply(details(#"{"transport":"off","httpStatus":404,"error":"drop_it_off"}"#)) .isOff, "[reply off] a 404 drop_it_off is off")
        if case .unsupported = DropIt.reply(details(#"{"transport":"unsupported","httpStatus":404}"#)) { passed += 1 } else { check(false, "[reply unsupported] a server without the routes needs an update") }
        if case .noToken = DropIt.reply(details(#"{"transport":"no_token"}"#)) { passed += 1 } else { check(false, "[reply no token]") }
        if case .unreachable = DropIt.reply(details(#"{"transport":"unavailable"}"#)) { passed += 1 } else { check(false, "[reply unreachable]") }
        if case .unreachable = DropIt.reply(nil) { passed += 1 } else { check(false, "[reply unreachable] no answer") }
        if case .ok = DropIt.reply(answered(200)) { passed += 1 } else { check(false, "[reply ok] a 200 is ok") }
        check(DropIt.line(DropIt.reply(details(#"{"transport":"off","httpStatus":404}"#))) == DropIt.offLine, "[reply off] off says how to turn it on")
        check(DropIt.line(DropIt.reply(details(#"{"transport":"unsupported","httpStatus":404}"#))) == DropIt.oldServerLine, "[reply unsupported] an old server says it needs a newer one")

        // ── Refusal lines: an unknown code shows the server's plain line, never the code
        check(DropIt.line(DropIt.reply(answered(409, #""error":"memory_accepted_new","message":"The memory was accepted, so Undo leaves it alone.""#))) == "The memory was accepted, so Undo leaves it alone.",
              "[refusal line] an unknown code shows the server's plain message")
        check(DropIt.line(DropIt.reply(answered(409, #""error":"edited""#))) == DropIt.failedLine, "[refusal line] a code with no message shows the fixed line, not the code")
        check(DropIt.line(DropIt.reply(answered(400, #""error":"invalid_text","message":"Text must be 1 to 2000 characters.""#))) == DropIt.tooLongLine, "[refusal line] invalid text is ours")
        check(DropIt.line(DropIt.reply(answered(404))) == DropIt.oldServerLine, "[refusal line] a 404 with no code needs a newer server")
        check(DropIt.refusalLine(code: "x", message: "line one\nline two", status: 500) == DropIt.failedLine, "[refusal line] a multi-line message is not shown")
        check(!DropIt.refusalLine(code: "some_code", message: nil, status: 409).contains("some_code"), "[refusal line] never the raw code")

        // ── Calls: the words only on stdin
        let submit = DropIt.submitCall(dropId: drop, text: "  send Gina the numbers \r\n")
        check(submit?.arguments == ["drop-it", "--op", "submit"] && stdinObject(submit?.stdin)["text"] as? String == "send Gina the numbers"
              && stdinObject(submit?.stdin)["dropId"] as? String == drop, "[submit stdin] the words go on stdin, trimmed, never in the arguments")
        check(DropIt.submitCall(dropId: drop, text: "   ") == nil && DropIt.submitCall(dropId: drop, text: String(repeating: "a", count: 2_001)) == nil
              && DropIt.submitCall(dropId: drop, text: String(repeating: "a", count: 2_000)) != nil, "[submit limit] 1 to 2,000 characters")
        let history = DropIt.historyCall(query: " Gina ", kind: "task", status: nil)
        check(history?.arguments == ["drop-it", "--op", "history"] && stdinObject(history?.stdin)["q"] as? String == "Gina" && stdinObject(history?.stdin)["kind"] as? String == "task"
              && stdinObject(history?.stdin)["status"] == nil, "[history stdin] History's words go on stdin; an unset status is not sent")
        let move = DropIt.moveCall(dropId: drop, dest: "thread", target: DropIt.Target(id: "thr_1", label: "Kickoff"))
        check(move?.arguments == ["drop-it", "--op", "move", "--drop", drop] && (stdinObject(move?.stdin)["target"] as? [String: Any])?["id"] as? String == "thr_1",
              "[move stdin] Move sends the destination and its target on stdin")
        let freshID = DropIt.newDropID()
        check(freshID == freshID.lowercased() && freshID.count == 36 && freshID.split(separator: "-")[2].first == "4",
              "[drop id] a lowercase UUID v4")

        // ── Capability
        check(DropItCapability(statusDetails: details(#"{"dropItProtocol":1,"dropItEnabled":true}"#)).available, "[capability] protocol 1 and on is available")
        check(!DropItCapability(statusDetails: details(#"{"dropItProtocol":1,"dropItEnabled":false}"#)).available
              && DropItCapability(statusDetails: details(#"{"dropItProtocol":1,"dropItEnabled":false}"#)).supported, "[capability] off is supported, not available")
        check(!DropItCapability(statusDetails: details(#"{"dropItProtocol":2,"dropItEnabled":true}"#)).available
              && !DropItCapability(statusDetails: details(#"{}"#)).supported, "[capability] another protocol or none shows nothing")

        // ── The chat's layout
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = DropIt.date(.string("2026-11-04T20:30:00.000Z"))!
        let parsed = [item(feedID(1), kind: "drop", at: "2026-11-03T17:05:00.000Z", source: "mac"),
                      item(feedID(2), kind: "receipt", at: "2026-11-03T17:05:02.000Z", title: "Filed to Work, Quilt", actions: receiptActions),
                      item(feedID(3), kind: "drop", at: "2026-11-04T14:44:00.000Z", source: "web"),
                      item(feedID(4), kind: "receipt", at: "2026-11-04T14:50:00.000Z", title: "Added to the thread"),
                      item(feedID(5), kind: "followup", at: "2026-11-04T19:41:00.000Z", read: false, title: "Re: x"),
                      item(feedID(6), kind: "question", at: "2026-11-04T19:42:00.000Z", read: false, title: "Is this a task?",
                           actions: #"[{"id":"choose:o1","label":"A task"},{"id":"choose:note","label":"Just a note"}]"#)]
            .compactMap { DropIt.item(details("{\"x\":" + $0 + "}")["x"]!) }
        check(parsed.count == 6, "[parse] six feed items parse")
        let mark = DropIt.newMark(parsed)
        check(mark?.first == feedID(5) && mark?.count == 2, "[new mark] the line goes above the first unread ping, follow-up or question, counting them")
        let rows = DropIt.rows(parsed, firstNew: mark?.first, newCount: mark?.count ?? 0, now: now, calendar: cal)
        let seps = rows.compactMap { row -> (String?, String)? in if case .separator(_, let day, let time) = row { return (day, time) }; return nil }
        check(seps.count == 3 && seps[0].0 == "Yesterday" && seps[0].1 == "11:05 AM" && seps[1].0 == "Today" && seps[1].1 == "8:44 AM"
              && seps[2].0 == nil && seps[2].1 == "1:41 PM",
              "[separators] the day where it changes, the time alone after a ten-minute gap, none inside ten minutes: \(seps.map { ($0.0 ?? "-") + " " + $0.1 })")
        if let newIndex = rows.firstIndex(where: { if case .newLine = $0 { return true }; return false }) {
            check(rows[newIndex + 1].id == "sep-" + feedID(5) && rows.filter({ if case .newLine = $0 { return true }; return false }).count == 1,
                  "[new line] one N new line, above the first new item's separator")
        } else { check(false, "[new line] the N new line is drawn") }
        let gapped = [item(feedID(1), kind: "drop", at: "2026-11-04T14:44:00.000Z", source: "mac"), item(feedID(2), kind: "receipt", at: "2026-11-04T15:20:00.000Z")]
            .compactMap { DropIt.item(details("{\"x\":" + $0 + "}")["x"]!) }
        check(DropIt.rows(gapped, firstNew: nil, newCount: 0, now: now, calendar: cal).filter { if case .separator = $0 { return true }; return false }.count == 2,
              "[separators] a 36-minute gap inside one day gets its own time")
        check(DropIt.dayLabel(DropIt.date(.string("2026-11-02T17:00:00.000Z"))!, now: now, calendar: cal) == "Monday"
              && DropIt.dayLabel(DropIt.date(.string("2026-10-22T17:00:00.000Z"))!, now: now, calendar: cal) == "Oct 22", "[day labels] a weekday this week, a date before")
        check(DropIt.sourcePhrase("g2") == "Dictated on the glasses" && DropIt.sourcePhrase("web") == "Typed on the phone" && DropIt.sourcePhrase("cos") == "",
              "[source phrase] where his words came from")

        // ── The Messages rail mark (plan section 12)
        let waitingSummary = DropIt.summary(details(#"{"unread":2,"lastLine":"x","lastAt":null,"version":1,"waiting":3}"#))
        let plainSummary = DropIt.summary(details(#"{"unread":2,"lastLine":"x","lastAt":null,"version":1}"#))
        check(waitingSummary.waiting == 3 && plainSummary.waiting == nil, "[rail mark] waiting is read when sent, absent otherwise")
        check(DropIt.railMark(waitingSummary, available: true) == .count(3), "[rail mark] a number for what COS waits on")
        check(DropIt.railMark(plainSummary, available: true) == .dot, "[rail mark] no waiting field: a dot for unread, never a number")
        check(DropIt.railMark(DropIt.Summary(unread: 0, waiting: 0), available: true) == .none, "[rail mark] nothing unread or waiting: nothing")
        check(DropIt.railMark(waitingSummary, available: false) == .none, "[rail mark] nothing while Drop it is off or unsupported")
        check(DropIt.summary(details(#"{"unread":0,"waiting":-4}"#)).waiting == 0, "[rail mark] a negative count is none")

        // ── Cards
        let receipt = parsed[1]
        let buttons = DropIt.buttons(receipt)
        check(buttons.primary?.id == "open_card" && buttons.quiet.map(\.id) == ["undo", "move"], "[buttons] one primary open, Undo and Move quiet")
        var done = receipt; done.live = false
        check(DropIt.buttons(done).primary == nil && DropIt.buttons(done).quiet.isEmpty, "[buttons] a superseded receipt has no buttons")
        check(DropIt.buttons(parsed[5]).primary == nil && DropIt.buttons(parsed[5]).quiet.isEmpty, "[buttons] a question's choices are not buttons in the row")
        check(DropIt.glyph(parsed[5]) == .question && DropIt.glyph(DropIt.item(details("{\"x\":" + item(feedID(7), kind: "receipt", at: "2026-11-04T19:42:00.000Z", links: #"[{"kind":"thread","id":"t1","label":"K"}]"#) + "}")["x"]!)!) == .thread,
              "[glyph] a question, a thread")
        check(DropIt.quote(for: parsed[4], in: [DropIt.item(details("{\"x\":" + item(feedID(8), kind: "drop", at: "2026-11-04T19:12:00.000Z", line: "price test", thread: drop, source: "mac") + "}")["x"]!)!, parsed[4]], calendar: cal)?.words == "price test",
              "[quote] a follow-up quotes the drop it answers")
        check(parsed[0].fromYou && !parsed[1].fromYou && !parsed[1].countsUnread && parsed[4].countsUnread, "[mine] drops are his; receipts are born read")

        // ── Move
        let places = DropIt.destinations(domains: [("quilt", "Quilt"), ("personal", "Personal")], threads: [("t1", "Kickoff 2027 Planning"), ("t2", "Bottle POS Pricing Tests")], search: "pricing")
        check(places.map(\.dest) == ["new_card", "new_card", "thread", "memory", "note"] && places[2].target?.id == "t2", "[move places] Work areas, matching threads, a memory, a note")
        let current = DropIt.drop(details("{\"x\":" + view + "}")["x"])
        check(DropIt.isCurrent(places[0], drop: current) && !DropIt.isCurrent(places[1], drop: current) && !DropIt.isCurrent(places[3], drop: current), "[move current] where it is now cannot be picked")

        // ── History words
        check(current.map(DropIt.whereItWent) == "Work, Quilt" && current.map(DropIt.kindLine) == "Task, typed on this Mac", "[history words] where it went and its kind")
        var undone = current!; undone.status = "undone"; undone.state = "undone"
        check(DropIt.kindLine(undone).hasSuffix("You undid it.") && DropIt.openAction(for: undone) == nil && DropIt.openAction(for: current!) == "open_card",
              "[history open] an undone drop opens the chat; a filed one opens where it lives")

        // ── The store
        let stand = Stand()
        let store = DropItStore(run: { args, data in try await stand.run(args, data) })
        var asked: [(String, String)] = []
        var askedFiles: [[String]] = []
        store.askRun = { id, prompt, files in asked.append((id, prompt)); askedFiles.append(files); return "6f1c2b3a-4d5e-4f60-8a7b-9c0d1e2f3a4b" }

        // Summary and the feed
        stand.answers["summary"] = answered(200, #""unread":2,"lastLine":"Heads up.","lastAt":"2026-11-04T20:00:00.000Z","version":3"#)
        await store.refreshSummary()
        check(store.summary.unread == 2 && store.summary.lastLine == "Heads up.", "[summary] the pinned row's numbers")
        let feedItems = [item(feedID(1), kind: "drop", at: "2026-11-04T19:12:00.000Z", source: "mac"), item(feedID(2), kind: "followup", at: "2026-11-04T19:41:00.000Z", read: false, title: "Re: x")]
        stand.answers["feed"] = answered(200, #""items":[\#(feedItems.joined(separator: ","))],"version":4,"more":false"#)
        stand.answers["read"] = answered(200, #""unread":0,"version":5"#)
        await store.loadFeed(opening: true)
        check(store.items.count == 2 && store.newMark?.first == feedID(2), "[feed] the chat loads and fixes its N new line")
        check(stand.calls("read") == [["drop-it", "--op", "read", "--through", feedID(2)]] && store.summary.unread == 0 && store.items.allSatisfy { $0.readAt != nil },
              "[mark read] opening marks what it shows read, through the last item")
        let readItems = [item(feedID(1), kind: "drop", at: "2026-11-04T19:12:00.000Z", source: "mac"), item(feedID(2), kind: "followup", at: "2026-11-04T19:41:00.000Z", title: "Re: x")]
        stand.answers["feed"] = answered(200, #""items":[\#(readItems.joined(separator: ","))],"version":5,"more":false"#)
        await store.loadFeed()
        check(stand.calls("read").count == 1 && store.newMark?.first == feedID(2), "[mark read] nothing unread, no read call; the line stays while open")
        store.closed()
        check(store.newMark == nil, "[new mark] closing forgets the line")

        // Send
        stand.answers["submit"] = dropAnswer([item(feedID(3), kind: "drop", at: "2026-11-04T20:01:00.000Z", source: "mac"),
                                              item(feedID(4), kind: "receipt", at: "2026-11-04T20:01:02.000Z", title: "Filed to Work, Quilt", actions: receiptActions)])
        let sent = await store.send("  send Gina the numbers ")
        check(sent != nil && stand.calls("submit").count == 1 && !stand.calls("submit")[0].joined().contains("Gina"), "[send] one submit, the words not in the arguments")
        check(store.items.count == 4 && store.items.last?.id == feedID(4) && store.drops[drop] != nil, "[send] the receipt joins the chat")
        check(DropIt.commandNote(sent!) == "Filed to Work, Quilt. It is in your COS chat.", "[command note] ⌘K says what the receipt says")
        check(await store.send("   ") == nil && stand.calls("submit").count == 1 && store.line == DropIt.tooLongLine, "[send] nothing to drop sends nothing")

        // Both calls are started before the stand lets go, so a missing guard shows as a third submit, never as a wait that
        // cannot end (the 0.5.369 order awaited the second call before the release, and its M9 mutant hung for hours).
        stand.holding = ["submit"]
        async let first = store.send("one")
        await Task.yield(); await Task.yield()
        async let secondCall = store.send("two")
        await Task.yield(); await Task.yield()
        stand.release("submit")
        let second = await secondCall
        _ = await first
        check(second == nil && stand.calls("submit").count == 2, "[send once] a second drop while one is out sends nothing")

        stand.answers["submit"] = answered(409, #""error":"brand_new_code","message":"It looked like a key, so it stays a note.""#)
        check(await store.send("x") == nil && store.line == "It looked like a key, so it stays a note.", "[send refused] the server's plain line under the box")
        stand.down = true
        check(await store.send("x") == nil && store.line == DropIt.unreachableLine, "[send down] a helper that fails says the server is not answering")
        stand.down = false

        // An ask: the existing Ask job, then the link
        stand.answers["submit"] = dropAnswer([item(feedID(5), kind: "receipt", at: "2026-11-04T20:02:00.000Z", title: "Asking COS")], next: #"{"kind":"ask","prompt":"what did Jeremy say?"}"#)
        stand.answers["ask"] = dropAnswer([])
        _ = await store.send("what did Jeremy say?")
        check(asked.count == 1 && asked[0].0 == drop && asked[0].1 == "what did Jeremy say?", "[ask] a question runs the existing Ask job with the words")
        check(stand.calls("ask") == [["drop-it", "--op", "ask", "--drop", drop, "--job", "6f1c2b3a-4d5e-4f60-8a7b-9c0d1e2f3a4b", "--generation", "1"]], "[ask link] then links the job to the drop")
        store.askRun = { _, _, _ in nil }
        _ = await store.send("what now?")
        check(store.line == DropIt.askHeldLine && stand.calls("ask").count == 1, "[ask held] a run that did not start links nothing and says why")

        // Undo, a choice, Move: one change per drop at a time
        stand.answers["action"] = dropAnswer([item(feedID(4), kind: "receipt", at: "2026-11-04T20:01:02.000Z", title: "Filed", live: false),
                                              item(feedID(9), kind: "receipt", at: "2026-11-04T20:03:00.000Z", title: "Undone")])
        stand.holding = ["action"]
        let receiptItem = store.items.first { $0.id == feedID(4) }!
        async let undoing = store.undo(receiptItem)
        // The child task hops to the main actor; wait for it (bounded) rather than counting yields, which raced.
        for _ in 0..<100 where !store.isBusy(drop) { try? await Task.sleep(nanoseconds: 5_000_000) }
        check(store.isBusy(drop), "[busy] the drop's buttons wait while its change is out")
        async let againCall = store.undo(receiptItem)
        await Task.yield(); await Task.yield()
        stand.release("action")
        let again = await againCall
        let undid = await undoing
        check(undid && !again && stand.calls("action").count == 1 && stand.calls("action")[0] == ["drop-it", "--op", "action", "--item", feedID(4), "--action", "undo"],
              "[undo once] Undo posts the item's undo once; a double tap waits")
        check(store.items.first { $0.id == feedID(4) }?.live == false && store.items.contains { $0.id == feedID(9) }, "[undo] the old receipt loses its buttons, the new one joins")
        stand.answers["action"] = answered(409, #""error":"edited","message":"The card was changed since, so Undo leaves it alone.""#)
        check(await store.undo(receiptItem) == false && store.itemLines[drop] == "The card was changed since, so Undo leaves it alone.", "[undo refused] the reason shows on the item")
        stand.answers["action"] = dropAnswer([])
        check(await store.choose(parsed[5], DropIt.Action(id: "undo", label: "Undo")) == false, "[choose] only a choice is posted as a choice")
        _ = await store.choose(parsed[5], DropIt.Action(id: "choose:o1", label: "A task"))
        check(stand.calls("action").last == ["drop-it", "--op", "action", "--item", feedID(6), "--action", "choose:o1"], "[choose] a choice posts choose:<id>")
        stand.answers["move"] = dropAnswer([])
        _ = await store.move(thread: drop, to: places[2])
        check(stand.calls("move").count == 1 && stdinObject(stand.log.last?.stdin)["dest"] as? String == "thread", "[move] Move posts the destination")

        // History: the newest search wins
        stand.answers["history"] = answered(200, #""drops":[\#(view)],"more":false,"cardStates":"read""#)
        stand.holding = ["history"]
        async let older: Void = store.loadHistory(query: "a", kind: nil, status: nil)
        await Task.yield(); await Task.yield()
        stand.answers["history"] = answered(200, #""drops":[],"more":false"#)
        stand.release("history")
        await older
        await store.loadHistory(query: "ab", kind: "task", status: "done")
        check(store.history.isEmpty && store.historyRequests == 2, "[history] each search reads; the list is the newest answer")
        stand.holding = ["history"]
        stand.answers["history"] = answered(200, #""drops":[\#(view)],"more":false"#)
        async let slow: Void = store.loadHistory(query: "slow", kind: nil, status: nil)
        await Task.yield(); await Task.yield()
        stand.holding = []
        stand.answers["history"] = answered(200, #""drops":[],"more":true"#)
        await store.loadHistory(query: "fast", kind: nil, status: nil)
        stand.answers["history"] = answered(200, #""drops":[\#(view)],"more":false"#)
        stand.release("history")
        await slow
        check(store.history.isEmpty && store.historyMore, "[history generation] an older answer arriving late never replaces a newer one")

        // Settings
        stand.answers["settings-set"] = answered(200, #""protocol":1,"enabled":false,"source":"settings""#)
        check(await store.setEnabled(false) == false && stand.calls("settings-set").last == ["drop-it", "--op", "settings-set", "--enabled", "false"]
              && store.items.isEmpty && store.summary.unread == 0, "[settings off] turning it off forgets the chat")
        stand.answers["settings-set"] = answered(200, #""protocol":1,"enabled":false,"source":"env","savedButEnvWins":true"#)
        _ = await store.setEnabled(true)
        check(store.settingsLine == DropIt.settingEnvLine && store.settings?.envDecides == true, "[settings env] the server's environment decides, and the row says so")
        stand.answers["settings-set"] = answered(503, #""error":"settings_unwritable""#)
        check(await store.setEnabled(true) == nil && store.settingsLine == DropIt.failedLine, "[settings refused] a failed change says so")

        // ── 0.5.371 option A: Ask and Drop, with attachments
        let mediaA = "m_" + String(repeating: "a", count: 24), mediaB = "m_" + String(repeating: "b", count: 24)
        check(DropItCapability(statusDetails: details(#"{"dropItProtocol":1,"dropItEnabled":true,"dropItAttachments":5}"#)).attachments == 5
              && DropItCapability(statusDetails: details(#"{"dropItProtocol":1,"dropItEnabled":true}"#)).attachments == nil, "[capability files] the drop file count is read, absent on an older server")
        if case .success(let what) = DropIt.classify(name: "Store front.HEIC", bytes: 9_000_000) { check(what.kind == .photo && what.mime == "image/jpeg", "[classify] a photo of any size goes up as a resized JPEG") } else { check(false, "[classify] a photo is attached") }
        if case .success(let what) = DropIt.classify(name: "Q4 deck.pdf", bytes: 3_000_000) { check(what.kind == .doc && what.mime == "application/pdf", "[classify] a PDF is a document") } else { check(false, "[classify] a PDF is attached") }
        if case .success(let what) = DropIt.classify(name: "walkthrough.mov", bytes: 50_000_000) { check(what.kind == .video && what.mime == "video/quicktime", "[classify] a MOV is a video") } else { check(false, "[classify] a MOV is attached") }
        if case .failure(let r) = DropIt.classify(name: "huge.pdf", bytes: 65 * 1024 * 1024) { check(r.line == "huge.pdf is 65 MB. The largest file COS takes is 64 MB.", "[classify limits] a document over 64 MB says so") } else { check(false, "[classify limits] a document over 64 MB is refused") }
        if case .failure(let r) = DropIt.classify(name: "long.mp4", bytes: 101 * 1024 * 1024) { check(r.line.hasSuffix("The largest video COS takes is 100 MB."), "[classify limits] a video over 100 MB says so") } else { check(false, "[classify limits] a video over 100 MB is refused") }
        if case .failure(let r) = DropIt.classify(name: "notes.docx", bytes: 1_000) { check(r.line == "notes.docx cannot be attached. " + DropIt.attachKinds, "[classify] an unknown kind says what COS takes") } else { check(false, "[classify] an unknown kind is refused") }
        if case .failure = DropIt.classify(name: "service-key.json", bytes: 1_000, secret: true) { passed += 1 } else { check(false, "[classify secret] a secrets file is never attached") }
        func att(_ state: DropIt.Attachment.State, _ media: String? = nil) -> DropIt.Attachment {
            DropIt.Attachment(id: DropIt.newDropID(), name: "a.pdf", kind: .doc, mime: "application/pdf", bytes: 10, source: URL(fileURLWithPath: "/tmp/a.pdf"), state: state, mediaId: media)
        }
        check(DropIt.askBlock(text: "  ", files: []) == "" && DropIt.askBlock(text: "what is this?", files: []) == nil, "[ask block] words are needed, and enough")
        check(DropIt.askBlock(text: "what is this?", files: [att(.uploading)]) == DropIt.filesWaitLine, "[ask waits] Ask waits for the files to be up")
        check(DropIt.askBlock(text: "what is this?", files: [att(.failed)]) == DropIt.fileFailedLine, "[ask waits] a failed file says retry or remove")
        check(DropIt.askBlock(text: String(repeating: "a", count: 20_001), files: []) == DropIt.askTooLongLine && DropIt.askBlock(text: String(repeating: "a", count: 3_000), files: []) == nil,
              "[ask limit] an ask is not held to a drop's 2,000")
        check(DropIt.dropBlock(files: [att(.ready, mediaA)], serverTakes: nil) == DropIt.dropWordsOnlyLine && DropIt.dropBlock(files: [att(.ready, mediaA)], serverTakes: 0) == DropIt.dropWordsOnlyLine,
              "[drop files gate] a server that does not take files on a drop refuses them with the line")
        check(DropIt.dropBlock(files: [att(.ready, mediaA)], serverTakes: 5) == nil && DropIt.dropBlock(files: [], serverTakes: nil) == nil, "[drop files gate] a server that takes them, or no files, goes")
        check(DropIt.dropBlock(files: [att(.ready, mediaA), att(.ready, mediaB)], serverTakes: 1) != nil, "[drop files gate] more than the server takes is refused")
        let mediaC = "m_" + String(repeating: "c", count: 24)
        check(DropIt.readyIDs([att(.ready, mediaA), att(.uploading, mediaC), att(.failed, mediaC), att(.ready, "bogus"), att(.ready, mediaB), att(.ready, mediaA)]) == [mediaA, mediaB],
              "[ready ids] only valid ids of files that are up, once each (a file still going up or failed has an id that must not go)")
        let withFiles = DropIt.submitCall(dropId: drop, text: "file this", attachmentIds: [mediaA])
        check(withFiles?.arguments == ["drop-it", "--op", "submit"] && stdinObject(withFiles?.stdin)["attachmentIds"] as? [String] == [mediaA], "[submit files] a drop's files go on stdin")
        check(stdinObject(DropIt.submitCall(dropId: drop, text: "words")?.stdin)["attachmentIds"] == nil, "[submit files] a drop without files sends no attachmentIds")
        let upFile = DropIt.Attachment(id: "x", name: "Q4 deck.pdf", kind: .doc, mime: "application/pdf", bytes: 10, source: URL(fileURLWithPath: "/tmp/secret-folder/Q4 deck.pdf"))
        let up = DropIt.uploadCall(upFile, capturedAt: Date(timeIntervalSince1970: 0))
        check(up?.arguments == ["drop-it", "--op", "upload"] && stdinObject(up?.stdin)["path"] as? String == "/tmp/secret-folder/Q4 deck.pdf" && stdinObject(up?.stdin)["kind"] as? String == "doc",
              "[upload stdin] the file's path and name go on stdin, never in the arguments")
        if case .success(let id) = DropIt.uploadResult(.ok(answered(200, #""mediaId":"\#(mediaA)""#))) { check(id == mediaA, "[upload result] the media id") } else { check(false, "[upload result] a 200 with an id is up") }
        if case .failure(let r) = DropIt.uploadResult(.ok(answered(200, #""mediaId":"nope""#))) { check(r.line == "The Mac did not keep the file", "[upload result] no valid id is a failure") } else { check(false, "[upload result] a bad id is not up") }
        if case .failure(let r) = DropIt.uploadResult(.refused(code: "file_too_large", line: "x")) { check(r.line == "Too large for COS", "[upload result] a code is worded, never shown raw") } else { check(false, "[upload result] a refusal fails") }
        check(DropIt.answer(dropAnswer([], next: #"{"kind":"ask","prompt":"what is this?","attachmentIds":["\#(mediaA)","bad"]}"#))?.askAttachmentIds == [mediaA], "[ask link files] next.attachmentIds are read, valid ones only")

        // A photo is resized to at most 1024 px, as a JPEG.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("drop-it-checks-" + DropIt.newDropID(), isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let bigPhoto = scratch.appendingPathComponent("Store front.png")
        if let ctx = CGContext(data: nil, width: 2400, height: 1600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.setFillColor(CGColor(red: 0.6, green: 0.4, blue: 0.2, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 2400, height: 1600))
            if let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(bigPhoto as CFURL, "public.png" as CFString, 1, nil) { CGImageDestinationAddImage(dest, image, nil); _ = CGImageDestinationFinalize(dest) }
        }
        let jpeg = DropIt.photoJPEG(bigPhoto)
        let size = jpeg.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        check((size?[kCGImagePropertyPixelWidth] as? Int) == 1024 && (size?[kCGImagePropertyPixelHeight] as? Int) == 683 && jpeg?.prefix(2) == Data([0xFF, 0xD8]),
              "[photo resize] a photo goes up at most 1024 px on its longest edge, as a JPEG")

        // The store: attach, upload, remove, the five cap, Ask with files, Drop with files.
        let files = DropItStore(run: { args, data in try await stand.run(args, data) })
        files.stagingRoot = scratch.appendingPathComponent("staging", isDirectory: true)
        let pdf = scratch.appendingPathComponent("Q4 deck.pdf"); try? Data("%PDF-1.4\n".utf8).write(to: pdf)
        stand.answers["upload"] = answered(200, #""mediaId":"\#(mediaA)""#)
        files.attach([(bigPhoto, "Store front.png"), (pdf, "Q4 deck.pdf")])
        func settle() async { for _ in 0..<200 where files.attachments.contains(where: \.busy) { try? await Task.sleep(nanoseconds: 10_000_000) } }
        await settle()
        let uploads = stand.log.filter { stand.op($0.args) == "upload" }
        check(files.attachments.count == 2 && files.attachments.allSatisfy { $0.state == .ready && $0.mediaId == mediaA } && uploads.count == 2,
              "[upload] each file goes up once, at once, and shows ready")
        let photoUp = uploads.map { stdinObject($0.stdin) }.first { $0["kind"] as? String == "photo" }
        let docUp = uploads.map { stdinObject($0.stdin) }.first { $0["kind"] as? String == "doc" }
        check((photoUp?["path"] as? String)?.hasSuffix(".jpg") == true && photoUp?["path"] as? String != bigPhoto.path
              && files.attachments[0].thumb != nil && docUp?["path"] as? String == pdf.path, "[upload] a photo goes up as its resized copy, a document as itself")
        files.attach((0..<4).map { (pdf, "copy \($0).pdf") })
        check(files.attachments.count == 5 && files.line == "Up to 5 attachments per message. copy 3.pdf was not added.", "[attach cap] at most five; the sixth is refused by name")
        await settle()
        let dropped = files.attachments.last!.id
        files.removeAttachment(dropped)
        check(files.attachments.count == 4 && !files.attachments.contains { $0.id == dropped }, "[remove] Remove takes the file off")
        let photoCopy = files.attachments[0].thumb!
        files.removeAttachment(files.attachments[0].id)
        check(!FileManager.default.fileExists(atPath: photoCopy.path) && FileManager.default.fileExists(atPath: bigPhoto.path), "[remove] the composer's own copy goes; his file stays")
        files.attach([(scratch.appendingPathComponent("notes.docx"), "notes.docx")])
        check(files.attachments.count == 3 && files.line?.hasPrefix("notes.docx cannot be attached.") == true, "[classify] an unknown kind is refused with a line, never added")
        // Drop on an older server: nothing is dropped, the files stay.
        let submitsBefore = stand.calls("submit").count
        files.dropTakes = nil
        check(await files.send("file these") == nil && files.line == DropIt.dropWordsOnlyLine && stand.calls("submit").count == submitsBefore && files.attachments.count == 3,
              "[drop files gate] Drop with files on an older server drops nothing and says so")
        files.dropTakes = 5
        stand.answers["submit"] = dropAnswer([item(feedID(10), kind: "drop", at: "2026-11-04T20:05:00.000Z", source: "mac")])
        _ = await files.send("file these")
        check(stand.calls("submit").count == submitsBefore + 1 && stdinObject(stand.log.last { stand.op($0.args) == "submit" }?.stdin)["attachmentIds"] as? [String] == [mediaA]
              && files.attachments.isEmpty, "[submit files] Drop on a server that takes files sends their ids and clears them")
        // Ask with files: the words and the ids, through the existing run.
        var jobs: [(target: String, prompt: String, ids: [String])] = []
        files.askJob = { target, prompt, ids in jobs.append((target, prompt, ids)); return .started("7a1c2b3a-4d5e-4f60-8a7b-9c0d1e2f3a4b") }
        stand.answers["upload"] = answered(200, #""mediaId":"\#(mediaB)""#)
        stand.holding = ["upload"]
        files.attach([(pdf, "Q4 deck.pdf")])
        for _ in 0..<50 where stand.waiting["upload"] == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        check(await files.ask("what changed in this deck?") == false && files.line == DropIt.filesWaitLine && jobs.isEmpty, "[ask waits] Ask while a file goes up waits and says so")
        stand.release("upload")
        await settle()
        check(await files.ask("  what changed in this deck? ") && jobs.count == 1 && jobs[0].prompt == "what changed in this deck?" && jobs[0].ids == [mediaB]
              && jobs[0].target.hasPrefix("cos:ask:") && files.attachments.isEmpty, "[ask files] Ask sends the words with the files' ids and clears the files")
        check(files.asks.count == 1 && files.asks[0].files.map(\.name) == ["Q4 deck.pdf"] && files.asks[0].id == "7a1c2b3a-4d5e-4f60-8a7b-9c0d1e2f3a4b", "[asks in the chat] the Ask is kept with its files")
        files.askState = { ids in [ids[0]: DropIt.AskState(status: "completed", answer: "Slide 4 moved to the appendix.", number: 215)] }
        await files.refreshAsks()
        check(files.asks[0].answer == "Slide 4 moved to the appendix." && files.asks[0].number == 215 && DropIt.askTitle(files.asks[0]) == "Message #215" && files.asks[0].finished,
              "[ask answer] the answer lands under his words with its Messages number")
        let merged = DropIt.merged([DropIt.item(details("{\"x\":" + item(feedID(11), kind: "drop", at: "2099-01-01T00:00:00.000Z", source: "mac") + "}")["x"]!)!], asks: files.asks)
        check(merged.map(\.kind) == ["ask", "drop"] && merged[0].countsUnread == false, "[asks in the chat] an Ask takes its place by time and is never unread")
        files.askJob = { _, _, _ in .refused("Work is busy. Try again in a minute.") }
        check(await files.ask("again?") == false && files.line == "Work is busy. Try again in a minute.", "[ask refused] a run that did not start says why, and the words stay")
        stand.answers["submit"] = dropAnswer([], next: #"{"kind":"ask","prompt":"what is in this?","attachmentIds":["\#(mediaA)"]}"#)
        askedFiles = []
        store.askRun = { _, _, ids in askedFiles.append(ids); return "6f1c2b3a-4d5e-4f60-8a7b-9c0d1e2f3a4b" }
        _ = await store.send("what is in this?")
        check(askedFiles == [[mediaA]], "[ask link files] a drop that became a question carries its files to the Ask")
        // 6.99.13: a refusal keeps the words and the files; file links and a drop's attachments decode.
        files.dropTakes = 5
        files.attach([(pdf, "Q4 deck.pdf")])
        await settle()
        stand.answers["submit"] = answered(410, #""error":"attachment_expired","message":"A file expired before it was dropped (uploads wait 4 hours). Add it again, then Drop.""#)
        check(await files.send("file this") == nil && files.attachments.count == 1 && files.line == "A file expired before it was dropped (uploads wait 4 hours). Add it again, then Drop.",
              "[drop files refused] a refused drop keeps its files and shows the server's line")
        let fileItem = DropIt.item(details("{\"x\":" + item(feedID(12), kind: "drop", at: "2026-11-05T12:00:00.000Z", links: #"[{"kind":"file","id":"\#(mediaA)","label":"Q4 deck.pdf"}]"#, source: "mac") + "}")["x"]!)
        check(fileItem?.links.first?.kind == "file" && fileItem?.links.first?.id == mediaA && DropIt.fileKind(name: "Q4 deck.pdf") == .doc, "[file links] a drop's file link decodes")
        stand.answers["settings"] = answered(200, #""protocol":1,"enabled":true,"source":"settings","attachments":5"#)
        files.dropTakes = nil
        await files.readSettings()
        check(files.dropTakes == 5, "[capability files] the settings answer says how many files a drop takes")
        try? FileManager.default.removeItem(at: scratch)

        // Words: no em dash, en dash or arrow in anything the chat says.
        for text in [DropIt.chatLine, DropIt.placeholder, DropIt.footReturn, DropIt.footNothingOut, DropIt.historyLine, DropIt.moveNote,
                     DropIt.offLine, DropIt.oldServerLine, DropIt.unreachableLine, DropIt.askHeldLine, DropIt.sendSessionLine, DropIt.settingDetail,
                     DropIt.settingEnvLine, DropIt.cameBackCard, DropIt.cameBackThread, DropIt.cameBackMemory, DropIt.historyEmpty, DropIt.historyMiss, DropIt.chatEmpty,
                     DropIt.dropWordsOnlyLine, DropIt.filesWaitLine, DropIt.fileFailedLine, DropIt.askWaiting, DropIt.askFailedLine, DropIt.dropZoneLine,
                     DropIt.dropZoneTarget, DropIt.attachKinds, DropIt.linkNotFileLine, DropIt.nothingToPasteLine, DropIt.askTooLongLine] {
            check(text.range(of: "[\u{2014}\u{2013}\u{2192}]|->", options: .regularExpression) == nil, "[copy] no em dash, en dash or arrow: \(text)")
        }
        print("drop it checks: \(passed) passed")
    }
}

extension DropIt.Reply {
    var isOff: Bool { if case .off = self { return true }; return false }
}
