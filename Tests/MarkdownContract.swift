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

        if failures.isEmpty {
            print("COS Control: Markdown parser pinned on the scribe's meeting, lists, tasks, tables, code, quotes, details and speaker lines (0.5.232)")
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
}
