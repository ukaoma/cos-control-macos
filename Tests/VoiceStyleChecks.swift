import Foundation

// 0.5.344 part 2, Your style (plan r2 section 2, PLAN_dictation_voice_style_2026-10-24.md), executed against fictional
// fixtures: the ledger file, the classifier and its evidence filters, promotion, retirement, tombstones, ranking, the
// pill once per rule ever, the card's lines, the not-used gate, and DictationStyleController's sync against a fake server
// (409 then merge, 413 then drop, the switch, and every interleaving QA found: a change made during a sync survives it). Compiled with Sources/MacDictationCore.swift alone (Tests/run-voice-style.sh). Nothing is drawn,
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
        gateChecks()
        await controllerChecks()
        await raceChecks()
        ledgerFileChecks()
        print("PASS voice style: \(ran) checks; keys, the classifier, the filters, promotion, retirement, tombstones, ranking, the pill once ever, the lines, the gate, the sync, the races, the ledger file")
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
        let guess = S.Key(kind: .dropPhrase, param: "i guess")
        check(guess.title == "Drop \u{201C}I guess\u{201D}" && guess.id == "drop-i-guess" && guess.param == "i guess" && S.display("you see") == "you see",
              "key titles", "the pronoun I in capitals, the server's phrase unchanged: \(guess.title)")
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
    static let on = C.Settings(enabled: true, learnMode: .automatic, notUsed: nil)
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
        for reason in S.NotUsed.allCases {
            var gated = on; gated.notUsed = reason
            check(C.excluded(evidence(), gated) == reason.rawValue, "filter not used", "nothing is learned while the rules are not used: \(reason)")
        }
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
        // QA W4: whatever made the opposite, Add removes it and keeps it quiet 30 days.
        var learnedAvoid = S.Ledger()
        for _ in 0..<3 { _ = S.observe(&learnedAvoid, dictation: UUID(), observations: [S.Observation(key: avoid)], appliedHash: nil, suggestOnly: false, now: t0) }
        S.add(&learnedAvoid, use, allowlist: S.defaultAllowlist, now: t0)
        check(learnedAvoid.rules.map(\.key) == [use] && S.tombstoned(avoid.id, in: learnedAvoid, now: t0.addingTimeInterval(60)), "add replaces opposite",
              "a learned avoid goes too, and stays quiet")
        _ = S.observe(&learnedAvoid, dictation: UUID(), observations: [S.Observation(key: avoid)], appliedHash: nil, suggestOnly: false, now: t0.addingTimeInterval(60))
        check(learnedAvoid.rules.map(\.key) == [use], "add replaces opposite", "and is not learned back while quiet")
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
        mine.rules = [S.Rule(kind: .contractions, param: "use", explicit: true, firstSeen: t0, lastSeen: t0)]
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
        ledger.rules.append(S.Rule(kind: .contractions, param: "use", explicit: true, firstSeen: t0, lastSeen: t0))
        _ = S.observe(&ledger, dictation: UUID(), observations: [S.Observation(key: avoid)], appliedHash: nil, suggestOnly: false, now: t0)
        _ = S.observe(&ledger, dictation: UUID(), observations: [S.Observation(key: avoid)], appliedHash: nil, suggestOnly: false, now: t0)
        let mixed = S.ranked(ledger, suggestOnly: false, now: t0.addingTimeInterval(100))
        check(mixed.filter { $0.kind == .contractions }.count == 1, "rank one contractions", "the server takes one contractions rule")
        // QA W4: a learned rule never outranks one the person chose, and both are never active.
        var both = S.Ledger()
        both.rules = [S.Rule(kind: .contractions, param: "use", explicit: true, firstSeen: t0, lastSeen: t0),
                      S.Rule(kind: .contractions, param: "avoid", confirmations: [UUID(), UUID(), UUID(), UUID()], firstSeen: t0, lastSeen: t0.addingTimeInterval(9))]
        check(S.ranked(both, suggestOnly: false, now: t0).map(\.key) == [use], "rank chosen first", "the added use wins over a learned avoid with more support")
        check(S.activeIDs(both, suggestOnly: false, now: t0) == [use.id] && S.state(both.rules[1], in: both, suggestOnly: false, now: t0) == .replaced
              && S.state(both.rules[0], in: both, suggestOnly: false, now: t0) == .active, "never both active", "the other one reads as replaced")
        let narrow = S.ranked(ledger, suggestOnly: false, now: t0.addingTimeInterval(100), allowlist: Array(phrases.dropFirst()))
        check(!narrow.contains { $0.param == phrases[0] } && narrow.contains { $0.param == phrases[1] } && narrow.contains { $0.kind == .contractions },
              "rank allowlist", "a phrase the server no longer takes is never sent (QA N9)")
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
        check(S.pillLabel(drop) == "Learned your style: drop \u{201C}honestly\u{201D}" && S.pillLabel(use) == "Learned your style: use contractions"
              && S.pillLabel(S.Key(kind: .dropPhrase, param: "i guess")) == "Learned your style: drop \u{201C}I guess\u{201D}", "pill label", S.pillLabel(drop))
        check(S.isPillLabel(S.pillLabel(drop)) && !S.isPillLabel("EDIT SAVED") && DictationStyleCopy.undoHelp == "Remove this style rule", "pill undo label",
              "the style pill's Undo says what it removes")
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
        check(S.keptLine(guard: "negation") == "Kept as heard: polish changed a negation" && S.keptLine(guard: "date") == "Kept as heard: polish changed a date"
              && S.keptLine(guard: nil) == "Kept as heard" && S.keptLine(guard: "weird") == "Kept as heard", "card kept", "every kind")
        check(S.guardCode("number") == "number" && S.guardCode("guarded") == "guarded" && S.guardCode("drop table") == nil
              && S.styleHash("0a1b2c3d") == "0a1b2c3d" && S.styleHash("0A1B2C3D") == nil, "record codes", "only codes reach the record")
        let round = (try? JSONEncoder().encode(guarded)).flatMap { try? JSONDecoder().decode(DictationRecord.self, from: $0) }
        check(round?.polishGuard == "number" && round?.polishLine(styleRules: 0) == "Kept as heard: polish changed a number", "record guard", "survives the file")
        let marked = DictationHistory.guarding(bare.id, guard: "date", styleHash: "0a1b2c3d", in: [bare])
        check(marked.first?.polishGuard == "date" && marked.first?.polishStyleHash == "0a1b2c3d" && marked.first?.text == "Ship it.", "record guarding", "paste first")
        let edited = DictationHistory.editing(guarded.id, edit: DictationUserEdit(text: "Ship 6 units.", app: "Fixture", at: t0, edits: 1), in: [guarded])
        check(edited.first?.polishGuard == "number", "record guarding", "an edit keeps the guard")
        // QA W1: text the server's own pass cleaned is swapped in as 0.5.343 did, and never called Claude's polish.
        let typed = DictationRecord(id: UUID(), text: "um so the plan works", createdAt: t0, delivery: .inserted(app: "Fixture"))
        let cleaned = DictationHistory.polishing(typed.id, to: "So the plan works.", heard: "um so the plan works", model: "sonnet", prompt: "v4",
                                                 styleHash: "0a1b2c3d", cleaned: "unchanged", in: [typed]).first
        check(cleaned?.polishLine(styleRules: 2) == DictationPolish.cleanedLabel && cleaned?.polishPrompt == nil && cleaned?.heard == "um so the plan works"
              && cleaned?.polishedByClaude == true, "card cleaned", "Cleaned up, never Polished; the model's own answer is still Claude's baseline")
        let tripped = DictationHistory.polishing(typed.id, to: "So the plan works.", heard: "um so the plan works", model: "sonnet",
                                                 cleaned: "failed", in: DictationHistory.guarding(typed.id, guard: "number", styleHash: nil, in: [typed])).first
        check(tripped?.polishLine(styleRules: 0) == "Kept as heard: polish changed a number" && tripped?.polishCleaned == "failed" && tripped?.polishedByClaude == false,
              "card cleaned", "a guard trip swaps the cleaned text in and keeps its word")
        let cleanRound = cleaned.flatMap { try? JSONEncoder().encode($0) }.flatMap { try? JSONDecoder().decode(DictationRecord.self, from: $0) }
        check(cleanRound?.polishCleaned == "unchanged" && DictationPolish.cleanedCode("daily_cap") == "daily_cap" && DictationPolish.cleanedCode("polished") == nil
              && DictationPolish.cleanedCode(nil) == nil, "record cleaned", "the code survives the file, from its closed set")
        let byClaude = DictationRecord(id: UUID(), text: "Hi.", createdAt: t0, delivery: .inserted(app: "Fixture"), heard: "um hi", polishModel: "sonnet")
        check(byClaude.polishedByClaude && !typed.polishedByClaude && !guarded.polishedByClaude
              && !DictationRecord(id: UUID(), text: "Hi.", createdAt: t0, delivery: .inserted(app: "Fixture"), heard: "um hi", polishModel: "sonnet",
                                  polishCleaned: "daily_cap").polishedByClaude, "claude baseline", "style evidence only from Claude's own version")
        // 0.5.343 parity: the model gave its input back after the server's deterministic pass. 0.5.343 read it as applied
        // and swapped; 0.5.344 reads it as cleaned and swaps the same text.
        let heard = "um so the plan works"
        let now344 = DictationPolish.choose(heard: heard, ok: true, text: "So the plan works.", polished: true, reason: nil, polishOutcome: "unchanged")
        let then343 = DictationPolish.choose(heard: heard, ok: true, text: "So the plan works.", polished: true, reason: nil)
        check(now344 == .fillersOnly("unchanged", text: "So the plan works.") && then343 == .applied("So the plan works.")
              && DictationPolishSwap.want(outcome: now344, typed: heard, final: "So the plan works.") == .swap("So the plan works.")
              && DictationPolishSwap.want(outcome: then343, typed: heard, final: "So the plan works.") == .swap("So the plan works."),
              "swap cleaned parity", "the same swap as 0.5.343")
        let guardTrip = DictationPolish.choose(heard: heard, ok: true, text: "So the plan works.", polished: true, reason: nil, skipped: "failed", polishOutcome: "guarded")
        check(DictationPolishSwap.want(outcome: guardTrip, typed: heard, final: "So the plan works.") == .swap("So the plan works.")
              && DictationPolish.cleaned(guardTrip) == "failed" && DictationPolish.cleaned(now344) == "unchanged" && DictationPolish.cleaned(then343) == nil,
              "swap cleaned parity", "a guard trip's cleaned text swaps too, as cleaned")
        check(DictationPolishSwap.want(outcome: .unchanged, typed: heard, final: heard) == .notPolished
              && DictationPolishSwap.want(outcome: .skipped("daily_cap"), typed: heard, final: heard) == .notPolished, "swap cleaned parity", "nothing new: nothing to swap")
        // Settings' words.
        check(DictationStyleCopy.rulesHeading(enabled: false, notUsed: .notSonnet) == (DictationStyleCopy.pausedHeading, DictationStyleCopy.paused)
              && DictationStyleCopy.rulesHeading(enabled: true, notUsed: .notSonnet) == (DictationStyleCopy.notUsedHeading, DictationStyleCopy.notUsedLine(.notSonnet))
              && DictationStyleCopy.rulesHeading(enabled: true, notUsed: nil) == (DictationStyleCopy.active, nil), "copy headings", "Paused, Not used, Active")
        check(DictationStyleCopy.notUsedLine(.notSonnet) == "AI polish is on Haiku, so these rules are not used."
              && DictationStyleCopy.paused.contains("on G2"), "copy headings", "the reason in words")
        check(DictationStyleCopy.status(learnMode: .off, monitor: true, notUsed: nil, enabled: true) == [DictationStyleCopy.needsLearn]
              && DictationStyleCopy.status(learnMode: .automatic, monitor: false, notUsed: nil, enabled: true) == [DictationStyleCopy.needsShortcut]
              && DictationStyleCopy.status(learnMode: .automatic, monitor: false, notUsed: .notSonnet, enabled: true).isEmpty
              && DictationStyleCopy.status(learnMode: .automatic, monitor: true, notUsed: nil, enabled: true).isEmpty, "copy status", "learning's own lines")
        let templates = DictationStyleCopy.templates(allowlist: S.defaultAllowlist)
        check(templates.count == 14 && templates.allSatisfy { $0.valid(allowlist: S.defaultAllowlist) }, "copy templates", "closed templates only")
        let half = S.Rule(kind: .dropPhrase, param: "honestly", confirmations: [UUID()], firstSeen: t0, lastSeen: t0)
        check(DictationStyleCopy.pendingLine(half) == "seen 1 of 2" && DictationStyleCopy.pending == "Not active yet", "copy pending", DictationStyleCopy.pendingLine(half))
        let added = S.Rule(kind: .dropPhrase, param: "honestly", explicit: true, firstSeen: t0, lastSeen: t0)
        check(DictationStyleCopy.detail(added) == "added" && DictationStyleCopy.detail(half) == "seen 1"
              && DictationStyleCopy.detail(S.Rule(kind: .dropPhrase, param: "honestly", confirmations: [UUID(), UUID()], explicit: true, firstSeen: t0, lastSeen: t0))
              == "added, seen 2", "copy detail", "an added rule says added, never seen 1")
        let copy = [DictationStyleCopy.title, DictationStyleCopy.switchTitle, DictationStyleCopy.needsLearn, DictationStyleCopy.empty, DictationStyleCopy.addTitle,
                    DictationStyleCopy.reset, DictationStyleCopy.resetDone, DictationStyleCopy.previousPolish, DictationStyleCopy.previousNote, DictationStyleCopy.setOnServer,
                    DictationStyleCopy.disclosureRules, DictationStyleCopy.disclosureKeys, DictationStyleCopy.needsShortcut, DictationStyleCopy.paused,
                    DictationStyleCopy.undoHelp, DictationStyleCopy.replaced, DictationStyleCopy.notSaved("conflict"), DictationStyleCopy.resetNotSaved("http_500"),
                    DictationStyleCopy.dropped(1), DictationPolish.cleanedLabel, S.pillLabel(drop), S.keptLine(guard: "number")]
            + S.NotUsed.allCases.map(DictationStyleCopy.notUsedLine) + templates.map(\.title)
        for line in copy { check(!line.contains("\u{2014}") && !line.contains("\u{2192}") && !line.contains("->"), "copy plain", line) }
        check(DictationStyleCopy.disclosureRules.contains("never your text") && DictationStyleCopy.disclosureRules.contains("when it polishes with Sonnet")
              && DictationStyleCopy.disclosureRules.contains("Sonnet polish") && DictationStyleCopy.disclosureKeys.contains("never records which keys"),
              "copy disclosure", "the two disclosure lines, true for G2 only on Sonnet")
        check(DictationStyleCopy.previousNote.contains("v4"), "copy previous polish", "Sonnet now uses the new polish")
        var clearing = S.Ledger()
        S.add(&clearing, drop, allowlist: S.defaultAllowlist, now: t0)
        _ = S.observe(&clearing, dictation: UUID(), observations: [S.Observation(key: use)], appliedHash: nil, suggestOnly: false, now: t0)
        S.clearHistory(&clearing)
        check(clearing.rules.map(\.key) == [drop] && clearing.seen.isEmpty, "clear history", "evidence goes; a rule the person added stays")
        clearing.enabled = false
        S.reset(&clearing)
        check(clearing.rules.isEmpty && clearing.tombstones.isEmpty && clearing.applied.isEmpty && clearing.enabled == false, "reset",
              "every rule and its evidence; the switch stays as it was (QA2 W7)")
    }

    // MARK: The not-used gate (QA W3)

    static func gateChecks() {
        check(S.notUsed(model: .sonnet, checked: true, available: true, serverEnabled: true, sonnetPrompt: "v4", envOverride: false) == nil
              && S.notUsed(model: .sonnet, checked: true, available: true, serverEnabled: true, sonnetPrompt: nil, envOverride: false) == nil, "not used",
              "Sonnet, the setting on, the new prompt: the rules apply")
        check(S.notUsed(model: .off, checked: true, available: true, serverEnabled: true, sonnetPrompt: "v4", envOverride: false) == .polishOff, "not used", "polish off")
        check(S.notUsed(model: .haiku, checked: true, available: true, serverEnabled: true, sonnetPrompt: "v4", envOverride: false) == .notSonnet, "not used", "Haiku")
        check(S.notUsed(model: .sonnet, checked: false, available: false, serverEnabled: true, sonnetPrompt: nil, envOverride: false) == .unreachable, "not used",
              "never read the server")
        check(S.notUsed(model: .sonnet, checked: true, available: false, serverEnabled: true, sonnetPrompt: nil, envOverride: false) == .oldServer, "not used", "6.90.0")
        check(S.notUsed(model: .sonnet, checked: true, available: true, serverEnabled: false, sonnetPrompt: "v4", envOverride: false) == .serverOff, "not used",
              "the server's switch")
        check(S.notUsed(model: .sonnet, checked: true, available: true, serverEnabled: true, sonnetPrompt: "v3", envOverride: false) == .previousPolish
              && S.notUsed(model: .sonnet, checked: true, available: true, serverEnabled: true, sonnetPrompt: "v3", envOverride: true) == .serverPrompt,
              "not used", "Previous polish, or the server's environment")
    }

    // MARK: DictationStyleController against a fake server

    /// A 6.91.0 server in memory: the setting's rules and switch, its text hash and its revision (text and switch). A put
    /// can be held mid-flight, so the checks interleave a person's change with a sync.
    @MainActor final class FakeServer {
        var rules: [S.ServerRule] = []
        var enabled = true
        var serverEnabled = true
        var cap = 20
        var allowlist = S.defaultAllowlist
        var conflictsLeft = 0
        var tooLong: Int? = nil
        var putStatus: Int? = nil
        var down = false
        var puts: [(rules: [S.ServerRule]?, enabled: Bool?, base: String?)] = []
        var gets = 0, clears = 0
        var holdNextPut = false
        var held: CheckedContinuation<Void, Never>?
        var hash: String { rules.isEmpty ? "" : Self.hex(rules.map(\.id).sorted().joined(separator: ",")) }
        var revision: String { Self.hex(hash + (enabled ? "1" : "0")) }
        static func hex(_ text: String) -> String { String(format: "%08x", text.unicodeScalars.reduce(UInt32(2166136261)) { ($0 ^ $1.value) &* 16777619 }) }
        func state() -> S.Server {
            S.Server(available: true, enabled: enabled, serverEnabled: serverEnabled, rules: rules, hash: hash, revision: revision,
                     allowlist: allowlist, maxRules: cap)
        }
        func release() { let c = held; held = nil; c?.resume() }
        func call(_ call: DictationStyleController.Call) async -> DictationStyleController.Reply? {
            if down { return nil }
            switch call {
            case .get:
                gets += 1
                return .init(status: 200, server: state())
            case .clear:
                clears += 1
                if let putStatus { return .init(status: putStatus, server: S.Server(reason: putStatus == 404 ? "unavailable" : nil, httpStatus: putStatus)) }
                rules = []
                return .init(status: 200, server: state())
            case .put(let newRules, let newEnabled, let base):
                puts.append((newRules, newEnabled, base))
                if holdNextPut { holdNextPut = false; await withCheckedContinuation { held = $0 } }
                if let putStatus { return .init(status: putStatus, server: S.Server(reason: putStatus == 404 ? "unavailable" : nil, httpStatus: putStatus)) }
                if conflictsLeft > 0 { conflictsLeft -= 1; enabled.toggle(); enabled.toggle(); return .init(status: 409, server: S.Server(reason: "conflict", httpStatus: 409)) }
                // bcdf083: a stale baseRevision is 409 base_revision_mismatch.
                guard base == revision else { return .init(status: 409, server: S.Server(reason: "conflict", httpStatus: 409)) }
                if let tooLong, (newRules ?? rules).count > tooLong { return .init(status: 413, server: S.Server(reason: "too_long", httpStatus: 413)) }
                if let newRules { rules = newRules }
                if let newEnabled { enabled = newEnabled }
                return .init(status: 200, server: state())
            }
        }
    }
    @MainActor static func controller(_ server: FakeServer, ledger: S.Ledger = S.Ledger(), loaded: S.LoadResult = .read) -> (DictationStyleController, Saves) {
        let saves = Saves()
        let ctl = DictationStyleController(ledger: ledger, loaded: loaded)
        ctl.transport = { call in await server.call(call) }
        ctl.persist = { saves.count += 1; saves.last = $0 }
        ctl.now = { t0 }
        ctl.options = .init(promptVersion: "default", sonnetPrompt: "v4", envOverride: false)
        return (ctl, saves)
    }
    @MainActor final class Saves { var count = 0; var last: S.Ledger? }
    @MainActor static func until(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<10_000 where !condition() { await Task.yield() }
        check(condition(), "fixture", "never reached: \(what)")
    }
    static let frankly = S.Key(kind: .dropPhrase, param: "frankly")
    static func rule(_ key: S.Key) -> S.ServerRule { S.ServerRule(id: key.id, kind: key.kind.rawValue, register: "all", param: key.param, count: 1, lastSeen: nil) }

    @MainActor static func controllerChecks() async {
        // Saved, with the revision as the base, codes only.
        let server = FakeServer()
        var (ctl, saves) = controller(server)
        await ctl.load()
        check(ctl.available && ctl.checked && server.puts.isEmpty, "sync unchanged", "an empty ledger and an empty server: nothing sent")
        let firstRevision = server.revision
        await ctl.add(drop)
        check(server.puts.first?.base == firstRevision, "sync base", "every PUT names the revision the GET gave (never baseHash)")
        check(server.puts.count == 1 && server.rules.map(\.id) == [drop.id] && ctl.message == nil, "sync saves", "\(server.puts.count) \(server.rules.map(\.id))")
        let sent = server.puts[0].rules?.first
        check(sent?.kind == "drop_phrase" && sent?.register == "all" && sent?.param == "honestly" && sent?.count == 1, "sync codes only", "kind, register, param, count")
        check(ctl.ruleCount(server.hash) == 1 && saves.count > 0, "sync remembers", "the hash names the rules it rendered")
        await ctl.load()
        check(server.puts.count == 1, "sync unchanged", "the same rules and switch: nothing sent")
        var second = S.Ledger(); S.add(&second, drop, allowlist: S.defaultAllowlist, now: t0)
        let other2: DictationStyleController
        (other2, _) = controller(server, ledger: second)
        await other2.load()
        check(server.puts.count == 1 && other2.ruleCount(server.hash) == 1, "sync unchanged remembers",
              "a Mac whose rules the server already holds still learns which rules the hash names")
        // An older server (6.90.0): available false, the ledger stays on this Mac, nothing sent.
        let old = FakeServer()
        let oldCtl: DictationStyleController
        (oldCtl, _) = controller(old)
        oldCtl.transport = { call in call == .get ? .init(status: 200, server: S.Server(available: false)) : await old.call(call) }
        await oldCtl.load(); await oldCtl.add(drop)
        check(!oldCtl.available && oldCtl.checked && oldCtl.notUsed(model: .sonnet) == .oldServer && old.puts.isEmpty && oldCtl.ledger.rules.count == 1,
              "older server local", "no PUT to a server without the setting")
        // The switch alone: {enabled}, the rules kept on the server.
        await ctl.setEnabled(false)
        check(server.puts.count == 2 && server.puts[1].rules == nil && server.puts[1].enabled == false && server.enabled == false && server.rules.count == 1,
              "switch sends only enabled", "Off keeps the server's rules")
        await ctl.setEnabled(true)
        // 409: re-read, merge into the current ledger, send once more.
        let other = FakeServer(); other.rules = [rule(frankly)]
        (ctl, saves) = controller(other)
        await ctl.load()
        other.rules = [rule(frankly), rule(S.Key(kind: .dropPhrase, param: "obviously"))]
        await ctl.add(drop)
        check(other.gets == 2 && Set(other.rules.map(\.id)) == [frankly.id, "drop-obviously", drop.id] && ctl.ledger.rules.count == 3, "sync 409 merge",
              "\(other.rules.map(\.id))")
        let busy = FakeServer(); busy.conflictsLeft = 5
        (ctl, saves) = controller(busy)
        await ctl.load(); await ctl.add(drop)
        check(busy.puts.count == 2 && ctl.message == DictationStyleCopy.notSaved("conflict"), "sync 409 once", "\(busy.puts.count) \(String(describing: ctl.message))")
        // 413: the lowest-ranked rule goes first.
        let small = FakeServer(); small.tooLong = 2
        var crowded = S.Ledger()
        for (i, phrase) in ["honestly", "frankly", "obviously"].enumerated() {
            crowded.rules.append(S.Rule(kind: .dropPhrase, param: phrase, explicit: true, firstSeen: t0, lastSeen: t0.addingTimeInterval(Double(10 - i))))
        }
        (ctl, saves) = controller(small, ledger: crowded)
        await ctl.load()
        check(small.rules.map(\.param) == ["honestly", "frankly"] && ctl.message == DictationStyleCopy.dropped(1), "sync 413 drop", "\(small.rules.map(\.param))")
        let capped = FakeServer(); capped.cap = 1
        (ctl, saves) = controller(capped, ledger: crowded)
        await ctl.load()
        check(capped.puts.first?.rules?.map(\.param) == ["honestly"], "sync server cap", "\(String(describing: capped.puts.first?.rules?.map(\.param)))")
        // Failures say so, any code; success clears it.
        let failing = FakeServer(); failing.putStatus = 500
        (ctl, saves) = controller(failing)
        await ctl.load(); await ctl.add(drop)
        check(ctl.message == DictationStyleCopy.notSaved("http_500"), "sync failure message", "\(String(describing: ctl.message))")
        failing.putStatus = nil
        await ctl.add(frankly)
        check(failing.rules.count == 2 && ctl.message == nil, "sync failure message", "a later saved PUT clears it")
        // 404 after a rollback to 6.90.0: unavailable, never ok, and the ledger stays on this Mac.
        let rolled = FakeServer()
        (ctl, saves) = controller(rolled)
        await ctl.load(); rolled.putStatus = 404
        await ctl.add(drop)
        check(!ctl.available && ctl.message == DictationStyleCopy.notSaved("unavailable") && ctl.ledger.rules.count == 1, "sync rollback 404", "\(String(describing: ctl.message))")
        // A pending Off: the server cannot be reached, the ledger keeps it, and the next read sends it.
        let away = FakeServer()
        (ctl, saves) = controller(away)
        await ctl.load(); await ctl.add(drop)
        away.down = true
        await ctl.setEnabled(false)
        check(!ctl.ledger.enabled && ctl.unreachable && away.enabled && ctl.message == DictationStyleCopy.notSaved("unreachable"), "pending off",
              "kept on this Mac: \(String(describing: ctl.message))")
        away.down = false
        check(ctl.needsReload, "pending off", "the server's return reads it again")
        await ctl.load()
        check(away.enabled == false && away.rules.count == 1 && !ctl.unreachable, "pending off", "sent when the server is back")
        // Reset: the server's DELETE, the switch kept; a failed DELETE says so.
        let resetting = FakeServer()
        var off = S.Ledger(); off.enabled = false
        (ctl, saves) = controller(resetting, ledger: off)
        await ctl.load(); await ctl.add(drop)
        await ctl.reset()
        check(resetting.clears == 1 && ctl.ledger.rules.isEmpty && ctl.ledger.enabled == false && ctl.message == DictationStyleCopy.resetDone, "reset keeps switch",
              "\(String(describing: ctl.message))")
        await ctl.add(drop)
        resetting.putStatus = 500
        await ctl.reset()
        check(ctl.message == DictationStyleCopy.resetNotSaved("http_500") && ctl.ledger.rules.isEmpty, "reset failure", "\(String(describing: ctl.message))")
        // The gate: nothing learned, promoted or announced unless the rules apply.
        let gate = FakeServer()
        (ctl, saves) = controller(gate)
        let evidenceOf = evidence()
        check(ctl.observe(evidenceOf, model: .sonnet, learnMode: .automatic, instructions: "").isEmpty && ctl.ledger.rules.isEmpty, "gate learning",
              "before the server is read: nothing learned")
        await ctl.load()
        check(ctl.observe(evidence(), model: .haiku, learnMode: .automatic, instructions: "").isEmpty && ctl.ledger.rules.isEmpty, "gate learning", "Haiku learns nothing")
        ctl.options = .init(promptVersion: "v3", sonnetPrompt: "v3", envOverride: false)
        check(ctl.observe(evidence(), model: .sonnet, learnMode: .automatic, instructions: "").isEmpty && ctl.ledger.rules.isEmpty, "gate learning",
              "Previous polish learns nothing")
        ctl.options = .init(promptVersion: "default", sonnetPrompt: "v4", envOverride: false)
        _ = ctl.observe(evidence(), model: .sonnet, learnMode: .automatic, instructions: "")
        let newly = ctl.observe(evidence(), model: .sonnet, learnMode: .automatic, instructions: "")
        check(newly == [drop.id], "gate learning", "Sonnet, the setting on, the new prompt: learned and promoted")
        check(ctl.announce(drop.id, model: .haiku) == nil && ctl.announce(drop.id, model: .sonnet) == drop && ctl.announce(drop.id, model: .sonnet) == nil,
              "gate pill", "no pill where the rules are not used; once ever where they are")
        let serverOff = FakeServer(); serverOff.serverEnabled = false
        (ctl, saves) = controller(serverOff)
        await ctl.load()
        check(ctl.notUsed(model: .sonnet) == .serverOff && ctl.observe(evidence(), model: .sonnet, learnMode: .automatic, instructions: "").isEmpty, "gate learning",
              "the server's switch off")
        // Registers: only the server's flag, never the always-published map.
        var mapped = FakeServer().state(); mapped.registers = ["iTerm2": "literal"]; mapped.registersEnabled = nil
        let mappedServer = FakeServer()
        (ctl, saves) = controller(mappedServer)
        ctl.transport = { call in call == .get ? .init(status: 200, server: mapped) : await mappedServer.call(call) }
        await ctl.load()
        check(!ctl.registersEnabled && ctl.registers == ["iTerm2": "literal"], "registers flag only", "the map alone never turns exclusion on")
        // A ledger that did not read: the server's rules are adopted, never overwritten with an empty list.
        let keeper = FakeServer(); keeper.rules = [rule(frankly)]; keeper.enabled = false
        (ctl, saves) = controller(keeper, ledger: S.Ledger(), loaded: .corrupt(movedTo: "dictation-style.json.corrupt-20261025-120000"))
        check(ctl.adopting, "adopt after a failed load", "the controller knows")
        await ctl.load()
        check(keeper.puts.isEmpty && keeper.rules.map(\.id) == [frankly.id] && ctl.ledger.rules.map(\.id) == [frankly.id] && ctl.ledger.enabled == false && !ctl.adopting,
              "adopt after a failed load", "no PUT [], the server's rules and switch taken")
        await ctl.add(drop)
        check(Set(keeper.rules.map(\.id)) == [frankly.id, drop.id], "adopt after a failed load", "then a change sends both")
        let unmovable = FakeServer(); unmovable.rules = [rule(frankly)]
        (ctl, saves) = controller(unmovable, loaded: .corrupt(movedTo: nil))
        await ctl.load(); await ctl.add(drop)
        check(ctl.readOnly && saves.count == 0 && Set(unmovable.rules.map(\.id)) == [frankly.id, drop.id], "read only ledger",
              "a file that could not be moved aside is never written over")
        let fresh = FakeServer(); fresh.rules = [rule(frankly)]
        (ctl, saves) = controller(fresh, loaded: .missing)
        await ctl.load()
        check(fresh.puts.isEmpty && ctl.ledger.rules.map(\.id) == [frankly.id], "adopt after a failed load", "no file at all adopts too")
    }

    // MARK: Interleavings (QA2 W2, QA3 W1, QA4 W7): a change made during a sync survives it

    @MainActor static func raceChecks() async {
        // QA2's: Add X starts PUT A; Remove X while A is in flight; A lands. X never comes back, its tombstone stays, and
        // the rerun takes it off the server.
        let server = FakeServer()
        var (ctl, _) = controller(server)
        await ctl.load()
        server.holdNextPut = true
        let adding = Task { await ctl.add(drop) }
        await until("PUT A in flight") { server.held != nil }
        await ctl.remove(drop.id)
        server.release()
        await adding.value
        check(ctl.ledger.rules.isEmpty && S.tombstoned(drop.id, in: ctl.ledger, now: t0), "race remove during put", "\(ctl.ledger.rules.map(\.id))")
        check(server.rules.isEmpty && server.puts.count == 2, "race remove during put", "the rerun removed it: \(server.rules.map(\.id)) puts \(server.puts.count)")
        // The switch flipped Off while a PUT is in flight stays Off, and reaches the server.
        server.holdNextPut = true
        let adding2 = Task { await ctl.add(frankly) }
        await until("PUT in flight") { server.held != nil }
        await ctl.setEnabled(false)
        server.release()
        await adding2.value
        check(!ctl.ledger.enabled && !server.enabled && server.rules.map(\.id) == [frankly.id], "race switch during put", "enabled \(ctl.ledger.enabled) server \(server.enabled)")
        // Reset during a sync: the rules stay gone, here and on the server.
        await ctl.setEnabled(true)
        server.holdNextPut = true
        let adding3 = Task { await ctl.add(drop) }
        await until("PUT in flight") { server.held != nil }
        let resetting = Task { await ctl.reset() }
        await until("reset sent") { server.clears == 1 }
        server.release()
        await adding3.value; await resetting.value
        check(ctl.ledger.rules.isEmpty && server.rules.isEmpty, "race reset during put", "here \(ctl.ledger.rules.map(\.id)) server \(server.rules.map(\.id))")
        // Two quick Removes during a sync both keep their tombstones; a pill announced meanwhile stays announced.
        let two = FakeServer()
        var both = S.Ledger()
        both.rules = [S.Rule(kind: .dropPhrase, param: "honestly", explicit: true, firstSeen: t0, lastSeen: t0),
                      S.Rule(kind: .dropPhrase, param: "frankly", explicit: true, firstSeen: t0, lastSeen: t0),
                      S.Rule(kind: .dropPhrase, param: "obviously", explicit: true, firstSeen: t0, lastSeen: t0)]
        (ctl, _) = controller(two, ledger: both)
        two.holdNextPut = true
        let loading = Task { await ctl.load() }
        await until("first PUT in flight") { two.held != nil }
        await ctl.remove(drop.id)
        await ctl.remove(frankly.id)
        check(ctl.announce("drop-obviously", model: .sonnet) != nil, "race announce during put", "announced while the PUT is in flight")
        two.release()
        await loading.value
        check(S.tombstoned(drop.id, in: ctl.ledger, now: t0) && S.tombstoned(frankly.id, in: ctl.ledger, now: t0) && ctl.ledger.rules.map(\.id) == ["drop-obviously"],
              "race two removes", "\(ctl.ledger.rules.map(\.id)) \(ctl.ledger.tombstones.map(\.id))")
        check(ctl.ledger.announced == ["drop-obviously"], "race announce during put", "\(ctl.ledger.announced)")
        check(two.rules.map(\.id) == ["drop-obviously"], "race two removes", "the rerun sends what is left: \(two.rules.map(\.id))")
        // A 409 merge during which the person removed a rule the server still holds never brings it back.
        let merging = FakeServer(); merging.rules = [rule(frankly)]
        (ctl, _) = controller(merging)
        await ctl.load()
        merging.rules = [rule(frankly), rule(S.Key(kind: .dropPhrase, param: "obviously"))]
        merging.holdNextPut = true
        let adding4 = Task { await ctl.add(drop) }
        await until("PUT in flight") { merging.held != nil }
        await ctl.remove("drop-obviously")
        merging.release()
        await adding4.value
        check(!ctl.ledger.rules.contains { $0.id == "drop-obviously" } && !merging.rules.contains { $0.id == "drop-obviously" }, "race merge after remove",
              "here \(ctl.ledger.rules.map(\.id)) server \(merging.rules.map(\.id))")
    }

    // MARK: The ledger file

    static func ledgerFileChecks() {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cos-style.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(S.fileName)
        let missing = S.load(from: url, now: t0)
        check(missing.ledger == S.Ledger() && missing.result == .missing, "ledger missing", "a missing file is an empty ledger, and says so")
        var ledger = S.Ledger()
        let typed = "Honestly the quarterly offsite plan for Jordan works."
        let final = "The quarterly offsite plan for Jordan works."
        _ = C.learn(&ledger, evidence: C.Evidence(dictation: UUID(), typed: typed, final: final, baselinePolished: true, complete: true, inputEvents: 2,
                                                  startReanchor: false, app: "Claude", appliedHash: nil), settings: on, now: t0)
        S.remove(&ledger, use.id, now: t0)
        do { try S.save(ledger, to: url) } catch { check(false, "ledger save", "\(error)") }
        let back = S.load(from: url, now: t0)
        check(back.ledger == ledger && back.result == .read, "ledger round trip", "the same ledger back")
        let mode = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int) ?? 0
        check(mode == 0o600, "ledger private", "mode \(String(mode, radix: 8))")
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".tmp") }
        check(leftovers.isEmpty, "ledger atomic", "no temp file left: \(leftovers)")
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        for word in ["quarterly", "offsite", "Jordan", "works", "Claude"] {
            check(!raw.contains(word), "ledger never text", "\(word) in the file")
        }
        check(raw.contains("drop_phrase") && raw.contains("honestly") && raw.contains("contractions-use"), "ledger codes", "class codes, the closed param, tombstones")
        // Every field reads with a default (QA2 W8, QA4 W8): an older file without the newer fields, a newer file with
        // fields this build does not know, and one bad rule among good ones all load what they can.
        let partial = #"{"rules":[{"kind":"drop_phrase","param":"honestly","explicit":true},{"kind":"tone","param":"x"},{"kind":"contractions","param":"use","lastSeen":"soon"}],"future":7}"#
        try? partial.write(to: url, atomically: true, encoding: .utf8)
        let lossy = S.load(from: url, now: t0)
        check(lossy.result == .read && lossy.ledger.enabled && lossy.ledger.rules.map(\.id) == [drop.id, use.id] && lossy.ledger.rules[0].explicit
              && lossy.ledger.announced.isEmpty, "ledger lossy", "\(lossy.ledger.rules.map(\.id))")
        // A file that does not read is moved aside, never overwritten.
        try? "not json".write(to: url, atomically: true, encoding: .utf8)
        let corrupt = S.load(from: url, now: t0)
        let moved: String? = if case .corrupt(let name) = corrupt.result { name } else { nil }
        check(corrupt.ledger == S.Ledger() && moved?.hasPrefix(S.fileName + ".corrupt-") == true && !FileManager.default.fileExists(atPath: url.path)
              && FileManager.default.fileExists(atPath: folder.appendingPathComponent(moved ?? "x").path), "ledger corrupt", "moved aside as \(String(describing: moved))")
    }
}
