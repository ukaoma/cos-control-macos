import Foundation

/// 0.5.380 (preview engine phase 1, Miles's 11/08 screenshot of the Sessions reader): a reply that links local files
/// showed raw Markdown with full Mac paths (`![chart](/Users/.../chart.png)`, `[note](/Users/.../My note.md)`), and the
/// 0.5.380 cards under the reply would repeat them. Control Web turns each local link into its card in place (the server's
/// projection); the Mac reader draws the local transcript, so it makes the same change itself, here, before
/// COSMarkdownView: a local link reads as its card's words, a local image token goes (its card shows under the reply),
/// and web links and everything else stay exactly as written.
///
/// The rules are a port of the server's, unit for unit (JavaScript strings are UTF-16, so this works on UTF-16 units):
///   - `linkTokens`, `isLocalTarget`, `splitLineAnchor`, `baseName`, `linkLabel`, `linkCardWords`, LINK_SCAN_CHARS:
///     server/lib/session-links.ts;
///   - the card's name: `resolveLinkTarget`'s (the base name of the path as written, or as percent-decoded);
///   - `imageTokens` and OUTPUT_IMAGE_SCAN_CHARS: server/lib/agent-session-output-images.ts;
///   - the scan bound: a reply longer than the scan limit is scanned up to its last line break inside it (as the
///     projection does); the rest is shown as written.
/// Tests/session-reply-links-parity-pins.py fails when those server rules drift; Tests/SessionReplyLinksChecks.swift
/// executes the cases. Pure: no file is read, nothing is resolved on disk.
enum SessionReplyLinks {
    /// LINK_SCAN_CHARS and OUTPUT_IMAGE_SCAN_CHARS (both 128 * 1024 UTF-16 units).
    static let scanChars = 128 * 1024
    /// `close - i > 250` (links) and `endLabel - i > 250` (images).
    static let labelSpan = 250
    /// A destination longer than this is not a token; the balanced scan stops past it too.
    static let targetMax = 4096
    /// `slice(0, 120)` in baseName and linkLabel.
    static let wordsMax = 120

    struct Token: Equatable {
        let start: Int
        let end: Int
        let label: [UInt16]
        let target: [UInt16]
    }

    /// One change to the scanned text: a link's card words, or nil for an image token that goes.
    struct Edit {
        let start: Int
        let end: Int
        let words: [UInt16]?
    }

    /// `text.indexOf(needle, start)`, remembered: the scanners ask with rising starts, so a reply full of `[` with no `]`
    /// stays linear instead of rescanning the rest of the reply for every bracket. Same answers as a fresh search.
    struct NextIndex {
        let text: [UInt16]
        let needle: [UInt16]
        var from = Int.max
        var found: Int? = nil
        init(_ text: [UInt16], _ needle: [UInt16]) { self.text = text; self.needle = needle }
        mutating func callAsFunction(_ start: Int) -> Int? {
            if start >= from, found.map({ $0 >= start }) ?? true { return found }
            from = start
            found = SessionReplyLinks.indexOf(text, needle, from: start)
            return found
        }
    }

    /// What the Sessions reader shows for an assistant reply. Text with no local link and no local image is returned as is.
    static func readerText(_ text: String) -> String {
        guard mayHaveToken(text) else { return text }
        let all = Array(text.utf16)
        // The projection scans a long reply up to its last line break inside the limit (lastIndexOf('\n', limit - 1) + 1).
        var cut = all.count
        if all.count > scanChars {
            cut = 0
            var k = scanChars - 1
            while k >= 0 {
                if all[k] == nl { cut = k + 1; break }
                k -= 1
            }
        }
        let scanned = Array(all[0..<cut])
        let images = imageTokens(scanned)
        // Local links only, never one inside an image token (the projection's filter).
        let links = linkTokens(scanned).filter { l in
            isLocalTarget(l.target) && !images.contains { l.start < $0.end && $0.start < l.end }
        }
        if images.isEmpty && links.isEmpty { return text }

        var edits = images.map { Edit(start: $0.start, end: $0.end, words: nil) }
        edits += links.map { Edit(start: $0.start, end: $0.end, words: cardWords($0)) }
        edits.sort { $0.start < $1.start }
        var out: [UInt16] = []
        out.reserveCapacity(scanned.count)
        var removals: [Int] = []
        var end = 0
        for edit in edits {
            if edit.start < end { continue }
            out.append(contentsOf: scanned[end..<edit.start])
            end = edit.end
            if let words = edit.words { out.append(contentsOf: words); continue }
            // An image token goes. One space of the two around it goes with it; a line it leaves empty goes below.
            let prev = out.last
            let next: UInt16? = end < scanned.count ? scanned[end] : nil
            if let n = next, isSpace(n), prev == nil || prev == nl || isSpace(prev!) {
                end += 1
            } else if next == nil || next == nl || next == cr {
                while let p = out.last, isSpace(p) { out.removeLast() }
                removals = removals.map { min($0, out.count) }
            }
            removals.append(out.count)
        }
        out.append(contentsOf: scanned[end...])
        out = collapse(out, removals: removals, wholeText: cut == all.count)
        out.append(contentsOf: all[cut...])
        return String(decoding: out, as: UTF16.self)
    }

    // MARK: - Lines an image token left empty

    /// Drops each line a removed image left empty (or holding only a list marker), and a blank line that would then
    /// double the one before it. `wholeText`: nothing follows, so trailing blank lines left by a drop go too.
    static func collapse(_ units: [UInt16], removals: [Int], wholeText: Bool) -> [UInt16] {
        guard !removals.isEmpty else { return units }
        var lines: [ArraySlice<UInt16>] = []
        var starts: [Int] = []
        var s = 0
        for (k, u) in units.enumerated() where u == nl {
            lines.append(units[s..<k]); starts.append(s); s = k + 1
        }
        lines.append(units[s...]); starts.append(s)
        var touched = Set<Int>()
        var li = 0
        for r in removals.sorted() {
            while li + 1 < starts.count && starts[li + 1] <= r { li += 1 }
            touched.insert(li)
        }
        var kept: [ArraySlice<UInt16>] = []
        var dropped = false
        for (k, line) in lines.enumerated() {
            // A scanned prefix ends at a line break: its last (empty) line is that break, and always stays.
            if k == lines.count - 1 && !wholeText { kept.append(line); break }
            if touched.contains(k) && emptied(line) { dropped = true; continue }
            if dropped && blank(line) && (kept.last.map(blank) ?? true) { continue }
            if !blank(line) { dropped = false }
            kept.append(line)
        }
        if dropped && wholeText { while let last = kept.last, blank(last) { kept.removeLast() } }
        var out: [UInt16] = []
        out.reserveCapacity(units.count)
        for (k, line) in kept.enumerated() {
            if k > 0 { out.append(nl) }
            out.append(contentsOf: line)
        }
        return out
    }

    static func blank(_ line: ArraySlice<UInt16>) -> Bool {
        line.allSatisfy { isSpace($0) || $0 == cr }
    }

    /// Nothing left, or only a list marker (`-`, `*`, `+`, `1.`, `1)`).
    static func emptied(_ line: ArraySlice<UInt16>) -> Bool {
        var a = line.startIndex, b = line.endIndex
        while a < b && (isSpace(line[a]) || line[a] == cr) { a += 1 }
        while b > a && (isSpace(line[b - 1]) || line[b - 1] == cr) { b -= 1 }
        let core = Array(line[a..<b])
        if core.isEmpty { return true }
        if core.count == 1 { return core[0] == 0x2D || core[0] == 0x2A || core[0] == 0x2B }
        guard let last = core.last, last == 0x2E || last == 0x29, core.count - 1 <= 9 else { return false }
        return core.dropLast().allSatisfy(isDigit)
    }

    // MARK: - session-links.ts

    /// The words a local link's card shows: linkCardWords(label, the card's name, target).
    static func cardWords(_ token: Token) -> [UInt16] {
        linkCardWords(token.label, cardName(token.target), token.target)
    }

    /// `[label](target)` tokens, never `![..](..)`. A port of linkTokens: inert inside fences, inline code, indented blocks
    /// and comments; the label has no brackets or newline; the target is angle-wrapped (one line) or balanced parentheses
    /// on one line; a trailing ` "title"` is dropped.
    static func linkTokens(_ raw: [UInt16]) -> [Token] {
        let text = Array(raw.prefix(scanChars))
        let n = text.count
        var out: [Token] = []
        var fence: [UInt16] = []
        var inline = 0
        var nextClose = NextIndex(text, [closeBracket])
        var nextGT = NextIndex(text, [gt])
        var i = 0
        while i < n {
            defer { i += 1 }
            if i == 0 || text[i - 1] == nl {
                if fence.isEmpty && indented(text, i) {
                    guard let e = indexOf(text, [nl], from: i) else { break }
                    i = e; continue
                }
                if let run = fenceRun(text, i) {
                    if fence.isEmpty { fence = run } else if run[0] == fence[0] && run.count >= fence.count { fence = [] }
                    guard let e = indexOf(text, [nl], from: i) else { break }
                    i = e; continue
                }
            }
            if !fence.isEmpty { continue }
            if text[i] == backslash { i += 1; continue }
            if text[i] == backtick {
                var r = 1
                while i + r < n && text[i + r] == backtick { r += 1 }
                if inline == 0 { inline = r } else if inline == r { inline = 0 }
                i += r - 1; continue
            }
            if inline != 0 { continue }
            if startsWith(text, commentOpen, at: i) {
                guard let e = indexOf(text, commentClose, from: i + 4) else { break }
                i = e + 2; continue
            }
            if text[i] != openBracket || (i > 0 && text[i - 1] == bang) { continue }
            guard let close = nextClose(i + 1), close - i <= labelSpan,
                  close + 1 < n, text[close + 1] == openParen else { continue }
            let label = Array(text[(i + 1)..<close])
            if label.contains(openBracket) || label.contains(nl) { continue }
            guard let dest = destination(text, close + 2, angleOneLine: true, nextGT: &nextGT) else { continue }
            let j = dest.end
            var t = dest.target
            if t.isEmpty || t.count > targetMax || t.contains(where: isControl) { continue }
            if let titled = untitled(t) { t = titled }
            out.append(Token(start: i, end: j, label: label, target: t))
            i = j - 1
        }
        return out
    }

    /// The angle-wrapped or balanced destination starting at `j` (just past `(`), and the index just past its `)`.
    /// Links refuse a line break inside `<...>`; images do not check it (the control-character test refuses it after).
    static func destination(_ text: [UInt16], _ start: Int, angleOneLine: Bool, nextGT: inout NextIndex) -> (target: [UInt16], end: Int)? {
        let n = text.count
        var j = start
        if j < n && text[j] == lt {
            guard let e = nextGT(j + 1), e + 1 < n, text[e + 1] == closeParen else { return nil }
            if angleOneLine && text[(j + 1)..<e].contains(nl) { return nil }
            return (Array(text[(j + 1)..<e]), e + 2)
        }
        var depth = 1
        while j < n && j - start <= targetMax {
            if text[j] == nl { break }
            if text[j] == openParen { depth += 1 }
            if text[j] == closeParen {
                depth -= 1
                if depth == 0 { return (Array(text[start..<j]), j + 1) }
            }
            j += 1
        }
        return nil
    }

    /// `/^(\S+)\s+"[^"]*"$/`: the first part when the target is `path "title"`, else nil.
    static func untitled(_ t: [UInt16]) -> [UInt16]? {
        var k = 0
        while k < t.count && !isJSSpace(t[k]) { k += 1 }
        guard k > 0, k < t.count else { return nil }
        let first = Array(t[0..<k])
        while k < t.count && isJSSpace(t[k]) { k += 1 }
        guard k < t.count, t[k] == quote, t.count - k >= 2, t[t.count - 1] == quote else { return nil }
        return t[(k + 1)..<(t.count - 1)].contains(quote) ? nil : first
    }

    /// A target that names a local file: a path, `~/...` or `file://`. Web URLs, mail, anchors and network paths are not.
    static func isLocalTarget(_ target: [UInt16]) -> Bool {
        if target.isEmpty || target[0] == hash || startsWith(target, [slash, slash], at: 0) || target.contains(backslash) { return false }
        if startsWithFileScheme(target) { return true }
        return !hasScheme(splitLineAnchor(target).path)
    }

    /// `/^[a-z][a-z0-9+.-]*:/i`
    static func hasScheme(_ s: [UInt16]) -> Bool {
        guard let first = s.first, isASCIILetter(first) else { return false }
        var k = 1
        while k < s.count {
            let c = s[k]
            if c == colon { return true }
            if !(isASCIILetter(c) || isDigit(c) || c == 0x2B || c == 0x2E || c == 0x2D) { return false }
            k += 1
        }
        return false
    }

    /// `/^file:\/\//i`
    static func startsWithFileScheme(_ s: [UInt16]) -> Bool {
        let want: [UInt16] = Array("file://".utf16)
        guard s.count >= want.count else { return false }
        for (k, w) in want.enumerated() where lowerASCII(s[k]) != w { return false }
        return true
    }

    /// `x.ts:42`, `x.ts:42:7`, `x.ts:42-50`, `x.ts#L42`, `x.ts#L42-L50`: the path and line 42 (nil for none or 0).
    static func splitLineAnchor(_ target: [UInt16]) -> (path: [UInt16], line: Int?) {
        // /^(.*?)#L(\d{1,7})(?:C\d+)?(?:-L?\d{1,7})?$/ : the lazy prefix is the first place the rest matches.
        if let m = firstTail(target, hashLineTail), m.at > 0 {
            return (Array(target[0..<m.at]), lineNumber(m.digits))
        }
        // /^(.*?):(\d{1,7})(?::\d{1,5}|-\d{1,7})?$/ , and the path must not end with ':'.
        if let m = firstTail(target, colonLineTail), m.at > 0, target[m.at - 1] != colon {
            return (Array(target[0..<m.at]), lineNumber(m.digits))
        }
        if let h = target.firstIndex(of: hash), h > 0 { return (Array(target[0..<h]), nil) }
        return (target, nil)
    }

    /// The first position p (the lazy `(.*?)` of a `^...$` pattern) where `tail` matches the rest; `.` stops at a line
    /// terminator, so p never passes one.
    static func firstTail(_ s: [UInt16], _ tail: ([UInt16], Int) -> [UInt16]?) -> (at: Int, digits: [UInt16])? {
        var p = 0
        while p <= s.count {
            if let digits = tail(s, p) { return (p, digits) }
            if p == s.count || isLineTerminator(s[p]) { return nil }
            p += 1
        }
        return nil
    }

    /// `#L(\d{1,7})(?:C\d+)?(?:-L?\d{1,7})?$` at p: the line digits.
    static func hashLineTail(_ s: [UInt16], _ p: Int) -> [UInt16]? {
        guard p + 1 < s.count, s[p] == hash, s[p + 1] == 0x4C else { return nil }
        let d = digitRun(s, p + 2)
        guard d >= 1 && d <= 7 else { return nil }
        var q = p + 2 + d
        if q < s.count && s[q] == 0x43 {
            let c = digitRun(s, q + 1)
            guard c >= 1 else { return nil }
            q += 1 + c
        }
        if q == s.count { return Array(s[(p + 2)..<(p + 2 + d)]) }
        guard s[q] == dash else { return nil }
        var r = q + 1
        if r < s.count && s[r] == 0x4C { r += 1 }
        let e = digitRun(s, r)
        guard e >= 1 && e <= 7 && r + e == s.count else { return nil }
        return Array(s[(p + 2)..<(p + 2 + d)])
    }

    /// `:(\d{1,7})(?::\d{1,5}|-\d{1,7})?$` at p: the line digits.
    static func colonLineTail(_ s: [UInt16], _ p: Int) -> [UInt16]? {
        guard p < s.count, s[p] == colon else { return nil }
        let d = digitRun(s, p + 1)
        guard d >= 1 && d <= 7 else { return nil }
        let q = p + 1 + d
        let digits = Array(s[(p + 1)..<q])
        if q == s.count { return digits }
        let e = digitRun(s, q + 1)
        if s[q] == colon && e >= 1 && e <= 5 && q + 1 + e == s.count { return digits }
        if s[q] == dash && e >= 1 && e <= 7 && q + 1 + e == s.count { return digits }
        return nil
    }

    static func lineNumber(_ digits: [UInt16]) -> Int? {
        let value = digits.reduce(0) { $0 * 10 + Int($1 - 0x30) }
        return value == 0 ? nil : value
    }

    /// The base name a person sees: no directories, no control characters, at most 120 units.
    static func baseName(_ source: [UInt16]) -> [UInt16] {
        let parts = source.split(whereSeparator: { $0 == slash || $0 == backslash })
        let base: [UInt16] = parts.last.map { Array($0) } ?? []
        let clean = jsTrim(base.filter { !isControl($0) })
        return Array((clean.isEmpty ? Array("File".utf16) : clean).prefix(wordsMax))
    }

    /// A link's words, made safe to show: a label that is itself an absolute or home path becomes its base name.
    static func linkLabel(_ label: [UInt16], _ name: [UInt16]) -> [UInt16] {
        let clean = jsTrim(label.map { isControl($0) ? space : $0 })
        if clean.isEmpty { return name }
        let fileScheme: [UInt16] = Array("file://".utf16)
        if startsWith(clean, fileScheme, at: 0) || startsWith(clean, [tilde, slash], at: 0) || clean[0] == slash || namesMacFolder(clean) {
            return baseName(startsWith(clean, fileScheme, at: 0) ? Array(clean.dropFirst(fileScheme.count)) : clean)
        }
        return Array(clean.prefix(wordsMax))
    }

    /// `/(?:^|[\s(`'"])(?:\/Users\/|\/private\/|\/Volumes\/|\/var\/folders\/)/`
    static func namesMacFolder(_ s: [UInt16]) -> Bool {
        let roots: [[UInt16]] = ["/Users/", "/private/", "/Volumes/", "/var/folders/"].map { Array($0.utf16) }
        for k in 0..<s.count {
            guard k == 0 || isJSSpace(s[k - 1]) || [openParen, backtick, apostrophe, quote].contains(s[k - 1]) else { continue }
            if roots.contains(where: { startsWith(s, $0, at: k) }) { return true }
        }
        return false
    }

    /// The words a link card shows. A label that is the file's own name keeps the line the link points at.
    static func linkCardWords(_ label: [UInt16], _ name: [UInt16], _ target: [UInt16]) -> [UInt16] {
        let words = linkLabel(label, name)
        let anchor = splitLineAnchor(target)
        guard let line = anchor.line else { return words }
        let own = baseName(startsWithFileScheme(anchor.path) ? Array(anchor.path.dropFirst(7)) : anchor.path)
        return words == own || words == name ? words + [colon] + Array(String(line).utf16) : words
    }

    /// resolveLinkTarget's `name`: the base name of the path as written, or as decodeURIComponent reads it when it
    /// holds a `%XX` and decodes (a malformed escape keeps it as written).
    static func cardName(_ target: [UInt16]) -> [UInt16] {
        let written = splitLineAnchor(target).path
        var last = written
        if hasPercentEscape(written), let decoded = decodeURIComponent(written), decoded != written { last = decoded }
        return baseName(last)
    }

    static func hasPercentEscape(_ s: [UInt16]) -> Bool {
        guard s.count >= 3 else { return false }
        for k in 0..<(s.count - 2) where s[k] == percent && hexValue(s[k + 1]) != nil && hexValue(s[k + 2]) != nil { return true }
        return false
    }

    /// ECMAScript decodeURIComponent: nil where it throws URIError.
    static func decodeURIComponent(_ s: [UInt16]) -> [UInt16]? {
        var out: [UInt16] = []
        var k = 0
        let len = s.count
        func byte(at k: Int) -> UInt8? {
            guard k + 2 < len, s[k] == percent, let h = hexValue(s[k + 1]), let l = hexValue(s[k + 2]) else { return nil }
            return UInt8(h << 4 | l)
        }
        while k < len {
            if s[k] != percent { out.append(s[k]); k += 1; continue }
            guard let b = byte(at: k) else { return nil }
            k += 3
            if b & 0x80 == 0 { out.append(UInt16(b)); continue }
            var count = 0
            while count < 8 && (b << UInt8(count)) & 0x80 != 0 { count += 1 }
            guard count != 1 && count <= 4 else { return nil }
            var cp = UInt32(b) & (0xFF >> UInt32(count + 1))
            for _ in 1..<count {
                guard let c = byte(at: k), c & 0xC0 == 0x80 else { return nil }
                cp = cp << 6 | UInt32(c & 0x3F)
                k += 3
            }
            let minimum: UInt32 = count == 2 ? 0x80 : count == 3 ? 0x800 : 0x10000
            guard cp >= minimum, cp <= 0x10FFFF, !(0xD800...0xDFFF).contains(cp), let scalar = Unicode.Scalar(cp) else { return nil }
            out.append(contentsOf: Array(String(Character(scalar)).utf16))
        }
        return out
    }

    // MARK: - agent-session-output-images.ts

    /// Local `![alt](path)` tokens. A port of imageTokens: the same inert regions; the alt has no line break; a scheme,
    /// a network path or a backslash is skipped whole (never a token, never scanned inside).
    static func imageTokens(_ raw: [UInt16]) -> [Token] {
        let text = Array(raw.prefix(scanChars))
        let n = text.count
        var out: [Token] = []
        var fence: [UInt16] = []
        var inline = 0
        var nextEndLabel = NextIndex(text, [closeBracket, openParen])
        var nextGT = NextIndex(text, [gt])
        var i = 0
        while i < n {
            defer { i += 1 }
            if i == 0 || text[i - 1] == nl {
                if fence.isEmpty && indented(text, i) {
                    guard let e = indexOf(text, [nl], from: i) else { break }
                    i = e; continue
                }
                if let run = fenceRun(text, i) {
                    if fence.isEmpty { fence = run } else if run[0] == fence[0] && run.count >= fence.count { fence = [] }
                    guard let e = indexOf(text, [nl], from: i) else { break }
                    i = e; continue
                }
            }
            if !fence.isEmpty { continue }
            if text[i] == backslash { i += 1; continue }
            if text[i] == backtick {
                var r = 1
                while i + r < n && text[i + r] == backtick { r += 1 }
                if inline == 0 { inline = r } else if inline == r { inline = 0 }
                i += r - 1; continue
            }
            if inline != 0 { continue }
            if startsWith(text, commentOpen, at: i) {
                guard let e = indexOf(text, commentClose, from: i + 4) else { break }
                i = e + 2; continue
            }
            guard text[i] == bang, i + 1 < n, text[i + 1] == openBracket else { continue }
            guard let endLabel = nextEndLabel(i + 2), endLabel - i <= labelSpan,
                  !text[i..<endLabel].contains(nl) else { continue }
            guard let dest = destination(text, endLabel + 2, angleOneLine: false, nextGT: &nextGT) else { continue }
            let source = dest.target, j = dest.end
            if source.isEmpty || source.count > targetMax || source.contains(where: isControl) { continue }
            if hasScheme(source) || startsWith(source, [slash, slash], at: 0) || source.contains(backslash) { i = j - 1; continue }
            out.append(Token(start: i, end: j, label: Array(text[(i + 2)..<endLabel]), target: source))
            i = j - 1
        }
        return out
    }

    // MARK: - Shared scanner pieces

    /// `/^(?: {4}| {0,3}\t)/` on the line's first four units.
    static func indented(_ t: [UInt16], _ i: Int) -> Bool {
        var k = 0
        while k < 4 && i + k < t.count && t[i + k] == space { k += 1 }
        if k == 4 { return true }
        return i + k < t.count && t[i + k] == tab
    }

    /// `/^( {0,3})(`{3,}|~{3,})/` on the line's first 80 units: the run.
    static func fenceRun(_ t: [UInt16], _ i: Int) -> [UInt16]? {
        let limit = min(t.count, i + 80)
        var k = i
        while k < limit && k - i < 3 && t[k] == space { k += 1 }
        guard k < limit, t[k] == backtick || t[k] == tilde else { return nil }
        let mark = t[k]
        var e = k
        while e < limit && t[e] == mark { e += 1 }
        return e - k >= 3 ? Array(t[k..<e]) : nil
    }

    static func indexOf(_ t: [UInt16], _ needle: [UInt16], from: Int) -> Int? {
        var k = max(from, 0)
        while k + needle.count <= t.count {
            if startsWith(t, needle, at: k) { return k }
            k += 1
        }
        return nil
    }

    static func startsWith(_ t: [UInt16], _ prefix: [UInt16], at k: Int) -> Bool {
        guard k >= 0, k + prefix.count <= t.count else { return false }
        for (m, u) in prefix.enumerated() where t[k + m] != u { return false }
        return true
    }

    static func digitRun(_ s: [UInt16], _ from: Int) -> Int {
        var k = from
        while k < s.count && isDigit(s[k]) { k += 1 }
        return k - from
    }

    /// String.prototype.trim: JavaScript white space and line terminators.
    static func jsTrim(_ s: [UInt16]) -> [UInt16] {
        var a = 0, b = s.count
        while a < b && isJSSpace(s[a]) { a += 1 }
        while b > a && isJSSpace(s[b - 1]) { b -= 1 }
        return Array(s[a..<b])
    }

    /// JavaScript's `\s` (and trim's set): WhiteSpace (tab, VT, FF, ZWNBSP, Zs) and LineTerminator.
    static func isJSSpace(_ u: UInt16) -> Bool {
        switch u {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        default: return false
        }
    }

    /// What JavaScript's `.` does not match.
    static func isLineTerminator(_ u: UInt16) -> Bool { u == 0x0A || u == 0x0D || u == 0x2028 || u == 0x2029 }
    static func isControl(_ u: UInt16) -> Bool { u <= 0x1F || u == 0x7F }
    static func isDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }
    static func isSpace(_ u: UInt16) -> Bool { u == space || u == tab }
    static func isASCIILetter(_ u: UInt16) -> Bool { (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) }
    static func lowerASCII(_ u: UInt16) -> UInt16 { u >= 0x41 && u <= 0x5A ? u + 0x20 : u }
    static func hexValue(_ u: UInt16) -> UInt8? {
        switch u {
        case 0x30...0x39: return UInt8(u - 0x30)
        case 0x41...0x46: return UInt8(u - 0x41 + 10)
        case 0x61...0x66: return UInt8(u - 0x61 + 10)
        default: return nil
        }
    }

    /// No `](` anywhere means no link and no image token: the common reply returns at once.
    static func mayHaveToken(_ text: String) -> Bool {
        var previous: UInt16 = 0
        for u in text.utf16 {
            if previous == closeBracket && u == openParen { return true }
            previous = u
        }
        return false
    }

    static let nl: UInt16 = 0x0A, cr: UInt16 = 0x0D, tab: UInt16 = 0x09, space: UInt16 = 0x20
    static let bang: UInt16 = 0x21, quote: UInt16 = 0x22, hash: UInt16 = 0x23, percent: UInt16 = 0x25, apostrophe: UInt16 = 0x27
    static let openParen: UInt16 = 0x28, closeParen: UInt16 = 0x29, dash: UInt16 = 0x2D, slash: UInt16 = 0x2F, colon: UInt16 = 0x3A
    static let lt: UInt16 = 0x3C, gt: UInt16 = 0x3E, openBracket: UInt16 = 0x5B, backslash: UInt16 = 0x5C, closeBracket: UInt16 = 0x5D
    static let backtick: UInt16 = 0x60, tilde: UInt16 = 0x7E
    static let commentOpen: [UInt16] = Array("<!--".utf16), commentClose: [UInt16] = Array("-->".utf16)
}
