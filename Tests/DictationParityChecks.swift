import CryptoKit
import Foundation

// 0.5.345 Wave A (plan r3, operations/personal/wk43_2026/PLAN_dictation_parity_2026-10-25.md), executed against the
// pure rules in Sources/MacDictationCore.swift alone (Tests/run-dictation-parity.sh): the filler strip and its shared
// fixture (F1, F1b), capitalizing a sentence's start (K2d), Undo polish (U1), "polish already fixed this" (E1), the AI
// polish picker's line (W2), the swap's wait for ⌘ or ⌃ (W3b-1), the audio breakers, the sound gate and the microphone
// fallback (A2), and the history's new optional fields. Nothing is drawn, clicked, posted, played or activated, and no
// device is opened. Every check names its behaviour, so Tests/mutate-dictation-parity.py attributes each kill.

@main struct DictationParityChecks {
    nonisolated(unsafe) static var ran = 0
    static func check(_ condition: Bool, _ behavior: String, _ detail: @autoclosure () -> String = "", line: UInt = #line) {
        ran += 1
        if !condition { fatalError("check failed [\(behavior)] at line \(line): \(detail())") }
    }
    static let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
    /// The canonical fixture's sha256, pinned here and in the server repo (server/lib/__fixtures__/dictation-fillers.json).
    static let fixtureSHA256 = "a531d0a99b4661dedcde5d81dbaa304eae73f916eb30e2efd7589e1e0a71de55"

    static func main() throws {
        try fillerFixture()
        fillerClient()
        casing()
        undoPolish()
        polishMatch()
        nextTime()
        picker()
        swapWait()
        audio()
        history()
        print("PASS dictation parity: \(ran) checks; fillers (fixture and gate), casing, Undo polish, polish already fixed this, the picker, the swap wait, audio breakers, sound gate, microphone fallback, history")
    }

    // MARK: A-W10 filler strip

    static func fillerFixture() throws {
        let url = root.appendingPathComponent("Tests/fixtures/dictation-fillers.json")
        let data = try Data(contentsOf: url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        check(hash == fixtureSHA256, "fillers fixture sha256", hash)
        let file = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let rows = file["rows"] as? [[String: Any]] ?? []
        let both = rows.filter { $0["scope"] as? String == "both" }
        check(file["schema"] as? Int == 1 && both.count >= 108 && both.contains { $0["group"] as? String == "language" }, "fillers fixture both", "\(both.count) rows")
        // The exemption rows, one behaviour each (so a mutant names which rule it broke).
        func row(_ id: String) -> (String, String) {
            let r = rows.first { $0["id"] as? String == id } ?? [:]
            return (r["input"] as? String ?? "", r["expected"] as? String ?? "")
        }
        for id in ["ex001", "ex002", "ex003", "ex004", "ex005", "ex006", "ex007", "ex008"] {
            let (i, e) = row(id); check(DictationFillers.strip(i) == e, "fillers touch before", id)
        }
        for id in ["ex009", "ex010", "ex011", "ex012", "ex013", "ex014", "ex015"] {
            let (i, e) = row(id); check(DictationFillers.strip(i) == e, "fillers touch after", id)
        }
        for id in ["ex017", "ex018"] {
            let (i, e) = row(id); check(DictationFillers.strip(i) == e, "fillers sentence end still strips", id)
        }
        var wrong: [String] = []
        for row in both {
            guard let input = row["input"] as? String, let expected = row["expected"] as? String else { continue }
            // The "language" rows hold through Control's whole step (its gate, then the token rules); the rest are the rules.
            let got = row["group"] as? String == "language" ? DictationFillers.clean(input, enabled: true).text : DictationFillers.strip(input)
            if got != expected { wrong.append("\(row["id"] ?? "?"): \(got.debugDescription)") }
        }
        // F1 (r3): the port matches the server function on every shared row, 100%.
        check(wrong.isEmpty, "fillers fixture both", wrong.prefix(5).joined(separator: "; "))
    }

    static func fillerClient() {
        let english: (String) -> [String: Double] = { _ in ["en": 0.97] }
        // F1b: exemption and non-English fixtures through the client's path (gate, then strip). Expected: unchanged.
        let kept: [(String, String)] = [
            ("open src/um.txt now", "path"), ("cd ~/uh and list it", "path"), ("ping @uh about the deck", "handle"),
            ("the tag #um is trending", "tag"), ("echo $um in the shell", "shell"), ("set the my_um field", "underscore"),
            ("run um.py again", "file"), ("open port um:8080 first", "port"), ("the um/bin folder", "path after"),
            ("mail um@example.com later", "address"), ("pass the -um flag", "flag"), ("Uh-oh, the build broke", "uh-oh"),
            ("We flew to Umbria in May", "Umbria"), ("uh huh, sounds good", "uh huh"), ("she said \"um\" twice", "quoted"),
        ]
        for (text, why) in kept { check(DictationFillers.clean(text, enabled: true, hypotheses: english).text == text, "fillers F1b exemption", why) }
        let foreign = [
            "um 5 Uhr", "Er kommt", "um carro", "Det er fint", "Er is een probleem", "Han er hjemme nu", "Wir treffen uns um 5 Uhr",
            "Comprei um carro novo", "Ela tem um gato", "um drei Uhr", "Ich komme um 9 Uhr", "Er hat um 8 Uhr angerufen",
            "Vamos sair um pouco", "Isso custa um real", "Er komt morgen", "Er ist heute nicht da", "Er kommt morgen.",
            "Ich komme um acht", "Tenho um", "Er hat recht", "Treffen um 5 Uhr morgen früh", "Er ist da", "ja um 5", "um ja", "Vamos um dia",
        ]
        for text in foreign { check(DictationFillers.clean(text, enabled: true).text == text, "fillers language gate", text) }
        check(kept.count + foreign.count >= 40, "fillers F1b exemption", "40 cases")
        // English goes through the real recognizer too.
        for (text, want) in [("I think, um, we should ship it today", "I think, we should ship it today"),
                             ("Um, can you send me the deck before Friday", "Can you send me the deck before Friday"),
                             ("uh yes", "yes"), ("Uh, send it", "Send it"), ("um ok", "ok")] {
            check(DictationFillers.clean(text, enabled: true).text == want, "fillers english strips", text)
        }
        // The gate's two rules, on fixed guesses (the recognizer's numbers never decide a check's verdict here).
        check(!DictationFillers.englishEnough("um I think we should go", hypotheses: { _ in ["en": 0.7, "de": 0.3] }), "fillers long text needs 0.8")
        check(DictationFillers.englishEnough("um I think we should go", hypotheses: { _ in ["en": 0.8] }), "fillers long text needs 0.8")
        check(!DictationFillers.englishEnough("um I think we should go", hypotheses: { _ in ["de": 0.9] }), "fillers long text needs 0.8")
        check(!DictationFillers.englishEnough("um kommt so", hypotheses: { _ in ["de": 0.61, "en": 0.27] }), "fillers short text signal")
        check(DictationFillers.englishEnough("um Dana", hypotheses: { _ in ["hr": 0.34] }), "fillers short text signal")
        check(!DictationFillers.englishEnough("um café", hypotheses: { _ in ["en": 0.9] }), "fillers short text non-ascii")
        check(!DictationFillers.englishEnough("um uh", hypotheses: { _ in ["en": 0.9] }), "fillers nothing but fillers")
        // A common short reply is English evidence (6.92.0 server QA): "hi" reads Catalan and "fine" Italian to the recognizer.
        check(DictationFillers.englishEnough("um hi", hypotheses: { _ in ["ca": 0.8] }) && DictationFillers.englishEnough("er fine", hypotheses: { _ in ["it": 0.4] })
              && !DictationFillers.englishEnough("um ja", hypotheses: { _ in ["fi": 0.59] }), "fillers short replies")
        for (text, want) in [("um yes", "yes"), ("um no", "no"), ("er no", "no"), ("um okay", "okay"), ("um thanks Dana", "thanks Dana"), ("Um, hi", "Hi")] {
            check(DictationFillers.clean(text, enabled: true).text == want, "fillers short replies", text)
        }
        // Off, nothing to strip, and the removed flag (the record keeps rawHeard only when it changed).
        let off = DictationFillers.clean("We need uh the deck", enabled: false, hypotheses: english)
        check(off.text == "We need uh the deck" && !off.removed, "fillers off")
        let on = DictationFillers.clean("We need uh the deck", enabled: true, hypotheses: english)
        check(on.text == "We need the deck" && on.removed, "fillers removed flag")
        check(!DictationFillers.clean("We need the deck", enabled: true, hypotheses: english).removed, "fillers removed flag")
        check(DictationFillers.stored(nil) && !DictationFillers.stored(false) && DictationFillers.defaultsKey == "dictation.removeFillers", "fillers default on")
        // A-W11's chip rule reads the same token set.
        check(["um", "Uhh", "erm", "hmm", "mhm", "ahh"].allSatisfy(DictationFillers.isBuiltIn) && !DictationFillers.isBuiltIn("honestly")
              && !DictationFillers.isBuiltIn("um uh") && !DictationFillers.isBuiltIn("umbrella"), "fillers built-in tokens")
    }

    // MARK: A-W9a capitalize the start (K2d)

    static func casing() {
        typealias K = DictationCasing
        let start = K.Before(text: "", reachesStart: true)
        func at(_ s: String) -> K.Before { K.Before(text: s, reachesStart: false) }
        let terms: Set<String> = ["bottlepos", "jewel360x"]
        func cap(_ text: String, _ before: K.Before?, terminal: Bool = false, secure: Bool = false, instructions: String = "") -> String? {
            K.apply(text, before: before, terminal: terminal, secure: secure, instructions: instructions, isTerm: { terms.contains($0) })
        }
        let rows: [(String, String, K.Before?, String?)] = [
            ("field start", "hello there", start, "Hello there"),
            ("empty field", "send it now", K.Before(text: "", reachesStart: true), "Send it now"),
            ("after a period", "next one", at("done. "), "Next one"),
            ("after a bang", "next one", at("great! "), "Next one"),
            ("after a question", "next one", at("ready? "), "Next one"),
            ("after a line break", "next one", at("first line\n"), "Next one"),
            ("period inside a quote", "next one", at("he said \"done.\" "), "Next one"),
            ("i alone", "i think so", start, "I think so"),
            ("open quote", "\"hello\" she said", start, "\"Hello\" she said"),
            ("open paren", "(maybe) later", start, "(Maybe) later"),
            ("latin accent", "élan vital", start, "Élan vital"),
        ]
        for (why, text, before, want) in rows { check(cap(text, before) == want, "casing applies", why) }
        let kept: [(String, String, K.Before?, String)] = [
            ("mid sentence", "next one", at("and then "), "casing mid sentence"),
            ("unread field", "next one", nil, "casing needs a read"),
            ("not the field start", "next one", K.Before(text: "   ", reachesStart: false), "casing needs a read"),
            ("e.g.", "the deck", at("things, e.g. "), "casing abbreviation"),
            ("Dr.", "smith said", at("ask Dr. "), "casing abbreviation"),
            ("p.m.", "works", at("at 5 p.m. "), "casing abbreviation"),
            ("an initial", "smith", at("ask J. "), "casing initial"),
            ("ellipsis", "maybe", at("well... "), "casing ellipsis"),
            ("ellipsis glyph", "maybe", at("well… "), "casing ellipsis"),
            ("iPhone", "iPhone is ready", start, "casing inner capital"),
            ("eBay", "eBay listing is up", start, "casing inner capital"),
            ("handle", "@dana can you look", start, "casing mark"),
            ("path", "/pricing is live", start, "casing mark"),
            ("domain", "gotcos.com is live", start, "casing mark"),
            ("snake", "my_var is set", start, "casing mark"),
            ("colon", "re: the deck", start, "casing mark"),
            ("flag", "-v is the flag", start, "casing applies"),
            ("tag", "#general is quiet", start, "casing applies"),
            ("command", "npm run build", start, "casing command"),
            ("git", "git push it", start, "casing command"),
            ("dictionary term", "bottlepos is live", start, "casing term"),
            ("terminal", "next one", start, "casing terminal"),
            ("secure", "next one", start, "casing secure"),
            ("lowercase instructions", "next one", start, "casing lowercase asked"),
            ("already capital", "Hello", start, "casing applies"),
            ("a digit", "5 is fine", start, "casing applies"),
            ("cyrillic", "привет всем", start, "casing script"),
        ]
        for (why, text, before, behavior) in kept {
            let got = cap(text, before, terminal: why == "terminal", secure: why == "secure",
                          instructions: why == "lowercase instructions" ? "Write everything in all lowercase." : "")
            check(got == nil, behavior, why + " " + (got ?? ""))
        }
        check(rows.count + kept.count >= 35, "casing applies", "K2d has 35 cases")
        check(K.lowercaseAsked("please use lower case") && K.lowercaseAsked("No capitals.") && !K.lowercaseAsked("Use Oxford commas"), "casing lowercase asked")
        check(K.stored(nil) && !K.stored(false), "casing default on")
        // Kept out of Your style: the classifier compares lowercased words, so a casing change is never a style edit.
        check(DictationStyleClassifier.observations(typed: "Next one please", final: "next one please", allowlist: DictationStyle.defaultAllowlist, instructions: "").isEmpty,
              "casing not style evidence")
    }

    // MARK: A-W7 Undo polish (U1)

    static func undoPolish() {
        typealias U = DictationUndoPolish
        let id = UUID(), at = Date(timeIntervalSince1970: 1_792_900_000)
        let swapped = DictationRecord(id: id, text: "We need the deck by Friday.", createdAt: at, delivery: .inserted(app: "Notes"),
                                      heard: "we need uh the deck by friday", polishModel: "sonnet", polishPrompt: "v4",
                                      typed: "We need the deck by friday")
        check(U.restoreText(swapped) == "We need the deck by friday", "undo restores typed")
        let noTyped = DictationRecord(id: id, text: "Polished.", createdAt: at, delivery: .inserted(app: "Notes"), heard: "polished", polishModel: "haiku")
        check(U.restoreText(noTyped) == "polished", "undo restores heard without typed")
        let plain = DictationRecord(id: id, text: "plain", createdAt: at, delivery: .inserted(app: "Notes"))
        check(U.restoreText(plain) == nil, "undo only after polish")
        check(U.actions(swapped: true, tracked: true, pendingApplies: false, record: swapped) == [.undoPolish, .showOriginal], "undo card states")
        check(U.actions(swapped: false, tracked: true, pendingApplies: true, record: plain) == [.applyPolished, .showOriginal], "undo card states")
        check(U.actions(swapped: true, tracked: false, pendingApplies: false, record: swapped) == [.showOriginal], "undo needs the span")
        let back = U.unpolished(swapped)
        check(back?.text == "We need the deck by friday" && back?.heard == nil && back?.polishModel == nil && back?.polishPrompt == nil
              && back?.rawHeard == "we need uh the deck by friday" && back?.id == id && back?.createdAt == at, "undo record")
        check(back?.heardShown == "we need uh the deck by friday", "undo record")
        check(DictationHistory.unpolishing(id, in: [swapped, plain]).first?.text == "We need the deck by friday", "undo record")
        // The fake field: exactly the span replaced, a moved span refused.
        let span = DictationInsertedSpan(pid: 7, location: 6, length: swapped.text.utf16.count)
        let field = "Note: " + swapped.text + " ok"
        let exact = DictationReplace.plan(span: span, terminal: false, appRunning: true, fieldCharacters: field.utf16.count, window: field, windowStart: 0,
                                          current: swapped.text, corrected: U.restoreText(swapped)!)
        check(U.placed(exact, span: span) == nil, "undo exact span")
        if case .edit(let edit, _) = exact {
            let ns = field as NSString
            let result = ns.replacingCharacters(in: NSRange(location: edit.location, length: edit.length), with: edit.replacement)
            check(result == "Note: We need the deck by friday ok", "undo exact span", result)
        } else { check(false, "undo exact span") }
        let movedField = "More text. Note: " + swapped.text + " ok"
        let moved = DictationReplace.plan(span: span, terminal: false, appRunning: true, fieldCharacters: movedField.utf16.count, window: movedField,
                                          windowStart: 0, current: swapped.text, corrected: U.restoreText(swapped)!)
        check(U.placed(moved, span: span) == .textMoved, "undo moved span refuses")
        let edited = "Note: We need the slides by Friday. ok"
        let partial = DictationReplace.plan(span: span, terminal: false, appRunning: true, fieldCharacters: edited.utf16.count, window: edited,
                                            windowStart: 0, current: swapped.text, corrected: U.restoreText(swapped)!)
        check(U.placed(partial, span: span) != nil, "undo moved span refuses")
        check(U.placed(.copy(.appGone), span: span) == .appGone && U.refusedNote(.appGone, app: "Notes").contains("Notes"), "undo moved span refuses")
        check(U.label == "Undo polish" && !U.refusedNote(.textMoved, app: "Notes").contains("Copied"), "undo label")
    }

    // MARK: A-W11 polish already fixed this (E1)

    static func polishMatch() {
        typealias M = DictationPolishMatch
        let typed = "uh so we need the deck by friday"
        let polished = "So we need the deck by Friday."
        check(M.subset(typed: typed, final: "so we need the deck by friday", polished: polished), "match subset")
        check(M.subset(typed: typed, final: "So we need the deck by Friday.", polished: polished), "match subset")
        check(!M.subset(typed: typed, final: "so we need the slides by friday", polished: polished), "match superset is not")
        check(!M.subset(typed: typed, final: "uh so we need the slides by friday", polished: polished), "match different is not")
        check(!M.subset(typed: typed, final: typed, polished: polished), "match no change is not")
        check(!M.subset(typed: "we need it", final: "we really need it", polished: "We need it."), "match different is not")
        check(M.subset(typed: "we need uh the deck", final: "we need the deck", polished: "We need the whole deck."), "match subset")
        check(!M.subset(typed: "we need it", final: "we need it now", polished: "We need it today."), "match insert words differ")
        check(!M.subset(typed: "we really need it", final: "we need it", polished: "We really need it."), "match deletion not made by polish")
        // The style baseline: only what the person did beyond polish is evidence.
        let base = M.baseline(typed: "honestly we need the deck do not wait", final: "we need the deck don't wait", polished: "We need the deck, do not wait.")
        check(base == "we need the deck do not wait", "match style baseline", base ?? "nil")
        // From the pending baseline, polish's own removal of "honestly" is not the person's; "don't" is.
        let found = DictationStyleClassifier.observations(typed: base ?? "", final: "we need the deck don't wait", allowlist: DictationStyle.defaultAllowlist, instructions: "")
        check(found.map(\.key) == [DictationStyle.Key(kind: .contractions, param: "use")], "match style baseline", "\(found.map(\.key))")
        // A polish removal the person never saw is never read as the person putting the word back.
        let unseen = M.baseline(typed: "honestly we need it", final: "honestly we need it now", polished: "We need it.")
        let fromUnseen = DictationStyleClassifier.observations(typed: unseen ?? "", final: "honestly we need it now", allowlist: DictationStyle.defaultAllowlist, instructions: "")
        check(unseen == "honestly we need it" && !fromUnseen.contains { $0.added }, "match style baseline")
        check(DictationNextTime.polishLine.hasPrefix("Polish had already fixed this.") && !DictationNextTime.polishLine.contains("key"), "match note")
    }

    // MARK: A-W12 the card's next-time lines (Miles 19:01)

    static func nextTime() {
        typealias N = DictationNextTime
        func parts(_ a: String, _ b: String) -> [DictationWordDiff.Part]? { DictationWordDiff.diff(original: a, final: b) }
        // A dictionary word learned.
        let learned = N.lines(parts: parts("ask joule 360", "ask Jewel360"), learned: ["Jewel360"], matchedPolish: false, styles: [], fillersOn: true)
        check(learned.lines == ["Next time COS writes Jewel360."] && learned.more == 0, "next learned", "\(learned)")
        check(N.didLine(parts: parts("ask joule 360", "ask Jewel360"), learned: ["Jewel360"]) == "Added Jewel360 to your dictionary.", "next learned")
        // Polish already fixed it, with up to three changes in short form; more than three gets the plain line.
        let fixed = N.lines(parts: parts("so I clicked the button", "so I click to button"), learned: [], matchedPolish: true, styles: [], fillersOn: true)
        check(fixed.lines == ["Polish had already fixed this (clicked the to click to). Its version couldn't swap in in time."], "next polish had it", "\(fixed)")
        let many = N.lines(parts: parts("a b c d e f g h", "a x c y e z g w"), learned: [], matchedPolish: true, styles: [], fillersOn: true)
        check(many.lines == [N.polishLine], "next polish had it", "\(many)")
        // Your style counted: one of two, then active.
        let seen = N.lines(parts: parts("I do not know", "I don't know"), learned: [], matchedPolish: false,
                           styles: [.init(title: "Use contractions", support: 1, active: false)], fillersOn: true)
        check(seen.lines == ["Style: seen 1 of 2. One more and COS will use contractions."], "next style counted", "\(seen)")
        let active = N.lines(parts: parts("I do not know", "I don't know"), learned: [], matchedPolish: false,
                             styles: [.init(title: "Use contractions", support: 2, active: true)], fillersOn: true)
        check(active.lines == ["Style rule now active: use contractions."], "next style active", "\(active)")
        // A built-in filler the person took out: only while the filler setting is on, and never as well as "polish had it".
        let filler = N.lines(parts: parts("so um we go", "so we go"), learned: [], matchedPolish: false, styles: [], fillersOn: true)
        check(filler.lines == [N.fillerLine], "next filler note", "\(filler)")
        check(N.lines(parts: parts("so um we go", "so we go"), learned: [], matchedPolish: false, styles: [], fillersOn: false).lines == [N.nothingLine], "next filler note")
        check(!N.lines(parts: parts("so um we go", "so we go"), learned: [], matchedPolish: true, styles: [], fillersOn: true).lines.contains(N.fillerLine), "next filler note")
        check(!N.fillerOnly(DictationWordDiff.Region(removed: "honestly", added: "", removedWords: 1, addedWords: 0)), "next filler note")
        // Nothing learnable: the one line, and the did-line drops the old bare tail.
        let once = N.lines(parts: parts("send the deck today", "send the slides today"), learned: [], matchedPolish: false, styles: [], fillersOn: true)
        check(once.lines == [N.nothingLine], "next nothing to learn", "\(once)")
        let did = N.didLine(parts: parts("send the deck today", "send the slides today"), learned: [])
        check(did == "You changed \"deck\" to \"slides\"." && !did.contains(DictationEditConfirm.nothingNew), "next nothing to learn", did)
        // At most three lines, the rest "+N more", in order: learned, polish, style, filler.
        let crowd = N.lines(parts: parts("a", "b"), learned: ["One", "Two"], matchedPolish: true,
                            styles: [.init(title: "Use contractions", support: 1, active: false), .init(title: "Drop “honestly”", support: 2, active: true)],
                            fillersOn: true)
        check(crowd.lines.count == 3 && crowd.more == 2 && crowd.lines[0] == "Next time COS writes One." && crowd.lines[2].hasPrefix("Polish had already"),
              "next at most three", "\(crowd)")
        check(N.moreLabel(2) == "+2 more", "next at most three")
        check(N.lines(parts: parts("a", "b"), learned: ["One", "Two"], matchedPolish: true, styles: [], fillersOn: true, limit: .max).more == 0, "next at most three")
        // The copy: no em dash, no arrow, "to" between before and after.
        for line in crowd.lines + [N.polishLine, N.fillerLine, N.nothingLine, N.styleLine(.init(title: "x", support: 0, active: false)), fixed.lines[0]] {
            check(!line.contains("\u{2014}") && !line.contains("\u{2192}") && !line.contains("->"), "next copy", line)
        }
        // The edit keeps its counted rules both ways, and an older edit reads with none.
        let edit = DictationUserEdit(text: "x", app: "Notes", at: Date(timeIntervalSince1970: 0), edits: 1, styleKeys: ["contractions-use"])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let back = (try? encoder.encode(edit)).flatMap { try? decoder.decode(DictationUserEdit.self, from: $0) }
        check(back?.styleKeys == ["contractions-use"] && back?.matchedPolish == false, "next edit keeps rules")
        let old = try? decoder.decode(DictationUserEdit.self, from: Data(#"{"text":"x","app":"Notes","at":"1970-01-01T00:00:00Z","edits":1}"#.utf8))
        check(old?.styleKeys == [] && old?.matchedPolish == false, "next edit keeps rules")
    }

    // MARK: A-W2 the picker (W2)

    static func picker() {
        typealias P = DictationPolishPicker
        let v4: [String: String] = ["haiku": "v3", "sonnet": "v4", "luna-5.6-fast": "v3"]
        let def = P.Server(available: true, promptVersion: "default", effectiveByModel: v4, meaningGuard: true, stylePairs: ["sonnet": "v4"])
        check(P.line(model: .sonnet, server: def, fillers: true, styleRules: 0) == P.newest, "picker sonnet v4 guard on")
        check(P.line(model: .sonnet, server: def, fillers: true, styleRules: 2) == P.newest + " Applies your 2 style rules.", "picker style suffix")
        check(P.line(model: .sonnet, server: def, fillers: true, styleRules: 1) == P.newest + " Applies your 1 style rule.", "picker style suffix")
        var noGuard = def; noGuard.meaningGuard = false
        check(P.line(model: .sonnet, server: noGuard, fillers: true, styleRules: 0) == P.newestNoGuard, "picker sonnet v4 guard off")
        var legacy = def; legacy.meaningGuard = nil; legacy.stylePairs = nil
        check(P.line(model: .sonnet, server: legacy, fillers: true, styleRules: 0) == P.newest, "picker 6.91 guard default on")
        var haikuV4 = def; haikuV4.effectiveByModel["haiku"] = "v4"; haikuV4.stylePairs = ["sonnet": "v4"]
        check(P.line(model: .haiku, server: haikuV4, fillers: true, styleRules: 3) == P.otherModelNewest, "picker haiku v4")
        let previous = P.Server(available: true, promptVersion: "v3", effectiveByModel: ["haiku": "v3", "sonnet": "v3"], meaningGuard: true, stylePairs: [:])
        check(P.line(model: .sonnet, server: previous, fillers: true, styleRules: 2) == P.previous, "picker previous polish")
        check(P.line(model: .haiku, server: def, fillers: true, styleRules: 0) == P.earlier, "picker haiku v3")
        var envV3 = def; envV3.effectiveByModel["sonnet"] = "v3"; envV3.envOverride = true; envV3.stylePairs = [:]
        check(P.line(model: .sonnet, server: envV3, fillers: true, styleRules: 0) == P.earlierSonnet, "picker sonnet v3 by the server")
        check(P.line(model: .sonnet, server: P.Server(), fillers: true, styleRules: 0) == nil, "picker 6.90 no options")
        check(P.line(model: .off, server: P.Server(), fillers: true, styleRules: 0) == "Pastes what was heard, without um and uh.", "picker off fillers")
        check(P.line(model: .off, server: def, fillers: false, styleRules: 0) == "Pastes what was heard.", "picker off fillers")
        // The lint: no speed words, no em dash or arrow, at most 400 characters with the glasses note.
        let speed = ["fast", "faster", "quick", "instant", "speed", "seconds", "slow"]
        for model in DictationPolishModel.allCases {
            for server in [def, noGuard, legacy, haikuV4, previous, envV3, P.Server()] {
                for rules in [0, 1, 20] {
                    guard let text = P.text(model: model, server: server, fillers: true, styleRules: rules) else { continue }
                    check(text.count <= P.maximumCharacters, "picker lint", "\(text.count) characters")
                    check(!text.contains("\u{2014}") && !text.contains("\u{2192}") && !text.contains("->"), "picker lint", text)
                    let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
                    check(speed.allSatisfy { !words.contains($0) }, "picker lint", text)
                }
            }
        }
        check(P.text(model: .haiku, server: def, fillers: true, styleRules: 0)?.hasSuffix(P.glasses) == true, "picker glasses note")
        // A changed server version or generation always reloads the options; otherwise only the cache's own reasons.
        check(P.reloads(versionChanged: true, needsReload: false, enabledDiffers: false) && !P.reloads(versionChanged: false, needsReload: false, enabledDiffers: false)
              && P.reloads(versionChanged: false, needsReload: true, enabledDiffers: false) && P.reloads(versionChanged: false, needsReload: false, enabledDiffers: true),
              "picker reload on change")
        // The Settings note is the paste-first one now, and keeps its pinned disclosures.
        let note = DictationPolish.settingNote(.sonnet, pasteFirst: true)
        check(note.hasPrefix("COS types what it heard right away, then swaps in Claude's version if you haven't moved on.")
              && note.contains("Uses your Claude plan") && note.contains("does not reliably fix misheard words") && note.contains("longer than 9 seconds"),
              "picker setting note paste first", note)
        check(DictationPolish.settingNote(.sonnet, pasteFirst: false) == DictationPolish.settingNote(.sonnet), "picker setting note polish first")
    }

    // MARK: A-W3b the swap's wait (W3b-1)

    static func swapWait() {
        typealias W = DictationSwapWait
        check(W.held { [55].contains($0) } == [.cmd] && W.held { [62].contains($0) } == [.ctrl] && W.held { [56, 58].contains($0) } == [.shift, .opt],
              "wait key classes")
        check(W.code([.ctrl, .cmd]) == "cmd+ctrl" && W.code([]) == nil, "wait key classes")
        check(W.step(held: [.shift], enabled: true, everHeld: true, waitedMs: 0, sinceKeyDownMs: 5_000, releasedAtMs: nil) == .skip(.keysHeld), "wait shift skips")
        check(W.step(held: [.opt, .cmd], enabled: true, everHeld: true, waitedMs: 0, sinceKeyDownMs: 5_000, releasedAtMs: nil) == .skip(.keysHeld), "wait shift skips")
        check(W.step(held: [.cmd], enabled: true, everHeld: true, waitedMs: 600, sinceKeyDownMs: 5_000, releasedAtMs: nil) == .wait, "wait cmd waits")
        check(W.step(held: [.ctrl], enabled: true, everHeld: true, waitedMs: 1_200, sinceKeyDownMs: 5_000, releasedAtMs: nil) == .skip(.keysHeld), "wait cmd bound")
        check(W.step(held: [.cmd], enabled: false, everHeld: true, waitedMs: 0, sinceKeyDownMs: 5_000, releasedAtMs: nil) == .skip(.keysHeld), "wait toggle off")
        check(W.step(held: [], enabled: true, everHeld: false, waitedMs: 0, sinceKeyDownMs: 0, releasedAtMs: nil) == .go, "wait nothing held goes")
        check(W.step(held: [], enabled: true, everHeld: true, waitedMs: 700, sinceKeyDownMs: 100, releasedAtMs: 650) == .wait, "wait quiet after release")
        check(W.step(held: [], enabled: true, everHeld: true, waitedMs: 1_000, sinceKeyDownMs: 300, releasedAtMs: 650) == .go, "wait quiet after release")
        check(W.step(held: [], enabled: true, everHeld: true, waitedMs: 1_900, sinceKeyDownMs: 50, releasedAtMs: 650) == .skip(.typing), "wait quiet bound")
        // The pure decision driven like the store drives it: a fake keyboard, a fake frontmost app, a fake clipboard.
        struct Fake { var downUntil: Int; var lastKeyDown: Int; var frontmost: Int32; var changeCount: Int }
        func drive(_ fake: Fake, frontmostAt: (Int) -> Int32, target: Int32 = 42) -> (posted: Bool, waited: Int) {
            var waited = 0, everHeld = false, released: Int?
            while true {
                let keys: Set<W.Key> = waited < fake.downUntil ? [.cmd] : []
                if !keys.isEmpty { everHeld = true } else if everHeld, released == nil { released = waited }
                let since = waited - max(fake.lastKeyDown, fake.downUntil)
                switch W.step(held: keys, enabled: true, everHeld: everHeld, waitedMs: waited, sinceKeyDownMs: since, releasedAtMs: released) {
                case .go:
                    // Re-gate after the wait: the frontmost app must still be the target, or nothing is posted.
                    let gate = DictationPolishSwap.gate(route: .paste, frontmost: frontmostAt(waited) == target, focusedIsTarget: true, ownWindowKey: false)
                    return (gate == nil, waited)
                case .skip: return (false, waited)
                case .wait: waited += W.pollMilliseconds
                }
            }
        }
        let released = drive(Fake(downUntil: 500, lastKeyDown: 0, frontmost: 42, changeCount: 1), frontmostAt: { _ in 42 })
        check(released.posted && released.waited >= 800 && released.waited < W.releaseMilliseconds + W.quietMilliseconds, "wait cmd released then pastes", "\(released)")
        let switched = drive(Fake(downUntil: 500, lastKeyDown: 0, frontmost: 42, changeCount: 1), frontmostAt: { $0 > 300 ? 77 : 42 })
        check(!switched.posted, "wait frontmost change posts nothing")
        let stuck = drive(Fake(downUntil: 5_000, lastKeyDown: 0, frontmost: 42, changeCount: 1), frontmostAt: { _ in 42 })
        check(!stuck.posted && stuck.waited == W.releaseMilliseconds, "wait cmd bound")
        // A newer clipboard is never written over, on every paste path.
        check(DictationClipboard.restoresOver(setChangeCount: 5, currentChangeCount: 5) && !DictationClipboard.restoresOver(setChangeCount: 5, currentChangeCount: 6),
              "wait newer clipboard kept")
        check(DictationPolishSwap.deliveryWaitMilliseconds == 4_000 && DictationPolishSwap.deliveryWaitMilliseconds >= 600 + W.releaseMilliseconds + W.quietMilliseconds + 1_400,
              "wait delivery cap covers the swap")
        check(W.stored(nil) && !W.stored(false), "wait default on")
    }

    // MARK: A-W1 audio (A2)

    static func audio() {
        var breaker = DictationAudioBreaker()
        check(!breaker.open(now: 0), "audio breaker closed")
        breaker.record(status: 0, now: 0)
        check(!breaker.open(now: 1), "audio breaker error status only")
        breaker.record(status: 2_003_329_396, now: 100)
        check(breaker.open(now: 100) && breaker.open(now: 699) && !breaker.open(now: 700.5), "audio breaker ten minutes")
        breaker.reset()
        check(!breaker.open(now: 101), "audio breaker reset")
        check(DictationAudioBreaker.pauseSeconds == 600, "audio breaker ten minutes")
        // The sound queue's drop rules: a sound never waits.
        typealias G = DictationSoundGate
        check(G.enqueue(outstanding: true, breakerOpen: false) == .dropBusy, "sound drop while starting")
        check(G.enqueue(outstanding: false, breakerOpen: false) == .play, "sound plays")
        check(G.enqueue(outstanding: false, breakerOpen: true) == .dropBreaker && G.dequeue(askedAt: 0, now: 0.1, breakerOpen: true) == .dropBreaker, "sound breaker")
        check(G.dequeue(askedAt: 10, now: 10.31, breakerOpen: false) == .dropLate && G.dequeue(askedAt: 10, now: 10.29, breakerOpen: false) == .play, "sound drop late")
        check(!DictationAudioCopy.isPermission(status: 2_003_329_396) && DictationAudioCopy.deviceNotResponding.contains("didn't respond"), "audio what is not permission")
        // The microphone fallback.
        typealias F = DictationMicFallback
        check(F.fourCC(0x626C_746E) == "bltn" && F.fourCC(0x7573_6220) == "usb " && F.fourCC(0x6363_7764) == "ccwd" && F.fourCC(0) == "", "fallback transport codes")
        let builtIn = F.Device(uid: "BuiltInMic", name: "MacBook Pro Microphone", transport: "bltn")
        let at2020 = F.Device(uid: "AT2020", name: "AT2020USB+", transport: "usb ")
        let camLink = F.Device(uid: "CamLink", name: "Cam Link 4K", transport: "usb ")
        let duo = F.Device(uid: "Duo", name: "Duo Microphone", transport: "ccwd")
        let airpods = F.Device(uid: "AirPods", name: "AirPods", transport: "blue")
        let teams = F.Device(uid: "Teams", name: "Microsoft Teams Audio", transport: "virt")
        let agg = F.Device(uid: "Agg", name: "Aggregate", transport: "grup")
        let devices = [builtIn, at2020, camLink, duo, airpods, teams, agg]
        check([duo, airpods, teams, agg, F.Device(uid: "X", name: "X", transport: "ccwl"), F.Device(uid: "Y", name: "Y", transport: "")].allSatisfy { !F.eligible($0) }
              && F.eligible(builtIn) && F.eligible(at2020), "fallback exclusions")
        let everyone = ["Duo", "AirPods", "Teams", "Agg", "AT2020", "BuiltInMic"]
        check(F.candidates(good: everyone, devices: devices, failedUID: nil, lidClosed: false).map(\.uid) == ["AT2020", "BuiltInMic"], "fallback exclusions")
        check(F.candidates(good: ["AT2020", "BuiltInMic"], devices: devices, failedUID: "AT2020", lidClosed: false).map(\.uid) == ["BuiltInMic"], "fallback never the failed device")
        check(F.candidates(good: ["BuiltInMic", "AT2020"], devices: devices, failedUID: nil, lidClosed: true).map(\.uid) == ["AT2020"], "fallback lid closed")
        // Two USB inputs, one silent (a Cam Link that never delivered sound): only the one that did is a candidate.
        var good: [String] = []
        good = F.remembering(camLink, nonSilent: F.nonSilent(dBFS: -90), in: good)
        good = F.remembering(at2020, nonSilent: F.nonSilent(dBFS: -42), in: good)
        check(good == ["AT2020"], "fallback non-silent memory")
        check(F.candidates(good: good, devices: devices, failedUID: "BuiltInMic", lidClosed: false).map(\.uid) == ["AT2020"], "fallback two usb one silent")
        check(F.remembering(airpods, nonSilent: true, in: good) == good && F.remembering(duo, nonSilent: true, in: good) == good, "fallback no bluetooth memory")
        check(F.remembering(builtIn, nonSilent: true, in: good) == ["BuiltInMic", "AT2020"], "fallback most recent first")
        var many: [String] = []
        for k in 0..<12 { many = F.remembering(F.Device(uid: "U\(k)", name: "U", transport: "usb "), nonSilent: true, in: many) }
        check(many.count == F.maximumGood && many.first == "U11", "fallback most recent first")
        check(F.candidates(good: ["Gone"], devices: devices, failedUID: nil, lidClosed: false).isEmpty, "fallback absent device")
        check(!F.nonSilent(dBFS: nil) && !F.nonSilent(dBFS: -70) && F.nonSilent(dBFS: -69.9), "fallback non-silent memory")
        check(F.triggers(engineStartThrew: true, firstAudio: nil) && F.triggers(engineStartThrew: false, firstAudio: .failed)
              && !F.triggers(engineStartThrew: false, firstAudio: .timedOut) && !F.triggers(engineStartThrew: false, firstAudio: .arrived(1)), "fallback triggers")
        check(F.mayRetry(firstAttemptMs: 639) && !F.mayRetry(firstAttemptMs: 5_100) && F.maximumWaitMilliseconds == 3_000, "fallback retry bound")
        check(F.usedMessage(failed: "Studio Display", used: "AT2020USB+") == "macOS couldn't start Studio Display, so COS used AT2020USB+.", "fallback messages")
        check(F.stuckMessage(continuityPresent: true).contains("Continuity Camera") && !F.stuckMessage(continuityPresent: false).contains("Continuity")
              && !F.stuckMessage(continuityPresent: false).contains("2003329396"), "fallback messages")
        check(F.stored(nil) && !F.stored(false), "fallback default on")
    }

    // MARK: history: the new fields are optional both ways

    static func history() {
        let id = UUID(), at = Date(timeIntervalSince1970: 1_792_900_000)
        let record = DictationRecord(id: id, text: "We need the deck.", createdAt: at, delivery: .inserted(app: "Notes"), heard: "we need uh the deck",
                                     polishModel: "sonnet", typed: "We need the deck", rawHeard: nil)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = (try? encoder.encode(record)) ?? Data()
        let back = try? decoder.decode(DictationRecord.self, from: data)
        check(back == record && back?.typed == "We need the deck", "history round trip")
        // A 0.5.344 record (no typed, no rawHeard) reads, and a wrong type reads as none, never a lost history.
        let old = #"{"id":"\#(id.uuidString)","text":"plain","createdAt":"2026-10-25T00:00:00Z","kind":"inserted","app":"Notes","typed":7}"#
        let read = try? decoder.decode(DictationRecord.self, from: Data(old.utf8))
        check(read?.text == "plain" && read?.typed == nil && read?.rawHeard == nil, "history older records")
        let stripped = DictationRecord(id: id, text: "We need the deck", createdAt: at, delivery: .inserted(app: "Notes"), rawHeard: "We need uh the deck")
        check(stripped.heardShown == "We need uh the deck" && record.heardShown == "we need uh the deck", "history what was heard")
        let polished = DictationHistory.polishing(id, to: "We need the deck.", heard: "we need uh the deck", model: "sonnet", in: [stripped])
        check(polished.first?.typed == "We need the deck" && polished.first?.heard == "we need uh the deck", "history polishing keeps typed")
        let same = DictationRecord(id: id, text: "we need uh the deck", createdAt: at, delivery: .inserted(app: "Notes"))
        check(DictationHistory.polishing(id, to: "We need the deck.", heard: "we need uh the deck", model: "sonnet", in: [same]).first?.typed == nil,
              "history polishing keeps typed")
        let edited = DictationHistory.editing(id, edit: DictationUserEdit(text: "x", app: "Notes", at: at, edits: 1, learned: [], learnedIDs: []), in: [record])
        check(edited.first?.typed == record.typed, "history edits keep typed")
    }
}
