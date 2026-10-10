import AppKit
import SwiftUI
import Foundation

/// Offscreen native render of the 0.5.232 Markdown panes, LIGHT AND DARK: the meeting
/// pane on the scribe's own file (the pane Miles showed on 2026-09-15), the thread pane
/// on a sectioned note, and the three action weights side by side. Same harness shape
/// as MergeUI: a real NSHostingView in an offscreen window, `cacheDisplay` so ScrollView
/// contents and native controls draw. Run by hand on a logged-in Mac:
///     ./Tests/run-markdown-ui.sh /tmp/cos-markdown-ui
/// Asserts: the pane fills its window, the render is not blank, the document view
/// carries no raw `## ` or `<details>` text (the shipped 0.5.231 body did), and the
/// primary button is the first control in the action row.
@main @MainActor
struct MarkdownPaneUIContract {
    static func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.16)) }

    static func render<V: View>(
        _ view: V, size: NSSize, name: String, output: URL, dark: Bool, fills: Bool = true
    ) throws -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = NSColor(COSPalette.panel)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        // 0.5.253: never ordered in, even off screen; the window is laid out and drawn where nobody sees it.
        pump(); host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); pump()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            fatalError("No native bitmap for \(name)")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG for \(name)") }
        try png.write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        precondition(host.bounds.width <= size.width && host.bounds.height <= size.height,
                     "content escaped the window clamp in \(name): \(host.bounds.size) vs \(size)")
        if fills {
            precondition(host.bounds.width == size.width && host.bounds.height == size.height,
                         "a pane must take the whole window it is given in \(name): \(host.bounds.size) vs \(size)")
        }
        precondition(png.count > 5000, "native render of \(name) came out blank")
        return (window, host)
    }

    /// Every NSTextField/NSTextView string under a view, for the raw-markdown assertion.
    static func strings(_ view: NSView) -> [String] {
        var out: [String] = []
        if let field = view as? NSTextField { out.append(field.stringValue) }
        if let text = view as? NSTextView { out.append(text.string) }
        for sub in view.subviews { out.append(contentsOf: strings(sub)) }
        return out
    }

    static let meeting = """
    # Bottle POS Funnel Deck Discovery (G2)

    | Field | Value |
    |-------|-------|
    | **Date** | 2026-09-15 15:37 |
    | **Source** | G2 Glasses |
    | **Domain** | Quilt |
    | **Type** | Review |
    | **Duration** | 3 minutes |

    ## Attendees

    - MU
    - Cort Ouzts

    ## Summary

    Tail-end capture of a Quilt working session on the Bottle POS funnel PowerPoint. Cort set the approach: treat slides 8-12 as the agenda, add or delete as findings are described, and keep the deck in discovery mode rather than final. Tyler committed to Slack Peter and Mary about extra working time outside tomorrow's 1:1.

    ## Topics Discussed

    - Bottle POS funnel deck structure
    - Discovery-driven slide editing
    - Follow-up scheduling with Peter and Mary

    ## Decisions Made

    - The shared Bottle funnel PowerPoint is the working document; slides 8-12 stay as the agenda/table of contents and get added to or deleted live during discovery. The deck is a draft, not final.

    ## Action Items


    ### Needs Review
    - [ ] `[REVIEW]` Send a Slack message to Peter and Mary to coordinate support and, if needed, schedule additional working time beyond tomorrow's 1:1. (Tyler Rhoton)

    ## Transcript

    <details>
    <summary>Click to expand transcript</summary>

    [Cort Ouzts]: See if you can do that , and then we 'll go from there . I just want to work off this bottle funnel PowerPoint . Is that
    [Ext]: shared ? That 's the shared , right ? Yeah , it 's the shared . I 'm Cara . We 'll leave section or slides 8 through 12 as kind of an agenda ,
    [Cort Ouzts]: a table of contents , if you will . Again , add to it . Just delete it as you 're describing it .
    [Tyler Rhoton]: in mobile list . Peter , Mary , I 'll send you a Slack too to see what I can do to help . Okay . All right , guys . Thank you .
    [Ext]: Thank you .
    [MU]: Thank you .

    </details>
    """

    static let thread = """
    # Bottle POS funnel deck

    **Status:** accelerating · **Owner:** Miles · **Next:** Tuesday 1:1

    ## Note

    Discovery deck for the Bottle POS funnel. Slides 8-12 are the agenda; findings get added live.

    ## Stakeholders

    | Person | Role |
    |---|---|
    | Cort Ouzts | Sales lead |
    | Tyler Rhoton | Account executive |

    ## Meetings

    - 2026-09-15 Bottle POS Funnel Deck Discovery (G2)
    - 2026-09-12 Funnel review

    ## Milestones

    1. Discovery deck in review
    2. Findings folded into slides 8-12

    <details><summary>Sources</summary>

    - operations/quilt/wk38_2026/bottle_funnel_deck.md
    - operations/quilt/meetings/2026-09/2026-09-15_Bottle_POS_Funnel_Deck_Discovery_(G2).md

    </details>
    """


    /// Message #356 exactly as the glasses server stored it (2026-10-09): the answer that
    /// printed `**Take Varesa.**` and `- [allthings.how: …](https://…)` raw in Messages.
    static let message356 = """
    **Take Varesa.** Neither Vesna nor Chiori is the best call. Vesna isn't actually in the free pool. She's the new 7.1 banner character, and your roster shows her at C2 already, so I'm assuming you meant Varesa. The free selector offers Varesa, Clorinde, Nilou, Baizhu, Chiori and Tartaglia, and you need to finish the 7.1 Archon Quest by November 3 to claim one.

    1. **Varesa:** She fits your best units. Her strongest team runs her with Xilonen and Mavuika, and you have both, with Mavuika at C6. If Iansan is in your 3 characters off-screen, that's her ideal setup. She'd give you a second top-tier main DPS next to Mavuika.
    2. **Clorinde:** She works with your C6 Fischl and Nahida, but she needs C2 to really pay off. Your Electro slot is already covered by Yae (C2) and Raiden.
    3. **Chiori:** Skip her. She needs a full Geo team, and you only have Albedo and Xilonen. She'd end up as an off-field support you don't need.

    The one reason to take Clorinde instead: if Iansan isn't in your account and you mainly play Fischl and Nahida teams.

    Sources:
    - [allthings.how: 7.1 selector best pick](https://allthings.how/genshin-impact-limited-5-star-selector-best-pick-in-version-7-1/)
    - [timesaver.gg: all selector characters and deadlines](https://timesaver.gg/blog/genshin-free-5-star-selector-7-1)
    - [ldshop.gg: 7.1 anniversary selector guide](https://www.ldshop.gg/blog/genshin-impact/7-1-anniversary-selector-guide.html)
    """
    static let query356 = "[2 Attachments] Based on my roster which free latern pull is better for me? Chlorine or vesna or chiori"

    /// The Messages detail as the pane lays it out: header, YOU card, COS card.
    /// `markdown: false` is the pre-2026-10-09 COS card (one plain Text), for the before shot.
    @ViewBuilder
    static func messageDetail(text: String, markdown: Bool, highlight: String = "", id: String = "turn:9dcc19f0:356") -> some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Message #356").font(.system(size: 19, weight: .semibold))
                    Text("17:28 · Opus · live").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy turn") {}
                Button("Copy + images") {}
            }
            .controlSize(.small)
            ActivityMessageCard(label: "You", text: query356, tint: ActivitySection.messages.tint, highlight: highlight)
            ActivityMessageCard(label: "COS", text: text, tint: COSPalette.green, highlight: highlight, markdownID: markdown ? id : nil)
        }
        .padding(28)
        .frame(maxWidth: 820, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(COSPalette.panel)
    }

    /// Where on the host each selectable text view sits, for the no-overflow assertion.
    static func textFrames(_ view: NSView, in host: NSView) -> [(String, NSRect)] {
        var out: [(String, NSRect)] = []
        if let field = view as? NSTextField { out.append((field.stringValue, field.convert(field.bounds, to: host))) }
        if let text = view as? NSTextView { out.append((text.string, text.convert(text.bounds, to: host))) }
        for sub in view.subviews { out.append(contentsOf: textFrames(sub, in: host)) }
        return out
    }

    /// Every link attribute drawn under a view (selectable text is a field or a text view).
    static func drawnLinks(_ view: NSView) -> [String] {
        var out: [String] = []
        func scan(_ a: NSAttributedString) {
            a.enumerateAttribute(.link, in: NSRange(location: 0, length: a.length)) { value, _, _ in
                if let url = value as? URL { out.append(url.absoluteString) } else if let s = value as? String { out.append(s) }
            }
        }
        if let field = view as? NSTextField { scan(field.attributedStringValue) }
        if let text = view as? NSTextView, let storage = text.textStorage { scan(storage) }
        for sub in view.subviews { out.append(contentsOf: drawnLinks(sub)) }
        return out
    }

    /// The drawn attributed string of the first text field or view whose text contains `needle`.
    static func drawnText(_ view: NSView, containing needle: String) -> NSAttributedString? {
        if let field = view as? NSTextField, field.stringValue.contains(needle) { return field.attributedStringValue }
        if let text = view as? NSTextView, text.string.contains(needle), let storage = text.textStorage { return storage }
        for sub in view.subviews { if let hit = drawnText(sub, containing: needle) { return hit } }
        return nil
    }

    /// Every construct a COS answer uses, in one answer.
    static let constructs = """
    ## What changed

    A *small* fix with `inline code` and **bold**, then ***both***.

    > A quoted line from the brief.

    1. **First:** a numbered item
       - a nested bullet
    2. Second item

    ```
    let answer = 42
    ```

    ### Links

    - [web](https://gotcos.com/control/)
    - [file](file:///etc/hosts)
    - [script](javascript:alert(1))
    - [mail](mailto:miles@example.com)
    """

    /// Messages (2026-10-09): Message #356 before and after, light and dark; the cache, the
    /// copy text, a half-streamed answer and a bare URL at a narrow width.
    static func messages(output: URL) throws {
        let size = NSSize(width: 760, height: 1180)
        for dark in [false, true] {
            let (_, before) = try render(messageDetail(text: message356, markdown: false), size: size, name: "message-356-before", output: output, dark: dark)
            let raw = strings(before).joined(separator: "\n")
            precondition(raw.contains("**Take Varesa.**") && raw.contains("](https://allthings.how"), "[message 356] the before shot is the raw text (the check below can fail)")

            let parsesBefore = COSMarkdownCache.parseCount
            let (_, after) = try render(messageDetail(text: message356, markdown: true), size: size, name: "message-356-after", output: output, dark: dark)
            let text = strings(after).joined(separator: "\n")
            precondition(!text.contains("**"), "[message 356] no bold markers on screen")
            precondition(!text.contains("]("), "[message 356] no link syntax on screen")
            precondition(text.contains("Take Varesa. Neither Vesna"), "[message 356] the lead line renders its words")
            precondition(text.contains("Varesa: She fits your best units."), "[message 356] the first pick renders without markers")
            precondition(text.contains("allthings.how: 7.1 selector best pick"), "[message 356] a source shows its label")
            precondition(text.contains("Sources:"), "[message 356] the Sources line renders")
            precondition(!text.contains("1. Varesa"), "[message 356] the number is the list marker, not part of the item text")
            precondition(text.contains("[2 Attachments] Based on my roster"), "[message 356] the YOU card shows the question as typed")
            let links = drawnLinks(after)
            precondition(Set(links) == ["https://allthings.how/genshin-impact-limited-5-star-selector-best-pick-in-version-7-1/", "https://timesaver.gg/blog/genshin-free-5-star-selector-7-1", "https://www.ldshop.gg/blog/genshin-impact/7-1-anniversary-selector-guide.html"], "[message 356] the three sources link to their pages: \(links)")
            // Parse once per message id + text: a second render of the same turn parses nothing.
            let parsedOnce = COSMarkdownCache.parseCount
            precondition(parsedOnce - parsesBefore <= 1, "[parse once] one turn parses at most once per render pass: \(parsedOnce - parsesBefore)")
            let inlineOnce = COSMarkdownInlineCache.parseCount
            _ = try render(messageDetail(text: message356, markdown: true), size: size, name: "message-356-after-redraw", output: output, dark: dark)
            precondition(COSMarkdownCache.parseCount == parsedOnce, "[parse once] a redraw of the same turn must not parse the document again")
            precondition(COSMarkdownInlineCache.parseCount == inlineOnce, "[parse once] a redraw must not re-run the inline parser")
            // The search mark lands on rendered words, including inside bold.
            let (_, searched) = try render(messageDetail(text: message356, markdown: true, highlight: "varesa"), size: size, name: "message-356-search", output: output, dark: dark)
            if let lead = drawnText(searched, containing: "Take Varesa. Neither") {
                let at = (lead.string as NSString).range(of: "Varesa").location
                precondition(lead.attribute(.backgroundColor, at: at, effectiveRange: nil) != nil, "[search mark] the term inside **bold** is marked on screen")
                precondition(lead.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil, "[search mark] only the term is marked")
            } else { preconditionFailure("[search mark] the lead paragraph renders") }
            precondition(COSMarkdownCache.parseCount == parsedOnce, "[parse once] a search mark is not a reparse")
        }

        // Every construct, light and dark: headings, emphasis, code, quote, nested list, fence, links.
        for dark in [false, true] {
            let (_, host) = try render(messageDetail(text: constructs, markdown: true, id: "turn:constructs"), size: NSSize(width: 760, height: 900), name: "message-constructs", output: output, dark: dark)
            let text = strings(host).joined(separator: "\n")
            for raw in ["## ", "**", "`", "> A quoted", "```", "](", "1. **"] { precondition(!text.contains(raw), "[constructs] raw \(raw) on screen") }
            for words in ["What changed", "A small fix with inline code and bold, then both.", "A quoted line from the brief.", "First: a numbered item", "a nested bullet", "let answer = 42", "web", "file", "script", "mail"] {
                precondition(text.contains(words), "[constructs] \(words) renders")
            }
            // DM Sans has no italic face: *small* takes the system italic at the body size.
            if let line = drawnText(host, containing: "A small fix") {
                let at = (line.string as NSString).range(of: "small").location
                let font = line.attribute(.font, at: at, effectiveRange: nil) as? NSFont
                precondition(font.map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } == true, "[italic] *small* draws italic: \(String(describing: font))")
                let upright = line.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                precondition(upright.map { !NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } == true, "[italic] the rest of the line stays upright")
            } else { preconditionFailure("[constructs] the emphasis line renders") }
            let links = drawnLinks(host)
            precondition(links == ["https://gotcos.com/control/"], "[web links only] only the https link is a link on screen: \(links)")
        }

        // Streaming: the live turn grows; each new text parses once into the SAME slot, and a
        // half-written ** or [ stays on screen as text.
        let cut = message356.range(of: "Clorinde:** She")!.lowerBound
        let partial = String(message356[..<cut]) + "Clorin"
        let midLink = String(message356[..<message356.range(of: "selector best pick")!.upperBound])
        let p0 = COSMarkdownCache.parseCount
        for (n, sample) in [partial, midLink].enumerated() {
            for dark in [false, true] {
                let (_, host) = try render(messageDetail(text: sample, markdown: true, id: "turn:stream"), size: size, name: "message-356-streaming-\(n + 1)", output: output, dark: dark)
                let text = strings(host).joined(separator: "\n")
                if n == 0 { precondition(text.contains("**Clorin"), "[streaming] an unclosed ** is drawn as text: \(text.suffix(80))") }
                if n == 1 { precondition(text.contains("[allthings.how: 7.1 selector best pick"), "[streaming] an unclosed link is drawn as text") }
                precondition(text.contains("Take Varesa. Neither"), "[streaming] the closed bold above it still renders")
            }
        }
        precondition(COSMarkdownCache.parseCount - p0 == 2, "[parse once] two streamed texts, two parses, whatever the redraws: \(COSMarkdownCache.parseCount - p0)")

        // A bare URL at a narrow width wraps inside the card instead of running past it.
        let bare = "Sources:\n\nhttps://allthings.how/genshin-impact-limited-5-star-selector-best-pick-in-version-7-1/\n\nhttps://www.ldshop.gg/blog/genshin-impact/7-1-anniversary-selector-guide.html"
        for dark in [false, true] {
            let narrow = NSSize(width: 420, height: 520)
            let (_, host) = try render(messageDetail(text: bare, markdown: true, id: "turn:bare"), size: narrow, name: "message-bare-urls", output: output, dark: dark)
            let frames = textFrames(host, in: host).filter { $0.0.contains("https://") }
            precondition(frames.count == 2, "[bare url] both URLs render as selectable text: \(frames.count)")
            for (string, frame) in frames {
                precondition(frame.maxX <= host.bounds.maxX - 28 + 0.5, "[bare url] \(string.prefix(30)) runs past the card: \(frame) in \(host.bounds)")
                precondition(frame.height > 20, "[bare url] a long URL wraps onto more than one line: \(frame)")
            }
        }

        // Copy turn and Copy + images read the stored turn, never the rendered one.
        let turn = GlassesTurn(id: "9dcc19f0:356", no: 356, timestamp: 1_791_584_905, query: query356, text: message356, sessionId: "9dcc19f0", source: "live")
        precondition(turn.turnClipboardText == "[Msg 356] User: \(query356)\n[Msg 356] COS: \(message356)", "[copy raw] Copy turn copies the stored Markdown byte for byte")
        precondition(turn.turnClipboardText.contains("**Take Varesa.**") && turn.turnClipboardText.contains("- [allthings.how: 7.1 selector best pick](https://"), "[copy raw] the copy keeps the Markdown")
        let archived = ArchiveMessage(.object(["no": .number(356), "query": .string(query356), "text": .string(message356), "timestamp": .number(1_791_584_905_443)]), ordinal: 0)
        precondition(archived?.clipboardText == turn.turnClipboardText, "[copy raw] an archived chat's Copy turn is the same raw text")

        // Copy answer (Messages COS card) and Copy reply (session chat) copy the stored Markdown.
        // A private named pasteboard, so the check never touches the clipboard of the person
        // running it.
        let board = NSPasteboard(name: NSPasteboard.Name("com.cos.control.tests.markdown-ui.\(ProcessInfo.processInfo.processIdentifier)"))
        defer { board.releaseGlobally() }
        ActivityAnswerCopy.copy(message356, to: board)
        let copied = board.string(forType: .string)
        precondition(copied == message356, "[copy reply] Copy reply and Copy answer copy the stored Markdown byte for byte: \(String(describing: copied?.prefix(40)))")
        precondition(copied?.contains("**Take Varesa.**") == true && copied?.contains("](https://allthings.how") == true, "[copy reply] the copy keeps the Markdown markers")

        // The session chat reply renders as Markdown, and its bubble hugs a short reply while a
        // long one takes the row, as the plain Text it replaced did.
        let short = "Done. Pushed **feat/messages-markdown**."
        let offered = NSSize(width: 640, height: 4000)
        for dark in [false, true] {
            // The row as SessionChatComposer lays it out: the bubble, then a Spacer of at least 60 pt.
            let row = HStack { SessionChatReplyBubble(text: short, id: "hug-short"); Spacer(minLength: 60) }
                .padding(16).frame(width: 640, height: 80, alignment: .topLeading).background(COSPalette.panel)
            let (_, host) = try render(row, size: NSSize(width: 640, height: 80), name: "session-chat-short", output: output, dark: dark)
            let text = strings(host).joined(separator: "\n")
            precondition(text.contains("Done. Pushed feat/messages-markdown.") && !text.contains("**"), "[session chat] a reply renders its Markdown: \(text)")
        }
        let shortWidth = NSHostingController(rootView: SessionChatReplyBubble(text: short, id: "hug-short")).sizeThatFits(in: offered).width
        let longWidth = NSHostingController(rootView: SessionChatReplyBubble(text: message356, id: "hug-long")).sizeThatFits(in: offered).width
        precondition(shortWidth < 360, "[hug] a short reply's bubble hugs its words, not the row: \(shortWidth) of \(offered.width)")
        precondition(abs(longWidth - offered.width) < 0.5, "[hug] a long reply's bubble takes the whole row, as wide as before: \(longWidth) of \(offered.width)")

        // The real inline cache under a stream: twice its capacity of new prefixes, with the
        // paragraph on screen drawn after each one, must never parse that paragraph again.
        let onScreen = "Take **Varesa**: the paragraph already on screen."
        _ = COSMarkdownInlineCache.attributed(onScreen, italicSize: 13)
        let before = COSMarkdownInlineCache.parseCount
        let streamed = 2 * COSMarkdownInlineCache.capacity
        for i in 0..<streamed {
            _ = COSMarkdownInlineCache.attributed("The live answer, token \(i)", italicSize: 13)
            _ = COSMarkdownInlineCache.attributed(onScreen, italicSize: 13)
        }
        precondition(COSMarkdownInlineCache.parseCount - before == streamed, "[lru] a stream of \(streamed) prefixes parses each prefix once and never the paragraph on screen: \(COSMarkdownInlineCache.parseCount - before) parses")
    }

    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/cos-markdown-ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        // The app registers its bundled fonts from its own Resources; this binary has none, and
        // without DM Sans every bold run fell back to an upright regular face in the renders.
        let root = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ".")
        for name in ["Fraunces", "Fraunces-Italic", "DMSans", "JetBrainsMono"] {
            CTFontManagerRegisterFontsForURL(root.appendingPathComponent("Resources/Fonts/\(name).ttf") as CFURL, .process, nil)
        }
        precondition(NSFont(name: "DM Sans", size: 12) != nil || NSFontManager.shared.availableMembers(ofFontFamily: "DM Sans") != nil, "DM Sans registers for the renders")

        let model = ControllerModel(startBackgroundWork: false)
        precondition(!model.backgroundWorkEnabled)

        model.openLibraryRow = LibraryMeeting(.object([
            "recordId": .string("2026-09/2026-09-15_Bottle_POS_Funnel_Deck_Discovery_(G2).md"),
            "sessionId": .string("meeting_1789508220_g2"),
            "title": .string("Bottle POS Funnel Deck Discovery (G2)"),
            "date": .string("2026-09-15"), "time": .string("15:37"),
            "domain": .string("quilt"), "domainAbbr": .string("Q"),
            "duration": .string("3 minutes"), "durationMinutes": .number(3),
            "month": .string("2026-09"),
            "filename": .string("2026-09-15_Bottle_POS_Funnel_Deck_Discovery_(G2).md"),
            "source": .string("G2 Glasses"), "librarySource": .string("g2"),
            "topicCount": .number(3), "decisionCount": .number(1), "actionCount": .number(1), "attendeeCount": .number(2),
        ]))
        precondition(model.openLibraryRow != nil, "the meeting row seeds")
        precondition(model.openLibraryRow?.canReviewVoices == true, "a G2 capture offers Review voices")
        model.libraryDetail = LibraryMeetingDetail(.object([
            "title": .string("Bottle POS Funnel Deck Discovery (G2)"),
            "date": .string("2026-09-15"), "time": .string("15:37"), "domain": .string("quilt"),
            "duration": .string("3 minutes"), "source": .string("G2 Glasses"),
            "summary": .string("Tail-end capture of a Quilt working session on the Bottle POS funnel PowerPoint."),
            "transcript": .string(meeting),
            "attendees": .array([.string("MU"), .string("Cort Ouzts")]),
            "topics": .array([]), "decisions": .array([]), "actionItems": .array([]),
            "librarySource": .string("g2"), "recordId": .string("2026-09/2026-09-15_Bottle_POS_Funnel_Deck_Discovery_(G2).md"),
            "mutable": .bool(false), "sources": .array([]),
        ]))
        precondition(model.libraryDetail != nil, "the meeting detail seeds")
        precondition(COSMarkdownParser.looksLikeDocument(model.libraryDetail!.transcript), "the scribe's file reads as a document")

        for dark in [false, true] {
            let (_, host) = try render(
                MeetingLibraryDetailPane(model: model, onReviewVoices: { _, _ in }),
                size: NSSize(width: 920, height: 1180), name: "meeting-pane", output: output, dark: dark)
            let text = strings(host).joined(separator: "\n")
            precondition(!text.contains("## "), "the meeting pane must not show raw headings; the 0.5.231 body did")
            precondition(!text.contains("<details>"), "the meeting pane must not show raw details tags")
            precondition(!text.contains("|-------|"), "the meeting pane must not show a raw table separator")
            precondition(text.contains("Cort Ouzts"), "the transcript's speaker lines render")
            precondition(text.contains("Send a Slack message"), "the task item renders")
        }

        // The thread pane: a sectioned note with a table, an ordered list and a details block.
        model.contextDetailKind = "thread"
        model.contextDetail = ContextRecord(
            id: "thread_bottle_funnel_deck", title: "Bottle POS funnel deck",
            subtitle: "quilt · accelerating", body: thread, createdAt: "2026-09-15",
            filePath: "/tmp/thread.md", meetingCount: 2, isResolved: false)
        for dark in [false, true] {
            let (_, host) = try render(
                ContextDetailPane(model: model, showsBackButton: false),
                size: NSSize(width: 920, height: 760), name: "thread-pane", output: output, dark: dark)
            let text = strings(host).joined(separator: "\n")
            precondition(!text.contains("## "), "the thread pane must not show raw headings")
            precondition(text.contains("Sales lead"), "the stakeholder table renders")
        }

        // The three weights, side by side, as a card.
        for dark in [false, true] {
            _ = try render(
                HStack(spacing: 8) {
                    Button("Copy as context") {}.buttonStyle(COSPrimaryButtonStyle())
                    Button("Copy summary") {}.buttonStyle(COSQuietButtonStyle())
                    Button("Reveal in Finder") {}.buttonStyle(COSQuietButtonStyle())
                    Spacer()
                    Button { } label: { HStack(spacing: 8) { Text("Review voices"); COSNewPill() } }
                        .buttonStyle(COSQuietButtonStyle(tone: .featured))
                }
                .controlSize(.small)
                .padding(16)
                .background(COSPalette.panel),
                size: NSSize(width: 640, height: 60), name: "action-weights", output: output, dark: dark, fills: false)
        }

        // 0.5.233: the live Activity block on the recorded 6.48.2 frames, then the three
        // fallback shapes (connecting, reconnecting, older server).
        let fixture = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ".")
            .appendingPathComponent("Tests/fixtures/session-stream-6.48.2.ndjson")
        var recorded = SessionLiveFeed()
        if let text = try? String(contentsOf: fixture, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                if let event = SessionLiveEvent(line: String(line)) { recorded = recorded.applying(event) }
            }
        }
        precondition(recorded.tools.count == SessionLiveFeed.toolWindow, "the recorded feed fills the tool window: \(recorded.tools.count)")
        recorded.connected = true
        var waiting = recorded
        waiting.agentState = "waiting"; waiting.waitingKind = "permission"; waiting.waitingDetail = "Bash git push origin main"
        var lost = SessionLiveFeed(); lost.fallbackReason = "http_404"
        var reconnecting = recorded; reconnecting.connected = false; reconnecting.fallbackReason = "reconnecting"; reconnecting.missed = 3
        for dark in [false, true] {
            let (_, host) = try render(
                VStack(alignment: .leading, spacing: 12) {
                    SessionActivityFeed(feed: recorded, queued: 1)
                    SessionActivityFeed(feed: waiting)
                    SessionActivityFeed(feed: reconnecting)
                    SessionActivityFeed(feed: lost)
                    SessionActivityFeed(feed: nil)
                }
                .padding(16)
                .frame(width: 920, alignment: .topLeading)
                .background(COSPalette.panel),
                size: NSSize(width: 920, height: 1000), name: "activity-feed", output: output, dark: dark, fills: false)
            // Only selectable Text is backed by an NSTextView the harness can read; the
            // state word, tool lines and chips are plain Text (drawn, not enumerable), so
            // the prompt is the one string asserted here and the PNG is the review surface.
            let text = strings(host).joined(separator: "\n")
            precondition(text.components(separatedBy: "Confirm the fix was server-side, then update the docs.").count == 4,
                         "the three live feeds draw the recorded prompt once each")
            precondition(host.bounds.height >= 700, "five feeds stack taller than one screen of chrome: \(host.bounds.height)")
        }

        try messages(output: output)
        print("PASS messages markdown UI: Message #356 renders as Markdown light and dark (before shot raw), parse once per id + text, streaming text stays text, bare URLs wrap, copy stays raw")
        print("PASS messages copy + chat: Copy answer and Copy reply copy the stored Markdown, a short session chat reply hugs its words, a stream never evicts the paragraph on screen")
        print("PASS markdown UI: meeting pane and thread pane render as documents at 920 pt, light and dark;")
        print("PASS activity feed: recorded, waiting, reconnecting, older-server and connecting shapes render light and dark;")
        print("PASS action weights: primary, quiet and featured render side by side. Output: \(output.path)")
    }
}
