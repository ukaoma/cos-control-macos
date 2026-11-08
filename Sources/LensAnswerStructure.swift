import Foundation

/// 0.5.380 (Miles 2026-11-08, server 7.0.5 parity): a COS answer is written for the G2 lens as plain text, so a numbered
/// list arrives inline ("...for me: 1. Prep before each meeting. 2. Catching conflicts early. 3. ..."), one long paragraph
/// in the Messages pane. Before COSMarkdownView draws a COS answer, each run of inline items 1, 2, 3 in order goes on its own
/// line under its lead-in. Only whitespace changes: every other character of the answer stays, in order. The lens, the
/// stored text and Copy turn never see it.
///
/// This is a port of structureLensAnswer in the server's web-control/app.js (Control Web draws the same answer the same
/// way). The rules are the web's, exactly: text with any Markdown structure is left alone; a marker counts only after a
/// sentence end (". " ": " "? " "! ") and never inside a code span; fewer than two items, or numbers out of order, are not
/// a list; words after the last item stay in it, except a short "Label:" sentence followed by a new 1, which starts the
/// next list. Positions are UTF-16 offsets, as in JavaScript. Tests/lens-answer-parity-pins.py compares the patterns
/// below with the web's LA_* constants; the JavaScript `\d` is written [0-9] and `\S` is [^\s\x{0B}\x{FEFF}] here,
/// because ICU's \d and \s are wider and narrower than JavaScript's.
enum LensAnswerStructure {
    /// LA_STRUCTURED: a bullet, numbered line, heading, quote or table row, a blank line, or a fence.
    static let structuredPattern = #"^[ \t]*(?:[-*+][ \t]|[0-9]{1,3}[.)][ \t]|#|>|\|)|\n[ \t]*\n|```|~~~"#
    /// LA_MARK: a sentence end, the space after it, then "N." with words after it.
    static let markPattern = #"([.:?!]["'”’)]?)([ \t]+)([1-9][0-9]?)\.(?=[ \t]+[^\s\x{0B}\x{FEFF}])"#
    /// LA_END: a sentence end and the space after it (the lead-in's own sentence start).
    static let endPattern = #"[.?!]["'”’)]?([ \t]+)"#
    /// LA_GUARD: code spans only. A link holds no whitespace, and only whitespace is ever replaced, so a link is never cut.
    static let guardPattern = #"`[^`\n]*`"#
    /// LA_LABEL_MAX: a "Label:" lead-in longer than this stays in the item before it.
    static let labelMax = 100

    private static let structured = try! NSRegularExpression(pattern: structuredPattern, options: [.anchorsMatchLines])
    private static let mark = try! NSRegularExpression(pattern: markPattern)
    private static let end = try! NSRegularExpression(pattern: endPattern)
    private static let codeSpan = try! NSRegularExpression(pattern: guardPattern)

    /// The answer with its inline numbered lists on their own lines, or the text itself when there is nothing to do.
    static func structure(_ text: String) -> String {
        let whole = text as NSString
        if whole.range(of: ". ", options: .literal).location == NSNotFound { return text }
        if structured.firstMatch(in: text, options: [], range: NSRange(location: 0, length: whole.length)) != nil { return text }
        // Lines split at "\n" only, in UTF-16 (a Swift Character would keep "\r\n" whole).
        var lines: [String] = []
        var start = 0
        var offset = 0
        for unit in text.utf16 {
            if unit == 0x0A {
                lines.append(whole.substring(with: NSRange(location: start, length: offset - start)))
                start = offset + 1
            }
            offset += 1
        }
        lines.append(whole.substring(with: NSRange(location: start, length: whole.length - start)))
        var out: [String] = []
        var changed = false
        for (index, line) in lines.enumerated() {
            if let listed = structureLine(line) {
                changed = true
                // A line that became a list ends with a blank line before whatever follows it.
                out.append(index < lines.count - 1 ? listed + "\n" : listed)
            } else {
                out.append(line)
            }
        }
        return changed ? out.joined(separator: "\n") : text
    }

    private struct Mark {
        let colon: Bool
        let ws: Int
        let at: Int
        let body: Int
        let n: Int
    }

    private struct Cut {
        let from: Int
        let to: Int
        let with: String
    }

    /// One line's lists, or nil when the line stays as it is.
    private static func structureLine(_ line: String) -> String? {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        let spans = codeSpan.matches(in: line, options: [], range: full).map { $0.range }
        // Inside a code span? The spans are in order and never overlap: binary search.
        func guarded(_ at: Int) -> Bool {
            var lo = 0
            var hi = spans.count - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                if spans[mid].location > at { hi = mid - 1 } else if NSMaxRange(spans[mid]) <= at { lo = mid + 1 } else { return true }
            }
            return false
        }
        var marks: [Mark] = []
        for m in mark.matches(in: line, options: [], range: full) {
            let punct = m.range(at: 1)
            let space = m.range(at: 2)
            let digits = m.range(at: 3)
            let ws = m.range.location + punct.length
            let at = ws + space.length
            if guarded(m.range.location) || guarded(at) { continue }
            marks.append(Mark(colon: ns.character(at: punct.location) == 0x3A, ws: ws, at: at,
                              body: at + digits.length + 1, n: Int(ns.substring(with: digits)) ?? 0))
        }
        // Runs of 1, 2, 3 in order; two items or more make a list.
        var runs: [[Mark]] = []
        var cur: [Mark] = []
        for c in marks {
            if let last = cur.last, c.n == last.n + 1 { cur.append(c); continue }
            if cur.count >= 2 { runs.append(cur) }
            cur = c.n == 1 ? [c] : []
        }
        if cur.count >= 2 { runs.append(cur) }
        var cuts: [Cut] = []
        var prevEnd = 0
        var lists = 0
        for run in runs {
            let first = run[0]
            // After a list, only a "Label:" lead-in starts another; anything else stays in the last item.
            if lists > 0 && !first.colon { continue }
            if first.colon {
                // The lead-in is the "Label:" sentence: it gets its own line when it is short. Only sentence ends that
                // finish before the list's own space count (the web stops at the first that does not).
                var from = -1
                var to = -1
                let scan = NSRange(location: prevEnd, length: max(0, first.ws - prevEnd))
                for e in end.matches(in: line, options: [], range: scan) {
                    if NSMaxRange(e.range) >= first.ws { break }
                    if !guarded(e.range.location) {
                        to = NSMaxRange(e.range)
                        from = to - e.range(at: 1).length
                    }
                }
                if from >= 0 && first.ws - to <= labelMax { cuts.append(Cut(from: from, to: to, with: "\n\n")) }
            }
            cuts.append(Cut(from: first.ws, to: first.at, with: "\n\n"))
            for item in run.dropFirst() { cuts.append(Cut(from: item.ws, to: item.at, with: "\n")) }
            prevEnd = run[run.count - 1].body   // after the last item's own "5.", which is not a sentence end
            lists += 1
        }
        if cuts.isEmpty { return nil }
        var result = ""
        var pos = 0
        for cut in cuts {
            result += ns.substring(with: NSRange(location: pos, length: cut.from - pos)) + cut.with
            pos = cut.to
        }
        return result + ns.substring(from: pos)
    }
}
