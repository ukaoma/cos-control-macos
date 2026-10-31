import Foundation

/// 0.5.357 (server 6.96.3): the Speakers display hint and Suggest names, as rules. Models.swift alone, so nothing here can open a
/// window. Each failure names its behaviour as "check failed [<behaviour>]" for Tests/mutate-voice-display.py. All names, labels
/// and words are invented.
@main struct VoiceDisplayChecks {
    nonisolated(unsafe) static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ behaviour: String, _ detail: @autoclosure () -> String = "") {
        checks += 1
        if !condition() {
            print("check failed [\(behaviour)]: \(detail())")
            exit(1)
        }
    }
    static func json(_ o: Any) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: o)) }
    static let sid = "mac_11111111-1111-4111-8111-111111111111"
    static let revA = String(repeating: "a", count: 64), revB = String(repeating: "b", count: 64)

    static func voice(_ label: String, segments: Int = 1, named: Bool = false, reliability: String = "unattributed") -> [String: Any] {
        ["label": label, "segments": segments, "speakingMs": 0, "nameAsserted": named, "reliability": reliability]
    }
    static func hint(groups: [[String: Any]] = [], singles: [[String: Any]] = [], short: [[String: Any]] = []) -> [String: Any] {
        ["source": "speaker-shadow", "recordedAt": "2026-10-30T16:09:00Z", "foldUnderSeconds": 15, "groups": groups, "singles": singles, "short": short]
    }
    static func group(_ id: String, _ labels: [String], _ seconds: Any = NSNull()) -> [String: Any] { ["id": id, "labels": labels, "seconds": seconds] }
    static func single(_ label: String, _ seconds: Any = NSNull()) -> [String: Any] { ["label": label, "seconds": seconds] }
    static func short(_ label: String, _ seconds: Any) -> [String: Any] { ["label": label, "seconds": seconds] }
    static func base(_ voices: [[String: Any]], hint: [String: Any]? = nil, extra: [String: Any] = [:]) -> [String: Any] {
        var o: [String: Any] = ["sessionId": sid, "recordId": "ops:quilt:2026-10:fixture.md", "sourceRevision": revA, "reviewIdentityVersion": 1,
                                "segments": 783, "attributed": false, "mutable": true, "voices": voices]
        if let hint { o["voiceDisplay"] = hint }
        o.merge(extra) { _, new in new }
        return o
    }
    static func review(_ o: [String: Any]) -> SpeakerReview { SpeakerReview(json(o))! }
    /// Every row in reading order, members included.
    static func flat(_ layout: VoiceDisplayLayout) -> [String] {
        layout.rows.flatMap { row -> [String] in
            switch row {
            case .merged(let merged): return merged.labels
            case .voice(let voice): return [voice.label]
            }
        } + layout.short.map(\.label)
    }
    static func tops(_ layout: VoiceDisplayLayout) -> [String] {
        layout.rows.map { row in
            switch row {
            case .merged(let merged): return merged.title
            case .voice(let voice): return voice.label
            }
        }
    }

    static func main() {
        absent()
        order()
        everyCombination()
        ignored()
        packet()
        merged()
        naming()
        suggestionsParse()
        suggestionsSurface()
        outcome()
        refusal()
        batchCandidates()
        batchResults()
        batchUndo()
        reviewFixes()
        contract(CommandLine.arguments[1])
        print("PASS: \(checks) voice display checks")
    }

    nonisolated(unsafe) static let roster: [[String: Any]] = [voice("Voice 1", segments: 9), voice("Voice 2", segments: 8), voice("Voice 3", segments: 7), voice("Voice 4", segments: 6),
                                          voice("Voice 5", segments: 5), voice("Voice 6", segments: 4), voice("Ext", segments: 90),
                                          voice("Dana Reyes", segments: 3, named: true, reliability: "confident")]

    static func absent() {
        let plain = review(base(roster))
        check(plain.voiceDisplay == nil && plain.voiceDisplayLayout == nil, "absent is nil")
        check(plain.displayVoiceRows.main == plain.voicesForReview, "absent order")
        check(plain.displayVoiceRows.shortFragments.isEmpty, "absent order")
        check(plain.inventoryHeader == "783 segments · 8 voices", "absent header", plain.inventoryHeader)
        // A malformed field is the same as no field.
        let good = hint(groups: [group("a", ["Voice 1", "Voice 2"], 30)])
        var wrongSource = good; wrongSource["source"] = "packet"
        var wrongFold = good; wrongFold["foldUnderSeconds"] = 30
        var fractionFold = good; fractionFold["foldUnderSeconds"] = 15.5
        var noDate = good; noDate.removeValue(forKey: "recordedAt")
        var emptyDate = good; emptyDate["recordedAt"] = ""
        var notArray = good; notArray["groups"] = "x"
        var noSingles = good; noSingles.removeValue(forKey: "singles")
        var noShort = good; noShort.removeValue(forKey: "short")
        for (name, bad) in [("source", wrongSource), ("fold", wrongFold), ("fraction fold", fractionFold), ("no date", noDate), ("empty date", emptyDate),
                            ("not array", notArray), ("no singles", noSingles), ("no short", noShort)] {
            let parsed = review(base(roster, hint: bad))
            check(parsed.voiceDisplayLayout == nil, "malformed hint is absent", name)
            check(parsed.displayVoiceRows.main == parsed.voicesForReview, "malformed hint is absent", name)
        }
        // A G2 meeting never takes the hint.
        var g2 = base(roster, hint: good); g2["sessionId"] = "meeting_g2_fixture"
        check(review(g2).voiceDisplay == nil && review(g2).voiceDisplayLayout == nil, "mac only")
        // A hint with no usable label leaves every row where it was.
        let unused = review(base(roster, hint: hint(groups: [group("x", ["Voice 90", "Voice 91"], 500)], singles: [single("Voice 92", 100)], short: [short("Voice 93", 3)])))
        check(flat(unused.voiceDisplayLayout!) == unused.voicesForReview.map(\.label), "unused hint keeps today's order")
        check(unused.voiceDisplayLayout!.short.isEmpty, "unused hint keeps today's order")
    }

    static func order() {
        let o = base(roster, hint: hint(
            groups: [group("small", ["Voice 1", "Voice 2"], 40), group("large", ["Voice 3", "Voice 4"], 400)],
            singles: [single("Voice 5", 20)], short: [short("Voice 6", 4)]))
        let layout = review(o).voiceDisplayLayout!
        check(tops(layout) == ["Voice 3 and 1 more", "Voice 1 and 1 more", "Voice 5", "Ext", "Dana Reyes"], "order", "\(tops(layout))")
        check(layout.short.map(\.label) == ["Voice 6"], "order short")
        check(layout.visibleRowCount == 6, "row count")
        check(review(o).inventoryHeader == "783 segments · 8 voice labels in 6 rows", "hint header", review(o).inventoryHeader)
        // Unknown totals sort after known ones, and among themselves by how many labels they hold.
        let mixed = review(base(roster, hint: hint(groups: [group("few", ["Voice 1", "Voice 2"]), group("many", ["Voice 3", "Voice 4", "Voice 5"])]))).voiceDisplayLayout!
        check(tops(mixed).prefix(2) == ["Voice 3 and 2 more", "Voice 1 and 1 more"], "unknown totals", "\(tops(mixed))")
        let timed = review(base(roster, hint: hint(groups: [group("few", ["Voice 1", "Voice 2"]), group("timed", ["Voice 3", "Voice 4"], 1), group("many", ["Voice 5", "Voice 6"])]))).voiceDisplayLayout!
        check(tops(timed).first == "Voice 3 and 1 more", "known total beats unknown", "\(tops(timed))")
        // Singles: longest first, unknown last.
        let singles = review(base(roster, hint: hint(singles: [single("Voice 1"), single("Voice 2", 30), single("Voice 3", 90)]))).voiceDisplayLayout!
        check(tops(singles).prefix(3) == ["Voice 3", "Voice 2", "Voice 1"], "singles order", "\(tops(singles))")
        // The rest keep today's relative order, and a voice the hint does not mention stays in the main list.
        let some = review(base(roster, hint: hint(singles: [single("Voice 2", 30)])))
        let someLayout = some.voiceDisplayLayout!
        check(tops(someLayout).first == "Voice 2", "unmentioned stays main")
        check(tops(someLayout).dropFirst() == ArraySlice(some.voicesForReview.map(\.label).filter { $0 != "Voice 2" }), "unmentioned stays main", "\(tops(someLayout))")
        // Short voices: longest first.
        let fold = review(base(roster, hint: hint(short: [short("Voice 1", 2), short("Voice 2", 14.9), short("Voice 3", 8)]))).voiceDisplayLayout!
        check(fold.short.map(\.label) == ["Voice 2", "Voice 3", "Voice 1"], "short order", "\(fold.short.map(\.label))")
        // At or over the floor is not short, whatever the server said.
        let notShort = review(base(roster, hint: hint(short: [short("Voice 1", 15), short("Voice 2", 40), short("Voice 3", 14.5), short("Voice 4", "soon"), short("Voice 5", -1)]))).voiceDisplayLayout!
        check(notShort.short.map(\.label) == ["Voice 3"], "short floor", "\(notShort.short.map(\.label))")
        check(flat(notShort).count == roster.count, "short floor")
        // The real call's shape: about 11 main rows and a fold of 24.
        var many: [[String: Any]] = [voice("Ext", segments: 400), voice("Avery Stone", segments: 40, named: true, reliability: "confident"), voice("Blake Moss", segments: 30, named: true, reliability: "confident")]
        for n in 1...58 { many.append(voice("Voice \(n)", segments: 60 - n)) }
        let groups = [group("g1", (1...13).map { "Voice \($0)" }, 900), group("g2", (14...20).map { "Voice \($0)" }, 300), group("g3", (21...24).map { "Voice \($0)" }, 200), group("g4", (25...27).map { "Voice \($0)" }, 90)]
        let singleRows = (28...34).map { single("Voice \($0)", Double(200 - $0)) }
        let shortRows = (35...58).map { short("Voice \($0)", Double($0 % 14) + 0.5) }
        let call = review(base(many, hint: hint(groups: groups, singles: singleRows, short: shortRows)))
        let callLayout = call.voiceDisplayLayout!
        check(callLayout.rows.count == 14 && callLayout.short.count == 24, "real shape", "\(callLayout.rows.count) \(callLayout.short.count)")
        check(callLayout.rows.prefix(4).map(\.id) == ["group:g1", "group:g2", "group:g3", "group:g4"], "real shape")
        check(Set(flat(callLayout)) == Set(many.map { $0["label"] as! String }) && flat(callLayout).count == many.count, "real shape")
        check(VoiceDisplayCopy.shortVoices(callLayout.short.count) == "Short voices (24)", "fold title")
    }

    /// Every voice appears exactly once, however the hint places it: alone, in either group, in singles, in short, twice, three times, nowhere.
    static func everyCombination() {
        let labels = ["Voice 1", "Voice 2", "Voice 3", "Ext", "Dana Reyes"]
        let voices: [[String: Any]] = [voice("Voice 1"), voice("Voice 2"), voice("Voice 3"), voice("Ext"), voice("Dana Reyes", named: true, reliability: "confident")]
        // Bit per place: group a, group b, singles, short. Nowhere, each place alone, two places, and all four.
        let places = [0, 1, 2, 4, 8, 1 | 8, 15]
        var combos = 0
        for a in places { for b in places { for c in places { for d in places { for e in places {
            let picks = [a, b, c, d, e]
            func holding(_ bit: Int) -> [String] { zip(labels, picks).filter { $0.1 & bit != 0 }.map(\.0) }
            let h = hint(groups: [group("a", holding(1) + ["Voice 99"], 10), group("b", holding(2), 20)],
                         singles: holding(4).map { single($0, 5) }, short: holding(8).map { short($0, 3) })
            let parsed = review(base(voices, hint: h))
            let shown = flat(parsed.voiceDisplayLayout!)
            combos += 1
            guard shown.count == labels.count, Set(shown) == Set(labels) else {
                check(false, "exactly once", "\(picks): \(shown)"); return
            }
            // Ext and named rows never join a group or the fold.
            guard !parsed.voiceDisplayLayout!.short.contains(where: { !MacVoiceLabel.isVoice($0.label) }) else {
                check(false, "named never folded", "\(picks)"); return
            }
        } } } } }
        check(combos == 16_807, "exactly once", "\(combos)")
    }

    static func ignored() {
        // An unknown label is ignored, and it takes the server's total with it because that total counted it.
        let partly = review(base(roster, hint: hint(groups: [group("g", ["Voice 1", "Voice 98", "Voice 2"], 300)]))).voiceDisplayLayout!
        guard case .merged(let row)? = partly.rows.first else { check(false, "unknown ignored"); return }
        check(row.labels == ["Voice 1", "Voice 2"], "unknown ignored", "\(row.labels)")
        check(row.seconds == nil && row.timeText == nil, "stale total dropped", "\(String(describing: row.seconds))")
        // One label left is a single row, not a group of one.
        let one = review(base(roster, hint: hint(groups: [group("g", ["Voice 1", "Voice 98"], 300)]))).voiceDisplayLayout!
        check(tops(one).first == "Voice 1", "group of one is a row", "\(tops(one))")
        check(!one.rows.contains { if case .merged = $0 { return true } else { return false } }, "group of one is a row")
        // Ext and a named row stay where they sit, even when the hint lists them.
        let listed = review(base(roster, hint: hint(groups: [group("g", ["Ext", "Dana Reyes", "Voice 1", "Voice 2"], 300)], singles: [single("Ext", 900)], short: [short("Dana Reyes", 3)]))).voiceDisplayLayout!
        check(listed.short.isEmpty, "named never folded")
        guard case .merged(let held)? = listed.rows.first else { check(false, "ext and names keep their place"); return }
        check(held.labels == ["Voice 1", "Voice 2"], "ext and names keep their place", "\(held.labels)")
        let today = review(base(roster)).voicesForReview.map(\.label).filter { !["Voice 1", "Voice 2"].contains($0) }
        check(Array(tops(listed).dropFirst()) == today, "ext and names keep their place", "\(tops(listed))")
        // A label listed twice lands once, at its first place.
        let twice = review(base(roster, hint: hint(groups: [group("g", ["Voice 1", "Voice 2", "Voice 1"], 300)], singles: [single("Voice 2", 1)], short: [short("Voice 1", 2)]))).voiceDisplayLayout!
        check(flat(twice).filter { $0 == "Voice 1" }.count == 1 && flat(twice).filter { $0 == "Voice 2" }.count == 1, "duplicates land once", "\(flat(twice))")
        // Two rows with one label could not be placed exactly once, so the plain list stays.
        let doubled = review(base(roster + [voice("Voice 1")], hint: hint(singles: [single("Voice 1", 1)])))
        check(doubled.voiceDisplayLayout == nil, "repeated label falls back")
        // Two groups with one id keep separate rows.
        let sameId = review(base(roster, hint: hint(groups: [group("g", ["Voice 1", "Voice 2"], 9), group("g", ["Voice 3", "Voice 4"], 5)]))).voiceDisplayLayout!
        check(Set(sameId.rows.map(\.id)).count == sameId.rows.count, "row ids unique", "\(sameId.rows.map(\.id))")
        // Malformed rows drop, and their voices stay main.
        let malformed = review(base(roster, hint: hint(groups: [["id": "g"], ["labels": ["Voice 1", "Voice 2"]], ["id": "", "labels": ["Voice 1", "Voice 2"]], group("e", [])], singles: [["seconds": 3]]))).voiceDisplayLayout!
        check(flat(malformed).sorted() == roster.map { $0["label"] as! String }.sorted(), "malformed rows dropped", "\(flat(malformed))")
        check(!malformed.rows.contains { if case .merged = $0 { return true } else { return false } }, "malformed rows dropped")
        // A time that is not a number is unknown, never zero.
        let badTime = review(base(roster, hint: hint(groups: [group("g", ["Voice 1", "Voice 2"], "long")], singles: [single("Voice 3", -4)]))).voiceDisplayLayout!
        guard case .merged(let untimed)? = badTime.rows.first else { check(false, "bad time is unknown"); return }
        check(untimed.seconds == nil && badTime.seconds["Voice 3"] == nil, "bad time is unknown")
    }

    /// When a packet applies, Codex's list stands, whatever the hint says.
    static func packet() {
        let h = hint(singles: [single("Anonymous group 1", 300)], short: [short("Voice 1", 3)])
        let anon: [String: Any] = ["label": "Anonymous group 1", "kind": "anonymous-group", "identityId": "fluid256_fixture", "nameAsserted": false, "reliability": "unattributed", "speakingMs": 1800, "wordCount": 5]
        let summary: [String: Any] = ["version": 1, "basis": "source-bound-hq-words", "anonymousGroupCount": 1, "preservedAnonymousGroupCount": 0, "namedVoiceCount": 0, "withheldNameCount": 0, "unresolvedSpeakingMs": 0, "unresolvedWordCount": 0, "displayRowCount": 1]
        let withSummary = review(base([anon], hint: h, extra: ["effectiveSpeakerSummary": summary]))
        check(withSummary.effectiveSpeakerSummary != nil, "packet leaves the list alone", "fixture needs a summary")
        check(withSummary.voiceDisplayLayout == nil, "packet leaves the list alone")
        check(withSummary.inventoryHeader == "1 estimated group", "packet leaves the list alone", withSummary.inventoryHeader)
        // The summary's interval metadata without a valid summary is still a packet.
        let partial = review(base(roster, hint: h, extra: ["intervalGroupScopes": []]))
        check(partial.intervalViewReadOnly && partial.voiceDisplayLayout == nil, "interval metadata leaves the list alone")
        // An older applied view, not an interval one.
        let applied = review(base(roster, hint: h, extra: ["speakerCallView": ["status": "applied", "mode": "anonymous-estimate"]]))
        check(!applied.intervalViewReadOnly && applied.voiceDisplayLayout == nil, "applied view leaves the list alone")
        check(applied.inventoryHeader == "783 segments · 8 voices", "applied view leaves the list alone")
        let baseView = review(base(roster, hint: h, extra: ["speakerCallView": ["status": "base", "mode": "strict"]]))
        check(baseView.voiceDisplayLayout != nil, "base view takes the hint")
    }

    static func merged() {
        let layout = review(base(roster, hint: hint(groups: [group("g", ["Voice 5", "Voice 1", "Voice 2", "Voice 3"], 125.4)]))).voiceDisplayLayout!
        guard case .merged(let row)? = layout.rows.first else { check(false, "merged title"); return }
        check(row.title == "Voice 5 and 3 more", "merged title", row.title)
        check(row.timeText == "2m 5s", "merged time", row.timeText ?? "nil")
        check(row.members.map(\.label) == ["Voice 5", "Voice 1", "Voice 2", "Voice 3"], "members in the server's order")
        check(VoiceDisplayCopy.duration(59.6) == "1m 0s", "duration rounds", VoiceDisplayCopy.duration(59.6))
        check(VoiceDisplayCopy.duration(0) == "0m 0s", "duration rounds")
        let copy = [VoiceDisplayCopy.machineGrouping, VoiceDisplayCopy.groupNoteOwnRows, VoiceDisplayCopy.suggestionsOnly, VoiceDisplayCopy.noSuggestions, VoiceDisplayCopy.staleSuggestions,
                    VoiceDisplayCopy.didNotFinish, VoiceDisplayCopy.didNotRun, VoiceDisplayCopy.refusal("recording_active"), VoiceDisplayCopy.progress(done: 1, total: 2), VoiceDisplayCopy.suggested(2)]
        for line in copy {
            check(!line.contains("\u{2014}") && !line.contains("\u{2192}") && !line.contains(" -> "), "copy has no em dash or arrow", line)
            check(!line.lowercased().contains("identified") && !line.lowercased().contains("people") && !line.lowercased().contains("person"), "copy never asserts identity", line)
        }
    }

    static func naming() {
        let row = VoiceDisplayLayout.MergedRow(id: "group:g", members: review(base(roster)).voices.filter { ["Voice 1", "Voice 2"].contains($0.label) }, seconds: 10)
        check(review(base(roster, hint: hint())).canNameTogether(row), "plain rows name together")
        check(!review(base(roster, hint: hint(), extra: ["mutable": false])).canNameTogether(row), "read-only never names together")
        var g2 = base(roster, hint: hint()); g2["sessionId"] = "meeting_g2_fixture"
        check(!review(g2).canNameTogether(row), "mac only naming")
        // A member on an exact-segment path keeps it.
        let member: [String: Any] = ["rawChunkIndex": 1, "position": 0, "before": "Voice 1", "text": "invented", "elapsedMs": 1]
        let scope: [String: Any] = ["identityId": "human_fixture", "displayLabel": "Voice 1", "scopeSHA256": revB, "members": [member], "fieldCount": 1, "reviewBasis": "automatic-label-only"]
        let scoped = review(base(roster, hint: hint(), extra: ["groupScopes": [scope]]))
        check(scoped.groupScopes.count == 1, "scoped member keeps its path", "fixture needs a scope")
        check(!scoped.canNameTogether(row), "scoped member keeps its path")
        // Only an unnamed Voice N, so a row with Ext or a name cannot be named together.
        let other = VoiceDisplayLayout.MergedRow(id: "group:h", members: review(base(roster)).voices.filter { ["Voice 1", "Dana Reyes"].contains($0.label) }, seconds: nil)
        check(!review(base(roster, hint: hint())).canNameTogether(other), "only voice labels name together")
        // The plan's flags: the single row's rule, and never a forced assignment.
        let ready: [String: Any] = ["person": "Dana Reyes", "enrolled": 4, "attempted": 4, "groupSize": 4, "groupSec": 30, "similarity": 0.8, "gates": []]
        let flagged: [String: Any] = ["person": "Dana Reyes", "enrolled": 4, "attempted": 4, "groupSize": 4, "groupSec": 30, "similarity": 0.3, "belowFloor": true, "gates": ["below_floor"]]
        func correction(_ from: String, _ enrolment: [String: Any]?) -> PendingCorrection {
            PendingCorrection(from: from, to: "Dana Reyes", scope: .thisMeeting, message: "", surfaces: CorrectionSurfaces(json(["sidecar": 2, "transcript": 3])), similarity: nil, refused: false, forceable: false,
                              proseStale: false, isNameAssignment: true, createsProfile: false, wouldRetract: 0, untraceable: 0,
                              macAssignment: enrolment.flatMap { MacVoiceAssignment(json($0)) })
        }
        let plan = PendingVoiceGroupName(rowId: "group:g", sessionId: sid, recordId: "r", revision: revA, to: "Dana Reyes", corrections: [correction("Voice 1", ready), correction("Voice 2", flagged), correction("Voice 3", nil)])
        check(plan.saveFlags(for: plan.corrections[0]) == ["--assign-voice-profile"], "unflagged adds samples")
        check(plan.saveFlags(for: plan.corrections[1]) == [], "flagged stays text only", "\(plan.saveFlags(for: plan.corrections[1]))")
        check(plan.saveFlags(for: plan.corrections[2]) == [], "typed stays text only")
        check(plan.labelsAddingSamples == 1 && plan.labelsFlagged == 1, "plan counts", "\(plan.labelsAddingSamples) \(plan.labelsFlagged)")
        check(plan.segments == 6 && plan.transcriptLines == 9, "plan counts")
        check(plan.title == "Name 3 voice labels \u{201C}Dana Reyes\u{201D}?", "plan title", plan.title)
        check(plan.assignmentRequested, "plan counts")
    }

    static func job(_ state: String, revision: String? = revA, suggestions: [[String: Any]] = [], extra: [String: Any] = [:]) -> [String: Any] {
        var o: [String: Any] = ["state": state, "rule": ["floor": 0.7, "margin": 0.05], "modelSpace": "192d", "suggestions": suggestions]
        if let revision { o["sourceRevision"] = revision }
        o.merge(extra) { _, new in new }
        return o
    }
    static func suggestion(_ labels: [String], _ name: String = "Dana Reyes", score: Any = 0.82, margin: Any = 0.11, extra: [String: Any] = [:]) -> [String: Any] {
        var o: [String: Any] = ["labels": labels, "name": name, "score": score, "margin": margin, "units": 12, "kept": 10, "requiresConfirmation": true]
        o.merge(extra) { _, new in new }
        return o
    }

    static func suggestionsParse() {
        func parsed(_ s: [String: Any]) -> [VoiceNameSuggestion] { VoiceSuggestionJob(json(job("done", suggestions: [s])))!.suggestions }
        check(parsed(suggestion(["Voice 1", "Voice 2"])).first?.labels == ["Voice 1", "Voice 2"], "suggestion parses")
        check(parsed(suggestion(["Ext"])).isEmpty, "no ext suggestions")
        check(parsed(suggestion(["Voice 1", "Ext"])).isEmpty, "no ext suggestions")
        check(parsed(suggestion(["Dana Reyes"])).isEmpty, "only voice labels suggested")
        check(parsed(suggestion(["Voice 1", "Voice 1"])).isEmpty, "suggestion labels unique")
        check(parsed(suggestion([])).isEmpty, "suggestion needs labels")
        check(parsed(suggestion(["Voice 1"], extra: ["requiresConfirmation": false])).isEmpty, "suggestion must require confirmation")
        var bare = suggestion(["Voice 1"]); bare.removeValue(forKey: "requiresConfirmation")
        check(parsed(bare).isEmpty, "suggestion must require confirmation")
        check(parsed(suggestion(["Voice 1"], "Voice 9")).isEmpty, "suggestion name is a name")
        check(parsed(suggestion(["Voice 1"], "Ext")).isEmpty, "suggestion name is a name")
        check(parsed(suggestion(["Voice 1"], "X")).isEmpty, "suggestion name is a name")
        check(parsed(suggestion(["Voice 1"], " Dana")).isEmpty, "suggestion name is a name")
        check(parsed(suggestion(["Voice 1"], "bad\nname")).isEmpty, "suggestion name is a name")
        check(parsed(suggestion(["Voice 1"], score: 1.5)).isEmpty, "suggestion score bounded")
        check(parsed(suggestion(["Voice 1"], score: "high")).isEmpty, "suggestion score bounded")
        check(parsed(suggestion(["Voice 1"], score: 0.7, margin: 0.05)).count == 1, "suggestion at the rule kept")
        // The real shape, from the server's own example.
        let real = VoiceSuggestionJob(json(["state": "done", "progress": ["done": 12, "total": 12], "rule": ["floor": 0.7, "margin": 0.05], "modelSpace": "192d", "sourceRevision": revA,
            "suggestions": [["labels": ["Voice 1", "Voice 2"], "name": "Dana Reyes", "score": 0.85, "margin": 0.31, "units": 6, "kept": 6, "requiresConfirmation": true, "highConfidence": true]],
            "unmatched": [["labels": ["Voice 4"], "gate": "below_rule"]]]))!
        check(real.suggestions.count == 1 && real.suggestions[0].highConfidence && real.progressDone == 12, "server example parses")
        // A refusal for a session that is not a saved capture carries an empty revision.
        check(VoiceSuggestionJob(json(["state": "refused", "reason": "not_saved_mac_capture", "sourceRevision": "", "rule": ["floor": 0.7, "margin": 0.05], "modelSpace": "192d"]))!.sourceRevision == nil, "empty revision is no revision")
        // A check in another space, or with no rule, names nothing.
        check(VoiceSuggestionJob(json(job("done", suggestions: [suggestion(["Voice 1"])], extra: ["modelSpace": "256d"])))!.suggestions.isEmpty, "model space bound")
        var noRule = job("done", suggestions: [suggestion(["Voice 1"])]); noRule.removeValue(forKey: "rule")
        check(VoiceSuggestionJob(json(noRule))!.suggestions.isEmpty, "rule required")
        // Only a finished check has suggestions.
        check(VoiceSuggestionJob(json(job("running", suggestions: [suggestion(["Voice 1"])])))!.suggestions.isEmpty, "only done has suggestions")
        check(VoiceSuggestionJob(json(["state": "later"])) == nil, "unknown state rejected")
        check(VoiceSuggestionJob(json(["reason": "x"])) == nil, "unknown state rejected")
        // Progress.
        let good = VoiceSuggestionJob(json(job("running", extra: ["progress": ["done": 120, "total": 753]])))!
        check(good.progressDone == 120 && good.progressTotal == 753, "progress parses")
        for bad: Any in [["done": 9, "total": 3], ["done": -1, "total": 3], ["done": 1.5, "total": 3], ["done": 1], "x"] {
            let job = VoiceSuggestionJob(json(job("running", extra: ["progress": bad])))!
            check(job.progressDone == nil && job.progressTotal == nil, "bad progress unknown", "\(bad)")
        }
        // A bad revision is no revision.
        check(VoiceSuggestionJob(json(job("done", revision: "short")))!.sourceRevision == nil, "bad revision rejected")
    }

    static func state(_ body: [String: Any]) -> VoiceSuggestionState {
        VoiceSuggestionState().applying(["job": json(body)])
    }

    static func suggestionsSurface() {
        let open = review(base(roster, hint: hint()))
        // Saved Mac calls only.
        check(open.canSuggestNames, "saved mac calls only")
        var g2 = base(roster); g2["sessionId"] = "meeting_g2_fixture"
        check(!review(g2).canSuggestNames, "saved mac calls only")
        var noRecord = base(roster); noRecord["recordId"] = ""
        check(!review(noRecord).canSuggestNames, "saved mac calls only")
        var noRevision = base(roster); noRevision.removeValue(forKey: "sourceRevision")
        check(!review(noRevision).canSuggestNames, "saved mac calls only")
        check(!review(base(roster, extra: ["mutable": false])).canSuggestNames, "saved mac calls only")
        let interval = review(base(roster, extra: ["intervalGroupScopes": []]))
        check(!interval.canSuggestNames, "saved mac calls only")
        // The button waits for an answer, and an older server's 404 hides it with nothing said.
        check(!VoiceSuggestionState().showsButton(for: open), "button waits for the route")
        let absent = VoiceSuggestionState().applying(["unavailable": .string("route_absent")])
        check(absent.routeAbsent && !absent.showsButton(for: open), "404 hides the button")
        check(absent.line(for: open) == nil && absent.note == nil, "404 says nothing")
        // A 404 after a working answer hides it too (the server was rolled back).
        let rolled = state(job("idle")).applying(["unavailable": .string("route_absent")])
        check(!rolled.showsButton(for: open) && rolled.job == nil, "404 hides the button")
        // Any other failure keeps the button and says so.
        let broken = VoiceSuggestionState().applying(["unavailable": .string("error")])
        check(broken.showsButton(for: open) && broken.line(for: open) == VoiceDisplayCopy.didNotFinish, "other failure reported", broken.line(for: open) ?? "nil")
        // Lines.
        check(state(job("idle")).line(for: open) == VoiceDisplayCopy.suggestionsOnly, "idle says suggestions")
        check(state(job("running", extra: ["progress": ["done": 120, "total": 753]])).line(for: open) == "Checking voices, 120 of 753", "progress line", state(job("running", extra: ["progress": ["done": 120, "total": 753]])).line(for: open) ?? "nil")
        check(state(job("running")).line(for: open) == "Checking voices", "progress line without counts")
        check(state(job("running")).isRunning, "running state")
        check(state(job("refused", extra: ["reason": "recording_active"])).line(for: open) == "A recording is active. Try again when it ends.", "refusal in plain words")
        check(state(job("refused", extra: ["reason": "some_code"])).line(for: open) == VoiceDisplayCopy.didNotRun, "unknown code hidden")
        check(state(job("refused", extra: ["reason": "The server said this sentence."])).line(for: open) == "The server said this sentence.", "server sentence shown")
        check(state(job("refused")).line(for: open) == VoiceDisplayCopy.didNotRun, "refusal with no reason")
        check(state(job("failed", extra: ["reason": "internal_error"])).line(for: open) == VoiceDisplayCopy.didNotFinish, "failure in plain words")
        check(state(job("failed", extra: ["reason": "stack trace"])).line(for: open) == VoiceDisplayCopy.didNotFinish, "failure in plain words")
        check(state(job("failed", extra: ["reason": "deadline"])).line(for: open) == "The voice check ran out of time. Try again.", "failure reasons", state(job("failed", extra: ["reason": "deadline"])).line(for: open) ?? "nil")
        check(state(job("failed", extra: ["reason": "profile_store_unreadable"])).line(for: open) == "The saved voice profiles could not be read. Try again later.", "failure reasons")
        // A job stopped midway explains itself to polling, and the button is offered again.
        let ended = VoiceSuggestionState(probed: true).applying(["job": json(job("failed", extra: ["reason": "recording_active"]))])
        check(ended.line(for: open) == "A recording started, so the voice check stopped. Try again when it ends.", "a stopped job says what stopped it", ended.line(for: open) ?? "nil")
        check(ended.showsButton(for: open) && !ended.isRunning, "a stopped job offers the button again")
        check(state(job("failed", extra: ["reason": "maintenance"])).line(for: open) == "COS was updating or restarting, so the voice check stopped. Try again.", "a stopped job says what stopped it")
        check(state(job("failed", extra: ["reason": "meeting_finalizing"])).line(for: open) == "This meeting is being saved, so the voice check stopped. Try again in a minute.", "a stopped job says what stopped it")
        check(state(job("failed", extra: ["reason": "some_code"])).line(for: open) == VoiceDisplayCopy.didNotFinish, "failure in plain words")
        check(state(job("done")).line(for: open) == VoiceDisplayCopy.noSuggestions, "no suggestions line")
        let one = state(job("done", suggestions: [suggestion(["Voice 1"])]))
        check(one.line(for: open) == "1 suggestion. " + VoiceDisplayCopy.suggestionsOnly, "suggestion count line", one.line(for: open) ?? "nil")
        // Each reason the server can refuse with reads as a sentence, never as its code.
        for reason in ["recording_active", "meeting_finalizing", "maintenance", "job_running_elsewhere", "speaker_model_unavailable", "audio_not_retained",
                       "not_enough_voice_profiles", "profile_store_unreadable", "no_index_mapping", "derived_call_view", "not_saved_mac_capture", "sidecar_unreadable"] {
            let line = VoiceDisplayCopy.refusal(reason)
            check(line != VoiceDisplayCopy.didNotRun && !line.contains("_") && line.hasSuffix("."), "every refusal in plain words", reason)
        }
        // An idle answer at a new revision keeps the old result, so the line can say why its suggestions went.
        let oldDone = state(job("done", suggestions: [suggestion(["Voice 1"])]))
        let afterName = oldDone.applying(["job": json(job("idle", revision: revB))])
        var movedOn = base(roster, hint: hint()); movedOn["sourceRevision"] = revB
        check(afterName.suggestions(for: review(movedOn)).isEmpty && afterName.line(for: review(movedOn)) == VoiceDisplayCopy.staleSuggestions, "new revision says why", afterName.line(for: review(movedOn)) ?? "nil")
        let idleSame = oldDone.applying(["job": json(job("idle", revision: revA))])
        check(idleSame.job?.state == .idle, "idle at the same revision replaces")
        // Bound to the revision.
        let done = state(job("done", suggestions: [suggestion(["Voice 1"]), suggestion(["Voice 2", "Voice 3"], "Avery Stone")]))
        check(done.suggestions(for: open).count == 2, "revision bound")
        var moved = base(roster, hint: hint()); moved["sourceRevision"] = revB
        let later = review(moved)
        check(done.suggestions(for: later).isEmpty, "revision change drops suggestions")
        check(done.suggestions(heldBy: ["Voice 1"], in: later).isEmpty, "revision change drops suggestions")
        check(done.line(for: later) == VoiceDisplayCopy.staleSuggestions, "revision change says so", done.line(for: later) ?? "nil")
        let noRev = state(job("done", revision: nil, suggestions: [suggestion(["Voice 1"])]))
        check(noRev.suggestions(for: open).isEmpty && noRev.line(for: open) == VoiceDisplayCopy.staleSuggestions, "no revision names nothing")
        // A review with no revision matches nothing, including a job with none.
        check(noRev.suggestions(for: review(noRevision)).isEmpty, "no revision names nothing")
        // A suggestion attaches to the row holding its labels, and can cover only part of it.
        func names(_ rows: [VoiceNameSuggestion]) -> [String] { rows.map(\.name) }
        check(names(done.suggestions(heldBy: ["Voice 1"], in: open)) == ["Dana Reyes"], "single row holds its suggestion")
        check(names(done.suggestions(heldBy: ["Voice 2", "Voice 3"], in: open)) == ["Avery Stone"], "merged row holds its suggestion")
        check(names(done.suggestions(heldBy: ["Voice 3", "Voice 2"], in: open)) == ["Avery Stone"], "merged row holds its suggestion")
        // A subset of a merged row attaches to that row.
        check(names(done.suggestions(heldBy: ["Voice 2", "Voice 3", "Voice 4"], in: open)) == ["Avery Stone"], "subset attaches to its row")
        // Part of a suggestion on this row and part elsewhere attaches nowhere.
        check(done.suggestions(heldBy: ["Voice 2"], in: open).isEmpty, "a suggestion across rows attaches nowhere")
        check(done.suggestions(heldBy: [], in: open).isEmpty && done.suggestions(heldBy: ["Voice 4"], in: open).isEmpty, "a member with no suggestion shows nothing")
        // Two on one merged row both show, widest first.
        let two = state(job("done", suggestions: [suggestion(["Voice 4"], "Blake Moss"), suggestion(["Voice 1", "Voice 2", "Voice 3"], "Dana Reyes")]))
        check(names(two.suggestions(heldBy: ["Voice 1", "Voice 2", "Voice 3", "Voice 4", "Voice 5"], in: open)) == ["Dana Reyes", "Blake Moss"], "two suggestions on one row", "\(names(two.suggestions(heldBy: ["Voice 1", "Voice 2", "Voice 3", "Voice 4", "Voice 5"], in: open)))")
        check(VoiceDisplayCopy.suggestedName("Dana Reyes", covering: 9, of: 13) == "Suggested: Dana Reyes for 9 of 13 voices", "coverage words")
        check(VoiceDisplayCopy.suggestedName("Dana Reyes", covering: 1, of: 1) == "Suggested: Dana Reyes", "coverage words")
        // Only labels on the plain path can be suggested for: one on a reviewed path takes the whole suggestion with it.
        check(done.suggestions(heldBy: ["Voice 1"], in: review(base(roster, extra: ["mutable": false]))).isEmpty, "read-only shows no suggestion")
        // A label the review no longer has means this suggestion can no longer be used as it stands.
        let stale = state(job("done", suggestions: [suggestion(["Voice 1", "Voice 2", "Voice 97"])]))
        check(stale.suggestions(heldBy: ["Voice 1", "Voice 2", "Voice 97"], in: open).isEmpty, "a gone label attaches nowhere")
        // A running or failed check names nothing.
        check(state(job("running")).suggestions(for: open).isEmpty && state(job("failed")).suggestions(for: open).isEmpty, "only done has suggestions")
    }

    static func outcome() {
        let labels = ["Voice 5", "Voice 7", "Voice 9", "Voice 12", "Voice 14"]
        let partway = VoiceGroupNamingOutcome(to: "Dana Reyes", labels: labels, namedCount: 2, stoppedAt: "Voice 9", reason: "That name is already used.")
        check(partway.named == ["Voice 5", "Voice 7"], "partway named", "\(partway.named)")
        check(partway.notNamed == ["Voice 9", "Voice 12", "Voice 14"], "partway not named", "\(partway.notNamed)")
        check(partway.line == "Named Voice 5 and 7 Dana Reyes. Not named: Voice 9, 12 and 14. Stopped at Voice 9: That name is already used.", "partway line", partway.line)
        let none = VoiceGroupNamingOutcome(to: "Dana Reyes", labels: labels, namedCount: 0, stoppedAt: "Voice 7", reason: "A recording is active.")
        check(none.line == "Nothing was named. Stopped at Voice 7: A recording is active.", "nothing named line", none.line)
        let vague = VoiceGroupNamingOutcome(to: "Dana Reyes", labels: labels, namedCount: 0, stoppedAt: nil, reason: "This meeting changed.")
        check(vague.line == "Nothing was named. This meeting changed.", "nothing named line", vague.line)
        let all = VoiceGroupNamingOutcome(to: "Dana Reyes", labels: labels, namedCount: 5, stoppedAt: nil, reason: nil)
        check(all.line == "Named Voice 5, 7, 9, 12 and 14 Dana Reyes in this meeting.", "all named line", all.line)
        check(VoiceGroupNamingOutcome.list(["Voice 5"]) == "Voice 5", "list one")
        check(VoiceGroupNamingOutcome.list(["Voice 5", "Dana Reyes"]) == "Voice 5 and Dana Reyes", "list mixed", VoiceGroupNamingOutcome.list(["Voice 5", "Dana Reyes"]))
    }

    static func high(_ labels: [String], _ name: String = "Dana Reyes", score: Any = 0.86, margin: Any = 0.1, flag: Bool = true) -> [String: Any] {
        suggestion(labels, name, score: score, margin: margin, extra: ["highConfidence": flag])
    }

    static func batchCandidates() {
        let layoutReview = review(base(roster, hint: hint(groups: [group("g", ["Voice 1", "Voice 2", "Voice 3"], 300)], singles: [single("Voice 4", 90)], short: [short("Voice 5", 4)])))
        func state(_ rows: [[String: Any]]) -> VoiceSuggestionState { VoiceDisplayChecks.state(job("done", suggestions: rows)) }
        // A merged row counts once, however many labels it holds, and the fold's rows count too.
        let done = state([high(["Voice 1", "Voice 2", "Voice 3"]), high(["Voice 4"], "Avery Stone"), high(["Voice 5"], "Blake Moss")])
        let all = done.batchCandidates(for: layoutReview)
        check(all.count == 3, "merged row counts once", "\(all.map(\.title))")
        check(all.map(\.title) == ["Voice 1 and 2 more", "Voice 4", "Voice 5"], "batch titles and order", "\(all.map(\.title))")
        check(all[0].labels == ["Voice 1", "Voice 2", "Voice 3"] && all[0].name == "Dana Reyes" && all[0].score == 0.86, "batch row carries its name and score")
        check(VoiceDisplayCopy.nameVoices(all.count) == "Name 3 voices", "confirm words")
        check(VoiceDisplayCopy.nameVoices(1) == "Name 1 voice" && VoiceDisplayCopy.nameVoices(9) == "Name 9 voices", "confirm words")
        // Without a hint every label is its own row.
        let plain = review(base(roster))
        check(state([high(["Voice 1"]), high(["Voice 2"], "Avery Stone")]).batchCandidates(for: plain).count == 2, "plain list batch")
        // The count follows the ticks, and only ticked rows travel.
        var batch = VoiceBatchState(probed: true)
        check(batch.ticked(all).count == 3, "all ticked by default")
        batch.unticked.insert(all[1].id)
        check(batch.ticked(all).map(\.title) == ["Voice 1 and 2 more", "Voice 5"], "count follows the ticks")
        check(!batch.isTicked(all[1]) && batch.isTicked(all[0]), "count follows the ticks")
        let body = try! JSONSerialization.jsonObject(with: batch.applyBody(all, review: layoutReview)!) as! [String: Any]
        check(Set(body.keys) == ["sessionId", "sourceRevision", "items", "confirm"], "apply body keys", "\(body.keys)")
        check(body["confirm"] as? Bool == true && body["sourceRevision"] as? String == revA, "apply binds the revision")
        let items = body["items"] as! [[String: Any]]
        check(items.map { $0["name"] as! String } == ["Dana Reyes", "Blake Moss"], "only ticked rows travel", "\(items)")
        check(items[0]["labels"] as! [String] == ["Voice 1", "Voice 2", "Voice 3"], "only ticked rows travel")
        for row in all { batch.unticked.insert(row.id) }
        check(batch.ticked(all).isEmpty && batch.applyBody(all, review: layoutReview) == nil, "nothing to send at zero")
        var noRevision = base(roster); noRevision.removeValue(forKey: "sourceRevision")
        check(VoiceBatchState(probed: true).applyBody(all, review: review(noRevision)) == nil, "no revision sends nothing")
        // Under .80 keeps its own Use this name and stays out of the batch.
        let mid = state([high(["Voice 4"], score: 0.75, flag: false)])
        check(mid.batchCandidates(for: layoutReview).isEmpty, "under .80 excluded")
        check(mid.suggestions(heldBy: ["Voice 4"], in: layoutReview).count == 1, "under .80 keeps its own suggestion")
        // The server's flag decides, because its score is rounded for display. A high score alone never joins, and a rounded one never leaves.
        check(state([high(["Voice 4"], score: 0.8, margin: 0.05)]).batchCandidates(for: layoutReview).count == 1, "the flag decides")
        check(state([high(["Voice 4"], score: 0.799)]).batchCandidates(for: layoutReview).count == 1, "the flag decides")
        check(state([suggestion(["Voice 4"], score: 0.95, margin: 0.2)]).batchCandidates(for: layoutReview).isEmpty, "no flag no batch")
        check(state([high(["Voice 4"], flag: false)]).batchCandidates(for: layoutReview).isEmpty, "no flag no batch")
        // A subset of a merged row: its title and its item come from the suggestion's own labels.
        let part = state([high(["Voice 2", "Voice 3"])]).batchCandidates(for: layoutReview)
        check(part.count == 1 && part[0].labels == ["Voice 2", "Voice 3"] && part[0].title == "Voice 2 and 1 more", "subset batch row", "\(part)")
        var partBatch = VoiceBatchState(probed: true); partBatch.previewOpen = true
        let partBody = try! JSONSerialization.jsonObject(with: partBatch.applyBody(part, review: layoutReview)!) as! [String: Any]
        check((partBody["items"] as! [[String: Any]])[0]["labels"] as! [String] == ["Voice 2", "Voice 3"], "subset sends only its labels")
        // Two on one merged row are two rows, and the count counts each.
        let pair = state([high(["Voice 1"], "Blake Moss"), high(["Voice 2", "Voice 3"], "Dana Reyes")]).batchCandidates(for: layoutReview)
        check(pair.map(\.name) == ["Dana Reyes", "Blake Moss"] && pair.map(\.title) == ["Voice 2 and 1 more", "Voice 1"], "two suggestions are two batch rows", "\(pair)")
        check(VoiceDisplayCopy.nameVoices(pair.count) == "Name 2 voices", "two suggestions are two batch rows")
        // A label never travels twice.
        check(state([high(["Voice 1", "Voice 2"]), high(["Voice 2"], "Blake Moss")]).batchCandidates(for: layoutReview).count == 1, "a label travels once")
        // A suggestion no row holds stays out, and an unmatched member adds nothing.
        check(state([high(["Voice 1", "Voice 4"])]).batchCandidates(for: layoutReview).isEmpty, "across rows stays out of the batch")
        // A row that is not on the plain path stays out, and so does the wearer's name.
        check(done.batchCandidates(for: review(base(roster, hint: hint(), extra: ["mutable": false]))).isEmpty, "read-only has no batch")
        check(done.batchCandidates(for: layoutReview, excluding: ["Avery Stone"]).map(\.name) == ["Dana Reyes", "Blake Moss"], "owner never in the batch")
        let member: [String: Any] = ["rawChunkIndex": 1, "position": 0, "before": "Voice 1", "text": "invented", "elapsedMs": 1]
        let scope: [String: Any] = ["identityId": "human_fixture", "displayLabel": "Voice 1", "scopeSHA256": revB, "members": [member], "fieldCount": 1, "reviewBasis": "automatic-label-only"]
        var scoped = base(roster, hint: hint(groups: [group("g", ["Voice 1", "Voice 2", "Voice 3"], 300)], singles: [single("Voice 4", 90)], short: [short("Voice 5", 4)]))
        scoped["groupScopes"] = [scope]
        check(done.batchCandidates(for: review(scoped)).map(\.title) == ["Voice 4", "Voice 5"], "scoped label stays out", "\(done.batchCandidates(for: review(scoped)).map(\.title))")
        var scopedSingle = base(roster); scopedSingle["groupScopes"] = [scope]
        check(state([high(["Voice 1"])]).batchCandidates(for: review(scopedSingle)).isEmpty, "scoped label stays out")
        // Bound to the revision: a moved review offers nothing.
        var moved = base(roster, hint: hint(groups: [group("g", ["Voice 1", "Voice 2", "Voice 3"], 300)])); moved["sourceRevision"] = revB
        check(done.batchCandidates(for: review(moved)).isEmpty, "moved revision offers nothing")
        // A 404 hides the controls; the button waits for an answer; a failure to read keeps waiting.
        let open = review(base(roster))
        check(!VoiceBatchState().showsControls(for: open), "controls wait for the list")
        let absent = VoiceBatchState().applyingList(["unavailable": .string("route_absent")])
        check(absent.routeAbsent && !absent.showsControls(for: open) && absent.undoableBatch == nil, "404 hides the batch")
        let failed = VoiceBatchState().applyingList(["unavailable": .string("error")])
        check(!failed.probed && !failed.showsControls(for: open), "failed list keeps it hidden")
        let listed = VoiceBatchState().applyingList(["batches": .array([])])
        check(listed.showsControls(for: open), "empty list shows controls")
        check(!listed.showsControls(for: review(base(roster, extra: ["mutable": false]))), "read-only has no batch")
    }

    static func batchRow(_ labels: [String], _ name: String = "Dana Reyes", samples: Int = 0, reason: String? = nil) -> [String: Any] {
        var o: [String: Any] = ["labels": labels, "name": name, "samplesAdded": samples]
        if let reason { o["reason"] = reason }
        return o
    }

    static func batchResults() {
        let applied = VoiceBatchResult(json(["batchId": "b1", "state": "applied", "named": (1...9).map { batchRow(["Voice \($0)"], samples: 3) }, "notNamed": [], "sourceRevision": revB, "undoAvailable": true]))!
        check(applied.line == "Named 9 voices.", "all named line", applied.line)
        let one = VoiceBatchResult(json(["batchId": "b1", "state": "applied", "named": [batchRow(["Voice 1", "Voice 2"])], "notNamed": [], "undoAvailable": true]))!
        check(one.line == "Named 1 voice.", "merged row reads as one", one.line)
        // A partial result lists the right labels.
        let partial = VoiceBatchResult(json(["batchId": "b2", "state": "partial", "reason": "stopped", "undoAvailable": true,
            "named": (1...5).map { batchRow(["Voice \($0)"]) },
            "notNamed": [batchRow(["Voice 12"], reason: "That name is already used differently."), batchRow(["Voice 20", "Voice 21", "Voice 22"], "Avery Stone", reason: "recording_active")]]))!
        check(partial.named.flatMap(\.labels) == (1...5).map { "Voice \($0)" }, "partial lists the named", "\(partial.named)")
        check(partial.notNamed.map(\.labels) == [["Voice 12"], ["Voice 20", "Voice 21", "Voice 22"]], "partial lists the not named", "\(partial.notNamed)")
        check(partial.line == "Named 5 voices. Stopped at Voice 12: That name is already used differently. Not named: Voice 12, Voice 20 and 2 more.", "partial line", partial.line)
        // The row's own reason wins, then the batch's, and a bare code never shows.
        let code = VoiceBatchResult(json(["batchId": "b", "state": "partial", "named": [batchRow(["Voice 1"])], "notNamed": [batchRow(["Voice 2"], reason: "recording_active")]]))!
        check(code.line == "Named 1 voice. Stopped at Voice 2: A recording is active. Not named: Voice 2.", "reason in plain words", code.line)
        let unknown = VoiceBatchResult(json(["batchId": "b", "state": "partial", "named": [], "notNamed": [batchRow(["Voice 2"], reason: "some_code_x")]]))!
        check(unknown.line == "Nothing was named. Stopped at Voice 2: The server did not apply it. Not named: Voice 2.", "unknown code hidden", unknown.line)
        // The server's real shapes: rows after the stop read not_attempted, and can come first in the list.
        let stopped = VoiceBatchResult(json(["batchId": "b", "state": "partial", "reason": "audio_not_retained", "undoAvailable": true, "named": [batchRow(["Voice 9"])],
            "notNamed": [batchRow(["Voice 1"], reason: "not_attempted"), batchRow(["Voice 2"], reason: "audio_not_retained"), batchRow(["Voice 3", "Voice 4"], reason: "not_attempted")]]))!
        check(stopped.line == "Named 1 voice. Stopped at Voice 2: This call's audio is no longer kept. Not named: Voice 1, Voice 2, Voice 3 and 1 more.", "stop is the row that stopped it", stopped.line)
        let wholeRefusal = VoiceBatchResult(json(["batchId": "", "state": "refused", "reason": "not_high_confidence", "named": [], "undoAvailable": false,
            "notNamed": [batchRow(["Voice 1"], reason: "not_attempted"), batchRow(["Voice 5"], reason: "not_high_confidence")]]))!
        check(wholeRefusal.line == "Nothing was named. This suggestion no longer qualifies.", "refusal line", wholeRefusal.line)
        // Every reason the server can send reads as a sentence, never as its code.
        for reason in ["recording_active", "meeting_finalizing", "maintenance", "suggestions_stale", "meeting_changed", "transcript_changed", "record_source_mismatch", "not_high_confidence", "owner_refused",
                       "label_not_anonymous", "duplicate_label", "correction_pending", "batch_running", "sync_running", "sidecar_unreadable", "audio_not_retained", "below_floor", "mixed_voice", "too_little_audio",
                       "profile_store_unavailable", "write_failed", "ledger_unwritable", "journal_unwritable", "internal_error", "not_attempted", "not_applied", "not_named", "not_reverted",
                       "store_unavailable", "interrupted", "journal_unreadable", "samples_not_found",
                       "label_changed_by_person", "confirmed_by_person", "batch_not_found", "derived_call_view", "not_saved_mac_capture", "direct_library_read_only"] {
            let line = VoiceDisplayCopy.batchReason(reason)
            check(line != "The server did not apply it" && !line.contains("_"), "every batch reason in plain words", reason)
            check(!line.lowercased().contains("identified") && !line.contains("\u{2014}"), "batch copy rules", line)
        }
        // A refusal leaves nothing named, whatever the body claims.
        let refused = VoiceBatchResult(json(["batchId": "b3", "state": "refused", "reason": "recording_active", "named": [batchRow(["Voice 1"])], "notNamed": [], "undoAvailable": true]))!
        check(refused.named.isEmpty, "refusal names nothing", "\(refused.named)")
        check(refused.line == "Nothing was named. A recording is active.", "refusal line", refused.line)
        check(VoiceBatchResult(json(["state": "later"])) == nil && VoiceBatchResult(json(["named": []])) == nil, "unknown batch state rejected")
        // Applied with no rows is not a success line.
        let empty = VoiceBatchResult(json(["batchId": "b", "state": "applied", "named": [], "notNamed": []]))!
        check(empty.line.hasPrefix("Nothing was named."), "applied with no rows is not a success", empty.line)
        // A malformed row is dropped rather than counted.
        let malformed = VoiceBatchResult(json(["batchId": "b", "state": "applied", "named": [batchRow(["Voice 1"]), ["name": "x"], ["labels": [], "name": "x"]], "notNamed": []]))!
        check(malformed.named.count == 1, "malformed rows not counted")
    }

    static func batchUndo() {
        // Availability across reopening: a fresh state reads it from the list, and the newest undoable wins.
        func listed(_ rows: [[String: Any]]) -> VoiceBatchState { VoiceBatchState().applyingList(["batches": json(["x": rows]).object!["x"]!]) }
        let reopened = listed([["batchId": "old", "at": "2026-10-30T10:00:00Z", "state": "applied", "named": [], "undoAvailable": true],
                               ["batchId": "new", "at": "2026-10-30T12:00:00Z", "state": "partial", "named": [], "undoAvailable": true],
                               ["batchId": "gone", "at": "2026-10-30T13:00:00Z", "state": "applied", "named": [], "undoAvailable": false]])
        check(reopened.undoableBatch?.batchId == "new", "undo survives reopening", reopened.undoableBatch?.batchId ?? "nil")
        check(listed([["batchId": "gone", "at": "x", "undoAvailable": false]]).undoableBatch == nil, "no undo when none available")
        check(listed([["batchId": "bare", "at": "x"]]).undoableBatch == nil, "undo needs the server's word")
        check(listed([["at": "x", "undoAvailable": true]]).undoableBatch == nil, "undo needs an id")
        // After an undo the list says it is gone.
        let after = reopened.applyingList(["batches": json(["x": [["batchId": "new", "at": "t", "undoAvailable": false]]]).object!["x"]!])
        check(after.undoableBatch == nil, "undo gone after undo")
        // What the undo did, in words.
        let done = VoiceBatchUndoResult(json(["state": "undone", "reverted": (1...9).map { ["labels": ["Voice \($0)"], "name": "Dana Reyes"] }, "left": [], "samplesRemoved": 27, "sourceRevision": revB]))!
        check(done.line == "Undid 9 names. Removed 27 profile samples.", "undo line", done.line)
        let single = VoiceBatchUndoResult(json(["state": "undone", "reverted": [["labels": ["Voice 1"], "name": "Dana Reyes"]], "left": [], "samplesRemoved": 1]))!
        check(single.line == "Undid 1 name. Removed 1 profile sample.", "undo line", single.line)
        let partial = VoiceBatchUndoResult(json(["state": "partial", "reverted": [["labels": ["Voice 1"], "name": "Dana Reyes"]],
            "left": [["labels": ["Voice 2", "Voice 3"], "name": "Avery Stone", "reason": "It changed after the batch."]], "samplesRemoved": 3]))!
        check(partial.reverted.flatMap(\.labels) == ["Voice 1"] && partial.left.flatMap(\.labels) == ["Voice 2", "Voice 3"], "partial undo labels")
        check(partial.line == "Undid 1 name. Removed 3 profile samples. Left in place: Voice 2 and 1 more. Voice 2 and 1 more: It changed after the batch.", "partial undo line", partial.line)
        let refused = VoiceBatchUndoResult(json(["state": "refused", "reason": "recording_active", "reverted": [["labels": ["Voice 1"], "name": "x"]], "left": [], "samplesRemoved": 8]))!
        check(refused.reverted.isEmpty && refused.samplesRemoved == 0, "refused undo did nothing")
        check(refused.line == "Nothing was undone. A recording is active.", "refused undo line", refused.line)
        check(VoiceBatchUndoResult(json(["state": "later"])) == nil, "unknown undo state rejected")
        for line in [VoiceDisplayCopy.undoNames, VoiceDisplayCopy.batchLostReply, VoiceDisplayCopy.batchPreviewNote, done.line, partial.line] {
            check(!line.contains("\u{2014}") && !line.contains("\u{2192}") && !line.lowercased().contains("identified") && !line.lowercased().contains("person") && !line.lowercased().contains("people"), "batch copy rules", line)
        }
    }

    /// The independent review of 3ce5972, one behaviour each.
    static func reviewFixes() {
        // Rename voice opens on a voice that can sit inside a collapsed row.
        let layoutReview = review(base(roster, hint: hint(groups: [group("g", ["Voice 1", "Voice 2"], 300)], singles: [single("Voice 4", 90)], short: [short("Voice 5", 4)])))
        let layout = layoutReview.voiceDisplayLayout!
        check(layout.collapsedHolder(of: "Voice 2") == .merged("group:g"), "holder of a merged member")
        check(layout.collapsedHolder(of: "Voice 5") == .short, "holder of a short voice")
        check(layout.collapsedHolder(of: "Voice 4") == nil && layout.collapsedHolder(of: "Ext") == nil && layout.collapsedHolder(of: "Voice 90") == nil, "a row on show has no holder")
        // Singular words.
        let lone = review(base([voice("Voice 1"), voice("Voice 2")], hint: hint(groups: [group("g", ["Voice 1", "Voice 2"], 30)])))
        check(lone.inventoryHeader == "783 segments · 2 voice labels in 1 row", "header singular", lone.inventoryHeader)
        let one = review(base([voice("Voice 1")], hint: hint(singles: [single("Voice 1", 30)])))
        check(one.inventoryHeader == "783 segments · 1 voice label in 1 row", "header singular", one.inventoryHeader)
        // Planning reports 0 of 0.
        let open = review(base(roster))
        check(state(job("running", extra: ["progress": ["done": 0, "total": 0]])).line(for: open) == "Checking voices", "planning has no count", state(job("running", extra: ["progress": ["done": 0, "total": 0]])).line(for: open) ?? "nil")
        // A running check that answers idle was dropped: say why, keep saying it, and offer the button.
        let running = state(job("running", extra: ["progress": ["done": 3, "total": 9]]))
        let dropped = running.applying(["job": json(job("idle"))])
        check(dropped.line(for: open) == VoiceDisplayCopy.checkStoppedChanged, "a dropped check says why", dropped.line(for: open) ?? "nil")
        check(dropped.showsButton(for: open) && !dropped.isRunning, "a dropped check offers the button")
        check(dropped.applying(["job": json(job("idle"))]).line(for: open) == VoiceDisplayCopy.checkStoppedChanged, "a dropped check says why")
        check(dropped.applying(["job": json(job("running"))]).line(for: open) == VoiceDisplayCopy.checking, "a new check clears the note")
        check(state(job("idle")).applying(["job": json(job("idle"))]).line(for: open) == VoiceDisplayCopy.suggestionsOnly, "idle to idle says nothing")
        // A suggestion inside the fold.
        func done(_ rows: [[String: Any]]) -> VoiceSuggestionState { state(job("done", suggestions: rows)) }
        check(done([suggestion(["Voice 5"])]).holdsShortSuggestion(in: layoutReview), "short suggestion opens the fold")
        check(!done([suggestion(["Voice 4"])]).holdsShortSuggestion(in: layoutReview), "other suggestions leave it shut")
        check(!state(job("idle")).holdsShortSuggestion(in: layoutReview), "other suggestions leave it shut")
        check(!done([suggestion(["Voice 1"])]).holdsShortSuggestion(in: open), "other suggestions leave it shut")
        // A name can land while its samples do not.
        let skipped = VoiceGroupNamingOutcome(to: "Dana Reyes", labels: ["Voice 1", "Voice 2"], namedCount: 2, stoppedAt: nil, reason: nil, skipped: ["store_unavailable", "store_unavailable"])
        check(skipped.line == "Named Voice 1 and 2 Dana Reyes in this meeting. · the name is applied, but the voice samples could not be saved", "group save warns of skipped samples", skipped.line)
        // A batch still running blocks both buttons, and has no Undo to offer yet.
        func listed(_ rows: [[String: Any]]) -> VoiceBatchState { VoiceBatchState().applyingList(["batches": json(["x": rows]).object!["x"]!]) }
        let live = listed([["batchId": "r", "at": "2026-10-30T21:00:00Z", "state": "running", "named": [], "undoAvailable": true]])
        check(live.hasRunningBatch, "running batch noticed")
        check(live.undoableBatch == nil, "running batch has no undo yet")
        check(live.historyLine == "A batch is still naming voices. This refreshes when it finishes.", "running batch says so", live.historyLine ?? "nil")
        check(!listed([["batchId": "a", "at": "x", "state": "applied", "undoAvailable": true]]).hasRunningBatch, "running batch noticed")
        // Some samples missing where no name went back says only that.
        let missing = VoiceBatchUndoResult(json(["state": "partial", "reverted": [], "left": [batchRow(["Voice 1"], reason: "samples_not_found")], "samplesRemoved": 0]))!
        check(missing.line == "Undid 0 names. Removed 0 profile samples. Some voice samples for Voice 1 could not be found.", "samples missing without a revert", missing.line)
        // What and when, for a review opened later.
        let row = VoiceBatchSummary(json(["batchId": "a", "at": "2026-10-30T20:05:00.000Z", "state": "applied", "undoAvailable": true, "named": [batchRow(["Voice 1"]), batchRow(["Voice 2", "Voice 3"], "Avery Stone")]]))!
        let utc = TimeZone(identifier: "UTC")!
        check(row.line(timeZone: utc) == "Named 2 voices on Oct 30 at 8:05 PM: Dana Reyes, Avery Stone.", "history says what and when", row.line(timeZone: utc) ?? "nil")
        let plainISO = VoiceBatchSummary(json(["batchId": "a", "at": "2026-10-30T20:05:00Z", "state": "applied", "undoAvailable": true, "named": []]))!
        check(plainISO.line(timeZone: utc) == "Named 0 voices on Oct 30 at 8:05 PM.", "history reads either iso", plainISO.line(timeZone: utc) ?? "nil")
        let noTime = VoiceBatchSummary(json(["batchId": "a", "at": "", "state": "applied", "undoAvailable": true, "named": [batchRow(["Voice 1"])]]))!
        check(noTime.line(timeZone: utc) == "Named 1 voice: Dana Reyes.", "history leaves out a bad time", noTime.line(timeZone: utc) ?? "nil")
        let many = VoiceBatchSummary(json(["batchId": "a", "at": "", "state": "applied", "undoAvailable": true, "named": ["A One", "B Two", "C Three", "D Four", "A One"].enumerated().map { batchRow(["Voice \($0.offset + 1)"], $0.element) }]))!
        check(many.line(timeZone: utc) == "Named 5 voices: A One, B Two, C Three and 1 more.", "history bounds its names", many.line(timeZone: utc) ?? "nil")
        check(VoiceBatchSummary(json(["batchId": "a", "at": "", "state": "applied", "undoAvailable": false]))!.line() == nil, "a spent batch says nothing")
        check(VoiceBatchSummary(json(["batchId": "a", "at": "", "state": "undone", "undoAvailable": false]))!.line() == nil, "a spent batch says nothing")
        // An undone batch is no history, an honest state is, and the newest undoable wins over both.
        check(listed([["batchId": "a", "at": "t", "state": "undone"]]).historyLine == nil, "a spent batch says nothing")
        let stuck = listed([["batchId": "a", "at": "", "state": "undo_partial"], ["batchId": "b", "at": "", "state": "applied", "undoAvailable": true, "named": [batchRow(["Voice 1"])]]])
        check(stuck.historyLine == "Named 1 voice: Dana Reyes.", "undoable comes first", stuck.historyLine ?? "nil")
    }

    /// Real bodies, in Tests/fixtures/voice-display-server-6.96.3.json. Each one's `source` names where in the server it came from.
    static func contract(_ path: String) {
        guard let data = FileManager.default.contents(atPath: path),
              let fixtures = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { check(false, "contract fixture reads", path); return }
        func body(_ name: String) -> JSONValue {
            guard let entry = fixtures[name] as? [String: Any], (entry["source"] as? String)?.isEmpty == false, let raw = entry["body"] else {
                check(false, "every fixture names its source", name); return .null
            }
            return json(["x": raw]).object!["x"]!
        }
        func answer(_ name: String, _ state: VoiceSuggestionState = VoiceSuggestionState()) -> VoiceSuggestionState { state.applying(["job": body(name)]) }
        let open = review(base(roster, hint: body("voiceDisplay").object.map { _ in (fixtures["voiceDisplay"] as! [String: Any])["body"] as! [String: Any] }))
        // /speakers
        let layout = open.voiceDisplayLayout
        check(layout != nil, "contract: voiceDisplay parses")
        check(layout.map { tops($0).prefix(3) == ["Voice 1 and 1 more", "Voice 3", "Voice 4"] } == true, "contract: voiceDisplay order", layout.map { "\(tops($0))" } ?? "nil")
        guard case .merged(let row)? = layout?.rows.first else { check(false, "contract: voiceDisplay order"); return }
        check(row.timeText == "0m 36s", "contract: voiceDisplay time", row.timeText ?? "nil")
        // /voice-suggestions
        check(answer("suggestionsIdle").line(for: open) == VoiceDisplayCopy.suggestionsOnly, "contract: idle")
        check(answer("suggestionsIdleUnsaved").job?.sourceRevision == nil, "contract: empty revision")
        let done = answer("suggestionsDone")
        check(done.job?.state == .done && done.suggestions(for: open).count == 2, "contract: done", "\(String(describing: done.job))")
        check(done.suggestions(heldBy: ["Voice 1", "Voice 2"], in: open).first?.name == "Dana Reyes", "contract: done")
        check(done.suggestions(heldBy: ["Voice 4"], in: open).isEmpty, "contract: unmatched shows nothing")
        check(done.batchCandidates(for: open).map(\.title) == ["Voice 1 and 1 more", "Voice 3"], "contract: batch rows", "\(done.batchCandidates(for: open).map(\.title))")
        check(answer("suggestionsRefused").line(for: open) == "A recording is active. Try again when it ends.", "contract: refused")
        check(answer("suggestionsRefusedUnreadable").line(for: open) == "This call's saved speaker data could not be read.", "contract: refused")
        check(answer("suggestionsFailed").line(for: open) == "A recording started, so the voice check stopped. Try again when it ends.", "contract: failed")
        // POST /voice-naming-batch
        func line(_ name: String) -> String { VoiceBatchResult(body(name))?.line ?? "unparsed" }
        check(line("batchApplied") == "Named 2 voices.", "contract: batch applied", line("batchApplied"))
        check(line("batchRefusedStale") == "Nothing was named. This meeting changed since the suggestions were made.", "contract: batch refused", line("batchRefusedStale"))
        check(line("batchRefusedItem") == "Nothing was named. This suggestion no longer qualifies.", "contract: batch refused", line("batchRefusedItem"))
        check(line("batchPartialAudio") == "Named 1 voice. Stopped at Voice 2: This call's audio is no longer kept. Not named: Voice 2, Voice 3 and 1 more.", "contract: batch partial", line("batchPartialAudio"))
        check(line("batchPartialStoreEarlier") == "Named 1 voice. The voice samples could not be saved. Not named: Voice 2.", "contract: store unavailable earlier", line("batchPartialStoreEarlier"))
        check(line("batchPartialStoreLast") == "Named 1 voice. The voice samples could not be saved.", "contract: store unavailable last", line("batchPartialStoreLast"))
        check(line("batchInterrupted") == "Named 1 voice. Stopped at Voice 2: The batch was interrupted. Not named: Voice 2.", "contract: interrupted", line("batchInterrupted"))
        // POST .../undo
        func undo(_ name: String) -> String { VoiceBatchUndoResult(body(name))?.line ?? "unparsed" }
        check(undo("undoLabelChanged") == "Undid 1 name. Removed 8 profile samples. Left in place: Voice 1. Voice 1: You changed it after the batch.", "contract: undo partial", undo("undoLabelChanged"))
        check(undo("undoSamplesNotFound") == "Undid 1 name. Removed 0 profile samples. 4 older samples could not be restored. The name on Voice 1 was reverted, but some of its voice samples could not be found.", "contract: samples not found", undo("undoSamplesNotFound"))
        check(undo("undoEvictedLost") == "Undid 1 name. Removed 4 profile samples. 4 older samples could not be restored.", "contract: older samples lost", undo("undoEvictedLost"))
        check(undo("undoEvictedBack") == "Undid 1 name. Removed 4 profile samples. Put back 4 older samples.", "contract: older samples back", undo("undoEvictedBack"))
        check(undo("undoRefused") == "Nothing was undone. These names can no longer be undone.", "contract: undo refused", undo("undoRefused"))
        // GET /voice-naming-batch
        func list(_ name: String) -> VoiceBatchState { VoiceBatchState().applyingList(body(name).object ?? [:]) }
        let utc = TimeZone(identifier: "UTC")!
        check(list("listEmpty").probed && list("listEmpty").undoableBatch == nil && list("listEmpty").historyLine == nil, "contract: empty list")
        check(list("listApplied").undoableBatch?.line(timeZone: utc) == "Named 2 voices on Oct 30 at 8:05 PM: Dana Reyes, Theo Marsh.", "contract: list applied", list("listApplied").undoableBatch?.line(timeZone: utc) ?? "nil")
        check(list("listInterrupted").undoableBatch?.line(timeZone: utc) == "A batch was interrupted on Oct 30 at 8:05 PM after naming 1 voice: Dana Reyes. Undo puts back what it named.", "contract: list interrupted", list("listInterrupted").undoableBatch?.line(timeZone: utc) ?? "nil")
        check(list("listUndoPartial").undoableBatch == nil && list("listUndoPartial").batches.first?.line(timeZone: utc) == "Undo of the batch on Oct 30 at 8:05 PM only partly finished. What was left stays as it is.", "contract: list undo partial", list("listUndoPartial").batches.first?.line(timeZone: utc) ?? "nil")
        check(list("listUnreadable").undoableBatch == nil && list("listUnreadable").historyLine == "The record of a batch could not be read, so it cannot be undone here.", "contract: list unreadable", list("listUnreadable").historyLine ?? "nil")
    }

    static func refusal() {
        func result(_ o: [String: Any]) -> [String: JSONValue]? { json(o).object }
        check(SpeakerRefusal.text(result(["reason": "x", "error": "That name is already used."])) == "That name is already used.", "refusal reads error")
        check(SpeakerRefusal.text(result(["message": "The message.", "error": "The error."])) == "The message.", "refusal prefers message")
        check(SpeakerRefusal.text(result(["message": "  ", "error": "The error."])) == "The error.", "refusal skips a blank message")
        check(SpeakerRefusal.text(result(["reason": "x"])) == nil, "refusal needs words")
        check(SpeakerRefusal.text(nil) == nil, "refusal needs words")
    }
}
