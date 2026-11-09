import Foundation

// 0.5.380 (preview engine phase 1, Miles's 11/08 Sessions reader screenshot): what the reader shows for an assistant reply
// (Sources/SessionReplyLinks.swift), executed. The table's expected values, and the golden fixture
// (Tests/fixtures/session-reply-links-golden.json: 300 generated replies), were produced by the server's own linkTokens,
// isLocalTarget, linkCardWords, resolveLinkTarget(...).name and imageTokens, so a pass here is the Mac agreeing with the
// server unit for unit. Tests/session-reply-links-parity-pins.py fails when those server rules drift. Compiled with
// SessionReplyLinks.swift alone by Tests/run-session-reply-links.sh (the fixture path is the first argument).
// Prints "session reply links checks: N passed".

/// Miles's reply as the 0.5.378 reader showed it (one local image, four local links with spaces in their paths).
let MILES = "I've added a test set to this session. On your phone, open this session in Control Web's Sessions reader, or Today's session sheet. Each link below should show as a file card, and the image above it as an image preview.\n\n![Preview test chart](/Users/ukaoma/Documents/GitHub/Ukaoma Chief Of Staff/MU-Chief-Staff/operations/personal/wk45_2026/preview_705/test-cards/preview-test-chart.png)\n\n- [Preview test note](/Users/ukaoma/Documents/GitHub/Ukaoma Chief Of Staff/MU-Chief-Staff/operations/personal/wk45_2026/preview_705/test-cards/preview-test-note.md): Markdown with a heading, list, bold text and a small table.\n- [Preview test page](/Users/ukaoma/Documents/GitHub/Ukaoma Chief Of Staff/MU-Chief-Staff/operations/personal/wk45_2026/preview_705/test-cards/preview-test-page.html): HTML in the sandbox. Tap Run scripts and the last line changes to \"Scripts ran: Run scripts is on.\" The accents should read correctly: “déjà vu”, naïve, 25°.\n- [Preview test table](/Users/ukaoma/Documents/GitHub/Ukaoma Chief Of Staff/MU-Chief-Staff/operations/personal/wk45_2026/preview_705/test-cards/preview-test-table.csv): a CSV table with four rows.\n- [preview-test-code.ts:7](/Users/ukaoma/Documents/GitHub/Ukaoma Chief Of Staff/MU-Chief-Staff/operations/personal/wk45_2026/preview_705/test-cards/preview-test-code.ts:7): a code file. The card should read `preview-test-code.ts:7` and open at that line.\n\n**What you should see:**\n1. **The image** shows as a picture card with five bars and the heading \"Preview test: COS 7.0.5\". This session also opened the same chart while checking it, so it may show a second time as an image the session looked at.\n2. **The four links** show as cards with their names and types, not as file paths. No folder path appears on the phone.\n3. **Tapping a card** opens the viewer. Back returns you to the reply.\n4. **Thumbnails** for the HTML page come from Quick Look, so they can take a few seconds to appear the first time.\n\nIf any card shows as raw text like `[name](cos-file:0)`, reload the Control Web tab; it was probably open before the update."
let MILES_READER = "I've added a test set to this session. On your phone, open this session in Control Web's Sessions reader, or Today's session sheet. Each link below should show as a file card, and the image above it as an image preview.\n\n- Preview test note: Markdown with a heading, list, bold text and a small table.\n- Preview test page: HTML in the sandbox. Tap Run scripts and the last line changes to \"Scripts ran: Run scripts is on.\" The accents should read correctly: “déjà vu”, naïve, 25°.\n- Preview test table: a CSV table with four rows.\n- preview-test-code.ts:7: a code file. The card should read `preview-test-code.ts:7` and open at that line.\n\n**What you should see:**\n1. **The image** shows as a picture card with five bars and the heading \"Preview test: COS 7.0.5\". This session also opened the same chart while checking it, so it may show a second time as an image the session looked at.\n2. **The four links** show as cards with their names and types, not as file paths. No folder path appears on the phone.\n3. **Tapping a card** opens the viewer. Back returns you to the reply.\n4. **Thumbnails** for the HTML page come from Quick Look, so they can take a few seconds to appear the first time.\n\nIf any card shows as raw text like `[name](cos-file:0)`, reload the Control Web tab; it was probably open before the update."

/// (input, expected). One pair per line, plain literals.
let cases: [(String, String)] = [
    // CASES BEGIN
    ("See [plan](docs/plan.md) now.", "See plan now."),
    ("Saved to [notes](~/Desktop/notes.txt).", "Saved to notes."),
    ("[report](file:///Users/x/My%20Report.pdf)", "report"),
    ("Open [](file:///Users/x/My%20Report.pdf) first.", "Open My Report.pdf first."),
    ("Run `[a](b.md)` and `![c](d.png)` here.", "Run `[a](b.md)` and `![c](d.png)` here."),
    ("```\n[a](b.md)\n![c](d.png)\n```", "```\n[a](b.md)\n![c](d.png)\n```"),
    ("See [docs](https://example.com/a.md) and [mail](mailto:x@y.z).", "See [docs](https://example.com/a.md) and [mail](mailto:x@y.z)."),
    ("![logo](https://example.com/logo.png)", "![logo](https://example.com/logo.png)"),
    ("Open [the deck](</Users/x/Q3 Plan/deck final.pptx>) today.", "Open the deck today."),
    ("[/Users/x/plan.md](/Users/x/plan.md)", "plan.md"),
    ("[/Users/x/app.ts](/Users/x/app.ts#L42)", "app.ts:42"),
    ("Here:\n\n![a](a.png)\n![b](b.png)\n\nDone.", "Here:\n\nDone."),
    ("- ![a](out/a.png)\n- [b](b.md)", "- b"),
    ("Nothing to see. [x] (y) and ](here).", "Nothing to see. [x] (y) and ](here)."),
    ("Chart ![c](c.png) above", "Chart above"),
    ("Chart: ![c](c.png)\nNext line.", "Chart:\nNext line."),
    ("Read [spec](docs/spec.md \"The spec\").", "Read spec."),
    ("    [a](b.md)\n", "    [a](b.md)\n"),
    ("<!-- [a](b.md) -->", "<!-- [a](b.md) -->"),
    ("\\[a](b.md)", "\\[a](b.md)"),
    ("[top](#top)", "[top](#top)"),
    ("[app.ts](src/app.ts:42) and [the handler](src/app.ts:42)", "app.ts:42 and the handler"),
    ("[site](https://x.com) and [file](a.md)", "[site](https://x.com) and file"),
    ("Look: [plan](Q3%20plan.md)", "Look: plan"),
    ("Look: [](Q3%20plan.md) and [](bad%zzname.md)", "Look: Q3 plan.md and bad%zzname.md"),
    ("![chart](</Users/x/My Charts/c.png>)\n\nThe chart above.", "The chart above."),
    ("Shot:\n\n![s](shot.png)", "Shot:"),
    ("1. ![a](a.png)\n2. [b](b.md)", "2. b"),
    ("[b:](a/b::12) and [](docs/nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn.md:3)", "b: and nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn:3"),
    // CASES END
]

@main struct SessionReplyLinksChecks {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func same(_ a: String, _ b: String) -> Bool { Array(a.utf16) == Array(b.utf16) }
        let f = SessionReplyLinks.readerText
        let u = { (s: String) in Array(s.utf16) }

        // ── Miles's screenshot: the image line goes, the four links read as their cards' words, nothing else moves.
        let shown = f(MILES)
        check(same(shown, MILES_READER), "Miles's reply: \(shown.debugDescription)")
        // Outside code spans (the reply quotes `[name](cos-file:0)` in one, and code is left as written, as on the server).
        let prose = shown.replacingOccurrences(of: "`[^`\n]*`", with: "", options: .regularExpression)
        check(!prose.contains("/Users/") && !prose.contains("![") && !prose.contains("]("), "no Mac path and no Markdown link is left outside code")
        for line in ["- Preview test note: Markdown", "- Preview test page: HTML", "- Preview test table: a CSV", "- preview-test-code.ts:7: a code file"] {
            check(shown.contains(line), "the card words read \(line)")
        }
        check(shown.contains("image preview.\n\n- Preview test note"), "the image's line and its blank line collapse to one break")
        check(shown.contains("`preview-test-code.ts:7`") && shown.contains("`[name](cos-file:0)`"), "code spans stay as written")
        check(shown.hasSuffix("it was probably open before the update."), "the reply's last words stay")

        // ── The table.
        for (input, expected) in cases {
            let out = f(input)
            check(same(out, expected), "\(input.debugDescription) -> \(out.debugDescription), expected \(expected.debugDescription)")
        }
        // A reply with nothing local is returned as it came, and one without "](" never reaches the scanners.
        for text in ["", "No links at all.", "See [docs](https://example.com/a.md).", "![logo](https://e.com/l.png)", "`[a](b.md)`"] {
            check(same(f(text), text), "unchanged: \(text.debugDescription)")
        }
        check(!SessionReplyLinks.mayHaveToken("[a] (b.md) ![c] (d.png)") && SessionReplyLinks.mayHaveToken("[a](b.md)"), "the quick test")

        // ── The pieces, on the server's own examples.
        let anchor = { (s: String) -> (String, Int?) in
            let r = SessionReplyLinks.splitLineAnchor(u(s)); return (String(decoding: r.path, as: UTF16.self), r.line)
        }
        for (target, path, line) in [("x.ts:42", "x.ts", 42), ("x.ts:42:7", "x.ts", 42), ("x.ts:42-50", "x.ts", 42), ("x.ts#L42", "x.ts", 42),
                                     ("x.ts#L42-L50", "x.ts", 42), ("x.ts#L3C2", "x.ts", 3), ("x.ts#frag", "x.ts", 0), ("x.ts:0", "x.ts", 0),
                                     ("c:42", "c", 42), ("x::12", "x::12", 0), (":12", ":12", 0), ("q.ts:12345678", "q.ts:12345678", 0)] {
            let (p, l) = anchor(target)
            check(p == path && (l ?? 0) == line, "splitLineAnchor(\(target)) = \(p), \(String(describing: l))")
        }
        for (target, local) in [("a.md", true), ("~/a.md", true), ("/Users/x/a.md", true), ("file:///x", true), ("FILE:///x", true),
                                ("c.ts:42", true), ("https://e.com", false), ("mailto:a@b", false), ("#top", false), ("//host/x", false),
                                ("a\\b", false), ("s3:x", false), ("", false)] {
            check(SessionReplyLinks.isLocalTarget(u(target)) == local, "isLocalTarget(\(target)) == \(local)")
        }
        let decode = { (s: String) in SessionReplyLinks.decodeURIComponent(u(s)).map { String(decoding: $0, as: UTF16.self) } }
        check(decode("Q3%20plan.md") == "Q3 plan.md" && decode("%E2%82%AC") == "\u{20AC}" && decode("%F0%9F%98%80") == "\u{1F600}", "decodes")
        check(decode("%zz") == nil && decode("%C3") == nil && decode("%ED%A0%80") == nil && decode("%C0%AF") == nil && decode("a%2") == nil,
              "a malformed escape, a cut sequence, a surrogate and an overlong form throw, as decodeURIComponent does")
        let words = { (label: String, name: String, target: String) in
            String(decoding: SessionReplyLinks.linkCardWords(u(label), u(name), u(target)), as: UTF16.self)
        }
        check(words("app.ts", "app.ts", "/Users/x/app.ts#L42") == "app.ts:42", "a file-name label keeps its line")
        check(words("the handler", "app.ts", "src/app.ts:42") == "the handler", "a prose label stays as written")
        check(words("/Users/x/plan.md", "plan.md", "/Users/x/plan.md") == "plan.md", "a path label becomes its base name")
        check(words("", "plan.md", "plan.md") == "plan.md", "an empty label reads as the name")
        check(words(String(repeating: "x", count: 130), "n", "n") == String(repeating: "x", count: 120), "a label is cut at 120 units")

        // ── A reply past the scan limit: scanned up to its last line break inside it, the rest shown as written.
        let filler = String(repeating: String(repeating: "word ", count: 15) + "\n", count: 1800)
        let longA = f("[early](a.md)\n" + filler + "[late](z.md)\n")
        check(longA.hasPrefix("early\nword ") && longA.hasSuffix("\n[late](z.md)\n"), "a link past the limit stays as written")
        let longB = f("Intro\n\n![x](x.png)\n\n" + filler + "![y](y.png)\n")
        check(longB.hasPrefix("Intro\n\nword ") && longB.hasSuffix("\n![y](y.png)\n"), "an image past the limit stays; one before it goes")
        let longC = String(repeating: "x", count: 128 * 1024 + 50) + "[a](b.md)"
        check(same(f(longC), longC), "no line break inside the limit: nothing is scanned")

        // ── The golden replies.
        guard CommandLine.arguments.count > 1, let data = FileManager.default.contents(atPath: CommandLine.arguments[1]),
              // JSONDecoder, not JSONSerialization: the latter drops a leading U+FEFF from a string value (0.5.380 first run).
              let golden = try? JSONDecoder().decode([[String]].self, from: data) else {
            preconditionFailure("pass Tests/fixtures/session-reply-links-golden.json")
        }
        check(golden.count >= 300, "the golden fixture holds 300 replies")
        for row in golden {
            let out = f(row[0])
            check(same(out, row[1]), "golden \(row[0].debugDescription) -> \(out.debugDescription), expected \(row[1].debugDescription)")
        }
        print("session reply links checks: \(checks) passed (\(cases.count) cases, \(golden.count) golden)")
    }
}
