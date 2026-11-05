import Combine
import Foundation

/// The stand-in helper being down.
struct StandDown: Error {}

/// 0.5.370 Drop it (DropIt and DropItStore in Sources/DropIt.swift, the capability in Sources/Models.swift), executed. Compiled
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
        store.askRun = { id, prompt in asked.append((id, prompt)); return "6f1c2b3a-4d5e-4f60-8a7b-9c0d1e2f3a4b" }

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

        stand.holding = ["submit"]
        async let first = store.send("one")
        await Task.yield(); await Task.yield()
        let second = await store.send("two")
        stand.release("submit")
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
        store.askRun = { _, _ in nil }
        _ = await store.send("what now?")
        check(store.line == DropIt.askHeldLine && stand.calls("ask").count == 1, "[ask held] a run that did not start links nothing and says why")

        // Undo, a choice, Move: one change per drop at a time
        stand.answers["action"] = dropAnswer([item(feedID(4), kind: "receipt", at: "2026-11-04T20:01:02.000Z", title: "Filed", live: false),
                                              item(feedID(9), kind: "receipt", at: "2026-11-04T20:03:00.000Z", title: "Undone")])
        stand.holding = ["action"]
        let receiptItem = store.items.first { $0.id == feedID(4) }!
        async let undoing = store.undo(receiptItem)
        await Task.yield(); await Task.yield()
        check(store.isBusy(drop), "[busy] the drop's buttons wait while its change is out")
        let again = await store.undo(receiptItem)
        stand.release("action")
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

        // Words: no em dash, en dash or arrow in anything the chat says.
        for text in [DropIt.pinNote, DropIt.chatLine, DropIt.placeholder, DropIt.footReturn, DropIt.footNothingOut, DropIt.historyLine, DropIt.moveNote,
                     DropIt.offLine, DropIt.oldServerLine, DropIt.unreachableLine, DropIt.askHeldLine, DropIt.sendSessionLine, DropIt.settingDetail,
                     DropIt.settingEnvLine, DropIt.cameBackCard, DropIt.cameBackThread, DropIt.cameBackMemory, DropIt.historyEmpty, DropIt.historyMiss, DropIt.chatEmpty] {
            check(text.range(of: "[\u{2014}\u{2013}\u{2192}]|->", options: .regularExpression) == nil, "[copy] no em dash, en dash or arrow: \(text)")
        }
        print("drop it checks: \(passed) passed")
    }
}

extension DropIt.Reply {
    var isOff: Bool { if case .off = self { return true }; return false }
}
