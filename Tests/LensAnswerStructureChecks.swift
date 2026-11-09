import Foundation

// 0.5.380 (Miles 2026-11-08, server 7.0.5 parity): the Messages pane structures a COS answer's inline numbered lists before
// COSMarkdownView draws it (Sources/LensAnswerStructure.swift), executed. The cases are the web's
// (server/web-control/lens-answer-structure-web.test.ts); Tests/lens-answer-parity-pins.py fails when a web case is
// missing here or reads differently, and when the patterns drift from app.js. Compiled with LensAnswerStructure.swift
// alone by Tests/run-lens-answer.sh. Prints "lens answer checks: N passed".

/// The #455 answer as Miles's screenshot shows it (the dots are the screenshot's elisions, kept as text).
let T455 = "...What it unlocks for me: 1. Prep before each meeting: past decisions, open items, who's in the room. 2. Catching conflicts early, like ... 3. Checking road closures ... 4. Fitting tasks ... 5. Wrap-ups after each meeting... How your day should change: 1. Block one 90-minute deep-work stretch before 10 AM each day. 2. Settle each overlap the night before: go, delegate or decline. 3. Get a prep card ... 4. Keep the end of the day for wrap-up. I draft the follow-ups and you approve them. Want me to draft which of this week's overlaps to decline or delegate? I'd only draft the list. Nothing changes without your go."
let E455 = "...What it unlocks for me:\n\n1. Prep before each meeting: past decisions, open items, who's in the room.\n2. Catching conflicts early, like ...\n3. Checking road closures ...\n4. Fitting tasks ...\n5. Wrap-ups after each meeting...\n\nHow your day should change:\n\n1. Block one 90-minute deep-work stretch before 10 AM each day.\n2. Settle each overlap the night before: go, delegate or decline.\n3. Get a prep card ...\n4. Keep the end of the day for wrap-up. I draft the follow-ups and you approve them. Want me to draft which of this week's overlaps to decline or delegate? I'd only draft the list. Nothing changes without your go."

/// (input, expected). The parity pin reads this table between the CASES markers: one pair per line, plain literals.
let cases: [(String, String)] = [
    // CASES BEGIN
    ("Short version. Here is the plan: 1. Draft it. 2. Send it.", "Short version.\n\nHere is the plan:\n\n1. Draft it.\n2. Send it."),
    ("Two things matter. 1. Sleep. 2. Water.", "Two things matter.\n\n1. Sleep.\n2. Water."),
    ("- one\n- two. 1. a. 2. b.", "- one\n- two. 1. a. 2. b."),
    ("* one. 1. a. 2. b.", "* one. 1. a. 2. b."),
    ("Plan:\n1. Draft it. 2. Send it.", "Plan:\n1. Draft it. 2. Send it."),
    ("# Plan: 1. Draft it. 2. Send it.", "# Plan: 1. Draft it. 2. Send it."),
    ("Intro: 1. a. 2. b.\n\nSecond paragraph.", "Intro: 1. a. 2. b.\n\nSecond paragraph."),
    ("```\nx: 1. a. 2. b.\n```", "```\nx: 1. a. 2. b.\n```"),
    ("> quote: 1. a. 2. b.", "> quote: 1. a. 2. b."),
    ("| a | b |\nPlan: 1. a. 2. b.", "| a | b |\nPlan: 1. a. 2. b."),
    ("Use version 2. Then restart it.", "Use version 2. Then restart it."),
    ("Meet at 8:30. 2 people are coming.", "Meet at 8:30. 2 people are coming."),
    ("Block one 90-minute stretch before 10 AM. Then rest.", "Block one 90-minute stretch before 10 AM. Then rest."),
    ("We shipped release 1. 2 bugs came back.", "We shipped release 1. 2 bugs came back."),
    ("Next step: 1. only one item. Then we wait.", "Next step: 1. only one item. Then we wait."),
    ("Order: 1. first. 3. third. 4. fourth.", "Order: 1. first. 3. third. 4. fourth."),
    ("Order: 2. second. 3. third.", "Order: 2. second. 3. third."),
    ("Steps 1. a 2. b", "Steps 1. a 2. b"),
    ("Plan: 1. Ship version 2. 2. Tell Gina at 8:30. 3. Done.", "Plan:\n\n1. Ship version 2.\n2. Tell Gina at 8:30.\n3. Done."),
    ("Do: 1. a. 2. b. Also. 1. c. 2. d.", "Do:\n\n1. a.\n2. b. Also. 1. c. 2. d."),
    ("Do: 1. a. 2. Wrap-ups Next steps: 1. c. 2. d.", "Do:\n\n1. a.\n2. Wrap-ups Next steps:\n\n1. c.\n2. d."),
    ("Steps:\n1. Draft it.\nThen: 1. a. 2. b.", "Steps:\n1. Draft it.\nThen: 1. a. 2. b."),
    ("Run `a. 1. b. 2. c` now.", "Run `a. 1. b. 2. c` now."),
    ("Steps: 1. Run `x. 2. y` then. 2. Done.", "Steps:\n\n1. Run `x. 2. y` then.\n2. Done."),
    ("Read: 1. See https://example.com/a.b?x=1. 2. Reply.", "Read:\n\n1. See https://example.com/a.b?x=1.\n2. Reply."),
    ("", ""),
    ("Morning.\nToday: 1. a. 2. b.\nThat is all.", "Morning.\nToday:\n\n1. a.\n2. b.\n\nThat is all."),
    // 0.5.380 final QA W1 (server 7.0.7): a cut never enters code, bold or italic, never starts a block line.
    ("Note this. > 5 users said: 1. Fast. 2. Cheap.", "Note this. > 5 users said:\n\n1. Fast.\n2. Cheap."),
    ("Done. # of open items: 1. Deck. 2. Budget.", "Done. # of open items:\n\n1. Deck.\n2. Budget."),
    ("Done. - next: 1. a. 2. b.", "Done. - next:\n\n1. a.\n2. b."),
    ("Done. * next: 1. a. 2. b.", "Done. * next:\n\n1. a.\n2. b."),
    ("Done. + next: 1. a. 2. b.", "Done. + next:\n\n1. a.\n2. b."),
    ("Done. | next: 1. a. 2. b.", "Done. | next:\n\n1. a.\n2. b."),
    ("Done. [Miles]: 1. a. 2. b.", "Done. [Miles]:\n\n1. a.\n2. b."),
    ("Done. <details>: 1. a. 2. b.", "Done. <details>:\n\n1. a.\n2. b."),
    ("Done. 3) next: 1. a. 2. b.", "Done. 3) next:\n\n1. a.\n2. b."),
    ("Done. 2026 plan: 1. a. 2. b.", "Done.\n\n2026 plan:\n\n1. a.\n2. b."),
    ("Plan: 1. **Prep** the deck. 2. Ship it.", "Plan:\n\n1. **Prep** the deck.\n2. Ship it."),
    ("Plan: 1. Prep the *deck*. 2. Ship __it__.", "Plan:\n\n1. Prep the *deck*.\n2. Ship __it__."),
    ("2 * 3 is six. Plan: 1. a. 2. b * c.", "2 * 3 is six.\n\nPlan:\n\n1. a.\n2. b * c."),
    ("Set: 1. max_tokens to 5. 2. top_p to 1.", "Set:\n\n1. max_tokens to 5.\n2. top_p to 1."),
    ("Set: 1. max_tokens to 5. 2. Use COS_ as the prefix.", "Set:\n\n1. max_tokens to 5.\n2. Use COS_ as the prefix."),
    ("Plan: 1. a * b. 2. c*.", "Plan:\n\n1. a * b.\n2. c*."),
    ("Do: 1. # a. 2. b. Next: 1. c. 2. d.", "Do: 1. # a. 2. b.\n\nNext:\n\n1. c.\n2. d."),
    ("Read: 1. [Spec](https://a.co/s). 2. Reply.", "Read:\n\n1. [Spec](https://a.co/s).\n2. Reply."),
    ("**Steps: 1. Prep the deck. 2. Ship it.**", "**Steps: 1. Prep the deck. 2. Ship it.**"),
    ("__Steps: 1. Prep the deck. 2. Ship it.__", "__Steps: 1. Prep the deck. 2. Ship it.__"),
    ("*Steps: 1. Prep the deck. 2. Ship it.*", "*Steps: 1. Prep the deck. 2. Ship it.*"),
    ("_Steps: 1. Prep the deck. 2. Ship it._", "_Steps: 1. Prep the deck. 2. Ship it._"),
    ("Plan: 1. a**b. 2. c**d.", "Plan: 1. a**b. 2. c**d."),
    ("Plan: 1. a*b. 2. c*d.", "Plan: 1. a*b. 2. c*d."),
    ("Note `` x. Plan: 1. a. 2. b` y.", "Note `` x. Plan: 1. a. 2. b` y."),
    ("Plan: 1. # one. 2. b.", "Plan: 1. # one. 2. b."),
    ("Plan: 1. a. 2. > b.", "Plan: 1. a. 2. > b."),
    ("Plan: 1. [x] done. 2. [ ] open.", "Plan: 1. [x] done. 2. [ ] open."),
    ("Do: 1. # a. 2. b. Also. 1. c. 2. d.", "Do: 1. # a. 2. b. Also. 1. c. 2. d."),
    ("** Steps: 1. Prep the deck. 2. Ship it. **", "** Steps: 1. Prep the deck. 2. Ship it. **"),
    // CASES END
]

@main struct LensAnswerStructureChecks {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let f = LensAnswerStructure.structure
        // Only whitespace may change: the answer's other characters, in order, are exactly the original's.
        func ink(_ s: String) -> [UInt16] { s.utf16.filter { $0 != 0x20 && $0 != 0x09 && $0 != 0x0A } }
        func words(_ s: String) -> String {
            s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
        }

        // ── The #455 answer: two lists, each under its own lead-in line; the closing sentences stay with the last item.
        check(f(T455) == E455, "the #455 answer: \(f(T455).debugDescription)")
        check(ink(f(T455)) == ink(T455) && words(f(T455)) == words(T455), "the #455 answer: only whitespace changes")
        check(f(E455) == E455, "an answer already structured stays as it is")

        // ── The web's cases, each exactly.
        for (input, expected) in cases {
            let out = f(input)
            check(out == expected, "\(input.debugDescription) gave \(out.debugDescription), expected \(expected.debugDescription)")
            check(ink(out) == ink(input), "\(input.debugDescription): only whitespace changes")
        }
        // The label limit: a lead-in sentence longer than 100 characters is not split from the item before it.
        let long = String(repeating: "x", count: 120)
        check(f("Do: 1. a. 2. b. \(long): 1. c. 2. d.") == "Do:\n\n1. a.\n2. b. \(long):\n\n1. c.\n2. d.", "the label limit")
        check(LensAnswerStructure.labelMax == 100, "the label limit is the web's LA_LABEL_MAX")
        // A short one is.
        let short = String(repeating: "x", count: 90)
        check(f("Do: 1. a. 2. b. \(short): 1. c. 2. d.") == "Do:\n\n1. a.\n2. b.\n\n\(short):\n\n1. c.\n2. d.", "a short label leads the next list")
        // Unicode before a list keeps its UTF-16 positions (the cuts are UTF-16 offsets, as in JavaScript).
        check(f("Caf\u{E9} \u{1F600} plan: 1. a. 2. b.") == "Caf\u{E9} \u{1F600} plan:\n\n1. a.\n2. b.", "non-ASCII text before the list")
        check(f("Note.\r\nPlan: 1. a. 2. b.") == "Note.\r\nPlan:\n\n1. a.\n2. b.", "a CRLF line splits at its \\n, as the web's split does")

        // ── Fuzz: random answers keep every non-space character in order.
        var seed: UInt64 = 7
        func rnd() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }
        let toks = ["1.", "2.", "3.", "4.", "Plan:", "go.", "now?", "yes!", "at", "8:30.", "`x. 2.`", "https://a.co/b.", "word", "v2.", "\n", "  ", "-", "#"]
        for _ in 0..<2000 {
            let n = 3 + Int(rnd() * 30)
            var s = ""
            for _ in 0..<n { s += toks[min(toks.count - 1, Int(rnd() * Double(toks.count)))] + (rnd() < 0.8 ? " " : "") }
            let out = f(s)
            check(ink(out) == ink(s), "fuzz: \(s.debugDescription)")
            check(f(out) == out || out == s, "fuzz: a structured answer is stable: \(s.debugDescription)")
        }

        // ── 100 KB of answer text stays fast (the web's bound is 50 ms; a debug build gets more room).
        let copies = (100_000 + T455.utf16.count - 1) / T455.utf16.count
        let big = Array(repeating: T455, count: copies).joined(separator: " ")
        let bigLines = Array(repeating: T455, count: copies).joined(separator: "\n")
        let code = Array(repeating: "`a. 1.` x. 2. y", count: 20000).joined(separator: " ")
        for s in [big, bigLines, code] {
            let t0 = Date()
            let out = f(s)
            let ms = Date().timeIntervalSince(t0) * 1000
            check(s.utf16.count > 99_000 && ms < 500, "100 KB in \(Int(ms)) ms")
            check(ink(out) == ink(s), "100 KB: only whitespace changes")
        }
        check(f(bigLines).components(separatedBy: "\n1. Prep before each meeting").count - 1 == copies, "every line of a long answer is structured")

        print("lens answer checks: \(checks) passed")
    }
}
