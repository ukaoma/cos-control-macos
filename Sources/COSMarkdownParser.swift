import Foundation

// The one Markdown renderer for COS Control's detail panes (0.5.232).
//
// Meetings, threads, memories and session replies are all stored as Markdown, and
// until 0.5.231 every pane printed the raw text: `## Attendees`, `| **Date** | ... |`,
// `<details>` tags and all (Miles, 2026-09-15: "Can we style these screens ... similar
// to what we can get from .md FluxMarkdown"). SwiftUI's own `Text(markdown:)` styles
// INLINE runs only and ignores every block-level intent, which is why nothing rendered
// as a document. This file is the block layer on top of it.
//
// TWO PARTS, ON PURPOSE. `COSMarkdownParser` is pure Foundation (no SwiftUI), so
// `Tests/MarkdownContract.swift` runs it against the exact shapes the COS pipeline and
// the glasses server write and asserts the block tree, not a rendered picture.
// `COSMarkdownView` (COSMarkdown.swift) turns that tree into the pane's own vocabulary: Fraunces for
// headings with a hairline under them, DM Sans for body, JetBrains Mono for labels and
// speaker names, the raised card for tables and disclosures. Copy actions never come
// through here: they copy the stored Markdown, byte for byte.
//
// Blocks the COS files actually use (every one has a fixture in the contract):
//   ATX headings 1-6 · paragraphs · `-`/`*`/`+`/`1.` lists with nesting by indent ·
//   task items `- [ ]` / `- [x]` · pipe tables with a `|---|` row · fenced code ·
//   `>` quotes · `---` rules · `<details><summary>…</summary>…</details>` ·
//   transcript lines `[Speaker]: text`, one per line (the scribe's shape).
// Anything else is a paragraph, which is the honest fallback for a renderer.

// MARK: - Block model

indirect enum COSMarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(ordered: Bool, items: [COSMarkdownListItem])
    case table(header: [String], rows: [[String]])
    case code(String)
    case quote([COSMarkdownBlock])
    case rule
    case details(summary: String, blocks: [COSMarkdownBlock])
    /// Transcript lines: one speaker label per line. `speaker` is the bracketed name.
    case speakerLines([COSMarkdownSpeakerLine])
}

struct COSMarkdownListItem: Equatable {
    var text: String
    /// nil for a plain bullet; false/true for `- [ ]` / `- [x]`.
    var checked: Bool?
    var children: [COSMarkdownBlock] = []
}

struct COSMarkdownSpeakerLine: Equatable {
    var speaker: String
    var text: String
}

// MARK: - Parser

enum COSMarkdownParser {
    /// Parse a whole document. `dropLeadingTitle` removes a first-line `# Title` when the
    /// pane already shows the title in its header (the meeting file starts with one).
    static func parse(_ text: String, dropLeadingTitle: Bool = false) -> [COSMarkdownBlock] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if dropLeadingTitle {
            if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
               lines[first].hasPrefix("# ") {
                lines.remove(at: first)
            }
        }
        return parseBlocks(lines[...])
    }

    /// Saved meeting presentation only. Stored Markdown and other document surfaces stay unchanged.
    static func meetingBlocks(_ text: String, dropLeadingTitle: Bool = false) -> [COSMarkdownBlock] {
        formatMeetingBlocks(parse(text, dropLeadingTitle: dropLeadingTitle), transcript: !looksLikeDocument(text))
    }

    private static func formatMeetingBlocks(_ blocks: [COSMarkdownBlock], transcript: Bool = false) -> [COSMarkdownBlock] {
        var inTranscript = transcript
        var result: [COSMarkdownBlock] = []
        var pending: [COSMarkdownSpeakerLine] = []
        func append(_ line: COSMarkdownSpeakerLine) {
            // Bound a reading section; never invent a speaker, punctuation or timestamp.
            if let last = pending.last, last.speaker == line.speaker,
               last.text.count + line.text.count + 1 <= 600 {
                pending[pending.count - 1].text += " " + line.text
            } else { pending.append(line) }
        }
        func flush() {
            guard !pending.isEmpty else { return }
            result.append(.speakerLines(pending.map {
                COSMarkdownSpeakerLine(speaker: $0.speaker, text: meetingParagraphs($0.text))
            }))
            pending.removeAll()
        }
        // Old scribe output sometimes put many `[Ext]:` markers on ONE line.
        let marker = try! NSRegularExpression(pattern: #"(?:^|\s)\[([^\]\n]{1,64})\]:\s*"#)
        for block in blocks {
            switch block {
            case .speakerLines(let rows):
                for row in rows {
                    // Reparse the body too: the ordinary parser only consumed the leading label.
                    let raw = "[" + row.speaker + "]: " + row.text
                    for row in splitMeetingSpeakers(raw, marker: marker) ?? [row] { append(row) }
                }
            case .paragraph(let raw):
                if let rows = splitMeetingSpeakers(raw, marker: marker) {
                    for row in rows { append(row) }
                } else if inTranscript {
                    flush()
                    let ns = raw as NSString
                    if let first = marker.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)), first.range.location > 0 {
                        let prefix = ns.substring(to: first.range.location)
                        result.append(.paragraph(meetingParagraphs(prefix)))
                        let tail = ns.substring(from: first.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
                        for row in splitMeetingSpeakers(tail, marker: marker) ?? [] { append(row) }
                    } else { result.append(.paragraph(meetingParagraphs(raw))) }
                } else { flush(); result.append(block) }
            case .heading(let level, let title):
                flush()
                if level <= 3 { inTranscript = title.lowercased().contains("transcript") }
                result.append(block)
            case .details(let summary, let inner):
                flush(); result.append(.details(summary: summary, blocks: formatMeetingBlocks(inner, transcript: inTranscript || summary.lowercased().contains("transcript"))))
            default: flush(); result.append(block)
            }
        }
        flush()
        return result
    }

    private static func splitMeetingSpeakers(_ text: String, marker: NSRegularExpression) -> [COSMarkdownSpeakerLine]? {
        let ns = text as NSString
        let matches = marker.matches(in: text, range: NSRange(location: 0, length: ns.length))
        // An ordinary sentence mentioning a bracketed label is not a transcript.
        guard let first = matches.first, first.range.location == 0 else { return nil }
        return matches.enumerated().map { index, match in
            let start = NSMaxRange(match.range)
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            return COSMarkdownSpeakerLine(speaker: ns.substring(with: match.range(at: 1)),
                text: ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func meetingParagraphs(_ text: String) -> String {
        let chars = Array(text)
        var start = 0
        var paragraphs: [String] = []
        while start < chars.count {
            let end = min(start + 420, chars.count)
            var cut = end
            if end < chars.count {
                var sentence: Int?
                var space: Int?
                for i in start..<end {
                    if chars[i].isWhitespace { space = i }
                    if i - start >= 160, ".!?。！？".contains(chars[i]), chars[i + 1].isWhitespace { sentence = i + 1 }
                }
                cut = sentence ?? space.flatMap { $0 > start ? $0 : nil } ?? end
            }
            let part = String(chars[start..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty { paragraphs.append(part) }
            start = cut
            while start < chars.count, chars[start].isWhitespace { start += 1 }
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// True when the text reads as a Markdown DOCUMENT rather than a sentence or two:
    /// a heading, a table row, a list, a fence or a details block. A pane uses this to
    /// decide whether the file IS the body (the meeting scribe's `.md`) or a field.
    static func looksLikeDocument(_ text: String) -> Bool {
        for raw in text.components(separatedBy: "\n").prefix(400) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") && headingLevel(line) != nil { return true }
            if line.hasPrefix("|") && line.hasSuffix("|") { return true }
            if line.hasPrefix("```") || line.hasPrefix("<details") { return true }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || orderedPrefix(line) != nil { return true }
        }
        return false
    }

    private static func parseBlocks(_ lines: ArraySlice<String>) -> [COSMarkdownBlock] {
        var blocks: [COSMarkdownBlock] = []
        var i = lines.startIndex
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph
            paragraph = []
            if let speakers = speakerLines(joined) {
                blocks.append(.speakerLines(speakers))
            } else {
                blocks.append(.paragraph(joined.joined(separator: " ")))
            }
        }

        while i < lines.endIndex {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.isEmpty { flushParagraph(); i += 1; continue }

            // Fenced code
            if line.hasPrefix("```") {
                flushParagraph()
                var body: [String] = []
                var j = i + 1
                while j < lines.endIndex, !lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[j]); j += 1
                }
                blocks.append(.code(body.joined(separator: "\n")))
                i = min(j + 1, lines.endIndex)
                continue
            }

            // <details> … </details>, with an optional <summary>
            if line.lowercased().hasPrefix("<details") {
                flushParagraph()
                var summary = "Details"
                // `<details><summary>Sources</summary>` on one line is how a thread note writes it.
                if let onOpeningLine = stripTag(line, open: "<summary>", close: "</summary>") { summary = onOpeningLine }
                var inner: [String] = []
                var j = i + 1
                var depth = 1
                while j < lines.endIndex {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    let lower = t.lowercased()
                    if lower.hasPrefix("<details") { depth += 1 }
                    if lower.hasPrefix("</details>") {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    if depth == 1, lower.hasPrefix("<summary>"), let s = stripTag(t, open: "<summary>", close: "</summary>") {
                        summary = s
                    } else {
                        inner.append(lines[j])
                    }
                    j += 1
                }
                blocks.append(.details(summary: summary, blocks: parseBlocks(inner[...])))
                i = min(j + 1, lines.endIndex)
                continue
            }

            // Headings
            if let level = headingLevel(line) {
                flushParagraph()
                let text = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: #"\s+#+$"#, with: "", options: .regularExpression)
                blocks.append(.heading(level: level, text: text))
                i += 1
                continue
            }

            // Rule
            if isRule(line) {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            // Table: a pipe row followed by a separator row
            if line.hasPrefix("|"), i + 1 < lines.endIndex, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = cells(line)
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.endIndex {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("|") else { break }
                    rows.append(cells(t)); j += 1
                }
                blocks.append(.table(header: header, rows: rows))
                i = j
                continue
            }

            // Quote
            if line.hasPrefix(">") {
                flushParagraph()
                var inner: [String] = []
                var j = i
                while j < lines.endIndex {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    inner.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces)); j += 1
                }
                blocks.append(.quote(parseBlocks(inner[...])))
                i = j
                continue
            }

            // Lists
            if bulletPrefix(raw) != nil || orderedPrefix(line) != nil {
                flushParagraph()
                let (list, next) = parseList(lines, from: i)
                blocks.append(list)
                i = next
                continue
            }

            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    /// A list runs while lines are items at the SAME indent, or continuation lines
    /// indented deeper (nested lists, wrapped text).
    private static func parseList(_ lines: ArraySlice<String>, from start: Int) -> (COSMarkdownBlock, Int) {
        let baseIndent = indent(lines[start])
        let ordered = orderedPrefix(lines[start].trimmingCharacters(in: .whitespaces)) != nil
        var items: [COSMarkdownListItem] = []
        var i = start
        while i < lines.endIndex {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                // A blank line ends the list unless the next non-blank line is still an item at this indent.
                var j = i + 1
                while j < lines.endIndex, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                if j < lines.endIndex, indent(lines[j]) == baseIndent, itemText(lines[j]) != nil { i = j; continue }
                break
            }
            guard indent(raw) == baseIndent, let (text, checked) = itemText(raw) else { break }
            // Gather this item's continuation: deeper-indented lines until the next item at base indent.
            var children: [String] = []
            var j = i + 1
            while j < lines.endIndex {
                let next = lines[j]
                let nt = next.trimmingCharacters(in: .whitespaces)
                if nt.isEmpty {
                    // keep a blank inside nested content only when more nested content follows
                    var k = j + 1
                    while k < lines.endIndex, lines[k].trimmingCharacters(in: .whitespaces).isEmpty { k += 1 }
                    if k < lines.endIndex, indent(lines[k]) > baseIndent { children.append(""); j += 1; continue }
                    break
                }
                if indent(next) > baseIndent { children.append(String(next.dropFirst(min(indent(next), baseIndent + 2)))); j += 1; continue }
                break
            }
            var item = COSMarkdownListItem(text: text, checked: checked)
            if !children.isEmpty {
                let nested = parseBlocks(children[...])
                // A wrapped line that is not a block of its own joins the item text.
                var kept: [COSMarkdownBlock] = []
                for block in nested {
                    if case .paragraph(let p) = block, kept.isEmpty, !children.contains(where: { bulletPrefix($0) != nil || orderedPrefix($0.trimmingCharacters(in: .whitespaces)) != nil }) {
                        item.text += " " + p
                    } else {
                        kept.append(block)
                    }
                }
                item.children = kept
            }
            items.append(item)
            i = j
        }
        return (.list(ordered: ordered, items: items), i)
    }

    // MARK: line helpers

    static func headingLevel(_ line: String) -> Int? {
        var level = 0
        for ch in line { if ch == "#" { level += 1 } else { break } }
        guard level >= 1, level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        return rest.first == " " || rest.isEmpty ? level : nil
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        return compact.count >= 3 && (Set(compact) == ["-"] || Set(compact) == ["*"] || Set(compact) == ["_"])
    }

    private static func isTableSeparator(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("|") else { return false }
        let inner = line.replacingOccurrences(of: "|", with: "").replacingOccurrences(of: ":", with: "").replacingOccurrences(of: " ", with: "")
        return !inner.isEmpty && Set(inner) == ["-"]
    }

    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func indent(_ raw: String) -> Int {
        var n = 0
        for ch in raw { if ch == " " { n += 1 } else if ch == "\t" { n += 4 } else { break } }
        return n
    }

    private static func bulletPrefix(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ "] where t.hasPrefix(marker) { return marker }
        if t == "-" || t == "*" { return t }
        return nil
    }

    private static func orderedPrefix(_ line: String) -> String? {
        guard let range = line.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) else { return nil }
        return String(line[range])
    }

    /// The item's text and its checkbox state, or nil when the line is not an item.
    private static func itemText(_ raw: String) -> (String, Bool?)? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        var rest: Substring
        if let marker = bulletPrefix(raw) {
            rest = line.dropFirst(marker.count)
        } else if let marker = orderedPrefix(line) {
            rest = line.dropFirst(marker.count)
        } else {
            return nil
        }
        rest = Substring(rest.trimmingCharacters(in: .whitespaces))
        if rest.hasPrefix("[ ] ") || rest == "[ ]" { return (String(rest.dropFirst(4)).trimmingCharacters(in: .whitespaces), false) }
        if rest.lowercased().hasPrefix("[x] ") || rest.lowercased() == "[x]" { return (String(rest.dropFirst(4)).trimmingCharacters(in: .whitespaces), true) }
        return (String(rest), nil)
    }

    private static func stripTag(_ line: String, open: String, close: String) -> String? {
        guard let start = line.range(of: open, options: .caseInsensitive) else { return nil }
        var inner = String(line[start.upperBound...])
        if let end = inner.range(of: close, options: .caseInsensitive) { inner = String(inner[..<end.lowerBound]) }
        return inner.trimmingCharacters(in: .whitespaces)
    }

    /// `[Cort Ouzts]: text` on every line of the paragraph: the scribe's transcript.
    private static func speakerLines(_ lines: [String]) -> [COSMarkdownSpeakerLine]? {
        guard lines.count >= 1 else { return nil }
        var out: [COSMarkdownSpeakerLine] = []
        for line in lines {
            guard let range = line.range(of: #"^\[([^\]]{1,64})\]:\s?"#, options: .regularExpression) else { return nil }
            let speaker = String(line[range]).replacingOccurrences(of: #"^\[|\]:\s?$"#, with: "", options: .regularExpression)
            out.append(COSMarkdownSpeakerLine(speaker: speaker, text: String(line[range.upperBound...])))
        }
        return out
    }
}


// MARK: - Inline runs (Messages, 2026-10-09)
//
// Message #356 printed `**Take Varesa.**` and `- [allthings.how: …](https://…)` as typed:
// the Messages cards were a plain Text while every other model-output pane already went
// through this renderer. The inline layer lives here, Foundation-only, so the contract can
// execute the link policy and the half-streamed shapes instead of trusting a picture.

extension COSMarkdownParser {
    /// Bold, italic, code and links through Foundation's inline parser. Anything it cannot
    /// close (a `**` or a `[` still streaming in) stays literal text, never dropped.
    /// A link survives only when it would open a web page: http or https with a host. Any
    /// other scheme (file, javascript, mailto, x-apple, a relative path) keeps its label as
    /// plain text and loses the link, so a tap can never hand the system a local action.
    static func inline(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        var string: AttributedString
        do {
            string = try AttributedString(markdown: text, options: options)
        } catch {
            string = AttributedString(text)
        }
        var refused: [Range<AttributedString.Index>] = []
        for run in string.runs {
            guard let url = run.link else { continue }
            if !opensAsWebLink(url) { refused.append(run.range) }
        }
        for range in refused { string[range].link = nil }
        return string
    }

    /// The one link policy: a web page, or nothing.
    static func opensAsWebLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        return true
    }

    /// One line of text for a list row: inline markers gone, heading and quote marks off the
    /// front of each line, links reduced to their labels. The stored text is never changed.
    static func plainText(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map { raw -> String in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if let level = headingLevel(line) { line = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces) }
            while line.hasPrefix(">") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return line
        }
        return String(inline(lines.joined(separator: "\n")).characters)
    }
}

// MARK: - Bounded caches (2026-10-09)

/// How many entries each renderer cache keeps. Exported so the contract checks eviction
/// against the numbers the app runs with, not a copy of them.
enum COSMarkdownCacheLimits {
    /// Parsed documents (COSMarkdownCache): one per message id, or per text when there is no id.
    static let documents = 128
    /// Inline runs (COSMarkdownInlineCache): one per distinct paragraph, list item or cell.
    static let inline = 1024
}

/// A bounded least-recently-used map, the eviction both renderer caches share. A hit makes
/// its key the newest; an insert into a full map drops the key used longest ago, never the
/// whole map. Before 2026-10-09 the inline cache cleared all 1024 entries when it filled, so
/// a long streamed answer (every token a new prefix, every prefix a new entry) wiped the runs
/// of the panes on screen again and again and made them parse again. Recency is a counter per
/// key, so a hit costs one dictionary write; only an insert into a full map scans for the
/// oldest. Pure Foundation, so Tests/MarkdownContract.swift executes it.
struct COSMarkdownLRU<Value> {
    let capacity: Int
    private var entries: [String: (value: Value, used: UInt64)] = [:]
    private var clock: UInt64 = 0

    init(capacity: Int) {
        precondition(capacity > 0, "an LRU holds at least one entry")
        self.capacity = capacity
    }

    var count: Int { entries.count }

    /// Whether `key` is held, without counting as a use.
    func contains(_ key: String) -> Bool { entries[key] != nil }

    /// The value for `key`, which becomes the most recently used.
    mutating func value(for key: String) -> Value? {
        guard let hit = entries[key] else { return nil }
        clock += 1
        entries[key] = (hit.value, clock)
        return hit.value
    }

    /// Stores `value` as the most recently used; a NEW key into a full map evicts the oldest.
    mutating func insert(_ value: Value, for key: String) {
        clock += 1
        if entries[key] == nil, entries.count >= capacity,
           let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[key] = (value, clock)
    }
}
