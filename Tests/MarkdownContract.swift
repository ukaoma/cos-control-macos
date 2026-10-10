import Foundation

// The Markdown parser against the shapes COS actually writes (0.5.232). Executed, not
// grepped: every block kind the panes render has a fixture here taken from a real file
// on the release Mac (the meeting scribe's `.md`, a thread note, a Claude reply), and
// the assertion is the block TREE. A renderer that reads these wrong reads every pane
// wrong, so the parser is pinned before the view is.

@main
struct MarkdownContract {
    nonisolated(unsafe) static var failures: [String] = []

    static func expect(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message) }
    }

    static func main() {
        scribeMeeting()
        listsAndTasks()
        tablesCodeQuotesRules()
        detailsAndSpeakers()
        documentDetection()
        edges()
        messageAnswer()
        webLinksOnly()
        streaming()

        if failures.isEmpty {
            print("COS Control: Markdown parser pinned on the scribe's meeting, lists, tasks, tables, code, quotes, details and speaker lines (0.5.232)")
            print("PASS messages markdown: Message #356 blocks and inline runs, web-links-only policy, half-streamed Markdown stays text, row preview flattens")
        } else {
            for f in failures { FileHandle.standardError.write(("MarkdownContract: " + f + "\n").data(using: .utf8)!) }
            exit(1)
        }
    }

    /// The meeting file exactly as `sync_meetings.py` writes it (2026-09-15 15:37, G2).
    static let meeting = """
    # Bottle POS Funnel Deck Discovery (G2)

    | Field | Value |
    |-------|-------|
    | **Date** | 2026-09-15 15:37 |
    | **Source** | G2 Glasses |
    | **Duration** | 3 minutes |

    ## Attendees

    - MU
    - Cort Ouzts

    ## Summary

    Tail-end capture of a Quilt working session on the Bottle POS funnel PowerPoint. Cort set the approach.

    ## Action Items


    ### Needs Review
    - [ ] `[REVIEW]` Send a Slack message to Peter and Mary to coordinate support. (Tyler Rhoton)

    ## Transcript

    <details>
    <summary>Click to expand transcript</summary>

    [Cort Ouzts]: See if you can do that , and then we 'll go from there .
    [Ext]: shared ? That 's the shared , right ?
    [MU]: Thank you .

    </details>
    """

    static func scribeMeeting() {
        let blocks = COSMarkdownParser.parse(meeting, dropLeadingTitle: true)
        expect(!blocks.isEmpty, "the meeting parses")
        if case .heading(let level, _) = blocks.first ?? .rule { expect(level != 1, "the leading H1 is dropped when the pane shows the title") }
        guard case .table(let header, let rows) = blocks.first ?? .rule else { return expect(false, "the first block after the title is the metadata table, got \(String(describing: blocks.first))") }
        expect(header == ["Field", "Value"], "table header cells are trimmed: \(header)")
        expect(rows.count == 3 && rows[0] == ["**Date**", "2026-09-15 15:37"], "table rows keep their inline markdown: \(rows)")
        expect(blocks.contains(.heading(level: 2, text: "Attendees")), "## Attendees is a level-2 heading")
        expect(blocks.contains(.list(ordered: false, items: [COSMarkdownListItem(text: "MU", checked: nil), COSMarkdownListItem(text: "Cort Ouzts", checked: nil)])), "the attendee list is two plain items")
        expect(blocks.contains(.heading(level: 3, text: "Needs Review")), "### Needs Review is a level-3 heading")
        expect(blocks.contains(.list(ordered: false, items: [COSMarkdownListItem(text: "`[REVIEW]` Send a Slack message to Peter and Mary to coordinate support. (Tyler Rhoton)", checked: false)])), "the action item is an unchecked task with its REVIEW marker kept inline")
        guard let details = blocks.last, case .details(let summary, let inner) = details else { return expect(false, "the transcript is the last block, a details block, got \(String(describing: blocks.last))") }
        expect(summary == "Click to expand transcript", "the summary text is read out of its tags: \(summary)")
        expect(inner == [.speakerLines([
            COSMarkdownSpeakerLine(speaker: "Cort Ouzts", text: "See if you can do that , and then we 'll go from there ."),
            COSMarkdownSpeakerLine(speaker: "Ext", text: "shared ? That 's the shared , right ?"),
            COSMarkdownSpeakerLine(speaker: "MU", text: "Thank you ."),
        ])], "the transcript inside details is speaker lines, one per line, not one paragraph: \(inner)")
        // The same file with the title kept: the H1 is the first block.
        let kept = COSMarkdownParser.parse(meeting)
        expect(kept.first == .heading(level: 1, text: "Bottle POS Funnel Deck Discovery (G2)"), "without dropLeadingTitle the H1 is the first block")
    }

    static func listsAndTasks() {
        let nested = """
        1. First
        2. Second
           - nested a
           - nested b
        3. Third wraps
           onto a second line
        """
        let blocks = COSMarkdownParser.parse(nested)
        guard case .list(let ordered, let items) = blocks.first ?? .rule else { return expect(false, "an ordered list parses as one list, got \(blocks)") }
        expect(ordered, "1. 2. 3. is ordered")
        expect(items.count == 3, "three top-level items, got \(items.count)")
        expect(items[1].children == [.list(ordered: false, items: [COSMarkdownListItem(text: "nested a", checked: nil), COSMarkdownListItem(text: "nested b", checked: nil)])], "an indented list nests under its item: \(items[1].children)")
        expect(items[2].text == "Third wraps onto a second line", "a wrapped line joins its item: \(items[2].text)")
        let tasks = COSMarkdownParser.parse("- [x] done\n- [ ] open\n- plain")
        guard case .list(_, let t) = tasks.first ?? .rule else { return expect(false, "tasks parse") }
        expect(t.map(\.checked) == [true, false, nil], "checked, unchecked, plain: \(t.map(\.checked))")
        expect(t.map(\.text) == ["done", "open", "plain"], "task text drops the box: \(t.map(\.text))")
        // Two lists separated by a paragraph stay two lists.
        let two = COSMarkdownParser.parse("- a\n\nwords\n\n- b")
        expect(two.count == 3, "list, paragraph, list: \(two.count) blocks")
    }

    static func tablesCodeQuotesRules() {
        let code = COSMarkdownParser.parse("before\n\n```sh\nnpm run x\n```\n\nafter")
        expect(code == [.paragraph("before"), .code("npm run x"), .paragraph("after")], "a fence is a code block with its lines verbatim: \(code)")
        let quote = COSMarkdownParser.parse("> quoted line\n> continues\n\nplain")
        expect(quote.first == .quote([.paragraph("quoted line continues")]), "a > run is one quote of one paragraph: \(String(describing: quote.first))")
        let rule = COSMarkdownParser.parse("a\n\n---\n\nb")
        expect(rule == [.paragraph("a"), .rule, .paragraph("b")], "--- between paragraphs is a rule: \(rule)")
        // A table separator row is NOT a rule, and a pipe row without a separator is a paragraph.
        let table = COSMarkdownParser.parse("| A | B |\n|---|:---:|\n| 1 | 2 |\n| 3 |")
        expect(table == [.table(header: ["A", "B"], rows: [["1", "2"], ["3"]])], "a ragged row keeps its cells: \(table)")
        let notTable = COSMarkdownParser.parse("| just | pipes |")
        expect(notTable == [.paragraph("| just | pipes |")], "a pipe row with no separator is text: \(notTable)")
    }

    static func detailsAndSpeakers() {
        let inline = COSMarkdownParser.parse("<details><summary>Sources</summary>\n\n- one\n\n</details>")
        expect(inline == [.details(summary: "Sources", blocks: [.list(ordered: false, items: [COSMarkdownListItem(text: "one", checked: nil)])])], "summary on the details line still reads: \(inline)")
        let bare = COSMarkdownParser.parse("<details>\nplain text\n</details>")
        expect(bare == [.details(summary: "Details", blocks: [.paragraph("plain text")])], "no summary tag falls back to Details: \(bare)")
        // Speaker lines only when EVERY line of the paragraph carries a label; a stray
        // bracket at the start of prose stays a paragraph.
        let mixed = COSMarkdownParser.parse("[Cort Ouzts]: hi\nand then prose")
        expect(mixed == [.paragraph("[Cort Ouzts]: hi and then prose")], "a paragraph that is not all speaker lines is a paragraph: \(mixed)")
        let one = COSMarkdownParser.parse("[Speaker 2]: only one line")
        expect(one == [.speakerLines([COSMarkdownSpeakerLine(speaker: "Speaker 2", text: "only one line")])], "one labelled line is a speaker line: \(one)")
    }

    static func documentDetection() {
        expect(COSMarkdownParser.looksLikeDocument(meeting), "the scribe's meeting is a document")
        expect(COSMarkdownParser.looksLikeDocument("## Summary\n\ntext"), "a heading makes a document")
        expect(!COSMarkdownParser.looksLikeDocument("Tail-end capture of a Quilt working session. Cort set the approach."), "a summary sentence is not a document")
        expect(!COSMarkdownParser.looksLikeDocument("MU, Cort Ouzts"), "an attendee line is not a document")
        expect(!COSMarkdownParser.looksLikeDocument("#hashtag is not a heading"), "#hashtag is not a heading")
    }

    static func edges() {
        expect(COSMarkdownParser.parse("").isEmpty, "empty input is no blocks")
        expect(COSMarkdownParser.parse("\n\n\n").isEmpty, "blank input is no blocks")
        expect(COSMarkdownParser.parse("```\nunclosed") == [.code("unclosed")], "an unclosed fence takes the rest of the file")
        expect(COSMarkdownParser.parse("<details>\nunclosed") == [.details(summary: "Details", blocks: [.paragraph("unclosed")])], "an unclosed details takes the rest of the file")
        expect(COSMarkdownParser.parse("####### seven") == [.paragraph("####### seven")], "seven hashes is not a heading")
        expect(COSMarkdownParser.parse("# Title ##") == [.heading(level: 1, text: "Title")], "closing hashes are trimmed")
        expect(COSMarkdownParser.parse("line one\r\nline two") == [.paragraph("line one line two")], "CRLF is fine")
    }

    /// Message #356 exactly as the glasses server stored it (2026-10-09 17:28, Opus): the
    /// answer Miles screenshotted printing its Markdown raw in Activity > Messages.
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

    static func strong(_ s: AttributedString) -> [String] {
        s.runs.compactMap { run in
            guard let i = run.inlinePresentationIntent, i.contains(.stronglyEmphasized) else { return nil }
            return String(s[run.range].characters)
        }
    }
    static func links(_ s: AttributedString) -> [URL] { s.runs.compactMap(\.link) }

    static func messageAnswer() {
        let blocks = COSMarkdownParser.parse(message356)
        expect(blocks.count == 5, "[message 356] lead paragraph, numbered list, paragraph, Sources:, link list: \(blocks.count) blocks: \(blocks)")
        guard blocks.count == 5 else { return }
        guard case .paragraph(let lead) = blocks[0] else { return expect(false, "[message 356] the bold title line opens a paragraph: \(blocks[0])") }
        let leadRuns = COSMarkdownParser.inline(lead)
        expect(strong(leadRuns) == ["Take Varesa."], "[message 356] **Take Varesa.** is bold: \(strong(leadRuns))")
        expect(String(leadRuns.characters).hasPrefix("Take Varesa. Neither Vesna"), "[message 356] the markers are gone from the text: \(String(leadRuns.characters).prefix(40))")
        guard case .list(let ordered, let picks) = blocks[1] else { return expect(false, "[message 356] the picks are a list: \(blocks[1])") }
        expect(ordered && picks.count == 3, "[message 356] 1. 2. 3. is one ordered list of three: ordered \(ordered), \(picks.count)")
        expect(picks.map { strong(COSMarkdownParser.inline($0.text)) } == [["Varesa:"], ["Clorinde:"], ["Chiori:"]], "[message 356] each pick leads with its bold name")
        expect(picks.allSatisfy { $0.checked == nil && $0.children.isEmpty }, "[message 356] the picks are plain items")
        expect(String(COSMarkdownParser.inline(picks[0].text).characters).hasPrefix("Varesa: She fits your best units."), "[message 356] item text renders without markers")
        expect(blocks[2] == .paragraph("The one reason to take Clorinde instead: if Iansan isn't in your account and you mainly play Fischl and Nahida teams."), "[message 356] the closing paragraph stands alone: \(blocks[2])")
        expect(blocks[3] == .paragraph("Sources:"), "[message 356] Sources: is its own line: \(blocks[3])")
        guard case .list(false, let sources) = blocks[4] else { return expect(false, "[message 356] the sources are a bulleted list: \(blocks[4])") }
        let rendered = sources.map { COSMarkdownParser.inline($0.text) }
        expect(rendered.map { String($0.characters) } == ["allthings.how: 7.1 selector best pick", "timesaver.gg: all selector characters and deadlines", "ldshop.gg: 7.1 anniversary selector guide"],
               "[message 356] each source shows its label, not the bracket syntax: \(rendered.map { String($0.characters) })")
        expect(rendered.map(links) == [
            [URL(string: "https://allthings.how/genshin-impact-limited-5-star-selector-best-pick-in-version-7-1/")!],
            [URL(string: "https://timesaver.gg/blog/genshin-free-5-star-selector-7-1")!],
            [URL(string: "https://www.ldshop.gg/blog/genshin-impact/7-1-anniversary-selector-guide.html")!],
        ], "[message 356] each label links to its https page: \(rendered.map(links))")
        // The row preview: the words, none of the markers.
        let preview = COSMarkdownParser.plainText(message356)
        expect(preview.hasPrefix("Take Varesa. Neither Vesna nor Chiori"), "[row preview] starts with the words: \(preview.prefix(40))")
        expect(!preview.contains("**") && !preview.contains("]("), "[row preview] no bold or link markers survive")
        expect(COSMarkdownParser.plainText("## Heading\n> quoted **bold**") == "Heading\nquoted bold", "[row preview] heading and quote marks come off: \(COSMarkdownParser.plainText("## Heading\n> quoted **bold**"))")
    }

    static func webLinksOnly() {
        for (source, label) in [
            ("[open](file:///etc/passwd)", "open"),
            ("[run](javascript:alert(1))", "run"),
            ("[mail](mailto:miles@example.com)", "mail"),
            ("[settings](x-apple.systempreferences:com.apple.preference.security)", "settings"),
            ("[relative](docs/guide.md)", "relative"),
            ("[nohost](https:///path)", "nohost"),
        ] {
            let runs = COSMarkdownParser.inline(source)
            expect(links(runs).isEmpty, "[web links only] \(source) must not stay a link: \(links(runs))")
            expect(String(runs.characters) == label, "[web links only] \(source) keeps its label as text: \(String(runs.characters))")
        }
        let autolink = COSMarkdownParser.inline("<mailto:miles@example.com> and <https://gotcos.com/control/>")
        expect(links(autolink) == [URL(string: "https://gotcos.com/control/")!], "[web links only] of two autolinks only the https one links: \(links(autolink))")
        expect(links(COSMarkdownParser.inline("[ok](HTTP://Example.com/a)")).count == 1, "[web links only] the scheme check ignores case")
        expect(COSMarkdownParser.opensAsWebLink(URL(string: "http://example.com")!), "[web links only] http opens")
        expect(!COSMarkdownParser.opensAsWebLink(URL(string: "ftp://example.com")!), "[web links only] ftp does not")
        // A bare URL in a Sources line is text, kept whole (the pane wraps it).
        let bare = COSMarkdownParser.inline("Sources: https://allthings.how/genshin-impact-limited-5-star-selector-best-pick-in-version-7-1/")
        expect(String(bare.characters).hasSuffix("best-pick-in-version-7-1/"), "[bare url] a bare URL is kept verbatim")
        expect(links(bare) == [URL(string: "https://allthings.how/genshin-impact-limited-5-star-selector-best-pick-in-version-7-1/")!], "[bare url] a bare https URL links to itself: \(links(bare))")
        expect(links(COSMarkdownParser.inline("see www.example.com/x")).allSatisfy(COSMarkdownParser.opensAsWebLink), "[bare url] a www autolink is a web link or none")
    }

    /// The live badge: a turn redraws as its answer streams in, so every prefix of the
    /// answer must parse, and a half-written `**` or `[` must read as text, not vanish.
    static func streaming() {
        let half = COSMarkdownParser.inline("**Take Var")
        expect(String(half.characters) == "**Take Var" && strong(half).isEmpty, "[streaming] an unclosed ** is literal text: \(String(half.characters))")
        let link = COSMarkdownParser.inline("[allthings.how: 7.1 selector](https://allthings.ho")
        // Every character stays on screen. The half URL may autolink (Foundation links a bare
        // http URL), and that link is still a web page.
        expect(String(link.characters) == "[allthings.how: 7.1 selector](https://allthings.ho", "[streaming] an unclosed link is literal text: \(String(link.characters))")
        expect(links(link).allSatisfy(COSMarkdownParser.opensAsWebLink), "[streaming] a half link never links off the web: \(links(link))")
        let bracket = COSMarkdownParser.parse("Sources:\n- [allthings.how: 7.1 sel")
        expect(bracket == [.paragraph("Sources:"), .list(ordered: false, items: [COSMarkdownListItem(text: "[allthings.how: 7.1 sel", checked: nil)])], "[streaming] a half link line is still a list item: \(bracket)")
        expect(COSMarkdownParser.parse("Here:\n```swift\nlet x") == [.paragraph("Here:"), .code("let x")], "[streaming] an open fence holds the rest as code")
        // Every prefix of the real answer parses, renders some text, and never links off the web.
        var prefixes = 0
        let chars = Array(message356)
        var end = 1
        while end <= chars.count {
            let prefix = String(chars[0..<end])
            let blocks = COSMarkdownParser.parse(prefix)
            var texts: [String] = []
            for block in blocks {
                switch block {
                case .paragraph(let t): texts.append(t)
                case .list(_, let items): texts.append(contentsOf: items.map(\.text))
                default: break
                }
            }
            for t in texts {
                let runs = COSMarkdownParser.inline(t)
                if String(runs.characters).isEmpty && !t.trimmingCharacters(in: .whitespaces).isEmpty {
                    expect(false, "[streaming] prefix \(end) rendered \(t) as nothing")
                }
                if !links(runs).allSatisfy(COSMarkdownParser.opensAsWebLink) { expect(false, "[streaming] prefix \(end) produced a non-web link") }
            }
            prefixes += 1
            end += 5
        }
        expect(prefixes > 250, "[streaming] the walk covered the answer: \(prefixes) prefixes")
    }
}
