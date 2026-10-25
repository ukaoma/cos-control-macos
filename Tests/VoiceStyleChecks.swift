import Foundation

// 0.5.344 part 2, Your style (plan r2 section 2, PLAN_dictation_voice_style_2026-10-24.md), executed against fictional
// fixtures: the ledger file, the classifier and its evidence filters, promotion, retirement, tombstones, ranking, the
// pill once per rule ever, the card's lines, and the push to the server (needs-push, 409 then merge, 413 then drop)
// against a fake server. Compiled with Sources/MacDictationCore.swift alone (Tests/run-voice-style.sh). Nothing is drawn,
// clicked, shown or posted. Every check names its behaviour, so Tests/mutate-voice-style.py attributes each kill.

@main struct VoiceStyleChecks {
    nonisolated(unsafe) static var ran = 0
    static func check(_ condition: Bool, _ behavior: String, _ detail: @autoclosure () -> String = "", line: UInt = #line) {
        ran += 1
        if !condition { fatalError("check failed [\(behavior)] at line \(line): \(detail())") }
    }
    typealias S = DictationStyle
    typealias C = DictationStyleClassifier
    static let t0 = Date(timeIntervalSince1970: 1_792_900_000)
    static let drop = S.Key(kind: .dropPhrase, param: "honestly")
    static let use = S.Key(kind: .contractions, param: "use")
    static let avoid = S.Key(kind: .contractions, param: "avoid")

    static func main() async {
        keyChecks()
        classifierChecks()
        filterChecks()
        promotionChecks()
        retirementChecks()
        tombstoneChecks()
        rankingChecks()
        pillChecks()
        lineChecks()
        await syncChecks()
        ledgerFileChecks()
        print("PASS voice style: \(ran) checks; keys, the classifier, the filters, promotion, retirement, tombstones, ranking, the pill once ever, the lines, the sync, the ledger file")
    }

    // MARK: Keys

    static func keyChecks() {
        check(drop.id == "drop-honestly" && S.Key(kind: .dropPhrase, param: "at the end of the day").id == "drop-at-the-end-of-the-day"
              && use.id == "contractions-use" && avoid.id == "contractions-avoid", "key ids", "the server's id pattern")
        for phrase in S.defaultAllowlist {
            let id = S.Key(kind: .dropPhrase, param: phrase).id
            check(id.range(of: "^[a-z0-9_-]{1,40}$", options: .regularExpression) != nil, "key ids", id)
        }
        check(S.defaultAllowlist.count == 12 && S.defaultAllowlist.contains("if that makes sense") && !S.defaultAllowlist.contains("like"),
              "allowlist", "the server's 12 phrases, never a word that carries meaning")
        check(drop.valid(allowlist: S.defaultAllowlist) && !S.Key(kind: .dropPhrase, param: "like").valid(allowlist: S.defaultAllowlist)
              && use.valid(allowlist: []) && !S.Key(kind: .contractions, param: "maybe").valid(allowlist: []), "key valid", "closed sets only")
        check(use.opposite == avoid && avoid.opposite == use && drop.opposite == nil, "key opposite", "use and avoid")
        check(drop.title == "Drop \u{201C}honestly\u{201D}" && use.title == "Use contractions" && avoid.title == "Write contractions out", "key titles", "Settings' words")
    }

    // MARK: The classifier

    static func observe(_ typed: String, _ final: String, instructions: String = "") -> [S.Observation] {
        C.observations(typed: typed, final: final, allowlist: S.defaultAllowlist, instructions: instructions)
    }
    static func classifierChecks() {
        check(observe("Honestly, the plan works for me.", "The plan works for me.") == [S.Observation(key: drop)], "drop phrase", "a sentence-start phrase")
        check(observe("It is, honestly, ready to go.", "It is ready to go.") == [S.Observation(key: drop)], "drop phrase", "punctuation moves with it")
        check(observe("I guess it works now.", "It works now.") == [S.Observation(key: S.Key(kind: .dropPhrase, param: "i guess"))], "drop phrase", "two words")
        check(observe("Send it at the end of the day please.", "Send it please.").first?.key.param == "at the end of the day", "drop phrase longest", "the longest phrase first")
        check(observe("Honestly the plan works.", "The plan works.", instructions: "Remove the filler \"honestly\".").isEmpty, "drop phrase instructions",
              "a phrase already in the person's instructions (the Always drop chip) is not a rule")
        check(observe("Basically the plan works.", "The plan works.").isEmpty, "drop phrase allowlist", "only the allowlist")
        check(observe("The plan works.", "Honestly the plan works.") == [S.Observation(key: drop, added: true)], "drop phrase put back", "a phrase added is a contradiction")
        check(observe("Honestly the plan works.", "Truly the plan works.").isEmpty, "drop phrase only change", "a phrase replaced is not a drop")
        check(observe("Honestly the plan works.", "A plan works.").isEmpty, "drop phrase only change", "dropped with another word changed is not a clean drop")
        check(observe("I am sure we do not need it.", "I'm sure we don't need it.") == [S.Observation(key: use)], "contractions use", "contracted")
        check(observe("I'm sure it's fine.", "I am sure it is fine.") == [S.Observation(key: avoid)], "contractions avoid", "written out")
        check(observe("I\u{2019}m sure.", "I am sure.") == [S.Observation(key: avoid)], "contractions apostrophe", "a curly apostrophe reads the same")
        check(observe("We cannot ship it today.", "We can't ship it today.") == [S.Observation(key: use)], "contractions use", "one word in full")
        check(observe("I am here.", "You are here.").isEmpty, "contractions only change", "another word is not a contraction")
        let both = observe("Honestly the plan works and I am sure.", "The plan works and I'm sure.")
        check(both == [S.Observation(key: drop), S.Observation(key: use)], "two classes", "one drop and one contraction in one edit: \(both)")
        let twice = observe("Honestly it works and frankly it ships.", "It works and it ships.")
        check(twice.filter { $0.key.kind == .dropPhrase }.count == 1, "one per class", "one drop_phrase a dictation: \(twice)")
        check(observe("Send the deck to the team", "Send the deck to the team honestly").isEmpty, "edge writing on",
              "an edit at the end that adds more than it removes is writing on, never a phrase put back")
        check(observe("Tell them we cannot", "Tell them we can't") == [S.Observation(key: use)], "edge contraction", "a contraction at the very end still counts")
        check(C.direction(removed: ["i", "am"], added: ["i'm"]) == "use" && C.direction(removed: ["i'm"], added: ["i", "am"]) == "avoid"
              && C.direction(removed: ["i"], added: ["i"]) == nil && C.direction(removed: [], added: ["i'm"]) == nil, "contractions direction", "both ways")
        check(C.spliced(["a", "honestly", "b"], ["a", "b"], phrase: ["honestly"]) && !C.spliced(["a", "honestly", "c"], ["a", "b"], phrase: ["honestly"])
              && !C.spliced(["a", "b"], ["a", "b"], phrase: ["honestly"]), "spliced", "exactly the phrase, nothing else")
        check(C.normalize("Honestly,") == "honestly" && C.normalize("I\u{2019}m") == "i'm" && C.normalize("\"don't\"") == "don't", "normalize", "case and edge punctuation")
    }

    // MARK: The evidence filters

    static func evidence(_ change: (inout C.Evidence) -> Void = { _ in }) -> C.Evidence {
        var e = C.Evidence(dictation: UUID(), typed: "Honestly, the plan works for me.", final: "The plan works for me.", baselinePolished: true,
                           complete: true, inputEvents: 3, startReanchor: false, app: "Claude", appliedHash: nil)
        change(&e)
        return e
    }
    static let on = C.Settings(enabled: true, polishOn: true, learnMode: .automatic)
    static func filterChecks() {
        check(C.excluded(evidence(), on) == nil, "filters pass", "a complete, polished, typed edit counts")
        check(C.excluded(evidence { $0.complete = false }, on) == "partial", "filter partial", "a partial watch is never evidence")
        check(C.excluded(evidence { $0.baselinePolished = false }, on) == "notPolished", "filter polished", "the baseline must be Claude's version")
        check(C.excluded(evidence { $0.inputEvents = 0 }, on) == "noInput", "filter input", "the monitor saw no key or click in that app")
        check(C.excluded(evidence { $0.startReanchor = true }, on) == "reanchor", "filter reanchor", "an edit found by re-anchoring at the start")
        var literal = on; literal.registers = ["iTerm2": "literal"]; literal.registersEnabled = true
        check(C.excluded(evidence { $0.app = " iterm2 " }, literal) == "literal", "filter literal", "a literal app while registers are on")
        literal.registersEnabled = false
        check(C.excluded(evidence { $0.app = "iTerm2" }, literal) == nil, "filter literal off", "registers off (6.91.0's default): a terminal counts")
        check(C.excluded(evidence { $0.final = "Пожалуйста отправьте план"; $0.typed = "Пожалуйста отправьте план сегодня" }, on) == "language",
              "filter language", "not mostly English")
        check(C.mostlyEnglish("The plan works.") && !C.mostlyEnglish("ok") && !C.mostlyEnglish("Пожалуйста"), "mostly english", "nine in ten letters a to z")
        var off = on; off.enabled = false
        check(C.excluded(evidence(), off) == "off", "filter switch", "Learn my style from edits off")
        var noPolish = on; noPolish.polishOn = false
        check(C.excluded(evidence(), noPolish) == "polishOff", "filter polish on", "only while AI polish is on")
        var learnOff = on; learnOff.learnMode = .off
        check(C.excluded(evidence(), learnOff) == "learnOff", "filter learn mode", "never with Learn from my edits off")
        var ledger = S.Ledger()
        let refused = C.learn(&ledger, evidence: evidence { $0.inputEvents = 0 }, settings: on, now: t0)
        check(refused.reason == "noInput" && ledger.rules.isEmpty && ledger.seen.isEmpty, "learn respects filters", "a refused edit leaves the ledger alone")
        let none = C.learn(&ledger, evidence: evidence { $0.final = $0.typed + " Thanks." }, settings: on, now: t0)
        check(none.reason == "noClass" && ledger.rules.isEmpty, "learn no class", "nothing to learn")
    }

    // MARK: Promotion

    static func promotionChecks() {
        var ledger = S.Ledger()
        let a = UUID(), b = UUID()
        let first = S.observe(&ledger, dictation: a, observations: [S.Observation(key: drop)], appliedHash: nil, suggestOnly: false, now: t0)
        check(first.isEmpty && S.state(ledger.rules[0], suggestOnly: false) == .pending, "promote after two", "one dictation is pending")
        let again = S.observe(&ledger, dictation: a, observations: [S.Observation(key: drop)], appliedHash: nil, suggestOnly: false, now: t0)
        check(again.isEmpty && ledger.rules[0].confirmations == [a], "promote distinct dictations", "the same dictation twice counts once")
        var forgot = S.Ledger()
        forgot.rules = [S.Rule(kind: .dropPhrase, param: "honestly", confirmations: [a], firstSeen: t0, lastSeen: t0)]
        _ = S.observe(&forgot, dictation: a, observations: [S.Observation(key: drop)], appliedHash: nil, suggestOnly: false, now: t0)
        check(forgot.rules[0].confirmations == [a], "promote distinct dictations", "evidence pruned, the rule still counts a dictation once")
        let second = S.observe(&ledger, dictation: b, observations: [S.Observation(key: drop)], appliedHash: nil, suggestOnly: false, now: t0)
        check(second == [drop.id] && S.state(ledger.rules[0], suggestOnly: false) == .active, "promote after two", "two distinct dictations")
        check(S.observe(&ledger, dictation: UUID(), observations: [S.Observation(key: drop)], appliedHash: nil, suggestOnly: false, now: t0).isEmpty,
              "promote once", "an active rule is not new again")
        var suggest = S.Ledger()
        _ = S.observe(&suggest, dictation: a, observations: [S.Observation(key: use)], appliedHash: nil, suggestOnly: true, now: t0)
        let proposed = S.observe(&suggest, dictation: b, observations: [S.Observation(key: use)], appliedHash: nil, suggestOnly: true, now: t0)
        check(proposed.isEmpty && S.state(suggest.rules[0], suggestOnly: true) == .suggested, "suggest only", "proposes, never activates")
        S.accept(&suggest, use.id)
        check(S.state(suggest.rules[0], suggestOnly: true) == .active, "suggest accept", "the person's Add activates it")
        var suggesting = on; suggesting.learnMode = .suggest
        var offered = S.Ledger()
        let firstLearn = C.learn(&offered, evidence: evidence(), settings: suggesting, now: t0)
        let secondLearn = C.learn(&offered, evidence: evidence(), settings: suggesting, now: t0)
        check(firstLearn.newlyActive.isEmpty && secondLearn.newlyActive.isEmpty && S.state(offered.rules[0], suggestOnly: true) == .suggested, "learn suggest only",
              "Suggest only proposes the rule and never activates it")
        var learned = S.Ledger()
        _ = C.learn(&learned, evidence: evidence(), settings: on, now: t0)
        let active = C.learn(&learned, evidence: evidence(), settings: on, now: t0)
        check(active.newlyActive == [drop.id] && active.reason == nil, "learn promotes", "two dictations, Save automatically")
        var explicit = S.Ledger()
        S.add(&explicit, avoid, allowlist: S.defaultAllowlist, now: t0)
        check(S.state(explicit.rules[0], suggestOnly: false) == .active && explicit.rules[0].support == 1, "add a rule", "Add a rule activates at once")
        S.add(&explicit, S.Key(kind: .dropPhrase, param: "like"), allowlist: S.defaultAllowlist, now: t0)
        check(explicit.rules.count == 1, "add closed", "never a phrase outside the allowlist")
        S.add(&explicit, use, allowlist: S.defaultAllowlist, now: t0)
        check(explicit.rules.map(\.key) == [use], "add replaces opposite", "use replaces an added avoid")
        var kinds = S.Ledger()
        _ = S.observe(&kinds, dictation: a, observations: [S.Observation(key: drop), S.Observation(key: S.Key(kind: .dropPhrase, param: "frankly"))],
                      appliedHash: nil, suggestOnly: false, now: t0)
        check(kinds.rules.count == 1, "one per class", "one drop_phrase observation a dictation in the ledger too")
        _ = S.observe(&kinds, dictation: a, observations: [S.Observation(key: S.Key(kind: .dropPhrase, param: "obviously"))], appliedHash: nil, suggestOnly: false, now: t0)
        check(kinds.rules.count == 1, "one per class", "a later edit of the same dictation adds nothing for a class it showed")
    }

    // MARK: Retirement

    static func retirementChecks() {
        var ledger = S.Ledger()
        let a = UUID(), b = UUID()
        _ = S.observe(&ledger, dictation: a, observations: [S.Observation(key: use)], appliedHash: nil, suggestOnly: false, now: t0)
        _ = S.observe(&ledger, dictation: b, observations: [S.Observation(key: use)], appliedHash: nil, suggestOnly: false, now: t0)
        S.remember(&ledger, hash: "0a1b2c3d", ids: [use.id])
        // Expanding contractions where "use" was NOT applied (no hash) is no contradiction.
        _ = S.observe(&ledger, dictation: UUID(), observations: [S.Observation(key: avoid)], appliedHash: nil, suggestOnly: false, now: t0)
        _ = S.observe(&ledger, dictation: UUID(), observations: [S.Observation(key: avoid)], appliedHash: "ffffffff", suggestOnly: false, now: t0)
        check(ledger.rules.first { $0.key == use }?.contradictions.isEmpty == true, "contradiction needs applied", "only where the hash shows the rule applied")
        _ = S.observe(&ledger, dictation: UUID(), observations: [S.Observation(key: avoid)], appliedHash: "0a1b2c3d", suggestOnly: false, now: t0)
        _ = S.observe(&ledger, dictation: UUID(), observations: [S.Observation(key: avoid)], appliedHash: "0a1b2c3d", suggestOnly: false, now: t0)
        let rule = ledger.rules.first { $0.key == use }!
        check(rule.contradictions.count == 2 && !rule.retired && S.state(rule, suggestOnly: false) == .active, "retire outnumbered",
              "two against two is not outnumbered")
        _ = S.observe(&ledger, dictation: UUID(), observations: [S.Observation(key: avoid)], appliedHash: "0a1b2c3d", suggestOnly: false, now: t0)
        let retired = ledger.rules.first { $0.key == use }!
        check(retired.retired && S.state(retired, suggestOnly: false) == .retired, "retire outnumbered", "three against two retires")
        var one = S.Ledger()
        S.add(&one, drop, allowlist: S.defaultAllowlist, now: t0)
        S.remember(&one, hash: "11112222", ids: [drop.id])
        _ = S.observe(&one, dictation: UUID(), observations: [S.Observation(key: drop, added: true)], appliedHash: "11112222", suggestOnly: false, now: t0)
        check(!one.rules[0].retired, "retire at least two", "one contradiction never retires")
        _ = S.observe(&one, dictation: UUID(), observations: [S.Observation(key: drop, added: true)], appliedHash: "11112222", suggestOnly: false, now: t0)
        check(one.rules[0].retired, "retire at least two", "two against an added rule's one")
        check(!S.Rule(kind: .dropPhrase, param: "honestly", contradictions: [UUID()], firstSeen: t0, lastSeen: t0).retired, "retire at least two",
              "one contradiction never retires, even with no support")
    }

    // MARK: Tombstones

    static func tombstoneChecks() {
        var ledger = S.Ledger()
        S.add(&ledger, drop, allowlist: S.defaultAllowlist, now: t0)
        S.remove(&ledger, drop.id, now: t0)
        check(ledger.rules.isEmpty && S.tombstoned(drop.id, in: ledger, now: t0.addingTimeInterval(29 * 24 * 3600)), "tombstone", "30 days quiet")
        _ = S.observe(&ledger, dictation: UUID(), observations: [S.Observation(key: drop)], appliedHash: nil, suggestOnly: false, now: t0.addingTimeInterval(60))
        check(ledger.rules.isEmpty, "tombstone quiet", "a removed rule is not seen again while quiet")
        check(!S.tombstoned(drop.id, in: ledger, now: t0.addingTimeInterval(31 * 24 * 3600)), "tombstone expires", "after 30 days")
        let later = t0.addingTimeInterval(31 * 24 * 3600)
        _ = S.observe(&ledger, dictation: UUID(), observations: [S.Observation(key: drop)], appliedHash: nil, suggestOnly: false, now: later)
        check(ledger.rules.count == 1 && ledger.tombstones.isEmpty, "tombstone expires", "seen again after, and pruned")
        S.remove(&ledger, drop.id, now: later)
        S.add(&ledger, drop, allowlist: S.defaultAllowlist, now: later)
        check(ledger.rules.count == 1 && !S.tombstoned(drop.id, in: ledger, now: later), "tombstone add", "Add a rule clears its tombstone")
        var merged = S.Ledger()
        S.remove(&merged, drop.id, now: t0)
        S.merge(&merged, server: [S.ServerRule(id: drop.id, kind: "drop_phrase", register: "all", param: "honestly", count: 3, lastSeen: nil)],
                allowlist: S.defaultAllowlist, now: t0)
        check(merged.rules.isEmpty, "tombstone merge", "a 409 merge never brings back a removed rule")
        var mine = S.Ledger()
        S.add(&mine, use, allowlist: S.defaultAllowlist, now: t0)
        S.merge(&mine, server: [S.ServerRule(id: avoid.id, kind: "contractions", register: "all", param: "avoid", count: 2, lastSeen: nil),
                                S.ServerRule(id: "drop-like", kind: "drop_phrase", register: "all", param: "like", count: 2, lastSeen: nil)],
                allowlist: S.defaultAllowlist, now: t0)
        check(mine.rules.map(\.key) == [use], "merge opposite", "the server's avoid never joins this Mac's use, and no phrase outside the allowlist")
    }

    // MARK: Ranking

    static func rankingChecks() {
        var ledger = S.Ledger()
        let phrases = S.defaultAllowlist
        for (i, phrase) in phrases.enumerated() {
            let key = S.Key(kind: .dropPhrase, param: phrase)
            for _ in 0..<(2 + i) {
                _ = S.observe(&ledger, dictation: UUID(), observations: [S.Observation(key: key)], appliedHash: nil, suggestOnly: false, now: t0.addingTimeInterval(Double(i)))
            }
        }
        let ranked = S.ranked(ledger, suggestOnly: false, now: t0.addingTimeInterval(100))
        check(ranked.first?.param == phrases.last && ranked.last?.param == phrases.first, "rank net support", "most support first")
        S.add(&ledger, use, allowlist: phrases, now: t0)
        _ = S.observe(&ledger, dictation: UUID(), observations: [S.Observation(key: avoid)], appliedHash: nil, suggestOnly: false, now: t0)
        _ = S.observe(&ledger, dictation: UUID(), observations: [S.Observation(key: avoid)], appliedHash: nil, suggestOnly: false, now: t0)
        let mixed = S.ranked(ledger, suggestOnly: false, now: t0.addingTimeInterval(100))
        check(mixed.filter { $0.kind == .contractions }.count == 1, "rank one contractions", "the server takes one contractions rule")
        var many = S.Ledger()
        for i in 0..<25 {
            many.rules.append(S.Rule(kind: .dropPhrase, param: "p\(i)", explicit: true, firstSeen: t0, lastSeen: t0.addingTimeInterval(Double(i))))
        }
        check(S.ranked(many, suggestOnly: false, now: t0).count == S.maximumRules, "rank top 20", "at most 20")
        check(S.ranked(many, suggestOnly: false, now: t0).first?.param == "p24", "rank last seen", "ties go to the latest seen")
    }

    // MARK: The pill, once per rule id ever

    static func pillChecks() {
        var ledger = S.Ledger()
        check(S.announce(&ledger, newlyActive: [drop.id]) == drop.id && ledger.announced == [drop.id], "pill once", "the first time")
        check(S.announce(&ledger, newlyActive: [drop.id]) == nil, "pill once", "never again, even after Undo and a new promotion")
        check(S.announce(&ledger, newlyActive: [drop.id, use.id]) == use.id, "pill next", "the next rule that never showed")
        S.reset(&ledger)
        check(ledger.announced.count == 2, "pill once ever", "Reset keeps the rules already announced")
        check(S.pillLabel(drop) == "Learned your style: drop \u{201C}honestly\u{201D}" && S.pillLabel(use) == "Learned your style: use contractions", "pill label", S.pillLabel(drop))
    }

    // MARK: The card's lines and the copy

    static func lineChecks() {
        var ledger = S.Ledger()
        S.remember(&ledger, hash: "0a1b2c3d", ids: [drop.id, use.id])
        check(S.ruleCount(hash: "0a1b2c3d", in: ledger) == 2 && S.ruleCount(hash: "ffffffff", in: ledger) == 0 && S.ruleCount(hash: nil, in: ledger) == 0,
              "rule count", "by the dictation's hash")
        let polished = DictationRecord(id: UUID(), text: "Hi.", createdAt: t0, delivery: .inserted(app: "Fixture"), heard: "um hi", polishModel: "sonnet",
                                       polishPrompt: "v4", polishStyleHash: "0a1b2c3d")
        check(polished.polishLine(styleRules: 2) == "Polished · Sonnet · v4 · 2 style rules" && polished.polishLine(styleRules: 1) == "Polished · Sonnet · v4 · 1 style rule"
              && polished.polishLine(styleRules: 0) == "Polished · Sonnet · v4", "card style rules", "\(String(describing: polished.polishLine(styleRules: 2)))")
        let guarded = DictationRecord(id: UUID(), text: "Ship 5 units.", createdAt: t0, delivery: .inserted(app: "Fixture"), polishGuard: "number")
        let bare = DictationRecord(id: UUID(), text: "Ship it.", createdAt: t0, delivery: .inserted(app: "Fixture"), polishGuard: "guarded")
        check(guarded.polishLine(styleRules: 0) == "Kept as heard: polish changed a number" && bare.polishLine(styleRules: 3) == "Kept as heard", "card kept",
              "by guard kind, plain without one")
        check(S.keptLine(guard: "negation") == "Kept as heard: polish changed a no or a not" && S.keptLine(guard: "date") == "Kept as heard: polish changed a date"
              && S.keptLine(guard: nil) == "Kept as heard" && S.keptLine(guard: "weird") == "Kept as heard", "card kept", "every kind")
        check(S.guardCode("number") == "number" && S.guardCode("guarded") == "guarded" && S.guardCode("drop table") == nil
              && S.styleHash("0a1b2c3d") == "0a1b2c3d" && S.styleHash("0A1B2C3D") == nil, "record codes", "only codes reach the record")
        let round = (try? JSONEncoder().encode(guarded)).flatMap { try? JSONDecoder().decode(DictationRecord.self, from: $0) }
        check(round?.polishGuard == "number" && round?.polishLine(styleRules: 0) == "Kept as heard: polish changed a number", "record guard", "survives the file")
        let marked = DictationHistory.guarding(bare.id, guard: "date", styleHash: "0a1b2c3d", in: [bare])
        check(marked.first?.polishGuard == "date" && marked.first?.polishStyleHash == "0a1b2c3d" && marked.first?.text == "Ship it.", "record guarding", "paste first")
        let edited = DictationHistory.editing(guarded.id, edit: DictationUserEdit(text: "Ship 6 units.", app: "Fixture", at: t0, edits: 1), in: [guarded])
        check(edited.first?.polishGuard == "number", "record guarding", "an edit keeps the guard")
        let status = DictationStyleCopy.status(available: false, checked: true, serverEnabled: true, model: .haiku, learnMode: .automatic)
        check(status == [DictationStyleCopy.needsServer, DictationStyleCopy.notSonnet], "copy status", "\(status)")
        check(DictationStyleCopy.status(available: true, checked: true, serverEnabled: false, model: .sonnet, learnMode: .automatic) == [DictationStyleCopy.serverOff],
              "copy status", "turned off on the server")
        check(DictationStyleCopy.status(available: true, checked: true, serverEnabled: true, model: .off, learnMode: .automatic) == [DictationStyleCopy.needsPolish]
              && DictationStyleCopy.status(available: false, checked: false, serverEnabled: true, model: .sonnet, learnMode: .automatic).isEmpty, "copy status",
              "polish off; nothing before a read")
        check(DictationStyleCopy.status(available: true, checked: true, serverEnabled: true, model: .sonnet, learnMode: .automatic, monitor: false)
              == [DictationStyleCopy.needsShortcut]
              && DictationStyleCopy.status(available: true, checked: true, serverEnabled: true, model: .off, learnMode: .automatic, monitor: false)
              == [DictationStyleCopy.needsPolish], "copy status shortcut", "a key-combination shortcut cannot count typing; polish off says only that")
        let templates = DictationStyleCopy.templates(allowlist: S.defaultAllowlist)
        check(templates.count == 14 && templates.allSatisfy { $0.valid(allowlist: S.defaultAllowlist) }, "copy templates", "closed templates only")
        let half = S.Rule(kind: .dropPhrase, param: "honestly", confirmations: [UUID()], firstSeen: t0, lastSeen: t0)
        check(DictationStyleCopy.pendingLine(half) == "seen 1 of 2", "copy pending", DictationStyleCopy.pendingLine(half))
        let copy = [DictationStyleCopy.title, DictationStyleCopy.switchTitle, DictationStyleCopy.needsServer, DictationStyleCopy.serverOff,
                    DictationStyleCopy.notSonnet, DictationStyleCopy.needsPolish, DictationStyleCopy.empty, DictationStyleCopy.addTitle, DictationStyleCopy.reset,
                    DictationStyleCopy.previousPolish, DictationStyleCopy.previousNote, DictationStyleCopy.disclosureRules, DictationStyleCopy.disclosureKeys,
                    DictationStyleCopy.needsShortcut,
                    S.pillLabel(drop), S.keptLine(guard: "number")] + templates.map(\.title)
        for line in copy { check(!line.contains("\u{2014}") && !line.contains("\u{2192}") && !line.contains("->"), "copy plain", line) }
        check(DictationStyleCopy.disclosureRules.contains("never your text") && DictationStyleCopy.disclosureKeys.contains("never records which keys"),
              "copy disclosure", "the two disclosure lines")
        var cleared = S.Ledger()
        S.add(&cleared, drop, allowlist: S.defaultAllowlist, now: t0)
        _ = S.observe(&cleared, dictation: UUID(), observations: [S.Observation(key: use)], appliedHash: nil, suggestOnly: false, now: t0)
        S.clearHistory(&cleared)
        check(cleared.rules.map(\.key) == [drop] && cleared.seen.isEmpty, "clear history", "evidence goes; a rule the person added stays")
        S.reset(&cleared)
        check(cleared.rules.isEmpty && cleared.tombstones.isEmpty && cleared.applied.isEmpty, "reset", "every rule and its evidence")
    }

    // MARK: The sync, against a fake server

    final class FakeServer: @unchecked Sendable {
        var rules: [S.ServerRule] = []
        var hash = ""
        var enabled = true
        var conflictsLeft = 0
        var maxRules = 20
        var puts: [(rules: [S.ServerRule], enabled: Bool, base: String)] = []
        var gets = 0
        var unreachable = false
        var cap = 20
        func state() -> S.Server { S.Server(available: true, enabled: enabled, serverEnabled: true, rules: rules, hash: hash, maxRules: cap) }
        func put(_ rules: [S.ServerRule], _ enabled: Bool, _ base: String) -> S.PutResult {
            puts.append((rules, enabled, base))
            if unreachable { return S.PutResult() }
            if conflictsLeft > 0 { conflictsLeft -= 1; hash = "99998888"; return S.PutResult(status: 409, server: S.Server(serverHash: hash)) }
            guard base == hash else { return S.PutResult(status: 409, server: S.Server(serverHash: hash)) }
            guard rules.count <= maxRules else { return S.PutResult(status: 413, server: S.Server(reason: "too_long")) }
            self.rules = rules; self.enabled = enabled
            hash = rules.isEmpty ? "" : String(format: "%08x", abs(rules.map(\.id).joined().hashValue) % 0xffffffff)
            return S.PutResult(status: 200, server: state())
        }
    }
    @MainActor static func run(_ ledger: inout S.Ledger, _ server: FakeServer) async -> S.SyncOutcome {
        await S.sync(&ledger, server: server.state(), suggestOnly: false, now: t0,
                     put: { rules, enabled, base in server.put(rules, enabled, base) },
                     get: { server.gets += 1; return server.state() })
    }
    @MainActor static func syncChecks() async {
        var ledger = S.Ledger()
        S.add(&ledger, drop, allowlist: S.defaultAllowlist, now: t0)
        let server = FakeServer()
        let saved = await run(&ledger, server)
        check(saved == .saved(rules: 1, dropped: 0) && server.puts.count == 1 && server.puts[0].base == "" && server.rules.map(\.id) == [drop.id],
              "sync saves", "\(saved)")
        check(server.puts[0].rules[0].kind == "drop_phrase" && server.puts[0].rules[0].register == "all" && server.puts[0].rules[0].param == "honestly"
              && server.puts[0].rules[0].count == 1, "sync codes only", "kind, register, param, count")
        check(ledger.serverHash == server.hash && S.ruleCount(hash: server.hash, in: ledger) == 1, "sync remembers", "the hash names the rules it rendered")
        let again = await run(&ledger, server)
        check(again == .unchanged && server.puts.count == 1, "sync unchanged", "the same rules and switch: nothing sent")
        var second = S.Ledger()
        S.add(&second, drop, allowlist: S.defaultAllowlist, now: t0)
        let same = await run(&second, server)
        check(same == .unchanged && second.serverHash == server.hash && S.ruleCount(hash: server.hash, in: second) == 1, "sync unchanged remembers",
              "a Mac whose rules the server already holds still learns which rules the hash names")
        ledger.enabled = false
        _ = await run(&ledger, server)
        check(server.puts.count == 2 && server.puts[1].enabled == false && server.enabled == false, "sync switch", "the switch alone is a change")
        ledger.enabled = true
        // 409: someone else saved first. Re-read, merge (their rule joins), send again with their hash.
        let other = FakeServer()
        other.rules = [S.ServerRule(id: "drop-frankly", kind: "drop_phrase", register: "all", param: "frankly", count: 2, lastSeen: nil)]
        other.hash = "12345678"
        var stale = S.Ledger()
        S.add(&stale, drop, allowlist: S.defaultAllowlist, now: t0)
        let behind = S.Server(available: true, enabled: true, rules: [], hash: "", maxRules: 20)
        let merged = await S.sync(&stale, server: behind, suggestOnly: false, now: t0,
                                  put: { rules, enabled, base in other.put(rules, enabled, base) },
                                  get: { other.gets += 1; return other.state() })
        check(merged == .saved(rules: 2, dropped: 0) && other.gets == 1 && other.puts.count == 2 && other.puts[1].base == "12345678"
              && Set(other.rules.map(\.id)) == ["drop-frankly", drop.id], "sync 409 merge", "\(merged)")
        // A second 409 in a row is a conflict, never a loop.
        let busy = FakeServer()
        busy.conflictsLeft = 5
        var keep = S.Ledger()
        S.add(&keep, drop, allowlist: S.defaultAllowlist, now: t0)
        let conflict = await run(&keep, busy)
        check(conflict == .conflict && busy.puts.count == 2 && busy.gets == 1, "sync 409 once", "\(conflict) puts \(busy.puts.count)")
        // 413: the lowest-ranked rule goes first, then the rest are sent.
        let small = FakeServer()
        small.maxRules = 2
        var crowded = S.Ledger()
        for (i, phrase) in ["honestly", "frankly", "obviously"].enumerated() {
            crowded.rules.append(S.Rule(kind: .dropPhrase, param: phrase, explicit: true, firstSeen: t0, lastSeen: t0.addingTimeInterval(Double(10 - i))))
        }
        let trimmed = await run(&crowded, small)
        check(trimmed == .saved(rules: 2, dropped: 1) && small.rules.map(\.param) == ["honestly", "frankly"], "sync 413 drop", "\(trimmed) \(small.rules.map(\.param))")
        let capped = FakeServer()
        capped.cap = 1
        var three = crowded
        three.serverHash = nil
        let fitted = await run(&three, capped)
        check(fitted == .saved(rules: 1, dropped: 0) && capped.puts[0].rules.map(\.param) == ["honestly"], "sync server cap", "\(fitted)")
        let down = FakeServer()
        down.unreachable = true
        var waiting = S.Ledger()
        S.add(&waiting, drop, allowlist: S.defaultAllowlist, now: t0)
        let failed = await run(&waiting, down)
        check(failed == .failed("unreachable") && down.puts.count == 1 && waiting.rules.count == 1, "sync unreachable", "the ledger stays on this Mac")
        check(S.needsPush([], enabled: true, server: S.Server(enabled: true, rules: [])) == false
              && S.needsPush(S.serverRules(waiting.rules), enabled: true, server: S.Server(enabled: true, rules: [])), "needs push", "by id, param and switch")
    }

    // MARK: The ledger file

    static func ledgerFileChecks() {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cos-style.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(S.fileName)
        check(S.load(from: url) == S.Ledger(), "ledger missing", "a missing file is an empty ledger")
        var ledger = S.Ledger()
        let typed = "Honestly the quarterly offsite plan for Jordan works."
        let final = "The quarterly offsite plan for Jordan works."
        _ = C.learn(&ledger, evidence: C.Evidence(dictation: UUID(), typed: typed, final: final, baselinePolished: true, complete: true, inputEvents: 2,
                                                  startReanchor: false, app: "Claude", appliedHash: nil), settings: on, now: t0)
        S.remove(&ledger, use.id, now: t0)
        do { try S.save(ledger, to: url) } catch { check(false, "ledger save", "\(error)") }
        check(S.load(from: url) == ledger, "ledger round trip", "the same ledger back")
        let mode = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int) ?? 0
        check(mode == 0o600, "ledger private", "mode \(String(mode, radix: 8))")
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".tmp") }
        check(leftovers.isEmpty, "ledger atomic", "no temp file left: \(leftovers)")
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        for word in ["quarterly", "offsite", "Jordan", "works", "Claude"] {
            check(!raw.contains(word), "ledger never text", "\(word) in the file")
        }
        check(raw.contains("drop_phrase") && raw.contains("honestly") && raw.contains("contractions-use"), "ledger codes", "class codes, the closed param, tombstones")
        try? "not json".write(to: url, atomically: true, encoding: .utf8)
        check(S.load(from: url) == S.Ledger(), "ledger corrupt", "a corrupt file is an empty ledger, never a crash")
    }
}
