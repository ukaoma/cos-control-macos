import AppKit
import SwiftUI

// 0.5.371 Drop it, with the whole app compiled (Tests/run-drop-it.sh).
//   DropItRender check            the wiring against the real ControllerModel and the command center: the route flags and their
//                                 openers, the capability gate, Settings' switch closing the chat, ⌘K's row old and new, the hub
//                                 search entry. Prints "drop it wiring checks: N passed" then "PASS: drop it wiring checks complete".
//   DropItRender render <dir>     offscreen PNGs, light and dark: the Activity window on Messages with the pinned row (and the same
//                                 window with Drop it off, for the unchanged list), the chat, History, the Settings row and the
//                                 strip a deep link leaves. Fixture data only (invented words, names from the mock), from a stand-in
//                                 run closure, never the helper or a server. No window is ordered in, the process can never become
//                                 active, and nothing is clicked or typed.

let base = Date()
func iso(_ minutesAgo: Double) -> String {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: base.addingTimeInterval(-minutesAgo * 60))
}
let dropA = "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed", dropB = "2c9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed", dropC = "3d9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"
let dropD = "4e9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed", dropE = "5f9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed", dropF = "6a9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"
func fid(_ n: Int) -> String { "fi_" + String(repeating: String(n % 10), count: 31) + String(n / 10 % 10) }
func feed(_ id: Int, _ kind: String, _ minutesAgo: Double, thread: String, source: String = "cos", title: String? = nil, line: String,
          links: String = "[]", actions: String = "[]", live: Bool = true, read: Bool = true) -> String {
    #"{"id":"\#(fid(id))","kind":"\#(kind)","threadId":"\#(thread)","createdAt":"\#(iso(minutesAgo))","readAt":\#(read ? "\"" + iso(minutesAgo) + "\"" : "null"),"source":"\#(source)","# +
        (title.map { #""title":"\#($0)","# } ?? "") + #""line":"\#(line)","links":\#(links),"actions":\#(actions),"state":"\#(live ? "live" : "done")"}"#
}
let undoMove = #"{"id":"undo","label":"Undo"},{"id":"move","label":"Move"}"#
/// The chat, shaped like the mock's 3b (the P1 parts: receipts, a question, an answer, a held session). Minutes ago from now.
let feedItems: [String] = [
    feed(1, "drop", 1_560, thread: dropA, source: "g2", line: "Use the Q4 numbers Jeremy approved, not the forecast"),
    feed(2, "receipt", 1_559.9, thread: dropA, title: "Held for Kickoff 2027 deck", line: "Send it to the session when you are ready.",
         links: #"[{"kind":"session","id":"claude:4f1e9b2a-kickoff","label":"Kickoff 2027 deck"}]"#,
         actions: #"[{"id":"send_to_session","label":"Send to session"},\#(undoMove)]"#),
    feed(3, "drop", 340, thread: dropB, source: "web", line: "Kickoff 2027: open with the three store stories, not the numbers"),
    feed(4, "receipt", 339.9, thread: dropB, title: "Added to the Kickoff 2027 Planning thread", line: "It joins the thread for the next prep. No card.",
         links: #"[{"kind":"thread","id":"thr_kickoff_2027","label":"Kickoff 2027 Planning"}]"#,
         actions: #"[{"id":"open_thread","label":"Open thread"},\#(undoMove)]"#),
    feed(5, "drop", 92, thread: dropC, source: "mac", line: "Price test idea for Bottle POS: try $10 off the first month for stores switching from Clover"),
    feed(6, "receipt", 91.9, thread: dropC, title: "Filed to Work, Quilt", line: "New card in the Inbox.",
         links: #"[{"kind":"card","id":"wid_price_test","label":"Quilt","domain":"quilt","created":true}]"#,
         actions: #"[{"id":"open_card","label":"Open card"},\#(undoMove)]"#),
    feed(7, "drop", 61, thread: dropD, source: "mac", line: "Call Dave about the Kickoff deck"),
    feed(8, "question", 60.9, thread: dropD, title: "Is this a task for you, or a note on the Kickoff 2027 Planning thread?",
         line: "COS is not sure where this goes, so it is asking instead of guessing.",
         actions: #"[{"id":"choose:o1","label":"A task for me"},{"id":"choose:o2","label":"A note on Kickoff 2027 Planning"},{"id":"choose:note","label":"Just a note"}]"#, read: false),
    feed(9, "drop", 40, thread: dropE, source: "mac", line: "what did Jeremy say about the Q4 numbers in QLT Monthly?"),
    feed(10, "receipt", 39.9, thread: dropE, title: "Asking COS", line: "The answer lands here when it is ready."),
    feed(11, "followup", 38, thread: dropE, title: "Re: what did Jeremy say about the Q4 numbers in QLT Mon…",
         line: "Use the approved Q4 numbers, not the forecast. He wants the same figures in the Kickoff 2027 deck and the board pack.",
         links: #"[{"kind":"session","id":"g2_session_qlt","label":"Messages"}]"#, actions: #"[{"id":"open_messages","label":"Open in Messages"}]"#, read: false),
    feed(12, "drop", 6, thread: dropF, source: "mac", line: "remember Gina wants the outline before the draft, every time"),
    feed(13, "receipt", 5.9, thread: dropF, title: "Saved to memories", line: "It waits in To review until you accept it.",
         links: #"[{"kind":"memory","id":"mem_8812","label":"To review"}]"#, actions: #"[{"id":"open_memory","label":"Open memory"},\#(undoMove)]"#),
]

func view(_ id: String, _ text: String, _ minutesAgo: Double, source: String, state: String = "filed", dest: String?, kind: String, status: String, links: String = "[]", hold: String? = nil) -> String {
    #"{"id":"\#(id)","text":"\#(text)","source":"\#(source)","createdAt":"\#(iso(minutesAgo))","updatedAt":null,"state":"\#(state)","dest":\#(dest.map { "\"" + $0 + "\"" } ?? "null"),"kind":"\#(kind)","status":"\#(status)","links":\#(links),"undoUntil":null,"canUndo":false"# + (hold.map { #","hold":\#($0)"# } ?? "") + "}"
}
let historyDrops: [String] = [
    view(dropF, "remember Gina wants the outline before the draft, every time", 6, source: "mac", dest: "memory", kind: "memory", status: "done", links: #"[{"kind":"memory","id":"mem_8812","label":"To review"}]"#),
    view(dropE, "what did Jeremy say about the Q4 numbers in QLT Monthly?", 40, source: "mac", state: "asked", dest: "ask", kind: "ask", status: "done"),
    view(dropD, "Call Dave about the Kickoff deck", 61, source: "mac", state: "asking", dest: nil, kind: "note", status: "open"),
    view(dropC, "Price test idea for Bottle POS: try $10 off the first month for stores switching from Clover", 92, source: "mac", dest: "new_card", kind: "idea", status: "in_progress",
         links: #"[{"kind":"card","id":"wid_price_test","label":"Quilt","domain":"quilt"}]"#),
    view(dropB, "Kickoff 2027: open with the three store stories, not the numbers", 340, source: "web", dest: "thread", kind: "idea", status: "done",
         links: #"[{"kind":"thread","id":"thr_kickoff_2027","label":"Kickoff 2027 Planning"}]"#),
    view(dropA, "Use the Q4 numbers Jeremy approved, not the forecast", 1_560, source: "g2", state: "held", dest: "session", kind: "task", status: "open",
         links: #"[{"kind":"session","id":"claude:4f1e9b2a-kickoff","label":"Kickoff 2027 deck"}]"#, hold: #"{"sessionId":"claude:4f1e9b2a-kickoff","label":"Kickoff 2027 deck"}"#),
    view("7b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed", "Ask Jeremy if the Bottle POS price test needs legal review", 13_000, source: "mac", state: "undone", dest: "new_card", kind: "task", status: "undone"),
]

func details(_ json: String) -> [String: JSONValue] {
    try! JSONDecoder().decode(HelperResponse.self, from: Data((#"{"ok":true,"message":"x","details":"# + json + "}").utf8)).details
}
func answered(_ body: String) -> HelperResponse {
    HelperResponse(ok: true, message: "x", details: details(#"{"transport":"answered","httpStatus":200,"# + body + "}"))
}
nonisolated(unsafe) var uploadCount = 0
/// The stand-in for the helper's drop-it ops.
@MainActor func fixtureRun(feedOn: Bool = true, waiting: Int? = 1) -> DropItStore.Run {
    { args, _ in
        switch args.count > 2 ? args[2] : "" {
        case "summary": return answered(#""unread":2,"lastLine":"Re: what did Jeremy say about the Q4 numbers. Use the approved Q4 numbers, not the forecast.","lastAt":"\#(iso(38))","version":13"# + (waiting.map { #","waiting":\#($0)"# } ?? ""))
        case "feed": return answered(#""items":[\#(feedOn ? feedItems.joined(separator: ",") : "")],"version":13,"more":false"#)
        case "history": return answered(#""drops":[\#(historyDrops.joined(separator: ","))],"more":false,"cardStates":"read""#)
        case "read": return answered(#""unread":2,"version":13"#)
        case "get": return answered(#""drop":\#(historyDrops[2]),"items":[],"replayed":false"#)
        case "settings": return answered(#""protocol":1,"enabled":true,"source":"settings""#)
        case "upload":
            uploadCount += 1
            return answered(#""mediaId":"m_\#(String(format: "%024x", uploadCount))""#)
        default: throw CancellationError()
        }
    }
}

/// 0.5.371 composer fixtures: a store-front photo and a one-page PDF, drawn here (no real files), in the scratch home.
func fixtureFiles() -> (photo: URL, pdf: URL) {
    let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("composer-fixtures", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let photo = folder.appendingPathComponent("Clover switcher store front.png"), pdf = folder.appendingPathComponent("Price test brief.pdf")
    let image = NSImage(size: NSSize(width: 1600, height: 1200), flipped: false) { rect in
        NSGradient(colors: [NSColor(srgbRed: 0.83, green: 0.62, blue: 0.36, alpha: 1), NSColor(srgbRed: 0.32, green: 0.22, blue: 0.14, alpha: 1)])!.draw(in: rect, angle: -60)
        NSColor(srgbRed: 0.96, green: 0.92, blue: 0.84, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 260, y: 220, width: 1080, height: 620), xRadius: 30, yRadius: 30).fill()
        NSColor(srgbRed: 0.42, green: 0.28, blue: 0.16, alpha: 1).setFill()
        for i in 0..<5 { NSBezierPath(rect: NSRect(x: 330 + i * 200, y: 300, width: 140, height: 380)).fill() }
        return true
    }
    if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) { try? rep.representation(using: .png, properties: [:])?.write(to: photo) }
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    if let consumer = CGDataConsumer(url: pdf as CFURL), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) {
        ctx.beginPDFPage(nil); ctx.setFillColor(NSColor.black.cgColor); ctx.fill(CGRect(x: 72, y: 700, width: 300, height: 14)); ctx.endPDFPage(); ctx.closePDF()
    }
    return (photo, pdf)
}

/// A store whose composer has the two fixture files up.
@MainActor func composerStore() async -> DropItStore {
    let model = seededModel(dropIt: true)
    let store = model.dropIt
    store.stagingRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("composer-staging", isDirectory: true)
    let files = fixtureFiles()
    store.attach([(files.photo, files.photo.lastPathComponent), (files.pdf, files.pdf.lastPathComponent)])
    for _ in 0..<300 where store.attachments.contains(where: \.busy) { try? await Task.sleep(nanoseconds: 10_000_000) }
    await store.loadFeed(opening: true)
    return store
}

/// Recent turns shaped like the mock's list (the unchanged Messages rows).
func turns() -> [GlassesTurn] {
    let rows: [(String, String, String?, String?)] = [
        ("What did Jeremy say about the Q4 numbers in QLT Monthly?", "Use the approved Q4 numbers, not the forecast. He wants the same figures in the Kickoff 2027 deck and the board pack.", "sonnet", nil),
        ("Pricing page header spacing is too tight on mobile, add that to Hubspot Theme Settings", "Added to the Hubspot Theme Settings thread as a note for the Codex session working on it now.", "sonnet", nil),
        ("Marketing priorities slides", "Finished in 18 min. 12 slides saved to this week's folder, with the Bottle POS price test on slide 4.", nil, "task"),
        ("Who was the third voice in QLT Monthly?", "Unidentified. One voice is close to Jeremy at a 0.82 match. The other two have no match yet.", "opus", nil),
        ("Morning brief", "Three meetings today and two decisions waiting. Kickoff 2027 Planning is at 3:00 PM.", nil, "routine"),
    ]
    return rows.enumerated().map { index, row in
        GlassesTurn(id: "turn-\(index)", no: 214 - index, timestamp: base.addingTimeInterval(-Double(index * 70 + 12) * 60).timeIntervalSince1970, query: row.0, text: row.1,
                    sessionId: "g2_session_\(index)", source: "glasses", modelPreference: row.2, origin: row.3, originId: row.3.map { _ in "fixture-\(index)" })
    }
}

@MainActor func seededModel(dropIt on: Bool, supported: Bool = true, waiting: Int? = 1) -> ControllerModel {
    let model = ControllerModel(startBackgroundWork: false)
    model.status = ServerStatus(["installed": .bool(true), "running": .bool(true)])
    model.status.running = true; model.status.installed = true; model.status.managedContract = true; model.status.ownershipVerified = true
    model.status.dropIt = DropItCapability(protocolVersion: supported ? 1 : nil, enabled: on, source: "settings")
    model.dropIt.run = fixtureRun(waiting: waiting)
    return model
}

/// The Messages section with its data: the launch section first, then the turns once the window's own (failing) load is done.
@MainActor func pump(_ seconds: Double = 0.6) { let end = Date().addingTimeInterval(seconds); while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }

@MainActor func renderWindow(_ model: ControllerModel, width: CGFloat, height: CGFloat, name: String, out: URL, after: @MainActor () -> Void) throws {
    for appearance in [NSAppearance.Name.darkAqua, .aqua] {
        let host = NSHostingView(rootView: ActivityWindow(model: model).frame(width: width, height: height).cosControlTheme())
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        model.activityOpenSection = .messages
        pump(1.0)
        model.recentMessages = turns(); model.recentGlassesStatus = .ready
        after()
        pump(1.4)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name)-\(appearance == .darkAqua ? "dark" : "light").png"))
        window.contentView = nil
        window.close()
    }
}

@MainActor func render<V: View>(_ view: V, width: CGFloat, height: CGFloat? = nil, name: String, out: URL) throws {
    var h = height ?? 0
    if height == nil {
        let sizer = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true).cosControlTheme())
        sizer.layoutSubtreeIfNeeded(); h = max(80, ceil(sizer.fittingSize.height))
    }
    for appearance in [NSAppearance.Name.darkAqua, .aqua] {
        let host = NSHostingView(rootView: view.frame(width: width, height: h, alignment: .top).background(TodayInk.page).cosControlTheme())
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: h), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: h))
        pump(1.2)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name)-\(appearance == .darkAqua ? "dark" : "light").png"))
        window.contentView = nil
        window.close()
    }
}

/// The hub's Work chat card holding only the Drop it row.
struct SettingsRowCard: View {
    @ObservedObject var model: ControllerModel
    var body: some View {
        SettingsHubCard(group: SettingsHubCatalog.group("work.chat")!, advancedCount: 0, advancedOpen: .constant(false)) {
            DropItSettingRow(model: model, store: model.dropIt)
        } advanced: { EmptyView() }
        .environment(\.settingsHubHosted, true)
        .padding(16)
    }
}

@main @MainActor struct DropItRender {
    nonisolated(unsafe) static var passed = 0
    static func check(_ condition: Bool, _ what: String) {
        guard condition else { print("drop it wiring check FAILED: \(what)"); exit(1) }
        passed += 1
    }

    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let mode = CommandLine.arguments.dropFirst().first ?? "check"
        if mode == "render" {
            guard NSHomeDirectory().contains("cos-drop-it") else { fputs("run through Tests/run-drop-it.sh (a scratch home)\n", stderr); exit(2) }
            let out = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            UserDefaults.standard.set(true, forKey: TodayHome.enabledKey)
            // Messages with the pinned row, then the same window with Drop it off (the list exactly as before).
            try renderWindow(seededModel(dropIt: true), width: 1280, height: 860, name: "1-messages-cos-pinned", out: out) {}
            try renderWindow(seededModel(dropIt: false), width: 1280, height: 860, name: "1b-messages-drop-it-off", out: out) {}
            // 0.5.371 (plan section 12): the rail with unread only (a server that sends no waiting): a dot, no number.
            try renderWindow(seededModel(dropIt: true, waiting: nil), width: 1280, height: 860, name: "1c-messages-rail-dot", out: out) {}
            // The chat, in the window (opened the way the pinned row opens it).
            let chatModel = seededModel(dropIt: true)
            try renderWindow(chatModel, width: 1280, height: 1500, name: "2-cos-chat", out: out) { chatModel.openDropItChat() }
            // History, in the window.
            let historyModel = seededModel(dropIt: true)
            try renderWindow(historyModel, width: 1280, height: 900, name: "3-history", out: out) { historyModel.openDropItHistory() }
            // The chat alone at the window's narrowest content width.
            let narrow = seededModel(dropIt: true)
            try render(DropItChatPane(store: narrow.dropIt, onAllMessages: {}, onHistory: {}, onOpen: { _, _ in }, polls: false), width: 540, height: 1200, name: "4-cos-chat-540", out: out)
            // The composer with words in it: Drop it lights up.
            let typed = seededModel(dropIt: true)
            try render(DropItChatPane(store: typed.dropIt, onAllMessages: {}, onHistory: {}, onOpen: { _, _ in }, polls: false,
                                      initialDraft: "Bottle POS: ask Gina for two Clover switcher stories for the price test page"), width: 1000, height: 760, name: "4b-composer-typed", out: out)
            // 0.5.371 option A: the composer, empty; typed with a photo and a PDF; mid drag-over; and after an Ask with files.
            let composerOut = CommandLine.arguments.count > 3 ? URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true) : out
            try FileManager.default.createDirectory(at: composerOut, withIntermediateDirectories: true)
            let empty = seededModel(dropIt: true)
            try render(DropItChatPane(store: empty.dropIt, onAllMessages: {}, onHistory: {}, onOpen: { _, _ in }, polls: false), width: 1000, height: 760, name: "1-composer-empty", out: composerOut)
            let typedFiles = await composerStore()
            try render(DropItChatPane(store: typedFiles, onAllMessages: {}, onHistory: {}, onOpen: { _, _ in }, polls: false,
                                      initialDraft: "What should the price test page say to stores switching from Clover?"), width: 1000, height: 760, name: "2-composer-typed-two-files", out: composerOut)
            let dragging = await composerStore()
            try render(DropItChatPane(store: dragging, onAllMessages: {}, onHistory: {}, onOpen: { _, _ in }, polls: false,
                                      initialDraft: "What should the price test page say to stores switching from Clover?", initialTargeted: true), width: 1000, height: 760, name: "3-composer-drag-over", out: composerOut)
            let asked = await composerStore()
            asked.askJob = { _, _, _, _, _ in .started("8b1c2b3a-4d5e-4f60-8a7b-9c0d1e2f3a4b") }
            asked.askState = { ids in [ids[0]: DropIt.AskState(status: "completed", answer: "Lead with the switch, not the discount. The photo shows a counter built for Clover's terminal, so open with *we move your items and history for you*. The brief's $10 offer works as the second line. Use the two store stories Gina is pulling.", number: 216)] }
            _ = await asked.ask("What should the price test page say to stores switching from Clover?")
            await asked.refreshAsks()
            try render(DropItChatPane(store: asked, onAllMessages: {}, onHistory: {}, onOpen: { _, _ in }, polls: false), width: 1000, height: 1100, name: "4-after-ask-with-files", out: composerOut)
            // Drop with files on a server that takes words only: nothing is dropped, the line says why.
            let oldServer = await composerStore()
            oldServer.dropTakes = nil
            _ = await oldServer.send("File these for the price test")
            try render(DropItChatPane(store: oldServer, onAllMessages: {}, onHistory: {}, onOpen: { _, _ in }, polls: false,
                                      initialDraft: "File these for the price test"), width: 1000, height: 760, name: "5-drop-files-older-server", out: composerOut)
            // Settings: the Drop it row in Work chat, on and off.
            try render(SettingsRowCard(model: seededModel(dropIt: true)), width: 720, name: "5-settings-drop-it-on", out: out)
            try render(SettingsRowCard(model: seededModel(dropIt: false)), width: 720, name: "5b-settings-drop-it-off", out: out)
            // 0.5.372: Settings, Work and agents, COS reaching out, as the server's P2 settings answer it.
            let reach = DropItP2Store(run: { _, _ in
                answered(#""protocol":1,"settings":{"pings":{"on":true,"dailyCap":6,"perSource":2,"gapMinutes":45,"quietStart":"18:00","quietEnd":"06:00","weekendsQuiet":true,"firstBanner":"08:00","sources":{"prep":true,"agent":true,"followups":true,"stale":false,"signals":true}},"followUps":{"on":true,"kinds":{"card":true,"handoff":true,"session":true,"thread":false}},"checkin":{"on":true,"weekday":1,"time":"09:00"},"reminders":{"defaultTime":"09:00","snoozeMinutes":60,"banners":true,"lensPush":true},"banners":{"reminder":true,"resolution":true,"prep":false,"agent":false,"followups":false,"stale":false,"checkin":false},"steer":{"about":"JCK, Rain","leaveAlone":"HubDB"}}"#)
            }, defaults: UserDefaults(suiteName: "drop-it-render-reach")!)
            await reach.readSettings()
            try render(DropItReachRows(store: reach), width: 720, name: "7-settings-cos-reaching-out", out: out)
            // The strip a deep link leaves on the pane it opened.
            try render(DropItCameBackStrip(line: DropIt.cameBackCard, back: {}), width: 900, name: "6-back-to-the-chat", out: out)
            print("DropItRender wrote PNGs to \(out.path)")
            return
        }

        // ── wiring checks
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 180)
            print("drop it wiring check FAILED: [timeout] the wiring checks did not finish in 180 s"); exit(1)
        }
        let off = seededModel(dropIt: false)
        off.openDropItChat()
        check(!off.dropItChatRouteActive && !off.dropItChatOpen, "[route gate] with Drop it off the chat never opens")
        let old = seededModel(dropIt: true, supported: false)
        old.openDropItChat(); old.openDropItHistory()
        check(!old.dropItChatRouteActive && !old.dropItHistoryRouteActive, "[route gate] an older server never opens the chat or History")
        let on = seededModel(dropIt: true)
        on.openDropItChat()
        check(on.dropItChatRouteActive && !on.dropItHistoryRouteActive, "[chat route] the opener writes the chat's flag")
        on.openDropItHistory()
        check(on.dropItHistoryRouteActive && on.dropItChatRouteActive, "[history route] History sits one rung above the chat")
        on.closeDropItHistory()
        check(!on.dropItHistoryRouteActive && on.dropItChatRouteActive, "[history back] History's Back lands on the chat")
        on.status.dropIt.enabled = false
        check(!on.dropItChatRouteActive, "[route gate] the server turning it off unmounts the chat")
        on.status.dropIt.enabled = true
        on.dropIt.run = { args, _ in
            args.count > 2 && args[2] == "settings-set" ? answered(#""protocol":1,"enabled":false,"source":"settings""#) : HelperResponse(ok: true, message: "x", details: [:])
        }
        await on.setDropItEnabled(false)
        check(!on.status.dropIt.enabled && !on.dropItChatOpen && !on.dropItHistoryOpen, "[settings off] turning it off in Settings closes the chat")

        // ⌘K: the old row exactly while off, Drop it while on.
        var inputs = SetupAssistant.Center.Inputs()
        inputs.snapshot.serverReachable = true
        let offRow = SetupAssistant.Center.listing(inputs, words: "call Dave about the Kickoff deck").rows.first { $0.id == "file" }
        check(offRow?.title == "File to Work" && offRow?.detail == "Saves your words to the Work inbox. No run." && offRow?.trailing == "Option-Return",
              "[command row off] File to Work, exactly as before")
        inputs.snapshot.dropIt = true
        let onRows = SetupAssistant.Center.listing(inputs, words: "call Dave about the Kickoff deck").rows
        check(onRows.filter { $0.id == "file" }.count == 1 && onRows.first { $0.id == "file" }?.title == "Drop it" && onRows.first { $0.id == "file" }?.kind == .file
              && onRows.last?.id == "file", "[command row on] the same row, last, says Drop it")

        // Settings: the row and its search entry.
        let entry = SettingsHubCatalog.item("DROP-01")
        check(entry?.group == "work.chat" && entry?.advanced == false && entry?.label == DropIt.settingLabel && entry?.detail == DropIt.settingDetail, "[settings row] DROP-01 is a Work chat row with the chat's words")
        for query in ["drop it", "file to work", "cos chat", "pinned"] {
            check(SettingsHubSearch.results(query).flatMap(\.items).map(\.id).contains("DROP-01"), "[settings search] found by \(query)")
        }
        check(!SettingsHubSearch.results("drop it", itemShown: { $0 != "DROP-01" }).flatMap(\.items).map(\.id).contains("DROP-01"), "[settings search] hidden for a server without it")
        print("drop it wiring checks: \(passed) passed")
        print("PASS: drop it wiring checks complete")
    }
}
