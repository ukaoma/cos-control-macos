import Foundation

/// 0.5.380 (Miles 2026-11-08, server 7.0.5 parity): a COS answer is written for the G2 lens as plain text, so a numbered
/// list arrives inline ("...for me: 1. Prep before each meeting. 2. Catching conflicts early. 3. ..."), one long paragraph
/// in the Messages pane. Before COSMarkdownView draws a COS answer, each run of inline items 1, 2, 3 in order goes on its own
/// line under its lead-in. Only whitespace changes: every other character of the answer stays, in order. The lens, the
/// stored text, Copy turn and Copy answer never see it.
///
/// This is a port of structureLensAnswer in the server's web-control/app.js (Control Web draws the same answer the same
/// way). The rules are the web's, exactly: text with any Markdown structure is left alone; a marker counts only after a
/// sentence end (". " ": " "? " "! ") and never inside a code, bold or italic span; fewer than two items, or numbers out of
/// order, are not a list; words after the last item stay in it, except a short "Label:" sentence followed by a new 1,
/// which starts the next list. Since 0.5.380's final QA (server 7.0.7, W1): a new line never starts with what a renderer
/// reads as a block. A "Label:" that starts with one stays on the line before it, and a list whose item starts with one is
/// left as it is (never half a list). Positions are UTF-16 offsets, as in JavaScript. Tests/lens-answer-parity-pins.py compares the patterns
/// below with the web's LA_* constants; the JavaScript `\d` is written [0-9] and `\S` is [^\s\x{0B}\x{FEFF}] here,
/// because ICU's \d and \s are wider and narrower than JavaScript's.
enum LensAnswerStructure {
    /// LA_STRUCTURED: a bullet, numbered line, heading, quote or table row, a blank line, or a fence.
    static let structuredPattern = #"^[ \t]*(?:[-*+][ \t]|[0-9]{1,3}[.)][ \t]|#|>|\|)|\n[ \t]*\n|```|~~~"#
    /// LA_MARK: a sentence end, the space after it, then "N." with words after it.
    static let markPattern = #"([.:?!]["'”’)]?)([ \t]+)([1-9][0-9]?)\.(?=[ \t]+[^\s\x{0B}\x{FEFF}])"#
    /// LA_END: a sentence end and the space after it (the lead-in's own sentence start).
    static let endPattern = #"[.?!]["'”’)]?([ \t]+)"#
    /// Spans no cut may enter. Each kind is found on its own, as its renderer finds it, and a cut is refused inside any of
    /// them: the web md()'s own `code` and **bold** (never empty, no star inside bold), and for this pane's inline
    /// Markdown *italic*, __bold__ and _italic_, each opening on a non-space and closing after one, on one line ("2 * 3"
    /// and a lone "*" are not spans). A word's own underscores (max_tokens, top_p) are matched first, so they never open
    /// a span. A link holds no whitespace, and only whitespace is ever replaced, so a link is never cut.
    /// LA_GUARD: code spans.
    static let guardPattern = #"`[^`\n]+`"#
    /// LA_BOLD: md()'s **bold**.
    static let boldPattern = #"\*\*[^*\n]+\*\*"#
    /// LA_STAR: *italic*.
    static let starPattern = #"\*(?!\*)[^\s\x{0B}\x{FEFF}](?:[^*\n]*(?!\*)[^\s\x{0B}\x{FEFF}])?\*"#
    /// LA_UNDER: a word's own underscores first, then __bold__ and _italic_ that do not close inside a word.
    static let underPattern = #"[A-Za-z0-9]_+|__(?!_)[^\s\x{0B}\x{FEFF}](?:[^_\n]*(?!_)[^\s\x{0B}\x{FEFF}])?__(?![A-Za-z0-9])|_(?!_)[^\s\x{0B}\x{FEFF}](?:[^_\n]*(?!_)[^\s\x{0B}\x{FEFF}])?_(?![A-Za-z0-9])"#
    /// LA_BLOCK_START: what a line may not start with when a cut makes it start (COSMarkdownParser reads all of these: a
    /// heading, quote, bullet or table row, a "[Speaker]:" line, "<details>", or a number list marker). Matched at one
    /// position only (the web's sticky flag is `.anchored` here).
    static let blockStartPattern = #"[ \t]*(?:[\-#>*+|<\[]|[0-9]+[.)])"#
    /// LA_ITEM_START: what an item's own words may not start with: a heading, a quote, or a task box ("1. [x] done").
    static let itemStartPattern = #"[ \t]*(?:[#>]|\[[ xX]\])"#
    /// LA_LABEL_MAX: a "Label:" lead-in longer than this stays in the item before it.
    static let labelMax = 100

    private static let structured = try! NSRegularExpression(pattern: structuredPattern, options: [.anchorsMatchLines])
    private static let mark = try! NSRegularExpression(pattern: markPattern)
    private static let end = try! NSRegularExpression(pattern: endPattern)
    private static let codeSpan = try! NSRegularExpression(pattern: guardPattern)
    private static let bold = try! NSRegularExpression(pattern: boldPattern)
    private static let star = try! NSRegularExpression(pattern: starPattern)
    private static let under = try! NSRegularExpression(pattern: underPattern)
    private static let blockStart = try! NSRegularExpression(pattern: blockStartPattern)
    private static let itemStart = try! NSRegularExpression(pattern: itemStartPattern)
    /// LA_SPANS, in the web's order.
    private static let spanKinds = [codeSpan, bold, star, under]

    /// Does `regex` match starting exactly at `at` (UTF-16) in `line`? The web's sticky `re.lastIndex = at; re.test(line)`.
    private static func startsAt(_ regex: NSRegularExpression, _ line: NSString, at: Int) -> Bool {
        regex.firstMatch(in: line as String, options: [.anchored], range: NSRange(location: at, length: line.length - at)) != nil
    }

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
        let kinds = spanKinds.map { kind in kind.matches(in: line, options: [], range: full).map { $0.range } }.filter { !$0.isEmpty }
        // Inside a span of any kind? One kind's spans are in order and never overlap: binary search each.
        func guarded(_ at: Int) -> Bool {
            for spans in kinds {
                var lo = 0
                var hi = spans.count - 1
                while lo <= hi {
                    let mid = (lo + hi) / 2
                    if spans[mid].location > at { hi = mid - 1 } else if NSMaxRange(spans[mid]) <= at { lo = mid + 1 } else { return true }
                }
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
            // An item whose words start a block leaves its whole list as it is; it still counts as a list, so the words
            // after it stay in its last item.
            let clean = !run.contains { startsAt(itemStart, ns, at: $0.body) }
            if clean {
                if first.colon {
                    // The lead-in is the "Label:" sentence: it gets its own line when it is short and does not start a
                    // block. Only sentence ends that finish before the list's own space count (the web stops at the first
                    // that does not).
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
                    if from >= 0 && first.ws - to <= labelMax && !startsAt(blockStart, ns, at: to) {
                        cuts.append(Cut(from: from, to: to, with: "\n\n"))
                    }
                }
                cuts.append(Cut(from: first.ws, to: first.at, with: "\n\n"))
                for item in run.dropFirst() { cuts.append(Cut(from: item.ws, to: item.at, with: "\n")) }
            }
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
