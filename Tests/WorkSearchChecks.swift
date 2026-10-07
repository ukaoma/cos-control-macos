import Foundation
import SwiftUI

// 0.5.259 Work search and order (board 4 of the 10/6 mock): the words a search looks for and how a card matches them,
// Jev's one threshold (0.15, for the band, the counts and the columns alike, so every count agrees), a late answer
// dropped, Best matches and why each matched,
// the counts, other domains, the degrade lines, the keys, Order and its memory, the created day and the last activity
// from each source, the stage-move journal (written by the app's own stage writes through a stand-in helper) and its
// bound, and the request and answer the helper's work-search carries. Failures read "check failed [<behaviour>]" so the
// mutation lane (Tests/mutate-work-search.py) can credit each kill. No window, no event, no server.

@main @MainActor struct WorkSearchChecks {
    @MainActor static func main() async throws {
        wordChecks()
        matchChecks()
        invariantChecks()
        mergeChecks()
        bandChecks()
        countChecks()
        elsewhereChecks()
        noteChecks()
        calibrationChecks()
        keyChecks()
        escapeChecks()
        orderChecks()
        persistenceChecks()
        createdChecks()
        activityChecks()
        lineChecks()
        taskRowChecks()
        requestChecks()
        try await askChecks()
        try await staleChecks()
        memoChecks()
        try journalChecks()
        try await journalWriteChecks()
        print("PASS: Work search and order (words and stopwords, title and word matches by word start, one Jev threshold (0.15) with N matches, N of M tasks and every column's n of m agreeing, a late answer dropped and a new search cancelling the wait, Best matches ranked and why, n of m, N more in another domain, one line for a paused or missing meaning search and none when it is off, the keys, Order with undated cards last, remembered per board, the created day and the last activity from each source, the stage-move journal written by the board, Intake and the tracker's writes, atomic and bounded to 2,000, and the work-search request and answer)")
    }

    /// Names the behaviour a failure is about, so a mutation is credited to the check that names it.
    static func check(_ condition: Bool, _ behaviour: String, _ detail: @autoclosure () -> String = "", line: UInt = #line) {
        if !condition { fatalError("check failed [\(behaviour)] at line \(line): \(detail())") }
    }

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }()
    static func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    static func day(_ text: String) -> Date { WorkCardDating.day(text, calendar: calendar)! }

    static func task(_ id: String, _ text: String, domain: String = "quilt", stage: String = "planned", checked: Bool = false,
                     source: String = "", meetings: [String] = [], extra: [String: JSONValue] = [:]) -> TaskRow {
        var row: [String: JSONValue] = ["id": .string(id), "domain": .string(domain), "title": .string(String(text.prefix(44))),
            "text": .string(text), "checked": .bool(checked), "workStage": .string(stage), "source": .string(source),
            "workRevision": .string(String(repeating: "a", count: 64)),
            "meetingRefs": .array(meetings.enumerated().map { index, title in
                .object(["recordId": .string("ops:\(domain):2026-10:m\(index).md"), "domain": .string(domain), "month": .string("2026-10"),
                         "filename": .string("2026-10-06_m\(index).md"), "title": .string(title)]) })]
        for (key, value) in extra { row[key] = value }
        return TaskRow(.object(row))!
    }
    static func items(_ tasks: [TaskRow]) -> [WorkWorkspaceItem] { WorkWorkspaceProjection.items(tasks: tasks, reviews: [], receipts: []) }
    static func json(_ body: [String: JSONValue]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(JSONValue.object(body))) ?? Data(), as: UTF8.self)
    }
    static func hex(_ n: Int) -> String { String(format: "a%011x", n) }

    // MARK: Words and matches

    static func wordChecks() {
        check(WorkSearch.words("the competitor ads for our store") == ["competitor", "ads", "store"], "stopwords",
              "\(WorkSearch.words("the competitor ads for our store"))")
        check(WorkSearch.words("a b c") == [] && WorkSearch.words("to the and") == [], "stopwords", "single letters and stopwords alone are no search")
        check(WorkSearch.words("Ads, ADS; ads") == ["ads"], "stopwords", "a word counts once, whatever its case")
        check(WorkSearch.words("Résumé review") == ["resume", "review"], "case and accents", "\(WorkSearch.words("Résumé review"))")
        check(WorkSearch.words("IT-Retail 3D lane") == ["it", "retail", "3d", "lane"], "word split", "\(WorkSearch.words("IT-Retail 3D lane"))")
    }

    static func matchChecks() {
        let fields = WorkSearchFields(title: "Send Cort screenshots of the paid search campaigns Scotch is running",
                                      other: ["Deprioritize CityHive, Feature DoorDash Integrations (G2)", "Pricing sheet.pdf"])
        check(fields.match(["paid", "search"]) == WorkSearchHit(kind: .title, words: ["paid", "search"]), "title match", "every word in the title")
        check(fields.match(["PAID".lowercased(), "campaign"])?.kind == .title, "title match", "a word finds the words it starts")
        check(fields.match(["doordash", "paid"]) == WorkSearchHit(kind: .words, words: ["doordash", "paid"]), "words match",
              "\(String(describing: fields.match(["doordash", "paid"])))")
        check(fields.match(["pricing"]) == WorkSearchHit(kind: .words, words: ["pricing"]), "words match", "a card file's name is searched")
        check(fields.match(["ads"]) == nil, "word start", "\"ads\" must not find \"leads\" or a word it sits inside")
        let leads = WorkSearchFields(title: "Review the leads report", other: [])
        check(leads.match(["ads"]) == nil && leads.match(["lead"])?.kind == .title, "word start", "\"ads\" inside \"leads\"")
        check(fields.match([]) == nil, "words match", "no words, no match")
        // Each field of a real card: title, task text, source label, meetings and files.
        let card = task(hex(1), "Make **DoorDash** the most prominent integration", source: "Manual entry 2026-10-06", meetings: ["Bottle POS integrations sync"])
        let made = WorkSearch.fields(items([card])[0], files: ["Integration tiers.xlsx"])
        check(made.match(["doordash"])?.kind == .title, "title match", "markdown in a title is not a word")
        check(made.match(["sync"])?.kind == .words && made.match(["manual"])?.kind == .words && made.match(["tiers"])?.kind == .words,
              "words match", "meeting names, the source label and file names")
    }

    // MARK: Jev thresholds and the result

    static func board(_ count: Int) -> [WorkWorkspaceItem] {
        items((1...count).map { task(hex($0), "Card number \($0) about launch" + ($0 == 1 ? " competitor ads" : "")) })
    }
    static func meaning(_ scores: [String: Double], key: WorkSearchKey = WorkSearchKey(query: "competitor ads", scope: .all, domain: nil),
                        available: Bool = true, reason: String? = nil) -> WorkSearchMeaning {
        WorkSearchMeaning(key: key, available: available, reason: reason, scores: scores)
    }
    static func result(_ cards: [WorkWorkspaceItem], query: String, meaning: WorkSearchMeaning? = nil, elsewhere: [WorkWorkspaceItem] = []) -> WorkSearchResult {
        WorkSearch.result(query: query, board: cards, elsewhere: elsewhere, meaning: meaning) { WorkSearch.fields($0, files: []) }
    }

    static func mergeChecks() {
        let cards = board(8)
        let id = { (n: Int) in cards[n - 1].id }
        let off = result(cards, query: "the")
        check(!off.active && off.shown.isEmpty && off.hits.isEmpty, "search off", "only stopwords is no search")
        let words = result(cards, query: "competitor ads")
        check(words.active && words.hits.count == 1 && words.hits[id(1)]?.kind == .title && words.shown == [id(1)], "title match", "\(words.hits)")
        let scored = result(cards, query: "competitor ads", meaning: meaning([id(2): 0.15, id(3): 0.149, id(4): 0.05, id(5): 0.049, id(1): 0.9, "task:quilt:elsewhere": 0.8]))
        check(scored.hits[id(2)] == WorkSearchHit(kind: .meaning, words: [], p: 0.15), "band threshold", "0.15 counts as a meaning match")
        check(scored.hits[id(3)] == nil, "band threshold", "0.149 is not a match")
        check(!scored.shown.contains(id(3)) && !scored.shown.contains(id(4)) && !scored.shown.contains(id(5)), "one threshold",
              "a card Jev rates under 0.15 is not on the board while searching")
        check(scored.shown == Set(scored.hits.keys), "one threshold", "the columns show exactly the matches")
        check(scored.hits[id(1)] == WorkSearchHit(kind: .title, words: ["competitor", "ads"], p: 0.9), "meaning merge",
              "a card the words found keeps its kind, with Jev's score")
        check(scored.titleCount == 1 && scored.wordsCount == 0 && scored.meaningCount == 1, "meaning merge",
              "meaning counts only cards the words did not find: \(scored.titleCount) \(scored.wordsCount) \(scored.meaningCount)")
        check(!scored.shown.contains("task:quilt:elsewhere") && scored.hits["task:quilt:elsewhere"] == nil, "meaning merge", "a card not on this board is ignored")
        let down = result(cards, query: "competitor ads", meaning: meaning([id(2): 0.8], available: false, reason: "jev_cap_reached"))
        check(down.hits.count == 1 && !down.shown.contains(id(2)), "meaning merge", "an answer that could not run adds nothing")
        check(down.note == "Meaning search is paused for today", "degrade line", "\(String(describing: down.note))")
    }

    static func bandChecks() {
        let cards = items([task(hex(1), "Review competitor pricing pages"),      // words (competitor)
                           task(hex(2), "Competitor ads on paid search"),        // title
                           task(hex(3), "DoorDash integration tier"),            // meaning only
                           task(hex(4), "Competitor ads review for the promo"),  // title, Jev .2
                           task(hex(5), "Ads budget and competitor watch list"), // title
                           task(hex(6), "Ads for the October offer")])           // words (ads)
        let id = { (n: Int) in cards[n - 1].id }
        let found = result(cards, query: "competitor ads", meaning: meaning([id(3): 0.4, id(4): 0.2, id(6): 0.1]))
        check(found.band == [id(3), id(4), id(2)], "band order", "Jev first (most likely first), then titles in board order: \(found.band)")
        check(found.band.count == WorkSearch.bandLimit, "band order", "at most three")
        let wordsFirst: [String: WorkSearchHit] = ["a": WorkSearchHit(kind: .words, words: ["one"]), "b": WorkSearchHit(kind: .words, words: ["one", "two"])]
        check(WorkSearch.band(order: ["a", "b"], hits: wordsFirst) == ["b", "a"], "band order", "the most words first among word matches")
        check(WorkSearch.why(found.hits[id(2)]!) == "Title", "why labels")
        check(WorkSearch.why(found.hits[id(3)]!) == "Similar meaning", "why labels")
        check(WorkSearch.why(WorkSearchHit(kind: .words, words: ["competitor"])) == "Words: \u{201C}competitor\u{201D}", "why labels")
        check(WorkSearch.why(WorkSearchHit(kind: .words, words: ["a1", "b2", "c3"])) == "Words: \u{201C}a1\u{201D}, \u{201C}b2\u{201D}", "why labels",
              "two words at most")
        let hits: [String: WorkSearchHit] = ["x": WorkSearchHit(kind: .words, words: ["a"], p: 0.3), "y": WorkSearchHit(kind: .title, words: ["a"])]
        check(WorkSearch.band(order: ["y", "x"], hits: hits) == ["x", "y"], "band order", "a word match Jev rates 0.15 or more ranks above a title")
    }

    static func countChecks() {
        let cards = board(8)
        let found = result(cards, query: "launch competitor", meaning: meaning([cards[2].id: 0.06]))
        check(found.countText == "8 matches" && found.kindsText == "1 by title · 7 by words", "result line", "\(found.countText) \(found.kindsText)")
        let one = result(cards, query: "competitor ads")
        check(one.countText == "1 match" && one.kindsText == "1 by title", "result line", "\(one.countText) \(one.kindsText)")
        check(WorkSearch.countLabel(kept: 2, of: 5, active: true) == "2 of 5" && WorkSearch.countLabel(kept: 2, of: 5, active: false) == "5",
              "n of m", "a column counts what the search kept of all it holds")
    }

    static func elsewhereChecks() {
        let here = board(3)
        let other = items([task(hex(20), "Competitor ads in the pet market", domain: "personal"),
                           task(hex(21), "Watch the ads competitor list", domain: "personal"),
                           task(hex(22), "Nothing to see", domain: "hermit_crabs")])
        let found = result(here, query: "competitor ads", elsewhere: other)
        check(found.elsewhere == [WorkSearchElsewhere(domain: "personal", count: 2)], "other domains", "\(found.elsewhere)")
        check(WorkSearch.elsewhereText([WorkSearchElsewhere(domain: "Personal", count: 2)]) == "2 more in Personal", "other domains")
        check(WorkSearch.elsewhereText([WorkSearchElsewhere(domain: "Personal", count: 2), WorkSearchElsewhere(domain: "Quilt", count: 1)]) == "3 more in other domains",
              "other domains", "several domains")
        check(WorkSearch.elsewhereText([]) == nil, "other domains", "no line when no other domain matches")
    }

    static func noteChecks() {
        check(WorkSearch.note("jev_cap_reached") == "Meaning search is paused for today", "degrade line", "the day's budget")
        check(WorkSearch.note("jev_breaker_open") == "Meaning search is paused for today", "degrade line", "the breaker")
        check(WorkSearch.note("server_too_old") == "Meaning search needs COS server 6.65", "degrade line", "an older server")
        for quiet in ["search_off", "jev_not_configured", "jev_unavailable", "too_many_candidates", "unreachable", "http_500", nil] as [String?] {
            check(WorkSearch.note(quiet) == nil, "degrade line", "no line for \(String(describing: quiet))")
        }
        let cards = board(2)
        let off = result(cards, query: "launch", meaning: meaning([:], key: WorkSearchKey(query: "launch", scope: .all, domain: nil), available: false, reason: "search_off"))
        check(off.note == nil && off.hits.count == 2, "degrade line", "switched off: the words alone, and nothing said")
        let old = result(cards, query: "launch", meaning: meaning([:], available: false, reason: "server_too_old"))
        check(old.note == "Meaning search needs COS server 6.65", "degrade line", "\(String(describing: old.note))")
        let fine = result(cards, query: "launch", meaning: meaning([:]))
        check(fine.note == nil, "degrade line", "an answer that ran says nothing")
    }

    /// Live Jev calibration (10/6, K1 to K3): a targeted query puts the card at 0.47 to 0.99 and nothing else at 0.15;
    /// nonsense and off-board queries come back empty (none = 1.00); a broad query spreads thin (top 0.23), so the words
    /// carry it. Meaning never invents a row, and an older server (K7) changes nothing but one line.
    static func calibrationChecks() {
        let cards = items([task(hex(1), "Make DoorDash the most prominent e-commerce integration"),
                           task(hex(2), "Launch the refreshed IT Retail website on Thursday"),
                           task(hex(3), "Fix the Bottle POS website backlog"),
                           task(hex(4), "Weekly review of the new website's keyword rankings"),
                           task(hex(5), "IT Retail 3D lane module on the sandbox homepage"),
                           task(hex(6), "Finish the MarktPOS origins video")])
        let id = { (n: Int) in cards[n - 1].id }
        // Empty answer, local matches: the words alone, no meaning row, nothing said.
        let empty = result(cards, query: "website backlog", meaning: meaning([:], key: WorkSearchKey(query: "website backlog", scope: .all, domain: nil)))
        check(empty.hits[id(3)]?.kind == .title && empty.meaningCount == 0 && !empty.hits.values.contains { $0.kind == .meaning } && empty.note == nil,
              "empty answer", "an empty answer invented a meaning row or a line: \(empty.hits)")
        check(empty.band.first == id(3) && empty.band.count == 3 && Set(empty.band) == [id(3), id(2), id(4)], "empty answer", "the band is the word matches: \(empty.band)")
        // Empty answer, no local matches: no rows, and the line says so.
        let none = result(cards, query: "zebra pancake recipe", meaning: meaning([:], key: WorkSearchKey(query: "zebra pancake recipe", scope: .all, domain: nil)))
        check(none.active && none.hits.isEmpty && none.band.isEmpty && none.shown.isEmpty && none.headline == "No matches on this board", "no matches",
              "\(none.headline) \(none.band)")
        check(empty.headline == "3 matches", "no matches", "a search with matches leads with its count: \(empty.headline)")
        // Targeted: the intended card first by meaning, at 0.47.
        let targeted = result(cards, query: "delivery partners", meaning: meaning([id(1): 0.47, id(5): 0.04]))
        check(targeted.band == [id(1)] && targeted.hits[id(1)]?.kind == .meaning && targeted.shown == [id(1)], "targeted answer", "\(targeted.band) \(targeted.shown)")
        // Broad: Jev spreads thin. Its one card over 0.15 leads, the words fill the band, and nothing under 0.15 shows.
        let broad = result(cards, query: "website", meaning: meaning([id(5): 0.23, id(6): 0.11, id(1): 0.07, id(2): 0.06, id(3): 0.04]))
        check(broad.band == [id(5), id(2), id(3)], "broad answer", "the meaning card, then the title matches: \(broad.band)")
        check(broad.titleCount == 3 && broad.meaningCount == 1 && broad.hits.count == 4, "broad answer", "\(broad.kindsText)")
        check(broad.shown == [id(2), id(3), id(4), id(5)], "broad answer", "only the matches, never the 0.05 to 0.15 cards: \(broad.shown.count)")
        // K7: an older server. One line; the words still find everything they found.
        let old = result(cards, query: "website", meaning: meaning([:], key: WorkSearchKey(query: "website", scope: .all, domain: nil), available: false, reason: "server_too_old"))
        let local = result(cards, query: "website")
        check(old.hits == local.hits && old.band == local.band && old.shown == local.shown && old.note == "Meaning search needs COS server 6.65",
              "older server", "an older server changed more than the one line: \(String(describing: old.note))")
    }

    /// One threshold, so every count agrees (10/6 review of work-search-active): the result line's "N matches" is the
    /// number of cards on the board, the board line's "N of M tasks", and the sum of the columns' "n of m", each worked
    /// out with the rule the view uses (WorkSearch.kept and countLabel). On the mock's board for "competitor ads" (the
    /// weekly-review card Jev rated 0.06 showed with 4 matches counted) and on a broad search (Jev 0.23, 0.12, 0.06, 0.06
    /// beside several word matches).
    static func invariantChecks() {
        let mock: [(String, String, String)] = [
            ("mentioned", "Make DoorDash the most prominent e-commerce integration and move CityHive to the lowest tier", "Deprioritize CityHive, Feature DoorDash Integrations (G2)"),
            ("mentioned", "Send Cort screenshots of the paid search campaigns Scotch is running, so the team can target the Bottle POS promo", ""),
            ("mentioned", "Decide with Niala the incentive budget for the Capterra review push to liquor store customers", ""),
            ("mentioned", "Review the Clover and Square funnel audit with Graham", ""),
            ("planned", "Launch the refreshed IT Retail site on Thursday, with the competitor pages and site refreshes", ""),
            ("planned", "Launch the refreshed CigarsPOS site at the start of next sprint", ""),
            ("planned", "Fix the Bottle POS website backlog left over from launch", ""),
            ("planned", "Finish the MarktPOS origins video for an October 23 final: animation polish and color grading", ""),
            ("planned", "Start a weekly review of the new website's session-to-contact rate and keyword rankings", "PR Strategy [2026-09-15]"),
            ("draft", "October switch offer page for Bottle POS, the response to Scotch", "Manual entry 2026-10-06"),
            ("draft", "Small Business Season promo landing pages: review and sign off", "Launchpad Huddle [2026-09-29]"),
            ("built", "IT Retail 3D lane module on the sandbox homepage", "Manual entry 2026-10-03"),
            ("qa", "Bottle POS hardware expanding cards: rescan the pages before upload", "[2026-09-24]"),
            ("complete", "Bottle POS review scores read live from HubDB, refreshed weekly by a Cloudflare Worker", "Manual entry 2026-10-01"),
            ("complete", "Swap the RLS 2026 promo on Wednesday 9/30 at 11:59 PM ET", "Weatherford Weekly Sync [2026-09-28]"),
        ]
        let cards = items(mock.enumerated().map { index, card in
            task(hex(index + 1), card.1, stage: card.0, checked: card.0 == "complete", source: card.2) })
        let id = { (n: Int) in cards.first { $0.task?.id == hex(n) }!.id }
        func agree(_ found: WorkSearchResult, _ label: String) {
            let n = found.hits.count
            let kept = WorkSearch.kept(cards, found)
            check(kept.count == n && Set(kept.map(\.id)) == Set(found.hits.keys), "count invariant",
                  "\(label): the columns show \(kept.count) cards, the line counts \(n)")
            let line = WorkSearch.countLabel(kept: kept.count, of: cards.count, active: found.active)
            check(line == "\(n) of \(cards.count)" && found.countText == (n == 1 ? "1 match" : "\(n) matches"), "count invariant",
                  "\(label): \(found.countText) but \(line) tasks")
            check(found.titleCount + found.wordsCount + found.meaningCount == n, "count invariant", "\(label): the kinds do not add up to \(n)")
            var columns = 0
            for stage in WorkBoardStage.allCases {
                let column = cards.filter { $0.task.map(WorkBoardStage.stage(for:)) == stage }
                let shown = WorkSearch.kept(column, found)
                check(WorkSearch.countLabel(kept: shown.count, of: column.count, active: found.active) == "\(shown.count) of \(column.count)", "count invariant",
                      "\(label): \(stage.title) says something other than n of m")
                columns += shown.count
            }
            check(columns == n, "count invariant", "\(label): the columns' n of m add up to \(columns), the line says \(n)")
        }
        let active = result(cards, query: "competitor ads", meaning: meaning([id(2): 0.62, id(10): 0.41, id(4): 0.18, id(9): 0.06]))
        agree(active, "competitor ads")
        check(active.hits.count == 4 && !WorkSearch.kept(cards, active).contains { $0.id == id(9) }, "one threshold",
              "the weekly-review card Jev rated 0.06 is on the board: \(active.hits.count) matches")
        let broad = result(cards, query: "website launch", meaning: meaning([id(12): 0.23, id(11): 0.12, id(10): 0.06, id(13): 0.06, id(9): 0.06],
                                                                           key: WorkSearchKey(query: "website launch", scope: .all, domain: nil)))
        agree(broad, "website launch")
        // Card 11 matches by its source ("Launchpad Huddle"), so it stays by its words; 10 and 13 have only 0.06. (Which kind
        // each match is, and the band's order, are the merge and band checks' to judge.)
        check(broad.hits.count == 6 && broad.hits[id(12)] != nil && broad.hits[id(9)] != nil && broad.hits[id(11)] != nil
              && broad.hits[id(10)] == nil && broad.hits[id(13)] == nil, "one threshold",
              "a broad search: the 0.23 card and the word matches, never a card with only 0.12 or 0.06: \(broad.kindsText)")
        let inactive = result(cards, query: "the")
        check(WorkSearch.kept(cards, inactive).count == cards.count && WorkSearch.countLabel(kept: cards.count, of: cards.count, active: false) == "\(cards.count)",
              "one threshold", "no search: every card, plain counts")
    }

    // MARK: Keys

    static func keyChecks() {
        check(WorkSearch.key(.down, query: "x", highlighted: 0, bandCount: 3) == .highlight(1), "keys", "↓ walks down")
        check(WorkSearch.key(.down, query: "x", highlighted: 2, bandCount: 3) == .highlight(2), "keys", "↓ stops at the last row")
        check(WorkSearch.key(.up, query: "x", highlighted: 2, bandCount: 3) == .highlight(1), "keys", "↑ walks up")
        check(WorkSearch.key(.up, query: "x", highlighted: 0, bandCount: 3) == .highlight(0), "keys", "↑ stops at the first row")
        check(WorkSearch.key(.up, query: "x", highlighted: 7, bandCount: 2) == .highlight(0), "keys", "a band that shrank walks from its last row")
        check(WorkSearch.key(.open, query: "x", highlighted: 0, bandCount: 3) == .open(0), "keys", "Return opens the first row by default")
        check(WorkSearch.key(.open, query: "x", highlighted: 5, bandCount: 2) == .open(1), "keys", "Return never opens past the band")
        for key in [WorkSearch.Key.down, .up, .open] {
            check(WorkSearch.key(key, query: "x", highlighted: 0, bandCount: 0) == .pass, "keys", "no band: the key goes on")
        }
        check(WorkSearch.key(.clear, query: "x", highlighted: 0, bandCount: 0) == .clear, "keys", "Escape clears a search")
        check(WorkSearch.key(.clear, query: "", highlighted: 0, bandCount: 0) == .pass, "keys", "Escape with nothing typed goes on to the window")
    }

    static func escapeChecks() {
        let state = WorkWorkspaceState()
        check(!state.escapeClearsSearch(), "escape clears", "nothing to clear")
        state.query = "launch"; state.bandIndex = 2
        check(state.escapeClearsSearch() && state.query.isEmpty && state.bandIndex == 0, "escape clears", "the board's search is cleared first")
        for open in ["card", "picker", "start", "intake", "waiting"] {
            let busy = WorkWorkspaceState()
            busy.query = "launch"
            switch open {
            case "card": busy.selectedID = "task:quilt:x"
            case "picker": busy.meetingPicker = true
            case "start": busy.startItemID = "task:quilt:x"
            case "intake": busy.intakeOpen = true
            default: busy.waitingOpen = true
            }
            check(!busy.escapeClearsSearch() && busy.query == "launch", "escape clears", "with \(open) open, Escape is theirs")
        }
    }

    // MARK: Order

    static func orderChecks() {
        let dates: [String: WorkCardDates] = [
            "a": WorkCardDates(created: day("2026-10-01"), active: at("2026-10-06T10:00:00Z")),
            "b": WorkCardDates(created: nil, active: nil),
            "c": WorkCardDates(created: day("2026-09-15"), active: at("2026-10-06T12:00:00Z")),
            "d": WorkCardDates(created: day("2026-10-01"), active: at("2026-10-06T10:00:00Z")),
            "e": WorkCardDates(created: day("2026-10-03"), active: nil),
        ]
        let ids = ["a", "b", "c", "d", "e"]
        func order(_ order: WorkBoardOrder) -> [String] { WorkCardDating.sorted(ids, id: { $0 }, order: order, dates: dates) }
        check(order(.board) == ids, "board order", "Board order leaves the columns as they are")
        check(order(.recent) == ["c", "a", "d", "b", "e"], "recent order", "newest activity first, ties in board order, no date last: \(order(.recent))")
        check(order(.newest) == ["e", "a", "d", "c", "b"], "newest order", "\(order(.newest))")
        check(order(.oldest) == ["c", "a", "d", "e", "b"], "oldest order", "oldest first and still no date last: \(order(.oldest))")
        check(WorkBoardOrder.allCases.map(\.title) == ["Board order", "Recent activity", "Newest created", "Oldest created"], "order names")
    }

    static func persistenceChecks() {
        final class Saved: @unchecked Sendable { var values: [String: String] = [:] }
        let saved = Saved()
        let store = WorkBoardOrderStore(read: { saved.values[$0] }, write: { saved.values[$0] = $1 })
        let state = WorkWorkspaceState(); state.orderStore = store
        check(state.order(domain: "quilt", scope: .all, isolated: false) == .board, "order memory", "Board order by default")
        state.setOrder(.recent, domain: "quilt", scope: .all, isolated: false)
        state.setOrder(.oldest, domain: nil, scope: .completed, isolated: false)
        check(saved.values == ["cos.workOrder.domain:quilt|all": "recent", "cos.workOrder.all|completed": "oldest"], "order memory", "\(saved.values)")
        let relaunched = WorkWorkspaceState(); relaunched.orderStore = store
        check(relaunched.order(domain: "quilt", scope: .all, isolated: false) == .recent, "order memory", "remembered after a relaunch")
        check(relaunched.order(domain: "personal", scope: .all, isolated: false) == .board && relaunched.order(domain: nil, scope: .all, isolated: false) == .board,
              "order memory", "per board: another board keeps its own")
        check(relaunched.order(domain: nil, scope: .completed, isolated: false) == .oldest, "order memory", "per scope")
        let preview = WorkWorkspaceState(); preview.orderStore = store
        preview.setOrder(.newest, domain: "Website", scope: .all, isolated: true)
        check(preview.order(domain: "Website", scope: .all, isolated: true) == .newest && saved.values["cos.workOrder.domain:Website|all"] == nil,
              "order memory", "the preview never writes the real preference")
        saved.values["cos.workOrder.domain:quilt|all"] = "sideways"
        let odd = WorkWorkspaceState(); odd.orderStore = store
        check(odd.order(domain: "quilt", scope: .all, isolated: false) == .board, "order memory", "an unknown stored value reads as Board order")
    }

    // MARK: Dates

    static func createdChecks() {
        func created(_ source: String, _ extra: [String: JSONValue] = [:]) -> Date? {
            WorkCardDating.created(task(hex(1), "x", source: source, extra: extra), calendar: calendar)
        }
        check(created("Manual entry 2026-10-06") == day("2026-10-06"), "created day", "the source label's date")
        check(created("PR Strategy [2026-09-15]") == day("2026-09-15"), "created day", "a bracketed date")
        check(created("Sync 2026-13-01 then 2026-02-30, held 2026-09-02") == day("2026-09-02"), "created day", "the first real day")
        check(created("Ticket 12026-10-06 and 2026-10-061") == nil, "created day", "digits around a date are not a date")
        check(created("No meeting linked") == nil, "created day", "no date")
        check(created("Manual entry 2026-09-15", ["createdOn": .string("2026-10-01"), "createdFrom": .string("git")]) == day("2026-10-01"),
              "created day", "the server's day wins")
        check(created("Manual entry 2026-09-15", ["createdOn": .string("2026-02-30")]) == day("2026-09-15"), "created day", "a server day that is not real")
        check(WorkCardDating.day("2026-10-06", calendar: calendar).map { calendar.component(.hour, from: $0) } == 0, "created day", "the start of the day here")
    }

    static func activityChecks() {
        let base = task(hex(1), "x", source: "Manual entry 2026-09-01", extra: ["lineChangedAt": .string("2026-10-02T15:00:00Z")])
        let moved = at("2026-10-03T15:00:00Z"), session = at("2026-10-04T15:00:00Z"), file = at("2026-10-05T15:00:00Z")
        func active(_ task: TaskRow, moved: Date? = nil, session: Date? = nil, file: Date? = nil) -> WorkCardDates {
            WorkCardDating.dates(task: task, moved: moved, session: session, file: file, calendar: calendar)
        }
        check(active(base).active == at("2026-10-02T15:00:00Z") && active(base).activeIsDay == false, "activity source: line change", "\(active(base))")
        check(active(base, moved: moved).active == moved, "activity source: stage move")
        check(active(base, moved: moved, session: session).active == session, "activity source: session")
        check(active(base, moved: moved, session: session, file: file).active == file, "activity source: file")
        check(active(base, moved: file, session: session).active == file, "activity source: stage move", "the newest wins, whichever it is")
        let plain = task(hex(2), "x", source: "Manual entry 2026-09-01")
        check(active(plain) == WorkCardDates(created: day("2026-09-01"), active: day("2026-09-01"), activeIsDay: true), "activity source: created",
              "only the created day: a day, not a moment")
        check(active(task(hex(3), "x")) == WorkCardDates(created: nil, active: nil), "activity source: created", "nothing at all: no date")
        func receipt(_ id: String, _ work: String, _ status: String, _ at: Double) -> WorkHandoffReceipt {
            WorkHandoffReceipt(id: id, workID: work, workTitle: "t", sourceRevision: "r", mode: .newSession, provider: "claude", modelID: "opus",
                               sessionID: nil, sessionTitle: "s", status: status, detail: "", prompt: "p", createdAt: at)
        }
        let sessions = WorkCardDating.lastSessions([receipt("1", "w1", "completed", 100), receipt("2", "w1", "delivered", 300), receipt("3", "w1", "refused", 900),
                                                   receipt("4", "w2", "failed", 500), receipt("5", "w2", "canceled", 600), receipt("6", "w3", "running", 0)])
        check(sessions == ["w1": Date(timeIntervalSince1970: 300)], "activity source: session",
              "the newest handoff that started a session, never a refused, failed or canceled one: \(sessions)")
    }

    static func lineChecks() {
        let now = at("2026-10-07T04:10:00Z")   // 23:10 in Austin, 10/6
        func line(_ dates: WorkCardDates?, _ order: WorkBoardOrder) -> String? { WorkCardDating.line(dates, order: order, now: now, calendar: calendar) }
        check(line(WorkCardDates(created: day("2026-10-06"), active: now), .board) == nil, "date line", "no date line in Board order")
        check(line(WorkCardDates(active: now.addingTimeInterval(-20)), .recent) == "active now", "date line")
        check(line(WorkCardDates(active: now.addingTimeInterval(-12 * 60)), .recent) == "active 12 min ago", "date line")
        check(line(WorkCardDates(active: now.addingTimeInterval(-2 * 3_600 - 100)), .recent) == "active 2 h ago", "date line")
        check(line(WorkCardDates(active: at("2026-10-05T17:00:00Z")), .recent) == "active yesterday", "date line")
        check(line(WorkCardDates(active: at("2026-10-01T17:00:00Z")), .recent) == "active 5 days ago", "date line")
        check(line(WorkCardDates(created: day("2026-10-06"), active: day("2026-10-06"), activeIsDay: true), .recent) == "active today", "date line",
              "a created day never reads as hours")
        check(line(WorkCardDates(), .recent) == "No date" && line(nil, .newest) == "No date", "date line")
        check(line(WorkCardDates(created: day("2026-10-06")), .newest) == "created Oct 6", "date line")
        check(line(WorkCardDates(created: day("2025-12-30")), .oldest) == "created Dec 30, 2025", "date line", "another year says which")
    }

    // MARK: Rows, request and answer

    static func taskRowChecks() {
        let full = task(hex(1), "x", extra: ["createdOn": .string("2026-10-01"), "createdFrom": .string("git"), "lineChangedAt": .string("2026-10-06T22:58:00.000Z")])
        check(full.createdOn == "2026-10-01" && full.createdFrom == "git" && full.lineChangedAt == "2026-10-06T22:58:00.000Z", "task row dates")
        let old = task(hex(2), "x")
        check(old.createdOn == nil && old.createdFrom == nil && old.lineChangedAt == nil, "task row dates", "an older server sends none")
        let null = task(hex(3), "x", extra: ["createdOn": .null, "createdFrom": .string(""), "lineChangedAt": .null])
        check(null.createdOn == nil && null.createdFrom == nil && null.lineChangedAt == nil, "task row dates", "null and empty read as none")
    }

    static func requestChecks() {
        let cards = items([task(hex(1), "Launch the site", domain: "quilt"), task(hex(2), "Launch the app", domain: "personal"),
                           task("sample-task-x", "A preview card")])
        let domain = WorkSearch.request(key: WorkSearchKey(query: "launch", scope: .all, domain: "quilt"), query: " launch ", items: cards)
        check(json(domain.body) == #"{"domain":"quilt","query":"launch","scope":"all"}"# && domain.wantsMeaning, "search request",
              "a domain board names its domain: \(json(domain.body))")
        let all = WorkSearch.request(key: WorkSearchKey(query: "launch", scope: .all, domain: nil), query: "launch", items: cards)
        check(json(all.body) == #"{"query":"launch","scope":"all"}"#, "search request", "All work: \(json(all.body))")
        let done = WorkSearch.request(key: WorkSearchKey(query: "launch", scope: .completed, domain: nil), query: "launch", items: cards)
        check(json(done.body) == #"{"query":"launch","scope":"completed"}"#, "search request", "Completed: \(json(done.body))")
        let twins = items([task(hex(1), "Launch the site", domain: "quilt"), task(hex(1), "Launch the app", domain: "personal"),
                           task(hex(2), "Launch the shop"), task("sample-task-x", "A preview card")])
        let list = WorkSearch.request(key: WorkSearchKey(query: "launch", scope: .attention, domain: nil), query: "launch", items: twins)
        check(json(list.body) == "{\"ids\":[\"\(hex(1))\",\"\(hex(2))\"],\"query\":\"launch\"}" && list.wantsMeaning, "search request",
              "a list only Control computes sends its cards' ids, each once and only real ones: \(json(list.body))")
        check(list.lookup[hex(1)] == [twins[0].id, twins[1].id] && list.lookup[hex(2)] == [twins[2].id] && list.lookup["sample-task-x"] == nil, "search request",
              "an answer's id leads back to every board card with that id: \(list.lookup)")
        check(!WorkSearch.request(key: all.key, query: "ab", items: cards).wantsMeaning, "meaning minimum", "two characters: words only")
        check(WorkSearch.request(key: all.key, query: "seo", items: cards).wantsMeaning, "meaning minimum", "three characters ask")
        check(!WorkSearch.request(key: all.key, query: "the", items: cards).wantsMeaning, "meaning minimum", "a stopword alone never asks")
        let many = items((1...255).map { task(hex($0), "Card \($0)") })
        check(!WorkSearch.request(key: WorkSearchKey(query: "card", scope: .progress, domain: nil), query: "card", items: many).wantsMeaning,
              "search request", "more cards than a Choice holds are never sent")
        check(WorkSearch.request(key: all.key, query: String(repeating: "x", count: 300), items: cards).body["query"]?.string == String(repeating: "x", count: 200),
              "search request", "the query is cut at 200 characters")
    }

    actor Gate {
        var calls: [([String], Data?)] = []
        var hold = false
        var answer: HelperResponse
        var fail = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        init(_ answer: HelperResponse) { self.answer = answer }
        func call(_ args: [String], _ data: Data?) async throws -> HelperResponse {
            calls.append((args, data))
            if hold { await withCheckedContinuation { waiting.append($0) } }
            if fail { throw HelperClientError.timedOut }
            return answer
        }
        func set(hold: Bool? = nil, fail: Bool? = nil, answer: HelperResponse? = nil) {
            if let hold { self.hold = hold }
            if let fail { self.fail = fail }
            if let answer { self.answer = answer }
        }
        func release() { for waiter in waiting { waiter.resume() }; waiting = [] }
        func count() -> Int { calls.count }
        func last() -> ([String], Data?)? { calls.last }
    }
    static func answer(_ results: [(String, Double)]) -> HelperResponse {
        HelperResponse(ok: true, message: "", details: ["available": .bool(true),
            "results": .array(results.map { .object(["id": .string($0.0), "p": .number($0.1)]) })])
    }

    static func askChecks() async throws {
        let cards = items([task(hex(1), "Launch the site"), task(hex(2), "Fix the backlog")])
        let request = WorkSearch.request(key: WorkSearchKey(query: "website launch", scope: .all, domain: "quilt"), query: "website launch", items: cards)
        let gate = Gate(answer(([(hex(2), 0.62), (hex(1), 0.2), ("ffffffffffff", 0.9), (hex(1), 1.5)])))
        let got = await WorkSearch.ask(request, transport: { args, data in try await gate.call(args, data) })
        let sent = await gate.last()
        check(sent?.0 == ["work-search"], "work-search transport", "the helper command")
        let body = sent?.1.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        check(body == ["query": "website launch", "scope": "all", "domain": "quilt"], "work-search transport", "\(String(describing: body))")
        check(got == WorkSearchMeaning(key: request.key, available: true, reason: nil, scores: [cards[1].id: 0.62, cards[0].id: 0.2]), "work-search answer",
              "ids lead to the board's cards; an unknown id and a p over 1 are dropped: \(got.scores)")
        await gate.set(answer: HelperResponse(ok: true, message: "", details: ["available": .bool(false), "reason": .string("jev_breaker_open")]))
        let paused = await WorkSearch.ask(request, transport: { args, data in try await gate.call(args, data) })
        check(!paused.available && paused.reason == "jev_breaker_open" && paused.scores.isEmpty, "work-search answer", "\(paused)")
        await gate.set(answer: HelperResponse(ok: true, message: "", details: ["available": .bool(false), "reason": .string("server_too_old")]))
        check(await WorkSearch.ask(request, transport: { args, data in try await gate.call(args, data) }).reason == "server_too_old", "work-search answer")
        await gate.set(fail: true)
        let failed = await WorkSearch.ask(request, transport: { args, data in try await gate.call(args, data) })
        check(!failed.available && failed.reason == "unreachable", "work-search answer", "a failed helper is an answer, never an error")
        check(WorkSearch.parse(HelperResponse(ok: false, message: "x", details: [:]), request: request).reason == "unreachable", "work-search answer")
        check(WorkSearch.parse(HelperResponse(ok: true, message: "", details: [:]), request: request).reason == "jev_unavailable", "work-search answer",
              "an answer with no verdict")
    }

    static func staleChecks() async throws {
        let cards = items([task(hex(1), "Make DoorDash the most prominent integration"), task(hex(2), "Send Cort the paid search ads")])
        let gate = Gate(answer([(hex(1), 0.7)]))
        let state = WorkWorkspaceState()
        state.searchPause = .zero
        state.searchTransport = { args, data in try await gate.call(args, data) }
        func ask() -> WorkSearchRequest { WorkSearch.request(key: state.currentSearchKey, query: state.query, items: cards) }

        // An answer that arrives after the search changed is dropped.
        state.query = "delivery partners"
        let first = ask()
        await gate.set(hold: true)
        let pending = Task { await state.searchMeaning(first, isolated: false) }
        var spins = 0
        while await gate.count() == 0, spins < 2_000 { try await Task.sleep(for: .milliseconds(2)); spins += 1 }
        check(await gate.count() == 1, "stale drop", "the request never went out")
        state.query = "competitor ads"
        await gate.release(); await gate.set(hold: false)
        await pending.value
        check(state.meaning == nil && state.staleMeaningDrops == 1, "stale drop", "an answer for an older search showed: \(String(describing: state.meaning))")

        // The current search's answer is kept, and the same search is never asked twice.
        await state.searchMeaning(ask(), isolated: false)
        check(state.meaning?.key == state.currentSearchKey && state.meaning?.scores[cards[0].id] == 0.7, "stale drop", "the current answer was not kept")
        check(state.meaning(for: state.currentSearchKey) != nil && state.meaning(for: first.key) == nil, "stale drop", "an answer is read only for its own search")
        await state.searchMeaning(ask(), isolated: false)
        let asked = await gate.count()
        check(asked == 2, "same search once", "the same search was asked again: \(asked)")

        // A new search cancels the wait: nothing is sent.
        state.searchPause = .milliseconds(300)
        state.query = "website launch"
        let waiting = Task { await state.searchMeaning(ask(), isolated: false) }
        try await Task.sleep(for: .milliseconds(20))
        waiting.cancel(); await waiting.value
        check(await gate.count() == 2, "pause", "a cancelled wait still asked Jev")
        // The pause is real: an answer never comes before it.
        let started = Date()
        await state.searchMeaning(ask(), isolated: false)
        let afterPause = await gate.count()
        check(Date().timeIntervalSince(started) >= 0.29 && afterPause == 3, "pause", "Jev was asked before the pause")

        // Words only: under three characters, stopwords, the preview without a fake, more cards than a Choice holds.
        state.searchPause = .zero
        state.query = "ab"; await state.searchMeaning(ask(), isolated: false)
        state.query = "the and"; await state.searchMeaning(ask(), isolated: false)
        state.query = "partners"; await state.searchMeaning(ask(), isolated: true)
        let wordsOnly = await gate.count()
        check(wordsOnly == 3, "meaning minimum", "a search that should not ask did: \(wordsOnly)")
        state.previewSearchTransport = { args, data in try await gate.call(args, data) }
        await state.searchMeaning(ask(), isolated: true)
        check(await gate.count() == 4, "meaning minimum", "the preview's own fake is used")
    }

    /// The board's memo: the search is built once per search, answer and data; card files are read once per change.
    static func memoChecks() {
        let memo = WorkBoardMemo()
        let tasks = [task(hex(1), "Launch the site", domain: "quilt"), task(hex(2), "Fix the backlog", domain: "quilt"),
                     task(hex(3), "Launch the pet site", domain: "personal"), task(hex(4), "Launch done", domain: "quilt", checked: true)]
        memo.refreshed(WorkBoardDataKey(tasks: 1)) { items(tasks) }
        var reads = 0
        let names: (String) -> [String] = { id in reads += 1; return id.hasSuffix(hex(2)) ? ["Launch checklist.pdf"] : [] }
        let found = memo.search(scope: .all, domain: "quilt", query: "launch", meaning: nil, filesEpoch: 1, fileNames: names)
        check(found.hits.count == 3 && found.hits.values.filter { $0.kind == .words }.count == 1, "memo search", "a file name finds its card: \(found.hits)")
        check(found.elsewhere == [WorkSearchElsewhere(domain: "personal", count: 1)], "other domains", "the memo counts other domains: \(found.elsewhere)")
        let afterFirst = reads
        _ = memo.search(scope: .all, domain: "quilt", query: "launch", meaning: nil, filesEpoch: 1, fileNames: names)
        _ = memo.search(scope: .all, domain: "quilt", query: "backlog", meaning: nil, filesEpoch: 1, fileNames: names)
        check(reads == afterFirst, "memo search", "card files were read again for an unchanged card: \(reads - afterFirst)")
        _ = memo.search(scope: .all, domain: "quilt", query: "backlog", meaning: nil, filesEpoch: 2, fileNames: names)
        check(reads > afterFirst, "memo search", "a change to card files was not read")
        let open = memo.search(scope: .all, domain: nil, query: "launch", meaning: nil, filesEpoch: 2, fileNames: names)
        check(open.elsewhere.isEmpty && open.hits.count == 4, "other domains", "All work has no other domain")
    }

    // MARK: The journal

    static func journalChecks() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cos search.journal \u{00FC}-\(UUID().uuidString.prefix(6))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent("Application Support/COS Control/work-activity.json")
        let journal = WorkActivityJournal(url: url)
        let card = task(hex(1), "x", stage: "planned")
        journal.recordStageChange(card, to: "planned")
        check(journal.moves.isEmpty && !FileManager.default.fileExists(atPath: url.path), "journal stage change", "writing the same stage is not activity")
        journal.recordStageChange(card, to: "draft", at: at("2026-10-06T22:00:00Z"))
        check(journal.moves == [card.workSourceID: at("2026-10-06T22:00:00Z")], "journal stage change", "\(journal.moves)")
        check(WorkActivityJournal(url: url).moves == journal.moves, "journal write", "a relaunch reads what was written")
        let done = task(hex(2), "x", checked: true)
        journal.recordStageChange(done, to: "complete")
        check(journal.moves[done.workSourceID] == nil, "journal stage change", "Complete again is no move")
        journal.recordStageChange(done, to: "planned")
        check(journal.moves[done.workSourceID] != nil, "journal stage change", "reopening is a move")
        // The bound: the newest 2,000.
        var many: [String: Date] = [:]
        for index in 0..<2_005 { many["task:quilt:\(index)"] = Date(timeIntervalSince1970: Double(1_000_000 + index)) }
        let kept = WorkActivityJournal.bounded(many, limit: WorkActivityJournal.limit)
        check(kept.count == 2_000 && kept["task:quilt:4"] == nil && kept["task:quilt:5"] != nil && kept["task:quilt:2004"] != nil, "journal bound",
              "\(kept.count) kept; oldest kept: \(kept["task:quilt:5"] != nil)")
        // Through the app's own path: a file of 1,999, then four moves.
        var seed: [String: Date] = [:]
        for index in 0..<1_999 { seed["task:quilt:\(index)"] = Date(timeIntervalSince1970: Double(2_000_000 + index)) }
        try WorkActivityJournal.encode(seed).write(to: home.appendingPathComponent("bounded.json"))
        let bounded = WorkActivityJournal(url: home.appendingPathComponent("bounded.json"))
        for index in 1_999..<2_003 { bounded.record("task:quilt:\(index)", at: Date(timeIntervalSince1970: Double(2_000_000 + index))) }
        let reread = WorkActivityJournal(url: home.appendingPathComponent("bounded.json")).moves
        check(bounded.moves.count == 2_000 && reread.count == 2_000 && reread["task:quilt:2"] == nil && reread["task:quilt:3"] != nil, "journal bound",
              "the file holds the newest 2,000: \(reread.count)")
        // A file is replaced whole (atomic), and a bad file reads as empty.
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        check(raw?["version"] as? Int == 1 && (raw?["moves"] as? [String: String])?.count == 2, "journal write", "\(String(describing: raw))")
        try Data("{not json".utf8).write(to: url)
        check(WorkActivityJournal(url: url).moves.isEmpty, "journal write", "a damaged file reads as empty")
        try Data(#"{"version":1,"moves":{"task:quilt:a":"2026-10-06T22:00:00Z","task:quilt:b":"yesterday","":"2026-10-06T22:00:00Z"}}"#.utf8).write(to: url)
        check(WorkActivityJournal(url: url).moves.keys.sorted() == ["task:quilt:a"], "journal write", "a bad entry is skipped")
        check(WorkActivityJournal(url: nil).moves.isEmpty, "journal write", "no file: nothing read")
    }

    /// The app's own stage writes note the move: the board (setWorkStage, which the tracker's moves and Undo also use) and
    /// Intake and Waiting on (changeWorkCard). Run through a stand-in helper beside this binary (Tests/run-work-search.sh).
    static func journalWriteChecks() async throws {
        guard let fixtures = ProcessInfo.processInfo.environment["COS_SEARCH_FIXTURES"].map({ URL(fileURLWithPath: $0, isDirectory: true) }),
              let home = ProcessInfo.processInfo.environment["COS_CONTROL_TEST_HOME"] else {
            fatalError("check failed [journal stage change]: run through Tests/run-work-search.sh (a stand-in helper and a scratch home)")
        }
        let row: [String: Any] = ["id": hex(9), "ref": "", "domain": "quilt", "title": "Launch the site", "text": "Launch the site", "column": "planning",
                                  "section": "inbox", "checked": false, "workStage": "planned", "workIdentity": hex(9), "workRevision": String(repeating: "b", count: 64),
                                  "meetingRefs": [], "source": "Manual entry 2026-10-03"]
        func write(_ name: String, _ details: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: ["ok": true, "message": "", "details": details]).write(to: fixtures.appendingPathComponent(name + ".json"))
        }
        try write("work-tasks", ["tasks": [row], "count": 1, "total": 1, "complete": true, "capabilities": ["version": 1, "writable": true, "workBatch": 1]])
        try write("work-set-stage", ["ok": true])
        try write("work-loop", [:])
        try write("tasks", ["tasks": []])
        let model = ControllerModel(startBackgroundWork: false)
        let journalURL = URL(fileURLWithPath: home).appendingPathComponent("work-activity.json")
        check(model.workActivity.url == journalURL, "journal write", "checks write under their own home: \(String(describing: model.workActivity.url))")
        await model.loadWorkTasks()
        guard let card = model.workTasks.first else { fatalError("check failed [journal stage change]: the stand-in board did not load: \(model.workTasksError ?? "")") }
        try await model.setWorkStage(card, stage: "planned")
        check(model.workActivity.moves.isEmpty, "journal stage change", "the same stage written again is no move")
        try await model.setWorkStage(card, stage: "draft")
        let first = model.workActivity.moves[card.workSourceID]
        let onDisk = WorkActivityJournal(url: journalURL).moves[card.workSourceID]
        check(first != nil && onDisk.map { abs($0.timeIntervalSince(first!)) < 0.001 } == true, "journal stage change",
              "a board move is noted on disk: \(model.workActivity.moves)")
        let calls = (try? String(contentsOf: fixtures.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
        check(calls.split(separator: "\n").contains("work-set-stage"), "journal stage change", "the move went through the helper: \(calls)")
        // Intake's Keep and Waiting on's Done write the stage through the batch.
        try await Task.sleep(for: .milliseconds(5))
        check(await model.changeWorkCard(card, action: "stage", fields: ["workStage": "complete"]), "journal stage change", model.workLoopError ?? "")
        let second = model.workActivity.moves[card.workSourceID]
        check(second != nil && first != nil && second! > first!, "journal stage change", "a batch stage change is noted")
        check(await model.changeWorkCard(card, action: "delegate", fields: ["owner": "Gina", "checkIn": "2026-10-13"]) && model.workActivity.moves[card.workSourceID] == second,
              "journal stage change", "a change that is not a stage is no move")
        // A refused write notes nothing.
        try JSONSerialization.data(withJSONObject: ["ok": false, "message": "Refused", "details": [:]]).write(to: fixtures.appendingPathComponent("work-set-stage.json"))
        let before = model.workActivity.moves
        do { try await model.setWorkStage(card, stage: "qa"); check(false, "journal stage change", "a refused write did not throw") } catch {}
        check(model.workActivity.moves == before, "journal stage change", "a refused write was noted")
    }
}
