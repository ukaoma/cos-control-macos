import Foundation

// 0.5.342 Your edit, confirmed (mock: operations/personal/wk43_2026/mock-edit-confirm/edit-confirmation.html), executed
// against fictional fixtures: the word diff, what a watch keeps, the pill, the record's file compatibility, the card's
// reason line and Copy, and the drop-a-filler chip. Compiled with Sources/MacDictationCore.swift alone
// (Tests/run-edit-confirm.sh). Nothing is drawn, clicked, shown or played; no app is activated.
// Every check names its behaviour, so Tests/mutate-edit-confirm.py attributes each kill.

@main struct EditConfirmChecks {
    nonisolated(unsafe) static var ran = 0

    static func check(_ condition: Bool, _ behavior: String, _ detail: @autoclosure () -> String = "", line: UInt = #line) {
        ran += 1
        if !condition { fatalError("check failed [\(behavior)] at line \(line): \(detail())") }
    }
    typealias D = DictationWordDiff
    typealias C = DictationEditConfirm
    static let t0 = Date(timeIntervalSince1970: 1_792_850_000)

    static func main() {
        diffChecks()
        capturedChecks()
        pillChecks()
        recordChecks()
        reasonChecks()
        chipChecks()
        copyChecks()
        canaryChecks()
        print("PASS edit confirm: \(ran) checks; word diff, what a watch keeps, the pill, record compatibility, the reason line, the chip, Copy, the canary")
    }

    // MARK: The word diff

    static func diffChecks() {
        let same = D.diff(original: "a b c", final: "a b c")
        check(same == [D.Part(kind: .same, text: "a b c", trailing: "", words: 3)] && D.regions(same ?? []).isEmpty, "diff identical",
              "\(String(describing: same))")

        // The 08:30 case: "kind of" removed. Same words keep the final's spacing, the removed run its own.
        let removal = D.diff(original: "be able to kind of tell", final: "be able to tell")
        check(removal == [D.Part(kind: .same, text: "be able to", trailing: " ", words: 3),
                          D.Part(kind: .removed, text: "kind of", trailing: " ", words: 2),
                          D.Part(kind: .same, text: "tell", trailing: "", words: 1)], "diff removal", "\(String(describing: removal))")
        check(D.regions(removal ?? []) == [D.Region(removed: "kind of", added: "", removedWords: 2, addedWords: 0)], "diff removal",
              "one place, two words removed")

        let insertion = D.diff(original: "send it now", final: "send it over now")
        check(insertion == [D.Part(kind: .same, text: "send it", trailing: " ", words: 2),
                            D.Part(kind: .added, text: "over", trailing: " ", words: 1),
                            D.Part(kind: .same, text: "now", trailing: "", words: 1)], "diff insertion", "\(String(describing: insertion))")

        // Same words take the final text's spacing (the person's own), not what COS typed.
        let spacing = D.diff(original: "one  two", final: "one two three")
        check(spacing == [D.Part(kind: .same, text: "one two", trailing: " ", words: 2), D.Part(kind: .added, text: "three", trailing: "", words: 1)],
              "diff spacing", "\(String(describing: spacing))")

        // A replacement: removed first, then added, one place.
        let replacement = D.diff(original: "to Dana Kovalchik before", final: "to Dana Kowalczyk before")
        check(replacement == [D.Part(kind: .same, text: "to Dana", trailing: " ", words: 2),
                              D.Part(kind: .removed, text: "Kovalchik", trailing: " ", words: 1),
                              D.Part(kind: .added, text: "Kowalczyk", trailing: " ", words: 1),
                              D.Part(kind: .same, text: "before", trailing: "", words: 1)], "diff replacement order",
              "\(String(describing: replacement))")
        check(D.regions(replacement ?? []).count == 1, "diff replacement order", "a replacement is one place")

        // Punctuation stays on its word: "Hello," and "Hello" differ, "world." is one word.
        let punctuation = D.diff(original: "Hello, world.", final: "Hello world.")
        check((punctuation ?? []).map(\.kind) == [D.Kind.removed, .added, .same] && punctuation?.last?.text == "world."
              && punctuation?.first?.text == "Hello,", "diff punctuation", "\(String(describing: punctuation))")

        // Two separate edits are two places.
        let two = D.diff(original: "um I think we should um go", final: "I think we should go")
        check(D.regions(two ?? []).count == 2, "diff regions", "\(String(describing: two))")

        // Line breaks are kept as the spacing after a word.
        check(D.tokens("one\ntwo  three ") == [D.Token(word: "one", trailing: "\n"), D.Token(word: "two", trailing: "  "), D.Token(word: "three", trailing: " ")]
              && D.tokens("  lead") == [D.Token(word: "lead", trailing: "")], "diff tokens")

        // Long text: no diff marks past 600 words on either side.
        let long = Array(repeating: "word", count: 601).joined(separator: " ")
        let limit = Array(repeating: "word", count: 600).joined(separator: " ")
        check(D.diff(original: long, final: "word") == nil && D.diff(original: "word", final: long) == nil, "diff long fallback")
        check(D.diff(original: limit, final: limit + "") != nil && D.maximumWords == 600, "diff long fallback", "600 words still diff")
    }

    // MARK: What a watch keeps

    static let typed = "how would the user be able to kind of tell when"
    static let edited = "how would the user be able to tell when"
    static let window = "Prefix. " + edited + " Suffix"
    static let start = ("Prefix. " as NSString).length
    static let length = (edited as NSString).length
    static func cap(inside: Int = 2, readable: Bool = true, learning: Bool = true, stop: String = "focusLeft", window w: String? = window,
                    start s: Int = start, length l: Int = length) -> String? {
        C.captured(typed: typed, window: w, start: s, length: l, inside: inside, readable: readable, learning: learning, stop: stop)
    }

    static func capturedChecks() {
        check(cap() == edited, "captured keeps", "the 08:30 Claude watch keeps the final words")
        for stop in ["focusLeft", "cleared", "emptied", "cap", "reads", "appGone"] {
            check(cap(stop: stop) == edited, "captured keeps", "stop \(stop)")
        }
        check(cap(inside: 0) == nil, "captured needs inside", "edits outside the dictation (inside 0) keep nothing")
        check(cap(readable: false) == nil, "captured needs readable")
        check(cap(learning: false) == nil, "captured needs learning", "a probe app's reads are not proven")
        for stop in ["lost", "unreadable", "secure", "cancelled"] {
            check(cap(stop: stop) == nil, "captured stops", "stop \(stop) keeps nothing")
        }
        check(cap(window: nil) == nil, "captured needs a read")
        check(cap(start: start + 10, length: length) == nil && cap(start: -1) == nil && cap(length: 0) == nil, "captured bounds")
        // An edit undone (the words match what COS typed again), or whitespace only, is not an edit.
        check(cap(window: "Prefix. " + typed + " Suffix", length: (typed as NSString).length) == nil, "captured reverted")
        check(cap(window: "Prefix.       Suffix", length: 5) == nil, "captured blank")
    }

    // MARK: The pill

    static func pillChecks() {
        check(C.pill(typed: "a b", final: nil, learned: []) == .silent && C.label(.silent) == nil && !C.showsAtEnd(.silent),
              "pill silent", "no edit kept: no pill")
        let saved = C.pill(typed: "be able to kind of tell", final: "be able to tell", learned: [])
        check(saved == .saved && C.label(saved) == "✓ EDIT SAVED" && C.showsAtEnd(saved), "pill saved")
        let typed = "send the deck to Dana Kovalchik"
        let learnedOnly = C.pill(typed: typed, final: "send the deck to Dana Kowalczyk", learned: [(heard: "Kovalchik", written: "Kowalczyk")])
        check(learnedOnly == .learned("Kowalczyk") && C.label(learnedOnly) == "✓ LEARNED · KOWALCZYK" && !C.showsAtEnd(learnedOnly),
              "pill learned only", "\(learnedOnly): its pill showed when it was learned")
        let both = C.pill(typed: typed, final: "send the deck to Dana Kowalczyk now", learned: [(heard: "Kovalchik", written: "Kowalczyk")])
        check(both == .savedAndLearned("Kowalczyk") && C.label(both) == "✓ EDIT SAVED · LEARNED KOWALCZYK" && C.showsAtEnd(both),
              "pill both", "\(both)")
    }

    // MARK: The record

    static func recordChecks() {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let id = UUID()
        // A 0.5.341 record: no edit key.
        let old = #"{"id":"\#(id.uuidString)","text":"be able to kind of tell","createdAt":"2026-10-24T13:30:00Z","kind":"inserted","app":"Claude"}"#
        let decoded = try? decoder.decode(DictationRecord.self, from: Data(old.utf8))
        check(decoded?.edit == nil && decoded?.finalText == "be able to kind of tell" && decoded?.text == "be able to kind of tell",
              "record old decodes", "\(String(describing: decoded))")
        check(decoded?.metaLine(time: "now") == "now · 6 words · inserted · Claude", "record old decodes", "the meta line is unchanged")
        // An edit that does not read is no edit, never a lost record.
        let garbled = #"{"id":"\#(id.uuidString)","text":"x","createdAt":"2026-10-24T13:30:00Z","kind":"inserted","app":"Claude","edit":"nope"}"#
        let kept = try? decoder.decode(DictationRecord.self, from: Data(garbled.utf8))
        check(kept != nil && kept?.edit == nil, "record bad edit", "\(String(describing: kept))")
        // An edit written without the learned keys reads with none.
        let bare = #"{"id":"\#(id.uuidString)","text":"x y","createdAt":"2026-10-24T13:30:00Z","kind":"inserted","app":"Claude","edit":{"text":"x","app":"Claude","at":"2026-10-24T13:31:00Z","edits":1}}"#
        let bareRecord = try? decoder.decode(DictationRecord.self, from: Data(bare.utf8))
        check(bareRecord?.edit?.learned.isEmpty == true && bareRecord?.edit?.learnedIDs.isEmpty == true && bareRecord?.edit?.text == "x", "record edit decodes")

        let learnedID = UUID()
        let edit = DictationUserEdit(text: "be able to tell", app: "Claude", at: t0, edits: 1, learned: ["Kowalczyk"], learnedIDs: [learnedID])
        let record = DictationRecord(id: id, text: "be able to kind of tell", createdAt: t0, delivery: .inserted(app: "Claude"), edit: edit)
        let round = (try? encoder.encode(record)).flatMap { try? decoder.decode(DictationRecord.self, from: $0) }
        check(round == record, "record round trip", "\(String(describing: round))")
        check(record.metaLine(time: "now") == "now · 4 words · inserted · Claude · 1\u{00A0}edit" && record.finalText == "be able to tell",
              "record meta edits", record.metaLine(time: "now"))
        check(C.editsLabel(1) == "1\u{00A0}edit" && C.editsLabel(2) == "2\u{00A0}edits" && C.tag(app: "Claude") == "EDITED IN CLAUDE", "record meta edits")
        // Miles 10:26: "1 edit" never breaks across lines on a narrow card; the meta line carries a no-break space.
        check(record.metaLine(time: "now").contains("1\u{00A0}edit") && !record.metaLine(time: "now").contains("1 edit"), "meta keeps the edit count together")

        // Through the history's own save and load (atomic, private).
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cos-edit-confirm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("dictations.json")
        let plain = DictationRecord(id: UUID(), text: "plain", createdAt: t0.addingTimeInterval(-60), delivery: .inserted(app: "Notes"))
        try? DictationHistory.save([record, plain], to: url)
        let loaded = DictationHistory.load(from: url)
        check(loaded == [record, plain], "record round trip", "the history file keeps the edit and the plain record")

        // Editing sets it; Fix a word and Apply polished drop a stale one; search finds what was sent.
        let base = DictationRecord(id: id, text: "be able to kind of tell", createdAt: t0, delivery: .inserted(app: "Claude"))
        let edited = DictationHistory.editing(id, edit: edit, in: [base, plain])
        check(edited.first?.edit == edit && edited.first?.text == base.text && edited.last == plain, "record editing")
        check(DictationHistory.correcting(id, to: "be able to kind of yell", in: edited).first?.edit == nil, "record correcting drops edit")
        check(DictationHistory.polishing(id, to: "Be able to tell.", heard: base.text, model: "haiku", in: edited).first?.edit == nil,
              "record polishing drops edit")
        check(DictationHistory.search(edited, "able to tell").map(\.id) == [id] && DictationHistory.search([base], "able to tell").isEmpty,
              "record search edited", "found by what was sent")

        // The edit for the record: the record must still hold what the watch looked for.
        let suggestion = DictationSuggestion(id: learnedID, heard: "Kovalchik", written: "Kowalczyk", app: "Slack", at: t0)
        let made = C.edit(typed: "Can you send the deck to Dana Kovalchik before the 2pm?", recordText: "Can you send the deck to Dana Kovalchik before the 2pm?",
                          final: "Can you send the deck to Dana Kowalczyk before the 2pm?", app: "Slack", at: t0, inside: 1, learned: [suggestion])
        check(made == DictationUserEdit(text: "Can you send the deck to Dana Kowalczyk before the 2pm?", app: "Slack", at: t0, edits: 1,
                                        learned: ["Kowalczyk"], learnedIDs: [learnedID]), "record edit made", "\(String(describing: made))")
        check(C.edit(typed: "Claude's version.", recordText: "what was heard", final: "Claude's version!", app: "Claude", at: t0, inside: 1, learned: []) == nil,
              "record edit mismatch", "a record whose text changed since the watch started keeps nothing")
        let twice = C.edit(typed: "um I think we should um go", recordText: "um I think we should um go", final: "I think we should go",
                           app: "Claude", at: t0, inside: 2, learned: [])
        check(twice?.edits == 2, "record edit made", "two places, two edits")
    }

    // MARK: The reason line

    static func reasonChecks() {
        let removal = D.diff(original: "be able to kind of tell", final: "be able to tell")
        check(C.reason(parts: removal, learned: []) == "You removed \"kind of\". Not added to your dictionary: COS learns names and terms, not everyday words.",
              "reason removal", C.reason(parts: removal, learned: []))
        check(C.reason(parts: D.diff(original: "Dana Kovalchik", final: "Dana Kowalczyk"), learned: ["Kowalczyk"])
              == "Added Kowalczyk to your dictionary. Next time COS writes it for you.", "reason learned")
        check(C.reason(parts: nil, learned: ["Gina", "Jewel360"]) == "Added Gina and Jewel360 to your dictionary. Next time COS writes them for you.",
              "reason learned")
        check(C.reason(parts: D.diff(original: "send it now", final: "send it over now"), learned: []) == "You added \"over\". Nothing new for your dictionary.",
              "reason added")
        check(C.reason(parts: D.diff(original: "see you their", final: "see you there"), learned: [])
              == "You changed \"their\" to \"there\". Nothing new for your dictionary.", "reason changed")
        check(C.reason(parts: D.diff(original: "um I think we should um go", final: "I think we should go"), learned: [])
              == "You edited 2 words. Nothing new for your dictionary.", "reason complex")
        check(C.reason(parts: nil, learned: []) == "You edited this dictation. Nothing new for your dictionary.", "reason long")
        // Copy rules: no em dash, no arrow in anything the card says.
        let lines = [C.reason(parts: removal, learned: []), C.notEveryday, C.nothingNew, C.chipLabel("kind of"), C.chipAdded, C.instruction("kind of"),
                     C.label(.saved) ?? "", C.label(.savedAndLearned("x")) ?? "", C.tag(app: "Claude")]
        check(lines.allSatisfy { !$0.contains("\u{2014}") && !$0.contains("\u{2192}") && !$0.contains(" -> ") }, "reason copy rules")
    }

    // MARK: Always drop "<phrase>" from my dictation

    static func chipChecks() {
        let none: (String) -> Bool = { _ in false }
        func phrase(_ a: String, _ b: String, terms: @escaping (String) -> Bool = { _ in false }) -> String? {
            C.dropPhrase(parts: D.diff(original: a, final: b), isTerm: terms)
        }
        check(phrase("be able to kind of tell", "be able to tell") == "kind of", "chip single removal")
        check(phrase("So, um, we go", "So, we go") == "um", "chip single removal", "punctuation around the phrase is trimmed, case folded")
        check(phrase("um I think we should um go", "I think we should go") == nil, "chip one place", "two removals are two edits")
        check(phrase("see you their", "see you there") == nil, "chip removal only", "a replacement is not a filler")
        check(phrase("send it now", "send it over now") == nil, "chip removal only", "an insertion is not a filler")
        check(phrase("it was you know sort of fine", "it was fine") == nil, "chip three words", "four words is not a short phrase")
        check(phrase("we are kind of sort here", "we are here") == "kind of sort", "chip three words", "three words is")
        check(phrase("meet at 2pm today", "meet today") == nil && phrase("see https://x.co now", "see now") == nil
              && phrase("ping @sam now", "ping now") == nil, "chip letters only", "digits, links and handles are not fillers")
        check(phrase("send to Dana Kowalczyk", "send to Dana", terms: { $0.lowercased() == "kowalczyk" }) == nil, "chip not a term",
              "a dictionary term is never offered as a filler")
        check(C.dropPhrase(parts: nil, isTerm: none) == nil, "chip needs a diff")

        check(C.instruction("kind of") == "Remove the filler \"kind of\".", "chip instruction")
        check(C.adding("kind of", to: "") == "Remove the filler \"kind of\".", "chip instruction", "into empty instructions")
        let mine = "Use Oxford commas."
        let added = C.adding("kind of", to: mine + "\n")
        check(added == mine + "\nRemove the filler \"kind of\".", "chip instruction", "on its own line after the person's own")
        check(C.adding("kind of", to: added ?? "") == nil && C.adding("kind of", to: "REMOVE THE FILLER \"KIND OF\".") == nil,
              "chip idempotent", "never added twice")
        let full = String(repeating: "x", count: DictationPolishInstructions.maximumCharacters - 10)
        check(C.adding("kind of", to: full) == nil, "chip cap", "never past the server's 1,000 characters")
        check(C.removing("kind of", from: added ?? "") == mine && C.removing("kind of", from: C.instruction("kind of")) == ""
              && C.removing("kind of", from: mine) == mine, "chip undo", "Undo takes out only its own line")
        check(C.offersDrop(phrase: "kind of", available: true, polishOn: true, saved: mine), "chip offered")
        check(!C.offersDrop(phrase: "kind of", available: false, polishOn: true, saved: mine), "chip needs instructions", "an older server: no chip")
        check(!C.offersDrop(phrase: "kind of", available: true, polishOn: false, saved: mine), "chip needs polish", "AI polish off: no chip")
        check(!C.offersDrop(phrase: nil, available: true, polishOn: true, saved: mine)
              && !C.offersDrop(phrase: "kind of", available: true, polishOn: true, saved: added ?? ""), "chip offered", "no phrase, or already there")
    }

    // MARK: Copy

    static func copyChecks() {
        let edit = DictationUserEdit(text: "be able to tell", app: "Claude", at: t0, edits: 1)
        let record = DictationRecord(id: UUID(), text: "be able to kind of tell", createdAt: t0, delivery: .inserted(app: "Claude"), edit: edit)
        let plain = DictationRecord(id: UUID(), text: "plain", createdAt: t0, delivery: .inserted(app: "Notes"))
        check(C.copyText(record, showOriginal: false) == "be able to tell" && C.copyText(record, showOriginal: true) == "be able to kind of tell",
              "copy follows the toggle")
        check(C.copyText(plain, showOriginal: false) == "plain" && C.copyText(plain, showOriginal: true) == "plain", "copy follows the toggle")
    }

    // MARK: The canary

    static func canaryChecks() {
        var canary = DictationLearnCanary(at: "2026-10-24T13:30:00Z", bundle: "com.anthropic.claudefordesktop", eligibility: "learn", readable: true,
                                          reads: 4, stop: "focusLeft", rebinds: 0, reanchors: 0, inside: 2, candidates: 0, learned: 0, focusWhy: "app")
        func keys(_ c: DictationLearnCanary) -> Set<String> {
            let line = DictationLearnCanaryLog.line(c).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return Set((try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?.keys.map { $0 } ?? [])
        }
        check(!keys(canary).contains("edited"), "canary edited", "absent until the watch says")
        canary.edited = true
        let line = DictationLearnCanaryLog.line(canary).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check(keys(canary).contains("edited") && line.contains("\"edited\":true") && !line.contains("kind"), "canary edited", "a verdict, never words")
    }
}
